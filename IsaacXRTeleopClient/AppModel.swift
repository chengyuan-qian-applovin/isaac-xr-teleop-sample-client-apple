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

    let hmdProperties = HmdProperties()

    let sessionEntity = Entity()

    static private let savedSettings = SavedSettings()

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

    /// Episode index of a pending server-side "was this recording a success?" request.
    /// Non-nil while the Success/Failure sheet should be shown.
    var recordResultEpisode: Int?

    /// Consumes the session's server message stream for server-initiated messages.
    @ObservationIgnored private var messageReceiveTask: Task<Void, Never>?

    var ipAddress = savedSettings.ipAddress {
        didSet {
            Self.savedSettings.ipAddress = ipAddress
        }
    }

    // MARK: - Server-initiated messages

    /// Listen for server->client messages. The Isaac Lab side pushes
    /// `omni.kit.cloudxr.send_message` carb events whose `message` field arrives
    /// here as the raw message bytes. Started on connect, stopped on disconnect.
    func startMessageReceiveTask() {
        messageReceiveTask?.cancel()
        messageReceiveTask = Task { [weak self] in
            guard let stream = self?.cxrSession.serverMessageStream else { return }
            for await data in stream {
                guard !Task.isCancelled else { return }
                self?.handleServerMessage(data)
            }
        }
    }

    func stopMessageReceiveTask() {
        messageReceiveTask?.cancel()
        messageReceiveTask = nil
        recordResultEpisode = nil
        teleopRunning = false
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

    /// After the Success/Failure choice: mirror the operator pressing Stop then
    /// Reset, so the scene resets for the next episode and the client UI state
    /// (teleopRunning) matches the server, which already paused at the gesture.
    /// The server exports the episode before handling the reset, so this
    /// back-to-back burst is safe.
    func finishEpisodeCleanup() {
        teleopRunning = false
        sendTeleopCommand("stop teleop")
        sendTeleopCommand("reset teleop")
    }

    /// Send a teleop command (fire-and-forget) — usable from any view, including
    /// the Success/Failure sheet.
    func sendTeleopCommand(_ command: String) {
        let teleopCommand = ClientToServerCommand(type: "teleop_command", message: ["command": command])
        guard let jsonCommand = try? JSONEncoder().encode(teleopCommand) else {
            Self.logger.error("JSON encoding failed.")
            return
        }
        cxrSession.sendServerMessage(jsonCommand)
        Self.logger.info("Teleop command sent: \(command)")
    }

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

        hmdProperties.beginIpdCheck(
            openImmersiveSpace: openImmersiveSpace
        )
    }
}
