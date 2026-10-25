import AVFoundation
import Foundation

/// An explicitly selected performance's audio-only path. The caller owns complete media
/// identity verification and retains its directory lease through prepare, playback and stop.
/// Control methods run on the main thread; no layer or original audiovisual item is created.
public final class PerformanceAudioPlayer {
    private let player = AVPlayer()
    private var generation: UInt64 = 0
    private var paused = false
    private var readyReported = false
    private var readyCallback: (() -> Void)?
    private var completionCallback: ((String?) -> Void)?
    private var statusObserver: NSKeyValueObservation?
    private var playerStateObserver: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var loadDeadline: DispatchWorkItem?
    private var watchdogTimer: Timer?
    private weak var watchdogItem: AVPlayerItem?
    private var watchdogWaiting = false
    private var watchdogTime = 0.0

    public var hasAudioResources: Bool { player.currentItem != nil }
    public var currentTime: CMTime { player.currentTime() }
    /// Observation-only handle for the confirmed-history media-clock observer. Control still
    /// enters exclusively through play/setPaused/setVolume/stop.
    public var observationPlayer: AVPlayer { player }
    public var effectiveVolume: Double { Double(player.volume) }
    /// Observation only, for diagnostics and real AVFoundation regression tests. Playback
    /// intent enters through setPaused/setVolume/play/stop, never through this item's objects.
    public var currentItem: AVPlayerItem? { player.currentItem }

