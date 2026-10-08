//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Defaults
import JellyfinAPI
import SwiftUI

/// The root view of the Downloads tab (issue #1789).
///
/// Lists all local downloads using the persisted item metadata and the poster
/// images saved at download time, so the list works fully offline. Tapping a
/// download opens the same `ItemView` used for server items (via the `.item`
/// route), which now offers offline playback of the local file.
struct DownloadLibraryView: View {

    @ObservedObject
    private var manager: DownloadManager

    @Router
    private var router

    init() {
        _manager = ObservedObject(wrappedValue: DownloadManager.shared)
    }

    var body: some View {
        Group {
            if manager.hasAnyDownloads {
                List {
                    ForEach(manager.downloads) { download in
                        DownloadRow(download: download)
                            .contentShape(.rect)
                            .onTapGesture {
                                router.route(to: .item(item: download.item))
                            }
                    }
                }
                .listStyle(.plain)
                .onFirstAppear {
                    Task { await manager.start() }
                }
            } else {
                EmptyView()
                    .contentTransition(.blurReplace)
                    .overlay {
                        ContentUnavailableView(
                            L10n.noDownloads,
                            systemImage: "arrow.down.circle",
                            description: Text(L10n.downloadsEmptySubtitle)
                        )
                    }
            }
        }
        .navigationTitle(L10n.downloads)
    }
}

private struct DownloadRow: View {

    let download: Download

    var body: some View {
        HStack(spacing: 12) {
            DownloadPoster(download: download)
                .frame(width: 56, height: 84)
                .clipShape(.rect(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(download.item.displayTitle)
                    .font(.headline)
                    .lineLimit(2)

                statusText
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(download.item.displayTitle), \(statusTitle)")
    }

    private var statusTitle: String {
        switch download.state {
        case .queued, .downloading:
            L10n.downloading
        case .completed:
            L10n.downloaded
        case .paused:
            L10n.downloadPaused
        case .failed:
            L10n.downloadFailed
        }
    }

    @ViewBuilder
    private var statusText: some View {
        switch download.state {
        case .queued, .downloading:
            Label(L10n.downloading, systemImage: "arrow.down")
        case .completed:
            Label(L10n.downloaded, systemImage: "checkmark.circle")
        case .paused:
            Label(L10n.downloadPaused, systemImage: "pause.circle")
        case .failed:
            Label(L10n.downloadFailed, systemImage: "exclamationmark.circle")
        }
    }
}

/// Shows the locally persisted poster image for a download when available,
/// falling back to the server image (or a placeholder) otherwise (issue #1789).
private struct DownloadPoster: View {

    let download: Download

    var body: some View {
        if FileManager.default.fileExists(atPath: download.posterImageURL.path) {
            Image(uiImage: UIImage(contentsOfFile: download.posterImageURL.path) ?? UIImage())
                .resizable()
                .scaledToFill()
        } else {
            PosterImage(
                item: download.item,
                type: .portrait,
                size: .small
            )
        }
    }
}
