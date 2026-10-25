// BSideTestRunner — Core domain suites.

import Foundation
import BSideCore

func runTimeBucketTests() {
    run("TimeBucket.autoBucketBoundaries") { t in
        // Documented boundaries: [00:00,06:00) night · [06:00,17:30) noon · [17:30,20:00) evening · [20:00,24:00) night
        t.expectEqual(TimeOfDay.autoBucket(minuteOfDay: 0), .night, "00:00")
        t.expectEqual(TimeOfDay.autoBucket(minuteOfDay: 359), .night, "05:59")
        t.expectEqual(TimeOfDay.autoBucket(minuteOfDay: 360), .noon, "06:00")
        t.expectEqual(TimeOfDay.autoBucket(minuteOfDay: 720), .noon, "12:00")
        t.expectEqual(TimeOfDay.autoBucket(minuteOfDay: 1049), .noon, "17:29")
        t.expectEqual(TimeOfDay.autoBucket(minuteOfDay: 1050), .evening, "17:30")
        t.expectEqual(TimeOfDay.autoBucket(minuteOfDay: 1199), .evening, "19:59")
        t.expectEqual(TimeOfDay.autoBucket(minuteOfDay: 1200), .night, "20:00")
        t.expectEqual(TimeOfDay.autoBucket(minuteOfDay: 1439), .night, "23:59")
        t.expectEqual(TimeOfDay.autoBucket(minuteOfDay: 1440), .night, "24:00 wraps")
        t.expectEqual(TimeOfDay.autoBucket(minuteOfDay: -60), .night, "negative wraps")
    }
}

func fullCatalog() -> ContentCatalog {
    var catalog = ContentCatalog(sourceLabel: "test")
    for scene in Scene.allCases {
        for outfit in Outfit.allCases {
            for time in TimeOfDay.allCases {
                let key = ContentKey(scene: scene, outfit: outfit, time: time)
                catalog.loops[key] = ContentID("loop://\(key.scene.rawValue)/\(key.outfit.rawValue)/\(key.time.rawValue)")
            }
        }
    }
    for scene in Scene.allCases {
        for (from, to) in [(TimeOfDay.noon, TimeOfDay.evening), (.evening, .night), (.night, .noon)] {
            let key = TransitionKey(scene: scene, from: from, to: to)
            catalog.transitions[key] = ContentID("transition://\(scene.rawValue)/\(from.rawValue)->\(to.rawValue)")
        }
    }
    for i in 1...3 {
        catalog.ambientTracks.append(AmbientTrack(id: ContentID("ambient://\(i)"), index: i, label: "ambient_loop_\(i).mp3"))
    }
    return catalog
}

func runContentResolverTests() {
    let desired = DesiredState(scene: .a, outfit: .r1, timeMode: .fixed(.noon), dailySoundtrack: .legacyDefault)

    run("Resolver.startupNeverTransitions") { t in
        let sel = ContentResolver.resolve(currentKey: nil, desired: desired, catalog: fullCatalog(), minuteOfDay: 720)
        t.expectEqual(sel.targetKey, ContentKey(scene: .a, outfit: .r1, time: .noon), "target key")
        t.expectNil(sel.transition, "no transition at startup")
        t.expect(sel.isPlayable, "playable")
        t.expectNotNil(sel.ambient, "ambient selected")
    }

    run("Resolver.timeChangeWithinSceneUsesTransition") { t in
        let current = ContentKey(scene: .a, outfit: .r1, time: .noon)
        let evening = DesiredState(scene: .a, outfit: .r1, timeMode: .fixed(.evening))
        let sel = ContentResolver.resolve(currentKey: current, desired: evening, catalog: fullCatalog(), minuteOfDay: 720)
        t.expectEqual(sel.transition, ContentID("transition://A/1200->1730"), "transition id")
        t.expectEqual(sel.loop, ContentID("loop://A/R1/1730"), "target loop")
    }

    run("Resolver.sceneChangeHasNoTransition") { t in
        let current = ContentKey(scene: .a, outfit: .r1, time: .noon)
        let sel = ContentResolver.resolve(
            currentKey: current, desired: DesiredState(scene: .b, outfit: .r1, timeMode: .fixed(.noon)),
            catalog: fullCatalog(), minuteOfDay: 720)
        t.expectNil(sel.transition, "cross-scene has no transition asset")
        t.expectEqual(sel.loop, ContentID("loop://B/R1/1200"), "target loop")
    }

    run("Resolver.outfitOnlyChangeHasNoTransition") { t in
        let current = ContentKey(scene: .a, outfit: .r1, time: .noon)
        let sel = ContentResolver.resolve(
            currentKey: current, desired: DesiredState(scene: .a, outfit: .r2, timeMode: .fixed(.noon)),
            catalog: fullCatalog(), minuteOfDay: 720)
        t.expectNil(sel.transition, "catalog-verified: no outfit transitions")
    }

    run("Resolver.missingTransitionFallsBackToDirectSwitch") { t in
        var catalog = fullCatalog()
        catalog.transitions[TransitionKey(scene: .a, from: .noon, to: .night)] = nil
        let current = ContentKey(scene: .a, outfit: .r1, time: .noon)
        let sel = ContentResolver.resolve(
            currentKey: current, desired: DesiredState(scene: .a, outfit: .r1, timeMode: .fixed(.night)),
            catalog: catalog, minuteOfDay: 720)
        t.expectNil(sel.transition, "missing transition → direct")
        t.expectEqual(sel.loop, ContentID("loop://A/R1/2000"), "target loop")
    }

    run("Resolver.simultaneousOutfitAndTimeDoesNotBorrowTimeTransition") { t in
        let sel = ContentResolver.resolve(currentKey: ContentKey(scene: .a, outfit: .r1, time: .noon),
            desired: DesiredState(scene: .a, outfit: .r2, timeMode: .fixed(.evening)),
            catalog: fullCatalog(), minuteOfDay: 720)
        t.expectNil(sel.transition, "time-only clip has no reviewed outfit-change semantics")
        t.expectEqual(sel.targetKey, ContentKey(scene: .a, outfit: .r2, time: .evening), "explicit target retained")
    }

    run("Resolver.autoModeUsesWallClockBucket") { t in
        let auto = DesiredState(scene: .a, outfit: .r1, timeMode: .auto)
        let sel = ContentResolver.resolve(currentKey: nil, desired: auto, catalog: fullCatalog(), minuteOfDay: 1050)
        t.expectEqual(sel.targetKey.time, .evening, "17:30 bucket")
    }

    run("Resolver.missingLoopIsNotPlayable") { t in
        var catalog = fullCatalog()
        catalog.loops[ContentKey(scene: .c, outfit: .r3, time: .night)] = nil
        let sel = ContentResolver.resolve(
            currentKey: nil, desired: DesiredState(scene: .c, outfit: .r3, timeMode: .fixed(.night)),
            catalog: catalog, minuteOfDay: 720)
        t.expect(!sel.isPlayable, "not playable")
        t.expectNil(sel.loop, "loop nil")
    }

    run("Resolver.soundtrackIsIndependentAndNeverSubstitutes") { t in
        let catalog = fullCatalog()
        for choice in [DailySoundtrackSelection.silent, .legacyDefault, .track(ContentID("ambient://2")), .track(ContentID("missing"))] {
            let expected: ContentID? = choice == .legacyDefault ? ContentID("ambient://1") : choice == .track(ContentID("ambient://2")) ? ContentID("ambient://2") : nil
            for scene in Scene.allCases {
                for time in TimeOfDay.allCases {
                    let intent = DesiredState(scene: scene, outfit: .r2, timeMode: .fixed(time), dailySoundtrack: choice)
                    let result = ContentResolver.resolve(currentKey: nil, desired: intent, catalog: catalog, minuteOfDay: 720)
                    t.expectEqual(result.ambient, expected, "video selection never rotates or substitutes the soundtrack")
                }
            }
        }
        var reversed = catalog; reversed.ambientTracks.reverse()
        t.expectEqual(reversed.ambientTrack(selection: .legacyDefault)?.id, ContentID("ambient://1"), "legacy choice is stable across catalog ordering")
        t.expectNil(ContentCatalog().ambientTrack(selection: .legacyDefault), "empty valid catalog resolves silence")
        t.expectEqual(DesiredState().dailySoundtrack, .silent, "new installs start silent")
        let silent = PlaybackPolicy.evaluate(desired: DesiredState(dailyMusicPaused: true), context: RuntimeContext())
        t.expect(silent.ambientVolume == 0 && !silent.ambientPaused && silent.visual == .full, "silence never retains an ambient item or pauses video")
    }

    run("Resolver.sameTargetIsIdempotent") { t in
        let current = ContentKey(scene: .a, outfit: .r1, time: .noon)
        let sel = ContentResolver.resolve(currentKey: current, desired: desired, catalog: fullCatalog(), minuteOfDay: 720)
        t.expectNil(sel.transition, "same target → no transition")
    }
}

