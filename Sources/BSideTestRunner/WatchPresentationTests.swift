// Hidden/on-demand song presentation: reducer failures and real media identity continuity.
// Fake windows never order a native surface front; generated fixtures contain no user media.
import AppKit
import AVFoundation
import Foundation
import BSideCore
import BSidePlatform

private final class FakeWatchWindow: WatchPresentingWindow {
    let watchContentLayer = CALayer()
    private(set) weak var hostedLayer: CALayer?
    private(set) var fullScreen = false
    private(set) var desktopPresentation = false
    private(set) var showCount = 0
    private(set) var showDesktopCount = 0
    private(set) var enterCount = 0
    private(set) var exitCount = 0
    private(set) var hideCount = 0
    private(set) var retireCount = 0
    private(set) var desktopApplyCount = 0
    private(set) var prepareFullScreenCount = 0
    /// True when every recorded show/native enter was preceded by a `prepareWatchForFullScreenEntry`.
    /// A stale desktop rendition must have been restored to the ordinary shell before the window is
    /// shown or asked to enter native fullscreen; the flag only goes false when a show/enter arrives
    /// without a preceding prepare.
    private(set) var preparePrecededShowAndEnter = true
    private(set) var lastTitle: String?
    private(set) var attachCount = 0
    private(set) var detachCount = 0
    /// Ephemeral ordering flag: set by a prepare and cleared only by an explicit desktop-shell
    /// change, so the recorded order mirrors the real seam (`prepare` covers the following show +
    /// native enter; a show/enter without that prepare marks the order broken).
    private var shellReadyForNativeEntry = false

    var isWatchFullScreen: Bool { fullScreen }
    var isWatchDesktopPresentation: Bool { desktopPresentation }
    func setWatchTitle(_ title: String) { lastTitle = title }

    func attachWatchLayer(_ layer: CALayer) {
        layer.removeFromSuperlayer()
        layer.frame = watchContentLayer.bounds
        watchContentLayer.addSublayer(layer)
        hostedLayer = layer
        attachCount += 1
    }

    func detachWatchLayer() {
        hostedLayer?.removeFromSuperlayer()
        hostedLayer = nil
        detachCount += 1
    }

    func showWatchWindow() {
        showCount += 1
        if !shellReadyForNativeEntry { preparePrecededShowAndEnter = false }
    }
    func showWatchDesktopWindow() { showDesktopCount += 1 }
    func enterWatchFullScreen() {
        enterCount += 1
        if !shellReadyForNativeEntry { preparePrecededShowAndEnter = false }
    }
    func exitWatchFullScreen() { exitCount += 1 }
    func hideWatchWindow() { hideCount += 1 }

    func applyWatchDesktopPresentation() {
        desktopApplyCount += 1
        desktopPresentation = true
        fullScreen = false
        shellReadyForNativeEntry = false
    }

    func prepareWatchForFullScreenEntry() {
        prepareFullScreenCount += 1
        desktopPresentation = false
        // Stays set through the following show/enter: one restore covers both.
        shellReadyForNativeEntry = true
    }

    /// A retired window is gone: it can no longer report fullscreen and is never reused.
    func retireWatchWindow() { retireCount += 1; fullScreen = false; desktopPresentation = false }

    /// Simulate AppKit completing the requested transition before the delegate callback.
    func completeEnter() { fullScreen = true; desktopPresentation = false }
    func completeExit() { fullScreen = false }
    /// Simulate AppKit refusing/cancelling the exit: the style mask stays fullscreen.
    func failExit() { fullScreen = true; desktopPresentation = false }
}

// MARK: - Fake daily host that really parents the engine layer

private final class LayerTrackingDailyHost: DesktopHost {
    let strategyName = "test-daily"
    let contentLayer = CALayer()
    private(set) var isInstalled = false
    private(set) var visibility: Bool?
    var onVisibilityChanged: ((Bool?) -> Void)?
    private(set) var installCount = 0
    private(set) var teardownCount = 0

    func install(layer: CALayer) {
        installCount += 1
        isInstalled = true
        layer.removeFromSuperlayer()
        layer.frame = contentLayer.bounds
        contentLayer.addSublayer(layer)
    }

