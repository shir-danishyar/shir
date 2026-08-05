import Foundation

/// YouTube's search autocomplete — the suggestions that appear as you type.
///
/// This is the endpoint YouTube's own search box uses. It needs no API key, no
/// account and no attestation, and unlike the InnerTube search it is a plain
/// GET small enough to fire on every keystroke.
///
/// It runs natively rather than inside the search web view, even though the
/// endpoint's CORS policy would allow an in-page fetch. Three reasons, in order
/// of weight: the web view has to finish loading m.youtube.com before any
/// script can run, so the first keystroke of a session would block on a full
/// page load; that web view is a single `@MainActor` instance already busy with
/// the ~119KB search; and native code is testable here on macOS in
/// milliseconds, which the web-view path is not.
public struct SuggestionClient: Sendable {
    private let http: HTTPFetching
    private let locale: SuggestionLocale

    public struct SuggestionLocale: Sendable {
        public let language: String
        public let region: String

        public init(language: String, region: String) {
            self.language = language
            self.region = region
        }

        /// `gl` measurably changes what comes back, so it is worth passing the
        /// real one rather than hardcoding US.
        public static var current: SuggestionLocale {
            SuggestionLocale(
                language: Locale.current.language.languageCode?.identifier ?? "en",
                region: Locale.current.region?.identifier ?? "US"
            )
        }
    }

    public init(http: HTTPFetching = URLSession.shared, locale: SuggestionLocale = .current) {
        self.http = http
        self.locale = locale
    }

    /// Suggestions for a partial query, most relevant first.
    ///
    /// Returns an empty array rather than throwing on anything that isn't a
    /// clean success. A failed suggestion lookup must be invisible — the user
    /// is mid-word, and an error banner for a feature they didn't ask for is
    /// worse than no suggestions.
    public func suggestions(for query: String) async -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = makeURL(query: trimmed) else { return [] }

        guard let (data, response) = try? await http.fetch(URLRequest(url: url)),
              response.statusCode == 200
        else { return [] }

        return Self.parse(data)
    }

    private func makeURL(query: String) -> URL? {
        var components = URLComponents(string: "https://suggestqueries-clients6.youtube.com/complete/search")
        components?.queryItems = [
            // `firefox` returns a flat array of strings. The other client
            // values wrap the payload in JSONP or in per-item tuples.
            URLQueryItem(name: "client", value: "firefox"),
            // Scopes to YouTube. Without it these are Google Web suggestions.
            URLQueryItem(name: "ds", value: "yt"),
            // Mandatory. Without it non-Latin scripts come back in a legacy
            // charset as mojibake, which matters a lot for this library.
            URLQueryItem(name: "oe", value: "utf-8"),
            URLQueryItem(name: "hl", value: locale.language),
            URLQueryItem(name: "gl", value: locale.region),
            URLQueryItem(name: "q", value: query),
        ]
        return components?.url
    }

    /// The response is `["query", ["suggestion", ...]]`.
    ///
    /// An empty result is a **two**-element array, so anything that reaches for
    /// index 2 or beyond crashes on the no-suggestions case.
    static func parse(_ data: Data) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [Any],
              root.count > 1,
              let suggestions = root[1] as? [String]
        else { return [] }
        return suggestions
    }
}
