// BSideControlApp — one companion home with on-demand library, queue, records and settings.
// Navigation owns transient presentation only. Existing models retain all playback, study,
// preferences and resource authority; the shared transport is the sole music pause/stop surface.
import AppKit
import SwiftUI
import BSideCore
import BSidePlatform

/// Transient candidate navigation. In-memory only: no preference field, no persisted
/// navigation format, no playback command. Cold launch starts on `daily`.
enum CandidatePage: String, CaseIterable, Hashable {
    case daily
    case library
    case queue
    case study
    case settings

    var label: String {
        switch self {
        case .daily: return "日常"
        case .library: return "曲库"
        case .queue: return "队列"
        case .study: return "记录"
        case .settings: return "设置"
        }
    }

    var systemImage: String {
        switch self {
        case .daily: return "sun.horizon"
        case .library: return "music.note.list"
        case .queue: return "list.bullet"
        case .study: return "clock.arrow.circlepath"
        case .settings: return "gearshape"
        }
    }
}

final class CandidateNavigationModel: ObservableObject {
    /// Required selected-page truth for the whole candidate window. Defaults to 日常 so a
    /// cold launch always opens the daily page.
    @Published private(set) var page: CandidatePage = .daily
    /// Mount the native library list on first use and keep its browsing position for this window.
    private(set) var hasVisitedLibrary = false
    @Published private(set) var studyControlsRequested = false

    var hasAuxiliaryPanel: Bool { page != .daily }
    var showsStudyControls: Bool { studyControlsRequested && !hasAuxiliaryPanel }

    func showStudyControls() {
        if !studyControlsRequested { studyControlsRequested = true }
        select(.daily)
    }

    func hideStudyControls() {
        if studyControlsRequested { studyControlsRequested = false }
    }

    func closePanel() { select(.daily) }
    /// Called after a user-visible page change (e.g. the daily page resolves its
    /// presentation-time recommendation). Never a playback command.
    var onPageSelected: (CandidatePage) -> Void = { _ in }

    @discardableResult
    func select(_ page: CandidatePage) -> Bool {
        guard self.page != page else { return false }
        if page == .library { hasVisitedLibrary = true }
        self.page = page
        onPageSelected(page)
        return true
    }
}

