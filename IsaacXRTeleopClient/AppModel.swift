// SPDX-FileCopyrightText: Copyright (c) 2023-2024 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: LicenseRef-NvidiaProprietary
//
// NVIDIA CORPORATION, its affiliates and licensors retain all intellectual
// property and proprietary rights in and to this material, related
// documentation and any modifications thereto. Any use, reproduction,
// disclosure or distribution of this material and related documentation
// without an express license agreement from NVIDIA CORPORATION or
// its affiliates is strictly prohibited.

import RealityKit
import Foundation
import CloudXRKit
import SwiftUI
import ARKit
import os.log

@Observable
class AppModel {
    @ObservationIgnored static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "IsaacXRTeleopClient",
        category: "AppModel"
    )

    var openImmersiveSpace: OpenImmersiveSpaceAction!
    var dismissImmersiveSpace: DismissImmersiveSpaceAction!
    var openWindow: OpenWindowAction!
    var dismissWindow: DismissWindowAction!

    let initPositionOffset = simd_float3(0, 0, 0)

    let cxrSession = CloudXRSession(config: CloudXRKit.Config())

    let sessionEntity = Entity()

    static private let savedSettings = SavedSettings()

    /// The teleop message channel, set once the server announces it after connect.
    var teleopChannel: MessageChannel?

    /// In-flight channel discovery task so we don't spawn duplicates.
    @ObservationIgnored private var channelDiscoveryTask: Task<Void, Never>?

    /// Episode index of a pending server-side "was this recording a success?" request.
    /// Non-nil while the Success/Failure sheet should be shown.
    var recordResultEpisode: Int?

    /// Consumes teleopChannel.receivedMessageStream for server-initiated messages.
    @ObservationIgnored private var messageReceiveTask: Task<Void, Never>?

    var configWindowIsOpen: Bool = false {
        didSet {
            // Reopen the window if the stream is running.
            if !configWindowIsOpen && cxrSession.state == .connected {
                // We might get into a situation where we falsely identify the config window as closed,
                // especially when transitioning to immersive space open and when the headset is taken
                // off. Hence, before opening the window again, we make sure everything is closed.
                Task { @MainActor in
                    dismissWindow(id: configViewTitle)
                    openWindow(id: configViewTitle)
                    configWindowIsOpen = true
                }
            }
        }
    }

    var immersiveSpaceIsOpen: Bool = false

    var teleopRunning: Bool = false

    var ipAddress = savedSettings.ipAddress {
        didSet {
            Self.savedSettings.ipAddress = ipAddress
        }
    }

    // MARK: - Message channel discovery

    /// Poll for the teleop message channel and open it once available.
    /// The server announces channels after the OpenXR teleop session is
    /// created, which may lag behind the streaming connection.
    func awaitTeleopChannel() async -> MessageChannel? {
        if let channel = teleopChannel {
            return channel
        }

        let maxWaitMs = 10_000
        let pollIntervalMs = 250
        let pollIntervalNs: UInt64 = UInt64(pollIntervalMs) * 1_000_000

        var waited = 0
        while waited < maxWaitMs {
            if Task.isCancelled { return nil }
            guard cxrSession.state == .connected else { return nil }

            let channels = cxrSession.availableMessageChannels
            if let info = findTeleopChannel(in: channels) {
                if let channel = cxrSession.getMessageChannel(info) {
                    // Eagerly send a ping to trigger the OPEN handshake so the
                    // server transitions the channel to CONNECTED immediately.
                    let ping = "{\"type\":\"ping\"}".data(using: .utf8)!
                    _ = channel.sendServerMessage(ping)

                    teleopChannel = channel
                    Self.logger.info("Teleop message channel opened")
                    startMessageReceiveTask(on: channel)
                    return channel
                }
            }
            do {
                try await Task.sleep(nanoseconds: pollIntervalNs)
            } catch {
                return nil
            }
            waited += pollIntervalMs
        }

        Self.logger.error("No teleop message channel available after \(maxWaitMs)ms")
        return nil
    }

    /// Start channel discovery in the background. Safe to call multiple times;
    /// redundant calls are no-ops while a discovery task is in flight.
    func beginChannelDiscovery() {
        guard channelDiscoveryTask == nil else { return }
        channelDiscoveryTask = Task {
            _ = await awaitTeleopChannel()
            channelDiscoveryTask = nil
        }
    }

    /// Tear down channel state when the session disconnects.
    func resetChannelState() {
        channelDiscoveryTask?.cancel()
        channelDiscoveryTask = nil
        messageReceiveTask?.cancel()
        messageReceiveTask = nil
        teleopChannel = nil
        teleopRunning = false
        recordResultEpisode = nil
    }

    // MARK: - Server-initiated messages

    /// Listen for server->client messages on the teleop channel. The Isaac Lab side
    /// pushes `omni.kit.cloudxr.send_message` carb events whose `message` field
    /// arrives here as the raw message bytes.
    private func startMessageReceiveTask(on channel: MessageChannel) {
        messageReceiveTask?.cancel()
        messageReceiveTask = Task { [weak self] in
            for await data in channel.receivedMessageStream {
                guard !Task.isCancelled else { return }
                self?.handleServerMessage(data)
            }
        }
    }

    private func handleServerMessage(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Self.logger.warning("Server message is not JSON: \(String(data: data, encoding: .utf8) ?? "<binary>")")
            return
        }
        // The relay may deliver either our payload directly or a wrapper with the
        // payload under "message"; accept both.
        let body = (json["message"] as? [String: Any]) ?? json
        guard let type = (body["type"] as? String) ?? (json["type"] as? String) else { return }
        switch type {
        case "recording_result_request":
            let episode = (body["episode"] as? Int) ?? -1
            Task { @MainActor in
                self.recordResultEpisode = episode
            }
        default:
            Self.logger.info("Unhandled server message type: \(type)")
        }
    }

    /// Send a teleop command (fire-and-forget) — usable from any view, unlike the
    /// deferred-send path in TeleopControlView's ViewModel, which is only mounted
    /// while connected.
    @discardableResult
    func sendTeleopCommand(_ command: String) -> Bool {
        guard let channel = teleopChannel else {
            Self.logger.error("sendTeleopCommand(\(command)): no message channel")
            return false
        }
        let teleopCommand = ClientToServerCommand(type: "teleop_command", message: ["command": command])
        guard let jsonCommand = try? JSONEncoder().encode(teleopCommand) else {
            Self.logger.error("JSON encoding failed.")
            return false
        }
        let success = channel.sendServerMessage(jsonCommand)
        if success {
            Self.logger.info("Teleop command sent: \(command)")
        } else {
            Self.logger.error("MessageChannel.sendServerMessage failed for: \(command)")
        }
        return success
    }

    // MARK: - Scene phase

    func appScenePhaseChanged(to scenePhase: ScenePhase) {
        // If the app scene phase has changed to inactive, dismiss the immersive space as well.
        // This will automatically disconnect the session.
        if scenePhase == .background && immersiveSpaceIsOpen {
            Task { @MainActor in
                await dismissImmersiveSpace()
            }
        }
    }

    func windowScenePhaseChanged(to scenePhase: ScenePhase) {
        if scenePhase == .active {
            configWindowIsOpen = true
        } else if scenePhase == .background {
            // This may have false positives, hence before we re-open the window, we
            // make sure everything is closed.
            configWindowIsOpen = false
        }
    }

    @MainActor
    func onFirstWindowAppear(
        openImmersiveSpace: OpenImmersiveSpaceAction,
        dismissImmersiveSpace: DismissImmersiveSpaceAction,
        openWindow: OpenWindowAction,
        dismissWindow: DismissWindowAction
    ) {
        self.openImmersiveSpace = openImmersiveSpace
        self.dismissImmersiveSpace = dismissImmersiveSpace
        self.openWindow = openWindow
        self.dismissWindow = dismissWindow

        configWindowIsOpen = true

        // Make sure this happens before the IPD check.
        CloudXRKit.registerSystems()
    }
}
