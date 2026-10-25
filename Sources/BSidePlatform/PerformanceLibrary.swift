// Portable reviewed metadata + local binding. Import stats candidates; only a selected
// variant is fully SHA-256 verified. Never infer semantics or substitute missing cells.
import Foundation
import CryptoKit
import Darwin
import BSideCore

public struct PerformanceManifest: Codable {
    public struct Variant: Codable {
        public let id: String
        public let relativePath: String
        public let lighting: PerformanceLighting
        public let presentation: PerformancePresentation
        public let byteSize: Int64
        public let sha256: String
        public let mediaByteSize: Int64?
        public let mediaSHA256: String?
    }
    public struct Track: Codable, Identifiable {
        public let id: String
        public let kind: PerformanceTrackKind
        public let title: String
        public let subtitle: String
        public let variants: [Variant]
    }
    public let schemaVersion: Int
    public let sourceRevision: String
    public let exclusions: [PerformanceSemanticUnsupportedExclusion]
    public let tracks: [Track]
}

public enum PerformanceAssetError: Error, CustomStringConvertible {
    case invalidManifest(String), missing(String), ambiguous(String), changed(String), outsideRoot, unreadable(String)
    public var description: String {
        switch self {
        case .invalidManifest(let reason): return "演奏清单无效：\(reason)"
        case .missing(let name): return "缺少所选版本：\(name)"
        case .ambiguous(let name): return "发现多份同名素材，请选择更具体的文件夹：\(name)"
        case .changed(let name): return "素材与已审查版本不符：\(name)"
        case .outsideRoot: return "素材链接指向所选目录之外"
        case .unreadable(let name): return "无法读取素材：\(name)"
        }
    }
}

/// Candidate evidence only: every possible location is retained, including missing files
/// and alternatives that can make a formerly unique selection ambiguous.
public struct PerformanceCandidateSnapshot: Sendable {
    public let root: URL
    public let candidateRoots: [URL]
    public let candidateLocations: [String: [URL]]
    public let unavailable: [String: String]
    fileprivate let catalogRevision: String
    fileprivate let pathOwners: [String: Set<String>]
    fileprivate let containsSymlinks: Bool
}

public struct PerformanceCandidateRefresh: Sendable {
    public let snapshot: PerformanceCandidateSnapshot
    public let checkedVariantIDs: Set<String>
    public let fullScan: Bool
}

/// Process-local reuse of the decoded/validated IMMUTABLE bundled authoring manifest.
///
/// `PerformanceLibrary.bundled()` used to re-read, JSON-decode, structurally validate and
/// SHA-256 the ~290 KB sealed manifest on every official song change (measured 12–24 ms per
/// call, median 14.4 ms, all of it on the song-change critical path). The manifest is sealed
/// application data: its catalog revision is a pure function of its bytes, so the validated
/// value cannot change while the same on-disk file is in place.
///
/// This caches NO media identity and skips NO media check: `verifiedURL` still streams and
/// SHA-256s the whole chosen file (plus its layout/size checks) on every single call. The entry
/// is revalidated against the file's own size + modification date, so a replaced/updated bundle
/// manifest is re-read and re-validated exactly as before.
private final class BundledManifestCache: @unchecked Sendable {
    private struct Identity: Equatable {
        let size: Int
        let modified: Date?
    }
    private struct Entry {
        let identity: Identity
        let library: PerformanceLibrary
    }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    private static func identity(of url: URL) -> Identity? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize else { return nil }
        return Identity(size: size, modified: values.contentModificationDate)
    }

    /// The cached value, only while the exact file it was decoded from is unchanged.
    func cachedLibrary(at url: URL) -> PerformanceLibrary? {
        guard let identity = Self.identity(of: url) else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[url.path], entry.identity == identity else { return nil }
        return entry.library
    }

    func store(_ library: PerformanceLibrary, at url: URL) {
        guard let identity = Self.identity(of: url) else { return }
        lock.lock(); defer { lock.unlock() }
        entries[url.path] = Entry(identity: identity, library: library)
    }
}

public struct PerformanceLibrary {
    public let manifest: PerformanceManifest
    public let snapshot: PerformanceCatalogSnapshot

    private static let bundledManifestCache = BundledManifestCache()

