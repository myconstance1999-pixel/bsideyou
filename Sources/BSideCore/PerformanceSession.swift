// Transient ControlApp-owned intent. No media paths, wall clocks, or platform objects.
import Foundation

public enum PerformancePlaybackMode: String, Codable, Hashable {
    case watch
    case listen
}

public struct PerformanceSession: Codable, Hashable {
    public let id: String
    /// The explicit typed target (ADR-022): an official resolved catalog cell or one local file.
    /// Core never fabricates official values for a local target.
    public let target: PerformancePlaybackTarget
    public let mode: PerformancePlaybackMode
    /// Queue ownership remains in ControlApp. At natural EOF the Agent waits briefly for
    /// its next start/stop decision instead of briefly restoring daily video and ambient.
    public let continuesQueue: Bool
    public var paused: Bool

    public init(id: String = UUID().uuidString, target: PerformancePlaybackTarget,
                mode: PerformancePlaybackMode = .watch, paused: Bool = false, continuesQueue: Bool = false) {
        self.id = id
        self.target = target
        self.mode = mode
        self.continuesQueue = continuesQueue
        self.paused = paused
    }

    /// Existing official call shape. A local session uses the `target:` initializer above.
    public init(id: String = UUID().uuidString, variant: ResolvedPerformanceVariant,
                mode: PerformancePlaybackMode = .watch, paused: Bool = false, continuesQueue: Bool = false) {
        self.init(id: id, target: .catalog(variant), mode: mode, paused: paused, continuesQueue: continuesQueue)
    }

    /// Nil for a local-file target — there is no official variant to report. Callers that show
    /// official lighting/camera labels must therefore handle the local case explicitly instead
    /// of receiving a fabricated cell.
    public var variant: ResolvedPerformanceVariant? { target.officialVariant }

    public var localReference: LocalPerformanceReference? { target.localReference }

    private enum CodingKeys: String, CodingKey { case id, target, variant, mode, paused, continuesQueue }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        if values.contains(.target) {
            target = try values.decode(PerformancePlaybackTarget.self, forKey: .target)
        } else {
            // Legacy official-only payload: the session's `variant` was the whole target.
            target = .catalog(try values.decode(ResolvedPerformanceVariant.self, forKey: .variant))
        }
        // Missing mode preserves old audiovisual intent; an unknown mode must not choose for the user.
        mode = try values.contains(.mode) ? values.decode(PerformancePlaybackMode.self, forKey: .mode) : .watch
        continuesQueue = try values.contains(.continuesQueue) ? values.decode(Bool.self, forKey: .continuesQueue) : false
        paused = try values.decode(Bool.self, forKey: .paused)
    }

    /// New sessions always write the unambiguous typed target; the legacy `variant` key is only
    /// ever read, never produced.
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(target, forKey: .target)
        try values.encode(mode, forKey: .mode)
        try values.encode(continuesQueue, forKey: .continuesQueue)
        try values.encode(paused, forKey: .paused)
    }
}

public struct PerformanceReport: Codable, Hashable {
    public enum State: String, Codable { case loading, playing, paused, ended, stopped, failed }
    public let sessionID: String
    public let state: State
    public let detail: String?
    public init(sessionID: String, state: State, detail: String? = nil) {
        self.sessionID = sessionID
        self.state = state
        self.detail = detail
    }
    public var isTerminal: Bool { state == .ended || state == .stopped || state == .failed }
}

/// ControlApp accepts only the active identity; supervisor separately gates Agent generation.
public struct PerformanceSessionState {
    public private(set) var session: PerformanceSession?
    public init() {}
    public mutating func start(_ session: PerformanceSession) { self.session = session }
    @discardableResult public mutating func pause(_ paused: Bool, sessionID: String) -> Bool {
        guard session?.id == sessionID else { return false }
        session?.paused = paused
        return true
    }
    @discardableResult public mutating func accept(_ report: PerformanceReport) -> Bool {
        guard session?.id == report.sessionID else { return false }
        if report.isTerminal { session = nil }
        return true
    }
    public mutating func agentLost() { session = nil }
}
