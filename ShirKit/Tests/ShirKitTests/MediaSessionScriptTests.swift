import JavaScriptCore
import XCTest
@testable import ShirKit

/// Tests `MediaSession.js`, which is what makes the iOS lock screen show Shir's
/// track and route its next button into Shir's queue.
///
/// The behaviour under test is adversarial: YouTube re-registers its own media
/// session handlers several times per track change, and would otherwise make the
/// lock screen's next button advance *its* playlist and show the advertiser's
/// name during a pre-roll. The lock has to survive that, and the only way to know
/// it does is to simulate the page fighting back.
final class MediaSessionScriptTests: XCTestCase {

    /// A JSContext with enough of the Media Session API to run the script.
    ///
    /// `mediaSession` is built with a real prototype carrying accessors, because
    /// the script reads `Object.getPrototypeOf` and
    /// `Object.getOwnPropertyDescriptor` and would silently no-op against a
    /// plain object.
    private func context() throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        var thrown: String?
        context.exceptionHandler = { _, exception in thrown = exception?.toString() }

        context.evaluateScript(
            """
            var window = this;
            window.top = window;
            window.webkit = { messageHandlers: { shir: { postMessage: function (m) {
                window.__sent = window.__sent || []; window.__sent.push(m);
            } } } };

            window.MediaMetadata = function (init) {
                this.title = init.title; this.artist = init.artist;
                this.album = init.album; this.artwork = init.artwork;
            };

            // Stand-in for WebCore: records what actually reached the OS.
            window.__native = { handlers: {}, metadata: null, state: null, position: null };

            function MediaSessionProto() {}
            MediaSessionProto.prototype.setActionHandler = function (action, handler) {
                window.__native.handlers[action] = handler;
            };
            MediaSessionProto.prototype.setPositionState = function (state) {
                window.__native.position = state;
            };
            Object.defineProperty(MediaSessionProto.prototype, 'metadata', {
                configurable: true,
                get: function () { return window.__native.metadata; },
                set: function (value) { window.__native.metadata = value; }
            });
            Object.defineProperty(MediaSessionProto.prototype, 'playbackState', {
                configurable: true,
                get: function () { return window.__native.state; },
                set: function (value) { window.__native.state = value; }
            });

            var navigator = { mediaSession: new MediaSessionProto() };
            window.navigator = navigator;

            var video = {
                duration: 213, currentTime: 12, playbackRate: 1, muted: false,
                tagName: 'VIDEO', addEventListener: function () {}
            };
            var document = {
                querySelector: function () { return video; },
                hidden: false, visibilityState: 'visible'
            };
            window.document = document;
            window.setInterval = function () { return 0; };
            window.__shir = { play: function () {}, pause: function () {}, seek: function () {} };
            """
        )

