// BSideControlApp — bsideyou shelf: presentation ownership seam.
//
// One small state machine owns WHEN the shelf is collapsed or expanded, independent of AppKit and
// SwiftUI, so the hover/leave policy can be tested deterministically:
//   * hover in schedules ONE very short entry delay (~0.01s) before expanding, so crossing the
//     invisible hardware-sized trigger on the way somewhere else never opens the shelf while an
//     intentional hover still feels immediate; hover out cancels it immediately;
//   * hover out after an expansion schedules ONE short delayed collapse (~0.10s leave grace) so the
//     pointer can travel from the hidden trigger into the body;
//   * a click on the trigger, the menu-bar icon or the application menu opens immediately and may
//     take keyboard access. On an already hover-expanded shelf the first explicit click only
//     promotes it to explicit (so Esc/close works); a further explicit click collapses it;
//   * there is NO pin and NO persistent-open behavior in this prototype: once the pointer leaves,
//     the shelf collapses, even after a control click. An explicit menu/AX show may open it for
//     access, but it never latches on leave;
//   * Esc / the collapse control explicitly collapse. While the pointer is still inside, hover
//     reopen stays suppressed until a REAL pointer leave, so a synthetic hover-in delivered while
//     the window is still shrinking cannot bounce the shelf straight back open — and that
//     suppression is cleared by the real leave, never latched past it;
//   * rapid transitions coalesce to the LATEST intent: every state change invalidates the
//     generation of any in-flight delayed entry/collapse, so a stale completion can never open,
//     collapse or resize a shelf the owner has since moved away from;
//   * shutdown or an event-driven screen change cancels every pending task, bumps the generation
//     and freezes the shelf collapsed.
//
// It owns no model, no queue, no player and no persisted field: it only answers "which shape is
// the shelf right now". The AppKit controller is driven by the synchronous `onModeChange` hook
// (which runs after `mode` has been stored) and by the published `page`, and it reads the CURRENT
// model values when it applies a frame — never a `willSet` emission — so a transition always
// animates to the shape the island is really in. The SwiftUI content observes the published
// `mode`, `surfaceIsVisible` and `sharpArtworkIsVisible` only.

import Foundation
import Combine

/// Which of the island's own pages is showing. Presentation-only transient state: it is never
/// persisted, never sent over IPC and never a second window. The AppKit controller observes it to
/// resize the one panel for the secondary content and animates back to the compact main page.
final class NotchIslandPageModel: ObservableObject {
    @Published private(set) var page: NotchIslandPage = .main

    /// Show one page. Idempotent: an unchanged selection is a no-op, so a repeated tap cannot start
    /// a second, competing frame transition.
    func select(_ page: NotchIslandPage) {
        guard self.page != page else { return }
        self.page = page
    }

    /// Return to the compact main page. Called whenever the island collapses, so the next open is
    /// always the compact music island and never a stale secondary page.
    func reset() { select(.main) }
}

