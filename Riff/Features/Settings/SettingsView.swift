import RiffKit
import SwiftUI

struct SettingsView: View {
    @Environment(LibraryStore.self) private var library

    /// No `NavigationStack` of its own — this is always pushed from More, and
    /// nesting a second stack inside the tab's one leaves the pushed content
    /// unreachable to navigation and to UI tests.
    var body: some View {
        List {
            howSearchWorksSection
            howPlaybackWorksSection
            storageSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - How search works

    private var howSearchWorksSection: some View {
        Section {
            row(
                icon: "magnifyingglass.circle.fill",
                title: "No account, no key",
                detail: """
                Search runs YouTube's own request from inside a real page, so it \
                needs no API key and no sign-in. There is no daily quota to run out of.
                """
            )
        } header: {
            Text("How search works")
        }
    }

    // MARK: - How playback works

    private var howPlaybackWorksSection: some View {
        Section {
            row(
                icon: "play.rectangle.fill",
                title: "YouTube tracks",
                detail: """
                Play in a web view driving YouTube's mobile site, with ads removed \
                before the player ever sees them. Keeps playing with the screen off.
                """
            )
            row(
                icon: "arrow.down.circle.fill",
                title: "Imported files",
                detail: """
                Play from your own storage with no ads at all, keep going in the \
                background, and show up on the lock screen and AirPlay.
                """
            )
            row(
                icon: "exclamationmark.triangle.fill",
                title: "When YouTube breaks it",
                detail: """
                Ad removal depends on YouTube's response format, which changes every \
                few months. When ads reappear, the fix is a scripts update — nothing \
                is wrong with your library.
                """
            )
        } header: {
            Text("How playback works")
        }
    }

    private func row(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(Theme.accent)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 15, weight: .medium))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Storage

    private var storageSection: some View {
        Section("Library") {
            LabeledContent("Playlists", value: "\(library.playlists.count)")
            LabeledContent("Saved songs", value: "\(library.allTracks.count)")
            LabeledContent("Imported files", value: "\(library.localTracks.count)")
            LabeledContent("Storage used", value: formattedMediaSize)
        }
    }

    private var formattedMediaSize: String {
        let directory = MediaLibraryLocation.mediaDirectory
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return "0 KB" }

        let bytes = contents.reduce(into: 0) { total, url in
            total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
