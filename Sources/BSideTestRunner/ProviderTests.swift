// BSideTestRunner — OfficialAssetProvider suites against synthetic fixtures
// (never the real official tree: tests run on any machine; the official folder stays read-only).

import Foundation
import CoreGraphics
import Darwin
import BSideCore
import BSidePlatform

enum ProviderFixture {
    /// Build the official 0.0.9.627 layout with empty placeholder files (provider reads names and metadata only).
    static func makeOfficialLayout(root: URL, version: String = "0.0.9.627") throws {
        let presence = root.appendingPathComponent("\(version)/assets/Wallpaper_Presence", isDirectory: true)
        let ambience = root.appendingPathComponent("\(version)/assets/Wallpaper_Ambience", isDirectory: true)
        try FileManager.default.createDirectory(at: presence, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ambience, withIntermediateDirectories: true)

        var names: [String] = []
        for scene in ["A", "B", "C"] {
            for outfit in ["R1", "R2", "R3"] {
                for time in ["1200", "1730", "2000"] {
                    names.append("\(scene)_\(outfit)_\(time).mp4")
                }
            }
        }
        for scene in ["A", "B", "C"] {
            for (from, to) in [("1200", "1730"), ("1730", "2000"), ("2000", "1200")] {
                names.append("\(scene)_Transition_\(from)_\(to).mp4")
            }
        }
        for name in names { try Data().write(to: presence.appendingPathComponent(name)) }
        for i in 1...22 { try Data().write(to: ambience.appendingPathComponent("ambient_loop_\(i).mp3")) }
        // One unrecognized file must land in unknownFiles.
        try Data().write(to: presence.appendingPathComponent("weird_bonus_file.dat"))
    }

    static func freshTempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bsidemac-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func setModificationTime(_ file: URL, seconds: Int, nanoseconds: Int) throws {
        var times = [timespec(tv_sec: seconds, tv_nsec: nanoseconds),
                     timespec(tv_sec: seconds, tv_nsec: nanoseconds)]
        guard utimensat(AT_FDCWD, file.path, &times, 0) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    static func withPermissions(_ permissions: Int, at url: URL, _ body: () throws -> Void) throws {
        let fm = FileManager.default
        guard let original = try fm.attributesOfItem(atPath: url.path)[.posixPermissions] else {
            throw NSError(domain: "ProviderFixture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot retain fixture permissions for restoration"])
        }
        try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        defer { try? fm.setAttributes([.posixPermissions: original], ofItemAtPath: url.path) }
        try body()
    }

    /// Apply only to a freshly created fixture file. Its temporary ACL denies metadata reads
    /// while the parent directory remains fully accessible, reaching the per-file read path.
    static func withMetadataDenied(at url: URL, _ body: () throws -> Void) throws {
        func chmod(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/chmod")
            process.arguments = arguments + [url.path]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw NSError(domain: "ProviderFixture", code: Int(process.terminationStatus),
                              userInfo: [NSLocalizedDescriptionKey: "Cannot change fixture metadata permissions"])
            }
        }
        try chmod(["+a", "everyone deny readattr"])
        defer { try? chmod(["-N"]) }
        try body()
    }
}

