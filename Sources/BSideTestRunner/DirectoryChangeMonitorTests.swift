import AppKit
import Darwin
import Foundation
// `@_spi(Testing)` is the test-only seam for injecting the native registration queue; the
// production `DirectoryChangeMonitor` API does not expose it. All public platform API remains
// visible through this import.
@_spi(Testing) import BSidePlatform

private final class WeakDirectoryChangeMonitor {
    weak var value: DirectoryChangeMonitor?
    init(_ value: DirectoryChangeMonitor?) { self.value = value }
}

private func directoryChangeWait(timeout: TimeInterval = 5, until condition: () -> Bool) -> Bool {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while !condition(), Date() < deadline {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
    }
    return condition()
}

private func directoryChangeFixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("bsidemac-directory-events-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    // Use one physical root before mutations. Foundation's convenience /var spelling can
    // change after a child is deleted, whereas FSEvents consistently reports /private/var.
    guard let physicalPath = realpath(root.path, nil) else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    defer { free(physicalPath) }
    return URL(fileURLWithPath: String(cString: physicalPath), isDirectory: true)
}

/// A real `DirectoryAccessLease` over a synthetic temporary root that does not require the
/// `com.apple.security.files.bookmarks.app-scope` entitlement, so registration-lifecycle checks
/// run both in the host gate and in a sandboxed DSH session. Only app-scoped persistence is
/// skipped; the monitor sees the same real URL, identity and lifetime contract.
private func directoryChangeLease(_ root: URL) throws -> DirectoryAccessLease {
    let data = try root.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    return try DirectoryAccessLease.resolveTransfer(data)
}

