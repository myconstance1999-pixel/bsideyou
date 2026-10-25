import CoreImage

/// A pinned lower-lock bend, including a small background collar around the moving outline.
final class NotchArtworkHairMotion {
    static let maximumDisplacement = 4.8
    static let period = 8.0
    let kernel = CIKernel(source: kernelSource)
    let compositionKernel = CIColorKernel(source: compositionKernelSource)

    /// Finite top-left source-pixel bounds: left, top, right, bottom. All four edges are pinned.
    static func region(for choice: NotchSceneChoice) -> SIMD4<Double> {
        switch choice {
        case .cloudyDesk: return SIMD4(414, 382, 466, 450)
        case .goldenDesk: return SIMD4(410, 388, 466, 456)
        case .lamplitSofa: return SIMD4(762, 366, 818, 425)
        }
    }

    static func displacement(at seconds: Double) -> Double {
        guard seconds.isFinite, seconds >= 0 else { return 0 }
        let phase = seconds.truncatingRemainder(dividingBy: period) / period
        let value = maximumDisplacement * sin(phase * 2 * .pi)
        return abs(value) < 1e-12 ? 0 : value
    }

    static func contains(x: Double, y: Double, choice: NotchSceneChoice) -> Bool {
        let bounds = region(for: choice)
        return x > bounds.x && x < bounds.z && y > bounds.y && y < bounds.w
    }

    func output(source: CIImage, composition: CIImage? = nil,
                choice: NotchSceneChoice, seconds: Double,
                enabled: Bool = true) -> CIImage {
        let unchanged = composition ?? source
        let shift = Self.displacement(at: seconds)
        guard enabled, shift != 0,
              source.extent == CGRect(x: 0, y: 0, width: 1536, height: 1024) else { return unchanged }
        let region = Self.region(for: choice)
        let bounds = CIVector(x: region.x, y: region.y, z: region.z, w: region.w)
        // Sample original pixels only. Sampling the composed light/expression image forces an
        // intermediate that rounds unrelated colors. These masks lie in the unchanged head area.
        guard let moved = kernel?.apply(extent: source.extent,
            roiCallback: { _, rect in rect.insetBy(dx: -Self.maximumDisplacement, dy: 0) },
            arguments: [source, bounds, shift]) else { return unchanged }
        return compositionKernel?.apply(extent: source.extent,
            arguments: [unchanged, moved, bounds]) ?? unchanged
    }

    static let kernelSource = """
    float hairWeight(vec2 p, vec4 bounds) {
        float horizontal = smoothstep(bounds.x, bounds.x + 16.0, p.x)
                         * (1.0 - smoothstep(bounds.z - 16.0, bounds.z, p.x));
        float vertical = smoothstep(bounds.y, bounds.w - 32.0, p.y)
                       * (1.0 - smoothstep(bounds.w - 20.0, bounds.w, p.y));
        return horizontal * vertical;
    }
    kernel vec4 hairMotion(sampler image, vec4 bounds, float shift) {
        vec2 coordinate = destCoord();
        vec4 original = sample(image, samplerTransform(image, coordinate));
        vec2 p = vec2(coordinate.x, 1024.0 - coordinate.y);
        // The 16-pixel edge taper bounds horizontal slope by 1.5 / 16. At 4.8 pixels,
        // the sampling map derivative stays >= 0.55: no folding or boundary crossing.
        float weight = hairWeight(p, bounds);
        if (weight <= 0.0 || original.a <= 0.0) { return original; }
        vec4 moved = sample(image, samplerTransform(image, coordinate + vec2(shift * weight, 0.0)));
        return premultiply(vec4(unpremultiply(moved).rgb, original.a));
    }
    """

    static let compositionKernelSource = """
    kernel vec4 hairComposition(__sample original, __sample moved, vec4 bounds) {
        vec2 p = vec2(destCoord().x, 1024.0 - destCoord().y);
        if (p.x <= bounds.x || p.x >= bounds.z || p.y <= bounds.y || p.y >= bounds.w) { return original; }
        return premultiply(vec4(unpremultiply(moved).rgb,original.a));
    }
    """
}
