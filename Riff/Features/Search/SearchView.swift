import RiffKit
import SwiftUI

/// YouTube search, in the app's own chrome.
///
/// This is the half of the Musi architecture that keeps the web view a dumb
/// player: the video id flows app → player and never the reverse. The user
/// never sees YouTube's interface, which is both the right product shape and
/// the reason the page's own search box — which used to crash the app when
/// tapped — is now unreachable.
struct SearchView: View {
    @Environment(AppEnvironment.self) private var appEnvironment
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackCoordinator.self) private var playback

    /// Built lazily because the view model needs the search client, which lives
    /// on the environment and isn't available at property-initialiser time.
    @State private var model: SearchViewModel?
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()

                if let model {
                    content(model: model)
                } else {
                    Color.clear
                }
            }
            .navigationBarHidden(true)
        }
        .onAppear {
            if model == nil {
                model = SearchViewModel(client: appEnvironment.youtube)
            }
        }
    }

    @ViewBuilder
    private func content(model: SearchViewModel) -> some View {
        VStack(spacing: 0) {
            searchField(model: model)

            if let error = model.errorMessage {
                errorRow(error)
            } else if model.results.isEmpty, model.hasSearched, !model.isLoading {
                EmptyStateView(
                    icon: "magnifyingglass",
                    title: "No results",
                    message: "Try a different search."
                )
                .padding(.top, 40)
            } else if !model.results.isEmpty {
                results(model: model)
            } else {
                idlePrompt
            }

            Spacer(minLength: 0)
        }
    }

    private func searchField(model: SearchViewModel) -> some View {
        @Bindable var model = model

        return HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Theme.secondaryText)

            TextField("Search", text: $model.query)
                .focused($isFieldFocused)
                .font(.system(size: 17))
                .foregroundStyle(Theme.primaryText)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .onSubmit { model.submit() }
                .accessibilityIdentifier("searchField")

            if model.isLoading {
                ProgressView().controlSize(.small).tint(Theme.secondaryText)
            } else if !model.query.isEmpty {
                Button {
                    model.clear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.secondaryText)
                }
                .buttonStyle(.plain)
                // Appears only once the typed text has reached the binding,
                // which makes it the gate a UI test can wait on instead of
                // sleeping — SwiftUI focuses fields asynchronously and drops
                // typeText that lands too early.
                .accessibilityIdentifier("clearSearchButton")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(Theme.field, in: Capsule())
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private func results(model: SearchViewModel) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(model.results.enumerated()), id: \.element.id) { index, video in
                    SearchResultRow(
                        video: video,
                        isInLibrary: library.track(id: video.track.id) != nil,
                        onAdd: { library.upsert(video.track) }
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { playFromResults(model: model, index: index) }

                    if index < model.results.count - 1 { RowSeparator() }
                }

                Color.clear.frame(height: Theme.miniPlayerHeight + 24)
            }
        }
        .scrollIndicators(.hidden)
        // Matters more here than anywhere else: the results are the whole point
        // and the keyboard covers half of them.
        .scrollDismissesKeyboard(.immediately)
    }

    private var idlePrompt: some View {
        EmptyStateView(
            icon: "magnifyingglass",
            title: "Find music",
            message: "Search YouTube for a song, artist or mix, then tap + to save it."
        )
        .padding(.top, 40)
    }

    private func errorRow(_ message: String) -> some View {
        EmptyStateView(icon: "exclamationmark.triangle", title: "Search failed", message: message)
            .padding(.top, 40)
    }

    // MARK: - Actions

    /// Playing and saving are separate, matching the reference: the row plays,
    /// the + saves. Tapping a result you don't want to keep should not silently
    /// grow your library — but it does need to be in the catalogue for the
    /// queue to resolve it later, so the played one is upserted.
    private func playFromResults(model: SearchViewModel, index: Int) {
        let tracks = model.results.map(\.track)
        guard tracks.indices.contains(index) else { return }
        library.upsert(tracks[index])
        playback.play(tracks, startingAt: index)
        isFieldFocused = false
    }
}
