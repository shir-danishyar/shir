# CLAUDE.md — Shir

An iPhone music app: playlists, a queue, and two playback sources.

## What this is

SwiftUI iOS app, iOS 17+, split into two pieces:

| Piece | What it holds | Why it's separate |
|---|---|---|
| `ShirKit/` | SwiftPM package. Models, library store, playback queue, YouTube Data API client. No UI framework imports. | Runs and tests on macOS, so the logic with real edge cases (queue transitions, shuffle, persistence) is covered by fast unit tests instead of a simulator. |
| `Shir/` | The iOS app. SwiftUI views, the two playback engines, keychain, file import. | Everything that genuinely needs UIKit/AVFoundation/WebKit. |

The Xcode project is **generated** by XcodeGen from `project.yml`. `Shir.xcodeproj` is
gitignored — edit `project.yml`, never the project file.

## The constraint that shapes the whole design

The app plays YouTube **through the official IFrame Player API**, in a visible
`WKWebView`. It does not extract streams, hide the player, or strip ads.

That is not squeamishness, it's the product boundary:

- App Store Review Guideline 5.2.1 rejects it, and the App Store is the chokepoint that
  actually matters. Apple removed Musi in September 2024 after complaints from IFPI, Sony,
  the NMPA and YouTube. Musi sued *Apple* — Google never sued Musi — and lost with
  prejudice in March 2026 when Judge Eumi Lee ruled Apple's Developer Program License
  Agreement lets it pull any app "at any time, with or without cause." Musi's law firm was
  sanctioned. That route is now demonstrably closed.
- Musi's own position was that it did not use the YouTube API at all, so it was not bound
  by the API terms. The NMPA disputed that, and separately alleged Musi circumvented
  YouTube's "rolling cipher" — which is a DMCA §1201 anti-circumvention claim, statutory
  law rather than a contract term. Avoiding the API does not reduce exposure here; it
  raises it.

Three rules follow, and they are enforced in code rather than left to a reviewer:

1. **The player stays visible.** `NowPlayingView` mounts the web view at 16:9 whenever a
   YouTube track is loaded. Never give it zero size or put artwork over it.
2. **YouTube pauses in the background.** `PlaybackCoordinator.applicationDidEnterBackground()`
   pauses YouTube tracks. Local files keep playing — that is what the `audio` background
   mode in `project.yml` is for. Do not "fix" this to make YouTube play with the screen off.
3. **Search only surfaces embeddable music.** `YouTubeSearchClient` sends
   `videoEmbeddable=true` and `videoCategoryId=10`. There is a test asserting both.

Uninterrupted listening comes from the other source: imported files, which the app owns
end to end and plays with no ads, background audio, and lock screen controls.

## Running it

```bash
brew install xcodegen          # once
xcodegen generate              # regenerate Shir.xcodeproj after touching project.yml
open Shir.xcodeproj
```

Search needs a YouTube Data API key, entered in the app's Settings tab (stored in the
keychain). Create one at console.cloud.google.com → enable "YouTube Data API v3" →
Credentials → API key. Free tier is 10,000 quota units/day; one search costs 100, which
is why `SearchViewModel` debounces at 450ms.

## Testing

```bash
swift test --package-path ShirKit    # 51 unit tests, run on macOS in ~20ms
xcodebuild -project Shir.xcodeproj -scheme Shir \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test    # 11 UI tests, ~2.5 min
./scripts/screenshots.sh             # writes screenshots/ from a simulator run
./scripts/typecheck-ios.sh           # fast compile-only gate, no simulator needed
```

Anything with real logic belongs in `ShirKit` with a unit test — it runs three orders of
magnitude faster than a UI test and does not need a simulator. The UI tests exist only to
cover what unit tests structurally cannot see: navigation, persistence reaching the
screen, and each screen's empty/error state.

`typecheck-ios.sh` predates the simulator being usable here and is kept because it is
seconds rather than minutes. It builds ShirKit for `arm64-apple-ios17.0-simulator` and
typechecks every app source against it — everything short of link and runtime errors.

**UI test isolation:** the app checks for a `-uitesting` launch argument
(`AppEnvironment.isUITesting`) and, when present, points the library at a fresh temp file
and clears the keychain. Without it, tests would inherit whatever the last run saved.
`testEachLaunchStartsFromACleanLibrary` guards that hook.

**Typing into SwiftUI fields is racy.** SwiftUI focuses a field asynchronously after a
tap, and `typeText` into a not-yet-focused field is silently dropped — this made both API
key tests flaky. `enterAndSaveAPIKey` gates on the Save button becoming enabled, which
only happens once the text reached the binding, and retries once. Don't replace that with
a sleep, and don't add a bare `tap()` + `typeText()` anywhere else without the same gate.

## Layout

```
ShirKit/Sources/ShirKit/
  Models/       Track, Playlist, Library, MediaSource
  Library/      LibraryStore (@Observable) + JSON persistence behind a protocol
  Playback/     PlaybackQueue — cursor, shuffle, repeat, reordering. Pure value type.
  YouTube/      YouTubeSearchClient over an injectable HTTPFetching
  Support/      ISO8601 duration parsing, collection move, HTTP stub for tests

Shir/
  App/          ShirApp entry point, AppEnvironment composition root
  Playback/     PlaybackEngine protocol, YouTubePlayerEngine (WKWebView + JS bridge),
                LocalAudioEngine (AVPlayer), PlaybackCoordinator (routes queue → engine)
  Services/     APIKeyStore (keychain), LocalMediaImporter (file copy + metadata)
  Features/     One folder per screen, plus shared Components
```

## Conventions

- Persistence is a whole-library JSON re-encode per mutation, behind `LibraryPersisting`.
  Fine at this size; if the library grows past a few thousand tracks, revisit before
  optimising anything else.
- `PlaybackQueue` is a value type with no engine knowledge. Keep it that way — it is the
  part most likely to grow subtle bugs, and it is only cheap to test because it is pure.
- Don't add `move(fromOffsets:toOffset:)` to a collection in ShirKit; SwiftUI defines its
  own and the two become ambiguous. The package's version is `moveElements`.
- Two engines, one coordinator. `PlaybackCoordinator.isActive(_:)` drops events from the
  engine that isn't in charge, so a stopping engine's final `.idle` can't clobber the
  track just started on the other one.
