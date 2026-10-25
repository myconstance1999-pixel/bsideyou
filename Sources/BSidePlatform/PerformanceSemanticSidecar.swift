// BSidePlatform — PerformanceSemanticSidecar + PerformanceSemanticCatalogJoin (Slice 2A.1;
// ADR-013): the explicit reviewed semantic normalization artifact and the deterministic
// production JOIN (base catalog bytes + sidecar bytes → BSideCore PerformanceCatalogSnapshot).
//
// Slice 2A established that the real v1 evidence catalog carries raw TOD/NI/WI/L provenance
// tokens ONLY (explicitly "no semantic claim"), so a full Core snapshot mapping requires a
// reviewed semantic source that Slice 2A deliberately never inferred. Slice 2A.1 supplies
// that source as an OFFLINE-reviewed sidecar artifact:
//
//   performance-semantic-sidecar.v1.json
//     schemaVersion          — 1
//     artifactKind           — "performanceCatalogV1SemanticClosure"
//     baseCatalogSHA256      — exact SHA-256 of the base catalog BYTES (byte-identical binding)
//     variantAnnotations[]   — explicit per-variant normalized lighting/presentation
//                              (+ documentary semanticSource: reviewedToken | explicitOverride)
//     unsupportedExclusions[] — explicit unknownGenerated track exclusions (version-aware
//                              unsupported reason) — never silently dropped, never annotated
//
// NON-NEGOTIABLE BOUNDARIES (Slice 2A.1):
//  - Production NEVER derives semantics from raw TOD/NI/WI/L tokens. Token translation lives
//    ONLY in the offline deterministic builder (scripts/build_performance_semantic_sidecar.swift)
//    with its exact reviewed mapping and override table. This file contains NO token knowledge
//    and never reads sourceTimeCode/sourceViewCode/sourceSuffixCode for semantics; the join
//    consumes explicit annotations only.
//  - The sidecar binds the exact base catalog byte SHA-256; the sidecar bytes' own SHA-256
//    participates in the joined revision/identity ("base=<baseSHA>&semantics=<sidecarSHA>").
//  - Supported variants require complete, explicit, noncontradictory annotations: missing,
//    duplicate, foreign, invalid, unsupported, base-identity-mismatch, or Core-ineligible
//    closures fail closed deterministically.
//  - unknownGenerated tracks are NEVER assigned fake lighting/presentation; they appear as
//    EXACT unsupported exclusions (no missing, extra, or duplicate exclusions).
//  - No media, no archive scanning, no absolute paths, no clocks/randomness; loading cost is
//    bounded by the two byte buffers (plus the base source-URL forms read those JSON files only).
//  - Core semantic admission (PerformanceTrack.catalogEligibility) remains the authority: the
//    join CALLS it as a final fail-closed gate and never reimplements admission.

import Foundation
import CryptoKit
import BSideCore

// MARK: - Sidecar v1 DTOs

/// One explicit reviewed annotation: the normalized semantics for ONE concrete Variant.
/// `semanticSource` is documentary provenance of how the semantics were reviewed
/// (`reviewedToken` = deterministic translation of already-review TOD/NI/WI tokens by the
/// offline builder; `explicitOverride` = the exact reviewed override table for
/// rawTokens-null source variants). The production join never interprets either value beyond
/// validating it is a sanctioned source.
public struct PerformanceSemanticVariantAnnotation: Codable, Equatable {
    public let variantID: String
    public let lighting: String
    public let presentation: String
    public let semanticSource: String

    public init(variantID: String, lighting: String, presentation: String, semanticSource: String) {
        self.variantID = variantID
        self.lighting = lighting
        self.presentation = presentation
        self.semanticSource = semanticSource
    }
}

/// One explicit unsupported-track exclusion. unknownGenerated tracks are never annotated and
/// never silently dropped: the closure artifact records them here with a version-aware
/// unsupported reason and the exact number of excluded variant records.
public struct PerformanceSemanticUnsupportedExclusion: Codable, Equatable {
    public let performanceID: String
    public let kind: String
    public let reason: String
    public let reasonVersion: Int
    public let excludedVariantCount: Int

    public init(performanceID: String, kind: String, reason: String, reasonVersion: Int, excludedVariantCount: Int) {
        self.performanceID = performanceID
        self.kind = kind
        self.reason = reason
        self.reasonVersion = reasonVersion
        self.excludedVariantCount = excludedVariantCount
    }
}

