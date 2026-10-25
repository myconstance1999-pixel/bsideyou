// BSideControlApp — Settings window (state projection + commands only; prompt rules #17/#18).
// No filesystem/player/agent access here — everything goes through the shared coordinator.

import SwiftUI
import BSideCore
import BSidePlatform

// Explicitly name the property-wrapper type: SDK 27 also exports a State macro,
// whose SwiftUIMacros plugin is absent from the current CLT toolchain.
private typealias BoolState = State<Bool>
private typealias IntState = State<Int>

/// Actions the Settings view may request, provided by the AppDelegate.
struct SettingsActions {
    var changeResource: () -> Void
    var validateNow: () -> Void
    var rerunOnboarding: () -> Void
    var restartAgent: () -> Void
    var openLogs: () -> Void
    var copyDiagnostics: () -> Void
    /// Diagnostics window entry. Removed from the Control Center primary panel, so the existing
    /// Advanced section keeps it reachable through the ordinary production path.
    var showDiagnostics: () -> Void
    var resetPreferences: () -> Void
    var changeLogin: (Bool) -> Void
    /// Pure Core projection of the REAL system status (Slice 7): toggle + truthful summary.
    var loginState: () -> LoginItemProjection
    var loginDescribe: () -> String
    var catalogSummary: () -> String
    /// Confirmed-history recording (opt-in, default off). All mutations go through the
    /// PlaybackHistoryController; the view never touches files or the Agent.
    var historySettings: () -> PlaybackHistorySettings
    var setHistoryEnabled: (Bool) -> Void
    var retryHistory: () -> Void
    var clearHistory: () -> Void
    var exportHistory: () -> Void
    var cropHistory: (Int) -> Void
}

