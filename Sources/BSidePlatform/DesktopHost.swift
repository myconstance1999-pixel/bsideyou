// BSidePlatform — DesktopHost: the ONLY place window-level / desktop-layer APIs live (ADR-006).
// Recipe adopted from AuraFlow (MIT) — see docs/architecture/UPSTREAM_ARCHITECTURE_AUDIT.md.

import AppKit
import SwiftUI
import BSideCore

/// Bounded, nonactivating hit surfaces. The wallpaper remains a separate click-through host.
public final class DesktopWorkspaceHost {
    private var panels: [DesktopWorkspaceAction: NSPanel] = [:]
    private var screenObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    private var presentation = DesktopWorkspacePresentation()
    public var onAction: ((DesktopWorkspaceAction) -> Void)?
    public var windowFrames: [CGRect] { panels.values.map(\.frame) }

    public init() {}

    public func update(_ value: DesktopWorkspacePresentation) {
        guard value.isVisible else { teardown(); presentation = value; return }
        let changed = value != presentation
        presentation = value
        if panels.isEmpty {
            for action in [DesktopWorkspaceAction.applications, .files, .music, .companion] {
                let panel = DesktopObjectPanel(contentRect: .zero,
                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.isReleasedWhenClosed = false
                panel.appearance = NSAppearance(named: .aqua)
                panel.isOpaque = false
                panel.backgroundColor = .clear
                panel.hasShadow = true
                panel.hidesOnDeactivate = false
                panel.isFloatingPanel = false
                panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
                panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
                panel.title = "bsideyou Desktop · \(action.rawValue)"
                panels[action] = panel
            }
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.positionPanels() }
            spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.positionPanels() }
            refreshViews()
            positionPanels()
        } else if changed { refreshViews() }
    }

    private func refreshViews() {
        for (action, panel) in panels {
            panel.contentView = NSHostingView(rootView: DesktopObjectCard(action: action, state: presentation) {
                [weak self] action in self?.onAction?(action)
            })
        }
    }

    private func positionPanels() {
        // screens.first is the menu-bar display; NSScreen.main follows the key window instead.
        guard let screen = NSScreen.screens.first else { return }
        let area = screen.visibleFrame
        let margin: CGFloat = 32
        let frames: [DesktopWorkspaceAction: CGRect] = [
            .applications: CGRect(x: area.minX + margin, y: area.minY + 18, width: 90, height: 94),
            .files: CGRect(x: area.minX + margin + 96, y: area.minY + 13, width: 112, height: 100),
            .music: CGRect(x: area.midX - 120, y: area.minY + 20, width: 240, height: 38),
            .companion: CGRect(x: area.maxX - margin - 144, y: area.minY + 20, width: 144, height: 36),
        ]
        for (action, panel) in panels {
            if let frame = frames[action] { panel.setFrame(frame, display: true) }
            panel.orderFrontRegardless()
        }
    }

    public func teardown() {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        screenObserver = nil
        spaceObserver = nil
        panels.values.forEach { $0.close() }
        panels.removeAll()
    }

    deinit { teardown() }
}

private final class DesktopObjectPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct DesktopObjectCard: View {
    let action: DesktopWorkspaceAction
    let state: DesktopWorkspacePresentation
    let perform: (DesktopWorkspaceAction) -> Void
    private let orange = Color(red: 0.82, green: 0.39, blue: 0.18)

    var body: some View {
        Group {
            switch action {
            case .applications: applications
            case .files: files
            case .music: music
            case .companion: companion
            default: EmptyView()
            }
        }
        .environment(\.colorScheme, .light)
    }

    private var applications: some View {
        Button { perform(.applications) } label: {
            ZStack {
                Ellipse().fill(.black.opacity(0.28)).frame(width: 72, height: 8)
                    .blur(radius: 3).offset(y: 34)
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(Color(red: 0.08, green: 0.09, blue: 0.09))
                        .offset(y: 3)
                    RoundedRectangle(cornerRadius: 9)
                        .fill(LinearGradient(colors: [Color(red: 0.31, green: 0.32, blue: 0.31),
                                                       Color(red: 0.13, green: 0.15, blue: 0.15)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(.white.opacity(0.3), lineWidth: 0.7))
                    RoundedRectangle(cornerRadius: 5)
                        .fill(LinearGradient(colors: [.black.opacity(0.66), .black.opacity(0.28)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(.black.opacity(0.5), lineWidth: 0.6))
                        .padding(.horizontal, 8).padding(.top, 7).padding(.bottom, 21)
                    VStack(spacing: 5) {
                        ForEach(0..<3) { row in
                            HStack(spacing: 5) {
                                ForEach(0..<3) { column in
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(row == 2 && column == 2 ? orange : Color(red: 0.63, green: 0.65, blue: 0.61))
                                        .overlay(RoundedRectangle(cornerRadius: 2).stroke(.white.opacity(0.2), lineWidth: 0.5))
                                        .frame(width: 9, height: 9)
                                        .shadow(color: .black.opacity(0.5), radius: 0.7, y: 1)
                                }
                            }
                        }
                    }.padding(.bottom, 29)
                    Text("应用").font(.system(size: 9, weight: .medium)).foregroundColor(.white.opacity(0.75))
                        .padding(.bottom, 7)
                }
                .frame(width: 66, height: 76)
                .rotationEffect(.degrees(-6))
                .offset(y: -5)
            }
            .frame(width: 90, height: 94).contentShape(Rectangle())
        }
        .buttonStyle(DesktopObjectButtonStyle())
        .accessibilityLabel("打开应用抽屉").help("应用")
    }

    private var files: some View {
        Button { perform(.files) } label: {
            ZStack(alignment: .topLeading) {
                Ellipse().fill(.black.opacity(0.28)).frame(width: 98, height: 9)
                    .blur(radius: 3).position(x: 56, y: 86)
                Path { path in
                    path.move(to: CGPoint(x: 14, y: 25)); path.addLine(to: CGPoint(x: 96, y: 25))
                    path.addLine(to: CGPoint(x: 109, y: 69)); path.addLine(to: CGPoint(x: 3, y: 69))
                    path.closeSubpath()
                }
                .fill(LinearGradient(colors: [Color(red: 0.43, green: 0.43, blue: 0.39),
                                               Color(red: 0.22, green: 0.24, blue: 0.23)],
                                     startPoint: .top, endPoint: .bottom))
                DesktopTraySheet().fill(Color(red: 0.76, green: 0.76, blue: 0.69))
                    .offset(x: 1, y: 6)
                DesktopTraySheet().fill(Color(red: 0.85, green: 0.85, blue: 0.78))
                    .offset(x: -2, y: 3)
                DesktopTraySheet().fill(LinearGradient(colors: [Color(red: 0.93, green: 0.92, blue: 0.85),
                                                                  Color(red: 0.83, green: 0.83, blue: 0.76)],
                                                        startPoint: .topLeading, endPoint: .bottomTrailing))
                DesktopTraySheet().stroke(Color(red: 0.45, green: 0.46, blue: 0.41).opacity(0.45), lineWidth: 0.6)
                Path { path in
                    path.move(to: CGPoint(x: 76, y: 25)); path.addLine(to: CGPoint(x: 88, y: 24))
                    path.addLine(to: CGPoint(x: 90, y: 29)); path.addLine(to: CGPoint(x: 78, y: 30))
                    path.closeSubpath()
                }.fill(orange)
                Path { path in
                    path.move(to: CGPoint(x: 3, y: 64)); path.addLine(to: CGPoint(x: 109, y: 64))
                    path.addLine(to: CGPoint(x: 103, y: 84)); path.addLine(to: CGPoint(x: 10, y: 84))
                    path.closeSubpath()
                }
                .fill(LinearGradient(colors: [Color(red: 0.40, green: 0.42, blue: 0.38),
                                               Color(red: 0.20, green: 0.23, blue: 0.22)],
                                     startPoint: .top, endPoint: .bottom))
                Path { path in
                    path.move(to: CGPoint(x: 4, y: 64)); path.addLine(to: CGPoint(x: 108, y: 64))
                }.stroke(.white.opacity(0.25), lineWidth: 1)
                Text("文件盒").font(.system(size: 9, weight: .medium)).foregroundColor(.white.opacity(0.75))
                    .position(x: 56, y: 75)
            }
            .frame(width: 112, height: 100).contentShape(Rectangle())
        }
        .buttonStyle(DesktopObjectButtonStyle())
        .accessibilityLabel("打开文件盒").help("文件盒")
    }

    private var music: some View {
        HStack(spacing: 0) {
            Button { perform(.music) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "music.note").font(.system(size: 11)).foregroundColor(.white.opacity(0.65))
                    Text(state.musicCanToggle && !state.musicTitle.isEmpty ? state.musicTitle : "选择音乐")
                        .font(.system(size: 12, weight: .medium)).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, 12).padding(.trailing, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
            }
            .buttonStyle(DesktopObjectButtonStyle())
            .help("打开音乐库").accessibilityLabel("打开音乐库")
            Rectangle().fill(.white.opacity(0.18)).frame(width: 1, height: 14)
            Button { perform(.toggleMusic) } label: {
                Image(systemName: state.musicCanToggle
                    ? (state.musicIsPlaying ? "pause.fill" : "play.fill") : "music.note.list")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 38, height: 38).contentShape(Rectangle())
            }
            .buttonStyle(DesktopObjectButtonStyle())
            .help(musicActionTitle).accessibilityLabel(musicActionTitle)
        }
        .foregroundColor(.white.opacity(0.92))
        .background(RoundedRectangle(cornerRadius: 7).fill(.black.opacity(0.32)))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(.white.opacity(0.15), lineWidth: 0.7).allowsHitTesting(false))
    }

