// BSideControlApp — discovery/admission regression for the automatic song-resource slice.
// It drives the REAL AutomaticSongResourceDiscovery plan, the REAL strict official metadata gate
// (`PerformanceLibrary.refreshCandidates`) and the REAL LocalSongLibraryController transaction
// against tiny temp-root fixtures, so ordering/identity/idempotence are exercised without a
// security-scoped bookmark entitlement, the Agent, a player or any real media payload.
import Foundation
import BSideCore
import BSidePlatform

private func discoveryFixtureRoot(_ label: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("bside-discovery-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func discoveryWrite(_ url: URL, bytes: Int, fill: UInt8 = 7) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try Data(repeating: fill, count: bytes).write(to: url)
}

/// The exact reviewed known locations, resolved under the injected Downloads URL exactly like
/// production resolves them under the OS Downloads URL (relative components only).
private func discoveryKnownPaths(_ downloads: URL)
    -> (package: URL, official: URL, extra: URL, alternate: URL) {
    let package = downloads.appendingPathComponent(
        AutomaticSongResourceDiscovery.knownPackageFolder, isDirectory: true)
    return (package,
            package.appendingPathComponent(AutomaticSongResourceDiscovery.officialDirectoryName,
                                           isDirectory: true),
            package.appendingPathComponent(AutomaticSongResourceDiscovery.extraDirectoryName,
                                           isDirectory: true),
            downloads.appendingPathComponent(AutomaticSongResourceDiscovery.alternateOfficialFolder,
                                             isDirectory: true))
}

/// A tiny but genuinely REVIEWED manifest: the same shape the bundled catalog uses (one pianoSolo
/// track with daylight/sunset/night variants) so the real strict validation and eligibility gates
/// run, while the fixture files stay a few bytes instead of hundreds of megabytes.
private func discoverySyntheticLibrary() throws -> PerformanceLibrary {
    func variant(_ key: String, _ path: String, _ lighting: String) -> String {
        let digest = String(repeating: "a", count: 64)
        return """
        {"id":"olivia.performance.synth.one.variant.\(key)","relativePath":"\(path)",
         "lighting":"\(lighting)","presentation":"sidePerformance","byteSize":16,"sha256":"\(digest)"}
        """
    }
    let json = """
    {"schemaVersion":1,"sourceRevision":"discovery-regression","exclusions":[],
     "tracks":[{"id":"olivia.performance.synth.one","kind":"pianoSolo","title":"合成曲目",
       "subtitle":"Synth One","variants":[
         \(variant("a", "SynthWorkOne/a.mp4", "daylight")),
         \(variant("b", "SynthWorkOne/b.mp4", "sunset")),
         \(variant("c", "SynthWorkOne/c.mp4", "night"))]}]}
    """
    return try PerformanceLibrary(data: Data(json.utf8))
}

/// Write the reviewed variant files under a root. `category` models `官方音乐/ACG/...`; nil writes
/// the work-layout download (`<root>/<work>/<file>`). `limit` makes a deliberately incomplete copy.
private func discoveryWriteReviewedVariants(_ library: PerformanceLibrary, root: URL,
                                            category: String?, limit: Int? = nil) throws {
    var written = 0
    for variant in library.manifest.tracks.flatMap({ $0.variants }) {
        if let limit, written >= limit { break }
        let relative = category.map { "\($0)/\(variant.relativePath)" } ?? variant.relativePath
        try discoveryWrite(root.appendingPathComponent(relative), bytes: Int(variant.byteSize))
        written += 1
    }
}

private func discoverySeams(downloads: URL,
                            savedOfficial: URL? = nil,
                            directoryState: ((URL) -> SongResourceDirectoryState)? = nil,
                            availableDelay: TimeInterval = 0) -> SongResourceDiscoverySeams {
    var seams = SongResourceDiscoverySeams.production
    seams.downloadsURL = { downloads }
    seams.savedOfficialRootPath = { savedOfficial?.path }
    if let directoryState { seams.directoryState = directoryState }
    if availableDelay > 0 {
        let base = seams.officialAvailableVariants
        seams.officialAvailableVariants = { library, root in
            Thread.sleep(forTimeInterval: availableDelay)
            return try base(library, root)
        }
    }
    return seams
}

private func discoveryControllerSeams(store: LocalSongStore,
                                      authorizeError: Error? = nil,
                                      resolveOverride: ((Data) throws
                                          -> (lease: DirectoryAccessLease, renewedData: Data?))? = nil)
    -> LocalSongLibrarySeams {
    var seams = LocalSongLibrarySeams.production
    seams.authorizeRoot = { url in
        if let authorizeError { throw authorizeError }
        let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        return (try DirectoryAccessLease.resolveTransfer(data), data)
    }
    seams.resolveRoot = resolveOverride ?? { data in
        (try DirectoryAccessLease.resolveTransfer(data), nil)
    }
    seams.save = { try store.save($0) }
    return seams
}

private func discoveryController(store: LocalSongStore, library: PerformanceLibrary,
                                 officialSourceRoot: (() -> URL?)? = nil,
                                 authorizeError: Error? = nil,
                                 resolveOverride: ((Data) throws
                                     -> (lease: DirectoryAccessLease, renewedData: Data?))? = nil,
                                 onMessage: @escaping (String?) -> Void) -> LocalSongLibraryController {
    LocalSongLibraryController(
        store: store, library: { library },
        seams: discoveryControllerSeams(store: store, authorizeError: authorizeError,
                                        resolveOverride: resolveOverride),
        makeMonitor: { _, _, _ in nil },
        officialSourceRoot: officialSourceRoot,
        onCatalog: { _, message in onMessage(message) })
}

private func discoveryWait(timeout: TimeInterval = 6.0, until condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    return condition()
}

/// Compare URL spellings through their physical path: `contentsOfDirectory` may return the
/// `/private/var` spelling while the fixture was built under `/var`.
private func discoverySamePath(_ lhs: URL?, _ rhs: URL) -> Bool {
    guard let lhs else { return false }
    return lhs.resolvingSymlinksInPath().path == rhs.resolvingSymlinksInPath().path
}

private func discoverySamePaths(_ lhs: [URL], _ rhs: [URL]) -> Bool {
    lhs.map { $0.resolvingSymlinksInPath().path } == rhs.map { $0.resolvingSymlinksInPath().path }
}

/// Wait for the controller's bounded scan to publish at least `count` tracks.
private func controllerWaitForTracks(_ controller: LocalSongLibraryController, count: Int) -> Bool {
    discoveryWait { !controller.isScanning && controller.catalog.tracks.count >= count }
}

/// Fails the first N calls after a successful resolve, so an automatic reuse can be shown to fall
/// back to the SAVED restore path rather than a discovered lease.
private final class DiscoveryResolveGate {
    private let lease: DirectoryAccessLease
    private(set) var calls = 0
    init(lease: DirectoryAccessLease) { self.lease = lease }
    func resolve(_ data: Data) throws -> (lease: DirectoryAccessLease, renewedData: Data?) {
        calls += 1
        if calls >= 2 { throw LocalSongError.rootUnavailable("saved bookmark unavailable") }
        return (lease, nil)
    }
}

func runAutomaticSongResourceDiscoveryRegression(expect: (Bool, String) -> Void) {
    let library: PerformanceLibrary
    do { library = try discoverySyntheticLibrary() }
    catch {
        expect(false, "the synthetic reviewed library must build: \(error)")
        return
    }

    // 1) Fresh no-bindings startup discovery probes ONLY the exact known locations, offers the
    // complete package's official directory and admits its ordinary local sibling through the real
    // controller transaction. Unrelated Downloads folders are never enumerated.
    do {
        let downloads = try discoveryFixtureRoot("fresh")
        defer { try? FileManager.default.removeItem(at: downloads) }
        let known = discoveryKnownPaths(downloads)
        try discoveryWriteReviewedVariants(library, root: known.official, category: "ACG")
        try discoveryWrite(known.extra.appendingPathComponent("cat1/workA/one.mp4"), bytes: 20, fill: 1)
        try discoveryWrite(known.extra.appendingPathComponent("cat1/workB/two.mp4"), bytes: 24, fill: 2)
        // A large set of unrelated folders must be invisible to discovery.
        for index in 0..<12 {
            try discoveryWrite(downloads.appendingPathComponent("Unrelated\(index)/notes.txt"), bytes: 4)
        }
        try discoveryWrite(downloads.appendingPathComponent("Loose/film.mp4"), bytes: 4)

        let allowed = [known.official, known.extra, known.alternate]
        var probed: [URL] = []
        var unexpected: [URL] = []
        let seams = discoverySeams(downloads: downloads, directoryState: { url in
            probed.append(url)
            if !allowed.contains(where: { discoverySamePath($0, url) }) { unexpected.append(url) }
            return AutomaticSongResourceDiscovery.directoryState(url)
        })

        let store = LocalSongStore(url: downloads.appendingPathComponent("store/local-songs.json"))
        var messages: [String?] = []
        let controller = discoveryController(store: store, library: library,
                                             onMessage: { messages.append($0) })
        controller.load()
        var plans: [SongResourceDiscoveryPlan] = []
        var officialBinds: [URL] = []
        var failures: [String] = []
        var planOnMain = true
        let discovery = AutomaticSongResourceDiscovery(
            seams: seams, library: { library },
            onPlan: { plan in
                planOnMain = planOnMain && Thread.isMainThread
                plans.append(plan)
                if let official = plan.official { officialBinds.append(official) }
                for extraRoot in plan.extras { controller.admitAutoRoot(extraRoot) }
            },
            onFailure: { failures.append($0) })
        discovery.discover()
        expect(discoveryWait { !plans.isEmpty }, "bounded discovery produces a plan")
        expect(planOnMain, "the discovery plan is delivered on the main thread")
        expect(failures.isEmpty, "an accessible package produces no failure message")
        expect(unexpected.isEmpty,
               "discovery never enumerates an unrelated Downloads folder")
        expect(probed.contains { discoverySamePath($0, known.official) }
               && probed.contains { discoverySamePath($0, known.extra) },
               "discovery probes the known official and local locations")
        guard let plan = plans.last else { return }
        expect(discoverySamePath(plan.official, known.official),
               "the complete package's official directory is the preferred official candidate")
        expect(discoverySamePaths(plan.extras, [known.extra]),
               "the known package's ordinary local root is discovered separately")
        expect(discoverySamePaths(officialBinds, [known.official]),
               "the official candidate is offered through the existing official bind path")
        expect(controllerWaitForTracks(controller, count: 2),
               "the discovered extra root is imported through the real controller transaction")
        expect(controller.catalog.roots.count == 1 && controller.catalog.roots.first?.isMissing == false,
               "the discovered extra root registers exactly one available root")
        expect(messages.contains { $0 == "正在自动加入已下载的歌曲…" },
               "a discovered import surfaces generic progress instead of a false empty list")
        expect(!messages.contains { $0?.contains("玩家上传音乐") == true },
               "the transient automatic progress never echoes the source folder label")
        discovery.cancel()
    } catch {
        expect(false, "fresh discovery fixture failed: \(error)")
    }

    // 2) A saved official binding stays authoritative, and the absent/present local sibling is
    // discovered from the saved layout independently of any official bind or playback.
    do {
        let downloads = try discoveryFixtureRoot("saved")
        defer { try? FileManager.default.removeItem(at: downloads) }
        let known = discoveryKnownPaths(downloads)
        try discoveryWriteReviewedVariants(library, root: known.official, category: "古典")

        let absent = try AutomaticSongResourceDiscovery.makePlan(
            library: library, downloads: downloads, savedOfficialRoot: known.official,
            seams: discoverySeams(downloads: downloads, savedOfficial: known.official))
        expect(absent.official == nil,
               "a saved official binding is never rebound from a discovered candidate")
        expect(absent.extras.isEmpty, "an absent local sibling is not invented")

        try discoveryWrite(known.extra.appendingPathComponent("cat/work/one.mp4"), bytes: 20)
        let present = try AutomaticSongResourceDiscovery.makePlan(
            library: library, downloads: downloads, savedOfficialRoot: known.official,
            seams: discoverySeams(downloads: downloads, savedOfficial: known.official))
        expect(discoverySamePaths(present.extras, [known.extra]),
               "the known package sibling of a saved official binding is still discovered")

        // A stale/unrecognized saved binding is never replaced by the valid candidate path.
        let stale = downloads.appendingPathComponent("Missing/官方音乐", isDirectory: true)
        let stalePlan = try AutomaticSongResourceDiscovery.makePlan(
            library: library, downloads: downloads, savedOfficialRoot: stale,
            seams: discoverySeams(downloads: downloads, savedOfficial: stale))
        expect(stalePlan.official == nil,
               "an invalid saved official bookmark is not silently rebased to a candidate path")

        // A saved package root that carries the marker children still identifies its sibling.
        let savedPackage = downloads.appendingPathComponent("SavedPackage", isDirectory: true)
        let savedPackageOfficial = savedPackage.appendingPathComponent("官方音乐", isDirectory: true)
        let savedPackageExtra = savedPackage.appendingPathComponent("玩家上传音乐", isDirectory: true)
        try discoveryWrite(savedPackageOfficial.appendingPathComponent("placeholder.txt"), bytes: 2)
        try discoveryWrite(savedPackageExtra.appendingPathComponent("cat/work/one.mp4"), bytes: 20)
        let savedRootPlan = try AutomaticSongResourceDiscovery.makePlan(
            library: library, downloads: downloads, savedOfficialRoot: savedPackage,
            seams: discoverySeams(downloads: downloads, savedOfficial: savedPackage))
        expect(savedRootPlan.extras.contains { discoverySamePath($0, savedPackageExtra) },
               "a saved package root with marker children discovers its own local sibling")
    } catch {
        expect(false, "saved-official discovery fixture failed: \(error)")
    }

    // 3) The two official alternatives are deterministic: the preferred package directory wins
    // whenever it is valid, and the alternate source is used only when it is not.
    do {
        let downloads = try discoveryFixtureRoot("alternatives")
        defer { try? FileManager.default.removeItem(at: downloads) }
        let known = discoveryKnownPaths(downloads)
        try discoveryWriteReviewedVariants(library, root: known.official, category: "ACG")
        try discoveryWriteReviewedVariants(library, root: known.alternate, category: nil)

        let seams = discoverySeams(downloads: downloads)
        let first = try AutomaticSongResourceDiscovery.makePlan(
            library: library, downloads: downloads, savedOfficialRoot: nil, seams: seams)
        expect(discoverySamePath(first.official, known.official),
               "the preferred package official directory wins over the alternate source")
        let second = try AutomaticSongResourceDiscovery.makePlan(
            library: library, downloads: downloads, savedOfficialRoot: nil, seams: seams)
        expect(second == first, "the same inputs always produce the same deterministic plan")

        // Preferred present but with no matching reviewed variants falls to the alternate.
        try FileManager.default.removeItem(at: known.official)
        try FileManager.default.createDirectory(at: known.official, withIntermediateDirectories: true)
        let invalidPreferred = try AutomaticSongResourceDiscovery.makePlan(
            library: library, downloads: downloads, savedOfficialRoot: nil, seams: seams)
        expect(discoverySamePath(invalidPreferred.official, known.alternate),
               "an invalid preferred candidate falls back to the alternate official source")

        try FileManager.default.removeItem(at: known.official)
        try FileManager.default.removeItem(at: known.alternate)
        let none = try AutomaticSongResourceDiscovery.makePlan(
            library: library, downloads: downloads, savedOfficialRoot: nil, seams: seams)
        expect(none.official == nil, "no valid official candidate yields no official offer")
    } catch {
        expect(false, "official-alternative fixture failed: \(error)")
    }

    // 4) Repeated discovery/refresh is idempotent: the same root, ids, stable numbers, custom
    // title, selected version and a queued local reference never change.
    do {
        let downloads = try discoveryFixtureRoot("repeat")
        defer { try? FileManager.default.removeItem(at: downloads) }
        let known = discoveryKnownPaths(downloads)
        try discoveryWriteReviewedVariants(library, root: known.official, category: "ACG")
        try discoveryWrite(known.extra.appendingPathComponent("cat/work/one.mp4"), bytes: 20, fill: 1)
        try discoveryWrite(known.extra.appendingPathComponent("cat/work/two.mp4"), bytes: 28, fill: 2)

        let store = LocalSongStore(url: downloads.appendingPathComponent("store/local-songs.json"))
        let controller = discoveryController(store: store, library: library, onMessage: { _ in })
        controller.load()
        let seams = discoverySeams(downloads: downloads)
        let plan = try AutomaticSongResourceDiscovery.makePlan(
            library: library, downloads: downloads, savedOfficialRoot: nil, seams: seams)
        expect(discoverySamePaths(plan.extras, [known.extra]),
               "the repeat fixture discovers the extra root")
        controller.admitAutoRoot(known.extra)
        expect(controllerWaitForTracks(controller, count: 1), "the first automatic import scans")
        guard let track = controller.catalog.tracks.first, track.sortedFiles.count == 2,
              let secondFile = track.sortedFiles.last else {
            expect(false, "the repeat fixture must produce one track with two versions")
            return
        }
        controller.rename(trackID: track.id, to: "自动导入保留")
        controller.selectFile(trackID: track.id, fileID: secondFile.id)
        let rootID = controller.catalog.roots.first?.id
        let trackIDs = controller.catalog.tracks.map(\.id).sorted()
        let numbers = controller.catalog.tracks.map(\.number).sorted()
        let fileIDs = controller.catalog.tracks.flatMap { $0.files.map(\.id) }.sorted()
        let nextNumber = controller.catalog.nextNumber
        let selected = controller.catalog.tracks.first?.selectedFileID

        // A queued explicit local entry is part of the identity that must survive discovery.
        let entry = PerformanceQueueEntry(trackID: track.id, fileID: secondFile.id, mode: .watch)
        let configuration = PerformanceQueueConfiguration(entries: [entry])
        let decoded = try JSONDecoder().decode(
            PerformanceQueueConfiguration.self, from: JSONEncoder().encode(configuration))

        // A refresh path plus a repeated discovery + admission must not allocate or renumber.
        controller.restoreAndScan()
        expect(discoveryWait { !controller.isScanning }, "the refresh scan settles")
        controller.admitAutoRoot(known.extra)
        expect(discoveryWait { !controller.isScanning }, "the repeated automatic admission settles")
        expect(controller.catalog.roots.count == 1 && controller.catalog.roots.first?.id == rootID,
               "a repeated automatic import reuses the existing root id")
        expect(controller.catalog.tracks.map(\.id).sorted() == trackIDs,
               "a repeated automatic import keeps every track id")
        expect(controller.catalog.tracks.map(\.number).sorted() == numbers,
               "a repeated automatic import keeps every stable temporary number")
        expect(controller.catalog.tracks.flatMap { $0.files.map(\.id) }.sorted() == fileIDs,
               "a repeated automatic import keeps every file id")
        expect(controller.catalog.tracks.first?.customTitle == "自动导入保留",
               "a repeated automatic import keeps the custom title")
        expect(controller.catalog.tracks.first?.selectedFileID == selected,
               "a repeated automatic import keeps the selected version")
        expect(controller.catalog.nextNumber == nextNumber,
               "a repeated automatic import never allocates another number")
        expect(decoded.entries.first?.target == entry.target
               && controller.resolvedReference(trackID: track.id, fileID: secondFile.id) != nil,
               "a queued local reference still resolves after repeated discovery/refresh")
    } catch {
        expect(false, "repeat-idempotence fixture failed: \(error)")
    }

    // 5) No candidates: the normal empty/manual state is preserved with no admission and no nag.
    do {
        let downloads = try discoveryFixtureRoot("none")
        defer { try? FileManager.default.removeItem(at: downloads) }
        try discoveryWrite(downloads.appendingPathComponent("Unrelated/notes.txt"), bytes: 8)
        try discoveryWrite(downloads.appendingPathComponent("Loose/film.mp4"), bytes: 8)
        let known = discoveryKnownPaths(downloads)
        let allowed = [known.official, known.extra, known.alternate]
        var unexpected: [URL] = []
        let plan = try AutomaticSongResourceDiscovery.makePlan(
            library: library, downloads: downloads, savedOfficialRoot: nil,
            seams: discoverySeams(downloads: downloads, directoryState: { url in
                if !allowed.contains(where: { discoverySamePath($0, url) }) { unexpected.append(url) }
                return AutomaticSongResourceDiscovery.directoryState(url)
            }))
        expect(plan.isEmpty, "an unrelated Downloads layout yields no candidate")
        expect(unexpected.isEmpty, "no-candidate discovery probes no unrelated folder")
        let store = LocalSongStore(url: downloads.appendingPathComponent("store/local-songs.json"))
        var messages: [String?] = []
        let controller = discoveryController(store: store, library: library,
                                             onMessage: { messages.append($0) })
        controller.load()
        for extra in plan.extras { controller.admitAutoRoot(extra) }
        expect(controller.catalog.roots.isEmpty && controller.catalog.tracks.isEmpty,
               "no candidate leaves the ordinary empty/manual library untouched")
        expect(messages.allSatisfy { $0 == nil }, "no candidate produces no nagging message")
    } catch {
        expect(false, "no-candidate fixture failed: \(error)")
    }

    // 6) Extras are independent of official presence, validity, readability and playback.
    do {
        let downloads = try discoveryFixtureRoot("extras")
        defer { try? FileManager.default.removeItem(at: downloads) }
        let known = discoveryKnownPaths(downloads)
        try discoveryWrite(known.extra.appendingPathComponent("cat/work/one.mp4"), bytes: 20)

        // Extras only: the official directory is entirely absent.
        let extrasOnly = try AutomaticSongResourceDiscovery.makePlan(
            library: library, downloads: downloads, savedOfficialRoot: nil,
            seams: discoverySeams(downloads: downloads))
        expect(extrasOnly.official == nil && discoverySamePaths(extrasOnly.extras, [known.extra]),
               "a known local sibling is discovered even with no official directory at all")

        // Invalid official (present, no matching reviewed variants) but a valid local sibling.
        try FileManager.default.createDirectory(at: known.official, withIntermediateDirectories: true)
        let invalidOfficial = try AutomaticSongResourceDiscovery.makePlan(
            library: library, downloads: downloads, savedOfficialRoot: nil,
            seams: discoverySeams(downloads: downloads))
        expect(invalidOfficial.official == nil
               && discoverySamePaths(invalidOfficial.extras, [known.extra]),
               "an invalid official directory never blocks importing the known local sibling")

        // Denied official probe: the permission failure is preserved and the local sibling still
        // imports under its own grant.
        let deniedOfficial = try AutomaticSongResourceDiscovery.makePlan(
            library: library, downloads: downloads, savedOfficialRoot: nil,
            seams: discoverySeams(downloads: downloads, directoryState: { url in
                discoverySamePath(known.official, url) ? .inaccessible
                    : AutomaticSongResourceDiscovery.directoryState(url)
            }))
        expect(deniedOfficial.official == nil
               && discoverySamePaths(deniedOfficial.extras, [known.extra]),
               "a denied official probe still allows the known local sibling")
        expect(deniedOfficial.inaccessible.contains { discoverySamePath($0, known.official) },
               "a denied official probe keeps its permission information instead of reporting empty")

        // A denied automatic grant registers nothing and reports the ordinary recovery message.
        let store = LocalSongStore(url: downloads.appendingPathComponent("store/local-songs.json"))
        var messages: [String?] = []
        let controller = discoveryController(
            store: store, library: library, authorizeError: CocoaError(.fileReadNoPermission),
            onMessage: { messages.append($0) })
        controller.load()
        controller.admitAutoRoot(known.extra)
        expect(controller.catalog.roots.isEmpty && controller.catalog.tracks.isEmpty,
               "a denied automatic grant registers no root")
        expect(messages.contains { $0?.contains("不可用") == true },
               "a denied automatic grant surfaces the ordinary recovery message")
    } catch {
        expect(false, "extras-independence fixture failed: \(error)")
    }

    // 7) An invalid saved local bookmark is preserved: the same directory is never re-admitted as
    // a second root or silently rebased to the discovered path.
    do {
        let downloads = try discoveryFixtureRoot("savedlocal")
        defer { try? FileManager.default.removeItem(at: downloads) }
        let known = discoveryKnownPaths(downloads)
        try discoveryWrite(known.extra.appendingPathComponent("cat/work/one.mp4"), bytes: 20)
        let store = LocalSongStore(url: downloads.appendingPathComponent("store/local-songs.json"))
        var seeded = LocalSongCatalog()
        seeded.registerRoot(id: "root-stale", displayPath: known.extra.path,
                            bookmark: Data([0x00, 0x01]), identity: nil)
        try store.save(seeded)
        let controller = discoveryController(store: store, library: library, onMessage: { _ in })
        controller.load()
        controller.admitAutoRoot(known.extra)
        _ = discoveryWait(timeout: 0.5) { controller.catalog.roots.count > 1 }
        expect(controller.catalog.roots.count == 1,
               "a saved root at the discovered path is never duplicated")
        expect(controller.catalog.roots.first?.id == "root-stale"
               && controller.catalog.roots.first?.bookmark == Data([0x00, 0x01]),
               "the stale saved bookmark is preserved, never rebased to the candidate")
        expect(controller.catalog.tracks.isEmpty,
               "no track is published from an automatic re-admission of a stale saved root")
    } catch {
        expect(false, "invalid-saved-bookmark fixture failed: \(error)")
    }

    // 8) The automatic reuse branch keeps the SAVED authorization authoritative: when the saved
    // bookmark cannot be resolved at scan time, the discovered lease is NOT used as a fallback.
    do {
        let downloads = try discoveryFixtureRoot("reuseauth")
        defer { try? FileManager.default.removeItem(at: downloads) }
        let known = discoveryKnownPaths(downloads)
        let fileURL = known.extra.appendingPathComponent("cat/work/one.mp4")
        try discoveryWrite(fileURL, bytes: 20)
        let bookmark = try known.extra.bookmarkData(options: [], includingResourceValuesForKeys: nil,
                                                    relativeTo: nil)
        let savedLease = try DirectoryAccessLease.resolveTransfer(bookmark)
        let store = LocalSongStore(url: downloads.appendingPathComponent("store/local-songs.json"))
        var seeded = LocalSongCatalog()
        // A saved record reached through an alias spelling: the discovered path does not match the
        // record's display path, so discovery reaches the identity-reuse branch.
        seeded.registerRoot(id: "root-alias", displayPath: "/synthetic/alias-path",
                            bookmark: bookmark, identity: nil)
        try store.save(seeded)
        let gate = DiscoveryResolveGate(lease: savedLease)
        var scanCalls = 0
        var controllerSeams = discoveryControllerSeams(store: store, resolveOverride: gate.resolve)
        let baseScan = controllerSeams.scan
        controllerSeams.scan = { url, officialSource in
            scanCalls += 1
            return try baseScan(url, officialSource)
        }
        var messages: [String?] = []
        let controller = LocalSongLibraryController(
            store: store, library: { library }, seams: controllerSeams,
            makeMonitor: { _, _, _ in nil },
            onCatalog: { _, message in messages.append(message) })
        controller.load()
        controller.admitAutoRoot(known.extra)
        expect(discoveryWait { controller.catalog.roots.first?.isMissing == true },
               "a saved authorization that fails to resolve marks the root unavailable")
        expect(gate.calls >= 2,
               "the automatic reuse re-ran the SAVED restore path after the identity check")
        expect(scanCalls == 0,
               "the discovered lease is never used to scan around a failed saved restore")
        expect(controller.catalog.roots.count == 1 && controller.catalog.roots.first?.id == "root-alias",
               "the failed saved restore never creates a second root")
        expect(controller.catalog.tracks.isEmpty,
               "the failed saved restore publishes no track from the discovered lease")
        expect(messages.contains { $0?.contains("不可用") == true },
               "the failed saved restore surfaces the ordinary recovery message")
    } catch {
        expect(false, "restored-authorization fixture failed: \(error)")
    }

    // 9) A corrupt local store stays byte-for-byte untouched and non-writable even when discovery
    // finds a real candidate.
    do {
        let downloads = try discoveryFixtureRoot("corrupt")
        defer { try? FileManager.default.removeItem(at: downloads) }
        let known = discoveryKnownPaths(downloads)
        try discoveryWrite(known.extra.appendingPathComponent("cat/work/one.mp4"), bytes: 20)
        let storeURL = downloads.appendingPathComponent("store/local-songs.json")
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let corruptBytes = Data("{not a catalog".utf8)
        try corruptBytes.write(to: storeURL)
        let store = LocalSongStore(url: storeURL)
        let controller = discoveryController(store: store, library: library, onMessage: { _ in })
        controller.load()
        expect(controller.isWritable == false, "a corrupt store disables local writes")
        controller.admitAutoRoot(known.extra)
        _ = discoveryWait(timeout: 0.5) { !controller.catalog.roots.isEmpty }
        expect(controller.catalog.roots.isEmpty, "a corrupt store admits no discovered root")
        expect(try Data(contentsOf: storeURL) == corruptBytes,
               "the corrupt store is never overwritten by automatic discovery")
    } catch {
        expect(false, "corrupt-store fixture failed: \(error)")
    }

    // 10) A same-named file outside the accepted official directory is preserved: exclusion is by
    // exact contained location, never by basename.
    do {
        let downloads = try discoveryFixtureRoot("samename")
        defer { try? FileManager.default.removeItem(at: downloads) }
        let known = discoveryKnownPaths(downloads)
        try discoveryWriteReviewedVariants(library, root: known.official, category: "ACG")
        try discoveryWrite(known.extra.appendingPathComponent("cat/work/a.mp4"), bytes: 16, fill: 3)
        try discoveryWrite(known.extra.appendingPathComponent("cat/work/one.mp4"), bytes: 20, fill: 4)
        let store = LocalSongStore(url: downloads.appendingPathComponent("store/local-songs.json"))
        let controller = discoveryController(store: store, library: library,
                                             officialSourceRoot: { known.official }, onMessage: { _ in })
        controller.load()
        controller.admitAutoRoot(known.extra)
        expect(discoveryWait { !controller.catalog.tracks.isEmpty && !controller.isScanning },
               "the same-name extra root is scanned")
        let basenames = controller.catalog.tracks.flatMap { $0.files.map(\.basename) }.sorted()
        expect(basenames == ["a.mp4", "one.mp4"],
               "a reviewed basename elsewhere is preserved, never treated as official duplication")
    } catch {
        expect(false, "same-name fixture failed: \(error)")
    }

    // 11) Cancellation and late callbacks: a superseded or cancelled discovery pass never delivers
    // a plan, and a slow pass still delivers on the main thread.
    do {
        let downloads = try discoveryFixtureRoot("cancel")
        defer { try? FileManager.default.removeItem(at: downloads) }
        let known = discoveryKnownPaths(downloads)
        try discoveryWrite(known.extra.appendingPathComponent("cat/work/one.mp4"), bytes: 20)
        let seams = discoverySeams(downloads: downloads, availableDelay: 0.25)
        var delivered = 0
        var deliveredOnMain = true
        let discovery = AutomaticSongResourceDiscovery(
            seams: seams, library: { library },
            onPlan: { _ in
                delivered += 1
                deliveredOnMain = deliveredOnMain && Thread.isMainThread
            },
            onFailure: { _ in })
        discovery.discover()
        discovery.cancel()
        _ = discoveryWait(timeout: 1.2) { delivered > 0 }
        expect(delivered == 0, "a cancelled discovery pass never delivers a late plan")

        discovery.discover()
        expect(discoveryWait { delivered == 1 }, "a later discovery pass delivers exactly one plan")
        expect(delivered == 1, "a cancelled task cannot deliver a second plan")
        expect(deliveredOnMain, "the delivered plan is always on the main thread")
        discovery.cancel()
    } catch {
        expect(false, "cancellation fixture failed: \(error)")
    }

    // 12) A manual official choice wins over a late automatic plan. The narrow production intent
    // gate drops a stale plan while a manual selection is pending, and the manual-ready event can
    // start a new pass with the current saved binding.
    do {
        let downloads = try discoveryFixtureRoot("intent")
        defer { try? FileManager.default.removeItem(at: downloads) }
        let known = discoveryKnownPaths(downloads)
        try discoveryWrite(known.extra.appendingPathComponent("cat/work/one.mp4"), bytes: 20)
        let seams = discoverySeams(downloads: downloads, availableDelay: 0.2)
        let gate = SongResourceDiscoveryIntentGate()
        let plan = SongResourceDiscoveryPlan(official: known.official, extras: [known.extra],
                                             inaccessible: [])
        expect(gate.planToApply(plan) != nil,
               "an automatic plan applies while no manual selection is pending")
        gate.noteManualOfficialSelection()
        expect(gate.planToApply(plan) == nil,
               "a late automatic plan is dropped while a manual official selection is pending")
        expect(gate.planToApply(.none) == nil, "an empty plan is never applied")
        gate.settleManualOfficialSelection()
        expect(gate.planToApply(plan) != nil,
               "the manual-ready event allows the next automatic discovery pass to apply")

        // The same handoff through the real controller/AppDelegate-shaped application closure.
        var applied: [SongResourceDiscoveryPlan] = []
        let discovery = AutomaticSongResourceDiscovery(
            seams: seams, library: { library },
            onPlan: { plan in
                if let plan = gate.planToApply(plan) { applied.append(plan) }
            },
            onFailure: { _ in })
        gate.noteManualOfficialSelection()
        discovery.discover()
        discovery.cancel()  // the manual selection cancels the in-flight automatic pass
        _ = discoveryWait(timeout: 1.0) { !applied.isEmpty }
        expect(applied.isEmpty,
               "a cancelled automatic pass cannot apply over a pending manual selection")
        gate.settleManualOfficialSelection()
        discovery.discover()
        expect(discoveryWait { !applied.isEmpty },
               "the manual-ready event starts a new pass that applies with the saved binding")
        discovery.cancel()
    } catch {
        expect(false, "manual-intent fixture failed: \(error)")
    }
}
