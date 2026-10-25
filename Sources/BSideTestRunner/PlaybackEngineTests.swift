// BSideTestRunner — real AVFoundation regression coverage for PlaybackEngine pause intent.

import AVFoundation
import CoreVideo
import Foundation
import BSideCore
import BSidePlatform

func makeTinyVideo(seconds: Int = 1, width: Int = 16, height: Int = 16, fps: Int32 = 12,
                           codec: AVVideoCodecType = .h264,
                           frameFill: (Int) -> UInt8 = { $0.isMultiple(of: 2) ? 0x40 : 0xA0 }) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("bsidemac-playback-\(UUID().uuidString).mp4")
    var returned = false
    defer {
        if !returned { try? FileManager.default.removeItem(at: url) }
    }
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: codec,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 32_000],
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
    guard writer.canAdd(input) else { throw NSError(domain: "PlaybackEngineTests", code: 1) }
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? NSError(domain: "PlaybackEngineTests", code: 2) }
    writer.startSession(atSourceTime: .zero)

    for frame in 0..<(Int(fps) * seconds) {
        let readyDeadline = Date().addingTimeInterval(3)
        while !input.isReadyForMoreMediaData && Date() < readyDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        guard input.isReadyForMoreMediaData else {
            writer.cancelWriting()
            throw NSError(domain: "PlaybackEngineTests", code: 3)
        }
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32ARGB, nil, &buffer)
        guard let buffer else {
            writer.cancelWriting()
            throw NSError(domain: "PlaybackEngineTests", code: 4)
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, Int32(frameFill(frame)), CVPixelBufferGetDataSize(buffer))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps)) else {
            writer.cancelWriting()
            throw writer.error ?? NSError(domain: "PlaybackEngineTests", code: 5)
        }
    }
    input.markAsFinished()
    let semaphore = DispatchSemaphore(value: 0)
    writer.finishWriting { semaphore.signal() }
    guard semaphore.wait(timeout: .now() + 5) == .success else {
        writer.cancelWriting()
        throw NSError(domain: "PlaybackEngineTests", code: 6)
    }
    guard writer.status == .completed else { throw writer.error ?? NSError(domain: "PlaybackEngineTests", code: 7) }
    returned = true
    return url
}

/// A real encoded video whose earliest displayable sample is delayed behind an empty leading edit.
/// An item installed on it reports readiness (and, on the platform, new output) while media time 0
/// still has no displayable picture, so `copyPixelBuffer` returns NULL exactly as the native
/// capture showed. Generated locally; no official media is used.
private func makeDelayedFirstFrameVideo(leadingDelay: Double = 1.0,
                                        seconds: Int = 2,
                                        codec: AVVideoCodecType = .h264,
                                        frameFill: (Int) -> UInt8 = { $0.isMultiple(of: 2) ? 0x40 : 0xA0 }) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("bsidemac-playback-delayed-\(UUID().uuidString).mp4")
    var returned = false
    defer {
        if !returned { try? FileManager.default.removeItem(at: url) }
    }
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: codec,
        AVVideoWidthKey: 16,
        AVVideoHeightKey: 16,
        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 32_000],
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 16,
            kCVPixelBufferHeightKey as String: 16,
        ])
    guard writer.canAdd(input) else { throw NSError(domain: "PlaybackEngineTests", code: 20) }
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? NSError(domain: "PlaybackEngineTests", code: 21) }
    // The session starts at zero while the first sample is appended after the delay, so the movie
    // carries an empty leading edit and media time 0 has nothing displayable.
    writer.startSession(atSourceTime: .zero)
    let timescale: CMTimeScale = 12
    let leadingFrames = Int((leadingDelay * Double(timescale)).rounded())
    for frame in 0..<(12 * seconds) {
        let readyDeadline = Date().addingTimeInterval(3)
        while !input.isReadyForMoreMediaData && Date() < readyDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        guard input.isReadyForMoreMediaData else {
            writer.cancelWriting()
            throw NSError(domain: "PlaybackEngineTests", code: 22)
        }
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32ARGB, nil, &buffer)
        guard let buffer else {
            writer.cancelWriting()
            throw NSError(domain: "PlaybackEngineTests", code: 23)
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, Int32(frameFill(frame)), CVPixelBufferGetDataSize(buffer))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let pts = CMTime(value: CMTimeValue(leadingFrames + frame), timescale: timescale)
        guard adaptor.append(buffer, withPresentationTime: pts) else {
            writer.cancelWriting()
            throw writer.error ?? NSError(domain: "PlaybackEngineTests", code: 24)
        }
    }
    input.markAsFinished()
    let semaphore = DispatchSemaphore(value: 0)
    writer.finishWriting { semaphore.signal() }
    guard semaphore.wait(timeout: .now() + 5) == .success else {
        writer.cancelWriting()
        throw NSError(domain: "PlaybackEngineTests", code: 25)
    }
    guard writer.status == .completed else { throw writer.error ?? NSError(domain: "PlaybackEngineTests", code: 26) }
    returned = true
    return url
}

/// A real malformed container: an .mp4 path whose payload cannot be parsed by AVFoundation.
/// This is the reproduced daily-loop failure shape (the item never becomes the player's current
/// item, so only the looper's own load status can report it).
private func makeUnreadableContainer() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("bsidemac-unreadable-\(UUID().uuidString).mp4")
    try Data(repeating: 0xAB, count: 256).write(to: url)
    return url
}

/// A test-owned copy of a generated HEVC asset whose video sample entry is retagged hvc1→hev1.
/// On this SDK the platform then reports the track isPlayable=false/isDecodable=false while the
/// item is still allowed to become ready — the false-success shape this regression guards.
private func makeHEV1MismatchCopy(of source: URL) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("bsidemac-hev1-\(UUID().uuidString).mp4")
    var data = try Data(contentsOf: source)
    guard let range = data.range(of: Data("hvc1".utf8)) else {
        throw NSError(domain: "PlaybackEngineTests", code: 8,
                      userInfo: [NSLocalizedDescriptionKey: "generated HEVC asset has no hvc1 sample entry"])
    }
    data.replaceSubrange(range, with: Data("hev1".utf8))
    try data.write(to: url)
    return url
}

/// The platform's own asynchronous track capability, loaded exactly as production must.
private func loadVideoCapability(_ url: URL) -> (playable: Bool, decodable: Bool)? {
    let semaphore = DispatchSemaphore(value: 0)
    var result: (playable: Bool, decodable: Bool)?
    Task {
        let asset = AVURLAsset(url: url)
        if let track = try? await asset.loadTracks(withMediaType: .video).first {
            result = ((try? await track.load(.isPlayable)) ?? false,
                      (try? await track.load(.isDecodable)) ?? false)
        }
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 10)
    return result
}

private func waitForPlayback(_ predicate: @escaping () -> Bool, timeout: TimeInterval = 3) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !predicate() && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    return predicate()
}

/// The retained picture is the engine's still layer contents; tests may need the real pixels to
/// prove a hold came from the outgoing video rather than a blank or source-frame-zero poster.
private func retainedStillImage(of engine: PlaybackEngine) -> CGImage? {
    for layer in engine.videoLayer.sublayers ?? [] {
        if let contents = layer.contents { return contents as! CGImage }
    }
    return nil
}

private func averageLuminance(_ image: CGImage) -> Double {
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    guard width > 0, height > 0,
          let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return -1 }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    var total = 0.0
    for index in stride(from: 0, to: pixels.count, by: 4) {
        total += Double(pixels[index]) * 0.299 + Double(pixels[index + 1]) * 0.587
            + Double(pixels[index + 2]) * 0.114
    }
    return total / Double(width * height)
}

