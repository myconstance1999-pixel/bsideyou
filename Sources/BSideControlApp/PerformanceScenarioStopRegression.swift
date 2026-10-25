// Scenario-seam deferred-stop regression: synthetic sessions/reports only. No app launch,
// no directory scan, no media, no timers, no IPC. It proves the opt-in stop gate added for
// the coalesced play/stop schedule while leaving the legacy immediate stop unchanged.
import Foundation
import BSideCore

func runPerformanceScenarioStopRegression(expect: (Bool, String) -> Void) {
    func variant(_ id: String) -> ResolvedPerformanceVariant {
        ResolvedPerformanceVariant(
            performanceID: PerformanceID("regression-track"),
            variantID: PerformanceVariantID(id),
            lighting: .sunset,
            presentation: .sidePerformance,
            catalogRevision: PerformanceCatalogRevision("regression-revision"),
            reason: .explicitUserPreference)
    }
    func session(_ id: String) -> PerformanceSession {
        PerformanceSession(id: id, variant: variant("regression-\(id)"))
    }

    // 1. A coalesced play/stop schedule: the opted-in stop is requested while the new
    //    session is still loading, so the current accepted projection is that synthetic
    //    loading state (not playing). It must not run until that exact session's own
    //    accepted playing report arrives, and then exactly once.
    let coalesced = PerformanceScenarioStopController()
    var stops: [String] = []
    let deferred = coalesced.handleStop(
        waitFor: "playing", sessionID: "session-a",
        currentReport: PerformanceReport(sessionID: "session-a", state: .loading),
        immediateStop: { stops.append("session-a") })
    expect(deferred && coalesced.isPending && coalesced.waitingSessionID == "session-a",
           "an opted-in stop must be deferred and bound to the session active at request time")
    expect(stops.isEmpty, "a coalesced stop must not run before the matching playing report")
    expect(!coalesced.receive(PerformanceReport(sessionID: "session-a", state: .loading))
           && coalesced.isPending,
           "the target's loading report must keep the deferred stop pending")
    expect(!coalesced.receive(PerformanceReport(sessionID: "session-a", state: .paused))
           && coalesced.isPending,
           "a paused report must not fire the deferred stop")
    expect(!coalesced.receive(PerformanceReport(sessionID: "session-b", state: .playing))
           && coalesced.isPending,
           "a stale unrelated session's playing report must not fire or clear the pending stop")
    expect(coalesced.receive(PerformanceReport(sessionID: "session-a", state: .playing))
           && stops == ["session-a"] && !coalesced.isPending,
           "the matching session's accepted playing report must fire the deferred stop exactly once")
    expect(!coalesced.receive(PerformanceReport(sessionID: "session-a", state: .playing))
           && stops == ["session-a"],
           "a later duplicate playing report must not fire the stop again")

    // 2. The normal (non-coalesced) schedule: the stop arrives after the matching session
    //    has already emitted its accepted playing report. That current accepted state is
    //    itself the proof, so the stop must run immediately and exactly once instead of
    //    arming a future report that may never come.
    let alreadyPlaying = PerformanceScenarioStopController()
    var alreadyStops = 0
    let alreadyDeferred = alreadyPlaying.handleStop(
        waitFor: "playing", sessionID: "session-ready",
        currentReport: PerformanceReport(sessionID: "session-ready", state: .playing),
        immediateStop: { alreadyStops += 1 })
    expect(!alreadyDeferred && alreadyStops == 1 && !alreadyPlaying.isPending,
           "a stop for an exact session already in accepted playing must run immediately, once")
    expect(!alreadyPlaying.receive(PerformanceReport(sessionID: "session-ready", state: .playing))
           && alreadyStops == 1,
           "an immediate already-playing stop must not also fire on a later duplicate report")

    // A stale current report for another session must not be mistaken for the active
    // session's playing state: the stop still waits for the live session's own report.
    let staleCurrent = PerformanceScenarioStopController()
    var staleCurrentStops = 0
    let staleCurrentDeferred = staleCurrent.handleStop(
        waitFor: "playing", sessionID: "session-live",
        currentReport: PerformanceReport(sessionID: "session-old", state: .playing),
        immediateStop: { staleCurrentStops += 1 })
    expect(staleCurrentDeferred && staleCurrent.isPending && staleCurrentStops == 0,
           "a stale unrelated report must not satisfy the wait or fire the stop")
    expect(staleCurrent.receive(PerformanceReport(sessionID: "session-live", state: .playing))
           && staleCurrentStops == 1,
           "the live session's own later playing report must still drive the deferred stop")

    // The synthetic loading projection carries the right session id but is not playing.
    let loadingCurrent = PerformanceScenarioStopController()
    var loadingCurrentStops = 0
    let loadingCurrentDeferred = loadingCurrent.handleStop(
        waitFor: "playing", sessionID: "session-loading",
        currentReport: PerformanceReport(sessionID: "session-loading", state: .loading),
        immediateStop: { loadingCurrentStops += 1 })
    expect(loadingCurrentDeferred && loadingCurrent.isPending && loadingCurrentStops == 0,
           "a same-session loading projection must not be accepted as already playing")
    expect(loadingCurrent.receive(PerformanceReport(sessionID: "session-loading", state: .playing))
           && loadingCurrentStops == 1,
           "the same session's later accepted playing report must fire the deferred stop")

    // Paused is likewise not playing.
    let pausedCurrent = PerformanceScenarioStopController()
    var pausedCurrentStops = 0
    let pausedCurrentDeferred = pausedCurrent.handleStop(
        waitFor: "playing", sessionID: "session-paused",
        currentReport: PerformanceReport(sessionID: "session-paused", state: .paused),
        immediateStop: { pausedCurrentStops += 1 })
    expect(pausedCurrentDeferred && pausedCurrent.isPending && pausedCurrentStops == 0,
           "a same-session paused report must not be accepted as already playing")

    // 3. Failure, natural completion and an explicit stop all remove the pending action so
    //    it can never fire later.
    for terminal in [PerformanceReport.State.failed, .ended, .stopped] {
        let controller = PerformanceScenarioStopController()
        var fired = 0
        _ = controller.handleStop(waitFor: "playing", sessionID: "session-t",
                                  immediateStop: { fired += 1 })
        expect(!controller.receive(PerformanceReport(sessionID: "session-t", state: terminal))
               && !controller.isPending && fired == 0,
               "a terminal \(terminal.rawValue) report must clear the pending stop without firing it")
        expect(!controller.receive(PerformanceReport(sessionID: "session-t", state: .playing))
               && fired == 0,
               "a stop cleared by \(terminal.rawValue) must not fire on a later playing report")
    }

    // 4. Session replacement (another play / queue handoff), agent loss and explicit cancel
    //    each remove the pending action before it can reach a later session.
    let handoff = PerformanceScenarioStopController()
    var handoffStops = 0
    _ = handoff.handleStop(waitFor: "playing", sessionID: "session-old",
                           immediateStop: { handoffStops += 1 })
    handoff.reconcile(activeSessionID: "session-new")
    expect(!handoff.isPending && handoffStops == 0
           && !handoff.receive(PerformanceReport(sessionID: "session-old", state: .playing)),
           "a queue handoff to another session must clear the pending stop before it can fire")
    handoff.reconcile(activeSessionID: nil)
    expect(!handoff.isPending, "reconciling an idle controller must stay idle")

    let lost = PerformanceScenarioStopController()
    var lostStops = 0
    _ = lost.handleStop(waitFor: "playing", sessionID: "session-lost",
                        immediateStop: { lostStops += 1 })
    lost.reconcile(activeSessionID: nil)
    expect(!lost.isPending && lostStops == 0
           && !lost.receive(PerformanceReport(sessionID: "session-lost", state: .playing)),
           "agent loss must clear the pending stop and it must never fire later")
    lost.reconcile(activeSessionID: "session-lost")
    expect(!lost.isPending, "a reconcile after cancellation must not resurrect a pending stop")

    let cancelled = PerformanceScenarioStopController()
    var cancelledStops = 0
    _ = cancelled.handleStop(waitFor: "playing", sessionID: "session-c",
                             immediateStop: { cancelledStops += 1 })
    cancelled.cancel()
    expect(!cancelled.isPending && cancelledStops == 0
           && !cancelled.receive(PerformanceReport(sessionID: "session-c", state: .playing)),
           "an explicit cancel must remove the pending action")

    // 5. Default behavior is unchanged: only the exact opt-in defers. Every other stop
    //    (absent waitFor, no active session, unrecognized value) runs immediately.
    let legacy = PerformanceScenarioStopController()
    var legacyStops = 0
    let legacyDeferred = legacy.handleStop(waitFor: nil, sessionID: "session-x",
                                           immediateStop: { legacyStops += 1 })
    expect(!legacyDeferred && legacyStops == 1 && !legacy.isPending,
           "a scenario stop without waitFor must keep the established immediate stop")
    let legacyNoSession = PerformanceScenarioStopController()
    var legacyNoSessionStops = 0
    let legacyNoSessionDeferred = legacyNoSession.handleStop(waitFor: nil, sessionID: nil,
                                                             immediateStop: { legacyNoSessionStops += 1 })
    expect(!legacyNoSessionDeferred && legacyNoSessionStops == 1 && !legacyNoSession.isPending,
           "a legacy scenario stop with no active session must still run its immediate stop path")
    let unknown = PerformanceScenarioStopController()
    var unknownStops = 0
    _ = unknown.handleStop(waitFor: "ended", sessionID: "session-x",
                           immediateStop: { unknownStops += 1 })
    expect(unknownStops == 1 && !unknown.isPending,
           "an unrecognized waitFor must not defer; the established immediate stop is preserved")
    let noSession = PerformanceScenarioStopController()
    var noSessionStops = 0
    let noSessionDeferred = noSession.handleStop(waitFor: "playing", sessionID: nil,
                                                 immediateStop: { noSessionStops += 1 })
    expect(noSessionDeferred && noSessionStops == 0 && !noSession.isPending,
           "an opted-in stop with no active session has nothing to wait for or stop")

    // 6. Real composition with the production acceptance rule: handleEvent accepts a report
    //    only for the active session, so another session's report never reaches the gate.
    var state = PerformanceSessionState()
    let active = session("active")
    let other = session("other")
    state.start(active)
    let composed = PerformanceScenarioStopController()
    var composedStops = 0
    _ = composed.handleStop(waitFor: "playing", sessionID: state.session?.id,
                            immediateStop: { composedStops += 1 })
    let unrelated = PerformanceReport(sessionID: other.id, state: .playing)
    let unrelatedAccepted = state.accept(unrelated)
    if unrelatedAccepted { _ = composed.receive(unrelated) }
    expect(!unrelatedAccepted && composed.isPending && composedStops == 0,
           "the accepted-session rule must reject another session's report before the stop gate sees it")
    let matching = PerformanceReport(sessionID: active.id, state: .playing)
    expect(state.accept(matching) && composed.receive(matching) && composedStops == 1
           && !composed.isPending,
           "the active session's accepted playing report must drive the deferred stop in the real composition")

    // Real composition of the already-playing schedule: the accepted report is already
    // projected for the active session when the stop arrives, so it stops immediately.
    var playingState = PerformanceSessionState()
    let playingSession = session("playing-active")
    playingState.start(playingSession)
    let currentPlaying = PerformanceReport(sessionID: playingSession.id, state: .playing)
    expect(playingState.accept(currentPlaying),
           "the active session's accepted playing report must be projected as current")
    let composedPlaying = PerformanceScenarioStopController()
    var composedPlayingStops = 0
    let composedPlayingDeferred = composedPlaying.handleStop(
        waitFor: "playing", sessionID: playingState.session?.id,
        currentReport: currentPlaying,
        immediateStop: { composedPlayingStops += 1 })
    expect(!composedPlayingDeferred && composedPlayingStops == 1 && !composedPlaying.isPending,
           "an already-accepted playing report must stop immediately in the real composition")
}