final class NotchPanelPresentation: ObservableObject {
    /// Current shape. Published so the hosted SwiftUI content re-renders on change.
    @Published private(set) var mode: NotchPanelMode = .collapsed
    /// True while the pointer is inside the shelf.
    @Published private(set) var isPointerInside = false
    /// True while the island surface must be DRAWN. It turns on with an expansion and stays on for
    /// the WHOLE closing transition — a shrinking invisible window would have no visible closing
    /// motion — and is turned off only by the controller once the newest COLLAPSED frame has really
    /// settled. A reopen during the transition turns it back on and invalidates that pending hide,
    /// so a stale settle can never blank a reopened island. `mode` remains the authoritative shape.
    @Published private(set) var surfaceIsVisible = false
    /// True while the SHARP character artwork may be drawn. It is deliberately stricter than
    /// `surfaceIsVisible`: the sharp layer is deferred until the expansion frame has really settled,
    /// so the earliest opening can never cut through the face; it then stays on for the WHOLE
    /// closing transition so the artwork retracts with the shrinking silhouette.
    @Published private(set) var sharpArtworkIsVisible = false
    /// True after an explicit close that happened while the pointer was still inside. The critical
    /// section between the close and the window actually reaching its collapsed frame can deliver a
    /// synthetic hover-in even though the pointer never moved, so hover reopen stays suppressed
    /// until a REAL pointer leave clears it — it is never latched past that leave (see
    /// `hoverChanged`).
    private(set) var suppressesHoverReopen = false
    /// Transient lateral proportion model. Owned here so the hosted view and the AppKit controller
    /// share one instance without any extra wiring.
    let profileModel = NotchIslandProfileModel()
    /// Transient illustrative-scene model. Presentation only: no gallery mutation, no apply.
    let sceneModel = NotchSceneChoiceModel()
    /// One-shot delayed entry after the pointer arrives. Short enough to feel immediate, long enough
    /// that a plain flyover does not open the shelf.
    var autoEntryDelay: TimeInterval = NotchPanelGeometry.hoverEntryDelay
    /// One-shot delayed collapse after the pointer leaves: the leave grace.
    var autoCollapseDelay: TimeInterval = NotchPanelGeometry.hoverCollapseDelay
    /// Called synchronously whenever `mode` really changes, with a monotonically increasing
    /// generation. The controller animates to the new geometry; tests observe transitions.
    /// Never called on a no-op transition, so an already-expanded shelf is never re-animated.
    var onModeChange: ((NotchPanelMode, Int) -> Void)?
    /// Called when an EXPLICIT click/menu open must hand the panel keyboard access, including when
    /// the shelf was already hover-expanded (a no-op mode transition). Hover never calls this.
    var onExplicitKeyEligible: (() -> Void)?

    /// Diagnostics for the regression seam.
    private(set) var scheduledEntryCount = 0
    private(set) var cancelledEntryCount = 0
    private(set) var scheduledCollapseCount = 0
    private(set) var cancelledCollapseCount = 0
    private(set) var staleCompletionCount = 0
    private(set) var staleEntryCompletionCount = 0
    private(set) var isShutDown = false
    /// Increments on every real shape change. A completion tagged with an older generation is stale.
    private(set) var transitionGeneration = 0
    /// True when the current expansion came from an explicit click/menu rather than hover, so the
    /// controller may make the panel key (hover must never steal focus).
    private(set) var lastExpansionWasExplicit = false

    private var pendingCollapse: DispatchWorkItem?
    private var pendingEntry: DispatchWorkItem?
    private var intentGeneration = 0

    var isExpanded: Bool { mode == .expanded }
    var hasPendingCollapse: Bool { pendingCollapse != nil }
    var hasPendingEntry: Bool { pendingEntry != nil }
    /// The generation a delayed entry/collapse scheduled right now would carry. Exposed for the
    /// regression seam so latest-intent ownership is testable without relying on GCD timing.
    var currentIntent: Int { intentGeneration }

    /// Latest-intent ownership predicate. A delayed collapse may only resize the shelf when the
    /// pointer really is OUTSIDE and the intent it was scheduled under is still the newest one: any
    /// later hover/click/collapse or shutdown bumps the generation, so its completion is stale and
    /// must be discarded.
    func collapseCompletionIsCurrent(generation: Int) -> Bool {
        !isShutDown && !isPointerInside && intentGeneration == generation
    }

    /// Latest-intent ownership predicate for the entry delay: the entry may only open the shelf when
    /// the pointer is still inside and no later intent superseded the one that scheduled it.
    func entryCompletionIsCurrent(generation: Int) -> Bool {
        !isShutDown && isPointerInside && intentGeneration == generation
    }

    /// Pointer entered (true) or left (false) the shelf. Entry is delayed by the short flyover
    /// debounce and never explicit (so it never steals focus); exit cancels a pending entry
    /// immediately and otherwise schedules the one short leave grace. Re-entry also cancels and
    /// invalidates any pending collapse even while the shelf is already expanded.
    func hoverChanged(_ hovering: Bool) {
        guard !isShutDown else { return }
        guard hovering else {
            if isPointerInside { isPointerInside = false }
            // A real leave is the ONLY thing that clears an explicit-close suppression, so the
            // suppression never latches past the leave: the next genuine entry may open again.
            suppressesHoverReopen = false
            invalidatePendingEntry()
            scheduleCollapse()
            return
        }
        // Synthetic re-entry while an explicitly closed shelf is still shrinking: the pointer never
        // really left, so this must not schedule an entry or reopen anything.
        guard !suppressesHoverReopen else { return }
        if !isPointerInside { isPointerInside = true }
        guard mode == .collapsed else {
            // Already expanded: cancel and invalidate any pending collapse (the pointer is back) but
            // schedule no entry, because there is nothing left to open.
            bumpIntent()
            invalidatePendingEntry()
            invalidatePendingCollapse()
            return
        }
        scheduleEntry()
    }

