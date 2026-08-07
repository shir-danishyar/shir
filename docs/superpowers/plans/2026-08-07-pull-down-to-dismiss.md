# Pull Down to Dismiss Now Playing — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a downward drag anywhere on Now Playing minimise it to the mini player, doing exactly what the existing chevron button does.

**Architecture:** The drag's judgement — how far the player follows the finger, when a drag is not a dismiss, and whether a release dismisses or springs back — becomes a pure value type in ShirKit next to `AutoResumePolicy`, unit-tested on macOS. Now Playing stops being a `fullScreenCover` and becomes a conditional layer in the `ZStack` that `RootTabView` already has, because a `.fullScreen` modal removes the presenting view from the window and there would be nothing to reveal behind the drag. The chevron and the drag then share one exit animation.

**Tech Stack:** Swift 5.9, SwiftUI, iOS 17+, XCTest (ShirKit unit tests on macOS; XCUITest on simulator), XcodeGen.

## Global Constraints

- Deployment target iOS 17.0. `withAnimation(_:completionCriteria:_:completion:)` and `@Observable` are available; nothing newer may be used.
- ShirKit imports **no UI framework** — no SwiftUI, no UIKit, no WebKit. CoreGraphics (`CGFloat`, `CGSize`) is permitted, on the same reasoning that permits JavaScriptCore.
- `Shir.xcodeproj` is generated and gitignored. Never edit it; run `xcodegen generate` after adding a file to a target's source directory.
- The accessibility identifier `dismissNowPlaying` and the chevron button it names must both survive — seven existing UI tests depend on them.
- No dead code and no commented-out code. A deleted thing that mattered gets a doc-comment note explaining why it went.
- Every gate before a commit: `swift test --package-path ShirKit` and `./scripts/typecheck-ios.sh`.

## File Structure

| File | Responsibility |
|---|---|
| **Create** `ShirKit/Sources/ShirKit/Playback/NowPlayingDragPolicy.swift` | Pure value type. Given a translation, says where the player sits; given a release, says dismiss or restore. No UI framework, no knowledge of SwiftUI gestures. |
| **Create** `ShirKit/Tests/ShirKitTests/NowPlayingDragPolicyTests.swift` | Ten tests, one per rule. |
| **Create** `Tests/ShirUITests/NowPlayingDismissGestureTests.swift` | Two offline UI tests: a downward drag minimises, a sideways drag does not. |
| **Modify** `Shir/Features/Player/NowPlayingView.swift` | Takes an `onDismiss` closure instead of `@Environment(\.dismiss)`. Owns the drag state, applies the offset, and holds the one exit animation both the chevron and the drag call. |
| **Modify** `Shir/Features/Root/RootTabView.swift` | Presents Now Playing as a `ZStack` layer instead of a `fullScreenCover`; hides the content behind it from accessibility while it is up. |

Task 1 delivers the policy and its tests with nothing depending on it. Task 2 rewires the presentation and can be judged on its own — it is the risky one, and the step that verifies `NowPlayingStageTests` still passes belongs to it. Task 3 adds the gesture on top of both. Task 4 is documentation.

---

### Task 1: The drag policy in ShirKit

**Files:**
- Create: `ShirKit/Sources/ShirKit/Playback/NowPlayingDragPolicy.swift`
- Test: `ShirKit/Tests/ShirKitTests/NowPlayingDragPolicyTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `public struct NowPlayingDragPolicy: Equatable, Sendable` with
  `public init()`,
  `public private(set) var offset: CGFloat`,
  `public private(set) var isRejected: Bool`,
  `public enum Resolution: Equatable, Sendable { case dismiss, restore }`,
  `public mutating func update(translation: CGSize, isScrubbing: Bool)`,
  `public func resolve(predictedEnd: CGSize, screenHeight: CGFloat) -> Resolution`,
  `public mutating func settle(at offset: CGFloat)`,
  `public mutating func reset()`,
  and the static constants `directionLockDistance`, `upwardResistance`, `maximumUpwardOffset`, `dismissFraction`, `flickFraction`, all `CGFloat`.

- [ ] **Step 1: Write the failing tests**

Create `ShirKit/Tests/ShirKitTests/NowPlayingDragPolicyTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path ShirKit`
Expected: FAIL to compile — `cannot find 'NowPlayingDragPolicy' in scope`.

- [ ] **Step 3: Write the implementation**

Create `ShirKit/Sources/ShirKit/Playback/NowPlayingDragPolicy.swift`:

```swift
import CoreGraphics

