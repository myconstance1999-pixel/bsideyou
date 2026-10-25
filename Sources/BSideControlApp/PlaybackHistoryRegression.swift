// Real isolated Foundation store regression for the confirmed-interval ledger. Uses only
// caller-supplied temp-directory URLs; it never touches the real user Application Support path.
import Foundation
import BSideCore

private func playbackHistoryDate(_ value: String) -> Date {
    ISO8601DateFormatter().date(from: value)!
}

private func playbackHistorySubmission(
    epoch: Int, session: String = "session-a", generation: Int = 1,
    channel: PlaybackChannel, sequence: Int, mono: ClosedRange<Double>, utc: Date
) -> PlaybackIntervalSubmission {
    PlaybackIntervalSubmission(
        epoch: epoch, session: session, generation: generation, channel: channel, sequence: sequence,
        monotonicStart: mono.lowerBound, monotonicEnd: mono.upperBound, utcStart: utc)
}

/// Explicit sum of the independent per-channel queries; the Core ledger deliberately exposes no
/// combined "companionship total" because overlapping channels would be double-counted.
private func playbackHistoryTotal(_ ledger: PlaybackHistoryLedger) -> TimeInterval {
    PlaybackChannel.allCases.reduce(0) { $0 + ledger.duration(for: $1) }
}

