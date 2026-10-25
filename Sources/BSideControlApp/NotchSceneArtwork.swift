// BSideControlApp — bsideyou island: illustrative still artwork, native frost and crop seam.
//
// This file is presentation-only and contains NO player, decoder loop, generated artwork or
// segmentation service:
//   * `NotchSceneCrop` is the PURE, testable crop seam. It derives one intentional head/shoulder
//     crop per still from the owner-measured face anchor, keeping the whole head inside the crop and
//     well away from the soft fade on the right;
//   * `NotchSceneImageStore` decodes each of the (at most three) ORIGINAL bundled stills ONCE and
//     caches the original. One source placement retains the body crop while allowing the original
//     pixels above it to continue through the reserved band; hover never decodes again;
//   * `NotchSceneBackgroundLayer` is one full-height material wash; it has no duplicate image fit;
//   * `NotchCharacterLayer` is the SHARP character-side layer, restricted to the left region and
//     masked with a soft horizontal fade so it merges into the background instead of sitting in a
//     boxed thumbnail;
//   * `NotchFrostView` bridges a real `NSVisualEffectView` under the tinted control-side material,
//     with an opaque material fallback when Reduce Transparency is on.
//
// The stills are prior generated variations (illustrative stills) supplied by the owner; character
// identity is not confirmed and the prototype makes no claim of live character or video. The assets
// are read-only and only ever decoded into memory; nothing here writes, converts or applies them.

import SwiftUI
import AppKit
import ImageIO
import CoreGraphics

// MARK: - Pure crop seam

/// Derives the intentional character crop from one still's measured face anchor.
///
/// All rectangles here are NORMALIZED in the source image with the origin at the TOP-LEFT (x from
/// the left edge, y from the top edge), matching how the owner measured the anchors. The crop keeps
/// a fixed wide aspect ratio so the still is never squeezed into the ultrawide island: it reveals
/// the whole head plus enough torso for a coherent pose, and the page composes it into the left
/// region with a soft fade to the right.
enum NotchSceneCrop {
    /// Physical aspect ratio (width / height) of the crop. Deliberately wide so the crop fills the
    /// left character region without letterboxing or distorting the source.
    static let aspect: CGFloat = 2.8
    /// Headroom kept ABOVE the face anchor, in image-height fractions. Conservative, so the top of
    /// the head is never clipped.
    static let headroom: CGFloat = 0.17
    /// Torso kept BELOW the face anchor, in image-height fractions.
    static let torso: CGFloat = 0.35
    /// The soft fade on the right must start to the RIGHT of this fraction of the crop, so the face
    /// is always inside the fully opaque part of the character layer.
    static let sharpUntilFraction: CGFloat = 0.60

    /// Normalized crop for one still and one decoded image size.
    static func normalizedRect(for choice: NotchSceneChoice, imageSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        let anchor = choice.faceAnchor
        let top = max(0, anchor.y - headroom)
        let bottom = min(1, anchor.y + torso)
        let heightFraction = max(0.1, bottom - top)
        // physicalAspect = (width * W) / (height * H)  =>  width = aspect * height * H / W
        let widthFraction = min(1, aspect * heightFraction * imageSize.height / imageSize.width)
        let x = min(max(0, anchor.x - widthFraction / 2), max(0, 1 - widthFraction))
        return CGRect(x: x, y: top, width: widthFraction, height: heightFraction)
    }

    /// The crop in source PIXELS, clamped to the decoded image bounds.
    static func pixelRect(for choice: NotchSceneChoice, imageSize: CGSize) -> CGRect {
        let normalized = normalizedRect(for: choice, imageSize: imageSize)
        let rect = CGRect(x: normalized.minX * imageSize.width,
                          y: normalized.minY * imageSize.height,
                          width: normalized.width * imageSize.width,
                          height: normalized.height * imageSize.height)
        return rect.intersection(CGRect(origin: .zero, size: imageSize))
    }

    /// Where the face anchor lands INSIDE the normalized crop (x fraction). Used by the regression
    /// to prove the face stays in the sharp part and away from the fade.
    static func faceFractionInsideCrop(for choice: NotchSceneChoice, imageSize: CGSize) -> CGFloat {
        let crop = normalizedRect(for: choice, imageSize: imageSize)
        guard crop.width > 0 else { return 0 }
        return (choice.faceAnchor.x - crop.minX) / crop.width
    }
}

// MARK: - Native frost seam

