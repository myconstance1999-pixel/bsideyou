// BSideCore — PlaybackHistory: pure confirmed-interval ledger. NOT the "陪伴历史" product feature.
//
// This type records only closed, positively confirmed playback spans that an owner already
// verified. It never observes AVFoundation, IPC messages, runtimeSnapshot/performance status, or
// wall-clock passage: a status message with rate>0/ready is not a confirmed span and cannot create
// a record through this API. There is no open/growing interval — duration is always monoEnd-monoStart
// of a finite same-session span, and checkpointing cannot extend it.
//
// Channels are independent: visual, music, ambient each keep their own sequence stream and may
// overlap in monotonic time. Within one session+channel, spans must be strictly non-overlapping
// even across a playback-generation switch; duplicate/out-of-order sequences and stale
// epoch/session/generation submissions are rejected. Capture contexts are transient: a restart
// never resumes an old active context, disable/clear invalidate every context, and disabling
// advances the recording epoch so no pre-switch submission can become current again.
//
// Every span carries a per-span UTC anchor so durations use monotonic elapsed time while
// positioning uses UTC. Backwards wall-clock corrections therefore produce overlapping UTC without
// erasing distinct real monotonic time. Beijing-day totals split with the Asia/Shanghai calendar
// and conserve monotonic duration internally. Retention crop trims/drops by explicit UTC cutoff
// but preserves receiver sequence *and* monotonic-end watermarks, so a trimmed span cannot replay
// and a later higher sequence cannot reuse cropped time.

import Foundation

/// Independent recording channels. No union/summary default is implied here.
public enum PlaybackChannel: String, Codable, CaseIterable, Hashable {
    case visual
    case music
    case ambient
}

/// A closed, positively confirmed span. `duration` is always `monotonicEnd - monotonicStart`;
/// `utcEnd` exists only as a derived position for display/splitting, never as stored duration.
public struct PlaybackInterval: Codable, Equatable, Hashable {
    public let epoch: Int
    public let session: String
    public let generation: Int
    public let channel: PlaybackChannel
    public let sequence: Int
    public let monotonicStart: TimeInterval
    public let monotonicEnd: TimeInterval
    public let utcStart: Date

    public init(
        epoch: Int, session: String, generation: Int, channel: PlaybackChannel, sequence: Int,
        monotonicStart: TimeInterval, monotonicEnd: TimeInterval, utcStart: Date
    ) {
        self.epoch = epoch
        self.session = session
        self.generation = generation
        self.channel = channel
        self.sequence = sequence
        self.monotonicStart = monotonicStart
        self.monotonicEnd = monotonicEnd
        self.utcStart = utcStart
    }

    private enum CodingKeys: String, CodingKey {
        case epoch, session, generation, channel, sequence, monotonicStart, monotonicEnd, utcStart
    }

    /// Persisted records are re-validated on decode with the same rule ingest uses, so a corrupt
    /// file throws instead of surfacing a negative or non-finite duration.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let epoch = try container.decode(Int.self, forKey: .epoch)
        let session = try container.decode(String.self, forKey: .session)
        let generation = try container.decode(Int.self, forKey: .generation)
        let channel = try container.decode(PlaybackChannel.self, forKey: .channel)
        let sequence = try container.decode(Int.self, forKey: .sequence)
        let monotonicStart = try container.decode(TimeInterval.self, forKey: .monotonicStart)
        let monotonicEnd = try container.decode(TimeInterval.self, forKey: .monotonicEnd)
        let utcStart = try container.decode(Date.self, forKey: .utcStart)
        guard Self.isValidConfirmedSpan(
            monotonicStart: monotonicStart, monotonicEnd: monotonicEnd, utcStart: utcStart)
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .monotonicEnd, in: container,
                debugDescription: "persisted interval is not a valid confirmed span")
        }
        self.epoch = epoch
        self.session = session
        self.generation = generation
        self.channel = channel
        self.sequence = sequence
        self.monotonicStart = monotonicStart
        self.monotonicEnd = monotonicEnd
        self.utcStart = utcStart
    }

    /// The single confirmation rule shared by ingest and persisted decode: finite positively-ordered
    /// monotonic endpoints, a finite duration, and a finite representable UTC anchor and derived
    /// end. No fallback date is ever substituted for an unusable one.
    static func isValidConfirmedSpan(
        monotonicStart: TimeInterval, monotonicEnd: TimeInterval, utcStart: Date
    ) -> Bool {
        guard monotonicStart.isFinite, monotonicEnd.isFinite, monotonicEnd > monotonicStart else {
            return false
        }
        let duration = monotonicEnd - monotonicStart
        guard duration.isFinite, utcStart.timeIntervalSince1970.isFinite else { return false }
        return utcStart.addingTimeInterval(duration).timeIntervalSince1970.isFinite
    }

    public var duration: TimeInterval { monotonicEnd - monotonicStart }

    public var utcEnd: Date { utcStart.addingTimeInterval(duration) }

    /// UTC position of a monotonic offset inside this span's own anchor mapping.
    public func utc(forMonotonic value: TimeInterval) -> Date {
        utcStart.addingTimeInterval(value - monotonicStart)
    }
}

