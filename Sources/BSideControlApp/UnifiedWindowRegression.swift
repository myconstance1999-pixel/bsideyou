// BSideControlApp — unified candidate window + library filter regression.
//
// Behavioural only: it drives the real models through their real commands and asserts what the
// user-visible surface would show. Native window fixtures are never ordered or fullscreened;
// it never starts an Agent or creates a player. `expect` is the in-house runner's check
// closure.
import Foundation
import AppKit
import SwiftUI
import Combine
import BSideCore
import BSidePlatform

func runUnifiedWindowRegression(expect: (Bool, String) -> Void) {
    runLibraryFilterRegression(expect: expect)
    runClassicalCategoryRegression(expect: expect)
    runUnifiedNavigationRegression(expect: expect)
    runCompanionPresentationRegression(expect: expect)
    runCompanionWindowRegression(expect: expect)
    runCompanionTransitionLayoutRegression(expect: expect)
    runMusicStripSizingRegression(expect: expect)
    runHomepageMusicRegression(expect: expect)
    runStatusQuickMenuRegression(expect: expect)
    runCompanionMusicControlRegression(expect: expect)
    runWatchDesktopAutoHideRegression(expect: expect)
}

// MARK: - Library filters (category + source/composer, AND with search and only-found)

private func runLibraryFilterRegression(expect: (Bool, String) -> Void) {
    guard let library = try? PerformanceLibrary.bundled() else {
        expect(false, "the bundled library must load for the unified library filter regression")
        return
    }
    let tracks = library.manifest.tracks
    let model = PerformanceBrowserModel()
    model.library = library

    // Every browsing call is recorded; none of them may happen from a filter/page change.
    var plays: [String] = []
    var pauses = 0
    var stops = 0
    var enqueues: [String] = []
    var starts: [String?] = []
    model.play = { id, _, _ in plays.append(id) }
    model.pause = { pauses += 1 }
    model.stop = { stops += 1 }
    model.enqueue = { id, _, _ in enqueues.append(id) }
    model.startQueue = { starts.append($0) }

    // Cold launch defaults: no filter, complete list, nothing selected or playing.
    expect(model.categoryFilter == .all && model.sourceFilter == .all && !model.onlyFound
           && model.search.isEmpty && !model.hasActiveLibraryFilters,
           "a cold launch must default every library filter to all/off")
    expect(model.rows.map(\.id) == tracks
            .filter { _ in true }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            .map(\.id),
           "with no filter the library shows every track in the established sort order")

    // Category filter uses the verified kind plus the explicit reviewed classical ID set:
    // 全部/古典/钢琴/弹唱 is a real partition, not an overlapping view.
    model.categoryFilter = .classical
    let classical = model.rows
    expect(!classical.isEmpty
           && classical.allSatisfy { PerformanceClassicalCatalog.contains($0) },
           "the 古典 filter must show exactly the reviewed classical track IDs")
    model.categoryFilter = .piano
    let piano = model.rows
    expect(piano.allSatisfy { $0.kind == .pianoSolo && !PerformanceClassicalCatalog.contains($0) },
           "the 钢琴 filter must show the remaining pianoSolo tracks only")
    model.categoryFilter = .vocal
    let vocal = model.rows
    expect(vocal.count == tracks.filter { $0.kind == .vocalPerformance }.count
           && vocal.allSatisfy { $0.kind == .vocalPerformance },
           "the 弹唱 filter must show exactly the vocalPerformance tracks")
    expect(classical.count + piano.count == tracks.filter { $0.kind == .pianoSolo }.count,
           "古典 + 钢琴 must partition the pianoSolo tracks with no overlap and nothing lost")
    expect(classical.count + piano.count + vocal.count == tracks.count,
           "古典 + 钢琴 + 弹唱 must partition the whole library")
    model.categoryFilter = .all
    expect(model.rows.count == tracks.count, "全部 must restore the complete library")

    // Source/composer menu comes from existing metadata and includes the unknown bucket.
    let sources = model.availableSources
    expect(sources.contains(PerformanceDisplay.unconfirmedSource),
           "the source menu must include the explicit unknown bucket")
    expect(sources.contains("崩坏3") && sources.contains("原神"),
           "the source menu must be built from the existing curated metadata")
    expect(sources == sources.sorted { $0.localizedStandardCompare($1) == .orderedAscending },
           "the source menu must be deterministic for two identical renders")
    expect(Set(sources).count == sources.count, "the source menu must not repeat a value")
    let unknownTracks = tracks.filter {
        (PerformanceDisplay.context(for: $0)?.source ?? PerformanceDisplay.unconfirmedSource)
            == PerformanceDisplay.unconfirmedSource
    }
    expect(!unknownTracks.isEmpty,
           "the bundled metadata must still contain unconfirmed origins for the unknown bucket")

    // Unknown bucket selects unconfirmed tracks and nothing else.
    model.sourceFilter = .source(PerformanceDisplay.unconfirmedSource)
    expect(!model.rows.isEmpty && model.rows.allSatisfy { track in
        (PerformanceDisplay.context(for: track)?.source ?? PerformanceDisplay.unconfirmedSource)
            == PerformanceDisplay.unconfirmedSource
    }, "the unknown source filter must show only unconfirmed-origin tracks")

    // Picker round-trip: the sentinel never leaks a curated label into the unknown bucket.
    let unknownPickerValue = model.sourceFilter.pickerValue
    expect(unknownPickerValue == PerformanceSourceFilter.unknownValue,
           "the selected unknown source must match its actual picker tag")
    expect(PerformanceSourceFilter.fromPickerValue(unknownPickerValue)
            == .source(PerformanceDisplay.unconfirmedSource),
           "the unknown bucket must survive a picker round-trip")
    expect(PerformanceSourceFilter.fromPickerValue("崩坏3") == .source("崩坏3")
           && PerformanceSourceFilter.fromPickerValue("") == .all,
           "a curated source and the all value must round-trip unchanged")

    // Category AND source AND search AND only-found combine.
    let known = tracks.first { track in
        (PerformanceDisplay.context(for: track)?.source ?? "") == "原神"
    }
    guard let known else {
        expect(false, "the bundled metadata must still attribute at least one 原神 track")
        return
    }
    model.sourceFilter = .source("原神")
    let sourceOnly = model.rows
    expect(!sourceOnly.isEmpty && sourceOnly.allSatisfy {
        (PerformanceDisplay.context(for: $0)?.source ?? "") == "原神"
    }, "a curated source filter must show only that source")

    model.categoryFilter = .piano
    let combined = model.rows
    expect(combined.allSatisfy { $0.kind == .pianoSolo }
           && combined.allSatisfy { (PerformanceDisplay.context(for: $0)?.source ?? "") == "原神" }
           && combined.count <= sourceOnly.count,
           "category and source must combine with AND")
    model.categoryFilter = .vocal
    model.search = "不存在-的-曲名-zzz"
    expect(model.rows.isEmpty && !model.libraryResultSummary.isEmpty,
           "a search with no match must produce an empty result and still report counts")
    expect(model.libraryResultSummary == "显示 0 / \(tracks.count) 首",
           "the result line must report visible/total even when nothing matches")
    model.search = ""
    model.categoryFilter = .piano
    model.sourceFilter = .all
    let pianoCount = model.rows.count
    model.onlyFound = true
    // No scan has run, so only-found legitimately yields nothing; it must AND, not replace.
    expect(model.rows.isEmpty && pianoCount > 0,
           "only-found must AND with the other filters rather than override them")
    model.onlyFound = false
    expect(model.rows.count == pianoCount,
           "clearing only-found must restore the category-filtered list unchanged")

    // Long titles and a full result line must not change filter semantics.
    model.categoryFilter = .all
    model.sourceFilter = .all
    model.search = "的"
    expect(model.rows.allSatisfy { PerformanceDisplay.matches($0, search: "的") },
           "the search surface must still reach title/subtitle/aliases under other filters")
    model.search = ""

    // Clear-all resets every filter in one action.
    model.categoryFilter = .vocal
    model.sourceFilter = .source(PerformanceDisplay.unconfirmedSource)
    model.onlyFound = true
    model.search = "肖邦"
    expect(model.hasActiveLibraryFilters, "the clear action must be enabled while a filter is set")
    model.clearLibraryFilters()
    expect(!model.hasActiveLibraryFilters && model.categoryFilter == .all
           && model.sourceFilter == .all && !model.onlyFound && model.search.isEmpty,
           "clear-all must reset search, category, source and only-found together")
    expect(model.rows.count == tracks.count, "clear-all must restore the full library")

    // Selection and playback are never touched by filtering, even when the playing row is hidden.
    model.desired = DesiredState(timeMode: .fixed(.noon))
    let playingTrack = tracks.first { $0.kind == .vocalPerformance }
        ?? tracks.first { $0.kind == .pianoSolo }
    guard let playingTrack, let variant = model.selection(playingTrack.id) else {
        expect(false, "the bundled library must resolve a variant for the non-stop playback check")
        return
    }
    model.selectedID = playingTrack.id
    model.sessionState.start(PerformanceSession(variant: variant, mode: .listen))
    let sessionID = model.sessionState.session?.id
    model.categoryFilter = playingTrack.kind == .pianoSolo ? .vocal : .piano
    expect(!model.rows.contains { $0.id == playingTrack.id },
           "the active track may legitimately be hidden by a category filter")
    expect(model.selectedID == playingTrack.id && model.sessionState.session?.id == sessionID
           && model.sessionStatus == "等待播放器确认",
           "hiding the active track must keep the selection and the running session alive")
    expect(plays.isEmpty && pauses == 0 && stops == 0 && enqueues.isEmpty && starts.isEmpty,
           "filtering, searching and browsing must never issue a playback command")
    model.clearLibraryFilters()

    // Filters are memory-only per instance: a different browser (the next cold launch) starts
    // from the same defaults, so no filter survived the previous one to any shared store.
    let relaunched = PerformanceBrowserModel()
    relaunched.library = library
    expect(relaunched.categoryFilter == .all && relaunched.sourceFilter == .all
           && !relaunched.onlyFound && relaunched.search.isEmpty
           && relaunched.rows.count == tracks.count,
           "a new launch must start on all/all with no filter carried over")
}

