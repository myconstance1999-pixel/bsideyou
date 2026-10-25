// BSideControlApp — owner of the explicit local song catalog (ADR-022). ControlApp is the SOLE
// persistent owner: it authorizes roots, runs bounded metadata scans, remembers per-track file
// selection and fingerprints the ONE selected file before playback. The Agent is disposable and
// never owns any of this state.
//
// No AVPlayer here: this controller only reads files, hashes one selected file and hands Core /
// IPC a typed local reference plus an explicit per-file binding.
//
// Every mutation is transactional: a candidate catalog is derived, saved atomically, and only
// then published as the in-memory committed state. A failed save keeps the previous ids, numbers,
// selection and records and surfaces a visible message instead of pretending success.
//
// Threading (PerformanceDirectoryController pattern): every controller mutation, persistence
// publication, generation check and callback is serialized on the MAIN thread. Only the bounded
// metadata scan and the single-file hash run on detached workers and hand their result back
// through a `@MainActor` task, so SwiftUI/AppKit state is never touched off-main.
import Foundation
import BSideCore
import BSidePlatform

/// One resolved local playback request: an already-authorized transfer grant (root path + fresh
/// ephemeral bookmark), the typed Core reference and the exact selected-file binding.
struct LocalPlaybackGrant {
    let root: String
    let transferBookmark: Data
    let reference: LocalPerformanceReference
    let binding: PerformanceFileBinding
}

/// Injectable IO seams. Production uses the ordinary Platform helpers unchanged. The regression
/// suite substitutes tiny temp-directory seams so ordering, identity and transactional behaviour
/// are exercised deterministically without a security-scoped bookmark entitlement or real media.
struct LocalSongLibrarySeams {
    var authorizeRoot: (URL) throws -> (lease: DirectoryAccessLease, persistentData: Data)
    var resolveRoot: (Data) throws -> (lease: DirectoryAccessLease, renewedData: Data?)
    var scan: (URL, LocalSongOfficialSource?) throws -> [LocalSongScannedGroup]
    var fingerprint: (URL) throws -> LocalFileFingerprint
    var transferBookmark: (DirectoryAccessLease) throws -> Data
    /// Nil uses the controller's real store. A regression may substitute a failing save to
    /// exercise transactional behaviour.
    var save: ((LocalSongCatalog) throws -> Void)?

    static let production = LocalSongLibrarySeams(
        authorizeRoot: { try DirectoryAccessLease.fromSelectedURL($0) },
        resolveRoot: { try DirectoryAccessLease.resolvePersistent($0) },
        scan: { url, officialSource in
            try LocalSongScanner.scan(root: url, officialSource: officialSource)
        },
        fingerprint: { try LocalFileVerifier.fingerprint(url: $0) },
        transferBookmark: { try $0.makeTransferBookmark() },
        save: nil)
}

final class LocalSongLibraryController {
    private let store: LocalSongStore
    private let library: () -> PerformanceLibrary?
    /// Narrow access to the ACCEPTED official source binding. Used ONLY to exclude that
    /// directory's exact reviewed files from a local scan; nil when no official root is accepted.
    private let officialSourceRoot: () -> URL?
    /// Called on the main thread with the newest authoritative catalog plus an optional
    /// actionable message (store error, scan failure, missing/changed root).
    private let onCatalog: (LocalSongCatalog, String?) -> Void
    private let seams: LocalSongLibrarySeams
    /// Nil disables monitoring (regression). Production creates the ordinary Platform monitor.
    private let makeMonitor: (URL, DirectoryAccessLease?, @escaping (DirectoryChange) -> Void)
        -> DirectoryChangeMonitor?

    private(set) var catalog = LocalSongCatalog()
    /// False after an unsupported/corrupt store load: the file must never be overwritten.
    private(set) var isWritable = true
    private(set) var loadMessage: String?

    /// One scan task AND one scan generation PER ROOT. A global generation would let the last
    /// started root's scan supersede every other root's result.
    private var scanTasks: [String: Task<Void, Never>] = [:]
    private var scanGenerations: [String: UUID] = [:]
    private var pendingRescans: Set<String> = []
    private var monitors: [String: DirectoryChangeMonitor] = [:]
    /// Retains the resolved authorization for a root for as long as its monitor and scans live.
    private var rootLeases: [String: DirectoryAccessLease] = [:]
    private(set) var isScanning = false

