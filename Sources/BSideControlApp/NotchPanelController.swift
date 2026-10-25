// BSideControlApp — bsideyou island: AppKit window ownership.
//
// ONE ordinary nonactivating NSPanel, never a desktop video host and never a second surface per
// display. It hangs from the top-centre of the built-in notched display when one is present,
// otherwise the main display, anchored to the same top edge the geometry seam derives so every
// readable control stays below the hardware and remains reachable.
//
// Ownership rules enforced here:
//   * `NotchPanelGeometry` decides WHERE (one pure seam, including the reserved hardware band, the
//     transient proportion and the per-page size);
//   * `NotchPanelPresentation` decides WHEN (one pure state machine, latest-intent delayed entry
//     and leave grace) and `NotchIslandPageModel` decides WHICH page;
//   * `NotchFrameTransition` owns the generation of the in-flight finite frame animation;
//   * this controller only creates/animates/orders the one window, observes the public
//     screen-parameters notification (event-driven reposition, no polling) and never activates the
//     application or opens the main window for a routine adjustment;
//   * the RESTING surface is COMPLETELY INVISIBLE on every display: on a notched display the window
//     covers exactly the public cutout, with no below-camera activation area and never
//     adjacent menu items; without a notch it is a 120x14 transparent target below the menu bar;
//   * expansion/collapse/page change/profile change animates the ACTUAL window geometry over a
//     finite 0.14s ease-out from the same top-centre anchor, so the island grows out of / retracts
//     into the hidden cutout instead of an instantly resized rectangle. Reduce Motion snaps. This
//     uses only the supported `NSAnimationContext`/`animator()` behavior — there is no custom
//     animation engine: a rapid reversal simply starts the next bounded animation, and the
//     superseded transition's completion is discarded by its generation token;
//   * the final frame is snapped exactly, so the collapsed window/hit region is byte-exact after
//     the transition and no permanently wide invisible surface is left behind;
//   * the panel is shown with `orderFrontRegardless()` and is made key only for an EXPLICIT
//     click/menu expansion — including when the island was already hover-expanded — so hover never
//     activates the application or steals focus;
//   * a screen-parameters change cancels any pending entry/collapse, invalidates the in-flight
//     animation completion and snaps to the new display's geometry; `shutdown()` does the same for
//     quit and then orders the panel out/closed, so a quit cannot leave a timer or a window behind;
//   * the workspace session/sleep events (public NSWorkspace notifications, no global hook and no
//     Spaces reassert loop) order the panel out and cancel hover work, and only ever restore the
//     COLLAPSED island on active/wake. `canBecomeVisibleWithoutLogin` is false, so the panel can
//     never be shown above the system login window or lock UI;
//   * no playback, queue, preference or video API is touched anywhere in this file.

import AppKit
import BSidePlatform
import Combine
import QuartzCore
import SwiftUI

/// Borderless nonactivating panel that can still become key for Esc/close-button keyboard access
/// without bringing the whole application forward.
final class NotchPanel: NSPanel {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) { onEscape?() }

    /// Never let AppKit constrain the island to the visible frame. Without this public override the
    /// closed panel is pushed BELOW the menu bar / hardware band (an actual `maxY` of 950 in
    /// `PLACEMENT_EVIDENCE.md`, i.e. Quartz Y33), which leaves a visible strip under the cutout and
    /// breaks the whole concealment contract. `visibleFrame` excludes the menu bar and the notch, so
    /// the default `constrainFrameRect` would defeat the placement this seam computes exactly.
    /// The topology (return the proposed rect unchanged) follows Atoll's notch panel
    /// (`Sources/Atoll/Core/NotchPanel.swift`, MIT, commit ea20f5541bb9ae8c300b20fb99a7b48665adb158,
    /// read and adapted for this file); see `THIRD_PARTY_NOTICES.md` for the exact mapping.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }
}

/// Hosting view that accepts a first mouse click, so the nonactivating panel's controls respond to
/// the owner's very first click instead of requiring a focus-activating click first.
final class NotchHostingView<Content: View>: NSHostingView<Content> {
    required init(rootView: Content) {
        super.init(rootView: rootView)
        // The controller owns the animated frame. Publishing the expanded SwiftUI minimum size
        // would resize the panel at its old origin before that animation can place it.
        sizingOptions = []
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        sizingOptions = []
    }

