// A saved queue contains selection intent only. Each start resolves its exact target now.
// The running position, session binding and pause intent never participate in persistence.
//
// ADR-022: an entry distinguishes an official semantic choice (performance id + camera) from an
// explicit local track + file. New entries persist the unambiguous typed `target`; the legacy
// official-only `performanceID`/`presentation`/`mode` JSON still decodes unchanged.
import Foundation

/// One queue entry's explicit selection intent.
public enum PerformanceQueueTarget: Hashable, Codable {
    /// Official: the lighting is still resolved when this entry starts (existing behavior).
    case official(performanceID: PerformanceID, presentation: PerformancePresentation)
    /// Local: one explicit track + file, captured when the entry was added so a later change of
    /// the preferred version never retargets an already queued entry.
    case localFile(trackID: String, fileID: String)

    public var officialSelection: (performanceID: PerformanceID, presentation: PerformancePresentation)? {
        if case .official(let performanceID, let presentation) = self { return (performanceID, presentation) }
        return nil
    }

    public var localSelection: (trackID: String, fileID: String)? {
        if case .localFile(let trackID, let fileID) = self { return (trackID, fileID) }
        return nil
    }

    public var isLocalFile: Bool {
        if case .localFile = self { return true }
        return false
    }
}

public struct PerformanceQueueEntry: Codable, Hashable, Identifiable {
    public let id: String
    public let target: PerformanceQueueTarget
    public let mode: PerformancePlaybackMode

    public init(id: String = UUID().uuidString, target: PerformanceQueueTarget,
                mode: PerformancePlaybackMode) {
        self.id = id
        self.target = target
        self.mode = mode
    }

    /// Existing official call shape.
    public init(id: String = UUID().uuidString, performanceID: PerformanceID,
                presentation: PerformancePresentation, mode: PerformancePlaybackMode) {
        self.init(id: id, target: .official(performanceID: performanceID, presentation: presentation), mode: mode)
    }

    /// Explicit local-file call shape.
    public init(id: String = UUID().uuidString, trackID: String, fileID: String,
                mode: PerformancePlaybackMode) {
        self.init(id: id, target: .localFile(trackID: trackID, fileID: fileID), mode: mode)
    }

    /// Official-only projection. Nil for a local entry — callers must handle the local case
    /// rather than receiving a fabricated performance identity.
    public var performanceID: PerformanceID? { target.officialSelection?.performanceID }
    public var presentation: PerformancePresentation? { target.officialSelection?.presentation }

    private enum CodingKeys: String, CodingKey {
        case id, target, mode, performanceID, presentation
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        if values.contains(.target) {
            target = try values.decode(PerformanceQueueTarget.self, forKey: .target)
        } else {
            target = .official(performanceID: try values.decode(PerformanceID.self, forKey: .performanceID),
                               presentation: try values.decode(PerformancePresentation.self, forKey: .presentation))
        }
        mode = try values.decode(PerformancePlaybackMode.self, forKey: .mode)
    }

    /// New entries write the typed target only; the legacy flat keys are never produced.
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(target, forKey: .target)
        try values.encode(mode, forKey: .mode)
    }
}

public enum PerformanceQueueOrder: String, Codable, CaseIterable, Hashable {
    case stopAfterQueue
    case repeatAll
    case shuffle
    case repeatOne
}

public struct PerformanceQueueConfiguration: Codable, Hashable {
    public var entries: [PerformanceQueueEntry]
    public var order: PerformanceQueueOrder

    public init(entries: [PerformanceQueueEntry] = [], order: PerformanceQueueOrder = .stopAfterQueue) {
        precondition(Self.validIDs(entries), "Queue entry identities must be unique and nonempty")
        self.entries = entries
        self.order = order
    }

    fileprivate static func validIDs(_ entries: [PerformanceQueueEntry]) -> Bool {
        entries.allSatisfy { !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            && Set(entries.map(\.id)).count == entries.count
    }

    private enum CodingKeys: String, CodingKey { case entries, order }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let entries = try values.decode([PerformanceQueueEntry].self, forKey: .entries)
        guard Self.validIDs(entries) else {
            throw DecodingError.dataCorruptedError(forKey: .entries, in: values,
                debugDescription: "Queue entry identities must be unique and nonempty")
        }
        self.entries = entries
        order = try values.decode(PerformanceQueueOrder.self, forKey: .order)
    }
}