/// Where the Now Playing screen sits while a finger is dragging it, and what a
/// release means.
///
/// The consumer is `NowPlayingView`. The gesture covers the whole screen, which
/// is what makes it easy to reach and also what makes it dangerous: the
/// scrubber lives in the middle of that area, and a seek that turned into a
/// dismiss would be worse than having no gesture at all. Two independent rules
/// stop that, because SwiftUI's gesture arbitration is not something to bet the
/// behaviour on:
///
/// | Rule | Stops |
/// |---|---|
/// | Stand down entirely while the slider has the touch | a seek being read as a pull |
/// | Lock direction once, on the first real movement | a horizontal drag anywhere else becoming a dismiss |
///
/// The lock is decided once per drag and never revisited. A drag that began
/// sideways stays rejected even if it ends up travelling the length of the
/// screen — otherwise a seek that drifted downward at the end would dismiss.
public struct NowPlayingDragPolicy: Equatable, Sendable {
    public enum Resolution: Equatable, Sendable {
        case dismiss
        case restore
    }

    /// How far a finger must travel before the drag commits to a direction.
    /// Matches the gesture's own `minimumDistance`, so the first translation
    /// this type ever sees is already a deliberate movement.
    public static let directionLockDistance: CGFloat = 10

    /// Upward drags move at a fifth of the finger. The screen is already at the
    /// top; the resistance says so without forbidding the movement.
    public static let upwardResistance: CGFloat = 5

    /// However hard it is pulled, the player never lifts more than this.
    public static let maximumUpwardOffset: CGFloat = 60

    /// Release past this much of the screen and it closes.
    public static let dismissFraction: CGFloat = 0.25

    /// Or release with enough speed that it would have travelled this far.
    public static let flickFraction: CGFloat = 0.5

    /// How far the player should be moved down from its resting place.
    public private(set) var offset: CGFloat = 0

    /// True once this drag has been ruled out as a dismissal. Never clears
    /// until `reset()`.
    public private(set) var isRejected = false

    private var hasLockedDirection = false

    public init() {}

    /// - Parameter isScrubbing: whether the scrubber currently owns the touch.
    ///   The slider's `onEditingChanged(true)` fires on touch-down, before the
    ///   gesture's minimum distance is met, so this is already true by the time
    ///   a seek produces its first translation.
    public mutating func update(translation: CGSize, isScrubbing: Bool) {
        if isScrubbing { isRejected = true }
        guard !isRejected else {
            offset = 0
            return
        }

        if !hasLockedDirection {
            let distance = (translation.width * translation.width
                + translation.height * translation.height).squareRoot()
            guard distance >= Self.directionLockDistance else {
                offset = 0
                return
            }
            hasLockedDirection = true
            if abs(translation.width) > abs(translation.height) {
                isRejected = true
                offset = 0
                return
            }
        }

        offset = Self.resisted(translation.height)
    }

    /// - Parameter predictedEnd: SwiftUI's `predictedEndTranslation` — where the
    ///   drag would have finished at its release speed. It is how a short, fast
    ///   flick reads as the dismissal it plainly is.
    public func resolve(predictedEnd: CGSize, screenHeight: CGFloat) -> Resolution {
        guard !isRejected else { return .restore }
        if offset > screenHeight * Self.dismissFraction { return .dismiss }
        if predictedEnd.height > screenHeight * Self.flickFraction { return .dismiss }
        return .restore
    }

