// Native presentation for the retained home window. It owns no playback or navigation state.
import AppKit
import Combine
import BSidePlatform

final class CompanionWindowPresentation: ObservableObject {
    @Published private(set) var isFullScreen = false
    // Prepare the destination geometry during AppKit's transition, without claiming success.
    @Published private(set) var usesImmersiveLayout = false
    @Published private(set) var isTransitioning = false
    @Published private(set) var failure: String?
    private weak var window: NSWindow?
    // The seam executes the same native action in production and permits deterministic rejection
    // and stale-window tests without entering fullscreen on the owner's desktop.
    var performToggle: (NSWindow) -> Void = { $0.toggleFullScreen(nil) }

    func attach(_ window: NSWindow) {
        self.window = window
        isFullScreen = window.styleMask.contains(.fullScreen)
        setLayout(fullScreen: isFullScreen)
        isTransitioning = false; failure = nil
    }
    func toggle() { request(fullScreen: !isFullScreen) }
    func request(fullScreen: Bool) {
        guard let window, !isTransitioning,
              window.styleMask.contains(.fullScreen) != fullScreen else { return }
        failure = nil; isTransitioning = true
        log("request", window: window)
        performToggle(window)
    }
    func willTransition(_ window: NSWindow?) {
        guard let window, self.window === window else { return }
        isTransitioning = true; failure = nil
        setLayout(fullScreen: !isFullScreen)
        log("will-transition", window: window)
    }
    func didTransition(_ window: NSWindow?) {
        guard let window, self.window === window else { return }
        isFullScreen = window.styleMask.contains(.fullScreen)
        setLayout(fullScreen: isFullScreen)
        isTransitioning = false; failure = nil
        log("did-transition", window: window)
    }
    func failed(_ window: NSWindow) {
        guard self.window === window else { return }
        isFullScreen = window.styleMask.contains(.fullScreen)
        setLayout(fullScreen: isFullScreen)
        isTransitioning = false
        failure = "未能切换全屏，画面和音乐会继续播放。"
        log("failed", window: window)
    }
    private func setLayout(fullScreen: Bool) {
        if usesImmersiveLayout != fullScreen { usesImmersiveLayout = fullScreen }
    }
    private func log(_ event: String, window: NSWindow) {
        AppLog.control("companion-window.\(event) window=\(window.windowNumber) policy=\(NSApp.activationPolicy().rawValue) collection=\(window.collectionBehavior.rawValue) style=\(window.styleMask.rawValue) fullscreen=\(window.styleMask.contains(.fullScreen)) immersive-layout=\(usesImmersiveLayout) visible=\(window.isVisible)")
    }
}

class CompanionMainWindow: NSWindow {
    var exitCompanionFullScreen: () -> Void = {}
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53, styleMask.contains(.fullScreen) {
            exitCompanionFullScreen()
            return
        }
        super.sendEvent(event)
    }
}