/// One home remains visible beside an auxiliary panel. Only the native library list is retained
/// while closed; all other panels and the optional study readout follow visible mount lifecycle.
struct UnifiedCandidateWindow: View {
    @ObservedObject var navigation: CandidateNavigationModel
    let controlCenter: ControlCenterModel
    let performance: PerformanceBrowserModel
    let study: StudyTimerController
    let dailyActivity: DailyActivityRecommendationModel
    let dailyBackgrounds: DailyBackgroundChooserModel
    let homePreview: CompanionHomePreview
    @ObservedObject var presentation: CompanionWindowPresentation
    let showQueuePage: () -> Void
    let makeSettingsActions: () -> SettingsActions

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                CompanionHomeHeader(navigation: navigation, study: study, control: controlCenter)
                CompanionHomeFeedback(control: controlCenter, music: performance,
                                      showLibrary: { navigation.select(.library) })
            }
            .frame(height: presentation.usesImmersiveLayout ? 0 : nil).clipped()
            .opacity(presentation.usesImmersiveLayout ? 0 : 1)
            .allowsHitTesting(!presentation.usesImmersiveLayout).accessibilityHidden(presentation.usesImmersiveLayout)
            GeometryReader { geometry in
                let panelWidth = min(480, max(420, geometry.size.width * 0.46))
                let showsPanel = navigation.hasAuxiliaryPanel && !presentation.usesImmersiveLayout
                HStack(alignment: .top, spacing: showsPanel ? 20 : 0) {
                    HStack(alignment: .top, spacing: 22) {
                        CompanionHomeScene(model: controlCenter, dailyActivity: dailyActivity,
                                           backgrounds: dailyBackgrounds, preview: homePreview, presentation: presentation,
                                           canvasAspectRatio: geometry.size.width / max(1, geometry.size.height),
                                           presentsBackgroundChooser: navigation.page != .settings)
                            .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
                        if navigation.showsStudyControls && !presentation.usesImmersiveLayout {
                            ScrollView {
                                CompactStudyTimer(study: study, close: navigation.hideStudyControls)
                            }
                            .frame(width: 264)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    auxiliaryPanel
                        .frame(width: panelWidth)
                        .frame(width: showsPanel ? panelWidth : 0)
                        .clipped()
                        .opacity(showsPanel ? 1 : 0)
                        .allowsHitTesting(showsPanel)
                        .disabled(!showsPanel)
                        .accessibilityElement(children: showsPanel ? .contain : .ignore)
                        .accessibilityHidden(!showsPanel)
                }
            }
            .padding(.horizontal, presentation.usesImmersiveLayout ? 0 : 24)
            .padding(.bottom, presentation.usesImmersiveLayout ? 0 : 20)
            VStack(spacing: 0) {
                Divider()
                SharedMusicStrip(model: performance, control: controlCenter, showQueuePage: showQueuePage)
            }
            .frame(height: presentation.usesImmersiveLayout ? 0 : nil).clipped()
            .opacity(presentation.usesImmersiveLayout ? 0 : 1)
            .allowsHitTesting(!presentation.usesImmersiveLayout).accessibilityHidden(presentation.usesImmersiveLayout)
        }
        .frame(minWidth: 960, minHeight: 680)
        .background(presentation.usesImmersiveLayout ? Color.black : MusicWorkspaceAppearance.background)
        // The plain titled window already separates its titlebar from the content view. Keep
        // this canvas independent of transient fullscreen safe-area insets within that view.
        .ignoresSafeArea(.container)
    }

    private var auxiliaryPanel: some View {
        VStack(spacing: 0) {
            if navigation.hasAuxiliaryPanel {
                HStack {
                    Text(navigation.page.label).font(.system(size: 20, weight: .medium, design: .serif))
                    Spacer()
                    Button(action: navigation.closePanel) {
                        Label("收起", systemImage: "xmark")
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("收起\(navigation.page.label)")
                    .accessibilityIdentifier("home-panel-close")
                }
                .padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 8)
            }
            ZStack {
                if navigation.hasVisitedLibrary {
                    PerformanceBrowserView(model: performance, saveModel: controlCenter,
                                            showsSessionFooter: false, fixedSection: .library,
                                            minimumWidth: 420,
                                            isPageVisible: navigation.page == .library && !presentation.usesImmersiveLayout,
                                            showsHeader: false, showsGlobalFeedback: false,
                                            minimumHeight: 360)
                        .opacity(navigation.page == .library ? 1 : 0)
                        .allowsHitTesting(navigation.page == .library)
                        .disabled(navigation.page != .library)
                        .accessibilityElement(children: navigation.page == .library ? .contain : .ignore)
                        .accessibilityHidden(navigation.page != .library)
                }
                switch navigation.page {
                case .daily, .library:
                    EmptyView()
                case .queue:
                    PerformanceQueueView(model: performance,
                                         showLibrary: { navigation.select(.library) },
                                         showsHistorySelector: false)
                case .study:
                    CompanionRecordsPanel(study: study, music: performance)
                case .settings:
                    SettingsView(model: controlCenter, actions: makeSettingsActions(),
                                 backgrounds: dailyBackgrounds, embedded: true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(MusicWorkspaceAppearance.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).stroke(MusicWorkspaceAppearance.line.opacity(0.7)) }
    }
}

private struct CompanionHomeHeader: View {
    @ObservedObject var navigation: CandidateNavigationModel
    @ObservedObject var study: StudyTimerController
    @ObservedObject var control: ControlCenterModel

    var body: some View {
        HStack(spacing: 18) {
            Button(action: navigation.closePanel) {
                Text("bsideyou").font(.system(size: 24, weight: .medium, design: .serif))
            }
            .buttonStyle(.plain).accessibilityLabel("返回主界面")
            Spacer(minLength: 16)
            Button { navigation.select(.library) } label: {
                Label("选音乐", systemImage: "music.note.list")
                    .padding(.horizontal, 15).padding(.vertical, 10)
                    .background(MusicWorkspaceAppearance.selected, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("home-open-library")
            Button(action: navigation.showStudyControls) {
                Label(studyLabel, systemImage: "timer")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("home-open-study")
            Menu {
                Button("记录") { navigation.select(.study) }
                Button("播放队列") { navigation.select(.queue) }
                Divider()
                Button("设置") { navigation.select(.settings) }
                Divider()
                Button(control.desired.paused ? "恢复全部画面和音乐" : "暂停全部画面和音乐", action: control.togglePause)
            } label: {
                Image(systemName: "ellipsis").frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("记录与设置")
            .accessibilityIdentifier("home-more")
        }
        .foregroundStyle(MusicWorkspaceAppearance.accent)
        .padding(.horizontal, 28).padding(.vertical, 20)
    }

    private var studyLabel: String {
        if study.error != nil { return "自习 · 待处理" }
        if study.ledger.active != nil { return study.isRunning ? "自习中" : "自习已暂停" }
        return "自习计时"
    }
}

/// Shared feedback remains visible even when the library is closed. It uses the existing
/// owner messages rather than inferring failure from strings or hiding terminal session errors.
private struct CompanionHomeFeedback: View {
    @ObservedObject var control: ControlCenterModel
    @ObservedObject var music: PerformanceBrowserModel
    let showLibrary: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PreferencesSaveFeedback(model: control)
            ResourceRecoveryFeedback(model: control)
            let messages = [music.retentionProblem, music.scanFailure, music.localMessage,
                            music.message.isEmpty ? nil : music.message].compactMap { $0 }
                .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            if !messages.isEmpty {
                HStack(alignment: .top, spacing: 16) {
                    Text(messages.joined(separator: "\n"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("查看音乐", action: showLibrary).font(.caption).buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 28).padding(.bottom, 12)
    }
}

private struct CompanionHomeScene: View {
    @ObservedObject var model: ControlCenterModel
    @ObservedObject var dailyActivity: DailyActivityRecommendationModel
    @ObservedObject var backgrounds: DailyBackgroundChooserModel
    @ObservedObject var preview: CompanionHomePreview
    @ObservedObject var presentation: CompanionWindowPresentation
    let canvasAspectRatio: CGFloat
    let presentsBackgroundChooser: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: presentation.usesImmersiveLayout ? 0 : 14) {
            CompanionHomeArtwork(model: preview, immersive: presentation.usesImmersiveLayout)
                .aspectRatio(presentation.usesImmersiveLayout ? canvasAspectRatio : 16.0 / 9.0, contentMode: .fit)
                .frame(maxWidth: .infinity, alignment: .center)
            VStack(alignment: .leading, spacing: 14) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 18) { scenePause; fullScreenButton; Spacer(); changeScene }
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 18) { scenePause; fullScreenButton }
                        changeScene
                    }
                }
                .font(.callout)
                if let failure = presentation.failure {
                    Text(failure).font(.caption).foregroundStyle(.secondary)
                }
                if let notice = dailyActivity.backgroundChoiceNotice ?? model.dailySwitchMessage {
                    Text(notice).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(height: presentation.usesImmersiveLayout ? 0 : nil).clipped()
            .opacity(presentation.usesImmersiveLayout ? 0 : 1)
            .allowsHitTesting(!presentation.usesImmersiveLayout).accessibilityHidden(presentation.usesImmersiveLayout)
        }
        .onChange(of: backgrounds.isPresented) { preview.setChooserPresented($0) }
        .onAppear { preview.setChooserPresented(backgrounds.isPresented) }
        .sheet(isPresented: Binding(get: { presentsBackgroundChooser && backgrounds.isPresentedInWindow },
                                    set: { backgrounds.isPresentedInWindow = $0 })) {
            DailyBackgroundChooser(model: backgrounds)
        }
        .tint(MusicWorkspaceAppearance.accent)
    }

    private var scenePause: some View {
        Button(action: model.toggleDailyVisualPause) {
            Label(model.dailyVisualPauseActionTitle,
                  systemImage: model.desired.dailyVisualPaused || model.desired.paused ? "play.fill" : "pause.fill")
        }
        .buttonStyle(.plain).disabled(model.dailyVisualPauseIsRestricted)
        .accessibilityIdentifier("home-scene-pause")
        .help("只控制陪伴画面，不影响音乐；全局暂停和系统限制仍然生效。")
    }
    private var fullScreenButton: some View {
        Button(action: presentation.toggle) {
            Label(presentation.isFullScreen ? "退出陪伴全屏" : "全屏陪伴画面",
                  systemImage: presentation.isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
        }
        .buttonStyle(.plain).disabled(presentation.isTransitioning)
        .accessibilityIdentifier("home-scene-fullscreen")
    }
    private var changeScene: some View {
        Button { backgrounds.present(currentKey: nil) } label: {
            Label("选择陪伴视频…", systemImage: "photo.stack")
        }
        .buttonStyle(.plain).accessibilityIdentifier("daily-change-background")
    }

}

private typealias RecordTabState = State<Bool>

private struct CompanionRecordsPanel: View {
    @ObservedObject var study: StudyTimerController
    @ObservedObject var music: PerformanceBrowserModel
    @RecordTabState private var showsSongs = false

    var body: some View {
        VStack(spacing: 16) {
            Picker("记录类型", selection: $showsSongs) {
                Text("自习记录").tag(false)
                Text("播放历史").tag(true)
            }
            .pickerStyle(.segmented).padding(.horizontal, 22).padding(.top, 12)
            .accessibilityIdentifier("home-record-kind")
            if showsSongs {
                SongPlaybackHistoryView(model: music)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let error = study.error {
                            Text(error).font(.caption).foregroundStyle(.secondary)
                            Button("重试", action: study.retry)
                        }
                        StudyHistoryView(model: study)
                    }.padding(22)
                }
            }
        }
        .accessibilityIdentifier("home-records")
    }
}

/// Pure read-only projection for the homepage music card. Built from the SHARED
/// `PerformanceBrowserModel`, so the card can never offer an action the model would refuse, can
/// never claim a start row it does not have, and cannot diverge from the 曲库/队列 pages or the
/// shared strip. It owns no state: it is recomputed from the shared model on every render.
struct HomepageMusicCardState: Equatable {
    /// Current category/source/search/only-found summary, in ordinary Chinese words.
    let filterSummary: String
    /// `visibleListSnapshot.count`: rows eligible to play right now under the current filters.
    let eligibleCount: Int
    /// The selected row title, reused from the shared list. Nil when nothing is selected.
    let selectedTitle: String?
    /// True only while the selected row is present in the eligible snapshot right now.
    let canPlaySelected: Bool
    /// True only while the current filter yields at least one eligible row.
    let canShuffle: Bool
    /// What list play would start, for a clear starting row.
    let startRow: String
    /// Why list play is disabled, or nil when it is available.
    let unavailableReason: String?

    static func make(_ model: PerformanceBrowserModel) -> HomepageMusicCardState {
        let snapshot = model.visibleListSnapshot
        let selectedTitle = model.selectedRow?.title
        let canPlaySelected = model.selectedID.flatMap { model.listEntry(forRow: $0) } != nil
        let reason: String?
        if model.selectedID == nil {
            reason = snapshot.isEmpty ? "当前筛选结果没有可播放的歌曲。" : "尚未选择歌曲，可先选择歌曲。"
        } else if canPlaySelected {
            reason = nil
        } else if let local = model.selectedLocalTrack {
            reason = model.localSelectionProblem(local)
                ?? "《\(selectedTitle ?? "所选歌曲")》不在当前筛选结果中。"
        } else {
            reason = model.selectionProblem
                ?? "《\(selectedTitle ?? "所选歌曲")》不在当前筛选结果中。"
        }
        let startRow: String
        if canPlaySelected, let selectedTitle {
            startRow = "开始曲目：《\(selectedTitle)》"
        } else if let selectedTitle {
            startRow = "所选歌曲：《\(selectedTitle)》当前不可播放"
        } else {
            startRow = "未选择歌曲"
        }
        return HomepageMusicCardState(
            filterSummary: summary(model),
            eligibleCount: snapshot.count,
            selectedTitle: selectedTitle,
            canPlaySelected: canPlaySelected,
            canShuffle: !snapshot.isEmpty,
            startRow: startRow,
            unavailableReason: reason)
    }

    private static func summary(_ model: PerformanceBrowserModel) -> String {
        var parts = ["类别：\(model.categoryFilter.label)"]
        switch model.sourceFilter {
        case .all: parts.append("来源：全部")
        case .source(let source): parts.append("来源：\(source)")
        }
        let search = model.search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !search.isEmpty { parts.append("搜索：\(search)") }
        if model.onlyFound { parts.append("仅可用") }
        if model.styleFilter != .all { parts.append("风格：\(model.styleFilter.label)") }
        if model.onlyFavorites { parts.append("仅收藏") }
        return parts.joined(separator: " · ")
    }
}

/// The ONE music status/control strip in the candidate window. Present on every page.
/// Primary music transport remains fixed; secondary song and queue actions share a compact menu.
/// Presentation and queue-order changes preserve the current song's session and item.
struct SharedMusicStrip: View {
    @ObservedObject var model: PerformanceBrowserModel
    @ObservedObject var control: ControlCenterModel
    @SwiftUI.State private var showsVolume = false
    /// Opens the 播放队列 page. Presentation only; it never issues a playback command.
    let showQueuePage: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    private var music: NotchMusicState { NotchMusicState.make(model, control: control) }

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: symbolName)
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(MusicWorkspaceAppearance.accent)
                .frame(width: 42, height: 42)
                .background(MusicWorkspaceAppearance.inset, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout.weight(.medium)).lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(minWidth: 100, maxWidth: .infinity, alignment: .leading)
            if model.sessionState.session != nil || model.queueState.isRunning {
                Button(action: model.previousSong) { Image(systemName: "backward.end.fill") }
                    .buttonStyle(.plain).frame(width: 28, height: 36)
                    .disabled(!model.canPreviousSong)
                    .accessibilityLabel("上一首").help("上一首")
                    .accessibilityIdentifier("music-previous")
            }
            Button { control.toggleCurrentMusicPause(performance: model) } label: {
                Group {
                    if !music.isActive && control.desired.dailySoundtrack == .silent {
                        Image(systemName: "pause.fill")
                    } else {
                        Label(music.pauseTitle, systemImage: music.isPaused ? "play.fill" : "pause.fill")
                    }
                }
                    .font(.callout.weight(.medium))
                    .foregroundStyle(MusicWorkspaceAppearance.actionForeground(for: colorScheme))
                    .padding(.horizontal, 12).frame(height: 42)
                    .background(MusicWorkspaceAppearance.accent, in: Capsule())
            }
            .buttonStyle(.plain).disabled(!music.canPause)
            .accessibilityLabel(music.pauseTitle).help(music.pauseTitle)
            .accessibilityIdentifier("music-pause")
            if music.isActive {
                Button(action: model.nextInQueue) { Image(systemName: "forward.end.fill") }
                    .buttonStyle(.plain).frame(width: 28, height: 36)
                    .accessibilityLabel("下一首").help("下一首")
                    .accessibilityIdentifier("music-next")
            }
            if model.sessionState.session == nil && !model.queueState.isRunning {
                if HomepageMusicCardState.make(model).canPlaySelected {
                    Button("播放所选歌曲", action: model.playSelectedFromList)
                        .buttonStyle(.plain)
                        .accessibilityLabel("播放所选歌曲")
                        .accessibilityIdentifier("music-play-selected")
                        .help("从所选歌曲开始，继续播放当前列表。")
                }
                Button(action: model.startFilteredShufflePlayback) {
                    Label("随机播放", systemImage: "shuffle")
                }
                .buttonStyle(.plain)
                .disabled(model.filteredShuffleProblem != nil)
                .accessibilityIdentifier("music-shuffle")
                .help("用当前列表替换队列，随机开始播放。")
            }
            Button { showsVolume = true } label: { Image(systemName: "speaker.wave.2") }
                .buttonStyle(.plain).accessibilityLabel(music.volumeLabel).help(music.volumeLabel)
                .popover(isPresented: $showsVolume) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(music.volumeLabel).font(.callout)
                        Slider(value: Binding(get: { control.currentMusicVolume(performance: model) },
                                              set: { control.setCurrentMusicVolume($0, performance: model) }), in: 0...1)
                            .accessibilityLabel(music.volumeLabel)
                        Text("\(Int((control.currentMusicVolume(performance: model) * 100).rounded()))%").font(.caption)
                    }.padding(16).frame(width: 240)
                }
            Menu {
                DailySoundtrackChoices(control: control, performance: model)
                Divider()
                PerformancePictureButton(model: model)
                if let id = model.currentSongID {
                    Button(model.isFavorite(id) ? "取消收藏" : "收藏歌曲") { model.toggleFavorite(id) }
                        .accessibilityIdentifier("music-favorite")
                }
                orderPicker
                Button("即将播放", action: showQueuePage)
                    .accessibilityIdentifier("music-open-queue")
                if model.sessionState.session != nil || model.queueState.isRunning {
                    Divider()
                    Button(model.sessionStopActionTitle, action: model.stop)
                        .accessibilityIdentifier("music-stop")
                }
            } label: { Label("音乐选项", systemImage: "ellipsis.circle") }
            .menuStyle(.borderlessButton).fixedSize()
            .accessibilityLabel("音乐选项")
        }
        .padding(.horizontal, 24).padding(.vertical, 14)
        .background(MusicWorkspaceAppearance.surface)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("音乐播放控制")
    }

    /// The real queue mode, using the existing order values. Changing it is a preference change on
    /// the saved queue; the current song keeps playing.
    private var orderPicker: some View {
        Picker("播放方式", selection: Binding(
            get: { model.queueState.configuration.order },
            set: { model.setQueueOrder($0) })) {
            ForEach([PerformanceQueueOrder.stopAfterQueue, .shuffle, .repeatAll, .repeatOne],
                    id: \.self) { order in
                Text(order.controlLabel).tag(order)
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .accessibilityLabel("播放方式")
        .accessibilityIdentifier("music-order")
        .help("改变播放方式只影响后续播放，不重启当前歌曲。")
    }

    private var symbolName: String {
        if model.sessionState.session != nil || model.queueState.isRunning {
            return model.sessionState.session?.mode == .listen ? "headphones" : "music.note"
        }
        return "circle.dotted"
    }

    private var title: String {
        if model.sessionState.session != nil {
            return model.sessionTitle ?? "当前音乐"
        }
        if model.queueState.isRunning {
            return model.queueState.activeEntry.map(model.queueEntryTitle) ?? "播放队列"
        }
        return music.title
    }

    private var subtitle: String {
        if model.sessionState.session == nil && !model.queueState.isRunning {
            return music.statusLine
        }
        return NotchMusicState.make(model).statusLine
    }
}


// MARK: - Menu-bar quick controls (candidate)

/// The candidate status item opens a small menu instead of the ordinary popover. These actions are
/// the approved quick set; every action delegates to the SAME model/IPC command the full window
/// uses, so the two surfaces cannot diverge. 进入全屏 is a presentation-only request: it is disabled
/// without an active watch session and never starts a song or changes the queue/pause state.
enum StatusQuickAction: String, CaseIterable, Hashable {
    case openWindow
    case enterFullScreen
    case toggleWallpaperPause
    case toggleMusicPause
    case quit

    var title: String {
        switch self {
        case .openWindow: return "打开 bsideyou"
        case .enterFullScreen: return "歌曲演奏视频"
        case .toggleWallpaperPause: return "暂停全部"
        case .toggleMusicPause: return "暂停音乐"
        case .quit: return "退出 bsideyou"
        }
    }
}

/// Pure projection of the candidate menu state. Built from the existing desired/session/queue
/// truth so the menu can never claim a state the app is not in, and testable without UI.
struct StatusQuickMenuState: Equatable {
    let wallpaperPaused: Bool
    let musicPauseAvailable: Bool
    let musicPaused: Bool
    /// True only while an active WATCH session exists (listen has no fullscreen presentation).
    let fullScreenAvailable: Bool
    let pictureExpanded: Bool
    let quitEnabled: Bool
    var companion: NotchMusicState? = nil

    static func make(wallpaperPaused: Bool, musicSessionPresent: Bool, musicSessionPaused: Bool,
                     queueRunning: Bool, watchSessionActive: Bool, pictureExpanded: Bool = false,
                     companion: NotchMusicState? = nil) -> StatusQuickMenuState {
        StatusQuickMenuState(
            wallpaperPaused: wallpaperPaused,
            musicPauseAvailable: musicSessionPresent || queueRunning || companion?.canPause == true,
            musicPaused: wallpaperPaused || musicSessionPaused || companion?.isPaused == true,
            fullScreenAvailable: watchSessionActive,
            pictureExpanded: pictureExpanded,
            quitEnabled: true,
            companion: musicSessionPresent || queueRunning ? nil : companion)
    }

    func title(for action: StatusQuickAction) -> String {
        switch action {
        case .openWindow: return StatusQuickAction.openWindow.title
        case .enterFullScreen: return pictureExpanded ? "关闭歌曲视频" : "歌曲演奏视频"
        case .toggleWallpaperPause: return wallpaperPaused ? "恢复全部" : "暂停全部"
        case .toggleMusicPause: return companion?.pauseTitle ?? (wallpaperPaused ? "恢复全部" : musicPaused ? "恢复音乐" : "暂停音乐")
        case .quit: return StatusQuickAction.quit.title
        }
    }

    func isEnabled(_ action: StatusQuickAction) -> Bool {
        switch action {
        case .openWindow: return true
        case .enterFullScreen: return fullScreenAvailable
        case .toggleWallpaperPause: return true
        case .toggleMusicPause: return musicPauseAvailable
        case .quit: return quitEnabled
        }
    }
}

/// Shared deliberate soundtrack choices. Existing song browsing remains a separate entry.
struct DailySoundtrackChoices: View {
    @ObservedObject var control: ControlCenterModel
    @ObservedObject var performance: PerformanceBrowserModel
    var body: some View {
        Button {
            control.selectDailySoundtrack(.silent, performance: performance)
        } label: {
            if control.desired.dailySoundtrack == .silent && performance.sessionState.session == nil {
                Label("无音乐", systemImage: "checkmark")
            } else { Text("无音乐") }
        }
        Menu("陪伴音轨") {
            ForEach(control.dailyAmbientTracks, id: \.id) { track in
                Button {
                    control.selectDailySoundtrack(.track(track.id), performance: performance)
                } label: {
                    if control.desired.dailySoundtrack == .track(track.id) {
                        Label(track.soundtrackTitle, systemImage: "checkmark")
                    } else { Text(track.soundtrackTitle) }
                }
            }
        }.disabled(control.dailyAmbientTracks.isEmpty)
    }
}
