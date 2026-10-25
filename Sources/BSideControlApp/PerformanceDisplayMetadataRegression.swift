// Curated display-context regression: complete coverage of the bundled track IDs, honest
// unconfirmed handling, and search/queue use of the shared display helper. Metadata only —
// no directory scan, no media access, no IPC.
import Foundation
import BSideCore
import BSidePlatform

func runPerformanceDisplayMetadataRegression(expect: (Bool, String) -> Void) {
    do {
        let library = try PerformanceLibrary.bundled()
        let tracks = library.manifest.tracks
        let ids = Set(tracks.map(\.id))
        let curatedIDs = Set(PerformanceDisplayTable.contexts.keys)

        expect(tracks.count == 129, "the bundled library must keep exposing the 129 reviewed tracks")
        expect(curatedIDs == ids,
               "curated display metadata must cover exactly the bundled track IDs (missing: "
               + ids.subtracting(curatedIDs).sorted().joined(separator: ",")
               + "; extra: " + curatedIDs.subtracting(ids).sorted().joined(separator: ",") + ")")

        // Guard against false franchise matches from generic search results.
        let reviewedSources = [
            "olivia.performance.vocal.da-capo": "崩坏3",
            "olivia.performance.vocal.star-odyssey": "原神",
            "olivia.performance.vocal.the-road-not-taken": "原神",
            "olivia.performance.solo.wildfire": "崩坏：星穹铁道",
            "olivia.performance.solo.wedding-of-love": "保罗·塞内维尔",
            "olivia.performance.solo.footprints": "来源未确认",
            "olivia.performance.solo.where-did-you-go": "来源未确认"
        ]
        for (id, source) in reviewedSources {
            expect(PerformanceDisplayTable.contexts[id]?.source == source,
                   "reviewed attribution must remain correct: \(id)")
        }

        var noContext: [String] = []
        var noEvidence: [String] = []
        var badEvidence: [String] = []
        var vagueUnconfirmed: [String] = []
        for track in tracks {
            guard let context = PerformanceDisplay.context(for: track) else { continue }
            if PerformanceDisplay.rowContext(for: track)?.isEmpty != false { noContext.append(track.id) }
            if context.evidence.isEmpty { noEvidence.append(track.id) }
            if context.evidence.contains(where: { !$0.url.hasPrefix("http") || $0.claim.isEmpty }) {
                badEvidence.append(track.id)
            }
            // An unconfirmed entry must state the concrete uncertainty, not just the label.
            if context.confidence == .unconfirmed, context.detail?.isEmpty != false {
                vagueUnconfirmed.append(track.id)
            }
        }
        expect(noContext.isEmpty, "every curated track must show a source/composer row label: \(noContext)")
        expect(noEvidence.isEmpty, "every curated entry must cite a public source: \(noEvidence)")
        expect(badEvidence.isEmpty, "every evidence item must be a public URL plus a claim: \(badEvidence)")
        expect(vagueUnconfirmed.isEmpty,
               "an unconfirmed entry must explain the uncertainty in detail: \(vagueUnconfirmed)")

        for (id, context) in PerformanceDisplayTable.contexts where context.confidence == .unconfirmed {
            expect(context.source == PerformanceDisplay.unconfirmedSource,
                   "an unconfirmed entry must use the explicit label, not a guessed origin: \(id)")
        }

        // Community game wikis are fan references; the table must never present them as
        // official/authoritative publications.
        for (id, context) in PerformanceDisplayTable.contexts {
            for evidence in context.evidence {
                let claim = evidence.claim
                if claim.localizedCaseInsensitiveContains("Fandom") {
                    expect(claim.contains("社区维护，非官方") || claim.localizedCaseInsensitiveContains("community"),
                           "a Fandom-sourced claim must be labelled a community reference, not official: \(id)")
                }
                expect(!claim.localizedCaseInsensitiveContains("official Fandom"),
                       "a community Fandom wiki must never be called official: \(id)")
            }
        }

        let browser = PerformanceBrowserModel()
        browser.library = library

        // The new Chinese source/composer labels must be searchable together with the originals.
        for label in ["崩坏3", "原神", "肖邦", "德彪西", "来源未确认"] {
            guard let track = tracks.first(where: { PerformanceDisplay.context(for: $0)?.source == label })
            else {
                expect(false, "expected at least one track carrying the curated label \(label)")
                continue
            }
            browser.search = label
            expect(browser.rows.contains { $0.id == track.id },
                   "search '\(label)' must return the track whose curated label it is")
            browser.search = track.title
            expect(browser.rows.contains { $0.id == track.id },
                   "search must still match the original title of \(track.id)")
        }

        // A curated album context is searchable too (Da Capo -> 崩坏3 毕业旅行主题曲).
        if let daCapo = tracks.first(where: { $0.id == "olivia.performance.vocal.da-capo" }),
           let album = PerformanceDisplay.context(for: daCapo)?.album {
            browser.search = album
            expect(browser.rows.contains { $0.id == daCapo.id },
                   "search must match the curated album context of Da Capo")
        } else {
            expect(false, "Da Capo must carry its reviewed album context")
        }
        browser.search = ""

        // Catalogue spellings carry accents; a plain-keyboard query must still reach them.
        if let etude = tracks.first(where: { $0.id.hasSuffix("chopin-etude-op10-no3") }) {
            browser.search = "Etude Op.10 No.3"
            expect(browser.rows.contains { $0.id == etude.id },
                   "an unaccented search must reach the accented catalogue spelling")
            browser.search = "  "
            expect(browser.rows.count == tracks.count, "a whitespace-only search must not filter")
        } else {
            expect(false, "the Chopin Étude track must exist in the bundled library")
        }
        browser.search = ""

        // The Scriabin track keeps its local title: a conflicting public opus is stated as an
        // uncertainty, never silently corrected.
        if let scriabin = tracks.first(where: { $0.id.hasSuffix("scriabin-etude-in-c-sharp-minor-op19-no2") }) {
            expect(scriabin.title.contains("Op.19"), "the Scriabin track keeps its original manifest title")
            let detail = PerformanceDisplay.context(for: scriabin)?.detail ?? ""
            expect(detail.contains("不一致") || detail.contains("存疑"),
                   "the Scriabin Op.19 conflict must be stated as an uncertainty in detail")
        } else {
            expect(false, "the Scriabin track must exist in the bundled library")
        }

        // Detail-pane dedup: the library row already shows the manifest title and the shared
        // source/composer label, so the detail keeps the verified kind only and never repeats
        // the original title (subtitle), the reviewed work or the fuller context line.
        var duplicatedDetail: Set<String> = []
        for track in tracks {
            let lines = PerformanceDisplay.detailMetadataLines(for: track)
            let joined = lines.joined(separator: " · ")
            let context = PerformanceDisplay.context(for: track)
            let row = PerformanceDisplay.rowContext(for: track) ?? ""
            if lines != [PerformanceDisplay.kindLabel(for: track)] { duplicatedDetail.insert(track.id) }
            if !track.subtitle.isEmpty, joined.contains(track.subtitle) { duplicatedDetail.insert(track.id) }
            if !row.isEmpty, joined.contains(row) { duplicatedDetail.insert(track.id) }
            if let work = context?.work, !work.isEmpty, joined.contains(work) { duplicatedDetail.insert(track.id) }
            if let detail = context?.detail, !detail.isEmpty, joined.contains(detail) {
                duplicatedDetail.insert(track.id)
            }
        }
        expect(duplicatedDetail.isEmpty,
               "the detail pane must not repeat the row's title/work/context: \(duplicatedDetail.sorted())")

        // Removing the original title/work/context from the detail must not remove them from
        // search: the English subtitle stays a first-class query surface.
        var unsearchableTitles: [String] = []
        var unsearchableContext: [String] = []
        for track in tracks {
            if !track.subtitle.isEmpty, !PerformanceDisplay.matches(track, search: track.subtitle) {
                unsearchableTitles.append(track.id)
            }
            if let detail = PerformanceDisplay.context(for: track)?.detail, !detail.isEmpty,
               !PerformanceDisplay.matches(track, search: detail) {
                unsearchableContext.append(track.id)
            }
        }
        expect(unsearchableTitles.isEmpty,
               "the original title must stay searchable after leaving the detail pane: \(unsearchableTitles)")
        expect(unsearchableContext.isEmpty,
               "the reviewed context must stay searchable after leaving the detail pane: \(unsearchableContext)")

        // The browser's own detail projection must keep only the verified kind, and an English
        // subtitle query must still return its track from the real filtered list.
        if let sample = tracks.first(where: { !$0.subtitle.isEmpty }) {
            browser.search = sample.subtitle
            expect(browser.rows.contains { $0.id == sample.id },
                   "an original English title must still return its track from the library")
            browser.search = ""
            browser.selectedID = sample.id
            expect(browser.selectedDetailMetadata == [PerformanceDisplay.kindLabel(for: sample)],
                   "the browser detail must expose only the verified kind for \(sample.id)")
        } else {
            expect(false, "the bundled library must contain a track with an original title")
        }

        // Queue rows reuse the same shared label; an unknown entry never invents one.
        if let sample = tracks.first(where: { PerformanceDisplay.rowContext(for: $0) != nil }) {
            let entry = PerformanceQueueEntry(id: "display-queue-entry",
                performanceID: PerformanceID(sample.id), presentation: .sidePerformance, mode: .watch)
            expect(browser.queueEntryContext(entry) == PerformanceDisplay.rowContext(for: sample),
                   "queue rows must reuse the shared display label")
        }
        let unknown = PerformanceQueueEntry(id: "display-queue-unknown",
            performanceID: PerformanceID("missing-manifest-track"), presentation: .sidePerformance, mode: .listen)
        expect(browser.queueEntryContext(unknown) == nil,
               "an unknown queue entry must not invent a display label")

        // Normal library availability is one concise line whose tooltip keeps the full path
        // and the technical count/validation detail; every other state stays a visible message.
        let availability = PerformanceBrowserModel()
        availability.library = library
        availability.root = "/synthetic/bside-availability-regression"
        expect(availability.libraryAvailabilitySummary == nil,
               "an unscanned root must not claim the library is ready")
        expect(availability.libraryAvailabilityHelp.contains("/synthetic/bside-availability-regression"),
               "the tooltip must carry the full selected path")
        availability.scanning = true
        expect(availability.libraryAvailabilitySummary == nil,
               "a scan in progress must not claim the library is ready")
        availability.scanning = false
        availability.scanFailure = "synthetic failure"
        expect(availability.libraryAvailabilitySummary == nil,
               "a failed scan must keep its own visible message, not a ready summary")
        availability.scanFailure = nil
        availability.scanned = true
        let summary = availability.libraryAvailabilitySummary ?? ""
        expect(summary == "曲库已就绪", "a successful scan must produce the one concise availability line")
        expect(!summary.contains("/synthetic") && !summary.contains("版本"),
               "the availability line must not expose the path or the technical prose")
        availability.scanDetail = "找到 1 / 2 个已知版本；点播时校验完整文件。"
        expect(availability.libraryAvailabilityHelp.contains("/synthetic/bside-availability-regression")
               && availability.libraryAvailabilityHelp.contains("1 / 2 个已知版本")
               && availability.libraryAvailabilityHelp.contains("校验完整文件"),
               "the tooltip must retain the found-version count and validation detail")

        // Any reported missing variant must replace the ready line with one concise visible
        // recovery line, counted straight from the unavailable map. An entirely unusable
        // library keeps that same line instead of claiming readiness, and the tooltip keeps
        // the full technical detail.
        availability.unavailable = ["synthetic.variant.one": "synthetic missing source"]
        expect(availability.libraryAvailabilitySummary == "有 1 个版本不可用，请重新检查",
               "one missing variant must replace the ready line with the concise recovery line")
        expect(availability.libraryAvailabilityHelp.contains("/synthetic/bside-availability-regression")
               && availability.libraryAvailabilityHelp.contains("1 / 2 个已知版本"),
               "the missing-variant state must keep the full detail in the tooltip")
        availability.unavailable = Dictionary(uniqueKeysWithValues: tracks.flatMap {
            $0.variants.map { ($0.id, "synthetic missing source") }
        })
        let unusableCount = availability.unavailable.count
        let missingSummary = availability.libraryAvailabilitySummary ?? ""
        expect(unusableCount > 1 && missingSummary == "有 \(unusableCount) 个版本不可用，请重新检查",
               "a library with no usable variant must keep the same concise visible recovery line")
        expect(!missingSummary.contains("/synthetic"),
               "the missing-variant line must not expose the path")
        availability.unavailable = [:]
        expect(availability.libraryAvailabilitySummary == "曲库已就绪",
               "clearing every missing variant must restore the ready line")

        // Watch and listen share one plain camera heading; the source meaning lives in help.
        let camera = PerformanceBrowserModel()
        camera.playbackMode = .watch
        let watchCameraTitle = camera.presentationControlTitle
        camera.playbackMode = .listen
        expect(watchCameraTitle == "机位" && camera.presentationControlTitle == watchCameraTitle,
               "watch and listen must share the same plain 机位 heading")
    } catch {
        expect(false, "display metadata regression needs the bundled library: \(error)")
    }
}
