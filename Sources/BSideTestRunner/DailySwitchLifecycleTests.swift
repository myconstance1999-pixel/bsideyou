import BSideCore

func runDailySwitchLifecycleTests() {
    let day = ContentKey(scene: .a, outfit: .r1, time: .noon)
    let evening = ContentKey(scene: .a, outfit: .r1, time: .evening)
    let night = ContentKey(scene: .a, outfit: .r1, time: .night)
    func selection(_ key: ContentKey) -> ContentSelection {
        ContentSelection(loop: ContentID("loop://\(key)"), ambient: nil, targetKey: key)
    }

    run("DailySwitch.clockWaitsThenUsesLatestTarget") { t in
        var state = DailySwitchLifecycle()
        t.expectEqual(state.update(current: day, selection: selection(evening), automatic: true,
            paused: false, hasVideo: true), .waitForEnd, "clock must not interrupt a live unit")
        t.expectEqual(state.pendingTarget, evening, "pending intent is visible, not reported as installed")
        t.expectEqual(state.update(current: day, selection: selection(night), automatic: true,
            paused: false, hasVideo: true), .waitForEnd, "newest target replaces pending intent")
        t.expectEqual(state.update(current: day, selection: selection(night), automatic: true,
            paused: false, hasVideo: true, atUnitEnd: true), .install, "end applies the newly resolved target")
        t.expectNil(state.pendingTarget, "committed target is no longer pending")
    }
    run("DailySwitch.cancelAndExplicitChoicesDoNotWait") { t in
        var state = DailySwitchLifecycle()
        _ = state.update(current: day, selection: selection(evening), automatic: true, paused: false, hasVideo: true)
        t.expectEqual(state.update(current: day, selection: selection(day), automatic: true,
            paused: false, hasVideo: true), .none, "clock returning to current target cancels waiting")
        t.expectNil(state.pendingTarget, "old target must not survive cancellation")
        t.expectEqual(state.update(current: day, selection: selection(evening), automatic: false,
            paused: false, hasVideo: true), .install, "fixed-time user intent remains immediate")
        for target in [ContentKey(scene: .b, outfit: .r1, time: .evening),
                       ContentKey(scene: .a, outfit: .r2, time: .evening)] {
            t.expectEqual(state.update(current: day, selection: selection(target), automatic: true,
                paused: false, hasVideo: true), .install, "explicit scene/outfit remains immediate even in auto time")
        }
    }
    run("DailySwitch.pauseWinsAndResumeDoesNotWaitForSpentEnd") { t in
        var state = DailySwitchLifecycle()
        _ = state.update(current: day, selection: selection(evening), automatic: true, paused: false, hasVideo: true)
        t.expectEqual(state.update(current: day, selection: selection(evening), automatic: true,
            paused: true, hasVideo: true, atUnitEnd: true), .none, "pause wins even when end arrives concurrently")
        t.expectNil(state.pendingTarget, "no pending end callback while paused")
        t.expectEqual(state.update(current: day, selection: selection(night), automatic: true,
            paused: false, hasVideo: true), .install, "resume resolves now, not an end that already happened")
    }
    run("DailySwitch.recoveryAndMissingTargetsNeverWait") { t in
        var state = DailySwitchLifecycle()
        t.expectEqual(state.update(current: nil, selection: selection(evening), automatic: true,
            paused: false, hasVideo: false), .install, "cold start has no unit to finish")
        t.expectEqual(state.update(current: day, selection: selection(evening), automatic: true,
            paused: false, hasVideo: false), .install, "released resource recovery resolves now")
        t.expectEqual(state.update(current: day, selection: selection(evening), automatic: true,
            paused: false, hasVideo: true, reload: true), .install, "explicit reload bypasses waiting")
        t.expectEqual(state.update(current: day,
            selection: ContentSelection(loop: nil, ambient: nil, targetKey: evening), automatic: true,
            paused: false, hasVideo: true), .install, "missing target must be reported, not hidden behind a wait")
        t.expectNil(state.pendingTarget, "no unsupported pending plan")
    }
    run("DailySwitch.performanceOwnershipResetForgetsPending") { t in
        var state = DailySwitchLifecycle()
        _ = state.update(current: day, selection: selection(evening), automatic: true, paused: false, hasVideo: true)
        state.reset()
        t.expectNil(state.pendingTarget, "performance takeover ends transient daily intent")
        t.expectEqual(state.update(current: nil, selection: selection(night), automatic: true,
            paused: false, hasVideo: false), .install, "returning from performance uses current target directly")
    }

    run("DailySwitch.sameKeySourceChangeWaitsWithoutTimeLabel") { t in
        for automatic in [false, true] {
            var state = DailySwitchLifecycle()
            t.expectEqual(state.update(current: day, selection: selection(day), automatic: automatic,
                paused: false, hasVideo: true, sourceChanged: true), .waitForEnd,
                "source replacement keeps the live unit intact in fixed and automatic modes")
            t.expectNil(state.pendingTarget, "source-only waiting is not a time-of-day switch")
            t.expectEqual(state.update(current: day, selection: selection(day), automatic: automatic,
                paused: false, hasVideo: true, sourceChanged: true), .waitForEnd,
                "latest source difference continues waiting without a captured installation plan")
            t.expectEqual(state.update(current: day, selection: selection(day), automatic: automatic,
                paused: false, hasVideo: true, sourceChanged: false), .none,
                "withdrawing the source difference cancels its wait")
            t.expectEqual(state.update(current: day, selection: selection(day), automatic: automatic,
                paused: false, hasVideo: true, sourceChanged: true, atUnitEnd: true), .install,
                "the same key still needs replacement when its source changed")
            t.expectNil(state.pendingTarget, "source commit does not invent a time label")
        }
    }

    run("DailySwitch.missingCurrentSourceWaitsThenHandsOffAtEnd") { t in
        var state = DailySwitchLifecycle()
        let missing = ContentSelection(loop: nil, ambient: nil, targetKey: day)
        t.expectEqual(state.update(current: day, selection: missing, automatic: true,
            paused: false, hasVideo: true, sourceChanged: true), .waitForEnd,
            "a missing catalog target does not cut the current live unit short")
        t.expectNil(state.pendingTarget, "missing current source is not a switch to its own time")
        t.expectEqual(state.update(current: day, selection: missing, automatic: true,
            paused: false, hasVideo: true, sourceChanged: true, atUnitEnd: true), .install,
            "the owner receives the missing target at EOF to stop obsolete resources")
        t.expectEqual(state.update(current: day, selection: missing, automatic: true,
            paused: false, hasVideo: false, sourceChanged: true), .install,
            "without live video there is no end to wait for")
        t.expectEqual(state.update(current: day, selection: selection(day), automatic: true,
            paused: false, hasVideo: true, reload: true, sourceChanged: true), .install,
            "explicit reload/recovery still overrides source waiting")
    }

    run("DailySwitch.explicitDifferentKeyOverridesSourceWaiting") { t in
        var state = DailySwitchLifecycle()
        t.expectEqual(state.update(current: day, selection: selection(evening), automatic: false,
            paused: false, hasVideo: true, sourceChanged: true), .install,
            "an explicit fixed-time change remains immediate during source refresh")
        for target in [ContentKey(scene: .b, outfit: .r1, time: .noon),
                       ContentKey(scene: .a, outfit: .r2, time: .noon)] {
            for loop in [ContentID("loop://explicit"), nil] as [ContentID?] {
                t.expectEqual(state.update(current: day,
                    selection: ContentSelection(loop: loop, ambient: nil, targetKey: target), automatic: true,
                    paused: false, hasVideo: true, sourceChanged: true), .install,
                    "scene/outfit choice is immediate even if its target is missing")
                t.expectNil(state.pendingTarget, "explicit choices do not leave a clock wait behind")
            }
        }
    }

    run("DailySwitch.pausedSourceChangeWaitsOnResumeOnlyWhileVideoSurvives") { t in
        var state = DailySwitchLifecycle()
        t.expectEqual(state.update(current: day, selection: selection(day), automatic: true,
            paused: true, hasVideo: true, sourceChanged: true), .none,
            "pause remains metadata-only; the Agent retains the source difference")
        t.expectNil(state.pendingTarget, "pause clears any visible time target")
        t.expectEqual(state.update(current: day, selection: selection(day), automatic: true,
            paused: false, hasVideo: true, sourceChanged: true), .waitForEnd,
            "the surviving same-key unit finishes after resume")
        _ = state.update(current: day, selection: selection(day), automatic: true,
            paused: true, hasVideo: true, sourceChanged: true)
        t.expectEqual(state.update(current: day, selection: selection(day), automatic: true,
            paused: false, hasVideo: false, sourceChanged: true), .install,
            "released recovery installs current sources directly")
    }

    run("DailySwitch.sourceAndClockShareOneWaitWithLatestTimeLabel") { t in
        var state = DailySwitchLifecycle()
        t.expectEqual(state.update(current: day, selection: selection(evening), automatic: true,
            paused: false, hasVideo: true, sourceChanged: true), .waitForEnd,
            "source and automatic lighting changes share the existing EOF effect")
        t.expectEqual(state.pendingTarget, evening, "a real automatic time change remains visible")
        t.expectEqual(state.update(current: day, selection: selection(day), automatic: true,
            paused: false, hasVideo: true, sourceChanged: true), .waitForEnd,
            "clock cancellation leaves the independent source wait in place")
        t.expectNil(state.pendingTarget, "returning to the current time removes the obsolete clock label")
        t.expectEqual(state.update(current: day, selection: selection(night), automatic: true,
            paused: false, hasVideo: true, sourceChanged: true, atUnitEnd: true), .install,
            "EOF uses the latest source and clock selection")
        t.expectNil(state.pendingTarget, "completed shared wait has no pending target")
    }

    run("DailySwitch.resumeToDifferentAutomaticKeyOverridesSourceWaiting") { t in
        for loop in [ContentID("loop://resume"), nil] as [ContentID?] {
            var state = DailySwitchLifecycle()
            let newest = ContentSelection(loop: loop, ambient: nil, targetKey: night)
            _ = state.update(current: day, selection: newest, automatic: true,
                paused: true, hasVideo: true, sourceChanged: true)
            t.expectEqual(state.update(current: day, selection: newest, automatic: true,
                paused: false, hasVideo: true, sourceChanged: true), .install,
                "resume uses the newest automatic key immediately, even with changed or missing sources")
            t.expectNil(state.pendingTarget, "resume never leaves an obsolete clock wait")
        }
    }

    run("DailySwitch.missingOrUnknownSourceWaitHasNoTimePromise") { t in
        var state = DailySwitchLifecycle()
        let missingEvening = ContentSelection(loop: nil, ambient: nil, targetKey: evening)
        t.expectEqual(state.update(current: day, selection: missingEvening, automatic: true,
            paused: false, hasVideo: true, sourceChanged: true), .waitForEnd,
            "a running unit finishes before applying a missing source at another automatic time")
        t.expectNil(state.pendingTarget, "a missing target is not advertised as an available time switch")
        t.expectEqual(state.update(current: day, selection: missingEvening, automatic: true,
            paused: false, hasVideo: true, sourceChanged: true, atUnitEnd: true), .install,
            "EOF hands missing source handling to the Agent")
        t.expectEqual(state.update(current: nil, selection: selection(day), automatic: true,
            paused: false, hasVideo: true, sourceChanged: true), .waitForEnd,
            "actual video can establish a source boundary even when its key is unknown")
        t.expectNil(state.pendingTarget, "an unknown current key cannot establish a real time switch")
    }
}
