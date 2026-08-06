import XCTest

/// Proves the app's core promise: YouTube audio keeps playing when the app
/// leaves the foreground. The failure mode this guards is silent and
/// upstream — a WebKit or YouTube change would present as "music stops at
/// home press" with nothing else wrong. The mechanism being exercised is
/// `AutoResumePolicy` via `YouTubePlayerEngine`; CLAUDE.md §9 has the full
/// story.
///
/// The verdict is the elapsed-time *delta* across a backgrounded interval,
/// not the play/pause icon: WebKit can auto-resume on foregrounding, which
/// makes the icon lie about what happened while backgrounded.
///
/// Needs the network: seeded tracks carry fake video ids YouTube cannot play,
/// so this drives a real video through the launch-argument seams (§8).
final class BackgroundPlaybackTests: ShirUITestCase {
    override var extraLaunchArguments: [String] {
        ["-autoplayVideoID", "dQw4w9WgXcQ", "-autoOpenNowPlaying", "YES"]
    }

    func testAudioSurvivesBackgrounding() {
        // YouTube occasionally refuses to start a stream in the simulator —
        // seen live when this runs late in a full-suite pass. One relaunch
        // absorbs that flake; the backgrounding assertion itself stays strict.
        var t0 = waitForPlaybackStart()
        if t0 == nil {
            app.terminate()
            app.launch()
            t0 = waitForPlaybackStart()
        }
        guard let before = t0 else {
            XCTFail("playback never started, even after a relaunch — check the network, then AdStrip/Bridge")
            return
        }

        XCUIDevice.shared.press(.home)
        // A wall-clock sleep is the point: the assertion is about how far the
        // audio advanced during this interval, not about waiting for UI.
        Thread.sleep(forTimeInterval: 20)

        app.activate()
        XCTAssertTrue(app.buttons["dismissNowPlaying"].waitForExistence(timeout: 10))
        // Let the bridge deliver a fresh position after foregrounding.
        Thread.sleep(forTimeInterval: 2)

        let after = elapsedSeconds(app) ?? -1
        XCTAssertGreaterThanOrEqual(
            after - before, 12,
            "elapsed advanced \(after - before)s across a 20s backgrounded interval — audio stopped"
        )
    }

    /// Waits for the cover to be open and elapsed time to move off 0:00.
    private func waitForPlaybackStart() -> Int? {
        guard app.buttons["dismissNowPlaying"].waitForExistence(timeout: 10) else {
            XCTFail("Now Playing should auto-open via the test seam")
            return nil
        }
        let start = Date()
        while Date().timeIntervalSince(start) < 90 {
            if let s = elapsedSeconds(app), s >= 3 { return s }
        }
        return nil
    }

    /// First visible m:ss label; the remaining-time label starts with "-" and
    /// never matches.
    private func elapsedSeconds(_ app: XCUIApplication) -> Int? {
        for t in app.staticTexts.allElementsBoundByIndex {
            let l = t.label
            guard l.range(of: #"^\d+:\d{2}$"#, options: .regularExpression) != nil else { continue }
            let p = l.split(separator: ":").compactMap { Int($0) }
            if p.count == 2 { return p[0] * 60 + p[1] }
        }
        return nil
    }
}
