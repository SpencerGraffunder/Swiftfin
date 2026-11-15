//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
import JellyfinAPI

// MARK: - State

/// The lifecycle state of a download. Kept as a raw-valued `Codable` enum
/// (with `progress` stored separately) so the queue can be persisted without
/// associated-value `Codable` synthesis.
enum DownloadState: String, Codable, Sendable {

    case queued
    case downloading
    case paused
    case completed
    case failed
}

// MARK: - Options

/// The options used to download an item (issue #1785).
///
/// Two ways to create one:
/// - `DownloadOptions.direct(item:)` — direct-play / direct-stream the
///   item's first playable media source (no server transcoding).
/// - `DownloadOptions.transcoded(...)` — download a server-transcoded stream
///   at a chosen bitrate and media source.
struct DownloadOptions: Codable, Hashable, Sendable {

    /// Whether the item is downloaded via a direct (non-transcoded) stream or
    /// a server transcoded stream.
    enum Method: String, Codable, Sendable {

        case direct
        case transcoded
    }

    var method: Method
    var bitrate: PlaybackBitrate
    var mediaSourceID: String?

    /// A direct-play / direct-stream download of the item's first playable
    /// media source.
    static func direct(_ item: BaseItemDto) -> DownloadOptions {
        .init(
            method: .direct,
            bitrate: .auto,
            mediaSourceID: item.mediaSources?.first?.id
        )
    }

    /// A server-transcoded download at the given bitrate and media source.
    static func transcoded(
        bitrate: PlaybackBitrate = .max,
        mediaSourceID: String?
    ) -> DownloadOptions {
        .init(
            method: .transcoded,
            bitrate: bitrate,
            mediaSourceID: mediaSourceID
        )
    }
}

// MARK: - Download

/// A single download tracked by `DownloadManager` (issue #1784).
///
/// The full item (`BaseItemDto`) and its selected media source
/// (`MediaSourceInfo`) are both `Codable`/`Hashable` in the SDK, so they are
/// stored alongside the download and reused for offline metadata, images, and
/// playback without a server round-trip (issue #1789).
struct Download: Codable, Identifiable, Hashable, Sendable {

    let id: String
    var item: BaseItemDto
    var mediaSource: MediaSourceInfo
    var options: DownloadOptions

    /// The file name (including extension) of the downloaded media within the
    /// downloads directory.
    var fileName: String

    var state: DownloadState
    var progress: Double
    let createdAt: Date

    /// The on-disk media file URL for this download.
    var fileURL: URL {
        DownloadStorage.directory.appending(path: fileName)
    }

    /// The on-disk poster image URL for this download (persisted at download
    /// time so the item has a poster while offline).
    var posterImageURL: URL {
        DownloadStorage.imageDirectory.appending(path: "\(id)-poster")
    }

    /// The on-disk backdrop (landscape preview) image URL, persisted alongside
    /// the poster so episode/series previews render in airplane mode.
    var backdropImageURL: URL {
        DownloadStorage.imageDirectory.appending(path: "\(id)-backdrop")
    }

    /// The local media file URL, but only when the download is completed and
    /// the file is actually on disk — the single source of truth for
    /// "playable offline" checks (play button, resolver, downloads list).
    var localFileURL: URL? {
        guard state == .completed, FileManager.default.fileExists(atPath: fileURL.path) else { return nil }

        return fileURL
    }

    /// The actual size of the downloaded file on disk, when present.
    var localFileSize: Int64? {
        guard let url = localFileURL else { return nil }

        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return values?.fileSize.map(Int64.init)
    }

    /// The expected total size of the download: the on-disk size when
    /// finished, else the bytes reported by the transfer, else an estimate
    /// from the media source bitrate and runtime.
    var expectedFileSize: Int64? {
        if let actual = localFileSize {
            return actual
        }
        if let bytes = bytesWritten, bytes > 0 {
            return totalBytesExpected ?? bytes
        }
        guard let bitrate = mediaSource.bitrate,
              bitrate > 0,
              let ticks = mediaSource.runTimeTicks,
              ticks > 0
        else { return nil }

        // ticks/10_000_000 = seconds; multiply first to stay in Int64 range.
        return Int64(bitrate) * (Int64(ticks) / 10_000_000) / 8
    }

    /// Bytes written so far in the active transfer (live while downloading).
    var bytesWritten: Int64?

    /// Total bytes expected in the active transfer (nil for chunked/unknown
    /// length responses).
    var totalBytesExpected: Int64?

    /// Smoothed transfer speed in bytes/second (live while downloading).
    var speedBytesPerSecond: Double?

    /// Human-readable cause when `state == .failed` (round 3). Optional and
    /// decoded-nil for downloads persisted before this field existed.
    var failureReason: String?

    init(
        item: BaseItemDto,
        mediaSource: MediaSourceInfo,
        options: DownloadOptions,
        fileName: String,
        state: DownloadState = .queued,
        progress: Double = 0,
        createdAt: Date = .now
    ) {
        self.id = item.id ?? UUID().uuidString
        self.item = item
        self.mediaSource = mediaSource
        self.options = options
        self.fileName = fileName
        self.state = state
        self.progress = progress
        self.createdAt = createdAt
    }
}

// MARK: - Storage

/// The on-disk storage layout for local downloads (issue #1784/#1789).
///
/// Media files and their poster images are stored under the app's Application
/// Support directory so they survive relaunches and are not purged with the
/// system's temporary files.
enum DownloadStorage {

    /// The directory that stores downloaded media files.
    static var directory: URL {
        makeDirectory("Downloads")
    }

    /// The directory that stores persisted poster images.
    static var imageDirectory: URL {
        makeDirectory("DownloadImages")
    }

    private static func makeDirectory(_ name: String) -> URL {
        let fileManager = FileManager.default
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let url = base.appendingPathComponent(name, isDirectory: true)

        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)

        return url
    }
}