func runPlaybackPolicyTests() {
    run("Policy.dailyMusicPauseRetainsOnlyEligibleAmbient") { t in
        var desired = DesiredState(dailyMusicPaused: true, dailySoundtrack: .legacyDefault)
        let paused = PlaybackPolicy.evaluate(desired: desired, context: RuntimeContext())
        t.expect(paused.ambientPaused && paused.ambientVolume == 0 && paused.visual == .full,
                 "soundtrack pause retains only ambient; picture still advances")
        let song = PerformanceSession(target: .localFile(.init(trackID: "track", fileID: "file", catalogRevision: .init("r"))))
        let songPolicy = PlaybackPolicy.evaluate(desired: desired, context: RuntimeContext(), performance: song)
        t.expect(!songPolicy.ambientPaused && !songPolicy.performancePaused && songPolicy.musicVolume > 0,
                 "song admission releases ambient without inheriting its pause")
        for context in [RuntimeContext(screenLocked: true), RuntimeContext(screenAwake: false),
                        RuntimeContext(systemAwake: false), RuntimeContext(sessionActive: false),
                        RuntimeContext(thermal: .serious), RuntimeContext(thermal: .critical)] {
            let state = PlaybackPolicy.evaluate(desired: desired, context: context)
            t.expect(!state.ambientPaused && state.ambientVolume == 0, "safety/context suppression releases paused audio")
        }
        for restricted in [DesiredState(dailyMusicPaused: true, dailySoundtrack: .legacyDefault, profile: .movie),
                           DesiredState(ambientVolume: 0, dailyMusicPaused: true, dailySoundtrack: .legacyDefault),
                           DesiredState(ambientMuted: true, dailyMusicPaused: true, dailySoundtrack: .legacyDefault),
                           DesiredState(paused: true, dailyMusicPaused: true, dailySoundtrack: .legacyDefault)] {
            t.expect(!PlaybackPolicy.evaluate(desired: restricted, context: RuntimeContext()).ambientPaused,
                     "profile, mute, zero gain and global pause retain their cleanup semantics")
        }
        desired.dailyMusicPaused = false
        let resumed = PlaybackPolicy.evaluate(desired: desired, context: RuntimeContext())
        t.expect(resumed.ambientVolume > 0 && !resumed.ambientPaused && resumed.visual == .full,
                 "resuming restores unchanged ambient gain without changing picture policy")
    }

    run("Policy.dailyExplicitPauseIsIndependentAndCannotOverrideSafety") { t in
        var desired = DesiredState(scene: .a, outfit: .r3, timeMode: .fixed(.evening), dailyVisualPaused: true)
        let song = PerformanceSession(id: "independent", target: .localFile(.init(trackID: "track", fileID: "file", catalogRevision: .init("r"))))
        let context = RuntimeContext(homeCompanionVisible: true, lowPowerMode: true)
        let paused = PlaybackPolicy.evaluate(desired: desired, context: context, performance: song)
        t.expect(paused.visual == .paused && !paused.performancePaused && paused.musicVolume > 0,
                 "scene-only pause leaves explicit song clock and volume intact")
        desired.dailyVisualPaused = false
        let resumed = PlaybackPolicy.evaluate(desired: desired, context: context, performance: song)
        t.expect(resumed.visual == .full && resumed.musicVolume == paused.musicVolume,
                 "scene resume changes only daily visual policy")
        for blocked in [RuntimeContext(screenLocked: true), RuntimeContext(screenAwake: false),
                        RuntimeContext(systemAwake: false), RuntimeContext(sessionActive: false),
                        RuntimeContext(thermal: .serious)] {
            let state = PlaybackPolicy.evaluate(desired: desired, context: blocked, performance: song)
            t.expect(state.visual == .paused && state.performancePaused, "scene resume never overrides safety")
        }
        desired.paused = true
        t.expect(PlaybackPolicy.evaluate(desired: desired, context: context, performance: song).visual == .paused,
                 "scene resume never clears global pause")
        desired.paused = false; desired.profile = .movie
        t.expect(PlaybackPolicy.evaluate(desired: desired, context: context, performance: song).visual == .paused,
                 "scene resume never clears profile pause")
    }

    let clean = RuntimeContext() // defaults = awake, nominal, no fullscreen
    let performance = PerformanceSession(id: "policy-performance", variant: ResolvedPerformanceVariant(
        performanceID: PerformanceID("performance://policy-fixture"),
        variantID: PerformanceVariantID("variant://policy-fixture/daylight/side"),
        lighting: .daylight, presentation: .sidePerformance,
        catalogRevision: PerformanceCatalogRevision("policy-test-revision"), reason: .explicitUserPreference))

    run("Policy.cleanContextPlaysAtFullVolumes") { t in
        let state = PlaybackPolicy.evaluate(desired: DesiredState(dailySoundtrack: .legacyDefault), context: clean)
        t.expectEqual(state.visual, VisualPolicy.full, "visual full")
        t.expectNear(state.musicVolume, 0.56, "music = 0.8*0.7")
        t.expectNear(state.ambientVolume, 0.4, "ambient = 0.8*0.5")
        t.expect(state.reasons.isEmpty, "no reasons")
    }

    run("Policy.userPausePausesEverything") { t in
        var d = DesiredState(dailySoundtrack: .legacyDefault); d.paused = true
        let state = PlaybackPolicy.evaluate(desired: d, context: clean)
        t.expectEqual(state.visual, VisualPolicy.paused, "visual paused")
        t.expectEqual(state.musicVolume, 0.0, "music muted")
        t.expectEqual(state.ambientVolume, 0.0, "ambient muted")
        t.expect(state.reasons.contains("user-paused"), "reason recorded")
    }

    run("Policy.screenAsleepPausesEverything") { t in
        let state = PlaybackPolicy.evaluate(desired: DesiredState(dailySoundtrack: .legacyDefault), context: RuntimeContext(screenAwake: false))
        t.expectEqual(state.visual, VisualPolicy.paused, "visual paused")
        t.expectEqual(state.musicVolume, 0.0, "music muted")
    }

    run("Policy.inactiveSessionPausesDailyAndPerformanceWithoutChangingIntent") { t in
        let desired = DesiredState(dailySoundtrack: .legacyDefault)
        for session in [nil, Optional(performance)] {
            var context = RuntimeContext(sessionActive: false)
            let state = PlaybackPolicy.evaluate(desired: desired, context: context, performance: session)
            t.expectEqual(state.visual, VisualPolicy.paused, "inactive session pauses visual")
            t.expectEqual(state.musicVolume, 0, "inactive session mutes music")
            t.expectEqual(state.ambientVolume, 0, "inactive session mutes ambient")
            t.expect(state.reasons.contains("session-inactive"), "diagnostic identifies session restriction")
            context.sessionActive = true
            let resumed = PlaybackPolicy.evaluate(desired: desired, context: context, performance: session)
            let expected = PlaybackPolicy.evaluate(desired: desired, context: clean, performance: session)
            t.expectEqual(resumed, expected, "session recovery restores original intent")
            for restricted in [RuntimeContext(screenAwake: false), RuntimeContext(systemAwake: false),
                               RuntimeContext(screenLocked: true), RuntimeContext(thermal: .serious)] {
                let blocked = PlaybackPolicy.evaluate(desired: desired, context: restricted, performance: session)
                t.expectEqual(blocked.visual, VisualPolicy.paused, "other restrictions survive session return")
                t.expectEqual(blocked.musicVolume, 0, "other restrictions still mute music")
            }
            var paused = desired
            paused.paused = true
            t.expectEqual(PlaybackPolicy.evaluate(desired: paused, context: context, performance: session).visual,
                          VisualPolicy.paused, "session return cannot undo user pause")
        }
    }

    run("Policy.systemAsleepPausesAndWakeResumes") { t in
        let asleep = PlaybackPolicy.evaluate(desired: DesiredState(dailySoundtrack: .legacyDefault), context: RuntimeContext(systemAwake: false))
        t.expectEqual(asleep.visual, VisualPolicy.paused, "system asleep pauses visual")
        t.expectEqual(asleep.musicVolume, 0.0, "system asleep mutes")
        t.expectEqual(asleep.ambientVolume, 0.0, "system asleep mutes ambient")
        t.expect(asleep.reasons.contains("system-asleep"), "reason recorded")

        let wake = PlaybackPolicy.evaluate(desired: DesiredState(dailySoundtrack: .legacyDefault), context: RuntimeContext())
        t.expectEqual(wake.visual, VisualPolicy.full, "wake resumes full visual")
        t.expectNear(wake.musicVolume, 0.56, "wake restores music volume")
        t.expectNear(wake.ambientVolume, 0.4, "wake restores ambient volume")
        t.expect(wake.reasons.isEmpty, "no restrictions after wake")
    }

    run("Policy.seriousAndCriticalThermalPauseAllMedia") { t in
        for thermal in [ThermalLevel.serious, .critical] {
            for session in [nil, Optional(performance)] {
                let state = PlaybackPolicy.evaluate(desired: DesiredState(dailySoundtrack: .legacyDefault),
                    context: RuntimeContext(thermal: thermal), performance: session)
                t.expectEqual(state.visual, VisualPolicy.paused, "\(thermal) pauses daily and performance video")
                t.expectEqual(state.musicVolume, 0.0, "\(thermal) pauses music work")
                t.expectEqual(state.ambientVolume, 0.0, "\(thermal) pauses ambient work")
                t.expect(state.reasons.contains("thermal-\(thermal.rawValue)"), "thermal reason recorded")
            }
        }
    }

    run("Policy.lowPowerFreezesDailyVisualAndPreservesRequestedAudio") { t in
        let state = PlaybackPolicy.evaluate(desired: DesiredState(dailySoundtrack: .legacyDefault), context: RuntimeContext(lowPowerMode: true))
        t.expectEqual(state.visual, VisualPolicy.paused, "daily visual is static")
        t.expectNear(state.musicVolume, 0.56, "music remains at requested level")
        t.expectNear(state.ambientVolume, 0.4, "ambient remains at requested level")
        t.expect(state.reasons.contains("low-power:daily-static"), "workload restriction recorded")
    }

    run("Policy.visibleHomeOverridesOnlyDailyVisibilityRestrictions") { t in
        var context = RuntimeContext(desktopVisible: false, homeCompanionVisible: true,
                                     fullscreenAppActive: true, lowPowerMode: true)
        var desired = DesiredState(dailySoundtrack: .legacyDefault)
        desired.pauseVisualOnFullscreen = true
        desired.muteAudioOnFullscreen = true
        let home = PlaybackPolicy.evaluate(desired: desired, context: context)
        t.expectEqual(home.visual, .full, "visible home animates despite covered desktop, fullscreen and Low Power")
        t.expectNear(home.ambientVolume, 0.4, "fullscreen preserves the independent soundtrack")
        context.homeCompanionVisible = false
        let hidden = PlaybackPolicy.evaluate(desired: desired, context: context)
        t.expectEqual(hidden.visual, .paused, "withdrawal immediately restores unattended daily restrictions")
        let song = PlaybackPolicy.evaluate(desired: desired, context: context, performance: performance)
        t.expect(!song.performancePaused, "hiding home does not pause the independent song")
    }

    run("Policy.visibleHomeCannotOverrideOwnerOrSystemSafety") { t in
        var paused = DesiredState(dailySoundtrack: .legacyDefault); paused.paused = true
        let restrictions: [(DesiredState, RuntimeContext)] = [
            (paused, RuntimeContext()), (DesiredState(dailySoundtrack: .legacyDefault, profile: .movie), RuntimeContext()),
            (DesiredState(dailySoundtrack: .legacyDefault), RuntimeContext(systemAwake: false)),
            (DesiredState(dailySoundtrack: .legacyDefault), RuntimeContext(screenAwake: false)),
            (DesiredState(dailySoundtrack: .legacyDefault), RuntimeContext(screenLocked: true)),
            (DesiredState(dailySoundtrack: .legacyDefault), RuntimeContext(sessionActive: false)),
            (DesiredState(dailySoundtrack: .legacyDefault), RuntimeContext(thermal: .serious)),
            (DesiredState(dailySoundtrack: .legacyDefault), RuntimeContext(thermal: .critical))]
        for (desired, original) in restrictions {
            var context = original
            context.homeCompanionVisible = true
            context.lowPowerMode = true
            let state = PlaybackPolicy.evaluate(desired: desired, context: context, performance: performance)
            t.expectEqual(state.visual, .paused, "visible home cannot clear a stronger pause")
            t.expect(state.performancePaused && state.musicVolume == 0, "song safety remains authoritative")
        }
        var song = performance; song.paused = true
        let state = PlaybackPolicy.evaluate(desired: DesiredState(dailySoundtrack: .legacyDefault),
            context: RuntimeContext(homeCompanionVisible: true, lowPowerMode: true), performance: song)
        t.expect(state.performancePaused && state.visual == .full, "song pause remains scoped while visible home animates")
    }

    run("Policy.visibleHomeCancelsPendingDailyResourceRelease") { t in
        var context = RuntimeContext(desktopVisible: false, lowPowerMode: true)
        var retention = DailyResourceLifecycle()
        let hidden = PlaybackPolicy.evaluate(desired: DesiredState(dailySoundtrack: .legacyDefault), context: context)
        let effects = retention.update(paused: hidden.visual == .paused, hasVideo: true,
            retentionDelay: PlaybackPolicy.dailyRetentionDelay(context: context, memoryPressure: false), now: 0)
        guard case .schedule(let token, _) = effects.first else { return t.expect(false, "hidden daily schedules release") }
        context.homeCompanionVisible = true
        let visible = PlaybackPolicy.evaluate(desired: DesiredState(dailySoundtrack: .legacyDefault), context: context)
        _ = retention.update(paused: visible.visual == .paused, hasVideo: true,
            retentionDelay: PlaybackPolicy.dailyRetentionDelay(context: context, memoryPressure: false), now: 1)
        t.expect(!retention.releaseDeadlineFired(token: token), "visible demand invalidates the old release deadline")
    }

    run("Policy.lowPowerPreservesExplicitPerformance") { t in
        let desired = DesiredState(dailySoundtrack: .legacyDefault, profile: .coding)
        let normal = PlaybackPolicy.evaluate(desired: desired, context: clean, performance: performance)
        let lowPower = PlaybackPolicy.evaluate(desired: desired,
            context: RuntimeContext(lowPowerMode: true), performance: performance)
        t.expectEqual(lowPower.performancePaused, normal.performancePaused, "Low Power preserves the song clock")
        t.expectEqual(lowPower.visual, .paused, "independent daily visual is static")
        t.expectNear(lowPower.musicVolume, 0.084, "performance honors the selected audio profile")
        t.expectEqual(lowPower.ambientVolume, 0.0, "daily ambient stays suppressed during performance")
    }

    run("Policy.dailyRetentionStillEligibleDuringIndependentSong") { t in
        let context = RuntimeContext(desktopVisible: false, lowPowerMode: true)
        let state = PlaybackPolicy.evaluate(desired: DesiredState(dailySoundtrack: .legacyDefault), context: context, performance: performance)
        var retention = DailyResourceLifecycle()
        let effects = retention.update(paused: state.visual == .paused, hasVideo: true,
            retentionDelay: PlaybackPolicy.dailyRetentionDelay(context: context, memoryPressure: false), now: 0)
        guard case .schedule(let token, _) = effects.first else {
            return t.expect(false, "covered daily engine schedules release even while song runs")
        }
        t.expect(retention.releaseDeadlineFired(token: token), "independent daily release remains eligible")
        t.expect(!state.performancePaused && state.musicVolume > 0, "daily release does not pause song")
    }

    run("Policy.lowPowerCannotOverrideStrongerPauses") { t in
        var pausedDesired = DesiredState(dailySoundtrack: .legacyDefault)
        pausedDesired.paused = true
        let restrictions: [(DesiredState, RuntimeContext)] = [
            (pausedDesired, RuntimeContext(lowPowerMode: true)),
            (DesiredState(dailySoundtrack: .legacyDefault, profile: .movie), RuntimeContext(lowPowerMode: true)),
            (DesiredState(dailySoundtrack: .legacyDefault), RuntimeContext(screenLocked: true, lowPowerMode: true)),
            (DesiredState(dailySoundtrack: .legacyDefault), RuntimeContext(screenAwake: false, lowPowerMode: true)),
            (DesiredState(dailySoundtrack: .legacyDefault), RuntimeContext(systemAwake: false, lowPowerMode: true)),
        ]
        for (desired, context) in restrictions {
            for session in [nil, Optional(performance)] {
                let state = PlaybackPolicy.evaluate(desired: desired, context: context, performance: session)
                t.expectEqual(state.visual, .paused, "stronger restriction pauses daily and performance")
                t.expectEqual(state.musicVolume, 0.0, "Low Power cannot unmute stronger music restriction")
                t.expectEqual(state.ambientVolume, 0.0, "Low Power cannot unmute stronger ambient restriction")
            }
        }
        var pausedPerformance = performance
        pausedPerformance.paused = true
        let state = PlaybackPolicy.evaluate(desired: DesiredState(dailySoundtrack: .legacyDefault), context: RuntimeContext(lowPowerMode: true),
                                            performance: pausedPerformance)
        t.expectEqual(state.visual, .paused, "transient performance pause also wins")
        t.expectEqual(state.musicVolume, 0.0, "transient pause remains silent")
    }

    run("Policy.lowPowerPreservesChannelMuteAndAppDuck") { t in
        let profile = Profile(id: "custom", name: "Custom", musicFactor: 1, ambientFactor: 1,
            appRules: [AppRule(bundleID: "test.editor", action: .duckAudio, duckFactor: 0.25)])
        var desired = DesiredState(dailySoundtrack: .legacyDefault, profile: profile)
        desired.ambientMuted = true
        for session in [nil, Optional(performance)] {
            let state = PlaybackPolicy.evaluate(desired: desired,
                context: RuntimeContext(lowPowerMode: true, foregroundAppBundleID: "test.editor"), performance: session)
            t.expectNear(state.musicVolume, 0.14, "app duck remains effective without another Low Power audio scale")
            t.expectEqual(state.ambientVolume, 0.0, "muted ambient is never enabled by Low Power policy")
        }
    }

    run("Policy.energyRestrictionsRecoverWithoutMutatingUserIntent") { t in
        let desired = DesiredState(scene: .b, outfit: .r2, timeMode: .fixed(.night), profile: .quiet)
        let originalDesired = desired
        let originalPerformance = performance
        for session in [nil, Optional(performance)] {
            let normal = PlaybackPolicy.evaluate(desired: desired, context: clean, performance: session)
            _ = PlaybackPolicy.evaluate(desired: desired, context: RuntimeContext(lowPowerMode: true), performance: session)
            _ = PlaybackPolicy.evaluate(desired: desired, context: RuntimeContext(lowPowerMode: true, thermal: .serious),
                                        performance: session)
            let recovered = PlaybackPolicy.evaluate(desired: desired, context: clean, performance: session)
            t.expectEqual(recovered, normal, "cleared restrictions restore the original playback policy")
            t.expectEqual(recovered.visual, .full, "normal thermal and power state resume video")
        }
        t.expectEqual(desired, originalDesired, "daily preferences remain intact")
        t.expectEqual(performance, originalPerformance, "session identity, variant, and user pause remain intact")
        let fair = PlaybackPolicy.evaluate(desired: desired, context: RuntimeContext(thermal: .fair), performance: performance)
        t.expectEqual(fair.visual, .full, "thermal recovery to fair permits performance resume")
    }

    run("Policy.thermalRecoveryRetainsRemainingLowPowerRestriction") { t in
        let context = RuntimeContext(lowPowerMode: true, thermal: .fair)
        let daily = PlaybackPolicy.evaluate(desired: DesiredState(dailySoundtrack: .legacyDefault), context: context)
        t.expectEqual(daily.visual, .paused, "remaining Low Power still freezes daily video after thermal recovery")
        t.expectNear(daily.ambientVolume, 0.4, "audio resumes after serious thermal pressure clears")
        let requested = PlaybackPolicy.evaluate(desired: DesiredState(dailySoundtrack: .legacyDefault), context: context, performance: performance)
        t.expectEqual(requested.visual, .paused, "daily remains static under remaining Low Power")
        t.expect(!requested.performancePaused, "song resumes after thermal restriction clears")
        t.expectNear(requested.musicVolume, 0.56, "performance audio resumes at requested level")
    }

    run("Policy.occludedDailyPausesOnlyVisualWork") { t in
        let profile = Profile(id: "occlusion-test", name: "Custom", musicFactor: 0.5, ambientFactor: 0.75,
            appRules: [AppRule(bundleID: "test.editor", action: .duckAudio, duckFactor: 0.25)])
        var desired = DesiredState(masterVolume: 0.6, musicVolume: 0.8, ambientVolume: 0.4, dailySoundtrack: .legacyDefault, profile: profile)
        let visible = PlaybackPolicy.evaluate(desired: desired,
            context: RuntimeContext(foregroundAppBundleID: "test.editor"))
        let occluded = PlaybackPolicy.evaluate(desired: desired,
            context: RuntimeContext(desktopVisible: false, foregroundAppBundleID: "test.editor"))
        t.expectEqual(occluded.visual, .paused, "covered daily visual stops animating")
        t.expectNear(occluded.musicVolume, visible.musicVolume, "music preserves user volume, profile and app duck")
        t.expectNear(occluded.ambientVolume, visible.ambientVolume, "ambient preserves user volume, profile and app duck")
        t.expect(occluded.ambientVolume > 0, "occlusion alone does not mute requested ambient")
        t.expect(occluded.reasons.contains("desktop-occluded"), "occlusion restriction is observable")
        desired.ambientMuted = true
        let muted = PlaybackPolicy.evaluate(desired: desired, context: RuntimeContext(desktopVisible: false))
        t.expectEqual(muted.ambientVolume, 0, "occlusion does not unmute a user-muted channel")
    }

    run("Policy.uncoveringDailyRestoresOnlyAllowedPlayback") { t in
        var desired = DesiredState(scene: .c, outfit: .r3, timeMode: .fixed(.evening), dailySoundtrack: .legacyDefault, profile: .quiet)
        let visible = PlaybackPolicy.evaluate(desired: desired, context: clean)
        var context = RuntimeContext(desktopVisible: false)
        let covered = PlaybackPolicy.evaluate(desired: desired, context: context)
        t.expectEqual(covered.visual, .paused, "covered state pauses")
        context.desktopVisible = true
        let uncovered = PlaybackPolicy.evaluate(desired: desired, context: context)
        t.expectEqual(uncovered, visible, "revealed desktop restores the original playback and volume")
        t.expect(!uncovered.reasons.contains("desktop-occluded"), "stale occlusion reason is removed")
        desired.paused = true
        let userPaused = PlaybackPolicy.evaluate(desired: desired, context: context)
        t.expectEqual(userPaused.visual, .paused, "revealing desktop cannot clear the user's pause")
        t.expectEqual(userPaused.ambientVolume, 0, "revealing desktop cannot resume user-paused audio")
        context.lowPowerMode = true
        desired.paused = false
        let lowPower = PlaybackPolicy.evaluate(desired: desired, context: context)
        t.expectEqual(lowPower.visual, .paused, "remaining Low Power restriction still freezes the revealed desktop")
        t.expect(lowPower.ambientVolume > 0, "remaining Low Power still permits requested audio")
    }

    run("Policy.occlusionDoesNotInterruptExplicitPerformance") { t in
        let desired = DesiredState(dailySoundtrack: .legacyDefault, profile: .quiet)
        let visible = PlaybackPolicy.evaluate(desired: desired, context: clean, performance: performance)
        let covered = PlaybackPolicy.evaluate(desired: desired,
            context: RuntimeContext(desktopVisible: false), performance: performance)
        t.expectEqual(covered.performancePaused, visible.performancePaused, "coverage preserves song clock")
        t.expectEqual(covered.visual, .paused, "covered daily engine is paused")
        t.expect(covered.musicVolume > 0, "music continues while covered")
        t.expectEqual(covered.ambientVolume, 0, "daily ambient remains excluded from performance")
        t.expect(covered.reasons.contains("desktop-occluded"), "daily restriction remains observable")
    }

    run("Policy.occlusionCannotOverrideStrongerMediaPauses") { t in
        var pausedDesired = DesiredState(dailySoundtrack: .legacyDefault)
        pausedDesired.paused = true
        let appProfile = Profile(id: "occlusion-pause-app", name: "Custom", musicFactor: 1, ambientFactor: 1,
            appRules: [AppRule(bundleID: "test.player", action: .pauseAll)])
        let restrictions: [(DesiredState, RuntimeContext)] = [
            (pausedDesired, RuntimeContext(desktopVisible: false)),
            (DesiredState(dailySoundtrack: .legacyDefault, profile: .movie), RuntimeContext(desktopVisible: false)),
            (DesiredState(dailySoundtrack: .legacyDefault), RuntimeContext(screenLocked: true, desktopVisible: false)),
            (DesiredState(dailySoundtrack: .legacyDefault), RuntimeContext(screenAwake: false, desktopVisible: false)),
            (DesiredState(dailySoundtrack: .legacyDefault), RuntimeContext(systemAwake: false, desktopVisible: false)),
            (DesiredState(dailySoundtrack: .legacyDefault), RuntimeContext(desktopVisible: false, thermal: .serious)),
            (DesiredState(dailySoundtrack: .legacyDefault), RuntimeContext(desktopVisible: false, thermal: .critical)),
            (DesiredState(dailySoundtrack: .legacyDefault, profile: appProfile), RuntimeContext(desktopVisible: false, foregroundAppBundleID: "test.player")),
        ]
        for (desired, context) in restrictions {
            for session in [nil, Optional(performance)] {
                let state = PlaybackPolicy.evaluate(desired: desired, context: context, performance: session)
                t.expectEqual(state.visual, .paused, "stronger pause applies to daily and explicit performance")
                t.expectEqual(state.musicVolume, 0, "occlusion cannot unmute stronger music restriction")
                t.expectEqual(state.ambientVolume, 0, "occlusion cannot unmute stronger ambient restriction")
            }
        }
        var pausedPerformance = performance
        pausedPerformance.paused = true
        let state = PlaybackPolicy.evaluate(desired: DesiredState(dailySoundtrack: .legacyDefault), context: RuntimeContext(desktopVisible: false),
                                            performance: pausedPerformance)
        t.expectEqual(state.visual, .paused, "explicit performance pause remains authoritative while covered")
        t.expectEqual(state.musicVolume, 0, "explicit performance pause remains silent while covered")
    }

    run("Policy.explicitSongSurvivesOtherFullscreenSpaces") { t in
        for mode in [PerformancePlaybackMode.watch, .listen] {
            var session = performance
            session = PerformanceSession(target: session.target, mode: mode)
            let desired = DesiredState(dailySoundtrack: .legacyDefault)
            for context in [RuntimeContext(fullscreenAppActive: true),
                            RuntimeContext(desktopVisible: false, fullscreenAppActive: true),
                            RuntimeContext(fullscreenAppActive: true, lowPowerMode: true)] {
                let state = PlaybackPolicy.evaluate(desired: desired, context: context, performance: session)
                t.expect(!state.performancePaused, "changing fullscreen Space does not pause the song")
                t.expectNear(state.musicVolume, 0.56, "requested song audio survives fullscreen defaults")
                t.expectEqual(state.visual, .paused, "daily fullscreen restriction is independent of song capability")
            }
            let locked = PlaybackPolicy.evaluate(desired: desired,
                context: RuntimeContext(screenLocked: true, fullscreenAppActive: true), performance: session)
            t.expect(locked.performancePaused && locked.musicVolume == 0, "lock still overrides fullscreen continuation")
        }
    }

    run("Policy.fullscreenPreservesIndependentSoundtrack") { t in
        let profile = Profile(id: "fullscreen-test", name: "Custom", musicFactor: 0.5, ambientFactor: 0.75,
            appRules: [AppRule(bundleID: "fixture.app", action: .duckAudio, duckFactor: 0.5)])
        for selection in [DailySoundtrackSelection.legacyDefault, .track(ContentID("ambient://1"))] {
            for legacyMute in [true, false] {
                var desired = DesiredState(masterVolume: 0.6, musicVolume: 0.8, ambientVolume: 0.4,
                    dailySoundtrack: selection, profile: profile, muteAudioOnFullscreen: legacyMute)
                for homeVisible in [false, true] {
                    let context = RuntimeContext(desktopVisible: false, homeCompanionVisible: homeVisible,
                        fullscreenAppActive: true, foregroundAppBundleID: "fixture.app")
                    let state = PlaybackPolicy.evaluate(desired: desired, context: context)
                    t.expectEqual(state.visual, homeVisible ? .full : .paused, "fullscreen only suppresses unattended picture")
                    t.expectNear(state.ambientVolume, 0.09, "soundtrack preserves master, channel, profile and app duck")
                    t.expectNear(state.musicVolume, 0.12, "fullscreen leaves the music bus gain unchanged")
                    desired.dailyMusicPaused = true
                    let paused = PlaybackPolicy.evaluate(desired: desired, context: context)
                    t.expect(paused.ambientPaused && paused.ambientVolume == 0 && paused.visual == state.visual,
                             "explicit soundtrack pause retains its item without changing picture intent")
                    desired.dailyMusicPaused = false
                    desired.dailyVisualPaused = true
                    let picturePaused = PlaybackPolicy.evaluate(desired: desired, context: context)
                    t.expect(picturePaused.visual == .paused && picturePaused.ambientVolume == state.ambientVolume,
                             "picture pause cannot interrupt the soundtrack")
                    desired.dailyVisualPaused = false
                }
            }
        }
    }

    run("Policy.fullscreenCannotOverrideSoundtrackSilenceOrSafety") { t in
        let selected = DailySoundtrackSelection.track(ContentID("ambient://1"))
        let intentRestrictions = [
            DesiredState(dailySoundtrack: .silent),
            DesiredState(ambientMuted: true, dailySoundtrack: selected),
            DesiredState(masterVolume: 0, dailySoundtrack: selected),
            DesiredState(ambientVolume: 0, dailySoundtrack: selected),
            DesiredState(paused: true, dailySoundtrack: selected),
            DesiredState(dailySoundtrack: selected, profile: .silent),
            DesiredState(dailySoundtrack: selected, profile: .movie),
            DesiredState(dailySoundtrack: selected, profile: Profile(id: "mute-app", name: "Mute",
                musicFactor: 1, ambientFactor: 1, appRules: [AppRule(bundleID: "fixture.app", action: .muteAudio)])),
            DesiredState(dailySoundtrack: selected, profile: Profile(id: "pause-app", name: "Pause",
                musicFactor: 1, ambientFactor: 1, appRules: [AppRule(bundleID: "fixture.app", action: .pauseAll)])),
        ]
        let safetyContexts = [RuntimeContext(screenAwake: false), RuntimeContext(systemAwake: false),
            RuntimeContext(screenLocked: true), RuntimeContext(sessionActive: false),
            RuntimeContext(thermal: .serious), RuntimeContext(thermal: .critical)]
        for homeVisible in [false, true] {
            for musicPaused in [false, true] {
                let cases = intentRestrictions.map { ($0, RuntimeContext(foregroundAppBundleID: "fixture.app")) }
                    + safetyContexts.map { (DesiredState(dailySoundtrack: selected), $0) }
                for (var desired, var context) in cases {
                    desired.dailyMusicPaused = musicPaused
                    context.homeCompanionVisible = homeVisible
                    context.fullscreenAppActive = true
                    let state = PlaybackPolicy.evaluate(desired: desired, context: context)
                    t.expect(state.ambientVolume == 0 && !state.ambientPaused,
                             "fullscreen never unmutes or retains audio forbidden by intent or safety")
                }
            }
        }
    }

    run("Policy.profileSilentMutesButKeepsVisual") { t in
        let state = PlaybackPolicy.evaluate(desired: DesiredState(dailySoundtrack: .legacyDefault, profile: .silent), context: clean)
        t.expectEqual(state.visual, VisualPolicy.full, "visual full")
        t.expectEqual(state.musicVolume, 0.0, "music 0")
        t.expectEqual(state.ambientVolume, 0.0, "ambient 0")
    }

    run("Policy.profileMoviePausesVisualAndAudio") { t in
        let state = PlaybackPolicy.evaluate(desired: DesiredState(dailySoundtrack: .legacyDefault, profile: .movie), context: clean)
        t.expectEqual(state.visual, VisualPolicy.paused, "visual paused")
        t.expectEqual(state.musicVolume, 0.0, "music 0")
    }

    run("Policy.profileCodingScalesAudio") { t in
        let state = PlaybackPolicy.evaluate(desired: DesiredState(dailySoundtrack: .legacyDefault, profile: .coding), context: clean)
        t.expectNear(state.musicVolume, 0.084, "music = 0.8*0.7*0.15")
        t.expectNear(state.ambientVolume, 0.06, "ambient = 0.8*0.5*0.15")
    }

    run("Policy.appRulePauseOnlyMatchesForegroundApp") { t in
        let profile = Profile(
            id: "custom", name: "Custom", musicFactor: 1, ambientFactor: 1,
            appRules: [AppRule(bundleID: "com.apple.DVDPlayer", action: .pauseAll)])
        let d = DesiredState(dailySoundtrack: .legacyDefault, profile: profile)
        let active = PlaybackPolicy.evaluate(desired: d, context: RuntimeContext(foregroundAppBundleID: "com.apple.DVDPlayer"))
        t.expectEqual(active.visual, VisualPolicy.paused, "matching app pauses")
        t.expectEqual(active.musicVolume, 0.0, "matching app mutes")
        let inactive = PlaybackPolicy.evaluate(desired: d, context: RuntimeContext(foregroundAppBundleID: "com.apple.Terminal"))
        t.expectEqual(inactive.visual, VisualPolicy.full, "other app unaffected")
        t.expectNear(inactive.musicVolume, 0.56, "other app volumes normal")
    }

    run("Policy.appRuleDuckScalesAudio") { t in
        let profile = Profile(
            id: "custom", name: "Custom", musicFactor: 1, ambientFactor: 1,
            appRules: [AppRule(bundleID: "com.apple.QuickTimePlayerX", action: .duckAudio, duckFactor: 0.25)])
        let d = DesiredState(dailySoundtrack: .legacyDefault, profile: profile)
        let state = PlaybackPolicy.evaluate(desired: d, context: RuntimeContext(foregroundAppBundleID: "com.apple.QuickTimePlayerX"))
        t.expectNear(state.musicVolume, 0.14, "music ducked = 0.56*0.25")
    }

    run("Policy.userMuteFlagsZeroOnlyTheirChannel") { t in
        var d = DesiredState(dailySoundtrack: .legacyDefault); d.musicMuted = true
        let state = PlaybackPolicy.evaluate(desired: d, context: clean)
        t.expectEqual(state.musicVolume, 0.0, "music 0")
        t.expectNear(state.ambientVolume, 0.4, "ambient unaffected")
    }

    run("Policy.worstConditionWins") { t in
        let state = PlaybackPolicy.evaluate(
            desired: DesiredState(dailySoundtrack: .legacyDefault),
            context: RuntimeContext(lowPowerMode: true, thermal: .serious))
        t.expectEqual(state.visual, .paused, "serious thermal keeps visual paused")
        t.expectEqual(state.musicVolume, 0.0, "serious thermal overrides Low Power's preserved music level")
        t.expectEqual(state.ambientVolume, 0.0, "serious thermal overrides Low Power's preserved ambient level")
    }
}

