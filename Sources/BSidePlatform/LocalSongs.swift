// BSidePlatform — ordinary-library local songs (ADR-022). Metadata only: a directory listing is
// a source GROUP, never proof of a song title or of any official lighting/camera semantics.
//
// Ownership: ControlApp is the sole persistent owner of this catalog; the Agent only receives an
// explicit per-file binding at start time and verifies it under its own transferred lease. This
// file holds the pure value model, the bounded directory scanner, the atomic versioned store and
// the single-selected-file verifier so both processes and the test runner share one definition.
import Foundation
import CryptoKit
import Darwin
import BSideCore

// MARK: - Errors

public enum LocalSongError: Error, Equatable, CustomStringConvertible {
    /// An on-disk store this build cannot interpret. The original bytes must be preserved.
    case unsupportedStoreVersion(Int)
    /// The store exists but is not decodable. The original bytes must be preserved.
    case corruptStore(String)
    case storeUnreadable(String)
    case storeWriteFailed(String)
    case rootUnavailable(String)
    case outsideRoot(String)
    case emptyTitle
    case unknownTrack(String)
    case unknownFile(String)
    case duplicateFile(String)
    case fileChanged(String)
    case unreadable(String)
    case tooManyEntries(Int)
    case invalidBinding(String)

    public var description: String {
        switch self {
        case .unsupportedStoreVersion(let version):
            return "本地歌曲记录版本不受支持（\(version)）；已保留原文件，未覆盖。"
        case .corruptStore(let detail):
            return "本地歌曲记录无法读取（\(detail)）；已保留原文件，未覆盖。"
        case .storeUnreadable(let detail):
            return "无法读取本地歌曲记录：\(detail)"
        case .storeWriteFailed(let detail):
            return "无法保存本地歌曲记录：\(detail)"
        case .rootUnavailable(let path):
            return "本地歌曲目录当前不可用：\(path)"
        case .outsideRoot(let path):
            return "所选文件位于授权目录之外：\(path)"
        case .emptyTitle:
            return "曲目名称不能为空。"
        case .unknownTrack(let id):
            return "本地曲目不存在：\(id)"
        case .unknownFile(let id):
            return "本地文件不存在：\(id)"
        case .duplicateFile(let id):
            return "重复的本地文件记录：\(id)"
        case .fileChanged(let path):
            return "所选文件与已保存的身份不符：\(path)"
        case .unreadable(let path):
            return "无法读取所选文件：\(path)"
        case .tooManyEntries(let count):
            return "目录中的文件过多（\(count)），已停止扫描。"
        case .invalidBinding(let detail):
            return "本地文件绑定无效：\(detail)"
        }
    }
}

// MARK: - Numbering and stable neutral versions

/// Temporary-title numbering. Monotonic and global: allocated once, never reused, never
/// recomputed from the current track list.
public enum LocalSongNumbering {
    public static let titlePrefix = "未命名曲目"

    public static func title(_ number: Int) -> String {
        titlePrefix + String(format: "%03d", max(1, number))
    }
}

// MARK: - Scanned metadata

/// One supported regular media file discovered by the bounded scanner. Metadata only — the file
/// payload is never read, hashed or decoded during a scan.
public struct LocalSongScannedFile: Equatable, Sendable {
    public let relativePath: String
    public let basename: String
    public let byteSize: Int64

    public init(relativePath: String, basename: String, byteSize: Int64) {
        self.relativePath = relativePath
        self.basename = basename
        self.byteSize = byteSize
    }
}

/// One directory containing supported files, represented as exactly one track.
public struct LocalSongScannedGroup: Equatable, Sendable {
    /// Path relative to the authorized root; "" means the selected root itself.
    public let relativePath: String
    public let files: [LocalSongScannedFile]

    public init(relativePath: String, files: [LocalSongScannedFile]) {
        self.relativePath = relativePath
        self.files = files
    }
}

// MARK: - Catalog value model

public struct LocalSongRoot: Codable, Equatable, Sendable {
    public var id: String
    public var displayPath: String
    /// Persistent app-scoped bookmark. Never transferred verbatim to the Agent.
    public var bookmark: Data?
    /// Best-effort historical anchor, kept separate from the renewable bookmark.
    public var identity: StoredDirectoryIdentity?
    /// True when the most recent scan could not reach this root. The record is retained.
    public var isMissing: Bool

    public init(id: String, displayPath: String, bookmark: Data? = nil,
                identity: StoredDirectoryIdentity? = nil, isMissing: Bool = false) {
        self.id = id
        self.displayPath = displayPath
        self.bookmark = bookmark
        self.identity = identity
        self.isMissing = isMissing
    }
}

