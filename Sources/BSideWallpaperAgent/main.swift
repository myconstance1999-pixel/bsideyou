// BSideWallpaperAgent — disposable playback process (ADR-002).
// Contract: newline JSON envelopes on stdin/stdout (ADR-007); stderr = logs; EOF or
// `shutdown` → graceful exit; orphaned (parent died) → self-terminate.

import AppKit
import CoreMedia
import Darwin
import Foundation
import BSideCore
import BSidePlatform

final class AgentRuntime {
    private let engine: PlaybackEngine
    private let songEngine = PlaybackEngine()
    private let performanceAudio = PerformanceAudioPlayer()
    private let supervisingProcessID: pid_t
    private let monitors: SystemMonitors
    private let hostController: DesktopHostController
    /// One on-demand window for the dedicated song engine. Daily retains its own desktop layer.
    private let watchPresentation = WatchPresentationHost()
    private let desktopWorkspace = DesktopWorkspaceHost()
    private var desktopWorkspaceState = DesktopWorkspacePresentation()
    private lazy var homeFrames = HomeCompanionFrameProducer(player: engine.videoObservationPlayer) { [weak self] in
        self?.currentLoopID?.rawValue ?? "daily-transition"
    }
    private var bundle: AssetBundle?
    private var dailyAccessRequest: DirectoryAccessRequest?
    private var dailyAccessLease: DirectoryAccessLease?
    // A reload may replace the catalog while paused video still belongs to the old root.
    // Keep that root alive until its video is replaced/stopped, including retained recovery.
    private var dailyVideoLease: DirectoryAccessLease?
    private var dailyAmbientLease: DirectoryAccessLease?
    private struct DailyRefreshRequest {
        let revision: UInt64
        let request: DirectoryAccessRequest
        let lease: DirectoryAccessLease?
    }
    private var dailyRefreshRevision: UInt64 = 0
    private var dailyRefreshTask: Task<AssetBundle, Error>?
    private var queuedDailyRefresh: DailyRefreshRequest?
    private var appliedDailyRefreshID: String?
    // Only accepted background discovery changes use EOF coordination. Explicit reload and
    // media recovery continue to use pendingDailyReload's existing immediate semantics.
    private var hasDailyRefreshResult = false
    private var waitingForDailyRefresh = false
    private var desired = DesiredState()
    private var currentKey: ContentKey?
    private var currentLoopID: ContentID?
    private var currentLoopURL: URL?
    private var currentLoopVersion: AssetSourceVersion?
    private struct DailySourceReference {
        let id: ContentID
        let url: URL
        let version: AssetSourceVersion?

        func differs(from bundle: AssetBundle?) -> Bool {
            url != bundle?.url(for: id) || version != bundle?.sourceVersions[id]
        }
    }
    private var currentTransitionSource: DailySourceReference?
    private var currentAmbientID: ContentID?
    private var currentAmbientURL: URL?
    private var currentAmbientVersion: AssetSourceVersion?
    private var lastSnapshot: RuntimeSnapshot?
    private var lastError: String?
    private var initialized = false
    private let startedAt = Date()
    private var clockTimer: Timer?
    private lazy var parentExitMonitor = ParentExitMonitor(parentPID: supervisingProcessID) { [weak self] in self?.shutdown() }
    private var signalSources: [DispatchSourceSignal] = []
    private var shuttingDown = false
    private var dailyResources = DailyResourceLifecycle()
    private var dailySwitch = DailySwitchLifecycle()
    // Explicit one-shot daily activity entry: transient current-session state, never persisted and
    // never replayed after Agent loss. Verification streams only the chosen reviewed file.
    private var dailyActivity = DailyActivityRequestTracker()
    private var dailyActivityTask: Task<Void, Never>?
    private var dailyActivityGeneration: UInt64 = 0
    /// The verified entry waiting to install with the desired state it carried. Cleared by a newer
    /// request, a source change or shutdown.
    private struct PendingDailyEntry {
        let requestID: String
        let sourceID: ContentID
        let offset: CMTime
        /// Fresh media identity captured around the full-hash verification. The entry installs only
        /// while the chosen file still matches it, so bytes replaced while paused are never entered.
        let version: AssetSourceVersion
    }
    private var pendingDailyEntry: PendingDailyEntry?
    // A known accepted-root loss invalidates whatever daily item is still installed/retained:
    // a later read may report identical path/version metadata while the stale item remains, so
    // accepted discovery alone cannot restore it. Cleared only by an actual fresh install.
    private var dailyInstalledMedia = DailyInstalledMediaValidity()
    // A daily source whose actual loop install failed (unreadable/malformed container). This is a
    // source-specific latch, not a retry budget: an unrelated volume/pause/visibility reevaluation
    // must not silently reinstall the same coordinates. Cleared by an actual new install attempt
    // that an explicit reload/retry/restart or a genuinely changed selected source/version permits.
    private var failedDailySource: DailySourceReference?
    private var dailyContentKeys: [ContentKey]?
    private var missingDailyContent: ContentKey?
    private var dailyAssetIssue: DailyAssetIssue?
    private var retentionTimer: Timer?
    private var memoryPressure = false
    private var pendingDailyReload = false
    private var attemptedPosterKey: ContentKey?
    private var attemptedPosterSource: DailySourceReference?
    private var dailyPosterGeneration: UInt64 = 0
    private var dailyPosterPending = false
    private var performance: PerformanceSession?
    private var isWatchingPerformance: Bool { performance?.mode == .watch }
    private var performanceAccessLease: DirectoryAccessLease?
    private var performanceTask: Task<Void, Never>?
    private var performanceGeneration: UInt64 = 0
    private var performanceReady = false
    private var performanceFrameReady = false
    private var performanceAwaitingNext = false
    private var performanceHandoffDeadline: DispatchWorkItem?
    private var lastPerformanceReport: PerformanceReport?
    private var lastPictureReport: PerformancePresentationReport?
    // Confirmed-history media-clock observation. Only attached while recording is enabled by an
    // explicit ControlApp token; spans are buffered here and flushed as one bounded batch.
    private let historyProgress = PlaybackProgressObserver()
    private var historyConfig: HistoryRecordingRequest?
    private let outputLock = NSLock()

    init() {
        supervisingProcessID = getppid()
        monitors = SystemMonitors(supervisingProcessID: supervisingProcessID)
        engine = PlaybackEngine()
        hostController = DesktopHostController(layer: engine.videoLayer)
        desktopWorkspace.onAction = { [weak self] action in self?.emit(.desktopWorkspaceAction(action)) }
        hostController.onVisibilityChanged = { [weak self] visible in
            AppLog.info("agent: host-visible=\(visible.map(String.init) ?? "unknown")")
            self?.monitors.setDesktopVisible(visible)
        }
        homeFrames.onFrame = { [weak self] frame in self?.emit(.homeCompanionFrame(frame)) }
        homeFrames.onContentReset = { [weak self] in self?.historyProgress.invalidate(role: .visual) }
        homeFrames.onFirstAcceptedFrame = { [weak self] in
            self?.historyProgress.invalidate(role: .visual)
            self?.logHomeContinuity("first-accepted-frame")
        }
        watchPresentation.onPresentationChanged = { [weak self] report in
            self?.reportPicturePresentation(report)
        }
        watchPresentation.onVisibilityChanged = { [weak self] _ in
            self?.historyProgress.invalidate(role: .visual)
        }
        songEngine.onPlaybackStalled = { [weak self] in
            guard let self, let session = self.performance, !self.performanceAwaitingNext else { return }
            self.finishPerformance(id: session.id, state: .failed, detail: "演奏停止推进，请重新点播")
        }
        engine.onPlaybackStalled = { [weak self] in self?.rebuildAfterStall() }
        engine.onDailyLoadFailed = { [weak self] error in self?.handleDailyLoadFailure(error) }
        engine.onDailySourceChanged = { [weak self] in
            guard let self, self.initialized, !self.shuttingDown else { return }
            // Report the actual phase after the engine changes source. This is observation,
            // not another reconciliation or a command to rebuild the queue at each loop.
            self.publishSnapshot(policyState: PlaybackPolicy.evaluate(
                desired: self.desired, context: self.runtimeContext(), performance: self.performance,
                performanceAwaitingNext: self.performanceAwaitingNext), selection: nil)
        }
        monitors.onContextChanged = { [weak self] in self?.reevaluate() }
        // Dedicated wake path (ADR-006): reassert the existing host's desktop level/collection
        // WITHOUT rebuilding it. `reevaluate` (via onContextChanged) reconciles policy separately.
        monitors.onWake = { [weak self] in self?.hostController.reassert() }
        monitors.onMemoryPressureChanged = { [weak self] pressure in
            // A NEW pressure event may supersede one failed visible-frame extraction. This is
            // a bounded event retry, never a timer-driven retry loop or a cache traversal.
            if pressure != .normal, let self { self.applyRetentionEffects(self.dailyResources.invalidate()) }
            self?.memoryPressure = pressure != .normal
            self?.reevaluate()
        }
        historyProgress.onConfirmed = { [weak self] submission in
            guard let self, self.historyConfig != nil, !self.shuttingDown else { return }
            // Small immediately-closed report (at most one per channel per callback). The ~30s
            // persistence batch is held by ControlApp, so no stopping supervisor is needed.
            self.emit(.historyIntervals([submission]))
        }
    }

    // MARK: - Lifecycle

    func start() {
        monitors.start()
        installSignalHandlers()
        parentExitMonitor.start()
        emit(.ready(protocolVersion: IPC.protocolVersion))
        readStdinLoop()
    }

