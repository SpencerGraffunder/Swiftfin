import XCTest

/// End-to-end UI coverage for the local-download feature (issue #1789) as exposed by
/// PR #2: the `Download` action lives in the item-detail action row, gated by the
/// `Experimental.downloads` flag (default ON).
///
/// Tests must stay ordered (test01 -> test02 -> test03): test01 owns first-run
/// onboarding (it creates the server + user), and test02/test03 reuse the resulting
/// signed-in state because tests relaunch the same app container within one job run.
///
/// Selector ground truth (verified against sources on this branch):
/// - First launch (zero servers): `ConnectToJellyfinView` -> Button "Connect"
/// - `ConnectToServerView`: TextField "URL", Button "Connect" (disabled while URL empty)
/// - `UserSignInView`: TextField "Username", SecureField "Password", Button "Sign in"
/// - iOS tab bar: Home(contentGroup) / Search / Media / Downloads
/// - Item detail: download button is a `Menu` with label exactly "Download", then
///   state labels "Downloading…" / "Downloaded" / "Download Paused" / "Download Failed"
///   and menu rows labeled exactly "Download" (start), "Pause", "Resume", "Cancel",
///   "Retry", "Play", "Delete".
///
/// Interaction rule: NEVER `app.buttons["X"].tap()` directly — SwiftUI glass buttons
/// can double-expose the same control (and offscreen variants of the same label exist
/// in form rows), which makes an ambiguous element's actions throw
/// "Multiple matching elements". All taps go through `tapFirst`, which polls a scoped
/// query and taps the first *hittable* match by index.
final class DownloadFlowUITests: XCTestCase {
    private static let app = XCUIApplication()
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    /// QA server + account injected by Scripts/qa/inject_env.py from the CI job env.
    /// Fallbacks must match the workflow dispatch inputs (dedicated QA container,
    /// NOT the family server).
    private let serverURL = ProcessInfo.processInfo.environment["QA_SERVER_URL"] ?? "http://192.168.4.200:8096"
    private let username = ProcessInfo.processInfo.environment["QA_USER"] ?? "qaadmin"
    private let password = ProcessInfo.processInfo.environment["QA_PASS"]
        ?? ProcessInfo.processInfo.environment["QA_PASSWORD"] ?? ""

    /// The small (~4 MB) ffmpeg-generated movie. test01 downloads it to completion.
    private let smallMovieTitle = "QA Movie"

    /// Matches the item-detail download action in any of its states while excluding
    /// the Downloads *tab* ("Downloads") and the idle action ("Download") itself.
    private static let barStatePredicate = NSPredicate(
        format: "label CONTAINS[cd] 'download' AND label != 'Download' AND label != 'Downloads'"
    )

    @MainActor
    override func setUpWithError() throws {
        // Instance property — cannot be set from class func setUp().
        continueAfterFailure = false
        Self.app.launch()
    }

    @MainActor
    override func tearDownWithError() throws {
        Self.app.terminate()
    }

