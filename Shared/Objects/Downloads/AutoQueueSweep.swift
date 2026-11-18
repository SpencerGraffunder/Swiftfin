//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
import JellyfinAPI

/// Pure (network-free) decision core of the rolling auto-queue sweep.
/// Split out so unit tests can pin the window semantics
/// (see Tests/SwiftfinTests/AutoQueueSweepTests.swift).
///
/// Semantics (round 7): for every series that has an episode downloaded,
/// keep at most `downloadsAutoQueueNext` episodes *in flight*
/// (queued/downloading/paused). Whenever an episode finishes downloading
/// — or the setting changes — the completed episodes free slots, which are
/// filled by the next untracked episodes after the furthest episode
/// already tracked for that series.
///
/// Failed downloads count as neither in flight nor open slots, and they
/// anchor the window where it landed: a broken episode never turns the
/// sweep into a retry loop (users retry it by hand from the Downloads tab),
/// and the sweep always moves forward instead of re-walking old episodes.
enum AutoQueueSweep {

    /// Position of an episode inside its series (season first, then episode).
    struct EpisodePosition: Comparable {

        let season: Int
        let episode: Int
    }

    static func position(of item: BaseItemDto) -> EpisodePosition {
        EpisodePosition(season: item.parentIndexNumber ?? 0, episode: item.indexNumber ?? 0)
    }

    /// Episodes still waiting or in flight — these fill the window.
    static func pendingCount(in tracked: [Download]) -> Int {
        tracked.count { [.queued, .downloading, .paused].contains($0.state) }
    }

    /// The furthest episode already tracked for the series (any state,
    /// including failed — the window always advances past it).
    static func anchor(in tracked: [Download]) -> BaseItemDto? {
        tracked
            .map(\.item)
            .max(by: { position(of: $0) < position(of: $1) })
    }

    /// The next episodes to queue: untracked, strictly after `after`, in
    /// series order, capped at `limit`. `after: nil` means "series start".
    static func candidates(
        from episodes: [BaseItemDto],
        after: EpisodePosition?,
        excluding trackedIDs: Set<String>,
        limit: Int
    ) -> [BaseItemDto] {
        guard limit > 0 else { return [] }

        return Array(
            episodes
                .filter { item in
                    guard let id = item.id, !trackedIDs.contains(id) else { return false }
                    guard let after else { return true }

                    return position(of: item) > after
                }
                .sorted { position(of: $0) < position(of: $1) }
                .prefix(limit)
        )
    }
}