    private func installSignalHandlers() {
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        for sig in [SIGTERM, SIGINT] {
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in self?.shutdown() }
            source.resume()
            signalSources.append(source)
        }
    }

    /// Every process-exit path revokes work before releasing directory scopes. Cancelled
    /// verification tasks retain their own lease until they finish or the process exits.
    private func shutdown() {
        guard !shuttingDown else { return }
        // Normal-exit emit: only spans already positively confirmed. A crash or a killed process
        // recovers nothing here, and the unconfirmed tail is never fabricated.
        emitPendingProgress()
        historyProgress.detach()
        historyConfig = nil
        shuttingDown = true
        invalidateDailyRefresh()
        invalidateDailyPoster()
        performanceGeneration &+= 1
        performanceTask?.cancel()
        performanceTask = nil
        cancelPerformanceHandoff()
        clockTimer?.invalidate()
        clockTimer = nil
        retentionTimer?.invalidate()
        retentionTimer = nil
        dailySwitch.reset()
        dailyActivityTask?.cancel()
        dailyActivityTask = nil
        dailyActivityGeneration &+= 1
        pendingDailyEntry = nil
        dailyActivity.clear()
        monitors.onContextChanged = nil
        monitors.onWake = nil
        monitors.onMemoryPressureChanged = nil
        monitors.stop()
        parentExitMonitor.cancel()
        signalSources.forEach { $0.cancel() }
        signalSources.removeAll()
        engine.onPlaybackStalled = nil
        engine.onDailySourceChanged = nil
        homeFrames.onFrame = { _ in }
        homeFrames.onFirstAcceptedFrame = nil
        homeFrames.onContentReset = nil
        homeFrames.stop()
        desktopWorkspace.onAction = nil
        desktopWorkspace.teardown()
        hostController.onVisibilityChanged = nil
        watchPresentation.onBeginOwnership = nil
        watchPresentation.onVisibilityChanged = nil
        watchPresentation.onPresentationChanged = nil
        songEngine.onPlaybackStalled = nil
        songEngine.teardown()
        performanceAudio.stop()
        // Bounded: release the watch layer and hide its window without awaiting the transition.
        watchPresentation.teardown()
        engine.teardown()
        hostController.teardown()
        performance = nil
        bundle = nil
        dailyAccessRequest = nil
        appliedDailyRefreshID = nil
        performanceAccessLease = nil
        dailyVideoLease = nil
        dailyAmbientLease = nil
        dailyAccessLease = nil
        exit(0)
    }

    /// EOF on stdin = parent went away or asked us to stop → graceful exit (Mirage pattern).
    /// Reads are framed by the shared pure BSideCore.NewlineFrameReader: partial reads
    /// accumulate, multiple lines per read are split, malformed lines are skipped, and an
    /// oversized line is bounded/dropped with framing resyncing at the next newline.
    private func readStdinLoop() {
        let handle = FileHandle.standardInput
        DispatchQueue.global(qos: .utility).async {
            var framer = NewlineFrameReader()

            func handleLine(_ line: String) {
                do {
                    let envelope = try JSONDecoder().decode(IPCEnvelope<AgentCommand>.self, from: Data(line.utf8))
                    guard envelope.protocolVersion == IPC.protocolVersion else {
                        AppLog.error("agent: dropped line with protocol version \(envelope.protocolVersion)")
                        return
                    }
                    CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) { self.handle(envelope.payload) }
                    CFRunLoopWakeUp(CFRunLoopGetMain())
                } catch {
                    // Commands can contain opaque directory grants; never log their payload.
                    AppLog.error("agent: dropped invalid command JSON")
                }
            }
            func reportOversized(before: Int) {
                if framer.oversizeDropped > before {
                    AppLog.error("agent: dropped oversized command frame " +
                                 "(\(framer.oversizeDropped) frames, \(framer.bytesDropped) bytes dropped total)")
                }
            }

            while true {
                let chunk = handle.availableData
                if chunk.isEmpty {
                    // stdin EOF: drain a final unterminated frame, then graceful exit.
                    let before = framer.oversizeDropped
                    let final = framer.finish()
                    reportOversized(before: before)
                    if let final, !final.isEmpty, let line = String(data: final, encoding: .utf8) {
                        handleLine(line)
                    }
                    DispatchQueue.main.async { self.shutdown() }
                    return
                }
                let before = framer.oversizeDropped
                let frames = framer.feed(chunk)
                reportOversized(before: before)
                for frame in frames {
                    guard !frame.isEmpty, let line = String(data: frame, encoding: .utf8) else { continue }
                    handleLine(line)
                }
            }
        }
    }

    // MARK: - Command handling (main thread only)

    private func handle(_ command: AgentCommand) {
        guard !shuttingDown else { return }
        switch command {
        case .initialize(let request):
            dailyAccessRequest = request
            loadAssets()
        case .setDesiredState(let state):
            // A separate preference change supersedes an outstanding entry only when it abandons
            // THIS request's reviewed source identity; a pause/volume/profile edit that keeps the
            // requested source must not cancel it.
            let sanitizedState = state.sanitized()
            if pendingDailyEntry != nil || dailyActivity.isPending {
                let requestedSource = dailyActivity.latest?.desired.dailySourceKey
                if requestedSource == nil || sanitizedState.dailySourceKey != requestedSource {
                    cancelPendingDailyActivity("已由新的画面设置取代。")
                }
            }
            let wasPaused = desired.paused
            desired = sanitizedState
            if desired.paused != wasPaused {
                // Owner boundary: clear anchors BEFORE the policy change mutates the players.
                historyProgress.invalidateAll()
                emitPendingProgress()
            }
            reevaluate()
        case .startDailyActivity(let request):
            startDailyActivity(request)
        case .setDesktopWorkspace(let presentation):
            desktopWorkspaceState = presentation
            updateDesktopWorkspace(context: runtimeContext())
        case .setHomeCompanionStream(let request):
            historyProgress.invalidate(role: .visual)
            let accepted = homeFrames.configure(request.stream)
            logHomeContinuity(accepted ? "request" : "withdraw")
            reevaluate()
        case .acknowledgeHomeCompanionFrame(let acknowledgement):
            homeFrames.acknowledge(acknowledgement)
        case .setHistoryRecording(let request):
            applyHistoryRecording(request)
        case .startPerformance(let request):
            emitPendingProgress()
            startPerformance(request)
        case .pausePerformance(let request):
            guard performance?.id == request.sessionID else { return }
            historyProgress.invalidate(role: .music)
            emitPendingProgress()
            performance?.paused = request.paused
            reevaluate()
        case .stopPerformance(let id):
            finishPerformance(id: id, state: .stopped)
        case .enterPerformanceFullScreen(let id):
            enterPerformanceFullScreen(sessionID: id)
        case .exitPerformanceFullScreen(let id):
            guard performance?.id == id, isWatchingPerformance else { return }
            watchPresentation.exitFullScreenExplicitly()
        case .reloadAssets:
            loadAssets()
        case .refreshAssets(let request):
            refreshAssets(request)
        case .invalidateDailyAssets(let invalidation):
            invalidateDailyRefresh()
            dailyAccessRequest = nil
            applyDailyRefreshFailure(invalidation.issue, refreshID: invalidation.refreshID)
        case .healthCheck:
            emit(.health(uptimeSeconds: Date().timeIntervalSince(startedAt)))
        case .shutdown:
            shutdown()
        }
    }

    // MARK: - Explicit daily activity entry (transient; latest request wins)

    /// Fresh no-follow metadata for one chosen file (never a library scan). `nil` means metadata
    /// could not be captured, which is never treated as "unchanged".
    private static func freshSourceVersion(_ url: URL) -> AssetSourceVersion? {
        try? OfficialAssetProvider.sourceVersion(url)
    }

    /// True only while `url` still carries the same fresh media identity as `version`. A missing or
    /// unreadable file fails the match rather than passing it.
    private static func sourceVersionStillMatches(_ version: AssetSourceVersion, at url: URL) -> Bool {
        guard let current = freshSourceVersion(url) else { return false }
        return current.hasSameMedia(as: version)
    }

    /// One explicit reviewed entry. The complete desired state travels with the request so the
    /// Agent applies both in a single install pass: an ordinary source install is never triggered
    /// just before the entry. Verification streams ONLY the chosen file while holding the
    /// directory lease; a newer request/root/source/performance supersedes it before any install.
    private func startDailyActivity(_ request: DailyActivityRequest) {
        dailyActivityGeneration &+= 1
        let generation = dailyActivityGeneration
        dailyActivityTask?.cancel()
        dailyActivityTask = nil
        pendingDailyEntry = nil
        if let superseded = dailyActivity.begin(request) {
            AppLog.info("agent: daily-activity superseded \(superseded)")
        }

        let sourceKey = request.desired.dailySourceKey
        // Only a reviewed (sourceKey, activity) combination is qualified. A missing or automatic
        // source, an unreviewed outfit/time, and an activity with no authored point in this source
        // are all rejected here; no other scene/outfit/time/activity is silently substituted.
        guard let sourceKey, let qualifiedEntry = DailyActivityCatalog.entry(
            for: sourceKey, activityID: request.activityID) else {
            finishDailyActivity(request.requestID, state: .failed,
                detail: "该日常组合没有已审查的活动进入点；未自动切换当前日常版本或时段。")
            return
        }
        // Adopt the COMPLETE desired state at receipt. ControlCenter coalescing must not be able to
        // lose a just-paused click and install the entry unpaused; the entry is transient, but the
        // ordinary preferences it carries are the user's, so a later setDesiredState still wins and
        // a failed one-shot never reverts them. The pending request suppresses any plain install of
        // this source until the verified entry installs it once at its authored point.
        let adopted = request.desired.sanitized()
        let wasPaused = desired.paused
        desired = adopted
        if desired.paused != wasPaused {
            historyProgress.invalidateAll()
            emitPendingProgress()
        }
        guard initialized, let bundle else {
            finishDailyActivity(request.requestID, state: .failed, detail: "请先配置可播放的日常素材")
            reevaluate()
            return
        }
        guard let sourceID = bundle.catalog.loop(for: sourceKey), let sourceURL = bundle.url(for: sourceID) else {
            finishDailyActivity(request.requestID, state: .failed, detail: "当前素材目录缺少已审查的日常原片")
            reevaluate()
            return
        }
        // Fresh, no-follow metadata captured before the streamed hash. Cached catalog metadata
        // alone cannot see a replacement; this version is re-checked after the hash and again
        // immediately before install.
        let sourceVersion = bundle.sourceVersions[sourceID]
        guard let verifiedVersion = Self.freshSourceVersion(sourceURL) else {
            finishDailyActivity(request.requestID, state: .failed, detail: "无法读取已审查的日常原片元数据")
            reevaluate()
            return
        }
        emit(.dailyActivity(DailyActivityReport(requestID: request.requestID, state: .verifying)))
        // Apply the adopted pause/volume policy immediately while the one-shot verifies. The
        // pending request above suppresses any plain install of the reviewed source, so only
        // policy (pause, mute, visibility) can act here — never a substitute source start.
        reevaluate()
        let lease = dailyAccessLease
        dailyActivityTask = Task { @MainActor [weak self, lease] in
            defer { withExtendedLifetime(lease) {} }
            let verification = Task.detached(priority: .userInitiated) { [lease] in
                defer { withExtendedLifetime(lease) {} }
                // The identity is the reviewed whole-source digest bound to THIS key; a source
                // without a reviewed identity is rejected before any bytes are read.
                try DailyActivityIntegrity.verify(url: sourceURL, sourceKey: sourceKey)
            }
            do {
                try await withTaskCancellationHandler {
                    try await verification.value
                } onCancel: { verification.cancel() }
            } catch is CancellationError {
                return
            } catch {
                guard let self, !self.shuttingDown, self.dailyActivityGeneration == generation,
                      self.dailyActivity.isPending else { return }
                self.dailyActivityTask = nil
                self.finishDailyActivity(request.requestID, state: .failed,
                    detail: (error as? DailyActivityIntegrityError)?.description ?? "已审查的日常原片校验失败")
                // The one-shot is terminal; converge on the adopted ordinary preferences now so the
                // Agent never stays on an older source that ControlApp no longer records.
                self.reevaluate()
                return
            }
            guard let self, !self.shuttingDown, self.dailyActivityGeneration == generation,
                  self.dailyActivity.isPending,
                  self.dailyActivity.latest?.requestID == request.requestID,
                  self.bundle?.url(for: sourceID) == sourceURL,
                  self.bundle?.sourceVersions[sourceID] == sourceVersion else { return }
            // The digest was computed over bytes whose fresh media identity must still match; a
            // replacement during verification is never entered.
            guard let verifiedAtInstall = Self.freshSourceVersion(sourceURL),
                  verifiedAtInstall.hasSameMedia(as: verifiedVersion) else {
                self.dailyActivityTask = nil
                self.finishDailyActivity(request.requestID, state: .failed,
                    detail: "已审查的日常原片在校验期间发生变化，请重试。")
                self.reevaluate()
                return
            }
            // The manual daily version must still be the reviewed one; a mid-verification switch
            // is never overridden and the entry is cancelled instead.
            guard self.desired.outfit == sourceKey.outfit else {
                self.dailyActivityTask = nil
                self.finishDailyActivity(request.requestID, state: .cancelled,
                    detail: "已由新的日常版本设置取代。")
                return
            }
            // Apply the disclosed scene/time change on top of the CURRENT desired state (which may
            // have newer pause/volume/profile edits), then arm the one-shot entry in the same pass.
            var next = self.desired
            next.scene = sourceKey.scene
            next.timeMode = .fixed(sourceKey.time)
            let wasPaused = self.desired.paused
            self.desired = next.sanitized()
            if self.desired.paused != wasPaused {
                self.historyProgress.invalidateAll()
                self.emitPendingProgress()
            }
            let entry = qualifiedEntry.point
            self.pendingDailyEntry = PendingDailyEntry(
                requestID: request.requestID, sourceID: sourceID,
                offset: CMTime(value: CMTimeValue(entry.ticks), timescale: CMTimeScale(entry.timescale)),
                version: verifiedAtInstall)
            self.dailyActivityTask = nil
            self.reevaluate()
            // The install pass may synchronously terminal-fail (missing/latched source) or the
            // request may have been superseded. Only a still-pending latest request is applied, so a
            // synchronous .failed can never be overwritten by an .applied callback.
            guard self.dailyActivity.isPending,
                  self.dailyActivity.latest?.requestID == request.requestID else { return }
            // "Applied" is the request reaching playback intent (verified + armed, respecting
            // pause); it is never a claim that a picture is already playing.
            self.finishDailyActivity(request.requestID, state: .applied,
                detail: self.desired.paused ? "当前暂停；恢复后从活动进入点开始。" : nil)
        }
    }

    /// Emit a report only for the latest request and never repeat the same state (a later terminal
    /// failure may still supersede an earlier `applied`).
    private func finishDailyActivity(_ requestID: String, state: DailyActivityRequestState, detail: String?) {
        guard let latest = dailyActivity.latest, latest.requestID == requestID,
              dailyActivity.state != state else { return }
        let report = DailyActivityReport(requestID: requestID, state: state, detail: detail)
        guard dailyActivity.accept(report) else { return }
        AppLog.info("agent: daily-activity \(state.rawValue) id=\(requestID) detail=\(detail ?? "-")")
        emit(.dailyActivity(report))
    }

    /// A newer request/source/root/performance supersedes the transient entry before it installs.
    /// Only a still-outstanding request is reported cancelled.
    private func cancelPendingDailyActivity(_ detail: String) {
        guard pendingDailyEntry != nil || dailyActivity.isPending else { return }
        dailyActivityGeneration &+= 1
        dailyActivityTask?.cancel()
        dailyActivityTask = nil
        pendingDailyEntry = nil
        if let report = dailyActivity.cancel(detail: detail) {
            AppLog.info("agent: daily-activity cancelled id=\(report.requestID)")
            emit(.dailyActivity(report))
        }
    }

    // MARK: - Confirmed history recording (opt-in token owned by ControlApp)

    private func applyHistoryRecording(_ request: HistoryRecordingRequest) {
        // Buffered spans carry their own epoch/session; flush them under that ORIGINAL token
        // before any configuration change so a receiver judges them by its current epoch.
        emitPendingProgress()
        // Disable invalidates the unconfirmed tail; confirmed spans already emitted survive.
        historyProgress.detach()
        if request.enabled {
            historyConfig = request
            historyProgress.enable(epoch: request.epoch, session: request.session)
            attachProgressObservers()
        } else {
            historyConfig = nil
        }
    }

    private func attachProgressObservers() {
        let progress = historyProgress
        progress.attach(player: engine.videoObservationPlayer, role: .visual) { [weak self] in
            guard let self else { return false }
            return PlaybackProgressEligibility.visual(
                hasVideoResources: self.engine.hasVideoResources && self.dailyVisualSelected,
                systemSuppressed: self.engine.visualPaused,
                resourcesAvailable: self.dailyVisualResourcesAvailable)
        }
        // Watch-mode video may carry a real audio track and then counts music independently of
        // visual; the observer additionally requires an actual audio track on the installed item.
        progress.attach(player: engine.videoObservationPlayer, role: .music,
                        requiresAudioTrack: true) { [weak self] in
            guard let self else { return false }
            return self.performance == nil && !self.engine.visualPaused
                && PlaybackProgressEligibility.music(
                    audioTrackPresent: true, effectiveVolume: self.engine.musicOutputVolume)
        }
        progress.attach(player: songEngine.videoObservationPlayer, role: .visual) { [weak self] in
            guard let self else { return false }
            return self.songVisualSelected && self.performanceFrameReady
                && self.songEngine.hasVideoResources && !self.songEngine.visualPaused
        }
        progress.attach(player: songEngine.videoObservationPlayer, role: .music,
                        requiresAudioTrack: true) { [weak self] in
            guard let self else { return false }
            return self.isWatchingPerformance && !self.songEngine.visualPaused
                && PlaybackProgressEligibility.music(audioTrackPresent: true,
                    effectiveVolume: self.songEngine.musicOutputVolume)
        }
        progress.attach(player: engine.ambientObservationPlayer, role: .ambient) { [weak self] in
            guard let self else { return false }
            return PlaybackProgressEligibility.ambient(
                hasTrack: self.engine.hasAmbientResources,
                effectiveVolume: self.engine.ambientOutputVolume)
        }
        // The audio-only listen player owns the music bus while listening.
        progress.attach(player: performanceAudio.observationPlayer, role: .music) { [weak self] in
            guard let self else { return false }
            return self.performanceAudio.hasAudioResources
                && PlaybackProgressEligibility.music(
                    audioTrackPresent: true, effectiveVolume: self.performanceAudio.effectiveVolume)
        }
    }

    /// Emit any already-confirmed closed spans still held by the observer (never a tail).
    private func emitPendingProgress() {
        for submission in historyProgress.flush() {
            emit(.historyIntervals([submission]))
        }
    }

    /// Daily history requires the current accepted installed source. Song history uses its own
    /// backend and is never admitted by daily discovery or invalidated by daily resource loss.
    private var dailyVisualResourcesAvailable: Bool {
        dailyInstalledMedia.historyEligible(
                discoveryAccepted: dailyContentKeys != nil && dailyAssetIssue == nil)
    }

    /// Close the visual anchor the moment an affected daily read is known to be unavailable, and
    /// mark the retained installed item as needing actual replacement. A later sample would close
    /// the anchor anyway, but the owner-declared boundary is immediate and never truncates a
    /// watch-mode performance's independent visual channel.
    private var songVisualSelected: Bool {
        watchPresentation.ownsLayer && watchPresentation.visibility == true
    }

    private var dailyVisualSelected: Bool {
        (!watchPresentation.ownsLayer || watchPresentation.visibility == false)
            && ((homeFrames.hasStream && homeFrames.hasAcceptedFrame) || monitors.snapshot().desktopVisible)
    }

    private func runtimeContext() -> RuntimeContext {
        var context = monitors.snapshot()
        context.homeCompanionVisible = homeFrames.hasStream
        return context
    }

    private func logHomeContinuity(_ event: String) {
        let player = engine.videoObservationPlayer
        let item = player.currentItem.map { String(describing: ObjectIdentifier($0)) } ?? "none"
        let song = songEngine.videoObservationPlayer
        let songItem = song.currentItem.map { String(describing: ObjectIdentifier($0)) } ?? "none"
        AppLog.info("home-stream.\(event) song=\(performance?.id ?? "none") songItem=\(songItem) songPosition=\(String(format: "%.3f", song.currentTime().seconds)) clip=\(currentLoopID?.rawValue ?? "none") item=\(item) position=\(String(format: "%.3f", player.currentTime().seconds)) rate=\(player.rate)")
    }

    private func invalidateInstalledDailyMediaForLoss() {
        dailyInstalledMedia.invalidatedByResourceLoss()
        if dailyVisualSelected { historyProgress.invalidate(role: .visual) }
    }

    private func loadAssets() {
        // A root reload supersedes any entry that has not yet installed; no offset may be applied
        // to unverified new bytes.
        cancelPendingDailyActivity("日常素材已重新加载。")
        invalidateDailyRefresh()
        // Explicit invalidation removes the last usable request. A later bare reload must
        // keep its failure and EOF coordination, never revive the old grant or clear the issue.
        guard let request = dailyAccessRequest else { return }
        invalidateDailyPoster()
        appliedDailyRefreshID = request.refreshID
        hasDailyRefreshResult = false
        waitingForDailyRefresh = false
        // A failed reload can leave an older bundle available for recovery. Its discovery
        // result must not be presented as evidence for the new request.
        dailyContentKeys = nil
        missingDailyContent = nil
        dailyAssetIssue = nil
        let lease: DirectoryAccessLease?
        do {
            // Supplied grants are authoritative. A failed grant must never become a plain
            // path read; nil is retained solely for explicitly non-sandbox CLI fixtures.
            lease = try request.bookmark.map { try DirectoryAccessLease.resolveTransfer($0) }
        } catch {
            let failure = error as NSError
            reportDailyAssetFailure(.authorizationRequired)
            AppLog.error("agent: daily directory grant failed (\(failure.domain), \(failure.code))")
            return
        }
        do {
            let loaded = try OfficialAssetProvider(assetPath: lease?.url.path ?? request.path).loadCatalog()
            // reevaluate replaces ambient playback synchronously. Paused video has its own
            // lease below, so it can continue using the previous root until actual replacement.
            let previousLease = dailyAccessLease
            defer { withExtendedLifetime(previousLease) {} }
            bundle = loaded
            dailyAccessLease = lease
            dailyContentKeys = bundle?.catalog.loops.keys.sorted { $0.description < $1.description }
            clearDailyAssetError()
            ensureHost()
            initialized = true
            AppLog.info("agent: catalog loaded (\(bundle?.catalog.loops.count ?? 0) loops)")
            reevaluate(force: true)
        } catch {
            reportDailyAssetFailure(DailyAssetIssue.classify(error))
            AppLog.error("agent: asset load failed: \(error)")
        }
    }

    private func reportDailyAssetFailure(_ issue: DailyAssetIssue) {
        dailyAssetIssue = issue
        invalidateInstalledDailyMediaForLoss()
        if lastError == nil || lastError?.hasPrefix("daily assets unavailable: ") == true {
            lastError = "daily assets unavailable: \(issue.rawValue)"
        }
        // One typed snapshot owns this failure. A separate generic error could overwrite
        // the specific UI reason when an identical repeated snapshot is deduplicated.
        publishSnapshot(policyState: nil, selection: nil)
    }

    private func clearDailyAssetError() {
        dailyAssetIssue = nil
        if lastError?.hasPrefix("daily assets unavailable: ") == true { lastError = nil }
    }

    /// Cancelling a detached read does not end it synchronously. Keep its handle until the
    /// completion has returned, so a newer refresh never starts a second background traversal.
    private func invalidateDailyRefresh() {
        dailyRefreshRevision &+= 1
        queuedDailyRefresh = nil
        dailyRefreshTask?.cancel()
    }

    private func refreshAssets(_ request: DirectoryAccessRequest) {
        cancelPendingDailyActivity("日常素材正在更新。")
        dailyRefreshRevision &+= 1
        let revision = dailyRefreshRevision
        queuedDailyRefresh = nil
        dailyRefreshTask?.cancel()
        do {
            let lease = try resolveRefreshAccess(request)
            queuedDailyRefresh = DailyRefreshRequest(revision: revision, request: request, lease: lease)
            beginQueuedDailyRefresh()
        } catch {
            applyDailyRefreshFailure(.authorizationRequired, refreshID: request.refreshID)
        }
    }

    private func resolveRefreshAccess(_ request: DirectoryAccessRequest,
                                      matching previous: DirectoryAccessLease? = nil) throws -> DirectoryAccessLease? {
        // A previously granted root cannot be refreshed through an unauthorised plain path.
        // Nil remains compatible only with the existing non-sandbox CLI path.
        if (dailyAccessRequest?.bookmark != nil || dailyAccessLease != nil), request.bookmark == nil {
            throw CocoaError(.fileReadNoPermission)
        }
        let lease = try request.bookmark.map { try DirectoryAccessLease.resolveTransfer($0) }
        if let lease {
            for old in [dailyAccessLease, previous].compactMap({ $0 }) {
                if old.representsSameDirectory(as: lease) == false { throw CocoaError(.fileReadNoPermission) }
            }
        }
        return lease
    }

    private func beginQueuedDailyRefresh() {
        guard !shuttingDown, dailyRefreshTask == nil, let queued = queuedDailyRefresh else { return }
        queuedDailyRefresh = nil
        let refresh: DailyRefreshRequest
        do {
            let lease = try resolveRefreshAccess(queued.request, matching: queued.lease)
            refresh = DailyRefreshRequest(revision: queued.revision, request: queued.request, lease: lease)
        } catch {
            applyDailyRefreshFailure(.authorizationRequired, refreshID: queued.request.refreshID)
            return
        }
        let load = Task.detached(priority: .utility) { [lease = refresh.lease] in
            defer { withExtendedLifetime(lease) {} }
            try Task.checkCancellation()
            let loaded = try OfficialAssetProvider(assetPath: lease?.url.path ?? refresh.request.path)
                .loadCatalog(allowEmptyLoops: true)
            try Task.checkCancellation()
            return loaded
        }
        dailyRefreshTask = load
        Task { @MainActor [weak self, load, refresh] in
            let result = await load.result
            guard let self else { return }
            self.dailyRefreshTask = nil
            if !self.shuttingDown, self.dailyRefreshRevision == refresh.revision {
                switch result {
                case .success(let loaded):
                    do {
                        // A queued/read lease keeps access alive, but its path may have been
                        // replaced while discovery ran. Recheck before accepting its URLs.
                        let lease = try self.resolveRefreshAccess(refresh.request, matching: refresh.lease)
                        if self.sameRefreshLocation(refresh.lease, lease) {
                            self.applyDailyRefresh(loaded, refresh: DailyRefreshRequest(
                                revision: refresh.revision, request: refresh.request, lease: lease))
                        } else {
                            // The same directory moved during the read. These enumerated URLs
                            // are stale; an existing filesystem event/retry supplies the new path.
                            self.applyDailyRefreshFailure(.readFailed, refreshID: refresh.request.refreshID)
                        }
                    } catch {
                        self.applyDailyRefreshFailure(.authorizationRequired, refreshID: refresh.request.refreshID)
                    }
                case .failure(let error):
                    if !(error is CancellationError) {
                        self.applyDailyRefreshFailure(DailyAssetIssue.classify(error), refreshID: refresh.request.refreshID)
                    }
                }
            }
            self.beginQueuedDailyRefresh()
        }
    }

    private func sameRefreshLocation(_ previous: DirectoryAccessLease?, _ current: DirectoryAccessLease?) -> Bool {
        if previous == nil && current == nil { return true } // explicit legacy CLI path
        func physicalPath(_ lease: DirectoryAccessLease?) -> String? {
            guard let lease, let path = realpath(lease.url.path, nil) else { return nil }
            defer { free(path) }
            return String(cString: path)
        }
        guard let previousPath = physicalPath(previous), let currentPath = physicalPath(current) else { return false }
        return previousPath == currentPath
    }

    private func applyDailyRefresh(_ loaded: AssetBundle, refresh: DailyRefreshRequest) {
        // Unrelated loops, ambience and unknown files cannot invalidate this one-shot read.
        // Its captured lease stays alive while an unchanged poster continues across discovery.
        if attemptedPosterSource?.differs(from: loaded) == true { invalidateDailyPoster() }
        let previousLease = dailyAccessLease
        defer { withExtendedLifetime(previousLease) {} }
        bundle = loaded
        dailyAccessRequest = refresh.request
        appliedDailyRefreshID = refresh.request.refreshID
        dailyAccessLease = refresh.lease
        dailyContentKeys = loaded.catalog.loops.keys.sorted { $0.description < $1.description }
        clearDailyAssetError()
        initialized = true
        hasDailyRefreshResult = true
        // Watching defers daily media work until return. Listening keeps the ordinary daily
        // EOF coordination active while the selected audio continues independently.
        reevaluate()
    }

    private func applyDailyRefreshFailure(_ issue: DailyAssetIssue, refreshID: String?) {
        cancelPendingDailyActivity("日常素材当前不可用。")
        invalidateDailyPoster()
        appliedDailyRefreshID = refreshID
        bundle = nil
        dailyContentKeys = nil
        missingDailyContent = nil
        hasDailyRefreshResult = true
        dailyAssetIssue = issue
        if lastError == nil || lastError?.hasPrefix("daily assets unavailable: ") == true {
            lastError = "daily assets unavailable: \(issue.rawValue)"
        }
        // The previous video and its scope survive until their real boundary. Discovery is
        // unknown now; later intent must not resolve the obsolete catalog as a current result.
        invalidateInstalledDailyMediaForLoss()
        reevaluate()
    }

    private var dailySourceChanged: Bool {
        guard hasDailyRefreshResult else { return false }
        // A retained partial transition is also a future read. Ignore the remembered
        // transition once the engine has naturally advanced to its loop.
        let metadataDiffers: Bool
        if let id = currentLoopID,
           currentLoopURL != bundle?.url(for: id) || currentLoopVersion != bundle?.sourceVersions[id] {
            metadataDiffers = true
        } else if let source = currentTransitionSource, engine.dailySourceURL == source.url {
            metadataDiffers = source.differs(from: bundle)
        } else {
            metadataDiffers = false
        }
        // A known loss invalidated the installed item, so a refresh that re-reads equal
        // path/version metadata is still a pending replacement for the switch reducer.
        return dailyInstalledMedia.indicatesSourceChange(metadataDiffers: metadataDiffers)
    }

    private func invalidateDailyPoster() {
        dailyPosterGeneration &+= 1
        if dailyPosterPending { engine.cancelPendingStill() }
        dailyPosterPending = false
        attemptedPosterKey = nil
        attemptedPosterSource = nil
    }

    private func reconcileDailyAmbient(id: ContentID?, url: URL?, version: AssetSourceVersion?, volume: Double, paused: Bool) {
        let oldLease = dailyAmbientLease
        defer { withExtendedLifetime(oldLease) {} }
        if url != nil, currentAmbientURL == url, currentAmbientVersion != version {
            // URL identity alone cannot see an atomically replaced ambient file. Clear first;
            // the normal volume policy below still prevents decoding a muted channel.
            engine.setAmbientTrack(url: nil, volume: 0)
        }
        let effect = engine.setAmbientTrack(url: url, volume: volume, paused: paused)
        if effect != .none {
            let audio = engine.ambientObservationPlayer
            let video = engine.videoObservationPlayer
            let item = audio.currentItem.map { String(describing: Unmanaged.passUnretained($0).toOpaque()) } ?? "none"
            let videoItem = video.currentItem.map { String(describing: Unmanaged.passUnretained($0).toOpaque()) } ?? "none"
            AppLog.info("daily.music effect=\(effect) source=\(id?.rawValue ?? "none") item=\(item) time=\(String(format: "%.3f", audio.currentTime().seconds)) rate=\(audio.rate) gain=\(audio.volume) video-item=\(videoItem) video-time=\(String(format: "%.3f", video.currentTime().seconds)) video-rate=\(video.rate)")
        }
        currentAmbientID = id
        currentAmbientURL = url
        currentAmbientVersion = version
        dailyAmbientLease = engine.retainsAmbientSource ? dailyAccessLease : nil
    }

    // MARK: - Playback decisions flow through Core (ADR-005)

    /// Preserve a successfully installed host; screen recovery is event-driven in the controller.
    /// The desktop always renders the selected daily scene; song presentation is independent.
    private func ensureHost() {
        hostController.ensureInstalled(desktopMode: desired.desktopMode)
    }

    /// A fullscreen watch may enter only for a live, awake, unlocked, active session. A first
    /// entry deferred here is retried by the existing event-driven context reevaluation and can
    /// never repeat once the run owns its window (including after a manual exit).
    private static func watchEntryEligible(_ context: RuntimeContext) -> Bool {
        context.systemAwake && context.screenAwake && !context.screenLocked && context.sessionActive
    }

    /// IPC10 `enterPerformanceFullScreen`: the bsideyou menu-bar item's one-shot presentation
    /// request. It never starts, restarts or replays media and never changes session/queue/pause
    /// state; it only asks the owned presentation to return to native fullscreen. Stale, absent,
    /// listen-mode, unready or currently ineligible requests are ignored, and a repeat while
    /// already fullscreen or transitioning is inert in the reducer. The first entry stays
    /// readiness-driven (see `mediaBecameReady`).
    private func enterPerformanceFullScreen(sessionID: String) {
        guard let performance, performance.mode == .watch, performance.id == sessionID,
              performanceReady, performanceFrameReady, !performanceAwaitingNext,
              Self.watchEntryEligible(monitors.snapshot()) else { return }
        watchPresentation.enterFullScreenExplicitly()
    }

    private func reportPicturePresentation(_ report: PerformancePresentationReport) {
        guard performanceReady, performanceFrameReady, performance?.id == report.sessionID, isWatchingPerformance,
              report != lastPictureReport else { return }
        historyProgress.invalidate(role: .visual)
        lastPictureReport = report
        let player = songEngine.videoObservationPlayer
        let itemID = player.currentItem.map { String(describing: ObjectIdentifier($0)) } ?? "none"
        AppLog.info("performance.picture session=\(report.sessionID) state=\(report.state.rawValue) item=\(itemID) position=\(String(format: "%.3f", player.currentTime().seconds)) rate=\(player.rate)")
        emit(.performancePresentation(report))
    }

    private func updateDesktopWorkspace(context: RuntimeContext) {
        var presentation = desktopWorkspaceState
        presentation.isVisible = presentation.isVisible && context.screenAwake && context.systemAwake
            && context.sessionActive && !context.screenLocked
        desktopWorkspace.update(presentation)
    }

    private func reevaluate(force: Bool = false, atDailyUnitEnd: Bool = false) {
        guard !shuttingDown else { return }
        if force {
            pendingDailyReload = true
            invalidateDailyPoster() // explicit recovery permits one repaired-source retry
        }
        // A single instant feeds both resolution and the next deadline. Clock changes and wake
        // enter here through SystemMonitors; missed buckets are not replayed after sleep.
        let now = Date()
        let context = runtimeContext()
        updateDesktopWorkspace(context: context)
        let policyState = PlaybackPolicy.evaluate(desired: desired, context: context, performance: performance,
                                                 performanceAwaitingNext: performanceAwaitingNext)
        // Owner boundaries from the evaluated policy: system suppression / pause and effective
        // mute must close the corresponding anchor BEFORE the player mutations below.
        if (dailyVisualSelected && policyState.visual == .paused)
            || (songVisualSelected && policyState.performancePaused) {
            historyProgress.invalidate(role: .visual)
        }
        if policyState.performancePaused || policyState.musicVolume <= 0 {
            historyProgress.invalidate(role: .music)
        }
        if policyState.ambientVolume <= 0 { historyProgress.invalidate(role: .ambient) }
        scheduleNextTimeBoundary(after: now, active: initialized && policyState.visual != .paused)
        if let performance, performance.mode == .listen {
            performanceAudio.setPaused(policyState.performancePaused)
            performanceAudio.setVolume(policyState.musicVolume)
            if performanceReady && !performanceAwaitingNext {
                reportPerformance(PerformanceReport(sessionID: performance.id,
                    state: policyState.performancePaused ? .paused : .playing,
                    detail: policyState.reasons.isEmpty ? nil : policyState.reasons.joined(separator: ", ")))
            }
        }
        if let performance, performance.mode == .watch {
            songEngine.setVisualPaused(policyState.performancePaused)
            songEngine.setMusicVolume(policyState.musicVolume)
            watchPresentation.reconcileEligibility(
                sessionID: performance.id, layer: songEngine.videoLayer,
                eligible: performanceFrameReady && Self.watchEntryEligible(context))
            if performanceReady && !performanceAwaitingNext {
                reportPerformance(PerformanceReport(sessionID: performance.id,
                    state: policyState.performancePaused ? .paused : .playing,
                    detail: policyState.reasons.isEmpty ? nil : policyState.reasons.joined(separator: ", ")))
            }
        }
        guard initialized else {
            publishSnapshot(policyState: policyState, selection: nil)
            return
        }
        let catalog = bundle?.catalog ?? ContentCatalog()
        ensureHost()

        let minute = BeijingClock.minuteOfDay(at: now)
        let selection = ContentResolver.resolve(
            currentKey: currentKey, desired: desired, catalog: catalog,
            minuteOfDay: minute)
        // Re-resolve this resource error on every intent, even if the valid target is already
        // installed. Keep media/load failures in lastError until their own recovery succeeds.
        missingDailyContent = dailyContentKeys != nil && !selection.isPlayable ? selection.targetKey : nil

        // Paused targets remain pure metadata. Do not create a new decoder just to pause it;
        // resume resolves the newest Beijing target once, without replaying missed transitions.
        let paused = policyState.visual == .paused
        engine.setVisualPaused(paused)
        homeFrames.setEnabled(!paused && homeFrames.hasStream)
        if !paused { invalidateDailyPoster() }
        if paused && (!context.systemAwake || !context.screenAwake || context.screenLocked || !context.sessionActive ||
                      (!context.desktopVisible && !context.homeCompanionVisible && !engine.hasVideoResources)) {
            // A covered cold start needs no poster yet. Existing paused video may still take
            // one retained frame at its deadline so an unexpected reveal has a ready image.
            engine.cancelPendingStill()
            invalidateDailyPoster()
        }
        let sourceChanged = dailySourceChanged
        let previousPending = dailySwitch.pendingTarget
        waitingForDailyRefresh = false
        // An armed one-shot entry forces the install pass even when the target key is already
        // installed (a same-activity re-click must start the entry again) without pretending to
        // be an ordinary reload.
        let entryForSelection = pendingDailyEntry.flatMap { $0.sourceID == selection.loop ? $0 : nil }
        var switchEffect = dailySwitch.update(current: currentKey, selection: selection,
            automatic: desired.timeMode == .auto, paused: paused,
            hasVideo: engine.hasVideoResources || engine.hasPendingDailyLoopLoad,
            reload: pendingDailyReload || entryForSelection != nil,
            sourceChanged: sourceChanged, atUnitEnd: atDailyUnitEnd)
        // While an entry is still being verified, the requested source is never installed as an
        // ordinary whole-source start; the verified entry installs it once, at its authored point.
        // The comparison uses THIS request's own source key, not a fixed library combination.
        if dailyActivity.isPending, pendingDailyEntry == nil, selection.isPlayable,
           let requestedSource = dailyActivity.latest?.desired.dailySourceKey,
           desired.dailySourceKey == requestedSource {
            switchEffect = .none
        }
        if switchEffect == .waitForEnd {
            if engine.finishCurrentDailyUnit({ [weak self] in
                // The clock or user intent may have changed again. Never install a captured plan.
                guard let self else { return }
                if self.dailyInstalledMedia.needsReplacement {
                    // A remounted source can keep the same URL. Recreating it inside the old
                    // item's EOF notification reproduced AVFoundation Cannot Open (-11829).
                    // Let that notification unwind after clearing the invalidated item, then
                    // resolve current intent. A fresh install or shutdown cancels this work.
                    self.engine.stopVideo()
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.dailyInstalledMedia.needsReplacement,
                              !self.shuttingDown else { return }
                        self.reevaluate(atDailyUnitEnd: true)
                    }
                } else {
                    self.reevaluate(atDailyUnitEnd: true)
                }
            }) {
                waitingForDailyRefresh = sourceChanged
                if previousPending != dailySwitch.pendingTarget {
                    AppLog.info("agent: daily-video pending \(selection.targetKey) until-unit-end")
                }
            } else {
                switchEffect = dailySwitch.update(current: currentKey, selection: selection,
                    automatic: desired.timeMode == .auto, paused: paused,
                    hasVideo: engine.hasVideoResources || engine.hasPendingDailyLoopLoad,
                    reload: pendingDailyReload, sourceChanged: sourceChanged, atUnitEnd: true)
            }
        } else {
            engine.cancelPendingDailyBoundary()
        }
        if atDailyUnitEnd, sourceChanged, !selection.isPlayable {
            // The drained engine otherwise restores its old loop after this callback. A
            // confirmed refresh removed that source; stop synchronously at this boundary.
            // Ordinary explicit missing selections keep their previous behavior.
            invalidateDailyPoster()
            engine.stopVideo()
            dailyVideoLease = nil
            currentKey = nil
            currentLoopID = nil
            currentLoopURL = nil
            currentLoopVersion = nil
            currentTransitionSource = nil
            waitingForDailyRefresh = false
            dailySwitch.reset()
            applyRetentionEffects(dailyResources.invalidate())
        }
        if switchEffect == .install {
            // The retained entry may have waited while paused. Re-stat the chosen file at the
            // immediate install point: bytes replaced after verification must never be entered with
            // an offset measured against the verified ones. Fresh single-file stat; no library scan.
            if let entry = pendingDailyEntry, let entryURL = bundle?.url(for: entry.sourceID),
               !Self.sourceVersionStillMatches(entry.version, at: entryURL) {
                pendingDailyEntry = nil
                finishDailyActivity(entry.requestID, state: .failed,
                    detail: "已审查的日常原片在进入前发生变化，请重新选择活动。")
            }
            if let loopID = selection.loop, let loopURL = bundle?.url(for: loopID),
               !isFailedDailySourceUnchanged(loopID: loopID, url: loopURL) {
                // This attempt was permitted (changed source/version or explicit reload/restart).
                // A repeated failure re-latches through handleDailyLoadFailure.
                failedDailySource = nil
                let hadVideo = engine.hasVideoResources
                let entry = pendingDailyEntry.flatMap { $0.sourceID == loopID ? $0 : nil }
                // A one-shot entry starts directly at its authored point: no transition clip is
                // substituted for the reviewed entry. A drained looper may already have removed
                // its last replica; the confirmed end still has a previous daily unit.
                let transitionURL = entry == nil && (hadVideo || atDailyUnitEnd)
                    ? selection.transition.flatMap { bundle?.url(for: $0) } : nil
                if pendingDailyReload || sourceChanged { engine.stopVideo() }
                engine.play(transitionURL: transitionURL, loopURL: loopURL, entryOffset: entry?.offset)
                if entry != nil {
                    // Consumed exactly here: normal EOF/pause/resume can never reapply it.
                    pendingDailyEntry = nil
                    AppLog.info("agent: daily-activity entry installed \(loopID.rawValue)")
                }
                if let transitionID = selection.transition, let transitionURL,
                   engine.dailySourceURL == transitionURL {
                    currentTransitionSource = DailySourceReference(id: transitionID, url: transitionURL,
                        version: bundle?.sourceVersions[transitionID])
                } else if currentTransitionSource?.url != engine.dailySourceURL {
                    // An unchanged suspended transition may have resumed instead of a new
                    // selection. Keep only that actual source, never the whole transition set.
                    currentTransitionSource = nil
                }
                dailyVideoLease = dailyAccessLease
                applyRetentionEffects(dailyResources.resourceReplaced())
                pendingDailyReload = false
                currentKey = selection.targetKey
                currentLoopID = loopID
                currentLoopURL = loopURL
                currentLoopVersion = bundle?.sourceVersions[loopID]
                // An actual fresh item now carries the current accepted source; only this clears
                // a known-loss invalidation (a same-metadata refresh above did not).
                dailyInstalledMedia.replacedByFreshInstall()
                lastError = nil
                AppLog.info("agent: daily-video installed \(loopID.rawValue)")
                emit(transitionURL != nil
                     ? .playbackStarted(clipID: loopID.rawValue)
                     : .contentChanged(clipID: loopID.rawValue))
            } else if let entry = pendingDailyEntry {
                // The reviewed source is missing or latched as unreadable: report the real
                // failure instead of leaving the explicit request pending forever.
                pendingDailyEntry = nil
                finishDailyActivity(entry.requestID, state: .failed,
                    detail: lastError ?? "所选日常原片当前不可用")
            }
        }

        // Supply a single still on a visible paused cold start or return from a performance.
        // An already-retained image stays put while paused targets change; resume resolves now.
        if paused && !engine.hasVideoResources && !engine.hasRetainedFrame &&
            context.screenAwake && context.systemAwake && !context.screenLocked && context.sessionActive && (context.desktopVisible || context.homeCompanionVisible) &&
            attemptedPosterKey != selection.targetKey,
            let loopID = selection.loop, let url = bundle?.url(for: loopID) {
            // No live item/frame is being replaced here. A changed same-URL source must not
            // inherit the released old source's restoration position after this new poster.
            if pendingDailyReload || sourceChanged {
                engine.stopVideo()
                dailyVideoLease = nil
                currentKey = nil
                currentLoopID = nil
                currentLoopURL = nil
                currentLoopVersion = nil
                currentTransitionSource = nil
                applyRetentionEffects(dailyResources.invalidate())
            }
            invalidateDailyPoster()
            attemptedPosterKey = selection.targetKey
            dailyPosterPending = true
            let posterGeneration = dailyPosterGeneration
            let version = bundle?.sourceVersions[loopID]
            attemptedPosterSource = DailySourceReference(id: loopID, url: url, version: version)
            dailyVideoLease = dailyAccessLease
            engine.showDailyStill(loopURL: url) { [weak self, lease = dailyAccessLease] installed in
                defer { withExtendedLifetime(lease) {} }
                guard let self, !self.shuttingDown, self.dailyPosterGeneration == posterGeneration else { return }
                self.dailyPosterPending = false
                if installed {
                    self.currentKey = selection.targetKey
                    self.currentLoopID = loopID
                    self.currentLoopURL = url
                    self.currentLoopVersion = version
                    AppLog.info("agent: daily-still installed \(loopID.rawValue)")
                    self.reevaluate()
                } else {
                    AppLog.error("agent: daily-still unavailable; retry on next playback intent")
                }
            }
        }

        // Ambient source changes use the same policy; unchanged sources remain a no-op.
        let ambientID = selection.ambient
        let ambientURL = ambientID.flatMap { bundle?.url(for: $0) }
        reconcileDailyAmbient(id: ambientID, url: ambientURL,
            version: ambientID.flatMap { bundle?.sourceVersions[$0] }, volume: policyState.ambientVolume,
            paused: policyState.ambientPaused)

        // Any active song owns the music bus; daily media never duplicates song audio.
        engine.setMusicVolume(performance != nil ? 0 : policyState.musicVolume)
        if paused && engine.hasVideoResources && (!context.systemAwake || !context.screenAwake || context.screenLocked || !context.sessionActive) {
            // Invisibility can release without image extraction, even after a previous visible
            // capture failed or is still pending. Stronger conditions must not retain that queue.
            applyRetentionEffects(dailyResources.invalidate())
        }
        applyRetentionEffects(dailyResources.update(paused: paused, hasVideo: engine.hasVideoResources,
            retentionDelay: PlaybackPolicy.dailyRetentionDelay(context: context, memoryPressure: memoryPressure),
            now: ProcessInfo.processInfo.systemUptime))
        publishSnapshot(policyState: policyState, selection: selection)
    }

    private func applyRetentionEffects(_ effects: [DailyResourceLifecycle.Effect]) {
        for effect in effects {
            switch effect {
            case .cancel:
                retentionTimer?.invalidate()
                retentionTimer = nil
            case .schedule(let token, let delay):
                retentionTimer?.invalidate()
                let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
                    guard let self, !self.shuttingDown, self.dailyResources.releaseDeadlineFired(token: token) else { return }
                    self.retentionTimer = nil
                    let context = self.runtimeContext()
                    let policy = PlaybackPolicy.evaluate(desired: self.desired, context: context,
                        performance: self.performance, performanceAwaitingNext: self.performanceAwaitingNext)
                    guard policy.visual == .paused else { return }
                    let invisible = !context.systemAwake || !context.screenAwake || context.screenLocked || !context.sessionActive
                    self.engine.releasePausedDaily(preservingFrame: !invisible) { [lease = self.dailyVideoLease] released in
                        defer { withExtendedLifetime(lease) {} }
                        AppLog.info("agent: daily-video release=\(released) still=\(self.engine.hasRetainedFrame)")
                    }
                }
                timer.tolerance = min(1, delay * 0.1)
                retentionTimer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
        }
    }

    private func startPerformance(_ request: PerformanceStartRequest) {
        guard initialized, !request.session.id.isEmpty else {
            emit(.performance(PerformanceReport(sessionID: request.session.id, state: .failed,
                detail: "请先配置可播放的日常素材")))
            return
        }
        // ADR-022 typed-target admission. A local target REQUIRES the per-file binding; an
        // official target must reject an extraneous binding instead of ignoring it. The shared
        // Core rule keeps this identical to the ControlApp request pipeline.
        if let issue = request.admissionIssue {
            emit(.performance(PerformanceReport(sessionID: request.session.id, state: .failed,
                detail: issue.description)))
            return
        }
        if performance?.id == request.session.id { return } // duplicate start is idempotent
        cancelPerformanceHandoff()
        // Audio-only successors close an opened song window. Video successors may retain an
        // explicitly opened window; neither path replaces the daily scene.
        if request.session.mode != .watch {
            watchPresentation.endRun(sessionID: performance?.id)
        }
        performanceGeneration &+= 1
        let generation = performanceGeneration
        AppLog.info("performance.prepare session=\(request.session.id) generation=\(generation) mode=\(request.session.mode.rawValue) local=\(request.session.target.isLocalFile) global-paused=\(desired.paused) session-paused=\(request.session.paused)")
        performanceTask?.cancel()
        performanceTask = nil
        historyProgress.invalidate(role: .music)
        if songVisualSelected { historyProgress.invalidate(role: .visual) }
        if request.session.mode == .watch { songEngine.retainDisplayedFrameForReplacement() }
        songEngine.stopVideo()
        if request.session.mode != .watch { songEngine.discardDisplayedFrameHold() }
        performanceAudio.stop()
        performance = request.session
        performanceReady = false
        performanceFrameReady = false
        lastPerformanceReport = nil
        lastPictureReport = nil
        performanceAccessLease = nil
        // ADR-023: a watch→watch replacement is accepted here, before its media is ready. Transfer
        // the presentation run identity now so a stop/failure for this session (or its
        // 20 s handoff timeout) ends the run the Agent actually accepted. No re-entry: an owned
        // window keeps its fullscreen transition untouched.
        if request.session.mode == .watch {
            watchPresentation.adoptSession(request.session.id)
        }
        reevaluate()
        reportPerformance(PerformanceReport(sessionID: request.session.id, state: .loading))
        let lease: DirectoryAccessLease?
        do {
            lease = try request.accessBookmark.map { try DirectoryAccessLease.resolveTransfer($0) }
        } catch {
            let failure = error as NSError
            AppLog.error("agent: performance directory grant failed (\(failure.domain), \(failure.code))")
            finishPerformance(id: request.session.id, state: .failed,
                              detail: "演奏目录授权已失效，请重新选择目录")
            return
        }
        performanceAccessLease = lease
        // A local request is admitted only with its transferred grant; it must never fall back
        // to the ControlApp-supplied path (which the shared admission rule already refuses).
        let root: URL
        if request.session.target.isLocalFile {
            guard let lease else {
                finishPerformance(id: request.session.id, state: .failed,
                                  detail: "歌曲缺少目录访问授权")
                return
            }
            root = lease.url
        } else {
            root = lease?.url ?? URL(fileURLWithPath: request.mediaRoot)
        }
        performanceTask = Task { @MainActor [weak self, lease] in
            // Cancellation only requests termination. Both the detached hash verification
            // and the later asynchronous media probe must retain scope until they return.
            defer { withExtendedLifetime(lease) {} }
            let verification = Task.detached(priority: .userInitiated) { [lease] in
                defer { withExtendedLifetime(lease) {} }
                switch request.session.target {
                case .catalog(let variant):
                    let library = try PerformanceLibrary.bundled()
                    return try library.verifiedURL(for: variant, root: root)
                case .localFile:
                    // Verify EXACTLY the one selected file under this lease: relative-path
                    // containment plus size+SHA-256 identity. Never hash siblings.
                    guard let binding = request.fileBinding else {
                        throw LocalSongError.invalidBinding("missing file binding")
                    }
                    return try LocalFileVerifier.resolveAndVerify(binding: binding, root: root)
                }
            }
            do {
                let url = try await withTaskCancellationHandler {
                    try await verification.value
                } onCancel: { verification.cancel() }
                try Task.checkCancellation()
                let audioOnlyLocal: Bool
                if request.session.target.isLocalFile, request.session.mode == .watch {
                    audioOnlyLocal = try await !PerformanceMediaProbe.hasVideo(url)
                } else {
                    audioOnlyLocal = false
                }
                let playbackMode: PerformancePlaybackMode = audioOnlyLocal ? .listen : request.session.mode
                let audioAsset = playbackMode == .listen
                    ? try await PerformanceAudioPlayer.prepare(url: url) : nil
                if playbackMode == .watch { try await PerformanceMediaProbe.validate(url) }
                try Task.checkCancellation()
                guard let self, !self.shuttingDown, self.performanceGeneration == generation,
                      self.performance?.id == request.session.id else { return }
                if audioOnlyLocal, let current = self.performance {
                    self.performance = PerformanceSession(id: current.id, target: current.target, mode: .listen,
                        paused: current.paused, continuesQueue: current.continuesQueue)
                    self.watchPresentation.endRun(sessionID: current.id)
                    self.songEngine.discardDisplayedFrameHold()
                    self.reevaluate()
                }
                AppLog.info("performance.validated session=\(request.session.id) generation=\(generation) mode=\(playbackMode.rawValue) audio-only-local=\(audioOnlyLocal)")
                self.reevaluate() // newest user/system intent, never captured pre-load intent
                let ready: () -> Void = { [weak self] in
                    guard let self, !self.shuttingDown, self.performanceGeneration == generation,
                          self.performance?.id == request.session.id, !self.performanceAwaitingNext else { return }
                    AppLog.info("performance.item-ready session=\(request.session.id) generation=\(generation) mode=\(playbackMode.rawValue)")
                    self.performanceReady = true
                    self.reevaluate()
                    if let report = self.watchPresentation.presentationReport {
                        self.reportPicturePresentation(report)
                    }
                }
                let completion: (String?) -> Void = { [weak self] error in
                    guard let self, !self.shuttingDown, self.performanceGeneration == generation else { return }
                    if let error {
                        self.finishPerformance(id: request.session.id, state: .failed, detail: error)
                    } else {
                        self.performanceReachedEnd(id: request.session.id, generation: generation)
                    }
                }
                if let audioAsset {
                    self.performanceAudio.play(asset: audioAsset, onReady: ready, completion: completion)
                    AppLog.info("agent: performance-audio installed session=\(request.session.id)")
                } else {
                    self.songEngine.playOnce(url: url, diagnosticSessionID: request.session.id,
                        onReady: ready, onSourceFrameReady: { [weak self] in
                            guard let self, !self.shuttingDown, self.performanceGeneration == generation,
                                  self.performance?.id == request.session.id, !self.performanceAwaitingNext else { return }
                            self.performanceFrameReady = true
                            self.watchPresentation.mediaBecameReady(
                                sessionID: request.session.id, layer: self.songEngine.videoLayer,
                                eligible: Self.watchEntryEligible(self.monitors.snapshot()),
                                automaticallyEnterFullScreen: false)
                            self.reevaluate()
                            if let report = self.watchPresentation.presentationReport {
                                self.reportPicturePresentation(report)
                            }
                        }, completion: completion)
                }
            } catch is CancellationError {
                // A stop/replacement owns restoration; obsolete work cannot emit or install.
                AppLog.info("performance.prepare-cancelled session=\(request.session.id) generation=\(generation)")
            } catch {
                guard !Task.isCancelled, let self, !self.shuttingDown,
                      self.performanceGeneration == generation else { return }
                self.finishPerformance(id: request.session.id, state: .failed, detail: String(describing: error))
            }
        }
    }

    private func performanceReachedEnd(id: String, generation: UInt64) {
        guard !shuttingDown, performanceGeneration == generation,
              let session = performance, session.id == id, !performanceAwaitingNext else { return }
        guard session.continuesQueue else {
            finishPerformance(id: id, state: .ended)
            return
        }
        // Keep this session suppressing ambient audio while ControlApp owns the next-song
        // choice. Watch retains its completed item/frame and lease; listen releases only its
        // finished audio item, leaving ordinary daily playback untouched.
        performanceAwaitingNext = true
        performanceReady = false
        performanceFrameReady = false
        performanceTask = nil
        performanceAudio.stop()
        let deadline = DispatchWorkItem { [weak self] in
            guard let self, !self.shuttingDown, self.performanceGeneration == generation,
                  self.performance?.id == id, self.performanceAwaitingNext else { return }
            self.finishPerformance(id: id, state: .failed,
                detail: "播放队列交接超时，请重新点播")
        }
        performanceHandoffDeadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: deadline)
        reevaluate()
        reportPerformance(PerformanceReport(sessionID: id, state: .ended))
    }

    private func cancelPerformanceHandoff() {
        performanceHandoffDeadline?.cancel()
        performanceHandoffDeadline = nil
        performanceAwaitingNext = false
    }

    private func finishPerformance(id: String, state: PerformanceReport.State, detail: String? = nil) {
        guard !shuttingDown, performance?.id == id else { return }
        AppLog.info("performance.finish session=\(id) generation=\(performanceGeneration) state=\(state.rawValue)")
        emitPendingProgress()   // session boundary: confirmed spans only
        cancelPerformanceHandoff()
        performanceGeneration &+= 1
        performanceTask?.cancel()
        performanceTask = nil
        performance = nil
        performanceReady = false
        performanceFrameReady = false
        performanceAudio.stop()
        lastPictureReport = nil
        historyProgress.invalidate(role: .music)
        if songVisualSelected { historyProgress.invalidate(role: .visual) }
        watchPresentation.endRun(sessionID: id)
        songEngine.stopVideo()
        songEngine.discardDisplayedFrameHold()
        performanceAccessLease = nil
        emit(.performance(PerformanceReport(sessionID: id, state: state, detail: detail)))
        lastPerformanceReport = nil
        reevaluate() // Daily media keeps its own item, clock and selected scene.
    }

    private func reportPerformance(_ report: PerformanceReport) {
        guard report != lastPerformanceReport else { return }
        lastPerformanceReport = report
        AppLog.info("performance.state session=\(report.sessionID) state=\(report.state.rawValue)")
        emit(.performance(report))
    }

    private func scheduleNextTimeBoundary(after now: Date, active: Bool) {
        let next = active && desired.timeMode == .auto ? BeijingClock.nextBoundary(after: now) : nil
        if let next, let clockTimer, clockTimer.isValid, clockTimer.fireDate == next { return }
        clockTimer?.invalidate()
        clockTimer = nil
        guard let next else { return }
        let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            self?.clockTimer = nil
            self?.reevaluate()
        }
        timer.tolerance = 1
        clockTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func rebuildAfterStall() {
        guard currentLoopURL != nil, engine.hasVideoResources else { return }
        AppLog.error("agent: playback stalled — reconciling latest daily target")
        // A direct engine rebuild would revoke its boundary callback but leave the Core wait
        // behind. Recovery must reconcile both owners and use the latest target immediately.
        reevaluate(force: true)
    }

    /// A real daily loop load failure (unreadable container): the engine has already released the
    /// failed decoder and no current item/watchdog exists on this route. Latch the actual source,
    /// drop its visual history anchor, and report an actionable degraded error through the
    /// existing snapshot/IPC path. No automatic retry of a deterministically unreadable source.
    private func handleDailyLoadFailure(_ error: Error?) {
        guard !shuttingDown else { return }
        // An installed loop/transition is the usual failed identity. A paused cold start has no
        // installed item yet, so its attempted poster is the source whose read/decode actually
        // failed; the same latch and error report must still apply, or a genuinely unavailable
        // target would keep its silent black desktop and its optimistic ready state.
        let failedSource: DailySourceReference
        if let loopID = currentLoopID, let loopURL = currentLoopURL {
            failedSource = DailySourceReference(id: loopID, url: loopURL, version: currentLoopVersion)
        } else if let poster = attemptedPosterSource {
            failedSource = poster
        } else {
            return
        }
        failedDailySource = failedSource
        if dailyVisualSelected { historyProgress.invalidate(role: .visual) }
        let detail = error.map { " (\($0.localizedDescription))" } ?? ""
        lastError = "无法读取当前日常视频。可在设置中切换其他组合；如已修复素材，可重启壁纸服务后重试。"
        AppLog.error("agent: daily-video load failed \(failedSource.id.rawValue):\(detail)")
        // An entry whose installed source is actually unreadable must report failure, without
        // disabling any unrelated control.
        if let latest = dailyActivity.latest, dailyActivity.state == .applied || dailyActivity.isPending {
            finishDailyActivity(latest.requestID, state: .failed, detail: lastError)
        }
        // Reconcile through the normal pipeline: the latch makes the same selection a no-op, so
        // this cannot silently reinstall it, and the snapshot carries the degraded lastError.
        reevaluate()
    }

    /// True while the selected daily source is still exactly the one whose actual install failed
    /// and nothing explicit permits a new load. Explicit reload (`reevaluate(force: true)`), a
    /// changed on-disk source/version, or a known-loss replacement each permit a fresh attempt.
    private func isFailedDailySourceUnchanged(loopID: ContentID, url: URL) -> Bool {
        guard let failed = failedDailySource, !pendingDailyReload, !dailySourceChanged,
              !dailyInstalledMedia.needsReplacement else { return false }
        return failed.id == loopID && failed.url == url
    }

    // MARK: - Snapshot reporting

    private func publishSnapshot(policyState: EffectivePlaybackState?, selection: ContentSelection?) {
        var state: AgentState = .starting
        if dailyAssetIssue != nil {
            state = .degraded
        } else if initialized {
            if lastError != nil || missingDailyContent != nil {
                state = .degraded
            } else if let policyState, policyState.visual == .paused {
                state = .paused
            } else if policyState != nil {
                state = .playing
            }
        }
        var summary: String?
        if dailyContentKeys != nil, let catalog = bundle?.catalog {
            summary = "loops:\(catalog.loops.count) transitions:\(catalog.transitions.count) ambient:\(catalog.ambientTracks.count) unknown:\(catalog.unknownFiles.count)"
        }
        let snapshot = RuntimeSnapshot(
            state: state,
            currentClip: currentKey.map { "\($0)" },
            transitionClip: currentTransitionSource?.url == engine.dailySourceURL
                ? currentTransitionSource?.id.rawValue : nil,
            musicVolume: policyState?.musicVolume ?? 0,
            ambientVolume: policyState?.ambientVolume ?? 0,
            visual: policyState?.visual ?? .full,
            reasons: policyState?.reasons ?? [],
            catalogSummary: summary,
            lastError: lastError ?? missingDailyContent.map { "no loop clip for \($0)" },
            pendingDailyTime: dailySwitch.pendingTarget?.time != currentKey?.time
                ? dailySwitch.pendingTarget?.time : nil,
            dailyContentKeys: dailyContentKeys,
            // Same latest confirmed directory read as dailyContentKeys: unknown while that read
            // is absent or failed, otherwise the discovered ambient file count (never playback proof).
            dailyAmbientTrackCount: dailyContentKeys == nil ? nil : bundle?.catalog.ambientTracks.count,
            dailyAmbientTracks: dailyContentKeys == nil ? nil : bundle?.catalog.ambientTracks,
            currentDailyAmbientTrackID: engine.retainsAmbientSource ? currentAmbientID : nil,
            missingDailyContent: missingDailyContent,
            dailyAssetIssue: dailyAssetIssue,
            pendingDailyRefresh: waitingForDailyRefresh ? true : nil,
            dailyRefreshID: appliedDailyRefreshID
        )
        guard snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot
        emit(.runtimeSnapshot(snapshot))
    }

    // MARK: - Output (serialized; single-line JSON only)

    private func emit(_ event: AgentEvent) {
        guard !shuttingDown else { return }
        guard let line = IPCCoding.encodeLine(IPCEnvelope(payload: event)) else {
            AppLog.error("agent: failed to encode event — dropped")
            return
        }
        outputLock.lock()
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
        outputLock.unlock()
    }
}

// MARK: - Process entry

// The disposable Agent never owns the shared control.log. Its diagnostics already leave through
// its own stderr, which the supervising ControlApp drains into supervisor-owned agent.log. A
// second writer on control.log cannot be serialized by RotatingFileLog's process-local lock and
// can overwrite a concurrent ControlApp record at a stale end offset. Relinquish the file sink
// before any AppLog use; stderr logging stays fully intact.
AppLog.setControlLogOwnership(false)

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let runtime = AgentRuntime()
runtime.start()
application.run()
