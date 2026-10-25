// BSideCore — Performance domain: pure semantic model of the official Performance media set
// (ADR-013). No paths, no IO, no clocks, no screens, no runtime file availability.
// Core resolves catalog semantics only; a future Platform slice binds real files.

/// Opaque identity of a Performance track (e.g. "performance://piano-solo/1").
/// Core never interprets the string and it carries no display/screen identity.
public struct PerformanceID: Hashable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    public var description: String { rawValue }
}

/// Opaque identity of one Performance variant (a concrete lighting × presentation cell).
/// Opaque to Core; never carries display/screen identity.
public struct PerformanceVariantID: Hashable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    public var description: String { rawValue }
}

/// Opaque catalog revision/hash identity, string-backed. The accepted architecture binds a
/// catalog revision/hash: this is NOT a number and Core never interprets its format, so it can
/// carry a content hash. It has no path and no display/position semantics. A revision is only
/// usable when non-blank; an empty/whitespace-only revision is rejected when resolving.
public struct PerformanceCatalogRevision: Hashable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    public var description: String { rawValue }
}

/// The kind of Performance content. `unknownGenerated` is the sanctioned representation
/// for sources the generator produced that BSideMac does not recognize; it is never
/// admissible and never resolved. No speculative extra cases.
public enum PerformanceTrackKind: String, Codable, CaseIterable, Hashable {
    case pianoSolo
    case vocalPerformance
    case unknownGenerated
}

/// Effective lighting, already produced by BSideMac policy. The enum is closed on purpose:
/// daylight/sunset/night only — no invented "invalid" or unknown case; a lighting the
/// catalog does not carry for a track surfaces as a typed missing-cell catalog failure.
public enum PerformanceLighting: String, Codable, CaseIterable, Hashable {
    case daylight
    case sunset
    case night
}

/// Performance presentation (camera/presentation semantic). Display targeting (which
/// physical screen) is NOT part of this domain — that is a future PlaybackPlan/Platform
/// concern.
public enum PerformancePresentation: String, Codable, CaseIterable, Hashable {
    case sidePerformance
    case portraitPerformance
}

/// A semantic catalog cell: one lighting × presentation combination.
public struct PerformanceSemanticCell: Hashable, Codable, Comparable {
    public let lighting: PerformanceLighting
    public let presentation: PerformancePresentation

    public init(lighting: PerformanceLighting, presentation: PerformancePresentation) {
        self.lighting = lighting
        self.presentation = presentation
    }

    /// Deterministic total order (declaration order of lighting, then presentation) so
    /// failure lists and duplicate reporting never depend on variant input order.
    public static func < (lhs: PerformanceSemanticCell, rhs: PerformanceSemanticCell) -> Bool {
        let lr = PerformanceLighting.allCases.firstIndex(of: lhs.lighting) ?? 0
        let rr = PerformanceLighting.allCases.firstIndex(of: rhs.lighting) ?? 0
        if lr != rr { return lr < rr }
        let lp = PerformancePresentation.allCases.firstIndex(of: lhs.presentation) ?? 0
        let rp = PerformancePresentation.allCases.firstIndex(of: rhs.presentation) ?? 0
        return lp < rp
    }
}

/// Presentation preference for resolution: automatic (normal v1 policy) or an explicit
/// semantic preference for one presentation. There is no display/screen preference here.
public enum PerformancePresentationPreference: Hashable, Codable {
    case automatic
    case explicit(PerformancePresentation)
}

/// Normalized source provenance of ONE concrete media Variant. Raw time/view strings and
/// suffix tokens (e.g. TOD/NI/WI/L) describe the concrete Variant — not the logical Track —
/// and are retained verbatim as provenance ONLY. VariantResolver never interprets them and L
/// never affects resolution.
public struct PerformanceSourceProvenance: Hashable, Codable {
    public let rawTime: String
    public let rawView: String
    public let suffixTokens: [String]

    public init(rawTime: String, rawView: String, suffixTokens: [String]) {
        self.rawTime = rawTime
        self.rawView = rawView
        self.suffixTokens = suffixTokens
    }
}

/// One concrete variant: opaque variant ID + semantic lighting × presentation cell + its OWN
/// source provenance (each concrete media Variant carries its own TOD/NI/WI/L provenance).
public struct PerformanceVariant: Hashable, Codable {
    public let id: PerformanceVariantID
    public let lighting: PerformanceLighting
    public let presentation: PerformancePresentation
    public let provenance: PerformanceSourceProvenance

    public init(
        id: PerformanceVariantID,
        lighting: PerformanceLighting,
        presentation: PerformancePresentation,
        provenance: PerformanceSourceProvenance
    ) {
        self.id = id
        self.lighting = lighting
        self.presentation = presentation
        self.provenance = provenance
    }
}

