import XCTest
@testable import ShirKit

/// The rules a pull-down on Now Playing obeys.
///
/// The hazard this type exists to contain is the scrubber: it sits in the
/// middle of the screen the drag covers, and a seek that turned into a dismiss
/// would be maddening. Two independent rules stop it — the drag stands down
/// while the slider has the touch, and a drag that starts out horizontal is
/// rejected for good — so both are tested here rather than trusted to SwiftUI's
/// gesture arbitration.
final class NowPlayingDragPolicyTests: XCTestCase {
    private let screenHeight: CGFloat = 800

    private func drag(_ translation: CGSize, isScrubbing: Bool = false) -> NowPlayingDragPolicy {
        var policy = NowPlayingDragPolicy()
        policy.update(translation: translation, isScrubbing: isScrubbing)
        return policy
    }

    // MARK: - Following the finger

    func testDownwardDragTracksTheFingerExactly() {
        XCTAssertEqual(drag(CGSize(width: 0, height: 120)).offset, 120)
    }

    func testASlightSidewaysWobbleStillTracksDownward() {
        // Real fingers are not plumb. Only a *predominantly* horizontal drag is
        // a rejection.
        XCTAssertEqual(drag(CGSize(width: 18, height: 120)).offset, 120)
    }

    func testUpwardDragResists() {
        let policy = drag(CGSize(width: 0, height: -100))
        XCTAssertEqual(policy.offset, -20, "up should move at a fifth of the finger")
    }

    func testUpwardDragIsCapped() {
        let policy = drag(CGSize(width: 0, height: -5000))
        XCTAssertEqual(policy.offset, -NowPlayingDragPolicy.maximumUpwardOffset,
                       "the player must not be tearable off the top of the screen")
    }

    // MARK: - Drags that are not dismissals

    func testHorizontalDragIsRejected() {
        let policy = drag(CGSize(width: 120, height: 20))
        XCTAssertTrue(policy.isRejected)
        XCTAssertEqual(policy.offset, 0)
    }

    func testARejectedDragStaysRejectedWhenItTurnsVertical() {
        // The direction lock is decided once. Without this, a seek that drifted
        // downward at the end would dismiss the screen mid-scrub.
        var policy = NowPlayingDragPolicy()
        policy.update(translation: CGSize(width: 120, height: 20), isScrubbing: false)
        policy.update(translation: CGSize(width: 120, height: 400), isScrubbing: false)
        XCTAssertEqual(policy.offset, 0)
        XCTAssertEqual(policy.resolve(predictedEnd: CGSize(width: 120, height: 400),
                                      screenHeight: screenHeight), .restore)
    }

    func testScrubbingRejectsTheDrag() {
        let policy = drag(CGSize(width: 0, height: 400), isScrubbing: true)
        XCTAssertTrue(policy.isRejected)
        XCTAssertEqual(policy.offset, 0)
    }

    func testMovementShorterThanTheLockDistanceDoesNotMoveThePlayer() {
        XCTAssertEqual(drag(CGSize(width: 0, height: 4)).offset, 0)
    }

    // MARK: - Releasing

    func testReleasingPastAQuarterOfTheScreenDismisses() {
        let policy = drag(CGSize(width: 0, height: 260))
        XCTAssertEqual(policy.resolve(predictedEnd: CGSize(width: 0, height: 260),
                                      screenHeight: screenHeight), .dismiss)
    }

    func testReleasingShortOfAQuarterOfTheScreenSpringsBack() {
        let policy = drag(CGSize(width: 0, height: 150))
        XCTAssertEqual(policy.resolve(predictedEnd: CGSize(width: 0, height: 150),
                                      screenHeight: screenHeight), .restore)
    }

    func testAHardFlickDismissesWithoutTravellingFar() {
        // 60pt of travel, but thrown hard enough that it would have carried
        // most of the screen. That is a dismiss to anyone's hand.
        let policy = drag(CGSize(width: 0, height: 60))
        XCTAssertEqual(policy.resolve(predictedEnd: CGSize(width: 0, height: 700),
                                      screenHeight: screenHeight), .dismiss)
    }

    func testAFlickUpwardNeverDismisses() {
        let policy = drag(CGSize(width: 0, height: -60))
        XCTAssertEqual(policy.resolve(predictedEnd: CGSize(width: 0, height: -700),
                                      screenHeight: screenHeight), .restore)
    }

    // MARK: - Between drags

    func testResetClearsTheOffsetAndTheRejection() {
        var policy = drag(CGSize(width: 200, height: 10))
        policy.reset()
        XCTAssertFalse(policy.isRejected)
        XCTAssertEqual(policy.offset, 0)

        policy.update(translation: CGSize(width: 0, height: 120), isScrubbing: false)
        XCTAssertEqual(policy.offset, 120, "a fresh drag should track again")
    }

    func testSettleDrivesTheOffsetToTheExitPosition() {
        var policy = drag(CGSize(width: 0, height: 260))
        policy.settle(at: screenHeight)
        XCTAssertEqual(policy.offset, screenHeight)
    }
}
