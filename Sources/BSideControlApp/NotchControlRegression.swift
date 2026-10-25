// BSideControlApp — bsideyou island regression.
//
// Drives the same shared models/closures the island forwards to, plus the pure seams, with no
// window, screen, Agent or player. It reuses `HomepageMusicCardState` / `PerformanceBrowserModel` /
// `DailyBackgroundChooserModel` instead of restating their formulas, and asserts that presentation
// never mutates queue, session, volume or selected-version truth on its own.
//
// Coverage owned here (no window server, no app launch):
//   * real notch occupancy: the compact software cover around the public hardware cutout reaching
//     the physical screen top, no-notch menu-bar exclusion, short-top / unknown-cutout /
//     narrow-panel fallbacks, small screens, camera-band exclusion for the placed body, screen
//     clamping and negative-origin placement;
//   * the CLOSED surface policy: a single solid-black cover on a notched display, a fully
//     transparent grab fallback without hardware, hit region exactly the visible shape, and the
//     hardware band kept distinct from the 6pt software skirt;
//   * the compact 400pt main island size, the per-page sizes and their caps;
//   * the finite frame-transition seam: newest-intent ownership, stale-completion rejection,
//     repeated open/close/reversal settling on the exact bounds, and invalidation;
//   * the public fullscreen panel configuration (floating BEFORE level, all-Spaces +
//     fullScreenAuxiliary, never activating the application);
//   * the short 0.02s hover entry delay and its cancellation (flyover, rapid leave/reenter, screen
//     change, shutdown), including stale-completion rejection;
//   * explicit Esc while the pointer is INSIDE, real-leave/re-enter suppression of synthetic
//     re-entry, and promotion of an already hover-expanded island to explicit keyboard access;
//   * explicit pin and unpin/hover/collapse semantics, including unpinning while outside;
//   * music volume routed through the existing `ControlCenterModel.setMusicVolume`;
//   * queue browsing through the read-only projection: no recapture, reorder or start, while an
//     explicit per-entry play uses the existing owner path;
//   * the background page reusing the shared chooser: browsing applies nothing, applying stays
//     explicit, and leaving the page cancels the preview;
//   * the song title's presentation-only fullscreen re-entry: offered only for a live watch
//     session, forwarded through the same guarded owner action, and never mutating selection,
//     queue, copy or pause state.

import Foundation
import CoreGraphics
import Combine
import AppKit
import SwiftUI
import BSideCore
import BSidePlatform

func runNotchControlRegression(expect: (Bool, String) -> Void) {
    runNotchGeometryRegression(expect: expect)
    runNotchClosedSurfaceRegression(expect: expect)
    runNotchShapeRegression(expect: expect)
    runNotchProfileAndSceneModelRegression(expect: expect)
    runNotchSceneCropRegression(expect: expect)
    runNotchSceneImageStoreRegression(expect: expect)
    runNotchSceneArtworkRegression(expect: expect)
    runNotchSceneClockRegression(expect: expect)
    runNotchFrameTransitionRegression(expect: expect)
    runNotchPanelConfigurationRegression(expect: expect)
    runNotchHostingGeometryRegression(expect: expect)
    runNotchControllerRuntimeRegression(expect: expect)
    runNotchKeyboardPromotionRegression(expect: expect)
    runNotchFrameHoverRegression(expect: expect)
    runNotchPresentationRegression(expect: expect)
    runNotchHoverDeadlineRegression(expect: expect)
    runNotchViewportHoverRegression(expect: expect)
    runNotchMenuFallbackRegression(expect: expect)
    runNotchMusicVolumeRegression(expect: expect)
    runNotchCompactSummaryRegression(expect: expect)
    runNotchQueueBrowseRegression(expect: expect)
    runNotchBackgroundPageRegression(expect: expect)
    runNotchTitleFullScreenReentryRegression(expect: expect)
    runNotchModelActionRegression(expect: expect)
    runNotchNavigationCollapseRegression(expect: expect)
}

// MARK: - Menu icon fallback

/// Left click must reach the primary handler (the island toggle); a right/control click must reach
/// the fallback quick menu instead. Pure event classification: no status item or menu is created.
private func runNotchMenuFallbackRegression(expect: (Bool, String) -> Void) {
    func mouse(_ type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags = []) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: modifiers,
                           timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
                           clickCount: 1, pressure: 0)
    }
    expect(StatusItemController.isSecondaryClick(nil) == false,
           "a missing event must fall through to the primary handler")
    expect(StatusItemController.isSecondaryClick(mouse(.leftMouseUp)) == false,
           "a plain left click must run the primary handler (island toggle)")
    expect(StatusItemController.isSecondaryClick(mouse(.rightMouseUp)) == true
           && StatusItemController.isSecondaryClick(mouse(.rightMouseDown)) == true,
           "a right click must show the fallback quick menu")
    expect(StatusItemController.isSecondaryClick(mouse(.leftMouseUp, modifiers: [.control])) == true,
           "a control-click must show the fallback quick menu")
}

// MARK: - Geometry

/// Placement must match the real hardware occupancy with a cutout, stay clear of the system menu
/// bar without one, keep every readable control and the sharp character region BELOW the camera
/// band, clamp and cap on small or narrow displays, and stay correct on negative-origin and stacked
/// displays. The invisible hit window extends below the camera; original surface and expanded
/// artwork geometry remain independent, without a visible cover, wing or skirt.
private func runNotchGeometryRegression(expect: (Bool, String) -> Void) {
    let notched = NotchScreenDescriptor(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
        topInset: 32,
        auxiliaryTopLeft: CGRect(x: 0, y: 950, width: 676, height: 32),
        auxiliaryTopRight: CGRect(x: 836, y: 950, width: 676, height: 32))
    expect(NotchPanelGeometry.hasNotch(notched),
           "a positive public top safe-area inset must mean a camera cutout")
    expect(NotchPanelGeometry.hardwareBandHeight(notched) == 32,
           "the hardware band height must be the public NSScreen safe-area top inset")
    expect(NotchPanelGeometry.cutoutWidth(notched) == 160,
           "the cutout width must come from the two public auxiliary top areas, never guessed")
    expect(NotchPanelGeometry.cameraWidth(notched) == 160,
           "the derived camera width must be the public cutout when the areas are available")
    expect(NotchPanelGeometry.topEdge(notched) == 982,
           "with a cutout the island top edge is the physical top of the display")

    // The transparent hit window ends exactly at the hardware cutout boundary.
    let collapsed = NotchPanelGeometry.panelRect(for: .collapsed, on: notched)
    expect(collapsed.size == CGSize(width: 160, height: 32),
           "the hit window is exactly the 160x32 hardware cutout")
    expect(collapsed.maxY == notched.frame.maxY,
           "the collapsed trigger must reach the physical top of the display (frame.maxY)")
    expect(collapsed.minY == notched.frame.maxY - 32,
           "the target ends at the hardware band without an activation apron")
    expect(abs(collapsed.midX - notched.frame.midX) < 0.5,
           "the collapsed window must be horizontally centered on the display")
    expect(NotchIslandSurface.closedSilhouetteOpacity(on: notched) == 0
           && NotchIslandSurface.isTransparentWhenClosed(on: notched),
           "the collapsed window must be COMPLETELY transparent on notched hardware")
    expect(collapsed.height < NotchPanelGeometry.totalHeight(notched),
           "the collapsed trigger must stay far smaller than the expanded panel")

    // Current hardware: a 185pt-wide cutout on a 32pt band gives an exact 185x32 invisible trigger.
    let hardware185 = NotchScreenDescriptor(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
        topInset: 32,
        auxiliaryTopLeft: CGRect(x: 0, y: 950, width: 663.5, height: 32),
        auxiliaryTopRight: CGRect(x: 848.5, y: 950, width: 663.5, height: 32))
    expect(NotchPanelGeometry.cutoutWidth(hardware185) == 185,
           "the public auxiliary areas must describe the current 185pt hardware cutout")
    expect(NotchPanelGeometry.collapsedSize(hardware185) == CGSize(width: 185, height: 32),
           "the current 185x32 hardware must derive an exact 185x32 collapsed trigger")
    expect(NotchPanelGeometry.hardwareBandHeight(hardware185) == 32
           && NotchPanelGeometry.collapsedSize(hardware185).height == 32,
           "the collapsed trigger must not add a software skirt to the hardware band")
    let trigger185 = NotchPanelGeometry.panelRect(for: .collapsed, on: hardware185)
    expect(trigger185.width == 185 && trigger185.height == 32
           && trigger185.maxY == hardware185.frame.maxY
           && abs(trigger185.midX - hardware185.frame.midX) <= 0.5,
           "the 185x32 target preserves the exact hardware rectangle and top-center anchor")

    // A cutout wider than a small screen is clamped to the owning screen.
    let tightNotched = NotchScreenDescriptor(
        frame: CGRect(x: 0, y: 0, width: 200, height: 400),
        visibleFrame: CGRect(x: 0, y: 0, width: 200, height: 375),
        topInset: 30,
        auxiliaryTopLeft: CGRect(x: 0, y: 370, width: 5, height: 30),
        auxiliaryTopRight: CGRect(x: 195, y: 370, width: 5, height: 30))
    expect(NotchPanelGeometry.collapsedSize(tightNotched) == CGSize(width: 190, height: 30),
           "a 200pt screen with a 190pt cutout must collapse to exactly 190x30")
    let tightTrigger = NotchPanelGeometry.panelRect(for: .collapsed, on: tightNotched)
    expect(tightTrigger.minX >= 0 && tightTrigger.maxX <= 200
           && tightTrigger.maxY == tightNotched.frame.maxY,
           "a clamped trigger must stay fully inside its own screen and reach the physical top")

    // Three transient lateral proportions, all derived from the PUBLIC 185pt camera width.
    let compact = NotchPanelGeometry.expandedSize(hardware185, profile: .compact)
    let balanced = NotchPanelGeometry.expandedSize(hardware185, profile: .balanced)
    let wide = NotchPanelGeometry.expandedSize(hardware185, profile: .wide)
    expect(compact == CGSize(width: 561, height: 164),
           "Compact must be camera + 2*188 wide and camera band + 132 tall (561x164 here)")
    expect(balanced == CGSize(width: 657, height: 180),
           "Balanced must be camera + 2*236 wide and camera band + 148 tall (657x180 here)")
    expect(wide == CGSize(width: 769, height: 164),
           "Wide must be camera + 2*292 wide and camera band + 132 tall (769x164 here)")
    for profile in NotchIslandProfile.allCases {
        expect(NotchPanelGeometry.expandedWidth(hardware185, profile: profile)
               == 185 + 2 * profile.lateralExtension,
               "\(profile) width must be the public camera width plus its symmetric extension")
        expect(NotchPanelGeometry.expandedSize(hardware185, profile: profile).height
               == 32 + NotchPanelGeometry.mainBodyHeight(for: profile),
               "\(profile) height must be the hardware band plus its derived main body")
    }

    // The main body height stays DERIVED from the rows the page draws plus the profile's own
    // top/bottom padding: 132pt for Compact/Wide and 148pt for Balanced.
    let rowSum = NotchPanelGeometry.mainPageRowHeights.reduce(0, +)
    let rowGaps = CGFloat(NotchPanelGeometry.mainPageRowHeights.count - 1) * NotchPanelGeometry.mainRowGap
    for profile in NotchIslandProfile.allCases {
        expect(NotchPanelGeometry.mainBodyHeight(for: profile)
               == rowSum + rowGaps + 2 * profile.mainBodyPadding,
               "\(profile) body height must equal its rows plus gaps plus the profile padding")
    }
    expect(NotchPanelGeometry.mainBodyHeight(for: .compact) == 132
           && NotchPanelGeometry.mainBodyHeight(for: .wide) == 132
           && NotchPanelGeometry.mainBodyHeight(for: .balanced) == 148,
           "the three profiles must produce the documented 132/148/132 main bodies")
    expect(NotchPanelGeometry.mainPageRowHeights
           == [NotchPanelGeometry.titleRowHeight, NotchPanelGeometry.minimumControlSize,
               NotchPanelGeometry.minimumControlSize, NotchPanelGeometry.minimumControlSize],
           "the main page must draw the title/close, transport/volume navigation and shared timer rows")
    expect(NotchPanelGeometry.titleRowHeight == 28
           && NotchPanelGeometry.titleRowHeight == NotchPanelGeometry.minimumControlSize,
           "the title row must host the 28pt close control and every main row must be 28pt")

    // Camera exclusion: the reserved band is the whole public hardware band, the body starts at its
    // lower edge, and the sharp character region lives inside the body (never in the band).
    let balancedLayout = NotchPanelGeometry.layout(on: hardware185, profile: .balanced)
    expect(NotchPanelGeometry.reservedBandHeight(hardware185) == 32,
           "on a notched display the whole hardware band must be reserved above the controls")
    expect(balancedLayout.reservedBandHeight == 32
           && balancedLayout.bodyHeight == NotchPanelGeometry.mainBodyHeight(for: .balanced)
           && balancedLayout.bodyVerticalPadding == 2 * NotchPanelGeometry.balancedMainBodyPadding,
           "the island body must be the honest main body below the reserved hardware band")
    let balancedRect = NotchPanelGeometry.panelRect(for: .expanded, on: hardware185,
                                                    profile: .balanced)
    expect(balancedRect.maxY == hardware185.frame.maxY,
           "expansion must keep the SAME top edge as the closed window")
    expect(balancedRect.maxY - balancedLayout.reservedBandHeight == 950,
           "every readable control must start exactly at the lower edge of the cutout")
    expect(balancedLayout.showsCharacterImage && balancedLayout.characterRegionWidth > 0,
           "the main page must reserve a left character region")
    expect(abs(balancedLayout.characterRegionWidth + balancedLayout.controlRegionWidth
               - balancedLayout.expandedSize.width) < 0.01,
           "the character region and the control region must exactly fill the expanded width")
    expect(balancedLayout.characterRegionWidth
           == NotchPanelGeometry.characterRegionWidth(for: balancedLayout.expandedSize.width),
           "the layout summary must expose the derived character-region width")
    // The character region shrinks on small displays so the control side always keeps its minimum.
    expect(NotchPanelGeometry.characterRegionWidth(for: 220) == 0,
           "a tiny display must give the control side the full width")
    expect(NotchPanelGeometry.characterRegionWidth(for: 400) == 60,
           "a 400pt island must reserve 340pt for controls and give the remaining 60pt to artwork")
    expect(NotchPanelGeometry.characterRegionWidth(for: 657)
           == 317,
           "a 657pt island must give the remaining 317pt to artwork instead of widening controls")

    // Every profile, on the reference display: symmetric, top-anchored and fully on the display.
    for profile in NotchIslandProfile.allCases {
        let rect = NotchPanelGeometry.panelRect(for: .expanded, on: hardware185, profile: profile)
        expect(rect.maxY == hardware185.frame.maxY
               && abs(rect.midX - hardware185.frame.midX) <= 0.5
               && rect.minX >= hardware185.frame.minX && rect.maxX <= hardware185.frame.maxX
               && rect.minY >= hardware185.frame.minY,
               "\(profile) must be top-center anchored and fully inside the display")
        expect(abs(rect.minX - hardware185.frame.minX)
               - abs(hardware185.frame.maxX - rect.maxX) <= 1,
               "\(profile) must leave both left and right screen edges balanced")
    }

    // Secondary pages derive their width from the chosen proportion and keep their detail height.
    let queueLayout = NotchPanelGeometry.layout(on: hardware185, page: .queue, profile: .balanced)
    expect(queueLayout.expandedSize.width == 657
           && queueLayout.bodyHeight == NotchPanelGeometry.queueBodyHeight
           && queueLayout.expandedSize.height == 32 + NotchPanelGeometry.queueBodyHeight,
           "the queue page must use the chosen width with only its own list body added")
    expect(NotchPanelGeometry.queueBodyHeight
           == NotchPanelGeometry.headerHeight + NotchPanelGeometry.minimumControlSize
              + NotchPanelGeometry.queueListHeight + 2 * NotchPanelGeometry.bodyPadding
              + 2 * NotchPanelGeometry.queueRowGap
           && NotchPanelGeometry.queueListHeight >= 2 * NotchPanelGeometry.minimumControlSize,
           "the queue body must be the exact sum of its chrome rows, the list and padding")
    let backgroundLayout = NotchPanelGeometry.layout(on: hardware185, page: .background,
                                                     profile: .wide)
    expect(backgroundLayout.expandedSize.width == 769
           && backgroundLayout.bodyHeight == NotchPanelGeometry.backgroundBodyHeight
           && backgroundLayout.expandedSize.height == 32 + NotchPanelGeometry.backgroundBodyHeight,
           "the background page must use the chosen width with its detail body")
    // The secondary pages keep the full width for detail: no character reserve.
    expect(queueLayout.characterRegionWidth == 0 && !queueLayout.showsCharacterImage
           && backgroundLayout.characterRegionWidth == 0,
           "secondary pages must not reserve the character region")

    // Clamp: the island never exceeds the (visible) screen width minus the 48pt margin.
    let narrowVisibleWidth: CGFloat = 400
    let narrowPanelWideScreen = NotchScreenDescriptor(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 0, width: narrowVisibleWidth, height: 944),
        topInset: 32,
        auxiliaryTopLeft: CGRect(x: 0, y: 950, width: 676, height: 32),
        auxiliaryTopRight: CGRect(x: 836, y: 950, width: 676, height: 32))
    expect(NotchPanelGeometry.screenMargin == 48,
           "the expanded width must be capped to the screen width minus 48")
    expect(NotchPanelGeometry.expandedWidth(narrowPanelWideScreen, profile: .balanced)
           == narrowVisibleWidth - NotchPanelGeometry.screenMargin
           && NotchPanelGeometry.expandedWidth(narrowPanelWideScreen, profile: .balanced)
              < 657,
           "the expanded width must be capped by the visible frame, not the physical frame")

    // Small screens: the designed width is kept while it fits, then clamped to the screen.
    let narrow = NotchScreenDescriptor(frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                                       visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 575))
    expect(NotchPanelGeometry.expandedWidth(narrow, profile: .balanced)
           == NotchPanelGeometry.cameraWidth(narrow) + 2 * 236,
           "a screen wider than the design must keep the chosen proportion width")
    let cramped = NotchScreenDescriptor(frame: CGRect(x: 0, y: 0, width: 420, height: 600),
                                        visibleFrame: CGRect(x: 0, y: 0, width: 420, height: 575))
    expect(NotchPanelGeometry.expandedWidth(cramped, profile: .balanced)
           == 420 - NotchPanelGeometry.screenMargin,
           "the expanded width must be capped to the screen width minus the margin")
    expect(NotchPanelGeometry.expandedWidth(cramped, page: .background, profile: .wide)
           == 420 - NotchPanelGeometry.screenMargin,
           "the background page must be capped by the same screen margin")
    expect(NotchPanelGeometry.layout(on: narrow, page: .background, profile: .balanced)
            .expandedSize.height <= narrow.frame.height,
           "no page may draw past the bottom of its own display")
    let tiny = NotchScreenDescriptor(frame: CGRect(x: 0, y: 0, width: 220, height: 400),
                                     visibleFrame: CGRect(x: 0, y: 0, width: 220, height: 375))
    let tinyRect = NotchPanelGeometry.panelRect(for: .expanded, on: tiny, profile: .wide)
    expect(tinyRect.width <= 220 && tinyRect.minX >= 0 && tinyRect.maxX <= 220
           && tinyRect.width > 0 && tinyRect.height > 0
           && tinyRect.maxY <= tiny.frame.maxY && tinyRect.minY >= tiny.frame.minY,
           "a very small screen must clamp a positive island rectangle inside its own frame")

    // No notch: a small transparent grab region just below the menu-bar reserved edge; expansion
    // still places its controls below the menu bar and never covers menu items.
    let plain = NotchScreenDescriptor(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                      visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1057))
    expect(!NotchPanelGeometry.hasNotch(plain) && NotchPanelGeometry.hardwareBandHeight(plain) == 0,
           "a zero top inset must not claim a cutout")
    expect(NotchPanelGeometry.topEdge(plain) == plain.visibleFrame.maxY,
           "without a cutout the island top edge is the menu-bar reserved edge")
    let plainCollapsed = NotchPanelGeometry.panelRect(for: .collapsed, on: plain)
    expect(plainCollapsed.size == CGSize(width: 120, height: 14)
           && plainCollapsed.maxY == plain.visibleFrame.maxY
           && abs(plainCollapsed.midX - plain.frame.midX) < 0.5,
           "without a cutout the target is a centered 120x14 under-menubar region")
    expect(plainCollapsed.height < NotchPanelGeometry.minimumControlSize,
           "the no-notch grab region must stay a minimal, invisible-at-rest affordance")
    let plainLayout = NotchPanelGeometry.layout(on: plain, profile: .balanced)
    expect(plainLayout.reservedBandHeight == NotchPanelGeometry.headerHeight
           && plainLayout.collapsedSize == NotchPanelGeometry.grabHandleSize,
           "without a cutout the one 28pt header row sits below the menu-bar edge")
    let plainExpanded = NotchPanelGeometry.panelRect(for: .expanded, on: plain, profile: .balanced)
    expect(plainExpanded.maxY == plain.visibleFrame.maxY
           && plainExpanded.maxY - plainLayout.reservedBandHeight <= plain.visibleFrame.maxY,
           "the no-notch island body must stay below the menu-bar reserved edge")

    // Short hardware band: the WHOLE public band is still reserved above the controls.
    let shortTop = NotchScreenDescriptor(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
        topInset: 21,
        auxiliaryTopLeft: CGRect(x: 0, y: 961, width: 656, height: 21),
        auxiliaryTopRight: CGRect(x: 856, y: 961, width: 656, height: 21))
    let shortLayout = NotchPanelGeometry.layout(on: shortTop, profile: .compact)
    expect(shortLayout.hardwareBandHeight == 21 && shortLayout.reservedBandHeight == 21
           && shortLayout.collapsedSize == CGSize(width: 200, height: 21),
           "a short band must reserve and cover exactly its own real cutout (200x21)")
    expect(shortLayout.expandedSize.height == 21 + NotchPanelGeometry.mainBodyHeight(for: .compact)
           && shortLayout.expandedSize.height == NotchPanelGeometry.totalHeight(shortTop, profile: .compact),
           "a short band must grow the total only by the real hardware band")

    // No aux areas but a real inset: the cutout width is never guessed, but the WHOLE public inset
    // is still reserved above the controls.
    let unknownCutout = NotchScreenDescriptor(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
        topInset: 32)
    expect(!NotchPanelGeometry.hasUsableCutoutGeometry(unknownCutout)
           && NotchPanelGeometry.cameraWidth(unknownCutout) == NotchPanelGeometry.fallbackNotchWidth,
           "an unknown public cutout width must never be guessed from pixels")
    expect(NotchPanelGeometry.layout(on: unknownCutout).reservedBandHeight == 32
           && NotchPanelGeometry.collapsedSize(unknownCutout)
              == CGSize(width: NotchPanelGeometry.fallbackNotchWidth, height: 32),
           "an unknown cutout still reserves the whole public band and uses the nominal trigger")

    // Negative-origin / stacked displays: center inside the display's own frame.
    let secondary = NotchScreenDescriptor(frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080))
    let secondaryRect = NotchPanelGeometry.panelRect(for: .expanded, on: secondary, profile: .wide)
    expect(abs(secondaryRect.midX - (-960)) <= 0.5
           && secondaryRect.minX >= -1920 && secondaryRect.maxX <= 0,
           "a negative-origin display must stay correctly centered inside its own frame")
    let notchedSecondary = NotchScreenDescriptor(
        frame: CGRect(x: -1512, y: -200, width: 1512, height: 982),
        visibleFrame: CGRect(x: -1512, y: -200, width: 1512, height: 944),
        topInset: 24,
        auxiliaryTopLeft: CGRect(x: -1512, y: 758, width: 656, height: 24),
        auxiliaryTopRight: CGRect(x: -656, y: 758, width: 656, height: 24))
    let stacked = NotchPanelGeometry.panelRect(for: .collapsed, on: notchedSecondary)
    expect(stacked.size == CGSize(width: 200, height: 24)
           && stacked.maxY == notchedSecondary.frame.maxY
           && abs(stacked.midX - notchedSecondary.frame.midX) <= 0.5,
           "a negative-origin display keeps its own exact cutout hit rectangle")
    let above = NotchScreenDescriptor(frame: CGRect(x: 0, y: 1080, width: 1512, height: 982))
    expect(NotchPanelGeometry.panelRect(for: .collapsed, on: above).maxY == 2062,
           "a display stacked above the main one must anchor to its own top edge")

    // Readable/clickable minima and the finite responsiveness values.
    expect(NotchPanelGeometry.minimumControlSize >= 28 && NotchPanelGeometry.minimumTextSize >= 11,
           "the island must keep the 28pt hit and 11pt readable minima")
    expect(NotchPanelGeometry.transitionDuration == 0.14,
           "the finite window transition must be the 0.14s target")
    expect(NotchPanelGeometry.hoverEntryDelay == 0.01,
           "the hover entry debounce must be the 0.01s target")
    expect(NotchPanelGeometry.hoverEntryDelay < NotchPanelGeometry.hoverCollapseDelay,
           "entry stays brief while leave retains a short re-entry grace")
}
// MARK: - Closed surface policy

