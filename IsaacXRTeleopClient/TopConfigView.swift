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
import RealityKit
import CloudXRKit

let configViewTitle = "IsaacSimTeleopConfigViewWindowGroup"

struct TopConfigView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State var viewModel: ViewModel

    var body: some View {
        VStack {
                VStack {
                    switch viewModel.uiPage {
                    case .main: mainPage
                    case .hud:
                            List {
                                HUDView(session: viewModel.cxrSession, hudConfig: viewModel.hudConfig)
                            }
                    }
                }.ornament(
                    visibility: viewModel.showOrnaments ? .visible : .hidden,
                    attachmentAnchor: .scene(.bottom)
                ) {
                    HStack {
                        Button("Main") { viewModel.uiPage = .main }
                        Button("HUD") { viewModel.uiPage = .hud }
                    }
                }
                .onChange(of: scenePhase) {
                    viewModel.scenePhaseChanged(to: scenePhase)
                }
                .sheet(isPresented: Binding(
                    get: { viewModel.appModel.recordResultEpisode != nil },
                    set: { if !$0 { viewModel.appModel.recordResultEpisode = nil } }
                )) {
                    recordResultSheet
                }
        }
    }

    /// Server-initiated prompt after the stop-recording hand gesture: mark the
    /// just-finished episode as a success or a failure. Labels are single words
    /// so visionOS Voice Control can press them by name.
    private var recordResultSheet: some View {
        VStack(spacing: 24) {
            Text("Recording finished")
                .font(.extraLargeTitle2)
            if let episode = viewModel.appModel.recordResultEpisode, episode >= 0 {
                Text("Episode \(episode) — keep it as a success or a failure?")
                    .font(.title3)
            }
            HStack(spacing: 24) {
                Button {
                    viewModel.appModel.sendTeleopCommand("record_success")
                    viewModel.appModel.recordResultEpisode = nil
                } label: {
                    Label("Success", systemImage: "checkmark.circle")
                        .frame(width: 190)
                }
                .font(.title3)
                .buttonStyle(.borderedProminent)

                Button {
                    viewModel.appModel.sendTeleopCommand("record_failure")
                    viewModel.appModel.recordResultEpisode = nil
                } label: {
                    Label("Failure", systemImage: "xmark.circle")
                        .frame(width: 190)
                }
                .font(.title3)
                .buttonStyle(.bordered)
            }
        }
        .padding(32)
        .interactiveDismissDisabled()
    }

    private var mainPage: some View {
        VStack {
            HStack {
                Spacer()
                Text("Main").font(.extraLargeTitle2)
                Spacer()
            }
            .frame(height: 50, alignment: .top).padding()

            if viewModel.showTeleopView {
                VStack {
                    TeleopControlView(viewModel: TeleopControlView.ViewModel(appModel: viewModel.appModel))
                        .frame(alignment: .top)
                }
                .frame(height: 200, alignment: .top)
            }

            VStack {
                StreamingControlsView(viewModel: StreamingControlsView.ViewModel(appModel: viewModel.appModel))
                    .frame(alignment: .top)
            }
            .frame(height: 150, alignment: .top)
        }
        .frame(alignment: .top)
    }
}

extension TopConfigView {
    @Observable
    class ViewModel {
        enum UiPage: String, CaseIterable {
            case main = "Main"
            case hud = "Heads-Up Display"
        }

        // Defined for convenience for the HUD.
        let cxrSession: CloudXRSession

        // View-model logic will write to the appModel when UI buttons are pressed.
        let appModel: AppModel

        init(appModel: AppModel) {
            cxrSession = appModel.cxrSession
            self.appModel = appModel
        }

        func scenePhaseChanged(to newValue: ScenePhase) {
            appModel.windowScenePhaseChanged(to: newValue)
        }

        // View-local state.
        var uiPage: UiPage = .main

        let hudConfig = HUDConfig()

        var showOrnaments: Bool {
            return cxrSession.state == .connected
        }

        var showTeleopView: Bool {
            return cxrSession.state == .connected
        }
    }
}

#Preview(windowStyle: .automatic) {
    TopConfigView(viewModel: TopConfigView.ViewModel(appModel: AppModel()))
}