// MARK: - Classical category: explicit reviewed IDs, exact partition, no string heuristic

/// Focused behavioural regression for the 全部/古典/钢琴/弹唱 category split. It drives the real
/// browser model and the bundled manifest/curated metadata only: no window, no Agent, no player
/// and no source-text matching. The reviewed classical set is locked by ID and count so a metadata
/// or manifest drift cannot silently move a track between categories.
private func runClassicalCategoryRegression(expect: (Bool, String) -> Void) {
    guard let library = try? PerformanceLibrary.bundled() else {
        expect(false, "the bundled library must load for the classical category regression")
        return
    }
    let tracks = library.manifest.tracks
    let byID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
    let reviewed = PerformanceClassicalCatalog.reviewed
    let reviewedIDs = reviewed.map(\.id)

    // The reviewed set itself: non-empty, no duplicate ID, stable reviewed count.
    expect(!reviewed.isEmpty, "the reviewed classical set must not be empty")
    expect(Set(reviewedIDs).count == reviewedIDs.count,
           "the reviewed classical set must not repeat a manifest track ID")
    expect(PerformanceClassicalCatalog.trackIDs.count == reviewed.count,
           "the classical membership set must be derived from the reviewed entries only")
    expect(reviewed.count == 48,
           "the reviewed classical count is locked at 48; a curation change must update this audit")

    // Every reviewed ID is real, is a piano track, and still carries the composer that justified it.
    let missing = reviewedIDs.filter { byID[$0] == nil }
    expect(missing.isEmpty,
           "every reviewed classical ID must exist in the bundled manifest: \(missing.sorted())")
    let nonPiano = reviewedIDs.filter { byID[$0]?.kind != .pianoSolo }
    expect(nonPiano.isEmpty,
           "classical membership must stay a subset of pianoSolo (Vocal is unchanged): \(nonPiano.sorted())")
    let driftedComposer = reviewed.filter {
        PerformanceDisplayTable.contexts[$0.id]?.source != $0.composer
    }.map(\.id)
    expect(driftedComposer.isEmpty,
           "every reviewed classical entry must still match its PerformanceDisplayTable composer: \(driftedComposer.sorted())")

    // Unknown/unconfirmed origins are never classical: they keep the existing piano/vocal bucket.
    let unconfirmed = tracks.filter { PerformanceDisplay.context(for: $0)?.confidence == .unconfirmed }
    expect(!unconfirmed.isEmpty,
           "the bundled metadata must still contain unconfirmed origins for the fallback check")
    expect(unconfirmed.allSatisfy { !PerformanceClassicalCatalog.contains($0) },
           "an unconfirmed origin must never be placed in 古典")
    expect(unconfirmed.filter { $0.kind == .pianoSolo }
            .allSatisfy { PerformanceCategoryFilter.piano.matches($0) },
           "an unconfirmed piano track must keep the existing 钢琴 bucket")
    expect(unconfirmed.filter { $0.kind == .vocalPerformance }
            .allSatisfy { PerformanceCategoryFilter.vocal.matches($0) },
           "an unconfirmed vocal track must keep the unchanged 弹唱 bucket")

    // Documented exclusion set: game-OST arrangements and contemporary crossover originals stay
    // out of 古典 even though they are piano tracks.
    let excludedFromClassical = [
        "olivia.performance.solo.a-dramatic-irony",       // 崩坏：星穹铁道 game OST
        "olivia.performance.solo.wildfire",                // 崩坏：星穹铁道 game OST
        "olivia.performance.solo.a-new-day-with-hope",     // 原神 game OST
        "olivia.performance.solo.croatian-rhapsody",       // 马克西姆·姆尔维察, contemporary original
        "olivia.performance.solo.lyphard-melody",          // 理查德·克莱德曼, contemporary original
        "olivia.performance.solo.wedding-of-love",         // 保罗·塞内维尔, contemporary original
        "olivia.performance.solo.footprints",              // 来源未确认
        "olivia.performance.solo.honkai-star-rail-opening-theme", // 来源未确认
        "olivia.performance.solo.where-did-you-go",        // 来源未确认
    ]
    expect(excludedFromClassical.allSatisfy { !PerformanceClassicalCatalog.contains(id: $0) },
           "modern, crossover and unconfirmed piano tracks must stay out of the classical bucket")

    // The explicitly reviewed classical adaptation stays in.
    expect(PerformanceClassicalCatalog.contains(id: "olivia.performance.solo.flight-of-the-bumblebee-jazz-version"),
           "the reviewed jazz adaptation of 野蜂飞舞 must remain 古典")

    // Exactly one narrow category matches every track: the three buckets are mutually exclusive.
    let narrow: [PerformanceCategoryFilter] = [.classical, .piano, .vocal]
    let multiplyMatched = tracks.filter { track in
        narrow.filter { $0.matches(track) }.count != 1
    }.map(\.id)
    expect(multiplyMatched.isEmpty,
           "every track must belong to exactly one of 古典/钢琴/弹唱: \(multiplyMatched.sorted())")
    expect(PerformanceCategoryFilter.allCases.map(\.label) == ["全部", "古典", "钢琴", "弹唱", "其他器乐", "待分类"],
           "the category picker must retain reviewed categories and append local instrumental/unclassified options")

    // Real model rows: exact membership, locked counts and the established sort order.
    let model = PerformanceBrowserModel()
    model.library = library
    model.categoryFilter = .classical
    let classicalRows = model.rows
    expect(Set(classicalRows.map(\.id)) == PerformanceClassicalCatalog.trackIDs,
           "the 古典 filter must show exactly the reviewed classical IDs")
    expect(classicalRows.count == 48, "the 古典 filter must show the reviewed 48 tracks")
    let expectedOrder = tracks
        .filter { PerformanceClassicalCatalog.contains($0) }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        .map(\.id)
    expect(classicalRows.map(\.id) == expectedOrder,
           "the 古典 filter must preserve the established title sort order")
    expect(classicalRows.allSatisfy { PerformanceDisplay.rowContext(for: $0) != nil },
           "classical rows must keep their reviewed source/composer row label")
    model.categoryFilter = .piano
    expect(model.rows.count == 50, "the 钢琴 filter must show the remaining 50 piano tracks")
    model.categoryFilter = .vocal
    expect(model.rows.count == 31, "the 弹唱 filter must keep the unchanged 31 vocal tracks")
    model.categoryFilter = .all
    expect(model.rows.count == 129, "全部 must keep exposing all 129 tracks")

    // Search and only-found must AND with the classical category, never replace it.
    model.categoryFilter = .classical
    model.search = "肖邦"
    expect(!model.rows.isEmpty && model.rows.allSatisfy {
        PerformanceClassicalCatalog.contains($0) && PerformanceDisplay.matches($0, search: "肖邦")
    }, "a search inside 古典 must intersect the classical set, not widen it")
    model.sourceFilter = .source("原神")
    expect(model.rows.isEmpty,
           "a classical category AND a game-OST source must intersect to nothing")
    model.sourceFilter = .all
    model.search = ""
    let classicalCount = model.rows.count
    model.onlyFound = true
    expect(model.rows.isEmpty && classicalCount == 48,
           "only-found must still AND with the classical category")
    model.onlyFound = false
    expect(model.rows.count == classicalCount,
           "clearing only-found must restore the classical list unchanged")
    model.clearLibraryFilters()
    expect(model.categoryFilter == .all && model.rows.count == tracks.count,
           "clear-all must reset the classical category with the other filters")

    // Double-click stays the existing select-and-play path while a classical filter is active.
    let playback = PerformanceBrowserModel()
    playback.library = library
    playback.root = "/synthetic/bside-classical-regression-only"
    playback.serviceReady = true
    playback.scanned = true
    playback.desired = DesiredState(timeMode: .fixed(.noon))
    playback.presentation = .sidePerformance
    playback.categoryFilter = .classical
    var started: [String] = []
    var snapshots: [[PerformanceQueueEntry]] = []
    playback.startListPlayback = { snapshot, entryID in
        snapshots.append(snapshot)
        started.append(entryID)
    }
    guard let playable = classicalRows.first(where: {
        playback.selection($0.id, presentation: .sidePerformance) != nil
    }) else {
        expect(false, "at least one reviewed classical track must resolve a daylight camera")
        return
    }
    expect(playback.rows.contains { $0.id == playable.id },
           "the fixture classical track must be visible under the classical filter")
    playback.playListRow(playable.id)
    expect(started.count == 1 && playback.selectedID == playable.id
           && snapshots.first?.contains { entry in
               entry.target.officialSelection?.performanceID.rawValue == playable.id
           } == true,
           "double-click must select the clicked row and start it inside the current list snapshot under 古典")

    // Transient lifecycle: the category survives page changes inside one launch, a fresh
    // browser starts on 全部, and filtering issues no playback command by itself.
    let navigation = CandidateNavigationModel()
    navigation.select(.library)
    playback.categoryFilter = .classical
    navigation.select(.daily)
    navigation.select(.library)
    expect(playback.categoryFilter == .classical,
           "the classical filter must survive a page change within the same launch")
    expect(started.count == 1,
           "page changes and filtering must never issue another playback command")
    let relaunched = PerformanceBrowserModel()
    relaunched.library = library
    expect(relaunched.categoryFilter == .all && relaunched.rows.count == tracks.count,
           "a new launch must start on 全部 with no classical filter carried over")
}

