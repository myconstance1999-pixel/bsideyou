// BSideControlApp — bsideyou island: pure geometry + collapsed-surface policy seam.
//
// The island is an ordinary nonactivating AppKit window that hangs from the top-centre of the
// display. This file owns the ONE placement decision so it can be tested without a screen, a
// window server or an Agent:
//   * `NotchScreenDescriptor` is a plain value description of everything the placement needs
//     (`NSScreen.frame` / `visibleFrame` / `safeAreaInsets.top` / `auxiliaryTopLeftArea` /
//     `auxiliaryTopRightArea`), filled from the public NSScreen API at the call site;
//   * `NotchIslandPage` names the one transient secondary surface the island can show;
//   * `NotchIslandProfile` names the transient lateral proportion (compact / balanced / wide);
//   * `NotchPanelGeometry` derives the collapsed and expanded rectangles for one display, page and
//     profile;
//   * `NotchShelfLayout` is the read-only summary the SwiftUI island renders from;
//   * `NotchIslandSurface` is the CLOSED-state policy: the resting window is COMPLETELY INVISIBLE
//     on every display. On notched displays the invisible hit window is exactly the hardware
//     cutout, with no activation area below or beside it.
//     Without a notch the under-menubar hit window is 120x14. No artwork, wing, cover, border,
//     glow or decorative notch is drawn at rest; no hit region extends over adjacent menu items.
//
// Shape rules:
//   * collapsed surface and hit window = the public cutout, top-anchored at `frame.maxY`
//     and clamped to the owning screen;
//   * without a notch the original 120x6 surface remains invisible, and the 120x14 hit window
//     starts below the menu-bar reserved top edge (`visibleFrame.maxY`);
//   * the hardware measurement stays distinct from any derived size: `hardwareBandHeight` (the real
//     camera band, e.g. 32pt) is the reserved top strip of the expanded frame, and nothing is ever
//     drawn in it;
//   * expanded OUTER width = the PUBLIC camera width plus `profile.lateralExtension` on EACH side,
//     capped to the screen width minus `screenMargin` and clamped to the screen, so the island is
//     always symmetric about the camera;
//   * expanded OUTER height = the reserved hardware band plus the CURRENT page's body. The main
//     page body is the EXACT sum of the rows it draws plus the profile's own top/bottom padding, so
//     a layout change that needs another row must change that list (and therefore the height);
//   * every readable control and the sharp character artwork live BELOW the reserved band, so the
//     camera can never bisect a face or a control. The main surface reserves a character region on
//     the LEFT (`characterRegionWidth`) and keeps controls on the RIGHT.
//
// Nothing here imports AppKit or touches real screens; NSScreen never appears in Core or in this
// seam. Expanded artwork geometry is independent of the collapsed hit target.

import Foundation
import CoreGraphics

/// One display, described only by the public values the placement needs.
struct NotchScreenDescriptor: Equatable {
    /// Full display frame in global display coordinates (origin bottom-left).
    var frame: CGRect
    /// Usable frame (menu bar / Dock excluded). Used to keep the island clear of system menu items.
    var visibleFrame: CGRect
    /// `NSScreen.safeAreaInsets.top`. Positive only when the display has a camera cutout; the island
    /// top edge is anchored to it so the hardware band lines up and controls stay below it.
    var topInset: CGFloat
    /// Public `NSScreen.auxiliaryTopLeftArea`, when the display exposes one.
    var auxiliaryTopLeft: CGRect?
    /// Public `NSScreen.auxiliaryTopRightArea`, when the display exposes one.
    var auxiliaryTopRight: CGRect?

    init(frame: CGRect, visibleFrame: CGRect? = nil, topInset: CGFloat = 0,
         auxiliaryTopLeft: CGRect? = nil, auxiliaryTopRight: CGRect? = nil) {
        self.frame = frame
        self.visibleFrame = visibleFrame ?? frame
        self.topInset = topInset
        self.auxiliaryTopLeft = auxiliaryTopLeft
        self.auxiliaryTopRight = auxiliaryTopRight
    }
}