public struct LocalSongFile: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var relativePath: String
    public var basename: String
    /// Last observed metadata size. Nil only for a record created before a successful scan.
    public var byteSize: Int64?
    /// Fingerprint established on FIRST selected-file playback. Never silently rebaselined.
    public var sha256: String?
    /// Size observed when `sha256` was established, so a later size change is detectable without
    /// re-hashing every sibling.
    public var fingerprintByteSize: Int64?
    /// Missing files remain records; they are never removed or replaced by a sibling.
    public var isPresent: Bool

    public init(id: String, relativePath: String, basename: String, byteSize: Int64? = nil,
                sha256: String? = nil, fingerprintByteSize: Int64? = nil, isPresent: Bool = true) {
        self.id = id
        self.relativePath = relativePath
        self.basename = basename
        self.byteSize = byteSize
        self.sha256 = sha256
        self.fingerprintByteSize = fingerprintByteSize
        self.isPresent = isPresent
    }
}

/// Audible performance and mood only; these values never identify an original work or composer.
public enum LocalSongCategory: String, Codable, CaseIterable, Sendable {
    case piano, vocal, instrumental, unclassified
}

public enum LocalSongStyle: String, Codable, CaseIterable, Sendable {
    case gentle, lyrical, bright, energetic, melancholic, atmospheric, majestic, unclassified
}

public enum LocalSongClassificationOrigin: String, Codable, Sendable {
    case automatic, manual
}

public struct LocalSongClassification: Codable, Equatable, Sendable {
    public var category: LocalSongCategory
    public var style: LocalSongStyle
    public var origin: LocalSongClassificationOrigin
    public var analyzedFileID: String?
    public var modelID: String?
    public var modelRevision: String?

    public init(category: LocalSongCategory, style: LocalSongStyle,
                origin: LocalSongClassificationOrigin, analyzedFileID: String? = nil,
                modelID: String? = nil, modelRevision: String? = nil) {
        self.category = category
        self.style = style
        self.origin = origin
        self.analyzedFileID = analyzedFileID
        self.modelID = modelID
        self.modelRevision = modelRevision
    }
}

public struct LocalSongTrack: Codable, Equatable, Sendable, Identifiable {
    /// Opaque persisted identity. Independent of the title and of the allocated number.
    public var id: String
    /// Monotonic global temporary number; never renumbered by scans/renames/removals.
    public var number: Int
    /// User rename. Nil keeps the stable temporary title.
    public var customTitle: String?
    public var rootID: String
    /// Group path relative to the root; "" for a root-level group.
    public var groupRelativePath: String
    public var files: [LocalSongFile]
    /// Remembered explicit file choice. Preserved across rescans, even while its file is missing.
    public var selectedFileID: String?
    /// True while at least one file of this group is present.
    public var isAvailable: Bool
    /// Optional analysis or manual classification, independent of title and playback selection.
    public var classification: LocalSongClassification?

    public init(id: String, number: Int, customTitle: String? = nil, rootID: String,
                groupRelativePath: String, files: [LocalSongFile] = [],
                selectedFileID: String? = nil, isAvailable: Bool = true,
                classification: LocalSongClassification? = nil) {
        self.id = id
        self.number = number
        self.customTitle = customTitle
        self.rootID = rootID
        self.groupRelativePath = groupRelativePath
        self.files = files
        self.selectedFileID = selectedFileID
        self.isAvailable = isAvailable
        self.classification = classification
    }

    public var displayTitle: String { customTitle ?? LocalSongNumbering.title(number) }

    /// Stable neutral order: basename first, relative path as a deterministic tie-break.
    /// Display versions are positional ("版本1/2/3") over exactly this order.
    public var sortedFiles: [LocalSongFile] {
        files.sorted {
            let byName = $0.basename.localizedStandardCompare($1.basename)
            if byName != .orderedSame { return byName == .orderedAscending }
            return $0.relativePath < $1.relativePath
        }
    }

    public var selectedFile: LocalSongFile? {
        guard let selectedFileID else { return nil }
        return files.first { $0.id == selectedFileID }
    }

    /// Position (1-based) of a file in the neutral version order, or nil when unknown.
    public func versionNumber(ofFile fileID: String) -> Int? {
        sortedFiles.firstIndex { $0.id == fileID }.map { $0 + 1 }
    }
}

public struct LocalSongScanSummary: Equatable, Sendable {
    public var newTracks: Int = 0
    public var newFiles: Int = 0
    public var missingTracks: Int = 0
    public var missingFiles: Int = 0
    public var presentFiles: Int = 0
    public init() {}
}

