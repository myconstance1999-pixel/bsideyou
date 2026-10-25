// BSideControlApp — Daily background chooser (ADR-024).
//
// The primary daily surface offers one video chooser. This model is the whole
// browsing/choosing state behind it:
//   * it enumerates actual admitted whole videos across all dayparts, preserving the
//     product exclusions (they are never discovered) and the current selection,
//   * one selected preview takes priority over a bounded visible thumbnail strip,
//   * it asks the Platform daily-preview service for a bounded still and displays only the result
//     of the request that is still current, so a stale image can never be shown,
//   * applying a candidate goes through the existing ordinary whole-combination preference path.
//
// Everything here is presentation + existing commands. No player, no AVFoundation, no media copy.
import Foundation
import SwiftUI
import BSideCore
import BSidePlatform

/// One admitted whole-video candidate; preview success is a separate capability.
struct DailyBackgroundCandidate: Equatable, Identifiable {
    let key: ContentKey
    /// True for the combination the daily preference is currently set to.
    let isCurrent: Bool

    var id: String { key.description }

    var familyTitle: String { "原片 \((BSideCore.Scene.allCases.firstIndex(of: key.scene) ?? 0) + 1)" }
    var title: String { "\(familyTitle) · 服装 \((Outfit.allCases.firstIndex(of: key.outfit) ?? 0) + 1) · \(key.time.controlCenterLabel)" }

    /// The raw identity. It is troubleshooting detail only, never the primary name.
    var technicalDetail: String {
        "文件键 \(key.description) · 目录中的正式素材文件"
    }
}

/// Result of one preview request as ControlApp sees it: either image data or an honest reason.
/// ControlApp never sees the Platform request types, so it never gains AVFoundation knowledge.
struct DailyBackgroundPreviewResult: Equatable {
    let key: ContentKey
    let data: Data?
    let failure: String?
    let failureKind: DailyPreviewFailureKind?

    init(_ outcome: DailyPreviewOutcome) {
        key = outcome.key
        data = outcome.data
        failure = outcome.failure
        failureKind = outcome.failureKind
    }

    static func image(_ key: ContentKey, _ data: Data) -> DailyBackgroundPreviewResult {
        DailyBackgroundPreviewResult(.image(key, data: data))
    }

    static func unavailable(_ key: ContentKey, _ reason: String,
                            kind: DailyPreviewFailureKind = .unavailable) -> DailyBackgroundPreviewResult {
        DailyBackgroundPreviewResult(.unavailable(key, reason, kind: kind))
    }
}

/// WHERE the one shared chooser is currently presented. It exists so the two callers that share
/// this model stay separated: the ordinary surfaces (daily page / settings) present it as a WINDOW
/// SHEET, while the notch island presents the SAME browsing state inside its own panel. A single
/// `isPresented` flag could not tell them apart, so an island navigation opened the window sheets
/// (and their `onDisappear` could cancel an unrelated island presentation). This is transient UI
/// routing only: it is never persisted, never sent over IPC and never a preference.
enum DailyBackgroundPresentation: Equatable {
    /// No surface is showing the chooser and no preview may run.
    case none
    /// The ordinary sheet on the full window / settings surface.
    case window
    /// The notch island's own background page, drawn inside the one panel.
    case island
}

/// Authorization gate for the daily still preview. The chooser may only read a loop through the
/// binding that was ACCEPTED for the daily root: if the lease's current fresh identity conflicts
/// with the identity captured at acceptance, the request is refused instead of reading whatever
/// now sits at the old path. Unknown current evidence cannot prove a conflict, so it passes — the
/// directory monitor still owns the authoritative cross-restart anchor and reselection flow.
enum DailyPreviewAuthorization {
    static func accepts(accepted: DirectoryIdentitySnapshot?,
                        fresh: DirectoryIdentitySnapshot?) -> Bool {
        guard let accepted, let fresh else { return true }
        if case .conflict = accepted.comparison(with: fresh) { return false }
        return true
    }
}

