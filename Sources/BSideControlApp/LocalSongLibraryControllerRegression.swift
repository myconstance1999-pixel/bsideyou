// BSideControlApp — controller-level regression for the explicit local song catalog (ADR-022).
// Drives the REAL LocalSongLibraryController through injectable tiny temp-directory scan/hash/grant
// seams: no security-scoped bookmark entitlement, no Agent, no player, no real media. It pins root
// identity reuse, per-root scan generations, transactional persistence and pending-request intent.
import Foundation
import BSideCore
import BSidePlatform

private func controllerFixtureRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("bside-local-controller-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@discardableResult
private func writeControllerFile(_ url: URL, bytes: Int, fill: UInt8 = 5) throws -> URL {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: fill, count: bytes).write(to: url)
    return url
}

/// Plain (non-security-scoped) bookmark + transfer lease: the same mechanism the existing
/// DirectoryChangeMonitor fixtures use in this sandbox.
private func controllerSeams(store: LocalSongStore,
                             gate: FailingSaveGate? = nil,
                             scanDelay: @escaping (URL) -> TimeInterval = { _ in 0 },
                             hashGate: HashGate? = nil) -> LocalSongLibrarySeams {
    var save: ((LocalSongCatalog) throws -> Void)?
    if let gate { save = { try gate.save($0) } }
    return LocalSongLibrarySeams(
        authorizeRoot: { url in
            let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            return (try DirectoryAccessLease.resolveTransfer(data), data)
        },
        resolveRoot: { data in
            (try DirectoryAccessLease.resolveTransfer(data), nil)
        },
        scan: { url, officialSource in
            let delay = scanDelay(url)
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            return try LocalSongScanner.scan(root: url, officialSource: officialSource)
        },
        fingerprint: { url in
            if let hashGate { return try hashGate.fingerprint(url) }
            return try LocalFileVerifier.fingerprint(url: url)
        },
        transferBookmark: { try $0.makeTransferBookmark() },
        save: save)
}

private func controllerWait(timeout: TimeInterval = 4.0, until condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    return condition()
}

/// Flips a real store save into a typed failure on demand so transactional behaviour is
/// exercised without touching a real user store.
private final class FailingSaveGate {
    private let store: LocalSongStore
    var failing = false
    init(store: LocalSongStore) { self.store = store }
    func save(_ catalog: LocalSongCatalog) throws {
        if failing { throw LocalSongError.storeWriteFailed("synthetic failure") }
        try store.save(catalog)
    }
}

/// Blocks the first hash deterministically; later hashes proceed. Lets the test release a slow
/// hash AFTER a superseding intent, exactly like a real slow local hash.
private final class HashGate {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var blockNext = true
    private var started = false
    func fingerprint(_ url: URL) throws -> LocalFileFingerprint {
        lock.lock()
        let shouldBlock = blockNext
        blockNext = false
        started = true
        lock.unlock()
        if shouldBlock { _ = semaphore.wait(timeout: .now() + 3) }
        return try LocalFileVerifier.fingerprint(url: url)
    }
    func release() { semaphore.signal() }
    var hasStarted: Bool {
        lock.lock(); defer { lock.unlock() }; return started
    }
}

/// Records which thread invoked each controller seam/callback so the regression can prove the
/// main-thread ownership contract without a flaky timing observation.
private final class ThreadProbe {
    private let lock = NSLock()
    private var catalogFlags: [Bool] = []
    private var scanFlags: [Bool] = []
    private var hashFlags: [Bool] = []
    private var saveFlags: [Bool] = []

    func recordCatalog() { lock.lock(); catalogFlags.append(Thread.isMainThread); lock.unlock() }
    func recordScan() { lock.lock(); scanFlags.append(Thread.isMainThread); lock.unlock() }
    func recordHash() { lock.lock(); hashFlags.append(Thread.isMainThread); lock.unlock() }
    func recordSave() { lock.lock(); saveFlags.append(Thread.isMainThread); lock.unlock() }

    private func copy(_ flags: [Bool]) -> [Bool] {
        lock.lock(); defer { lock.unlock() }; return flags
    }
    var allCatalogMain: Bool { copy(catalogFlags).allSatisfy { $0 } }
    var allSaveMain: Bool { copy(saveFlags).allSatisfy { $0 } }
    var anyScanBackground: Bool { copy(scanFlags).contains(false) }
    var anyHashBackground: Bool { copy(hashFlags).contains(false) }
    var catalogCount: Int { copy(catalogFlags).count }
    var scanCount: Int { copy(scanFlags).count }
}

