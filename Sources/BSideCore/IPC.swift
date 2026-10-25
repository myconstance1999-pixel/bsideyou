// BSideCore — IPC protocol: versioned newline-delimited JSON envelopes (ADR-007).
// Transport-independent: both sides speak Envelope<Payload>; the agent pipes transport lives
// in the executables. stderr never carries protocol data.

import Foundation

public enum IPC {
    /// Bump on incompatible wire or command semantics; ControlApp refuses mismatched versions.
    public static let protocolVersion = 17
}

public struct IPCEnvelope<Payload: Codable>: Codable {
    public var protocolVersion: Int
    public var messageID: String
    /// Seconds since Unix epoch (avoids Date encoding-strategy coupling).
    public var sentAt: Double
    public var payload: Payload

    public init(messageID: String = UUID().uuidString, sentAt: Double = Date().timeIntervalSince1970, payload: Payload) {
        self.protocolVersion = IPC.protocolVersion
        self.messageID = messageID
        self.sentAt = sentAt
        self.payload = payload
    }
}

/// ControlApp → Agent. Wire format: `{"<case>": payload-or-empty}` (explicit Codable —
/// avoids Swift's synthesized `{"case": {"_0": …}}` wrapper).
public enum AgentCommand: Hashable {
    /// Boot with the official asset folder (provider validates; unknown layout → error event).
    case initialize(DirectoryAccessRequest)
    /// Full persistent wallpaper intent replay; transient performances end on Agent loss.
    case setDesiredState(DesiredState)
    /// Preview-only desktop controls. Replayed by ControlApp; no media/session mutation.
    case setDesktopWorkspace(DesktopWorkspacePresentation)
    /// Transient in-window frame stream; nil withdraws it. Never persisted.
    case setHomeCompanionStream(HomeCompanionStreamRequest)
    /// Buffer reuse is permitted only after the consumer has copied this exact frame.
    case acknowledgeHomeCompanionFrame(HomeCompanionFrameAcknowledgement)
    /// One-shot reviewed daily entry; never replayed after Agent loss.
    case startDailyActivity(DailyActivityRequest)
    case setHistoryRecording(HistoryRecordingRequest)
    /// Transport-only media root; the domain session itself contains no paths.
    case startPerformance(PerformanceStartRequest)
    case pausePerformance(PerformancePauseRequest)
    case stopPerformance(sessionID: String)
    /// One-shot presentation request for the current watch session; never starts/restarts media.
    case enterPerformanceFullScreen(sessionID: String)
    /// Hide the current performance picture; the daily desktop and song playback remain intact.
    case exitPerformanceFullScreen(sessionID: String)
    case reloadAssets
    /// Reconcile the current directory without interrupting its active daily unit.
    case refreshAssets(DirectoryAccessRequest)
    /// A previously accepted root cannot currently be authorized; do not read old paths.
    case invalidateDailyAssets(DailyAssetInvalidation)
    case healthCheck
    case shutdown
}

/// Agent → ControlApp. Same direct-payload wire format as AgentCommand.
public enum AgentEvent: Hashable {
    case desktopWorkspaceAction(DesktopWorkspaceAction)
    case homeCompanionFrame(HomeCompanionFrame)
    case dailyActivity(DailyActivityReport)
    case performance(PerformanceReport)
    case performancePresentation(PerformancePresentationReport)
    case ready(protocolVersion: Int)
    case runtimeSnapshot(RuntimeSnapshot)
    case historyIntervals([PlaybackIntervalSubmission])
    case playbackStarted(clipID: String)
    case playbackPaused
    case contentChanged(clipID: String)
    case degraded(reason: String)
    case error(code: String, message: String)
    case health(uptimeSeconds: Double)
}