/// Versioned, ControlApp-owned local song catalog. Pure value type: no IO here.
public struct LocalSongCatalog: Codable, Equatable, Sendable {
    public static let currentVersion = 2

    public var version: Int
    /// Monotonic opaque revision source. Bumped on every accepted mutation.
    public var revision: Int
    /// Next global temporary number to allocate. Never decremented.
    public var nextNumber: Int
    public var roots: [LocalSongRoot]
    public var tracks: [LocalSongTrack]

    public init(version: Int = LocalSongCatalog.currentVersion, revision: Int = 0,
                nextNumber: Int = 1, roots: [LocalSongRoot] = [], tracks: [LocalSongTrack] = []) {
        self.version = version
        self.revision = revision
        self.nextNumber = nextNumber
        self.roots = roots
        self.tracks = tracks
    }

    public var isSupported: Bool { version == Self.currentVersion }

    /// Structural invariants a loaded store must satisfy. A syntactically valid JSON document
    /// that violates them is treated as corrupt and preserved rather than trusted or rewritten.
    /// Returns nil when the catalog is coherent.
    public var structuralProblem: String? {
        guard version == Self.currentVersion else { return "unsupported version \(version)" }
        guard revision >= 0 else { return "negative revision" }
        var rootIDs = Set<String>()
        for root in roots {
            guard !root.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "blank root id"
            }
            guard rootIDs.insert(root.id).inserted else { return "duplicate root id \(root.id)" }
        }
        var trackIDs = Set<String>()
        var fileIDs = Set<String>()
        var numbers = Set<Int>()
        var groupKeys = Set<String>()
        var maxNumber = 0
        for track in tracks {
            guard !track.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "blank track id"
            }
            guard trackIDs.insert(track.id).inserted else { return "duplicate track id \(track.id)" }
            guard track.number > 0 else { return "non-positive track number \(track.number)" }
            guard numbers.insert(track.number).inserted else { return "duplicate track number \(track.number)" }
            maxNumber = max(maxNumber, track.number)
            guard rootIDs.contains(track.rootID) else {
                return "track \(track.id) references an unknown root"
            }
            guard LocalFileVerifier.isValidRelativePath(track.groupRelativePath, allowEmpty: true) else {
                return "invalid group path for track \(track.id)"
            }
            guard groupKeys.insert("\(track.rootID)\u{1F}\(track.groupRelativePath)").inserted else {
                return "duplicate group \(track.groupRelativePath) under root \(track.rootID)"
            }
            var relativePaths = Set<String>()
            for file in track.files {
                guard !file.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return "blank file id"
                }
                guard fileIDs.insert(file.id).inserted else { return "duplicate file id \(file.id)" }
                guard LocalFileVerifier.isValidRelativePath(file.relativePath, allowEmpty: false) else {
                    return "invalid relative path for file \(file.id)"
                }
                guard relativePaths.insert(file.relativePath).inserted else {
                    return "duplicate file path \(file.relativePath)"
                }
                guard !file.basename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return "blank basename for file \(file.id)"
                }
                if let byteSize = file.byteSize, byteSize < 0 { return "negative size for file \(file.id)" }
                switch (file.sha256, file.fingerprintByteSize) {
                case (nil, nil):
                    break
                case (let digest?, let size?):
                    guard LocalSongFile.isSHA256Identity(digest), size > 0 else {
                        return "invalid fingerprint for file \(file.id)"
                    }
                default:
                    return "incomplete fingerprint pair for file \(file.id)"
                }
            }
            if let selected = track.selectedFileID, !track.files.contains(where: { $0.id == selected }) {
                return "track \(track.id) references an unknown selected file"
            }
        }
        guard nextNumber > maxNumber else { return "nextNumber is not above the maximum number" }
        guard nextNumber >= 1 else { return "non-positive nextNumber" }
        return nil
    }

    /// Opaque local catalog revision carried by `LocalPerformanceReference`.
    public var catalogRevision: PerformanceCatalogRevision {
        PerformanceCatalogRevision("local.\(version).\(revision)")
    }

    public func root(id: String) -> LocalSongRoot? { roots.first { $0.id == id } }
    public func track(id: String) -> LocalSongTrack? { tracks.first { $0.id == id } }

    public func track(rootID: String, groupRelativePath: String) -> LocalSongTrack? {
        tracks.first { $0.rootID == rootID && $0.groupRelativePath == groupRelativePath }
    }

    // MARK: Roots

    @discardableResult
    public mutating func registerRoot(id: String, displayPath: String, bookmark: Data?,
                                      identity: StoredDirectoryIdentity?) -> LocalSongRoot {
        if let index = roots.firstIndex(where: { $0.id == id }) {
            roots[index].displayPath = displayPath
            roots[index].bookmark = bookmark
            roots[index].identity = identity
            roots[index].isMissing = false
            revision += 1
            return roots[index]
        }
        let root = LocalSongRoot(id: id, displayPath: displayPath, bookmark: bookmark,
                                 identity: identity, isMissing: false)
        roots.append(root)
        revision += 1
        return root
    }

    public mutating func markRoot(id: String, missing: Bool) {
        guard let index = roots.firstIndex(where: { $0.id == id }), roots[index].isMissing != missing else { return }
        roots[index].isMissing = missing
        revision += 1
    }

    // MARK: Scan application

    /// Apply one root's bounded scan. Existing records keep their ids, numbers and titles;
    /// absent files/tracks become unavailable records instead of disappearing. The same
    /// (root, relative group) or (track, relative file) can never be inserted twice.
    @discardableResult
    public mutating func applyScan(rootID: String, groups: [LocalSongScannedGroup]) -> LocalSongScanSummary {
        let previousTracks = tracks
        var summary = LocalSongScanSummary()
        var seenGroups = Set<String>()
        var scannedByTrack: [Int: Set<String>] = [:]

        for group in groups {
            guard seenGroups.insert(group.relativePath).inserted else { continue }
            let existingIndex = tracks.firstIndex { $0.rootID == rootID && $0.groupRelativePath == group.relativePath }
            let trackIndex: Int
            if let existingIndex {
                trackIndex = existingIndex
            } else {
                let track = LocalSongTrack(id: "local.track.\(UUID().uuidString)", number: nextNumber,
                                           rootID: rootID, groupRelativePath: group.relativePath)
                nextNumber += 1
                tracks.append(track)
                trackIndex = tracks.count - 1
                summary.newTracks += 1
            }
            var scannedPaths = Set<String>()
            for file in group.files {
                guard scannedPaths.insert(file.relativePath).inserted else { continue }
                if let fileIndex = tracks[trackIndex].files.firstIndex(where: { $0.relativePath == file.relativePath }) {
                    tracks[trackIndex].files[fileIndex].basename = file.basename
                    tracks[trackIndex].files[fileIndex].byteSize = file.byteSize
                    tracks[trackIndex].files[fileIndex].isPresent = true
                } else {
                    tracks[trackIndex].files.append(LocalSongFile(
                        id: "local.file.\(UUID().uuidString)", relativePath: file.relativePath,
                        basename: file.basename, byteSize: file.byteSize, isPresent: true))
                    summary.newFiles += 1
                }
                summary.presentFiles += 1
            }
            scannedByTrack[trackIndex] = scannedPaths
        }

        // Retain every record: files/tracks absent from this scan become unavailable, not deleted.
        for index in tracks.indices where tracks[index].rootID == rootID {
            guard let scannedPaths = scannedByTrack[index] else {
                if tracks[index].isAvailable || tracks[index].files.contains(where: { $0.isPresent }) {
                    summary.missingTracks += 1
                }
                for fileIndex in tracks[index].files.indices where tracks[index].files[fileIndex].isPresent {
                    tracks[index].files[fileIndex].isPresent = false
                    summary.missingFiles += 1
                }
                tracks[index].isAvailable = false
                continue
            }
            for fileIndex in tracks[index].files.indices
            where !scannedPaths.contains(tracks[index].files[fileIndex].relativePath) {
                if tracks[index].files[fileIndex].isPresent {
                    tracks[index].files[fileIndex].isPresent = false
                    summary.missingFiles += 1
                }
            }
            if tracks[index].selectedFileID == nil {
                tracks[index].selectedFileID = tracks[index].sortedFiles.first(where: { $0.isPresent })?.id
            }
            tracks[index].isAvailable = tracks[index].files.contains { $0.isPresent }
        }
        if tracks != previousTracks { revision += 1 }
        return summary
    }

    // MARK: Rename / selection / fingerprint / removal

    /// Trim whitespace, refuse an empty name and never touch the opaque id or number.
    public mutating func rename(trackID: String, to title: String) throws {
        guard let index = tracks.firstIndex(where: { $0.id == trackID }) else {
            throw LocalSongError.unknownTrack(trackID)
        }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LocalSongError.emptyTitle }
        tracks[index].customTitle = trimmed
        revision += 1
    }

    /// Metadata-only edit: preserves the track, files, root and remembered playback selection.
    public mutating func setClassification(trackID: String,
                                          classification: LocalSongClassification?) throws {
        guard let index = tracks.firstIndex(where: { $0.id == trackID }) else {
            throw LocalSongError.unknownTrack(trackID)
        }
        guard tracks[index].classification != classification else { return }
        tracks[index].classification = classification
        revision += 1
    }

    public mutating func selectFile(trackID: String, fileID: String) throws {
        guard let index = tracks.firstIndex(where: { $0.id == trackID }) else {
            throw LocalSongError.unknownTrack(trackID)
        }
        guard tracks[index].files.contains(where: { $0.id == fileID }) else {
            throw LocalSongError.unknownFile(fileID)
        }
        guard tracks[index].selectedFileID != fileID else { return }
        tracks[index].selectedFileID = fileID
        revision += 1
    }

    /// Establish the fingerprint the FIRST time, and only ever confirm it afterwards. A changed
    /// file is a typed failure — never a silent rebaseline.
    public mutating func setFingerprint(trackID: String, fileID: String, sha256: String,
                                        byteSize: Int64) throws {
        guard let trackIndex = tracks.firstIndex(where: { $0.id == trackID }),
              let fileIndex = tracks[trackIndex].files.firstIndex(where: { $0.id == fileID }) else {
            throw LocalSongError.unknownFile(fileID)
        }
        guard LocalSongFile.isSHA256Identity(sha256), byteSize > 0 else {
            throw LocalSongError.invalidBinding("bad fingerprint")
        }
        if let existing = tracks[trackIndex].files[fileIndex].sha256 {
            guard existing == sha256,
                  tracks[trackIndex].files[fileIndex].fingerprintByteSize == byteSize else {
                throw LocalSongError.fileChanged(tracks[trackIndex].files[fileIndex].relativePath)
            }
            return
        }
        tracks[trackIndex].files[fileIndex].sha256 = sha256
        tracks[trackIndex].files[fileIndex].fingerprintByteSize = byteSize
        tracks[trackIndex].files[fileIndex].byteSize = byteSize
        revision += 1
    }

    /// Explicit removal never renumbers anything and never decrements `nextNumber`.
    @discardableResult
    public mutating func removeTrack(id: String) -> Bool {
        guard let index = tracks.firstIndex(where: { $0.id == id }) else { return false }
        tracks.remove(at: index)
        revision += 1
        return true
    }

    /// Every file record that ever existed, for duplicate/identity audits.
    public var fileRelativePaths: Set<String> {
        Set(tracks.flatMap { track in track.files.map { "\(track.rootID)/\($0.relativePath)" } })
    }
}

