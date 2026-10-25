// BSideControlApp — daily companion activity recommendations (bounded reviewed inventory).
// Browsing remains presentation-only. Whole-source choices use ordinary preferences;
// reviewed activity entry sends a transient IPC request without adding persisted activity state.

import SwiftUI
import Foundation
import BSideCore
import BSidePlatform

/// One browsing tab for the reviewed activity inventory. The tab is presentation-only: it selects
/// which qualified source the entry buttons resolve to, and never applies or switches media.
/// Its cases are exactly the three official whole-source time labels.
enum DailyActivityTimeTab: String, CaseIterable, Identifiable {
    case noon
    case evening
    case night

    var id: String { rawValue }

    /// The exact `TimeOfDay` this tab browses, via an explicit case switch. It must never go
    /// through `rawValue`: the tab tags ("noon"/"evening"/"night") are NOT `TimeOfDay` raw values
    /// (those are the official filename labels "1200"/"1730"/"2000"), so a raw-value lookup would
    /// fail and any fallback would silently collapse every tab onto one time.
    var time: TimeOfDay {
        switch self {
        case .noon: return .noon
        case .evening: return .evening
        case .night: return .night
        }
    }

    var title: String { time.controlCenterLabel }
}

/// The two reviewed entry activities. Each entry is bound to the source it was reviewed in, so
/// `reading` is deliberately absent: no reading activity was reviewed.
enum DailyActivityEntryChoice: String, CaseIterable, Identifiable {
    case desk
    case rest

    var id: String { rawValue }
    var activityID: DailyActivityID { self == .desk ? .desk : .rest }

    var title: String {
        switch self {
        case .desk: return "书桌日常"
        case .rest: return "沙发休息"
        }
    }

    /// Ordinary two-character shortcut word for the compact action row.
    var shortTitle: String {
        switch self {
        case .desk: return "书桌"
        case .rest: return "沙发"
        }
    }
}

/// One reviewed whole-source unit offered as a material choice. `target` is the exact
/// (scene, outfit, time) combination the reviewed entries belong to; applying it uses the ordinary
/// whole-combination command. Nothing user-facing names the internal resource ids (ADR-024): the
/// daypart is the ordinary word, and the raw key stays available for the troubleshooting detail.
struct DailyActivityRecommendation: Equatable {
    let target: ContentKey

    /// Ordinary product word for this combination: its daypart.
    var timeLabel: String { target.time.controlCenterLabel }
}

/// Presentation-only view of the reviewed inventory. The four whole-source units and the exact
/// supported time set per source come from `DailyActivityCatalog`; nothing here invents a source,
/// a time or a fallback. A source inside the current material group whose browsed time it does not
/// support is rendered as unavailable rather than silently redirected.
enum DailyActivityRecommendationCatalog {
    /// One card per reviewed source, in the catalog's deterministic order. Cards are whole-source
    /// choices: they are never described as desk-only playback.
    static let recommendations: [DailyActivityRecommendation] = {
        var seen = Set<ContentKey>()
        var result: [DailyActivityRecommendation] = []
        for entry in DailyActivityCatalog.entries where seen.insert(entry.sourceKey).inserted {
            result.append(DailyActivityRecommendation(target: entry.sourceKey))
        }
        return result
    }()

    static func recommendation(for target: ContentKey) -> DailyActivityRecommendation? {
        recommendations.first { $0.target == target }
    }

    /// True when this exact whole source has at least one reviewed entry.
    static func isQualified(_ target: ContentKey) -> Bool {
        DailyActivityCatalog.hasAnyEntry(for: target)
    }

    /// The times of day this outfit has reviewed entries for inside material group A, in the
    /// fixed official order. Empty means the outfit has no reviewed entry at all.
    static func qualifiedTimes(for outfit: Outfit) -> [TimeOfDay] {
        TimeOfDay.allCases.filter {
            DailyActivityCatalog.hasAnyEntry(
                for: ContentKey(scene: .a, outfit: outfit, time: $0))
        }
    }
}

