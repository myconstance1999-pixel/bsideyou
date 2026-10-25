import SwiftUI
import BSideCore
import BSidePlatform

private typealias CompanionTitleState = State<String>

/// A read-only projection of the selected daily source. It owns no playback state or player.
final class CompanionHomePreview: ObservableObject {
    @Published private(set) var result: DailyBackgroundPreviewResult?
    var request: (ContentKey, DailyPreviewPixelSize, @escaping (DailyBackgroundPreviewResult) -> Void) -> Void = { _, _, _ in }
    var cancel: () -> Void = {}
    var toggleFullScreen: () -> Void = {}
    var streamChanged: (HomeCompanionStreamRequest) -> Void = { _ in }
    var acknowledge: (HomeCompanionFrameAcknowledgement) -> Void = { _ in }
    private var receiver: HomeCompanionFrameReceiver?
    private weak var frameView: HomeCompanionFrameView?
    private var retainedFrame: CGImage?
    private var nativeVisible = false
    private var agentAvailable = false
    private var key: ContentKey?
    private var size: DailyPreviewPixelSize?
    private var mounted = false
    private var windowVisible = false
    private var chooserPresented = false
    private var generation = 0
    private var pending = false

    func update(key: ContentKey?, windowVisible: Bool) {
        if self.key != key {
            invalidate(); self.key = key
            AppLog.control("home-preview.key key=\(key?.description ?? "none")")
        }
        if self.windowVisible != windowVisible {
            AppLog.control("home-preview.visibility visible=\(windowVisible)")
        }
        self.windowVisible = windowVisible
        reconcile()
    }
    func geometry(_ size: CGSize, scale: CGFloat) {
        let pixels = DailyPreviewPixelSize.forRenderedContainer(size: size, scale: scale)
        guard self.size != pixels else { return }
        AppLog.control("home-preview.geometry pixels=\(pixels.width)x\(pixels.height)")
        // A completed fallback remains valid at another size. Resizing must not launch extraction.
        self.size = pixels; reconcile()
    }
    func setMounted(_ value: Bool) {
        if mounted != value { AppLog.control("home-preview.mount mounted=\(value)") }
        mounted = value; reconcile()
    }
    func setChooserPresented(_ value: Bool) {
        if chooserPresented != value { AppLog.control("home-preview.chooser presented=\(value)") }
        chooserPresented = value; reconcile()
    }
    func invalidate() {
        if pending || result != nil {
            AppLog.control("home-preview.invalidate generation=\(generation) pending=\(pending)")
        }
        generation += 1; cancel(); pending = false; result = nil
    }
    func attach(_ view: HomeCompanionFrameView) {
        frameView = view
        if let retainedFrame { view.display(retainedFrame) }
    }
    func setNativeVisible(_ value: Bool, view: HomeCompanionFrameView) {
        guard frameView === view else { return }
        if nativeVisible != value { AppLog.control("home-stream.visibility visible=\(value)") }
        nativeVisible = value; reconcileStream()
    }
    func detach(_ view: HomeCompanionFrameView) {
        guard frameView === view else { return }
        nativeVisible = false; frameView = nil; reconcileStream()
    }
    /// A new Agent generation receives a fresh capability, never a previous process's slot.
    func agentReady() { stopStream(); agentAvailable = true; reconcileStream() }
    func agentLost() { agentAvailable = false; stopStream() }
    func fullScreenTransitionFailed() { (frameView as? CompanionFrameSurfaceView)?.finishFullScreenTransition() }
    func traceFullScreen(event: String, beginning: Bool) {
        guard HomeCompanionFrameReceiver.transitionTracingEnabled else { return }
        guard let receiver else {
            AppLog.control("home-transition.summary event=\(event) terminal=no-stream monotonic-ms=\(ProcessInfo.processInfo.systemUptime * 1000)")
            return
        }
        if beginning { receiver.beginTransitionTrace(event: event) }
        else { receiver.completeTransitionTrace(event: event) }
    }