extension LocalSongFile {
    /// Lowercase 64-hex identity, the same shape the manifest uses.
    public static func isSHA256Identity(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}

// MARK: - Versioned atomic store

/// Minimal decode target used to read the stored version BEFORE the full catalog decode. A
/// document with no readable integer `version` is corrupt, not silently treated as current.
private struct LocalSongVersionProbe: Decodable {
    let version: Int?
}

public enum LocalSongStoreLoad: Equatable {
    case empty
    case loaded(LocalSongCatalog)
    /// Present but written by a version this build does not understand: preserve, never overwrite.
    case unsupported(String)
    /// Present but not decodable: preserve, never overwrite.
    case corrupt(String)
}

public struct LocalSongStore {
    public let url: URL

    public init(url: URL = AppPaths.localSongsURL) { self.url = url }

    /// Metadata-only load. A missing file is `.empty`; an unreadable/undecodable/unknown-version
    /// file is reported typed and its bytes are never touched. The version is probed BEFORE the
    /// full decode so an unknown version is reported unsupported even when the rest of the
    /// document would not decode in this build.
    public func load() -> LocalSongStoreLoad {
        guard FileManager.default.fileExists(atPath: url.path) else { return .empty }
        do {
            let data = try Data(contentsOf: url)
            guard let probe = try? JSONDecoder().decode(LocalSongVersionProbe.self, from: data),
                  let version = probe.version else {
                return .corrupt("无法解析本地歌曲记录")
            }
            guard version == 1 || version == LocalSongCatalog.currentVersion else {
                return .unsupported("本地歌曲记录版本 \(version)")
            }
            guard var decoded = try? JSONDecoder().decode(LocalSongCatalog.self, from: data) else {
                return .corrupt("无法解析本地歌曲记录")
            }
            if version == 1 {
                // A v1 catalog has no classification payload. Refuse an inconsistent document
                // rather than discard data that an older writer could not preserve.
                guard decoded.tracks.allSatisfy({ $0.classification == nil }) else {
                    return .corrupt("旧版本记录包含分类数据")
                }
                decoded.version = LocalSongCatalog.currentVersion
            }
            if let problem = decoded.structuralProblem {
                return .corrupt("结构无效：\(problem)")
            }
            return .loaded(decoded)
        } catch {
            return .corrupt(String(describing: error))
        }
    }

