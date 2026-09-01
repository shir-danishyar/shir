# CLAUDE.md — Shir

An iPhone music app: playlists, a queue, and two playback sources.

**New here? Read §1, §3 and §9.** That is the shape of the app, where the code
lives, and the traps that already cost someone a day. Everything else is
reference you can come back to.

---

## 1. Orientation

Shir plays music from two places and treats them as one library:

- **YouTube**, in a `WKWebView` driving `m.youtube.com`, with ads removed
- **Imported audio files**, played by `AVPlayer`

One decision explains most of the codebase: **this app is sideloaded onto one
personal iPhone, not shipped to the App Store** (§4). That is what permits ad
stripping and background playback, and it is reversible — §4 says how.

Two things are true of nearly every non-obvious line here, and both are worth
internalising before changing anything:

1. **The web view is a player, not a browser.** The user never sees or touches
   YouTube's interface. Letting them crashed the app (§9).
2. **Injected JavaScript does the work Swift cannot.** Ad removal, background
   audio and search all happen inside the page.

### Reading order for a new task

| You are about to… | Read |
|---|---|
| Change anything about YouTube playback | §5, then §9 |
| Touch search, suggestions or history | §6 |
| Change what a tap does in a list | §7 |
| Add a feature | §3 for placement, §8 for where its test goes |
| Debug "the ads came back" | §5, §9, then `scripts/extract-brave-scriptlets.py` |
| Work out why something is the way it is | `git log` — commit messages here carry the reasoning |

---

## 2. Quick reference

```bash
xcodegen generate                     # after ANY change to project.yml
swift test --package-path ShirKit     # 133 unit tests, macOS, ~0.1s
./scripts/typecheck-ios.sh            # compile-only gate, seconds, no simulator

# 20 UI tests, ~5 min. BackgroundPlaybackTests and SearchAutoplayTests need the network. Use an explicit device id — several simulators share names.
xcodebuild -project Shir.xcodeproj -scheme Shir \
  -destination 'platform=iOS Simulator,id=<UDID>' test

./scripts/screenshots.sh              # regenerates screenshots/
./scripts/extract-brave-scriptlets.py --list    # harvest filter data from Brave
./scripts/make-app-icon.py --preview  # rebuilds AppIcon.appiconset from docs/logo/
```

The app icon is **generated, but committed** — `AppIcon-{light,dark,tinted}.png`
are build inputs, so they live in the asset catalogue. Re-run the script after
replacing `docs/logo/shir-icon-source.png`; do not hand-edit the PNGs.

`Shir.xcodeproj` is **generated** and gitignored. Edit `project.yml`, never the
project file. Nothing else needs configuring — search takes no API key.

Deploying to a physical device needs a signing team. It is **not** committed —
this repo is public and a team id is personal to an Apple developer account.
`project.yml` reads it from the environment, so export it before generating:

```bash
export SHIR_DEVELOPMENT_TEAM=<your team id>   # then: xcodegen generate
```

Unset, XcodeGen writes the `${SHIR_DEVELOPMENT_TEAM}` token through literally
and Xcode expands the undefined setting to empty — so simulator builds and
`./scripts/typecheck-ios.sh` work untouched on a fresh clone. (XcodeGen's docs
say a missing variable is *removed*; the source leaves the token in place.
Verified, because the difference decides whether a clone builds.)

**A device build with it unset fails**, and the failure is confusing because it
is Xcode's *destination*, not your code: `Signing for "Shir" requires a
development team`. Pressing ▶ with an iPhone or "Any iOS Device" selected hits
this; switching the destination to a simulator does not. Export and regenerate.
The Xcode Signing & Capabilities route also works, but it writes into the
generated project, so the next `xcodegen generate` discards it.

A `configFiles`/xcconfig alternative was tried and rejected: XcodeGen fails spec
validation outright when the referenced file is absent, so a fresh clone could
not generate a project at all. The env var degrades; a config file does not.

---

## 3. Architecture

```
┌─ Shir (iOS app target) ────────────────────────────────────────┐
│                                                                │
│  Features/          SwiftUI screens, one folder per area       │
│      ↕                                                         │
│  AppEnvironment     composition root — built once, passed      │
│                     down via .environment()                    │
│      ↕                                                         │
│  PlaybackCoordinator ── routes the queue to an engine          │
│      ├── YouTubePlayerEngine   WKWebView + 5 injected scripts  │
│      └── LocalAudioEngine      AVPlayer                        │
│                     both conform to PlaybackEngine             │
│                                                                │
│  InnerTubeSearchClient   a SECOND, hidden WKWebView            │
└────────────────────────────────────────────────────────────────┘
                              ↕
