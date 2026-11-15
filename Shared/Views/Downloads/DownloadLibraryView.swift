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
import UIKit

/// The root view of the Downloads tab (issue #1789).
///
/// Lists all local downloads grouped by show, using the persisted item
/// metadata and the poster/backdrop images saved at download time, so the
/// list works fully offline (airplane mode). Rows carry the transfer details
/// users expect from a downloads screen — size on disk, transferred/total
/// bytes, speed and time left — support swipe-to-delete, and offer a
/// multi-select mode for bulk removal. Tapping a download opens the same
/// `ItemView` used for server items (via the `.item` route), which offers
/// offline playback of the local file.
struct DownloadLibraryView: View {

    @ObservedObject
    private var manager: DownloadManager

    @Router
    private var router

    @State
    private var isSelecting = false

    @State
    private var selectedIDs: Set<String> = []

    init() {
        _manager = ObservedObject(wrappedValue: DownloadManager.shared)
    }

    // MARK: - Grouping

    private struct DownloadSection: Identifiable {

        let id: String
        let title: String?
        let downloads: [Download]
    }

    private var sections: [DownloadSection] {
        var episodesBySeries: [String: [Download]] = [:]
        var standalone: [Download] = []

        for download in manager.downloads {
            if download.item.type == .episode, let series = download.item.seriesName {
                episodesBySeries[series, default: []].append(download)
            } else {
                standalone.append(download)
            }
        }

        var result = episodesBySeries
            .map { series, downloads in
                DownloadSection(
                    id: series,
                    title: series,
                    downloads: downloads.sorted { lhs, rhs in
                        let lSeason = lhs.item.parentIndexNumber ?? 0
                        let rSeason = rhs.item.parentIndexNumber ?? 0
                        guard lSeason == rSeason else { return lSeason < rSeason }
                        return (lhs.item.indexNumber ?? 0) < (rhs.item.indexNumber ?? 0)
                    }
                )
            }
            .sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }

        if !standalone.isEmpty {
            let isAllMovies = standalone.allSatisfy { $0.item.type == .movie }
            result.append(
                DownloadSection(
                    id: "\u{0}standalone",
                    title: isAllMovies ? L10n.movies : nil,
                    downloads: standalone.sorted { $0.item.displayTitle < $1.item.displayTitle }
                )
            )
        }