final class DailyBackgroundChooserModel: ObservableObject {
    /// All admitted whole-video combinations, current selection first.
    @Published private(set) var candidates: [DailyBackgroundCandidate] = []
    @Published private(set) var selectedIndex = 0
    /// Selected still; loading is explicit so an empty catalog never implies a spinner.
    @Published private(set) var previewImageData: Data?
    @Published private(set) var previewFailure: String?
    @Published private(set) var previewFailureKind: DailyPreviewFailureKind?
    @Published private(set) var isPreviewing = false
    @Published private(set) var thumbnailResults: [ContentKey: DailyBackgroundPreviewResult] = [:]
    @Published private(set) var applyNotice: String?
    @Published private(set) var applyFailed = false
    @Published private(set) var pendingSwitchMessage: String?
    @Published private(set) var timePolicySummary = ""

    static let maximumVisibleThumbnails = 7
    static let maximumThumbnailBytes = 4 * 1024 * 1024
    private var visibleThumbnailKeys: [ContentKey] = []
    private var thumbnailPixelSize = DailyPreviewPixelSize(width: 160, height: 90)
    private var activeThumbnail: ContentKey?
    private var thumbnailDestination: DailyBackgroundPresentation?
    private var selectedFamilyKeys: [BSideCore.Scene: ContentKey] = [:]

    var thumbnailByteCount: Int { thumbnailResults.values.reduce(0) { $0 + ($1.data?.count ?? 0) } }

    /// One representative per source family. Variants remain explicit choices, never new footage.
    var visibleCandidates: [DailyBackgroundCandidate] {
        BSideCore.Scene.allCases.compactMap { scene in
            let family = candidates.filter { $0.key.scene == scene }
            return family.first { $0.key == selectedCandidate?.key }
                ?? family.first { $0.key == selectedFamilyKeys[scene] }
                ?? family.first { $0.isCurrent }
                ?? family.first { thumbnailResults[$0.key]?.data != nil }
                ?? family.first
        }
    }

    var selectedFamilyVariants: [DailyBackgroundCandidate] {
        candidates.filter { $0.key.scene == selectedCandidate?.key.scene }
            .sorted { ($0.key.outfit.rawValue, $0.key.time.rawValue) < ($1.key.outfit.rawValue, $1.key.time.rawValue) }
    }

    var selectionStatus: String {
        selectionIsCurrent ? "当前设置" : "仅预览 · 尚未使用"
    }

    var previewExplanation: String {
        return "缩略图仅供选片；播放完整视频，使用所选服装与光照版本。"
    }

    var canReturnToCurrent: Bool { !selectionIsCurrent && candidates.contains { $0.isCurrent } }

    func returnToCurrent() {
        if let current = candidates.first(where: { $0.isCurrent }) { select(current) }
    }

    func updatePlaybackStatus(pending: String?, timePolicy: String) {
        if pendingSwitchMessage != pending { pendingSwitchMessage = pending }
        if timePolicySummary != timePolicy { timePolicySummary = timePolicy }
    }
    /// Technical detail is collapsed by default: raw identifiers are not ordinary names.
    @Published var showsTechnicalDetail = false
    /// Whether the chooser surface is presented AT ALL (window sheet or island page). It lives here
    /// so every entry point drives one browsing state; the WINDOW sheets bind to
    /// `isPresentedInWindow` instead, so an island presentation can never open them.
    @Published var isPresented = false
    /// WHERE it is presented. Set by the presenter, never persisted.
    @Published private(set) var destination: DailyBackgroundPresentation = .none

    /// True only while the ordinary WINDOW sheet owns the chooser. `UnifiedWindow` and `Settings`
    /// bind their `.sheet(isPresented:)` to this, so the island's own background page does not
    /// activate or switch to those surfaces (and their `onDisappear` cannot cancel an island
    /// presentation).
    var isPresentedInWindow: Bool {
        get { isPresented && destination == .window }
        set {
            if newValue {
                present(currentKey: nil, in: .window)
            } else if destination == .window {
                dismissed()
            }
        }
    }