/// The external semantic sidecar document (Platform DTO). Decodes exactly the artifact fields
/// above (unknown/additional keys are ignored, like the base v1 DTO). Annotations are an
/// ARRAY so duplicates are detectable — a dictionary would silently collapse them.
public struct PerformanceSemanticSidecarDocument: Codable, Equatable {
    public let schemaVersion: Int
    public let artifactKind: String
    public let baseCatalogSHA256: String
    public let variantAnnotations: [PerformanceSemanticVariantAnnotation]
    public let unsupportedExclusions: [PerformanceSemanticUnsupportedExclusion]

    public init(
        schemaVersion: Int,
        artifactKind: String,
        baseCatalogSHA256: String,
        variantAnnotations: [PerformanceSemanticVariantAnnotation],
        unsupportedExclusions: [PerformanceSemanticUnsupportedExclusion]
    ) {
        self.schemaVersion = schemaVersion
        self.artifactKind = artifactKind
        self.baseCatalogSHA256 = baseCatalogSHA256
        self.variantAnnotations = variantAnnotations
        self.unsupportedExclusions = unsupportedExclusions
    }
}

// MARK: - Sanctioned closure contract constants

/// The sanctioned constants of the semantic sidecar contract. These are artifact CONTRACT
/// values only — none of them is a token→semantic mapping; the offline builder owns all
/// reviewed token knowledge.
public enum PerformanceSemanticSidecar {
    /// The only supported sidecar schema version.
    public static let supportedSchemaVersion = 1
    /// The only sanctioned artifact kind signature.
    public static let sanctionedArtifactKind = "performanceCatalogV1SemanticClosure"
    /// Sanctioned documentary annotation sources.
    public static let sanctionedAnnotationSources: Set<String> = ["explicitOverride", "reviewedToken"]
    /// The only kind that is ever explicitly excluded (never annotated).
    public static let sanctionedUnsupportedKind = "unknownGenerated"
    /// Version-aware unsupported reason for excluded tracks.
    public static let sanctionedUnsupportedReason = "unknownGeneratedUnsupported"
    /// Version of the unsupported reason contract (bump when the exclusion contract evolves).
    public static let sanctionedUnsupportedReasonVersion = 1
}

// MARK: - Typed closure failures

/// Typed semantic-closure failures. Fail-closed and deterministic: every case maps to an
/// explicit reason; nothing is repaired, fuzzily recovered, inferred, or silently dropped.
public enum PerformanceSemanticClosureError: Error, Equatable, CustomStringConvertible {
    /// The sidecar JSON could not be parsed or decoded.
    case malformedSidecarJSON(String)
    /// The sidecar file could not be read (source-URL form only).
    case unreadableSidecar(String)
    /// `schemaVersion` is not the supported value 1.
    case unsupportedSidecarSchema(Int)
    /// `artifactKind` is not the sanctioned closure signature.
    case invalidArtifactKind(String)
    /// `baseCatalogSHA256` is not exactly 64 lowercase hex characters.
    case invalidBaseCatalogBinding(String)
    /// The sidecar's claimed base binding does not equal the actual SHA-256 of the supplied
    /// base catalog bytes — the artifact is not bound to these exact bytes.
    case baseCatalogHashMismatch(expected: String, actual: String)
    /// The base catalog itself failed the v1 external contract (typed load error propagated).
    case baseCatalogInvalid(PerformanceCatalogLoadError)
    /// A supported variant has no annotation in the sidecar — the closure is incomplete.
    case missingAnnotation(variantID: String)
    /// The same variant appears more than once in the annotation list.
    case duplicateAnnotation(variantID: String)
    /// An annotation names a variant that is not a supported variant of the bound catalog
    /// (unknown ID, or an unknownGenerated variant which is never annotated).
    case foreignAnnotation(variantID: String)
    /// An annotation lighting is outside the closed set (daylight/sunset/night).
    case invalidAnnotationLighting(variantID: String, value: String)
    /// An annotation presentation is outside the closed set (side/portrait).
    case invalidAnnotationPresentation(variantID: String, value: String)
    /// An annotation `semanticSource` is not a sanctioned source.
    case invalidAnnotationSource(variantID: String, value: String)
    /// An annotation contradicts an explicit normalized claim already carried by the base
    /// variant record (base explicit semantics must never disagree with reviewed annotations).
    case annotationContradictsBase(performanceID: String, variantID: String, detail: String)
    /// An unknownGenerated track has no explicit exclusion.
    case missingUnsupportedExclusion(performanceID: String)
    /// The same performance appears more than once in the exclusion list.
    case duplicateUnsupportedExclusion(performanceID: String)
    /// An exclusion names a performance that is not an unknownGenerated track of the bound
    /// catalog.
    case foreignUnsupportedExclusion(performanceID: String)
    /// An exclusion record violates the sanctioned unsupported contract (kind/reason/version).
    case invalidUnsupportedExclusion(performanceID: String, detail: String)
    /// An exclusion's declared excluded-variant-count disagrees with the catalog record.
    case exclusionVariantCountMismatch(performanceID: String, declared: Int, actual: Int)
    /// The full closure maps into Core but Core admission refuses a track (typed, with the
    /// COMPLETE ordered issue list from the authoritative Core eligibility — Core refuses the
    /// whole closure, never a partial snapshot).
    case ineligibleSemanticClosure(performanceID: String, issues: [PerformanceCatalogIssue])

