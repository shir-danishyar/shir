// Bridge.js — commands from Swift into YouTube's player, state back out.
//
// On m.youtube.com the player element (#movie_player) exposes the same API
// surface as the IFrame player, but because we are first-party we can call it
// directly instead of postMessage'ing at it. That is the entire reason this
// spike loads m.youtube.com rather than an embed.
//
// Injected at .atDocumentStart into WKContentWorld.page.

(function () {
  'use strict';

  function send(payload) {
    try {
      window.webkit.messageHandlers.spike.postMessage(payload);
    } catch (e) { /* no handler */ }
  }

  function report(message) {
    send({ kind: 'log', text: message });
  }

  function player() {
    return document.querySelector('#movie_player');
  }

  // YouTube's numeric player states.
  var STATE_NAMES = {
    '-1': 'unstarted', 0: 'ended', 1: 'playing', 2: 'paused', 3: 'buffering', 5: 'cued'
  };

  var wiredPlayer = null;

  function wireUp() {
    var p = player();
    if (!p || p === wiredPlayer) return;
    if (typeof p.addEventListener !== 'function') return;

    try {
      p.addEventListener('onStateChange', function (state) {
        var name = STATE_NAMES[String(state)] || ('state ' + state);
        send({ kind: 'state', state: name, videoId: currentVideoId() });
        // Criterion 1 hinges on this line: if a backgrounded track change
        // works, we see ended -> unstarted/buffering -> playing with no gap.
        report('player state: ' + name);
      });
      wiredPlayer = p;
      report('bridge wired to #movie_player');
      send({ kind: 'ready' });
    } catch (e) {
      report('wireUp failed: ' + e);
    }
  }

  function currentVideoId() {
    try {
      var data = player().getVideoData();
      return (data && data.video_id) || '';
    } catch (e) {
      return '';
    }
  }

  function ytMuted() {
    try { return player().isMuted(); } catch (e) { return null; }
  }

  function ytVolume() {
    try { return player().getVolume(); } catch (e) { return null; }
  }

  // The player is created well after document-start, and m.youtube.com is an
  // SPA, so poll rather than assume.
  setInterval(wireUp, 1000);
  window.addEventListener('yt-navigate-finish', wireUp);
  window.addEventListener('yt-page-data-updated', wireUp);

  // ---- the command surface Swift calls --------------------------------------

  window.__spike = {
    // The measurement that matters. Returns a string describing what happened
    // so the Swift side can log it even when the screen is locked.
    load: function (videoId) {
      var p = player();
      if (!p) return 'no player element';
      if (typeof p.loadVideoById !== 'function') return 'loadVideoById unavailable';
      try {
        p.loadVideoById(videoId);
        return 'loadVideoById(' + videoId + ') called';
      } catch (e) {
        return 'loadVideoById threw: ' + e;
      }
    },

    play: function () {
      var p = player();
      if (p && typeof p.playVideo === 'function') { p.playVideo(); return 'playVideo'; }
      var v = document.querySelector('video');
      if (v) { v.play(); return 'video.play'; }
      return 'no player';
    },

    pause: function () {
      var p = player();
      if (p && typeof p.pauseVideo === 'function') { p.pauseVideo(); return 'pauseVideo'; }
      var v = document.querySelector('video');
      if (v) { v.pause(); return 'video.pause'; }
      return 'no player';
    },

    // Cheap probe used to prove the page did not navigate underneath us.
    status: function () {
      var v = document.querySelector('video');
      return JSON.stringify({
        href: location.href,
        videoId: currentVideoId(),
        paused: v ? v.paused : null,
        currentTime: v ? Math.round(v.currentTime) : null,
        duration: v ? Math.round(v.duration) : null,
        readyState: v ? v.readyState : null,
        // Audio diagnostics. `muted` is the element flag; `volume` is 0..1;
        // ytMuted is the player's own idea, which can disagree with the element.
        muted: v ? v.muted : null,
        volume: v ? v.volume : null,
        ytMuted: ytMuted(),
        ytVolume: ytVolume(),
        videoCount: document.querySelectorAll('video').length,
        hidden: document.hidden,
        visibility: document.visibilityState
      });
    },

    // Force audio on without going through YouTube's own unmute affordance.
    // If this produces sound and tapping the overlay does not, the problem is
    // YouTube's UI. If neither produces sound, the problem is below the page.
    unmute: function () {
      var results = [];
      var p = player();

      if (p && typeof p.unMute === 'function') {
        try { p.unMute(); results.push('player.unMute'); } catch (e) { results.push('unMute threw'); }
      }
      if (p && typeof p.setVolume === 'function') {
        try { p.setVolume(100); results.push('setVolume(100)'); } catch (e) {}
      }

      var videos = document.querySelectorAll('video');
      for (var i = 0; i < videos.length; i++) {
        videos[i].muted = false;
        videos[i].volume = 1;
        var playback = videos[i].play();
        if (playback && playback.catch) {
          playback.catch(function (e) { report('play() rejected: ' + e); });
        }
      }
      results.push('unmuted ' + videos.length + ' video element(s)');
      return results.join(', ');
    }
  };

  report('Bridge installed');
})();