    /// Drives the offset to a resting place the drag did not reach — the target
    /// of the exit animation, which the chevron uses too so that tapping and
    /// pulling produce the same motion.
    public mutating func settle(at offset: CGFloat) {
        self.offset = offset
    }

    public mutating func reset() {
        offset = 0
        isRejected = false
        hasLockedDirection = false
    }

    private static func resisted(_ height: CGFloat) -> CGFloat {
        guard height < 0 else { return height }
        return -min(-height / upwardResistance, maximumUpwardOffset)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path ShirKit`
Expected: PASS — 133 tests (120 existing plus 13 new).

- [ ] **Step 5: Commit**

```bash
git add ShirKit/Sources/ShirKit/Playback/NowPlayingDragPolicy.swift \
        ShirKit/Tests/ShirKitTests/NowPlayingDragPolicyTests.swift
git commit -m "The pull-down's judgement, before any of it can be dragged

A gesture covering the whole of Now Playing has to cross the scrubber,
and a seek misread as a dismiss would be worse than no gesture. Two
independent rules stop it: stand down while the slider owns the touch,
and lock direction once on the first real movement, never revisiting it.

Both live here rather than in the view, so they are settled by thirteen
tests in a tenth of a second instead of by SwiftUI's gesture arbitration."
```

---

### Task 2: Now Playing becomes a layer, not a cover

**Files:**
- Modify: `Shir/Features/Player/NowPlayingView.swift:16` (drop `@Environment(\.dismiss)`), `:13-21` (add the `onDismiss` property), `:61` (call it)
- Modify: `Shir/Features/Root/RootTabView.swift:43-56` (accessibility), `:61-66` (accessibility), `:72-77` (replace the cover), `:96-98` (test seam)

**Interfaces:**
- Consumes: nothing from Task 1 yet.
- Produces: `NowPlayingView.init(onDismiss: @escaping () -> Void)`. Task 3 adds the drag inside this same view.

**Why this task exists at all.** `fullScreenCover` presents with UIKit's `.fullScreen` modal style, which removes the presenting view controller's view from the window once the transition settles — that is exactly why `.overFullScreen` exists as a separate style. Pull such a cover down and what you expose is empty black, not the library. Step 1 confirms that before the rest of the task depends on it.

- [ ] **Step 1: Confirm the premise before rewriting anything**

Prove that a `fullScreenCover` really does blank what is behind it, rather than taking it on trust. Temporarily add `.offset(y: 200)` to the `ZStack` inside `NowPlayingView.body` (line 26), build to the simulator, open Now Playing, and look at the 200pt strip at the top.

```bash
xcodebuild -project Shir.xcodeproj -scheme Shir \
  -destination 'platform=iOS Simulator,name=iPhone 16' build
```

Expected: the strip is **black**, not the library screen. If it shows the library, stop — `fullScreenCover` would be keepable and this whole task is unnecessary; report that before continuing.

Remove the temporary `.offset` before moving on.

- [ ] **Step 2: Give `NowPlayingView` an explicit dismiss closure**

In `Shir/Features/Player/NowPlayingView.swift`, delete the `@Environment(\.dismiss)` line and add a stored closure. The declaration becomes:

```swift
struct NowPlayingView: View {
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(LibraryStore.self) private var library

    /// Closes the screen. An explicit closure rather than
    /// `@Environment(\.dismiss)` because this is no longer a presentation —
    /// it is a layer in `RootTabView`'s stack, and `dismiss` has nothing to
    /// act on. See the file comment on why it stopped being a cover.
    let onDismiss: () -> Void

    @State private var isShowingQueue = false
    @State private var scrubPosition: TimeInterval = 0
```

Change the chevron's action on what is currently line 61 from `Button { dismiss() } label: {` to:

```swift
                Button { onDismiss() } label: {
```

- [ ] **Step 3: Record why it is not a cover, in the type's own doc comment**

Extend the doc comment above `struct NowPlayingView` (currently lines 4-12) with a fourth paragraph:

```swift
/// This is a layer in `RootTabView`'s `ZStack`, not a `fullScreenCover`. A
/// `.fullScreen` presentation removes the presenting view from the window once
/// it settles, so a pull-down would expose black rather than the library behind
/// — measured, not assumed. Being a sibling of the offstage web-view host also
/// retires an entire UIKit presentation lifecycle, which §9 records being burned
/// by twice.
```

- [ ] **Step 4: Present it from the stack in `RootTabView`**

In `Shir/Features/Root/RootTabView.swift`, delete the `.fullScreenCover(isPresented:)` modifier (lines 75-77) entirely and add the layer inside the `ZStack`, immediately after the `if playback.hasActiveTrack { MiniPlayerBar … }` block:

```swift
            if isShowingNowPlaying {
                NowPlayingView(onDismiss: { isShowingNowPlaying = false })
                    // Removal is `.identity` because the exit animation has
                    // already carried the layer off the bottom by the time it
                    // goes away — a removal transition would slide it twice.
                    .transition(.asymmetric(insertion: .move(edge: .bottom),
                                            removal: .identity))
                    .zIndex(1)
            }
```

The layer must not take `.ignoresSafeArea()`: it is `NowPlayingView`'s own
`Theme.background.ignoresSafeArea()` that paints under the status bar and over
the tab bar, while the layout stays inside the safe area exactly as it did
inside the cover. Adding it here would slide the header under the clock.

- [ ] **Step 5: Hide what is behind from accessibility**

A sibling layer leaves the library and tab bar in the accessibility tree, where an `XCUIApplication` query can match a row underneath the player. Restore the isolation the modal gave for free.

Add to the `GeometryReader` holding `OffstageYouTubePlayerHost` (after its closing brace on line 41) and to the `TabView`'s modifier chain (after `.background(Theme.background.ignoresSafeArea())` on line 59), and to `MiniPlayerBar`'s chain (after `.transition(…)` on line 65), the same modifier:

```swift
                    .accessibilityHidden(isShowingNowPlaying)
```

- [ ] **Step 6: Animate the opening**

The `ZStack`'s existing `.animation(…, value: playback.hasActiveTrack)` is keyed to a different value and will not drive the new transition, so the two places that open the screen have to supply the animation themselves.

Change the `MiniPlayerBar` call on line 62 to:

```swift
                MiniPlayerBar { withAnimation(.snappy(duration: 0.3)) { isShowingNowPlaying = true } }
```

and the `onChange` block on lines 72-74 to:

```swift
        .onChange(of: playback.userPlaybackToken) {
            withAnimation(.snappy(duration: 0.3)) { isShowingNowPlaying = true }
        }
```

Leave the `-autoOpenNowPlaying` seam in `onAppear` (line 97) as a plain assignment — a test seam wants the screen there, not an animation to wait on.

- [ ] **Step 7: Compile**

Run: `./scripts/typecheck-ios.sh`
Expected: PASS, no errors.

- [ ] **Step 8: Verify the geometry did not move**

This is the regression the presentation change could plausibly cause, so run the suite that measures it. Get a UDID first — several simulators share names:

```bash
xcrun simctl list devices available | grep -m1 "iPhone 16"
xcodebuild -project Shir.xcodeproj -scheme Shir \
  -destination 'platform=iOS Simulator,id=<UDID>' \
  -only-testing:ShirUITests/NowPlayingStageTests test
```

Expected: PASS — the stage still spans the full screen width at 16:9.

- [ ] **Step 9: Verify the flows that open and close the screen still work**

```bash
xcodebuild -project Shir.xcodeproj -scheme Shir \
  -destination 'platform=iOS Simulator,id=<UDID>' \
  -only-testing:ShirUITests/AddToPlaylistFlowTests test
```

Expected: PASS — both tests open Now Playing by tapping a song and close it with the chevron, which is the whole presentation path.

- [ ] **Step 10: Commit**

```bash
git add Shir/Features/Player/NowPlayingView.swift Shir/Features/Root/RootTabView.swift
git commit -m "Now Playing stops being a cover, so there is something behind it

A .fullScreen presentation removes the presenting view from the window
once it settles — which is why .overFullScreen exists as a separate
style. Pull that down and you expose black, not the library. Measured
before rewriting anything: a temporary 200pt offset on the cover showed
a black strip.

So it becomes a layer in the stack RootTabView already has. The gesture
that needs this lands next; what arrives now is the same screen, opened
and closed the same ways, with the library genuinely behind it.

Two consequences. dismiss() has nothing to act on, so the chevron calls
an explicit closure. And a sibling layer leaves the library in the
accessibility tree, where a UI-test query could match a row underneath
the player, so the content behind is hidden while it is up."
```

---

### Task 3: The gesture

**Files:**
- Modify: `Shir/Features/Player/NowPlayingView.swift`
- Test: `Tests/ShirUITests/NowPlayingDismissGestureTests.swift` (create)

**Interfaces:**
- Consumes: `NowPlayingDragPolicy` from Task 1 — `update(translation:isScrubbing:)`, `resolve(predictedEnd:screenHeight:)`, `settle(at:)`, `reset()`, `offset`, and the static `directionLockDistance`. `NowPlayingView.init(onDismiss:)` from Task 2. `PlaybackCoordinator.isScrubbing` (already exists, `Shir/Playback/PlaybackCoordinator.swift:40`).
- Produces: the finished feature. Nothing depends on it.

- [ ] **Step 1: Write the failing UI tests**

Create `Tests/ShirUITests/NowPlayingDismissGestureTests.swift`:

```swift
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

        let start = stage.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 500)))

        XCTAssertTrue(app.buttons["miniPlayerToggle"].waitForExistence(timeout: 5),
                      "pulling down should leave the mini player, exactly as the chevron does")
        XCTAssertFalse(app.buttons["dismissNowPlaying"].exists,
                       "Now Playing should be closed")
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
```

- [ ] **Step 2: Regenerate the project so the new file joins the target, then run the tests to verify they fail**

```bash
xcodegen generate
xcrun simctl list devices available | grep -m1 "iPhone 16"
xcodebuild -project Shir.xcodeproj -scheme Shir \
  -destination 'platform=iOS Simulator,id=<UDID>' \
  -only-testing:ShirUITests/NowPlayingDismissGestureTests test
```

Expected: `testPullingDownMinimisesToTheMiniPlayer` FAILS — Now Playing stays open, so `miniPlayerToggle` never appears. `testDraggingSidewaysDoesNotMinimise` passes already; that is correct, it is a guard against a regression the next step could introduce.

- [ ] **Step 3: Add the drag state and the shared exit to `NowPlayingView`**

Add the import and the state alongside the existing `@State` properties:

```swift
import ShirKit
import SwiftUI
```

`ShirKit` is already imported at line 1 — no change needed there. Add after `@State private var scrubPosition: TimeInterval = 0`:

```swift
    @State private var drag = NowPlayingDragPolicy()
```

Add these two members below the `header` property:

```swift
    // MARK: - Pull down to dismiss

    /// The one way out, shared by the chevron and the pull so that tapping and
    /// dragging produce the same motion rather than two different dismissals.
    private func animateOut(screenHeight: CGFloat) {
        withAnimation(.snappy(duration: 0.25), completionCriteria: .logicallyComplete) {
            drag.settle(at: screenHeight)
        } completion: {
            onDismiss()
            drag.reset()
        }
    }

    /// Attached with `simultaneousGesture` rather than `gesture`: a plain
    /// `.gesture` on a container enters arbitration against every Button and
    /// Slider inside it and loses unpredictably. Running alongside them keeps
    /// the transport buttons and the heart behaving normally — a tap still
    /// fires, a drag that leaves the button does not — and leaves
    /// `NowPlayingDragPolicy`, rather than SwiftUI, deciding when not to move.
    ///
    /// The stage needs nothing special: the web view has
    /// `isUserInteractionEnabled = false`, so touches over the video already
    /// fall through to here.
    private func dismissDrag(screenHeight: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: NowPlayingDragPolicy.directionLockDistance)
            .onChanged { value in
                drag.update(translation: value.translation, isScrubbing: playback.isScrubbing)
            }
            .onEnded { value in
                switch drag.resolve(predictedEnd: value.predictedEndTranslation,
                                    screenHeight: screenHeight) {
                case .dismiss:
                    animateOut(screenHeight: screenHeight)
                case .restore:
                    withAnimation(.snappy(duration: 0.3)) { drag.reset() }
                }
            }
    }
```

- [ ] **Step 4: Apply the offset and the gesture**

Replace the `body` (currently lines 21-45) with:

```swift
    var body: some View {
        // The stage needs a width it does not have to negotiate for, and a
        // VStack cannot give it one — see `stage(width:)`. Reading the width
        // once here is what makes the size definite. The height is read for a
        // second reason: it is what a pull-down is measured against.
        GeometryReader { proxy in
            ZStack {
                Theme.background.ignoresSafeArea()

                VStack(spacing: 0) {
                    header(screenHeight: proxy.size.height)
                    stage(width: proxy.size.width)
                    scrubber
                    trackInfo
                    Spacer(minLength: 8)
                    transportControls
                    Spacer(minLength: 8)
                    secondaryControls
                }
            }
            // Deliberately no scale and no corner rounding while dragging:
            // scaling would resize the web view's frame on every frame and make
            // WebKit re-lay-out the page sixty times a second for decoration.
            .offset(y: drag.offset)
            .simultaneousGesture(dismissDrag(screenHeight: proxy.size.height))
        }
        .sheet(isPresented: $isShowingQueue) {
            QueueView()
                .presentationDetents([.medium, .large])
        }
    }
```

- [ ] **Step 5: Route the chevron through the same exit**

Change `private var header: some View {` to a function, and its button action, so the chevron animates out exactly as a completed pull does:

```swift
    private func header(screenHeight: CGFloat) -> some View {
```

and within it change `Button { onDismiss() } label: {` to:

```swift
                Button { animateOut(screenHeight: screenHeight) } label: {
```

- [ ] **Step 6: Compile**

Run: `./scripts/typecheck-ios.sh`
Expected: PASS, no errors.

- [ ] **Step 7: Run the new tests to verify they pass**

```bash
xcodebuild -project Shir.xcodeproj -scheme Shir \
  -destination 'platform=iOS Simulator,id=<UDID>' \
  -only-testing:ShirUITests/NowPlayingDismissGestureTests test
```

Expected: PASS, both tests.

- [ ] **Step 8: Run the whole UI suite**

The chevron's behaviour changed — it now animates out over 0.25s instead of dismissing a cover — and seven tests tap it.

```bash
xcodebuild -project Shir.xcodeproj -scheme Shir \
  -destination 'platform=iOS Simulator,id=<UDID>' test
```

Expected: PASS — 21 UI tests (19 existing plus 2 new). `BackgroundPlaybackTests` and `SearchAutoplayTests` need the network; if the machine is offline, note which tests were skipped rather than reporting a clean run.

- [ ] **Step 9: Run the unit suite**

Run: `swift test --package-path ShirKit`
Expected: PASS — 133 tests.

- [ ] **Step 10: Commit**

```bash
git add Shir/Features/Player/NowPlayingView.swift Tests/ShirUITests/NowPlayingDismissGestureTests.swift
git commit -m "Pull Now Playing down to minimise it

The chevron was the only way out. Now a downward drag anywhere on the
screen does the same job, and does it through the same function — so
tapping and pulling are one motion rather than two dismissals that
happen to agree.

simultaneousGesture, not gesture: a plain .gesture on a container enters
arbitration against every Button and Slider inside it and loses
unpredictably. Alongside them, the buttons keep working and the policy,
not SwiftUI, decides when not to move.

No scale and no corner rounding while dragging. The reference has
neither, and scaling would resize the web view's frame on every frame,
making WebKit re-lay-out the page sixty times a second for decoration."
```

---

### Task 4: Documentation

**Files:**
- Modify: `CLAUDE.md` (§2 quick reference test counts, §3 file map, §8 testing counts, §9 pitfalls index)

**Interfaces:**
- Consumes: everything. Nothing depends on it.

- [ ] **Step 1: Update the counts**

Three places carry test counts, and all three are now wrong. Replace `120 unit tests` with `133 unit tests` and `19 UI tests` with `21 UI tests` in:

- §2 Quick reference, the `swift test` comment line and the `xcodebuild` comment line
- §3 The layering rule paragraph ("120 tests in about a tenth of a second")
- §8 Testing, the opening line

- [ ] **Step 2: Add the two new files to the §3 file map**

In the **ShirKit — state** block, after the `Playback/AutoResumePolicy.swift` row:

```markdown
| `Playback/NowPlayingDragPolicy.swift` | Pure value type. Where the player sits under a finger, and whether a release dismisses. Stands down while the scrubber has the touch (§9) |
```

In the **App — screens** block, amend the `NowPlayingView.swift` row:

```markdown
| `Features/Player/NowPlayingView.swift` | Full-screen player. Mounts the engine's web view. A layer in `RootTabView`'s stack, not a cover (§9) |
```

- [ ] **Step 3: Add the pitfall**

Add a row to the §9 pitfalls index, after the "An audible dip every time Now Playing is dismissed" row:

```markdown
| Dragging Now Playing down exposes black instead of the library behind it | It was a `fullScreenCover`. A `.fullScreen` presentation removes the presenting view controller's view from the window once the transition settles — which is exactly why `.overFullScreen` exists as a separate style. Nothing about this is visible until something tries to see past the cover | Present it as a layer in `RootTabView`'s `ZStack` instead. `@Environment(\.dismiss)` stops working there — the chevron takes an explicit closure — and the library stays in the accessibility tree, so the content behind is `.accessibilityHidden` while the player is up |
```

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "Document the pull-down, and the cover that had to go to allow it"
```

---

## Self-Review

**Spec coverage.** Every section of `docs/superpowers/specs/2026-08-07-pull-down-to-dismiss-design.md` maps to a task: the presentation change to Task 2, the policy and its four rules to Task 1, the wiring and `simultaneousGesture` reasoning to Task 3, the one-exit-path to Task 3 step 5, accessibility to Task 2 step 5, the unit test table to Task 1 step 1, the UI test to Task 3 step 1, the `NowPlayingStageTests` regression watch to Task 2 step 8. The spec's "Not doing" list needs no task by construction.

**Type consistency.** `NowPlayingDragPolicy` is named identically in all four tasks. `settle(at:)` is defined in Task 1 and consumed in Task 3 step 3. `resolve(predictedEnd:screenHeight:)` keeps both labels in both places. `onDismiss` is introduced in Task 2 step 2 and consumed in Task 2 step 2 and Task 3 step 5. `directionLockDistance` is declared in Task 1 and read in Task 3 step 3.

**One deviation from the spec, deliberate.** The spec's policy sketch listed four members; the implementation has five — `settle(at:)` was added so the exit animation has something to animate, since `offset` is `private(set)`. It is covered by `testSettleDrivesTheOffsetToTheExitPosition`.
