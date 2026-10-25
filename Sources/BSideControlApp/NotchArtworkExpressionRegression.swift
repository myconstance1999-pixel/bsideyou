import AppKit
import CoreImage
import ImageIO

/// Uses the production kernels and explicit artwork paths; never creates a window or media state.
func runNotchArtworkExpressionRegression(renderer: NotchArtworkSceneLight, resourceRoot: URL,
                                         outputFolder: URL, expect: (Bool, String) -> Void) throws {
    guard let context = renderer.context else {
        expect(false, "expression context unavailable"); return
    }
    let expression = renderer.expression
    var records: [[String: Any]] = []
    for choice in NotchSceneChoice.allCases {
        let scene = choice.resourceName
        guard let imageSource = CGImageSourceCreateWithURL(resourceRoot.appendingPathComponent(scene + ".png") as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            expect(false, "\(scene): expression source unavailable"); continue
        }
        let source = NotchArtworkSceneLight.source(image)
        let regions = NotchArtworkExpression.regions(for: choice)
        let plates = expression.plates[choice]
        expect(expression.kernel != nil && plates?.half != nil && plates?.closed != nil && plates?.smile != nil,
               "\(scene): all three authored plates must load")
        func bytes(_ input: CIImage) -> [UInt8] {
            var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
            pixels.withUnsafeMutableBytes { address in
                context.render(input, toBitmap: address.baseAddress!, rowBytes: image.width * 4,
                               bounds: input.extent, format: .RGBA8, colorSpace: nil)
            }
            return pixels
        }
        for (name, seconds) in [("neutral", 1.0), ("half", 0.05), ("closed", choice == .goldenDesk ? 0.15 : 0.10),
                                ("late-closure", 0.13),
                                ("after-morning-blink", 0.25),
                                ("midpoint", 2.55), ("smile", 3.5), ("smile-and-blink", 4.15), ("release", 5.1), ("returned", 6.0)] {
            let date = renderer.epoch.addingTimeInterval(seconds)
            // Date stores an absolute floating-point timestamp; compare the same sampled phase.
            let phase = date.timeIntervalSince(renderer.epoch)
            let light = renderer.output(source: source, choice: choice, seconds: phase)!
            let output = expression.output(source: light, choice: choice, seconds: phase)
            let baseline = bytes(light), actual = bytes(output)
            let blink = NotchArtworkExpression.blinkStage(at: seconds, choice: choice)
            let smile = NotchArtworkExpression.smileAmount(at: seconds)
            var eyes = 0, mouth = 0, outside = 0, alpha = 0
            for y in 0..<image.height { for x in 0..<image.width {
                let index = (y * image.width + x) * 4
                if actual[index + 3] != baseline[index + 3] { alpha += 1 }
                guard actual[index..<index+3] != baseline[index..<index+3] else { continue }
                let eye = [regions.leftEye, regions.rightEye].contains {
                    NotchArtworkExpression.contains(x: Double(x)+0.5, y: Double(y)+0.5, region: $0)
                }
                let smileRegion = NotchArtworkExpression.contains(x: Double(x)+0.5, y: Double(y)+0.5,
                                                                  region: regions.mouth)
                if eye { eyes += 1 } else if smileRegion { mouth += 1 } else { outside += 1 }
            }}
            expect(outside == 0 && alpha == 0, "\(scene) \(name): expression preserves every pixel outside finite masks and original alpha")
            expect(blink == 0 ? eyes == 0 : eyes > 1000, "\(scene) \(name): selected eyelid plate appears only during blink")
            expect(smile == 0 ? mouth == 0 : mouth > 1000, "\(scene) \(name): faint smile appears only during its envelope")
            guard let frame = renderer.frame(choice, at: date) else {
                expect(false, "\(scene) \(name): production frame unavailable"); continue
            }
            expect(bytes(NotchArtworkSceneLight.source(frame))
                == bytes(renderer.hairMotion.output(source: source, composition: output,
                                                   choice: choice, seconds: phase)),
                   "\(scene) \(name): production frame includes the same authored expression")
            let destination = CGImageDestinationCreateWithURL(outputFolder.appendingPathComponent("\(scene)-expression-\(name).png") as CFURL,
                                                             "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, frame, nil)
            expect(CGImageDestinationFinalize(destination), "\(scene) \(name): evidence PNG export")
            records.append(["scene": scene, "name": name, "seconds": seconds, "blinkStage": blink, "smileAmount": smile,
                            "changedEyePixels": eyes, "changedMouthPixels": mouth,
                            "changedOutsideMaskPixels": outside, "changedAlphaPixels": alpha])
        }
        let original = bytes(source)
        let unavailable = NotchArtworkExpression()
        expect(bytes(unavailable.output(source: source, choice: choice, seconds: 0.15)) == original,
               "missing eyelid assets restore the original eyes")
        expect(bytes(unavailable.output(source: source, choice: choice, seconds: 3.5)) == original,
               "missing smile asset restores the neutral mouth")
        // Preparing another scene cannot substitute its plates for a missing scene.
        let otherScene = NotchArtworkExpression()
        otherScene.prepare(choice == .cloudyDesk ? .goldenDesk : .cloudyDesk, resourceRoot: resourceRoot)
        expect(bytes(otherScene.output(source: source, choice: choice, seconds: 0.15)) == original,
               "\(scene): an unprepared scene never borrows another scene's eyelids")
        expect(bytes(otherScene.output(source: source, choice: choice, seconds: 3.5)) == original,
               "\(scene): an unprepared scene never borrows another scene's smile")
        let missing = NotchArtworkExpression()
        missing.prepare(choice, resourceRoot: outputFolder.appendingPathComponent("missing-plates"))
        missing.prepare(choice, resourceRoot: resourceRoot)
        expect(missing.plates.count == 1 && missing.plates[choice]?.half == nil
            && missing.plates[choice]?.closed == nil && missing.plates[choice]?.smile == nil,
               "\(scene): failed resource attempts are retained, with no repeated decode")
        expect(bytes(missing.output(source: source, choice: choice, seconds: 4.15)) == original,
               "\(scene): missing scene plates preserve the original expression")
    }
    expect(expression.plates.count == NotchSceneChoice.allCases.count, "expression cache is bounded to the three scenes")
    for choice in NotchSceneChoice.allCases {
        let sampledStages = Set((0...240).map {
            NotchArtworkExpression.blinkStage(at: Double($0) / 20, choice: choice)
        })
        expect(sampledStages == Set([0, 1, 2]), "\(choice.resourceName): the existing 20 Hz timeline samples all three eyelid stages")
        expect(NotchArtworkExpression.blinkStage(at: 0.075, choice: choice) == (choice == .goldenDesk ? 1 : 2),
               "morning and night leave the narrow half-eye pose sooner; afternoon retains its timing")
        expect(NotchArtworkExpression.blinkStage(at: 0.13, choice: choice) == (choice == .cloudyDesk ? 1 : 2),
               "night preserves its longer closed phase while morning has already begun reopening")
        expect(NotchArtworkExpression.blinkStage(at: 0.15, choice: choice) == (choice == .goldenDesk ? 2 : 1),
               "night reopens through the half-eye plate without extending the morning blink")
        expect(NotchArtworkExpression.blinkStage(at: 0.225, choice: choice) == (choice == .goldenDesk ? 1 : 0),
               "morning and night restore open eyes before the unchanged afternoon blink finishes")
        for seconds in [Double.nan, .infinity, -.infinity, -1] {
            expect(NotchArtworkExpression.blinkStage(at: seconds, choice: choice) == 0
                && NotchArtworkExpression.smileAmount(at: seconds) == 0,
                   "invalid/negative phases remain neutral")
        }
    }
    try JSONSerialization.data(withJSONObject: ["frames": records,
        "limits": "Discrete authored eyelid states; blended smile midpoint. Pixel containment does not establish native naturalness or smoothness."],
        options: [.prettyPrinted, .sortedKeys]).write(to: outputFolder.appendingPathComponent("expression-evidence.json"))
}