func runPlaybackHistoryRegression(expect: (Bool, String) -> Void) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("bsidemac-playback-history-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let anchor = playbackHistoryDate("2026-09-07T10:00:00Z")

    // Missing file -> empty, disabled, and nothing is created or overwritten.
    do {
        let url = root.appendingPathComponent("missing.json")
        let store = try PlaybackHistoryStore(fileURL: url)
        expect(store.ledger.intervals.isEmpty && !store.ledger.isRecording && store.ledger.epoch == 0,
               "missing history file must load an empty disabled ledger")
        expect(!FileManager.default.fileExists(atPath: url.path),
               "loading a missing history file must not create a file")
    } catch {
        expect(false, "missing-file history load threw \(error)")
    }

    // Real save/reload/export of confirmed records, with no active context after restart.
    do {
        let url = root.appendingPathComponent("ledger.json")
        let store = try PlaybackHistoryStore(fileURL: url)
        try store.setRecording(true)
        expect(try store.beginCapture(channel: .visual, session: "s1", generation: 3), "bind visual context")
        expect(try store.beginCapture(channel: .music, session: "s1", generation: 3), "bind music context")
        expect(try store.submit(playbackHistorySubmission(epoch: 0, session: "s1", generation: 3,
                                                          channel: .visual, sequence: 1, mono: 0...10, utc: anchor)) == .accepted,
               "visual span accepted")
        expect(try store.submit(playbackHistorySubmission(epoch: 0, session: "s1", generation: 3,
                                                          channel: .music, sequence: 1, mono: 0...10, utc: anchor)) == .accepted,
               "music span accepted independently")

        let reloaded = try PlaybackHistoryStore(fileURL: url)
        expect(reloaded.ledger.intervals == store.ledger.intervals, "reload restores confirmed intervals")
        expect(reloaded.ledger.isRecording, "recording switch persisted")
        expect(reloaded.ledger.contexts.isEmpty, "restart has no active capture context")
        expect(try reloaded.submit(playbackHistorySubmission(epoch: 0, session: "s1", generation: 3,
                                                             channel: .visual, sequence: 2, mono: 10...20, utc: anchor))
               == .rejected(.missingCaptureContext),
               "restart must not accept the old persisted active context")

        let exportURL = root.appendingPathComponent("export.json")
        try reloaded.export(to: exportURL)
        let exported = try JSONDecoder().decode(PlaybackHistoryLedger.self,
                                                from: try Data(contentsOf: exportURL))
        expect(exported.intervals == reloaded.ledger.intervals, "export contains the raw versioned records")
        let text = String(data: try Data(contentsOf: exportURL), encoding: .utf8) ?? ""
        expect(!text.contains(root.path) && !text.contains("/Users") && !text.contains("bookmark"),
               "export must not embed file paths, bookmarks, user or device identifiers")
    } catch {
        expect(false, "history save/reload/export regression threw \(error)")
    }

    // Corrupt data errors without overwriting the file.
    do {
        let url = root.appendingPathComponent("corrupt.json")
        let garbage = Data("this is not a confirmed interval ledger".utf8)
        try garbage.write(to: url)
        var threw = false
        do { _ = try PlaybackHistoryStore(fileURL: url) } catch { threw = true }
        expect(threw, "corrupt history data must error on load")
        expect(try Data(contentsOf: url) == garbage, "corrupt history file must not be overwritten")
    } catch {
        expect(false, "corrupt history regression threw \(error)")
    }

    // Unsupported version reports its number and is not overwritten.
    do {
        let url = root.appendingPathComponent("unsupported.json")
        let payload = Data("{\"version\":99,\"epoch\":0,\"isRecording\":false,\"intervals\":[],\"watermarks\":[]}".utf8)
        try payload.write(to: url)
        var observed: PlaybackHistoryStore.StoreError?
        do { _ = try PlaybackHistoryStore(fileURL: url) } catch let error as PlaybackHistoryStore.StoreError {
            observed = error
        } catch { }
        expect(observed == .unsupportedVersion(99), "unsupported version must be reported")
        expect(try Data(contentsOf: url) == payload, "unsupported version file must not be overwritten")
    } catch {
        expect(false, "unsupported-version history regression threw \(error)")
    }

    // Valid schema but invalid persisted values: a negative-duration interval and a watermark that
    // understates its recorded interval. Both must load as corrupt and leave the file untouched.
    do {
        let url = root.appendingPathComponent("invalid-values.json")
        let payload = Data(#"{"version":1,"epoch":0,"isRecording":false,"intervals":[{"epoch":0,"session":"s1","generation":1,"channel":"visual","sequence":1,"monotonicStart":0,"monotonicEnd":-5,"utcStart":0}],"watermarks":[]}"#.utf8)
        try payload.write(to: url)
        var observed: PlaybackHistoryStore.StoreError?
        do { _ = try PlaybackHistoryStore(fileURL: url) } catch let error as PlaybackHistoryStore.StoreError {
            observed = error
        } catch { }
        expect(observed == .corruptFile, "a persisted negative-duration interval must load as corrupt")
        expect(try Data(contentsOf: url) == payload, "invalid persisted values must not be overwritten")

        let watermarkURL = root.appendingPathComponent("invalid-watermark.json")
        let watermarkPayload = Data(#"{"version":1,"epoch":0,"isRecording":false,"intervals":[{"epoch":0,"session":"s1","generation":1,"channel":"visual","sequence":1,"monotonicStart":0,"monotonicEnd":10,"utcStart":0}],"watermarks":[{"session":"s1","channel":"visual","sequence":1,"monotonicEnd":5}]}"#.utf8)
        try watermarkPayload.write(to: watermarkURL)
        var watermarkObserved: PlaybackHistoryStore.StoreError?
        do { _ = try PlaybackHistoryStore(fileURL: watermarkURL) }
        catch let error as PlaybackHistoryStore.StoreError { watermarkObserved = error } catch { }
        expect(watermarkObserved == .corruptFile,
               "a watermark that understates its interval must load as corrupt")
        expect(try Data(contentsOf: watermarkURL) == watermarkPayload,
               "an invalid watermark file must not be overwritten")
    } catch {
        expect(false, "invalid-persisted-values history regression threw \(error)")
    }

    // A failed atomic save keeps both the last valid in-memory state and the last valid file.
    do {
        let dir = root.appendingPathComponent("readonly", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("ledger.json")
        let store = try PlaybackHistoryStore(fileURL: url)
        try store.setRecording(true)
        _ = try store.beginCapture(channel: .visual, session: "s1", generation: 1)
        _ = try store.submit(playbackHistorySubmission(epoch: 0, session: "s1", channel: .visual,
                                                       sequence: 1, mono: 0...10, utc: anchor))
        let snapshot = try Data(contentsOf: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }
        var failed = false
        do { try store.setRecording(false) } catch { failed = true }
        expect(failed, "a save into a read-only directory must fail")
        expect(store.ledger.isRecording && store.ledger.intervals.count == 1,
               "failed save must keep the last valid in-memory ledger")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        expect(try Data(contentsOf: url) == snapshot, "failed save must leave the last valid file untouched")
    } catch {
        expect(false, "failed-save history regression threw \(error)")
    }

    // Clear commits an incremented epoch atomically; restart cannot resurrect old records.
    do {
        let url = root.appendingPathComponent("clear.json")
        let store = try PlaybackHistoryStore(fileURL: url)
        try store.setRecording(true)
        _ = try store.beginCapture(channel: .visual, session: "s1", generation: 1)
        _ = try store.submit(playbackHistorySubmission(epoch: 0, session: "s1", channel: .visual,
                                                       sequence: 1, mono: 0...10, utc: anchor))
        let oldEpoch = store.ledger.epoch
        try store.clear()
        expect(store.ledger.epoch == oldEpoch + 1 && store.ledger.intervals.isEmpty,
               "clear must commit an incremented epoch with empty records")
        let stale = playbackHistorySubmission(epoch: oldEpoch, session: "s1", channel: .visual,
                                              sequence: 2, mono: 10...20, utc: anchor)
        expect(try store.submit(stale) == .rejected(.staleEpoch), "pre-clear epoch is rejected")
        let reloaded = try PlaybackHistoryStore(fileURL: url)
        expect(reloaded.ledger.epoch == oldEpoch + 1 && reloaded.ledger.intervals.isEmpty,
               "restart sees only the cleared epoch")
        expect(try reloaded.submit(stale) == .rejected(.staleEpoch), "restart cannot resurrect cleared records")
    } catch {
        expect(false, "clear/restart history regression threw \(error)")
    }

    // Checkpoint flushes confirmed state only; it cannot extend duration.
    do {
        let url = root.appendingPathComponent("checkpoint.json")
        let store = try PlaybackHistoryStore(fileURL: url)
        try store.setRecording(true)
        _ = try store.beginCapture(channel: .visual, session: "s1", generation: 1)
        _ = try store.submit(playbackHistorySubmission(epoch: 0, session: "s1", channel: .visual,
                                                       sequence: 1, mono: 0...10, utc: anchor))
        let before = playbackHistoryTotal(store.ledger)
        try store.checkpoint()
        try store.checkpoint()
        expect(playbackHistoryTotal(store.ledger) == before, "checkpoint cannot extend confirmed duration")
        let reloaded = try PlaybackHistoryStore(fileURL: url)
        expect(reloaded.ledger.intervals.count == 1 && playbackHistoryTotal(reloaded.ledger) == before,
               "checkpoint flushes only the confirmed state")
    } catch {
        expect(false, "checkpoint history regression threw \(error)")
    }

    // Disabling advances the persisted epoch; a late pre-switch event can never be relabeled, even
    // after rebinding the same session/generation and after a reload. Confirmed history is kept.
    do {
        let url = root.appendingPathComponent("late.json")
        let store = try PlaybackHistoryStore(fileURL: url)
        try store.setRecording(true)
        _ = try store.beginCapture(channel: .visual, session: "s1", generation: 1)
        _ = try store.submit(playbackHistorySubmission(epoch: 0, session: "s1", channel: .visual,
                                                       sequence: 1, mono: 0...5, utc: anchor))
        let oldEpoch = store.ledger.epoch
        try store.setRecording(false)
        expect(store.ledger.epoch == oldEpoch + 1 && store.ledger.intervals.count == 1,
               "disabling advances the epoch and retains confirmed history")
        expect(try store.submit(playbackHistorySubmission(epoch: oldEpoch, session: "s1", channel: .visual,
                                                          sequence: 2, mono: 5...9, utc: anchor)) == .rejected(.recordingOff),
               "disabled recording rejects late confirmed spans")
        try store.setRecording(true)
        expect(try store.submit(playbackHistorySubmission(epoch: oldEpoch, session: "s1", channel: .visual,
                                                          sequence: 2, mono: 5...9, utc: anchor)) == .rejected(.staleEpoch),
               "re-enabling cannot relabel a span bound before the switch")
        _ = try store.beginCapture(channel: .visual, session: "s1", generation: 1)
        expect(try store.submit(playbackHistorySubmission(epoch: store.ledger.epoch, session: "s1",
                                                          channel: .visual, sequence: 2, mono: 5...9,
                                                          utc: anchor)) == .accepted,
               "a span confirmed under the fresh epoch is accepted")
        expect(store.ledger.intervals.count == 2, "late inputs never grow the ledger")
        let reloaded = try PlaybackHistoryStore(fileURL: url)
        expect(reloaded.ledger.intervals.count == 2 && reloaded.ledger.epoch == oldEpoch + 1,
               "persistence keeps the fresh epoch and confirmed history")
        expect(try reloaded.submit(playbackHistorySubmission(epoch: oldEpoch, session: "s1", channel: .visual,
                                                             sequence: 3, mono: 9...12, utc: anchor)) == .rejected(.staleEpoch),
               "reload still rejects the revoked epoch")
    } catch {
        expect(false, "disable/re-enable history regression threw \(error)")
    }

    // A non-finite UTC anchor is rejected at ingest and never becomes a record.
    do {
        let url = root.appendingPathComponent("nonfinite.json")
        let store = try PlaybackHistoryStore(fileURL: url)
        try store.setRecording(true)
        _ = try store.beginCapture(channel: .visual, session: "s1", generation: 1)
        expect(try store.submit(playbackHistorySubmission(epoch: 0, session: "s1", channel: .visual,
                                                          sequence: 1, mono: 0...10,
                                                          utc: Date(timeIntervalSince1970: .infinity)))
               == .rejected(.invalidSpan),
               "an infinite UTC anchor is rejected before persistence")
        expect(store.ledger.intervals.isEmpty, "a non-finite date cannot create a record")
    } catch {
        expect(false, "non-finite UTC store regression threw \(error)")
    }

    // Retention trims crossing spans; the persisted monotonic watermark survives crop and reload.
    do {
        let url = root.appendingPathComponent("trim.json")
        let store = try PlaybackHistoryStore(fileURL: url)
        try store.setRecording(true)
        _ = try store.beginCapture(channel: .visual, session: "s1", generation: 1)
        let t0 = playbackHistoryDate("2026-09-07T10:00:00Z")
        _ = try store.submit(playbackHistorySubmission(epoch: 0, session: "s1", channel: .visual,
                                                       sequence: 1, mono: 0...100, utc: t0))
        _ = try store.submit(playbackHistorySubmission(epoch: 0, session: "s1", channel: .visual,
                                                       sequence: 2, mono: 100...200, utc: t0.addingTimeInterval(100)))
        try store.crop(retainingAfter: t0.addingTimeInterval(150))
        expect(store.ledger.intervals.count == 1 && store.ledger.intervals[0].duration == 50,
               "retention removes expired spans and trims the crossing span")
        expect(try store.submit(playbackHistorySubmission(epoch: 0, session: "s1", channel: .visual,
                                                          sequence: 2, mono: 100...200, utc: t0.addingTimeInterval(100)))
               == .rejected(.outOfOrderSequence),
               "a trimmed event cannot replay through the store")
        expect(try store.submit(playbackHistorySubmission(epoch: 0, session: "s1", channel: .visual,
                                                          sequence: 3, mono: 0...10, utc: t0))
               == .rejected(.overlappingSpan),
               "a higher sequence cannot reuse cropped monotonic time")
        expect(playbackHistoryTotal(store.ledger) == 50, "retention with replay attempt does not grow duration")
        let reloaded = try PlaybackHistoryStore(fileURL: url)
        _ = try reloaded.beginCapture(channel: .visual, session: "s1", generation: 1)
        expect(try reloaded.submit(playbackHistorySubmission(epoch: 0, session: "s1", channel: .visual,
                                                             sequence: 4, mono: 0...10, utc: t0))
               == .rejected(.overlappingSpan),
               "the monotonic watermark survives save/reload")
    } catch {
        expect(false, "retention/replay history regression threw \(error)")
    }

    // Production control model: default OFF, explicit token, one batch commit, clear/stale and
    // Agent loss never write, and export/save failures are surfaced instead of hidden.
    do {
        let url = root.appendingPathComponent("controller.json")
        var sent: [HistoryRecordingRequest] = []
        let controller = PlaybackHistoryController(fileURL: url)
        controller.onSend = { sent.append($0) }
        expect(controller.state == .ready && !controller.isEnabled, "missing file defaults OFF")
        expect(!FileManager.default.fileExists(atPath: url.path), "default off creates no file")
        controller.agentReady()
        expect(sent.count == 1 && sent[0].enabled == false,
               "a ready Agent with recording off receives an explicit disable only")

        expect(controller.setEnabled(true), "enable persists before reporting success")
        expect(controller.isEnabled && FileManager.default.fileExists(atPath: url.path),
               "enabled recording is persisted before success")
        guard let token = controller.issued else {
            expect(false, "enable mints a bound token")
            return
        }
        expect(token.enabled && token.epoch == controller.ledger?.epoch,
               "token matches the persisted epoch")

        let report = [
            playbackHistorySubmission(epoch: token.epoch, session: token.session, generation: 1,
                                      channel: .visual, sequence: 1, mono: 0...1, utc: anchor),
            playbackHistorySubmission(epoch: token.epoch, session: token.session, generation: 1,
                                      channel: .visual, sequence: 2, mono: 1...2, utc: anchor),
            playbackHistorySubmission(epoch: token.epoch, session: token.session, generation: 1,
                                      channel: .music, sequence: 1, mono: 0...1, utc: anchor),
        ]
        controller.receive(report)
        expect(controller.intervalCount == 0,
               "ControlApp batches reports instead of writing per span")
        expect(controller.commitPending(), "an explicit boundary commit succeeds")
        expect(controller.intervalCount == 3, "the whole batch is stored")
        expect(controller.ledger?.duration(for: .visual) == 2, "visual evidence is independent")
        expect(controller.ledger?.duration(for: .music) == 1, "music evidence is independent")
        expect(controller.ledger?.duration(for: .ambient) == 0, "an unobserved channel stays empty")
        let reloaded = try PlaybackHistoryStore(fileURL: url)
        expect(reloaded.ledger.intervals.count == 3, "the batch was committed to disk at once")

        let oldToken = token
        expect(controller.clear(), "clear persists before reporting success")
        expect(controller.ledger?.intervals.isEmpty == true, "clear empties the records")
        expect(controller.issued?.session != oldToken.session && controller.issued?.enabled == true,
               "clear while enabled mints a fresh bound token")
        expect(controller.issued?.epoch != oldToken.epoch, "clear advances the epoch")
        controller.receive([
            playbackHistorySubmission(epoch: oldToken.epoch, session: oldToken.session, generation: 1,
                                      channel: .visual, sequence: 1, mono: 0...1, utc: anchor)
        ])
        expect(controller.intervalCount == 0, "a pre-clear report is never relabelled")

        guard let current = controller.issued else {
            expect(false, "clear mints a token")
            return
        }
        controller.agentLost()
        controller.receive([
            playbackHistorySubmission(epoch: current.epoch, session: current.session, generation: 1,
                                      channel: .visual, sequence: 1, mono: 0...1, utc: anchor)
        ])
        expect(controller.intervalCount == 0, "reports after Agent loss do not write")

        let badURL = root.appendingPathComponent("no-such-dir/export.json")
        expect(!controller.export(to: badURL), "a failed export is reported as failure")
        expect(controller.settings.error != nil, "the export failure stays visible to Settings")

        controller.agentReady()
        guard let token2 = controller.issued else {
            expect(false, "a ready Agent mints a token again")
            return
        }
        controller.receive([
            playbackHistorySubmission(epoch: token2.epoch, session: token2.session, generation: 1,
                                      channel: .visual, sequence: 1, mono: 0...100, utc: anchor)
        ])
        expect(controller.crop(retainingAfter: anchor.addingTimeInterval(50)),
               "the explicit retention crop applies")
        expect(controller.ledger?.duration(for: .visual) == 50,
               "the crop keeps only post-cutoff time")
    } catch {
        expect(false, "history controller regression threw \(error)")
    }

    // Corrupt file: the controller surfaces the failure and never writes or resets the file.
    do {
        let url = root.appendingPathComponent("controller-corrupt.json")
        let garbage = Data("this is not a confirmed interval ledger".utf8)
        try garbage.write(to: url)
        let controller = PlaybackHistoryController(fileURL: url)
        var sent = false
        controller.onSend = { _ in sent = true }
        expect(controller.state != .ready, "a corrupt file surfaces a load failure")
        expect(!controller.setEnabled(true), "a corrupt file cannot be enabled or written over")
        controller.agentReady()
        expect(!sent, "no recording token is sent while the ledger failed to load")
        expect(try Data(contentsOf: url) == garbage, "the corrupt file is never overwritten or reset")
    } catch {
        expect(false, "corrupt history controller regression threw \(error)")
    }

    // Cadence: the ~30s limit is confirmed ELAPSED span, not a segment count, and commits ONE
    // atomic write. The separate count cap bounds a flood of sub-second submissions.
    do {
        let url = root.appendingPathComponent("controller-cadence.json")
        let controller = PlaybackHistoryController(fileURL: url)
        _ = controller.setEnabled(true)
        guard let token = controller.issued else {
            expect(false, "cadence test mints a token")
            return
        }
        let cadenceCount = Int(PlaybackHistoryController.pendingDurationLimit)
        // Deliver one confirmed second at a time so the real event-driven boundary is exercised.
        for index in 1...cadenceCount {
            controller.receive([
                playbackHistorySubmission(epoch: token.epoch, session: token.session, generation: 1,
                                          channel: .visual, sequence: index,
                                          mono: Double(index - 1)...Double(index), utc: anchor)
            ])
        }
        expect(controller.intervalCount == cadenceCount,
               "accumulating ~30s of confirmed span commits the pending batch")
        let reloaded = try PlaybackHistoryStore(fileURL: url)
        expect(reloaded.ledger.intervals.count == cadenceCount,
               "the cadence batch is persisted and reloadable")
    } catch {
        expect(false, "history cadence regression threw \(error)")
    }

    // Bounded count cap: many tiny confirmed submissions commit at the hard bound even though the
    // elapsed cadence has not been reached. There is no timer and no unbounded buffer.
    do {
        let url = root.appendingPathComponent("controller-cap.json")
        let controller = PlaybackHistoryController(fileURL: url)
        _ = controller.setEnabled(true)
        guard let token = controller.issued else {
            expect(false, "cap test mints a token")
            return
        }
        let cap = (1...PlaybackHistoryController.pendingBatchLimit).map { index in
            playbackHistorySubmission(epoch: token.epoch, session: token.session, generation: 1,
                                      channel: .visual, sequence: index,
                                      mono: Double(index - 1) * 0.01...Double(index) * 0.01, utc: anchor)
        }
        controller.receive(cap)
        expect(controller.intervalCount == PlaybackHistoryController.pendingBatchLimit,
               "the bounded count cap commits even before the elapsed cadence")
    } catch {
        expect(false, "history count-cap regression threw \(error)")
    }

    // A failed batch write preserves truthful error state and pauses ingestion instead of
    // buffering forever or retrying invisibly.
    do {
        let dir = root.appendingPathComponent("controller-readonly", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("ledger.json")
        let controller = PlaybackHistoryController(fileURL: url)
        var sent: [HistoryRecordingRequest] = []
        controller.onSend = { sent.append($0) }
        _ = controller.setEnabled(true)
        guard let token = controller.issued else {
            expect(false, "failed-write test mints a token")
            return
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }
        let batch = (1...PlaybackHistoryController.pendingBatchLimit).map { index in
            playbackHistorySubmission(epoch: token.epoch, session: token.session, generation: 1,
                                      channel: .music, sequence: index,
                                      mono: Double(index - 1)...Double(index), utc: anchor)
        }
        controller.receive(batch)
        expect(controller.ingestionPaused, "a failed batch write pauses report ingestion")
        expect(controller.settings.error != nil, "the failed write stays visible to Settings")
        expect(controller.intervalCount == 0, "a failed write never counts as stored")
        controller.receive([
            playbackHistorySubmission(epoch: token.epoch, session: token.session, generation: 1,
                                      channel: .music, sequence: 99, mono: 100...101, utc: anchor)
        ])
        expect(controller.intervalCount == 0, "ingestion stays paused after a data error")
        expect(sent.last?.enabled == false,
               "a failed commit stops remote authority with the existing disable request")
        controller.agentReady()
        expect(controller.issued == nil && sent.last?.enabled == false,
               "a paused controller never re-enables capture or mints a fresh token")
        expect(!controller.export(to: root.appendingPathComponent("failed-batch-export.json")),
               "repeated export cannot hide the retained failed batch")
        expect(controller.settings.error != nil, "repeated failure stays visible")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        expect(controller.commitPending(), "explicit retry persists the bounded failed batch")
        expect(controller.intervalCount == batch.count, "retry loses no previously confirmed span")

    } catch {
        expect(false, "failed-batch history regression threw \(error)")
    }

    // Store ingest context across a session restart: the SESSION is compared before the
    // generation, so a fresh session starting at generation 1 rebinds instead of being rejected
    // by the previous session's higher generation. Old-session input stays stale.
    do {
        let url = root.appendingPathComponent("session-rebind.json")
        let store = try PlaybackHistoryStore(fileURL: url)
        try store.setRecording(true)
        let epoch = store.ledger.epoch
        expect(try store.beginCapture(channel: .visual, session: "s1", generation: 5),
               "the previous session binds a high generation")
        expect(try store.submit(playbackHistorySubmission(epoch: epoch, session: "s1", generation: 5,
                                                          channel: .visual, sequence: 1,
                                                          mono: 0...10, utc: anchor)) == .accepted,
               "the previous session records a span")
        let request = HistoryRecordingRequest(enabled: true, epoch: epoch, session: "s2")
        let fresh = playbackHistorySubmission(epoch: epoch, session: "s2", generation: 1,
                                              channel: .visual, sequence: 1,
                                              mono: 20...30, utc: anchor)
        expect(try store.ingest([fresh], expected: request) == [.accepted],
               "a fresh session with a lower generation is accepted, not stale-rejected")
        expect(store.ledger.duration(for: .visual) == 20,
               "both sessions' confirmed spans are retained")
        expect(try store.submit(playbackHistorySubmission(epoch: epoch, session: "s2", generation: 1,
                                                          channel: .visual, sequence: 2,
                                                          mono: 30...35, utc: anchor)) == .accepted,
               "the rebound session keeps accepting its own generation")
        let old = playbackHistorySubmission(epoch: epoch, session: "s1", generation: 6,
                                            channel: .visual, sequence: 3,
                                            mono: 40...45, utc: anchor)
        expect(try store.ingest([old], expected: request) == [.rejected(.staleContext)],
               "an old-session report is rejected under the new token")
        let lower = playbackHistorySubmission(epoch: epoch, session: "s2", generation: 0,
                                              channel: .visual, sequence: 4,
                                              mono: 50...55, utc: anchor)
        expect(try store.ingest([lower], expected: request) == [.rejected(.staleContext)],
               "a same-session lower generation stays stale")
    } catch {
        expect(false, "session-rebind history regression threw \(error)")
    }

    // A failed clear write must NOT discard pending confirmed spans, and a later export must fail
    // truthfully when the pending commit cannot persist instead of silently dropping the batch.
    do {
        let dir = root.appendingPathComponent("controller-pending", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("ledger.json")
        let controller = PlaybackHistoryController(fileURL: url)
        expect(controller.setEnabled(true), "pending-failure test enables recording")
        guard let token = controller.issued else {
            expect(false, "pending-failure test mints a token")
            return
        }
        controller.receive([
            playbackHistorySubmission(epoch: token.epoch, session: token.session, generation: 1,
                                      channel: .visual, sequence: 1, mono: 0...1, utc: anchor),
            playbackHistorySubmission(epoch: token.epoch, session: token.session, generation: 1,
                                      channel: .visual, sequence: 2, mono: 1...2, utc: anchor),
        ])
        expect(controller.intervalCount == 0, "a sub-cadence report stays pending")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }
        expect(!controller.clear(), "a failed clear write is reported as failure")
        expect(controller.settings.error != nil, "the failed clear stays visible")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        expect(controller.commitPending(), "pending survived the failed clear and commits later")
        expect(controller.intervalCount == 2,
               "a failed clear did not discard pending confirmed spans")
        controller.receive([
            playbackHistorySubmission(epoch: token.epoch, session: token.session, generation: 1,
                                      channel: .visual, sequence: 3, mono: 10...11, utc: anchor),
            playbackHistorySubmission(epoch: token.epoch, session: token.session, generation: 1,
                                      channel: .visual, sequence: 4, mono: 11...12, utc: anchor),
        ])
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        expect(!controller.export(to: dir.appendingPathComponent("export.json")),
               "export fails when the pending commit cannot persist")
        expect(controller.settings.error != nil, "the export/pending failure stays visible")
    } catch {
        expect(false, "pending/clear history regression threw \(error)")
    }

    // Retention crop must also fail (not silently drop) when its pending commit cannot persist.
    do {
        let dir = root.appendingPathComponent("controller-crop", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("ledger.json")
        let controller = PlaybackHistoryController(fileURL: url)
        expect(controller.setEnabled(true), "crop-failure test enables recording")
        guard let token = controller.issued else {
            expect(false, "crop-failure test mints a token")
            return
        }
        for index in 1...Int(PlaybackHistoryController.pendingDurationLimit) {
            controller.receive([
                playbackHistorySubmission(epoch: token.epoch, session: token.session, generation: 1,
                                          channel: .visual, sequence: index,
                                          mono: Double(index - 1)...Double(index), utc: anchor)
            ])
        }
        controller.receive([
            playbackHistorySubmission(epoch: token.epoch, session: token.session, generation: 1,
                                      channel: .visual,
                                      sequence: Int(PlaybackHistoryController.pendingDurationLimit) + 1,
                                      mono: 100...101, utc: anchor),
        ])
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }
        expect(!controller.crop(retainingAfter: anchor),
               "crop fails when the pending commit cannot persist")
        expect(controller.settings.error != nil, "the crop/pending failure stays visible")
    } catch {
        expect(false, "crop/pending history regression threw \(error)")
    }

    // Production onChange -> agentLost wiring. AppDelegate wires playbackHistory.onChange to
    // uiRefresh (pushModelUpdate), and pushModelUpdate calls agentLost whenever the Agent is not
    // running. A failed export sets lastError and emits onChange, so agentLost re-entered the same
    // wiring forever until the Release stack was exhausted (SIGSEGV). The callback below is
    // bounded: the failing baseline records a wrong notification count instead of exhausting the
    // runner's stack. An unchanged error is NOT a new event and must not clear the export error.
    do {
        let url = root.appendingPathComponent("controller-onchange-agentlost.json")
        let controller = PlaybackHistoryController(fileURL: url)
        expect(controller.setEnabled(true), "onChange-wiring test enables recording")
        var notifications = 0
        let bound = 32
        controller.onChange = {
            notifications += 1
            guard notifications < bound else { return }
            controller.agentLost()
        }
        let badURL = root.appendingPathComponent("no-such-dir/onchange-export.json")
        expect(!controller.export(to: badURL), "the export failure is still reported")
        expect(notifications == 1,
               "a failed export refreshes once; unchanged agentLost must not recurse (saw \(notifications))")
        expect(controller.settings.error != nil,
               "the export error stays visible instead of being cleared to stop recursion")
    } catch {
        expect(false, "onChange/agentLost wiring regression threw \(error)")
    }

    // A successful pending flush on genuine Agent loss changes the projection (count/durations) and
    // must refresh the UI exactly once; repeated unchanged agentLost calls stay silent.
    do {
        let url = root.appendingPathComponent("controller-agentlost-flush.json")
        let controller = PlaybackHistoryController(fileURL: url)
        expect(controller.setEnabled(true), "loss-flush test enables recording")
        guard let token = controller.issued else {
            expect(false, "loss-flush test mints a token")
            return
        }
        controller.receive([
            playbackHistorySubmission(epoch: token.epoch, session: token.session, generation: 1,
                                      channel: .visual, sequence: 1, mono: 0...1, utc: anchor),
            playbackHistorySubmission(epoch: token.epoch, session: token.session, generation: 1,
                                      channel: .visual, sequence: 2, mono: 1...2, utc: anchor),
        ])
        expect(controller.intervalCount == 0, "the loss-flush batch stays pending")
        var notifications = 0
        let bound = 32
        controller.onChange = {
            notifications += 1
            guard notifications < bound else { return }
            controller.agentLost()
        }
        controller.agentLost()
        expect(controller.intervalCount == 2, "genuine Agent loss persists the pending batch")
        expect(notifications == 1,
               "a successful loss flush refreshes its changed count/durations once (saw \(notifications))")
    } catch {
        expect(false, "loss-flush history regression threw \(error)")
    }

    // A flush that fails on genuine Agent loss is actionable: notify once, keep the error and the
    // bounded retry batch, then stay quiet on the repeated unchanged agentLost that follows.
    do {
        let dir = root.appendingPathComponent("controller-agentlost-fail", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("ledger.json")
        let controller = PlaybackHistoryController(fileURL: url)
        expect(controller.setEnabled(true), "failed loss-flush test enables recording")
        guard let token = controller.issued else {
            expect(false, "failed loss-flush test mints a token")
            return
        }
        controller.receive([
            playbackHistorySubmission(epoch: token.epoch, session: token.session, generation: 1,
                                      channel: .music, sequence: 1, mono: 0...1, utc: anchor),
            playbackHistorySubmission(epoch: token.epoch, session: token.session, generation: 1,
                                      channel: .music, sequence: 2, mono: 1...2, utc: anchor),
        ])
        var notifications = 0
        let bound = 32
        controller.onChange = {
            notifications += 1
            guard notifications < bound else { return }
            controller.agentLost()
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }
        controller.agentLost()
        expect(controller.ingestionPaused, "a failed loss flush pauses ingestion")
        expect(controller.settings.error != nil, "a failed loss flush keeps actionable feedback")
        expect(notifications == 1,
               "a newly failed flush notifies once and does not recurse (saw \(notifications))")
    } catch {
        expect(false, "failed loss-flush history regression threw \(error)")
    }
}