/// An owner-confirmed span offered to the ledger. `epoch` must be the current recording epoch.
public struct PlaybackIntervalSubmission: Codable, Hashable {
    public let epoch: Int
    public let session: String
    public let generation: Int
    public let channel: PlaybackChannel
    public let sequence: Int
    public let monotonicStart: TimeInterval
    public let monotonicEnd: TimeInterval
    public let utcStart: Date

    public init(
        epoch: Int, session: String, generation: Int, channel: PlaybackChannel, sequence: Int,
        monotonicStart: TimeInterval, monotonicEnd: TimeInterval, utcStart: Date
    ) {
        self.epoch = epoch
        self.session = session
        self.generation = generation
        self.channel = channel
        self.sequence = sequence
        self.monotonicStart = monotonicStart
        self.monotonicEnd = monotonicEnd
        self.utcStart = utcStart
    }
}

/// An owner-selected, currently-capturing context. Transient by construction: never persisted.
public struct PlaybackCaptureContext: Equatable {
    public let channel: PlaybackChannel
    public let epoch: Int
    public let session: String
    public let generation: Int

    public init(channel: PlaybackChannel, epoch: Int, session: String, generation: Int) {
        self.channel = channel
        self.epoch = epoch
        self.session = session
        self.generation = generation
    }
}

/// Highest accepted sequence and its monotonic end per session+channel. Persisted so retention
/// crop cannot let a trimmed event replay, and so a later higher-sequence span is checked against
/// the real chronological end rather than only the sequence number.
public struct PlaybackSequenceWatermark: Codable, Equatable {
    public let session: String
    public let channel: PlaybackChannel
    public let sequence: Int
    public let monotonicEnd: TimeInterval

    public init(session: String, channel: PlaybackChannel, sequence: Int, monotonicEnd: TimeInterval) {
        self.session = session
        self.channel = channel
        self.sequence = sequence
        self.monotonicEnd = monotonicEnd
    }
}

public enum PlaybackHistoryRejection: Equatable {
    case recordingOff
    case staleEpoch
    case missingCaptureContext
    case staleContext
    case outOfOrderSequence
    case overlappingSpan
    case invalidSpan
}

public enum PlaybackHistorySubmissionResult: Equatable {
    case accepted
    /// Same identity and identical span already recorded; no state change.
    case duplicate
    case rejected(PlaybackHistoryRejection)
}

/// One Beijing-day slice of confirmed duration (keyed by the UTC instant of 00:00 Asia/Shanghai).
public struct PlaybackDayDuration: Equatable {
    public let dayStart: Date
    public let channel: PlaybackChannel
    public let duration: TimeInterval

    public init(dayStart: Date, channel: PlaybackChannel, duration: TimeInterval) {
        self.dayStart = dayStart
        self.channel = channel
        self.duration = duration
    }
}

/// Versioned, Codable confirmed-interval ledger. Active capture contexts are intentionally not
/// encoded: a decoded ledger starts with no active context and cannot resume an old tail.
public struct PlaybackHistoryLedger: Codable, Equatable {
    public static let currentVersion = 1

    public private(set) var version: Int
    public private(set) var epoch: Int
    public private(set) var isRecording: Bool
    public private(set) var intervals: [PlaybackInterval]
    public private(set) var watermarks: [PlaybackSequenceWatermark]
    public private(set) var contexts: [PlaybackCaptureContext]

    private enum CodingKeys: String, CodingKey {
        case version, epoch, isRecording, intervals, watermarks
    }

