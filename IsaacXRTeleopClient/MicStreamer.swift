// SPDX-FileCopyrightText: Copyright (c) 2023-2024 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: LicenseRef-NvidiaProprietary
//
// NVIDIA CORPORATION, its affiliates and licensors retain all intellectual
// property and proprietary rights in and to this material, related
// documentation and any modifications thereto. Any use, reproduction,
// disclosure or distribution of this material and related documentation
// without an express license agreement from NVIDIA CORPORATION or
// its affiliates is strictly prohibited.

import AVFAudio
import Foundation
import Observation
import os.log

/// Streams the headset microphone to the Isaac Lab teleop server for voice
/// commands (success / failure / align / play / stop / reset / next — the
/// transcription runs server-side with Whisper).
///
/// Wire protocol: binary WebSocket frames of raw 16 kHz mono PCM16 (little
/// endian), sent to `wss://<server>:8444/audio` — the same protocol the Quest
/// browser mic page speaks, so the server (IsaacLab
/// `sharpa_duo/headset_mic.py`, `--mic_device avp`) is shared between the two
/// headsets and re-chunks whatever frame sizes arrive.
///
/// The server's TLS certificate is self-signed (it reuses the CloudXR proxy's
/// certificate), so this session trusts the server unconditionally — the same
/// decision the Quest flow makes when the operator accepts the browser's
/// certificate warning. This is out-of-band with respect to CloudXRKit: it
/// uses only AVFoundation and URLSession, so it works with any CloudXRKit
/// version.
///
/// Lifecycle: `start(host:)` when the CloudXR session connects (the server IP
/// is the same machine), `stop()` on disconnect or when the user turns the
/// mic toggle off. Lost connections retry every 2 s while started, mirroring
/// the Quest page's auto-reconnect.
@Observable
final class MicStreamer {
    @ObservationIgnored static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "IsaacXRTeleopClient",
        category: "MicStreamer"
    )

    /// Port of the teleop server's headset-mic endpoint (headset_mic.py default).
    static let defaultPort = 8444

    private static let sampleRate = 16_000.0
    private static let chunkSamples = 1600  // 0.1 s, the server reader's granularity
    private static let chunkBytes = chunkSamples * MemoryLayout<Int16>.size
    private static let reconnectDelay: TimeInterval = 2.0

    /// One-line connection state for the UI.
    private(set) var status = "off"
    /// Peak mic level of the last second, 0…1, for the UI level meter.
    private(set) var level: Float = 0

    /// Serial queue owning all mutable streaming state below.
    @ObservationIgnored private let ioQueue = DispatchQueue(label: "MicStreamer.io")
    @ObservationIgnored private var enabled = false
    @ObservationIgnored private var url: URL?
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var socketTask: URLSessionWebSocketTask?
    @ObservationIgnored private var pending = Data()
    @ObservationIgnored private var levelHold: Float = 0
    @ObservationIgnored private var levelChunks = 0
    @ObservationIgnored private var configChangeObserver: NSObjectProtocol?

    @ObservationIgnored private lazy var urlSession: URLSession = {
        let delegate = SocketDelegate()
        delegate.streamer = self
        return URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
    }()

    /// Begin capturing the mic and streaming it to `host`. Idempotent while
    /// already streaming to the same host.
    func start(host: String, port: Int = MicStreamer.defaultPort) {
        guard let url = URL(string: "wss://\(host):\(port)/audio") else {
            setStatus("bad server address: \(host)")
            return
        }
        Task {
            guard await AVAudioApplication.requestRecordPermission() else {
                Self.logger.error("Microphone permission denied")
                self.setStatus("microphone permission denied")
                return
            }
            self.ioQueue.async {
                if self.enabled && self.url == url && self.engine != nil { return }
                self.shutdownLocked()
                self.enabled = true
                self.url = url
                do {
                    try self.startEngineLocked()
                } catch {
                    Self.logger.error("Audio engine failed: \(error.localizedDescription)")
                    self.enabled = false
                    self.setStatus("audio engine failed: \(error.localizedDescription)")
                    return
                }
                self.openSocketLocked()
            }
        }
    }

    /// Stop capturing and streaming. Idempotent.
    func stop() {
        ioQueue.async {
            guard self.enabled else { return }
            self.shutdownLocked()
            self.setStatus("off")
        }
    }

    // MARK: - Audio capture (ioQueue)

    private func startEngineLocked() throws {
        // .mixWithOthers keeps CloudXRKit's streamed audio playing; the mic is
        // started only after the CloudXR session connects, so this category
        // change lands after CloudXRKit's own audio session setup.
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers])
        try audioSession.setActive(true)

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw MicError.noInputDevice
        }
        guard
            let outFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: Self.sampleRate,
                channels: 1,
                interleaved: true
            ),
            let converter = AVAudioConverter(from: inFormat, to: outFormat)
        else {
            throw MicError.converterUnavailable
        }
        input.installTap(onBus: 0, bufferSize: 4800, format: inFormat) { [weak self] buffer, _ in
            self?.convertAndEnqueue(buffer: buffer, converter: converter, outFormat: outFormat)
        }
        engine.prepare()
        try engine.start()
        self.engine = engine

        // The OS re-routing the input (device change, interruption recovery)
        // invalidates the tap format — rebuild the engine on the new route.
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.ioQueue.async {
                guard self.enabled else { return }
                Self.logger.info("Audio route changed; restarting capture")
                self.teardownEngineLocked()
                do {
                    try self.startEngineLocked()
                } catch {
                    self.setStatus("mic lost: \(error.localizedDescription)")
                }
            }
        }
    }

    private func teardownEngineLocked() {
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
    }

    /// Runs on the audio tap thread: resample to 16 kHz mono int16 and hand
    /// the bytes to the ioQueue.
    private func convertAndEnqueue(buffer: AVAudioPCMBuffer, converter: AVAudioConverter, outFormat: AVAudioFormat) {
        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
        var fed = false
        var conversionError: NSError?
        let result = converter.convert(to: out, error: &conversionError) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard result != .error, out.frameLength > 0, let samples = out.int16ChannelData else { return }
        let data = Data(bytes: samples[0], count: Int(out.frameLength) * MemoryLayout<Int16>.size)
        ioQueue.async { self.enqueueLocked(data) }
    }

    private func enqueueLocked(_ data: Data) {
        guard enabled else { return }
        pending.append(data)
        while pending.count >= Self.chunkBytes {
            let chunk = Data(pending.prefix(Self.chunkBytes))
            pending.removeFirst(Self.chunkBytes)
            meterLocked(chunk)
            guard let task = socketTask else { continue }  // not connected: drop, don't lag
            task.send(.data(chunk)) { [weak self] error in
                if error != nil {
                    self?.socketFailed(task)
                }
            }
        }
    }

    private func meterLocked(_ chunk: Data) {
        var peak: Int16 = 0
        chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for sample in raw.bindMemory(to: Int16.self) {
                peak = max(peak, sample == .min ? .max : abs(sample))
            }
        }
        levelHold = max(levelHold, Float(peak) / 32768)
        levelChunks += 1
        if levelChunks >= 10 {  // once per second
            let level = levelHold
            levelChunks = 0
            levelHold = 0
            DispatchQueue.main.async { self.level = level }
        }
    }

    // MARK: - WebSocket (ioQueue)

    private func openSocketLocked() {
        guard enabled, socketTask == nil, let url else { return }
        let task = urlSession.webSocketTask(with: url)
        socketTask = task
        task.resume()
        setStatus("connecting to \(url.host ?? "server")…")
    }

    fileprivate func socketOpened(_ task: URLSessionWebSocketTask) {
        ioQueue.async {
            guard task === self.socketTask, let url = self.url else { return }
            Self.logger.info("Mic stream connected")
            self.setStatus("streaming to \(url.host ?? "server")")
        }
    }

    fileprivate func socketFailed(_ task: URLSessionTask) {
        ioQueue.async {
            guard task === self.socketTask else { return }
            self.socketTask = nil
            guard self.enabled else { return }
            self.setStatus("server unreachable — retrying")
            self.ioQueue.asyncAfter(deadline: .now() + Self.reconnectDelay) { [weak self] in
                self?.openSocketLocked()
            }
        }
    }

    private func shutdownLocked() {
        enabled = false
        teardownEngineLocked()
        socketTask?.cancel(with: .goingAway, reason: nil)
        socketTask = nil
        pending.removeAll()
        levelHold = 0
        levelChunks = 0
        DispatchQueue.main.async { self.level = 0 }
    }

    private func setStatus(_ text: String) {
        DispatchQueue.main.async { self.status = text }
    }

    private enum MicError: LocalizedError {
        case noInputDevice
        case converterUnavailable

        var errorDescription: String? {
            switch self {
            case .noInputDevice: "no microphone input available"
            case .converterUnavailable: "could not create the 16 kHz converter"
            }
        }
    }
}

/// URLSession delegate: trusts the teleop server's self-signed certificate and
/// forwards socket open/close events to the streamer.
private final class SocketDelegate: NSObject, URLSessionWebSocketDelegate {
    weak var streamer: MicStreamer?

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocolName: String?
    ) {
        streamer?.socketOpened(webSocketTask)
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        streamer?.socketFailed(webSocketTask)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        streamer?.socketFailed(task)
    }
}
