import Foundation

public enum StudyTimerMode: String, Codable, CaseIterable {
    case countUp, countdown
}

public struct StudySession: Codable, Equatable, Identifiable {
    public let id: String
    public let startedAt: Date
    public let title: String
    public let mode: StudyTimerMode
    public let targetSeconds: Double
    public private(set) var elapsed: Double

    public init(id: String = UUID().uuidString, startedAt: Date, title: String,
                mode: StudyTimerMode, targetSeconds: Double, elapsed: Double = 0) {
        self.id = id
        self.startedAt = startedAt
        self.title = title
        self.mode = mode
        self.targetSeconds = targetSeconds
        self.elapsed = elapsed
    }

    public func measured(adding seconds: Double) -> Double {
        let total = elapsed + max(0, seconds)
        return mode == .countdown ? min(targetSeconds, total) : total
    }

    public mutating func accumulate(_ seconds: Double) { elapsed = measured(adding: seconds) }
    public var reachedTarget: Bool { mode == .countdown && elapsed >= targetSeconds }
}

public struct StudyRecord: Codable, Equatable, Identifiable {
    public let session: StudySession
    public let endedAt: Date
    public var id: String { session.id }

    public init(session: StudySession, endedAt: Date) {
        self.session = session
        self.endedAt = endedAt
    }
}

/// The active session is a confirmed checkpoint. Process downtime is never extrapolated.
public struct StudyTimerLedger: Codable, Equatable {
    public var version = 1
    public var mode: StudyTimerMode = .countUp
    public var countdownMinutes = 25
    public var title = ""
    public var active: StudySession?
    public var records: [StudyRecord] = []

    public init() { }

    public var isValid: Bool {
        func valid(_ session: StudySession) -> Bool {
            !session.id.isEmpty && session.elapsed.isFinite && session.elapsed >= 0
                && session.targetSeconds.isFinite && session.targetSeconds > 0
                && (session.mode != .countdown || session.elapsed <= session.targetSeconds)
        }
        return version == 1 && (1...240).contains(countdownMinutes)
            && active.map(valid) != false && records.allSatisfy { valid($0.session) }
            && Set(records.map(\.id)).count == records.count
            && !records.contains { $0.id == active?.id }
    }
}
