import Foundation
import BSideCore
import BSidePlatform

func runMediaRetentionRegression(expect: (Bool, String) -> Void) {
    do {
        let library = try PerformanceLibrary.bundled()
        guard let vocal = library.manifest.tracks.first(where: { $0.kind == .vocalPerformance }),
              let keeper = vocal.variants.first(where: { $0.presentation == .portraitPerformance && $0.lighting == .night }),
              let retired = vocal.variants.first(where: { $0.presentation == .sidePerformance && $0.lighting == .daylight }) else {
            expect(false, "retention fixture requires one admitted vocal song"); return
        }
        let model = PerformanceBrowserModel()
        model.library = library; model.root = "/retention-fixture"; model.scanned = true; model.serviceReady = true
        model.desired.timeMode = .fixed(.noon)
        let desired = model.desired
        let legacy = model.selection(vocal.id, presentation: .sidePerformance)
        expect(legacy?.variantID.rawValue == retired.id, "absent curation preserves exact official lighting and camera")
        let official = MediaRetentionDocument.Official(performanceID: vocal.id,
            catalogRevision: library.snapshot.revision, retainedVariantID: keeper.id)
        model.mediaRetention = .loaded(.init(version: 1, official: [official], local: []))
        expect(model.retentionProblem == nil, "reviewed same-song official choice is accepted")
        model.unavailable = Dictionary(uniqueKeysWithValues: vocal.variants.filter { $0.id != keeper.id }.map { ($0.id, "retired") })
        expect(model.selection(vocal.id, presentation: .sidePerformance)?.variantID.rawValue == keeper.id,
               "direct official resolution uses the reviewed keeper regardless of old camera and lighting")
        expect(model.preferredPresentation(for: vocal.id) == .portraitPerformance && model.hasCandidate(vocal.id),
               "automatic browsing and found filter agree with the retained official choice")
        expect(model.libraryAvailabilitySummary == "曲库已就绪" && model.requiredUnavailableVariants.isEmpty,
               "intentionally retired cells are excluded from readiness counts")
        let officialQueue = PerformanceQueueEntry(id: "saved-queue", performanceID: PerformanceID(vocal.id),
                                                  presentation: .sidePerformance, mode: .listen)
        model.queueState = PerformanceQueueState(configuration: .init(entries: [officialQueue], order: .repeatAll))
        model.selectedQueueEntryID = officialQueue.id
        let savedQueue = model.queueState.configuration
        expect(model.selectedQueuePlaybackProblem == nil, "saved official queue camera resolves through the same keeper")
        let history = SongPlaybackRecord(target: .catalog(legacy!), mode: .listen, title: "Original title", lastPlayed: Date())
        model.songHistory = [history]
        expect(try model.historyPlaybackTarget(history).0.officialVariant?.variantID.rawValue == keeper.id,
               "official history replay resolves an existing retired variant to its reviewed keeper")
        expect(model.songHistoryUnavailableReason(history) == nil, "retired official history remains replayable")
        expect(model.songHistory == [history] && model.queueState.configuration == savedQueue && model.desired == desired,
               "resolution preserves original history, queue identity/order/mode and daily time")
        model.unavailable[keeper.id] = "keeper missing"
        expect(!model.hasCandidate(vocal.id) && model.songHistoryUnavailableReason(history) != nil,
               "missing official keeper blocks browsing and history without fallback")
        model.unavailable[keeper.id] = nil

        let hash = String(repeating: "a", count: 64)
        let binding = PerformanceFileBinding(relativePath: "song/keep.mp4", byteSize: 10, sha256: hash)
        let localChoice = MediaRetentionDocument.Local(trackID: "local", retainedFileID: "keep", binding: binding)
        let oldFile = LocalSongFile(id: "old", relativePath: "song/old.mp4", basename: "old.mp4", byteSize: 11,
            sha256: String(repeating: "b", count: 64), fingerprintByteSize: 11, isPresent: false)
        let keptFile = LocalSongFile(id: "keep", relativePath: binding.relativePath, basename: "keep.mp4", byteSize: 10)
        var local = LocalSongCatalog(nextNumber: 2,
            roots: [.init(id: "root", displayPath: "/retention-fixture", bookmark: Data([1]))],
            tracks: [.init(id: "local", number: 1, customTitle: "Preserved title", rootID: "root",
                groupRelativePath: "song", files: [oldFile, keptFile], selectedFileID: "old",
                classification: .init(category: .piano, style: .gentle, origin: .manual))])
        model.localCatalog = local
        let document = MediaRetentionDocument(version: 1, official: [official], local: [localChoice])
        model.mediaRetention = .loaded(document)
        model.selectedID = "local"; model.favoriteLocalTrackIDs = ["local"]
        let originalLocal = model.localCatalog
        expect(model.localSelectionProblem(local.tracks[0]) == nil && model.displayedLocalFiles(local.tracks[0]) == [keptFile],
               "local readiness and visible options use only the retained file")
        expect(model.playableSelectionEntry?.target == .localFile(trackID: "local", fileID: "keep"),
               "new local queue and list entries capture the keeper")
        var playedLocal: String?
        model.playLocal = { _, fileID, _ in playedLocal = fileID }
        model.playSelection()
        expect(playedLocal == "keep", "single local play uses the same reviewed keeper")
        expect(model.visibleListSnapshot.contains(where: { $0.target == .localFile(trackID: "local", fileID: "keep") }),
               "visible-list playback includes the retained local file")
        let oldBinding = PerformanceFileBinding(relativePath: oldFile.relativePath, byteSize: 11, sha256: oldFile.sha256!)
        let localHistory = SongPlaybackRecord(target: .localFile(.init(trackID: "local", fileID: "old", catalogRevision: .init("previous"))),
            fileBinding: oldBinding, mode: .watch, title: "Original local title", lastPlayed: Date())
        expect(try model.historyPlaybackTarget(localHistory).1 == binding && model.songHistoryUnavailableReason(localHistory) == nil,
               "retired local history uses the reviewed keeper binding before its first playback")
        model.songNavigation.installed(sessionID: "previous", item: .init(record: localHistory, queueEntry: nil))
        _ = model.songNavigation.received(.init(sessionID: "previous", state: .playing), at: Date())
        model.songNavigation.installed(sessionID: "current", item: .init(record: history, queueEntry: officialQueue))
        _ = model.songNavigation.received(.init(sessionID: "current", state: .playing), at: Date())
        model.sessionState.start(.init(id: "current", target: history.target, mode: .listen))
        expect(model.canPreviousSong, "Previous can replay a retired local history identity through its keeper")
        let localQueue = PerformanceQueueEntry(id: "old-local-queue", trackID: "local", fileID: "old", mode: .listen)
        expect(model.queueEntryUnavailableReason(localQueue) == nil, "old local queue references remain usable")
        expect(model.localCatalog == originalLocal && model.favoriteLocalTrackIDs == ["local"],
               "retention leaves titles, classification, selected file, favorites and all catalog records unchanged")
        local.tracks[0].files[1].isPresent = false; model.localCatalog = local
        expect(model.localSelectionProblem(local.tracks[0]) != nil && !model.canPreviousSong,
               "missing local keeper blocks selection and Previous without using retired siblings")
        local.tracks[0].files[1].isPresent = true; local.tracks[0].files[1].byteSize = 12; model.localCatalog = local
        expect(model.songHistoryUnavailableReason(localHistory) != nil, "changed keeper metadata blocks history readiness")
        local.tracks[0].files[1].byteSize = 10; model.localCatalog = local
        expect((try? model.localPlaybackChoice(trackID: "local", requestedFileID: "foreign")) == nil,
               "curation cannot legitimize an unknown saved source file")

        let invalidDocuments = [
            MediaRetentionDocument(version: 2, official: [official], local: []),
            .init(version: 1, official: [official, official], local: []),
            .init(version: 1, official: [.init(performanceID: vocal.id, catalogRevision: .init("wrong"), retainedVariantID: keeper.id)], local: []),
            .init(version: 1, official: [.init(performanceID: "unknown", catalogRevision: library.snapshot.revision, retainedVariantID: keeper.id)], local: []),
            .init(version: 1, official: [], local: [.init(trackID: "local", retainedFileID: "foreign", binding: binding)]),
            .init(version: 1, official: [], local: [.init(trackID: "local", retainedFileID: "keep",
                binding: .init(relativePath: "../keep.mp4", byteSize: 10, sha256: hash))])
        ]
        for invalid in invalidDocuments {
            model.mediaRetention = .loaded(invalid)
            expect(model.retentionProblem != nil && model.selection(vocal.id) == nil
                && model.localSelectionProblem(local.tracks[0]) != nil,
                "invalid curation blocks both song kinds without downgrading to legacy behavior")
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bside-retention-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("media-retention.json")
        expect(MediaRetentionState.load(from: url) == .absent, "missing map preserves legacy operation without writing")
        let bytes = try JSONEncoder().encode(document)
        try bytes.write(to: url)
        model.mediaRetention = MediaRetentionState.load(from: url)
        expect(model.retentionProblem == nil && model.displayedLocalFile(local.tracks[0])?.id == "keep",
               "map reload restores the same reviewed choices against the current catalog")
        _ = local.applyScan(rootID: "root", groups: [.init(relativePath: "song", files: [
            .init(relativePath: "song/keep.mp4", basename: "keep.mp4", byteSize: 10)])])
        model.localCatalog = local
        expect(model.retentionProblem == nil && model.localCatalog?.tracks[0].selectedFileID == "old"
            && model.localCatalog?.tracks[0].files.count == 2 && model.localTrackIsAvailable(local.tracks[0]),
               "rescan retains retired records and explicit selection while keeper readiness stays consistent")
        expect(try Data(contentsOf: url) == bytes, "catalog publication and resolution never rewrite the reviewed map")
        try Data("{broken".utf8).write(to: url)
        model.mediaRetention = MediaRetentionState.load(from: url)
        expect(try model.retentionProblem != nil && Data(contentsOf: url) == Data("{broken".utf8),
               "malformed map is visible and preserved byte-for-byte")
        model.mediaRetention = .absent
        expect(model.selection(vocal.id, presentation: .sidePerformance) == legacy,
               "removing the explicit map restores exact legacy official resolution")
    } catch { expect(false, "retention model regression threw \(error)") }

    runRetainedLocalGrantRegression(expect: expect)
}

private func runRetainedLocalGrantRegression(expect: (Bool, String) -> Void) {
    do {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bside-retained-grant-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("media")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 32).write(to: root.appendingPathComponent("keeper.mp4"))
        let fingerprint = try LocalFileVerifier.fingerprint(url: root.appendingPathComponent("keeper.mp4"))
        let bookmark = try root.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let lease = try DirectoryAccessLease.resolveTransfer(bookmark)
        let store = LocalSongStore(url: directory.appendingPathComponent("local-songs.json"))
        let catalog = LocalSongCatalog(nextNumber: 2,
            roots: [.init(id: "root", displayPath: root.path, bookmark: bookmark,
                          identity: DirectoryIdentityResolver.explicitSelection(fresh: lease.identitySnapshot(provenance: .explicitSelection)))],
            tracks: [.init(id: "track", number: 1, rootID: "root", groupRelativePath: "", files: [
                .init(id: "keeper", relativePath: "keeper.mp4", basename: "keeper.mp4", byteSize: 32)], selectedFileID: "keeper")])
        try store.save(catalog)
        let before = try Data(contentsOf: store.url)
        var seams = LocalSongLibrarySeams.production
        seams.resolveRoot = { (try DirectoryAccessLease.resolveTransfer($0), nil) }
        let controller = LocalSongLibraryController(store: store, library: { nil }, seams: seams,
            makeMonitor: { _, _, _ in nil }, onCatalog: { _, _ in })
        controller.load()
        var result: Result<LocalPlaybackGrant, Error>?
        func waitForResult() {
            let deadline = Date().addingTimeInterval(4)
            while result == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        }
        controller.preparePlayback(trackID: "track", fileID: "keeper", expectedBinding:
            .init(relativePath: "keeper.mp4", byteSize: 32, sha256: String(repeating: "0", count: 64))) { result = $0 }
        waitForResult()
        if case .failure? = result { expect(true, "wrong reviewed hash refuses a local grant") }
        else { expect(false, "wrong reviewed hash must refuse a local grant") }
        expect(try controller.catalog.tracks[0].files[0].sha256 == nil && Data(contentsOf: store.url) == before,
               "failed keeper hash cannot establish or persist a fingerprint")
        result = nil
        let binding = PerformanceFileBinding(relativePath: "keeper.mp4", byteSize: 32, sha256: fingerprint.sha256)
        controller.preparePlayback(trackID: "track", fileID: "keeper", expectedBinding: binding) { result = $0 }
        waitForResult()
        if case .success(let grant)? = result {
            expect(grant.binding == binding && grant.reference.fileID == "keeper",
                   "verified keeper grants its exact file identity through the existing transfer path")
        } else { expect(false, "matching reviewed keeper must receive a grant") }
        result = nil
        controller.preparePlayback(trackID: "track", fileID: "keeper", expectedBinding:
            .init(relativePath: "different.mp4", byteSize: 32, sha256: fingerprint.sha256)) { result = $0 }
        if case .failure? = result { expect(true, "retained relative-path mismatch fails before hashing") }
        else { expect(false, "retained relative-path mismatch must fail before hashing") }
    } catch { expect(false, "retained local grant regression threw \(error)") }
}