public struct PerformanceQueueState {
    public enum Outcome: Equatable {
        case ignored
        case stopped
        case play(PerformanceQueueEntry)
    }

    public private(set) var configuration: PerformanceQueueConfiguration
    /// Snapshot of the entry that actually started; removing it cannot change current media.
    public private(set) var activeEntry: PerformanceQueueEntry?
    public private(set) var activeSessionID: String?
    public private(set) var isRunning = false
    public private(set) var paused = false
    private var visitedIDs: Set<String> = []
    /// Explicit "play this next" intent for one still-unplayed entry. It is deliberately not an
    /// order mode: it outranks shuffle's random draw once and never survives that entry playing,
    /// so inserting it cannot restart the current song or revoke its binding.
    private var nextPriorityID: String?

    public init(configuration: PerformanceQueueConfiguration = PerformanceQueueConfiguration()) {
        precondition(PerformanceQueueConfiguration.validIDs(configuration.entries),
                     "Queue entry identities must be unique and nonempty")
        self.configuration = configuration
    }

    /// Explicit begin starts fresh. A specified sequential entry skips its preceding prefix;
    /// shuffle marks only the chosen entry. The caller supplies randomness, never Core.
    public mutating func begin(entryID: String? = nil, favorites: Set<PerformanceQueueTarget> = [], chooseIndex: (Int) -> Int) -> PerformanceQueueEntry? {
        stop()
        let entries = configuration.entries
        guard !entries.isEmpty else { return nil }
        let index: Int
        if let entryID {
            guard let selected = entries.firstIndex(where: { $0.id == entryID }) else { return nil }
            index = selected
        } else {
            index = configuration.order == .shuffle ? Self.shuffleIndex(entries, favorites: favorites, chooseIndex: chooseIndex) : 0
            guard entries.indices.contains(index) else { return nil }
        }
        if configuration.order != .shuffle {
            visitedIDs.formUnion(entries.prefix(index).map(\.id))
        }
        isRunning = true
        return activate(entries[index])
    }

    /// The owner binds the newly created session before dispatch. A pending entry accepts one
    /// binding only; ordinary playing/paused reports cannot rewrite the user's pause intent.
    @discardableResult public mutating func bind(sessionID: String) -> Bool {
        guard isRunning, activeEntry != nil, activeSessionID == nil,
              !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        activeSessionID = sessionID
        return true
    }

    public mutating func received(_ report: PerformanceReport, favorites: Set<PerformanceQueueTarget> = [], chooseIndex: (Int) -> Int) -> Outcome {
        guard isRunning, activeSessionID == report.sessionID else { return .ignored }
        switch report.state {
        case .loading, .playing, .paused:
            return .ignored
        case .failed, .stopped:
            stop()
            return .stopped
        case .ended:
            return advance(repeatingCurrent: true, favorites: favorites, chooseIndex: chooseIndex)
        }
    }

    /// Explicit next skips repeat-one. While verification is pending it also revokes that
    /// entry's binding; the owner cancels the corresponding work before starting the result.
    public mutating func next(favorites: Set<PerformanceQueueTarget> = [], chooseIndex: (Int) -> Int) -> Outcome {
        guard isRunning else { return .ignored }
        return advance(repeatingCurrent: false, favorites: favorites, chooseIndex: chooseIndex)
    }

    @discardableResult public mutating func setPaused(_ value: Bool) -> Bool {
        guard isRunning else { return false }
        paused = value
        return true
    }

    public mutating func stop() {
        isRunning = false
        paused = false
        activeEntry = nil
        activeSessionID = nil
        visitedIDs.removeAll()
        nextPriorityID = nil
    }

    public mutating func agentLost() { stop() }

    /// Retracing a confirmed song changes the active snapshot/binding only. The queue's visited
    /// set and explicit next priority survive; removed entries remain valid playback snapshots.
    public mutating func bindHistory(_ entry: PerformanceQueueEntry, sessionID: String) {
        guard isRunning else { return }
        activeEntry = entry
        activeSessionID = sessionID
    }

    // Configuration edits never change the playing snapshot, binding, pause or visited set.
    @discardableResult public mutating func append(_ entry: PerformanceQueueEntry) -> Bool {
        guard !entry.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !configuration.entries.contains(where: { $0.id == entry.id }) else { return false }
        configuration.entries.append(entry)
        return true
    }

