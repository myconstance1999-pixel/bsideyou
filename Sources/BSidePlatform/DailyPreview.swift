// BSidePlatform — bounded still preview for one authorized daily background (ADR-024).
//
// Contract: a preview is a READ-ONLY, bounded, on-demand still of the exact loop the user is
// comparing. It is produced here (Platform is the only layer allowed to touch AVFoundation) and
// handed to ControlApp as plain image data, so ControlApp never imports AVFoundation and never
// owns a player. Nothing is persisted: no official media copy, no thumbnail cache on disk, no
// second playback engine.
//
// One request owns at most one generator, one deadline and one retained access lease. Every
// settle path checks the request token, so a superseded request can neither store a stale image
// nor report a stale failure. The lease is held by the request itself (never by one shared
// mutable property) and is released only once nothing in the request can still read the source:
// after the asynchronous source-metadata load has returned and any AVAssetImageGenerator callback
// has actually returned, including the cancellation and deadline paths.
//
// Source dimensions are loaded asynchronously and the deadline is armed before any AVFoundation
// work, so neither the metadata read nor a slow decode can block the caller (often the main
// thread) or postpone the bounded deadline.
//
// Quality: the request carries the device-pixel bounds of the REAL rendered container (display
// backing scale applied), capped by the product limits and never above the source's own transformed
// pixel size. The still is encoded as lossless PNG, because the chooser compares it against the live
// picture and compression artifacts would be misread as source quality.
import Foundation
import AppKit
import AVFoundation
import BSideCore

/// Device-pixel bounds for one preview request, never points.
///
/// This is the only place a rendered chooser size is translated into extraction bounds, so the
/// still is decoded once at (approximately) the size it is actually displayed at instead of being
/// enlarged afterwards. The bounds are always bounded in both axes AND in total pixels: degenerate
/// geometry falls back to a usable minimum, and no container can ask the decoder for an unbounded
/// bitmap. A source smaller than the request is never enlarged (see `capped(toSource:)`).
public struct DailyPreviewPixelSize: Equatable, Sendable {
    /// Smallest edge a container-derived request is clamped to. A below-minimum *source* may still
    /// legitimately produce a smaller still: the source cap is applied last and never upscales.
    public static let minimumEdge = 32
    /// Longest edge a preview may ever request. Retina-sized for the chooser's real container
    /// (~480x220 pt => 960x440 px at 2x) with headroom for 3x, and still exactly one bounded bitmap.
    public static let maximumEdge = 1440
    /// Total-pixel ceiling, so a wide/short request cannot trade one edge cap for a huge bitmap.
    public static let maximumPixelCount = maximumEdge * maximumEdge

    public let width: Int
    public let height: Int

    public var longestEdge: Int { max(width, height) }
    public var cgSize: CGSize { CGSize(width: width, height: height) }

    /// Product-bounded pixel demand. Values below one are impossible: the generator is never asked
    /// for a zero/negative size.
    public init(width: Int, height: Int) {
        self.init(width: width, height: height, minimumEdge: Self.minimumEdge)
    }

    /// The pixel demand of an actually rendered container at a display backing scale.
    ///
    /// Invalid geometry (a negative dimension, a nonpositive/non-finite scale, a non-finite size,
    /// or a value that cannot be represented) falls back to the usable minimum instead of trapping
    /// in `Int` conversion or silently producing a zero-sized request. Every axis and the scale are
    /// rejected individually: a negative container size must never be rescued by multiplying by a
    /// negative scale. Scaling is clamped in floating point BEFORE the integer conversion, so even a
    /// hostile container value cannot overflow it.
    public static func forRenderedContainer(size: CGSize, scale: CGFloat)
        -> DailyPreviewPixelSize {
        let scaledWidth = size.width * scale
        let scaledHeight = size.height * scale
        guard size.width.isFinite, size.height.isFinite, scale.isFinite,
              size.width >= 0, size.height >= 0, scale > 0,
              scaledWidth.isFinite, scaledHeight.isFinite,
              scaledWidth >= 1, scaledHeight >= 1 else {
            return DailyPreviewPixelSize(width: minimumEdge, height: minimumEdge)
        }
        let width = Int(min(scaledWidth, Double(maximumEdge)).rounded(.up))
        let height = Int(min(scaledHeight, Double(maximumEdge)).rounded(.up))
        return DailyPreviewPixelSize(width: width, height: height)
    }