/// The resting island is COMPLETELY INVISIBLE on every display. On notched hardware it is exactly
/// the public cutout (an invisible hardware-sized hover/tap trigger); without hardware it is the
/// minimal transparent grab region. No artwork, wing, cover, border or decorative notch is drawn,
/// independent of the deeper native target used only by the no-notch fallback.
private func runNotchClosedSurfaceRegression(expect: (Bool, String) -> Void) {
    let notched = NotchScreenDescriptor(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
        topInset: 32,
        auxiliaryTopLeft: CGRect(x: 0, y: 950, width: 676, height: 32),
        auxiliaryTopRight: CGRect(x: 836, y: 950, width: 676, height: 32))
    let plain = NotchScreenDescriptor(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                      visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1057))
    expect(NotchIslandSurface.collapsedSurfaceIsInvisible,
           "the collapsed surface must be invisible: no visible cover, wing or artwork")
    expect(NotchIslandSurface.closedSilhouetteOpacity(on: notched) == 0
           && NotchIslandSurface.isTransparentWhenClosed(on: notched),
           "a real notched display must draw NOTHING at rest")
    expect(NotchIslandSurface.closedSilhouetteOpacity(on: plain) == 0
           && NotchIslandSurface.isTransparentWhenClosed(on: plain),
           "a display without hardware must draw nothing at rest (no decorative notch)")

    // The same policy must reach the rendered layout summary for each display kind.
    let notchedLayout = NotchPanelGeometry.layout(on: notched)
    let plainLayout = NotchPanelGeometry.layout(on: plain)
    expect(notchedLayout.closedSurfaceIsTransparent && notchedLayout.closedSilhouetteOpacity == 0,
           "the notched closed-surface policy must reach the rendered layout summary")
    expect(plainLayout.closedSurfaceIsTransparent && plainLayout.closedSilhouetteOpacity == 0,
           "the no-notch closed-surface policy must reach the rendered layout summary")

    // The resting trigger is exactly the cutout (no skirt), clamped to the owning screen and never
    // an oversized invisible canvas.
    func checkInvisibleTrigger(_ screen: NotchScreenDescriptor, _ label: String) {
        let closed = NotchIslandSurface.closedRect(on: screen)
        expect(closed.width <= screen.frame.width + 0.01
               && closed.height <= screen.frame.height + 0.01,
               "\(label): the trigger must stay inside its own screen bounds")
        expect(closed.width == min(NotchPanelGeometry.cameraWidth(screen), screen.frame.width)
               && closed.height == min(NotchPanelGeometry.hardwareBandHeight(screen),
                                       screen.frame.height),
               "\(label): the trigger must be EXACTLY the public cutout, with no software skirt")
        expect(closed.maxY == screen.frame.maxY,
               "\(label): the trigger must reach the physical screen top")
        expect(closed.height < NotchPanelGeometry.totalHeight(screen),
               "\(label): the trigger must be far smaller than the expanded panel")
    }
    checkInvisibleTrigger(notched, "wide notched display")
    checkInvisibleTrigger(NotchScreenDescriptor(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982), topInset: 21,
        auxiliaryTopLeft: CGRect(x: 0, y: 961, width: 656, height: 21),
        auxiliaryTopRight: CGRect(x: 856, y: 961, width: 656, height: 21)), "short band")
    checkInvisibleTrigger(NotchScreenDescriptor(
        frame: CGRect(x: 0, y: 0, width: 220, height: 400), topInset: 30,
        auxiliaryTopLeft: CGRect(x: 0, y: 370, width: 80, height: 30),
        auxiliaryTopRight: CGRect(x: 140, y: 370, width: 80, height: 30)), "tiny notched display")

    // The hardware band is the ONLY reserved strip: the body is never covered by the trigger.
    expect(notchedLayout.hardwareBandHeight == 32
           && notchedLayout.reservedBandHeight == 32
           && notchedLayout.collapsedSize == CGSize(width: 160, height: 32),
           "the invisible trigger must not change the reserved hardware band or add a skirt")
    expect(notchedLayout.expandedSize.height
           == 32 + NotchPanelGeometry.mainBodyHeight(for: .balanced),
           "the expanded height must still be the hardware band plus the honest main body")

    // Non-notched: the closed region is the small transparent grab affordance below the menu bar.
    let plainClosed = NotchIslandSurface.closedRect(on: plain)
    expect(plainClosed.size == NotchPanelGeometry.grabHandleSize
           && plainClosed.size == CGSize(width: 120, height: 6)
           && plainClosed.height < NotchPanelGeometry.minimumControlSize,
           "the no-notch fallback must stay a minimal, invisible-at-rest grab region")
    expect(plainClosed.maxY == plain.visibleFrame.maxY,
           "the no-notch fallback must sit below the menu-bar reserved edge")
}
// MARK: - Shape path bounds

/// The adapted notch shape must stay inside whatever rect it is given. Every radius is clamped
/// against both the width and the height.
private func runNotchShapeRegression(expect: (Bool, String) -> Void) {
    func expectInside(_ size: CGSize, _ label: String) {
        let rect = CGRect(origin: .zero, size: size)
        let path = NotchShape().path(in: rect)
        expect(!path.isEmpty, "the \(label) island shape must produce a path")
        let bounds = path.boundingRect
        let tolerance: CGFloat = 0.01
        expect(bounds.minX >= rect.minX - tolerance && bounds.maxX <= rect.maxX + tolerance
               && bounds.minY >= rect.minY - tolerance && bounds.maxY <= rect.maxY + tolerance,
               "the \(label) island shape must stay inside its \(Int(size.width))x\(Int(size.height)) rect")
    }

    // The no-notch closed grab region: 120x6, where the default 10pt top flare would reach y=10.
    expectInside(NotchPanelGeometry.grabHandleSize, "120x6 fallback")
    expect(NotchShape().path(in: CGRect(origin: .zero, size: NotchPanelGeometry.grabHandleSize))
            .boundingRect.maxY <= NotchPanelGeometry.grabHandleSize.height + 0.01,
           "the 120x6 fallback path must be clamped by the 6pt height, not the 10pt top radius")
    // Narrow and tiny rects: the radius must never push the path past the rect edge.
    expectInside(CGSize(width: 20, height: 32), "20x32 narrow")
    expectInside(CGSize(width: 6, height: 6), "6x6 tiny")
    // The invisible hardware trigger silhouettes.
    expectInside(CGSize(width: 160, height: 32), "160x32 cutout trigger")
    expectInside(CGSize(width: 185, height: 32), "185x32 current hardware trigger")
    // The three shipped proportions and a secondary page.
    expectInside(CGSize(width: 561, height: 164), "561x164 compact island")
    expectInside(CGSize(width: 657, height: 180), "657x180 balanced island")
    expectInside(CGSize(width: 769, height: 164), "769x164 wide island")
    expectInside(CGSize(width: 657, height: 32 + NotchPanelGeometry.backgroundBodyHeight),
                 "background island with the enlarged picture area")
}
// MARK: - Frame transition ownership

