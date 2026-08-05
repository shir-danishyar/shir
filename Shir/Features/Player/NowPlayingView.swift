import ShirKit
import SwiftUI

/// The full-screen player.
///
/// Layout follows the reference top to bottom: dismiss chevron and "PLAYING
/// FROM" caption, the video, a thin scrubber with elapsed and remaining time,
/// the title with a heart, then the transport row, volume, and a row of
/// secondary actions.
///
/// Everything is the accent colour and everything is large. That is the whole
/// visual idea — this screen has one job and does not hedge about it.
struct NowPlayingView: View {
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss

    @State private var isShowingQueue = false
    @State private var scrubPosition: TimeInterval = 0

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                stage
                scrubber
                trackInfo
                Spacer(minLength: 8)
                transportControls
                Spacer(minLength: 8)
                secondaryControls
            }
        }
        .sheet(isPresented: $isShowingQueue) {
            QueueView()
                .presentationDetents([.medium, .large])
        }
    }

    // MARK: - Header

    private var header: some View {
        ZStack {
            VStack(spacing: 1) {
                Text("PLAYING FROM")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                Text("My Favorites")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.primaryText)
            }

            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(Theme.primaryText)
                        .frame(width: 44, height: 44)
                }
                Spacer()
                Button { isShowingQueue = true } label: {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 44, height: 44)
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 6)
    }

    // MARK: - Stage

    /// The video for YouTube tracks, artwork for imported files.
    ///
    /// The web view stays mounted whenever a YouTube track is loaded. It is no
    /// longer a compliance requirement — that went with the App Store — but it
    /// is still a hard technical one: unmounting the view suspends the media
    /// element, and the audio stops.
    @ViewBuilder
    private var stage: some View {
        if playback.isPlayingYouTube {
            YouTubePlayerView(webView: playback.youtubeEngine.webView)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .background(Color.black)
        } else {
            VideoThumbnail(
                url: playback.currentTrack?.artworkURL,
                width: UIScreen.main.bounds.width,
                height: UIScreen.main.bounds.width * 9 / 16,
                seed: abs(playback.currentTrack?.id.hashValue ?? 0)
            )
        }
    }

    // MARK: - Scrubber

    private var scrubber: some View {
        VStack(spacing: 2) {
            Slider(
                value: Binding(
                    get: { playback.isScrubbing ? scrubPosition : playback.position },
                    set: { scrubPosition = $0 }
                ),
                in: 0...max(playback.duration, 1),
                onEditingChanged: { editing in
                    playback.isScrubbing = editing
                    if !editing { playback.seek(to: scrubPosition) }
                }
            )
            .tint(Theme.accent)

            HStack {
                Text(playback.position.formattedPlaybackTime)
                Spacer()
                Text(remainingText)
            }
            .font(.system(size: 13).monospacedDigit())
            .foregroundStyle(Theme.secondaryText)
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
    }

    private var remainingText: String {
        guard playback.duration > 0 else { return "--:--" }
        let position = playback.isScrubbing ? scrubPosition : playback.position
        return "-" + max(0, playback.duration - position).formattedPlaybackTime
    }

    // MARK: - Track info

    private var trackInfo: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(playback.currentTrack?.title ?? "Nothing playing")
                    .font(Theme.nowPlayingTitle)
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                Text(playback.currentTrack?.artist ?? "")
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: toggleSaved) {
                Image(systemName: isSaved ? "heart.fill" : "heart")
                    .font(.system(size: 26))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.top, 18)
    }

    private var isSaved: Bool {
        guard let track = playback.currentTrack else { return false }
        return library.track(id: track.id) != nil
    }

    private func toggleSaved() {
        guard let track = playback.currentTrack else { return }
        if isSaved {
            library.deleteTrack(id: track.id)
        } else {
            library.upsert(track)
        }
    }

    // MARK: - Transport

    private var transportControls: some View {
        HStack {
            Button { playback.toggleShuffle() } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 24))
                    .foregroundStyle(playback.isShuffled ? Theme.accent : Theme.secondaryText)
            }

            Spacer()

            Button { playback.previous() } label: {
                Image(systemName: "backward.fill").font(.system(size: 34))
            }
            .foregroundStyle(Theme.accent)

            Spacer()

            Button { playback.togglePlayPause() } label: {
                ZStack {
                    Circle().fill(Theme.accent).frame(width: 86, height: 86)
                    if playback.status == .buffering {
                        ProgressView().controlSize(.large).tint(.white)
                    } else {
                        Image(systemName: playback.status.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 36, weight: .medium))
                            .foregroundStyle(.white)
                    }
                }
            }

            Spacer()

            Button { playback.next() } label: {
                Image(systemName: "forward.fill").font(.system(size: 34))
            }
            .foregroundStyle(Theme.accent)

            Spacer()

            Button { playback.cycleRepeatMode() } label: {
                Image(systemName: playback.repeatMode == .one ? "repeat.1" : "repeat")
                    .font(.system(size: 24))
                    .foregroundStyle(playback.repeatMode == .off ? Theme.secondaryText : Theme.accent)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 22)
    }

    // MARK: - Secondary actions

    private var secondaryControls: some View {
        HStack {
            Spacer()
            secondaryButton("plus") { }
            Spacer()
            secondaryButton("slider.horizontal.3") { }
            Spacer()
            secondaryButton("airplayaudio") { }
            Spacer()
            secondaryButton("music.note.list") { isShowingQueue = true }
            Spacer()
            secondaryButton("square.and.arrow.up") { }
            Spacer()
        }
        .padding(.bottom, 18)
    }

    private func secondaryButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 21))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
    }
}
