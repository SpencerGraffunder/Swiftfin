//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import FactoryKit
import Foundation
import JellyfinAPI
import Logging

/// A small on-disk mirror of playback positions keyed by item id.
///
/// Server progress reports (``MediaProgressReporter``) fail silently while
/// offline, so an episode watched on a plane would resume from the last
/// server-known position. This store is written on every report attempt
/// (online or offline) and wins over the cached server value when it is
/// newer, which keeps resume correct for downloaded playback in airplane
/// mode. Server reports are unchanged: once connectivity returns, the next
/// periodic report carries the current position anyway.
@MainActor
final class LocalPlaybackPositions {

    struct Entry: Codable {

        var ticks: Int64
        var updatedAt: Date
        var completed: Bool

        /// nil for entries written before the replay pass existed — treated
        /// as "needs replay" once, then cleared.
        var needsReplay: Bool?

        var replays: Bool {
            needsReplay ?? true
        }
    }

    static let shared = LocalPlaybackPositions()

    private static let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("LocalPlaybackPositions.json")
    }()

    private var entries: [String: Entry]
    private var loaded = false

    private init() {
        entries = [:]
    }

    func record(itemID: String, ticks: Int64, completed: Bool = false, needsReplay: Bool = false) {
        loadIfNeeded()
        entries[itemID] = Entry(ticks: ticks, updatedAt: .now, completed: completed, needsReplay: needsReplay)
        persist()
    }

    /// Flags the saved position for another server sync (used when a live
    /// progress report fails, e.g. airplane mode).
    func markNeedsReplay(itemID: String) {
        loadIfNeeded()
        guard entries[itemID] != nil, entries[itemID]?.needsReplay != false else { return }

        entries[itemID]?.needsReplay = true
        persist()
    }

    func entry(for itemID: String?) -> Entry? {
        guard let itemID else { return nil }

        loadIfNeeded()
        return entries[itemID]
    }

    func remove(itemID: String) {
        loadIfNeeded()
        guard entries[itemID] != nil else { return }

        entries[itemID] = nil
        persist()
    }

    private func loadIfNeeded() {
        guard !loaded else { return }

        loaded = true

        guard let data = try? Data(contentsOf: Self.fileURL),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return }

        entries = decoded
    }

    /// Pushes positions that the server never received (offline viewing or
    /// failed reports). Uses the two endpoints the app already relies on —
    /// mark-played and the stopped report — so any server version computes
    /// resume/played the same way as during live playback.
    func replayPending() async {
        guard let userSession = Container.shared.currentUserSession() else { return }

        await replay(userSession: userSession)
    }

    private nonisolated(unsafe) static let replayLogger = Logger.swiftfin()

    func replay(userSession: UserSession) async {
        loadIfNeeded()

        let pending = entries
            .filter(\.value.replays)
            .sorted { $0.value.updatedAt < $1.value.updatedAt }

        guard pending.isNotEmpty else { return }

        let client = userSession.client
        let userID = userSession.user.id

        for (itemID, entry) in pending {
            do {
                if entry.completed {
                    _ = try await client.send(Paths.markPlayedItem(itemID: itemID, userID: userID))
                } else if entry.ticks > 0 {
                    var info = PlaybackStopInfo()
                    info.itemID = itemID
                    info.positionTicks = entry.ticks
                    _ = try await client.send(Paths.reportPlaybackStopped(info))
                }

                entries[itemID]?.needsReplay = false
                persist()
            } catch {
                // Server unreachable (or item unknown): keep the entry for a
                // later foreground pass. Legacy entries without a position
                // still clear so they do not linger forever.
                if entry.ticks == 0, !entry.completed {
                    entries[itemID]?.needsReplay = false
                    persist()
                }
            }
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }

        try? data.write(to: Self.fileURL, options: .atomic)
    }
}
