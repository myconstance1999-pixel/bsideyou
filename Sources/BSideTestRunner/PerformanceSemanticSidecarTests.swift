// BSideTestRunner — Performance semantic sidecar + deterministric production JOIN
// (Slice 2A.1) synthetic invariant suites. Drives the REAL BSidePlatform
// PerformanceSemanticCatalogJoin with synthetic base-catalog + semantic-sidecar byte
// buffers: successful exact closure, every typed annotation/exclusion failure, byte-bound
// identity, deterministic ordering, L inertness, the no-inference boundary, URL/data error
// surfacing, the Core eligibility gate, and the env-gated real catalog + committed
// sidecar acceptance (129 tracks / 480 variants / 3 exclusions, exact base + sidecar
// SHA-256). Nothing here reads media, archives, or any absolute path — the real base
// catalog is reached ONLY through BSIDEMAC_PERFORMANCE_CATALOG_V1 (same convention as the
// Slice 2A loader acceptance), and the sidecar comes from the committed fixture.

import Foundation
import BSideCore
import BSidePlatform

// MARK: - Recorded reviewed-artifact identities (committed metadata, not paths)

/// The exact SHA-256 of the committed fixture scripts/fixtures/performance-semantic-sidecar.v1.json
/// (byte-identity of regeneration verified by the offline builder — see checkpoint 33).
private let documentedSidecarSHA256 = "098bd5793f0cd112b5ac8863803cef149d91684449e1219579f1016a54933833"

/// The exact SHA-256 of the accepted real base catalog (performance-catalog.v1.json) that the
/// committed fixture binds. 132 performances / 483 variants; 3 unknownGenerated tracks
/// excluded → 129 / 480.
private let documentedBaseCatalogSHA256 = "490f2c10dac89cad9703317198f8bcc496cc9d17ccea314658319e5324e46529"

// MARK: - Synthetic v1 + sidecar builders

private let sidecarEvidence: [String: String] = [
    "MANIFEST.jsonl": "4f4750b48f75598f1d15eb4e0c14f550ae061422c34117011fb0d2a83c490f9a",
    "MEDIA_PROBE.jsonl": "16b26ea5978166827d6892c3d3c6da40039ffaa4965ffa087927b1edc4ecfe3d",
    "Olivia_索引.csv": "6676198257551e585c98397a39a4412b2713739f299a0ab45badbbc264b47066",
    "SUMMARY.md": "ed75ec798d7928a47d6e6061380dc9f4d1d87d1a706e3130c7a31db40f0296e8",
]

private func joinRawTokens(
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

/// A variant in the "real evidence" shape: raw provenance tokens ONLY (no explicit
/// normalized semantics — the sidecar supplies those). Explicit lighting/presentation may
/// be passed for the base-contradiction tests (closed-set values only).
private func joinVariantJSON(
    id: String,
    lighting: String? = nil,
    presentation: String? = nil,
    rawTokens: [String: String]? = joinRawTokens()
) -> [String: Any] {
    var object: [String: Any] = [
        "id": id,
        "relativePath": "Solo_Minimal/\(id).mp4",
        "sourceFilename": "\(id).mp4",
    ]
    if let lighting { object["lighting"] = lighting }
    if let presentation { object["presentation"] = presentation }
    if let rawTokens { object["rawTokens"] = rawTokens }
    return object
}

private func joinPerformanceJSON(id: String, kind: String, variants: [[String: Any]]) -> [String: Any] {
    ["id": id, "performanceKind": kind, "variantCount": variants.count, "variants": variants]
}

private func joinDocumentJSON(performances: [[String: Any]]) -> [String: Any] {
    ["schemaVersion": 1, "sourceEvidence": sidecarEvidence, "performances": performances]
}

/// Standard pianoSolo in the evidence shape (3 raw-token variants; no explicit semantics).
private func joinSoloJSON(id: String = "olivia.performance.solo.p2a1") -> [String: Any] {
    joinPerformanceJSON(id: id, kind: "pianoSolo", variants: [
        joinVariantJSON(id: "\(id).variant.daylight-side", rawTokens: joinRawTokens("TOD1200", "WI", "L")),
        joinVariantJSON(id: "\(id).variant.sunset-side", rawTokens: joinRawTokens("TOD1730", "WI", "L")),
        joinVariantJSON(id: "\(id).variant.night-side", rawTokens: joinRawTokens("TOD2000", "NI", "L")),
    ])
}

/// Standard vocalPerformance in the evidence shape (6 raw-token variants).
private func joinVocalJSON(id: String = "olivia.performance.vocal.p2a1") -> [String: Any] {
    var variants: [[String: Any]] = []
    for (index, lighting) in ["daylight", "sunset", "night"].enumerated() {
        let time = ["TOD1200", "TOD1730", "TOD2000"][index]
        variants.append(joinVariantJSON(id: "\(id).variant.\(lighting)-side", rawTokens: joinRawTokens(time, "WI", "L")))
        variants.append(joinVariantJSON(id: "\(id).variant.\(lighting)-portrait", rawTokens: joinRawTokens(time, "WI", "L")))
    }
    return joinPerformanceJSON(id: id, kind: "vocalPerformance", variants: variants)
}

/// A standard unknownGenerated (midi) performance in the evidence shape, carrying
/// 3 raw-token variants (as the real catalog's midi-31823 track does).
private func joinUnknownJSON(id: String = "olivia.performance.unknown.midi-p2a1") -> [String: Any] {
    joinPerformanceJSON(id: id, kind: "unknownGenerated", variants: [
        joinVariantJSON(id: "\(id).variant.1", rawTokens: nil),
        joinVariantJSON(id: "\(id).variant.2", rawTokens: nil),
        joinVariantJSON(id: "\(id).variant.3", rawTokens: nil),
    ])
}

private func joinAnnotationJSON(variantID: String, lighting: String, presentation: String, source: String = "reviewedToken") -> [String: Any] {
    ["variantID": variantID, "lighting": lighting, "presentation": presentation, "semanticSource": source]
}

private func joinExclusionJSON(
    performanceID: String,
    declaredCount: Int,
    kind: String = "unknownGenerated",
    reason: String = "unknownGeneratedUnsupported",
    version: Int = 1
) -> [String: Any] {
    ["performanceID": performanceID, "kind": kind, "reason": reason, "reasonVersion": version, "excludedVariantCount": declaredCount]
}

/// The annotations of the standard exact closure: the 3 solo annotations by default, plus
/// the 6 vocal annotations when a vocal performance is part of the base document.
private func joinStandardAnnotations(
    soloID: String = "olivia.performance.solo.p2a1",
    vocalID: String? = nil
) -> [[String: Any]] {
    var annotations: [[String: Any]] = []
    for lighting in ["daylight", "sunset", "night"] {
        annotations.append(joinAnnotationJSON(variantID: "\(soloID).variant.\(lighting)-side", lighting: lighting, presentation: "sidePerformance"))
        if let vocalID {
            annotations.append(joinAnnotationJSON(variantID: "\(vocalID).variant.\(lighting)-side", lighting: lighting, presentation: "sidePerformance"))
            annotations.append(joinAnnotationJSON(variantID: "\(vocalID).variant.\(lighting)-portrait", lighting: lighting, presentation: "portraitPerformance"))
        }
    }
    return annotations
}

private func joinSidecarJSON(baseSHA: String, annotations: [[String: Any]], exclusions: [[String: Any]]) -> [String: Any] {
    [
        "schemaVersion": 1,
        "artifactKind": "performanceCatalogV1SemanticClosure",
        "baseCatalogSHA256": baseSHA,
        "variantAnnotations": annotations,
        "unsupportedExclusions": exclusions,
    ]
}

private func joinEncode(_ json: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: json)
}

