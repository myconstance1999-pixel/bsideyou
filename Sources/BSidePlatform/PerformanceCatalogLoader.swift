// BSidePlatform — PerformanceCatalogLoader: external Performance Catalog v1 JSON → BSideCore
// PerformanceCatalogSnapshot (Slice 2A; ADR-013).
//
// Read-only by contract: never touches media, never resolves a relative reference to a file,
// never consults clocks/randomness, never infers normalized semantics from raw source tokens
// (TOD/NI/WI/L are provenance only; L is semantically inert), and loading cost is bounded by
// the catalog bytes only. Core semantic admission (PerformanceTrack.catalogEligibility /
// VariantResolver) stays authoritative; this loader does not duplicate it.
//
// External v1 contract (the forensic v1 JSON schema defines exactly these fields — there is
// no separate revision field; `revision` is NOT part of the v1 schema):
//   schemaVersion  — the JSON schema version; supported value is exactly 1.
//   sourceEvidence — REQUIRED evidence-catalog form: an object of source-file hash identities
//                    with at least 4 non-blank key/value entries, each value exactly 64
//                    lowercase hex characters (the v1 SHA-256 identity pattern
//                    ^[0-9a-f]{64}$). It satisfies the revision-identity contract AND provides
//                    the opaque PerformanceCatalogRevision for the Core snapshot (composed
//                    deterministically from the sorted keys — the hashes are preserved, never
//                    interpreted).
//   performances[] — performance records (id, performanceKind, variantCount, variants[]).
//
// The DTO decodes only these v1 fields (no full JSON Schema engine; unknown/additional
// properties such as a stray "revision" key are ignored rather than invented into the DTO).
//
// A variant record carries an explicit normalized `lighting` / `presentation` plus the raw
// provenance tokens. Mapping into the Core snapshot requires those explicit semantic fields:
// the loader NEVER derives them from raw tokens. The real v1 evidence catalog carries raw
// tokens only, so a full snapshot mapping of it is refused with a typed
// `.missingNormalizedSemantics` result (no inference, no silent repair); its external format
// itself still validates (see `validate(data:)`).

import Foundation
import BSideCore

/// Raw source tokens of ONE concrete media Variant (v1 evidence form), preserved verbatim as
/// provenance ONLY. TOD/NI/WI/L are never interpreted; L is semantically inert everywhere.
public struct PerformanceV1RawTokens: Codable, Equatable {
    public var sourceTimeCode: String?
    public var sourceViewCode: String?
    public var sourceSuffixCode: String?

    public init(sourceTimeCode: String? = nil, sourceViewCode: String? = nil, sourceSuffixCode: String? = nil) {
        self.sourceTimeCode = sourceTimeCode
        self.sourceViewCode = sourceViewCode
        self.sourceSuffixCode = sourceSuffixCode
    }
}

/// One concrete media Variant as the external v1 document carries it. `lighting` and
/// `presentation` are the explicit normalized semantics (validated, never inferred);
/// `relativePath` is a syntactically validated relative asset reference that stays Platform
/// data for a later resolver — it is never resolved to a file here.
public struct PerformanceVariantV1Record: Codable, Equatable {
    public let id: String
    public let relativePath: String
    public let sourceFilename: String?
    public let lighting: String?
    public let presentation: String?
    public let rawTokens: PerformanceV1RawTokens?

    public init(
        id: String,
        relativePath: String,
        sourceFilename: String? = nil,
        lighting: String? = nil,
        presentation: String? = nil,
        rawTokens: PerformanceV1RawTokens? = nil
    ) {
        self.id = id
        self.relativePath = relativePath
        self.sourceFilename = sourceFilename
        self.lighting = lighting
        self.presentation = presentation
        self.rawTokens = rawTokens
    }
}

/// One performance Track as the external v1 document carries it.
public struct PerformanceV1Record: Codable, Equatable {
    public let id: String
    public let performanceKind: String
    public let variantCount: Int
    public let variants: [PerformanceVariantV1Record]

    public init(id: String, performanceKind: String, variantCount: Int, variants: [PerformanceVariantV1Record]) {
        self.id = id
        self.performanceKind = performanceKind
        self.variantCount = variantCount
        self.variants = variants
    }
}

/// The external Performance Catalog v1 document (Platform DTO) — decodes exactly the fields
/// of the forensic v1 schema: `schemaVersion`, required `sourceEvidence`, `performances`.
/// There is no separate revision field in the v1 schema; the revision identity comes from
/// `sourceEvidence` alone.
public struct PerformanceCatalogV1Document: Codable, Equatable {
    public let schemaVersion: Int
    public let sourceEvidence: [String: String]?
    public let performances: [PerformanceV1Record]

