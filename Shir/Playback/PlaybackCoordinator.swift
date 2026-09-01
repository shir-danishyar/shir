import AVFoundation
import Foundation
import MediaPlayer
import ShirKit

enum PlaybackStatus: Equatable {
    case idle
    case buffering
    case playing
    case paused

    var isPlaying: Bool { self == .playing }
}

/// Owns the queue and routes it to whichever engine can play the current track.
///
/// Both engines keep playing with the screen off, by very different routes —
/// `LocalAudioEngine` through AVFoundation, `YouTubePlayerEngine` through the
/// machinery in CLAUDE.md §5 rule 10 — but the coordinator does not need to
/// care, which is the point of the `PlaybackEngine` protocol. Lock screen
/// *controls* are asymmetric by mechanism: local files get them via
/// `MPRemoteCommandCenter` normally, while YouTube presses arrive through the
/// page's media session (`MediaSession.js` → `handle(remoteCommand:)`),
/// because WebKit owns the card whenever web media plays.
///
/// Until 2026-08-04 the engines were deliberately asymmetric and YouTube
/// paused on backgrounding. That was an App Store constraint, and it left
/// with the App Store; see CLAUDE.md §4.
@MainActor
@Observable
final class PlaybackCoordinator {
    private(set) var queue = PlaybackQueue()
    private(set) var status: PlaybackStatus = .idle
    private(set) var position: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var errorMessage: String?

    /// Set while the user drags the scrubber so incoming progress ticks don't
    /// fight the thumb for control of its position.
    var isScrubbing = false

    /// Bumped whenever the *user* starts playback — tapping a song, shuffle,
    /// picking a queue item. `RootTabView` observes it and presents Now
    /// Playing, which is the reference app's behaviour and also a technical
    /// necessity: WebKit refuses to *start* media in a web view that is not
    /// genuinely visible (occluded, near-transparent, clipped and 1pt hosts
    /// were all measured to fail), and the Now Playing stage is the app's one
    /// visible mount. Queue auto-advance deliberately does not bump this —
    /// a track ending must not fling the cover open if the user closed it.
    private(set) var userPlaybackToken = 0

    let youtubeEngine: YouTubePlayerEngine
    private let localEngine: LocalAudioEngine

    var currentTrack: Track? { queue.current }
    var isShuffled: Bool { queue.isShuffled }
    var repeatMode: RepeatMode { queue.repeatMode }
    var hasActiveTrack: Bool { queue.current != nil }
    /// Drives whether the Now Playing screen shows the video surface or artwork.
    var isPlayingYouTube: Bool { queue.current?.youtubeVideoID != nil }

    /// Engines are optional rather than defaulted to fresh instances because a
    /// default argument is evaluated outside the actor, and both engines are
    /// main-actor isolated.
    init(youtubeEngine: YouTubePlayerEngine? = nil, localEngine: LocalAudioEngine? = nil) {
        let youtube = youtubeEngine ?? YouTubePlayerEngine()
        let local = localEngine ?? LocalAudioEngine()
        self.youtubeEngine = youtube
        self.localEngine = local
        wire(youtube)
        wire(local)
        youtube.onRemoteCommand = { [weak self] command in
            self?.handle(remoteCommand: command)
        }
        configureRemoteCommands()
    }

