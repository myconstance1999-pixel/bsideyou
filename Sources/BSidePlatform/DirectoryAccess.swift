import Foundation
import Darwin

/// Versioned, serializable historical identity anchor for one authorized directory.
/// This is deliberately best-effort evidence, not a positive identity guarantee: it records
/// only what a known volume namespace and (where established) persistent inode semantics can
/// support. Opaque Foundation identifiers and birth times are never part of this record.
public struct DirectoryIdentitySnapshot: Codable, Equatable, Sendable {
    /// Where the evidence came from. Legacy adoption is prospective and cannot prove the
    /// directory was never replaced before its first capture.
    public enum Provenance: String, Codable, Sendable {
        case explicitSelection
        case bookmarkHistorical
        case legacyAdopted
    }

    public static let currentVersion = 1

    public let version: Int
    public let volumeUUID: String?
    public let inode: UInt64?
    public let persistentIDsSupported: Bool?
    public let provenance: Provenance
    /// Non-nil only where a migration/legacy adoption produced this record.
    public let capturedAt: Date?

    public init(version: Int = DirectoryIdentitySnapshot.currentVersion,
                volumeUUID: String?, inode: UInt64?, persistentIDsSupported: Bool?,
                provenance: Provenance, capturedAt: Date? = nil) {
        self.version = version
        self.volumeUUID = volumeUUID
        self.inode = inode
        self.persistentIDsSupported = persistentIDsSupported
        self.provenance = provenance
        self.capturedAt = capturedAt
    }

    /// A record written by an unknown future version is preserved but never reinterpreted.
    public var isSupported: Bool { version == Self.currentVersion }

    /// Pure three-way comparison of a historical anchor against fresh metadata.
    /// - Both known UUIDs differ → conflict.
    /// - Same known UUID, both known inodes, both with established persistence, different inode → conflict.
    /// - Complete comparable tuple equal → consistent (not "identity proved").
    /// - Everything else → unknown, retaining partial evidence.
    public func comparison(with fresh: DirectoryIdentitySnapshot) -> DirectoryIdentityComparison {
        // A record from an unknown version is preserved but never reinterpreted.
        guard isSupported, fresh.isSupported else { return .unknown }
        switch (volumeUUID, fresh.volumeUUID) {
        case let (anchor?, current?) where anchor != current:
            return .conflict(.volumeChanged)
        case let (anchor?, current?) where anchor == current:
            guard let anchorInode = inode, let currentInode = fresh.inode,
                  persistentIDsSupported == true, fresh.persistentIDsSupported == true else {
                return .unknown
            }
            return anchorInode == currentInode ? .consistent : .conflict(.inodeChanged)
        default:
            return .unknown
        }
    }

    /// Prospective legacy adoption: requires a usable volume namespace. An inode without a
    /// volume is not a sufficient cross-restart baseline. Returns nil when insufficient.
    public func adoptedForLegacyMigration(at date: Date = Date()) -> DirectoryIdentitySnapshot? {
        guard volumeUUID != nil else { return nil }
        return DirectoryIdentitySnapshot(version: version, volumeUUID: volumeUUID, inode: inode,
                                         persistentIDsSupported: persistentIDsSupported,
                                         provenance: .legacyAdopted, capturedAt: date)
    }
}

public enum DirectoryIdentityConflictReason: String, Codable, Equatable, Sendable {
    case volumeChanged
    case inodeChanged
}

public enum DirectoryIdentityComparison: Equatable, Sendable {
    case consistent
    case conflict(DirectoryIdentityConflictReason)
    case unknown
}

/// Raised by a restore/acquire path before any renewal, enumeration, activation or transfer.
/// The caller keeps the original path, bookmark and anchor and offers explicit reselection.
public enum DirectoryIdentityError: Error, Equatable {
    case conflict(DirectoryIdentityConflictReason)
}

/// One process-local access lifetime. URL, Bool, and the private copied identity are immutable;
/// a strong capture can keep it alive across detached reads without shared mutable state.
/// The final reference releases exactly the start owned by this lease, on the releasing thread.
/// The start result records that obligation, not whether a directory or media file is readable.
public final class DirectoryAccessLease: @unchecked Sendable {
    public let url: URL
    public let didStartAccessing: Bool
    private let identity: FileIdentity?

    private let resourceIdentifier: (any NSObjectProtocol)?

    /// The owned HFS+ remount probe changed Foundation's opaque identifier while
    /// the volume UUID and inode remained stable. Qualify the inode by its volume.
    private struct FileIdentity: Equatable {
        let volumeUUID: String
        let fileID: UInt64
    }

    private static let persistentOptions: URL.BookmarkCreationOptions = [
        .withSecurityScope, .securityScopeAllowOnlyReadAccess,
    ]

