// BSideControlApp — focused local-song projection regression (ADR-022). Drives the real browser
// model with an explicitly injected local catalog: no bookmark, no store IO, no Agent, no player.
// It pins the contract that local rows coexist with official rows without being mislabeled.
import Foundation
import BSideCore
import BSidePlatform

private func localRegressionCatalog() -> LocalSongCatalog {
    var catalog = LocalSongCatalog()
    catalog.registerRoot(id: "local.root.r1", displayPath: "/synthetic/local-only",
                         bookmark: nil, identity: nil)
    let groups = [
        LocalSongScannedGroup(relativePath: "work1",
            files: [LocalSongScannedFile(relativePath: "work1/solo.mp4", basename: "solo.mp4", byteSize: 20)]),
        LocalSongScannedGroup(relativePath: "work2",
            files: [LocalSongScannedFile(relativePath: "work2/a.mp4", basename: "a.mp4", byteSize: 30),
                    LocalSongScannedFile(relativePath: "work2/b.mp4", basename: "b.mp4", byteSize: 40)]),
    ]
    catalog.applyScan(rootID: "local.root.r1", groups: groups)
    return catalog
}

func runLocalSongLibraryRegression(expect: (Bool, String) -> Void) {
    guard let library = try? PerformanceLibrary.bundled() else {
        expect(false, "the bundled library must load for the local library regression")
        return
    }
    let officialCount = library.manifest.tracks.count
    let model = PerformanceBrowserModel()
    model.library = library
    model.serviceReady = true
    model.localCatalog = localRegressionCatalog()
    let localTracks = model.localTracks
    expect(localTracks.count == 2, "each local group is one track in the ordinary library")

    if let local = localTracks.first {
        model.favoriteLocalTrackIDs = [local.id]
        model.onlyFavorites = true
        expect(model.localRows.map(\.id) == [local.id], "favorite filtering also covers local songs")
        model.styleFilter = .game
        expect(model.localRows.isEmpty, "local favorites never acquire an invented game style")
        model.clearLibraryFilters()
    }

    // Coexistence and total counts: new rows join the same list; official rows are unchanged.
    expect(model.rows.count == officialCount, "the official projection stays exactly the manifest")
    expect(model.visibleRows.count == officialCount + localTracks.count,
           "the visible library includes the new local rows")
    expect(model.libraryTotalCount == officialCount + localTracks.count,
           "the total count includes new rows")
    expect(model.libraryResultSummary == "显示 \(officialCount + localTracks.count) / \(officialCount + localTracks.count) 首",
           "the results line reports the unified visible/total counts")

    // All + search: local rows are visible under 全部 and are searchable by title and file name.
    expect(model.visibleRows.contains { $0.local != nil }, "local rows appear under 全部")
    model.search = "未命名曲目"
    expect(!model.localRows.isEmpty && model.localRows.allSatisfy { $0.displayTitle.hasPrefix("未命名曲目") },
           "a normal search matches the stable temporary titles")
    model.search = "solo.mp4"
    let soloTrack = localTracks.first { $0.files.contains { $0.basename == "solo.mp4" } }
    expect(model.localRows.map(\.id) == [soloTrack?.id].compactMap { $0 },
           "a search also matches the local file identification")
    model.search = ""

    // Narrowed category/source filters never mislabel a local row into them.
    model.categoryFilter = .classical
    expect(model.localRows.isEmpty, "a local row is not placed in 古典")
    model.categoryFilter = .piano
    expect(model.localRows.isEmpty, "a local row is not placed in 钢琴")
    model.categoryFilter = .vocal
    expect(model.localRows.isEmpty, "a local row is not placed in 弹唱")
    model.categoryFilter = .all
    model.sourceFilter = .source(PerformanceDisplay.unconfirmedSource)
    expect(model.localRows.isEmpty, "a local row never invents a reviewed composer/source label")
    model.sourceFilter = .all
    expect(model.localRows.count == 2, "clearing the filters restores the local rows")

    // Classification filters are independent and never change reviewed official assignments.
    let classifiedModel = PerformanceBrowserModel()
    classifiedModel.library = library
    var classifiedCatalog = localRegressionCatalog()
    let pianoID = classifiedCatalog.tracks[0].id
    let vocalID = classifiedCatalog.tracks[1].id
    try? classifiedCatalog.setClassification(trackID: pianoID, classification:
        LocalSongClassification(category: .piano, style: .gentle, origin: .automatic,
            analyzedFileID: classifiedCatalog.tracks[0].files[0].id, modelID: "local-test-model", modelRevision: "r1"))
    try? classifiedCatalog.setClassification(trackID: vocalID, classification:
        LocalSongClassification(category: .vocal, style: .bright, origin: .automatic))
    classifiedModel.localCatalog = classifiedCatalog
    classifiedModel.categoryFilter = .piano
    expect(classifiedModel.localRows.map(\.id) == [pianoID], "local piano enters the piano category")
    classifiedModel.styleFilter = .bright
    expect(classifiedModel.localRows.isEmpty, "category and mood filters combine independently with AND")
    classifiedModel.styleFilter = .gentle
    expect(classifiedModel.localRows.map(\.id) == [pianoID], "matching category and mood retain the local song")
    classifiedModel.categoryFilter = .classical
    expect(classifiedModel.localRows.isEmpty, "audible piano does not imply reviewed classical repertoire")
    classifiedModel.clearLibraryFilters()
    classifiedModel.categoryFilter = .vocal
    expect(classifiedModel.localRows.map(\.id) == [vocalID], "local vocals enter the existing vocal category")

    let officialCategoryCounts: [PerformanceCategoryFilter: Int] = [
        .all: 129, .classical: 48,
        .piano: library.manifest.tracks.filter { $0.kind == .pianoSolo }.count - 48,
        .vocal: library.manifest.tracks.filter { $0.kind == .vocalPerformance }.count,
        .instrumental: 0, .unclassified: 0]
    for (filter, count) in officialCategoryCounts {
        classifiedModel.categoryFilter = filter
        expect(classifiedModel.rows.count == count,
               "official category count stays unchanged for \(filter.rawValue)")
    }
    classifiedModel.clearLibraryFilters()
    let reviewedStyles: [PerformanceStyleFilter] = [.classical, .game, .folk, .other]
    var officialStyleIDs = Set<String>()
    for filter in reviewedStyles {
        classifiedModel.styleFilter = filter
        let expected = library.manifest.tracks.filter { PerformanceStyleFilter.group($0) == filter }.map(\.id)
        expect(Set(classifiedModel.rows.map(\.id)) == Set(expected),
               "the reviewed official style assignment stays intact for \(filter.rawValue)")
        officialStyleIDs.formUnion(expected)
    }
    expect(officialStyleIDs.count == officialCount, "existing styles still account for every official song")
    for style in LocalSongStyle.allCases where style != .unclassified {
        classifiedModel.styleFilter = PerformanceStyleFilter(rawValue: style.rawValue)!
        expect(classifiedModel.rows.isEmpty, "new local mood buckets do not include official rows")
    }

    // Both pickers use the real model action, retain the other field and mark manual provenance.
    classifiedModel.clearLibraryFilters()
    classifiedModel.selectedID = pianoID
    classifiedModel.favoriteLocalTrackIDs = [pianoID]
    classifiedModel.queueState.append(PerformanceQueueEntry(trackID: pianoID,
        fileID: classifiedCatalog.tracks[0].files[0].id, mode: .listen))
    classifiedModel.sessionState.start(PerformanceSession(target: .localFile(LocalPerformanceReference(
        trackID: pianoID, fileID: classifiedCatalog.tracks[0].files[0].id,
        catalogRevision: classifiedCatalog.catalogRevision)), mode: .listen))
    let queueBefore = classifiedModel.queueState
    let sessionBefore = classifiedModel.sessionState
    let desiredBefore = classifiedModel.desired
    var playbackCommands = 0
    classifiedModel.playLocal = { _, _, _ in playbackCommands += 1 }
    classifiedModel.classifyLocal = { trackID, classification in
        var candidate = classifiedModel.localCatalog!
        try? candidate.setClassification(trackID: trackID, classification: classification)
        classifiedModel.localCatalog = candidate
    }
    classifiedModel.setLocalClassification(trackID: pianoID, category: .instrumental)
    expect(classifiedModel.localTrack(pianoID)?.classification ==
           LocalSongClassification(category: .instrumental, style: .gentle, origin: .manual),
           "a category correction retains mood and clears automatic provenance")
    classifiedModel.setLocalClassification(trackID: pianoID, style: .majestic)
    expect(classifiedModel.localTrack(pianoID)?.classification ==
           LocalSongClassification(category: .instrumental, style: .majestic, origin: .manual),
           "a mood correction retains the latest committed category")
    classifiedModel.categoryFilter = .instrumental
    classifiedModel.styleFilter = .majestic
    expect(classifiedModel.localRows.map(\.id) == [pianoID], "manual corrections immediately update both filters")
    classifiedModel.setLocalClassification(trackID: pianoID, category: .unclassified, style: .unclassified)
    classifiedModel.categoryFilter = .unclassified
    classifiedModel.styleFilter = .other
    expect(classifiedModel.localRows.map(\.id) == [pianoID], "explicit uncertainty uses the unclassified filters")
    expect(classifiedModel.selectedID == pianoID
           && classifiedModel.queueState.configuration == queueBefore.configuration
           && classifiedModel.queueState.activeEntry == queueBefore.activeEntry
           && classifiedModel.queueState.activeSessionID == queueBefore.activeSessionID
           && classifiedModel.queueState.isRunning == queueBefore.isRunning
           && classifiedModel.queueState.paused == queueBefore.paused
           && classifiedModel.sessionState.session == sessionBefore.session
           && classifiedModel.desired == desiredBefore
           && classifiedModel.favoriteLocalTrackIDs == [pianoID] && playbackCommands == 0
           && classifiedModel.localCatalog?.roots == classifiedCatalog.roots
           && classifiedModel.localTrack(pianoID)?.selectedFileID == classifiedCatalog.tracks[0].selectedFileID,
           "classification preserves selection, playback, queue, favorites, volumes, roots and file choice")
    model.categoryFilter = .unclassified
    model.styleFilter = .other
    expect(model.localRows.count == 2, "legacy nil classification remains visibly unclassified")
    model.clearLibraryFilters()

    // Neutral versions: 版本1/2 over the stable basename order, never a camera label.
    guard let multi = localTracks.first(where: { $0.files.count == 2 }) else {
        expect(false, "the fixture must provide a multi-file local track")
        return
    }
    expect(multi.sortedFiles.map(\.basename) == ["a.mp4", "b.mp4"], "versions are ordered by basename")
    expect(model.localVersionLabel(multi, file: multi.sortedFiles[0]) == "版本1"
           && model.localVersionLabel(multi, file: multi.sortedFiles[1]) == "版本2",
           "versions are neutral positional labels, not official camera labels")
    expect(model.localVersionLabel(multi, file: multi.sortedFiles[0]).contains("侧") == false,
           "no official camera wording leaks into a local version label")

    // Explicit selection: the remembered file is the exact target, and it can be changed.
    model.selectedID = multi.id
    expect(model.selectedLocalTrack?.id == multi.id, "a local row can be selected")
    expect(model.selectionProblem == nil, "an available local selection has no blocking problem")
    var started: [(String, String, PerformancePlaybackMode)] = []
    model.playLocal = { started.append(($0, $1, $2)) }
    model.selectLocalFile = { trackID, fileID in
        var updated = model.localCatalog ?? LocalSongCatalog()
        try? updated.selectFile(trackID: trackID, fileID: fileID)
        model.localCatalog = updated
    }
    model.playbackMode = .watch
    model.playSelection()
    expect(started.count == 1 && started[0].0 == multi.id
           && started[0].1 == multi.sortedFiles[0].id && started[0].2 == .watch,
           "explicit playback uses exactly the remembered file and mode")
    model.selectLocalFile(multi.id, multi.sortedFiles[1].id)
    model.playSelection()
    expect(started.count == 2 && started[1].1 == multi.sortedFiles[1].id,
           "a changed preferred version is the exact next target")
    // Double-click continues through the current list: the snapshot replaces the queue and the
    // local entry keeps the EXACT file selected at click time (a later change never retargets it).
    var listSnapshots: [[PerformanceQueueEntry]] = []
    var listStarts: [String] = []
    model.startListPlayback = { snapshot, entryID in
        listSnapshots.append(snapshot)
        listStarts.append(entryID)
    }
    model.playListRow(multi.id)
    expect(listSnapshots.count == 1 && listStarts.count == 1,
           "double-click must start one list snapshot")
    guard let localEntry = listSnapshots[0].first(where: { $0.target.localSelection?.trackID == multi.id }) else {
        expect(false, "the local row must appear inside the double-click snapshot")
        return
    }
    expect(localEntry.target.localSelection?.fileID == multi.sortedFiles[1].id,
           "the snapshot must keep the local file version selected at click time")
    expect(localEntry.id == listStarts[0],
           "the started entry must be the clicked local row's own snapshot entry")

    // Queue capture: the entry records the file chosen at enqueue time and is never retargeted.
    var enqueued: [(String, String, PerformancePlaybackMode)] = []
    model.enqueueLocal = { trackID, fileID, mode in
        enqueued.append((trackID, fileID, mode))
        _ = model.queueState.append(PerformanceQueueEntry(trackID: trackID, fileID: fileID, mode: mode))
    }
    model.selectLocalFile(multi.id, multi.sortedFiles[0].id)
    model.enqueueSelection()
    expect(enqueued.count == 1 && enqueued[0].1 == multi.sortedFiles[0].id,
           "enqueue captures the file selected at that moment")
    guard let captured = model.queueState.configuration.entries.last else {
        expect(false, "a local enqueue must append a queue entry")
        return
    }
    model.selectLocalFile(multi.id, multi.sortedFiles[1].id)
    expect(captured.target.localSelection?.fileID == multi.sortedFiles[0].id,
           "changing the preferred version never retargets the already queued entry")
    expect(model.queueEntryTitle(captured) == multi.displayTitle,
           "a local queue entry shows its track title")
    expect(model.queueEntryContext(captured) == nil,
           "a local queue entry carries no source class, only its own title")
    expect(model.queueEntryDetail(captured) == "版本1",
           "a local queue detail names the exact neutral version and mode, not a camera or source class")
    expect(model.queueEntryUnavailableReason(captured) == nil,
           "an available local queue entry has no blocking reason")

    // Missing file: a previously populated catalog rescanned with no present groups retains its
    // records, marks the row unavailable, and never falls back to a sibling or another folder.
    let missingModel = PerformanceBrowserModel()
    missingModel.library = library
    var missingCatalog = localRegressionCatalog()
    missingCatalog.applyScan(rootID: "local.root.r1", groups: [])
    missingModel.localCatalog = missingCatalog
    guard let missingTrack = missingModel.localTracks.first else {
        expect(false, "the missing-file fixture must keep its retained track records")
        return
    }
    expect(!missingModel.localTrackIsAvailable(missingTrack), "a missing local track is unavailable")
    expect(missingModel.localSelectionProblem(missingTrack) != nil,
           "a missing selected file reports a problem instead of falling back")
    missingModel.onlyFound = true
    expect(missingModel.localRows.isEmpty, "only-found hides an unavailable local track")
    expect(!missingModel.visibleRows.contains { $0.local != nil },
           "an unavailable local track adds no visible row while only-found is active")

    // Legacy official queue projection still works beside local entries.
    let legacyEntry = PerformanceQueueEntry(id: "legacy-official",
        performanceID: PerformanceID(library.manifest.tracks[0].id),
        presentation: .sidePerformance, mode: .watch)
    expect(model.queueEntryTitle(legacyEntry) == library.manifest.tracks[0].title,
           "a legacy official queue entry keeps its title projection")
    expect(model.queueEntryContext(legacyEntry) != nil,
           "an official queue entry keeps its curated context")

    // A local session carries no source classification in the shared session strip: its title
    // and neutral version already identify it.
    let localReference = LocalPerformanceReference(trackID: multi.id, fileID: multi.sortedFiles[0].id,
                                                   catalogRevision: model.localCatalog?.catalogRevision
                                                       ?? PerformanceCatalogRevision("local.1.0"))
    model.sessionState.start(PerformanceSession(target: .localFile(localReference), mode: .listen))
    expect(model.sessionTargetLabels.isEmpty,
           "a local session adds no source/lighting/camera label")
    expect(model.sessionTitle == multi.displayTitle, "a local session keeps its track title")
}
