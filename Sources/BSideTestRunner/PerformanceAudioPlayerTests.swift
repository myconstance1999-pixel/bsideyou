// Real AVFoundation coverage using only self-owned, silent audio/video fixtures (ADR-009).

import AVFoundation
import CoreVideo
import Foundation
import BSideCore
import BSidePlatform

private func audioFixtureError(_ code: Int) -> NSError {
    NSError(domain: "PerformanceAudioPlayerTests", code: code)
}

private func makeAudioFixture(audioTracks: Int = 1, audioSeconds: Double = 2.5, audioOnly: Bool = false) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("bsidemac-audio-only-\(UUID().uuidString).\(audioOnly ? "mp4" : "mov")")
    var returned = false
    defer { if !returned { try? FileManager.default.removeItem(at: url) } }
    let writer = try AVAssetWriter(outputURL: url, fileType: audioOnly ? .mp4 : .mov)
    let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: 16,
        AVVideoHeightKey: 16,
        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 32_000],
    ])
    let pixels = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 16,
            kCVPixelBufferHeightKey as String: 16,
        ])
    guard writer.canAdd(video) else { throw audioFixtureError(1) }
    if !audioOnly { writer.add(video) }
    let audio = (0..<audioTracks).map { _ in
        AVAssetWriterInput(mediaType: .audio, outputSettings: audioOnly ? [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000
        ] : [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
    }
    for input in audio {
        guard writer.canAdd(input) else { throw audioFixtureError(2) }
        writer.add(input)
    }
    guard writer.startWriting() else { throw writer.error ?? audioFixtureError(3) }
    writer.startSession(atSourceTime: .zero)
    var writerFinished = false
    defer { if !writerFinished { writer.cancelWriting() } }

    // The audio samples begin at 0.25 s and end at 2.75 s; video continues to 4 s.
    // QuickTime represents this with a leading empty edit and a track range starting at 0.
    // PCM avoids encoder priming so both that edit and the complete range can be checked.
    if !audio.isEmpty {
        var format = AudioStreamBasicDescription(mSampleRate: 44_100,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var description: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &format,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &description) == noErr,
              let description else { throw audioFixtureError(4) }
        let frameCount = Int(audioSeconds * 44_100)
        let byteCount = frameCount * 2
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
            memoryBlock: nil, blockLength: byteCount, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: byteCount,
            flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block else { throw audioFixtureError(5) }
        var bytes: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
            totalLengthOut: nil, dataPointerOut: &bytes) == noErr, let bytes else {
            throw audioFixtureError(6)
        }
        memset(bytes, 0, byteCount)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 44_100),
            presentationTimeStamp: CMTime(value: 11_025, timescale: 44_100),
            decodeTimeStamp: .invalid)
        var sampleSize = 2
        var samples: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
            formatDescription: description, sampleCount: frameCount,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
            sampleBufferOut: &samples) == noErr, let samples else { throw audioFixtureError(7) }
        for input in audio {
            guard waitForAudio({ input.isReadyForMoreMediaData }) else { throw audioFixtureError(8) }
            guard input.append(samples) else { throw writer.error ?? audioFixtureError(9) }
            input.markAsFinished()
        }
    }
    for frame in 0..<(audioOnly ? 0 : 48) {
        guard waitForAudio({ video.isReadyForMoreMediaData }) else { throw audioFixtureError(10) }
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32ARGB,
            nil, &pixelBuffer) == kCVReturnSuccess, let pixelBuffer else { throw audioFixtureError(11) }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            memset(base, frame.isMultiple(of: 2) ? 0x40 : 0xA0, CVPixelBufferGetDataSize(pixelBuffer))
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        guard pixels.append(pixelBuffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 12)) else {
            throw writer.error ?? audioFixtureError(12)
        }
    }
    if !audioOnly { video.markAsFinished() }
    let finished = DispatchSemaphore(value: 0)
    writer.finishWriting { finished.signal() }
    guard finished.wait(timeout: .now() + 5) == .success else { throw audioFixtureError(13) }
    guard writer.status == .completed else { throw writer.error ?? audioFixtureError(14) }
    writerFinished = true
    returned = true
    return url
}

private func waitForAudio(_ predicate: @escaping () -> Bool, timeout: TimeInterval = 3) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !predicate() && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    return predicate()
}

