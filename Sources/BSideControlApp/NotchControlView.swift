// BSideControlApp — bsideyou island: SwiftUI content.
//
// This is presentation only. It reuses the SHARED models the full window already uses
// (`ControlCenterModel`, `PerformanceBrowserModel`, `DailyBackgroundChooserModel`) and forwards the
// SAME commands; it owns no queue, no session, no selected version and no persisted field. The pure
// projections below read authoritative model values so a compact label can never claim a state the
// app is not in:
//   * `NotchMusicState` mirrors the shared music strip's title/status/action truth;
//   * `NotchBackgroundState` reads the existing scene/time summary and the guarded fullscreen
//     readiness (`watch` session only);
//   * `NotchQueueState` is a read-only projection of the existing queue (entries, order, active
//     entry, titles/status) so browsing can never recapture, reorder or start anything.
//
// `HomepageMusicCardState` supplies the eligible count, start row and the model refusal reason, and
// the model's STRUCTURED filter fields (`hasActiveLibraryFilters`) decide the compact 全部/已筛选
// wording, so the island's list actions can never offer something the library model would refuse and
// the scope label can never be guessed from a localized summary string.
//
// Shape: ONE transient island whose width comes from the selected proportion (Compact / Balanced /
// Wide) plus a left character region and a right control region. Every readable control and the
// sharp character artwork live BELOW the camera band: the window reserves the public hardware band
// above the island body, and on a display without a cutout one 28pt header row sits below the
// menu-bar edge. There are no nested dashboard cards, no fake artwork, no waveform and no progress.
// The CLOSED window is COMPLETELY INVISIBLE: its trigger is exactly the public cutout,
// or a small under-menubar region without a notch. Surface/artwork geometry
// remains separate from this hit target. No cover, wing, border or decorative notch is drawn.
//
// Surface (restored Scene reference, native SwiftUI only): ONE silhouette spanning the illustrative
// still, the native frost and the controls. The main body is composed horizontally — the SHARP
// character crop on the LEFT, the tinted frost and the controls on the RIGHT — with the pure-black
// camera reservation fading seamlessly into near-black green. The character is never blurred or
// dimmed; only the surrounding scene layer is blurred/tinted. The controls keep their existing panel
// fills, hairlines, hover/press shades, text colours, fonts, icons and spacing. There is no
// continuous hover tracking and no pointer-driven backdrop engine.
//
// Transition: the WINDOW frame is the only animated surface (`NotchPanelController`); the SwiftUI
// body is laid out at its page size and merely clipped by the moving surface, so titles and buttons
// never squash or reflow at intermediate window sizes. A page change or a proportion change resizes
// the one panel and the controller always animates back to the exact collapsed rectangle. The sharp
// character layer is deferred until the newest expansion frame has settled, so the earliest opening
// can never cut through the face. There is no competing implicit layout animation on `mode`, no
// custom spring/display-link engine and no polling. Reduce Motion snaps every transition.

import SwiftUI
import Combine
import BSideCore

// MARK: - Scene palette

/// The restored Scene reference reduced to a native palette. These are the ONLY colour values the
/// island draws with: the pure black camera reservation, the dark green paper the body settles
/// into, deep panel fills, ink/muted words, a quiet line edge, one restrained sage accent and one
/// small warm amber reflected light. Plain SwiftUI colours only — no asset, image, shader or WebGL
/// import. The illustrative stills are decoded separately (`NotchSceneArtwork`).
enum NotchPalette {
    /// The camera reservation: pure black through the reserved hardware band.
    static let surface = Color.black
    /// #101713 — near-black green the body starts from just below the camera band.
    static let bodyDeep = Color(red: 0x10 / 255, green: 0x17 / 255, blue: 0x13 / 255)
    /// #202b28 — dark green paper the body settles into at its rounded lower edge.
    static let paper = Color(red: 0x20 / 255, green: 0x2b / 255, blue: 0x28 / 255)
    /// #344438 — panel fill for the quiet controls.
    static let panel = Color(red: 0x34 / 255, green: 0x44 / 255, blue: 0x38 / 255)
    /// #e7ecdf — ink for the plain, readable words.
    static let ink = Color(red: 0xe7 / 255, green: 0xec / 255, blue: 0xdf / 255)
    /// #b9c6b2 — muted secondary words.
    static let muted = Color(red: 0xb9 / 255, green: 0xc6 / 255, blue: 0xb2 / 255)
    /// #415442 — hairline edge between layered surfaces.
    static let line = Color(red: 0x41 / 255, green: 0x54 / 255, blue: 0x42 / 255)
    /// #c7d5b4 — the one restrained sage accent.
    static let sage = Color(red: 0xc7 / 255, green: 0xd5 / 255, blue: 0xb4 / 255)
    /// #d9a05b — the small warm reflected light below the camera band.
    static let amber = Color(red: 0xd9 / 255, green: 0xa0 / 255, blue: 0x5b / 255)
}

/// Minimal observable holder for a control's decorative hover highlight. Plain `ObservableObject`
/// state is used deliberately: the CLT-only toolchain here cannot expand `@State`'s external SwiftUI
/// macro, so this decoration is carried by an observable object instead — the same pattern the
/// existing ControlApp views use for their presentation state. It owns no model, no command and no
/// persisted field; it only answers "is the pointer over this control".
private final class NotchHoverState: ObservableObject {
    @Published var hovering = false
}

/// Authoritative, read-only music projection for the island.
struct NotchMusicState: Equatable {
    let title: String
    /// ONLY a meaningful runtime state (waiting / loading / paused / failed). The routine playback
    /// mode, camera material and daypart labels are deliberately not repeated here: the current song
    /// is shown once, while a genuine loading/error state is still reported instead of hidden.
    let status: String
    let symbolName: String
    /// True while a session exists or the saved queue is running: the only time transport is live.
    let isActive: Bool
    let isPaused: Bool
    /// Full authoritative pause/resume wording (accessibility/help + tooltip).
    let pauseTitle: String
    /// Full authoritative stop wording (accessibility/help); the compact button is icon-led.
    let stopTitle: String
    var isFavorite = false
    var canFavorite = false
    var canPrevious = false
    var canPause = false
    var volumeLabel: String { isActive ? "音乐音量" : "陪伴音乐音量" }

    /// Icon for the pause/resume control: pause while running, play while paused.
    var pauseSymbol: String { isPaused ? "play.fill" : "pause.fill" }
    /// Secondary line. Empty when there is nothing meaningful to add, so the compact island never
    /// repeats the song or a routine playing summary.
    var statusLine: String { status }