    private var playbackTask: Task<Void, Never>?
    private var playbackGeneration = UUID()
    /// The track whose pending request a version change would invalidate. Renaming never
    /// invalidates; selecting another file of the same track does.
    private var pendingVersionTrackID: String?
    /// The root a pending request belongs to, so an invalidated root scan also drops its request.
    private var pendingPlaybackRootID: String?

    init(store: LocalSongStore = LocalSongStore(),
         library: @escaping () -> PerformanceLibrary?,
         seams: LocalSongLibrarySeams? = nil,
         makeMonitor: ((URL, DirectoryAccessLease?, @escaping (DirectoryChange) -> Void)
            -> DirectoryChangeMonitor?)? = nil,
         officialSourceRoot: (() -> URL?)? = nil,
         onCatalog: @escaping (LocalSongCatalog, String?) -> Void) {
        self.store = store
        self.library = library
        self.officialSourceRoot = officialSourceRoot ?? { nil }
        self.onCatalog = onCatalog
        var resolved = seams ?? .production
        if resolved.save == nil {
            resolved.save = { [store] candidate in try store.save(candidate) }
        }
        self.seams = resolved
        self.makeMonitor = makeMonitor ?? { root, access, onChange in
            DirectoryChangeMonitor(root: root, access: access, onChange: onChange)
        }
    }

    deinit {
        playbackTask?.cancel()
        for task in scanTasks.values { task.cancel() }
        // DirectoryChangeMonitor is main-thread confined (start/stop/release). The controller is
        // owned by the main-thread AppDelegate, so ordinary release matches that ownership; a
        // stray off-main release defers monitor shutdown to the main queue instead of tripping
        // the monitor's main-thread precondition.
        let monitorsToStop = Array(monitors.values)
        if Thread.isMainThread {
            for monitor in monitorsToStop { monitor.stop() }
        } else {
            DispatchQueue.main.async {
                for monitor in monitorsToStop { monitor.stop() }
            }
        }
    }

    // MARK: Main-thread serialization

    /// Every state mutation, persistence publication, generation check and callback is serialized
    /// on the main thread. Scans/hashes run on detached workers and hand back through `@MainActor`.
    private func assertMainThread(_ operation: String) {
        assert(Thread.isMainThread,
               "LocalSongLibraryController.\(operation) must run on the main thread")
    }

    /// The one publication point for controller state changes.
    private func publish(_ message: String?) {
        assertMainThread("onCatalog")
        onCatalog(catalog, message)
    }

    // MARK: Load / persist

    /// Metadata-only load. A corrupt/unsupported store is preserved byte-for-byte and local
    /// writes are disabled until the user explicitly resolves it.
    func load() {
        assertMainThread("load")
        switch store.load() {
        case .empty:
            catalog = LocalSongCatalog()
            isWritable = true
            loadMessage = nil
            publish(nil)
        case .loaded(let loaded):
            catalog = loaded
            isWritable = true
            loadMessage = nil
            publish(nil)
        case .unsupported(let detail):
            isWritable = false
            loadMessage = "\(detail)；已保留原文件，未覆盖。请移走该文件后重新添加歌曲。"
            publish(loadMessage)
        case .corrupt(let detail):
            isWritable = false
            loadMessage = LocalSongError.corruptStore(detail).description
            publish(loadMessage)
        }
    }

    /// Atomic, transactional persist. The candidate becomes the committed in-memory state ONLY
    /// after the store write succeeds; on failure the previous state is retained and the error
    /// is surfaced so a caller can never report a success it did not get.
    @discardableResult
    private func persist(_ candidate: LocalSongCatalog) -> Bool {
        assertMainThread("persist")
        guard isWritable else {
            loadMessage = LocalSongError.storeWriteFailed("store is read-only").description
            publish(loadMessage)
            return false
        }
        do {
            if let save = seams.save {
                try save(candidate)
            } else {
                try store.save(candidate)
            }
            catalog = candidate
            return true
        } catch {
            loadMessage = (error as? LocalSongError)?.description ?? String(describing: error)
            publish(loadMessage)
            return false
        }
    }

    // MARK: Roots

    /// Explicit user selection of an authorized root. Selecting the SAME accepted directory again
    /// reuses its existing root id (and every track id/number/title/selection). A known identity
    /// conflict refuses to reuse or rebase the saved record.
    func addRoot(_ url: URL) {
        assertMainThread("addRoot")
        adoptRoot(url, automatic: false)
    }

