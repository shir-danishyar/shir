// AdStrip.js — delete YouTube's ad inventory before its player reads it.
//
// MUST be injected at .atDocumentStart into WKContentWorld.page. In an
// isolated world this file runs, reports success, and does nothing, because
// the `fetch` it patches is not the one the page uses.
//
// Technique independently arrived at by NouTube (lib/intercept.ts) and by
// uBlock Origin / Brave (##+js(json-prune, ...) rules). Reimplemented here
// rather than copied: NouTube is AGPL-3.0.

(function () {
  'use strict';

  // The only place these key names appear. Do not mirror them into Swift.
  var AD_KEYS = ['adPlacements', 'playerAds', 'adSlots', 'adBreakHeartbeatParams'];

  // Wider than just /player: the ad payload rides along on several of these.
  var ENDPOINT = /\/youtubei\/v1\/(browse|get_watch|next|player|search)/;

  var stripped = 0;

  function report(message) {
    try {
      window.webkit.messageHandlers.riff.postMessage({ kind: 'log', text: message });
    } catch (e) {
      /* handler not registered — playback still works, we just lose the log line */
    }
  }

  // Returns how many keys it removed, so callers can tell "no ads present"
  // from "we did something".
  function stripFrom(object) {
    if (!object || typeof object !== 'object') return 0;
    var removed = 0;
    for (var i = 0; i < AD_KEYS.length; i++) {
      if (AD_KEYS[i] in object) {
        delete object[AD_KEYS[i]];
        removed++;
      }
    }
    return removed;
  }

  // Walks the three shapes YouTube actually returns:
  //   /player     -> ad keys at the root
  //   /get_watch  -> nested at data[0].playerResponse  (NouTube shipped this as a bug fix)
  //   others      -> a playerResponse sibling
  function stripDeep(data) {
    var removed = stripFrom(data);
    if (!data || typeof data !== 'object') return removed;

    removed += stripFrom(data.playerResponse);

    if (Array.isArray(data)) {
      for (var i = 0; i < data.length; i++) {
        removed += stripFrom(data[i]);
        if (data[i]) removed += stripFrom(data[i].playerResponse);
      }
    }
    return removed;
  }

  function transform(text) {
    if (!text || text.charAt(0) !== '{' && text.charAt(0) !== '[') return text;
    try {
      var data = JSON.parse(text);
      var removed = stripDeep(data);
      if (removed === 0) return text;
      stripped += removed;
      report('stripped ' + removed + ' ad key(s), ' + stripped + ' total');
      return JSON.stringify(data);
    } catch (e) {
      return text;
    }
  }

  function isTargetURL(rawURL) {
    try {
      return ENDPOINT.test(new URL(rawURL, location.href).pathname);
    } catch (e) {
      return false;
    }
  }

  // ---- fetch ----------------------------------------------------------------

  var nativeFetch = window.fetch;
  window.fetch = function (input, init) {
    var self = this;
    var args = arguments;
    return nativeFetch.apply(self, args).then(function (response) {
      var url = (input && input.url) ? input.url : String(input);
      if (!isTargetURL(url)) return response;

      return response.clone().text().then(function (text) {
        var patched = transform(text);
        if (patched === text) return response;
        return new Response(patched, {
          status: response.status,
          statusText: response.statusText,
          headers: response.headers
        });
      }).catch(function () {
        return response;
      });
    });
  };

  // ---- XMLHttpRequest -------------------------------------------------------

  var nativeOpen = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function (method, url) {
    this.__riffURL = url;
    return nativeOpen.apply(this, arguments);
  };

  var nativeSend = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.send = function () {
    var request = this;
    request.addEventListener('readystatechange', function () {
      if (request.readyState !== 4) return;
      if (!isTargetURL(request.__riffURL || '')) return;

      var original;
      try {
        original = request.responseText;
      } catch (e) {
        return; // responseType isn't text; nothing to rewrite
      }

      var patched = transform(original);
      if (patched === original) return;

      // Own properties shadow the prototype getters.
      Object.defineProperty(request, 'responseText', { value: patched });
      Object.defineProperty(request, 'response', { value: patched });
    });
    return nativeSend.apply(this, arguments);
  };

  // ---- server-rendered payloads --------------------------------------------
  //
  // ytInitialPlayerResponse and ytInitialData are assigned by an inline
  // <script> tag. They never pass through fetch or XHR, so without this the
  // very first video of a session plays its ad.

  ['ytInitialPlayerResponse', 'ytInitialData'].forEach(function (name) {
    var stored;
    try {
      Object.defineProperty(window, name, {
        configurable: true,
        get: function () { return stored; },
        set: function (value) {
          var removed = stripDeep(value);
          if (removed > 0) {
            stripped += removed;
            report('stripped ' + removed + ' ad key(s) from ' + name);
          }
          stored = value;
        }
      });
    } catch (e) {
      report('could not intercept ' + name + ': ' + e);
    }
  });

  report('AdStrip installed');
})();
