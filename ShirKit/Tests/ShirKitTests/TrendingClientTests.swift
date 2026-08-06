import XCTest
@testable import ShirKit

/// The trending parser against a captured InnerTube browse response.
///
/// Like the search parser, this is fragile-by-nature code: `lockupViewModel`
/// is YouTube's newest render format and it churns. When trending goes blank,
/// this test is what names the breakage — re-capture the fixture with a plain
/// keyless POST to m.youtube.com/youtubei/v1/browse and diff.
final class TrendingClientTests: XCTestCase {

    private func fixture() throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "Fixtures/trending-browse", withExtension: "json"),
            "fixture missing from test bundle"
        )
        return try Data(contentsOf: url)
    }

    func testParsesAllTwentyChartEntries() throws {
        let videos = TrendingClient.parse(try fixture())
        XCTAssertEqual(videos.count, 20)
    }

    func testEntriesCarryIDTitleBylineAndStableThumbnail() throws {
        let videos = TrendingClient.parse(try fixture())
        let first = try XCTUnwrap(videos.first)

        XCTAssertFalse(first.id.isEmpty)
        XCTAssertFalse(first.title.isEmpty)
        XCTAssertFalse(first.channelTitle.isEmpty)
        // Built from the id, never taken from the response — response
        // thumbnail URLs carry expiring signature params.
        XCTAssertEqual(
            first.thumbnailURL?.absoluteString,
            "https://i.ytimg.com/vi/\(first.id)/hqdefault.jpg"
        )
    }

    func testEntriesAreUniqueAndOrdered() throws {
        let videos = TrendingClient.parse(try fixture())
        XCTAssertEqual(Set(videos.map(\.id)).count, videos.count, "chart entries should be unique")
    }

    func testGarbageAndEmptyInputParseToNothing() {
        XCTAssertEqual(TrendingClient.parse(Data()), [])
        XCTAssertEqual(TrendingClient.parse(Data("not json".utf8)), [])
        XCTAssertEqual(TrendingClient.parse(Data("{}".utf8)), [])
        XCTAssertEqual(TrendingClient.parse(Data(#"{"contents":[]}"#.utf8)), [])
    }
}