    /// Automatic admission of a DISCOVERED known-package root (ADR-022 discovery). It uses the
    /// exact same transactional identity/numbering/selection transaction as an explicit Add Songs
    /// import, so a discovered import is indistinguishable from a manual one. Two extra guards
    /// keep the discovered path weaker than an explicit selection:
    ///  - a directory that is already a saved root (same path in any spelling) is left entirely to
    ///    the ordinary restore/rescan path, so a stale/unresolvable saved bookmark is preserved
    ///    and can never be silently replaced or duplicated by a discovered candidate;
    ///  - an existing reused root's saved bookmark/anchor is never rewritten from a discovered
    ///    path (only the in-memory scan authorization is refreshed when the root is not active).
    func admitAutoRoot(_ url: URL) {
        assertMainThread("admitAutoRoot")
        guard isWritable else { return }
        if savedRootMatches(url) { return }
        adoptRoot(url, automatic: true)
    }

    /// True when a saved root already names this directory, comparing every ordinary spelling so
    /// a temp-root `/var` ⇄ `/private/var` pair or a symlinked alias is not imported twice.
    private func savedRootMatches(_ url: URL) -> Bool {
        assertMainThread("savedRootMatches")
        let candidatePaths = Set([url.standardizedFileURL.path,
                                  url.resolvingSymlinksInPath().path])
        return catalog.roots.contains { root in
            let savedPaths = Set([root.displayPath,
                                  URL(fileURLWithPath: root.displayPath).standardizedFileURL.path,
                                  URL(fileURLWithPath: root.displayPath).resolvingSymlinksInPath().path])
            return !candidatePaths.isDisjoint(with: savedPaths)
        }
    }

    private func adoptRoot(_ url: URL, automatic: Bool) {
        assertMainThread("adoptRoot")
        guard isWritable else {
            if !automatic { publish(loadMessage) }
            return
        }
        do {
            let selected = try seams.authorizeRoot(url)
            let fresh = selected.lease.identitySnapshot(provenance: .explicitSelection)
            switch adoptionDecision(for: selected.lease, fresh: fresh) {
            case .reuse(let rootID):
                guard !automatic else {
                    // Never rewrite or substitute an existing saved record from a discovered path.
                    // Keep the SAVED authorization authoritative: re-run its own restore/scan path
                    // rather than activating the freshly discovered lease, so an invalid saved
                    // bookmark reports missing instead of silently falling back to the candidate.
                    if rootLeases[rootID] == nil && scanTasks[rootID] == nil {
                        resolveAndScan(rootID: rootID)
                    }
                    return
                }
                var candidate = catalog
                candidate.registerRoot(id: rootID, displayPath: selected.lease.url.path,
                                       bookmark: selected.persistentData,
                                       identity: continuityIdentity(rootID: rootID, fresh: fresh))
                guard persist(candidate) else { return }
                publish(nil)
                activate(rootID: rootID, lease: selected.lease)
            case .rejected(let message):
                publish(message)
            case nil:
                let id = "local.root.\(UUID().uuidString)"
                var candidate = catalog
                candidate.registerRoot(id: id, displayPath: selected.lease.url.path,
                                       bookmark: selected.persistentData,
                                       identity: DirectoryIdentityResolver.explicitSelection(fresh: fresh))
                guard persist(candidate) else { return }
                // Minimal generic progress so a discovered import is never shown as a false
                // empty/ready local list; the completed scan replaces it through the ordinary
                // publication. The source folder label is deliberately not echoed.
                publish(automatic ? "正在自动加入已下载的歌曲…" : nil)
                activate(rootID: id, lease: selected.lease)
            }
        } catch {
            publish(LocalSongError.rootUnavailable(url.path).description)
        }
    }

    private enum RootAdoption {
        case reuse(String)
        /// Known conflict or an unverifiable stored anchor: never reuse/rebase. The message is
        /// surfaced verbatim; the saved bookmark, anchor and catalog are untouched.
        case rejected(String)
    }

