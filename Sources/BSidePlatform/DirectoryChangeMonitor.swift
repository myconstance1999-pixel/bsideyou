import AppKit
import CoreServices
import Foundation

/// A change hint, not a directory snapshot. The owner reconciles its current authorized root.
public struct DirectoryChange: Sendable {
    public let paths: [String]
    public let requiresFullScan: Bool
    public let rootChanged: Bool
    public let volumeAvailable: Bool?

    public init(paths: [String], requiresFullScan: Bool, rootChanged: Bool, volumeAvailable: Bool?) {
        self.paths = paths
        self.requiresFullScan = requiresFullScan
        self.rootChanged = rootChanged
        self.volumeAvailable = volumeAvailable
    }
}

/// Owns one native FSEvents registration (create, start, stop, release on a private serial
/// queue) and forwards change hints to the main thread. Bookkeeping stays main-thread confined.
///
/// `FSEventStreamCreate` synchronously opens the watched root and every ancestor
/// (`watch_all_parents` -> `open`), and the OS can hold that open for an unbounded time (the
/// specific cause of that wait is not established here). Doing it on the calling thread therefore
/// freezes the ControlApp launch/quit path, so registration is scheduled on `registrationQueue`
/// and `start()` returns as soon as native monitoring is engaged. No enumeration or media reads
/// occur here.
/// Keep monitoring active before starting a scan so changes during that scan remain visible; the
/// stream's `sinceWhen` is captured when `start()` is requested, so the asynchronous registration
/// cannot create a window in which a change goes unreported.
public final class DirectoryChangeMonitor {
    private final class StreamContext {
        weak var owner: DirectoryChangeMonitor?
        let generation: UInt64
        let access: DirectoryAccessLease
        /// Event id captured when the owner requested monitoring, before the (possibly delayed)
        /// native create. It becomes the stream's `sinceWhen`, preserving the pre-async boundary.
        let eventBoundary: FSEventStreamEventId
        // `cancel()` runs on the main thread while the registration queue may be inside the
        // blocking native create; the flag is the only state shared across the two.
        private let lock = NSLock()
        private var cancelled = false

        init(owner: DirectoryChangeMonitor, generation: UInt64, access: DirectoryAccessLease,
             eventBoundary: FSEventStreamEventId) {
            self.owner = owner
            self.generation = generation
            self.access = access
            self.eventBoundary = eventBoundary
        }

