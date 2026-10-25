// BSideTestRunner — Platform wiring acceptance (Beta Slice 5).
// Drives the REAL SystemMonitors observers through the REAL notification centers so the production
// wake/Space wiring is proven end-to-end, not just the pure PowerState reducer. No real sleep and no
// external apps: posting a name on NSWorkspace.shared.notificationCenter only fans out to in-process
// observers on that center, so the machine never actually sleeps.
//
// The positive assertion is the wiring proof: if SystemMonitors had registered these on
// NotificationCenter.default (the rejected bug), posting on the workspace center would reach nothing
// and the counts below would stay 0.

import AppKit
import Foundation
import BSideCore
import BSidePlatform

private func drainMainRunLoop(for interval: TimeInterval) {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: interval))
}

@discardableResult
private func drainMainRunLoop(until predicate: () -> Bool, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if predicate() { return true }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
    }
    return predicate()
}

func runPlatformWiringTests() {
    run("Platform.clockChangesReconcileAndObserversAreRemoved") { t in
        let monitors = SystemMonitors(environmentSnapshot: {
            SystemEnvironmentSnapshot(screenAwake: true, sessionActive: true)
        })
        var contextChanges = 0
        monitors.onContextChanged = { contextChanges += 1 }
        monitors.start()
        monitors.start()
        let center = NotificationCenter.default
        center.post(name: .NSSystemClockDidChange, object: nil)
        center.post(name: .NSSystemTimeZoneDidChange, object: nil)
        t.expect(drainMainRunLoop(until: { contextChanges == 1 }, timeout: 2.0),
                 "clock and zone burst requests one fresh reconciliation")
        monitors.stop()
        center.post(name: .NSSystemClockDidChange, object: nil)
        center.post(name: .NSSystemTimeZoneDidChange, object: nil)
        drainMainRunLoop(for: 0.25)
        t.expectEqual(contextChanges, 1, "stop removes both observers")
    }

    run("Platform.systemMonitorsWakeWiringUsesWorkspaceCenter") { t in
        let monitors = SystemMonitors(environmentSnapshot: {
            SystemEnvironmentSnapshot(screenAwake: true, sessionActive: true)
        })
        var contextChanges = 0
        var wakeCount = 0
        monitors.onContextChanged = { contextChanges += 1 }
        monitors.onWake = { wakeCount += 1 }

        monitors.start()
        monitors.start()   // idempotent start must not duplicate observers
        t.expect(monitors.snapshot().systemAwake, "starts system-awake")
        t.expect(monitors.snapshot().screenAwake, "starts screen-awake")

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        t.expect(drainMainRunLoop(until: { contextChanges == 1 }, timeout: 2), "sleep delivered")
        workspaceCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        t.expect(drainMainRunLoop(until: { contextChanges == 2 }, timeout: 2), "wake delivered")
        workspaceCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        t.expect(drainMainRunLoop(until: { contextChanges == 3 }, timeout: 2), "screen sleep delivered")
        workspaceCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)

        t.expect(drainMainRunLoop(until: { wakeCount == 2 && contextChanges == 4 }, timeout: 2.0),
                 "main run loop drained the workspace-center observers")

        t.expectEqual(monitors.snapshot().systemAwake, true, "willSleep→didWake restores systemAwake")
        t.expectEqual(monitors.snapshot().screenAwake, true, "screensDidSleep→screensDidWake restores screenAwake")
        t.expectEqual(wakeCount, 2, "didWake + screensDidWake each fire onWake once")
        t.expectEqual(contextChanges, 4, "each posted notification fires onContextChanged exactly once")

        monitors.stop()
        monitors.stop()   // idempotent teardown must not fault
    }

    run("Platform.systemMonitorsStopRemovesFromWorkspaceCenter") { t in
        let monitors = SystemMonitors(environmentSnapshot: {
            SystemEnvironmentSnapshot(screenAwake: true, sessionActive: true)
        })
        var wakeCount = 0
        monitors.onWake = { wakeCount += 1 }
        monitors.start()
        monitors.stop()

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        workspaceCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        drainMainRunLoop(for: 0.25)   // give any leaked observer a chance to fire

        t.expectEqual(monitors.snapshot().systemAwake, true,
                      "post-stop willSleep is not observed (token removed from workspace center)")
        t.expectEqual(wakeCount, 0, "post-stop didWake fires no onWake (no leaked observer)")
    }
}
