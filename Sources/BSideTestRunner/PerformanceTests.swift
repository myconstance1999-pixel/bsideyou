// BSideTestRunner — Performance domain (ADR-013) synthetic invariant suites.
// Pure semantic catalog admission + exact fail-closed VariantResolver. No real catalog is
// loaded: these cover the V1 shapes, resolution policy, and fail-closed boundaries.

import Foundation
import BSideCore

private func cell(_ lighting: PerformanceLighting, _ presentation: PerformancePresentation) -> PerformanceSemanticCell {
    PerformanceSemanticCell(lighting: lighting, presentation: presentation)
}

private func semanticCell(_ variant: PerformanceVariant) -> PerformanceSemanticCell {
    PerformanceSemanticCell(lighting: variant.lighting, presentation: variant.presentation)
}

private func rev(_ value: String) -> PerformanceCatalogRevision {
    PerformanceCatalogRevision(value)
}

/// Deterministic per-variant provenance used by the canonical builders.
private func defaultProvenance(_ presentation: PerformancePresentation) -> PerformanceSourceProvenance {
    PerformanceSourceProvenance(
        rawTime: "1200",
        rawView: presentation == .portraitPerformance ? "portrait" : "side",
        suffixTokens: ["TOD", "WI"]
    )
}

/// Exact V1 pianoSolo shape: daylight/sunset/night × sidePerformance.
private func canonicalSoloVariants() -> [PerformanceVariant] {
    PerformanceLighting.allCases.map {
        PerformanceVariant(
            id: PerformanceVariantID("variant://pianoSolo/\($0.rawValue)/side"),
            lighting: $0,
            presentation: .sidePerformance,
            provenance: defaultProvenance(.sidePerformance)
        )
    }
}

/// Exact V1 vocalPerformance shape: daylight/sunset/night × {side, portrait}.
private func canonicalVocalVariants() -> [PerformanceVariant] {
    var variants: [PerformanceVariant] = []
    for lighting in PerformanceLighting.allCases {
        variants.append(PerformanceVariant(
            id: PerformanceVariantID("variant://vocal/\(lighting.rawValue)/side"),
            lighting: lighting, presentation: .sidePerformance,
            provenance: defaultProvenance(.sidePerformance)
        ))
        variants.append(PerformanceVariant(
            id: PerformanceVariantID("variant://vocal/\(lighting.rawValue)/portrait"),
            lighting: lighting, presentation: .portraitPerformance,
            provenance: defaultProvenance(.portraitPerformance)
        ))
    }
    return variants
}

private func soloTrack(
    id: String = "performance://pianoSolo/1",
    variants: [PerformanceVariant]? = nil
) -> PerformanceTrack {
    PerformanceTrack(id: PerformanceID(id), kind: .pianoSolo, variants: variants ?? canonicalSoloVariants())
}

private func vocalTrack(
    id: String = "performance://vocal/1",
    variants: [PerformanceVariant]? = nil
) -> PerformanceTrack {
    PerformanceTrack(id: PerformanceID(id), kind: .vocalPerformance, variants: variants ?? canonicalVocalVariants())
}

/// Replace the provenance of the ONE variant carrying the given semantic cell (ID and cell
/// kept identical) — only the selected concrete media Variant's provenance differs.
private func replacingProvenance(
    in variants: [PerformanceVariant],
    of selected: PerformanceSemanticCell,
    with provenance: PerformanceSourceProvenance
) -> [PerformanceVariant] {
    variants.map { variant in
        semanticCell(variant) == selected
            ? PerformanceVariant(id: variant.id, lighting: variant.lighting, presentation: variant.presentation, provenance: provenance)
            : variant
    }
}

private func resolved(_ r: VariantResolution) -> ResolvedPerformanceVariant? {
    if case .resolved(let v) = r { return v }
    return nil
}

private func failed(_ r: VariantResolution) -> VariantResolverFailure? {
    if case .failed(let f) = r { return f }
    return nil
}