/// Projection for the companion window. It holds only existing model state: desired state,
/// current-run daily discovery, resource/service readiness and whether a performance or queue
/// is active. The explicit actions forward the resolved reviewed key to the existing guarded paths.
final class DailyActivityRecommendationModel: ObservableObject {
    /// The browsed time tab. `prepareForPresentation` seeds it from the actual resolved desired
    /// time; browsing it afterwards is presentation-only and changes no preference or media.
    @Published var timeTab: DailyActivityTimeTab = .evening
    @Published var entryChoice: DailyActivityEntryChoice = .desk
    @Published private(set) var desired = DesiredState()
    @Published private(set) var resourceReady = false
    @Published private(set) var dailyContentKeys: [ContentKey]?
    @Published private(set) var performanceActive = false
    @Published private(set) var pendingSwitchMessage: String?

    // Whole-source apply is keyed to the card that was actually applied, so browsing another card
    // never relabels an outstanding status.
    @Published private(set) var lastAppliedTarget: ContentKey?

    // Explicit activity entry is transient current-session state: it is never added to DesiredState,
    // never persisted and never replayed after Agent loss. `activitySourceKey` is the ACTUAL source
    // key the last request carried, so the status line never borrows the browsed tab's label.
    @Published private(set) var activityID: DailyActivityID?
    @Published private(set) var activityRequestID: String?
    @Published private(set) var activityState: DailyActivityRequestState?
    @Published private(set) var activityDetail: String?
    @Published private(set) var activitySourceKey: ContentKey?

    /// The owner applies the reviewed key through the ordinary daily selection path. It returns
    /// false when that guarded command refused the key, so no status is shown for a no-op.
    var onApply: (ContentKey) -> Bool = { _ in false }

    /// The owner sends the one explicit entry request to the running Agent. It returns false when
    /// no running Agent accepted it; the model then reports that truthfully instead of "pending".
    var onStartActivity: (DailyActivityRequest) -> Bool = { _ in false }

    func update(desired: DesiredState, resourceReady: Bool, dailyContentKeys: [ContentKey]?,
                performanceActive: Bool, pendingSwitchMessage: String?) {
        let previousSource = self.desired.dailySourceKey
        self.desired = desired
        // A source change abandons the outstanding/previous entry: its status and request belong to
        // the old source. The actual requested key is compared (never a fixed library combination),
        // and a browsing tab change alone does not reach here. Our OWN entry request is the one
        // exception: the real AppDelegate applies the request's desired state synchronously through
        // this same update, so the new desired source equals `activitySourceKey`. That self-refresh
        // must keep the request (and its later Agent report) instead of being mistaken for an
        // unrelated source change.
        if previousSource != desired.dailySourceKey, desired.dailySourceKey != activitySourceKey {
            activityRequestID = nil
            activityID = nil
            activityState = nil
            activityDetail = nil
            activitySourceKey = nil
        }
        // The whole-source applied status belongs to its exact source, so it becomes obsolete as
        // soon as the desired source moves elsewhere.
        if let applied = lastAppliedTarget, applied != desired.dailySourceKey {
            lastAppliedTarget = nil
        }
        self.resourceReady = resourceReady
        self.dailyContentKeys = dailyContentKeys
        self.performanceActive = performanceActive
        self.pendingSwitchMessage = pendingSwitchMessage
    }

    /// Presentation-time default, called once on each explicit window opening. It resolves the
    /// CURRENT desired time (Beijing clock for automatic, the saved fixed choice otherwise) and
    /// opens the matching tab. It uses the existing time resolution, adds no timer/polling, and —
    /// like any other browsing edit — never applies or switches media.
    func prepareForPresentation(now: Date = Date()) {
        timeTab = Self.tab(for: Self.resolvedTime(desired: desired, now: now))
    }

