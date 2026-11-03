import XCTest

/// Siri Remote walk through the tvOS app against the loopback fixture
/// (`scripts/fake_xtream_server.py`). The source form is pre-filled through a
/// DEBUG launch variable because the tvOS system keyboard is not scriptable;
/// saving still goes through the form's Save button.
final class BufferTVUITests: XCTestCase {
    private let remote = XCUIRemote.shared

    override func setUp() {
        continueAfterFailure = true
    }

    func testAddSourceBrowseAndPlay() throws {
        let app = XCUIApplication()
        let server = ProcessInfo.processInfo.environment["BUFFER_FIXTURE_SERVER"] ?? "http://127.0.0.1:8899"
        app.launchEnvironment["BUFFER_PREFILL_XTREAM"] = "\(server)|demo|demo"
        app.launch()

        if app.buttons["welcome-add-source"].waitForExistence(timeout: 10) {
            snapshot(app, "01-welcome")
            remote.press(.select)
            XCTAssertTrue(app.buttons["save-source"].waitForExistence(timeout: 10))
            snapshot(app, "02-add-source")
            focus(app.buttons["save-source"], pressing: .down)
            remote.press(.select)
        }

        let channel = app.buttons.matching(identifier: "tv-channel").firstMatch
        XCTAssertTrue(channel.waitForExistence(timeout: 60), "guide did not appear")
        sleep(6)
        snapshot(app, "03-guide")

        focus(channel, pressing: .right)
        snapshot(app, "04-guide-focus")
        remote.press(.select)
        let player = app.descendants(matching: .any)["player"]
        XCTAssertTrue(player.waitForExistence(timeout: 10), "player did not open")
        sleep(10)
        snapshot(app, "05-player")
        remote.press(.up)
        sleep(1)
        snapshot(app, "06-player-chrome")
        remote.press(.menu)
        remote.press(.menu)
        sleep(2)

        // Moving up from the guide opens the tab sidebar; move down to the
        // section and select it.
        for (name, shot) in [("Sports", "07-sports"), ("Countries", "08-countries"), ("Search", "09-search")] {
            let tab = app.cells.containing(NSPredicate(format: "label == %@", name)).firstMatch
            for _ in 0..<6 { remote.press(.up) }
            // With nothing focusable in the content, Up only reaches the
            // collapsed pill; Select expands it.
            if !tab.waitForExistence(timeout: 1) { remote.press(.select); sleep(1) }
            focus(tab, pressing: .down, attempts: 14, fallback: .up)
            remote.press(.select)
            sleep(name == "Sports" ? 8 : 2)
            snapshot(app, shot)
        }
    }

    /// Presses `direction` until `element` holds focus.
    private func focus(_ element: XCUIElement, pressing direction: XCUIRemote.Button, attempts: Int = 12,
                       fallback: XCUIRemote.Button? = nil) {
        guard element.waitForExistence(timeout: 2) else { return }
        for _ in 0..<attempts where !element.hasFocus { remote.press(direction) }
        if let fallback { for _ in 0..<attempts * 2 where !element.hasFocus { remote.press(fallback) } }
    }

    private func snapshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
