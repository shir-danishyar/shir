import XCTest

/// Walks the app and saves a screenshot of each screen.
///
/// Not an assertion suite — it exists so the UI can be reviewed without anyone
/// tapping through by hand. Images land in the test runner's Documents
/// directory; `scripts/screenshots.sh` pulls them back out to `screenshots/`.
final class ScreenshotTour: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uitesting"]
        app.launch()
    }

    func testCaptureEveryScreen() {
        XCTAssertTrue(app.staticTexts["No playlists yet"].waitForExistence(timeout: 10))
        save("01-library-empty")

        app.buttons["Create Playlist"].tap()
        let alert = app.alerts["New Playlist"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        let nameField = alert.textFields.firstMatch
        nameField.tap()
        nameField.typeText("Late Night")
        alert.buttons["Create"].tap()

        XCTAssertTrue(app.staticTexts["Late Night"].waitForExistence(timeout: 5))
        save("02-library-with-playlist")

        app.staticTexts["Late Night"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["No songs yet"].waitForExistence(timeout: 5))
        save("03-playlist-detail")

        app.navigationBars.buttons.element(boundBy: 0).tap()

        tapTab("Search")
        XCTAssertTrue(app.staticTexts["YouTube key needed"].waitForExistence(timeout: 5))
        save("04-search")

        tapTab("Settings")
        XCTAssertTrue(app.staticTexts["YouTube Data API key"].waitForExistence(timeout: 5))
        save("05-settings-top")

        app.swipeUp()
        save("06-settings-playback")
    }

    // MARK: - Helpers

    private func tapTab(_ name: String) {
        let tab = app.tabBars.buttons[name]
        if tab.waitForExistence(timeout: 5) { tab.tap() } else { app.buttons[name].tap() }
    }

    private func save(_ name: String) {
        let image = XCUIScreen.main.screenshot()

        // Attach for the .xcresult bundle...
        let attachment = XCTAttachment(screenshot: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        // ...and write a plain PNG, which is far easier to pull off the
        // simulator than digging attachments out of an xcresult.
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = directory.appendingPathComponent("\(name).png")
        do {
            try image.pngRepresentation.write(to: url)
        } catch {
            XCTFail("could not write \(name): \(error)")
        }
    }
}