/// Pure selection for the native frost material, so Reduce Transparency is testable without a view.
enum NotchSceneArtwork {
    /// Preserve the old crop's scale and body origin, extending the same source above the band.
    /// The one artwork plane uses this frame, so its skyline/furniture continue through the band.
    static func imageFrame(imageSize: CGSize, choice: NotchSceneChoice,
                           layout: NotchShelfLayout) -> CGRect {
        let crop = NotchSceneCrop.pixelRect(for: choice, imageSize: imageSize).integral
        let width = layout.showsCharacterImage ? layout.characterRegionWidth : layout.expandedSize.width
        let scale = max(width / crop.width, layout.bodyHeight / crop.height)
        return CGRect(x: (width - crop.width * scale) / 2 - crop.minX * scale,
                      y: layout.reservedBandHeight - crop.minY * scale,
                      width: imageSize.width * scale, height: imageSize.height * scale)
    }

    /// Real AppKit frost under the tinted control-side material. With Reduce Transparency the
    /// system asks for an opaque, readable material instead of a translucent one.
    static func frostMaterial(reduceTransparency: Bool) -> NSVisualEffectView.Material {
        reduceTransparency ? .contentBackground : .hudWindow
    }

    /// Blend inside this window's content, never "behind window": the window backing is transparent
    /// and the scene layers are drawn by SwiftUI in the same window.
    static let frostBlendingMode: NSVisualEffectView.BlendingMode = .withinWindow
}

/// AppKit bridge for the real native frost. No player, no layer host, no timer.
struct NotchFrostView: NSViewRepresentable {
    var reduceTransparency: Bool

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = NotchSceneArtwork.frostBlendingMode
        view.state = .active
        view.isEmphasized = false
        view.material = NotchSceneArtwork.frostMaterial(reduceTransparency: reduceTransparency)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.blendingMode = NotchSceneArtwork.frostBlendingMode
        view.state = .active
        view.material = NotchSceneArtwork.frostMaterial(reduceTransparency: reduceTransparency)
    }
}

// MARK: - Image store

/// Decodes and caches at most one original image per scene choice. The three ORIGINAL 1536x1024
/// stills are the only resources this prototype ever loads; the original is kept so hover,
/// profile changes and page changes never trigger another decode. The actual memory footprint is
/// NOT claimed here (it has not been measured).
final class NotchSceneImageStore {
    static let shared = NotchSceneImageStore()

    private let lock = NSLock()
    private var cache: [NotchSceneChoice: NSImage] = [:]
    /// Choices that were already attempted (including a failed decode), so a missing resource is
    /// never re-decoded on every body evaluation/hover.
    private var attempted: Set<NotchSceneChoice> = []
    /// Number of real decodes performed. Read-only diagnostic for the regression.
    private(set) var decodeCount = 0
    /// Test seam: replaces the bundle loader. `nil` restores the bundle loader.
    var loader: ((NotchSceneChoice) -> NSImage?)?

    private init() {}

    /// The original still for one choice, decoded at most once.
    func image(for choice: NotchSceneChoice) -> NSImage? {
        lock.lock()
        if attempted.contains(choice) {
            let cached = cache[choice]
            lock.unlock()
            return cached
        }
        let load = loader ?? Self.loadFromBundle
        lock.unlock()

        let decoded = load(choice)

        lock.lock()
        defer { lock.unlock() }
        if attempted.contains(choice) { return cache[choice] }
        attempted.insert(choice)
        decodeCount += 1
        if let decoded { cache[choice] = decoded }
        return decoded
    }

