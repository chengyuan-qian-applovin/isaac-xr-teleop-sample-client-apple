// SPDX-FileCopyrightText: Copyright (c) 2023-2024 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: LicenseRef-NvidiaProprietary
//
// NVIDIA CORPORATION, its affiliates and licensors retain all intellectual
// property and proprietary rights in and to this material, related
// documentation and any modifications thereto. Any use, reproduction,
// disclosure or distribution of this material and related documentation
// without an express license agreement from NVIDIA CORPORATION or
// its affiliates is strictly prohibited.

import SwiftUI
import CloudXRKit
import os.log

struct TeleopControlView: View {
    @State var viewModel: ViewModel

    var body: some View {
        Section(header: HStack {
            Text("Teleoperation Controls").font(.title2)
            Spacer()
        }) {
            VStack {
                HStack {
                    Button {
                        viewModel.teleopStartButtonPressed()
                    } label: {
                        HStack {
                            Image(systemName: viewModel.teleopStartButtonImage)
                            Text(viewModel.teleopStartButtonText)
                        }
                        .frame(width: viewModel.teleopButtonWidth)
                    }
                    .font(.title3)
                    .buttonStyle(.bordered)
                    .disabled(viewModel.teleopStartButtonDisabled)

                    Button {
                        viewModel.teleopStopButtonPressed()
                    } label: {
                        HStack {
                            Image(systemName: viewModel.teleopStopButtonImage)
                            Text(viewModel.teleopStopButtonText)
                        }
                        .frame(width: viewModel.teleopButtonWidth)
                    }
                    .font(.title3)
                    .buttonStyle(.bordered)
                    .disabled(viewModel.teleopStopButtonDisabled)
                }
                Divider()
                HStack {
                    Button {
                        viewModel.teleopResetButtonPressed()
                    } label: {
                        HStack {
                            Image(systemName: viewModel.teleopResetButtonImage)
                            Text(viewModel.teleopResetButtonText)
                        }
                        .frame(width: viewModel.teleopButtonWidth)
                    }
                    .font(.title3)
                    .buttonStyle(.bordered)

                    Button {
                        viewModel.teleopAlignButtonPressed()
                    } label: {
                        HStack {
                            Image(systemName: viewModel.teleopAlignButtonImage)
                            Text(viewModel.teleopAlignButtonText)
                        }
                        .frame(width: viewModel.teleopButtonWidth)
                    }
                    .font(.title3)
                    .buttonStyle(.bordered)
                }
            }
            .frame(height: 100, alignment: .top)
        }
        .padding()
    }
}

extension TeleopControlView {
    @Observable
    class ViewModel {
        @ObservationIgnored static let logger = Logger()
        private let appModel: AppModel

        private let startTeleopCommand = "start teleop"
        private let stopTeleopCommand = "stop teleop"
        private let resetTeleopCommand = "reset teleop"
        // "align" is dispatched by the TACO teleop script's TeleopCommandBridge;
        // it must not contain the start/stop/reset substrings the stock
        // OpenXRDevice handler matches on.
        private let alignTeleopCommand = "align scene"

        var teleopRunning: Bool {
            get { appModel.teleopRunning }
            set { appModel.teleopRunning = newValue }
        }

        init(appModel: AppModel) {
            self.appModel = appModel
        }

        func sendTeleopCommandToServer(command: String) {
            let teleopCommand = ClientToServerCommand(
                type: "teleop_command",
                message: [
                    "command": command
                ]
            )
            let jsonEncoder = JSONEncoder()
            if let jsonCommand = try? jsonEncoder.encode(teleopCommand) {
                appModel.cxrSession.sendServerMessage(jsonCommand)
                Self.logger.info("Teleop command sent: \(command)")
            } else {
                Self.logger.error("JSON encoding failed.")
            }
        }

        func teleopStartButtonPressed() {
            teleopRunning = true
            sendTeleopCommandToServer(command: startTeleopCommand)
        }

        func teleopStopButtonPressed() {
            teleopRunning = false
            sendTeleopCommandToServer(command: stopTeleopCommand)
        }

        func teleopResetButtonPressed() {
            sendTeleopCommandToServer(command: resetTeleopCommand)
        }

        func teleopAlignButtonPressed() {
            sendTeleopCommandToServer(command: alignTeleopCommand)
        }

        var teleopStartButtonText: String {
            "Play"
        }

        var teleopButtonWidth: CGFloat {
            190
        }

        var teleopStartButtonImage: String {
            "play.circle"
        }

        var teleopStopButtonImage: String {
            "stop.circle"
        }

        var teleopResetButtonImage: String {
            "arrow.counterclockwise.circle"
        }

        var teleopResetButtonText: String {
            "Reset"
        }

        var teleopAlignButtonImage: String {
            "scope"
        }

        var teleopAlignButtonText: String {
            "Align"
        }

        var teleopStopButtonText: String {
            "Stop"
        }

        var teleopStartButtonDisabled: Bool {
            teleopRunning
        }

        var teleopStopButtonDisabled: Bool {
            !teleopRunning
        }
    }
}
