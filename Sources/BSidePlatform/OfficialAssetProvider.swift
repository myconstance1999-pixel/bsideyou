// BSidePlatform — OfficialAssetProvider: official BSide Offline folder → logical ContentCatalog.
// Read-only by contract (ADR-004): never writes, never renames, never copies media.

import Foundation
import Darwin
import BSideCore

public enum AssetValidationError: Error, CustomStringConvertible {
    case directoryNotFound(String)
    case notDirectory(String)
    case layoutNotRecognized(String)
    case ambiguousLayouts([String])
    case noContentFound(String)

    public var description: String {
        switch self {
        case .directoryNotFound(let p): return "Asset directory not found: \(p)"
        case .notDirectory(let p): return "Asset location is not a directory: \(p)"
        case .layoutNotRecognized(let p): return "Not a recognized BSide Offline layout: \(p)"
        case .ambiguousLayouts(let paths):
            return "Multiple BSide Offline layouts found. Select a specific version folder:\n"
                + paths.joined(separator: "\n")
        case .noContentFound(let p): return "No playable media found in: \(p)"
        }
    }
}

/// Metadata records a source version; it is not a content hash or media integrity verdict.
public struct AssetSourceVersion: Equatable, Sendable {
    public let physicalURL: URL
    public let deviceID: UInt64
    public let inode: UInt64
    public let byteSize: Int64
    public let modificationSeconds: Int64
    public let modificationNanoseconds: Int64
    public let changeSeconds: Int64
    public let changeNanoseconds: Int64

    /// A directory move changes the URL without changing the media inode or timestamps.
    /// The full Equatable comparison also includes location so callers can refresh an old URL.
    public func hasSameMedia(as other: AssetSourceVersion) -> Bool {
        deviceID == other.deviceID && inode == other.inode && byteSize == other.byteSize
            && modificationSeconds == other.modificationSeconds
            && modificationNanoseconds == other.modificationNanoseconds
            && changeSeconds == other.changeSeconds && changeNanoseconds == other.changeNanoseconds
    }
}

/// Resolved asset bundle: logical catalog + the ContentID → file URL table (kept in Platform;
/// Core never sees URLs).
public struct AssetBundle {
    public var catalog: ContentCatalog
    var urls: [ContentID: URL]
    public let sourceVersions: [ContentID: AssetSourceVersion]

    public func url(for id: ContentID) -> URL? { urls[id] }

    /// The admitted loop file for one exact discovered combination, or nil when this binding
    /// does not admit it (missing on disk, product-excluded, or never discovered). It returns
    /// ONLY the URL recorded during discovery — the file that was actually read — and never
    /// re-derives a path from the catalog's filename grammar, so a caller cannot preview a
    /// guessed or substituted combination that this binding never admitted.
    public func loopFileURL(for key: ContentKey) -> URL? {
        guard let id = catalog.loops[key] else { return nil }
        return urls[id]
    }
}

public struct OfficialAssetProvider {
    public let baseURL: URL

    /// Product exclusion of three daily loop combinations that were confirmed to fail on this
    /// machine's official distribution set. The owner accepted that no replacement wallpaper
    /// source exists and asked to remove exactly these choices; this is a bounded decision about
    /// these combinations only, NOT a verdict on every B/C scene, every outfit, or every official
    /// distribution.
    ///
    /// The exclusion is applied once at catalog admission so UI capability and playback policy
    /// share the same truth: an excluded key never enters `ContentCatalog.loops`, never receives a
    /// URL or a source version, and is not reported as an unrecognized file (it is a valid official
    /// name that is deliberately not offered). Callers therefore observe it exactly like any other
    /// missing combination through the existing missing-content flow — no UI-only filter and no
    /// silent substitution with different footage.
    public static let productExcludedLoopKeys: Set<ContentKey> = [
        ContentKey(scene: .b, outfit: .r1, time: .evening),
        ContentKey(scene: .b, outfit: .r1, time: .night),
        ContentKey(scene: .c, outfit: .r1, time: .evening),
    ]

    /// - Parameter assetPath: authorized folder (may use ~). The caller retains its access
    ///   lease through all reads; this provider does not create or resolve access bookmarks.
    public init(assetPath: String) {
        let expanded = (assetPath as NSString).expandingTildeInPath
        self.baseURL = URL(fileURLWithPath: expanded, isDirectory: true)
    }

    // Official filename grammar (frozen from baseline-sha256 / phase-2 catalog):
    //   Wallpaper_Presence/{A|B|C}_R{1|2|3}_{1200|1730|2000}.mp4            → loop
    //   Wallpaper_Presence/{A|B|C}_Transition_{t1}_{t2}.mp4                  → transition (t1→t2)
    //   Wallpaper_Ambience/ambient_loop_{n}.mp3                              → ambient track
    // Parsed with plain string splits — no regex, no ambiguity.

