// Search.js — YouTube search from inside a first-party m.youtube.com document.
//
// No API key. None is needed: the `key` parameter is ignored by the endpoint —
// a deliberately bogus key returns the same 200 and the same results as the
// real one, and both yt-dlp and NewPipe stopped sending it. So we send none.
//
// Search also needs no bot attestation. PoToken/BotGuard gate the *player*
// endpoint, not search; yt-dlp's source defines PO token policies for streams,
// player and subtitles and has no search policy at all. That split is why this
// works while stream extraction does not.
//
// Why in-page rather than a native URLSession request: a same-origin fetch
// carries the page's cookies (including HttpOnly YSC/GPS), a browser-set Origin
// and Referer that page JS cannot forge, and the real User-Agent. More
// importantly the body reuses ytcfg's INNERTUBE_CONTEXT, which holds
// server-minted visitorData, rolloutToken and appInstallData — values a native
// request cannot invent and would have to scrape anyway.
//
// Injected at .atDocumentStart into WKContentWorld.page, in the dedicated
// search web view. It is deliberately NOT injected into the player web view,
// whose AdStrip.js patches window.fetch and matches /youtubei/v1/search — that
// would clone and JSON-parse a 119KB body to remove nothing.

(function () {
  'use strict';

  // JSContext (used by the unit tests) has no `window`.
  var root = typeof window !== 'undefined' ? window : globalThis;

  /// Reads a value out of YouTube's page config.
  ///
  /// Called lazily at search time, never at document-start — `ytcfg` does not
  /// exist yet when this script is injected.
  function ytcfgGet(key) {
    try {
      if (root.ytcfg && typeof root.ytcfg.get === 'function') {
        var value = root.ytcfg.get(key);
        if (value) return value;
      }
    } catch (e) { /* fall through */ }
    try {
      return (root.ytcfg && root.ytcfg.data_ && root.ytcfg.data_[key]) || null;
    } catch (e) {
      return null;
    }
  }

  /// YouTube renders text as either `{simpleText}` or `{runs:[{text}]}`,
  /// inconsistently between desktop and mobile, so handle both everywhere.
  function text(node) {
    if (!node) return '';
    if (node.simpleText) return node.simpleText;
    if (node.runs) {
      return node.runs.map(function (run) { return run.text; }).join('');
    }
    return '';
  }

  /// "5:22" / "1:02:07" -> seconds. Returns null when absent, which is how
  /// live streams present — there is no lengthText on a live item.
  function durationSeconds(label) {
    if (!label) return null;
    var parts = label.split(':').map(Number);
    if (parts.some(isNaN)) return null;
    return parts.reduce(function (total, part) { return total * 60 + part; }, 0);
  }

  /// Walks the response for video items and projects them into small objects.
  ///
  /// Projection happens here rather than in Swift for two reasons: the raw
  /// payload is ~119KB and crossing the bridge with it costs far more than
  /// returning twenty small dictionaries, and searching for `videoRenderer`
  /// rather than hard-coding the container path survives YouTube reshuffling
  /// its wrapper layers — which it does far more often than it renames the
  /// renderers themselves.
  ///
  /// Exposed separately from the fetch so it can be unit-tested against a
  /// captured fixture with no network and no ytcfg.
  function project(payload, limit) {
    var out = [];
    var max = limit || 40;

    function walk(node) {
      if (!node || out.length >= max || typeof node !== 'object') return;
      if (Array.isArray(node)) {
        for (var i = 0; i < node.length; i++) walk(node[i]);
        return;
      }
      // videoWithContextRenderer is mobile, videoRenderer is desktop.
      var video = node.videoWithContextRenderer || node.videoRenderer;
      if (video && video.videoId) {
        var lengthLabel = text(video.lengthText);
        out.push({
          id: video.videoId,
          title: text(video.headline || video.title),
          channel: text(video.shortBylineText || video.ownerText || video.longBylineText),
          durationSeconds: durationSeconds(lengthLabel),
          // Deliberately NOT the thumbnail URL from the response: those carry
          // expiring `sqp`/`rs` signature params, and this URL gets persisted
          // into the library. The i.ytimg.com form is stable and unsigned.
          thumbnail: 'https://i.ytimg.com/vi/' + video.videoId + '/hqdefault.jpg'
        });
      }
      for (var key in node) walk(node[key]);
    }

    walk(payload);
    return out;
  }

  root.__riffProjectSearch = project;

  /// Runs a search and resolves to the projected results.
  root.__riffSearch = function (query) {
    var context = ytcfgGet('INNERTUBE_CONTEXT');
    if (!context) {
      return Promise.reject(new Error('YouTube page config not ready'));
    }

    var clientName = ytcfgGet('INNERTUBE_CONTEXT_CLIENT_NAME') || 2;
    var clientVersion = ytcfgGet('INNERTUBE_CONTEXT_CLIENT_VERSION')
                     || ytcfgGet('INNERTUBE_CLIENT_VERSION')
                     || '';

    // prettyPrint=false is not cosmetic — it roughly halves the payload.
    return fetch('/youtubei/v1/search?prettyPrint=false', {
      method: 'POST',
      credentials: 'same-origin',   // the default, but it is the entire point
      headers: {
        'Content-Type': 'application/json',
        'X-YouTube-Client-Name': String(clientName),
        'X-YouTube-Client-Version': String(clientVersion)
      },
      body: JSON.stringify({
        context: context,
        query: query,
        // base64 protobuf for type=video. Drops Shorts, channels and playlist
        // shelves, which removes most of the parsing edge cases and is what a
        // music app wants anyway.
        params: 'EgIQAQ=='
      })
    }).then(function (response) {
      if (!response.ok) throw new Error('search failed (HTTP ' + response.status + ')');
      return response.json();
    }).then(function (payload) {
      return project(payload);
    });
  };
})();