    private var companion: some View {
        HStack(spacing: 0) {
            Button { perform(.companion) } label: {
                Text("陪伴").font(.system(size: 11, weight: .medium))
                    .frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
            }
            .buttonStyle(DesktopObjectButtonStyle())
            .help("打开陪伴画面与背景选择").accessibilityLabel("打开陪伴画面与背景选择")
            Rectangle().fill(.white.opacity(0.18)).frame(width: 1, height: 14)
            Button { perform(.toggleCompanion) } label: {
                Image(systemName: state.pictureIsPaused ? "play.rectangle" : "pause.rectangle")
                    .font(.system(size: 14)).frame(width: 36, height: 36).contentShape(Rectangle())
            }
            .buttonStyle(DesktopObjectButtonStyle())
            .help(state.pictureIsPaused ? "恢复画面" : "暂停画面")
            .accessibilityLabel(state.pictureIsPaused ? "恢复陪伴画面" : "暂停陪伴画面")
            Button { perform(.settings) } label: {
                Image(systemName: "slider.horizontal.3").font(.system(size: 12))
                    .frame(width: 32, height: 36).contentShape(Rectangle())
            }
            .buttonStyle(DesktopObjectButtonStyle())
            .help("设置").accessibilityLabel("设置")
        }
        .foregroundColor(.white.opacity(0.88))
        .background(RoundedRectangle(cornerRadius: 7).fill(.black.opacity(0.25)))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(.white.opacity(0.12), lineWidth: 0.7).allowsHitTesting(false))
    }

    private var musicActionTitle: String {
        state.musicCanToggle ? (state.musicIsPlaying ? "暂停音乐" : "恢复音乐") : "选择音乐"
    }
}

private struct DesktopTraySheet: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: 22, y: 20)); path.addLine(to: CGPoint(x: 86, y: 17))
            path.addLine(to: CGPoint(x: 101, y: 59)); path.addLine(to: CGPoint(x: 12, y: 65))
            path.closeSubpath()
        }
    }
}

private struct DesktopObjectButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        DesktopObjectButtonFeedback(configuration: configuration)
    }
}

private struct DesktopObjectButtonFeedback: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovered = false

    var body: some View {
        configuration.label
            .brightness(configuration.isPressed ? -0.12 : hovered ? 0.07 : 0)
            .onHover { hovered = $0 }
    }
}

/// A host that presents the playback layer at (or near) the desktop layer.
public protocol DesktopHost: AnyObject {
    var strategyName: String { get }
    /// Whether installation created a window. Unknown visibility is not an installation failure.
    var isInstalled: Bool { get }
    /// Read-only window identity/Space membership for bounded presentation acceptance.
    var presentationProbe: (windowID: Int, onActiveSpace: Bool)? { get }
    /// Observed visibility of this host's window; nil until a post-show event or the single bounded
    /// initial-settlement read. An unshown window's empty occlusionState never confirms coverage.
    var visibility: Bool? { get }
    /// Main-queue, coalesced state changes. Never called synchronously inside install/show/teardown.
    var onVisibilityChanged: ((Bool?) -> Void)? { get set }
    /// Install the playback layer (engine-owned CALayer) into the host's content tree.
    func install(layer: CALayer)
    func show()
    func teardown()
    /// Re-assert the host's correct window level + collection behavior WITHOUT rebuilding it,
    /// after WindowServer detaches desktop-level windows (wake / Spaces animation).
    func reassert()
}

extension DesktopHost {
    public var presentationProbe: (windowID: Int, onActiveSpace: Bool)? { nil }
}