extension AgentCommand: Codable {
    private enum Keys: String, CodingKey {
        case initialize, startDailyActivity, setDesiredState, setDesktopWorkspace, setHomeCompanionStream, acknowledgeHomeCompanionFrame, setHistoryRecording, startPerformance, pausePerformance, stopPerformance, enterPerformanceFullScreen, exitPerformanceFullScreen, reloadAssets, refreshAssets, invalidateDailyAssets, healthCheck, shutdown
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .startDailyActivity(let request): try c.encode(request, forKey: .startDailyActivity)
        case .initialize(let request): try c.encode(request, forKey: .initialize)
        case .setDesiredState(let state): try c.encode(state, forKey: .setDesiredState)
        case .setDesktopWorkspace(let presentation): try c.encode(presentation, forKey: .setDesktopWorkspace)
        case .setHomeCompanionStream(let request): try c.encode(request, forKey: .setHomeCompanionStream)
        case .acknowledgeHomeCompanionFrame(let acknowledgement): try c.encode(acknowledgement, forKey: .acknowledgeHomeCompanionFrame)
        case .setHistoryRecording(let request): try c.encode(request, forKey: .setHistoryRecording)
        case .startPerformance(let request): try c.encode(request, forKey: .startPerformance)
        case .pausePerformance(let request): try c.encode(request, forKey: .pausePerformance)
        case .stopPerformance(let id): try c.encode(id, forKey: .stopPerformance)
        case .enterPerformanceFullScreen(let id): try c.encode(id, forKey: .enterPerformanceFullScreen)
        case .exitPerformanceFullScreen(let id): try c.encode(id, forKey: .exitPerformanceFullScreen)
        case .reloadAssets: try c.encode(true, forKey: .reloadAssets)
        case .refreshAssets(let request): try c.encode(request, forKey: .refreshAssets)
        case .invalidateDailyAssets(let request): try c.encode(request, forKey: .invalidateDailyAssets)
        case .healthCheck: try c.encode(true, forKey: .healthCheck)
        case .shutdown: try c.encode(true, forKey: .shutdown)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        if c.contains(.startDailyActivity) { self = .startDailyActivity(try c.decode(DailyActivityRequest.self, forKey: .startDailyActivity)); return }
        if c.contains(.setHistoryRecording) { self = .setHistoryRecording(try c.decode(HistoryRecordingRequest.self, forKey: .setHistoryRecording)); return }
        if c.contains(.initialize) { self = .initialize(try c.decode(DirectoryAccessRequest.self, forKey: .initialize)); return }
        if let state = try? c.decode(DesiredState.self, forKey: .setDesiredState) { self = .setDesiredState(state); return }
        if c.contains(.setDesktopWorkspace) { self = .setDesktopWorkspace(try c.decode(DesktopWorkspacePresentation.self, forKey: .setDesktopWorkspace)); return }
        if c.contains(.setHomeCompanionStream) { self = .setHomeCompanionStream(try c.decode(HomeCompanionStreamRequest.self, forKey: .setHomeCompanionStream)); return }
        if c.contains(.acknowledgeHomeCompanionFrame) { self = .acknowledgeHomeCompanionFrame(try c.decode(HomeCompanionFrameAcknowledgement.self, forKey: .acknowledgeHomeCompanionFrame)); return }
        if c.contains(.startPerformance) { self = .startPerformance(try c.decode(PerformanceStartRequest.self, forKey: .startPerformance)); return }
        if c.contains(.pausePerformance) { self = .pausePerformance(try c.decode(PerformancePauseRequest.self, forKey: .pausePerformance)); return }
        if c.contains(.stopPerformance) { self = .stopPerformance(sessionID: try c.decode(String.self, forKey: .stopPerformance)); return }
        if c.contains(.enterPerformanceFullScreen) { self = .enterPerformanceFullScreen(sessionID: try c.decode(String.self, forKey: .enterPerformanceFullScreen)); return }
        if c.contains(.exitPerformanceFullScreen) { self = .exitPerformanceFullScreen(sessionID: try c.decode(String.self, forKey: .exitPerformanceFullScreen)); return }
        if c.contains(.refreshAssets) { self = .refreshAssets(try c.decode(DirectoryAccessRequest.self, forKey: .refreshAssets)); return }
        if c.contains(.invalidateDailyAssets) { self = .invalidateDailyAssets(try c.decode(DailyAssetInvalidation.self, forKey: .invalidateDailyAssets)); return }
        // Flag cases accept `true` or an empty object.
        if c.contains(.reloadAssets) { self = .reloadAssets; return }
        if c.contains(.healthCheck) { self = .healthCheck; return }
        if c.contains(.shutdown) { self = .shutdown; return }
        throw DecodingError.dataCorrupted(DecodingError.Context(
            codingPath: decoder.codingPath, debugDescription: "unknown AgentCommand payload"))
    }
}

