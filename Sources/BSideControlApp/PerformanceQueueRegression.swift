// Real browser projections over Core queue state; no directory scan, persistence or IPC.
import Foundation
import BSideCore
import BSidePlatform

func runPerformanceQueueRegression(expect: (Bool, String) -> Void) {
    // Library-wide random playback and one-click add-and-play: real browser projections plus the
    // owner-side queue edits the AppDelegate calls through. Runs first so it still executes when
    // the older projection below hits its fixture guard.
    // Measured: adds 162 checks (949 -> 1111) and all pass.
    runFilteredQueuePlaybackRegression(expect: expect)
    let browser = PerformanceBrowserModel()
    var additions: [(String, PerformancePresentation, PerformancePlaybackMode)] = []
    var starts: [String?] = []
    var removals: [String] = []
    var moves: [(String, Int)] = []
    var orders: [PerformanceQueueOrder] = []
    var clears = 0
    browser.enqueue = { additions.append(($0, $1, $2)) }
    browser.startQueue = { starts.append($0) }
    browser.removeQueueEntry = { removals.append($0) }
    browser.moveQueueEntry = { moves.append(($0, $1)) }
    browser.setQueueOrder = { orders.append($0) }
    browser.clearQueue = { clears += 1 }

    do {
        let library = try PerformanceLibrary.bundled()
        guard let track = library.manifest.tracks.first(where: { track in
            track.variants.contains { $0.lighting == .daylight && $0.presentation == .sidePerformance }
                && track.variants.contains { $0.lighting == .daylight && $0.presentation == .portraitPerformance }
        }) else {
            expect(false, "queue browser regression needs a track with both daylight cameras")
            return
        }
        browser.library = library
        browser.desired = DesiredState(timeMode: .fixed(.noon))
        browser.selectedID = track.id
        browser.presentation = .sidePerformance
        browser.playbackMode = .listen
        browser.unavailable = Dictionary(uniqueKeysWithValues: library.manifest.tracks.flatMap {
            $0.variants.map { ($0.id, "missing current candidate") }
        })
        browser.enqueueSelection()
        expect(browser.canEnqueueSelection && additions.count == 1
               && additions.first?.0 == track.id && additions.first?.1 == .sidePerformance
               && additions.first?.2 == .listen && starts.isEmpty
               && browser.queueState.configuration.entries.isEmpty,
               "enqueue must forward a supported selection without starting, scanning or mutating the owner's queue")
        browser.selectedID = "unknown-browser-selection"
        browser.enqueueSelection()
        expect(additions.count == 1 && !browser.canEnqueueSelection,
               "an unknown manifest selection must not be enqueued")
        browser.selectedID = track.id

        let first = PerformanceQueueEntry(id: "queue-first", performanceID: PerformanceID(track.id),
            presentation: .sidePerformance, mode: .listen)
        let second = PerformanceQueueEntry(id: "queue-second", performanceID: PerformanceID(track.id),
            presentation: .portraitPerformance, mode: .watch)
        let missing = PerformanceQueueEntry(id: "queue-missing", performanceID: PerformanceID("missing-manifest-track"),
            presentation: .sidePerformance, mode: .listen)
        let configuration = PerformanceQueueConfiguration(entries: [first, second, missing])
        browser.queueState = PerformanceQueueState(configuration: configuration)
        expect(!browser.queueState.isRunning && starts.isEmpty
               && browser.queueState.configuration.entries.count == 3,
               "restoring queue configuration must preserve duplicate songs and unknown IDs without autoplay")
        browser.selectedQueueEntryID = missing.id
        browser.playSelectedQueueEntry()
        browser.removeSelectedQueueEntry()
        expect(browser.queueEntryTitle(missing) == "不可用曲目"
               && browser.queueEntryUnavailableReason(missing) != nil && starts.isEmpty
               && removals == [missing.id] && browser.queueState.configuration == configuration,
               "unknown entries must stay visible and removable by entry ID, without silently disappearing or playing")

        browser.root = "/synthetic/bside-queue-regression-only"
        browser.serviceReady = true
        browser.scanned = true
        browser.selectedQueueEntryID = second.id
        let date = Date()
        guard let queuedPresentation = second.presentation,
              let variant = browser.selection(track.id, presentation: queuedPresentation, at: date) else {
            expect(false, "the queued explicit camera must resolve independently from browsing")
            return
        }
        browser.unavailable.removeValue(forKey: variant.variantID.rawValue)
        browser.playSelectedQueueEntry()
        expect(starts.count == 1 && starts[0] == second.id
               && browser.selectionProblem != nil && browser.selectedQueuePlaybackProblem == nil
               && browser.presentation == .sidePerformance && browser.playbackMode == .listen
               && browser.queueEntryDetail(second) == "正面素材",
               "queued playback must validate its saved camera and retain its mode without taking over browsing")
        browser.moveSelectedQueueEntry(by: -1)
        browser.removeSelectedQueueEntry()
        browser.setQueueOrder(.shuffle)
        expect(moves.count == 1 && moves[0].0 == second.id && moves[0].1 == -1
               && removals.last == second.id && orders == [.shuffle]
               && browser.queueState.configuration == configuration && starts.count == 1,
               "queue editing actions must forward exact entry IDs and defer all state changes to the owner")

        // A begin/bind is intent, not an Agent's confirmation. A previous session's report
        // cannot label either a handoff or the new queue entry as playing.
        let old = PerformanceSession(id: "queue-old-session", variant: variant, mode: .listen)
        browser.sessionState.start(old)
        browser.report = PerformanceReport(sessionID: old.id, state: .playing)
        _ = browser.queueState.begin(entryID: second.id, chooseIndex: { _ in 0 })
        expect(browser.sessionStatus == "等待队列切换"
               && browser.queueEntryStatus(second) == "等待队列切换"
               && browser.queueEntryStatus(first) == nil,
               "an unbound queue handoff must not borrow the previous session's playing report or mark duplicate entries active")
        let session = PerformanceSession(id: "queue-current-session", variant: variant, mode: second.mode)
        _ = browser.queueState.bind(sessionID: session.id)
        browser.sessionState.start(session)
        expect(browser.sessionStatus == "等待播放器确认",
               "binding a queue session must still wait for a matching Agent report")
        browser.report = PerformanceReport(sessionID: session.id, state: .playing)
        browser.queueState.setOrder(.repeatOne)
        browser.selectedID = library.manifest.tracks.first { $0.id != track.id }?.id
        browser.section = .queue
        expect(browser.sessionStatus == "播放中" && browser.sessionModeLabel == "观看演奏"
               && browser.sessionTitle == track.title && browser.queueState.activeEntry == second
               && browser.queueState.activeSessionID == session.id && starts.count == 1,
               "browsing and owner-applied order changes must not relabel or restart the currently reported queue session")

        _ = browser.queueState.remove(entryID: second.id)
        expect(browser.queueEditExplanation.contains("不会打断当前曲目")
               && browser.sessionState.session == session && browser.sessionStatus == "播放中",
               "removing the active entry must keep the current session projection and explain continued playback")
        browser.clearQueue()
        expect(clears == 1 && !browser.queueState.configuration.entries.isEmpty,
               "clear must be a forwarded owner action, not an implicit local stop")
        browser.queueState.clear()
        expect(browser.queueState.configuration.entries.isEmpty && browser.queueState.isRunning
               && browser.sessionState.session == session && browser.sessionStatus == "播放中"
               && browser.queueStartProblem != nil,
               "an owner-cleared queue must keep its current song visible while preventing a new empty queue start")
    } catch {
        expect(false, "queue browser metadata regression failed: \(error)")
    }
}