    static func parseLoop(_ name: String) -> ContentKey? {
        guard name.hasSuffix(".mp4") else { return nil }
        let parts = name.dropLast(4).split(separator: "_").map(String.init)
        guard parts.count == 3,
              let scene = Scene(rawValue: parts[0]),
              let outfit = Outfit(rawValue: parts[1]),
              let time = TimeOfDay(rawValue: parts[2]) else { return nil }
        return ContentKey(scene: scene, outfit: outfit, time: time)
    }

    static func parseTransition(_ name: String) -> TransitionKey? {
        guard name.hasSuffix(".mp4") else { return nil }
        let parts = name.dropLast(4).split(separator: "_").map(String.init)
        guard parts.count == 4, parts[1] == "Transition",
              let scene = Scene(rawValue: parts[0]),
              let from = TimeOfDay(rawValue: parts[2]),
              let to = TimeOfDay(rawValue: parts[3]) else { return nil }
        return TransitionKey(scene: scene, from: from, to: to)
    }

    static func parseAmbientIndex(_ name: String) -> Int? {
        guard name.hasSuffix(".mp3") else { return nil }
        let prefix = "ambient_loop_"
        let base = String(name.dropLast(4))
        guard base.hasPrefix(prefix), let index = Int(base.dropFirst(prefix.count)) else { return nil }
        return index
    }