    public init(
        schemaVersion: Int,
        sourceEvidence: [String: String]? = nil,
        performances: [PerformanceV1Record]
    ) {
        self.schemaVersion = schemaVersion
        self.sourceEvidence = sourceEvidence
        self.performances = performances
    }
}

/// Typed external-format / mapping failures. Fail-closed and deterministic: every case maps
/// to an explicit reason; nothing is ever repaired, fuzzily recovered, or inferred.
public enum PerformanceCatalogLoadError: Error, Equatable, CustomStringConvertible {
    /// JSON parse or DTO decode failure (also covers structurally missing required fields).
    case malformedJSON(String)
    /// The document's source could not be read (only the source-URL form).
    case unreadableSource(String)
    /// `schemaVersion` is not the supported value 1.
    case unsupportedSchema(Int)
    /// The v1 revision-identity contract is unsatisfiable: `sourceEvidence` is absent, has
    /// fewer than 4 entries, or contains a blank key/value — the v1 schema requires at
    /// least 4 non-blank entries.
    case missingRevisionIdentity
    /// `sourceEvidence` is present but a value is not exactly 64 lowercase hex characters
    /// (the v1 SHA-256 identity pattern `^[0-9a-f]{64}$`).
    case invalidRevisionIdentity(String)
    /// Two performance records share one Performance ID.
    case duplicatePerformanceID(String)
    /// Two variant records (within one performance or across the catalog) share one Variant ID.
    case duplicateVariantID(String)
    /// `variantCount` does not equal the actual number of variant records (catalog integrity).
    case integrityMismatch(performanceID: String, declared: Int, actual: Int)
    /// A variant ID is not inside its performance's identity namespace (`<perfId>.variant.`).
    case identityMismatch(performanceID: String, variantID: String)
    /// `performanceKind` is outside the sanctioned v1 set.
    case unsupportedPerformanceKind(String)
    /// An explicit normalized lighting is outside the closed set (daylight/sunset/night).
    case invalidNormalizedLighting(String)
    /// An explicit normalized presentation is outside the closed set (side/portrait).
    case invalidNormalizedPresentation(String)
    /// `relativePath` is not a syntactically valid relative .mp4 reference (v1 pattern).
    case invalidRelativeReference(String)
    /// Full snapshot mapping requires explicit normalized semantics per variant; the document
    /// carries none for this variant and the loader never infers them from raw tokens.
    case missingNormalizedSemantics(performanceID: String, variantID: String)

    public var description: String {
        switch self {
        case .malformedJSON(let detail): return "Malformed Performance Catalog v1 JSON: \(detail)"
        case .unreadableSource(let detail): return "Cannot read catalog source: \(detail)"
        case .unsupportedSchema(let v): return "Unsupported catalog schema version \(v) (supported: 1)"
        case .missingRevisionIdentity: return "Missing catalog revision identity (sourceEvidence must carry at least 4 non-blank entries)"
        case .invalidRevisionIdentity(let key): return "Invalid catalog revision identity: sourceEvidence value for \"\(key)\" is not exactly 64 lowercase hex characters"
        case .duplicatePerformanceID(let id): return "Duplicate Performance ID: \(id)"
        case .duplicateVariantID(let id): return "Duplicate Variant ID: \(id)"
        case .integrityMismatch(let pid, let declared, let actual):
            return "Catalog integrity mismatch for \(pid): declared variantCount \(declared), actual \(actual)"
        case .identityMismatch(let pid, let vid):
            return "Catalog identity mismatch: variant \(vid) is not inside the namespace of \(pid)"
        case .unsupportedPerformanceKind(let kind): return "Unsupported performance kind: \(kind)"
        case .invalidNormalizedLighting(let v): return "Invalid normalized lighting: \(v)"
        case .invalidNormalizedPresentation(let v): return "Invalid normalized presentation: \(v)"
        case .invalidRelativeReference(let p): return "Invalid relative asset reference: \(p)"
        case .missingNormalizedSemantics(let pid, let vid):
            return "Variant \(vid) (performance \(pid)) carries no explicit normalized lighting/presentation; refusing to infer it from raw tokens"
        }
    }
}

/// A successful load: the Core semantic snapshot plus the validated Platform DTO (relative
/// references retained for a later resolver, never resolved here).
public struct PerformanceCatalogLoad: Equatable {
    public let snapshot: PerformanceCatalogSnapshot
    public let document: PerformanceCatalogV1Document

    public init(snapshot: PerformanceCatalogSnapshot, document: PerformanceCatalogV1Document) {
        self.snapshot = snapshot
        self.document = document
    }
}

/// Deterministic read-only loader for the Performance Catalog v1 external contract.
public enum PerformanceCatalogLoader {
    /// The only supported JSON schema version.
    public static let supportedSchemaVersion = 1

