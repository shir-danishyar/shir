import XCTest
@testable import ShirKit

/// The judgement behind background playback: WebKit's forced pause must be
/// answered, everyone else's pause must be respected, and the answering must
/// not loop forever.
final class AutoResumePolicyTests: XCTestCase {

    /// A policy in the state the engine is in mid-song.
    private func playing() -> AutoResumePolicy {
        var policy = AutoResumePolicy()
        policy.noteLoad(autoplay: true)
        policy.notePlaying()
        return policy
    }

    // MARK: - The case this exists for

    func testUnrequestedPauseAfterAutoplayLoadIsResumed() {
        var policy = AutoResumePolicy()
        policy.noteLoad(autoplay: true)
        XCTAssertTrue(policy.shouldResumeAfterUnrequestedPause())
    }

    func testPauseAfterCueOnlyLoadIsNotResumed() {
        var policy = AutoResumePolicy()
        policy.noteLoad(autoplay: false)
        XCTAssertFalse(policy.shouldResumeAfterUnrequestedPause())
    }

    /// Backgrounding repeatedly is normal use and has to work every time, so a
    /// resume that succeeds restores the budget.
    func testRepeatedBackgroundingIsAnsweredEveryTime() {
        var policy = playing()
        for _ in 0..<10 {
            XCTAssertTrue(policy.shouldResumeAfterUnrequestedPause())
            policy.notePlaying()
        }
    }

    // MARK: - Pauses that must be respected

    func testUserPauseIsRespected() {
        var policy = playing()
        policy.notePause()
        XCTAssertFalse(policy.shouldResumeAfterUnrequestedPause())
    }

    /// The headphones came out. Resuming would play the song out loud.
    func testOutputDeviceDisconnectIsNotFought() {
        var policy = playing()
        policy.noteOutputDeviceDisconnected()
        XCTAssertFalse(policy.shouldResumeAfterUnrequestedPause())
    }

    /// A call or Siri. iOS owns the audio until it says otherwise.
    func testPauseDuringAnInterruptionIsNotFought() {
        var policy = playing()
        policy.noteInterruptionBegan()
        XCTAssertFalse(policy.shouldResumeAfterUnrequestedPause())
    }

    func testInterruptionEndResumesWhenTheSystemSaysSo() {
        var policy = playing()
        policy.noteInterruptionBegan()
        XCTAssertTrue(policy.noteInterruptionEnded(shouldResume: true))
    }

    func testInterruptionEndDoesNotResumeWhenTheSystemSaysNot() {
        var policy = playing()
        policy.noteInterruptionBegan()
        XCTAssertFalse(policy.noteInterruptionEnded(shouldResume: false))
    }

    /// Ending an interruption must not restart audio the user had paused
    /// before the call arrived.
    func testInterruptionEndDoesNotResumeAfterAUserPause() {
        var policy = playing()
        policy.notePause()
        policy.noteInterruptionBegan()
        XCTAssertFalse(policy.noteInterruptionEnded(shouldResume: true))
    }

    /// Playing reported *during* an interruption must not re-arm intent —
    /// otherwise the interruption guard evaporates on the next event.
    func testPlayingDuringAnInterruptionDoesNotReArmIntent() {
        var policy = playing()
        policy.notePause()
        policy.noteInterruptionBegan()
        policy.notePlaying()
        XCTAssertFalse(policy.shouldResumeAfterUnrequestedPause())
    }

    // MARK: - Playback that is over

    func testStopEndsResumption() {
        var policy = playing()
        policy.notePlaybackEnded()
        XCTAssertFalse(policy.shouldResumeAfterUnrequestedPause())
    }

    /// The queue ran out. A page that navigates itself and starts playing must
    /// not resurrect the session minutes later.
    func testLatePlayingAfterTheQueueEndsDoesNotReArm() {
        var policy = playing()
        policy.notePlaybackEnded()
        policy.notePlaying()
        XCTAssertFalse(policy.shouldResumeAfterUnrequestedPause())
    }

    // MARK: - Re-arming

    func testPlayAfterUserPauseReArmsResumption() {
        var policy = playing()
        policy.notePause()
        policy.notePlay()
        XCTAssertTrue(policy.shouldResumeAfterUnrequestedPause())
    }

    /// WebKit resumes elements it force-paused when the app foregrounds. That
    /// audible playback has to count as wanted, or the next home press kills
    /// the music.
    func testWebKitsOwnResumeRestoresIntent() {
        var policy = playing()
        policy.notePause()          // user paused from the lock screen
        policy.notePlaying()        // WebKit resumed it on foregrounding
        XCTAssertTrue(policy.wantsPlayback)
        XCTAssertTrue(policy.shouldResumeAfterUnrequestedPause())
    }

    func testFreshLoadResetsAnExhaustedBudget() {
        var policy = playing()
        while policy.shouldResumeAfterUnrequestedPause() {}
        policy.noteLoad(autoplay: true)
        XCTAssertTrue(policy.shouldResumeAfterUnrequestedPause())
    }

    /// A pause that keeps winning gets three answers, then wins.
    func testConsecutiveFailedResumesAreCapped() {
        var policy = playing()
        XCTAssertTrue(policy.shouldResumeAfterUnrequestedPause())
        XCTAssertTrue(policy.shouldResumeAfterUnrequestedPause())
        XCTAssertTrue(policy.shouldResumeAfterUnrequestedPause())
        XCTAssertFalse(policy.shouldResumeAfterUnrequestedPause())
    }
}
