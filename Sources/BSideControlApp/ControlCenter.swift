// BSideControlApp — Control Center model + view (SwiftUI in the status-item popover).
// Pure projection: reads model state, produces Commands through callbacks. No players here.

import SwiftUI
import BSideCore
import BSidePlatform

enum ControlCenterRequest {
    case performanceLibrary, dailyActivity, settings, chooseResource, retryResource, help, diagnostics, about, commandBar, restartAgent, retrySave, quit
}

/// ResourceStage → semantic health input. Non-ready stages collapse to one "preparing" state:
/// the pure projection only needs to know failed/ready/not-yet (user language: preparing).
extension ResourceStage {
    var healthReadiness: HealthProjection.Readiness {
        switch self {
        case .unconfigured: return .unconfigured
        case .selecting, .validating, .loading, .startingPlayback: return .preparing
        case .ready: return .ready
        case .failed: return .failed
        }
    }
}

final class ControlCenterModel: ObservableObject {
    @Published var desired = DesiredState()
    @Published var stage: ResourceStage = .unconfigured
    @Published var stageDetail = ""
    @Published var snapshot: RuntimeSnapshot?
    @Published var preferencesSaveStatus: PreferencesSaveStatus = .unchanged
    @Published var resourceConfigured = false
    @Published var dailyCatalogSelectionFailed = false
    @Published var dailyAssetIssue: DailyAssetIssue?
    @Published var canRetryDailyResource = false

    func preferencesDidChange() {
        if preferencesSaveStatus != .failed { preferencesSaveStatus = .pending }
    }

    func preferencesSaveCompleted(succeeded: Bool) {
        preferencesSaveStatus = succeeded ? .saved : .failed
    }
    /// Precise supervisor phase (Core) — the health projection distinguishes starting/stopping/
    /// backoff (recovering) from degraded (service problem).
    @Published var supervision: AgentLifecycle.Phase = .idle

    var onDesiredChange: (DesiredState) -> Void = { _ in }
    /// The owner persists/sends its latest state after a burst of control edits.
    var onDesiredSettled: () -> Void = {}
    var onRequest: (ControlCenterRequest) -> Void = { _ in }

    var dailyVisualPauseIsRestricted: Bool {
        desired.paused || desired.profile.visualPaused || (snapshot?.visual == .paused &&
            snapshot?.reasons.contains(where: { ["system-asleep", "screen-asleep", "screen-locked",
                "session-inactive", "thermal-serious", "thermal-critical"].contains($0)
                || ($0.hasPrefix("app-rule:") && $0.hasSuffix(":pause")) }) == true)
    }
    var dailyVisualPauseActionTitle: String {
        if desired.paused { return "陪伴画面已随全部暂停" }
        if desired.profile.visualPaused { return "陪伴画面已随模式暂停" }
        if dailyVisualPauseIsRestricted { return "陪伴画面暂不可播放" }
        return desired.dailyVisualPaused ? "恢复陪伴画面" : "暂停陪伴画面"
    }

    var dailyAmbientTracks: [AmbientTrack] { dailySoundtrackCatalog ?? [] }
    var selectedDailyAmbient: AmbientTrack? {
        ContentCatalog(ambientTracks: dailyAmbientTracks).ambientTrack(selection: desired.dailySoundtrack)
    }
    var dailyMusicTitle: String {
        if desired.dailySoundtrack == .silent { return "无音乐" }
        return selectedDailyAmbient?.soundtrackTitle ?? "陪伴音乐不可用"
    }
    var dailyMusicRestriction: String? {
        if desired.dailySoundtrack == .silent { return "未选择音乐" }
        if selectedDailyAmbient == nil { return "所选陪伴音乐不可用" }
        if desired.profile.visualPaused || desired.profile.ambientFactor == 0 { return "陪伴音乐已随模式暂停" }
        if snapshot?.reasons.contains(where: {
            ["system-asleep", "screen-asleep", "screen-locked", "session-inactive", "thermal-serious",
             "thermal-critical"].contains($0)
                || ($0.hasPrefix("app-rule:") && ($0.hasSuffix(":pause") || $0.hasSuffix(":mute")))
        }) == true { return "陪伴音乐暂不可播放" }
        if desired.ambientMuted { return "陪伴音乐已静音" }
        if desired.masterVolume == 0 || desired.ambientVolume == 0 { return "陪伴音乐音量为零" }
        return nil
    }
    var dailyMusicPauseAvailable: Bool {
        (health == .normal || health == .paused) && selectedDailyAmbient != nil
            && dailyMusicRestriction == nil
    }
    var dailyMusicPauseActionTitle: String {
        if let restriction = dailyMusicRestriction { return restriction }
        if desired.paused { return "恢复全部" }
        return desired.dailyMusicPaused ? "恢复陪伴音乐" : "暂停陪伴音乐"
    }
    var dailyMusicStatus: String {
        if desired.dailySoundtrack == .silent { return "" }
        if let restriction = dailyMusicRestriction { return restriction }
        if desired.paused || desired.dailyMusicPaused { return "已暂停" }
        return ""
    }