/// The two presentation states the island window can be in. Raw values are stable ids used by the
/// regression seam and by accessibility inspection, never persisted.
enum NotchPanelMode: String, Equatable {
    case collapsed
    case expanded
}

/// The one transient page the island can show besides its compact main surface. Selecting a page
/// only changes the island's own size/content: it is never persisted, never sent over IPC and never
/// a second window.
enum NotchIslandPage: String, Equatable, CaseIterable {
    /// Compact music island: title with the trailing close control, transport, music volume,
    /// queue/background entry, list play/shuffle when no song is active, and the compact
    /// 全部/已筛选 count beside those idle actions. No header, no pin and no second window.
    case main
    /// Read-only queue browse inside the same panel, plus an explicit per-entry play.
    case queue
    /// The existing background chooser model projected into the same panel.
    case background
}

/// Read-only summary of everything the SwiftUI island needs to know about the display, page and
/// proportion it is drawn at. Derived from one `NotchScreenDescriptor`, so the view never reads
/// NSScreen itself.
struct NotchShelfLayout: Equatable {
    /// True when a camera cutout/hardware band exists.
    var hasNotch: Bool
    /// The transient lateral proportion this layout was derived for.
    var profile: NotchIslandProfile
    /// Collapsed surface geometry; the no-notch invisible hit target is slightly deeper.
    var collapsedSize: CGSize
    /// Exact expanded OUTER size for the CURRENT page and profile (reserved top strip + body).
    var expandedSize: CGSize
    /// Height of the reserved hardware band at the top of the expanded frame: the public safe-area
    /// top inset when there is a camera cutout, otherwise 0.
    var hardwareBandHeight: CGFloat
    /// Height of the window's reserved top strip. On a notched display this is exactly the hardware
    /// band, so every readable control starts at the band's lower edge; without a cutout it is the
    /// one 28pt header row placed below the menu-bar edge. The island content is padded by exactly
    /// this much, so nothing is ever drawn under the hardware or over menu-bar controls.
    var reservedBandHeight: CGFloat
    /// True while the CLOSED window draws no artwork at all. The review prototype draws nothing at
    /// rest on EVERY display, so this is always true now.
    var closedSurfaceIsTransparent: Bool
    /// Opacity of the closed silhouette. Always 0: the collapsed trigger is invisible.
    var closedSilhouetteOpacity: Double
    /// Rounded lower edge of the black island.
    var cornerRadius: CGFloat
    /// The page this layout was derived for.
    var page: NotchIslandPage
    /// Body below the reserved band. `reservedBandHeight + bodyHeight` is the expanded TOTAL.
    var bodyHeight: CGFloat
    /// Body padding above + below the island controls.
    var bodyVerticalPadding: CGFloat
    /// Effective main-page body padding for the current profile (half of `bodyVerticalPadding` on
    /// the main page). Kept explicit so the regression can prove the profile's padding is the one
    /// that produced the height.
    var mainBodyPadding: CGFloat
    /// Width reserved for the sharp character artwork on the LEFT of the body. Zero on the
    /// secondary pages (queue/background), which need their full width for detail content.
    var characterRegionWidth: CGFloat
    /// True while the sharp character artwork participates in the layout (main page only).
    var showsCharacterImage: Bool
    /// Width left for controls on the RIGHT of the body.
    var controlRegionWidth: CGFloat { max(0, expandedSize.width - characterRegionWidth) }
}

/// Collapsed visual policy. Nothing is drawn inside the hit window.
enum NotchIslandSurface {
    /// The resting surface is invisible on every display. There is no visible collapsed artwork,
    /// wing, cover, border, glow or invented decorative notch.
    static let collapsedSurfaceIsInvisible = true
    /// Opacity of the closed silhouette. Always 0: nothing is drawn at rest.
    static func closedSilhouetteOpacity(on screen: NotchScreenDescriptor) -> Double { 0 }
    /// True because the closed surface never draws anything on any display.
    static func isTransparentWhenClosed(on screen: NotchScreenDescriptor) -> Bool { true }
    /// Original surface rectangle; the native window uses `collapsedHitSize` separately.
    static func closedRect(on screen: NotchScreenDescriptor) -> CGRect {
        NotchPanelGeometry.panelRect(size: NotchPanelGeometry.collapsedSize(screen),
                                    top: NotchPanelGeometry.topEdge(screen), on: screen)
    }
}