/// Own-window observations only. A window first ordered behind an opaque cover may receive no
/// initial occlusion event. One read 250ms after its first show covers that observed AppKit behavior;
/// settlement is a capability to verify with the real desktop probe on each macOS release, not a
/// universal timing guarantee. There are no retries or recurring queries. Never order a window in
/// response to an observation or substitute application activation for window visibility.
/// Main-thread confined, like the hosts. Delegate observations update value immediately; callbacks
/// wait for the next main-queue turn to avoid reentering the owner's installation/teardown path.
private final class DesktopVisibilityObservation {
    private(set) var value: Bool?
    var onChange: ((Bool?) -> Void)?
    private weak var window: NSWindow?
    private var hasBeenShown = false
    private var generation: UInt64 = 0
    private var pending: DispatchWorkItem?
    private var initialSettlement: DispatchWorkItem?
    private var didScheduleInitialSettlement = false
    private var lastDelivered: Bool?
    private var applicationTraceObserver: NSObjectProtocol?
    /// Explicit test-only timing diagnostics; the production path does no timestamp/log work.
    private let traceEnabled = ProcessInfo.processInfo.environment["BSIDEMAC_TRACE_VISIBILITY"] == "1"

    func bind(to window: NSWindow?) {
        generation &+= 1
        if let applicationTraceObserver {
            NotificationCenter.default.removeObserver(applicationTraceObserver)
        }
        applicationTraceObserver = nil
        pending?.cancel()
        pending = nil
        initialSettlement?.cancel()
        initialSettlement = nil
        didScheduleInitialSettlement = false
        self.window = window
        hasBeenShown = false
        let wasKnown = value != nil
        value = nil
        if wasKnown { trace(phase: "accepted", visible: nil, source: "bind") }
        if lastDelivered != nil { scheduleDelivery() }
        if traceEnabled, let window {
            let activeGeneration = generation
            applicationTraceObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeOcclusionStateNotification,
                object: NSApplication.shared, queue: .main
            ) { [weak self, weak window] _ in
                guard let self, let window, self.generation == activeGeneration,
                      self.window === window else { return }
                // Diagnostic comparison only: application notification never accepts a visibility
                // value, orders a window, or drives media. Read exactly this host's current window.
                self.trace(phase: "application", visible: window.occlusionState.contains(.visible),
                           source: "application-notification")
            }
        }
    }

    func willShow(_ window: NSWindow) {
        guard self.window === window else { return }
        hasBeenShown = true
    }

    func didShow(_ window: NSWindow) {
        guard self.window === window, hasBeenShown, !didScheduleInitialSettlement else { return }
        didScheduleInitialSettlement = true
        guard value == nil else { return }
        // A positive post-ordering observation is already useful; only an empty initial state
        // needs the one bounded settlement. Repeated show/reassert calls neither add nor defer it.
        let initiallyVisible = window.occlusionState.contains(.visible)
        trace(phase: "observed", visible: initiallyVisible, source: "initial-show")
        if initiallyVisible {
            record(true, source: "initial-show")
            return
        }
        let activeGeneration = generation
        let work = DispatchWorkItem { [weak self, weak window] in
            guard let self, let window, self.generation == activeGeneration,
                  self.window === window, self.hasBeenShown, self.value == nil else { return }
            self.initialSettlement = nil
            // isVisible confirms the window is still ordered, not that any pixels are uncovered.
            guard window.isVisible else { return }
            let visible = window.occlusionState.contains(.visible)
            self.trace(phase: "observed", visible: visible, source: "initial-settlement")
            self.record(visible, source: "initial-settlement")
        }
        initialSettlement = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func receive(_ notification: Notification) {
        guard let observed = notification.object as? NSWindow,
              observed === window else { return }
        let visible = observed.occlusionState.contains(.visible)
        trace(phase: "observed", visible: visible, source: "notification")
        guard hasBeenShown else { return }
        record(visible, source: "notification")
    }

    private func record(_ visible: Bool, source: String) {
        initialSettlement?.cancel()
        initialSettlement = nil
        guard visible != value else { return }
        value = visible
        trace(phase: "accepted", visible: visible, source: source)
        scheduleDelivery()
    }

    private func scheduleDelivery() {
        guard pending == nil else { return }
        let activeGeneration = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == activeGeneration else { return }
            self.pending = nil
            guard self.lastDelivered != self.value else { return }
            self.lastDelivered = self.value
            if let onChange = self.onChange {
                self.trace(phase: "delivered", visible: self.value, source: "main-queue")
                onChange(self.value)
            }
        }
        pending = work
        DispatchQueue.main.async(execute: work)
    }

    private func trace(phase: String, visible: Bool?, source: String) {
        guard traceEnabled else { return }
        let state = visible.map { $0 ? "true" : "false" } ?? "unknown"
        let uptime = String(format: "%.6f", ProcessInfo.processInfo.systemUptime)
        AppLog.info("visibility-trace phase=\(phase) visible=\(state) uptime=\(uptime) source=\(source)")
    }

    deinit {
        pending?.cancel()
        initialSettlement?.cancel()
        if let applicationTraceObserver {
            NotificationCenter.default.removeObserver(applicationTraceObserver)
        }
    }
}

/// Stable strategy: borderless window at the desktop window level, click-through, all Spaces,
/// never activated. Finder icons stay clickable because the window ignores mouse events.
public final class StableDesktopPanelHost: NSObject, DesktopHost, NSWindowDelegate {
    private var window: DesktopWallpaperWindow?
    private var observers: [NSObjectProtocol] = []             // NotificationCenter.default tokens (screen parameters)
    private var workspaceObservers: [NSObjectProtocol] = []    // NSWorkspace.shared.notificationCenter tokens (active Space)
    /// Pure double-hop reassert reducer (Core) — generation-scopes the delayed second hop.
    private var reassertGate = HostReassert()
    private let visibilityObservation = DesktopVisibilityObservation()

    public let strategyName = "stable-desktop-panel"
    public var isInstalled: Bool { window != nil }
    public var presentationProbe: (windowID: Int, onActiveSpace: Bool)? {
        window.map { ($0.windowNumber, $0.isOnActiveSpace) }
    }
    public var visibility: Bool? { visibilityObservation.value }
    public var onVisibilityChanged: ((Bool?) -> Void)? {
        get { visibilityObservation.onChange }
        set { visibilityObservation.onChange = newValue }
    }

    public func install(layer: CALayer) {
        teardown()   // reinstall cannot retain old observers, delegates, or delayed visibility work
        guard let screen = NSScreen.main else { return }
        let window = DesktopWallpaperWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        window.canHide = false
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.animationBehavior = .none
        window.delegate = self
        window.isReleasedWhenClosed = false

        let content = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        content.wantsLayer = true
        content.layer = CALayer()
        content.layer?.backgroundColor = NSColor.black.cgColor
        layer.frame = content.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        content.layer?.addSublayer(layer)
        window.contentView = content
        window.setFrame(screen.frame, display: true)

        self.window = window
        visibilityObservation.bind(to: window)
        registerReassertObservers(for: window)
    }

