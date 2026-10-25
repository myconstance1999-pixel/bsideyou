// BSideCore — PlaybackProgress: pure, event-driven classification of real media-clock samples
// into confirmed PlaybackIntervalSubmission spans. NOT a timer and NOT a state poller.
//
// The observer that owns AVFoundation feeds one observation per callback (or per invalidation
// event). This reducer decides whether two compatible observations are a real, positively
// advancing media span:
//
//  * Only active observations (`isActive`) may extend an anchor. Pause, mute/trackless music,
//    a retained still, waiting/loading, seek, a current-item/generation change and policy
//    suppression all arrive as inactive and close the anchor without inventing a tail.
//  * Two active observations extend only when the item/generation is identical, media time and
//    monotonic time both move forward, the callback gap is bounded, and the media delta agrees
//    with the monotonic delta within a conservative slack. A long gap or disagreement (sleep,
//    lock, stalled callback) breaks the anchor rather than fabricating elapsed time.
//  * Each confirmed segment is rotated out immediately and reported as its own submission. The
//    stored interval is the MONOTONIC interval [m0, m1) of the compatible samples, not a
//    backdated `min(P, M)` slice: media delta P must agree with monotonic delta M within the
//    sampling tolerance at unchanged rate 1, and then M is counted. A disagreement beyond the
//    tolerance is a stall/seek/sleep discontinuity and the whole segment is dropped and re-anchored
//    rather than truncated in an unknown location.
//
// Wall-clock time is used only as an independent per-segment UTC anchor; duration always comes
// from monotonic elapsed time. A wall-clock correction therefore starts a new mapping.

import Foundation

/// One media-clock observation for one channel. `isActive` is the observer's verdict that the
/// media is currently playing and eligible for this channel (audible + audio track for music,
/// actual displayed video for visual, decoded audibility for ambient).
public struct PlaybackProgressObservation: Equatable {
    public let channel: PlaybackChannel
    public let generation: Int
    public let item: Int
    public let mediaTime: TimeInterval
    public let monotonicTime: TimeInterval
    public let utc: Date
    public let isActive: Bool

    public init(
        channel: PlaybackChannel, generation: Int, item: Int, mediaTime: TimeInterval,
        monotonicTime: TimeInterval, utc: Date, isActive: Bool
    ) {
        self.channel = channel
        self.generation = generation
        self.item = item
        self.mediaTime = mediaTime
        self.monotonicTime = monotonicTime
        self.utc = utc
        self.isActive = isActive
    }
}

/// Pure accumulator. One instance per recording token (epoch + session). `closeAll()` is used at
/// a state boundary; it only emits spans whose two endpoints were already positively confirmed.
public struct PlaybackProgressTracker {
    /// A callback gap above this is a discontinuity (sleep/lock/stall), never elapsed playback.
    public static let maxCallbackGap: TimeInterval = 5
    /// Media and monotonic deltas may differ by at most this sampling-error bound. Larger
    /// disagreement is a material discontinuity (stall/seek/lock), not a duration to truncate.
    public static let samplingTolerance: TimeInterval = 0.35
    /// A confirmed segment must be at least this long; shorter noise is never stored.
    public static let minConfirmedDuration: TimeInterval = 0.25

    public let epoch: Int
    public let session: String

    private struct Anchor {
        let channel: PlaybackChannel
        let generation: Int
        let item: Int
        var mediaStart: TimeInterval
        var mediaEnd: TimeInterval
        var monotonicStart: TimeInterval
        var monotonicEnd: TimeInterval
        let utcStart: Date
        var utcEnd: Date
    }

    private var anchors: [PlaybackChannel: Anchor] = [:]
    private var sequences: [PlaybackChannel: Int] = [:]

    public init(epoch: Int, session: String) {
        self.epoch = epoch
        self.session = session
    }