    /// One command path shared by the main strip, notch and menu. A queue handoff never
    /// accidentally changes the daily soundtrack while waiting for its next song session.
    func toggleCurrentMusicPause(performance: PerformanceBrowserModel) {
        if performance.sessionState.session != nil || performance.queueState.isRunning {
            performance.pause()
        } else if dailyMusicPauseAvailable {
            applyLocal {
                if $0.paused { $0.paused = false; $0.dailyMusicPaused = false }
                else { $0.dailyMusicPaused.toggle() }
            }
        }
    }

    /// Commit deliberate source selection before stopping the song, so its end cannot restore
    /// an older ambient choice. The existing stop command also cancels pending queue preparation.
    func selectDailySoundtrack(_ selection: DailySoundtrackSelection, performance: PerformanceBrowserModel) {
        guard selection == .silent || dailyAmbientTracks.contains(where: { selection == .track($0.id) }) else { return }
        applyLocal { $0.dailySoundtrack = selection; $0.dailyMusicPaused = false }
        sendWorkItem?.cancel()
        onDesiredSettled()
        performance.stop()
    }

    func selectSongSoundtrack() {
        guard desired.dailySoundtrack != .silent else { return }
        applyLocal { $0.dailySoundtrack = .silent }
    }

    func currentMusicVolume(performance: PerformanceBrowserModel) -> Double {
        performance.sessionState.session != nil || performance.queueState.isRunning
            ? desired.musicVolume : desired.ambientVolume
    }
    func setCurrentMusicVolume(_ value: Double, performance: PerformanceBrowserModel) {
        if performance.sessionState.session != nil || performance.queueState.isRunning { setMusicVolume(value) }
        else { setAmbientVolume(value) }
    }

    private var sendWorkItem: DispatchWorkItem?

    func apply(desired: DesiredState, stage: ResourceStage, stageDetail: String,
               snapshot: RuntimeSnapshot?, supervision: AgentLifecycle.Phase,
               dailyCatalogSelectionFailed: Bool = false, dailyAssetIssue: DailyAssetIssue? = nil,
               canRetryDailyResource: Bool = false) {
        self.desired = desired
        self.stage = stage
        self.stageDetail = stageDetail
        self.snapshot = snapshot
        self.supervision = supervision
        self.dailyCatalogSelectionFailed = dailyCatalogSelectionFailed
        self.dailyAssetIssue = dailyAssetIssue
        self.canRetryDailyResource = canRetryDailyResource
        if desired.dailySoundtrack == .legacyDefault, let tracks = dailySoundtrackCatalog {
            let first = ContentCatalog(ambientTracks: tracks).ambientTrack(selection: .legacyDefault)
            applyLocal { $0.dailySoundtrack = first.map { .track($0.id) } ?? .silent }
        }
    }

    func syncFrom(_ appDelegate: AppDelegate) {
        apply(desired: appDelegate.prefs.desired, stage: appDelegate.resourceStage,
              stageDetail: appDelegate.resourceStageDetail, snapshot: appDelegate.supervisor.lastSnapshot,
              supervision: appDelegate.supervisor.lifecyclePhase,
              dailyCatalogSelectionFailed: appDelegate.dailyCatalogSelectionFailed,
              dailyAssetIssue: appDelegate.dailyAssetIssue,
              canRetryDailyResource: appDelegate.canRetryDailyResource)
    }

    // MARK: - Semantic health (single source of truth for menu bar + Control Center)

    /// One cross-checked health state from the pure Core projection. Computed — never cached —
    /// so pause toggles and every pushed update re-project from the current inputs.
    var health: HealthProjection.Health {
        HealthProjection.project(
            readiness: stage.healthReadiness,
            service: supervision,
            failure: stage.failureKind,
            userPaused: desired.paused,
            snapshot: snapshot)
    }

    // MARK: - User-language status (prompt rule #9: no dev jargon)

    var statusSymbol: String {
        switch health {
        case .normal: return "circle.fill"
        case .paused: return "pause.circle"
        case .resourceUnavailable, .serviceProblem: return "exclamationmark.triangle"
        case .preparing, .recovering: return "arrow.clockwise"
        }
    }

    var statusText: String {
        switch health {
        case .normal: return "正常"
        case .paused: return "已暂停"
        case .resourceUnavailable: return "资源不可用"
        case .serviceProblem: return "服务异常"
        case .recovering: return "正在恢复…"
        case .preparing: return "准备中…"
        }
    }