private func joinJoin(baseJSON: [String: Any], annotations: [[String: Any]], exclusions: [[String: Any]] = [])
    -> Result<PerformanceSemanticClosureLoad, PerformanceSemanticClosureError> {
    let baseData = joinEncode(baseJSON)
    let baseSHA = PerformanceSemanticCatalogJoin.sha256Hex(of: baseData)
    let sidecarData = joinEncode(joinSidecarJSON(baseSHA: baseSHA, annotations: annotations, exclusions: exclusions))
    return PerformanceSemanticCatalogJoin.join(baseCatalogData: baseData, sidecarData: sidecarData)
}

private func joinResolved(_ result: Result<PerformanceSemanticClosureLoad, PerformanceSemanticClosureError>) -> PerformanceSemanticClosureLoad? {
    if case .success(let load) = result { return load }
    return nil
}

private func joinError(_ result: Result<PerformanceSemanticClosureLoad, PerformanceSemanticClosureError>) -> PerformanceSemanticClosureError? {
    if case .failure(let error) = result { return error }
    return nil
}

// MARK: - Suites

func runPerformanceSemanticSidecarTests() {
    // 1. Successful exact closure: solo(3)+vocal(6) annotated, unknownGenerated(3 variants)
    //    explicitly excluded — never annotated, never in the snapshot. Joined revision binds
    //    BOTH byte hashes; unknownGenerated is absent from the Core snapshot.
    run("SidecarJoin.successExactClosure") { t in
        let soloID = "olivia.performance.solo.p2a1"
        let vocalID = "olivia.performance.vocal.p2a1"
        let unknownID = "olivia.performance.unknown.midi-p2a1"
        let document = joinDocumentJSON(performances: [joinSoloJSON(id: soloID), joinVocalJSON(id: vocalID), joinUnknownJSON(id: unknownID)])
        let baseData = joinEncode(document)
        let baseSHA = PerformanceSemanticCatalogJoin.sha256Hex(of: baseData)
        let sidecarData = joinEncode(joinSidecarJSON(
            baseSHA: baseSHA,
            annotations: joinStandardAnnotations(soloID: soloID, vocalID: vocalID),
            exclusions: [joinExclusionJSON(performanceID: unknownID, declaredCount: 3)]
        ))
        let result = PerformanceSemanticCatalogJoin.join(baseCatalogData: baseData, sidecarData: sidecarData)
        guard let load = joinResolved(result) else { t.expect(false, "exact closure joined"); return }
        t.expectEqual(load.snapshot.tracks.count, 2, "supported tracks only (unknownGenerated excluded from the snapshot)")
        t.expectNil(load.snapshot.track(for: PerformanceID(unknownID)), "unknownGenerated never enters the Core snapshot")
        let solo = load.snapshot.track(for: PerformanceID(soloID))
        t.expectNotNil(solo, "solo track present")
        t.expectEqual(solo?.variants.count, 3, "solo: exactly 3 variants")
        t.expectEqual(solo?.variants.map { $0.lighting }, [.daylight, .sunset, .night], "solo cells from annotations, canonical order")
        t.expectEqual(PerformanceTrack.catalogEligibility(solo!), .eligible, "Core admission: exact v1 shape eligible")
        let vocal = load.snapshot.track(for: PerformanceID(vocalID))
        t.expectEqual(vocal?.variants.count, 6, "vocal: exactly 6 variants")
        t.expectEqual(PerformanceTrack.catalogEligibility(vocal!), .eligible, "Core admission: vocal eligible")
        t.expectEqual(load.sidecar.unsupportedExclusions.count, 1, "exactly one explicit exclusion")
        let exclusion = load.sidecar.unsupportedExclusions[0]
        t.expectEqual(exclusion.performanceID, unknownID, "exclusion names the unknownGenerated track")
        t.expectEqual(exclusion.excludedVariantCount, 3, "exclusion count matches the catalog record")
        t.expectEqual(load.baseCatalogSHA256, baseSHA, "recorded base SHA is the exact base byte hash")
        t.expectEqual(load.sidecarSHA256, PerformanceSemanticCatalogJoin.sha256Hex(of: sidecarData), "recorded sidecar SHA is the exact sidecar byte hash")
        t.expectEqual(PerformanceSemanticCatalogJoin.joinedRevision(baseCatalogSHA256: load.baseCatalogSHA256, sidecarSHA256: load.sidecarSHA256).rawValue,
                      "base=\(load.baseCatalogSHA256)&semantics=\(load.sidecarSHA256)", "joined revision composition")
        t.expectEqual(load.snapshot.revision.rawValue, "base=\(load.baseCatalogSHA256)&semantics=\(load.sidecarSHA256)", "loaded revision binds both byte hashes")
    }

    // 2. Wrong base hash → typed refusal BEFORE any snapshot (valid-format but foreign binding).
    run("SidecarJoin.baseHashMismatch") { t in
        let soloID = "olivia.performance.solo.p2a1"
        let baseData = joinEncode(joinDocumentJSON(performances: [joinSoloJSON(id: soloID)]))
        let baseSHA = PerformanceSemanticCatalogJoin.sha256Hex(of: baseData)
        let claimedOther = String(repeating: "a", count: 64)
        let sidecarData = joinEncode(joinSidecarJSON(
            baseSHA: claimedOther,
            annotations: joinStandardAnnotations(soloID: soloID),
            exclusions: []
        ))
        let result = PerformanceSemanticCatalogJoin.join(baseCatalogData: baseData, sidecarData: sidecarData)
        t.expectEqual(joinError(result), .some(.baseCatalogHashMismatch(expected: claimedOther, actual: baseSHA)), "foreign base binding refused with actual hash")
        // And the binding helper itself is deterministic.
        let recomputed = PerformanceSemanticCatalogJoin.sha256Hex(of: baseData)
        t.expectEqual(recomputed, baseSHA, "sha256Hex deterministic for identical bytes")
    }

    // 3. Missing annotation → typed refusal (first missing in deterministic sorted order).
    run("SidecarJoin.missingAnnotation") { t in
        let soloID = "olivia.performance.solo.p2a1"
        var annotations = joinStandardAnnotations(soloID: soloID)
        annotations.removeAll { $0["variantID"] as? String == "\(soloID).variant.daylight-side" }
        let result = joinJoin(
            baseJSON: joinDocumentJSON(performances: [joinSoloJSON(id: soloID)]),
            annotations: annotations
        )
        t.expectEqual(joinError(result), .some(.missingAnnotation(variantID: "\(soloID).variant.daylight-side")), "unannotated supported variant refused (sorted first)")
    }

    // 4. Duplicate annotation → typed refusal (never collapsed into one entry).
    run("SidecarJoin.duplicateAnnotation") { t in
        let soloID = "olivia.performance.solo.p2a1"
        var annotations = joinStandardAnnotations(soloID: soloID)
        let daylight = joinAnnotationJSON(variantID: "\(soloID).variant.daylight-side", lighting: "daylight", presentation: "sidePerformance")
        annotations.append(daylight)
        let result = joinJoin(
            baseJSON: joinDocumentJSON(performances: [joinSoloJSON(id: soloID)]),
            annotations: annotations
        )
        t.expectEqual(joinError(result), .some(.duplicateAnnotation(variantID: "\(soloID).variant.daylight-side")), "duplicate variant annotation refused")
    }

    // 5. Foreign annotation → typed refusal (unknown ID — and unknownGenerated variants are
    //    never annotated, they are excluded instead).
    run("SidecarJoin.foreignAnnotation") { t in
        let soloID = "olivia.performance.solo.p2a1"
        let unknownID = "olivia.performance.unknown.midi-p2a1"
        // A foreign ID that is not a supported variant at all.
        var foreign = joinAnnotationJSON(variantID: "olivia.performance.solo.elsewhere.variant.x", lighting: "daylight", presentation: "sidePerformance")
        var result = joinJoin(
            baseJSON: joinDocumentJSON(performances: [joinSoloJSON(id: soloID)]),
            annotations: joinStandardAnnotations(soloID: soloID) + [foreign]
        )
        t.expectEqual(joinError(result), .some(.foreignAnnotation(variantID: "olivia.performance.solo.elsewhere.variant.x")), "annotation for an unknown variant refused")
        // An unknownGenerated variant is foreign to the annotation set too.
        foreign = joinAnnotationJSON(variantID: "\(unknownID).variant.1", lighting: "daylight", presentation: "sidePerformance")
        result = joinJoin(
            baseJSON: joinDocumentJSON(performances: [joinSoloJSON(id: soloID), joinUnknownJSON(id: unknownID)]),
            annotations: joinStandardAnnotations(soloID: soloID) + [foreign],
            exclusions: [joinExclusionJSON(performanceID: unknownID, declaredCount: 3)]
        )
        t.expectEqual(joinError(result), .some(.foreignAnnotation(variantID: "\(unknownID).variant.1")), "annotating an unknownGenerated variant refused (exclusion is the only sanctioned form)")
    }

    // 6. Invalid closed-set lighting in an annotation → typed refusal.
    run("SidecarJoin.invalidAnnotationLighting") { t in
        let soloID = "olivia.performance.solo.p2a1"
        var annotations = joinStandardAnnotations(soloID: soloID)
        annotations[0]["lighting"] = "dawn"
        let result = joinJoin(
            baseJSON: joinDocumentJSON(performances: [joinSoloJSON(id: soloID)]),
            annotations: annotations
        )
        t.expectEqual(joinError(result), .some(.invalidAnnotationLighting(variantID: "\(soloID).variant.daylight-side", value: "dawn")), "lighting \"dawn\" refused")
    }

    // 7. Invalid closed-set presentation in an annotation → typed refusal.
    run("SidecarJoin.invalidAnnotationPresentation") { t in
        let soloID = "olivia.performance.solo.p2a1"
        var annotations = joinStandardAnnotations(soloID: soloID)
        annotations[0]["presentation"] = "immersive"
        let result = joinJoin(
            baseJSON: joinDocumentJSON(performances: [joinSoloJSON(id: soloID)]),
            annotations: annotations
        )
        t.expectEqual(joinError(result), .some(.invalidAnnotationPresentation(variantID: "\(soloID).variant.daylight-side", value: "immersive")), "presentation \"immersive\" refused")
    }

    // 8. Unsanctioned semanticSource → typed refusal (only reviewedToken / explicitOverride
    //    are sanctioned documentary sources; production never accepts a token-derived marker).
    run("SidecarJoin.invalidAnnotationSource") { t in
        let soloID = "olivia.performance.solo.p2a1"
        var annotations = joinStandardAnnotations(soloID: soloID)
        annotations[0]["semanticSource"] = "guessedFromTokens"
        let result = joinJoin(
            baseJSON: joinDocumentJSON(performances: [joinSoloJSON(id: soloID)]),
            annotations: annotations
        )
        t.expectEqual(joinError(result), .some(.invalidAnnotationSource(variantID: "\(soloID).variant.daylight-side", value: "guessedFromTokens")), "unsanctioned source refused")
        // The sanctioned override source is accepted (explicitOverride path).
        var overrides = joinStandardAnnotations(soloID: soloID)
        overrides[0]["semanticSource"] = "explicitOverride"
        let ok = joinJoin(
            baseJSON: joinDocumentJSON(performances: [joinSoloJSON(id: soloID)]),
            annotations: overrides
        )
        t.expectNotNil(joinResolved(ok), "sanctioned explicitOverride source accepted")
    }

    // 9. Base contradiction where the base carries an explicit normalized claim: the reviewed
    //    annotation must never disagree with it (fail-closed, checks BOTH lighting and
    //    presentation).
    run("SidecarJoin.annotationContradictsBase") { t in
        let soloID = "olivia.performance.solo.p2a1"
        // A base carrying explicit daylight on the daylight variant but the annotation says night.
        let soloLighting = joinPerformanceJSON(id: soloID, kind: "pianoSolo", variants: [
            joinVariantJSON(id: "\(soloID).variant.daylight-side", lighting: "daylight", presentation: "sidePerformance",
                            rawTokens: joinRawTokens("TOD1200", "WI", "L")),
            joinVariantJSON(id: "\(soloID).variant.sunset-side", lighting: "sunset", presentation: "sidePerformance",
                            rawTokens: joinRawTokens("TOD1730", "WI", "L")),
            joinVariantJSON(id: "\(soloID).variant.night-side", lighting: "night", presentation: "sidePerformance",
                            rawTokens: joinRawTokens("TOD2000", "NI", "L")),
        ])
        var annotations = joinStandardAnnotations(soloID: soloID)
        annotations[0]["lighting"] = "night" // contradicts base explicit daylight
        let result = joinJoin(
            baseJSON: joinDocumentJSON(performances: [soloLighting]),
            annotations: annotations
        )
        if case .failure(.annotationContradictsBase(let pid, let vid, let detail)) = result {
            t.expectEqual(pid, soloID, "contradiction surfaces the performance")
            t.expectEqual(vid, "\(soloID).variant.daylight-side", "contradiction surfaces the variant")
            t.expect(detail.contains("base lighting daylight contradicts annotation night"), "contradiction detail names both claims: \(detail)")
        } else {
            t.expect(false, "explicit base lighting contradiction refused (got \(String(describing: result)))")
        }
        // Presentation contradiction, same fail-closed rule.
        var presentationAnnotations = joinStandardAnnotations(soloID: soloID)
        presentationAnnotations[0]["presentation"] = "portraitPerformance" // base says side
        let presentationResult = joinJoin(
            baseJSON: joinDocumentJSON(performances: [soloLighting]),
            annotations: presentationAnnotations
        )
        if case .failure(.annotationContradictsBase(_, let pVid, let pDetail)) = presentationResult {
            t.expectEqual(pVid, "\(soloID).variant.daylight-side", "presentation contradiction surfaces the variant")
            t.expect(pDetail.contains("base presentation sidePerformance contradicts annotation portraitPerformance"), "presentation contradiction detail: \(pDetail)")
        } else {
            t.expect(false, "explicit base presentation contradiction refused")
        }
        // Agreement between base explicit claims and annotations is fine.
        let agreed = joinJoin(
            baseJSON: joinDocumentJSON(performances: [soloLighting]),
            annotations: joinStandardAnnotations(soloID: soloID)
        )
        t.expectNotNil(joinResolved(agreed), "matching explicit base claims + annotations joined")
    }

    // 10. Missing unsupported exclusion → typed refusal (a known unknownGenerated track with
    //     no explicit exclusion is never silently dropped).
    run("SidecarJoin.missingUnsupportedExclusion") { t in
        let soloID = "olivia.performance.solo.p2a1"
        let unknownID = "olivia.performance.unknown.midi-p2a1"
        let result = joinJoin(
            baseJSON: joinDocumentJSON(performances: [joinSoloJSON(id: soloID), joinUnknownJSON(id: unknownID)]),
            annotations: joinStandardAnnotations(soloID: soloID),
            exclusions: []
        )
        t.expectEqual(joinError(result), .some(.missingUnsupportedExclusion(performanceID: unknownID)), "unknownGenerated without explicit exclusion refused")
    }

    // 11. Duplicate unsupported exclusion → typed refusal.
    run("SidecarJoin.duplicateUnsupportedExclusion") { t in
        let soloID = "olivia.performance.solo.p2a1"
        let unknownID = "olivia.performance.unknown.midi-p2a1"
        let result = joinJoin(
            baseJSON: joinDocumentJSON(performances: [joinSoloJSON(id: soloID), joinUnknownJSON(id: unknownID)]),
            annotations: joinStandardAnnotations(soloID: soloID),
            exclusions: [
                joinExclusionJSON(performanceID: unknownID, declaredCount: 3),
                joinExclusionJSON(performanceID: unknownID, declaredCount: 3),
            ]
        )
        t.expectEqual(joinError(result), .some(.duplicateUnsupportedExclusion(performanceID: unknownID)), "duplicate exclusion refused")
    }

    // 12. Foreign unsupported exclusion → typed refusal (only unknownGenerated tracks may be
    //     excluded; a supported track is never "excluded").
    run("SidecarJoin.foreignUnsupportedExclusion") { t in
        let soloID = "olivia.performance.solo.p2a1"
        let result = joinJoin(
            baseJSON: joinDocumentJSON(performances: [joinSoloJSON(id: soloID)]),
            annotations: joinStandardAnnotations(soloID: soloID),
            exclusions: [joinExclusionJSON(performanceID: soloID, declaredCount: 3)]
        )
        t.expectEqual(joinError(result), .some(.foreignUnsupportedExclusion(performanceID: soloID)), "exclusion for a supported track refused")
    }

    // 13. Invalid unsupported exclusion contract (kind/reason/reasonVersion) → typed refusal.
    run("SidecarJoin.invalidUnsupportedExclusion") { t in
        let soloID = "olivia.performance.solo.p2a1"
        let unknownID = "olivia.performance.unknown.midi-p2a1"
        func withExclusion(_ exclusion: [String: Any]) -> Result<PerformanceSemanticClosureLoad, PerformanceSemanticClosureError> {
            joinJoin(
                baseJSON: joinDocumentJSON(performances: [joinSoloJSON(id: soloID), joinUnknownJSON(id: unknownID)]),
                annotations: joinStandardAnnotations(soloID: soloID),
                exclusions: [exclusion]
            )
        }
        if case .failure(.invalidUnsupportedExclusion(let pid, let detail)) = withExclusion(
            joinExclusionJSON(performanceID: unknownID, declaredCount: 3, kind: "droppedSilently")) {
            t.expectEqual(pid, unknownID, "bad kind surfaces the performance")
            t.expect(detail.contains("droppedSilently"), "bad kind named in detail")
        } else { t.expect(false, "unsanctioned exclusion kind refused") }
        if case .failure(.invalidUnsupportedExclusion(_, let reasonDetail)) = withExclusion(
            joinExclusionJSON(performanceID: unknownID, declaredCount: 3, reason: "mysteryReason")) {
            t.expect(reasonDetail.contains("mysteryReason"), "bad reason named in detail")
        } else { t.expect(false, "unsanctioned exclusion reason refused") }
        if case .failure(.invalidUnsupportedExclusion(_, let versionDetail)) = withExclusion(
            joinExclusionJSON(performanceID: unknownID, declaredCount: 3, version: 2)) {
            t.expect(versionDetail.contains("reasonVersion=2"), "bad reason version named in detail")
        } else { t.expect(false, "unsupported exclusion reason version refused") }
    }

    // 14. Exclusion declared variant count vs actual catalog record → typed refusal.
    run("SidecarJoin.exclusionVariantCountMismatch") { t in
        let soloID = "olivia.performance.solo.p2a1"
        let unknownID = "olivia.performance.unknown.midi-p2a1"
        let result = joinJoin(
            baseJSON: joinDocumentJSON(performances: [joinSoloJSON(id: soloID), joinUnknownJSON(id: unknownID)]),
            annotations: joinStandardAnnotations(soloID: soloID),
            exclusions: [joinExclusionJSON(performanceID: unknownID, declaredCount: 5)]
        )
        t.expectEqual(joinError(result), .some(.exclusionVariantCountMismatch(performanceID: unknownID, declared: 5, actual: 3)), "declared/actual exclusion count mismatch refused")
    }

    // 15. Deterministic identity and order:
    //     (a) the EXACT same byte buffers → fully identical load (snapshot, revision, hashes);
    //     (b) output variant order is the canonical semantic-cell order regardless of the
    //         base document's listing order;
    //     (c) annotation-array order does not change the SNAPSHOT (the revision stays
    //         byte-exact per artifact, by contract).
    run("SidecarJoin.deterministicIdentityAndOrder") { t in
        // (a) identical bytes → identical load including revision. The SAME Data instances
        //     are fed to both joins (determinism is a property of identical input bytes).
        let document = joinDocumentJSON(performances: [joinSoloJSON()])
        let baseData = joinEncode(document)
        let baseSHA = PerformanceSemanticCatalogJoin.sha256Hex(of: baseData)
        let sidecarData = joinEncode(joinSidecarJSON(baseSHA: baseSHA, annotations: joinStandardAnnotations(), exclusions: []))
        let first = PerformanceSemanticCatalogJoin.join(baseCatalogData: baseData, sidecarData: sidecarData)
        let second = PerformanceSemanticCatalogJoin.join(baseCatalogData: baseData, sidecarData: sidecarData)
        guard let loadA = joinResolved(first), let loadB = joinResolved(second) else {
            t.expect(false, "both identical joins resolved")
            return
        }
        t.expectEqual(loadA, loadB, "identical byte buffers → identical closure load")
        t.expectEqual(loadA.snapshot.revision, loadB.snapshot.revision, "identical revision under identical bytes")

        // (b) canonical order: base lists night/daylight/sunset; output is daylight/sunset/night.
        let soloID = "olivia.performance.solo.p2a1"
        let scrambled = joinPerformanceJSON(id: soloID, kind: "pianoSolo", variants: [
            joinVariantJSON(id: "\(soloID).variant.night-side", rawTokens: joinRawTokens("TOD2000", "NI", "L")),
            joinVariantJSON(id: "\(soloID).variant.daylight-side", rawTokens: joinRawTokens("TOD1200", "WI", "L")),
            joinVariantJSON(id: "\(soloID).variant.sunset-side", rawTokens: joinRawTokens("TOD1730", "WI", "L")),
        ])
        let canonicalResult = joinJoin(baseJSON: joinDocumentJSON(performances: [scrambled]), annotations: joinStandardAnnotations())
        guard let canonicalLoad = joinResolved(canonicalResult) else { t.expect(false, "scrambled-order closure joined"); return }
        let canonicalTrack = canonicalLoad.snapshot.track(for: PerformanceID(soloID))
        t.expectEqual(canonicalTrack?.variants.map { $0.lighting }, [.daylight, .sunset, .night], "variant order canonicalized by semantic cell")
        t.expectEqual(canonicalTrack?.variants.map { $0.presentation }, [.sidePerformance, .sidePerformance, .sidePerformance], "presentation order preserved canonically")

        // (c) annotation-array reordering → identical snapshot content; the revision is the
        //     deterministic byte-bound composition for each artifact (by contract the joined
        //     revision binds the sidecar BYTES, so a re-serialized artifact is a different
        //     identity — the SNAPSHOT semantics never depend on array order).
        let reversed = Array(joinStandardAnnotations().reversed())
        let reversedResult = joinJoin(baseJSON: document, annotations: reversed)
        guard let reversedLoad = joinResolved(reversedResult) else { t.expect(false, "reversed-annotation closure joined"); return }
        t.expectEqual(reversedLoad.snapshot.tracks, loadA.snapshot.tracks, "annotation array order never changes the snapshot")
        t.expectEqual(reversedLoad.snapshot.revision.rawValue, "base=\(reversedLoad.baseCatalogSHA256)&semantics=\(reversedLoad.sidecarSHA256)", "revision is always the byte-bound composition of THIS artifact")
    }

    // 16. L is provenance-only in the join too: L / absent / non-L suffixes never change the
    //     joined semantics or Core admission/resolution; the suffix is retained verbatim.
    run("SidecarJoin.lingeringSuffixInert") { t in
        func closure(suffix: String?) -> PerformanceSemanticClosureLoad? {
            let soloID = "olivia.performance.solo.p2a1"
            let solo = joinPerformanceJSON(id: soloID, kind: "pianoSolo", variants: [
                joinVariantJSON(id: "\(soloID).variant.daylight-side", rawTokens: joinRawTokens("TOD1200", "WI", suffix)),
                joinVariantJSON(id: "\(soloID).variant.sunset-side", rawTokens: joinRawTokens("TOD1730", "WI", "L")),
                joinVariantJSON(id: "\(soloID).variant.night-side", rawTokens: joinRawTokens("TOD2000", "NI", "L")),
            ])
            return joinResolved(joinJoin(baseJSON: joinDocumentJSON(performances: [solo]), annotations: joinStandardAnnotations(soloID: soloID)))
        }
        guard let withL = closure(suffix: "L"), let withX = closure(suffix: "X"), let without = closure(suffix: nil) else {
            t.expect(false, "all suffix closures joined")
            return
        }
        let trackL = withL.snapshot.track(for: PerformanceID("olivia.performance.solo.p2a1"))
        let trackX = withX.snapshot.track(for: PerformanceID("olivia.performance.solo.p2a1"))
        let trackNone = without.snapshot.track(for: PerformanceID("olivia.performance.solo.p2a1"))
        t.expectEqual(trackL?.variants.map { $0.lighting }, trackX?.variants.map { $0.lighting }, "L does not change joined lighting")
        t.expectEqual(trackL?.variants.map { $0.lighting }, trackNone?.variants.map { $0.lighting }, "suffix absence does not change joined lighting")
        t.expectEqual(PerformanceTrack.catalogEligibility(trackL!), PerformanceTrack.catalogEligibility(trackX!), "L does not change Core admission")
        t.expectEqual(PerformanceTrack.catalogEligibility(trackL!), PerformanceTrack.catalogEligibility(trackNone!), "suffix absence does not change Core admission")
        // Resolution compares the resolved variant + reason only: the carried catalogRevision
        // is the ARTIFACT-bound joined revision and therefore differs across byte-different
        // closures by contract (the suffix lives in the base bytes). The resolved semantic
        // variant must be identical.
        struct ResolvedVariantCore: Equatable {
            let variantID: PerformanceVariantID
            let lighting: PerformanceLighting
            let presentation: PerformancePresentation
            let reason: PerformanceResolutionReason
        }
        func resolvedCore(_ r: VariantResolution) -> ResolvedVariantCore? {
            if case .resolved(let v) = r {
                return ResolvedVariantCore(variantID: v.variantID, lighting: v.lighting, presentation: v.presentation, reason: v.reason)
            }
            return nil
        }
        func resolveNight(_ load: PerformanceSemanticClosureLoad) -> ResolvedVariantCore? {
            resolvedCore(VariantResolver.resolve(trackID: PerformanceID("olivia.performance.solo.p2a1"), in: load.snapshot,
                                                 effectiveLighting: .night, presentationPreference: .automatic))
        }
        t.expectEqual(resolveNight(withL), resolveNight(withX), "L does not change resolution variant/reason")
        t.expectEqual(resolveNight(withL), resolveNight(without), "suffix absence does not change resolution variant/reason")
        let daylightL = trackL?.variants.first { $0.id.rawValue.hasSuffix("daylight-side") }
        let daylightX = trackX?.variants.first { $0.id.rawValue.hasSuffix("daylight-side") }
        t.expectEqual(daylightL?.provenance.suffixTokens, ["L"], "L retained verbatim")
        t.expectEqual(daylightX?.provenance.suffixTokens, ["X"], "non-L suffix retained verbatim")
    }

    // 17. Production join NEVER infers semantics from raw tokens: the annotation is the only
    //     semantic source, and an unannotated supported variant fails closed instead of being
    //     guessed.
    run("SidecarJoin.noInferenceFromRawTokens") { t in
        // (a) The annotation is authoritative even when the variant's own raw token would say
        //     otherwise: lightings are swapped BETWEEN cells (daylight-side carries the
        //     TOD1200/daylight token but is annotated sunset; sunset-side carries TOD1730 but
        //     is annotated daylight) — the exact v1 shape stays eligible, and the snapshot
        //     shows the ANNOTATED semantics, not the token-given ones.
        let soloID = "olivia.performance.solo.p2a1"
        var swapped = joinStandardAnnotations(soloID: soloID)
        swapped[0]["lighting"] = "sunset" // daylight-side variant (token TOD1200) annotated sunset
        swapped[1]["lighting"] = "daylight" // sunset-side variant (token TOD1730) annotated daylight
        let result = joinJoin(
            baseJSON: joinDocumentJSON(performances: [joinSoloJSON(id: soloID)]),
            annotations: swapped
        )
        guard let load = joinResolved(result) else { t.expect(false, "swapped-annotation closure joined"); return }
        let daylightVariant = load.snapshot.track(for: PerformanceID(soloID))?.variants.first { $0.id.rawValue.hasSuffix("daylight-side") }
        let sunsetVariant = load.snapshot.track(for: PerformanceID(soloID))?.variants.first { $0.id.rawValue.hasSuffix("sunset-side") }
        t.expectEqual(daylightVariant?.lighting, .sunset, "annotation is authoritative; the TOD1200 token is never interpreted")
        t.expectEqual(sunsetVariant?.lighting, .daylight, "annotation is authoritative; the TOD1730 token is never interpreted")
        t.expectEqual(daylightVariant?.provenance.rawTime, "TOD1200", "raw tokens survive as provenance only")
        t.expectEqual(PerformanceTrack.catalogEligibility(load.snapshot.track(for: PerformanceID(soloID))!), .eligible, "swapped cells still form the exact v1 shape")

        // (b) A supported variant with NO annotation fails closed (missingAnnotation) — never
        //     a guessed snapshot from tokens.
        var incomplete = joinStandardAnnotations(soloID: soloID)
        incomplete.removeAll { $0["variantID"] as? String == "\(soloID).variant.night-side" }
        let missing = joinJoin(
            baseJSON: joinDocumentJSON(performances: [joinSoloJSON(id: soloID)]),
            annotations: incomplete
        )
        t.expectEqual(joinError(missing), .some(.missingAnnotation(variantID: "\(soloID).variant.night-side")), "tokens-only supported variant refused — no inference fallback")
    }

    // 18. Sidecar schema / artifact contract validation: version, kind, binding format.
    run("SidecarJoin.schemaAndArtifactValidation") { t in
        let soloID = "olivia.performance.solo.p2a1"
        let baseData = joinEncode(joinDocumentJSON(performances: [joinSoloJSON(id: soloID)]))
        let baseSHA = PerformanceSemanticCatalogJoin.sha256Hex(of: baseData)
        var badSchema = joinSidecarJSON(baseSHA: baseSHA, annotations: joinStandardAnnotations(soloID: soloID), exclusions: [])
        badSchema["schemaVersion"] = 2
        t.expectEqual(joinError(PerformanceSemanticCatalogJoin.join(baseCatalogData: baseData, sidecarData: joinEncode(badSchema))),
                      .some(.unsupportedSidecarSchema(2)), "sidecar schemaVersion 2 refused")
        var badKind = joinSidecarJSON(baseSHA: baseSHA, annotations: joinStandardAnnotations(soloID: soloID), exclusions: [])
        badKind["artifactKind"] = "inferredSemanticsClosure"
        t.expectEqual(joinError(PerformanceSemanticCatalogJoin.join(baseCatalogData: baseData, sidecarData: joinEncode(badKind))),
                      .some(.invalidArtifactKind("inferredSemanticsClosure")), "unsanctioned artifact kind refused")
        var badBinding = joinSidecarJSON(baseSHA: baseSHA, annotations: joinStandardAnnotations(soloID: soloID), exclusions: [])
        badBinding["baseCatalogSHA256"] = "not-a-hash"
        t.expectEqual(joinError(PerformanceSemanticCatalogJoin.join(baseCatalogData: baseData, sidecarData: joinEncode(badBinding))),
                      .some(.invalidBaseCatalogBinding("not-a-hash")), "non-64-hex base binding refused")
    }

    // 19. Malformed / invalid data surfacing: sidecar decode failure and base-contract
    //     failures propagate typed.
    run("SidecarJoin.malformedAndBaseErrors") { t in
        let soloID = "olivia.performance.solo.p2a1"
        let baseData = joinEncode(joinDocumentJSON(performances: [joinSoloJSON(id: soloID)]))
        if case .failure(.malformedSidecarJSON) = PerformanceSemanticCatalogJoin.join(
            baseCatalogData: baseData, sidecarData: Data("{\"artifactKind\":".utf8)) {
            // expected
        } else { t.expect(false, "truncated sidecar refused as malformed") }

        // Binding passes (the sidecar claims the hash of the malformed bytes), so the base
        // external contract itself surfaces the typed malformed-JSON failure.
        let malformedBaseData = Data("{\"schemaVersion\": ".utf8)
        let malformedSidecar = joinEncode(joinSidecarJSON(
            baseSHA: PerformanceSemanticCatalogJoin.sha256Hex(of: malformedBaseData),
            annotations: joinStandardAnnotations(soloID: soloID),
            exclusions: []
        ))
        if case .failure(.baseCatalogInvalid(.malformedJSON)) = PerformanceSemanticCatalogJoin.join(
            baseCatalogData: malformedBaseData, sidecarData: malformedSidecar) {
            // expected
        } else { t.expect(false, "malformed base propagated as baseCatalogInvalid") }
        var unsupported = joinSoloJSON(id: soloID)
        unsupported["performanceKind"] = "orchestra"
        unsupported["variantCount"] = 0
        unsupported["variants"] = []
        let unsupportedData = joinEncode(joinDocumentJSON(performances: [unsupported]))
        let unsupportedSHA = PerformanceSemanticCatalogJoin.sha256Hex(of: unsupportedData)
        let unsupportedSidecar = joinEncode(joinSidecarJSON(baseSHA: unsupportedSHA, annotations: [], exclusions: []))
        t.expectEqual(joinError(PerformanceSemanticCatalogJoin.join(baseCatalogData: unsupportedData, sidecarData: unsupportedSidecar)),
                      .some(.baseCatalogInvalid(.unsupportedPerformanceKind("orchestra"))), "base kind violation propagated typed")
        var noEvidence = joinDocumentJSON(performances: [joinSoloJSON(id: soloID)])
        noEvidence.removeValue(forKey: "sourceEvidence")
        let noEvidenceData = joinEncode(noEvidence)
        let noEvidenceSHA = PerformanceSemanticCatalogJoin.sha256Hex(of: noEvidenceData)
        let noEvidenceSidecar = joinEncode(joinSidecarJSON(baseSHA: noEvidenceSHA, annotations: [], exclusions: []))
        t.expectEqual(joinError(PerformanceSemanticCatalogJoin.join(baseCatalogData: noEvidenceData, sidecarData: noEvidenceSidecar)),
                      .some(.baseCatalogInvalid(.missingRevisionIdentity)), "base revision-identity violation propagated typed")
    }

    // 20. URL/data error surfacing: the source-URL form reads ONLY the two JSON files and
    //     surfaces unreadable sources typed.
    run("SidecarJoin.urlErrorSurfacing") { t in
        let tmp = FileManager.default.temporaryDirectory
        let baseURL = tmp.appendingPathComponent("sidecar-join-tmp-base.json")
        let sidecarURL = tmp.appendingPathComponent("sidecar-join-tmp-sidecar.json")
        defer {
            try? FileManager.default.removeItem(at: baseURL)
            try? FileManager.default.removeItem(at: sidecarURL)
        }
        let soloID = "olivia.performance.solo.p2a1"
        let baseData = joinEncode(joinDocumentJSON(performances: [joinSoloJSON(id: soloID)]))
        let baseSHA = PerformanceSemanticCatalogJoin.sha256Hex(of: baseData)
        let sidecarData = joinEncode(joinSidecarJSON(baseSHA: baseSHA, annotations: joinStandardAnnotations(soloID: soloID), exclusions: []))
        do {
            try baseData.write(to: baseURL)
            try sidecarData.write(to: sidecarURL)
        } catch {
            t.expect(false, "temp fixture files written")
            return
        }
        let missingURL = tmp.appendingPathComponent("sidecar-join-tmp-missing.json")
        // Unreadable sidecar surfaces typed.
        if case .failure(.unreadableSidecar(let detail)) = PerformanceSemanticCatalogJoin.join(baseCatalogURL: baseURL, sidecarURL: missingURL) {
            t.expect(!detail.isEmpty, "unreadable sidecar carries a reason: \(detail)")
        } else {
            t.expect(false, "unreadable sidecar URL surfaced as .unreadableSidecar")
        }
        // Unreadable base surfaces typed through baseCatalogInvalid.
        if case .failure(.baseCatalogInvalid(.unreadableSource(let detail))) = PerformanceSemanticCatalogJoin.join(baseCatalogURL: missingURL, sidecarURL: sidecarURL) {
            t.expect(!detail.isEmpty, "unreadable base carries a reason: \(detail)")
        } else {
            t.expect(false, "unreadable base URL surfaced as .baseCatalogInvalid(.unreadableSource)")
        }
        // Valid files join through the URL form.
        if case .success(let load) = PerformanceSemanticCatalogJoin.join(baseCatalogURL: baseURL, sidecarURL: sidecarURL) {
            t.expectEqual(load.snapshot.tracks.count, 1, "URL form joins the same closure")
        } else {
            t.expect(false, "URL-form join succeeded")
        }
    }

    // 21. Core eligibility GATE: a complete annotation set that maps to a Core-ineligible
    //     track shape refuses the WHOLE closure typed — the join calls Core admission, never
    //     reimplements it.
    run("SidecarJoin.ineligibleSemanticClosure") { t in
        let soloID = "olivia.performance.solo.p2a1"
        // All three solo variants annotated daylight/side → missing expected cells
        // {sunset,night}, duplicate cell; Core refuses the track shape.
        let collapsed = [
            joinAnnotationJSON(variantID: "\(soloID).variant.daylight-side", lighting: "daylight", presentation: "sidePerformance"),
            joinAnnotationJSON(variantID: "\(soloID).variant.sunset-side", lighting: "daylight", presentation: "sidePerformance"),
            joinAnnotationJSON(variantID: "\(soloID).variant.night-side", lighting: "daylight", presentation: "sidePerformance"),
        ]
        let result = joinJoin(
            baseJSON: joinDocumentJSON(performances: [joinSoloJSON(id: soloID)]),
            annotations: collapsed
        )
        if case .failure(.ineligibleSemanticClosure(let pid, let issues)) = result {
            t.expectEqual(pid, soloID, "Core gate surfaces the performance")
            t.expect(!issues.isEmpty, "Core gate carries the complete ordered issue list")
            t.expect(issues.contains(.missingExpectedCell(PerformanceSemanticCell(lighting: .sunset, presentation: .sidePerformance))), "missing sunset cell in issues")
            t.expect(issues.contains(.missingExpectedCell(PerformanceSemanticCell(lighting: .night, presentation: .sidePerformance))), "missing night cell in issues")
        } else {
            t.expect(false, "Core-ineligible closure refused wholesale")
        }
    }

    // 22. REAL catalog + committed sidecar acceptance (env-gated base path, committed
    //     fixture — no media, no archive scanning). Asserts the exact base hash, the exact
    //     sidecar hash, 129 tracks / 480 variants, and exactly 3 explicit exclusions.
    run("SidecarJoin.realClosureAcceptance") { t in
        guard let basePath = ProcessInfo.processInfo.environment["BSIDEMAC_PERFORMANCE_CATALOG_V1"], !basePath.isEmpty else {
            print("      SKIP — set BSIDEMAC_PERFORMANCE_CATALOG_V1 to the accepted performance-catalog.v1.json to run the real-closure acceptance")
            return
        }
        let fixturePath = FileManager.default.currentDirectoryPath + "/scripts/fixtures/performance-semantic-sidecar.v1.json"
        guard let baseData = try? Data(contentsOf: URL(fileURLWithPath: basePath)) else {
            t.expect(false, "cannot read real base catalog \(basePath)")
            return
        }
        guard let sidecarData = try? Data(contentsOf: URL(fileURLWithPath: fixturePath)) else {
            t.expect(false, "cannot read committed sidecar fixture at \(fixturePath) (run from the repo root)")
            return
        }
        let computedBaseSHA = PerformanceSemanticCatalogJoin.sha256Hex(of: baseData)
        let computedSidecarSHA = PerformanceSemanticCatalogJoin.sha256Hex(of: sidecarData)
        t.expectEqual(computedSidecarSHA, documentedSidecarSHA256, "committed fixture byte hash matches the documented identity")
        t.expectEqual(computedBaseSHA, documentedBaseCatalogSHA256, "real base bytes hash to the documented base binding")
        switch PerformanceSemanticCatalogJoin.join(baseCatalogData: baseData, sidecarData: sidecarData) {
        case .failure(let error):
            t.expect(false, "real closure join failed: \(error)")
        case .success(let load):
            t.expectEqual(load.baseCatalogSHA256, documentedBaseCatalogSHA256, "real base bytes hash to the documented base binding")
            t.expectEqual(load.baseCatalogSHA256, load.sidecar.baseCatalogSHA256, "join validated the exact byte binding")
            t.expectEqual(load.sidecarSHA256, documentedSidecarSHA256, "joined sidecar identity is the documented artifact hash")
            t.expectEqual(load.snapshot.tracks.count, 129, "129 supported tracks (132 performances − 3 unknownGenerated)")
            let variantCount = load.snapshot.tracks.values.reduce(0) { $0 + $1.variants.count }
            t.expectEqual(variantCount, 480, "480 supported variants (483 − 3 excluded unknownGenerated variants)")
            t.expectEqual(load.sidecar.unsupportedExclusions.count, 3, "exactly 3 explicit unsupported exclusions")
            let excludedIDs = Set(load.sidecar.unsupportedExclusions.map { $0.performanceID })
            t.expectEqual(excludedIDs, Set([
                "olivia.performance.unknown.midi-31823-1784212665",
                "olivia.performance.unknown.midi-3854-1783936709",
                "olivia.performance.unknown.midi-3854-1783937285",
            ]), "exclusions name exactly the three real unknownGenerated tracks")
            let declaredCounts = load.sidecar.unsupportedExclusions.map { $0.excludedVariantCount }.sorted()
            t.expectEqual(declaredCounts, [0, 0, 3], "excluded variant counts match the real catalog records")
            for track in load.snapshot.tracks.values {
                t.expectEqual(PerformanceTrack.catalogEligibility(track), .eligible, "every joined track passes Core admission (track \(track.id.rawValue))")
            }
            t.expectEqual(load.snapshot.revision.rawValue,
                          "base=\(documentedBaseCatalogSHA256)&semantics=\(documentedSidecarSHA256)",
                          "real joined revision binds both documented byte hashes")
        }
    }
}