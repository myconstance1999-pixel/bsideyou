import AppKit
import CoreImage
import ImageIO

/// Samples each scene's authored eyelid and smile plates at its original coordinates.
/// Only finite eye/mouth masks reach authored pixels; there is no geometric deformation.
final class NotchArtworkExpression {
    struct Regions {
        let leftEye: SIMD4<Double>
        let rightEye: SIMD4<Double>
        let mouth: SIMD4<Double>
    }
    struct Plates {
        let half: CIImage?
        let closed: CIImage?
        let smile: CIImage?
    }

    /// Top-left source-pixel coordinates. R09 retains its previously reviewed masks.
    static func regions(for choice: NotchSceneChoice) -> Regions {
        switch choice {
        case .cloudyDesk:
            return Regions(leftEye: SIMD4(602, 343, 23, 16), rightEye: SIMD4(672, 352, 19, 15),
                           mouth: SIMD4(626, 428, 32, 15))
        case .goldenDesk:
            return Regions(leftEye: SIMD4(609, 339, 22, 13), rightEye: SIMD4(669, 341, 18, 12),
                           mouth: SIMD4(638, 420, 28, 13))
        case .lamplitSofa:
            return Regions(leftEye: SIMD4(650, 307, 24, 15), rightEye: SIMD4(731, 309, 24, 15),
                           mouth: SIMD4(688, 384, 31, 14))
        }
    }
    static let taper = 1.25

    let kernel = CIColorKernel(source: kernelSource)
    private(set) var plates: [NotchSceneChoice: Plates] = [:]

    /// At most three scenes, each with one decode attempt for each optional plate. Failed loads
    /// are retained too, so a missing resource cannot trigger repeated IO on body evaluation.
    func prepare(_ choice: NotchSceneChoice, resourceRoot: URL? = nil) {
        guard plates[choice] == nil else { return }
        func load(_ suffix: String) -> CIImage? {
            let name = choice.resourceName + suffix
            let url = resourceRoot?.appendingPathComponent(name + ".png")
                ?? Bundle.main.url(forResource: name, withExtension: "png")
            guard let url, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  image.width == 1536, image.height == 1024 else { return nil }
            return NotchArtworkSceneLight.source(image)
        }
        plates[choice] = Plates(half: load("-half-eyes"), closed: load("-closed-eyes"), smile: load("-smile"))
    }

    /// Discrete open/half/closed cels: no iris crossfade or sliding skin patch.
    /// Two blinks per 12-second cycle, with reproducible 4...8-second gaps. Morning and night
    /// use shorter half-eye holds; night retains its original 0.08-second fully closed phase.
    static func blinkStage(at seconds: Double, choice: NotchSceneChoice = .cloudyDesk) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        let cycle = floor(seconds / 12)
        let local = seconds.truncatingRemainder(dividingBy: 12)
        let hash = sin(cycle * 12.9898 + 4.1414) * 43758.5453
        let offset = 4 + 4 * (hash - floor(hash))
        let timing: (duration: Double, closedStart: Double, closedEnd: Double)
        switch choice {
        case .cloudyDesk: timing = (0.20, 0.06, 0.12)
        case .goldenDesk: timing = (0.30, 0.10, 0.18)
        case .lamplitSofa: timing = (0.20, 0.06, 0.14)
        }
        func stage(_ time: Double) -> Int {
            guard time > 0, time < timing.duration else { return 0 }
            return time >= timing.closedStart && time < timing.closedEnd ? 2 : 1
        }
        return max(stage(local), stage(local - offset))
    }

    /// A brief, faint authored smile; most of the 14-second cycle stays neutral.
    static func smileAmount(at seconds: Double) -> Double {
        guard seconds.isFinite, seconds >= 0 else { return 0 }
        let time = seconds.truncatingRemainder(dividingBy: 14) - 2
        func ease(_ value: Double) -> Double { value * value * (3 - 2 * value) }
        guard time > 0, time < 3.9 else { return 0 }
        if time < 1.1 { return ease(time / 1.1) }
        if time < 2.3 { return 1 }
        return 1 - ease((time - 2.3) / 1.6)
    }

    static func contains(x: Double, y: Double, region: SIMD4<Double>) -> Bool {
        let dx = (x - region.x) / region.z, dy = (y - region.y) / region.w
        return dx * dx + dy * dy < taper * taper
    }

    func output(source: CIImage, choice: NotchSceneChoice, seconds: Double) -> CIImage {
        guard source.extent == CGRect(x: 0, y: 0, width: 1536, height: 1024),
              seconds.isFinite, let plate = plates[choice] else { return source }
        let stage = plate.half != nil && plate.closed != nil ? Self.blinkStage(at: seconds, choice: choice) : 0
        let smileAmount = plate.smile == nil ? 0 : Self.smileAmount(at: seconds)
        guard stage != 0 || smileAmount > 0 else { return source }
        func vector(_ region: SIMD4<Double>) -> CIVector {
            CIVector(x: region.x, y: region.y, z: region.z, w: region.w)
        }
        let regions = Self.regions(for: choice)
        return kernel?.apply(extent: source.extent, arguments: [source,
            stage == 1 ? (plate.half ?? source) : (plate.closed ?? source), plate.smile ?? source,
            vector(regions.leftEye), vector(regions.rightEye), vector(regions.mouth),
            stage, smileAmount]) ?? source
    }

    static let kernelSource = """
    float localMask(vec2 p, vec4 region) {
        float radius = length((p - region.xy) / region.zw);
        return 1.0 - smoothstep(1.0, 1.25, radius);
    }
    kernel vec4 expression(__sample original, __sample eyelid, __sample smile,
                           vec4 leftEye, vec4 rightEye, vec4 mouth,
                           float stage, float smileAmount) {
        vec2 p = vec2(destCoord().x, 1024.0 - destCoord().y);
        float eyeMask = stage > 0.0 ? max(localMask(p, leftEye), localMask(p, rightEye)) : 0.0;
        float mouthMask = smileAmount * localMask(p, mouth);
        if (eyeMask <= 0.0 && mouthMask <= 0.0) { return original; }
        vec3 color = mix(original.rgb, smile.rgb, mouthMask);
        color = mix(color, eyelid.rgb, eyeMask);
        return vec4(color, original.a);
    }
    """
}
