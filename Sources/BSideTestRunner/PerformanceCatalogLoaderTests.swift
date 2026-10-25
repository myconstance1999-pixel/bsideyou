// BSideTestRunner — Performance Catalog loader (Slice 2A) synthetic invariant suites.
// Drives the REAL BSidePlatform PerformanceCatalogLoader with synthetic v1 JSON documents:
// external-format validation, deterministic mapping into the Core PerformanceCatalogSnapshot,
// and the no-inference/no-media boundaries. The synthetic documents exercise the REAL v1
// contract: schemaVersion=1 plus required sourceEvidence (>= 4 non-blank entries, each value
// exactly 64 lowercase hex characters) — there is no revision field in the v1 schema. The
// real evidence-catalog acceptance is gated behind the BSIDEMAC_PERFORMANCE_CATALOG_V1
// environment variable so no absolute path becomes a permanent automated-test dependency.

import Foundation
import BSideCore
import BSidePlatform

// MARK: - Deterministic v1 JSON builders

/// The exact evidence identity of the accepted real v1 catalog: 4 non-blank entries, each
/// value exactly 64 lowercase hex characters (the v1 SHA-256 identity contract).
private let validEvidence: [String: String] = [
    "MANIFEST.jsonl": "4f4750b48f75598f1d15eb4e0c14f550ae061422c34117011fb0d2a83c490f9a",
    "MEDIA_PROBE.jsonl": "16b26ea5978166827d6892c3d3c6da40039ffaa4965ffa087927b1edc4ecfe3d",
    "Olivia_索引.csv": "6676198257551e585c98397a39a4412b2713739f299a0ab45badbbc264b47066",
    "SUMMARY.md": "ed75ec798d7928a47d6e6061380dc9f4d1d87d1a706e3130c7a31db40f0296e8",
]

/// Deterministic sorted-key `k=v&k=v` composition of `validEvidence` — the opaque
/// PerformanceCatalogRevision the accepted mapping rule produces.
private let validEvidenceRevision = validEvidence.keys.sorted()
    .map { "\($0)=\(validEvidence[$0] ?? "")" }
    .joined(separator: "&")

private func rawTokensJSON(
    _ time: String? = "TOD1200",
    _ view: String? = "WI",
    _ suffix: String? = "L"
) -> [String: String]? {
    guard time != nil || view != nil || suffix != nil else { return nil }
    var out: [String: String] = [:]
    if let time { out["sourceTimeCode"] = time }
    if let view { out["sourceViewCode"] = view }
    if let suffix { out["sourceSuffixCode"] = suffix }
    return out
}

private func variantJSON(
    id: String,
    lighting: String? = nil,
    presentation: String? = nil,
    relativePath: String = "Solo_Minimal/Solo_Minimal_TOD1200_WI_L.mp4",
    rawTokens: [String: String]? = rawTokensJSON()
) -> [String: Any] {
    var object: [String: Any] = [
        "id": id,
        "relativePath": relativePath,
        "sourceFilename": (relativePath as NSString).lastPathComponent,
    ]
    if let lighting { object["lighting"] = lighting }
    if let presentation { object["presentation"] = presentation }
    if let rawTokens { object["rawTokens"] = rawTokens }
    return object
}

private func performanceJSON(id: String, kind: String, variants: [[String: Any]]) -> [String: Any] {
    ["id": id, "performanceKind": kind, "variantCount": variants.count, "variants": variants]
}

private func documentJSON(
    performances: [[String: Any]],
    schemaVersion: Int = 1,
    sourceEvidence: [String: String]? = validEvidence
) -> [String: Any] {
    var object: [String: Any] = ["schemaVersion": schemaVersion, "performances": performances]
    if let sourceEvidence { object["sourceEvidence"] = sourceEvidence }
    return object
}