func runDirectoryChangeMonitorTests() {
    run("DirectoryChangeMonitor.nativeRecursiveAddDeleteAndStop") { t in
        do {
            let root = try directoryChangeFixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let child = root.appendingPathComponent("nested", isDirectory: true)
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
            let access = try directoryChangeLease(root)
            var changes: [DirectoryChange] = []
            var allOnMain = true
            var nativeActive = false
            var monitor: DirectoryChangeMonitor? = DirectoryChangeMonitor(
                root: root, access: access, workspaceCenter: NotificationCenter()) {
                    allOnMain = allOnMain && Thread.isMainThread
                    changes.append($0)
                }
            monitor!.onNativeMonitoringChange = { nativeActive = $0 }
            defer { monitor?.stop() }
            t.expect(monitor!.start(), "real FSEvents stream starts with a lease")
            t.expect(monitor!.start(), "repeated start keeps the same active stream")
            // Attach first so this check isolates steady-state delivery; changes made while
            // registration is still pending are covered by the held-registration test below.
            t.expect(directoryChangeWait { nativeActive },
                     "native registration attaches before the first mutation")
            let file = child.appendingPathComponent("marker.txt")
            try Data("synthetic event".utf8).write(to: file)
            t.expect(directoryChangeWait { changes.contains { $0.paths.contains(file.path) } },
                     "native recursive creation reports the actual file")
            changes.removeAll()
            try FileManager.default.removeItem(at: file)
            t.expect(directoryChangeWait { changes.contains { $0.paths.contains(file.path) } },
                     "native deletion reports the actual removed file")
            t.expect(allOnMain, "native callback runs on main")
            t.expect(changes.allSatisfy { $0.volumeAvailable == nil }, "ordinary FS events do not invent volume state")
            try Data().write(to: child.appendingPathComponent("pending-before-stop.txt"))
            monitor!.stop()
            monitor!.stop()
            let stoppedCount = changes.count
            try Data().write(to: child.appendingPathComponent("created-after-stop.txt"))
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 1.2))
            t.expectEqual(changes.count, stoppedCount, "stop suppresses both pending and later native events")
            let releasedMonitor = WeakDirectoryChangeMonitor(monitor)
            monitor = nil
            t.expect(releasedMonitor.value == nil, "native callback context does not retain the owner")
        } catch { t.expect(false, "native directory fixture failed: \(error)") }
    }

    run("DirectoryChangeMonitor.nativeRootRenameRequiresReconciliation") { t in
        do {
            let parent = try directoryChangeFixture()
            defer { try? FileManager.default.removeItem(at: parent) }
            let root = parent.appendingPathComponent("selected", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let access = try directoryChangeLease(root)
            var changes: [DirectoryChange] = []
            var nativeActive = false
            let monitor = DirectoryChangeMonitor(root: root, access: access, workspaceCenter: NotificationCenter()) {
                changes.append($0)
            }
            monitor.onNativeMonitoringChange = { nativeActive = $0 }
            defer { monitor.stop() }
            t.expect(monitor.start(), "root stream starts")
            // Attach first: this check is about the live WatchRoot signal, not the pending gap.
            t.expect(directoryChangeWait { nativeActive }, "root stream attaches before the rename")
            try FileManager.default.moveItem(at: root, to: parent.appendingPathComponent("renamed"))
            t.expect(directoryChangeWait { changes.contains(where: \.rootChanged) },
                     "WatchRoot preserves native root rename notification")
            t.expect(changes.filter(\.rootChanged).allSatisfy(\.requiresFullScan),
                     "root change always requests complete reconciliation")
        } catch { t.expect(false, "root rename fixture failed: \(error)") }
    }

    run("DirectoryChangeMonitor.offlineVolumeNotificationsAreComponentFiltered") { t in
        do {
            let parent = try directoryChangeFixture()
            defer { try? FileManager.default.removeItem(at: parent) }
            // These are notification payloads, not actual mounts or newly authorized roots.
            let volume = parent.appendingPathComponent("offline-volume", isDirectory: true)
            let renamed = parent.appendingPathComponent("renamed-volume", isDirectory: true)
            let root = volume.appendingPathComponent("resources", isDirectory: true)
            let center = NotificationCenter()
            var changes: [DirectoryChange] = []
            let monitor = DirectoryChangeMonitor(root: root, access: nil, workspaceCenter: center) { changes.append($0) }
            defer { monitor.stop() }
            t.expect(!monitor.start(), "without a lease only workspace recovery is installed")
            t.expect(!monitor.start(), "repeated offline start does not add observers")
            center.post(name: NSWorkspace.didMountNotification, object: nil,
                        userInfo: [NSWorkspace.volumeURLUserInfoKey: parent.appendingPathComponent("offline-volume-other")])
            center.post(name: NSWorkspace.didMountNotification, object: nil)
            t.expect(changes.isEmpty, "sibling-prefix and missing payloads are ignored")
            center.post(name: NSWorkspace.didMountNotification, object: nil,
                        userInfo: [NSWorkspace.volumeURLUserInfoKey: volume])
            center.post(name: NSWorkspace.didUnmountNotification, object: nil,
                        userInfo: [NSWorkspace.volumeURLUserInfoKey: volume])
            center.post(name: NSWorkspace.didRenameVolumeNotification, object: nil,
                        userInfo: [NSWorkspace.volumeURLUserInfoKey: renamed, NSWorkspace.oldVolumeURLUserInfoKey: volume])
            center.post(name: NSWorkspace.didUnmountNotification, object: nil,
                        userInfo: [NSWorkspace.volumeURLUserInfoKey: renamed])
            t.expectEqual(changes.map(\.volumeAvailable), [true, false, true, false],
                          "only the related volume delivers availability, including its renamed mount path")
            t.expect(changes.allSatisfy(\.requiresFullScan), "volume changes request owner reconciliation")
            t.expectEqual(changes.filter(\.rootChanged).count, 1, "volume rename retains root-path-change information")
            monitor.stop()
            let stoppedCount = changes.count
            center.post(name: NSWorkspace.didMountNotification, object: nil,
                        userInfo: [NSWorkspace.volumeURLUserInfoKey: renamed])
            t.expectEqual(changes.count, stoppedCount, "stop removes private workspace subscriptions")
        } catch { t.expect(false, "offline workspace fixture failed: \(error)") }
    }

    run("DirectoryChangeMonitor.authorizedVolumeRejectsOtherFoldersOnSameDisk") { t in
        do {
            let root = try directoryChangeFixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let access = try directoryChangeLease(root)
            let volume = try root.resourceValues(forKeys: [.volumeURLKey]).volume!
            let center = NotificationCenter()
            var changes: [DirectoryChange] = []
            let monitor = DirectoryChangeMonitor(root: root, access: access, workspaceCenter: center) { changes.append($0) }
            defer { monitor.stop() }
            t.expect(monitor.start(), "authorized monitor starts")
            center.post(name: NSWorkspace.didMountNotification, object: nil,
                        userInfo: [NSWorkspace.volumeURLUserInfoKey: root])
            t.expect(changes.isEmpty, "an arbitrary directory sharing the UUID is not a mount root")
            center.post(name: NSWorkspace.didUnmountNotification, object: nil,
                        userInfo: [NSWorkspace.volumeURLUserInfoKey: volume])
            t.expectEqual(changes.map(\.volumeAvailable), [false], "cached selected volume receives unmount notice")
        } catch { t.expect(false, "authorized volume fixture failed: \(error)") }
    }

    run("DirectoryChangeMonitor.slowNativeRegistrationDoesNotBlockCaller") { t in
        do {
            let root = try directoryChangeFixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let access = try directoryChangeLease(root)
            // Hold the monitor's serial registration queue where the blocking native
            // FSEventStreamCreate/watch_all_parents call runs.
            let gate = DispatchSemaphore(value: 0)
            let queue = DispatchQueue(label: "bsidemac.test.slow-registration")
            queue.async { gate.wait() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { gate.signal() }
            var changes: [DirectoryChange] = []
            var activeStates: [Bool] = []
            var monitor: DirectoryChangeMonitor? = DirectoryChangeMonitor(
                root: root, access: access, workspaceCenter: NotificationCenter(),
                registrationQueue: queue) { changes.append($0) }
            monitor!.onNativeMonitoringChange = { activeStates.append($0) }
            let began = ProcessInfo.processInfo.systemUptime
            t.expect(monitor!.start(), "start engages native monitoring with a lease")
            let elapsed = ProcessInfo.processInfo.systemUptime - began
            t.expect(elapsed < 0.5,
                     "start returns without waiting for the blocked native registration (took \(elapsed)s)")
            // Stop while the OS registration is still held: the pending create must never attach.
            monitor!.stop()
            let marker = root.appendingPathComponent("after-stop.txt")
            try Data("synthetic".utf8).write(to: marker)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 1.4))
            t.expect(changes.isEmpty, "a registration cancelled before attach never delivers events")
            t.expect(!activeStates.contains(true), "a cancelled registration never reports itself active")
            let releasedMonitor = WeakDirectoryChangeMonitor(monitor)
            monitor = nil
            t.expect(releasedMonitor.value == nil,
                     "the pending registration block does not retain a stopped monitor")
        } catch { t.expect(false, "slow-registration fixture failed: \(error)") }
    }

    run("DirectoryChangeMonitor.heldRegistrationReplaysChangesFromStartBoundary") { t in
        do {
            let root = try directoryChangeFixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let access = try directoryChangeLease(root)
            let file = root.appendingPathComponent("during-registration.txt")
            // Reference stream that attaches before the mutation. Waiting for it to deliver the
            // change proves the event is already journaled, so the held monitor below faces a
            // real boundary test rather than a race against fseventsd's journaling lag.
            var referenceSawFile = false
            var referenceAttached = false
            let reference = DirectoryChangeMonitor(
                root: root, access: access, workspaceCenter: NotificationCenter()) { change in
                    referenceSawFile = referenceSawFile || change.paths.contains(file.path)
                }
            reference.onNativeMonitoringChange = { referenceAttached = $0 }
            defer { reference.stop() }
            t.expect(reference.start(), "reference observation is engaged")
            t.expect(directoryChangeWait { referenceAttached }, "reference stream attaches")

            // Monitor under test: hold the serial registration queue so no stream can attach yet.
            // This is the production shape where `FSEventStreamCreate` waits on the OS: the owner
            // has already started its scan-equivalent observation, but no stream exists.
            let gate = DispatchSemaphore(value: 0)
            let queue = DispatchQueue(label: "bsidemac.test.held-registration-gap")
            queue.async { gate.wait() }
            var changes: [DirectoryChange] = []
            var active = false
            var monitor: DirectoryChangeMonitor? = DirectoryChangeMonitor(
                root: root, access: access, workspaceCenter: NotificationCenter(),
                registrationQueue: queue) { changes.append($0) }
            monitor!.onNativeMonitoringChange = { active = $0 }
            defer { monitor?.stop() }
            t.expect(monitor!.start(), "observation is engaged while native registration is held")
            t.expect(!active, "no stream can settle as active while registration is held")
            // Mutate BEFORE attach. The `start()`-time event boundary must replay this; a
            // `sinceNow` marker evaluated later, at attach, would place it before the stream and
            // lose it. This mutation deliberately does not wait for `active`.
            try Data("synthetic registration-gap event".utf8).write(to: file)
            t.expect(changes.isEmpty, "the held stream cannot report anything before it attaches")
            t.expect(directoryChangeWait { referenceSawFile },
                     "the change is journaled while registration is still held")
            gate.signal()
            t.expect(directoryChangeWait { changes.contains { $0.paths.contains(file.path) }
                        || changes.contains(where: \.requiresFullScan) },
                     "a change made during the registration gap is reconciled after attach")
            t.expect(directoryChangeWait { active }, "the stream settles as attached")
            let releasedMonitor = WeakDirectoryChangeMonitor(monitor)
            monitor = nil
            t.expect(releasedMonitor.value == nil, "the gap registration does not retain its owner")
        } catch { t.expect(false, "held-registration fixture failed: \(error)") }
    }

    run("DirectoryChangeMonitor.restartAfterStopAttachesOnlyCurrentRegistration") { t in
        do {
            let root = try directoryChangeFixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let access = try directoryChangeLease(root)
            let gate = DispatchSemaphore(value: 0)
            let queue = DispatchQueue(label: "bsidemac.test.replaced-registration")
            queue.async { gate.wait() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.6) { gate.signal() }
            var changes: [DirectoryChange] = []
            var activeStates: [Bool] = []
            let monitor = DirectoryChangeMonitor(
                root: root, access: access, workspaceCenter: NotificationCenter(),
                registrationQueue: queue) { changes.append($0) }
            defer { monitor.stop() }
            monitor.onNativeMonitoringChange = { activeStates.append($0) }
            t.expect(monitor.start(), "first registration is engaged")
            monitor.stop() // cancel generation 1 while its native create is still held
            t.expect(monitor.start(), "second registration is engaged after stop")
            t.expect(directoryChangeWait(timeout: 3) { activeStates.contains(true) },
                     "only the current registration settles as active")
            changes.removeAll()
            let marker = root.appendingPathComponent("marker.txt")
            try Data("synthetic".utf8).write(to: marker)
            t.expect(directoryChangeWait { changes.contains { $0.paths.contains(marker.path) } },
                     "the replacement native stream still reports real events")
            t.expect(activeStates == [true],
                     "the cancelled generation never attaches or reports active")
        } catch { t.expect(false, "replaced-registration fixture failed: \(error)") }
    }

    run("DirectoryChangeMonitor.releaseDuringBlockedRegistrationDeallocatesOnMain") { t in
        do {
            let root = try directoryChangeFixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let access = try directoryChangeLease(root)
            let gate = DispatchSemaphore(value: 0)
            let queue = DispatchQueue(label: "bsidemac.test.release-mid-registration")
            queue.async { gate.wait() }
            var monitor: DirectoryChangeMonitor? = DirectoryChangeMonitor(
                root: root, access: access, workspaceCenter: NotificationCenter(),
                registrationQueue: queue) { _ in }
            t.expect(monitor!.start(), "registration is engaged while the queue is held")
            let releasedMonitor = WeakDirectoryChangeMonitor(monitor)
            // Drop the last external reference while the native create is still queued. An
            // implicit strong owner capture in the registration block would deallocate on
            // `queue` and trip `stop()`'s main-thread precondition (SIGTRAP); a correct
            // capture deallocates here on the main thread.
            monitor = nil
            t.expect(releasedMonitor.value == nil, "a queued registration does not retain its owner")
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { gate.signal() }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.8))
            t.expect(true, "blocked registration settles after the owner is gone without trapping")
        } catch { t.expect(false, "release-mid-registration fixture failed: \(error)") }
    }
}