    public func show() {
        guard let window else { return }
        visibilityObservation.willShow(window)
        // orderBack puts us behind everything at our level; orderFrontRegardless asserts the
        // desktop-level placement WITHOUT activating the app (no focus steal).
        window.orderBack(nil)
        window.orderFrontRegardless()
        visibilityObservation.didShow(window)
    }

    public func teardown() {
        reassertGate.invalidate()   // any in-flight delayed hop is now stale
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        workspaceObservers.removeAll()
        let closingWindow = window
        window = nil
        closingWindow?.delegate = nil
        visibilityObservation.bind(to: nil)
        closingWindow?.orderOut(nil)
    }

    public func windowDidChangeOcclusionState(_ notification: Notification) {
        visibilityObservation.receive(notification)
    }

    deinit {
        visibilityObservation.onChange = nil
        teardown()
    }

    /// Re-assert level + collection (the SAME values install() set — the strategy is unchanged),
    /// then the bounded double-hop order (immediate + next runloop turn, generation-scoped).
    public func reassert() {
        let effects = reassertGate.onTrigger()
        for effect in effects {
            switch effect {
            case .reassertNow:
                applyReassert()
            case .scheduleReassert(let generation):
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.reassertGate.reassertIfCurrent(generation: generation) else { return }
                    self.applyReassert()
                }
            }
        }
    }

    /// The actual window-level reassert: re-apply desktop level + collection behavior and order.
    private func applyReassert() {
        guard let window else { return }
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        show()
    }

    /// WindowServer briefly detaches desktop-level windows during Spaces animations; re-assert
    /// immediately AND on the next runloop turn (AuraFlow-proven double tap).
    private func registerReassertObservers(for window: DesktopWallpaperWindow) {
        let center = NotificationCenter.default
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self, weak window] _ in
            guard let self, let window, self.window === window else { return }
            self.reassert()
            if ProcessInfo.processInfo.environment["BSIDEMAC_TRACE_SPACES"] == "1" {
                AppLog.info("space-trace desktop-window=\(window.windowNumber) active=\(window.isOnActiveSpace)")
            }
        })
        observers.append(center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self, weak window] _ in
            guard let self, let window, self.window === window else { return }
            self.rebuildFrame()
        })
    }

    private func rebuildFrame() {
        guard let window, let screen = NSScreen.main else { return }
        window.setFrame(screen.frame, display: true)
        window.contentView?.setFrameSize(screen.frame.size)
        show()
    }
}

/// Window subclass: never key/main (desktop-level window must not take focus).
/// Note: NSWindow.constrainFrameRect was removed/renamed in the macOS 26 SDK — frames are
/// set explicitly to the screen frame, so no constraint override is needed.
final class DesktopWallpaperWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Preview is an ordinary user-interactable window even though it has no title bar. Becoming
/// key/main is permitted when requested by the user; merely showing it must not claim focus.
final class WallpaperPreviewWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Degraded strategy: ordinary borderless floating preview window. Used when the stable
/// strategy is unavailable so the app stays usable instead of blank.
public final class FallbackWindowHost: NSObject, DesktopHost, NSWindowDelegate {
    private var window: WallpaperPreviewWindow?
    private let visibilityObservation = DesktopVisibilityObservation()
    public let strategyName = "fallback-floating-preview"
    public var isInstalled: Bool { window != nil }
    public var presentationProbe: (windowID: Int, onActiveSpace: Bool)? {
        window.map { ($0.windowNumber, $0.isOnActiveSpace) }
    }
    public var visibility: Bool? { visibilityObservation.value }
    public var onVisibilityChanged: ((Bool?) -> Void)? {
        get { visibilityObservation.onChange }
        set { visibilityObservation.onChange = newValue }
    }

    public func install(layer: CALayer) {
        teardown()
        guard NSScreen.main != nil else { return }
        let size = NSSize(width: 960, height: 540)
        let window = WallpaperPreviewWindow(
            contentRect: NSRect(origin: CGPoint(x: 64, y: 64), size: size),
            styleMask: [.borderless, .resizable],
            backing: .buffered, defer: false
        )
        window.level = .floating
        window.title = "bsideyou 壁纸预览"
        window.setAccessibilityIdentifier("BSideMac.wallpaper-preview")
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = false
        window.delegate = self

        let content = NSView(frame: NSRect(origin: .zero, size: size))
        content.wantsLayer = true
        layer.frame = content.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        content.layer?.addSublayer(layer)
        window.contentView = content
        self.window = window
        visibilityObservation.bind(to: window)
    }

    public func show() {
        guard let window else { return }
        visibilityObservation.willShow(window)
        window.orderFrontRegardless()
        visibilityObservation.didShow(window)
    }

    public func teardown() {
        let closingWindow = window
        window = nil
        closingWindow?.delegate = nil
        visibilityObservation.bind(to: nil)
        closingWindow?.orderOut(nil)
    }

    public func windowDidChangeOcclusionState(_ notification: Notification) {
        visibilityObservation.receive(notification)
    }

    deinit {
        visibilityObservation.onChange = nil
        teardown()
    }

    public func reassert() {
        // Floating preview has no desktop-layer detach problem; re-showing keeps it visible.
        show()
    }
}

/// Selects the requested presentation without treating a temporarily absent screen as a successful
/// fallback. Both hosts need a screen; the controller retries installation when one becomes available.
public enum DesktopHostFactory {
    public static func makeHost(desktopMode: Bool = true) -> DesktopHost {
        desktopMode ? StableDesktopPanelHost() : FallbackWindowHost()
    }
}

/// Main-thread owner of one presentation host. Screen recovery is independent of RuntimeContext
/// changes: connecting a display can leave its global boolean inputs unchanged. Installed hosts
/// retain their window/content tree; only an uninstalled host is retried, without polling.
public final class DesktopHostController {
    private let layer: CALayer
    private let notificationCenter: NotificationCenter
    private let makeHost: (Bool) -> DesktopHost
    private var host: DesktopHost?
    private var requestedDesktopMode: Bool?
    private var hostDesktopMode: Bool?
    private var screenObserver: NSObjectProtocol?
    private var pendingScreenRetry: DispatchWorkItem?
    private var observationGeneration: UInt64 = 0
    private var installationGeneration: UInt64 = 0

    public var onVisibilityChanged: ((Bool?) -> Void)?
    public var isInstalled: Bool { host?.isInstalled == true }
    public var presentationProbe: (windowID: Int, onActiveSpace: Bool)? { host?.presentationProbe }
    public var strategyName: String? { host?.strategyName }

