//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation

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

    func record(itemID: String, ticks: Int64, completed: Bool = false) {
        loadIfNeeded()
        entries[itemID] = Entry(ticks: ticks, updatedAt: .now, completed: completed)
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

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}