    static func looksLikeVersionDir(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return false } // e.g. 0.0.9.627 (4 numeric components)
        return parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isNumber } }
    }

    private struct Layout {
        let contentRoot: URL
        let assetsDirectory: URL

        var presenceDirectory: URL {
            assetsDirectory.appendingPathComponent("Wallpaper_Presence", isDirectory: true)
        }

        var ambienceDirectory: URL {
            assetsDirectory.appendingPathComponent("Wallpaper_Ambience", isDirectory: true)
        }
    }

    /// fstatat with no flags follows directory symlinks, like the previous fileExists check, but preserves
    /// permission and I/O failures instead of treating inaccessible locations as absent.
    private static func fileMode(_ url: URL) throws -> mode_t? {
        try Task.checkCancellation()
        var info = stat()
        guard fstatat(AT_FDCWD, url.path, &info, 0) == 0 else {
            let code = errno
            if code == ENOENT || code == ENOTDIR { return nil }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                          userInfo: [NSFilePathErrorKey: url.path])
        }
        return info.st_mode
    }

    private static func isDirectory(_ url: URL) throws -> Bool {
        guard let mode = try fileMode(url) else { return false }
        return mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
    }

    private static func contentsOfDirectory(_ directory: URL) throws -> [URL] {
        // Foundation URL enumeration can reject a directory symlink with ENOTDIR even when
        // stat succeeds. Resolve the directory before enumeration; read failures still throw.
        try Task.checkCancellation()
        let files = try FileManager.default.contentsOfDirectory(
            at: directory.resolvingSymlinksInPath(), includingPropertiesForKeys: nil)
        try Task.checkCancellation()
        return files
    }

    private static func isRegularFile(_ file: URL) throws -> Bool {
        // Enumeration URLs can carry cached attributes even with no requested property keys.
        // A fresh URL performs the real metadata read and preserves any access failure, while
        // retaining resourceValues' existing behavior of not treating media symlinks as files.
        try URL(fileURLWithPath: file.path).resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
    }

    /// Fresh, no-follow metadata capture for one chosen file. Discovery uses this to build the
    /// catalog; a caller that must detect a replaced file without rescanning the library calls it
    /// again at its own checkpoints and compares `hasSameMedia`. A media symlink is still rejected
    /// and any stat failure throws rather than returning a fabricated version.
    public static func sourceVersion(_ file: URL) throws -> AssetSourceVersion {
        try Task.checkCancellation()
        // Resolve only the parent so a replaced media symlink is still rejected by the
        // no-follow stat below. POSIX physical paths also unify /var and /private/var.
        let parent = file.deletingLastPathComponent()
        let physicalParent: URL = try parent.withUnsafeFileSystemRepresentation { path in
            guard let path else { throw CocoaError(.fileReadInvalidFileName) }
            guard let resolved = realpath(path, nil) else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                              userInfo: [NSFilePathErrorKey: parent.path])
            }
            defer { free(resolved) }
            return URL(fileURLWithFileSystemRepresentation: resolved, isDirectory: true, relativeTo: nil)
        }
        let physical = physicalParent.appendingPathComponent(file.lastPathComponent)
        var info = stat()
        guard fstatat(AT_FDCWD, physical.path, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                          userInfo: [NSFilePathErrorKey: physical.path])
        }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: physical.path])
        }
        return AssetSourceVersion(physicalURL: physical, deviceID: UInt64(truncatingIfNeeded: info.st_dev),
            inode: UInt64(info.st_ino), byteSize: Int64(info.st_size),
            modificationSeconds: Int64(info.st_mtimespec.tv_sec), modificationNanoseconds: Int64(info.st_mtimespec.tv_nsec),
            changeSeconds: Int64(info.st_ctimespec.tv_sec), changeNanoseconds: Int64(info.st_ctimespec.tv_nsec))
    }

    private static func layout(assetsDirectory: URL) throws -> Layout? {
        guard try isDirectory(assetsDirectory),
              try isDirectory(assetsDirectory.appendingPathComponent("Wallpaper_Presence", isDirectory: true))
        else { return nil }
        return Layout(contentRoot: assetsDirectory.deletingLastPathComponent(),
                      assetsDirectory: assetsDirectory)
    }

    /// Inspect only the selected entry point and, if needed, its immediate version folders.
    /// An explicitly selected layout takes precedence over automatic version discovery.
    private func discoverLayout() throws -> Layout {
        try Task.checkCancellation()
        guard let mode = try Self.fileMode(baseURL) else {
            throw AssetValidationError.directoryNotFound(baseURL.path)
        }
        guard mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw AssetValidationError.notDirectory(baseURL.path)
        }

        if baseURL.lastPathComponent == "Wallpaper_Presence",
           let selected = try Self.layout(assetsDirectory: baseURL.deletingLastPathComponent()) {
            return selected
        }
        if baseURL.lastPathComponent == "assets",
           let selected = try Self.layout(assetsDirectory: baseURL) {
            return selected
        }
        if let direct = try Self.layout(assetsDirectory: baseURL.appendingPathComponent("assets", isDirectory: true)) {
            return direct
        }

        let children = try Self.contentsOfDirectory(baseURL)
        let candidates = try children.compactMap { child -> Layout? in
            try Task.checkCancellation()
            guard Self.looksLikeVersionDir(child.lastPathComponent), try Self.isDirectory(child) else { return nil }
            return try Self.layout(assetsDirectory: child.appendingPathComponent("assets", isDirectory: true))
        }.sorted { $0.contentRoot.path < $1.contentRoot.path }

        guard let candidate = candidates.first else {
            throw AssetValidationError.layoutNotRecognized(baseURL.path)
        }
        guard candidates.count == 1 else {
            throw AssetValidationError.ambiguousLayouts(candidates.map { $0.contentRoot.path })
        }
        return candidate
    }

    /// Validate the folder and build the catalog. Layout failures are typed; directory
    /// enumeration failures retain their filesystem error rather than appearing as empty media.
    /// Empty loops are allowed only when the caller explicitly refreshes an already-bound root.
    public func loadCatalog(allowEmptyLoops: Bool = false) throws -> AssetBundle {
        try Task.checkCancellation()
        let layout = try discoverLayout()
        let presenceDir = layout.presenceDirectory
        let ambienceDir = layout.ambienceDirectory

        var catalog = ContentCatalog(sourceLabel: layout.contentRoot.lastPathComponent)
        var urls: [ContentID: URL] = [:]
        var sourceVersions: [ContentID: AssetSourceVersion] = [:]

        for file in try Self.contentsOfDirectory(presenceDir) {
            try Task.checkCancellation()
            let name = file.lastPathComponent
            let isRegularFile = try Self.isRegularFile(file)
            if isRegularFile, let key = Self.parseLoop(name) {
                // A confirmed-unsupported combination is not admitted and is not "unknown":
                // it is a recognized official name this product deliberately does not offer.
                guard !Self.productExcludedLoopKeys.contains(key) else { continue }
                let id = ContentID("loop://\(key.scene.rawValue)/\(key.outfit.rawValue)/\(key.time.rawValue)")
                catalog.loops[key] = id
                urls[id] = file
                sourceVersions[id] = try Self.sourceVersion(file)
            } else if isRegularFile, let key = Self.parseTransition(name) {
                let id = ContentID("transition://\(key.scene.rawValue)/\(key.from.rawValue)->\(key.to.rawValue)")
                catalog.transitions[key] = id
                urls[id] = file
                sourceVersions[id] = try Self.sourceVersion(file)
            } else {
                catalog.unknownFiles.append(name)
            }
        }

        let ambienceFiles = try Self.isDirectory(ambienceDir)
            ? try Self.contentsOfDirectory(ambienceDir)
            : []
        for file in ambienceFiles {
            try Task.checkCancellation()
            let name = file.lastPathComponent
            let isRegularFile = try Self.isRegularFile(file)
            if isRegularFile, let index = Self.parseAmbientIndex(name) {
                let id = ContentID("ambient://\(index)")
                catalog.ambientTracks.append(AmbientTrack(id: id, index: index, label: name))
                urls[id] = file
                sourceVersions[id] = try Self.sourceVersion(file)
            } else {
                catalog.unknownFiles.append(name)
            }
        }

        catalog.ambientTracks.sort { $0.index < $1.index }
        catalog.unknownFiles.sort()

        try Task.checkCancellation()
        guard allowEmptyLoops || !catalog.loops.isEmpty else {
            throw AssetValidationError.noContentFound(presenceDir.path)
        }
        return AssetBundle(catalog: catalog, urls: urls, sourceVersions: sourceVersions)
    }
}
