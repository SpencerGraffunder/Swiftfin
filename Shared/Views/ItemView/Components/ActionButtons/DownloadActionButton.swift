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
    struct Download: View {

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

        @ViewBuilder
        private var downloadLabel: some View {
            if let download {
                switch download.state {
                case .downloading, .queued:
                    Label(L10n.downloading, systemImage: "arrow.down.circle")
                case .completed:
                    Label(L10n.downloaded, systemImage: "checkmark.circle.fill")
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

        @ViewBuilder
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

        @ViewBuilder
        private func stateMenu(for download: Download) -> some View {
            switch download.state {
            case .queued, .downloading:
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

            let options: DownloadOptions
            if selectedMethod == .direct {
                options = .direct(item)
            } else {
                options = .transcoded(bitrate: selectedBitrate, mediaSourceID: mediaSource?.id)
            }

            Task {
                await manager.download(item, options: options, mediaSource: mediaSource)
            }
        }

        /// Play a completed download offline from its local file (issue #1789).
        private func playDownload(_ download: Download) {
            let fileURL = download.fileURL
            let baseItem = download.item
            let mediaSource = download.mediaSource
            let bitrate = download.options.bitrate

            let provider = MediaPlayerItemProvider(
                item: baseItem,
                mediaSource: mediaSource,
                requestedBitrate: bitrate
            ) { _, _ in
                try await DownloadManager.makeOfflinePlaybackItem(
                    item: baseItem,
                    mediaSource: mediaSource,
                    fileURL: fileURL,
                    bitrate: bitrate
                )
            }

            router.route(to: .videoPlayer(provider: provider))
        }
    }
}
