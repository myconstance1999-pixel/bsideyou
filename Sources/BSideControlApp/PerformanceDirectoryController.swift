// ControlApp owns directory discovery and its credentials. This object has no playback
// commands: refreshing candidates must never become an implicit stop/rebind operation.
import Foundation
import BSideCore
import BSidePlatform

final class PerformanceDirectoryController {
    struct Binding {
        let access: DirectoryAccessLease
        let bookmark: Data
        /// Persisted anchor to keep/commit; unchanged during ordinary renewal/move.
        let identity: StoredDirectoryIdentity?
        let freshIdentity: DirectoryIdentitySnapshot?
        let adoptAfterValidation: Bool
    }
    enum Update {
        case checking(root: URL)
        case ready(binding: Binding, result: PerformanceCandidateRefresh, monitoring: Bool)
        case failed(root: URL, message: String)
    }

    private let library: () -> PerformanceLibrary?
    private let onUpdate: (Update) -> Void
    private(set) var binding: Binding?
    private var canTransfer = false
    private var attemptedURL: URL?
    private var savedBookmark: Data?
    /// Persisted cross-restart anchor, independent of the renewable bookmark.
    private var savedIdentity: StoredDirectoryIdentity?
    /// Distinguishes a fresh user selection from a cold restore of saved data.
    private var isUserSelection = false
    private var snapshot: PerformanceCandidateSnapshot?
    private var scan: Task<Void, Never>?
    private var scanID = UUID()
    private var monitor: DirectoryChangeMonitor?
    private var monitorID = UUID()
    private var monitoredPath: String?
    private var monitoring = false
    private var restartMonitor = false
    private var refreshWork: DispatchWorkItem?
    private var pendingRefresh = false
    private var pendingFullScan = false
    private var pendingUserRefresh = false
    private var pendingPaths = Set<String>()

    init(library: @escaping () -> PerformanceLibrary?, onUpdate: @escaping (Update) -> Void) {
        self.library = library
        self.onUpdate = onUpdate
    }

    deinit {
        scan?.cancel()
        refreshWork?.cancel()
        // DirectoryChangeMonitor releases its native stream on this same owning thread.
    }

    /// Explicit user selection is a new binding. The caller owns any requested session stop.
    func select(_ url: URL) {
        reset()
        isUserSelection = true
        attemptedURL = url
        beginScan(changedPaths: nil, reason: "selection")
    }

    func restore(path: String, bookmark: Data?, identity: StoredDirectoryIdentity?) {
        reset()
        isUserSelection = false
        attemptedURL = URL(fileURLWithPath: path)
        savedBookmark = bookmark
        savedIdentity = identity
        beginScan(changedPaths: nil, reason: "restore")
    }

    /// A manual retry uses the same non-disruptive path as a directory event. A bookmark,
    /// once present, remains authoritative even if its old path happens to be readable.
    func refresh() {
        guard attemptedURL != nil else { return }
        queueRefresh(paths: nil, immediate: true)
    }

    func transfer() throws -> (root: String, bookmark: Data) {
        guard canTransfer, let binding else { throw CocoaError(.fileReadNoPermission) }
        // File events arrive asynchronously. A previously checked path may already name
        // another directory when the user clicks Play, before the event scan can reject it.
        let current = try acquire()
        if binding.access.representsSameDirectory(as: current.access) == false {
            rejectReplacedDirectory(root: binding.access.url)
            throw CocoaError(.fileReadNoPermission)
        }
        return (current.access.url.path, try current.access.makeTransferBookmark())
    }

    func reset() {
        scanID = UUID()
        scan?.cancel()
        scan = nil
        refreshWork?.cancel()
        refreshWork = nil
        pendingRefresh = false
        pendingFullScan = false
        pendingUserRefresh = false
        pendingPaths.removeAll()
        monitorID = UUID()
        monitor?.stop()
        monitor = nil
        monitoredPath = nil
        monitoring = false
        restartMonitor = false
        snapshot = nil
        binding = nil
        canTransfer = false
        attemptedURL = nil
        savedBookmark = nil
        savedIdentity = nil
        isUserSelection = false
    }

