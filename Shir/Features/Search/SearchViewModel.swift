import Foundation
import Observation
import ShirKit

/// Drives the search screen: suggestions while typing, results once submitted.
///
/// The two run on separate tasks with separate debounces. Suggestions are a
/// 350-byte GET and want to feel instant; results are a ~119KB transfer and a
/// JSON parse inside the process decoding audio, so they wait longer.
@MainActor
@Observable
final class SearchViewModel {
    var query: String = "" {
        didSet { scheduleWork() }
    }

    private(set) var results: [YouTubeVideo] = []
    private(set) var suggestions: [String] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var hasSearched = false

    private let client: InnerTubeSearchClient
    private let suggestionClient: SuggestionClient
    private let history: SearchHistoryStore

    private var searchTask: Task<Void, Never>?
    private var suggestTask: Task<Void, Never>?

    private let searchDebounce: UInt64 = 450_000_000
    private let suggestionDebounce: UInt64 = 150_000_000

    init(
        client: InnerTubeSearchClient,
        suggestionClient: SuggestionClient,
        history: SearchHistoryStore
    ) {
        self.client = client
        self.suggestionClient = suggestionClient
        self.history = history
    }

    var historyEntries: [String] { history.entries }

    // MARK: - Actions

    func submit() {
        searchTask?.cancel()
        clearSuggestions()
        recordCurrentQuery()
        runSearch()
    }

    /// Order matters here.
    ///
    /// Assigning `query` fires its `didSet` synchronously, which schedules a
    /// fresh suggestion fetch — so the suggestions have to be cleared *after*
    /// the assignment, not before, or the list reopens under the user's finger.
    func accept(suggestion: String) {
        query = suggestion
        clearSuggestions()
        recordCurrentQuery()
        searchTask?.cancel()
        runSearch()
    }

    func removeFromHistory(_ entry: String) {
        history.remove(entry)
    }

    func clear() {
        searchTask?.cancel()
        clearSuggestions()
        query = ""
        results = []
        errorMessage = nil
        hasSearched = false
    }

    // MARK: - Scheduling

    private func scheduleWork() {
        searchTask?.cancel()
        suggestTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            suggestions = []
            errorMessage = nil
            hasSearched = false
            return
        }

        suggestTask = Task { [suggestionDebounce] in
            try? await Task.sleep(nanoseconds: suggestionDebounce)
            guard !Task.isCancelled else { return }
            await loadSuggestions(for: trimmed)
        }

        searchTask = Task { [searchDebounce] in
            try? await Task.sleep(nanoseconds: searchDebounce)
            guard !Task.isCancelled else { return }
            runSearch()
        }
    }

    /// URLSession does not guarantee completion order, and these requests are
    /// small and fast enough that interleaving is likely rather than
    /// theoretical. Dropping any response whose query is no longer the current
    /// one stops an earlier, slower reply overwriting a later one.
    private func loadSuggestions(for requested: String) async {
        let fetched = await suggestionClient.suggestions(for: requested)
        guard !Task.isCancelled,
              requested == query.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return }
        suggestions = fetched
    }

    private func clearSuggestions() {
        suggestTask?.cancel()
        suggestions = []
    }

    private func recordCurrentQuery() {
        history.record(query)
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
