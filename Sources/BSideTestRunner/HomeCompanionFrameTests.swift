// Real bounded-buffer and media integration coverage. Fixtures are generated locally.
import AppKit
import AVFoundation
import Darwin
import BSideCore
import BSidePlatform

private func waitHome(_ seconds: Double = 3, mode: RunLoop.Mode = .default, until predicate: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !predicate(), Date() < deadline {
        RunLoop.main.run(mode: mode, before: Date().addingTimeInterval(0.01))
    }
    return predicate()
}
private func pumpHome(_ seconds: Double, mode: RunLoop.Mode = .default) {
    _ = waitHome(seconds, mode: mode, until: { false })
}
private func frame(_ stream: HomeCompanionStreamRequest.Stream, sequence: UInt64 = 1,
                   width: Int = 2, height: Int = 2, stride: Int = 8) -> HomeCompanionFrame {
    .init(streamID: stream.id, sequence: sequence, contentID: "daily-test", width: width, height: height, bytesPerRow: stride)
}
private func fillHome(_ stream: HomeCompanionStreamRequest.Stream, byte: UInt8) throws {
    let file = try FileHandle(forWritingTo: URL(fileURLWithPath: stream.bufferPath))
    defer { try? file.close() }
    try file.seek(toOffset: 0)
    try file.write(contentsOf: Data(repeating: byte, count: 16))
}

