// BSideControlApp — bsideyou island: transient review proportions + illustrative scene choice.
//
// This file is a PRESENTATION-ONLY seam for the isolated island review prototype:
//   * `NotchIslandProfile` is one of three lateral proportions. Its width is DERIVED from the
//     public hardware camera width plus a symmetric extension on EACH side, so the real cutout
//     always stays the centre of the silhouette and the island grows equally left and right;
//   * `NotchSceneChoice` is one of the three already-bundled illustrative stills. Choosing one only
//     swaps the island's own backdrop: it never touches the wallpaper gallery, never requests a
//     preview and never applies a desktop background;
//   * both models are transient. Nothing here is persisted, sent over IPC, or handed to the Agent.
//
// The two `ObservableObject`s are owned by `NotchPanelPresentation` (the one object the hosted
// SwiftUI content and the AppKit controller already share), so no other wiring changes are needed.

import Foundation
import Combine

/// The three transient lateral proportions the review prototype can show. Compact and Wide keep
/// the minimal 4pt main-body padding; Balanced — the default — breathes with 12pt, which is what
/// produces its documented 148pt total height on the reference 32pt hardware band.
enum NotchIslandProfile: String, CaseIterable, Identifiable, Equatable {
    case compact
    case balanced
    case wide

    var id: String { rawValue }

    /// Symmetric extension applied on EACH side of the public camera cutout, in points.
    var lateralExtension: CGFloat {
        switch self {
        case .compact: return 188
        case .balanced: return 236
        case .wide: return 292
        }
    }

    /// Main-page body padding, top and bottom, in points. The main body height stays DERIVED from
    /// the rows the page really draws plus this padding (never an arbitrary constant).
    var mainBodyPadding: CGFloat {
        switch self {
        case .compact, .wide: return NotchPanelGeometry.minimumMainBodyPadding
        case .balanced: return NotchPanelGeometry.balancedMainBodyPadding
        }
    }

    var displayName: String {
        switch self {
        case .compact: return "紧凑"
        case .balanced: return "均衡"
        case .wide: return "宽幅"
        }
    }
}

/// Which already-bundled illustrative still backs the review prototype. The raw values are the
/// resource names `review-build.sh` copies into `Contents/Resources`. These are the owner-supplied
/// ORIGINAL review stills (prior generated variations), not official video frames; the prototype
/// never claims a live character or video. Selecting one is presentation only.
enum NotchSceneChoice: String, CaseIterable, Identifiable, Equatable {
    case cloudyDesk = "R09"
    case goldenDesk = "R13"
    case lamplitSofa = "R16"

    var id: String { rawValue }

    /// Bundled PNG resource name (no extension).
    var resourceName: String { rawValue }

    var displayName: String {
        switch self {
        case .cloudyDesk: return "阴天书桌"
        case .goldenDesk: return "落日书桌"
        case .lamplitSofa: return "灯下沙发"
        }
    }

    /// Face anchor of this still, normalized in the source image with the origin at the TOP-LEFT
    /// (x from the left edge, y from the top edge). Measured from the originals: R09/R13 sit near
    /// (0.37, 0.33) and R16 near (0.455, 0.30). The crop seam derives its intentional head/shoulder
    /// crop from this so the whole head stays intact and away from the camera.
    var faceAnchor: CGPoint {
        switch self {
        case .cloudyDesk, .goldenDesk: return CGPoint(x: 0.37, y: 0.33)
        case .lamplitSofa: return CGPoint(x: 0.455, y: 0.30)
        }
    }
}

/// Transient proportion selection. Presentation-only: never persisted, never sent over IPC, never
/// a second window. The controller observes it to resize the ONE panel through the existing
/// generation-safe frame animator.
final class NotchIslandProfileModel: ObservableObject {
    @Published private(set) var profile: NotchIslandProfile = .balanced

    func select(_ profile: NotchIslandProfile) {
        guard self.profile != profile else { return }
        self.profile = profile
    }
}
