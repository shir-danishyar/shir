import XCTest

/// Pulling Now Playing down minimises it, and only a downward pull does.
///
/// The unit tests in `NowPlayingDragPolicyTests` settle the arithmetic; what
/// they structurally cannot see is whether the gesture is reached at all —
/// whether SwiftUI hands the drag to the screen rather than to a Button, a
/// Slider, or the web view sitting in the middle of it. That is what these two
/// are for.
///
/// Runs offline: `-seedLibrary` puts YouTube-sourced tracks in the catalogue,
/// so the stage mounts and can be dragged whether or not the video loads.
final class NowPlayingDismissGestureTests: ShirUITestCase {
    override var extraLaunchArguments: [String] { ["-seedLibrary"] }

    func testPullingDownMinimisesToTheMiniPlayer() {
        app.openNowPlayingForSeededSong()

        let stage = app.otherElements["playerStage"]
        XCTAssertTrue(stage.waitForExistence(timeout: 5), "the stage should be mounted")

        // `exists` is the wrong question to ask about the mini player: it is a
        // sibling layer behind the player rather than a separate presentation,
        // so XCUITest enumerates it either way. `isHittable` is the one that
        // discriminates — it is covered now and reachable afterwards.
        XCTAssertFalse(app.buttons["miniPlayerToggle"].isHittable,
                       "the mini player should be covered while the player is up")

        let start = stage.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 500)))

        // Waited for, not asserted outright: the exit animation runs for 250ms
        // after the finger lifts, and the chevron is on screen for all of it.
        XCTAssertTrue(app.buttons["dismissNowPlaying"].waitForNonExistence(timeout: 5),
                      "Now Playing should be closed")
        XCTAssertTrue(app.buttons["miniPlayerToggle"].isHittable,
                      "pulling down should leave the mini player, exactly as the chevron does")
    }

    /// The direction lock, end to end. A sideways drag is how a seek starts.
    func testDraggingSidewaysDoesNotMinimise() {
        app.openNowPlayingForSeededSong()

        let stage = app.otherElements["playerStage"]
        XCTAssertTrue(stage.waitForExistence(timeout: 5))

        let start = stage.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 250, dy: 60)))

        XCTAssertTrue(app.buttons["dismissNowPlaying"].exists,
                      "a sideways drag must leave Now Playing open")
    }
}
