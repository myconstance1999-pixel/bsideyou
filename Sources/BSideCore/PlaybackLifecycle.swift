// BSideCore — PlaybackLifecycle: pure value-type reducer for the agent's AVFoundation stack.
// Owns the ONLY decisions about (a) when a transition→loop install is valid and (b) whether the
// ambient decode chain should be running. The Platform shell (PlaybackEngine) executes the
// returned effects against AVPlayer/AVPlayerLooper. This type knows nothing about AVFoundation,
// URLs, file paths, or the clock (architecture gate #4).
//
// Visual invariant (transition race): every beginVisual() mints a new monotonic generation; a
// transition-end event is honored only if it carries the CURRENT generation and the loop has not
// already been installed. A stale generation (an earlier switch) or a duplicate end event is a
// no-op — so a late callback can never resurrect an old loop.
//
// Ambient decode runs only at positive effective volume. An explicit soundtrack pause may retain
// the existing chain without advancing it; safety/mute/source changes still release it. Repeated
// intents are no-ops, and resuming a retained chain never rebuilds its item or resets its clock.

import Foundation

public struct PlaybackLifecycle: Equatable {

    // MARK: - Visual (transition → loop installation)

    /// Monotonic identity of the current visual target. Increments on every `beginVisual`;
    /// a transition-end event carrying any other value is stale and must be ignored.
    public private(set) var visualGeneration = 0

    /// True once the current target's loop has been installed (directly, or via a transition end).
    public private(set) var loopInstalled = false

    /// True while the current target is still waiting for its transition clip to end.
    public private(set) var transitionPending = false

    // MARK: - Ambient

    public enum AmbientEffect: Equatable {
        /// The ambient chain is already in the correct state — the shell must do nothing.
        case none
        /// Ensure exactly ONE running ambient chain for the current URL identity (start or rebuild).
        case run
        /// Pause/resume the retained chain without replacing its item.
        case pause, resume
        /// Ensure NO running ambient chain (tear down).
        case stop
    }

    /// Whether the ambient chain is currently meant to be running.
    public private(set) var ambientRunning = false
    public private(set) var ambientRetained = false

    /// Identity of the ambient asset the running chain is (or should be) built from.
    public private(set) var ambientURLIdentity: String?

    public init() {}

    // MARK: - Visual events

    /// Begin a new visual target. `transition` = a transition clip must play before the loop.
    /// Returns the generation token to hand to `transitionEnded(generation:)`.
    @discardableResult
    public mutating func beginVisual(transition: Bool) -> Int {
        visualGeneration += 1
        transitionPending = transition
        loopInstalled = !transition          // a direct target installs its loop immediately
        return visualGeneration
    }

    /// A transition clip ended for `generation`. Returns true only at the one moment the loop
    /// should be installed: it is the current target, a transition is still pending, and the loop
    /// has not been installed yet. A stale generation or a duplicate end event returns false.
    public mutating func transitionEnded(generation: Int) -> Bool {
        guard generation == visualGeneration, transitionPending, !loopInstalled else { return false }
        transitionPending = false
        loopInstalled = true
        return true
    }

    /// Invalidate all in-flight visual work and forget the shell's ambient chain. The generation
    /// advances instead of returning to zero so a callback captured before teardown can never
    /// collide with the next target if the same PlaybackEngine instance is reused.
    public mutating func reset() {
        visualGeneration += 1
        transitionPending = false
        loopInstalled = false
        ambientRunning = false
        ambientRetained = false
        ambientURLIdentity = nil
    }

    // MARK: - Ambient events

    /// `paused` is Core's explicit retention permission, not an inferred zero-volume pause.
    public mutating func updateAmbient(urlIdentity: String?, effectiveVolume: Double,
                                       paused: Bool = false) -> AmbientEffect {
        let urlChanged = urlIdentity != ambientURLIdentity
        ambientURLIdentity = urlIdentity
        if paused, urlIdentity != nil, ambientRetained, !urlChanged {
            guard ambientRunning else { return .none }
            ambientRunning = false
            return .pause
        }
        if !paused, urlIdentity != nil, effectiveVolume > 0 {
            if ambientRetained && !urlChanged {
                guard !ambientRunning else { return .none }
                ambientRunning = true
                return .resume
            }
            ambientRetained = true
            ambientRunning = true
            return .run
        }
        if ambientRetained {
            ambientRetained = false
            ambientRunning = false
            return .stop
        }
        return .none
    }
}
