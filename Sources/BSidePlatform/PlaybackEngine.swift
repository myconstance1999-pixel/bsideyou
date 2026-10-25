// BSidePlatform — PlaybackEngine: AVFoundation playback stack owned by the WallpaperAgent.
// Native system HEVC decode → AVQueuePlayer (+AVPlayerLooper) → AVPlayerLayer (ADR-001/003).
// No custom playback decoder. A suspended daily clip may retain ONE asynchronously extracted
// still image so its video queue can be released without blanking the desktop.
//
// All lifecycle decisions — whether a transition→loop install is still valid, and whether the
// ambient chain should be decoding — come from BSideCore.PlaybackLifecycle. This class only
// executes the resulting effects against AVFoundation, so the race/energy invariants are owned
// by a pure, table-tested reducer (ADR-005).

import AVFoundation
import CoreMedia
import CoreVideo
import VideoToolbox
import BSideCore

/// A daily video whose track the platform itself reports as non-playable/non-decodable in the
/// current environment. AVFoundation may still reach readyToPlay for such an item and advance
/// its clock while producing no frames, so the explicit capability result is the failure signal.
struct DailyTrackCapabilityError: LocalizedError {
    let reason: String
    var errorDescription: String? { reason }
}

public final class PlaybackEngine {
    /// Install this layer into the DesktopHost's content view.
    public let videoLayer = AVPlayerLayer()
    /// A second presentation of the SAME player, not a second playback/decoder clock.
    /// The desktop layer stays installed while this surface presents the same daily player.
    public let watchVideoLayer = AVPlayerLayer()

    public var onMirrorContentChanged: (() -> Void)?

    public func setWatchMirrorEnabled(_ enabled: Bool, aspectFit: Bool = false) {
        watchVideoLayer.player = enabled ? videoPlayer : nil
        watchVideoLayer.videoGravity = aspectFit ? .resizeAspect : videoLayer.videoGravity
        watchStillLayer.contentsGravity = aspectFit ? .resizeAspect : .resizeAspectFill
        syncWatchStill()
    }


    private let videoPlayer = AVQueuePlayer()
    private var videoLooper: AVPlayerLooper?
    private let ambientPlayer = AVQueuePlayer()
    private var ambientLooper: AVPlayerLooper?

    /// Pure reducer owning transition/ambient lifecycle decisions (generation guard, run/stop).
    private var lifecycle = PlaybackLifecycle()

    private var singleGeneration = 0
    private var singleDiagnosticSessionID: String?
    private weak var singleDiagnosticItem: AVPlayerItem?
    private var loggedSingleLayerReady = false
    private var singleEndObserver: NSObjectProtocol?
    private var singleFailureObserver: NSObjectProtocol?
    private var singleStatusObserver: NSKeyValueObservation?
    private var singleLoadDeadline: DispatchWorkItem?
    // Natural EOF consumes this item's playback lifecycle while retaining its decoded
    // surface. Later policy/KVO events may not replay it or classify its stopped clock as a
    // stall. Only installing another item starts another lifecycle.
    private weak var completedSingleItem: AVPlayerItem?
    private var currentLoopURL: URL?
    private var transitionEndObserver: NSObjectProtocol?
    private struct DailyBoundary {
        let generation: Int
        let item: AVPlayerItem
        var completion: (() -> Void)?
    }
    private var dailyBoundary: DailyBoundary?
    private var dailyBoundaryObserver: NSObjectProtocol?

    // A discovered but unreadable daily container never becomes the player's current item, so
    // the current-item watchdog cannot see it. AVPlayerLooper's own KVO status/error is the only
    // actual load-failure signal; it is reported once per install attempt (no timer, no sampler).
    private var looperStatusObserver: NSKeyValueObservation?
    private var dailyLoadFailureReported = false

    private var watchdogTimer: Timer?
    private var watchdogWaiting = false
    private weak var watchdogItem: AVPlayerItem?
    private var watchdogTime: Double = 0
    private var playerStatusObserver: NSKeyValueObservation?
    private var playerItemObserver: NSKeyValueObservation?
    private var displayObserver: NSKeyValueObservation?
    private var reportedDailySourceURL: URL?
    private var restoreSeeking = false
    private var restoreDeadline: DispatchWorkItem?
    private var restoreTarget: (generation: Int, time: CMTime)?
    private var suspensionGeneration = 0
    private var imageGenerator: AVAssetImageGenerator?
    private var imageDeadline: DispatchWorkItem?
    private let stillLayer = CALayer()
    private let watchStillLayer = CALayer()
    private struct SuspendedDaily {
        let loopURL: URL
        let itemURL: URL
        let time: CMTime
    }
    private var suspendedDaily: SuspendedDaily?

    // A transition's actual last decoded frame is tapped from its item output and held over
    // the loop install to cover the replacement's loading interval.
    // The hold ends once a different current item is ready for display, or on any
    // replacement/stop/release path that owns the queue.
    private var transitionFrameOutput: AVPlayerItemVideoOutput?
    private weak var transitionFrameItem: AVPlayerItem?
    private var holdsTransitionFrame = false
    // An owner-planned replacement (performance start / return to daily) keeps the same retained
    // surface across its queue release until a different replacement item is ready or fails.
    // Ordinary stop/transition ownership still clears its hold; only this explicit intent defers it.
    private var holdsReplacementFrame = false
    private weak var heldFrameItem: AVPlayerItem?
    private weak var observedHoldItem: AVPlayerItem?
    private var heldFrameStatusObserver: NSKeyValueObservation?
    // The single-item entry (daily → watch performance) keeps the outgoing surface until this exact
    // incoming item has actually vended a retained non-null pixel buffer at its own current item
    // time. readyToPlay, AVPlayerLayer.isReadyForDisplay and the item clock can all describe a
    // released or not-yet-displayable picture, and AVPlayerItemVideoOutput's own contract permits
    // copyPixelBuffer to return NULL right after hasNewPixelBuffer reported new output, so a
    // non-null copy is the only accepted acquisition signal here. That copy is still only an
    // item-level decode/availability fact: it does NOT prove AVPlayerLayer composed or presented
    // the image, and it is not a gap-free guarantee. The output belongs to the exact incoming item;
    // the retained predecessor additionally waits for layer readiness before release, and every
    // clear/failure/cancel/replacement/stop/teardown path retires this acquisition.
    //
    // The incoming item is allowed to advance under the retained predecessor: the latest policy
    // request is never overridden by the gate, so no artificial pause is added. Because KVO has no
    // guaranteed event after a NULL copy, one temporary display-refresh callback retries the copy
    // while the request is active. It is not a renderer, never samples while the policy pauses
    // visuals, and is stopped on acquisition, pause, failure, cancellation, replacement, stop or
    // teardown. A single bounded active-request budget (user pause excluded, never reset by a NULL)
    // limits the retry and reports failure through the existing single-item completion path. The
    // refresh callback and the budget deadline each capture the acquisition identity (token, exact
    // item, generation) that created them and re-validate it before acting, so neither a queued
    // refresh nor an expired deadline from a retired handoff can touch its successor.
    private var firstFrameOutput: AVPlayerItemVideoOutput?
    private weak var firstFrameItem: AVPlayerItem?
    private var incomingSourceFrameReady: (() -> Void)?
    private var awaitsIncomingFirstFrame = false
    /// The `singleGeneration` that armed this acquisition; any replacement increments it and retires
    /// the gate, so a stale callback can never observe or clear a successor's cover.
    private var incomingFrameGeneration = 0
    /// Monotonic identity of the armed acquisition. The display-refresh handler and the budget
    /// deadline capture this token (with the exact item and generation) when they are created and
    /// re-validate it before acting, so a queued refresh or a cancelled/replaced/paused deadline can
    /// only ever affect the acquisition that created it — never a successor whose mutable latest
    /// fields happen to match.
    private var incomingFrameAcquisitionToken = 0
    /// The retained non-null buffer copied for the exact incoming item; released on reveal/retire.
    private var incomingFrameRetainedBuffer: CVPixelBuffer?
    /// Existing `playOnce` failure path, retained so the acquisition budget cannot report success.
    private var incomingFrameFailureHandler: ((String?) -> Void)?
    /// Temporary display-refresh retry driver (CoreVideo, available on the minimum OS). It drives
    /// acquisition only and stops immediately on every terminal transition; it is not a renderer.
    private var incomingFrameDisplayLink: CVDisplayLink?
    private let incomingFrameSampleLock = NSLock()
    /// Token of the acquisition whose main-queue sample is already queued; `nil` means none. The
    /// token is captured with the block, so a retired acquisition's queued sample can neither claim
    /// nor clear a successor's coalescing state.
    private var incomingFrameSampleScheduledToken: Int?
    private var incomingFrameBudgetDeadline: DispatchWorkItem?
    private var incomingFrameBudgetRemaining: TimeInterval = 0
    private var incomingFrameBudgetActiveSince: CFTimeInterval?
    private var incomingFrameHoldStartedAt: CFTimeInterval = 0
    /// Bounded active-request acquisition budget. It counts waits while the exact request is
    /// active, excludes policy pause, and is never reset by a NULL copy. Same order as the
    /// engine's existing 8-second waiting deadlines.
    private static let incomingFrameAcquisitionBudget: TimeInterval = 8