    static func make(_ model: PerformanceBrowserModel, control: ControlCenterModel? = nil) -> NotchMusicState {
        let session = model.sessionState.session
        let queueRunning = model.queueState.isRunning
        let active = session != nil || queueRunning
        if !active, let control {
            var state = NotchMusicState(title: control.dailyMusicTitle, status: control.dailyMusicStatus,
                symbolName: "music.note", isActive: false,
                isPaused: control.desired.paused || control.desired.dailyMusicPaused,
                pauseTitle: control.dailyMusicPauseActionTitle, stopTitle: model.sessionStopActionTitle)
            state.canPause = control.dailyMusicPauseAvailable
            return state
        }
        let symbol: String
        if active {
            symbol = session?.mode == .listen ? "headphones" : "music.note"
        } else {
            symbol = "circle.dotted"
        }
        let title: String
        if session != nil {
            title = model.sessionTitle ?? "当前音乐"
        } else if queueRunning {
            title = model.queueState.activeEntry.map(model.queueEntryTitle) ?? "播放队列"
        } else {
            title = "音乐未播放"
        }
        var state = NotchMusicState(title: title,
                               status: runtimeStatus(model, session: session, queueRunning: queueRunning),
                               symbolName: symbol, isActive: active,
                               isPaused: model.primaryMusicIsPaused,
                               pauseTitle: model.sessionPauseActionTitle,
                               stopTitle: model.sessionStopActionTitle)
        state.canPause = active
        state.canPrevious = model.canPreviousSong
        state.canFavorite = model.currentSongID != nil
        state.isFavorite = model.currentSongID.map(model.isFavorite) ?? false
        return state
    }

    /// The one meaningful runtime state, read from the STRUCTURED session/report fields (never parsed
    /// out of a localized label). Routine `playing`/`ended`/`stopped` add nothing, so they return an
    /// empty string; a wait, load, explicit pause or failure is still surfaced.
    private static func runtimeStatus(_ model: PerformanceBrowserModel,
                                      session: PerformanceSession?,
                                      queueRunning: Bool) -> String {
        if queueRunning, session == nil || model.queueState.activeSessionID != session?.id {
            return "正在切换"
        }
        guard let session else { return "" }
        guard let report = model.report, report.sessionID == session.id else {
            return "准备中"
        }
        switch report.state {
        case .loading: return "加载中"
        case .paused: return "已暂停"
        case .failed: return "播放失败"
        case .playing, .ended, .stopped: return ""
        }
    }
}

/// Read-only background projection: the authoritative daypart summary from the same Control Center
/// truth, the guarded fullscreen readiness the quick menu already uses, and the EXISTING pending
/// switch message. The material-group / daily-version display names are deliberately not restated:
/// they are implementation identities, not product words for this surface.
struct NotchBackgroundState: Equatable {
    let timeSummary: String
    /// True only while an active WATCH session exists (listen has no fullscreen presentation).
    let fullScreenAvailable: Bool
    /// The existing `ControlCenterModel.dailySwitchMessage`: non-nil only while the runtime snapshot
    /// really shows a pending switch/refresh/transition. The island never invents a timer or a
    /// persistent pending flag of its own.
    let pendingSwitchMessage: String?

    /// Concise tooltip for the song title's presentation-only fullscreen re-entry. Empty when no
    /// watch session can re-enter, so the island never advertises an inert action.
    var fullScreenActionHelp: String { fullScreenAvailable ? "双击进入全屏。" : "" }

    /// Accessibility action name for the current song title's fullscreen affordance.
    static let fullScreenActionLabel = "进入全屏"

    static func make(_ model: ControlCenterModel, performance: PerformanceBrowserModel) -> NotchBackgroundState {
        NotchBackgroundState(
            timeSummary: model.subtitle,
            fullScreenAvailable: performance.sessionState.session?.mode == .watch,
            pendingSwitchMessage: model.dailySwitchMessage)
    }
}

/// Read-only idle list projection for the island. It reuses `HomepageMusicCardState` for the
/// eligible count / start row / model refusal reason, and reads the model's STRUCTURED filter fields
/// (`hasActiveLibraryFilters`) to decide the compact 全部/已筛选 wording, so this can never be guessed
/// from a localized summary string. The exact summary stays available for help/AX.
struct NotchListScopeState: Equatable {
    let isFiltered: Bool
    let eligibleCount: Int
    let filterSummary: String
    let startRow: String
    let canPlaySelected: Bool
    let canShuffle: Bool
    let unavailableReason: String?

    /// Compact visible scope shown beside the idle list actions.
    var compactLabel: String { "\(isFiltered ? "已筛选" : "全部") · \(eligibleCount) 首" }

    static func make(_ model: PerformanceBrowserModel, includeDetails: Bool = true) -> NotchListScopeState {
        guard includeDetails else {
            return NotchListScopeState(isFiltered: false, eligibleCount: 0, filterSummary: "",
                                       startRow: "", canPlaySelected: false, canShuffle: false,
                                       unavailableReason: nil)
        }
        let card = HomepageMusicCardState.make(model)
        return NotchListScopeState(isFiltered: model.hasActiveLibraryFilters,
                                   eligibleCount: card.eligibleCount,
                                   filterSummary: card.filterSummary,
                                   startRow: card.startRow,
                                   canPlaySelected: card.canPlaySelected,
                                   canShuffle: card.canShuffle,
                                   unavailableReason: card.unavailableReason)
    }
}

/// Read-only projection of the existing queue. It reads the same configuration the queue page shows
/// and exposes no mutation: browsing the island can never recapture, reorder or start a queue entry.
struct NotchQueueState: Equatable {
    struct Row: Equatable, Identifiable {
        let id: String
        let title: String
        /// Existing per-entry status while this entry is the running one, else nil.
        let status: String?
        /// True for the entry the queue is currently playing.
        let isActive: Bool
        let isSelected: Bool
        /// True only while the exact entry can start right now (explicit play would be accepted).
        let canPlay: Bool
    }

    let rows: [Row]
    let orderLabel: String
    let order: PerformanceQueueOrder
    let isRunning: Bool
    let emptyMessage: String?

    var isEmpty: Bool { rows.isEmpty }

    static func make(_ model: PerformanceBrowserModel, includeRows: Bool = true) -> NotchQueueState {
        let entries = model.queueState.configuration.entries
        let activeID = model.queueState.activeEntry?.id
        let rows = (includeRows ? entries : []).map { entry -> Row in
            let problem = model.selectedQueuePlaybackProblemForEntry(entry)
            return Row(id: entry.id,
                       title: model.queueEntryTitle(entry),
                       status: model.queueEntryStatus(entry),
                       isActive: activeID == entry.id,
                       isSelected: model.selectedQueueEntryID == entry.id,
                       canPlay: problem == nil)
        }
        return NotchQueueState(rows: rows,
                               orderLabel: model.queueState.configuration.order.controlLabel,
                               order: model.queueState.configuration.order,
                               isRunning: model.queueState.isRunning,
                               emptyMessage: entries.isEmpty
                                   ? "播放队列为空。可在完整窗口的曲库中加入曲目。"
                                   : nil)
    }
}

