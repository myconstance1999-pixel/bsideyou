// Native library layout over the existing ControlApp-owned selection and session state.
import Foundation
import SwiftUI
import BSideCore
import BSidePlatform

// Explicitly name the property-wrapper type: this SDK also exports a State macro whose
// SwiftUIMacros plugin is absent from the CLT toolchain.
private typealias StringState = State<String>
private typealias BrowserBoolState = State<Bool>

enum PerformanceBrowserSection: Hashable { case library, queue }

/// Library category filter over the existing verified `PerformanceManifest.Track.kind` plus the
/// explicit reviewed classical-repertoire ID set (`PerformanceClassicalCatalog`). Official
/// assignments remain unchanged. Local categories describe audible performance only and never
/// imply membership in the reviewed classical repertoire. All filters are browse-only state.
enum PerformanceCategoryFilter: String, CaseIterable, Hashable {
    case all
    case classical
    case piano
    case vocal
    case instrumental
    case unclassified

    var label: String {
        switch self {
        case .all: return "全部"
        case .classical: return "古典"
        case .piano: return "钢琴"
        case .vocal: return "弹唱"
        case .instrumental: return "其他器乐"
        case .unclassified: return "待分类"
        }
    }

    func matches(_ track: PerformanceManifest.Track) -> Bool {
        switch self {
        case .all:
            return true
        case .classical:
            // Explicit stable ID membership only; never a title/composer string heuristic.
            return PerformanceClassicalCatalog.contains(track)
        case .piano:
            // The remaining piano tracks: the reviewed classical repertoire is excluded, so a
            // track is in exactly one of 古典 / 钢琴. Unconfirmed origins are not in the
            // classical set, so they keep this existing piano bucket.
            return track.kind == .pianoSolo && !PerformanceClassicalCatalog.contains(track)
        case .vocal:
            return track.kind == .vocalPerformance
        case .instrumental, .unclassified:
            return false
        }
    }

    func matches(_ track: LocalSongTrack) -> Bool {
        switch self {
        case .all: return true
        case .classical: return false
        case .piano: return track.classification?.category == .piano
        case .vocal: return track.classification?.category == .vocal
        case .instrumental: return track.classification?.category == .instrumental
        case .unclassified: return track.classification == nil || track.classification?.category == .unclassified
        }
    }
}

extension LocalSongCategory {
    var label: String {
        switch self {
        case .piano: return "钢琴"
        case .vocal: return "弹唱"
        case .instrumental: return "其他器乐"
        case .unclassified: return "待分类"
        }
    }
}

extension LocalSongStyle {
    var label: String {
        switch self {
        case .gentle: return "柔和舒缓"
        case .lyrical: return "温柔抒情"
        case .bright: return "轻快明亮"
        case .energetic: return "激昂有力"
        case .melancholic: return "忧伤沉静"
        case .atmospheric: return "空灵氛围"
        case .majestic: return "庄严宏大"
        case .unclassified: return "未分类"
        }
    }
}

/// Independent source/composer filter built from the existing `PerformanceDisplay`
/// metadata. The curated table already marks an unconfirmed origin with
/// `PerformanceDisplay.unconfirmedSource`, so "unknown" is a real selectable value
/// rather than a second, invented bucket.
enum PerformanceSourceFilter: Hashable {
    case all
    case source(String)

    /// Selector value for the explicit unknown bucket. It is a single private-use scalar,
    /// so a curated source label can never collide with it.
    static let unknownValue = "\u{F8FF}unknown"

    var pickerValue: String {
        switch self {
        case .all: return ""
        case .source(let source): return source == PerformanceDisplay.unconfirmedSource ? Self.unknownValue : source
        }
    }

    static func fromPickerValue(_ value: String) -> PerformanceSourceFilter {
        if value.isEmpty { return .all }
        if value == unknownValue { return .source(PerformanceDisplay.unconfirmedSource) }
        return .source(value)
    }

    func matches(_ track: PerformanceManifest.Track) -> Bool {
        switch self {
        case .all: return true
        case .source(let expected):
            let actual = PerformanceDisplay.context(for: track)?.source ?? PerformanceDisplay.unconfirmedSource
            return actual == expected
        }
    }
}

/// One visible library row. Official reviewed catalog tracks and explicit local songs share one
/// list so the existing filters/search/counts keep working; the two cases never masquerade as
/// each other (a local row has no kind, lighting, camera or fabricated composer).
enum LibraryRow: Identifiable {
    case official(PerformanceManifest.Track)
    case local(LocalSongTrack)

    var id: String {
        switch self {
        case .official(let track): return track.id
        case .local(let track): return track.id
        }
    }

    var title: String {
        switch self {
        case .official(let track): return track.title
        case .local(let track): return track.displayTitle
        }
    }

    var official: PerformanceManifest.Track? {
        if case .official(let track) = self { return track }
        return nil
    }

    var local: LocalSongTrack? {
        if case .local(let track) = self { return track }
        return nil
    }
}

enum PerformanceStyleFilter: String, CaseIterable, Hashable {
    case all, classical, game, folk, other
    case gentle, lyrical, bright, energetic, melancholic, atmospheric, majestic

    var label: String {
        switch self {
        case .all: return "全部风格"
        case .classical: return "古典"
        case .game: return "游戏原声"
        case .folk: return "民歌与童谣"
        case .other: return "其他／未分类"
        case .gentle: return LocalSongStyle.gentle.label
        case .lyrical: return LocalSongStyle.lyrical.label
        case .bright: return LocalSongStyle.bright.label
        case .energetic: return LocalSongStyle.energetic.label
        case .melancholic: return LocalSongStyle.melancholic.label
        case .atmospheric: return LocalSongStyle.atmospheric.label
        case .majestic: return LocalSongStyle.majestic.label
        }
    }

    static func group(_ track: PerformanceManifest.Track) -> Self {
        guard let context = PerformanceDisplay.context(for: track), context.confidence == .verified else { return .other }
        switch context.source {
        case "巴赫", "圣-桑", "帕赫贝尔", "德彪西", "拉威尔", "拉赫玛尼诺夫",
             "斯克里亚宾", "斯卡拉蒂", "李斯特", "柴可夫斯基", "格里格", "肖邦",
             "舒伯特", "舒曼", "莫扎特", "萨蒂", "贝多芬", "里姆斯基-科萨科夫", "门德尔松": return .classical
        case "原神", "崩坏3", "崩坏：星穹铁道": return .game
        case "中国民歌", "中国童谣", "儿歌", "学堂乐歌", "苏格兰民歌": return .folk
        default: return .other
        }
    }

    func matches(_ track: PerformanceManifest.Track) -> Bool { self == .all || Self.group(track) == self }