    /// One viewport-owned area survives SwiftUI content insertion and removal. AppKit keeps its
    /// visible rectangle synchronized with the actual animated window, including non-key hover.
    var onViewportHoverChange: ((Bool) -> Void)?
    private(set) var viewportTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard viewportTrackingArea == nil else { return }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        viewportTrackingArea = area
        addTrackingArea(area)
    }

    /// Coordinate-only seam used by hidden-view checks; it emits no system event.
    func pointerIsInsideViewport(_ screenPoint: CGPoint) -> Bool {
        guard let window else { return false }
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let localPoint = convert(windowPoint, from: nil)
        return NSMouseInRect(localPoint, visibleRect, isFlipped)
    }

    override func mouseEntered(with event: NSEvent) {
        guard event.trackingArea === viewportTrackingArea else {
            super.mouseEntered(with: event)
            return
        }
        onViewportHoverChange?(pointerIsInsideViewport(NSEvent.mouseLocation))
    }

    override func mouseExited(with event: NSEvent) {
        guard event.trackingArea === viewportTrackingArea else {
            super.mouseExited(with: event)
            return
        }
        // A frame/content update may deliver an edge notification. Resolve it against the current
        // physical pointer and viewport, rather than treating the notification itself as a leave.
        onViewportHoverChange?(pointerIsInsideViewport(NSEvent.mouseLocation))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class NotchPanelController {
    /// Read-only snapshot of what the ONE owned panel ACTUALLY is, for the runtime acceptance seam.
    /// Contains no product state and is never polled by the product.
    struct PanelState: Equatable {
        var requestedFrame: CGRect
        var actualFrame: CGRect
        var level: Int
        var canJoinAllSpaces: Bool
        var canJoinAllApplications: Bool
        var fullScreenAuxiliary: Bool
        var canBecomeVisibleWithoutLogin: Bool
        var isFloatingPanel: Bool
        var isOpaque: Bool
        var hasShadow: Bool
        var isVisible: Bool
        var surfaceIsVisible: Bool
        var sharpArtworkIsVisible: Bool
    }

    /// Read-only runtime seam: the requested/actual frame, the level and the Space behavior of the
    /// panel this controller owns (not of a duplicated test instance). Lets the regression prove the
    /// real placement/level contract on the real object.
    func panelState() -> PanelState? {
        guard let panel else { return nil }
        return PanelState(requestedFrame: frameTransition.target,
                          actualFrame: panel.frame,
                          level: panel.level.rawValue,
                          canJoinAllSpaces: panel.collectionBehavior.contains(.canJoinAllSpaces),
                          canJoinAllApplications: panel.collectionBehavior.contains(.canJoinAllApplications),
                          fullScreenAuxiliary: panel.collectionBehavior.contains(.fullScreenAuxiliary),
                          canBecomeVisibleWithoutLogin: panel.canBecomeVisibleWithoutLogin,
                          isFloatingPanel: panel.isFloatingPanel,
                          isOpaque: panel.isOpaque,
                          hasShadow: panel.hasShadow,
                          isVisible: panel.isVisible,
                          surfaceIsVisible: presentation.surfaceIsVisible,
                          sharpArtworkIsVisible: presentation.sharpArtworkIsVisible)
    }

    /// The exact expanded OUTER size the island draws at on the display currently hosting it, for
    /// the current page and proportion.
    var currentExpandedSize: CGSize? {
        guard let descriptor = Self.preferredScreen().map(Self.descriptor) else { return nil }
        return NotchPanelGeometry.expandedSize(descriptor, page: pageModel.page,
                                               profile: presentation.profileModel.profile)
    }

    let presentation = NotchPanelPresentation()
    let pageModel = NotchIslandPageModel()
    /// Finite transition duration of the one window frame. The product value is
    /// `NotchPanelGeometry.transitionDuration`; the runtime regression may shorten it so it can wait
    /// for a REALLY settled frame instead of a wall-clock heuristic.
    var transitionDuration: TimeInterval = NotchPanelGeometry.transitionDuration
    /// Reduce Motion is read at transition time; never observed with a timer. It is an instance
    /// property so the regression can force the non-animated path deterministically.
    var reduceMotionProvider: () -> Bool = { NotchPanelController.systemReduceMotion }
    /// Physical pointer position sampled only when a finite frame change settles.
    var pointerLocationProvider: () -> CGPoint = { NSEvent.mouseLocation }
    var reduceMotion: Bool {
        get { reduceMotionProvider() }
        set { reduceMotionProvider = { newValue } }
    }
    private let contentBuilder: (NotchPanelPresentation, NotchIslandPageModel, NotchShelfLayout) -> NotchPanelRootView
    /// Called whenever the island leaves the background page (back, close, collapse, screen change
    /// or shutdown), so the shared chooser cancels its in-flight preview and drops its displayed
    /// still. Presentation only: it never applies a background or sends a playback command.
    private let onLeaveBackgroundPage: () -> Void
    private var panel: NotchPanel?
    private var hosting: NotchHostingView<NotchPanelRootView>?
    private var screenObserver: NSObjectProtocol?
    private var pageObserver: AnyCancellable?
    private var profileObserver: AnyCancellable?
    private var motionObserver: NSObjectProtocol?
    private var workspaceObservers: [NSObjectProtocol] = []
    /// Newest frame intent and the generation of its finite animation.
    private var frameTransition = NotchFrameTransition()
    private var currentLayout: NotchShelfLayout?
    /// True while a workspace session-resign/sleep event has ordered the panel out. Nothing may
    /// re-show it until the matching active/wake event restores the COLLAPSED island.
    private var isSuspendedForWorkspace = false
    /// Last page the panel actually presented, so leaving the background page can release the
    /// shared chooser exactly once.
    private var lastPresentedPage: NotchIslandPage = .main

    init(onLeaveBackgroundPage: @escaping () -> Void = {},
         contentBuilder: @escaping (NotchPanelPresentation, NotchIslandPageModel,
                                    NotchShelfLayout) -> NotchPanelRootView) {
        self.onLeaveBackgroundPage = onLeaveBackgroundPage
        self.contentBuilder = contentBuilder
        presentation.autoEntryDelay = NotchPanelGeometry.hoverEntryDelay
        presentation.autoCollapseDelay = NotchPanelGeometry.hoverCollapseDelay
        presentation.onExplicitKeyEligible = { [weak self] in
            self?.applyKeyboardAccess()
        }
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let motionObserver { NSWorkspace.shared.notificationCenter.removeObserver(motionObserver) }
        let center = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers { center.removeObserver(observer) }
    }

    var isInstalled: Bool { panel != nil }
    var isExpanded: Bool { presentation.isExpanded }
    var currentPage: NotchIslandPage { pageModel.page }
    /// Diagnostics for the read-only runtime seam (never polled by the product).
    var lastRequestedFrame: CGRect { frameTransition.target }
    /// Generation of the newest frame intent. A keyboard promotion of already-correct geometry must
    /// NOT advance it, so the regression can prove an in-flight transition was left running.
    var frameIntentGeneration: Int { frameTransition.generation }
    /// How many frame completions were discarded because a newer intent had superseded them.
    var staleFrameCompletionCount: Int { frameTransition.staleCompletionCount }
    /// Number of workspace observers currently installed (0 after shutdown). Diagnostics only.
    var workspaceObserverCount: Int { workspaceObservers.count }
    /// True while a workspace session-resign/sleep event has hidden the panel.
    var isHiddenForWorkspaceEvent: Bool { isSuspendedForWorkspace }

    /// Create the one retained panel (idempotent) and show it collapsed on the current page.
    func install() {
        guard panel == nil else { return }
        // Prepare the current bundled scene before the first hover expansion.
        _ = NotchSceneImageStore.shared.image(for: presentation.sceneModel.choice)
        let screen = Self.preferredScreen()
        let descriptor = screen.map(Self.descriptor) ?? NotchScreenDescriptor(frame: .zero)
        let profile = presentation.profileModel.profile
        let layout = NotchPanelGeometry.layout(on: descriptor, page: pageModel.page, profile: profile)
        currentLayout = layout

        let rootView = contentBuilder(presentation, pageModel, layout)
        let hosting = NotchHostingView(rootView: rootView)
        let rect = NotchPanelGeometry.panelRect(for: .collapsed, on: descriptor)

        let panel = NotchPanel(contentRect: rect,
                               styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        panel.onEscape = { [weak self] in self?.collapse() }
        // Public AppKit fullscreen overlay, in the required order: the panel must ALREADY be a
        // floating panel before its final window level is applied. `isFloatingPanel`'s setter resets
        // the level, so assigning the level first silently produced a level-3 panel that dropped out
        // of the intended status-bar layer (see PLACEMENT_EVIDENCE.md). The level is therefore set
        // strictly AFTER the floating flag.
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NotchPanelConfiguration.windowLevel)
        // Above ordinary windows, joins every Space INCLUDING native fullscreen and other
        // applications' sets, but never moves this or another window and uses no private Spaces API
        // and no permission hook. Review-only experimental coverage (see NotchPanelConfiguration).
        panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications,
                                    .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.canBecomeVisibleWithoutLogin = NotchPanelConfiguration.canBecomeVisibleWithoutLogin
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovable = false
        panel.isOpaque = false
        // Transparent window backing store: the SwiftUI content owns every pixel, so the collapsed
        // trigger is truly invisible and the island body is the only surface ever drawn.
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        // The hosting view is the content view, so the window always resizes it: the window frame is
        // the ONLY thing that morphs. The SwiftUI body is laid out at its FULL page size and clipped
        // by the moving surface, so the island controls never squash or reflow.
        panel.contentView = hosting

        self.panel = panel
        self.hosting = hosting
        hosting.onViewportHoverChange = { [weak self] hovering in
            guard let self, let panel = self.panel, !self.isSuspendedForWorkspace else { return }
            // Event-only review evidence, not a timer or a user-facing status field.
            AppLog.control("notch.hover source=viewport inside=\(hovering) frame=\(NSStringFromRect(panel.frame)) mode=\(self.presentation.mode) frameGeneration=\(self.frameIntentGeneration)")
            self.presentation.hoverChanged(hovering)
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in self?.reposition() }
        installWorkspaceObservers()
        motionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in self?.motionPreferencesDidChange() }
        // Event-driven: the presentation and the page model are the only inputs that move the frame.
        // A mode change is applied through the presentation's SYNCHRONOUS change hook, which runs
        // exactly once per real transition and strictly AFTER the new `mode` has been stored, so
        // `applyCurrentFrame` reads the shape the island is actually in. A Combine `@Published`
        // subscription runs in `willSet` instead, so reading the model from there would compute the
        // frame for the shape being left. One intent, one animation: `applyFrame` also ignores a
        // repeated application of the frame the newest transition already owns.
        presentation.onModeChange = { [weak self] mode, _ in
            guard let self else { return }
            // Every collapse path leaves secondary pages, including hover, toggle and sleep.
            // Reset after the mode changes so page cleanup cannot request an expanded frame.
            if mode == .collapsed { self.pageModel.reset() }
            self.applyCurrentFrame(animated: true)
        }
        pageObserver = pageModel.$page
            .removeDuplicates()
            .sink { [weak self] page in self?.pageDidChange(page) }
        // A proportion change resizes the ONE real panel through the same generation-safe animator,
        // never merely a visual scale. A scene change redraws the same layout with the new still.
        // The emitted value is used directly: `@Published` publishes during `willSet`, so the stored
        // property still holds the OLD profile while this sink runs.
        profileObserver = presentation.profileModel.$profile
            .removeDuplicates()
            .sink { [weak self] profile in self?.profileDidChange(profile) }

        applyFrame(rect, collapsed: true, animated: false, makeKey: false)
        panel.orderFrontRegardless()
    }

    /// Left-click / menu command: toggle collapsed ⇄ expanded. Opening is explicit, so the panel
    /// may become key (keyboard/menu access); an already hover-expanded island is promoted so its
    /// Esc/close access works. Hover never goes through here.
    func toggle() {
        install()
        presentation.toggle()
    }

    /// Show the island collapsed without changing any other surface. The page returns to the
    /// compact main island, so the next open is never a stale secondary page.
    func showCollapsed() {
        install()
        collapse()
    }

    func collapse() {
        presentation.collapse()
    }

    /// Explicit collapse from a control inside the page: same policy as Esc.
    func collapseFromControl() { collapse() }

    /// Show the island expanded on the queue page. Opening is explicit, so the panel may take
    /// keyboard access; selection/browsing never mutates the queue.
    func showQueuePage() {
        install()
        pageModel.select(.queue)
        presentation.setExpandedFromPage()
    }

    /// Show the island expanded on the background page. The shared chooser is presented by the
    /// owner wiring; the island only projects it and applies through the existing explicit command.
    func showBackgroundPage() {
        install()
        pageModel.select(.background)
        presentation.setExpandedFromPage()
    }

    /// Back to the compact main island from a secondary page without collapsing.
    func showMainPage() {
        install()
        pageModel.reset()
    }

    /// Orderly shutdown: cancel pending tasks/in-flight completions, invalidate the in-flight
    /// animation completion, remove the observers and close the panel cleanly.
    func shutdown() {
        presentation.shutdown()
        // Resetting the page routes through `pageDidChange`, which releases the shared chooser when
        // the background page was the last one presented.
        pageModel.reset()
        frameTransition.invalidate()
        pageObserver = nil
        profileObserver = nil
        if let motionObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(motionObserver)
            self.motionObserver = nil
        }
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        removeWorkspaceObservers()
        hosting?.onViewportHoverChange = nil
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        hosting = nil
        currentLayout = nil
    }

    // MARK: - Window placement

    /// Animate (or snap) the window to the geometry of the current mode/page/profile on the current
    /// display. Explicit expansions may take keyboard access; hover never does.
    private func applyCurrentFrame(animated: Bool) {
        guard let descriptor = Self.preferredScreen().map(Self.descriptor) else { return }
        let mode = presentation.mode
        let page = pageModel.page
        let profile = presentation.profileModel.profile
        applyFrame(NotchPanelGeometry.panelRect(for: mode, on: descriptor, page: page, profile: profile),
                   collapsed: mode == .collapsed,
                   animated: animated,
                   makeKey: mode == .expanded && presentation.lastExpansionWasExplicit)
    }

    /// A page change resizes the one panel for the secondary content (or back to the compact main
    /// island) and rebuilds the layout summary. Leaving the background page releases the shared
    /// chooser's preview, so no extraction can run behind a page that is no longer visible.
    private func pageDidChange(_ page: NotchIslandPage) {
        if page != .background && lastPresentedPage == .background { onLeaveBackgroundPage() }
        lastPresentedPage = page
        guard let hosting else { return }
        let descriptor = Self.preferredScreen().map(Self.descriptor) ?? NotchScreenDescriptor(frame: .zero)
        let profile = presentation.profileModel.profile
        let layout = NotchPanelGeometry.layout(on: descriptor, page: page, profile: profile)
        currentLayout = layout
        hosting.rootView = contentBuilder(presentation, pageModel, layout)
        guard presentation.isExpanded else { return }
        applyFrame(NotchPanelGeometry.panelRect(for: .expanded, on: descriptor, page: page,
                                                profile: profile),
                   collapsed: false,
                   animated: true,
                   makeKey: false)
    }

    /// A proportion change updates the ACTUAL window geometry through the same generation-safe
    /// animator. While collapsed there is nothing to resize (the hidden trigger is profile
    /// independent), so only the layout summary is refreshed. `profile` is the EMITTED value, because
    /// the model publishes during `willSet` and the stored property still holds the old one.
    private func profileDidChange(_ profile: NotchIslandProfile) {
        guard let hosting else { return }
        let descriptor = Self.preferredScreen().map(Self.descriptor) ?? NotchScreenDescriptor(frame: .zero)
        let page = pageModel.page
        let layout = NotchPanelGeometry.layout(on: descriptor, page: page, profile: profile)
        currentLayout = layout
        hosting.rootView = contentBuilder(presentation, pageModel, layout)
        guard presentation.isExpanded else { return }
        applyFrame(NotchPanelGeometry.panelRect(for: .expanded, on: descriptor, page: page,
                                                profile: profile),
                   collapsed: false,
                   animated: true,
                   makeKey: false)
    }

    /// Public preference notification; also callable with an injected provider in regression.
    func motionPreferencesDidChange() {
        presentation.sceneModel.refreshEnvironment()
        if reduceMotion { applyCurrentFrame(animated: false) }
    }

    /// Explicit keyboard access for an already-hover-expanded island: the frame does not change, but
    /// the panel must still accept Esc/close. Safe to call repeatedly (the geometry is unchanged),
    /// and it must NOT disturb an in-flight geometry transition.
    private func applyKeyboardAccess() {
        guard let panel, let descriptor = Self.preferredScreen().map(Self.descriptor) else { return }
        if !panel.isVisible && !isSuspendedForWorkspace { panel.orderFrontRegardless() }
        panel.makeKey()
        let rect = NotchPanelGeometry.panelRect(for: presentation.mode, on: descriptor,
                                                page: pageModel.page,
                                                profile: presentation.profileModel.profile)
        if let retarget = frameTransition.promoteToKeyboard(
            target: rect, collapsed: presentation.mode == .collapsed) {
            panel.setFrame(retarget, display: true, animate: false)
        }
    }

    /// Animate (or snap) the window to `rect`, then snap exactly once the finite transition has
    /// finished. Only the newest generation may finalize: an older, superseded animator completion
    /// is discarded, so a rapid reversal always settles on the newest exact frame and never leaves a
    /// permanently wide invisible surface behind.
    ///
    /// This is also the ONLY place that hides the surface after a close and reveals the sharp
    /// artwork after an open: both are tagged with the same generation token as the frame, so only
    /// the NEWEST completed frame may settle them. A reopen during the shrinking transition bumps
    /// the generation, the older completion is discarded, and the newest completion decides again.
    private func applyFrame(_ rect: NSRect, collapsed: Bool, animated: Bool, makeKey: Bool) {
        guard let panel else { return }
        // One intent, one animation. A repeated application of the frame the newest transition
        // already owns (e.g. a page notification arriving behind a mode change for the same rect)
        // must not restart the animation.
        guard !(animated && frameTransition.owns(target: rect, collapsed: collapsed)) else { return }
        let token = frameTransition.begin(target: rect, collapsed: collapsed)
        let hadHoverIntent = presentation.isPointerInside || presentation.hasPendingCollapse

        if !panel.isVisible && !isSuspendedForWorkspace { panel.orderFrontRegardless() }

        guard animated, !reduceMotion else {
            panel.setFrame(rect, display: true, animate: false)
            if makeKey { panel.makeKey() }
            // A non-animated transition settles in this very turn: there is no transition whose
            // completion could report it, so settle the artwork here.
            if collapsed { presentation.surfaceSettledImmediately() }
            else {
                presentation.expansionSettled()
                reconcilePointerAfterFrameChange(hadHoverIntent: hadHoverIntent)
            }
            return
        }
        if makeKey { panel.makeKey() }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = self.transitionDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(rect, display: true)
        } completionHandler: { [weak self, weak panel] in
            guard let self, let panel else { return }
            guard let final = self.frameTransition.completionFrame(token: token) else {
                self.frameTransition.noteStaleCompletion()
                return
            }
            panel.setFrame(final, display: true, animate: false)
            // Newest completed frame owns the artwork too: a stale completion never reaches here.
            if self.frameTransition.targetIsCollapsed {
                self.presentation.surfaceSettledCollapsed()
            } else {
                self.presentation.expansionSettled()
                self.reconcilePointerAfterFrameChange(hadHoverIntent: hadHoverIntent)
            }
        }
    }

    /// Resizing can move the viewport away from a stationary pointer or consume a boundary event
    /// during animation. Settle the existing hover intent against the final physical viewport,
    /// through the ordinary leave grace. An explicit menu/keyboard opening remains available until
    /// the pointer has visited it; a frame change alone must not start hover or undo explicit close.
    private func reconcilePointerAfterFrameChange(hadHoverIntent: Bool) {
        guard !isSuspendedForWorkspace, presentation.isExpanded, let hosting,
              hadHoverIntent || presentation.isPointerInside || presentation.hasPendingCollapse else { return }
        presentation.hoverChanged(hosting.pointerIsInsideViewport(pointerLocationProvider()))
    }

    /// Event-driven reposition after a screen change. Cancels every pending entry/collapse and
    /// invalidates any in-flight animation completion, then snaps immediately (no transition) and
    /// rebuilds the root view so the layout summary follows the display that now hosts the island;
    /// never polls and never touches the player.
    private func reposition() {
        guard let panel, let hosting else { return }
        let descriptor = Self.preferredScreen().map(Self.descriptor) ?? NotchScreenDescriptor(frame: .zero)
        let page = pageModel.page
        let profile = presentation.profileModel.profile
        let layout = NotchPanelGeometry.layout(on: descriptor, page: page, profile: profile)
        let mode = presentation.mode
        let rect = NotchPanelGeometry.panelRect(for: mode, on: descriptor, page: page, profile: profile)
        // Screen notifications can repeat while Desktop/Mission Control transitions run.
        // Unchanged geometry must leave the active animator and hover intent alone.
        guard layout != currentLayout
                || !frameTransition.owns(target: rect, collapsed: mode == .collapsed) else { return }
        let hadHoverIntent = presentation.isPointerInside || presentation.hasPendingCollapse
        presentation.cancelPendingWork()
        if layout != currentLayout {
            currentLayout = layout
            hosting.rootView = contentBuilder(presentation, pageModel, layout)
        }
        frameTransition.invalidate()
        frameTransition.begin(target: rect, collapsed: mode == .collapsed)
        panel.setFrame(rect, display: true, animate: false)
        if mode == .collapsed {
            presentation.surfaceSettledImmediately()
        } else {
            presentation.expansionSettled()
            reconcilePointerAfterFrameChange(hadHoverIntent: hadHoverIntent)
        }
    }

    // MARK: - Workspace session / sleep (public NSWorkspace events)

    /// Subscribe to the public workspace session/sleep notifications. No global hook, no private
    /// lock API and no Spaces reassert loop: the events only hide the panel, and only active/wake
    /// restores it, always COLLAPSED.
    private func installWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        let hide: [Notification.Name] = [NSWorkspace.sessionDidResignActiveNotification,
                                         NSWorkspace.willSleepNotification,
                                         NSWorkspace.screensDidSleepNotification]
        let restore: [Notification.Name] = [NSWorkspace.sessionDidBecomeActiveNotification,
                                            NSWorkspace.didWakeNotification,
                                            NSWorkspace.screensDidWakeNotification]
        for name in hide {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in self?.suspendForWorkspaceEvent()
            })
        }
        for name in restore {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in self?.resumeAfterWorkspaceEvent()
            })
        }
    }

    private func removeWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers { center.removeObserver(observer) }
        workspaceObservers.removeAll()
    }

    /// Session resigned / screen sleeping: cancel every pending hover task, collapse and order the
    /// panel out, so it can never linger above the login window or the lock UI.
    private func suspendForWorkspaceEvent() {
        guard let panel, !isSuspendedForWorkspace else { return }
        isSuspendedForWorkspace = true
        presentation.hoverChanged(false)
        presentation.collapse()
        let descriptor = Self.preferredScreen().map(Self.descriptor) ?? NotchScreenDescriptor(frame: .zero)
        let rect = NotchPanelGeometry.panelRect(for: .collapsed, on: descriptor)
        frameTransition.invalidate()
        frameTransition.begin(target: rect, collapsed: true)
        presentation.surfaceSettledImmediately()
        panel.setFrame(rect, display: true, animate: false)
        panel.orderOut(nil)
    }

    /// Session became active / woke: only ever restore the COLLAPSED invisible trigger.
    private func resumeAfterWorkspaceEvent() {
        guard isSuspendedForWorkspace, let panel else { return }
        isSuspendedForWorkspace = false
        presentation.sceneModel.refreshEnvironment()
        presentation.hoverChanged(false)
        let descriptor = Self.preferredScreen().map(Self.descriptor) ?? NotchScreenDescriptor(frame: .zero)
        let rect = NotchPanelGeometry.panelRect(for: .collapsed, on: descriptor)
        frameTransition.invalidate()
        frameTransition.begin(target: rect, collapsed: true)
        panel.setFrame(rect, display: true, animate: false)
        presentation.surfaceSettledImmediately()
        panel.orderFrontRegardless()
    }

    /// Built-in notched display when present, otherwise the main display, otherwise the first.
    static func preferredScreen() -> NSScreen? {
        let screens = NSScreen.screens
        if let notched = screens.first(where: { $0.safeAreaInsets.top > 0.5 }) { return notched }
        return NSScreen.main ?? screens.first
    }

    static func descriptor(_ screen: NSScreen) -> NotchScreenDescriptor {
        NotchScreenDescriptor(frame: screen.frame,
                              visibleFrame: screen.visibleFrame,
                              topInset: screen.safeAreaInsets.top,
                              auxiliaryTopLeft: screen.auxiliaryTopLeftArea,
                              auxiliaryTopRight: screen.auxiliaryTopRightArea)
    }

    /// Read at transition time; never observed with a timer.
    static var systemReduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}