/// Minimal exact-V1 pianoSolo performance: daylight/sunset/night × side (3 cells), explicit
/// normalized semantics + raw provenance tokens.
private func minimalSolo(id: String = "olivia.performance.solo.minimal") -> [String: Any] {
    let variants: [[String: Any]] = [
        variantJSON(id: "\(id).variant.daylight-side", lighting: "daylight", presentation: "sidePerformance",
                    relativePath: "Solo_Minimal/Solo_Minimal_TOD1200_WI_L.mp4", rawTokens: rawTokensJSON("TOD1200", "WI", "L")),
        variantJSON(id: "\(id).variant.sunset-side", lighting: "sunset", presentation: "sidePerformance",
                    relativePath: "Solo_Minimal/Solo_Minimal_TOD1730_WI_L.mp4", rawTokens: rawTokensJSON("TOD1730", "WI", "L")),
        variantJSON(id: "\(id).variant.night-side", lighting: "night", presentation: "sidePerformance",
                    relativePath: "Solo_Minimal/Solo_Minimal_TOD2000_WI_L.mp4", rawTokens: rawTokensJSON("TOD2000", "NI", "L")),
    ]
    return performanceJSON(id: id, kind: "pianoSolo", variants: variants)
}

/// Minimal exact-V1 vocalPerformance performance: 3 lightings × {side, portrait} (6 cells).
private func minimalVocal(id: String = "olivia.performance.vocal.minimal") -> [String: Any] {
    var variants: [[String: Any]] = []
    for (index, lighting) in ["daylight", "sunset", "night"].enumerated() {
        variants.append(variantJSON(id: "\(id).variant.\(lighting)-side", lighting: lighting, presentation: "sidePerformance"))
        variants.append(variantJSON(id: "\(id).variant.\(lighting)-portrait", lighting: lighting, presentation: "portraitPerformance"))
        _ = index
    }
    return performanceJSON(id: id, kind: "vocalPerformance", variants: variants)
}

/// An unknownGenerated (midi) performance with no variants (emptySource), as the evidence
/// catalog carries it. Core admission stays authoritative and refuses it.
private func minimalUnknownEmpty(id: String = "olivia.performance.unknown.midi-empty") -> [String: Any] {
    performanceJSON(id: id, kind: "unknownGenerated", variants: [])
}

private func encode(_ json: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: json)
}

private func loadResult(_ json: [String: Any]) -> Result<PerformanceCatalogLoad, PerformanceCatalogLoadError> {
    PerformanceCatalogLoader.load(data: encode(json))
}

private func resolved(_ result: Result<PerformanceCatalogLoad, PerformanceCatalogLoadError>) -> PerformanceCatalogLoad? {
    if case .success(let load) = result { return load }
    return nil
}

private func loadError(_ result: Result<PerformanceCatalogLoad, PerformanceCatalogLoadError>) -> PerformanceCatalogLoadError? {
    if case .failure(let error) = result { return error }
    return nil
}

// MARK: - Suites

