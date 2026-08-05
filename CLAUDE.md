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

Restore four rules, all of which the git history still contains:

1. Player stays visible — mount the web view at 16:9 whenever a YouTube track is loaded.
2. `PlaybackCoordinator.applicationDidEnterBackground()` pauses YouTube tracks.
3. No script injection of any kind into YouTube pages.
4. Search through the official Data API v3 with a user-supplied key, rather than InnerTube.
   `git show c7fc009:RiffKit/Sources/RiffKit/YouTube/YouTubeSearchClient.swift` has the
   whole implementation, tests included.

## 3. Ad blocking and background audio

**STATUS: built and shipping.** `YouTubePlayerEngine` drives `m.youtube.com` first-party
with four injected scripts; `applicationDidEnterBackground()` is an empty hook.

The research behind it is in `docs/superpowers/specs/` — worth reading before changing any
of this, because most of the rules below look arbitrary until you know what they cost.

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

Nothing to configure. Search needs no API key and no account — see §3a.

Deploying to a physical device needs a signing team set in Xcode. That is a manual,
interactive step — an agent cannot do it for you.

## 3a. Search, without an API key

`InnerTubeSearchClient` runs YouTube's own search request from inside a real, first-party
`m.youtube.com` document, and reads the results back. This is how the app searches; the
Data API v3 client it replaced is gone (§2, revert rule 4).

Three facts make it work, all verified live rather than assumed:

- **No key is needed.** The `key` parameter is ignored — a deliberately bogus key returns
  the same 200 and the same results as the real one. yt-dlp and NewPipe both stopped
  sending it. So Riff sends none, which also removes the "whose key is this?" question.
- **Search needs no bot attestation.** PoToken and BotGuard gate `/youtubei/v1/player`,
  not `/youtubei/v1/search`. yt-dlp's source defines PO token policies for streams, player
  and subtitles and has *no* search policy at all. That split is why this works while
  stream extraction does not — and it is why Riff does not extract streams.
- **In-page beats a native request.** A same-origin `fetch` inherits the page's cookies
  (including HttpOnly ones), a browser-set `Origin` and `Referer` that page JS cannot
  forge, and `ytcfg`'s `INNERTUBE_CONTEXT` — which carries server-minted `visitorData`,
  `rolloutToken` and `appInstallData` that cannot be fabricated at all.

Rules:

1. **Search gets its own web view, separate from the player's.** `AdStrip.js` patches
   `window.fetch` and matches `/youtubei/v1/search`, so sharing would route every search
   through the ad-stripper — a clone and a full JSON parse of a ~119KB body, in the
   process decoding audio, to remove nothing. Separate configurations make that
   impossible rather than something to remember. Cookies are still shared, because
   `websiteDataStore` defaults to the process-wide store.
2. **The host document must be a real YouTube page.** A blank document with a `baseURL`
   would give the right origin but no `ytcfg`, and `ytcfg` is the entire reason for using
   a web view.
3. **`ytcfg` does not exist at `.atDocumentStart`.** Read it lazily, at search time.
4. **Never persist a response thumbnail URL.** They carry expiring `sqp`/`rs` signature
   params. Use `https://i.ytimg.com/vi/<id>/hqdefault.jpg`, which does not expire. There
   is a test for this.
5. **`params: 'EgIQAQ=='`** filters to videos, dropping Shorts, channels and playlist
   shelves — which removes most of the parsing edge cases.

## 3b. Favorites, and what a tap means

**My Favorites is a list the user builds, not "everything the app has seen".**
It is `Library.favoriteTrackIDs`, separate from the `tracks` catalogue.

That distinction is the whole point, and getting it wrong was a real bug:
`SearchView` used to `upsert` a track before playing it so the queue could
resolve it later, which meant every song you merely listened to appeared under
My Favorites. `PlaybackQueue` holds `Track` values rather than ids, so playback
needs nothing stored at all.

The rules, each with a test:

1. **Tapping a song plays it and touches nothing else.** No library write, no
   favorite, no checkmark.
2. **`+` opens `AddToPlaylistSheet`.** Every row is a toggle, so the checkmarks
   double as "which lists is this song already in". My Favorites sits there as
   one list among several, which is what it is.
3. **The heart is the only control that adds to Favorites** — in Now Playing,
   in the sheet, and in the long-press menu.
4. **Un-favoriting leaves the track in the catalogue**, so playlists containing
   it and the queue playing it are unaffected.
5. **Search result rows always show `+`, never a checkmark.** A song can be in
   several lists at once, so there is no single "added" state to show.

`Library` decodes tolerantly (`init(from:)` with `decodeIfPresent` defaults).
Keep it that way. Without it, adding any field to that type throws
`keyNotFound`, and `LibraryStore` reacts to a decode failure by starting from an
empty `Library` — silently deleting every existing user's music on first launch.
There is a test that loads a favorites-less library file and asserts the music
survives.

