import AVFoundation
import Foundation
import ShirKit

/// Copies audio files the user picks into the app's own Documents/Media folder
/// and reads their embedded metadata.
///
/// Copying matters: the picker hands back a security-scoped URL that is only
/// valid for the duration of the callback, so anything left pointing at the
/// original location would fail to play on the next launch.
enum LocalMediaImporter {
    struct ImportResult {
        let tracks: [Track]
        let failures: [String]
    }

    static func importFiles(at urls: [URL]) async -> ImportResult {
        var tracks: [Track] = []
        var failures: [String] = []

        for url in urls {
            do {
                tracks.append(try await importFile(at: url))
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return ImportResult(tracks: tracks, failures: failures)
    }

    private static func importFile(at url: URL) async throws -> Track {
        try MediaLibraryLocation.ensureMediaDirectoryExists()

        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let fileName = uniqueFileName(for: url.lastPathComponent)
        let destination = MediaLibraryLocation.mediaDirectory.appendingPathComponent(fileName)
        try FileManager.default.copyItem(at: url, to: destination)

        let metadata = await readMetadata(from: destination)
        return Track.localFile(
            fileName: fileName,
            title: metadata.title ?? url.deletingPathExtension().lastPathComponent,
            artist: metadata.artist ?? "Unknown Artist",
            duration: metadata.duration
        )
    }

    /// Keeps a second import of the same filename from overwriting the first.
    private static func uniqueFileName(for proposed: String) -> String {
        let directory = MediaLibraryLocation.mediaDirectory
        var candidate = proposed
        var suffix = 2
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            let base = (proposed as NSString).deletingPathExtension
            let ext = (proposed as NSString).pathExtension
            candidate = ext.isEmpty ? "\(base) \(suffix)" : "\(base) \(suffix).\(ext)"
            suffix += 1
        }
        return candidate
    }

    private struct Metadata {
        var title: String?
        var artist: String?
        var duration: TimeInterval?
    }

    private static func readMetadata(from url: URL) async -> Metadata {
        let asset = AVURLAsset(url: url)
        var metadata = Metadata()

        if let duration = try? await asset.load(.duration) {
            let seconds = duration.seconds
            metadata.duration = seconds.isFinite && seconds > 0 ? seconds : nil
        }

        guard let items = try? await asset.load(.commonMetadata) else { return metadata }
        metadata.title = await stringValue(in: items, identifier: .commonIdentifierTitle)
        // Split rather than chained with ?? — the right-hand side of ?? is an
        // autoclosure, which cannot contain an await.
        if let artist = await stringValue(in: items, identifier: .commonIdentifierArtist) {
            metadata.artist = artist
        } else {
            metadata.artist = await stringValue(in: items, identifier: .commonIdentifierCreator)
        }
        return metadata
    }

    private static func stringValue(
        in items: [AVMetadataItem],
        identifier: AVMetadataIdentifier
    ) async -> String? {
        let matching = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier)
        guard let item = matching.first,
              let value = try? await item.load(.stringValue) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Deletes the backing file for a local track. Safe to call for a track
    /// whose file is already gone.
    static func deleteFile(for track: Track) {
        guard let fileName = track.localFileName else { return }
        let url = MediaLibraryLocation.mediaDirectory.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: url)
    }
}
