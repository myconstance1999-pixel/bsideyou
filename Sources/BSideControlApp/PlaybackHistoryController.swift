// BSideControlApp — PlaybackHistoryController: the single serial owner of the confirmed-interval
// ledger in the production ControlApp. It owns the opt-in token (epoch + session), performs every
// mutation through the concrete PlaybackHistoryStore, and is the only place that talks to the
// Agent about recording.
//
// Rules enforced here:
//  * Missing/corrupt file: default OFF, or an explicit load failure. Nothing writes until the
//    owner enables recording, and a corrupt file is never overwritten/reset silently.
//  * Enabling/disabling/clearing persists BEFORE success is reported; a failed write leaves both
//    the on-disk file and the in-memory ledger at their last valid state and surfaces the error.
//  * A ready Agent gets a freshly allocated session token. Clear/disable/re-enable always mints a
//    new token, so a buffered pre-switch report can never be relabelled.
//  * A report is accepted only when its epoch/session match the currently issued token; the whole
//    report is committed with one atomic store write, and capture contexts only rebind forward.

import Foundation
import BSideCore
import BSidePlatform

/// Pure Settings projection. Independent per-channel evidence only; no combined total.
struct PlaybackHistorySettings: Equatable {
    var isEnabled: Bool
    var intervalCount: Int
    var visualDuration: TimeInterval
    var musicDuration: TimeInterval
    var ambientDuration: TimeInterval
    var error: String?
    var canRetry = false

    var channelEvidence: String {
        func minutes(_ value: TimeInterval) -> String {
            String(format: "%.1f 分钟", value / 60)
        }
        return "画面 \(minutes(visualDuration)) · 音乐 \(minutes(musicDuration)) · 环境音 \(minutes(ambientDuration))"
    }
}

final class PlaybackHistoryController {
    enum LoadState: Equatable {
        case ready
        case failed(String)
    }

    private(set) var state: LoadState
    private(set) var issued: HistoryRecordingRequest?
    private(set) var lastError: String?
    /// True after a failed batch write: ingestion stays paused (no unbounded buffer, no silent
    /// retry) until a later successful store action clears it. Agent authority is dropped too.
    private(set) var ingestionPaused = false
    private var store: PlaybackHistoryStore?
    /// Confirmed Agent reports not yet persisted. ControlApp owns the batch so a stopping
    /// supervisor is never required to deliver the tail. Bounded by BOTH a confirmed-duration
    /// cadence and a hard submission-count cap; there is no timer.
    private var pending: [PlaybackIntervalSubmission] = []
    private var pendingToken: HistoryRecordingRequest?
    /// Event-driven cadence: commit after this much confirmed span has accumulated.
    static let pendingDurationLimit: TimeInterval = 30
    /// Hard bound on buffered submissions, independent of the duration cadence.
    static let pendingBatchLimit = 90

    /// Delivered on the main thread; the AppDelegate forwards it to the Agent.
    var onSend: (HistoryRecordingRequest) -> Void = { _ in }
    /// Request a UI refresh after a state/error change.
    var onChange: () -> Void = { }

    var ledger: PlaybackHistoryLedger? { store?.ledger }
    var isEnabled: Bool { store?.ledger.isRecording ?? false }
    var intervalCount: Int { store?.ledger.intervals.count ?? 0 }

    init(fileURL: URL = AppPaths.applicationSupport.appendingPathComponent("history.json")) {
        do {
            store = try PlaybackHistoryStore(fileURL: fileURL)
            state = .ready
        } catch {
            store = nil
            state = .failed(Self.describe(error))
            lastError = Self.describe(error)
        }
    }

    var settings: PlaybackHistorySettings {
        PlaybackHistorySettings(
            isEnabled: isEnabled, intervalCount: intervalCount,
            visualDuration: duration(for: .visual), musicDuration: duration(for: .music),
            ambientDuration: duration(for: .ambient),
            error: lastError ?? {
                if case .failed(let message) = state { return message }
                return nil
            }(), canRetry: ingestionPaused)
    }

    /// A freshly accepted Agent generation: allocate a new session and send the current token.
    /// Disabled recording still sends an explicit disable so a restarted Agent keeps no authority.
    func agentReady() {
        guard state == .ready, let store else { return }
        guard store.ledger.isRecording else {
            issued = nil
            onSend(HistoryRecordingRequest(enabled: false, epoch: store.ledger.epoch, session: ""))
            return
        }
        // A data-error pause stops authority: never re-enable capture or mint a fresh token.
        guard !ingestionPaused else {
            issued = nil
            onSend(HistoryRecordingRequest(enabled: false, epoch: store.ledger.epoch, session: ""))
            return
        }
        // A fresh token must never leave confirmed old-session spans uncommitted.
        guard commitPending(notify: false) else {
            onChange()
            return
        }
        sendFreshToken(store: store)
    }

