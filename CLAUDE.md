# CLAUDE.md — Riff

A Musi-style iPhone music app: playlists, a queue, and two playback sources.

**Read §2 before changing anything about YouTube playback.** This project reversed a major
design decision on 2026-08-04, and the code has not caught up with the decision yet.

## 1. What this is

SwiftUI iOS app, iOS 17+, split into two pieces:

| Piece | What it holds | Why it's separate |
|---|---|---|
| `RiffKit/` | SwiftPM package. Models, library store, playback queue, YouTube Data API client. No UI framework imports. | Runs and tests on macOS, so the logic with real edge cases (queue transitions, shuffle, persistence) is covered by fast unit tests instead of a simulator. |
| `Riff/` | The iOS app. SwiftUI views, the two playback engines, keychain, file import. | Everything that genuinely needs UIKit/AVFoundation/WebKit. |

The Xcode project is **generated** by XcodeGen from `project.yml`. `Riff.xcodeproj` is
gitignored — edit `project.yml`, never the project file.

## 2. The fork: this is a personal-device build

Riff targets **one physical iPhone, sideloaded**. It is not going to the App Store.

That is a deliberate, reversible choice made on 2026-08-04, and it inverts the constraint
this project was originally built around. Both positions are recorded here because a
future session needs to understand the trade, not just inherit the result.

### What the constraint used to be, and why

Until 2026-08-04 the app played YouTube through the **official IFrame Player**, visibly,
with ads intact, pausing in the background. The reasoning was sound and still holds *for a
shipping product*:

- App Store Review Guideline 5.2.1 rejects ad-stripping YouTube clients, and the App Store
  is the chokepoint that actually matters. Apple removed Musi in September 2024 after
  complaints from IFPI, Sony, the NMPA and YouTube. Musi sued *Apple* — Google never sued
  Musi — and lost with prejudice in March 2026 when Judge Eumi Lee ruled Apple's Developer
  Program License Agreement lets it pull any app "at any time, with or without cause."
  Musi's law firm was sanctioned.
- Musi's own position was that it used no YouTube API and so was not bound by the API
  terms. The NMPA disputed that and separately alleged circumvention of YouTube's "rolling
  cipher" — a DMCA §1201 anti-circumvention claim, statute rather than contract.

### What changed

Nothing about the law. The **distribution target** changed. Guideline 5.2.1 governs App
Store review; it does not reach an app signed with your own certificate and installed on
your own device. Removing App Store distribution from the requirements removes the
constraint that was doing all the work.

### What this costs, stated plainly

- **It will break.** Brave — with a paid team and the best filter lists in the industry —
  has had four documented multi-week YouTube ad-blocking outages on iOS since 2024
  (May 2024, Dec 2024, May 2025, Jan 2026). Expect the same and do not treat a breakage
  as a regression in this codebase until the upstream rules have been checked.
- **Server-side ad insertion is a live threat.** If YouTube stitches ads into the media
  stream, no client-side technique survives — not scriptlets, not filter engines, not
  stream extraction. Sources disagree on how far SSAI has rolled out. Treat it as a risk
  that ends this approach, not a distant hypothetical.
- **Sideload upkeep.** Free Apple ID certificates expire every 7 days (3 apps max); a paid
  account lasts a year; SideStore/AltStore automate re-signing over WiFi.

### To revert to a shippable app

Restore three rules, all of which the git history still contains:

1. Player stays visible — mount the web view at 16:9 whenever a YouTube track is loaded.
2. `PlaybackCoordinator.applicationDidEnterBackground()` pauses YouTube tracks.
3. No script injection of any kind into YouTube pages.

Rule 3 below (`videoEmbeddable`/`videoCategoryId`) is **not** part of the reverted set — it
is good behaviour regardless and has a test asserting it. Keep it.

## 3. Ad blocking and background audio — the design

**STATUS: agreed, NOT YET BUILT.** As of the last commit, `YouTubePlayerEngine` still uses
the cross-origin IFrame embed and `applicationDidEnterBackground()` still pauses YouTube.
Do not describe the design below as if it ships. Build it, then update this section.

The research behind it is in `docs/superpowers/specs/` — read the spec before implementing.

### The core technique

Delete `adPlacements`, `playerAds`, `adSlots`, and `adBreakHeartbeatParams` from YouTube's
`/youtubei/v1/player` response before the page's own script parses it. The player concludes
no ad inventory exists, so it never schedules an ad and no anti-adblock warning fires.

NouTube and Brave arrived at this independently. These four key names have not changed in
24 months of upstream filter-list history.

