import XCTest

/// End-to-end walk through the iPhone / iPad app against the loopback
/// fixture (`scripts/fake_xtream_server.py`). Each flow attaches full-screen
/// captures; steps that depend on live data (ESPN fixtures, Smart Channels
/// matches) record what they found instead of failing the run.
final class BufferMobileUITests: XCTestCase {
    private var server: String {
        ProcessInfo.processInfo.environment["BUFFER_FIXTURE_SERVER"] ?? "http://127.0.0.1:8899"
    }
    private var app: XCUIApplication!
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    override func setUp() {
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        // XCUITest typing into SecureField does not reach its binding on the
        // iOS 27 simulator, so the form is pre-filled (DEBUG launch variable);
        // saving still goes through the form's button.
        app.launchEnvironment["BUFFER_PREFILL_XTREAM"] = "\(server)|demo|demo"
        app.launch()
    }

    func testAllFlows() throws {
        addSource()
        guide()
        reminders()
        search()
        sports()
        countryFilter()
        smartChannels()
        player()
        rotation()
    }

    /// Captures Buffer's icon on the Home Screen (run once per appearance).
    func testHomeScreenIcon() throws {
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let icon = springboard.icons["Buffer"]
        for _ in 0..<3 where !(icon.exists && icon.isHittable) {
            springboard.swipeLeft()
            sleep(1)
        }
        XCTAssertTrue(icon.exists, "Buffer icon not on the Home Screen")
        snapshot("00-home-icon")
    }

    // MARK: - Flows

    private func addSource() {
        guard app.buttons["welcome-add-source"].waitForExistence(timeout: 10) else { return }
        snapshot("01-welcome")
        app.buttons["welcome-add-source"].tap()
        let save = app.buttons["save-source"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        snapshot("02-add-source")
        save.tap()
    }

    private var guideGrid: XCUIElement { app.descendants(matching: .any)["guide-grid"] }

    private func guide() {
        XCTAssertTrue(guideGrid.waitForExistence(timeout: 60), "guide grid did not appear")
        sleep(5)
        snapshot("03-guide")
        // VoiceOver exposure of drawn cells: the channel and programme elements.
        let channel = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "US: ESPN")).firstMatch
        XCTAssertTrue(channel.exists, "guide cells are not exposed to accessibility")
    }

    private func reminders() {
        // Long-press a programme an hour or so ahead in the first row.
        let future = guideGrid.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: isPad ? 760 : 380, dy: 70))
        future.press(forDuration: 1.2)
        sleep(1)
        snapshot("04-guide-menu")
        if app.buttons["Remind Me"].waitForExistence(timeout: 3) {
            app.buttons["Remind Me"].tap()
            app.buttons["At Start"].firstMatch.tap()
            // Answer the notification permission prompt the first reminder raises.
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            let allow = springboard.buttons["Allow"]
            if allow.waitForExistence(timeout: 5) { allow.tap() }
            sleep(2)
            snapshot("05-reminder-scheduled")
        } else {
            XCTFail("reminder menu missing")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
        }
        openSettings()
        let remindersLink = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Programme Reminders")).firstMatch
        if remindersLink.waitForExistence(timeout: 5) {
            remindersLink.tap()
            sleep(1)
            snapshot("06-reminders-list")
            app.buttons["BackButton"].firstMatch.tap()
        }
        snapshot("07-settings")
        openGuide()
    }

    private func search() {
        if isPad { sidebarItem("Search").tap() } else { app.tabBars.buttons["Search"].tap() }
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("News")
        sleep(3)
        snapshot("08-search")
        // Leave search: dismiss the keyboard, then clear the query.
        field.typeText("\n")
        let cancel = app.buttons["Close"].firstMatch
        if cancel.exists { cancel.tap() }
        sleep(1)
        openGuide()
    }

    private func sports() {
        if isPad { sidebarItem("Sports").tap() } else { app.tabBars.buttons["Sports"].tap() }
        sleep(10)
        snapshot("09-sports")
        let event = app.buttons.matching(identifier: "sport-event").firstMatch
        if event.exists {
            event.tap()
            sleep(5)
            snapshot("10-sport-matches")
            app.buttons["Done"].firstMatch.tap()
            sleep(1)
        } else {
            print("SPORTS: no fixtures loaded (ESPN unavailable)")
        }
        openGuide()
    }

    private func countryFilter() {
        app.buttons["country-filter"].firstMatch.tap()
        sleep(2)
        snapshot("11-countries")
        let toggle = app.switches.firstMatch
        if toggle.waitForExistence(timeout: 3) {
            // Tap the switch itself; the centre of a Toggle is its label.
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            // Keep the first country (United Kingdom) only.
            let all = app.buttons["All"].firstMatch
            if all.waitForExistence(timeout: 3) { all.tap() }
            sleep(2)
            snapshot("12-countries-uk")
            dismissCountryFilter()
            sleep(2)
            snapshot("13-guide-uk-only")
            // Turn it back off for the remaining flows.
            app.buttons["country-filter"].firstMatch.tap()
            sleep(1)
            if app.switches.firstMatch.waitForExistence(timeout: 3) {
                app.switches.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            }
            sleep(1)
        }
        dismissCountryFilter()
    }

    private func dismissCountryFilter() {
        if !isPad, app.buttons["Done"].exists { app.buttons["Done"].tap() } else if isPad {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.95)).tap()
        }
    }

    private func smartChannels() {
        chooseSource("Smart Channels")
        sleep(12)
        snapshot("14-smart-channels")
        chooseSource("Fixture")
        sleep(4)
    }

    private func chooseSource(_ name: String) {
        if isPad {
            sidebarItem(name).tap()
            openGuide()
        } else {
            app.buttons["Browse"].firstMatch.tap()
            let item = app.buttons[name].firstMatch
            if item.waitForExistence(timeout: 3) { item.tap() }
        }
    }

    private func player() {
        XCTAssertTrue(guideGrid.waitForExistence(timeout: 20))
        guideGrid.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 40, dy: 60)).tap()
        let player = app.descendants(matching: .any)["player"]
        XCTAssertTrue(player.waitForExistence(timeout: 10), "player did not open")
        sleep(10)
        snapshot("15-player")
        player.tap()
        sleep(1)
        snapshot("16-player-chrome")
        let airplay = app.buttons["AirPlay"].firstMatch
        if airplay.exists {
            airplay.tap()
            sleep(2)
            snapshot("17-airplay")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
            sleep(1)
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(4)
        snapshot("18-player-landscape")
        XCUIDevice.shared.orientation = .portrait
        sleep(2)
        player.tap()
        sleep(1)
        let close = app.buttons["Close player"]
        if close.waitForExistence(timeout: 3) { close.tap() }
        sleep(1)
    }

    private func rotation() {
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(3)
        snapshot("19-guide-landscape")
        XCUIDevice.shared.orientation = .portrait
        sleep(2)
    }

    // MARK: - Helpers

    /// An iPad sidebar row, re-showing the sidebar if it was collapsed.
    private func sidebarItem(_ name: String) -> XCUIElement {
        let item = app.staticTexts[name].firstMatch
        if !item.exists || !item.isHittable {
            let toggle = app.buttons["ToggleSidebar"].firstMatch
            if toggle.exists { toggle.tap(); sleep(1) }
        }
        return item
    }

    private func openSettings() {
        if isPad { sidebarItem("Settings").tap() } else { app.tabBars.buttons["Settings"].tap() }
        sleep(1)
    }

    private func openGuide() {
        if isPad { sidebarItem("All Channels").tap() } else { app.tabBars.buttons["Guide"].tap() }
        sleep(1)
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
