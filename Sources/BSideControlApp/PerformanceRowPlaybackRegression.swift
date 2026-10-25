// Library row double-click playback regression over the real browser model and bundled
// metadata only: no media access, scan, player process, gesture synthesis or UI window.
//
// ADR-024 contract pinned here: double-click snapshots the CURRENT visible eligible rows with
// each row's exact selected version, starts the clicked row inside that snapshot, and continues
// under the existing queue mode. An unavailable or unknown row selects itself with a reason and
// never substitutes another song. Single click stays selection-only.
import Foundation
import BSideCore
import BSidePlatform

func runPerformanceRowPlaybackRegression(expect: (Bool, String) -> Void) {
    let browser = PerformanceBrowserModel()
    // The owner side of list playback, reduced to its observable effect: the saved queue is
    // replaced by the exact snapshot and the started entry is recorded.
    var batches: [[PerformanceQueueEntry]] = []
    var started: [String] = []
    var singlePlays: [String] = []
    browser.startListPlayback = { snapshot, entryID in
        batches.append(snapshot)
        started.append(entryID)
        var state = PerformanceQueueState(configuration: PerformanceQueueConfiguration(
            entries: snapshot, order: browser.queueState.configuration.order))
        _ = state.begin(entryID: entryID, chooseIndex: { _ in 0 })
        browser.queueState = state
    }
    browser.play = { id, _, _ in singlePlays.append(id) }

    do {
        let library = try PerformanceLibrary.bundled()
        browser.library = library
        browser.root = "/synthetic/bside-row-playback-regression-only"
        browser.serviceReady = true
        browser.scanned = true
        browser.desired = DesiredState(timeMode: .fixed(.noon))
        browser.presentation = .sidePerformance
        browser.playbackMode = .watch
        browser.pause = {}
        browser.nextInQueue = {}
        browser.stop = {}

        // One reviewed track that resolves both daylight cameras, plus a second resolvable
        // track used as the previously selected row.
        guard let clicked = library.manifest.tracks.first(where: { track in
            track.variants.contains { $0.lighting == .daylight && $0.presentation == .sidePerformance }
                && track.variants.contains { $0.lighting == .daylight && $0.presentation == .portraitPerformance }
        }), let previous = library.manifest.tracks.first(where: {
            $0.id != clicked.id && browser.selection($0.id, presentation: .sidePerformance) != nil
        }) else {
            expect(false, "row-playback regression needs a both-camera track and a second resolvable track")
            return
        }
        browser.favorites = [PerformanceID(clicked.id)]
        browser.onlyFavorites = true
        expect(browser.rows.map(\.id) == [clicked.id], "favorites filter narrows the real library")
        expect(browser.visibleListSnapshot.count == 1, "favorite-only shuffle captures one exact song")
        browser.styleFilter = PerformanceStyleFilter.group(clicked)
        expect(browser.visibleListSnapshot.count == 1, "style and favorites combine without losing the selected group")
        browser.styleFilter = PerformanceStyleFilter.group(clicked) == .classical ? .game : .classical
        expect(browser.visibleListSnapshot.isEmpty, "a different style does not leak favorites outside its group")
        expect(browser.hasActiveLibraryFilters, "favorite/style filters count as active")
        browser.clearLibraryFilters()
        expect(!browser.onlyFavorites && browser.styleFilter == .all && browser.favorites.contains(PerformanceID(clicked.id)),
               "clear filters keeps durable favorites")
        if let variant = browser.selection(clicked.id) {
            browser.sessionState.start(PerformanceSession(variant: variant, mode: .watch))
            let notch = NotchMusicState.make(browser)
            expect(notch.canFavorite && notch.isFavorite, "notch projects current song favorite state")
            browser.sessionState = PerformanceSessionState()
        }
        do {
            var prefs = AppPreferences()
            prefs.favoritePerformanceIDs = browser.favorites
            prefs.favoriteLocalTrackIDs = ["local-song"]
            let restored = try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(prefs))
            expect(restored.favoritePerformanceIDs == browser.favorites && restored.favoriteLocalTrackIDs == ["local-song"],
                   "favorites round-trip without altering typed queue preferences")
        } catch { expect(false, "favorite preference round-trip: \(error)") }
        expect(PerformanceBrowserModel().automaticCamera, "a fresh browser defaults to front-first automatic camera")
        browser.automaticCamera = true
        expect(browser.selection(clicked.id)?.presentation == .portraitPerformance,
               "automatic camera resolves a supported front view")
        let automaticSnapshot = browser.visibleListSnapshot
        expect(automaticSnapshot.first { $0.performanceID?.rawValue == clicked.id }?.presentation == .portraitPerformance,
               "automatic list and shuffle snapshots capture the front view")
        if let solo = library.manifest.tracks.first(where: { $0.kind == .pianoSolo }) {
            expect(browser.selection(solo.id)?.presentation == .sidePerformance,
                   "a side-only song remains playable under automatic camera")
        }
        if let front = browser.selection(clicked.id) {
            browser.unavailable[front.variantID.rawValue] = "synthetic missing front view"
            expect(browser.selection(clicked.id)?.presentation == .sidePerformance,
                   "automatic camera uses side when the scan reports a missing front view")
            browser.presentation = .portraitPerformance
            expect(browser.automaticCamera == false,
                   "an explicit camera disables automatic selection")
            expect(browser.playbackProblem(id: clicked.id, presentation: .portraitPerformance) != nil,
                   "an explicit missing front view reports failure rather than substituting side")
            browser.unavailable = [:]
        }
        browser.presentation = .sidePerformance
        let visible = browser.visibleRows

        // A plain selection change (single click) must stay select-only.
        browser.selectedID = previous.id
        expect(browser.selectedID == previous.id && started.isEmpty && batches.isEmpty,
               "selecting a row without the double-click action must never dispatch playback")

        // Double-clicking a different row selects the CLICKED row and starts it inside the
        // snapshot of every currently visible eligible row, in displayed order.
        browser.playListRow(clicked.id)
        expect(browser.selectedID == clicked.id && started.count == 1
               && batches.count == 1,
               "double-click must select the clicked row and start one list snapshot")
        let snapshot = batches[0]
        expect(snapshot.map(\.id) == browser.visibleListSnapshot.map(\.id),
               "the snapshot must be exactly the currently visible eligible rows in displayed order")
        expect(snapshot.count == visible.count,
               "every eligible visible row must be captured, never a List page")
        guard let clickedEntry = snapshot.first(where: { entry in
            entry.target.officialSelection?.performanceID.rawValue == clicked.id
        }) else {
            expect(false, "the clicked row must appear inside its own snapshot")
            return
        }
        expect(started[0] == clickedEntry.id,
               "the started entry must be the clicked row's own snapshot entry, never another row")
        expect(clickedEntry.mode == .watch
               && clickedEntry.target.officialSelection?.presentation == .sidePerformance,
               "the snapshot must keep the current mode and camera")
        expect(browser.queueState.isRunning && browser.queueState.activeEntry?.id == clickedEntry.id,
               "the owner replaces the queue with the snapshot and starts the clicked entry")

        // The queue mode is whatever the user already had; the snapshot replacement does not
        // silently switch it.
        browser.queueState.setOrder(.repeatAll)
        browser.presentation = .portraitPerformance
        browser.playbackMode = .listen
        browser.selectedID = previous.id
        browser.playListRow(clicked.id)
        expect(browser.selectedID == clicked.id && started.count == 2 && batches.count == 2,
               "a second double-click starts another list snapshot")
        expect(batches[1].allSatisfy { $0.mode == .listen
                   && $0.target.officialSelection?.presentation == .portraitPerformance },
               "the second snapshot must forward the current listen mode and portrait camera")
        expect(browser.queueState.configuration.order == .repeatAll,
               "list playback must keep the user's existing queue mode")

        // A browsing change after the start must not mutate the running queue.
        let runningBefore = browser.queueState.configuration.entries
        browser.categoryFilter = .vocal
        browser.search = "的"
        expect(browser.queueState.configuration.entries == runningBefore,
               "filter and search changes after the start must not mutate the snapshot queue")
        browser.clearLibraryFilters()

        // An unavailable clicked row still moves the selection (same as a single click) but never
        // dispatches and never substitutes another song.
        guard let variant = browser.selection(clicked.id, presentation: .portraitPerformance) else {
            expect(false, "the both-camera fixture must resolve its portrait source")
            return
        }
        browser.unavailable[variant.variantID.rawValue] = "synthetic missing source"
        browser.selectedID = previous.id
        let batchesBefore = batches.count
        browser.playListRow(clicked.id)
        expect(browser.selectedID == clicked.id && batches.count == batchesBefore,
               "an unavailable double-clicked row must not replace the queue or start anything")
        expect(browser.selectionProblem != nil,
               "the unavailable row must keep an explicit reason channel")
        browser.unavailable = [:]

        // An unknown row id is blocked the same way.
        let unknownBatches = batches.count
        browser.playListRow("no-such-library-row")
        expect(batches.count == unknownBatches
               && browser.selectedID == "no-such-library-row"
               && browser.selectionProblem != nil,
               "an unknown double-clicked row must not dispatch and must keep a visible reason")

        // 只播放这首 remains the explicit single-song convenience, through the retained exact path.
        browser.presentation = .sidePerformance
        browser.playbackMode = .watch
        browser.selectedID = previous.id
        browser.playSelectedEntryOnly()
        expect(singlePlays == [previous.id] && batches.count == unknownBatches,
               "只播放这首 must start exactly the selected song once and add no list snapshot")
        expect(browser.selectedID == previous.id,
               "只播放这首 must not move the selection to another row")

        // 下一首播放 inserts the exact selected entry after the running one, without interrupting.
        browser.presentation = .portraitPerformance
        browser.queueState.bind(sessionID: "row-playback-active")
        let activeBefore = browser.queueState.activeEntry
        let activeSessionBefore = browser.queueState.activeSessionID
        browser.selectedID = clicked.id
        browser.playNext = { entry in _ = browser.queueState.insertAfterActive(entry) }
        browser.playSelectionNext()
        expect(browser.queueState.activeEntry == activeBefore,
               "下一首播放 must leave the current entry untouched")
        expect(browser.queueState.activeSessionID == activeSessionBefore,
               "下一首播放 must not revoke the current session binding")
        guard let activeID = activeBefore?.id,
              let activeIndex = browser.queueState.configuration.entries.firstIndex(where: { $0.id == activeID }) else {
            expect(false, "the running queue must still contain its active entry")
            return
        }
        expect(browser.queueState.configuration.entries.count > activeIndex + 1
               && browser.queueState.configuration.entries[activeIndex + 1].target
                    .officialSelection?.performanceID.rawValue == clicked.id,
               "下一首播放 must insert the selected song immediately after the active one")
    } catch {
        expect(false, "row-playback browser metadata regression failed: \(error)")
    }
}
