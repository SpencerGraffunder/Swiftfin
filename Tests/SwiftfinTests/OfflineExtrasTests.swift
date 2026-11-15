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

/// Round-4 offline extras: which subtitle streams get persisted as sidecars
/// and how trickplay sheet counts are derived. Both are pure decisions that
/// previously only shipped-and-prayed could catch.
final class OfflineExtrasTests: XCTestCase {

    // MARK: - Subtitle candidates

    private func makeStream(
        type: MediaStreamType = .subtitle,
        isExternal: Bool?,
        isText: Bool?,
        codec: String? = "subrip"
    ) -> MediaStream {
        var stream = MediaStream()
        stream.type = type
        stream.isExternal = isExternal
        stream.isTextSubtitleStream = isText
        stream.codec = codec

        return stream
    }

    func testOnlyExternalTextSubtitlesAreCandidates() {
        let externalText = makeStream(isExternal: true, isText: true)
        let embeddedText = makeStream(isExternal: false, isText: true)
        let externalImage = makeStream(isExternal: true, isText: false)
        let externalAudio = makeStream(type: .audio, isExternal: true, isText: nil)

        var source = MediaSourceInfo()
        source.mediaStreams = [externalText, embeddedText, externalImage, externalAudio]

        let candidates = DownloadSubtitleSupport.candidates(in: source)

        // Embedded subs ride the media file; image subs don't render on
        // progressive files; anything not a subtitle is not a subtitle.
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.codec, "subrip")
    }

    func testSubtitleFormats() {
        XCTAssertEqual(DownloadSubtitleSupport.format(for: makeStream(isExternal: true, isText: true, codec: "subrip")), "srt")
        XCTAssertEqual(DownloadSubtitleSupport.format(for: makeStream(isExternal: true, isText: true, codec: "webvtt")), "vtt")
        XCTAssertEqual(DownloadSubtitleSupport.format(for: makeStream(isExternal: true, isText: true, codec: "ass")), "ass")
        XCTAssertNil(DownloadSubtitleSupport.format(for: makeStream(isExternal: true, isText: true, codec: "pgssub")))
        XCTAssertNil(DownloadSubtitleSupport.format(for: makeStream(isExternal: true, isText: true, codec: nil)))
    }

    // MARK: - Trickplay selection

    private func makeTrickplay(
        width: Int?,
        height: Int? = 72,
        columns: Int? = 5,
        rows: Int? = 5,
        interval: Int? = 10000
    ) -> TrickplayInfoDto {
        var info = TrickplayInfoDto()
        info.width = width
        info.height = height
        info.tileWidth = columns
        info.tileHeight = rows
        info.interval = interval

        return info
    }

    func testTrickplaySelectionPicksSmallestValidResolution() {
        var item = BaseItemDto()
        item.trickplay = [
            "ms-1": [
                "320": makeTrickplay(width: 320),
                "128": makeTrickplay(width: 128),
                "640": makeTrickplay(width: 640),
            ],
        ]

        let selected = DownloadTrickplaySupport.select(in: item, mediaSourceID: "ms-1")

        XCTAssertEqual(selected?.width, 128)
    }

    func testTrickplaySelectionSkipsInvalidEntries() {
        var item = BaseItemDto()
        item.trickplay = [
            "ms-1": [
                "0": makeTrickplay(width: 0),
                "nil-tiles": makeTrickplay(width: 100, columns: nil),
                "good": makeTrickplay(width: 256),
            ],
        ]

        let selected = DownloadTrickplaySupport.select(in: item, mediaSourceID: "ms-1")

        XCTAssertEqual(selected?.width, 256)
    }

    func testTrickplaySelectionNilWithoutMatchingMediaSource() {
        var item = BaseItemDto()
        item.trickplay = ["ms-1": ["128": makeTrickplay(width: 128)]]

        XCTAssertNil(DownloadTrickplaySupport.select(in: item, mediaSourceID: "ms-2"))
        XCTAssertNil(DownloadTrickplaySupport.select(in: item, mediaSourceID: nil))
        XCTAssertNil(DownloadTrickplaySupport.select(in: BaseItemDto(), mediaSourceID: "ms-1"))
    }

    // MARK: - Trickplay sheet count

    func testSheetCountDerivesFromRuntime() {
        // 10 s interval, one tile per sheet, 10 minutes of runtime
        // (10 min = 6_000_000_000 ticks) = 60 thumbs.
        let info = makeTrickplay(width: 128, columns: 1, rows: 1, interval: 10000)

        XCTAssertEqual(DownloadTrickplaySupport.sheetCount(info: info, runtimeTicks: 6_000_000_000), 60)
    }

    func testSheetCountDerivesFromThumbnailCount() {
        let info = makeTrickplay(width: 128, columns: 5, rows: 5)

        var withCount = info
        withCount.thumbnailCount = 250

        // 250 thumbnails / 25 tiles-per-sheet = 10 sheets.
        XCTAssertEqual(DownloadTrickplaySupport.sheetCount(info: withCount, runtimeTicks: nil), 10)
    }

    func testSheetCountIsCapped() {
        let info = makeTrickplay(width: 128, columns: 1, rows: 1, interval: 1000)

        // A 3-hour movie at 1 s intervals would be ~10k sheets; the cap
        // protects the downloads directory from a misconfigured server.
        XCTAssertEqual(DownloadTrickplaySupport.sheetCount(info: info, runtimeTicks: 108_000_000_000), 64)
    }
}
