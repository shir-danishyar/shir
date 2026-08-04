import Foundation

public struct YouTubeVideo: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let channelTitle: String
    public let thumbnailURL: URL?
    public var duration: TimeInterval?

    public init(id: String, title: String, channelTitle: String, thumbnailURL: URL?, duration: TimeInterval? = nil) {
        self.id = id
        self.title = title
        self.channelTitle = channelTitle
        self.thumbnailURL = thumbnailURL
        self.duration = duration
    }

    public var track: Track {
        .youtube(
            videoID: id,
            title: title,
            channelTitle: channelTitle,
            artworkURL: thumbnailURL,
            duration: duration
        )
    }
}

public struct YouTubeSearchPage: Sendable {
    public let videos: [YouTubeVideo]
    public let nextPageToken: String?
}

public enum YouTubeError: LocalizedError, Equatable {
    case missingAPIKey
    case quotaExceeded
    case forbidden(String)
    case http(status: Int, message: String)
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add a YouTube Data API key in Settings to search."
        case .quotaExceeded:
            return "This API key is out of daily quota. It resets at midnight Pacific time."
        case let .forbidden(message):
            return message.isEmpty ? "YouTube refused the request." : message
        case let .http(status, message):
            return message.isEmpty ? "YouTube returned HTTP \(status)." : message
        case let .decoding(message):
            return "Unexpected response from YouTube: \(message)"
        }
    }
}

/// Searches YouTube through the official Data API v3.
///
/// Two deliberate filters: `videoEmbeddable=true` so the app only ever surfaces
/// videos their owner has allowed to play in an embedded player, and
/// `videoCategoryId=10` to keep results in the Music category. Together they
/// keep the app inside the YouTube API Services Terms.
public struct YouTubeSearchClient: Sendable {
    private let http: HTTPFetching
    private let apiKeyProvider: @Sendable () -> String?
    private let baseURL = URL(string: "https://www.googleapis.com/youtube/v3")!

    public init(http: HTTPFetching = URLSession.shared, apiKeyProvider: @escaping @Sendable () -> String?) {
        self.http = http
        self.apiKeyProvider = apiKeyProvider
    }

    public func search(query: String, pageToken: String? = nil, maxResults: Int = 25) async throws -> YouTubeSearchPage {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return YouTubeSearchPage(videos: [], nextPageToken: nil) }
        guard let key = apiKeyProvider()?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw YouTubeError.missingAPIKey
        }

        var items = [URLQueryItem(name: "part", value: "snippet"),
                     URLQueryItem(name: "type", value: "video"),
                     URLQueryItem(name: "videoEmbeddable", value: "true"),
                     URLQueryItem(name: "videoCategoryId", value: "10"),
                     URLQueryItem(name: "maxResults", value: String(max(1, min(maxResults, 50)))),
                     URLQueryItem(name: "q", value: trimmed),
                     URLQueryItem(name: "key", value: key)]
        if let pageToken, !pageToken.isEmpty {
            items.append(URLQueryItem(name: "pageToken", value: pageToken))
        }

        let payload: SearchResponse = try await get(path: "search", queryItems: items)
        let videos = payload.items.compactMap { item -> YouTubeVideo? in
            guard let videoID = item.id.videoId else { return nil }
            return YouTubeVideo(
                id: videoID,
                title: item.snippet.title.decodingHTMLEntities(),
                channelTitle: item.snippet.channelTitle.decodingHTMLEntities(),
                thumbnailURL: item.snippet.thumbnails.best
            )
        }

        // The search endpoint does not return durations; one extra call fills
        // them in for the whole page and costs a single quota unit.
        let withDurations = (try? await annotateDurations(videos)) ?? videos
        return YouTubeSearchPage(videos: withDurations, nextPageToken: payload.nextPageToken)
    }

    /// Looks up durations for a page of results in one batched request.
    public func annotateDurations(_ videos: [YouTubeVideo]) async throws -> [YouTubeVideo] {
        guard !videos.isEmpty else { return [] }
        guard let key = apiKeyProvider(), !key.isEmpty else { throw YouTubeError.missingAPIKey }

        let items = [URLQueryItem(name: "part", value: "contentDetails"),
                     URLQueryItem(name: "id", value: videos.map(\.id).joined(separator: ",")),
                     URLQueryItem(name: "key", value: key)]
        let payload: VideosResponse = try await get(path: "videos", queryItems: items)
        let durations = Dictionary(
            uniqueKeysWithValues: payload.items.map { ($0.id, ISO8601Duration.seconds(from: $0.contentDetails.duration)) }
        )
        return videos.map { video in
            var copy = video
            copy.duration = durations[video.id] ?? nil
            return copy
        }
    }

    // MARK: - Transport

    private func get<T: Decodable>(path: String, queryItems: [URLQueryItem]) async throws -> T {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = queryItems
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 20

        let (data, response) = try await http.fetch(request)
        guard (200..<300).contains(response.statusCode) else {
            throw Self.error(status: response.statusCode, body: data)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw YouTubeError.decoding(error.localizedDescription)
        }
    }

    /// Google returns a machine-readable `reason` that distinguishes an
    /// exhausted quota from a genuinely bad key — worth telling apart, because
    /// the fixes are completely different.
    static func error(status: Int, body: Data) -> YouTubeError {
        let payload = try? JSONDecoder().decode(APIErrorResponse.self, from: body)
        let message = payload?.error.message ?? ""
        let reason = payload?.error.errors?.first?.reason ?? ""

        if reason == "quotaExceeded" || reason == "dailyLimitExceeded" {
            return .quotaExceeded
        }
        if status == 403 {
            return .forbidden(message)
        }
        return .http(status: status, message: message)
    }
}

// MARK: - Wire format

private struct SearchResponse: Decodable {
    let nextPageToken: String?
    let items: [Item]

    struct Item: Decodable {
        let id: ID
        let snippet: Snippet

        struct ID: Decodable { let videoId: String? }
        struct Snippet: Decodable {
            let title: String
            let channelTitle: String
            let thumbnails: Thumbnails
        }
    }
}

private struct Thumbnails: Decodable {
    let medium: Thumbnail?
    let high: Thumbnail?
    let `default`: Thumbnail?

    struct Thumbnail: Decodable { let url: URL }

    var best: URL? { (high ?? medium ?? `default`)?.url }
}

private struct VideosResponse: Decodable {
    let items: [Item]
    struct Item: Decodable {
        let id: String
        let contentDetails: ContentDetails
        struct ContentDetails: Decodable { let duration: String }
    }
}

private struct APIErrorResponse: Decodable {
    let error: Payload
    struct Payload: Decodable {
        let message: String?
        let errors: [Detail]?
        struct Detail: Decodable { let reason: String? }
    }
}

extension String {
    /// YouTube returns snippet text with HTML entities still escaped.
    func decodingHTMLEntities() -> String {
        var output = self
        let replacements = [
            ("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
            ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "),
        ]
        for (entity, character) in replacements {
            output = output.replacingOccurrences(of: entity, with: character)
        }
        return output
    }
}