    /// Empty ledger, recording disabled. This is the only default state.
    public init() {
        version = Self.currentVersion
        epoch = 0
        isRecording = false
        intervals = []
        watermarks = []
        contexts = []
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == Self.currentVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .version, in: container,
                debugDescription: "unsupported PlaybackHistoryLedger version \(version)")
        }
        self.version = version
        self.epoch = try container.decode(Int.self, forKey: .epoch)
        self.isRecording = try container.decode(Bool.self, forKey: .isRecording)
        self.intervals = try container.decode([PlaybackInterval].self, forKey: .intervals)
        self.watermarks = try container.decode([PlaybackSequenceWatermark].self, forKey: .watermarks)
        // Capture contexts are transient: restart must never accept a persisted active context.
        self.contexts = []
        try validatePersistedInvariants(in: container)
    }

    /// Decode-time check for persisted numeric/watermark invariants that ingest cannot violate.
    /// Deliberately small: one span rule (already enforced by `PlaybackInterval`) plus epoch
    /// non-negativity and the per-key watermark that must cover every recorded interval. Corrupt
    /// data throws; nothing is rewritten.
    private func validatePersistedInvariants(
        in container: KeyedDecodingContainer<CodingKeys>
    ) throws {
        guard epoch >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .epoch, in: container, debugDescription: "negative recording epoch")
        }
        for watermark in watermarks where !watermark.monotonicEnd.isFinite {
            throw DecodingError.dataCorruptedError(
                forKey: .watermarks, in: container,
                debugDescription: "non-finite sequence watermark")
        }
        let allCovered = intervals.allSatisfy { interval in
            watermarks.contains {
                $0.session == interval.session && $0.channel == interval.channel
                    && interval.sequence <= $0.sequence && interval.monotonicEnd <= $0.monotonicEnd
            }
        }
        guard allCovered else {
            throw DecodingError.dataCorruptedError(
                forKey: .watermarks, in: container,
                debugDescription: "watermark does not cover its recorded intervals")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(epoch, forKey: .epoch)
        try container.encode(isRecording, forKey: .isRecording)
        try container.encode(intervals, forKey: .intervals)
        try container.encode(watermarks, forKey: .watermarks)
    }

    // MARK: - Owner capture control

    /// Toggle recording. Both directions invalidate every active context, and disabling advances the
    /// recording epoch: any submission bound before the switch is permanently stale, so a late or
    /// still-in-flight event cannot be made current by re-enabling and rebinding the same
    /// session/generation. Confirmed records and watermarks survive the switch.
    @discardableResult
    public mutating func setRecording(_ enabled: Bool) -> Bool {
        guard enabled != isRecording else { return false }
        isRecording = enabled
        contexts = []
        if !enabled { epoch += 1 }
        return true
    }

    /// Bind (or replace) the current capture context for one channel, bound to the current epoch.
    @discardableResult
    public mutating func beginCapture(channel: PlaybackChannel, session: String, generation: Int) -> Bool {
        guard isRecording else { return false }
        contexts.removeAll { $0.channel == channel }
        contexts.append(PlaybackCaptureContext(
            channel: channel, epoch: epoch, session: session, generation: generation))
        return true
    }

    /// Atomically start a new epoch with an empty record set. Watermarks and contexts reset; old
    /// epoch submissions are rejected forever, so a restart cannot resurrect cleared records.
    @discardableResult
    public mutating func clear() -> Bool {
        epoch += 1
        intervals = []
        watermarks = []
        contexts = []
        return true
    }

    // MARK: - Confirmed submissions

    public mutating func submit(
        _ submission: PlaybackIntervalSubmission
    ) -> PlaybackHistorySubmissionResult {
        guard isRecording else { return .rejected(.recordingOff) }
        guard submission.epoch == epoch else { return .rejected(.staleEpoch) }
        guard PlaybackInterval.isValidConfirmedSpan(
            monotonicStart: submission.monotonicStart, monotonicEnd: submission.monotonicEnd,
            utcStart: submission.utcStart) else {
            return .rejected(.invalidSpan)
        }
        guard let context = contexts.first(where: { $0.channel == submission.channel }) else {
            return .rejected(.missingCaptureContext)
        }
        guard context.session == submission.session, context.generation == submission.generation else {
            return .rejected(.staleContext)
        }

        if let existing = intervals.first(where: {
            $0.session == submission.session && $0.channel == submission.channel
                && $0.sequence == submission.sequence
        }) {
            if existing.generation == submission.generation,
               existing.monotonicStart == submission.monotonicStart,
               existing.monotonicEnd == submission.monotonicEnd,
               existing.utcStart == submission.utcStart {
                return .duplicate
            }
            return .rejected(.outOfOrderSequence)
        }
        if let watermark = watermarks.first(where: {
            $0.session == submission.session && $0.channel == submission.channel
        }) {
            if submission.sequence <= watermark.sequence { return .rejected(.outOfOrderSequence) }
            // Chronological non-overlap must survive crop and generation switches, so the persisted
            // monotonic end is checked, not only the currently surviving interval list.
            if submission.monotonicStart < watermark.monotonicEnd {
                return .rejected(.overlappingSpan)
            }
        }

        // Same session+channel never overlaps, regardless of generation switch.
        let overlaps = intervals.contains { existing in
            existing.session == submission.session && existing.channel == submission.channel
                && submission.monotonicStart < existing.monotonicEnd
                && existing.monotonicStart < submission.monotonicEnd
        }
        if overlaps { return .rejected(.overlappingSpan) }

        intervals.append(PlaybackInterval(
            epoch: epoch, session: submission.session, generation: submission.generation,
            channel: submission.channel, sequence: submission.sequence,
            monotonicStart: submission.monotonicStart, monotonicEnd: submission.monotonicEnd,
            utcStart: submission.utcStart))
        if let index = watermarks.firstIndex(where: {
            $0.session == submission.session && $0.channel == submission.channel
        }) {
            watermarks[index] = PlaybackSequenceWatermark(
                session: submission.session, channel: submission.channel,
                sequence: submission.sequence, monotonicEnd: submission.monotonicEnd)
        } else {
            watermarks.append(PlaybackSequenceWatermark(
                session: submission.session, channel: submission.channel,
                sequence: submission.sequence, monotonicEnd: submission.monotonicEnd))
        }
        return .accepted
    }

    // MARK: - Retention

    /// Drop spans ending at/before `cutoff` and trim the pre-cutoff prefix of a crossing span,
    /// preserving monotonic duration conservation. Receiver watermarks are never touched, so a
    /// dropped or trimmed event with an old sequence cannot replay.
    @discardableResult
    public mutating func crop(retainingAfter cutoff: Date) -> Bool {
        var changed = false
        var kept: [PlaybackInterval] = []
        for interval in intervals {
            if interval.utcEnd <= cutoff {
                changed = true
                continue
            }
            if interval.utcStart < cutoff {
                let trimmedStart = interval.monotonicStart + cutoff.timeIntervalSince(interval.utcStart)
                if trimmedStart >= interval.monotonicEnd {
                    changed = true
                    continue
                }
                kept.append(PlaybackInterval(
                    epoch: interval.epoch, session: interval.session, generation: interval.generation,
                    channel: interval.channel, sequence: interval.sequence,
                    monotonicStart: trimmedStart, monotonicEnd: interval.monotonicEnd,
                    utcStart: cutoff))
                changed = true
            } else {
                kept.append(interval)
            }
        }
        intervals = kept
        return changed
    }

    // MARK: - Queries (confirmed data only)

    /// Independent per-channel confirmed duration. There is deliberately no combined "total":
    /// channels may overlap in time, so any single sum would double-count and is not an approved
    /// aggregate metric. Callers that need a figure sum the explicit channel results themselves.
    public func duration(for channel: PlaybackChannel) -> TimeInterval {
        intervals.filter { $0.channel == channel }.reduce(0) { $0 + $1.duration }
    }

    /// Split every confirmed span at Beijing (Asia/Shanghai) midnights. Each span is mapped through
    /// its own UTC anchor, so monotonic duration is conserved and a backwards wall correction is
    /// not deduplicated or erased.
    public func beijingDayDurations() -> [PlaybackDayDuration] {
        var result: [PlaybackDayDuration] = []
        for interval in intervals {
            let end = interval.utcEnd
            var cursor = interval.utcStart
            while cursor < end {
                let dayStart = PlaybackHistoryCalendar.beijing.startOfDay(for: cursor)
                let nextMidnight = PlaybackHistoryCalendar.beijing.date(
                    byAdding: .day, value: 1, to: dayStart) ?? end
                let segmentEnd = min(nextMidnight, end)
                result.append(PlaybackDayDuration(
                    dayStart: dayStart, channel: interval.channel,
                    duration: segmentEnd.timeIntervalSince(cursor)))
                cursor = segmentEnd
            }
        }
        return result
    }
}

enum PlaybackHistoryCalendar {
    /// Asia/Shanghai has no DST; this is the fixed Beijing day-line used for day attribution.
    static let beijing: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? TimeZone(secondsFromGMT: 8 * 3600)!
        return calendar
    }()
}
