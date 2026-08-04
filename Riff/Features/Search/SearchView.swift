import RiffKit
import SwiftUI

struct SearchView: View {
    @Environment(AppEnvironment.self) private var appEnvironment
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackCoordinator.self) private var playback
    @State private var model: SearchViewModel?

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    content(model: model)
                } else {
                    Color.clear
                }
            }
            .background(Theme.background)
            .navigationTitle("Search")
        }
        .onAppear {
            if model == nil {
                model = SearchViewModel(client: appEnvironment.youtube)
            }
        }
    }

    @ViewBuilder
    private func content(model: SearchViewModel) -> some View {
        @Bindable var model = model

        List {
            if !appEnvironment.apiKeys.hasKey {
                missingKeyNotice
            } else if let error = model.errorMessage {
                errorRow(error)
            } else if model.results.isEmpty && model.hasSearched && !model.isLoading {
                EmptyStateView(
                    icon: "magnifyingglass",
                    title: "No results",
                    message: "Try a different spelling, or add the artist's name."
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else if model.results.isEmpty && !model.isLoading {
                EmptyStateView(
                    icon: "music.note.tv",
                    title: "Search YouTube",
                    message: "Results are limited to music videos their uploader allows to be embedded."
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            ForEach(model.results) { video in
                let track = video.track
                TrackRow(track: track, isCurrent: track.id == playback.currentTrack?.id, showsSourceBadge: false)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        library.upsert(track)
                        playback.play(model.results.map(\.track), startingAt: model.results.firstIndex(of: video) ?? 0)
                    }
                    .listRowBackground(Theme.surface)
                    .contextMenu { TrackContextMenu(track: track) }
                    .onAppear { model.loadMoreIfNeeded(currentItem: video) }
            }

            if model.isLoading {
                HStack {
                    Spacer()
                    ProgressView().tint(Theme.accent)
                    Spacer()
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            // Keeps the last row clear of the mini player.
            Color.clear
                .frame(height: Theme.miniPlayerHeight)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .searchable(text: $model.query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Songs, artists, albums")
        .onSubmit(of: .search) { model.submit() }
    }

    private var missingKeyNotice: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("YouTube key needed", systemImage: "key.fill")
                .font(.headline)
                .foregroundStyle(Theme.primaryText)
            Text("""
            Search runs on the official YouTube Data API, which needs your own \
            API key. Settings has the steps — it takes about two minutes and the \
            free tier covers roughly 100 searches a day.
            """)
            .font(.system(size: 13))
            .foregroundStyle(Theme.secondaryText)
        }
        .padding(.vertical, 8)
        .listRowBackground(Theme.surface)
    }

    private func errorRow(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 13))
            .foregroundStyle(Theme.secondaryText)
            .listRowBackground(Theme.surface)
    }
}