func runPlaybackEngineTests() {
    run("PlaybackEngine.soundtrackPauseRetainsPositionAndIndependentVideo") { t in
        let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent("bsidemac-ambient-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: audioURL) }
        do {
            let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
            let samples = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_323_000)!
            samples.frameLength = samples.frameCapacity
            samples.floatChannelData![0].initialize(repeating: 0, count: Int(samples.frameLength))
            do { try AVAudioFile(forWriting: audioURL, settings: format.settings).write(from: samples) }
            let videoURL = try makeTinyVideo(seconds: 12)
            defer { try? FileManager.default.removeItem(at: videoURL) }
            let engine = PlaybackEngine()
            let observer = PlaybackProgressObserver()
            defer { observer.detach(); engine.teardown() }
            var spans: [PlaybackIntervalSubmission] = []
            observer.enable(epoch: 1, session: "ambient-pause")
            observer.onConfirmed = { spans.append($0) }
            observer.attach(player: engine.ambientObservationPlayer, role: .ambient) {
                PlaybackProgressEligibility.ambient(hasTrack: engine.hasAmbientResources,
                                                    effectiveVolume: engine.ambientOutputVolume)
            }
            engine.play(transitionURL: nil, loopURL: videoURL)
            engine.setAmbientTrack(url: audioURL, volume: 0.4)
            let audio = engine.ambientObservationPlayer, video = engine.videoObservationPlayer
            guard waitForPlayback({ audio.currentTime().seconds > 0.2 && video.currentTime().seconds > 0.2 }),
                  let audioItem = audio.currentItem, let videoItem = video.currentItem else {
                t.expect(false, "independent audio/video fixtures start"); return
            }
            t.expect(waitForPlayback({ !spans.isEmpty }), "actual ambient progress earns history")
            observer.invalidate(role: .ambient)
            engine.setAmbientTrack(url: audioURL, volume: 0, paused: true)
            let position = audio.currentTime().seconds, videoPosition = video.currentTime().seconds
            let count = spans.count
            RunLoop.main.run(until: Date().addingTimeInterval(1.2))
            t.expect(audio.currentItem === audioItem && engine.hasAmbientResources && audio.rate == 0,
                     "explicit pause retains the exact audio item and resource lifetime")
            t.expectNear(audio.currentTime().seconds, position, "audio clock remains at paused position", eps: 0.025)
            t.expect(video.currentItem === videoItem && video.currentTime().seconds > videoPosition + 0.5,
                     "picture item keeps advancing independently")
            t.expectEqual(spans.count, count, "paused soundtrack earns no history")
            engine.setAmbientTrack(url: audioURL, volume: 0.4)
            t.expect(waitForPlayback({ audio.currentTime().seconds > position + 0.15 }), "same clock resumes forward")
            t.expect(audio.currentItem === audioItem, "resume never rebuilds or seeks the audio item")
            t.expectNear(engine.ambientOutputVolume, 0.4, "unchanged gain restored", eps: 0.0001)
            let beforeVideoSwitch = audio.currentTime().seconds
            engine.stopVideo()
            engine.play(transitionURL: nil, loopURL: videoURL)
            t.expectEqual(engine.setAmbientTrack(url: audioURL, volume: 0.4), .none,
                          "reconciling an unchanged deliberate soundtrack on video replacement is a no-op")
            t.expect(waitForPlayback { audio.currentTime().seconds > beforeVideoSwitch + 0.15 },
                     "soundtrack clock advances through independent video replacement")
            t.expect(audio.currentItem === audioItem, "video replacement cannot replace or seek the soundtrack item")

            let desired = DesiredState(dailySoundtrack: .track(ContentID("ambient://1")))
            let fullscreen = PlaybackPolicy.evaluate(desired: desired,
                context: RuntimeContext(desktopVisible: false, fullscreenAppActive: true))
            engine.setVisualPaused(fullscreen.visual == .paused)
            let beforeFullscreen = audio.currentTime().seconds
            let picturePosition = video.currentTime().seconds
            t.expectEqual(engine.setAmbientTrack(url: audioURL, volume: fullscreen.ambientVolume,
                paused: fullscreen.ambientPaused), .none, "fullscreen keeps the same soundtrack chain")
            t.expect(waitForPlayback { audio.currentTime().seconds > beforeFullscreen + 0.2 },
                     "soundtrack time advances while another application is fullscreen")
            t.expect(video.rate == 0, "fullscreen pauses the daily picture")
            t.expectNear(video.currentTime().seconds, picturePosition, "daily picture time remains paused", eps: 0.025)
            t.expect(audio.currentItem === audioItem && (audio.currentItem?.asset as? AVURLAsset)?.url == audioURL,
                     "fullscreen preserves the exact ambient item and selected source")

            var released: Bool?
            engine.releasePausedDaily { released = $0 }
            t.expect(waitForPlayback({ released != nil }), "daily retention release completes")
            t.expect(released == true && !engine.hasVideoResources && engine.hasRetainedFrame,
                     "paused fullscreen picture can release its decoder and retain a still")
            let afterRelease = audio.currentTime().seconds
            t.expect(waitForPlayback { audio.currentTime().seconds > afterRelease + 0.2 },
                     "soundtrack keeps advancing after video resource release")
            t.expect(audio.currentItem === audioItem && audio.rate > 0,
                     "video resource release leaves the ambient player item running")

            let returned = PlaybackPolicy.evaluate(desired: desired, context: RuntimeContext())
            engine.setVisualPaused(returned.visual == .paused)
            engine.play(transitionURL: nil, loopURL: videoURL)
            t.expectEqual(engine.setAmbientTrack(url: audioURL, volume: returned.ambientVolume,
                paused: returned.ambientPaused), .none, "leaving fullscreen does not rebuild the soundtrack")
            let beforeReturn = audio.currentTime().seconds
            t.expect(waitForPlayback { audio.currentTime().seconds > beforeReturn + 0.2 && video.rate > 0 },
                     "same soundtrack clock continues as the daily picture resumes")
            t.expect(audio.currentItem === audioItem && engine.ambientObservationPlayer === audio,
                     "fullscreen round trip retains the same audio player and item")
            engine.setAmbientTrack(url: audioURL, volume: 0, paused: true)
            engine.setAmbientTrack(url: nil, volume: 0)
            t.expect(!engine.hasAmbientResources && audio.currentItem == nil,
                     "resource invalidation releases a retained paused item")
            engine.setAmbientTrack(url: audioURL, volume: 0.4)
            engine.setAmbientTrack(url: audioURL, volume: 0, paused: true)
            engine.setAmbientTrack(url: audioURL, volume: 0)
            t.expect(!engine.hasAmbientResources && audio.currentItem == nil,
                     "safety/mute releases the retained item rather than silently retaining decode resources")
        } catch { t.expect(false, "soundtrack fixture failed: \(error)") }
    }

    run("PlaybackEngine.homeMirrorSharesDailyClockAndKeepsDesktopLayer") { t in
        do {
            let url = try makeTinyVideo(seconds: 3)
            defer { try? FileManager.default.removeItem(at: url) }
            let engine = PlaybackEngine()
            defer { engine.teardown() }
            let desktop = CALayer(), home = CALayer()
            desktop.addSublayer(engine.videoLayer)
            home.addSublayer(engine.watchVideoLayer)
            engine.setWatchMirrorEnabled(true, aspectFit: true)
            t.expect(engine.videoLayer.player === engine.watchVideoLayer.player,
                     "both layers use the exact same player, not synchronized independent players")
            let player = engine.videoLayer.player!
            t.expectEqual(player.audiovisualBackgroundPlaybackPolicy, .continuesIfPossible,
                          "an explicit audiovisual player declares background continuation")
            engine.play(transitionURL: nil, loopURL: url)
            guard waitForPlayback({ player.currentTime().seconds > 0.1 }) else {
                t.expect(false, "shared player starts"); return
            }
            let item = player.currentItem
            t.expect(engine.videoLayer.superlayer === desktop && engine.watchVideoLayer.superlayer === home,
                     "home presentation does not steal the desktop layer")
            engine.setWatchMirrorEnabled(false)
            engine.setWatchMirrorEnabled(true, aspectFit: true)
            t.expect(player.currentItem === item, "reopening home keeps the exact daily item")
            t.expectEqual(engine.watchVideoLayer.videoGravity, .resizeAspect, "home retains the full companion framing")
            engine.setVisualPaused(true)
            t.expectEqual(engine.watchVideoLayer.player?.rate, 0, "one pause applies to both presentations")
            engine.setVisualPaused(false)
            let priorTime = player.currentTime().seconds
            engine.setWatchMirrorEnabled(false)
            t.expectNil(engine.watchVideoLayer.player, "ending home releases its mirror")
            t.expect(engine.videoLayer.player === player && player.currentItem === item,
                     "mirror removal preserves the desktop's item and player")
            t.expect(waitForPlayback { player.currentTime().seconds > priorTime + 0.1 },
                     "desktop clock continues after mirror removal")
            engine.teardown()
            t.expectNil(engine.watchVideoLayer.player, "shutdown cannot retain a mirror player")
        } catch { t.expect(false, "mirror fixture failed: \(error)") }
    }

    run("PlaybackEngine.dailyBoundaryWaitsForActualReplicaAndUsesLatestCallback") { t in
        do {
            let url = try makeTinyVideo(seconds: 2)
            let replacementURL = try makeTinyVideo()
            defer {
                try? FileManager.default.removeItem(at: url)
                try? FileManager.default.removeItem(at: replacementURL)
            }
            let engine = PlaybackEngine()
            defer { engine.teardown() }
            let player = engine.videoLayer.player!
            var obsoleteCalls = 0
            var calls = 0
            var finishedAt = 0.0
            t.expect(!engine.finishCurrentDailyUnit { obsoleteCalls += 1 }, "empty queue has no daily unit")
            engine.play(transitionURL: nil, loopURL: url)
            guard waitForPlayback({ player.currentTime().seconds > 0.15 }), let item = player.currentItem else {
                t.expect(false, "daily replica starts")
                return
            }
            let observationLock = NSLock()
            var earlyItemChanges: [String] = []
            let itemObservation = player.observe(\.currentItem, options: [.new]) { _, change in
                let next = change.newValue ?? nil
                let endedAt = item.currentTime().seconds
                if next !== item && endedAt < 1.8 {
                    observationLock.lock()
                    earlyItemChanges.append("\(next == nil ? "empty" : "replacement") at \(endedAt)")
                    observationLock.unlock()
                }
            }
            defer { itemObservation.invalidate() }
            t.expect(engine.finishCurrentDailyUnit { obsoleteCalls += 1 }, "request captures a daily replica")
            let switchAtEnd = {
                calls += 1
                finishedAt = item.currentTime().seconds
                engine.play(transitionURL: nil, loopURL: replacementURL)
            }
            engine.finishCurrentDailyUnit(switchAtEnd)
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            t.expect(player.currentItem === item && item.currentTime().seconds > 0.25,
                     "request leaves the actual running item in place")
            t.expectEqual(calls, 0, "request does not eagerly invoke the boundary")
            t.expect(engine.finishCurrentDailyUnit(switchAtEnd), "later intent update stays on the draining replica")
            t.expect(waitForPlayback({ calls == 1 }, timeout: 5), "real natural end invokes latest callback")
            t.expect(finishedAt > 1.8, "the full current unit finishes, got \(finishedAt)")
            t.expectEqual(obsoleteCalls, 0, "updating intent replaces the old callback")
            t.expect(waitForPlayback { (player.currentItem?.asset as? AVURLAsset)?.url == replacementURL },
                     "callback replacement survives old-loop cleanup")
            NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: item)
            t.expectEqual(calls, 1, "stale duplicate event cannot invoke the consumed callback")
            observationLock.lock()
            let prematureChanges = earlyItemChanges
            observationLock.unlock()
            t.expect(prematureChanges.isEmpty,
                     "draining queue has no nil/next-item KVO transition before EOF: \(prematureChanges)")
        } catch { t.expect(false, "daily boundary fixture failed: \(error)") }
    }
    run("PlaybackEngine.cancelledBoundaryDrainsThenKeepsLooping") { t in
        do {
            let url = try makeTinyVideo()
            defer { try? FileManager.default.removeItem(at: url) }
            let engine = PlaybackEngine()
            defer { engine.teardown() }
            let player = engine.videoLayer.player!
            engine.play(transitionURL: nil, loopURL: url)
            guard waitForPlayback({ player.currentTime().seconds > 0.1 }), let item = player.currentItem else {
                t.expect(false, "daily starts before cancellation")
                return
            }
            var calls = 0
            engine.finishCurrentDailyUnit { calls += 1 }
            t.expect(waitForPlayback { engine.hasPreparedDailyEOFFrame },
                     "a pending boundary prepares its handoff frame")
            engine.cancelPendingDailyBoundary()
            t.expect(!engine.hasPreparedDailyEOFFrame,
                     "withdrawing an actual pending request still discards its preparation")
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            t.expect(player.currentItem === item, "cancelling does not cut off the current unit")
            t.expect(waitForPlayback { player.currentItem != nil && player.currentItem !== item },
                     "cancelled switch still restores the original loop after real end")
            let next = player.currentItem
            t.expect(waitForPlayback { player.currentItem != nil && player.currentItem !== next },
                     "restored loop continues through another whole unit")
            t.expectEqual(calls, 0, "cancelled owner callback is never called")
        } catch { t.expect(false, "cancelled boundary fixture failed: \(error)") }
    }
    run("PlaybackEngine.preparedDailyEOFFrameClearsOnStopAndRetarget") { t in
        do {
            let dayURL = try makeTinyVideo(seconds: 3)
            defer { try? FileManager.default.removeItem(at: dayURL) }
            let transitionURL = try makeTinyVideo()
            defer { try? FileManager.default.removeItem(at: transitionURL) }
            let engine = PlaybackEngine()
            defer { engine.teardown() }
            let player = engine.videoLayer.player!
            var calls = 0

            engine.play(transitionURL: nil, loopURL: dayURL)
            guard waitForPlayback({ player.currentTime().seconds > 0.3 }), let firstItem = player.currentItem else {
                t.expect(false, "daily unit starts before the stop check")
                return
            }
            engine.finishCurrentDailyUnit { calls += 1 }
            t.expect(waitForPlayback { engine.hasPreparedDailyEOFFrame },
                     "a pending boundary prepares before the stop")
            engine.stopVideo()
            t.expect(!engine.hasPreparedDailyEOFFrame && !engine.hasRetainedFrame && !engine.hasVideoResources,
                     "stop clears the prepared frame with the released queue")

            engine.play(transitionURL: nil, loopURL: dayURL)
            guard waitForPlayback({ player.currentTime().seconds > 0.3 }), player.currentItem != nil else {
                t.expect(false, "daily unit restarts before the retarget")
                return
            }
            engine.finishCurrentDailyUnit { calls += 1 }
            t.expect(waitForPlayback { engine.hasPreparedDailyEOFFrame },
                     "a pending boundary prepares before the retarget")
            engine.play(transitionURL: transitionURL, loopURL: transitionURL)
            t.expect(!engine.hasPreparedDailyEOFFrame,
                     "an explicit retarget clears a preparation it does not consume")
            NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: firstItem)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            t.expectEqual(calls, 0, "stop and retarget never invoke the withdrawn callback")
        } catch { t.expect(false, "prepared frame cleanup fixture failed: \(error)") }
    }
    run("PlaybackEngine.dailyBoundaryPreservesPauseBeforeAndAfterNaturalEnd") { t in
        do {
            let url = try makeTinyVideo()
            defer { try? FileManager.default.removeItem(at: url) }
            let engine = PlaybackEngine()
            defer { engine.teardown() }
            let player = engine.videoLayer.player!
            engine.play(transitionURL: nil, loopURL: url)
            guard waitForPlayback({ player.currentTime().seconds > 0.1 }), let item = player.currentItem else {
                t.expect(false, "daily starts before pause")
                return
            }
            engine.setVisualPaused(true)
            var calls = 0
            engine.finishCurrentDailyUnit {
                calls += 1
                engine.setVisualPaused(true)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(1.1))
            t.expectEqual(calls, 0, "wall-clock elapsed time cannot finish a paused unit")
            t.expect(player.currentItem === item && player.rate == 0, "waiting leaves pause intent intact")
            engine.setVisualPaused(false)
            t.expect(waitForPlayback { calls == 1 && player.currentItem != nil && player.currentItem !== item },
                     "resume reaches real end and restores loop when callback does not replace it")
            t.expectEqual(player.rate, 0, "pause applied by owner at end survives loop restoration")
            NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: item)
            t.expectEqual(calls, 1, "duplicate old event remains consumed while paused")
            engine.setVisualPaused(false)
            t.expect(waitForPlayback { player.currentTime().seconds > 0.15 }, "restored paused loop can resume")
        } catch { t.expect(false, "paused boundary fixture failed: \(error)") }
    }
    run("PlaybackEngine.restoredTransitionBoundaryFinishesRemainingItemOnce") { t in
        do {
            let url = try makeTinyVideo(seconds: 2)
            defer { try? FileManager.default.removeItem(at: url) }
            let engine = PlaybackEngine()
            defer { engine.teardown() }
            let player = engine.videoLayer.player!
            engine.play(transitionURL: url, loopURL: url)
            t.expect(waitForPlayback { player.currentTime().seconds > 0.3 }, "original transition advances")
            let originalItem = player.currentItem
            var obsoleteCalls = 0
            engine.finishCurrentDailyUnit { obsoleteCalls += 1 }
            engine.setVisualPaused(true)
            var released = false
            engine.releasePausedDaily(preservingFrame: false) { released = $0 }
            t.expect(released, "release invalidates the original boundary")
            engine.play(transitionURL: nil, loopURL: url)
            t.expect(waitForPlayback { player.currentTime().seconds > 0.2 }, "restores remaining transition position")
            guard let item = player.currentItem else { t.expect(false, "restored item exists"); return }
            var calls = 0
            var finishedAt = 0.0
            engine.finishCurrentDailyUnit {
                calls += 1
                finishedAt = item.currentTime().seconds
            }
            NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: originalItem)
            t.expect(player.currentItem === item, "late old transition end cannot replace restored unit")
            engine.setVisualPaused(false)
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            t.expect(player.currentItem === item && calls == 0, "remaining transition is not cut short")
            t.expect(waitForPlayback({ calls == 1 && player.currentItem !== item }, timeout: 5),
                     "shared transition handler invokes boundary then installs exactly one loop")
            t.expect(finishedAt > 1.8, "restored transition reaches its natural end")
            t.expectEqual(obsoleteCalls, 0, "released boundary cannot return")
            let next = player.currentItem
            NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: item)
            t.expect(player.currentItem === next && calls == 1, "duplicate transition cannot install another loop")
        } catch { t.expect(false, "restored boundary fixture failed: \(error)") }
    }
    run("PlaybackEngine.dailySourceTracksReleasedTransitionAndClearsRecovery") { t in
        do {
            let transitionURL = try makeTinyVideo(seconds: 2)
            defer { try? FileManager.default.removeItem(at: transitionURL) }
            let loopURL = try makeTinyVideo(seconds: 2)
            defer { try? FileManager.default.removeItem(at: loopURL) }
            let engine = PlaybackEngine()
            defer { engine.teardown() }
            let player = engine.videoLayer.player!

            engine.play(transitionURL: transitionURL, loopURL: loopURL)
            guard waitForPlayback({ engine.dailySourceURL == transitionURL && player.currentTime().seconds > 0.1 }) else {
                t.expect(false, "distinct transition is the actual initial daily source")
                return
            }
            guard waitForPlayback({ engine.dailySourceURL == loopURL }, timeout: 4) else {
                t.expect(false, "natural transition end reports its loop as the active source")
                return
            }
            t.expectEqual((player.currentItem?.asset as? AVURLAsset)?.url, loopURL,
                          "an ended transition is not reported as the loop's active source")

            engine.play(transitionURL: transitionURL, loopURL: loopURL)
            guard waitForPlayback({ engine.dailySourceURL == transitionURL && player.currentTime().seconds > 0.35 }),
                  let oldTransition = player.currentItem else {
                t.expect(false, "another transition has a nonzero position before release")
                return
            }
            engine.setVisualPaused(true)
            let pausedAt = player.currentTime().seconds
            t.expect(pausedAt > 0.3, "the recovery position can be distinguished from a fresh loop")
            // Exercise the engine's explicit release seam, not Agent version selection or
            // the policy's natural retention deadline. No still extraction is needed here.
            var released = false
            engine.releasePausedDaily(preservingFrame: false) { released = $0 }
            t.expect(released && !engine.hasVideoResources, "released transition has no video queue")
            t.expectEqual(engine.dailySourceURL, transitionURL,
                          "released source remains the actual transition, not its future loop")

            engine.stopVideo()
            t.expectNil(engine.dailySourceURL, "stop invalidates the resumable transition source")
            engine.play(transitionURL: nil, loopURL: loopURL)
            guard waitForPlayback({ player.currentItem?.status == .readyToPlay }), let freshLoop = player.currentItem else {
                t.expect(false, "same loop URL can be installed after discarding old recovery")
                return
            }
            t.expectEqual(engine.dailySourceURL, loopURL, "same loop URL does not restore the old transition")
            t.expectEqual((freshLoop.asset as? AVURLAsset)?.url, loopURL, "the actual replacement item is the loop")
            t.expectEqual(player.rate, 0, "discarding recovery preserves pause intent")
            t.expect(player.currentTime().seconds.isFinite && abs(player.currentTime().seconds) < 0.08,
                     "fresh paused loop must not inherit the transition's \(pausedAt)-second seek")
            NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: oldTransition)
            t.expect(player.currentItem === freshLoop && engine.dailySourceURL == loopURL,
                     "stale transition completion cannot replace the fresh paused loop")
            engine.setVisualPaused(false)
            t.expect(waitForPlayback { engine.dailySourceURL == loopURL && player.currentTime().seconds > 0.15 },
                     "explicit resume advances the correct loop")
        } catch { t.expect(false, "daily source recovery fixture failed: \(error)") }
    }
    run("PlaybackEngine.dailySourceEventsUseLatestPhaseAndIgnoreLoopReplicas") { t in
        do {
            let transitionURL = try makeTinyVideo(seconds: 2)
            defer { try? FileManager.default.removeItem(at: transitionURL) }
            let loopURL = try makeTinyVideo()
            defer { try? FileManager.default.removeItem(at: loopURL) }
            let engine = PlaybackEngine()
            defer {
                engine.onDailySourceChanged = nil
                engine.teardown()
            }
            let player = engine.videoLayer.player!
            var sources: [URL?] = []
            var callbacksOnMain = true
            engine.onDailySourceChanged = { [weak engine] in
                guard let engine else { return }
                callbacksOnMain = callbacksOnMain && Thread.isMainThread
                sources.append(engine.dailySourceURL)
            }

            engine.play(transitionURL: transitionURL, loopURL: loopURL)
            guard waitForPlayback({ sources.contains { $0 == transitionURL } && player.currentTime().seconds > 0.1 }) else {
                t.expect(false, "actual transition source is reported while it plays")
                return
            }
            guard waitForPlayback({ sources.contains { $0 == loopURL } }, timeout: 4),
                  let firstLoop = player.currentItem else {
                t.expect(false, "real natural transition end reports the target loop")
                return
            }
            t.expectEqual(sources.compactMap { $0 }, [transitionURL, loopURL],
                          "each actual daily phase is reported exactly once")
            let beforeReplica = sources.count
            t.expect(waitForPlayback { player.currentItem != nil && player.currentItem !== firstLoop },
                     "a duplicate loop replica actually becomes current")
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            t.expectEqual(sources.count, beforeReplica, "same-URL loop replicas do not republish the phase")

            engine.setVisualPaused(true)
            engine.play(transitionURL: transitionURL, loopURL: loopURL)
            guard waitForPlayback({ sources.last.map { $0 == transitionURL } == true }) else {
                t.expect(false, "replacement transition is observed before release")
                return
            }
            let beforeRelease = sources.count
            var released = false
            engine.releasePausedDaily(preservingFrame: false) { released = $0 }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            t.expect(released && engine.dailySourceURL == transitionURL && !engine.hasVideoResources,
                     "released transition remains the current resumable source")
            t.expectEqual(sources.count, beforeRelease, "releasing a source does not falsely report that it ended")
            engine.stopVideo()
            t.expect(waitForPlayback { sources.count > beforeRelease }, "stop reports an empty released source without item KVO")
            t.expectEqual(Array(sources.dropFirst(beforeRelease)), [nil], "stop reports the cleared source once")

            let beforeQueuedStop = sources.count
            engine.play(transitionURL: transitionURL, loopURL: loopURL)
            guard let obsoleteTransition = player.currentItem else {
                t.expect(false, "obsolete transition item exists before the immediate stop")
                return
            }
            // Do not pump the main queue between installation and stop: observations already
            // enqueued for that item must read the stopped engine, not a captured transition.
            engine.stopVideo()
            NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: obsoleteTransition)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            t.expectNil(engine.dailySourceURL, "queued old events leave the source stopped")
            t.expectEqual(sources.count, beforeQueuedStop, "obsolete item observations cannot resurrect a phase notification")

            engine.play(transitionURL: transitionURL, loopURL: loopURL)
            guard waitForPlayback({ sources.last.map { $0 == transitionURL } == true }) else {
                t.expect(false, "daily transition is observed before performance takeover")
                return
            }
            let beforePerformance = sources.count
            guard let replacedTransition = player.currentItem else {
                t.expect(false, "transition item exists before performance takeover")
                return
            }
            engine.playOnce(url: loopURL, onReady: {}, completion: { _ in })
            t.expect(waitForPlayback { sources.count > beforePerformance }, "performance takeover reports no daily source")
            NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: replacedTransition)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            t.expectEqual(Array(sources.dropFirst(beforePerformance)), [nil],
                          "performance and stale transition events do not advertise a daily loop")
            t.expect(callbacksOnMain, "all source callbacks run on the main thread")
        } catch { t.expect(false, "daily source event fixture failed: \(error)") }
    }
    run("PlaybackEngine.replacementsInvalidateDailyBoundary") { t in
        do {
            let url = try makeTinyVideo()
            defer { try? FileManager.default.removeItem(at: url) }
            let engine = PlaybackEngine()
            defer { engine.teardown() }
            let player = engine.videoLayer.player!
            engine.setVisualPaused(true)
            var calls = 0
            for replacement in 0..<3 {
                engine.play(transitionURL: nil, loopURL: url)
                guard waitForPlayback({ player.currentItem != nil }), let item = player.currentItem else {
                    t.expect(false, "paused replica available")
                    return
                }
                engine.finishCurrentDailyUnit { calls += 1 }
                if replacement == 0 {
                    engine.playOnce(url: url, onReady: {}, completion: { _ in })
                    t.expect(!engine.finishCurrentDailyUnit { calls += 1 }, "performance has no daily boundary")
                } else if replacement == 1 {
                    engine.stopVideo()
                } else {
                    engine.teardown()
                }
                let current = player.currentItem
                NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: item)
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                t.expect(player.currentItem === current, "old daily end cannot undo replacement \(replacement)")
            }
            t.expectEqual(calls, 0, "performance, stop and teardown invalidate daily callbacks")
        } catch { t.expect(false, "replacement boundary fixture failed: \(error)") }
    }
    run("PlaybackEngine.pausedColdStartUsesOnlyOneStill") { t in
        do {
            let url = try makeTinyVideo()
            defer { try? FileManager.default.removeItem(at: url) }
            let engine = PlaybackEngine()
            defer { engine.teardown() }
            engine.setVisualPaused(true)
            var installed: Bool?
            var cancelledCompletion = false
            engine.showDailyStill(loopURL: url) { _ in cancelledCompletion = true }
            engine.cancelPendingStill()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            t.expect(!cancelledCompletion && !engine.hasRetainedFrame && !engine.hasVideoResources,
                     "removing visual demand cancels a cold poster without installing it")
            engine.showDailyStill(loopURL: url) { installed = $0 }
            t.expect(waitForPlayback { installed != nil }, "cold poster finishes")
            t.expectEqual(installed, true, "valid first frame retained")
            t.expect(engine.hasRetainedFrame && !engine.hasVideoResources,
                     "paused cold start has a still and no video queue")
            engine.setVisualPaused(false)
            engine.play(transitionURL: nil, loopURL: url)
            t.expect(waitForPlayback { engine.videoLayer.player?.rate == 1 }, "leaving static mode starts ordinary video")
        } catch { t.expect(false, "cold poster fixture failed: \(error)") }
    }
    run("PlaybackEngine.dailyStillReleasesQueueAndRestoresPosition") { t in
        do {
            let url = try makeTinyVideo(seconds: 3)
            defer { try? FileManager.default.removeItem(at: url) }
            let engine = PlaybackEngine()
            defer { engine.teardown() }
            let player = engine.videoLayer.player!
            engine.play(transitionURL: nil, loopURL: url)
            t.expect(waitForPlayback { player.currentTime().seconds > 0.35 }, "real daily video advances")
            engine.setVisualPaused(true)
            let pausedAt = player.currentTime().seconds
            var released: Bool?
            engine.releasePausedDaily { released = $0 }
            t.expect(waitForPlayback { released != nil }, "one-frame extraction completes")
            t.expectEqual(released, true, "daily decoder released after retaining a frame")
            t.expect(engine.hasRetainedFrame, "paused desktop retains one image")
            t.expect(!engine.hasVideoResources && (player as? AVQueuePlayer)?.items().isEmpty == true,
                     "looper and all queued items released")
            t.expect(engine.videoLayer.player == nil, "layer releases the decoded player surface")
            engine.play(transitionURL: nil, loopURL: url)
            var releasedDuringSeek = false
            engine.releasePausedDaily(preservingFrame: false) { releasedDuringSeek = $0 }
            t.expect(releasedDuringSeek, "screen sleep can release while restoring")
            engine.play(transitionURL: nil, loopURL: url)
            engine.setVisualPaused(false)
            t.expectEqual(player.rate, 0, "resume while seek is pending keeps the seek barrier")
            engine.setVisualPaused(true)
            let restored = waitForPlayback { abs(player.currentTime().seconds - pausedAt) < 0.08 }
            t.expect(restored, "same loop resumes at retained position \(pausedAt), got \(player.currentTime().seconds)")
            t.expectEqual(player.rate, 0, "resource reconstruction preserves pause intent")
            engine.setVisualPaused(false)
            t.expect(waitForPlayback { player.currentTime().seconds > pausedAt + 0.15 }, "resume advances from that position")
        } catch { t.expect(false, "daily suspension fixture failed: \(error)") }
    }
    run("PlaybackEngine.explicitEntryPlaysToNaturalEndThenLoopsFromZero") { t in
        do {
            let url = try makeTinyVideo(seconds: 3)
            defer { try? FileManager.default.removeItem(at: url) }
            let engine = PlaybackEngine()
            defer { engine.teardown() }
            let player = engine.videoLayer.player!
            let entry = CMTime(value: 24, timescale: 12) // 2.0s into a 3s source
            engine.play(transitionURL: nil, loopURL: url, entryOffset: entry)
            guard waitForPlayback({ player.currentTime().seconds > 1.9 && player.rate > 0 }, timeout: 5),
                  let entryItem = player.currentItem else {
                t.expect(false, "explicit entry starts at its authored offset")
                return
            }
            t.expectEqual(engine.dailySourceURL, url, "the entry plays the full reviewed source")
            t.expect(player.currentTime().seconds >= 1.9, "entry resumes past its offset, not at zero")
            // A same-source explicit click is a NEW entry: it restarts the authored entry point.
            engine.play(transitionURL: nil, loopURL: url, entryOffset: entry)
            guard waitForPlayback({ player.currentItem !== entryItem && player.currentTime().seconds > 1.0 }),
                  let reentryItem = player.currentItem else {
                t.expect(false, "re-click reinstalls the same source at the entry offset")
                return
            }
            // Natural EOF: the entry item ends and the ordinary full-source loop installs from zero.
            NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: reentryItem)
            t.expect(waitForPlayback { player.currentItem !== reentryItem }, "entry EOF installs the loop")
            t.expect(waitForPlayback { player.currentTime().seconds < 1.0 },
                     "the loop restarts from zero, never the entry offset")
            t.expectEqual(engine.dailySourceURL, url, "the loop keeps the same reviewed source identity")
        } catch { t.expect(false, "explicit entry fixture failed: \(error)") }
    }
    run("PlaybackEngine.entryRespectsPauseAndIsNotReappliedOnResume") { t in
        do {
            let url = try makeTinyVideo(seconds: 3)
            defer { try? FileManager.default.removeItem(at: url) }
            let engine = PlaybackEngine()
            defer { engine.teardown() }
            let player = engine.videoLayer.player!
            let entry = CMTime(value: 24, timescale: 12)
            engine.setVisualPaused(true)
            engine.play(transitionURL: nil, loopURL: url, entryOffset: entry)
            t.expect(waitForPlayback { player.currentItem != nil }, "paused entry installs an item")
            t.expect(waitForPlayback { player.currentTime().seconds > 1.9 },
                     "paused entry prepares at the authored offset")
            t.expectEqual(player.rate, 0, "entry never starts media contrary to pause")
            engine.setVisualPaused(false)
            t.expect(waitForPlayback { player.rate > 0 && player.currentTime().seconds > 1.9 },
                     "resume advances from the entry position")
            engine.setVisualPaused(true)
            var released: Bool?
            engine.releasePausedDaily(preservingFrame: false) { released = $0 }
            t.expect(waitForPlayback { released != nil }, "release completes")
            // An ordinary resume restores the consumed position and must NOT reapply the entry.
            engine.play(transitionURL: nil, loopURL: url)
            t.expect(waitForPlayback { player.currentItem != nil }, "resume installs the source again")
            t.expect(waitForPlayback { player.currentTime().seconds > 1.0 },
                     "resume restores the consumed position, not the entry/zero")
            t.expectEqual(player.rate, 0, "pause intent survives the resume install")
        } catch { t.expect(false, "paused entry fixture failed: \(error)") }
    }
    run("PlaybackEngine.newExplicitEntrySupersedesSuspendedPosition") { t in
        do {
            let url = try makeTinyVideo(seconds: 4)
            defer { try? FileManager.default.removeItem(at: url) }
            let engine = PlaybackEngine()
            defer { engine.teardown() }
            let player = engine.videoLayer.player!
            // Establish and release a paused position near the start of the source.
            engine.play(transitionURL: nil, loopURL: url)
            t.expect(waitForPlayback { player.currentTime().seconds > 0.4 }, "ordinary source advances")
            engine.setVisualPaused(true)
            let oldPosition = player.currentTime().seconds
            t.expect(oldPosition < 1.5, "the released position is well before the new entry")
            var released: Bool?
            engine.releasePausedDaily(preservingFrame: false) { released = $0 }
            t.expect(waitForPlayback { released != nil }, "release completes")
            t.expectEqual(released, true, "paused source released while retaining its position")
            // A NEW explicit entry must win over the retained suspended position: resuming the old
            // point would silently ignore the click.
            let entry = CMTime(value: 3, timescale: 1) // 3.0s into a 4s source
            engine.play(transitionURL: nil, loopURL: url, entryOffset: entry)
            t.expect(waitForPlayback { player.currentItem != nil }, "explicit entry installs")
            t.expect(waitForPlayback { player.currentTime().seconds > 2.5 },
                     "entry prepares at 3.0s, not the released \(oldPosition)s")
            t.expectEqual(player.rate, 0, "pause intent survives the new entry install")
            engine.setVisualPaused(false)
            t.expect(waitForPlayback { player.rate > 0 && player.currentTime().seconds > 2.5 },
                     "resume continues from the NEW entry, never the suspended point")
        } catch { t.expect(false, "explicit supersede fixture failed: \(error)") }
    }
    run("PlaybackEngine.suspendedTransitionCompletesIntoLoop") { t in
        do {
            let url = try makeTinyVideo(seconds: 2)
            defer { try? FileManager.default.removeItem(at: url) }
            let engine = PlaybackEngine()
            defer { engine.teardown() }
            let player = engine.videoLayer.player!
            engine.play(transitionURL: url, loopURL: url)
            t.expect(waitForPlayback { player.currentTime().seconds > 0.2 }, "transition advances")
            engine.setVisualPaused(true)
            var released = false
            engine.releasePausedDaily(preservingFrame: false) { released = $0 }
            t.expect(released, "invisible transition releases without generating a frame")
            engine.play(transitionURL: nil, loopURL: url)
            t.expect(waitForPlayback { player.currentTime().seconds > 0.15 }, "transition position restored")
            let transitionItem = player.currentItem!
            NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: transitionItem)
            t.expect(waitForPlayback { player.currentItem !== transitionItem }, "restored transition still installs target loop")
            t.expectEqual(player.rate, 0, "transition completion preserves paused intent")
        } catch { t.expect(false, "transition fixture failed: \(error)") }
    }
    run("PlaybackEngine.obsoleteCaptureCannotReleaseReplacementOrResume") { t in
        do {
            let url = try makeTinyVideo(seconds: 2)
            defer { try? FileManager.default.removeItem(at: url) }
            let engine = PlaybackEngine()
            defer { engine.teardown() }
            let player = engine.videoLayer.player!
            engine.play(transitionURL: nil, loopURL: url)
            t.expect(waitForPlayback { player.currentTime().seconds > 0.1 }, "daily ready")
            engine.setVisualPaused(true)
            var obsoleteCompletions = 0
            engine.releasePausedDaily { _ in obsoleteCompletions += 1 }
            engine.stopVideo()
            engine.playOnce(url: url, onReady: {}, completion: { _ in })
            let replacement = player.currentItem
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
            t.expectEqual(obsoleteCompletions, 0, "obsolete capture must not complete")
            t.expect(player.currentItem === replacement && engine.hasVideoResources, "late still cannot release performance")
            t.expect(!engine.hasRetainedFrame, "obsolete still cannot cover new media")
            var released: Bool?
            engine.releasePausedDaily { released = $0 }
            t.expectEqual(released, false, "daily retention never releases a performance")
        } catch { t.expect(false, "capture cancellation fixture failed: \(error)") }
    }
    run("PlaybackEngine.pausedPlayReloadAndTransitionStayPaused") { t in
        do {
            let url = try makeTinyVideo()
            defer { try? FileManager.default.removeItem(at: url) }
            let engine = PlaybackEngine()
            defer {
                engine.teardown()
                // AVPlayerLooper may finish an internal disable asynchronously. Drain the main
                // queue before the next suite can construct another AVFoundation player.
                for _ in 0..<20 {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                }
            }
            let player = engine.videoLayer.player!

            engine.setVisualPaused(true)
            engine.play(transitionURL: url, loopURL: url)
            t.expect(waitForPlayback { player.currentItem != nil }, "paused play installs an item")
            t.expectEqual(player.rate, 0, "paused transition does not auto-play")

            guard let transitionItem = player.currentItem else {
                t.expect(false, "transition item is available for end notification")
                return
            }
            NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: transitionItem)
            t.expect(waitForPlayback({ player.currentItem !== transitionItem }, timeout: 1),
                      "transition end installs the loop item")
            t.expectEqual(player.rate, 0, "paused transition-to-loop remains paused")

            engine.play(transitionURL: nil, loopURL: url)
            t.expectEqual(player.rate, 0, "paused reload does not auto-play")

            engine.setVisualPaused(false)
            t.expect(waitForPlayback { player.rate > 0 }, "resume starts the reloaded loop")

            engine.play(transitionURL: url, loopURL: url)
            t.expect(waitForPlayback { player.rate > 0 }, "unpaused transition starts explicitly")

            engine.setVisualPaused(true)
            engine.setVisualPaused(true)
            engine.play(transitionURL: nil, loopURL: url)
            t.expectEqual(player.rate, 0, "repeated pause survives another reload")
        } catch {
            t.expect(false, "AVFoundation fixture failed: \(error)")
        }
    }
    run("PlaybackEngine.singleItemPauseEndAndObsoleteCallback") { t in
        do {
            let url = try makeTinyVideo()
            defer { try? FileManager.default.removeItem(at: url) }
            let engine = PlaybackEngine()
            defer { engine.teardown() }
            let player = engine.videoLayer.player!
            var ended = 0
            var errors = 0
            engine.setVisualPaused(true)
            engine.playOnce(url: url, onReady: {}, completion: { error in
                if error == nil { ended += 1 } else { errors += 1 }
            })
            let obsolete = player.currentItem!
            t.expectEqual(player.rate, 0, "single item respects pre-load pause")
            engine.stopVideo()
            engine.play(transitionURL: nil, loopURL: url)
            NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: obsolete)
            t.expectEqual(ended, 0, "stale end cannot stop restored daily")
            engine.playOnce(url: url, onReady: {}, completion: { error in
                if error == nil { ended += 1 } else { errors += 1 }
            })
            t.expectEqual(player.rate, 0, "second single remains paused")
            engine.setVisualPaused(false)
            t.expect(waitForPlayback({ ended == 1 }, timeout: 5), "real natural end fires once")
            t.expectEqual(errors, 0, "valid video did not fail")
            if let item = player.currentItem {
                NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: item)
            }
            t.expectEqual(ended, 1, "duplicate completion ignored")
        } catch { t.expect(false, "\(error)") }
    }

    run("PlaybackEngine.completedSingleRetainsFrameWithoutReplayOrWatchdog") { t in
        do {
            let url = try makeTinyVideo()
            defer { try? FileManager.default.removeItem(at: url) }
            let engine = PlaybackEngine()
            defer { engine.teardown() }
            let player = engine.videoLayer.player!
            var desired = DesiredState()
            desired.musicMuted = true
            let session = PerformanceSession(id: "eof-hold", variant: ResolvedPerformanceVariant(
                performanceID: PerformanceID("performance://eof-fixture"),
                variantID: PerformanceVariantID("variant://eof-fixture/daylight/side"),
                lighting: .daylight, presentation: .sidePerformance,
                catalogRevision: PerformanceCatalogRevision("eof-test"), reason: .explicitUserPreference),
                continuesQueue: true)
            let initial = PlaybackPolicy.evaluate(desired: desired, context: RuntimeContext(), performance: session)
            engine.setVisualPaused(initial.visual == .paused)
            engine.setMusicVolume(initial.musicVolume)
            var ended = 0
            var failures = 0
            var stalls = 0
            var waitingPolicy: EffectivePlaybackState?
            engine.onPlaybackStalled = { stalls += 1 }
            engine.playOnce(url: url, onReady: {}, completion: { error in
                guard error == nil else { failures += 1; return }
                ended += 1
                let policy = PlaybackPolicy.evaluate(desired: desired, context: RuntimeContext(),
                    performance: session, performanceAwaitingNext: true)
                waitingPolicy = policy
                engine.setVisualPaused(policy.performancePaused)
                engine.setMusicVolume(policy.musicVolume)
            })
            guard let item = player.currentItem else {
                t.expect(false, "performance item is installed")
                return
            }
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ])
            item.add(output)
            t.expect(waitForPlayback({ ended == 1 }, timeout: 5), "real natural EOF enters the policy hold")
            t.expectEqual(failures, 0, "valid single item reaches EOF without failure")
            t.expectEqual(waitingPolicy?.visual, .full, "Core leaves independent daily visuals running during queue handoff")
            t.expectEqual(waitingPolicy?.performancePaused, true, "Core pauses the completed performance clock")
            t.expectEqual(waitingPolicy?.musicVolume, 0, "Core mutes the waiting performance")
            t.expectEqual(waitingPolicy?.ambientVolume, 0, "Core continues suppressing ambient during handoff")
            t.expect(player.currentItem === item && engine.hasVideoResources,
                     "EOF retains the actual completed item")
            t.expect(engine.videoLayer.player === player, "EOF keeps its player attached to the display layer")
            t.expect(item.currentTime().seconds >= 0.9, "retained item reached its true end")
            var frameTime = CMTime.invalid
            let frame = output.copyPixelBuffer(forItemTime: CMTime(value: 23, timescale: 24),
                                               itemTimeForDisplay: &frameTime)
            t.expectNotNil(frame, "the last decoded frame remains available after real EOF")
            if let frame {
                t.expectEqual(CVPixelBufferGetWidth(frame), 16, "retained frame comes from the tiny fixture")
                t.expectNear(frameTime.seconds, 11.0 / 12.0, "retained frame is the final video sample", eps: 0.01)
            }
            NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: item)
            NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: item)

            // A replacement's policy intent can arrive before its item installation. Resuming
            // that intent cannot turn the consumed previous item into a new playback lifecycle.
            let nextSession = PerformanceSession(id: "eof-next", target: session.target, continuesQueue: true)
            let nextPolicy = PlaybackPolicy.evaluate(desired: desired, context: RuntimeContext(), performance: nextSession)
            engine.setVisualPaused(nextPolicy.performancePaused)
            engine.setMusicVolume(nextPolicy.musicVolume)
            let finishedTime = item.currentTime().seconds
            t.expectEqual(player.rate, 0, "new policy intent cannot replay an already-consumed item")
            // Exercise the real eight-second waiting deadline, including its tolerance, so a
            // stale KVO-rearmed timer would be observed. No system state or power sampling.
            RunLoop.main.run(until: Date().addingTimeInterval(9))
            t.expectEqual(stalls, 0, "EOF and late KVO do not arm a stall watchdog for the completed item")
            t.expectEqual(ended, 1, "old EOF remains consumed exactly once")
            t.expectEqual(failures, 0, "late failure notifications cannot fail the completed item")
            t.expect(player.currentItem === item && engine.hasVideoResources, "handoff hold retains the same final item")
            t.expectNear(item.currentTime().seconds, finishedTime, "completed clock remains stopped", eps: 0.025)

            var nextReady = 0
            var nextEnded = 0
            engine.playOnce(url: url, onReady: { nextReady += 1 }, completion: { _ in nextEnded += 1 })
            let nextItem = player.currentItem
            t.expect(nextItem !== item, "installing the next song creates its own item lifecycle")
            t.expect(waitForPlayback { nextReady == 1 && player.currentTime().seconds > 0.1 },
                     "completed-item protection clears for a real next installation")
            NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: item)
            t.expectEqual(nextEnded, 0, "old EOF cannot complete the next song")
            engine.stopVideo()
            t.expect(!engine.hasVideoResources && player.currentItem == nil, "stop releases the held or replacement item")
        } catch { t.expect(false, "EOF hold fixture failed: \(error)") }
    }
    run("PlaybackEngine.transitionFrameHoldCoversInstallThenReleasesForReadyLoop") { t in
        do {
            let transitionURL = try makeTinyVideo(seconds: 2)
            defer { try? FileManager.default.removeItem(at: transitionURL) }
            let loopURL = try makeTinyVideo(seconds: 2)
            defer { try? FileManager.default.removeItem(at: loopURL) }
            let engine = PlaybackEngine()
            defer { engine.teardown() }
            let player = engine.videoLayer.player!

            engine.play(transitionURL: transitionURL, loopURL: loopURL)
            guard waitForPlayback({ player.currentTime().seconds > 0.2 }) else {
                t.expect(false, "transition starts before its hold fixture")
                return
            }
            t.expect(!engine.hasRetainedFrame, "a playing transition installs no still")
            var heldDuringOwnerCallback = false
            var boundaryItem: AVPlayerItem?
            engine.finishCurrentDailyUnit {
                heldDuringOwnerCallback = engine.hasRetainedFrame
                boundaryItem = player.currentItem
            }
            t.expect(waitForPlayback({ boundaryItem != nil }, timeout: 6),
                     "natural transition end reaches the owner boundary")
            // The hold is the transition's actual final frame, installed before the owner's
            // boundary callback so it is already the displayed picture when the loop item
            // replaces the transition.
            t.expect(heldDuringOwnerCallback, "natural EOF boundary callback observes the transition frame hold")
            t.expect(waitForPlayback { player.currentItem != nil && player.currentItem !== boundaryItem },
                     "transition end installs the loop replacement")
            t.expect(waitForPlayback { !engine.hasRetainedFrame },
                     "the hold releases once the replacement is ready, not indefinitely")
            t.expect(waitForPlayback { player.currentTime().seconds > 0.15 },
                     "the ready loop advances under the released hold")
        } catch { t.expect(false, "transition frame hold fixture failed: \(error)") }
    }
    run("PlaybackEngine.transitionFrameHoldCannotSurviveOwnerStopOrRetarget") { t in
        do {
            let transitionURL = try makeTinyVideo(seconds: 2)
            defer { try? FileManager.default.removeItem(at: transitionURL) }
            let loopURL = try makeTinyVideo(seconds: 2)
            defer { try? FileManager.default.removeItem(at: loopURL) }
            let engine = PlaybackEngine()
            defer { engine.teardown() }
            let player = engine.videoLayer.player!

            engine.play(transitionURL: transitionURL, loopURL: loopURL)
            guard waitForPlayback({ player.currentTime().seconds > 0.2 }), let firstTransition = player.currentItem else {
                t.expect(false, "first transition starts")
                return
            }
            engine.finishCurrentDailyUnit { engine.stopVideo() }
            NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: firstTransition)
            t.expect(!engine.hasVideoResources && !engine.hasRetainedFrame,
                     "owner stop clears the held transition frame with the queue")
            t.expectNil(engine.dailySourceURL, "owner stop leaves no daily source after the hold")

            engine.play(transitionURL: transitionURL, loopURL: loopURL)
            guard waitForPlayback({ player.currentTime().seconds > 0.2 }), let secondTransition = player.currentItem else {
                t.expect(false, "retarget transition starts")
                return
            }
            engine.finishCurrentDailyUnit { engine.play(transitionURL: nil, loopURL: loopURL) }
            NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: secondTransition)
            t.expect(waitForPlayback {
                (player.currentItem?.asset as? AVURLAsset)?.url == loopURL && player.currentItem !== secondTransition
            }, "owner EOF callback still wins with its own replacement loop")
            t.expect(!engine.hasRetainedFrame, "old transition hold cannot cover the owner replacement")
            t.expect(waitForPlayback { player.currentTime().seconds > 0.1 }, "owner replacement advances")
            NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: secondTransition)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            t.expect(!engine.hasRetainedFrame, "stale transition end cannot revive the old hold")
        } catch { t.expect(false, "transition hold ownership fixture failed: \(error)") }
    }
    run("PlaybackEngine.explicitReplacementHoldsActualOutgoingFrameUntilReady") { t in
        do {
            // Frame 0 is black and every later frame is white, so a hold taken from the outgoing
            // item's real displayed frame is bright, while a blank or source-frame-zero poster
            // would be dark.
            let outgoingURL = try makeTinyVideo(seconds: 2, frameFill: { $0 == 0 ? 0x00 : 0xFF })
            defer { try? FileManager.default.removeItem(at: outgoingURL) }
            let replacementURL = try makeTinyVideo(seconds: 2)
            defer { try? FileManager.default.removeItem(at: replacementURL) }
            let engine = PlaybackEngine()
            defer { engine.teardown() }
            let player = engine.videoLayer.player!

            engine.play(transitionURL: nil, loopURL: outgoingURL)
            guard waitForPlayback({ player.currentTime().seconds > 0.5 }), let outgoingItem = player.currentItem else {
                t.expect(false, "outgoing daily loop advances before replacement")
                return
            }
            // The replica frame output is attached as the current item turns over on the main queue.
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            t.expect(!engine.hasRetainedFrame, "an ordinarily playing loop installs no still")

            engine.play(transitionURL: replacementURL, loopURL: replacementURL)
            // The explicit replacement is synchronous, so the still must already cover the swap.
            t.expect(player.currentItem !== outgoingItem, "explicit replacement installs its own item")
            t.expect(engine.hasRetainedFrame, "explicit replacement holds the outgoing frame across the swap")
            if let image = retainedStillImage(of: engine) {
                let luminance = averageLuminance(image)
                t.expect(luminance > 150,
                         "the hold is the outgoing item's real current frame, not black or frame 0, got \(luminance)")
            } else {
                t.expect(false, "the held still exposes the outgoing item's decoded pixels")
            }
            t.expect(waitForPlayback { !engine.hasRetainedFrame },
                     "the hold releases once the replacement item is actually ready")
            t.expect(waitForPlayback { player.currentTime().seconds > 0.15 },
                     "the replacement advances under the released hold")
        } catch { t.expect(false, "explicit replacement hold fixture failed: \(error)") }
    }
    run("PlaybackEngine.explicitReplacementHoldClearsOnStopAndFailedInstall") { t in
        do {
            let outgoingURL = try makeTinyVideo(seconds: 2)
            defer { try? FileManager.default.removeItem(at: outgoingURL) }
            let replacementURL = try makeTinyVideo(seconds: 2)
            defer { try? FileManager.default.removeItem(at: replacementURL) }
            let brokenURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("bsidemac-playback-broken-\(UUID().uuidString).mp4")
            try Data("not a video".utf8).write(to: brokenURL)
            defer { try? FileManager.default.removeItem(at: brokenURL) }
            let engine = PlaybackEngine()
            defer { engine.teardown() }
            let player = engine.videoLayer.player!

            engine.play(transitionURL: nil, loopURL: outgoingURL)
            guard waitForPlayback({ player.currentTime().seconds > 0.5 }) else {
                t.expect(false, "outgoing daily starts before the stop check")
                return
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            engine.play(transitionURL: replacementURL, loopURL: replacementURL)
            t.expect(engine.hasRetainedFrame, "replacement installs a handoff still first")
            engine.stopVideo()
            t.expect(!engine.hasRetainedFrame && !engine.hasVideoResources,
                     "stop clears the handoff still with the released queue")
            t.expectNil(engine.dailySourceURL, "stop leaves no daily source after the handoff")

            engine.play(transitionURL: nil, loopURL: outgoingURL)
            guard waitForPlayback({ player.currentTime().seconds > 0.5 }) else {
                t.expect(false, "outgoing daily restarts before the failed install")
                return
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            engine.play(transitionURL: brokenURL, loopURL: replacementURL)
            t.expect(engine.hasRetainedFrame, "a broken replacement still hands off the prior frame")
            t.expect(waitForPlayback({ !engine.hasRetainedFrame }, timeout: 5),
                     "a failed replacement releases the stale handoff surface")
        } catch { t.expect(false, "replacement hold cleanup fixture failed: \(error)") }
    }
    run("PlaybackEngine.replacementFrameHoldSurvivesStopUntilSuccessorReady") { t in
        do {
            // Frame 0 is black, every later frame white: the replacement hold must expose the
            // outgoing unit's real current frame, not a blank layer or a frame-zero poster.
            let outgoingURL = try makeTinyVideo(seconds: 2, frameFill: { $0 == 0 ? 0x00 : 0xFF })
            defer { try? FileManager.default.removeItem(at: outgoingURL) }
            let replacementURL = try makeTinyVideo(seconds: 2)
            defer { try? FileManager.default.removeItem(at: replacementURL) }
            let engine = PlaybackEngine()
            defer { engine.teardown() }
            let player = engine.videoLayer.player!

            engine.play(transitionURL: nil, loopURL: outgoingURL)
            guard waitForPlayback({ player.currentTime().seconds > 0.5 }) else {
                t.expect(false, "outgoing daily advances before the replacement hold")
                return
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            t.expect(!engine.hasRetainedFrame, "an ordinarily playing loop installs no still")

            // Exact production order: retain, then release the queue for async validation.
            engine.retainDisplayedFrameForReplacement()
            t.expect(engine.hasRetainedFrame, "owner retention installs the outgoing source frame")
            engine.stopVideo()
            t.expect(engine.hasRetainedFrame, "the retained frame survives the queue release")
            t.expect(!engine.hasVideoResources && engine.dailySourceURL == nil,
                     "video/audio resources are still released promptly under the hold")
            if let image = retainedStillImage(of: engine) {
                let luminance = averageLuminance(image)
                t.expect(luminance > 150,
                         "the hold is the outgoing item's real frame, not black, got \(luminance)")
            } else {
                t.expect(false, "the replacement hold exposes decoded pixels")
            }

            // A superseding start re-retains without recapturing, then the successor installs.
            engine.retainDisplayedFrameForReplacement()
            engine.stopVideo()
            t.expect(engine.hasRetainedFrame, "a superseding start keeps one retained surface")
            engine.play(transitionURL: nil, loopURL: replacementURL)
            t.expect(waitForPlayback { !engine.hasRetainedFrame },
                     "the hold releases once the replacement item is actually ready")
            t.expect(waitForPlayback({ player.currentTime().seconds > 0.15 }),
                     "the replacement daily advances under the released hold")
        } catch { t.expect(false, "replacement frame hold fixture failed: \(error)") }
    }
    run("PlaybackEngine.pausedReleasedDailyStillSurvivesWatchReplacement") { t in
        do {
            let dailyURL = try makeTinyVideo(seconds: 2, frameFill: { _ in 0xFF })
            defer { try? FileManager.default.removeItem(at: dailyURL) }
            let watchURL = try makeDelayedFirstFrameVideo(leadingDelay: 1.0, seconds: 2)
            defer { try? FileManager.default.removeItem(at: watchURL) }
            let engine = PlaybackEngine()
            defer { engine.teardown() }
            let player = engine.videoObservationPlayer
            engine.setVisualPaused(true)
            var installed: Bool?
            engine.showDailyStill(loopURL: dailyURL) { installed = $0 }
            guard waitForPlayback({ installed != nil }), installed == true else {
                return t.expect(false, "paused daily fixture installs its actual retained image")
            }
            t.expect(engine.videoLayer.player == nil && !engine.hasVideoResources,
                     "paused daily has released its player item before Watch starts")
            engine.retainDisplayedFrameForReplacement()
            engine.stopVideo()
            engine.setWatchMirrorEnabled(true)
            t.expect(engine.hasRetainedFrame, "queue release preserves the existing paused daily image")
            let mirrorImage = engine.watchVideoLayer.sublayers?.compactMap { $0.contents }.first
            if let image = mirrorImage {
                t.expect(averageLuminance(image as! CGImage) > 150,
                         "the Watch surface shares the valid bright predecessor image")
            } else { t.expect(false, "Watch owns the retained image before any incoming item is ready") }

            var firstReady = false
            var firstFinished = false
            engine.playOnce(url: watchURL, onReady: { firstReady = true },
                            completion: { _ in firstFinished = true })
            t.expect(waitForPlayback { firstReady }, "a globally paused Watch item can become ready")
            t.expect(player.rate == 0 && engine.hasRetainedFrame,
                     "item readiness neither clears pause nor releases the cover without a decoded frame")
            let oldItem = player.currentItem!
            engine.retainDisplayedFrameForReplacement()
            engine.stopVideo()
            var successorReady = false
            var successorFinished = false
            engine.playOnce(url: watchURL, onReady: { successorReady = true },
                            completion: { _ in successorFinished = true })
            NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: oldItem)
            t.expect(waitForPlayback { successorReady }, "the replacement becomes ready under the same pause")
            t.expect(!firstFinished && !successorFinished && engine.hasRetainedFrame
                     && engine.watchVideoLayer.sublayers?.contains(where: { $0.contents != nil }) == true,
                     "stale predecessor completion cannot retire the new item's mirrored cover")
            engine.setVisualPaused(false)
            t.expect(waitForPlayback({ !engine.hasRetainedFrame }, timeout: 5),
                     "resume acquires the incoming item's real frame and releases the predecessor")
            t.expect(engine.watchVideoLayer.sublayers?.allSatisfy { $0.contents == nil } != false,
                     "the same first-frame boundary clears the Watch cover")
            t.expect(player.rate > 0, "resume keeps the shared player advancing")
            engine.setWatchMirrorEnabled(false)
            t.expect(engine.watchVideoLayer.player == nil,
                     "ending Watch detaches its mirror without adding another playback clock")
        } catch { t.expect(false, "paused daily to Watch fixture failed: \(error)") }
    }
    run("PlaybackEngine.replacementHoldWaitsForIncomingItemsOwnDecodedFrame") { t in
        do {
            // Real entry shape from the native capture: a daily loop is retained for a watch
            // performance and the incoming single item starts under that retained surface. The
            // incoming fixture withholds its first displayable sample, so readiness, layer
            // readiness and new-output flags can all be present while copyPixelBuffer still returns
            // nothing — the nil-after-new-data shape the native diagnostic capture showed.
            let outgoingURL = try makeTinyVideo(seconds: 2, codec: .hevc,
                                                frameFill: { $0 == 0 ? 0x00 : 0xFF })
            defer { try? FileManager.default.removeItem(at: outgoingURL) }
            let delayedURL = try makeDelayedFirstFrameVideo(leadingDelay: 1.0, seconds: 2)
            defer { try? FileManager.default.removeItem(at: delayedURL) }
            let engine = PlaybackEngine()
            defer { engine.teardown() }
            let player = engine.videoLayer.player!

            engine.play(transitionURL: nil, loopURL: outgoingURL)
            guard waitForPlayback({ player.currentTime().seconds > 0.5 }) else {
                t.expect(false, "outgoing HEVC daily advances before the replacement")
                return
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            engine.retainDisplayedFrameForReplacement()
            engine.stopVideo()
            t.expect(engine.hasRetainedFrame, "the outgoing frame is retained across the queue release")
            if let image = retainedStillImage(of: engine) {
                t.expect(averageLuminance(image) > 150,
                         "the hold carries the outgoing item's real pixels, not black")
            } else {
                t.expect(false, "the replacement hold exposes decoded pixels")
            }

            // Unpaused install: the latest policy request advances the incoming item under the
            // retained predecessor, and the predecessor is replaced only once this exact item has
            // vended a retained non-null frame.
            var incomingReady = false
            var sourceReady = false
            var coverSafeAtSourceReady = false
            engine.playOnce(url: delayedURL, onReady: { incomingReady = true }, onSourceFrameReady: {
                sourceReady = true
                coverSafeAtSourceReady = engine.videoLayer.isReadyForDisplay || engine.hasRetainedFrame
            }, completion: { _ in })
            let incoming = player.currentItem
            t.expect(incoming != nil, "the replacement installs its incoming item")
            t.expect(engine.hasRetainedFrame, "the retained predecessor covers the incoming install")
            t.expect(waitForPlayback { incomingReady }, "the incoming item loads and reports ready")
            t.expect(incoming?.status == .readyToPlay, "the incoming item is ready")
            t.expect(waitForPlayback {
                guard let time = incoming?.currentTime().seconds else { return false }
                return player.rate > 0 && time > 0.2 && time < 0.9
            }, "the incoming item advances under the retained predecessor")
            t.expect(engine.hasRetainedFrame,
                     "readiness alone never removes the cover while no frame is displayable")
            t.expect(waitForPlayback { !engine.hasRetainedFrame },
                     "the cover is replaced once the item's own non-null frame is copied")
            t.expect(player.currentItem === incoming && engine.hasVideoResources,
                     "the incoming item stays installed after the cover is replaced")
            t.expect(sourceReady && coverSafeAtSourceReady,
                     "source readiness never removes a predecessor before layer composition")
            t.expect(waitForPlayback({ player.currentTime().seconds > 1.1 }),
                     "the revealed incoming item keeps advancing")

            // A policy-paused install is the sharpest case: the pause transition permits exactly
            // one attempt, a nil result leaves the request pending-paused behind the cover with no
            // sampler and no hidden clock advancement, and Resume finishes it with the remaining
            // startup budget.
            engine.retainDisplayedFrameForReplacement()
            engine.stopVideo()
            t.expect(engine.hasRetainedFrame, "a paused replacement retains its outgoing frame")
            engine.setVisualPaused(true)
            var pausedReady = false
            engine.playOnce(url: delayedURL, onReady: { pausedReady = true }, completion: { _ in })
            let pausedIncoming = player.currentItem
            t.expect(waitForPlayback { pausedReady }, "the paused incoming item still loads")
            t.expect(engine.hasRetainedFrame,
                     "a paused request with no displayable frame stays behind the cover")
            t.expectEqual(player.rate, 0, "the paused incoming item remains paused")
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            t.expect(engine.hasRetainedFrame,
                     "no sampler keeps running while the request is paused")
            t.expect((pausedIncoming?.currentTime().seconds ?? 1) < 0.1,
                     "a paused acquisition never advances the clock secretly")
            engine.setVisualPaused(false)
            t.expect(waitForPlayback({ !engine.hasRetainedFrame && player.rate > 0 }, timeout: 4),
                     "Resume completes the acquisition with the remaining startup budget")
            t.expect(player.currentItem === pausedIncoming && engine.hasVideoResources,
                     "the resumed incoming item stays installed")
            t.expect(waitForPlayback({ player.rate > 0 && player.currentTime().seconds > 1.1 }),
                     "the resumed incoming item advances")

            // Explicit cancellation clears a still-pending replacement hold without releasing the
            // installed incoming item.
            engine.setVisualPaused(true)
            engine.retainDisplayedFrameForReplacement()
            engine.stopVideo()
            engine.playOnce(url: delayedURL, onReady: {}, completion: { _ in })
            t.expect(engine.hasRetainedFrame, "a pending replacement hold is present before discard")
            engine.discardDisplayedFrameHold()
            t.expect(!engine.hasRetainedFrame, "an explicit discard clears a pending replacement hold")
            t.expect(engine.hasVideoResources, "discarding the hold does not release the incoming item")
            engine.setVisualPaused(false)
        } catch { t.expect(false, "replacement first-frame fixture failed: \(error)") }
    }
    run("PlaybackEngine.incomingAcquisitionFailsBeforeEOFAndRetiresOnReplacement") { t in
        do {
            let outgoingURL = try makeTinyVideo(seconds: 2, frameFill: { $0 == 0 ? 0x00 : 0xFF })
            defer { try? FileManager.default.removeItem(at: outgoingURL) }
            // The retired item's first frame is available sooner than its successor's, so a leaked
            // callback would visibly reveal the successor if the generation guard failed.
            let retiredURL = try makeDelayedFirstFrameVideo(leadingDelay: 2.0, seconds: 2)
            defer { try? FileManager.default.removeItem(at: retiredURL) }
            let successorURL = try makeDelayedFirstFrameVideo(leadingDelay: 3.0, seconds: 2)
            defer { try? FileManager.default.removeItem(at: successorURL) }
            let engine = PlaybackEngine()
            defer { engine.teardown() }
            let player = engine.videoLayer.player!

            engine.play(transitionURL: nil, loopURL: outgoingURL)
            guard waitForPlayback({ player.currentTime().seconds > 0.4 }) else {
                t.expect(false, "outgoing daily advances before the acquisition lifetime checks")
                return
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))

            // EOF before the incoming item ever vended a frame is not a successful held freeze: the
            // acquisition failure is reported through the existing owner completion path.
            engine.retainDisplayedFrameForReplacement()
            engine.stopVideo()
            var eofFailed = false
            engine.playOnce(url: successorURL, onReady: {}, completion: { if $0 != nil { eofFailed = true } })
            guard let pendingItem = player.currentItem else {
                t.expect(false, "the pending incoming item is installed")
                return
            }
            t.expect(engine.hasRetainedFrame, "the pending acquisition starts behind the cover")
            NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: pendingItem)
            t.expect(eofFailed, "EOF before acquisition reports failure, not a frozen success")
            t.expect(!engine.hasRetainedFrame,
                     "the EOF-before-acquisition failure releases the cover through the owner path")

            // Replacement lifetime: the retired acquisition must not reveal its successor's cover.
            engine.play(transitionURL: nil, loopURL: outgoingURL)
            guard waitForPlayback({ player.currentTime().seconds > 0.3 }) else {
                t.expect(false, "outgoing daily restarts before the replacement lifetime check")
                return
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            engine.retainDisplayedFrameForReplacement()
            engine.stopVideo()
            var retiredOutcome: String?
            engine.playOnce(url: retiredURL, onReady: {}, completion: { retiredOutcome = $0 ?? "ended" })
            t.expect(engine.hasRetainedFrame, "the first pending acquisition keeps its cover")
            engine.retainDisplayedFrameForReplacement()
            engine.stopVideo()
            engine.playOnce(url: successorURL, onReady: {}, completion: { _ in })
            t.expect(engine.hasRetainedFrame, "the successor installs behind the same retained cover")
            RunLoop.main.run(until: Date().addingTimeInterval(2.4))
            t.expect(engine.hasRetainedFrame,
                     "the retired acquisition cannot reveal the successor's cover")
            t.expect(retiredOutcome == nil, "a replaced acquisition reports no success")
            t.expect(waitForPlayback { !engine.hasRetainedFrame },
                     "the successor reveals only on its own non-null frame")

            // Teardown with a live acquisition retires it without a late resurrection.
            engine.retainDisplayedFrameForReplacement()
            engine.stopVideo()
            engine.playOnce(url: successorURL, onReady: {}, completion: { _ in })
            t.expect(engine.hasRetainedFrame, "the teardown check starts from a pending acquisition")
            engine.teardown()
            t.expect(!engine.hasRetainedFrame, "teardown retires a pending acquisition and its cover")
            RunLoop.main.run(until: Date().addingTimeInterval(1.5))
            t.expect(!engine.hasRetainedFrame,
                     "no retired acquisition callback resurrects a cover after teardown")
        } catch { t.expect(false, "acquisition lifetime fixture failed: \(error)") }
    }
    run("PlaybackEngine.incomingAcquisitionBudgetBoundsAnItemThatNeverVendsAFrame") { t in
        do {
            let outgoingURL = try makeTinyVideo(seconds: 2, frameFill: { $0 == 0 ? 0x00 : 0xFF })
            defer { try? FileManager.default.removeItem(at: outgoingURL) }
            // The first displayable sample lies far beyond the bounded acquisition budget, so the
            // active request must report failure instead of holding a frozen cover indefinitely.
            let neverURL = try makeDelayedFirstFrameVideo(leadingDelay: 10.0, seconds: 1)
            defer { try? FileManager.default.removeItem(at: neverURL) }
            let engine = PlaybackEngine()
            defer { engine.teardown() }
            let player = engine.videoLayer.player!

            engine.play(transitionURL: nil, loopURL: outgoingURL)
            guard waitForPlayback({ player.currentTime().seconds > 0.4 }) else {
                t.expect(false, "outgoing daily advances before the acquisition budget check")
                return
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            engine.retainDisplayedFrameForReplacement()
            engine.stopVideo()
            var timeoutError: String?
            var completed = false
            engine.playOnce(url: neverURL, onReady: {}, completion: { timeoutError = $0; completed = true })
            t.expect(engine.hasRetainedFrame, "the retained predecessor covers the never-vending item")
            t.expect(waitForPlayback({ completed }, timeout: 11),
                     "the bounded acquisition budget reports failure instead of holding forever")
            t.expect(timeoutError != nil, "the acquisition timeout reports a non-nil owner error")
            t.expect(!engine.hasRetainedFrame,
                     "the existing failure path releases the cover instead of freezing it")
        } catch { t.expect(false, "acquisition budget fixture failed: \(error)") }
    }
    run("PlaybackEngine.queuedRetiredRefreshCannotTouchSuccessorHandoff") { t in
        do {
            // Both incoming fixtures withhold their first displayable sample behind an empty
            // leading edit, so the retired acquisition is still pending when its own queued
            // display-refresh sample is left behind by the replacement. That queued block is the
            // stale refresh: it was created for the retired acquisition, but both mutable
            // generations match again once the successor is armed.
            let outgoingURL = try makeTinyVideo(seconds: 2, frameFill: { $0 == 0 ? 0x00 : 0xFF })
            defer { try? FileManager.default.removeItem(at: outgoingURL) }
            let retiredURL = try makeDelayedFirstFrameVideo(leadingDelay: 2.0, seconds: 2)
            defer { try? FileManager.default.removeItem(at: retiredURL) }
            let successorURL = try makeDelayedFirstFrameVideo(leadingDelay: 1.0, seconds: 2)
            defer { try? FileManager.default.removeItem(at: successorURL) }
            let engine = PlaybackEngine()
            defer { engine.teardown() }
            let player = engine.videoLayer.player!

            engine.play(transitionURL: nil, loopURL: outgoingURL)
            guard waitForPlayback({ player.currentTime().seconds > 0.4 }) else {
                t.expect(false, "outgoing daily advances before the queued-refresh check")
                return
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))

            engine.retainDisplayedFrameForReplacement()
            engine.stopVideo()
            var retiredFinished = false
            var retiredError: String?
            engine.playOnce(url: retiredURL, onReady: {}, completion: { retiredError = $0; retiredFinished = true })
            guard let retiredItem = player.currentItem else {
                t.expect(false, "the retired acquisition's item is installed")
                return
            }
            t.expect(waitForPlayback { retiredItem.status == .readyToPlay },
                     "the retired acquisition's item loads and reports ready")
            // Keep the main thread busy so the retired acquisition's display-refresh retry really
            // has a main-thread sample queued (coalesced to at most one) before the successor
            // replaces it; that is the ordering the identity capture must survive.
            Thread.sleep(forTimeInterval: 0.1)

            engine.retainDisplayedFrameForReplacement()
            engine.stopVideo()
            var successorFinished = false
            var successorError: String?
            engine.playOnce(url: successorURL, onReady: {}, completion: { successorError = $0; successorFinished = true })
            guard let successorItem = player.currentItem else {
                t.expect(false, "the successor item is installed")
                return
            }
            t.expect(successorItem !== retiredItem, "the successor replaces the retired item")
            t.expect(engine.hasRetainedFrame, "the successor installs behind the retained cover")

            // The retired acquisition's queued refresh now runs against the successor. It must not
            // reveal the successor's cover (the successor still has no displayable frame), must not
            // fail the successor through the retired handler, and must leave the successor's own
            // sampling able to finish the handoff.
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            t.expect(engine.hasRetainedFrame,
                     "a queued retired refresh cannot reveal the successor's cover")
            t.expect(!successorFinished,
                     "a queued retired refresh cannot fail the successor's acquisition")
            t.expect(!retiredFinished && retiredError == nil,
                     "the retired acquisition stays silent after its refresh is queued")
            t.expect(waitForPlayback({ !engine.hasRetainedFrame }, timeout: 4),
                     "the successor reveals only on its own copied frame")
            t.expect(!successorFinished && successorError == nil,
                     "the successor acquisition completes on its own copy, not a retired failure")
            t.expect(player.currentItem === successorItem && engine.hasVideoResources,
                     "the successor item stays installed after its own reveal")
            t.expect(waitForPlayback({ player.rate > 0 && player.currentTime().seconds > 1.1 }),
                     "the successor keeps advancing after the queued retired refresh")
        } catch { t.expect(false, "queued retired refresh fixture failed: \(error)") }
    }
    run("PlaybackEngine.replacementFrameHoldClearsOnFailedTargetAndDiscard") { t in
        do {
            let outgoingURL = try makeTinyVideo(seconds: 2)
            defer { try? FileManager.default.removeItem(at: outgoingURL) }
            let brokenURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("bsidemac-playback-broken-\(UUID().uuidString).mp4")
            try Data("not a video".utf8).write(to: brokenURL)
            defer { try? FileManager.default.removeItem(at: brokenURL) }
            let engine = PlaybackEngine()
            defer { engine.teardown() }
            let player = engine.videoLayer.player!

            engine.play(transitionURL: nil, loopURL: outgoingURL)
            guard waitForPlayback({ player.currentTime().seconds > 0.5 }) else {
                t.expect(false, "outgoing daily advances before the failed target")
                return
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            engine.retainDisplayedFrameForReplacement()
            engine.stopVideo()
            t.expect(engine.hasRetainedFrame, "the replacement hold covers the failed target start")
            var dailyFailed = false
            engine.onDailyLoadFailed = { _ in dailyFailed = true }
            engine.play(transitionURL: nil, loopURL: brokenURL)
            t.expect(waitForPlayback({ dailyFailed }, timeout: 5),
                     "malformed daily successor reports actual looper failure")
            t.expect(!engine.hasRetainedFrame,
                     "failed daily load clears its hold even without a current item")

            engine.play(transitionURL: nil, loopURL: outgoingURL)
            guard waitForPlayback({ player.currentTime().seconds > 0.3 }) else {
                t.expect(false, "daily recovers before the failed single target")
                return
            }
            engine.retainDisplayedFrameForReplacement()
            engine.stopVideo()
            engine.playOnce(url: brokenURL, onReady: {}, completion: { _ in })
            t.expect(waitForPlayback({ !engine.hasRetainedFrame }, timeout: 5),
                     "a failed replacement target cannot leave a retained frame")

            // Abort without any successor: the owner discards explicitly.
            engine.play(transitionURL: nil, loopURL: outgoingURL)
            guard waitForPlayback({ player.currentTime().seconds > 0.3 }) else {
                t.expect(false, "daily restarts before the discard check")
                return
            }
            engine.retainDisplayedFrameForReplacement()
            engine.stopVideo()
            t.expect(engine.hasRetainedFrame, "the aborted replacement first retains its frame")
            engine.discardDisplayedFrameHold()
            t.expect(!engine.hasRetainedFrame, "an aborted replacement discards its retained frame")
        } catch { t.expect(false, "replacement discard fixture failed: \(error)") }
    }
    run("PlaybackEngine.replacementFrameHoldHardStopsWithTeardown") { t in
        do {
            let outgoingURL = try makeTinyVideo(seconds: 2)
            defer { try? FileManager.default.removeItem(at: outgoingURL) }
            let engine = PlaybackEngine()
            let player = engine.videoLayer.player!
            engine.play(transitionURL: nil, loopURL: outgoingURL)
            guard waitForPlayback({ player.currentTime().seconds > 0.3 }) else {
                t.expect(false, "daily advances before the hard stop")
                return
            }
            engine.retainDisplayedFrameForReplacement()
            engine.stopVideo()
            t.expect(engine.hasRetainedFrame, "hard stop retains only while it is still a replacement")
            engine.teardown()
            t.expect(!engine.hasRetainedFrame, "teardown clears a retained replacement frame")
            t.expectNil(engine.dailySourceURL, "teardown clears the retained source identity")
        } catch { t.expect(false, "replacement hard-stop fixture failed: \(error)") }
    }
    run("PlaybackEngine.naturalDailyEOFHoldsActualFinalFrameAcrossTransitionEntry") { t in
        do {
            // Frame 0 is black and every later frame is white: a hold taken at the real daily
            // EOF must be the bright final sample, not a blank layer or the frame-zero poster.
            let dayURL = try makeTinyVideo(seconds: 2, frameFill: { $0 == 0 ? 0x00 : 0xFF })
            defer { try? FileManager.default.removeItem(at: dayURL) }
            let transitionURL = try makeTinyVideo(seconds: 2)
            defer { try? FileManager.default.removeItem(at: transitionURL) }
            let engine = PlaybackEngine()
            defer { engine.teardown() }
            let player = engine.videoLayer.player!

            engine.play(transitionURL: nil, loopURL: dayURL)
            guard waitForPlayback({ player.currentTime().seconds > 0.5 }), let dayItem = player.currentItem else {
                t.expect(false, "daily unit advances before the natural-EOF request")
                return
            }
            var callbackFired = false
            var eofTime = 0.0
            var heldInCallback = false
            var preparedFrameSurvivedCancellation = false
            var heldLuminance: Double?
            engine.finishCurrentDailyUnit {
                callbackFired = true
                eofTime = dayItem.currentTime().seconds
                // Production owner boundary: reevaluate(atDailyUnitEnd:true) withdraws the
                // drained boundary before installing the successor. The genuine EOF already
                // consumed the request, so this must not discard the prepared handoff frame.
                engine.cancelPendingDailyBoundary()
                preparedFrameSurvivedCancellation = engine.hasPreparedDailyEOFFrame
                // Enter the transition on the real EOF callback.
                engine.play(transitionURL: transitionURL, loopURL: transitionURL)
                heldInCallback = engine.hasRetainedFrame
                if let image = retainedStillImage(of: engine) { heldLuminance = averageLuminance(image) }
            }
            t.expect(waitForPlayback { engine.hasPreparedDailyEOFFrame },
                     "the natural-EOF frame is prepared while the day unit still plays")
            t.expect(waitForPlayback({ callbackFired }, timeout: 6),
                     "the full day unit reaches its genuine natural EOF")
            // The day clock overshoots the asset duration at EOF; the outgoing reconstruction
            // must still resolve the actual final decoded frame.
            t.expect(eofTime > 1.9, "the boundary fires only after the whole unit, got \(eofTime)")
            t.expect(preparedFrameSurvivedCancellation,
                     "post-EOF owner cancellation keeps the prepared handoff frame")
            t.expect(heldInCallback, "natural daily EOF installs the outgoing frame before the swap")
            t.expect((heldLuminance ?? -1) > 150,
                     "the hold is the day's real final frame, not black or frame 0, got \(String(describing: heldLuminance))")
            t.expect(waitForPlayback { !engine.hasRetainedFrame },
                     "the hold releases once the transition item is actually ready")
            t.expect(waitForPlayback { player.currentTime().seconds > 0.15 },
                     "the transition advances under the released hold")
        } catch { t.expect(false, "natural EOF hold fixture failed: \(error)") }
    }
    run("PlaybackEngine.unreadableDailyLoopReportsActualLoadFailureOnce") { t in
        do {
            let brokenURL = try makeUnreadableContainer()
            defer { try? FileManager.default.removeItem(at: brokenURL) }
            let engine = PlaybackEngine()
            defer { engine.teardown() }
            var failures: [Error?] = []
            var stalls = 0
            engine.onDailyLoadFailed = { failures.append($0) }
            engine.onPlaybackStalled = { stalls += 1 }

            engine.play(transitionURL: nil, loopURL: brokenURL)
            t.expect(engine.hasVideoResources || engine.hasPendingDailyLoopLoad,
                     "a newly submitted load is owned before its first item or failure callback")
            // Baseline evidence: this exact source never becomes a current item and no watchdog
            // ever fires. The actual looper error must arrive far inside the 8s waiting / 30s
            // active watchdog windows instead.
            t.expect(waitForPlayback({ !failures.isEmpty }, timeout: 5),
                     "an unreadable daily container reports its real load failure without waiting for the watchdog")
            RunLoop.main.run(until: Date().addingTimeInterval(1.0))
            t.expect(failures.count == 1, "the load failure is reported exactly once, got \(failures.count)")
            t.expect(failures.first.flatMap { $0 } != nil,
                     "the report carries AVPlayerLooper's actual load error, not a synthesized stall")
            t.expect(!engine.hasVideoResources, "the failed daily decoder is released")
            t.expect(!engine.hasPendingDailyLoopLoad, "failure releases the pending loop installation")
            t.expectNil(engine.dailySourceURL, "no daily source remains installed after the failed load")
            t.expect(stalls == 0, "a container load failure is not double-reported as a playback stall")
        } catch { t.expect(false, "unreadable daily loop fixture failed: \(error)") }
    }
    run("PlaybackEngine.validLoopAdvancesWithoutSpuriousLoadFailure") { t in
        do {
            let url = try makeTinyVideo(seconds: 2)
            defer { try? FileManager.default.removeItem(at: url) }
            let engine = PlaybackEngine()
            defer { engine.teardown() }
            let player = engine.videoLayer.player!
            var failures = 0
            engine.onDailyLoadFailed = { _ in failures += 1 }

            engine.play(transitionURL: nil, loopURL: url)
            t.expect(waitForPlayback({ player.currentTime().seconds > 0.3 }),
                     "valid generated looping media still advances under the new load observer")
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            t.expect(failures == 0, "a healthy loop reports no load failure")
            t.expect(engine.hasVideoResources, "a healthy loop keeps its decoder")
        } catch { t.expect(false, "valid loop fixture failed: \(error)") }
    }
    run("PlaybackEngine.staleLoadFailureCallbackRejectsReplacementAndStop") { t in
        do {
            let brokenURL = try makeUnreadableContainer()
            defer { try? FileManager.default.removeItem(at: brokenURL) }
            let validURL = try makeTinyVideo(seconds: 2)
            defer { try? FileManager.default.removeItem(at: validURL) }
            let engine = PlaybackEngine()
            defer { engine.teardown() }
            let player = engine.videoLayer.player!
            var failures = 0
            engine.onDailyLoadFailed = { _ in failures += 1 }

            engine.play(transitionURL: nil, loopURL: brokenURL)
            t.expect(waitForPlayback({ failures == 1 }, timeout: 5),
                     "the broken source reports its failure before the replacement")
            // A genuinely changed source is a permitted new load and must recover.
            engine.play(transitionURL: nil, loopURL: validURL)
            t.expect(waitForPlayback({ player.currentTime().seconds > 0.2 }),
                     "source replacement after a failed load recovers and advances")
            engine.stopVideo()
            RunLoop.main.run(until: Date().addingTimeInterval(1.0))
            t.expect(failures == 1,
                     "no stale load failure is delivered after replacement or stop, got \(failures)")
            t.expect(!engine.hasVideoResources, "stop leaves no decoder after the recovered replacement")

            // Replace/stop before pumping the main queue, so asynchronous load observations from
            // the abandoned looper must not poison the replacement or report after stop.
            engine.play(transitionURL: nil, loopURL: brokenURL)
            engine.play(transitionURL: nil, loopURL: validURL)
            t.expect(waitForPlayback({ player.currentTime().seconds > 0.2 }),
                     "a replacement survives an abandoned malformed load")
            engine.play(transitionURL: nil, loopURL: brokenURL)
            engine.stopVideo()
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            t.expectEqual(failures, 1, "abandoned load callbacks cannot report against a new generation")
        } catch { t.expect(false, "stale load failure fixture failed: \(error)") }
    }
    run("PlaybackEngine.nonDecodableHEVCTrackReportsCapabilityFailureInsteadOfSilentReady") { t in
        do {
            let hevcSource = try makeTinyVideo(seconds: 2, codec: .hevc)
            defer { try? FileManager.default.removeItem(at: hevcSource) }
            let hev1URL = try makeHEV1MismatchCopy(of: hevcSource)
            defer { try? FileManager.default.removeItem(at: hev1URL) }
            let validURL = try makeTinyVideo(seconds: 2)
            defer { try? FileManager.default.removeItem(at: validURL) }

            // Fixture precondition: fail loudly rather than silently skipping if this SDK ever
            // stops reproducing the platform capability=false / item-ready false success.
            guard let capability = loadVideoCapability(hev1URL) else {
                t.expect(false, "retagged HEVC fixture has no readable video track")
                return
            }
            t.expect(!capability.playable && !capability.decodable,
                     "fixture reproduces platform capability=false, got \(capability)")

            let engine = PlaybackEngine()
            defer { engine.teardown() }
            let player = engine.videoLayer.player!
            var failures: [Error?] = []
            var stalls = 0
            engine.onDailyLoadFailed = { failures.append($0) }
            engine.onPlaybackStalled = { stalls += 1 }

            engine.play(transitionURL: nil, loopURL: hev1URL)
            t.expect(waitForPlayback({ !failures.isEmpty }, timeout: 6),
                     "an installed non-decodable daily track reports failure instead of silent ready")
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            t.expectEqual(failures.count, 1, "the capability failure is reported exactly once")
            t.expect(failures.first.flatMap { $0 } != nil,
                     "the report carries a meaningful capability error")
            t.expect(!engine.hasVideoResources, "the false-success decoder is released")
            t.expect(!engine.hasPendingDailyLoopLoad, "capability failure releases the pending loop install")
            t.expect(stalls == 0, "a capability failure is not double-reported as a playback stall")
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            t.expectEqual(failures.count, 1, "the engine does not silently reinstall the unchanged failed source")

            // A changed source is a permitted new install and must recover.
            engine.play(transitionURL: nil, loopURL: validURL)
            t.expect(waitForPlayback({ player.currentTime().seconds > 0.3 }),
                     "a valid source after a capability failure advances")
            engine.setVisualPaused(true)
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            t.expect(engine.visualPaused, "capability handling preserves a user pause")
            t.expectEqual(failures.count, 1, "valid playback reports no capability failure")
            engine.setVisualPaused(false)

            // Stale validation: an in-flight query for the failed source must not stop the newer
            // valid install even when the bad source is replaced before the query completes.
            engine.play(transitionURL: nil, loopURL: hev1URL)
            engine.play(transitionURL: nil, loopURL: validURL)
            t.expect(waitForPlayback({ player.currentTime().seconds > 0.2 }),
                     "a newer valid install survives an in-flight capability validation")
            RunLoop.main.run(until: Date().addingTimeInterval(1.0))
            t.expectEqual(failures.count, 1, "a stale capability validation cannot fail newer playback")

            // A valid 2s transition must actually complete into its target loop, not merely be
            // observed for part of its duration, and must report no spurious capability failure.
            let validLoopURL = try makeTinyVideo(seconds: 2)
            defer { try? FileManager.default.removeItem(at: validLoopURL) }
            engine.stopVideo()
            engine.play(transitionURL: validURL, loopURL: validLoopURL)
            t.expect(waitForPlayback({ engine.dailySourceURL == validURL && player.currentTime().seconds > 0.2 },
                                     timeout: 3),
                     "a valid transition to loop install plays its transition under capability validation")
            t.expect(waitForPlayback({ engine.dailySourceURL == validLoopURL }, timeout: 4),
                     "the valid transition reaches its natural end and installs the target loop")
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            t.expectEqual(failures.count, 1, "the completed valid transition to loop reports no false failure")
        } catch { t.expect(false, "non-decodable HEVC fixture failed: \(error)") }
    }
    run("PlaybackEngine.nonDecodableDailyTransitionReportsFailureInsteadOfAdvancingToLoop") { t in
        do {
            let hevcSource = try makeTinyVideo(seconds: 2, codec: .hevc)
            defer { try? FileManager.default.removeItem(at: hevcSource) }
            let hev1TransitionURL = try makeHEV1MismatchCopy(of: hevcSource)
            defer { try? FileManager.default.removeItem(at: hev1TransitionURL) }
            let validTransitionURL = try makeTinyVideo(seconds: 1)
            defer { try? FileManager.default.removeItem(at: validTransitionURL) }
            let validLoopURL = try makeTinyVideo(seconds: 2)
            defer { try? FileManager.default.removeItem(at: validLoopURL) }

            guard let capability = loadVideoCapability(hev1TransitionURL) else {
                t.expect(false, "retagged HEVC transition fixture has no readable video track")
                return
            }
            t.expect(!capability.playable && !capability.decodable,
                     "transition fixture reproduces platform capability=false, got \(capability)")

            let engine = PlaybackEngine()
            defer { engine.teardown() }
            let player = engine.videoLayer.player!
            var failures: [Error?] = []
            var stalls = 0
            engine.onDailyLoadFailed = { failures.append($0) }
            engine.onPlaybackStalled = { stalls += 1 }

            // An unsupported transition must fail its install while it is on screen, not stay
            // black to its EOF and only then hand off to the valid target loop.
            engine.play(transitionURL: nil, loopURL: validLoopURL)
            t.expect(waitForPlayback({ player.currentTime().seconds > 0.3 }),
                     "a valid outgoing loop advances before the unsupported transition")
            engine.play(transitionURL: hev1TransitionURL, loopURL: validLoopURL)
            t.expect(engine.hasRetainedFrame, "transition entry retains the outgoing source frame")
            t.expect(waitForPlayback({ !failures.isEmpty }, timeout: 6),
                     "an unsupported daily transition reports failure instead of silently advancing to the loop")
            RunLoop.main.run(until: Date().addingTimeInterval(1.0))
            t.expectEqual(failures.count, 1, "the unsupported transition is reported exactly once")
            t.expect(failures.first.flatMap { $0 } != nil,
                     "the transition report carries a meaningful capability error")
            t.expect(player.currentItem == nil,
                     "the unsupported transition does not silently continue into the target loop")
            t.expect(!engine.hasVideoResources, "the failed transition queue is released")
            t.expect(!engine.hasRetainedFrame, "the failed transition releases its outgoing frame hold")
            t.expect(!engine.hasPendingDailyLoopLoad, "no pending loop install survives the transition failure")
            t.expect(stalls == 0, "a transition capability failure is not double-reported as a playback stall")
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            t.expectEqual(failures.count, 1, "the unchanged unsupported transition is not reinstalled")
            t.expectNil(engine.dailySourceURL, "the unsupported transition never becomes the active loop source")

            // A stale unsupported transition must not stop a newer valid install that replaced it.
            engine.play(transitionURL: hev1TransitionURL, loopURL: validLoopURL)
            engine.play(transitionURL: nil, loopURL: validLoopURL)
            t.expect(waitForPlayback({ player.currentTime().seconds > 0.2 }),
                     "a newer valid loop survives a stale unsupported-transition validation")
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            t.expectEqual(failures.count, 1, "a stale transition validation cannot fail newer playback")

            // A changed, valid transition is a permitted new install and must reach its loop.
            engine.stopVideo()
            engine.play(transitionURL: validTransitionURL, loopURL: validLoopURL)
            t.expect(waitForPlayback({ engine.dailySourceURL == validTransitionURL }, timeout: 3),
                     "the replacement valid transition plays under capability validation")
            t.expect(waitForPlayback({ engine.dailySourceURL == validLoopURL }, timeout: 4),
                     "the replacement valid transition recovers into its target loop")
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            t.expectEqual(failures.count, 1, "the recovered valid transition reports no further failure")
        } catch { t.expect(false, "non-decodable transition fixture failed: \(error)") }
    }
    run("PlaybackEngine.nonDecodableDailyStillReportsFailureInsteadOfSilentBlack") { t in
        do {
            let hevcSource = try makeTinyVideo(seconds: 2, codec: .hevc)
            defer { try? FileManager.default.removeItem(at: hevcSource) }
            let hev1URL = try makeHEV1MismatchCopy(of: hevcSource)
            defer { try? FileManager.default.removeItem(at: hev1URL) }
            let validURL = try makeTinyVideo(seconds: 2)
            defer { try? FileManager.default.removeItem(at: validURL) }

            guard let capability = loadVideoCapability(hev1URL) else {
                t.expect(false, "retagged HEVC still fixture has no readable video track")
                return
            }
            t.expect(!capability.playable && !capability.decodable,
                     "still fixture reproduces platform capability=false, got \(capability)")

            let engine = PlaybackEngine()
            defer { engine.teardown() }
            var failures: [Error?] = []
            engine.onDailyLoadFailed = { failures.append($0) }
            engine.setVisualPaused(true)
            t.expect(engine.visualPaused, "paused cold start is the precondition for a still")

            var unsupportedInstalled: Bool?
            engine.showDailyStill(loopURL: hev1URL) { unsupportedInstalled = $0 }
            t.expect(waitForPlayback({ unsupportedInstalled != nil }, timeout: 6),
                     "an unsupported source's still attempt completes")
            t.expect(unsupportedInstalled == false, "an unsupported source installs no still")
            t.expect(waitForPlayback({ !failures.isEmpty }, timeout: 6),
                     "a paused cold start on an unsupported source reports failure instead of silent black")
            t.expectEqual(failures.count, 1, "the still capability failure is reported exactly once")
            t.expect(failures.first.flatMap { $0 } != nil,
                     "the still report carries a meaningful capability error")
            t.expect(!engine.hasRetainedFrame, "no frame is retained for the unsupported source")
            t.expect(!engine.hasVideoResources, "the failed still leaves no video resources")
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            t.expectEqual(failures.count, 1, "the unchanged unsupported still is never silently reinstalled")

            // A valid source for the same paused state must still install its still and add no
            // false failure, so the fix cannot turn an ordinary pause into a reported error.
            var validInstalled: Bool?
            engine.showDailyStill(loopURL: validURL) { validInstalled = $0 }
            t.expect(waitForPlayback({ validInstalled != nil }, timeout: 6),
                     "a valid source's still attempt completes")
            t.expect(validInstalled == true, "a valid paused source installs its still")
            t.expect(engine.hasRetainedFrame, "the valid still is retained")
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            t.expectEqual(failures.count, 1, "the valid still reports no false capability failure")
        } catch { t.expect(false, "non-decodable still fixture failed: \(error)") }
    }

}
