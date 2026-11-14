//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Defaults
import FactoryKit
import Foundation
import JellyfinAPI
import SwiftUI
import Transmission

extension ItemActionButtons {

    /// The download action button (issue #1787).
    ///
    /// Presents a menu that changes with the download's state:
    /// - Not downloading: pick direct vs. transcoded + bitrate to start.
    /// - Queued / downloading: progress + pause + cancel.
    /// - Paused: resume + cancel.
    /// - Failed: retry + cancel.
    /// - Completed: play (offline) + delete.
    struct DownloadAction: View {

        @EnvironmentObject
        private var provider: ItemContentGroupProvider

        @ObservedObject
        private var manager: DownloadManager

        @Router
        private var router

        @State
        private var selectedMethod: DownloadOptions.Method = .direct
        @State
        private var selectedBitrate: PlaybackBitrate = .max

        init() {
            _manager = ObservedObject(wrappedValue: DownloadManager.shared)
            _selectedBitrate = State(initialValue: Defaults[.VideoPlayer.Playback.appMaximumBitrate])
        }

        private var item: BaseItemDto {
            provider.item
        }

        private var download: Download? {
            manager.download(for: item.id)
        }

        private var bitrates: [PlaybackBitrate] {
            item.mediaSources?.first?.supportedBitrates ?? PlaybackBitrate.videoBitrates
        }

        @ContentBuilder
        var body: some View {
            Menu {
                if let download {
                    stateMenu(for: download)
                } else {
                    newDownloadMenu
                }
            } label: {
                downloadLabel
            }
            .onFirstAppear {
                Task { await manager.start() }
            }
        }

        // MARK: - Label

        @ContentBuilder
        private var downloadLabel: some View {
            if let download {
                switch download.state {
                case .downloading, .queued:
                    // The bar renders icon-only, so the progress ring lives
                    // inside the glyph: same arrow.down.circle with a trim
                    // ring tracing the download's completion.
                    Label {
                        Text(L10n.downloadProgress(Int(download.progress * 100)))
                    } icon: {
                        Image(systemName: "arrow.down.circle")
                            .overlay {
                                Circle()
                                    .trim(from: 0, to: CGFloat(max(0.02, download.progress)))
                                    .stroke(style: StrokeStyle(lineWidth: 2, lineCap: .round))
                                    .foregroundStyle(.tint)
                                    .rotationEffect(.degrees(-90))
                            }
                    }

                case .completed:
                    // The download glyph stays visible with a small offset
                    // check badge on top, instead of swapping to a bare
                    // checkmark whose meaning was unclear.
                    Label {
                        Text(L10n.downloaded)
                    } icon: {
                        Image(systemName: "arrow.down.circle")
                            .overlay(alignment: .topTrailing) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 9, weight: .semibold))
                                    .background(Circle().fill(.background).padding(-1.5))
                                    .offset(x: 3, y: -2)
                            }
                    }

                case .paused:
                    Label(L10n.downloadPaused, systemImage: "pause.circle")

                case .failed:
                    Label(L10n.downloadFailed, systemImage: "exclamationmark.circle")
                }
            } else {
                Label(ItemActionButton.download.displayTitle, systemImage: ItemActionButton.download.systemImage)
            }
        }

        // MARK: - Menus

        @ContentBuilder
        private var newDownloadMenu: some View {
            Section(L10n.downloadOptions) {
                Picker(L10n.source, selection: $selectedMethod) {
                    Text(L10n.directPlay).tag(DownloadOptions.Method.direct)
                    Text(L10n.transcoded).tag(DownloadOptions.Method.transcoded)
                }
                .pickerStyle(.menu)

                if selectedMethod == .transcoded {
                    Picker(L10n.bitrate, selection: $selectedBitrate) {
                        ForEach(bitrates, id: \.rawValue) { bitrate in
                            Text(bitrate.displayTitle).tag(bitrate)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }

            Button(L10n.download, systemImage: "arrow.down") {
                startDownload()
            }
            .disabled(item.mediaSources?.isEmpty == true)
        }

        @ContentBuilder
        private func stateMenu(for download: Download) -> some View {
            switch download.state {
            case .queued, .downloading:
                if download.state == .downloading {
                    ProgressView(value: download.progress) {
                        Text(L10n.downloading)
                    }

                    Text(L10n.downloadProgress(Int(download.progress * 100)))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Button(L10n.pause, systemImage: "pause") {
                    manager.pause(download.id)
                }

                Button(L10n.cancel, systemImage: "xmark") {
                    manager.cancel(download.id)
                }

            case .paused:
                Button(L10n.resume, systemImage: "play") {
                    manager.resume(download.id)
                }

                Button(L10n.cancel, systemImage: "xmark") {
                    manager.cancel(download.id)
                }

            case .failed:
                Button(L10n.retry, systemImage: "arrow.clockwise") {
                    manager.retry(download.id)
                }

                Button(L10n.cancel, systemImage: "xmark") {
                    manager.cancel(download.id)
                }

            case .completed:
                Button(L10n.play, systemImage: "play.fill") {
                    playDownload(download)
                }

                Button(L10n.delete, systemImage: "trash", role: .destructive) {
                    manager.delete(download.id)
                }
            }
        }

        // MARK: - Actions

        private func startDownload() {
            let mediaSource = item.mediaSources?.first

            let options: DownloadOptions = if selectedMethod == .direct {
                .direct(item)
            } else {
                .transcoded(bitrate: selectedBitrate, mediaSourceID: mediaSource?.id)
            }

            Task {
                await manager.download(item, options: options, mediaSource: mediaSource)
            }
        }

        /// Play a completed download offline from its local file (issue #1789).
        ///
        /// The offline intent marker makes `MediaPlayerItemResolver` build the
        /// player item straight from the local file + stored media source, so
        /// no server round-trip (item fetch, playback-info, bitrate test or
        /// stream URL) is attempted — this must work in airplane mode.
        private func playDownload(_ download: Download) {
            guard let userSession = Container.shared.currentUserSession() else { return }

            var intent = PlaybackIntent(item: download.item)
            intent.offline = .init(fileURL: download.fileURL, mediaSource: download.mediaSource)

            let session = Container.shared.mediaPlayerManager().play(
                intent: intent,
                userSession: userSession
            )

            router.route(to: .videoPlayer(session: session))
        }
    }
}
