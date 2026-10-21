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
/// - Item detail: download button is a `Menu`; label "Download", then state menus
///   with rows labeled exactly "Download" (start), "Pause", "Resume", "Cancel",
///   "Retry", "Play", "Delete" (L10n.signIn -> "Sign in", lowercase i, etc.)
final class DownloadFlowUITests: XCTestCase {
    private static let app = XCUIApplication()

    /// QA server + account injected by Scripts/qa/inject_env.py from the CI job env.
    /// Fallbacks must match the repo secrets QA_SERVER_URL / QA_USER / QA_PASSWORD
    /// (the dedicated `qa` account, NOT the admin).
    private let serverURL = ProcessInfo.processInfo.environment["QA_SERVER_URL"] ?? "http://192.168.4.200:8096"
    private let username = ProcessInfo.processInfo.environment["QA_USER"] ?? "qa"
    private let password = ProcessInfo.processInfo.environment["QA_PASS"]
        ?? ProcessInfo.processInfo.environment["QA_PASSWORD"] ?? ""

    /// The small (~4 MB) ffmpeg-generated movie. test01 downloads it to completion.
    private let smallMovieTitle = "QA Movie"

    override class func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    override func setUpWithError() throws {
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

    /// Flips the first-run disclaimer if present.
    private func acceptDisclaimerIfNeeded(_ app: XCUIApplication) {
        let continueButton = app.buttons["Continue"]
        if continueButton.waitForExistence(timeout: 3) { continueButton.tap() }
    }

    private func tapIfExists(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        guard element.waitForExistence(timeout: timeout) else { return false }
        element.tap()
        return true
    }

    /// Signs in (first run only). Swiftfin's launch sequence is
    /// disclaimer -> server list -> add-server form -> user sign-in -> tab bar.
    /// When the app is already signed in (state persisted from a previous test in
    /// this same run), it lands on the tab bar and this function returns immediately.
    private func signInIfNeeded(_ app: XCUIApplication) throws {
        acceptDisclaimerIfNeeded(app)
        dismissChrome(app)

        // Already signed in from an earlier test? The tab bar is the tell.
        if app.tabBars.buttons["Downloads"].waitForExistence(timeout: 15) { return }

        // Zero saved servers -> ConnectToJellyfinView with a single "Connect" CTA.
        if !tapIfExists(app.buttons["Connect"], timeout: 30) {
            // Servers exist but no user signed in: the sign-in screen should already
            // be visible; as a backstop try the Advanced/gear menu's Add-server entry.
            if !app.textFields["Username"].waitForExistence(timeout: 8) {
                tapIfExists(app.buttons["Advanced"], timeout: 5)
                tapIfExists(app.buttons["Add server"], timeout: 5)
            }
        }
        snap("01-connect-screen")

        let urlField = app.textFields["URL"]
        XCTAssertTrue(
            urlField.waitForExistence(timeout: 15),
            "URL field never appeared on the add-server form"
        )
        urlField.tap()
        urlField.typeText(serverURL)
        tapIfExists(app.keyboards.buttons["Return"], timeout: 3) // hide keyboard

        XCTAssertTrue(
            tapIfExists(app.buttons["Connect"], timeout: 10),
            "no Connect button on the add-server form"
        )
        snap("02-server-connected")

        let userField = app.textFields["Username"]
        XCTAssertTrue(
            userField.waitForExistence(timeout: 25),
            "user sign-in screen never appeared after connecting to the server"
        )
        userField.tap()
        userField.typeText(username)

        let passField = app.secureTextFields["Password"]
        XCTAssertTrue(passField.waitForExistence(timeout: 10), "password field missing")
        passField.tap()
        passField.typeText(password)
        tapIfExists(app.keyboards.buttons["Return"], timeout: 3)

        XCTAssertTrue(
            tapIfExists(app.buttons["Sign in"], timeout: 10),
            "no Sign in button on the sign-in screen"
        )
        dismissChrome(app)
        XCTAssertTrue(
            app.tabBars.buttons["Downloads"].waitForExistence(timeout: 30),
            "download feature off or tab missing after sign-in"
        )
        snap("03-signed-in")
    }

    /// Deterministic navigation to an item's detail page via the Search tab
    /// (home shelves are personalized/paginated and unreliable in CI).
    private func openItemViaSearch(_ app: XCUIApplication, title: String) throws {
        let searchTab = app.tabBars.buttons["Search"]
        XCTAssertTrue(searchTab.waitForExistence(timeout: 25), "Search tab missing")
        searchTab.tap()

        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 10), "search field missing")
        searchField.tap()
        searchField.typeText(title)
        tapIfExists(app.keyboards.buttons["Return"], timeout: 3)
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
        XCTAssertTrue(
            app.buttons["Download"].waitForExistence(timeout: 20) ||
                app.buttons.matching(NSPredicate(format: "label CONTAINS[cd] 'download'")).firstMatch.waitForExistence(timeout: 10),
            "item detail for '\(title)' missing the download action"
        )
    }

    /// The QA movie detail page, reached via search.
    private func openSmallMovie(_ app: XCUIApplication) throws {
        dismissChrome(app)
        try openItemViaSearch(app, title: smallMovieTitle)
        snap("11-item-detail")
    }

    // MARK: - Tests

    func test01ConnectSignInAndDownloadMovie() throws {
        let app = Self.app
        try signInIfNeeded(app)

        try openSmallMovie(app)

        // 1. The download button is visible in the primary action row and enabled.
        let downloadButton = app.buttons["Download"]
        XCTAssertTrue(downloadButton.waitForExistence(timeout: 15), "download button missing on item detail")
        XCTAssertTrue(downloadButton.isHittable, "download button not tappable")

        // 2. Tapping it opens the start menu (bitrate picker + Download row).
        downloadButton.tap()
        let startButton = try XCTUnwrap(
            lastHittable(app.buttons.matching(NSPredicate(format: "label == 'Download'"))),
            "download menu did not offer a Download start row"
        )
        snap("12-download-menu")
        startButton.tap()

        // 3. The action must flip into a state label immediately (queued/progress).
        let stateLabel = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[cd] 'download' AND label != 'Download'")
        ).firstMatch
        XCTAssertTrue(stateLabel.waitForExistence(timeout: 30), "download never entered a progress/queued state")
        snap("13-download-started")

        // 4. Poll until the action settles: completed (or failed — which must
        // fail the test explicitly rather than time out opaque).
        let completed = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[cd] 'downloaded'")
        ).firstMatch
        let deadline = Date().addingTimeInterval(300)
        var settled = false
        while Date() < deadline {
            if completed.exists || !stateLabel.exists { settled = true; break }
            RunLoop.current.run(until: Date().addingTimeInterval(2))
        }
        XCTAssertTrue(settled, "download did not settle within 5 minutes")
        XCTAssertFalse(
            app.buttons.matching(NSPredicate(format: "label CONTAINS[cd] 'download failed'")).firstMatch.exists,
            "download FAILED"
        )

        // 5. Downloads tab lists the item as downloaded.
        let downloadsTab = app.tabBars.buttons["Downloads"]
        XCTAssertTrue(downloadsTab.waitForExistence(timeout: 10), "Downloads tab missing")
        downloadsTab.tap()
        let row = app.cells.matching(
            NSPredicate(format: "label CONTAINS[cd] 'QA Movie'")
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "downloaded item missing from Downloads tab")
        XCTAssertTrue(row.label.lowercased().contains("download"), "row shows no state label: \(row.label)")
        snap("14-downloads-tab")
    }

    func test02PauseCancelStateMachine() throws {
        let app = Self.app
        try signInIfNeeded(app)
        dismissChrome(app)
        try openItemViaSearch(app, title: "QA Big Movie")

        let downloadButton = app.buttons["Download"]
        XCTAssertTrue(downloadButton.waitForExistence(timeout: 15), "download button missing on Big Movie")
        downloadButton.tap()
        let startButton = try XCTUnwrap(
            lastHittable(app.buttons.matching(NSPredicate(format: "label == 'Download'"))),
            "no hittable Download start row in menu"
        )
        startButton.tap()

        // Re-open the menu: active download must offer Pause (or Play if it already
        // completed — the tunnel is fast enough to beat the round trip on flaky days).
        XCTAssertTrue(downloadButton.waitForExistence(timeout: 20))
        downloadButton.tap()
        let pauseItem = app.buttons["Pause"].firstMatch
        let playItem = app.buttons["Play"].firstMatch
        if pauseItem.waitForExistence(timeout: 8) {
            pauseItem.tap()
            let pausedLabel = app.buttons.matching(
                NSPredicate(format: "label CONTAINS[cd] 'download paused'")
            ).firstMatch
            XCTAssertTrue(pausedLabel.waitForExistence(timeout: 20), "label did not become Download Paused")
            snap("20-paused")

            downloadButton.tap()
            if app.buttons["Resume"].firstMatch.waitForExistence(timeout: 5) {
                app.buttons["Resume"].firstMatch.tap()
            }
            snap("21-resumed")
            downloadButton.tap()
        } else if playItem.waitForExistence(timeout: 3) {
            // Completed already: completed menu must show Play + Delete.
            XCTAssertTrue(app.buttons["Delete"].firstMatch.waitForExistence(timeout: 5),
                          "completed menu missing Delete")
            snap("20-completed-menu")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
            return
        }

        // Cancel from whatever state we are in now.
        XCTAssertTrue(downloadButton.waitForExistence(timeout: 10))
        downloadButton.tap()
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 8), "menu missing Cancel action")
        cancel.tap()
        snap("22-cancelled")

        // The Downloads tab must no longer list the cancelled download.
        tapIfExists(app.tabBars.buttons["Downloads"], timeout: 10)
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

        let downloadsTab = app.tabBars.buttons["Downloads"]
        XCTAssertTrue(downloadsTab.waitForExistence(timeout: 25), "Downloads tab missing")
        downloadsTab.tap()

        let row = app.cells.matching(
            NSPredicate(format: "label CONTAINS[cd] 'QA Movie' AND label CONTAINS[cd] 'downloaded'")
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "completed download missing from Downloads tab")
        row.tap()
        snap("14-offline-detail")

        let detailDownload = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[cd] 'downloaded'")
        ).firstMatch
        XCTAssertTrue(detailDownload.waitForExistence(timeout: 15), "detail action not in downloaded state")
        snap("15-offline-state")

        let play = app.buttons.matching(
            NSPredicate(format: "label == 'Play' OR label CONTAINS[cd] 'resume'")
        ).firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 15), "play control missing on offline item")
        snap("16-offline-play-ready")
    }

    // MARK: - Helpers

    private func lastHittable(_ query: XCUIElementQuery) -> XCUIElement? {
        for i in stride(from: query.count - 1, through: 0, by: -1) {
            let el = query.element(boundBy: i)
            if el.exists, el.isHittable { return el }
        }
        return nil
    }

    private func dismissChrome(_ app: XCUIApplication) {
        tapIfExists(app.buttons["OK"], timeout: 3)
        tapIfExists(app.buttons["Allow"], timeout: 3)
        tapIfExists(app.buttons["Later"], timeout: 2)
        tapIfExists(app.buttons["No Thanks"], timeout: 2)
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