    // Prepare one outgoing frame only while a natural-EOF boundary is pending. Decoding it
    // during the handoff left a visible blank interval with the reviewed day source; preparing
    // it beforehand lets the existing still layer cover that interval without a decoder open.
    private var dailyEOFFrame: CGImage?
    private weak var dailyEOFFrameItem: AVPlayerItem?
    private var dailyEOFFrameGenerator: AVAssetImageGenerator?

    public var hasVideoResources: Bool { videoPlayer.currentItem != nil }
    /// The looper may still be loading its template (or delivering its load-failure callback).
    /// An unrelated owner reevaluation must not start the same installation again in this gap.
    public var hasPendingDailyLoopLoad: Bool { videoLooper != nil && videoPlayer.currentItem == nil }
    public var hasRetainedFrame: Bool { stillLayer.contents != nil }
    /// Observation-only: a natural-EOF handoff frame has been prepared and not yet consumed.
    /// A consumed boundary (genuine EOF) must keep it until the successor install holds it;
    /// a withdrawn pending request discards it. No playback decision reads this.
    public var hasPreparedDailyEOFFrame: Bool { dailyEOFFrame != nil }
    /// Observation-only handles for the confirmed-history media-clock observer. Playback
    /// decisions still flow only through the existing policy methods; nothing below mutates.
    public var videoObservationPlayer: AVPlayer { videoPlayer }
    public var ambientObservationPlayer: AVPlayer { ambientPlayer }
    public var visualPaused: Bool { isVisualPaused }
    public var musicOutputVolume: Double { Double(videoPlayer.volume) }
    public var ambientOutputVolume: Double { Double(ambientPlayer.volume) }
    public var hasAmbientResources: Bool { ambientPlayer.currentItem != nil }
    /// Includes a loading or explicitly paused chain whose source access must remain alive.
    public var retainsAmbientSource: Bool { lifecycle.ambientRetained }
    /// The actual daily source, including a released item's resumable position. An ended
    /// transition stops being the source once its loop is installed; performances return nil.
    /// A cold-start poster has no installed/resumable item and also returns nil. This is
    /// source identity, not a displayed-frame or advancing-media signal for history totals.
    public var dailySourceURL: URL? {
        guard currentLoopURL != nil else { return nil }
        if let asset = videoPlayer.currentItem?.asset as? AVURLAsset { return asset.url }
        return suspendedDaily?.itemURL
    }

    /// Set by the owner after init (avoids self-capture during construction).
    public var onPlaybackStalled: (() -> Void)?
    /// Main-queue report of a daily loop whose actual looper/asset load failed (for example a
    /// malformed or truncated container). The error is AVPlayerLooper's real error, not a retry
    /// budget or readiness guess, and delivers at most once per install attempt. The failed queue
    /// is already released when this fires; the owner decides whether to latch/retry/report.
    public var onDailyLoadFailed: ((Error?) -> Void)?
    /// Main-queue notification of a changed actual/resumable daily URL. The receiver reads
    /// dailySourceURL now; queued item observations never carry an obsolete phase or plan.
    public var onDailySourceChanged: (() -> Void)?

    private(set) var isVisualPaused = false
    private var holdsCompletedSingleItem: Bool {
        guard let completedSingleItem else { return false }
        return videoPlayer.currentItem === completedSingleItem
    }

