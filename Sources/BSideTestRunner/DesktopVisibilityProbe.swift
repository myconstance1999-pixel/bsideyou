// Opt-in WindowServer integration fixture, never part of the unattended unit gate.
// Creates/changes only its own windows. No screenshots, input automation or other-app queries.
import AppKit
import AVFoundation
import BSideCore
import BSidePlatform

private final class VisibilityCover: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

func runDesktopVisibilityProbe() -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let fallback = CommandLine.arguments.contains("--fallback")
    let host: DesktopHost = fallback ? FallbackWindowHost() : StableDesktopPanelHost()
    let arguments = CommandLine.arguments
    var mediaURL: URL?
    if let index = arguments.firstIndex(of: "--daily-root"), index + 1 < arguments.count {
        do {
            let bundle = try OfficialAssetProvider(assetPath: arguments[index + 1]).loadCatalog()
            let selection = ContentResolver.resolve(currentKey: nil, desired: DesiredState(), catalog: bundle.catalog,
                                                    minuteOfDay: 720)
            mediaURL = selection.loop.flatMap { bundle.url(for: $0) }
            guard mediaURL != nil else { exit(2) }
        } catch { fputs("visibility probe could not resolve the supplied daily source\n", stderr); exit(2) }
    }
    let engine = mediaURL == nil ? nil : PlaybackEngine()
    let layer: CALayer = engine?.videoLayer ?? CALayer()
    layer.backgroundColor = NSColor.darkGray.cgColor
    var events: [[String: Any]] = []
    var samples: [[String: Any]] = []
    let started = ProcessInfo.processInfo.systemUptime
    let monitors = SystemMonitors(fullscreenDetector: { false })
    var desired = DesiredState()
    desired.pauseVisualOnFullscreen = false
    desired.muteAudioOnFullscreen = false
    monitors.start()
    if let engine, let mediaURL {
        monitors.onContextChanged = {
            let paused = PlaybackPolicy.evaluate(desired: desired, context: monitors.snapshot()).visual == .paused
            engine.setVisualPaused(paused)
            if !paused && !engine.hasVideoResources { engine.play(transitionURL: nil, loopURL: mediaURL) }
        }
        engine.play(transitionURL: nil, loopURL: mediaURL)
    }
    host.onVisibilityChanged = { visible in
        events.append(["elapsed": ProcessInfo.processInfo.systemUptime - started,
                       "visible": visible.map { $0 as Any } ?? NSNull()])
        monitors.setDesktopVisible(visible)
    }

    // A hard independent deadline bounds this opt-in native fixture even if AppKit stalls.
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 55) {
        fputs("visibility probe exceeded 55 second deadline\n", stderr)
        exit(2)
    }
    DispatchQueue.main.async {
        let keyWindowBeforeShow = app.keyWindow
        let mainWindowBeforeShow = app.mainWindow
        let applicationActiveBeforeShow = app.isActive
        host.install(layer: layer)
        host.show()
        guard let window = app.windows.first(where: { $0.contentView?.layer?.sublayers?.contains(layer) == true }) else {
            fputs("visibility probe could not locate its own presentation window\n", stderr)
            exit(2)
        }
        func hasExpectedWindowStructure(_ candidate: NSWindow) -> Bool {
            guard candidate.canBecomeKey == fallback, candidate.canBecomeMain == fallback else { return false }
            if fallback {
                return candidate.title == "bsideyou 壁纸预览" &&
                    candidate.accessibilityIdentifier() == "BSideMac.wallpaper-preview"
            }
            return true
        }
        // Own-window structure only. A preview may accept a later user click but show() itself
        // must leave key/main/application activation unchanged; the desktop can never take focus.
        let initialWindowStructure = hasExpectedWindowStructure(window)
        let showPreservedFocus = app.keyWindow === keyWindowBeforeShow &&
            app.mainWindow === mainWindowBeforeShow && app.isActive == applicationActiveBeforeShow &&
            !window.isKeyWindow && !window.isMainWindow
        let originalFrame = window.frame
        func makeCover(frame: NSRect) -> NSWindow {
            let cover = VisibilityCover(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            // Fixture level is relative to its OWN host. Desktop coverage stays behind ordinary
            // application windows, and never activates or intercepts the user's mouse.
            cover.level = NSWindow.Level(rawValue: window.level.rawValue + 1)
            cover.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            cover.backgroundColor = .darkGray
            cover.isOpaque = true
            cover.hasShadow = false
            cover.ignoresMouseEvents = true
            cover.isReleasedWhenClosed = false
            cover.animationBehavior = .none
            return cover
        }
        let cover = makeCover(frame: originalFrame)
        let secondCover = makeCover(frame: originalFrame)
        func sample(_ phase: String, expected: Bool) {
            let context = monitors.snapshot()
            let policy = PlaybackPolicy.evaluate(desired: desired, context: context)
            samples.append(["phase": phase, "elapsed": ProcessInfo.processInfo.systemUptime - started,
                "expected_visible": expected, "visible": host.visibility.map { $0 as Any } ?? NSNull(),
                "ordered": window.isVisible, "raw_visible": window.occlusionState.contains(.visible),
                "context_visible": context.desktopVisible, "visual_policy": policy.visual.rawValue,
                "pass": host.visibility == expected && context.desktopVisible == expected &&
                    (policy.visual == .full) == expected])
        }
        Task { @MainActor in
            func settle() async { try? await Task.sleep(nanoseconds: 1_200_000_000) }
            await settle()
            if engine != nil { try? await Task.sleep(nanoseconds: 4_000_000_000) }
            sample("uncovered", expected: true)
            cover.orderFrontRegardless()
            await settle()
            sample("fully_covered", expected: false)
            cover.setFrame(NSRect(x: originalFrame.midX, y: originalFrame.minY,
                                  width: originalFrame.width / 2, height: originalFrame.height), display: true)
            await settle()
            sample("partly_covered", expected: true)
            cover.orderOut(nil)
            await settle()
            sample("uncovered_again", expected: true)
            cover.setFrame(NSRect(x: originalFrame.minX, y: originalFrame.minY,
                                  width: originalFrame.width / 2 + 1, height: originalFrame.height), display: true)
            secondCover.setFrame(NSRect(x: originalFrame.midX, y: originalFrame.minY,
                                       width: originalFrame.width / 2 + 1, height: originalFrame.height), display: true)
            cover.orderFrontRegardless()
            secondCover.orderFrontRegardless()
            await settle()
            sample("two_windows_cover", expected: false)
            let stableStart = events.count
            host.reassert()
            await settle()
            sample("covered_after_reassert", expected: false)
            // Replacing media content must not uncover/reorder an opaque host window.
            var releasedRealVideo = engine == nil
            if let engine {
                releasedRealVideo = await withCheckedContinuation { continuation in
                    engine.releasePausedDaily { continuation.resume(returning: $0) }
                }
                releasedRealVideo = releasedRealVideo && engine.hasRetainedFrame && !engine.hasVideoResources &&
                    engine.videoLayer.player == nil
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            } else {
                layer.sublayers = [CALayer()]
            }
            await settle()
            sample("covered_after_content_change", expected: false)
            let stableCovered = events.dropFirst(stableStart).allSatisfy { $0["visible"] as? Bool == false }
            cover.orderOut(nil)
            secondCover.orderOut(nil)
            await settle()
            sample("finally_uncovered", expected: true)
            let realPlaybackRestored = engine.map { $0.hasVideoResources && $0.videoLayer.player?.rate == 1 } ?? true
            host.teardown()
            await settle()
            let detached = host.visibility == nil && !window.isVisible
            // Starting while a cover already exists checks the no-initial-visible-event case.
            cover.setFrame(originalFrame, display: true)
            cover.orderFrontRegardless()
            host.install(layer: layer)
            host.show()
            // An old delegate callback cannot overwrite the fresh host, even before delivery.
            if let delegate = host as? NSWindowDelegate {
                delegate.windowDidChangeOcclusionState?(Notification(name: NSWindow.didChangeOcclusionStateNotification,
                                                                     object: window))
            }
            await settle()
            let newWindow = app.windows.first(where: { $0.contentView?.layer?.sublayers?.contains(layer) == true && $0 !== window })
            let reinstalledWindowStructure = newWindow.map { hasExpectedWindowStructure($0) } ?? false
            let coldCovered = host.visibility == false && !monitors.snapshot().desktopVisible &&
                PlaybackPolicy.evaluate(desired: desired, context: monitors.snapshot()).visual == .paused && newWindow != nil
            cover.orderOut(nil)
            await settle()
            let coldRevealed = host.visibility == true
            host.onVisibilityChanged = nil
            host.teardown()
            monitors.stop()
            engine?.teardown()
            let passed = samples.allSatisfy { $0["pass"] as? Bool == true } && detached && coldCovered && coldRevealed && stableCovered && releasedRealVideo && realPlaybackRestored && initialWindowStructure && reinstalledWindowStructure && showPreservedFocus
            let report: [String: Any] = ["strategy": host.strategyName, "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "samples": samples, "events": events, "teardown_unknown": detached,
                "cold_covered": coldCovered, "cold_revealed": coldRevealed, "passed": passed,
                "covered_without_feedback": stableCovered,
                "real_video_tested": engine != nil, "real_video_released": releasedRealVideo,
                "real_video_restored": realPlaybackRestored,
                "initial_window_structure": initialWindowStructure,
                "reinstalled_window_structure": reinstalledWindowStructure,
                "show_preserved_focus": showPreservedFocus,
                "limits": "One current screen/Space, owned opaque rectangular covers. Native occlusion evidence; not visual image or energy acceptance."]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
               let text = String(data: data, encoding: .utf8) { print(text) }
            exit(passed ? 0 : 1)
        }
    }
    app.run()
    exit(2)
}