    func receive(_ frame: HomeCompanionFrame) {
        guard let receiver else { return }
        receiver.receive(frame) { [weak self, weak receiver] image, acknowledgement in
            guard let self, let receiver, self.receiver === receiver else { return }
            self.retainedFrame = image
            let presentationStart = receiver.isTracingTransition ? ProcessInfo.processInfo.systemUptime : nil
            self.frameView?.display(image)
            let submitted = presentationStart.map { _ in ProcessInfo.processInfo.systemUptime }
            if receiver.copiedFrames == 1 {
                AppLog.control("home-stream.first-frame stream=\(frame.streamID) content=\(frame.contentID) size=\(frame.width)x\(frame.height)")
            }
            // The immutable image owns its bytes before the Agent may reuse the mapped slot.
            let acknowledgementStart = presentationStart.map { _ in ProcessInfo.processInfo.systemUptime }
            self.acknowledge(acknowledgement)
            if let presentationStart, let submitted, let acknowledgementStart {
                receiver.tracePresentation(sequence: acknowledgement.sequence, started: presentationStart,
                    submitted: submitted, acknowledgementStarted: acknowledgementStart,
                    acknowledged: ProcessInfo.processInfo.systemUptime)
            }
        }
    }
    private func stopStream() {
        guard let receiver else { return }
        AppLog.control("home-stream.withdraw stream=\(receiver.stream?.id ?? "none")")
        streamChanged(.init())
        receiver.invalidate(); self.receiver = nil
    }
    private func reconcileStream() {
        guard agentAvailable, mounted, nativeVisible, !chooserPresented, frameView != nil else {
            stopStream(); return
        }
        guard receiver == nil else { return }
        do {
            let receiver = try HomeCompanionFrameReceiver()
            self.receiver = receiver
            AppLog.control("home-stream.create stream=\(receiver.stream!.id)")
            streamChanged(.init(stream: receiver.stream))
        } catch { AppLog.control("home-stream.unavailable buffer-creation") }
    }

    private func reconcile() {
        reconcileStream()
        guard mounted, windowVisible, !chooserPresented else {
            if pending {
                AppLog.control("home-preview.cancel generation=\(generation) mounted=\(mounted) visible=\(windowVisible) chooser=\(chooserPresented)")
                generation += 1; cancel(); pending = false
            }
            return
        }
        guard !pending, result == nil, let key, let size else { return }
        generation += 1
        let token = generation
        pending = true
        AppLog.control("home-preview.request generation=\(token) key=\(key.description) pixels=\(size.width)x\(size.height)")
        request(key, size) { [weak self] outcome in
            guard let self else { return }
            guard self.generation == token, self.mounted, self.windowVisible,
                  !self.chooserPresented, self.key == outcome.key else {
                AppLog.control("home-preview.completion-rejected generation=\(token) current=\(self.generation) mounted=\(self.mounted) visible=\(self.windowVisible) chooser=\(self.chooserPresented)")
                return
            }
            AppLog.control("home-preview.completed generation=\(token) key=\(outcome.key.description) result=\(outcome.data == nil ? "unavailable" : "image")")
            self.pending = false
            self.result = outcome
        }
    }
}

struct CompanionHomeArtwork: View {
    @ObservedObject var model: CompanionHomePreview
    var immersive = false
    @Environment(\.displayScale) private var displayScale
    private var canvasColor: Color { immersive ? .black : MusicWorkspaceAppearance.inset }
    var body: some View {
        GeometryReader { geometry in
            Group {
                if let data = model.result?.data, let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .background(canvasColor)
                        .accessibilityLabel("所选陪伴视频")
                } else {
                    canvasColor.overlay {
                        VStack(spacing: 8) {
                            Image(systemName: "photo")
                            Text(model.result?.failure ?? "正在准备场景预览")
                                .font(.caption).multilineTextAlignment(.center)
                        }.foregroundStyle(.secondary).padding()
                            .opacity(immersive ? 0 : 1).accessibilityHidden(immersive)
                    }
                }
            }
            .onAppear { model.geometry(geometry.size, scale: displayScale) }
            .onChange(of: geometry.size) { model.geometry($0, scale: displayScale) }
            .onChange(of: displayScale) { model.geometry(geometry.size, scale: $0) }
        }
        .overlay(CompanionFrameSurface(model: model, cornerRadius: immersive ? 0 : 16))
        // Mount belongs to the persistent artwork surface, not its placeholder/image branch.
        .onAppear { model.setMounted(true) }
        .onDisappear { model.setMounted(false) }
        .clipShape(RoundedRectangle(cornerRadius: immersive ? 0 : 16))
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: model.toggleFullScreen)
    }
}

