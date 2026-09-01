# Shir

> **Published for educational purposes.**
>
> This repository exists to document a technique and the reasoning behind it: driving a
> `WKWebView` as a player rather than a browser, keeping injected JavaScript alive across
> iOS backgrounding, and how far you get with no API key and no account. It is source
> code and a write-up. There is no binary, no release, and no support.
>
> Shir strips YouTube's ads, which breaks YouTube's Terms of Service. "Educational
> purposes" states intent — it is not a legal shield, and nobody should read it as one.
> Building and running this is your decision and your risk. If you use YouTube, pay for
> it: Premium removes the ads and pays the people who made what you are listening to.

An iPhone music app: build playlists, queue songs, play them. Two sources, treated as one
library.

**YouTube** — search and play through a `WKWebView` driving `m.youtube.com`. No API key and
no account: search runs YouTube's own request from inside a first-party page. Playback
continues with the app backgrounded and the screen locked.

**Your own files** — import audio from Files or iCloud Drive. Plays in the background,
shows up on the lock screen and AirPlay.

## This is a personal sideload, not an App Store app

Shir strips YouTube's ads. It deletes the ad inventory from YouTube's `/youtubei/v1/player`
response before the page's own script parses it, so the player never schedules an ad.

That is why this is signed with a personal certificate and installed on one phone rather
than shipped. App Store Guideline 5.2.1 rejects ad-stripping YouTube clients, and
distribution is the chokepoint — no argument about which API a client uses changes that.

Two consequences worth knowing before you build it:

- **It will break.** Ad blocking on YouTube is an arms race, and even well-resourced
  projects have had multi-week outages. Treat a breakage as upstream until proven otherwise.
- **Server-side ad insertion would end it.** If YouTube stitches ads into the media stream,
  nothing client-side survives.

The app is reversible to a shippable design — the four rules to restore are in `CLAUDE.md`
§4, and git history has each implementation.

## Requirements

- Xcode 16 or later, iOS 17+ target
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`

## Getting started

```bash
xcodegen generate
open Shir.xcodeproj
```

Nothing else needs configuring — search takes no API key, and importing files needs no
setup (Library → **+** → Import Audio Files).

For a **simulator** build that is all you need. For a **device** build, set your own signing
team, either in Xcode under Signing & Capabilities or by exporting it before generating:

```bash
export SHIR_DEVELOPMENT_TEAM=YOURTEAMID
xcodegen generate
```

## Tests

```bash
swift test --package-path ShirKit    # 133 unit tests, macOS, ~0.1s
./scripts/typecheck-ios.sh           # compile-only gate, seconds, no simulator

# 20 UI tests, ~5 min. Use an explicit device id — several simulators share names.
xcodebuild -project Shir.xcodeproj -scheme Shir \
  -destination 'platform=iOS Simulator,id=<UDID>' test
```

The interesting logic lives in `ShirKit`, a plain Swift package with no UI framework
imports, so it tests on macOS in a fraction of a second instead of booting a simulator.
That includes the injected JavaScript, which is unit-tested through `JavaScriptCore`
against captured fixtures.

## Layout

```
ShirKit/     Models, library store, playback queue, YouTube clients, injected .js — pure Swift, tested
Shir/        SwiftUI app: playback engines, screens, web views, file import
project.yml  XcodeGen source of truth; Shir.xcodeproj is generated and gitignored
```

`CLAUDE.md` is the real documentation: architecture, the reasoning behind the non-obvious
decisions, and a pitfalls index.

## Status

Early, and honest about it. Playback, playlists, queue, search, trending and import all
work. Known gaps are listed in `CLAUDE.md` §12 — among them: no search pagination, no play
history (so "Recently Played" duplicates "Recently Added"), four Now Playing buttons laid
out but not wired, and non-embeddable videos not being skipped.

## Licence

MIT — see [`LICENSE`](LICENSE).

One file, `ShirKit/Sources/ShirKit/Resources/Scripts/BackgroundPlay.js`, is adapted from
MIT-licensed code by Mozilla, by way of Brave. That attribution and the upstream notice
are in [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md), together with the projects
whose techniques were studied and whose code was deliberately not copied.
