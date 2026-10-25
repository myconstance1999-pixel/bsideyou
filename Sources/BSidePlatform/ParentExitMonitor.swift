// BSidePlatform — event-driven supervisor-loss guard. No periodic orphan polling.

import Darwin
import Foundation

/// Main-thread confined. Watches the captured parent for exit and closes the startup race with
/// getppid checks before and after arming the kernel source. IPC EOF remains an independent path.
/// The callback is delivered at most once per start/cancel lifecycle; it may run during start().
public final class ParentExitMonitor {
    private let parentPID: pid_t
    private let currentParentPID: () -> pid_t
    private let onParentExit: () -> Void
    private var source: DispatchSourceProcess?
    private var started = false
    private var didReportExit = false
    private var generation: UInt64 = 0

    /// The query dependency allows launch-race tests without orphaning the test runner. Production
    /// uses the real parent captured at construction and getppid for both startup checks.
    public init(
        parentPID: pid_t = getppid(),
        currentParentPID: @escaping () -> pid_t = { getppid() },
        onParentExit: @escaping () -> Void
    ) {
        self.parentPID = parentPID
        self.currentParentPID = currentParentPID
        self.onParentExit = onParentExit
    }

    public func start() {
        guard !started else { return }
        started = true
        didReportExit = false
        generation &+= 1
        let activeGeneration = generation
        guard parentPID > 1, currentParentPID() == parentPID else {
            reportExit(generation: activeGeneration)
            return
        }

        let processSource = DispatchSource.makeProcessSource(identifier: parentPID, eventMask: .exit, queue: .main)
        source = processSource
        processSource.setEventHandler { [weak self] in
            self?.reportExit(generation: activeGeneration)
        }
        processSource.setRegistrationHandler { [weak self] in
            guard let self, self.started, self.generation == activeGeneration,
                  self.currentParentPID() != self.parentPID else { return }
            self.reportExit(generation: activeGeneration)
        }
        processSource.resume()

        // If reparenting won the race with registration, no future exit of the captured parent is
        // required to release the agent. Registration is asynchronous, so the handler above repeats
        // the check after the source is actually armed. A later .exit cannot report a second time.
        if currentParentPID() != parentPID { reportExit(generation: activeGeneration) }
    }

    public func cancel() {
        generation &+= 1
        started = false
        source?.cancel()
        source = nil
    }

    deinit { source?.cancel() }

    private func reportExit(generation activeGeneration: UInt64) {
        guard started, generation == activeGeneration, !didReportExit else { return }
        didReportExit = true
        source?.cancel()
        source = nil
        onParentExit()
    }
}
