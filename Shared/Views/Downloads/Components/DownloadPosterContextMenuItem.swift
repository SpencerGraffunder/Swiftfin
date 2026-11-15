//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Defaults
import JellyfinAPI
import SwiftUI

/// Context-menu row shown on episode/movie posters (season view episode
/// cards, home rows, search results) that starts or cancels a direct
/// download straight from the long-press menu, without opening the detail
/// view first.
struct DownloadPosterContextMenuItem: View {

    @ObservedObject
    private var manager: DownloadManager

    @Default(.Experimental.downloads)
    private var isDownloadsEnabled

    let item: BaseItemDto

    init(item: BaseItemDto) {
        _manager = ObservedObject(wrappedValue: DownloadManager.shared)
        self.item = item
    }

    @ContentBuilder
    var body: some View {
        if isDownloadsEnabled,
           item.canBePlayed,
           [.episode, .movie].contains(item.type),
           item.id != nil {
            switch manager.download(for: item.id)?.state {
            case .completed:
                Label(L10n.downloaded, systemImage: "checkmark.circle.fill")

            case .queued, .downloading, .paused:
                Button(L10n.cancel, systemImage: "xmark.circle") {
                    if let itemID = item.id {
                        manager.cancel(itemID)
                    }
                }

            case .failed, .none:
                Button(L10n.download, systemImage: "arrow.down.circle") {
                    Task {
                        await manager.download(item, options: .direct(item))
                    }
                }
            }
        }
    }
}
