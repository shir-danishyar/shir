# Ad-free YouTube playback in Shir — design

**Date:** 2026-08-04
**Status:** agreed, not yet implemented
**Supersedes:** the IFrame-embed constraint documented in `CLAUDE.md` before this date

## 1. What we're building and why

Shir plays YouTube through the official IFrame Player today: ads intact, player visible,
playback pausing when the app backgrounds. That was the correct design for an App Store
product and it is the wrong design for the actual requirement, which is a music app on one
personal iPhone.

This spec changes the YouTube playback layer so that:

- YouTube tracks play without ads
- Audio continues with the screen off and across track changes
- Shir's own playlists and queue drive playback, not YouTube's

`ShirKit` does not change. The domain layer — library, playlists, `PlaybackQueue`,
persistence, 51 passing tests — was built without knowledge of where audio comes from, and
that pays off here.

### Non-goals

- App Store distribution. Explicitly abandoned; see `CLAUDE.md` §2 for the revert path.
- Stream extraction (InnerTube + PoToken + `AVPlayer`). This is what Musi did and what
  FreeTube and LibreTube do. It requires executing Google's BotGuard interpreter *and*
  YouTube's own cipher JavaScript — two remote-code-execution dependencies, and the DMCA
  §1201 surface the NMPA alleged against Musi. Out of scope unless Phase 0 fails and we
  consciously revisit.
- General web ad blocking. A `WKContentRuleList` compiled from EasyList would block
  trackers and banners. It buys page weight and privacy, not silence. Deferred; §5 keeps
  the seam clean.
- Blocking ads anywhere except the YouTube player. Feed and Shorts ad surfaces are not
  part of a music app's job.

## 2. Why not embed adblock-rust

Brave's engine is in `../youtube-clons/adblock-rust` and does support iOS — but the support
converts filter rules into Safari content-blocking JSON, and that format **cannot express
`+js(...)` scriptlets** (`CbRuleCreationFailure::ScriptletInjectionsNotSupported`,
`src/content_blocking.rs`). 76 of Brave's 238 YouTube rules are scriptlets, and they are
exactly the ones that kill video ads. The iOS conversion path drops all of them.

The engine's runtime cosmetic API (`Engine::url_cosmetic_resources`) *does* return
executable JavaScript — roughly 46 KB for `m.youtube.com`, arguments baked in. But
embedding it requires:

- rustup (not installed; Homebrew's Rust is 1.87, the crate needs 1.88+ and pins 1.97)
- three iOS target stdlibs (the sysroot has only `aarch64-apple-darwin`)
- a hand-written C ABI — the crate contains no `extern "C"`, no `#[no_mangle]`, no cbindgen
- xcframework packaging
- a `.dat` cache whose format version upstream reserves the right to break on a patch bump

Estimated 10–12 engineer-days to deliver JavaScript that resolves to four key names we
already have. **Decision: build-time data source, not runtime dependency.**
`scripts/extract-brave-scriptlets.py` does the extraction in seconds with no toolchain.

## 3. Phase 0 — the spike (do this first)

A throwaway target. Not in the Shir tree, deleted when done. One view, a `WKWebView` on
`m.youtube.com`, two hardcoded video IDs, a play button.

It exists to answer one question before we spend weeks: **does audio survive a programmatic
track change while the phone is locked?**

### Pass criteria, ordered by risk

| # | Criterion | Why it's the risk it is |
|---|---|---|
| 1 | Audio continues into track 2 after a programmatic track change with the screen locked | iOS restricts starting new media while backgrounded. Brave has open bugs where playlist background playback dies after a few songs. **If this fails, stop and reconsider.** |
| 2 | Audio survives 60s+ after lock on a single track | Known-good — Brave ships it |
| 3 | A video with a known pre-roll plays with no ad and no spinner | Validates both ad-strip and SABR backoff handling |
| 4 | Lock screen shows title and transport controls | `MPNowPlayingInfoCenter` wiring |

### The specific unknown behind #1

On `m.youtube.com` the player is `#movie_player`, exposing `loadVideoById`, `playVideo`,
`pauseVideo`, `seekTo`, `getCurrentTime`, `getDuration`. Because we are first-party we can
call these directly via `evaluateJavaScript` rather than `postMessage`.

What is unverified: whether `loadVideoById` swaps the video *without* an SPA navigation. If
it triggers a document load, the audio session likely dies with it. If that happens,
fall back to driving YouTube's own playlist via `nextVideo()` and reconciling Shir's queue
to it — worse, but survivable.

There is reason for cautious optimism: Brave delegates ordering to YouTube's playlist page,
so every transition is a navigation. Shir owns the queue, so a transition is one call into
an already-live player with an already-active audio session. That is a materially easier
problem — but it is not proven.

## 4. Architecture

### What changes

Exactly one component's internals: `Shir/Playback/YouTubePlayerEngine.swift`. It stops
embedding the cross-origin IFrame and loads `m.youtube.com` as a first-party document.

`PlaybackEngine`, `PlaybackCoordinator`, `MediaSource`, `PlaybackQueue`, `LocalAudioEngine`,
and every `ShirKit` type are untouched. Local file playback is unaffected.

### Why the IFrame must go

It is cross-origin. No injected script can reach inside it — same-origin policy, not a
configuration problem. NouTube's author hit this and documented it at
`content/mini-player.ts:349-350`: inside the embed, ad stripping does not apply and
playback rate caps at 2. First-party document control is what makes injection possible.

### The injected scripts

Four `.js` resource files, not Swift string literals — diffable, lintable, testable.

| File | Responsibility | Provenance |
|---|---|---|
| `AdStrip.js` | Patch `fetch` + `XHR`, intercept `/youtubei/v1/*`, delete the four ad keys | Hand-written |
| `BackgroundPlay.js` | Visibility overrides, `_lact` refresh, activity simulation | Adapted from `brave-video-bg-play-update.js` (MIT) |
| `SabrBackoff.js` | Rewrite `backoffTimeMs` so blocked ads don't become spinners | Ported from `brave-yt-sabr-fix.js` |
| `Bridge.js` | Player commands in, state events out via `WKScriptMessageHandler` | Hand-written |

All four inject at `.atDocumentStart`, `forMainFrameOnly: false`, into
**`WKContentWorld.page`**.

The ad-key list lives in `AdStrip.js` and is never mirrored into Swift.

### Injection rules that are not negotiable

1. **`WKContentWorld.page`, not `.defaultClient`.** Everything here patches page globals.
   A main-world script placed in an isolated world runs, reports success, and does nothing.
   Verified against Brave's `ScriptFactory.swift`, `case .engineScript`.
2. **`.atDocumentStart`.** The patch must be installed before YouTube's bundle captures its
   own `fetch` reference. Brave's bug #6241 was exactly this — "engine scripts inject too
   late."
3. **Frame guard.** `WKUserScript` cannot target a subframe; it is all-frames or
   main-frame-only. Guard on frame origin inside the script or it runs in every iframe.
4. **`scriptletGlobals`** must be declared if any uBO scriptlet body is used, or
   `safeSelf()` throws and the try/catch swallows it into a silent no-op.

### Ad-strip specifics

Delete `adPlacements`, `playerAds`, `adSlots`, `adBreakHeartbeatParams`.

Three cases a naive implementation misses, each a real shipped bug fix in NouTube:

- `ytInitialData` arrives server-rendered in a `<script>` tag and never passes through
  `fetch` or `XHR`. Intercept with `Object.defineProperty`.
- `get_watch` nests the payload at `data[0].playerResponse`.
- The endpoint regex must cover `browse|get_watch|next|player|search`.

### Background playback specifics

- Override `Document.prototype.hidden` → `false`, `visibilityState` → `'visible'`,
  `onvisibilitychange` → no-op setter.
- **Do not block `visibilitychange` on iOS.** Brave explicitly skips this on iOS because it
  conflicts with media backgrounding.
- Refresh `window._lact` every 5 minutes.
- Dispatch synthetic `mousemove` on `#movie_player` every 10 minutes.
- Re-dispatch `timeupdate` every 60s.
- `AVAudioSession` category `.playback`, active. The `audio` background mode is already
  declared in `project.yml` for local files.

## 5. Extension seam for network-level blocking

If general ad blocking is wanted later, the shape is a `ContentBlocking` service that vends
a compiled `WKContentRuleList` to `YouTubePlayerEngine`'s `WKWebViewConfiguration`. Rules
would be generated offline from EasyList and shipped as a JSON resource — no Rust in the
app. Nothing in this design forecloses that; it is additive.

WebKit caps a rule list at 150,000 rules, hardcoded. Brave ships only a trimmed "Slim List"
on iOS for this reason.

## 6. Testing

### The important one

`AdStrip.js` is a pure function — JSON in, JSON out. Test it in `ShirKit` by loading the
script into a `JSContext`, feeding a captured real player-response fixture, and asserting
the four keys are gone and video data is intact.

`JavaScriptCore` is not a UI framework, so this does not violate ShirKit's no-UI-imports
rule. It runs on macOS in milliseconds alongside the existing 51 tests.

This is the highest-value test in the project. The ad-strip is the most fragile code here,
and without it a breakage presents as "there's an ad, no idea why" instead of a named
failing assertion. Capture fixtures for both `/player` and `/get_watch` shapes.

### Everything else

- `ShirKit`'s existing 51 tests must continue to pass untouched. If a change to this layer
  is needed, that is a signal the design has leaked.
- UI tests: the existing 11 cover navigation and empty states and should keep passing.
- Playback behaviour with a locked screen is not unit-testable. It is verified by the
  Phase 0 spike and then by hand on the device.

## 7. Risks

| Risk | Likelihood | Response |
|---|---|---|
| Background track change fails | Medium — this is why Phase 0 exists | Fall back to YouTube-playlist-driven ordering, or reconsider extraction |
| YouTube changes response shape | High over time | `JSContext` test names the failure; re-run the extraction script against a fresher bundle |
| Server-side ad insertion | Unknown, contested | **Nothing client-side survives it.** Would end this approach entirely |
| Multi-week upstream breakage | High — Brave had 4 since 2024 | Accept, or fall back to local files during outages |
| Certificate expiry | Certain | 7-day free / 1-year paid / SideStore auto-resign |

The honest framing: Brave, with a paid team and the industry's best filter lists, treats
scriptlet-based YouTube ad blocking as *usually* working. Their own guaranteed ad-free path
on iOS is Brave Playlist — extract to a native player. We are choosing the fragile
technique deliberately because the alternative carries legal exposure we do not want.

## 8. Deployment

Sideloading to a physical iPhone. Signing team must be set manually in Xcode — an agent
cannot do this step.

| Method | Lifetime | Notes |
|---|---|---|
| Free Apple ID | 7 days | Max 3 apps, re-sign by cable |
| Paid developer account | 1 year | $99/yr |
| SideStore / AltStore | Automated | Re-signs over WiFi; what most people settle on |

## 9. Implementation order

1. Phase 0 spike. Gate on criterion #1.
2. Extract and adapt `brave-video-bg-play-update.js` and `brave-yt-sabr-fix.js`.
3. Write `AdStrip.js` plus its `JSContext` tests and fixtures.
4. Rework `YouTubePlayerEngine` for first-party loading and script injection.
5. Wire `Bridge.js` state events into `PlaybackCoordinator`.
6. Remove the background-pause behaviour from `applicationDidEnterBackground()`.
7. Device testing: long playlist, screen locked, over an hour.
8. Regenerate `docs/shir-architecture.html`, which will be stale from step 4 onward.

## 10. Open questions

- Does `loadVideoById` avoid an SPA navigation? Phase 0 answers this.
- Does `m.youtube.com` need a desktop user-agent? Brave's heavier
  `trusted-replace-fetch-response` rules are scoped to `www.youtube.com` and `tv.youtube.com`
  only. If mobile coverage proves weak, forcing desktop UA is the lever.
- How should Shir behave during an upstream breakage — play with ads, or refuse and fall
  back to local files? Product decision, deferrable until it first happens.
