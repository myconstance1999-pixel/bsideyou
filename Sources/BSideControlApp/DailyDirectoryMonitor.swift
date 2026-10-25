import Foundation
import Darwin
import BSideCore
import BSidePlatform

/// Main-thread authorization refresh only. Catalog validation and playback belong to the owner.
final class DailyDirectoryMonitor {
    struct Binding {
        let access: DirectoryAccessLease
        let bookmark: Data
        /// Persisted anchor to keep/commit. Unchanged from the saved record during ordinary renewal.
        let identity: StoredDirectoryIdentity?
        /// Fresh metadata captured from this resolved lease.
        let freshIdentity: DirectoryIdentitySnapshot?
        /// True only for a prospective legacy root with no sufficient anchor yet.
        let adoptAfterValidation: Bool
    }

    private let onRefresh: (Binding) -> Void
    private let onFailure: (DailyAssetIssue) -> Void
    private let onIdentityConflict: () -> Void
    private let logURLs: [URL]
    private var path: String?
    private var bookmark: Data?
    private var access: DirectoryAccessLease?
    // Persisted cross-restart anchor; separate from the renewable bookmark and from the
    // session-local lease comparison below.
    private var storedIdentity: StoredDirectoryIdentity?
    // Keep the selected session's identity even if a later metadata read is unavailable.
    // Only stop/new start may establish a different directory identity.
    private var identityAnchor: DirectoryAccessLease?
    private var identityConflict = false
    private var monitor: DirectoryChangeMonitor?
    private var monitoredPath: String?
    private var nativeMonitoring = false
    private var restartMonitor = false
    private var volumeOffline = false
    private var generation: UInt64 = 0
    private var monitorID = UUID()
    private var refreshID = UUID()
    private var refreshWork: DispatchWorkItem?

    init(onRefresh: @escaping (Binding) -> Void, onFailure: @escaping (DailyAssetIssue) -> Void,
         onIdentityConflict: @escaping () -> Void) {
        precondition(Thread.isMainThread)
        self.onRefresh = onRefresh
        self.onFailure = onFailure
        self.onIdentityConflict = onIdentityConflict
        logURLs = [AppPaths.controlLogURL, AppPaths.agentLogURL].flatMap {
            [$0, URL(fileURLWithPath: $0.path + ".1")]
        }
    }

    /// Observation starts before the owner's validation. It never itself publishes a refresh.
    func start(path: String, bookmark: Data?, identity: StoredDirectoryIdentity?,
               access: DirectoryAccessLease?) {
        precondition(Thread.isMainThread)
        stop()
        self.path = access?.url.path ?? path
        self.bookmark = bookmark
        self.access = access
        storedIdentity = identity
        identityAnchor = access
        observe(access: access)
    }

    /// Manual retry still resolves the saved bookmark; a readable old path cannot replace it.
    func refresh() {
        precondition(Thread.isMainThread)
        guard path != nil else { return }
        cancelPendingRefresh()
        resolveAndRefresh()
    }

    /// Carries a successfully validated/adopted record back into the running monitor, so an
    /// ordinary refresh cannot re-propose migration or recompute the anchor.
    func commitIdentity(_ identity: StoredDirectoryIdentity?) {
        precondition(Thread.isMainThread)
        storedIdentity = identity
    }

    func stop() {
        precondition(Thread.isMainThread)
        generation &+= 1
        cancelPendingRefresh()
        monitorID = UUID()
        monitor?.stop()
        monitor = nil
        monitoredPath = nil
        nativeMonitoring = false
        restartMonitor = false
        volumeOffline = false
        identityConflict = false
        path = nil
        bookmark = nil
        access = nil
        identityAnchor = nil
        storedIdentity = nil
    }

    deinit { stop() }

    private func acquire() throws -> Binding {
        if let bookmark {
            let restored = try DirectoryAccessLease.resolvePersistent(bookmark)
            let fresh = restored.lease.identitySnapshot(provenance: .legacyAdopted)
            let outcome = DirectoryIdentityResolver.resolve(stored: storedIdentity, bookmark: bookmark,
                                                            fresh: fresh)
            if let reason = outcome.conflictReason { throw DirectoryIdentityError.conflict(reason) }
            return Binding(access: restored.lease, bookmark: restored.renewedData ?? bookmark,
                           identity: outcome.identity, freshIdentity: fresh,
                           adoptAfterValidation: outcome.adoptAfterValidation)
        }
        // The no-bookmark branch is only the initial selected/legacy migration. Once saved
        // data exists, every attempt above is authoritative and throws instead of falling back.
        if let access {
            let selected = try DirectoryAccessLease.fromSelectedURL(access.url)
            let fresh = selected.lease.identitySnapshot(provenance: .explicitSelection)
            return Binding(access: selected.lease, bookmark: selected.persistentData,
                           identity: DirectoryIdentityResolver.explicitSelection(fresh: fresh),
                           freshIdentity: fresh, adoptAfterValidation: false)
        }
        guard let path else { throw CocoaError(.fileReadNoSuchFile) }
        let migrated = try DirectoryAccessLease.migrateLegacyPath(path)
        let fresh = migrated.lease.identitySnapshot(provenance: .legacyAdopted)
        if let storedIdentity {
            // Existing record without a renewable bookmark: preserve it, never rebaseline.
            let outcome = DirectoryIdentityResolver.resolve(stored: storedIdentity, bookmark: Data(),
                                                            fresh: fresh)
            if let reason = outcome.conflictReason { throw DirectoryIdentityError.conflict(reason) }
            return Binding(access: migrated.lease, bookmark: migrated.persistentData,
                           identity: outcome.identity, freshIdentity: fresh,
                           adoptAfterValidation: false)
        }
        return Binding(access: migrated.lease, bookmark: migrated.persistentData, identity: nil,
                       freshIdentity: fresh, adoptAfterValidation: true)
    }