    public var description: String {
        switch self {
        case .malformedSidecarJSON(let detail): return "Malformed semantic sidecar JSON: \(detail)"
        case .unreadableSidecar(let detail): return "Cannot read semantic sidecar: \(detail)"
        case .unsupportedSidecarSchema(let v): return "Unsupported semantic sidecar schema version \(v) (supported: 1)"
        case .invalidArtifactKind(let kind): return "Invalid semantic sidecar artifact kind: \(kind)"
        case .invalidBaseCatalogBinding(let v): return "Invalid base catalog binding (must be 64 lowercase hex): \(v)"
        case .baseCatalogHashMismatch(let expected, let actual):
            return "Semantic sidecar is not bound to these base catalog bytes (claimed \(expected), actual \(actual))"
        case .baseCatalogInvalid(let error): return "Base catalog failed its external contract: \(error)"
        case .missingAnnotation(let variantID): return "Missing semantic annotation for variant \(variantID)"
        case .duplicateAnnotation(let variantID): return "Duplicate semantic annotation for variant \(variantID)"
        case .foreignAnnotation(let variantID): return "Foreign semantic annotation (not a supported variant): \(variantID)"
        case .invalidAnnotationLighting(let variantID, let value): return "Invalid annotation lighting \(value) for variant \(variantID)"
        case .invalidAnnotationPresentation(let variantID, let value): return "Invalid annotation presentation \(value) for variant \(variantID)"
        case .invalidAnnotationSource(let variantID, let value): return "Invalid annotation semanticSource \(value) for variant \(variantID)"
        case .annotationContradictsBase(let pid, let vid, let detail):
            return "Annotation for \(vid) (performance \(pid)) contradicts the base catalog: \(detail)"
        case .missingUnsupportedExclusion(let pid): return "Missing explicit unsupported exclusion for \(pid)"
        case .duplicateUnsupportedExclusion(let pid): return "Duplicate unsupported exclusion for \(pid)"
        case .foreignUnsupportedExclusion(let pid): return "Foreign unsupported exclusion (not an unknownGenerated track): \(pid)"
        case .invalidUnsupportedExclusion(let pid, let detail):
            return "Invalid unsupported exclusion for \(pid): \(detail)"
        case .exclusionVariantCountMismatch(let pid, let declared, let actual):
            return "Exclusion variant-count mismatch for \(pid): declared \(declared), actual \(actual)"
        case .ineligibleSemanticClosure(let pid, let issues):
            return "Semantic closure is Core-ineligible for \(pid): \(issues.map { String(describing: $0) }.joined(separator: "; "))"
        }
    }
}

// MARK: - Closure load result

/// A successful semantic closure: the Core snapshot (joined revision), the validated base
/// document, the validated sidecar, and the two bound byte hashes (base + sidecar) that the
/// joined revision/identity is composed from.
public struct PerformanceSemanticClosureLoad: Equatable {
    public let snapshot: PerformanceCatalogSnapshot
    public let document: PerformanceCatalogV1Document
    public let sidecar: PerformanceSemanticSidecarDocument
    public let baseCatalogSHA256: String
    public let sidecarSHA256: String