func runProviderTests() {
    run("Provider.officialLayoutMapsFully") { t in
        do {
            let root = try ProviderFixture.freshTempRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            try ProviderFixture.makeOfficialLayout(root: root)
            let bundle = try OfficialAssetProvider(assetPath: root.path).loadCatalog()

            t.expectEqual(bundle.catalog.loops.count, 24, "27 official loop files minus 3 product exclusions")
            t.expectEqual(bundle.catalog.transitions.count, 9, "9 transitions")
            t.expectEqual(bundle.catalog.ambientTracks.count, 22, "22 ambient")
            t.expectEqual(bundle.catalog.unknownFiles, ["weird_bonus_file.dat"], "unknown file captured")
            t.expectEqual(bundle.catalog.sourceLabel, "0.0.9.627", "source label = version dir")

            let loopID = bundle.catalog.loop(for: ContentKey(scene: .a, outfit: .r1, time: .noon))
            t.expectEqual(loopID, ContentID("loop://A/R1/1200"), "loop id")
            let url = loopID.flatMap { bundle.url(for: $0) }
            t.expectEqual(url?.lastPathComponent, "A_R1_1200.mp4", "url mapped")
            t.expect(url.map { FileManager.default.fileExists(atPath: $0.path) } == true, "file exists")

            let transition = bundle.catalog.transition(scene: .b, from: .evening, to: .night)
            t.expectEqual(transition, ContentID("transition://B/1730->2000"), "transition id")
            t.expectEqual(bundle.catalog.ambientTracks.first?.label, "ambient_loop_1.mp3", "ambient sorted")
            let knownIDs = Set(bundle.catalog.loops.values).union(bundle.catalog.transitions.values)
                .union(bundle.catalog.ambientTracks.map(\.id))
            t.expectEqual(Set(bundle.sourceVersions.keys), knownIDs, "only known media receives a source version")
        } catch {
            t.expect(false, "unexpected throw: \(error)")
        }
    }

    run("Provider.productExcludedLoopsAreNotAdmitted") { t in
        do {
            let root = try ProviderFixture.freshTempRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            try ProviderFixture.makeOfficialLayout(root: root)
            let bundle = try OfficialAssetProvider(assetPath: root.path).loadCatalog()

            let excluded: [ContentKey] = [
                ContentKey(scene: .b, outfit: .r1, time: .evening),
                ContentKey(scene: .b, outfit: .r1, time: .night),
                ContentKey(scene: .c, outfit: .r1, time: .evening),
            ]
            t.expectEqual(OfficialAssetProvider.productExcludedLoopKeys, Set(excluded),
                          "exactly the three confirmed combinations are excluded")
            t.expectEqual(OfficialAssetProvider.productExcludedLoopKeys.count, 3, "no additional exclusions")

            for key in excluded {
                let id = ContentID("loop://\(key.scene.rawValue)/\(key.outfit.rawValue)/\(key.time.rawValue)")
                let filename = "\(key.scene.rawValue)_\(key.outfit.rawValue)_\(key.time.rawValue).mp4"
                t.expectNil(bundle.catalog.loop(for: key), "excluded key has no catalog entry: \(key)")
                t.expectNil(bundle.url(for: id), "excluded key exposes no URL: \(key)")
                t.expectNil(bundle.sourceVersions[id], "excluded key receives no source version: \(key)")
                t.expect(!bundle.catalog.unknownFiles.contains(filename),
                         "excluded file is not reported as unrecognized: \(key)")
                // The official file is untouched on disk; only admission is withheld.
                let file = root.appendingPathComponent("0.0.9.627/assets/Wallpaper_Presence/\(filename)")
                t.expect(FileManager.default.fileExists(atPath: file.path),
                         "official file is preserved on disk: \(filename)")
            }

            // Neighboring combinations (same scene/outfit at another time, other outfits, other
            // scenes) stay admitted: this is not a blanket B/C or official-distribution verdict.
            let preserved: [ContentKey] = [
                ContentKey(scene: .a, outfit: .r1, time: .noon),
                ContentKey(scene: .a, outfit: .r1, time: .evening),
                ContentKey(scene: .a, outfit: .r1, time: .night),
                ContentKey(scene: .b, outfit: .r1, time: .noon),
                ContentKey(scene: .b, outfit: .r2, time: .evening),
                ContentKey(scene: .b, outfit: .r2, time: .night),
                ContentKey(scene: .c, outfit: .r1, time: .noon),
                ContentKey(scene: .c, outfit: .r1, time: .night),
                ContentKey(scene: .c, outfit: .r2, time: .evening),
            ]
            for key in preserved {
                let id = ContentID("loop://\(key.scene.rawValue)/\(key.outfit.rawValue)/\(key.time.rawValue)")
                t.expectNotNil(bundle.catalog.loop(for: key), "neighboring key remains supported: \(key)")
                t.expectNotNil(bundle.url(for: id), "neighboring key keeps its URL: \(key)")
                t.expectNotNil(bundle.sourceVersions[id], "neighboring key keeps its source version: \(key)")
            }

            // Fixed and automatic intent both follow the admitted catalog.
            let fixedExcluded = ContentResolver.resolve(
                currentKey: nil,
                desired: DesiredState(scene: .b, outfit: .r1, timeMode: .fixed(.evening)),
                catalog: bundle.catalog, minuteOfDay: 720)
            t.expect(!fixedExcluded.isPlayable && fixedExcluded.loop == nil,
                     "a saved fixed excluded selection resolves unavailable")
            t.expectEqual(fixedExcluded.targetKey, ContentKey(scene: .b, outfit: .r1, time: .evening),
                          "the unavailable target is reported, not silently replaced")

            let autoEvening = ContentResolver.resolve(
                currentKey: nil,
                desired: DesiredState(scene: .b, outfit: .r1, timeMode: .auto),
                catalog: bundle.catalog, minuteOfDay: TimeOfDay.evening.minuteOfDay)
            t.expect(!autoEvening.isPlayable && autoEvening.loop == nil,
                     "automatic evening must not load the excluded B/R1 loop")
            let autoNight = ContentResolver.resolve(
                currentKey: nil,
                desired: DesiredState(scene: .b, outfit: .r1, timeMode: .auto),
                catalog: bundle.catalog, minuteOfDay: TimeOfDay.night.minuteOfDay)
            t.expect(!autoNight.isPlayable && autoNight.loop == nil,
                     "automatic night must not load the excluded B/R1 loop")
            let autoNoon = ContentResolver.resolve(
                currentKey: nil,
                desired: DesiredState(scene: .b, outfit: .r1, timeMode: .auto),
                catalog: bundle.catalog, minuteOfDay: TimeOfDay.noon.minuteOfDay)
            t.expect(autoNoon.isPlayable, "automatic noon still resolves the admitted B/R1 loop")
            let autoA = ContentResolver.resolve(
                currentKey: nil,
                desired: DesiredState(scene: .a, outfit: .r1, timeMode: .auto),
                catalog: bundle.catalog, minuteOfDay: TimeOfDay.night.minuteOfDay)
            t.expect(autoA.isPlayable, "A keys retain their full automatic coverage")
        } catch {
            t.expect(false, "product exclusion fixture failed: \(error)")
        }
    }

    run("Provider.loopFileURLLookupIsExactForAdmittedKeysOnly") { t in
        do {
            let root = try ProviderFixture.freshTempRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            try ProviderFixture.makeOfficialLayout(root: root)
            let bundle = try OfficialAssetProvider(assetPath: root.path).loadCatalog()
            let presence = root.appendingPathComponent("0.0.9.627/assets/Wallpaper_Presence",
                                                       isDirectory: true)

            // The lookup is the exact inverse of the catalog grammar: an admitted key resolves to
            // the same file discovery recorded, never to another combination.
            for key in [ContentKey(scene: .a, outfit: .r1, time: .noon),
                        ContentKey(scene: .c, outfit: .r3, time: .night)] {
                let id = ContentID("loop://\(key.scene.rawValue)/\(key.outfit.rawValue)/\(key.time.rawValue)")
                t.expectEqual(bundle.loopFileURL(for: key), bundle.url(for: id),
                              "an admitted key must resolve the file discovery recorded: \(key)")
                t.expectEqual(bundle.loopFileURL(for: key)?.deletingLastPathComponent()
                                  .resolvingSymlinksInPath().path,
                              presence.resolvingSymlinksInPath().path,
                              "the resolved preview file must live in the bound presence directory: \(key)")
            }
            // Excluded keys expose no preview target at all.
            for key in [ContentKey(scene: .b, outfit: .r1, time: .evening),
                        ContentKey(scene: .b, outfit: .r1, time: .night),
                        ContentKey(scene: .c, outfit: .r1, time: .evening)] {
                t.expectNil(bundle.loopFileURL(for: key),
                            "a product-excluded combination must expose no preview file: \(key)")
            }
            // A combination that was admitted at load time but is now gone from disk must not
            // silently resolve to a neighbor.
            let absentKey = ContentKey(scene: .a, outfit: .r2, time: .noon)
            let missingRoot = try ProviderFixture.freshTempRoot()
            defer { try? FileManager.default.removeItem(at: missingRoot) }
            try ProviderFixture.makeOfficialLayout(root: missingRoot)
            let missingFile = missingRoot.appendingPathComponent(
                "0.0.9.627/assets/Wallpaper_Presence/A_R2_1200.mp4")
            try FileManager.default.removeItem(at: missingFile)
            let missingBundle = try OfficialAssetProvider(assetPath: missingRoot.path).loadCatalog()
            t.expectNil(missingBundle.loopFileURL(for: absentKey),
                        "a combination missing from disk must expose no preview file")
        } catch {
            t.expect(false, "loop-file lookup fixture failed: \(error)")
        }
    }

    run("DailyPreview.requestIsBounded") { t in
        let key = ContentKey(scene: .a, outfit: .r1, time: .noon)
        let url = URL(fileURLWithPath: "/tmp/does-not-need-to-exist.mp4")
        let negative = DailyPreviewRequest(key: key, loopURL: url, atSeconds: -10, maximumPixelSize: 100_000)
        t.expectEqual(negative.atSeconds, 0, "a negative frame position must be clamped to the start")
        t.expectEqual(negative.maximumPixelSize, DailyPreview.maximumPreviewPixelSize,
                      "a thumbnail can never request more than the product maximum")
        let huge = DailyPreviewRequest(key: key, loopURL: url, atSeconds: 1e12)
        t.expectEqual(huge.atSeconds, DailyPreview.maximumFrameSeconds,
                      "a non-finite or absurd frame position must stay bounded")
        let tiny = DailyPreviewRequest(key: key, loopURL: url, maximumPixelSize: 1)
        t.expectEqual(tiny.maximumPixelSize, 32, "a degenerate thumbnail size must stay usable")
        let normal = DailyPreviewRequest(key: key, loopURL: url, atSeconds: 5, maximumPixelSize: 640)
        t.expectEqual(normal.atSeconds, 5, "an ordinary request keeps its chosen frame position")
        t.expectEqual(normal.maximumPixelSize, 640, "an ordinary request keeps its chosen size")
        let defaulted = DailyPreviewRequest(key: key, loopURL: url)
        t.expectEqual(defaulted.pixelSize, DailyPreview.defaultPreviewPixelSize,
                      "the default request uses the bounded product pixel size")
        let small = DailyPreviewRequest(key: key, loopURL: url,
                                        pixelSize: DailyPreviewPixelSize(width: 960, height: 440))
        let large = DailyPreviewRequest(key: key, loopURL: url,
                                        pixelSize: DailyPreviewPixelSize(width: 1920, height: 880))
        t.expectEqual(small, small, "identical preview requests stay equal")
        t.expect(small != large,
                 "request identity must include the requested pixel size, so a resize cannot reuse it")
        t.expectEqual(large.pixelSize, DailyPreviewPixelSize(width: 1440, height: 880),
                      "a request larger than the product cap is bounded before it reaches the generator")
        let service = DailyPreview(deadlineSeconds: 0.05)
        t.expect(!service.isBusy, "a fresh preview service owns no request")
        service.cancel()
        t.expect(!service.isBusy, "cancelling an idle preview service is safe and inert")
        let outcome = DailyPreviewOutcome.unavailable(key, "预览暂不可用。")
        t.expectNil(outcome.data, "an unavailable outcome carries no image data")
        t.expectEqual(outcome.failure, "预览暂不可用。", "an unavailable outcome states its reason")
    }

    run("DailyPreview.pixelBoundsFollowRenderedContainerAndScale") { t in
        // The real chooser container is ~480x220 pt inside its sheet; the device pixels it needs
        // follow the display backing scale, not a fixed product constant.
        t.expectEqual(
            DailyPreviewPixelSize.forRenderedContainer(size: CGSize(width: 480, height: 220), scale: 2),
            DailyPreviewPixelSize(width: 960, height: 440),
            "a 2x 480x220 container must request 960x440 device pixels")
        t.expectEqual(
            DailyPreviewPixelSize.forRenderedContainer(size: CGSize(width: 480, height: 220), scale: 1),
            DailyPreviewPixelSize(width: 480, height: 220),
            "the same container on a 1x display needs half the pixels")
        t.expectEqual(
            DailyPreviewPixelSize.forRenderedContainer(size: CGSize(width: 100, height: 400), scale: 2),
            DailyPreviewPixelSize(width: 200, height: 800),
            "a narrow/tall container keeps its own pixel bounds")
        let wide = DailyPreviewPixelSize.forRenderedContainer(size: CGSize(width: 900, height: 50), scale: 2)
        t.expect(wide.width == DailyPreviewPixelSize.maximumEdge && wide.height == 100,
                 "a very wide container is edge-capped instead of requesting an unbounded bitmap")

        // Invalid geometry is defensive: never a trap, never a zero-sized request.
        for invalid in [CGSize(width: 0, height: 220), CGSize(width: -480, height: 220),
                        CGSize(width: CGFloat.infinity, height: 220), CGSize(width: CGFloat.nan, height: 220)] {
            t.expectEqual(
                DailyPreviewPixelSize.forRenderedContainer(size: invalid, scale: 2),
                DailyPreviewPixelSize(width: 32, height: 32),
                "invalid container geometry falls back to the usable minimum")
        }
        for invalidScale in [CGFloat(0), CGFloat(-2), CGFloat.nan, CGFloat.infinity] {
            t.expectEqual(
                DailyPreviewPixelSize.forRenderedContainer(
                    size: CGSize(width: 480, height: 220), scale: invalidScale),
                DailyPreviewPixelSize(width: 32, height: 32),
                "invalid backing scale falls back to the usable minimum")
        }

        // Each axis and the scale are rejected individually: a negative container size must never
        // be rescued by multiplying it by a negative scale into a positive pixel demand, and a
        // nonpositive scale is invalid regardless of the container.
        let negativeGeometry: [(CGSize, CGFloat)] = [
            (CGSize(width: -480, height: -220), CGFloat(-2)),
            (CGSize(width: -480, height: 220), CGFloat(-2)),
            (CGSize(width: 480, height: -220), CGFloat(-2)),
            (CGSize(width: -480, height: -220), CGFloat(2)),
            (CGSize(width: -1, height: -1), CGFloat(-1)),
        ]
        for (invalidSize, invalidScale) in negativeGeometry {
            t.expectEqual(
                DailyPreviewPixelSize.forRenderedContainer(size: invalidSize, scale: invalidScale),
                DailyPreviewPixelSize(width: 32, height: 32),
                "a negative container axis and/or a nonpositive scale must be rejected individually")
        }
        t.expectEqual(
            DailyPreviewPixelSize.forRenderedContainer(size: CGSize(width: 0, height: 0), scale: 1),
            DailyPreviewPixelSize(width: 32, height: 32),
            "a zero container stays at the usable minimum, never a zero-sized request")

        // A hostile container cannot overflow the pixel demand; the total-pixel budget holds.
        let huge = DailyPreviewPixelSize.forRenderedContainer(
            size: CGSize(width: 1e9, height: 1e9), scale: 2)
        t.expect(huge.longestEdge <= DailyPreviewPixelSize.maximumEdge
                 && huge.width * huge.height <= DailyPreviewPixelSize.maximumPixelCount,
                 "an absurd container stays inside the bounded product pixel budget")
    }

    run("DailyPreview.pixelBoundsNeverUpscaleBeyondSource") { t in
        let requested = DailyPreviewPixelSize(width: 960, height: 440)
        t.expectEqual(requested.capped(toSourceTransformedPixelSize: CGSize(width: 2560, height: 1440)),
                      requested,
                      "a source larger than the request leaves the request unchanged")
        t.expectEqual(requested.capped(toSourceTransformedPixelSize: CGSize(width: 1280, height: 720)),
                      requested,
                      "a 1280x720 source still covers the 960x440 request")
        t.expectEqual(requested.capped(toSourceTransformedPixelSize: CGSize(width: 320, height: 200)),
                      DailyPreviewPixelSize(width: 320, height: 200),
                      "a small source is capped to its own pixels, never enlarged")
        t.expectEqual(requested.capped(toSourceTransformedPixelSize: nil), requested,
                      "unknown source evidence leaves the request unchanged")
        t.expectEqual(requested.capped(toSourceTransformedPixelSize: CGSize(width: 0, height: 0)), requested,
                      "invalid source evidence leaves the request unchanged")
        let belowMinimum = requested.capped(toSourceTransformedPixelSize: CGSize(width: 16, height: 16))
        t.expect(belowMinimum.width == 16 && belowMinimum.height == 16,
                 "a below-minimum source still wins: no upscale, even under the product minimum")
        let fractional = requested.capped(toSourceTransformedPixelSize: CGSize(width: 500.9, height: 400.2))
        t.expect(fractional.width == 500 && fractional.height == 400,
                 "a fractional source size is floored, never rounded up into an enlargement")
    }

    run("DailyPreview.stillIsLosslessPNGWithExactDimensions") { t in
        // Synthetic 7x3 fixture only; no official media is read or written.
        let width = 7
        let height = 3
        let byteCount = width * height * 4
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: byteCount)
        defer { buffer.deallocate() }
        for index in 0..<(width * height) {
            buffer[index * 4 + 0] = UInt8((index * 37) % 256)
            buffer[index * 4 + 1] = UInt8((index * 61) % 256)
            buffer[index * 4 + 2] = UInt8((index * 83) % 256)
            buffer[index * 4 + 3] = 255
        }
        guard let context = CGContext(data: buffer, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = context.makeImage() else {
            t.expect(false, "the synthetic CGImage fixture must be creatable")
            return
        }
        guard let png = DailyPreview.pngData(from: image) else {
            t.expect(false, "a valid CGImage must encode to PNG data")
            return
        }
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        t.expect(png.count > 24 && Array(png.prefix(8)) == signature,
                 "the still must be a real PNG stream")
        t.expect(!(png.count > 3 && Array(png.prefix(3)) == [0xFF, 0xD8, 0xFF]),
                 "the lossy JPEG path must be gone")
        let bytes = [UInt8](png)
        t.expectEqual(String(decoding: bytes[12..<16], as: UTF8.self), "IHDR",
                      "a PNG must begin with its IHDR chunk")
        func bigEndian(_ range: Range<Int>) -> Int {
            bytes[range].reduce(0) { ($0 << 8) | Int($1) }
        }
        t.expectEqual(bigEndian(16..<20), width, "the PNG must carry the real image width")
        t.expectEqual(bigEndian(20..<24), height, "the PNG must carry the real image height")
    }

    run("Provider.sourceVersionsDetectReplacementAndInPlaceChanges") { t in
        do {
            let root = try ProviderFixture.freshTempRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            try ProviderFixture.makeOfficialLayout(root: root)
            let provider = OfficialAssetProvider(assetPath: root.path)
            let file = root.appendingPathComponent("0.0.9.627/assets/Wallpaper_Presence/A_R1_1200.mp4")
            let id = ContentID("loop://A/R1/1200")
            let otherID = ContentID("ambient://1")
            let originalBytes = Data("owned-first".utf8)
            let replacementBytes = Data("owned-other".utf8)
            try originalBytes.write(to: file)
            try ProviderFixture.setModificationTime(file, seconds: 1_700_000_000, nanoseconds: 123_000_000)
            let before = try provider.loadCatalog()
            guard let original = before.sourceVersions[id] else {
                t.expect(false, "known loop has a source version")
                return
            }

            // Pin the original inode while atomically replacing the same path and size.
            let retained = root.appendingPathComponent("retained-source")
            try FileManager.default.linkItem(at: file, to: retained)
            try replacementBytes.write(to: file, options: .atomic)
            try ProviderFixture.setModificationTime(file, seconds: Int(original.modificationSeconds),
                                                    nanoseconds: Int(original.modificationNanoseconds))
            let replacedBundle = try provider.loadCatalog()
            guard let replaced = replacedBundle.sourceVersions[id] else {
                t.expect(false, "replacement remains known media")
                return
            }
            t.expectEqual(replaced.physicalURL, original.physicalURL, "atomic replacement retains the physical path")
            t.expectEqual(replaced.byteSize, original.byteSize, "replacement has the same size")
            t.expectEqual(replaced.modificationSeconds, original.modificationSeconds, "replacement preserves mtime seconds")
            t.expectEqual(replaced.modificationNanoseconds, original.modificationNanoseconds, "replacement preserves mtime nanoseconds")
            t.expect(replaced.inode != original.inode, "replacement is a different inode")
            t.expect(!replaced.hasSameMedia(as: original), "same path and size do not hide a replacement")
            t.expectEqual(replacedBundle.sourceVersions[otherID], before.sourceVersions[otherID], "unrelated ambience stays unchanged")
            t.expectEqual(try Data(contentsOf: retained), originalBytes, "the replaced inode still contains the original bytes")

            let handle = try FileHandle(forWritingTo: file)
            try handle.write(contentsOf: originalBytes)
            try handle.close()
            try ProviderFixture.setModificationTime(file, seconds: Int(replaced.modificationSeconds),
                                                    nanoseconds: Int(replaced.modificationNanoseconds))
            guard let rewritten = try provider.loadCatalog().sourceVersions[id] else {
                t.expect(false, "in-place rewrite remains known media")
                return
            }
            t.expectEqual(rewritten.inode, replaced.inode, "in-place rewrite retains the inode")
            t.expectEqual(rewritten.byteSize, replaced.byteSize, "in-place rewrite retains the size")
            t.expectEqual(rewritten.modificationSeconds, replaced.modificationSeconds, "in-place rewrite restores mtime seconds")
            t.expectEqual(rewritten.modificationNanoseconds, replaced.modificationNanoseconds, "in-place rewrite restores mtime nanoseconds")
            t.expect(rewritten.changeSeconds != replaced.changeSeconds || rewritten.changeNanoseconds != replaced.changeNanoseconds,
                     "ctime records the same-inode rewrite even after restoring mtime")
            t.expect(!rewritten.hasSameMedia(as: replaced), "restored size and mtime do not hide this in-place rewrite")

            try ProviderFixture.setModificationTime(file, seconds: Int(rewritten.modificationSeconds), nanoseconds: 124_000_000)
            guard let touched = try provider.loadCatalog().sourceVersions[id] else {
                t.expect(false, "mtime-only change remains known media")
                return
            }
            t.expectEqual(touched.modificationSeconds, rewritten.modificationSeconds, "mtime change remains within the same second")
            t.expectEqual(touched.modificationNanoseconds, 124_000_000, "subsecond mtime is retained without Date rounding")
            t.expect(!touched.hasSameMedia(as: rewritten), "subsecond metadata change produces a different version")
            t.expectEqual(before.sourceVersions[id], original, "previous bundle retains its immutable source version")
        } catch { t.expect(false, "source version fixture failed: \(error)") }
    }

    run("Provider.sourceVersionsSeparateRelocationAndUnknownFiles") { t in
        do {
            let root = try ProviderFixture.freshTempRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            try ProviderFixture.makeOfficialLayout(root: root)
            let version = root.appendingPathComponent("0.0.9.627", isDirectory: true)
            let before = try OfficialAssetProvider(assetPath: version.path).loadCatalog()
            let unknown = version.appendingPathComponent("assets/Wallpaper_Presence/owner-notes.txt")
            try Data("unrecognized fixture notes".utf8).write(to: unknown)
            let added = try OfficialAssetProvider(assetPath: version.path).loadCatalog()
            t.expect(added.catalog.unknownFiles.contains(unknown.lastPathComponent), "new unknown file is still reported")
            t.expectEqual(added.sourceVersions, before.sourceVersions, "unknown additions do not dirty known media")
            try Data("changed fixture notes".utf8).write(to: unknown)
            let edited = try OfficialAssetProvider(assetPath: version.path).loadCatalog()
            t.expectEqual(edited.sourceVersions, before.sourceVersions, "unknown modifications do not dirty known media")

            let moved = root.appendingPathComponent("moved-library", isDirectory: true)
            try FileManager.default.moveItem(at: version, to: moved)
            let after = try OfficialAssetProvider(assetPath: moved.path).loadCatalog()
            t.expectEqual(Set(after.sourceVersions.keys), Set(before.sourceVersions.keys), "relocation preserves known identities")
            for (id, original) in before.sourceVersions {
                guard let relocated = after.sourceVersions[id] else { continue }
                t.expect(relocated != original, "relocation changes the full source location for \(id)")
                t.expect(relocated.hasSameMedia(as: original), "parent relocation preserves the media version for \(id)")
                t.expect(FileManager.default.fileExists(atPath: relocated.physicalURL.path), "new physical URL is usable for \(id)")
                t.expect(!FileManager.default.fileExists(atPath: original.physicalURL.path), "previous physical URL no longer exists for \(id)")
            }
        } catch { t.expect(false, "source relocation fixture failed: \(error)") }
    }

    run("Provider.directLayoutWithoutVersionDirAccepted") { t in
        do {
            let root = try ProviderFixture.freshTempRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            try ProviderFixture.makeOfficialLayout(root: root)
            // Flatten: move assets/ to root (tolerated for extracted builds).
            let versionDir = root.appendingPathComponent("0.0.9.627", isDirectory: true)
            try FileManager.default.moveItem(
                at: versionDir.appendingPathComponent("assets"),
                to: root.appendingPathComponent("assets"))
            try FileManager.default.removeItem(at: versionDir)

            let bundle = try OfficialAssetProvider(assetPath: root.path).loadCatalog()
            t.expectEqual(bundle.catalog.loops.count, 24, "admitted loops after product exclusions")
        } catch {
            t.expect(false, "unexpected throw: \(error)")
        }
    }

    run("Provider.selectedAssetsOrPresenceDirectoryAccepted") { t in
        do {
            let root = try ProviderFixture.freshTempRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            try ProviderFixture.makeOfficialLayout(root: root)
            let assets = root.appendingPathComponent("0.0.9.627/assets", isDirectory: true)
            for selected in [assets, assets.appendingPathComponent("Wallpaper_Presence", isDirectory: true)] {
                let bundle = try OfficialAssetProvider(assetPath: selected.path).loadCatalog()
                t.expectEqual(bundle.catalog.loops.count, 24, "\(selected.lastPathComponent): all admitted loops")
                t.expectEqual(bundle.catalog.transitions.count, 9, "\(selected.lastPathComponent): transitions")
                t.expectEqual(bundle.catalog.ambientTracks.count, 22, "\(selected.lastPathComponent): sibling ambience")
                t.expectEqual(bundle.catalog.sourceLabel, "0.0.9.627", "source label remains the version")
                let loop = bundle.catalog.loop(for: ContentKey(scene: .a, outfit: .r1, time: .noon))
                // FileManager enumeration and temporaryDirectory can use different /var aliases.
                t.expectEqual(loop.flatMap { bundle.url(for: $0)?.resolvingSymlinksInPath().path },
                              assets.appendingPathComponent("Wallpaper_Presence/A_R1_1200.mp4")
                                .resolvingSymlinksInPath().path,
                              "selection resolves the same media URL")
            }
        } catch {
            t.expect(false, "unexpected throw: \(error)")
        }
    }

    run("Provider.multipleCompleteVersionsRequireExplicitSelection") { t in
        do {
            let root = try ProviderFixture.freshTempRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let versions = ["0.0.9.627", "0.0.10.1"]
            for version in versions { try ProviderFixture.makeOfficialLayout(root: root, version: version) }

            do {
                _ = try OfficialAssetProvider(assetPath: root.path).loadCatalog()
                t.expect(false, "multiple valid versions must not be silently chosen")
            } catch AssetValidationError.ambiguousLayouts(let paths) {
                let expected = versions.map { root.appendingPathComponent($0).resolvingSymlinksInPath().path }.sorted()
                let resolved = paths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }.sorted()
                t.expectEqual(resolved, expected, "ambiguity carries the valid candidate paths")
                t.expectEqual(paths, paths.sorted(), "candidate paths have stable ordering")
                let description = AssetValidationError.ambiguousLayouts(paths).description
                t.expect(description.contains("Select a specific version folder"), "error explains how to resolve it")
                t.expect(description.hasSuffix(paths.joined(separator: "\n")), "error lists the candidates in order")
            }

            for version in versions {
                let bundle = try OfficialAssetProvider(assetPath: root.appendingPathComponent(version).path).loadCatalog()
                t.expectEqual(bundle.catalog.sourceLabel, version, "explicit version selection is authoritative")
                t.expectEqual(bundle.catalog.loops.count, 24, "explicit version loads all its admitted loops")
            }
        } catch {
            t.expect(false, "unexpected throw: \(error)")
        }
    }

    run("Provider.incompleteNumericDirectoriesDoNotHideValidLayout") { t in
        do {
            let root = try ProviderFixture.freshTempRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let fm = FileManager.default
            try fm.createDirectory(at: root.appendingPathComponent("0.0.1"), withIntermediateDirectories: true)
            try fm.createDirectory(at: root.appendingPathComponent("0.0.2/assets"), withIntermediateDirectories: true)
            try fm.createDirectory(at: root.appendingPathComponent("0.0.3/assets"), withIntermediateDirectories: true)
            try Data().write(to: root.appendingPathComponent("0.0.3/assets/Wallpaper_Presence"))
            try Data().write(to: root.appendingPathComponent("0.0.4"))
            try ProviderFixture.makeOfficialLayout(root: root)

            let bundle = try OfficialAssetProvider(assetPath: root.path).loadCatalog()
            t.expectEqual(bundle.catalog.sourceLabel, "0.0.9.627", "only the complete directory layout is selected")
            t.expectEqual(bundle.catalog.loops.count, 24, "incomplete siblings do not obscure the valid library")
        } catch {
            t.expect(false, "unexpected throw: \(error)")
        }
    }

    run("Provider.filesCannotStandInForLayoutDirectories") { t in
        do {
            let root = try ProviderFixture.freshTempRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let impostorPaths = ["assets", "assets/Wallpaper_Presence", "0.0.9.627",
                                 "0.0.9.627/assets", "0.0.9.627/assets/Wallpaper_Presence"]
            for (index, impostorPath) in impostorPaths.enumerated() {
                let selected = root.appendingPathComponent("case-\(index)", isDirectory: true)
                let impostor = selected.appendingPathComponent(impostorPath)
                try FileManager.default.createDirectory(at: impostor.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try Data().write(to: impostor)
                do {
                    _ = try OfficialAssetProvider(assetPath: selected.path).loadCatalog()
                    t.expect(false, "file at \(impostorPath) must not form a layout")
                } catch AssetValidationError.layoutNotRecognized(let path) {
                    t.expectEqual(path, selected.path, "invalid layout is attributed to the selected root")
                }
            }
            let selectedFile = root.appendingPathComponent("Wallpaper_Presence")
            try Data().write(to: selectedFile)
            do {
                _ = try OfficialAssetProvider(assetPath: selectedFile.path).loadCatalog()
                t.expect(false, "a directly selected file must not be accepted as a folder")
            } catch AssetValidationError.notDirectory(let path) {
                t.expectEqual(path, selectedFile.path, "selected file is rejected before layout discovery")
            }
        } catch {
            t.expect(false, "unexpected throw: \(error)")
        }
    }

    run("Provider.mediaNamedDirectoriesAreNotPlayableFiles") { t in
        do {
            let root = try ProviderFixture.freshTempRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            try ProviderFixture.makeOfficialLayout(root: root)
            let assets = root.appendingPathComponent("0.0.9.627/assets", isDirectory: true)
            let mediaPaths = ["Wallpaper_Presence/A_R1_1200.mp4",
                              "Wallpaper_Presence/A_Transition_1200_1730.mp4",
                              "Wallpaper_Ambience/ambient_loop_1.mp3"]
            for mediaPath in mediaPaths {
                let file = assets.appendingPathComponent(mediaPath)
                try FileManager.default.removeItem(at: file)
                try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
            }
            let bundle = try OfficialAssetProvider(assetPath: root.path).loadCatalog()
            t.expectEqual(bundle.catalog.loops.count, 23, "directory is not a loop")
            t.expectEqual(bundle.catalog.transitions.count, 8, "directory is not a transition")
            t.expectEqual(bundle.catalog.ambientTracks.count, 21, "directory is not an ambient track")
            t.expectEqual(bundle.catalog.loop(for: ContentKey(scene: .a, outfit: .r1, time: .noon)), nil,
                          "no logical loop points at the directory")
            t.expectEqual(bundle.url(for: ContentID("ambient://1")), nil, "no ambient URL points at the directory")
        } catch {
            t.expect(false, "unexpected throw: \(error)")
        }
    }

    run("Provider.missingDirectoryThrows") { t in
        do {
            let root = try ProviderFixture.freshTempRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            do {
                _ = try OfficialAssetProvider(assetPath: root.appendingPathComponent("nope").path).loadCatalog()
                t.expect(false, "missing directory must throw")
            } catch AssetValidationError.directoryNotFound(let path) {
                t.expectEqual(path, root.appendingPathComponent("nope").path, "missing path is reported")
            }
        } catch {
            t.expect(false, "fixture creation failed or unexpected validation error: \(error)")
        }
    }

    run("Provider.mediaSymlinksRemainUnknownFiles") { t in
        do {
            let root = try ProviderFixture.freshTempRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            try ProviderFixture.makeOfficialLayout(root: root)
            let fm = FileManager.default
            let assets = root.appendingPathComponent("0.0.9.627/assets", isDirectory: true)
            let names = ["Wallpaper_Presence/A_R1_1200.mp4",
                         "Wallpaper_Presence/A_Transition_1200_1730.mp4",
                         "Wallpaper_Ambience/ambient_loop_1.mp3"]
            for (index, name) in names.enumerated() {
                let file = assets.appendingPathComponent(name)
                let target = root.appendingPathComponent("stored-media-\(index)")
                try fm.moveItem(at: file, to: target)
                try fm.createSymbolicLink(at: file, withDestinationURL: target)
            }
            let bundle = try OfficialAssetProvider(assetPath: root.path).loadCatalog()
            t.expectEqual(bundle.catalog.loops.count, 23, "media symlink does not add a loop")
            t.expectEqual(bundle.catalog.transitions.count, 8, "media symlink does not add a transition")
            t.expectEqual(bundle.catalog.ambientTracks.count, 21, "media symlink does not add ambience")
            for name in names {
                t.expect(bundle.catalog.unknownFiles.contains(URL(fileURLWithPath: name).lastPathComponent),
                         "media symlink stays in unknown files: \(name)")
            }
        } catch { t.expect(false, "media symlink fixture failed: \(error)") }
    }

    run("Provider.unrecognizedLayoutThrows") { t in
        do {
            let root = try ProviderFixture.freshTempRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let stranger = root.appendingPathComponent("random-app", isDirectory: true)
            try FileManager.default.createDirectory(at: stranger.appendingPathComponent("bin"), withIntermediateDirectories: true)
            t.expectThrows("layoutNotRecognized") {
                _ = try OfficialAssetProvider(assetPath: stranger.path).loadCatalog()
            }
        } catch {
            t.expect(false, "unexpected throw: \(error)")
        }
    }

    run("Provider.emptyPresenceThrowsNoContent") { t in
        do {
            let root = try ProviderFixture.freshTempRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let presence = root.appendingPathComponent("0.0.9.627/assets/Wallpaper_Presence", isDirectory: true)
            try FileManager.default.createDirectory(at: presence, withIntermediateDirectories: true)
            t.expectThrows("noContentFound") {
                _ = try OfficialAssetProvider(assetPath: root.path).loadCatalog()
            }
            let refreshed = try OfficialAssetProvider(assetPath: root.path).loadCatalog(allowEmptyLoops: true)
            t.expect(refreshed.catalog.loops.isEmpty, "explicit background refresh can publish no loops")
            t.expect(refreshed.sourceVersions.isEmpty, "empty refresh does not invent source versions")
            try FileManager.default.removeItem(at: presence)
            t.expectThrows("empty refresh still requires a recognized layout") {
                _ = try OfficialAssetProvider(assetPath: root.path).loadCatalog(allowEmptyLoops: true)
            }
        } catch {
            t.expect(false, "unexpected throw: \(error)")
        }
    }

    run("Provider.directoryPermissionFailuresRemainAccessDenied") { t in
        guard geteuid() != 0 else {
            print("      SKIP — root bypasses directory permission checks")
            return
        }
        do {
            let root = try ProviderFixture.freshTempRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            try ProviderFixture.makeOfficialLayout(root: root)
            let paths = ["", "0.0.9.627", "0.0.9.627/assets",
                         "0.0.9.627/assets/Wallpaper_Presence", "0.0.9.627/assets/Wallpaper_Ambience"]
            for path in paths {
                let blocked = path.isEmpty ? root : root.appendingPathComponent(path, isDirectory: true)
                try ProviderFixture.withPermissions(0, at: blocked) {
                    do {
                        _ = try OfficialAssetProvider(assetPath: root.path).loadCatalog()
                        t.expect(false, "inaccessible \(path) must not return a partial or missing catalog")
                    } catch {
                        t.expectEqual(DailyAssetIssue.classify(error), .accessDenied,
                                      "permission cause survives for \(path)")
                    }
                }
            }
            let recovered = try OfficialAssetProvider(assetPath: root.path).loadCatalog()
            t.expectEqual(recovered.catalog.loops.count, 24, "restored permissions recover the same directory")
            t.expectEqual(recovered.catalog.ambientTracks.count, 22, "ambience was not silently discarded")
        } catch { t.expect(false, "permission fixture failed: \(error)") }
    }

    run("Provider.inaccessibleNumericCandidateCannotSilentlyChooseSibling") { t in
        guard geteuid() != 0 else {
            print("      SKIP — root bypasses directory permission checks")
            return
        }
        do {
            let root = try ProviderFixture.freshTempRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            try ProviderFixture.makeOfficialLayout(root: root, version: "0.0.1")
            try ProviderFixture.makeOfficialLayout(root: root, version: "0.0.2")
            let blocked = root.appendingPathComponent("0.0.1", isDirectory: true)
            try ProviderFixture.withPermissions(0, at: blocked) {
                do {
                    _ = try OfficialAssetProvider(assetPath: root.path).loadCatalog()
                    t.expect(false, "an unreadable candidate must not disappear from automatic discovery")
                } catch {
                    t.expectEqual(DailyAssetIssue.classify(error), .accessDenied, "candidate failure retains permission cause")
                }
                let explicit = try OfficialAssetProvider(assetPath: root.appendingPathComponent("0.0.2").path).loadCatalog()
                t.expectEqual(explicit.catalog.loops.count, 24, "explicit readable selection does not inspect siblings")
            }
        } catch { t.expect(false, "candidate permission fixture failed: \(error)") }
    }

    run("Provider.fileMetadataFailureDoesNotBecomeUnknownMedia") { t in
        guard geteuid() != 0 else {
            print("      SKIP — root bypasses directory permission checks")
            return
        }
        do {
            let root = try ProviderFixture.freshTempRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            try ProviderFixture.makeOfficialLayout(root: root)
            for (name, filename) in [("Wallpaper_Presence", "A_R1_1200.mp4"),
                                     ("Wallpaper_Ambience", "ambient_loop_1.mp3")] {
                let directory = root.appendingPathComponent("0.0.9.627/assets/\(name)", isDirectory: true)
                let file = directory.appendingPathComponent(filename)
                try ProviderFixture.withMetadataDenied(at: file) {
                    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                    t.expect(files.contains { $0.lastPathComponent == filename },
                             "metadata fixture enumerates the inaccessible file in \(name)")
                    do {
                        _ = try URL(fileURLWithPath: file.path).resourceValues(forKeys: [.isRegularFileKey])
                        t.expect(false, "fixture must deny metadata reading, not just media contents")
                    } catch {
                        t.expectEqual(DailyAssetIssue.classify(error), .accessDenied, "actual child metadata is inaccessible")
                    }
                    for allowEmptyLoops in [false, true] {
                        do {
                            _ = try OfficialAssetProvider(assetPath: root.path).loadCatalog(allowEmptyLoops: allowEmptyLoops)
                            t.expect(false, "inaccessible metadata must not appear as unknown/empty media in \(name)")
                        } catch {
                            t.expectEqual(DailyAssetIssue.classify(error), .accessDenied,
                                          "metadata read retains permission cause even when empty loops are allowed")
                        }
                    }
                }
            }
            let recovered = try OfficialAssetProvider(assetPath: root.path).loadCatalog()
            t.expectEqual(recovered.catalog.loops.count, 24, "removing fixture ACL restores all admitted loops")
            t.expectEqual(recovered.catalog.ambientTracks.count, 22, "removing fixture ACL restores all ambience")
        } catch { t.expect(false, "metadata permission fixture failed: \(error)") }
    }

    run("Provider.preCancelledLoadPropagatesCancellation") { t in
        do {
            let root = try ProviderFixture.freshTempRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            try ProviderFixture.makeOfficialLayout(root: root)
            let (gate, releaseGate) = AsyncStream<Void>.makeStream()
            let finished = DispatchSemaphore(value: 0)
            let cancelled = DispatchSemaphore(value: 0)
            let task = Task.detached {
                defer { finished.signal() }
                for await _ in gate { }
                do { _ = try OfficialAssetProvider(assetPath: root.path).loadCatalog(allowEmptyLoops: true) }
                catch is CancellationError { cancelled.signal() }
                catch { /* An I/O or layout failure does not satisfy cancellation. */ }
            }
            task.cancel()
            releaseGate.finish()
            t.expect(finished.wait(timeout: .now() + 5) == .success, "pre-cancelled load terminates")
            t.expect(cancelled.wait(timeout: .now()) == .success, "load preserves CancellationError")
            let recovered = try OfficialAssetProvider(assetPath: root.path).loadCatalog()
            t.expectEqual(recovered.catalog.loops.count, 24, "cancelled read leaves the fixture usable")
        } catch { t.expect(false, "provider cancellation fixture failed: \(error)") }
    }

    run("Provider.directorySymlinksAreFollowedAndBrokenLinksStayMissing") { t in
        do {
            let root = try ProviderFixture.freshTempRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let fm = FileManager.default
            try ProviderFixture.makeOfficialLayout(root: root)
            let version = root.appendingPathComponent("0.0.9.627", isDirectory: true)
            let alias = root.appendingPathComponent("selected-version", isDirectory: true)
            try fm.createSymbolicLink(at: alias, withDestinationURL: version)
            let presence = version.appendingPathComponent("assets/Wallpaper_Presence", isDirectory: true)
            let storedPresence = root.appendingPathComponent("presence-store", isDirectory: true)
            try fm.moveItem(at: presence, to: storedPresence)
            try fm.createSymbolicLink(at: presence, withDestinationURL: storedPresence)
            let bundle = try OfficialAssetProvider(assetPath: alias.path).loadCatalog()
            t.expectEqual(bundle.catalog.loops.count, 24, "selected directory and Presence directory symlinks both work")
            t.expectEqual(bundle.catalog.ambientTracks.count, 22, "directory symlink keeps sibling ambience")

            let broken = root.appendingPathComponent("broken-directory", isDirectory: true)
            try fm.createSymbolicLink(at: broken, withDestinationURL: root.appendingPathComponent("missing"))
            do {
                _ = try OfficialAssetProvider(assetPath: broken.path).loadCatalog()
                t.expect(false, "broken directory link must not load")
            } catch {
                t.expectEqual(DailyAssetIssue.classify(error), .missingLocation, "missing symlink target is truly absent")
            }
            let cyclic = root.appendingPathComponent("cyclic-directory", isDirectory: true)
            try fm.createSymbolicLink(at: cyclic, withDestinationURL: cyclic)
            do {
                _ = try OfficialAssetProvider(assetPath: cyclic.path).loadCatalog()
                t.expect(false, "cyclic directory link must not load")
            } catch {
                t.expectEqual(DailyAssetIssue.classify(error), .readFailed, "symlink traversal error is not absence or empty media")
            }
        } catch { t.expect(false, "directory symlink fixture failed: \(error)") }
    }

    run("Provider.issueClassificationUsesTypedCodesAndBoundedUnderlyingCause") { t in
        let typed: [(AssetValidationError, DailyAssetIssue)] = [
            (.directoryNotFound("private path"), .missingLocation),
            (.notDirectory("private path"), .unsupportedLayout),
            (.layoutNotRecognized("private path"), .unsupportedLayout),
            (.ambiguousLayouts(["first", "second"]), .ambiguousLayouts),
            (.noContentFound("private path"), .noDailyContent),
        ]
        for (error, expected) in typed {
            t.expectEqual(DailyAssetIssue.classify(error), expected, "typed validation reason")
        }
        let codes: [(String, Int, DailyAssetIssue)] = [
            (NSCocoaErrorDomain, CocoaError.Code.fileReadNoSuchFile.rawValue, .missingLocation),
            (NSCocoaErrorDomain, CocoaError.Code.fileNoSuchFile.rawValue, .missingLocation),
            (NSCocoaErrorDomain, CocoaError.Code.fileReadNoPermission.rawValue, .accessDenied),
            (NSPOSIXErrorDomain, Int(ENOENT), .missingLocation),
            (NSPOSIXErrorDomain, Int(ENOTDIR), .unsupportedLayout),
            (NSPOSIXErrorDomain, Int(EACCES), .accessDenied),
            (NSPOSIXErrorDomain, Int(EPERM), .accessDenied),
            (NSPOSIXErrorDomain, Int(EIO), .readFailed),
            (NSPOSIXErrorDomain, Int.max, .readFailed),
        ]
        for (domain, code, expected) in codes {
            t.expectEqual(DailyAssetIssue.classify(NSError(domain: domain, code: code)), expected,
                          "system code \(domain)/\(code)")
        }
        var wrapped: NSError = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        for _ in 0..<7 {
            wrapped = NSError(domain: NSCocoaErrorDomain, code: CocoaError.Code.fileReadUnknown.rawValue,
                              userInfo: [NSUnderlyingErrorKey: wrapped])
        }
        t.expectEqual(DailyAssetIssue.classify(wrapped), .accessDenied, "bounded nested permission cause is recovered")
        wrapped = NSError(domain: "wrapper", code: 1, userInfo: [NSUnderlyingErrorKey: wrapped])
        t.expectEqual(DailyAssetIssue.classify(wrapped), .readFailed, "underlying traversal has an explicit depth limit")
        let misleadingText = NSError(domain: "unrecognized", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "权限不足，路径不存在，没有素材"])
        t.expectEqual(DailyAssetIssue.classify(misleadingText), .readFailed, "localized wording never determines cause")
    }
}