    /// Lock-screen and Control Center presses for YouTube tracks, forwarded by
    /// `MediaSession.js` — WebKit owns the card while web media plays, so
    /// `MPRemoteCommandCenter` never sees these (that path stays for
    /// `LocalAudioEngine`).
    ///
    /// Everything routes through the NORMAL control methods, with the same
    /// gates as the `MPRemoteCommandCenter` handlers below: `hasActiveTrack`,
    /// and the current track's engine — never a hardcoded one. The web view
    /// and its media session outlive `stop()`, so a stale card can still send
    /// presses after the queue is cleared or a local file has taken over;
    /// ungated, a `.play` restarted the dead YouTube video as ghost audio the
    /// UI showed as idle.
    ///
    /// There are no status writes here. The correction over the reverted
    /// `cf5e582`: the page's action handler pauses in-page, which
    /// `AutoResumePolicy` cannot see — so `.pause` must reach
    /// `youtubeEngine.pause()` (via `engine(for:)` whenever the current track
    /// is YouTube) for `notePause()` to run, or the policy treats the
    /// following "paused" state as unrequested and answers it: a lock-screen
    /// pause that un-pauses itself. The page posts the remote message before
    /// acting on the player at all, so `notePause()` beats the state event
    /// structurally — not by trusting YouTube's event timing.
    private func handle(remoteCommand command: RemoteCommand) {
        guard hasActiveTrack else { return }
        switch command {
        case .next: next()
        case .previous: previous()
        case .play: engine(for: currentTrack)?.play()
        case .pause: engine(for: currentTrack)?.pause()
        case let .seek(time): seek(to: time)
        }
    }

    // MARK: - Starting playback

    func play(_ tracks: [Track], startingAt index: Int) {
        guard !tracks.isEmpty else { return }
        queue.load(tracks, startingAt: index)
        userPlaybackToken += 1
        startCurrentTrack(autoplay: true)
    }

    func play(_ track: Track) {
        play([track], startingAt: 0)
    }

    /// Plays a collection with shuffle forced on, for the Shuffle button.
    func shufflePlay(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        if !queue.isShuffled { queue.toggleShuffle() }
        queue.load(tracks, startingAt: Int.random(in: 0..<tracks.count))
        userPlaybackToken += 1
        startCurrentTrack(autoplay: true)
    }

    // MARK: - Transport

    func togglePlayPause() {
        guard hasActiveTrack else { return }
        if status.isPlaying {
            engine(for: currentTrack)?.pause()
        } else {
            engine(for: currentTrack)?.play()
        }
    }

    func next() {
        guard queue.skipForward() != nil else { return }
        startCurrentTrack(autoplay: true)
    }

    /// Restarts the current song if the user is more than three seconds in,
    /// which is the behaviour every other music player has trained people to expect.
    func previous() {
        if position > 3 {
            seek(to: 0)
            return
        }
        guard queue.skipBackward() != nil else { return }
        startCurrentTrack(autoplay: true)
    }

    func playItem(at index: Int) {
        guard queue.jump(to: index) != nil else { return }
        startCurrentTrack(autoplay: true)
    }

    func seek(to time: TimeInterval) {
        position = time
        engine(for: currentTrack)?.seek(to: time)
        updateNowPlayingInfo()
    }

    func toggleShuffle() {
        queue.toggleShuffle()
    }

    func cycleRepeatMode() {
        queue.repeatMode = queue.repeatMode.next
    }

    // MARK: - Queue editing

    func playNext(_ track: Track) { queue.playNext(track) }

    func playLast(_ track: Track) {
        let wasEmpty = queue.isEmpty
        queue.playLast(track)
        if wasEmpty {
            userPlaybackToken += 1
            startCurrentTrack(autoplay: true)
        }
    }

    func removeFromQueue(at index: Int) {
        let wasCurrent = index == queue.currentIndex
        queue.remove(at: index)
        guard wasCurrent else { return }
        if queue.current == nil {
            stop()
        } else {
            startCurrentTrack(autoplay: status.isPlaying)
        }
    }

    func moveInQueue(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        queue.move(fromOffsets: offsets, toOffset: destination)
    }