    private func snap(_ name: String) {
        let attachment = XCTAttachment(screenshot: Self.app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Interaction helpers

    /// Taps the first hittable element of `query`, polling until `timeout`.
    /// Immune to ambiguous-label duplicates (index resolution + hittable filter).
    @discardableResult
    private func tapFirst(_ query: XCUIElementQuery, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let count = query.count
            for i in 0 ..< count {
                let el = query.element(boundBy: i)
                if el.isHittable {
                    el.tap()
                    return true
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        } while Date() < deadline
        return false
    }

    /// Convenience: exact-label button tap.
    @discardableResult
    private func tapButton(_ collection: XCUIElementQuery, _ label: String, timeout: TimeInterval) -> Bool {
        tapFirst(collection.matching(NSPredicate(format: "label == %@", label)), timeout: timeout)
    }

    /// Picks the LAST hittable match: for an open menu whose rows share the bar
    /// button's label, the menu window is later in the element tree (and the bar
    /// behind the menu is not hittable).
    private func lastHittable(_ query: XCUIElementQuery) -> XCUIElement? {
        for i in stride(from: query.count - 1, through: 0, by: -1) {
            let el = query.element(boundBy: i)
            if el.isHittable { return el }
        }
        return nil
    }

    private func exists(_ query: XCUIElementQuery, timeout: TimeInterval) -> Bool {
        query.firstMatch.waitForExistence(timeout: timeout)
    }

    /// Flips the first-run disclaimer if present.
    private func acceptDisclaimerIfNeeded(_ app: XCUIApplication) {
        _ = tapButton(app.buttons, "Continue", timeout: 3)
    }

    private func dismissChrome(_ app: XCUIApplication) {
        dismissSystemAlert()
        for label in ["OK", "Allow", "Later", "No Thanks"] {
            _ = tapButton(app.buttons, label, timeout: 2)
        }
    }

    /// Taps the button of a system permission alert (local-network discovery etc.)
    /// or the first-keyboard "slide to type" tip if one is up. Those live in
    /// SpringBoard, not the app's own element tree.
    private func dismissSystemAlert() {
        for label in ["Allow", "OK", "Later", "Don’t Allow", "Continue"] {
            let b = springboard.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
            if b.waitForExistence(timeout: 0.5) { b.tap(); return }
        }
    }

    /// Finds a text field by visible title. A SwiftUI `TextField`/`SecureField`
    /// in a Form row exposes its title ONLY as `placeholderValue` while the field
    /// is empty — `label` stays empty — so `label == 'URL'` matches nothing
    /// (observed CI failure: "URL field never appeared" with the field on screen).
    /// Prefers a visible named field; falls back to the only visible field.
    private func findField(in collection: XCUIElementQuery, title: String, timeout: TimeInterval) -> XCUIElement? {
        let named = collection.matching(NSPredicate(
            format: "visible == 1 AND (label CONTAINS[cd] %@ OR placeholderValue CONTAINS[cd] %@)", title, title
        ))
        let anyVisible = collection.matching(NSPredicate(format: "visible == 1"))
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if named.count > 0 { return named.element(boundBy: 0) }
            if title.isEmpty, anyVisible.count > 0 { return anyVisible.element(boundBy: 0) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        } while Date() < deadline
        // Nothing matched by name — if exactly one visible field exists, take it.
        return anyVisible.count == 1 ? anyVisible.element(boundBy: 0) : nil
    }

    /// Dumps the raw element labels to the test log so selector mismatches are
    /// diagnosable from CI output alone.
    private func dumpTree(_ tag: String) {
        let app = Self.app
        print("### TREE[\(tag)] buttons:")
        for el in app.buttons.allElementsBoundByIndex {
            print("###   button label='\(el.label)' id='\(el.identifier)' enabled=\(el.isEnabled) hittable=\(el.isHittable)")
        }
        print("### TREE[\(tag)] textFields:")
        for el in app.textFields.allElementsBoundByIndex {
            print("###   textField label='\(el.label)' value='\(String(describing: el.value))' id='\(el.identifier)'")
        }
        print("### TREE[\(tag)] secureTextFields:")
        for el in app.secureTextFields.allElementsBoundByIndex {
            print("###   secureField label='\(el.label)' id='\(el.identifier)'")
        }
        print("### TREE[\(tag)] staticTexts: \(app.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | "))")
    }

    /// Taps EVERY hittable element matching `label` (once each) until an element of
    /// `indicator` shows up. Guards against SwiftUI glass duplicates where one of
    /// two same-labeled elements is a non-functional ghost.
    @discardableResult
    private func tapUntil(_ app: XCUIApplication, label: String, indicator: XCUIElementQuery, timeout: TimeInterval) -> Bool {
        let cta = app.buttons.matching(NSPredicate(format: "label == %@ AND visible == 1", label))
        var tried = Set<Int>()
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if indicator.firstMatch.exists { return true }
            let count = cta.count
            for i in 0 ..< count where !tried.contains(i) {
                let el = cta.element(boundBy: i)
                guard el.isHittable else { tried.insert(i); continue }
                tried.insert(i)
                el.tap()
                RunLoop.current.run(until: Date().addingTimeInterval(1.5))
                if indicator.firstMatch.exists { return true }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        } while Date() < deadline
        return indicator.firstMatch.exists
    }

    /// Signs in (first run only). Swiftfin's launch sequence is
    /// disclaimer -> server list -> add-server form -> user sign-in -> tab bar.
    /// When the app is already signed in (state persisted from a previous test in
    /// this same run), it lands on the tab bar and this function returns immediately.
    private func signInIfNeeded(_ app: XCUIApplication) throws {
        acceptDisclaimerIfNeeded(app)
        dismissChrome(app)

        // Already signed in from an earlier test? The tab bar is the tell.
        if exists(app.tabBars.buttons.matching(NSPredicate(format: "label == 'Downloads'")), timeout: 15) { return }

        // Section header of the add-server form.
        let formHeader = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[cd] 'connect to server'"))
        // "Sign in to <server>" line on the user sign-in screen.
        let signInHeader = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[cd] 'sign in to'"))

        // Zero saved servers -> ConnectToJellyfinView with a "Connect" CTA.
        // Tap until the form actually opens (glass ghosts can swallow taps).
        if !tapUntil(app, label: "Connect", indicator: formHeader, timeout: 30),
           !signInHeader.firstMatch.exists
        {
            // As a backstop try the Advanced/gear menu's Add-server entry.
            _ = tapButton(app.buttons, "Advanced", timeout: 5)
            _ = tapUntil(app, label: "Add server", indicator: formHeader, timeout: 10)
        }
        // Connecting triggers Bonjour discovery -> the local-network permission
        // alert can land over the add-server form; clear it before interacting.
        dismissSystemAlert()
        snap("01-connect-screen")

        if formHeader.firstMatch.exists {
            guard let urlField = findField(in: app.textFields, title: "URL", timeout: 15) else {
                dumpTree("add-server-form")
                XCTAssertFalse(true, "no URL field on the add-server form")
                return
            }
            urlField.tap()
            // The very first keyboard on a fresh simulator triggers the iOS
            // "slide to type" onboarding tip that covers the keyboard area.
            dismissSystemAlert()
            urlField.typeText(serverURL)
            if (urlField.value as? String)?.contains(serverURL) != true {
                // The tip or a focus hiccup ate the first input pass — retry once.
                urlField.tap()
                dismissSystemAlert()
                urlField.typeText(serverURL)
            }
            _ = tapFirst(app.keyboards.buttons.matching(NSPredicate(format: "label == 'Return'")), timeout: 3)

            if !tapUntil(app, label: "Connect", indicator: signInHeader, timeout: 15) {
                dumpTree("after-connect")
                XCTAssertFalse(true, "connecting to '\(serverURL)' never reached the user sign-in screen")
            }
        } else if !signInHeader.firstMatch.waitForExistence(timeout: 5) {
            dumpTree("after-cta")
            XCTAssertFalse(true, "never reached the add-server form or sign-in screen")
        }
        snap("02-server-connected")

        guard let userField = findField(in: app.textFields, title: "Username", timeout: 25) else {
            dumpTree("sign-in-screen")
            XCTAssertFalse(true, "user sign-in username field missing")
            return
        }
        userField.tap()
        userField.typeText(username)
        if (userField.value as? String)?.contains(username) != true {
            userField.tap()
            userField.typeText(username)
        }

        guard let passField = findField(in: app.secureTextFields, title: "Password", timeout: 10) else {
            dumpTree("password-field")
            XCTAssertFalse(true, "password field missing")
            return
        }
        passField.tap()
        passField.typeText(password)
        _ = tapFirst(app.keyboards.buttons.matching(NSPredicate(format: "label == 'Return'")), timeout: 3)

        XCTAssertTrue(
            tapButton(app.buttons, "Sign in", timeout: 10),
            "no Sign in button on the sign-in screen"
        )
        dismissChrome(app)
        let signedIn = exists(app.tabBars.buttons.matching(NSPredicate(format: "label == 'Downloads'")), timeout: 30)
        if !signedIn {
            dumpTree("sign-in-failed")
            XCTAssertFalse(true, "download feature off or tab missing after sign-in")
        }
        snap("03-signed-in")
    }

    /// Deterministic navigation to an item's detail page via the Search tab
    /// (home shelves are personalized/paginated and unreliable in CI).
    private func openItemViaSearch(_ app: XCUIApplication, title: String) throws {
        let searchTab = app.tabBars.buttons.matching(NSPredicate(format: "label == 'Search'")).firstMatch
        XCTAssertTrue(searchTab.waitForExistence(timeout: 25), "Search tab missing")
        searchTab.tap()

        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 10), "search field missing")
        searchField.tap()
        searchField.typeText(title)
        _ = tapFirst(app.keyboards.buttons.matching(NSPredicate(format: "label == 'Return'")), timeout: 3)
        snap("10-search-\(title.replacingOccurrences(of: " ", with: "-"))")

        let pred = NSPredicate(format: "label CONTAINS[cd] %@", title)
        var result: XCUIElement?
        for query in [app.cells.matching(pred), app.buttons.matching(pred), app.staticTexts.matching(pred)] {
            let candidate = query.firstMatch
            if candidate.waitForExistence(timeout: 8) {
                result = candidate
                break
            }
        }
        let found = try XCTUnwrap(result, "no search result matching '\(title)'")
        found.tapWithRetry()
        let downloadIdle = app.buttons.matching(NSPredicate(format: "label == 'Download'"))
        XCTAssertTrue(
            downloadIdle.firstMatch.waitForExistence(timeout: 20)
                || exists(app.buttons.matching(Self.barStatePredicate), timeout: 10),
            "item detail for '\(title)' missing the download action"
        )
    }