    /// The existing desired-time resolution, reused rather than duplicated.
    static func resolvedTime(desired: DesiredState, now: Date) -> TimeOfDay {
        switch desired.timeMode {
        case .fixed(let time): return time
        case .auto: return TimeOfDay.autoBucket(minuteOfDay: BeijingClock.minuteOfDay(at: now))
        }
    }

    /// The exact inverse of `DailyActivityTimeTab.time`: an explicit case switch, no raw-value
    /// lookup and no fallback, so every `TimeOfDay` maps to its own tab and the round trip is
    /// identity in both directions.
    static func tab(for time: TimeOfDay) -> DailyActivityTimeTab {
        switch time {
        case .noon: return .noon
        case .evening: return .evening
        case .night: return .night
        }
    }

    // MARK: - Whole-source cards

    var recommendations: [DailyActivityRecommendation] {
        DailyActivityRecommendationCatalog.recommendations
    }

    /// The card matching the last explicit apply, never the browsed tab.
    var appliedRecommendation: DailyActivityRecommendation? {
        lastAppliedTarget.flatMap { DailyActivityRecommendationCatalog.recommendation(for: $0) }
    }

    private func targetDiscovered(_ key: ContentKey) -> Bool {
        guard let keys = dailyContentKeys else { return false }
        return keys.contains(key)
    }

    /// A whole-source card never changes the manually selected daily version: applying the
    /// ordinary command would rewrite outfit, so a card whose target outfit differs from the
    /// current desired outfit is offered but refused until the owner switches version through the
    /// ordinary picker. Otherwise ready to apply only when the reviewed combination is actually
    /// discovered and no performance/listening/queue would make the daily setting misleading.
    /// Pause is intent the ordinary command preserves, not a blocker.
    func canApply(_ target: ContentKey) -> Bool {
        target.outfit == desired.outfit
            && DailyActivityRecommendationCatalog.isQualified(target) && resourceReady
            && !performanceActive && targetDiscovered(target)
    }

    /// Why the explicit whole-source action is unavailable, in the same order as the blocking guard.
    func applyUnavailableReason(for target: ContentKey) -> String? {
        if target.outfit != desired.outfit {
            return "当前画面版本不同；也可直接在“更换背景”中切换画面。"
        }
        if !resourceReady { return "日常资源或播放器服务尚未就绪，暂时不能应用。" }
        if performanceActive { return "演奏或队列正在使用播放器；请先停止或等待结束后再试。" }
        if dailyContentKeys == nil { return "正在确认日常素材。" }
        if !targetDiscovered(target) { return "当前素材目录缺少这段日常。" }
        return nil
    }

    /// Honest one-line explanation that a background choice is a whole-combination preference
    /// change under the existing switching policy, not an immediate-play claim.
    var backgroundChoiceNotice: String? {
        guard lastAppliedTarget != nil else { return nil }
        var text = "已选择新背景，本段结束后切换。"
        if desired.paused { text = "已选择新背景；当前全局暂停，恢复后生效。" }
        if let pending = pendingSwitchMessage, !pending.isEmpty { text += pending }
        return text
    }

    /// Empty-state explanation for outfits without reviewed evidence. It never offers an
    /// automatic outfit change: the existing manual selection remains the only path. Internal
    /// version ids are never ordinary product words (ADR-024).
    var noRecommendationMessage: String? {
        DailyActivityRecommendationCatalog.qualifiedTimes(for: desired.outfit).isEmpty
            ? "当前画面暂无可进入的活动，也不会自动更换背景。"
            : nil
    }

    /// Reports the requested setting plus existing pending-switch/paused state. It never claims
    /// that playback started, because this action only issues the ordinary preference change.
    var appliedStatus: String? {
        guard let target = lastAppliedTarget else { return nil }
        var parts = ["已请求切换背景：\(target.daypartLabel)"]
        if let pending = pendingSwitchMessage, !pending.isEmpty { parts.append(pending) }
        if desired.paused { parts.append("当前全局暂停，恢复后按原策略生效") }
        return parts.joined(separator: "；") + "。"
    }