    func stop() {
        youtubeEngine.stop()
        localEngine.stop()
        queue.clear()
        status = .idle
        position = 0
        duration = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func clearError() { errorMessage = nil }

    // MARK: - Lifecycle

    /// Called when the app leaves the foreground.
    ///
    /// Deliberately does nothing. This used to pause YouTube tracks, because
    /// the app was aiming at the App Store, where keeping the IFrame player
    /// running with the app backgrounded is the specific behaviour that gets a
    /// client pulled. Shir is now a personal-device build (CLAUDE.md §4), so
    /// both sources keep playing.
    ///
    /// Kept as a hook rather than deleted: it is the single place to reinstate
    /// the pause if this app is ever pointed back at the App Store, and the
    /// scene-phase wiring in `ShirApp` already calls it.
    func applicationDidEnterBackground() {}

    // MARK: - Engine plumbing

    private func engine(for track: Track?) -> PlaybackEngine? {
        guard let track else { return nil }
        switch track.source {
        case .youtube: return youtubeEngine
        case .localFile: return localEngine
        }
    }

    /// Loads whatever the cursor points at, stopping the other engine so two
    /// songs can never play over each other.
    private func startCurrentTrack(autoplay: Bool) {
        guard let track = queue.current else { return }
        position = 0
        duration = track.duration ?? 0

        switch track.source {
        case .youtube:
            localEngine.stop()
            youtubeEngine.load(track, autoplay: autoplay)
        case .localFile:
            youtubeEngine.stop()
            localEngine.load(track, autoplay: autoplay)
        }
        updateNowPlayingInfo()
    }

    private func wire(_ engine: PlaybackEngine) {
        engine.onStateChange = { [weak self] state in
            self?.handle(state: state, from: engine)
        }
        engine.onProgress = { [weak self] position, duration in
            self?.handleProgress(position: position, duration: duration, from: engine)
        }
        engine.onError = { [weak self] message in
            self?.errorMessage = message
        }
    }

    /// Ignores events from the engine that is not currently in charge — a
    /// stopping engine emits a final `.idle` that would otherwise clobber the
    /// state of the track just started on the other one.
    private func isActive(_ engine: PlaybackEngine) -> Bool {
        guard let active = self.engine(for: currentTrack) else { return false }
        return active === engine
    }

    private func handle(state: EngineState, from engine: PlaybackEngine) {
        guard isActive(engine) else { return }

        switch state {
        case .idle:
            status = .idle
        case .buffering:
            status = .buffering
        case .playing:
            status = .playing
        case .paused:
            status = .paused
        case .ended:
            advanceAfterTrackEnded()
        }
        updateNowPlayingInfo()
    }

    private func handleProgress(position: TimeInterval, duration: TimeInterval, from engine: PlaybackEngine) {
        guard isActive(engine), !isScrubbing else { return }
        self.position = position
        if duration > 0 { self.duration = duration }
        updateNowPlayingInfo()
    }

    private func advanceAfterTrackEnded() {
        guard let next = queue.advanceAtEndOfTrack() else {
            status = .paused
            position = 0
            return
        }
        // Repeat-one returns the same track, which still needs a seek-to-zero
        // rather than a reload so playback is gapless.
        if next.id == currentTrack?.id, queue.repeatMode == .one {
            seek(to: 0)
            engine(for: next)?.play()
            return
        }
        startCurrentTrack(autoplay: true)
    }

    // MARK: - Lock screen and remote controls

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            guard let self, self.hasActiveTrack else { return .noSuchContent }
            self.engine(for: self.currentTrack)?.play()
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self, self.hasActiveTrack else { return .noSuchContent }
            self.engine(for: self.currentTrack)?.pause()
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self, self.hasActiveTrack else { return .noSuchContent }
            self.togglePlayPause()
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            guard let self, self.hasActiveTrack else { return .noSuchContent }
            self.next()
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            guard let self, self.hasActiveTrack else { return .noSuchContent }
            self.previous()
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self.seek(to: event.positionTime)
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        guard let track = currentTrack else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        // While the page's video plays, WebKit republishes MediaRemote with a
        // REPLACE policy within a tick of anything written here — the YouTube
        // card is MediaSession.js's to maintain, and writing anyway is two
        // clobbered XPC round trips per second for hours. This center is the
        // local engine's.
        guard case .localFile = track.source else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: status.isPlaying ? 1.0 : 0.0,
        ]
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