    public init() {
        videoLayer.player = videoPlayer
        videoLayer.videoGravity = .resizeAspectFill
        videoPlayer.actionAtItemEnd = .none
        videoPlayer.automaticallyWaitsToMinimizeStalling = false
        // Explicit songs may outlive their fullscreen Space. Core still pauses on user/system
        // restrictions; do not let AVFoundation choose an unrelated background pause policy.
        videoPlayer.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        ambientPlayer.actionAtItemEnd = .none
        stillLayer.contentsGravity = .resizeAspectFill
        stillLayer.masksToBounds = true
        stillLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        watchStillLayer.contentsGravity = .resizeAspectFill
        watchStillLayer.masksToBounds = true
        watchStillLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        playerStatusObserver = videoPlayer.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.reconcileWatchdog() }
        }
        playerItemObserver = videoPlayer.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.reconcileWatchdog()
                self?.publishDailySourceIfChanged()
                self?.releaseHeldFrameIfReplaced()
            }
        }
        displayObserver = videoLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.logSingleLayerReadyIfNeeded()
                self?.removeStillWhenReady()
            }
        }
    }

    deinit {
        // A hard deallocation without teardown must not leave the display-refresh retry running.
        stopIncomingFrameDisplayLink()
        incomingFrameBudgetDeadline?.cancel()
    }

    private func publishDailySourceIfChanged() {
        let source = dailySourceURL
        guard source != reportedDailySourceURL else { return }
        reportedDailySourceURL = source
        onDailySourceChanged?()
    }

    private func scheduleDailySourceCheck() {
        DispatchQueue.main.async { [weak self] in self?.publishDailySourceIfChanged() }
    }

    // MARK: - Video (loop + optional transition)

    /// Start (or switch) playback: optional transition clip, then the loop clip looping forever.
    /// `entryOffset` is the one explicit one-shot entry: play the FULL source from that authored
    /// offset to its natural end, then loop it from zero. It is not a suspended restoration and
    /// is consumed by this call only, so normal EOF/pause/resume can never reapply it.
    public func play(transitionURL: URL?, loopURL: URL, entryOffset: CMTime? = nil) {
        // Only a positive, numeric authored offset is a real entry point; anything else falls
        // back to the ordinary install instead of inventing a position.
        let entryTime = entryOffset.flatMap { $0.isNumeric && $0.seconds > 0 ? $0 : nil }
        // An explicit entry is a NEW request and supersedes any retained suspended position:
        // resuming the old point would silently ignore the click. Ordinary recovery (no entry)
        // still restores the saved position.
        let resume = entryTime == nil
            ? suspendedDaily.flatMap { $0.loopURL == loopURL ? $0 : nil } : nil
        // Cover the observed loop-to-transition queue swap with the outgoing item's actual
        // media-time frame. Other replacement/recovery paths retain their existing ownership.
        let outgoingItem = videoPlayer.currentItem
        cancelFrameCapture()
        if transitionURL != nil || entryTime != nil, resume == nil {
            holdDisplayedFrameIfAvailable(outgoingItem: outgoingItem)
        }
        suspendedDaily = nil
        videoLayer.player = videoPlayer
        cancelSinglePlayback()
        cancelTransitionObserver()
        // AVPlayerLooper can have an asynchronous insertion pending.  Dropping the reference is
        // insufficient: disable it before clearing the queue or the old looper may insert an item
        // into the new generation and collide with the replacement item.
        clearVideoQueue()
        currentLoopURL = loopURL

        let loopItem = AVPlayerItem(url: loopURL)
        // A suspended partial item is restored, and an explicit one-shot entry is a fresh partial
        // install of the SAME full source at its authored offset. Both play to the source's
        // natural end and then arm the ordinary full-source loop from zero — never an
        // activity-only segment or a custom segment EOF. Seeking a newly armed AVPlayerLooper can
        // be reset by its asynchronous replica inserts, so one ordinary item plays first.
        let phaseURL = entryTime != nil ? loopURL : (resume?.itemURL ?? transitionURL)
        let phaseStart = entryTime ?? resume?.time
        if let phaseURL {
            // Phase 1: play the transition; Phase 2 on its end: arm the looper.
            // The generation token + current-item guard make a stale end callback a no-op even
            // if observer removal races — we never rely on timing alone.
            let generation = lifecycle.beginVisual(transition: true)
            // Each install attempt reports at most once, transition or loop phase alike.
            dailyLoadFailureReported = false
            let transitionItem = AVPlayerItem(url: phaseURL)
            // Tap the transition's decoded frames so its true last image can cover the loop
            // install below. Default suppressesPlayerRendering keeps normal player rendering.
            let frameOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ])
            transitionItem.add(frameOutput)
            transitionFrameOutput = frameOutput
            transitionFrameItem = transitionItem
            videoPlayer.replaceCurrentItem(with: transitionItem)
            // Replacing the item must not defeat an already-applied pause intent.  The
            // transition-end callback also goes through installLoop(), which repeats this
            // guard for the loop phase.
            restorePosition(phaseStart)
            // The transition is the actual daily item on screen now. Validate it before/while it
            // begins so an unsupported clip fails the install instead of staying black to its EOF
            // and only then handing off to a loop.
            validateDailyTransitionCapability(item: transitionItem, generation: generation)
            transitionEndObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: transitionItem, queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                // Current-item guard: the clip that ended must still be what the player is showing.
                guard self.videoPlayer.currentItem === transitionItem else { return }
                // Generation/token guard: only the current visual target may install its loop.
                if self.lifecycle.transitionEnded(generation: generation) {
                    self.cancelTransitionObserver()
                    // Hold the transition's actual final frame now, before the owner may
                    // retarget: the still becomes the displayed picture the moment the item
                    // is replaced, and every replacement/stop path clears it again.
                    if let output = self.transitionFrameOutput, self.transitionFrameItem === transitionItem,
                       let frame = self.copyTransitionFrame(item: transitionItem, output: output) {
                        self.installStill(frame)
                        self.holdsTransitionFrame = true
                        self.heldFrameItem = transitionItem
                    }
                    self.transitionFrameOutput = nil
                    self.transitionFrameItem = nil
                    self.consumeDailyBoundary(item: transitionItem, generation: generation)?()
                    // The owner may have installed its latest target, released resources or
                    // stopped while handling the boundary. Never append the old loop afterwards.
                    guard self.lifecycle.visualGeneration == generation,
                          self.videoPlayer.currentItem === transitionItem else { return }
                    self.installLoop(item: loopItem)
                    self.releaseHeldFrameIfReplaced()
                }
            }
        } else {
            lifecycle.beginVisual(transition: false)
            installLoop(item: loopItem)
        }
    }

    /// Finish the actual daily item already on screen before notifying the owner. The owner
    /// must resolve its latest desired target in the callback; no future selection is retained
    /// here. Returns false for a still/empty queue or single performance, which has no live daily
    /// boundary. Repeated requests update the callback without restarting the current unit.
    @discardableResult
    public func finishCurrentDailyUnit(_ completion: @escaping () -> Void) -> Bool {
        guard let loopURL = currentLoopURL, let item = videoPlayer.currentItem else { return false }
        let generation = lifecycle.visualGeneration
        if dailyBoundary?.generation == generation, dailyBoundary?.item === item {
            dailyBoundary?.completion = completion
            // A withdrawn boundary releases the prefetch; a later request on the same item restarts
            // it. A still-running or already-finished prefetch is left untouched.
            if dailyEOFFrame == nil, dailyEOFFrameGenerator == nil {
                prefetchDailyEOFFrame(for: item)
            }
            return true
        }
        invalidateDailyBoundary()
        dailyBoundary = DailyBoundary(generation: generation, item: item, completion: completion)
        // A transition, including a restored partial daily item, already has an end observer.
        // That observer consumes this request before deciding whether its old loop is needed.
        guard !lifecycle.transitionPending else { return true }

        prefetchDailyEOFFrame(for: item)
        dailyBoundaryObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self, weak item] _ in
            guard let self, let item, self.lifecycle.visualGeneration == generation,
                  self.dailyBoundary?.generation == generation, self.dailyBoundary?.item === item else { return }
            let callback = self.consumeDailyBoundary(item: item, generation: generation)
            callback?()
            guard self.lifecycle.visualGeneration == generation, self.currentLoopURL == loopURL,
                  self.videoPlayer.currentItem === item || self.videoPlayer.currentItem == nil else { return }
            // disableLooping may remove its last replica at the end. If the owner cancelled
            // its target (or only paused), rebuild the original loop after this legal boundary.
            self.clearVideoQueue()
            self.installLoop(item: AVPlayerItem(url: loopURL))
        }
        // The looper's template never plays. disableLooping lets this captured actual replica
        // finish and prevents another replica from starting; do not clear/replace it early.
        videoLooper?.disableLooping()
        return true
    }

    /// Withdraw the owner's switch while allowing an already-disabled looper to drain and
    /// restart naturally. Removing that internal end handler would leave daily playback stuck.
    /// A boundary the genuine EOF already consumed leaves no pending request: the prepared
    /// handoff frame is then the frame the imminent successor install must hold, so it is kept
    /// for `play`. Cancelling an actual pending request before that EOF still discards it.
    public func cancelPendingDailyBoundary() {
        guard dailyBoundary != nil else { return }
        dailyBoundary?.completion = nil
        cancelDailyEOFFramePrefetch()
    }

    private func consumeDailyBoundary(item: AVPlayerItem, generation: Int) -> (() -> Void)? {
        guard dailyBoundary?.generation == generation, dailyBoundary?.item === item else { return nil }
        let callback = dailyBoundary?.completion
        invalidateDailyBoundary()
        return callback
    }

    private func invalidateDailyBoundary() {
        dailyBoundary = nil
        if let dailyBoundaryObserver { NotificationCenter.default.removeObserver(dailyBoundaryObserver) }
        dailyBoundaryObserver = nil
    }

    /// Single audiovisual item owned by this engine: one clock and no looper.
    /// Caller supplies policy intent before installation. Completion is at most once and
    /// invalidated by any subsequent install/stop, including already-enqueued callbacks.
    public func playOnce(url: URL, diagnosticSessionID: String? = nil, onReady: @escaping () -> Void,
                         onSourceFrameReady: (() -> Void)? = nil, completion: @escaping (String?) -> Void) {
        cancelFrameCapture()
        suspendedDaily = nil
        videoLayer.player = videoPlayer
        cancelSinglePlayback()
        cancelTransitionObserver()
        lifecycle.beginVisual(transition: false)
        clearVideoQueue()
        currentLoopURL = nil
        scheduleDailySourceCheck()
        let token = singleGeneration
        let item = AVPlayerItem(url: url)
        singleDiagnosticSessionID = diagnosticSessionID
        singleDiagnosticItem = item
        AppLog.info("performance.video-install session=\(diagnosticSessionID ?? "none") generation=\(token) paused=\(isVisualPaused) retained-frame=\(hasRetainedFrame)")
        videoPlayer.actionAtItemEnd = .pause
        let finish: (String?) -> Void = { [weak self, weak item] error in
            guard let self, let item, self.singleGeneration == token,
                  self.videoPlayer.currentItem === item else { return }
            AppLog.info("performance.video-finish session=\(diagnosticSessionID ?? "none") generation=\(token) failed=\(error != nil)")
            self.cancelSinglePlayback()
            if error == nil {
                self.completedSingleItem = item
                self.videoPlayer.actionAtItemEnd = .pause
                self.videoPlayer.pause()
            } else {
                self.discardDisplayedFrameHold()
            }
            completion(error)
        }
        // A replacement handoff must not drop the retained predecessor until this exact incoming
        // item has vended a retained non-null pixel buffer. Arm that acquisition before install;
        // the incoming item still advances under the retained predecessor (it is never held paused
        // for the gate), and a cold install has no retained surface and needs no acquisition.
        if holdsTransitionFrame || onSourceFrameReady != nil {
            armFirstFrameGate(for: item, onFailure: finish)
            // A hidden dedicated song engine has no composed layer yet. Its real decoded buffer
            // admits the explicit presentation action; it does not claim visible composition.
            incomingSourceFrameReady = onSourceFrameReady
        }
        singleEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            // An item that reaches its end before its own first frame was ever acquired has not
            // produced a startable picture. Report the acquisition failure rather than a
            // successful (held/frozen) single-image entry; ordinary EOF handling is unchanged.
            if let self, self.awaitsIncomingFirstFrame, self.incomingFrameRetainedBuffer == nil, self.firstFrameItem === item {
                self.failIncomingFrameAcquisition("演奏视频未能在结束前解码出画面")
            } else {
                finish(nil)
            }
        }
        singleFailureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { notification in
            finish((notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?
                .localizedDescription ?? "演奏播放中断")
        }
        singleStatusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self, self.singleGeneration == token,
                      self.videoPlayer.currentItem === item else { return }
                if item.status == .failed { finish(item.error?.localizedDescription ?? "演奏加载失败") }
                if item.status == .readyToPlay {
                    self.singleLoadDeadline?.cancel()
                    self.singleLoadDeadline = nil
                    self.singleStatusObserver = nil
                    AppLog.info("performance.video-item-ready session=\(diagnosticSessionID ?? "none") generation=\(token) paused=\(self.isVisualPaused) desktop-layer-ready=\(self.videoLayer.isReadyForDisplay) watch-layer-ready=\(self.watchVideoLayer.isReadyForDisplay)")
                    self.logSingleLayerReadyIfNeeded()
                    onReady()
                    self.removeStillWhenReady()
                    self.reconcileWatchdog()
                }
            }
        }
        let deadline = DispatchWorkItem { finish("演奏加载超时，请检查素材磁盘") }
        singleLoadDeadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: deadline)
        videoPlayer.replaceCurrentItem(with: item)
        applyVisualIntent()
    }

    private func cancelSinglePlayback() {
        singleGeneration += 1
        singleDiagnosticSessionID = nil
        singleDiagnosticItem = nil
        loggedSingleLayerReady = false
        completedSingleItem = nil
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        cancelFirstFrameGate()
        if let singleEndObserver { NotificationCenter.default.removeObserver(singleEndObserver) }
        if let singleFailureObserver { NotificationCenter.default.removeObserver(singleFailureObserver) }
        singleEndObserver = nil
        singleFailureObserver = nil
        singleStatusObserver = nil
        singleLoadDeadline?.cancel()
        singleLoadDeadline = nil
        videoPlayer.actionAtItemEnd = .none
    }

    /// Owner-planned replacement: retain the outgoing item's actual displayed source frame before
    /// releasing the queue, so the desktop keeps real pixels through the target's asynchronous
    /// identity validation/load. The hold belongs to the replacement transaction (not playback);
    /// it ends once a different item is ready — a single-item entry waits for that item's own first
    /// decoded frame — or on `discardDisplayedFrameHold`.
    /// Call this immediately before the queued release (`stopVideo`) or successor install.
    public func retainDisplayedFrameForReplacement() {
        if !holdsTransitionFrame {
            if stillLayer.contents != nil {
                // A paused daily item may already have released its queue/decoder. Its retained
                // image remains valid and must survive the same replacement transaction.
                holdsTransitionFrame = true
                heldFrameItem = videoPlayer.currentItem
            } else {
                holdDisplayedFrameIfAvailable(outgoingItem: videoPlayer.currentItem)
            }
        }
        // An already-held transition/last frame is adopted into the replacement transaction.
        holdsReplacementFrame = holdsTransitionFrame
    }

    /// Abandon a replacement hold whose target never installed (failed/aborted start, no successor,
    /// hard stop/shutdown). No-op for an ordinary transition/loop hold.
    public func discardDisplayedFrameHold() {
        guard holdsReplacementFrame else { return }
        clearHeldFrame()
    }

    /// Release the current video without destroying the engine/watchdog. Used before async
    /// performance validation and on session end so stale media cannot keep sounding. A frame the
    /// owner explicitly retained for a planned replacement survives this release; every other
    /// still/hold is cleared with the queue as before.
    public func stopVideo() {
        cancelFrameCapture()
        suspendedDaily = nil
        if !holdsReplacementFrame {
            clearHeldFrame()
            stillLayer.contents = nil
        }
        cancelSinglePlayback()
        cancelTransitionObserver()
        lifecycle.beginVisual(transition: false)
        clearVideoQueue()
        currentLoopURL = nil
        // A released daily item has no currentItem KVO left to report its cleared source.
        scheduleDailySourceCheck()
    }

    private func installLoop(item: AVPlayerItem) {
        let generation = lifecycle.visualGeneration
        let looper = AVPlayerLooper(player: videoPlayer, templateItem: item)
        videoLooper = looper
        observeLoopLoad(looper: looper, generation: generation)
        validateDailyTrackCapability(item: item, looper: looper, generation: generation)
        // play() is also used to reload/switch content.  A paused policy must survive that
        // operation; only setVisualPaused(false) is allowed to resume the player.
        restorePosition(nil)
    }

    /// Authoritative capability query shared by the daily transition and loop installs. A
    /// false-success source can keep its looper status healthy and its item ready while every frame
    /// fails to decode, so ask AVFoundation for the actual track capability and route a
    /// negative/missing/error result into the same once-per-install failure path. The async loader
    /// is static and captures no engine state; the generation and item/looper identity guards below
    /// keep an in-flight query from stopping newer valid playback.
    private static func trackCapabilityFailure(for asset: AVAsset) async -> String? {
        do {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                return "每日视频缺少可用的视频轨道"
            }
            let playable = try await track.load(.isPlayable)
            let decodable = try await track.load(.isDecodable)
            guard playable, decodable else {
                return "每日视频在当前设备上无法播放或解码"
            }
            return nil
        } catch {
            // A genuine asset/track read error keeps its underlying description for diagnosis.
            return "每日视频读取失败：\(error.localizedDescription)"
        }
    }

    private func validateDailyTrackCapability(item: AVPlayerItem, looper: AVPlayerLooper, generation: Int) {
        let asset = item.asset
        Task { @MainActor [weak self] in
            guard let reason = await Self.trackCapabilityFailure(for: asset) else { return }
            guard let self, generation == self.lifecycle.visualGeneration,
                  self.videoLooper === looper else { return }
            self.reportLoopLoadFailure(DailyTrackCapabilityError(reason: reason),
                                       looper: looper, generation: generation)
        }
    }

    private func validateDailyTransitionCapability(item: AVPlayerItem, generation: Int) {
        let asset = item.asset
        Task { @MainActor [weak self] in
            guard let reason = await Self.trackCapabilityFailure(for: asset) else { return }
            guard let self, generation == self.lifecycle.visualGeneration,
                  self.videoPlayer.currentItem === item else { return }
            self.reportTransitionLoadFailure(DailyTrackCapabilityError(reason: reason),
                                             item: item, generation: generation)
        }
    }

    /// Event-driven detection of a failed loop load. AVPlayerLooper loads its template asset
    /// asynchronously and reports the real error through its KVO-observable status; the template
    /// item never becomes currentItem, so nothing else in the engine can observe this at all.
    private func observeLoopLoad(looper: AVPlayerLooper, generation: Int) {
        dailyLoadFailureReported = false
        looperStatusObserver = looper.observe(\.status, options: [.initial, .new]) { [weak self] looper, _ in
            guard looper.status == .failed else { return }
            DispatchQueue.main.async {
                self?.reportLoopLoadFailure(looper.error, looper: looper, generation: generation)
            }
        }
    }

    /// Report the actual load failure once, then release the failed queue. `currentLoopURL` is
    /// kept as the failed source's identity so the owner can refuse an unchanged silent reinstall.
    private func reportLoopLoadFailure(_ error: Error?, looper: AVPlayerLooper, generation: Int) {
        guard !dailyLoadFailureReported, generation == lifecycle.visualGeneration,
              videoLooper === looper else { return }
        finishDailyLoadFailure(error)
    }

    /// The same once-per-install failure path for the transition phase, which has no looper. The
    /// transition item must still be the item on screen; a newer loop/transition that already
    /// replaced it must not be stopped by this stale completion.
    private func reportTransitionLoadFailure(_ error: Error?, item: AVPlayerItem, generation: Int) {
        guard !dailyLoadFailureReported, generation == lifecycle.visualGeneration,
              videoPlayer.currentItem === item else { return }
        finishDailyLoadFailure(error)
    }

    private func finishDailyLoadFailure(_ error: Error?) {
        dailyLoadFailureReported = true
        looperStatusObserver = nil
        cancelTransitionObserver()
        // A failed looper/transition can have no current item, so item-readiness observation
        // cannot release either an ordinary transition hold or an owner replacement hold.
        clearHeldFrame()
        clearVideoQueue()
        onDailyLoadFailed?(error)
    }

    private func restorePosition(_ time: CMTime?) {
        guard let time, time.isNumeric, time.seconds > 0 else {
            applyVisualIntent()
            removeStillWhenReady()
            return
        }
        restoreSeeking = true
        let generation = lifecycle.visualGeneration
        restoreTarget = (generation, time)
        let deadline = DispatchWorkItem { [weak self] in
            guard let self, self.restoreSeeking, self.lifecycle.visualGeneration == generation else { return }
            self.restoreSeeking = false
            self.restoreDeadline = nil
            self.videoPlayer.currentItem?.cancelPendingSeeks()
            self.onPlaybackStalled?()
        }
        restoreDeadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: deadline)
        videoPlayer.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            DispatchQueue.main.async {
                guard let self, self.restoreSeeking, generation == self.lifecycle.visualGeneration else { return }
                self.restoreDeadline?.cancel()
                self.restoreDeadline = nil
                self.restoreSeeking = false
                self.restoreTarget = nil
                self.applyVisualIntent()
                self.removeStillWhenReady()
                if !finished { self.onPlaybackStalled?() }
            }
        }
    }

    private func applyVisualIntent() {
        // The acquisition gate deliberately does NOT appear here: the latest policy request
        // advances the incoming item under the retained predecessor instead of being overridden by
        // an artificial wait for pixels.
        if isVisualPaused || restoreSeeking || holdsCompletedSingleItem {
            videoPlayer.pause()
        } else {
            videoPlayer.playImmediately(atRate: 1)
        }
        reconcileWatchdog()
    }

    private func cancelTransitionObserver() {
        if let observer = transitionEndObserver {
            NotificationCenter.default.removeObserver(observer)
            transitionEndObserver = nil
        }
    }

    private func clearVideoQueue() {
        cancelFirstFrameGate()
        invalidateDailyBoundary()
        cancelDailyEOFFramePrefetch()
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        transitionFrameOutput = nil
        transitionFrameItem = nil
        videoPlayer.pause()
        videoPlayer.currentItem?.cancelPendingSeeks()
        restoreDeadline?.cancel()
        restoreDeadline = nil
        restoreSeeking = false
        restoreTarget = nil
        videoLooper?.disableLooping()
        videoLooper = nil
        looperStatusObserver = nil
        videoPlayer.removeAllItems()
    }

    public func setVisualPaused(_ paused: Bool) {
        guard paused != isVisualPaused else { return }
        isVisualPaused = paused
        if !paused { cancelFrameCapture() }
        if awaitsIncomingFirstFrame {
            if paused {
                // Policy pause stops the sampler and freezes the remaining acquisition budget,
                // but still permits the one state-transition attempt. A NULL from that attempt
                // leaves the request pending-paused behind the retained predecessor with no hidden
                // clock advancement; Resume restarts acquisition with the remaining budget.
                suspendIncomingFrameSampling()
                attemptIncomingFrameAcquisition()
            } else {
                beginIncomingFrameSampling()
            }
        }
        applyVisualIntent()
    }

    /// Daily-only resource release. A single still replaces the paused decoded surface; the
    /// current clip/position and transition phase survive. Failed extraction retains the player.
    /// Resume, replacement and stop invalidate both extraction and its bounded deadline.
    /// Completion belongs to the active extraction only; invalidation suppresses stale
    /// callbacks. Owners must clear their own pending state when cancelling, not await a result.
    public func releasePausedDaily(preservingFrame: Bool = true, completion: @escaping (Bool) -> Void) {
        guard isVisualPaused, let loopURL = currentLoopURL,
              let item = videoPlayer.currentItem, let asset = item.asset as? AVURLAsset else {
            completion(false)
            return
        }
        cancelFrameCapture()
        let token = suspensionGeneration
        // A lock can re-release a newly reconstructed item before its seek finishes. Preserve
        // the target for this resource generation, not that item's transient zero position.
        let time: CMTime
        if restoreSeeking, let target = restoreTarget, target.generation == lifecycle.visualGeneration {
            time = target.time
        } else {
            time = item.currentTime().isNumeric ? item.currentTime() : .zero
        }
        let saved = SuspendedDaily(loopURL: loopURL, itemURL: asset.url, time: time)
        let finish: (CGImage?) -> Void = { [weak self, weak item] image in
            guard let self, let item, self.isVisualPaused,
                  self.suspensionGeneration == token, self.videoPlayer.currentItem === item else { return }
            self.imageDeadline?.cancel()
            self.imageDeadline = nil
            self.imageGenerator?.cancelAllCGImageGeneration()
            self.imageGenerator = nil
            // Consume before invoking the owner; a timeout and a late image cannot both finish.
            self.suspensionGeneration += 1
            guard image != nil || !preservingFrame else { completion(false); return }
            if let image {
                self.installStill(image)
            }
            self.suspendedDaily = saved
            self.cancelTransitionObserver()
            self.lifecycle.beginVisual(transition: false)
            self.videoLayer.player = nil
            self.clearVideoQueue()
            completion(true)
        }
        guard preservingFrame else { finish(nil); return }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        imageGenerator = generator
        let deadline = DispatchWorkItem { finish(nil) }
        imageDeadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: deadline)
        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, image, _, result, _ in
            DispatchQueue.main.async { finish(result == .succeeded ? image : nil) }
        }
    }

    /// A paused cold start (including Low Power Mode) needs a desktop image, not a running
    /// video queue. Extract one first frame on demand; no looper/player item remains installed.
    /// The poster creates no saved playback position. As with releasePausedDaily, cancellation
    /// invalidates completion; the owner clears pending state when it invalidates this request.
    public func showDailyStill(loopURL: URL, completion: @escaping (Bool) -> Void) {
        guard isVisualPaused, !hasVideoResources else { completion(false); return }
        cancelFrameCapture()
        let token = suspensionGeneration
        let stillAsset = AVURLAsset(url: loopURL)
        let generator = AVAssetImageGenerator(asset: stillAsset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        imageGenerator = generator
        let finish: (CGImage?) -> Void = { [weak self] image in
            guard let self, token == self.suspensionGeneration, self.isVisualPaused,
                  !self.hasVideoResources else { return }
            self.cancelFrameCapture()
            guard let image else {
                // A still can fail transiently, but a source whose own video track AVFoundation
                // cannot play or decode can never yield one. Reuse the authoritative capability
                // query and the existing load-failure channel so a paused cold start reports the
                // failure instead of leaving a silent black desktop that still reads as ready.
                let generation = self.suspensionGeneration
                Task { @MainActor [weak self] in
                    guard let self, let reason = await Self.trackCapabilityFailure(for: stillAsset),
                          generation == self.suspensionGeneration,
                          self.isVisualPaused, !self.hasVideoResources else { completion(false); return }
                    self.onDailyLoadFailed?(DailyTrackCapabilityError(reason: reason))
                    completion(false)
                }
                return
            }
            self.installStill(image)
            self.videoLayer.player = nil
            self.currentLoopURL = loopURL
            completion(true)
        }
        let deadline = DispatchWorkItem { finish(nil) }
        imageDeadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: deadline)
        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: .zero)]) { _, image, _, result, _ in
            DispatchQueue.main.async { finish(result == .succeeded ? image : nil) }
        }
    }

    /// Cancel one-shot image work when a system event removes its visual demand.
    /// This does not alter a restoration seek or discard an already-retained image.
    public func cancelPendingStill() { cancelFrameCapture() }

    private func installStill(_ image: CGImage) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stillLayer.frame = videoLayer.bounds
        stillLayer.contents = image
        videoLayer.addSublayer(stillLayer)
        syncWatchStill()
        CATransaction.commit()
    }

    /// Share the same immutable image with the fullscreen surface; no extra capture or decoder.
    private func syncWatchStill() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        watchStillLayer.frame = watchVideoLayer.bounds
        watchStillLayer.contents = watchVideoLayer.player == nil ? nil : stillLayer.contents
        if watchStillLayer.contents != nil { watchVideoLayer.addSublayer(watchStillLayer) }
        onMirrorContentChanged?()
        CATransaction.commit()
    }

    /// Layer readiness is a presentation signal, not proof that this item's pixels were acquired.
    /// Read the live item after queued KVO delivery and emit once for its current lifecycle.
    private func logSingleLayerReadyIfNeeded() {
        guard !loggedSingleLayerReady, let sessionID = singleDiagnosticSessionID,
              let item = singleDiagnosticItem, videoPlayer.currentItem === item,
              item.status == .readyToPlay, videoLayer.isReadyForDisplay else { return }
        loggedSingleLayerReady = true
        AppLog.info("performance.video-layer-ready session=\(sessionID) generation=\(singleGeneration) retained-frame=\(hasRetainedFrame) watch-layer-ready=\(watchVideoLayer.isReadyForDisplay)")
    }

    private func cancelFrameCapture() {
        suspensionGeneration += 1
        imageDeadline?.cancel()
        imageDeadline = nil
        imageGenerator?.cancelAllCGImageGeneration()
        imageGenerator = nil
        // A replacement hold outlives the queue/capture teardown it was created for; it is
        // released by readiness/failure or by the owner's explicit discard.
        if holdsTransitionFrame, !holdsReplacementFrame { clearHeldFrame() }
    }

    /// Copy an item's currently displayable frame — at natural EOF the transition's actual last
    /// decoded sample — so a hold shows real pixels, not an invented image.
    private func copyTransitionFrame(item: AVPlayerItem, output: AVPlayerItemVideoOutput) -> CGImage? {
        var displayTime = CMTime.invalid
        guard let buffer = output.copyPixelBuffer(forItemTime: item.currentTime(),
                                                  itemTimeForDisplay: &displayTime) else { return nil }
        var image: CGImage?
        guard VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image) == noErr else { return nil }
        return image
    }

    /// Cover explicit transition entry with the outgoing item's current media-time picture.
    /// The transition phase supplies its existing output; attaching another output to a live
    /// looper replica regressed loop advancement on SDK27. Decode that replica's current
    /// timestamp instead. This is a source-frame reconstruction, not screen-pixel capture;
    /// failed decoding leaves the normal replacement path unchanged.
    private func holdDisplayedFrameIfAvailable(outgoingItem: AVPlayerItem?) {
        guard !holdsTransitionFrame, videoLayer.player === videoPlayer,
              let outgoingItem, outgoingItem === videoPlayer.currentItem else { return }
        // Use the frame prepared when the boundary was requested. Only an item at
        // or past its own end may use it, so an explicit mid-play replacement still holds its
        // real current frame.
        if itemIsAtOrPastEnd(outgoingItem), dailyEOFFrameItem === outgoingItem, let frame = dailyEOFFrame {
            dailyEOFFrame = nil
            dailyEOFFrameItem = nil
            dailyEOFFrameGenerator?.cancelAllCGImageGeneration()
            dailyEOFFrameGenerator = nil
            installStill(frame)
            holdsTransitionFrame = true
            heldFrameItem = outgoingItem
            return
        }
        guard let frame = displayedFrame(of: outgoingItem) else { return }
        installStill(frame)
        holdsTransitionFrame = true
        heldFrameItem = outgoingItem
    }

    private func itemIsAtOrPastEnd(_ item: AVPlayerItem) -> Bool {
        guard let asset = item.asset as? AVURLAsset else { return false }
        let duration = asset.duration
        let time = item.currentTime()
        return duration.isNumeric && duration.seconds > 0 && time.isNumeric && time.seconds >= duration.seconds
    }

    /// Decode one final source frame while the current unit is still playing. This does not
    /// change playback position or start a successor; cancellation/replacement discards the frame.
    private func prefetchDailyEOFFrame(for item: AVPlayerItem) {
        cancelDailyEOFFramePrefetch()
        guard let asset = item.asset as? AVURLAsset else { return }
        let duration = asset.duration
        guard duration.isNumeric, duration.seconds > 0 else { return }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        // Same clamp as the synchronous fallback: ask for the end, accept the last decoded sample.
        generator.requestedTimeToleranceAfter = .positiveInfinity
        dailyEOFFrameItem = item
        dailyEOFFrameGenerator = generator
        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: duration)]) { [weak self, weak item] _, image, _, result, _ in
            DispatchQueue.main.async {
                guard let self, let item, self.dailyEOFFrameItem === item,
                      result == .succeeded, let image else { return }
                self.dailyEOFFrame = image
            }
        }
    }

    private func cancelDailyEOFFramePrefetch() {
        dailyEOFFrameGenerator?.cancelAllCGImageGeneration()
        dailyEOFFrameGenerator = nil
        dailyEOFFrame = nil
        dailyEOFFrameItem = nil
    }

    private func displayedFrame(of item: AVPlayerItem) -> CGImage? {
        if transitionFrameOutput != nil, transitionFrameItem === item, let output = transitionFrameOutput {
            return copyTransitionFrame(item: item, output: output)
        }
        guard let asset = item.asset as? AVURLAsset else { return nil }
        let time = item.currentTime()
        guard time.isNumeric else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        // The EOF clock can overshoot duration. The synthetic regression rejects an exact
        // request beyond its end; an end request with after-tolerance returns its last sample.
        // Keep ordinary in-media requests exact. This alone did not fix the official-source flash.
        let duration = asset.duration
        if duration.isNumeric, duration.seconds > 0, time.seconds >= duration.seconds {
            generator.requestedTimeToleranceAfter = .positiveInfinity
            return try? generator.copyCGImage(at: duration, actualTime: nil)
        }
        generator.requestedTimeToleranceAfter = .zero
        return try? generator.copyCGImage(at: time, actualTime: nil)
    }

    /// End the transition-frame hold once a different current item is ready, so the hold can never
    /// hide the installed target. A replacement that is not ready yet is observed to ready; the
    /// observed item is re-targeted if the queue advances again. A failed replacement also releases
    /// the hold so no stale surface outlives a failed install. A single-item entry instead holds its
    /// own first-frame gate and is released only once that item's decoded frame exists.
    private func releaseHeldFrameIfReplaced() {
        guard holdsTransitionFrame, videoLayer.player === videoPlayer,
              let current = videoPlayer.currentItem, current !== heldFrameItem else { return }
        if current.status == .failed {
            clearHeldFrame()
            return
        }
        if current.status == .readyToPlay {
            removeStillWhenReady()
            return
        }
        guard observedHoldItem !== current else { return }
        observedHoldItem = current
        heldFrameStatusObserver = current.observe(\.status, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self, self.videoPlayer.currentItem === item else { return }
                if item.status == .failed { self.clearHeldFrame() }
                else if item.status == .readyToPlay { self.removeStillWhenReady() }
            }
        }
    }

    private func clearHeldFrame() {
        cancelFirstFrameGate()
        holdsTransitionFrame = false
        holdsReplacementFrame = false
        heldFrameItem = nil
        observedHoldItem = nil
        heldFrameStatusObserver = nil
        clearStillContents()
    }

    private func clearStillContents() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stillLayer.contents = nil
        watchStillLayer.contents = nil
        onMirrorContentChanged?()
        CATransaction.commit()
    }

    /// Attach one video output to the exact incoming single item and begin the bounded
    /// non-null-buffer acquisition. Scoped to this item and its `singleGeneration`;
    /// `cancelFirstFrameGate()` retires it from every clear/failure/cancel/replacement/stop/
    /// teardown path, so no observation or callback can outlive its install. A cold install has no
    /// retained predecessor and never arms this.
    private func armFirstFrameGate(for item: AVPlayerItem, onFailure: @escaping (String?) -> Void) {
        cancelFirstFrameGate()
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        item.add(output)
        firstFrameOutput = output
        firstFrameItem = item
        awaitsIncomingFirstFrame = true
        incomingFrameGeneration = singleGeneration
        incomingFrameAcquisitionToken += 1
        incomingFrameRetainedBuffer = nil
        incomingFrameFailureHandler = onFailure
        incomingFrameBudgetRemaining = Self.incomingFrameAcquisitionBudget
        incomingFrameBudgetActiveSince = nil
        incomingFrameHoldStartedAt = CACurrentMediaTime()
        // Sampling starts on the first readiness reconciliation below, not here: the item is not
        // current yet, and a slow/buffering load must not consume the acquisition budget.
    }

    /// Retire the acquisition completely: stop the display-refresh retry, cancel the bounded
    /// budget, detach the exact-item output, release the retained buffer and forget the owner path.
    /// Idempotent; safe from every lifecycle path.
    private func cancelFirstFrameGate() {
        stopIncomingFrameSampling()
        if let output = firstFrameOutput, let item = firstFrameItem {
            item.remove(output)
        }
        firstFrameOutput = nil
        firstFrameItem = nil
        incomingSourceFrameReady = nil
        awaitsIncomingFirstFrame = false
        incomingFrameRetainedBuffer = nil
        incomingFrameFailureHandler = nil
        incomingFrameHoldStartedAt = 0
        incomingFrameBudgetRemaining = 0
        incomingFrameBudgetActiveSince = nil
    }

    /// One display-refresh attempt for the exact incoming item. The current item and generation are
    /// validated before the item time is read, and that time is snapshotted exactly once for both
    /// the availability query and the copy.
    ///
    /// The identity captured when the queued refresh was created is compared first, so a queued
    /// block from a retired acquisition can never act on a successor that replaced it: reading the
    /// latest fields would let both mutable generations match and sample the wrong handoff.
    private func incomingFrameAcquisitionIsCurrent(token: Int, item: AVPlayerItem,
                                                   generation: Int) -> Bool {
        awaitsIncomingFirstFrame
            && incomingFrameAcquisitionToken == token
            && incomingFrameGeneration == generation
            && singleGeneration == generation
            && firstFrameItem === item
            && videoPlayer.currentItem === item
    }

    private func sampleIncomingFirstFrame(token: Int, item: AVPlayerItem, generation: Int) {
        guard incomingFrameAcquisitionIsCurrent(token: token, item: item, generation: generation),
              !isVisualPaused else { return }
        attemptIncomingFrameAcquisition()
    }

    private func attemptIncomingFrameAcquisition() {
        guard awaitsIncomingFirstFrame, !restoreSeeking, videoLayer.player === videoPlayer,
              singleGeneration == incomingFrameGeneration,
              let item = videoPlayer.currentItem, item === firstFrameItem,
              item.status == .readyToPlay else { return }
        guard itemHasVideoTrack(item) else {
            // Audio-only incoming material has no picture to acquire; the retained predecessor is
            // replaced through the existing readiness release.
            completeIncomingFrameAcquisition(displayTime: .invalid, mediaTime: item.currentTime(),
                                             copied: false)
            return
        }
        if incomingFrameRetainedBuffer != nil {
            guard !holdsTransitionFrame || videoLayer.isReadyForDisplay else { return }
            completeIncomingFrameAcquisition(displayTime: .invalid, mediaTime: item.currentTime(), copied: true)
            return
        }
        // Existing retained replacements require composition before release. A hidden song may
        // notify source readiness sooner, but that notification never removes its retained cover.
        guard incomingSourceFrameReady != nil || videoLayer.isReadyForDisplay else { return }
        guard let output = firstFrameOutput else { return }
        guard incomingFrameBudgetRemainingNow > 0 else {
            failIncomingFrameAcquisition("演奏首帧解码超时，请检查素材磁盘")
            return
        }
        let itemTime = item.currentTime()
        let queryTime = itemTime.isNumeric ? itemTime : .zero
        // hasNew=false and a NULL copy both mean "nothing displayable at this item time": the
        // retained predecessor stays and the retry continues within the active budget. The SDK
        // explicitly permits a NULL return here even when hasNewPixelBuffer reported new output.
        guard output.hasNewPixelBuffer(forItemTime: queryTime) else { return }
        var displayTime = CMTime.invalid
        guard let buffer = output.copyPixelBuffer(forItemTime: queryTime,
                                                  itemTimeForDisplay: &displayTime) else { return }
        incomingFrameRetainedBuffer = buffer
        let sourceReady = incomingSourceFrameReady
        incomingSourceFrameReady = nil
        stopIncomingFrameSampling()
        if sourceReady != nil {
            AppLog.info("performance.source-frame-ready session=\(singleDiagnosticSessionID ?? "none") generation=\(singleGeneration) layer-ready=\(videoLayer.isReadyForDisplay) retained-cover=\(holdsTransitionFrame)")
        }
        sourceReady?()
        guard firstFrameItem === item, videoPlayer.currentItem === item,
              awaitsIncomingFirstFrame else { return }
        guard !holdsTransitionFrame || videoLayer.isReadyForDisplay else { return }
        completeIncomingFrameAcquisition(displayTime: displayTime, mediaTime: itemTime, copied: true)
    }

    /// Replace the retained predecessor once a real (or not-required) incoming picture exists.
    /// `clearHeldFrame()` retires the exact-item output before the cover contents are cleared — the
    /// same output-removal boundary as the reviewed candidate — and the acquired buffer is released
    /// here, never handed to a separate consumer.
    ///
    /// `clearHeldFrame()` reaches `cancelFirstFrameGate()`, which drops the engine's own reference to
    /// the copied buffer *before* `clearStillContents()` and the reveal. A local strong reference
    /// plus `withExtendedLifetime` keeps the actual copied buffer alive through that whole reveal
    /// despite the lifecycle cleanup.
    private func completeIncomingFrameAcquisition(displayTime: CMTime, mediaTime: CMTime,
                                                  copied: Bool) {
        let elapsed = incomingFrameHoldStartedAt > 0
            ? CACurrentMediaTime() - incomingFrameHoldStartedAt : 0
        let remaining = incomingFrameBudgetRemainingNow
        let revealedBuffer = incomingFrameRetainedBuffer
        let size = revealedBuffer.map {
            "\(CVPixelBufferGetWidth($0))x\(CVPixelBufferGetHeight($0))"
        } ?? "-"
        withExtendedLifetime(revealedBuffer) {
            clearHeldFrame()
            incomingFrameRetainedBuffer = nil
            let displaySeconds = displayTime.isNumeric ? displayTime.seconds : -1
            let mediaSeconds = mediaTime.isNumeric ? mediaTime.seconds : -1
            AppLog.info("incoming-frame acquired session=\(singleDiagnosticSessionID ?? "none") generation=\(singleGeneration) copied=\(copied) size=\(size)"
                + " displayTime=\(String(format: "%.3f", displaySeconds))"
                + " mediaTime=\(String(format: "%.3f", mediaSeconds))"
                + " holdSeconds=\(String(format: "%.3f", elapsed))"
                + " budgetRemaining=\(String(format: "%.3f", remaining))")
            applyVisualIntent()
        }
    }

    private var incomingFrameBudgetRemainingNow: TimeInterval {
        guard let since = incomingFrameBudgetActiveSince else { return incomingFrameBudgetRemaining }
        return max(0, incomingFrameBudgetRemaining - (CACurrentMediaTime() - since))
    }

    /// Start the display-refresh retry and, once, the active-request budget. The budget begins with
    /// the active request so a slow load cannot consume it, and it is never reset by a NULL copy.
    private func beginIncomingFrameSampling() {
        guard awaitsIncomingFirstFrame, incomingFrameRetainedBuffer == nil, !isVisualPaused, !restoreSeeking,
              let item = videoPlayer.currentItem, item === firstFrameItem,
              item.status == .readyToPlay else { return }
        if incomingFrameBudgetActiveSince == nil {
            guard incomingFrameBudgetRemaining > 0 else {
                failIncomingFrameAcquisition("演奏首帧解码超时，请检查素材磁盘")
                return
            }
            incomingFrameBudgetActiveSince = CACurrentMediaTime()
            armIncomingFrameBudgetDeadline()
        }
        startIncomingFrameDisplayLink()
    }

    /// Policy pause suspends the sampler and freezes the remaining budget; the caller still permits
    /// the one state-transition attempt. Resume calls `beginIncomingFrameSampling()` with whatever
    /// budget remains.
    private func suspendIncomingFrameSampling() {
        if let since = incomingFrameBudgetActiveSince {
            incomingFrameBudgetRemaining = max(0, incomingFrameBudgetRemaining - (CACurrentMediaTime() - since))
            incomingFrameBudgetActiveSince = nil
        }
        stopIncomingFrameDisplayLink()
        incomingFrameBudgetDeadline?.cancel()
        incomingFrameBudgetDeadline = nil
    }

    /// Fully stop the sampler and budget without changing the request state (used on retire).
    private func stopIncomingFrameSampling() {
        stopIncomingFrameDisplayLink()
        incomingFrameBudgetDeadline?.cancel()
        incomingFrameBudgetDeadline = nil
        incomingFrameBudgetActiveSince = nil
    }

    private func armIncomingFrameBudgetDeadline() {
        incomingFrameBudgetDeadline?.cancel()
        guard let intervalStartedAt = incomingFrameBudgetActiveSince else {
            incomingFrameBudgetDeadline = nil
            return
        }
        let remaining = incomingFrameBudgetRemaining
        guard remaining > 0 else {
            incomingFrameBudgetDeadline = nil
            return
        }
        // The deadline captures the acquisition and the active-budget interval that armed it. A
        // cancelled/replaced/paused deadline therefore cannot zero a successor's budget or fail its
        // handler; only this exact acquisition, still inside this exact interval, may be retired.
        let token = incomingFrameAcquisitionToken
        let generation = incomingFrameGeneration
        let deadline = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.incomingFrameAcquisitionToken == token,
                  self.incomingFrameGeneration == generation,
                  self.awaitsIncomingFirstFrame,
                  let stillActiveSince = self.incomingFrameBudgetActiveSince,
                  stillActiveSince == intervalStartedAt else { return }
            self.incomingFrameBudgetDeadline = nil
            self.incomingFrameBudgetRemaining = 0
            self.incomingFrameBudgetActiveSince = nil
            self.failIncomingFrameAcquisition("演奏首帧解码超时，请检查素材磁盘")
        }
        incomingFrameBudgetDeadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: deadline)
    }

    /// Retire the acquisition, then report through the existing single-item failure owner path so a
    /// held/frozen cover can never be reported as success.
    private func failIncomingFrameAcquisition(_ message: String) {
        let failure = incomingFrameFailureHandler
        AppLog.error("incoming-frame acquisition failed session=\(singleDiagnosticSessionID ?? "none") generation=\(singleGeneration): \(message)")
        cancelFirstFrameGate()
        failure?(message)
    }

    /// Temporary display-refresh retry. A display-refresh callback — not a renderer and not a
    /// generic timer — is the retry source because copyPixelBuffer may return NULL after
    /// hasNewPixelBuffer reported new output and no KVO event follows. The handler coalesces to at
    /// most one main-queue sample per acquisition and is stopped on every terminal transition.
    ///
    /// The handler and its queued main block capture the acquisition identity that existed when the
    /// link was created; that identity — not the latest fields — decides whether the sample may run.
    private func startIncomingFrameDisplayLink() {
        guard incomingFrameDisplayLink == nil else { return }
        guard let item = firstFrameItem else { return }
        let token = incomingFrameAcquisitionToken
        let generation = incomingFrameGeneration
        var link: CVDisplayLink?
        guard CVDisplayLinkCreateWithActiveCGDisplays(&link) == kCVReturnSuccess, let link else { return }
        _ = CVDisplayLinkSetOutputHandler(link) { [weak self] _, _, _, _, _ in
            guard let self else { return kCVReturnSuccess }
            self.incomingFrameSampleLock.lock()
            let alreadyScheduled = self.incomingFrameSampleScheduledToken != nil
            if !alreadyScheduled { self.incomingFrameSampleScheduledToken = token }
            self.incomingFrameSampleLock.unlock()
            guard !alreadyScheduled else { return kCVReturnSuccess }
            DispatchQueue.main.async { [weak self, weak item] in
                guard let self, let item else { return }
                self.runScheduledIncomingFrameSample(token: token, item: item, generation: generation)
            }
            return kCVReturnSuccess
        }
        incomingFrameDisplayLink = link
        _ = CVDisplayLinkStart(link)
    }

    /// Consume one queued display-refresh sample. The coalescing claim is released only while it
    /// still belongs to this queued sample, and the captured identity is re-validated before the
    /// attempt, so a retired acquisition's queued refresh leaves a successor's sampling and
    /// coalescing state untouched.
    private func runScheduledIncomingFrameSample(token: Int, item: AVPlayerItem, generation: Int) {
        incomingFrameSampleLock.lock()
        let ownsScheduledSample = incomingFrameSampleScheduledToken == token
        if ownsScheduledSample { incomingFrameSampleScheduledToken = nil }
        incomingFrameSampleLock.unlock()
        guard ownsScheduledSample else { return }
        sampleIncomingFirstFrame(token: token, item: item, generation: generation)
    }

    private func stopIncomingFrameDisplayLink() {
        if let link = incomingFrameDisplayLink {
            _ = CVDisplayLinkStop(link)
            incomingFrameDisplayLink = nil
        }
        incomingFrameSampleLock.lock()
        incomingFrameSampleScheduledToken = nil
        incomingFrameSampleLock.unlock()
    }

    private func itemHasVideoTrack(_ item: AVPlayerItem) -> Bool {
        item.tracks.contains { $0.assetTrack?.mediaType == .video }
    }

    private func removeStillWhenReady() {
        guard !restoreSeeking, videoLayer.player === videoPlayer,
              let current = videoPlayer.currentItem, current.status == .readyToPlay else { return }
        if awaitsIncomingFirstFrame {
            if holdsTransitionFrame && current === heldFrameItem { return }
            attemptIncomingFrameAcquisition()
            if awaitsIncomingFirstFrame, !isVisualPaused { beginIncomingFrameSampling() }
            return
        }
        if holdsTransitionFrame {
            guard current !== heldFrameItem, videoLayer.isReadyForDisplay else { return }
            clearHeldFrame()
            return
        }
        guard videoLayer.isReadyForDisplay else { return }
        clearStillContents()
    }

    /// Music channel: currently the video's audio track (official wallpaper clips ship without
    /// audio — music bus stays wired for future sources; volumes apply regardless).
    public func setMusicVolume(_ volume: Double) {
        videoPlayer.volume = Float(PlaybackEngine.clamp01(volume))
    }

    // MARK: - Ambient audio

    /// Explicit pause retains the current item; ordinary zero gain/source removal releases it.
    @discardableResult
    public func setAmbientTrack(url: URL?, volume: Double, paused: Bool = false) -> PlaybackLifecycle.AmbientEffect {
        let clamped = Float(PlaybackEngine.clamp01(volume))
        ambientPlayer.volume = clamped

        let effect = lifecycle.updateAmbient(urlIdentity: url?.absoluteString,
            effectiveVolume: PlaybackEngine.clamp01(volume), paused: paused)
        switch effect {
        case .none:
            break
        case .run:
            rebuildAmbient(url: url)
        case .stop:
            teardownAmbient()
        case .pause:
            ambientPlayer.pause()
        case .resume:
            ambientPlayer.play()
        }
        return effect
    }

    private func rebuildAmbient(url: URL?) {
        teardownAmbient()                 // ensure at most one chain before building the next
        guard let url else { return }
        ambientLooper = AVPlayerLooper(player: ambientPlayer, templateItem: AVPlayerItem(url: url))
        ambientPlayer.play()
    }

    private func teardownAmbient() {
        ambientLooper?.disableLooping()
        ambientLooper = nil
        ambientPlayer.removeAllItems()
    }

    // MARK: - Lifecycle

    public func teardown() {
        setWatchMirrorEnabled(false)
        // Hard lifecycle end: no replacement hold may outlive the engine.
        holdsReplacementFrame = false
        cancelFrameCapture()
        suspendedDaily = nil
        stillLayer.contents = nil
        cancelSinglePlayback()
        cancelTransitionObserver()
        lifecycle.reset()
        clearVideoQueue()
        teardownAmbient()
        scheduleDailySourceCheck()
    }

    private func reconcileWatchdog() {
        // Single-performance loading already has its own 20-second readiness deadline, and the
        // bounded incoming-frame acquisition budget owns the handoff window while it is active;
        // no separate watchdog timer is stacked alongside either.
        guard !isVisualPaused, !restoreSeeking, !holdsCompletedSingleItem, !awaitsIncomingFirstFrame,
              singleStatusObserver == nil,
              let item = videoPlayer.currentItem else {
            watchdogTimer?.invalidate()
            watchdogTimer = nil
            return
        }
        let waiting = videoPlayer.timeControlStatus != .playing
        if watchdogTimer != nil, watchdogItem === item, watchdogWaiting == waiting { return }
        watchdogTimer?.invalidate()
        watchdogWaiting = waiting
        watchdogItem = item
        watchdogTime = item.currentTime().seconds
        // Waiting/loading receives a bounded deadline. A separate 30-second active-only safety
        // check catches silent rate=1 stalls that don't deliver an AVFoundation state event.
        // No media-time sampler, and no timer at all for pause/empty queue/released resources.
        let timer = Timer(timeInterval: waiting ? 8 : 30, repeats: false) { [weak self, weak item] _ in
            guard let self, let item, self.videoPlayer.currentItem === item,
                  !self.isVisualPaused, !self.restoreSeeking, !self.holdsCompletedSingleItem else { return }
            self.watchdogTimer = nil
            let now = item.currentTime().seconds
            if item.status == .failed || self.videoPlayer.timeControlStatus != .playing ||
                (now.isFinite && self.watchdogTime.isFinite && abs(now - self.watchdogTime) < 0.01) {
                self.onPlaybackStalled?()
            } else {
                self.reconcileWatchdog()
            }
        }
        timer.tolerance = waiting ? 0.5 : 3
        watchdogTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    static func clamp01(_ v: Double) -> Double { min(max(v, 0), 1) }
}
