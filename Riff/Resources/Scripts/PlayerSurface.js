// PlayerSurface.js — turn m.youtube.com into a bare player.
//
// This is the Musi architecture: the app provides search, playlists and a
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

  var STYLE_ID = '__riff_player_surface';

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