    private func acquire() throws -> Binding {
        guard let attemptedURL else { throw CocoaError(.fileReadNoSuchFile) }
        if let savedBookmark {
            let restored = try DirectoryAccessLease.resolvePersistent(savedBookmark)
            let fresh = restored.lease.identitySnapshot(provenance: .legacyAdopted)
            let outcome = DirectoryIdentityResolver.resolve(stored: savedIdentity, bookmark: savedBookmark,
                                                            fresh: fresh)
            if let reason = outcome.conflictReason { throw DirectoryIdentityError.conflict(reason) }
            return Binding(access: restored.lease, bookmark: restored.renewedData ?? savedBookmark,
                           identity: outcome.identity, freshIdentity: fresh,
                           adoptAfterValidation: outcome.adoptAfterValidation)
        }
        // An explicit selection is a new binding: capture its fresh identity as the anchor.
        if isUserSelection {
            let selected = try DirectoryAccessLease.fromSelectedURL(attemptedURL)
            let fresh = selected.lease.identitySnapshot(provenance: .explicitSelection)
            return Binding(access: selected.lease, bookmark: selected.persistentData,
                           identity: DirectoryIdentityResolver.explicitSelection(fresh: fresh),
                           freshIdentity: fresh, adoptAfterValidation: false)
        }
        // Path-only legacy restore: no renewable bookmark exists yet. Preserve any existing
        // (possibly unreadable) record rather than rebaselining it; otherwise adopt the
        // current tuple only after the scan succeeds.
        let migrated = try DirectoryAccessLease.migrateLegacyPath(attemptedURL.path)
        let fresh = migrated.lease.identitySnapshot(provenance: .legacyAdopted)
        if let savedIdentity {
            let outcome = DirectoryIdentityResolver.resolve(stored: savedIdentity, bookmark: Data(),
                                                            fresh: fresh)
            if let reason = outcome.conflictReason { throw DirectoryIdentityError.conflict(reason) }
            return Binding(access: migrated.lease, bookmark: migrated.persistentData,
                           identity: outcome.identity, freshIdentity: fresh,
                           adoptAfterValidation: false)
        }
        return Binding(access: migrated.lease, bookmark: migrated.persistentData, identity: nil,
                       freshIdentity: fresh, adoptAfterValidation: true)
    }

    /// A successful scan finalizes the once-only prospective legacy adoption, so later
    /// refreshes reuse the same anchor/timestamp instead of re-proposing migration.
    private func finalizeIdentity(_ acquired: Binding) -> Binding {
        guard acquired.adoptAfterValidation else { return acquired }
        let identity = DirectoryIdentityResolver.adopt(fresh: acquired.freshIdentity) ?? acquired.identity
        let settled = Binding(access: acquired.access, bookmark: acquired.bookmark, identity: identity,
                              freshIdentity: acquired.freshIdentity, adoptAfterValidation: false)
        binding = settled
        savedIdentity = identity
        return settled
    }

