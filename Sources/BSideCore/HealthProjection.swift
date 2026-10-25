// BSideCore — HealthProjection: ONE semantic health projection shared by the menu bar and the
// Control Center, so the two can never disagree. It folds resource-loading readiness, the pure
// supervision phase, failure kind, user pause intent, and the current runtime snapshot into a
// single Health state. It knows nothing about AppKit/SwiftUI colors or localized strings —
// BSideControlApp owns that rendering mapping (this file is Foundation-only, arch gate #4).
//
// Truth hierarchy (worst-wins, ADR-005 spirit):
//   1. resource validation failure/unavailable  → resourceUnavailable / serviceProblem
//   2. supervisor starting/stopping/backoff     → recovering  (never normal/green)
//   3. supervisor DEGRADED                      → serviceProblem (never normal/green)
//   4. idle/absent service                      → preparing   (never normal/green)
//   5. RUNNING: user/agent pause (nothing failing) → paused
//   6. RUNNING: current playing snapshot        → normal
//   7. RUNNING without a current playing snapshot  → preparing

public enum HealthProjection {

    /// Resource-loading lifecycle as the user sees it (semantic; NOT the ControlApp UI stage).
    public enum Readiness: String, Equatable {
        case unconfigured  // no resource selected yet
        case preparing     // selecting / validating / loading / starting playback
        case ready         // a current runtime snapshot has established a playable desktop
        case failed        // resource validation or playback failed
    }

    /// Why a failure is a failure — drives the user-visible resource-vs-service distinction.
    public enum FailureKind: String, Equatable {
        case resourceUnavailable  // the selected BSide resource cannot be read/validated
        case service              // agent/player-side problem
    }

    /// ONE semantic health state consumed by menu bar + Control Center.
    public enum Health: String, Equatable {
        case normal              // running generation + current playing snapshot
        case paused              // user or agent paused; nothing failing
        case preparing           // nothing failing, nothing playing (yet)
        case recovering          // supervisor starting/stopping/backoff
        case serviceProblem      // supervisor degraded or agent/player failure
        case resourceUnavailable // the selected resource cannot be read
    }

    /// Fold readiness + supervision truth + failure + pause intent + current snapshot into the
    /// single Health state. `snapshot` must already be current-generation evidence (the shell
    /// drops otherwise); the projection still never trusts it while the service is not running.
    public static func project(
        readiness: Readiness,
        service: AgentLifecycle.Phase,
        failure: FailureKind?,
        userPaused: Bool,
        snapshot: RuntimeSnapshot?
    ) -> Health {
        // 1. Resource validation failure/unavailable is highest-priority and user-friendly —
        //    it beats every supervision/runtime state, including a still-playing snapshot.
        if readiness == .failed {
            return failure == .resourceUnavailable ? .resourceUnavailable : .serviceProblem
        }
        switch service {
        case .starting, .stopping, .backoff:
            // Concise recovery state, never green — even with a stale playing snapshot around.
            return .recovering
        case .degraded:
            // DEGRADED must never show green/normal, even with an old playing snapshot.
            return .serviceProblem
        case .idle:
            // Absent service (no agent, no pending work): never normal, stale snapshot or not.
            return .preparing
        case .running:
            break
        }
        // A live old Agent may still be playing while the user selects or validates a new
        // resource directory. That playback snapshot must not hide the active preparation flow.
        guard readiness == .ready else { return .preparing }
        // 2. User pause shows paused only when it conceals nothing (failures already ranked) —
        //    a pause intent wins over a lagging playing snapshot.
        if userPaused || snapshot?.state == .paused { return .paused }
        // 3. Only a RUNNING generation with a CURRENT playing snapshot may be normal.
        if let snapshot, snapshot.state == .playing { return .normal }
        return .preparing
    }
}