    /// Compare the candidate directory against every saved root through the existing identity
    /// helpers. Same accepted directory (alias spelling, same-volume move) reuses the root id;
    /// a known conflict (saved anchor vs. the current object at that path) refuses to reuse or
    /// rebase the saved anchor.
    ///
    /// The historical anchor is ALWAYS consulted before any object/path shortcut: a bookmark that
    /// was rebased to another directory may resolve to this very selection, so object equality
    /// alone is never continuity evidence when a stored identity exists.
    private func adoptionDecision(for lease: DirectoryAccessLease,
                                  fresh: DirectoryIdentitySnapshot?) -> RootAdoption? {
        assertMainThread("adoptionDecision")
        for root in catalog.roots {
            let restored = root.bookmark.flatMap { try? seams.resolveRoot($0).lease }
            let sameObject = restored?.representsSameDirectory(as: lease)
            // A failed old grant does not erase its separate historical anchor. The fresh
            // explicit selection supplies access; only a consistent anchor can supply continuity.
            // Saved path equality is used solely to refuse an ambiguous replacement, never reuse.
            let savedURL = URL(fileURLWithPath: root.displayPath)
            let samePath = restored?.url.path == lease.url.path
                || savedURL.standardizedFileURL.path == lease.url.standardizedFileURL.path
                || savedURL.resolvingSymlinksInPath().path == lease.url.resolvingSymlinksInPath().path
            if let stored = root.identity {
                // No readable, comparable anchor: preserve it and never reuse on object equality.
                guard let anchor = stored.snapshotValue, let fresh else {
                    if sameObject == true || samePath {
                        return .rejected("已保存的目录身份记录无法确认；请重新选择目录，未覆盖原记录。")
                    }
                    continue
                }
                switch anchor.comparison(with: fresh) {
                case .consistent:
                    return .reuse(root.id)
                case .conflict(let reason):
                    if sameObject == true || samePath { return .rejected(identityConflictMessage(reason)) }
                case .unknown:
                    if sameObject == true || samePath {
                        return .rejected("已保存的目录身份无法确认（当前对象与历史记录不可比）。请重新选择目录，未覆盖原记录。")
                    }
                }
                continue
            }
            // No historical anchor at all: process-local object equality is the only evidence.
            if sameObject == true { return .reuse(root.id) }
            if samePath {
                return .rejected("已保存的目录身份无法确认；未覆盖原记录，也未重复添加歌曲。")
            }
        }
        return nil
    }

    /// The anchor to keep when a root is reused: an existing record is never replaced by a fresh
    /// tuple, including an unreadable/unknown-version record that must stay verbatim.
    private func continuityIdentity(rootID: String, fresh: DirectoryIdentitySnapshot?)
        -> StoredDirectoryIdentity? {
        if let existing = catalog.root(id: rootID)?.identity { return existing }
        return DirectoryIdentityResolver.explicitSelection(fresh: fresh)
    }

    private func identityConflictMessage(_ reason: DirectoryIdentityConflictReason) -> String {
        "该目录与已保存的记录不一致（\(reason.rawValue)）。请重新选择目录，未覆盖原记录。"
    }

    /// Restore every persisted root and rescan. A missing root becomes an unavailable record;
    /// an identity conflict is reported as changed rather than silently rebased.
    func restoreAndScan() {
        assertMainThread("restoreAndScan")
        for root in catalog.roots {
            resolveAndScan(rootID: root.id)
        }
    }

    func refresh() {
        assertMainThread("refresh")
        restoreAndScan()
    }

    private func resolveAndScan(rootID: String) {
        assertMainThread("resolveAndScan")
        guard let root = catalog.root(id: rootID), let bookmark = root.bookmark else {
            markRootMissing(rootID)
            return
        }
        do {
            let restored = try seams.resolveRoot(bookmark)
            let fresh = restored.lease.identitySnapshot(provenance: .legacyAdopted)
            let outcome = DirectoryIdentityResolver.resolve(stored: root.identity,
                                                            bookmark: bookmark, fresh: fresh)
            if let reason = outcome.conflictReason {
                invalidateScan(rootID)
                stopMonitoring(rootID)
                markRootMissing(rootID, message: identityConflictMessage(reason))
                return
            }
            if outcome.adoptAfterValidation,
               let identity = DirectoryIdentityResolver.adopt(fresh: fresh) {
                var candidate = catalog
                if let index = candidate.roots.firstIndex(where: { $0.id == rootID }) {
                    candidate.roots[index].identity = identity
                    if let renewed = restored.renewedData { candidate.roots[index].bookmark = renewed }
                }
                guard persist(candidate) else { return }
            } else if let renewed = restored.renewedData {
                var candidate = catalog
                if let index = candidate.roots.firstIndex(where: { $0.id == rootID }) {
                    candidate.roots[index].bookmark = renewed
                }
                guard persist(candidate) else { return }
            }
            activate(rootID: rootID, lease: restored.lease)
        } catch {
            stopMonitoring(rootID)
            markRootMissing(rootID, message: "歌曲目录当前不可用：\(root.displayPath)")
        }
    }