    /// Atomic write (single rename). Callers must never call this for an unsupported/corrupt load.
    public func save(_ catalog: LocalSongCatalog) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(catalog)
        } catch {
            throw LocalSongError.storeWriteFailed(String(describing: error))
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic])
        } catch {
            throw LocalSongError.storeWriteFailed(String(describing: error))
        }
    }
}

// MARK: - Bounded scanner

/// Bounded, metadata-only scanner. It never walks the whole disk: only the explicitly selected
/// authorized root and at most two directory levels below it.
public enum LocalSongScanner {
    /// Supported regular media extensions. Only MP4 is admitted today.
    public static let supportedExtensions: Set<String> = ["mp4"]
    /// Bounded work so a hostile/unexpected tree cannot stall the scan.
    public static let maximumGroups = 8_000
    public static let maximumFiles = 40_000

    /// Scan one authorized root. Recognizes the selected root itself, its immediate child
    /// directories, or its grandchildren (category/work depth 2) — whichever first contains
    /// supported files. Symlinks are never followed out of the root.
    ///
    /// `officialSource` is optional and never widens what is enumerated: it only removes the
    /// exact reviewed files of an ALREADY-AUTHORIZED official source directory. A matching
    /// basename elsewhere proves nothing and is always preserved.
    public static func scan(root: URL, officialSource: LocalSongOfficialSource? = nil) throws
        -> [LocalSongScannedGroup] {
        try Task.checkCancellation()
        let physicalRoot = try physicalURL(root)
        let rootValues = try physicalRoot.resourceValues(forKeys: [.isDirectoryKey])
        guard rootValues.isDirectory == true else { throw LocalSongError.rootUnavailable(root.path) }
        // The official root is already authorized by its own accepted binding; resolve its
        // physical spelling once. If it cannot be resolved right now, no file is excluded and
        // every scanned file is preserved.
        let officialRootPhysical: String? = officialSource.flatMap { source in
            (try? physicalURL(source.root))?.path ?? source.root.standardizedFileURL.path
        }
        func isOfficial(_ physical: URL) -> Bool {
            guard let officialSource, let officialRootPhysical,
                  physical.path.hasPrefix(officialRootPhysical + "/") else { return false }
            let relative = String(physical.path.dropFirst(officialRootPhysical.count + 1))
            return officialSource.matches(relativeLocation: relative)
        }

        // Level 0: the selected root itself.
        let rootFiles = try files(in: physicalRoot, root: physicalRoot, prefix: "", isOfficial: isOfficial)
        if !rootFiles.isEmpty {
            try Task.checkCancellation()
            return [LocalSongScannedGroup(relativePath: "", files: rootFiles)]
        }

        // Level 1: immediate children containing supported files.
        var level1: [LocalSongScannedGroup] = []
        for child in try directories(in: physicalRoot) {
            try Task.checkCancellation()
            let relative = child.lastPathComponent
            let files = try files(in: child, root: physicalRoot, prefix: relative, isOfficial: isOfficial)
            if !files.isEmpty { level1.append(LocalSongScannedGroup(relativePath: relative, files: files)) }
        }
        if !level1.isEmpty { return try bounded(level1) }

        // Level 2: category/work depth.
        var level2: [LocalSongScannedGroup] = []
        for category in try directories(in: physicalRoot) {
            for work in try directories(in: category) {
                try Task.checkCancellation()
                let relative = "\(category.lastPathComponent)/\(work.lastPathComponent)"
                let files = try files(in: work, root: physicalRoot, prefix: relative, isOfficial: isOfficial)
                if !files.isEmpty { level2.append(LocalSongScannedGroup(relativePath: relative, files: files)) }
            }
        }
        return try bounded(level2)
    }

