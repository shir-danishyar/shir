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
    let apiKeys: APIKeyStore
    let youtube: YouTubeSearchClient

    /// Passed by the UI test target so each run starts from a clean library
    /// instead of whatever the previous run left in Documents.
    static var isUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains("-uitesting")
    }

    init() {
        let apiKeys = APIKeyStore()
        self.apiKeys = apiKeys
        if Self.isUITesting { apiKeys.clear() }

        let persistence: LibraryPersisting = Self.isUITesting
            ? FileLibraryPersistence(
                url: FileManager.default.temporaryDirectory
                    .appendingPathComponent("uitest-\(UUID().uuidString)")
                    .appendingPathComponent("library.json")
              )
            : FileLibraryPersistence()
        library = LibraryStore(persistence: persistence)
        playback = PlaybackCoordinator()

        // The client reads the key on every call rather than capturing it, so
        // pasting a key in Settings takes effect without rebuilding anything.
        //
        // It reads the keychain directly rather than the store. The client
        // calls this from a background async context, and the previous
        // `MainActor.assumeIsolated { apiKeys?.key }` asserted and killed the
        // process on the first search — every search crashed the app.
        youtube = YouTubeSearchClient(apiKeyProvider: { APIKeyStore.currentKey() })
    }

    /// Removes a local track's file as well as its library entry, so deleting
    /// from the UI actually reclaims storage.
    func deleteLocalTrack(_ track: Track) {
        LocalMediaImporter.deleteFile(for: track)
        library.deleteTrack(id: track.id)
    }
}
