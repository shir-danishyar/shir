import JavaScriptCore
import XCTest
@testable import RiffKit

/// Tests the injected JavaScript by running it in a `JSContext`.
///
/// This is the most valuable suite in the project. The ad-strip and the search
/// parser are the code most likely to break — YouTube reshapes its responses
/// every few months — and without these, a breakage presents as "there's an ad"
/// or "search returns nothing" with no clue why. Here it presents as a named
/// failing assertion, on macOS, in milliseconds.
///
/// `JavaScriptCore` is not a UI framework, so this does not violate RiffKit's
/// no-UI-imports rule.
final class PlayerScriptsTests: XCTestCase {

    // MARK: - Harness

    /// A context with a `window` and the given script evaluated into it.
    ///
    /// The scripts guard on `typeof window !== 'undefined'` so they work under
    /// both WebKit and JSContext; the shim here supplies the parts they touch.
    private func context(loading script: PlayerScripts) throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        var thrown: String?
        context.exceptionHandler = { _, exception in
            thrown = exception?.toString()
        }

        // Minimal browser shims. Deliberately not a full DOM — if a script
        // needs more than this, that is a signal it is doing too much.
        //
        // `fetch` and `XMLHttpRequest` have to be here even though no test
        // calls them: AdStrip patches both at load, and a missing global makes
        // the whole IIFE throw before it installs the interceptor the tests
        // actually exercise. That is fine in a real web view, where they always
        // exist, but the harness has to model it.
        context.evaluateScript(
            """
            var window = this;
            window.webkit = { messageHandlers: { riff: { postMessage: function () {} } } };
            var document = { querySelector: function () { return null; },
                             querySelectorAll: function () { return []; },
                             addEventListener: function () {},
                             createElement: function () { return {}; },
                             documentElement: null, head: null };
            var Document = { prototype: {} };
            window.addEventListener = function () {};
            window.setInterval = function () { return 0; };
            window.setTimeout = function () { return 0; };
            window.location = { href: 'https://m.youtube.com/watch?v=test', hostname: 'm.youtube.com' };
            window.fetch = function () { return Promise.resolve({ ok: true }); };
            window.Response = function (body) { this.body = body; };
            window.XMLHttpRequest = function () {};
            window.XMLHttpRequest.prototype = {
                open: function () {}, send: function () {}, addEventListener: function () {}
            };
            """
        )

