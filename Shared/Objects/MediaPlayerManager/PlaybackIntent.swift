//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
import JellyfinAPI

@MainActor
struct PlaybackIntent {

    let entry: ItemEntry
    var queue: any MediaPlayerQueue?
    var configuration: MediaPlaybackConfiguration

    /// Fork addition (issue #1789): set for playback of a completed local
    /// download. When present, `MediaPlayerItemResolver` builds the player
    /// item straight from the local file with zero server round-trips, so
    /// playback works with no connectivity (airplane mode).
    var offline: OfflinePlayback?

    struct OfflinePlayback {
        let fileURL: URL
        let mediaSource: MediaSourceInfo
    }

    var item: BaseItemDto {
        entry.snapshot
    }

    var mediaSource: MediaSourceInfo? {
        configuration.mediaSource(in: item)
    }

    init(item: BaseItemDto, queue: any MediaPlayerQueue? = nil) {
        self.init(item: item, configuration: .init(), queue: queue)
    }

    init(item: BaseItemDto, configuration: MediaPlaybackConfiguration, queue: any MediaPlayerQueue? = nil) {
        self.entry = SharedBaseItem(wrappedValue: item).entry
        self.queue = queue
        self.configuration = configuration
    }
}
