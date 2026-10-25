import Foundation

public enum DesktopWorkspaceFileError: LocalizedError {
    case outsideRoot, notDirectory, unsupportedStore
    public var errorDescription: String? {
        switch self {
        case .outsideRoot: return "这个链接指向文件盒之外，请单独选择它所在的文件夹。"
        case .notDirectory: return "所选位置不是可读取的文件夹。"
        case .unsupportedStore: return "文件盒设置无法读取，原文件已保留。本次选择仅用于当前会话。"
        }
    }
}

/// Canonical containment is checked again at every browse/open/reveal boundary.
public enum DesktopWorkspaceFiles {
    public static func validatedURL(_ url: URL, within root: URL) throws -> URL {
        guard url.isFileURL, root.isFileURL else { throw DesktopWorkspaceFileError.outsideRoot }
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        var candidate = url.resolvingSymlinksInPath().standardizedFileURL
        let values = try candidate.resourceValues(forKeys: [.isAliasFileKey])
        if values.isAliasFile == true {
            candidate = try URL(resolvingAliasFileAt: candidate, options: [.withoutUI, .withoutMounting])
                .resolvingSymlinksInPath().standardizedFileURL
        }
        let parts = canonicalRoot.pathComponents
        guard candidate.pathComponents.starts(with: parts) else { throw DesktopWorkspaceFileError.outsideRoot }
        return candidate
    }

    public struct Listing {
        public let entries: [URL]
        public let isTruncated: Bool
    }

    public static func children(of directory: URL, within root: URL, limit: Int = 1000) throws -> Listing {
        let directory = try validatedURL(directory, within: root)
        guard try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw DesktopWorkspaceFileError.notDirectory
        }
        let entries = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .isAliasFileKey], options: [.skipsHiddenFiles])
        let sorted = entries.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        return Listing(entries: Array(sorted.prefix(limit)), isTruncated: entries.count > limit)
    }
}

/// A separate preview-only document. Loading failure never becomes an empty writable document.
public struct DesktopWorkspacePreferences: Codable, Equatable {
    public var version = 1
    public var folderPath: String?
    public var folderBookmark: Data?
    public var pinnedApplications: [String] = []
    public init() {}

    public static func load(from url: URL) throws -> Self {
        guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard value.version == 1 else { throw DesktopWorkspaceFileError.unsupportedStore }
        return value
    }

    public func save(to url: URL) throws {
        guard version == 1 else { throw DesktopWorkspaceFileError.unsupportedStore }
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}
