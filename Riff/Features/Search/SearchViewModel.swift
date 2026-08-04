import Foundation
import Observation
import RiffKit

/// Debounced search over the YouTube Data API.
///
/// The debounce is not just polish: each search costs 100 quota units against a
/// default daily allowance of 10,000, so firing on every keystroke would burn
/// the day's budget in a couple of minutes.
@MainActor
@Observable
final class SearchViewModel {
    var query: String = "" {
        didSet { scheduleSearch() }
    }

    private(set) var results: [YouTubeVideo] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var hasSearched = false

    private let client: YouTubeSearchClient
    private var searchTask: Task<Void, Never>?
    private var nextPageToken: String?

    private let debounceNanoseconds: UInt64 = 450_000_000

    init(client: YouTubeSearchClient) {
        self.client = client
    }

    func submit() {
        searchTask?.cancel()
        runSearch(resetting: true)
    }

    func loadMoreIfNeeded(currentItem: YouTubeVideo) {
        guard let last = results.last, last.id == currentItem.id else { return }
        guard nextPageToken != nil, !isLoading else { return }
        runSearch(resetting: false)
    }

    func clear() {
        searchTask?.cancel()
        query = ""
        results = []
        errorMessage = nil
        hasSearched = false
        nextPageToken = nil
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            errorMessage = nil
            hasSearched = false
            return
        }
        searchTask = Task { [debounceNanoseconds] in
            try? await Task.sleep(nanoseconds: debounceNanoseconds)
            guard !Task.isCancelled else { return }
            runSearch(resetting: true)
        }
    }

    private func runSearch(resetting: Bool) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let token = resetting ? nil : nextPageToken
        isLoading = true
        errorMessage = nil

        searchTask = Task {
            do {
                let page = try await client.search(query: trimmed, pageToken: token)
                guard !Task.isCancelled else { return }
                if resetting {
                    results = page.videos
                } else {
                    // Paging can echo a result that was already on screen;
                    // dropping duplicates keeps SwiftUI's ForEach ids unique.
                    let known = Set(results.map(\.id))
                    results.append(contentsOf: page.videos.filter { !known.contains($0.id) })
                }
                nextPageToken = page.nextPageToken
                hasSearched = true
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                hasSearched = true
            }
            isLoading = false
        }
    }
}