/// A bounded external cover for the full ControlApp/Agent benchmark. Only this fixture's window
/// is manipulated. Its desktop-relative level keeps ordinary app windows and user input intact.
func runDesktopCoverFixture() -> Never {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: "--duration"), index + 1 < arguments.count,
          let duration = Double(arguments[index + 1]), duration.isFinite, (1...120).contains(duration) else {
        fputs("--cover-desktop-only requires --duration 1...120 seconds\n", stderr)
        exit(2)
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    // The measurement controller must deliver its requested boundary on time. This bounded
    // activity belongs ONLY to the synthetic cover process, never to ControlApp or Agent.
    let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                        reason: "Bounded desktop occlusion measurement fixture")
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + duration + 10) { exit(2) }
    DispatchQueue.main.async {
        guard let screen = NSScreen.main else { exit(2) }
        let fallback = arguments.contains("--fallback")
        let frame = fallback ? NSRect(x: 64, y: 64, width: 960, height: 540) : screen.frame
        let cover = VisibilityCover(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        let targetLevel = fallback ? NSWindow.Level.floating.rawValue : Int(CGWindowLevelForKey(.desktopWindow))
        cover.level = NSWindow.Level(rawValue: targetLevel + 1)
        cover.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        cover.backgroundColor = .darkGray
        cover.isOpaque = true
        cover.hasShadow = false
        cover.ignoresMouseEvents = true
        cover.isReleasedWhenClosed = false
        cover.animationBehavior = .none
        cover.orderFrontRegardless()
        let covered = Date()
        let started = ProcessInfo.processInfo.systemUptime
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            cover.orderOut(nil)
            let requested = Date()
            let requestedUptime = ProcessInfo.processInfo.systemUptime
            app.updateWindows()
            CATransaction.flush()
            // Allow AppKit to finish ordering out before process teardown. A single query of
            // this fixture's own window confirms the WindowServer boundary; no window polling.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                let ownInfo = CGWindowListCopyWindowInfo(.optionIncludingWindow,
                    CGWindowID(cover.windowNumber)) as? [[String: Any]]
                let absent = ownInfo?.isEmpty == true || ownInfo?.first?[kCGWindowIsOnscreen as String] as? Bool == false
                let confirmed = Date()
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let report: [String: Any] = ["covered_utc": formatter.string(from: covered),
                    "uncovered_utc": formatter.string(from: requested),
                    "uncover_confirmed_utc": formatter.string(from: confirmed),
                    "window_server_confirmed_absent": absent,
                    "duration_elapsed_seconds": requestedUptime - started,
                    "total_elapsed_seconds": ProcessInfo.processInfo.systemUptime - started,
                    "fixture_only_activity": true,
                    "presentation_mode": fallback ? "preview" : "desktop",
                    "limits": "Owned opaque cover above the target layer; does not exercise real Spaces or other displays."]
                if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
                   let text = String(data: data, encoding: .utf8) { print(text) }
                ProcessInfo.processInfo.endActivity(activity)
                exit(absent ? 0 : 1)
            }
        }
    }
    app.run()
    exit(2)
}
