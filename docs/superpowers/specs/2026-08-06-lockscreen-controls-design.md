# Lock-screen controls for YouTube tracks — design

2026-08-06. Restores and corrects the reverted attempt `53cdda6` (revert
`69a3e3f`). The revert was made after checking the **simulator** lock screen —
the one signal the original commit itself said could not answer the question.
The approach was never disproven where it counts: a locked physical device.

## Goal

The lock screen and Control Center show play/pause/next/previous (plus track
metadata, artwork and a live scrubber) for YouTube tracks, and the buttons
drive **Shir's queue** — not YouTube's autoplay. Local files already work
through `MPRemoteCommandCenter` and must not be disturbed.

## Verified mechanism (why the design has this shape)

Every claim below was checked against primary sources this session, not
recalled. WebKit line numbers are from `main` on 2026-08-06 and will drift.

1. **The host app cannot own the card while web media plays.** WebKit's GPU
   process (not WebContent — a correction to `53cdda6`'s analysis) publishes
   Now Playing info straight into MediaRemote with
   `MRMediaRemoteSetNowPlayingInfoWithMergePolicy(info, MRMediaRemoteMergePolicyReplace)`
   on a self-re-arming ~5s timer, attributed to the host app via
   `MRMediaRemoteSetParentApplication`
   (`Source/WebCore/platform/audio/cocoa/MediaSessionManagerCocoa.mm`,
   `setNowPlayingInfo` ~501, timer ~97/~698;
   `Source/WebKit/WebProcess/GPU/media/WebMediaStrategy.cpp` ~118).
   Anything Shir writes through `MPNowPlayingInfoCenter` competes with that
   republish loop. So the page's media session is the only reliable lever.

2. **Buttons exist iff the page registers them.** The chain is provable in
   source, hop by hop: `navigator.mediaSession.setActionHandler('nexttrack')`
   → `sessionManager->addSupportedCommand(NextTrackCommand)`
   (`Modules/mediasession/MediaSession.cpp` ~80–93, ~315) → NowPlayingManager
   → GPU-process IPC (`RemoteRemoteCommandListener.cpp` ~89) →
   `RemoteCommandListenerCocoa.mm`: registered set =
   `supportedCommands().unionWith(minimalCommands())` where minimal is
   {play, pause}; with **no** page registrations a default set (play, pause,
   toggle, seek) applies. Next/previous are in neither fallback. That is why
   `MPRemoteCommandCenter.nextTrackCommand` can never produce a next button
   for web media, and why today's card shows no track buttons.

3. **Gate:** a page's registered commands reach the OS only while its web
   process is the *active now-playing process*
   (`GPUConnectionToWebProcess.cpp` ~828: early-return unless
   `m_isActiveNowPlayingProcess`). The player web view is the process playing
   audio, so it qualifies; the hidden search web view never plays and cannot
   steal the card.

4. **Artwork works.** `MediaMetadata` artwork is fetched in-page, scored,
   shipped as image bytes over IPC once per URL, and lands in
   `kMRMediaRemoteNowPlayingInfoArtworkData` with no iOS-version gate
   (`MediaMetadata.cpp` ~70; `MediaSessionManagerCocoa.mm` ~476).

5. **Card visibility is automatic:** WebKit sets the entry visible exactly
   when the page is not visible-and-active (`MediaElementSession.cpp` ~1543)
   — i.e. when the phone is locked or the app backgrounded.

6. **YouTube IFrame API idempotency is NOT documented.** The docs are silent
   on redundant `playVideo()`/`pauseVideo()` calls. What they do guarantee is
   the **outcome**: "The final player state after this function executes will
   be paused (2)" (resp. playing). The design depends only on the outcome
   guarantee plus event-order safety (below), never on no-op-ness.
   Documented hazard: `seekTo()` from a non-paused, non-playing state (e.g.
   `video cued`) starts playback.

## Architecture

```
Lock screen press
  → WebKit fires the page's registered mediaSession action handler
     → MediaSession.js acts in-page where sensible (latency) and posts
       {kind: "remote", action: ...} through the existing "shir" handler
        → YouTubePlayerEngine.onRemoteCommand
           → PlaybackCoordinator routes through its NORMAL control methods
```

Metadata flows the opposite way: `pushNowPlayingMetadata()` on every `load()`
and on bridge `ready` writes Shir's own title/artist/artwork into the page's
(locked) `navigator.mediaSession.metadata`.

## Components

| Piece | Status vs `53cdda6` |
|---|---|
| `ShirKit/Resources/Scripts/MediaSession.js` | Restored as-is. Injected **first** in `PlayerScripts.player` so it captures the pristine `MediaSession` prototype at document start. Owns `setActionHandler` and `metadata` with `configurable:false` accessors that swallow page writes; nulls `seekforward`/`seekbackward` (they occupy the same two lock-screen slots as previous/next); registers `nexttrack`, `previoustrack`, `play`, `pause`, `seekto`; pushes position state on element events + 5s heartbeat; exposes `window.__shirMedia` (setMetadata / install / probe) |
| `RemoteCommand` enum (`PlaybackEngine.swift`) | Restored: `.play .pause .next .previous .seek(TimeInterval)`. Sits beside `EngineState` (~line 12). Not part of the `PlaybackEngine` protocol — `LocalAudioEngine`'s remote path is `MPRemoteCommandCenter` and works; a no-op property would fake a symmetry that does not exist |
| `YouTubePlayerEngine` | Restored, rebased: `onRemoteCommand` closure, `loadedTrack`, `pushNowPlayingMetadata()` (called in `load()` after the `run(...)` and in the `"ready"` case before `flushPendingCommands()`), `jsString` via `JSONEncoder` (a newline or U+2028 in a YouTube title must not silently kill the push), a `"remote"` case in the message switch. The 900ms `scheduleUnmute()` the old diff sat beside no longer exists |
| `PlaybackCoordinator` | **Corrected.** `youtube.onRemoteCommand` wired in `init` beside `wire()` calls. Routing: `.next → next()`, `.previous → previous()`, `.play → youtubeEngine.play()`, `.pause → youtubeEngine.pause()`, `.seek(t) → seek(to: t)`. **No status writes in the handler at all** — status flows through the existing state pipeline (page changes state → Bridge reports → `handle(state:from:)`). One control path for UI and lock screen alike. The existing `configureRemoteCommands()` / `updateNowPlayingInfo()` block stays untouched — it is the local-engine path |
| `MediaSessionScriptTests` | Restored 9 JSContext tests. The `context(loading:shims:)` harness and base shims move from `PlayerScriptsTests`-private to a shared test-support file so two suites don't grow two shim stacks; MediaSession tests add `navigator.mediaSession` / `MediaMetadata` shims following the `bridgeShims` pattern |

## The remote-pause correction (why `53cdda6` needed changing)

The reverted code handled a remote `.pause` by writing `status = .paused`
directly. But the page's action handler pauses the video in-page, so
`AutoResumePolicy` — which arms on `engine.pause()` — never learns the pause
was requested. Bridge.js then reports `"paused"`, the engine sees an
unrequested pause, and auto-resumes: **a lock-screen pause would un-pause
itself ~300ms later.** (The auto-resume machinery predates `53cdda6`; the
interaction was missed.)

Fix: route `.pause` through `youtubeEngine.pause()`. Ordering makes this
safe without relying on undocumented no-op behavior: the page posts the
`remote` message *before* the player's async state event can arrive, and
script messages deliver in order — so `notePause()` runs first, and the
later `"paused"` state finds `wantsPlayback == false`. The redundant
in-page `pauseVideo()` is covered by the documented outcome guarantee
(final state: paused). Symmetrically for `.play`.

## Error handling

Unchanged from `53cdda6`, because it was right: the locks swallow rather
than throw (YouTube's strict-mode bundle must never take a player-init
exception — a blank card beats broken playback); metadata pushes fail
silently but are visible in `__shirMedia.probe()`; every failure path
degrades to "worse lock screen", never "no music".

## Verification — three gates, in order

1. **JSContext tests** (macOS, ms): the 9 restored adversarial tests — the
   page cannot replace an owned handler, cannot put an advertiser on the
   card, its rejected writes do not throw, presses post the right messages.
2. **Simulator diagnostic** — proves *install*, deliberately not buttons:
   autoplay launch, capture via probe log: `MediaSession owned`,
   `probe()` JSON showing `hasMetadata: true` with Shir's title, playback
   state transitions. Then lock the simulator and screenshot: buttons
   rendering is a bonus; their absence is **not a verdict** — that mistake
   is what killed `53cdda6`.
3. **Physical device** — the only real gate, explicitly deferred to the
   user's next sideload: play a YouTube track, lock, check card + artwork +
   all four transports, press each, confirm next/previous move **Shir's**
   queue. Outcome — pass or fail — gets recorded in CLAUDE.md §12.

## Documentation

CLAUDE.md: §12 gap rewritten (restored + corrected, device verdict pending);
§9 rows for "lock-screen pause un-pauses itself" (cause: page-local pause is
invisible to `AutoResumePolicy`) and "no track buttons on the lock screen"
(cause: next/previous exist only if the page registers them); file-map row
for `MediaSession.js`; §5 note that the lock screen is part of the injected-
scripts surface.

## Out of scope

- Lock-screen controls for local files (already work; untouched).
- `skipad` action, `nextslide`, playlist UI on the card.
- Any change to search, trending, or the second web view (it never plays,
  so it cannot become the active now-playing process — verified, claim 3).
