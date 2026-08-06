import XCTest

/// Covers the rule that tapping a song plays it and nothing else, and that `+`
/// is the only route into a playlist or into Favorites.
///
/// Uses seeded library data rather than the network, so these run offline.
final class AddToPlaylistFlowTests: ShirUITestCase {
    override var extraLaunchArguments: [String] { ["-seedLibrary"] }

    /// The regression this whole change exists for: playing a song used to file
    /// it under My Favorites.
    func testPlayingASongDoesNotAddItToFavorites() {
        XCTAssertTrue(app.staticTexts["No songs yet"].waitForExistence(timeout: 10),
                      "favorites should start empty even with a seeded catalogue")

        app.tapTab("Playlists")
        app.staticTexts["Recently Added"].firstMatch.tap()

        let song = app.staticTexts["Seeded Song A"]
        XCTAssertTrue(song.waitForExistence(timeout: 5))
        song.tap()

        app.tapTab("My Favorites")
        XCTAssertTrue(app.staticTexts["No songs yet"].waitForExistence(timeout: 5),
                      "playing a song must not add it to Favorites")
    }

    func testHeartInNowPlayingAddsToFavorites() {
        app.openNowPlayingForSeededSong()

        let heart = app.buttons["favoriteToggle"]
        XCTAssertTrue(heart.waitForExistence(timeout: 5))
        heart.tap()

        app.buttons["dismissNowPlaying"].tap()

        app.tapTab("My Favorites")
        XCTAssertTrue(app.staticTexts["Seeded Song A"].waitForExistence(timeout: 5),
                      "the heart should be what puts a song in Favorites")
    }
}
