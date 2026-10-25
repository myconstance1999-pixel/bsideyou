// Real controller/async filesystem regression. The only files are short self-owned Data;
// the bundled manifest supplies semantic names, never official media or a media decoder.
import Foundation
import Darwin
import BSideCore
import BSidePlatform

private func performanceDirectoryRealPath(_ url: URL) -> String? {
    url.withUnsafeFileSystemRepresentation { path in
        guard let path, let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

private func performanceDirectoryMatches(_ candidate: URL?, _ expected: URL) -> Bool {
    guard let candidate, let actual = performanceDirectoryRealPath(candidate),
          let wanted = performanceDirectoryRealPath(expected) else { return false }
    return actual == wanted
}

private func performanceDirectoryIdentity(_ url: URL?) -> String {
    guard let url else { return "nil" }
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    let device = (attributes?[.systemNumber] as? NSNumber)?.stringValue ?? "unavailable"
    let inode = (attributes?[.systemFileNumber] as? NSNumber)?.stringValue ?? "unavailable"
    return "\(url.path) [physical=\(performanceDirectoryRealPath(url) ?? "unavailable"), device=\(device), inode=\(inode)]"
}

private struct PerformanceDirectoryReadyEvidence {
    let root: URL
    let bookmark: Data
    let identity: StoredDirectoryIdentity?
    let adoptAfterValidation: Bool
    let result: PerformanceCandidateRefresh
    let monitoring: Bool
}

private final class PerformanceDirectoryEvidence {
    var ready: [PerformanceDirectoryReadyEvidence] = []
    var failures: [(root: URL, message: String)] = []
    var checking: [URL] = []
    var allOnMain = true
    var updateCount: Int { ready.count + failures.count + checking.count }

    func record(_ update: PerformanceDirectoryController.Update) {
        allOnMain = allOnMain && Thread.isMainThread
        switch update {
        case .checking(let root):
            checking.append(root)
        case .ready(let binding, let result, let monitoring):
            ready.append(PerformanceDirectoryReadyEvidence(root: binding.access.url,
                bookmark: binding.bookmark, identity: binding.identity,
                adoptAfterValidation: binding.adoptAfterValidation,
                result: result, monitoring: monitoring))
        case .failed(let root, let message):
            failures.append((root, message))
        }
    }
}

private func performanceDirectoryFixtureLibrary(bytes: Data) throws -> PerformanceLibrary {
    let bundled = try PerformanceLibrary.bundled()
    guard var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(bundled.manifest))
            as? [String: Any],
          let tracks = json["tracks"] as? [[String: Any]],
          var track = tracks.first,
          var variants = track["variants"] as? [[String: Any]], variants.count >= 2 else {
        throw PerformanceAssetError.invalidManifest("directory regression requires one known variant set")
    }
    let digest = PerformanceSemanticCatalogJoin.sha256Hex(of: bytes)
    for index in variants.indices {
        variants[index]["byteSize"] = bytes.count
        variants[index]["sha256"] = digest
        variants[index].removeValue(forKey: "mediaByteSize")
        variants[index].removeValue(forKey: "mediaSHA256")
    }
    track["variants"] = variants
    json["tracks"] = [track]
    return try PerformanceLibrary(data: JSONSerialization.data(withJSONObject: json))
}

func runPerformanceDirectoryRegression(expect: (Bool, String) -> Void) {
    guard Thread.isMainThread else {
        expect(false, "performance directory regression requires the main run loop")
        return
    }
    let deadline = ProcessInfo.processInfo.systemUptime + 18
    func wait(_ limit: TimeInterval = 4, until condition: () -> Bool) -> Bool {
        let end = min(deadline, ProcessInfo.processInfo.systemUptime + limit)
        while !condition(), ProcessInfo.processInfo.systemUptime < end {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        return condition()
    }
    func settle(_ interval: TimeInterval) {
        let end = min(deadline, ProcessInfo.processInfo.systemUptime + interval)
        while ProcessInfo.processInfo.systemUptime < end {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
    }

    do {
        let bytes = Data("BSideMac synthetic directory candidates".utf8)
        let library = try performanceDirectoryFixtureLibrary(bytes: bytes)
        let variants = library.manifest.tracks[0].variants
        let first = variants[0]
        let second = variants[1]
        let allIDs = Set(variants.map(\.id))
        let manager = FileManager.default
        let parent = manager.temporaryDirectory
            .appendingPathComponent("bsidemac-performance-directory-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: parent) }
        let original = parent.appendingPathComponent("selected", isDirectory: true)
        let moved = parent.appendingPathComponent("moved", isDirectory: true)
        let movedAgain = parent.appendingPathComponent("moved-again", isDirectory: true)
        try manager.createDirectory(at: original, withIntermediateDirectories: true)
        func write(_ variant: PerformanceManifest.Variant, root: URL) throws {
            let file = root.appendingPathComponent(variant.relativePath)
            try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: file)
        }
        try write(first, root: original)
        let unrelatedLog = original.appendingPathComponent("user-debug.log")
        try Data("existing unrelated log\n".utf8).write(to: unrelatedLog)
        let evidence = PerformanceDirectoryEvidence()
        let controller = PerformanceDirectoryController(library: { library }, onUpdate: evidence.record)
        defer { controller.reset() }
        func hasCandidates(root: URL, available: Set<String>, after readyCount: Int) -> Bool {
            guard evidence.ready.count > readyCount, let latest = evidence.ready.last else { return false }
            return performanceDirectoryMatches(latest.root, root)
                && performanceDirectoryMatches(latest.result.snapshot.root, root)
                && Set(latest.result.snapshot.unavailable.keys) == allIDs.subtracting(available)
        }
        func candidateDiagnostic(root: URL, available: Set<String>, after readyCount: Int) -> String {
            var details = [
                "expectedRoot=\(performanceDirectoryIdentity(root))",
                "expectedUnavailable=\(allIDs.subtracting(available).sorted())",
                "readyCount=\(evidence.ready.count) previous=\(readyCount)",
                "currentBinding=\(performanceDirectoryIdentity(controller.binding?.access.url))",
                "lastChecking=\(performanceDirectoryIdentity(evidence.checking.last))",
            ]
            if let latest = evidence.ready.last {
                details += [
                    "readyRoot=\(performanceDirectoryIdentity(latest.root))",
                    "snapshotRoot=\(performanceDirectoryIdentity(latest.result.snapshot.root))",
                    "unavailable=\(latest.result.snapshot.unavailable.keys.sorted())",
                    "checked=\(latest.result.checkedVariantIDs.sorted())",
                    "fullScan=\(latest.result.fullScan) monitoring=\(latest.monitoring)",
                ]
            }
            if let failure = evidence.failures.last {
                details += ["lastFailureRoot=\(performanceDirectoryIdentity(failure.root))",
                            "lastFailureMessage=\(failure.message)"]
            }
            return details.joined(separator: "; ")
        }

        controller.select(original)
        guard wait(until: { hasCandidates(root: original, available: [first.id], after: 0) }) else {
            expect(false, "selected synthetic root publishes its exact available and missing variants")
            return
        }
        let initial = evidence.ready.last!
        expect(initial.monitoring, "selected root starts actual native directory monitoring")
        expect(initial.result.fullScan && initial.result.checkedVariantIDs == allIDs,
               "initial binding discovers the complete known variant set")
        expect(performanceDirectoryMatches(controller.binding?.access.url, original) && !initial.bookmark.isEmpty,
               "ready evidence and the transferable binding belong to the selected directory")
        let beforeManual = evidence.ready.count
        controller.refresh()
        guard wait(until: {
            hasCandidates(root: original, available: [first.id], after: beforeManual)
                && evidence.ready.last?.result.fullScan == true
        }) else {
            expect(false, "manual refresh completes through the existing authorized binding")
            return
        }
        expect(evidence.failures.isEmpty && performanceDirectoryMatches(controller.binding?.access.url, original),
               "manual refresh preserves the root and publishes useful candidate evidence")

        // Drain setup/coalesced events before establishing a quiet-state baseline. Modify an
        // existing regular file: new directories and unknown tombstones legitimately need a
        // conservative full scan. A log-only write must not start a UI/save/log feedback loop.
        settle(1.2)
        let beforeUnrelatedWrite = evidence.updateCount
        try Data("existing unrelated log\nanother ordinary log entry\n".utf8).write(to: unrelatedLog)
        settle(1.2)
        expect(evidence.updateCount == beforeUnrelatedWrite,
               "an unrelated existing log-file change publishes no checking, ready, or failed UI update")

        let beforeAdd = evidence.ready.count
        try write(second, root: original)
        guard wait(until: { hasCandidates(root: original, available: [first.id, second.id], after: beforeAdd) }) else {
            expect(false, "native file creation refreshes candidates without a manual refresh")
            return
        }
        expect(evidence.ready.last!.result.checkedVariantIDs.contains(second.id),
               "creation actually rechecks the new known candidate")
        let beforeDelete = evidence.ready.count
        try manager.removeItem(at: original.appendingPathComponent(first.relativePath))
        guard wait(until: { hasCandidates(root: original, available: [second.id], after: beforeDelete) }) else {
            expect(false, "native file deletion removes only the missing candidate from availability")
            return
        }
        let deleted = original.appendingPathComponent(first.relativePath)
        // The file is absent, so compare its exact name and existing parent identity. URL
        // spelling alone differs legitimately between native /var and /private/var paths.
        expect(evidence.ready.last!.result.snapshot.candidateLocations[first.id]?.contains(where: {
            $0.lastPathComponent == deleted.lastPathComponent
                && performanceDirectoryMatches($0.deletingLastPathComponent(), deleted.deletingLastPathComponent())
        }) == true,
            "a deleted candidate keeps its possible location for later recovery")

        let beforeMove = evidence.ready.count
        let beforeMoveIdentity = performanceDirectoryIdentity(original)
        try manager.moveItem(at: original, to: moved)
        guard wait(until: { hasCandidates(root: moved, available: [second.id], after: beforeMove) }) else {
            expect(false, "ordinary native root movement follows the directory through its bookmark; "
                + "beforeMove=\(beforeMoveIdentity); "
                + candidateDiagnostic(root: moved, available: [second.id], after: beforeMove))
            return
        }
        expect(evidence.ready.last!.monitoring,
               "the moved authorized directory receives a replacement native monitor")

        // Foundation can resolve a stale bookmark to a new directory occupying its old
        // spelling. A known runtime identity mismatch must fail without renewing that grant.
        guard let protectedBinding = controller.binding else {
            expect(false, "ordinary movement retains a binding for runtime identity protection")
            return
        }
        let beforeCollisionReady = evidence.ready.count
        let beforeCollisionFailures = evidence.failures.count
        let protectedIdentity = performanceDirectoryIdentity(moved)
        try manager.moveItem(at: moved, to: movedAgain)
        try manager.createDirectory(at: moved, withIntermediateDirectories: true)
        try write(first, root: moved) // replacement deliberately has the other known candidate
        // No run-loop turn has occurred since the rename. The cached ready state cannot
        // authorize a new transfer while native event delivery/debouncing is still pending.
        do {
            _ = try controller.transfer()
            expect(false, "transfer rejects a replaced root before native notifications are delivered")
        } catch {
            expect(true, "transfer rejects a replaced root before native notifications are delivered")
        }
        expect(controller.binding?.access === protectedBinding.access
               && controller.binding?.bookmark == protectedBinding.bookmark,
               "an immediate transfer rejection preserves the original binding and bookmark")
        guard wait(until: { evidence.failures.count > beforeCollisionFailures }) else {
            expect(false, "a replacement occupying the selected directory's old path requires explicit recovery; "
                + "protected=\(protectedIdentity); replacement=\(performanceDirectoryIdentity(moved)); "
                + candidateDiagnostic(root: movedAgain, available: [second.id], after: beforeCollisionReady))
            return
        }
        settle(0.8) // queued hints must remain failed while the user has not reselected
        expect(evidence.ready.count == beforeCollisionReady,
               "a root identity conflict must not publish replacement-directory candidates as ready")
        expect(controller.binding?.access === protectedBinding.access
               && controller.binding?.bookmark == protectedBinding.bookmark,
               "a root identity conflict preserves the original binding and bookmark without renewal")
        expect(evidence.failures.last?.message.contains("重新选择") == true,
               "a root identity conflict offers explicit directory reselection")

        let beforeReselection = evidence.ready.count
        controller.select(movedAgain)
        guard wait(until: { hasCandidates(root: movedAgain, available: [second.id], after: beforeReselection) }) else {
            expect(false, "explicitly selecting the original moved directory recovers its actual candidates; "
                + candidateDiagnostic(root: movedAgain, available: [second.id], after: beforeReselection))
            return
        }
        let reselectedBookmark = evidence.ready.last!.bookmark
        let reselectedIdentity = evidence.ready.last!.identity
        controller.reset()
        let beforeRestore = evidence.ready.count
        controller.restore(path: movedAgain.path, bookmark: reselectedBookmark, identity: reselectedIdentity)
        guard wait(until: { hasCandidates(root: movedAgain, available: [second.id], after: beforeRestore) }) else {
            expect(false, "the bookmark from explicit reselection cold-restores the correct directory; "
                + candidateDiagnostic(root: movedAgain, available: [second.id], after: beforeRestore))
            return
        }
        let restoredAnchor = evidence.ready.last!.identity
        let beforeRestoreRefresh = evidence.ready.count
        controller.refresh()
        guard wait(until: { evidence.ready.count > beforeRestoreRefresh }) else {
            expect(false, "an ordinary refresh of a restored root publishes a ready binding")
            return
        }
        expect(evidence.ready.last!.identity == restoredAnchor && restoredAnchor != nil,
               "two refreshes keep the same finalized identity anchor and timestamp, never re-adopting")
        expect(!evidence.ready.last!.adoptAfterValidation,
               "a finalized binding never re-proposes legacy adoption on refresh")
        let transferred = try controller.transfer()
        expect(performanceDirectoryMatches(URL(fileURLWithPath: transferred.root), movedAgain) && !transferred.bookmark.isEmpty,
               "playback transfer uses the restored root rather than the stale display path")

        let beforeInvalidReady = evidence.ready.count
        let beforeInvalidFailures = evidence.failures.count
        controller.restore(path: moved.path, bookmark: Data("invalid directory bookmark".utf8), identity: nil)
        expect(evidence.failures.count == beforeInvalidFailures + 1 && controller.binding == nil,
               "an invalid stored bookmark fails instead of selecting a readable legacy path")
        controller.refresh()
        controller.refresh()
        expect(evidence.ready.count == beforeInvalidReady
               && evidence.failures.count == beforeInvalidFailures + 3 && controller.binding == nil,
               "repeated manual retries cannot turn an invalid bookmark into a path binding")
        expect(evidence.failures.suffix(3).allSatisfy { performanceDirectoryMatches($0.root, moved) && !$0.message.isEmpty },
               "authorization failures identify the attempted location and provide recovery feedback")
        do {
            _ = try controller.transfer()
            expect(false, "a failed binding must not transfer an obsolete directory grant")
        } catch {
            expect(true, "a failed binding cannot transfer an obsolete directory grant")
        }

        // Cross-restart: a persisted anchor that disagrees with the resolved directory must
        // be rejected before scanning, keep the saved bookmark, and require reselection.
        let decoy = parent.appendingPathComponent("decoy", isDirectory: true)
        try manager.createDirectory(at: decoy, withIntermediateDirectories: true)
        let decoyAnchor = try DirectoryAccessLease.fromSelectedURL(decoy).lease
            .identitySnapshot(provenance: .explicitSelection).map { StoredDirectoryIdentity.snapshot($0) }
        let beforeAnchorReady = evidence.ready.count
        let beforeAnchorFailures = evidence.failures.count
        controller.restore(path: movedAgain.path, bookmark: reselectedBookmark, identity: decoyAnchor)
        expect(evidence.ready.count == beforeAnchorReady
               && evidence.failures.count == beforeAnchorFailures + 1 && controller.binding == nil,
               "a persisted anchor conflict rejects the resolved directory before scanning")
        expect(evidence.failures.last?.message.contains("重新选择") == true,
               "a persisted anchor conflict offers explicit directory reselection")
        do {
            _ = try controller.transfer()
            expect(false, "a persisted anchor conflict must not transfer a grant")
        } catch {
            expect(true, "a persisted anchor conflict cannot transfer a grant")
        }

        // Path-only legacy restore (no bookmark, no anchor) adopts once after the first
        // successful scan and then reuses that exact record on every later refresh.
        let beforeLegacy = evidence.ready.count
        controller.restore(path: movedAgain.path, bookmark: nil, identity: nil)
        guard wait(until: { hasCandidates(root: movedAgain, available: [second.id], after: beforeLegacy) }) else {
            expect(false, "a path-only legacy restore scans the readable directory; "
                + candidateDiagnostic(root: movedAgain, available: [second.id], after: beforeLegacy))
            return
        }
        let adoptedAnchor = evidence.ready.last!.identity
        expect(adoptedAnchor != nil && !evidence.ready.last!.adoptAfterValidation,
               "the first successful legacy scan finalizes exactly one adopted record")
        let beforeLegacyRefresh = evidence.ready.count
        controller.refresh()
        guard wait(until: { evidence.ready.count > beforeLegacyRefresh }) else {
            expect(false, "an ordinary refresh of an adopted legacy root publishes a ready binding")
            return
        }
        expect(evidence.ready.last!.identity == adoptedAnchor && !evidence.ready.last!.adoptAfterValidation,
               "a later refresh cannot recompute the adopted legacy anchor or its timestamp")

        // select schedules a real scan and arms the native stream before returning. Reset
        // before yielding makes its eventual cancellation completion belong to an old token.
        controller.select(movedAgain)
        try write(first, root: movedAgain) // also queue a real filesystem change before reset
        controller.reset()
        let resetCount = evidence.updateCount
        controller.refresh() // no attempted binding remains
        try manager.removeItem(at: movedAgain.appendingPathComponent(second.relativePath))
        settle(1.2)
        expect(controller.binding == nil && evidence.updateCount == resetCount,
               "reset suppresses scheduled scan completion and pending or later native events")
        expect(evidence.allOnMain, "all directory results are delivered on the main thread")
        expect(ProcessInfo.processInfo.systemUptime <= deadline,
               "directory controller regression completes within its bounded wall-clock budget")
    } catch {
        expect(false, "performance directory regression fixture or operation failed: \(error)")
    }
}
