import XCTest

/// End-to-end checks that the app launches and its core flows work on a real
/// simulator. Deliberately thin: the interesting logic is unit-tested in
/// ShirKit, so these only cover the wiring that unit tests cannot see —
/// navigation, persistence reaching the UI, and the states each screen shows.
final class ShirUITests: ShirUITestCase {

    // MARK: - Launch

    func testLaunchesOnFavoritesWithEmptyState() {
        XCTAssertTrue(app.staticTexts["No songs yet"].waitForExistence(timeout: 10))
    }

    func testAllFourTabsAreReachable() {
        app.tapTab("Playlists")
        XCTAssertTrue(app.staticTexts["My Playlists"].waitForExistence(timeout: 5))

        app.tapTab("Search")
        // The field, not the idle prompt: with a network the resting screen is
        // the trending charts, without one it is the prompt — the field is the
        // one element present either way.
        XCTAssertTrue(app.textFields["searchField"].waitForExistence(timeout: 5))

        app.tapTab("More")
        XCTAssertTrue(app.buttons["settingsRow"].waitForExistence(timeout: 5))

        app.tapTab("My Favorites")
        XCTAssertTrue(app.staticTexts["No songs yet"].waitForExistence(timeout: 5))
    }

    // MARK: - Playlists

    func testCreatingPlaylistFromToolbar() {
        app.tapTab("Playlists")
        app.createPlaylist(named: "Late Night")

        XCTAssertTrue(app.staticTexts["Late Night"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["0 Tracks"].exists)
    }

    func testOpeningPlaylistShowsItsEmptyState() {
        app.tapTab("Playlists")
        app.createPlaylist(named: "Gym")

        app.staticTexts["Gym"].firstMatch.tap()

        XCTAssertTrue(app.staticTexts["No songs yet"].waitForExistence(timeout: 5))
    }

    /// The derived playlists are always present, even with an empty library,
    /// because they are sorts rather than stored rows.
    func testSmartPlaylistsAreAlwaysListed() {
        app.tapTab("Playlists")
        XCTAssertTrue(app.staticTexts["Recently Added"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Recently Played"].exists)
    }

    /// Guards the test isolation hook itself: under `-uitesting` each launch
    /// gets a fresh temp store, which is what keeps every other test here
    /// independent of run order.
    func testEachLaunchStartsFromACleanLibrary() {
        app.tapTab("Playlists")
        app.createPlaylist(named: "Temporary")
        XCTAssertTrue(app.staticTexts["Temporary"].waitForExistence(timeout: 5))

        app.terminate()
        app.launch()

        app.tapTab("Playlists")
        XCTAssertFalse(
            app.staticTexts["Temporary"].waitForExistence(timeout: 3),
            "a fresh launch should not inherit the previous run's library"
        )
    }

    // MARK: - Search

    func testSearchFieldAcceptsTyping() {
        app.tapTab("Search")
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        typeQuery("benyamin", into: field)
        XCTAssertEqual(field.value as? String, "benyamin")

        let clear = app.buttons["clearSearchButton"]
        clear.tap()
        XCTAssertFalse(clear.waitForExistence(timeout: 2), "clearing should empty the query")
    }

    /// History is recorded on submit regardless of whether the search itself
    /// succeeded, so this covers the whole loop without needing the network.
    func testSubmittingASearchRecordsItInHistory() {
        app.tapTab("Search")
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        typeQuery("ahmad zahir", into: field)

        // Return key, not app.buttons["Search"] — that matches the tab bar first.
        field.typeText("\n")

        app.buttons["clearSearchButton"].tap()
        field.tap()

        let entry = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "ahmad zahir")
        ).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 10), "the query should appear in history")
    }

    func testDeletingAHistoryEntryRemovesIt() {
        app.tapTab("Search")
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        typeQuery("gym music", into: field)
        field.typeText("\n")

        app.buttons["clearSearchButton"].tap()
        field.tap()

        let entry = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "gym music")
        ).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 10))

        app.buttons["deleteHistory-gym music"].tap()
        XCTAssertFalse(entry.waitForExistence(timeout: 3), "deleting should remove the entry")
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
        app.tapTab("More")
        XCTAssertTrue(app.staticTexts["Songs"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Playlists"].exists)
        XCTAssertTrue(app.staticTexts["Imported Files"].exists)
    }

    // MARK: - Helpers

    /// SwiftUI focuses fields asynchronously, so text typed before focus lands
    /// is silently dropped. Rather than sleeping, this gates on the clear
    /// button, which only renders once the text reached the binding. The retry
    /// checks the field is genuinely still empty — gating it on the button
    /// alone types twice whenever the button merely rendered slowly, giving
    /// "benyaminbenyamin".
    private func typeQuery(_ text: String, into field: XCUIElement) {
        field.tap()
        _ = app.keyboards.element.waitForExistence(timeout: 5)
        field.typeText(text)

        let clear = app.buttons["clearSearchButton"]
        if !clear.waitForExistence(timeout: 3), (field.value as? String) == "Search" {
            field.tap()
            field.typeText(text)
        }
        XCTAssertTrue(clear.waitForExistence(timeout: 8), "typed text should reach the binding")
    }

    private func openSettings() {
        app.tapTab("More")
        let settings = app.buttons["settingsRow"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
    }
}
