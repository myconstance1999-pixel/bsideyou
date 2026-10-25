// BSideTestRunner — PowerState suites (Beta Slice 5).
// These exercise the EXACT pure power/lock reducer SystemMonitors drives in production, so the
// sleep→pause / wake→resume context transitions proven here are the production-used mapping.

import Foundation
import BSideCore

func runPowerStateTests() {
    run("Power.defaultsAwakeAndUnlocked") { t in
        let p = PowerState()
        t.expect(p.systemAwake && p.screenAwake && !p.screenLocked && p.sessionActive, "defaults awake/unlocked/active")
    }

    run("Power.systemSleepThenWake") { t in
        var p = PowerState()
        t.expect(!p.apply(.willSleep), "willSleep does not trigger reassert")
        t.expect(!p.systemAwake, "system asleep after willSleep")
        t.expect(p.apply(.didWake), "didWake triggers reassert")
        t.expect(p.systemAwake, "system awake after didWake")
    }

    run("Power.screenSleepThenWake") { t in
        var p = PowerState()
        _ = p.apply(.screensDidSleep)
        t.expect(!p.screenAwake, "screen asleep")
        t.expect(p.apply(.screensDidWake), "screen wake triggers reassert")
        t.expect(p.screenAwake, "screen awake")
    }

    run("Power.lockThenUnlock") { t in
        var p = PowerState()
        t.expect(!p.apply(.screenLocked), "lock does not trigger reassert")
        t.expect(p.screenLocked, "locked")
        t.expect(!p.apply(.screenUnlocked), "unlock does not trigger reassert")
        t.expect(!p.screenLocked, "unlocked")
    }

    run("Power.sleepFlagsAreIndependent") { t in
        var p = PowerState()
        _ = p.apply(.willSleep)          // system asleep; screen still awake
        t.expect(!p.systemAwake && p.screenAwake, "system and screen tracked independently")
        _ = p.apply(.screensDidWake)     // screen wake does not resurrect the system flag
        t.expect(!p.systemAwake, "screen wake leaves system asleep")
        t.expect(p.screenAwake, "screen awake")
    }

    run("Power.sessionActivationDoesNotUnlockOrWake") { t in
        var p = PowerState()
        _ = p.apply(.willSleep)
        _ = p.apply(.screensDidSleep)
        _ = p.apply(.screenLocked)
        t.expect(!p.apply(.sessionDidResignActive), "session loss does not reassert")
        t.expect(!p.sessionActive, "session inactive")
        t.expect(!p.apply(.sessionDidBecomeActive), "session return is not a display wake")
        t.expect(p.sessionActive, "activation establishes session activity")
        t.expect(!p.systemAwake && !p.screenAwake && p.screenLocked,
                 "activation preserves independent restrictions")
    }

    run("Power.environmentSamplesPreserveUnknownAndLockEvidence") { t in
        var p = PowerState()
        _ = p.apply(.willSleep)
        _ = p.apply(.screenLocked)
        p.reconcileEnvironment(screenAwake: false, sessionActive: false)
        p.reconcileEnvironment(screenAwake: nil, sessionActive: nil)
        t.expect(!p.screenAwake && !p.sessionActive, "unknown does not erase known inactivity")
        p.reconcileEnvironment(screenAwake: true, sessionActive: true)
        t.expect(p.screenAwake && p.sessionActive, "known recovery corrects stale environment")
        t.expect(!p.systemAwake && p.screenLocked, "sampling neither wakes system nor unlocks")
        p.beginMonitoring(screenAwake: false, sessionActive: false)
        t.expect(p.systemAwake && !p.screenAwake && !p.sessionActive && p.screenLocked,
                 "restart establishes execution, samples environment, and preserves lock")
        p.beginMonitoring(screenAwake: nil, sessionActive: nil)
        t.expect(!p.screenAwake && !p.sessionActive && p.screenLocked, "unknown restart preserves evidence")
    }
}
