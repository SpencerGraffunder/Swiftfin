//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file. You can obtain one at https://mozilla.org/MPL/2.0/.
//
// End-to-end download-flow QA against a dedicated QA Jellyfin server.
// Configuration comes from the test runner environment (xctestrun):
//   QA_SERVER_URL, QA_USER, QA_PASS
//

import XCTest

final class DownloadFlowUITests: XCTestCase {

    private static let app = XCUIApplication(bundleIdentifier: "org.jellyfin.swiftfin")

    private var serverURL: String {
        ProcessInfo.processInfo.environment["QA_SERVER_URL"] ?? "http://192.168.4.200:8097"
    }

    private var qaUser: String {
        ProcessInfo.processInfo.environment["QA_USER"] ?? "qaadmin"
    }

    private var qaPass: String {
        ProcessInfo.processInfo.environment["QA_PASS"] ?? ""
    }

    override func setUp() {
        continueAfterFailure = false
    }

    private func snap(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        addAttachment(shot.pngRepresentation, named: "screenshot-\(name).png", uti: "public.png")
    }

    @discardableResult
    private func tapIfExists(_ element: XCUIElement, timeout: TimeInterval = 4) -> Bool {
        if element.waitForExistence(timeout: timeout) {
            element.tap()
            return true
        }
        return false
    }

    /// Last hittable element of a query (duplicate labels across bar + sheet).
    private func lastHittable(_ query: XCUIElementQuery) -> XCUIElement? {
        var chosen: XCUIElement?
        for i in 0 ..< query.count where query.element(boundBy: i).isHittable {
            chosen = query.element(boundBy: i)
        }
        return chosen
    }

    // MARK: - Flow

    func test01ConnectSignInAndDownloadMovie() throws {
        let app = Self.app
        app.launch()

        // First-run: server selection screen -> "Add server"
        tapIfExists(app.buttons["Add server"], timeout: 25)
        snap("01-add-server")

        // Server entry form: URL field -> Connect
        let urlField = app.textFields.firstMatch
        XCTAssertTrue(urlField.waitForExistence(timeout: 15), "server URL field never appeared")
        urlField.tap()
        urlField.typeText(serverURL)
        snap("02-url-entered")

        let connect = app.buttons["Connect"]
        XCTAssertTrue(connect.waitForExistence(timeout: 5), "Connect button missing")
        connect.tapWithRetry()
        snap("03-connected")

        // Sign-in form: Username / Password
        let userField = app.textFields["Username"]
        XCTAssertTrue(userField.waitForExistence(timeout: 30), "username field never appeared")
        userField.tap()
        userField.typeText(qaUser)

        let passField = app.secureTextFields["Password"]
        XCTAssertTrue(passField.waitForExistence(timeout: 5), "password field never appeared")
        passField.tap()
        passField.typeText(qaPass)
        snap("04-credentials")

        if !tapIfExists(app.buttons["Connect"], timeout: 4) {
            if !tapIfExists(app.buttons["Sign In"], timeout: 3) {
                passField.typeText("\n")
            }
        }
        snap("05-signed-in")

        // Home: dismiss any chrome, then find Movies
        dismissChrome(app)

        let moviesTab = app.tabBars.buttons["Movies"]
        if !tapIfExists(moviesTab, timeout: 25) {
            tapIfExists(app.tabBars.buttons["Home"], timeout: 5)
        }
        snap("06-movies")

        // Open the QA movie (poster image, falling back to its title label)
        if !tapIfExists(app.images["QA Movie"], timeout: 20) {
            app.swipeUp()
            if !tapIfExists(app.images["QA Movie"], timeout: 8) {
                XCTAssertTrue(
                    tapIfExists(app.staticTexts["QA Movie"], timeout: 8),
                    "QA Movie not visible in Movies"
                )
            }
        }
        snap("07-item-detail")

        // The download action must be present in the primary action row
        let downloadButton = app.buttons["Download"]
        XCTAssertTrue(downloadButton.waitForExistence(timeout: 15), "download button missing from item detail")
        snap("08-download-visible")

        // Tap opens the options menu; its sheet action (also "Download") starts the job.
        downloadButton.tap()
        snap("09-download-menu")

        let startButton = try XCTUnwrap(lastHittable(app.buttons["Download"]),
                                        "download start action missing from menu")
        startButton.tap()
        snap("10-download-started")

        // Button label must flip to an active state
        let pending = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[cd] 'ownload'")
        ).firstMatch
        XCTAssertTrue(pending.waitForExistence(timeout: 30), "download button never entered an active state")
        snap("11-download-active")