    /// True only while the notch island's own background page owns the chooser.
    var isPresentedInIsland: Bool { isPresented && destination == .island }

    /// Provided by the owner (AppDelegate): the next usable daypart and the discovered keys are
    /// read from the SAME model state the rest of the daily surface uses.
    var timeProvider: () -> TimeOfDay = { .evening }
    var availableKeysProvider: () -> [ContentKey]? = { nil }
    /// The currently configured daily combination, so an invalidation rebuild can mark it.
    var currentKeyProvider: () -> ContentKey? = { nil }
    var timePolicyProvider: () -> String = { "" }
    var followsAutomaticTime: () -> Bool = { false }
    var pendingSwitchProvider: () -> String? = { nil }
    /// The backdrop side of the current daily preference. The Core `dailySourceKey` is
    /// deliberately nil while the time policy is automatic, so THIS chooser resolves its
    /// backdrop key from scene + outfit + the effective time (the same `resolvedTime` the daily
    /// picture follows). It never redefines Core's activity-source semantics.
    static func backdropKey(desired: DesiredState, at now: Date) -> ContentKey {
        ContentKey(scene: desired.scene, outfit: desired.outfit,
                   time: DailyActivityRecommendationModel.resolvedTime(desired: desired, now: now))
    }
    /// Owner path for one explicit whole-combination choice. Returns false when the ordinary
    /// guarded command refused the key, so no success is reported for a no-op.
    var onApply: (ContentKey) -> Bool = { _ in false }
    /// Starts one bounded Platform preview request at the pixel bounds the still is displayed at.
    /// The bounds are part of the request identity: a resize or a display-scale change re-requests
    /// instead of reusing an undersized still. The owner wires the authorized directory.
    var onRequestPreview: (ContentKey, DailyPreviewPixelSize,
                           @escaping (DailyBackgroundPreviewResult) -> Void) -> Void = { key, _, completion in
        completion(.unavailable(key, "预览服务不可用。"))
    }
    var onCancelPreview: () -> Void = {}

    /// Monotonic request identity. Only the newest request may install its result.
    private var generation = 0

    /// The rendered container the still is sized for, as last reported by the view, and the pixel
    /// bounds derived from it. Both are presentation geometry only: changing them can never apply
    /// content or send a playback command.
    private(set) var previewContainerSize: CGSize = .zero
    private(set) var previewDisplayScale: CGFloat = 0
    /// The pixel bounds of the request that is current. Nil until the view reports real geometry;
    /// the Platform's bounded default is used for that first request.
    private(set) var previewPixelSize: DailyPreviewPixelSize?

    /// The exact inputs the candidate list is built from. Comparing it is what makes an unrelated
    /// snapshot or progress push a no-op (see `syncState`).
    private struct PresentationSignature: Equatable {
        let backdropKey: ContentKey?
        let keys: [ContentKey]?
        let effectiveTime: TimeOfDay
    }
    private var lastPresentation: PresentationSignature?

    var selectedCandidate: DailyBackgroundCandidate? {
        candidates.indices.contains(selectedIndex) ? candidates[selectedIndex] : nil
    }

    var positionText: String {
        let families = visibleCandidates
        guard let index = families.firstIndex(where: { $0.key.scene == selectedCandidate?.key.scene }) else { return "无可用视频" }
        return "\(index + 1) / \(families.count)"
    }

    var canGoPrevious: Bool { visibleCandidates.count > 1 }
    var canGoNext: Bool { visibleCandidates.count > 1 }

    /// A successful selected preview admits apply. Loading, failed and hidden selections cannot
    /// reach the owner command, including a resize that still displays the previous-size picture.
    var canApplySelection: Bool {
        guard isPresented, let candidate = selectedCandidate else { return false }
        return (!candidate.isCurrent || followsAutomaticTime()) && !isPreviewing && previewImageData != nil && previewFailure == nil
    }

