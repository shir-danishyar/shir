/// Decides whether a pause the app never asked for should be answered with an
/// immediate play.
///
/// The consumer is `YouTubePlayerEngine`. WebKit force-pauses video sessions
/// when the app backgrounds, and the counter is to play again — but "the app
/// did not ask for this pause" is not enough to justify resuming, because
/// several very different things pause a player and only one of them wants
/// answering:
///
/// | Who paused | Answer? |
/// |---|---|
/// | WebKit, because the app backgrounded | **yes** — the whole point |
/// | The user, via the app or a remote command | no |
/// | iOS, for a call/Siri/another app | no, until iOS says the interruption ended *and* that resuming is appropriate |
/// | iOS, because headphones were unplugged | no — resuming plays out loud in a room |
/// | The player, because the track ended or errored | no |
///
/// Getting this wrong is not subtle: answering a route-change pause blasts
/// music out of the phone speaker the moment AirPods disconnect, which is the
/// exact thing that pause exists to prevent.
public struct AutoResumePolicy: Equatable, Sendable {
    /// True while the app wants audio: something asked for playback and
    /// nothing has since taken it away.
    public private(set) var wantsPlayback = false

    /// True while iOS owns the audio — a call, Siri, or another app. Resuming
    /// during an interruption both fails and fights the system, so the policy
    /// stays out of the way until iOS says the interruption ended.
    public private(set) var isInterrupted = false

    /// True when playback was torn down rather than merely paused: stopped,
    /// finished, or failed. A late player event must not re-arm a queue that
    /// is over.
    private var isFinished = true

    private var attempts = 0
    private let maxAttempts: Int

    public init(maxAttempts: Int = 3) {
        self.maxAttempts = maxAttempts
    }

    // MARK: - What the app asked for

    public mutating func noteLoad(autoplay: Bool) {
        isFinished = false
        isInterrupted = false
        wantsPlayback = autoplay
        attempts = 0
    }

    public mutating func notePlay() {
        isFinished = false
        isInterrupted = false
        wantsPlayback = true
    }

    public mutating func notePause() {
        wantsPlayback = false
    }

    /// Playback is over — stopped by the app, ended by the queue running out,
    /// or abandoned after an error or a failed navigation. All four mean the
    /// same thing to this type: stop wanting audio, and do not let a late
    /// event from the dead player start it again.
    public mutating func notePlaybackEnded() {
        wantsPlayback = false
        isInterrupted = false
        isFinished = true
        attempts = 0
    }

    // MARK: - What iOS did

    public mutating func noteInterruptionBegan() {
        isInterrupted = true
    }

    /// - Parameter shouldResume: iOS's own advice, from
    ///   `AVAudioSession.InterruptionOptions.shouldResume`. When it is false
    ///   the user is expected to press play themselves.
    /// - Returns: whether playback should be restarted now.
    public mutating func noteInterruptionEnded(shouldResume: Bool) -> Bool {
        isInterrupted = false
        guard shouldResume, wantsPlayback, !isFinished else { return false }
        attempts = 0
        return true
    }

    /// Headphones or a Bluetooth device went away. iOS pauses, and it is right
    /// to — the user took the audio off their head.
    public mutating func noteOutputDeviceDisconnected() {
        wantsPlayback = false
    }

    // MARK: - What the player reported

    public mutating func notePlaying() {
        attempts = 0
        // Audio that is genuinely running is audio the app wants. Without
        // this, playback WebKit resumed by itself — which it does on
        // foregrounding — would leave audible sound with `wantsPlayback`
        // false, so the next home press would not be answered and the music
        // would die: the very regression this type exists to prevent.
        if !isFinished, !isInterrupted { wantsPlayback = true }
    }

    /// Whether a reported pause the app never requested should be answered
    /// with a play. Consumes one attempt when it says yes.
    ///
    /// The cap bounds *consecutive* failures, because `notePlaying` re-arms it:
    /// backgrounding the app repeatedly is legitimate and must work every
    /// time. What stops an endless fight with a recurring pauser is knowing
    /// who paused — the interruption and route-change cases above — not the
    /// counter.
    public mutating func shouldResumeAfterUnrequestedPause() -> Bool {
        guard wantsPlayback, !isInterrupted, !isFinished, attempts < maxAttempts else { return false }
        attempts += 1
        return true
    }
}