    public static func bundled() throws -> PerformanceLibrary {
        // Packaged apps resolve sealed Contents/Resources first. SwiftPM development runs
        // use Bundle.module; production must never depend on its generated build path.
        let packaged = Bundle.main.resourceURL?.appendingPathComponent("BSideMac_BSidePlatform.bundle")
        let resources: Bundle
        if Bundle.main.bundleURL.pathExtension == "app" {
            guard let bundle = packaged.flatMap({ Bundle(url: $0) }) else {
                throw PerformanceAssetError.invalidManifest("安装包缺少演奏清单")
            }
            resources = bundle
        } else {
            resources = Bundle.module
        }
        guard let url = resources.url(forResource: "performance-manifest.v1", withExtension: "json") else {
            throw PerformanceAssetError.invalidManifest("未随应用提供")
        }
        // Reuse the already validated value only while the exact file it was decoded from is
        // still in place. A missing identity falls through to the ordinary full decode.
        if let cached = bundledManifestCache.cachedLibrary(at: url) { return cached }
        let library = try PerformanceLibrary(data: Data(contentsOf: url))
        bundledManifestCache.store(library, at: url)
        return library
    }

    public init(data: Data) throws {
        let manifest = try JSONDecoder().decode(PerformanceManifest.self, from: data)
        guard manifest.schemaVersion == 1, !manifest.sourceRevision.isEmpty, !manifest.tracks.isEmpty else {
            throw PerformanceAssetError.invalidManifest("版本或身份缺失")
        }
        var tracks: [PerformanceID: PerformanceTrack] = [:]
        var variantIDs = Set<String>()
        var paths = Set<String>()
        for record in manifest.tracks {
            let id = PerformanceID(record.id)
            guard tracks[id] == nil else { throw PerformanceAssetError.invalidManifest("重复曲目") }
            let track = PerformanceTrack(id: id, kind: record.kind, variants: try record.variants.map { v in
                guard variantIDs.insert(v.id).inserted,
                      v.id.hasPrefix(record.id + ".variant."),
                      paths.insert(v.relativePath).inserted,
                      PerformanceCatalogLoader.isValidRelativeReference(v.relativePath),
                      !v.relativePath.contains("\0"), v.byteSize > 0,
                      PerformanceCatalogLoader.isSHA256Identity(v.sha256) else {
                    throw PerformanceAssetError.invalidManifest("无效资源引用")
                }
                if let size = v.mediaByteSize, let hash = v.mediaSHA256 {
                    guard size > 0, PerformanceCatalogLoader.isSHA256Identity(hash) else {
                        throw PerformanceAssetError.invalidManifest("无效媒体主体身份")
                    }
                } else if v.mediaByteSize != nil || v.mediaSHA256 != nil {
                    throw PerformanceAssetError.invalidManifest("媒体主体身份不完整")
                }
                return PerformanceVariant(id: PerformanceVariantID(v.id), lighting: v.lighting,
                    presentation: v.presentation,
                    provenance: PerformanceSourceProvenance(rawTime: "", rawView: "", suffixTokens: []))
            })
            guard PerformanceTrack.catalogEligibility(track) == .eligible else {
                throw PerformanceAssetError.invalidManifest("曲目语义不完整：\(record.id)")
            }
            tracks[id] = track
        }
        self.manifest = manifest
        // Include exported bytes so changing binding metadata also changes runtime identity.
        self.snapshot = PerformanceCatalogSnapshot(
            revision: PerformanceCatalogRevision(manifest.sourceRevision + "&manifest=" + PerformanceSemanticCatalogJoin.sha256Hex(of: data)),
            tracks: tracks)
    }

    public func record(for resolved: ResolvedPerformanceVariant) throws -> PerformanceManifest.Variant {
        guard resolved.catalogRevision == snapshot.revision,
              case .resolved(let exact) = VariantResolver.resolve(trackID: resolved.performanceID, in: snapshot,
                effectiveLighting: resolved.lighting, presentationPreference: .explicit(resolved.presentation)),
              exact.variantID == resolved.variantID,
              let variant = manifest.tracks.first(where: { $0.id == resolved.performanceID.rawValue })?
                .variants.first(where: { $0.id == resolved.variantID.rawValue }) else {
            throw PerformanceAssetError.invalidManifest("所选曲目身份不匹配")
        }
        return variant
    }

