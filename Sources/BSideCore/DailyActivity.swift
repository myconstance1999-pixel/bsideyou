// BSideCore — reviewed daily activity ENTRY (one explicit, transient request).
//
// The activity request is a current-session ControlApp-owned message: it is deliberately NOT a
// field of DesiredState, is never persisted, and is never replayed after an Agent disconnect or
// restart. The ordinary whole-source preference it carries IS persisted by ControlApp, so
// recovery replays the plain whole-source loop — never the one-shot entry point.

/// A reviewed daily activity that has a real authored entry into a whole source unit.
/// `reading` is intentionally absent: no reading activity was reviewed, so none is offered.
public enum DailyActivityID: String, Codable, CaseIterable, Hashable {
    case desk
    case rest
}

/// An offset expressed as source PTS ticks over a timebase. Core stays integer/pure; the
/// platform converts it to a media time (CMTime) when installing.
public struct DailyActivityEntryPoint: Hashable {
    public let ticks: Int64
    public let timescale: Int32

    public init(ticks: Int64, timescale: Int32) {
        self.ticks = ticks
        self.timescale = timescale
    }

    /// Exact seconds as PTS ticks/timescale (e.g. 10.6s).
    public var seconds: Double { Double(ticks) / Double(timescale) }
}

/// One reviewed authored entry: the exact (scene, outfit, time) whole source it belongs to and the
/// offset at which that source's camera cuts to the activity. Each entry is bound to ONE source;
/// the same activity in a different source carries its own offset.
public struct DailyActivityEntry: Hashable {
    public let sourceKey: ContentKey
    public let activityID: DailyActivityID
    public let point: DailyActivityEntryPoint

    public init(sourceKey: ContentKey, activityID: DailyActivityID, point: DailyActivityEntryPoint) {
        self.sourceKey = sourceKey
        self.activityID = activityID
        self.point = point
    }

    public var ticks: Int64 { point.ticks }
    public var timescale: Int32 { point.timescale }
}

/// The reviewed entry inventory. Every entry is an authored shot introduction inside ONE whole
/// source unit at an exact camera-cut boundary; it is never a self-loop, a cross-source join or a
/// new activity category. Lookup is by (ContentKey, DailyActivityID): a combination that is absent
/// is simply unqualified and must never fall back to another source, activity or time.
public enum DailyActivityCatalog {
    private struct EntryKey: Hashable {
        let sourceKey: ContentKey
        let activityID: DailyActivityID
    }

    private static let table: [EntryKey: DailyActivityEntry] = {
        var table: [EntryKey: DailyActivityEntry] = [:]
        for entry in entries {
            table[EntryKey(sourceKey: entry.sourceKey, activityID: entry.activityID)] = entry
        }
        return table
    }()

    /// Exactly the reviewed entries: the two original A/R1/sunset points plus the six reviewed
    /// camera-cut introductions in A/R1/noon, A/R1/night and A/R2/sunset. Order is
    /// source-major, activity-minor so the diagnostics are deterministic.
    public static let entries: [DailyActivityEntry] = [
        DailyActivityEntry(sourceKey: ContentKey(scene: .a, outfit: .r1, time: .noon),
                           activityID: .desk, point: DailyActivityEntryPoint(ticks: 318_000, timescale: 30_000)),
        DailyActivityEntry(sourceKey: ContentKey(scene: .a, outfit: .r1, time: .noon),
                           activityID: .rest, point: DailyActivityEntryPoint(ticks: 5_355_000, timescale: 30_000)),
        DailyActivityEntry(sourceKey: ContentKey(scene: .a, outfit: .r1, time: .evening),
                           activityID: .desk, point: DailyActivityEntryPoint(ticks: 1_913_000, timescale: 30_000)),
        DailyActivityEntry(sourceKey: ContentKey(scene: .a, outfit: .r1, time: .evening),
                           activityID: .rest, point: DailyActivityEntryPoint(ticks: 2_979_000, timescale: 30_000)),
        DailyActivityEntry(sourceKey: ContentKey(scene: .a, outfit: .r1, time: .night),
                           activityID: .desk, point: DailyActivityEntryPoint(ticks: 2_916_000, timescale: 30_000)),
        DailyActivityEntry(sourceKey: ContentKey(scene: .a, outfit: .r1, time: .night),
                           activityID: .rest, point: DailyActivityEntryPoint(ticks: 319_000, timescale: 30_000)),
        DailyActivityEntry(sourceKey: ContentKey(scene: .a, outfit: .r2, time: .evening),
                           activityID: .desk, point: DailyActivityEntryPoint(ticks: 3_290_000, timescale: 30_000)),
        DailyActivityEntry(sourceKey: ContentKey(scene: .a, outfit: .r2, time: .evening),
                           activityID: .rest, point: DailyActivityEntryPoint(ticks: 4_033_000, timescale: 30_000)),
    ]

