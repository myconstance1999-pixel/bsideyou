// BSideCore — explicit playback target (ADR-022): an official resolved catalog cell OR one
// explicitly selected local file. Pure domain only: opaque identities and an opaque local
// catalog revision — never a filesystem path, never a fabricated lighting/presentation cell.
//
// The local case deliberately carries NO PerformanceLighting / PerformancePresentation /
// PerformanceTrackKind. A local folder is a source group, not proof of a song's semantics, so
// Core must not invent camera or lighting labels for it.

/// Opaque reference to exactly one selected file of one local track. `trackID`/`fileID` are
/// ControlApp-allocated opaque identities (never a path, number or title), and
/// `catalogRevision` is the opaque revision of the local catalog the caller resolved against.
public struct LocalPerformanceReference: Hashable, Codable {
    public let trackID: String
    public let fileID: String
    public let catalogRevision: PerformanceCatalogRevision

    public init(trackID: String, fileID: String, catalogRevision: PerformanceCatalogRevision) {
        self.trackID = trackID
        self.fileID = fileID
        self.catalogRevision = catalogRevision
    }

    /// Structurally usable identities only. A blank track/file/revision never resolves and is
    /// never replaced by another local or official file.
    public var isUsable: Bool {
        !PerformanceStringUsability.isBlank(trackID)
            && !PerformanceStringUsability.isBlank(fileID)
            && !PerformanceStringUsability.isBlank(catalogRevision.rawValue)
    }
}

/// The explicit semantic target of one session/queue start. New sessions ALWAYS carry this
/// unambiguous typed form; the legacy official-only queue JSON still decodes (see
/// `PerformanceQueueEntry`).
public enum PerformancePlaybackTarget: Hashable, Codable {
    /// An official catalog cell resolved by `VariantResolver` (lighting × presentation).
    case catalog(ResolvedPerformanceVariant)
    /// One explicitly selected local file, identified by opaque ids + local catalog revision.
    case localFile(LocalPerformanceReference)

    public var officialVariant: ResolvedPerformanceVariant? {
        if case .catalog(let variant) = self { return variant }
        return nil
    }

    public var localReference: LocalPerformanceReference? {
        if case .localFile(let reference) = self { return reference }
        return nil
    }

    public var isLocalFile: Bool {
        if case .localFile = self { return true }
        return false
    }

    /// Official targets are admissible only when their resolved identity is structurally usable.
    public var isUsable: Bool {
        switch self {
        case .catalog(let variant):
            return !PerformanceStringUsability.isBlank(variant.performanceID.rawValue)
                && !PerformanceStringUsability.isBlank(variant.variantID.rawValue)
                && !PerformanceStringUsability.isBlank(variant.catalogRevision.rawValue)
        case .localFile(let reference):
            return reference.isUsable
        }
    }
}

/// Typed reason a `PerformanceStartRequest` may not be admitted. Shared by the ControlApp request
/// pipeline and the Agent so the two can never disagree about target/binding coherence.
public enum PerformanceStartAdmissionIssue: Error, Equatable, CustomStringConvertible {
    case emptySession
    case unusableTarget
    case emptyMediaRoot
    /// A local-file target without the mandatory per-file binding.
    case localRequiresBinding
    /// A local-file target without a transferred directory grant. A local request must never
    /// fall back to a saved path: without the grant the file cannot be admitted or read.
    case localRequiresGrant
    /// An official target carrying an extraneous local-file binding.
    case officialRejectsBinding

    public var description: String {
        switch self {
        case .emptySession: return "演奏会话身份缺失"
        case .unusableTarget: return "演奏目标身份无效"
        case .emptyMediaRoot: return "演奏素材目录缺失"
        case .localRequiresBinding: return "歌曲缺少有效的文件绑定"
        case .localRequiresGrant: return "歌曲缺少目录访问授权"
        case .officialRejectsBinding: return "官方演奏不接受本地文件绑定"
        }
    }
}

extension PerformanceStartRequest {
    /// Nil when the request is coherent. A local target REQUIRES a file binding; an official
    /// target must REJECT an extraneous one. Pure: no IO, no filesystem, no path interpretation.
    public var admissionIssue: PerformanceStartAdmissionIssue? {
        if session.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .emptySession }
        guard session.target.isUsable else { return .unusableTarget }
        if mediaRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .emptyMediaRoot }
        switch session.target {
        case .localFile:
            if fileBinding == nil { return .localRequiresBinding }
            if accessBookmark?.isEmpty != false { return .localRequiresGrant }
        case .catalog:
            if fileBinding != nil { return .officialRejectsBinding }
        }
        return nil
    }
}
