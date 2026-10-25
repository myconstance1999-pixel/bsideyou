// Real FSEvents and bookmark regression using synthetic files only, before NSApplication.
import Foundation
import Darwin
import BSideCore
import BSidePlatform

private func dailyDirectoryPhysicalPath(_ url: URL) -> String? {
    guard let resolved = realpath(url.path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
}

func runDailyDirectoryRegression(expect: (Bool, String) -> Void) {
    guard Thread.isMainThread else {
        expect(false, "daily directory regression requires the main run loop")
        return
    }
    let began = ProcessInfo.processInfo.systemUptime
    let deadline = began + 19.5
    func wait(_ limit: TimeInterval = 3, until condition: () -> Bool) -> Bool {
        let end = min(deadline, ProcessInfo.processInfo.systemUptime + limit)
        while !condition(), ProcessInfo.processInfo.systemUptime < end {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }
    func settle(_ interval: TimeInterval) {
        _ = wait(interval, until: { false })
    }

    let manager = FileManager.default
    let base = manager.temporaryDirectory.appendingPathComponent("bsidemac-daily-directory-\(UUID().uuidString)")
    let selected = base.appendingPathComponent("selected")
    let moved = base.appendingPathComponent("moved")
    let movedAgain = base.appendingPathComponent("moved-again")
    var bindings: [DailyDirectoryMonitor.Binding] = []
    var failures: [DailyAssetIssue] = []
    var conflicts = 0
    var allOnMain = true
    let monitor = DailyDirectoryMonitor(onRefresh: {
        allOnMain = allOnMain && Thread.isMainThread
        bindings.append($0)
    }, onFailure: {
        allOnMain = allOnMain && Thread.isMainThread
        failures.append($0)
    }, onIdentityConflict: {
        allOnMain = allOnMain && Thread.isMainThread
        conflicts += 1
    })
    defer {
        monitor.stop()
        try? manager.removeItem(at: base)
        expect(ProcessInfo.processInfo.systemUptime - began < 20,
               "daily directory regression completes within twenty seconds")
    }

    do {
        try manager.createDirectory(at: selected, withIntermediateDirectories: true)
        let content = selected.appendingPathComponent("synthetic.txt")
        try Data("before".utf8).write(to: content)
        let original = try DirectoryAccessLease.fromSelectedURL(selected)
        let originalIdentity = original.lease.identitySnapshot(provenance: .explicitSelection)
            .map { StoredDirectoryIdentity.snapshot($0) }
        monitor.start(path: selected.path, bookmark: original.persistentData,
                      identity: originalIdentity, access: original.lease)
        expect(bindings.isEmpty && failures.isEmpty, "starting daily observation does not itself request a refresh")
        // Drain setup hints before attributing the next native batch to the measured writes.
        settle(1.1)
        let beforeWrites = bindings.count
        for value in ["one", "two", "three"] { try Data(value.utf8).write(to: content) }
        guard wait(until: { bindings.count > beforeWrites }) else {
            expect(false, "ordinary synthetic writes deliver a native daily directory refresh")
            return
        }
        settle(0.9)
        expect(bindings.count == beforeWrites + 1 && failures.isEmpty,
               "one burst of ordinary file writes is merged into one daily refresh")
        expect(bindings.last?.access.representsSameDirectory(as: original.lease) == true,
               "ordinary refresh retains the selected directory identity")

        let beforeMove = bindings.count
        try manager.moveItem(at: selected, to: moved)
        guard wait(until: {
            bindings.dropFirst(beforeMove).contains {
                dailyDirectoryPhysicalPath($0.access.url) == dailyDirectoryPhysicalPath(moved)
                    && $0.access.representsSameDirectory(as: original.lease) == true
            }
        }) else {
            expect(false, "a native root rename follows the actual original directory")
            return
        }
        let protected = bindings.last!
        expect(protected.bookmark != original.persistentData,
               "a renamed daily root publishes renewed persistent bookmark data")
        let restored = try DirectoryAccessLease.resolvePersistent(protected.bookmark)
        expect(restored.lease.representsSameDirectory(as: original.lease) == true
               && dailyDirectoryPhysicalPath(restored.lease.url) == dailyDirectoryPhysicalPath(moved),
               "the renewed daily bookmark resolves to the moved original directory")
        settle(0.8)

        let beforeConflict = bindings.count
        let failuresBeforeConflict = failures.count
        let conflictsBeforeConflict = conflicts
        try manager.moveItem(at: moved, to: movedAgain)
        try manager.createDirectory(at: moved, withIntermediateDirectories: true)
        try Data("replacement".utf8).write(to: moved.appendingPathComponent("synthetic.txt"))
        monitor.refresh() // Run before queued native events: Foundation can resolve the old path's replacement.
        monitor.refresh()
        expect(bindings.count == beforeConflict && failures.count == failuresBeforeConflict
               && conflicts == conflictsBeforeConflict + 2,
               "manual retries reject a replacement inode at the bookmarked path as an identity conflict")
        settle(0.9)
        expect(bindings.count == beforeConflict,
               "queued native hints cannot automatically adopt a conflicting replacement directory")

        // Returning the *original inode* to its bookmarked path distinguishes preserving the
        // old data from silently renewing it for the rejected replacement. This is not reselection.
        try manager.removeItem(at: moved)
        try manager.moveItem(at: movedAgain, to: moved)
        monitor.refresh()
        expect(bindings.count == beforeConflict + 1
               && bindings.last?.access.representsSameDirectory(as: original.lease) == true
               && bindings.last?.bookmark == protected.bookmark,
               "a conflict preserves the original bookmark for a later retry of the same directory")

        // Cold-restart stand-in: a NEW monitor that only has the saved bookmark + persisted
        // anchor (no session lease) must reject a replacement and resume the same original.
        let savedBookmark = bindings.last!.bookmark
        let savedAnchor = bindings.last!.identity
        var restartedBindings: [DailyDirectoryMonitor.Binding] = []
        var restartedConflicts = 0
        let restarted = DailyDirectoryMonitor(onRefresh: { restartedBindings.append($0) },
            onFailure: { _ in }, onIdentityConflict: { restartedConflicts += 1 })
        defer { restarted.stop() }
        restarted.start(path: moved.path, bookmark: savedBookmark, identity: savedAnchor, access: nil)
        try manager.moveItem(at: moved, to: movedAgain)
        try manager.createDirectory(at: moved, withIntermediateDirectories: true)
        restarted.refresh()
        expect(restartedConflicts == 1 && restartedBindings.isEmpty,
               "a persisted anchor rejects a replacement without any session lease")
        try manager.removeItem(at: moved)
        try manager.moveItem(at: movedAgain, to: moved)
        restarted.refresh()
        expect(restartedBindings.count == 1 && restartedBindings.last?.identity == savedAnchor
               && restartedBindings.last?.access.representsSameDirectory(as: original.lease) == true,
               "a persisted anchor resumes the genuine moved original unchanged")

        try manager.moveItem(at: moved, to: movedAgain)
        try manager.createDirectory(at: moved, withIntermediateDirectories: true)
        monitor.refresh()
        let replacement = try DirectoryAccessLease.fromSelectedURL(moved)
        let replacementIdentity = replacement.lease.identitySnapshot(provenance: .explicitSelection)
            .map { StoredDirectoryIdentity.snapshot($0) }
        let beforeReselection = bindings.count
        monitor.start(path: moved.path, bookmark: replacement.persistentData,
                      identity: replacementIdentity, access: replacement.lease)
        expect(bindings.count == beforeReselection, "explicit new selection starts observation without publishing a refresh")
        monitor.refresh()
        expect(bindings.count == beforeReselection + 1
               && bindings.last?.access.representsSameDirectory(as: replacement.lease) == true
               && bindings.last?.access.representsSameDirectory(as: original.lease) == false,
               "explicit new start can establish the newly selected directory identity after conflict")

        try Data("queued before stop".utf8).write(to: moved.appendingPathComponent("late.txt"))
        monitor.stop()
        let stoppedUpdates = bindings.count + failures.count
        monitor.refresh()
        try Data("after stop".utf8).write(to: moved.appendingPathComponent("later.txt"))
        settle(1.1)
        expect(bindings.count + failures.count == stoppedUpdates,
               "stop suppresses pending, old-stream, subsequent native, and manual refresh callbacks")
        expect(allOnMain, "daily directory callbacks stay on the main thread")

        // run_tests.sh supplies this mktemp directory. Never touch the user's default support
        // or accept an arbitrary override as permission to modify its logs.
        guard let override = ProcessInfo.processInfo.environment["BSIDEMAC_SUPPORT_DIR"],
              !override.isEmpty else {
            expect(false, "daily log regression requires run_tests.sh's isolated support directory")
            return
        }
        let support = URL(fileURLWithPath: override, isDirectory: true)
        guard support.lastPathComponent.hasPrefix("bsidemac-control-regression."),
              let supportPath = dailyDirectoryPhysicalPath(support),
              let temporaryPath = dailyDirectoryPhysicalPath(manager.temporaryDirectory),
              (supportPath as NSString).deletingLastPathComponent == temporaryPath else {
            expect(false, "daily log regression refuses a support directory outside the test mktemp location")
            return
        }
        let logURLs = [AppPaths.controlLogURL, AppPaths.agentLogURL].flatMap {
            [$0, URL(fileURLWithPath: $0.path + ".1")]
        }
        var savedLogs: [(URL, Data?)] = []
        var expectedLogData: [URL: Data] = [:]
        let ordinaryLog = support.appendingPathComponent("daily-synthetic-\(UUID().uuidString).log")
        var logRefreshes = 0
        var logFailures = 0
        var logWriteError: Error?
        var echoLogs = false
        func appendLogs() throws {
            for url in logURLs {
                let addition = Data("daily directory synthetic regression\n".utf8)
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: addition)
                expectedLogData[url, default: Data()].append(addition)
            }
        }
        let logMonitor = DailyDirectoryMonitor(onRefresh: { _ in
            logRefreshes += 1
            if echoLogs {
                do { try appendLogs() } catch { logWriteError = error }
            }
        }, onFailure: { _ in logFailures += 1 }, onIdentityConflict: { logFailures += 1 })
        defer {
            logMonitor.stop()
            try? manager.removeItem(at: ordinaryLog)
            // Preserve existing evidence; only undo our additions if no other writer intervened.
            for (url, originalData) in savedLogs {
                guard let expected = expectedLogData[url],
                      (try? Data(contentsOf: url)) == expected else { continue }
                if let originalData { try? originalData.write(to: url) }
                else { try? manager.removeItem(at: url) }
            }
        }
        for url in logURLs {
            let originalData = manager.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
            savedLogs.append((url, originalData))
            expectedLogData[url] = originalData ?? Data()
            if originalData == nil { try Data().write(to: url) }
        }
        try Data("ordinary log before".utf8).write(to: ordinaryLog)
        let logSelection = try DirectoryAccessLease.fromSelectedURL(support)
        let logIdentity = logSelection.lease.identitySnapshot(provenance: .explicitSelection)
            .map { StoredDirectoryIdentity.snapshot($0) }
        logMonitor.start(path: support.path, bookmark: logSelection.persistentData,
                         identity: logIdentity, access: logSelection.lease)
        settle(1.1)
        let beforeLogs = logRefreshes
        try appendLogs()
        settle(1.3)
        expect(logRefreshes == beforeLogs && logFailures == 0,
               "exact control.log, agent.log, and both .1 paths do not trigger daily refresh")

        // Other .log files remain events. Echoing all four actual log paths from onRefresh
        // recreates the feedback cycle without an Agent, preferences, or a media process.
        echoLogs = true
        try Data("ordinary log after".utf8).write(to: ordinaryLog)
        guard wait(until: { logRefreshes > beforeLogs }) else {
            expect(false, "an unrelated .log path still requests a native daily refresh")
            return
        }
        settle(1.3)
        expect(logRefreshes == beforeLogs + 1 && logFailures == 0 && logWriteError == nil,
               "refresh-generated application logs do not self-excite another refresh")
    } catch {
        expect(false, "daily directory regression fixture or operation failed: \(error)")
    }
}
