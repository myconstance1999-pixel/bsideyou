// BSidePlatform — PlaybackProgressObserver: the ONLY place that attaches AVPlayer media-clock
// observation for confirmed-history recording. It uses a periodic media-time observer (about one
// second) on the existing video/ambient/listen players; it creates no decoder, output, layer,
// display link, timer or system-state poll.
//
// Confirmed spans are produced exclusively by BSideCore.PlaybackProgressTracker, so every anchor,
// gap, disagreement and eligibility rule is pure and table-tested. This class only translates
// real AVFoundation state (item identity, rate/timeControlStatus, TimeJumped, end/failure,
// current-item change, enabled audio-track presence and effective volume) into observations.
//
// The callback's delivered `time` is never trusted: the media time is read synchronously together
// with the current item, monotonic uptime and UTC inside the callback, so a queued/old callback
// can never pair an old media time with a fresh identity or fresher clocks.
//
// Channel ownership: `.music` may be attached by more than one player (watch-mode video and the
// audio-only listen player). Exactly one attachment is the authoritative owner of a channel at a
// time; an inactive or unrelated attachment cannot invalidate another source's anchor. Ownership
// changes (real source/item change) advance a monotonically increasing channel generation while
// the tracker keeps ONE sequence stream per channel.
//
// Observation exists only between `enable(epoch:session:)` and `detach()`. `detach()` removes all
// observers and discards the unconfirmed tail; confirmed spans already reported are unaffected.
// Audio eligibility reads the current enabled item tracks; it keeps no asset metadata cache.

import AVFoundation
import BSideCore

public final class PlaybackProgressObserver {
    public enum Role: Hashable {
        case visual
        case music
        case ambient
    }

    /// Called on the main thread for every confirmed segment.
    public var onConfirmed: (PlaybackIntervalSubmission) -> Void = { _ in }

    private final class Attachment {
        /// Stable per-attachment identity; never derived from an object address.
        let id = UUID()
        let role: Role
        let channel: PlaybackChannel
        let player: AVPlayer
        let requiresAudioTrack: Bool
        let eligibility: () -> Bool
        var timeObserver: Any?
        var itemObservation: NSKeyValueObservation?
        var rateObservation: NSKeyValueObservation?
        var statusObservation: NSKeyValueObservation?
        var volumeObservation: NSKeyValueObservation?
        var timeJumpedObserver: NSObjectProtocol?
        var endObserver: NSObjectProtocol?
        var failureObserver: NSObjectProtocol?
        init(role: Role, player: AVPlayer, requiresAudioTrack: Bool,
             eligibility: @escaping () -> Bool) {
            self.role = role
            self.channel = role.channel
            self.player = player
            self.requiresAudioTrack = requiresAudioTrack
            self.eligibility = eligibility
        }

    }

    private var attachments: [Attachment] = []
    private var tracker: PlaybackProgressTracker?
    /// One authoritative owner per channel plus its monotonic source generation.
    private var channelOwner: [PlaybackChannel: UUID] = [:]
    private var channelGeneration: [PlaybackChannel: Int] = [:]

    public init() {}

    public var isObserving: Bool { tracker != nil }

    /// Start a fresh recording token. Any previous observers are removed first.
    public func enable(epoch: Int, session: String) {
        detachObservers()
        tracker = PlaybackProgressTracker(epoch: epoch, session: session)
        channelOwner.removeAll()
        channelGeneration.removeAll()
    }

