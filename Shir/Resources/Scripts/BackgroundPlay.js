// BackgroundPlay.js — keep YouTube playing with the screen off.
//
// Adapted from Brave's brave-video-bg-play-update.js, which is itself based on
// https://github.com/mozilla/video-bg-play (MIT). Trimmed to the iOS path and
// to what a music app needs; the desktop/Vimeo/pause-resume branches are gone.
//
// MUST be injected at .atDocumentStart into WKContentWorld.page.
//
// The critical iOS-specific finding, quoting Brave's own comment: they
// deliberately do NOT block visibilitychange events on iOS, because doing so
// "conflicts with media backgrounding". Overriding the Document properties is
// enough, and is what keeps YouTube from pausing itself.

(function () {
  'use strict';

  function report(message) {
    try {
      window.webkit.messageHandlers.shir.postMessage({ kind: 'log', text: message });
    } catch (e) { /* no handler; carry on */ }
  }

  // ---- Page Visibility ------------------------------------------------------
  //
  // YouTube reads these to decide it has been backgrounded and should pause.
  // Lie to it. Defined on Document.prototype so the override survives any
  // per-document reset.

  try {
    Object.defineProperty(Document.prototype, 'hidden', {
      get: function () { return false; },
      enumerable: false,
      configurable: true
    });
    Object.defineProperty(Document.prototype, 'visibilityState', {
      get: function () { return 'visible'; },
      enumerable: false,
      configurable: true
    });
    Object.defineProperty(Document.prototype, 'onvisibilitychange', {
      get: function () { return null; },
      set: function () {},
      enumerable: false,
      configurable: true
    });
  } catch (e) {
    report('visibility override failed: ' + e);
  }

  // NOTE: deliberately NOT calling
  //     document.addEventListener('visibilitychange', stopPropagation, true)
  // Brave does that on desktop and Android and explicitly skips it on iOS
  // because it fights the media session. Do not "fix" this.

  // ---- Activity keepalive ---------------------------------------------------
  //
  // window._lact is YouTube's last-activity timestamp. Left alone, long
  // sessions stop on their own and the "Are you still watching?" interstitial
  // appears. For an app meant to play for hours this is load-bearing.

  function refreshLact() {
    try {
      if (window._lact !== undefined) window._lact = Date.now();
    } catch (e) { /* ignore */ }
  }

  function waitForLact(callback, interval, delay) {
    delay = delay || 1000;
    var maxDelay = 60 * 1000;
    if (Object.prototype.hasOwnProperty.call(window, '_lact')) {
      setInterval(callback, interval);
      report('_lact keepalive armed');
    } else {
      setTimeout(function () {
        waitForLact(callback, interval, Math.min(delay * 2, maxDelay));
      }, delay);
    }
  }

  waitForLact(refreshLact, 5 * 60 * 1000);

  // Synthetic interaction, every 10 minutes, to defeat the idle interstitial.
  setInterval(function () {
    var player = document.querySelector('#movie_player');
    if (player) {
      player.dispatchEvent(new MouseEvent('mousemove', { bubbles: true }));
    }
    refreshLact();
  }, 10 * 60 * 1000);

  // Keep the player's own state machine ticking.
  setInterval(function () {
    var video = document.querySelector('#movie_player video, video');
    if (video && !video.paused) {
      video.dispatchEvent(new Event('timeupdate'));
    }
  }, 60 * 1000);

  report('BackgroundPlay installed');
})();