    /// External-format validation only. Decodes the v1 Platform DTO and validates the whole
    /// external contract (schema, revision identity, duplicates, integrity/identity, closed
    /// normalized enums when present, relative-reference syntax). Does NOT require normalized
    /// semantics and never touches the filesystem or media.
    public static func validate(data: Data) -> Result<PerformanceCatalogV1Document, PerformanceCatalogLoadError> {
        let document: PerformanceCatalogV1Document
        do {
            document = try JSONDecoder().decode(PerformanceCatalogV1Document.self, from: data)
        } catch {
            return .failure(.malformedJSON(String(describing: error)))
        }
        switch validateContract(document) {
        case .failure(let error): return .failure(error)
        case .success: return .success(document)
        }
    }

    /// validate + deterministic mapping into the existing Core `PerformanceCatalogSnapshot`.
    /// Requires explicit normalized `lighting`/`presentation` per variant; a variant without
    /// them is refused with `.missingNormalizedSemantics` — the loader never infers semantics
    /// from raw TOD/NI/WI/L tokens.
    public static func load(data: Data) -> Result<PerformanceCatalogLoad, PerformanceCatalogLoadError> {
        switch validate(data: data) {
        case .failure(let error): return .failure(error)
        case .success(let document): return map(document)
        }
    }

    /// The "or source" form: read one catalog JSON file from an explicitly supplied URL and
    /// load it. Reads ONLY the catalog bytes — never a media root, never an MP4.
    public static func load(sourceURL: URL) -> Result<PerformanceCatalogLoad, PerformanceCatalogLoadError> {
        let data: Data
        do {
            data = try Data(contentsOf: sourceURL)
        } catch {
            return .failure(.unreadableSource(String(describing: error)))
        }
        return load(data: data)
    }

    // MARK: - Validation

    private static func validateContract(_ document: PerformanceCatalogV1Document) -> Result<Void, PerformanceCatalogLoadError> {
        // 1. Supported schema.
        guard document.schemaVersion == supportedSchemaVersion else {
            return .failure(.unsupportedSchema(document.schemaVersion))
        }

        // 2. v1 revision-identity contract: required `sourceEvidence` with at least 4
        //    non-blank key/value entries; each value must be exactly 64 lowercase hex
        //    characters (the v1 SHA-256 identity pattern `^[0-9a-f]{64}$`). Absent/short/
        //    blank → typed missing identity; a present but malformed value → typed invalid
        //    identity. Check order is deterministic (sorted keys).
        guard let sourceEvidence = document.sourceEvidence, sourceEvidence.count >= 4 else {
            return .failure(.missingRevisionIdentity)
        }
        for key in sourceEvidence.keys.sorted() {
            guard let value = sourceEvidence[key], !Self.isBlank(key), !Self.isBlank(value) else {
                return .failure(.missingRevisionIdentity)
            }
            guard Self.isSHA256Identity(value) else {
                return .failure(.invalidRevisionIdentity(key))
            }
        }

        // 3. Duplicate Performance IDs (before any dictionary is built — never silently
        //    collapse duplicates).
        var seenPerformanceIDs: Set<String> = []
        for performance in document.performances {
            if seenPerformanceIDs.contains(performance.id) {
                return .failure(.duplicatePerformanceID(performance.id))
            }
            seenPerformanceIDs.insert(performance.id)
        }

        // 4. Per-performance external contract.
        var seenVariantIDs: Set<String> = []
        for performance in document.performances {
            guard PerformanceTrackKind(rawValue: performance.performanceKind) != nil else {
                return .failure(.unsupportedPerformanceKind(performance.performanceKind))
            }
            guard performance.variantCount == performance.variants.count else {
                return .failure(.integrityMismatch(
                    performanceID: performance.id,
                    declared: performance.variantCount,
                    actual: performance.variants.count
                ))
            }
            for variant in performance.variants {
                if seenVariantIDs.contains(variant.id) {
                    return .failure(.duplicateVariantID(variant.id))
                }
                seenVariantIDs.insert(variant.id)

                guard variant.id.hasPrefix(performance.id + ".variant.") else {
                    return .failure(.identityMismatch(performanceID: performance.id, variantID: variant.id))
                }
                if let lighting = variant.lighting, PerformanceLighting(rawValue: lighting) == nil {
                    return .failure(.invalidNormalizedLighting(lighting))
                }
                if let presentation = variant.presentation, PerformancePresentation(rawValue: presentation) == nil {
                    return .failure(.invalidNormalizedPresentation(presentation))
                }
                guard Self.isValidRelativeReference(variant.relativePath) else {
                    return .failure(.invalidRelativeReference(variant.relativePath))
                }
            }
        }
        return .success(())
    }