    private static func bounded(_ groups: [LocalSongScannedGroup]) throws -> [LocalSongScannedGroup] {
        guard groups.count <= maximumGroups else { throw LocalSongError.tooManyEntries(groups.count) }
        let total = groups.reduce(0) { $0 + $1.files.count }
        guard total <= maximumFiles else { throw LocalSongError.tooManyEntries(total) }
        return groups
    }

    /// Non-symlink child directories, deterministically ordered.
    private static func directories(in folder: URL) throws -> [URL] {
        try Task.checkCancellation()
        let entries = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles])
        return entries
            .filter { entry in
                let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                return values?.isDirectory == true && values?.isSymbolicLink != true
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Supported regular files directly inside `folder`, with physical containment enforced.
    /// `isOfficial` receives the already-resolved physical file URL so official exclusion can use
    /// the file's exact contained location instead of guessing from its basename.
    private static func files(in folder: URL, root: URL, prefix: String,
                              isOfficial: (URL) -> Bool) throws -> [LocalSongScannedFile] {
        try Task.checkCancellation()
        let entries = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles])
        var results: [LocalSongScannedFile] = []
        for entry in entries {
            try Task.checkCancellation()
            let basename = entry.lastPathComponent
            let ext = entry.pathExtension.lowercased()
            guard supportedExtensions.contains(ext) else { continue }
            let values = try? entry.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
            // A lexical child can still resolve outside the root through a symlinked ancestor.
            let physical = try physicalURL(entry)
            guard physical.path == root.path || physical.path.hasPrefix(root.path + "/") else {
                throw LocalSongError.outsideRoot(basename)
            }
            guard !isOfficial(physical) else { continue }
            let relative = prefix.isEmpty ? basename : "\(prefix)/\(basename)"
            results.append(LocalSongScannedFile(relativePath: relative, basename: basename,
                                                byteSize: Int64(values?.fileSize ?? 0)))
        }
        return results.sorted {
            let byName = $0.basename.localizedStandardCompare($1.basename)
            if byName != .orderedSame { return byName == .orderedAscending }
            return $0.relativePath < $1.relativePath
        }
    }

    static func physicalURL(_ url: URL) throws -> URL {
        try url.withUnsafeFileSystemRepresentation { path in
            guard let path else { throw LocalSongError.unreadable(url.lastPathComponent) }
            guard let resolved = realpath(path, nil) else {
                throw LocalSongError.rootUnavailable(url.path)
            }
            defer { free(resolved) }
            return URL(fileURLWithFileSystemRepresentation: resolved, isDirectory: false, relativeTo: nil)
        }
    }
}