/// Every island control forwards to an existing model command through this struct. AppDelegate
/// builds it from the same models/closures the full window and the status quick menu use, so the
/// island cannot diverge from them. `toggle`/`collapse`/page navigation are presentation-only.
struct NotchControlActions {
    var pauseOrResumeMusic: () -> Void = {}
    var previous: () -> Void = {}
    var next: () -> Void = {}
    var stop: () -> Void = {}
    var toggleFavorite: () -> Void = {}
    var setMusicVolume: (Double) -> Void = { _ in }
    var playList: () -> Void = {}
    var shuffle: () -> Void = {}
    var chooseSongs: () -> Void = {}
    /// Open the island's own queue page (presentation only; never recaptures or starts).
    var openQueuePage: () -> Void = {}
    var setQueueOrder: (PerformanceQueueOrder) -> Void = { _ in }
    /// Open the island's own background page (presentation only; apply stays explicit).
    var openBackgroundPage: () -> Void = {}
    /// Back to the compact main island page.
    var showMainPage: () -> Void = {}
    /// Explicitly start one existing queue entry through the existing owner path.
    var playQueueEntry: (String) -> Void = { _ in }
    /// Explicit pause/resume from a secondary page (the same shared session command).
    var toggleGlobalPause: () -> Void = {}
    var enterFullScreen: () -> Void = {}
    var openFullWindow: () -> Void = {}
    var toggle: () -> Void = {}
    var collapse: () -> Void = {}
}

/// `PerformanceQueueView` already owns the authoritative "can this exact entry start?" question, but
/// its selected-entry form reads the window's transient selection. The island asks the same question
/// for a row it may not have selected yet, through the same shared model checks.
extension PerformanceBrowserModel {
    func selectedQueuePlaybackProblemForEntry(_ entry: PerformanceQueueEntry) -> String? {
        if let problem = queueEntryUnavailableReason(entry) { return problem }
        switch entry.target {
        case .official(let performanceID, let presentation):
            return playbackProblem(id: performanceID.rawValue, presentation: presentation)
        case .localFile(let trackID, let fileID):
            guard let track = localTrack(trackID) else { return "曲目不在当前记录中，条目仍保留在队列中。" }
            guard track.files.contains(where: { $0.id == fileID }) else {
                return "队列保存的文件不再存在，条目仍保留在队列中。"
            }
            return localSelectionProblem(track)
        }
    }
}

/// Notch silhouette: the top corners flare outward into the menu bar so the shape reads as an
/// extension of the hardware shoulders, and the bottom corners are rounded inward. The geometry
/// below is a narrow adaptation of Atoll's `NotchShape` (MIT, commit ea20f5541bb9ae8c300b20fb99a7b48665adb158,
/// `Sources/Atoll/UI/NotchShape.swift`); see `THIRD_PARTY_NOTICES.md` for the exact mapping and the
/// complete license. Differences from upstream: both radii are parameterized from
/// `NotchPanelGeometry` (20pt corners / 10pt top flare), every radius is clamped to the rect it is
/// given (top by half the width AND half the height, bottom leaving a non-negative straight edge) so
/// a tiny collapsed silhouette cannot self-intersect or extend past its own window, and
/// `animatableData` is deliberately NOT adopted because the window frame is the only animated surface
/// (one bounded geometry transition, no shape animation).
struct NotchShape: Shape {
    var bottomCornerRadius: CGFloat = NotchPanelGeometry.cornerRadius
    var topCornerRadius: CGFloat = NotchPanelGeometry.topCornerRadius

    func path(in rect: CGRect) -> Path {
        // Radii are clamped to the rect: the top radius must leave at least half the width for the
        // flat top edge AND must fit in half the height. The no-notch grab region is only 120x6, so
        // without the height clamp the 10pt top flare would extend to y=10 inside a 6pt-tall window.
        // The bottom radius then leaves a non-negative straight side edge and bottom edge. This keeps
        // every silhouette a valid, non-self-intersecting path that stays inside its window frame.
        let top = max(0, min(min(topCornerRadius, rect.width / 2), rect.height / 2))
        let bottom = max(0, min(bottomCornerRadius, rect.width / 2 - top, rect.height / 2))
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        // Top-left outward flare.
        path.addQuadCurve(to: CGPoint(x: rect.minX + top, y: rect.minY + top),
                          control: CGPoint(x: rect.minX + top, y: rect.minY))
        // Left edge.
        path.addLine(to: CGPoint(x: rect.minX + top, y: rect.maxY - bottom))
        // Bottom-left rounded corner.
        let curve = bottom * 0.5522847498
        path.addCurve(to: CGPoint(x: rect.minX + top + bottom, y: rect.maxY),
                      control1: CGPoint(x: rect.minX + top, y: rect.maxY - bottom + curve),
                      control2: CGPoint(x: rect.minX + top + bottom - curve, y: rect.maxY))
        // Bottom edge.
        path.addLine(to: CGPoint(x: rect.maxX - top - bottom, y: rect.maxY))
        // Bottom-right rounded corner.
        path.addCurve(to: CGPoint(x: rect.maxX - top, y: rect.maxY - bottom),
                      control1: CGPoint(x: rect.maxX - top - bottom + curve, y: rect.maxY),
                      control2: CGPoint(x: rect.maxX - top, y: rect.maxY - bottom + curve))
        // Right edge.
        path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY + top))
        // Top-right outward flare.
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                          control: CGPoint(x: rect.maxX - top, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

/// One tactile control surface: a quiet panel fill, a hairline edge, an inset top highlight and a
/// thin press shade, with a short FINITE ease between rest, hover and press. Presentation chrome
/// only — the wrapped control still owns its label, identifier, help, accessibility and exact 28pt
/// hit geometry, and nothing here moves or resizes the control. The decoration layers are excluded
/// from hit testing so they can never intercept the button's own click.
private struct NotchControlSurface<Label: View>: View {
    var disabled: Bool = false
    var highlighted: Bool = false
    var pressed: Bool = false
    @ViewBuilder var label: Label
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var hover = NotchHoverState()

    private var showsLight: Bool { !disabled && (hover.hovering || pressed) }

    private var fill: Color {
        if disabled { return NotchPalette.panel.opacity(0.10) }
        if highlighted { return NotchPalette.sage.opacity(0.85) }
        if pressed { return NotchPalette.bodyDeep.opacity(0.95) }
        if hover.hovering { return NotchPalette.panel.opacity(0.62) }
        return NotchPalette.panel.opacity(0.34)
    }

    private var edge: Color {
        if disabled { return NotchPalette.line.opacity(0.45) }
        if highlighted { return NotchPalette.sage }
        return NotchPalette.line.opacity(showsLight ? 1 : 0.8)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        label
            .frame(height: NotchPanelGeometry.minimumControlSize)
            .background(shape.fill(fill))
            .overlay(shape.strokeBorder(edge, lineWidth: 1).allowsHitTesting(false))
            .overlay(alignment: .top) {
                // Inset top highlight: the one "lit from above" cue that makes the pill read as a
                // physical key instead of a flat rectangle. Static geometry, never animated.
                shape
                    .strokeBorder(
                        LinearGradient(colors: [NotchPalette.ink.opacity(disabled ? 0.06 : 0.14), .clear],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 1)
                    .opacity(disabled ? 0.5 : 1)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) {
                if pressed {
                    shape.strokeBorder(NotchPalette.bodyDeep.opacity(0.9), lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(shape)
            .onHover { hover.hovering = !disabled && $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hover.hovering)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.07), value: pressed)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: highlighted)
    }
}

/// Button-style wrapper so the tactile surface can read the real pressed state without changing the
/// button's label, action or hit geometry.
private struct NotchTactileButtonStyle: ButtonStyle {
    var disabled: Bool = false
    var highlighted: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        NotchControlSurface(disabled: disabled, highlighted: highlighted,
                            pressed: configuration.isPressed) {
            configuration.label
        }
    }
}

/// One compact icon control. 28pt minimum hit/edge and never below the 11pt readable text minimum.
private struct NotchIconButton: View {
    let symbol: String
    let id: String
    let label: String
    let help: String
    var disabled: Bool = false
    var highlighted: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: NotchPanelGeometry.minimumControlSize,
                       height: NotchPanelGeometry.minimumControlSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(NotchTactileButtonStyle(disabled: disabled, highlighted: highlighted))
        .disabled(disabled)
        .accessibilityIdentifier(id)
        .accessibilityLabel(label)
        .help(help)
    }

    /// Ink on the quiet panel fills; the dark body colour only while the control itself is the
    /// highlighted/on state, where the sage fill is bright enough to need dark type.
    private var iconColor: Color {
        if disabled { return NotchPalette.muted.opacity(0.38) }
        if highlighted { return NotchPalette.bodyDeep.opacity(0.9) }
        return NotchPalette.ink.opacity(0.92)
    }
}