    public init(
        snapshot: PerformanceCatalogSnapshot,
        document: PerformanceCatalogV1Document,
        sidecar: PerformanceSemanticSidecarDocument,
        baseCatalogSHA256: String,
        sidecarSHA256: String
    ) {
        self.snapshot = snapshot
        self.document = document
        self.sidecar = sidecar
        self.baseCatalogSHA256 = baseCatalogSHA256
        self.sidecarSHA256 = sidecarSHA256
    }
}

// MARK: - Deterministic production join

/// Deterministic production join: base catalog bytes + semantic sidecar bytes → validated
/// BSideCore PerformanceCatalogSnapshot. Reads nothing but the two byte buffers (and the two
/// explicitly supplied source files in the URL form); never media, never archives, never
/// tokens-for-semantics.
public enum PerformanceSemanticCatalogJoin {
    /// The joined opaque revision/identity: binds BOTH the base catalog byte SHA-256 and the
    /// semantic sidecar byte SHA-256, composed deterministically (`base=<sha>&semantics=<sha>`).
    /// Consistent with the loader's `k=v&k=v` sourceEvidence revision convention.
    public static func joinedRevision(baseCatalogSHA256: String, sidecarSHA256: String) -> PerformanceCatalogRevision {
        PerformanceCatalogRevision("base=\(baseCatalogSHA256)&semantics=\(sidecarSHA256)")
    }

