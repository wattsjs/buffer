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
    }

    func testAddSourceBrowseAndPlay() throws {
        let app = XCUIApplication()
        app.launch()
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        if isPad { XCUIDevice.shared.orientation = .landscapeLeft }

        if app.buttons["welcome-add-source"].waitForExistence(timeout: 10) {
            snapshot(app, "01-welcome")
            app.buttons["welcome-add-source"].tap()
            fill(app.textFields["Server URL"], server)
            fill(app.textFields["Username"], "demo")
            fill(app.secureTextFields["Password"], "demo")
            snapshot(app, "02-add-source")
            app.buttons["save-source"].tap()
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
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