    var statusColor: Color {
        switch health {
        case .normal: return .green
        case .paused: return .secondary
        case .resourceUnavailable, .serviceProblem: return .orange
        case .preparing, .recovering: return .yellow
        }
    }

    /// One honest status line: the daypart the daily picture is actually following, plus whether
    /// it follows the clock. Internal material IDs are never ordinary product words (ADR-024);
    /// they stay in the optional file/troubleshooting detail.
    var subtitle: String {
        let resolved = TimeOfDay.autoBucket(minuteOfDay: BeijingClock.minuteOfDay(at: Date()))
        switch desired.timeMode {
        case .auto: return "按北京时间 · 现在\(resolved.controlCenterLabel)"
        case .fixed(let t): return "固定\(t.controlCenterLabel)"
        }
    }

    var dailySwitchMessage: String? {
        guard health == .normal, !desired.paused else { return nil }
        if desired.timeMode == .auto, let time = snapshot?.pendingDailyTime {
            return "本段结束后切换至\(time.controlCenterLabel)"
        }
        if snapshot?.pendingDailyRefresh == true { return "本段结束后更新日常素材" }
        return snapshot?.transitionClip != nil ? "正在切换日常光照" : nil
    }

    // MARK: - Actions

    func resumeUserPause() {
        guard desired.paused else { return }
        applyLocal { $0.paused = false }
    }

    func toggleDailyVisualPause() { applyLocal { $0.dailyVisualPaused.toggle() } }

    func togglePause() {
        applyLocal { $0.paused = !$0.paused }
    }

    func setScene(_ scene: BSideCore.Scene) {
        guard dailySceneIsEnabled(scene) else { return }
        applyLocal { $0.scene = scene }
    }
    func setOutfit(_ outfit: Outfit) {
        guard dailyOutfitIsEnabled(outfit) else { return }
        applyLocal { $0.outfit = outfit }
    }
    func setTimeAuto() {
        guard dailyAutoIsEnabled else { return }
        applyLocal { $0.timeMode = .auto }
    }
    func setTimeFixed(_ time: TimeOfDay) {
        guard dailyTimeIsEnabled(time) else { return }
        applyLocal { $0.timeMode = .fixed(time) }
    }

    /// Explicit whole-combination selection gives sparse libraries a path across dimensions.
    /// It never picks a different combination on the user's behalf. Returns false when the
    /// current guarded discovery no longer contains the key, so callers can report truthfully.
    @discardableResult
    func selectDailyContent(_ key: ContentKey) -> Bool {
        guard dailyContentKeys?.contains(key) == true else { return false }
        applyLocal { $0.scene = key.scene; $0.outfit = key.outfit; $0.timeMode = .fixed(key.time) }
        return true
    }

    /// Background-only selection from the visual chooser: it changes the scene/outfit of the
    /// current appearance while preserving the user's existing automatic/fixed daypart
    /// preference. The chooser only offers combinations at the currently effective daypart, so
    /// this never forces a fixed time and never silently stops automatic switching. Returns
    /// false when the current guarded discovery no longer contains the key.
    @discardableResult
    func selectDailyBackground(_ key: ContentKey) -> Bool {
        guard dailyContentKeys?.contains(key) == true else { return false }
        applyLocal { $0.scene = key.scene; $0.outfit = key.outfit }
        return true
    }
    func setProfile(_ profile: Profile) { applyLocal { $0.profile = profile } }

    var profileOptions: [Profile] {
        desired.profile.id == Profile.custom.id ? Profile.builtIn + [.custom] : Profile.builtIn
    }

    /// Volume changes make the previous profile label dishonest — switch to neutral Custom.
    func setMasterVolume(_ volume: Double) {
        applyLocal { $0.masterVolume = volume; $0.profile = .custom }
    }

    func setMusicVolume(_ volume: Double) {
        applyLocal { $0.musicVolume = volume; $0.musicMuted = false; $0.profile = .custom }
    }

    func setAmbientVolume(_ volume: Double) {
        applyLocal { $0.ambientVolume = volume; $0.profile = .custom }
    }

    func setDesktopMode(_ enabled: Bool) { applyLocal { $0.desktopMode = enabled } }
    func setTimeMode(_ mode: TimeMode) {
        switch mode {
        case .auto: setTimeAuto()
        case .fixed(let time): setTimeFixed(time)
        }
    }
    func setFullscreenPause(_ enabled: Bool) { applyLocal { $0.pauseVisualOnFullscreen = enabled } }
    func setFullscreenMute(_ enabled: Bool) { applyLocal { $0.muteAudioOnFullscreen = enabled } }

    var masterBinding: Binding<Double> {
        Binding(get: { self.desired.masterVolume }, set: { self.setMasterVolume($0) })
    }
    var ambientBinding: Binding<Double> {
        Binding(get: { self.desired.ambientVolume }, set: { self.setAmbientVolume($0) })
    }
    var musicBinding: Binding<Double> {
        Binding(get: { self.desired.musicVolume }, set: { self.setMusicVolume($0) })
    }