/// A Performance track: kind + the set of variants it carries. Built by a future Platform
/// adapter; Core only validates catalog semantics. Provenance is per-Variant — the raw
/// TOD/NI/WI/L describe each concrete media Variant, not the Track.
public struct PerformanceTrack: Hashable, Codable {
    public let id: PerformanceID
    public let kind: PerformanceTrackKind
    public let variants: [PerformanceVariant]

    public init(id: PerformanceID, kind: PerformanceTrackKind, variants: [PerformanceVariant]) {
        self.id = id
        self.kind = kind
        self.variants = variants
    }

    /// Admitted V1 kinds. Anything outside this set is an unsupported kind.
    private static let admittedKinds: Set<PerformanceTrackKind> = [.pianoSolo, .vocalPerformance]

    /// Static, deterministic V1 catalog admission: eligible ONLY when the semantic cell set
    /// is EXACTLY the documented V1 shape for the kind (see `expectedCells`) and identity/
    /// reference integrity holds (no reused VariantID across cells, no blank identities).
    /// Runtime file availability is never part of admission and no compensation with another
    /// Variant ever happens.
    public static func catalogEligibility(_ track: PerformanceTrack) -> PerformanceTrackEligibility {
        // Kind gate is a TOTAL refusal, typed distinctly (unknownGenerated vs any future
        // unsupported kind). It short-circuits: shape checks would only add noise for a
        // source that is refused on its kind alone.
        if !PerformanceTrack.admittedKinds.contains(track.kind) {
            return .ineligible(track.kind == .unknownGenerated ? [.unknownGeneratedKind] : [.unsupportedKind(track.kind)])
        }

        var issues: [PerformanceCatalogIssue] = []

        // Structural identity/reference usability (blank = unusable; pure Swift, no Foundation).
        if PerformanceStringUsability.isBlank(track.id.rawValue) { issues.append(.unusableIdentity) }
        if track.variants.contains(where: { PerformanceStringUsability.isBlank($0.id.rawValue) }) { issues.append(.unusableReference) }

        // Reference identity consistency: two different semantic cells must never reuse one
        // PerformanceVariantID. The whole track is refused — no collision is ever chosen
        // arbitrarily.
        var cellsByReference: [PerformanceVariantID: Set<PerformanceSemanticCell>] = [:]
        for variant in track.variants {
            cellsByReference[variant.id, default: []]
                .insert(PerformanceSemanticCell(lighting: variant.lighting, presentation: variant.presentation))
        }
        for reference in cellsByReference.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            if let cells = cellsByReference[reference], cells.count > 1 {
                issues.append(.duplicateVariantReference(reference))
            }
        }

        // Exact semantic shape.
        let cells = track.variants.map { PerformanceSemanticCell(lighting: $0.lighting, presentation: $0.presentation) }
        let expected = track.kind.expectedCells
        let expectedSet = Set(expected)
        let cellSet = Set(cells)

        var seen: Set<PerformanceSemanticCell> = []
        var duplicates: Set<PerformanceSemanticCell> = []
        for c in cells {
            if seen.contains(c) { duplicates.insert(c) }
            seen.insert(c)
        }
        for c in duplicates.sorted() { issues.append(.duplicateSemanticCell(c)) }
        for c in expected where !cellSet.contains(c) { issues.append(.missingExpectedCell(c)) }
        for c in cellSet where !expectedSet.contains(c) { issues.append(.unsupportedExtraShape(c)) }

        return issues.isEmpty ? .eligible : .ineligible(issues.sorted { PerformanceCatalogIssue.rank($0) < PerformanceCatalogIssue.rank($1) })
    }
}

/// Outcome of V1 catalog admission. `ineligible` carries every distinct structured issue so
/// callers can surface exactly why a source was refused.
public enum PerformanceTrackEligibility: Equatable {
    case eligible
    case ineligible([PerformanceCatalogIssue])
}