// MARK: - Official source exclusion

/// An ALREADY-AUTHORIZED official source directory plus the exact reviewed variant locations it
/// may contain. A scanned file is excluded ONLY when it is physically contained in this directory
/// AND its location relative to it exactly matches one of those variant paths (or that path under
/// one immediate official child, which is how the official candidate roots are searched).
///
/// A matching basename, size or duration found elsewhere is NEVER evidence of duplication: the
/// owner's instruction is that the same name does not prove the same material. This type performs
/// no IO and never widens the selected grant; the scanner only compares paths it already read.
public struct LocalSongOfficialSource: Equatable, Sendable {
    public let root: URL
    /// Root-relative variant locations exactly as the accepted manifest stores them.
    public let relativePaths: Set<String>

    public init(root: URL, relativePaths: Set<String>) {
        self.root = root
        self.relativePaths = relativePaths
    }

    /// Build from the accepted library for the currently accepted official binding.
    public static func from(_ library: PerformanceLibrary, root: URL) -> LocalSongOfficialSource {
        let paths = library.manifest.tracks.flatMap { $0.variants }.map { $0.relativePath }
        return LocalSongOfficialSource(root: root, relativePaths: Set(paths))
    }

    /// `officialRelative` is the scanned file's path relative to `root`. It matches when it is
    /// exactly a reviewed variant location, or when dropping exactly one leading component (an
    /// immediate official child directory used as a candidate root) yields one.
    public func matches(relativeLocation officialRelative: String) -> Bool {
        if relativePaths.contains(officialRelative) { return true }
        guard let separator = officialRelative.firstIndex(of: "/") else { return false }
        let tail = String(officialRelative[officialRelative.index(after: separator)...])
        return relativePaths.contains(tail)
    }
}

// MARK: - Single selected-file verification (ControlApp pre-flight AND Agent admission)

/// Result of hashing exactly one file.
public struct LocalFileFingerprint: Equatable, Sendable {
    public let byteSize: Int64
    public let sha256: String
    public init(byteSize: Int64, sha256: String) {
        self.byteSize = byteSize
        self.sha256 = sha256
    }
}

