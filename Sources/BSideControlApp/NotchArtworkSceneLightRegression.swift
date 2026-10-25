import AppKit
import CoreImage
import ImageIO
import Metal

/// Explicit original resource/evidence roots; no NSApplication, windows, persisted preferences or media.
func runNotchArtworkSceneLightRegression(resourceRoot: URL, outputFolder: URL) -> Int {
    var failures: [String] = []
    func expect(_ condition: Bool, _ message: String) {
        if !condition { failures.append(message); print("FAIL: \(message)") }
    }
    let renderer = NotchArtworkSceneLight()
    for choice in NotchSceneChoice.allCases {
        renderer.expression.prepare(choice, resourceRoot: resourceRoot)
    }
    guard let context = renderer.context, renderer.kernel != nil else {
        print("FAIL: Metal Core Image context or scene color kernel unavailable")
        return 1
    }
    func bytes(_ image: CIImage, float: Bool = false) -> [UInt8] {
        let stride = Int(image.extent.width) * (float ? 16 : 4)
        var data = [UInt8](repeating: 0, count: stride * Int(image.extent.height))
        data.withUnsafeMutableBytes { address in
            context.render(image, toBitmap: address.baseAddress!, rowBytes: stride,
                bounds: image.extent, format: float ? .RGBAf : .RGBA8, colorSpace: nil)
        }
        return data
    }
    func png(_ pixels: [UInt8], width: Int, height: Int, name: String) throws {
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width*4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let url = outputFolder.appendingPathComponent(name)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw NSError(domain: "SceneLightEvidence", code: 1)
        }
        CGImageDestinationAddImage(destination, cg, nil)
        if !CGImageDestinationFinalize(destination) { throw NSError(domain: "SceneLightEvidence", code: 2) }
    }
    var records: [[String: Any]] = []
    do {
        try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        for choice in NotchSceneChoice.allCases {
            let url = resourceRoot.appendingPathComponent(choice.resourceName + ".png")
            guard let decoded = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateImageAtIndex(decoded, 0, nil) else {
                expect(false, "missing original \(url.path)"); continue
            }
            let source = NotchArtworkSceneLight.source(cg), original = bytes(source)
            let w = cg.width, h = cg.height
            expect(w == 1536 && h == 1024, "authored protection coordinates require the original 1536x1024 image")
            expect(renderer.prepare(choice, image: NSImage(cgImage:cg, size:NSSize(width:w,height:h))),
                   "the production cache must accept the original artwork")
            try png(original, width: w, height: h, name: choice.resourceName + "-original.png")
            let identity = renderer.output(source: source, choice: choice, seconds: 8, amount: 0)!
            expect(bytes(identity) == original, "\(choice.resourceName) disabled kernel is exact source RGB/alpha")
            let protected: [CGRect] = choice == .lamplitSofa
                ? [CGRect(x: 555,y: 145,width: 270,height: 345), CGRect(x: 700,y: 465,width: 220,height: 185),
                   CGRect(x: 430,y: 785,width: 510,height: 239)]
                : [CGRect(x: 400,y: 140,width: 350,height: 420), CGRect(x: 600,y: 730,width: 185,height: 115)]
            let witnesses: [CGRect] = choice == .lamplitSofa
                ? [CGRect(x: 440,y: 120,width: 100,height: 240), CGRect(x: 80,y: 480,width: 270,height: 300),
                   CGRect(x: 980,y: 180,width: 300,height: 260)]
                : [CGRect(x: 40,y: 40,width: 280,height: 260), CGRect(x: 20,y: 420,width: 230,height: 260),
                   CGRect(x: 870,y: 620,width: 330,height: 190)]
            var first: [UInt8] = [], temporalLight = 0, temporalShade = 0
            var sceneRows: [[String: Any]] = []
            for phase in [0.0,4.0,8.0,12.0,16.0] {
                guard let output = renderer.output(source: source, choice: choice, seconds: phase) else {
                    expect(false,"kernel failed \(choice.resourceName)"); continue
                }
                let actual = bytes(output)
                guard let frame=renderer.frame(choice, at:renderer.epoch.addingTimeInterval(phase)) else {
                    expect(false,"production frame failed \(choice.resourceName)"); continue
                }
                let frameTag=frame.colorSpace?.name as String? ?? "untagged"
                let composed = renderer.composedOutput(source: source, choice: choice, seconds: phase)!
                let frameBytesMatch=bytes(NotchArtworkSceneLight.source(frame)) == bytes(composed)
                expect(cg.colorSpace?.name == CGColorSpace.sRGB && frame.colorSpace?.name == cg.colorSpace?.name,
                       "\(choice.resourceName) output must retain the original sRGB display tag")
                expect(frameBytesMatch,"\(choice.resourceName) display tagging must not change raw RGB or alpha")
                try png(actual,width:w,height:h,name:String(format:"%@-phase-%04.1f.png",choice.resourceName,phase))
                if first.isEmpty { first = actual }
                var protectedChanges = 0, alphaChanges = 0, maxDelta = 0, lit = 0, shaded = 0
                var phaseLight = 0, phaseShade = 0
                for y in 0..<h { for x in 0..<w {
                    let i=(y*w+x)*4
                    let changed = actual[i] != original[i] || actual[i+1] != original[i+1] || actual[i+2] != original[i+2]
                    // The shader's coordinate origin is verified here against visible top-left pixel witnesses.
                    if changed && protected.contains(where: { $0.contains(CGPoint(x:x,y:y)) }) { protectedChanges += 1 }
                    if actual[i+3] != original[i+3] { alphaChanges += 1 }
                    let dr=Int(actual[i])-Int(original[i]), dg=Int(actual[i+1])-Int(original[i+1])
                    let db=Int(actual[i+2])-Int(original[i+2])
                    maxDelta = max(maxDelta,abs(dr),abs(dg),abs(db))
                    let luma = 0.2126*Double(dr)+0.7152*Double(dg)+0.0722*Double(db)
                    if luma > 1 { lit += 1 }; if luma < -1 { shaded += 1 }
                    if witnesses.contains(where: { $0.contains(CGPoint(x:x,y:y)) }) {
                        let temporal=0.2126*Double(Int(actual[i])-Int(first[i]))
                            + 0.7152*Double(Int(actual[i+1])-Int(first[i+1]))
                            + 0.0722*Double(Int(actual[i+2])-Int(first[i+2]))
                        if temporal > 1 { phaseLight += 1 }; if temporal < -1 { phaseShade += 1 }
                    }
                }}
                temporalLight=max(temporalLight,phaseLight); temporalShade=max(temporalShade,phaseShade)
                let floats = bytes(output,float:true)
                let finiteBounded = floats.withUnsafeBytes { raw -> Bool in
                    raw.bindMemory(to: Float.self).allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }
                }
                expect(protectedChanges == 0,"\(choice.resourceName) phase \(phase) protected RGB changed \(protectedChanges)")
                expect(alphaChanges == 0,"\(choice.resourceName) original alpha changed")
                expect(maxDelta <= 20 && finiteBounded,"\(choice.resourceName) bounded finite color response")
                expect(lit > 1000 && shaded > 1000,"\(choice.resourceName) must contain both illuminated and shaded regions")
                print("\(choice.resourceName) phase=\(phase) protected=\(protectedChanges) alpha=\(alphaChanges) maxDelta=\(maxDelta) lit=\(lit) shade=\(shaded) temporalWitness=\(phaseLight)/\(phaseShade)")
                sceneRows.append(["seconds":phase,"protectedChanges":protectedChanges,"alphaChanges":alphaChanges,
                    "maximumRGBDelta":maxDelta,"finiteBounded":finiteBounded,"litPixels":lit,"shadedPixels":shaded,
                    "frameColorSpace":frameTag,"frameBytesMatch":frameBytesMatch,
                    "environmentTemporalLightPixels":phaseLight,"environmentTemporalShadePixels":phaseShade])
            }
            expect(temporalLight > 1000 && temporalShade > 1000,
                   "\(choice.resourceName) environment witnesses must show temporal light AND shadow variation")
            let screen=NotchScreenDescriptor(frame:CGRect(x:0,y:0,width:1512,height:982),topInset:32,
                auxiliaryTopLeft:CGRect(x:0,y:950,width:664,height:32),
                auxiliaryTopRight:CGRect(x:849,y:950,width:663,height:32))
            let layout=NotchPanelGeometry.layout(on:screen)
            let frame=NotchSceneArtwork.imageFrame(imageSize:CGSize(width:w,height:h),choice:choice,layout:layout)
            records.append(["scene":choice.resourceName,"phases":sceneRows,
                "notchLogicalSize":[layout.expandedSize.width,layout.expandedSize.height],
                "notchCharacterWidth":layout.characterRegionWidth,
                "notchSourceFrame":[frame.minX,frame.minY,frame.width,frame.height],
                "protectedTopLeftRectangles":protected.map { [$0.minX,$0.minY,$0.width,$0.height] },
                "environmentWitnesses":witnesses.map { [$0.minX,$0.minY,$0.width,$0.height] }])
        }
        // A coordinate witness with asymmetric texture and alpha. A color-only response cannot
        // move a bright/dark checker boundary; no texture/gradient matching hides displacement.
        var pattern=[UInt8](repeating:0,count:64*64*4)
        for y in 0..<64 { for x in 0..<64 {
            let i=(y*64+x)*4, alpha=UInt8(100+(x+y)%156), bright=(x/5+y/7)%2 == 0
            for c in 0..<3 { pattern[i+c]=bright ? alpha : 0 }; pattern[i+3]=alpha
        }}
        let synthetic=CIImage(bitmapData:Data(pattern),bytesPerRow:256,size:CGSize(width:64,height:64),
                              format:.RGBA8,colorSpace:nil)
        for choice in NotchSceneChoice.allCases {
            let rendered=bytes(renderer.output(source:synthetic,choice:choice,seconds:5)!)
            let fixed=(0..<(64*64)).allSatisfy { p in
                let i=p*4
                return rendered[i+3]==pattern[i+3]
                    && (Int(rendered[i])*2 > Int(rendered[i+3])) == (pattern[i] > 0)
            }
            expect(fixed,"\(choice.resourceName) asymmetric source coordinates and nonopaque alpha remain fixed")
        }
        for blocked in 0..<5 {
            expect(!NotchArtworkSceneLight.eligible(visible:blocked != 0,sharpRevealed:blocked != 1,
                available:blocked != 2,reduceMotion:blocked == 3,lowPower:blocked == 4),
                "each visibility/reveal/availability/motion/power gate independently stops frame work")
        }
        expect(NotchArtworkSceneLight.eligible(visible:true,sharpRevealed:true,available:true,
            reduceMotion:false,lowPower:false),"fully eligible artwork may animate")
        runNotchSceneClockRegression(expect:expect)
        try runNotchArtworkExpressionRegression(renderer: renderer, resourceRoot: resourceRoot,
                                               outputFolder: outputFolder, expect: expect)
        try runNotchArtworkHairMotionRegression(renderer: renderer, resourceRoot: resourceRoot,
                                               outputFolder: outputFolder, expect: expect)
        let report: [String:Any] = ["device":MTLCreateSystemDefaultDevice()?.name ?? "unavailable",
            "renderer":"Metal-backed Core Image composition: color-only light, authored expressions and bounded inset hair sampling",
            "scenes":records,"failures":failures,
            "limits":"Authored decorative modulation, not physical relighting. Offscreen output is not native visibility or naturalness acceptance."]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
            .write(to:outputFolder.appendingPathComponent("scene-light-evidence.json"))
    } catch { expect(false,"evidence/render error: \(error)") }
    print("notch-scene-lighting: \(failures.isEmpty ? "PASS" : "FAIL") (\(failures.count) failures)")
    return failures.isEmpty ? 0 : 1
}