### Suggestions and history

`SuggestionClient` fetches YouTube's autocomplete — the same endpoint its own
search box uses, no key, no account:

```
https://suggestqueries-clients6.youtube.com/complete/search
  ?client=firefox&ds=yt&oe=utf-8&hl=<lang>&gl=<region>&q=<query>
```

Every parameter is load-bearing. `client=firefox` selects the flat-array shape;
the others wrap it in JSONP or per-item tuples. `ds=yt` scopes to YouTube rather
than Google Web. **`oe=utf-8` is not optional** — without it non-Latin scripts
come back as mojibake, which for this library means most of it. `gl` measurably
changes results.

- **Parse `root[1]`, and guard `root.count > 1`.** An empty result is a *two*
  element array, so anything reaching for index 2 crashes on no-suggestions.
- **This one runs natively, not in the web view**, unlike search. The endpoint's
  CORS policy would permit an in-page fetch, so that is not the reason. The
  reasons are: the web view must finish loading m.youtube.com before any script
  runs, so the first keystroke of a session would block on a page load; that web
  view is a single `@MainActor` instance already busy with the 119KB search; and
  native code is testable on macOS in milliseconds.
- **Failures are silent, never thrown.** The user is mid-word; an error banner
  for a feature they did not ask for is worse than no suggestions.
- **150ms debounce, separate task from search's 450ms.** They must not cancel
  each other.
- **Drop out-of-order responses.** These requests are small and fast enough that
  interleaving is likely, not theoretical. Capture the query at request time and
  discard any reply whose query is no longer current.
- **Accepting a suggestion has a required order:** assign `query` first, *then*
  clear suggestions. `query`'s `didSet` fires synchronously and schedules a new
  fetch, so clearing first reopens the list under the user's finger.

Search history is a **separate `search-history.json`**, never a field on
`Library`. Swift's synthesized `Decodable` throws `keyNotFound` for a property
missing from stored JSON, and `LibraryStore.init` handles a decode failure by
starting from an empty `Library` — so adding a field there would delete the
user's whole library on first launch of the new build.

**What was lost:** the Data API's `videoEmbeddable=true` and `videoCategoryId=10` filters
have no InnerTube equivalent, so a non-embeddable video can now reach the queue. The
authoritative signal is at playback instead — IFrame error codes **101** and **150** mean
"embedding disabled by owner". `YouTubePlayerEngine` reports those; skipping the track
automatically is not implemented yet.

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
- **Use skills, every time.** Check for a relevant skill before starting any non-trivial
  task and invoke it — this is not optional and not a judgement call.
  `superpowers:brainstorming` before designing, `superpowers:writing-plans` before
  implementing, `superpowers:systematic-debugging` before guessing at a bug,
  `superpowers:verification-before-completion` before claiming something works.
  Process skills come first and set the approach; implementation skills follow.
- **Gather context with subagents.** Before writing against an unfamiliar API or making an
  architectural call, dispatch agents to read the actual source and report exact
  signatures. Every significant decision in this project was made this way, and twice it
  reversed the answer.
- **Use context7 for library and API documentation.** Prefer it over recollection or web
  search for anything about a framework, SDK, or CLI — including Apple's. Training data
  goes stale; this project depends on WebKit behaviour that changes between iOS releases.
- **Verify, don't assert.** This project has already been wrong twice from reasoning
  instead of checking: the Musi legal history, and whether WKWebView can play audio in the
  background. Both were settled by going and looking. Read the source, run the code, quote
  the file and line.
- **Say what is not built.** Design decisions and shipped code are different things.
  Mark planned work as planned — a doc that overstates reality costs more than no doc.
- **YAGNI.** Build what is needed now, not what might be needed. This project has already
  been saved real weeks by it twice: embedding Brave's Rust engine was 10–12 days to
  deliver a string constant we already had, and a Piped-style backend would have made us
  the operator of a service. When a feature is genuinely coming, leave a documented seam —
  not an abstraction with one implementation.
- **DRY, with a caveat.** One fact, one place. But two things that merely *look* alike are
  not duplication — `TrackCollectionView` was extracted because both playlist screens are
  the same screen, whereas the two playback engines stay separate because they only
  resemble each other from the outside.
- **No dead code, no commented-out code.** Git remembers. A deleted thing that mattered
  gets a note in the doc comment explaining why it went, like
  `applicationDidEnterBackground()`.
- **Fix the cause, not the symptom.** The web view crash was a gesture-graph conflict; the
  fix was making it a player instead of a browser. Reach for the reason one layer down
  before patching what you can see.

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