func runPerformanceCatalogLoaderTests() {
    // 1. Valid minimal pianoSolo: full external contract + mapping into the Core snapshot,
    //    Semantics resolve through the authoritative Core VariantResolver.
    run("PerfLoader.validMinimalSolo") { t in
        let result = loadResult(documentJSON(performances: [minimalSolo()]))
        guard let load = resolved(result) else { t.expect(false, "minimal solo loaded"); return }
        t.expectEqual(load.snapshot.tracks.count, 1, "one track")
        let track = load.snapshot.track(for: PerformanceID("olivia.performance.solo.minimal"))
        t.expectNotNil(track, "track by id present")
        t.expectEqual(track?.kind, .pianoSolo, "kind mapped verbatim")
        t.expectEqual(track?.variants.count, 3, "exactly 3 variants")
        t.expectEqual(PerformanceTrack.catalogEligibility(track!), .eligible, "Core admission: exact V1 shape eligible")
        let resolution = VariantResolver.resolve(
            trackID: PerformanceID("olivia.performance.solo.minimal"),
            in: load.snapshot,
            effectiveLighting: .night,
            presentationPreference: .automatic
        )
        if case .resolved(let v) = resolution {
            t.expectEqual(v.variantID, PerformanceVariantID("olivia.performance.solo.minimal.variant.night-side"), "night automatic → exact variant")
        } else {
            t.expect(false, "night automatic resolved")
        }
    }

    // 2. Valid minimal vocalPerformance.
    run("PerfLoader.validMinimalVocal") { t in
        let result = loadResult(documentJSON(performances: [minimalVocal()]))
        guard let load = resolved(result) else { t.expect(false, "minimal vocal loaded"); return }
        let track = load.snapshot.track(for: PerformanceID("olivia.performance.vocal.minimal"))
        t.expectEqual(track?.variants.count, 6, "exactly 6 variants")
        t.expectEqual(PerformanceTrack.catalogEligibility(track!), .eligible, "Core admission: exact V1 shape eligible")
        let resolution = VariantResolver.resolve(
            trackID: PerformanceID("olivia.performance.vocal.minimal"),
            in: load.snapshot,
            effectiveLighting: .sunset,
            presentationPreference: .explicit(.portraitPerformance)
        )
        if case .resolved(let v) = resolution {
            t.expectEqual(v.variantID, PerformanceVariantID("olivia.performance.vocal.minimal.variant.sunset-portrait"), "explicit sunset portrait → exact variant")
        } else {
            t.expect(false, "sunset portrait resolved")
        }
    }

    // 3. Supported schema (schemaVersion == 1) AND supported v1 revision identity: the
    //    required sourceEvidence with >= 4 non-blank entries, each value exactly 64 lowercase
    //    hex characters → loaded; the opaque Core revision is the deterministic sorted-key
    //    composition of the evidence hashes.
    run("PerfLoader.supportedSchemaAndRevisionIdentity") { t in
        let result = loadResult(documentJSON(performances: [minimalSolo()]))
        guard let load = resolved(result) else { t.expect(false, "valid evidence identity loaded"); return }
        t.expectEqual(load.snapshot.revision.rawValue, validEvidenceRevision, "opaque revision composed from sorted sourceEvidence")
    }

    // 4. Unsupported schema → typed external-format refusal (schemaVersion is the only
    //    versioned dimension of the v1 contract).
    run("PerfLoader.unsupportedSchema") { t in
        let result = loadResult(documentJSON(performances: [minimalSolo()], schemaVersion: 2))
        t.expectEqual(loadError(result), .some(.unsupportedSchema(2)), "schemaVersion 2 refused")
    }

    // 5. Invalid revision identity → typed refusal: every sourceEvidence value must be exactly
    //    64 lowercase hex characters (the v1 SHA-256 identity pattern); the v1 schema defines
    //    no separate revision field, so there is no "revision marker" to accept.
    run("PerfLoader.invalidRevisionIdentity") { t in
        func withEvidence(_ evidence: [String: String]) -> Result<PerformanceCatalogLoad, PerformanceCatalogLoadError> {
            loadResult(documentJSON(performances: [minimalSolo()], sourceEvidence: evidence))
        }
        var uppercase = validEvidence
        uppercase["SUMMARY.md"] = uppercase["SUMMARY.md"]!.uppercased()
        if case .failure(.invalidRevisionIdentity(let key)) = withEvidence(uppercase) {
            t.expectEqual(key, "SUMMARY.md", "uppercase hex value refused as invalid identity")
        } else { t.expect(false, "uppercase hex value refused") }
        var short = validEvidence
        short["SUMMARY.md"] = String(repeating: "a", count: 32)
        if case .failure(.invalidRevisionIdentity(let key)) = withEvidence(short) {
            t.expectEqual(key, "SUMMARY.md", "non-64-hex value refused as invalid identity")
        } else { t.expect(false, "non-64-hex value refused") }
        var nonHex = validEvidence
        nonHex["SUMMARY.md"] = String(repeating: "g", count: 64)
        if case .failure(.invalidRevisionIdentity(let key)) = withEvidence(nonHex) {
            t.expectEqual(key, "SUMMARY.md", "non-hex character refused as invalid identity")
        } else { t.expect(false, "non-hex character refused") }
    }

    // 6. Malformed JSON → typed refusal.
    run("PerfLoader.malformedJSON") { t in
        if case .failure(.malformedJSON) = PerformanceCatalogLoader.load(data: Data("{\"schemaVersion\": ".utf8)) {
            // expected
        } else {
            t.expect(false, "truncated JSON refused as malformed")
        }
        // Structurally incomplete document (missing performances) is also a decode failure.
        if case .failure(.malformedJSON) = PerformanceCatalogLoader.load(data: Data("{\"schemaVersion\":1}".utf8)) {
            // expected
        } else {
            t.expect(false, "schema-only document refused as malformed")
        }
    }

    // 7. Duplicate Performance ID → typed refusal (never collapsed into one dictionary entry).
    run("PerfLoader.duplicatePerformanceID") { t in
        let duplicate = minimalSolo(id: "olivia.performance.solo.dup")
        let result = loadResult(documentJSON(performances: [duplicate, duplicate]))
        t.expectEqual(loadError(result), .some(.duplicatePerformanceID("olivia.performance.solo.dup")), "duplicate performance id refused")
    }

    // 8. Duplicate Variant ID (within one performance) → typed refusal.
    run("PerfLoader.duplicateVariantID") { t in
        var performance = performanceJSON(id: "olivia.performance.solo.dup", kind: "pianoSolo", variants: [])
        performance["variants"] = [
            variantJSON(id: "olivia.performance.solo.dup.variant.shared", lighting: "daylight", presentation: "sidePerformance"),
            variantJSON(id: "olivia.performance.solo.dup.variant.shared", lighting: "sunset", presentation: "sidePerformance"),
        ]
        performance["variantCount"] = 2
        let result = loadResult(documentJSON(performances: [performance]))
        t.expectEqual(loadError(result), .some(.duplicateVariantID("olivia.performance.solo.dup.variant.shared")), "duplicate variant id refused")
    }

    // 9. Invalid normalized lighting → typed refusal (closed enum, no invented cases).
    run("PerfLoader.invalidNormalizedLighting") { t in
        var solo = minimalSolo()
        var variants = solo["variants"] as! [[String: Any]]
        var bad = variants[0]
        bad["lighting"] = "dawn"
        variants[0] = bad
        solo["variants"] = variants
        let result = loadResult(documentJSON(performances: [solo]))
        t.expectEqual(loadError(result), .some(.invalidNormalizedLighting("dawn")), "lighting \"dawn\" refused")
    }

    // 10. Invalid normalized presentation → typed refusal.
    run("PerfLoader.invalidNormalizedPresentation") { t in
        var solo = minimalSolo()
        var variants = solo["variants"] as! [[String: Any]]
        var bad = variants[2]
        bad["presentation"] = "immersive"
        variants[2] = bad
        solo["variants"] = variants
        let result = loadResult(documentJSON(performances: [solo]))
        t.expectEqual(loadError(result), .some(.invalidNormalizedPresentation("immersive")), "presentation \"immersive\" refused")
    }

    // 11. Raw TOD/NI/WI/L tokens preserved verbatim as per-Variant provenance (never interpreted).
    run("PerfLoader.rawProvenancePreservation") { t in
        var solo = minimalSolo()
        var variants = solo["variants"] as! [[String: Any]]
        var first = variants[0]
        first["rawTokens"] = ["sourceTimeCode": "TOD1200", "sourceViewCode": "NI", "sourceSuffixCode": "L"]
        variants[0] = first
        var hashNamed = variantJSON(id: "olivia.performance.solo.minimal.variant.source-abc123",
                                    lighting: "daylight", presentation: "sidePerformance", rawTokens: nil)
        hashNamed["sourceFilename"] = "source-abc123.mp4"
        variants.append(hashNamed)
        solo["variants"] = variants
        solo["variantCount"] = variants.count

        let result = loadResult(documentJSON(performances: [solo]))
        guard let load = resolved(result) else { t.expect(false, "provenance doc loaded"); return }
        let track = load.snapshot.track(for: PerformanceID("olivia.performance.solo.minimal"))!
        let tod = track.variants.first { $0.id.rawValue.hasSuffix("daylight-side") }
        t.expectEqual(tod?.provenance, PerformanceSourceProvenance(rawTime: "TOD1200", rawView: "NI", suffixTokens: ["L"]), "raw tokens preserved verbatim")
        let hash = track.variants.first { $0.id.rawValue.hasSuffix("source-abc123") }
        t.expectEqual(hash?.provenance, PerformanceSourceProvenance(rawTime: "", rawView: "", suffixTokens: []), "null rawTokens → empty provenance")
    }

    // 12. L is semantically inert: changing the raw suffix token never changes admission or
    //     resolution; it is only retained verbatim in provenance.
    run("PerfLoader.lingeringSuffixInert") { t in
        func soloWithSuffix(_ suffix: String?) -> PerformanceCatalogLoad? {
            var solo = minimalSolo()
            var variants = solo["variants"] as! [[String: Any]]
            var first = variants[0]
            first["rawTokens"] = rawTokensJSON("TOD1200", "WI", suffix)
            variants[0] = first
            solo["variants"] = variants
            return resolved(loadResult(documentJSON(performances: [solo])))
        }
        guard let withL = soloWithSuffix("L"), let withX = soloWithSuffix("X"), let without = soloWithSuffix(nil) else {
            t.expect(false, "all suffix variants load")
            return
        }
        let trackL = withL.snapshot.track(for: PerformanceID("olivia.performance.solo.minimal"))!
        let trackX = withX.snapshot.track(for: PerformanceID("olivia.performance.solo.minimal"))!
        let trackNone = without.snapshot.track(for: PerformanceID("olivia.performance.solo.minimal"))!
        t.expectEqual(PerformanceTrack.catalogEligibility(trackL), PerformanceTrack.catalogEligibility(trackX), "L does not change admission")
        t.expectEqual(PerformanceTrack.catalogEligibility(trackL), PerformanceTrack.catalogEligibility(trackNone), "suffix absence does not change admission")
        func resolveNight(_ load: PerformanceCatalogLoad) -> VariantResolution {
            VariantResolver.resolve(trackID: PerformanceID("olivia.performance.solo.minimal"), in: load.snapshot,
                                    effectiveLighting: .night, presentationPreference: .automatic)
        }
        t.expectEqual(resolveNight(withL), resolveNight(withX), "L does not change resolution")
        t.expectEqual(resolveNight(withL), resolveNight(without), "suffix absence does not change resolution")
        t.expectEqual(trackL.variants[0].provenance.suffixTokens, ["L"], "L retained verbatim on the variant")
        t.expectEqual(trackX.variants[0].provenance.suffixTokens, ["X"], "non-L suffix retained verbatim too")
    }

    // 13. Identical logical input → equivalent snapshots independent of record order.
    run("PerfLoader.orderingIndependent") { t in
        func doc(soloReversed: Bool, vocalReversed: Bool, variantReversed: Bool) -> [String: Any] {
            var performances = [minimalSolo(), minimalVocal()]
            if soloReversed { performances[0] = reversedPerformance(performances[0], variantReversed: variantReversed) }
            if vocalReversed { performances[1] = reversedPerformance(performances[1], variantReversed: variantReversed) }
            return documentJSON(performances: performances)
        }
        func reversedPerformance(_ performance: [String: Any], variantReversed: Bool) -> [String: Any] {
            var variants = performance["variants"] as! [[String: Any]]
            if variantReversed { variants.reverse() }
            var out = performance
            out["variants"] = variants
            return out
        }
        let orderA = doc(soloReversed: false, vocalReversed: false, variantReversed: false)
        let orderB = doc(soloReversed: true, vocalReversed: true, variantReversed: true)
        let a = resolved(loadResult(orderA))
        let b = resolved(loadResult(orderB))
        guard let loadA = a, let loadB = b else { t.expect(false, "both orders load"); return }
        t.expectEqual(loadA.snapshot, loadB.snapshot, "snapshots equivalent under full record reordering")
        t.expectEqual(loadA.snapshot.revision, loadB.snapshot.revision, "revision identical under reordering")
    }

    // 14. The opaque catalog revision/hash identity is preserved and never interpreted:
    //     composed deterministically from the sorted sourceEvidence and carried into
    //     resolution (uses the exact 4-entry evidence identity of the accepted real catalog).
    run("PerfLoader.opaqueRevisionPreserved") { t in
        let result = loadResult(documentJSON(performances: [minimalSolo()], sourceEvidence: validEvidence))
        guard let load = resolved(result) else { t.expect(false, "evidence doc loaded"); return }
        t.expectEqual(load.snapshot.revision.rawValue, validEvidenceRevision, "opaque revision composed deterministically from sorted sourceEvidence")
        let resolution = VariantResolver.resolve(
            trackID: PerformanceID("olivia.performance.solo.minimal"),
            in: load.snapshot,
            effectiveLighting: .daylight,
            presentationPreference: .automatic
        )
        if case .resolved(let v) = resolution {
            t.expectEqual(v.catalogRevision, load.snapshot.revision, "hash identity flows into resolution")
        } else {
            t.expect(false, "resolution carries the composed revision")
        }
    }

    // 15. Syntactically invalid relative asset references are refused (fail-closed, no
    //     filesystem resolution/canonicalization); valid nested POSIX relative .mp4
    //     references pass.
    run("PerfLoader.invalidRelativeReference") { t in
        func soloWithRelativePath(_ path: String) -> Result<PerformanceCatalogLoad, PerformanceCatalogLoadError> {
            var solo = minimalSolo()
            var variants = solo["variants"] as! [[String: Any]]
            var first = variants[0]
            first["relativePath"] = path
            variants[0] = first
            solo["variants"] = variants
            return loadResult(documentJSON(performances: [solo]))
        }
        func expectRefused(_ path: String, _ label: String, t: inout TestContext) {
            if case .failure(.invalidRelativeReference) = soloWithRelativePath(path) {
                // expected
            } else { t.expect(false, "\(label) refused: \(path)") }
        }
        // Leading slash / backslash (absolute forms).
        if case .failure(.invalidRelativeReference(let path)) = soloWithRelativePath("/Solo_Minimal/Absolute.mp4") {
            t.expectEqual(path, "/Solo_Minimal/Absolute.mp4", "leading slash refused")
        } else { t.expect(false, "absolute path refused") }
        expectRefused("\\Solo_Minimal\\Absolute.mp4", "leading backslash", t: &t)
        // Non-.mp4 / empty.
        expectRefused("Solo_Minimal/NoExtension", "non-.mp4", t: &t)
        expectRefused("", "empty path", t: &t)
        // CR/LF structural terminators.
        expectRefused("Solo\nMinimal/Broken.mp4", "newline", t: &t)
        expectRefused("Solo\rMinimal/Broken.mp4", "carriage return", t: &t)
        // Slash-delimited dot / dot-dot components.
        expectRefused("../Solo.mp4", "leading dot-dot", t: &t)
        expectRefused("Solo_Minimal/../Solo.mp4", "nested dot-dot", t: &t)
        expectRefused("./Solo.mp4", "leading dot", t: &t)
        expectRefused("Solo_Minimal/./Solo.mp4", "nested dot", t: &t)
        // Backslash path separators (Windows forms).
        expectRefused("Solo_Minimal\\Solo_Minimal_TOD1200_WI_L.mp4", "backslash separator", t: &t)
        expectRefused("..\\Solo.mp4", "backslash dot-dot", t: &t)
        // Empty components.
        expectRefused("Solo_Minimal//Solo.mp4", "empty component", t: &t)
        // Obvious URL / drive absolute forms.
        expectRefused("file:///Solo/Solo.mp4", "file URL", t: &t)
        expectRefused("https://host/Solo.mp4", "https URL", t: &t)
        expectRefused("C:/Solo/Solo.mp4", "drive absolute", t: &t)
        expectRefused("C:\\Solo\\Solo.mp4", "drive absolute backslash", t: &t)
        // Valid nested POSIX relative references are retained (no resolution).
        t.expectNotNil(resolved(soloWithRelativePath("Solo_Minimal/Solo_Minimal_TOD1200_WI_L.mp4")), "valid relative reference accepted")
        t.expectNotNil(resolved(soloWithRelativePath("Solo_Minimal/Sub/Deeper/Solo_TOD2000_NI_L.mp4")), "valid nested relative reference accepted")
    }

    // 16. Works with no media root and no MP4 files: pure in-memory load, and the explicitly
    //     supplied source-URL form reads only the catalog JSON file.
    run("PerfLoader.noMediaRootOrMP4") { t in
        let memory = loadResult(documentJSON(performances: [minimalSolo(), minimalVocal()]))
        guard let load = resolved(memory) else { t.expect(false, "in-memory load works with no media root"); return }
        // Relative asset references stay Platform data, unresolved.
        let documentPath = load.document.performances[0].variants[0].relativePath
        t.expectEqual(documentPath, "Solo_Minimal/Solo_Minimal_TOD1200_WI_L.mp4", "relative reference retained verbatim, never resolved")

        // Source form: a standalone catalog JSON file (no media anywhere).
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("perf-catalog-slice2a-tmp.json")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try encode(documentJSON(performances: [minimalSolo()])).write(to: url)
        } catch {
            t.expect(false, "temp catalog written")
            return
        }
        if case .success(let fromSource) = PerformanceCatalogLoader.load(sourceURL: url) {
            t.expectEqual(fromSource.snapshot.tracks.count, 1, "source-URL form loads the same logical catalog")
        } else {
            t.expect(false, "source-URL load succeeded")
        }
    }

    // 17. A catalog carrying raw tokens ONLY (like the real evidence artifact) validates at
    //     the external-format level but cannot be mapped without inference: typed refusal.
    run("PerfLoader.missingNormalizedSemantics") { t in
        var solo = minimalSolo()
        var variants = solo["variants"] as! [[String: Any]]
        var first = variants[0]
        first["lighting"] = nil
        first["presentation"] = nil
        variants[0] = first
        solo["variants"] = variants

        let document = documentJSON(performances: [solo])
        let validation = PerformanceCatalogLoader.validate(data: encode(document))
        if case .success(let dto) = validation {
            t.expectEqual(dto.performances.count, 1, "external format validates without semantics")
        } else {
            t.expect(false, "external format validates without semantics")
        }
        let result = loadResult(document)
        t.expectEqual(loadError(result), .some(.missingNormalizedSemantics(
            performanceID: "olivia.performance.solo.minimal",
            variantID: "olivia.performance.solo.minimal.variant.daylight-side"
        )), "snapshot mapping refused — no inference from raw tokens")
    }

    // 18. Catalog integrity: declared variantCount must equal the actual variant records.
    run("PerfLoader.integrityMismatch") { t in
        var solo = minimalSolo()
        solo["variantCount"] = 4
        let result = loadResult(documentJSON(performances: [solo]))
        t.expectEqual(loadError(result), .some(.integrityMismatch(
            performanceID: "olivia.performance.solo.minimal", declared: 4, actual: 3
        )), "declared/actual mismatch refused")
    }

    // 19. Catalog identity: a variant ID outside its performance's namespace is refused.
    run("PerfLoader.identityMismatch") { t in
        var solo = minimalSolo()
        var variants = solo["variants"] as! [[String: Any]]
        var first = variants[0]
        first["id"] = "olivia.performance.vocal.intruder.variant.x"
        variants[0] = first
        solo["variants"] = variants
        let result = loadResult(documentJSON(performances: [solo]))
        t.expectEqual(loadError(result), .some(.identityMismatch(
            performanceID: "olivia.performance.solo.minimal",
            variantID: "olivia.performance.vocal.intruder.variant.x"
        )), "foreign variant id refused")
    }

    // 20. performanceKind outside the sanctioned v1 set is refused.
    run("PerfLoader.unsupportedPerformanceKind") { t in
        let performance = performanceJSON(id: "olivia.performance.solo.orchestra", kind: "orchestra", variants: [])
        let result = loadResult(documentJSON(performances: [performance]))
        t.expectEqual(loadError(result), .some(.unsupportedPerformanceKind("orchestra")), "kind \"orchestra\" refused")
    }

    // 21. The v1 revision-identity contract must be satisfiable: required sourceEvidence with
    //     at least 4 non-blank entries (the v1 schema defines no separate revision field).
    run("PerfLoader.missingRevisionIdentity") { t in
        func withEvidence(_ evidence: [String: String]?) -> Result<PerformanceCatalogLoad, PerformanceCatalogLoadError> {
            loadResult(documentJSON(performances: [minimalSolo()], sourceEvidence: evidence))
        }
        t.expectEqual(loadError(withEvidence(nil)), .some(.missingRevisionIdentity), "no sourceEvidence refused")
        t.expectEqual(loadError(withEvidence([:])), .some(.missingRevisionIdentity), "empty sourceEvidence refused")
        // 3 non-blank entries is below the v1 minimum of 4.
        let tooFew: [String: String] = [
            "MANIFEST.jsonl": validEvidence["MANIFEST.jsonl"]!,
            "MEDIA_PROBE.jsonl": validEvidence["MEDIA_PROBE.jsonl"]!,
            "SUMMARY.md": validEvidence["SUMMARY.md"]!,
        ]
        t.expectEqual(loadError(withEvidence(tooFew)), .some(.missingRevisionIdentity), "3-entry sourceEvidence refused (v1 min 4)")
        // Blank key/value entries are not usable evidence.
        var blankValue = validEvidence
        blankValue["INDEX.csv"] = "  "
        t.expectEqual(loadError(withEvidence(blankValue)), .some(.missingRevisionIdentity), "blank sourceEvidence value refused")
        var blankKey = validEvidence
        blankKey["  "] = validEvidence["Olivia_索引.csv"]!
        blankKey.removeValue(forKey: "Olivia_索引.csv")
        t.expectEqual(loadError(withEvidence(blankKey)), .some(.missingRevisionIdentity), "blank sourceEvidence key refused")
    }

    // 22. unknownGenerated passes through the loader verbatim; CORE semantic admission (not
    //     the loader) remains the authority that refuses it.
    run("PerfLoader.unknownGeneratedCoreAuthority") { t in
        let result = loadResult(documentJSON(performances: [minimalUnknownEmpty()]))
        guard let load = resolved(result) else { t.expect(false, "unknownGenerated mapped"); return }
        let track = load.snapshot.track(for: PerformanceID("olivia.performance.unknown.midi-empty"))
        t.expectEqual(track?.kind, .unknownGenerated, "kind preserved verbatim")
        t.expectEqual(track?.variants.count, 0, "emptySource carries zero variants")
        t.expectEqual(PerformanceTrack.catalogEligibility(track!), .ineligible([.unknownGeneratedKind]), "Core refuses unknownGenerated; loader did not duplicate admission")
    }

    // 23. Real accepted catalog local acceptance. Gated by env var so the Workbuddy absolute
    //     path is never a permanent automated-test dependency.
    run("PerfLoader.realCatalogAcceptance") { t in
        guard let path = ProcessInfo.processInfo.environment["BSIDEMAC_PERFORMANCE_CATALOG_V1"], !path.isEmpty else {
            print("      SKIP — set BSIDEMAC_PERFORMANCE_CATALOG_V1 to the accepted performance-catalog.v1.json to run the real-catalog acceptance")
            return
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            t.expect(false, "cannot read \(path)")
            return
        }
        switch PerformanceCatalogLoader.validate(data: data) {
        case .failure(let error):
            t.expect(false, "real catalog external-format validation failed: \(error)")
        case .success(let document):
            t.expectEqual(document.performances.count, 132, "real catalog performance count")
            let variantCount = document.performances.reduce(0) { $0 + $1.variants.count }
            t.expectEqual(variantCount, 483, "real catalog variant count")
            // The accepted evidence catalog carries raw tokens ONLY (explicitly "no semantic
            // claim"); no explicit normalized lighting/presentation exists, so a full Core
            // snapshot mapping is refused typed — never inferred, never repaired.
            switch PerformanceCatalogLoader.load(data: data) {
            case .success:
                t.expect(false, "expected refusal: evidence catalog has no explicit normalized semantics")
            case .failure(.missingNormalizedSemantics(let performanceID, let variantID)):
                print("      note: real catalog carries raw tokens only; snapshot mapping refused at \(performanceID)/\(variantID); no inference performed")
            case .failure(let error):
                t.expect(false, "expected missingNormalizedSemantics, got \(error)")
            }
        }
    }
}