struct SettingsView: View {
    @ObservedObject var model: ControlCenterModel
    let actions: SettingsActions
    /// ADR-024 daily background chooser. Visual background selection lives in ONE place; settings
    /// only offers the daypart policy and a way into that chooser, never numbered resource ids.
    @ObservedObject var backgrounds: DailyBackgroundChooserModel
    var embedded = false
    @BoolState private var confirmReset = false
    @BoolState private var confirmClearHistory = false
    @IntState private var retentionDays = 30

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PreferencesSaveFeedback(model: model, alwaysShow: true)
                // The picture section keeps only what the user can decide here: when the picture
                // changes (the existing time policy) and whether fullscreen pauses it. Which
                // background plays is chosen visually in the daily chooser.
                section("画面") {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(currentPictureSummary)
                            Text("选择完整陪伴视频，音乐单独选择。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Button("选择陪伴视频…") {
                            // The chooser resolves the current backdrop key itself (Core's
                            // dailySourceKey is nil under the automatic time policy).
                            backgrounds.present(currentKey: nil)
                        }
                        .accessibilityIdentifier("settings-change-background")
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        pickerRow(title: "时间") {
                            DailySegmentedPicker(label: "时间", selection: timeModeBinding,
                                options: [.init(value: .auto, title: "自动", isEnabled: model.dailyAutoIsEnabled)] +
                                    TimeOfDay.allCases.map { time in
                                        .init(value: .fixed(time), title: time.controlCenterLabel,
                                              isEnabled: model.dailyTimeIsEnabled(time))
                                    },
                                accessibilityIdentifier: "daily-settings-time")
                                .frame(height: 22)
                        }
                        Text("自动按北京时间：06:00–17:30 白天 · 17:30–20:00 傍晚 · 其余夜晚")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    DailyContentFeedback(model: model)
                    Toggle("其他应用全屏时暂停日常画面", isOn: fullscreenPauseBinding)
                }
                // Per-channel audio moved here from the primary panel. Manual volume edits are
                // what switch the profile to the neutral 手动调节 case, explained right beside
                // the sliders; the preset rows live in the adjacent 使用场景 section.
                section("声音") {
                    volumeSlider("主音量", model.masterBinding)
                    volumeSlider("环境音", model.ambientBinding)
                    volumeSlider("音乐", model.musicBinding)
                    Text(ProfilePresentationCatalog.customSwitchNote)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("usage-scene-custom-switch-note")
                }
                // "使用场景" (formerly the 播放模式 Picker): the rows state use case, effect and
                // selected state together, so alternatives are comparable without selecting them.
                section("使用场景") {
                    ProfileChoiceList(
                        profiles: ProfilePresentationCatalog.visibleOptions(
                            selected: model.desired.profile, base: model.profileOptions),
                        selectedID: model.desired.profile.id,
                        onSelect: { model.setProfile($0) })
                    Text(ProfilePresentationCatalog.scopeNote)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("usage-scene-scope-note")
                }
                // 通用 (login + desktop mode + onboarding) follows the picture/sound controls;
                // its login-availability text is preserved exactly as before.
                section("通用") {
                    loginRow
                    Toggle("默认桌面壁纸模式（关闭后为浮窗预览）", isOn: desktopModeBinding)
                    Button("重新运行首次设置…") { actions.rerunOnboarding() }
                }
                section("内容") {
                    HStack {
                        Text(modelStagePath).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(2)
                        Spacer()
                        Button("更改…") { actions.changeResource() }
                    }
                    HStack {
                        Text("资源状态：\(model.stage.settingsDescription)")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("重新检查目录") { actions.validateNow() }
                            .disabled(!model.canRetryDailyResource)
                    }
                    ResourceRecoveryFeedback(model: model)
                }
                section("记录") {
                    Toggle("记录实际播放时长（实验，默认关闭）", isOn: historyBinding)
                    Text(historyProjection.channelEvidence)
                        .font(.caption).foregroundStyle(.secondary)
                    if let error = historyProjection.error {
                        if historyProjection.canRetry {
                            Button("重试保存记录") { actions.retryHistory() }
                        }
                        Text(error).font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("仅统计实际推进的媒体时钟：画面、音乐、环境音各自独立，不合并为总和，也不推断中断的时长。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Picker("保留最近", selection: $retentionDays) {
                            Text("7 天").tag(7)
                            Text("30 天").tag(30)
                            Text("90 天").tag(90)
                            Text("365 天").tag(365)
                        }
                        .frame(width: 150)
                        Button("删除更早记录") { actions.cropHistory(retentionDays) }
                            .disabled(historyProjection.intervalCount == 0)
                        Spacer()
                        Button("导出记录…") { actions.exportHistory() }
                            .disabled(historyProjection.intervalCount == 0)
                        Button("清除记录…", role: .destructive) { confirmClearHistory = true }
                            .disabled(historyProjection.intervalCount == 0)
                            .confirmationDialog("清除全部播放时长记录？此操作无法撤销，不会删除媒体文件。",
                                                isPresented: $confirmClearHistory) {
                                Button("清除", role: .destructive) { actions.clearHistory() }
                            }
                    }
                }
                section("高级") {
                    Button("重启壁纸服务") { actions.restartAgent() }
                        .disabled(!model.resourceConfigured)
                    Button("打开诊断…") { actions.showDiagnostics() }
                    Button("打开日志文件夹") { actions.openLogs() }
                    Button("复制诊断信息") { actions.copyDiagnostics() }
                    Button("重置偏好设置…", role: .destructive) { confirmReset = true }
                        .confirmationDialog("将清除所有 bsideyou 设置并停止播放，确定吗？",
                                            isPresented: $confirmReset) {
                            Button("重置", role: .destructive) { actions.resetPreferences() }
                        }
                }
            }
            .padding(20)
        }
        .frame(width: embedded ? nil : 520, height: embedded ? nil : 560)
        .sheet(isPresented: Binding(get: { backgrounds.isPresentedInWindow },
                                    set: { backgrounds.isPresentedInWindow = $0 })) {
            DailyBackgroundChooser(model: backgrounds)
        }
        .onDisappear { if backgrounds.isPresentedInWindow { backgrounds.dismissed() } }
    }

    /// Ordinary words for the current picture policy. No numbered resource id appears here.
    private var currentPictureSummary: String {
        let resolved = DailyActivityRecommendationModel.resolvedTime(desired: model.desired, now: Date())
        switch model.desired.timeMode {
        case .auto: return "按北京时间自动切换 · 现在\(resolved.controlCenterLabel)"
        case .fixed(let time): return "固定\(time.controlCenterLabel)"
        }
    }

    private var modelStagePath: String { model.resourceConfigured ? "已配置" : "未配置" }

    private var historyProjection: PlaybackHistorySettings { actions.historySettings() }

    private var historyBinding: Binding<Bool> {
        Binding(
            get: { actions.historySettings().isEnabled },
            set: { enabled in
                // The controller persists first; a failed write surfaces through the projection.
                actions.setHistoryEnabled(enabled)
            })
    }

    private var loginRow: some View {
        HStack {
            Toggle("登录时启动 bsideyou", isOn: loginBinding)
            Spacer()
            Text(actions.loginDescribe())
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var loginBinding: Binding<Bool> {
        Binding(
            get: { actions.loginState().toggleOn },
            set: { enabled in
                // Setter goes through the coordinator so the UI always reflects the REAL state.
                actions.changeLogin(enabled)
            })
    }

    private var desktopModeBinding: Binding<Bool> {
        Binding(get: { model.desired.desktopMode }, set: { model.setDesktopMode($0) })
    }
    private var timeModeBinding: Binding<TimeMode> {
        Binding(get: { model.desired.timeMode }, set: { model.setTimeMode($0) })
    }
    private var fullscreenPauseBinding: Binding<Bool> {
        Binding(get: { model.desired.pauseVisualOnFullscreen }, set: { model.setFullscreenPause($0) })
    }

    private func volumeSlider(_ title: String, _ binding: Binding<Double>) -> some View {
        HStack {
            Text(title).frame(width: 60, alignment: .leading)
            // "主音量" already ends in 音量; appending it again produced "主音量音量".
            Slider(value: binding, in: 0...1)
                .accessibilityLabel(title.hasSuffix("音量") ? title : "\(title)音量")
            Text("\(Int((binding.wrappedValue * 100).rounded()))%")
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
    }

    private func pickerRow<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(title).font(.callout).frame(width: 72, alignment: .leading)
            content()
        }
        .accessibilityElement(children: .contain)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 6)
    }
}
