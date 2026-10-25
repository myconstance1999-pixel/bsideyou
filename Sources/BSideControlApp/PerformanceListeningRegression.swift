// Real browser model and bundled metadata only: no media access, scan or player process.
import Foundation
import BSideCore
import BSidePlatform

func runPerformanceListeningRegression(expect: (Bool, String) -> Void) {
    let browser = PerformanceBrowserModel()
    var starts: [(id: String, presentation: PerformancePresentation, mode: PerformancePlaybackMode)] = []
    browser.play = { starts.append(($0, $1, $2)) }
    expect(browser.playbackMode == .watch,
           "the new browsing mode must preserve watching as the initial mode")
    browser.playbackMode = .listen
    browser.playSelection()
    expect(starts.isEmpty && browser.selectionProblem != nil,
           "listening must not dispatch from an unconfigured browser")

    do {
        let library = try PerformanceLibrary.bundled()
        guard let track = library.manifest.tracks.first(where: { track in
            track.variants.contains { $0.lighting == .daylight && $0.presentation == .sidePerformance }
                && track.variants.contains { $0.lighting == .daylight && $0.presentation == .portraitPerformance }
        }) else {
            expect(false, "listening regression needs one reviewed track with both daylight source cameras")
            return
        }
        browser.library = library
        browser.root = "/synthetic/bside-listening-regression-only"
        browser.serviceReady = true
        browser.scanned = true
        browser.desired = DesiredState(timeMode: .fixed(.noon))
        browser.selectedID = track.id
        browser.presentation = .sidePerformance
        guard let variant = browser.selection(track.id) else {
            expect(false, "the browser must resolve its exact daylight side-view source")
            return
        }
        browser.unavailable = Dictionary(uniqueKeysWithValues: library.manifest.tracks.flatMap {
            $0.variants.map { ($0.id, "synthetic missing source") }
        })
        browser.unavailable.removeValue(forKey: variant.variantID.rawValue)
        browser.onlyFound = true
        browser.playbackMode = .watch
        browser.playSelection()
        expect(starts.count == 1 && starts.first?.id == track.id
               && starts.first?.presentation == .sidePerformance && starts.first?.mode == .watch,
               "the primary watch action must dispatch the selected track, camera and mode")

        browser.playbackMode = .listen
        expect(starts.count == 1 && browser.playbackMode == .listen
               && browser.selection(track.id) == variant && browser.rows.map(\.id) == [track.id],
               "choosing listen must preserve the exact candidate and filter without starting playback")
        browser.playSelection()
        expect(starts.count == 2 && starts.last?.id == track.id
               && starts.last?.presentation == .sidePerformance && starts.last?.mode == .listen,
               "the primary listen action must dispatch the same explicit source in listen mode")

        // A known alternative camera does not repair the explicitly selected missing source.
        let otherCamera = track.variants.first {
            $0.lighting == .daylight && $0.presentation == .portraitPerformance
        }!
        browser.unavailable.removeValue(forKey: otherCamera.id)
        browser.unavailable[variant.variantID.rawValue] = "selected source is missing"
        browser.playSelection()
        expect(starts.count == 2 && browser.selectionProblem == "selected source is missing"
               && browser.rows.isEmpty && browser.selection(track.id) == variant,
               "listening must retain missing-source feedback and must not fall back to the available camera")
        browser.unavailable.removeValue(forKey: variant.variantID.rawValue)
        browser.scanFailure = "directory unavailable"
        browser.playSelection()
        expect(starts.count == 2 && browser.rows.isEmpty && browser.selectionProblem != nil,
               "a failed scan must block listening just as it blocks watching")
        browser.scanFailure = nil

        let watch = PerformanceSession(id: "browser-watch", variant: variant)
        browser.sessionState.start(watch)
        browser.report = PerformanceReport(sessionID: watch.id, state: .playing)
        expect(browser.sessionModeLabel == "观看演奏" && browser.sessionPauseActionTitle == "暂停音乐"
               && browser.sessionStopActionTitle == "停止音乐" && browser.sessionStatus == "播放中"
               && browser.playbackMode == .listen,
               "a running watch session must keep watch controls while the next selection is listen")

        let listen = PerformanceSession(id: "browser-listen", variant: variant, mode: .listen)
        browser.sessionState.start(listen)
        browser.playbackMode = .watch
        browser.presentation = .portraitPerformance
        browser.selectedID = library.manifest.tracks.first { $0.id != track.id }?.id
        expect(browser.sessionModeLabel == "只听音乐" && browser.sessionPauseActionTitle == "暂停音乐"
               && browser.sessionStopActionTitle == "停止音乐" && browser.sessionTitle == track.title
               && browser.sessionState.session == listen && browser.sessionStatus == "等待播放器确认",
               "browsing mode, camera and track must not relabel listen or accept the previous watch report")
        browser.report = PerformanceReport(sessionID: listen.id, state: .playing)
        expect(browser.sessionStatus == "播放中", "only the matching listen report confirms playback")
        _ = browser.sessionState.pause(true, sessionID: listen.id)
        browser.report = PerformanceReport(sessionID: listen.id, state: .paused)
        expect(browser.sessionPauseActionTitle == "恢复音乐" && browser.sessionStatus == "已暂停"
               && browser.sessionState.session?.variant == variant && !browser.desired.paused,
               "pausing the listen session must project a music resume action without changing daily intent")
    } catch {
        expect(false, "listening browser metadata regression failed: \(error)")
    }
}