    private func resolveAndRefresh() {
        let fresh: Binding
        do {
            fresh = try acquire()
        } catch is DirectoryIdentityError {
            // A detectable cross-restart replacement: keep the original path, bookmark and
            // anchor, refuse any scan/activation for the candidate, and require reselection.
            identityConflict = true
            cancelPendingRefresh()
            observe(access: nil, force: true)
            onIdentityConflict()
            return
        } catch {
            let issue = DailyAssetIssue.classify(error)
            if issue == .missingLocation || issue == .accessDenied {
                // Preserve the existing workspace observer's cached volume identity. An
                // offline cold start already has a workspace-only observer without any grant.
                onFailure(issue)
            } else {
                observe(access: nil, force: true)
                onFailure(.authorizationRequired)
            }
            return
        }
        let sameDirectory = identityAnchor?.representsSameDirectory(as: fresh.access)
        let persistedIdentityMatches: Bool
        if let anchor = storedIdentity?.snapshotValue, let current = fresh.freshIdentity {
            persistedIdentityMatches = anchor.comparison(with: current) == .consistent
        } else {
            persistedIdentityMatches = false
        }
        // A cold-start conflict has no process-local lease. Consistency with its saved anchor
        // permits recovery; unknown evidence still cannot clear the conflict.
        if sameDirectory == false
            || (identityConflict && sameDirectory != true && !persistedIdentityMatches) {
            // Do not accept a renewed bookmark for a replacement inode at the same old path.
            // Keep the original data and anchor for manual retry of the original directory.
            identityConflict = true
            cancelPendingRefresh()
            observe(access: nil, force: true)
            onIdentityConflict()
            return
        }
        identityConflict = false
        if identityAnchor == nil { identityAnchor = fresh.access }
        bookmark = fresh.bookmark
        access = fresh.access
        storedIdentity = fresh.identity
        path = fresh.access.url.path
        volumeOffline = false
        observe(access: fresh.access)
        // The owner must also retain this binding in any detached validation or IPC handoff.
        // Reentrant stop/new selection cannot release this scope during the callback itself.
        withExtendedLifetime(fresh.access) { onRefresh(fresh) }
    }

    private func observe(access: DirectoryAccessLease?, force: Bool = false) {
        guard let path else { return }
        let root = access?.url ?? URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let nextPath = root.standardizedFileURL.path
        if !force, !restartMonitor, monitor != nil, monitoredPath == nextPath,
           access == nil || nativeMonitoring { return }
        monitorID = UUID()
        let currentMonitor = monitorID
        let currentGeneration = generation
        monitor?.stop()
        monitor = DirectoryChangeMonitor(root: root, access: access) { [weak self] change in
            guard let self, self.generation == currentGeneration, self.monitorID == currentMonitor else { return }
            self.changed(change)
        }
        monitor?.onNativeMonitoringChange = { [weak self] active in
            // Native registration settles after `observe` returns; keep the projection exact.
            guard let self, self.generation == currentGeneration, self.monitorID == currentMonitor else { return }
            self.nativeMonitoring = active
        }
        monitoredPath = nextPath
        restartMonitor = false
        nativeMonitoring = monitor?.start() ?? false
    }

    private func changed(_ change: DirectoryChange) {
        guard path != nil, !identityConflict else { return }
        if !change.requiresFullScan, !change.rootChanged, change.volumeAvailable == nil,
           !change.paths.isEmpty {
            // Refresh itself produces these application logs. Exclude only their exact
            // physical paths, including one rotation backup; other .log files remain inputs.
            let logs = Set(logURLs.map { Self.physicalPath($0.path) })
            guard change.paths.contains(where: { !logs.contains(Self.physicalPath($0)) }) else { return }
        }
        if change.rootChanged || change.volumeAvailable != nil { restartMonitor = true }
        if change.volumeAvailable == false {
            volumeOffline = true
            cancelPendingRefresh()
            onFailure(.missingLocation)
            return
        }
        if change.volumeAvailable == true { volumeOffline = false }
        guard !volumeOffline, refreshWork == nil else { return }
        // Keep the first-event deadline fixed; a stream of writes cannot postpone it forever.
        let currentGeneration = generation
        let currentRefresh = refreshID
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == currentGeneration, self.refreshID == currentRefresh else { return }
            self.refreshWork = nil
            self.resolveAndRefresh()
        }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func cancelPendingRefresh() {
        refreshID = UUID()
        refreshWork?.cancel()
        refreshWork = nil
    }

    private static func physicalPath(_ path: String) -> String {
        var ancestor = URL(fileURLWithPath: path)
        var missingComponents: [String] = []
        while true {
            if let resolved = realpath(ancestor.path, nil) {
                defer { free(resolved) }
                var result = String(cString: resolved)
                for component in missingComponents.reversed() {
                    result = (result as NSString).appendingPathComponent(component)
                }
                return result
            }
            let parent = ancestor.deletingLastPathComponent()
            guard parent.path != ancestor.path else { return URL(fileURLWithPath: path).standardizedFileURL.path }
            // Deleted/rotating log files still compare through their nearest existing ancestor.
            missingComponents.append(ancestor.lastPathComponent)
            ancestor = parent
        }
    }
}
