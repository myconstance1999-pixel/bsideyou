// BSideControlApp — automatic SONG-resource discovery (ADR-022 extension). The owner's ordinary
// library must find the already-downloaded local song package without a manual Add Songs click or
// an explicit official-folder selection. This helper only PROPOSES a bounded plan; the actual
// official bind goes through the existing PerformanceDirectoryController strict catalog scan and
// the actual local import goes through LocalSongLibraryController's ordinary transaction, so the
// discovery step never owns identity, numbering, selection or persistence.
//
// Bounded and metadata-only: the reviewed known package locations resolved under the OS Downloads
// directory, their immediate layout markers, and the existing reviewed official manifest metadata
// gate. It never lists unrelated Downloads folders, never walks the tree recursively, never
// watches anything, never hashes or decodes media, and never moves/deletes a file. The saved
// official binding and saved local roots stay authoritative: this helper never rebinds or rebases
// them, and it can only offer an official candidate when no saved binding exists.
//
// Threading matches the other controllers: `discover()`/`cancel()` and the callbacks run on the
// main thread, while the bounded metadata probes run on a detached worker.
import Foundation
import BSideCore
import BSidePlatform

/// What automatic discovery found. `official` is offered only when no official binding is saved;
/// `extras` are the known package's ordinary local roots, admitted through the same transactional
/// import an explicit Add Songs selection uses. `inaccessible` records known locations that could
/// not be read at all (for example an OS permission denial) so a denial is never silently
/// converted into a false "no resource / ready" state.
struct SongResourceDiscoveryPlan: Equatable {
    var official: URL?
    var extras: [URL]
    var inaccessible: [URL]

    static let none = SongResourceDiscoveryPlan(official: nil, extras: [], inaccessible: [])
    var isEmpty: Bool { official == nil && extras.isEmpty }
}

/// Result of probing one directory. `absent` covers a genuinely missing/non-directory path;
/// `inaccessible` is retained separately so permission recovery messaging can be preserved.
enum SongResourceDirectoryState: Equatable {
    case present
    case absent
    case inaccessible
}

/// Injectable IO seams. Production probes the ordinary OS Downloads URL and the existing strict
/// manifest metadata gate. Regressions substitute tiny temp-directory seams so the real plan and
/// admission code runs without a security-scoped bookmark entitlement or real media.
struct SongResourceDiscoverySeams {
    /// The OS-configured Downloads directory (never a literal user path).
    var downloadsURL: () -> URL?
    /// Probe one exact candidate path. Never a directory listing.
    var directoryState: (URL) -> SongResourceDirectoryState
    /// Count of reviewed official variants that RESOLVE under `root` through the existing strict
    /// `PerformanceLibrary.refreshCandidates` metadata gates (size/readability, never a media
    /// hash). Zero means the directory is not this known official package.
    var officialAvailableVariants: (PerformanceLibrary, URL) throws -> Int
    /// The saved official binding PATH, when one exists. Discovery never replaces it.
    var savedOfficialRootPath: () -> String?

    static let production = SongResourceDiscoverySeams(
        downloadsURL: { FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first },
        directoryState: { AutomaticSongResourceDiscovery.directoryState($0) },
        officialAvailableVariants: { library, root in
            let refresh = try library.refreshCandidates(root: root, previous: nil, changedPaths: nil)
            let total = library.manifest.tracks.reduce(0) { $0 + $1.variants.count }
            return max(0, total - refresh.snapshot.unavailable.count)
        },
        savedOfficialRootPath: { nil })
}

/// Narrow, testable handoff between a manual official selection and an asynchronous discovery
/// plan. A manual choice is authoritative: while it is pending, a stale automatic plan must never
/// rebind the official root or import from a superseded location.
final class SongResourceDiscoveryIntentGate {
    private(set) var isManualOfficialSelectionPending = false

    func noteManualOfficialSelection() { isManualOfficialSelectionPending = true }
    func settleManualOfficialSelection() { isManualOfficialSelectionPending = false }

    /// The plan that may actually be applied, or nil when a manual selection is in flight (or the
    /// plan carries nothing to do).
    func planToApply(_ plan: SongResourceDiscoveryPlan) -> SongResourceDiscoveryPlan? {
        guard !isManualOfficialSelectionPending, !plan.isEmpty else { return nil }
        return plan
    }
}

final class AutomaticSongResourceDiscovery {
    /// The reviewed known-package layout from the controller contract. These are RELATIVE layout
    /// components (`官方音乐`/`玩家上传音乐` are the package markers, `Olivia Lin`/`Olivia` the
    /// known package and its alternate source): they are resolved under the OS Downloads URL, so
    /// no OS account name and no absolute path is ever embedded in the source.
    static let knownPackageFolder = "Olivia Lin"
    static let officialDirectoryName = "官方音乐"
    static let extraDirectoryName = "玩家上传音乐"
    static let alternateOfficialFolder = "Olivia"

    private let seams: SongResourceDiscoverySeams
    private let library: () -> PerformanceLibrary?
    private let onPlan: (SongResourceDiscoveryPlan) -> Void
    private let onFailure: (String) -> Void

    private var task: Task<Void, Never>?
    private var generation = UUID()
    private(set) var isDiscovering = false

    init(seams: SongResourceDiscoverySeams = .production,
         library: @escaping () -> PerformanceLibrary?,
         onPlan: @escaping (SongResourceDiscoveryPlan) -> Void,
         onFailure: @escaping (String) -> Void) {
        self.seams = seams
        self.library = library
        self.onPlan = onPlan
        self.onFailure = onFailure
    }

    deinit { task?.cancel() }