        // Downloads tab must surface the in-flight download
        let downloadsTab = app.tabBars.buttons["Downloads"]
        XCTAssertTrue(downloadsTab.waitForExistence(timeout: 10), "Downloads tab missing from tab bar")
        downloadsTab.tap()
        snap("12-downloads-tab")

        XCTAssertTrue(
            app.cells.matching(NSPredicate(format: "label CONTAINS[cd] 'QA Movie'")).firstMatch
                .waitForExistence(timeout: 20),
            "download row missing from Downloads tab"
        )

        // Progress must reach the completed state (row label combines title + status)
        let completed = app.cells.matching(NSPredicate(format: "label CONTAINS[cd] 'QA Movie' AND label CONTAINS[cd] 'downloaded'")).firstMatch
        XCTAssertTrue(completed.waitForExistence(timeout: 300), "download did not complete within 300s")
        snap("13-download-complete")
    }

    func test02PauseCancelStateMachine() throws {
        let app = Self.app
        app.launch()
        dismissChrome(app)

        if !tapIfExists(app.tabBars.buttons["Movies"], timeout: 25) {
            tapIfExists(app.tabBars.buttons["Home"], timeout: 5)
        }
        if !tapIfExists(app.images["QA Big Movie"], timeout: 20) {
            app.swipeUp()
            XCTAssertTrue(tapIfExists(app.images["QA Big Movie"], timeout: 8)
                || tapIfExists(app.staticTexts["QA Big Movie"], timeout: 8),
                "QA Big Movie not visible")
        }

        let downloadButton = app.buttons["Download"]
        XCTAssertTrue(downloadButton.waitForExistence(timeout: 15), "download button missing on Big Movie")
        downloadButton.tap()
        let startButton = try XCTUnwrap(lastHittable(app.buttons["Download"]), "no hittable Download start control")
        startButton.tap()

        // Re-open the menu: active download must offer Pause + Cancel (or Play if already done)
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
            // Small-enough file finished already: completed menu must show Play + Delete
            XCTAssertTrue(app.buttons["Delete"].firstMatch.waitForExistence(timeout: 5),
                          "completed menu missing Delete")
            snap("20-completed-menu")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
            return
        }
        // Cancel from whatever state we are in now
        XCTAssertTrue(downloadButton.waitForExistence(timeout: 10))
        downloadButton.tap()
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 8), "menu missing Cancel action")
        cancel.tap()
        snap("22-cancelled")

        // Downloads tab must no longer list the cancelled download
        tapIfExists(app.tabBars.buttons["Downloads"], timeout: 10)
        let gone = NSPredicate(format: "label CONTAINS[cd] 'QA Big Movie'")
        let stillThere = app.cells.matching(gone).firstMatch.waitForExistence(timeout: 5)
        XCTAssertFalse(stillThere, "cancelled download still listed in Downloads tab")
        snap("23-cancel-row-gone")
    }

    func test03CompletedDownloadOffersOfflinePlay() throws {
        let app = Self.app
        app.launch()
        dismissChrome(app)

        let downloadsTab = app.tabBars.buttons["Downloads"]
        XCTAssertTrue(downloadsTab.waitForExistence(timeout: 25), "Downloads tab missing")
        downloadsTab.tap()

        let row = app.cells.matching(NSPredicate(format: "label CONTAINS[cd] 'QA Movie' AND label CONTAINS[cd] 'downloaded'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "completed download missing from Downloads tab")
        row.tap()
        snap("14-offline-detail")

        let detailDownload = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[cd] 'downloaded'")
        ).firstMatch
        XCTAssertTrue(detailDownload.waitForExistence(timeout: 15), "detail action not in downloaded state")
        snap("15-offline-state")

        let play = app.buttons.matching(NSPredicate(format: "label == 'Play' OR label CONTAINS[cd] 'resume'")).firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 15), "play control missing on offline item")
        snap("16-offline-play-ready")
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
