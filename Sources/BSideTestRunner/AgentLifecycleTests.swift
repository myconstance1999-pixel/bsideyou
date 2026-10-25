// BSideTestRunner — AgentLifecycle reducer suites (pure supervision state machine, ADR-002/007).
// These exercise the exact reducer BSideControlApp.AgentSupervisor drives in production, so the
// invariants proven here are the production-used logic — not a test-only mirror.

import Foundation
import BSideCore

private struct SpawnEffect {
    let generation: Int
    let assetPath: String
    let desired: DesiredState
    let deadline: TimeInterval
}

private func firstSpawn(_ effects: [AgentLifecycle.Effect]) -> SpawnEffect? {
    for case .spawn(let generation, let assetPath, let desired, let deadline) in effects {
        return SpawnEffect(generation: generation, assetPath: assetPath, desired: desired, deadline: deadline)
    }
    return nil
}

private let timeoutFailureReason = "never became ready within 10s"

func runAgentLifecycleTests() {
    run("Lifecycle.firstStartSpawnsWithFullReplay") { t in
        var lc = AgentLifecycle()
        let effects = lc.reduce(.start(assetPath: "/a", desired: DesiredState(scene: .a)), now: 0)
        guard let s = firstSpawn(effects) else { t.expect(false, "spawn effect"); return }
        t.expectEqual(effects.count, 1, "one spawn")
        t.expectEqual(s.generation, 1, "generation 1")
        t.expectEqual(s.assetPath, "/a", "asset path")
        t.expectEqual(s.desired, DesiredState(scene: .a), "complete desired replayed")
        t.expectEqual(s.deadline, 10.0, "deadline = now + 10")
        t.expectEqual(lc.phase, .starting, "starting")
        t.expectEqual(lc.liveGeneration, 1, "slot occupied")
    }

    run("Lifecycle.restartWhileRunningReplacesOnce") { t in
        var lc = AgentLifecycle()
        let first = lc.reduce(.start(assetPath: "/a", desired: DesiredState(scene: .a)), now: 0)
        guard let s1 = firstSpawn(first) else { t.expect(false, "spawn1"); return }
        _ = lc.reduce(.ready(generation: s1.generation), now: 1)
        t.expectEqual(lc.phase, .running, "running")

        let restart = lc.reduce(.start(assetPath: "/a", desired: DesiredState(scene: .a)), now: 2)
        t.expectEqual(restart, [.shutdown], "restart shuts down, no immediate spawn")
        t.expectEqual(lc.phase, .stopping, "stopping")
        t.expectEqual(lc.liveGeneration, s1.generation, "old agent still occupies slot")

        let term = lc.reduce(.terminated(generation: s1.generation, abnormal: false, reason: "stopped with status 0"), now: 3)
        guard let s2 = firstSpawn(term) else { t.expect(false, "spawn2"); return }
        t.expectEqual(term.count, 1, "exactly one replacement")
        t.expect(s2.generation > s1.generation, "new generation")
        t.expectEqual(lc.liveGeneration, s2.generation, "only the new agent is live")
    }

    run("Lifecycle.restartCoalescesToOneReplacement") { t in
        var lc = AgentLifecycle()
        let first = lc.reduce(.start(assetPath: "/a", desired: DesiredState()), now: 0)
        guard let s1 = firstSpawn(first) else { t.expect(false, "spawn1"); return }
        _ = lc.reduce(.ready(generation: s1.generation), now: 1)

        let r1 = lc.reduce(.start(assetPath: "/a", desired: DesiredState()), now: 2)
        t.expectEqual(r1, [.shutdown], "first restart shuts down")
        let r2 = lc.reduce(.start(assetPath: "/a", desired: DesiredState()), now: 3)
        t.expectEqual(r2, [], "second restart coalesced (no second shutdown)")

        let term = lc.reduce(.terminated(generation: s1.generation, abnormal: false, reason: "stopped with status 0"), now: 4)
        t.expectEqual(term.count, 1, "single replacement despite two restarts")
        t.expect(firstSpawn(term) != nil, "replacement is a spawn")
    }

    run("Lifecycle.coalescedRestartUsesNewestState") { t in
        var lc = AgentLifecycle()
        let first = lc.reduce(.start(assetPath: "/a", desired: DesiredState(scene: .a)), now: 0)
        guard let s1 = firstSpawn(first) else { t.expect(false, "spawn1"); return }
        _ = lc.reduce(.ready(generation: s1.generation), now: 1)

        _ = lc.reduce(.start(assetPath: "/b", desired: DesiredState(scene: .b)), now: 2)
        _ = lc.reduce(.start(assetPath: "/c", desired: DesiredState(scene: .c)), now: 3)

        let term = lc.reduce(.terminated(generation: s1.generation, abnormal: false, reason: "stopped with status 0"), now: 4)
        guard let s2 = firstSpawn(term) else { t.expect(false, "spawn2"); return }
        t.expectEqual(s2.assetPath, "/c", "newest assetPath")
        t.expectEqual(s2.desired, DesiredState(scene: .c), "newest DesiredState")
    }

    run("Lifecycle.normalStopDoesNotRestart") { t in
        var lc = AgentLifecycle()
        let first = lc.reduce(.start(assetPath: "/a", desired: DesiredState()), now: 0)
        guard let s1 = firstSpawn(first) else { t.expect(false, "spawn1"); return }
        _ = lc.reduce(.ready(generation: s1.generation), now: 1)

        _ = lc.reduce(.stop, now: 2)
        t.expectEqual(lc.phase, .stopping, "stopping after stop")
        let term = lc.reduce(.terminated(generation: s1.generation, abnormal: false, reason: "stopped with status 0"), now: 3)
        t.expectEqual(term, [], "no restart after explicit stop")
        t.expectEqual(lc.phase, .idle, "idle")
        t.expectNil(lc.liveGeneration, "slot free")
    }

    run("Lifecycle.stopCancelsPendingReplacement") { t in
        var lc = AgentLifecycle()
        let first = lc.reduce(.start(assetPath: "/a", desired: DesiredState()), now: 0)
        guard let s1 = firstSpawn(first) else { t.expect(false, "spawn1"); return }
        _ = lc.reduce(.ready(generation: s1.generation), now: 1)

        _ = lc.reduce(.start(assetPath: "/a", desired: DesiredState()), now: 2)   // restart → stopping
        let stopFx = lc.reduce(.stop, now: 3)                                     // quit beats restart
        t.expectEqual(stopFx, [], "already stopping; no extra shutdown")
        t.expectNil(lc.pending, "pending replacement cleared")

        let term = lc.reduce(.terminated(generation: s1.generation, abnormal: false, reason: "stopped with status 0"), now: 4)
        t.expectEqual(term, [], "quit cancelled the pending replacement")
        t.expectEqual(lc.phase, .idle, "idle")
    }

    run("Lifecycle.timeoutHoldsSlotAndKillsOnly") { t in
        var lc = AgentLifecycle()
        let first = lc.reduce(.start(assetPath: "/a", desired: DesiredState()), now: 0)
        guard let s1 = firstSpawn(first) else { t.expect(false, "spawn1"); return }

        let fx = lc.reduce(.handshakeTimeout(generation: s1.generation), now: 10)
        t.expectEqual(fx, [.kill(reason: timeoutFailureReason)], "kill only — no backoff before termination")
        t.expectEqual(lc.phase, .stopping, "non-ready stopping/failing phase")
        t.expectEqual(lc.liveGeneration, s1.generation, "slot stays OCCUPIED until the process really terminates")
        t.expectNil(lc.handshakeDeadline, "deadline cleared")
        t.expectEqual(lc.consecutiveAbnormalExits, 0, "no failure counted at timeout time")
        t.expectNil(lc.backoffToken, "no backoff scheduled yet")

        let ready = lc.reduce(.ready(generation: s1.generation), now: 10.5)
        t.expectEqual(ready, [], "ready after timeout is ignored")
        t.expectEqual(lc.phase, .stopping, "still in teardown")
        t.expectEqual(lc.liveGeneration, s1.generation, "late ready cannot free or mutate the slot")
    }

    run("Lifecycle.timeoutTerminationCountsExactlyOnceThenBacksOff") { t in
        var lc = AgentLifecycle()
        let first = lc.reduce(.start(assetPath: "/a", desired: DesiredState()), now: 0)
        guard let s1 = firstSpawn(first) else { t.expect(false, "spawn1"); return }
        _ = lc.reduce(.handshakeTimeout(generation: s1.generation), now: 10)

        let term = lc.reduce(.terminated(generation: s1.generation, abnormal: true, reason: timeoutFailureReason), now: 11)
        t.expectEqual(term, [.scheduleBackoff(token: 1, after: 1.0)],
                      "exactly one tokenized 1s backoff effect after termination")
        t.expectEqual(lc.consecutiveAbnormalExits, 1, "counted exactly once")
        t.expectEqual(lc.phase, .backoff, "backoff")
        t.expectNil(lc.liveGeneration, "slot freed only by the real termination")
        t.expectEqual(lc.backoffToken, 1, "reducer stores the backoff token")
        t.expectEqual(lc.lastFailureReason, timeoutFailureReason, "timeout reason preserved")

        // A duplicate/late termination of the same generation must not double-count.
        t.expectEqual(lc.reduce(.terminated(generation: s1.generation, abnormal: true, reason: timeoutFailureReason), now: 12),
                      [], "duplicate termination ignored")
        t.expectEqual(lc.consecutiveAbnormalExits, 1, "still exactly one failure")
    }

    run("Lifecycle.noReplacementUntilTimeoutKillTerminates") { t in
        var lc = AgentLifecycle()
        let first = lc.reduce(.start(assetPath: "/a", desired: DesiredState()), now: 0)
        guard let s1 = firstSpawn(first) else { t.expect(false, "spawn1"); return }
        _ = lc.reduce(.handshakeTimeout(generation: s1.generation), now: 10)

        // The OS process may still be alive: anything that would spawn must not fire yet.
        t.expectEqual(lc.reduce(.backoffElapsed(token: 999), now: 10.1), [], "no backoff exists to spawn early")
        t.expectEqual(lc.reduce(.start(assetPath: "/a", desired: DesiredState()), now: 10.2), [],
                      "restart coalesces — no second spawn while the slot is occupied")
        t.expectEqual(lc.liveGeneration, s1.generation, "still exactly the dying generation")
        t.expectEqual(lc.phase, .stopping, "still teardown")

        // Only the killed process's termination arms the backoff…
        let term = lc.reduce(.terminated(generation: s1.generation, abnormal: true, reason: timeoutFailureReason), now: 11)
        guard case .scheduleBackoff(let token, let after) = term.first else {
            t.expect(false, "scheduleBackoff after timeout termination"); return
        }
        t.expectEqual(after, 1.0, "first backoff 1s")

        // …and only that backoff's elapsed event spawns exactly one replacement.
        _ = lc.reduce(.backoffElapsed(token: 999), now: 11.5)
        t.expectNil(lc.liveGeneration, "a different token cannot spawn")
        let respawn = lc.reduce(.backoffElapsed(token: token), now: 12)
        guard let s2 = firstSpawn(respawn) else { t.expect(false, "replacement spawn"); return }
        t.expect(s2.generation > s1.generation, "replacement generation")
        t.expectEqual(lc.liveGeneration, s2.generation, "exactly one live agent after replacement")
    }

    run("Lifecycle.stopDuringTimeoutTeardownEndsIdle") { t in
        var lc = AgentLifecycle()
        let first = lc.reduce(.start(assetPath: "/a", desired: DesiredState()), now: 0)
        guard let s1 = firstSpawn(first) else { t.expect(false, "spawn1"); return }
        _ = lc.reduce(.handshakeTimeout(generation: s1.generation), now: 10)

        let stopFx = lc.reduce(.stop, now: 10.5)      // quit beats the kill in flight
        t.expectEqual(stopFx, [], "already teardown; no extra shutdown")
        t.expectNil(lc.pending, "pending intent cleared")
        t.expectEqual(lc.liveGeneration, s1.generation, "slot still occupied until the process really dies")

        // Termination after quit — abnormal or not — must end idle: no backoff, no replacement.
        let term = lc.reduce(.terminated(generation: s1.generation, abnormal: true, reason: timeoutFailureReason), now: 11)
        t.expectEqual(term, [], "no backoff, no replacement after stop")
        t.expectEqual(lc.phase, .idle, "idle")
        t.expectNil(lc.liveGeneration, "slot free")
        t.expectEqual(lc.consecutiveAbnormalExits, 0, "no failure counted after quit")
        t.expectNil(lc.backoffToken, "no backoff armed")

        t.expectEqual(lc.reduce(.backoffElapsed(token: 123), now: 12), [], "no stray backoff can fire after stop")
        t.expectEqual(lc.phase, .idle, "still idle")
    }

    run("Lifecycle.readyInvalidatesDeadline") { t in
        var lc = AgentLifecycle()
        let first = lc.reduce(.start(assetPath: "/a", desired: DesiredState()), now: 0)
        guard let s1 = firstSpawn(first) else { t.expect(false, "spawn1"); return }

        _ = lc.reduce(.ready(generation: s1.generation), now: 1)
        t.expectEqual(lc.phase, .running, "running")
        t.expectNil(lc.handshakeDeadline, "deadline cleared on ready")

        let late = lc.reduce(.handshakeTimeout(generation: s1.generation), now: 11)
        t.expectEqual(late, [], "late timeout ignored")
        t.expectEqual(lc.phase, .running, "still running")
    }

    run("Lifecycle.staleTimeoutCannotAffectNewGeneration") { t in
        var lc = AgentLifecycle()
        let first = lc.reduce(.start(assetPath: "/a", desired: DesiredState()), now: 0)
        guard let s1 = firstSpawn(first) else { t.expect(false, "spawn1"); return }

        _ = lc.reduce(.handshakeTimeout(generation: s1.generation), now: 10)     // gen1 times out
        let fail = lc.reduce(.terminated(generation: s1.generation, abnormal: true, reason: timeoutFailureReason), now: 11)
        guard case .scheduleBackoff(let token, _) = fail.first else { t.expect(false, "backoff"); return }
        let second = lc.reduce(.backoffElapsed(token: token), now: 12)          // gen2 spawns
        guard let s2 = firstSpawn(second) else { t.expect(false, "spawn2"); return }
        t.expect(s2.generation > s1.generation, "gen2 newer")

        let stale = lc.reduce(.handshakeTimeout(generation: s1.generation), now: 13)
        t.expectEqual(stale, [], "stale gen1 timeout ignored")
        t.expectEqual(lc.phase, .starting, "gen2 still starting")
        t.expectEqual(lc.liveGeneration, s2.generation, "gen2 slot intact")
    }

    run("Lifecycle.staleReadyAndTerminationCannotMutateNewGeneration") { t in
        var lc = AgentLifecycle()
        let first = lc.reduce(.start(assetPath: "/a", desired: DesiredState()), now: 0)
        guard let s1 = firstSpawn(first) else { t.expect(false, "spawn1"); return }

        _ = lc.reduce(.handshakeTimeout(generation: s1.generation), now: 10)
        let fail = lc.reduce(.terminated(generation: s1.generation, abnormal: true, reason: timeoutFailureReason), now: 11)
        guard case .scheduleBackoff(let token, _) = fail.first else { t.expect(false, "backoff"); return }
        let second = lc.reduce(.backoffElapsed(token: token), now: 12)
        guard let s2 = firstSpawn(second) else { t.expect(false, "spawn2"); return }

        t.expectEqual(lc.reduce(.ready(generation: s1.generation), now: 12.5), [], "stale ready ignored")
        t.expectEqual(lc.phase, .starting, "not marked healthy by stale ready")

        t.expectEqual(lc.reduce(.terminated(generation: s1.generation, abnormal: false, reason: "stopped with status 0"), now: 13),
                      [], "stale termination ignored")
        t.expectEqual(lc.liveGeneration, s2.generation, "gen2 unaffected")
        t.expectEqual(lc.consecutiveAbnormalExits, 1, "gen1 counted once, no duplicate")
    }

    run("Lifecycle.abnormalBackoffSequenceThenDegraded") { t in
        var lc = AgentLifecycle()
        let first = lc.reduce(.start(assetPath: "/a", desired: DesiredState()), now: 0)
        guard let s1 = firstSpawn(first) else { t.expect(false, "spawn1"); return }

        let expectedBackoffs: [TimeInterval] = [1, 2, 4, 8]
        var gen = s1.generation
        var now: TimeInterval = 0
        for (i, backoff) in expectedBackoffs.enumerated() {
            let fail = lc.reduce(.terminated(generation: gen, abnormal: true, reason: "crashed with signal 11"), now: now)
            guard case .scheduleBackoff(let token, let after) = fail.first else {
                t.expect(false, "backoff \(i + 1)"); return
            }
            t.expectEqual(fail.count, 1, "one tokenized backoff effect")
            t.expectEqual(after, backoff, "backoff \(i + 1) = \(backoff)s")
            t.expectEqual(lc.phase, .backoff, "backoff phase \(i + 1)")
            let respawn = lc.reduce(.backoffElapsed(token: token), now: now + backoff)
            guard let s = firstSpawn(respawn) else { t.expect(false, "respawn \(i + 1)"); return }
            gen = s.generation
            now += backoff
        }

        let fifth = lc.reduce(.terminated(generation: gen, abnormal: true, reason: "crashed with signal 11"), now: now)
        guard case .degraded = fifth.first else { t.expect(false, "fifth failure degrades"); return }
        t.expectEqual(fifth.count, 1, "degraded only, no further backoff")
        t.expectEqual(lc.phase, .degraded, "degraded")
        t.expectEqual(lc.consecutiveAbnormalExits, 5, "five consecutive failures")
        t.expectEqual(lc.reduce(.backoffElapsed(token: 12345), now: now + 100), [], "no respawn while degraded")
    }

    run("Lifecycle.staleBackoffTokenCannotTriggerNewBackoff") { t in
        var lc = AgentLifecycle()
        let first = lc.reduce(.start(assetPath: "/a", desired: DesiredState()), now: 0)
        guard let s1 = firstSpawn(first) else { t.expect(false, "spawn1"); return }

        let fail1 = lc.reduce(.terminated(generation: s1.generation, abnormal: true, reason: "crashed with signal 11"), now: 1)
        guard case .scheduleBackoff(let t1, let after1) = fail1.first else { t.expect(false, "backoff1"); return }
        t.expectEqual(after1, 1.0, "first backoff 1s")

        let spawn2 = lc.reduce(.backoffElapsed(token: t1), now: 2)          // armed token fires
        guard let s2 = firstSpawn(spawn2) else { t.expect(false, "spawn2"); return }

        let fail2 = lc.reduce(.terminated(generation: s2.generation, abnormal: true, reason: "crashed with signal 11"), now: 3)
        guard case .scheduleBackoff(let t2, _) = fail2.first else { t.expect(false, "backoff2"); return }
        t.expect(t2 != t1, "each backoff carries a distinct monotonic token")
        t.expectEqual(lc.phase, .backoff, "backoff armed with t2")

        // The cancelled t1 timer fires late (cancel raced in the shell) — it must be a no-op
        // and must not spawn a replacement while t2 is the armed backoff.
        t.expectEqual(lc.reduce(.backoffElapsed(token: t1), now: 4), [], "stale old token cannot trigger a new backoff")
        t.expectNil(lc.liveGeneration, "no early spawn from stale token")
        t.expectEqual(lc.phase, .backoff, "real backoff t2 still armed")

        let spawn3 = lc.reduce(.backoffElapsed(token: t2), now: 5)
        guard let s3 = firstSpawn(spawn3) else { t.expect(false, "spawn3"); return }
        t.expect(s3.generation > s2.generation, "only the armed token respawns")
    }

    run("Lifecycle.backoffElapsedWithoutIntentCannotStickInBackoff") { t in
        var lc = AgentLifecycle()
        let first = lc.reduce(.start(assetPath: "/a", desired: DesiredState()), now: 0)
        guard let s1 = firstSpawn(first) else { t.expect(false, "spawn1"); return }

        let fail = lc.reduce(.terminated(generation: s1.generation, abnormal: true, reason: "crashed with signal 11"), now: 1)
        guard case .scheduleBackoff(let token, _) = fail.first else { t.expect(false, "backoff"); return }
        t.expectEqual(lc.phase, .backoff, "backoff")

        // Stop clears the intent while the backoff is armed.
        _ = lc.reduce(.stop, now: 1.5)
        t.expectEqual(lc.phase, .idle, "stop leaves backoff immediately (no pending intent)")
        t.expectNil(lc.pending, "intent cleared")

        // Any elapsed that still reaches the reducer (a cancel raced in the shell) must not
        // re-enter or leave the machine stuck in backoff, and must not spawn.
        t.expectEqual(lc.reduce(.backoffElapsed(token: token), now: 2), [], "late elapsed after stop is a no-op")
        t.expectEqual(lc.phase, .idle, "not stuck in backoff")
        t.expectNil(lc.liveGeneration, "no spawn without intent")
    }

    run("Lifecycle.readyResetsFailureStreak") { t in
        var lc = AgentLifecycle()
        let first = lc.reduce(.start(assetPath: "/a", desired: DesiredState()), now: 0)
        guard let s1 = firstSpawn(first) else { t.expect(false, "spawn1"); return }

        let fail = lc.reduce(.terminated(generation: s1.generation, abnormal: true, reason: "crashed with signal 11"), now: 0)
        guard case .scheduleBackoff(let token, _) = fail.first else { t.expect(false, "backoff"); return }
        t.expectEqual(lc.consecutiveAbnormalExits, 1, "one failure")

        let second = lc.reduce(.backoffElapsed(token: token), now: 1)
        guard let s2 = firstSpawn(second) else { t.expect(false, "spawn2"); return }
        _ = lc.reduce(.ready(generation: s2.generation), now: 2)
        t.expectEqual(lc.consecutiveAbnormalExits, 0, "successful handshake resets streak")
    }

    run("Lifecycle.everyLaunchReplaysCompleteDesiredState") { t in
        var lc = AgentLifecycle()
        let desired = DesiredState(scene: .c, outfit: .r3, timeMode: .fixed(.night), profile: .coding)

        let first = lc.reduce(.start(assetPath: "/a", desired: desired), now: 0)
        guard let s1 = firstSpawn(first) else { t.expect(false, "spawn1"); return }
        t.expectEqual(s1.assetPath, "/a", "first launch asset")
        t.expectEqual(s1.desired, desired, "first launch full desired")

        let fail = lc.reduce(.terminated(generation: s1.generation, abnormal: true, reason: "crashed with signal 11"), now: 0)
        guard case .scheduleBackoff(let token, _) = fail.first else { t.expect(false, "backoff"); return }
        let second = lc.reduce(.backoffElapsed(token: token), now: 1)
        guard let s2 = firstSpawn(second) else { t.expect(false, "spawn2"); return }
        t.expectEqual(s2.assetPath, "/a", "recovery launch asset")
        t.expectEqual(s2.desired, desired, "recovery launch full desired")
    }

    run("Lifecycle.directoryRefreshPreservesLiveGenerationAndFutureReplay") { t in
        var lc = AgentLifecycle()
        let desired = DesiredState(scene: .b, outfit: .r2, timeMode: .fixed(.night), paused: true)
        guard let first = firstSpawn(lc.reduce(.start(assetPath: "/before", desired: desired), now: 0)) else {
            t.expect(false, "initial spawn"); return
        }
        _ = lc.reduce(.ready(generation: first.generation), now: 1)
        lc.recordAssetPath("/moved")
        t.expectEqual(lc.phase, .running, "directory update does not interrupt the process")
        t.expectEqual(lc.liveGeneration, first.generation, "live generation is retained")
        let effects = lc.reduce(.terminated(generation: first.generation, abnormal: true, reason: "crash"), now: 2)
        guard case .scheduleBackoff(let token, _) = effects.first,
              let recovered = firstSpawn(lc.reduce(.backoffElapsed(token: token), now: 4)) else {
            t.expect(false, "ordinary crash recovery"); return
        }
        t.expectEqual(recovered.assetPath, "/moved", "recovery uses the refreshed directory")
        t.expectEqual(recovered.desired, desired, "pause and remaining preferences survive")
    }

    run("Lifecycle.spawnFailureIsTerminalNoStorm") { t in
        var lc = AgentLifecycle()
        let first = lc.reduce(.start(assetPath: "/a", desired: DesiredState()), now: 0)
        guard let s1 = firstSpawn(first) else { t.expect(false, "spawn1"); return }

        let fx = lc.reduce(.spawnFailed(generation: s1.generation, reason: "agent binary not found"), now: 0)
        t.expectEqual(fx, [.degraded(reason: "agent binary not found")], "degraded, no backoff")
        t.expectEqual(lc.phase, .degraded, "degraded")
        t.expectEqual(lc.reduce(.backoffElapsed(token: 1), now: 10), [], "no restart storm on spawn failure")
    }
}
