// MediaSession.js — take the iOS lock screen away from YouTube.
//
// MUST be injected at .atDocumentStart into WKContentWorld.page, and listed
// FIRST in PlayerScripts.player so it captures the pristine MediaSession
// prototype methods before anything else can wrap them.
//
// Why this file exists rather than more MPNowPlayingInfoCenter code:
//
//   WebKit does not publish web-media Now Playing info through MediaPlayer. It
//   writes MediaRemote directly from the WebContent process, with a REPLACE
//   merge policy, against the same per-app origin MPNowPlayingInfoCenter writes
//   to — and re-arms on a repeating timer. Anything Swift sets while this page's
//   <video> is playing is overwritten within a tick.
//
//   WebKit also rebuilds the lock screen's button set as
//   {actions THIS PAGE registered} ∪ {play, pause}. NextTrack is not in its
//   default set. So a next button exists if and only if this file registers a
//   'nexttrack' handler. That is the entire mechanism, and it is why enabling
//   MPRemoteCommandCenter.nextTrackCommand in Swift did nothing.
//
// The page fights back: YouTube re-registers its whole handler set several times
// per media-item change, installs its own nexttrack that advances YOUTUBE's
// queue, and during a pre-roll sets the ADVERTISER as the metadata. An interval
// or a MutationObserver loses that race. A document-start lock does not.

