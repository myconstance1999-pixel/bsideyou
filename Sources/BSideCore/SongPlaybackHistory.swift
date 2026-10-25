import Foundation

/// A confirmed song start, independent of the opt-in duration ledger. Exact official cells and
/// local fingerprints survive renames; display titles are only a fallback when a catalog is gone.
public struct SongPlaybackRecord: Codable, Hashable, Identifiable {
    public let id: String
    public let target: PerformancePlaybackTarget
    public let fileBinding: PerformanceFileBinding?
    public let mode: PerformancePlaybackMode
    public let title: String
    public let lastPlayed: Date

    public init(id: String = UUID().uuidString, target: PerformancePlaybackTarget,
                fileBinding: PerformanceFileBinding? = nil, mode: PerformancePlaybackMode,
                title: String, lastPlayed: Date) {
        self.id = id; self.target = target; self.fileBinding = fileBinding
        self.mode = mode; self.title = title; self.lastPlayed = lastPlayed
    }

    public func isSameFile(as other: Self) -> Bool {
        switch (target, other.target) {
        case (.catalog(let a), .catalog(let b)):
            return a.performanceID == b.performanceID && a.variantID == b.variantID
                && a.catalogRevision == b.catalogRevision
        case (.localFile(let a), .localFile(let b)):
            return a.trackID == b.trackID && a.fileID == b.fileID && fileBinding == other.fileBinding
        default: return false
        }
    }

    public var isValid: Bool {
        guard !id.isEmpty, target.isUsable, lastPlayed.timeIntervalSince1970.isFinite else { return false }
        if target.isLocalFile {
            guard let fileBinding else { return false }
            return fileBinding.byteSize > 0 && !fileBinding.relativePath.isEmpty
                && fileBinding.sha256.count == 64
                && fileBinding.sha256.allSatisfy { $0.isHexDigit }
        }
        return fileBinding == nil
    }
}

public struct SongPlaybackHistory: Codable, Equatable {
    public static let limit = 200
    public let version: Int
    public private(set) var records: [SongPlaybackRecord]
    public init() { version = 1; records = [] }
    public var isValid: Bool {
        version == 1 && records.count <= Self.limit && records.allSatisfy(\.isValid)
            && Set(records.map(\.id)).count == records.count
    }
    public mutating func record(_ record: SongPlaybackRecord) {
        guard record.isValid else { return }
        if records.first?.isSameFile(as: record) == true { records.removeFirst() }
        records.insert(record, at: 0)
        if records.count > Self.limit { records.removeLast(records.count - Self.limit) }
    }
}

/// Actual confirmed playback order, never reconstructed from shuffle or saved queue positions.
/// The queue retains its own visited/priority state while this cursor retraces played files.
public struct SongPlaybackNavigation {
    public struct Item: Equatable {
        public let record: SongPlaybackRecord
        public let queueEntry: PerformanceQueueEntry?
        public init(record: SongPlaybackRecord, queueEntry: PerformanceQueueEntry?) {
            self.record = record; self.queueEntry = queueEntry
        }
    }
    public private(set) var path: [Item] = []
    public private(set) var cursor: Int?
    public private(set) var requestedIndex: Int?
    private var sessionID: String?
    private var active: Item?
    private var recorded = false
    private var navigationIndex: Int?
    public init() {}
    private var position: Int {
        if let requestedIndex { return requestedIndex }
        if let navigationIndex { return navigationIndex }
        guard let cursor else { return path.count }
        if let active, !active.record.isSameFile(as: path[cursor].record) { return cursor + 1 }
        return cursor
    }
    public var canPrevious: Bool { position > 0 && !path.isEmpty }
    public var canForward: Bool { position + 1 < path.count }
    public mutating func requestMove(_ offset: Int) -> (index: Int, item: Item)? {
        let index = position + offset
        guard path.indices.contains(index) else { return nil }
        requestedIndex = index
        return (index, path[index])
    }
    public mutating func cancelMove() { requestedIndex = nil }
    public mutating func installed(sessionID: String, item: Item, navigationIndex: Int? = nil) {
        self.sessionID = sessionID; active = item; recorded = false
        self.navigationIndex = navigationIndex; requestedIndex = nil
    }
    /// Paused readiness commits only an existing navigation position. It never fabricates a play.
    public mutating func received(_ report: PerformanceReport, at date: Date) -> SongPlaybackRecord? {
        guard sessionID == report.sessionID, let active else { return nil }
        if report.isTerminal {
            sessionID = nil; self.active = nil; navigationIndex = nil
            return nil
        }
        guard report.state == .playing || report.state == .paused else { return nil }
        if let navigationIndex { cursor = navigationIndex }
        guard report.state == .playing, !recorded else { return nil }
        recorded = true
        let old = active.record
        let record = SongPlaybackRecord(target: old.target, fileBinding: old.fileBinding,
            mode: old.mode, title: old.title, lastPlayed: date)
        if navigationIndex == nil {
            if let cursor { path = Array(path.prefix(cursor + 1)) }
            let item = Item(record: record, queueEntry: active.queueEntry)
            if path.last?.record.isSameFile(as: record) == true { path[path.count - 1] = item }
            else { path.append(item) }
            if path.count > SongPlaybackHistory.limit { path.removeFirst(path.count - SongPlaybackHistory.limit) }
            cursor = path.count - 1
        }
        return record
    }
    public mutating func reset() { self = Self() }
}