/// The window compositor owns the picture's geometry, including drag, fullscreen and Spaces.
private struct CompanionFrameSurface: NSViewRepresentable {
    let model: CompanionHomePreview
    let cornerRadius: CGFloat
    func makeNSView(context: Context) -> CompanionFrameSurfaceView {
        let view = CompanionFrameSurfaceView()
        view.model = model
        model.attach(view)
        return view
    }
    func updateNSView(_ view: CompanionFrameSurfaceView, context: Context) {
        if view.layer?.cornerRadius != cornerRadius {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            view.layer?.cornerRadius = cornerRadius
            CATransaction.commit()
        }
        model.attach(view); view.scheduleVisibility()
    }
    static func dismantleNSView(_ view: CompanionFrameSurfaceView, coordinator: ()) { view.detach() }
}

class CompanionFrameSurfaceView: HomeCompanionFrameView {
    weak var model: CompanionHomePreview?
    private var observations: [NSObjectProtocol] = []
    private var reportPending = false
    private var generation = 0
    private var wasVisible = false
    private var fullScreenTransition = false
    var applicationIsActive: Bool { NSApp.isActive }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeObservations()
        guard let window else { model?.setNativeVisible(false, view: self); return }
        let center = NotificationCenter.default
        let names: [Notification.Name] = [NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
            NSWindow.willBeginSheetNotification, NSWindow.didEndSheetNotification,
            NSWindow.didBecomeKeyNotification, NSWindow.didChangeScreenNotification]
        for name in names {
            observations.append(center.addObserver(forName: name, object: window, queue: nil) { [weak self] _ in
                self?.scheduleVisibility()
            })
        }
        for name in [NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification,
                     NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            observations.append(center.addObserver(forName: name, object: window, queue: nil) { [weak self] _ in
                guard let self else { return }
                self.fullScreenTransition = name == NSWindow.willEnterFullScreenNotification || name == NSWindow.willExitFullScreenNotification
                AppLog.control("home-stream.fullscreen event=\(name.rawValue)")
                self.model?.traceFullScreen(event: name.rawValue, beginning: self.fullScreenTransition)
                self.scheduleVisibility()
            })
        }
        observations.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.generation += 1; self.reportPending = false
            self.wasVisible = false; self.fullScreenTransition = false
            self.model?.setNativeVisible(false, view: self)
        })
        for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification,
                     NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            observations.append(center.addObserver(forName: name, object: NSApp, queue: nil) { [weak self] _ in self?.scheduleVisibility() })
        }
        scheduleVisibility()
    }
    override func layout() { super.layout(); scheduleVisibility() }
    override func viewDidEndLiveResize() { super.viewDidEndLiveResize(); scheduleVisibility() }
    func scheduleVisibility() {
        guard !reportPending else { return }
        reportPending = true
        let token = generation
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) { [weak self] in
            guard let self, self.generation == token else { return }
            self.reportPending = false
            let visible: Bool
            if let window = self.window {
                // AppKit can transiently report occlusion/empty visibleRect during an ongoing
                // native resize. Preserve only previously visible content on the active Space;
                // actual hide, minimize, sheet and end-of-resize observations still withdraw.
                let resizingVisibleWindow = self.inLiveResize && self.wasVisible && window.isOnActiveSpace
                // AppKit can deliver a stale occlusion flag immediately after native fullscreen
                // completion. A key window of the active app on this Space is independently visible.
                let activeKeyWindow = window.isKeyWindow && self.applicationIsActive && window.isOnActiveSpace
                visible = window.isVisible && !window.isMiniaturized && !NSApp.isHidden
                    && (window.occlusionState.contains(.visible) || (self.fullScreenTransition && self.wasVisible)
                        || resizingVisibleWindow || activeKeyWindow)
                    && window.attachedSheet == nil && !self.isHiddenOrHasHiddenAncestor
                    && (!self.visibleRect.isEmpty || resizingVisibleWindow)
                if visible != self.wasVisible {
                    AppLog.control("home-stream.visibility-reason visible=\(visible) window=\(window.isVisible) mini=\(window.isMiniaturized) hidden=\(NSApp.isHidden) occluded=\(!window.occlusionState.contains(.visible)) active-space=\(window.isOnActiveSpace) resize=\(self.inLiveResize) rect-empty=\(self.visibleRect.isEmpty) key=\(window.isKeyWindow) app-active=\(self.applicationIsActive) event=\(NSApp.currentEvent?.type.rawValue ?? 0)")
                }
            } else { visible = false }
            self.wasVisible = visible
            self.model?.setNativeVisible(visible, view: self)
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }
    func finishFullScreenTransition() {
        fullScreenTransition = false
        AppLog.control("home-stream.fullscreen event=failed")
        model?.traceFullScreen(event: "failed", beginning: false)
        scheduleVisibility()
    }
    private func removeObservations() {
        generation += 1; reportPending = false
        observations.forEach(NotificationCenter.default.removeObserver); observations.removeAll()
    }
    func detach() { removeObservations(); model?.detach(self) }
    deinit { observations.forEach(NotificationCenter.default.removeObserver) }
}

