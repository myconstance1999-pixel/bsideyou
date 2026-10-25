// BSideTestRunner — notification/source lifecycles, without system sleep or memory stress.
// Exact event counts use private centers; PlatformWiringTests covers the real system centers.

import AppKit
import Darwin
import Foundation
import BSideCore
import BSidePlatform

private func energyMonitors(
    fullscreenDetector: (() -> Bool)? = { false },
    environmentSnapshot: @escaping () -> SystemEnvironmentSnapshot = {
        SystemEnvironmentSnapshot(screenAwake: true, sessionActive: true)
    },
    notificationCenter: NotificationCenter = NotificationCenter(),
    workspaceNotificationCenter: NotificationCenter = NotificationCenter()
) -> SystemMonitors {
    SystemMonitors(fullscreenDetector: fullscreenDetector, environmentSnapshot: environmentSnapshot,
                   notificationCenter: notificationCenter, workspaceNotificationCenter: workspaceNotificationCenter)
}

private func energyDrain(for interval: TimeInterval = 0.06) {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: interval))
}

private func energyWait(until condition: () -> Bool, timeout: TimeInterval = 2) -> Bool {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while !condition(), Date() < deadline { energyDrain(for: 0.02) }
    return condition()
}

func runEnergyMonitorTests() {
    run("EnergyMonitor.hostVisibilityIsIndependentCoalescedAndUnknownPermitsPlayback") { t in
        let center = NotificationCenter()
        let monitors = energyMonitors(notificationCenter: center)
        var changes = 0
        monitors.onContextChanged = { changes += 1 }
        monitors.start()
        defer { monitors.stop() }
        t.expect(monitors.snapshot().desktopVisible, "unknown starts permissive")
        monitors.setDesktopVisible(false)
        monitors.setDesktopVisible(false)
        energyDrain()
        t.expectEqual(changes, 1, "duplicate own-host observations reconcile once")
        t.expect(!monitors.snapshot().desktopVisible, "confirmed full occlusion reaches context")
        center.post(name: .NSSystemClockDidChange, object: nil)
        energyDrain()
        t.expect(!monitors.snapshot().desktopVisible, "other monitor events preserve the host input")
        monitors.setDesktopVisible(nil)
        energyDrain()
        t.expect(monitors.snapshot().desktopVisible, "replaced/unknown host permits playback")
        t.expectEqual(changes, 3, "clock and restoration each delivered once")
        monitors.setDesktopVisible(false)
        monitors.setDesktopVisible(true)
        energyDrain()
        t.expectEqual(changes, 3, "same-turn occlusion burst with visible final value is suppressed")
    }
    run("EnergyMonitor.contextBurstsCoalesceAndDuplicatesAreSuppressed") { t in
        let workspace = NotificationCenter()
        let monitors = energyMonitors(workspaceNotificationCenter: workspace)
        var changes = 0
        monitors.onContextChanged = { changes += 1 }
        monitors.start()
        defer { monitors.stop() }
        for _ in 0..<6 { workspace.post(name: NSWorkspace.willSleepNotification, object: nil) }
        energyDrain()
        t.expectEqual(changes, 1, "six equivalent sleep notifications reconcile once")
        t.expect(!monitors.snapshot().systemAwake, "latest context carries the sleep state")
        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        energyDrain()
        t.expectEqual(changes, 1, "unchanged context on a later turn does not reconcile again")
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        energyDrain()
        t.expectEqual(changes, 2, "changed wake context is still delivered")
    }

    run("EnergyMonitor.clockForcesReconcileButSharesNotificationBurst") { t in
        let center = NotificationCenter()
        let monitors = energyMonitors(notificationCenter: center)
        var changes = 0
        monitors.onContextChanged = { changes += 1 }
        monitors.start()
        defer { monitors.stop() }
        let before = monitors.snapshot()
        center.post(name: .NSSystemClockDidChange, object: nil)
        center.post(name: .NSSystemTimeZoneDidChange, object: nil)
        energyDrain()
        t.expectEqual(changes, 1, "clock and zone burst forces one reconciliation")
        t.expectEqual(monitors.snapshot(), before, "wall-clock events need no context field change")
        center.post(name: .NSSystemClockDidChange, object: nil)
        energyDrain()
        t.expectEqual(changes, 2, "a later clock adjustment is never suppressed as unchanged")
    }

    run("EnergyMonitor.windowQueriesCoalesceBeforeReconciliation") { t in
        let center = NotificationCenter()
        var queries = 0
        var fullscreen = false
        let monitors = energyMonitors(fullscreenDetector: { queries += 1; return fullscreen }, notificationCenter: center)
        var changes = 0
        monitors.onContextChanged = { changes += 1 }
        monitors.start()
        defer { monitors.stop() }
        fullscreen = true
        for _ in 0..<5 {
            center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        }
        energyDrain()
        t.expectEqual(queries, 2, "one startup query plus one query for the entire screen-event burst")
        t.expectEqual(changes, 1, "the newest fullscreen state reconciles once")
        t.expect(monitors.snapshot().fullscreenAppActive, "deferred refresh precedes delivery")
    }

    run("EnergyMonitor.stopCancelsQueuedContextAndOldSpaceSettlement") { t in
        let center = NotificationCenter()
        let workspace = NotificationCenter()
        var queries = 0
        let monitors = energyMonitors(
            fullscreenDetector: { queries += 1; return false },
            notificationCenter: center, workspaceNotificationCenter: workspace
        )
        var changes = 0
        monitors.onContextChanged = { changes += 1 }
        monitors.start()
        center.post(name: .NSSystemClockDidChange, object: nil)
        workspace.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        monitors.stop()
        monitors.start()
        energyDrain(for: 0.4)
        t.expectEqual(changes, 0, "old forced delivery is cancelled across stop/restart")
        t.expectEqual(queries, 2, "old Space settlement cannot query the restarted monitor")
        for _ in 0..<4 {
            workspace.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        }
        // Settlement's 0.3-second work enqueues reconciliation on another main-queue turn.
        // A fixed 0.4-second run-loop window can end before that actual query under load.
        t.expect(energyWait(until: { queries >= 3 }), "new Space settlement reaches its deferred query")
        energyDrain()
        t.expectEqual(queries, 3, "new Space burst receives exactly one settled query")
        monitors.stop()
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        energyDrain()
        t.expectEqual(queries, 3, "stop removes screen observers too")
    }

    run("EnergyMonitor.wakeReassertSurvivesUnchangedFinalContext") { t in
        let workspace = NotificationCenter()
        let monitors = energyMonitors(workspaceNotificationCenter: workspace)
        var wakeCount = 0
        var changes = 0
        monitors.onWake = { wakeCount += 1 }
        monitors.onContextChanged = { changes += 1 }
        monitors.start()
        defer { monitors.stop() }
        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        workspace.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspace.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        energyDrain()
        t.expectEqual(wakeCount, 2, "wake host reassertions remain independent of context coalescing")
        t.expectEqual(changes, 0, "the final context equals the pre-burst state")
    }

    run("EnergyMonitor.coldStartSamplesSleepingScreenAndInactiveSession") { t in
        var queries = 0
        let monitors = energyMonitors(environmentSnapshot: {
            queries += 1
            return SystemEnvironmentSnapshot(screenAwake: false, sessionActive: false)
        })
        monitors.start()
        monitors.start()
        defer { monitors.stop() }
        let context = monitors.snapshot()
        t.expectEqual(queries, 1, "initial environment is sampled exactly once on idempotent start")
        t.expect(!context.screenAwake, "already sleeping display is known before any playback decision")
        t.expect(!context.sessionActive, "already inactive session is known before any playback decision")
        t.expect(!context.screenLocked, "session inactivity never invents screen-lock evidence")
        t.expect(context.systemAwake, "a running monitor begins with a currently awake system")
    }

    run("EnergyMonitor.restartResamplesChangesWhileStoppedAndPreservesUnknownFacts") { t in
        let workspace = NotificationCenter()
        var environment = SystemEnvironmentSnapshot(screenAwake: true, sessionActive: true)
        var queries = 0
        let monitors = energyMonitors(environmentSnapshot: { queries += 1; return environment }, workspaceNotificationCenter: workspace)
        monitors.start()
        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        monitors.stop()
        environment = SystemEnvironmentSnapshot(screenAwake: false, sessionActive: false)
        monitors.start()
        t.expect(monitors.snapshot().systemAwake, "restart corrects an old willSleep after missed wake")
        t.expect(!monitors.snapshot().screenAwake, "screen change while stopped is sampled")
        t.expect(!monitors.snapshot().sessionActive, "session change while stopped is sampled")
        monitors.stop()
        environment = SystemEnvironmentSnapshot()
        monitors.start()
        t.expect(!monitors.snapshot().screenAwake, "unknown query retains known sleeping screen")
        t.expect(!monitors.snapshot().sessionActive, "unknown query retains known inactive session")
        monitors.stop()
        environment = SystemEnvironmentSnapshot(screenAwake: true, sessionActive: true)
        monitors.start()
        t.expect(monitors.snapshot().screenAwake, "later known awake snapshot permits restoration")
        t.expect(monitors.snapshot().sessionActive, "later known active snapshot permits restoration")
        t.expectEqual(queries, 4, "each start samples current environment")
        monitors.stop()
    }

    run("EnergyMonitor.sessionActivationRechecksScreenBeforeDelivery") { t in
        let workspace = NotificationCenter()
        var environment = SystemEnvironmentSnapshot(screenAwake: true, sessionActive: true)
        var queries = 0
        let monitors = energyMonitors(environmentSnapshot: { queries += 1; return environment }, workspaceNotificationCenter: workspace)
        var delivered: [RuntimeContext] = []
        monitors.onContextChanged = { delivered.append(monitors.snapshot()) }
        monitors.start()
        defer { monitors.onContextChanged = nil; monitors.stop() }
        workspace.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        t.expect(!monitors.snapshot().sessionActive, "resign notification applies suppression immediately")
        energyDrain()
        environment = SystemEnvironmentSnapshot(screenAwake: false, sessionActive: true)
        workspace.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        workspace.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        energyDrain()
        t.expect(monitors.snapshot().sessionActive, "session activation is recognized")
        t.expect(!monitors.snapshot().screenAwake, "the current sleeping screen still constrains restoration")
        t.expectEqual(queries, 2, "activation and wake share one current-environment query")
        t.expectEqual(delivered.count, 2, "resign and final active-but-screen-asleep context each deliver once")
        t.expectEqual(delivered.last?.screenAwake, false, "no awake intermediate state is delivered")
    }

    run("EnergyMonitor.sessionActivationEvidenceSurvivesUnavailableSessionQuery") { t in
        let workspace = NotificationCenter()
        var environment = SystemEnvironmentSnapshot(screenAwake: true, sessionActive: false)
        let monitors = energyMonitors(environmentSnapshot: { environment }, workspaceNotificationCenter: workspace)
        monitors.start()
        defer { monitors.stop() }
        environment = SystemEnvironmentSnapshot(screenAwake: true, sessionActive: nil)
        workspace.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        energyDrain()
        t.expect(monitors.snapshot().sessionActive, "public activation event supplies evidence when query is unavailable")
        t.expect(monitors.snapshot().screenAwake, "known screen snapshot is merged independently")
        t.expect(!monitors.snapshot().screenLocked, "activation is not an artificial lock transition")
    }

    run("EnergyMonitor.environmentBurstsCoalesceAndResignWinsConflictingActiveQuery") { t in
        let center = NotificationCenter()
        let workspace = NotificationCenter()
        var queries = 0
        let monitors = energyMonitors(environmentSnapshot: {
            queries += 1
            return SystemEnvironmentSnapshot(screenAwake: true, sessionActive: true)
        }, notificationCenter: center, workspaceNotificationCenter: workspace)
        monitors.start()
        defer { monitors.stop() }
        workspace.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        for _ in 0..<5 {
            center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
            workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
            workspace.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        }
        energyDrain()
        t.expectEqual(queries, 2, "one startup query plus one query for the whole environment-event burst")
        t.expect(!monitors.snapshot().sessionActive, "conflicting onConsole=true cannot undo the resign event")
        workspace.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        energyDrain()
        t.expect(monitors.snapshot().sessionActive, "explicit activation opens the inactive-event latch")
        t.expectEqual(queries, 3, "activation makes one fresh screen/session query")
    }

    run("EnergyMonitor.screenSleepWinsEarlierRefreshAndProtectionIsOneBatch") { t in
        let center = NotificationCenter()
        let workspace = NotificationCenter()
        var environment = SystemEnvironmentSnapshot(screenAwake: true, sessionActive: true)
        var queries = 0
        let monitors = energyMonitors(
            environmentSnapshot: { queries += 1; return environment },
            notificationCenter: center, workspaceNotificationCenter: workspace
        )
        monitors.start()
        defer { monitors.stop() }
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        workspace.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        energyDrain()
        t.expect(!monitors.snapshot().screenAwake, "final explicit screen sleep wins the same-batch awake query")
        t.expectEqual(queries, 2, "earlier wake/configuration still share one environment query")
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        energyDrain()
        t.expect(monitors.snapshot().screenAwake, "next batch can accept fresh awake evidence; protection is not sticky")
        workspace.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspace.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        energyDrain()
        t.expect(monitors.snapshot().screenAwake, "a later explicit screen wake clears same-batch sleep protection")
        environment = SystemEnvironmentSnapshot(screenAwake: false, sessionActive: true)
        workspace.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspace.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        energyDrain()
        t.expect(!monitors.snapshot().screenAwake, "known restrictive screen snapshot still constrains the wake event")
        workspace.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        monitors.stop()
        environment = SystemEnvironmentSnapshot(screenAwake: true, sessionActive: true)
        monitors.start()
        energyDrain()
        t.expect(monitors.snapshot().screenAwake, "old pending sleep protection cannot cross stop/restart")
    }

    run("EnergyMonitor.sessionEventOrderAndKnownRestrictiveSnapshot") { t in
        let workspace = NotificationCenter()
        var environment = SystemEnvironmentSnapshot(screenAwake: true, sessionActive: true)
        let monitors = energyMonitors(environmentSnapshot: { environment }, workspaceNotificationCenter: workspace)
        monitors.start()
        defer { monitors.stop() }
        workspace.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        workspace.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        energyDrain()
        t.expect(!monitors.snapshot().sessionActive, "become then resign ends inactive despite conflicting active query")
        workspace.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        workspace.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        energyDrain()
        t.expect(!monitors.snapshot().sessionActive, "screen wake does not reactivate a resigned user session")
        workspace.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        workspace.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        energyDrain()
        t.expect(monitors.snapshot().sessionActive, "resign then become accepts matching active evidence")
        // This is the intended conflict policy, not a claim that the real OS query has lagged.
        environment = SystemEnvironmentSnapshot(screenAwake: true, sessionActive: false)
        workspace.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        energyDrain()
        t.expect(!monitors.snapshot().sessionActive, "known inactive snapshot remains a stronger restriction")
        t.expect(!monitors.snapshot().screenLocked, "session conflict handling never fabricates screen lock")
    }

    run("EnergyMonitor.stopCancelsOldEnvironmentQueriesAndSessionObservers") { t in
        let center = NotificationCenter()
        let workspace = NotificationCenter()
        var queries = 0
        var environment = SystemEnvironmentSnapshot(screenAwake: true, sessionActive: true)
        let monitors = energyMonitors(
            environmentSnapshot: { queries += 1; return environment },
            notificationCenter: center, workspaceNotificationCenter: workspace
        )
        monitors.start()
        workspace.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        monitors.stop()
        environment = SystemEnvironmentSnapshot(screenAwake: false, sessionActive: false)
        monitors.start()
        energyDrain()
        t.expectEqual(queries, 2, "old pending callback cannot query or mutate the new generation")
        t.expect(!monitors.snapshot().sessionActive, "new generation retains its freshly sampled inactive state")
        monitors.stop()
        workspace.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        workspace.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        energyDrain()
        t.expectEqual(queries, 2, "stopped session and screen observers cannot trigger queries")
    }

    run("EnergyMonitor.parentAlreadyGoneAndStartupRaceReportOnce") { t in
        var alreadyGoneCount = 0
        let alreadyGone = ParentExitMonitor(parentPID: 1, currentParentPID: { 1 }) { alreadyGoneCount += 1 }
        alreadyGone.start()
        alreadyGone.start()
        t.expectEqual(alreadyGoneCount, 1, "an already orphaned process reports immediately once")
        alreadyGone.cancel()

        var checks = 0
        var racedCount = 0
        let parentPID = getppid()
        let raced = ParentExitMonitor(parentPID: parentPID, currentParentPID: {
            checks += 1
            return checks == 1 ? parentPID : 1
        }) { racedCount += 1 }
        raced.start()
        energyDrain()
        t.expectEqual(racedCount, 1, "reparenting between the first check and source arming reports once")
        raced.cancel()
    }

    run("EnergyMonitor.parentRaceAtAsynchronousRegistrationIsCaught") { t in
        var checks = 0
        var exits = 0
        let parentPID = getppid()
        let monitor = ParentExitMonitor(parentPID: parentPID, currentParentPID: {
            checks += 1
            return checks <= 2 ? parentPID : 1
        }) { exits += 1 }
        monitor.start()
        t.expect(energyWait(until: { exits == 1 }), "registration handler detects reparenting after resume")
        t.expectEqual(exits, 1, "asynchronous registration reports once")
        monitor.cancel()
    }

    run("EnergyMonitor.realProcessExitSourceAndCancellation") { t in
        // A pipe lets this owned child exit normally after source registration; no signals, polling
        // timer in production, or changes to any external process are required.
        for cancelBeforeExit in [false, true] {
            let child = Process()
            let input = Pipe()
            child.executableURL = URL(fileURLWithPath: "/bin/sh")
            child.arguments = ["-c", "read value"]
            child.standardInput = input
            child.standardOutput = FileHandle.nullDevice
            child.standardError = FileHandle.nullDevice
            do { try child.run() }
            catch { t.expect(false, "launch controlled child: \(error)"); continue }
            let childPID = child.processIdentifier
            var exits = 0
            let monitor = ParentExitMonitor(parentPID: childPID, currentParentPID: { childPID }) { exits += 1 }
            monitor.start()
            energyDrain()
            if cancelBeforeExit { monitor.cancel() }
            try? input.fileHandleForWriting.write(contentsOf: Data("done\n".utf8))
            try? input.fileHandleForWriting.close()
            child.waitUntilExit()
            if cancelBeforeExit {
                energyDrain()
                t.expectEqual(exits, 0, "cancel suppresses a real later exit event")
            } else {
                t.expect(energyWait(until: { exits == 1 }), "kernel process-exit event reaches the callback")
                monitor.start()
                energyDrain()
                t.expectEqual(exits, 1, "duplicate start does not report the dead process twice")
            }
            monitor.cancel()
        }
    }
}