    /// The QA movie detail page, reached via search.
    private func openSmallMovie(_ app: XCUIApplication) throws {
        dismissChrome(app)
        try openItemViaSearch(app, title: smallMovieTitle)
        snap("11-item-detail")
    }

    /// The item-detail download action in its IDLE state (exact "Download" label).
    private var idleDownloadQuery: XCUIElementQuery {
        Self.app.buttons.matching(NSPredicate(format: "label == 'Download'"))
    }

    /// The item-detail download action in any ACTIVE/terminal state.
    private var stateDownloadQuery: XCUIElementQuery {
        Self.app.buttons.matching(Self.barStatePredicate)
    }

    // MARK: - Tests

    func test01ConnectSignInAndDownloadMovie() throws {
        let app = Self.app
        try signInIfNeeded(app)

        try openSmallMovie(app)

        // 1. The download button is visible in the primary action row and tappable.
        XCTAssertTrue(idleDownloadQuery.firstMatch.waitForExistence(timeout: 15), "download button missing on item detail")
        XCTAssertTrue(tapFirst(idleDownloadQuery, timeout: 10), "download button not tappable")

        // 2. The opened menu must offer a Download start row (bar + row share the
        // label; the menu row is the last hittable one).
        let startButton = try XCTUnwrap(
            lastHittable(idleDownloadQuery),
            "download menu did not offer a Download start row"
        )
        snap("12-download-menu")
        startButton.tap()

        // 3. The action must flip into a state label (queued/progress), excluding
        // the Downloads tab label.
        XCTAssertTrue(
            stateDownloadQuery.firstMatch.waitForExistence(timeout: 30),
            "download never entered a progress/queued state"
        )
        snap("13-download-started")

        // 4. Poll until the action settles: completed (or failed — which must
        // fail the test explicitly rather than time out opaque).
        let completed = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[cd] 'downloaded'")).firstMatch
        let failed = app.buttons.matching(NSPredicate(format: "label CONTAINS[cd] 'download failed'")).firstMatch
        let deadline = Date().addingTimeInterval(300)
        var settled = false
        while Date() < deadline {
            if completed.exists || failed.exists || !stateDownloadQuery.firstMatch.exists { settled = true; break }
            RunLoop.current.run(until: Date().addingTimeInterval(2))
        }
        XCTAssertTrue(settled, "download did not settle within 5 minutes")
        XCTAssertFalse(failed.exists, "download FAILED")
        XCTAssertTrue(completed.exists, "download settled but never reached the Downloaded state")
        snap("14-download-complete")

        // 5. Downloads tab lists the item as downloaded.
        let downloadsTab = app.tabBars.buttons.matching(NSPredicate(format: "label == 'Downloads'")).firstMatch
        XCTAssertTrue(downloadsTab.waitForExistence(timeout: 10), "Downloads tab missing")
        downloadsTab.tap()
        let row = app.cells.matching(
            NSPredicate(format: "label CONTAINS[cd] 'QA Movie'")
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "downloaded item missing from Downloads tab")
        XCTAssertTrue(row.label.lowercased().contains("download"), "row shows no state label: \(row.label)")
        snap("15-downloads-tab")
    }

