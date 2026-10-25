// BSideCore — HostReassert: pure reducer for the bounded double-hop desktop-host reassert.
// WindowServer briefly detaches desktop-level windows during wake and Spaces animations, so the
// host must re-assert its level/collection behavior immediately AND once more on the next runloop
// turn (AuraFlow-proven double tap). The second hop is generation-scoped: only the current host
// generation may apply it, so a stale/delayed hop can never act on a replaced host. The Platform
// shell (DesktopHost) interprets `.reassertNow` as "apply level + collection + order", and
// `.scheduleReassert` as "dispatch the same reassert on the next runloop turn".

public struct HostReassert: Equatable {

    public enum Effect: Equatable {
        /// Apply the reassert now, on the triggering event's turn.
        case reassertNow
        /// Apply the reassert again on the next runloop turn, scoped to `generation`.
        case scheduleReassert(generation: Int)
    }

    /// Monotonic identity of the current host. Advances on every trigger AND on every
    /// install/teardown (host replacement), so a pending hop from an earlier host is stale.
    public private(set) var generation = 0

    public init() {}

    /// A wake / Spaces reassert trigger arrived. Returns an immediate reassert plus a
    /// generation-scoped second hop. Each trigger advances the generation, so the newest trigger
    /// supersedes any still-pending hop (a burst never accumulates N delayed reasserts).
    public mutating func onTrigger() -> [Effect] {
        generation += 1
        return [.reassertNow, .scheduleReassert(generation: generation)]
    }

    /// The delayed second hop for `generation` fires. True only when that generation is still the
    /// current host — a hop scheduled before a host replacement is a no-op.
    public mutating func reassertIfCurrent(generation: Int) -> Bool {
        generation == self.generation
    }

    /// The host was (re)installed or torn down: advance the generation so any in-flight hop from
    /// the previous host cannot act on the new one.
    public mutating func invalidate() {
        generation += 1
    }
}
