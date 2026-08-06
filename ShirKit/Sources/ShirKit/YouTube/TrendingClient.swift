import Foundation

/// The charts that fill the Search tab before the user has typed anything.
///
/// Fetches YouTube's published music-chart playlists over a plain keyless
/// InnerTube `browse` — verified to need no API key, no cookies and no
/// visitorData, exactly like search and suggestions (PoToken gates only
/// `/player`). Runs natively rather than in a web view for the same reasons
/// `SuggestionClient` does: nothing about the response depends on page
/// context, and native code is testable on macOS in milliseconds.
///
/// The playlist ids are YouTube Charts' own published playlists, stable for
/// years, pinned to the *global* editions deliberately: the chart country
/// picker has no entry for most of the world (and `gl` does not switch it),
/// so global is the honest default rather than someone else's country.
public struct TrendingClient: Sendable {
    public struct Section: Identifiable, Hashable, Sendable {
        public let title: String
        public let videos: [YouTubeVideo]
        public var id: String { title }

        public init(title: String, videos: [YouTubeVideo]) {
            self.title = title
            self.videos = videos
        }
    }

    /// Section titles follow the reference app; the playlists behind them are
    /// YouTube Charts' "Top 100 Music Videos Global" and "Daily Top Music
    /// Videos Global".
    private static let charts: [(title: String, playlistID: String)] = [
        ("Top Tracks", "PL4fGSI1pDJn5kI81J1fYWK5eZRl1zJ5kM"),
        ("Top New Tracks", "PL4fGSI1pDJn6t3TXLGiiJdD-sZbrG3tG0"),
    ]

    private let http: HTTPFetching

    public init(http: HTTPFetching = URLSession.shared) {
        self.http = http
    }

    /// Both chart sections, fetched concurrently. Failures are silent and
    /// partial results are fine — an empty array means the caller keeps
    /// showing its plain idle state, which is strictly better than an error
    /// banner for content the user never asked for.
    public func sections() async -> [Section] {
        await withTaskGroup(of: (Int, Section?).self) { group in
            for (index, chart) in Self.charts.enumerated() {
                group.addTask {
                    (index, await section(title: chart.title, playlistID: chart.playlistID))
                }
            }
            var found: [(Int, Section)] = []
            for await (index, section) in group {
                if let section { found.append((index, section)) }
            }
            return found.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private func section(title: String, playlistID: String) async -> Section? {
        guard let request = Self.makeRequest(playlistID: playlistID),
              let (data, response) = try? await http.fetch(request),
              response.statusCode == 200
        else { return nil }

        let videos = Self.parse(data)
        return videos.isEmpty ? nil : Section(title: title, videos: videos)
    }

    private static func makeRequest(playlistID: String) -> URLRequest? {
        guard let url = URL(string: "https://m.youtube.com/youtubei/v1/browse?prettyPrint=false") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "context": [
                "client": [
                    "clientName": "MWEB",
                    "clientVersion": "2.20250101.00.00",
                ]
            ],
            // "VL" is how InnerTube names a playlist's browse page.
            "browseId": "VL\(playlistID)",
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    // MARK: - Parsing

    /// Walks the whole response for `lockupViewModel` video entries instead of
    /// hardcoding the nesting above them. The wrapper hierarchy
    /// (`singleColumnBrowseResultsRenderer` → tabs → sections …) is exactly
    /// the part YouTube reshuffles between clients and releases; the lockup
    /// items are the part that has to exist for the page to render at all.
    static func parse(_ data: Data) -> [YouTubeVideo] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var videos: [YouTubeVideo] = []
        var seen = Set<String>()
        collectLockups(in: root, videos: &videos, seen: &seen)
        return videos
    }

    private static func collectLockups(in node: Any, videos: inout [YouTubeVideo], seen: inout Set<String>) {
        if let dictionary = node as? [String: Any] {
            if let lockup = dictionary["lockupViewModel"] as? [String: Any],
               let video = video(fromLockup: lockup),
               seen.insert(video.id).inserted {
                videos.append(video)
            }
            for value in dictionary.values {
                collectLockups(in: value, videos: &videos, seen: &seen)
            }
        } else if let array = node as? [Any] {
            for value in array {
                collectLockups(in: value, videos: &videos, seen: &seen)
            }
        }
    }

    private static func video(fromLockup lockup: [String: Any]) -> YouTubeVideo? {
        guard lockup["contentType"] as? String == "LOCKUP_CONTENT_TYPE_VIDEO",
              let videoID = lockup["contentId"] as? String,
              let metadata = lockup["metadata"] as? [String: Any],
              let lockupMetadata = metadata["lockupMetadataViewModel"] as? [String: Any],
              let titleNode = lockupMetadata["title"] as? [String: Any],
              let title = titleNode["content"] as? String
        else { return nil }

        // First metadata row, first part is the byline ("Artist and 2 more").
        let byline = (((lockupMetadata["metadata"] as? [String: Any])?["contentMetadataViewModel"]
            as? [String: Any])?["metadataRows"] as? [[String: Any]])?
            .first
            .flatMap { ($0["metadataParts"] as? [[String: Any]])?.first }
            .flatMap { ($0["text"] as? [String: Any])?["content"] as? String }

        return YouTubeVideo(
            id: videoID,
            title: title,
            channelTitle: byline ?? "",
            // Built rather than read from the response: response thumbnails
            // carry expiring signature params that must never be persisted
            // (CLAUDE.md §6); this form does not expire.
            thumbnailURL: URL(string: "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg")
        )
    }
}
