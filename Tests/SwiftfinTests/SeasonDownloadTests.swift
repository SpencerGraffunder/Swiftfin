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

/// Regression tests for the "Download season" no-op and the
/// "second episode of a series never downloads" bugs.
///
/// Root cause recap: Jellyfin only returns `MediaSources` when the request
/// asks for the `MediaSources` field. The season request built for downloads
/// omitted it, so every returned episode failed the
/// `item.mediaSources?.isEmpty == false` gate and the season action silently
/// queued zero episodes.
final class SeasonDownloadTests: XCTestCase {

    private func makeEpisode(id: String, mediaSourceCount: Int? = 1) -> BaseItemDto {
        var episode = BaseItemDto()
        episode.id = id
        episode.name = "Episode \(id)"
        episode.type = .episode
        if let mediaSourceCount {
            episode.mediaSources = (0 ..< mediaSourceCount).map { index in
                var source = MediaSourceInfo()
                source.id = "\(id)-source-\(index)"
                return source
            }
        }

        return episode
    }

    private func makeDownload(id: String, state: DownloadState) -> Download {
        Download(
            item: makeEpisode(id: id),
            mediaSource: MediaSourceInfo(),
            options: .direct(makeEpisode(id: id)),
            fileName: "\(id).mp4",
            state: state
        )
    }

    // MARK: - Request shape

    func testEpisodesRequestTargetsTheGivenSeason() {
        let request = SeasonDownloads.episodesRequest(seasonID: "season-1", userID: "user-1")

        XCTAssertEqual(request.url?.path, "/Shows/season-1/Episodes")
    }

    func testEpisodesRequestAsksForTheMediaSourcesField() {
        // Without this the server omits MediaSources entirely and
        // `downloadableEpisodes` (rightly) rejects every episode.
        let request = SeasonDownloads.episodesRequest(seasonID: "season-1", userID: "user-1")

        let query = request.query ?? []

        func values(for name: String) -> [String] {
            query.filter { $0.0.caseInsensitiveCompare(name) == .orderedSame }.compactMap(\.1)
        }

        XCTAssertTrue(
            values(for: "fields").joined(separator: ",").contains("MediaSources"),
            "the season request must include the MediaSources field, got: \(values(for: "fields"))"
        )
        XCTAssertTrue(values(for: "seasonId").contains("season-1"))
        XCTAssertTrue(values(for: "userId").contains("user-1"))
    }

    // MARK: - Episode filtering

    func testEpisodesWithMediaSourcesAreQueued() {
        let items = [makeEpisode(id: "e1"), makeEpisode(id: "e2")]

        let result = SeasonDownloads.downloadableEpisodes(from: items, existing: { _ in nil })

        XCTAssertEqual(result.map(\.id), ["e1", "e2"])
    }

    func testEpisodesWithoutMediaSourcesAreRejected() {
        // Pre-fix server responses looked like this for every episode
        // (nil mediaSources), which is why the button appeared dead.
        let items = [
            makeEpisode(id: "e1", mediaSourceCount: nil),
            makeEpisode(id: "e2", mediaSourceCount: 0),
        ]

        let result = SeasonDownloads.downloadableEpisodes(from: items, existing: { _ in nil })

        XCTAssertTrue(result.isEmpty)
    }

    func testNonEpisodeItemsAreRejected() {
        var special = makeEpisode(id: "s1")
        special.type = .movie

        let result = SeasonDownloads.downloadableEpisodes(from: [special], existing: { _ in nil })

        XCTAssertTrue(result.isEmpty)
    }

    func testTrackedDownloadsAreSkippedButFailedOnesAreRetried() {
        let items = [makeEpisode(id: "e1"), makeEpisode(id: "e2"), makeEpisode(id: "e3"), makeEpisode(id: "e4")]

        let downloads: [String: Download] = [
            "e1": makeDownload(id: "e1", state: .completed),
            "e2": makeDownload(id: "e2", state: .downloading),
            "e3": makeDownload(id: "e3", state: .failed),
        ]

        let result = SeasonDownloads.downloadableEpisodes(from: items, existing: { downloads[$0 ?? ""] })

        // e1/e2 stay untouched (done / in flight), e3 is retried, e4 is new.
        XCTAssertEqual(result.compactMap(\.id), ["e3", "e4"])
    }
}
