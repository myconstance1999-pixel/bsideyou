// BSideTestRunner — reviewed daily activity entry: exact inventory, per-source identity, v8
// roundtrip and the pure latest-request-wins/cancellation bookkeeping. No paths, media or network.

import Foundation
import CryptoKit
import BSideCore
import BSidePlatform

private func sourceKey(_ scene: Scene, _ outfit: Outfit, _ time: TimeOfDay) -> ContentKey {
    ContentKey(scene: scene, outfit: outfit, time: time)
}

private let reviewedNoon = sourceKey(.a, .r1, .noon)
private let reviewedEvening = sourceKey(.a, .r1, .evening)
private let reviewedNight = sourceKey(.a, .r1, .night)
private let reviewedR2Evening = sourceKey(.a, .r2, .evening)

func runDailyActivityTests() {
    run("DailyActivity.exactReviewedInventory") { t in
        t.expectEqual(DailyActivityID.allCases, [.desk, .rest],
                      "only the two reviewed activities are offered (no invented reading)")
        t.expectEqual(Set(DailyActivityID.allCases.map(\.rawValue)), ["desk", "rest"],
                      "stable wire identifiers")

        // Exactly the eight reviewed entries: two per qualified source.
        let entries = DailyActivityCatalog.entries
        t.expectEqual(entries.count, 8, "exactly the eight reviewed authored entry points")
        t.expectEqual(Set(entries.map(\.sourceKey)),
                      [reviewedNoon, reviewedEvening, reviewedNight, reviewedR2Evening],
                      "entries exist only in the four reviewed whole sources")
        for key in [reviewedNoon, reviewedEvening, reviewedNight, reviewedR2Evening] {
            for activity in DailyActivityID.allCases {
                let entry = DailyActivityCatalog.entry(for: key, activityID: activity)
                t.expect(entry?.sourceKey == key && entry?.activityID == activity,
                         "every reviewed source carries its own \(activity.rawValue) entry: \(key)")
                t.expectEqual(entry?.timescale, 30_000, "every reviewed entry uses the 1/30000 timebase")
            }
        }

        // The pre-existing A/R1/sunset points are unchanged.
        let eveningDesk = DailyActivityCatalog.entry(for: reviewedEvening, activityID: .desk)
        let eveningRest = DailyActivityCatalog.entry(for: reviewedEvening, activityID: .rest)
        t.expectEqual(eveningDesk?.ticks, 1_913_000, "sunset desk keeps its original PTS ticks")
        t.expectEqual(eveningRest?.ticks, 2_979_000, "sunset rest keeps its original PTS ticks")
        t.expectNear(eveningDesk?.point.seconds ?? 0, 63.7666667, "sunset desk seconds", eps: 0.0000001)
        t.expectNear(eveningRest?.point.seconds ?? 0, 99.3, "sunset rest seconds", eps: 0.0000001)

        // The six newly reviewed camera-cut introductions are exact.
        t.expectEqual(DailyActivityCatalog.entry(for: reviewedNoon, activityID: .desk)?.ticks, 318_000,
                      "noon desk entry at 10.6s")
        t.expectEqual(DailyActivityCatalog.entry(for: reviewedNoon, activityID: .rest)?.ticks, 5_355_000,
                      "noon rest entry at 178.5s")
        t.expectEqual(DailyActivityCatalog.entry(for: reviewedNight, activityID: .desk)?.ticks, 2_916_000,
                      "night desk entry at 97.2s")
        t.expectEqual(DailyActivityCatalog.entry(for: reviewedNight, activityID: .rest)?.ticks, 319_000,
                      "night rest entry at 10.633333s")
        t.expectEqual(DailyActivityCatalog.entry(for: reviewedR2Evening, activityID: .desk)?.ticks, 3_290_000,
                      "R2 sunset desk entry at 109.666667s")
        t.expectEqual(DailyActivityCatalog.entry(for: reviewedR2Evening, activityID: .rest)?.ticks, 4_033_000,
                      "R2 sunset rest entry at 134.433333s")

        // No substitution: an unqualified combination is simply absent.
        t.expectNil(DailyActivityCatalog.entry(for: sourceKey(.a, .r2, .noon), activityID: .desk),
                    "R2 has no reviewed noon entry (no cross-time fallback)")
        t.expectNil(DailyActivityCatalog.entry(for: sourceKey(.a, .r2, .night), activityID: .rest),
                    "R2 has no reviewed night entry (no cross-time fallback)")
        t.expectNil(DailyActivityCatalog.entry(for: sourceKey(.a, .r3, .evening), activityID: .desk),
                    "R3 has no reviewed entry at all")
        t.expectNil(DailyActivityCatalog.entry(for: sourceKey(.b, .r1, .evening), activityID: .desk),
                    "material group B has no reviewed entry here")
        t.expect(!DailyActivityCatalog.hasAnyEntry(for: sourceKey(.a, .r3, .evening)),
                 "R3 is not qualified for any activity")
        t.expect(DailyActivityCatalog.hasAnyEntry(for: reviewedR2Evening),
                 "R2/sunset is the one qualified R2 source")

        // Every activity has its own offset inside every source; no two reviewed points collide.
        let points = entries.map { "\($0.sourceKey)|\($0.activityID.rawValue)|\($0.ticks)" }
        t.expectEqual(Set(points).count, entries.count, "no two reviewed entries share source/activity/offset")
    }

    run("DailyActivity.sameActivityDifferentSourceIsDistinct") { t in
        let noonDesk = DailyActivityCatalog.entry(for: reviewedNoon, activityID: .desk)
        let eveningDesk = DailyActivityCatalog.entry(for: reviewedEvening, activityID: .desk)
        let r2Desk = DailyActivityCatalog.entry(for: reviewedR2Evening, activityID: .desk)
        t.expect(noonDesk != eveningDesk && eveningDesk != r2Desk && noonDesk != r2Desk,
                 "the same activity in different sources carries a distinct entry")
        let offsets = [noonDesk?.ticks, eveningDesk?.ticks, r2Desk?.ticks].compactMap { $0 }
        t.expectEqual(Set(offsets).count, 3, "desk offsets differ per source")

        // The same activity is also a different identity per source.
        let noonIdentity = DailyActivitySourceIdentity.reviewed(for: reviewedNoon)
        let eveningIdentity = DailyActivitySourceIdentity.reviewed(for: reviewedEvening)
        let r2Identity = DailyActivitySourceIdentity.reviewed(for: reviewedR2Evening)
        t.expect(noonIdentity != eveningIdentity && eveningIdentity != r2Identity && noonIdentity != r2Identity,
                 "each reviewed source has its own whole-file identity")
        t.expectEqual(DailyActivitySourceIdentity.reviewed(for: reviewedNoon)?.sha256,
                      "3921fb7f656907ff3f2b95795187da758348f23823ca064fb36bd8f2c8ac571f",
                      "the noon identity stays bound to its own source key")
    }

    run("DailyActivity.reviewedIdentityPerSourceKey") { t in
        // Exactly four reviewed identities, one per qualified source, with no unknown fallback.
        let qualifiedKeys = [reviewedNoon, reviewedEvening, reviewedNight, reviewedR2Evening]
        let identities = qualifiedKeys.compactMap { DailyActivitySourceIdentity.reviewed(for: $0) }
        t.expectEqual(identities.count, 4, "exactly four reviewed source identities")
        t.expectEqual(Set(identities.map(\.sha256)).count, 4, "each reviewed identity is distinct")

        t.expectEqual(DailyActivitySourceIdentity.reviewed(for: reviewedNoon)?.byteSize, 125_130_252,
                      "A/R1/noon exact byte length")
        t.expectEqual(DailyActivitySourceIdentity.reviewed(for: reviewedNoon)?.sha256,
                      "3921fb7f656907ff3f2b95795187da758348f23823ca064fb36bd8f2c8ac571f",
                      "A/R1/noon full SHA-256")
        t.expectEqual(DailyActivitySourceIdentity.reviewed(for: reviewedEvening)?.byteSize, 106_935_332,
                      "A/R1/sunset exact byte length")
        t.expectEqual(DailyActivitySourceIdentity.reviewed(for: reviewedEvening)?.sha256,
                      "7fbc3c21975832c7c0855a287623c86136071c249bf7485d7791b5ad5acfd976",
                      "A/R1/sunset full SHA-256 is unchanged")
        t.expectEqual(DailyActivitySourceIdentity.reviewed(for: reviewedNight)?.byteSize, 93_098_638,
                      "A/R1/night exact byte length")
        t.expectEqual(DailyActivitySourceIdentity.reviewed(for: reviewedNight)?.sha256,
                      "3740912fc4efc84633e38e52987fedc2a358e4ed3f3d900311f0f7b209cc6641",
                      "A/R1/night full SHA-256")
        t.expectEqual(DailyActivitySourceIdentity.reviewed(for: reviewedR2Evening)?.byteSize, 110_641_767,
                      "A/R2/sunset exact byte length")
        t.expectEqual(DailyActivitySourceIdentity.reviewed(for: reviewedR2Evening)?.sha256,
                      "14289bb53fcc86e7d6166aa94d2b8fbe4a0aec70f5502d05b45de9dd4f3c92b9",
                      "A/R2/sunset full SHA-256")

        // An unqualified combination has no identity: it can never be verified against another
        // source's digest, and there is no unknown fallback.
        t.expectNil(DailyActivitySourceIdentity.reviewed(for: sourceKey(.a, .r2, .noon)),
                    "R2/noon has no reviewed identity")
        t.expectNil(DailyActivitySourceIdentity.reviewed(for: sourceKey(.a, .r3, .evening)),
                    "R3 has no reviewed identity")
        t.expectNil(DailyActivitySourceIdentity.reviewed(for: sourceKey(.b, .r1, .noon)),
                    "group B has no reviewed identity here")
        for key in qualifiedKeys {
            let identity = DailyActivitySourceIdentity.reviewed(for: key)
            t.expectEqual(identity?.sha256.count, 64, "full digest, not a prefix: \(key)")
            t.expect(identity?.sha256.allSatisfy { $0.isHexDigit && !$0.isUppercase } == true,
                     "lowercase hex digest: \(key)")
        }
    }

    run("DailyActivity.desiredSourceKeyHasNoAutoFallback") { t in
        let fixed = DesiredState(scene: .a, outfit: .r2, timeMode: .fixed(.evening))
        t.expectEqual(fixed.dailySourceKey, reviewedR2Evening,
                      "a fixed desired state exposes its own exact source key")
        t.expectNil(DesiredState(scene: .a, outfit: .r1, timeMode: .auto).dailySourceKey,
                    "automatic time has no concrete source key, so it never matches a request")
    }

    run("DailyActivity.requestAndReportRoundTrip") { t in
        let desired = DesiredState(scene: .a, outfit: .r2, timeMode: .fixed(.evening),
                                   masterVolume: 0.42, musicVolume: 0.3, ambientVolume: 0.6,
                                   paused: true, profile: .coding)
        let request = DailyActivityRequest(requestID: "entry-1", activityID: .desk, desired: desired)
        let line = IPCCoding.encodeLine(IPCEnvelope(payload: AgentCommand.startDailyActivity(request)))
        t.expectNotNil(line, "request encodes")
        t.expect(line?.contains("\n") == false, "single line")
        let decoded = line.flatMap { IPCCoding.decodeLine($0, as: AgentCommand.self) }
        t.expectEqual(decoded?.payload, .startDailyActivity(request), "request round trip")
        // The complete desired state travels with the request: source key, pause and volumes.
        if case .startDailyActivity(let decodedRequest)? = decoded?.payload {
            t.expectEqual(decodedRequest.desired.dailySourceKey, reviewedR2Evening,
                          "the exact requested source key travels unchanged")
            t.expectEqual(decodedRequest.desired.paused, true, "pause travels atomically")
            t.expectEqual(decodedRequest.desired.masterVolume, 0.42, "master volume preserved")
            t.expectEqual(decodedRequest.desired.profile, .coding, "profile preserved")
            t.expectEqual(decodedRequest.activityID, .desk, "activity id preserved")
        } else {
            t.expect(false, "decoded command is a startDailyActivity")
        }

        for state in DailyActivityRequestState.allCases {
            let report = DailyActivityReport(requestID: "entry-1", state: state, detail: "d")
            let eventLine = IPCCoding.encodeLine(IPCEnvelope(payload: AgentEvent.dailyActivity(report)))
            t.expectNotNil(eventLine, "report encodes: \(state)")
            let event = eventLine.flatMap { IPCCoding.decodeLine($0, as: AgentEvent.self) }
            t.expectEqual(event?.payload, .dailyActivity(report), "report round trip: \(state)")
        }
        t.expectEqual(DailyActivityRequestState.allCases.map(\.rawValue),
                      ["verifying", "applied", "failed", "cancelled"], "stable report states")
        t.expectEqual(IPC.protocolVersion, 17,
                      "desktop workspace requires IPC17; daily activity is unchanged")
    }

    run("DailyActivity.trackerLatestWinsAndSameKeyRepeat") { t in
        var tracker = DailyActivityRequestTracker()
        t.expectNil(tracker.latest, "nothing outstanding initially")
        t.expect(!tracker.isPending, "not pending")
        let first = DailyActivityRequest(requestID: "r1", activityID: .desk,
            desired: DesiredState(scene: .a, outfit: .r1, timeMode: .fixed(.noon)))
        t.expectNil(tracker.begin(first), "first request has nothing to supersede")
        t.expectEqual(tracker.armedRequestID, "r1", "the first request may install")
        // The same activity re-clicked is a NEW request: it cancels the old one and starts again.
        let second = DailyActivityRequest(requestID: "r2", activityID: .desk,
            desired: DesiredState(scene: .a, outfit: .r2, timeMode: .fixed(.evening)))
        t.expectEqual(tracker.begin(second), "r1", "a re-click supersedes the previous request")
        t.expectEqual(tracker.armedRequestID, "r2", "only the newest request may install")
        t.expectEqual(tracker.latest?.desired.dailySourceKey, reviewedR2Evening,
                      "the tracker keeps each request's own source key")
        t.expect(!tracker.accept(DailyActivityReport(requestID: "r1", state: .applied)),
                 "a stale report cannot change the latest request state")
        t.expectEqual(tracker.state, .verifying, "state stays the latest request's")
        t.expect(tracker.accept(DailyActivityReport(requestID: "r2", state: .failed, detail: "identity")),
                 "the latest request report is accepted")
        t.expectEqual(tracker.state, .failed, "failed state recorded")
        t.expectEqual(tracker.detail, "identity", "failure detail recorded")
        t.expectEqual(tracker.armedRequestID, nil, "a terminal request is no longer armed")
    }

    run("DailyActivity.trackerCancellationAndClear") { t in
        var tracker = DailyActivityRequestTracker()
        let request = DailyActivityRequest(requestID: "r1", activityID: .rest,
            desired: DesiredState(scene: .a, outfit: .r1, timeMode: .fixed(.night)))
        tracker.begin(request)
        tracker.begin(DailyActivityRequest(requestID: "r2", activityID: .rest, desired: request.desired))
        let cancellation = tracker.cancel(detail: "source changed")
        t.expectEqual(cancellation?.requestID, "r2", "cancellation belongs to the latest request")
        t.expectEqual(cancellation?.state, .cancelled, "cancellation state")
        t.expectEqual(tracker.state, .cancelled, "tracker records the cancellation")
        t.expectNil(tracker.cancel(detail: "again"), "an already-cancelled request reports nothing new")
        tracker.clear()
        t.expectNil(tracker.latest, "clear drops the transient request")
        t.expectNil(tracker.state, "clear drops the state")
    }

    run("DailyActivity.notPersistedInDesiredState") { t in
        let desired = DesiredState(scene: .a, outfit: .r1, timeMode: .fixed(.evening))
        let data = (try? JSONEncoder().encode(desired)) ?? Data()
        let json = String(data: data, encoding: .utf8) ?? ""
        t.expect(!json.contains("activity"), "DesiredState carries no activity field")
        t.expect(!json.contains("requestID"), "DesiredState carries no transient request id")
        // A fresh app-session tracker starts empty; nothing is replayed from persistence.
        let restarted = DailyActivityRequestTracker()
        t.expectNil(restarted.latest, "a restarted session has no replayed activity request")
    }

    run("DailyActivity.integrityRequiresExactSizeAndDigest") { t in
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bsidemac-activity-identity-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        let bytes = Data(repeating: 0x5A, count: 4096)
        do { try bytes.write(to: url) } catch { t.expect(false, "fixture write failed: \(error)"); return }
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        do {
            try DailyActivityIntegrity.verify(url: url,
                identity: DailyActivitySourceIdentity(byteSize: 4096, sha256: digest))
        } catch {
            t.expect(false, "matching size + digest must verify: \(error)")
        }
        // Metadata (size) alone is never reviewed-content identity.
        let wrongDigest = DailyActivitySourceIdentity(byteSize: 4096, sha256: String(repeating: "0", count: 64))
        t.expectThrows("a same-size different digest must fail") {
            try DailyActivityIntegrity.verify(url: url, identity: wrongDigest)
        }
        let wrongSize = DailyActivitySourceIdentity(byteSize: 4095, sha256: digest)
        t.expectThrows("a wrong size must fail") {
            try DailyActivityIntegrity.verify(url: url, identity: wrongSize)
        }
        // A key with no reviewed identity is rejected before any byte is read. The real file does
        // not match any reviewed digest, so reaching the read path would fail differently.
        t.expectThrows("an unreviewed source key can never verify") {
            try DailyActivityIntegrity.verify(url: url, sourceKey: sourceKey(.a, .r3, .evening))
        }
        t.expectThrows("a reviewed key rejects these unrelated bytes") {
            try DailyActivityIntegrity.verify(url: url, sourceKey: reviewedEvening)
        }
    }

    run("DailyActivity.freshSourceVersionDetectsChosenFileReplacement") { t in
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bsidemac-activity-replace-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("A_R1_1730.mp4")
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = Data(repeating: 0x11, count: 8192)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try original.write(to: url)
        } catch { t.expect(false, "fixture write failed: \(error)"); return }
        guard let before = try? OfficialAssetProvider.sourceVersion(url) else {
            t.expect(false, "fresh chosen-file stat is captured")
            return
        }
        // Unchanged bytes keep the same media identity, so an install-time re-check cannot reject a
        // file that was never replaced.
        t.expect((try? OfficialAssetProvider.sourceVersion(url))?.hasSameMedia(as: before) == true,
                 "an unchanged chosen file keeps its captured identity")
        // A replaced file at the same path carries a different media identity; a retained
        // PendingDailyEntry version must reject it before installing the authored offset.
        do {
            try FileManager.default.removeItem(at: url)
            try Data(repeating: 0x22, count: 8192).write(to: url)
        } catch { t.expect(false, "replacement write failed: \(error)"); return }
        guard let after = try? OfficialAssetProvider.sourceVersion(url) else {
            t.expect(false, "replacement stat is captured")
            return
        }
        t.expect(!before.hasSameMedia(as: after), "a fresh stat detects the chosen-file replacement")
        // The reviewed digest bound to the original bytes can never verify the replacement.
        let digest = SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined()
        t.expectThrows("replaced bytes cannot pass the reviewed identity") {
            try DailyActivityIntegrity.verify(url: url,
                identity: DailyActivitySourceIdentity(byteSize: Int64(original.count), sha256: digest))
        }
        // The reviewed per-source digest is not this fixture's bytes either, so the source-key
        // path must reject the replacement before any install.
        t.expectThrows("the reviewed source key rejects replaced bytes") {
            try DailyActivityIntegrity.verify(url: url, sourceKey: reviewedEvening)
        }
    }
}