func runPerformanceTests() {
    // 1. Valid Solo admission.
    run("Performance.admission.validSolo") { t in
        let track = soloTrack()
        t.expectEqual(PerformanceTrack.catalogEligibility(track), .eligible, "solo exact V1 shape eligible")
        t.expectEqual(track.variants.count, 3, "solo carries exactly 3 variants")
        t.expectEqual(Set(track.variants.map { $0.presentation }), [.sidePerformance], "solo only side")
    }

    // 2. Valid Vocal admission.
    run("Performance.admission.validVocal") { t in
        let track = vocalTrack()
        t.expectEqual(PerformanceTrack.catalogEligibility(track), .eligible, "vocal exact V1 shape eligible")
        t.expectEqual(track.variants.count, 6, "vocal carries exactly 6 variants")
        t.expectEqual(Set(track.variants.map { $0.presentation }), [.sidePerformance, .portraitPerformance], "vocal side + portrait")
    }

    // 3. Automatic Solo presentation (v1 policy: pianoSolo → side).
    run("Performance.resolve.soloAutomatic") { t in
        let track = soloTrack()
        let r = VariantResolver.resolve(track: track, effectiveLighting: .night, presentationPreference: .automatic, catalogRevision: rev("7"))
        guard let v = resolved(r) else { t.expect(false, "solo automatic night resolved"); return }
        t.expectEqual(v.performanceID, track.id, "performanceID")
        t.expectEqual(v.variantID, PerformanceVariantID("variant://pianoSolo/night/side"), "exact variantID")
        t.expectEqual(v.lighting, .night, "resolved lighting")
        t.expectEqual(v.presentation, .sidePerformance, "automatic → side")
        t.expectEqual(v.catalogRevision, rev("7"), "catalog revision")
        t.expectEqual(v.reason, .automaticPolicy, "automatic policy reason")
    }

    // 4. Automatic Vocal presentation (v1 policy: vocalPerformance → side).
    run("Performance.resolve.vocalAutomatic") { t in
        let r = VariantResolver.resolve(track: vocalTrack(), effectiveLighting: .sunset, presentationPreference: .automatic, catalogRevision: rev("2"))
        guard let v = resolved(r) else { t.expect(false, "vocal automatic sunset resolved"); return }
        t.expectEqual(v.variantID, PerformanceVariantID("variant://vocal/sunset/side"), "automatic → side cell")
        t.expectEqual(v.presentation, .sidePerformance, "presentation side")
        t.expectEqual(v.reason, .automaticPolicy, "automatic policy reason")
    }

    // 5. Exact explicit Side.
    run("Performance.resolve.explicitSide") { t in
        let r = VariantResolver.resolve(track: vocalTrack(), effectiveLighting: .daylight, presentationPreference: .explicit(.sidePerformance), catalogRevision: rev("3"))
        guard let v = resolved(r) else { t.expect(false, "explicit side resolved"); return }
        t.expectEqual(v.variantID, PerformanceVariantID("variant://vocal/daylight/side"), "exact side variantID")
        t.expectEqual(v.presentation, .sidePerformance, "presentation side")
        t.expectEqual(v.reason, .explicitUserPreference, "explicit user preference reason")
    }

    // 6. Exact explicit Portrait.
    run("Performance.resolve.explicitPortrait") { t in
        let r = VariantResolver.resolve(track: vocalTrack(), effectiveLighting: .night, presentationPreference: .explicit(.portraitPerformance), catalogRevision: rev("4"))
        guard let v = resolved(r) else { t.expect(false, "vocal night portrait resolved"); return }
        t.expectEqual(v.variantID, PerformanceVariantID("variant://vocal/night/portrait"), "exact semantic variantID")
        t.expectEqual(v.lighting, .night, "resolved lighting")
        t.expectEqual(v.presentation, .portraitPerformance, "presentation portrait")
        t.expectEqual(v.reason, .explicitUserPreference, "explicit user preference reason")
    }

    // 7. Unsupported Solo Portrait (explicit portrait requires exact support; retained for a
    //    semantically eligible pianoSolo track — full admission passes, preference is refused).
    run("Performance.resolve.soloPortraitUnsupported") { t in
        let r = VariantResolver.resolve(track: soloTrack(), effectiveLighting: .daylight, presentationPreference: .explicit(.portraitPerformance), catalogRevision: rev("1"))
        t.expectEqual(failed(r), .some(.unsupportedPresentation(.portraitPerformance, kind: .pianoSolo)), "pianoSolo + portrait → unsupportedPresentation")
    }

    // 8. Missing semantic cell → catalogInconsistent (admission AND resolver agree).
    run("Performance.resolve.missingCellInconsistent") { t in
        var variants = canonicalVocalVariants()
        variants.removeAll { $0.lighting == .night && $0.presentation == .portraitPerformance }
        let track = vocalTrack(variants: variants)
        t.expectEqual(PerformanceTrack.catalogEligibility(track), .ineligible([.missingExpectedCell(cell(.night, .portraitPerformance))]), "admission flags missing night×portrait")
        let r = VariantResolver.resolve(track: track, effectiveLighting: .night, presentationPreference: .explicit(.portraitPerformance), catalogRevision: rev("5"))
        t.expectEqual(failed(r), .some(.catalogInconsistent([.missingExpectedCell(cell(.night, .portraitPerformance))])), "resolver refuses missing cell")
    }

    // 9. Duplicate semantic cell → catalogInconsistent (never ambiguous).
    run("Performance.resolve.duplicateCellInconsistent") { t in
        var variants = canonicalSoloVariants()
        variants.append(PerformanceVariant(id: PerformanceVariantID("variant://pianoSolo/night/side/dup"), lighting: .night, presentation: .sidePerformance, provenance: defaultProvenance(.sidePerformance)))
        let track = soloTrack(variants: variants)
        t.expectEqual(PerformanceTrack.catalogEligibility(track), .ineligible([.duplicateSemanticCell(cell(.night, .sidePerformance))]), "admission flags duplicate")
        let r = VariantResolver.resolve(track: track, effectiveLighting: .night, presentationPreference: .automatic, catalogRevision: rev("5"))
        t.expectEqual(failed(r), .some(.catalogInconsistent([.duplicateSemanticCell(cell(.night, .sidePerformance))])), "resolver refuses ambiguous cell")
    }

    // 10. unknownGenerated / unsupported kind never admit and never resolve.
    run("Performance.resolve.unknownGeneratedRejected") { t in
        let track = PerformanceTrack(
            id: PerformanceID("performance://unknown/1"),
            kind: .unknownGenerated,
            variants: canonicalSoloVariants()
        )
        t.expectEqual(PerformanceTrack.catalogEligibility(track), .ineligible([.unknownGeneratedKind]), "unknownGenerated never admissible")
        let r = VariantResolver.resolve(track: track, effectiveLighting: .night, presentationPreference: .automatic, catalogRevision: rev("1"))
        t.expectEqual(failed(r), .some(.catalogInconsistent([.unknownGeneratedKind])), "resolver rejects unknownGenerated")
    }

    // 11. Unsupported structural shape / invalid identity → structured admission failures.
    run("Performance.admission.invalidShapeAndIdentity") { t in
        // extra structural shape: portrait cell on a pianoSolo
        var extra = canonicalSoloVariants()
        extra.append(PerformanceVariant(id: PerformanceVariantID("variant://pianoSolo/daylight/portrait"), lighting: .daylight, presentation: .portraitPerformance, provenance: defaultProvenance(.portraitPerformance)))
        t.expectEqual(PerformanceTrack.catalogEligibility(soloTrack(variants: extra)), .ineligible([.unsupportedExtraShape(cell(.daylight, .portraitPerformance))]), "extra portrait cell on solo")

        // missing expected cell
        var missing = canonicalSoloVariants()
        missing.removeAll { $0.lighting == .sunset }
        t.expectEqual(PerformanceTrack.catalogEligibility(soloTrack(variants: missing)), .ineligible([.missingExpectedCell(cell(.sunset, .sidePerformance))]), "missing sunset side cell")

        // structurally unusable track identity (empty)
        t.expectEqual(PerformanceTrack.catalogEligibility(soloTrack(id: "")), .ineligible([.unusableIdentity]), "empty track id")

        // structurally unusable variant reference (empty)
        var badRef = canonicalSoloVariants()
        badRef[0] = PerformanceVariant(id: PerformanceVariantID(""), lighting: .daylight, presentation: .sidePerformance, provenance: defaultProvenance(.sidePerformance))
        t.expectEqual(PerformanceTrack.catalogEligibility(soloTrack(variants: badRef)), .ineligible([.unusableReference]), "empty variant id")

        // zero variants → every expected cell missing (in documented order)
        let allMissing: [PerformanceCatalogIssue] = PerformanceLighting.allCases.map {
            .missingExpectedCell(cell($0, .sidePerformance))
        }
        t.expectEqual(PerformanceTrack.catalogEligibility(soloTrack(variants: [])), .ineligible(allMissing), "empty variant list → all cells missing")
    }

    // 12. Invalid effective lighting is NOT representable: the enum is closed at the
    //     accepted policy boundary — no speculative case; absent lighting cells fail typed.
    run("Performance.lighting.closedShape") { t in
        t.expectEqual(PerformanceLighting.allCases, [.daylight, .sunset, .night], "closed lighting set (declaration order)")
        t.expectNil(PerformanceLighting(rawValue: "dawn"), "no invented lighting case")
        for lighting in PerformanceLighting.allCases {
            let r = VariantResolver.resolve(track: vocalTrack(), effectiveLighting: lighting, presentationPreference: .explicit(.portraitPerformance), catalogRevision: rev("9"))
            guard let v = resolved(r) else { t.expect(false, "portrait \(lighting.rawValue) resolved"); continue }
            t.expectEqual(v.lighting, lighting, "\(lighting.rawValue) preserved")
        }
        var missing = canonicalVocalVariants()
        missing.removeAll { $0.lighting == .daylight && $0.presentation == .portraitPerformance }
        let r = VariantResolver.resolve(track: vocalTrack(variants: missing), effectiveLighting: .daylight, presentationPreference: .explicit(.portraitPerformance), catalogRevision: rev("9"))
        t.expectEqual(failed(r), .some(.catalogInconsistent([.missingExpectedCell(cell(.daylight, .portraitPerformance))])), "absent lighting cell fails closed")
    }

    // 13. Deterministic result independent of input ordering.
    run("Performance.resolve.inputOrderIndependent") { t in
        let canonical = canonicalVocalVariants()
        let orderA = [canonical[0], canonical[2], canonical[1], canonical[5], canonical[4], canonical[3]]
        let orderB = [canonical[5], canonical[4], canonical[3], canonical[2], canonical[1], canonical[0]]
        let rA = VariantResolver.resolve(track: vocalTrack(variants: orderA), effectiveLighting: .night, presentationPreference: .explicit(.portraitPerformance), catalogRevision: rev("11"))
        let rB = VariantResolver.resolve(track: vocalTrack(variants: orderB), effectiveLighting: .night, presentationPreference: .explicit(.portraitPerformance), catalogRevision: rev("11"))
        t.expectEqual(rA, rB, "resolution identical under reordering")
    }

    // 14. Raw provenance of the SELECTED Variant does not alter resolution (provenance is
    //     variant-level, never semantics; semantic cell and ID stay identical).
    run("Performance.resolve.provenanceIndependent") { t in
        let p1 = PerformanceSourceProvenance(rawTime: "1200", rawView: "side", suffixTokens: ["TOD"])
        let p2 = PerformanceSourceProvenance(rawTime: "17:30", rawView: "WIDE", suffixTokens: ["WI", "NI", "custom-suffix"])
        let base = canonicalSoloVariants()
        let selected = cell(.daylight, .sidePerformance)
        let r1 = VariantResolver.resolve(track: soloTrack(variants: replacingProvenance(in: base, of: selected, with: p1)), effectiveLighting: .daylight, presentationPreference: .automatic, catalogRevision: rev("13"))
        let r2 = VariantResolver.resolve(track: soloTrack(variants: replacingProvenance(in: base, of: selected, with: p2)), effectiveLighting: .daylight, presentationPreference: .automatic, catalogRevision: rev("13"))
        guard let v1 = resolved(r1), let v2 = resolved(r2) else { t.expect(false, "both resolved"); return }
        t.expectEqual(v1.variantID, v2.variantID, "same variantID")
        t.expectEqual(v1.lighting, v2.lighting, "same lighting")
        t.expectEqual(v1.presentation, v2.presentation, "same presentation")
        t.expectEqual(r1, r2, "whole resolutions equal")
    }

    // 15. L never affects resolution; tokens are retained verbatim as variant provenance only.
    run("Performance.resolve.lingeringSuffixIgnored") { t in
        let base = canonicalSoloVariants()
        let selected = cell(.night, .sidePerformance)
        let noL = soloTrack(variants: replacingProvenance(in: base, of: selected, with: PerformanceSourceProvenance(rawTime: "1200", rawView: "side", suffixTokens: ["TOD", "NI"])))
        let withL = soloTrack(variants: replacingProvenance(in: base, of: selected, with: PerformanceSourceProvenance(rawTime: "1200", rawView: "side", suffixTokens: ["TOD", "NI", "L"])))
        let lOnly = soloTrack(variants: replacingProvenance(in: base, of: selected, with: PerformanceSourceProvenance(rawTime: "1200", rawView: "side", suffixTokens: ["L", "L2", "L3"])))
        let rA = VariantResolver.resolve(track: noL, effectiveLighting: .night, presentationPreference: .automatic, catalogRevision: rev("15"))
        let rB = VariantResolver.resolve(track: withL, effectiveLighting: .night, presentationPreference: .automatic, catalogRevision: rev("15"))
        let rC = VariantResolver.resolve(track: lOnly, effectiveLighting: .night, presentationPreference: .automatic, catalogRevision: rev("15"))
        t.expectEqual(rA, rB, "L suffix does not alter resolution")
        t.expectEqual(rA, rC, "L-only tokens do not alter resolution")
        let selectedVariant = withL.variants.first { semanticCell($0) == selected }
        t.expectEqual(selectedVariant?.provenance.suffixTokens ?? [], ["TOD", "NI", "L"], "tokens retained verbatim as variant provenance")
        t.expectEqual(selectedVariant?.provenance.rawTime ?? "", "1200", "raw time retained verbatim on the variant")
    }

    // 16. IDs/domain carry no display identity; resolution surface is exactly six fields.
    run("Performance.domain.noDisplayIdentity") { t in
        let track = vocalTrack()
        let r = VariantResolver.resolve(track: track, effectiveLighting: .night, presentationPreference: .explicit(.portraitPerformance), catalogRevision: rev("16"))
        guard let v = resolved(r) else { t.expect(false, "resolved"); return }
        let obj = try? JSONEncoder().encode(v)
        let keys = obj.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?.keys.sorted()
        t.expectEqual(keys ?? [], ["catalogRevision", "lighting", "performanceID", "presentation", "reason", "variantID"], "only the six sanctioned resolution fields")

        // whole snapshot surface has no display/screen concept and an opaque revision
        let snapshot = PerformanceCatalogSnapshot(revision: rev("16"), tracks: [track.id: track])
        let snapObj = try? JSONEncoder().encode(snapshot)
        let snapKeys = snapObj.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?.keys.sorted()
        t.expectEqual(snapKeys ?? [], ["revision", "tracks"], "snapshot surface: revision + tracks only")

        // IDs are opaque: display-looking strings are never interpreted
        let opaque = vocalTrack(id: "performance://vocal/display-1-left-screen")
        t.expectNotNil(resolved(VariantResolver.resolve(track: opaque, effectiveLighting: .daylight, presentationPreference: .explicit(.sidePerformance), catalogRevision: rev("16"))), "display-looking id resolves identically")
    }

    // 17. Resolver requires no runtime media availability (no playableVariantSet input).
    run("Performance.resolve.noRuntimeAvailability") { t in
        let track = vocalTrack()
        let snapshot = PerformanceCatalogSnapshot(revision: rev("17"), tracks: [track.id: track])
        let obj = try? JSONEncoder().encode(snapshot)
        let keys = obj.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?.keys.sorted()
        t.expectEqual(keys ?? [], ["revision", "tracks"], "catalog model has no availability/playable fields")

        // snapshot lookup resolves purely on semantics; revision flows from the snapshot
        let r = VariantResolver.resolve(trackID: track.id, in: snapshot, effectiveLighting: .daylight, presentationPreference: .automatic)
        guard let v = resolved(r) else { t.expect(false, "snapshot lookup resolved"); return }
        t.expectEqual(v.performanceID, track.id, "track identity from lookup")
        t.expectEqual(v.catalogRevision, rev("17"), "revision from snapshot")

        // unknown track id in snapshot → typed catalogInconsistent, not a runtime fallback
        let missing = VariantResolver.resolve(trackID: PerformanceID("performance://vocal/nope"), in: snapshot, effectiveLighting: .daylight, presentationPreference: .automatic)
        t.expectEqual(failed(missing), .some(.catalogInconsistent([.trackNotFound(PerformanceID("performance://vocal/nope"))])), "snapshot miss fails closed")
    }

    // 18. Full-track admission: a request for an EXISTING cell still fails when another
    //     expected cell is missing (fail-closed at Track level, before exact selection).
    run("Performance.resolve.admissionGateMissingCell") { t in
        var variants = canonicalVocalVariants()
        variants.removeAll { $0.lighting == .daylight && $0.presentation == .portraitPerformance }
        let track = vocalTrack(variants: variants)
        t.expectEqual(PerformanceTrack.catalogEligibility(track), .ineligible([.missingExpectedCell(cell(.daylight, .portraitPerformance))]), "admission flags the missing unrelated cell")
        let r = VariantResolver.resolve(track: track, effectiveLighting: .night, presentationPreference: .explicit(.portraitPerformance), catalogRevision: rev("18"))
        t.expectEqual(failed(r), .some(.catalogInconsistent([.missingExpectedCell(cell(.daylight, .portraitPerformance))])), "existing night×portrait request fails on missing unrelated cell")
    }

    // 19. Full-track admission: a request for an EXISTING cell still fails when an
    //     unsupported extra structural cell exists.
    run("Performance.resolve.admissionGateExtraShape") { t in
        var variants = canonicalSoloVariants()
        variants.append(PerformanceVariant(
            id: PerformanceVariantID("variant://pianoSolo/daylight/portrait"),
            lighting: .daylight, presentation: .portraitPerformance,
            provenance: defaultProvenance(.portraitPerformance)
        ))
        let track = soloTrack(variants: variants)
        t.expectEqual(PerformanceTrack.catalogEligibility(track), .ineligible([.unsupportedExtraShape(cell(.daylight, .portraitPerformance))]), "admission flags the extra structural cell")
        let r = VariantResolver.resolve(track: track, effectiveLighting: .daylight, presentationPreference: .automatic, catalogRevision: rev("19"))
        t.expectEqual(failed(r), .some(.catalogInconsistent([.unsupportedExtraShape(cell(.daylight, .portraitPerformance))])), "existing daylight×side request fails on the extra structural cell")
    }

    // 20. Two different semantic cells reusing one PerformanceVariantID is a typed
    //     identity/reference inconsistency: the whole track is refused, never one collision
    //     chosen arbitrarily.
    run("Performance.admission.duplicateVariantIdRejected") { t in
        var variants = canonicalVocalVariants()
        let shared = PerformanceVariantID("variant://vocal/reused")
        variants[0] = PerformanceVariant(id: shared, lighting: .daylight, presentation: .sidePerformance, provenance: defaultProvenance(.sidePerformance))
        variants[4] = PerformanceVariant(id: shared, lighting: .night, presentation: .sidePerformance, provenance: defaultProvenance(.sidePerformance))
        let track = vocalTrack(variants: variants)
        t.expectEqual(PerformanceTrack.catalogEligibility(track), .ineligible([.duplicateVariantReference(shared)]), "reused variant ID across different cells refused")
        let r = VariantResolver.resolve(track: track, effectiveLighting: .daylight, presentationPreference: .automatic, catalogRevision: rev("20"))
        t.expectEqual(failed(r), .some(.catalogInconsistent([.duplicateVariantReference(shared)])), "resolver refuses the ID collision deterministically")
    }

    // 21. Empty or whitespace-only track/variant IDs are structurally unusable (pure Swift
    //     blank check; no Foundation in Core); resolution fails closed on them too.
    run("Performance.admission.blankWhitespaceIdentityRejected") { t in
        t.expectEqual(PerformanceTrack.catalogEligibility(soloTrack(id: " \t \n ")), .ineligible([.unusableIdentity]), "whitespace-only track id unusable")

        var ws = canonicalSoloVariants()
        ws[0] = PerformanceVariant(id: PerformanceVariantID(" \t "), lighting: .daylight, presentation: .sidePerformance, provenance: defaultProvenance(.sidePerformance))
        t.expectEqual(PerformanceTrack.catalogEligibility(soloTrack(variants: ws)), .ineligible([.unusableReference]), "whitespace-only variant id unusable")

        t.expectEqual(PerformanceTrack.catalogEligibility(soloTrack(id: "")), .ineligible([.unusableIdentity]), "empty track id remains unusable")

        let r = VariantResolver.resolve(track: soloTrack(id: " \t "), effectiveLighting: .daylight, presentationPreference: .automatic, catalogRevision: rev("21"))
        t.expectEqual(failed(r), .some(.catalogInconsistent([.unusableIdentity])), "whitespace-only track id fails resolution")
    }

    // 22. The opaque catalog revision must be usable to resolve against: an empty or
    //     whitespace-only revision is a structured catalog inconsistency (also via lookup).
    run("Performance.resolve.unusableRevisionRejected") { t in
        let track = soloTrack()
        let empty = VariantResolver.resolve(track: track, effectiveLighting: .daylight, presentationPreference: .automatic, catalogRevision: PerformanceCatalogRevision(""))
        t.expectEqual(failed(empty), .some(.catalogInconsistent([.unusableRevision])), "empty revision rejected")

        let blank = VariantResolver.resolve(track: track, effectiveLighting: .daylight, presentationPreference: .automatic, catalogRevision: PerformanceCatalogRevision(" \t "))
        t.expectEqual(failed(blank), .some(.catalogInconsistent([.unusableRevision])), "whitespace-only revision rejected")

        let snapshot = PerformanceCatalogSnapshot(revision: PerformanceCatalogRevision("  \n  "), tracks: [track.id: track])
        let viaSnapshot = VariantResolver.resolve(trackID: track.id, in: snapshot, effectiveLighting: .daylight, presentationPreference: .automatic)
        t.expectEqual(failed(viaSnapshot), .some(.catalogInconsistent([.unusableRevision])), "blank revision rejected via snapshot lookup too")
    }
}