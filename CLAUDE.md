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
swift test --package-path ShirKit     # 90 unit tests, macOS, ~0.1s
./scripts/typecheck-ios.sh            # compile-only gate, seconds, no simulator

# 16 UI tests, ~4.5 min. BackgroundPlaybackTests needs the network. Use an explicit device id — several simulators share names.
xcodebuild -project Shir.xcodeproj -scheme Shir \
  -destination 'platform=iOS Simulator,id=<UDID>' test

./scripts/screenshots.sh              # regenerates screenshots/
./scripts/extract-brave-scriptlets.py --list    # harvest filter data from Brave
```

`Shir.xcodeproj` is **generated** and gitignored. Edit `project.yml`, never the
project file. Nothing else needs configuring — search takes no API key.

Deploying to a physical device needs a signing team set in Xcode. That step is
manual and interactive; an agent cannot do it.

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
│      ├── YouTubePlayerEngine   WKWebView + 4 injected scripts  │
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
simulator — 90 tests in about a tenth of a second. The app target holds only
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
| **ShirKit — YouTube** | |
| `YouTube/PlayerScripts.swift` | Loads the `.js` from the package bundle. One place that knows where they live |
| `YouTube/SuggestionClient.swift` | Autocomplete, over `HTTPFetching`. Native, not in a web view |
| `YouTube/YouTubeVideo.swift` | A search result, before it becomes a `Track` |
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
| `Features/Search/SearchView.swift` | Field, history, suggestions, results — four states |
| `Features/Search/SearchViewModel.swift` | Two debounces, two tasks |
| `Features/Player/NowPlayingView.swift` | Full-screen player. Mounts the engine's web view |
| `Features/Player/MiniPlayerBar.swift` | The bar above the tab bar |
| `Features/Components/Theme.swift` | Palette sampled from reference screenshots, not eyeballed |

---

## 4. The fork: this is a personal-device build

Shir targets **one physical iPhone, sideloaded**. Decided 2026-08-04. Both
positions are recorded because the trade matters more than the outcome.

**What the constraint used to be.** Until that date the app played YouTube
through the official IFrame Player, ads intact, pausing in the background. The
reasoning was sound *for a shipping product*: App Store Guideline 5.2.1 rejects
ad-stripping YouTube clients. Apple removed Musi in September 2024 after
complaints from IFPI, Sony, the NMPA and YouTube. Musi sued *Apple*, not the
other way round, and lost with prejudice in March 2026 — Judge Eumi Lee held
that Apple's developer agreement lets it delist any app "at any time, with or
without cause". Musi's law firm was sanctioned.

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
   `git show c7fc009:ShirKit/Sources/ShirKit/YouTube/YouTubeSearchClient.swift`
   has the whole implementation, tests included.

---

## 5. Playback

Two engines, one coordinator, one protocol. `PlaybackCoordinator.isActive(_:)`
drops events from whichever engine is not in charge, so a stopping engine's
final `.idle` cannot clobber the track just started on the other one.

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
9. **Unmute explicitly, on load and after every track change.** WebKit permits
   unattended autoplay only when the media is silent, so YouTube starts muted
   and waits for a tap on its own overlay. Nothing else will unmute it.
10. **Background audio needs all four:** `UIBackgroundModes: audio`, an active
    `.playback` `AVAudioSession`, the visibility overrides, and the engine's
    auto-resume. The first three keep the *page* willing to play; the fourth
    answers WebKit itself, which force-pauses video sessions on backgrounding
    regardless of everything the page believes (pitfalls index has the
    mechanism). Any one missing and playback stops at home press or lock.

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

1. **Tapping a song plays it and touches nothing else.**
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

90 unit tests (macOS, ~0.1s) and 16 UI tests (simulator, ~4.5 min; BackgroundPlaybackTests needs the network).

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
| Video plays but there is no sound | WebKit only allows unattended autoplay when muted; YouTube complies and waits for a tap | Unmute explicitly on load and after each track change |
| Ads replaced by a 4–16s spinner | SABR `backoffTimeMs` still covers the removed ad slot | Port `brave-yt-sabr-fix.js` |
| First song of a session plays an ad | `ytInitialData` is server-rendered and never passes through `fetch`/`XHR` | Intercept with `Object.defineProperty` |
| Playback stops roughly half an hour in | `window._lact` went stale | Refresh it every 5 min |
| The video is correctly 16:9 but barely half the screen wide | `.aspectRatio(_:contentMode: .fit)` inside a `VStack`. A stack proposes each child a *share* of the leftover height, and `.fit` inscribes the ratio in whatever it is offered — so a short proposal shrinks the **width**. Measured: 120pt offered → 213pt wide, 54% | Give the stage a definite width, then derive the height (`NowPlayingView.stage(width:)`). `.layoutPriority` measurably does nothing — Spacers already go last, so there is no height left to win. `.frame(maxWidth: .infinity)` after it widens the frame, not the child |
| A black band across the top of the video, same amount lost off the bottom | `.player-container` is `top: 48px` to clear the mobile header — which `PlayerSurface.js` hides, so nothing reclaims the space | `top: 0 !important`. Hiding an element does not collapse an offset reserved for it |
| Music blasts out of the phone speaker when AirPods disconnect | The auto-resume answered a pause it should have respected. "The app did not ask for this pause" is not enough to justify resuming — iOS pauses for calls, Siri, other apps and unplugged headphones, and every one of those means it | `AutoResumePolicy` is told *who* paused: `AVAudioSession` interruption and route-change observers in `YouTubePlayerEngine`. Only WebKit's backgrounding pause gets answered |
| YouTube never plays again until the app is killed | One failed or redirected first navigation. `hasLoadedDocument` latched before the load was known to succeed, so every later track ran `loadVideoById` against a document that never existed and queued behind a bridge that could never be ready | `resetForRetry()` on `didFailProvisionalNavigation`, and clear `appInitiatedNavigation` on **commit** rather than first use, so a consent/region redirect is not cancelled |
| Tapping the scrubber restarts the song | `onEditingChanged(true)` flips the binding's `get` to `scrubPosition` before the slider ever calls `set`, and a touch that never drags never calls it — so release seeks to a stale value, 0 on first use | Seed `scrubPosition` from the live position when editing begins |
| Audio stops the instant the app is backgrounded | WebKit force-pauses every video session on backgrounding (`BackgroundProcessPlaybackRestricted`). It is C++ app state: no injected visibility override reaches it, and it fires whether or not the web view is mounted. `UIBackgroundModes: audio` does **not** exempt a `<video>` | Answer the unasked-for pause with an immediate `play()` — WebKit accepts it because the audio session is active. The when-to-answer judgement is `AutoResumePolicy` (ShirKit, unit-tested); `YouTubePlayerEngine` wires it to WebKit and to the `AVAudioSession` observers that keep it from also answering iOS. Guarded by `BackgroundPlaybackTests` |
| A track never starts, spinner forever — but only when driven by automation | Playback can only *start* with Now Playing open. The video begins muted, and WebKit suspends silent elements in a hidden page before the 900ms unmute; the cover is the web view's only mount. Manual use always opens the cover, so only automation ever hits this | Launch with `-autoplayVideoID <id> -autoOpenNowPlaying YES` — the seams exist for exactly this. Do **not** conclude "the Simulator can't play YouTube"; it can |
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
  reasoning instead of checking: the Musi legal history, whether WebKit can play
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

| Source | Licence | Reusable here? |
|---|---|---|
| `adblock-rust` (Brave engine) | MPL-2.0 | Yes — file-level copyleft |
| `brave-video-bg-play-update.js`, via `brave-resources.json` | MIT (from `mozilla/video-bg-play`) | **Yes** — the background-playback code to adapt |
| uBO scriptlets (`json-prune`, `set-constant`) | GPL-3.0 | Personal use only; no distribution means no obligation triggered |
| NouTube | AGPL-3.0 | No — reimplement the idea |
| FreeTube | AGPL-3.0 | No |
| LibreTube | GPL-3.0 | No |

Record provenance in a comment whenever you adapt code from any of these.

---

## 12. Known gaps and stale artefacts

**Not built:**

- **Lock-screen Now Playing controls for YouTube tracks.** Attempted in
  `53cdda6` and reverted in `69a3e3f`; the revert records no reason, so treat
  the approach as unproven rather than rejected. That commit message contains a
  detailed mechanism analysis — WebKit writing MediaRemote from the WebContent
  process, and the lock screen's button set being derived from what the *page*
  registers — which is worth reading before trying again. Local files are
  unaffected: `LocalAudioEngine` gets lock-screen controls normally.
- **Non-embeddable videos are not skipped.** The Data API's `videoEmbeddable`
  filter has no InnerTube equivalent, so such a video can reach the queue. The
  authoritative signal is IFrame error **101/150** at playback, which the engine
  already reports; auto-skipping on it is not implemented.
- **No discovery/browse landing page.** The Search tab shows a prompt on a fresh
  install rather than curated content.
- **"Recently Played" mirrors "Recently Added".** There is no play-history
  store; it is honestly a duplicate rather than fake data.
- **Four Now Playing action buttons are inert** — plus, EQ, AirPlay and share
  are laid out but not wired.
- **No search pagination.** One page of results, roughly 20 items.

Two stale artefacts this section used to track are gone: `spike/` (the Phase 0
background-playback spike — answered its question) and
`docs/shir-architecture.html` (documented the pre-fork architecture). Both
deleted 2026-08-05; git remembers them.