private func awaitAudio<T>(_ operation: @escaping () async throws -> T) throws -> T {
    var result: Result<T, Error>?
    let task = Task { @MainActor in
        do { result = .success(try await operation()) }
        catch { result = .failure(error) }
    }
    guard waitForAudio({ result != nil }, timeout: 8), let result else {
        task.cancel()
        throw audioFixtureError(15)
    }
    return try result.get()
}

func runPerformanceAudioPlayerTests() {
    run("PerformanceMediaProbe.audioOnlyLocalMP4KeepsAudioPlayback") { t in
        do {
            let url = try makeAudioFixture(audioOnly: true)
            defer { try? FileManager.default.removeItem(at: url) }
            let hasVideo = try awaitAudio { try await PerformanceMediaProbe.hasVideo(url) }
            t.expect(!hasVideo && url.pathExtension == "mp4", "a supported local MP4 can have no video track")
            let composition = try awaitAudio { try await PerformanceAudioPlayer.prepare(url: url) }
            let player = PerformanceAudioPlayer()
            defer { player.stop() }
            player.setVolume(0)
            player.play(asset: composition, onReady: {}, completion: { _ in })
            t.expect(waitForAudio { player.currentTime.seconds > 0.3 },
                     "the existing audio-only path still advances without any picture presentation")
            let videoURL = try makeAudioFixture()
            defer { try? FileManager.default.removeItem(at: videoURL) }
            let videoPresent = try awaitAudio { try await PerformanceMediaProbe.hasVideo(videoURL) }
            t.expect(videoPresent, "a video-backed container retains video capability")
            let broken = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
            defer { try? FileManager.default.removeItem(at: broken) }
            try Data("invalid media".utf8).write(to: broken)
            do {
                _ = try awaitAudio { try await PerformanceMediaProbe.hasVideo(broken) }
                t.expect(false, "unreadable video must fail instead of becoming an audio fallback")
            } catch { t.expect(true, "unreadable source retains its failure") }
        } catch { t.expect(false, "audio-only compatibility fixture failed: \(error)") }
    }
    run("PerformanceAudioPlayer.audioOnlyFullTrackAndRealPlayback") { t in
        do {
            let url = try makeAudioFixture()
            defer { try? FileManager.default.removeItem(at: url) }
            let source = AVURLAsset(url: url)
            let sourceAudio = try awaitAudio { try await source.loadTracks(withMediaType: .audio) }
            let sourceVideo = try awaitAudio { try await source.loadTracks(withMediaType: .video) }
            t.expectEqual(sourceAudio.count, 1, "fixture really contains one audio track")
            t.expectEqual(sourceVideo.count, 1, "fixture really contains video")
            guard let original = sourceAudio.first else { return }
            let originalRange = try awaitAudio { try await original.load(.timeRange) }
            let originalSegments = try awaitAudio { try await original.load(.segments) }
            let originalDuration = try awaitAudio { try await source.load(.duration) }
            let composition = try awaitAudio { try await PerformanceAudioPlayer.prepare(url: url) }
            let audio = try awaitAudio { try await composition.loadTracks(withMediaType: .audio) }
            let video = try awaitAudio { try await composition.loadTracks(withMediaType: .video) }
            let duration = try awaitAudio { try await composition.load(.duration) }
            t.expectEqual(audio.count, 1, "prepared asset contains one audio track")
            t.expectEqual(video.count, 0, "prepared asset contains no video track")
            let emptySegments = originalSegments.filter { $0.isEmpty }
            let contentSegments = originalSegments.filter { !$0.isEmpty }
            t.expectNear(originalRange.start.seconds, 0, "container includes the leading empty edit in its track range")
            t.expectEqual(emptySegments.count, 1, "fixture has a real leading empty edit")
            t.expectEqual(contentSegments.count, 1, "fixture has one real nonempty audio edit")
            if let empty = emptySegments.first {
                t.expectNear(empty.timeMapping.target.start.seconds, 0, "leading empty edit starts at zero")
                t.expectNear(empty.timeMapping.target.duration.seconds, 0.25, "leading empty edit preserves the sample delay")
            }
            if let content = contentSegments.first {
                t.expectNear(content.timeMapping.target.start.seconds, 0.25, "real audio segment starts at the original sample offset")
                t.expectNear(content.timeMapping.target.duration.seconds, 2.5, "real audio segment keeps every sample")
            }
            t.expect(originalDuration.seconds - CMTimeRangeGetEnd(originalRange).seconds > 1,
                     "fixture has a real video trailer beyond the audio")
            t.expectNear(duration.seconds, CMTimeRangeGetEnd(originalRange).seconds,
                         "composition ends at the complete audio end, not the video end")
            let segments = (audio.first as? AVCompositionTrack)?.segments.filter { !$0.isEmpty } ?? []
            t.expectEqual(segments.count, 1, "one complete source audio segment is inserted")
            if let segment = segments.first {
                t.expectEqual(segment.sourceURL, source.url, "composition references the original media including its edits")
                t.expectEqual(segment.sourceTrackID, original.trackID, "composition references the complete original audio track")
                t.expectNear(segment.timeMapping.source.start.seconds, originalRange.start.seconds,
                             "original audio source start is retained")
                t.expectNear(segment.timeMapping.source.duration.seconds, originalRange.duration.seconds,
                             "original audio source duration is retained")
                t.expectNear(segment.timeMapping.target.start.seconds, originalRange.start.seconds,
                             "complete source track start is retained on the output timeline")
                t.expectNear(segment.timeMapping.target.duration.seconds, originalRange.duration.seconds,
                             "audio is neither shortened nor stretched")
                if let content = contentSegments.first {
                    // This outer composition references the source track's edits; verify the
                    // nested nonempty edit still lands at the fixture's original 0.25 s offset.
                    let contentStart = CMTimeAdd(segment.timeMapping.target.start,
                        CMTimeSubtract(content.timeMapping.target.start, segment.timeMapping.source.start))
                    t.expectNear(contentStart.seconds, 0.25, "referenced audio edit retains its original output start")
                }
            }

            let player = PerformanceAudioPlayer()
            defer { player.stop() }
            player.setPaused(true)
            player.setVolume(0)
            var ready = 0
            var completed = 0
            var detail: String?
            var callbacksOnMain = true
            player.play(asset: composition, onReady: {
                ready += 1
                callbacksOnMain = callbacksOnMain && Thread.isMainThread
            }, completion: {
                completed += 1
                detail = $0
                callbacksOnMain = callbacksOnMain && Thread.isMainThread
            })
            guard waitForAudio({ ready == 1 || completed > 0 }), let item = player.currentItem else {
                t.expect(false, "audio becomes ready while initial pause is retained: \(detail ?? "no completion")")
                return
            }
            t.expectEqual(ready, 1, "ready callback occurs once")
            let installedVideo = try awaitAudio { try await item.asset.loadTracks(withMediaType: .video) }
            t.expect(installedVideo.isEmpty, "actual installed AVPlayerItem has no video track")
            let initialTime = player.currentTime.seconds
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            t.expectNear(player.currentTime.seconds, initialTime, "initial pause prevents clock advance", eps: 0.025)
            player.setPaused(false)
            t.expect(waitForAudio { player.currentTime.seconds > 0.45 }, "zero-volume playback actually advances")
            let silentTime = player.currentTime.seconds
            t.expect(waitForAudio { player.currentTime.seconds > silentTime + 0.15 },
                     "remaining muted continues the media clock")
            player.setPaused(true)
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            let pauseTime = player.currentTime.seconds
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            t.expectNear(player.currentTime.seconds, pauseTime, "pause stops the real audio clock", eps: 0.025)
            t.expectEqual(completed, 0, "pause does not finish the performance")
            player.setPaused(false)
            t.expect(waitForAudio { player.currentTime.seconds > pauseTime + 0.15 }, "resume advances the same item")
            t.expect(player.currentItem === item, "pause and resume preserve the installed item")
            t.expect(waitForAudio({ completed == 1 }, timeout: 5), "real audio EOF completes once")
            t.expectNil(detail, "natural audio EOF succeeds")
            t.expect(item.currentTime().seconds >= duration.seconds - 0.1, "natural EOF consumes the complete audio timeline")
            t.expect(!player.hasAudioResources && player.currentItem == nil, "EOF releases audio resources")
            NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: item)
            NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: item)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            t.expectEqual(completed, 1, "late EOF/failure cannot duplicate completion")
            t.expectEqual(ready, 1, "pause/resume/EOF do not repeat ready")
            t.expect(callbacksOnMain, "ready and completion arrive on the main thread")
        } catch { t.expect(false, "audio-only playback fixture failed: \(error)") }
    }

    run("PerformanceAudioPlayer.stopAndReplacementRevokeOldCallbacks") { t in
        do {
            let url = try makeAudioFixture()
            defer { try? FileManager.default.removeItem(at: url) }
            let composition = try awaitAudio { try await PerformanceAudioPlayer.prepare(url: url) }
            let player = PerformanceAudioPlayer()
            defer { player.stop() }
            player.setPaused(true)
            player.setVolume(0)
            var obsoleteReady = 0
            var obsoleteCompletion = 0
            player.play(asset: composition, onReady: { obsoleteReady += 1 }, completion: { _ in obsoleteCompletion += 1 })
            guard let oldItem = player.currentItem else {
                t.expect(false, "first audio item is installed synchronously")
                return
            }
            player.stop() // Before pumping main: initial status work is still queued.
            t.expect(!player.hasAudioResources, "explicit stop releases the item immediately")
            var ready = 0
            var completed = 0
            player.play(asset: composition, onReady: { ready += 1 }, completion: { _ in completed += 1 })
            guard let current = player.currentItem else {
                t.expect(false, "replacement audio item is installed")
                return
            }
            NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: oldItem)
            NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: oldItem,
                userInfo: [AVPlayerItemFailedToPlayToEndTimeErrorKey: audioFixtureError(16)])
            t.expect(waitForAudio { ready == 1 }, "replacement reaches ready after old work is revoked")
            t.expect(player.currentItem === current && current !== oldItem, "old item events cannot release the replacement")
            t.expectEqual(obsoleteReady, 0, "stopped initial readiness is suppressed")
            t.expectEqual(obsoleteCompletion, 0, "stop does not report completion")
            t.expectEqual(completed, 0, "old EOF/failure cannot finish the replacement")
            player.stop()
            NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: current)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            t.expectEqual(completed, 0, "replacement stop also suppresses late completion")
            t.expect(!player.hasAudioResources && player.currentItem == nil, "stop leaves no audio resources")
        } catch { t.expect(false, "audio callback fixture failed: \(error)") }
    }

    run("PerformanceAudioPlayer.rejectsMissingAmbiguousVideoAndCancelledPreparation") { t in
        do {
            let missingURL = try makeAudioFixture(audioTracks: 0)
            defer { try? FileManager.default.removeItem(at: missingURL) }
            let ambiguousURL = try makeAudioFixture(audioTracks: 2)
            defer { try? FileManager.default.removeItem(at: ambiguousURL) }
            do {
                _ = try awaitAudio { try await PerformanceAudioPlayer.prepare(url: missingURL) }
                t.expect(false, "video-only source must fail audio preparation")
            } catch {
                t.expect(String(describing: error).contains("没有音轨"), "missing audio has an explicit reason: \(error)")
            }
            do {
                _ = try awaitAudio { try await PerformanceAudioPlayer.prepare(url: ambiguousURL) }
                t.expect(false, "multiple audio tracks require an explicit selection rule")
            } catch {
                t.expect(String(describing: error).contains("多条音轨"), "multiple audio tracks fail without guessing: \(error)")
            }
            let cancelled = Task { @MainActor in try await PerformanceAudioPlayer.prepare(url: ambiguousURL) }
            cancelled.cancel() // The main-actor operation cannot start until this test pumps its run loop.
            do {
                _ = try awaitAudio { try await cancelled.value }
                t.expect(false, "cancelled preparation must not return a composition")
            } catch {
                t.expect(error is CancellationError, "cancellation remains cancellation: \(error)")
            }

            let invalid = try awaitAudio { () async throws -> AVComposition in
                let source = AVURLAsset(url: missingURL)
                let tracks = try await source.loadTracks(withMediaType: .video)
                guard let sourceTrack = tracks.first else { throw audioFixtureError(17) }
                let range = try await sourceTrack.load(.timeRange)
                let composition = AVMutableComposition()
                guard let track = composition.addMutableTrack(withMediaType: .video,
                    preferredTrackID: kCMPersistentTrackID_Invalid) else { throw audioFixtureError(18) }
                try track.insertTimeRange(range, of: sourceTrack, at: .zero)
                return composition
            }
            let player = PerformanceAudioPlayer()
            defer { player.stop() }
            var ready = 0
            var completed = 0
            var detail: String?
            var callbackOnMain = false
            player.play(asset: invalid, onReady: { ready += 1 }, completion: {
                completed += 1
                detail = $0
                callbackOnMain = Thread.isMainThread
            })
            t.expect(!player.hasAudioResources, "composition containing video never becomes an AVPlayerItem")
            t.expect(waitForAudio { completed == 1 }, "invalid composition reports failure once")
            t.expectNotNil(detail, "invalid composition has an explicit failure reason")
            t.expectEqual(ready, 0, "invalid composition cannot report ready")
            t.expect(callbackOnMain, "pre-install failure is delivered on the main thread")
        } catch { t.expect(false, "audio rejection fixture failed: \(error)") }
    }

    run("PlaybackProgressObserver.realMediaAdvancesConfirmsAndEligibilityGatesHold") { t in
        do {
            // Default OFF: a real advancing player records nothing until enable() gives a token.
            let url = try makeAudioFixture()
            defer { try? FileManager.default.removeItem(at: url) }
            let composition = try awaitAudio { try await PerformanceAudioPlayer.prepare(url: url) }
            let player = PerformanceAudioPlayer()
            defer { player.stop() }
            let observer = PlaybackProgressObserver()
            var confirmed: [PlaybackIntervalSubmission] = []
            observer.onConfirmed = { confirmed.append($0) }
            t.expect(!observer.isObserving, "no observation before an explicit token")
            player.setPaused(true)
            player.setVolume(0.5)
            var ready = 0
            player.play(asset: composition, onReady: { ready += 1 }, completion: { _ in })
            t.expect(waitForAudio { ready == 1 }, "real audio fixture becomes ready")
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            t.expect(confirmed.isEmpty, "a disabled observer records nothing")

            observer.enable(epoch: 0, session: "agent-real")
            observer.attach(player: player.observationPlayer, role: .music, requiresAudioTrack: true) {
                player.effectiveVolume > 0
            }
            player.setPaused(false)
            t.expect(waitForAudio({ confirmed.count >= 2 }, timeout: 6),
                     "the real media clock confirms spans while playing")
            t.expect(confirmed.allSatisfy {
                $0.channel == .music && $0.epoch == 0 && $0.session == "agent-real"
                    && ($0.monotonicEnd - $0.monotonicStart) > 0
                    && ($0.monotonicEnd - $0.monotonicStart) <= PlaybackProgressTracker.maxCallbackGap
            }, "every confirmed span is a positive, bounded music span under the issued token")
            let beforeDetach = confirmed.count
            observer.detach()
            t.expect(!observer.isObserving, "detach removes observation")
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            t.expectEqual(confirmed.count, beforeDetach, "a detached observer records nothing more")

            // Audible-zero must not count as music.
            observer.enable(epoch: 1, session: "muted")
            observer.attach(player: player.observationPlayer, role: .music, requiresAudioTrack: true) {
                player.effectiveVolume > 0
            }
            player.setVolume(0)
            let mutedBefore = confirmed.count
            RunLoop.main.run(until: Date().addingTimeInterval(1.5))
            t.expectEqual(confirmed.count, mutedBefore, "audible-zero playback never counts music")
            observer.detach()

            // A real trackless video must not count as music even at full volume.
            let tracklessURL = try makeAudioFixture(audioTracks: 0)
            defer { try? FileManager.default.removeItem(at: tracklessURL) }
            let videoOnly = AVPlayer()
            defer { videoOnly.pause(); videoOnly.replaceCurrentItem(with: nil) }
            videoOnly.volume = 1
            videoOnly.replaceCurrentItem(with: AVPlayerItem(url: tracklessURL))
            videoOnly.play()
            observer.enable(epoch: 2, session: "visual")
            observer.attach(player: videoOnly, role: .music, requiresAudioTrack: true) { true }
            t.expect(waitForAudio { videoOnly.rate == 1 }, "trackless fixture actually plays")
            let tracklessBefore = confirmed.count
            RunLoop.main.run(until: Date().addingTimeInterval(1.5))
            t.expectEqual(confirmed.count, tracklessBefore,
                          "a trackless daily video can never count as music")
            observer.detach()
        } catch { t.expect(false, "real progress observer fixture failed: \(error)") }
    }

    run("PlaybackProgressObserver.listenAndTracklessDailyShareMusicWithoutMutualInvalidation") { t in
        do {
            // A real audio-only listen player and a real trackless daily video both attach to the
            // music channel. The idle/trackless daily attachment must never clear the listen
            // anchor, and the listen attachment must never clear the daily visual anchor.
            let listenURL = try makeAudioFixture()
            defer { try? FileManager.default.removeItem(at: listenURL) }
            let listenComposition = try awaitAudio {
                try await PerformanceAudioPlayer.prepare(url: listenURL)
            }
            let listen = PerformanceAudioPlayer()
            defer { listen.stop() }
            listen.setPaused(true)
            listen.setVolume(0.6)
            var listenReady = 0
            listen.play(asset: listenComposition, onReady: { listenReady += 1 }, completion: { _ in })
            t.expect(waitForAudio { listenReady == 1 }, "the listen fixture becomes ready")

            let dailyURL = try makeAudioFixture(audioTracks: 0)
            defer { try? FileManager.default.removeItem(at: dailyURL) }
            let daily = AVPlayer()
            defer { daily.pause(); daily.replaceCurrentItem(with: nil) }
            daily.volume = 1
            daily.replaceCurrentItem(with: AVPlayerItem(url: dailyURL))

            let observer = PlaybackProgressObserver()
            var confirmed: [PlaybackIntervalSubmission] = []
            observer.onConfirmed = { confirmed.append($0) }
            observer.enable(epoch: 7, session: "listen+daily")
            observer.attach(player: daily, role: .visual) { true }
            observer.attach(player: daily, role: .music, requiresAudioTrack: true) { true }
            observer.attach(player: listen.observationPlayer, role: .music,
                            requiresAudioTrack: true) { listen.effectiveVolume > 0 }
            listen.setPaused(false)
            daily.play()
            t.expect(waitForAudio { daily.rate == 1 }, "the trackless daily fixture actually plays")
            t.expect(waitForAudio({ confirmed.contains { $0.channel == .music } }, timeout: 8),
                     "listen music confirms while a trackless daily video advances alongside it")
            t.expect(waitForAudio({ confirmed.contains { $0.channel == .visual } }, timeout: 8),
                     "the daily video confirms visual independently at the same time")
            observer.detach()
        } catch { t.expect(false, "listen+daily observer fixture failed: \(error)") }
    }

    run("PlaybackProgressObserver.fastPauseResumeStillLeavesBoundary") { t in
        do {
            let url = try makeAudioFixture(audioSeconds: 12)
            defer { try? FileManager.default.removeItem(at: url) }
            let composition = try awaitAudio { try await PerformanceAudioPlayer.prepare(url: url) }
            let player = PerformanceAudioPlayer()
            defer { player.stop() }
            player.setPaused(true)
            player.setVolume(0.7)
            var ready = 0
            player.play(asset: composition, onReady: { ready += 1 }, completion: { _ in })
            t.expect(waitForAudio { ready == 1 }, "pause-boundary fixture becomes ready")
            let observer = PlaybackProgressObserver()
            var confirmed: [PlaybackIntervalSubmission] = []
            observer.onConfirmed = { confirmed.append($0) }
            observer.enable(epoch: 4, session: "pause-boundary")
            observer.attach(player: player.observationPlayer, role: .music,
                            requiresAudioTrack: true) { player.effectiveVolume > 0 }
            player.setPaused(false)
            t.expect(waitForAudio({ confirmed.count >= 2 }, timeout: 6),
                     "playback confirms before the pause")
            // Pause and resume inside one sampling second: the boundary must still break, so no
            // single confirmed span may straddle the pause instant.
            let pauseInstant = ProcessInfo.processInfo.systemUptime
            player.setPaused(true)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            player.setPaused(false)
            t.expect(waitForAudio({ confirmed.count >= 4 }, timeout: 6),
                     "playback confirms again after the resume")
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            observer.detach()
            t.expect(!confirmed.contains {
                $0.monotonicStart < pauseInstant && $0.monotonicEnd > pauseInstant
            }, "no confirmed span crosses the rapid pause/resume boundary")
        } catch { t.expect(false, "pause-boundary observer fixture failed: \(error)") }
    }
}