┌─ ShirKit (SwiftPM package) ────────────────────────────────────┐
│  Models · LibraryStore · PlaybackQueue · SearchHistory         │
│  SuggestionClient · Resources/Scripts/*.js                     │
│  No UIKit, no SwiftUI, no WebKit → tests run on macOS          │
└────────────────────────────────────────────────────────────────┘
```

### The layering rule

**Anything with real logic goes in `ShirKit` with a unit test.** ShirKit imports
no UI framework, so its tests run on macOS in milliseconds instead of booting a
simulator — 133 tests in about a tenth of a second. The app target holds only
what genuinely needs UIKit, WebKit or AVFoundation.

`JavaScriptCore` is **not** a UI framework, which is why the injected scripts
live in ShirKit and are unit-tested there. That is the highest-value test suite
in the project (§8).

### File map

| File | Purpose |
|---|---|
| **ShirKit — models** | |
| `Models/Track.swift` | The unit of music. `id` is derived: `yt:<videoID>` / `file:<name>` |
| `Models/MediaSource.swift` | The `.youtube` / `.localFile` fork that decides engine and behaviour |
| `Models/Playlist.swift` | `Playlist` + `Library`. **`Library` decodes tolerantly — keep it that way (§9)** |
| **ShirKit — state** | |
| `Library/LibraryStore.swift` | `@Observable` store. Catalogue, playlists, favorites. Persists on every mutation |
| `Library/LibraryPersistence.swift` | Whole-library JSON behind a protocol, plus an in-memory double |
| `Search/SearchHistory.swift` | Recent queries. **Its own file, never a field on `Library` (§9)** |
| `Playback/PlaybackQueue.swift` | Pure value type. Cursor, shuffle, repeat. No engine knowledge |
| `Playback/AutoResumePolicy.swift` | Pure value type. Decides which player pauses get answered with `play()` — WebKit's backgrounding pause yes; the user's, iOS's and a dead player's no (§9) |
| `Playback/NowPlayingDragPolicy.swift` | Pure value type. Where the player sits under a finger, and whether a release dismisses. Stands down while the scrubber has the touch (§9) |
| **ShirKit — YouTube** | |
| `YouTube/PlayerScripts.swift` | Loads the `.js` from the package bundle. One place that knows where they live |
| `YouTube/SuggestionClient.swift` | Autocomplete, over `HTTPFetching`. Native, not in a web view |
| `YouTube/TrendingClient.swift` | The charts on the default Search screen. Keyless InnerTube `browse`, native, fixture-tested |
| `YouTube/YouTubeVideo.swift` | A search result, before it becomes a `Track` |
| `Resources/Scripts/MediaSession.js` | Owns `navigator.mediaSession`: Shir's metadata on the lock screen, presses routed to Shir's queue. Injected first |
| `Resources/Scripts/AdStrip.js` | Deletes ad inventory before the player parses it |
| `Resources/Scripts/BackgroundPlay.js` | Keeps audio alive with the screen off |
| `Resources/Scripts/PlayerSurface.js` | Hides YouTube's chrome |
| `Resources/Scripts/Bridge.js` | Player commands in, state and progress out |
| `Resources/Scripts/Search.js` | Keyless InnerTube search, run inside the page |
| **App — playback** | |
| `Playback/PlaybackEngine.swift` | The protocol both engines satisfy: 3 closures, 5 methods |
| `Playback/PlaybackCoordinator.swift` | Owns the queue, routes to an engine, drives Now Playing info |
| `Playback/YouTubePlayerEngine.swift` | The web view, the script injection, the JS bridge |
| `Playback/LocalAudioEngine.swift` | `AVPlayer`, plus `MediaLibraryLocation` |
| **App — services** | |
| `Services/InnerTubeSearchClient.swift` | Search, in its own hidden web view (§6) |
| `Services/LocalMediaImporter.swift` | File copy and metadata for imports |
| **App — screens** | |
| `Features/Root/RootTabView.swift` | Four tabs, mini player, Now Playing cover, global error alert |
| `Features/Library/FavoritesView.swift` | My Favorites, alphabetised, with the letter index |
| `Features/Library/PlaylistsView.swift` | Recent carousel, derived playlists, user playlists |
| `Features/Library/TrackCollectionView.swift` | Shared body of playlist detail and derived playlists |
| `Features/Library/AddToPlaylistSheet.swift` | Where `+` leads (§7) |
| `Features/Search/SearchView.swift` | Field, history, suggestions, results, trending charts — five states |
| `Features/Search/SearchViewModel.swift` | Two debounces, two tasks |
| `Features/Player/NowPlayingView.swift` | Full-screen player. Mounts the engine's web view. A layer in `RootTabView`'s stack, not a cover, and pulls down to close (§9) |
| `Features/Player/MiniPlayerBar.swift` | The bar above the tab bar |
| `Features/Components/Theme.swift` | Palette sampled from reference screenshots, not eyeballed |

---

## 4. The fork: this is a personal-device build

Shir targets **one physical iPhone, sideloaded**. Decided 2026-08-04. Both
positions are recorded because the trade matters more than the outcome.

**What the constraint used to be.** Until that date the app played YouTube
through the official IFrame Player, ads intact, pausing in the background. The
reasoning was sound *for a shipping product*: App Store Guideline 5.2.1 rejects
ad-stripping YouTube clients, and rightsholder complaints have repeatedly been
enough to get one delisted. Apple's developer agreement lets it remove any app
"at any time, with or without cause", and courts have upheld that — so no
technical argument about which API a client uses protects it. Distribution is
the chokepoint, not the API.

**What changed.** Nothing about the law — the *distribution target*. 5.2.1
governs App Store review; it does not reach an app signed with your own
certificate on your own device.

**What it costs.**

- **It will break.** Brave — paid team, best filter lists in the industry — has
  had four documented multi-week YouTube ad-blocking outages on iOS since 2024.
  Treat a breakage as upstream until proven otherwise.
- **Server-side ad insertion would end this.** If YouTube stitches ads into the
  media stream, nothing client-side survives. Sources disagree on how far it has
  rolled out. Treat it as live risk, not a distant hypothetical.
- **Sideload upkeep.** Free Apple ID certs expire every 7 days (3 apps max); a
  paid account lasts a year; SideStore/AltStore automate re-signing over WiFi.

**To revert to a shippable app**, restore four rules — git history has them all:

1. Player stays visible — mount the web view at 16:9 for any YouTube track.
2. `PlaybackCoordinator.applicationDidEnterBackground()` pauses YouTube tracks.
3. No script injection of any kind into YouTube pages.
4. Search through the official Data API v3 with a user-supplied key.
   `git show 1747374:ShirKit/Sources/ShirKit/YouTube/YouTubeSearchClient.swift`
   has the whole implementation, tests included.

---

## 5. Playback

Two engines, one coordinator, one protocol. `PlaybackCoordinator.isActive(_:)`
drops events from whichever engine is not in charge, so a stopping engine's
final `.idle` cannot clobber the track just started on the other one.

The lock screen is part of the injected-scripts surface: for YouTube tracks
the Now Playing card is published by WebKit from what the *page's* media
session holds, so `MediaSession.js` — not `MPNowPlayingInfoCenter` — is what
puts Shir's title and buttons there (§9 has both traps).

### The YouTube technique

Delete `adPlacements`, `playerAds`, `adSlots` and `adBreakHeartbeatParams` from
YouTube's `/youtubei/v1/player` response before the page's own script parses it.
The player concludes no ad inventory exists, so it never schedules an ad and no
anti-adblock warning fires.

NouTube and Brave arrived at this independently. Those four key names have not
changed in 24 months of upstream filter history.

### Rules that look arbitrary until you know the cost

1. **The IFrame embed cannot work.** It is cross-origin; no injected script can
   reach inside it. Structural fact, not preference — the reason the engine
   loads `m.youtube.com` as a first-party document.
2. **Scripts go in `WKContentWorld.page`, at `.atDocumentStart`,
   `forMainFrameOnly: false`.** They patch page globals — `fetch`,
   `XMLHttpRequest`, `Document.prototype`. In `.defaultClient` they run, report
   success, and do nothing. **The failure is completely silent.**
3. **`WKUserScript` cannot target a subframe.** Guard on frame origin inside the
   script, or it executes in every unrelated iframe.
4. **Do not block `visibilitychange` on iOS.** It conflicts with media
   backgrounding — Brave says so in a source comment and skips it on iOS.
   Override `Document.prototype.hidden` and `visibilityState` instead.
5. **Refresh `window._lact` every 5 minutes.** YouTube's last-activity
   timestamp. Without it, long playback stops on its own. Also dispatch a
   synthetic `mousemove` to defeat "Are you still watching?". For an app that
   plays for hours these are load-bearing, not polish.
6. **Handle the SABR backoff.** YouTube sends `backoffTimeMs` covering the ad
   slot. Blocking the ad does not remove the backoff, so a naive implementation
   shows a **4–16 second spinner** instead of an ad — worse than the ad.
7. **Intercept `ytInitialData` via `Object.defineProperty`.** The server-rendered
   payload arrives in a `<script>` tag and never passes through `fetch` or
   `XHR`, so the first page load is unblocked without it.
8. **`get_watch` nests the payload** at `data[0].playerResponse`, and the
   endpoint regex must cover `browse|get_watch|next|player|search`.
9. **The bridge unmutes on every transition to `playing`.** WebKit permits
   unattended autoplay only when the media is silent, so YouTube starts each
   video muted and waits for a tap on its own TAP TO UNMUTE overlay. Nothing
   else will unmute it — and a timer instead of the event means a silent
   intro: the 900ms version played the first second of every track muted,
   behind the banner. `Bridge.js` also unmutes at wire-up if the player is
   already playing, because an already-playing player fires no transition.
   The banner itself (`.ytp-unmute`, DOM verified live) is hidden by
   `PlayerSurface.js` — it flashes for the beat between playback starting
   and the unmute landing, and a user who cannot touch the page must never
   be told to tap it.
10. **Background audio needs all three:** `UIBackgroundModes: audio`, the
    visibility overrides, and the answer to WebKit's backgrounding pause.
    That answer is two-layered: `BackgroundPlay.js` replays in-page,
    synchronously inside the pause event, because on a device the paused
    session drops WebKit's media assertion and its processes suspend before
    a native round trip can land (the simulator enforces no suspension —
    this exact gap shipped); the native `AutoResumePolicy` remains the judge
    for every slower case and for who-paused questions the page cannot see.
    The audio *session* is deliberately **not** the app's to activate: WKWebView
    media plays through WebKit's helper-process session, attributed to this
    app, activated by WebKit on every play — and an app-side `.playback`
    session alongside it is a rival that mediaserverd bounces with an
    interruption pair at every foreground return (a measured one-second
    pause). The engine *releases* the app session instead; only
    `LocalAudioEngine` activates one. Brave ships the same split. Any leg
    missing and playback stops at home press or lock.
11. **Command `play()` when the bridge comes up; never trust the watch page to
    autoplay.** The page autoplays only when the web view is the visible
    stage — anywhere else it sits silent with the bridge ready and nothing
    playing. The engine's `"ready"` handler sends the explicit play, which
    works in every posture.

### Why adblock-rust is not a dependency

`youtube-clons/adblock-rust` is Brave's engine and it does support iOS — but
only by converting filter rules to Safari content-blocking JSON, which **cannot
express `+js(...)` scriptlets**
(`CbRuleCreationFailure::ScriptletInjectionsNotSupported`). 76 of Brave's 238
YouTube rules are scriptlets, and they are exactly the ones that kill video ads.

Embedding it at runtime would need rustup, iOS target stdlibs, a hand-written
C ABI (the crate has no `extern "C"` anywhere), xcframework packaging, and a
`.dat` format upstream may break on a patch bump — roughly 10–12 engineer-days
to deliver JavaScript we can extract in seconds.

**So it is a build-time data source, not a runtime dependency.**
`scripts/extract-brave-scriptlets.py` pulls scriptlet bodies out of
`brave-resources.json`. Re-run it against a newer bundle when YouTube breaks
things.

---

## 6. Search — no API key, no account

`InnerTubeSearchClient` runs YouTube's own search request from inside a real,
first-party `m.youtube.com` document. The Data API v3 client it replaced is gone
(§4, revert rule 4).

Three facts, all verified live rather than assumed:

- **No key is needed.** The `key` parameter is ignored — a deliberately bogus
  key returns the same 200 and the same results. yt-dlp and NewPipe both stopped
  sending it. Shir sends none.
- **Search needs no bot attestation.** PoToken and BotGuard gate
  `/youtubei/v1/player`, not `/youtubei/v1/search`. yt-dlp's source defines PO
  token policies for streams, player and subtitles and has *no* search policy.
  That split is why this works while stream extraction does not — and why Shir
  does not extract streams.
- **In-page beats a native request** *for search*. A same-origin `fetch`
  inherits the page's cookies (including HttpOnly ones), a browser-set `Origin`
  and `Referer` page JS cannot forge, and `ytcfg`'s `INNERTUBE_CONTEXT` —
  carrying server-minted `visitorData`, `rolloutToken` and `appInstallData` that
  cannot be fabricated.

**Search gets its own web view, separate from the player's.** `AdStrip.js`
patches `window.fetch` and matches `/youtubei/v1/search`, so sharing would route
every search through the ad-stripper: a clone and a full JSON parse of a ~119KB
body, in the process decoding audio, to remove nothing. Separate configurations
make that impossible by construction. Cookies are still shared, because
`websiteDataStore` defaults to the process-wide store.

Other rules: the host document must be a **real** YouTube page (a blank document
with a `baseURL` gives the right origin but no `ytcfg`); `ytcfg` does not exist
at `.atDocumentStart`, so read it lazily; never persist a response thumbnail URL
(they carry expiring `sqp`/`rs` params — use
`https://i.ytimg.com/vi/<id>/hqdefault.jpg`); and `params: 'EgIQAQ=='` filters to
videos, dropping Shorts and channel rows.

### Trending

The default Search screen's charts come from `TrendingClient` — a plain
native keyless InnerTube `browse` of YouTube Charts' published playlists,
pinned to the **global** editions (Top 100 / Daily Top): the chart country
picker covers few countries, `gl` does not switch it, and global is the honest
default rather than someone else's country. Verified live: no key, no
cookies, no visitorData needed — like search and suggestions, PoToken gates
only `/player`. Do **not** use `browseId: FEtrending`; YouTube removed the
Trending page server-side (400) — the chart playlists are the living route.

Items arrive as `lockupViewModel`, YouTube's newest and most churn-prone
render format. The parser walks the whole response for lockups instead of
hardcoding the wrapper nesting, and is tested against a captured fixture
(`ShirKit/Tests/ShirKitTests/Fixtures/trending-browse.json`). When trending
goes blank: re-capture with a keyless POST to
`m.youtube.com/youtubei/v1/browse` (`browseId: "VL<playlistID>"`, MWEB
client), diff against the fixture, fix the parser. MWEB lockups carry no
duration (`overlays: null`) — that is why chart rows have no time badge.

### Suggestions

`SuggestionClient` uses the endpoint YouTube's own search box uses:

```
https://suggestqueries-clients6.youtube.com/complete/search
  ?client=firefox&ds=yt&oe=utf-8&hl=<lang>&gl=<region>&q=<query>
```

Every parameter is load-bearing. `client=firefox` selects the flat-array shape;
others wrap it in JSONP. `ds=yt` scopes to YouTube. **`oe=utf-8` is not
optional** — without it non-Latin scripts arrive as mojibake, which for this
library means most of it. `gl` measurably changes results.

- **Parse `root[1]`, guarding `root.count > 1`.** An empty result is a *two*
  element array; reaching for index 2 crashes on no-suggestions.
- **This one runs natively, unlike search.** Not for CORS reasons — the endpoint
  permits an in-page fetch. Because the web view must finish loading
  `m.youtube.com` first, so the first keystroke of a session would block on a
  page load; because that web view is a single `@MainActor` instance already
  busy with the 119KB search; and because native code is testable on macOS.
- **Failures are silent, never thrown.** The user is mid-word.
- **150ms debounce, its own task**, separate from search's 450ms.
- **Drop out-of-order replies** by comparing against the current query.
- **Accepting a suggestion has a required order:** assign `query` *first*, then
  clear suggestions. `query`'s `didSet` fires synchronously and schedules a new
  fetch, so clearing first reopens the list under the user's finger.

### History

`SearchHistory` — most-recent-first, case-insensitive dedupe, capped at 20, in
its **own `search-history.json`** (§9 explains why it is not on `Library`).

---

## 7. Favorites, and what a tap means

**My Favorites is a list the user builds, not "everything the app has seen".**
It is `Library.favoriteTrackIDs`, separate from the `tracks` catalogue.

Getting this wrong was a real bug: `SearchView` used to `upsert` a track before
playing so the queue could resolve it later, which meant every song you merely
listened to appeared under My Favorites. `PlaybackQueue` holds `Track` *values*
rather than ids, so playback needs nothing stored.

Each rule has a test:

1. **Tapping a song plays it, opens Now Playing, and touches nothing else in
   the library.** The auto-open is the reference app's behaviour and a
   technical requirement at once — playback cannot *start* without it (§9's
   visibility trap). Only user-initiated plays open the cover
   (`userPlaybackToken` in `PlaybackCoordinator`); a track ending and
   advancing the queue never does.
2. **`+` opens `AddToPlaylistSheet`.** Every row is a toggle, so the checkmarks
   double as "which lists is this already in".
3. **The heart is the only control that adds to Favorites** — Now Playing, the
   sheet, and the long-press menu.
4. **Un-favouriting leaves the track in the catalogue**, so playlists containing
   it and the queue playing it are unaffected.
5. **Result rows always show `+`, never a checkmark.** A song can be in several
   lists at once, so there is no single "added" state.

---

## 8. Testing

133 unit tests (macOS, ~0.1s) and 20 UI tests (simulator, ~5 min; BackgroundPlaybackTests and SearchAutoplayTests need the network).

**Anything with real logic belongs in ShirKit with a unit test.** The UI tests
exist only for what unit tests structurally cannot see: navigation, persistence
reaching the screen, each screen's empty and error states, on-device geometry
(`NowPlayingStageTests`), and audio surviving backgrounding
(`BackgroundPlaybackTests`). Shared scaffolding — the `ShirUITestCase` base
class and the `XCUIApplication` helpers — lives in `XCUITestHelpers.swift`.

**The injected JavaScript is unit-tested via `JSContext`** —
`PlayerScriptsTests` loads a script into a JS context and runs it against
captured fixtures. This is the most valuable suite here: the ad-strip and the
search parser are the most fragile code in the project, and without these a
breakage presents as "there's an ad" or "search returns nothing" with no clue
why. The harness must model the browser — it shims `fetch`, `XMLHttpRequest` and
`document`, because `AdStrip.js` aborts entirely if a global it patches is
missing.

**Test isolation:** `-uitesting` points the library and history at a fresh temp
directory and is guarded by `testEachLaunchStartsFromACleanLibrary`.
`-seedLibrary` adds known tracks to the catalogue *but not to Favorites*, so the
flow tests can exercise play-versus-favourite offline.

**Bootstrap seams:** `-autoplayVideoID <id>` starts playback with no UI driving
it, and `-autoOpenNowPlaying YES` opens the cover so the stage is mounted —
together they are how `BackgroundPlaybackTests` reaches a playing state
deterministically, and how a bare `simctl launch` reproduces playback issues
without XCUITest at all (§9 explains why search-driven repros stall).

Prefer offline tests. The two committed history tests avoid the network
entirely, because history is recorded on submit whether or not the search
succeeded.

---

## 9. Pitfalls index

Everything below cost real debugging time. Scan this before diagnosing anything.

| Symptom | Cause | Fix |
|---|---|---|
| An injected script "runs" but has no effect | It is in `.defaultClient`, patching globals the page never sees | `WKContentWorld.page`, `.atDocumentStart` |
| Adding a field to `Library` empties everyone's library | Synthesized `Decodable` throws `keyNotFound`; `LibraryStore` reacts to a decode failure by starting empty | `Library.init(from:)` uses `decodeIfPresent` defaults — **keep it** |
| App crashes on touching the web view | WKWebView and YouTube gesture recognizers form a conflicting edge in `UIGestureGraph` | `isUserInteractionEnabled = false`. It is a player, not a browser |
| Every search crashes the app | A key provider using `MainActor.assumeIsolated`, called from a background context | Read the keychain directly, or keep the call off the main actor |
| Video plays but there is no sound | WebKit only allows unattended autoplay when muted; YouTube complies and waits for a tap | `Bridge.js` unmutes on every `playing` transition, and at wire-up if already playing. Not a timer — 900ms of delay was 900ms of silent intro |
| Ads replaced by a 4–16s spinner | SABR `backoffTimeMs` still covers the removed ad slot | Port `brave-yt-sabr-fix.js` |
| First song of a session plays an ad | `ytInitialData` is server-rendered and never passes through `fetch`/`XHR` | Intercept with `Object.defineProperty` |
| Playback stops roughly half an hour in | `window._lact` went stale | Refresh it every 5 min |
| The video is correctly 16:9 but barely half the screen wide | `.aspectRatio(_:contentMode: .fit)` inside a `VStack`. A stack proposes each child a *share* of the leftover height, and `.fit` inscribes the ratio in whatever it is offered — so a short proposal shrinks the **width**. Measured: 120pt offered → 213pt wide, 54% | Give the stage a definite width, then derive the height (`NowPlayingView.stage(width:)`). `.layoutPriority` measurably does nothing — Spacers already go last, so there is no height left to win. `.frame(maxWidth: .infinity)` after it widens the frame, not the child |
| A black band across the top of the video, same amount lost off the bottom | `.player-container` is `top: 48px` to clear the mobile header — which `PlayerSurface.js` hides, so nothing reclaims the space | `top: 0 !important`. Hiding an element does not collapse an offset reserved for it |
| Music blasts out of the phone speaker when AirPods disconnect | The auto-resume answered a pause it should have respected. "The app did not ask for this pause" is not enough to justify resuming — iOS pauses for calls, Siri, other apps and unplugged headphones, and every one of those means it | `AutoResumePolicy` is told *who* paused: `AVAudioSession` interruption and route-change observers in `YouTubePlayerEngine`. Only WebKit's backgrounding pause gets answered |
| YouTube never plays again until the app is killed | One failed or redirected first navigation. `hasLoadedDocument` latched before the load was known to succeed, so every later track ran `loadVideoById` against a document that never existed and queued behind a bridge that could never be ready | `resetForRetry()` on `didFailProvisionalNavigation`, and clear `appInitiatedNavigation` on **commit** rather than first use, so a consent/region redirect is not cancelled |
| Tapping the scrubber restarts the song | `onEditingChanged(true)` flips the binding's `get` to `scrubPosition` before the slider ever calls `set`, and a touch that never drags never calls it — so release seeks to a stale value, 0 on first use | Seed `scrubPosition` from the live position when editing begins |
| Audio stops the instant the app is backgrounded | WebKit force-pauses every video session on backgrounding (`BackgroundProcessPlaybackRestricted`). It is C++ app state: no injected visibility override reaches it, and it fires whether or not the web view is mounted. `UIBackgroundModes: audio` does **not** exempt a `<video>` | Answer the unasked-for pause with an immediate `play()` — WebKit accepts it because the audio session is active. The when-to-answer judgement is `AutoResumePolicy` (ShirKit, unit-tested); `YouTubePlayerEngine` wires it to WebKit and to the `AVAudioSession` observers that keep it from also answering iOS. Guarded by `BackgroundPlaybackTests` |
| Backgrounding, locking, or minimizing Now Playing kills the music on a **real phone** while the simulator plays on happily; the lock-screen card's clock keeps counting in silence | Two device-only enforcements the simulator skips. (1) The paused session drops WebKit's `MediaPlayback` RunningBoard assertion, so the device suspends WebKit's processes before the native pause→bridge→Swift→`evaluateJavaScript` replay arrives — the resume loses the race it always won in the simulator. (2) Dismissing the `fullScreenCover` unparents the web view, and `WKApplicationStateTrackingView` treats a nil window as *application did enter background* — the very same `EnteringBackground` interruption, app foreground or not. The advancing clock proves nothing: MediaRemote extrapolates from the last published rate and nothing publishes a correction after suspension | Replay in-page, synchronously, inside the `pause` event (`BackgroundPlay.js`), gated on a genuine visible→hidden transition within 2s in either race order — so lock-card presses, calls and AirPods pauses (no transition) still fall through to `AutoResumePolicy`, which knows who paused. Same shape Brave ships; unit-tested in `PlayerScriptsTests` |
| A track never starts — spinner or cued overlay forever | WebKit refuses to **start** media in a web view that is not genuinely visible, and every hiding trick fails a different way, all measured: never-parented → the page runs no media at all; 1pt host → the page won't build a player into a 1px viewport; near-transparent → treated as hidden; occluded behind opaque UI → bridge comes up, `play()` ignored; fully visible → works instantly | Starting a song presents Now Playing (`userPlaybackToken`), which mounts the stage visibly — the one posture that works. Don't burn a day re-testing invisible-host tricks; five probe variants are in the git history. In tests, `-autoplayVideoID <id> -autoOpenNowPlaying YES` reproduces a playing state deterministically |
| An audible dip every time Now Playing is dismissed to the mini player — device only | Dismissal unparented the web view, and `WKApplicationStateTrackingView` treats `window == nil` as "application did enter background": the same `EnteringBackground` pause as a home press, replayed a beat later | The web view never leaves the window: `OffstageYouTubePlayerHost` stays mounted (occluded) in `RootTabView`, and `WebViewAdoptingView` adopts only from `didMoveToWindow`, so every handover is window→window. The occluded host cannot *start* playback (measured; the Now Playing auto-open is that fix) — it exists so playback *continues* |
| Dragging Now Playing down exposes black instead of the library behind it | It was a `fullScreenCover`. A `.fullScreen` presentation removes the presenting view controller's view from the window once the transition settles — which is exactly why `.overFullScreen` exists as a separate style. Nothing about this is visible until something tries to see past the cover; measured with a temporary 200pt offset, which showed a black strip where the Favorites nav bar should have been | Present it as a layer in `RootTabView`'s `ZStack` instead. `@Environment(\.dismiss)` stops working there, so the chevron takes an explicit closure |
| Hiding the content behind a custom modal layer does nothing — VoiceOver still swipes into the library under the player | `.accessibilityHidden` attaches to the view's *own* element, and SwiftUI had flattened the tab bar's and mini player's children into the same container as the player, where they escape a modifier on their parent. Confirmed against a live `app.debugDescription` dump, not reasoned about | `.accessibilityElement(children: .contain)` then `.accessibilityAddTraits(.isModal)` on the covering layer — `isModal` is judged against *siblings*, which is the relationship that actually holds. It does not affect XCUITest, which enumerates the whole snapshot regardless of modality: a UI test that wants to know a covered control is unreachable must ask `isHittable`, never `exists` |
| Coming back from the lock screen or home pauses the video for about a second — and sometimes a "Session activation failed" alert appears | The app activated its own `.playback` `AVAudioSession` for YouTube playback. WKWebView audio actually plays through WebKit's helper-process session (non-mixable, attributed to the app, activated by WebKit itself on every play — `MediaSessionManagerInterface::sessionWillBeginPlayback`), so the app-side session was a *rival*: mediaserverd re-arbitrated on every foreground/unlock and bounced a begin/end interruption pair off WebKit's session. Confirmed live: "interruption began" lands ~17ms after `state playing` | The YouTube engine never activates the app session — it *releases* it on `load` (`releaseAppAudioSession`), so handing over from a local file cannot leave a rival up. Brave touches `AVAudioSession` nowhere for the same reason. `LocalAudioEngine` keeps its own activation — AVPlayer genuinely plays in-process |
| `.js` files missing at runtime | `.js` has no default build phase in Xcode | They live in ShirKit as SwiftPM resources — do not move them to the app target |
| UI test cannot find an icon-only control | No accessibility identifier; SF Symbol names are undocumented and have changed between releases | Add `.accessibilityIdentifier` |
| `typeText` silently dropped | SwiftUI focuses fields asynchronously | Gate on a UI change that only happens once text reached the binding. **Never sleep** |
| Retry types text twice ("benyaminbenyamin") | Retry gated on a slow-rendering button rather than on the field | Check the field is genuinely still empty |
| A UI test matching `"Search"` taps the wrong thing | The tab bar and the keyboard return key share that label | `field.typeText("\n")` |
| Tapping a search result opens Add To Playlist instead of playing | The row is a tap gesture, not a Button, so `resultRow-<id>` propagates down to the trailing `+` — and `app.buttons[…]` therefore resolves to the `+` | Aim at a `staticText` inside the row (the artist line), not at the row identifier |
| A section-header assertion never matches | iOS uppercases grouped-list headers | Assert on the nav bar or a row, not the header |
| `await` inside `XCTAssert…` will not compile | Assertions take autoclosures | Split into two statements |
| `move(fromOffsets:toOffset:)` is ambiguous | SwiftUI defines its own | ShirKit's is `moveElements` |
| `min`/`max` resolve wrongly in a `Collection` extension | They hit `Sequence`'s instance methods | Qualify: `Swift.min` |
| Nested `NavigationStack` leaves content unreachable | A pushed view owning its own stack | Pushed views must not create one |
| A `Button` inside a row swallows the row's tap | Default button style | `.buttonStyle(.plain)` |
| A lock-screen or Control Center pause un-pauses itself a beat later | The card's pause acts in-page (or in WebKit's C++), so `AutoResumePolicy` never learns it was requested — the following "paused" state looks unanswered-for and the auto-resume answers it. Captured live: four Control Center pauses, four auto-un-pauses | Remote presses route through `PlaybackCoordinator.handle(remoteCommand:)` → `youtubeEngine.pause()`, so `notePause()` runs before the state event arrives. Script messages deliver in order — the page posts `remote` before the player's async state event |
| No next/previous buttons on the lock-screen card for YouTube tracks | WebKit builds the card's button set from what the *page* registers, plus a play/pause fallback. `MPRemoteCommandCenter.nextTrackCommand` can never produce a next button for web media | `MediaSession.js` registers `nexttrack`/`previoustrack` (and nulls `seekforward`/`seekbackward`, which occupy the same two slots) and forwards presses over the bridge |

---

## 10. Conventions and principles

### How to work here

- **Use skills, every time.** Check for a relevant skill before any non-trivial
  task and invoke it — not a judgement call. `superpowers:brainstorming` before
  designing, `superpowers:writing-plans` before implementing,
  `superpowers:systematic-debugging` before guessing at a bug,
  `superpowers:verification-before-completion` before claiming something works.
  Process skills set the approach; implementation skills follow.
- **Gather context with subagents.** Before writing against an unfamiliar API or
  making an architectural call, dispatch agents to read the actual source and
  report exact signatures. Every significant decision here was made that way,
  and twice it reversed the answer.
- **Use context7 for library and API documentation**, including Apple's. This
  project depends on WebKit behaviour that changes between iOS releases.
- **Verify, don't assert.** This project has been wrong four times from
  reasoning instead of checking: the App Store legal position, whether WebKit can play
  audio backgrounded, whether the suggestion endpoint sends CORS headers, and
  whether tapping a song should save it. Each was settled by going and looking.
  Read the source, run the code, quote the file and line.
- **Say what is not built.** Mark planned work as planned. A doc that overstates
  reality costs more than no doc.

### How to design here

- **YAGNI.** Build what is needed now. This project has been saved real weeks
  twice: embedding Brave's Rust engine was 10–12 days to deliver a string
  constant we already had, and a Piped-style backend would have made us the
  operator of a service. When a feature is genuinely coming, leave a documented
  seam — not an abstraction with one implementation.
- **DRY, with a caveat.** One fact, one place. But two things that merely *look*
  alike are not duplication — `TrackCollectionView` was extracted because both
  playlist screens *are* the same screen, whereas the two engines stay separate
  because they only resemble each other from the outside.
- **No dead code, no commented-out code.** Git remembers. A deleted thing that
  mattered gets a note in the doc comment explaining why it went, like
  `applicationDidEnterBackground()`.
- **Fix the cause, not the symptom.** The web view crash was a gesture-graph
  conflict; the fix was making it a player instead of a browser. Reach one layer
  down before patching what you can see.

### Code

- Persistence is a whole-library JSON re-encode per mutation, behind
  `LibraryPersisting`. Fine at this size; past a few thousand tracks, revisit
  before optimising anything else.
- `PlaybackQueue` is a value type with no engine knowledge. Keep it that way —
  it is the part most likely to grow subtle bugs, and it is only cheap to test
  because it is pure.
- Injected JavaScript lives in `.js` resource files, never Swift string
  literals, so it stays diffable, lintable and testable.
- Colours come from `Theme`, sampled from reference screenshots rather than
  eyeballed. The accent `#E24D68` is one colour used everywhere.

---

## 11. Borrowed code and licences

Reference clones live in `../youtube-clons/` and are **read-only**. Mine them
for technique; check the licence before copying anything.

**This repo is public, so distribution obligations are live.** They were not
while it was one phone's sideload, and that changed the answer in one row
below: GPL-3.0 scriptlets can no longer be copied in on a personal-use
argument. What ships is recorded in `THIRD-PARTY-NOTICES.md`; anything adapted
must be added there as well as commented in place.

| Source | Licence | Reusable here? |
|---|---|---|
| `adblock-rust` (Brave engine) | MPL-2.0 | Yes — file-level copyleft |
| `brave-video-bg-play-update.js`, via `brave-resources.json` | MIT (from `mozilla/video-bg-play`) | **Yes** — the background-playback code to adapt |
| uBO scriptlets (`json-prune`, `set-constant`) | GPL-3.0 | **No** — copying one now relicenses this repo GPL-3.0. Study the behaviour, reimplement |
| NouTube | AGPL-3.0 | No — reimplement the idea |
| FreeTube | AGPL-3.0 | No |
| LibreTube | GPL-3.0 | No |

Record provenance in a comment whenever you adapt code from any of these,
and add the upstream notice to `THIRD-PARTY-NOTICES.md` in the same commit.

---

## 12. Known gaps and stale artefacts

**Not built:**

- **Lock-screen controls for YouTube tracks: implemented, device verdict
  pending.** The `cf5e582` approach (reverted on simulator evidence the commit
  itself called unanswerable there) is restored per the 2026-08-06 spec in
  `docs/superpowers/specs/`, with its one real bug corrected: a remote `.pause`
  now routes through `youtubeEngine.pause()` so `AutoResumePolicy` learns the
  pause was requested — the reverted code's lock-screen pause would have
  un-paused itself. The simulator gate passed ("MediaSession owned", playback
  intact); what only a locked physical device can answer — card, artwork, all
  four transports moving *Shir's* queue — is awaiting the next sideload test.
  Record the verdict here. Local files are unaffected: `LocalAudioEngine` gets
  lock-screen controls normally via `MPRemoteCommandCenter`.
- **Non-embeddable videos are not skipped.** The Data API's `videoEmbeddable`
  filter has no InnerTube equivalent, so such a video can reach the queue. The
  authoritative signal is IFrame error **101/150** at playback, which the engine
  already reports; auto-skipping on it is not implemented.
- **"Recently Played" mirrors "Recently Added".** There is no play-history
  store; it is honestly a duplicate rather than fake data.
- **Four Now Playing action buttons are inert** — plus, EQ, AirPlay and share
  are laid out but not wired.
- **No search pagination.** One page of results, roughly 20 items.
- **A sub-second audio dip at home press or lock is inherent.** WebKit
  force-pauses the session (`EnteringBackground`) and the in-page replay
  answers in the same event turn; what remains is the device's audio-pipeline
  restart. No API lifts the interruption (verified against WebKit main —
  the only exemptions are PiP, AirPlay, CarPlay), and Brave's implementation
  has the identical dip. The simulator restarts audio instantly, so it is
  inaudible there.

Two stale artefacts this section used to track are gone: `spike/` (the Phase 0
background-playback spike — answered its question) and
`docs/shir-architecture.html` (documented the pre-fork architecture). Both
deleted 2026-08-05; git remembers them.
