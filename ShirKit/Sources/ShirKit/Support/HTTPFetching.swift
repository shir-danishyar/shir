import Foundation

/// Network seam so the YouTube client can be tested without a live API key.
public protocol HTTPFetching: Sendable {
    func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

extension URLSession: HTTPFetching {
    public func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await data(for: request, delegate: nil)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}

/// Records requests and replays canned responses. Used by the test suite.
public final class StubHTTPClient: HTTPFetching, @unchecked Sendable {
    public struct Response {
        public let data: Data
        public let statusCode: Int

        public init(data: Data, statusCode: Int = 200) {
            self.data = data
            self.statusCode = statusCode
        }

        public init(json: String, statusCode: Int = 200) {
            self.init(data: Data(json.utf8), statusCode: statusCode)
        }
    }

    public private(set) var requestedURLs: [URL] = []
    private var responses: [Response]

    public init(responses: [Response]) {
        self.responses = responses
    }

    public func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if let url = request.url { requestedURLs.append(url) }
        guard !responses.isEmpty else { throw URLError(.resourceUnavailable) }
        let next = responses.removeFirst()
        let http = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.invalid")!,
            statusCode: next.statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (next.data, http)
    }
}