    private func markRootMissing(_ rootID: String, message: String? = nil) {
        assertMainThread("markRootMissing")
        invalidateScan(rootID)
        var candidate = catalog
        candidate.markRoot(id: rootID, missing: true)
        guard persist(candidate) else { return }
        publish(message)
        stopMonitoring(rootID)
        rootLeases[rootID] = nil
    }

    /// A root identity change (or explicit removal) invalidates any in-flight scan for that root
    /// so a late result can never publish over the newer committed state. A pending playback for
    /// that same root is invalidated too: its authorization can no longer be trusted.
    private func invalidateScan(_ rootID: String) {
        assertMainThread("invalidateScan")
        scanGenerations[rootID] = UUID()
        scanTasks[rootID]?.cancel()
        scanTasks[rootID] = nil
        pendingRescans.remove(rootID)
        isScanning = scanTasks.isEmpty == false
        if pendingPlaybackRootID == rootID { cancelPendingPlayback() }
    }

    /// Register (or replace) the root's monitor and start its scan. Monitoring is started before
    /// the scan so a change during the scan is not lost; it is event-driven only (no polling) and
    /// never touches the active session.
    private func activate(rootID: String, lease: DirectoryAccessLease) {
        assertMainThread("activate")
        rootLeases[rootID] = lease
        if let monitor = makeMonitor(lease.url, lease, { [weak self] change in
            self?.handleDirectoryChange(rootID: rootID, change: change)
        }) {
            monitors[rootID]?.stop()
            _ = monitor.start()
            monitors[rootID] = monitor
        }
        scan(rootID: rootID, lease: lease)
    }

    private func stopMonitoring(_ rootID: String) {
        assertMainThread("stopMonitoring")
        monitors[rootID]?.stop()
        monitors[rootID] = nil
    }

    /// A same-root directory event refreshes availability without stopping playback. Events are
    /// coalesced: while a scan is in flight the root is marked and rescanned once on completion.
    private func handleDirectoryChange(rootID: String, change: DirectoryChange) {
        assertMainThread("handleDirectoryChange")
        guard catalog.root(id: rootID) != nil else { return }
        // A root-path or volume change requires re-resolving the saved authorization (the
        // bookmark may follow a same-volume move); an ordinary in-root change only rescans.
        if change.rootChanged || change.volumeAvailable == false {
            resolveAndScan(rootID: rootID)
            return
        }
        if change.requiresFullScan || !change.paths.isEmpty {
            scheduleRescan(rootID: rootID)
        }
    }

    private func scheduleRescan(rootID: String) {
        assertMainThread("scheduleRescan")
        if scanTasks[rootID] != nil {
            pendingRescans.insert(rootID)
            return
        }
        if let lease = rootLeases[rootID] {
            scan(rootID: rootID, lease: lease)
        } else {
            resolveAndScan(rootID: rootID)
        }
    }

    // MARK: Scan

    private func scan(rootID: String, lease: DirectoryAccessLease) {
        assertMainThread("scan")
        guard let library = library() else {
            publish("演奏清单不可用，无法排除官方素材。")
            return
        }
        // Exclusion is by exact contained location under the ACCEPTED official source binding,
        // never by basename. With no accepted binding nothing is excluded and every scanned file
        // is preserved. The official root itself is never enumerated from here.
        let officialSource = officialSourceRoot().map {
            LocalSongOfficialSource.from(library, root: $0)
        }
        guard scanTasks[rootID] == nil else {
            pendingRescans.insert(rootID)
            return
        }
        startScan(rootID: rootID, lease: lease, officialSource: officialSource)
    }

    private func startScan(rootID: String, lease: DirectoryAccessLease,
                           officialSource: LocalSongOfficialSource?) {
        assertMainThread("startScan")
        let generation = UUID()
        scanGenerations[rootID] = generation
        isScanning = true
        let scanSeam = seams.scan
        scanTasks[rootID] = Task { @MainActor [weak self] in
            let detached = Task.detached(priority: .userInitiated) {
                [lease, officialSource, scanSeam] () -> Result<[LocalSongScannedGroup], Error> in
                // The lease stays alive until the detached scan actually returns.
                defer { withExtendedLifetime(lease) {} }
                do {
                    return .success(try scanSeam(lease.url, officialSource))
                } catch {
                    return .failure(error)
                }
            }
            // Cancellation reaches the detached child; the lease is retained until it returns.
            let result = await withTaskCancellationHandler {
                await detached.value
            } onCancel: {
                detached.cancel()
            }
            guard let self else { return }
            self.finishScan(rootID: rootID, generation: generation, result: result)
        }
    }

