import AppKit
import CoreImage
import Metal
import SwiftUI

/// Composes decorative light, authored expressions and bounded inset hair-detail motion.
/// The light pass changes color only; it is not physical relighting or inferred geometry.
final class NotchArtworkSceneLight {
    static let shared = NotchArtworkSceneLight()
    let context = MTLCreateSystemDefaultDevice().map { CIContext(mtlDevice: $0, options: [
        .workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false]) }
    let kernel = CIColorKernel(source: kernelSource)
    let epoch = Date()
    let expression = NotchArtworkExpression()
    let hairMotion = NotchArtworkHairMotion()
    private var sources: [NotchSceneChoice: (image: CIImage, colorSpace: CGColorSpace?)] = [:]
    private var failed: Set<NotchSceneChoice> = []

    static func eligible(visible: Bool, sharpRevealed: Bool, available: Bool,
                         reduceMotion: Bool, lowPower: Bool) -> Bool {
        visible && sharpRevealed && available && !reduceMotion && !lowPower
    }

    /// Main-thread presentation cache: at most the three existing originals, no frame cache.
    func prepare(_ choice: NotchSceneChoice, image: NSImage?) -> Bool {
        guard kernel != nil, hairMotion.kernel != nil, hairMotion.compositionKernel != nil,
              context != nil, !failed.contains(choice) else { return false }
        if sources[choice] != nil { return true }
        guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return false
        }
        sources[choice] = (Self.source(cg), cg.colorSpace)
        expression.prepare(choice)
        return true
    }

    static func source(_ image: CGImage) -> CIImage {
        CIImage(cgImage: image, options: [.colorSpace: NSNull()])
    }

    func output(source: CIImage, choice: NotchSceneChoice, seconds: Double,
                amount: Double = 1) -> CIImage? {
        guard seconds.isFinite, amount.isFinite else { return nil }
        let scene = choice == .cloudyDesk ? 0 : (choice == .goldenDesk ? 1 : 2)
        return kernel?.apply(extent: source.extent, arguments: [source,
            CIVector(x: source.extent.width, y: source.extent.height), scene, seconds, amount])
    }

    func composedOutput(source: CIImage, choice: NotchSceneChoice, seconds: Double,
                        hairMotionEnabled: Bool = true) -> CIImage? {
        guard let light = output(source: source, choice: choice, seconds: seconds) else { return nil }
        let expressed = expression.output(source: light, choice: choice, seconds: seconds)
        return hairMotion.output(source: source, composition: expressed, choice: choice, seconds: seconds,
                                 enabled: hairMotionEnabled)
    }

    func frame(_ choice: NotchSceneChoice, at date: Date) -> CGImage? {
        guard !failed.contains(choice), let source = sources[choice],
              let output = composedOutput(source: source.image, choice: choice,
                                          seconds: date.timeIntervalSince(epoch)),
              let image = context?.createCGImage(output, from: source.image.extent,
                                                 format: .RGBA8, colorSpace: source.colorSpace) else {
            if failed.insert(choice).inserted {
                NSLog("Notch scene light unavailable for %@; using the original still", choice.resourceName)
            }
            return nil
        }
        return image
    }

    // Protection uses broad original-pixel head/neck/contact rectangles with a smooth OUTER
    // feather. Every interior pixel returns its untouched input, including its original alpha.
    static let kernelSource = """
    float boxDistance(vec2 p, vec4 box) {
        vec2 q = abs(p - (box.xy + box.zw) * 0.5) - (box.zw - box.xy) * 0.5;
        return length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0);
    }
    float clearOf(vec2 p, vec4 box) { return smoothstep(0.0, 64.0, boxDistance(p, box)); }
    float pool(vec2 p, vec2 center, vec2 radius) {
        vec2 q = (p - center) / radius;
        return exp(-dot(q,q) * 1.6);
    }
    kernel vec4 sceneLight(__sample pixel, vec2 size, float scene, float time, float amount) {
        if (amount <= 0.0 || pixel.a <= 0.0) { return pixel; }
        vec2 p = vec2(destCoord().x, size.y - destCoord().y);
        vec2 uv = p / size;
        float safe;
        if (scene < 1.5) {
            safe = clearOf(p, vec4(400.0,140.0,750.0,560.0))
                 * clearOf(p, vec4(600.0,730.0,785.0,845.0));
        } else {
            safe = clearOf(p, vec4(555.0,145.0,825.0,490.0))
                 * clearOf(p, vec4(700.0,465.0,920.0,650.0))
                 * clearOf(p, vec4(430.0,785.0,940.0,1100.0));
        }
        if (safe <= 0.0) { return pixel; }
        float light = 0.0, shade = 0.0;
        vec3 tint;
        if (scene < 0.5) {
            // Broad cloud shade crosses the window/room; diffuse cool light occupies a
            // different region. The small lower pool is reflected light on dark clothing.
            shade = 0.125 * pool(uv, vec2(0.24+0.18*sin(time*0.30),0.28+0.06*cos(time*0.23)), vec2(0.38,0.50));
            light = 0.070 * pool(uv, vec2(0.70+0.13*cos(time*0.25),0.43), vec2(0.42,0.55))
                  + 0.018 * (0.5+0.5*sin(time*0.30+1.2)) * pool(uv,vec2(0.31,0.68),vec2(0.16,0.24));
            tint = vec3(0.86,0.94,1.0);
        } else if (scene < 1.5) {
            // Soft parallel occlusion bands follow the baked upper-right window direction.
            float axis = uv.x*0.76 + uv.y*0.55;
            float sun = (axis-(0.65+0.12*sin(time*0.24)))/0.17;
            float cloud = (axis-(0.34+0.13*cos(time*0.21)))/0.20;
            light = 0.080 * exp(-sun*sun) * (0.72+0.28*uv.x);
            shade = 0.135 * exp(-cloud*cloud);
            tint = vec3(1.0,0.86,0.66);
        } else {
            // Slow lamp falloff on curtain/sofa, separate cool window reflection. The
            // luminous shade itself is fixed; there is no lamp flicker or moving geometry.
            light = 0.070 * pool(uv,vec2(0.25+0.035*sin(time*0.18),0.45+0.07*cos(time*0.20)),vec2(0.36,0.40));
            shade = 0.120 * pool(uv,vec2(0.30+0.10*cos(time*0.22),0.72+0.08*sin(time*0.16)),vec2(0.41,0.36));
            float reflection = 0.028 * pool(uv,vec2(0.82,0.42+0.12*sin(time*0.17)),vec2(0.30,0.41));
            tint = vec3(1.0,0.83,0.61);
            vec3 base = unpremultiply(pixel).rgb;
            safe *= clearOf(p,vec4(230.0,0.0,590.0,110.0));
            vec3 delta = light*tint*(vec3(1.0)-base) - shade*base
                       + reflection*vec3(0.52,0.70,1.0)*(vec3(1.0)-base);
            return premultiply(vec4(clamp(base+clamp(delta,vec3(-0.075),vec3(0.075))*safe*amount,0.0,1.0),pixel.a));
        }
        vec3 base = unpremultiply(pixel).rgb;
        vec3 delta = light*tint*(vec3(1.0)-base) - shade*base;
        return premultiply(vec4(clamp(base+clamp(delta,vec3(-0.075),vec3(0.075))*safe*amount,0.0,1.0),pixel.a));
    }
    """
}

/// Only this decorative image subscribes to frame dates. Inactive branches contain no TimelineView.
struct NotchSceneLightImage: View {
    let original: NSImage
    let choice: NotchSceneChoice
    let active: Bool
    let onUnavailable: () -> Void

    var body: some View {
        if active {
            TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { tick in
                if let frame = NotchArtworkSceneLight.shared.frame(choice, at: tick.date) {
                    Image(decorative: frame, scale: 1).resizable()
                } else {
                    Image(nsImage: original).resizable().onAppear(perform: onUnavailable)
                }
            }
        } else {
            Image(nsImage: original).resizable()
        }
    }
}