### Non-obvious rules, each of which cost real debugging time to learn

1. **The IFrame embed cannot work.** It is cross-origin; no injected script can reach
   inside it. `YouTubePlayerEngine` must load `m.youtube.com` as a first-party document.
   This is a structural fact, not a preference.
2. **Scriptlets go in `WKContentWorld.page`, at `.atDocumentStart`, `forMainFrameOnly: false`.**
   Anything patching a page global — `fetch`, `XMLHttpRequest`, `JSON.parse`,
   `ytInitialPlayerResponse` — must be in the page's own world. A main-world script placed
   in `.defaultClient` **runs, reports success, and does nothing**. It fails silently in
   exactly one direction. Only DOM-reading code and native `postMessage` handlers belong
   in `.defaultClient`.
3. **`WKUserScript` cannot target a subframe.** It is all-frames or main-frame-only. Guard
   inside the script on the frame's origin, or it executes in every unrelated iframe.
4. **Do not block `visibilitychange` on iOS.** It conflicts with media backgrounding —
   Brave says so in a source comment and explicitly skips it on iOS. Override
   `Document.prototype.hidden` → `false` and `visibilityState` → `'visible'` instead.
5. **Refresh `window._lact` every 5 minutes.** It is YouTube's last-activity timestamp.
   Without it, long playback stops on its own. Also dispatch a synthetic `mousemove` on
   `#movie_player` periodically to defeat "Are you still watching?". For a music app
   playing for hours these are load-bearing, not polish.
6. **Handle the SABR backoff.** YouTube sends `backoffTimeMs` covering the ad slot's
   duration. Blocking the ad does not remove the backoff, so a naive implementation shows
   a **4–16 second spinner** instead of an ad — worse than the ad. See
   `brave-yt-sabr-fix.js`.
7. **Intercept `ytInitialData` via `Object.defineProperty`.** The server-rendered payload
   arrives in a `<script>` tag and never passes through `fetch` or `XHR`, so the first page
   load is unblocked without this.
8. **`get_watch` nests the payload** at `data[0].playerResponse`, and the endpoint regex
   must cover `browse|get_watch|next|player|search`, not just `/player`.
9. **Prepend `scriptletGlobals`** if any uBO scriptlet is used, or `safeSelf()` throws a
   `ReferenceError` that the per-scriptlet try/catch swallows into a silent no-op. Brave
   declares it as a Proxy over a Map.

### Why adblock-rust is not a dependency

`youtube-clons/adblock-rust` is Brave's engine and it does support iOS — but only by
converting filter rules to Safari content-blocking JSON, which **cannot express `+js(...)`
scriptlets** (`CbRuleCreationFailure::ScriptletInjectionsNotSupported`). Every rule that
blocks YouTube video ads is a scriptlet. The iOS conversion path drops all of them.

The engine's *runtime* cosmetic API does return usable JavaScript, but embedding it costs
rustup + iOS targets + a hand-written C ABI (the crate has no `extern "C"` anywhere) +
xcframework packaging + a `.dat` format upstream may break on a patch bump — roughly
10–12 engineer-days to deliver JavaScript we can extract in seconds.

**So it is a build-time data source, not a runtime dependency.**
`scripts/extract-brave-scriptlets.py` pulls scriptlet bodies out of
`brave-resources.json`. Re-run it against a newer bundle when YouTube breaks things.

## 4. Running it

```bash
brew install xcodegen          # once
xcodegen generate              # regenerate Riff.xcodeproj after touching project.yml
open Riff.xcodeproj
```

Search needs a YouTube Data API key, entered in the app's Settings tab (stored in the
keychain). Create one at console.cloud.google.com → enable "YouTube Data API v3" →
Credentials → API key. Free tier is 10,000 quota units/day; one search costs 100, which
is why `SearchViewModel` debounces at 450ms.

Deploying to a physical device needs a signing team set in Xcode. That is a manual,
interactive step — an agent cannot do it for you.

## 5. Testing

```bash
swift test --package-path RiffKit    # 51 unit tests, run on macOS in ~20ms
xcodebuild -project Riff.xcodeproj -scheme Riff \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test    # 11 UI tests, ~2.5 min
./scripts/screenshots.sh             # writes screenshots/ from a simulator run
./scripts/typecheck-ios.sh           # fast compile-only gate, no simulator needed
```

Anything with real logic belongs in `RiffKit` with a unit test — it runs three orders of
magnitude faster than a UI test and does not need a simulator. The UI tests exist only to
cover what unit tests structurally cannot see: navigation, persistence reaching the
screen, and each screen's empty/error state.