    func matches(_ track: LocalSongTrack) -> Bool {
        if self == .all { return true }
        switch track.classification?.style ?? .unclassified {
        case .unclassified: return self == .other
        case .gentle: return self == .gentle
        case .lyrical: return self == .lyrical
        case .bright: return self == .bright
        case .energetic: return self == .energetic
        case .melancholic: return self == .melancholic
        case .atmospheric: return self == .atmospheric
        case .majestic: return self == .majestic
        }
    }
}

final class PerformanceBrowserModel: ObservableObject {
    @Published var library: PerformanceLibrary? { didSet { refreshRetentionValidation() } }
    @Published var mediaRetention = MediaRetentionState.absent { didSet { refreshRetentionValidation() } }
    @Published var retentionProblem: String?
    @Published var root: String?
    @Published var unavailable: [String: String] = [:]
    @Published var scanning = false
    @Published var scanned = false
    @Published var scanFailure: String?
    // Technical discovery result for the selected root (candidate version count plus the
    // point-of-play validation note). The library header keeps it in the availability
    // line's tooltip instead of always-visible prose.
    @Published var scanDetail: String?
    @Published var message = "选择你的官方演奏素材文件夹。"
    @Published var sessionState = PerformanceSessionState() {
        didSet {
            if oldValue.session?.id != sessionState.session?.id { clearPicturePresentation() }
        }
    }
    @Published private(set) var picturePresentation: PerformancePresentationReport?
    var setPictureExpanded: (Bool) -> Void = { _ in }

    func clearPicturePresentation() { picturePresentation = nil }

    func receivePicturePresentation(_ report: PerformancePresentationReport) {
        guard sessionState.session?.id == report.sessionID else { return }
        picturePresentation = report
    }

    var pictureIsExpanded: Bool {
        picturePresentation?.state == .expanded || picturePresentation?.state == .collapsing
    }

    var canTogglePicture: Bool {
        guard serviceReady, let session = sessionState.session, session.mode == .watch,
              let report, report.sessionID == session.id,
              report.state == .playing || report.state == .paused,
              let picturePresentation, picturePresentation.sessionID == session.id else { return false }
        return picturePresentation.state == .collapsed || picturePresentation.state == .expanded
    }

    func togglePicture() {
        guard canTogglePicture else { return }
        setPictureExpanded(!pictureIsExpanded)
    }
    @Published var report: PerformanceReport?
    @Published var desired = DesiredState()
    @Published var serviceReady = false {
        didSet { if !serviceReady { clearPicturePresentation() } }
    }
    @Published var selectedID: String?
    @Published var favorites: Set<PerformanceID> = []
    @Published var favoriteLocalTrackIDs: Set<String> = []
    @Published var onlyFavorites = false
    @Published var styleFilter: PerformanceStyleFilter = .all
    var toggleFavorite: (String) -> Void = { _ in }

    func isFavorite(_ id: String) -> Bool {
        localTrack(id) != nil ? favoriteLocalTrackIDs.contains(id) : favorites.contains(PerformanceID(id))
    }

    var currentSongID: String? {
        guard let session = sessionState.session else { return nil }
        switch session.target {
        case .catalog(let variant): return variant.performanceID.rawValue
        case .localFile(let file): return file.trackID
        }
    }

    var favoriteQueueTargets: Set<PerformanceQueueTarget> {
        Set(queueState.configuration.entries.compactMap { entry in
            switch entry.target {
            case .official(let id, _): return favorites.contains(id) ? entry.target : nil
            case .localFile(let id, _): return favoriteLocalTrackIDs.contains(id) ? entry.target : nil
            }
        })
    }

    @Published var search = ""
    @Published var onlyFound = false
    /// Transient library filters. In-memory only: they survive page changes but are never
    /// persisted, so a cold launch starts on 全部/all again (unified-window requirement).
    @Published var categoryFilter: PerformanceCategoryFilter = .all
    @Published var sourceFilter: PerformanceSourceFilter = .all
    /// Automatic browsing chooses the available front view per song. Explicit choices stay exact.
    @Published var automaticCamera = true
    @Published var presentation: PerformancePresentation = .sidePerformance {
        didSet { automaticCamera = false }
    }
    @Published var playbackMode: PerformancePlaybackMode = .watch
    @Published var queueState = PerformanceQueueState()
    @Published var songNavigation = SongPlaybackNavigation()
    @Published var songHistory: [SongPlaybackRecord] = []
    @Published var songHistoryError: String?
    @Published var songHistoryPlaybackError: String?
    @Published var showingSongHistory = false
    var previousSong: () -> Void = {}
    var replaySongHistory: (SongPlaybackRecord) -> Void = { _ in }
    var retrySongHistory: () -> Void = {}
    var canPreviousSong: Bool {
        guard sessionState.session != nil || queueState.isRunning else { return false }
        var navigation = songNavigation
        guard let previous = navigation.requestMove(-1) else { return false }
        return songHistoryUnavailableReason(previous.item.record) == nil
    }
    @Published var selectedQueueEntryID: String?
    @Published var section: PerformanceBrowserSection = .library
    /// Explicit local songs (ADR-022). Nil until the ControlApp-owned store is loaded; a
    /// store/scan problem is surfaced through `localMessage` and never overwrites the store.
    @Published var localCatalog: LocalSongCatalog? { didSet { refreshRetentionValidation() } }
    @Published var localMessage: String?
    var pickRoot: () -> Void = {}
    var refresh: () -> Void = {}
    var play: (String, PerformancePresentation, PerformancePlaybackMode) -> Void = { _, _, _ in }
    /// Generic "Add Songs" directory action over the existing library.
    var addLocalRoot: () -> Void = {}
    var refreshLocal: () -> Void = {}
    var renameLocal: (String, String) -> Void = { _, _ in }
    var classifyLocal: (String, LocalSongClassification) -> Void = { _, _ in }
    var selectLocalFile: (String, String) -> Void = { _, _ in }
    var playLocal: (String, String, PerformancePlaybackMode) -> Void = { _, _, _ in }
    var enqueueLocal: (String, String, PerformancePlaybackMode) -> Void = { _, _, _ in }
    var pause: () -> Void = {}
    var stop: () -> Void = {}
    var enqueue: (String, PerformancePresentation, PerformancePlaybackMode) -> Void = { _, _, _ in }
    /// Library 随机播放: the owner replaces the saved queue with this exact snapshot, selects the
    /// existing shuffle order and starts immediately. An empty snapshot is never passed here.
    var startFilteredShuffle: ([PerformanceQueueEntry]) -> Void = { _ in }
    /// ADR-024 list playback: the owner replaces the saved queue with this exact ordered snapshot
    /// of the currently visible eligible rows and starts the named entry inside it. The snapshot
    /// was captured when the user acted, so later browsing changes cannot mutate it.
    var startListPlayback: ([PerformanceQueueEntry], String) -> Void = { _, _ in }
    /// Selected song 加入并播放: the owner appends this exact entry and starts that new entry.
    var addAndPlay: (PerformanceQueueEntry) -> Void = { _ in }
    /// 下一首播放: the owner inserts this exact entry immediately after the current one.
    var playNext: (PerformanceQueueEntry) -> Void = { _ in }
    var startQueue: (String?) -> Void = { _ in }
    var nextInQueue: () -> Void = {}
    var removeQueueEntry: (String) -> Void = { _ in }
    var moveQueueEntry: (String, Int) -> Void = { _, _ in }
    var clearQueue: () -> Void = {}
    var setQueueOrder: (PerformanceQueueOrder) -> Void = { _ in }

