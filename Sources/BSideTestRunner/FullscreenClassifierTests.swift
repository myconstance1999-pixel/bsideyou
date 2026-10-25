// BSideTestRunner — FullscreenClassifier suites (Beta Slice 5).
// These exercise the EXACT pure classifier SystemMonitors drives in production (after parsing
// CGWindowListCopyWindowInfo into candidate records), so the heuristic proven here is the
// production-used decision — not a test mirror. Documented heuristic status: unchanged from Alpha.

import Foundation
import CoreGraphics
import BSideCore
import BSidePlatform

func runFullscreenClassifierTests() {
    let screenArea = 2560.0 * 1440.0   // official 1440p desktop

    func candidate(
        layer: Int = 0,
        width: Double = 2560, height: Double = 1440,
        regularApp: Bool = true, ownProcess: Bool = false
    ) -> FullscreenCandidate {
        FullscreenCandidate(layer: layer, width: width, height: height,
                            regularApp: regularApp, ownProcess: ownProcess)
    }

    run("Fullscreen.standardGeometryDetected") { t in
        t.expect(FullscreenClassifier.detectsFullscreen(
            candidates: [candidate()], screenArea: screenArea),
            "exact screen-size layer-0 regular app")
    }

    run("Fullscreen.menuBarAndDockLayerExcluded") { t in
        // Menu bar (24) and Dock (25) live above the normal window layer and must never count.
        t.expect(!FullscreenClassifier.detectsFullscreen(
            candidates: [candidate(layer: 24)], screenArea: screenArea), "menu bar layer excluded")
        t.expect(!FullscreenClassifier.detectsFullscreen(
            candidates: [candidate(layer: 25)], screenArea: screenArea), "dock layer excluded")
    }

    run("Fullscreen.nonzeroLayerExcluded") { t in
        t.expect(!FullscreenClassifier.detectsFullscreen(
            candidates: [candidate(layer: 1)], screenArea: screenArea), "layer 1 excluded")
        t.expect(!FullscreenClassifier.detectsFullscreen(
            candidates: [candidate(layer: -1)], screenArea: screenArea), "unknown layer excluded")
    }

    run("Fullscreen.ownProcessExcluded") { t in
        t.expect(!FullscreenClassifier.detectsFullscreen(
            candidates: [candidate(ownProcess: true)], screenArea: screenArea),
            "our own window never counts")
    }

    run("Fullscreen.backgroundAccessoryOwnerExcluded") { t in
        // Accessory/background owners (not regular apps) must never count.
        t.expect(!FullscreenClassifier.detectsFullscreen(
            candidates: [candidate(regularApp: false)], screenArea: screenArea),
            "accessory/background owner excluded")
    }

    run("Fullscreen.nearFullscreenRejectedBoundaryAccepted") { t in
        // 94% coverage is a "maximized but not fullscreen" window → false positive must be rejected.
        t.expect(!FullscreenClassifier.detectsFullscreen(
            candidates: [candidate(width: 2560, height: 1353.6)], screenArea: screenArea),
            "94% coverage rejected")
        // Exactly 95% (the inclusive threshold) is accepted.
        t.expect(FullscreenClassifier.detectsFullscreen(
            candidates: [candidate(width: 2560, height: 1368.0)], screenArea: screenArea),
            "95% boundary accepted")
    }

    run("Fullscreen.emptyListNotDetected") { t in
        t.expect(!FullscreenClassifier.detectsFullscreen(candidates: [], screenArea: screenArea),
                 "empty list")
    }

    run("Fullscreen.firstMatchWinsAcrossMixedWindows") { t in
        // A tiny layer-0 accessory window first must not mask a real fullscreen window later.
        t.expect(FullscreenClassifier.detectsFullscreen(
            candidates: [candidate(width: 100, height: 100), candidate()],
            screenArea: screenArea),
            "later fullscreen window still detected")
    }

    // Exercise the actual WindowServer metadata projection, including the two-process app
    // identity, before evaluating the unchanged playback policy with audible daily channels.
    let agentPID = ProcessInfo.processInfo.processIdentifier
    let controlPID = agentPID + 1
    let foreignPID = agentPID + 2
    func window(_ pid: Int32, layer: Int = 0) -> [String: Any] {
        [kCGWindowOwnerPID as String: NSNumber(value: pid),
         kCGWindowLayer as String: NSNumber(value: layer),
         kCGWindowBounds as String: ["Width": NSNumber(value: 2560), "Height": NSNumber(value: 1440)]]
    }

    run("Fullscreen.supervisorMetadataPreservesDailyAudio") { t in
        let monitor = SystemMonitors(supervisingProcessID: controlPID)
        let desired = DesiredState(masterVolume: 0.8, musicVolume: 0.7, ambientVolume: 0.5, dailySoundtrack: .legacyDefault,
                                   pauseVisualOnFullscreen: true, muteAudioOnFullscreen: true)
        var context = RuntimeContext(homeCompanionVisible: true)
        let baseline = PlaybackPolicy.evaluate(desired: desired, context: context)
        t.expect(baseline.musicVolume > 0 && baseline.ambientVolume > 0, "fixture starts with audible daily channels")
        for windows in [[window(controlPID)], [window(agentPID)], [window(controlPID), window(agentPID)], []] {
            context.fullscreenAppActive = monitor.detectsFullscreen(windowInfo: windows, screenArea: screenArea,
                                                                    applicationIsRegular: { _ in true })
            let effective = PlaybackPolicy.evaluate(desired: desired, context: context)
            t.expect(!context.fullscreenAppActive, "ControlApp and Agent windows are both excluded, including entry and exit")
            t.expectEqual(effective.musicVolume, baseline.musicVolume, "own fullscreen retains nonzero daily music gain")
            t.expectEqual(effective.ambientVolume, baseline.ambientVolume, "own fullscreen retains nonzero ambient gain")
            t.expect(!effective.reasons.contains("fullscreen-app"), "own fullscreen cannot introduce foreign-app suppression")
        }
        context.screenLocked = true
        let locked = PlaybackPolicy.evaluate(desired: desired, context: context)
        t.expect(locked.musicVolume == 0 && locked.ambientVolume == 0, "owned-window exclusion cannot override lock safety")
    }

    run("Fullscreen.foreignMetadataPausesOnlyUnattendedPicture") { t in
        let monitor = SystemMonitors(supervisingProcessID: controlPID)
        let detected = monitor.detectsFullscreen(windowInfo: [window(controlPID), window(agentPID), window(foreignPID)],
                                                 screenArea: screenArea, applicationIsRegular: { _ in true })
        t.expect(detected, "excluded own windows cannot mask an unrelated fullscreen owner")
        let desired = DesiredState(dailySoundtrack: .track(ContentID("ambient://1")), muteAudioOnFullscreen: true)
        for homeVisible in [false, true] {
            let context = RuntimeContext(homeCompanionVisible: homeVisible, fullscreenAppActive: detected)
            let effective = PlaybackPolicy.evaluate(desired: desired, context: context)
            t.expect(effective.musicVolume > 0 && effective.ambientVolume > 0,
                     "foreign fullscreen metadata preserves independent companion audio despite the legacy mute preference")
            t.expectEqual(effective.visual, homeVisible ? .full : .paused,
                          "foreign fullscreen still pauses the unattended daily picture")
            t.expectEqual(effective.reasons.contains("fullscreen-app"), !homeVisible,
                          "fullscreen reason describes only the actual picture restriction")
        }
        t.expect(!monitor.detectsFullscreen(windowInfo: [window(foreignPID)], screenArea: screenArea,
                                           applicationIsRegular: { _ in nil }), "unknown process ownership remains excluded")
    }

    run("Fullscreen.absentSupervisorDoesNotExcludeAnotherApp") { t in
        let absentSupervisors: [Int32?] = [nil, 1]
        for supervisor in absentSupervisors {
            let monitor = SystemMonitors(supervisingProcessID: supervisor)
            t.expect(monitor.detectsFullscreen(windowInfo: [window(controlPID)], screenArea: screenArea,
                                               applicationIsRegular: { _ in true }),
                     "without a valid supervised launch there is no additional application exemption")
        }
    }
}
