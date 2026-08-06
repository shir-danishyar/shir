import XCTest

/// Guards the size of the video stage on Now Playing.
///
/// The stage used to be laid out as `.aspectRatio(16/9, contentMode: .fit)`
/// inside a `VStack`, which looks right and is not: a stack proposes each child
/// a *share* of the available height, and `.fit` then shrinks the width to
/// honour the ratio. The result was a video about 56% of the screen width,
/// centred, instead of the edge-to-edge stage the reference has. Nothing about
/// that failure is visible in a compile or in a unit test — only in geometry.
///
/// Runs offline: `-seedLibrary` puts YouTube-sourced tracks in the catalogue, so
/// the web view mounts and gets its frame whether or not the video can load.
final class NowPlayingStageTests: ShirUITestCase {
    override var extraLaunchArguments: [String] { ["-seedLibrary"] }

    func testStageSpansTheFullScreenWidthAtSixteenByNine() {
        app.openNowPlayingForSeededSong()

        let stage = app.otherElements["playerStage"]
        XCTAssertTrue(stage.waitForExistence(timeout: 5), "the stage should be mounted for a YouTube track")

        let screenWidth = app.windows.firstMatch.frame.width
        XCTAssertEqual(stage.frame.width, screenWidth, accuracy: 1,
                       "the stage must span the full screen width, not a fraction of it")
        // 9/16 restates Theme.videoAspectRatio — the UI-test target cannot see
        // the app module, so the ratio has to be written out here.
        XCTAssertEqual(stage.frame.height, screenWidth * 9 / 16, accuracy: 1,
                       "the stage must be 16:9")
    }
}