/// Typed semantic/catalog failures shared by admission and resolution. Fail-closed: every
/// case maps to an explicit reason; nothing is ever compensated or fuzzily selected.
public enum PerformanceCatalogIssue: Error, Hashable {
    /// A kind the V1 admission does not support (only reachable when the model grows).
    case unsupportedKind(PerformanceTrackKind)
    /// The sanctioned representation for unrecognized generated sources.
    case unknownGeneratedKind
    /// Track identity is structurally unusable (empty or whitespace-only).
    case unusableIdentity
    /// A variant reference/ID is structurally unusable (empty or whitespace-only).
    case unusableReference
    /// The catalog revision is structurally unusable (empty or whitespace-only). Only the
    /// resolver can produce this: admission never sees the revision.
    case unusableRevision
    /// Two different semantic cells reuse the same PerformanceVariantID — a typed
    /// identity/reference inconsistency; never resolved by picking one collision. (Same-cell
    /// reuse surfaces as `duplicateSemanticCell` instead.)
    case duplicateVariantReference(PerformanceVariantID)
    /// The documented V1 shape requires this cell and it is absent.
    case missingExpectedCell(PerformanceSemanticCell)
    /// The same semantic cell appears more than once — resolution would be ambiguous.
    case duplicateSemanticCell(PerformanceSemanticCell)
    /// The cell exists but is outside the documented V1 shape (extra/structural shape).
    case unsupportedExtraShape(PerformanceSemanticCell)
    /// Snapshot lookup failed: no track with this PerformanceID.
    case trackNotFound(PerformanceID)

    /// Total deterministic ordering so failure lists never depend on variant input order.
    /// Cell rank is in [0, 5] (3 lightings × 2 presentations); category bases are chosen so
    /// no two distinct issues can share a rank.
    static func rank(_ issue: PerformanceCatalogIssue) -> Int {
        switch issue {
        case .unknownGeneratedKind: return 0
        case .unsupportedKind: return 100
        case .unusableIdentity: return 200
        case .unusableRevision: return 250
        case .unusableReference: return 300
        case .duplicateVariantReference: return 400
        case .missingExpectedCell(let c): return 1000 + Self.cellRank(c)
        case .duplicateSemanticCell(let c): return 2000 + Self.cellRank(c)
        case .unsupportedExtraShape(let c): return 3000 + Self.cellRank(c)
        case .trackNotFound: return 4000
        }
    }

    static func cellRank(_ cell: PerformanceSemanticCell) -> Int {
        let l = PerformanceLighting.allCases.firstIndex(of: cell.lighting) ?? 0
        let p = PerformancePresentation.allCases.firstIndex(of: cell.presentation) ?? 0
        return l * PerformancePresentation.allCases.count + p
    }
}

extension PerformanceTrackKind {
    /// Exact V1 cells in documented (deterministic) order:
    ///   pianoSolo:        daylight/sunset/night × sidePerformance
    ///   vocalPerformance: daylight/sunset/night × {sidePerformance, portraitPerformance}
    /// `unknownGenerated` has no expected cells and is never admissible.
    var expectedCells: [PerformanceSemanticCell] {
        switch self {
        case .pianoSolo:
            return PerformanceLighting.allCases.map { PerformanceSemanticCell(lighting: $0, presentation: .sidePerformance) }
        case .vocalPerformance:
            var cells: [PerformanceSemanticCell] = []
            for lighting in PerformanceLighting.allCases {
                cells.append(PerformanceSemanticCell(lighting: lighting, presentation: .sidePerformance))
                cells.append(PerformanceSemanticCell(lighting: lighting, presentation: .portraitPerformance))
            }
            return cells
        case .unknownGenerated:
            return []
        }
    }

    /// Presentations this kind semantically supports; explicit preference outside this set
    /// is `unsupportedPresentation` (e.g. pianoSolo + portrait).
    var supportedPresentations: Set<PerformancePresentation> {
        switch self {
        case .pianoSolo: return [.sidePerformance]
        case .vocalPerformance: return [.sidePerformance, .portraitPerformance]
        case .unknownGenerated: return []
        }
    }

    /// Normal v1 automatic policy: both admitted kinds default to sidePerformance.
    var automaticPresentation: PerformancePresentation {
        switch self {
        case .pianoSolo, .vocalPerformance: return .sidePerformance
        case .unknownGenerated: return .sidePerformance // unreachable: kind gate fires first
        }
    }
}

/// Minimal semantic catalog snapshot / repository view with an opaque revision. No runtime
/// availability, no playableVariantSet, no paths — Core reads catalog semantics only.
public struct PerformanceCatalogSnapshot: Hashable, Codable {
    public let revision: PerformanceCatalogRevision
    public let tracks: [PerformanceID: PerformanceTrack]

    public init(revision: PerformanceCatalogRevision, tracks: [PerformanceID: PerformanceTrack] = [:]) {
        self.revision = revision
        self.tracks = tracks
    }

    public func track(for id: PerformanceID) -> PerformanceTrack? { tracks[id] }
}

/// Pure-Swift blank check (no Foundation import): empty or whitespace-only. Used for
/// identity/reference/revision usability so structurally unusable strings are refused
/// deterministically.
enum PerformanceStringUsability {
    static func isBlank(_ value: String) -> Bool {
        let whitespace: Set<Character> = [" ", "\t", "\n", "\r"]
        return value.allSatisfy { whitespace.contains($0) }
    }
}