/// One compact labelled control (icon + ordinary Chinese words) in the same 28pt row.
private struct NotchLabelButton: View {
    let symbol: String
    let text: String
    let id: String
    let label: String
    let help: String
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                Text(text).font(.system(size: NotchPanelGeometry.minimumTextSize)).lineLimit(1)
            }
            .foregroundStyle(disabled ? NotchPalette.muted.opacity(0.38) : NotchPalette.ink.opacity(0.92))
            .padding(.horizontal, 8)
            .frame(height: NotchPanelGeometry.minimumControlSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(NotchTactileButtonStyle(disabled: disabled))
        .disabled(disabled)
        .accessibilityIdentifier(id)
        .accessibilityLabel(label)
        .help(help)
    }
}

/// Shared 28pt label for the two small review menus (proportion and illustrative scene). It never
/// grows or moves, and it keeps the same quiet panel fill as the other controls.
private struct NotchMenuLabel: View {
    let symbol: String
    var active: Bool = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(NotchPalette.ink.opacity(0.92))
            .frame(width: NotchPanelGeometry.minimumControlSize,
                   height: NotchPanelGeometry.minimumControlSize)
            .background(shape.fill(NotchPalette.panel.opacity(active ? 0.62 : 0.34)))
            .overlay(shape.strokeBorder(NotchPalette.line.opacity(0.8), lineWidth: 1)
                .allowsHitTesting(false))
            .contentShape(shape)
    }
}

/// Small review menu for the three transient lateral proportions. Selecting one changes the ACTUAL
/// window geometry through the controller's generation-safe animator; it is presentation only and
/// is never persisted.
private struct NotchOptionsMenu: View {
    @ObservedObject var profileModel: NotchIslandProfileModel
    @ObservedObject var sceneModel: NotchSceneChoiceModel

    var body: some View {
        Menu {
            Menu("主题") {
                Button { sceneModel.preview(hour: nil) } label: {
                    Label("自动切换", systemImage: sceneModel.previewHour == nil ? "checkmark" : "clock")
                }
                Divider()
                Button("早上") { sceneModel.preview(hour: sceneModel.schedule.morning) }
                Button("午后") { sceneModel.preview(hour: sceneModel.schedule.afternoon) }
                Button("夜晚") { sceneModel.preview(hour: sceneModel.schedule.evening) }
            }
            Menu("浮窗宽度") {
                ForEach(NotchIslandProfile.allCases) { profile in
                    Button { profileModel.select(profile) } label: {
                        if profile == profileModel.profile {
                            Label(profile.displayName, systemImage: "checkmark")
                        } else {
                            Text(profile.displayName)
                        }
                    }
                }
            }
            Menu("切换时间") {
                boundaryMenu("早上", value: sceneModel.schedule.morning, keyPath: \.morning,
                             hours: Array(0..<sceneModel.schedule.afternoon))
                boundaryMenu("午后", value: sceneModel.schedule.afternoon, keyPath: \.afternoon,
                             hours: Array((sceneModel.schedule.morning + 1)..<sceneModel.schedule.evening))
                boundaryMenu("夜晚", value: sceneModel.schedule.evening, keyPath: \.evening,
                             hours: Array((sceneModel.schedule.afternoon + 1)..<24))
                Button("恢复默认时间") { sceneModel.setSchedule(.init()) }
            }
        } label: {
            NotchMenuLabel(symbol: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityIdentifier("notch-options-menu")
        .accessibilityLabel("浮窗选项")
        .help("主题、宽度与切换时间。")
    }

    private func boundaryMenu(_ title: String, value: Int,
                              keyPath: WritableKeyPath<NotchSceneSchedule, Int>, hours: [Int]) -> some View {
        Menu("\(title) \(String(format: "%02d:00", value))") {
            ForEach(hours, id: \.self) { hour in
                Button(String(format: "%02d:00", hour)) {
                    var schedule = sceneModel.schedule
                    schedule[keyPath: keyPath] = hour
                    sceneModel.setSchedule(schedule)
                }
            }
        }
    }
}

/// A quiet hover/active tint for a non-button row (queue entries). Decorative only: it sits behind
/// the row content, changes no geometry and adds no hit region of its own.
private struct NotchRowTint<Content: View>: View {
    var active: Bool
    @ViewBuilder var content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var hover = NotchHoverState()

    var body: some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(active ? NotchPalette.panel.opacity(0.34)
                                 : (hover.hovering ? NotchPalette.panel.opacity(0.20) : Color.clear))
                    .allowsHitTesting(false)
            )
            .onHover { hover.hovering = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hover.hovering)
    }
}