(function () {
  'use strict';

  var HANDLER = 'shir';

  function send(payload) {
    try { window.webkit.messageHandlers[HANDLER].postMessage(payload); } catch (e) {}
  }
  function report(text) { send({ kind: 'log', text: text }); }

  // WKUserScript is all-frames or main-frame-only, never a specific subframe.
  // The player's <video> lives in the top m.youtube.com document; every other
  // frame is an ad or a tracking pixel and must be left alone.
  try { if (window.top !== window) return; } catch (e) { return; }

  if (typeof navigator === 'undefined' || !navigator.mediaSession) {
    report('mediaSession unavailable');
    return;
  }

  var ms = navigator.mediaSession;
  var proto = Object.getPrototypeOf(ms);

  // Capture the real implementations now. Anything that later tries to wrap
  // setActionHandler gets the accessor installed below, never these.
  var rawSet = proto.setActionHandler;
  var rawSetPosition = proto.setPositionState;
  var metaDesc = Object.getOwnPropertyDescriptor(proto, 'metadata');
  var stateDesc = Object.getOwnPropertyDescriptor(proto, 'playbackState');

  if (typeof rawSet !== 'function') {
    report('setActionHandler missing');
    return;
  }

  // Actions Shir owns outright. Page writes to these are discarded.
  var OWNED = {
    play: 1, pause: 1,
    nexttrack: 1, previoustrack: 1,
    seekforward: 1, seekbackward: 1, seekto: 1
  };

  // WebKit holds action handlers weakly and they can be collected, after which
  // the button silently stops firing. Hold a strong reference from the page —
  // one slot per action, so a re-install replaces rather than accumulates.
  var KEEP_ALIVE = {};

  // False while Shir has stood the page's session down — the engine stopped
  // or handed playback to the local engine. Handlers stop acting locally (a
  // stale card press must not restart a stopped video from inside the page)
  // but still report, so Swift keeps the decision.
  var active = true;

  function ownWrite(action, handler) {
    try {
      if (typeof handler === 'function') { KEEP_ALIVE[action] = handler; } else { delete KEEP_ALIVE[action]; }
      rawSet.call(ms, action, handler);
    } catch (e) {
      report('mediaSession ' + action + ' failed: ' + e);
    }
  }

  // ---- lock setActionHandler ------------------------------------------------
  //
  // The lock SWALLOWS rather than throws. YouTube's bundle is strict mode, and a
  // throw during player init risks breaking playback outright — a blank lock
  // screen is a far better failure than no music.

  var wrapper = function (action, handler) {
    if (OWNED[action]) return undefined;   // drop, silently
    return rawSet.call(ms, action, handler);
  };

  try {
    Object.defineProperty(ms, 'setActionHandler', {
      configurable: false,
      enumerable: false,
      get: function () { return wrapper; },
      set: function () {}
    });
  } catch (e) {
    report('setActionHandler lock failed: ' + e);
  }

  // Second line of defence, in case the page reaches through the prototype.
  try { proto.setActionHandler = wrapper; } catch (e) {}

  // NOTE: configurable:false means this can never be redefined by anyone,
  // including us — a later evaluateJavaScript re-install would throw. That is
  // why ownWrite calls the captured rawSet directly instead of going through
  // the wrapper, and why the wrapper reads OWNED from closure state rather
  // than being swapped out. Do not "fix" this by making it configurable.

  // ---- lock metadata --------------------------------------------------------
  //
  // Without this the card shows the advertiser during a pre-roll. The accessor
  // gates JS writers only; WebCore reads its own internal member, so only values
  // pushed through the captured descriptor reach the OS.

  var ourMetadata = null;

  // The getter hands out a COPY, never the live object. Returning ourMetadata
  // itself would open a second write channel the assignment lock cannot see:
  // WebCore propagates in-place attribute mutation (metadata.title = "…")
  // straight to the lock screen via MediaMetadata's metadataUpdated path — no
  // setter involved.
  function metadataCopy() {
    if (!ourMetadata) return null;
    try {
      return new window.MediaMetadata({
        title: ourMetadata.title,
        artist: ourMetadata.artist,
        album: ourMetadata.album,
        artwork: (ourMetadata.artwork || []).slice()
      });
    } catch (e) { return null; }
  }

  try {
    Object.defineProperty(ms, 'metadata', {
      configurable: false,
      enumerable: false,
      get: function () { return metadataCopy(); },
      set: function () {}
    });
  } catch (e) {
    report('metadata lock failed: ' + e);
  }

  function applyMetadata(title, artist, album, artworkURL) {
    try {
      // Artwork is fetched as an ordinary no-cors subresource, but the page's
      // img-src still applies — an i.ytimg.com URL is what m.youtube.com already
      // loads, so it passes. WebKit re-encodes it, so `type` is advisory.
      var artwork = artworkURL
        ? [{ src: artworkURL, sizes: '320x180', type: 'image/jpeg' }]
        : [];
      ourMetadata = new window.MediaMetadata({
        title: title || '',
        artist: artist || '',
        album: album || '',
        artwork: artwork
      });
      if (metaDesc && metaDesc.set) metaDesc.set.call(ms, ourMetadata);
      return 'metadata set';
    } catch (e) {
      return 'metadata failed: ' + e;
    }
  }

  // ---- element and position -------------------------------------------------

  function videoElement() {
    return document.querySelector('#movie_player video, video');
  }

  function pushPlaybackState(state) {          // 'playing' | 'paused' | 'none'
    try { if (stateDesc && stateDesc.set) stateDesc.set.call(ms, state); } catch (e) {}
  }

  // MediaRemote extrapolates elapsed time from position, rate and wallclock, so
  // the scrubber needs transitions plus a slow heartbeat rather than a per-second
  // timer waking a backgrounded process. setPositionState throws on a non-finite
  // duration or an out-of-range position, and an uncaught throw here would take
  // out the caller.
  function pushPosition() {
    var v = videoElement();
    if (!v || !rawSetPosition) return;
    var duration = v.duration;
    if (!isFinite(duration) || duration <= 0) return;
    try {
      rawSetPosition.call(ms, {
        duration: duration,
        position: Math.min(Math.max(v.currentTime || 0, 0), duration),
        playbackRate: v.playbackRate || 1
      });
    } catch (e) {}
  }

  // ---- handlers -------------------------------------------------------------
  //
  // next/previous and seekto do NOT act locally. Shir's queue and scrubber live
  // in Swift, and the whole point of this file is that the lock screen drives
  // SHIR — a local pre-seek here applied the same absolute time twice, and the
  // second application landed a round trip later against a moving playhead: an
  // audible snap-back on every lock-screen scrub.
  //
  // play/pause DO act locally, for latency — but the remote message goes out
  // FIRST. Swift's notePause/notePlay bookkeeping must win any ordering race
  // with Bridge.js's state event; acting first would leave that ordering
  // resting on YouTube's player dispatching onStateChange asynchronously
  // inside pauseVideo(), an undocumented internal free to change.

  function bridge() { return window.__shir; }

  function install() {
    // Skip-15s occupies the same two lock-screen slots as previous/next, so
    // these must be nulled for the track buttons to appear at all.
    ownWrite('seekforward', null);
    ownWrite('seekbackward', null);

    ownWrite('nexttrack', function () {
      send({ kind: 'remote', action: 'next' });
    });
    ownWrite('previoustrack', function () {
      send({ kind: 'remote', action: 'previous' });
    });

    ownWrite('play', function () {
      send({ kind: 'remote', action: 'play' });
      if (!active) return;
      var b = bridge();
      if (b && b.play) { try { b.play(); } catch (e) {} }
      pushPlaybackState('playing');
    });
    ownWrite('pause', function () {
      send({ kind: 'remote', action: 'pause' });
      if (!active) return;
      var b = bridge();
      if (b && b.pause) { try { b.pause(); } catch (e) {} }
      pushPlaybackState('paused');
    });

    ownWrite('seekto', function (details) {
      send({ kind: 'remote', action: 'seek', time: (details && details.seekTime) || 0 });
    });

    return 'installed';
  }

  function wire(video) {
    if (!video || video.__shirMediaWired) return;
    video.__shirMediaWired = true;
    video.addEventListener('playing', function () { if (!active) return; pushPlaybackState('playing'); pushPosition(); });
    video.addEventListener('pause', function () { if (!active) return; pushPlaybackState('paused'); pushPosition(); });
    video.addEventListener('loadedmetadata', function () { if (active) pushPosition(); });
    video.addEventListener('ratechange', function () { if (active) pushPosition(); });
    video.addEventListener('seeked', function () { if (active) pushPosition(); });
  }

  // m.youtube.com is an SPA and replaces the media element. Poll on the same 1s
  // cadence Bridge.js already uses rather than adding a MutationObserver.
  setInterval(function () { wire(videoElement()); }, 1000);
  setInterval(function () { if (active) pushPosition(); }, 5000);

  // ---- the surface Swift drives ---------------------------------------------

  window.__shirMedia = {
    // Also re-arms a session `deactivate` stood down — the engine pushes
    // metadata on every load, so a new track is what brings the card back.
    setMetadata: function (title, artist, album, artworkURL) {
      active = true;
      return applyMetadata(title, artist, album, artworkURL);
    },
    // The engine stopped, or handed playback to the local engine: clear the
    // card and stand the handlers down to report-only, so a stale card press
    // cannot restart a stopped video from inside the page.
    deactivate: function () {
      active = false;
      ourMetadata = null;
      try { if (metaDesc && metaDesc.set) metaDesc.set.call(ms, null); } catch (e) {}
      pushPlaybackState('none');
      return 'deactivated';
    },
    pushPosition: function () { pushPosition(); return 'position pushed'; },
    // Idempotent. The lock means YouTube can never undo the install, and
    // KEEP_ALIVE is keyed by action, so calling again is free.
    install: install,
    // Device diagnostics. Note `hidden` and `visibility` are lies told by
    // BackgroundPlay.js — WebKit's own now-playing gate reads its internal page
    // visibility in C++, not these getters.
    probe: function () {
      var v = videoElement();
      return JSON.stringify({
        active: active,
        hasMetadata: !!ourMetadata,
        title: ourMetadata ? ourMetadata.title : null,
        playbackState: ms.playbackState,
        muted: v ? v.muted : null,
        tag: v ? v.tagName : null,
        duration: v && isFinite(v.duration) ? Math.round(v.duration) : null,
        hidden: document.hidden,
        visibility: document.visibilityState
      });
    }
  };

  install();
  wire(videoElement());
  report('MediaSession owned');
})();