    /// Deterministic SHA-256 hex of a byte buffer (used for the base binding, the sidecar
    /// identity, and the joined revision). Pure; no clocks/randomness; identical bytes →
    /// identical hash.
    public static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Join base catalog DATA + sidecar DATA. Byte-hash binding is validated BEFORE anything
    /// else produces a snapshot; every annotation/exclusion contract violation fails closed.
    public static func join(
        baseCatalogData: Data,
        sidecarData: Data
    ) -> Result<PerformanceSemanticClosureLoad, PerformanceSemanticClosureError> {
        let baseSHA = sha256Hex(of: baseCatalogData)
        let sidecarSHA = sha256Hex(of: sidecarData)

        // 1. Sidecar decode + artifact contract.
        let sidecar: PerformanceSemanticSidecarDocument
        do {
            sidecar = try JSONDecoder().decode(PerformanceSemanticSidecarDocument.self, from: sidecarData)
        } catch {
            return .failure(.malformedSidecarJSON(String(describing: error)))
        }
        guard sidecar.schemaVersion == PerformanceSemanticSidecar.supportedSchemaVersion else {
            return .failure(.unsupportedSidecarSchema(sidecar.schemaVersion))
        }
        guard sidecar.artifactKind == PerformanceSemanticSidecar.sanctionedArtifactKind else {
            return .failure(.invalidArtifactKind(sidecar.artifactKind))
        }
        guard PerformanceCatalogLoader.isSHA256Identity(sidecar.baseCatalogSHA256) else {
            return .failure(.invalidBaseCatalogBinding(sidecar.baseCatalogSHA256))
        }
        guard sidecar.baseCatalogSHA256 == baseSHA else {
            return .failure(.baseCatalogHashMismatch(expected: sidecar.baseCatalogSHA256, actual: baseSHA))
        }

        // 2. Base catalog external contract (reuse the Slice 2A loader validation).
        let baseDocument: PerformanceCatalogV1Document
        switch PerformanceCatalogLoader.validate(data: baseCatalogData) {
        case .failure(let error): return .failure(.baseCatalogInvalid(error))
        case .success(let document): baseDocument = document
        }

        // 3. Index the base document (deterministic maps/sets).
        var kindByPerformance: [String: PerformanceTrackKind] = [:]
        var unknownGeneratedIDs: Set<String> = []
        var baseVariantCountByPerformance: [String: Int] = [:]
        var baseVariantsByID: [String: PerformanceVariantV1Record] = [:]
        var performanceIDByVariantID: [String: String] = [:]
        for performance in baseDocument.performances {
            guard let kind = PerformanceTrackKind(rawValue: performance.performanceKind) else {
                // Unreachable: the base contract already refused unsupported kinds.
                return .failure(.baseCatalogInvalid(.unsupportedPerformanceKind(performance.performanceKind)))
            }
            kindByPerformance[performance.id] = kind
            baseVariantCountByPerformance[performance.id] = performance.variants.count
            if kind == .unknownGenerated {
                unknownGeneratedIDs.insert(performance.id)
            }
            for variant in performance.variants {
                baseVariantsByID[variant.id] = variant
                performanceIDByVariantID[variant.id] = performance.id
            }
        }
        let supportedVariantIDs = Set(baseVariantsByID.keys.filter { variantID in
            guard let performanceID = performanceIDByVariantID[variantID],
                  let kind = kindByPerformance[performanceID] else { return false }
            return kind != .unknownGenerated
        })

        // 4. Annotations: complete, explicit, noncontradictory, no duplicates/foreign entries.
        var annotationsByVariant: [String: PerformanceSemanticVariantAnnotation] = [:]
        var seenAnnotations: Set<String> = []
        for annotation in sidecar.variantAnnotations {
            if seenAnnotations.contains(annotation.variantID) {
                return .failure(.duplicateAnnotation(variantID: annotation.variantID))
            }
            seenAnnotations.insert(annotation.variantID)

            guard supportedVariantIDs.contains(annotation.variantID) else {
                return .failure(.foreignAnnotation(variantID: annotation.variantID))
            }
            guard PerformanceLighting(rawValue: annotation.lighting) != nil else {
                return .failure(.invalidAnnotationLighting(variantID: annotation.variantID, value: annotation.lighting))
            }
            guard PerformancePresentation(rawValue: annotation.presentation) != nil else {
                return .failure(.invalidAnnotationPresentation(variantID: annotation.variantID, value: annotation.presentation))
            }
            guard PerformanceSemanticSidecar.sanctionedAnnotationSources.contains(annotation.semanticSource) else {
                return .failure(.invalidAnnotationSource(variantID: annotation.variantID, value: annotation.semanticSource))
            }
            if let baseVariant = baseVariantsByID[annotation.variantID] {
                let performanceID = performanceIDByVariantID[annotation.variantID] ?? ""
                if let baseLighting = baseVariant.lighting, baseLighting != annotation.lighting {
                    return .failure(.annotationContradictsBase(
                        performanceID: performanceID,
                        variantID: annotation.variantID,
                        detail: "base lighting \(baseLighting) contradicts annotation \(annotation.lighting)"
                    ))
                }
                if let basePresentation = baseVariant.presentation, basePresentation != annotation.presentation {
                    return .failure(.annotationContradictsBase(
                        performanceID: performanceID,
                        variantID: annotation.variantID,
                        detail: "base presentation \(basePresentation) contradicts annotation \(annotation.presentation)"
                    ))
                }
            }
            annotationsByVariant[annotation.variantID] = annotation
        }

        // Exact annotation coverage: every supported variant must be annotated (fail-closed,
        // first missing in deterministic sorted order).
        for variantID in supportedVariantIDs.sorted() {
            if annotationsByVariant[variantID] == nil {
                return .failure(.missingAnnotation(variantID: variantID))
            }
        }

        // 5. Exclusions: EXACT bijection with the bound catalog's unknownGenerated tracks.
        var exclusionsByPerformance: [String: PerformanceSemanticUnsupportedExclusion] = [:]
        var seenExclusions: Set<String> = []
        for exclusion in sidecar.unsupportedExclusions {
            if seenExclusions.contains(exclusion.performanceID) {
                return .failure(.duplicateUnsupportedExclusion(performanceID: exclusion.performanceID))
            }
            seenExclusions.insert(exclusion.performanceID)

            guard unknownGeneratedIDs.contains(exclusion.performanceID) else {
                return .failure(.foreignUnsupportedExclusion(performanceID: exclusion.performanceID))
            }
            guard exclusion.kind == PerformanceSemanticSidecar.sanctionedUnsupportedKind,
                  exclusion.reason == PerformanceSemanticSidecar.sanctionedUnsupportedReason,
                  exclusion.reasonVersion == PerformanceSemanticSidecar.sanctionedUnsupportedReasonVersion else {
                return .failure(.invalidUnsupportedExclusion(
                    performanceID: exclusion.performanceID,
                    detail: "kind=\(exclusion.kind) reason=\(exclusion.reason) reasonVersion=\(exclusion.reasonVersion)"
                ))
            }
            let actualCount = baseVariantCountByPerformance[exclusion.performanceID] ?? 0
            if exclusion.excludedVariantCount != actualCount {
                return .failure(.exclusionVariantCountMismatch(
                    performanceID: exclusion.performanceID,
                    declared: exclusion.excludedVariantCount,
                    actual: actualCount
                ))
            }
            exclusionsByPerformance[exclusion.performanceID] = exclusion
        }
        for performanceID in unknownGeneratedIDs.sorted() {
            if exclusionsByPerformance[performanceID] == nil {
                return .failure(.missingUnsupportedExclusion(performanceID: performanceID))
            }
        }

        // 6. Deterministic mapping into the Core snapshot. Semantics come ONLY from the
        //    annotations; raw tokens survive verbatim as per-Variant provenance (L inert).
        var tracks: [PerformanceID: PerformanceTrack] = [:]
        for performance in baseDocument.performances {
            guard let kind = kindByPerformance[performance.id], kind != .unknownGenerated else { continue }
            var variants: [PerformanceVariant] = []
            for variant in performance.variants {
                guard let annotation = annotationsByVariant[variant.id],
                      let lighting = PerformanceLighting(rawValue: annotation.lighting),
                      let presentation = PerformancePresentation(rawValue: annotation.presentation) else {
                    // Unreachable: coverage + closed-value validation already ran.
                    return .failure(.missingAnnotation(variantID: variant.id))
                }
                variants.append(PerformanceVariant(
                    id: PerformanceVariantID(variant.id),
                    lighting: lighting,
                    presentation: presentation,
                    provenance: PerformanceCatalogLoader.provenance(from: variant.rawTokens)
                ))
            }
            // Deterministic canonical order (identical to the loader's rule): semantic cell
            // total order, then raw variant ID as the total tiebreaker.
            variants.sort { (a, b) in
                let ca = PerformanceSemanticCell(lighting: a.lighting, presentation: a.presentation)
                let cb = PerformanceSemanticCell(lighting: b.lighting, presentation: b.presentation)
                if ca != cb { return ca < cb }
                return a.id.rawValue < b.id.rawValue
            }
            tracks[PerformanceID(performance.id)] = PerformanceTrack(
                id: PerformanceID(performance.id),
                kind: kind,
                variants: variants
            )
        }

        // 7. Core eligibility GATE (authoritative admission; the join calls Core, never
        //    reimplements it). A Core-ineligible closure is refused wholesale — the fail-closed
        //    guarantee that a "complete" annotation set still forms a valid semantic closure.
        for performanceID in tracks.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let track = tracks[performanceID] else { continue }
            switch PerformanceTrack.catalogEligibility(track) {
            case .ineligible(let issues):
                return .failure(.ineligibleSemanticClosure(performanceID: performanceID.rawValue, issues: issues))
            case .eligible:
                break
            }
        }

