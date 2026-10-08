//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import JellyfinAPI
import SwiftUI

extension ItemView {

    struct MetadataHStack: View {

        let item: BaseItemDto

        var body: some View {
            DotHStack {
                if let firstGenre = item.genres?.first {
                    Text(firstGenre)
                }

                if let premiereYear = item.premiereDateYear {
                    Text(premiereYear)
                }

                if let runtime = item.runtime {
                    Text(runtime, format: .hourMinuteAbbreviated)
                        // The abbreviated "1h 15m" is read as "1 h, 15 meters"
                        // by VoiceOver; spell out the units (#1738).
                        .accessibilityLabel(runtime.formatted(.wideUnits))
                }

                if let seasonEpisodeLabel = item.seasonEpisodeLabel {
                    Text(seasonEpisodeLabel)
                }
            }
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
        }
    }
}