    var applyActionTitle: String {
        selectionIsCurrent && !followsAutomaticTime() ? "当前设置" : "播放此视频"
    }

    var canRetryPreview: Bool {
        selectedCandidate != nil && !isPreviewing && previewFailureKind != .unsupported
    }

    /// True when the chosen combination is already the daily preference.
    var selectionIsCurrent: Bool { selectedCandidate?.isCurrent == true }

    var emptyMessage: String? {
        candidates.isEmpty ? "没有已接入的陪伴视频。" : nil
    }

    /// Open the chooser on the current truth: rebuild candidates for the effective daypart and
    /// present at `destination` (the window sheet by default, the island page from the island).
    /// Presentation only — it never applies or switches anything. `currentKey` is an optional
    /// already-resolved overlay; the owner's `currentKeyProvider` is the ordinary path.
    func present(currentKey: ContentKey?, in destination: DailyBackgroundPresentation = .window) {
        cancelPreview()
        applyNotice = nil
        applyFailed = false
        previewPixelSize = nil
        self.destination = destination
        isPresented = true
        updatePlaybackStatus(pending: pendingSwitchProvider(), timePolicy: timePolicyProvider())
        refresh(currentKey: currentKey ?? currentKeyProvider())
    }

    /// Rebuild the admitted whole-video list. Called when the chooser is opened and
    /// whenever the underlying discovery changes while it is open. It preserves the position of a
    /// candidate that is still present and otherwise starts from the current one. It starts a
    /// preview request only while the surface is presented, so a background rebuild can never
    /// launch an extraction behind a closed chooser.
    func refresh(currentKey: ContentKey?, keys: [ContentKey]? = nil,
                 effectiveTime: TimeOfDay? = nil) {
        let keyList = keys ?? availableKeysProvider()
        let time = effectiveTime ?? timeProvider()
        let previous = selectedCandidate?.key
        clearThumbnails()
        let admitted = Set(keyList ?? [])
            .sorted { lhs, rhs in
                (lhs.scene.rawValue, lhs.outfit.rawValue, lhs.time.rawValue) < (rhs.scene.rawValue, rhs.outfit.rawValue, rhs.time.rawValue)
            }
        var ordered: [ContentKey] = []
        if let currentKey, admitted.contains(currentKey) { ordered.append(currentKey) }
        ordered.append(contentsOf: admitted.filter { $0 != currentKey })
        candidates = ordered.map { DailyBackgroundCandidate(key: $0, isCurrent: $0 == currentKey) }
        if let previous, let index = candidates.firstIndex(where: { $0.key == previous }) {
            selectedIndex = index
        } else {
            selectedIndex = 0
        }
        if isPresented {
            if thumbnailDestination == destination { visibleThumbnailKeys = visibleCandidates.map(\.key) }
            requestPreviewForSelection()
        } else {
            generation += 1
            isPreviewing = false
            previewImageData = nil
            previewFailure = nil
            previewFailureKind = nil
            onCancelPreview()
        }
        // Every rebuild re-baselines change detection, so the next owner push is compared against
        // exactly the inputs that produced this candidate list.
        lastPresentation = PresentationSignature(
            backdropKey: currentKey, keys: keyList, effectiveTime: time)
    }

    /// Change-detected update for an already-built state. The owner pushes snapshots/progress
    /// continuously; only the three inputs this chooser actually shows can rebuild it — the
    /// resolved backdrop key, the discovered key list and the effective daypart. An unchanged
    /// push is a no-op, so a progress report can never re-request the same still. While the
    /// surface is closed nothing is recomputed, so no extraction can start behind it.
    func syncState(desired: DesiredState, keys: [ContentKey]?, effectiveTime: TimeOfDay, at now: Date) {
        guard isPresented else { return }
        let signature = PresentationSignature(
            backdropKey: Self.backdropKey(desired: desired, at: now),
            keys: keys, effectiveTime: effectiveTime)
        guard signature != lastPresentation else { return }
        refresh(currentKey: signature.backdropKey, keys: keys, effectiveTime: effectiveTime)
    }