func runIPCTests() {
    run("IPC.commandRoundTrip") { t in
        let commands: [AgentCommand] = [
            .initialize(assetPath: "/tmp/bside"),
            .initialize(DirectoryAccessRequest(path: "/tmp/bside", bookmark: Data([0, 1, 255]))),
            .refreshAssets(DirectoryAccessRequest(path: "/tmp/bside-moved", bookmark: Data([255, 1, 0]), refreshID: "refresh-2")),
            .invalidateDailyAssets(DailyAssetInvalidation(issue: .authorizationRequired, refreshID: "refresh-3")),
            .setHomeCompanionStream(.init()),
            .setHomeCompanionStream(.init(stream: .init(id: "stream", bufferPath: "/tmp/owned-buffer",
                capacity: 640 * 360 * 4, maxWidth: 640, maxHeight: 360))),
            .acknowledgeHomeCompanionFrame(.init(streamID: "stream", sequence: 7)),
            .setDesiredState(DesiredState(scene: .b, outfit: .r3, timeMode: .fixed(.night))),
            .setDesktopWorkspace(.init()),
            .setDesktopWorkspace(.init(isVisible: true, musicTitle: "Quiet / 夜曲\n01",
                musicIsPlaying: true, musicCanToggle: true, pictureIsPaused: true)),
            .startDailyActivity(DailyActivityRequest(requestID: "activity-1", activityID: .desk,
                desired: DesiredState(scene: .a, outfit: .r1, timeMode: .fixed(.evening), paused: true))),
            .setHistoryRecording(HistoryRecordingRequest(enabled: true, epoch: 3, session: "capture-test")),
            .setHistoryRecording(HistoryRecordingRequest(enabled: false, epoch: 4, session: "capture-test")),
            .stopPerformance(sessionID: "session-to-stop"),
            .enterPerformanceFullScreen(sessionID: "session-to-enter"),
            .exitPerformanceFullScreen(sessionID: "session-to-exit"),
            .reloadAssets, .healthCheck, .shutdown,
        ]
        for command in commands {
            let line = IPCCoding.encodeLine(IPCEnvelope(payload: command))
            t.expectNotNil(line, "encoded: \(command)")
            t.expect(line?.contains("\n") == false, "single line")
            let decoded = line.flatMap { IPCCoding.decodeLine($0, as: AgentCommand.self) }
            t.expectEqual(decoded?.payload, command, "round trip")
        }
    }

    run("IPC.eventRoundTrip") { t in
        let events: [AgentEvent] = [
            .performancePresentation(.init(sessionID: "picture", state: .collapsed)),
            .performancePresentation(.init(sessionID: "picture", state: .expanding)),
            .performancePresentation(.init(sessionID: "picture", state: .expanded)),
            .performancePresentation(.init(sessionID: "picture", state: .collapsing)),
            .historyIntervals([PlaybackIntervalSubmission(epoch: 3, session: "capture-test", generation: 2,
                channel: .music, sequence: 9, monotonicStart: 10, monotonicEnd: 11,
                utcStart: Date(timeIntervalSince1970: 1000))]),
            .historyIntervals([]),
            .ready(protocolVersion: IPC.protocolVersion),
            .runtimeSnapshot(RuntimeSnapshot(state: .playing, currentClip: "loop://A/R1/1200", musicVolume: 0.5)),
            .runtimeSnapshot(RuntimeSnapshot(state: .playing, currentClip: "loop://A/R1/1200", pendingDailyTime: .evening)),
            .runtimeSnapshot(RuntimeSnapshot(state: .degraded,
                dailyContentKeys: [ContentKey(scene: .a, outfit: .r1, time: .noon)],
                missingDailyContent: ContentKey(scene: .a, outfit: .r1, time: .night))),
            .runtimeSnapshot(RuntimeSnapshot(state: .paused, dailyContentKeys: [], dailyAmbientTrackCount: 0)),
            .runtimeSnapshot(RuntimeSnapshot(state: .playing, dailyAmbientTrackCount: 2)),
            .runtimeSnapshot(RuntimeSnapshot(state: .degraded, dailyAssetIssue: .accessDenied)),
            .runtimeSnapshot(RuntimeSnapshot(state: .playing, pendingDailyRefresh: true, dailyRefreshID: "refresh-new")),
            .playbackStarted(clipID: "loop://A/R1/1200"),
            .playbackPaused,
            .homeCompanionFrame(.init(streamID: "stream", sequence: 7, contentID: "daily",
                width: 640, height: 360, bytesPerRow: 2560)),
            .contentChanged(clipID: "loop://A/R2/1730"),
            .dailyActivity(DailyActivityReport(requestID: "activity-1", state: .verifying)),
            .dailyActivity(DailyActivityReport(requestID: "activity-1", state: .applied)),
            .dailyActivity(DailyActivityReport(requestID: "activity-1", state: .failed, detail: "identity")),
            .dailyActivity(DailyActivityReport(requestID: "activity-1", state: .cancelled, detail: "superseded")),
            .degraded(reason: "agent restarted 5 times"),
            .error(code: "asset", message: "missing file"),
            .health(uptimeSeconds: 42),
        ]
        for event in events + DesktopWorkspaceAction.allCases.map(AgentEvent.desktopWorkspaceAction) {
            let line = IPCCoding.encodeLine(IPCEnvelope(payload: event))
            t.expectNotNil(line, "encoded: \(event)")
            let decoded = line.flatMap { IPCCoding.decodeLine($0, as: AgentEvent.self) }
            t.expectEqual(decoded?.payload, event, "round trip")
        }
    }

    run("IPC.versionMismatchRejected") { t in
        let previousWorkspaceVersion = #"{"protocolVersion":16,"messageID":"old-workspace","sentAt":0,"payload":{"healthCheck":true}}"#
        t.expectNil(IPCCoding.decodeLine(previousWorkspaceVersion, as: AgentCommand.self),
                    "a previous Agent cannot silently discard desktop control presentation")
        let previousSoundtrackVersion = #"{"protocolVersion":15,"messageID":"old-soundtrack","sentAt":0,"payload":{"healthCheck":true}}"#
        t.expectNil(IPCCoding.decodeLine(previousSoundtrackVersion, as: AgentCommand.self),
                    "previous Agent cannot silently ignore independent soundtrack selection")
        let previousHomeVersion = #"{"protocolVersion":13,"messageID":"old-home","sentAt":0,"payload":{"healthCheck":true}}"#
        t.expectNil(IPCCoding.decodeLine(previousHomeVersion, as: AgentCommand.self), "an IPC12 Agent cannot silently ignore the live home surface")
        let previousDesktopSongVersion = #"{"protocolVersion":11,"messageID":"old","sentAt":0,"payload":{"healthCheck":true}}"#
        t.expectNil(IPCCoding.decodeLine(previousDesktopSongVersion, as: AgentCommand.self), "desktop-song semantics cannot cross IPC12")
        let json = #"{"protocolVersion":99,"messageID":"x","sentAt":0,"payload":{"healthCheck":{}}}"#
        t.expectNil(IPCCoding.decodeLine(json, as: AgentCommand.self), "version mismatch → nil")
        let previous = #"{"protocolVersion":2,"messageID":"old","sentAt":0,"payload":{"initialize":"/tmp/old"}}"#
        t.expectNil(IPCCoding.decodeLine(previous, as: AgentCommand.self), "old bundle protocol cannot silently discard access grants")
        let previousGrantVersion = #"{"protocolVersion":3,"messageID":"old-grant","sentAt":0,"payload":{"reloadAssets":true}}"#
        t.expectNil(IPCCoding.decodeLine(previousGrantVersion, as: AgentCommand.self), "old bundle cannot execute non-disruptive refresh")
        let previousPlaybackVersion = #"{"protocolVersion":4,"messageID":"old-playback","sentAt":0,"payload":{"healthCheck":true}}"#
        t.expectNil(IPCCoding.decodeLine(previousPlaybackVersion, as: AgentCommand.self), "old bundle cannot ignore audio-only session mode")
        let previousQueueVersion = #"{"protocolVersion":5,"messageID":"old-single","sentAt":0,"payload":{"healthCheck":true}}"#
        t.expectNil(IPCCoding.decodeLine(previousQueueVersion, as: AgentCommand.self), "old bundle cannot ignore queue continuation")
        let previousHistoryVersion = #"{"protocolVersion":6,"messageID":"old-history","sentAt":0,"payload":{"healthCheck":true}}"#
        t.expectNil(IPCCoding.decodeLine(previousHistoryVersion, as: AgentCommand.self), "old Agent must not silently ignore history recording controls")
        let previousActivityVersion = #"{"protocolVersion":7,"messageID":"old-activity","sentAt":0,"payload":{"healthCheck":true}}"#
        t.expectNil(IPCCoding.decodeLine(previousActivityVersion, as: AgentCommand.self), "old Agent must not silently ignore a daily activity entry")
        let previousOfficialOnlyVersion = #"{"protocolVersion":8,"messageID":"old-official","sentAt":0,"payload":{"healthCheck":true}}"#
        t.expectNil(IPCCoding.decodeLine(previousOfficialOnlyVersion, as: AgentCommand.self), "a v8 Agent cannot reject an extraneous local file binding")
        let previousLocalBindingVersion = #"{"protocolVersion":9,"messageID":"old-local","sentAt":0,"payload":{"healthCheck":true}}"#
        t.expectNil(IPCCoding.decodeLine(previousLocalBindingVersion, as: AgentCommand.self), "a v9 Agent cannot honor an explicit fullscreen entry request")
        let previousPictureVersion = #"{"protocolVersion":10,"messageID":"old-picture","sentAt":0,"payload":{"healthCheck":true}}"#
        t.expectNil(IPCCoding.decodeLine(previousPictureVersion, as: AgentCommand.self), "a v10 Agent cannot report or collapse picture presentation")
        let stringInNewVersion = #"{"protocolVersion":16,"messageID":"invalid","sentAt":0,"payload":{"initialize":"/tmp/old"}}"#
        t.expectNil(IPCCoding.decodeLine(stringInNewVersion, as: AgentCommand.self), "current protocol requires structured directory access")
    }

    run("IPC.olderSnapshotDoesNotRequirePendingDailyTime") { t in
        let data = Data(#"{"state":"playing","musicVolume":0,"ambientVolume":0,"visual":"full","reasons":[]}"#.utf8)
        let decoded = try? JSONDecoder().decode(RuntimeSnapshot.self, from: data)
        t.expectNotNil(decoded, "existing IPC v2 snapshot remains readable")
        t.expectNil(decoded?.pendingDailyTime, "absent optional field never invents waiting intent")
        t.expectNil(decoded?.dailyContentKeys, "an old snapshot is unknown, not a known empty catalog")
        t.expectNil(decoded?.dailyAmbientTrackCount, "missing optional ambient discovery is unknown, never zero")
        t.expectNil(decoded?.missingDailyContent, "absence never invents a resource choice failure")
        t.expectNil(decoded?.dailyAssetIssue, "legacy snapshots do not invent a directory failure")
        t.expectNil(decoded?.pendingDailyRefresh, "absence never invents a source refresh wait")
        t.expectNil(decoded?.dailyRefreshID, "absence cannot acknowledge a pending refresh")
    }

    run("IPC.garbageAndUnknownPayloadsSkipped") { t in
        t.expectNil(IPCCoding.decodeLine("not json", as: AgentCommand.self), "garbage → nil")
        let unknown = #"{"protocolVersion":16,"messageID":"x","sentAt":0,"payload":{"timeTravel":{"year":3000}}}"#
        t.expectNil(IPCCoding.decodeLine(unknown, as: AgentCommand.self), "unknown case → nil")
    }

    run("IPC.messageIDsUnique") { t in
        let a = IPCEnvelope(payload: AgentCommand.healthCheck)
        let b = IPCEnvelope(payload: AgentCommand.healthCheck)
        t.expect(a.messageID != b.messageID, "ids differ")
        t.expectEqual(a.protocolVersion, IPC.protocolVersion, "version stamped")
    }
}

func runDesiredStateTests() {
    run("DesiredState.oldDataDefaultsDailyPauseWithoutChangingOtherFields") { t in
        do {
            let current = DesiredState(scene: .a, outfit: .r3, timeMode: .fixed(.evening), musicVolume: 0.66, paused: true, profile: .coding)
            var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as! [String: Any]
            legacy.removeValue(forKey: "dailyVisualPaused")
            legacy.removeValue(forKey: "dailyMusicPaused")
            legacy.removeValue(forKey: "dailySoundtrack")
            let decoded = try JSONDecoder().decode(DesiredState.self, from: JSONSerialization.data(withJSONObject: legacy))
            var expected = current; expected.dailySoundtrack = .legacyDefault
            t.expectEqual(decoded, expected, "legacy data retains choices and requests one catalog-backed pin")
            for selection in [DailySoundtrackSelection.legacyDefault, .silent, .track(ContentID("ambient://2"))] {
                var roundtrip = current; roundtrip.dailySoundtrack = selection
                t.expectEqual(try JSONDecoder().decode(DesiredState.self, from: JSONEncoder().encode(roundtrip)), roundtrip, "soundtrack choice roundtrips without changing volumes or video")
            }
            var explicit = decoded; explicit.dailyVisualPaused = true; explicit.dailyMusicPaused = true
            t.expectEqual(try JSONDecoder().decode(DesiredState.self, from: JSONEncoder().encode(explicit)), explicit,
                          "explicit scene pause survives persistence/IPC roundtrip")
            legacy["dailyMusicPaused"] = "invalid"
            t.expect((try? JSONDecoder().decode(DesiredState.self, from: JSONSerialization.data(withJSONObject: legacy))) == nil,
                     "malformed soundtrack pause is rejected")
            legacy.removeValue(forKey: "dailyMusicPaused")
            legacy["dailyVisualPaused"] = "invalid"
            t.expect((try? JSONDecoder().decode(DesiredState.self, from: JSONSerialization.data(withJSONObject: legacy))) == nil,
                     "malformed new field is not silently discarded")
        } catch { t.expect(false, "legacy desired fixture: \(error)") }
    }

    run("DesiredState.sanitizesVolumes") { t in
        var d = DesiredState(masterVolume: 5, musicVolume: -1, ambientVolume: 2)
        d = d.sanitized()
        t.expectEqual(d.masterVolume, 1.0, "master clamped high")
        t.expectEqual(d.musicVolume, 0.0, "music clamped low")
        t.expectEqual(d.ambientVolume, 1.0, "ambient clamped high")
    }

    run("DesiredState.builtInProfiles") { t in
        t.expectEqual(Profile.builtIn.count, 5, "5 built-ins")
        t.expect(Profile.normal.musicFactor != Profile.coding.musicFactor, "profiles differ")
        t.expect(Profile.movie.visualPaused, "movie pauses visual")
        t.expectEqual(Profile.builtIn(id: "silent")?.musicFactor, 0.0, "silent lookup")
    }

    run("DesiredState.codableRoundTrip") { t in
        let original = DesiredState(scene: .c, outfit: .r2, timeMode: .fixed(.evening), profile: .coding)
        let data = try? JSONEncoder().encode(original)
        let decoded = data.flatMap { try? JSONDecoder().decode(DesiredState.self, from: $0) }
        t.expectEqual(decoded, original, "round trip")
    }
}