    /// Ingest one observation. Returns a confirmed submission when a segment just closed.
    @discardableResult
    public mutating func ingest(_ observation: PlaybackProgressObservation) -> PlaybackIntervalSubmission? {
        guard observation.isActive, observation.mediaTime.isFinite,
              observation.monotonicTime.isFinite, observation.utc.timeIntervalSince1970.isFinite else {
            return close(channel: observation.channel)
        }
        guard var anchor = anchors[observation.channel] else {
            start(observation)
            return nil
        }
        guard anchor.generation == observation.generation, anchor.item == observation.item else {
            let closed = close(channel: observation.channel)
            start(observation)
            return closed
        }
        let mediaDelta = observation.mediaTime - anchor.mediaEnd
        let monotonicDelta = observation.monotonicTime - anchor.monotonicEnd
        // Unknown/backwards media or monotonic time, a long callback gap, or clocks that disagree
        // beyond the slack: break and re-baseline; never synthesize the missing duration.
        guard mediaDelta > 0, monotonicDelta > 0,
              monotonicDelta <= Self.maxCallbackGap,
              mediaDelta <= Self.maxCallbackGap,
              abs(mediaDelta - monotonicDelta) <= Self.samplingTolerance else {
            let closed = close(channel: observation.channel)
            start(observation)
            return closed
        }
        // Independent UTC anchor: the wall clock must advance with the monotonic clock by the same
        // amount. A discontinuity (wall-clock correction, or sleeping where uptime pauses but UTC
        // advances) discards the crossing candidate outright and re-anchors; UTC is never used to
        // time a span.
        let utcDelta = observation.utc.timeIntervalSince(anchor.utcEnd)
        guard utcDelta.isFinite, abs(utcDelta - monotonicDelta) <= Self.samplingTolerance else {
            discard(channel: observation.channel)
            start(observation)
            return nil
        }
        anchor.mediaEnd = observation.mediaTime
        anchor.monotonicEnd = observation.monotonicTime
        anchor.utcEnd = observation.utc
        anchors[observation.channel] = anchor
        guard let submission = emit(anchor) else { return nil }
        // Rotate: continue from this sample under a fresh anchor so the next segment cannot
        // overlap the confirmed one and a later late callback cannot extend it.
        start(observation)
        return submission
    }

    /// Close every open anchor at a state boundary / disable / shutdown. A tail with no confirmed
    /// positive progression yields nothing, so this never fabricates a span.
    public mutating func closeAll() -> [PlaybackIntervalSubmission] {
        PlaybackChannel.allCases.compactMap { close(channel: $0) }
    }

    /// Close one channel immediately (pause, seek, item change, ineligibility).
    @discardableResult
    public mutating func invalidate(channel: PlaybackChannel) -> PlaybackIntervalSubmission? {
        close(channel: channel)
    }

    private mutating func start(_ observation: PlaybackProgressObservation) {
        anchors[observation.channel] = Anchor(
            channel: observation.channel, generation: observation.generation, item: observation.item,
            mediaStart: observation.mediaTime, mediaEnd: observation.mediaTime,
            monotonicStart: observation.monotonicTime, monotonicEnd: observation.monotonicTime,
            utcStart: observation.utc, utcEnd: observation.utc)
    }

    /// Drop an open anchor without emitting. Used for a wall-clock-jump crossing candidate: the
    /// segment straddles an unknown mapping and must never be confirmed.
    private mutating func discard(channel: PlaybackChannel) {
        anchors.removeValue(forKey: channel)
    }

    private mutating func close(channel: PlaybackChannel) -> PlaybackIntervalSubmission? {
        guard let anchor = anchors.removeValue(forKey: channel) else { return nil }
        return emit(anchor)
    }

    private mutating func emit(_ anchor: Anchor) -> PlaybackIntervalSubmission? {
        // The interval is the MONOTONIC span of continuously-compatible samples. Media time is
        // only the agreement witness (P ≈ M at rate 1); it is never backdated into a slice.
        let monotonicSpan = anchor.monotonicEnd - anchor.monotonicStart
        guard monotonicSpan >= Self.minConfirmedDuration else { return nil }
        let sequence = (sequences[anchor.channel] ?? 0) + 1
        sequences[anchor.channel] = sequence
        return PlaybackIntervalSubmission(
            epoch: epoch, session: session, generation: anchor.generation, channel: anchor.channel,
            sequence: sequence, monotonicStart: anchor.monotonicStart,
            monotonicEnd: anchor.monotonicEnd, utcStart: anchor.utcStart)
    }
}

/// Pure channel eligibility rules shared by the observer and its regressions. These decide only
/// whether an existing media clock may count; they never create a span on their own.
public enum PlaybackProgressEligibility {
    /// Music counts only with a real audio track AND an effectively nonzero output volume.
    /// A trackless daily video or a muted output can therefore never produce a music span.
    public static func music(audioTrackPresent: Bool, effectiveVolume: Double) -> Bool {
        audioTrackPresent && effectiveVolume.isFinite && effectiveVolume > 0
    }

    /// Ambient counts only while decoded audio is actually present with a positive volume.
    public static func ambient(hasTrack: Bool, effectiveVolume: Double) -> Bool {
        hasTrack && effectiveVolume.isFinite && effectiveVolume > 0
    }

    /// Visual counts only actual displayed video from media whose resources are still available.
    /// A retained still or released queue is not advancing media, and neither is an AVPlayer
    /// clock that keeps advancing while its accepted resources have disappeared: that frozen
    /// output is not displayed progress. A caller that knows the resources are gone must report
    /// `resourcesAvailable == false` so the anchor closes instead of accruing until recovery.
    public static func visual(hasVideoResources: Bool, systemSuppressed: Bool,
                              resourcesAvailable: Bool) -> Bool {
        hasVideoResources && !systemSuppressed && resourcesAvailable
    }
}