    private func applyLocal(_ change: (inout DesiredState) -> Void) {
        var copy = desired
        change(&copy)
        desired = copy.sanitized()
        // Commit user intent synchronously. Runtime refreshes must not replace a pending edit
        // with the owner's old state, nor may a delayed whole-state copy undo a later command.
        onDesiredChange(desired)
        scheduleSend()
    }

    /// Save/send once after slider edits settle for 150 ms (prompt rule #12).
    private func scheduleSend() {
        sendWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onDesiredSettled() }
        sendWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
}

struct ControlCenterView: View {
    @ObservedObject var model: ControlCenterModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            PreferencesSaveFeedback(model: model)
            ResourceRecoveryFeedback(model: model)
            if let message = model.dailySwitchMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("daily-switch-pending")
            }
            pauseButton
            volumeRow(title: "主音量", value: Binding(
                get: { model.desired.masterVolume },
                set: { model.setMasterVolume($0) }))
            Divider()
            // Primary entries only. Manual scene/outfit/time and per-channel audio/profile
            // selection moved to the Settings window ("画面" / "声音"); this panel keeps the
            // prominent pause, master volume and the top-level destinations.
            dailyActivityRow
            performanceLibraryRow
            settingsRow
            Divider()
            footer
        }
        .padding(20)
        .frame(width: 336)
        .background(FrontendAppearance.surface)
        .tint(FrontendAppearance.actionTint(for: colorScheme))
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text("林离").font(FrontendAppearance.titleFont)
                Text(model.subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 4) {
                Image(systemName: model.statusSymbol)
                    .foregroundStyle(model.statusColor)
                Text(model.statusText).font(.caption)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("当前状态：\(model.statusText)")
        }
    }

    private var pauseButton: some View {
        Button {
            model.togglePause()
        } label: {
            Label(model.desired.paused ? "恢复播放" : "暂停播放",
                  systemImage: model.desired.paused ? "play.fill" : "pause.fill")
                .frame(maxWidth: .infinity).padding(.vertical, 5)
        }
        .buttonStyle(.bordered)
        .keyboardShortcut(.space, modifiers: [])
        .accessibilityLabel(model.desired.paused ? "恢复播放" : "暂停播放")
    }

    private func volumeRow(title: String, value: Binding<Double>) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.callout).frame(width: 46, alignment: .leading)
            Slider(value: value, in: 0...1)
                .accessibilityLabel(title)
            Text("\(Int((value.wrappedValue * 100).rounded()))%")
                .monospacedDigit().font(.caption).foregroundStyle(.secondary)
                .frame(width: 35, alignment: .trailing)
        }
    }

    private func entryLabel(_ title: String, systemImage: String) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            Image(systemName: "chevron.right").font(.caption)
        }.padding(.vertical, 4).contentShape(Rectangle())
    }

    /// One compact primary entry: the reviewed daily material chooser lives in its own window.
    private var dailyActivityRow: some View {
        Button { model.onRequest(.dailyActivity) } label: {
            entryLabel("日常…", systemImage: "sparkles")
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("daily-activity-entry")
        .help("查看当前背景、时段与活动入口；浏览不会自动播放或更改声音设置。")
    }

    private var performanceLibraryRow: some View {
        Button { model.onRequest(.performanceLibrary) } label: {
            entryLabel("演奏曲库", systemImage: "music.note.list")
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("performance-library-entry")
    }

    /// Clearly labeled secondary entry. Scene/outfit/time and per-channel audio live there.
    private var settingsRow: some View {
        Button { model.onRequest(.settings) } label: {
            entryLabel("设置…", systemImage: "gearshape")
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings-entry")
        .help("画面、声音、资源、记录与高级设置")
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Button { model.onRequest(.help) } label: { Image(systemName: "questionmark.circle") }
                .accessibilityLabel("帮助")
                .help("帮助")
            Spacer()
            Button { model.onRequest(.quit) } label: {
                Label("退出", systemImage: "power")
            }
            .accessibilityIdentifier("quit-entry")
            .accessibilityLabel("退出 bsideyou")
            .help("退出 bsideyou")
        }
        .buttonStyle(.plain)
        .font(.system(size: 15))
    }
}

extension TimeOfDay {
    var controlCenterLabel: String {
        switch self { case .noon: return "白天"; case .evening: return "傍晚"; case .night: return "夜晚" }
    }
}

/// Only known generic source filenames receive a display label; real titles remain verbatim.
extension AmbientTrack {
    var soundtrackTitle: String {
        label.range(of: "^ambient_loop_[0-9]+\\.mp3$", options: [.regularExpression, .caseInsensitive]) != nil
            ? "陪伴音轨 \(index)" : label
    }
}