    /// Persist the opt-in toggle before reporting success. Only a committed write sends a token.
    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        guard let store else { return false }
        // Any pending confirmed spans are persisted under the CURRENT token before the switch; a
        // failed commit preserves the truthful error and aborts the switch (no silent loss).
        guard commitPending(notify: false) else {
            onChange()
            return false
        }
        do {
            try store.setRecording(enabled)
        } catch {
            lastError = Self.describe(error)
            onChange()
            return false
        }
        lastError = nil
        ingestionPaused = false
        if enabled {
            sendFreshToken(store: store)
        } else {
            issued = nil
            onSend(HistoryRecordingRequest(enabled: false, epoch: store.ledger.epoch, session: ""))
        }
        onChange()
        return true
    }

    /// Clear advances the persisted epoch and, while still enabled, mints a fresh bound token.
    /// Pending pre-clear reports are discarded ONLY after the clear write succeeds, so a failed
    /// clear cannot silently drop confirmed spans; a successful clear makes them unrelabellable.
    @discardableResult
    func clear() -> Bool {
        guard let store else { return false }
        do {
            try store.clear()
        } catch {
            lastError = Self.describe(error)
            onChange()
            return false
        }
        pending.removeAll()
        pendingToken = nil
        lastError = nil
        ingestionPaused = false
        if store.ledger.isRecording {
            sendFreshToken(store: store)
        } else {
            issued = nil
        }
        onChange()
        return true
    }

    /// Explicit, owner-triggered retention crop; there is no automated scheduler or default expiry.
    /// A pending commit that cannot be persisted fails the crop instead of being ignored.
    @discardableResult
    func crop(retainingAfter cutoff: Date) -> Bool {
        guard let store else { return false }
        guard commitPending(notify: false) else {
            onChange()
            return false
        }
        do {
            try store.crop(retainingAfter: cutoff)
        } catch {
            lastError = Self.describe(error)
            onChange()
            return false
        }
        lastError = nil
        onChange()
        return true
    }

    /// Export fails truthfully if confirmed pending spans cannot first be persisted; there is no
    /// hidden retry and no silently dropped batch.
    @discardableResult
    func export(to url: URL) -> Bool {
        guard let store else { return false }
        guard commitPending(notify: false) else {
            onChange()
            return false
        }
        do {
            try store.export(to: url)
        } catch {
            lastError = Self.describe(error)
            onChange()
            return false
        }
        lastError = nil
        onChange()
        return true
    }

    /// One Agent report from the current running generation. The issued epoch/session are
    /// verified BEFORE anything is buffered or bound; only current-token spans enter the batch.
    /// Committing happens on the event-driven elapsed cadence or the bounded count cap, and the
    /// UI is refreshed only after a persisted batch/action, never per callback.
    func receive(_ submissions: [PlaybackIntervalSubmission]) {
        guard state == .ready, let store, let issued, issued.enabled,
              store.ledger.isRecording, store.ledger.epoch == issued.epoch,
              !ingestionPaused, !submissions.isEmpty else { return }
        if pending.isEmpty { pendingToken = issued }
        pending.append(contentsOf: submissions.filter {
            $0.epoch == issued.epoch && $0.session == issued.session
        })
        guard !pending.isEmpty else { return }
        if pendingDuration >= Self.pendingDurationLimit || pending.count >= Self.pendingBatchLimit {
            commitPending()
        }
    }

    private var pendingDuration: TimeInterval {
        guard let start = pending.map(\.monotonicStart).min(),
              let end = pending.map(\.monotonicEnd).max() else { return 0 }
        return end - start
    }

    /// Commit the pending confirmed batch as one atomic write. Called at the elapsed cadence, the
    /// count cap, a state boundary, and normal quit; a stale token discards instead of relabelling.
    @discardableResult
    func commitPending(notify: Bool = true) -> Bool {
        guard !pending.isEmpty else { return true }
        guard let store, let token = pendingToken, token.enabled,
              store.ledger.isRecording, store.ledger.epoch == token.epoch else {
            pending.removeAll()
            return false
        }
        let batch = pending
        let wasPaused = ingestionPaused
        do {
            _ = try store.ingest(batch, expected: token)
            pending.removeAll()
            pendingToken = nil
            lastError = nil
            ingestionPaused = false
            if wasPaused { sendFreshToken(store: store) }
            if notify { onChange() }
            return true
        } catch {
            // Truthful failure: stop ingest/buffering rather than retrying invisibly or growing.
            // Drop remote authority with the existing disable request so the Agent stops capturing.
            // Retain this bounded batch for an explicit action/quit retry.
            lastError = Self.describe(error)
            ingestionPaused = true
            self.issued = nil
            onSend(HistoryRecordingRequest(enabled: false, epoch: store.ledger.epoch, session: ""))
            if notify { onChange() }
            return false
        }
    }

    /// Agent loss stops history authority. Already-confirmed reports are persisted first; no
    /// report is accepted until a fresh bound token is issued.
    func agentLost() {
        // Announce only a real projection change. The AppDelegate wiring
        // (onChange -> uiRefresh -> pushModelUpdate -> agentLost while the Agent is not running)
        // re-enters this method, so an unchanged lastError — e.g. an export failure that is still
        // displayed — is NOT a new event; a committed or newly failed flush does change
        // count/durations/error and is announced exactly once.
        let before = settings
        if !ingestionPaused { _ = commitPending(notify: false) }
        issued = nil
        if settings != before { onChange() }
    }

    /// Independent per-channel confirmed duration; there is deliberately no combined total.
    func duration(for channel: PlaybackChannel) -> TimeInterval {
        store?.ledger.duration(for: channel) ?? 0
    }

    private func sendFreshToken(store: PlaybackHistoryStore) {
        let request = HistoryRecordingRequest(
            enabled: true, epoch: store.ledger.epoch, session: UUID().uuidString)
        issued = request
        onSend(request)
    }

    private static func describe(_ error: Error) -> String {
        if let storeError = error as? PlaybackHistoryStore.StoreError {
            switch storeError {
            case .corruptFile:
                return "历史记录文件已损坏；未写入，也不会被覆盖或重置。"
            case .unsupportedVersion(let version):
                return "历史记录文件版本不受支持（\(version)）；未写入，也不会被覆盖。"
            }
        }
        return "历史记录读取或保存失败：\(error.localizedDescription)"
    }
}
