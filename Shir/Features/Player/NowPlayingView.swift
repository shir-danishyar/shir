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
///
/// This is a layer in `RootTabView`'s `ZStack`, not a `fullScreenCover`. A
/// `.fullScreen` presentation removes the presenting view from the window once
/// it settles, so a pull-down would expose black rather than the library behind
/// — measured, not assumed. Being a sibling of the offstage web-view host also
/// retires an entire UIKit presentation lifecycle, which §9 records being burned
/// by twice.
struct NowPlayingView: View {
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(LibraryStore.self) private var library

    /// Closes the screen. An explicit closure rather than
    /// `@Environment(\.dismiss)` because this is no longer a presentation —
    /// it is a layer in `RootTabView`'s stack, and `dismiss` has nothing to
    /// act on.
    let onDismiss: () -> Void

    @State private var isShowingQueue = false
    @State private var scrubPosition: TimeInterval = 0
    @State private var drag = NowPlayingDragPolicy()

    var body: some View {
        // The stage needs a width it does not have to negotiate for, and a
        // VStack cannot give it one — see `stage(width:)`. Reading the width
        // once here is what makes the size definite. The height is read for a
        // second reason: it is what a pull-down is measured against.
        GeometryReader { proxy in
            ZStack {
                Theme.background.ignoresSafeArea()

                VStack(spacing: 0) {
                    header(screenHeight: proxy.size.height)
                    stage(width: proxy.size.width)
                    scrubber
                    trackInfo
                    Spacer(minLength: 8)
                    transportControls
                    Spacer(minLength: 8)
                    secondaryControls
                }
            }
            // Deliberately no scale and no corner rounding while dragging:
            // scaling would resize the web view's frame on every frame and make
            // WebKit re-lay-out the page sixty times a second for decoration.
            .offset(y: drag.offset)
            .simultaneousGesture(dismissDrag(screenHeight: proxy.size.height))
        }
        .sheet(isPresented: $isShowingQueue) {
            QueueView()
                .presentationDetents([.medium, .large])
        }
    }

    // MARK: - Header

    private func header(screenHeight: CGFloat) -> some View {
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
                Button { animateOut(screenHeight: screenHeight) } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(Theme.primaryText)
                        .frame(width: 44, height: 44)
                }
                .accessibilityIdentifier("dismissNowPlaying")
                .accessibilityLabel("Close Now Playing")
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

    // MARK: - Pull down to dismiss

    /// The one way out, shared by the chevron and the pull so that tapping and
    /// dragging produce the same motion rather than two different dismissals.
    private func animateOut(screenHeight: CGFloat) {
        withAnimation(.snappy(duration: 0.25), completionCriteria: .logicallyComplete) {
            drag.settle(at: screenHeight)
        } completion: {
            onDismiss()
            drag.reset()
        }
    }

    /// Attached with `simultaneousGesture` rather than `gesture`: a plain
    /// `.gesture` on a container enters arbitration against every Button and
    /// Slider inside it and loses unpredictably. Running alongside them keeps
    /// the transport buttons and the heart behaving normally — a tap still
    /// fires, a drag that leaves the button does not — and leaves
    /// `NowPlayingDragPolicy`, rather than SwiftUI, deciding when not to move.
    ///
    /// The stage needs nothing special: the web view has
    /// `isUserInteractionEnabled = false`, so touches over the video already
    /// fall through to here.
    private func dismissDrag(screenHeight: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: NowPlayingDragPolicy.directionLockDistance)
            .onChanged { value in
                drag.update(translation: value.translation, isScrubbing: playback.isScrubbing)
            }
            .onEnded { value in
                switch drag.resolve(predictedEnd: value.predictedEndTranslation,
                                    screenHeight: screenHeight) {
                case .dismiss:
                    animateOut(screenHeight: screenHeight)
                case .restore:
                    withAnimation(.snappy(duration: 0.3)) { drag.reset() }
                }
            }
    }

    // MARK: - Stage

    /// The video for YouTube tracks, artwork for imported files: one box, edge
    /// to edge, 16:9, sized here rather than by each branch.
    ///
    /// It has to be a *definite* size, and that is the whole reason this takes
    /// a width instead of asking for one. The stage used to say
    /// `.aspectRatio(16.0 / 9.0, contentMode: .fit)` inside the VStack, which
    /// reads as "be 16:9" but means "fit 16:9 inside whatever you are offered".
    /// A stack offers each child a *share* of the height left over, and `.fit`
    /// shrinks the width to match — a video barely half the screen wide,
    /// correctly proportioned and far too small (CLAUDE.md §9 has the measured
    /// numbers). `.frame(maxWidth: .infinity)` after it widened the frame but
    /// not the video inside, which is why the result was centred rather than
    /// stretched.
    ///
    /// Mounting is more subtle than it looks, and the old comment here — "un-
    /// mounting the view suspends the media element" — turned out to be only
    /// half true. WebKit suspends *silent* elements in a hidden page, which is
    /// why a track cannot *start* unless this stage is mounted: it begins
    /// muted, and a suspended element never reaches the "playing" state that
    /// triggers the bridge's unmute. An *audibly playing*
    /// element is explicitly spared, which is why the mini-player posture
    /// keeps playing with no mount at all. Backgrounding is a different pause
    /// entirely — WebKit force-pauses video sessions when the app leaves the
    /// foreground, mounted or not — and the engine answers that one itself;
    /// see `AutoResumePolicy` in ShirKit.
    private func stage(width: CGFloat) -> some View {
        let height = (width / Theme.videoAspectRatio).rounded()

        return Group {
            if playback.isPlayingYouTube {
                YouTubePlayerView(engine: playback.youtubeEngine)
            } else {
                VideoThumbnail(
                    url: playback.currentTrack?.artworkURL,
                    width: width,
                    height: height,
                    seed: abs(playback.currentTrack?.id.hashValue ?? 0)
                )
            }
        }
        .frame(width: width, height: height)
        .background(Color.black)
        // The web view disables interaction, so there is nothing inside worth
        // exposing — flattening it gives NowPlayingStageTests one element whose
        // frame is the stage's frame.
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("playerStage")
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
                    // Seed from the live position before `isScrubbing` flips
                    // the binding over to `scrubPosition`. A touch that never
                    // drags never calls the setter, so without this, resting a
                    // finger on the thumb and lifting seeks to whatever stale
                    // value was there — 0 on first use, which restarts the
                    // song.
                    if editing { scrubPosition = playback.position }
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
            .accessibilityIdentifier("favoriteToggle")
            .accessibilityLabel(isSaved ? "Remove from Favorites" : "Add to Favorites")
        }
        .padding(.horizontal, 14)
        .padding(.top, 18)
    }

    private var isSaved: Bool {
        guard let track = playback.currentTrack else { return false }
        return library.isFavorite(track.id)
    }

    /// The heart is the only control that adds to My Favorites. Unfavoriting
    /// leaves the track in the catalogue, so playlists that contain it and the
    /// queue that is playing it are unaffected.
    private func toggleSaved() {
        guard let track = playback.currentTrack else { return }
        library.toggleFavorite(track)
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