        context.evaluateScript(try PlayerScripts.mediaSession.source)
        if let thrown { XCTFail("MediaSession.js threw: \(thrown)") }
        return context
    }

    private func nativeHandlerExists(_ action: String, in context: JSContext) -> Bool {
        context.evaluateScript("typeof window.__native.handlers['\(action)'] === 'function'")?
            .toBool() ?? false
    }

    // MARK: - Installation

    /// A next button exists on the lock screen only if the page registered a
    /// `nexttrack` handler — WebKit's own default command set has none. This is
    /// the entire mechanism, so it gets the most direct test.
    func testRegistersTheTrackHandlersTheLockScreenNeeds() throws {
        let context = try context()

        XCTAssertTrue(nativeHandlerExists("nexttrack", in: context))
        XCTAssertTrue(nativeHandlerExists("previoustrack", in: context))
        XCTAssertTrue(nativeHandlerExists("play", in: context))
        XCTAssertTrue(nativeHandlerExists("pause", in: context))
        XCTAssertTrue(nativeHandlerExists("seekto", in: context))
    }

    /// Skip-forward and skip-back occupy the same two lock-screen slots as the
    /// track buttons, so they must be explicitly cleared or next/previous never
    /// appear at all.
    func testClearsTheSkipHandlersThatWouldStealTheTrackButtonSlots() throws {
        let context = try context()

        XCTAssertFalse(nativeHandlerExists("seekforward", in: context))
        XCTAssertFalse(nativeHandlerExists("seekbackward", in: context))
    }

    // MARK: - The lock

    /// The page tries to take the next button back on every track change. If it
    /// wins, the lock screen advances YouTube's playlist instead of Shir's queue.
    func testThePageCannotReplaceOwnedHandlers() throws {
        let context = try context()

        context.evaluateScript(
            """
            window.__pageHandlerRan = false;
            navigator.mediaSession.setActionHandler('nexttrack', function () {
                window.__pageHandlerRan = true;
            });
            window.__native.handlers['nexttrack']();
            """
        )

        XCTAssertEqual(context.evaluateScript("window.__pageHandlerRan")?.toBool(), false,
                       "the page's nexttrack handler must never be the one that runs")
    }

    /// Swallowing rather than throwing is deliberate: YouTube's bundle is strict
    /// mode, and a throw during player init risks breaking playback outright. A
    /// blank lock screen is a much better failure than no music.
    func testRejectedWritesDoNotThrow() throws {
        let context = try context()

        context.evaluateScript(
            """
            window.__threw = false;
            try { navigator.mediaSession.setActionHandler('play', function () {}); }
            catch (e) { window.__threw = true; }
            """
        )

        XCTAssertEqual(context.evaluateScript("window.__threw")?.toBool(), false)
    }

    /// Actions Shir does not claim should still reach the page — there is no
    /// reason to break YouTube's own features.
    func testUnownedActionsStillPassThrough() throws {
        let context = try context()

        context.evaluateScript(
            "navigator.mediaSession.setActionHandler('skipad', function () {});"
        )

        XCTAssertTrue(nativeHandlerExists("skipad", in: context),
                      "only the actions Shir owns should be blocked")
    }

    /// Without this the lock screen shows the advertiser's name and artwork
    /// during a pre-roll, because YouTube sets its metadata for the ad.
    func testThePageCannotOverwriteMetadata() throws {
        let context = try context()

        context.evaluateScript(
            """
            window.__shirMedia.setMetadata('Real Song', 'Real Artist', '', 'https://i.ytimg.com/vi/x/hqdefault.jpg');
            navigator.mediaSession.metadata = new window.MediaMetadata({
                title: 'Fried Pickle Pub Burger (:06)', artist: "Culver's", album: '', artwork: []
            });
            """
        )

        XCTAssertEqual(context.evaluateScript("window.__native.metadata.title")?.toString(),
                       "Real Song", "an advertiser must not reach the lock screen")
        XCTAssertEqual(context.evaluateScript("window.__native.metadata.artist")?.toString(),
                       "Real Artist")
    }

    // MARK: - Reporting

    func testPressingNextReportsToSwiftWithoutActingLocally() throws {
        let context = try context()

        context.evaluateScript(
            """
            window.__playCalled = false;
            window.__shir.play = function () { window.__playCalled = true; };
            window.__native.handlers['nexttrack']();
            """
        )

        let action = context.evaluateScript("window.__sent[window.__sent.length - 1].action")?.toString()
        XCTAssertEqual(action, "next")
        XCTAssertEqual(context.evaluateScript("window.__playCalled")?.toBool(), false,
                       "next must be Shir's queue advancing, not the page's")
    }

    /// The remote message must go out BEFORE the handler acts on the player.
    /// Acting first leaves the anti-un-pause correction resting on YouTube's
    /// player dispatching its state event asynchronously inside pauseVideo()
    /// — an undocumented internal. Message-first makes the ordering
    /// structural: Swift's notePause() always beats the "paused" state event.
    func testPausePostsTheRemoteMessageBeforeActingOnThePlayer() throws {
        let context = try context()

        context.evaluateScript(
            """
            window.__order = [];
            window.webkit.messageHandlers.shir.postMessage = function (m) {
                if (m.kind === 'remote') { window.__order.push('sent:' + m.action); }
            };
            window.__shir.pause = function () { window.__order.push('acted'); };
            window.__native.handlers['pause']();
            """
        )

        XCTAssertEqual(context.evaluateScript("window.__order.join(',')")?.toString(),
                       "sent:pause,acted")
    }

    /// seekto is notify-only: an in-page pre-seek applied the same absolute
    /// time twice, and the second application landed a bridge round trip later
    /// against a moving playhead — an audible snap-back on every scrub.
    func testSeekOnlyNotifiesAndNeverSeeksInPage() throws {
        let context = try context()

        context.evaluateScript(
            """
            window.__seeked = false;
            window.__shir.seek = function () { window.__seeked = true; };
            window.__native.handlers['seekto']({ seekTime: 42 });
            """
        )

        XCTAssertEqual(context.evaluateScript("window.__seeked")?.toBool(), false)
        XCTAssertEqual(context.evaluateScript("window.__sent[window.__sent.length - 1].action")?.toString(), "seek")
        XCTAssertEqual(context.evaluateScript("window.__sent[window.__sent.length - 1].time")?.toInt32(), 42)
    }

    /// The web view outlives the engine's stop(), so a stale card press must
    /// not restart the stopped video from inside the page. Deactivation makes
    /// handlers report-only — Swift keeps the decision — and a new track's
    /// metadata push re-arms them.
    func testDeactivationMakesHandlersReportOnlyUntilTheNextTrack() throws {
        let context = try context()

        context.evaluateScript(
            """
            window.__played = 0;
            window.__shir.play = function () { window.__played += 1; };
            window.__shirMedia.deactivate();
            window.__native.handlers['play']();
            """
        )

        XCTAssertEqual(context.evaluateScript("window.__played")?.toInt32(), 0,
                       "a deactivated session must not act on the player")
        XCTAssertEqual(context.evaluateScript("window.__sent[window.__sent.length - 1].action")?.toString(),
                       "play", "…but Swift must still hear about the press")
        XCTAssertTrue(context.evaluateScript("window.__native.metadata === null")?.toBool() ?? false,
                      "deactivation clears the card")

        context.evaluateScript(
            """
            window.__shirMedia.setMetadata('Next Song', 'Artist', '', '');
            window.__native.handlers['play']();
            """
        )
        XCTAssertEqual(context.evaluateScript("window.__played")?.toInt32(), 1,
                       "the next track's metadata push re-arms the handlers")
    }

    /// The assignment lock alone is not enough: WebCore propagates in-place
    /// attribute mutation on the live MediaMetadata straight to the lock
    /// screen, no setter involved. The getter must hand out a copy.
    func testMutatingTheMetadataGettersResultChangesNothing() throws {
        let context = try context()

        context.evaluateScript(
            """
            window.__shirMedia.setMetadata('Real Song', 'Real Artist', '', '');
            var leaked = navigator.mediaSession.metadata;
            if (leaked) { leaked.title = "Culver's"; }
            """
        )

        XCTAssertEqual(context.evaluateScript("window.__native.metadata.title")?.toString(),
                       "Real Song", "mutation through the getter must never reach the OS")
    }

    func testMetadataReachesTheNativeLayer() throws {
        let context = try context()

        context.evaluateScript(
            "window.__shirMedia.setMetadata('Song', 'Artist', '', 'https://i.ytimg.com/vi/x/hqdefault.jpg');"
        )

        XCTAssertEqual(context.evaluateScript("window.__native.metadata.title")?.toString(), "Song")
        XCTAssertEqual(context.evaluateScript("window.__native.metadata.artwork.length")?.toInt32(), 1)
    }

    func testPositionStateIsPushedForTheScrubber() throws {
        let context = try context()
        context.evaluateScript("window.__shirMedia.pushPosition();")

        XCTAssertEqual(context.evaluateScript("window.__native.position.duration")?.toInt32(), 213)
        XCTAssertEqual(context.evaluateScript("window.__native.position.position")?.toInt32(), 12)
    }
}