/// Pure placement math. No state, no NSScreen, no polling: every value is derived from one
/// `NotchScreenDescriptor` plus the page and proportion the island is showing.
enum NotchPanelGeometry {
    /// Header row height: 28pt. On a display without a cutout it is placed below the menu-bar edge.
    static let headerHeight: CGFloat = 28
    /// MAIN page title row height: one 13pt title + one 11pt meaningful status on the same line,
    /// sized to the 28pt trailing close control so the close can never be squeezed off the row.
    static let titleRowHeight: CGFloat = 28
    /// MAIN page body padding used by Compact/Wide. Balanced overrides it (see
    /// `balancedMainBodyPadding`). It is the minimum that keeps the bottom row clear of the rounded
    /// lower corners.
    static let minimumMainBodyPadding: CGFloat = 4
    /// MAIN page body padding used by the Balanced default, which is what gives it 148pt total
    /// height before the inline timer was added.
    static let balancedMainBodyPadding: CGFloat = 12
    /// MAIN page body height for a proportion. DERIVED from the rows the main page really draws —
    /// title with the trailing close control, transport with the music volume, the
    /// navigation/context row and shared timer row — plus the gaps between them and the profile's own top/bottom padding.
    static func mainBodyHeight(for profile: NotchIslandProfile) -> CGFloat {
        mainPageRowHeights.reduce(0, +)
            + CGFloat(mainPageRowHeights.count - 1) * mainRowGap
            + 2 * profile.mainBodyPadding
    }
    /// MAIN page body height for the Balanced default (kept as a convenience for the seam).
    static var mainBodyHeight: CGFloat { mainBodyHeight(for: .balanced) }
    /// The exact vertical gap the main page's VStack uses between its rows.
    static let mainRowGap: CGFloat = 4
    /// The rows the main page really draws, in order: title + close (28pt), transport/volume (28pt)
    /// navigation/context (28pt), and the shared timer (28pt). `mainBodyHeight(for:)` is their exact sum plus gaps and the
    /// profile padding, so a layout change that needs another row must change this list.
    static var mainPageRowHeights: [CGFloat] {
        [titleRowHeight, minimumControlSize, minimumControlSize, minimumControlSize]
    }
    /// QUEUE page vertical gap between its fixed chrome row and the scrollable browse list.
    static let queueRowGap: CGFloat = 4
    /// QUEUE page scrollable browse list height. The queue body is the exact sum of its fixed
    /// chrome (page header + queue-order/transport row), this list and the body padding.
    static let queueListHeight: CGFloat = 64
    /// QUEUE page body height: page header + queue-order row + the browse list + gaps + padding.
    static var queueBodyHeight: CGFloat {
        headerHeight + minimumControlSize + queueListHeight
            + 2 * bodyPadding + 2 * queueRowGap
    }
    /// Background body reserves a larger selected picture plus seven compact thumbnail slots.
    /// Header, compact navigation/apply row and status stay below the existing hardware band.
    static let backgroundBodyHeight: CGFloat = 368
    /// Vertical body padding for the SECONDARY pages (queue/background), top and bottom together.
    /// The main page has its own profile padding, which is part of its derived body height.
    static let bodyPadding: CGFloat = 8
    /// The expanded width is capped to the (visible) screen width minus this much. 48pt keeps the
    /// island clear of screen edges even for the widest proportion.
    static let screenMargin: CGFloat = 48
    /// Never draw narrower than this, even on a tiny/zoomed display.
    static let minimumWidth: CGFloat = 240
    /// Horizontal padding inside the expanded island for the SECONDARY pages.
    static let horizontalBodyPadding: CGFloat = 12
    /// Horizontal padding inside the MAIN page's control region. Smaller than the secondary pages
    /// because the main controls share the body with the character region and must never be
    /// squeezed.
    static let mainControlPadding: CGFloat = 6
    /// No-notch collapsed affordance: a small centred transparent grab region below the menu bar.
    static let grabHandleSize = CGSize(width: 120, height: 6)
    /// Height of the invisible under-menubar target on displays without a hardware cutout.
    static let fallbackHitHeight: CGFloat = 14
    /// Used only when a display reports a top inset but exposes no auxiliary top areas; the real
    /// cutout width is never guessed from pixels when the public areas are available.
    static let fallbackNotchWidth: CGFloat = 180
    /// Main controls keep a compact width across presets; extra width belongs to the artwork.
    /// On narrower displays the control region takes the available width before artwork is added.
    static let mainControlRegionWidth: CGFloat = 340
    /// Lower-corner radius of the black island.
    static let cornerRadius: CGFloat = 20
    /// Radius of the top outward flare where the island meets the hardware shoulders.
    static let topCornerRadius: CGFloat = 10
    /// Finite expansion/collapse/page-change duration. Kept short so an explicit click starts
    /// immediately and even the animated path settles quickly.
    static let transitionDuration: TimeInterval = 0.14
    /// Small entry delay before a plain flyover expands the island. Cancelled the moment the pointer
    /// leaves, so crossing the notch on the way somewhere else never opens the island.
    static let hoverEntryDelay: TimeInterval = 0.01
    /// One short delayed collapse after the pointer leaves. It is the leave grace that lets the
    /// pointer travel from the hardware-sized trigger into the body.
    static let hoverCollapseDelay: TimeInterval = 0.10
    /// Minimum clickable control edge (product rule: no control smaller than this).
    static let minimumControlSize: CGFloat = 28
    /// Minimum readable text size (product rule: never shrink text to make it fit).
    static let minimumTextSize: CGFloat = 11
    /// Safety gap between any optional in-band content and the camera cutout. The island keeps every
    /// readable control below the band, so this is only retained as an invariant for the seam.
    static let cutoutSafetyMargin: CGFloat = 8