    @discardableResult
    func applyRecommendation(_ target: ContentKey) -> Bool {
        guard canApply(target) else { return false }
        guard onApply(target) else { return false }
        lastAppliedTarget = target
        return true
    }

    // MARK: - Explicit activity entry

    /// The whole source the entry buttons currently resolve to: material group A, the CURRENT
    /// manually selected daily version, and the BROWSED time. No fallback: an unqualified
    /// combination resolves to nil and is presented as unavailable.
    var entrySourceKey: ContentKey? {
        let key = ContentKey(scene: .a, outfit: desired.outfit, time: timeTab.time)
        return DailyActivityCatalog.hasAnyEntry(for: key) ? key : nil
    }

    /// The times of day the current manual daily version can actually enter.
    var entryQualifiedTimes: [TimeOfDay] {
        DailyActivityRecommendationCatalog.qualifiedTimes(for: desired.outfit)
    }

    /// Browsing is presentation-only, so every time tab is ALWAYS browseable for every manual
    /// version: R2 daytime/night and R3 can be inspected without applying or switching anything.
    /// A version/time without a reviewed entry is reported unavailable at the entry/apply action
    /// instead of being silently redirected, and never disabled as a tab.
    func entryTimeIsEnabled(_ tab: DailyActivityTimeTab) -> Bool {
        _ = tab
        return true
    }

    var canEnterActivity: Bool {
        entrySourceKey != nil && resourceReady && !performanceActive
            && entrySourceDiscovered
    }

    private var entrySourceDiscovered: Bool {
        guard let key = entrySourceKey else { return false }
        return targetDiscovered(key)
    }

    /// Plain reason in the same order as the blocking guard. A picture without any reviewed entry
    /// says so in ordinary words; a picture with entries but not at the browsed daypart names the
    /// daypart, and neither path falls back to another source or exposes an internal id.
    var entryUnavailableReason: String? {
        guard let key = entrySourceKey else {
            let supported = entryQualifiedTimes.map(\.controlCenterLabel)
            if supported.isEmpty {
                return "当前画面暂无可进入的活动，也不会自动更换背景。"
            }
            return "当前画面在\(timeTab.title)没有可进入的活动，也不会自动切换到其他时段。"
                + "可用时段：\(supported.joined(separator: "、"))。"
        }
        if !resourceReady { return "日常资源或播放器服务尚未就绪，暂时不能进入。" }
        if performanceActive { return "演奏或队列正在使用播放器；请先停止或等待结束后再试。" }
        if dailyContentKeys == nil { return "正在确认日常素材。" }
        if !targetDiscovered(key) { return "当前素材目录缺少\(key.time.controlCenterLabel)的日常画面。" }
        return nil
    }

    /// One explicit click = one new requestID; the same activity re-click starts the entry again.
    /// The carried desired state fixes the resolved source's scene/time while preserving the
    /// manual daily version, pause, volumes and profile.
    @discardableResult
    func startActivity(_ activity: DailyActivityID) -> Bool {
        guard let key = entrySourceKey, canEnterActivity,
              DailyActivityCatalog.entry(for: key, activityID: activity) != nil else {
            activityID = activity
            activityState = .failed
            activityDetail = entryUnavailableReason
            return false
        }
        var next = desired
        next.scene = key.scene
        next.timeMode = .fixed(key.time)
        // next.outfit deliberately keeps the manual selection.
        let request = DailyActivityRequest(requestID: UUID().uuidString, activityID: activity, desired: next)
        activityID = activity
        activityRequestID = request.requestID
        activitySourceKey = key
        activityState = .verifying
        activityDetail = nil
        guard onStartActivity(request) else {
            activityState = .failed
            activityDetail = "播放器服务未运行，未能发送进入请求。"
            return false
        }
        return true
    }

    /// Agent report for the current entry. A report for an older request is ignored.
    func receiveActivityReport(_ report: DailyActivityReport) {
        guard report.requestID == activityRequestID, activityState != report.state else { return }
        activityState = report.state
        activityDetail = report.detail
    }

