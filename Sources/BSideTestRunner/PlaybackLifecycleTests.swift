// BSideTestRunner — PlaybackLifecycle reducer suites (Beta Slice 4).
// These exercise the EXACT pure reducer BSidePlatform.PlaybackEngine drives in production, so the
// invariants proven here are the production-used transition/ambient logic — not a test mirror.

import Foundation
import BSideCore

func runPlaybackLifecycleTests() {
    // MARK: Visual — transition generation/token guard

    run("PlaybackLifecycle.directInstallIsImmediate") { t in
        var lc = PlaybackLifecycle()
        _ = lc.beginVisual(transition: false)
        t.expect(lc.loopInstalled, "direct target installs loop immediately")
        t.expect(!lc.transitionPending, "no pending transition")
    }

    run("PlaybackLifecycle.transitionEndsInstallExactlyOnce") { t in
        var lc = PlaybackLifecycle()
        let g = lc.beginVisual(transition: true)
        t.expect(!lc.loopInstalled, "loop not installed before transition ends")
        t.expect(lc.transitionEnded(generation: g), "first end installs the loop")
        t.expect(lc.loopInstalled, "loop now installed")
        t.expect(!lc.transitionEnded(generation: g), "duplicate end does NOT reinstall")
    }

    run("PlaybackLifecycle.staleTransitionCannotInstallOldLoop") { t in
        var lc = PlaybackLifecycle()
        let g1 = lc.beginVisual(transition: true)   // transition A starts
        let g2 = lc.beginVisual(transition: true)   // switch to B before A completes
        t.expect(!lc.transitionEnded(generation: g1), "stale A end is ignored")
        t.expect(lc.transitionPending, "B still waiting for its own transition")
        t.expect(!lc.loopInstalled, "A's loop must NOT be installed")
        t.expect(lc.transitionEnded(generation: g2), "B's end installs B's loop")
    }

    run("PlaybackLifecycle.directSwitchInvalidatesPendingTransition") { t in
        var lc = PlaybackLifecycle()
        let g1 = lc.beginVisual(transition: true)   // A transition starts
        _ = lc.beginVisual(transition: false)       // rapid switch to direct B (no transition)
        t.expect(lc.loopInstalled, "B installed immediately")
        t.expect(!lc.transitionEnded(generation: g1), "stale A end cannot resurrect A")
    }

    run("PlaybackLifecycle.rapidSwitchesOnlyCurrentGenerationInstalls") { t in
        var lc = PlaybackLifecycle()
        let g1 = lc.beginVisual(transition: true)
        let g2 = lc.beginVisual(transition: true)
        let g3 = lc.beginVisual(transition: true)
        t.expect(!lc.transitionEnded(generation: g1), "g1 stale")
        t.expect(!lc.transitionEnded(generation: g2), "g2 stale")
        t.expect(!lc.loopInstalled, "nothing installed by stale ends")
        t.expect(lc.transitionEnded(generation: g3), "only current generation installs")
    }

    run("PlaybackLifecycle.generationsAreMonotonicAndDistinct") { t in
        var lc = PlaybackLifecycle()
        let g1 = lc.beginVisual(transition: true)
        let g2 = lc.beginVisual(transition: true)
        let g3 = lc.beginVisual(transition: false)
        t.expect(g1 != g2 && g2 != g3 && g1 != g3, "tokens distinct")
        t.expect(g2 > g1 && g3 > g2, "tokens monotonic")
    }

    run("PlaybackLifecycle.teardownInvalidatesCallbacksAndAllowsAmbientRebuild") { t in
        var lc = PlaybackLifecycle()
        let stale = lc.beginVisual(transition: true)
        _ = lc.updateAmbient(urlIdentity: "ambient://1", effectiveVolume: 0.4)
        lc.reset()
        t.expect(!lc.transitionEnded(generation: stale), "pre-teardown callback is stale")
        t.expect(!lc.ambientRunning, "teardown forgets the removed ambient chain")
        t.expectEqual(lc.updateAmbient(urlIdentity: "ambient://1", effectiveVolume: 0.4), .run,
                      "same ambient URL rebuilds after teardown")
    }

    // MARK: Ambient — energy honesty + no duplicates

    run("PlaybackLifecycle.ambientStartsThenIdempotent") { t in
        var lc = PlaybackLifecycle()
        t.expectEqual(lc.updateAmbient(urlIdentity: "ambient://1", effectiveVolume: 0.4), .run, "start")
        t.expect(lc.ambientRunning, "running")
        t.expectEqual(lc.updateAmbient(urlIdentity: "ambient://1", effectiveVolume: 0.4), .none, "repeated intent is a no-op")
    }

    run("PlaybackLifecycle.zeroEffectiveVolumeStopsDecode") { t in
        var lc = PlaybackLifecycle()
        _ = lc.updateAmbient(urlIdentity: "ambient://1", effectiveVolume: 0.4)
        t.expectEqual(lc.updateAmbient(urlIdentity: "ambient://1", effectiveVolume: 0.0), .stop, "zero volume stops")
        t.expect(!lc.ambientRunning, "stopped")
        t.expectEqual(lc.updateAmbient(urlIdentity: "ambient://1", effectiveVolume: 0.0), .none, "already stopped")
    }

    run("PlaybackLifecycle.nilAssetStopsDecode") { t in
        var lc = PlaybackLifecycle()
        _ = lc.updateAmbient(urlIdentity: "ambient://1", effectiveVolume: 0.4)
        t.expectEqual(lc.updateAmbient(urlIdentity: nil, effectiveVolume: 0.4), .stop, "nil asset stops")
    }

    run("PlaybackLifecycle.resumeRestoresExactlyOneChain") { t in
        var lc = PlaybackLifecycle()
        _ = lc.updateAmbient(urlIdentity: "ambient://1", effectiveVolume: 0.4)   // run
        _ = lc.updateAmbient(urlIdentity: "ambient://1", effectiveVolume: 0.0)   // stop
        t.expectEqual(lc.updateAmbient(urlIdentity: "ambient://1", effectiveVolume: 0.4), .run, "resume rebuilds")
        t.expectEqual(lc.updateAmbient(urlIdentity: "ambient://1", effectiveVolume: 0.4), .none, "no duplicate chain")
    }

    run("PlaybackLifecycle.urlChangeWhileRunningRebuildsOnce") { t in
        var lc = PlaybackLifecycle()
        _ = lc.updateAmbient(urlIdentity: "ambient://1", effectiveVolume: 0.4)
        t.expectEqual(lc.updateAmbient(urlIdentity: "ambient://2", effectiveVolume: 0.4), .run, "url change rebuilds")
        t.expectEqual(lc.ambientURLIdentity, "ambient://2", "identity updated")
        t.expectEqual(lc.updateAmbient(urlIdentity: "ambient://2", effectiveVolume: 0.4), .none, "no further churn")
    }

    run("PlaybackLifecycle.urlChangeWhileStoppedStaysStoppedUntilPositive") { t in
        var lc = PlaybackLifecycle()
        _ = lc.updateAmbient(urlIdentity: "ambient://1", effectiveVolume: 0.0)   // never ran
        t.expectEqual(lc.updateAmbient(urlIdentity: "ambient://2", effectiveVolume: 0.0), .none, "still stopped at zero volume")
        t.expect(!lc.ambientRunning, "not running")
        t.expectEqual(lc.updateAmbient(urlIdentity: "ambient://2", effectiveVolume: 0.5), .run, "resume with new url builds once")
    }

    run("PlaybackLifecycle.explicitPauseRetainsButSourceAndSafetyRelease") { t in
        var lc = PlaybackLifecycle()
        t.expectEqual(lc.updateAmbient(urlIdentity: "a", effectiveVolume: 0.4), .run, "install")
        t.expectEqual(lc.updateAmbient(urlIdentity: "a", effectiveVolume: 0, paused: true), .pause, "pause existing chain")
        t.expect(lc.ambientRetained && !lc.ambientRunning, "pause retains resources without decoding")
        t.expectEqual(lc.updateAmbient(urlIdentity: "a", effectiveVolume: 0, paused: true), .none, "repeat pause is inert")
        t.expectEqual(lc.updateAmbient(urlIdentity: "a", effectiveVolume: 0.4), .resume, "resume same chain")
        _ = lc.updateAmbient(urlIdentity: "a", effectiveVolume: 0, paused: true)
        t.expectEqual(lc.updateAmbient(urlIdentity: "b", effectiveVolume: 0, paused: true), .stop, "source replacement releases old chain")
        t.expect(!lc.ambientRetained, "no source lease needed after release")
        t.expectEqual(lc.updateAmbient(urlIdentity: "b", effectiveVolume: 0, paused: true), .none, "new paused source is not decoded")
        t.expectEqual(lc.updateAmbient(urlIdentity: "b", effectiveVolume: 0.4), .run, "resume installs the new source once")
        _ = lc.updateAmbient(urlIdentity: "b", effectiveVolume: 0, paused: true)
        t.expectEqual(lc.updateAmbient(urlIdentity: "b", effectiveVolume: 0), .stop, "safety zero gain releases retained chain")
        _ = lc.updateAmbient(urlIdentity: "b", effectiveVolume: 0.4)
        _ = lc.updateAmbient(urlIdentity: "b", effectiveVolume: 0, paused: true)
        t.expectEqual(lc.updateAmbient(urlIdentity: nil, effectiveVolume: 0, paused: true), .stop, "invalidation releases paused chain")
    }

    // MARK: Ambient — policy composition (pause zeroes volume → decode stops)

    run("PlaybackLifecycle.policyPauseZeroesVolumeWhichStopsDecode") { t in
        let clean = RuntimeContext()
        var desired = DesiredState(dailySoundtrack: .track(ContentID("ambient://1")))
        let playing = PlaybackPolicy.evaluate(desired: desired, context: clean)
        t.expect(playing.ambientVolume > 0, "ambient audible while playing")

        var lc = PlaybackLifecycle()
        _ = lc.updateAmbient(urlIdentity: "ambient://1", effectiveVolume: playing.ambientVolume)

        desired.paused = true
        let paused = PlaybackPolicy.evaluate(desired: desired, context: clean)
        t.expectEqual(paused.ambientVolume, 0.0, "pause policy zeroes effective ambient volume")
        t.expectEqual(lc.updateAmbient(urlIdentity: "ambient://1", effectiveVolume: paused.ambientVolume), .stop,
                      "zeroed effective volume stops ambient decode")
    }
}
