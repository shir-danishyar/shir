import Foundation
import Observation
import RiffKit

/// Debounced YouTube search.
///
/// The debounce used to exist for quota — each Data API search cost 100 units
/// against a 10,000/day allowance. That reason is gone with the API key, but a
/// better one replaced it: every keystroke would otherwise be a ~119KB transfer
/// and a JSON parse inside the same process decoding audio.
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

    private let client: InnerTubeSearchClient
    private var searchTask: Task<Void, Never>?

    private let debounceNanoseconds: UInt64 = 450_000_000

    init(client: InnerTubeSearchClient) {
        self.client = client
    }

    func submit() {
        searchTask?.cancel()
        runSearch()
    }

    func clear() {
        searchTask?.cancel()
        query = ""
        results = []
        errorMessage = nil
        hasSearched = false
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
            runSearch()
        }
    }

    private func runSearch() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isLoading = true
        errorMessage = nil

        searchTask = Task {
            do {
                let videos = try await client.search(query: trimmed)
                guard !Task.isCancelled else { return }
                results = videos
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