/// A catalog inside the selected root emits its own directory-change hint after each save.
/// Drive the real controller callback without relying on native event delivery timing.
private func runUnchangedLocalScanRegression(library: PerformanceLibrary,
                                            expect: (Bool, String) -> Void) {
    do {
        let dir = try controllerFixtureRoot()
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("selected", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = LocalSongStore(url: root.appendingPathComponent("local-songs.json"))
        let file = root.appendingPathComponent("work/a.mp4")
        var directoryChange: ((DirectoryChange) -> Void)?
        var saves = 0
        var publications = 0
        var queuedEvents = 0
        var writeEvents = 0
        var observeWrites = false
        let probe = ThreadProbe()
        var seams = controllerSeams(store: store)
        let scan = seams.scan
        seams.scan = { url, officialSource in
            probe.recordScan()
            return try scan(url, officialSource)
        }
        seams.save = { catalog in
            try store.save(catalog)
            saves += 1
            // Bound a regression on old code rather than permitting an endless feedback loop.
            if observeWrites && writeEvents < 8 {
                writeEvents += 1
                queuedEvents += 1
                DispatchQueue.main.async {
                    queuedEvents -= 1
                    directoryChange?(DirectoryChange(paths: [store.url.path], requiresFullScan: false,
                                                     rootChanged: false, volumeAvailable: nil))
                }
            }
        }
        let controller = LocalSongLibraryController(
            store: store, library: { library }, seams: seams,
            makeMonitor: { _, _, callback in directoryChange = callback; return nil },
            onCatalog: { _, _ in publications += 1 })
        controller.load()
        controller.addRoot(root)
        expect(controllerWait { !controller.isScanning }, "an empty root finishes its initial scan")
        expect(FileManager.default.fileExists(atPath: store.url.path)
               && controller.catalog.roots.count == 1 && controller.catalog.tracks.isEmpty && saves == 1,
               "initial empty-root admission still creates and saves its catalog")

        let emptyCatalog = controller.catalog
        let emptyBytes = try Data(contentsOf: store.url)
        let emptyPublications = publications
        controller.refresh()
        expect(controllerWait { !controller.isScanning }, "an unchanged empty-root refresh completes")
        let refreshedEmptyBytes = try Data(contentsOf: store.url)
        expect(controller.catalog == emptyCatalog && refreshedEmptyBytes == emptyBytes
               && saves == 1 && publications == emptyPublications,
               "an unchanged empty-root scan preserves bytes, revision and publication count")

        observeWrites = true
        try writeControllerFile(file, bytes: 32)
        directoryChange?(DirectoryChange(paths: [file.path], requiresFullScan: false,
                                         rootChanged: false, volumeAvailable: nil))
        expect(controllerWait { !controller.isScanning && queuedEvents == 0 },
               "a changed scan and its catalog-write event settle")
        expect(controller.catalog.tracks.count == 1 && saves == 2 && writeEvents == 1,
               "a file addition commits once and its own catalog event cannot sustain writes")

        let stable = controller.catalog
        let stableBytes = try Data(contentsOf: store.url)
        let stablePublications = publications
        let scans = probe.scanCount
        controller.refresh()
        expect(controllerWait { !controller.isScanning && queuedEvents == 0 },
               "a manual populated-root refresh completes")
        let unrelated = DirectoryChange(paths: [root.appendingPathComponent("notes.txt").path],
                                        requiresFullScan: false, rootChanged: false, volumeAvailable: nil)
        directoryChange?(unrelated)
        directoryChange?(unrelated)
        expect(controllerWait { !controller.isScanning && queuedEvents == 0 },
               "an in-flight event still drains its coalesced pending rescan")
        let rescannedBytes = try Data(contentsOf: store.url)
        expect(probe.scanCount == scans + 3,
               "manual refresh plus two coalesced events perform all three required scans")
        expect(controller.catalog == stable && rescannedBytes == stableBytes
               && publications == stablePublications && saves == 2,
               "unchanged refresh and directory events never save or republish the catalog")

        try FileManager.default.removeItem(at: file)
        directoryChange?(DirectoryChange(paths: [file.path], requiresFullScan: false,
                                         rootChanged: false, volumeAvailable: nil))
        expect(controllerWait { !controller.isScanning && queuedEvents == 0 },
               "a file removal and its catalog event settle")
        expect(saves == 3 && controller.catalog.tracks.first?.isAvailable == false,
               "file removal persists availability once without deleting its record")
        try writeControllerFile(file, bytes: 32)
        directoryChange?(DirectoryChange(paths: [file.path], requiresFullScan: false,
                                         rootChanged: false, volumeAvailable: nil))
        expect(controllerWait { !controller.isScanning && queuedEvents == 0 },
               "a returning file and its catalog event settle")
        expect(saves == 4 && writeEvents == 3 && controller.catalog.tracks == stable.tracks,
               "file return commits once with the original identities and remembered selection")
    } catch {
        expect(false, "unchanged local scan fixture failed: \(error)")
    }
}

private func runLocalRootReauthorizationRegression(library: PerformanceLibrary,
                                                  expect: (Bool, String) -> Void) {
    do {
        let dir = try controllerFixtureRoot()
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("selected", isDirectory: true)
        try writeControllerFile(root.appendingPathComponent("work/a.mp4"), bytes: 32)
        try writeControllerFile(root.appendingPathComponent("work/b.mp4"), bytes: 48)
        let store = LocalSongStore(url: dir.appendingPathComponent("local-songs.json"))
        let original = LocalSongLibraryController(
            store: store, library: { library }, seams: controllerSeams(store: store),
            makeMonitor: { _, _, _ in nil }, onCatalog: { _, _ in })
        original.load()
        original.addRoot(root)
        expect(controllerWait { !original.isScanning && !original.catalog.tracks.isEmpty },
               "reauthorization fixture imports its initial records")
        guard let track = original.catalog.tracks.first,
              let alternate = track.sortedFiles.dropFirst().first,
              let anchor = original.catalog.roots.first?.identity?.snapshotValue,
              let inode = anchor.inode, anchor.volumeUUID != nil, anchor.persistentIDsSupported == true else {
            expect(false, "reauthorization fixture requires a comparable persistent identity and two versions")
            return
        }
        original.rename(trackID: track.id, to: "Preserved title")
        original.selectFile(trackID: track.id, fileID: alternate.id)
        var seed = original.catalog
        let invalidBookmark = Data("invalid-in-new-app-identity".utf8)
        seed.roots[0].bookmark = invalidBookmark
        try store.save(seed)
        let savedBytes = try Data(contentsOf: store.url)
        var seams = controllerSeams(store: store)
        let resolve = seams.resolveRoot
        seams.resolveRoot = { data in
            if data == invalidBookmark { throw CocoaError(.fileReadCorruptFile) }
            return try resolve(data)
        }
        let renewed = LocalSongLibraryController(
            store: store, library: { library }, seams: seams,
            makeMonitor: { _, _, _ in nil }, onCatalog: { _, _ in })
        renewed.load()
        renewed.admitAutoRoot(root)
        expect(renewed.catalog == seed && (try? Data(contentsOf: store.url)) == savedBytes,
               "automatic discovery cannot replace an invalid saved grant")
        renewed.addRoot(root)
        expect(controllerWait { !renewed.isScanning }, "explicit reauthorization scan settles")
        expect(renewed.catalog.roots.count == 1 && renewed.catalog.roots.first?.id == seed.roots[0].id,
               "matching stable identity reuses the original root despite old bookmark failure")
        expect(renewed.catalog.roots.first?.identity == seed.roots[0].identity
               && renewed.catalog.roots.first?.bookmark != invalidBookmark,
               "reauthorization renews the grant without rebasing its historical anchor")
        expect(renewed.catalog.tracks == seed.tracks && renewed.catalog.nextNumber == seed.nextNumber,
               "reauthorization preserves track/file IDs, numbering, custom title and selected version")

        let uncertain: [(String, StoredDirectoryIdentity?)] = [
            ("conflicting", .snapshot(DirectoryIdentitySnapshot(volumeUUID: anchor.volumeUUID, inode: inode + 1,
                persistentIDsSupported: true, provenance: .explicitSelection))),
            ("incomparable", .snapshot(DirectoryIdentitySnapshot(volumeUUID: anchor.volumeUUID, inode: inode,
                persistentIDsSupported: false, provenance: .explicitSelection))),
            ("unsupported", .unsupported(.object(["version": .int(99)]))),
            ("missing", nil),
        ]
        for (label, identity) in uncertain {
            var rejected = seed
            rejected.roots[0].identity = identity
            try store.save(rejected)
            let before = try Data(contentsOf: store.url)
            var lastMessage: String?
            let controller = LocalSongLibraryController(
                store: store, library: { library }, seams: seams,
                makeMonitor: { _, _, _ in nil }, onCatalog: { _, message in lastMessage = message })
            controller.load()
            controller.addRoot(root)
            expect(!controller.isScanning && controller.catalog == rejected,
                   "an invalid grant with \(label) anchor cannot reuse, rebase or duplicate the selected root")
            expect((try? Data(contentsOf: store.url)) == before && lastMessage?.isEmpty == false,
                   "\(label) identity refusal preserves saved bytes and exposes recovery failure")
        }
    } catch { expect(false, "root reauthorization fixture failed: \(error)") }
}

func runLocalSongControllerRegression(expect: (Bool, String) -> Void) {
    guard let library = try? PerformanceLibrary.bundled() else {
        expect(false, "the bundled library must load for the controller regression")
        return
    }
    runUnchangedLocalScanRegression(library: library, expect: expect)
    runLocalRootReauthorizationRegression(library: library, expect: expect)

    // 1) Repeated explicit import of the SAME accepted root reuses the root id and keeps every
    // track id, number, title, selected file and numbering.
    do {
        let dir = try controllerFixtureRoot()
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("selected", isDirectory: true)
        try writeControllerFile(root.appendingPathComponent("work/a.mp4"), bytes: 32, fill: 1)
        try writeControllerFile(root.appendingPathComponent("work/b.mp4"), bytes: 48, fill: 2)
        let store = LocalSongStore(url: dir.appendingPathComponent("local-songs.json"))
        var messages: [String?] = []
        let controller = LocalSongLibraryController(
            store: store, library: { library }, seams: controllerSeams(store: store),
            makeMonitor: { _, _, _ in nil },
            onCatalog: { _, message in messages.append(message) })
        controller.load()
        controller.addRoot(root)
        expect(controllerWait { !controller.catalog.tracks.isEmpty && !controller.isScanning },
               "the first explicit import scans the selected root")
        expect(controller.catalog.roots.count == 1, "one explicit import registers one root")
        let firstTrackIDs = controller.catalog.tracks.map(\.id).sorted()
        let firstNumbers = controller.catalog.tracks.map(\.number).sorted()
        let firstFileIDs = controller.catalog.tracks.flatMap { $0.files.map(\.id) }.sorted()
        let nextAfterFirst = controller.catalog.nextNumber
        guard let trackID = controller.catalog.tracks.first?.id,
              let otherFile = controller.catalog.tracks.first?.sortedFiles.dropFirst().first else {
            expect(false, "the fixture must produce one track with two versions")
            return
        }
        controller.rename(trackID: trackID, to: "重复导入保留")
        controller.selectFile(trackID: trackID, fileID: otherFile.id)
        expect(controller.catalog.tracks.first?.customTitle == "重复导入保留",
               "the rename is committed before the repeated import")

        controller.addRoot(root)
        expect(controllerWait { controller.catalog.roots.count == 1 && !controller.isScanning },
               "re-importing the same root completes without adding a root")
        expect(controller.catalog.roots.count == 1,
               "the same accepted directory must reuse its existing root id, not duplicate it")
        expect(controller.catalog.tracks.map(\.id).sorted() == firstTrackIDs,
               "a repeated import keeps every existing track id")
        expect(controller.catalog.tracks.map(\.number).sorted() == firstNumbers,
               "a repeated import keeps every existing number")
        expect(controller.catalog.tracks.flatMap { $0.files.map(\.id) }.sorted() == firstFileIDs,
               "a repeated import keeps every existing file id")
        expect(controller.catalog.tracks.first?.customTitle == "重复导入保留",
               "a repeated import keeps the renamed title")
        expect(controller.catalog.tracks.first?.selectedFileID == otherFile.id,
               "a repeated import keeps the remembered selected file")
        expect(controller.catalog.nextNumber == nextAfterFirst,
               "a repeated import never renumbers or allocates again")

        // 3) A repeated same-root scan keeps ids/numbers/titles/selection stable.
        let stableIDs = controller.catalog.tracks.map(\.id).sorted()
        controller.refresh()
        expect(controllerWait { !controller.isScanning },
               "the repeated same-root refresh completes")
        expect(controller.catalog.roots.count == 1, "a refresh never adds a root")
        expect(controller.catalog.tracks.map(\.id).sorted() == stableIDs,
               "a repeated same-root scan keeps stable ids")
        expect(controller.catalog.tracks.first?.customTitle == "重复导入保留"
               && controller.catalog.tracks.first?.selectedFileID == otherFile.id,
               "a repeated same-root scan keeps title and selection")
    } catch {
        expect(false, "controller repeated-import fixture failed: \(error)")
    }

    // 2) Two roots whose scans complete in REVERSED order both publish: a per-root generation is
    // required, because one global generation would let the last root's scan drop the first.
    do {
        let dir = try controllerFixtureRoot()
        defer { try? FileManager.default.removeItem(at: dir) }
        let rootA = dir.appendingPathComponent("rootA", isDirectory: true)
        let rootB = dir.appendingPathComponent("rootB", isDirectory: true)
        try writeControllerFile(rootA.appendingPathComponent("work/a.mp4"), bytes: 16, fill: 3)
        try writeControllerFile(rootB.appendingPathComponent("work/b.mp4"), bytes: 16, fill: 4)
        let store = LocalSongStore(url: dir.appendingPathComponent("local-songs.json"))
        let controller = LocalSongLibraryController(
            store: store, library: { library },
            seams: controllerSeams(store: store, scanDelay: { url in
                url.lastPathComponent == "rootA" ? 0.25 : 0.01
            }),
            makeMonitor: { _, _, _ in nil },
            onCatalog: { _, _ in })
        controller.load()
        controller.addRoot(rootA)
        controller.addRoot(rootB)
        expect(controllerWait { !controller.isScanning && controller.catalog.roots.count == 2 },
               "both roots finish their scans")
        let rootIDs = Set(controller.catalog.tracks.map(\.rootID))
        expect(controller.catalog.roots.count == 2, "both roots are registered")
        expect(rootIDs.count == 2,
               "a slow first root still publishes after a fast second root (per-root generation)")
        expect(controller.catalog.tracks.count == 2, "each root contributes its own track")
        expect(controller.catalog.roots.allSatisfy { !$0.isMissing },
               "neither completed root is left marked missing by the other's scan")
    } catch {
        expect(false, "controller multi-root ordering fixture failed: \(error)")
    }

    // 4) A failing save is transactional: no fake success, and prior ids/selection/message state
    // survive. The scan itself must not clear the error.
    do {
        let dir = try controllerFixtureRoot()
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("selected", isDirectory: true)
        try writeControllerFile(root.appendingPathComponent("work/a.mp4"), bytes: 24, fill: 6)
        try writeControllerFile(root.appendingPathComponent("work/b.mp4"), bytes: 24, fill: 7)
        let store = LocalSongStore(url: dir.appendingPathComponent("local-songs.json"))
        let gate = FailingSaveGate(store: store)
        var lastMessage: String?
        let controller = LocalSongLibraryController(
            store: store, library: { library }, seams: controllerSeams(store: store, gate: gate),
            makeMonitor: { _, _, _ in nil },
            onCatalog: { _, message in lastMessage = message })
        controller.load()
        controller.addRoot(root)
        expect(controllerWait { !controller.catalog.tracks.isEmpty && !controller.isScanning },
               "the baseline import succeeds before the failure")
        guard let trackID = controller.catalog.tracks.first?.id,
              let firstFile = controller.catalog.tracks.first?.sortedFiles.first,
              let secondFile = controller.catalog.tracks.first?.sortedFiles.dropFirst().first,
              let committedNumber = controller.catalog.tracks.first?.number else {
            expect(false, "the failure fixture must produce one track with two versions")
            return
        }
        controller.selectFile(trackID: trackID, fileID: firstFile.id)
        let committedSelection = controller.catalog.tracks.first?.selectedFileID
        let automatic = LocalSongClassification(category: .piano, style: .gentle, origin: .automatic,
            analyzedFileID: firstFile.id, modelID: "local-test-model", modelRevision: "revision-1")
        controller.setClassification(trackID: trackID, classification: automatic)
        let beforeFailure = controller.catalog
        let committedBytes = try Data(contentsOf: store.url)

        gate.failing = true
        controller.setClassification(trackID: trackID, classification:
            LocalSongClassification(category: .vocal, style: .energetic, origin: .manual))
        expect(controller.catalog == beforeFailure,
               "a failed classification save retains the complete committed catalog and revision")
        expect(try Data(contentsOf: store.url) == committedBytes,
               "a failed classification save leaves the prior on-disk bytes intact")
        controller.rename(trackID: trackID, to: "不应提交")
        expect(controller.catalog.tracks.first?.customTitle == nil,
               "a failed rename must not mutate the committed title")
        controller.selectFile(trackID: trackID, fileID: secondFile.id)
        expect(controller.catalog.tracks.first?.selectedFileID == committedSelection,
               "a failed selection change must retain the committed selection")
        expect(controller.catalog.tracks.first?.number == committedNumber,
               "a failed mutation must retain the committed number")
        expect(lastMessage != nil && lastMessage?.contains("无法保存") == true,
               "a failed save surfaces a visible error instead of a fake success")
        expect(store.load() != .empty, "the previously committed store survives a failed save")
        gate.failing = false
        controller.rename(trackID: trackID, to: "恢复后提交")
        expect(controller.catalog.tracks.first?.customTitle == "恢复后提交",
               "a later successful save commits normally")
        let manual = LocalSongClassification(category: .instrumental, style: .lyrical, origin: .manual)
        controller.setClassification(trackID: trackID, classification: manual)
        expect(controller.catalog.tracks.first?.classification == manual,
               "a recovered classification save commits the manual correction")
        let reloaded = LocalSongLibraryController(store: store, library: { library },
            seams: controllerSeams(store: store), makeMonitor: { _, _, _ in nil }, onCatalog: { _, _ in })
        reloaded.load()
        expect(reloaded.catalog == controller.catalog,
               "a new controller loads the exact classification and committed state")

        // A scan whose result cannot be saved must keep the committed catalog and the error.
        let beforeScanFailure = controller.catalog
        let bytesBeforeScanFailure = try Data(contentsOf: store.url)
        try writeControllerFile(root.appendingPathComponent("work/b.mp4"), bytes: 48, fill: 7)
        gate.failing = true
        lastMessage = nil
        controller.refresh()
        expect(controllerWait { lastMessage?.contains("无法保存") == true },
               "a failed scan save surfaces a visible error instead of fake success")
        expect(controller.catalog.tracks.count == 1
               && controller.catalog.tracks.first?.customTitle == "恢复后提交"
               && !controller.catalog.roots.isEmpty,
               "a failed scan save retains every committed id/number/title/selection record")
        let bytesAfterScanFailure = try Data(contentsOf: store.url)
        expect(controller.catalog == beforeScanFailure && bytesAfterScanFailure == bytesBeforeScanFailure,
               "a failed changed scan preserves the exact committed catalog, revision and bytes")

        // A later no-op is not a successful save and cannot dismiss the prior failure.
        try writeControllerFile(root.appendingPathComponent("work/b.mp4"), bytes: 24, fill: 7)
        let failureMessage = lastMessage
        controller.refresh()
        expect(controllerWait { !controller.isScanning }, "the unchanged scan after a save failure completes")
        expect(lastMessage == failureMessage && controller.catalog == beforeScanFailure,
               "an unchanged scan preserves the prior save error and committed catalog")

        gate.failing = false
        try writeControllerFile(root.appendingPathComponent("work/b.mp4"), bytes: 48, fill: 7)
        controller.refresh()
        expect(controllerWait { !controller.isScanning }, "a changed scan retries after save recovery")
        expect(lastMessage == nil && controller.catalog != beforeScanFailure
               && controller.catalog.tracks.first?.files.first(where: { $0.id == secondFile.id })?.byteSize == 48,
               "a successful changed scan commits the pending file metadata and clears the failure")
    } catch {
        expect(false, "controller transactional fixture failed: \(error)")
    }

    // 5) A slow local hash is superseded by a version change: its late result never publishes a
    // fingerprint, never sends a grant, and the successful request carries the post-save revision.
    do {
        let dir = try controllerFixtureRoot()
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("selected", isDirectory: true)
        try writeControllerFile(root.appendingPathComponent("work/a.mp4"), bytes: 128, fill: 9)
        try writeControllerFile(root.appendingPathComponent("work/b.mp4"), bytes: 256, fill: 8)
        let store = LocalSongStore(url: dir.appendingPathComponent("local-songs.json"))
        let hashGate = HashGate()
        let controller = LocalSongLibraryController(
            store: store, library: { library },
            seams: controllerSeams(store: store, hashGate: hashGate),
            makeMonitor: { _, _, _ in nil },
            onCatalog: { _, _ in })
        controller.load()
        controller.addRoot(root)
        expect(controllerWait { !controller.catalog.tracks.isEmpty && !controller.isScanning },
               "the intent fixture scans before hashing")
        guard let track = controller.catalog.tracks.first,
              let firstFile = track.sortedFiles.first,
              let secondFile = track.sortedFiles.dropFirst().first else {
            expect(false, "the intent fixture must produce one track with two versions")
            return
        }
        var firstCompletions = 0
        var secondGrant: LocalPlaybackGrant?
        controller.preparePlayback(trackID: track.id, fileID: firstFile.id) { _ in
            firstCompletions += 1
        }
        expect(controllerWait { hashGate.hasStarted }, "the first hash starts")
        // A relevant version change invalidates the slow request.
        controller.selectFile(trackID: track.id, fileID: secondFile.id)
        hashGate.release()
        expect(controllerWait { controller.catalog.tracks.first?.selectedFileID == secondFile.id },
               "the new version is committed")
        _ = controllerWait(timeout: 0.4) { firstCompletions > 0 }
        expect(firstCompletions == 0,
               "a superseded hash must not deliver a start grant")
        let firstCommitted = controller.catalog.tracks.first?.files.first { $0.id == firstFile.id }
        expect(firstCommitted?.sha256 == nil,
               "a superseded hash must not publish a fingerprint into the catalog")

        controller.preparePlayback(trackID: track.id, fileID: secondFile.id) { result in
            if case .success(let grant) = result { secondGrant = grant }
        }
        expect(controllerWait { secondGrant != nil },
               "the later request completes with its own exact file")
        expect(secondGrant?.binding.relativePath == secondFile.relativePath,
               "the grant binds the exact later-selected file")
        expect(secondGrant?.reference.catalogRevision == controller.catalog.catalogRevision,
               "the grant carries the CURRENT revision, after the successful fingerprint save")
        expect(controller.catalog.tracks.first?.files.first { $0.id == secondFile.id }?.sha256
               == secondGrant?.binding.sha256,
               "the saved fingerprint matches the granted binding")
    } catch {
        expect(false, "controller intent fixture failed: \(error)")
    }

    // 6) An unrelated label edit does NOT cancel the pending request (only playback intent does).
    do {
        let dir = try controllerFixtureRoot()
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("selected", isDirectory: true)
        try writeControllerFile(root.appendingPathComponent("work/a.mp4"), bytes: 96, fill: 4)
        let store = LocalSongStore(url: dir.appendingPathComponent("local-songs.json"))
        let hashGate = HashGate()
        let controller = LocalSongLibraryController(
            store: store, library: { library }, seams: controllerSeams(store: store, hashGate: hashGate),
            makeMonitor: { _, _, _ in nil },
            onCatalog: { _, _ in })
        controller.load()
        controller.addRoot(root)
        expect(controllerWait { !controller.catalog.tracks.isEmpty && !controller.isScanning },
               "the rename fixture scans before hashing")
        guard let track = controller.catalog.tracks.first,
              let file = track.sortedFiles.first else {
            expect(false, "the rename fixture must produce one track")
            return
        }
        var granted = false
        controller.preparePlayback(trackID: track.id, fileID: file.id) { result in
            if case .success = result { granted = true }
        }
        expect(controllerWait { hashGate.hasStarted }, "the hash starts before the rename")
        controller.rename(trackID: track.id, to: "无关标签")
        let manual = LocalSongClassification(category: .piano, style: .melancholic, origin: .manual)
        controller.setClassification(trackID: track.id, classification: manual)
        hashGate.release()
        expect(controllerWait { granted }, "an ordinary label edit must not cancel the pending request")
        expect(controller.catalog.tracks.first?.customTitle == "无关标签",
               "the unrelated rename is still committed")
        expect(controller.catalog.tracks.first?.classification == manual,
               "classification stays committed when the pending playback fingerprint completes")
    } catch {
        expect(false, "controller rename-intent fixture failed: \(error)")
    }

    // 7) A known root identity conflict refuses to rebase the saved anchor.
    do {
        let dir = try controllerFixtureRoot()
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("selected", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bookmark = try root.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let lease = try DirectoryAccessLease.resolveTransfer(bookmark)
        guard let fresh = lease.identitySnapshot(provenance: .explicitSelection), fresh.inode != nil else {
            expect(false, "the conflict fixture requires a filesystem identity")
            return
        }
        let conflicting = StoredDirectoryIdentity.snapshot(DirectoryIdentitySnapshot(
            volumeUUID: fresh.volumeUUID, inode: fresh.inode! + 1,
            persistentIDsSupported: fresh.persistentIDsSupported, provenance: .explicitSelection))
        let store = LocalSongStore(url: dir.appendingPathComponent("local-songs.json"))
        var seeded = LocalSongCatalog()
        seeded.registerRoot(id: "root-conflict", displayPath: root.path, bookmark: bookmark,
                            identity: conflicting)
        try store.save(seeded)
        var lastMessage: String?
        let controller = LocalSongLibraryController(
            store: store, library: { library },
            seams: LocalSongLibrarySeams(
                authorizeRoot: { url in
                    let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
                    return (try DirectoryAccessLease.resolveTransfer(data), data)
                },
                resolveRoot: { data in (try DirectoryAccessLease.resolveTransfer(data), nil) },
                scan: { url, officialSource in
                    try LocalSongScanner.scan(root: url, officialSource: officialSource)
                },
                fingerprint: { try LocalFileVerifier.fingerprint(url: $0) },
                transferBookmark: { try $0.makeTransferBookmark() },
                save: nil),
            makeMonitor: { _, _, _ in nil },
            onCatalog: { _, message in lastMessage = message })
        controller.load()
        controller.restoreAndScan()
        expect(controllerWait { controller.catalog.roots.first?.isMissing == true },
               "a known identity conflict marks the root unavailable")
        expect(controller.catalog.roots.first?.identity == conflicting,
               "a known identity conflict must not rebase the saved anchor")
        expect(controller.catalog.tracks.isEmpty,
               "a conflicting root must not publish scanned tracks")
        expect(lastMessage?.contains("不一致") == true,
               "the conflict is surfaced as a visible actionable error")

        // Re-importing that same path must also refuse to reuse/duplicate or rebase the record.
        controller.addRoot(root)
        expect(controllerWait { controller.catalog.roots.count == 1 && !controller.isScanning },
               "re-importing a conflicting path settles without adding a root")
        expect(controller.catalog.roots.count == 1,
               "a known identity conflict is not silently duplicated as a new root")
        expect(controller.catalog.roots.first?.identity == conflicting,
               "re-importing a conflicting path does not rebase the saved anchor")
        expect(controller.catalog.roots.first?.bookmark == bookmark,
               "re-importing a conflicting path does not replace the saved bookmark")
        expect(controller.catalog.tracks.isEmpty,
               "re-importing a conflicting path does not publish any catalog track")
        expect(lastMessage?.contains("不一致") == true,
               "the re-import conflict is surfaced to the user")
    } catch {
        expect(false, "controller conflict fixture failed: \(error)")
    }

    // 8) A fingerprint that cannot be saved never yields a start grant and never becomes a
    // baseline; the same file can be prepared once the save works again.
    do {
        let dir = try controllerFixtureRoot()
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("selected", isDirectory: true)
        try writeControllerFile(root.appendingPathComponent("work/a.mp4"), bytes: 64, fill: 2)
        let store = LocalSongStore(url: dir.appendingPathComponent("local-songs.json"))
        let gate = FailingSaveGate(store: store)
        let browser = PerformanceBrowserModel()
        let controller = LocalSongLibraryController(
            store: store, library: { library }, seams: controllerSeams(store: store, gate: gate),
            makeMonitor: { _, _, _ in nil },
            onCatalog: { catalog, _ in browser.localCatalog = catalog })
        controller.load()
        controller.addRoot(root)
        expect(controllerWait { !controller.catalog.tracks.isEmpty && !controller.isScanning },
               "the fingerprint-save fixture scans before hashing")
        guard let track = controller.catalog.tracks.first,
              let file = track.sortedFiles.first else {
            expect(false, "the fingerprint-save fixture must produce one track")
            return
        }
        gate.failing = true
        var denied = false
        var deniedGrant = false
        controller.preparePlayback(trackID: track.id, fileID: file.id) { result in
            switch result {
            case .failure: denied = true
            case .success: deniedGrant = true
            }
        }
        expect(controllerWait { denied || deniedGrant },
               "a failed identity save completes the request")
        expect(denied && !deniedGrant,
               "a fingerprint that cannot be saved must not issue a start grant")
        expect(controller.catalog.tracks.first?.files.first?.sha256 == nil,
               "a failed save must not leave a fingerprint baseline in the catalog")
        expect(browser.localCatalog?.tracks.first?.files.first?.sha256 == nil,
               "failed fingerprint persistence cannot publish a false UI baseline")
        gate.failing = false
        var granted = false
        var historyAvailableAtGrant = false
        var projectedBindingAtGrant = false
        controller.preparePlayback(trackID: track.id, fileID: file.id) { result in
            if case .success(let grant) = result {
                granted = true
                let projectedFile = browser.localCatalog?.track(id: track.id)?.files.first { $0.id == file.id }
                projectedBindingAtGrant = projectedFile?.sha256 == grant.binding.sha256
                    && projectedFile?.fingerprintByteSize == grant.binding.byteSize
                    && browser.localCatalog?.catalogRevision == grant.reference.catalogRevision
                let history = SongPlaybackRecord(target: .localFile(grant.reference), fileBinding: grant.binding,
                    mode: .listen, title: track.displayTitle, lastPlayed: Date())
                historyAvailableAtGrant = browser.songHistoryUnavailableReason(history) == nil
            }
        }
        expect(controllerWait { granted },
               "the same file can be prepared once the store accepts writes again")
        expect(projectedBindingAtGrant,
               "first-play completion sees the committed fingerprint and revision in the browser model")
        expect(historyAvailableAtGrant,
               "fresh import followed by first playback makes the exact history file replayable without reload")
    } catch {
        expect(false, "controller fingerprint-save fixture failed: \(error)")
    }

    // 9) Thread ownership: every catalog publication and playback completion is delivered on the
    // main thread and persistence is published on the main thread, while the metadata scan and the
    // selected-file hash still run on detached workers.
    do {
        let dir = try controllerFixtureRoot()
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("selected", isDirectory: true)
        try writeControllerFile(root.appendingPathComponent("work/a.mp4"), bytes: 48, fill: 1)
        try writeControllerFile(root.appendingPathComponent("work/b.mp4"), bytes: 64, fill: 2)
        let store = LocalSongStore(url: dir.appendingPathComponent("local-songs.json"))
        let probe = ThreadProbe()
        var seams = controllerSeams(store: store)
        let baseScan = seams.scan
        let baseFingerprint = seams.fingerprint
        seams.scan = { url, officialSource in
            probe.recordScan()
            return try baseScan(url, officialSource)
        }
        seams.fingerprint = { url in
            probe.recordHash()
            return try baseFingerprint(url)
        }
        seams.save = { candidate in
            probe.recordSave()
            try store.save(candidate)
        }
        let controller = LocalSongLibraryController(
            store: store, library: { library }, seams: seams,
            makeMonitor: { _, _, _ in nil },
            onCatalog: { _, _ in probe.recordCatalog() })
        controller.load()
        controller.addRoot(root)
        expect(controllerWait { !controller.catalog.tracks.isEmpty && !controller.isScanning },
               "the thread-ownership fixture scans")
        guard let track = controller.catalog.tracks.first,
              let file = track.sortedFiles.first else {
            expect(false, "the thread-ownership fixture must produce one track")
            return
        }
        var completionFlags: [Bool] = []
        controller.preparePlayback(trackID: track.id, fileID: file.id) { _ in
            completionFlags.append(Thread.isMainThread)
        }
        expect(controllerWait { !completionFlags.isEmpty },
               "the thread-ownership fixture completes a playback request")
        expect(probe.catalogCount > 0 && probe.allCatalogMain,
               "every onCatalog publication is delivered on the main thread")
        expect(probe.allSaveMain,
               "every catalog persistence publication happens on the main thread")
        expect(completionFlags.allSatisfy { $0 },
               "every playback completion is delivered on the main thread")
        expect(probe.anyScanBackground,
               "the bounded metadata scan still runs off the main thread")
        expect(probe.anyHashBackground,
               "the selected-file hash still runs off the main thread")
    } catch {
        expect(false, "controller thread-ownership fixture failed: \(error)")
    }

    // 10) Official exclusion follows exact contained locations under the ACCEPTED official
    // binding. A same-named file outside it is preserved; the 129 official rows are untouched.
    do {
        let dir = try controllerFixtureRoot()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let variant = library.manifest.tracks.first?.variants.first else {
            expect(false, "the official-location fixture needs one official variant")
            return
        }
        let officialRoot = dir.appendingPathComponent("official", isDirectory: true)
        let userRoot = dir.appendingPathComponent("user", isDirectory: true)
        let officialFile = officialRoot.appendingPathComponent(variant.relativePath)
        try writeControllerFile(officialFile, bytes: 16, fill: 3)
        let officialName = (variant.relativePath as NSString).lastPathComponent
        try writeControllerFile(userRoot.appendingPathComponent(officialName), bytes: 16, fill: 4)
        let store = LocalSongStore(url: dir.appendingPathComponent("local-songs.json"))
        let controller = LocalSongLibraryController(
            store: store, library: { library }, seams: controllerSeams(store: store),
            makeMonitor: { _, _, _ in nil },
            officialSourceRoot: { officialRoot },
            onCatalog: { _, _ in })
        controller.load()
        controller.addRoot(userRoot)
        expect(controllerWait { !controller.catalog.tracks.isEmpty && !controller.isScanning },
               "the user root with a same-named file is scanned")
        expect(controller.catalog.tracks.first?.files.map(\.basename) == [officialName],
               "a file whose name matches an official basename outside the official source is preserved")
        controller.addRoot(officialRoot)
        expect(controllerWait { controller.catalog.roots.count == 2 && !controller.isScanning },
               "the accepted official source root also scans")
        expect(controller.catalog.tracks.count == 1,
               "the exact reviewed file inside the accepted official source is excluded")
        expect(library.manifest.tracks.count == 129,
               "the 129 official rows stay untouched")
    } catch {
        expect(false, "controller official-location fixture failed: \(error)")
    }

    // 11) A directory replaced between hash start and completion must fail: no start grant and no
    // false fingerprint baseline, even when the replacement holds identical bytes.
    do {
        let dir = try controllerFixtureRoot()
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("selected", isDirectory: true)
        let fileURL = root.appendingPathComponent("work/a.mp4")
        try writeControllerFile(fileURL, bytes: 128, fill: 7)
        let store = LocalSongStore(url: dir.appendingPathComponent("local-songs.json"))
        let hashGate = HashGate()
        let controller = LocalSongLibraryController(
            store: store, library: { library },
            seams: controllerSeams(store: store, hashGate: hashGate),
            makeMonitor: { _, _, _ in nil },
            onCatalog: { _, _ in })
        controller.load()
        controller.addRoot(root)
        expect(controllerWait { !controller.catalog.tracks.isEmpty && !controller.isScanning },
               "the replacement fixture scans before hashing")
        guard let track = controller.catalog.tracks.first,
              let file = track.sortedFiles.first else {
            expect(false, "the replacement fixture must produce one track")
            return
        }
        let originalBytes = try Data(contentsOf: fileURL)
        var granted = false
        var failure: String?
        controller.preparePlayback(trackID: track.id, fileID: file.id) { result in
            switch result {
            case .success: granted = true
            case .failure(let error):
                failure = (error as? LocalSongError)?.description ?? String(describing: error)
            }
        }
        expect(controllerWait { hashGate.hasStarted }, "the hash starts before the root is replaced")
        // Replace the whole accepted directory; the same bytes reappear at the same path so only
        // the root's filesystem identity changed.
        try FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("work"),
                                                withIntermediateDirectories: true)
        try originalBytes.write(to: root.appendingPathComponent("work/a.mp4"))
        hashGate.release()
        expect(controllerWait { granted || failure != nil },
               "a root replaced during hashing settles the request")
        expect(!granted, "a directory replaced during hashing must never yield a start grant")
        _ = controllerWait(timeout: 0.5) { granted }
        expect(!granted, "no late grant arrives after the replacement")
        expect(controller.catalog.tracks.first?.files.first?.sha256 == nil,
               "a replaced root must not store a false fingerprint baseline")
    } catch {
        expect(false, "controller root-replacement fixture failed: \(error)")
    }

    // 12) A pending legacy adoption whose save fails must return BEFORE reading the file: no grant,
    // no published adoption and no fingerprint baseline.
    do {
        let dir = try controllerFixtureRoot()
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("selected", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let validBookmark = try root.bookmarkData(options: [], includingResourceValuesForKeys: nil,
                                                  relativeTo: nil)
        let store = LocalSongStore(url: dir.appendingPathComponent("local-songs.json"))
        var seeded = LocalSongCatalog()
        // A legacy bookmark-only record whose stored bytes carry no usable historical identity.
        seeded.registerRoot(id: "root-legacy", displayPath: root.path, bookmark: Data([0x00]),
                            identity: nil)
        seeded.tracks = [LocalSongTrack(
            id: "t1", number: 1, rootID: "root-legacy", groupRelativePath: "",
            files: [LocalSongFile(id: "f1", relativePath: "a.mp4", basename: "a.mp4", byteSize: 8)],
            selectedFileID: "f1")]
        seeded.nextNumber = 2
        try store.save(seeded)
        let gate = FailingSaveGate(store: store)
        var seams = controllerSeams(store: store, gate: gate)
        seams.resolveRoot = { _ in (try DirectoryAccessLease.resolveTransfer(validBookmark), nil) }
        var failure: String?
        var granted = false
        let controller = LocalSongLibraryController(
            store: store, library: { library }, seams: seams,
            makeMonitor: { _, _, _ in nil },
            onCatalog: { _, _ in })
        controller.load()
        gate.failing = true
        controller.preparePlayback(trackID: "t1", fileID: "f1") { result in
            switch result {
            case .success: granted = true
            case .failure(let error):
                failure = (error as? LocalSongError)?.description ?? String(describing: error)
            }
        }
        expect(controllerWait { granted || failure != nil },
               "a failed root-identity adoption save settles the request")
        expect(!granted, "a failed adoption save must not yield a start grant")
        expect(failure?.contains("无法保存") == true,
               "a failed adoption save is surfaced as a store-write failure")
        expect(controller.catalog.root(id: "root-legacy")?.identity == nil,
               "the uncommitted adoption is never published to the catalog")
        expect(controller.catalog.tracks.first?.files.first?.sha256 == nil,
               "a failed adoption save stores no fingerprint baseline")
    } catch {
        expect(false, "controller failed-adoption fixture failed: \(error)")
    }

    // 13) Invalidating a root's scan also invalidates its pending playback: the late hash never
    // delivers a callback or a grant.
    do {
        let dir = try controllerFixtureRoot()
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("selected", isDirectory: true)
        try writeControllerFile(root.appendingPathComponent("work/a.mp4"), bytes: 96, fill: 5)
        let store = LocalSongStore(url: dir.appendingPathComponent("local-songs.json"))
        let hashGate = HashGate()
        var seams = controllerSeams(store: store, hashGate: hashGate)
        // Model the real failure: a plain bookmark can still resolve by path, so the controller's
        // resolve seam must report a removed directory as unavailable.
        seams.resolveRoot = { data in
            let lease = try DirectoryAccessLease.resolveTransfer(data)
            guard FileManager.default.fileExists(atPath: lease.url.path) else {
                throw LocalSongError.rootUnavailable(lease.url.path)
            }
            return (lease, nil)
        }
        let controller = LocalSongLibraryController(
            store: store, library: { library }, seams: seams,
            makeMonitor: { _, _, _ in nil },
            onCatalog: { _, _ in })
        controller.load()
        controller.addRoot(root)
        expect(controllerWait { !controller.catalog.tracks.isEmpty && !controller.isScanning },
               "the invalidation fixture scans before hashing")
        guard let track = controller.catalog.tracks.first,
              let file = track.sortedFiles.first else {
            expect(false, "the invalidation fixture must produce one track")
            return
        }
        var completions = 0
        var granted = false
        controller.preparePlayback(trackID: track.id, fileID: file.id) { result in
            completions += 1
            if case .success = result { granted = true }
        }
        expect(controllerWait { hashGate.hasStarted }, "the invalidation fixture starts its hash")
        // The root disappears: refreshing invalidates its scan and any pending request for it.
        try FileManager.default.removeItem(at: root)
        controller.refresh()
        hashGate.release()
        _ = controllerWait(timeout: 0.6) { completions > 0 }
        expect(completions == 0,
               "an invalidated root scan drops its pending request without a late callback")
        expect(!granted, "no start grant is delivered for a root whose scan was invalidated")
        expect(controller.catalog.roots.first?.isMissing == true,
               "the removed root is marked missing")
    } catch {
        expect(false, "controller root-invalidation fixture failed: \(error)")
    }

    // 14) Automatic discovery/admission for the same ADR-022 slice (separate focused file).
    runAutomaticSongResourceDiscoveryRegression(expect: expect)
}