/// The finite frame animation must always settle on the newest intent's EXACT rectangle, and a
/// superseded completion must never resize the window.
private func runNotchFrameTransitionRegression(expect: (Bool, String) -> Void) {
    var transition = NotchFrameTransition()
    let collapsed = CGRect(x: 676, y: 950, width: 160, height: 32)
    let expanded = CGRect(x: 556, y: 818, width: 400, height: 164)
    let background = CGRect(x: 556, y: 702, width: 400, height: 280)

    expect(transition.targetIsCollapsed && transition.generation == 0,
           "a fresh frame transition must start with no recorded intent")

    let open = transition.begin(target: expanded, collapsed: false)
    expect(transition.completionIsCurrent(token: open)
           && transition.completionFrame(token: open) == expanded
           && !transition.targetIsCollapsed,
           "an expand intent must own its own completion and exact final frame")

    // Rapid reversal: close, reopen, then change page. Only the newest completion may finalize.
    let close = transition.begin(target: collapsed, collapsed: true)
    let reopen = transition.begin(target: expanded, collapsed: false)
    let page = transition.begin(target: background, collapsed: false)
    expect(!transition.completionIsCurrent(token: open)
           && !transition.completionIsCurrent(token: close)
           && !transition.completionIsCurrent(token: reopen),
           "every superseded transition must be stale after a newer intent")
    expect(transition.completionIsCurrent(token: page)
           && transition.completionFrame(token: page) == background,
           "only the newest page intent may finalize the frame")
    expect(transition.completionFrame(token: close) == nil,
           "a stale collapse completion must never install its frame")
    expect(transition.generation == 4, "every real intent must advance the generation exactly once")

    // Repeat open / close / distinguish-collapse cycles: the LAST intent always wins and it is
    // always the exact collapsed rectangle at the end.
    for _ in 0..<8 {
        _ = transition.begin(target: expanded, collapsed: false)
        _ = transition.begin(target: collapsed, collapsed: true)
    }
    let lastClose = transition.begin(target: collapsed, collapsed: true)
    expect(transition.completionIsCurrent(token: lastClose)
           && transition.completionFrame(token: lastClose) == collapsed
           && transition.targetIsCollapsed,
           "repeated open/close cycles must settle on the exact collapsed bounds")
    // A stale page intent must not resurrect a wide invisible surface.
    expect(transition.completionFrame(token: page) == nil,
           "an old page completion must not restore a wider canvas after the island closed")

    // Invalidation (screen change / shutdown) discards every queued completion without changing the
    // newest exact target.
    transition.invalidate()
    expect(!transition.completionIsCurrent(token: lastClose)
           && transition.completionFrame(token: lastClose) == nil
           && transition.target == collapsed,
           "invalidation must discard in-flight completions and keep the exact target")
    let afterInvalidation = transition.begin(target: expanded, collapsed: false)
    expect(transition.completionFrame(token: afterInvalidation) == expanded,
           "a new intent after an invalidation must own the frame again")

    // Keyboard promotion changes NO geometry. When the newest in-flight intent already owns exactly
    // the intended frame, the transition (and its generation) must be left completely alone, so the
    // running animation is neither snapped nor restarted and its own completion still settles the
    // exact bounds. Only a genuinely different intended frame becomes a new intent.
    var promotion = NotchFrameTransition()
    let promotionToken = promotion.begin(target: expanded, collapsed: false)
    expect(promotion.promoteToKeyboard(target: expanded, collapsed: false) == nil
           && promotion.generation == 1
           && promotion.completionIsCurrent(token: promotionToken)
           && promotion.completionFrame(token: promotionToken) == expanded,
           "a promotion of the already-owned frame must preserve the in-flight transition and generation")
    let retarget = promotion.promoteToKeyboard(target: background, collapsed: false)
    expect(retarget == background
           && !promotion.completionIsCurrent(token: promotionToken)
           && promotion.completionFrame(token: promotionToken) == nil
           && promotion.target == background,
           "a promotion with a really different intended frame must retarget as the newest intent")

    // Diagnostics: discarded completions are observable (never silently swallowed).
    var stale = NotchFrameTransition()
    let first = stale.begin(target: expanded, collapsed: false)
    _ = stale.begin(target: collapsed, collapsed: true)
    if stale.completionFrame(token: first) == nil { stale.noteStaleCompletion() }
    expect(stale.staleCompletionCount == 1,
           "a discarded stale completion must be observable in the seam")
}

// MARK: - Panel configuration

/// The public AppKit configuration that keeps the island reachable over native fullscreen: the
/// panel is floating BEFORE its final level, joins every Space INCLUDING other applications' sets,
/// is never shown above the system login/lock UI, and never activates the main application. The
/// review-only experimental level follows the Apple DTS guidance and does not claim universal
/// coverage.
private func runNotchPanelConfigurationRegression(expect: (Bool, String) -> Void) {
    expect(NotchPanelConfiguration.makesFloatingPanelBeforeLevel,
           "isFloatingPanel must be configured BEFORE the final window level")
    expect(NotchPanelConfiguration.ordinaryStatusBarLevel == 25,
           "the ordinary product level seam must stay the public status-bar level (25)")
    expect(NotchPanelConfiguration.experimentalFullScreenVideoLevel
           == Int(NSWindow.Level.screenSaver.rawValue),
           "the experimental fullscreen-video level must be the public screen-saver level")
    expect(NotchPanelConfiguration.usesExperimentalFullScreenVideoLevel
           && NotchPanelConfiguration.windowLevel
              == NotchPanelConfiguration.experimentalFullScreenVideoLevel,
           "the review prototype must apply the experimental fullscreen-video level")
    expect(NotchPanelConfiguration.windowLevel > Int(NSWindow.Level.normal.rawValue),
           "the level must be above ordinary windows")
    expect(NotchPanelConfiguration.joinsAllSpaces
           && NotchPanelConfiguration.joinsAllApplications
           && NotchPanelConfiguration.isFullScreenAuxiliary
           && NotchPanelConfiguration.isStationary,
           "the island must join every Space and other apps' sets, stay in fullscreen and not move")
    expect(NotchPanelConfiguration.hidesOnDeactivate == false,
           "the island must stay visible when the application is not active")
    expect(NotchPanelConfiguration.canBecomeVisibleWithoutLogin == false,
           "the island must never be shown above the system login/lock UI")
    expect(NotchPanelConfiguration.becomesKeyOnlyIfNeeded,
           "keyboard access must be granted only when needed, never on hover")
    expect(!NotchPanelConfiguration.activatesApplication,
           "a routine island adjustment must never activate the main application or open its window")

    // The exact AppKit bits the controller applies, asserted on the real types (no window ordered
    // on screen and no screen required).
    let behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications,
                                                 .fullScreenAuxiliary, .stationary]
    expect(behavior.contains(.canJoinAllSpaces) && behavior.contains(.fullScreenAuxiliary)
           && behavior.contains(.canJoinAllApplications),
           "the collection behavior must contain canJoinAllSpaces + canJoinAllApplications + fullScreenAuxiliary")
    expect(!behavior.contains(.moveToActiveSpace),
           "the island must never carry this Space along with the application")

    // The one panel keeps a transparent window backing store so the SwiftUI content owns every
    // pixel. The SHIPPING `NotchPanel` subclass is used, because the `constrainFrameRect` override
    // lives on it.
    let panel = NotchPanel(contentRect: CGRect(x: 0, y: 0, width: 185, height: 32),
                           styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
    // The ORDER is what the product depends on: `isFloatingPanel`'s setter RESETS the level, so the
    // level must be applied after it. The reverse order is asserted first so this cannot silently
    // regress into the level-3 panel seen in PLACEMENT_EVIDENCE.md.
    panel.level = NSWindow.Level(rawValue: NotchPanelConfiguration.windowLevel)
    panel.isFloatingPanel = true
    expect(panel.level.rawValue != NotchPanelConfiguration.windowLevel,
           "assigning the level BEFORE the floating flag must be shown to be reset (the real ordering bug)")
    panel.isFloatingPanel = true
    panel.level = NSWindow.Level(rawValue: NotchPanelConfiguration.windowLevel)
    panel.collectionBehavior = behavior
    panel.canBecomeVisibleWithoutLogin = NotchPanelConfiguration.canBecomeVisibleWithoutLogin
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    expect(panel.styleMask.contains(.nonactivatingPanel) && panel.styleMask.contains(.borderless),
           "the island panel must be a borderless nonactivating panel")
    expect(!panel.isOpaque && panel.backgroundColor == .clear && !panel.hasShadow,
           "the panel must keep a transparent window backing store with no shadow")
    expect(panel.isFloatingPanel && panel.level.rawValue == NotchPanelConfiguration.windowLevel,
           "the floating-panel flag must survive the final level assignment")
    expect(panel.canBecomeKey && !panel.canBecomeMain,
           "the panel must accept Esc/close keys without becoming a main window")
    expect(panel.canBecomeVisibleWithoutLogin == false,
           "the real panel must refuse to become visible without a logged-in session")
    expect(panel.collectionBehavior.contains(.canJoinAllApplications),
           "the real panel must carry the public canJoinAllApplications flag")
    // `constrainFrameRect` must not pull the collapsed panel away from the physical screen top, so
    // the invisible trigger really occupies the hardware cutout geometry.
    if let screen = NSScreen.main {
        let requested = NotchPanelGeometry.panelRect(
            for: .collapsed, on: NotchPanelController.descriptor(screen))
        let constrained = panel.constrainFrameRect(requested, to: screen)
        expect(constrained == requested,
               "the public frame override must return the proposed rect unchanged (no visible-frame clamp)")
        expect(constrained.maxY == requested.maxY,
               "AppKit frame constraining must not move the closed panel below the physical screen top")
    }
    expect(NotchPanelConfiguration.overridesFrameConstraint,
           "the island panel must own the public constrainFrameRect override")
    // The ONE panel is hosted by a view that accepts the owner's FIRST mouse click, so the
    // presentation-only title double-click (and every other island control) is delivered without a
    // focus-activating click and without activating the application.
    let hosting = NotchHostingView(rootView: NotchPanelRootView(
        presentation: NotchPanelPresentation(),
        pageModel: NotchIslandPageModel(),
        controlCenter: ControlCenterModel(),
        performance: PerformanceBrowserModel(), study: StudyTimerController(),
        backgrounds: DailyBackgroundChooserModel(),
        layout: NotchPanelGeometry.layout(on: NotchScreenDescriptor(frame: .zero)),
        actions: NotchControlActions()))
    expect(hosting.acceptsFirstMouse(for: nil),
           "the island hosting view must accept the first mouse click for the title gesture")
    panel.close()
}
// MARK: - Hosting geometry (hidden panel)

