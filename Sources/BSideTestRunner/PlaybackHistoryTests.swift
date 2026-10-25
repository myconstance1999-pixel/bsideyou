// BSideTestRunner — confirmed interval ledger regressions (Core only, no collector/telemetry).

import Foundation
import BSideCore

private func historyDate(_ value: String) -> Date {
    ISO8601DateFormatter().date(from: value)!
}

private func historySubmission(
    epoch: Int, session: String = "session-a", generation: Int = 1,
    channel: PlaybackChannel, sequence: Int, mono: ClosedRange<Double>, utc: Date
) -> PlaybackIntervalSubmission {
    PlaybackIntervalSubmission(
        epoch: epoch, session: session, generation: generation, channel: channel, sequence: sequence,
        monotonicStart: mono.lowerBound, monotonicEnd: mono.upperBound, utcStart: utc)
}

private func historyLedger(
    session: String = "session-a", generation: Int = 1,
    channels: [PlaybackChannel] = PlaybackChannel.allCases
) -> PlaybackHistoryLedger {
    var ledger = PlaybackHistoryLedger()
    _ = ledger.setRecording(true)
    for channel in channels {
        _ = ledger.beginCapture(channel: channel, session: session, generation: generation)
    }
    return ledger
}

/// Explicit sum of the independent per-channel queries. There is deliberately no aggregate
/// "companionship total": overlapping channels would be double-counted by any single sum.
private func historyTotal(_ ledger: PlaybackHistoryLedger) -> TimeInterval {
    PlaybackChannel.allCases.reduce(0) { $0 + ledger.duration(for: $1) }
}