    private func finishScan(rootID: String, generation: UUID,
                            result: Result<[LocalSongScannedGroup], Error>) {
        assertMainThread("finishScan")
        // A newer scan for this root (or a root identity change) owns the record now.
        guard scanGenerations[rootID] == generation, !Task.isCancelled else { return }
        scanTasks[rootID] = nil
        isScanning = scanTasks.isEmpty == false
        switch result {
        case .success(let groups):
            var candidate = catalog
            candidate.markRoot(id: rootID, missing: false)
            _ = candidate.applyScan(rootID: rootID, groups: groups)
            // Unchanged metadata is already committed. Rewriting it would create another
            // directory event when the selected root contains the catalog itself. Keep any
            // existing error visible, and still drain a pending rescan below.
            if candidate != catalog, persist(candidate) {
                publish(nil)
            }
        case .failure(let error):
            var candidate = catalog
            candidate.markRoot(id: rootID, missing: true)
            if persist(candidate) {
                publish((error as? LocalSongError)?.description ?? String(describing: error))
            }
        }
        if pendingRescans.remove(rootID) != nil, let lease = rootLeases[rootID] {
            scan(rootID: rootID, lease: lease)
        }
    }

    // MARK: Edits

    func rename(trackID: String, to title: String) {
        assertMainThread("rename")
        do {
            var candidate = catalog
            try candidate.rename(trackID: trackID, to: title)
            if persist(candidate) { publish(nil) }
        } catch {
            publish((error as? LocalSongError)?.description ?? String(describing: error))
        }
    }

    /// Classification is metadata only, just like a rename; pending and active playback survive.
    func setClassification(trackID: String, classification: LocalSongClassification) {
        assertMainThread("setClassification")
        do {
            var candidate = catalog
            try candidate.setClassification(trackID: trackID, classification: classification)
            if persist(candidate) { publish(nil) }
        } catch {
            publish((error as? LocalSongError)?.description ?? String(describing: error))
        }
    }

    /// Selecting another version of the track whose request is still being prepared invalidates
    /// that pending request. Renaming is a label edit and never affects playback intent.
    func selectFile(trackID: String, fileID: String) {
        assertMainThread("selectFile")
        if pendingVersionTrackID == trackID { cancelPendingPlayback() }
        do {
            var candidate = catalog
            try candidate.selectFile(trackID: trackID, fileID: fileID)
            if persist(candidate) { publish(nil) }
        } catch {
            publish((error as? LocalSongError)?.description ?? String(describing: error))
        }
    }

    // MARK: Playback identity

