// BSideTestRunner — Beta Slice 2 suites: semantic health projection + runtime-evidence acceptance.
// These exercise the EXACT projection BSideControlApp drives for the menu bar and Control Center
// (HealthProjection.project) and the EXACT read-only gates AgentSupervisor consults before
// letting a runtime event reach the app state machine (AgentLifecycle.acceptsReady /
// acceptsRuntimeEvents / acceptsFailureReports). Production-used logic, not a test mirror.

import Foundation
import BSideCore

private func snapshot(state: AgentState) -> RuntimeSnapshot {
    RuntimeSnapshot(state: state, currentClip: "loop://A/R1/1200")
}

private func firstSpawnGeneration(_ effects: [AgentLifecycle.Effect]) -> Int? {
    for case .spawn(let generation, _, _, _) in effects { return generation }
    return nil
}

func runHealthProjectionTests() {
    run("Health.degradedWithStalePlayingIsServiceProblemNotNormal") { t in
        let h = HealthProjection.project(
            readiness: .ready, service: .degraded, failure: nil,
            userPaused: false, snapshot: snapshot(state: .playing))
        t.expectEqual(h, .serviceProblem, "degraded + stale playing → service problem")
        t.expect(h != .normal, "degraded must never project normal/green")
    }

    run("Health.recoveryPhasesWithStalePlayingAreRecovering") { t in
        let phases: [AgentLifecycle.Phase] = [.starting, .stopping, .backoff]
        for phase in phases {
            let h = HealthProjection.project(
                readiness: .ready, service: phase, failure: nil,
                userPaused: false, snapshot: snapshot(state: .playing))
            t.expectEqual(h, .recovering, "\(phase.rawValue) + stale playing → recovering")
            t.expect(h != .normal, "\(phase.rawValue) must never project normal/green")
        }
    }

    run("Health.idleAbsentWithStalePlayingIsNotNormal") { t in
        let h = HealthProjection.project(
            readiness: .ready, service: .idle, failure: nil,
            userPaused: false, snapshot: snapshot(state: .playing))
        t.expectEqual(h, .preparing, "idle/absent + stale playing → preparing")
        t.expect(h != .normal, "idle/absent must never project normal/green")
    }

    run("Health.runningWithPlayingSnapshotIsNormal") { t in
        let h = HealthProjection.project(
            readiness: .ready, service: .running, failure: nil,
            userPaused: false, snapshot: snapshot(state: .playing))
        t.expectEqual(h, .normal, "running + current playing snapshot → normal")
    }

    run("Health.runningWithoutCurrentSnapshotIsNotNormal") { t in
        let h = HealthProjection.project(
            readiness: .ready, service: .running, failure: nil,
            userPaused: false, snapshot: nil)
        t.expectEqual(h, .preparing, "running but no current snapshot → preparing, not normal")
    }

    run("Health.resourceFailureWinsOverAllOtherStates") { t in
        let unavailable = HealthProjection.project(
            readiness: .failed, service: .running, failure: .resourceUnavailable,
            userPaused: false, snapshot: snapshot(state: .playing))
        t.expectEqual(unavailable, .resourceUnavailable, "unavailable beats running + playing")

        let serviceFailed = HealthProjection.project(
            readiness: .failed, service: .degraded, failure: .service,
            userPaused: true, snapshot: snapshot(state: .playing))
        t.expectEqual(serviceFailed, .serviceProblem, "service failure beats degraded + paused")

        let unknownKind = HealthProjection.project(
            readiness: .failed, service: .running, failure: nil,
            userPaused: false, snapshot: snapshot(state: .playing))
        t.expectEqual(unknownKind, .serviceProblem, "failed without a kind defaults to service problem")
    }

    run("Health.userPauseNeverConcealsDegradedOrResourceFailure") { t in
        let degraded = HealthProjection.project(
            readiness: .ready, service: .degraded, failure: nil,
            userPaused: true, snapshot: snapshot(state: .paused))
        t.expectEqual(degraded, .serviceProblem, "pause must not conceal degraded")
        t.expect(degraded != .paused, "never paused while degraded")

        let resourceFailed = HealthProjection.project(
            readiness: .failed, service: .running, failure: .resourceUnavailable,
            userPaused: true, snapshot: snapshot(state: .paused))
        t.expectEqual(resourceFailed, .resourceUnavailable, "pause must not conceal resource failure")
    }

    run("Health.cleanRunningPauseIsPaused") { t in
        let user = HealthProjection.project(
            readiness: .ready, service: .running, failure: nil,
            userPaused: true, snapshot: snapshot(state: .playing))
        t.expectEqual(user, .paused, "user pause with nothing failing → paused")

        let agent = HealthProjection.project(
            readiness: .ready, service: .running, failure: nil,
            userPaused: false, snapshot: snapshot(state: .paused))
        t.expectEqual(agent, .paused, "agent pause with nothing failing → paused")
    }

    run("Health.notReadyReadinessProjectsPreparing") { t in
        for readiness in [HealthProjection.Readiness.unconfigured, .preparing] {
            let h = HealthProjection.project(
                readiness: readiness, service: .running, failure: nil,
                userPaused: false, snapshot: snapshot(state: .playing))
            t.expectEqual(h, .preparing,
                          "\(readiness.rawValue) + running old snapshot → preparing")
        }
    }
}