func runHomeCompanionFrameTests() {
    run("HomeFrames.displayCadencePreservesPhaseAcrossJitterAndSuspension") { t in
        var cadence = HomeCompanionFrameCadence()
        let times = (0...120).map { Double($0) / 60 + ($0.isMultiple(of: 2) ? 0 : 0.0002) }
        let accepted = times.filter { cadence.admit(displayTime: $0, refreshInterval: 1.0 / 60) }
        t.expectEqual(accepted.count, 61, "two seconds of 60 Hz display timestamps admit 30 Hz without phase loss")
        t.expect(zip(accepted, accepted.dropFirst()).allSatisfy { abs(($1 - $0) - 1.0 / 30) < 0.001 },
                 "submillisecond jitter cannot introduce the previous 50 ms gaps")
        t.expect(!cadence.admit(displayTime: .nan, refreshInterval: 1.0 / 60), "invalid clock cannot advance schedule")
        t.expect(cadence.admit(displayTime: 120, refreshInterval: 1.0 / 60), "long pause admits only its latest display refresh")
        t.expect(!cadence.admit(displayTime: 120, refreshInterval: 1.0 / 60)
                 && !cadence.admit(displayTime: 120 + 1.0 / 60, refreshInterval: 1.0 / 60),
                 "missed deadlines create neither a catch-up burst nor a queued frame")
        t.expect(cadence.admit(displayTime: 120 + 1.0 / 30, refreshInterval: 1.0 / 60),
                 "normal cadence resumes after suspension")
    }
    run("HomeFrames.privateMappingRejectsUntrustedShapeAndFile") { t in
        do {
            let receiver = try HomeCompanionFrameReceiver()
            guard let stream = receiver.stream else { t.expect(false, "created mapping"); return }
            let producer = HomeCompanionFrameProducer(player: AVPlayer(), contentID: { "test" })
            defer { producer.stop(); receiver.invalidate() }
            t.expect(producer.configure(stream), "real owner-only regular buffer is accepted")
            t.expect(!HomeCompanionFrameReceiver.valid(frame(stream, width: Int.max), for: stream), "overflow width rejected before multiplication")
            t.expect(!HomeCompanionFrameReceiver.valid(frame(stream, height: -1), for: stream), "negative height rejected")
            t.expect(!HomeCompanionFrameReceiver.valid(frame(stream, stride: Int.max), for: stream), "malformed row length rejected")
            t.expect(!HomeCompanionFrameReceiver.valid(frame(stream, sequence: 0), for: stream), "zero sequence rejected")
            let badCapacity = HomeCompanionStreamRequest.Stream(id: stream.id, bufferPath: stream.bufferPath,
                capacity: stream.capacity - 1, maxWidth: stream.maxWidth, maxHeight: stream.maxHeight)
            t.expect(!producer.configure(badCapacity), "inconsistent capacity rejected")
            chmod(stream.bufferPath, 0o644)
            t.expect(!producer.configure(stream), "nonprivate file rejected")
            chmod(stream.bufferPath, 0o600)
            let link = URL(fileURLWithPath: stream.bufferPath).deletingLastPathComponent().appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: stream.bufferPath)
            let symlink = HomeCompanionStreamRequest.Stream(id: stream.id, bufferPath: link.path,
                capacity: stream.capacity, maxWidth: stream.maxWidth, maxHeight: stream.maxHeight)
            t.expect(!producer.configure(symlink), "symlink is not a capability")
            let file = try FileHandle(forWritingTo: URL(fileURLWithPath: stream.bufferPath))
            try file.truncate(atOffset: 16); try file.close()
            t.expect(!producer.configure(stream), "exact file length is required")
        } catch { t.expect(false, "mapping fixture: \(error)") }
    }
    run("HomeFrames.immutableCopyBeforeReuseAndStaleCopyRetirement") { t in
        do {
            let receiver = try HomeCompanionFrameReceiver()
            let stream = receiver.stream!
            defer { receiver.invalidate() }
            try fillHome(stream, byte: 0x22)
            var acceptedImage: CGImage?
            var acknowledgement: HomeCompanionFrameAcknowledgement?
            t.expect(receiver.receive(frame(stream)) { acceptedImage = $0; acknowledgement = $1 }, "valid first descriptor admitted")
            t.expect(!receiver.receive(frame(stream, sequence: 2)) { _, _ in }, "another frame cannot queue behind an in-flight copy")
            t.expect(waitHome { acknowledgement != nil }, "copy completion delivers ACK")
            t.expectEqual(acknowledgement?.sequence, 1, "ACK names copied sequence")
            try fillHome(stream, byte: 0x99)
            let bytes = acceptedImage?.dataProvider?.data.map { $0 as Data }
            t.expect(bytes?.first == 0x22, "buffer reuse cannot mutate already displayed image")
            t.expect(!receiver.receive(frame(stream)) { _, _ in }, "duplicate descriptor never copies again")
            var secondAccepted = false
            receiver.receive(frame(stream, sequence: 2)) { image, _ in
                secondAccepted = (image.dataProvider?.data.map { $0 as Data })?.first == 0x99
            }
            t.expect(waitHome { secondAccepted }, "same slot can be reused after ACK")

            let old = try HomeCompanionFrameReceiver()
            let oldStream = old.stream!
            try fillHome(oldStream, byte: 0x55)
            var staleAccepted = false
            old.receive(frame(oldStream)) { _, _ in staleAccepted = true }
            old.invalidate() // Copy is genuinely queued; its mapping must outlive this invalidation.
            t.expect(waitHome { !FileManager.default.fileExists(atPath: oldStream.bufferPath) }, "old copy releases and removes only its own mapping")
            t.expect(!staleAccepted, "an in-flight old generation cannot ACK or display")
            t.expect(!receiver.receive(frame(oldStream, sequence: 99)) { _, _ in }, "stale stream ID cannot address current mapped file")
        } catch { t.expect(false, "copy fixture: \(error)") }
    }
    run("HomeFrames.realMediaBackpressureTrackingAndIndependentSong") { t in
        do {
            let url = try makeTinyVideo(seconds: 8, width: 1280, height: 720, fps: 30)
            defer { try? FileManager.default.removeItem(at: url) }
            let daily = PlaybackEngine(), song = PlaybackEngine()
            let receiver = try HomeCompanionFrameReceiver()
            let producer = HomeCompanionFrameProducer(player: daily.videoObservationPlayer, contentID: { "daily-fixture" })
            defer { producer.stop(); receiver.invalidate(); daily.teardown(); song.teardown() }
            daily.play(transitionURL: nil, loopURL: url)
            song.play(transitionURL: nil, loopURL: url)
            daily.setMusicVolume(0); song.setMusicVolume(0)
            let player = daily.videoObservationPlayer
            t.expect(waitHome { player.currentTime().seconds > 0.1 }, "daily decoder actually advances")
            guard let dailyItem = player.currentItem else { t.expect(false, "daily item present"); return }
            let startPosition = player.currentTime().seconds
            t.expect(producer.configure(receiver.stream), "producer accepts receiver capability")
            var descriptors: [HomeCompanionFrame] = []
            producer.onFrame = { descriptors.append($0) }
            producer.setEnabled(true)
            t.expect(waitHome { descriptors.count == 1 }, "real native pixels produce first descriptor")
            let blockedTicks = producer.mainTicks
            pumpHome(0.15)
            t.expectEqual(descriptors.count, 1, "missing ACK bounds producer to one outstanding slot")
            t.expectEqual(producer.mainTicks, blockedTicks, "missing ACK requires no main-thread display ticks")
            guard let first = descriptors.first else { return }
            producer.acknowledge(.init(streamID: "stale", sequence: first.sequence))
            producer.acknowledge(.init(streamID: first.streamID, sequence: first.sequence + 1))
            pumpHome(0.1)
            t.expectEqual(descriptors.count, 1, "wrong generation or sequence cannot release slot")
            t.expectEqual(producer.mainTicks, blockedTicks, "invalid ACK cannot restart main-thread display ticks")
            receiver.receive(first) { _, ack in producer.acknowledge(ack) }
            t.expect(waitHome { producer.hasAcceptedFrame }, "immutable consumer completion confirms current item")
            producer.onFrame = { descriptor in receiver.receive(descriptor) { _, ack in producer.acknowledge(ack) } }
            // Flush the descriptor that could already have reached the previous callback.
            if descriptors.count > 1 { receiver.receive(descriptors.last!) { _, ack in producer.acknowledge(ack) } }
            let framesBefore = receiver.copiedFrames
            CFRunLoopAddCommonMode(CFRunLoopGetMain(), CFRunLoopMode(rawValue: RunLoop.Mode.eventTracking.rawValue as CFString))
            let bytesBefore = receiver.copiedBytes
            let copyBefore = receiver.copySeconds, produceBefore = producer.produceSeconds
            let ticksBefore = producer.mainTicks
            let wallStart = ProcessInfo.processInfo.systemUptime
            var usageStart = rusage(); getrusage(RUSAGE_SELF, &usageStart)
            pumpHome(0.65, mode: .eventTracking)
            var usageEnd = rusage(); getrusage(RUSAGE_SELF, &usageEnd)
            let wall = ProcessInfo.processInfo.systemUptime - wallStart
            let measuredFrames = receiver.copiedFrames - framesBefore
            let measuredBytes = receiver.copiedBytes - bytesBefore
            let measuredCopy = receiver.copySeconds - copyBefore, measuredProduce = producer.produceSeconds - produceBefore
            let measuredTicks = producer.mainTicks - ticksBefore
            t.expect(receiver.copiedFrames > framesBefore + 3, "real frames and ACKs continue in event-tracking mode")
            t.expect(measuredTicks <= Int(ceil(wall * 30)) + 2,
                     "main-thread work follows the unchanged 30 Hz frame cadence instead of every display refresh")
            producer.setEnabled(false)
            pumpHome(0.05) // Drain a handoff already admitted before disabling.
            let pausedTicks = producer.mainTicks, pausedFrames = receiver.copiedFrames
            pumpHome(0.1)
            t.expectEqual(producer.mainTicks, pausedTicks, "paused stream has no main-thread display ticks")
            t.expectEqual(receiver.copiedFrames, pausedFrames, "paused stream creates no additional frame images")
            producer.setEnabled(true)
            t.expect(waitHome { receiver.copiedFrames > pausedFrames + 1 }, "resume delivers frames without replacing either player")
            let songBefore = song.videoObservationPlayer.currentItem
            song.play(transitionURL: nil, loopURL: url)
            t.expect(waitHome { song.videoObservationPlayer.currentItem !== songBefore }, "song actually replaces its item")
            t.expect(player.currentItem === dailyItem && player.currentTime().seconds > startPosition,
                     "song replacement preserves daily item and advancing position")
            t.expect(waitHome { song.videoObservationPlayer.currentTime().seconds > 0.05 }, "replacement song clock is ready before continuity measurement")
            let songItem = song.videoObservationPlayer.currentItem
            let songTime = song.videoObservationPlayer.currentTime().seconds
            producer.stop()
            pumpHome(0.1)
            let stoppedTicks = producer.mainTicks, stoppedFrames = receiver.copiedFrames
            producer.acknowledge(.init(streamID: first.streamID, sequence: first.sequence))
            pumpHome(0.1)
            t.expectEqual(producer.mainTicks, stoppedTicks, "late ACK after withdrawal cannot restart display ticks")
            t.expectEqual(receiver.copiedFrames, stoppedFrames, "withdrawn stream produces no further images")
            t.expect(player.currentItem === dailyItem && song.videoObservationPlayer.currentItem === songItem
                     && song.videoObservationPlayer.currentTime().seconds >= songTime,
                     "withdrawing home leaves both independent items and song position intact")
            func cpu(_ value: rusage) -> Double {
                Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec) + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1_000_000
            }
            print(String(format: "HOME_FRAME_MEASUREMENT fixture=1280x720@30 wall=%.3fs processCPU=%.3fs frames=%d mainTicks=%d copiedBytes=%d consumerCopy=%.6fs producerCopyScale=%.6fs", wall, cpu(usageEnd) - cpu(usageStart), measuredFrames, measuredTicks, measuredBytes, measuredCopy, measuredProduce))
        } catch { t.expect(false, "real-media fixture: \(error)") }
    }
    run("HomeFrames.replacementDoesNotCreditOldAcknowledgementAndScalesWithinCap") { t in
        do {
            let url = try makeTinyVideo(seconds: 3, width: 2048, height: 1152)
            defer { try? FileManager.default.removeItem(at: url) }
            let engine = PlaybackEngine()
            let receiver = try HomeCompanionFrameReceiver()
            let producer = HomeCompanionFrameProducer(player: engine.videoObservationPlayer, contentID: { "source" })
            defer { producer.stop(); receiver.invalidate(); engine.teardown() }
            var descriptors: [HomeCompanionFrame] = []
            producer.onFrame = { descriptors.append($0) }
            producer.configure(receiver.stream)
            engine.play(transitionURL: nil, loopURL: url); engine.setMusicVolume(0)
            producer.setEnabled(true)
            t.expect(waitHome { descriptors.count == 1 }, "oversize source yields bounded native frame")
            guard let first = descriptors.first else { return }
            t.expect(first.width == 1920 && first.height == 1080 && first.bytesPerRow == 7680, "scaling preserves 16:9 within memory cap")
            receiver.receive(first) { _, ack in producer.acknowledge(ack) }
            t.expect(waitHome { producer.hasAcceptedFrame && descriptors.count >= 2 }, "old item is confirmed with successor outstanding")
            let pending = descriptors.last!
            let oldItem = engine.videoObservationPlayer.currentItem
            engine.play(transitionURL: nil, loopURL: url)
            t.expect(waitHome { engine.videoObservationPlayer.currentItem !== oldItem && !producer.hasAcceptedFrame },
                     "replacement resets confirmed visual eligibility before new pixels")
            receiver.receive(pending) { _, ack in producer.acknowledge(ack) }
            pumpHome(0.05)
            t.expect(!producer.hasAcceptedFrame, "late old-item ACK releases slot but never credits replacement")
            t.expect(waitHome { descriptors.last?.sequence != pending.sequence }, "new item proceeds after stale ACK releases slot")
            if let next = descriptors.last { receiver.receive(next) { _, ack in producer.acknowledge(ack) } }
            t.expect(waitHome { producer.hasAcceptedFrame }, "only a new-item accepted frame restores eligibility")
        } catch { t.expect(false, "replacement fixture: \(error)") }
    }
}