// MARK: - Filtered library random playback + one-click add-and-play

/// Drives the real browser model with the bundled 129-track manifest plus two synthetic local
/// songs, and the real owner-side `PerformanceQueueEdit` transitions `AppDelegate` calls. It
/// never reads, decodes or hashes media and never instantiates a window, Agent or player.
private func runFilteredQueuePlaybackRegression(expect: (Bool, String) -> Void) {
    guard let library = try? PerformanceLibrary.bundled() else {
        expect(false, "the filtered shuffle regression needs the bundled library")
        return
    }
    let model = PerformanceBrowserModel()
    model.library = library
    model.root = "/synthetic/bside-filtered-shuffle-regression-only"
    model.serviceReady = true
    model.scanned = true
    model.desired = DesiredState(timeMode: .fixed(.noon))
    model.presentation = .sidePerformance
    model.playbackMode = .listen

    // Synthetic local catalog: one single-file song and one two-version song.
    var catalog = LocalSongCatalog()
    catalog.registerRoot(id: "local.root.shuffle", displayPath: "/synthetic/local-shuffle",
                         bookmark: nil, identity: nil)
    catalog.applyScan(rootID: "local.root.shuffle", groups: [
        LocalSongScannedGroup(relativePath: "work1",
            files: [LocalSongScannedFile(relativePath: "work1/solo.mp4", basename: "solo.mp4", byteSize: 20)]),
        LocalSongScannedGroup(relativePath: "work2",
            files: [LocalSongScannedFile(relativePath: "work2/a.mp4", basename: "a.mp4", byteSize: 30),
                    LocalSongScannedFile(relativePath: "work2/b.mp4", basename: "b.mp4", byteSize: 40)]),
    ])
    model.localCatalog = catalog

    var batches: [[PerformanceQueueEntry]] = []
    var added: [PerformanceQueueEntry] = []
    var appendedOnly: [String] = []
    var starts: [String?] = []
    model.startFilteredShuffle = { batches.append($0) }
    model.addAndPlay = { added.append($0) }
    model.enqueue = { id, _, _ in appendedOnly.append(id) }
    model.enqueueLocal = { trackID, _, _ in appendedOnly.append(trackID) }
    model.startQueue = { starts.append($0) }

    // 1. The snapshot is EVERY filtered row (well beyond 100), never a List page, and every
    //    entry carries the browsing camera, mode and (for a local row) the remembered file.
    let visible = model.visibleRows
    let snapshot = model.visibleListSnapshot
    expect(visible.count == library.manifest.tracks.count + model.localTracks.count
           && visible.count > 100 && snapshot.count == visible.count,
           "the filtered snapshot must include every filtered library row, not a List page")
    expect(snapshot.count > 100, "the filtered snapshot must exceed 100 rows")
    expect(snapshot.allSatisfy { $0.mode == .listen },
           "every snapshot entry must keep the current listen/watch mode")
    var officialCaptured = 0
    var localCaptured = 0
    for entry in snapshot {
        switch entry.target {
        case .official(_, let presentation):
            officialCaptured += 1
            expect(presentation == .sidePerformance,
                   "an official snapshot entry must keep the current camera")
        case .localFile(let trackID, let fileID):
            localCaptured += 1
            expect(model.localTrack(trackID)?.selectedFileID == fileID && fileID == catalog.tracks
                    .first { $0.id == trackID }?.selectedFileID,
                   "a local snapshot entry must keep the remembered explicit file version")
        }
    }
    expect(officialCaptured == library.manifest.tracks.count && localCaptured == model.localTracks.count,
           "the snapshot must contain every official and local filtered row exactly once")
    let snapshotTargets = snapshot.map { $0.target.officialSelection?.performanceID.rawValue
        ?? $0.target.localSelection?.trackID ?? "" }
    expect(Set(snapshotTargets).count == snapshot.count
           && Set(snapshotTargets) == Set(visible.map(\.id)),
           "the snapshot identity must be the unique row identity for every visible row")

    // Narrowing the filters narrows the snapshot; browsing alone issues no playback command.
    model.categoryFilter = .classical
    let classicalSnapshot = model.visibleListSnapshot
    expect(classicalSnapshot.count == 48
           && classicalSnapshot.allSatisfy { $0.target.officialSelection != nil },
           "a category filter must narrow the snapshot to exactly those eligible rows")
    model.categoryFilter = .all
    model.search = "肖邦"
    expect(model.visibleListSnapshot.count == model.visibleRows.count
           && model.visibleListSnapshot.count < snapshot.count,
           "a search must narrow the snapshot to the visible matches")
    model.search = ""
    expect(batches.isEmpty && added.isEmpty && starts.isEmpty,
           "filtering and browsing must never issue a playback command")

    // A currently missing asset is excluded as unavailable, with no decode/hash fallback.
    guard let firstTrack = library.manifest.tracks.first,
          let firstVariant = model.selection(firstTrack.id) else {
        expect(false, "the bundled library must resolve a daylight side variant")
        return
    }
    model.unavailable[firstVariant.variantID.rawValue] = "missing"
    let reduced = model.visibleListSnapshot
    expect(reduced.count == snapshot.count - 1
           && !reduced.contains { $0.target.officialSelection?.performanceID.rawValue == firstTrack.id },
           "an unavailable row must be excluded from the snapshot, never retried or substituted")
    model.unavailable = [:]

    // 2. Empty/blocked snapshots never reach the owner.
    model.search = "不存在-的-曲名-shuffle-zzz"
    expect(model.visibleListSnapshot.isEmpty && model.filteredShuffleProblem != nil,
           "an empty filtered result must expose a blocking reason")
    model.startFilteredShufflePlayback()
    expect(batches.isEmpty, "an empty snapshot must never reach the owner")
    model.search = ""
    let blocked = PerformanceBrowserModel()
    blocked.library = library
    blocked.localCatalog = catalog
    blocked.serviceReady = false
    blocked.root = "/synthetic/bside-filtered-shuffle-regression-only"
    blocked.scanned = true
    blocked.desired = DesiredState(timeMode: .fixed(.noon))
    var blockedBatches: [[PerformanceQueueEntry]] = []
    blocked.startFilteredShuffle = { blockedBatches.append($0) }
    blocked.startFilteredShufflePlayback()
    expect(blocked.visibleListSnapshot.isEmpty && blockedBatches.isEmpty,
           "a blocked/not-ready library must not emit or start a snapshot")

    // 3. Owner-side edits: the snapshot replaces the whole queue and selects shuffle.
    let existingFirst = PerformanceQueueEntry(id: "existing-first",
        target: .official(performanceID: PerformanceID(library.manifest.tracks[0].id),
                          presentation: .sidePerformance), mode: .watch)
    var state = PerformanceQueueState(configuration: PerformanceQueueConfiguration(
        entries: [existingFirst], order: .repeatOne))
    expect(PerformanceQueueEdit.replaceWithShuffledSnapshot(&state, snapshot: snapshot),
           "a non-empty snapshot must replace the queue")
    expect(state.configuration.order == .shuffle
           && state.configuration.entries.map(\.id) == snapshot.map(\.id)
           && !state.configuration.entries.contains { $0.id == existingFirst.id },
           "the replacement must keep the snapshot order, select shuffle and drop the old entries")
    let replaced = state.configuration
    expect(!PerformanceQueueEdit.replaceWithShuffledSnapshot(&state, snapshot: [])
           && state.configuration == replaced,
           "an empty snapshot must leave the replaced queue and its shuffle order untouched")
    expect(!PerformanceQueueEdit.replaceWithShuffledSnapshot(&state, snapshot: [snapshot[0], snapshot[0]])
           && state.configuration == replaced,
           "a malformed snapshot must be refused as a whole, never partially applied")

    // Shuffle keeps its no-repeat-until-cycle behavior over the replaced snapshot.
    guard let shuffleStart = state.begin(entryID: nil, chooseIndex: { _ in 0 }),
          state.bind(sessionID: "shuffle-session") else {
        expect(false, "a replaced queue must begin a shuffle entry and accept its binding")
        return
    }
    var visited: Set<String> = [shuffleStart.id]
    var cycleComplete = true
    for _ in 1..<snapshot.count {
        guard case .play(let entry) = state.received(
            PerformanceReport(sessionID: "shuffle-session", state: .ended),
            chooseIndex: { _ in 0 }), state.bind(sessionID: "shuffle-session") else {
            cycleComplete = false
            break
        }
        visited.insert(entry.id)
    }
    expect(cycleComplete && visited.count == snapshot.count,
           "shuffle must visit every entry once before repeating any")
    expect(state.received(PerformanceReport(sessionID: "shuffle-session", state: .ended),
                          chooseIndex: { _ in 0 }) == .stopped,
           "shuffle must stop only after the whole cycle is complete, never repeat early")

    // 4. Add-and-play appends the exact entry and starts THAT new entry (not the first existing).
    let existingSecond = PerformanceQueueEntry(id: "existing-second",
        target: .official(performanceID: PerformanceID(library.manifest.tracks[1].id),
                          presentation: .sidePerformance), mode: .watch)
    var addState = PerformanceQueueState(configuration: PerformanceQueueConfiguration(
        entries: [existingFirst, existingSecond]))
    guard let newEntry = snapshot.last else {
        expect(false, "the snapshot must provide an add-and-play entry")
        return
    }
    guard let appended = PerformanceQueueEdit.appendForImmediatePlay(&addState, entry: newEntry) else {
        expect(false, "add-and-play must append the captured entry")
        return
    }
    expect(addState.configuration.entries.map(\.id) == [existingFirst.id, existingSecond.id, newEntry.id],
           "add-and-play must retain the existing queue entries and append the new one")
    guard let started = addState.begin(entryID: appended.id, chooseIndex: { _ in 0 }) else {
        expect(false, "add-and-play must start the appended entry")
        return
    }
    expect(started.id == newEntry.id && addState.configuration.entries.count == 3,
           "add-and-play must start the new entry, never the first existing one")
    expect(PerformanceQueueEdit.appendForImmediatePlay(&addState, entry: newEntry) == nil
           && addState.configuration.entries.count == 3,
           "a duplicate entry identity must be refused without mutating the queue")

    // 5. The model captures official/local selections and forwards them; append-only stays idle.
    model.selectedID = model.localTracks[0].id
    model.playbackMode = .listen
    guard let local = model.selectedLocalTrack, let localFileID = local.selectedFileID else {
        expect(false, "the local fixture must have an explicitly remembered file")
        return
    }
    expect(model.canAddSelectionAndPlay, "an available local selection must offer 加入并播放")
    model.addSelectionAndPlay()
    expect(added.count == 1 && added[0].target.localSelection?.trackID == local.id
           && added[0].target.localSelection?.fileID == localFileID && added[0].mode == .listen,
           "add-and-play must capture the exact local file and mode")
    model.enqueueSelection()
    expect(appendedOnly == [local.id] && added.count == 1 && batches.isEmpty && starts.isEmpty,
           "the append-only action must forward without starting anything")

    guard let official = library.manifest.tracks.first(where: {
        model.playbackProblem(id: $0.id, presentation: .sidePerformance) == nil
    }) else {
        expect(false, "the bundled library must resolve a playable official row")
        return
    }
    model.selectedID = official.id
    model.presentation = .sidePerformance
    model.playbackMode = .watch
    model.addSelectionAndPlay()
    expect(added.count == 2
           && added[1].target.officialSelection?.performanceID.rawValue == official.id
           && added[1].target.officialSelection?.presentation == .sidePerformance
           && added[1].mode == .watch,
           "add-and-play must capture the official target, camera and mode")
    model.selectedID = "unknown-browser-selection"
    expect(!model.canAddSelectionAndPlay,
           "an unknown selection must not offer 加入并播放")
    model.addSelectionAndPlay()
    expect(added.count == 2 && appendedOnly.count == 1 && batches.isEmpty && starts.isEmpty,
           "an invalid selection must not mutate the queue or interrupt playback")

    // 6. Queue row double-click starts exactly that entry, localfile included; an unknown row
    //    changes nothing. The existing keyboard/accessibility controls stay untouched.
    let officialEntry = PerformanceQueueEntry(id: "queue-official",
        target: .official(performanceID: PerformanceID(official.id), presentation: .sidePerformance),
        mode: .watch)
    let localEntry = PerformanceQueueEntry(id: "queue-local",
        target: .localFile(trackID: local.id, fileID: localFileID), mode: .listen)
    model.selectedQueueEntryID = nil
    model.queueState = PerformanceQueueState(configuration: PerformanceQueueConfiguration(
        entries: [officialEntry, localEntry]))
    model.playQueueEntryOnDoubleClick(localEntry.id)
    expect(starts == [localEntry.id] && model.selectedQueueEntryID == localEntry.id,
           "double-click must start exactly the clicked localfile queue entry")
    model.playQueueEntryOnDoubleClick("missing-queue-entry")
    expect(starts == [localEntry.id] && model.selectedQueueEntryID == localEntry.id,
           "an unknown queue row must not start, select or replace the running entry")
    model.selectedQueueEntryID = nil
    model.playQueueEntryOnDoubleClick(officialEntry.id)
    expect(starts == [localEntry.id, officialEntry.id],
           "double-click must start exactly the clicked official queue entry")
    expect(PerformanceQueueOrder.shuffle.controlLabel == "随机顺序",
           "the shuffle order must be labelled 随机顺序 in the order control")

    // 7. ADR-024 list playback: the same snapshot replaces the queue while the user's existing
    //    order is preserved, and the clicked row is the one that starts.
    var listBatches: [[PerformanceQueueEntry]] = []
    var listStarts: [String] = []
    model.startListPlayback = { snapshot, entryID in
        listBatches.append(snapshot)
        listStarts.append(entryID)
    }
    model.queueState.setOrder(.repeatAll)
    guard let listTrack = library.manifest.tracks.first(where: {
        model.playbackProblem(id: $0.id, presentation: .sidePerformance) == nil
    }) else {
        expect(false, "the bundled library must resolve a playable row for list playback")
        return
    }
    model.selectedID = listTrack.id
    model.playSelectedFromList()
    guard let listSnapshot = listBatches.last, let listStart = listStarts.last else {
        expect(false, "list play must emit one snapshot and one start entry")
        return
    }
    expect(listSnapshot.map(\.id) == model.visibleListSnapshot.map(\.id),
           "list play must capture exactly the visible eligible rows")
    expect(listStart == listSnapshot.first {
               $0.target.officialSelection?.performanceID.rawValue == listTrack.id }?.id,
           "list play must start the selected row's own snapshot entry")
    var listState = PerformanceQueueState(configuration: PerformanceQueueConfiguration(
        entries: [existingFirst, existingSecond], order: .repeatAll))
    expect(PerformanceQueueEdit.replaceWithListSnapshot(&listState, snapshot: listSnapshot),
           "a non-empty list snapshot must replace the queue")
    expect(listState.configuration.order == .repeatAll
           && !listState.configuration.entries.contains { $0.id == existingFirst.id },
           "list playback must keep the user's existing order and drop the old entries")
    expect(!PerformanceQueueEdit.replaceWithListSnapshot(&listState, snapshot: []),
           "an empty list snapshot must leave the queue untouched")

    // 8. Play Next: insert immediately after the active entry without interrupting it, and the
    //    explicit next survives shuffle.
    let priority = PerformanceQueueEntry(id: "priority-entry",
        target: .official(performanceID: PerformanceID("priority-song"),
                          presentation: .sidePerformance), mode: .watch)
    let nextA = PerformanceQueueEntry(id: "next-a", target: .official(
        performanceID: PerformanceID("next-a"), presentation: .sidePerformance), mode: .watch)
    let nextB = PerformanceQueueEntry(id: "next-b", target: .official(
        performanceID: PerformanceID("next-b"), presentation: .sidePerformance), mode: .watch)
    let nextC = PerformanceQueueEntry(id: "next-c", target: .official(
        performanceID: PerformanceID("next-c"), presentation: .sidePerformance), mode: .watch)
    var nextState = PerformanceQueueState(configuration: PerformanceQueueConfiguration(
        entries: [nextA, nextB, nextC], order: .stopAfterQueue))
    _ = nextState.begin(entryID: nextA.id, chooseIndex: { _ in 0 })
    _ = nextState.bind(sessionID: "next-active")
    expect(nextState.insertAfterActive(priority),
           "下一首播放 must insert while a queue entry is running")
    expect(nextState.activeEntry == nextA && nextState.activeSessionID == "next-active",
           "inserting must not change the current entry or its binding")
    expect(nextState.configuration.entries.map(\.id) == [nextA.id, priority.id, nextB.id, nextC.id],
           "下一首播放 must insert immediately after the active entry")
    expect(!nextState.insertAfterActive(priority),
           "a duplicate identity must not be inserted twice")
    expect(nextState.received(PerformanceReport(sessionID: "next-active", state: .ended),
                              chooseIndex: { _ in 0 }) == .play(priority),
           "the inserted entry must be the very next one played")
    _ = nextState.bind(sessionID: "priority-session")
    expect(nextState.received(PerformanceReport(sessionID: "priority-session", state: .ended),
                              chooseIndex: { _ in 0 }) == .play(nextB),
           "the priority is consumed once and does not replay")
    var shuffled = PerformanceQueueState(configuration: PerformanceQueueConfiguration(
        entries: [nextA, nextB, nextC], order: .shuffle))
    _ = shuffled.begin(entryID: nextB.id, chooseIndex: { _ in 0 })
    _ = shuffled.bind(sessionID: "shuffle-active")
    expect(shuffled.insertAfterActive(priority), "下一首播放 must work in shuffle too")
    expect(shuffled.received(PerformanceReport(sessionID: "shuffle-active", state: .ended),
                             chooseIndex: { _ in 0 }) == .play(priority),
           "an explicit next must outrank the shuffle draw once")
    var removedPriority = PerformanceQueueState(configuration: PerformanceQueueConfiguration(
        entries: [nextA, nextB], order: .shuffle))
    _ = removedPriority.begin(entryID: nextA.id, chooseIndex: { _ in 0 })
    _ = removedPriority.insertAfterActive(priority)
    _ = removedPriority.remove(entryID: priority.id)
    _ = removedPriority.bind(sessionID: "removed-priority")
    expect(removedPriority.received(PerformanceReport(sessionID: "removed-priority", state: .ended),
                                    chooseIndex: { _ in 0 }) == .play(nextB),
           "a removed priority must not be played")
    var idle = PerformanceQueueState(configuration: PerformanceQueueConfiguration(
        entries: [nextA, nextB]))
    expect(!idle.insertAfterActive(priority),
           "下一首播放 must be refused while nothing is playing")
}
