// Confirmed-progress classification and exclusive daily/song visual ownership regressions.

import Foundation
import AVFoundation
import BSidePlatform
import BSideCore

private let progressAnchor = ISO8601DateFormatter().date(from: "2026-09-10T10:00:00Z")!

private func observation(
    _ channel: PlaybackChannel = .visual, generation: Int = 1, item: Int = 1,
    media: Double, mono: Double, utc: Date? = nil, active: Bool = true
) -> PlaybackProgressObservation {
    PlaybackProgressObservation(
        channel: channel, generation: generation, item: item, mediaTime: media,
        monotonicTime: mono, utc: utc ?? progressAnchor.addingTimeInterval(mono), isActive: active)
}

func runPlaybackProgressTests() {
    run("PlaybackProgressObserver.dailyAndSongVisualOwnershipIsExclusive") { t in
        do {
            let url = try makeTinyVideo(seconds: 14)
            defer { try? FileManager.default.removeItem(at: url) }
            let daily = AVPlayer(url: url), song = AVPlayer(url: url)
            defer { daily.pause(); song.pause() }
            let observer = PlaybackProgressObserver()
            defer { observer.detach() }
            var visibleSong: Bool? = false
            var spans: [PlaybackIntervalSubmission] = []
            observer.onConfirmed = { spans.append($0) }
            observer.enable(epoch: 1, session: "separate-sources")
            observer.attach(player: daily, role: .visual) { visibleSong == false }
            observer.attach(player: song, role: .visual) { visibleSong == true }
            daily.play(); song.play()
            func wait(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
            wait(2.4)
            t.expect(!spans.isEmpty, "daily actual clock earns visual history while song is hidden")
            observer.invalidate(role: .visual); visibleSong = nil
            let unknownCount = spans.count
            wait(1.3)
            t.expectEqual(spans.count, unknownCount, "unknown presentation visibility earns neither source")
            observer.invalidate(role: .visual); visibleSong = true
            wait(2.4)
            t.expect(spans.count > unknownCount, "visible song earns its own fresh spans")
            let beforeDailyLoss = spans.count
            daily.replaceCurrentItem(with: nil)
            wait(1.3)
            t.expect(spans.count > beforeDailyLoss, "daily invalidation cannot terminate song visual ownership")
            t.expect(spans.allSatisfy { $0.channel == .visual }, "two players still supply one aggregate visual channel")
            for (left, right) in zip(spans, spans.dropFirst()) {
                t.expect(left.monotonicEnd <= right.monotonicStart + 0.001,
                         "daily and song never double count an overlapping visual interval")
            }
        } catch { t.expect(false, "fixture error: \(error)") }
    }
    run("PlaybackProgress.advancingMediaProducesNonEmptyOrderedSpans") { t in
        var tracker = PlaybackProgressTracker(epoch: 0, session: "s1")
        t.expectNil(tracker.ingest(observation(media: 10, mono: 100)), "first sample only baselines")
        let first = tracker.ingest(observation(media: 11, mono: 101))
        t.expectNotNil(first, "a second compatible sample confirms a span")
        guard let first else { return }
        t.expectNear(first.monotonicEnd - first.monotonicStart, 1, "conservative duration is one second", eps: 0.0001)
        t.expectEqual(first.epoch, 0, "token epoch retained")
        t.expectEqual(first.session, "s1", "token session retained")
        t.expectEqual(first.channel, .visual, "channel retained")
        t.expectEqual(first.sequence, 1, "first sequence")
        let second = tracker.ingest(observation(media: 12, mono: 102))
        t.expectNotNil(second, "rotation reports the next confirmed span")
        guard let second else { return }
        t.expectEqual(second.sequence, 2, "sequence increases")
        t.expectNear(second.monotonicStart, first.monotonicEnd,
                     "rotated spans are contiguous and non-overlapping", eps: 0.0001)
        t.expect(second.monotonicStart >= first.monotonicEnd, "no overlap after truncation")
    }

    run("PlaybackProgress.pauseBreaksAnchorAndResumeUsesFreshBaseline") { t in
        var tracker = PlaybackProgressTracker(epoch: 3, session: "s")
        _ = tracker.ingest(observation(media: 0, mono: 0))
        let before = tracker.ingest(observation(media: 1, mono: 1))
        t.expectNotNil(before, "span before pause confirmed")
        t.expectNil(tracker.ingest(observation(media: 2, mono: 2, active: false)),
                    "an inactive sample closes the anchor without a tail")
        // A late/backdated active sample that would bridge the pause is a discontinuity.
        t.expectNil(tracker.ingest(observation(media: 2.5, mono: 2.5)),
                    "resume only re-baselines")
        let resumed = tracker.ingest(observation(media: 3.5, mono: 3.5))
        t.expectNotNil(resumed, "resume confirms a fresh span")
        if let resumed {
            t.expect(resumed.monotonicStart >= 2.5,
                     "no interval crosses the pause boundary: \(resumed.monotonicStart)")
        }
    }

    run("PlaybackProgress.longGapAndClockDisagreementNeverInventDuration") { t in
        var tracker = PlaybackProgressTracker(epoch: 0, session: "s")
        _ = tracker.ingest(observation(media: 0, mono: 0))
        t.expectNil(tracker.ingest(observation(media: 1, mono: 12)),
                    "a callback gap beyond the bound breaks and re-baselines")
        t.expectNil(tracker.ingest(observation(media: 20, mono: 24)),
                    "a media discontinuity beyond the bound breaks the anchor")
        // After the two breaks the tracker keeps working from a fresh, agreeing baseline.
        t.expectNotNil(tracker.ingest(observation(media: 21, mono: 25)),
                       "agreeing samples confirm again after re-baselining")
    }

    run("PlaybackProgress.backwardsMediaAndItemChangeBreakAnchor") { t in
        var tracker = PlaybackProgressTracker(epoch: 0, session: "s")
        _ = tracker.ingest(observation(media: 5, mono: 5))
        t.expectNil(tracker.ingest(observation(media: 4, mono: 6)),
                    "backwards media re-baselines instead of seeking elapsed time")
        t.expectNil(tracker.ingest(observation(item: 2, media: 5, mono: 7)),
                    "a new item starts a fresh anchor")
        let changed = tracker.ingest(observation(item: 2, media: 6, mono: 8))
        t.expectNotNil(changed, "the new item confirms on its own")
        t.expectNil(tracker.ingest(observation(generation: 2, item: 2, media: 7, mono: 9)),
                    "a new generation re-baselines")
    }

    run("PlaybackProgress.monotonicIntervalCountedWhenMediaAgrees") { t in
        var tracker = PlaybackProgressTracker(epoch: 0, session: "s")
        _ = tracker.ingest(observation(media: 0, mono: 0))
        let span = tracker.ingest(observation(media: 1.1, mono: 1.3))
        t.expectNotNil(span, "within-tolerance agreement confirms the segment")
        if let span {
            let duration = span.monotonicEnd - span.monotonicStart
            t.expectNear(duration, 1.3, "the monotonic interval is counted, not a min() slice", eps: 0.0001)
        }
        // Material disagreement is a discontinuity, not a truncation to be backdated.
        t.expectNil(tracker.ingest(observation(media: 2.1, mono: 4.0)),
                    "a stall-sized disagreement breaks and re-baselines")
        t.expectNil(tracker.ingest(observation(media: 9.0, mono: 4.6)),
                    "a seek-sized media jump never becomes elapsed playback")
    }

    run("PlaybackProgress.tinyProgressionAndCloseAllNeverFabricate") { t in
        var tracker = PlaybackProgressTracker(epoch: 0, session: "s")
        _ = tracker.ingest(observation(media: 0, mono: 0))
        t.expectNil(tracker.ingest(observation(media: 0.1, mono: 0.1)),
                    "below-minimum noise is not stored")
        t.expect(tracker.closeAll().isEmpty, "closing an unconfirmed tail emits nothing")
        let inactiveFirst = tracker.ingest(observation(.music, media: 1, mono: 1, active: false))
        t.expectNil(inactiveFirst, "an inactive first sample never creates a span")
    }

    run("PlaybackProgress.channelsStayIndependent") { t in
        var tracker = PlaybackProgressTracker(epoch: 1, session: "s")
        _ = tracker.ingest(observation(.visual, media: 0, mono: 0))
        _ = tracker.ingest(observation(.music, media: 0, mono: 0))
        let visual = tracker.ingest(observation(.visual, media: 1, mono: 1))
        let music = tracker.ingest(observation(.music, media: 1, mono: 1))
        t.expectNotNil(visual, "visual span confirmed independently")
        t.expectNotNil(music, "music span confirmed independently")
        t.expectEqual(visual?.channel, .visual, "visual channel")
        t.expectEqual(music?.channel, .music, "music channel")
        t.expectNil(tracker.ingest(observation(.ambient, media: 0, mono: 0, active: false)),
                    "an unrelated channel is untouched")
    }

    run("PlaybackProgress.utcJumpDiscardsCrossingCandidateAndReanchors") { t in
        var tracker = PlaybackProgressTracker(epoch: 0, session: "s")
        _ = tracker.ingest(observation(media: 0, mono: 0))
        t.expectNotNil(tracker.ingest(observation(media: 1, mono: 1)),
                       "a consistent UTC/monotonic segment confirms")
        // Wall clock jumps forward 100s while monotonic advances only 1s: the crossing candidate
        // must be discarded (not counted), never timed from the UTC delta.
        t.expectNil(
            tracker.ingest(observation(media: 2, mono: 2,
                                       utc: progressAnchor.addingTimeInterval(101))),
            "a wall-clock jump discards the crossing candidate and re-anchors")
        // The new anchor is consistent again, so post-jump playback confirms normally.
        let after = tracker.ingest(observation(media: 3, mono: 3,
                                               utc: progressAnchor.addingTimeInterval(102)))
        t.expectNotNil(after, "post-jump samples confirm on a fresh, consistent anchor")
        if let after {
            t.expect(after.monotonicStart >= 2, "no interval crosses the wall-clock jump")
        }
        // A backwards wall-clock jump is equally a discontinuity.
        _ = tracker.ingest(observation(media: 4, mono: 4,
                                       utc: progressAnchor.addingTimeInterval(103)))
        t.expectNil(
            tracker.ingest(observation(media: 5, mono: 5,
                                       utc: progressAnchor.addingTimeInterval(50))),
            "a backwards wall-clock jump also discards the crossing candidate")
    }

    run("PlaybackProgressEligibility.visualRequiresAvailableResources") { t in
        t.expect(PlaybackProgressEligibility.visual(
            hasVideoResources: true, systemSuppressed: false, resourcesAvailable: true),
            "present media under no suppression is eligible")
        t.expect(!PlaybackProgressEligibility.visual(
            hasVideoResources: true, systemSuppressed: false, resourcesAvailable: false),
            "a retained clock over unavailable accepted media is never eligible")
        t.expect(!PlaybackProgressEligibility.visual(
            hasVideoResources: false, systemSuppressed: false, resourcesAvailable: true),
            "no installed item is ineligible")
        t.expect(!PlaybackProgressEligibility.visual(
            hasVideoResources: true, systemSuppressed: true, resourcesAvailable: true),
            "policy suppression stays ineligible")
    }

    run("PlaybackProgress.visualEligibilityInvalidatesAndRecoversWithAcceptedMedia") { t in
        // The observer's `isActive` verdict for visual is exactly this pure rule. The retained
        // AVPlayer clock described by the volume-loss evidence keeps advancing with monotonic
        // time while the displayed frame is frozen, so resource availability — not media time —
        // must decide whether the span may accrue.
        func active(_ resourcesAvailable: Bool) -> Bool {
            PlaybackProgressEligibility.visual(
                hasVideoResources: true, systemSuppressed: false,
                resourcesAvailable: resourcesAvailable)
        }
        var tracker = PlaybackProgressTracker(epoch: 7, session: "resource-loss")
        _ = tracker.ingest(observation(media: 10.9, mono: 100, active: active(true)))
        let beforeLoss = tracker.ingest(observation(media: 11.9, mono: 101, active: active(true)))
        t.expectNotNil(beforeLoss, "accepted media confirms a visual span before the loss")

        // Resource loss: the retained clock and monotonic time keep advancing together, but every
        // sample is ineligible. No frozen-clock tail may be confirmed as displayed history.
        var duringLoss: [PlaybackIntervalSubmission] = []
        for step in 1...9 {
            let closed = tracker.ingest(observation(media: 11.9 + Double(step),
                                                    mono: 101 + Double(step), active: active(false)))
            if let closed { duringLoss.append(closed) }
        }
        t.expect(duringLoss.isEmpty,
                 "a retained advancing clock over unavailable media confirms nothing")

        // Recovery: valid daily media returns. The first eligible sample only re-baselines; a
        // later one confirms a fresh span that cannot bridge the unavailable interval.
        t.expectNil(tracker.ingest(observation(media: 21.9, mono: 111, active: active(true))),
                    "recovery re-baselines instead of bridging the loss")
        let recovered = tracker.ingest(observation(media: 22.9, mono: 112, active: active(true)))
        t.expectNotNil(recovered, "returned valid media confirms a fresh visual span")
        if let recovered {
            t.expect(recovered.monotonicStart >= 111,
                     "the recovered span starts after the loss: \(recovered.monotonicStart)")
        }
    }

    run("PlaybackProgress.knownLossSameSourceRefreshReplacesBeforeHistoryReopens") { t in
        // Lifecycle: known accepted-root loss -> remount before the retained unit ends with
        // identical path/version metadata -> actual replacement at EOF -> recording reopens.
        // Discovery availability alone cannot carry the stale retained item (the short-volume
        // evidence: the same item stayed frozen while the re-accepted directory resumed history).
        let key = ContentKey(scene: .a, outfit: .r1, time: .noon)
        let selection = ContentSelection(loop: ContentID("loop://a/r1/noon"),
                                         ambient: nil, targetKey: key)
        func active(_ resourcesAvailable: Bool) -> Bool {
            PlaybackProgressEligibility.visual(
                hasVideoResources: true, systemSuppressed: false,
                resourcesAvailable: resourcesAvailable)
        }
        t.expect(DailyInstalledMediaValidity().indicatesSourceChange(metadataDiffers: true),
                 "an ordinary source replacement is unchanged by the invalidation state")

        var installed = DailyInstalledMediaValidity()
        var tracker = PlaybackProgressTracker(epoch: 9, session: "replacement")
        _ = tracker.ingest(observation(media: 4.5, mono: 200,
                                       active: active(installed.historyEligible(discoveryAccepted: true))))
        let beforeLoss = tracker.ingest(observation(
            media: 5.5, mono: 201, active: active(installed.historyEligible(discoveryAccepted: true))))
        t.expectNotNil(beforeLoss, "an accepted fresh installation confirms a span before the loss")
        t.expect(!installed.indicatesSourceChange(metadataDiffers: false),
                 "no replacement is pending before any loss")

        // Known accepted-root loss: the retained item is invalidated and the anchor closes.
        installed.invalidatedByResourceLoss()
        t.expectNil(tracker.ingest(observation(
            media: 6.5, mono: 202, active: active(installed.historyEligible(discoveryAccepted: false)))),
            "the retained clock confirms nothing once the loss is declared")
        t.expectNil(tracker.ingest(observation(
            media: 10.5, mono: 206, active: active(installed.historyEligible(discoveryAccepted: true)))),
            "directory acceptance alone cannot reopen history for the invalidated item")

        // Remount before the original EOF with equal metadata. The invalidation must present as a
        // pending source change so the surviving complete unit finishes and is replaced at EOF.
        let sourceChanged = installed.indicatesSourceChange(metadataDiffers: false)
        t.expect(sourceChanged, "the invalidated item is a pending source change despite equal metadata")
        var switchState = DailySwitchLifecycle()
        t.expectEqual(switchState.update(current: key, selection: selection, automatic: true,
            paused: false, hasVideo: true, sourceChanged: sourceChanged), .waitForEnd,
            "recovery before EOF preserves the remaining complete unit")
        t.expectEqual(switchState.update(current: key, selection: selection, automatic: true,
            paused: false, hasVideo: true, sourceChanged: sourceChanged, atUnitEnd: true), .install,
            "EOF installs a fresh item even though path/version metadata compares equal")

        // Only the actual fresh installation clears the invalidation and reopens recording.
        installed.replacedByFreshInstall()
        t.expect(!installed.indicatesSourceChange(metadataDiffers: false),
                 "the installed replacement resolves the pending change")
        t.expect(installed.historyEligible(discoveryAccepted: true),
                 "history reopens only after the fresh install")
        t.expectNil(tracker.ingest(observation(
            media: 11.5, mono: 210, active: active(installed.historyEligible(discoveryAccepted: true)))),
            "the fresh item re-baselines instead of bridging the invalidated interval")
        let reopened = tracker.ingest(observation(
            media: 12.5, mono: 211, active: active(installed.historyEligible(discoveryAccepted: true))))
        t.expectNotNil(reopened, "the replacement confirms its own fresh span")
        if let reopened {
            t.expect(reopened.monotonicStart >= 210,
                     "no span crosses the invalidated interval: \(reopened.monotonicStart)")
        }
    }
}