    /// The surface was dismissed. Any in-flight request is cancelled and the change-detection
    /// baseline is dropped, so the next presentation always rebuilds from current truth instead
    /// of firing a redundant second request for the snapshot it already showed.
    func dismissed() {
        isPresented = false
        destination = .none
        lastPresentation = nil
        cancelPreview()
    }

    /// The accepted daily root was invalidated, failed, rebound or replaced. Everything this
    /// chooser displays belongs to the previous authorization, so the displayed still is dropped
    /// and the candidate list is rebuilt from the current discovered keys. While the surface is
    /// closed that rebuild starts no extraction; while it is open the rebuilt selection asks the
    /// owner for a fresh, re-authorized preview.
    func rootInvalidated() {
        let renderedDestination = thumbnailDestination
        cancelPreview()
        thumbnailDestination = renderedDestination
        applyNotice = nil
        applyFailed = false
        refresh(currentKey: currentKeyProvider())
    }

    /// Main navigation moves between source families. Exact versions stay in the variant menu;
    /// revisiting a family restores its last browsed variant without applying it.
    func selectPrevious() { step(-1) }
    func selectNext() { step(1) }

    private func step(_ offset: Int) {
        let families = visibleCandidates
        guard families.count > 1,
              let index = families.firstIndex(where: { $0.key.scene == selectedCandidate?.key.scene }) else { return }
        if let selected = selectedCandidate { selectedFamilyKeys[selected.key.scene] = selected.key }
        select(families[(index + offset + families.count) % families.count])
    }

    func select(_ candidate: DailyBackgroundCandidate) {
        guard let index = candidates.firstIndex(where: { $0.key == candidate.key }), index != selectedIndex else { return }
        selectedIndex = index
        selectedFamilyKeys[candidate.key.scene] = candidate.key
        if thumbnailDestination == destination {
            visibleThumbnailKeys = visibleCandidates.map(\.key)
            thumbnailResults = thumbnailResults.filter { visibleThumbnailKeys.contains($0.key) }
        }
        applyNotice = nil
        applyFailed = false
        requestPreviewForSelection()
    }

    /// Explicit apply acknowledges the preference only. Runtime switch status remains separate;
    /// rejection stays visible and retryable without changing the current-setting marker.
    @discardableResult
    func applySelection() -> Bool {
        guard canApplySelection, let candidate = selectedCandidate else { return false }
        guard onApply(candidate.key) else {
            applyFailed = true
            applyNotice = "未能播放此视频，请检查素材状态后重试。"
            return false
        }
        applyFailed = false
        applyNotice = "已选择陪伴视频，实际切换以播放状态为准。"
        // The applied key is now the current one; keep browsing state consistent without
        // re-requesting the same preview.
        candidates = candidates.map {
            DailyBackgroundCandidate(key: $0.key, isCurrent: $0.key == candidate.key)
        }
        return true
    }

    /// The presented view reports its ACTUAL rendered container size in points and the display's
    /// backing scale. That geometry alone decides the request's pixel bounds. A pure size/scale
    /// change re-requests the still for the new bounds (its identity includes them) and changes
    /// nothing else: it never rebuilds candidates, never applies a combination and never sends a
    /// playback command. An unchanged report is inert, so ordinary relayout cannot cause churn.
    func updatePreviewMetrics(size: CGSize, scale: CGFloat) {
        previewContainerSize = size
        previewDisplayScale = scale
        let requested = DailyPreviewPixelSize.forRenderedContainer(size: size, scale: scale)
        guard requested != previewPixelSize else { return }
        previewPixelSize = requested
        guard isPresented, selectedCandidate != nil else { return }
        // Keep the still that is already on screen while the correctly sized one is produced.
        requestPreviewForSelection(clearingDisplayed: false)
    }

