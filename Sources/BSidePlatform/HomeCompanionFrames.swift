// BSidePlatform — bounded packed-BGRA transport for the Agent's existing daily player.
// The ControlApp creates the capability; frame events never choose a filesystem path.
import AppKit
import AVFoundation
import Accelerate
import CoreVideo
import Darwin
import BSideCore

private enum HomeFrameError: Error { case invalidBuffer, invalidFrame, system(Int32) }

private final class HomeFrameMapping {
    static let maxWidth = 1920, maxHeight = 1080
    let stream: HomeCompanionStreamRequest.Stream
    let pointer: UnsafeMutableRawPointer
    private let descriptor: Int32
    private let ownedDirectory: URL?

    static func valid(_ stream: HomeCompanionStreamRequest.Stream) -> Bool {
        UUID(uuidString: stream.id) != nil && stream.maxWidth > 0 && stream.maxHeight > 0
            && stream.maxWidth <= maxWidth && stream.maxHeight <= maxHeight
            && stream.capacity == stream.maxWidth * stream.maxHeight * 4
    }

    init(stream: HomeCompanionStreamRequest.Stream, ownedDirectory: URL? = nil) throws {
        guard Self.valid(stream) else { throw HomeFrameError.invalidBuffer }
        let fd = open(stream.bufferPath, O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw HomeFrameError.system(errno) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o777 == 0o600, info.st_uid == geteuid(), info.st_nlink == 1,
              info.st_size == stream.capacity else {
            close(fd); throw HomeFrameError.invalidBuffer
        }
        let mapped = mmap(nil, stream.capacity, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
        guard let mapped, mapped != MAP_FAILED else { close(fd); throw HomeFrameError.system(errno) }
        self.stream = stream; pointer = mapped; descriptor = fd; self.ownedDirectory = ownedDirectory
    }

    static func create() throws -> HomeFrameMapping {
        let id = UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bsidemac-home-\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("pixels.bgra")
        let capacity = maxWidth * maxHeight * 4
        let fd = open(url.path, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { try? FileManager.default.removeItem(at: directory); throw HomeFrameError.system(errno) }
        let result = ftruncate(fd, off_t(capacity)); close(fd)
        guard result == 0 else { try? FileManager.default.removeItem(at: directory); throw HomeFrameError.system(errno) }
        do {
            return try HomeFrameMapping(stream: .init(id: id, bufferPath: url.path, capacity: capacity,
                                                       maxWidth: maxWidth, maxHeight: maxHeight), ownedDirectory: directory)
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }

    deinit {
        munmap(pointer, stream.capacity); close(descriptor)
        if let ownedDirectory { try? FileManager.default.removeItem(at: ownedDirectory) }
    }
}

/// Runs during AppKit's tracking modes as well as its ordinary loop. No timer or polling.
private func onHomeMain(_ action: @escaping () -> Void) {
    CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue, action)
    CFRunLoopWakeUp(CFRunLoopGetMain())
}

/// Main-thread owner. Each admitted frame is copied off-main before completion/ACK. A CGImage
/// owns immutable bytes, so the producer may reuse the mapped slot even while CA reads the image.
public final class HomeCompanionFrameReceiver {
    public static let transitionTracingEnabled = ProcessInfo.processInfo.environment["BSIDEMAC_TRACE_HOME_TRANSITION"] == "1"
    private struct TransitionTrace {
        let id = UUID().uuidString
        let event: String
        let streamID: String
        let started = ProcessInfo.processInfo.systemUptime
        var completed: Double?
        var lastReceive: Double?
        var lastPresentation: Double?
        var contentID = "none"
        var receivedSequence: UInt64 = 0
        var presentedSequence: UInt64 = 0
        var frames = 0
        var maxReceiveGap = 0.0, maxPresentationGap = 0.0
        var maxCopy = 0.0, maxMainHandoff = 0.0
        var maxPresentation = 0.0, maxAcknowledgement = 0.0
    }
    private var transitionTrace: TransitionTrace?
    public var isTracingTransition: Bool { transitionTrace != nil }
    private var mapping: HomeFrameMapping?
    private let copyQueue = DispatchQueue(label: "bside.home-frame-copy", qos: .userInteractive)
    private var generation: UInt64 = 0
    private var lastSequence: UInt64 = 0
    private var copying = false
    public private(set) var copiedFrames = 0
    public private(set) var copiedBytes = 0
    public private(set) var copySeconds: Double = 0
    public var stream: HomeCompanionStreamRequest.Stream? { mapping?.stream }

    public init() throws { mapping = try HomeFrameMapping.create() }

    public static func valid(_ frame: HomeCompanionFrame, for stream: HomeCompanionStreamRequest.Stream) -> Bool {
        HomeFrameMapping.valid(stream) && frame.streamID == stream.id && frame.sequence > 0
            && !frame.contentID.isEmpty && frame.width > 0 && frame.height > 0
            && frame.width <= stream.maxWidth && frame.height <= stream.maxHeight
            && frame.bytesPerRow == frame.width * 4
            && frame.bytesPerRow * frame.height <= stream.capacity
    }

    @discardableResult
    public func receive(_ frame: HomeCompanionFrame,
                        completion: @escaping (CGImage, HomeCompanionFrameAcknowledgement) -> Void) -> Bool {
        guard let mapping, !copying, frame.sequence > lastSequence,
              Self.valid(frame, for: mapping.stream) else { return false }
        if var trace = transitionTrace {
            let now = ProcessInfo.processInfo.systemUptime
            trace.maxReceiveGap = max(trace.maxReceiveGap, now - (trace.lastReceive ?? trace.started))
            trace.lastReceive = now; trace.receivedSequence = frame.sequence; trace.contentID = frame.contentID
            transitionTrace = trace
        }
        lastSequence = frame.sequence; copying = true
        let token = generation
        copyQueue.async { [weak self, mapping] in
            let start = ProcessInfo.processInfo.systemUptime
            let count = frame.bytesPerRow * frame.height
            let bytes = Data(bytes: mapping.pointer, count: count)
            let provider = CGDataProvider(data: bytes as CFData)
            let image = provider.flatMap { CGImage(width: frame.width, height: frame.height,
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: frame.bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue),
                provider: $0, decode: nil, shouldInterpolate: true, intent: .defaultIntent) }
            let finished = ProcessInfo.processInfo.systemUptime
            let elapsed = finished - start
            onHomeMain { [weak self] in
                guard let self, self.generation == token, self.mapping === mapping else { return }
                self.copying = false
                guard let image else { return }
                self.copiedFrames += 1; self.copiedBytes += count; self.copySeconds += elapsed
                if var trace = self.transitionTrace {
                    trace.maxCopy = max(trace.maxCopy, elapsed)
                    trace.maxMainHandoff = max(trace.maxMainHandoff, ProcessInfo.processInfo.systemUptime - finished)
                    self.transitionTrace = trace
                }
                completion(image, .init(streamID: frame.streamID, sequence: frame.sequence))
            }
        }
        return true
    }

    public func beginTransitionTrace(event: String) {
        guard Self.transitionTracingEnabled, let stream else { return }
        if transitionTrace != nil { logTransitionTrace(terminal: "superseded-no-post-frame") }
        transitionTrace = TransitionTrace(event: event, streamID: stream.id)
        logTransitionTrace(terminal: "begin")
    }

    public func completeTransitionTrace(event: String) {
        guard transitionTrace != nil else { return }
        transitionTrace?.completed = ProcessInfo.processInfo.systemUptime
        // Always emit native completion, even if no later frame ever arrives. The optional
        // first-post-frame record supplements this snapshot; no timer waits for a frame.
        logTransitionTrace(terminal: "\(event)-no-post-frame-yet")
    }

    /// Includes synchronous CALayer image preparation/transaction commit, not proof of scanout.
    public func tracePresentation(sequence: UInt64, started: Double, submitted: Double,
                                  acknowledgementStarted: Double, acknowledged: Double) {
        guard var trace = transitionTrace else { return }
        trace.frames += 1; trace.presentedSequence = sequence
        trace.maxPresentationGap = max(trace.maxPresentationGap, submitted - (trace.lastPresentation ?? trace.started))
        trace.lastPresentation = submitted
        trace.maxPresentation = max(trace.maxPresentation, submitted - started)
        trace.maxAcknowledgement = max(trace.maxAcknowledgement, acknowledged - acknowledgementStarted)
        transitionTrace = trace
        if trace.completed != nil {
            logTransitionTrace(terminal: "first-post-frame")
            transitionTrace = nil
        }
    }

    private func logTransitionTrace(terminal: String) {
        guard let trace = transitionTrace else { return }
        let now = ProcessInfo.processInfo.systemUptime
        func ms(_ seconds: Double) -> String { String(format: "%.3f", seconds * 1000) }
        AppLog.control("home-transition.summary id=\(trace.id) event=\(trace.event) terminal=\(terminal) stream=\(trace.streamID) content=\(trace.contentID) received=\(trace.receivedSequence) presented=\(trace.presentedSequence) frames=\(trace.frames) monotonic-ms=\(ms(now)) elapsed-ms=\(ms(now - trace.started)) completion-ms=\(trace.completed.map(ms) ?? "none") open-present-gap-ms=\(ms(now - (trace.lastPresentation ?? trace.started))) max-receive-gap-ms=\(ms(trace.maxReceiveGap)) max-present-gap-ms=\(ms(trace.maxPresentationGap)) max-copy-ms=\(ms(trace.maxCopy)) max-main-handoff-ms=\(ms(trace.maxMainHandoff)) max-layer-submit-ms=\(ms(trace.maxPresentation)) max-ack-ms=\(ms(trace.maxAcknowledgement)) mode=\(RunLoop.current.currentMode?.rawValue ?? "none")")
    }

    public func invalidate() {
        if transitionTrace != nil { logTransitionTrace(terminal: "withdrawn-no-post-frame"); transitionTrace = nil }
        generation &+= 1; mapping = nil; copying = false
    }
}

/// Main-thread media owner with one bounded off-main BGRA copy/scale and one outstanding ACK.
/// No additional player, decoder, audio path, seek or media-item replacement is created.
public struct HomeCompanionFrameCadence {
    private var nextDeadline: Double?
    public init() {}
    /// Select the nearest display refresh to each 30 Hz deadline. Preserve phase under jitter,
    /// and skip missed deadlines after backpressure or suspension without a catch-up queue.
    public mutating func admit(displayTime: Double, refreshInterval: Double) -> Bool {
        guard displayTime.isFinite, displayTime >= 0, refreshInterval.isFinite,
              refreshInterval > 0 else { return false }
        let period = 1.0 / 30
        let eligibleTime = displayTime + min(refreshInterval, period) / 2
        guard let deadline = nextDeadline else {
            nextDeadline = displayTime + period
            return true
        }
        guard eligibleTime >= deadline else { return false }
        nextDeadline = deadline + (floor((eligibleTime - deadline) / period) + 1) * period
        return true
    }
}

public final class HomeCompanionFrameProducer {
    private let player: AVPlayer
    private let contentID: () -> String
    private var mapping: HomeFrameMapping?
    private var output: AVPlayerItemVideoOutput?
    private weak var outputItem: AVPlayerItem?
    private var itemObservation: NSKeyValueObservation?
    private var displayLink: CVDisplayLink?
    private let tickLock = NSLock()
    private var tickPending = false
    private var tickAdmissionOpen = false
    private var latestDisplayTime = 0.0
    private let copyQueue = DispatchQueue(label: "bside.home-frame-produce", qos: .userInteractive)
    private var generation: UInt64 = 0
    private var itemGeneration: UInt64 = 0
    private var sequence: UInt64 = 0
    private var outstanding: UInt64?
    private var outstandingItemGeneration: UInt64?
    private var copying = false
    private var cadence = HomeCompanionFrameCadence()
    private var enabled = false
    public private(set) var hasAcceptedFrame = false
    public private(set) var producedFrames = 0
    public private(set) var mainTicks = 0
    public private(set) var produceSeconds: Double = 0
    public var onFrame: (HomeCompanionFrame) -> Void = { _ in }
    public var onFirstAcceptedFrame: (() -> Void)?
    public var onContentReset: (() -> Void)?
    public var hasStream: Bool { mapping != nil }

    public init(player: AVPlayer, contentID: @escaping () -> String) {
        self.player = player; self.contentID = contentID
        itemObservation = player.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
            onHomeMain { [weak self] in self?.bindCurrentItem() }
        }
    }

    @discardableResult
    public func configure(_ stream: HomeCompanionStreamRequest.Stream?) -> Bool {
        stop()
        guard let stream else { return false }
        do { mapping = try HomeFrameMapping(stream: stream) }
        catch { AppLog.error("home-stream.rejected invalid-buffer"); return false }
        bindCurrentItem()
        return true
    }

    private func bindCurrentItem() {
        guard outputItem !== player.currentItem || output == nil else { return }
        itemGeneration &+= 1
        hasAcceptedFrame = false; onContentReset?()
        if let output, let outputItem { outputItem.remove(output) }
        output = nil; outputItem = nil
        guard mapping != nil, let item = player.currentItem else { return }
        let next = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(next); output = next; outputItem = item
    }

    public func setEnabled(_ value: Bool) {
        enabled = value
        updateTickAdmission()
        if value && mapping != nil {
            guard displayLink == nil else { return }
            var link: CVDisplayLink?
            guard CVDisplayLinkCreateWithActiveCGDisplays(&link) == kCVReturnSuccess, let link else { return }
            CVDisplayLinkSetOutputCallback(link, { _, _, outputTime, _, _, context in
                guard let context else { return kCVReturnSuccess }
                let stamp = outputTime.pointee
                let flags = CVTimeStampFlags(rawValue: stamp.flags)
                guard flags.contains(.hostTimeValid), flags.contains(.videoRefreshPeriodValid),
                      stamp.videoTimeScale > 0, stamp.videoRefreshPeriod > 0 else { return kCVReturnSuccess }
                Unmanaged<HomeCompanionFrameProducer>.fromOpaque(context).takeUnretainedValue().scheduleTick(
                    displayTime: Double(stamp.hostTime) / CVGetHostClockFrequency(),
                    refreshInterval: Double(stamp.videoRefreshPeriod) / Double(stamp.videoTimeScale))
                return kCVReturnSuccess
            }, Unmanaged.passUnretained(self).toOpaque())
            displayLink = link
            CVDisplayLinkStart(link)
        } else { stopDisplayLink() }
    }

    private func scheduleTick(displayTime: Double, refreshInterval: Double) {
        tickLock.lock()
        latestDisplayTime = displayTime
        // Reject unused refreshes before waking the main run loop. Cadence and this
        // admission snapshot are protected by tickLock; player state stays on main.
        guard tickAdmissionOpen, !tickPending,
              cadence.admit(displayTime: displayTime, refreshInterval: refreshInterval) else {
            tickLock.unlock(); return
        }
        tickPending = true; tickLock.unlock()
        onHomeMain { [weak self] in
            guard let self else { return }
            self.tickLock.lock()
            let time = self.latestDisplayTime
            self.tickLock.unlock()
            self.mainTicks += 1
            self.tick(displayTime: time)
            self.tickLock.lock(); self.tickPending = false; self.tickLock.unlock()
        }
    }

    private func tick(displayTime: Double) {
        guard enabled, let mapping, !copying, outstanding == nil else { return }
        bindCurrentItem()
        guard let output, let item = outputItem, player.currentItem === item, item.status == .readyToPlay else { return }
        let time = output.itemTime(forHostTime: displayTime)
        guard output.hasNewPixelBuffer(forItemTime: time),
              let pixels = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { return }
        copying = true
        updateTickAdmission()
        let token = generation, itemToken = itemGeneration, source = contentID()
        copyQueue.async { [weak self, mapping] in
            let start = ProcessInfo.processInfo.systemUptime
            let shape = Self.write(pixels, into: mapping)
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            onHomeMain { [weak self] in
                guard let self else { return }
                // stop/configure keep copying true until this physical write finishes.
                // Reopen admission from current state, never the retired generation.
                self.copying = false
                defer { self.updateTickAdmission() }
                guard self.generation == token, self.mapping === mapping else { return }
                guard self.itemGeneration == itemToken, self.player.currentItem === item, let shape else { return }
                self.sequence += 1; self.outstanding = self.sequence
                self.outstandingItemGeneration = itemToken
                self.producedFrames += 1; self.produceSeconds += elapsed
                self.onFrame(.init(streamID: mapping.stream.id, sequence: self.sequence, contentID: source,
                                   width: shape.0, height: shape.1, bytesPerRow: shape.0 * 4))
            }
        }
    }

    private static func write(_ pixels: CVPixelBuffer, into mapping: HomeFrameMapping) -> (Int, Int)? {
        guard CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let source = CVPixelBufferGetBaseAddress(pixels) else { return nil }
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
        guard width > 0, height > 0 else { return nil }
        let scale = min(1, min(Double(mapping.stream.maxWidth) / Double(width), Double(mapping.stream.maxHeight) / Double(height)))
        let targetWidth = max(1, Int(Double(width) * scale)), targetHeight = max(1, Int(Double(height) * scale))
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        if targetWidth == width && targetHeight == height {
            for row in 0..<height { memcpy(mapping.pointer.advanced(by: row * width * 4), source.advanced(by: row * stride), width * 4) }
        } else {
            var input = vImage_Buffer(data: source, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: stride)
            var destination = vImage_Buffer(data: mapping.pointer, height: vImagePixelCount(targetHeight), width: vImagePixelCount(targetWidth), rowBytes: targetWidth * 4)
            guard vImageScale_ARGB8888(&input, &destination, nil, vImage_Flags(kvImageNoFlags)) == kvImageNoError else { return nil }
        }
        return (targetWidth, targetHeight)
    }

    public func acknowledge(_ acknowledgement: HomeCompanionFrameAcknowledgement) {
        bindCurrentItem()
        guard acknowledgement.streamID == mapping?.stream.id, acknowledgement.sequence == outstanding else { return }
        outstanding = nil
        updateTickAdmission()
        guard outstandingItemGeneration == itemGeneration else { return }
        if !hasAcceptedFrame { hasAcceptedFrame = true; onFirstAcceptedFrame?() }
    }
    private func stopDisplayLink() {
        if let displayLink { CVDisplayLinkStop(displayLink) }
        displayLink = nil
    }
    private func updateTickAdmission() {
        tickLock.lock()
        tickAdmissionOpen = enabled && mapping != nil && !copying && outstanding == nil
        tickLock.unlock()
    }
    public func stop() {
        generation &+= 1; enabled = false; updateTickAdmission(); stopDisplayLink()
        if let output, let outputItem { outputItem.remove(output) }
        output = nil; outputItem = nil; mapping = nil; outstanding = nil; outstandingItemGeneration = nil
        sequence = 0; hasAcceptedFrame = false
        tickLock.lock(); cadence = HomeCompanionFrameCadence(); tickLock.unlock()
    }
    deinit { stopDisplayLink(); if let output, let outputItem { outputItem.remove(output) } }
}