        // 8. Joined revision/identity binds both byte hashes.
        return .success(PerformanceSemanticClosureLoad(
            snapshot: PerformanceCatalogSnapshot(
                revision: joinedRevision(baseCatalogSHA256: baseSHA, sidecarSHA256: sidecarSHA),
                tracks: tracks
            ),
            document: baseDocument,
            sidecar: sidecar,
            baseCatalogSHA256: baseSHA,
            sidecarSHA256: sidecarSHA
        ))
    }

    /// Source-URL form: read ONE base catalog JSON file and ONE semantic sidecar JSON file and
    /// join them. Reads ONLY those two JSON files — never a media root, never an MP4, never an
    /// archive scan.
    public static func join(
        baseCatalogURL: URL,
        sidecarURL: URL
    ) -> Result<PerformanceSemanticClosureLoad, PerformanceSemanticClosureError> {
        let baseData: Data
        do {
            baseData = try Data(contentsOf: baseCatalogURL)
        } catch {
            return .failure(.baseCatalogInvalid(.unreadableSource(String(describing: error))))
        }
        let sidecarData: Data
        do {
            sidecarData = try Data(contentsOf: sidecarURL)
        } catch {
            return .failure(.unreadableSidecar(String(describing: error)))
        }
        return join(baseCatalogData: baseData, sidecarData: sidecarData)
    }
}