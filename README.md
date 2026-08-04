# Riff

An iPhone music app in the shape of Musi: build playlists, queue songs, play them.

Two sources, and they behave differently on purpose.

**YouTube** — search and play through YouTube's official embedded player. Playlists, queue,
shuffle, repeat, scrubbing. The video stays on screen and YouTube serves whatever ads it
normally serves. Playback pauses when you leave the app.

**Your own files** — import audio from Files or iCloud Drive. No ads at all, plays in the
background, shows up on the lock screen and AirPlay. This is where uninterrupted listening
comes from.

## Why it doesn't strip YouTube's ads

That's the one thing Musi did that this app deliberately doesn't — and Musi's own history is
the argument.

Apple removed Musi in September 2024 after complaints from IFPI, Sony, the NMPA and YouTube.
Musi sued Apple over the removal, not the other way round; Google never sued Musi. In March
2026 the case was dismissed with prejudice, the court holding that Apple's developer
agreement lets it delist any app "at any time, with or without cause." Musi's law firm was
sanctioned on the way out. An app can be technically unstoppable by Google and still be one
complaint away from ending, because distribution is the chokepoint, not the API.

Musi argued it used no YouTube API at all and so wasn't bound by the API terms. The NMPA
disputed that and separately alleged circumvention of YouTube's stream protection — a DMCA
anti-circumvention claim, which is statute rather than contract. Going around the API makes
the exposure worse, not better.

So this app is built the way that ships: the official IFrame Player for YouTube, and full
ownership of playback for files you bring yourself. For ad-free YouTube specifically, a
Premium account is the route that works.

## Requirements

- Xcode 16 or later, iOS 17+ target
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`
- A YouTube Data API key for search (free; setup below)

## Getting started

```bash
xcodegen generate
open Riff.xcodeproj
```

Then, for search:

1. Go to [console.cloud.google.com](https://console.cloud.google.com), create a project.
2. Enable **YouTube Data API v3**.
3. Credentials → Create credentials → API key.
4. Paste it into the app's Settings tab. It's stored in the device keychain and only ever
   sent to Google.

The free tier is 10,000 quota units a day and a search costs 100, so roughly 100 searches
daily. Search input is debounced to avoid burning through that on keystrokes.

Importing files needs no setup — Library → **+** → Import Audio Files.

## Tests

```bash
swift test --package-path RiffKit    # 51 unit tests: queue, library, API client, parsing
xcodebuild -project Riff.xcodeproj -scheme Riff \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test    # 11 UI tests
./scripts/screenshots.sh             # regenerates screenshots/ from a simulator run
```

The interesting logic lives in `RiffKit`, a plain Swift package with no UI framework
imports, so it tests on macOS in under a second instead of booting a simulator.

## Layout

```
RiffKit/     Models, library store, playback queue, YouTube client — pure Swift, tested
Riff/        SwiftUI app: playback engines, screens, keychain, file import
project.yml  XcodeGen source of truth; Riff.xcodeproj is generated and gitignored
```

## Status

Early. Playback, playlists, queue, search, and import all work. Not yet built: artwork for
imported files, iCloud sync of the library, sleep timer, CarPlay.
