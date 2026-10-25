// BSideTestRunner — deterministic, metadata-only import summary for an explicitly selected
// local root (ADR-022). It never reads, hashes or decodes media payload: only directory entries,
// regular-file checks and byte sizes. Used by the worker to re-count the known additional root
// without touching it.
import Foundation
import BSideCore
import BSidePlatform

private struct LocalImportSummaryGroup: Codable {
    let relativePath: String
    let fileCount: Int
    let byteSize: Int64
}

private struct LocalImportSummary: Codable {
    let schemaVersion: Int
    let rootDisplay: String
    let layout: String
    let categoryCount: Int
    let workFolderCount: Int
    let admittedGroupCount: Int
    let admittedFileCount: Int
    let totalMediaFileCount: Int
    let totalByteSize: Int64
    let groups: [LocalImportSummaryGroup]
}

func writeLocalImportSummary(rootPath: String, outputPath: String) throws {
    let root = URL(fileURLWithPath: rootPath, isDirectory: true)
    // Official exclusion is location-based under an ALREADY-AUTHORIZED official source binding and
    // the test runner holds no such binding for an arbitrary selected root, so nothing is guessed
    // away here. A file whose name merely matches an official basename is preserved.
    let all = try LocalSongScanner.scan(root: root)

    let allFiles = all.reduce(0) { $0 + $1.files.count }
    let groups = all
        .map { LocalImportSummaryGroup(relativePath: $0.relativePath, fileCount: $0.files.count,
                                       byteSize: $0.files.reduce(0) { $0 + $1.byteSize }) }
        .sorted { $0.relativePath < $1.relativePath }
    let depths = Set(groups.map { $0.relativePath.split(separator: "/").count })
    let layout: String
    switch depths {
    case []: layout = "empty"
    case [0]: layout = "root"
    case [1]: layout = "immediate-children"
    case [2]: layout = "category-work-depth2"
    default: layout = "mixed"
    }
    let summary = LocalImportSummary(
        schemaVersion: 1,
        rootDisplay: root.lastPathComponent,
        layout: layout,
        categoryCount: Set(groups.compactMap { $0.relativePath.split(separator: "/").first.map(String.init) }).count,
        workFolderCount: groups.filter { $0.relativePath.split(separator: "/").count == 2 }.count,
        admittedGroupCount: groups.count,
        admittedFileCount: allFiles,
        totalMediaFileCount: allFiles,
        totalByteSize: groups.reduce(0) { $0 + $1.byteSize },
        groups: groups)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(summary)
    try data.write(to: URL(fileURLWithPath: outputPath), options: [.atomic])
    print("local-import-summary written: groups=\(groups.count) files=\(allFiles) (no name-based exclusion)")
}
