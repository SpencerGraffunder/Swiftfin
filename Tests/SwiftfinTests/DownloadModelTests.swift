//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import JellyfinAPI
@testable import Swiftfin
import XCTest

/// Model-level rules for the `Download` struct: the "playable offline" gate
/// (`localFileURL`), size reporting, on-disk layout and the direct-download
/// options factory. These rules decide whether the play button, the resolver
/// and the downloads list agree on an item being available offline.
final class DownloadModelTests: XCTestCase {

    private func makeItem(id: String = "item-1") -> BaseItemDto {
        var item = BaseItemDto()
        item.id = id
        item.name = "Item \(id)"
        item.type = .episode
        var source = MediaSourceInfo()
        source.id = "\(id)-source"
        item.mediaSources = [source]

        return item
    }

    private func makeDownload(
        id: String = "item-1",
        fileName: String = "movie.mp4",
        state: DownloadState = .queued
    ) -> Download {
        let item = makeItem(id: id)

        return Download(
            item: item,
            mediaSource: item.mediaSources!.first!,
            options: .direct(item),
            fileName: fileName,
            state: state
        )
    }

    // MARK: - Defaults & options

    func testFreshDownloadStartsQueued() {
        let download = makeDownload()

        XCTAssertEqual(download.state, .queued)
        XCTAssertEqual(download.progress, 0)
        XCTAssertEqual(download.id, "item-1")
    }

    func testDirectOptionsUseFirstMediaSource() throws {
        var item = makeItem()
        var second = MediaSourceInfo()
        second.id = "source-2"
        item.mediaSources = try [XCTUnwrap(makeItem().mediaSources?.first), second]

        let options = DownloadOptions.direct(item)

        XCTAssertEqual(options.method, .direct)
        XCTAssertEqual(options.mediaSourceID, "item-1-source")
    }

    // MARK: - localFileURL: the single "playable offline" gate

    func testLocalFileURLNilWhileNotCompleted() throws {
        let download = makeDownload(id: "not-done-\(UUID().uuidString)", state: .downloading)

        // Even with a file present, a non-completed download is never
        // treated as playable (partial files can exist on resume).
        try Data("x".utf8).write(to: download.fileURL, options: .atomic)
        addTeardownBlock { try? FileManager.default.removeItem(at: download.fileURL) }

        XCTAssertNil(download.localFileURL)
    }

    func testLocalFileURLNilWhenFileMissing() {
        let download = makeDownload(id: "ghost-\(UUID().uuidString)", state: .completed)

        // A completed record whose file was deleted off disk (user cleanup,
        // storage eviction) must not advertise itself as playable.
        XCTAssertFalse(FileManager.default.fileExists(atPath: download.fileURL.path))
        XCTAssertNil(download.localFileURL)
        XCTAssertNil(download.localFileSize)
    }

    func testLocalFileURLAndSizeWhenCompletedOnDisk() throws {
        let download = makeDownload(id: "done-\(UUID().uuidString)", state: .completed)

        let payload = Data(repeating: 0xAB, count: 1234)
        try FileManager.default.createDirectory(at: download.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try payload.write(to: download.fileURL, options: .atomic)
        addTeardownBlock { try? FileManager.default.removeItem(at: download.fileURL) }

        var stored = download
        stored.state = .completed

        XCTAssertEqual(stored.localFileURL, stored.fileURL)
        XCTAssertEqual(stored.localFileSize, 1234)
        XCTAssertEqual(stored.expectedFileSize, 1234)
    }

    // MARK: - Size expectations

    func testExpectedFileSizePrefersTransferBytes() {
        var download = makeDownload()
        download.bytesWritten = 500
        download.totalBytesExpected = 9000

        XCTAssertEqual(download.expectedFileSize, 9000)
    }

    func testExpectedFileSizeEstimatesFromBitrateAndRuntime() {
        var download = makeDownload()
        download.mediaSource.bitrate = 8_000_000 // bits per second
        download.mediaSource.runTimeTicks = 600_000_000 // 60 seconds

        // 8_000_000 bps * 60 s / 8 = 60 MB.
        XCTAssertEqual(download.expectedFileSize, 60_000_000)
    }

    // MARK: - On-disk layout

    func testFileURLLivesInTheDownloadsDirectory() {
        let download = makeDownload(fileName: "episode.mp4")

        XCTAssertEqual(download.fileURL.lastPathComponent, "episode.mp4")
        XCTAssertEqual(
            download.fileURL.deletingLastPathComponent(),
            DownloadStorage.directory
        )
    }

    func testSidecarURLsIncludeDownloadID() {
        let download = makeDownload(id: "sidecar-1")

        XCTAssertTrue(download.posterImageURL.lastPathComponent.hasPrefix("sidecar-1"))
        XCTAssertTrue(download.backdropImageURL.lastPathComponent.hasPrefix("sidecar-1"))
        XCTAssertTrue(download.subtitleDirectoryURL.absoluteString.contains("sidecar-1"))
    }
}
