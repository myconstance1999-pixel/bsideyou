// BSideCore — AgentLifecycle: pure value-type reducer for agent supervision (ADR-002/007).
// Owns every supervision decision — spawn/stop/backoff/degraded, launch generation identity,
// coalesced restart intent, and the bounded 10 s handshake deadline. The ControlApp shell only
// executes the returned effects with Process/Dispatch/FileHandle. This type knows nothing about
// Process, AppKit, Dispatch, concrete paths, or scheduling APIs (architecture gate #4).
//
// Exactly-one-process-slot invariant: the slot (`liveGeneration`) is freed only by that process's
// own termination event. A handshake timeout therefore does NOT free the slot, count a failure,
// or schedule a backoff; it stops waiting, emits a kill, and defers ALL failure accounting to the
// termination callback. A respawn can therefore never overlap a dying process. Every backoff
// schedule is armed with a monotonic identity token, and every backoffElapsed must match the
// currently armed token — a stale/cancelled timer is a reducer no-op.

import Foundation

public struct AgentLifecycle: Equatable {

    public enum Phase: String, Equatable {
        case idle       // no agent and no pending work
        case starting   // a launch is in flight, waiting for its handshake
        case running    // handshake complete, agent healthy
        case stopping   // teardown of a live agent (graceful stop, replacement, or timeout kill)
        case backoff    // waiting out a bounded abnormal-exit backoff
        case degraded   // max consecutive failures reached; waiting for explicit user action
    }

    /// The launch intent currently in force. Coalesced newest-wins: at most one live agent and
    /// exactly one replacement per restart request.
    public struct Pending: Equatable {
        public var assetPath: String
        public var desired: DesiredState
        public init(assetPath: String, desired: DesiredState) {
            self.assetPath = assetPath
            self.desired = desired
        }
    }

    public enum Event: Equatable {
        /// Start or restart intent (explicit; the newest assetPath/DesiredState wins).
        case start(assetPath: String, desired: DesiredState)
        /// Intentional stop (app quit / reset preferences): cancels any pending replacement.
        case stop
        /// A spawn could not be started (binary missing / run threw). Terminal until user acts.
        case spawnFailed(generation: Int, reason: String)
        /// The agent of `generation` completed its handshake.
        case ready(generation: Int)
        /// The agent of `generation` exited. `abnormal` = not an expected stop.
        case terminated(generation: Int, abnormal: Bool, reason: String)
        /// The 10 s handshake deadline for `generation` elapsed.
        case handshakeTimeout(generation: Int)
        /// A scheduled backoff delay elapsed. `token` must match the currently armed backoff;
        /// any other token is a stale/cancelled timer and is a no-op.
        case backoffElapsed(token: Int)
    }

    public enum Effect: Equatable {
        /// Spawn a new agent with identity `generation`; the shell replays initialize +
        /// this exact DesiredState, then arms the handshake deadline.
        case spawn(generation: Int, assetPath: String, desired: DesiredState, handshakeDeadline: TimeInterval)
        /// Gracefully shut the live agent down (shell escalates SIGTERM → SIGKILL).
        case shutdown
        /// Force-kill the live agent now (handshake timeout). `reason` is the failure
        /// disposition the shell must report back via `.terminated` when the process dies — the
        /// kill is a timeout failure, never a normal intentional restart.
        case kill(reason: String)
        /// Schedule a bounded abnormal-exit backoff before retrying. `token` identities THIS
        /// schedule; only `.backoffElapsed(token:)` with the same token may respawn.
        case scheduleBackoff(token: Int, after: TimeInterval)
        /// Enter DEGRADED and surface a user-visible reason.
        case degraded(reason: String)
    }

    public private(set) var phase: Phase = .idle
    /// Monotonic launch identity counter.
    public private(set) var generation: Int = 0
    /// Generation currently occupying the process slot; nil only when no agent is alive.
    public private(set) var liveGeneration: Int?
    /// The newest coalesced launch intent (nil once explicitly stopped).
    public private(set) var pending: Pending?
    public private(set) var consecutiveAbnormalExits: Int = 0
    /// Absolute deadline for the current generation's handshake (nil once ready/terminated).
    public private(set) var handshakeDeadline: TimeInterval?
    /// Identity of the currently armed backoff; a `.backoffElapsed` only matches this token.
    public private(set) var backoffToken: Int?
    /// Human-readable reason for the most recent failure (surfaced in diagnostics).
    public private(set) var lastFailureReason: String?

    /// Monotonic token source — never reset, so a stale token from an earlier schedule can never
    /// collide with a later one after a start/stop/ready/termination transition.
    private var nextBackoffToken = 0

    public static let maxConsecutiveFailures = 5
    public static let handshakeTimeout: TimeInterval = 10.0

    public init() {}

    // MARK: - Read-only acceptance helpers (for the effect shell's event gating)
    //
    // These mirror the reducer's own guards WITHOUT mutating state, so the shell can decide
    // whether an inbound event is current evidence. They change no lifecycle behavior: the
    // reducer still performs the authoritative acceptance check on `.ready` / `.terminated`.

    /// May `.ready` from `generation` complete the handshake? Only a live STARTING generation —
    /// a late ready from a timed-out, stopping, or already-replaced generation must not be
    /// forwarded as a healthy event.
    public func acceptsReady(generation: Int) -> Bool {
        generation == liveGeneration && phase == .starting
    }

    /// Is `generation`'s runtime evidence (snapshots, playback events) CURRENT? Only a RUNNING
    /// live generation's events may promote resourceStage or become the visible snapshot.
    public func acceptsRuntimeEvents(generation: Int) -> Bool {
        generation == liveGeneration && phase == .running
    }

