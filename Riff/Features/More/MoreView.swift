import RiffKit
import SwiftUI

/// The fourth tab: importing, settings, and the numbers about your library.
///
/// The reference puts everything that isn't music behind this tab, which keeps
/// the other three about listening. Import lives here rather than on Playlists
/// because it is a rare, deliberate action.
struct MoreView: View {
    @Environment(AppEnvironment.self) private var appEnvironment
    @Environment(LibraryStore.self) private var library

    @State private var isImportingFiles = false
    @State private var importMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 0) {
                        NavigationLink {
                            SettingsView()
                        } label: {
                            MoreRow(icon: "gearshape", title: "Settings", detail: nil)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("settingsRow")
                        RowSeparator()

                        Button {
                            isImportingFiles = true
                        } label: {
                            MoreRow(
                                icon: "square.and.arrow.down",
                                title: "Import Audio Files",
                                detail: nil
                            )
                        }
                        .buttonStyle(.plain)
                        RowSeparator()

                        MoreRow(icon: "music.note", title: "Songs",
                                detail: "\(library.allTracks.count)")
                        RowSeparator()
                        MoreRow(icon: "music.note.list", title: "Playlists",
                                detail: "\(library.playlists.count)")
                        RowSeparator()
                        MoreRow(icon: "arrow.down.circle", title: "Imported Files",
                                detail: "\(library.localTracks.count)")

                        Color.clear.frame(height: Theme.miniPlayerHeight + 24)
                    }
                    .padding(.top, 8)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle("More")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.surface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .fileImporter(
                isPresented: $isImportingFiles,
                allowedContentTypes: [.audio],
                allowsMultipleSelection: true
            ) { result in
                Task { await handleImport(result) }
            }
            .alert(
                "Import",
                isPresented: Binding(
                    get: { importMessage != nil },
                    set: { if !$0 { importMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { importMessage = nil }
            } message: {
                Text(importMessage ?? "")
            }
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) async {
        switch result {
        case let .failure(error):
            importMessage = error.localizedDescription
        case let .success(urls):
            let outcome = await LocalMediaImporter.importFiles(at: urls)
            for track in outcome.tracks { library.upsert(track) }

            if outcome.failures.isEmpty {
                importMessage = "Imported \(outcome.tracks.count) file\(outcome.tracks.count == 1 ? "" : "s")."
            } else {
                importMessage = "Imported \(outcome.tracks.count), skipped \(outcome.failures.count)."
            }
        }
    }
}

/// One row in the More list: icon, title, optional trailing value.
struct MoreRow: View {
    let icon: String
    let title: String
    let detail: String?

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 17))
                .foregroundStyle(Theme.accent)
                .frame(width: 26)

            Text(title)
                .font(.system(size: 17))
                .foregroundStyle(Theme.primaryText)

            Spacer()

            if let detail {
                Text(detail)
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.secondaryText)
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .contentShape(Rectangle())
    }
}