extension AgentEvent: Codable {
    private enum Keys: String, CodingKey {
        case desktopWorkspaceAction, homeCompanionFrame, dailyActivity, performance, performancePresentation, ready, runtimeSnapshot, historyIntervals, playbackStarted, playbackPaused, contentChanged, degraded, error, health
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .desktopWorkspaceAction(let action): try c.encode(action, forKey: .desktopWorkspaceAction)
        case .homeCompanionFrame(let frame): try c.encode(frame, forKey: .homeCompanionFrame)
        case .dailyActivity(let report): try c.encode(report, forKey: .dailyActivity)
        case .performance(let report): try c.encode(report, forKey: .performance)
        case .performancePresentation(let report): try c.encode(report, forKey: .performancePresentation)
        case .ready(let version): try c.encode(version, forKey: .ready)
        case .runtimeSnapshot(let snapshot): try c.encode(snapshot, forKey: .runtimeSnapshot)
        case .historyIntervals(let intervals): try c.encode(intervals, forKey: .historyIntervals)
        case .playbackStarted(let clip): try c.encode(clip, forKey: .playbackStarted)
        case .playbackPaused: try c.encode(true, forKey: .playbackPaused)
        case .contentChanged(let clip): try c.encode(clip, forKey: .contentChanged)
        case .degraded(let reason): try c.encode(reason, forKey: .degraded)
        case .error(let code, let message):
            var nested = c.nestedContainer(keyedBy: ErrorKeys.self, forKey: .error)
            try nested.encode(code, forKey: .code)
            try nested.encode(message, forKey: .message)
        case .health(let uptime): try c.encode(uptime, forKey: .health)
        }
    }

    private struct ErrorKeys: CodingKey {
        let stringValue: String
        let intValue: Int?
        init?(stringValue: String) { self.stringValue = stringValue; self.intValue = nil }
        init?(intValue: Int) { self.stringValue = "\(intValue)"; self.intValue = intValue }
        static let code = ErrorKeys(stringValue: "code")!
        static let message = ErrorKeys(stringValue: "message")!
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        if c.contains(.desktopWorkspaceAction) { self = .desktopWorkspaceAction(try c.decode(DesktopWorkspaceAction.self, forKey: .desktopWorkspaceAction)); return }
        if c.contains(.homeCompanionFrame) { self = .homeCompanionFrame(try c.decode(HomeCompanionFrame.self, forKey: .homeCompanionFrame)); return }
        if c.contains(.dailyActivity) { self = .dailyActivity(try c.decode(DailyActivityReport.self, forKey: .dailyActivity)); return }
        if c.contains(.historyIntervals) { self = .historyIntervals(try c.decode([PlaybackIntervalSubmission].self, forKey: .historyIntervals)); return }
        if c.contains(.performance) { self = .performance(try c.decode(PerformanceReport.self, forKey: .performance)); return }
        if c.contains(.performancePresentation) { self = .performancePresentation(try c.decode(PerformancePresentationReport.self, forKey: .performancePresentation)); return }
        if let version = try? c.decode(Int.self, forKey: .ready) { self = .ready(protocolVersion: version); return }
        if let snapshot = try? c.decode(RuntimeSnapshot.self, forKey: .runtimeSnapshot) { self = .runtimeSnapshot(snapshot); return }
        if let clip = try? c.decode(String.self, forKey: .playbackStarted) { self = .playbackStarted(clipID: clip); return }
        if try c.decodeIfPresent(Bool.self, forKey: .playbackPaused) != nil { self = .playbackPaused; return }
        if let clip = try? c.decode(String.self, forKey: .contentChanged) { self = .contentChanged(clipID: clip); return }
        if let reason = try? c.decode(String.self, forKey: .degraded) { self = .degraded(reason: reason); return }
        if let nested = try? c.nestedContainer(keyedBy: ErrorKeys.self, forKey: .error),
           let code = try? nested.decode(String.self, forKey: .code),
           let message = try? nested.decode(String.self, forKey: .message) {
            self = .error(code: code, message: message); return
        }
        if let uptime = try? c.decode(Double.self, forKey: .health) { self = .health(uptimeSeconds: uptime); return }
        throw DecodingError.dataCorrupted(DecodingError.Context(
            codingPath: decoder.codingPath, debugDescription: "unknown AgentEvent payload"))
    }
}

public enum IPCCoding {
    /// Encode an envelope as ONE protocol line (no trailing newline added).
    public static func encodeLine<Payload: Codable>(_ envelope: IPCEnvelope<Payload>) -> String? {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(envelope) else { return nil }
        guard let line = String(data: data, encoding: .utf8) else { return nil }
        // Belt & suspenders: a raw newline inside the payload would desync line framing.
        return line.contains("\n") ? nil : line
    }

    /// Decode one protocol line. Returns nil for anything malformed or version-mismatched
    /// (callers must skip-and-log, never crash — forward compatibility).
    public static func decodeLine<Payload: Codable>(_ line: String, as payloadType: Payload.Type) -> IPCEnvelope<Payload>? {
        guard let data = line.data(using: .utf8) else { return nil }
        guard let envelope = try? JSONDecoder().decode(IPCEnvelope<Payload>.self, from: data) else { return nil }
        guard envelope.protocolVersion == IPC.protocolVersion else { return nil }
        return envelope
    }
}

