import XCTest

/// End-to-end walk through the iPhone / iPad app against the loopback
/// fixture (`scripts/fake_xtream_server.py`): add an Xtream source, browse
/// the guide, Sports and the country filter, then play a channel. Each step
/// attaches a screenshot to the result bundle.
final class BufferMobileUITests: XCTestCase {
    private var server: String {
        ProcessInfo.processInfo.environment["BUFFER_FIXTURE_SERVER"] ?? "http://127.0.0.1:8899"
    }

    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    func testAddSourceBrowseAndPlay() throws {
        let app = XCUIApplication()
        app.launchEnvironment["BUFFER_PREFILL_XTREAM"] = "\(server)|demo|demo"
        app.launch()
        let isPad = UIDevice.current.userInterfaceIdiom == .pad

        if app.buttons["welcome-add-source"].waitForExistence(timeout: 10) {
            snapshot(app, "01-welcome")
            app.buttons["welcome-add-source"].tap()
            // XCUITest typing into SecureField does not reach its binding on the
            // iOS 27 simulator, so the form is pre-filled (DEBUG launch variable).
            snapshot(app, "02-add-source")
            let save = app.buttons["save-source"]
            XCTAssertTrue(save.waitForExistence(timeout: 5))
            save.tap()
            sleep(3)
            snapshot(app, "02b-after-save")
        }

        // The guide appears once channels sync; give the guide a moment too.
        let guide = app.descendants(matching: .any)["guide-grid"]
        XCTAssertTrue(guide.waitForExistence(timeout: 60), "guide grid did not appear")
        sleep(6)
        snapshot(app, "03-guide")

        if isPad {
            app.staticTexts["Sports"].firstMatch.tap()
        } else {
            app.tabBars.buttons["Sports"].tap()
        }
        sleep(8)
        snapshot(app, "04-sports")
        let event = app.buttons.matching(identifier: "sport-event").firstMatch
        if event.exists {
            event.tap()
            sleep(4)
            snapshot(app, "04b-sport-matches")
            app.buttons["Done"].firstMatch.tap()
            sleep(1)
        }

        if isPad {
            app.buttons["country-filter"].firstMatch.tap()
        } else {
            app.tabBars.buttons["Guide"].tap()
            app.buttons["country-filter"].firstMatch.tap()
        }
        sleep(2)
        snapshot(app, "05-countries")
        if !isPad, app.buttons["Done"].exists { app.buttons["Done"].tap() }
        else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }

        if isPad { app.staticTexts["All Channels"].firstMatch.tap() }
        XCTAssertTrue(guide.waitForExistence(timeout: 10))
        // First channel's name cell, in the sticky column under the header.
        guide.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 40, dy: 60)).tap()
        let player = app.descendants(matching: .any)["player"]
        XCTAssertTrue(player.waitForExistence(timeout: 10), "player did not open")
        sleep(10)
        snapshot(app, "06-player")
        player.tap()
        sleep(1)
        snapshot(app, "07-player-chrome")
    }

    private func fill(_ field: XCUIElement, _ text: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 5), "missing field \(field)")
        field.tap()
        field.typeText(text)
    }

    private func snapshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