    /// v1 relative asset reference syntax, fail-closed and consistent with the accepted v1
    /// builder validation: a non-empty POSIX-relative `.mp4` reference that never starts with
    /// "/" or "\", never contains a backslash path separator, CR/LF, an empty, "." or ".."
    /// path component, or an obvious URL/drive absolute form (`C:/…`, `file://…`, `https://…`).
    /// Nested relative references such as `Solo_Minimal/Solo_Minimal_TOD1200_WI_L.mp4` stay
    /// valid. The reference is validated only — never resolved to a file.
    static func isValidRelativeReference(_ path: String) -> Bool {
        guard !path.isEmpty, path.hasSuffix(".mp4") else { return false }
        // Absolute and separator-escape forms.
        if path.hasPrefix("/") || path.hasPrefix("\\") { return false }
        if path.contains("\\") { return false }
        // Obvious URL / drive absolute forms.
        if path.contains("://") { return false }
        if path.count >= 2 {
            let second = path.index(path.startIndex, offsetBy: 1)
            if path[path.startIndex].isLetter && path[second] == ":" { return false }
        }
        // Structural terminators: CR/LF are rejected like the schema's [^\n].
        if path.contains("\n") || path.contains("\r") { return false }
        // Every "/"-delimited component must be non-empty and never "." or "..".
        for component in path.split(separator: "/", omittingEmptySubsequences: false) {
            if component.isEmpty || component == "." || component == ".." { return false }
        }
        return true
    }

    /// Exactly 64 lowercase hex characters — the v1 SHA-256 identity pattern `^[0-9a-f]{64}$`.
    static func isSHA256Identity(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    static func isBlank(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Mapping

    private static func map(_ document: PerformanceCatalogV1Document) -> Result<PerformanceCatalogLoad, PerformanceCatalogLoadError> {
        var tracks: [PerformanceID: PerformanceTrack] = [:]
        for performance in document.performances {
            guard let kind = PerformanceTrackKind(rawValue: performance.performanceKind) else {
                return .failure(.unsupportedPerformanceKind(performance.performanceKind))
            }
            var variants: [PerformanceVariant] = []
            for variant in performance.variants {
                // Explicit normalized semantics are REQUIRED; raw tokens are never interpreted.
                guard let lighting = variant.lighting.flatMap(PerformanceLighting.init(rawValue:)) else {
                    return .failure(.missingNormalizedSemantics(performanceID: performance.id, variantID: variant.id))
                }
                guard let presentation = variant.presentation.flatMap(PerformancePresentation.init(rawValue:)) else {
                    return .failure(.missingNormalizedSemantics(performanceID: performance.id, variantID: variant.id))
                }
                variants.append(PerformanceVariant(
                    id: PerformanceVariantID(variant.id),
                    lighting: lighting,
                    presentation: presentation,
                    provenance: Self.provenance(from: variant.rawTokens)
                ))
            }
            // Deterministic canonical order so identical logical input produces an IDENTICAL
            // snapshot independent of input record order: first by semantic cell (Core's total
            // cell order), then by raw variant ID as a total tiebreaker. Nothing is dropped,
            // repaired, or inferred — this only fixes the order of already-mapped variants.
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
        return .success(PerformanceCatalogLoad(
            snapshot: PerformanceCatalogSnapshot(revision: Self.opaqueRevision(for: document), tracks: tracks),
            document: document
        ))
    }

    /// Raw TOD/NI/WI/L tokens are preserved verbatim as per-Variant provenance ONLY. Absent
    /// raw tokens (e.g. hash-named files) map to an empty provenance — no value is invented.
    static func provenance(from tokens: PerformanceV1RawTokens?) -> PerformanceSourceProvenance {
        guard let tokens else {
            return PerformanceSourceProvenance(rawTime: "", rawView: "", suffixTokens: [])
        }
        return PerformanceSourceProvenance(
            rawTime: tokens.sourceTimeCode ?? "",
            rawView: tokens.sourceViewCode ?? "",
            suffixTokens: tokens.sourceSuffixCode.map { [$0] } ?? []
        )
    }

    /// Opaque catalog revision/hash identity, composed deterministically from the document's
    /// own validated `sourceEvidence` hashes: sorted keys joined as `k=v&k=v`. Never blank,
    /// never interpreted, no clock/randomness. Validation guarantees a non-empty
    /// `sourceEvidence`, so the composition always yields a usable (non-blank) opaque
    /// revision for the Core snapshot.
    static func opaqueRevision(for document: PerformanceCatalogV1Document) -> PerformanceCatalogRevision {
        let sourceEvidence = document.sourceEvidence ?? [:]
        let parts = sourceEvidence.keys.sorted().map { "\($0)=\(sourceEvidence[$0] ?? "")" }
        return PerformanceCatalogRevision(parts.joined(separator: "&"))
    }
}