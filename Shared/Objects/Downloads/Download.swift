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

    init(
        method: Method,
        bitrate: PlaybackBitrate,
        mediaSourceID: String?
    ) {
        self.method = method
        self.bitrate = bitrate
        self.mediaSourceID = mediaSourceID
    }

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
