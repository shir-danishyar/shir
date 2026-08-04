import RiffKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var appEnvironment
    @Environment(LibraryStore.self) private var library
    @State private var draftKey = ""
    @State private var isEditingKey = false

    var body: some View {
        NavigationStack {
            List {
                apiKeySection
                howPlaybackWorksSection
                storageSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Settings")
        }
    }

    // MARK: - API key

    private var apiKeySection: some View {
        Section {
            if appEnvironment.apiKeys.hasKey && !isEditingKey {
                HStack {
                    Label("Key saved", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Button("Change") {
                        draftKey = ""
                        isEditingKey = true
                    }
                }
                Button("Remove Key", role: .destructive) {
                    appEnvironment.apiKeys.clear()
                }
            } else {
                SecureField("AIza…", text: $draftKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Save Key") {
                    appEnvironment.apiKeys.save(draftKey)
                    draftKey = ""
                    isEditingKey = false
                }
                .disabled(draftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        } header: {
            Text("YouTube Data API key")
        } footer: {
            Text("""
            Create a project at console.cloud.google.com, enable “YouTube Data API v3”, \
            then make an API key under Credentials. The key is stored in your device \
            keychain and only ever sent to Google. The free tier is 10,000 quota units \
            a day, and one search costs 100.
            """)
        }
    }

    // MARK: - How playback works

    private var howPlaybackWorksSection: some View {
        Section {
            row(
                icon: "play.rectangle.fill",
                title: "YouTube tracks",
                detail: """
                Play through YouTube's official embedded player, so the video stays \
                on screen and YouTube serves whatever ads it normally would. Pauses \
                when you leave the app.
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
                icon: "info.circle.fill",
                title: "Why not strip the ads?",
                detail: """
                Pulling YouTube streams into a hidden player breaks their terms and \
                gets an app removed from the App Store. Import files for uninterrupted \
                listening, or use a YouTube Premium account.
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
