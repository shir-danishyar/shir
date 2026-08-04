import XCTest

/// End-to-end checks that the app launches and its core flows work on a real
/// simulator. Deliberately thin: the interesting logic is unit-tested in
/// ShirKit, so these only cover the wiring that unit tests cannot see —
/// navigation, persistence reaching the UI, and the states each screen shows.
final class ShirUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uitesting"]
        app.launch()
    }

    // MARK: - Launch

    func testLaunchesOnLibraryTabWithEmptyState() {
        XCTAssertTrue(app.staticTexts["Library"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["No playlists yet"].exists)
        XCTAssertTrue(app.buttons["Create Playlist"].exists)
    }

    func testAllThreeTabsAreReachable() {
        tapTab("Search")
        XCTAssertTrue(app.staticTexts["Search"].firstMatch.waitForExistence(timeout: 5))

        tapTab("Settings")
        XCTAssertTrue(app.staticTexts["YouTube Data API key"].waitForExistence(timeout: 5))

        tapTab("Library")
        XCTAssertTrue(app.staticTexts["No playlists yet"].waitForExistence(timeout: 5))
    }

    // MARK: - Playlists

    func testCreatingPlaylistFromEmptyState() {
        app.buttons["Create Playlist"].tap()
        createPlaylist(named: "Late Night")

        XCTAssertTrue(app.staticTexts["Late Night"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["0 songs"].exists)
        XCTAssertFalse(app.staticTexts["No playlists yet"].exists, "the empty state should be replaced")
    }

    func testOpeningPlaylistShowsItsEmptyState() {
        app.buttons["Create Playlist"].tap()
        createPlaylist(named: "Gym")

        app.staticTexts["Gym"].firstMatch.tap()

        XCTAssertTrue(app.staticTexts["No songs yet"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Play"].exists)
        XCTAssertTrue(app.buttons["Shuffle"].exists)
    }

    /// Guards the test isolation hook itself: under `-uitesting` each launch
    /// gets a fresh temp store, which is what keeps every other test here
    /// independent of run order.
    func testEachLaunchStartsFromACleanLibrary() {
        app.buttons["Create Playlist"].tap()
        createPlaylist(named: "Temporary")
        XCTAssertTrue(app.staticTexts["Temporary"].waitForExistence(timeout: 5))

        app.terminate()
        app.launch()

        XCTAssertTrue(app.staticTexts["No playlists yet"].waitForExistence(timeout: 10))
    }

    func testCreatingSecondPlaylistFromToolbar() {
        app.buttons["Create Playlist"].tap()
        createPlaylist(named: "First")
        XCTAssertTrue(app.staticTexts["First"].waitForExistence(timeout: 5))

        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["New Playlist"].tap()
        createPlaylist(named: "Second")

        XCTAssertTrue(app.staticTexts["Second"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["First"].exists)
    }

    // MARK: - Search

    func testSearchTellsYouWhenTheAPIKeyIsMissing() {
        tapTab("Search")
        XCTAssertTrue(app.staticTexts["YouTube key needed"].waitForExistence(timeout: 5))
    }

    // MARK: - Settings

    func testSettingsExplainsBothPlaybackPaths() {
        tapTab("Settings")
        XCTAssertTrue(app.staticTexts["YouTube tracks"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Imported files"].exists)
        XCTAssertTrue(app.staticTexts["Why not strip the ads?"].exists)
    }

    func testSavingAPIKeyUnlocksSearch() {
        tapTab("Settings")
        enterAndSaveAPIKey()

        XCTAssertTrue(app.staticTexts["Key saved"].waitForExistence(timeout: 10))

        tapTab("Search")
        XCTAssertFalse(
            app.staticTexts["YouTube key needed"].exists,
            "saving a key should remove the missing-key notice"
        )
    }

    func testRemovingSavedKeyRestoresTheNotice() {
        tapTab("Settings")
        enterAndSaveAPIKey()
        XCTAssertTrue(app.staticTexts["Key saved"].waitForExistence(timeout: 10))

        app.buttons["Remove Key"].tap()

        tapTab("Search")
        XCTAssertTrue(app.staticTexts["YouTube key needed"].waitForExistence(timeout: 5))
    }

    func testLibraryCountsAreShownInSettings() {
        app.buttons["Create Playlist"].tap()
        createPlaylist(named: "Counted")

        tapTab("Settings")
        let playlists = app.staticTexts["Playlists"]
        XCTAssertTrue(playlists.waitForExistence(timeout: 5))
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Saved songs"].exists)
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

    /// Types a key into the Settings field and saves it.
    ///
    /// SwiftUI focuses a field asynchronously after the tap, and `typeText`
    /// into a not-yet-focused field is silently dropped — which made the two
    /// key tests flaky. Rather than sleeping, this gates on the Save button
    /// becoming enabled, which only happens once the text actually landed in
    /// the binding, and retries the typing once if it didn't.
    private func enterAndSaveAPIKey(_ key: String = "AIzaTestKeyNotReal") {
        let field = app.secureTextFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the key field should be on screen")
        field.tap()
        _ = app.keyboards.element.waitForExistence(timeout: 5)
        field.typeText(key)

        let save = app.buttons["Save Key"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))

        if !save.isEnabled {
            field.tap()
            field.typeText(key)
        }

        let enabled = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: save)
        wait(for: [enabled], timeout: 10)
        save.tap()
    }

    private func createPlaylist(named name: String) {
        let alert = app.alerts["New Playlist"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "the name prompt should appear")
        let field = alert.textFields.firstMatch
        field.tap()
        field.typeText(name)
        alert.buttons["Create"].tap()
    }
}
