import XCTest

/// End-to-end checks that the app launches and its core flows work on a real
/// simulator. Deliberately thin: the interesting logic is unit-tested in
/// RiffKit, so these only cover the wiring that unit tests cannot see —
/// navigation, persistence reaching the UI, and the states each screen shows.
final class RiffUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uitesting"]
        app.launch()
    }

    // MARK: - Launch

    func testLaunchesOnFavoritesWithEmptyState() {
        XCTAssertTrue(app.staticTexts["No songs yet"].waitForExistence(timeout: 10))
    }

    func testAllFourTabsAreReachable() {
        tapTab("Playlists")
        XCTAssertTrue(app.staticTexts["My Playlists"].waitForExistence(timeout: 5))

        tapTab("Search")
        XCTAssertTrue(app.staticTexts["Find music"].waitForExistence(timeout: 5))

        tapTab("More")
        XCTAssertTrue(app.buttons["settingsRow"].waitForExistence(timeout: 5))

        tapTab("My Favorites")
        XCTAssertTrue(app.staticTexts["No songs yet"].waitForExistence(timeout: 5))
    }

    // MARK: - Playlists

    func testCreatingPlaylistFromToolbar() {
        tapTab("Playlists")
        createPlaylist(named: "Late Night")

        XCTAssertTrue(app.staticTexts["Late Night"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["0 Tracks"].exists)
    }

    func testOpeningPlaylistShowsItsEmptyState() {
        tapTab("Playlists")
        createPlaylist(named: "Gym")

        app.staticTexts["Gym"].firstMatch.tap()

        XCTAssertTrue(app.staticTexts["No songs yet"].waitForExistence(timeout: 5))
    }

    /// The derived playlists are always present, even with an empty library,
    /// because they are sorts rather than stored rows.
    func testSmartPlaylistsAreAlwaysListed() {
        tapTab("Playlists")
        XCTAssertTrue(app.staticTexts["Recently Added"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Recently Played"].exists)
    }

    /// Guards the test isolation hook itself: under `-uitesting` each launch
    /// gets a fresh temp store, which is what keeps every other test here
    /// independent of run order.
    func testEachLaunchStartsFromACleanLibrary() {
        tapTab("Playlists")
        createPlaylist(named: "Temporary")
        XCTAssertTrue(app.staticTexts["Temporary"].waitForExistence(timeout: 5))

        app.terminate()
        app.launch()

        tapTab("Playlists")
        XCTAssertFalse(
            app.staticTexts["Temporary"].waitForExistence(timeout: 3),
            "a fresh launch should not inherit the previous run's library"
        )
    }

    // MARK: - Search

    /// SwiftUI focuses a field asynchronously after the tap, so `typeText` that
    /// lands before focus arrives is silently dropped. Rather than sleeping,
    /// this gates on the clear button, which only renders once the text has
    /// actually reached the binding, rather than waiting a fixed time.
    func testSearchFieldAcceptsTyping() {
        tapTab("Search")
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        _ = app.keyboards.element.waitForExistence(timeout: 5)
        field.typeText("benyamin")

        let clear = app.buttons["clearSearchButton"]
        // Retry only if the field is genuinely still empty. Gating the retry on
        // the clear button alone types a second time whenever the button merely
        // rendered slowly, which produces "benyaminbenyamin".
        if !clear.waitForExistence(timeout: 3), (field.value as? String) == "Search" {
            field.tap()
            field.typeText("benyamin")
        }
        XCTAssertTrue(clear.waitForExistence(timeout: 8), "typed text should reach the binding")
        XCTAssertEqual(field.value as? String, "benyamin")

        clear.tap()
        XCTAssertFalse(clear.waitForExistence(timeout: 2), "clearing should empty the query")
    }

    // MARK: - Settings

    func testSettingsExplainsBothPlaybackPaths() {
        openSettings()
        XCTAssertTrue(app.staticTexts["YouTube tracks"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Imported files"].exists)
        XCTAssertTrue(app.staticTexts["When YouTube breaks it"].exists)
        XCTAssertTrue(app.staticTexts["No account, no key"].exists)
    }

    func testMoreTabShowsLibraryCounts() {
        tapTab("More")
        XCTAssertTrue(app.staticTexts["Songs"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Playlists"].exists)
        XCTAssertTrue(app.staticTexts["Imported Files"].exists)
    }

    // MARK: - Helpers

    private func tapTab(_ name: String) {
        let tab = app.tabBars.buttons[name]
        if tab.waitForExistence(timeout: 5) {
            tab.tap()
        } else {
            app.buttons[name].tap()
        }
    }

    private func openSettings() {
        tapTab("More")
        let settings = app.buttons["settingsRow"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
    }

    /// Creates a playlist from the Playlists tab's + button.
    private func createPlaylist(named name: String) {
        app.buttons["newPlaylistButton"].tap()

        let alert = app.alerts["New Playlist"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "the name prompt should appear")
        let field = alert.textFields.firstMatch
        field.tap()
        field.typeText(name)
        alert.buttons["Create"].tap()
    }
}
