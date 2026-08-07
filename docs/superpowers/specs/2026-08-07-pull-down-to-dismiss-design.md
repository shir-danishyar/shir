# Pull down to dismiss Now Playing

**Date:** 2026-08-07
**Status:** Design approved, ready to plan

## The ask

Now Playing can only be closed by tapping the chevron in its top-left corner.
The reference app closes it by pulling the screen down with a finger. Add that
gesture.

The gesture does **exactly** what the chevron already does — it minimises to the
existing mini player. There is no new end state, no new layout, and no change to
what the closed or open screens look like. The chevron stays.

## What the reference app actually does

Two frames captured mid-drag settle what to build, and rule out three things
that would otherwise have been guesses:

- The player **translates rigidly**. Measured across the two frames, the header,
  the video and the title row all moved by the same ~395px. Nothing reflows,
  nothing compresses.
- There is **no scale, no corner rounding, and no dimming** of what is behind.
- What is revealed behind is the **real library screen** — its navigation bar,
  its rows, the tab bar. Not a snapshot, not a dimming layer.

That last point is the one with a consequence.

## Architecture

### The presentation has to stop being a `fullScreenCover`

`fullScreenCover` presents with UIKit's `.fullScreen` modal style, which removes
the presenting view controller's view from the window once the transition
settles. That is precisely why `.overFullScreen` exists as a separate style.
Drag such a cover down and what you expose is empty black, not the library.

So `NowPlayingView` moves out of `.fullScreenCover` and becomes a conditional
layer in the `ZStack` that `RootTabView` already has, above `MiniPlayerBar`.

Two consequences.

**This is friendlier to the web view, not riskier.** The adopt/park handover in
`WebViewAdoptingView` is unchanged: the stage still adopts on `didMoveToWindow`,
`dismantleUIView` still calls `parkWebView()`, every handover is still
window→window. What goes away is an entire UIKit presentation lifecycle, which
is the thing §9 records being burned by twice. The offstage host and the stage
become siblings in one hierarchy instead of parties to a presentation.

**`@Environment(\.dismiss)` stops working inside `NowPlayingView`.** It takes an
explicit closure from `RootTabView` instead.

### The decision-making is a pure value type

Per the layering rule, the logic goes in ShirKit with unit tests rather than
inside a SwiftUI view. New file, `ShirKit/Sources/ShirKit/Playback/NowPlayingDragPolicy.swift`:

```swift
public struct NowPlayingDragPolicy: Equatable, Sendable {
    public enum Resolution { case dismiss, restore }
    public private(set) var offset: CGFloat
    public mutating func update(translation: CGSize, isScrubbing: Bool)
    public func resolve(predictedEnd: CGSize, screenHeight: CGFloat) -> Resolution
    public mutating func reset()
}
```

It imports Foundation only. `CGFloat` and `CGSize` come from CoreGraphics, which
is not a UI framework — the same reasoning that puts the injected JavaScript in
ShirKit.

Four rules:

1. **Downward tracks the finger 1:1.** `offset = translation.height`.
2. **Upward rubber-bands.** One fifth of the distance, capped at 60pt, so the
   player cannot be torn off the top of the screen.
3. **Direction lock, decided once per drag.** On the first movement past 10pt,
   a drag more horizontal than vertical is rejected for its entire lifetime. It
   cannot become a dismiss halfway through.
4. **Scrubbing wins outright.** If `isScrubbing` is true the drag is rejected.

Rules 3 and 4 are belt and braces for the same hazard — the scrubber. The
slider's `onEditingChanged(true)` fires on touch-down, before the gesture's 10pt
minimum, so rule 4 alone should always catch a seek. Rule 3 covers the general
case of a horizontal drag anywhere else on the screen.

Release resolves to `dismiss` when the pull passed a quarter of the screen
height, or when `predictedEndTranslation` says the flick would have carried it
past half. Otherwise `restore`, and the offset springs back to zero.

### Wiring

The gesture is a `.simultaneousGesture` on the root of `NowPlayingView`, not a
`.gesture`. A plain `.gesture` on a container enters arbitration against every
Button and Slider inside it and loses unpredictably. Simultaneous means the
transport buttons and the heart keep behaving normally — a tap still fires, a
drag that leaves the button does not — and the policy, not SwiftUI's
arbitration, is what declines to move.

The stage needs nothing special: the web view has `isUserInteractionEnabled =
false`, so touches over the video already fall through to SwiftUI.

**No scale, no corner rounding** — matching the reference, and correct
independently: scaling would resize the web view's frame on every frame of the
drag, making WebKit re-lay-out the page 60 times a second for decoration.

### One exit path

Because the pull must do the chevron's job, both go through one function:

```swift
private func animateOut() {
    withAnimation(.snappy(duration: 0.25), completionCriteria: .logicallyComplete) {
        drag.offset = screenHeight
    } completion: {
        onDismiss()
        drag.reset()
    }
}
```

The chevron therefore gains the same slide-down the drag has, in place of the
cover's stock dismissal. They become the same motion, which is the point.

The layer's transition is `.move(edge: .bottom)` on insert and `.identity` on
removal — by removal time the offset animation has already carried it off
screen, and a removal transition would slide it a second time.

### Accessibility of what is behind

As a sibling layer rather than a modal presentation, the library and tab bar
stay in the accessibility tree while the player is up, so an `XCUIApplication`
query could match a row underneath it. The content behind therefore takes
`.accessibilityHidden(true)` while the player is presented. This restores the
isolation the modal presentation gave for free.

## Testing

**ShirKit unit tests** — `NowPlayingDragPolicyTests`, one per rule:

| Test | Asserts |
|---|---|
| Downward tracks 1:1 | 120pt down → offset 120 |
| Upward rubber-bands | 100pt up → offset about -20, never past the -60 cap |
| Horizontal drag is rejected | offset stays 0 |
| A rejected drag stays rejected | later vertical movement still gives offset 0 |
| A rejected drag never dismisses | `resolve` returns `.restore` regardless of distance |
| Scrubbing rejects the drag | `isScrubbing: true` → offset 0 |
| Past a quarter screen dismisses | `.dismiss` |
| Short of a quarter screen restores | `.restore` |
| A hard flick dismisses early | small translation, large `predictedEnd` → `.dismiss` |
| `reset` clears offset and rejection | a fresh drag tracks again |

**UI test** — one, offline, in `Tests/ShirUITests/`: launch with
`-autoOpenNowPlaying YES -seedLibrary`, swipe down on `playerStage`, assert the
mini player is back and `dismissNowPlaying` is gone.

**Regression to watch:** `NowPlayingStageTests` measures the stage's on-device
geometry, and the presentation change is exactly the kind of thing that moves
it. Run it explicitly and confirm the stage width is unchanged.

The seven existing tests that tap `dismissNowPlaying` are unaffected — the
identifier and the button both stay.

## Not doing

- **No change to the resting layout of either screen.** The open player and the
  mini player look exactly as they do today.
- **No tab bar under the open player.** The reference shows one during the drag
  because the drag reveals it; it is not part of the resting design here.
- **No swipe-up from the mini player to open.** Not asked for. Tapping the mini
  player already opens Now Playing.
