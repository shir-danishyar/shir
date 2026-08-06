import XCTest

/// Walks the app and saves a screenshot of each screen.
///
/// Not an assertion suite — it exists so the UI can be reviewed without anyone
/// tapping through by hand, which matters a lot for a design that is being
/// matched against reference screenshots. Images land in the test runner's
/// Documents directory; `scripts/screenshots.sh` pulls them back out.
final class ScreenshotTour: ShirUITestCase {

    func testCaptureEveryScreen() {
        XCTAssertTrue(app.staticTexts["No songs yet"].waitForExistence(timeout: 10))
        save("01-favorites-empty")

        app.tapTab("Playlists")
        XCTAssertTrue(app.staticTexts["My Playlists"].waitForExistence(timeout: 5))
        save("02-playlists")

        app.createPlaylist(named: "Late Night")
        XCTAssertTrue(app.staticTexts["Late Night"].waitForExistence(timeout: 5))
        save("03-playlists-with-one")

        app.staticTexts["Late Night"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["No songs yet"].waitForExistence(timeout: 5))
        save("04-playlist-detail")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        app.tapTab("Search")
        XCTAssertTrue(app.staticTexts["Find music"].waitForExistence(timeout: 5))
        save("05-search")

        app.tapTab("More")
        XCTAssertTrue(app.buttons["settingsRow"].waitForExistence(timeout: 5))
        save("06-more")

        app.buttons["settingsRow"].tap()
        // Assert on the nav bar rather than the section header: iOS
        // uppercases grouped-list headers, so matching the literal source
        // string silently never matches.
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        save("07-settings")

        app.swipeUp()
        save("08-settings-playback")
    }

    // MARK: - Helpers

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