    /// Click on the trigger, the menu-bar icon or the application menu command. A collapsed shelf
    /// opens immediately and explicitly, so the controller may make the panel key. An ALREADY
    /// hover-expanded shelf is only promoted to explicit (keyboard/Esc access) on the first explicit
    /// click, because the mode cannot change; a further explicit click then collapses it.
    func toggle() {
        guard !isShutDown else { return }
        guard mode == .expanded else {
            expand(explicit: true)
            return
        }
        if lastExpansionWasExplicit {
            collapse()
        } else {
            expand(explicit: true)
        }
    }

    /// Explicit navigation to one of the island's own secondary pages. Presentation only: it opens
    /// the one panel explicitly (so Esc/close keyboard access is granted) and never touches the
    /// library, the queue, the session or any persisted field.
    func setExpandedFromPage() { expand(explicit: true) }

    /// Explicit collapse (Esc, collapse control, navigation to another surface, or an owner
    /// decision). Cancels every pending entry/collapse. When the pointer is still inside, hover
    /// reopen stays suppressed until a real leave, so the shrinking window's synthetic hover-in
    /// cannot bounce the shelf straight back open. There is no pin to release: the prototype never
    /// holds itself open.
    func collapse() {
        bumpIntent()
        invalidatePendingEntry()
        invalidatePendingCollapse()
        suppressesHoverReopen = isPointerInside
        setMode(.collapsed, explicit: false)
    }

    /// Orderly shutdown: cancel every delayed task, invalidate every in-flight completion and never
    /// expand again. Safe to call twice.
    func shutdown() {
        bumpIntent()
        isShutDown = true
        sceneModel.shutdown()
        invalidatePendingEntry()
        invalidatePendingCollapse()
        suppressesHoverReopen = false
        sharpArtworkIsVisible = false
        setMode(.collapsed, explicit: false)
    }

    /// Event-driven cancellation for a screen change: nothing scheduled against the previous
    /// geometry may still fire against the new one. Bumps the intent generation first, so a
    /// completion already queued on the main queue is stale even if its work item could not be
    /// cancelled.
    func cancelPendingWork() {
        guard !isShutDown else { return }
        bumpIntent()
        invalidatePendingEntry()
        invalidatePendingCollapse()
    }

    // MARK: - Internals

    private func expand(explicit: Bool) {
        guard !isShutDown else { return }
        // Bump first: reopening supersedes any scheduled collapse even when the mode is already
        // expanded, so a completion tagged with the old generation is stale from now on.
        bumpIntent()
        invalidatePendingEntry()
        invalidatePendingCollapse()
        guard mode != .expanded else {
            // Already hover-expanded: there is no geometry transition to run, but an explicit open
            // must still hand keyboard access (Esc/close) to the shelf.
            if explicit { promoteToExplicitExpansion() }
            return
        }
        // An explicit open (click/menu) is immediate and also cancels any explicit-close
        // suppression, so the owner can always reopen a shelf they closed deliberately.
        if explicit { suppressesHoverReopen = false }
        setMode(.expanded, explicit: explicit)
    }

    /// Record that the CURRENT expansion is explicit and let the controller take keyboard access.
    /// Only the AppKit seam consumes this; the SwiftUI content reads `mode`/`isExpanded` only.
    private func promoteToExplicitExpansion() {
        lastExpansionWasExplicit = true
        onExplicitKeyEligible?()
    }