    /// A camera cutout/hardware band is present only when the public top inset is non-zero.
    static func hasNotch(_ screen: NotchScreenDescriptor) -> Bool { screen.topInset > 0.5 }

    /// Height of the reserved top band (camera cutout), derived from the public safe-area inset.
    static func hardwareBandHeight(_ screen: NotchScreenDescriptor) -> CGFloat {
        hasNotch(screen) ? max(0, screen.topInset) : 0
    }

    /// Width between the two public auxiliary top areas (the hardware cutout), or nil when the
    /// display does not expose both. Never guessed from pixels.
    static func cutoutWidth(_ screen: NotchScreenDescriptor) -> CGFloat? {
        guard let left = screen.auxiliaryTopLeft, let right = screen.auxiliaryTopRight else { return nil }
        let width = screen.frame.width - left.width - right.width
        return width > 0 ? width : nil
    }

    /// The camera width the layout is derived from: the PUBLIC cutout width when the display
    /// exposes both auxiliary areas, otherwise the documented nominal fallback. Never a per-model
    /// fixed guess when public values are available.
    static func cameraWidth(_ screen: NotchScreenDescriptor) -> CGFloat {
        cutoutWidth(screen) ?? fallbackNotchWidth
    }

    /// True when the two public auxiliary top areas describe a cutout that really sits at the top of
    /// the display and leaves room beside it.
    static func hasUsableCutoutGeometry(_ screen: NotchScreenDescriptor) -> Bool {
        hasNotch(screen) && cutoutWidth(screen) != nil
    }

    /// Global Y of the island's top edge. With a cutout the island starts at the physical top of the
    /// display and its reserved band covers the hardware; without one it starts at the menu-bar
    /// reserved edge (`visibleFrame.maxY`) so system menu items are never covered.
    static func topEdge(_ screen: NotchScreenDescriptor) -> CGFloat {
        hasNotch(screen) ? screen.frame.maxY : screen.visibleFrame.maxY
    }

