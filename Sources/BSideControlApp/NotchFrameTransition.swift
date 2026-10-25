// BSideControlApp — bsideyou island: finite window-frame transition state machine.
//
// The window frame is the ONE animated surface of the island. This tiny pure state machine owns
// WHICH frame is the newest intent and whether a completion from an `NSAnimationContext` may still
// finalize it, so the "repeated reversal / stale completion / exact final bounds" rules are
// testable without a window server, an animation clock or a screen.
//
//   * every new intent (expand, collapse, page change, keyboard promotion, screen change) bumps the
//     generation and records the exact target rectangle;
//   * a completion tagged with an OLDER generation is stale and must be discarded: a rapid reversal
//     can therefore never resize or close the newest transition;
//   * the newest completion snaps the EXACT target rectangle, so a finite animation always settles
//     on the exact geometry (including the exact collapsed bounds) and never leaves a permanently
//     wide invisible surface;
//   * the machine carries no AppKit type: the controller converts `CGRect` values only.

import Foundation
import CoreGraphics

/// One finite frame transition of the one island window.
struct NotchFrameTransition {
    /// The frame the newest intent wants.
    private(set) var target: CGRect = .zero
    /// True when the newest intent is the collapsed geometry.
    private(set) var targetIsCollapsed = true
    /// Monotonic generation of the newest intent.
    private(set) var generation = 0
    /// How many completions were discarded because a newer intent had superseded them.
    private(set) var staleCompletionCount = 0

    /// Record a new intent. Returns the token a completion of THIS transition must carry.
    @discardableResult
    mutating func begin(target: CGRect, collapsed: Bool) -> Int {
        self.target = target
        targetIsCollapsed = collapsed
        generation &+= 1
        return generation
    }

    /// Invalidate every in-flight transition (screen change, shutdown) without starting an
    /// animation: any queued completion becomes stale and the newest target stays authoritative.
    mutating func invalidate() { generation &+= 1 }

    /// True when the newest recorded intent is already exactly this frame. Used to make a repeated
    /// application inert, so a duplicated notification cannot restart (and thereby retarget) an
    /// animation that is already in flight.
    func owns(target: CGRect, collapsed: Bool) -> Bool {
        self.target == target && targetIsCollapsed == collapsed
    }

    /// Record an explicit keyboard-access promotion, which by itself changes NO geometry.
    ///
    /// The common case is promoting an already hover-expanded island while its expansion animation
    /// is still in flight: the newest intent already wants exactly this frame, so the transition
    /// (and its generation) is left completely untouched — the in-flight animation keeps running
    /// and its own completion still settles the exact final bounds. Returns nil in that case; the
    /// caller must not install any frame.
    ///
    /// Only when the intended frame really differs from the newest recorded intent (a page change,
    /// a reversal or a screen change around the promotion) is the promotion a genuine new intent:
    /// it is recorded as the newest generation and its exact frame is returned for immediate
    /// installation, so the promotion still owns the final geometry.
    mutating func promoteToKeyboard(target: CGRect, collapsed: Bool) -> CGRect? {
        guard !owns(target: target, collapsed: collapsed) else { return nil }
        _ = begin(target: target, collapsed: collapsed)
        return target
    }

    /// True when a completion tagged `token` may finalize the window frame.
    func completionIsCurrent(token: Int) -> Bool { token == generation }

    /// The exact frame a valid completion (or an immediate snap) must install.
    func completionFrame(token: Int) -> CGRect? {
        completionIsCurrent(token: token) ? target : nil
    }

    /// Record a discarded stale completion (diagnostics only).
    mutating func noteStaleCompletion() { staleCompletionCount += 1 }
}

/// The order the one island window must be configured in, and the level/collection behavior that
/// keeps it reachable over native fullscreen. Pure so the AppKit controller cannot silently drift:
/// the panel is made a FLOATING panel BEFORE its final window level is applied (`isFloatingPanel`'s
/// setter resets `level`, so the reverse order leaves a level-3 panel), its frame is never passed
/// through AppKit's visible-frame constraint, and only public levels/behaviors are used (no private
/// Spaces API, no hotkey/permission hook, no display timer).
///
/// Level/collection flags are public AppKit only. The review-only experimental coverage level
/// follows the Apple DTS guidance for other applications' fullscreen video (thread 826308); the
/// prototype does NOT claim universal fullscreen coverage, and Codex tests the actual desktop and a
/// controlled other-app fullscreen case. `canBecomeVisibleWithoutLogin` is kept false and the
/// controller orders the panel out on session resign/screen sleep, so it is never shown above the
/// system login window or lock UI.
enum NotchPanelConfiguration {
    /// Step 1: `NSPanel.isFloatingPanel = true` BEFORE assigning `level`.
    static let makesFloatingPanelBeforeLevel = true
    /// Ordinary product level: the public status-bar level. Kept in the seam for regression even
    /// though the review prototype uses the experimental fullscreen-video level below.
    static let ordinaryStatusBarLevel: Int = 25 // NSWindow.Level.statusBar.rawValue
    /// The public screen-saver level. Apple DTS suggests it for covering other applications'
    /// fullscreen video; this is review-only EXPERIMENTAL coverage.
    static let experimentalFullScreenVideoLevel: Int = 1000 // NSWindow.Level.screenSaver.rawValue
    /// True while the review prototype uses the experimental level. Flip to `false` to return the
    /// ordinary status-bar level without touching any other behavior.
    static let usesExperimentalFullScreenVideoLevel = true
    /// Step 2: the level applied strictly AFTER the floating flag.
    static var windowLevel: Int {
        usesExperimentalFullScreenVideoLevel ? experimentalFullScreenVideoLevel : ordinaryStatusBarLevel
    }
    /// Step 3: join every Space, including native fullscreen, without moving this or any other
    /// window and without a private Spaces API. `canJoinAllApplications` (macOS 13+, public) lets
    /// the floating panel join other applications' sets as well.
    static let joinsAllSpaces = true
    static let joinsAllApplications = true
    static let isFullScreenAuxiliary = true
    static let isStationary = true
    static let hidesOnDeactivate = false
    /// Never shown above the system login window / lock UI (public NSWindow property).
    static let canBecomeVisibleWithoutLogin = false
    /// The panel overrides `constrainFrameRect` to return the proposed rect unchanged: the closed
    /// island's whole point is to sit EXACTLY in the hardware cutout at the physical screen top, and
    /// AppKit's default constraint would push it below `visibleFrame`.
    static let overridesFrameConstraint = true
    /// Keyboard access (Esc/close) is granted only for an explicit click/menu expansion.
    static let becomesKeyOnlyIfNeeded = true
    /// The main application is never activated and no main window is opened for routine adjustment.
    static let activatesApplication = false
}
