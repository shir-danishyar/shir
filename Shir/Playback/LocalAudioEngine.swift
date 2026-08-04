import AVFoundation
import Foundation
import ShirKit

/// Plays files the user imported. Unlike the YouTube engine this owns the audio
/// end to end, so it gets real background playback, lock screen controls and
/// AirPlay — the behaviour people actually want from a music app.
@MainActor
final class LocalAudioEngine: NSObject, PlaybackEngine {
    var onStateChange: ((EngineState) -> Void)?
    var onProgress: ((TimeInterval, TimeInterval) -> Void)?
    var onError: ((String) -> Void)?

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?

    override init() {
        super.init()
        player.actionAtItemEnd = .pause
        addPeriodicObserver()
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
    }

    // MARK: - PlaybackEngine

    func load(_ track: Track, autoplay: Bool) {
        guard let fileName = track.localFileName else {
            onError?("That track is not a local file.")
            return
        }
        let url = MediaLibraryLocation.mediaDirectory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            onError?("“\(track.title)” is missing from your library. It may have been deleted.")
            onStateChange?(.idle)
            return
        }

        onStateChange?(.buffering)
        let item = AVPlayerItem(url: url)
        observeEnd(of: item)
        player.replaceCurrentItem(with: item)

        if autoplay {
            activateAudioSession()
            player.play()
            onStateChange?(.playing)
        } else {
            onStateChange?(.paused)
        }
    }

    func play() {
        guard player.currentItem != nil else { return }
        activateAudioSession()
        player.play()
        onStateChange?(.playing)
    }

    func pause() {
        player.pause()
        onStateChange?(.paused)
    }

    func seek(to time: TimeInterval) {
        let target = CMTime(seconds: max(0, time), preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        onStateChange?(.idle)
    }

    // MARK: - Observation

    private func addPeriodicObserver() {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, let item = self.player.currentItem else { return }
                let duration = item.duration.seconds
                self.onProgress?(time.seconds, duration.isFinite ? duration : 0)
            }
        }
    }

    private func observeEnd(of item: AVPlayerItem) {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }

        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onStateChange?(.ended) }
        }

        failureObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                self?.onStateChange?(.idle)
                self?.onError?(error?.localizedDescription ?? "That file couldn't be played.")
            }
        }
    }

    /// Activated lazily rather than at launch so the app doesn't interrupt
    /// whatever else is playing until the user actually starts a song.
    private func activateAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch {
            onError?("Couldn't start audio: \(error.localizedDescription)")
        }
    }
}

/// Single place that knows where imported media lives, so the importer, the
/// engine and the delete path can't drift apart.
enum MediaLibraryLocation {
    static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var mediaDirectory: URL {
        documentsDirectory.appendingPathComponent("Media", isDirectory: true)
    }

    static func ensureMediaDirectoryExists() throws {
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
    }
}