    /// May `generation` still report user-visible failures (error/degraded)? Only a current
    /// starting or running process is authoritative. A stopping/timed-out process is already
    /// doomed; its late failure may be logged, but must not replace the truthful recovery state.
    public func acceptsFailureReports(generation: Int) -> Bool {
        generation == liveGeneration && (phase == .starting || phase == .running)
    }

    /// Fold one supervision event into zero or more effects the shell must execute.
    /// `now` is an absolute monotonic time (seconds) supplied by the caller for deadline math.
    public mutating func reduce(_ event: Event, now: TimeInterval = 0) -> [Effect] {
        switch event {
        case .start(let assetPath, let desired):
            pending = Pending(assetPath: assetPath, desired: desired)
            consecutiveAbnormalExits = 0
            backoffToken = nil                       // a fresh intent invalidates any armed backoff
            if liveGeneration == nil {
                return spawnNow(now: now)
            } else if phase != .stopping {
                // A live agent (running or starting) occupies the slot: stop it, then replace
                // on its termination. No arbitrary +0.4 s assumption — replacement is driven
                // by the termination event alone.
                phase = .stopping
                return [.shutdown]
            }
            return []

        case .stop:
            pending = nil
            handshakeDeadline = nil
            backoffToken = nil                       // quit/stop cancels any armed backoff
            guard liveGeneration != nil else {
                phase = .idle
                return []
            }
            if phase != .stopping {
                phase = .stopping
                return [.shutdown]
            }
            return []

        case .spawnFailed(let failedGeneration, let reason):
            guard failedGeneration == liveGeneration else { return [] }
            liveGeneration = nil
            handshakeDeadline = nil
            backoffToken = nil
            phase = .degraded
            lastFailureReason = reason
            return [.degraded(reason: reason)]

        case .ready(let readyGeneration):
            guard readyGeneration == liveGeneration, phase == .starting else { return [] }
            phase = .running
            handshakeDeadline = nil          // ready invalidates its deadline (a later timeout
            backoffToken = nil               // for this generation is already rejected)
            consecutiveAbnormalExits = 0     // a successful handshake resets the failure streak
            return []

        case .terminated(let terminatedGeneration, let abnormal, let reason):
            guard terminatedGeneration == liveGeneration else { return [] }
            liveGeneration = nil             // the process is really gone — the slot frees now
            handshakeDeadline = nil
            backoffToken = nil               // termination invalidates any armed backoff
            guard pending != nil else {
                // Quit/stop won: ANY termination with no intent in force — a timeout kill
                // included, regardless of signal classification — ends idle with no backoff
                // and no replacement.
                phase = .idle
                return []
            }
            guard abnormal else {
                // Expected stop with a pending replacement: swap immediately.
                return spawnNow(now: now)
            }
            consecutiveAbnormalExits += 1
            lastFailureReason = reason
            if consecutiveAbnormalExits >= Self.maxConsecutiveFailures {
                phase = .degraded
                return [.degraded(reason: "agent \(reason) ×\(consecutiveAbnormalExits) — auto-restart paused")]
            }
            let backoff = Self.backoff(afterFailures: consecutiveAbnormalExits)
            phase = .backoff
            nextBackoffToken += 1
            let token = nextBackoffToken
            backoffToken = token
            return [.scheduleBackoff(token: token, after: backoff)]

        case .handshakeTimeout(let timedOutGeneration):
            guard timedOutGeneration == liveGeneration, phase == .starting,
                  let deadline = handshakeDeadline, now >= deadline else { return [] }
            // The OS process may still be alive: the slot stays OCCUPIED. Stop waiting for the
            // handshake — clear the deadline, reject any late ready — and kill. Failure
            // accounting (exactly one count, then 1/2/4/8 backoff or DEGRADED at 5) happens on
            // THIS generation's termination event, so a respawn can never overlap the dying
            // process and no failure is double-counted.
            handshakeDeadline = nil
            lastFailureReason = "never became ready within \(Int(Self.handshakeTimeout))s"
            phase = .stopping
            return [.kill(reason: lastFailureReason!)]

        case .backoffElapsed(let token):
            guard token == backoffToken, phase == .backoff else { return [] }  // stale: no-op
            backoffToken = nil               // consume the matched token
            guard pending != nil else {
                // No intent in force: leave backoff rather than staying stuck in it.
                phase = .idle
                return []
            }
            return spawnNow(now: now)
        }
    }

    /// Update the recorded intent's DesiredState only (live user changes; no launch/stop).
    public mutating func recordDesired(_ desired: DesiredState) {
        pending?.desired = desired
    }

    /// Update the authorized directory's resolved location for future restart replay.
    /// Discovery changes do not themselves request a process restart or reset its backoff.
    public mutating func recordAssetPath(_ path: String) {
        pending?.assetPath = path
    }

    /// 1, 2, 4, 8 seconds; the 5th consecutive failure DEGRADEs instead of scheduling.
    static func backoff(afterFailures failures: Int) -> TimeInterval {
        let steps: [TimeInterval] = [1, 2, 4, 8]
        let index = max(0, min(failures - 1, steps.count - 1))
        return steps[index]
    }

    private mutating func spawnNow(now: TimeInterval) -> [Effect] {
        guard let pending else { return [] }
        generation += 1
        liveGeneration = generation
        phase = .starting
        backoffToken = nil                   // a new launch supersedes any armed backoff
        let deadline = now + Self.handshakeTimeout
        handshakeDeadline = deadline
        return [.spawn(
            generation: generation,
            assetPath: pending.assetPath,
            desired: pending.desired,
            handshakeDeadline: deadline)]
    }
}