    static func scanFailureMessage(_ error: Error) -> String {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain {
            switch CocoaError.Code(rawValue: error.code) {
            case .fileReadNoPermission:
                return "无法读取该目录。请确认目录权限后点按“重新检查”，或选择其他目录。"
            case .fileNoSuchFile, .fileReadNoSuchFile:
                return "该目录已移动或不存在，请重新选择目录。"
            default:
                break
            }
        }
        return "无法检查该目录。请确认目录可访问后点按“重新检查”，或选择其他目录。"
    }

    var rows: [PerformanceManifest.Track] {
        let date = Date()
        return (library?.manifest.tracks ?? []).filter {
            // Search covers the curated Chinese source/composer labels as well as the
            // original title/subtitle, through the shared display helper. Category,
            // source, search and only-found combine with AND; filtering changes which
            // rows are VISIBLE only and never touches identity, sorting, selection or
            // any playing/queued item.
            styleFilter.matches($0)
                && (!onlyFavorites || favorites.contains(PerformanceID($0.id)))
                && categoryFilter.matches($0)
                && sourceFilter.matches($0)
                && (!onlyFound || hasCandidate($0.id, at: date))
                && PerformanceDisplay.matches($0, search: search)
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Every distinct reviewed source/composer label plus the explicit unknown bucket,
    /// derived from the existing metadata only. No new attribution is invented here.
    var availableSources: [String] {
        var seen = Set<String>()
        for track in library?.manifest.tracks ?? [] {
            let source = PerformanceDisplay.context(for: track)?.source ?? PerformanceDisplay.unconfirmedSource
            if !source.isEmpty { seen.insert(source) }
        }
        return seen.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// True while any library filter narrows the list. Used by the clear-all action's
    /// enabled state and by the results line, never to change playback.
    var hasActiveLibraryFilters: Bool {
        !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || onlyFound
            || onlyFavorites
            || styleFilter != .all
            || categoryFilter != .all
            || sourceFilter != .all
    }

    /// Clears every library filter at once. Selection, sorting, playback mode and any
    /// active session/queue are deliberately untouched.
    func clearLibraryFilters() {
        search = ""
        onlyFound = false
        onlyFavorites = false
        styleFilter = .all
        categoryFilter = .all
        sourceFilter = .all
    }

    // MARK: - Explicit local songs (ADR-022)

    /// Every persisted local track, whatever the current filters. Used for identity lookups.
    var localTracks: [LocalSongTrack] { localCatalog?.tracks ?? [] }

    func localTrack(_ id: String) -> LocalSongTrack? { localTracks.first { $0.id == id } }

    /// A local track is "found" only while its root is reachable and at least one file is present.
    func localTrackIsAvailable(_ track: LocalSongTrack) -> Bool {
        if mediaRetention.document?.local.contains(where: { $0.trackID == track.id }) == true {
            return localPlaybackProblem(track, fileID: track.selectedFileID) == nil
        }
        guard retentionProblem == nil else { return false }
        guard let root = localCatalog?.root(id: track.rootID) else { return false }
        return !root.isMissing && track.isAvailable
    }

    /// Local classification narrows category and mood independently. Source/composer remains
    /// unknown, so the existing reviewed-source filtering continues to exclude local rows.
    private func localMatches(_ track: LocalSongTrack) -> Bool {
        guard categoryFilter.matches(track), sourceFilter == .all, styleFilter.matches(track) else { return false }
        if onlyFavorites, !favoriteLocalTrackIDs.contains(track.id) { return false }
        if onlyFound, !localTrackIsAvailable(track) { return false }
        return localSearchMatches(track)
    }

    /// Read the latest committed track so changing one picker preserves the other field. A manual
    /// correction has its own provenance, rather than claiming the model authored the new value.
    func setLocalClassification(trackID: String, category: LocalSongCategory? = nil,
                                style: LocalSongStyle? = nil) {
        guard let track = localTrack(trackID) else { return }
        classifyLocal(trackID, LocalSongClassification(
            category: category ?? track.classification?.category ?? .unclassified,
            style: style ?? track.classification?.style ?? .unclassified, origin: .manual))
    }

    private func localSearchMatches(_ track: LocalSongTrack) -> Bool {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        if track.displayTitle.localizedCaseInsensitiveContains(query) { return true }
        if let custom = track.customTitle, custom.localizedCaseInsensitiveContains(query) { return true }
        // Only the local file names are searched; no official metadata is fabricated for them.
        return track.files.contains { $0.basename.localizedCaseInsensitiveContains(query) }
    }

    var localRows: [LocalSongTrack] {
        localTracks.filter(localMatches).sorted {
            $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending
        }
    }

    /// The one visible library list: official reviewed rows plus explicit local rows.
    var visibleRows: [LibraryRow] {
        (rows.map { LibraryRow.official($0) } + localRows.map { LibraryRow.local($0) })
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var libraryTotalCount: Int { (library?.manifest.tracks.count ?? 0) + localTracks.count }

    /// Selected row across both library kinds, independent of the active filters.
    var selectedRow: LibraryRow? {
        if let track = selectedTrack { return .official(track) }
        if let local = localTrack(selectedID ?? "") { return .local(local) }
        return nil
    }

    var selectedLocalTrack: LocalSongTrack? { selectedRow?.local }

    /// Total counts include new local rows; the number stays filter-independent.
    var libraryResultSummary: String {
        "显示 \(visibleRows.count) / \(libraryTotalCount) 首"
    }

    // Absence from the missing-file map means found only after a successful scan.
    // This is a metadata candidate, never a substitute for point-of-play identity validation.
    func hasCandidate(_ id: String, at date: Date = Date()) -> Bool {
        guard root != nil, scanned, !scanning, scanFailure == nil,
              let variant = selection(id, at: date) else { return false }
        return unavailable[variant.variantID.rawValue] == nil
    }

    var filterContext: String {
        if mediaRetention.document?.official.isEmpty == false { return "" }
        let lighting = PlaybackPolicy.performanceLighting(desired: desired, minuteOfDay: BeijingClock.minuteOfDay(at: Date()))
        return "\(PerformanceDisplay.label(for: lighting)) · \(automaticCamera ? "自动 · 正面优先" : PerformanceDisplay.label(for: presentation))"
    }

    /// One concise availability line for the library header. Nil whenever the directory is
    /// unselected, still scanning, failed, or the manifest is unavailable, so every
    /// failed/recovery message keeps its own visible channel. A successful scan with any
    /// reported missing variant states that count instead of claiming the library is ready;
    /// the full technical detail stays in the tooltip.
    var libraryAvailabilitySummary: String? {
        if let retentionProblem { return retentionProblem }
        guard root != nil, library != nil, scanned, !scanning, scanFailure == nil else { return nil }
        guard requiredUnavailableVariants.isEmpty else {
            return "有 \(requiredUnavailableVariants.count) 个版本不可用，请重新检查"
        }
        return "曲库已就绪"
    }

    /// Tooltip for the availability line: the full selected path plus the technical
    /// discovery detail (found-version count and full-file validation timing). It never
    /// replaces the visible message while the library is not normally available.
    var libraryAvailabilityHelp: String {
        let detail = mediaRetention.document == nil ? scanDetail :
            "找到 \(requiredOfficialVariantIDs.count - requiredUnavailableVariants.count) / \(requiredOfficialVariantIDs.count) 个保留版本；点播时校验完整文件。"
        return [root, detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// One plain camera heading for both watch and listen. The listen-mode meaning already
    /// lives in the collapsed 播放说明 help (`机位指定音轨的素材来源。`), so the visible label
    /// stays identical and non-technical in both modes.
    var presentationControlTitle: String { "机位" }

    var emptyListMessage: String {
        guard library != nil else { return "演奏清单不可用" }
        if onlyFound {
            guard root != nil else { return "尚未选择演奏素材目录" }
            if scanning { return "正在检查素材目录…" }
            if scanFailure != nil { return "素材检查失败" }
            guard scanned else { return "尚未检查素材" }
            return search.isEmpty ? "当前时段与机位没有素材" : "没有匹配的曲目"
        }
        return "没有匹配的曲目"
    }

    func selection(_ id: String, at date: Date = Date()) -> ResolvedPerformanceVariant? {
        selection(id, presentation: preferredPresentation(for: id, at: date), at: date)
    }

    /// Resolve only this song and lighting. A scan-reported missing front view may use side;
    /// point-of-play identity errors still fail through the existing admission path.
    func preferredPresentation(for id: String, at date: Date = Date()) -> PerformancePresentation {
        if let keeper = retainedOfficialVariant(id) { return keeper.presentation }
        guard automaticCamera else { return presentation }
        if let front = selection(id, presentation: .portraitPerformance, at: date),
           unavailable[front.variantID.rawValue] == nil {
            return .portraitPerformance
        }
        return .sidePerformance
    }

    func selection(_ id: String, presentation: PerformancePresentation, at date: Date = Date()) -> ResolvedPerformanceVariant? {
        guard retentionProblem == nil else { return nil }
        if let keeper = retainedOfficialVariant(id) { return keeper }
        guard let library else { return nil }
        let lighting = PlaybackPolicy.performanceLighting(desired: desired, minuteOfDay: BeijingClock.minuteOfDay(at: date))
        guard case .resolved(let variant) = VariantResolver.resolve(trackID: PerformanceID(id), in: library.snapshot,
            effectiveLighting: lighting, presentationPreference: .explicit(presentation)) else { return nil }
        return variant
    }

    var playbackReadinessProblem: String? {
        if let retentionProblem { return retentionProblem }
        guard serviceReady else { return "播放器尚未就绪，请查看上方的提示。" }
        guard library != nil else { return "演奏清单不可用。" }
        guard root != nil else { return "请先选择演奏素材目录。" }
        guard !scanning else { return "正在检查素材目录…" }
        if let scanFailure { return scanFailure }
        guard scanned else { return "请先点按“重新检查”。" }
        return nil
    }

    func playbackProblem(id: String?, presentation: PerformancePresentation, at date: Date = Date()) -> String? {
        if let problem = playbackReadinessProblem { return problem }
        guard let id else { return "从曲库中选择一首。" }
        guard let variant = selection(id, presentation: presentation, at: date) else { return "这首曲目不支持所选机位。" }
        return unavailable[variant.variantID.rawValue]
    }

    var selectionProblem: String? {
        if let local = selectedLocalTrack { return localSelectionProblem(local) }
        return playbackProblem(id: selectedID, presentation: selectedID.map { preferredPresentation(for: $0) } ?? presentation)
    }

    /// A local row never fabricates official eligibility. Its only requirements are an
    /// authorized, reachable root and a remembered file that is currently present.
    func localSelectionProblem(_ track: LocalSongTrack) -> String? {
        if let retentionProblem { return retentionProblem }
        guard serviceReady else { return "播放器尚未就绪，请查看上方的提示。" }
        return localPlaybackProblem(track, fileID: track.selectedFileID)
    }

    /// Neutral version label for one local file: 版本1/2/3 over the stable basename order.
    /// Never an official camera or lighting label.
    func localVersionLabel(_ track: LocalSongTrack, file: LocalSongFile) -> String {
        "版本\(track.versionNumber(ofFile: file.id) ?? 0)"
    }

    func playSelection() {
        if let local = selectedLocalTrack {
            playLocalSelection(local)
            return
        }
        guard selectionProblem == nil, let selectedID else { return }
        play(selectedID, preferredPresentation(for: selectedID), playbackMode)
    }

    /// Explicit single-track start for one local row: exactly the remembered file of the
    /// selected track, in the chosen mode. There is no fallback to another file.
    func playLocalSelection(_ track: LocalSongTrack, mode: PerformancePlaybackMode? = nil) {
        guard localSelectionProblem(track) == nil, let fileID = displayedLocalFile(track)?.id else { return }
        playLocal(track.id, fileID, mode ?? playbackMode)
    }

    var sessionTitle: String? {
        guard let session = sessionState.session else { return nil }
        switch session.target {
        case .catalog(let variant):
            return library?.manifest.tracks.first { $0.id == variant.performanceID.rawValue }?.title
        case .localFile(let reference):
            return localTrack(reference.trackID)?.displayTitle
        }
    }

    /// The selected manifest track, resolved from the existing library snapshot only.
    var selectedTrack: PerformanceManifest.Track? {
        library?.manifest.tracks.first { $0.id == selectedID }
    }

    /// Detail-pane secondary metadata. The row already carries the title and the shared
    /// source/composer label, so the detail keeps the verified kind only and never repeats
    /// the original title, work or context line (see `PerformanceDisplay.detailMetadataLines`).
    var selectedDetailMetadata: [String] {
        selectedTrack.map(PerformanceDisplay.detailMetadataLines(for:)) ?? []
    }

    // Browsing another mode never changes the active session's controls or explanation.
    var sessionModeLabel: String? { sessionState.session.map { PerformanceDisplay.label(for: $0.mode) } }

    /// Official sessions keep their official lighting/camera labels. A local session adds no
    /// source classification: the row/title already identify it, so this stays empty.
    var sessionTargetLabels: [String] {
        guard let session = sessionState.session else { return [] }
        switch session.target {
        case .catalog(let variant):
            return [PerformanceDisplay.label(for: variant.lighting),
                    PerformanceDisplay.label(for: variant.presentation)]
        case .localFile:
            return []
        }
    }

    var primaryMusicIsPaused: Bool { desired.paused || sessionState.session?.paused == true }

    var sessionPauseActionTitle: String {
        if desired.paused { return "恢复全部" }
        return sessionState.session?.paused == true ? "恢复音乐" : "暂停音乐"
    }

    var sessionStopActionTitle: String { "停止音乐" }

    // Only an Agent report for this session confirms runtime playback.
    var sessionStatus: String {
        if queueState.isRunning,
           sessionState.session == nil || queueState.activeSessionID != sessionState.session?.id {
            return "等待队列切换"
        }
        guard let session = sessionState.session, let report, report.sessionID == session.id else {
            return "等待播放器确认"
        }
        switch report.state {
        case .loading: return "正在校验与加载"
        case .playing: return "播放中"
        case .paused: return "已暂停"
        case .ended: return "已结束"
        case .stopped: return "已停止"
        case .failed: return "播放失败"
        }
    }
}

struct PerformanceBrowserView: View {
    @ObservedObject var model: PerformanceBrowserModel
    @ObservedObject var saveModel: ControlCenterModel
    /// The candidate's auxiliary panel uses the shell's shared transport and purpose heading.
    /// The standalone path keeps its own footer, heading and internal library/queue selector.
    var showsSessionFooter: Bool = true
    var fixedSection: PerformanceBrowserSection? = nil
    /// Unified-shell hook: "返回曲库" opens the library auxiliary panel.
    var showLibrary: (() -> Void)? = nil
    /// The standalone window keeps its historical dimensions; an auxiliary panel supplies
    /// smaller floors so the shell's header and shared transport fit the existing window.
    var minimumWidth: CGFloat = 740
    var isPageVisible = true
    var showsHeader = true
    var showsGlobalFeedback = true
    var minimumHeight: CGFloat = 600
    @BrowserBoolState private var showsFilters = false
    @BrowserBoolState private var showsDetails = false
    @Environment(\.colorScheme) private var colorScheme
    // Local disclosure state: the help starts collapsed and is never persisted.
    @StateObject private var playbackHelp = PlaybackHelpState()
    /// Editable local rename draft; committed through the owner only, never persisted here.
    /// Explicit wrapper type: the SDK also exports a State macro whose plugin is absent here.
    @StringState private var localTitleDraft = ""

    private var activeSection: PerformanceBrowserSection { fixedSection ?? model.section }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 0) {
                    if showsHeader { header.fixedSize(horizontal: false, vertical: true) }
                    else if activeSection == .library { searchField.padding(.bottom, 14) }
                    adaptiveLibraryTools.layoutPriority(1)
                    Divider().overlay(MusicWorkspaceAppearance.line)
                    browserContent
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, 24).padding(.top, 24)
            if showsSessionFooter {
                Divider()
                sessionFooter.fixedSize(horizontal: false, vertical: true)
            }
        }
        .background(MusicWorkspaceAppearance.background)
        .tint(MusicWorkspaceAppearance.accent)
        .frame(minWidth: minimumWidth, minHeight: minimumHeight)
        .sheet(isPresented: $showsDetails) {
            VStack(spacing: 0) {
                HStack {
                    Text("曲目信息").font(.headline)
                    Spacer()
                    Button("完成") { showsDetails = false }.keyboardShortcut(.defaultAction)
                }.padding(20)
                Divider()
                ScrollView { selectionDetail.padding(24) }
            }
            .frame(width: 440, height: 560)
            .background(MusicWorkspaceAppearance.background)
        }
        .onChange(of: isPageVisible) { visible in
            if !visible { showsFilters = false; showsDetails = false }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 20) {
            Text(activeSection == .queue ? "播放队列" : "音乐")
                .font(.system(size: 26, weight: .medium, design: .serif))
                .fixedSize()
            Spacer(minLength: 0)
            if activeSection == .library {
                searchField.frame(minWidth: 160, maxWidth: 270)
            } else {
                libraryManagementMenu
            }
        }
        .padding(.bottom, 18)
    }

    private var adaptiveLibraryTools: some View {
        ViewThatFits(in: .vertical) {
            libraryTools.fixedSize(horizontal: false, vertical: true)
            ScrollView(.vertical) { libraryTools }
        }
    }

    private var libraryTools: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsGlobalFeedback {
                PreferencesSaveFeedback(model: saveModel)
                ResourceRecoveryFeedback(model: saveModel)
            }
            if activeSection == .library {
                HStack(spacing: 6) {
                    favoriteTab("全部", favorites: false)
                    favoriteTab("收藏", favorites: true)
                    Spacer(minLength: 8)
                    Button { showsFilters.toggle() } label: {
                        Label(hasExtraFilters ? "筛选 · 已选" : "筛选", systemImage: "line.3.horizontal.decrease")
                            .font(.callout)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(MusicWorkspaceAppearance.accent)
                    .accessibilityIdentifier("library-filters")
                    .popover(isPresented: $showsFilters, arrowEdge: .bottom) { libraryFilters }
                }
                libraryActions
            }
            libraryMetadata
            if activeSection == .library, !model.scanning,
               model.root == nil || model.scanFailure != nil {
                Button(model.root == nil ? "选择音乐文件夹…" : "重新选择音乐文件夹…") {
                    presentDirectoryPicker(model.pickRoot)
                }
                .accessibilityIdentifier("library-recover-music-folder")
            }
            if activeSection == .library, model.selectedID != nil, let problem = model.selectionProblem {
                Label(problem, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 14)
    }

    private func favoriteTab(_ title: String, favorites: Bool) -> some View {
        Button { model.onlyFavorites = favorites } label: {
            Text(title).font(.callout.weight(model.onlyFavorites == favorites ? .semibold : .regular))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .foregroundStyle(model.onlyFavorites == favorites ? MusicWorkspaceAppearance.accent : Color.secondary)
                .background(model.onlyFavorites == favorites ? MusicWorkspaceAppearance.selected : .clear,
                            in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(favorites ? "library-tab-favorites" : "library-tab-all")
        .accessibilityAddTraits(model.onlyFavorites == favorites ? .isSelected : [])
    }

    private var libraryActions: some View {
        HStack(spacing: 12) {
            Text(model.hasActiveLibraryFilters ? model.libraryResultSummary : "\(model.libraryTotalCount) 首")
                .monospacedDigit().font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 6)
            Button(action: model.playSelectedFromList) {
                Label("播放", systemImage: "play.fill")
            }
            .buttonStyle(.plain)
            .disabled(model.selectedID == nil || model.selectionProblem != nil || !model.listPlayIsAvailable)
            .help(model.queueState.isRunning ? "用当前列表替换队列，从所选曲目开始播放。" : "从所选曲目开始，继续播放当前列表。")
            .accessibilityIdentifier("library-play-list")
            Button(action: model.startFilteredShufflePlayback) {
                Image(systemName: "shuffle")
            }
            .buttonStyle(.plain)
            .disabled(model.filteredShuffleProblem != nil)
            .accessibilityLabel("随机播放当前列表")
            .accessibilityIdentifier("library-shuffle")
            .help("用当前筛选结果替换队列，随机播放。")
        }
        .foregroundStyle(MusicWorkspaceAppearance.accent)
    }

    /// One ordinary library-management surface. The technical resource actions keep their exact
    /// existing commands; only their location changed, and both entries that must stay reachable
    /// during a missing-file problem (音乐文件夹… / 刷新曲库) remain in the always-available menu.
    /// The presence narrowing keeps an ordinary name: 已找到素材 is not an ordinary product term.
    private var libraryManagementMenu: some View {
        Menu("管理音乐") {
            Button("音乐文件夹…") { presentDirectoryPicker(model.pickRoot) }
            Button("添加歌曲…") { presentDirectoryPicker(model.addLocalRoot) }
            Button("刷新曲库", action: model.refresh)
                .disabled(model.root == nil || model.scanning)
            Divider()
            Button("只看当前有素材的曲目", action: { model.onlyFound = true })
            Button("显示全部曲目", action: { model.onlyFound = false })
        }
        .fixedSize()
        .help("管理演奏素材文件夹、添加歌曲、刷新曲库与可选的范围筛选。")
        .accessibilityIdentifier("library-management")
    }

    private func presentDirectoryPicker(_ action: @escaping () -> Void) {
        // Return from the menu action and dismiss its containing popover before AppKit
        // presents the existing native panel. The callback retains all grant validation.
        showsFilters = false
        DispatchQueue.main.async(execute: action)
    }

    private var hasExtraFilters: Bool {
        model.categoryFilter != .all || model.sourceFilter != .all || model.styleFilter != .all || model.onlyFound
    }

    private var libraryFilters: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("筛选").font(.headline)
                Spacer()
                Button("清除筛选", action: model.clearLibraryFilters)
                    .disabled(!model.hasActiveLibraryFilters)
            }
            categoryFilterPicker
            sourceFilter
            Picker("风格", selection: $model.styleFilter) {
                ForEach(PerformanceStyleFilter.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Toggle("仅显示当前有素材的曲目", isOn: $model.onlyFound)
                .toggleStyle(.checkbox)
            Divider()
            libraryManagementMenu
        }
        .padding(20).frame(width: 320)
    }

    private func favoriteButton(_ id: String) -> some View {
        Button { model.toggleFavorite(id) } label: {
            Image(systemName: model.isFavorite(id) ? "heart.fill" : "heart")
                .foregroundStyle(model.isFavorite(id) ? MusicWorkspaceAppearance.accent : Color.secondary)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(model.isFavorite(id) ? "取消收藏" : "收藏歌曲")
        .help(model.isFavorite(id) ? "取消收藏" : "收藏歌曲")
    }

    private var categoryFilterPicker: some View {
        Picker("曲目分类", selection: $model.categoryFilter) {
            ForEach(PerformanceCategoryFilter.allCases, id: \.self) { category in
                Text(category.label).tag(category)
            }
        }
        .pickerStyle(.menu)
        .tint(FrontendAppearance.accent)
        .accessibilityLabel("曲目分类")
    }

    private var sourceFilter: some View {
        HStack(spacing: 6) {
            Text("来源").font(.caption).foregroundStyle(.secondary)
            Picker("来源或作曲家", selection: sourceSelection) {
                Text("全部来源").tag("")
                Text(PerformanceDisplay.unconfirmedSource).tag(PerformanceSourceFilter.unknownValue)
                ForEach(model.availableSources.filter { $0 != PerformanceDisplay.unconfirmedSource },
                        id: \.self) { source in
                    Text(source).tag(source)
                }
            }
            .labelsHidden().frame(maxWidth: .infinity)
            .accessibilityLabel("来源或作曲家")
        }
    }

    private var sourceSelection: Binding<String> {
        Binding(get: { model.sourceFilter.pickerValue },
                set: { model.sourceFilter = PerformanceSourceFilter.fromPickerValue($0) })
    }

    // Compact secondary metadata. Normal availability is one concise line whose tooltip
    // carries the full path plus the candidate/validation detail; actionable messages (scan
    // progress/failure, playback, queue, recovery) keep their own visible line. Without a
    // root the list's empty state already names the missing selection.
    @ViewBuilder
    private var libraryMetadata: some View {
        if model.root != nil || !model.localTracks.isEmpty || model.localMessage != nil || model.retentionProblem != nil {
            VStack(alignment: .leading, spacing: 3) {
                if model.root == nil, let problem = model.retentionProblem {
                    Text(problem).fixedSize(horizontal: false, vertical: true)
                }
                if model.root != nil {
                    if let summary = model.libraryAvailabilitySummary,
                       model.retentionProblem != nil || !model.requiredUnavailableVariants.isEmpty {
                        Text(summary)
                            .fixedSize(horizontal: false, vertical: true)
                            .help(model.libraryAvailabilityHelp)
                    }
                }
                if let localMessage = model.localMessage, !localMessage.isEmpty {
                    Text(localMessage).fixedSize(horizontal: false, vertical: true)
                }
                if !model.message.isEmpty {
                    Text(model.message)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索曲名、作曲家或来源", text: $model.search)
                .textFieldStyle(.plain).accessibilityLabel("搜索曲名、作曲家或来源")
            if !model.search.isEmpty {
                Button { model.search = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain).accessibilityLabel("清空搜索").help("清空搜索")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(MusicWorkspaceAppearance.inset.opacity(0.7), in: RoundedRectangle(cornerRadius: 9))
    }

    private var browserContent: some View {
        VStack(spacing: 0) {
            // The in-view library/queue selector exists only for the standalone window. The
            // unified shell exposes the two as sidebar pages and passes `fixedSection`.
            if fixedSection == nil {
                HStack {
                    Picker("浏览内容", selection: $model.section) {
                        Text("曲库").tag(PerformanceBrowserSection.library)
                        Text("播放队列 (\(model.queueState.configuration.entries.count))").tag(PerformanceBrowserSection.queue)
                    }
                    .pickerStyle(.segmented).frame(width: 260)
                    .tint(FrontendAppearance.accent)
                    .accessibilityLabel("浏览内容")
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 20).padding(.vertical, 6)
                Divider()
            }
            if activeSection == .library {
                browserColumns
            } else {
                PerformanceQueueView(model: model, showLibrary: fixedSection == nil ? nil : showLibrary,
                                     showsHistorySelector: fixedSection == nil)
            }
        }
        .frame(minHeight: 220, maxHeight: .infinity)
    }

    private var browserColumns: some View {
        trackList.frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
    }

    private var trackList: some View {
        List(selection: $model.selectedID) {
            ForEach(model.visibleRows) { row in
                trackRow(row)
                    .tag(row.id)
                    // Double-click plays the clicked row immediately. `simultaneousGesture`
                    // keeps the List's own single-click selection intact (select-only), while
                    // `count: 2` never fires on a single click. `contentShape` only widens the
                    // row's own hit area (spacer/padding) for the gesture; it adds no gesture
                    // and does not take over the List selection.
                    .contentShape(Rectangle())
                    .simultaneousGesture(TapGesture(count: 2).onEnded { model.playListRow(row.id) })
                    .contextMenu { songActions(row) }
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .tint(MusicWorkspaceAppearance.accent)
        .overlay {
            if model.visibleRows.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "music.note.list").font(.title2)
                    Text(model.emptyListMessage)
                        .font(.callout)
                    if model.hasActiveLibraryFilters {
                        Button("清除筛选", action: model.clearLibraryFilters)
                    }
                }
                .padding(12)
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func trackRow(_ row: LibraryRow) -> some View {
        switch row {
        case .official(let track): officialTrackRow(track)
        case .local(let track): localTrackRow(track)
        }
    }

    private func officialTrackRow(_ track: PerformanceManifest.Track) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(track.title).font(.body).lineLimit(2)
                // The curated source/composer keeps each row self-explanatory; the English
                // subtitle moves to the detail pane. An uncurated track keeps its subtitle.
                if let context = PerformanceDisplay.rowContext(for: track) {
                    Text(context).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else if !track.subtitle.isEmpty {
                    Text(track.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            favoriteButton(track.id)
            songMenu(.official(track))
            if model.scanned, let variant = model.selection(track.id),
               model.unavailable[variant.variantID.rawValue] != nil {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary)
                    .help("所选时段的素材缺失或不匹配")
            }
        }
        .padding(.vertical, 10)
    }

    /// Local category and mood are secondary metadata; a version count appears only when useful.
    /// Missing classifications remain visible and never borrow reviewed source/composer labels.
    private func localTrackRow(_ track: LocalSongTrack) -> some View {
        let versionCount = model.displayedLocalFiles(track).count
        let versionSuffix = versionCount > 1 ? " · \(versionCount) 个版本" : ""
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(track.displayTitle).font(.body).lineLimit(2)
                Text("\((track.classification?.category ?? .unclassified).label) · \((track.classification?.style ?? .unclassified).label)\(versionSuffix)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            favoriteButton(track.id)
            songMenu(.local(track))
            if !model.localTrackIsAvailable(track) {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary)
                    .help("文件缺失或目录当前不可用")
            }
        }
        .padding(.vertical, 10)
    }

    private func songMenu(_ row: LibraryRow) -> some View {
        Menu { songActions(row) } label: {
            Image(systemName: "ellipsis").frame(width: 24, height: 28)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("\(row.title)的歌曲菜单")
    }

    @ViewBuilder
    private func songActions(_ row: LibraryRow) -> some View {
        let problem = row.local.map(model.localSelectionProblem) ??
            model.playbackProblem(id: row.id, presentation: model.preferredPresentation(for: row.id))
        Button("从这首开始播放") { model.playListRow(row.id) }.disabled(problem != nil)
        Button("只播放这首") { perform(row) { model.playSelectedEntryOnly() } }.disabled(problem != nil)
        Button("加入并播放") { perform(row) { model.addSelectionAndPlay() } }.disabled(problem != nil)
        Button("下一首播放") { perform(row) { model.playSelectionNext() } }
            .disabled(problem != nil || !model.queueState.isRunning || model.queueState.activeEntry == nil)
        // The existing owner checks exact eligibility, including the less restrictive official
        // enqueue rule. Opening a menu does not change selection or mutate the queue.
        Button("稍后播放") { perform(row) { model.enqueueSelection() } }
        Divider()
        Button(model.isFavorite(row.id) ? "取消收藏" : "收藏歌曲") { model.toggleFavorite(row.id) }
        Button("曲目信息…") {
            model.selectedID = row.id
            showsDetails = true
        }
    }

    private func perform(_ row: LibraryRow, action: () -> Void) {
        model.selectedID = row.id
        action()
    }

    /// Editing and file provenance stay available without competing with everyday playback.
    @ViewBuilder
    private func localSelectionDetail(_ track: LocalSongTrack) -> some View {
        Text(track.displayTitle)
            .font(FrontendAppearance.trackTitleFont)
            .lineLimit(3).fixedSize(horizontal: false, vertical: true)
        DisclosureGroup("曲目信息") {
            VStack(alignment: .leading, spacing: 10) {
                labeledControl("曲目名称") {
                    HStack(spacing: 8) {
                        TextField("未命名曲目", text: $localTitleDraft)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { model.renameLocal(track.id, localTitleDraft) }
                        Button("重命名") { model.renameLocal(track.id, localTitleDraft) }
                            .disabled(localTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                labeledControl("分类") {
                    Picker("分类", selection: Binding(
                        get: { track.classification?.category ?? .unclassified },
                        set: { model.setLocalClassification(trackID: track.id, category: $0) })) {
                        ForEach(LocalSongCategory.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.menu).accessibilityLabel("本地曲目分类")
                }
                labeledControl("风格") {
                    Picker("风格", selection: Binding(
                        get: { track.classification?.style ?? .unclassified },
                        set: { model.setLocalClassification(trackID: track.id, style: $0) })) {
                        ForEach(LocalSongStyle.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.menu).accessibilityLabel("本地曲目风格")
                }
                Text(track.classification?.origin == .automatic ? "自动分析，可手动调整" :
                     track.classification?.origin == .manual ? "已手动调整" : "尚未分类，可手动选择")
                    .font(.caption).foregroundStyle(.secondary)
                if model.displayedLocalFiles(track).count > 1 {
                    labeledControl("版本") {
                        Picker("版本", selection: Binding(
                            get: { model.displayedLocalFile(track)?.id ?? "" },
                            set: { model.selectLocalFile(track.id, $0) })) {
                            ForEach(model.displayedLocalFiles(track)) { file in
                                Text("\(model.localVersionLabel(track, file: file)) · \(file.basename)\(file.isPresent ? "" : "（缺失）")")
                                    .tag(file.id)
                            }
                        }
                        .pickerStyle(.menu).accessibilityLabel("版本")
                    }
                }
                if let file = model.displayedLocalFile(track) {
                    Text("文件：\(file.basename)\(file.isPresent ? "" : "（当前不可用）")")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2).truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let location = model.localCatalog?.root(id: track.rootID)?.displayPath {
                    Text(location).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2).truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.padding(.top, 6)
        }
    }

    private var selectionDetail: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let local = model.selectedLocalTrack {
                localSelectionDetail(local)
            } else {
                Text(model.selectedTrack?.title ?? "从左侧选择一首")
                    .font(FrontendAppearance.trackTitleFont)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                // The row above already shows the manifest title and the shared source/composer
                // label; the detail keeps only the verified kind and never repeats the original
                // title, work or context (they stay searchable).
                ForEach(model.selectedDetailMetadata, id: \.self) { line in
                    Text(line).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button(action: model.playSelectedFromList) {
                Label("播放", systemImage: "play.fill")
                    .frame(maxWidth: .infinity).padding(.vertical, 4)
                    .foregroundStyle(FrontendAppearance.actionForeground(for: colorScheme))
            }
            .buttonStyle(.borderedProminent)
            .tint(FrontendAppearance.actionTint(for: colorScheme))
            .disabled(model.selectedID == nil || model.selectionProblem != nil || !model.listPlayIsAvailable)
            .help("从这首开始，按当前显示顺序继续播放当前列表。")
            Button(action: model.playSelectedEntryOnly) {
                Label("只播放这首", systemImage: "play.circle")
                    .frame(maxWidth: .infinity)
            }
            .disabled(!model.canAddSelectionAndPlay)
            .help("只播放当前这一首，不继续播放列表。")
            Button(action: model.addSelectionAndPlay) {
                Label("加入并播放", systemImage: "play.square.stack")
                    .frame(maxWidth: .infinity)
            }
            .disabled(!model.canAddSelectionAndPlay)
            .help("把当前选择（含本地文件版本）加入队列并立即播放这一条；已有队列条目保留，当前歌曲会被这一条替换。")
            Button(action: model.playSelectionNext) {
                Label("下一首播放", systemImage: "text.line.first.and.arrowtriangle.forward")
                    .frame(maxWidth: .infinity)
            }
            .disabled(!model.canPlaySelectionNext)
            .help("把当前选择插入到正在播放的歌曲之后，不打断当前歌曲。")
            Button(action: model.enqueueSelection) {
                Label("稍后播放", systemImage: "text.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .disabled(!model.canEnqueueSelection)
            .help("只加入队列末尾，不开始播放，也不打断当前曲目。")
            if let problem = model.selectionProblem {
                Text(problem).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // The queue consequence stays visible whenever it can actually apply; the
            // collapsed help then omits the duplicate copy.
            if model.queueState.isRunning {
                Text("“播放”会用当前列表替换播放队列。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup(isExpanded: $playbackHelp.isExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("“播放”从这首开始，按当前显示顺序继续；“只播放这首”只播一首；"
                         + "“下一首播放”插到当前歌曲之后；“稍后播放”加到队列末尾。")
                    Text("打开或关闭歌曲演奏视频不改变音乐进度、音量和队列；按 Esc 关闭视频。")
                    if !model.queueState.isRunning {
                        Text("“播放”会用当前列表替换播放队列。")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text("播放说明").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { localTitleDraft = model.selectedLocalTrack?.customTitle ?? "" }
        .onChange(of: model.selectedID) { _ in
            localTitleDraft = model.selectedLocalTrack?.customTitle ?? ""
        }
    }

    // Keep captions above the controls instead of squeezing inline picker titles.
    private func labeledControl<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content().labelsHidden()
        }
    }

    private var sessionFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let session = model.sessionState.session {
                HStack(spacing: 12) {
                    Image(systemName: session.mode == .listen ? "headphones" : "music.note").font(.title3)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.sessionTitle ?? "当前演奏")
                            .font(.callout.weight(.medium)).lineLimit(1)
                        Text((model.sessionTargetLabels
                            + [model.sessionStatus])
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Button("上一首", action: model.previousSong).disabled(!model.canPreviousSong)
                    if model.queueState.isRunning || model.songNavigation.canForward {
                        Button("下一首", action: model.nextInQueue)
                    }
                    Button(model.sessionPauseActionTitle, action: model.pause)
                    PerformancePictureButton(model: model)
                    Button(model.sessionStopActionTitle, action: model.stop)
                }
            } else if model.queueState.isRunning {
                HStack(spacing: 12) {
                    Image(systemName: "music.note.list")
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.queueState.activeEntry.map(model.queueEntryTitle) ?? "播放队列")
                            .font(.callout.weight(.medium)).lineLimit(1)
                        Text(model.sessionStatus).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Button("上一首", action: model.previousSong).disabled(!model.canPreviousSong)
                    Button("下一首", action: model.nextInQueue)
                    Button("停止队列", action: model.stop)
                }
            } else {
                // One factual idle line; the removed disclaimer repeated the queue help.
                HStack(spacing: 8) {
                    Image(systemName: "circle.dotted")
                    Text("当前没有歌曲播放")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 9)
    }
}

// The lighting/presentation/mode wording is shared through `PerformanceDisplay.label(for:)`
// so the library, the queue and the unified shell's music strip present one label.

// View-owned, non-persistent disclosure state for the selected-track help.
private final class PlaybackHelpState: ObservableObject {
    @Published var isExpanded = false
}

/// Presentation-only control, visible only after the Agent owns a video surface.
struct PerformancePictureButton: View {
    @ObservedObject var model: PerformanceBrowserModel

    var body: some View {
        if model.picturePresentation != nil {
            Button(action: model.togglePicture) {
                Label(model.pictureIsExpanded ? "关闭歌曲视频" : "歌曲演奏视频",
                      systemImage: model.pictureIsExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.plain)
            .disabled(!model.canTogglePicture)
            .accessibilityIdentifier("music-toggle-picture")
            .help("打开或关闭歌曲演奏视频，音乐继续播放；陪伴场景保持不变。")
        }
    }
}
