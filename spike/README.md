# Phase 0 spike — background playback

Throwaway. Delete `spike/` once it has answered its question; nothing in Shir
depends on it.

It exists to de-risk the one assumption that could invalidate the design in
`docs/superpowers/specs/2026-08-04-youtube-adblock-design.md`: **does audio
survive a programmatic track change while the phone is locked?**

## Running it

```bash
cd spike
xcodegen generate
open BackgroundPlaySpike.xcodeproj
```

Simulator, with a scripted track change 15s after the player is ready:

```bash
xcrun simctl launch <device-id> com.shirhussain.shir.spike -autoadvance
```

Without `-autoadvance` the switch is manual, via the Next button or the
lock-screen ▶▶ control.

## Results so far

### Verified in the simulator — 2026-08-04

| # | Finding | Evidence |
|---|---|---|
| 1 | **Ad keys are stripped on first load** | `js: stripped 1 ad key(s) from ytInitialPlayerResponse` — the server-rendered path, caught by the `Object.defineProperty` interceptor |
| 2 | **Ad keys are stripped on subsequent tracks** | `js: stripped 1 ad key(s), 2 total` immediately after `loadVideoById`, via the `fetch`/XHR patch |
| 3 | **`#movie_player` is reachable and exposes the player API** | `js: bridge wired to #movie_player`, then `onStateChange` events arriving |
| 4 | **`loadVideoById` does NOT navigate** | Before: `href=...v=dQw4w9WgXcQ, videoId=dQw4w9WgXcQ`. After: **`href` unchanged**, `videoId=9bZkp7q19f0`. No `didFinish` navigation callback fired. |
| 5 | Track change is fast and clean | `paused → unstarted → buffering → playing` in about 1 second |
| 6 | `_lact` keepalive arms successfully | `js: _lact keepalive armed` |
| 7 | **YouTube starts every video muted, and the app must unmute it** | Probe before: `muted:true, ytMuted:true`. After forcing: `muted:false, ytMuted:false`. |

### Finding 7 is a real requirement, not a spike quirk

WebKit permits unattended autoplay **only when the media is silent**, so YouTube
mutes itself and waits for a tap on its own "TAP TO UNMUTE" overlay. A music app
must never sit in that state, and nothing else is going to fix it — so the engine
unmutes explicitly, both on player-ready and again after every track change,
since a freshly loaded video can come back muted.

`__spike.unmute()` covers both layers, because they can disagree: the player API
(`unMute()` / `setVolume(100)`) and the raw element flags (`muted`, `volume`).

Diagnosing this took adding `muted` / `volume` / `ytMuted` / `ytVolume` to the
status probe. Keep that instrumentation in the production engine — "no sound" is
otherwise indistinguishable from "not playing".

The audio session was correct throughout and was never the problem:
`category=Playback output=0.6 otherAudio=false route=Speaker`.

**Finding 4 is the important one.** It was the spec's first open question. Because
the swap happens inside a live document, the audio session is never torn down by
a track change — which is the mechanism criterion 1 needs. Shir owning the queue
(rather than delegating to a YouTube playlist page, as Brave does) is what makes
this available.

### NOT yet verified — needs the physical device

The simulator cannot answer these honestly:

- **Criterion 1 proper.** Audio continuing through a track change with the screen
  actually locked. Simulator backgrounding does not reproduce device behaviour.
- **Criterion 2.** Audio surviving 60s+ after lock.
- **Criterion 4.** Lock-screen transport controls appearing and working.
- **Audio at all.** The simulator autoplays the video **muted** — note the
  "TAP TO UNMUTE" overlay. Everything above proves the *video* element advances
  and that ads are stripped; it does not prove a single sample of audio was
  produced. Unmuted playback needs a real user gesture on a real device.

## Device test procedure

1. Set a signing team on the `BackgroundPlaySpike` target in Xcode.
2. Run on the iPhone. Tap the video once to unmute — confirm you hear audio.
3. Lock the phone. Confirm audio continues (criterion 2).
4. Press ▶▶ on the lock screen (criterion 1 and 4).
5. Unlock and read the on-screen log. It timestamps everything that happened
   while locked.

Pass looks like: `js state: playing [<second video id>]` after the lock-screen
press, with `href` still showing the *first* video's URL, and uninterrupted audio.

Fail looks like: playback stopping at the switch, a `navigation finished` line
appearing, or the log showing `bridge not ready`.

If it fails, **stop** — do not start the production implementation. Reread §7 of
the spec and reconsider before spending weeks.

## Layout

```
Sources/
  SpikeApp.swift          @main, scene-phase hooks
  SpikeController.swift   web view, audio session, remote commands, logging
  ContentView.swift       player + controls + on-screen log
  Scripts/
    AdStrip.js            fetch/XHR patch, ad-key deletion
    BackgroundPlay.js     visibility overrides, _lact keepalive
    Bridge.js             player commands in, state events out
```

`Scripts/` is forced into the Resources build phase in `project.yml` — `.js` has
no default build phase in Xcode, and without that the bundle lookup silently
returns nil at runtime.

All three scripts inject at `.atDocumentStart` into `WKContentWorld.page`. They
run three times per page because `forMainFrameOnly: false`; that is expected.