// MARK: - On-demand home controls

private func runCompanionPresentationRegression(expect: (Bool, String) -> Void) {
    let navigation = CandidateNavigationModel()
    expect(!navigation.hasAuxiliaryPanel && !navigation.showsStudyControls,
           "a new home must not open a library panel or optional timer")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("bsidemac-home-study-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("study.json")
    var clock = 100.0
    let study = StudyTimerController(fileURL: file, uptime: { clock })
    defer { study.shutdown() }
    study.configure(title: "Navigation check")
    study.start()
    let sessionID = study.ledger.active?.id
    let saved = try? Data(contentsOf: file)
    expect(saved != nil && sessionID != nil, "the navigation fixture must have a real saved active session")

    navigation.showStudyControls()
    expect(navigation.showsStudyControls, "requesting study must reveal its controls on home")
    navigation.select(.library)
    expect(navigation.hasAuxiliaryPanel && !navigation.showsStudyControls && navigation.hasVisitedLibrary,
           "opening the library must unmount the optional timer readout and retain the native list")
    navigation.closePanel()
    expect(!navigation.hasAuxiliaryPanel && navigation.showsStudyControls && navigation.hasVisitedLibrary,
           "closing a panel must restore the requested timer without discarding the library")
    navigation.hideStudyControls()
    clock += 7
    expect(!navigation.showsStudyControls && study.isRunning && study.ledger.active?.id == sessionID
           && study.presentation.elapsed == 7,
           "hiding timer controls must not pause, replace or reset the actual session")
    navigation.select(.study)
    expect(navigation.hasAuxiliaryPanel && !navigation.showsStudyControls,
           "the history entry must show records without mounting another timer")
    navigation.select(.settings)
    navigation.closePanel()
    expect(!navigation.showsStudyControls && study.ledger.records.isEmpty
           && (try? Data(contentsOf: file)) == saved,
           "opening and closing records/settings must not write study data or restore a hidden timer")
    navigation.showStudyControls()
    expect(navigation.showsStudyControls && study.ledger.active?.id == sessionID,
           "reopening optional study controls must reveal the same active session")
}

// MARK: - Unified navigation lifecycle

private final class CompanionPresentationWindowFixture: CompanionMainWindow {
    var fixtureFullScreen = false
    override var styleMask: NSWindow.StyleMask {
        get { fixtureFullScreen ? super.styleMask.union(.fullScreen) : super.styleMask.subtracting(.fullScreen) }
        set { super.styleMask = newValue }
    }
}

private func runCompanionWindowRegression(expect: (Bool, String) -> Void) {
    let window = CompanionPresentationWindowFixture(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 740),
        styleMask: [.titled, .resizable], backing: .buffered, defer: true)
    let stale = CompanionPresentationWindowFixture(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
    let owner = CompanionWindowPresentation()
    var requests: [NSWindow] = []
    owner.performToggle = { requests.append($0) }
    owner.attach(window)
    owner.toggle(); owner.toggle()
    expect(requests.count == 1 && requests.first === window && owner.isTransitioning
           && !owner.isFullScreen && !owner.usesImmersiveLayout,
           "the same retained window receives one native request, never optimistic fullscreen or reentry")
    owner.willTransition(window); owner.willTransition(window)
    expect(owner.usesImmersiveLayout && !owner.isFullScreen,
           "native entry prepares destination layout once while confirmed fullscreen remains false")
    owner.willTransition(stale); owner.didTransition(stale); owner.failed(stale)
    expect(owner.isTransitioning && owner.usesImmersiveLayout && owner.failure == nil,
           "a different window cannot settle or roll back the active transition")
    owner.failed(window)
    expect(!owner.isTransitioning && !owner.isFullScreen && !owner.usesImmersiveLayout && owner.failure != nil,
           "native entry rejection restores ordinary layout while preserving actual window state")
    // The native green button can begin a transition without a model-issued request.
    owner.willTransition(window); window.fixtureFullScreen = true; owner.didTransition(window)
    expect(owner.isFullScreen && owner.usesImmersiveLayout && !owner.isTransitioning && owner.failure == nil,
           "only the native completion with fullscreen style confirms immersive presentation")
    window.exitCompanionFullScreen = { owner.request(fullScreen: false) }
    let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: 0, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
    window.sendEvent(escape); window.sendEvent(escape)
    expect(requests.count == 2 && requests.last === window && owner.isTransitioning && owner.isFullScreen,
           "Escape requests one native exit on the same window and retains confirmed state during transition")
    owner.willTransition(window)
    expect(!owner.usesImmersiveLayout && owner.isFullScreen,
           "native exit restores the ordinary layout before fullscreen completion")
    owner.failed(window)
    expect(owner.usesImmersiveLayout && owner.isFullScreen && !owner.isTransitioning && owner.failure != nil,
           "failed exit rolls layout back to the actual fullscreen window")
    window.sendEvent(escape); owner.willTransition(window)
    window.fixtureFullScreen = false; owner.didTransition(window)
    expect(!owner.isFullScreen && !owner.usesImmersiveLayout && !owner.isTransitioning,
           "native exit restores the ordinary retained home")
    owner.attach(stale); owner.willTransition(window)
    expect(!owner.isTransitioning, "retired window notifications cannot change a newly attached window")
}

private func runCompanionTransitionLayoutRegression(expect: (Bool, String) -> Void) {
    let navigation = CandidateNavigationModel(), music = PerformanceBrowserModel()
    let presentation = CompanionWindowPresentation(), preview = CompanionHomePreview()
    let window = CompanionPresentationWindowFixture(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 740),
        styleMask: [.titled, .resizable], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    let studyFile = FileManager.default.temporaryDirectory.appendingPathComponent("fullscreen-layout-\(UUID().uuidString).json")
    music.message = "音乐已暂停。"
    music.search = "retained search"
    navigation.select(.library)
    let host = NSHostingView(rootView: UnifiedCandidateWindow(
        navigation: navigation, controlCenter: ControlCenterModel(), performance: music,
        study: StudyTimerController(fileURL: studyFile), dailyActivity: DailyActivityRecommendationModel(),
        dailyBackgrounds: DailyBackgroundChooserModel(), homePreview: preview, presentation: presentation,
        showQueuePage: {}, makeSettingsActions: { fatalError("settings is not visited by the layout fixture") }))
    window.contentView = host
    presentation.attach(window)
    func flushLayout() {
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
    }
    func picture(in view: NSView) -> HomeCompanionFrameView? {
        if let picture = view as? HomeCompanionFrameView { return picture }
        return view.subviews.lazy.compactMap { picture(in: $0) }.first
    }
    flushLayout()
    guard let surface = picture(in: host) else {
        expect(false, "the real unified home must mount its native picture surface in the layout fixture")
        return
    }
    let normal = surface.convert(surface.bounds, to: host)
    expect(normal.minX > host.bounds.minX && normal.minY > host.bounds.minY
           && normal.maxX < host.bounds.maxX && normal.maxY < host.bounds.maxY,
           "ordinary layout reserves real header, transport and library space around the picture; picture=\(normal) host=\(host.bounds)")
    expect(surface.layer?.cornerRadius == 16 && surface.layer?.contentsGravity == .resizeAspect,
           "ordinary picture styling keeps the established rounded aspect-fit native surface")
    var layoutPublications: [Bool] = []
    let observation = presentation.$usesImmersiveLayout.dropFirst().sink { layoutPublications.append($0) }
    defer { observation.cancel() }
    presentation.willTransition(window); flushLayout()
    let preparedEntry = surface.convert(surface.bounds, to: host)
    expect(preparedEntry == host.bounds && !presentation.isFullScreen,
           "the same native picture fills the complete fullscreen canvas before native entry completes")
    expect(surface.layer?.cornerRadius == 0 && surface.layer?.contentsGravity == .resizeAspect,
           "video-only fullscreen removes every surrounding control and real layer corner while preserving aspect fit")
    host.additionalSafeAreaInsets = NSEdgeInsets(top: 33, left: 0, bottom: 0, right: 0)
    flushLayout()
    expect(surface.convert(surface.bounds, to: host) == preparedEntry,
           "a native fullscreen safe-area inset cannot introduce a second picture layout inside the content view")
    window.fixtureFullScreen = true; presentation.didTransition(window); flushLayout()
    expect(picture(in: host) === surface && surface.convert(surface.bounds, to: host) == preparedEntry,
           "entry completion retains the mounted surface and prepared geometry without a second reflow")
    presentation.willTransition(window); flushLayout()
    let preparedExit = surface.convert(surface.bounds, to: host)
    expect(preparedExit == normal && presentation.isFullScreen,
           "the header, feedback and library regain their original geometry before native exit completes")
    expect(surface.layer?.cornerRadius == 16,
           "leaving video-only layout restores the established native picture corners")
    window.fixtureFullScreen = false; presentation.didTransition(window); flushLayout()
    host.additionalSafeAreaInsets = NSEdgeInsetsZero
    flushLayout()
    expect(picture(in: host) === surface && surface.convert(surface.bounds, to: host) == preparedExit
           && layoutPublications == [true, false],
           "exit completion preserves surface identity and geometry with no completion-time layout publication")
    expect(navigation.page == .library && music.search == "retained search",
           "transition preparation retains the selected panel and its browsing state")
}

private func runMusicStripSizingRegression(expect: (Bool, String) -> Void) {
    let music = PerformanceBrowserModel(), control = ControlCenterModel()
    let song = PerformanceSession(id: "sizing-song", target: .localFile(.init(trackID: "track", fileID: "file", catalogRevision: .init("test"))))
    music.sessionState.start(song)
    music.receivePicturePresentation(.init(sessionID: song.id, state: .collapsed))
    let host = NSHostingView(rootView: SharedMusicStrip(model: music, control: control, showQueuePage: {}))
    host.frame = NSRect(x: 0, y: 0, width: 960, height: 96)
    host.layoutSubtreeIfNeeded()
    expect(host.fittingSize.width <= 960 && host.fittingSize.height <= 96,
           "actual active music hosting view fits the supported minimum width without forcing window growth")
    music.desired.paused = true
    host.layoutSubtreeIfNeeded()
    expect(host.fittingSize.width <= 960 && host.fittingSize.height <= 96,
           "the honest Resume all action preserves the bounded transport size")
    let companion = PerformanceBrowserModel()
    control.resourceConfigured = true
    control.apply(desired: DesiredState(dailySoundtrack: .track(ContentID("ambient://1"))), stage: .ready, stageDetail: "",
        snapshot: RuntimeSnapshot(state: .playing, dailyAmbientTrackCount: 3, dailyAmbientTracks: [AmbientTrack(id: ContentID("ambient://1"), index: 1, label: "陪伴音乐")]), supervision: .running)
    let companionHost = NSHostingView(rootView: SharedMusicStrip(model: companion, control: control, showQueuePage: {}))
    companionHost.frame = NSRect(x: 0, y: 0, width: 960, height: 96)
    companionHost.layoutSubtreeIfNeeded()
    expect(!HomepageMusicCardState.make(companion).canPlaySelected
           && NotchMusicState.make(companion, control: control).canPause,
           "cold companion context has one enabled primary soundtrack action and no selected-song launch")
    expect(companionHost.fittingSize.width <= 960 && companionHost.fittingSize.height <= 96,
           "actual companion transport fits the minimum width")
    if let library = try? PerformanceLibrary.bundled() {
        companion.library = library; companion.root = "/synthetic/companion-layout-only"
        companion.serviceReady = true; companion.scanned = true
        companion.desired = DesiredState(timeMode: .fixed(.noon))
        companion.selectedID = companion.rows.first(where: {
            companion.selection($0.id, presentation: .sidePerformance) != nil
        })?.id
        companionHost.layoutSubtreeIfNeeded()
        expect(HomepageMusicCardState.make(companion).canPlaySelected,
               "a real playable selection exposes the existing secondary song launch")
        expect(companionHost.fittingSize.width <= 960 && companionHost.fittingSize.height <= 96,
               "companion pause plus selected-song/random actions remain bounded at minimum width")
    } else { expect(false, "bundled library is required for selected-song layout coverage") }

}

private func runUnifiedNavigationRegression(expect: (Bool, String) -> Void) {
    let navigation = CandidateNavigationModel()
    expect(navigation.page == .daily && !navigation.hasVisitedLibrary,
           "a cold launch must select daily without mounting the library")
    expect(CandidatePage.allCases.map(\.label) == ["日常", "曲库", "队列", "记录", "设置"],
           "existing entry points must keep their purpose, with study history opening records")
    expect(Set(CandidatePage.allCases.map(\.systemImage)).count == 5,
           "each auxiliary destination must keep a distinct symbol")

    var selected: [CandidatePage] = []
    var publications = 0
    let observation = navigation.objectWillChange.sink { publications += 1 }
    defer { observation.cancel() }
    navigation.onPageSelected = { selected.append($0) }
    expect(!navigation.select(.daily) && publications == 0,
           "reselecting the initial daily page must not invalidate the shell")
    expect(navigation.select(.library) && navigation.hasVisitedLibrary,
           "the first library visit must make its browsing state available for retention")
    expect(!navigation.select(.library) && publications == 1,
           "reselecting the library must not publish a redundant shell update")
    navigation.select(.queue)
    navigation.select(.settings)
    navigation.select(.daily)
    expect(selected == [.library, .queue, .settings, .daily],
           "only a real page change may fire the page-selected projection")
    expect(publications == 4, "each real page change must invalidate navigation exactly once")
    expect(navigation.page == .daily && navigation.hasVisitedLibrary,
           "leaving the library must retain its browsing state for this window")

    // Menu/shortcut entries select the matching page without issuing playback.
    let model = PerformanceBrowserModel()
    var plays: [String] = []
    var pauses = 0
    var stops = 0
    model.play = { id, _, _ in plays.append(id) }
    model.pause = { pauses += 1 }
    model.stop = { stops += 1 }
    navigation.select(.library)
    model.search = "肖邦"
    model.categoryFilter = .classical
    navigation.select(.daily)
    navigation.select(.library)
    expect(model.search == "肖邦" && model.categoryFilter == .classical,
           "filters must persist across page changes within the same launch")
    expect(plays.isEmpty && pauses == 0 && stops == 0,
           "page changes must never issue a playback command")

    // The shell's single music strip is a real projection of the shared browser model. It needs
    // the bundled fixture loaded; without it the model exposes no track at all.
    expect(model.sessionState.session == nil && !model.queueState.isRunning,
           "the strip must start idle rather than claiming playback")
    guard let library = try? PerformanceLibrary.bundled() else {
        expect(false, "the bundled fixture must load for the strip regression")
        return
    }
    model.library = library
    model.desired = DesiredState(timeMode: .fixed(.noon))
    // Resolve against the real catalog instead of assuming the first manifest entry has a
    // variant for the model's current lighting/presentation.
    var stripFixture: (track: PerformanceManifest.Track, variant: ResolvedPerformanceVariant)?
    for candidate in library.manifest.tracks {
        if let variant = model.selection(candidate.id) {
            stripFixture = (candidate, variant)
            break
        }
    }
    if let (track, variant) = stripFixture {
        let session = PerformanceSession(variant: variant, mode: .listen)
        model.sessionState.start(session)
        model.report = PerformanceReport(sessionID: session.id, state: .playing)
        expect(model.sessionTitle == track.title && model.sessionStatus == "播放中",
               "the shared strip must show the real session title and Agent-confirmed state")
        expect(model.sessionPauseActionTitle == "暂停音乐",
               "a listening session must offer the music-specific pause label")
        model.pause()
        expect(pauses == 1, "the strip's pause must reach the shared model command")
        model.stop()
        expect(stops == 1, "the strip's stop must reach the shared model command")
    } else {
        expect(false, "the bundled fixture must resolve a variant for the strip regression")
    }
}

// MARK: - Homepage music-first card

/// Behavioural regression for the homepage music-first card. It drives the SHARED
/// `PerformanceBrowserModel` through the same commands the card forwards and asserts the pure
/// `HomepageMusicCardState` projection the card renders. No SwiftUI view, window, Agent or player
/// is created, and the assertions pin model behaviour (snapshot, selected file, filter, queue)
/// rather than restating the projection's own formulas.
private func runHomepageMusicRegression(expect: (Bool, String) -> Void) {
    guard let library = try? PerformanceLibrary.bundled() else {
        expect(false, "the bundled library must load for the homepage music regression")
        return
    }

    func loaded() -> PerformanceBrowserModel {
        let model = PerformanceBrowserModel()
        model.library = library
        model.root = "/synthetic/bside-homepage-regression-only"
        model.serviceReady = true
        model.scanned = true
        model.desired = DesiredState(timeMode: .fixed(.noon))
        model.presentation = .sidePerformance
        return model
    }

    // 1) Cold/idle: with no library and no selection the card offers nothing and its commands are
    // inert. Rendering the projection is a pure read.
    let cold = PerformanceBrowserModel()
    var coldCommands: [String] = []
    cold.startListPlayback = { _, entry in coldCommands.append("list:\(entry)") }
    cold.startFilteredShuffle = { _ in coldCommands.append("shuffle") }
    let coldState = HomepageMusicCardState.make(cold)
    expect(coldState.selectedTitle == nil && coldState.eligibleCount == 0
           && !coldState.canPlaySelected && !coldState.canShuffle,
           "the idle homepage card must offer no play or shuffle before a library exists")
    expect(coldState.startRow == "未选择歌曲" && coldState.unavailableReason != nil,
           "the idle card must say no song is selected rather than imply a start row")
    cold.playSelectedFromList()
    cold.startFilteredShufflePlayback()
    expect(coldCommands.isEmpty,
           "the idle card's play/shuffle must be a no-op, never a fallback to another song")

    // 2) Loaded list: the count is the exact eligible snapshot and list play starts the selected
    // row inside that same snapshot.
    let model = loaded()
    var listSnapshots: [[PerformanceQueueEntry]] = []
    var listStarts: [String] = []
    model.startListPlayback = { snapshot, entryID in
        listSnapshots.append(snapshot)
        listStarts.append(entryID)
    }
    let eligible = model.visibleListSnapshot
    expect(!eligible.isEmpty, "the synthetic fixture must yield eligible rows for list play")
    let loadedState = HomepageMusicCardState.make(model)
    expect(loadedState.eligibleCount == eligible.count
           && loadedState.eligibleCount == model.visibleListSnapshot.count,
           "the homepage card must show the exact eligible visibleListSnapshot count")
    expect(loadedState.selectedTitle == nil && !loadedState.canPlaySelected,
           "with nothing selected, list play must stay disabled even though eligible rows exist")
    expect(loadedState.canShuffle,
           "shuffle needs only a non-empty current filter, not a selection")
    guard let selectedTrack = library.manifest.tracks.first(where: {
        $0.kind == .vocalPerformance
            && model.selection($0.id, presentation: .sidePerformance) != nil
    }) else {
        expect(false, "the bundled fixture must resolve a startable vocal track")
        return
    }
    model.selectedID = selectedTrack.id
    let selectedState = HomepageMusicCardState.make(model)
    expect(selectedState.selectedTitle == selectedTrack.title,
           "the card must reuse the shared selected row title, never invent one")
    expect(selectedState.canPlaySelected
           && selectedState.startRow.contains(selectedTrack.title),
           "the selected start row must name the real selected title so the starting row is clear")
    model.playSelectedFromList()
    guard let startedSnapshot = listSnapshots.first else {
        expect(false, "list play must pass one snapshot to the existing owner command")
        return
    }
    expect(listStarts.count == 1
           && startedSnapshot.contains { entry in
               entry.id == listStarts[0]
                   && entry.target.officialSelection?.performanceID.rawValue == selectedTrack.id
           },
           "list play must start exactly the selected row's own snapshot entry")
    expect(startedSnapshot.map(\.id) == model.visibleListSnapshot.map(\.id),
           "list play must pass the exact current eligible snapshot in displayed order")

    // 3) Unavailable/absent selection: the control disables and an explicit play is a no-op, so
    // the selected song can never silently fall back to a different eligible row.
    model.categoryFilter = .classical
    let narrowed = HomepageMusicCardState.make(model)
    expect(!model.visibleRows.contains { $0.id == selectedTrack.id },
           "the vocal selection must be excluded by the narrowed classical filter")
    expect(narrowed.eligibleCount > 0 && !narrowed.canPlaySelected,
           "an excluded selected song must disable list play while eligible rows remain")
    expect(narrowed.unavailableReason != nil && narrowed.startRow.contains("当前不可播放"),
           "the disabled state must state that the selected song cannot play")
    model.playSelectedFromList()
    expect(listSnapshots.count == 1 && model.selectedID == selectedTrack.id,
           "an unavailable selected song must not start any row and must not be reselected away")
    model.categoryFilter = .all

    // 4) A local selection plays exactly its remembered file version through the same list path.
    let localModel = loaded()
    var localCatalog = LocalSongCatalog()
    localCatalog.registerRoot(id: "local.root.review", displayPath: "/synthetic/review-local",
                              bookmark: nil, identity: nil)
    localCatalog.applyScan(rootID: "local.root.review", groups: [
        LocalSongScannedGroup(relativePath: "work", files: [
            LocalSongScannedFile(relativePath: "work/a.mp4", basename: "a.mp4", byteSize: 10),
            LocalSongScannedFile(relativePath: "work/b.mp4", basename: "b.mp4", byteSize: 11),
        ]),
    ])
    localModel.localCatalog = localCatalog
    localModel.selectLocalFile = { trackID, fileID in
        var updated = localModel.localCatalog ?? LocalSongCatalog()
        try? updated.selectFile(trackID: trackID, fileID: fileID)
        localModel.localCatalog = updated
    }
    guard let localTrack = localModel.localTracks.first, localTrack.files.count == 2 else {
        expect(false, "the local fixture must provide one two-file track")
        return
    }
    localModel.selectedID = localTrack.id
    localModel.selectLocalFile(localTrack.id, localTrack.sortedFiles[1].id)
    var localSnapshots: [[PerformanceQueueEntry]] = []
    var localStarts: [String] = []
    localModel.startListPlayback = { snapshot, entryID in
        localSnapshots.append(snapshot)
        localStarts.append(entryID)
    }
    let localState = HomepageMusicCardState.make(localModel)
    expect(localState.canPlaySelected && localState.selectedTitle == localTrack.displayTitle,
           "an available local selection must be playable and titled from the shared row")
    localModel.playSelectedFromList()
    guard let localSnapshot = localSnapshots.first,
          let localEntry = localSnapshot.first(where: {
              $0.target.localSelection?.trackID == localTrack.id
          }) else {
        expect(false, "list play must include the selected local row in the snapshot")
        return
    }
    expect(localEntry.target.localSelection?.fileID == localTrack.sortedFiles[1].id,
           "the homepage list play must keep the exact selected local file version")
    expect(localStarts == [localEntry.id],
           "the homepage list play must start the selected local row's own snapshot entry")

    // 5) Shuffle snapshots the CURRENT filter and leaves the existing queue/order untouched.
    let shuffleModel = loaded()
    shuffleModel.categoryFilter = .classical
    let expectedShuffle = shuffleModel.visibleListSnapshot
    expect(!expectedShuffle.isEmpty && expectedShuffle.count < eligible.count,
           "the classical filter must narrow the shuffle snapshot")
    var shuffles: [[PerformanceQueueEntry]] = []
    shuffleModel.startFilteredShuffle = { shuffles.append($0) }
    expect(HomepageMusicCardState.make(shuffleModel).canShuffle,
           "a non-empty current filter must enable shuffle")
    shuffleModel.startFilteredShufflePlayback()
    expect(shuffles.count == 1 && shuffles[0].map(\.id) == expectedShuffle.map(\.id),
           "shuffle must hand the exact current-filter snapshot to the existing owner command")
    let queued = PerformanceQueueEntry(id: "queued-before-shuffle",
        performanceID: PerformanceID(library.manifest.tracks[0].id),
        presentation: .sidePerformance, mode: .watch)
    _ = shuffleModel.queueState.append(queued)
    shuffleModel.queueState.setOrder(.repeatAll)
    let queuedIDs = shuffleModel.queueState.configuration.entries.map(\.id)
    shuffleModel.search = "不存在的曲名-zzz-review"
    expect(HomepageMusicCardState.make(shuffleModel).eligibleCount == 0
           && !HomepageMusicCardState.make(shuffleModel).canShuffle,
           "an empty filter result must disable shuffle")
    shuffleModel.startFilteredShufflePlayback()
    expect(shuffles.count == 1, "shuffle with an empty current filter must be a no-op")
    expect(shuffleModel.queueState.configuration.entries.map(\.id) == queuedIDs
           && shuffleModel.queueState.configuration.order == .repeatAll,
           "an inert shuffle must preserve the existing queue and order")

    // 6) 选择歌曲 is navigation only: selecting the library page issues no music command.
    let navigation = CandidateNavigationModel()
    let navModel = loaded()
    var navCommands: [String] = []
    navModel.startListPlayback = { _, entry in navCommands.append("list:\(entry)") }
    navModel.startFilteredShuffle = { _ in navCommands.append("shuffle") }
    navModel.play = { id, _, _ in navCommands.append("play:\(id)") }
    navModel.pause = { navCommands.append("pause") }
    navModel.stop = { navCommands.append("stop") }
    _ = HomepageMusicCardState.make(navModel)
    let showLibrary: () -> Void = { navigation.select(.library) }
    showLibrary()
    expect(navigation.page == .library && navCommands.isEmpty,
           "选择歌曲 must only open the library page and never start or pause music")
    navigation.select(.daily)
    expect(navigation.page == .daily && navCommands.isEmpty,
           "returning from the library must also be command-free")

    // 7) Browsing/filtering the homepage preserves the running queue and its current song.
    let browseModel = loaded()
    let runningEntry = PerformanceQueueEntry(id: "browse-keep-1",
        performanceID: PerformanceID(library.manifest.tracks[0].id),
        presentation: .sidePerformance, mode: .watch)
    _ = browseModel.queueState.append(runningEntry)
    _ = browseModel.queueState.begin(entryID: runningEntry.id) { _ in 0 }
    let runningIDs = browseModel.queueState.configuration.entries.map(\.id)
    var browseCommands: [String] = []
    browseModel.startListPlayback = { _, entry in browseCommands.append("list:\(entry)") }
    browseModel.startFilteredShuffle = { _ in browseCommands.append("shuffle") }
    browseModel.stop = { browseCommands.append("stop") }
    browseModel.nextInQueue = { browseCommands.append("next") }
    _ = HomepageMusicCardState.make(browseModel)
    browseModel.categoryFilter = .vocal
    browseModel.search = "的"
    _ = HomepageMusicCardState.make(browseModel)
    expect(browseModel.queueState.isRunning
           && browseModel.queueState.configuration.entries.map(\.id) == runningIDs
           && browseModel.queueState.activeEntry?.id == runningEntry.id,
           "homepage filter/browse changes must preserve the running queue and its current song")
    expect(browseCommands.isEmpty,
           "rendering and browsing the homepage must never issue a music command")

    // 8) The card and the shared strip read the SAME current title from the shared model.
    let titleModel = loaded()
    guard let titleTrack = library.manifest.tracks.first(where: {
        titleModel.selection($0.id, presentation: .sidePerformance) != nil
    }) else {
        expect(false, "the bundled fixture must resolve a track for the shared-title check")
        return
    }
    titleModel.selectedID = titleTrack.id
    let session = PerformanceSession(variant: titleModel.selection(titleTrack.id,
                                                                   presentation: .sidePerformance)!,
                                     mode: .listen)
    titleModel.sessionState.start(session)
    expect(titleModel.sessionTitle == titleTrack.title
           && HomepageMusicCardState.make(titleModel).selectedTitle == titleTrack.title,
           "the homepage card and the shared strip must reuse the same current title")
}

// MARK: - Candidate menu-bar quick controls

private func runStatusQuickMenuRegression(expect: (Bool, String) -> Void) {
    let idle = StatusQuickMenuState.make(wallpaperPaused: false, musicSessionPresent: false,
                                         musicSessionPaused: false, queueRunning: false,
                                         watchSessionActive: false)
    expect(idle.title(for: .toggleWallpaperPause) == "暂停全部",
           "an unpaused wallpaper must offer 暂停全部")
    expect(idle.title(for: .toggleMusicPause) == "暂停音乐",
           "an active music session must offer 暂停音乐")
    expect(!idle.isEnabled(.toggleMusicPause),
           "music pause must be unavailable with no session and no queue")
    expect(!idle.isEnabled(.enterFullScreen),
           "进入全屏 must be disabled with no watch session")
    expect(idle.title(for: .enterFullScreen) == "歌曲演奏视频",
           "the explicit presentation item keeps its reviewed Chinese title")
    expect(idle.isEnabled(.openWindow) && idle.isEnabled(.toggleWallpaperPause) && idle.isEnabled(.quit),
           "open, wallpaper pause and quit must stay available")
    expect(StatusQuickAction.allCases.count == 5
           && StatusQuickAction.allCases.map(\.title)
           == ["打开 bsideyou", "歌曲演奏视频", "暂停全部", "暂停音乐", "退出 bsideyou"],
           "the candidate quick menu must expose exactly the five approved actions in order")

    let active = StatusQuickMenuState.make(wallpaperPaused: true, musicSessionPresent: true,
                                           musicSessionPaused: true, queueRunning: false,
                                           watchSessionActive: true)
    expect(active.title(for: .toggleWallpaperPause) == "恢复全部",
           "a paused wallpaper must offer 恢复全部")
    expect(active.title(for: .toggleMusicPause) == "恢复全部",
           "a paused music session must offer 恢复音乐")
    expect(active.isEnabled(.toggleMusicPause),
           "music pause must be available while a session exists")
    expect(active.isEnabled(.enterFullScreen),
           "进入全屏 must be available while an active watch session exists")
    expect(active.wallpaperPaused && active.musicPaused,
           "wallpaper and music pause must be independent fields, never one shared flag")

    let listening = StatusQuickMenuState.make(wallpaperPaused: false, musicSessionPresent: true,
                                              musicSessionPaused: false, queueRunning: false,
                                              watchSessionActive: false)
    expect(!listening.isEnabled(.enterFullScreen),
           "a listen-only session must never enable 进入全屏")

    let queued = StatusQuickMenuState.make(wallpaperPaused: false, musicSessionPresent: false,
                                           musicSessionPaused: false, queueRunning: true,
                                           watchSessionActive: false)
    expect(queued.isEnabled(.toggleMusicPause),
           "a running queue must keep music pause available without an active session")
    expect(!queued.musicPaused, "a running queue alone must not claim music is paused")
    expect(!queued.isEnabled(.enterFullScreen),
           "a running queue without a watch session must not enable 进入全屏")
}

// MARK: - Watch desktop auto-hide ownership (pure seam)

/// New playback intent normalizes legacy modes without rewriting saved queue/history identity.
/// Picture reports are transient and can only address the currently installed session.
private func runWatchDesktopAutoHideRegression(expect: (Bool, String) -> Void) {
    let target = PerformancePlaybackTarget.localFile(.init(trackID: "track", fileID: "file",
                                                          catalogRevision: .init("revision")))
    let old = PerformanceSession(id: "legacy-session", target: target, mode: .listen,
                                 paused: true, continuesQueue: true)
    let binding = PerformanceFileBinding(relativePath: "song.mp4", byteSize: 7, sha256: "digest")
    let source = PerformanceStartRequest(session: old, mediaRoot: "/synthetic",
        accessBookmark: Data([1, 2]), fileBinding: binding, automaticallyEnterFullScreen: true)
    let normalized = UnifiedMusicPlayback.request(source)
    expect(normalized.session.mode == .watch && normalized.automaticallyEnterFullScreen == false,
           "a legacy Listen request executes unified music without automatic fullscreen")
    expect(normalized.session.id == old.id && normalized.session.target == old.target
           && normalized.session.paused && normalized.session.continuesQueue,
           "normalization preserves exact session, target, pause and queue ownership")
    expect(normalized.mediaRoot == source.mediaRoot && normalized.accessBookmark == source.accessBookmark
           && normalized.fileBinding == binding && source.session.mode == .listen,
           "normalization preserves grants and file identity without mutating legacy input")
    do {
        let entry = PerformanceQueueEntry(trackID: "track", fileID: "file", mode: .listen)
        let record = SongPlaybackRecord(target: target, fileBinding: binding, mode: .listen,
                                       title: "legacy", lastPlayed: Date(timeIntervalSince1970: 1))
        let decodedEntry = try JSONDecoder().decode(PerformanceQueueEntry.self, from: JSONEncoder().encode(entry))
        let decodedRecord = try JSONDecoder().decode(SongPlaybackRecord.self, from: JSONEncoder().encode(record))
        expect(decodedEntry == entry && decodedEntry.mode == .listen,
               "legacy queue mode and file identity remain readable without migration")
        expect(decodedRecord == record && decodedRecord.mode == .listen,
               "legacy song history remains unchanged and decodable")
    } catch { expect(false, "legacy compatibility fixture failed: \(error)") }

    let model = PerformanceBrowserModel()
    model.serviceReady = true
    model.sessionState.start(normalized.session)
    model.report = PerformanceReport(sessionID: old.id, state: .loading)
    var requests: [Bool] = []
    model.setPictureExpanded = { requests.append($0) }
    model.togglePicture()
    expect(requests.isEmpty && !model.canTogglePicture, "unready playback has no actionable picture")
    model.report = PerformanceReport(sessionID: old.id, state: .paused)
    model.receivePicturePresentation(.init(sessionID: "obsolete", state: .expanded))
    expect(model.picturePresentation == nil, "a stale picture report cannot enable the current song")
    model.receivePicturePresentation(.init(sessionID: old.id, state: .collapsed))
    model.togglePicture()
    expect(requests == [true] && model.sessionState.session == normalized.session,
           "expansion forwards presentation intent without changing or replaying the session")
    model.receivePicturePresentation(.init(sessionID: old.id, state: .expanding))
    model.togglePicture()
    expect(requests == [true] && !model.canTogglePicture, "a native transition disables repeated picture commands")
    model.receivePicturePresentation(.init(sessionID: old.id, state: .expanded))
    model.togglePicture()
    expect(requests == [true, false] && model.sessionState.session == normalized.session,
           "collapse preserves the same session and pause intent")
    model.receivePicturePresentation(.init(sessionID: old.id, state: .collapsed))
    expect(!model.pictureIsExpanded && model.canTogglePicture, "native Esc/close updates the action to expand")
    model.sessionState.start(PerformanceSession(id: "next", target: target))
    expect(model.picturePresentation == nil, "a replacement clears the predecessor picture status")
    model.receivePicturePresentation(.init(sessionID: old.id, state: .expanded))
    expect(model.picturePresentation == nil, "a delayed predecessor report cannot change a successor")
    model.receivePicturePresentation(.init(sessionID: "next", state: .collapsed))
    model.serviceReady = false
    expect(model.picturePresentation == nil && !model.canTogglePicture, "Agent loss clears transient picture state")
}

private func runCompanionMusicControlRegression(expect: (Bool, String) -> Void) {
    let control = ControlCenterModel(), performance = PerformanceBrowserModel()
    control.resourceConfigured = true
    control.apply(desired: DesiredState(scene: .a, outfit: .r2, timeMode: .fixed(.evening),
                  musicVolume: 0.36, ambientVolume: 0.5, dailySoundtrack: .track(ContentID("ambient://1"))), stage: .ready, stageDetail: "",
                  snapshot: RuntimeSnapshot(state: .playing, ambientVolume: 0.4, dailyAmbientTrackCount: 3, dailyAmbientTracks: [AmbientTrack(id: ContentID("ambient://1"), index: 1, label: "陪伴音乐")]),
                  supervision: .running)
    var pushed: [DesiredState] = []
    control.onDesiredChange = { pushed.append($0) }
    let admission = ControlCenterModel()
    var pinned: [DesiredState] = []
    admission.onDesiredChange = { pinned.append($0) }
    let legacy = DesiredState(dailySoundtrack: .legacyDefault)
    admission.apply(desired: legacy, stage: .ready, stageDetail: "", snapshot: nil, supervision: .running)
    expect(pinned.isEmpty, "unknown catalog cannot migrate a legacy soundtrack")
    let generic = AmbientTrack(id: ContentID("generic"), index: 1, label: "ambient_loop_1.mp3")
    let titled = AmbientTrack(id: ContentID("titled"), index: 2, label: "Evening Piano")
    expect(generic.soundtrackTitle == "陪伴音轨 1" && titled.soundtrackTitle == titled.label,
           "generic ambient filenames receive stable natural labels while real titles remain unchanged")
    let tracks = [AmbientTrack(id: ContentID("ambient://2"), index: 2, label: "Second"),
                  AmbientTrack(id: ContentID("ambient://1"), index: 1, label: "First")]
    let catalogSnapshot = RuntimeSnapshot(state: .playing, dailyAmbientTracks: tracks)
    admission.apply(desired: legacy, stage: .ready, stageDetail: "", snapshot: catalogSnapshot, supervision: .running)
    expect(pinned.isEmpty && admission.dailyAmbientTracks.isEmpty, "unconfigured resource cannot expose or pin stale snapshot tracks")
    admission.resourceConfigured = true
    admission.apply(desired: legacy, stage: .ready, stageDetail: "", snapshot: catalogSnapshot, supervision: .running)
    expect(pinned.count == 1 && admission.desired.dailySoundtrack == .track(ContentID("ambient://1")),
           "first valid catalog pins the deterministic legacy choice exactly once")
    admission.apply(desired: admission.desired, stage: .ready, stageDetail: "", snapshot: catalogSnapshot, supervision: .running)
    expect(pinned.count == 1, "later snapshots cannot repin explicit intent")
    var missing = legacy; missing.dailySoundtrack = .track(ContentID("missing"))
    admission.apply(desired: missing, stage: .ready, stageDetail: "", snapshot: catalogSnapshot, supervision: .running)
    let unavailable = NotchMusicState.make(performance, control: admission)
    expect(!unavailable.canPause && unavailable.title == "陪伴音乐不可用" && pinned.count == 1,
           "a missing explicit track remains unavailable without fallback or an ineffective transport")
    admission.apply(desired: legacy, stage: .ready, stageDetail: "",
        snapshot: RuntimeSnapshot(state: .playing, dailyAmbientTracks: []), supervision: .running)
    expect(admission.desired.dailySoundtrack == .silent, "known empty catalog pins silence")
    let silent = NotchMusicState.make(performance, control: admission)
    let silentMenu = StatusQuickMenuState.make(wallpaperPaused: false, musicSessionPresent: false,
        musicSessionPaused: false, queueRunning: false, watchSessionActive: false, companion: silent)
    expect(silent.title == "无音乐" && silent.statusLine.isEmpty && !silent.canPause && !silentMenu.isEnabled(.toggleMusicPause)
           && silentMenu.title(for: .toggleMusicPause) == "未选择音乐", "silent main/notch/menu cannot imply music is playing")
    let beforeNoop = admission.desired
    admission.toggleCurrentMusicPause(performance: performance)
    expect(admission.desired == beforeNoop, "silence pause is a no-op")
    admission.apply(desired: missing, stage: .ready, stageDetail: "", snapshot: catalogSnapshot, supervision: .running)
    var selectionEvents: [String] = []
    admission.onDesiredSettled = { selectionEvents.append("send") }
    performance.stop = { selectionEvents.append("stop") }
    let beforeSelection = admission.desired
    admission.selectDailySoundtrack(.track(ContentID("ambient://2")), performance: performance)
    expect(selectionEvents == ["send", "stop"] && admission.desired.dailySoundtrack == .track(ContentID("ambient://2")),
           "explicit ambient selection flushes intent before the existing song/queue stop command")
    expect(admission.desired.scene == beforeSelection.scene && admission.desired.timeMode == beforeSelection.timeMode
           && admission.desired.musicVolume == beforeSelection.musicVolume && admission.desired.ambientVolume == beforeSelection.ambientVolume,
           "soundtrack choice preserves video and both saved gains")
    admission.selectSongSoundtrack()
    expect(admission.desired.dailySoundtrack == .silent, "starting an explicit song leaves no automatic ambient successor")
    admission.selectDailySoundtrack(.silent, performance: performance)
    expect(selectionEvents.suffix(2) == ["send", "stop"], "explicit silence also stops an active or pending song queue")

    let original = control.desired
    let idle = NotchMusicState.make(performance, control: control)
    expect(idle.title == "陪伴音乐" && idle.canPause && idle.pauseTitle == "暂停陪伴音乐",
           "main and notch offer the actual companion soundtrack without a selected song")
    control.toggleCurrentMusicPause(performance: performance)
    var expected = original; expected.dailyMusicPaused = true
    expect(control.desired == expected && pushed == [expected],
           "primary pause changes only persisted soundtrack intent, not picture/volume/profile/selection")
    let paused = NotchMusicState.make(performance, control: control)
    expect(paused.status == "已暂停" && paused.pauseTitle == "恢复陪伴音乐" && paused.pauseSymbol == "play.fill",
           "both surfaces immediately offer true soundtrack resume")
    let menu = StatusQuickMenuState.make(wallpaperPaused: false, musicSessionPresent: false,
        musicSessionPaused: false, queueRunning: false, watchSessionActive: false, companion: paused)
    expect(menu.isEnabled(.toggleMusicPause) && menu.title(for: .toggleMusicPause) == paused.pauseTitle,
           "quick menu uses the same soundtrack state/action")
    control.toggleCurrentMusicPause(performance: performance)
    expect(control.desired == original, "resume preserves all original choices")
    let playingSnapshot = control.snapshot
    control.snapshot?.state = .paused
    control.snapshot?.visual = .paused
    control.snapshot?.reasons = ["fullscreen-app", "desktop-occluded"]
    let fullscreenMusic = NotchMusicState.make(performance, control: control)
    expect(control.desired.muteAudioOnFullscreen && control.dailyMusicRestriction == nil
           && control.dailyMusicPauseAvailable && control.dailyMusicStatus.isEmpty
           && fullscreenMusic.canPause && fullscreenMusic.pauseTitle == "暂停陪伴音乐",
           "a fullscreen-paused picture leaves companion music controls usable despite the legacy mute preference")
    control.toggleCurrentMusicPause(performance: performance)
    let fullscreenPaused = NotchMusicState.make(performance, control: control)
    expect(control.desired == expected && fullscreenPaused.canPause && fullscreenPaused.status == "已暂停"
           && fullscreenPaused.pauseTitle == "恢复陪伴音乐",
           "main and notch pause only the soundtrack while the fullscreen picture stays paused")
    control.toggleCurrentMusicPause(performance: performance)
    expect(control.desired == original && control.dailyMusicStatus.isEmpty && control.snapshot?.visual == .paused,
           "soundtrack resume in fullscreen preserves picture pause and all original choices")
    control.snapshot = playingSnapshot
    control.setCurrentMusicVolume(0.25, performance: performance)
    expect(control.desired.ambientVolume == 0.25 && control.desired.musicVolume == original.musicVolume,
           "companion volume targets existing ambient preference only")
    control.desired = original
    control.desired.paused = true; control.desired.dailyMusicPaused = true
    expect(NotchMusicState.make(performance, control: control).pauseTitle == "恢复全部",
           "global recovery never masquerades as music-only resume")
    control.toggleCurrentMusicPause(performance: performance)
    expect(control.desired == original, "explicit resume-all clears only user-global and soundtrack pause")
    control.desired.profile = .movie
    let restricted = control.desired
    control.toggleCurrentMusicPause(performance: performance)
    expect(control.desired == restricted && !NotchMusicState.make(performance, control: control).canPause,
           "music control cannot override profile restrictions")
    control.desired = original
    control.snapshot?.reasons = ["screen-locked"]
    control.toggleCurrentMusicPause(performance: performance)
    expect(control.desired == original && !control.dailyMusicPauseAvailable, "system restriction is not cleared")
    control.snapshot?.reasons = []
    let song = PerformanceSession(target: .localFile(.init(trackID: "song", fileID: "file", catalogRevision: .init("r"))))
    performance.sessionState.start(song)
    var songPauses = 0
    performance.pause = { songPauses += 1 }
    control.toggleCurrentMusicPause(performance: performance)
    expect(songPauses == 1 && control.desired == original,
           "an explicit session keeps its existing pause command, without changing daily intent")
    control.setCurrentMusicVolume(0.21, performance: performance)
    expect(control.desired.musicVolume == 0.21 && control.desired.ambientVolume == original.ambientVolume,
           "song volume still targets its existing preference")
}