    /// Number of cached stills. Never more than the number of choices.
    var cachedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return cache.count
    }

    /// Number of choices that were attempted (decoded or failed). Never more than the number of
    /// choices, which is what proves hover cannot trigger a repeated decode.
    var attemptedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return attempted.count
    }

    /// Test-only reset so a regression can start from a clean store.
    func resetForTesting() {
        lock.lock(); defer { lock.unlock() }
        cache.removeAll()
        attempted.removeAll()
        decodeCount = 0
        loader = nil
    }

    /// Decode one bundled PNG once. Presentation retains the intentional body crop coordinates.
    static func loadFromBundle(_ choice: NotchSceneChoice) -> NSImage? {
        guard let url = Bundle.main.url(forResource: choice.resourceName, withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let decoded = CGImageSourceCreateImageAtIndex(
                  source, 0, [kCGImageSourceShouldCache: true, kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: decoded,
                       size: NSSize(width: decoded.width, height: decoded.height))
    }
}

// MARK: - Scene layers

/// One uninterrupted material wash beneath the original scene. No second image fit or crop.
struct NotchSceneBackgroundLayer: View {
    let reduceTransparency: Bool

    var body: some View {
        ZStack {
            NotchPalette.paper.opacity(reduceTransparency ? 0.92 : 0.55)
            LinearGradient(colors: [NotchPalette.bodyDeep.opacity(0.55),
                                    NotchPalette.paper.opacity(0.92)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The SHARP character-side layer: the intentional crop, restricted to the left region and faded
/// out with a soft spatial mask so it becomes the scene background instead of a card. The image is
/// never blurred. Its source placement continues through the top band without a separate crop.
/// Until the expansion frame has really settled the layer is empty, so the
/// earliest opening can never cut through the face.
struct NotchCharacterLayer: View {
    let image: NSImage?
    let width: CGFloat
    let imageFrame: CGRect
    let isRevealed: Bool
    var choice: NotchSceneChoice = .cloudyDesk
    var lightingActive = false
    var onLightUnavailable: () -> Void = {}

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    if let image, isRevealed, width > 0 {
                        NotchSceneLightImage(original: image, choice: choice, active: lightingActive,
                                             onUnavailable: onLightUnavailable)
                            .frame(width: imageFrame.width, height: imageFrame.height)
                            .offset(x: imageFrame.minX, y: imageFrame.minY)
                    }
                }
                .frame(width: max(0, width), height: proxy.size.height, alignment: .topLeading)
                .clipped()
                .mask(
                    LinearGradient(stops: [
                        .init(color: .white, location: 0),
                        .init(color: .white, location: NotchSceneCrop.sharpUntilFraction),
                        .init(color: .clear, location: 1)
                    ], startPoint: .leading, endPoint: .trailing)
                )
                Spacer(minLength: 0)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// ONE silhouette: real native frost beneath one material wash and the continuous original artwork,
/// a camera-local black reservation blending into
/// the scene-colored shoulders, and a restrained static bottom edge light. It owns no control or
/// hit target; the controls are drawn by `NotchIslandContent` on top.
struct NotchSceneSurface: View {
    let layout: NotchShelfLayout
    let choice: NotchSceneChoice
    let image: NSImage?
    let sharpRevealed: Bool
    var lightingActive = false
    var onLightUnavailable: () -> Void = {}
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var band: CGFloat { layout.reservedBandHeight }
    private var imageFrame: CGRect {
        guard let image else { return .zero }
        return NotchSceneArtwork.imageFrame(imageSize: image.size, choice: choice, layout: layout)
    }

    var body: some View {
        ZStack(alignment: .top) {
            NotchFrostView(reduceTransparency: reduceTransparency)
            NotchSceneBackgroundLayer(reduceTransparency: reduceTransparency)
            if layout.showsCharacterImage {
                NotchCharacterLayer(image: image, width: layout.characterRegionWidth,
                                    imageFrame: imageFrame, isRevealed: sharpRevealed,
                                    choice: choice, lightingActive: lightingActive,
                                    onLightUnavailable: onLightUnavailable)
            }
            cameraReservation
            warmReflection
            bottomEdgeLight
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Restrained contact shading underneath the physical camera cutout. The hardware supplies
    /// its own black silhouette: painting a second opaque shape adds a visible software frame.
    /// Readable content still stays below the measured hardware band.
    private var cameraReservation: some View {
        let cameraWidth = layout.hasNotch ? layout.collapsedSize.width : 0
        return Group {
            if layout.hasNotch {
                EllipticalGradient(stops: [
                    .init(color: .black.opacity(0.36), location: 0),
                    .init(color: .black.opacity(0.08), location: 0.55),
                    .init(color: .clear, location: 1)
                ])
                .frame(width: cameraWidth + 28, height: band + 20)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// Small warm amber reflected light on the CONTROL side only. Static and restrained: no motion,
    /// no pointer tracking, and it never covers the character region.
    private var warmReflection: some View {
        HStack(spacing: 0) {
            if layout.showsCharacterImage {
                Color.clear.frame(width: layout.characterRegionWidth)
            }
            LinearGradient(colors: [.clear, NotchPalette.amber.opacity(0.10), .clear],
                           startPoint: .top, endPoint: .bottom)
        }
        .frame(height: 54)
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    /// Restrained static edge light at the rounded lower edge. No motion, no pointer tracking.
    private var bottomEdgeLight: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            LinearGradient(colors: [.clear, NotchPalette.sage.opacity(0.10)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 26)
        }
    }
}
