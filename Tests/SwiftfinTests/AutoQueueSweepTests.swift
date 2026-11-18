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

/// Pins the rolling auto-queue window semantics (round 7): keep
/// `downloadsAutoQueueNext` episodes in flight per downloaded series,
/// anchored at the furthest tracked episode.
final class AutoQueueSweepTests: XCTestCase {

    private func makeEpisode(id: String, season: Int, episode: Int, seriesID: String = "series-1") -> BaseItemDto {
        var item = BaseItemDto()
        item.id = id
        item.name = "S\(season)E\(episode)"
        item.type = .episode
        item.seriesID = seriesID
        item.parentIndexNumber = season
        item.indexNumber = episode
        item.mediaSources = [MediaSourceInfo()]

        return item
    }

    private func makeDownload(_ item: BaseItemDto, state: DownloadState) -> Download {
        Download(
            item: item,
            mediaSource: MediaSourceInfo(),
            options: .direct(item),
            fileName: "\(item.id ?? "x").mp4",
            state: state
        )
    }

    // MARK: - Anchor

    func testAnchorIsFurthestTrackedEpisodeAcrossSeasons() {
        let s1e2 = makeEpisode(id: "s1e2", season: 1, episode: 2)
        let s1e9 = makeEpisode(id: "s1e9", season: 1, episode: 9)
        let s2e1 = makeEpisode(id: "s2e1", season: 2, episode: 1)

        let tracked = [
            makeDownload(s1e2, state: .completed),
            makeDownload(s2e1, state: .queued),
            makeDownload(s1e9, state: .downloading),
        ]

        XCTAssertEqual(AutoQueueSweep.anchor(in: tracked)?.id, "s2e1")
    }

    func testAnchorIncludesFailedDownloadsSoTheWindowMovesForward() {
        let done = makeEpisode(id: "e1", season: 1, episode: 1)
        let broken = makeEpisode(id: "e2", season: 1, episode: 2)

        let tracked = [
            makeDownload(done, state: .completed),
            makeDownload(broken, state: .failed),
        ]

        // The failed episode still anchors the window: the sweep queues
        // forward of it instead of re-walking the series.
        XCTAssertEqual(AutoQueueSweep.anchor(in: tracked)?.id, "e2")
    }

    // MARK: - Pending count

    func testPendingCountsOnlyInFlightStates() {
        let tracked: [Download] = [
            makeDownload(makeEpisode(id: "a", season: 1, episode: 1), state: .completed),
            makeDownload(makeEpisode(id: "b", season: 1, episode: 2), state: .queued),
            makeDownload(makeEpisode(id: "c", season: 1, episode: 3), state: .downloading),
            makeDownload(makeEpisode(id: "d", season: 1, episode: 4), state: .paused),
            makeDownload(makeEpisode(id: "e", season: 1, episode: 5), state: .failed),
        ]

        // queued + downloading + paused fill the window; completed/failed free it.
        XCTAssertEqual(AutoQueueSweep.pendingCount(in: tracked), 3)
    }

    // MARK: - Candidates

    func testCandidatesStartStrictlyAfterTheAnchor() {
        let episodes = (1 ... 6).map { makeEpisode(id: "e\($0)", season: 1, episode: $0) }
        let anchor = AutoQueueSweep.position(of: episodes[1]) // E2

        let picked = AutoQueueSweep.candidates(
            from: episodes,
            after: anchor,
            excluding: ["e1", "e2"],
            limit: 2
        )

        XCTAssertEqual(picked.compactMap(\.id), ["e3", "e4"])
    }

    func testCandidatesSortUnsortedServerResponses() {
        let episodes = [
            makeEpisode(id: "e5", season: 1, episode: 5),
            makeEpisode(id: "e3", season: 1, episode: 3),
            makeEpisode(id: "e4", season: 1, episode: 4),
        ]
        let anchor = AutoQueueSweep.EpisodePosition(season: 1, episode: 2)

        let picked = AutoQueueSweep.candidates(from: episodes, after: anchor, excluding: [], limit: 3)

        XCTAssertEqual(picked.compactMap(\.id), ["e3", "e4", "e5"])
    }

    func testCandidatesWithoutAnchorPickFromSeriesStart() {
        let episodes = [makeEpisode(id: "e2", season: 1, episode: 2), makeEpisode(id: "e1", season: 1, episode: 1)]

        let picked = AutoQueueSweep.candidates(from: episodes, after: nil, excluding: ["e1"], limit: 5)

        XCTAssertEqual(picked.compactMap(\.id), ["e2"])
    }

    func testLaterSeasonEpisodesSortAfterEarlierSeasons() {
        let anchor = AutoQueueSweep.EpisodePosition(season: 1, episode: 24)
        let seasonTwo = [makeEpisode(id: "s2e1", season: 2, episode: 1), makeEpisode(id: "s2e2", season: 2, episode: 2)]

        let picked = AutoQueueSweep.candidates(from: seasonTwo, after: anchor, excluding: [], limit: 1)

        XCTAssertEqual(picked.compactMap(\.id), ["s2e1"])
    }

    func testZeroLimitNeverQueues() {
        let episodes = (1 ... 3).map { makeEpisode(id: "e\($0)", season: 1, episode: $0) }

        XCTAssertTrue(AutoQueueSweep.candidates(from: episodes, after: nil, excluding: [], limit: 0).isEmpty)
    }

    // MARK: - Window simulation (the rolling behaviour end to end)

    func testWindowRollsAsEpisodesComplete() {
        let episodes = (1 ... 8).map { makeEpisode(id: "e\($0)", season: 1, episode: $0) }
        var byID: [String: BaseItemDto] = [:]
        for episode in episodes {
            if let id = episode.id {
                byID[id] = episode
            }
        }
        let n = 3

        // Spec's initial state: one downloaded episode, nothing else.
        var downloads: [String: Download] = [:]
        if let first = byID["e1"] {
            downloads["e1"] = makeDownload(first, state: .completed)
        }

        func sweep() -> [String] {
            let tracked = Array(downloads.values)
            let slots = n - AutoQueueSweep.pendingCount(in: tracked)
            guard slots > 0, let anchorItem = AutoQueueSweep.anchor(in: tracked) else { return [] }

            let next = AutoQueueSweep.candidates(
                from: episodes,
                after: AutoQueueSweep.position(of: anchorItem),
                excluding: Set(downloads.keys),
                limit: slots
            )

            return next.compactMap(\.id)
        }

        // First sweep fills the window to N past the completed episode.
        XCTAssertEqual(sweep(), ["e2", "e3", "e4"])
        for id in sweep() {
            if let episode = byID[id] {
                downloads[id] = makeDownload(episode, state: .queued)
            }
        }

        // Window full → another sweep adds nothing (no unbounded growth).
        XCTAssertTrue(sweep().isEmpty)

        // e2 completes (e.g. overnight): the window slides by exactly one.
        downloads["e2"]?.state = .completed
        XCTAssertEqual(sweep(), ["e5"])
        if let episode = byID["e5"] {
            downloads["e5"] = makeDownload(episode, state: .downloading)
        }

        // Never a duplicate of anything already tracked. (isDisjoint is used
        // deliberately: Set.intersects is newer SDK-only and absent from the
        // CI toolchain's overlay.)
        let queued = sweep()
        XCTAssertTrue(queued.isEmpty || Set(queued).isDisjoint(with: downloads.keys))
    }
}