    /// Bounded layout discovery: chosen root, its immediate children, and 官方音乐 categories.
    /// No whole-disk recursion, fuzzy filename search, or content decoding.
    public static func candidateRoots(_ root: URL) throws -> [URL] {
        try Task.checkCancellation()
        let root = try physicalURL(root)
        let values = try root.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else { throw PerformanceAssetError.unreadable(root.lastPathComponent) }
        func children(_ folder: URL) throws -> [URL] {
            try Task.checkCancellation()
            let entries = try FileManager.default.contentsOfDirectory(at: folder,
                includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            var directories: [URL] = []
            for entry in entries {
                try Task.checkCancellation()
                if (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    // Foundation directory enumeration and resolvingSymlinksInPath can use
                    // different /var spellings. Keep every lexical child under this one root.
                    directories.append(folder.appendingPathComponent(entry.lastPathComponent, isDirectory: true))
                }
            }
            return directories
        }
        let direct = try children(root)
        var roots = [root] + direct
        if let official = direct.first(where: { $0.lastPathComponent == "官方音乐" }) {
            roots += try children(official)
        }
        try Task.checkCancellation()
        return roots.sorted { $0.path < $1.path }
    }

    private static func candidateLocations(for variant: PerformanceManifest.Variant,
                                           root: URL, roots: [URL]) throws -> [URL] {
        var candidates: [URL] = []
        for candidateRoot in roots {
            try Task.checkCancellation()
            candidates.append(candidateRoot.appendingPathComponent(variant.relativePath))
        }
        // Selecting one known track folder is useful for a partial library.
        let components = variant.relativePath.split(separator: "/")
        if components.count == 2, root.lastPathComponent == String(components[0]) {
            candidates.append(root.appendingPathComponent(String(components[1])))
        }
        return candidates
    }

    public static func candidateURL(for variant: PerformanceManifest.Variant, root: URL, roots: [URL]) throws -> URL {
        try Task.checkCancellation()
        let root = try physicalURL(root)
        let candidates = try candidateLocations(for: variant, root: root, roots: roots)
        var matches: [URL] = []
        for candidate in candidates {
            try Task.checkCancellation()
            guard FileManager.default.fileExists(atPath: candidate.path) else { continue }
            let canonical = try physicalURL(candidate)
            guard canonical.path.hasPrefix(root.path + "/") else { throw PerformanceAssetError.outsideRoot }
            let values = try canonical.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { throw PerformanceAssetError.unreadable(candidate.lastPathComponent) }
            if !matches.contains(canonical) { matches.append(canonical) }
        }
        try Task.checkCancellation()
        guard matches.count <= 1 else { throw PerformanceAssetError.ambiguous(variant.relativePath) }
        guard let url = matches.first else { throw PerformanceAssetError.missing(variant.relativePath) }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        let fullSize = Int64(size ?? -1)
        if fullSize != variant.byteSize {
            guard let expected = variant.mediaByteSize,
                  try mediaBodySize(url) == expected else { throw PerformanceAssetError.changed(variant.relativePath) }
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw PerformanceAssetError.unreadable(variant.relativePath) }
        // Preserve the existing public URL spelling; containment above uses physical paths.
        return url.resolvingSymlinksInPath()
    }

    /// Must run off the UI queue. Streaming verification is bounded to a 1 MiB buffer;
    /// cancellation is checked per chunk, including when a newer session supersedes this one.
    public func verifiedURL(for resolved: ResolvedPerformanceVariant, root: URL) throws -> URL {
        let variant = try record(for: resolved)
        let url = try Self.candidateURL(for: variant, root: root, roots: Self.candidateRoots(root))
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let mediaSize = try Self.mediaBodySize(url)
        var hasher = SHA256()
        var mediaDigest: SHA256.Digest?
        var position: Int64 = 0
        while true {
            try Task.checkCancellation()
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            let mediaCount = Int(min(Int64(data.count), max(0, mediaSize - position)))
            if mediaCount > 0 { hasher.update(data: data.prefix(mediaCount)) }
            if mediaDigest == nil && position + Int64(mediaCount) == mediaSize {
                // Finalize a value copy at the exact body boundary. The ongoing state
                // still absorbs every trailer byte, without hashing the common prefix twice.
                let bodySnapshot = hasher
                mediaDigest = bodySnapshot.finalize()
            }
            if mediaCount < data.count { hasher.update(data: data.dropFirst(mediaCount)) }
            position += Int64(data.count)
        }
        let fullDigest = hasher.finalize()
        let hash = fullDigest.map { String(format: "%02x", $0) }.joined()
        // If EOF precedes the sampled boundary (or the stream is empty), every byte
        // read belonged to both digests. Preserve the existing size/identity checks below.
        let mediaHash = (mediaDigest ?? fullDigest).map { String(format: "%02x", $0) }.joined()
        guard (position == variant.byteSize && hash == variant.sha256)
            || (mediaSize == variant.mediaByteSize && mediaHash == variant.mediaSHA256) else {
            throw PerformanceAssetError.changed(variant.relativePath)
        }
        return url
    }

    /// Only the observed, unboxed UID metadata trailer is excluded from the portable
    /// fingerprint. No bytes are stripped from the actual file or passed through a decoder.
    public static func mediaBodySize(_ url: URL) throws -> Int64 {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size >= 24 else { return Int64(size) }
        try handle.seek(toOffset: size - 4)
        let lengthData = try handle.read(upToCount: 4) ?? Data()
        guard lengthData.count == 4 else { throw PerformanceAssetError.unreadable(url.lastPathComponent) }
        let length = lengthData.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << ($1.offset * 8) }
        guard length > 0, length <= 128, size >= length + 20 else { return Int64(size) }
        try handle.seek(toOffset: size - length - 20)
        let tail = try handle.read(upToCount: Int(length + 20)) ?? Data()
        let marker = Data("__UID_TAG__".utf8) + Data(repeating: 0, count: 5)
        guard tail.count == Int(length + 20), tail.prefix(16) == marker,
              tail.dropFirst(16).dropLast(4).allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return Int64(size) }
        return Int64(size - length - 20)
    }

    /// Availability is Platform evidence only. It never feeds the semantic resolver.
    public func availability(root: URL) throws -> [String: String] {
        try refreshCandidates(root: root, previous: nil, changedPaths: nil).snapshot.unavailable
    }

    /// A nil change list requests a full metadata pass. Specific file changes recheck all
    /// possible locations of their variants; directory/topology changes and uncertain aliases
    /// conservatively rebuild the evidence. This never verifies or caches a media hash.
    public func refreshCandidates(root: URL, previous: PerformanceCandidateSnapshot?,
                                  changedPaths: [String]?) throws -> PerformanceCandidateRefresh {
        try Task.checkCancellation()
        let requestedRoot = root.path
        let root = try Self.physicalURL(root)
        let roots = try Self.candidateRoots(root)
        let variants = manifest.tracks.flatMap(\.variants)
        let allIDs = Set(variants.map(\.id))
        let sameLayout = previous?.root == root && previous?.catalogRevision == snapshot.revision.rawValue
            && previous?.candidateRoots == roots
        let locations: [String: [URL]]
        let pathOwners: [String: Set<String>]
        if let previous, sameLayout {
            // Value collections share their immutable backing storage. A file event must
            // not rebuild the variant × root URL table when the layout is unchanged.
            locations = previous.candidateLocations
            pathOwners = previous.pathOwners
        } else {
            var newLocations: [String: [URL]] = [:]
            var newPathOwners: [String: Set<String>] = [:]
            for variant in variants {
                try Task.checkCancellation()
                let candidates = try Self.candidateLocations(for: variant, root: root, roots: roots)
                newLocations[variant.id] = candidates
                for candidate in candidates {
                    try Task.checkCancellation()
                    newPathOwners[candidate.path, default: []].insert(variant.id)
                }
            }
            locations = newLocations
            pathOwners = newPathOwners
        }

        var fullScan = !sameLayout || changedPaths == nil || previous?.containsSymlinks == true
        var checkedIDs: Set<String> = []
        if !fullScan, let changedPaths {
            for path in changedPaths {
                try Task.checkCancellation()
                guard path.hasPrefix("/") else { fullScan = true; break }
                let url = URL(fileURLWithPath: path)
                // Retain the event's leaf even after deletion or symlink replacement, while
                // resolving its existing parent into the same physical namespace as the index.
                let location: URL?
                do { location = try Self.physicalLocation(url) }
                catch is CancellationError { throw CancellationError() }
                catch { location = nil }
                var spellings = Set([url.path])
                if let location { spellings.insert(location.path) }
                if path == requestedRoot {
                    spellings.insert(root.path)
                } else if path.hasPrefix(requestedRoot + "/") {
                    spellings.insert(root.appendingPathComponent(String(path.dropFirst(requestedRoot.count + 1))).path)
                }
                let insideRoot = spellings.filter { $0 == root.path || $0.hasPrefix(root.path + "/") }
                guard !insideRoot.isEmpty else { continue }
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey])
                let affectsDirectory = insideRoot.contains { changed in
                    changed == root.path || pathOwners.keys.contains { $0.hasPrefix(changed + "/") }
                }
                if affectsDirectory || values?.isDirectory == true || values?.isSymbolicLink == true {
                    fullScan = true
                    break
                }
                let affected = insideRoot.reduce(into: Set<String>()) { ids, path in
                    ids.formUnion(pathOwners[path] ?? [])
                }
                // An unknown tombstone could be a removed directory. A known file tombstone
                // is safe to handle incrementally because its missing location was indexed.
                if affected.isEmpty && values?.isRegularFile != true {
                    fullScan = true
                    break
                }
                checkedIDs.formUnion(affected)
            }
        }
        if fullScan { checkedIDs = allIDs }

        var unavailable = fullScan ? [:] : previous?.unavailable ?? [:]
        func checkCandidates(_ ids: Set<String>) throws {
            for variant in variants where ids.contains(variant.id) {
                try Task.checkCancellation()
                unavailable.removeValue(forKey: variant.id)
                do { _ = try Self.candidateURL(for: variant, root: root, roots: roots) }
                catch is CancellationError { throw CancellationError() }
                catch { unavailable[variant.id] = String(describing: error) }
            }
        }
        try checkCandidates(checkedIDs)
        let hasSymlinks = try Self.containsSymlinks(in: checkedIDs.flatMap { locations[$0] ?? [] })
        if !fullScan && hasSymlinks {
            // Newly discovered aliases make the rest of the cached evidence uncertain.
            // Complete the metadata pass without repeating either the checked candidates
            // or the alias inspection whose positive result already makes it conservative.
            try checkCandidates(allIDs.subtracting(checkedIDs))
            checkedIDs = allIDs
            fullScan = true
        }
        let result = PerformanceCandidateSnapshot(root: root, candidateRoots: roots,
            candidateLocations: locations, unavailable: unavailable,
            catalogRevision: snapshot.revision.rawValue, pathOwners: pathOwners, containsSymlinks: hasSymlinks)
        return PerformanceCandidateRefresh(snapshot: result, checkedVariantIDs: checkedIDs, fullScan: fullScan)
    }

    private static func containsSymlinks(in locations: [URL]) throws -> Bool {
        var visited: Set<String> = []
        var parents: [String: URL] = [:]
        for location in locations {
            try Task.checkCancellation()
            let path = location.path
            guard visited.insert(path).inserted else { continue }
            // Reuse the path index, never resource-value caches attached to its old URLs.
            let current = URL(fileURLWithPath: path)
            let parent = current.deletingLastPathComponent()
            let physicalParent: URL
            if let cached = parents[parent.path] {
                physicalParent = cached
            } else {
                do {
                    physicalParent = try physicalExistingAncestor(parent)
                    parents[parent.path] = physicalParent
                } catch is CancellationError { throw CancellationError() }
                catch { return true }
            }
            if physicalParent.appendingPathComponent(current.lastPathComponent).path != path { return true }
            if (try? current.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { return true }
        }
        return false
    }

    private static func physicalURL(_ url: URL) throws -> URL {
        try url.withUnsafeFileSystemRepresentation { path in
            guard let path else { throw CocoaError(.fileReadInvalidFileName) }
            guard let resolved = realpath(path, nil) else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            defer { free(resolved) }
            return URL(fileURLWithFileSystemRepresentation: resolved, isDirectory: false, relativeTo: nil)
        }
    }

    /// Resolve the existing prefix without requiring a deleted file/directory to reappear.
    private static func physicalExistingAncestor(_ url: URL) throws -> URL {
        var current = url
        var suffix: [String] = []
        while true {
            try Task.checkCancellation()
            do {
                var resolved = try physicalURL(current)
                for component in suffix.reversed() { resolved.appendPathComponent(component) }
                return resolved
            } catch let error as POSIXError where error.code == .ENOENT || error.code == .ENOTDIR {
                guard current.path != "/" else { throw error }
                suffix.append(current.lastPathComponent)
                current.deleteLastPathComponent()
            }
        }
    }

    private static func physicalLocation(_ url: URL) throws -> URL {
        guard url.path != "/" else { return url }
        return try physicalExistingAncestor(url.deletingLastPathComponent()).appendingPathComponent(url.lastPathComponent)
    }
}