    /// The exact reviewed entry for this source and activity, or nil when that combination was
    /// never reviewed (no substitution or fallback is ever produced here).
    public static func entry(for sourceKey: ContentKey, activityID: DailyActivityID) -> DailyActivityEntry? {
        table[EntryKey(sourceKey: sourceKey, activityID: activityID)]
    }

    /// Whether a whole source offers at least one reviewed entry. A source without any entry is
    /// never silently entered through a different one.
    public static func hasAnyEntry(for sourceKey: ContentKey) -> Bool {
        entries.contains { $0.sourceKey == sourceKey }
    }
}

/// The concrete whole-source selection part of a desired state. `TimeMode.auto` has no concrete
/// source key yet, so pending-request comparisons treat it as "no stable source".
public extension DesiredState {
    var dailySourceKey: ContentKey? {
        guard case .fixed(let time) = timeMode else { return nil }
        return ContentKey(scene: scene, outfit: outfit, time: time)
    }
}

/// One explicit entry click. `desired` is the COMPLETE desired state captured atomically with
/// the request, so applying it cannot trigger a separate ordinary source install first.
public struct DailyActivityRequest: Codable, Hashable {
    public let requestID: String
    public let activityID: DailyActivityID
    public let desired: DesiredState

    public init(requestID: String, activityID: DailyActivityID, desired: DesiredState) {
        self.requestID = requestID
        self.activityID = activityID
        self.desired = desired
    }
}

/// Transient lifecycle of one entry request. `applied` means the Agent applied the desired state
/// and armed the entry; it is never a claim that media is audibly/visibly playing.
public enum DailyActivityRequestState: String, Codable, CaseIterable, Hashable {
    case verifying
    case applied
    case failed
    case cancelled
}

/// Agent → ControlApp result for one request. ControlApp ignores reports that do not match the
/// latest requestID it sent.
public struct DailyActivityReport: Codable, Hashable {
    public let requestID: String
    public let state: DailyActivityRequestState
    public let detail: String?

    public init(requestID: String, state: DailyActivityRequestState, detail: String? = nil) {
        self.requestID = requestID
        self.state = state
        self.detail = detail
    }
}

/// Pure latest-request-wins bookkeeping shared by ControlApp and the Agent. It holds at most one
/// transient request: a new explicit click replaces (and cancels) the previous one, and only the
/// latest request's report may change the visible state. It is never persisted and never replayed.
public struct DailyActivityRequestTracker: Equatable {
    public private(set) var latest: DailyActivityRequest?
    public private(set) var state: DailyActivityRequestState?
    public private(set) var detail: String?

    public init() {}

    /// Adopt a new explicit request. Returns the superseded requestID, if any, so the caller can
    /// report that request cancelled; a same-activity re-click still produces a new requestID.
    @discardableResult
    public mutating func begin(_ request: DailyActivityRequest) -> String? {
        let superseded = latest?.requestID
        latest = request
        state = .verifying
        detail = nil
        return superseded
    }

    /// Accept a report only when it belongs to the latest request. `false` means ignored.
    @discardableResult
    public mutating func accept(_ report: DailyActivityReport) -> Bool {
        guard let latest, report.requestID == latest.requestID else { return false }
        state = report.state
        detail = report.detail
        return true
    }

    /// The latest request is superseded (source change, Agent loss or shutdown). Returns the
    /// cancellation report to send, or nil when nothing is outstanding or already cancelled.
    public mutating func cancel(detail: String?) -> DailyActivityReport? {
        guard let latest, state != .cancelled else { return nil }
        state = .cancelled
        self.detail = detail
        return DailyActivityReport(requestID: latest.requestID, state: .cancelled, detail: detail)
    }

    public mutating func clear() {
        latest = nil
        state = nil
        detail = nil
    }

    public var isPending: Bool { state == .verifying }

    /// The requestID whose media work may still install, or nil when nothing is outstanding.
    public var armedRequestID: String? { isPending ? latest?.requestID : nil }
}