    /// Bounded, single-request preview for the current selection.
    ///
    /// - Parameter clearingDisplayed: true for a selection change (the previous still belongs to
    ///   another candidate, so it must not linger); false for a pure geometry re-request, where the
    ///   existing still stays visible until the correctly sized replacement arrives.
    private func requestPreviewForSelection(clearingDisplayed: Bool = true) {
        generation += 1
        let token = generation
        if clearingDisplayed {
            previewImageData = nil
            previewFailure = nil
            previewFailureKind = nil
        }
        activeThumbnail = nil
        onCancelPreview()
        guard isPresented, let candidate = selectedCandidate else {
            isPreviewing = false
            previewImageData = nil
            previewFailure = nil
            previewFailureKind = nil
            return
        }
        let pixelSize = previewPixelSize ?? DailyPreview.defaultPreviewPixelSize
        isPreviewing = true
        onRequestPreview(candidate.key, pixelSize) { [weak self] outcome in
            guard let self, self.isPresented, token == self.generation,
                  outcome.key == candidate.key, self.selectedCandidate?.key == candidate.key else { return }
            self.isPreviewing = false
            self.previewImageData = outcome.data
            self.previewFailure = outcome.data == nil
                ? (outcome.failure ?? "这段画面暂时无法生成预览。")
                : nil
            self.previewFailureKind = outcome.failureKind
            self.requestNextThumbnail()
        }
    }

    func retryPreview() {
        guard isPresented, canRetryPreview else { return }
        requestPreviewForSelection()
    }

    /// The view supplies only the currently rendered slots and their real pixel demand.
    func updateVisibleThumbnails(keys: [ContentKey], size: CGSize, scale: CGFloat,
                                 in destination: DailyBackgroundPresentation) {
        guard isPresented, self.destination == destination else { return }
        thumbnailDestination = destination
        let admitted = Array(keys.filter { key in candidates.contains { $0.key == key } }
            .prefix(Self.maximumVisibleThumbnails))
        let pixelSize = DailyPreviewPixelSize.forRenderedContainer(size: size, scale: scale)
        if pixelSize != thumbnailPixelSize {
            clearThumbnails()
            thumbnailPixelSize = pixelSize
        }
        visibleThumbnailKeys = admitted
        thumbnailResults = thumbnailResults.filter { admitted.contains($0.key) }
        if let activeThumbnail, !admitted.contains(activeThumbnail) {
            generation += 1
            self.activeThumbnail = nil
            onCancelPreview()
        }
        requestNextThumbnail()
    }

    private func clearThumbnails() {
        if activeThumbnail != nil {
            generation += 1
            onCancelPreview()
        }
        activeThumbnail = nil
        visibleThumbnailKeys = []
        thumbnailResults = [:]
    }

    /// One service request at a time. Selected preview completion opens the thumbnail queue;
    /// a new selection cancels it immediately. Install the active identity before invoking the
    /// seam because authorization failures and regression completions can be synchronous.
    private func requestNextThumbnail() {
        guard isPresented, !isPreviewing, activeThumbnail == nil,
              let key = visibleThumbnailKeys.first(where: {
                  $0 != selectedCandidate?.key && thumbnailResults[$0] == nil
              }) else { return }
        generation += 1
        let token = generation
        activeThumbnail = key
        onRequestPreview(key, thumbnailPixelSize) { [weak self] outcome in
            guard let self, self.isPresented, token == self.generation,
                  self.activeThumbnail == key, outcome.key == key,
                  self.visibleThumbnailKeys.contains(key) else { return }
            self.activeThumbnail = nil
            if let data = outcome.data,
               data.count + self.thumbnailByteCount > Self.maximumThumbnailBytes {
                self.thumbnailResults[key] = .unavailable(key, "请点选查看大图。")
            } else {
                self.thumbnailResults[key] = outcome
            }
            self.requestNextThumbnail()
        }
    }