    public init() {
        player.actionAtItemEnd = .pause
        player.automaticallyWaitsToMinimizeStalling = false
        playerStateObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.reconcileWatchdog() }
        }
    }

    /// Materialize one complete audio track without decoding video, exporting, copying media
    /// bytes or guessing which of several tracks should be mixed. Nonzero source start is
    /// retained on the composition timeline, including its leading empty interval.
    public static func prepare(url: URL) async throws -> AVComposition {
        try Task.checkCancellation()
        let source = AVURLAsset(url: url)
        let tracks = try await source.loadTracks(withMediaType: .audio)
        try Task.checkCancellation()
        guard !tracks.isEmpty else {
            throw PerformanceAssetError.unreadable("所选演奏没有音轨，无法只听音乐")
        }
        guard tracks.count == 1 else {
            throw PerformanceAssetError.unreadable("所选演奏包含多条音轨，尚无明确的音轨选择规则")
        }
        let track = tracks[0]
        let range = try await track.load(.timeRange)
        try Task.checkCancellation()
        guard range.isValid, range.start.isNumeric, range.duration.isNumeric,
              range.start.seconds.isFinite, range.start.seconds >= 0,
              range.duration.seconds.isFinite, range.duration.seconds > 0,
              CMTimeRangeGetEnd(range).seconds.isFinite else {
            throw PerformanceAssetError.unreadable("所选音轨的完整时间范围无法保留")
        }
        let mutable = AVMutableComposition()
        guard let audio = mutable.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw PerformanceAssetError.unreadable("无法创建独立音轨")
        }
        try audio.insertTimeRange(range, of: track, at: range.start)
        try Task.checkCancellation()
        // This copies only the composition's track references/timing, never the source file.
        guard let composition = mutable.copy() as? AVComposition else {
            throw PerformanceAssetError.unreadable("无法完成音轨准备")
        }
        let playable = try await composition.load(.isPlayable)
        let duration = try await composition.load(.duration)
        try Task.checkCancellation()
        guard playable, duration.isNumeric, duration.seconds.isFinite, duration.seconds > 0 else {
            throw PerformanceAssetError.unreadable("所选音轨无法独立播放")
        }
        return composition
    }

    public func play(asset: AVComposition, onReady: @escaping () -> Void,
                     completion: @escaping (String?) -> Void) {
        precondition(Thread.isMainThread, "PerformanceAudioPlayer control requires the main thread")
        stop()
        let token = generation
        readyCallback = onReady
        completionCallback = completion
        // Freeze the in-memory composition so a mutable caller cannot later add a video
        // track to the installed item. AVComposition tracks are already materialized metadata.
        guard let prepared = asset.copy() as? AVComposition,
              prepared.tracks.count == 1, prepared.tracks[0].mediaType == .audio else {
            DispatchQueue.main.async { [weak self] in
                self?.finish(item: nil, generation: token, detail: "只听音乐需要且仅支持一条独立音轨")
            }
            return
        }
        let item = AVPlayerItem(asset: prepared)
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self, weak item] _ in
            guard let item else { return }
            self?.finish(item: item, generation: token, detail: nil)
        }
        failureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self, weak item] notification in
            guard let item else { return }
            let detail = (notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?
                .localizedDescription ?? "音轨播放中断，请重新点播"
            self?.finish(item: item, generation: token, detail: detail)
        }
        statusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self, weak item] _, _ in
            DispatchQueue.main.async {
                guard let self, let item, self.matches(item: item, generation: token) else { return }
                if item.status == .failed {
                    self.finish(item: item, generation: token, detail: item.error?.localizedDescription ?? "音轨加载失败")
                } else if item.status == .readyToPlay && !self.readyReported {
                    self.readyReported = true
                    self.loadDeadline?.cancel()
                    self.loadDeadline = nil
                    let callback = self.readyCallback
                    self.readyCallback = nil
                    callback?()
                    if self.matches(item: item, generation: token) { self.reconcileWatchdog() }
                }
            }
        }
        let deadline = DispatchWorkItem { [weak self, weak item] in
            guard let item else { return }
            self?.finish(item: item, generation: token, detail: "音轨加载超时，请检查素材磁盘")
        }
        loadDeadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: deadline)
        player.replaceCurrentItem(with: item)
        applyPauseIntent()
    }

    public func setPaused(_ value: Bool) {
        precondition(Thread.isMainThread, "PerformanceAudioPlayer control requires the main thread")
        paused = value
        applyPauseIntent()
    }

    /// Zero volume deliberately leaves the media clock running. Pause is a separate intent.
    public func setVolume(_ value: Double) {
        precondition(Thread.isMainThread, "PerformanceAudioPlayer control requires the main thread")
        player.volume = Float(value.isFinite ? min(1, max(0, value)) : 0)
    }

    /// Stop revokes every pending callback before releasing the item. It never reports an end.
    public func stop() {
        precondition(Thread.isMainThread, "PerformanceAudioPlayer control requires the main thread")
        generation &+= 1
        clearObservationWork()
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    private func matches(item: AVPlayerItem?, generation token: UInt64) -> Bool {
        generation == token && player.currentItem === item
    }

    private func finish(item: AVPlayerItem?, generation token: UInt64, detail: String?) {
        guard matches(item: item, generation: token) else { return }
        let callback = completionCallback
        stop()
        callback?(detail)
    }

    private func applyPauseIntent() {
        if paused { player.pause() }
        else if hasAudioResources { player.playImmediately(atRate: 1) }
        reconcileWatchdog()
    }

    private func reconcileWatchdog() {
        guard !paused, readyReported, let item = player.currentItem else {
            watchdogTimer?.invalidate()
            watchdogTimer = nil
            return
        }
        let waiting = player.timeControlStatus != .playing
        if watchdogTimer != nil, watchdogItem === item, watchdogWaiting == waiting { return }
        watchdogTimer?.invalidate()
        watchdogItem = item
        watchdogWaiting = waiting
        watchdogTime = item.currentTime().seconds
        let token = generation
        // Match the existing player's bounded waiting/advance checks. There is no periodic
        // media sampler or system sampling; paused/stopped playback owns no stall deadline.
        let timer = Timer(timeInterval: waiting ? 8 : 30, repeats: false) { [weak self, weak item] _ in
            guard let self, let item, self.matches(item: item, generation: token), !self.paused else { return }
            self.watchdogTimer = nil
            let now = item.currentTime().seconds
            if item.status == .failed || self.player.timeControlStatus != .playing ||
                (now.isFinite && self.watchdogTime.isFinite && abs(now - self.watchdogTime) < 0.01) {
                self.finish(item: item, generation: token, detail: "音轨停止推进，请重新点播")
            } else {
                self.reconcileWatchdog()
            }
        }
        timer.tolerance = waiting ? 0.5 : 3
        watchdogTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func clearObservationWork() {
        statusObserver?.invalidate()
        statusObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        endObserver = nil
        failureObserver = nil
        loadDeadline?.cancel()
        loadDeadline = nil
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        watchdogItem = nil
        readyReported = false
        readyCallback = nil
        completionCallback = nil
    }

    deinit {
        clearObservationWork()
        playerStateObserver?.invalidate()
        player.pause()
        player.replaceCurrentItem(with: nil)
    }
}