    /// Collapsed silhouette: EXACTLY the public hardware cutout on a notched display (an invisible
    /// hover/tap trigger), otherwise the small transparent grab region below the menu bar. No
    /// software skirt, wing or cover is added, so no invisible interception ever extends over the
    /// menu items.
    static func collapsedSize(_ screen: NotchScreenDescriptor) -> CGSize {
        guard hasNotch(screen) else { return grabHandleSize }
        let width = min(cameraWidth(screen), screen.frame.width)
        let height = min(hardwareBandHeight(screen), screen.frame.height)
        return CGSize(width: width, height: height)
    }

    /// One rectangular, transparent native target: the exact cutout on notched displays,
    /// or the established deeper under-menubar target on no-notch displays.
    static func collapsedHitSize(_ screen: NotchScreenDescriptor) -> CGSize {
        let surface = collapsedSize(screen)
        let height = hasNotch(screen) ? surface.height : fallbackHitHeight
        return CGSize(width: surface.width, height: min(height, screen.frame.height))
    }

    /// Height of the window's reserved top strip. On a notched display the WHOLE hardware band is
    /// reserved and every readable control starts at (or below) its lower edge; without a cutout one
    /// 28pt header row sits below the menu-bar edge.
    static func reservedBandHeight(_ screen: NotchScreenDescriptor) -> CGFloat {
        hasNotch(screen) ? hardwareBandHeight(screen) : headerHeight
    }

    /// Body height below the reserved strip for one page and profile. The main page's height is the
    /// exact sum of the rows it draws plus the profile padding; the secondary pages are sized for
    /// their own detail content.
    static func pageBodyHeight(_ page: NotchIslandPage,
                               profile: NotchIslandProfile) -> CGFloat {
        switch page {
        case .main: return mainBodyHeight(for: profile)
        case .queue: return queueBodyHeight
        case .background: return backgroundBodyHeight
        }
    }

    /// Body below the reserved top band.
    static func bodyHeight(_ screen: NotchScreenDescriptor,
                           page: NotchIslandPage = .main,
                           profile: NotchIslandProfile = .balanced) -> CGFloat {
        pageBodyHeight(page, profile: profile)
    }

    /// Vertical padding inside the body, top and bottom together. The MAIN page's padding is part of
    /// its derived body height (the profile's padding top and bottom); the secondary pages keep
    /// their own fixed padding.
    static func bodyVerticalPadding(_ screen: NotchScreenDescriptor,
                                    page: NotchIslandPage = .main,
                                    profile: NotchIslandProfile = .balanced) -> CGFloat {
        page == .main ? 2 * profile.mainBodyPadding : 2 * bodyPadding
    }

    /// TOTAL expanded height on one display for one page and profile: the reserved top strip plus
    /// that page's body.
    static func totalHeight(_ screen: NotchScreenDescriptor,
                            page: NotchIslandPage = .main,
                            profile: NotchIslandProfile = .balanced) -> CGFloat {
        reservedBandHeight(screen) + pageBodyHeight(page, profile: profile)
    }

    /// Expanded OUTER width for one page and profile, derived from the PUBLIC camera width plus the
    /// profile's symmetric lateral extension, then capped to the (visible) screen width minus the
    /// screen margin and clamped to the owning screen.
    static func expandedWidth(_ screen: NotchScreenDescriptor,
                              page: NotchIslandPage = .main,
                              profile: NotchIslandProfile = .balanced) -> CGFloat {
        let designed = cameraWidth(screen) + 2 * profile.lateralExtension
        let screenWidth = screen.frame.width > 0 ? screen.frame.width : designed
        let visibleWidth = screen.visibleFrame.width > 0 ? screen.visibleFrame.width : screenWidth
        let cap = min(screenWidth, visibleWidth) - screenMargin
        return min(screenWidth, max(minimumWidth, min(designed, cap)))
    }