    private func beginScan(changedPaths: [String]?, reason: String) {
        guard let root = attemptedURL else { return }
        var announce = reason != "filesystem" || snapshot == nil
        if announce {
            canTransfer = false
            onUpdate(.checking(root: binding?.access.url ?? root))
        }
        guard let library = library() else {
            canTransfer = false
            onUpdate(.failed(root: root, message: "演奏清单不可用，请检查应用是否安装完整。"))
            return
        }
        let acquired: Binding
        do {
            acquired = try acquire()
        } catch {
            canTransfer = false
            if error is DirectoryIdentityError {
                // Cross-restart replacement detected before any renewal/scan. Keep the saved
                // bookmark, path and anchor; only explicit reselection may establish a new one.
                snapshot = nil
                rejectReplacedDirectory(root: root)
                if reason != "filesystem" { AppLog.control("performance.identity-conflict root=\(root.path)") }
                return
            }
            // Keep an existing stream for root recovery; an offline cold start gets only
            // filtered workspace mount notifications, never filesystem access from a path.
            observe(root: root, access: nil)
            snapshot = nil
            let issue = DailyAssetIssue.classify(error)
            let message = [.missingLocation, .accessDenied].contains(issue)
                ? PerformanceBrowserModel.scanFailureMessage(error)
                : "无法恢复演奏素材的访问授权。请重新选择演奏素材目录。"
            onUpdate(.failed(root: root, message: message))
            // A selected root can contain our log. Writing on every automatic failure
            // would generate another event and retry indefinitely; manual retry logs detail.
            if reason != "filesystem" { AppLog.control("performance.authorization-failed detail=\(error)") }
            return
        }
        if let previousBinding = binding,
           previousBinding.access.representsSameDirectory(as: acquired.access) == false {
            // Foundation can resolve a stale bookmark to a different directory that has
            // reused its old path. Do not renew/persist that replacement automatically.
            // This identity comparison is process-local, not a promise across system boots.
            rejectReplacedDirectory(root: root)
            return
        }
        if !announce, binding?.access.url.path != acquired.access.url.path {
            announce = true
            canTransfer = false
            onUpdate(.checking(root: acquired.access.url))
        }
        binding = acquired
        savedBookmark = acquired.bookmark
        savedIdentity = acquired.identity
        attemptedURL = acquired.access.url
        observe(root: acquired.access.url, access: acquired.access)
        let previous = snapshot
        let token = UUID()
        scanID = token
        let access = acquired.access
        let shouldAnnounce = announce
        // An unrelated file may be our own log inside a broadly selected root. Logging the
        // start of every file-triggered scan would feed that event back into itself forever.
        if reason != "filesystem" { AppLog.control("performance.scan-start reason=\(reason)") }
        scan = Task { @MainActor [weak self] in
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    // Cancellation cannot interrupt a synchronous filesystem call. The
                    // detached worker owns access until it actually returns.
                    try withExtendedLifetime(access) {
                        try library.refreshCandidates(root: access.url, previous: previous, changedPaths: changedPaths)
                    }
                }
                let result = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: { worker.cancel() }
                guard let self, self.scanID == token, !Task.isCancelled else { return }
                self.scan = nil
                self.snapshot = result.snapshot
                self.canTransfer = true
                // Failed scans never reach here, so adoption is committed only on success.
                let ready = self.finalizeIdentity(acquired)
                if shouldAnnounce || !result.checkedVariantIDs.isEmpty {
                    self.onUpdate(.ready(binding: ready, result: result, monitoring: self.monitoring))
                    AppLog.control("performance.scan-complete checked=\(result.checkedVariantIDs.count) full=\(result.fullScan)")
                }
                self.runPendingRefresh()
            } catch {
                guard let self, self.scanID == token, !Task.isCancelled else { return }
                self.scan = nil
                self.snapshot = nil
                self.canTransfer = false
                self.onUpdate(.failed(root: access.url, message: PerformanceBrowserModel.scanFailureMessage(error)))
                if reason != "filesystem" { AppLog.control("performance.scan-failed detail=\(error)") }
                self.runPendingRefresh()
            }
        }
    }

    private func rejectReplacedDirectory(root: URL) {
        canTransfer = false
        snapshot = nil
        // Transfer can discover replacement while an automatic scan is still running.
        // Its older result must not restore candidate availability or replace the bookmark.
        scanID = UUID()
        scan?.cancel()
        scan = nil
        refreshWork?.cancel()
        refreshWork = nil
        pendingRefresh = false
        pendingFullScan = false
        pendingUserRefresh = false
        pendingPaths.removeAll()
        monitorID = UUID()
        monitor?.stop()
        monitor = nil
        monitoring = false
        onUpdate(.failed(root: root, message: "演奏素材目录的身份与已保存记录不一致（可能已被替换）。请重新选择原素材目录。"))
    }

    private func observe(root: URL, access: DirectoryAccessLease?) {
        let path = root.standardizedFileURL.resolvingSymlinksInPath().path
        if monitor != nil, monitoredPath == path, !restartMonitor,
           access == nil || monitoring { return }
        monitorID = UUID()
        let token = monitorID
        monitor?.stop()
        monitor = DirectoryChangeMonitor(root: root, access: access) { [weak self] change in
            guard let self, self.monitorID == token else { return }
            self.changed(change)
        }
        monitor?.onNativeMonitoringChange = { [weak self] active in
            // Native registration settles after `observe` returns. Track the real result so a
            // failed stream start stays visible and retryable on the next scan.
            guard let self, self.monitorID == token else { return }
            self.monitoring = active
        }
        monitoredPath = path
        restartMonitor = false
        monitoring = monitor?.start() ?? false
    }

    private func changed(_ change: DirectoryChange) {
        guard let root = attemptedURL else { return }
        if change.rootChanged || change.volumeAvailable != nil { restartMonitor = true }
        if change.volumeAvailable == false {
            scanID = UUID()
            scan?.cancel()
            scan = nil
            refreshWork?.cancel()
            refreshWork = nil
            pendingRefresh = false
            pendingPaths.removeAll()
            pendingFullScan = false
            pendingUserRefresh = false
            snapshot = nil
            canTransfer = false
            onUpdate(.failed(root: root, message: "演奏素材所在磁盘已离线。重新连接后会自动检查，也可以重新选择目录。"))
            return
        }
        queueRefresh(paths: change.requiresFullScan || change.rootChanged || change.volumeAvailable == true
                     ? nil : change.paths, immediate: false)
    }

    private func queueRefresh(paths: [String]?, immediate: Bool) {
        pendingRefresh = true
        pendingUserRefresh = pendingUserRefresh || immediate
        if let paths, !pendingFullScan {
            pendingPaths.formUnion(paths)
            if pendingPaths.count > 256 { pendingFullScan = true; pendingPaths.removeAll() }
        } else if paths == nil {
            pendingFullScan = true
            pendingPaths.removeAll()
        }
        // One scan at a time for event bursts. Changes arriving during it are retained for
        // one follow-up; repeatedly cancelling/restarting would starve a downloading library.
        guard scan == nil else { return }
        if immediate {
            refreshWork?.cancel()
            refreshWork = nil
            runPendingRefresh()
        } else if refreshWork == nil {
            // First-event deadline stays fixed, so a stream of writes cannot defer forever.
            let work = DispatchWorkItem { [weak self] in
                self?.refreshWork = nil
                self?.runPendingRefresh()
            }
            refreshWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
    }

    private func runPendingRefresh() {
        guard pendingRefresh, scan == nil else { return }
        let paths = pendingFullScan ? nil : Array(pendingPaths)
        let reason = pendingUserRefresh ? "manual" : "filesystem"
        pendingRefresh = false
        pendingFullScan = false
        pendingUserRefresh = false
        pendingPaths.removeAll()
        beginScan(changedPaths: paths, reason: reason)
    }
}
