import AppKit
import CoreImage
import ImageIO

/// Compares the production composition with the same-time composition with hair disabled.
func runNotchArtworkHairMotionRegression(renderer: NotchArtworkSceneLight, resourceRoot: URL,
                                         outputFolder: URL, expect: (Bool, String) -> Void) throws {
    guard let context = renderer.context else { expect(false, "hair context unavailable"); return }
    expect(renderer.hairMotion.kernel != nil && renderer.hairMotion.compositionKernel != nil,
           "hair sampling and composition kernels must compile")
    func bytes(_ input: CIImage) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: 1536 * 1024 * 4)
        data.withUnsafeMutableBytes {
            context.render(input, toBitmap: $0.baseAddress!, rowBytes: 1536 * 4,
                           bounds: input.extent, format: .RGBA8, colorSpace: nil)
        }
        return data
    }
    func export(_ image: CGImage, name: String) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            outputFolder.appendingPathComponent(name + ".png") as CFURL, "public.png" as CFString, 1, nil) else {
            throw NSError(domain: "HairMotionEvidence", code: 1)
        }
        CGImageDestinationAddImage(destination, image, nil)
        expect(CGImageDestinationFinalize(destination), "\(name): hair evidence PNG export")
    }
    let screen = NotchScreenDescriptor(frame: CGRect(x: 0, y: 0, width: 1512, height: 982), topInset: 32,
        auxiliaryTopLeft: CGRect(x: 0, y: 950, width: 664, height: 32),
        auxiliaryTopRight: CGRect(x: 849, y: 950, width: 663, height: 32))
    let layout = NotchPanelGeometry.layout(on: screen)
    var records: [[String: Any]] = []
    var contours: [[String: Any]] = []
    for choice in NotchSceneChoice.allCases {
        let name = choice.resourceName
        guard let imageSource = CGImageSourceCreateWithURL(resourceRoot.appendingPathComponent(name + ".png") as CFURL, nil),
              let original = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            expect(false, "\(name): hair source unavailable"); continue
        }
        let source = NotchArtworkSceneLight.source(original)
        try export(original, name: name + "-hair-original")
        // Independent anatomical bounds, separate from the motion-mask definitions.
        let protected: [CGRect] = choice == .lamplitSofa
            ? [CGRect(x: 555, y: 145, width: 270, height: 130),
               CGRect(x: 620, y: 260, width: 135, height: 195),
               CGRect(x: 591, y: 308, width: 36, height: 55),
               CGRect(x: 783, y: 305, width: 22, height: 58),
               CGRect(x: 620, y: 425, width: 310, height: 230)]
            : [CGRect(x: 400, y: 140, width: 350, height: 190),
               CGRect(x: 466, y: 310, width: 70, height: 92),
               CGRect(x: 520, y: 230, width: 185, height: 244),
               CGRect(x: 470, y: 390, width: 130, height: 115),
               CGRect(x: 470, y: 445, width: 300, height: 400)]
        for (label, seconds) in [("neutral", 0.0), ("positive", 2.0), ("crossing", 4.0), ("negative", 6.0)] {
            let date = renderer.epoch.addingTimeInterval(seconds)
            let phase = date.timeIntervalSince(renderer.epoch)
            let disabled = renderer.composedOutput(source: source, choice: choice, seconds: phase,
                                                   hairMotionEnabled: false)!
            guard let frame = renderer.frame(choice, at: date) else {
                expect(false, "\(name): production hair frame unavailable"); continue
            }
            let before = bytes(disabled), after = bytes(NotchArtworkSceneLight.source(frame))
            var changed = 0, outside = 0, protectedChanges = 0, alpha = 0
            for y in 0..<1024 { for x in 0..<1536 {
                let index = (y * 1536 + x) * 4
                if before[index + 3] != after[index + 3] { alpha += 1 }
                guard before[index] != after[index] || before[index + 1] != after[index + 1]
                    || before[index + 2] != after[index + 2] else { continue }
                changed += 1
                if !NotchArtworkHairMotion.contains(x: Double(x) + 0.5, y: Double(y) + 0.5, choice: choice) {
                    outside += 1
                }
                if protected.contains(where: { $0.contains(CGPoint(x: x, y: y)) }) { protectedChanges += 1 }
            }}
            expect(outside == 0 && protectedChanges == 0 && alpha == 0,
                   "\(name) \(label): hair preserves every outside/protected pixel and original alpha")
            expect(seconds == 0 || seconds == 4 ? changed == 0 : changed > 100,
                   "\(name) \(label): neutral is exact and extreme motion is confined but nonzero")
            expect(renderer.hairMotion.output(source: disabled, choice: choice, seconds: phase,
                                               enabled: false) === disabled,
                   "\(name): disabled motion does not resample the composition")
            try export(frame, name: name + "-hair-" + label)
            records.append(["scene": name, "phase": seconds, "changedPixels": changed,
                            "outsideMaskChanges": outside, "protectedChanges": protectedChanges, "alphaChanges": alpha])
        }
        for phase in [0.0, 4, 8, -1, Double.nan, .infinity] {
            expect(renderer.hairMotion.output(source: source, choice: choice, seconds: phase) === source,
                   "\(name): neutral or invalid hair phase returns the untouched input")
        }

        // Freeze lighting and expression so the outline alone explains the comparison.
        // The detailed crop is 2x source pixels. The native strip uses the existing 317x180 layout.
        let crop = choice == .lamplitSofa ? CGRect(x: 580, y: 270, width: 230, height: 190)
                                           : CGRect(x: 410, y: 270, width: 300, height: 220)
        let placement = NotchSceneArtwork.imageFrame(imageSize: CGSize(width: 1536, height: 1024),
                                                     choice: choice, layout: layout)
        let frozen = renderer.composedOutput(source: source, choice: choice, seconds: 0,
                                             hairMotionEnabled: false)!
        func hairOnly(_ phase: Double) -> CIImage {
            renderer.hairMotion.output(source: source, composition: frozen, choice: choice, seconds: phase)
        }
        let bounds = NotchArtworkHairMotion.region(for: choice)
        let support = CGRect(x: bounds.x, y: bounds.y, width: bounds.z - bounds.x, height: bounds.w - bounds.y)
        let overlay = CGContext(data: nil, width: 1536, height: 1024, bitsPerComponent: 8,
            bytesPerRow: 0, space: original.colorSpace!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        overlay.draw(original, in: CGRect(x: 0, y: 0, width: 1536, height: 1024))
        overlay.translateBy(x: 0, y: 1024); overlay.scaleBy(x: 1, y: -1)
        overlay.setLineWidth(1)
        overlay.setStrokeColor(CGColor(red: 1, green: 0.2, blue: 0.2, alpha: 0.7))
        for rect in protected { overlay.stroke(rect) }
        overlay.setStrokeColor(CGColor(red: 0.2, green: 1, blue: 0.2, alpha: 1))
        overlay.stroke(support)
        overlay.setStrokeColor(CGColor(red: 0.1, green: 0.8, blue: 1, alpha: 1))
        overlay.setLineWidth(2)
        overlay.move(to: CGPoint(x: bounds.x, y: bounds.y))
        overlay.addLine(to: CGPoint(x: bounds.z, y: bounds.y)); overlay.strokePath()
        let skinEdge = choice == .lamplitSofa ? bounds.x : bounds.z
        overlay.setStrokeColor(CGColor(red: 1, green: 0.2, blue: 1, alpha: 1))
        overlay.move(to: CGPoint(x: skinEdge, y: bounds.y))
        overlay.addLine(to: CGPoint(x: skinEdge, y: bounds.w)); overlay.strokePath()
        try export(overlay.makeImage()!, name: name + "-hair-support")

        let phases = [0.0, 2, 6]
        let samples = phases.map { bytes(hairOnly($0)) }
        for (index, label) in ["neutral", "positive", "negative"].enumerated() {
            let image = context.createCGImage(hairOnly(phases[index]), from: source.extent,
                                              format: .RGBA8, colorSpace: original.colorSpace)!
            try export(image.cropping(to: crop)!, name: name + "-hair-only-" + label)
        }
        // Locate the actual hair/background luminance crossing in rendered pixels. Use one
        // source-derived threshold per row for every phase, not the shader's displacement value.
        let rows = choice == .lamplitSofa ? [400, 403, 406]
            : choice == .cloudyDesk ? [422, 425, 428] : [430, 433, 436]
        let search = (Int(bounds.x) + 5)...(Int(bounds.z) - 5)
        func luminance(_ data: [UInt8], _ x: Int, _ y: Int) -> Double {
            let i = (y * 1536 + x) * 4
            return 0.2126 * Double(data[i]) + 0.7152 * Double(data[i + 1]) + 0.0722 * Double(data[i + 2])
        }
        var travel: [Double] = []
        for y in rows {
            let threshold = (luminance(samples[0], search.lowerBound, y)
                           + luminance(samples[0], search.upperBound, y)) / 2
            var edges: [Double] = []
            for data in samples {
                var crossings: [Double] = []
                for x in search.dropLast() {
                    let a = luminance(data, x, y), b = luminance(data, x + 1, y)
                    let rightDirection = choice == .lamplitSofa ? b > a : b < a
                    if rightDirection && min(a, b) <= threshold && max(a, b) >= threshold {
                        crossings.append(Double(x) + (threshold - a) / (b - a))
                    }
                }
                // Select the exterior crossing, not a brighter strand inside the lock.
                if let edge = choice == .lamplitSofa ? crossings.last : crossings.first { edges.append(edge) }
            }
            expect(edges.count == 3, "\(name): rendered hair contour is measurable at row \(y)")
            if edges.count == 3 {
                let span = edges.max()! - edges.min()!
                travel.append(span)
                contours.append(["scene": name, "row": y, "threshold": threshold,
                    "neutralX": edges[0], "positiveX": edges[1], "negativeX": edges[2],
                    "sourcePeakToPeak": span, "nativePointPeakToPeak": span * placement.width / 1536])
            }
        }
        if travel.count == 3 {
            expect(travel.sorted()[1] * placement.width / 1536 >= 2,
                   "\(name): actual lower contour travels at least two native logical points")
        }
        for detailed in [true, false] {
            let width = detailed ? Int(crop.width) * 2 : Int(layout.characterRegionWidth)
            let height = detailed ? Int(crop.height) * 2 : Int(layout.expandedSize.height)
            let label = detailed ? "detail" : "native-scale"
            let url = outputFolder.appendingPathComponent(name + "-hair-" + label + ".gif")
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "com.compuserve.gif" as CFString, 40, nil) else {
                expect(false, "\(name): GIF destination unavailable"); continue
            }
            CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
            for index in 0..<40 {
                autoreleasepool {
                    let before = context.createCGImage(frozen, from: source.extent,
                                                       format: .RGBA8, colorSpace: original.colorSpace)!
                    let after = context.createCGImage(hairOnly(Double(index) / 5), from: source.extent,
                                                      format: .RGBA8, colorSpace: original.colorSpace)!
                    let canvas = CGContext(data: nil, width: width * 2, height: height, bitsPerComponent: 8,
                        bytesPerRow: 0, space: original.colorSpace!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                    canvas.interpolationQuality = .high
                    for (column, image) in [before, after].enumerated() {
                        canvas.saveGState()
                        canvas.clip(to: CGRect(x: column * width, y: 0, width: width, height: height))
                        if detailed {
                            canvas.draw(image.cropping(to: crop)!, in: CGRect(x: column * width, y: 0, width: width, height: height))
                        } else {
                            canvas.draw(image, in: CGRect(x: CGFloat(column * width) + placement.minX,
                                y: CGFloat(height) - placement.maxY, width: placement.width, height: placement.height))
                        }
                        canvas.restoreGState()
                    }
                    CGImageDestinationAddImage(destination, canvas.makeImage()!,
                        [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.2]] as CFDictionary)
                }
            }
            expect(CGImageDestinationFinalize(destination), "\(name): \(label) GIF export")
        }
    }
    let offsets = (0...160).map { NotchArtworkHairMotion.displacement(at: Double($0) / 20) }
    expect(offsets.allSatisfy { abs($0) <= 4.8 }, "hair displacement never exceeds 4.8 source pixels")
    expect(zip(offsets, offsets.dropFirst()).allSatisfy { abs($0 - $1) < 0.189 },
           "hair movement advances smoothly at the existing 20 Hz cadence")
    expect(zip(offsets, offsets.dropFirst(2)).enumerated().allSatisfy { index, endpoints in
        abs(endpoints.1 - 2 * offsets[index + 1] + endpoints.0) < 0.0075
    }, "hair movement has no abrupt acceleration at neutral or loop boundaries")
    // Nonopaque pixels verify that displaced RGB never imports a neighboring pixel's alpha.
    var translucent = [UInt8](repeating: 0, count: 1536 * 1024 * 4)
    for index in stride(from: 0, to: translucent.count, by: 4) {
        let alpha = UInt8(100 + (index / 4) % 156)
        translucent[index] = alpha; translucent[index + 1] = alpha / 2; translucent[index + 3] = alpha
    }
    let input = CIImage(bitmapData: Data(translucent), bytesPerRow: 1536 * 4,
                        size: CGSize(width: 1536, height: 1024), format: .RGBA8, colorSpace: nil)
    let before = bytes(input)
    let after = bytes(renderer.hairMotion.output(source: input, choice: .lamplitSofa, seconds: 2))
    expect(stride(from: 3, to: after.count, by: 4).allSatisfy { before[$0] == after[$0] },
           "hair preserves nonopaque alpha even while sampling neighboring RGB")
    try JSONSerialization.data(withJSONObject: ["frames": records, "contours": contours,
        "maximumSourceDisplacement": 4.8, "periodSeconds": 8,
        "minimumHorizontalSamplingDerivative": 0.55,
        "supportOverlayLegend": "Green: finite support. Cyan: pinned upper attachment. Magenta: pinned skin-facing edge. Red: unchanged anatomical protection.",
        "gifComparison": "Left: hair disabled. Right: production hair kernel. Both hold lighting and expression at phase zero. Detail is 2x source pixels; native-scale is the existing 317x180 character placement. GIF samples 5 Hz; application remains 20 Hz.",
        "limits": "The lower outline and a finite adjacent background collar bend together. Pixel containment and measured contour travel do not establish natural appearance."],
        options: [.prettyPrinted, .sortedKeys]).write(to: outputFolder.appendingPathComponent("hair-motion-evidence.json"))
}