    /// Never ask the decoder for more than the source's own transformed pixel size, so a small
    /// source can never be turned into a blurred enlargement. Unknown or invalid source evidence
    /// leaves the request unchanged. The cap is applied last, so it may go below the product
    /// minimum when the source itself is smaller — still no upscale.
    public func capped(toSourceTransformedPixelSize source: CGSize?) -> DailyPreviewPixelSize {
        guard let source, source.width.isFinite, source.height.isFinite,
              source.width >= 1, source.height >= 1 else { return self }
        let sourceWidth = Int(min(source.width, CGFloat(DailyPreviewPixelSize.maximumEdge)).rounded(.down))
        let sourceHeight = Int(min(source.height, CGFloat(DailyPreviewPixelSize.maximumEdge)).rounded(.down))
        return DailyPreviewPixelSize(width: min(width, max(1, sourceWidth)),
                                     height: min(height, max(1, sourceHeight)),
                                     minimumEdge: 1)
    }

    /// Product cap without the minimum-edge floor (used after a source cap).
    private init(width: Int, height: Int, minimumEdge: Int) {
        var boundedWidth = min(max(width, minimumEdge), Self.maximumEdge)
        var boundedHeight = min(max(height, minimumEdge), Self.maximumEdge)
        let pixels = boundedWidth * boundedHeight
        if pixels > Self.maximumPixelCount {
            let factor = (Double(Self.maximumPixelCount) / Double(pixels)).squareRoot()
            boundedWidth = max(1, Int(Double(boundedWidth) * factor))
            boundedHeight = max(1, Int(Double(boundedHeight) * factor))
        }
        self.width = boundedWidth
        self.height = boundedHeight
    }
}

/// One explicit preview demand for one exact discovered combination.
public struct DailyPreviewRequest: Equatable {
    /// Exact combination being compared; never a fallback combination.
    public let key: ContentKey
    /// The authorized loop file resolved from the current catalog binding.
    public let loopURL: URL
    /// Frame position inside the loop. Far enough in to avoid a leader/fade-in frame.
    public let atSeconds: Double
    /// Pixel bounds for the produced still, already capped by the product limits. These bounds are
    /// PART OF THE REQUEST IDENTITY: a chooser resize or a move to another display backing scale is
    /// a different request and can never be answered by an undersized still from the old geometry.
    public let pixelSize: DailyPreviewPixelSize

    public init(key: ContentKey, loopURL: URL, atSeconds: Double = 5,
                pixelSize: DailyPreviewPixelSize = DailyPreview.defaultPreviewPixelSize) {
        self.key = key
        self.loopURL = loopURL
        // A bounded request is part of the contract: negative or absurd times cannot reach the
        // generator, and the bounds can never exceed the product maximum.
        self.atSeconds = atSeconds.isFinite ? max(0, min(atSeconds, DailyPreview.maximumFrameSeconds)) : 0
        self.pixelSize = pixelSize
    }

    /// Square-bounds convenience for a caller that only has one edge (the product cap).
    public init(key: ContentKey, loopURL: URL, atSeconds: Double = 5, maximumPixelSize: Int) {
        self.init(key: key, loopURL: loopURL, atSeconds: atSeconds,
                  pixelSize: DailyPreviewPixelSize(width: maximumPixelSize, height: maximumPixelSize))
    }

    /// Longest edge of the requested pixel bounds, in pixels.
    public var maximumPixelSize: Int { pixelSize.longestEdge }
}

/// Unsupported is established by AVFoundation's typed playable metadata, never error wording.
public enum DailyPreviewFailureKind: Equatable {
    case unavailable
    case unsupported
}

/// Outcome of one preview request. `data` is lossless PNG bytes ready for `NSImage(data:)`.
public struct DailyPreviewOutcome: Equatable {
    public let key: ContentKey
    public let data: Data?
    public let failure: String?
    public let failureKind: DailyPreviewFailureKind?

    public static func image(_ key: ContentKey, data: Data) -> DailyPreviewOutcome {
        DailyPreviewOutcome(key: key, data: data, failure: nil, failureKind: nil)
    }

    public static func unavailable(_ key: ContentKey, _ reason: String,
                                   kind: DailyPreviewFailureKind = .unavailable) -> DailyPreviewOutcome {
        DailyPreviewOutcome(key: key, data: nil, failure: reason, failureKind: kind)
    }
}

/// Bounded still extraction for the daily background chooser.
///
/// The caller supplies access: production resolves the SAME authorized daily bookmark the rest of
/// the app uses and keeps that lease alive for the extraction. This service never grants file
/// access on its own, never enumerates a directory and never writes.
public final class DailyPreview {
    /// Product cap for a chooser still's longest edge, in pixels (see `DailyPreviewPixelSize`).
    public static let maximumPreviewPixelSize = DailyPreviewPixelSize.maximumEdge
    /// Bounds used until the presented view has reported its real rendered size: the full bounded
    /// request, so the first still can never be undersized. The real container size replaces it as
    /// soon as it is known, which re-requests (identity includes the bounds).
    public static let defaultPreviewPixelSize = DailyPreviewPixelSize(
        width: maximumPreviewPixelSize, height: maximumPreviewPixelSize)
    /// Product cap for the requested frame position; a longer loop simply uses its start region.
    public static let maximumFrameSeconds: Double = 600
    /// Hard request deadline. A slow/undecodable source reports honestly instead of hanging.
    public static let requestDeadlineSeconds: Double = 8