/// The existing study owner with a visible-only readout. Hiding this view never pauses or
/// finishes a session; its draft title is the only local view state.
struct CompactStudyTimer: View {
    @ObservedObject var study: StudyTimerController
    let close: () -> Void
    @CompanionTitleState private var title = ""
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        studyCard
            .onAppear { title = study.ledger.title }
            .onChange(of: study.ledger.title) { title = $0 }
            .onDisappear { saveTitle() }
            .accessibilityIdentifier("home-study-controls")
    }

    private var studyCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("自习", systemImage: "book.closed")
                    .font(.callout.weight(.medium))
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(.plain).help("收起计时，当前自习会继续")
                    .accessibilityLabel("收起自习计时")
                    .accessibilityIdentifier("home-study-close")
            }
            .foregroundStyle(.secondary)
            Picker("计时方式", selection: Binding(get: { study.ledger.mode }, set: study.selectMode)) {
                Text("正计时").tag(StudyTimerMode.countUp)
                Text("倒计时").tag(StudyTimerMode.countdown)
            }
            .pickerStyle(.segmented)
            .disabled(study.ledger.active != nil || study.loadFailed)
            .accessibilityIdentifier("music-study-mode")
            if study.isRunning {
                TimelineView(.periodic(from: .now, by: 1)) { _ in readout }
            } else {
                readout
            }
            TextField("自习名称（可选）", text: $title)
                .textFieldStyle(.plain)
                .padding(9)
                .background(MusicWorkspaceAppearance.inset.opacity(0.65), in: RoundedRectangle(cornerRadius: 7))
                .disabled(study.ledger.active != nil || study.loadFailed)
                .onSubmit { saveTitle() }
                .accessibilityIdentifier("music-study-title")
            if study.ledger.mode == .countdown {
                Stepper(value: Binding(get: { study.ledger.countdownMinutes },
                                       set: { study.configure(minutes: $0) }), in: 1...240) {
                    Text("\(study.ledger.countdownMinutes) 分钟").font(.callout).monospacedDigit()
                }
                .disabled(study.ledger.active != nil || study.loadFailed)
                .accessibilityIdentifier("music-study-duration")
            }
            HStack(spacing: 8) {
                Button {
                    saveTitle()
                    study.toggle()
                } label: {
                    Label(study.isRunning ? "暂停" : study.ledger.active != nil ? "继续" : "开始",
                          systemImage: study.isRunning ? "pause.fill" : "play.fill")
                        .font(.callout.weight(.medium)).padding(.horizontal, 12).padding(.vertical, 9)
                        .foregroundStyle(MusicWorkspaceAppearance.actionForeground(for: colorScheme))
                        .background(MusicWorkspaceAppearance.accent, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain).disabled(study.loadFailed)
                .accessibilityIdentifier("music-study-toggle")
                if study.ledger.active != nil {
                    Button("结束并记录", action: study.finish)
                        .buttonStyle(.plain).font(.caption)
                        .accessibilityIdentifier("music-study-finish")
                }
            }
            if let error = study.error {
                Text(error).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("重试", action: study.retry).controlSize(.small)
            }
        }
        .padding(17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MusicWorkspaceAppearance.surface, in: RoundedRectangle(cornerRadius: 12))
        .tint(MusicWorkspaceAppearance.accent)
    }

    private var readout: some View {
        StudyTimerReadout(state: study.presentation, compact: true, timeSize: 42, alignment: .leading)
            .minimumScaleFactor(0.75).lineLimit(1)
    }

    private func saveTitle() {
        guard study.ledger.active == nil, title != study.ledger.title else { return }
        study.configure(title: title)
    }
}