    public init(layer: CALayer, notificationCenter: NotificationCenter = .default,
                makeHost: @escaping (Bool) -> DesktopHost = { DesktopHostFactory.makeHost(desktopMode: $0) }) {
        self.layer = layer
        self.notificationCenter = notificationCenter
        self.makeHost = makeHost
    }

    public func ensureInstalled(desktopMode: Bool) {
        requestedDesktopMode = desktopMode
        observeScreenChangesIfNeeded()
        if hostDesktopMode == desktopMode, isInstalled { return }

        installationGeneration &+= 1
        let generation = installationGeneration
        if host == nil || hostDesktopMode != desktopMode {
            host?.onVisibilityChanged = nil
            host?.teardown()
            host = makeHost(desktopMode)
            hostDesktopMode = desktopMode
        }
        guard let host else { return }
        // Commit identity before AppKit installation can generate events. Even a queued callback
        // retained by an earlier attempt on this same host must not publish into the new attempt.
        host.onVisibilityChanged = { [weak self, weak host] visible in
            guard let self, let host, self.installationGeneration == generation,
                  self.host === host else { return }
            self.onVisibilityChanged?(visible)
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.installationGeneration == generation else { return }
            self.onVisibilityChanged?(nil)
        }
        host.install(layer: layer)
        host.show()
        AppLog.info("desktop host installation strategy=\(host.strategyName) installed=\(host.isInstalled)")
    }

    public func reassert() {
        if isInstalled {
            host?.reassert()
        } else if let requestedDesktopMode {
            ensureInstalled(desktopMode: requestedDesktopMode)
        }
    }

    public func teardown() {
        observationGeneration &+= 1
        installationGeneration &+= 1
        pendingScreenRetry?.cancel()
        pendingScreenRetry = nil
        if let screenObserver { notificationCenter.removeObserver(screenObserver) }
        screenObserver = nil
        requestedDesktopMode = nil
        hostDesktopMode = nil
        host?.onVisibilityChanged = nil
        host?.teardown()
        host = nil
    }

    private func observeScreenChangesIfNeeded() {
        guard screenObserver == nil else { return }
        let generation = observationGeneration
        screenObserver = notificationCenter.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.observationGeneration == generation,
                  !self.isInstalled, self.pendingScreenRetry == nil else { return }
            // Avoid reentering a host's install from an AppKit notification. A burst has one retry
            // using the newest requested mode; teardown invalidates both observer and queued work.
            let retry = DispatchWorkItem { [weak self] in
                guard let self, self.observationGeneration == generation else { return }
                self.pendingScreenRetry = nil
                guard let desktopMode = self.requestedDesktopMode, !self.isInstalled else { return }
                self.ensureInstalled(desktopMode: desktopMode)
            }
            self.pendingScreenRetry = retry
            DispatchQueue.main.async(execute: retry)
        }
    }

    deinit { teardown() }
}

// MARK: - Native fullscreen watch presentation (ADR-023)

/// The window surface the watch host drives. The real conformer is an ordinary normal-level
/// titled/closable/resizable `NSWindow`; tests inject a fake that records the same operations and
/// exposes the real layer-parenting seam (`watchContentLayer`).
public protocol WatchPresentingWindow: AnyObject {
    /// Content layer that hosts the engine's single video layer while the watch presents.
    var watchContentLayer: CALayer { get }
    var isWatchFullScreen: Bool { get }
    /// True while this window is the borderless desktop-level, mouse-pass-through rendition.
    var isWatchDesktopPresentation: Bool { get }
    func setWatchTitle(_ title: String)
    func attachWatchLayer(_ layer: CALayer)
    func detachWatchLayer()
    func showWatchWindow()
    /// Order the desktop-level window in without activating the app or stealing focus.
    func showWatchDesktopWindow()
    func enterWatchFullScreen()
    func exitWatchFullScreen()
    /// Transform the retained window (and its still-attached layer) into the borderless
    /// desktop-level presentation: full-screen frame, below ordinary apps/icons, no shadow,
    /// mouse pass-through. Never re-parents the layer, never activates and uses no implicit
    /// animation.
    func applyWatchDesktopPresentation()
    /// Prepare the same desktop-presenting window for an explicit native fullscreen entry:
    /// ordinary titled/resizable style, normal level, `fullScreenPrimary`, mouse events restored.
    /// Never re-parents or re-shows the layer.
    func prepareWatchForFullScreenEntry()
    func hideWatchWindow()
    /// Permanently retire this window because its requested fullscreen exit failed while it was
    /// still fullscreen: clear the delegate, then close/hide it once. A retired window is never
    /// reused and can never deliver a callback that mutates the run that replaces it.
    func retireWatchWindow()
}

/// Ordinary normal-level window: titled/closable/resizable + `fullScreenPrimary` only.
/// No `.canJoinAllSpaces` / `.moveToActiveSpace` / floating / desktop level: assigning it to a
/// normal Space stays a real Mission Control decision, never a product-created pseudo-desktop.
/// After a native fullscreen exit the SAME window is transformed in place into the desktop-level,
/// mouse-pass-through rendition (ADR-023): the engine layer stays parented to the same content
/// layer throughout, so no presentation change ever re-attaches the live video.
///
/// The window's content view carries exactly one standard `NSClickGestureRecognizer`
/// (`numberOfClicksRequired = 2`), so a double-click on the video content asks the host to leave
/// fullscreen. It is deliberately narrow: the recognizer lives on the content view only, so a
/// single click, the title bar (macOS zoom behavior stays untouched) and the library rows in the
/// ControlApp window are never intercepted. The desktop rendition is mouse-pass-through, so the
/// same recognizer can never fire there and can never re-enter fullscreen.
public final class WatchPresentationWindow: NSWindow, WatchPresentingWindow {
    private let layerHost: CALayer = {
        let layer = CALayer()
        layer.backgroundColor = NSColor.black.cgColor
        return layer
    }()
    private weak var hostedLayer: CALayer?
    private let videoDoubleClick = NSClickGestureRecognizer()
    private var desktopPresentation = false

    /// The ordinary watch-window frame, centered in the main screen's visible area.
    private static func defaultNormalFrame() -> NSRect {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 720)
        let size = NSSize(width: min(1600, screen.width * 0.9), height: min(900, screen.height * 0.9))
        return NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    public init() {
        let frame = WatchPresentationWindow.defaultNormalFrame()
        super.init(contentRect: frame,
                   styleMask: [.titled, .closable, .miniaturizable, .resizable],
                   backing: .buffered, defer: false)
        level = .normal
        collectionBehavior = [.fullScreenPrimary]
        title = WatchPresentationHost.windowTitle
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isExcludedFromWindowsMenu = true
        let content = NSView(frame: NSRect(origin: .zero, size: frame.size))
        content.wantsLayer = true
        content.layer = layerHost
        contentView = content
        videoDoubleClick.numberOfClicksRequired = 2
        videoDoubleClick.target = self
        videoDoubleClick.action = #selector(videoContentDoubleClicked(_:))
        content.addGestureRecognizer(videoDoubleClick)
    }

