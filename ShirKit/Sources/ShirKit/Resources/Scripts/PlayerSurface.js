// PlayerSurface.js — turn m.youtube.com into a bare player.
//
// This is the architecture: the app provides search, playlists and a
// queue, and the web view is a dumb surface that shows video and nothing else.
// The user never sees or touches YouTube's interface.
//
// That is not only cosmetic. Letting touches reach YouTube's chrome crashed the
// app outright — UIKit threw from UIGestureGraph addUniqueEdgeWithLabel while
// delivering a touch, because WKWebView's gesture recognizers and the ones
// YouTube's search UI installs formed a conflicting edge. Removing the chrome
// removes the whole class of problem.
//
// Injected at .atDocumentStart into WKContentWorld.page, all frames.

(function () {
  'use strict';

  var STYLE_ID = '__shir_player_surface';

  // Everything that is not the video itself. Deliberately conservative — this
  // hides chrome, it does not restructure YouTube's layout, so a selector going
  // stale degrades to "some chrome is visible" rather than "no video".
  var HIDE = [
    'ytm-mobile-topbar-renderer',        // header with search + Open App
    'header.mobile-topbar-header',
    'ytm-pivot-bar-renderer',            // bottom nav
    'ytm-single-column-watch-next-results-renderer', // related videos
    'ytm-item-section-renderer',         // comments, chips
    'ytm-companion-slot',
    'ytm-app-promo-renderer',
    'ytm-banner-promo-renderer',
    '.mobile-topbar-header',
    '#dialog',
    'ytm-button-renderer.icon-button'
  ];

  function install() {
    if (document.getElementById(STYLE_ID)) return;
    var head = document.head || document.documentElement;
    if (!head) return;

    var style = document.createElement('style');
    style.id = STYLE_ID;
    style.textContent =
      HIDE.join(',\n') + ' { display: none !important; }\n' +
      // Let the player take the whole surface.
      'ytm-app, #app, body, html { background: #000 !important; }\n' +
      '.player-container, #player-container-id, ytm-player { ' +
        'margin: 0 !important; padding: 0 !important; }\n' +
      // The page positions .player-container at top:48px to clear the header
      // bar — which is in the HIDE list above, so those 48px are now a black
      // band across the top of the stage and the same amount is pushed off the
      // bottom. Measured before this rule: a 226pt stage showed 130pt of video
      // centred between two 48pt bars.
      '.player-container, #player-container-id.player-container { top: 0 !important; }\n' +
      // Keep YouTube's own 16:9 box (padding-bottom:56.25% is how the page
      // states the ratio; the Swift side states it as Theme.videoAspectRatio)
      // and hold it to the full width of the web view.
      '.player-container .player-size, ytm-watch .player-size, ' +
        '#player.player-api.player-size { position: relative !important; ' +
        'width: 100% !important; padding-bottom: 56.25% !important; ' +
        'height: auto !important; max-height: none !important; }\n' +
      // Deliberately NOT overriding the <video> element's own size here.
      //
      // The remaining letterbox is not CSS: the player measures #movie_player
      // and writes a contain-fitted, centred *pixel* rect onto the <video>
      // inline, on every resize. That math is correct once the container sits
      // at top:0, and it is the same thing the reference app shows — a 1.95:1
      // source letterboxed inside a 16:9 box, not cropped to fill it.
      //
      // Forcing width/height/object-fit onto the <video> would outrank it (on
      // MWEB the inline write is plain — the setProperty(..., 'important')
      // branch is gated on WEB_UNPLUGGED, i.e. YouTube TV), but it could not be
      // verified: the simulator never starts playback, so every capture shows
      // YouTube's poster overlay rather than the video element. Untestable and
      // unnecessary, so it stays out until something proves it is needed.

      // Belt and braces: touches are already disabled on the UIView side, but
      // this stops any stray long-press/selection UI from being constructed.
      '* { -webkit-touch-callout: none !important; -webkit-user-select: none !important; }\n';

    head.appendChild(style);
  }

  install();
  document.addEventListener('DOMContentLoaded', install);
  // m.youtube.com is an SPA and rebuilds chrome as it goes.
  window.addEventListener('yt-navigate-finish', install);
  window.addEventListener('yt-page-data-updated', install);
  setInterval(install, 2000);
})();
