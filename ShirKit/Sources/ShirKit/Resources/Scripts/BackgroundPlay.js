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

  // The replay logic below needs the real visibility, so capture the native
  // getter before the spoof replaces it. WebKit fires visibilitychange either
  // way — the override only lies to code that *asks*.
  var nativeVisibilityGet = null;
  try {
    var descriptor = Object.getOwnPropertyDescriptor(Document.prototype, 'visibilityState');
    if (descriptor && descriptor.get) { nativeVisibilityGet = descriptor.get; }
  } catch (e) { /* fall through to the spoofed value */ }

  function actualVisibility() {
    try {
      if (nativeVisibilityGet) { return nativeVisibilityGet.call(document); }
    } catch (e) { /* fall through */ }
    return 'visible';
  }

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

  // ---- Backgrounding pause replay -------------------------------------------
  //
  // WebKit pauses every video+audio session with an EnteringBackground
  // interruption when the app backgrounds or locks — and, same code path,
  // when the hosting view leaves the window (WKApplicationStateTrackingView
  // treats an unparented view as a backgrounded app). Script play() during
  // that interruption is permitted; the catch is timing. The moment playback
  // pauses, WebKit's processes drop their media-playback assertion, and on a
  // real device they suspend before a pause→bridge→Swift→evaluateJavaScript
  // round trip can land — which is why the native-only resume passed on the
  // simulator (no suspension there) and died on the phone. The only replay
  // that reliably wins is this one: synchronous, in-page, inside the pause
  // event itself. Brave's shipping implementation is the same shape
  // (brave-core ios/browser/web/media/resources/media_backgrounding.ts,
  // MPL-2.0); this adaptation adds a stricter gate.
  //
  // The gate: replay only a pause the page did not request that coincides
  // with a genuine visible→hidden transition, in either race order, within
  // REPLAY_WINDOW_MS. Everything else — AirPods disconnecting, a phone call,
  // the lock-card pause button (all of which pause without a transition) —
  // is left for the native AutoResumePolicy, which is told by AVAudioSession
  // *who* paused and refuses the ones that must stay paused.

  var REPLAY_WINDOW_MS = 2000;

  // "Who paused most recently": pauses issued through script — Shir's own
  // pause command lands as pauseVideo() → element.pause() — must never be
  // replayed. WebKit's interruption pause is C++ and never crosses these
  // wrappers, so it leaves the flag false.
  var pauseRequested = false;
  var nativePlay = null;
  try {
    if (window.HTMLMediaElement && HTMLMediaElement.prototype) {
      nativePlay = HTMLMediaElement.prototype.play;
      var nativePause = HTMLMediaElement.prototype.pause;
      HTMLMediaElement.prototype.pause = function () {
        pauseRequested = true;
        return nativePause.apply(this, arguments);
      };
      HTMLMediaElement.prototype.play = function () {
        pauseRequested = false;
        return nativePlay.apply(this, arguments);
      };
    }
  } catch (e) {
    report('media prototype wrap failed: ' + e);
  }

  var lastHiddenAt = -REPLAY_WINDOW_MS;
  var lastVisibleAt = -REPLAY_WINDOW_MS;
  document.addEventListener('visibilitychange', function () {
    var vis = actualVisibility();
    report('visibility -> ' + vis);
    if (vis === 'hidden') { lastHiddenAt = Date.now(); } else { lastVisibleAt = Date.now(); }
  }, true);

  function replay(video, why) {
    report('replaying ' + why + ' pause');
    try {
      // The saved original, so the replay does not clear pauseRequested
      // bookkeeping, and a WebKit refusal surfaces as a rejected promise
      // rather than an uncaught error.
      var result = nativePlay ? nativePlay.call(video) : video.play();
      if (result && typeof result.catch === 'function') { result.catch(function () {}); }
    } catch (e) { /* refused; the native policy still gets its slower turn */ }
  }

  // The pause event does not bubble; a capture-phase listener on the document
  // sees it from every current and future media element.
  document.addEventListener('pause', function (event) {
    var video = event.target;
    if (!video || video.tagName !== 'VIDEO') { return; }
    var now = Date.now();
    if (pauseRequested || video.ended) {
      report('pause skipped: requested=' + pauseRequested + ' ended=' + video.ended);
      return;
    }

    if (actualVisibility() === 'hidden') {
      // Pause landed after the transition (home press, lock, view unmounted).
      if (now - lastHiddenAt < REPLAY_WINDOW_MS) {
        replay(video, 'backgrounding');
      } else {
        report('pause while hidden, stale by ' + (now - lastHiddenAt) + 'ms — native policy\'s call');
      }
      return;
    }

    // WebKit's foreground restore of a session it paused lands as a fresh
    // unrequested pause just after the hidden→visible transition — measured
    // on device as pause → player teardown → stream refetch → playing,
    // ~390ms on every return. Answering on the element, in the same event
    // turn, resumes without the player-level restart.
    if (now - lastVisibleAt < REPLAY_WINDOW_MS) {
      replay(video, 'foreground-restore');
      return;
    }

    // Pause landed first, still officially visible. Replay only if the app
    // genuinely backgrounds within the window; otherwise this was a pause to
    // respect — AirPods off, a call — and the armed listener expires
    // untriggered, leaving it to the native policy.
    report('pause while visible, no recent transition — arming ' + REPLAY_WINDOW_MS + 'ms watch');
    var expiry = setTimeout(cleanup, REPLAY_WINDOW_MS);
    function onTransition() {
      if (actualVisibility() !== 'hidden') { return; }
      cleanup();
      if (!video.ended && !pauseRequested) { replay(video, 'backgrounding'); }
    }
    function cleanup() {
      clearTimeout(expiry);
      document.removeEventListener('visibilitychange', onTransition, true);
    }
    document.addEventListener('visibilitychange', onTransition, true);
  }, true);

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
