# CLAUDE.md — Riff

A Musi-style iPhone music app: playlists, a queue, and two playback sources.

**New here? Read §1, §3 and §9.** That is the shape of the app, where the code
lives, and the traps that already cost someone a day. Everything else is
reference you can come back to.

---

## 1. Orientation

Riff plays music from two places and treats them as one library:

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
swift test --package-path RiffKit     # 83 unit tests, macOS, ~0.1s
./scripts/typecheck-ios.sh            # compile-only gate, seconds, no simulator

# 14 UI tests, ~2.5 min. Use an explicit device id — several simulators share names.
xcodebuild -project Riff.xcodeproj -scheme Riff \
  -destination 'platform=iOS Simulator,id=<UDID>' test

./scripts/screenshots.sh              # regenerates screenshots/
./scripts/extract-brave-scriptlets.py --list    # harvest filter data from Brave
```

`Riff.xcodeproj` is **generated** and gitignored. Edit `project.yml`, never the
project file. Nothing else needs configuring — search takes no API key.

Deploying to a physical device needs a signing team set in Xcode. That step is
manual and interactive; an agent cannot do it.

---

## 3. Architecture

```
┌─ Riff (iOS app target) ────────────────────────────────────────┐
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
┌─ RiffKit (SwiftPM package) ────────────────────────────────────┐
│  Models · LibraryStore · PlaybackQueue · SearchHistory         │
│  SuggestionClient · Resources/Scripts/*.js                     │
│  No UIKit, no SwiftUI, no WebKit → tests run on macOS          │
└────────────────────────────────────────────────────────────────┘
```

### The layering rule

**Anything with real logic goes in `RiffKit` with a unit test.** RiffKit imports
no UI framework, so its tests run on macOS in milliseconds instead of booting a
simulator — 83 tests in about a tenth of a second. The app target holds only
what genuinely needs UIKit, WebKit or AVFoundation.

`JavaScriptCore` is **not** a UI framework, which is why the injected scripts
live in RiffKit and are unit-tested there. That is the highest-value test suite
in the project (§8).

### File map

| File | Purpose |
|---|---|
| **RiffKit — models** | |
| `Models/Track.swift` | The unit of music. `id` is derived: `yt:<videoID>` / `file:<name>` |
| `Models/MediaSource.swift` | The `.youtube` / `.localFile` fork that decides engine and behaviour |
| `Models/Playlist.swift` | `Playlist` + `Library`. **`Library` decodes tolerantly — keep it that way (§9)** |
| **RiffKit — state** | |
| `Library/LibraryStore.swift` | `@Observable` store. Catalogue, playlists, favorites. Persists on every mutation |
| `Library/LibraryPersistence.swift` | Whole-library JSON behind a protocol, plus an in-memory double |
| `Search/SearchHistory.swift` | Recent queries. **Its own file, never a field on `Library` (§9)** |
| `Playback/PlaybackQueue.swift` | Pure value type. Cursor, shuffle, repeat. No engine knowledge |
| **RiffKit — YouTube** | |
| `YouTube/PlayerScripts.swift` | Loads the `.js` from the package bundle. One place that knows where they live |
| `YouTube/SuggestionClient.swift` | Autocomplete, over `HTTPFetching`. Native, not in a web view |
| `YouTube/YouTubeVideo.swift` | A search result, before it becomes a `Track` |
| `Resources/Scripts/AdStrip.js` | Deletes ad inventory before the player parses it |
| `Resources/Scripts/BackgroundPlay.js` | Keeps audio alive with the screen off |
| `Resources/Scripts/PlayerSurface.js` | Hides YouTube's chrome |
| `Resources/Scripts/Bridge.js` | Player commands in, state and progress out |
| `Resources/Scripts/Search.js` | Keyless InnerTube search, run inside the page |
| `Resources/Scripts/MediaSession.js` | Owns `navigator.mediaSession`, so the lock screen is Riff's (§5) |
| **App — playback** | |
| `Playback/PlaybackEngine.swift` | The protocol both engines satisfy: 3 closures, 5 methods, plus `RemoteCommand` |
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

Riff targets **one physical iPhone, sideloaded**. Decided 2026-08-04. Both
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
   `git show c7fc009:RiffKit/Sources/RiffKit/YouTube/YouTubeSearchClient.swift`
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
10. **Background audio needs all three:** `UIBackgroundModes: audio`, an active
    `.playback` `AVAudioSession`, and the visibility overrides. Any one missing
    and playback stops at lock.

### The lock screen belongs to WebKit, not to this app

**`MPNowPlayingInfoCenter` and `MPRemoteCommandCenter` do nothing for a YouTube
track.** Not "less", *nothing*. Both are still wired for local files, where they
work normally, so the code being present is not evidence it runs.

Two mechanisms, both read out of WebKit's source rather than guessed:

1. **WebKit publishes web media itself.** `MediaSessionManagerCocoa::setNowPlayingInfo`
   calls MediaRemote directly from the WebContent process, with
   `MRMediaRemoteMergePolicyReplace`, and re-arms on a ~5s timer. It even
   attributes itself to this bundle via `MRMediaRemoteSetParentApplication`. So
   it presents *as Riff* while overwriting anything Riff sets.
2. **The page decides which buttons exist.** `RemoteCommandListenerCocoa` builds
   the set as `supportedCommands() ∪ {play, pause}`, and the only route into
   `supportedCommands()` is the page calling
   `navigator.mediaSession.setActionHandler`. **NextTrack and PreviousTrack are
   in no default set.** A next button exists if and only if the page registers
   `nexttrack`. That sentence is the whole feature.

So `MediaSession.js` takes `navigator.mediaSession` away from YouTube at
document-start and forwards presses to Swift as `{kind: "remote", action: …}`,
which `PlaybackCoordinator` turns into *Riff's* queue advancing rather than
YouTube's autoplay. Details that look arbitrary and are not:

- **`seekforward`/`seekbackward` are nulled deliberately.** Skip-15s occupies the
  same two lock-screen slots as previous/next, so leaving them registered means
  no track buttons appear at all.
- **The lock swallows rather than throws.** YouTube's bundle is strict mode; a
  throw during player init risks killing playback. A blank card beats no music.
- **Metadata goes through `JSONEncoder`, not `escape(_:)`.** The latter handles
  quotes and backslashes only — fine for an 11-character video id, nowhere near
  enough for a real title, where a newline or U+2028 is a silent syntax error.
- **The web view must be in a window.** WebKit only treats a page as visible if
  its `WKWebView` has one, and `NowPlayingView` is a `fullScreenCover` — so the
  player used to have no window at all whenever that screen was closed, which is
  most of the time. `RootTabView.playerKeepAlive` holds a one-point mount for
  exactly this. An ineligible session has its card cleared *without its audio
  being paused*, which is why the symptom was "music plays, lock screen empty".

**Verified on iOS 26.3, not assumed:** WebKit's `RequirePageVisibilityForVideoToBeNowPlaying`
restriction — which would make a `<video>` ineligible whenever its page is
hidden, and which nothing in the page can clear — is **compiled out** of the
shipping build. `YouTubePlayerEngine.allowNowPlayingWhileHidden` probes for it by
writing `true` and reading it back (`responds(to:)` cannot tell a live setting
from a stub, because the accessors exist either way) and disables it if a future
iOS turns it on.

To confirm behaviour on a device, stream both subsystems while locking the phone:

```bash
log stream --device-name "<iPhone>" --style compact \
  --predicate 'subsystem == "com.shirhussain.riff" OR (subsystem == "com.apple.WebKit" AND category == "Media")'
```

`MediaSession::setActionHandler … adding nexttrack` means the handlers landed.
`clearing now playing info` at lock means the session went ineligible.
`title = …` every ~5s means WebKit is publishing and the problem is elsewhere.
`INFO_LOG` lines are unreachable on a device build — do not grep for them.

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
  sending it. Riff sends none.
- **Search needs no bot attestation.** PoToken and BotGuard gate
  `/youtubei/v1/player`, not `/youtubei/v1/search`. yt-dlp's source defines PO
  token policies for streams, player and subtitles and has *no* search policy.
  That split is why this works while stream extraction does not — and why Riff
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

83 unit tests (macOS, ~0.1s) and 14 UI tests (simulator, ~2.5 min).

**Anything with real logic belongs in RiffKit with a unit test.** The UI tests
exist only for what unit tests structurally cannot see: navigation, persistence
reaching the screen, and each screen's empty and error states.

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
| Music plays with the screen locked but there is no Now Playing card | The web view has no window, so WebKit does not treat the page as visible and clears the card — without pausing the audio | Keep it mounted; `RootTabView.playerKeepAlive` |
| Lock screen has play/pause but no next or previous | WebKit's default command set has neither, and `MPRemoteCommandCenter` cannot add them for web media | The *page* must register `nexttrack` — `MediaSession.js` |
| Registering `nexttrack` still shows no track buttons | `seekforward`/`seekbackward` occupy the same two slots | Null them explicitly |
| The lock screen shows an advertiser's name | YouTube sets its own `mediaSession.metadata` during a pre-roll | Lock `metadata` with `configurable: false` at document-start |
| An SPI check passes but the setting does nothing | WebKit declares the accessors unconditionally and compiles the bodies out, so `responds(to:)` answers YES for a stub | Write a value and read it back |
| First song of a session plays an ad | `ytInitialData` is server-rendered and never passes through `fetch`/`XHR` | Intercept with `Object.defineProperty` |
| Playback stops roughly half an hour in | `window._lact` went stale | Refresh it every 5 min |
| `.js` files missing at runtime | `.js` has no default build phase in Xcode | They live in RiffKit as SwiftPM resources — do not move them to the app target |
| UI test cannot find an icon-only control | No accessibility identifier; SF Symbol names are undocumented and have changed between releases | Add `.accessibilityIdentifier` |
| `typeText` silently dropped | SwiftUI focuses fields asynchronously | Gate on a UI change that only happens once text reached the binding. **Never sleep** |
| Retry types text twice ("benyaminbenyamin") | Retry gated on a slow-rendering button rather than on the field | Check the field is genuinely still empty |
| A UI test matching `"Search"` taps the wrong thing | The tab bar and the keyboard return key share that label | `field.typeText("\n")` |
| A section-header assertion never matches | iOS uppercases grouped-list headers | Assert on the nav bar or a row, not the header |
| `await` inside `XCTAssert…` will not compile | Assertions take autoclosures | Split into two statements |
| `move(fromOffsets:toOffset:)` is ambiguous | SwiftUI defines its own | RiffKit's is `moveElements` |
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

**Built but not confirmed on a device:**

- **Lock-screen controls for YouTube tracks.** Built (§5), reverted once, and
  restored. What is *verified*, from the simulator's WebKit log rather than by
  reasoning: the handlers reach WebKit (`MediaSession::setActionHandler … adding
  nexttrack`), `seekforward`/`seekbackward` stay unregistered, and the
  page-visibility restriction is compiled out of iOS 26.3. What is **not**
  verified is the only thing that matters to a user — that the card appears on a
  locked phone. **The simulator cannot answer that**, which is the most likely
  reason `53cdda6` was reverted 31 minutes after it was committed. Use the `log
  stream` predicate in §5 on the physical device, not a simulator screenshot.

**Not built:**

- **Non-embeddable videos are not skipped.** The Data API's `videoEmbeddable`
  filter has no InnerTube equivalent, so such a video can reach the queue. The
  authoritative signal is IFrame error **101/150** at playback, which the engine
  already reports; auto-skipping on it is not implemented.
- **No discovery/browse landing page.** The Search tab shows a prompt on a fresh
  install rather than curated content.
- **"Recently Played" mirrors "Recently Added".** There is no play-history
  store; it is honestly a duplicate rather than fake data.
- **Three Now Playing action buttons are inert** — EQ, AirPlay and share are
  laid out but not wired.
- **No search pagination.** One page of results, roughly 20 items.

**Stale:**

- `docs/riff-architecture.html` documents the **pre-fork** architecture — IFrame
  embed, player always visible, YouTube pausing in background. Regenerate it or
  delete it; do not trust it.
- `spike/` is the Phase 0 background-playback spike. It answered its question
  and is safe to delete; nothing in Riff imports from it.
