import ShirKit
import SwiftUI

/// YouTube search, in the app's own chrome.
///
/// Three states, matching the reference app:
///
/// - focused with an empty field → recent searches
/// - typing → live YouTube autocomplete
/// - submitted, or focus dropped → results
///
/// This is also the half of the architecture that keeps the web view a
/// dumb player: the video id flows app → player and never the reverse. The user
/// never sees YouTube's interface, which is both the right product shape and
/// the reason the page's own search box — which used to crash the app when
/// tapped — is unreachable.
struct SearchView: View {
    @Environment(AppEnvironment.self) private var appEnvironment
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackCoordinator.self) private var playback

    /// Built lazily because the view model needs clients that live on the
    /// environment, which isn't available at property-initialiser time.
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
                model = SearchViewModel(
                    client: appEnvironment.youtube,
                    suggestionClient: appEnvironment.suggestions,
                    history: appEnvironment.searchHistory
                )
            }
        }
    }

    @ViewBuilder
    private func content(model: SearchViewModel) -> some View {
        VStack(spacing: 0) {
            searchField(model: model)

            switch state(for: model) {
            case .history:
                historyList(model: model)
            case .suggestions:
                suggestionList(model: model)
            case .error(let message):
                errorRow(message)
            case .noResults:
                EmptyStateView(
                    icon: "magnifyingglass",
                    title: "No results",
                    message: "Try a different search."
                )
                .padding(.top, 40)
            case .results:
                results(model: model)
            case .idle:
                idlePrompt
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: - State

    private enum ScreenState {
        case history, suggestions, results, noResults, idle
        case error(String)
    }

    /// Suggestions and history only take over while the field has focus.
    /// Dropping the keyboard should reveal the results that have been loading
    /// underneath the whole time, not an empty screen.
    private func state(for model: SearchViewModel) -> ScreenState {
        if isFieldFocused, model.query.isEmpty {
            return model.historyEntries.isEmpty ? .idle : .history
        }
        if isFieldFocused, !model.suggestions.isEmpty {
            return .suggestions
        }
        if let error = model.errorMessage { return .error(error) }
        if !model.results.isEmpty { return .results }
        if model.hasSearched, !model.isLoading { return .noResults }
        return .idle
    }

    // MARK: - Field

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
                .onSubmit {
                    model.submit()
                    isFieldFocused = false
                }
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

    // MARK: - History

    private func historyList(model: SearchViewModel) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.historyEntries, id: \.self) { entry in
                    HStack(spacing: 14) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 19))
                            .foregroundStyle(Theme.secondaryText)
                            .frame(width: 26)

                        Text(entry)
                            .font(.system(size: 17))
                            .foregroundStyle(Theme.primaryText)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Button {
                            model.removeFromHistory(entry)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Theme.secondaryText)
                                .frame(width: 44, height: 44)
                        }
                        // .plain stops the delete button from claiming the
                        // whole row's tap, which is the classic nested-button
                        // trap in SwiftUI lists.
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("deleteHistory-\(entry)")
                        .accessibilityLabel("Remove \(entry) from recent searches")
                    }
                    .padding(.leading, 14)
                    .padding(.trailing, 2)
                    .frame(height: 52)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        model.accept(suggestion: entry)
                        isFieldFocused = false
                    }

                    RowSeparator()
                }
            }
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.never)
    }

    // MARK: - Suggestions

    private func suggestionList(model: SearchViewModel) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.suggestions, id: \.self) { suggestion in
                    Button {
                        model.accept(suggestion: suggestion)
                        isFieldFocused = false
                    } label: {
                        Text(Self.highlighted(suggestion, matching: model.query))
                            .font(.system(size: 17))
                            .foregroundStyle(Theme.primaryText)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .frame(height: 52)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    RowSeparator()
                }
            }
        }
        .scrollIndicators(.hidden)
        // The opposite of the results list on purpose. Dismissing the keyboard
        // here would drop focus, which swaps this whole view out from under the
        // finger mid-scroll.
        .scrollDismissesKeyboard(.never)
    }

    /// Bolds the part of the suggestion the user has already typed, the way the
    /// reference app does.
    ///
    /// Ranges are `String.Index`, never `NSRange` — UTF-16 offsets break on the
    /// Persian and Arabic queries this library is full of. When the suggestion
    /// isn't prefixed by the query, which happens when the first suggestion is
    /// the query verbatim, everything falls back to regular weight.
    static func highlighted(_ suggestion: String, matching query: String) -> AttributedString {
        var attributed = AttributedString(suggestion)
        attributed.font = .system(size: 17)

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let match = suggestion.range(of: trimmed, options: [.caseInsensitive, .anchored]),
              let bold = Range(match, in: attributed)
        else { return attributed }

        attributed[bold].font = .system(size: 17, weight: .bold)
        return attributed
    }

    // MARK: - Results

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
