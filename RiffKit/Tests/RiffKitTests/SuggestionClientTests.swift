import XCTest
@testable import RiffKit

final class SuggestionClientTests: XCTestCase {

    private func client(responding responses: [StubHTTPClient.Response]) -> (SuggestionClient, StubHTTPClient) {
        let http = StubHTTPClient(responses: responses)
        let client = SuggestionClient(
            http: http,
            locale: .init(language: "en", region: "US")
        )
        return (client, http)
    }

    func testParsesSuggestionsFromARealResponseShape() async {
        let (client, _) = self.client(responding: [
            .init(json: #"["afghan",["afghan songs","afghan family vlog","afghani song"]]"#)
        ])

        let suggestions = await client.suggestions(for: "afghan")

        XCTAssertEqual(suggestions, ["afghan songs", "afghan family vlog", "afghani song"])
    }

    /// A query with no suggestions comes back as a TWO element array. Anything
    /// that reaches for index 2 crashes here, which is why this case has a test.
    func testHandlesTheEmptySuggestionShape() async {
        let (client, _) = client(responding: [.init(json: #"["zzzqqq",[]]"#)])
        let suggestions = await client.suggestions(for: "zzzqqq")
        XCTAssertTrue(suggestions.isEmpty)
    }

    func testNonLatinSuggestionsSurviveDecoding() async {
        let (client, _) = client(responding: [
            .init(json: #"["بنیامین",["بنیامین بهادری","بنیامین جدید"]]"#)
        ])

        let suggestions = await client.suggestions(for: "بنیامین")

        XCTAssertEqual(suggestions, ["بنیامین بهادری", "بنیامین جدید"])
    }

    func testBlankQueriesNeverHitTheNetwork() async {
        let (client, http) = self.client(responding: [.init(json: "[]")])

        // Split out: `await` inside an assertion's autoclosure doesn't compile.
        let suggestions = await client.suggestions(for: "   ")
        XCTAssertTrue(suggestions.isEmpty)
        XCTAssertTrue(http.requestedURLs.isEmpty, "a blank query should short-circuit")
    }

    /// Suggestions are a convenience. Every failure path returns empty rather
    /// than throwing, so a mid-word network blip cannot raise an error banner.
    func testFailuresAreSilent() async {
        let (httpError, _) = client(responding: [.init(json: "[]", statusCode: 500)])
        let onHTTPError = await httpError.suggestions(for: "anything")
        XCTAssertTrue(onHTTPError.isEmpty, "a 500 should be silent")

        let (garbage, _) = client(responding: [.init(json: "this is not json")])
        let onGarbage = await garbage.suggestions(for: "anything")
        XCTAssertTrue(onGarbage.isEmpty, "unparseable data should be silent")

        let (unexpectedShape, _) = client(responding: [.init(json: #"{"suggestions":["a"]}"#)])
        let onWrongShape = await unexpectedShape.suggestions(for: "anything")
        XCTAssertTrue(onWrongShape.isEmpty, "an unexpected shape should be silent")

        let (exhausted, _) = client(responding: [])
        let onTransportFailure = await exhausted.suggestions(for: "anything")
        XCTAssertTrue(onTransportFailure.isEmpty, "a transport failure should be silent")
    }

    /// Every one of these parameters is load-bearing: `ds` scopes to YouTube,
    /// `oe` stops non-Latin scripts arriving as mojibake, `client=firefox`
    /// selects the flat-array response shape, and `gl` measurably changes what
    /// comes back.
    func testRequestCarriesEveryRequiredParameter() async {
        let (client, http) = self.client(responding: [.init(json: #"["x",[]]"#)])
        _ = await client.suggestions(for: "ahmad zahir")

        let url = try? XCTUnwrap(http.requestedURLs.first)
        let items = URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })

        XCTAssertEqual(url?.host, "suggestqueries-clients6.youtube.com")
        XCTAssertEqual(values["client"], "firefox")
        XCTAssertEqual(values["ds"], "yt")
        XCTAssertEqual(values["oe"], "utf-8")
        XCTAssertEqual(values["hl"], "en")
        XCTAssertEqual(values["gl"], "US")
        XCTAssertEqual(values["q"], "ahmad zahir")
    }
}
