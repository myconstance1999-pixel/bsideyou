// BSideCore — bounded retention of a paused daily video's decode resources.
// This reducer owns timing intent only. The agent schedules one-shot work and the platform
// captures a still/releases players; neither media paths nor framework objects enter Core.

public struct DailyResourceLifecycle: Equatable {
    public enum Effect: Equatable {
        case schedule(token: Int, after: Double)
        case cancel
    }

    private enum Phase: Equatable {
        case inactive
        case waiting(token: Int, pausedSince: Double, deadline: Double)
        case consumed(token: Int)
    }

    private var phase = Phase.inactive
    public private(set) var generation = 0

    public init() {}

    /// Reconcile one daily resource's retention. `now` is finite monotonic time in seconds.
    /// A repeated pause does not refresh its budget. A stronger policy measures its shorter
    /// budget from the original pause, and may make release due immediately.
    ///
    /// Once a deadline is consumed, repeated paused updates never rearm it, including while
    /// asynchronous still capture is in flight or after capture fails. There is no automatic
    /// retry loop: resume/no resource resets the cycle; actual replacement must explicitly
    /// call `resourceReplaced()` before reconciling the new resource.
    public mutating func update(
        paused: Bool, hasVideo: Bool, retentionDelay: Double, now: Double
    ) -> [Effect] {
        precondition(now.isFinite, "Daily retention requires finite monotonic time")
        guard paused && hasVideo else {
            guard phase != .inactive else { return [] }
            return invalidate()
        }

        // An invalid retention budget must not retain the decoder indefinitely.
        let delay = retentionDelay.isFinite ? max(0, retentionDelay) : 0
        switch phase {
        case .inactive:
            generation += 1
            let deadline = boundedDeadline(start: now, delay: delay)
            phase = .waiting(token: generation, pausedSince: now, deadline: deadline)
            return [.schedule(token: generation, after: max(0, deadline - now))]

        case .waiting(_, let pausedSince, let deadline):
            let earlier = boundedDeadline(start: pausedSince, delay: delay)
            guard earlier < deadline else { return [] }
            generation += 1
            phase = .waiting(token: generation, pausedSince: pausedSince, deadline: earlier)
            return [.cancel, .schedule(token: generation, after: max(0, earlier - now))]

        case .consumed:
            return []
        }
    }

    /// Returns true at most once for the current timer. The shell must additionally guard
    /// asynchronous platform work against its own player/resource generation.
    public mutating func releaseDeadlineFired(token: Int) -> Bool {
        guard case .waiting(let current, _, _) = phase, token == current else { return false }
        phase = .consumed(token: token)
        return true
    }

    /// Use when daily ownership ends (performance starts, stop, or teardown). Advancing even
    /// from an inactive state keeps previously issued callback identities invalid forever.
    @discardableResult
    public mutating func invalidate() -> [Effect] {
        let needsCancel: Bool
        if case .waiting = phase { needsCancel = true } else { needsCancel = false }
        generation += 1
        phase = .inactive
        return needsCancel ? [.cancel] : []
    }

    /// The same paused intent may now refer to a different installed resource. Only an actual
    /// replacement starts a new retention cycle; a context or desired-scene change does not.
    @discardableResult
    public mutating func resourceReplaced() -> [Effect] { invalidate() }

    private func boundedDeadline(start: Double, delay: Double) -> Double {
        let deadline = start + delay
        return deadline.isFinite ? deadline : start
    }
}

extension PlaybackPolicy {
    /// Initial engineering budgets, not measured optimal values. Brief ordinary pauses retain
    /// a decoder for quick recovery; constrained conditions shorten retention. No viewer or
    /// memory pressure makes it immediately releasable. This only applies to daily video;
    /// a performance's exact playback position/session has a separate lifecycle.
    public static func dailyRetentionDelay(context: RuntimeContext, memoryPressure: Bool) -> Double {
        if memoryPressure || !context.systemAwake || !context.screenAwake || context.screenLocked || !context.sessionActive
            || context.thermal == .critical {
            return 0
        }
        if context.lowPowerMode || context.thermal == .serious { return 5 }
        return 30
    }
}