    func show() {}
    func teardown() { teardownCount += 1; isInstalled = false }
    func reassert() {}
}

private func fakeWindowEnter(_ host: WatchPresentationHost, _ window: FakeWatchWindow) {
    window.completeEnter()
    host.windowDidEnterFullScreen(Notification(name: NSWindow.didEnterFullScreenNotification, object: window))
}

private func fakeWindowExit(_ host: WatchPresentationHost, _ window: FakeWatchWindow) {
    window.completeExit()
    host.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: window))
}

func runWatchPresentationTests() {
    run("Watch.unopenedLegacyAutomaticRequestStaysHidden") { t in
        var state = WatchPresentation()
        state.adoptSession("a")
        t.expectEqual(state.mediaBecameReady(sessionID: "a", eligible: true,
            automaticallyEnterFullScreen: true), .none, "legacy automatic flag cannot open video")
        t.expect(!state.ownsLayer, "ready hidden song owns no window layer")
        t.expectEqual(state.reconcileEligibility(sessionID: "a", eligible: true), .none,
                      "wake and policy reevaluation cannot open video")
        t.expectEqual(state.explicitFullScreenRequested(), .enterFullScreen, "explicit request opens")
        t.expectEqual(state.explicitFullScreenRequested(), .none, "duplicate enter is inert")
    }
    run("Watch.readinessAndStaleSessionAdmission") { t in
        var state = WatchPresentation()
        state.adoptSession("a")
        t.expectEqual(state.explicitFullScreenRequested(), .none, "unready request cannot queue surprise entry")
        state.adoptSession("b")
        t.expectEqual(state.mediaBecameReady(sessionID: "a", eligible: true), .none, "old readiness ignored")
        t.expectEqual(state.explicitFullScreenRequested(), .none, "stale ready did not admit current item")
        _ = state.mediaBecameReady(sessionID: "b", eligible: false)
        t.expectEqual(state.explicitFullScreenRequested(), .none, "locked request does not show")
        t.expectEqual(state.reconcileEligibility(sessionID: "b", eligible: true), .enterFullScreen,
                      "an explicit accepted request can finish after eligibility returns")
    }
    run("Watch.closeDuringEntryAndQueueLatch") { t in
        var state = WatchPresentation()
        state.adoptSession("a")
        _ = state.mediaBecameReady(sessionID: "a", eligible: true)
        _ = state.explicitFullScreenRequested()
        t.expectEqual(state.closeRequested(), .none, "close waits for native entry")
        t.expectEqual(state.didEnterFullScreen(), .returnToDesktop, "entry lands then requests exit")
        t.expectEqual(state.didExitFullScreen(programmatic: false), .orderOut, "close hides layer")
        state.adoptSession("b")
        t.expectEqual(state.mediaBecameReady(sessionID: "b", eligible: true), .none,
                      "closed queue remains hidden")
        t.expect(!state.ownsLayer, "queue successor has no desktop song surface")
    }
    run("Watch.openQueueSuccessorRetainsWindowAndRejectsOldStop") { t in
        var state = WatchPresentation()
        state.adoptSession("a")
        _ = state.mediaBecameReady(sessionID: "a", eligible: true)
        _ = state.explicitFullScreenRequested(); _ = state.didEnterFullScreen()
        state.adoptSession("b")
        t.expectEqual(state.endRun(sessionID: "a"), .none, "stale stop cannot close successor")
        t.expectEqual(state.mediaBecameReady(sessionID: "b", eligible: true), .none, "no repeated enter")
        t.expect(state.ownsLayer && state.isFullScreen, "explicit open run stays open")
    }
    run("Watch.endDuringEntryAndNewSessionDuringExit") { t in
        var state = WatchPresentation()
        state.adoptSession("a"); _ = state.mediaBecameReady(sessionID: "a", eligible: true)
        _ = state.explicitFullScreenRequested()
        t.expectEqual(state.endRun(sessionID: "a"), .none, "end waits for native callback")
        t.expect(!state.ownsLayer, "end releases media immediately")
        state.adoptSession("b"); _ = state.mediaBecameReady(sessionID: "b", eligible: true)
        t.expectEqual(state.didEnterFullScreen(), .exitFullScreen, "obsolete entry is exited")
        t.expectEqual(state.didExitFullScreen(programmatic: true), .orderOut, "obsolete window hides")
        t.expectEqual(state.sessionID, "b", "new ready song survives old exit")
        t.expectEqual(state.explicitFullScreenRequested(), .enterFullScreen, "new song opens only explicitly")
    }
    run("Watch.failureAndShutdownConvergeWithoutRetry") { t in
        var state = WatchPresentation()
        state.adoptSession("a"); _ = state.mediaBecameReady(sessionID: "a", eligible: true)
        _ = state.explicitFullScreenRequested()
        t.expectEqual(state.didFailToEnterFullScreen(), .orderOut, "failed entry hides")
        t.expectEqual(state.reconcileEligibility(sessionID: "a", eligible: true), .none, "no retry loop")
        _ = state.explicitFullScreenRequested(); _ = state.didEnterFullScreen()
        _ = state.closeRequested()
        t.expectEqual(state.didFailToExitFullScreen(isFullScreen: true), .none, "actual fullscreen stays honest")
        t.expect(state.isFullScreen && state.ownsLayer, "failed close remains retryable")
        t.expectEqual(state.shutdown(), .orderOut, "shutdown hides immediately")
        t.expectEqual(state.didEnterFullScreen(), .none, "late entry is inert")
        t.expectEqual(state.mediaBecameReady(sessionID: "a", eligible: true), .none, "late readiness cannot revive")
    }
    run("WatchHost.hiddenAndExplicitLayersKeepDailyParent") { t in
        let dailyLayer = CALayer(), songLayer = CALayer()
        let daily = LayerTrackingDailyHost(); daily.install(layer: dailyLayer)
        let window = FakeWatchWindow()
        let host = WatchPresentationHost(makeWindow: { window })
        defer { host.teardown() }
        host.adoptSession("a")
        host.mediaBecameReady(sessionID: "a", layer: songLayer, eligible: true)
        t.expectEqual(window.showCount, 0, "ready never shows")
        t.expectEqual(host.presentationReport?.state, .collapsed, "ready hidden source is reported")
        host.enterFullScreenExplicitly()
        t.expect(songLayer.superlayer === window.watchContentLayer, "only song layer is attached")
        t.expect(dailyLayer.superlayer === daily.contentLayer, "daily layer never moves")
        fakeWindowEnter(host, window)
        t.expectEqual(host.presentationReport?.state, .expanded, "actual callback confirms expanded")
        host.exitFullScreenExplicitly(); fakeWindowExit(host, window)
        t.expectNil(songLayer.superlayer, "closing detaches song layer")
        t.expect(dailyLayer.superlayer === daily.contentLayer, "daily still installed")
        t.expectEqual(window.showDesktopCount, 0, "song is never shown on desktop")
        t.expectEqual(host.presentationReport?.state, .collapsed, "actual exit confirms collapsed")
        host.adoptSession("b"); host.mediaBecameReady(sessionID: "b", layer: songLayer, eligible: true)
        t.expectEqual(window.showCount, 1, "hidden successor does not reopen")
    }
    run("WatchHost.closeDuringEnterAndNativeEscape") { t in
        let window = FakeWatchWindow()
        let actual = WatchPresentationHost(makeWindow: { window })
        defer { actual.teardown() }
        actual.adoptSession("a"); actual.mediaBecameReady(sessionID: "a", layer: CALayer(), eligible: true)
        actual.enterFullScreenExplicitly(); actual.exitFullScreenExplicitly()
        t.expectEqual(window.exitCount, 0, "close is deferred during entry")
        fakeWindowEnter(actual, window)
        t.expectEqual(window.exitCount, 1, "close completes through one native exit")
        fakeWindowExit(actual, window)
        actual.enterFullScreenExplicitly(); fakeWindowEnter(actual, window)
        fakeWindowExit(actual, window)
        t.expectEqual(actual.presentationReport?.state, .collapsed, "native Esc hides without media command")
        t.expectNil(window.hostedLayer, "native exit releases presentation only")
    }
    run("WatchHost.failedEndingExitRetiresAndRejectsOldWindowCallbacks") { t in
        let first = FakeWatchWindow(), second = FakeWatchWindow()
        var windows = [first, second]
        let host = WatchPresentationHost(makeWindow: { windows.removeFirst() })
        defer { host.teardown() }
        host.adoptSession("a"); host.mediaBecameReady(sessionID: "a", layer: CALayer(), eligible: true)
        host.enterFullScreenExplicitly(); fakeWindowEnter(host, first)
        host.endRun(sessionID: "a"); first.failExit(); host.exitFullScreenFailed()
        t.expectEqual(first.retireCount, 1, "failed obsolete fullscreen is retired")
        host.adoptSession("b"); host.mediaBecameReady(sessionID: "b", layer: CALayer(), eligible: true)
        host.enterFullScreenExplicitly(); fakeWindowEnter(host, second)
        fakeWindowExit(host, first)
        host.videoContentDoubleClicked(from: first)
        t.expectEqual(host.presentationReport?.state, .expanded, "old callbacks cannot close new window")
        t.expectEqual(second.exitCount, 0, "old gesture issues no new exit")
    }
    run("WatchHost.independentDailyAndSongKeepRealItemClockAcrossPresentation") { t in
        do {
            let dailyURL = try makeTinyVideo(seconds: 5), songURL = try makeTinyVideo(seconds: 5)
            defer { try? FileManager.default.removeItem(at: dailyURL); try? FileManager.default.removeItem(at: songURL) }
            let daily = PlaybackEngine(), song = PlaybackEngine()
            defer { daily.teardown(); song.teardown() }
            let window = FakeWatchWindow(), layerHost = LayerTrackingDailyHost()
            let host = WatchPresentationHost(makeWindow: { window })
            defer { host.teardown() }
            layerHost.install(layer: daily.videoLayer)
            var frameReady = false
            daily.playOnce(url: dailyURL, onReady: {}, completion: { _ in })
            song.playOnce(url: songURL, onReady: {}, onSourceFrameReady: { frameReady = true }, completion: { _ in })
            let deadline = Date().addingTimeInterval(4)
            while (!frameReady || song.videoObservationPlayer.currentTime().seconds < 0.2) && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            t.expect(frameReady, "hidden source yields a real frame without a composed layer")
            let player = song.videoObservationPlayer
            guard let item = player.currentItem, let dailyItem = daily.videoObservationPlayer.currentItem else {
                return t.expect(false, "both independent sources installed")
            }
            let before = player.currentTime().seconds
            host.adoptSession("song"); host.mediaBecameReady(sessionID: "song", layer: song.videoLayer, eligible: true)
            host.enterFullScreenExplicitly(); fakeWindowEnter(host, window)
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            host.exitFullScreenExplicitly(); fakeWindowExit(host, window)
            t.expect(player.currentItem === item, "show/hide preserves exact song item")
            t.expect(player.currentTime().seconds >= before, "song clock does not restart")
            t.expect(daily.videoObservationPlayer.currentItem === dailyItem, "picture action preserves daily item")
            song.setVisualPaused(true)
            let paused = player.currentTime().seconds
            host.enterFullScreenExplicitly(); fakeWindowEnter(host, window)
            host.exitFullScreenExplicitly(); fakeWindowExit(host, window)
            t.expect(song.visualPaused && player.rate == 0, "picture preserves explicit pause")
            t.expectNear(player.currentTime().seconds, paused, "paused clock remains unchanged", eps: 0.02)
            daily.stopVideo(); daily.playOnce(url: songURL, onReady: {}, completion: { _ in })
            t.expect(player.currentItem === item, "daily scene replacement cannot replace song")
            song.stopVideo()
            t.expect(daily.hasVideoResources, "song stop leaves daily installed")
        } catch { t.expect(false, "fixture error: \(error)") }
    }
}