**Test the injected JavaScript in `RiffKit` via `JSContext`.** `JavaScriptCore` is not a UI
framework, so it does not violate RiffKit's no-UI-imports rule. The ad-strip logic is a
pure function — JSON in, JSON out — so it can be unit-tested on macOS in milliseconds
against a captured player-response fixture. This is the single most valuable test in the
project: it is the most fragile code, and without it "there is an ad" is a mystery instead
of a named failing assertion.

`typecheck-ios.sh` predates the simulator being usable here and is kept because it is
seconds rather than minutes. It builds RiffKit for `arm64-apple-ios17.0-simulator` and
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

## 6. Layout

```
RiffKit/Sources/RiffKit/
  Models/       Track, Playlist, Library, MediaSource
  Library/      LibraryStore (@Observable) + JSON persistence behind a protocol
  Playback/     PlaybackQueue — cursor, shuffle, repeat, reordering. Pure value type.
  YouTube/      YouTubeSearchClient over an injectable HTTPFetching
  Support/      ISO8601 duration parsing, collection move, HTTP stub for tests

Riff/
  App/          RiffApp entry point, AppEnvironment composition root
  Playback/     PlaybackEngine protocol, YouTubePlayerEngine (WKWebView + JS bridge),
                LocalAudioEngine (AVPlayer), PlaybackCoordinator (routes queue → engine)
  Services/     APIKeyStore (keychain), LocalMediaImporter (file copy + metadata)
  Features/     One folder per screen, plus shared Components
```

## 7. Conventions

### Engineering principles

- **DRY, and mean it.** A fact belongs in exactly one place. The ad-key list lives in the
  JavaScript and is never mirrored into Swift. Filter data is extracted by a committed
  script, never hand-copied. If you find yourself typing the same constant twice, the
  second one is a bug waiting for the first one to change.
- **Use skills.** Check for a relevant skill before starting any non-trivial task and
  invoke it. `superpowers:brainstorming` before designing, `superpowers:writing-plans`
  before implementing, `superpowers:systematic-debugging` before guessing at a bug.
- **Use context7 for library and API documentation.** Prefer it over recollection or web
  search for anything about a framework, SDK, or CLI — including Apple's. Training data
  goes stale; this project depends on WebKit behaviour that changes between iOS releases.
- **Verify, don't assert.** This project has already been wrong twice from reasoning
  instead of checking: the Musi legal history, and whether WKWebView can play audio in the
  background. Both were settled by going and looking. Read the source, run the code, quote
  the file and line.
- **Say what is not built.** Design decisions and shipped code are different things.
  Mark planned work as planned — a doc that overstates reality costs more than no doc.

### Code

- Persistence is a whole-library JSON re-encode per mutation, behind `LibraryPersisting`.
  Fine at this size; if the library grows past a few thousand tracks, revisit before
  optimising anything else.
- `PlaybackQueue` is a value type with no engine knowledge. Keep it that way — it is the
  part most likely to grow subtle bugs, and it is only cheap to test because it is pure.
- Don't add `move(fromOffsets:toOffset:)` to a collection in RiffKit; SwiftUI defines its
  own and the two become ambiguous. The package's version is `moveElements`.
- Two engines, one coordinator. `PlaybackCoordinator.isActive(_:)` drops events from the
  engine that isn't in charge, so a stopping engine's final `.idle` can't clobber the
  track just started on the other one.
- Injected JavaScript lives in `.js` resource files, never in Swift string literals, so it
  stays diffable, lintable, and testable.

## 8. Borrowed code and licences

Reference clones live in `../youtube-clons/` and are **read-only**. Mine them for
technique; do not copy files across without checking the licence.

| Source | Licence | Reusable here? |
|---|---|---|
| `adblock-rust` (Brave engine) | MPL-2.0 | Yes — file-level copyleft |
| `brave-video-bg-play-update.js`, via `brave-resources.json` | MIT (from `mozilla/video-bg-play`) | **Yes** — this is the background-playback implementation to adapt |
| uBO scriptlets (`json-prune`, `set-constant`) | GPL-3.0 | Personal use only; no distribution means no obligation triggered |
| NouTube | AGPL-3.0 | No — reimplement the idea |
| FreeTube | AGPL-3.0 | No |
| LibreTube | GPL-3.0 | No |

Record provenance in a comment whenever you adapt code from any of these.

## 9. Known stale artefacts

- `docs/riff-architecture.html` documents the **pre-fork** architecture — IFrame embed,
  player always visible, YouTube pausing in background. It is accurate for the code as it
  stands today and will be wrong the moment §3 is implemented. Regenerate it then.
