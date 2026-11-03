import XCTest

/// Siri Remote walk through the tvOS app against the loopback fixture
/// (`scripts/fake_xtream_server.py`). The source form is pre-filled through a
/// DEBUG launch variable because the tvOS system keyboard is not scriptable;
/// saving still goes through the form's Save button.
final class BufferTVUITests: XCTestCase {
    private let remote = XCUIRemote.shared
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
        let server = ProcessInfo.processInfo.environment["BUFFER_FIXTURE_SERVER"] ?? "http://127.0.0.1:8899"
        app.launchEnvironment["BUFFER_PREFILL_XTREAM"] = "\(server)|demo|demo"
        app.launch()
    }

    func testAllFlows() throws {
        // Add source.
        if app.buttons["welcome-add-source"].waitForExistence(timeout: 10) {
            snapshot("01-welcome")
            remote.press(.select)
            XCTAssertTrue(app.buttons["save-source"].waitForExistence(timeout: 10))
            snapshot("02-add-source")
            focus(app.buttons["save-source"], pressing: .down)
            remote.press(.select)
        }

        // Guide and focus.
        let channel = app.buttons.matching(identifier: "tv-channel").firstMatch
        XCTAssertTrue(channel.waitForExistence(timeout: 60), "guide did not appear")
        sleep(6)
        snapshot("03-guide")
        focus(channel, pressing: .right)
        remote.press(.right)
        remote.press(.right)
        sleep(1)
        snapshot("04-guide-focus-programme")
        remote.press(.down)
        sleep(1)
        snapshot("05-guide-focus-next-row")
        focus(channel, pressing: .left)

        // Player.
        remote.press(.select)
        let player = app.descendants(matching: .any)["player"]
        XCTAssertTrue(player.waitForExistence(timeout: 10), "player did not open")
        sleep(10)
        snapshot("06-player")
        remote.press(.up)
        sleep(1)
        snapshot("07-player-chrome")
        remote.press(.playPause)
        sleep(1)
        snapshot("08-player-paused")
        remote.press(.playPause)
        remote.press(.menu)
        remote.press(.menu)
        sleep(2)

        // Sports.
        openSection("Sports")
        sleep(8)
        snapshot("09-sports")
        let event = app.buttons.matching(identifier: "sport-event").firstMatch
        if event.exists {
            focus(event, pressing: .down)
            remote.press(.select)
            sleep(5)
            snapshot("10-sport-matches")
            remote.press(.menu)
            sleep(1)
        } else {
            print("SPORTS: no fixtures loaded (ESPN unavailable)")
        }

        // Country filter: enable, keep the first country, then turn it off.
        openSection("Countries")
        sleep(2)
        snapshot("11-countries")
        let toggle = app.cells.containing(NSPredicate(format: "label CONTAINS %@", "Filter by country")).firstMatch
        if toggle.waitForExistence(timeout: 3) {
            focus(toggle, pressing: .down)
            remote.press(.select)
            remote.press(.down)
            remote.press(.select)
            sleep(1)
            snapshot("12-countries-on")
            focus(toggle, pressing: .up)
            remote.press(.select)
            sleep(1)
        }

        // Search with the on-screen keyboard.
        openSection("Search")
        sleep(2)
        let field = app.searchFields.firstMatch
        if field.waitForExistence(timeout: 3) {
            field.typeText("News")
        } else {
            for key in ["n", "e", "w", "s"] {
                let button = app.keyboards.buttons[key].firstMatch
                if button.exists { focus(button, pressing: .right, attempts: 30, fallback: .left); remote.press(.select) }
            }
        }
        sleep(3)
        snapshot("13-search")

        // Smart Channels from the Sources section, then back to the source.
        openSection("Sources")
        sleep(1)
        let smart = app.cells.containing(NSPredicate(format: "label CONTAINS %@", "Smart Channels")).firstMatch
        if smart.waitForExistence(timeout: 3) {
            focus(smart, pressing: .down, fallback: .up)
            remote.press(.select)
            sleep(12)
            openSection("All Channels")
            sleep(3)
            snapshot("14-smart-channels")
            openSection("Sources")
            let fixture = app.cells.containing(NSPredicate(format: "label CONTAINS %@", "Fixture")).firstMatch
            focus(fixture, pressing: .down, fallback: .up)
            remote.press(.select)
            sleep(3)
        }
        openSection("Settings")
        sleep(1)
        snapshot("15-settings")
    }

    /// The tab sidebar opens by moving up from the content (or, when nothing
    /// in the content is focusable, by selecting the collapsed pill).
    private func openSection(_ name: String) {
        let tab = app.cells.containing(NSPredicate(format: "label == %@", name)).firstMatch
        for _ in 0..<6 { remote.press(.up) }
        if !tab.waitForExistence(timeout: 1) { remote.press(.select); sleep(1) }
        focus(tab, pressing: .down, attempts: 16, fallback: .up)
        remote.press(.select)
    }

    /// Presses `direction` until `element` holds focus.
    private func focus(_ element: XCUIElement, pressing direction: XCUIRemote.Button, attempts: Int = 12,
                       fallback: XCUIRemote.Button? = nil) {
        guard element.waitForExistence(timeout: 2) else { return }
        for _ in 0..<attempts where !element.hasFocus { remote.press(direction) }
        if let fallback { for _ in 0..<attempts * 2 where !element.hasFocus { remote.press(fallback) } }
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
