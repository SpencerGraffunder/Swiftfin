//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Defaults
import SwiftUI

extension VideoPlayer {

    struct PlaybackControls: View {

        typealias ViewState = VideoPlayer.ViewState

        // since this view ignores safe area, it must
        // get safe area insets from parent views
        @Environment(\.safeAreaInsets)
        private var safeAreaInsets

        @Environment(ViewState.self)
        private var viewState
        @EnvironmentObject
        private var manager: MediaPlayerManager

        // TODO: do something with this value
        @State
        private var activeIsBuffering: Bool = false
        @State
        private var bottomContentFrame: CGRect = .zero

        private var isScrubbing: Bool {
            viewState.isScrubbing
        }

        // MARK: body

        var body: some View {
            ZStack {
                VStack {
                    Toolbar()
                        .frame(height: 50)
                        .isVisible(viewState.visibleElements.contains(.toolbar))
                        .enabled(viewState.visibleElements.contains(.toolbar))
                        .padding(.top, safeAreaInsets.top)
                        .padding(.leading, safeAreaInsets.leading)
                        .padding(.trailing, safeAreaInsets.trailing)
                        .offset(y: viewState.isPresentingControls ? 0 : -20)

                    Spacer()
                        .allowsHitTesting(false)

                    PlaybackProgress()
                        .isVisible(viewState.isPresentingProgress)
                        .enabled(viewState.isPresentingProgress)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, safeAreaInsets.leading)
                        .padding(.trailing, safeAreaInsets.trailing)
                        .trackingFrame($bottomContentFrame)
                        .background {
                            if viewState.isPresentingProgress {
                                EmptyHitTestView()
                            }
                        }
                        .background(alignment: .top) {
                            Color.black
                                .mask(gradient: .linear) {
                                    (location: 0, opacity: 0)
                                    (location: 1, opacity: 0.5)
                                }
                                .isVisible(isScrubbing)
                                .frame(height: bottomContentFrame.height + 50 + EdgeInsets.edgePadding * 2)
                        }
                }

                PlaybackButtons()
                    .isVisible(viewState.visibleElements.contains(.playbackButtons))
                    .enabled(viewState.visibleElements.contains(.playbackButtons))
            }
            // The overlay controls fade out after inactivity and, while faded, are
            // removed from the accessibility tree (opacity 0 + disabled), so a
            // VoiceOver user can no longer reach them or exit the player (issue
            // #1733). This button is present in the accessibility tree and tappable
            // whenever the overlay is faded, so it can always be reached to bring
            // the controls back — mirroring the native player's full-screen "show
            // controls" button. While the real controls are showing it is inert and
            // hidden from accessibility, so it neither steals their touches nor
            // adds a redundant element. It is invisible and small so sighted
            // users' taps on the video/scrubber are unaffected.
            .overlay(alignment: .topTrailing) {
                Button {
                    viewState.showControls()
                } label: {
                    Color.clear
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .opacity(0)
                .allowsHitTesting(!viewState.isPresentingControls)
                .accessibilityHidden(viewState.isPresentingControls)
                .accessibilityLabel(L10n.showPlayerControls)
                .accessibilityAddTraits(.isButton)
            }
            .modifier(VideoPlayer.KeyCommandsModifier())
            .animation(.linear(duration: 0.1), value: isScrubbing)
            .animation(.bouncy(duration: 0.4), value: viewState.isPresentingSupplement)
            .animation(.bouncy(duration: 0.25), value: viewState.presentation)
            .onChange(of: manager.proxy?.isBuffering.value) {
                activeIsBuffering = manager.proxy?.isBuffering.value ?? false
            }
            .disabled(manager.error != nil)
        }
    }
}
