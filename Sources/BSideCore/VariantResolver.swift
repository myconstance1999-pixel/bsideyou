// BSideCore — VariantResolver: Catalog semantics → exact PerformanceVariantID (ADR-013).
// Pure, deterministic, fail-closed. Never inspects clocks, raw TOD tokens, filesystem/media
// roots, runtime availability, or displays; never performs fallback/fuzzy/cross-track or
// cross-lighting selection.

/// Why this Variant was chosen.
public enum PerformanceResolutionReason: String, Codable, Hashable {
    /// Normal v1 policy (automatic presentation: both kinds default to sidePerformance).
    case automaticPolicy
    /// The caller supplied an explicit semantic presentation preference.
    case explicitUserPreference
}

/// The exact result of a successful resolution. Only these six fields: PerformanceID,
/// PerformanceVariantID, resolved lighting, resolved presentation, opaque catalog revision,
/// resolution reason. No fallbackTrace, no display identity.
public struct ResolvedPerformanceVariant: Hashable, Codable {
    public let performanceID: PerformanceID
    public let variantID: PerformanceVariantID
    public let lighting: PerformanceLighting
    public let presentation: PerformancePresentation
    public let catalogRevision: PerformanceCatalogRevision
    public let reason: PerformanceResolutionReason

    public init(
        performanceID: PerformanceID,
        variantID: PerformanceVariantID,
        lighting: PerformanceLighting,
        presentation: PerformancePresentation,
        catalogRevision: PerformanceCatalogRevision,
        reason: PerformanceResolutionReason
    ) {
        self.performanceID = performanceID
        self.variantID = variantID
        self.lighting = lighting
        self.presentation = presentation
        self.catalogRevision = catalogRevision
        self.reason = reason
    }
}

/// Typed resolution failure. Fail-closed: an explicit typed reason, never a silent
/// fallback or a compensated Variant.
public enum VariantResolverFailure: Error, Equatable {
    /// The requested presentation is semantically unsupported for this kind
    /// (e.g. pianoSolo + explicit portrait).
    case unsupportedPresentation(PerformancePresentation, kind: PerformanceTrackKind)
    /// The catalog semantics cannot satisfy the request. Carries the FULL deterministically
    /// ordered issue list (full-track admission runs first) so callers see every distinct
    /// structural reason — never a single arbitrary one.
    case catalogInconsistent([PerformanceCatalogIssue])
}

/// Outcome of Variant resolution.
public enum VariantResolution: Equatable {
    case resolved(ResolvedPerformanceVariant)
    case failed(VariantResolverFailure)
}

/// Pure semantic resolver (repository style: either a direct track or a snapshot lookup).
public enum VariantResolver {
    /// Resolve against a concrete track. `effectiveLighting` is ALREADY produced by BSideMac
    /// policy (never derived here from clocks or TOD tokens); `catalogRevision` is the opaque
    /// revision of the catalog the caller is resolving against.
    public static func resolve(
        track: PerformanceTrack,
        effectiveLighting: PerformanceLighting,
        presentationPreference: PerformancePresentationPreference,
        catalogRevision: PerformanceCatalogRevision
    ) -> VariantResolution {
        // 1. Revision gate — the opaque revision must be usable (non-blank) to resolve
        //    against; an empty/whitespace-only revision is a structured catalog inconsistency.
        if PerformanceStringUsability.isBlank(catalogRevision.rawValue) {
            return .failed(.catalogInconsistent([.unusableRevision]))
        }

        // 2. FULL-TRACK admission BEFORE any presentation/cell selection (fail-closed).
        //    A request for an existing cell still fails when another expected cell is missing
        //    or an unsupported extra structural cell exists: the Track as a whole must be
        //    admissible. The failure carries the complete, deterministically ordered issue
        //    list (missing/duplicate/extra cells, blank identity/reference, reused VariantID…).
        switch PerformanceTrack.catalogEligibility(track) {
        case .ineligible(let issues):
            return .failed(.catalogInconsistent(issues))
        case .eligible:
            break
        }

        // 3. Presentation: automatic v1 policy or explicit semantic preference.
        let presentation: PerformancePresentation
        let reason: PerformanceResolutionReason
        switch presentationPreference {
        case .automatic:
            presentation = track.kind.automaticPresentation
            reason = .automaticPolicy
        case .explicit(let preferred):
            guard track.kind.supportedPresentations.contains(preferred) else {
                return .failed(.unsupportedPresentation(preferred, kind: track.kind))
            }
            presentation = preferred
            reason = .explicitUserPreference
        }

        // 4. Exact semantic cell match. After full admission this is unique; the guards stay
        //    fail-closed (no fallback, no arbitrary/minimum-ID/fuzzy/cross-track selection).
        let wanted = PerformanceSemanticCell(lighting: effectiveLighting, presentation: presentation)
        let matches = track.variants.filter { $0.lighting == wanted.lighting && $0.presentation == wanted.presentation }
        if matches.count > 1 {
            return .failed(.catalogInconsistent([.duplicateSemanticCell(wanted)]))
        }
        guard let variant = matches.first else {
            return .failed(.catalogInconsistent([.missingExpectedCell(wanted)]))
        }

        return .resolved(ResolvedPerformanceVariant(
            performanceID: track.id,
            variantID: variant.id,
            lighting: effectiveLighting,
            presentation: presentation,
            catalogRevision: catalogRevision,
            reason: reason
        ))
    }

    /// Resolve from a semantic catalog snapshot by PerformanceID. The snapshot's opaque
    /// revision is carried into the result; a missing track is a typed catalog inconsistency.
    public static func resolve(
        trackID: PerformanceID,
        in catalog: PerformanceCatalogSnapshot,
        effectiveLighting: PerformanceLighting,
        presentationPreference: PerformancePresentationPreference
    ) -> VariantResolution {
        guard let track = catalog.track(for: trackID) else {
            return .failed(.catalogInconsistent([.trackNotFound(trackID)]))
        }
        return resolve(
            track: track,
            effectiveLighting: effectiveLighting,
            presentationPreference: presentationPreference,
            catalogRevision: catalog.revision
        )
    }
}