        return result
    }

    // MARK: - Body

    @ContentBuilder
    var body: some View {
        List {
            ForEach(sections) { section in
                if let title = section.title {
                    Section(title) {
                        rows(in: section)
                    }
                } else {
                    rows(in: section)
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if manager.downloads.isEmpty {
                ContentUnavailableView(
                    L10n.noDownloads,
                    systemImage: "arrow.down.circle",
                    description: Text(L10n.downloadsEmptySubtitle)
                )
            }
        }
        .navigationTitle(L10n.downloads)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if manager.downloads.isEmpty {
                    EmptyView()
                } else if isSelecting {
                    Button(L10n.done) {
                        exitSelection()
                    }
                } else {
                    Button(L10n.select) {
                        isSelecting = true
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting, !manager.downloads.isEmpty {
                selectionBar
            }
        }
        .onFirstAppear {
            Task { await manager.start() }
        }
    }

    @ContentBuilder
    private func rows(in section: DownloadSection) -> some View {
        ForEach(section.downloads) { download in
            DownloadRow(
                download: download,
                isSelecting: isSelecting,
                isSelected: selectedIDs.contains(download.id)
            )
            .contentShape(.rect)
            .onTapGesture {
                if isSelecting {
                    if selectedIDs.contains(download.id) {
                        selectedIDs.remove(download.id)
                    } else {
                        selectedIDs.insert(download.id)
                    }
                } else {
                    router.route(to: .item(item: download.item))
                }
            }
            .if(!isSelecting) { row in
                row.swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        manager.delete(download.id)
                    } label: {
                        Label(L10n.delete, systemImage: "trash")
                    }
                }
            }
        }
    }

    // MARK: - Selection

    private var selectionBar: some View {
        HStack {
            Button(L10n.selectAll) {
                selectedIDs = Set(manager.downloads.map(\.id))
            }

            Spacer()

            Button(role: .destructive) {
                manager.deleteAll(in: selectedIDs)
                exitSelection()
            } label: {
                Text(L10n.deleteSelection(selectedIDs.count))
            }
            .disabled(selectedIDs.isEmpty)
        }
        .font(.body)
        .padding(.horizontal)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private func exitSelection() {
        isSelecting = false
        selectedIDs = []
    }
}

// MARK: - Row

private struct DownloadRow: View {

    let download: Download
    let isSelecting: Bool
    let isSelected: Bool

    @ContentBuilder
    var body: some View {
        HStack(spacing: 12) {
            if isSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? .tint : .secondary)
                    .font(.title3)
            }

            DownloadPoster(download: download)
                .frame(width: 56, height: 84)
                .clipShape(.rect(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(download.item.displayTitle)
                    .font(.headline)
                    .lineLimit(2)

                if let locator = download.item.seasonEpisodeLabel {
                    Text(locator)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                statusText
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if let info = infoText {
                    info
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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

    // MARK: Transfer info (size / speed / time left)

    @ContentBuilder
    private var infoText: some View {
        switch download.state {
        case .queued, .downloading, .paused:
            HStack(spacing: 8) {
                if let written = download.bytesWritten, written > 0 {
                    if let total = download.totalBytesExpected, total > 0 {
                        Text(L10n.downloadBytesProgress(Self.bytes(written), Self.bytes(total)))
                    } else {
                        Text(Self.bytes(written))
                    }
                } else if let estimate = download.expectedFileSize {
                    Text(L10n.downloadEstimatedSize(Self.bytes(estimate)))
                }

                if download.state == .downloading, let speed = download.speedBytesPerSecond, speed > 1024 {
                    Text(L10n.downloadSpeed(Self.bytes(Int64(speed))))
                }

                if download.state == .downloading, let left = timeLeft, left > 0 {
                    Text(L10n.downloadTimeLeft(Self.duration(left)))
                }
            }

        case .completed:
            HStack(spacing: 8) {
                if let size = download.localFileSize ?? download.expectedFileSize {
                    Text(Self.bytes(size))
                }

                if let ticks = download.mediaSource.runTimeTicks, ticks > 0 {
                    Text(Self.duration(TimeInterval(ticks) / 10_000_000))
                }
            }

        case .failed:
            HStack(spacing: 8) {
                if let reason = download.failureReason {
                    Text(L10n.downloadFailedReason(reason))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                } else if let estimate = download.expectedFileSize {
                    Text(L10n.downloadEstimatedSize(Self.bytes(estimate)))
                }

                Button(L10n.retry) {
                    DownloadManager.shared.retry(download.id)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private var timeLeft: TimeInterval? {
        guard
            let total = download.totalBytesExpected, total > 0,
            let written = download.bytesWritten, total > written,
            let speed = download.speedBytesPerSecond, speed > 0
        else { return nil }

        return Double(total - written) / speed
    }

    @ContentBuilder
    private var statusText: some View {
        switch download.state {
        case .queued, .downloading:
            VStack(alignment: .leading, spacing: 4) {
                Label {
                    Text(
                        download.state == .downloading
                            ? L10n.downloadProgress(Int(download.progress * 100))
                            : L10n.downloading
                    )
                } icon: {
                    Image(systemName: "arrow.down")
                }

                ProgressView(value: download.progress)
                    .progressViewStyle(.linear)
            }

        case .completed:
            Label(L10n.downloaded, systemImage: "checkmark.circle")

        case .paused:
            Label(L10n.downloadPaused, systemImage: "pause.circle")

        case .failed:
            Label(L10n.downloadFailed, systemImage: "exclamationmark.circle")
        }
    }

    // MARK: Formatters

    private static func bytes(_ value: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: value)
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute]
        formatter.maximumUnitCount = 2
        formatter.zeroFormattingBehavior = .dropAll
        return formatter.string(from: seconds) ?? .emptyDash
    }
}

/// Shows the locally persisted poster image for a download when available,
/// falling back to the server image (or a placeholder) otherwise (issue #1789).
private struct DownloadPoster: View {

    let download: Download

    @ContentBuilder
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
