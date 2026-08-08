import ShirKit
import WebKit

/// Searches YouTube with no API key and no account.
///
/// It runs YouTube's own search request from inside a real, first-party
/// `m.youtube.com` document. That buys three things a native `URLSession`
/// request cannot have:
///
/// - the page's cookies, including the HttpOnly ones JavaScript can't read
/// - `Origin` and `Referer` set by the browser, which page code cannot forge
/// - `ytcfg`'s `INNERTUBE_CONTEXT`, carrying server-minted `visitorData`,
///   `rolloutToken` and `appInstallData` — values that cannot be fabricated
///
/// No key is sent. The endpoint ignores the `key` parameter entirely; a bogus
/// key returns the same results as the real one, and yt-dlp and NewPipe both
/// stopped sending it. Search also needs no bot attestation — that gates the
/// *player* endpoint, not this one.
///
/// This deliberately owns a **separate** web view from `YouTubePlayerEngine`.
/// The player's `AdStrip.js` patches `window.fetch` and matches
/// `/youtubei/v1/search`, so sharing would route every search through the
/// ad-stripper: a clone and a full JSON parse of a ~119KB body, in the same
/// process decoding audio, to remove nothing. Separate configurations make the
/// conflict structurally impossible rather than something to remember.
/// Cookies are still shared, because `websiteDataStore` defaults to the
/// process-wide store.
@MainActor
final class InnerTubeSearchClient: NSObject {

    /// Any first-party YouTube document will do — this one is only ever used as
    /// a host for the fetch, never displayed.
    private static let hostURL = URL(string: "https://m.youtube.com/")!

    private lazy var webView: WKWebView = makeWebView()

    private enum LoadState {
        case idle, loading, ready, failed(String)
    }

    private var state: LoadState = .idle
    private var waiters: [CheckedContinuation<Void, Error>] = []

    // MARK: - Searching

    func search(query: String) async throws -> [YouTubeVideo] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        try await prepareHostDocument()

        let result: Any?
        do {
            result = try await webView.callAsyncJavaScript(
                "return await window.__shirSearch(query);",
                arguments: ["query": trimmed],
                in: nil,
                contentWorld: .page   // must match where the script was injected
            )
        } catch {
            throw SearchError.failed(error.localizedDescription)
        }

        guard let rows = result as? [[String: Any]] else { return [] }
        return rows.compactMap(Self.video(from:))
    }

    private static func video(from row: [String: Any]) -> YouTubeVideo? {
        guard let id = row["id"] as? String,
              let title = row["title"] as? String,
              !id.isEmpty, !title.isEmpty else { return nil }

        return YouTubeVideo(
            id: id,
            title: title,
            channelTitle: row["channel"] as? String ?? "",
            thumbnailURL: (row["thumbnail"] as? String).flatMap(URL.init(string:)),
            duration: row["durationSeconds"] as? Double
        )
    }

    // MARK: - Host document

    /// Loads the host page once and keeps it warm.
    ///
    /// A blank document with a `baseURL` would give the right origin but no
    /// `ytcfg`, and `ytcfg` is the whole reason for doing this in a web view —
    /// so a real page it has to be.
    private func prepareHostDocument() async throws {
        switch state {
        case .ready:
            return
        case let .failed(message):
            // Retry rather than staying broken forever: the usual cause is the
            // phone having been offline when search was first opened.
            state = .idle
            _ = message
            try await prepareHostDocument()
        case .loading:
            try await withCheckedThrowingContinuation { waiters.append($0) }
        case .idle:
            state = .loading
            webView.load(URLRequest(url: Self.hostURL))
            try await withCheckedThrowingContinuation { waiters.append($0) }
        }
    }

    private func finishLoading(with error: Error?) {
        if let error {
            state = .failed(error.localizedDescription)
        } else {
            state = .ready
        }
        let pending = waiters
        waiters.removeAll()
        for continuation in pending {
            if let error {
                continuation.resume(throwing: SearchError.failed(error.localizedDescription))
            } else {
                continuation.resume()
            }
        }
    }

    // MARK: - Web view

    private func makeWebView() -> WKWebView {
        let controller = WKUserContentController()

        do {
            controller.addUserScript(
                WKUserScript(
                    source: try PlayerScripts.search.source,
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: true,
                    in: .page
                )
            )
        } catch {
            assertionFailure("\(error)")
        }

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        // Nothing here should ever play; this document exists to host a fetch.
        configuration.allowsInlineMediaPlayback = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.isUserInteractionEnabled = false
        return webView
    }

    enum SearchError: LocalizedError {
        case failed(String)

        var errorDescription: String? {
            switch self {
            case let .failed(message): return message
            }
        }
    }
}

// MARK: - Navigation

extension InnerTubeSearchClient: WKNavigationDelegate {

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { finishLoading(with: nil) }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        MainActor.assumeIsolated { finishLoading(with: error) }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        MainActor.assumeIsolated { finishLoading(with: error) }
    }
}
