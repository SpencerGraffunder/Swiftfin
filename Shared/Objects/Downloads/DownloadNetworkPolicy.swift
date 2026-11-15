//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
import Network

/// Wi-Fi/cellular gate for automatic (background-initiated) downloads.
///
/// Manual downloads triggered by the user are never gated — only the
/// auto-queue ("download next N episodes while watching") respects the
/// `Experimental.downloadsAllowCellular` setting.
@MainActor
final class DownloadNetworkPolicy {

    static let shared = DownloadNetworkPolicy()

    private nonisolated(unsafe) static let monitor = NWPathMonitor()

    private init() {
        Self.monitor.start(queue: .global(qos: .utility))
    }

    /// Whether an auto-download may start right now.
    ///
    /// With cellular allowed this is always true (connectivity itself is the
    /// URLSession's problem). Otherwise the current network must be Wi-Fi or
    /// wired Ethernet; while the path is unknown (monitor warm-up, airplane
    /// mode) auto-downloads stay parked.
    static func allowsAutoDownload(allowCellular: Bool) -> Bool {
        if allowCellular {
            return true
        }

        let path = monitor.currentPath

        return path.status == .satisfied
            && (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet))
    }
}