    private func scheduleEntry() {
        guard !isShutDown, mode == .collapsed, pendingEntry == nil else { return }
        // Repeated same-state tracking notifications must retain the first entry deadline.
        bumpIntent()
        invalidatePendingEntry()
        invalidatePendingCollapse()
        scheduledEntryCount += 1
        let token = intentGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Latest-intent ownership: a leave, click, collapse, screen change or shutdown that
            // happens during the delay bumps `intentGeneration`, so this completion is stale and
            // must not open the shelf the owner has since moved away from.
            guard self.entryCompletionIsCurrent(generation: token) else {
                self.staleEntryCompletionCount += 1
                return
            }
            self.pendingEntry = nil
            self.expand(explicit: false)
        }
        pendingEntry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + autoEntryDelay, execute: work)
    }

    private func scheduleCollapse() {
        guard !isShutDown else { return }
        // Nothing to collapse: a pointer leaving an already-collapsed shelf (or during the entry
        // delay) must not leave a no-op task behind. Mirrors `scheduleEntry`'s collapsed guard.
        guard mode == .expanded, pendingCollapse == nil else { return }
        // Repeated outside notifications must retain the first leave-grace deadline.
        bumpIntent()
        invalidatePendingCollapse()
        scheduledCollapseCount += 1
        let token = intentGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Latest-intent ownership: any later owner action bumps `intentGeneration`, so this
            // completion is stale and must not resize or close the shelf the owner has reopened.
            guard self.collapseCompletionIsCurrent(generation: token) else {
                self.staleCompletionCount += 1
                return
            }
            self.pendingCollapse = nil
            self.setMode(.collapsed, explicit: false)
        }
        pendingCollapse = work
        DispatchQueue.main.asyncAfter(deadline: .now() + autoCollapseDelay, execute: work)
    }

    /// Every owner intent supersedes any scheduled entry/collapse.
    private func bumpIntent() { intentGeneration &+= 1 }

    /// Cancel a scheduled collapse. Returns true when one was actually pending.
    @discardableResult
    private func invalidatePendingCollapse() -> Bool {
        guard let work = pendingCollapse else { return false }
        work.cancel()
        pendingCollapse = nil
        cancelledCollapseCount += 1
        return true
    }

    /// Cancel a scheduled entry. Returns true when one was actually pending.
    @discardableResult
    private func invalidatePendingEntry() -> Bool {
        guard let work = pendingEntry else { return false }
        work.cancel()
        pendingEntry = nil
        cancelledEntryCount += 1
        return true
    }

    private func setMode(_ next: NotchPanelMode, explicit: Bool) {
        guard mode != next else { return }
        mode = next
        sceneModel.setVisible(next == .expanded)
        if next == .expanded { lastExpansionWasExplicit = explicit }
        // The DRAWABLE surface follows the shape with the closing delay built in: expanding shows it
        // immediately (the island grows out of the hidden trigger), collapsing KEEPS it until the
        // controller reports the collapsed frame settled. This is the ONLY writer of the flag, so a
        // direct `mode` assignment (the regression seam) can never leave an expanded island blank.
        if next == .expanded { surfaceIsVisible = true }
        transitionGeneration &+= 1
        onModeChange?(next, transitionGeneration)
    }

    /// The controller settled the newest EXPANDED frame: the silhouette is fully revealed, so the
    /// sharp character layer may finally be drawn. Ignored while collapsed or shut down, which is
    /// what makes a stale expand completion harmless after a rapid reversal.
    func expansionSettled() {
        guard !isShutDown, mode == .expanded else { return }
        sharpArtworkIsVisible = true
    }

    /// The controller settled the newest COLLAPSED frame: nothing is drawn at rest, so the sharp
    /// artwork stops being drawn too. Ignored while expanded or shut down, which is what makes a
    /// stale settle harmless after a rapid reopen.
    func surfaceSettledCollapsed() {
        guard !isShutDown, mode == .collapsed else { return }
        sharpArtworkIsVisible = false
        guard surfaceIsVisible else { return }
        surfaceIsVisible = false
    }

    /// Fallback settle for a collapse that produced no animation (Reduce Motion, a non-animated
    /// snap, a screen change or shutdown): those paths settle in the same turn, so there is no
    /// transition for the controller to observe.
    func surfaceSettledImmediately() {
        guard mode == .collapsed else { return }
        sharpArtworkIsVisible = false
        guard surfaceIsVisible else { return }
        surfaceIsVisible = false
    }
}