    /// The double-click on video content reached the host, which owns the window lifecycle guard
    /// and the reducer seam. An unset handler (no active watch run) makes the gesture inert.
    public var onVideoDoubleClick: (() -> Void)?

    @objc private func videoContentDoubleClicked(_ sender: NSClickGestureRecognizer) {
        guard sender.state == .ended else { return }
        onVideoDoubleClick?()
    }

    /// The ordinary/fullscreen shell may take key/main focus (native fullscreen needs key focus for
    /// Esc/`cancelOperation`), but the borderless desktop-level rendition must never: it is
    /// mouse-pass-through and must retain no focus, exactly like the daily `DesktopWallpaperWindow`.
    public override var canBecomeKey: Bool { !desktopPresentation }
    public override var canBecomeMain: Bool { !desktopPresentation }

    /// Esc exits fullscreen deterministically; when already desktop-presenting it does nothing.
    public override func cancelOperation(_ sender: Any?) {
        if styleMask.contains(.fullScreen) { toggleFullScreen(nil) }
    }

    public var watchContentLayer: CALayer { layerHost }
    public var isWatchFullScreen: Bool { styleMask.contains(.fullScreen) }
    public var isWatchDesktopPresentation: Bool { desktopPresentation }
    public func setWatchTitle(_ title: String) { self.title = title }

    public func attachWatchLayer(_ layer: CALayer) {
        layer.removeFromSuperlayer()
        layer.frame = layerHost.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layerHost.addSublayer(layer)
        hostedLayer = layer
    }

    public func detachWatchLayer() {
        hostedLayer?.removeFromSuperlayer()
        hostedLayer = nil
    }

    public func showWatchWindow() {
        makeKeyAndOrderFront(nil)
        // The accessory Agent is normally not the active app. Activation happens once, at entry:
        // no re-activation, retry, or focus reassertion after the user switches away.
        if !NSApp.isActive {
            if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        }
    }

    /// Desktop-level ordering: show without activating, so returning to the desktop background
    /// never steals focus from whatever the user was doing.
    public func showWatchDesktopWindow() {
        orderFrontRegardless()
    }

    public func enterWatchFullScreen() { toggleFullScreen(nil) }
    public func exitWatchFullScreen() {
        if styleMask.contains(.fullScreen) { toggleFullScreen(nil) }
    }
    public func hideWatchWindow() { orderOut(nil) }

    /// Borderless desktop-level rendition of the SAME window. The engine layer stays parented to
    /// `layerHost`; only the window shell and its geometry change. Window animation is disabled and
    /// the layer transaction ignores actions so a geometry change cannot accumulate implicit
    /// animations on the live video layer.
    public func applyWatchDesktopPresentation() {
        guard let screen = self.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        desktopPresentation = true
        // A native fullscreen exit leaves this same window key/main. Flipping `canBecomeKey`/
        // `canBecomeMain` only blocks *future* acquisition; an already-key window must resign
        // explicitly, otherwise the desktop shell keeps the keyboard/menu focus it had in
        // fullscreen. The engine layer stays parented and untouched.
        if isKeyWindow { resignKey() }
        if isMainWindow { resignMain() }
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        animationBehavior = .none
        styleMask = [.borderless]
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        // The assigned normal desktop stays the OS decision: never request all-Spaces behavior.
        collectionBehavior = [.stationary, .ignoresCycle, .fullScreenAuxiliary]
        ignoresMouseEvents = true
        hasShadow = false
        isOpaque = true
        backgroundColor = .black
        canHide = false
        hidesOnDeactivate = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        setFrame(screen.frame, display: true)
        contentView?.setFrameSize(screen.frame.size)
        CATransaction.commit()
        NSAnimationContext.endGrouping()
    }

    /// Restore the ordinary window shell for an explicit fullscreen entry on the SAME window. No
    /// layer re-parenting, no re-show, no activation: only the shell that native fullscreen needs.
    public func prepareWatchForFullScreenEntry() {
        guard desktopPresentation else { return }
        desktopPresentation = false
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        animationBehavior = .none
        styleMask = [.titled, .closable, .miniaturizable, .resizable]
        level = .normal
        collectionBehavior = [.fullScreenPrimary]
        ignoresMouseEvents = false
        hasShadow = true
        canHide = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        setFrame(WatchPresentationWindow.defaultNormalFrame(), display: true)
        contentView?.setFrameSize(frame.size)
        CATransaction.commit()
        NSAnimationContext.endGrouping()
    }

    /// Clear the delegate first so the close can never re-enter this host, then close the window.
    /// `isReleasedWhenClosed` is false, so closing does not end the object; the host drops its own
    /// reference. A window that is still in fullscreen leaves its Space here instead of being
    /// pretended desktop.
    public func retireWatchWindow() {
        delegate = nil
        close()
    }
}

/// Main-thread owner of one reused watch window and the pure `WatchPresentation` reducer.
/// It reads the real window's own occlusion through `DesktopVisibilityObservation`, so the Agent
/// can feed actual watch-host visibility to `SystemMonitors` instead of stale daily visibility.
public final class WatchPresentationHost: NSObject, NSWindowDelegate {
    public static let windowTitle = "bsideyou 演奏"

    private let makeWindow: () -> WatchPresentingWindow
    private var window: WatchPresentingWindow?
    private var engineLayer: CALayer?
    private var reducer = WatchPresentation()
    private let visibilityObservation = DesktopVisibilityObservation()
    /// An AppKit exit transition this host requested (vs a user green-button/Esc/system exit).
    private var awaitingProgrammaticExit = false
    /// A native fullscreen transition is in flight. AppKit ignores a second `toggleFullScreen` while
    /// one is animating, so the host drops duplicate double-click gestures from the moment the
    /// transition *begins* until the matching enter/exit/failed delegate callback arrives. That
    /// includes the green-button/Esc/system transitions the host never requested, which are marked
    /// here by `windowWillEnterFullScreen`/`windowWillExitFullScreen`. No timer, no retry: the
    /// callback is the only thing that clears it.
    private var windowTransitionPending = false
    /// Event-driven screen-geometry observer. It is registered only while the run presents as the
    /// desktop background and re-applies that window's screen frame/level on a screen change: no
    /// polling, no timer, and no observer while fullscreen or between runs.
    private var desktopScreenObserver: NSObjectProtocol?
    private var lastPresentationReport: PerformancePresentationReport?
    public var onPresentationChanged: ((PerformancePresentationReport) -> Void)?

