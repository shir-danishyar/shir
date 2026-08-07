import CoreGraphics

/// Where the Now Playing screen sits while a finger is dragging it, and what a
/// release means.
///
/// The consumer is `NowPlayingView`. The gesture covers the whole screen, which
/// is what makes it easy to reach and also what makes it dangerous: the
/// scrubber lives in the middle of that area, and a seek that turned into a
/// dismiss would be worse than having no gesture at all. Two independent rules
/// stop that, because SwiftUI's gesture arbitration is not something to bet the
/// behaviour on:
///
/// | Rule | Stops |
/// |---|---|
/// | Stand down entirely while the slider has the touch | a seek being read as a pull |
/// | Lock direction once, on the first real movement | a horizontal drag anywhere else becoming a dismiss |
///
/// The lock is decided once per drag and never revisited. A drag that began
/// sideways stays rejected even if it ends up travelling the length of the
/// screen — otherwise a seek that drifted downward at the end would dismiss.
public struct NowPlayingDragPolicy: Equatable, Sendable {
    public enum Resolution: Equatable, Sendable {
        case dismiss
        case restore
    }

    /// How far a finger must travel before the drag commits to a direction.
    /// Matches the gesture's own `minimumDistance`, so the first translation
    /// this type ever sees is already a deliberate movement.
    public static let directionLockDistance: CGFloat = 10

    /// Upward drags move at a fifth of the finger. The screen is already at the
    /// top; the resistance says so without forbidding the movement.
    public static let upwardResistance: CGFloat = 5

    /// However hard it is pulled, the player never lifts more than this.
    public static let maximumUpwardOffset: CGFloat = 60

    /// Release past this much of the screen and it closes.
    public static let dismissFraction: CGFloat = 0.25

    /// Or release with enough speed that it would have travelled this far.
    public static let flickFraction: CGFloat = 0.5

    /// How far the player should be moved down from its resting place.
    public private(set) var offset: CGFloat = 0

    /// True once this drag has been ruled out as a dismissal. Never clears
    /// until `reset()`.
    public private(set) var isRejected = false

    private var hasLockedDirection = false

    public init() {}

    /// - Parameter isScrubbing: whether the scrubber currently owns the touch.
    ///   The slider's `onEditingChanged(true)` fires on touch-down, before the
    ///   gesture's minimum distance is met, so this is already true by the time
    ///   a seek produces its first translation.
    public mutating func update(translation: CGSize, isScrubbing: Bool) {
        if isScrubbing { isRejected = true }
        guard !isRejected else {
            offset = 0
            return
        }

        if !hasLockedDirection {
            let distance = (translation.width * translation.width
                + translation.height * translation.height).squareRoot()
            guard distance >= Self.directionLockDistance else {
                offset = 0
                return
            }
            hasLockedDirection = true
            if abs(translation.width) > abs(translation.height) {
                isRejected = true
                offset = 0
                return
            }
        }

        offset = Self.resisted(translation.height)
    }

    /// - Parameter predictedEnd: SwiftUI's `predictedEndTranslation` — where the
    ///   drag would have finished at its release speed. It is how a short, fast
    ///   flick reads as the dismissal it plainly is.
    public func resolve(predictedEnd: CGSize, screenHeight: CGFloat) -> Resolution {
        guard !isRejected else { return .restore }
        if offset > screenHeight * Self.dismissFraction { return .dismiss }
        if predictedEnd.height > screenHeight * Self.flickFraction { return .dismiss }
        return .restore
    }

    /// Drives the offset to a resting place the drag did not reach — the target
    /// of the exit animation, which the chevron uses too so that tapping and
    /// pulling produce the same motion.
    public mutating func settle(at offset: CGFloat) {
        self.offset = offset
    }

    public mutating func reset() {
        offset = 0
        isRejected = false
        hasLockedDirection = false
    }

    private static func resisted(_ height: CGFloat) -> CGFloat {
        guard height < 0 else { return height }
        return -min(-height / upwardResistance, maximumUpwardOffset)
    }
}