/// The island's single root view. Its window frame is animated by `NotchPanelController` between the
/// exact collapsed/expanded geometries, so the island grows out of the compact cover silhouette and
/// the resting state on a notched display is one solid black cover around the hardware.
struct NotchPanelRootView: View {
    @ObservedObject var presentation: NotchPanelPresentation
    @ObservedObject var pageModel: NotchIslandPageModel
    @ObservedObject var controlCenter: ControlCenterModel
    @ObservedObject var performance: PerformanceBrowserModel
    @ObservedObject var study: StudyTimerController
    @ObservedObject var backgrounds: DailyBackgroundChooserModel
    /// Display summary from the geometry seam (band height, page size, closed policy).
    let layout: NotchShelfLayout
    let actions: NotchControlActions

    var studyActions = StudyTimerActions()

    private var music: NotchMusicState { NotchMusicState.make(performance, control: controlCenter) }

    var body: some View {
        ZStack(alignment: .top) {
            // The resting surface is ALWAYS present and is exactly the window's bounds: the
            // collapsed silhouette is COMPLETELY INVISIBLE on every display, so the window is an
            // invisible hover/tap trigger inside the exact cutout (or the under-menubar target
            // without a notch). This transparent layer draws nothing.
            collapsedSurface
            // The visible island is rendered while expanded AND through the whole closing
            // transition, so the surface really retracts into the cover instead of disappearing at
            // the first frame. It is removed only once the newest COLLAPSED frame has settled
            // (`presentation.surfaceIsVisible`), and a reopen during the transition invalidates that
            // hide. The view is pinned to the FULL expanded size and merely clipped by the shrinking
            // window, so titles and controls never reflow mid-transition.
            if presentation.surfaceIsVisible {
                expandedIsland
            }
        }
        // Accept the animated viewport, even below the full island content size.
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        .foregroundStyle(NotchPalette.ink)
        // Expansion/collapse hover belongs to the persistent AppKit viewport tracking area.
        // Content insertion/removal and per-control highlights cannot supply a second owner.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("bsideyou 浮窗控制")
    }

    // MARK: - Collapsed (compact cover / transparent fallback)

    /// The resting surface, exactly the window's own bounds so the hit region is the invisible
    /// hit target. `closedSilhouetteOpacity` is 0 on every display, so no
    /// artwork, wing, cover, border, gradient or glow is drawn at rest; the clear shape is kept only
    /// so the cutout or no-notch fallback receives hover and explicit clicks.
    private var collapsedSurface: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                Group {
                    if layout.closedSilhouetteOpacity > 0 {
                        NotchPalette.surface
                            .clipShape(NotchShape(bottomCornerRadius: layout.cornerRadius))
                    }
                }
            )
            .contentShape(Rectangle())
            .onTapGesture { actions.toggle() }
            .accessibilityIdentifier("notch-collapsed")
            .accessibilityLabel(music.isActive
                                ? "bsideyou 浮窗，正在播放：\(music.title)。单击展开"
                                : "bsideyou 浮窗。单击展开")
            .help("单击展开控制面板；指向硬件缺口也会临时展开。")
    }

    // MARK: - Expanded

    private var expandedIsland: some View {
        ZStack(alignment: .top) {
            // ONE silhouette: the blurred/tinted scene background may span the whole body, the
            // SHARP character crop is restricted to the left region with a soft fade to the right,
            // and real native frost sits under the tinted control-side material. The camera
            // reservation stays pure black. The sharp layer is empty until the expansion frame has
            // settled, so the earliest opening can never cut through the face.
            NotchTimedSceneSurface(model: presentation.sceneModel, layout: layout,
                                   sharpRevealed: presentation.sharpArtworkIsVisible)
            NotchIslandContent(presentation: presentation,
                               page: layout.page,
                               controlCenter: controlCenter,
                               music: music,
                               study: study,
                               studyActions: studyActions,
                               performance: performance,
                               queue: NotchQueueState.make(performance, includeRows: layout.page == .queue),
                               listScope: NotchListScopeState.make(performance,
                                   includeDetails: layout.page == .main && !music.isActive),
                               backgroundState: NotchBackgroundState.make(controlCenter, performance: performance),
                               musicVolume: controlCenter.currentMusicVolume(performance: performance),
                               paused: controlCenter.desired.paused,
                               backgrounds: backgrounds,
                               layout: layout,
                               actions: actions)
        }
        // The fixed layout size is the FINAL expanded size for the current page. The window frame is
        // the only animated surface, so the whole silhouette — scene, character, frost and controls —
        // is laid out once at its final size and merely CLIPPED by the moving window: nothing scales,
        // reflows or squashes at intermediate sizes.
        .frame(width: layout.expandedSize.width, height: layout.expandedSize.height,
               alignment: .top)
        // Top-CENTER: the window is top-center anchored and grows symmetrically, so the content
        // stays put on screen while the island opens out of the hidden cutout trigger.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipShape(NotchShape(bottomCornerRadius: layout.cornerRadius))
        .contentShape(NotchShape(bottomCornerRadius: layout.cornerRadius))
        // Restrained static exterior shadow once the silhouette is really open; no continuous
        // motion, no pointer tracking.
        .shadow(color: .black.opacity(presentation.sharpArtworkIsVisible ? 0.32 : 0),
                radius: 10, y: 4)
        .accessibilityIdentifier("notch-expanded")
    }
}

/// The expanded island body for one page. Split from `NotchPanelRootView` so the collapsed/expanded
/// branch stays small and so the body's layout inputs are explicit values.
private struct NotchIslandContent: View {
    @ObservedObject var presentation: NotchPanelPresentation
    let page: NotchIslandPage
    @ObservedObject var controlCenter: ControlCenterModel
    let music: NotchMusicState
    @ObservedObject var study: StudyTimerController
    let studyActions: StudyTimerActions
    @ObservedObject var performance: PerformanceBrowserModel
    let queue: NotchQueueState
    /// Shared model projection for the list actions (structured 全部/已筛选 scope, eligible count,
    /// exact filter summary and start row).
    let listScope: NotchListScopeState
    let backgroundState: NotchBackgroundState
    let musicVolume: Double
    let paused: Bool
    @ObservedObject var backgrounds: DailyBackgroundChooserModel
    let layout: NotchShelfLayout
    let actions: NotchControlActions
    @Environment(\.displayScale) private var displayScale