    @discardableResult public mutating func remove(entryID: String) -> Bool {
        guard let index = configuration.entries.firstIndex(where: { $0.id == entryID }) else { return false }
        configuration.entries.remove(at: index)
        // A removed entry can never be an explicit next any more.
        if nextPriorityID == entryID { nextPriorityID = nil }
        return true
    }

    /// Destination is the final zero-based index, not SwiftUI's insertion offset.
    @discardableResult public mutating func move(entryID: String, to index: Int) -> Bool {
        guard configuration.entries.indices.contains(index),
              let previous = configuration.entries.firstIndex(where: { $0.id == entryID }),
              previous != index else { return false }
        let entry = configuration.entries.remove(at: previous)
        configuration.entries.insert(entry, at: index)
        return true
    }

    public mutating func clear() {
        configuration.entries.removeAll()
        nextPriorityID = nil
    }
    public mutating func setOrder(_ order: PerformanceQueueOrder) { configuration.order = order }

    /// 下一首播放: insert one exact entry immediately after the entry that is playing now,
    /// without interrupting it. The current snapshot, its session binding, the pause intent and
    /// the visited set are untouched, so nothing about the current song changes.
    ///
    /// The insertion alone cannot guarantee "next" in every order: shuffle picks randomly,
    /// repeat-one would repeat the current entry, and the order may change after this call. The
    /// entry is therefore ALWAYS recorded as the one-time priority target. That intent outranks
    /// shuffle, repeat-all, repeat-one and the sequential cursor exactly once; it survives
    /// ordinary list edits but is dropped as soon as the entry plays or leaves the list.
    @discardableResult public mutating func insertAfterActive(_ entry: PerformanceQueueEntry) -> Bool {
        guard let active = activeEntry,
              !entry.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !configuration.entries.contains(where: { $0.id == entry.id }),
              let currentIndex = configuration.entries.firstIndex(where: { $0.id == active.id })
        else { return false }
        configuration.entries.insert(entry, at: currentIndex + 1)
        nextPriorityID = entry.id
        return true
    }

    private mutating func activate(_ entry: PerformanceQueueEntry) -> PerformanceQueueEntry {
        activeEntry = entry
        activeSessionID = nil
        visitedIDs.insert(entry.id)
        if nextPriorityID == entry.id { nextPriorityID = nil }
        return entry
    }

    /// Weighted sampling without replacement: favorites get three tickets, ordinary entries
    /// one. The finite run still visits each entry once; only the draw order changes.
    private static func shuffleIndex(_ entries: [PerformanceQueueEntry],
                                     favorites: Set<PerformanceQueueTarget>, chooseIndex: (Int) -> Int) -> Int {
        let weights = entries.map { favorites.contains($0.target) ? 3 : 1 }
        let total = weights.reduce(0, +)
        var ticket = chooseIndex(total)
        guard ticket >= 0 && ticket < total else { return -1 }
        for (index, weight) in weights.enumerated() {
            if ticket < weight { return index }
            ticket -= weight
        }
        return -1
    }

    private mutating func advance(repeatingCurrent: Bool, favorites: Set<PerformanceQueueTarget>, chooseIndex: (Int) -> Int) -> Outcome {
        // Consume the old binding before returning another entry, including repeat-one.
        activeSessionID = nil
        // An explicit "play next" outranks every order mode, including repeat-one and the
        // sequential cursor, and is checked BEFORE repeat-one so a natural end honors it. It is
        // consumed when it plays and never replays on the following decision.
        if let priority = nextPriorityID,
           let entry = configuration.entries.first(where: { $0.id == priority }) {
            nextPriorityID = nil
            return .play(activate(entry))
        }
        if repeatingCurrent, configuration.order == .repeatOne,
           let current = activeEntry,
           let retained = configuration.entries.first(where: { $0.id == current.id }) {
            return .play(activate(retained))
        }
        var remaining = configuration.entries.filter { !visitedIDs.contains($0.id) }
        if remaining.isEmpty && configuration.order == .repeatAll {
            visitedIDs.removeAll()
            remaining = configuration.entries
        }
        guard !remaining.isEmpty else {
            stop()
            return .stopped
        }
        let index = configuration.order == .shuffle ? Self.shuffleIndex(remaining, favorites: favorites, chooseIndex: chooseIndex) : 0
        guard remaining.indices.contains(index) else {
            stop()
            return .stopped
        }
        return .play(activate(remaining[index]))
    }
}