    private let deadlineSeconds: Double
    private var active: Session?

    /// One in-flight generation. Its identity is the request token: a superseded callback must
    /// settle nothing. It also owns the access lease for exactly as long as the extraction can
    /// still run, so the security scope cannot be released out from under the generator.
    private final class Session {
        let token: Int
        let request: DailyPreviewRequest
        let completion: (DailyPreviewOutcome) -> Void
        var generator: AVAssetImageGenerator?
        var deadline: DispatchWorkItem?
        /// The accepted directory lease retained by THIS request until its callback ends.
        var retainedLease: DirectoryAccessLease?
        var settled = false
        /// The asynchronous source-dimension load has returned. Until it has, the metadata read
        /// may still be touching the source, so the lease must stay retained.
        var loadCompleted = false
        /// A generator callback for this request is outstanding. Its return is what ends the
        /// extraction, and therefore the lease's usable life.
        var generationActive = false

        init(token: Int, request: DailyPreviewRequest, completion: @escaping (DailyPreviewOutcome) -> Void) {
            self.token = token
            self.request = request
            self.completion = completion
        }
    }

    private var nextToken = 0

    public init(deadlineSeconds: Double = DailyPreview.requestDeadlineSeconds) {
        self.deadlineSeconds = deadlineSeconds
    }

    /// True while some request is still in flight (used by the UI's honest "loading" state).
    public var isBusy: Bool { active != nil }

    /// Start one preview. Any previous in-flight request is cancelled first: only the newest
    /// request may deliver, so browsing candidates quickly can never install an older image.
    ///
    /// - Parameter lease: the accepted directory access for `request.loopURL`. It is retained
    ///   strongly by this request until the request can no longer read the source (the asynchronous
    ///   metadata load has returned and any generator callback has ended). A caller must never pass
    ///   a lease it has not already verified against the accepted daily root.
    public func request(_ request: DailyPreviewRequest,
                        retaining lease: DirectoryAccessLease? = nil,
                        completion: @escaping (DailyPreviewOutcome) -> Void) {
        cancel()
        nextToken += 1
        let session = Session(token: nextToken, request: request, completion: completion)
        session.retainedLease = lease
        active = session

        // Arm the deadline BEFORE any AVFoundation work. Loading the source's dimensions and
        // decoding the still are asynchronous and may be slow or blocked; the request must settle
        // honestly after its bounded deadline no matter where it is.
        let deadline = DispatchWorkItem { [weak self] in
            self?.settle(session, with: .unavailable(request.key, "预览生成超时，可稍后重试。"), cancelGenerator: true)
        }
        session.deadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + deadlineSeconds, execute: deadline)

        let asset = AVURLAsset(url: request.loopURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // A background loop has no meaningful exact frame; a modest tolerance lets AVFoundation
        // return a nearby decodable frame instead of failing on a boundary.
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        // Ask the generator to scale the produced still down to the requested pixel bounds right
        // away, so the request is bounded even before the source's own size is known. This bounds
        // the OUTPUT bitmap; it does not guarantee that the decoder avoids a full-resolution decode
        // internally, so no such guarantee is relied upon. The source cap below only refuses to ask
        // for an enlargement of a smaller source once that source's dimensions have been loaded.
        generator.maximumSize = request.pixelSize.cgSize
        session.generator = generator

        // Source dimensions (`tracks`/`naturalSize`/`preferredTransform`) are loaded
        // asynchronously: reading them on the caller's thread — often the main thread — would block
        // the UI and delay this request's deadline. The load stays inside the request lifetime: if
        // the request is cancelled or superseded before it returns, no generation is started, so a
        // late source can never produce a stale still.
        Task { @MainActor [weak self] in
            // A known-unplayable source cannot become usable by retrying the same still. Unknown
            // metadata remains a recoverable extraction failure, not a guessed format diagnosis.
            let isPlayable = try? await asset.load(.isPlayable)
            let sourceSize = isPlayable == false ? nil : await Self.sourceTransformedPixelSize(of: asset)
            session.loadCompleted = true
            guard let self, self.active === session, !session.settled else {
                self?.releaseLeaseIfIdle(session)
                return
            }
            if isPlayable == false {
                self.settle(session, with: .unavailable(request.key,
                    "macOS 无法播放这份素材，原文件未改动。请选择其他视频。",
                    kind: .unsupported), cancelGenerator: true)
                return
            }
            if let sourceSize {
                generator.maximumSize = request.pixelSize
                    .capped(toSourceTransformedPixelSize: sourceSize)
                    .cgSize
            }
            session.generationActive = true
            let time = CMTime(seconds: request.atSeconds, preferredTimescale: 600)
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { [weak self] _, image, _, result, error in
                DispatchQueue.main.async {
                    defer {
                        // The extraction has actually ended (succeeded, failed, cancelled or timed
                        // out): only now is the retained security scope released.
                        session.generationActive = false
                        session.retainedLease = nil
                    }
                    guard result == .succeeded, let image, let data = Self.pngData(from: image) else {
                        let reason = result == .cancelled
                            ? "预览已取消。"
                            : Self.failureMessage(error)
                        self?.settle(session, with: .unavailable(request.key, reason), cancelGenerator: false)
                        return
                    }
                    self?.settle(session, with: .image(request.key, data: data), cancelGenerator: false)
                }
            }
        }
    }