    /// Stop any in-flight request and drop the displayed still, without touching the selection.
    /// Used when the chooser closes: the surface holds no still of its own between presentations.
    func cancelPreview() {
        thumbnailDestination = nil
        clearThumbnails()
        generation += 1
        isPreviewing = false
        previewImageData = nil
        previewFailure = nil
        previewFailureKind = nil
        onCancelPreview()
    }
}

/// A shared still surface keeps empty, loading and retry behavior identical in both presenters.
struct DailyBackgroundPreview: View {
    @ObservedObject var model: DailyBackgroundChooserModel
    @Environment(\.displayScale) private var displayScale
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(.primary.opacity(0.06))
                if let empty = model.emptyMessage {
                    Label(empty, systemImage: "photo.on.rectangle")
                        .font(.callout).foregroundStyle(.secondary).padding(16)
                        .accessibilityIdentifier("daily-background-empty")
                } else if let data = model.previewImageData, let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .accessibilityLabel("所选视频缩略图")
                } else if let failure = model.previewFailure {
                    VStack(spacing: 6) {
                        Label(model.previewFailureKind == .unsupported ? "此素材暂不支持" : "预览不可用",
                              systemImage: "photo.badge.exclamationmark")
                        Text(failure).font(.caption).multilineTextAlignment(.center)
                        if model.canRetryPreview {
                            Button("重试预览") { model.retryPreview() }
                                .accessibilityIdentifier("daily-background-retry")
                        }
                    }
                    .foregroundStyle(.secondary).padding(12)
                    .accessibilityIdentifier("daily-background-preview-unavailable")
                } else if model.isPreviewing {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { model.updatePreviewMetrics(size: proxy.size, scale: displayScale) }
            .onChange(of: proxy.size) { _ in model.updatePreviewMetrics(size: proxy.size, scale: displayScale) }
            .onChange(of: displayScale) { _ in model.updatePreviewMetrics(size: proxy.size, scale: displayScale) }
        }
    }
}

/// Compact family thumbnails; each image still belongs to one exact full-video key.
struct DailyBackgroundThumbnails: View {
    @ObservedObject var model: DailyBackgroundChooserModel
    let destination: DailyBackgroundPresentation
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { proxy in
            let visible = model.visibleCandidates
            let width = max(1, (proxy.size.width - CGFloat(max(0, visible.count - 1)) * 6) / CGFloat(max(1, visible.count)))
            HStack(spacing: 6) {
                ForEach(visible) { candidate in
                    let selected = candidate.key == model.selectedCandidate?.key
                    let data = selected ? model.previewImageData : model.thumbnailResults[candidate.key]?.data
                    let failure = selected ? model.previewFailure : model.thumbnailResults[candidate.key]?.failure
                    let unsupported = selected ? model.previewFailureKind == .unsupported
                        : model.thumbnailResults[candidate.key]?.failureKind == .unsupported
                    Button { model.select(candidate) } label: {
                        VStack(spacing: 3) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 5).fill(.primary.opacity(0.07))
                                if let data, let image = NSImage(data: data) {
                                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                                        .clipShape(RoundedRectangle(cornerRadius: 5))
                                } else if failure != nil {
                                    VStack(spacing: 2) {
                                        Image(systemName: "exclamationmark.triangle")
                                        Text(unsupported ? "不支持" : "不可用")
                                    }
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                                    .accessibilityIdentifier("daily-background-thumbnail-unavailable-\(candidate.id)")
                                } else {
                                    Image(systemName: "photo").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .frame(height: 43)
                            .overlay(RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
                            HStack(spacing: 3) {
                                Text(candidate.familyTitle)
                                if candidate.isCurrent { Image(systemName: "checkmark.circle.fill") }
                            }
                            .font(.caption2).foregroundStyle(selected ? .primary : .secondary)
                        }
                        .frame(width: width)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(candidate.title + (candidate.isCurrent ? "，当前设置" : "") + (selected ? "，已选中预览" : "") + (failure != nil ? "，预览不可用" : ""))
                    .accessibilityIdentifier("daily-background-thumbnail-\(candidate.id)")
                }
            }
            .onAppear { report(width: width) }
            .onChange(of: visible.map(\.key)) { _ in report(width: width) }
            .onChange(of: proxy.size) { _ in report(width: width) }
            .onChange(of: displayScale) { _ in report(width: width) }
        }
        .frame(height: model.candidates.isEmpty ? 0 : 62)
    }