func runPlaybackHistoryTests() {
    let anchor = historyDate("2026-09-07T10:00:00Z")

    run("PlaybackHistory.channelsAreIndependentAndMayOverlap") { t in
        var ledger = historyLedger()
        t.expectEqual(
            ledger.submit(historySubmission(epoch: 0, channel: .visual, sequence: 1, mono: 0...10, utc: anchor)),
            .accepted, "visual span")
        t.expectEqual(
            ledger.submit(historySubmission(epoch: 0, channel: .music, sequence: 1, mono: 0...10, utc: anchor)),
            .accepted, "music may overlap visual in monotonic time")
        t.expectEqual(
            ledger.submit(historySubmission(epoch: 0, channel: .visual, sequence: 2, mono: 5...15, utc: anchor)),
            .rejected(.overlappingSpan), "same channel/session must not overlap")
        t.expectEqual(ledger.intervals.count, 2, "rejections add no records")
        t.expectNear(ledger.duration(for: .visual), 10, "visual duration")
        t.expectNear(ledger.duration(for: .music), 10, "music duration")
        t.expectNear(ledger.duration(for: .ambient), 0, "unrelated channel untouched")
    }

    run("PlaybackHistory.missingContextRejectsWithoutRecord") { t in
        var ledger = PlaybackHistoryLedger()
        t.expectEqual(
            ledger.submit(historySubmission(epoch: 0, channel: .visual, sequence: 1, mono: 0...10, utc: anchor)),
            .rejected(.recordingOff), "recording is disabled by default")
        t.expect(!ledger.beginCapture(channel: .visual, session: "s", generation: 1),
                 "cannot bind a context while disabled")
        _ = ledger.setRecording(true)
        t.expectEqual(
            ledger.submit(historySubmission(epoch: 0, channel: .visual, sequence: 1, mono: 0...10, utc: anchor)),
            .rejected(.missingCaptureContext), "owner must select the capture context first")
        t.expect(ledger.intervals.isEmpty && historyTotal(ledger) == 0,
                 "status/context alone never invents duration")
    }

    run("PlaybackHistory.duplicateAndSequenceOrdering") { t in
        var ledger = historyLedger(channels: [.visual])
        let first = historySubmission(epoch: 0, channel: .visual, sequence: 1, mono: 0...10, utc: anchor)
        t.expectEqual(ledger.submit(first), .accepted, "fresh span")
        t.expectEqual(ledger.submit(first), .duplicate, "identical replay is idempotent")
        t.expectEqual(ledger.intervals.count, 1, "duplicate must not double count")
        t.expectEqual(
            ledger.submit(historySubmission(epoch: 0, channel: .visual, sequence: 1, mono: 1...11, utc: anchor)),
            .rejected(.outOfOrderSequence), "same sequence with a different span is rejected")
        t.expectEqual(
            ledger.submit(historySubmission(epoch: 0, channel: .visual, sequence: 3, mono: 10...20, utc: anchor)),
            .accepted, "later sequence accepted")
        t.expectEqual(
            ledger.submit(historySubmission(epoch: 0, channel: .visual, sequence: 2, mono: 20...30, utc: anchor)),
            .rejected(.outOfOrderSequence), "older sequence rejected")
        t.expectEqual(
            ledger.submit(historySubmission(epoch: 0, channel: .visual, sequence: 4, mono: 20...30, utc: anchor)),
            .accepted, "higher sequence, non-overlapping span accepted")
        t.expectNear(ledger.duration(for: .visual), 30, "only accepted spans counted")
    }

    run("PlaybackHistory.staleSessionGenerationEpochRejected") { t in
        var ledger = historyLedger(session: "session-a", generation: 1, channels: [.visual])
        _ = ledger.submit(historySubmission(epoch: 0, channel: .visual, sequence: 1, mono: 0...10, utc: anchor))
        t.expectEqual(
            ledger.submit(historySubmission(epoch: 0, generation: 2, channel: .visual, sequence: 2, mono: 10...20, utc: anchor)),
            .rejected(.staleContext), "new generation needs a new owner-selected context")
        _ = ledger.beginCapture(channel: .visual, session: "session-a", generation: 2)
        t.expectEqual(
            ledger.submit(historySubmission(epoch: 0, generation: 2, channel: .visual, sequence: 2, mono: 5...15, utc: anchor)),
            .rejected(.overlappingSpan), "overlap is enforced across a generation switch")
        _ = ledger.beginCapture(channel: .visual, session: "session-b", generation: 1)
        t.expectEqual(
            ledger.submit(historySubmission(epoch: 0, session: "session-a", channel: .visual, sequence: 3, mono: 0...5, utc: anchor)),
            .rejected(.staleContext), "old session rejected after rebinding")
        _ = ledger.clear()
        _ = ledger.beginCapture(channel: .visual, session: "session-b", generation: 1)
        t.expectEqual(
            ledger.submit(historySubmission(epoch: 0, session: "session-b", channel: .visual, sequence: 1, mono: 0...5, utc: anchor)),
            .rejected(.staleEpoch), "cleared epoch invalidates old submissions")
    }

    run("PlaybackHistory.invalidSpansRejected") { t in
        var ledger = historyLedger(channels: [.visual])
        func rawSubmission(sequence: Int, start: Double, end: Double) -> PlaybackIntervalSubmission {
            PlaybackIntervalSubmission(
                epoch: 0, session: "session-a", generation: 1, channel: .visual, sequence: sequence,
                monotonicStart: start, monotonicEnd: end, utcStart: anchor)
        }
        t.expectEqual(
            ledger.submit(rawSubmission(sequence: 1, start: 5, end: 5)),
            .rejected(.invalidSpan), "zero-length span is not a confirmed interval")
        t.expectEqual(
            ledger.submit(rawSubmission(sequence: 2, start: 9, end: 4)),
            .rejected(.invalidSpan), "backwards monotonic span is rejected")
        t.expectEqual(
            ledger.submit(rawSubmission(sequence: 3, start: 0, end: .nan)),
            .rejected(.invalidSpan), "non-finite span is rejected")
        t.expect(ledger.intervals.isEmpty, "invalid spans never persist")
    }

    run("PlaybackHistory.disableClearReenableInvalidatesContexts") { t in
        var ledger = historyLedger(channels: [.visual])
        _ = ledger.submit(historySubmission(epoch: 0, channel: .visual, sequence: 1, mono: 0...10, utc: anchor))
        let boundEpoch = ledger.epoch
        _ = ledger.setRecording(false)
        t.expectEqual(ledger.epoch, boundEpoch + 1, "disabling advances the recording epoch")
        t.expectEqual(ledger.intervals.count, 1, "disabling retains confirmed history")
        t.expectEqual(
            ledger.submit(historySubmission(epoch: boundEpoch, channel: .visual, sequence: 2, mono: 10...20, utc: anchor)),
            .rejected(.recordingOff), "no capture while disabled")
        _ = ledger.setRecording(true)
        t.expectEqual(
            ledger.submit(historySubmission(epoch: boundEpoch, channel: .visual, sequence: 2, mono: 10...20, utc: anchor)),
            .rejected(.staleEpoch), "re-enabling cannot relabel a span bound before the switch")
        _ = ledger.beginCapture(channel: .visual, session: "session-a", generation: 1)
        t.expectEqual(
            ledger.submit(historySubmission(epoch: boundEpoch, channel: .visual, sequence: 0, mono: 10...20, utc: anchor)),
            .rejected(.staleEpoch), "the old epoch stays stale after rebinding")
        let freshEpoch = ledger.epoch
        t.expectEqual(
            ledger.submit(historySubmission(epoch: freshEpoch, channel: .visual, sequence: 2, mono: 10...20, utc: anchor)),
            .accepted, "only a span confirmed under the fresh epoch is recorded")
        t.expectNear(historyTotal(ledger), 20, "past and fresh confirmed spans are both retained")
        _ = ledger.clear()
        t.expectEqual(ledger.epoch, freshEpoch + 1, "clear advances the epoch")
        t.expect(ledger.intervals.isEmpty && historyTotal(ledger) == 0, "clear leaves an empty ledger")
        t.expectEqual(
            ledger.submit(historySubmission(epoch: freshEpoch, channel: .visual, sequence: 3, mono: 20...25, utc: anchor)),
            .rejected(.staleEpoch), "pre-clear epoch cannot return")
    }

    run("PlaybackHistory.recordingSwitchRevokesOldEpochUnreceivedEvent") { t in
        var ledger = historyLedger(session: "agent-1", generation: 1, channels: [.visual])
        _ = ledger.submit(historySubmission(epoch: 0, session: "agent-1", generation: 1,
                                            channel: .visual, sequence: 1, mono: 0...5, utc: anchor))
        let oldEpoch = ledger.epoch
        _ = ledger.setRecording(false)
        _ = ledger.setRecording(true)
        // SAME session and generation, and a sequence that was never received before the switch.
        t.expectEqual(
            ledger.submit(historySubmission(epoch: oldEpoch, session: "agent-1", generation: 1,
                                            channel: .visual, sequence: 2, mono: 5...9, utc: anchor)),
            .rejected(.staleEpoch), "an in-flight pre-switch event can never become current")
        _ = ledger.beginCapture(channel: .visual, session: "agent-1", generation: 1)
        t.expectEqual(
            ledger.submit(historySubmission(epoch: oldEpoch, session: "agent-1", generation: 1,
                                            channel: .visual, sequence: 2, mono: 5...9, utc: anchor)),
            .rejected(.staleEpoch), "rebinding the same context cannot revive the old epoch")
        t.expectEqual(ledger.intervals.count, 1, "the late event never becomes a record")
        t.expectEqual(
            ledger.submit(historySubmission(epoch: ledger.epoch, session: "agent-1", generation: 1,
                                            channel: .visual, sequence: 2, mono: 5...9, utc: anchor)),
            .accepted, "a span confirmed under the fresh epoch is still accepted")
        t.expectNear(historyTotal(ledger), 9, "past confirmed history is retained")
        let encoded = try! JSONEncoder().encode(ledger)
        var reloaded = try! JSONDecoder().decode(PlaybackHistoryLedger.self, from: encoded)
        t.expect(reloaded.contexts.isEmpty, "restart has no active context")
        t.expectEqual(
            reloaded.submit(historySubmission(epoch: oldEpoch, session: "agent-1", generation: 1,
                                              channel: .visual, sequence: 3, mono: 9...12, utc: anchor)),
            .rejected(.staleEpoch), "reload still rejects the revoked epoch")
        t.expectNear(historyTotal(reloaded), 9, "reload retains confirmed history")
    }

    run("PlaybackHistory.cropPreservesMonotonicWatermark") { t in
        var ledger = historyLedger(session: "agent-1", generation: 1, channels: [.visual])
        _ = ledger.submit(historySubmission(epoch: 0, session: "agent-1", generation: 1,
                                            channel: .visual, sequence: 1, mono: 0...10, utc: anchor))
        _ = ledger.crop(retainingAfter: anchor.addingTimeInterval(20))
        t.expect(ledger.intervals.isEmpty, "a fully expired span is dropped")
        t.expectEqual(ledger.watermarks.count, 1, "crop preserves the watermark")
        t.expectEqual(ledger.watermarks[0].monotonicEnd, 10, "crop preserves the monotonic end")
        t.expectEqual(
            ledger.submit(historySubmission(epoch: 0, session: "agent-1", generation: 1,
                                            channel: .visual, sequence: 2, mono: 0...10, utc: anchor)),
            .rejected(.overlappingSpan), "a higher sequence cannot reuse cropped monotonic time")
        _ = ledger.beginCapture(channel: .visual, session: "agent-1", generation: 2)
        t.expectEqual(
            ledger.submit(historySubmission(epoch: 0, session: "agent-1", generation: 2,
                                            channel: .visual, sequence: 3, mono: 5...15, utc: anchor)),
            .rejected(.overlappingSpan), "a generation switch cannot reuse cropped monotonic time")
        t.expectEqual(
            ledger.submit(historySubmission(epoch: 0, session: "agent-1", generation: 2,
                                            channel: .visual, sequence: 4, mono: 10...20, utc: anchor)),
            .accepted, "a span starting at the preserved end is still accepted")
        t.expectNear(ledger.duration(for: .visual), 10, "only the new non-overlapping span counts")
    }

    run("PlaybackHistory.nonFiniteUtcAnchorRejected") { t in
        var ledger = historyLedger(channels: [.visual])
        func utcSubmission(sequence: Int, utc: Date, start: Double = 0, end: Double = 10)
            -> PlaybackIntervalSubmission {
            PlaybackIntervalSubmission(
                epoch: 0, session: "session-a", generation: 1, channel: .visual, sequence: sequence,
                monotonicStart: start, monotonicEnd: end, utcStart: utc)
        }
        t.expectEqual(
            ledger.submit(utcSubmission(sequence: 1, utc: Date(timeIntervalSince1970: .infinity))),
            .rejected(.invalidSpan), "an infinite UTC anchor is not a confirmed date")
        t.expectEqual(
            ledger.submit(utcSubmission(sequence: 2, utc: Date(timeIntervalSince1970: .nan))),
            .rejected(.invalidSpan), "a NaN UTC anchor is not a confirmed date")
        t.expectEqual(
            ledger.submit(utcSubmission(sequence: 3, utc: Date(timeIntervalSince1970: 1e308),
                                        start: 0, end: 1e308)),
            .rejected(.invalidSpan), "a UTC end that overflows its anchor is rejected")
        t.expect(ledger.intervals.isEmpty && historyTotal(ledger) == 0,
                 "no invalid date can invent duration")
        t.expectEqual(
            ledger.submit(utcSubmission(sequence: 4, utc: anchor)),
            .accepted, "a finite UTC anchor is still accepted")
    }

    run("PlaybackHistory.beijingMidnightSplitConservesDuration") { t in
        var ledger = historyLedger(channels: [.visual])
        let start = historyDate("2026-09-07T15:00:00Z")   // 23:00 Beijing
        _ = ledger.submit(historySubmission(epoch: 0, channel: .visual, sequence: 1, mono: 0...14400, utc: start))
        let days = ledger.beijingDayDurations()
        t.expectEqual(days.count, 2, "one span crosses one Beijing midnight")
        t.expectEqual(days.first?.dayStart, historyDate("2026-09-06T16:00:00Z"), "first Beijing day start")
        t.expectEqual(days.last?.dayStart, historyDate("2026-09-07T16:00:00Z"), "second Beijing day start")
        t.expectNear(days.first?.duration ?? 0, 3600, "pre-midnight segment")
        t.expectNear(days.last?.duration ?? 0, 10800, "post-midnight segment")
        t.expectNear(days.reduce(0) { $0 + $1.duration }, 14400, "segments conserve monotonic duration")
        t.expectNear(days.reduce(0) { $0 + $1.duration }, historyTotal(ledger), "split equals stored total")
    }

    run("PlaybackHistory.wallCorrectionsUsePerIntervalAnchors") { t in
        var ledger = historyLedger(channels: [.visual])
        let firstAnchor = historyDate("2026-09-07T10:00:00Z")
        // Forward wall correction: next confirmed span gets a fresh anchor an hour later.
        let secondAnchor = historyDate("2026-09-07T11:00:10Z")
        // Backwards wall correction: a later real span reuses a UTC position earlier than the
        // previous span's derived end; distinct monotonic time must survive.
        let thirdAnchor = historyDate("2026-09-07T11:00:15Z")
        _ = ledger.submit(historySubmission(epoch: 0, channel: .visual, sequence: 1, mono: 0...10, utc: firstAnchor))
        _ = ledger.submit(historySubmission(epoch: 0, channel: .visual, sequence: 2, mono: 10...20, utc: secondAnchor))
        _ = ledger.submit(historySubmission(epoch: 0, channel: .visual, sequence: 3, mono: 20...30, utc: thirdAnchor))
        t.expectEqual(ledger.intervals.count, 3, "all distinct real spans retained")
        t.expectNear(historyTotal(ledger), 30, "durations stay monotonic")
        t.expect(ledger.intervals[1].utcEnd > ledger.intervals[2].utcStart,
                 "backwards UTC overlap is data, not a duplicate")
        t.expect(ledger.intervals.allSatisfy { $0.duration > 0 },
                 "no correction can create a negative or zero span")
        t.expectNear(ledger.beijingDayDurations().reduce(0) { $0 + $1.duration }, 30,
                     "splitting preserves total across corrections")
    }

    run("PlaybackHistory.cropTrimsAndPreservesWatermarks") { t in
        var ledger = historyLedger(channels: [.visual])
        let start = historyDate("2026-09-07T10:00:00Z")
        _ = ledger.submit(historySubmission(epoch: 0, channel: .visual, sequence: 1, mono: 0...100, utc: start))
        _ = ledger.submit(historySubmission(epoch: 0, channel: .visual, sequence: 2, mono: 100...200,
                                            utc: start.addingTimeInterval(100)))
        let cutoff = start.addingTimeInterval(150)
        t.expect(ledger.crop(retainingAfter: cutoff), "crop changes the ledger")
        t.expectEqual(ledger.intervals.count, 1, "fully-expired span removed, crossing span trimmed")
        t.expectNear(ledger.intervals[0].duration, 50, "trimmed span retains only post-cutoff duration")
        t.expectEqual(ledger.intervals[0].monotonicStart, 150, "trimmed monotonic start at cutoff")
        t.expectEqual(ledger.intervals[0].utcStart, cutoff, "trimmed UTC anchor at cutoff")
        t.expectEqual(ledger.watermarks.count, 1, "watermarks preserved by retention")
        t.expectEqual(ledger.watermarks[0].sequence, 2, "receiver watermark unchanged")
        t.expectEqual(
            ledger.submit(historySubmission(epoch: 0, channel: .visual, sequence: 2, mono: 100...200,
                                            utc: start.addingTimeInterval(100))),
            .rejected(.outOfOrderSequence), "trimmed event cannot replay")
        t.expectEqual(
            ledger.submit(historySubmission(epoch: 0, channel: .visual, sequence: 1, mono: 0...100, utc: start)),
            .rejected(.outOfOrderSequence), "expired event cannot replay")
        t.expectNear(historyTotal(ledger), 50, "no replay growth after crop")
    }

    run("PlaybackHistory.checkpointAndEncodingDoNotInventDuration") { t in
        var ledger = historyLedger(channels: [.visual, .music])
        _ = ledger.submit(historySubmission(epoch: 0, channel: .visual, sequence: 1, mono: 0...10, utc: anchor))
        _ = ledger.submit(historySubmission(epoch: 0, channel: .music, sequence: 1, mono: 4...9, utc: anchor))
        t.expect(ledger.intervals.allSatisfy { $0.monotonicEnd > $0.monotonicStart },
                 "ledger stores only closed finite spans")
        let encoded = try! JSONEncoder().encode(ledger)
        // "Checkpoint" here is a pure re-encode/restart: no clock and no open tail exist to extend.
        var reloaded = try! JSONDecoder().decode(PlaybackHistoryLedger.self, from: encoded)
        t.expectNear(historyTotal(reloaded), historyTotal(ledger), "reload preserves duration")
        t.expectEqual(reloaded.intervals, ledger.intervals, "reload preserves records")
        t.expect(reloaded.contexts.isEmpty, "restart never resumes a persisted active context")
        let before = historyTotal(reloaded)
        _ = reloaded.submit(historySubmission(epoch: 0, channel: .music, sequence: 2, mono: 100...100, utc: anchor))
        t.expectNear(historyTotal(reloaded), before, "a rejected span cannot grow duration")
    }

    run("PlaybackHistory.versionedDecodeRejectsUnknownAndDropsContexts") { t in
        var ledger = historyLedger(channels: [.visual])
        _ = ledger.submit(historySubmission(epoch: 0, channel: .visual, sequence: 1, mono: 0...10, utc: anchor))
        let encoded = try! JSONEncoder().encode(ledger)
        var object = try! JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        object["version"] = PlaybackHistoryLedger.currentVersion + 7
        let tampered = try! JSONSerialization.data(withJSONObject: object)
        t.expectThrows("unknown ledger version must throw") {
            _ = try JSONDecoder().decode(PlaybackHistoryLedger.self, from: tampered)
        }
        t.expectThrows("corrupt ledger must throw") {
            _ = try JSONDecoder().decode(PlaybackHistoryLedger.self, from: Data("not json".utf8))
        }
    }

    run("PlaybackHistory.decodeRejectsInvalidPersistedValues") { t in
        var ledger = historyLedger(channels: [.visual])
        _ = ledger.submit(historySubmission(epoch: 0, channel: .visual, sequence: 1, mono: 0...10, utc: anchor))
        let encoded = try! JSONEncoder().encode(ledger)

        var negative = try! JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        var entries = negative["intervals"] as! [[String: Any]]
        entries[0]["monotonicEnd"] = -5
        negative["intervals"] = entries
        let negativeData = try! JSONSerialization.data(withJSONObject: negative)
        t.expectThrows("a persisted negative-duration interval must not decode") {
            _ = try JSONDecoder().decode(PlaybackHistoryLedger.self, from: negativeData)
        }

        var understated = try! JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        var watermarks = understated["watermarks"] as! [[String: Any]]
        watermarks[0]["monotonicEnd"] = 1
        understated["watermarks"] = watermarks
        let understatedData = try! JSONSerialization.data(withJSONObject: understated)
        t.expectThrows("a watermark that does not cover its intervals must not decode") {
            _ = try JSONDecoder().decode(PlaybackHistoryLedger.self, from: understatedData)
        }
    }
}
