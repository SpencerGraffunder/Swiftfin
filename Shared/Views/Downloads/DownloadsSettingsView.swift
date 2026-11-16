//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Defaults
import SwiftUI

/// Download behavior settings, opened from the Downloads tab's gear button.
/// A regular settings page (not a popover menu) so every option carries its
/// label and an explanatory footer.
struct DownloadsSettingsView: View {

    @Default(.Experimental.downloadsAutoQueueNext)
    private var downloadsAutoQueueNext
    @Default(.Experimental.downloadsAllowCellular)
    private var downloadsAllowCellular
    @Default(.Experimental.downloadsDeleteAfterWatched)
    private var downloadsDeleteAfterWatched

    @ContentBuilder
    var body: some View {
        Form(systemImage: "arrow.down.circle") {
            Section {
                // swiftlint:disable hard_coded_display_string
                Picker(L10n.downloadAutoQueueNext, selection: $downloadsAutoQueueNext) {
                    Text(L10n.off).tag(0)
                    ForEach(1 ... 5, id: \.self) { count in
                        Text(L10n.downloadAutoQueueCount(count)).tag(count)
                    }
                }
            } footer: {
                Text(L10n.downloadAutoQueueNextDescription)
            }

            Section {
                Toggle(L10n.downloadCellular, isOn: $downloadsAllowCellular)
            } footer: {
                Text(L10n.downloadCellularDescription)
            }

            Section {
                Toggle(L10n.downloadDeleteAfterWatched, isOn: $downloadsDeleteAfterWatched)
            } footer: {
                Text(L10n.downloadDeleteAfterWatchedDescription)
            }
            // swiftlint:enable hard_coded_display_string
        }
        .navigationTitle(L10n.downloadSettings)
    }
}
