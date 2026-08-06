import Foundation
import Observation
import ShirKit

/// Composition root. Everything the app needs is built here once and handed
/// down through the SwiftUI environment, so no view reaches for a singleton.
@MainActor
@Observable
final class AppEnvironment {
    let library: LibraryStore
    let playback: PlaybackCoordinator
    let youtube: InnerTubeSearchClient
    let suggestions: SuggestionClient
    let trending: TrendingClient
    let searchHistory: SearchHistoryStore

    /// Passed by the UI test target so each run starts from a clean library
    /// instead of whatever the previous run left in Documents.
    static var isUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains("-uitesting")
    }

    /// Puts a couple of known tracks in the catalogue — but not in Favorites —
    /// so the flow tests can exercise play-versus-favorite without a network.
    private static var wantsSeedData: Bool {
        ProcessInfo.processInfo.arguments.contains("-seedLibrary")
    }

    init() {
        // Under -uitesting both stores point at a fresh temp directory, so each
        // run starts clean rather than inheriting the last one.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("uitest-\(UUID().uuidString)")

        let persistence: LibraryPersisting = Self.isUITesting
            ? FileLibraryPersistence(url: scratch.appendingPathComponent("library.json"))
            : FileLibraryPersistence()
        library = LibraryStore(persistence: persistence)

        let historyPersistence: SearchHistoryPersisting = Self.isUITesting
            ? FileSearchHistoryPersistence(url: scratch.appendingPathComponent("search-history.json"))
            : FileSearchHistoryPersistence()
        searchHistory = SearchHistoryStore(persistence: historyPersistence)

        playback = PlaybackCoordinator()
        youtube = InnerTubeSearchClient()
        suggestions = SuggestionClient()
        trending = TrendingClient()

        if Self.wantsSeedData {
            for name in ["A", "B"] {
                library.upsert(
                    .youtube(
                        videoID: "seed\(name)",
                        title: "Seeded Song \(name)",
                        channelTitle: "Seeded Channel"
                    )
                )
            }
        }

        // Test seam: `-autoplayVideoID <id>` starts playback with no UI
        // driving it. BackgroundPlaybackTests depends on it, and it is also
        // how a plain `simctl launch` reproduces playback issues without
        // XCUITest — search-driven repros stall for reasons unrelated to
        // what is usually being probed.
        if let videoID = UserDefaults.standard.string(forKey: "autoplayVideoID") {
            playback.play(.youtube(videoID: videoID, title: "Probe track", channelTitle: "Probe"))
        }
    }

}