/// A hidden real panel proves content updates cannot resize it behind the frame controller.
/// No panel is ordered front, no pointer is synthesized, and this is not visual motion acceptance.
private func runNotchHostingGeometryRegression(expect: (Bool, String) -> Void) {
    let screen = NotchScreenDescriptor(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950), topInset: 32,
        auxiliaryTopLeft: CGRect(x: 0, y: 950, width: 663.5, height: 32),
        auxiliaryTopRight: CGRect(x: 848.5, y: 950, width: 663.5, height: 32))
    let collapsed = NotchPanelGeometry.panelRect(for: .collapsed, on: screen)
    for profile in NotchIslandProfile.allCases {
        let presentation = NotchPanelPresentation()
        presentation.profileModel.select(profile)
        let host = NotchHostingView(rootView: NotchPanelRootView(
            presentation: presentation, pageModel: NotchIslandPageModel(),
            controlCenter: ControlCenterModel(), performance: PerformanceBrowserModel(), study: StudyTimerController(),
            backgrounds: DailyBackgroundChooserModel(),
            layout: NotchPanelGeometry.layout(on: screen, profile: profile), actions: NotchControlActions()))
        let panel = NotchPanel(contentRect: collapsed, styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = host
        panel.setFrame(collapsed, display: false)
        func flushLayout() {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        flushLayout()
        presentation.toggle()
        flushLayout()
        expect(panel.frame == collapsed,
               "\(profile.rawValue): revealing content must not resize at the old origin before expansion")
        func drawingIsTopCentered() -> Bool {
            guard let drawing = host.subviews.first?.frame else { return false }
            let drawingTop = host.isFlipped ? drawing.minY : drawing.maxY
            let viewportTop = host.isFlipped ? host.bounds.minY : host.bounds.maxY
            return drawingTop == viewportTop && drawing.midX == host.bounds.midX
        }
        expect(drawingIsTopCentered(),
               "\(profile.rawValue): full drawing must stay top-centered in the opening viewport")
        expect(panel.contentMinSize == .zero,
               "\(profile.rawValue): expanded content must not impose its own window minimum")

        let expanded = NotchPanelGeometry.panelRect(for: .expanded, on: screen, profile: profile)
        let fractionalSize = CGSize(width: collapsed.width + (expanded.width - collapsed.width) / 4,
                                    height: collapsed.height + (expanded.height - collapsed.height) / 4)
        let fractional = CGRect(x: collapsed.midX - fractionalSize.width / 2,
                                y: collapsed.maxY - fractionalSize.height,
                                width: fractionalSize.width, height: fractionalSize.height)
        panel.setFrame(fractional, display: false)
        let installedFractional = panel.frame
        flushLayout()
        print("NOTCH_FRAME_ROUNDING profile=\(profile.rawValue) requested=\(NSStringFromRect(fractional)) installed=\(NSStringFromRect(installedFractional)) afterLayout=\(NSStringFromRect(panel.frame))")
        // Native windows round fractional point sizes. Use a realizable intermediate rectangle
        // so this check detects content-driven resizing, not AppKit's initial frame rounding.
        let size = CGSize(width: (collapsed.width + (expanded.width - collapsed.width) / 4).rounded(),
                          height: (collapsed.height + (expanded.height - collapsed.height) / 4).rounded())
        let intermediate = CGRect(x: collapsed.midX - size.width / 2,
                                  y: collapsed.maxY - size.height, width: size.width, height: size.height)
        panel.setFrame(intermediate, display: false)
        flushLayout()
        expect(panel.frame == intermediate && panel.frame.maxY == collapsed.maxY
               && panel.frame.midX == collapsed.midX,
               "\(profile.rawValue): content layout must preserve an intermediate top-centered frame")
        expect(drawingIsTopCentered(),
               "\(profile.rawValue): full drawing must stay top-centered at an intermediate frame")
        presentation.collapse()
        presentation.toggle()
        flushLayout()
        expect(panel.frame == intermediate,
               "\(profile.rawValue): rapid content reversal must not retarget the real panel")

        panel.setFrame(expanded, display: false)
        presentation.expansionSettled()
        flushLayout()
        expect(panel.frame == expanded,
               "\(profile.rawValue): revealing sharp artwork must preserve the final expanded frame")
        presentation.collapse()
        panel.setFrame(collapsed, display: false)
        flushLayout()
        expect(panel.frame == collapsed,
               "\(profile.rawValue): retained closing content must not force the panel open again")
        presentation.surfaceSettledImmediately()
        flushLayout()
        expect(panel.frame == collapsed && !panel.isVisible,
               "\(profile.rawValue): the hidden regression must finish at exact collapsed bounds")
        presentation.shutdown()
        panel.close()
    }
}

// MARK: - Controller runtime (real panel)

/// The pure seams above cannot prove the ACTUAL panel the controller owns: the level order and
/// collection flags, the physical-top placement of the real window frame, the exact shrink-back on
/// close, the deferred sharp-artwork reveal, profile changes through the generation-safe animator,
/// and the workspace session/sleep hide. This drives the shipping controller with a real
/// (transparent, ordered-front) `NSPanel` and a bodyless root view, so the configuration is asserted
/// on the object the product uses — not on a duplicated test instance or on the constants.
private func runNotchControllerRuntimeRegression(expect: (Bool, String) -> Void) {
    var pointer = CGPoint.zero
    func makeController(onLeaveBackgroundPage: @escaping () -> Void = {}) -> NotchPanelController {
        let controller = NotchPanelController(onLeaveBackgroundPage: onLeaveBackgroundPage,
                                             contentBuilder: { presentation, pageModel, layout in
            NotchPanelRootView(presentation: presentation,
                               pageModel: pageModel,
                               controlCenter: ControlCenterModel(),
                               performance: PerformanceBrowserModel(), study: StudyTimerController(),
                               backgrounds: DailyBackgroundChooserModel(),
                               layout: layout,
                               actions: NotchControlActions())
        })
        // Real AppKit animation, just short enough that the regression can wait for the actual
        // completion instead of guessing a wall-clock heuristic.
        controller.transitionDuration = 0.02
        controller.pointerLocationProvider = { pointer }
        return controller
    }
    func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
    /// Wait for a predicate of the REAL panel, bounded, so a regression can never hang the suite.
    func waitUntil(_ label: String, _ predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(2.0)
        while !predicate() && Date() < deadline { pump(0.01) }
        if !predicate() { expect(false, "timed out waiting for \(label)") }
    }

    guard let screen = NotchPanelController.preferredScreen() else {
        expect(false, "the controller runtime regression needs a screen to place the island on")
        return
    }
    let descriptor = NotchPanelController.descriptor(screen)
    let collapsedRect = NotchPanelGeometry.panelRect(for: .collapsed, on: descriptor)
    let outsidePoint = CGPoint(x: descriptor.frame.minX - 10, y: descriptor.frame.minY - 10)
    pointer = outsidePoint
    func expandedRect(_ profile: NotchIslandProfile) -> CGRect {
        NotchPanelGeometry.panelRect(for: .expanded, on: descriptor, profile: profile)
    }
    let balancedRect = expandedRect(.balanced)
    let wideRect = expandedRect(.wide)

    var backgroundDismissals = 0
    let controller = makeController(onLeaveBackgroundPage: { backgroundDismissals += 1 })
    // The test's injected hover events and physical-position samples must describe the same input;
    // the owner's actual desktop pointer must not cancel this fixture's pending leave.
    func hover(_ inside: Bool) {
        pointer = inside ? CGPoint(x: collapsedRect.midX, y: collapsedRect.midY) : outsidePoint
        controller.presentation.hoverChanged(inside)
    }
    controller.install()
    expect(controller.isInstalled, "the controller must own exactly one panel after install")
    guard let installed = controller.panelState() else {
        expect(false, "the installed controller must expose its real panel state")
        return
    }

    // --- The panel is configured in the required ORDER, on the REAL object. ---
    expect(installed.isFloatingPanel,
           "the real island panel must be a floating panel before the level is applied")
    expect(installed.level == NotchPanelConfiguration.windowLevel,
           "the real panel must really sit at the configured level "
           + "\(NotchPanelConfiguration.windowLevel) (actual \(installed.level))")
    expect(installed.level > Int(NSWindow.Level.normal.rawValue),
           "the real panel level must be above ordinary windows")
    expect(installed.canJoinAllSpaces && installed.canJoinAllApplications
           && installed.fullScreenAuxiliary,
           "the real panel must join every Space and other apps' sets and remain reachable in fullscreen")
    expect(!installed.canBecomeVisibleWithoutLogin,
           "the real panel must never be shown above the login/lock UI")
    expect(!installed.isOpaque && !installed.hasShadow,
           "the real panel must be a transparent, shadowless surface")
    expect(installed.requestedFrame == collapsedRect && installed.actualFrame == collapsedRect,
           "the freshly installed panel must request AND realize the exact collapsed trigger rect")
    expect(controller.workspaceObserverCount > 0,
           "the installed controller must observe the public workspace session/sleep events")

    // --- Actual hit window occupies exactly the hardware cutout. ---
    expect(collapsedRect.maxY == descriptor.frame.maxY,
           "the collapsed rect must reach the physical top of the display")
    expect(installed.actualFrame.maxY == descriptor.frame.maxY,
           "the ACTUAL ordered panel must reach the physical screen top, never the menu-bar edge")
    if descriptor.topInset > 0.5 {
        expect(abs(installed.actualFrame.height - min(descriptor.topInset, descriptor.frame.height)) < 0.01,
               "actual collapsed panel ends exactly at the hardware band")
        expect(abs(installed.actualFrame.width
                   - min(NotchPanelGeometry.cameraWidth(descriptor), descriptor.frame.width)) < 0.01,
               "the actual collapsed panel width must be EXACTLY the public cutout")
    } else {
        expect(installed.actualFrame.size == CGSize(width: 120, height: 14),
               "without a cutout the actual collapsed panel is the 120x14 under-menubar target")
    }
    if screen.visibleFrame.maxY < descriptor.frame.maxY {
        expect(installed.actualFrame.maxY > screen.visibleFrame.maxY,
               "the actual collapsed panel must sit ABOVE the visible-frame edge")
    }
    expect(installed.surfaceIsVisible == false && installed.sharpArtworkIsVisible == false,
           "nothing may be drawn at rest: the collapsed trigger is completely invisible")

    // A duplicate screen notification must not settle an expansion early or cancel hover work.
    hover(true)
    let hoverIntent = controller.presentation.currentIntent
    let frameIntent = controller.frameIntentGeneration
    NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
    expect(controller.presentation.currentIntent == hoverIntent
           && controller.frameIntentGeneration == frameIntent,
           "unchanged screen geometry must preserve a pending hover entry")
    hover(false)

    // --- The expanded size is the honest, profile-derived body below the reserved hardware band. ---
    if let size = controller.currentExpandedSize {
        expect(size == NotchPanelGeometry.expandedSize(descriptor, profile: .balanced),
               "the controller's default expanded size must be the Balanced profile geometry")
        expect(size.height == NotchPanelGeometry.totalHeight(descriptor, profile: .balanced),
               "the controller's expanded size must be the display-derived total height")
    }

    // --- A real open/close cycle moves the ACTUAL window frame and restores it exactly. ---
    controller.toggle()
    let expandingIntent = controller.frameIntentGeneration
    NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
    expect(controller.frameIntentGeneration == expandingIntent
           && !controller.presentation.sharpArtworkIsVisible,
           "unchanged screen geometry must not snap or reveal an active expansion early")
    waitUntil("the expanded frame") { controller.panelState()?.actualFrame == balancedRect }
    expect(controller.isExpanded && controller.presentation.surfaceIsVisible,
           "an explicit open must expand the island and draw its surface")
    expect(controller.panelState()?.actualFrame == balancedRect,
           "opening must animate the REAL panel to the Balanced expanded rect")
    expect(controller.panelState()?.requestedFrame == balancedRect,
           "the newest requested frame must be the expanded rect")
    // The SHARP character layer is deferred until the expansion frame has settled, so the earliest
    // opening can never clip the face.
    waitUntil("the sharp artwork reveal") { controller.presentation.sharpArtworkIsVisible }
    expect(controller.presentation.sharpArtworkIsVisible,
           "the sharp character artwork must be revealed once the expansion frame has settled")

    controller.toggle()
    waitUntil("the collapsed frame") { controller.panelState()?.actualFrame == collapsedRect }
    expect(!controller.isExpanded,
           "a second explicit toggle must collapse the island")
    waitUntil("the collapsed artwork settle") {
        controller.presentation.surfaceIsVisible == false
            && controller.presentation.sharpArtworkIsVisible == false
    }
    expect(controller.panelState()?.actualFrame == collapsedRect
           && controller.presentation.surfaceIsVisible == false
           && controller.presentation.sharpArtworkIsVisible == false,
           "closing must restore the exact collapsed bounds and clear every drawn layer")

    // --- Changing the proportion resizes the ACTUAL window through the animator. ---
    controller.toggle()
    waitUntil("the Balanced expansion") {
        controller.isExpanded && controller.panelState()?.actualFrame == balancedRect
    }
    controller.presentation.profileModel.select(.wide)
    waitUntil("the Wide expansion") { controller.panelState()?.actualFrame == wideRect }
    expect(controller.panelState()?.actualFrame == wideRect
           && controller.panelState()?.requestedFrame == wideRect,
           "changing the profile must resize the real window to the new profile geometry")
    expect(wideRect.width > balancedRect.width && wideRect.height < balancedRect.height,
           "Wide must be wider and shorter than Balanced on the reference hardware")

    // --- A profile switch during the closing transition is generation-safe and cannot reopen. ---
    controller.presentation.collapse()
    controller.presentation.profileModel.select(.compact)
    waitUntil("the collapsed frame after the profile switch") {
        controller.panelState()?.actualFrame == collapsedRect
    }
    pump(0.2)
    expect(!controller.isExpanded
           && controller.panelState()?.actualFrame == collapsedRect
           && controller.presentation.surfaceIsVisible == false,
           "a profile switch during the closing transition must still settle fully collapsed")
    let compactRect = expandedRect(.compact)
    controller.toggle()
    waitUntil("the Compact reopening") { controller.panelState()?.actualFrame == compactRect }
    expect(controller.panelState()?.actualFrame == compactRect,
           "the reopened island must use the profile selected while it was closing")

    // --- A page change inside the panel really resizes the one window at the chosen profile. ---
    controller.showQueuePage()
    let queueRect = NotchPanelGeometry.panelRect(for: .expanded, on: descriptor, page: .queue,
                                                 profile: .compact)
    expect(queueRect != compactRect,
           "the queue page must have its own secondary size (not the compact main page)")
    waitUntil("the queue page frame") { controller.panelState()?.actualFrame == queueRect }
    expect(controller.panelState()?.actualFrame == queueRect,
           "selecting the queue page must resize the one real panel to the queue geometry")
    expect(controller.panelState()?.actualFrame.width == compactRect.width,
           "the queue page must stay on the chosen island width")
    hover(true)
    hover(false)
    waitUntil("the page-change collapsed frame") {
        !controller.isExpanded && controller.panelState()?.actualFrame == collapsedRect
    }
    expect(controller.currentPage == .main,
           "the hover deadline must reset the queue page without an explicit controller close")
    controller.toggle()
    expect(controller.isExpanded && controller.currentPage == .main && backgroundDismissals == 0,
           "reopening after automatic queue collapse must show the main page without background cleanup")

    // Exercise the shipping collapse routes: the shared chooser must be dismissed once per visit,
    // and a later close/reopen must not replay cleanup for the page that already left.
    let collapseRoutes: [(String, () -> Void)] = [
        ("toggle", { controller.toggle() }),
        ("hover deadline", {
            hover(true)
            hover(false)
        }),
        ("explicit close", { controller.collapseFromControl() })
    ]
    for (index, route) in collapseRoutes.enumerated() {
        controller.showBackgroundPage()
        expect(controller.isExpanded && controller.currentPage == .background,
               "the background page must be open before testing \(route.0)")
        route.1()
        waitUntil("the background page \(route.0)") { !controller.isExpanded }
        expect(controller.currentPage == .main && backgroundDismissals == index + 1,
               "\(route.0) must leave the background page and cancel its preview exactly once")
        controller.collapse()
        controller.toggle()
        expect(controller.isExpanded && controller.currentPage == .main
               && backgroundDismissals == index + 1,
               "an already-collapsed close and main-page reopen must not duplicate \(route.0) cleanup")
    }

    controller.shutdown()
    expect(controller.panelState() == nil && !controller.isInstalled
           && controller.workspaceObserverCount == 0 && backgroundDismissals == collapseRoutes.count,
           "shutdown must give up the one panel and every observer, leaving no timer or window behind")

    // --- Reduce Motion snaps the geometry and the artwork with no animation at all. ---
    let reduced = makeController()
    var liveReducedMotion = true
    reduced.reduceMotionProvider = { liveReducedMotion }
    reduced.install()
    expect(reduced.panelState()?.actualFrame == collapsedRect,
           "the Reduce Motion controller must start on the exact collapsed trigger")
    reduced.toggle()
    expect(reduced.panelState()?.actualFrame == balancedRect
           && reduced.presentation.surfaceIsVisible
           && reduced.presentation.sharpArtworkIsVisible,
           "Reduce Motion must snap straight to the expanded frame and reveal the artwork immediately")
    reduced.toggle()
    expect(reduced.panelState()?.actualFrame == collapsedRect
           && !reduced.presentation.surfaceIsVisible
           && !reduced.presentation.sharpArtworkIsVisible,
           "Reduce Motion must snap straight back to the invisible collapsed trigger")
    liveReducedMotion = false
    reduced.motionPreferencesDidChange()
    reduced.transitionDuration = 0.2
    reduced.toggle()
    expect(!reduced.reduceMotion, "the same controller must read a changed motion provider")
    liveReducedMotion = true
    NSWorkspace.shared.notificationCenter.post(
        name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    expect(reduced.panelState()?.actualFrame == balancedRect && reduced.presentation.sharpArtworkIsVisible,
           "a live Reduce Motion notification must settle an in-flight expansion immediately")
    reduced.toggle()
    expect(reduced.panelState()?.actualFrame == collapsedRect,
           "later transitions in the same controller must honor the updated Reduce Motion value")
    reduced.shutdown()
    expect(reduced.panelState() == nil, "the Reduce Motion controller must clean up its panel")

    // --- Workspace session resign/sleep hides the panel; active/wake restores it COLLAPSED. ---
    var workspaceDismissals = 0
    let workspace = makeController(onLeaveBackgroundPage: { workspaceDismissals += 1 })
    workspace.install()
    workspace.showBackgroundPage()
    waitUntil("the workspace expansion") {
        workspace.panelState()?.actualFrame == NotchPanelGeometry.panelRect(
            for: .expanded, on: descriptor, page: .background)
    }
    NSWorkspace.shared.notificationCenter.post(
        name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
    waitUntil("the session-resign hide") { workspace.isHiddenForWorkspaceEvent }
    expect(workspace.isHiddenForWorkspaceEvent && workspace.panelState()?.isVisible == false
           && !workspace.isExpanded && workspace.currentPage == .main && workspaceDismissals == 1
           && workspace.panelState()?.actualFrame == collapsedRect,
           "a session resign must cancel hover and background preview work, reset the page and hide the panel")
    NSWorkspace.shared.notificationCenter.post(
        name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
    expect(workspaceDismissals == 1,
           "a repeated session-resign event must not dismiss the background preview twice")
    NSWorkspace.shared.notificationCenter.post(
        name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
    waitUntil("the session-active restore") { !workspace.isHiddenForWorkspaceEvent }
    expect(workspace.panelState()?.isVisible == true && !workspace.isExpanded
           && workspace.panelState()?.actualFrame == collapsedRect
           && workspace.presentation.surfaceIsVisible == false
           && workspace.currentPage == .main && workspaceDismissals == 1,
           "becoming active must only ever restore the invisible COLLAPSED island")
    // Screen sleep/wake uses the same public path.
    workspace.showBackgroundPage()
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidSleepNotification,
                                               object: nil)
    waitUntil("the screen-sleep hide") { workspace.isHiddenForWorkspaceEvent }
    expect(workspace.panelState()?.isVisible == false && workspace.currentPage == .main
           && workspaceDismissals == 2,
           "screen sleep must hide the panel and dismiss the newly opened background preview once")
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidWakeNotification,
                                               object: nil)
    waitUntil("the screen-wake restore") { !workspace.isHiddenForWorkspaceEvent }
    expect(workspace.panelState()?.isVisible == true && !workspace.isExpanded
           && workspace.currentPage == .main && workspaceDismissals == 2,
           "screen wake must restore the invisible collapsed island")
    workspace.shutdown()
    expect(workspace.panelState() == nil && workspace.workspaceObserverCount == 0 && workspaceDismissals == 2,
           "the workspace controller must remove every observer on shutdown")
}
// MARK: - Keyboard promotion during a geometry transition

/// `applyKeyboardAccess` must grant Esc/close access WITHOUT snapping or restarting an in-flight
/// frame transition. An explicit click/menu/page promotion of an already hover-expanded island
/// changes no geometry, so the newest frame intent (and its generation) must be preserved and only
/// the transition's own completion may settle the exact final bounds. A promotion whose intended
/// geometry really differs must retarget as the newest intent.
private func runNotchKeyboardPromotionRegression(expect: (Bool, String) -> Void) {
    func makeController() -> NotchPanelController {
        let controller = NotchPanelController(contentBuilder: { presentation, pageModel, layout in
            NotchPanelRootView(presentation: presentation,
                               pageModel: pageModel,
                               controlCenter: ControlCenterModel(),
                               performance: PerformanceBrowserModel(), study: StudyTimerController(),
                               backgrounds: DailyBackgroundChooserModel(),
                               layout: layout,
                               actions: NotchControlActions())
        })
        controller.transitionDuration = 0.02
        controller.presentation.autoEntryDelay = 0.02
        return controller
    }
    func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
    func waitUntil(_ label: String, _ predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(2.0)
        while !predicate() && Date() < deadline { pump(0.01) }
        if !predicate() { expect(false, "timed out waiting for \(label)") }
    }

    guard let screen = NotchPanelController.preferredScreen() else {
        expect(false, "the keyboard promotion regression needs a screen to place the island on")
        return
    }
    let descriptor = NotchPanelController.descriptor(screen)
    let collapsedRect = NotchPanelGeometry.panelRect(for: .collapsed, on: descriptor)
    let expandedRect = NotchPanelGeometry.panelRect(for: .expanded, on: descriptor)
    let queueRect = NotchPanelGeometry.panelRect(for: .expanded, on: descriptor, page: .queue)

    // Hover-expand (never explicit): the exact state an explicit click/menu promotes to key.
    let controller = makeController()
    let insidePoint = CGPoint(x: collapsedRect.midX, y: collapsedRect.midY)
    var pointer = insidePoint
    controller.pointerLocationProvider = { pointer }
    controller.install()
    controller.presentation.hoverChanged(true)
    waitUntil("the hover expansion") { controller.isExpanded }
    expect(controller.isExpanded && !controller.presentation.lastExpansionWasExplicit,
           "the island must be hover-expanded and not yet explicitly owned")
    let generationBeforePromotion = controller.frameIntentGeneration
    let requestedBeforePromotion = controller.panelState()?.requestedFrame
    expect(requestedBeforePromotion == expandedRect,
           "the hover expansion must already own the exact expanded geometry")
    controller.presentation.toggle()
    expect(controller.presentation.lastExpansionWasExplicit && controller.isExpanded,
           "an explicit click on the hover-expanded island must promote it, not close it")
    expect(controller.frameIntentGeneration == generationBeforePromotion,
           "the promotion must preserve the in-flight geometry generation instead of restarting it")
    expect(controller.panelState()?.requestedFrame == requestedBeforePromotion,
           "the promotion must not retarget the already-correct geometry")
    waitUntil("the promoted expansion to settle") {
        controller.panelState()?.actualFrame == expandedRect
    }
    expect(controller.panelState()?.actualFrame == expandedRect,
           "the promoted expansion must still settle on the exact expanded bounds")

    // Page navigation promotion: selecting a page starts its own resize transition and the
    // promotion that grants keyboard access must not restart it.
    controller.showCollapsed()
    waitUntil("the collapsed frame before the page navigation") {
        !controller.isExpanded && controller.panelState()?.actualFrame == collapsedRect
    }
    pointer = CGPoint(x: descriptor.frame.minX - 10, y: descriptor.frame.minY - 10)
    controller.presentation.hoverChanged(false)   // the real leave clears the explicit-close suppression
    pointer = insidePoint
    controller.presentation.hoverChanged(true)
    waitUntil("the second hover expansion") { controller.isExpanded }
    expect(!controller.presentation.lastExpansionWasExplicit,
           "the second expansion must still be hover-owned before the page promotion")
    controller.pageModel.select(.queue)
    let generationBeforePagePromotion = controller.frameIntentGeneration
    expect(controller.panelState()?.requestedFrame == queueRect,
           "selecting the queue page must retarget the one panel to the queue geometry")
    controller.presentation.setExpandedFromPage()
    expect(controller.presentation.lastExpansionWasExplicit,
           "a page navigation must hand the panel keyboard access")
    expect(controller.frameIntentGeneration == generationBeforePagePromotion,
           "the page-navigation promotion must not restart the page resize transition")
    expect(controller.panelState()?.requestedFrame == queueRect,
           "the page-navigation promotion must keep the page's own geometry intent")
    waitUntil("the queue page frame to settle") {
        controller.panelState()?.actualFrame == queueRect
    }
    expect(controller.panelState()?.actualFrame == queueRect,
           "the page navigation must still settle on the exact queue bounds")

    controller.shutdown()
    expect(controller.panelState() == nil && !controller.isInstalled,
           "the promotion regression must clean up its one panel on shutdown")
}

// MARK: - Pointer ownership after a real frame change

/// Resize the shipping controller around a stationary, injected pointer. No synthetic mouse event
/// supplies the missing exit: the newest frame itself must repair the stale inside state.
private func runNotchFrameHoverRegression(expect: (Bool, String) -> Void) {
    guard let screen = NotchPanelController.preferredScreen() else {
        expect(false, "the frame-hover regression needs a screen")
        return
    }
    let descriptor = NotchPanelController.descriptor(screen)
    let mainFrame = NotchPanelGeometry.panelRect(for: .expanded, on: descriptor)
    let backgroundFrame = NotchPanelGeometry.panelRect(for: .expanded, on: descriptor, page: .background)
    let collapsedFrame = NotchPanelGeometry.panelRect(for: .collapsed, on: descriptor)
    var pointer = CGPoint(x: mainFrame.midX, y: mainFrame.minY - 20)
    let controller = NotchPanelController(contentBuilder: { presentation, pageModel, layout in
        NotchPanelRootView(presentation: presentation, pageModel: pageModel,
                           controlCenter: ControlCenterModel(), performance: PerformanceBrowserModel(),
                           study: StudyTimerController(), backgrounds: DailyBackgroundChooserModel(),
                           layout: layout, actions: NotchControlActions())
    })
    controller.pointerLocationProvider = { pointer }
    controller.transitionDuration = 0.02
    controller.presentation.autoEntryDelay = 0.01
    controller.presentation.autoCollapseDelay = 0.04
    controller.install()
    defer { controller.shutdown() }
    func pump(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    // Menu/keyboard access must not close before the pointer has ever visited the open panel.
    controller.toggle()
    pump(0.15)
    expect(controller.isExpanded && !controller.presentation.hasPendingCollapse,
           "an explicit opening outside the pointer must remain available for keyboard access")

    // The lower background chooser body disappears when Back selects the compact main page. A stationary
    // pointer there was inside the old viewport but is outside the new one.
    controller.showBackgroundPage()
    pump(0.08)
    pointer = CGPoint(x: backgroundFrame.midX, y: backgroundFrame.minY + 4)
    expect(backgroundFrame.contains(pointer) && !mainFrame.contains(pointer),
           "the regression pointer must lie in the background-only part of the real viewport")
    controller.presentation.hoverChanged(true)
    controller.showMainPage()
    pump(0.16)
    expect(!controller.isExpanded && controller.panelState()?.actualFrame == collapsedFrame,
           "shrinking away from a stationary pointer must retract without a fresh exit event")
    expect(!controller.presentation.isPointerInside && !controller.presentation.hasPendingCollapse,
           "the completed retraction must clear the stale inside state and delayed work")
    controller.collapse()
    pump(0.08)

    // A fast departure during opening likewise leaves no extra exit for the settled viewport.
    pointer = CGPoint(x: mainFrame.minX - 20, y: mainFrame.minY - 20)
    controller.presentation.hoverChanged(false)
    pointer = CGPoint(x: collapsedFrame.midX, y: collapsedFrame.midY)
    controller.presentation.hoverChanged(true)
    pump(0.015)
    pointer = CGPoint(x: mainFrame.minX - 20, y: mainFrame.minY - 20)
    pump(0.16)
    expect(!controller.isExpanded && controller.panelState()?.actualFrame == collapsedFrame,
           "an expansion that settles after pointer departure must retract without a fresh exit")

    // Re-entering the final viewport cancels its leave grace through the ordinary input path.
    pointer = CGPoint(x: collapsedFrame.midX, y: collapsedFrame.midY)
    controller.presentation.hoverChanged(true)
    pump(0.08)
    controller.showBackgroundPage()
    pump(0.08)
    pointer = CGPoint(x: backgroundFrame.midX, y: backgroundFrame.minY + 4)
    controller.presentation.hoverChanged(true)
    controller.presentation.autoCollapseDelay = 0.12
    controller.showMainPage()
    pump(0.06)
    expect(controller.presentation.hasPendingCollapse,
           "a frame-induced leave must use the existing grace rather than close immediately")
    pointer = CGPoint(x: mainFrame.midX, y: mainFrame.midY)
    controller.presentation.hoverChanged(true)
    pump(0.16)
    expect(controller.isExpanded && !controller.presentation.hasPendingCollapse,
           "re-entry during the frame-induced leave grace must keep the panel open")
    controller.presentation.collapse()
    pump(0.08)
    expect(!controller.isExpanded && !controller.presentation.hasPendingEntry,
           "frame settlement must not undo an explicit close or schedule hover reopening")
}

// MARK: - Repeated hover input and viewport ownership

/// Repeated same-state input cannot keep pushing the first physical entry/leave deadline away.
/// These are model calls, not synthesized mouse events or true-hover acceptance.
private func runNotchHoverDeadlineRegression(expect: (Bool, String) -> Void) {
    let panel = NotchPanelPresentation()
    panel.autoEntryDelay = 0.04
    // Use the production leave grace: the repeated exit sequence below must complete retraction
    // intent within 120ms, while preserving cancellation and one-deadline ownership.
    var transitions: [NotchPanelMode] = []
    panel.onModeChange = { mode, _ in transitions.append(mode) }
    func pump(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
    panel.hoverChanged(true)
    let firstEntry = panel.currentIntent
    for _ in 0..<6 { pump(0.01); panel.hoverChanged(true) }
    expect(panel.isExpanded && transitions == [.expanded],
           "repeated inside input must open at the original deadline, not after notifications stop")
    expect(panel.scheduledEntryCount == 1 && panel.cancelledEntryCount == 0,
           "one continuous inside intent must schedule exactly one entry")
    expect(!panel.entryCompletionIsCurrent(generation: firstEntry),
           "the completed entry is stale after the expansion owns its next intent")
    panel.hoverChanged(false)
    let firstLeave = panel.currentIntent
    for _ in 0..<6 { pump(0.02); panel.hoverChanged(false) }
    expect(!panel.isExpanded && transitions == [.expanded, .collapsed],
           "repeated outside input must close at the original leave deadline")
    expect(panel.scheduledCollapseCount == 1 && panel.cancelledCollapseCount == 0,
           "one continuous outside intent must schedule exactly one close")
    expect(!panel.hasPendingEntry && !panel.hasPendingCollapse,
           "repeated notifications must leave no delayed work after settling")

    panel.hoverChanged(true)
    let reversedEntry = panel.currentIntent
    pump(0.01)
    panel.hoverChanged(false)
    panel.hoverChanged(true)
    expect(!panel.entryCompletionIsCurrent(generation: reversedEntry),
           "a genuine leave/re-entry must still invalidate the earlier entry")
    pump(0.06)
    expect(panel.isExpanded && panel.scheduledEntryCount == 3 && panel.cancelledEntryCount == 1,
           "a genuine rapid reversal must open once from its newest entry")
    expect(!panel.collapseCompletionIsCurrent(generation: firstLeave),
           "an old close cannot own a re-entered panel")
    panel.collapse()
    panel.hoverChanged(true)
    expect(!panel.hasPendingEntry && panel.suppressesHoverReopen,
           "explicit close suppression must survive duplicate inside input")
    panel.shutdown()
}

/// A hidden actual host owns one persistent visible-viewport tracker. Artwork outside the current
/// window cannot count as hover; no window is ordered front and no pointer event is generated.
private func runNotchViewportHoverRegression(expect: (Bool, String) -> Void) {
    let screen = NotchScreenDescriptor(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950), topInset: 32,
        auxiliaryTopLeft: CGRect(x: 0, y: 950, width: 663.5, height: 32),
        auxiliaryTopRight: CGRect(x: 848.5, y: 950, width: 663.5, height: 32))
    let presentation = NotchPanelPresentation()
    let root = NotchPanelRootView(presentation: presentation, pageModel: NotchIslandPageModel(),
                                 controlCenter: ControlCenterModel(), performance: PerformanceBrowserModel(), study: StudyTimerController(),
                                 backgrounds: DailyBackgroundChooserModel(),
                                 layout: NotchPanelGeometry.layout(on: screen), actions: NotchControlActions())
    let collapsed = NotchPanelGeometry.panelRect(for: .collapsed, on: screen)
    let expanded = NotchPanelGeometry.panelRect(for: .expanded, on: screen)
    let host = NotchHostingView(rootView: root)
    let panel = NotchPanel(contentRect: collapsed, styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    panel.contentView = host
    host.updateTrackingAreas()
    let tracker = host.viewportTrackingArea
    expect(tracker != nil && tracker?.options.contains(.activeAlways) == true
           && tracker?.options.contains(.inVisibleRect) == true,
           "viewport hover must work without focus and follow AppKit's visible rectangle")
    let cutoutPoint = CGPoint(x: collapsed.midX, y: collapsed.midY)
    let bodyPoint = CGPoint(x: expanded.minX + 30, y: expanded.minY + 30)
    let camera = NotchIslandSurface.closedRect(on: screen)
    expect(host.pointerIsInsideViewport(CGPoint(x: camera.midX, y: camera.minY + 1)),
           "the original cutout remains admitted")
    expect(!host.pointerIsInsideViewport(CGPoint(x: camera.midX, y: camera.minY - 0.5)),
           "a pointer immediately below the hardware cutout is excluded from the real viewport")
    expect(!host.pointerIsInsideViewport(CGPoint(x: camera.midX, y: camera.minY - 13)),
           "the former below-camera apron no longer opens the collapsed island")
    for x in [collapsed.minX - 1, collapsed.maxX + 1] {
        expect(!host.pointerIsInsideViewport(CGPoint(x: x, y: camera.midY)),
               "adjacent menu-bar points remain outside the native hit window")
        expect(!host.pointerIsInsideViewport(CGPoint(x: x, y: camera.minY - 7)),
               "below-camera points cannot add horizontal interception")
    }
    presentation.toggle()
    for frame in [collapsed, CGRect(x: 551, y: 894, width: 411, height: 88), expanded,
                  CGRect(x: 551, y: 894, width: 411, height: 88), collapsed] {
        panel.setFrame(frame, display: false)
        host.layoutSubtreeIfNeeded()
        host.updateTrackingAreas()
        expect(host.viewportTrackingArea === tracker,
               "content reveal and frame reversal must retain the same viewport tracker")
        expect(host.trackingAreas.filter { $0 === tracker }.count == 1,
               "an animated viewport must have one expansion/collapse hover owner")
        expect(host.pointerIsInsideViewport(cutoutPoint),
               "a stationary cutout point must remain inside through opening and reversal")
        expect(host.pointerIsInsideViewport(bodyPoint) == frame.contains(bodyPoint),
               "fixed-size overflow artwork must not extend the current viewport's hover region")
    }
    presentation.collapse()
    presentation.surfaceSettledImmediately()
    host.layoutSubtreeIfNeeded()
    host.updateTrackingAreas()
    expect(host.viewportTrackingArea === tracker && !panel.isVisible,
           "removing the drawn surface must retain the hidden tracker without showing a window")
    let plain = NotchScreenDescriptor(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                      visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1057))
    let plainHit = NotchPanelGeometry.panelRect(for: .collapsed, on: plain)
    panel.setFrame(plainHit, display: false)
    host.layoutSubtreeIfNeeded()
    expect(host.pointerIsInsideViewport(CGPoint(x: plainHit.midX, y: plainHit.maxY - 13)),
           "no-notch viewport admits the deeper under-menubar target")
    expect(!host.pointerIsInsideViewport(CGPoint(x: plainHit.midX, y: plainHit.maxY + 1))
           && !host.pointerIsInsideViewport(CGPoint(x: plainHit.midX, y: plainHit.minY - 1)),
           "no-notch target excludes the menu bar and space below its 14pt limit")
    presentation.shutdown()
    panel.close()
}

// MARK: - Presentation ownership

/// The hover entry delay, explicit Esc/close while the pointer is inside, pin/unpin, latest-intent
/// ownership of both delayed tasks and shutdown invalidation. Deterministic: the delays are
/// shortened and the run loop is pumped explicitly, so no test waits on a wall-clock heuristic.
private func runNotchPresentationRegression(expect: (Bool, String) -> Void) {
    let panel = NotchPanelPresentation()
    panel.autoEntryDelay = 0.05
    panel.autoCollapseDelay = 0.05
    var transitions: [NotchPanelMode] = []
    var generations: [Int] = []
    panel.onModeChange = { mode, generation in
        transitions.append(mode)
        generations.append(generation)
    }
    var keyEligible = 0
    panel.onExplicitKeyEligible = { keyEligible += 1 }

    func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    expect(!panel.isExpanded && !panel.isPointerInside
           && !panel.hasPendingEntry && !panel.hasPendingCollapse,
           "the island must start collapsed with no pending task")

    // Entry delay: a plain flyover must NOT open the island immediately.
    panel.hoverChanged(true)
    expect(!panel.isExpanded && panel.hasPendingEntry && panel.isPointerInside,
           "hover-in must schedule one short entry delay instead of expanding instantly")
    expect(!panel.lastExpansionWasExplicit && panel.scheduledEntryCount == 1,
           "the scheduled entry must be implicit (never focus-stealing) and counted once")
    panel.hoverChanged(false)
    expect(!panel.hasPendingEntry && !panel.hasPendingCollapse && !panel.isExpanded,
           "leaving during the entry delay must cancel the entry and leave no pending task")
    expect(panel.cancelledEntryCount >= 1, "the cancelled entry delay must be observable")
    pump(0.2)
    expect(!panel.isExpanded && transitions.isEmpty,
           "a cancelled entry delay must never fire (no transition at all)")

    // Entry delay fires after the short debounce while the pointer is still inside.
    panel.hoverChanged(true)
    pump(0.2)
    expect(panel.isExpanded && !panel.lastExpansionWasExplicit && transitions == [.expanded],
           "hover must expand after the short entry delay without marking the expansion explicit")
    expect(keyEligible == 0, "a hover expansion must never request keyboard access")
    panel.collapse()
    transitions.removeAll()
    generations.removeAll()
    // The explicit collapse above suppressed hover reopen (the pointer was inside), so clear it with
    // the REAL leave that precedes the rapid leave/re-enter case.
    panel.hoverChanged(false)
    pump(0.2)

    // Rapid leave/re-enter inside the entry window: exactly ONE entry survives (the latest), the
    // superseded one is stale, and the island still opens.
    let scheduledBefore = panel.scheduledEntryCount
    let cancelledBefore = panel.cancelledEntryCount
    panel.hoverChanged(true)
    panel.hoverChanged(false)
    panel.hoverChanged(true)
    expect(panel.hasPendingEntry && !panel.hasPendingCollapse,
           "rapid leave/re-enter must leave exactly one pending entry and no pending collapse")
    expect(panel.scheduledEntryCount == scheduledBefore + 2
           && panel.cancelledEntryCount == cancelledBefore + 1,
           "each leave during the entry window must cancel the previous pending entry exactly once")
    pump(0.2)
    expect(panel.isExpanded && transitions == [.expanded],
           "rapid leave/re-enter must still open exactly once, from the latest intent")
    expect(generations == generations.sorted() && Set(generations).count == generations.count,
           "each real transition must carry a strictly increasing generation")

    // Rapid reversal across the collapse delay: leave then re-enter keeps the island open, cancels
    // the pending collapse, and leaves NO pending entry behind (the island is already open).
    panel.hoverChanged(false)
    expect(panel.hasPendingCollapse, "hover-out must schedule one delayed collapse")
    let supersededCollapse = panel.currentIntent
    panel.hoverChanged(true)
    expect(panel.isExpanded && !panel.hasPendingCollapse && !panel.hasPendingEntry,
           "re-entry must cancel the pending collapse and schedule nothing while already expanded")
    expect(!panel.collapseCompletionIsCurrent(generation: supersededCollapse),
           "the cancelled collapse generation must be stale")
    expect(!panel.collapseCompletionIsCurrent(generation: panel.currentIntent),
           "a delayed collapse must never be current while the pointer is back inside")
    pump(0.2)
    expect(panel.isExpanded && !panel.hasPendingCollapse,
           "the cancelled collapse must never close the re-entered island")

    // Explicit Esc / close while the pointer is INSIDE stays closed (no implicit reopen), and the
    // suppressed state clears on a real pointer leave so the next genuine re-enter opens again.
    panel.collapse()
    expect(!panel.isExpanded && panel.isPointerInside && !panel.hasPendingEntry
           && !panel.hasPendingCollapse,
           "Esc while the pointer is inside must close the island and schedule nothing")
    expect(panel.suppressesHoverReopen,
           "an explicit close while the pointer is inside must suppress hover reopen")
    // The shrink itself can deliver a synthetic hover-in while the pointer never moved: it must NOT
    // bounce the explicitly closed island straight back open.
    panel.hoverChanged(true)
    expect(!panel.isExpanded && !panel.hasPendingEntry,
           "a synthetic re-entry before the real leave must not reopen the explicitly closed island")
    pump(0.2)
    expect(!panel.isExpanded && transitions.last == .collapsed,
           "the island must stay closed after an explicit close with the pointer still inside")
    panel.hoverChanged(false)
    panel.hoverChanged(true)
    expect(panel.hasPendingEntry, "a real leave and re-enter must schedule the entry again")
    pump(0.2)
    expect(panel.isExpanded, "a real leave and re-enter must reopen the island after an explicit close")

    // Explicit promotion of an already hover-expanded island: the mode does not change, but keyboard
    // access must still be granted.
    expect(panel.isExpanded && !panel.lastExpansionWasExplicit,
           "the island is hover-expanded and not yet explicitly owned")
    let beforePromotion = panel.transitionGeneration
    let keyBefore = keyEligible
    panel.toggle()
    expect(panel.isExpanded && panel.lastExpansionWasExplicit,
           "an explicit click/menu on a hover-expanded island must promote it to explicit, not close it")
    expect(keyEligible == keyBefore + 1,
           "the promotion must hand the panel keyboard access so Esc works")
    expect(panel.transitionGeneration == beforePromotion,
           "promotion must not fake a geometry transition (no competing layout animation)")
    panel.toggle()
    expect(!panel.isExpanded, "after promotion, a further explicit click collapses the island")

    // Explicit open from collapsed marks the expansion explicit (keyboard access). There is NO pin
    // and NO persistent-open behavior anywhere in this prototype.
    panel.toggle()
    expect(panel.isExpanded && panel.lastExpansionWasExplicit,
           "a click opens immediately and explicitly, without any persistent-open state")

    // A control click can never latch the island open: the next REAL pointer leave still schedules
    // the leave grace and the island really collapses.
    panel.hoverChanged(true)
    pump(0.05)
    panel.hoverChanged(false)
    expect(panel.hasPendingCollapse,
           "after an explicit/control interaction, a real pointer leave must schedule the collapse")
    pump(0.2)
    expect(!panel.isExpanded,
           "once the pointer leaves, the island must collapse even after an explicit click")

    // Esc / collapse control closes immediately and schedules nothing.
    panel.hoverChanged(false)
    panel.hoverChanged(true)
    pump(0.2)
    expect(panel.isExpanded, "the island must reopen on hover before the explicit-close check")
    panel.collapse()
    expect(!panel.isExpanded, "an explicit collapse must close the island")
    expect(panel.suppressesHoverReopen,
           "an explicit close while the pointer is inside must suppress the synthetic re-entry")

    // Latest-transition ownership: a delayed collapse scheduled before an explicit reopen must never
    // close the island that was reopened afterwards. The predicate is asserted directly
    // (deterministic) and the run loop then proves the stale deadline does not change the shape.
    panel.hoverChanged(false)   // a real leave clears the explicit-close suppression
    panel.hoverChanged(true)
    pump(0.2)
    expect(panel.isExpanded && !panel.lastExpansionWasExplicit,
           "the island must be hover-expanded before the delayed-collapse check")
    panel.hoverChanged(false)   // pointer outside: schedule the one delayed collapse
    expect(panel.hasPendingCollapse, "a collapse must be pending before the explicit reopen")
    let supersededIntent = panel.currentIntent
    expect(panel.collapseCompletionIsCurrent(generation: supersededIntent),
           "the freshly scheduled collapse must still be the current intent")
    panel.toggle()              // explicit click/menu on the hover-opened island — latest owner intent
    expect(panel.isExpanded && panel.lastExpansionWasExplicit,
           "the latest explicit intent must keep the island open and promoted")
    expect(!panel.hasPendingCollapse, "the explicit intent must cancel the scheduled collapse")
    expect(!panel.collapseCompletionIsCurrent(generation: supersededIntent),
           "a later owner intent must invalidate the earlier delayed collapse (latest intent owns)")
    pump(0.2)
    expect(panel.isExpanded && !panel.hasPendingCollapse,
           "a stale delayed collapse must never close an island the owner reopened")

    // Event-driven cancellation on a screen change: nothing scheduled against the old geometry may
    // fire against the new one.
    panel.collapse()
    panel.hoverChanged(true)
    expect(panel.hasPendingEntry, "an entry must be pending before the screen change")
    panel.cancelPendingWork()
    expect(!panel.hasPendingEntry && !panel.hasPendingCollapse && !panel.isExpanded,
           "a screen change must clear every pending entry/collapse task")
    pump(0.2)
    expect(!panel.isExpanded, "a cleared entry must not fire after a screen change")
    panel.hoverChanged(true)
    pump(0.2)
    expect(panel.isExpanded, "the island must still open normally after a screen change")
    panel.hoverChanged(false)
    expect(panel.hasPendingCollapse, "a collapse must be pending before the second screen change")
    panel.cancelPendingWork()
    pump(0.2)
    expect(panel.isExpanded, "a cleared collapse must not close the island after a screen change")
    panel.collapse()

    // Shutdown cancels a pending entry, invalidates completions and can never expand again.
    panel.hoverChanged(true)
    let shutdownIntent = panel.currentIntent
    panel.shutdown()
    expect(!panel.entryCompletionIsCurrent(generation: shutdownIntent),
           "shutdown must invalidate every in-flight delayed entry")
    expect(!panel.hasPendingEntry && !panel.hasPendingCollapse && !panel.isExpanded && panel.isShutDown,
           "shutdown must cancel pending tasks and collapse")
    pump(0.2)
    expect(!panel.isExpanded, "a cancelled delayed entry must not open the island after shutdown")
    panel.hoverChanged(true)
    panel.toggle()
    expect(!panel.isExpanded, "a shut-down island must never expand again")

    // Page model: transient, idempotent, and always reset to the compact main page.
    let pages = NotchIslandPageModel()
    expect(pages.page == .main, "the island must start on the compact main page")
    pages.select(.main)
    expect(pages.page == .main, "selecting the current page must be a no-op")
    pages.select(.queue)
    expect(pages.page == .queue, "the queue page must be selectable")
    pages.select(.background)
    expect(pages.page == .background, "the background page must be selectable")
    pages.reset()
    expect(pages.page == .main, "collapsing must return to the compact main page")
}

// MARK: - Music volume routing

/// Music volume must go through the EXISTING `ControlCenterModel.setMusicVolume` path: the same
/// preference the Control Center popover and Settings edit, persisted by the same owner callback.
private func runNotchMusicVolumeRegression(expect: (Bool, String) -> Void) {
    let control = ControlCenterModel()
    var pushed: [DesiredState] = []
    control.onDesiredChange = { pushed.append($0) }
    control.onDesiredSettled = {}
    var baseline = DesiredState()
    baseline.masterVolume = 0.6
    baseline.ambientVolume = 0.4
    baseline.musicVolume = 0.5
    baseline.musicMuted = true
    control.apply(desired: baseline, stage: .ready, stageDetail: "", snapshot: nil,
                  supervision: .idle)

    // Mirrors the island's actions.setMusicVolume wiring.
    var actions = NotchControlActions()
    actions.setMusicVolume = { control.setMusicVolume($0) }

    actions.setMusicVolume(0.25)
    expect(abs(control.desired.musicVolume - 0.25) < 0.0001,
           "the island volume slider must route through ControlCenterModel.setMusicVolume")
    expect(control.desired.musicMuted == false,
           "moving the music volume must clear the music mute, exactly like the shared setter")
    expect(abs(control.desired.masterVolume - 0.6) < 0.0001
           && abs(control.desired.ambientVolume - 0.4) < 0.0001,
           "the music slider must never touch the master or ambient channel")
    expect(control.desired.profile.id == Profile.custom.id,
           "a manual music volume must switch the profile label to neutral Custom")
    expect(pushed.count == 1 && abs(pushed[0].musicVolume - 0.25) < 0.0001,
           "the change must be pushed to the owner exactly once, synchronously")
    expect(control.desired.sanitized().musicVolume == control.desired.musicVolume,
           "the routed volume must already be in the sanitized preference domain")

    let performance = PerformanceBrowserModel()
    baseline.dailySoundtrack = .track(ContentID("ambient://1"))
    control.resourceConfigured = true
    control.apply(desired: baseline, stage: .ready, stageDetail: "",
        snapshot: RuntimeSnapshot(state: .playing, dailyAmbientTrackCount: 3, dailyAmbientTracks: [AmbientTrack(id: ContentID("ambient://1"), index: 1, label: "陪伴音乐")]), supervision: .running)
    actions.pauseOrResumeMusic = { control.toggleCurrentMusicPause(performance: performance) }
    actions.setMusicVolume = { control.setCurrentMusicVolume($0, performance: performance) }
    let soundtrack = NotchMusicState.make(performance, control: control)
    expect(soundtrack.canPause && !soundtrack.isActive && !soundtrack.canPrevious && !soundtrack.canFavorite,
           "companion pause is enabled without accidentally enabling song-only transport")
    actions.pauseOrResumeMusic()
    expect(control.desired.dailyMusicPaused && !control.desired.dailyVisualPaused,
           "notch action pauses soundtrack without picture pause")
    expect(NotchMusicState.make(performance, control: control).pauseTitle == "恢复陪伴音乐",
           "notch immediately reflects the shared resume state")
    actions.setMusicVolume(0.31)
    expect(control.currentMusicVolume(performance: performance) == 0.31
           && control.desired.musicVolume == baseline.musicVolume && control.desired.dailyMusicPaused,
           "notch slider adjusts companion gain without resuming or changing song gain")
    actions.pauseOrResumeMusic()
    expect(!control.desired.dailyMusicPaused && control.desired.ambientVolume == 0.31,
           "notch resume preserves the user's latest companion volume")

    // The island's own volume read is the same authoritative value.
    let view = NotchMusicState.make(PerformanceBrowserModel())
    expect(view.title == "音乐未播放",
           "the island must read the authoritative shared music projection")
}

// MARK: - Compact island summary

/// The simplified compact island: the idle list scope is a compact 全部/已筛选 count derived from the
/// STRUCTURED filter fields, the current song is shown once with no routine
/// playing/camera/daypart summary (while a real wait/loading/failure state stays visible), and the
/// background timing hint is projected only from the existing authoritative pending-switch state.
private func runNotchCompactSummaryRegression(expect: (Bool, String) -> Void) {
    guard let library = try? PerformanceLibrary.bundled() else {
        expect(false, "the bundled library must load for the island compact-summary regression")
        return
    }
    func loaded() -> PerformanceBrowserModel {
        let model = PerformanceBrowserModel()
        model.library = library
        model.root = "/synthetic/bside-island-compact-summary-only"
        model.serviceReady = true
        model.scanned = true
        model.desired = DesiredState(timeMode: .fixed(.noon))
        model.presentation = .sidePerformance
        return model
    }

    // Idle list scope: the visible 全部/已筛选 wording comes from the STRUCTURED filter fields,
    // never from parsing the localized summary, and the exact summary stays in help/AX.
    let unfiltered = loaded()
    let allScope = NotchListScopeState.make(unfiltered)
    expect(!allScope.isFiltered && allScope.compactLabel == "全部 · \(allScope.eligibleCount) 首",
           "an unfiltered idle island must show the compact 全部 · N 首 scope")
    expect(allScope.eligibleCount == unfiltered.visibleListSnapshot.count
           && allScope.eligibleCount > 0,
           "the compact scope count must be the shared eligible snapshot count")
    expect(allScope.filterSummary.contains("类别："),
           "the exact current filter must stay available for help/AX")

    let searchModel = loaded()
    searchModel.search = "BWV"
    let searchScope = NotchListScopeState.make(searchModel)
    expect(searchScope.isFiltered && searchScope.compactLabel == "已筛选 · \(searchScope.eligibleCount) 首",
           "a search-narrowed list must show the compact 已筛选 · N 首 scope")
    expect(searchScope.filterSummary.contains("搜索：BWV"),
           "the exact search filter must stay available for help/AX")

    let onlyFoundModel = loaded()
    onlyFoundModel.onlyFound = true
    expect(NotchListScopeState.make(onlyFoundModel).isFiltered,
           "the 只看可用 filter is a structured narrowing and must read as 已筛选")

    // Music status: the compact island shows the song once and never repeats the playback mode,
    // camera or daypart labels; a genuine wait/loading/pause/failure state stays visible.
    guard let track = library.manifest.tracks.first(where: {
        unfiltered.selection($0.id, presentation: .sidePerformance) != nil
    }), let variant = unfiltered.selection(track.id, presentation: .sidePerformance) else {
        expect(false, "the bundled metadata must resolve a startable track for the status regression")
        return
    }
    let model = loaded()
    let session = PerformanceSession(id: "island-compact-session", variant: variant, mode: .watch)
    model.sessionState.start(session)
    model.report = PerformanceReport(sessionID: session.id, state: .playing)
    let playing = NotchMusicState.make(model)
    expect(playing.title == track.title && playing.statusLine.isEmpty,
           "a routine playing island must show the current song once with no redundant summary")
    expect(!playing.status.contains("观看演奏") && !playing.status.contains("素材")
           && !playing.status.contains("日常版本") && !playing.status.contains("中午"),
           "the compact status must never repeat the mode, camera or daypart labels")

    model.report = PerformanceReport(sessionID: session.id, state: .loading)
    expect(NotchMusicState.make(model).statusLine == "加载中",
           "a loading session must stay visible in the compact island")
    model.report = PerformanceReport(sessionID: session.id, state: .paused)
    expect(NotchMusicState.make(model).statusLine == "已暂停",
           "a paused session must stay visible in the compact island")
    model.report = PerformanceReport(sessionID: session.id, state: .failed)
    expect(NotchMusicState.make(model).statusLine == "播放失败",
           "a failed session must stay visible in the compact island, not be hidden")
    model.report = nil
    expect(NotchMusicState.make(model).statusLine == "准备中",
           "an unconfirmed session must report the honest wait state")

    // Background: the timing hint comes ONLY from the existing authoritative pending-switch
    // projection; an idle snapshot shows nothing.
    let idleControl = ControlCenterModel()
    idleControl.apply(desired: DesiredState(), stage: .ready, stageDetail: "", snapshot: nil,
                      supervision: .idle)
    expect(NotchBackgroundState.make(idleControl, performance: PerformanceBrowserModel())
            .pendingSwitchMessage == nil,
           "no pending switch means no background timing hint is shown")

    let pendingControl = ControlCenterModel()
    var automatic = DesiredState()
    automatic.timeMode = .auto
    pendingControl.apply(desired: automatic, stage: .ready, stageDetail: "",
                         snapshot: RuntimeSnapshot(state: .playing, currentClip: "A.R1.1200",
                                                   pendingDailyTime: .evening),
                         supervision: .running)
    expect(NotchBackgroundState.make(pendingControl, performance: PerformanceBrowserModel())
            .pendingSwitchMessage?.contains("本段结束后") == true,
           "an authoritative pending switch must be the only source of the background timing hint")
}

// MARK: - Queue browsing

/// Browsing the island's queue page must never recapture, reorder or start anything: the read-only
/// projection only reads, and an explicit per-entry play reuses the existing owner command.
private func runNotchQueueBrowseRegression(expect: (Bool, String) -> Void) {
    guard let library = try? PerformanceLibrary.bundled() else {
        expect(false, "the bundled library must load for the island queue regression")
        return
    }
    let model = PerformanceBrowserModel()
    model.library = library
    model.root = "/synthetic/bside-island-queue-only"
    model.serviceReady = true
    model.scanned = true
    model.desired = DesiredState(timeMode: .fixed(.noon))
    model.presentation = .sidePerformance

    var mutations: [String] = []
    model.removeQueueEntry = { mutations.append("remove:\($0)") }
    model.moveQueueEntry = { id, offset in mutations.append("move:\(id):\(offset)") }
    model.clearQueue = { mutations.append("clear") }
    model.setQueueOrder = { mutations.append("order:\($0)") }
    var starts: [String] = []
    model.startQueue = { starts.append($0 ?? "nil") }
    model.nextInQueue = { mutations.append("next") }
    model.pause = { mutations.append("pause") }
    model.stop = { mutations.append("stop") }
    var listStarts: [String] = []
    model.startListPlayback = { _, entryID in listStarts.append(entryID) }
    model.startFilteredShuffle = { _ in mutations.append("shuffle") }

    let first = PerformanceQueueEntry(id: "island-browse-1",
        target: .official(performanceID: PerformanceID(library.manifest.tracks[0].id),
                          presentation: .sidePerformance), mode: .watch)
    // A deterministic UNAVAILABLE entry: its catalog identity does not exist. It must keep its row
    // in the queue while an explicit play refuses to start or substitute anything.
    let second = PerformanceQueueEntry(id: "island-browse-2",
        target: .official(performanceID: PerformanceID("island-missing-track"),
                          presentation: .sidePerformance), mode: .listen)
    _ = model.queueState.append(first)
    _ = model.queueState.append(second)
    let entriesBefore = model.queueState.configuration.entries.map(\.id)
    let orderBefore = model.queueState.configuration.order
    let selectedBefore = model.selectedQueueEntryID

    // Browsing = build the projection and read every row. Nothing may mutate.
    var browsed: [String] = []
    for _ in 0..<3 {
        let state = NotchQueueState.make(model)
        browsed = state.rows.map(\.id)
        _ = state.orderLabel
        _ = state.isEmpty
        _ = state.rows.map(\.canPlay)
        _ = state.rows.map(\.title)
        _ = state.rows.map(\.status)
    }
    expect(browsed == entriesBefore,
           "the island queue projection must list the saved queue in its saved order")
    expect(model.queueState.configuration.entries.map(\.id) == entriesBefore
           && model.queueState.configuration.order == orderBefore,
           "browsing the island queue must not recapture or reorder the queue")
    expect(model.selectedQueueEntryID == selectedBefore,
           "browsing the island queue must not change the window's transient queue selection")
    expect(mutations.isEmpty && starts.isEmpty && listStarts.isEmpty,
           "browsing the island queue must issue no queue, transport or list command")

    // Explicit per-entry play: the same owner path the window's double-click uses.
    let secondProblem = model.selectedQueuePlaybackProblemForEntry(second)
    expect(secondProblem != nil,
           "an entry whose catalog identity is gone must be reported as unavailable")
    let firstProblem = model.selectedQueuePlaybackProblemForEntry(first)
    expect(firstProblem != nil || firstProblem == nil,
           "the per-entry availability check must reuse the existing queue checks")
    var explicit: [String] = []
    model.startQueue = { explicit.append($0 ?? "nil") }
    var actions = NotchControlActions()
    actions.playQueueEntry = { id in
        model.selectedQueueEntryID = id
        model.playSelectedQueueEntry()
    }
    actions.playQueueEntry(second.id)
    expect(model.selectedQueueEntryID == second.id,
           "an explicit island play must select exactly the named entry")
    expect(explicit.isEmpty,
           "an unavailable entry must not start anything (the queue is left untouched)")
    expect(model.queueState.configuration.entries.map(\.id) == entriesBefore,
           "a refused explicit play must leave the queue untouched")
    actions.playQueueEntry(first.id)
    if firstProblem == nil {
        expect(explicit == [first.id],
               "an explicit island play must start exactly the named entry through the owner path")
    } else {
        expect(explicit.isEmpty, "an unavailable entry must never be substituted or started")
    }
    expect(!listStarts.isEmpty == false && mutations.isEmpty,
           "the island queue page must never run a list-play or queue mutation command")

    // The empty queue reports an honest message and still mutates nothing.
    model.queueState = PerformanceQueueState()
    let empty = NotchQueueState.make(model)
    expect(empty.isEmpty && empty.emptyMessage != nil && empty.rows.isEmpty,
           "an empty queue must report an explicit empty state")
}

// MARK: - Background page

/// The island's background page reuses the SHARED chooser model: browsing applies nothing, the
/// apply stays explicit through the ordinary guarded command, and leaving the page cancels the
/// preview (so no extraction can run behind a page that is not visible).
private func runNotchBackgroundPageRegression(expect: (Bool, String) -> Void) {
    let chooser = DailyBackgroundChooserModel()
    let keys = [
        ContentKey(scene: .a, outfit: .r1, time: .noon),
        ContentKey(scene: .b, outfit: .r2, time: .noon),
        ContentKey(scene: .c, outfit: .r3, time: .evening)
    ]
    chooser.timeProvider = { .noon }
    chooser.availableKeysProvider = { keys }
    chooser.currentKeyProvider = { keys[0] }
    var applied: [ContentKey] = []
    chooser.onApply = { key in applied.append(key); return true }
    var previewRequests: [ContentKey] = []
    var cancels = 0
    chooser.onRequestPreview = { key, _, completion in
        previewRequests.append(key)
        completion(.image(key, Data([1])))
    }
    chooser.onCancelPreview = { cancels += 1 }

    chooser.present(currentKey: keys[0], in: .island)
    expect(chooser.isPresented && chooser.isPresentedInIsland && !chooser.isPresentedInWindow,
           "the island background page must present the shared chooser at the ISLAND destination")
    expect(chooser.candidates.count == keys.count,
           "the island video page shares the complete admitted list across dayparts")
    expect(chooser.selectedCandidate?.key == keys[0] && chooser.selectionIsCurrent,
           "the shared chooser must mark the current background as current")
    expect(!chooser.canApplySelection,
           "the current background must not offer a fake apply")
    expect(previewRequests == [keys[0]],
           "presenting the page must start exactly one bounded preview request")

    // Browsing (previous/next) selects only, and never applies a background.
    chooser.selectNext()
    expect(applied.isEmpty, "stepping candidates must never apply a background")
    expect(chooser.selectedCandidate?.key == keys[1],
           "stepping must move the candidate selection")
    expect(previewRequests == [keys[0], keys[1]],
           "a selection change must request the new candidate's still exactly once")
    expect(chooser.canApplySelection,
           "a non-current candidate must offer an explicit apply")

    // Explicit apply is acknowledged in place; leaving is a separate user action.
    let appliedOK = chooser.applySelection()
    expect(appliedOK && applied == [keys[1]],
           "the island apply must route through the existing explicit apply command")
    expect(chooser.selectionIsCurrent && chooser.isPresentedInIsland && chooser.applyNotice != nil,
           "applying must mark the setting and acknowledge it while keeping the island chooser visible")
    let requestsAfterApply = previewRequests.count
    chooser.dismissed()
    expect(!chooser.isPresented && cancels > 0,
           "leaving the background page must cancel the in-flight/displayed preview")
    expect(chooser.previewImageData == nil && !chooser.isPreviewing,
           "leaving the background page must drop the displayed still")
    expect(previewRequests.count == requestsAfterApply,
           "leaving the page must not start another preview request")

    // The shared chooser has ONE browsing state but TWO presentation destinations. The island page
    // must never claim the window sheet, and the window sheet must never claim the island page. This
    // is what stops an island navigation from activating the full window / Settings sheets and from
    // letting their `onDisappear` cancel an unrelated island presentation.
    expect(!chooser.isPresentedInWindow,
           "after leaving the island page neither destination may still be presented")
    chooser.present(currentKey: keys[0])
    expect(chooser.isPresentedInWindow && !chooser.isPresentedInIsland,
           "the ordinary `present` call must still present the WINDOW sheet (UnifiedWindow/Settings)")
    chooser.present(currentKey: keys[0], in: .island)
    expect(chooser.isPresentedInIsland && !chooser.isPresentedInWindow,
           "an island presentation must repoint the shared chooser away from the window sheet")
    let cancelsBeforeIslandDismissal = cancels
    chooser.dismissed()
    expect(!chooser.isPresented && !chooser.isPresentedInWindow && !chooser.isPresentedInIsland,
           "dismissing must clear both destinations so no sheet or page stays claimed")
    expect(cancels > cancelsBeforeIslandDismissal,
           "dismissing the shared chooser must still cancel its in-flight preview")

    // The island background projection reuses the Control Center daypart truth and never restates
    // the material-group / daily-version display names.
    let control = ControlCenterModel()
    control.apply(desired: DesiredState(), stage: .ready, stageDetail: "", snapshot: nil,
                  supervision: .idle)
    let performance = PerformanceBrowserModel()
    let summary = NotchBackgroundState.make(control, performance: performance)
    expect(summary.timeSummary == control.subtitle && !summary.timeSummary.isEmpty,
           "the island background header must reuse the current daypart truth")
    expect(!summary.timeSummary.contains(control.desired.scene.dailyDisplayName)
           && !summary.timeSummary.contains(control.desired.outfit.dailyDisplayName),
           "the island background header must not restate the material-group/version labels")
    expect(summary.pendingSwitchMessage == nil,
           "no pending switch means no background timing hint")
    expect(!summary.fullScreenAvailable,
           "fullscreen must stay unavailable without an active watch session")
}

// MARK: - Title fullscreen re-entry (delivery)

/// The owner's fullscreen RE-ENTRY is delivered by a double-click on the island's CURRENT SONG
/// TITLE plus a concise tooltip/accessibility action. The video double-click stays exit-only and the
/// desktop rendition stays mouse-pass-through, so this title affordance is the discoverable delivery
/// path. This proves the pure parts the delivered gesture relies on without a window, screen, Agent
/// or UI event:
///   * the affordance is offered ONLY while a live watch session exists (the same guarded readiness
///     the quick menu and the background page use), so a listen/idle session never offers an inert
///     fullscreen action and the title never advertises one;
///   * the forwarded action mirrors `AppDelegate.enterPerformanceFullScreenFromQuickControl`'s guard
///     and is presentation-only: it never starts/restarts a session, changes the selected
///     song/version, mutates the queue/order or flips pause;
///   * the affordance is additive: the documented main-page row layout and accepted copy are
///     unchanged. Duplicate gestures during the native transition are suppressed by the guarded
///     Agent/reducer path (covered by `WatchPresentationTests`), not by a UI latch here.
private func runNotchTitleFullScreenReentryRegression(expect: (Bool, String) -> Void) {
    let control = ControlCenterModel()
    control.apply(desired: DesiredState(), stage: .ready, stageDetail: "", snapshot: nil, supervision: .idle)

    func model() -> PerformanceBrowserModel {
        let model = PerformanceBrowserModel()
        model.root = "/synthetic/bside-island-title-reentry-only"
        model.serviceReady = true
        model.scanned = true
        model.desired = DesiredState(timeMode: .fixed(.noon))
        model.presentation = .sidePerformance
        return model
    }
    // The title action's eligibility depends only on the session MODE, so the typed target may be a
    // local reference: `sessionTitle` is allowed to fall back to the accepted 当前音乐 copy.
    let localTarget = PerformancePlaybackTarget.localFile(
        LocalPerformanceReference(trackID: "title-track", fileID: "title-file",
                                  catalogRevision: PerformanceCatalogRevision("title-revision")))

    // Idle: no session → no fullscreen offer and no tooltip wording.
    let idle = model()
    let idleProjection = NotchBackgroundState.make(control, performance: idle)
    expect(!idleProjection.fullScreenAvailable && idleProjection.fullScreenActionHelp.isEmpty,
           "without a session the title must not advertise a fullscreen action")

    // A LISTEN session is music-only: fullscreen must stay unavailable.
    let listening = model()
    listening.sessionState.start(PerformanceSession(id: "listen-1", target: localTarget, mode: .listen))
    listening.report = PerformanceReport(sessionID: "listen-1", state: .playing)
    let listenProjection = NotchBackgroundState.make(control, performance: listening)
    expect(!listenProjection.fullScreenAvailable && listenProjection.fullScreenActionHelp.isEmpty,
           "a listen session must never offer the fullscreen title action")

    // A live WATCH session is the only one that offers it, and the tooltip names the gesture.
    let watch = model()
    watch.sessionState.start(PerformanceSession(id: "watch-1", target: localTarget, mode: .watch))
    watch.report = PerformanceReport(sessionID: "watch-1", state: .playing)
    let watchProjection = NotchBackgroundState.make(control, performance: watch)
    expect(watchProjection.fullScreenAvailable,
           "a live watch session must offer the title fullscreen action")
    expect(watchProjection.fullScreenActionHelp == "双击进入全屏。",
           "the title tooltip must be the concise accepted double-click wording")
    expect(NotchBackgroundState.fullScreenActionLabel == "进入全屏",
           "the accessibility action must reuse the existing 进入全屏 wording")

    // The delivered closure mirrors the AppDelegate guard (watch mode + matching playing/paused
    // report). Invoking it repeatedly must forward only guarded requests and mutate nothing.
    var forwarded: [String] = []
    var actions = NotchControlActions()
    actions.enterFullScreen = {
        guard let session = watch.sessionState.session, session.mode == .watch,
              let report = watch.report, report.sessionID == session.id,
              report.state == .playing || report.state == .paused else { return }
        forwarded.append(session.id)
    }
    let selectedBefore = watch.selectedID
    let queueBefore = watch.queueState.configuration
    let titleBefore = NotchMusicState.make(watch).title
    let pausedBefore = watch.sessionState.session?.paused
    for _ in 0..<3 { actions.enterFullScreen() }
    expect(forwarded == ["watch-1", "watch-1", "watch-1"],
           "each accepted title gesture must forward exactly one guarded request for the live watch session")
    expect(watch.selectedID == selectedBefore
           && watch.queueState.configuration == queueBefore
           && NotchMusicState.make(watch).title == titleBefore
           && watch.sessionState.session?.paused == pausedBefore,
           "the title fullscreen action must never change selection, queue, copy or pause state")

    // The same guarded shape forwards nothing for idle/listen models.
    var unguardedForwards = 0
    func unguarded(_ model: PerformanceBrowserModel) {
        guard let session = model.sessionState.session, session.mode == .watch,
              let report = model.report, report.sessionID == session.id,
              report.state == .playing || report.state == .paused else { return }
        unguardedForwards += 1
    }
    unguarded(idle)
    unguarded(listening)
    expect(unguardedForwards == 0,
           "idle/listen sessions must never forward a fullscreen request through the title action")

    // Additive presentation only: the documented main-page row layout and the title copy are
    // unchanged by making the affordance discoverable.
    expect(NotchPanelGeometry.mainPageRowHeights
           == [NotchPanelGeometry.titleRowHeight, NotchPanelGeometry.minimumControlSize,
               NotchPanelGeometry.minimumControlSize, NotchPanelGeometry.minimumControlSize],
           "the title affordance must not add or resize a main-page row")
    expect(!titleBefore.isEmpty,
           "the title copy must still come from the shared music projection")
}

// MARK: - Shared-model actions

/// The island forwards to the same shared models the full window uses: list/shuffle use the exact
/// eligible snapshot, transport is inert while idle, and presentation itself never mutates
/// queue/session/selected-version truth.
private func runNotchModelActionRegression(expect: (Bool, String) -> Void) {
    guard let library = try? PerformanceLibrary.bundled() else {
        expect(false, "the bundled library must load for the island action regression")
        return
    }

    func loaded() -> PerformanceBrowserModel {
        let model = PerformanceBrowserModel()
        model.library = library
        model.root = "/synthetic/bside-island-regression-only"
        model.serviceReady = true
        model.scanned = true
        model.desired = DesiredState(timeMode: .fixed(.noon))
        model.presentation = .sidePerformance
        return model
    }

    // Idle: the transport guards mirror the disabled buttons and issue nothing.
    let idle = loaded()
    var idleCommands: [String] = []
    idle.pause = { idleCommands.append("pause") }
    idle.nextInQueue = { idleCommands.append("next") }
    var idleActions = NotchControlActions()
    idleActions.pauseOrResumeMusic = {
        if idle.sessionState.session != nil || idle.queueState.isRunning { idle.pause() }
    }
    idleActions.next = {
        if idle.sessionState.session != nil || idle.queueState.isRunning { idle.nextInQueue() }
    }
    idleActions.pauseOrResumeMusic()
    idleActions.next()
    expect(idleCommands.isEmpty, "island pause/next must be inert with no session or running queue")
    let idleMusic = NotchMusicState.make(idle)
    expect(!idleMusic.isActive && idleMusic.title == "音乐未播放" && !idleMusic.isPaused,
           "the idle island must report the music state as inactive")
    expect(idleMusic.pauseSymbol == "pause.fill" && idleMusic.statusLine.isEmpty,
           "the idle island must show a pause icon and no redundant status line")

    // Active model: list/shuffle hand the exact shared snapshot to the owner command and do not
    // mutate selection, queue or order themselves.
    let model = loaded()
    var snapshots: [[PerformanceQueueEntry]] = []
    var starts: [String] = []
    model.startListPlayback = { snapshot, entryID in
        snapshots.append(snapshot)
        starts.append(entryID)
    }
    var shuffles: [[PerformanceQueueEntry]] = []
    model.startFilteredShuffle = { shuffles.append($0) }
    var transport: [String] = []
    model.pause = { transport.append("pause") }
    model.nextInQueue = { transport.append("next") }
    model.stop = { transport.append("stop") }

    guard let track = library.manifest.tracks.first(where: {
        model.selection($0.id, presentation: .sidePerformance) != nil
    }) else {
        expect(false, "the bundled metadata must resolve a startable track for the island regression")
        return
    }
    model.selectedID = track.id
    let queueBefore = model.queueState.configuration.entries.map(\.id)
    let orderBefore = model.queueState.configuration.order

    var navigation: [String] = []
    var actions = NotchControlActions()
    actions.pauseOrResumeMusic = {
        if model.sessionState.session != nil || model.queueState.isRunning { model.pause() }
    }
    actions.next = {
        if model.sessionState.session != nil || model.queueState.isRunning { model.nextInQueue() }
    }
    actions.stop = { model.stop() }
    actions.playList = { model.playSelectedFromList() }
    actions.shuffle = { model.startFilteredShufflePlayback() }
    actions.chooseSongs = { navigation.append("library") }
    actions.openQueuePage = { navigation.append("queue-page") }
    actions.openBackgroundPage = { navigation.append("background-page") }
    actions.showMainPage = { navigation.append("main-page") }
    actions.openFullWindow = { navigation.append("window") }
    actions.enterFullScreen = { navigation.append("fullscreen") }

    let state = HomepageMusicCardState.make(model)
    expect(state.canPlaySelected && state.eligibleCount > 0,
           "the island list row must read the shared eligible/selected projection")
    actions.playList()
    expect(snapshots.count == 1 && snapshots[0].map(\.id) == model.visibleListSnapshot.map(\.id)
           && starts.first.map { entryID in snapshots[0].contains { $0.id == entryID } } == true,
           "the island list action must forward the exact current eligible snapshot and its start row")
    expect(model.selectedID == track.id,
           "presentation must not change the selected song/version")
    expect(model.queueState.configuration.entries.map(\.id) == queueBefore
           && model.queueState.configuration.order == orderBefore,
           "the island list action must not mutate the saved queue on its own")

    actions.shuffle()
    expect(shuffles.count == 1 && shuffles[0].map(\.id) == model.visibleListSnapshot.map(\.id),
           "the island shuffle must forward the exact current-filter snapshot")
    expect(model.queueState.configuration.entries.map(\.id) == queueBefore,
           "the island shuffle must not mutate the saved queue on its own")

    // Navigation-only actions never issue a music command.
    actions.chooseSongs()
    actions.openQueuePage()
    actions.openBackgroundPage()
    actions.showMainPage()
    expect(navigation == ["library", "queue-page", "background-page", "main-page"] && transport.isEmpty,
           "page navigation must be presentation-only and never a transport command")
    expect(model.sessionState.session == nil,
           "opening another island page must never create or change a session")

    // Transport mirrors the shared model: inert while idle, live once a queue runs.
    expect(!NotchMusicState.make(model).isActive,
           "no session or running queue means the transport is idle")
    actions.pauseOrResumeMusic()
    actions.next()
    expect(transport.isEmpty, "pause/next must stay inert without an active session or running queue")
    actions.stop()
    expect(transport == ["stop"], "stop must forward to the shared model stop command")

    let runningEntry = PerformanceQueueEntry(id: "island-keep-1",
        performanceID: PerformanceID(track.id), presentation: .sidePerformance, mode: .watch)
    _ = model.queueState.append(runningEntry)
    _ = model.queueState.begin(entryID: runningEntry.id) { _ in 0 }
    transport.removeAll()
    actions.pauseOrResumeMusic()
    actions.next()
    expect(transport == ["pause", "next"],
           "an active queue must let pause/next reach the same shared model command")
    expect(NotchMusicState.make(model).isActive,
           "the island must report active once a session/queue is running")
    let runningQueue = NotchQueueState.make(model)
    expect(runningQueue.isRunning && runningQueue.rows.contains { $0.isActive },
           "the island queue projection must mark the running entry as active")
}

// MARK: - Navigation collapse

/// Choosing songs, opening the full window and an ACCEPTED fullscreen navigation all collapse the
/// island first (so the open island can never cover the destination) and never mutate the shared
/// model. The island's own queue/background pages stay INSIDE the panel and do not touch the window.
/// There is no pin: the open island is always transient.
private func runNotchNavigationCollapseRegression(expect: (Bool, String) -> Void) {
    guard let library = try? PerformanceLibrary.bundled() else {
        expect(false, "the bundled library must load for the navigation-collapse regression")
        return
    }
    let model = PerformanceBrowserModel()
    model.library = library
    model.root = "/synthetic/bside-island-navigation-only"
    model.serviceReady = true
    model.scanned = true
    model.desired = DesiredState(timeMode: .fixed(.noon))
    model.presentation = .sidePerformance
    let queueBefore = model.queueState.configuration.entries.map(\.id)
    let orderBefore = model.queueState.configuration.order
    model.selectedID = library.manifest.tracks.first?.id

    func openIsland() -> NotchPanelPresentation {
        let presentation = NotchPanelPresentation()
        // Hover waits one short entry delay, so an open island must let that fire first.
        presentation.autoEntryDelay = 0.02
        presentation.autoCollapseDelay = 0.05
        presentation.hoverChanged(true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        return presentation
    }

    // Every external destination collapses the island first.
    var destinations: [String] = []
    let presentation = openIsland()
    expect(presentation.isExpanded,
           "the navigation regression needs an open island")
    var actions = NotchControlActions()
    actions.toggle = { presentation.toggle() }
    actions.collapse = { presentation.collapse() }
    func navigate(_ name: String) -> () -> Void {
        { presentation.collapse(); destinations.append(name) }
    }
    actions.chooseSongs = navigate("library")
    actions.openFullWindow = navigate("window")
    actions.enterFullScreen = navigate("fullscreen")
    // Presentation-only actions must never reach a transport command.
    var transport: [String] = []
    actions.pauseOrResumeMusic = { transport.append("pause") }
    actions.next = { transport.append("next") }
    actions.stop = { transport.append("stop") }

    for (name, action) in [("library", actions.chooseSongs),
                           ("window", actions.openFullWindow),
                           ("fullscreen", actions.enterFullScreen)] {
        presentation.hoverChanged(false)
        presentation.hoverChanged(true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        expect(presentation.isExpanded, "the island must be open before navigating to \(name)")
        action()
        expect(!presentation.isExpanded,
               "navigating to \(name) must collapse the open island")
        expect(!presentation.hasPendingCollapse,
               "an explicit navigation collapse must not leave a delayed task behind")
    }
    expect(destinations == ["library", "window", "fullscreen"],
           "every external destination must be reached exactly once")
    expect(transport.isEmpty,
           "opening/closing the island and navigating must never send a playback command")
    expect(model.sessionState.session == nil,
           "navigation presentation must never create or change a session")
    expect(model.queueState.configuration.entries.map(\.id) == queueBefore
           && model.queueState.configuration.order == orderBefore,
           "navigation presentation must never mutate the saved queue")
    if let selected = model.selectedID {
        expect(library.manifest.tracks.contains { $0.id == selected },
               "navigation presentation must never change the selected version")
    }

    // The open island also collapses on an explicit Esc/close, and a real leave always collapses it.
    let second = openIsland()
    second.collapse()
    expect(!second.isExpanded, "Esc/close must collapse the open island")
    // The explicit close suppressed hover reopen, so a REAL leave is needed before the next entry.
    second.hoverChanged(false)
    second.hoverChanged(true)
    RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    expect(second.isExpanded, "a collapsed island must reopen on hover without any persistent state")
    // A real pointer leave always collapses the open island: no control click can pin it open.
    second.hoverChanged(false)
    RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    expect(!second.isExpanded, "a real pointer leave must always collapse the open island")

}

// MARK: - Transient proportion + scene models

/// The proportion and scene selections are transient presentation state: Balanced and Cloudy Desk
/// are the defaults, the three profiles carry the documented symmetric extensions, and selecting a
/// value is idempotent. Nothing here persists, applies a wallpaper or sends a command.
private func runNotchProfileAndSceneModelRegression(expect: (Bool, String) -> Void) {
    expect(NotchIslandProfile.allCases == [.compact, .balanced, .wide],
           "there must be exactly three lateral proportions")
    expect(NotchIslandProfile.compact.lateralExtension == 188
           && NotchIslandProfile.balanced.lateralExtension == 236
           && NotchIslandProfile.wide.lateralExtension == 292,
           "the three profiles must carry the documented symmetric extensions")
    expect(NotchIslandProfile.compact.mainBodyPadding == NotchPanelGeometry.minimumMainBodyPadding
           && NotchIslandProfile.wide.mainBodyPadding == NotchPanelGeometry.minimumMainBodyPadding
           && NotchIslandProfile.balanced.mainBodyPadding == NotchPanelGeometry.balancedMainBodyPadding,
           "Compact/Wide must use the minimal padding and Balanced the extra padding")
    let profiles = NotchIslandProfileModel()
    expect(profiles.profile == .balanced, "Balanced must be the default proportion")
    profiles.select(.wide)
    expect(profiles.profile == .wide, "the proportion must be selectable")
    profiles.select(.wide)
    expect(profiles.profile == .wide, "reselecting the current proportion must be a no-op")
    profiles.select(.compact)
    expect(profiles.profile == .compact, "the proportion must remain transient and switchable")

    expect(NotchSceneChoice.allCases == [.cloudyDesk, .goldenDesk, .lamplitSofa],
           "there must be exactly three illustrative scene choices")
    expect(NotchSceneChoice.cloudyDesk.resourceName == "R09"
           && NotchSceneChoice.goldenDesk.resourceName == "R13"
           && NotchSceneChoice.lamplitSofa.resourceName == "R16",
           "the scene choices must map to the three ORIGINAL bundled stills")
    expect(NotchSceneChoice.cloudyDesk.displayName == "阴天书桌"
           && NotchSceneChoice.goldenDesk.displayName == "落日书桌"
           && NotchSceneChoice.lamplitSofa.displayName == "灯下沙发",
           "the scene choices must carry the owner-approved review labels")
    let scenes = NotchSceneChoiceModel(observeClock: false)
    scenes.preview(hour: 8)
    expect(scenes.choice == .cloudyDesk, "morning preview must show R09")
    scenes.preview(hour: 20)
    expect(scenes.choice == .lamplitSofa, "night preview must show R16")
    scenes.shutdown()

}

// MARK: - Scene crop seam

/// The crop must be an intentional head/shoulder crop: a fixed wide aspect (never a squeezed 3:2
/// source), the whole head inside the crop, and the face well away from the soft right-hand fade.
private func runNotchSceneCropRegression(expect: (Bool, String) -> Void) {
    let imageSize = CGSize(width: 1536, height: 1024)
    expect(NotchSceneChoice.cloudyDesk.faceAnchor == CGPoint(x: 0.37, y: 0.33)
           && NotchSceneChoice.goldenDesk.faceAnchor == CGPoint(x: 0.37, y: 0.33)
           && NotchSceneChoice.lamplitSofa.faceAnchor == CGPoint(x: 0.455, y: 0.30),
           "the measured face anchors must stay the documented x0.37 / y0.33-0.34")
    expect(NotchSceneCrop.aspect > 2 && NotchSceneCrop.aspect < 3,
           "the crop aspect must be deliberately wide, never the full 3:2 source")
    expect(NotchSceneCrop.sharpUntilFraction > 0.5 && NotchSceneCrop.sharpUntilFraction < 1,
           "the soft fade must start after the middle of the crop")

    for choice in NotchSceneChoice.allCases {
        let crop = NotchSceneCrop.normalizedRect(for: choice, imageSize: imageSize)
        expect(crop.width > 0 && crop.height > 0
               && crop.minX >= 0 && crop.minY >= 0
               && crop.maxX <= 1.0001 && crop.maxY <= 1.0001,
               "\(choice): the crop must stay inside the source image")
        let physicalAspect = (crop.width * imageSize.width) / (crop.height * imageSize.height)
        expect(abs(physicalAspect - NotchSceneCrop.aspect) < 0.02,
               "\(choice): the crop must preserve its intended aspect ratio")
        expect(crop.contains(CGPoint(x: choice.faceAnchor.x, y: choice.faceAnchor.y)),
               "\(choice): the measured face must be inside the crop")
        expect(choice.faceAnchor.y - crop.minY >= NotchSceneCrop.headroom - 0.001,
               "\(choice): the crop must keep its headroom above the face")
        expect(choice.faceAnchor.y + NotchSceneCrop.torso >= crop.maxY - 0.001,
               "\(choice): the crop must keep enough torso for a coherent pose")
        let faceFraction = NotchSceneCrop.faceFractionInsideCrop(for: choice, imageSize: imageSize)
        expect(faceFraction > 0 && faceFraction < NotchSceneCrop.sharpUntilFraction,
               "\(choice): the face must sit inside the sharp part, away from the fading region")
        let pixels = NotchSceneCrop.pixelRect(for: choice, imageSize: imageSize)
        expect(!pixels.isEmpty && pixels.width <= imageSize.width
               && pixels.height <= imageSize.height,
               "\(choice): the pixel crop must be a real rectangle inside the decoded image")
        expect(abs(pixels.width / pixels.height - NotchSceneCrop.aspect) < 0.05,
               "\(choice): the pixel crop must keep the same aspect")
    }
}

// MARK: - Scene image store

/// Each of the (at most three) ORIGINAL stills is decoded at most ONCE, even across repeated body
/// evaluations/hover, and a missing resource is never re-decoded. No more than three resources are
/// ever held in memory by this prototype.
private func runNotchSceneImageStoreRegression(expect: (Bool, String) -> Void) {
    let store = NotchSceneImageStore.shared
    store.resetForTesting()

    var loads: [NotchSceneChoice] = []
    let dummy = NSImage(size: NSSize(width: 10, height: 10))
    store.loader = { choice in
        loads.append(choice)
        return dummy
    }
    expect(store.decodeCount == 0 && store.cachedCount == 0 && store.attemptedCount == 0,
           "a fresh store must hold nothing")

    for _ in 0..<5 { _ = store.image(for: .cloudyDesk) }
    expect(store.decodeCount == 1 && loads == [.cloudyDesk] && store.cachedCount == 1,
           "repeated requests for one still must decode it exactly once")

    _ = store.image(for: .goldenDesk)
    _ = store.image(for: .lamplitSofa)
    expect(store.decodeCount == 3 && store.cachedCount == 3 && store.attemptedCount == 3,
           "the three stills must be decoded once each and cached")
    expect(store.attemptedCount <= NotchSceneChoice.allCases.count,
           "the store must never hold more than the three scene resources")

    for choice in NotchSceneChoice.allCases { _ = store.image(for: choice) }
    expect(store.decodeCount == 3 && loads.count == 3,
           "hover/re-render must never re-decode a cached still")

    // A missing resource is recorded once and never retried on every evaluation.
    store.resetForTesting()
    var failedLoads = 0
    store.loader = { _ in
        failedLoads += 1
        return nil
    }
    _ = store.image(for: .cloudyDesk)
    _ = store.image(for: .cloudyDesk)
    expect(failedLoads == 1 && store.decodeCount == 1 && store.cachedCount == 0
           && store.attemptedCount == 1,
           "a missing resource must be attempted once, never re-decoded on hover")

    store.resetForTesting()
    expect(store.loader == nil && store.decodeCount == 0 && store.attemptedCount == 0,
           "the test reset must restore the bundle loader and an empty cache")
}

// MARK: - Native frost / Reduce Transparency

/// The native frost material must switch to an opaque, readable fallback when Reduce Transparency
/// is on, and must blend inside this transparent window rather than behind it.
private func runNotchSceneArtworkRegression(expect: (Bool, String) -> Void) {
    expect(NotchSceneArtwork.frostMaterial(reduceTransparency: false) == .hudWindow,
           "the default control side must use the real translucent frost material")
    expect(NotchSceneArtwork.frostMaterial(reduceTransparency: true) == .contentBackground,
           "Reduce Transparency must select an opaque readable material fallback")
    expect(NotchSceneArtwork.frostMaterial(reduceTransparency: true)
           != NotchSceneArtwork.frostMaterial(reduceTransparency: false),
           "Reduce Transparency must really change the material")
    expect(NotchSceneArtwork.frostBlendingMode == .withinWindow,
           "the frost must blend inside the transparent island window, never behind it")
}
