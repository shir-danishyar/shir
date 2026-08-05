import XCTest
@testable import RiffKit

final class YouTubeSearchClientTests: XCTestCase {
    private let searchJSON = """
    {
      "nextPageToken": "PAGE2",
      "items": [
        {
          "id": { "kind": "youtube#video", "videoId": "abc123" },
          "snippet": {
            "title": "Track &amp; Field &quot;Live&quot;",
            "channelTitle": "Some Artist&#39;s Channel",
            "thumbnails": {
              "default": { "url": "https://i.ytimg.com/vi/abc123/default.jpg" },
              "medium":  { "url": "https://i.ytimg.com/vi/abc123/mqdefault.jpg" },
              "high":    { "url": "https://i.ytimg.com/vi/abc123/hqdefault.jpg" }
            }
          }
        },
        {
          "id": { "kind": "youtube#channel" },
          "snippet": {
            "title": "A Channel",
            "channelTitle": "Channel",
            "thumbnails": { "default": { "url": "https://i.ytimg.com/x.jpg" } }
          }
        }
      ]
    }
    """

    private let videosJSON = """
    { "items": [ { "id": "abc123", "contentDetails": { "duration": "PT3M42S" } } ] }
    """

    func testSearchParsesResultsAndDecodesEntities() async throws {
        let http = StubHTTPClient(responses: [.init(json: searchJSON), .init(json: videosJSON)])
        let client = YouTubeSearchClient(http: http, apiKeyProvider: { "TESTKEY" })

        let page = try await client.search(query: "some song")

        XCTAssertEqual(page.videos.count, 1, "non-video results must be dropped")
        let video = try XCTUnwrap(page.videos.first)
        XCTAssertEqual(video.id, "abc123")
        XCTAssertEqual(video.title, #"Track & Field "Live""#)
        XCTAssertEqual(video.channelTitle, "Some Artist's Channel")
        XCTAssertEqual(video.thumbnailURL?.absoluteString, "https://i.ytimg.com/vi/abc123/hqdefault.jpg")
        XCTAssertEqual(video.duration, 222)
        XCTAssertEqual(page.nextPageToken, "PAGE2")
    }

    func testSearchRequestsOnlyEmbeddableMusicVideos() async throws {
        let http = StubHTTPClient(responses: [.init(json: searchJSON), .init(json: videosJSON)])
        let client = YouTubeSearchClient(http: http, apiKeyProvider: { "TESTKEY" })

        _ = try await client.search(query: "jazz")

        let url = try XCTUnwrap(http.requestedURLs.first?.absoluteString)
        XCTAssertTrue(url.contains("videoEmbeddable=true"), "only embeddable videos may be surfaced")
        XCTAssertTrue(url.contains("videoCategoryId=10"))
        XCTAssertTrue(url.contains("type=video"))
    }

    func testSearchResultConvertsToTrack() async throws {
        let http = StubHTTPClient(responses: [.init(json: searchJSON), .init(json: videosJSON)])
        let client = YouTubeSearchClient(http: http, apiKeyProvider: { "TESTKEY" })

        let page = try await client.search(query: "x")
        let track = try XCTUnwrap(page.videos.first).track

        XCTAssertEqual(track.id, "yt:abc123")
        XCTAssertEqual(track.source, .youtube(videoID: "abc123"))
        XCTAssertEqual(track.duration, 222)
        // Was false while the app targeted the App Store. Both sources now play
        // in the background — see MediaSource and CLAUDE.md §2.
        XCTAssertTrue(track.source.supportsBackgroundPlayback)
    }

    func testMissingAPIKeyIsReportedBeforeAnyNetworkCall() async {
        let http = StubHTTPClient(responses: [])
        let client = YouTubeSearchClient(http: http, apiKeyProvider: { nil })

        do {
            _ = try await client.search(query: "anything")
            XCTFail("expected a missingAPIKey error")
        } catch let error as YouTubeError {
            XCTAssertEqual(error, .missingAPIKey)
            XCTAssertTrue(http.requestedURLs.isEmpty)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testBlankQueryShortCircuits() async throws {
        let http = StubHTTPClient(responses: [])
        let client = YouTubeSearchClient(http: http, apiKeyProvider: { "TESTKEY" })

        let page = try await client.search(query: "   ")
        XCTAssertTrue(page.videos.isEmpty)
        XCTAssertTrue(http.requestedURLs.isEmpty)
    }

    func testQuotaExceededIsDistinguishedFromOtherFailures() {
        let body = Data("""
        { "error": { "code": 403, "message": "quota", "errors": [ { "reason": "quotaExceeded" } ] } }
        """.utf8)

        XCTAssertEqual(YouTubeSearchClient.error(status: 403, body: body), .quotaExceeded)
    }

    func testForbiddenWithoutQuotaReasonSurfacesMessage() {
        let body = Data("""
        { "error": { "code": 403, "message": "API key not valid", "errors": [ { "reason": "badRequest" } ] } }
        """.utf8)

        XCTAssertEqual(YouTubeSearchClient.error(status: 403, body: body), .forbidden("API key not valid"))
    }

    func testSearchStillReturnsResultsWhenDurationLookupFails() async throws {
        let http = StubHTTPClient(responses: [.init(json: searchJSON), .init(json: "{}", statusCode: 500)])
        let client = YouTubeSearchClient(http: http, apiKeyProvider: { "TESTKEY" })

        let page = try await client.search(query: "x")

        XCTAssertEqual(page.videos.count, 1, "a failed duration lookup must not lose the search results")
        XCTAssertNil(page.videos.first?.duration)
    }
}

final class ISO8601DurationTests: XCTestCase {
    func testParsesCommonYouTubeDurations() {
        XCTAssertEqual(ISO8601Duration.seconds(from: "PT4M13S"), 253)
        XCTAssertEqual(ISO8601Duration.seconds(from: "PT1H2M3S"), 3_723)
        XCTAssertEqual(ISO8601Duration.seconds(from: "PT45S"), 45)
        XCTAssertEqual(ISO8601Duration.seconds(from: "PT2H"), 7_200)
        XCTAssertEqual(ISO8601Duration.seconds(from: "P1DT30S"), 86_430)
    }

    func testRejectsMalformedInput() {
        XCTAssertNil(ISO8601Duration.seconds(from: "4M13S"), "missing the P prefix")
        XCTAssertNil(ISO8601Duration.seconds(from: "PT4M13"), "trailing digits with no unit")
        XCTAssertNil(ISO8601Duration.seconds(from: ""))
        XCTAssertNil(ISO8601Duration.seconds(from: "P"))
    }

    func testFormatsPlaybackTime() {
        XCTAssertEqual(TimeInterval(0).formattedPlaybackTime, "0:00")
        XCTAssertEqual(TimeInterval(65).formattedPlaybackTime, "1:05")
        XCTAssertEqual(TimeInterval(3_725).formattedPlaybackTime, "1:02:05")
        XCTAssertEqual(TimeInterval(-1).formattedPlaybackTime, "--:--")
        XCTAssertEqual(TimeInterval.infinity.formattedPlaybackTime, "--:--")
    }
}