    /// Attach media-clock observation for one existing player/channel. Safe to call while the
    /// player already has an item.
    public func attach(player: AVPlayer, role: Role, requiresAudioTrack: Bool = false,
                       eligibility: @escaping () -> Bool) {
        let attachment = Attachment(role: role, player: player,
                                    requiresAudioTrack: requiresAudioTrack, eligibility: eligibility)
        // The periodic callback is only a sampling trigger; `sample` reads the current item,
        // media time, uptime and UTC itself on the main queue.
        attachment.timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main
        ) { [weak self, weak attachment] _ in
            guard let self, let attachment else { return }
            self.sample(attachment)
        }
        attachment.itemObservation = player.observe(\.currentItem, options: [.initial, .new]) {
            [weak self, weak attachment] _, _ in
            // Serialize item boundaries with media samples.
            DispatchQueue.main.async {
                guard let self, let attachment, self.tracker != nil else { return }
                let channel = attachment.channel
                if self.channelOwner[channel] == attachment.id {
                    self.invalidateChannel(channel)
                    self.channelGeneration[channel, default: 0] &+= 1
                }
            }
        }
        attachment.rateObservation = player.observe(\.rate, options: [.new]) {
            [weak self, weak attachment] _, change in
            // Inspect the observed change, not the latest live rate: a fast pause/resume must
            // still leave a boundary instead of being masked by the already-restored rate.
            guard let newRate = change.newValue, newRate != 1 else { return }
            DispatchQueue.main.async {
                guard let self, let attachment,
                      self.channelOwner[attachment.channel] == attachment.id else { return }
                self.invalidateChannel(attachment.channel)
            }
        }
        // Buffering/waiting and end-of-item are discontinuities rate alone does not announce.
        attachment.statusObservation = player.observe(\.timeControlStatus, options: [.new]) {
            [weak self, weak attachment] _, change in
            guard let status = change.newValue, status != .playing else { return }
            DispatchQueue.main.async {
                guard let self, let attachment,
                      self.channelOwner[attachment.channel] == attachment.id else { return }
                self.invalidateChannel(attachment.channel)
            }
        }
        // A mute/unmute is an owner intent that must close the anchor immediately rather than
        // waiting up to one callback. Only an effective-volume zero crossing truncates, and only
        // for the audio-eligible channels; changing a level does not break a visual span.
        if role != .visual {
            attachment.volumeObservation = player.observe(\.volume, options: [.old, .new]) {
                [weak self, weak attachment] _, change in
                guard let old = change.oldValue, let new = change.newValue,
                      (old > 0) != (new > 0) else { return }
                DispatchQueue.main.async {
                    guard let self, let attachment,
                          self.channelOwner[attachment.channel] == attachment.id else { return }
                    self.invalidateChannel(attachment.channel)
                }
            }
        }
        attachment.timeJumpedObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemTimeJumped, object: nil, queue: .main
        ) { [weak self, weak attachment] note in
            guard let self, let attachment, let item = note.object as? AVPlayerItem,
                  attachment.player.currentItem === item else { return }
            self.boundary(attachment)
        }
        attachment.endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main
        ) { [weak self, weak attachment] note in
            guard let self, let attachment, let item = note.object as? AVPlayerItem,
                  attachment.player.currentItem === item else { return }
            self.boundary(attachment)
        }
        attachment.failureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main
        ) { [weak self, weak attachment] note in
            guard let self, let attachment, let item = note.object as? AVPlayerItem,
                  attachment.player.currentItem === item else { return }
            self.boundary(attachment)
        }
        attachments.append(attachment)
    }

    /// Owner-declared boundary: close this role's anchor BEFORE the owner mutates the player
    /// (pause/seek/mute). Safe to call at any time; a no-op when nothing is open.
    public func invalidate(role: Role) {
        invalidateChannel(role.channel)
    }

    /// Close every channel before a global owner mutation (pause/disable).
    public func invalidateAll() {
        for channel in PlaybackChannel.allCases {
            invalidateChannel(channel)
        }
    }

    /// Remove every observer and discard the unconfirmed tail. Confirmed submissions already
    /// delivered through `onConfirmed` are the caller's data and are not retracted.
    public func detach() {
        detachObservers()
        tracker = nil
        channelOwner.removeAll()
        channelGeneration.removeAll()
    }

    /// Close every confirmed anchor at a state boundary and return the closed spans.
    public func flush() -> [PlaybackIntervalSubmission] {
        guard var current = tracker else { return [] }
        let closed = current.closeAll()
        tracker = current
        return closed
    }

    private func detachObservers() {
        for attachment in attachments {
            if let observer = attachment.timeObserver {
                attachment.player.removeTimeObserver(observer)
            }
            attachment.itemObservation?.invalidate()
            attachment.rateObservation?.invalidate()
            attachment.statusObservation?.invalidate()
            attachment.volumeObservation?.invalidate()
            if let observer = attachment.timeJumpedObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            if let observer = attachment.endObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            if let observer = attachment.failureObserver {
                NotificationCenter.default.removeObserver(observer)
            }
        }
        attachments.removeAll()
    }

    /// Invalidate only when this attachment is the authoritative owner of its channel. An
    /// unrelated/inactive attachment must never clear another source's live anchor.
    private func boundary(_ attachment: Attachment) {
        guard channelOwner[attachment.channel] == attachment.id else { return }
        invalidateChannel(attachment.channel)
    }

    private func invalidateChannel(_ channel: PlaybackChannel, clearOwner: Bool = true) {
        guard var current = tracker else { return }
        let closed = current.invalidate(channel: channel)
        tracker = current
        if clearOwner { channelOwner.removeValue(forKey: channel) }
        if let closed { onConfirmed(closed) }
    }

    private func sample(_ attachment: Attachment) {
        guard tracker != nil else { return }
        let player = attachment.player
        // Synchronous co-sampling: identity, media clock, uptime and wall clock all read here.
        let item = player.currentItem
        let mediaTime = player.currentTime().seconds
        let monotonicTime = ProcessInfo.processInfo.systemUptime
        let utc = Date()
        guard let item else {
            boundary(attachment)
            return
        }
        let channel = attachment.channel
        let audioOK = !attachment.requiresAudioTrack || audioTrackState(attachment, item: item) == true
        let active = player.rate == 1 && player.timeControlStatus == .playing
            && audioOK && attachment.eligibility()
        guard active else {
            boundary(attachment)
            return
        }
        if channelOwner[channel] != attachment.id {
            // Real source change: close the previous owner's anchor and advance the channel source
            // generation. The tracker keeps one sequence stream per channel.
            invalidateChannel(channel, clearOwner: false)
            channelOwner[channel] = attachment.id
            channelGeneration[channel, default: 0] &+= 1
        }
        guard var current = tracker else { return }
        let observation = PlaybackProgressObservation(
            channel: channel,
            generation: channelGeneration[channel] ?? 0,
            item: ObjectIdentifier(item).hashValue,
            mediaTime: mediaTime,
            monotonicTime: monotonicTime,
            utc: utc,
            isActive: true)
        let closed = current.ingest(observation)
        tracker = current
        if let closed { onConfirmed(closed) }
    }

    /// Read the currently enabled item tracks at each sample; empty/unknown is ineligible.
    private func audioTrackState(_ attachment: Attachment, item: AVPlayerItem) -> Bool {
        item.tracks.contains { $0.isEnabled && $0.assetTrack?.mediaType == .audio }
    }

}

private extension PlaybackProgressObserver.Role {
    var channel: PlaybackChannel {
        switch self {
        case .visual: return .visual
        case .music: return .music
        case .ambient: return .ambient
        }
    }
}
