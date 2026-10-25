import Foundation
import BSideCore
import BSidePlatform

/// Failed loads never become an empty writable store. Each append commits atomically before
/// publishing; the last valid in-memory and on-disk histories survive a failed write.
final class SongPlaybackHistoryStore {
    enum StoreError: Error { case invalidData, unsupportedVersion(Int) }
    let url: URL
    private(set) var history = SongPlaybackHistory()
    private var committedData: Data?
    private let write: (Data, URL) throws -> Void
    init(url: URL, write: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) throws {
        self.write = write
        self.url = url
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let data = try Data(contentsOf: url)
        struct Header: Decodable { let version: Int }
        let header = try JSONDecoder().decode(Header.self, from: data)
        guard header.version == 1 else { throw StoreError.unsupportedVersion(header.version) }
        let loaded = try JSONDecoder().decode(SongPlaybackHistory.self, from: data)
        guard loaded.isValid else { throw StoreError.invalidData }
        history = loaded
        committedData = data
    }
    func record(_ record: SongPlaybackRecord) throws {
        guard record.isValid else { throw StoreError.invalidData }
        var next = history
        next.record(record)
        let existing = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
        guard existing == committedData else { throw StoreError.invalidData }
        let data = try JSONEncoder().encode(next)
        try write(data, url)
        committedData = data
        history = next
    }
}

final class SongPlaybackHistoryController {
    let url: URL
    private var store: SongPlaybackHistoryStore?
    private(set) var error: String?
    private(set) var records: [SongPlaybackRecord] = []
    init(url: URL = AppPaths.applicationSupport.appendingPathComponent("song-playback-history.json")) {
        self.url = url
        reload()
    }
    func reload() {
        do { store = try SongPlaybackHistoryStore(url: url); records = store?.history.records ?? []; error = nil }
        catch { store = nil; self.error = "无法读取播放历史，原文件已保留。请检查文件权限或从备份恢复后重试。" }
    }
    func record(_ record: SongPlaybackRecord) {
        guard let store else { return }
        do { try store.record(record); records = store.history.records; error = nil }
        catch { self.error = "播放历史保存失败，已有记录已保留。请检查磁盘空间和文件权限后重试。" }
    }
}