    /// Hash and record the ONE selected file BEFORE any start request is produced. The root's
    /// saved identity is enforced before the selected file is read AND re-checked against the
    /// currently saved authorization immediately before the fingerprint is persisted, so a
    /// directory replaced during hashing can never store a false baseline or send a grant.
    /// Late work is dropped when the generation changed (new selection/stop/root change/version
    /// change). A changed file, a known root conflict or a failed save is a typed failure — the
    /// request is never built and no saved path is used as a fallback.
    func preparePlayback(trackID: String, fileID: String, expectedBinding: PerformanceFileBinding? = nil,
                         completion: @escaping (Result<LocalPlaybackGrant, Error>) -> Void) {
        assertMainThread("preparePlayback")
        cancelPendingPlayback()
        let generation = UUID()
        playbackGeneration = generation
        guard let track = catalog.track(id: trackID),
              let root = catalog.root(id: track.rootID),
              let bookmark = root.bookmark,
              let file = track.files.first(where: { $0.id == fileID }) else {
            completion(.failure(LocalSongError.unknownFile(fileID)))
            return
        }
        if let expectedBinding, file.relativePath != expectedBinding.relativePath {
            completion(.failure(LocalSongError.invalidBinding("retained file path changed")))
            return
        }
        pendingVersionTrackID = trackID
        pendingPlaybackRootID = track.rootID
        playbackTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // 1) Resolve the saved authorization and enforce the saved identity BEFORE reading.
            let resolved: (lease: DirectoryAccessLease, renewedData: Data?)
            do {
                resolved = try self.seams.resolveRoot(bookmark)
            } catch {
                self.finishPlaybackFailure(generation: generation, completion: completion,
                                           error: LocalSongError.rootUnavailable(root.displayPath))
                return
            }
            let lease = resolved.lease
            let fresh = lease.identitySnapshot(provenance: .legacyAdopted)
            let outcome = DirectoryIdentityResolver.resolve(stored: root.identity, bookmark: bookmark,
                                                            fresh: fresh)
            if let reason = outcome.conflictReason {
                self.finishPlaybackFailure(generation: generation, completion: completion,
                    error: LocalSongError.invalidBinding("root identity conflict \(reason.rawValue)"))
                return
            }
            // A pending legacy adoption must be committed BEFORE the read; a failed save returns.
            if outcome.adoptAfterValidation, let adopted = DirectoryIdentityResolver.adopt(fresh: fresh) {
                var adoptedCatalog = self.catalog
                if let index = adoptedCatalog.roots.firstIndex(where: { $0.id == root.id }) {
                    adoptedCatalog.roots[index].identity = adopted
                    if let renewed = resolved.renewedData { adoptedCatalog.roots[index].bookmark = renewed }
                }
                guard self.persist(adoptedCatalog) else {
                    self.finishPlaybackFailure(generation: generation, completion: completion,
                        error: LocalSongError.storeWriteFailed("root identity not recorded"))
                    return
                }
            }

            // 2) Hash exactly the selected file on a detached worker under the retained lease.
            let fingerprintSeam = self.seams.fingerprint
            let relativePath = file.relativePath
            let detached = Task.detached(priority: .userInitiated) { [lease] () -> Result<LocalFileFingerprint, Error> in
                // Keep the authorization alive until the hash returns.
                defer { withExtendedLifetime(lease) {} }
                do {
                    let url = try LocalFileVerifier.resolvedURL(relativePath: relativePath, root: lease.url)
                    return .success(try fingerprintSeam(url))
                } catch {
                    return .failure(error)
                }
            }
            let hashed = await withTaskCancellationHandler {
                await detached.value
            } onCancel: {
                detached.cancel()
            }
            guard self.playbackGeneration == generation, !Task.isCancelled else { return }
            switch hashed {
            case .failure(let error):
                self.finishPlaybackFailure(generation: generation, completion: completion, error: error)
            case .success(let fingerprint):
                if let expectedBinding,
                   fingerprint.sha256 != expectedBinding.sha256 || fingerprint.byteSize != expectedBinding.byteSize {
                    self.finishPlaybackFailure(generation: generation, completion: completion,
                        error: LocalSongError.invalidBinding("retained file fingerprint changed"))
                    return
                }
                // 3) Root continuity at ACTUAL start. Re-resolve the CURRENT saved bookmark and
                //    compare both the saved anchor and the freshly leased object immediately
                //    before persisting. A directory replaced during hashing fails here and no
                //    false baseline is stored.
                guard let currentRoot = self.catalog.root(id: track.rootID),
                      let currentBookmark = currentRoot.bookmark else {
                    self.finishPlaybackFailure(generation: generation, completion: completion,
                        error: LocalSongError.rootUnavailable(root.displayPath))
                    return
                }
                let current: (lease: DirectoryAccessLease, renewedData: Data?)
                do {
                    current = try self.seams.resolveRoot(currentBookmark)
                } catch {
                    self.finishPlaybackFailure(generation: generation, completion: completion,
                        error: LocalSongError.rootUnavailable(currentRoot.displayPath))
                    return
                }
                let currentFresh = current.lease.identitySnapshot(provenance: .legacyAdopted)
                let currentOutcome = DirectoryIdentityResolver.resolve(stored: currentRoot.identity,
                                                                       bookmark: currentBookmark,
                                                                       fresh: currentFresh)
                if let reason = currentOutcome.conflictReason {
                    self.finishPlaybackFailure(generation: generation, completion: completion,
                        error: LocalSongError.invalidBinding(
                            "root identity conflict after hashing \(reason.rawValue)"))
                    return
                }
                // The object hashed must still be the object the current authorization names.
                if current.lease.representsSameDirectory(as: lease) == false {
                    self.finishPlaybackFailure(generation: generation, completion: completion,
                        error: LocalSongError.invalidBinding("root directory replaced during hashing"))
                    return
                }
                // 4) Never rebaseline: an existing fingerprint must match, or this fails typed.
                var candidate = self.catalog
                do {
                    try candidate.setFingerprint(trackID: trackID, fileID: fileID,
                                                 sha256: fingerprint.sha256,
                                                 byteSize: fingerprint.byteSize)
                } catch {
                    self.finishPlaybackFailure(generation: generation, completion: completion, error: error)
                    return
                }
                if currentOutcome.adoptAfterValidation,
                   let adopted = DirectoryIdentityResolver.adopt(fresh: currentFresh),
                   let index = candidate.roots.firstIndex(where: { $0.id == currentRoot.id }) {
                    candidate.roots[index].identity = adopted
                    if let renewed = current.renewedData { candidate.roots[index].bookmark = renewed }
                }
                // Identity must be persisted BEFORE the request is handed to the Agent.
                guard self.persist(candidate) else {
                    self.finishPlaybackFailure(generation: generation, completion: completion,
                        error: LocalSongError.storeWriteFailed("identity not recorded"))
                    return
                }
                // Publish the committed fingerprint before handing off the grant. History and
                // transport eligibility read the UI's catalog projection, not this private copy.
                self.publish(nil)
                // The reference carries the CURRENT committed revision, after the successful
                // fingerprint save — never the pre-save revision.
                guard let committed = self.catalog.track(id: trackID),
                      committed.files.contains(where: { $0.id == fileID }) else {
                    self.finishPlaybackFailure(generation: generation, completion: completion,
                        error: LocalSongError.unknownFile(fileID))
                    return
                }
                // 5) The transfer grant comes from the CURRENT lease whose identity was just
                //    verified — never from the pre-hash lease.
                let transfer: Data
                do {
                    transfer = try self.seams.transferBookmark(current.lease)
                } catch {
                    self.finishPlaybackFailure(generation: generation, completion: completion,
                        error: LocalSongError.rootUnavailable(currentRoot.displayPath))
                    return
                }
                let reference = LocalPerformanceReference(trackID: trackID, fileID: fileID,
                                                          catalogRevision: self.catalog.catalogRevision)
                self.playbackTask = nil
                self.pendingVersionTrackID = nil
                self.pendingPlaybackRootID = nil
                completion(.success(LocalPlaybackGrant(
                    root: current.lease.url.path, transferBookmark: transfer, reference: reference,
                    binding: PerformanceFileBinding(relativePath: file.relativePath,
                                                    byteSize: fingerprint.byteSize,
                                                    sha256: fingerprint.sha256))))
            }
        }
    }

    /// Drop the pending request without delivering a late grant. A result that already lost its
    /// generation is never delivered.
    private func finishPlaybackFailure(generation: UUID,
                                       completion: @escaping (Result<LocalPlaybackGrant, Error>) -> Void,
                                       error: Error) {
        assertMainThread("finishPlaybackFailure")
        guard playbackGeneration == generation, !Task.isCancelled else { return }
        playbackTask = nil
        pendingVersionTrackID = nil
        pendingPlaybackRootID = nil
        completion(.failure(error))
    }

    func cancelPendingPlayback() {
        assertMainThread("cancelPendingPlayback")
        playbackGeneration = UUID()
        playbackTask?.cancel()
        playbackTask = nil
        pendingVersionTrackID = nil
        pendingPlaybackRootID = nil
    }

    /// Diagnostic helper only. The PRODUCTION start path (`preparePlayback`) performs its own
    /// root-continuity check and must never delegate to this as a substitute.
    func transferRoot(trackID: String) -> (root: String, bookmark: Data)? {
        assertMainThread("transferRoot")
        guard let track = catalog.track(id: trackID),
              let root = catalog.root(id: track.rootID), let bookmark = root.bookmark,
              let restored = try? seams.resolveRoot(bookmark) else { return nil }
        let fresh = restored.lease.identitySnapshot(provenance: .legacyAdopted)
        let outcome = DirectoryIdentityResolver.resolve(stored: root.identity, bookmark: bookmark,
                                                        fresh: fresh)
        if outcome.conflictReason != nil { return nil }
        guard let transfer = try? seams.transferBookmark(restored.lease) else { return nil }
        return (restored.lease.url.path, transfer)
    }

    /// Resolve an explicit local queue entry against the CURRENT catalog revision. Missing
    /// records stay missing — they are never replaced by another track/file.
    func resolvedReference(trackID: String, fileID: String) -> LocalPerformanceReference? {
        assertMainThread("resolvedReference")
        guard let track = catalog.track(id: trackID),
              track.files.contains(where: { $0.id == fileID }) else { return nil }
        return LocalPerformanceReference(trackID: trackID, fileID: fileID,
                                         catalogRevision: catalog.catalogRevision)
    }

    func track(id: String) -> LocalSongTrack? {
        assertMainThread("track")
        return catalog.track(id: id)
    }

    func rootDisplayPath(for track: LocalSongTrack) -> String? {
        assertMainThread("rootDisplayPath")
        return catalog.root(id: track.rootID)?.displayPath
    }
}
