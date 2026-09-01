# Third-party notices

Shir is MIT licensed — see [`LICENSE`](LICENSE). This file records the one piece of
third-party code it contains, and the projects whose code it deliberately does **not**
contain.

## Included

### `ShirKit/Sources/ShirKit/Resources/Scripts/BackgroundPlay.js`

Adapted from Brave's `brave-video-bg-play-update.js`, which is itself based on
[mozilla/video-bg-play](https://github.com/mozilla/video-bg-play). Trimmed to the iOS
path and to what a music app needs; the desktop, Vimeo and pause-resume branches are
gone. The provenance is also recorded in the file's own header comment.

Licensed MIT:

```
Copyright (c) 2017 Mozilla Corporation

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

## Studied, not copied

The technique behind `AdStrip.js` — deleting ad inventory from YouTube's
`/youtubei/v1/player` response before the page parses it — was arrived at independently
by several projects. Shir's implementation was written from the observable behaviour of
the endpoint, not from anyone's source. Where a project's licence would not permit
copying, nothing was copied.

| Project | Licence | Relationship to this repository |
|---|---|---|
| [NouTube](https://github.com/NouTubeApp/NouTube) | AGPL-3.0 | Technique studied and reimplemented. No code copied. |
| [FreeTube](https://github.com/FreeTubeApp/FreeTube) | AGPL-3.0 | Studied only. |
| [LibreTube](https://github.com/libre-tube/LibreTube) | GPL-3.0 | Studied only. |
| uBlock Origin scriptlets (`json-prune`, `set-constant`) | GPL-3.0 | Behaviour studied. Not vendored, not adapted. |
| [Brave `adblock-rust`](https://github.com/brave/adblock-rust) | MPL-2.0 | Not a dependency and not vendored. `scripts/extract-brave-scriptlets.py` reads a Brave resource bundle from the developer's own machine; no Brave code or data is committed here. |

If you believe anything here is attributed incorrectly or incompletely, please open an
issue and it will be corrected.