    /// Agent loss clears the transient request; it is never replayed on the next process.
    func agentLost() {
        guard activityRequestID != nil, activityState != .cancelled else { return }
        activityState = .cancelled
        activityDetail = "播放器服务已断开；进入请求已取消。"
    }

    /// Truthful status line. A pending/verified request is never described as successful playback,
    /// and the daypart named is the one the request actually carried. It names no internal id.
    var activityStatus: String? {
        guard let activityID, let activityState, let sourceKey = activitySourceKey else { return nil }
        let label = DailyActivityEntryChoice.allCases.first { $0.activityID == activityID }?.title
            ?? activityID.rawValue
        let target = sourceKey.time.controlCenterLabel
        switch activityState {
        case .verifying:
            return "正在准备进入\(target)的\(label)…"
        case .applied:
            var text = "已选择\(target)的\(label)；后续按原片顺序播放"
            if desired.paused { text += "；当前暂停" }
            return text + "。"
        case .failed:
            return "进入\(target)的\(label)失败" + (activityDetail.map { "：\($0)" } ?? "。")
        case .cancelled:
            return "进入\(target)的\(label)已取消" + (activityDetail.map { "：\($0)" } ?? "。")
        }
    }
}

/// Native modest-size companion window content. Recommendation content lives here instead of
/// the small Control Center popover.
struct DailyActivityRecommendationView: View {
    @ObservedObject var model: DailyActivityRecommendationModel
    /// True when the view is a page of the unified candidate window (ADR-021): that page
    /// already scrolls and shows its own heading, so the view drops its fixed 440x640 frame
    /// and duplicate title. The standalone companion-window path is unchanged.
    var embedded: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !embedded { Text("日常活动").font(FrontendAppearance.titleFont) }
                timePicker
                Divider()
                entrySection
                Spacer(minLength: 0)
            }
            .padding(embedded ? 0 : 20)
        }
        .frame(width: embedded ? nil : 440, height: embedded ? nil : 640, alignment: .topLeading)
        .background(FrontendAppearance.surface)
        .tint(FrontendAppearance.actionTint(for: colorScheme))
    }

    private var timePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            DailySegmentedPicker(label: "活动时段", selection: $model.timeTab,
                options: DailyActivityTimeTab.allCases.map {
                    .init(value: $0, title: $0.title, isEnabled: model.entryTimeIsEnabled($0))
                }, accessibilityIdentifier: "daily-activity-intent")
            .frame(height: 24)
        }
    }

    /// Actual entry into a reviewed activity. The actions are the two reviewed entry points only
    /// (去书桌 / 去沙发). No source footage is relabeled as an activity, and the abolished
    /// per-source material cards now live in the background chooser (ADR-024).
    private var entrySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("活动").font(.headline)
            if model.entryUnavailableReason == nil {
                Text(entryTargetDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                ForEach(DailyActivityEntryChoice.allCases) { entry in
                    Button("去\(entry.shortTitle)") {
                        model.entryChoice = entry
                        model.startActivity(entry.activityID)
                    }
                    .disabled(!model.canEnterActivity)
                    .accessibilityIdentifier("daily-activity-enter-\(entry.rawValue)")
                }
            }
            if let reason = model.entryUnavailableReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("daily-activity-entry-unavailable")
            }
            if let status = model.activityStatus {
                Text(status)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("daily-activity-entry-status")
            }
        }
    }

    private var entryTargetDescription: String {
        guard let key = model.entrySourceKey else {
            // A picture with no reviewed entry at all states the honest fact instead of an empty
            // supported-times list, and never names an internal id.
            let supported = model.entryQualifiedTimes.map(\.controlCenterLabel)
            if supported.isEmpty {
                return "当前画面暂无可进入的活动。"
            }
            return "当前时段不可用，可选择：\(supported.joined(separator: "、"))。"
        }
        return "将进入：\(key.time.controlCenterLabel)的日常画面"
    }
}