    /// Cancel any in-flight request without reporting a result. Used when the chooser closes,
    /// switches candidates, or the surface disappears. The retained lease is released only after
    /// the last read of the source has ended, so cancellation never pulls the security scope out
    /// from under an in-flight metadata load or generator callback.
    public func cancel() {
        guard let session = active else { return }
        session.settled = true
        session.deadline?.cancel()
        session.deadline = nil
        session.generator?.cancelAllCGImageGeneration()
        session.generator = nil
        active = nil
        // If generation had already started, its callback fires `.cancelled` and releases the lease
        // when it returns; if the source-dimension load is still in flight, the lease is released
        // when that load returns. Either way the lease outlives the last read of the source.
        releaseLeaseIfIdle(session)
    }

    /// Settle exactly once. A superseded or already-settled session is a no-op, which is what
    /// makes a stale image impossible to display.
    private func settle(_ session: Session, with outcome: DailyPreviewOutcome, cancelGenerator: Bool) {
        guard !session.settled, active === session else { return }
        session.settled = true
        session.deadline?.cancel()
        session.deadline = nil
        if cancelGenerator { session.generator?.cancelAllCGImageGeneration() }
        session.generator = nil
        active = nil
        releaseLeaseIfIdle(session)
        session.completion(outcome)
    }

    /// Release the retained lease only once nothing in this request can still read the source: the
    /// asynchronous metadata load has returned and no generator callback is outstanding.
    private func releaseLeaseIfIdle(_ session: Session) {
        guard session.loadCompleted, !session.generationActive else { return }
        session.retainedLease = nil
    }

    /// Plain, user-facing reason. It never lists a path or a media-internal detail.
    private static func failureMessage(_ error: Error?) -> String {
        guard let error else { return "这段画面暂时无法生成预览。" }
        let nsError = error as NSError
        switch nsError.code {
        case NSURLErrorFileDoesNotExist, NSURLErrorNoPermissionsToReadFile:
            return "这段画面当前不可读取。"
        default:
            return "这段画面暂时无法生成预览。"
        }
    }

    /// The source's own displayed pixel size after its preferred transform (`appliesPreferredTrack-
    /// Transform` is on). Loaded with the asynchronous AVFoundation property loaders so the caller's
    /// thread (often the main thread) is never blocked by asset I/O. Best effort: missing, empty or
    /// invalid evidence simply leaves the requested bounds in place.
    private static func sourceTransformedPixelSize(of asset: AVURLAsset) async -> CGSize? {
        guard let tracks = try? await asset.loadTracks(withMediaType: .video),
              let track = tracks.first,
              let naturalSize = try? await track.load(.naturalSize),
              let preferredTransform = try? await track.load(.preferredTransform) else {
            return nil
        }
        let transformed = naturalSize.applying(preferredTransform)
        let size = CGSize(width: abs(transformed.width), height: abs(transformed.height))
        guard size.width.isFinite, size.height.isFinite, size.width >= 1, size.height >= 1 else {
            return nil
        }
        return size
    }

    /// Lossless PNG bytes for one generated still.
    ///
    /// The chooser judges one still against the live picture, so compression artifacts would be
    /// read as source quality. PNG keeps the exact decoded pixels; the byte size stays bounded by
    /// the request's pixel bounds (one bounded bitmap, never a second visual pipeline).
    public static func pngData(from image: CGImage) -> Data? {
        let representation = NSBitmapImageRep(cgImage: image)
        return representation.representation(using: .png, properties: [:])
    }
}