/// Verifies ONE explicitly selected file. Never enumerates or hashes siblings.
public enum LocalFileVerifier {
    /// Reject anything that is not a plain relative path inside the root: absolute paths,
    /// "..", NUL, empty components and non-file URLs are all refused before any read.
    public static func validatedRelativePath(_ relativePath: String) throws -> String {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"),
              !relativePath.contains("\0"), !relativePath.hasPrefix("~") else {
            throw LocalSongError.invalidBinding("relative path")
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw LocalSongError.invalidBinding("relative path traversal")
        }
        return relativePath
    }

    /// Non-throwing form used by structural validation. An empty path is legal only for a
    /// track's group path (the selected root itself), never for a file.
    public static func isValidRelativePath(_ path: String, allowEmpty: Bool) -> Bool {
        if path.isEmpty { return allowEmpty }
        return (try? validatedRelativePath(path)) != nil
    }

    /// Resolve the binding's relative path under the leased root and confirm the physical file
    /// is contained in the root's physical directory.
    public static func resolvedURL(relativePath: String, root: URL) throws -> URL {
        let relativePath = try validatedRelativePath(relativePath)
        let physicalRoot = try LocalSongScanner.physicalURL(root)
        let candidate = physicalRoot.appendingPathComponent(relativePath)
        let physical = try LocalSongScanner.physicalURL(candidate)
        guard physical.path.hasPrefix(physicalRoot.path + "/") else {
            throw LocalSongError.outsideRoot(relativePath)
        }
        let values = try physical.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw LocalSongError.unreadable(relativePath)
        }
        return physical
    }

    /// Open-handle identity captured before and after hashing. Never persisted: it only proves the
    /// bytes hashed all belonged to one filesystem object.
    private struct OpenFileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let mtimeSeconds: Int64
        let mtimeNanoseconds: Int64
        let ctimeSeconds: Int64
        let ctimeNanoseconds: Int64
    }

    private static func identity(of handle: FileHandle) throws -> OpenFileIdentity {
        var status = stat()
        guard fstat(handle.fileDescriptor, &status) == 0 else {
            throw LocalSongError.unreadable("open handle")
        }
        return OpenFileIdentity(device: UInt64(status.st_dev), inode: UInt64(status.st_ino),
                                size: Int64(status.st_size),
                                mtimeSeconds: Int64(status.st_mtimespec.tv_sec),
                                mtimeNanoseconds: Int64(status.st_mtimespec.tv_nsec),
                                ctimeSeconds: Int64(status.st_ctimespec.tv_sec),
                                ctimeNanoseconds: Int64(status.st_ctimespec.tv_nsec))
    }

    /// Hash exactly one file with bounded, cancellable chunks. Device/inode/size/mtime/ctime are
    /// read from the OPEN handle before and after hashing, and the path is re-stat'ed before
    /// returning, so a same-size rewrite or replacement during hashing fails instead of becoming
    /// a new baseline.
    public static func fingerprint(url: URL) throws -> LocalFileFingerprint {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let before = try identity(of: handle)
        try handle.seek(toOffset: 0)
        var hasher = SHA256()
        var position: Int64 = 0
        while true {
            try Task.checkCancellation()
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
            position += Int64(data.count)
        }
        guard position == before.size else { throw LocalSongError.fileChanged(url.lastPathComponent) }
        let after = try identity(of: handle)
        guard before == after else { throw LocalSongError.fileChanged(url.lastPathComponent) }
        // The path must still denote the very object whose bytes were hashed.
        var pathStatus = stat()
        guard stat(url.path, &pathStatus) == 0 else {
            throw LocalSongError.unreadable(url.lastPathComponent)
        }
        guard UInt64(pathStatus.st_dev) == before.device,
              UInt64(pathStatus.st_ino) == before.inode,
              Int64(pathStatus.st_size) == before.size else {
            throw LocalSongError.fileChanged(url.lastPathComponent)
        }
        let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return LocalFileFingerprint(byteSize: before.size, sha256: hash)
    }

    /// Full admission check for one binding: path containment, size, then content identity.
    @discardableResult
    public static func resolveAndVerify(binding: PerformanceFileBinding, root: URL) throws -> URL {
        guard binding.byteSize > 0, LocalSongFile.isSHA256Identity(binding.sha256) else {
            throw LocalSongError.invalidBinding("size or digest")
        }
        let url = try resolvedURL(relativePath: binding.relativePath, root: root)
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize, Int64(size) == binding.byteSize else {
            throw LocalSongError.fileChanged(binding.relativePath)
        }
        let fingerprint = try fingerprint(url: url)
        guard fingerprint.byteSize == binding.byteSize, fingerprint.sha256 == binding.sha256 else {
            throw LocalSongError.fileChanged(binding.relativePath)
        }
        return url
    }
}
