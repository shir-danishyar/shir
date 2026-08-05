// Bridge.js — commands from Swift into YouTube's player, state and progress back.
//
// On m.youtube.com the player element (#movie_player) exposes the same API as
// the IFrame player, but because the page is first-party we call it directly
// rather than posting messages at an embed. That is the whole reason the engine
// loads m.youtube.com instead of youtube.com/embed: a cross-origin iframe is a
// black box, and nothing — not ad stripping, not background playback — can
// reach inside it.
//
// Injected at .atDocumentStart into WKContentWorld.page, all frames.

(function () {
  'use strict';

  var HANDLER = 'shir';

  function send(payload) {
    try {
      window.webkit.messageHandlers[HANDLER].postMessage(payload);
    } catch (e) {
      /* no handler registered — playback still works, we just lose telemetry */
    }
  }

  function report(message) {
    send({ kind: 'log', text: message });
  }

  function player() {
    return document.querySelector('#movie_player');
  }

  function videoElement() {
    return document.querySelector('#movie_player video, video');
  }

  // YouTube's numeric player states, mapped to the names Swift's EngineState
  // expects. -1 (unstarted) and 5 (cued) both mean "loaded, not started".
  var STATES = {
    '-1': 'idle', '0': 'ended', '1': 'playing', '2': 'paused', '3': 'buffering', '5': 'paused'
  };

  var wiredPlayer = null;
  var progressTimer = null;

  function currentVideoId() {
    try {
      var data = player().getVideoData();
      return (data && data.video_id) || '';
    } catch (e) {
      return '';
    }
  }

  function emitProgress() {
    var v = videoElement();
    if (!v) return;
    var duration = isFinite(v.duration) ? v.duration : 0;
    send({ kind: 'progress', position: v.currentTime || 0, duration: duration });
  }

  function startProgress() {
    if (progressTimer) return;
    // 500ms is what the previous IFrame bridge used: smooth enough for the
    // scrubber without flooding the message handler.
    progressTimer = setInterval(emitProgress, 500);
  }

  function stopProgress() {
    if (!progressTimer) return;
    clearInterval(progressTimer);
    progressTimer = null;
  }

  function wireUp() {
    var p = player();
    if (!p || p === wiredPlayer) return;
    if (typeof p.addEventListener !== 'function') return;

    try {
      p.addEventListener('onStateChange', function (code) {
        var state = STATES[String(code)] || 'idle';
        send({ kind: 'state', state: state, videoId: currentVideoId() });
        if (state === 'playing') { startProgress(); emitProgress(); } else { stopProgress(); }
      });
      p.addEventListener('onError', function (code) {
        send({ kind: 'error', code: code });
      });
      wiredPlayer = p;
      send({ kind: 'ready' });
      report('bridge wired to #movie_player');
    } catch (e) {
      report('wireUp failed: ' + e);
    }
  }

  // The player is built well after document-start, and m.youtube.com is an SPA
  // that can replace it, so poll rather than assume.
  setInterval(wireUp, 1000);
  window.addEventListener('yt-navigate-finish', wireUp);
  window.addEventListener('yt-page-data-updated', wireUp);

  // ---- the command surface Swift calls --------------------------------------

  window.__shir = {
    // Swap the video without navigating. Verified in the Phase 0 spike:
    // location.href does not change, so the document — and with it the audio
    // session — survives a track change.
    load: function (videoId) {
      var p = player();
      if (!p) return 'no player element';
      if (typeof p.loadVideoById !== 'function') return 'loadVideoById unavailable';
      try {
        p.loadVideoById(videoId);
        return 'loaded ' + videoId;
      } catch (e) {
        return 'loadVideoById threw: ' + e;
      }
    },

    cue: function (videoId) {
      var p = player();
      if (!p || typeof p.cueVideoById !== 'function') return 'cueVideoById unavailable';
      try { p.cueVideoById(videoId); return 'cued ' + videoId; } catch (e) { return 'cue threw: ' + e; }
    },

    play: function () {
      var p = player();
      if (p && typeof p.playVideo === 'function') { p.playVideo(); return 'playVideo'; }
      var v = videoElement();
      if (v) { v.play(); return 'video.play'; }
      return 'no player';
    },

    pause: function () {
      var p = player();
      if (p && typeof p.pauseVideo === 'function') { p.pauseVideo(); return 'pauseVideo'; }
      var v = videoElement();
      if (v) { v.pause(); return 'video.pause'; }
      return 'no player';
    },

    seek: function (seconds) {
      var p = player();
      if (p && typeof p.seekTo === 'function') { p.seekTo(seconds, true); return 'seekTo ' + seconds; }
      var v = videoElement();
      if (v) { v.currentTime = seconds; return 'currentTime = ' + seconds; }
      return 'no player';
    },

    stop: function () {
      stopProgress();
      var p = player();
      if (p && typeof p.stopVideo === 'function') { p.stopVideo(); return 'stopVideo'; }
      var v = videoElement();
      if (v) { v.pause(); return 'video.pause'; }
      return 'no player';
    },

    // YouTube starts every video muted, because WebKit only permits unattended
    // autoplay when the media is silent. Nothing else will unmute it, so the
    // engine calls this on load and after every track change.
    unmute: function () {
      var p = player();
      if (p && typeof p.unMute === 'function') { try { p.unMute(); } catch (e) {} }
      if (p && typeof p.setVolume === 'function') { try { p.setVolume(100); } catch (e) {} }
      var videos = document.querySelectorAll('video');
      for (var i = 0; i < videos.length; i++) {
        videos[i].muted = false;
        videos[i].volume = 1;
      }
      return 'unmuted ' + videos.length;
    },

    status: function () {
      var v = videoElement();
      return JSON.stringify({
        href: location.href,
        videoId: currentVideoId(),
        paused: v ? v.paused : null,
        currentTime: v ? Math.round(v.currentTime) : null,
        duration: v ? Math.round(v.duration) : null,
        muted: v ? v.muted : null,
        readyState: v ? v.readyState : null
      });
    }
  };

  report('Bridge installed');
})();