    public var presentationReport: PerformancePresentationReport? {
        guard let sessionID = reducer.sessionID else { return nil }
        let state: PerformancePictureState
        if windowTransitionPending {
            state = reducer.isEntering ? .expanding : .collapsing
        } else {
            state = window?.isWatchFullScreen == true ? .expanded : .collapsed
        }
        return PerformancePresentationReport(sessionID: sessionID, state: state)
    }

    private func publishPresentation() {
        guard let report = presentationReport else { lastPresentationReport = nil; return }
        guard report != lastPresentationReport else { return }
        lastPresentationReport = report
        onPresentationChanged?(report)
    }

    /// Called synchronously before this host attaches its presentation layer. The Agent keeps
    /// the desktop's separate layer installed; both layers may share the same player.
    public var onBeginOwnership: (() -> Void)?
    /// Actual watch-window visibility (nil = unknown), delivered on the main queue.
    public var onVisibilityChanged: ((Bool?) -> Void)? {
        get { visibilityObservation.onChange }
        set { visibilityObservation.onChange = newValue }
    }

    public var visibility: Bool? { visibilityObservation.value }
    public var ownsLayer: Bool { reducer.ownsLayer }
    public var presentationProbe: (windowID: Int, onActiveSpace: Bool, fullscreen: Bool)? {
        guard let window = window as? NSWindow else { return nil }
        return (window.windowNumber, window.isOnActiveSpace, window.styleMask.contains(.fullScreen))
    }

    public var isActiveRun: Bool { reducer.isActiveRun }
    /// The current run's identity, for callers that need to address the presentation explicitly.
    public var sessionID: String? { reducer.sessionID }

    public init(makeWindow: @escaping () -> WatchPresentingWindow = { WatchPresentationWindow() }) {
        self.makeWindow = makeWindow
        super.init()
    }

    public func mediaBecameReady(sessionID: String, layer: CALayer, eligible: Bool,
                                 automaticallyEnterFullScreen: Bool = true) {
        engineLayer = layer
        apply(reducer.mediaBecameReady(sessionID: sessionID, eligible: eligible,
                                     automaticallyEnterFullScreen: automaticallyEnterFullScreen))
    }

    /// Transfer the run identity to a newly accepted watch session before its media is ready, so
    /// stop/failure for that session ends the run the Agent actually accepted. Never re-enters
    /// and never touches the current presentation or its fullscreen transition.
    public func adoptSession(_ sessionID: String) {
        reducer.adoptSession(sessionID)
        publishPresentation()
    }

    public func reconcileEligibility(sessionID: String, layer: CALayer, eligible: Bool) {
        engineLayer = layer
        apply(reducer.reconcileEligibility(sessionID: sessionID, eligible: eligible))
    }

    /// Release the layer synchronously (so the daily restore can install immediately) while the
    /// AppKit fullscreen exit finishes asynchronously.
    public func endRun(sessionID: String?) {
        AppLog.info("watch.end-request session=\(sessionID ?? "none") current=\(reducer.sessionID ?? "none") owns-layer=\(reducer.ownsLayer)")
        let effect = reducer.endRun(sessionID: sessionID)
        if !reducer.ownsLayer { releaseLayerSynchronously() }
        apply(effect)
    }

    /// Process shutdown: bounded, never waits for the transition. The Agent exits right after.
    public func teardown() {
        let effect = reducer.shutdown()
        releaseLayerSynchronously()
        apply(effect)
    }

    // MARK: - Effects

    private func apply(_ effect: WatchPresentation.Effect) {
        defer { publishPresentation() }
        if effect != .none {
            AppLog.info("watch.presentation session=\(reducer.sessionID ?? "none") effect=\(effect) owns-layer=\(reducer.ownsLayer)")
        }
        switch effect {
        case .enterFullScreen:
            present(requestFullScreen: true)
        case .exitFullScreen:
            requestExit()
        case .returnToDesktop:
            returnToDesktop()
        case .orderOut:
            windowTransitionPending = false
            releaseLayerSynchronously()
            window?.hideWatchWindow()
        case .none:
            break
        }
    }

    /// Attach the dedicated song layer only for an explicit fullscreen request.
    private func present(requestFullScreen: Bool) {
        guard let layer = engineLayer else { return }
        onBeginOwnership?()
        let window = ensureWindow()
        window.prepareWatchForFullScreenEntry()
        if let real = window as? NSWindow {
            visibilityObservation.bind(to: real)
            visibilityObservation.willShow(real)
        }
        window.setWatchTitle(Self.windowTitle)
        window.attachWatchLayer(layer)
        window.showWatchWindow()
        if let real = window as? NSWindow { visibilityObservation.didShow(real) }
        awaitingProgrammaticExit = false
        windowTransitionPending = true
        window.enterWatchFullScreen()
    }

    /// Both user close and session end leave native fullscreen and hide the song surface.
    private func requestExit(programmatic: Bool = true) {
        guard let window else {
            apply(reducer.didExitFullScreen(programmatic: programmatic))
            return
        }
        if window.isWatchFullScreen {
            windowTransitionPending = true
            awaitingProgrammaticExit = programmatic
            window.exitWatchFullScreen()
            return
        }
        // The transition never actually reached fullscreen. While the run is still entering, wait
        // for that callback (which also asks for the exit); otherwise converge on the real state
        // instead of toggling a non-fullscreen surface into fullscreen.
        guard reducer.isExitDeferredForEnter else {
            apply(reducer.didExitFullScreen(programmatic: programmatic))
            return
        }
    }

    /// Legacy private name: leave fullscreen, then hide. Playback continues unchanged.
    private func returnToDesktop() {
        guard reducer.ownsLayer, !windowTransitionPending else { return }
        requestExit(programmatic: false)
    }

    // MARK: - Video-content double click (exit-only) and explicit menu-bar re-entry

    /// Exit-only double-click, scoped to video content and inert during a native transition.
    public func videoContentDoubleClicked() {
        guard reducer.ownsLayer, !windowTransitionPending, let window else { return }
        if window.isWatchFullScreen {
            apply(reducer.contentDoubleClicked())
        }
        // A hidden song never receives a gesture or opens itself.
    }

    /// The same gesture carrying the window surface's identity. A gesture delivered by a window this
    /// host no longer drives — a retired window's delayed recognizer, or a window already replaced by
    /// a newer run — is refused before it can change the newer presentation.
    public func videoContentDoubleClicked(from object: Any?) {
        guard isHostWindow(object) else { return }
        videoContentDoubleClicked()
    }

    /// Explicit presentation request for the already installed song; no playback mutation.
    public func enterFullScreenExplicitly() {
        apply(reducer.explicitFullScreenRequested())
    }

    public func exitFullScreenExplicitly() {
        apply(reducer.closeRequested())
    }