    func test02PauseCancelStateMachine() throws {
        let app = Self.app
        try signInIfNeeded(app)
        dismissChrome(app)
        try openItemViaSearch(app, title: "QA Big Movie")

        XCTAssertTrue(tapFirst(idleDownloadQuery, timeout: 15), "download button missing/unhittable on Big Movie")
        let startButton = try XCTUnwrap(
            lastHittable(idleDownloadQuery),
            "no hittable Download start row in menu"
        )
        startButton.tap()

        // Re-open the menu: the bar now shows an active state label ("Downloading…"
        // / "Download Paused" / "Downloaded"), NOT the idle "Download" label.
        let activeDownload = stateDownloadQuery
        XCTAssertTrue(activeDownload.firstMatch.waitForExistence(timeout: 20), "bar never showed a download state")
        XCTAssertTrue(tapFirst(activeDownload, timeout: 10), "download state label not tappable")

        let pauseRow = app.buttons.matching(NSPredicate(format: "label == 'Pause'"))
        let playRow = app.buttons.matching(NSPredicate(format: "label == 'Play'"))
        if pauseRow.firstMatch.waitForExistence(timeout: 8) {
            XCTAssertTrue(tapFirst(pauseRow, timeout: 8), "Pause row not tappable")
            let pausedLabel = app.buttons.matching(
                NSPredicate(format: "label CONTAINS[cd] 'download paused'")
            ).firstMatch
            XCTAssertTrue(pausedLabel.waitForExistence(timeout: 20), "label did not become Download Paused")
            snap("20-paused")

            XCTAssertTrue(tapFirst(activeDownload, timeout: 10))
            _ = tapFirst(app.buttons.matching(NSPredicate(format: "label == 'Resume'")), timeout: 5)
            snap("21-resumed")
            _ = tapFirst(activeDownload, timeout: 10)
        } else if playRow.firstMatch.waitForExistence(timeout: 3) {
            // Completed already: completed menu must show Play + Delete.
            XCTAssertTrue(playRow.firstMatch.isHittable, "completed menu Play row not hittable")
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == 'Delete'")).firstMatch.waitForExistence(timeout: 5),
                          "completed menu missing Delete")
            snap("20-completed-menu")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
            return
        } else {
            XCTAssertFalse(true, "active download menu offered neither Pause nor Play")
        }