    private init(url: URL) throws {
        guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        // Keep the actual selected/resolved URL and its scope; reconstructing it from a path
        // here would discard authorization. In particular, never substitute a parent URL.
        self.url = url
        didStartAccessing = url.startAccessingSecurityScopedResource()
        identity = Self.captureIdentity(at: url)
        let values = try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.fileResourceIdentifierKey])
        resourceIdentifier = values?.fileResourceIdentifier?.copy(with: nil) as? NSObjectProtocol
    }

    /// A resolved/bookmarked URL may carry cached metadata for a previous inode. Read a fresh
    /// URL only for this snapshot; the stored URL above keeps actual authorization. Missing or
    /// unreadable metadata leaves the identity unknown rather than claiming continuity.
    private static func captureIdentity(at url: URL) -> FileIdentity? {
        let freshURL = URL(fileURLWithPath: url.path)
        guard let volumeUUID = (try? freshURL.resourceValues(forKeys: [.volumeUUIDStringKey]))?
            .volumeUUIDString, !volumeUUID.isEmpty else { return nil }
        var status = stat()
        guard stat(freshURL.path, &status) == 0 else { return nil }
        return FileIdentity(volumeUUID: volumeUUID, fileID: status.st_ino)
    }

    deinit {
        if didStartAccessing { url.stopAccessingSecurityScopedResource() }
    }

    /// Compare captured file-system identities within the current system run. Missing metadata
    /// is unknown, including when both leases lack an identity: absence is never continuity.
    /// These values are never persisted, and equality does not replace current directory/media
    /// reads or grant access to another URL.
    public func representsSameDirectory(as other: DirectoryAccessLease) -> Bool? {
        if let identity, let otherIdentity = other.identity {
            return identity == otherIdentity
        }
        // Preserve the existing comparison on file systems without a qualified identity.
        guard let resourceIdentifier, let otherIdentifier = other.resourceIdentifier else { return nil }
        return resourceIdentifier.isEqual(otherIdentifier)
    }

    /// Fresh, serializable metadata for this leased URL. Reads the filesystem again rather
    /// than trusting values cached by the resolved/bookmarked URL. The opaque Foundation
    /// identifier stays process-local and is never included.
    public func identitySnapshot(provenance: DirectoryIdentitySnapshot.Provenance)
        -> DirectoryIdentitySnapshot? {
        let freshURL = URL(fileURLWithPath: url.path)
        let values = try? freshURL.resourceValues(
            forKeys: [.volumeUUIDStringKey, .volumeSupportsPersistentIDsKey])
        let volume = values?.volumeUUIDString.flatMap { $0.isEmpty ? nil : $0 }
        var status = stat()
        let inode: UInt64? = stat(freshURL.path, &status) == 0 ? status.st_ino : nil
        guard volume != nil || inode != nil else { return nil }
        return DirectoryIdentitySnapshot(volumeUUID: volume, inode: inode,
                                         persistentIDsSupported: values?.volumeSupportsPersistentIDs,
                                         provenance: provenance)
    }

    /// Inspect the ORIGINAL bookmark bytes for historical identity without resolving or
    /// renewing it. A default-created bookmark may legitimately carry only the volume UUID;
    /// absence of the inode is unknown evidence, never an invented match. Never parse bytes.
    public static func historicalIdentity(fromBookmarkData data: Data) -> DirectoryIdentitySnapshot? {
        var keys: Set<URLResourceKey> = [.volumeUUIDStringKey, .volumeSupportsPersistentIDsKey]
        if #available(macOS 13.3, *) { keys.insert(.fileIdentifierKey) }
        let values = URL.resourceValues(forKeys: keys, fromBookmarkData: data)
        guard let values else { return nil }
        let volume = values.volumeUUIDString.flatMap { $0.isEmpty ? nil : $0 }
        var inode: UInt64?
        if #available(macOS 13.3, *), let identifier = values.fileIdentifier, identifier >= 0 {
            inode = UInt64(identifier)
        }
        guard volume != nil || inode != nil else { return nil }
        return DirectoryIdentitySnapshot(volumeUUID: volume, inode: inode,
                                         persistentIDsSupported: values.volumeSupportsPersistentIDs,
                                         provenance: .bookmarkHistorical)
    }

    /// Create read-only persistent authorization while the selected URL is still accessible.
    /// The caller validates its directory and commits the data through ordinary preferences.
    public static func fromSelectedURL(_ url: URL) throws
        -> (lease: DirectoryAccessLease, persistentData: Data) {
        let lease = try DirectoryAccessLease(url: url)
        let data = try url.bookmarkData(options: persistentOptions,
                                        includingResourceValuesForKeys: nil, relativeTo: nil)
        return (lease, data)
    }

    /// Restore this app's persistent authorization. Invalid data never falls back to a path.
    /// Renewal failure also throws, leaving the caller's previously saved preferences intact.
    public static func resolvePersistent(_ data: Data) throws
        -> (lease: DirectoryAccessLease, renewedData: Data?) {
        var stale = false
        let url = try URL(resolvingBookmarkData: data,
                          options: [.withSecurityScope, .withoutUI, .withoutMounting],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        let lease = try DirectoryAccessLease(url: url)
        let renewed = stale ? try url.bookmarkData(options: persistentOptions,
            includingResourceValuesForKeys: nil, relativeTo: nil) : nil
        return (lease, renewed)
    }

    /// The receiver needs a fresh ephemeral grant, not this app's persistent app-scoped data.
    /// Default creation options retain implicit security scope. Do not persist this transfer.
    public func makeTransferBookmark() throws -> Data {
        try withExtendedLifetime(self) {
            try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        }
    }

    public static func resolveTransfer(_ data: Data) throws -> DirectoryAccessLease {
        var stale = false
        let url = try URL(resolvingBookmarkData: data,
                          options: [.withoutImplicitStartAccessing, .withoutUI, .withoutMounting],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        return try DirectoryAccessLease(url: url)
    }

    /// Only for an existing unsandboxed path preference. This attempts the same persistent
    /// security-scoped creation; success is not a sandbox acceptance result. Failure requires
    /// reselection, not an ordinary-bookmark or old-path fallback.
    public static func migrateLegacyPath(_ path: String) throws
        -> (lease: DirectoryAccessLease, persistentData: Data) {
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { throw CocoaError(.fileReadInvalidFileName) }
        return try fromSelectedURL(URL(fileURLWithPath: expanded, isDirectory: true))
    }
}
