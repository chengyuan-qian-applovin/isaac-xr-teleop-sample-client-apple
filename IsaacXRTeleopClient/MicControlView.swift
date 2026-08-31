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

/// Toggle + status for streaming the headset microphone to the teleop server
/// (voice commands, transcribed server-side — see `MicStreamer`). Streaming
/// follows the CloudXR session automatically; the toggle just opts out.
struct MicControlView: View {
    @State var viewModel: ViewModel

    var body: some View {
        Section(header: HStack {
            Text("Voice Microphone").font(.title2)
            Spacer()
        }) {
            VStack {
                Toggle("Stream microphone", isOn: $viewModel.micEnabled)
                    .font(.title3)
                HStack {
                    Text(viewModel.statusText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    ProgressView(value: viewModel.level)
                        .frame(width: 120)
                        .tint(.green)
                }
            }
        }
        .padding()
    }
}

extension MicControlView {
    @Observable
    class ViewModel {
        private let appModel: AppModel

        init(appModel: AppModel) {
            self.appModel = appModel
        }

        var micEnabled: Bool {
            get { appModel.micEnabled }
            set { appModel.micEnabled = newValue }
        }

        var statusText: String {
            appModel.micStreamer.status
        }

        var level: Float {
            appModel.micStreamer.level
        }
    }
}

#Preview {
    MicControlView(viewModel: MicControlView.ViewModel(appModel: AppModel()))
}