func runRuntimeAcceptanceTests() {
    run("RuntimeEvidence.onlyRunningLiveGenerationAccepts") { t in
        var lc = AgentLifecycle()
        let first = lc.reduce(.start(assetPath: "/a", desired: DesiredState()), now: 0)
        guard let g1 = firstSpawnGeneration(first) else { t.expect(false, "spawn1"); return }

        // Starting: handshake acceptable; runtime evidence NOT (a starting agent is not yet a
        // healthy source of snapshots); live failures are real (e.g. validation error).
        t.expect(lc.acceptsReady(generation: g1), "ready acceptable while starting")
        t.expect(!lc.acceptsRuntimeEvents(generation: g1), "snapshots rejected while starting")
        t.expect(lc.acceptsFailureReports(generation: g1), "starting agent failures are real")

        _ = lc.reduce(.ready(generation: g1), now: 1)
        t.expectEqual(lc.phase, .running, "running after accepted ready")
        t.expect(!lc.acceptsReady(generation: g1), "a second ready is not acceptable")
        t.expect(lc.acceptsRuntimeEvents(generation: g1), "runtime evidence acceptable while running")
        t.expect(lc.acceptsFailureReports(generation: g1), "live running agent may report failures")

        // Restart intent: stopping — snapshots must be dropped even though the process is live.
        _ = lc.reduce(.start(assetPath: "/a", desired: DesiredState()), now: 2)
        t.expectEqual(lc.phase, .stopping, "stopping after restart intent")
        t.expect(!lc.acceptsRuntimeEvents(generation: g1), "no runtime evidence while stopping")
        t.expect(!lc.acceptsFailureReports(generation: g1),
                 "stopping agent failure cannot replace recovery state")
    }

    run("RuntimeEvidence.staleGenerationNeverAccepted") { t in
        var lc = AgentLifecycle()
        let first = lc.reduce(.start(assetPath: "/a", desired: DesiredState()), now: 0)
        guard let g1 = firstSpawnGeneration(first) else { t.expect(false, "spawn1"); return }
        _ = lc.reduce(.handshakeTimeout(generation: g1), now: 10)
        t.expect(!lc.acceptsFailureReports(generation: g1),
                 "timed-out stopping generation cannot replace recovery state")
        let fail = lc.reduce(.terminated(generation: g1, abnormal: true, reason: "never became ready within 10s"), now: 11)
        guard case .scheduleBackoff(let token, _) = fail.first else { t.expect(false, "backoff"); return }
        let respawn = lc.reduce(.backoffElapsed(token: token), now: 12)
        guard let g2 = firstSpawnGeneration(respawn) else { t.expect(false, "spawn2"); return }
        _ = lc.reduce(.ready(generation: g2), now: 13)
        t.expectEqual(lc.phase, .running, "gen2 running")

        // gen1 is freed: NOTHING from it is acceptable evidence any more.
        t.expect(!lc.acceptsReady(generation: g1), "stale ready rejected")
        t.expect(!lc.acceptsRuntimeEvents(generation: g1), "stale snapshot rejected")
        t.expect(!lc.acceptsFailureReports(generation: g1), "stale failure report rejected")

        // Only the running gen2 accepts runtime evidence.
        t.expect(lc.acceptsRuntimeEvents(generation: g2), "gen2 running evidence accepted")
        t.expect(!lc.acceptsReady(generation: g2), "gen2 already ready")
    }

    run("RuntimeEvidence.backoffAndDegradedAcceptNothing") { t in
        var lc = AgentLifecycle()
        let first = lc.reduce(.start(assetPath: "/a", desired: DesiredState()), now: 0)
        guard let g1 = firstSpawnGeneration(first) else { t.expect(false, "spawn1"); return }

        // Abnormal exit → backoff: slot freed, nothing from the dead generation is acceptable.
        let fail = lc.reduce(.terminated(generation: g1, abnormal: true, reason: "crashed with signal 11"), now: 1)
        guard case .scheduleBackoff(let token, _) = fail.first else { t.expect(false, "backoff"); return }
        t.expectEqual(lc.phase, .backoff, "backoff")
        t.expect(!lc.acceptsReady(generation: g1), "no ready during backoff")
        t.expect(!lc.acceptsRuntimeEvents(generation: g1), "no runtime evidence during backoff")
        t.expect(!lc.acceptsFailureReports(generation: g1), "dead generation cannot report failures")
        t.expectEqual(lc.reduce(.backoffElapsed(token: 999), now: 1.5), [], "stale backoff token ignored")

        // Backoff chain: g1 counts 1, then 3 more counted failures, then the 5th → DEGRADED.
        var gen = g1
        let respawn1 = lc.reduce(.backoffElapsed(token: token), now: 2)
        guard let g2 = firstSpawnGeneration(respawn1) else { t.expect(false, "spawn2"); return }
        gen = g2
        for _ in 0..<3 {
            let fx = lc.reduce(.terminated(generation: gen, abnormal: true, reason: "crashed with signal 11"), now: 3)
            guard case .scheduleBackoff(let tk, _) = fx.first else { t.expect(false, "backoff chain"); return }
            t.expect(!lc.acceptsRuntimeEvents(generation: gen), "no runtime evidence while backing off")
            let r = lc.reduce(.backoffElapsed(token: tk), now: 4)
            guard let next = firstSpawnGeneration(r) else { t.expect(false, "respawn chain"); return }
            gen = next
        }
        let fifth = lc.reduce(.terminated(generation: gen, abnormal: true, reason: "crashed with signal 11"), now: 5)
        guard case .degraded = fifth.first else { t.expect(false, "fifth failure degrades"); return }
        t.expectEqual(lc.phase, .degraded, "degraded")
        t.expect(!lc.acceptsReady(generation: gen), "no ready while degraded")
        t.expect(!lc.acceptsRuntimeEvents(generation: gen), "no runtime evidence while degraded")
        t.expect(!lc.acceptsFailureReports(generation: gen), "no failure reports while degraded")
    }
}
