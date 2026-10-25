// BSideControlApp — StatusItemController: exactly one NSStatusItem for the whole app lifetime
// (created once, strongly retained, removed only by quit). Click → Control Center popover.
// The menu-bar symbol is driven by the SAME semantic health as the Control Center, so the two
// can never disagree (Beta Slice 2: supervision truth over stale runtime snapshots).

import AppKit
import SwiftUI
import BSideCore

final class StatusItemController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var contentFactory: (() -> NSViewController)?
    private var clickHandler: (() -> Void)?
    /// Candidate-only quick menu. Nil in the ordinary variant, which keeps the popover click.
    private var quickMenu: NSMenu?
    private var quickMenuActions: [StatusQuickAction: () -> Void] = [:]
    private var quickMenuItems: [StatusQuickAction: NSMenuItem] = [:]

    override init() {
        super.init()
        popover.behavior = .transient   // outside click + Esc close for free
        popover.animates = false        // Reduce Motion friendly; no decoration
    }

    func install(clickHandler: @escaping () -> Void) {
        self.clickHandler = clickHandler
        let button = statusItem.button
        let image = NSImage(systemSymbolName: "photo.on.rectangle.angled",
                            accessibilityDescription: "bsideyou")
        image?.isTemplate = true
        button?.image = image
        button?.target = self
        button?.action = #selector(statusItemClicked)
        // Deliver BOTH buttons to the action so a right/control click can show the fallback quick
        // menu while a left click runs the primary handler (the notch toggle in the candidate).
        button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    /// Candidate quick controls (ADR-021): the status item keeps this menu as the FALLBACK surface
    /// on a right click. The menu is deliberately NOT assigned to `statusItem.menu`: a left click
    /// must reach `clickHandler` (which toggles the notch panel), while a right/control click pops
    /// this same menu with the exact approved actions, each delegating to the same production
    /// command the full window uses.
    func installQuickMenu(_ actions: [StatusQuickAction: () -> Void]) {
        quickMenuActions = actions
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        let menu = NSMenu()
        menu.autoenablesItems = false
        quickMenuItems = [:]
        for action in StatusQuickAction.allCases {
            if action == .quit { menu.addItem(.separator()) }
            let item = NSMenuItem(title: action.title, action: #selector(quickMenuSelected(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = action.rawValue
            menu.addItem(item)
            quickMenuItems[action] = item
        }
        quickMenu = menu
    }

    /// True while a right/control click should show the fallback quick menu instead of running the
    /// primary (notch) toggle. Pure event inspection; never mutates state.
    static func isSecondaryClick(_ event: NSEvent?) -> Bool {
        guard let event else { return false }
        switch event.type {
        case .rightMouseDown, .rightMouseUp: return true
        case .leftMouseDown, .leftMouseUp: return event.modifierFlags.contains(.control)
        default: return false
        }
    }

    private func showQuickMenu() {
        guard let menu = quickMenu, let button = statusItem.button else { return }
        // The supported modern replacement for the deprecated popUpMenu: assign the menu for the
        // duration of one synthetic click, then clear it so the next left click toggles the notch.
        statusItem.menu = menu
        button.performClick(nil)
        statusItem.menu = nil
    }

    /// Refresh the quick menu's titles/enabled state from current truth. Never mutates state.
    func refreshQuickMenu(_ state: StatusQuickMenuState) {
        for (action, item) in quickMenuItems {
            item.title = state.title(for: action)
            item.isEnabled = state.isEnabled(action)
        }
    }

    @objc private func quickMenuSelected(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let action = StatusQuickAction(rawValue: raw) else { return }
        quickMenuActions[action]?()
    }

    @objc private func statusItemClicked() {
        // Left click runs the primary handler (the notch toggle in the candidate). A right click
        // keeps the established full quick menu as the fallback surface.
        if Self.isSecondaryClick(NSApp.currentEvent) {
            showQuickMenu()
            return
        }
        clickHandler?()
    }

    /// Toggle the Control Center popover anchored to the status item.
    func togglePopover(contentFactory: @escaping () -> NSViewController) {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        presentPopover(contentFactory: contentFactory)
    }

    /// Show (never close) the Control Center popover. Startup presentation is idempotent: an
    /// already-visible popover is left exactly as it is, and the factory is not re-run.
    func presentPopover(contentFactory: @escaping () -> NSViewController) {
        guard !popover.isShown else { return }
        self.contentFactory = contentFactory
        let controller = contentFactory()
        popover.contentViewController = controller
        // Position using the actual SwiftUI content size, before AppKit chooses its anchor.
        // Letting the hosting view grow after show can push the top beyond the screen.
        controller.view.layoutSubtreeIfNeeded()
        popover.contentSize = controller.view.fittingSize
        guard let button = statusItem.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // This is a user-requested control surface; keyboard input belongs here, not to
        // whichever Settings/onboarding window was key when the command was invoked.
        controller.view.window?.makeKey()
    }

    /// True while the Control Center is already on screen (startup idempotence check).
    var isControlCenterShown: Bool { popover.isShown }

    /// Read by the existing window lifecycle seam; a show call alone is not evidence that
    /// controls are visible, reachable on the screen, or receiving keyboard input.
    func presentationState() -> (shown: Bool, key: Bool, fitsScreen: Bool) {
        guard let window = popover.contentViewController?.view.window else { return (false, false, false) }
        let fits = window.screen.map { $0.frame.contains(window.frame) } ?? false
        return (popover.isShown && window.isVisible, window.isKeyWindow, fits)
    }

    func closePopover() {
        if popover.isShown { popover.performClose(nil) }
    }

    /// True only when the status item has a real, ON-SCREEN anchor window to attach a popover to.
    /// A window reference alone is not readiness: during a cold launch the status item window can
    /// exist before it is actually on screen, and a popover shown against it is not visible. The
    /// Journey-E regression seam checks this before showing the popover, so a run without an
    /// available status bar (e.g. headless session) can never crash on a nil anchor.
    func canShowPopover() -> Bool {
        guard let window = statusItem.button?.window else { return false }
        return window.isVisible
    }

    /// Lightweight state hints (template symbols, no animation, no per-second refresh).
    /// `health` is the exact semantic state the Control Center shows; `accessibilityText` is the
    /// same short user-language status string, so VoiceOver + menu-bar icon + popover agree.
    func refresh(health: HealthProjection.Health, accessibilityText: String) {
        let symbolName: String
        switch health {
        case .resourceUnavailable, .serviceProblem:
            symbolName = "exclamationmark.triangle"
        case .paused:
            symbolName = "pause.circle"
        case .recovering:
            symbolName = "arrow.clockwise"
        case .preparing, .normal:
            symbolName = "photo.on.rectangle.angled"
        }
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "bsideyou")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.setAccessibilityLabel("bsideyou — \(accessibilityText)")
    }
}