        context.evaluateScript(try script.source)
        if let thrown { XCTFail("\(script.rawValue).js threw: \(thrown)") }
        return context
    }

    // MARK: - Search projection

    func testSearchProjectionExtractsVideosFromAMobileResponse() throws {
        let context = try context(loading: .search)

        // Trimmed to the shape that matters, from a real m.youtube.com response.
        let payload = """
        {"contents":{"sectionListRenderer":{"contents":[{"itemSectionRenderer":{"contents":[
          {"videoWithContextRenderer":{
            "videoId":"FGBhQbmPwH8",
            "headline":{"runs":[{"text":"Daft Punk - One More Time"}]},
            "shortBylineText":{"runs":[{"text":"Daft Punk"}]},
            "lengthText":{"simpleText":"5:22"},
            "thumbnail":{"thumbnails":[{"url":"https://i.ytimg.com/vi/FGBhQbmPwH8/hq720.jpg?sqp=EXPIRES"}]}
          }},
          {"videoWithContextRenderer":{
            "videoId":"9bZkp7q19f0",
            "headline":{"simpleText":"Gangnam Style"},
            "shortBylineText":{"runs":[{"text":"officialpsy"}]},
            "lengthText":{"simpleText":"4:12"}
          }}
        ]}}]}}}
        """

        let results = try project(payload, in: context)

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0]["id"] as? String, "FGBhQbmPwH8")
        XCTAssertEqual(results[0]["title"] as? String, "Daft Punk - One More Time")
        XCTAssertEqual(results[0]["channel"] as? String, "Daft Punk")
        XCTAssertEqual(results[0]["durationSeconds"] as? Double, 322)

        // simpleText and runs[] are both used by YouTube, inconsistently.
        XCTAssertEqual(results[1]["title"] as? String, "Gangnam Style")
        XCTAssertEqual(results[1]["durationSeconds"] as? Double, 252)
    }

    /// Response thumbnails carry expiring signature params, and these URLs get
    /// persisted into the library. The projection must substitute the stable
    /// form rather than pass the signed one through.
    func testSearchProjectionUsesUnsignedThumbnailURLs() throws {
        let context = try context(loading: .search)
        let payload = """
        {"contents":{"sectionListRenderer":{"contents":[{"itemSectionRenderer":{"contents":[
          {"videoRenderer":{"videoId":"abc123","title":{"simpleText":"x"},
           "thumbnail":{"thumbnails":[{"url":"https://i.ytimg.com/vi/abc123/hq720.jpg?sqp=SIGNED&rs=EXPIRES"}]}}}
        ]}}]}}}
        """

        let results = try project(payload, in: context)
        let thumbnail = try XCTUnwrap(results.first?["thumbnail"] as? String)

        XCTAssertEqual(thumbnail, "https://i.ytimg.com/vi/abc123/hqdefault.jpg")
        XCTAssertFalse(thumbnail.contains("sqp="), "a signed URL must never reach the library")
    }

    /// A live stream has no `lengthText`. That absence is the only signal, so
    /// it has to survive as nil rather than becoming zero.
    func testSearchProjectionLeavesLiveStreamsWithoutADuration() throws {
        let context = try context(loading: .search)
        let payload = """
        {"contents":{"sectionListRenderer":{"contents":[{"itemSectionRenderer":{"contents":[
          {"videoRenderer":{"videoId":"live1","title":{"simpleText":"Lofi radio"}}}
        ]}}]}}}
        """

        let results = try project(payload, in: context)
        XCTAssertEqual(results.count, 1)
        XCTAssertNil(results[0]["durationSeconds"] as? Double)
    }

    func testSearchProjectionIgnoresNonVideoItems() throws {
        let context = try context(loading: .search)
        let payload = """
        {"contents":{"sectionListRenderer":{"contents":[{"itemSectionRenderer":{"contents":[
          {"shelfRenderer":{"title":{"simpleText":"People also watched"}}},
          {"lockupViewModel":{"contentId":"RDxyz"}},
          {"videoRenderer":{"videoId":"real1","title":{"simpleText":"An actual song"}}}
        ]}}]}}}
        """

        let results = try project(payload, in: context)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0]["id"] as? String, "real1")
    }

    func testSearchProjectionHandlesAnEmptyResponse() throws {
        let context = try context(loading: .search)
        XCTAssertEqual(try project("{}", in: context).count, 0)
    }

    // MARK: - Ad stripping

    /// The whole ad blocker, in one assertion: these four keys must be gone.
    func testAdStripRemovesEveryAdKeyFromAPlayerResponse() throws {
        let context = try context(loading: .adStrip)

        let stripped = try strip(
            """
            {"adPlacements":[{"a":1}],"playerAds":[{"b":2}],"adSlots":[{"c":3}],
             "adBreakHeartbeatParams":"xyz",
             "videoDetails":{"videoId":"abc","title":"Real song"}}
            """,
            in: context
        )

        XCTAssertNil(stripped["adPlacements"])
        XCTAssertNil(stripped["playerAds"])
        XCTAssertNil(stripped["adSlots"])
        XCTAssertNil(stripped["adBreakHeartbeatParams"])

        // The point is removing ads, not damaging the response.
        let details = try XCTUnwrap(stripped["videoDetails"] as? [String: Any])
        XCTAssertEqual(details["videoId"] as? String, "abc")
        XCTAssertEqual(details["title"] as? String, "Real song")
    }

    /// `get_watch` nests the payload a level down. NouTube shipped this as a bug
    /// fix after missing it, so it is worth an explicit test.
    func testAdStripReachesTheNestedGetWatchPayload() throws {
        let context = try context(loading: .adStrip)

        let stripped = try strip(
            """
            [{"playerResponse":{"adPlacements":[{"a":1}],"videoDetails":{"videoId":"nested"}}}]
            """,
            in: context
        )

        let first = try XCTUnwrap((stripped["__array"] as? [Any])?.first as? [String: Any])
        let playerResponse = try XCTUnwrap(first["playerResponse"] as? [String: Any])
        XCTAssertNil(playerResponse["adPlacements"])
        XCTAssertEqual((playerResponse["videoDetails"] as? [String: Any])?["videoId"] as? String, "nested")
    }

    func testAdStripLeavesAnAdFreeResponseUntouched() throws {
        let context = try context(loading: .adStrip)
        let original = #"{"videoDetails":{"videoId":"clean"}}"#
        let stripped = try strip(original, in: context)
        XCTAssertEqual((stripped["videoDetails"] as? [String: Any])?["videoId"] as? String, "clean")
    }

    // MARK: - Helpers

    private func project(_ json: String, in context: JSContext) throws -> [[String: Any]] {
        let value = context.objectForKeyedSubscript("__riffProjectSearch")
            .call(withArguments: [try parse(json, in: context)])
        return (value?.toArray() as? [[String: Any]]) ?? []
    }

    /// Runs the script's own `stripDeep` via the `ytInitialPlayerResponse`
    /// interceptor it installs, which is the only entry point it exposes.
    /// Arrays come back wrapped so the assertions can reach them.
    private func strip(_ json: String, in context: JSContext) throws -> [String: Any] {
        context.evaluateScript(
            """
            var __input = \(json);
            window.ytInitialPlayerResponse = __input;
            var __result = window.ytInitialPlayerResponse;
            var __out = Array.isArray(__result) ? { __array: __result } : __result;
            """
        )
        return (context.objectForKeyedSubscript("__out").toDictionary() as? [String: Any]) ?? [:]
    }

    private func parse(_ json: String, in context: JSContext) throws -> Any {
        let value = context.evaluateScript("(\(json))")
        return try XCTUnwrap(value?.toObject())
    }
}