    /// Start one bounded discovery pass. A previous pass is superseded immediately; its late
    /// result can never deliver a plan. No-op when the library or the Downloads URL is unavailable,
    /// which preserves the normal empty/manual state without a modal.
    func discover() {
        assert(Thread.isMainThread, "AutomaticSongResourceDiscovery.discover must run on the main thread")
        cancel()
        guard let library = library(), let downloads = seams.downloadsURL() else { return }
        let saved = seams.savedOfficialRootPath().map { URL(fileURLWithPath: $0) }
        let seams = self.seams
        let generation = UUID()
        self.generation = generation
        isDiscovering = true
        task = Task { @MainActor [weak self] in
            let detached = Task.detached(priority: .utility) {
                () -> Result<SongResourceDiscoveryPlan, Error> in
                do {
                    return .success(try Self.makePlan(library: library, downloads: downloads,
                                                      savedOfficialRoot: saved, seams: seams))
                } catch {
                    return .failure(error)
                }
            }
            let result = await withTaskCancellationHandler {
                await detached.value
            } onCancel: {
                detached.cancel()
            }
            guard let self, self.generation == generation, !Task.isCancelled else { return }
            self.task = nil
            self.isDiscovering = false
            guard case .success(let plan) = result else { return }
            self.onPlan(plan)
            // Report an unreadable known location after applying whatever is accessible, so a
            // permission denial is visible instead of a silent empty/ready library.
            if !plan.inaccessible.isEmpty {
                self.onFailure("无法自动读取已下载的歌曲目录；可使用“添加歌曲”手动选择目录。")
            }
        }
    }

    func cancel() {
        assert(Thread.isMainThread, "AutomaticSongResourceDiscovery.cancel must run on the main thread")
        generation = UUID()
        task?.cancel()
        task = nil
        isDiscovering = false
    }

    // MARK: Bounded plan

    /// Build the discovery plan by probing ONLY the exact reviewed known locations. Pure URL work
    /// plus the injected metadata seam: no listing, no UI, no persistence, no media payload access.
    /// Deterministic for the same inputs and cancellation-checked before every candidate operation.
    static func makePlan(library: PerformanceLibrary, downloads: URL, savedOfficialRoot: URL?,
                         seams: SongResourceDiscoverySeams) throws -> SongResourceDiscoveryPlan {
        let packageParent = downloads.appendingPathComponent(knownPackageFolder, isDirectory: true)
        let preferredOfficial = packageParent.appendingPathComponent(officialDirectoryName,
                                                                     isDirectory: true)
        let knownExtra = packageParent.appendingPathComponent(extraDirectoryName, isDirectory: true)
        let alternate = downloads.appendingPathComponent(alternateOfficialFolder, isDirectory: true)

        var inaccessible: [URL] = []
        func present(_ url: URL) -> Bool {
            switch seams.directoryState(url) {
            case .present: return true
            case .absent: return false
            case .inaccessible: inaccessible.append(url); return false
            }
        }
        func availability(_ url: URL) -> Int {
            do {
                return try seams.officialAvailableVariants(library, url)
            } catch {
                if isPermissionDenied(error) { inaccessible.append(url) }
                return 0
            }
        }

        // Official preference: the complete known package's own official directory first; the
        // reviewed alternate source only when no preferred candidate is valid.
        try Task.checkCancellation()
        var official: URL?
        if savedOfficialRoot == nil {
            if present(preferredOfficial), availability(preferredOfficial) > 0 {
                official = preferredOfficial
            } else {
                try Task.checkCancellation()
                if present(alternate), availability(alternate) > 0 { official = alternate }
            }
        }

        // Extra roots are INDEPENDENT of official presence, readability, metadata validity or
        // playback: a known package's local sibling is imported under its own grant.
        var extras: [URL] = []
        try Task.checkCancellation()
        if present(knownExtra) { extras.append(knownExtra) }
        if let saved = savedOfficialRoot {
            try Task.checkCancellation()
            let savedExtra: URL?
            if saved.lastPathComponent == officialDirectoryName {
                // The saved official binding is the known package's own 官方音乐 directory.
                savedExtra = saved.deletingLastPathComponent()
                    .appendingPathComponent(extraDirectoryName, isDirectory: true)
            } else if present(saved.appendingPathComponent(officialDirectoryName, isDirectory: true))
                        || present(saved.appendingPathComponent(extraDirectoryName, isDirectory: true)) {
                // A saved package root that explicitly carries these marker children.
                savedExtra = saved.appendingPathComponent(extraDirectoryName, isDirectory: true)
            } else {
                savedExtra = nil
            }
            if let savedExtra, !samePath(savedExtra, knownExtra), present(savedExtra) {
                extras.append(savedExtra)
            }
        }
        var seen = Set<String>()
        let uniqueExtras = extras.filter { seen.insert($0.resolvingSymlinksInPath().path).inserted }
        return SongResourceDiscoveryPlan(official: official, extras: uniqueExtras,
                                         inaccessible: inaccessible)
    }

    private static func samePath(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.resolvingSymlinksInPath().path == rhs.resolvingSymlinksInPath().path
    }

    // MARK: Filesystem probes

    static func directoryState(_ url: URL) -> SongResourceDirectoryState {
        do {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { return .absent }
            return .present
        } catch {
            return isPermissionDenied(error) ? .inaccessible : .absent
        }
    }

    static func isPermissionDenied(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain {
            switch CocoaError.Code(rawValue: error.code) {
            case .fileReadNoPermission, .fileWriteNoPermission: return true
            default: break
            }
        }
        if error.domain == NSPOSIXErrorDomain {
            return error.code == Int(EACCES) || error.code == Int(EPERM)
        }
        return false
    }
}