    /// Expanded OUTER size for one page and profile: the profile width capped to the (visible)
    /// screen width minus the screen margin, and the display-derived total height. Never taller than
    /// the display.
    static func expandedSize(_ screen: NotchScreenDescriptor,
                             page: NotchIslandPage = .main,
                             profile: NotchIslandProfile = .balanced) -> CGSize {
        let width = expandedWidth(screen, page: page, profile: profile)
        let total = totalHeight(screen, page: page, profile: profile)
        let height = min(total, screen.frame.height > 0 ? screen.frame.height : total)
        return CGSize(width: width, height: height)
    }

    /// Width reserved for the sharp character artwork on the LEFT of the main body. It keeps the
    /// sharp artwork clear of the controls. The fixed control reserve gives wider presets more
    /// original scene instead of adding blank control spacing; small displays omit the artwork.
    static func characterRegionWidth(for expandedWidth: CGFloat) -> CGFloat {
        max(0, expandedWidth - mainControlRegionWidth)
    }

    static func size(for mode: NotchPanelMode, on screen: NotchScreenDescriptor,
                     page: NotchIslandPage = .main,
                     profile: NotchIslandProfile = .balanced) -> CGSize {
        switch mode {
        case .collapsed: return collapsedHitSize(screen)
        case .expanded: return expandedSize(screen, page: page, profile: profile)
        }
    }

    static func layout(on screen: NotchScreenDescriptor,
                       page: NotchIslandPage = .main,
                       profile: NotchIslandProfile = .balanced) -> NotchShelfLayout {
        let expanded = expandedSize(screen, page: page, profile: profile)
        return NotchShelfLayout(hasNotch: hasNotch(screen),
                                profile: profile,
                                collapsedSize: collapsedSize(screen),
                                expandedSize: expanded,
                                hardwareBandHeight: hardwareBandHeight(screen),
                                reservedBandHeight: reservedBandHeight(screen),
                                closedSurfaceIsTransparent: NotchIslandSurface.isTransparentWhenClosed(on: screen),
                                closedSilhouetteOpacity: NotchIslandSurface.closedSilhouetteOpacity(on: screen),
                                cornerRadius: cornerRadius,
                                page: page,
                                bodyHeight: bodyHeight(screen, page: page, profile: profile),
                                bodyVerticalPadding: bodyVerticalPadding(screen, page: page, profile: profile),
                                mainBodyPadding: profile.mainBodyPadding,
                                characterRegionWidth: page == .main
                                    ? characterRegionWidth(for: expanded.width) : 0,
                                showsCharacterImage: page == .main)
    }

    /// Exact window rectangle for one presentation state on one display.
    static func panelRect(for mode: NotchPanelMode, on screen: NotchScreenDescriptor,
                          page: NotchIslandPage = .main,
                          profile: NotchIslandProfile = .balanced) -> CGRect {
        panelRect(size: size(for: mode, on: screen, page: page, profile: profile),
                  top: topEdge(screen), on: screen)
    }

    /// Top-center anchored rectangle. Works for any origin, including a negative-origin secondary
    /// display: the rectangle is always centered inside its OWN display frame.
    ///
    /// The result is snapped to INTEGRAL points. A fractional origin is not reliably realizable: the
    /// real hardware cutout here is 185pt wide on a 1512pt display, so the exactly centered origin is
    /// 663.5, and the ordered window really came up at 663.0. Leaving the snap to AppKit would make
    /// "requested == actual" unverifiable and weaken the exact shrink-back guarantee, so the geometry
    /// owns it. Widths/heights are already integral (they come from the cutout/safe-area/public
    /// constants), so only the origin is rounded.
    static func panelRect(size: CGSize, top: CGFloat, on screen: NotchScreenDescriptor) -> CGRect {
        let width = min(size.width, screen.frame.width)
        let centered = (screen.frame.midX - width / 2).rounded()
        let minX = screen.frame.minX
        let maxX = screen.frame.maxX - width
        let x = maxX >= minX ? min(max(centered, minX), maxX).rounded() : minX.rounded()
        return CGRect(x: x, y: (top - size.height).rounded(), width: width, height: size.height)
    }
}
