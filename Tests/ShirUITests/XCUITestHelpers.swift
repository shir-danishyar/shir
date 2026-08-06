import XCTest

/// Boots the app once per test with `-uitesting` plus whatever a suite adds.
/// Owns the scaffolding that used to be copied into every suite's
/// `setUpWithError` — one fact, one place.
class ShirUITestCase: XCTestCase {
    var app: XCUIApplication!

    /// Suites override to add seeds or seams; `-uitesting` is always on so
    /// every launch starts from a clean temp library.
    var extraLaunchArguments: [String] { [] }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uitesting"] + extraLaunchArguments
        app.launch()
    }
}

extension XCUIApplication {
    /// Taps a tab by name. This was copied into four test files before it
    /// lived here — one fact, one place.
    ///
    /// The fallback exists because the tab bar's buttons are not always
    /// exposed under `tabBars` immediately after launch; a plain button match
    /// finds the same control when the query misses.
    func tapTab(_ name: String) {
        let tab = tabBars.buttons[name]
        if tab.waitForExistence(timeout: 5) { tab.tap() } else { buttons[name].tap() }
    }

    /// Creates a playlist through the toolbar prompt on the Playlists tab.
    func createPlaylist(named name: String) {
        buttons["newPlaylistButton"].tap()
        let alert = alerts["New Playlist"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "the name prompt should appear")
        let field = alert.textFields.firstMatch
        field.tap()
        field.typeText(name)
        alert.buttons["Create"].tap()
    }

    /// Plays "Seeded Song A" from Recently Added and opens Now Playing via the
    /// mini bar — the route the seeded-library flow tests share. The mini bar
    /// is reached by coordinate because its title area has no identifier and
    /// the row that was just tapped matches the same title text.
    func openNowPlayingForSeededSong() {
        tapTab("Playlists")
        staticTexts["Recently Added"].firstMatch.tap()

        let song = staticTexts["Seeded Song A"]
        XCTAssertTrue(song.waitForExistence(timeout: 5))
        song.tap()

        let mini = buttons["miniPlayerToggle"]
        XCTAssertTrue(mini.waitForExistence(timeout: 5))
        coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 120, dy: mini.frame.midY))
            .tap()
        XCTAssertTrue(buttons["dismissNowPlaying"].waitForExistence(timeout: 5))
    }
}
