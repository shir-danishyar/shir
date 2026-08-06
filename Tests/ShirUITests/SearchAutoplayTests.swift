import XCTest

/// The first-run promise: search, tap a result, music plays — no second tap.
///
/// This used to fail structurally: the tap started the engine with the web
/// view in no window, WebKit refuses to *start* media in a view that is not
/// genuinely visible, and the track sat cued until the user opened Now
/// Playing and pressed play. Starting a song now presents Now Playing, which
/// mounts the stage, which is what lets playback begin at all.
///
/// Needs the network — it drives a real search and a real video.
final class SearchAutoplayTests: ShirUITestCase {

    /// The default Search screen is the trending charts, not an empty prompt.
    /// Network-dependent like everything else in this suite; when this fails
    /// alone, the lockup parser broke — TrendingClientTests names the spot.
    func testDefaultSearchShowsTrendingCharts() {
        app.tapTab("Search")
        XCTAssertTrue(app.staticTexts["Top Tracks"].waitForExistence(timeout: 20),
                      "the charts should replace the idle prompt")
        XCTAssertTrue(app.staticTexts["Top New Tracks"].exists)
    }

    func testTappingASearchResultPlaysWithoutFurtherTaps() {
        app.tapTab("Search")
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("dawood sarkhosh\n")

        // Aim at the artist line: the row identifier resolves to the trailing
        // `+` (pitfalls index), the artist text is safely inside the row.
        let row = app.staticTexts["Sarkhosh Music Inc."].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "no search results")
        row.tap()

        XCTAssertTrue(app.buttons["dismissNowPlaying"].waitForExistence(timeout: 5),
                      "tapping a result should open Now Playing on its own")

        // The actual promise: elapsed time moves with no further interaction.
        var started = false
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            if let s = elapsedSeconds(), s >= 3 { started = true; break }
        }
        XCTAssertTrue(started, "the tapped result should play by itself")
    }

    /// First visible m:ss label; the remaining-time label starts with "-" and
    /// never matches.
    private func elapsedSeconds() -> Int? {
        for t in app.staticTexts.allElementsBoundByIndex {
            let l = t.label
            guard l.range(of: #"^\d+:\d{2}$"#, options: .regularExpression) != nil else { continue }
            let p = l.split(separator: ":").compactMap { Int($0) }
            if p.count == 2 { return p[0] * 60 + p[1] }
        }
        return nil
    }
}
