import Foundation

/// The queries the user has searched, most recent first.
///
/// A pure value type so the ordering, deduplication and capping rules can be
/// tested without touching disk — which is where the actual behaviour lives.
public struct SearchHistory: Codable, Equatable, Sendable {

    /// Twenty is enough to cover "the thing I searched last week" without the
    /// list becoming something you have to scroll.
    public static let limit = 20

    public private(set) var entries: [String] = []

    public init(entries: [String] = []) {
        self.entries = Array(entries.prefix(Self.limit))
    }

    /// Records a query, moving it to the front if it was already there.
    ///
    /// Dedupe is case-insensitive, and the newly typed casing wins — searching
    /// "Daft Punk" after "daft punk" should leave one entry reading the way you
    /// last typed it, not the way you first did.
    public mutating func record(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        entries.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        entries.insert(trimmed, at: 0)
        if entries.count > Self.limit {
            entries.removeSubrange(Self.limit...)
        }
    }

    public mutating func remove(_ query: String) {
        entries.removeAll { $0.caseInsensitiveCompare(query) == .orderedSame }
    }

    public mutating func clear() {
        entries.removeAll()
    }
}

/// Where search history is read from and written to.
///
/// Deliberately a separate file from the library rather than a field on
/// `Library`: Swift's synthesized `Decodable` throws `keyNotFound` for a
/// property that isn't in the stored JSON, and `LibraryStore.init` handles a
/// decode failure by starting from an empty `Library`. Adding a field to that
/// type would therefore delete every existing user's music the first time they
/// launched the new build.
public protocol SearchHistoryPersisting: AnyObject {
    func load() -> SearchHistory
    func save(_ history: SearchHistory)
}

/// JSON on disk, next to the library.
///
/// Neither method throws. History is a convenience — losing it should never
/// surface an error to someone who is just trying to find a song.
public final class FileSearchHistoryPersistence: SearchHistoryPersisting {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public convenience init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.init(url: documents.appendingPathComponent("search-history.json"))
    }

    public func load() -> SearchHistory {
        guard let data = try? Data(contentsOf: url),
              let history = try? JSONDecoder().decode(SearchHistory.self, from: data)
        else { return SearchHistory() }
        return history
    }

    public func save(_ history: SearchHistory) {
        guard let data = try? JSONEncoder().encode(history) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }
}

/// Test double.
public final class InMemorySearchHistoryPersistence: SearchHistoryPersisting {
    public private(set) var stored: SearchHistory
    public private(set) var saveCount = 0

    public init(_ history: SearchHistory = SearchHistory()) {
        stored = history
    }

    public func load() -> SearchHistory { stored }

    public func save(_ history: SearchHistory) {
        stored = history
        saveCount += 1
    }
}

/// Observable wrapper so SwiftUI redraws when the list changes.
@MainActor
@Observable
public final class SearchHistoryStore {
    public private(set) var history: SearchHistory

    private let persistence: SearchHistoryPersisting

    public init(persistence: SearchHistoryPersisting) {
        self.persistence = persistence
        history = persistence.load()
    }

    public var entries: [String] { history.entries }

    public func record(_ query: String) {
        let before = history
        history.record(query)
        // Re-searching the same term repeatedly is common; skip the write when
        // nothing actually moved.
        guard history != before else { return }
        persistence.save(history)
    }

    public func remove(_ query: String) {
        history.remove(query)
        persistence.save(history)
    }

    public func clear() {
        history.clear()
        persistence.save(history)
    }
}
