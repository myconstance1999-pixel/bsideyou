// Deterministic tests of the production daily-resource reducer, using monotonic test time.

import BSideCore

func runDailyResourceLifecycleTests() {
    run("DailyRetention.onlyPausedInstalledVideoSchedules") { t in
        var lifecycle = DailyResourceLifecycle()
        t.expectEqual(lifecycle.update(paused: false, hasVideo: true, retentionDelay: 30, now: 10), [],
                      "playing video has no release work")
        t.expectEqual(lifecycle.update(paused: true, hasVideo: false, retentionDelay: 30, now: 10), [],
                      "paused cold start does not invent resources")
        t.expectEqual(lifecycle.update(paused: true, hasVideo: true, retentionDelay: 30, now: 10),
                      [.schedule(token: 1, after: 30)], "first eligible pause schedules one deadline")
    }

    run("DailyRetention.repeatedPauseNeverExtendsDeadline") { t in
        var lifecycle = DailyResourceLifecycle()
        _ = lifecycle.update(paused: true, hasVideo: true, retentionDelay: 30, now: 100)
        t.expectEqual(lifecycle.update(paused: true, hasVideo: true, retentionDelay: 30, now: 120), [],
                      "same context does not postpone release")
        t.expectEqual(lifecycle.update(paused: true, hasVideo: true, retentionDelay: 60, now: 125), [],
                      "weaker policy does not prolong an existing pause")
        t.expect(lifecycle.releaseDeadlineFired(token: 1), "original deadline remains valid")
        t.expect(!lifecycle.releaseDeadlineFired(token: 1), "duplicate release is ignored")
    }

    run("DailyRetention.strongerPolicyShortensFromOriginalPause") { t in
        var lifecycle = DailyResourceLifecycle()
        _ = lifecycle.update(paused: true, hasVideo: true, retentionDelay: 30, now: 100)
        t.expectEqual(lifecycle.update(paused: true, hasVideo: true, retentionDelay: 5, now: 103),
                      [.cancel, .schedule(token: 2, after: 2)], "five-second total budget leaves two seconds")
        t.expect(!lifecycle.releaseDeadlineFired(token: 1), "cancelled deadline cannot release")
        t.expectEqual(lifecycle.update(paused: true, hasVideo: true, retentionDelay: 30, now: 104), [],
                      "pressure relief does not push shortened deadline out")
        t.expect(lifecycle.releaseDeadlineFired(token: 2), "shortened current deadline releases")
    }

    run("DailyRetention.latePressureEscalationIsImmediatelyDue") { t in
        var lifecycle = DailyResourceLifecycle()
        _ = lifecycle.update(paused: true, hasVideo: true, retentionDelay: 30, now: 100)
        t.expectEqual(lifecycle.update(paused: true, hasVideo: true, retentionDelay: 5, now: 129),
                      [.cancel, .schedule(token: 2, after: 0)],
                      "stronger policy must not move an almost-expired deadline into the future")
    }

    run("DailyRetention.memoryPressureMakesReleaseImmediate") { t in
        var lifecycle = DailyResourceLifecycle()
        _ = lifecycle.update(paused: true, hasVideo: true, retentionDelay: 30, now: 0)
        t.expectEqual(lifecycle.update(paused: true, hasVideo: true, retentionDelay: 0, now: 1),
                      [.cancel, .schedule(token: 2, after: 0)], "zero retention cancels old timer")
        t.expect(lifecycle.releaseDeadlineFired(token: 2), "immediate deadline consumed")
    }

    run("DailyRetention.resumeCancelsAndNextPauseGetsFreshBudget") { t in
        var lifecycle = DailyResourceLifecycle()
        _ = lifecycle.update(paused: true, hasVideo: true, retentionDelay: 30, now: 0)
        t.expectEqual(lifecycle.update(paused: false, hasVideo: true, retentionDelay: 30, now: 4), [.cancel],
                      "resume cancels scheduled release")
        t.expect(!lifecycle.releaseDeadlineFired(token: 1), "late pre-resume deadline ignored")
        t.expectEqual(lifecycle.update(paused: true, hasVideo: true, retentionDelay: 30, now: 10),
                      [.schedule(token: 3, after: 30)], "new pause receives full budget")
    }

    run("DailyRetention.resourceDisappearanceCancels") { t in
        var lifecycle = DailyResourceLifecycle()
        _ = lifecycle.update(paused: true, hasVideo: true, retentionDelay: 30, now: 0)
        t.expectEqual(lifecycle.update(paused: true, hasVideo: false, retentionDelay: 30, now: 2), [.cancel],
                      "no player means no retained resource to release")
        t.expect(!lifecycle.releaseDeadlineFired(token: 1), "removed resource's callback ignored")
        t.expectEqual(lifecycle.update(paused: true, hasVideo: false, retentionDelay: 30, now: 40), [],
                      "remaining without resources does not schedule")
    }

    run("DailyRetention.consumedCaptureCannotRearmInSamePause") { t in
        var lifecycle = DailyResourceLifecycle()
        _ = lifecycle.update(paused: true, hasVideo: true, retentionDelay: 30, now: 0)
        t.expect(lifecycle.releaseDeadlineFired(token: 1), "capture begins once")
        for time in [30.1, 31, 60, 600] {
            t.expectEqual(lifecycle.update(paused: true, hasVideo: true, retentionDelay: 30, now: time), [],
                          "retained player during capture or failed capture does not cause a retry loop")
        }
        t.expectEqual(lifecycle.update(paused: true, hasVideo: true, retentionDelay: 0, now: 601), [],
                      "pressure does not duplicate a capture already issued")
        t.expect(!lifecycle.releaseDeadlineFired(token: 1), "duplicate callback cannot capture twice")
    }

    run("DailyRetention.invalidationRejectsTimersAndFreshCycleCannotCollide") { t in
        var lifecycle = DailyResourceLifecycle()
        _ = lifecycle.update(paused: true, hasVideo: true, retentionDelay: 30, now: 0)
        t.expectEqual(lifecycle.invalidate(), [.cancel], "performance/stop invalidates daily ownership")
        t.expect(!lifecycle.releaseDeadlineFired(token: 1), "old callback rejected")
        t.expectEqual(lifecycle.invalidate(), [], "repeated invalidation has no timer to cancel")
        let effects = lifecycle.update(paused: true, hasVideo: true, retentionDelay: 30, now: 50)
        t.expectEqual(effects, [.schedule(token: 4, after: 30)], "later lifecycle uses distinct identity")
        t.expect(!lifecycle.releaseDeadlineFired(token: 1), "old identity stays stale after reuse")
        t.expect(lifecycle.releaseDeadlineFired(token: 4), "new timer accepted")
    }

    run("DailyRetention.actualReplacementResetsConsumedCycle") { t in
        var lifecycle = DailyResourceLifecycle()
        _ = lifecycle.update(paused: true, hasVideo: true, retentionDelay: 0, now: 0)
        _ = lifecycle.releaseDeadlineFired(token: 1)
        t.expectEqual(lifecycle.resourceReplaced(), [], "consumed timer needs no cancellation")
        t.expectEqual(lifecycle.update(paused: true, hasVideo: true, retentionDelay: 5, now: 20),
                      [.schedule(token: 3, after: 5)], "new installed resource receives a bounded cycle")
        t.expect(!lifecycle.releaseDeadlineFired(token: 1), "prior resource callback cannot release replacement")
    }

    run("DailyRetention.invalidBudgetsCannotRetainForever") { t in
        for delay in [-1.0, .nan, .infinity, -.infinity] {
            var lifecycle = DailyResourceLifecycle()
            t.expectEqual(lifecycle.update(paused: true, hasVideo: true, retentionDelay: delay, now: 10),
                          [.schedule(token: 1, after: 0)], "invalid budget becomes immediate release")
        }
    }

    run("DailyRetention.policyBudgetsRespectStrongestCondition") { t in
        var context = RuntimeContext()
        t.expectEqual(PlaybackPolicy.dailyRetentionDelay(context: context, memoryPressure: false), 30,
                      "ordinary brief pause retains for initial thirty-second budget")
        context.thermal = .fair
        t.expectEqual(PlaybackPolicy.dailyRetentionDelay(context: context, memoryPressure: false), 30,
                      "fair thermal state leaves ordinary budget")
        context.lowPowerMode = true
        t.expectEqual(PlaybackPolicy.dailyRetentionDelay(context: context, memoryPressure: false), 5,
                      "Low Power Mode shortens retention")
        context.lowPowerMode = false
        context.thermal = .serious
        t.expectEqual(PlaybackPolicy.dailyRetentionDelay(context: context, memoryPressure: false), 5,
                      "serious thermal pressure shortens retention")
        context.thermal = .critical
        t.expectEqual(PlaybackPolicy.dailyRetentionDelay(context: context, memoryPressure: false), 0,
                      "critical thermal pressure releases immediately")
        context = RuntimeContext()
        t.expectEqual(PlaybackPolicy.dailyRetentionDelay(context: context, memoryPressure: true), 0,
                      "memory pressure releases immediately")
        context.systemAwake = false
        t.expectEqual(PlaybackPolicy.dailyRetentionDelay(context: context, memoryPressure: false), 0,
                      "system asleep needs no retained decoder")
        context = RuntimeContext(screenAwake: false)
        t.expectEqual(PlaybackPolicy.dailyRetentionDelay(context: context, memoryPressure: false), 0,
                      "display asleep needs no retained decoder")
        context = RuntimeContext(sessionActive: false)
        t.expectEqual(PlaybackPolicy.dailyRetentionDelay(context: context, memoryPressure: false), 0,
                      "inactive user session needs no retained decoder")
        context = RuntimeContext(screenLocked: true, lowPowerMode: true, thermal: .serious)
        t.expectEqual(PlaybackPolicy.dailyRetentionDelay(context: context, memoryPressure: false), 0,
                      "screen lock wins over five-second budgets")
    }
}
