// Scenario-seam-only deferred stop. No media, no timers, no product wiring: the
// controller is inert unless the isolated --performance-scenario seam opts in.
import Foundation
import BSideCore

/// An explicitly opted-in `stop` step that waits for the exact session that was active
/// when the stop was requested to emit its own accepted `playing` report, then fires at
/// most once. If that exact session has already emitted its accepted `playing` report, the
/// stop runs immediately instead, because no further report is guaranteed to follow.
///
/// Why this exists: a coalesced schedule (`play` then `stop` in the same main-queue
/// drain, e.g. after a sleep/wake) used to deliver the stop while the load was still in
/// flight, producing `loading -> stopped` with no `playing`. That is truthful cancelled
/// load behavior, but it cannot prove playing-before-stop. The strict analyzer correctly
/// keeps that checkpoint unmet; this seam lets a future durable scenario prove it without
/// widening delays or waiving the checkpoint.
///
/// Lifetime is bounded by session events, never by a timeout: a session replacement
/// (another play or queue handoff), agent loss, explicit cancel, or the target session's
/// own terminal report clears the pending action so it can never stop a later session. A
/// mismatched/stale report is ignored: it neither fires nor clears the pending action.
final class PerformanceScenarioStopController {
    private var pendingSessionID: String?
    private var pendingStop: (() -> Void)?

    /// True while a deferred stop is armed and un-fired.
    var isPending: Bool { pendingSessionID != nil }
    /// The session the pending stop is bound to, when armed.
    var waitingSessionID: String? { pendingSessionID }

    /// Handles one scenario `stop` step. Only `waitFor == "playing"` defers; every other
    /// value keeps the established immediate stop. `currentReport` is the accepted report
    /// currently projected for the active session, when one exists: if it is that exact
    /// session's own accepted `playing` state, there is no future playing report to wait
    /// for and the stop runs now, exactly once. Returns true when the stop was deferred.
    @discardableResult
    func handleStop(waitFor: String?, sessionID: String?,
                    currentReport: PerformanceReport? = nil,
                    immediateStop: @escaping () -> Void) -> Bool {
        guard waitFor == "playing" else {
            immediateStop()
            return false
        }
        // Nothing is loading or playing, so there is no session to wait for or stop.
        guard let sessionID else { return true }
        // The normal (non-coalesced) schedule stops after the matching session already
        // reported playing, so waiting would hang until a terminal report. Only the exact
        // active session's own accepted playing state counts; an unrelated or stale report
        // or a synthetic loading projection must keep waiting.
        if let currentReport, currentReport.sessionID == sessionID, currentReport.state == .playing {
            clear()
            immediateStop()
            return false
        }
        pendingSessionID = sessionID
        pendingStop = immediateStop
        return true
    }

    /// Consumes one accepted report. Fires the deferred stop at most once and only for the
    /// exact pending session; that session's own terminal state clears the pending action
    /// instead, while a report for any other session is ignored.
    @discardableResult
    func receive(_ report: PerformanceReport) -> Bool {
        guard let target = pendingSessionID, report.sessionID == target else { return false }
        switch report.state {
        case .playing:
            let stop = pendingStop
            clear()
            stop?()
            return true
        case .ended, .stopped, .failed:
            clear()
            return false
        case .loading, .paused:
            return false
        }
    }

    /// Drops a pending stop when the active session changes (new play, queue handoff or
    /// agent loss). A no-op while idle or while the active session is still the target.
    func reconcile(activeSessionID: String?) {
        guard let target = pendingSessionID, target != activeSessionID else { return }
        clear()
    }

    /// Drops any pending stop, e.g. when an immediate stop supersedes it.
    func cancel() { clear() }

    private func clear() {
        pendingSessionID = nil
        pendingStop = nil
    }
}