/// Ephemeral transport capability. Pixels never enter JSON; the ControlApp creates a
/// private bounded buffer, and Platform validates its ownership, type and exact size.
public struct HomeCompanionStreamRequest: Codable, Hashable {
    public struct Stream: Codable, Hashable {
        public let id: String
        public let bufferPath: String
        public let capacity: Int
        public let maxWidth: Int
        public let maxHeight: Int

        public init(id: String, bufferPath: String, capacity: Int, maxWidth: Int, maxHeight: Int) {
            self.id = id; self.bufferPath = bufferPath; self.capacity = capacity
            self.maxWidth = maxWidth; self.maxHeight = maxHeight
        }
    }

    public let stream: Stream?
    public init(stream: Stream? = nil) { self.stream = stream }
}

/// One outstanding packed BGRA frame. Sequence is monotonic within a fresh stream ID.
/// The receiver validates all dimensions and copies immutable pixels before acknowledgement.
public struct HomeCompanionFrame: Codable, Hashable {
    public let streamID: String
    public let sequence: UInt64
    public let contentID: String
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int

    public init(streamID: String, sequence: UInt64, contentID: String,
                width: Int, height: Int, bytesPerRow: Int) {
        self.streamID = streamID; self.sequence = sequence; self.contentID = contentID
        self.width = width; self.height = height; self.bytesPerRow = bytesPerRow
    }
}

public struct HomeCompanionFrameAcknowledgement: Codable, Hashable {
    public let streamID: String
    public let sequence: UInt64
    public init(streamID: String, sequence: UInt64) {
        self.streamID = streamID; self.sequence = sequence
    }
}

public struct DailyAssetInvalidation: Codable, Hashable {
    public let issue: DailyAssetIssue
    public let refreshID: String
    public init(issue: DailyAssetIssue, refreshID: String) {
        self.issue = issue; self.refreshID = refreshID
    }
}

public struct DirectoryAccessRequest: Codable, Hashable {
    public let path: String
    /// Ephemeral cross-process grant, never the ControlApp's persistent app-scoped bookmark.
    /// Nil supports explicit non-sandbox command-line fixtures; it grants no file access.
    public let bookmark: Data?
    /// Correlates a background refresh with the snapshot that accepted its result.
    public let refreshID: String?
    public init(path: String, bookmark: Data? = nil, refreshID: String? = nil) {
        self.path = path; self.bookmark = bookmark; self.refreshID = refreshID
    }
}

extension AgentCommand {
    public static func initialize(assetPath: String) -> Self {
        .initialize(DirectoryAccessRequest(path: assetPath))
    }
}

/// Transport binding for one explicitly selected local file. The Agent independently checks
/// containment and content identity under the transferred directory lease before playback.
public struct PerformanceFileBinding: Codable, Hashable {
    public let relativePath: String
    public let byteSize: Int64
    public let sha256: String

    public init(relativePath: String, byteSize: Int64, sha256: String) {
        self.relativePath = relativePath
        self.byteSize = byteSize
        self.sha256 = sha256
    }
}

public struct PerformanceStartRequest: Codable, Hashable {
    /// Unified UI starts pass false; absent legacy requests retain automatic-entry semantics.
    public let automaticallyEnterFullScreen: Bool?
    public let session: PerformanceSession
    public let mediaRoot: String
    public let accessBookmark: Data?
    public let fileBinding: PerformanceFileBinding?
    public init(session: PerformanceSession, mediaRoot: String, accessBookmark: Data? = nil,
                fileBinding: PerformanceFileBinding? = nil, automaticallyEnterFullScreen: Bool = true) {
        self.automaticallyEnterFullScreen = automaticallyEnterFullScreen
        self.session = session
        self.mediaRoot = mediaRoot
        self.accessBookmark = accessBookmark
        self.fileBinding = fileBinding
    }
}
public struct PerformancePauseRequest: Codable, Hashable {
    public let sessionID: String
    public let paused: Bool
    public init(sessionID: String, paused: Bool) { self.sessionID = sessionID; self.paused = paused }
}

/// Transient picture state from the Agent's native window callbacks. Never persisted.
public enum PerformancePictureState: String, Codable, Hashable {
    case collapsed, expanding, expanded, collapsing
}

public struct PerformancePresentationReport: Codable, Hashable {
    public let sessionID: String
    public let state: PerformancePictureState
    public init(sessionID: String, state: PerformancePictureState) {
        self.sessionID = sessionID
        self.state = state
    }
}