    /// Reserved top strip: exactly the public hardware band on a notched display (so every readable
    /// control starts at the band's lower edge) or the 28pt below-menu-bar header row otherwise.
    private var reservedBand: CGFloat { layout.reservedBandHeight }
    private var bodyHeight: CGFloat { layout.bodyHeight }
    private var verticalPadding: CGFloat { layout.bodyVerticalPadding / 2 }
    /// Left region reserved for the sharp character artwork (main page only). The controls never
    /// overlap it, so no face/head is ever covered by a control.
    private var characterReserve: CGFloat {
        layout.showsCharacterImage ? layout.characterRegionWidth : 0
    }
    /// Horizontal padding inside the control region.
    private var controlPadding: CGFloat {
        page == .main ? NotchPanelGeometry.mainControlPadding : NotchPanelGeometry.horizontalBodyPadding
    }
    /// Width left for controls on the right of the body.
    private var controlWidth: CGFloat {
        max(0, layout.expandedSize.width - characterReserve)
    }

    var body: some View {
        VStack(spacing: 0) {
            // The pure-black camera reservation (drawn by `NotchSceneSurface`) covers this strip, so
            // nothing readable is ever placed in the hardware band.
            Color.clear.frame(height: reservedBand)
            HStack(spacing: 0) {
                Color.clear.frame(width: characterReserve).allowsHitTesting(false)
                content
                    .padding(.horizontal, controlPadding)
                    // The outward shoulder leaves an inward body edge on both sides.
                    .padding(.trailing, NotchPanelGeometry.topCornerRadius)
                    .padding(.leading, page == .main ? 0 : NotchPanelGeometry.topCornerRadius)
                    .padding(.vertical, verticalPadding)
                    .frame(width: controlWidth,
                           height: bodyHeight,
                           alignment: .top)
            }
            .frame(height: bodyHeight)
        }
        .frame(width: layout.expandedSize.width,
               height: layout.expandedSize.height,
               alignment: .top)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case .main: mainPage
        case .queue: queuePage
        case .background: backgroundPage
        }
    }

    // MARK: - Header (secondary pages only)

    /// Secondary-page header: back to the compact main island, Home and close. Always
    /// drawn below the hardware band, so no control can overlap the camera. The MAIN page draws no
    /// header at all: its title row already carries the trailing close control, and there is no pin
    /// control anywhere in the island (the pin state machine stays available to the presentation
    /// seam, but no page renders a pin button).
    private func pageHeader() -> some View {
        HStack(spacing: 6) {
            Image(systemName: music.isActive ? music.symbolName : "music.note")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(NotchPalette.sage.opacity(0.85))
                .accessibilityHidden(true)
            Text(pageLabel)
                .font(.system(size: NotchPanelGeometry.minimumTextSize, weight: .medium))
                .foregroundStyle(NotchPalette.muted)
                .lineLimit(1)
                .accessibilityLabel(pageLabel)
            Spacer(minLength: 8)
            NotchIconButton(symbol: "chevron.backward", id: "notch-page-back",
                            label: "返回音乐浮窗", help: "返回。",
                            action: actions.showMainPage)
            homeButton
            NotchIconButton(symbol: "xmark", id: "notch-close", label: "收起浮窗",
                            help: "收起浮窗（Esc）。") { actions.collapse() }
        }
        .frame(height: NotchPanelGeometry.headerHeight)
    }

    private var pageLabel: String {
        switch page {
        case .main: return "bsideyou"
        case .queue: return "播放队列"
        case .background: return "选择陪伴视频"
        }
    }

    // MARK: - Main page: ONE compact music island

    /// The compact main surface. Its FOUR rows are exactly `NotchPanelGeometry.mainPageRowHeights`
    /// (title + close, transport/volume, navigation/context, shared timer), so the panel's body height is the true
    /// sum of what it draws plus its own padding instead of a too short constant. There is no
    /// separate scope row: the idle list scope is a compact 全部/已筛选 count beside the idle actions,
    /// and the exact filter stays in help/AX.
    private var mainPage: some View {
        VStack(alignment: .leading, spacing: NotchPanelGeometry.mainRowGap) {
            titleRow
            transportRow
            navigationRow
            inlineStudyRow
        }
    }

    /// Authoritative song title with the trailing 28pt close control, shown ONCE. A meaningful
    /// wait/loading/pause/failure state is appended; the routine playing/camera/daypart summary is
    /// deliberately not repeated here. No artwork, no waveform and no fabricated progress. The
    /// title may truncate (tail) but the close control is a fixed 28pt edge, so it always stays
    /// visible and reachable.
    ///
    /// The title also carries the owner's presentation-only fullscreen re-entry: a double-click (or
    /// the explicit accessibility action) forwards to the SAME guarded `enterFullScreen` action the
    /// menu-bar quick control and the background page already use, so it is inert without a live
    /// watch session and duplicate gestures during a transition stay harmless in that owner path.
    /// No playback, queue, selection or pause state is touched, and the copy/font/row layout are
    /// unchanged; only a concise tooltip and accessibility action make the affordance discoverable.
    private var titleRow: some View {
        HStack(alignment: .center, spacing: 6) {
            Image(systemName: music.isActive ? music.symbolName : "music.note")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(NotchPalette.sage.opacity(0.85))
                .accessibilityHidden(true)
            titleLabel
            if !music.statusLine.isEmpty {
                Text(music.statusLine)
                    .font(.system(size: NotchPanelGeometry.minimumTextSize))
                    .foregroundStyle(NotchPalette.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityIdentifier("notch-music-status")
                    .accessibilityLabel(music.statusLine)
            }
            Spacer(minLength: 6)
            homeButton
            NotchOptionsMenu(profileModel: presentation.profileModel,
                             sceneModel: presentation.sceneModel)
            NotchIconButton(symbol: "xmark", id: "notch-close", label: "收起浮窗",
                            help: "收起浮窗（Esc）。", action: actions.collapse)
        }
        .frame(height: NotchPanelGeometry.titleRowHeight)
    }

    /// The owner reuses the main window and collapses this panel without changing playback.
    private var homeButton: some View {
        NotchIconButton(symbol: "house", id: "notch-home", label: "打开主页",
                        help: "打开主页，继续当前播放。", action: actions.openFullWindow)
    }

    /// The title label plus its optional, honest discoverability affordance. The double-click is
    /// always attached (the guarded owner action makes it inert when unavailable), while the
    /// tooltip and accessibility action appear only while a watch session can really re-enter.
    @ViewBuilder
    private var titleLabel: some View {
        if backgroundState.fullScreenAvailable {
            titleText
                .accessibilityAction(named: Text(NotchBackgroundState.fullScreenActionLabel)) {
                    actions.enterFullScreen()
                }
                .help(backgroundState.fullScreenActionHelp)
        } else {
            titleText
        }
    }

    private var titleText: some View {
        Text(music.title)
            .font(.system(size: 13, weight: .medium))
            .lineLimit(1)
            .truncationMode(.tail)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { actions.enterFullScreen() }
            .accessibilityIdentifier("notch-music-title")
            .accessibilityLabel(music.title)
    }

    /// Authoritative transport plus the music volume, in ONE 28pt row: pause/resume, next, stop, the
    /// existing `ControlCenterModel` music-volume setter. Its short, quiet slider leaves the scene
    /// dominant; the exact percentage stays in its tooltip and native accessibility value. Transport
    /// selects the existing song or companion soundtrack; neither changes picture playback.
    private var transportRow: some View {
        HStack(spacing: 6) {
            NotchIconButton(symbol: "backward.end.fill", id: "notch-music-previous", label: "上一首",
                            help: "播放上一首已播放的歌曲，从头开始。",
                            disabled: !music.canPrevious, action: actions.previous)
            NotchIconButton(symbol: music.pauseSymbol, id: "notch-music-pause",
                            label: music.pauseTitle, help: music.pauseTitle,
                            disabled: !music.canPause,
                            action: actions.pauseOrResumeMusic)
            NotchIconButton(symbol: "forward.end.fill", id: "notch-music-next", label: "下一首",
                            help: "下一首。",
                            disabled: !music.isActive, action: actions.next)
            NotchIconButton(symbol: "stop.fill", id: "notch-music-stop", label: music.stopTitle,
                            help: music.stopTitle,
                            disabled: !music.isActive, action: actions.stop)
            NotchIconButton(symbol: music.isFavorite ? "heart.fill" : "heart",
                            id: "notch-music-favorite", label: music.isFavorite ? "取消收藏" : "收藏歌曲",
                            help: music.isFavorite ? "取消收藏" : "收藏歌曲",
                            disabled: !music.canFavorite, action: actions.toggleFavorite)
            Menu {
                DailySoundtrackChoices(control: controlCenter, performance: performance)
                Divider()
                Button("选择歌曲…", action: actions.chooseSongs)
            } label: { Image(systemName: "speaker.wave.2.fill") }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel("选择音乐")
                .font(.system(size: 11))
                .foregroundStyle(NotchPalette.muted.opacity(0.60))
            Slider(value: Binding(get: { musicVolume }, set: { actions.setMusicVolume($0) }),
                   in: 0...1)
                .controlSize(.mini)
                .frame(width: 64)
                .tint(NotchPalette.muted.opacity(0.55))
                .accessibilityIdentifier("notch-music-volume")
                .accessibilityLabel(music.volumeLabel)
                .help("\(music.volumeLabel)：\(Int((musicVolume * 100).rounded()))%。")
        }
        .frame(height: NotchPanelGeometry.minimumControlSize)
    }

    /// The island's own queue/background pages, the global picture-and-music pause, and (while no
    /// song is active) the list actions with the compact 全部/已筛选 count beside them. While a song
    /// is active the list scope is hidden entirely and this row carries the exact 全部暂停 / 全部恢复
    /// wording; the accessibility label and help spell out the picture-and-music scope.
    @ViewBuilder
    private var navigationRow: some View {
        // 4pt spacing: the compact profile's control region is the tightest row, and this keeps the
        // two list label buttons plus the compact 全部/已筛选 count inside it without clipping.
        HStack(spacing: 4) {
            NotchIconButton(symbol: "list.bullet", id: "notch-music-queue",
                            label: "打开播放队列",
                            help: "浏览播放队列。",
                            action: actions.openQueuePage)
            playbackOrderMenu
            NotchIconButton(symbol: "photo", id: "notch-background-open",
                            label: "选择陪伴视频",
                            help: "选择陪伴视频。",
                            action: actions.openBackgroundPage)
            if music.isActive {
                Spacer(minLength: 6)
                NotchLabelButton(symbol: paused ? "play.circle" : "pause.circle",
                                 text: paused ? "全部恢复" : "全部暂停",
                                 id: "notch-global-pause",
                                 label: paused ? "全部恢复（画面和音乐）" : "全部暂停（画面和音乐）",
                                 help: "全局暂停：日常画面与音乐一起暂停或恢复。",
                                 action: actions.toggleGlobalPause)
            } else {
                NotchLabelButton(symbol: "play.fill", text: "播放列表", id: "notch-list-play",
                                 label: "播放列表",
                                 help: listScope.unavailableReason ?? "从当前列表开始播放。",
                                 disabled: !listScope.canPlaySelected, action: actions.playList)
                NotchLabelButton(symbol: "shuffle", text: "随机", id: "notch-list-shuffle",
                                 label: "随机播放",
                                 help: listScope.canShuffle ? "随机播放当前列表。"
                                                            : "当前列表没有可播放的歌曲。",
                                 disabled: !listScope.canShuffle, action: actions.shuffle)
                NotchIconButton(symbol: "plus", id: "notch-list-choose", label: "选择歌曲",
                                help: "选择歌曲。",
                                action: actions.chooseSongs)
                Spacer(minLength: 0)
            }
        }
        .frame(height: NotchPanelGeometry.minimumControlSize)
    }

    private var playbackOrderMenu: some View {
        Menu {
            ForEach(PerformanceQueueOrder.allCases, id: \.self) { order in
                Button { actions.setQueueOrder(order) } label: {
                    if order == queue.order { Label(order.controlLabel, systemImage: "checkmark") }
                    else { Text(order.controlLabel) }
                }
            }
        } label: {
            NotchMenuLabel(symbol: queue.order == .repeatOne ? "repeat.1" : queue.order == .shuffle ? "shuffle" : "repeat")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .accessibilityIdentifier("notch-music-order")
        .accessibilityLabel("播放方式：\(queue.orderLabel)")
        .help("播放方式：\(queue.orderLabel)。仅影响后续播放。")
    }

    /// The original music panel renders the same timer owner without changing pages.
    private var inlineStudyRow: some View {
        HStack(spacing: 6) {
            Menu {
                Button("正计时") { studyActions.selectMode(.countUp) }
                Button("倒计时") { studyActions.selectMode(.countdown) }
            } label: {
                NotchMenuLabel(symbol: study.ledger.mode == .countdown ? "hourglass" : "stopwatch")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .disabled(study.ledger.active != nil || study.loadFailed)
            .accessibilityIdentifier("notch-study-mode")
            .accessibilityLabel(study.ledger.mode == .countdown ? "倒计时" : "正计时")
            .help("选择正计时或倒计时。")
            if study.isRunning {
                TimelineView(.periodic(from: .now, by: 1)) { _ in inlineStudyReadout(study.presentation) }
            } else { inlineStudyReadout(study.presentation) }
            Spacer(minLength: 0)
            NotchIconButton(symbol: study.isRunning ? "pause.fill" : "play.fill",
                id: "notch-study-toggle", label: study.isRunning ? "暂停自习" : "开始或继续自习",
                help: study.presentation.status, disabled: study.loadFailed, action: studyActions.toggle)
            NotchIconButton(symbol: "stop.fill", id: "notch-study-finish", label: "结束并记录自习",
                help: "结束并记录自习。", disabled: study.ledger.active == nil, action: studyActions.finish)
        }
        .frame(height: NotchPanelGeometry.minimumControlSize)
    }

    private func inlineStudyReadout(_ state: StudyTimerPresentation) -> some View {
        Text(state.timeText)
            .font(.system(size: 15, weight: .medium, design: .monospaced))
            .foregroundStyle(NotchPalette.ink).fixedSize()
            .accessibilityIdentifier("notch-study-time")
            .accessibilityLabel("自习 \(state.timeText)，\(state.status)")
            .help(state.status)
    }

    // MARK: - Queue page (read-only browse + explicit play)

    private var queuePage: some View {
        VStack(alignment: .leading, spacing: NotchPanelGeometry.queueRowGap) {
            pageHeader()
            HStack(spacing: 6) {
                SongQueueSelector(model: performance)
                    .controlSize(.small)
                Spacer(minLength: 4)
                NotchIconButton(symbol: music.pauseSymbol, id: "notch-queue-pause",
                                label: music.pauseTitle, help: music.pauseTitle,
                                disabled: !music.canPause,
                                action: actions.pauseOrResumeMusic)
            }
            .frame(height: NotchPanelGeometry.minimumControlSize)
            if performance.showingSongHistory {
                SongPlaybackHistoryView(model: performance, compact: true)
            } else {
                queueList
            }
        }
    }

    private var queueList: some View {
        Group {
            if let message = queue.emptyMessage {
                Text(message)
                    .font(.system(size: NotchPanelGeometry.minimumTextSize))
                    .foregroundStyle(NotchPalette.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .accessibilityIdentifier("notch-queue-empty")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(queue.rows) { row in
                            queueRow(row)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("notch-queue-list")
    }

    private func queueRow(_ row: NotchQueueState.Row) -> some View {
        NotchRowTint(active: row.isActive) {
            HStack(spacing: 6) {
                Image(systemName: row.isActive ? "speaker.wave.2.fill" : "music.note")
                    .font(.system(size: 10))
                    .foregroundStyle(row.isActive ? NotchPalette.sage : NotchPalette.muted.opacity(0.7))
                    .frame(width: 14)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(row.title).font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                    if let status = row.status {
                        Text(status)
                            .font(.system(size: NotchPanelGeometry.minimumTextSize))
                            .foregroundStyle(NotchPalette.muted.opacity(0.85))
                            .lineLimit(1).truncationMode(.tail)
                    }
                }
                Spacer(minLength: 4)
                NotchIconButton(symbol: "play.fill",
                                id: "notch-queue-play-\(row.id)",
                                label: "播放《\(row.title)》",
                                help: row.canPlay ? "播放这一条。" : "这一条当前不可播放。",
                                disabled: !row.canPlay) { actions.playQueueEntry(row.id) }
            }
            .padding(.vertical, 2)
            .frame(minHeight: NotchPanelGeometry.minimumControlSize)
            .contentShape(Rectangle())
        }
        .onTapGesture(count: 2) {
            guard row.canPlay else { return }
            actions.playQueueEntry(row.id)
        }
        .accessibilityIdentifier("notch-queue-row-\(row.id)")
    }

    // MARK: - Background page (existing chooser model, projected)

    private var backgroundPage: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                pageHeader()
                DailyVideoVariantMenu(model: backgrounds)
                    .font(.system(size: NotchPanelGeometry.minimumTextSize))
                    .foregroundStyle(NotchPalette.muted).lineLimit(1)
                    .accessibilityIdentifier("notch-background-time")
            }
            DailyBackgroundPreview(model: backgrounds)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            DailyBackgroundThumbnails(model: backgrounds, destination: .island)
            HStack(spacing: 8) {
                NotchIconButton(symbol: "chevron.left", id: "notch-background-previous",
                                label: "上一原片", help: "浏览上一原片。",
                                disabled: !backgrounds.canGoPrevious,
                                action: backgrounds.selectPrevious)
                Text(backgrounds.positionText)
                    .font(.system(size: NotchPanelGeometry.minimumTextSize)).monospacedDigit()
                NotchIconButton(symbol: "chevron.right", id: "notch-background-next",
                                label: "下一原片", help: "浏览下一原片。",
                                disabled: !backgrounds.canGoNext,
                                action: backgrounds.selectNext)
                Text(backgrounds.selectionStatus)
                    .font(.system(size: NotchPanelGeometry.minimumTextSize))
                    .foregroundStyle(NotchPalette.muted).lineLimit(1)
                Spacer(minLength: 0)
                if backgrounds.canReturnToCurrent {
                    NotchIconButton(symbol: "arrow.uturn.backward", id: "notch-background-current",
                                    label: "回到当前", help: "查看当前选择的视频。",
                                    action: backgrounds.returnToCurrent)
                }
                NotchLabelButton(symbol: "checkmark", text: backgrounds.applyActionTitle,
                                 id: "notch-background-apply", label: "播放此视频",
                                 help: "播放所选完整视频及其服装与光照版本。",
                                 disabled: !backgrounds.canApplySelection) {
                    backgrounds.applySelection()
                }
            }
            .frame(height: NotchPanelGeometry.minimumControlSize)
            VStack(alignment: .leading, spacing: 2) {
                if let notice = backgrounds.applyNotice {
                    Text(notice).foregroundStyle(backgrounds.applyFailed ? Color.red : NotchPalette.muted)
                        .accessibilityIdentifier("notch-background-apply-status")
                }
                Text(backgroundState.pendingSwitchMessage ?? backgrounds.previewExplanation)
                    .foregroundStyle(NotchPalette.muted)
                    .accessibilityIdentifier("notch-background-pending")
            }
            .font(.system(size: NotchPanelGeometry.minimumTextSize))
            .lineLimit(1)
            .frame(height: 28, alignment: .topLeading)
        }
    }

}
