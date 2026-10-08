//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import FactoryKit
import Foundation
import Get
import Logging

/// An `APIClientDelegate` that signs the user out when the server reports the
/// current access token is no longer valid (HTTP 401).
///
/// When a device is removed from the server's admin UI, its API key is revoked
/// and every subsequent authenticated request returns `401`. Previously the app
/// kept holding the now-dead session and only surfaced the raw 401, forcing the
/// user to manually re-select the server *and* re-add the user before logging
/// back in. By intercepting the 401 in one place (the authenticated client's
/// response validation) we clear the stored session, which returns the user to
/// the user/login selection screen so a fresh login succeeds (issue #1138).
///
/// Only the *authenticated* `UserSession` client installs this delegate. The
/// sign-in flow uses a separate unauthenticated client, so a failed login (also
/// a 401) is not mistaken for a dead session and does not trigger a sign-out.
final class UnauthorizedSessionDelegate: APIClientDelegate, @unchecked Sendable {

    private let logger = Logger.swiftfin()

    private let lock = NSLock()
    private var lastSignOutAt = Date.distantPast

    func client(_ client: APIClient, validateResponse response: HTTPURLResponse, data: Data, task: URLSessionTask) throws {
        if response.statusCode == 401 {
            handleUnauthorizedResponse()
        }

        // Preserve the SDK's default status-code validation so the caller still
        // receives the same error it would have without this delegate.
        guard (200 ..< 300).contains(response.statusCode) else {
            throw APIError.unacceptableStatusCode(response.statusCode)
        }
    }

    private func handleUnauthorizedResponse() {
        guard Container.shared.currentUserSession() != nil else { return }

        // Coalesce a burst of 401s (one revoked token produces many concurrent
        // failing requests) into a single sign-out.
        let shouldSignOut: Bool
        lock.lock()
        if Date.now.timeIntervalSince(lastSignOutAt) >= 1 {
            lastSignOutAt = Date.now
            shouldSignOut = true
        } else {
            shouldSignOut = false
        }
        lock.unlock()
        guard shouldSignOut else { return }

        logger.warning(
            "Server rejected the current access token (HTTP 401); signing out so the user can log in again",
            metadata: ["issue": .string("1138")]
        )

        let manager = Container.shared.userSessionManager()

        Task { @MainActor in
            await manager.signOut(reason: .unauthorized)
        }
    }
}