        /// Asked for by `stop()`/a replacement start. The queue checks it before and after the
        /// native start, so a stopped monitor never attaches a stream and never races release.
        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }
    }

    private let root: URL
    // Retain the original authorization for this monitor's lifetime, including stop/restart.
    private let access: DirectoryAccessLease?
    private let workspaceCenter: NotificationCenter
    private let onChange: (DirectoryChange) -> Void
    // Serial queue that owns every native FSEventStream* call for this monitor.
    private let registrationQueue: DispatchQueue
    private var registration: StreamContext?
    private var stream: FSEventStreamRef?
    private var workspaceTokens: [NSObjectProtocol] = []
    private var generation: UInt64 = 0
    private var running = false
    private var volumeURL: URL?
    private var volumeUUID: String?

    /// Invoked on the main thread when an asynchronous native registration settles: `true` once
    /// the stream is attached, `false` when it could not start. Owners use it to keep their
    /// monitoring projection honest without making `start()` wait for the OS.
    public var onNativeMonitoringChange: ((Bool) -> Void)?

    public convenience init(root: URL, access: DirectoryAccessLease?,
                            workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
                            onChange: @escaping (DirectoryChange) -> Void) {
        self.init(root: root, access: access, workspaceCenter: workspaceCenter,
                  registrationQueue: DispatchQueue(label: "local.bsidemac.directory-change-monitor"),
                  onChange: onChange)
    }

    /// Test-only seam, not part of the public API: injects the serial queue that owns native
    /// FSEvents registration so lifecycle checks can hold the blocking create deterministically.
    /// Production callers use the initializer above, which supplies the monitor's own queue.
    @_spi(Testing)
    public init(root: URL, access: DirectoryAccessLease?,
                workspaceCenter: NotificationCenter,
                registrationQueue: DispatchQueue,
                onChange: @escaping (DirectoryChange) -> Void) {
        precondition(Thread.isMainThread)
        // An authorized URL wins over a display/legacy path; never monitor a manufactured parent.
        self.root = access?.url ?? root
        self.access = access
        self.workspaceCenter = workspaceCenter
        self.registrationQueue = registrationQueue
        self.onChange = onChange
        if let access {
            let values = try? access.url.resourceValues(forKeys: [.volumeURLKey, .volumeUUIDStringKey])
            volumeURL = values?.volume
            volumeUUID = values?.volumeUUIDString
        }
    }

    /// Engages native monitoring without waiting for the OS to open the root's ancestors.
    /// Returns whether a native stream is engaged (scheduled or attached). Workspace recovery
    /// remains active when false; a registration that fails later reports through
    /// `onNativeMonitoringChange`.
    @discardableResult
    public func start() -> Bool {
        precondition(Thread.isMainThread)
        if running { return stream != nil || registration != nil }
        running = true
        generation &+= 1
        let currentGeneration = generation
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
                     NSWorkspace.didRenameVolumeNotification] {
            workspaceTokens.append(workspaceCenter.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] notification in
                guard let self, self.running, self.generation == currentGeneration else { return }
                self.receiveVolume(notification)
            })
        }
        guard let access, root.isFileURL else { return false }
        // Boundary capture at request time. `FSEventsGetCurrentEventId()` is a journal query, not
        // an ancestor open, so it does not reintroduce the block that moved registration off-thread.
        let box = StreamContext(owner: self, generation: currentGeneration, access: access,
                                eventBoundary: FSEventsGetCurrentEventId())
        registration = box
        scheduleCreation(box: box)
        return true
    }

    public func stop() {
        precondition(Thread.isMainThread)
        running = false
        generation &+= 1
        for token in workspaceTokens { workspaceCenter.removeObserver(token) }
        workspaceTokens.removeAll()
        if let registration {
            // The queue re-checks this before and after the native start; an in-flight create
            // is discarded there, never attached here.
            self.registration = nil
            registration.cancel()
        }
        if let stream {
            self.stream = nil
            let queue = registrationQueue
            queue.async { DirectoryChangeMonitor.dispose(stream, started: true) }
        }
    }

    deinit { stop() }

    /// Runs the blocking native create/start on the monitor's serial queue, then reports the
    /// settled registration back to the main thread. Nothing here retains the owner strongly,
    /// so a stopped or released monitor deallocates on the main thread while the OS call runs.
    private func scheduleCreation(box: StreamContext) {
        let paths = [root.path] as CFArray
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagUseCFTypes)
        let queue = registrationQueue
        // `[weak self]` is required on this outer block too: without it the escaping block
        // captures the owner strongly and would deallocate it on the registration queue
        // (off-main) when a stop/replace drops the last external reference mid-registration.
        queue.async { [weak self] in
            var context = FSEventStreamContext(
                version: 0, info: Unmanaged.passUnretained(box).toOpaque(),
                retain: { pointer in
                    guard let pointer else { return nil }
                    _ = Unmanaged<StreamContext>.fromOpaque(pointer).retain()
                    return pointer
                },
                release: { pointer in
                    guard let pointer else { return }
                    Unmanaged<StreamContext>.fromOpaque(pointer).release()
                }, copyDescription: nil)
            // `info` is unretained until FSEventStreamCreate invokes context.retain. Keep the
            // Swift owner alive through that call even under optimized ARC lifetime shortening.
            //
            // `sinceWhen` is the boundary captured when `start()` was requested, not the moment
            // this delayed create runs. A fresh `kFSEventStreamEventIdSinceNow` here would place
            // the marker after the owner's scan-equivalent work, silently dropping every change
            // made during the registration gap. Replay is safe for the owners, which coalesce
            // change hints into one reconciliation scan; if the kernel has already discarded that
            // history it flags the stream and `receive` requests a full scan instead.
            let created = withExtendedLifetime(box, { FSEventStreamCreate(kCFAllocatorDefault, { _, info, count, paths, flags, _ in
                guard let info else { return }
                let box = Unmanaged<StreamContext>.fromOpaque(info).takeUnretainedValue()
                let paths = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as! [String]
                // The native flag pointer is only valid for this callback; copy it before the
                // main-thread hop so delivery never touches freed FSEvents memory.
                var copied = [FSEventStreamEventFlags]()
                copied.reserveCapacity(count)
                for index in 0..<count { copied.append(flags[index]) }
                DispatchQueue.main.async {
                    guard let owner = box.owner else { return }
                    owner.receive(paths: paths, flags: copied, count: count, generation: box.generation)
                }
            }, &context, paths, box.eventBoundary, 0.5, flags) })
            guard let created else {
                DispatchQueue.main.async { [weak self] in
                    self?.finishRegistration(box, stream: nil, started: false)
                }
                return
            }
            if box.isCancelled {
                DirectoryChangeMonitor.dispose(created, started: false)
                DispatchQueue.main.async { [weak self] in
                    self?.finishRegistration(box, stream: nil, started: false)
                }
                return
            }
            FSEventStreamSetDispatchQueue(created, queue)
            guard FSEventStreamStart(created) else {
                DirectoryChangeMonitor.dispose(created, started: false)
                DispatchQueue.main.async { [weak self] in
                    self?.finishRegistration(box, stream: nil, started: false)
                }
                return
            }
            // A stop/replace that landed while Start ran must not leave a live stream behind.
            if box.isCancelled {
                DirectoryChangeMonitor.dispose(created, started: true)
                DispatchQueue.main.async { [weak self] in
                    self?.finishRegistration(box, stream: nil, started: false)
                }
                return
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    // The owner was released mid-registration: release the native stream here.
                    queue.async { DirectoryChangeMonitor.dispose(created, started: true) }
                    return
                }
                self.finishRegistration(box, stream: created, started: true)
            }
        }
    }

    /// Main-thread settlement of one scheduled registration. A stream whose registration is no
    /// longer the current one is released instead of attached, so stop/reset cannot attach a
    /// stale stream or race a freed context.
    private func finishRegistration(_ box: StreamContext, stream: FSEventStreamRef?, started: Bool) {
        precondition(Thread.isMainThread)
        guard registration === box else {
            if let stream {
                registrationQueue.async { DirectoryChangeMonitor.dispose(stream, started: started) }
            }
            return
        }
        registration = nil
        if let stream {
            self.stream = stream
            onNativeMonitoringChange?(true)
        } else {
            onNativeMonitoringChange?(false)
        }
    }

    /// Every call runs on `registrationQueue`, which serializes create/start/stop/release.
    private static func dispose(_ stream: FSEventStreamRef, started: Bool) {
        if started { FSEventStreamStop(stream) }
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    private func receive(paths: [String], flags: [FSEventStreamEventFlags],
                         count: Int, generation: UInt64) {
        precondition(Thread.isMainThread)
        guard running, self.generation == generation else { return }
        let fullScanMask = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs
            | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
            | kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged)
        var fullScan = false
        var rootChanged = false
        for index in 0..<count {
            fullScan = fullScan || flags[index] & fullScanMask != 0
            rootChanged = rootChanged || flags[index] & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0
        }
        // Dropped events may report "/"; filtering paths first would discard the full-scan signal.
        guard !paths.isEmpty || fullScan || rootChanged else { return }
        onChange(DirectoryChange(paths: Array(Set(paths)).sorted(), requiresFullScan: fullScan,
                                 rootChanged: rootChanged, volumeAvailable: nil))
    }

    private func receiveVolume(_ notification: Notification) {
        guard let changed = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL,
              changed.isFileURL else { return }
        let old = notification.userInfo?[NSWorkspace.oldVolumeURLUserInfoKey] as? URL
        guard isRelatedVolume(changed) || (old.map(isRelatedVolume) ?? false) else { return }
        let available = notification.name != NSWorkspace.didUnmountNotification
        if available { volumeURL = changed }
        onChange(DirectoryChange(paths: [root.path], requiresFullScan: true,
                                 rootChanged: notification.name == NSWorkspace.didRenameVolumeNotification,
                                 volumeAvailable: available))
    }

    private func isRelatedVolume(_ candidate: URL) -> Bool {
        guard candidate.isFileURL else { return false }
        let path = candidate.standardizedFileURL.path
        // After unmount, metadata may already be unavailable. The last mount URL is still useful.
        if let volumeURL, volumeURL.standardizedFileURL.path == path { return true }
        if let volumeUUID {
            let values = try? candidate.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeURLKey])
            // A notification identifies a mount root, not an arbitrary folder on the same disk.
            return values?.volumeUUIDString == volumeUUID
                && values?.volume?.standardizedFileURL.path == path
        }
        // Offline cold start has no readable volume identity. Component matching only requests
        // that the owner resolve its stored bookmark; this path never starts access or a stream.
        let components = candidate.standardizedFileURL.pathComponents
        return root.standardizedFileURL.pathComponents.starts(with: components)
    }
}
