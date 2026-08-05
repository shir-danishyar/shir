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

    /// Passed by the UI test target so each run starts from a clean library
    /// instead of whatever the previous run left in Documents.
    static var isUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains("-uitesting")
    }

    init() {
        let persistence: LibraryPersisting = Self.isUITesting
            ? FileLibraryPersistence(
                url: FileManager.default.temporaryDirectory
                    .appendingPathComponent("uitest-\(UUID().uuidString)")
                    .appendingPathComponent("library.json")
              )
            : FileLibraryPersistence()
        library = LibraryStore(persistence: persistence)
        playback = PlaybackCoordinator()
        youtube = InnerTubeSearchClient()
    }

    /// Removes a local track's file as well as its library entry, so deleting
    /// from the UI actually reclaims storage.
    func deleteLocalTrack(_ track: Track) {
        LocalMediaImporter.deleteFile(for: track)
        library.deleteTrack(id: track.id)
    }
}
