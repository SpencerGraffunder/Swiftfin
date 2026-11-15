//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

@testable import Swiftfin
import XCTest

/// The on-disk playback-position mirror that keeps resume working offline
/// (round 3). Runs against the real store inside the test host container;
/// every case uses a throwaway item id so cases stay independent.
@MainActor
final class LocalPlaybackPositionsTests: XCTestCase {

    private var itemID: String!

    override func setUp() {
        super.setUp()
        itemID = "lpp-test-\(UUID().uuidString)"
        LocalPlaybackPositions.shared.record(itemID: itemID, ticks: 0)
    }

    override func tearDown() {
        LocalPlaybackPositions.shared.remove(itemID: itemID)
        super.tearDown()
    }

    func testRecordThenEntryRoundTrips() {
        LocalPlaybackPositions.shared.record(itemID: itemID, ticks: 42_000_000, completed: false, needsReplay: false)

        let entry = LocalPlaybackPositions.shared.entry(for: itemID)

        XCTAssertEqual(entry?.ticks, 42_000_000)
        XCTAssertEqual(entry?.completed, false)
        // Recorded with needsReplay:false => the position was already reported live.
        XCTAssertEqual(entry?.replays, false)
    }

    func testLegacyEntriesReplayOnceByDefault() {
        // Entry.needsReplay == nil models rows written before the replay pass
        // existed; those must get exactly one more server sync.
        let entry = OfflineExtrasTestSupport.makeLegacyEntry()

        XCTAssertEqual(entry.replays, true)
    }

    func testMarkNeedsReplayFlagsStoredEntry() {
        LocalPlaybackPositions.shared.record(itemID: itemID, ticks: 10, needsReplay: false)
        LocalPlaybackPositions.shared.markNeedsReplay(itemID: itemID)

        XCTAssertEqual(LocalPlaybackPositions.shared.entry(for: itemID)?.replays, true)
    }

    func testMarkNeedsReplayIgnoresUnknownItem() {
        LocalPlaybackPositions.shared.markNeedsReplay(itemID: "never-recorded-\(UUID().uuidString)")

        XCTAssertNil(LocalPlaybackPositions.shared.entry(for: "never-recorded-\(UUID().uuidString)"))
    }

    func testEntryForNilItemIDIsNil() {
        XCTAssertNil(LocalPlaybackPositions.shared.entry(for: nil))
    }

    func testRemoveDropsTheEntry() {
        LocalPlaybackPositions.shared.record(itemID: itemID, ticks: 1)
        LocalPlaybackPositions.shared.remove(itemID: itemID)

        XCTAssertNil(LocalPlaybackPositions.shared.entry(for: itemID))
    }

    func testCompletedRecordedAsCompleted() {
        LocalPlaybackPositions.shared.record(itemID: itemID, ticks: 999, completed: true)

        XCTAssertEqual(LocalPlaybackPositions.shared.entry(for: itemID)?.completed, true)
    }
}

/// Helper namespace so the "legacy row" shape (needsReplay == nil) can be
/// exercised without touching the on-disk file.
enum OfflineExtrasTestSupport {

    static func makeLegacyEntry() -> LocalPlaybackPositions.Entry {
        .init(ticks: 5, updatedAt: .distantPast, completed: false, needsReplay: nil)
    }
}