    /// Synchronous layer release. The engine's retained/still frame stays attached to its layer.
    private func releaseLayerSynchronously() {
        stopObservingDesktopScreenChanges()
        window?.detachWatchLayer()
        visibilityObservation.bind(to: nil)
    }

    private func stopObservingDesktopScreenChanges() {
        if let desktopScreenObserver { NotificationCenter.default.removeObserver(desktopScreenObserver) }
        desktopScreenObserver = nil
    }

    /// Retire an obsolete window whose requested fullscreen exit failed while it was still
    /// fullscreen. The window can never present the desktop rendition and must not be reused: unbind
    /// its visibility observation, detach only its hosted layer, let it clear its delegate and
    /// close/hide once, then drop the host's reference. The next `present` builds a fresh window.
    private func retireWindow() {
        guard let retiring = window else { return }
        windowTransitionPending = false
        stopObservingDesktopScreenChanges()
        visibilityObservation.bind(to: nil)
        retiring.detachWatchLayer()
        retiring.retireWatchWindow()
        window = nil
    }

    private func ensureWindow() -> WatchPresentingWindow {
        if let window { return window }
        let created = makeWindow()
        if let real = created as? NSWindow { real.delegate = self }
        if let watch = created as? WatchPresentationWindow {
            // Capture the surface weakly and re-check its identity: a gesture owned by a retired (or
            // replaced) window must never toggle the run the host drives now.
            watch.onVideoDoubleClick = { [weak self, weak watch] in
                guard let self, let watch else { return }
                self.videoContentDoubleClicked(from: watch)
            }
        }
        window = created
        return created
    }

    // MARK: - NSWindowDelegate (real windows; tests drive the same handlers directly)

    /// Close hides the presentation and keeps the song session, item, clock and pause intent.
    public func requestClose() -> Bool {
        apply(reducer.closeRequested())
        return false
    }

    /// Close with the closing window's identity. A close delivered by a window this host no longer
    /// drives (for example a retired window's delayed callback) is refused without touching the
    /// run. A missing identity is rejected as well.
    public func requestClose(from object: Any?) -> Bool {
        guard isHostWindow(object) else { return false }
        return requestClose()
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        requestClose(from: sender)
    }

    /// Failed entry hides the song surface and keeps playback available from home.
    public func enterFullScreenFailed() {
        AppLog.error("watch.fullscreen-enter-failed session=\(reducer.sessionID ?? "none") actual-fullscreen=\(window?.isWatchFullScreen ?? false)")
        windowTransitionPending = false
        apply(reducer.didFailToEnterFullScreen())
    }

    /// A failed fullscreen exit. The reducer is told the window's *actual* native state, so an
    /// active run that is really still fullscreen keeps its true state and layer. When a released
    /// run's obsolete window is still fullscreen it is retired here, and any pending ready+eligible
    /// run then presents through the reducer's own effect.
    public func exitFullScreenFailed() {
        AppLog.error("watch.fullscreen-exit-failed session=\(reducer.sessionID ?? "none") actual-fullscreen=\(window?.isWatchFullScreen ?? false)")
        awaitingProgrammaticExit = false
        windowTransitionPending = false
        let stillFullScreen = window?.isWatchFullScreen ?? false
        let wasEnding = reducer.isEnding
        let effect = reducer.didFailToExitFullScreen(isFullScreen: stillFullScreen)
        if wasEnding, stillFullScreen { retireWindow() }
        apply(effect)
    }

    public func windowDidChangeOcclusionState(_ notification: Notification) {
        visibilityObservation.receive(notification)
    }

    /// AppKit delegate notifications are accepted only when they belong to the window this host
    /// actually drives; a notification or callback carrying another window cannot mutate the run.
    /// Identity is compared on object identity, so the injectable window surface is covered too.
    /// A missing identity cannot establish that a callback belongs to the current window.
    private func isHostWindow(_ object: Any?) -> Bool {
        guard let object else { return false }
        guard let notified = object as AnyObject?, let window = window as AnyObject? else { return false }
        return ObjectIdentifier(notified) == ObjectIdentifier(window)
    }

    /// A native transition has *begun* — the run's own request, or the green button/Esc/system
    /// transition the host never requested. Marking it pending here is what makes a duplicate
    /// double-click during the animation inert; only the matching did/failed callback clears it. A
    /// notification from a window this host does not drive (for example a retired window) is refused.
    ///
    /// The reducer is told about the entry too, so a red close/double-click during a native entry it
    /// never requested still parks and defers its close until the entry lands instead of
    /// letting the transition complete into fullscreen. For a released or ending run the reducer
    /// seam is inert, and a repeated callback never clears a latched return intent.
    public func windowWillEnterFullScreen(_ notification: Notification) {
        guard isHostWindow(notification.object) else { return }
        AppLog.info("watch.fullscreen-will-enter session=\(reducer.sessionID ?? "none")")
        reducer.willEnterFullScreen()
        windowTransitionPending = true
        publishPresentation()
    }

    public func windowWillExitFullScreen(_ notification: Notification) {
        guard isHostWindow(notification.object) else { return }
        AppLog.info("watch.fullscreen-will-exit session=\(reducer.sessionID ?? "none")")
        windowTransitionPending = true
        publishPresentation()
    }

    public func windowDidEnterFullScreen(_ notification: Notification) {
        guard isHostWindow(notification.object) else { return }
        AppLog.info("watch.fullscreen-did-enter session=\(reducer.sessionID ?? "none")")
        windowTransitionPending = false
        apply(reducer.didEnterFullScreen())
        // A run that was released while entering converges only after AppKit really entered, so
        // request its exit here. Guarded by the remaining run state, so a stale callback is inert.
        if reducer.isExitDeferredForEnter {
            requestExit()
        }
    }

    public func windowDidExitFullScreen(_ notification: Notification) {
        guard isHostWindow(notification.object) else { return }
        AppLog.info("watch.fullscreen-did-exit session=\(reducer.sessionID ?? "none") programmatic=\(awaitingProgrammaticExit)")
        windowTransitionPending = false
        let programmatic = awaitingProgrammaticExit
        awaitingProgrammaticExit = false
        apply(reducer.didExitFullScreen(programmatic: programmatic))
    }

    public func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        guard isHostWindow(window) else { return }
        enterFullScreenFailed()
    }

    /// AppKit refused to complete the requested fullscreen exit (for example the window was moved
    /// or the transition was cancelled). The host reads the window's actual state, retires it when
    /// it is an obsolete still-fullscreen window, and converges without a retry loop. A stale
    /// callback from a window this host no longer drives is rejected before any state change.
    public func windowDidFailToExitFullScreen(_ window: NSWindow) {
        guard isHostWindow(window) else { return }
        exitFullScreenFailed()
    }

    deinit {
        stopObservingDesktopScreenChanges()
        visibilityObservation.onChange = nil
    }
}