    private func report(width: CGFloat) {
        model.updateVisibleThumbnails(keys: model.visibleCandidates.map(\.key),
            size: CGSize(width: width, height: 43), scale: displayScale, in: destination)
    }
}

struct DailyBackgroundChooser: View {
    @ObservedObject var model: DailyBackgroundChooserModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("选择陪伴视频").font(FrontendAppearance.titleFont)
                DailyVideoVariantMenu(model: model)
                Spacer()
                Button("完成") { model.dismissed() }.keyboardShortcut(.cancelAction)
            }
            DailyBackgroundPreview(model: model).frame(height: 290)
            DailyBackgroundThumbnails(model: model, destination: .window)
            HStack(spacing: 12) {
                Button { model.selectPrevious() } label: { Image(systemName: "chevron.left") }
                    .disabled(!model.canGoPrevious).help("上一原片")
                    .accessibilityIdentifier("daily-background-previous")
                Text(model.positionText).monospacedDigit().font(.caption)
                    .accessibilityIdentifier("daily-background-position")
                Button { model.selectNext() } label: { Image(systemName: "chevron.right") }
                    .disabled(!model.canGoNext).help("下一原片")
                    .accessibilityIdentifier("daily-background-next")
                Text(model.selectionStatus).font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if model.canReturnToCurrent {
                    Button("回到当前") { model.returnToCurrent() }.font(.caption)
                        .accessibilityIdentifier("daily-background-current")
                }
                Button(model.applyActionTitle) { model.applySelection() }
                    .buttonStyle(.borderedProminent).disabled(!model.canApplySelection)
                    .accessibilityIdentifier("daily-background-apply")
            }
            VStack(alignment: .leading, spacing: 3) {
                if let notice = model.applyNotice {
                    Text(notice).foregroundStyle(model.applyFailed ? Color.red : Color.secondary)
                        .accessibilityIdentifier("daily-background-apply-status")
                }
                if let pending = model.pendingSwitchMessage { Text(pending).foregroundStyle(.secondary) }
                Text(model.previewExplanation).foregroundStyle(.secondary)
            }
            .font(.caption).fixedSize(horizontal: false, vertical: true)
            DisclosureGroup(isExpanded: $model.showsTechnicalDetail) {
                Text(model.selectedCandidate?.technicalDetail ?? "无")
                    .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
            } label: { Text("文件信息").font(.caption).foregroundStyle(.secondary) }
        }
        .padding(20)
        .frame(width: 640)
        .background(FrontendAppearance.surface)
        .tint(FrontendAppearance.actionTint(for: colorScheme))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("daily-background-chooser")
        .onDisappear { if model.isPresentedInWindow { model.dismissed() } }
    }
}

/// Versions are expanded on demand on both the home sheet and the compact notch page.
struct DailyVideoVariantMenu: View {
    @ObservedObject var model: DailyBackgroundChooserModel
    var body: some View {
        Menu {
            ForEach(model.selectedFamilyVariants) { candidate in
                Button {
                    model.select(candidate)
                } label: {
                    if candidate.key == model.selectedCandidate?.key {
                        Label(candidate.title, systemImage: "checkmark")
                    } else {
                        Text(candidate.title)
                    }
                }
            }
        } label: {
            Text(model.selectedCandidate?.title ?? "服装与光照版本")
        }
        .accessibilityLabel("服装与光照版本")
        .accessibilityIdentifier("daily-video-variants")
        .fixedSize()
    }
}