        // Cancel from whatever state we are in now (menu may already be open from
        // the resume step; the resume step re-opened it).
        if !app.buttons.matching(NSPredicate(format: "label == 'Cancel'")).firstMatch.exists {
            XCTAssertTrue(tapFirst(activeDownload, timeout: 10), "download state label not re-tappable")
        }
        let cancel = app.buttons.matching(NSPredicate(format: "label == 'Cancel'"))
        XCTAssertTrue(tapFirst(cancel, timeout: 8), "menu missing Cancel action")
        snap("22-cancelled")

        // The Downloads tab must no longer list the cancelled download.
        _ = tapFirst(app.tabBars.buttons.matching(NSPredicate(format: "label == 'Downloads'")), timeout: 10)
        let stillThere = app.cells.matching(
            NSPredicate(format: "label CONTAINS[cd] 'QA Big Movie'")
        ).firstMatch.waitForExistence(timeout: 5)
        XCTAssertFalse(stillThere, "cancelled download still listed in Downloads tab")
        snap("23-cancel-row-gone")
    }

    func test03CompletedDownloadOffersOfflinePlay() throws {
        let app = Self.app
        try signInIfNeeded(app)
        dismissChrome(app)

        let downloadsTab = app.tabBars.buttons.matching(NSPredicate(format: "label == 'Downloads'")).firstMatch
        XCTAssertTrue(downloadsTab.waitForExistence(timeout: 25), "Downloads tab missing")
        downloadsTab.tap()

        let row = app.cells.matching(
            NSPredicate(format: "label CONTAINS[cd] 'QA Movie' AND label CONTAINS[cd] 'downloaded'")
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "completed download missing from Downloads tab")
        row.tapWithRetry()
        snap("14-offline-detail")

        let detailDownload = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH[cd] 'downloaded'")
        ).firstMatch
        XCTAssertTrue(detailDownload.waitForExistence(timeout: 15), "detail action not in downloaded state")
        snap("15-offline-state")

        let play = app.buttons.matching(
            NSPredicate(format: "label == 'Play' OR label CONTAINS[cd] 'resume'")
        ).firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 15), "play control missing on offline item")
        snap("16-offline-play-ready")
    }
}

extension XCUIElement {
    /// Retry a tap whose first attempt can land during a transition.
    func tapWithRetry(maxAttempts: Int = 3) {
        for _ in 0 ..< maxAttempts {
            if exists { tap() }
            if !waitForExistence(timeout: 1.5) { return }
        }
    }
}
