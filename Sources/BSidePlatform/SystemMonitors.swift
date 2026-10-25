// BSidePlatform — SystemMonitors: event-driven RuntimeContext production (prompt rule #19).
// Monitors NEVER act on players; they only update context fields and notify (ADR-005).

import AppKit
import CoreGraphics
import BSideCore

/// Platform-only representation of the public Dispatch memory-pressure notifications.
/// Consumers decide what future work to defer or which bounded live resources to release.
public enum SystemMemoryPressure: Equatable {
    case normal
    case warning
    case critical
}

/// Public, independently sampled environment facts. Unknown values do not erase earlier evidence
/// or assert screen lock/unlock; console-session activity and screen lock are different inputs.
public struct SystemEnvironmentSnapshot: Equatable {
    public var screenAwake: Bool?
    public var sessionActive: Bool?

    public init(screenAwake: Bool? = nil, sessionActive: Bool? = nil) {
        self.screenAwake = screenAwake
        self.sessionActive = sessionActive
    }

    public static func capture() -> SystemEnvironmentSnapshot {
        let sessionActive: Bool?
        if let rawDictionary = CGSessionCopyCurrentDictionary() {
            if let dictionary = rawDictionary as? [String: Any] {
                let onConsole = dictionary[kCGSessionOnConsoleKey as String] as? Bool
                let loginDone = dictionary[kCGSessionLoginDoneKey as String] as? Bool
                if onConsole == false || loginDone == false { sessionActive = false }
                else if onConsole == true && loginDone == true { sessionActive = true }
                else { sessionActive = nil }
            } else {
                sessionActive = nil
            }
        } else {
            // The public API defines native nil as no Quartz GUI session / disabled WindowServer.
            // That is unavailable-session evidence, independently of screen lock or unlock.
            sessionActive = false
        }
        return SystemEnvironmentSnapshot(screenAwake: captureScreenAwake(), sessionActive: sessionActive)
    }

    private static func captureScreenAwake() -> Bool? {
        // This is the global screen-sleep input, not a claim about a particular host's display.
        // Main-display IDs and NSScreen.main can differ; preserve work if any online screen is
        // awake. Include online sleeping displays (an active-only list would omit these).
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0, count <= 64 else { return nil }
        var displays = [CGDirectDisplayID](repeating: kCGNullDirectDisplay, count: Int(count))
        var actualCount: UInt32 = 0
        guard CGGetOnlineDisplayList(count, &displays, &actualCount) == .success,
              actualCount > 0, actualCount <= count else { return nil }
        var confirmedOnline = 0
        for display in displays.prefix(Int(actualCount)) where display != kCGNullDirectDisplay {
            // A display can disconnect between list retrieval and its sleep-state query.
            guard CGDisplayIsOnline(display) != 0 else { continue }
            confirmedOnline += 1
            if CGDisplayIsAsleep(display) == 0 { return true }
        }
        return confirmedOnline > 0 ? false : nil
    }
}

/// Main-thread confined. Notification bursts reconcile once with the newest context; wall-clock
/// events also reconcile when the context is unchanged because the Beijing schedule is external.
public final class SystemMonitors {
    /// Called on the main thread after context or wall-clock inputs changed.
    public var onContextChanged: (() -> Void)?
    /// Dedicated wake path: fired on the main thread when a system or screen wake arrives and the
    /// desktop host should re-assert its level/collection behavior (ADR-006). Separate from
    /// `onContextChanged` so the reassert is explicit and independent of policy reconciliation.
    public var onWake: (() -> Void)?
    /// Event-driven, delivered on main; this monitor never traverses caches or touches players.
    public var onMemoryPressureChanged: ((SystemMemoryPressure) -> Void)?

    /// Pure power/lock reducer (Core) — owns the sleep/wake/lock context transitions.
    private var power = PowerState()
    public private(set) var fullscreenAppActive = false
    public private(set) var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    public private(set) var thermal = ThermalLevel.from(ProcessInfo.processInfo.thermalState)
    public private(set) var foregroundAppBundleID: String?
    /// Only the actual presentation host supplies this input. Unknown visibility permits work;
    /// neither the menu bar app's activation nor a failed window query proves occlusion.
    private var desktopVisible: Bool?
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var started = false
    private var generation: UInt64 = 0
    private var pendingContextChange: DispatchWorkItem?
    private var forceContextChange = false
    private var lastDeliveredContext: RuntimeContext?
    private var fullscreenNeedsRefresh = false
    private var foregroundNeedsRefresh = false
    private var environmentNeedsRefresh = false
    /// A resign event is direct evidence. A same-burst configuration query must not overwrite it
    /// with conflicting onConsole=true; explicit activation or a fresh start opens the latch.
    private var sessionInactiveEventLatched = false
    /// Restrictive screen-sleep evidence wins against a same-batch refresh scheduled by an earlier
    /// wake/configuration event. An explicit later screen wake clears it; each flush consumes it.
    private var screenSleepDuringPendingChange = false
    private var spaceSettlement: DispatchWorkItem?
    private var spaceSettlementRevision: UInt64 = 0
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var lastMemoryPressure: SystemMemoryPressure?
    private let fullscreenDetector: (() -> Bool)?
    private let supervisingProcessID: pid_t?
    private let environmentSnapshot: () -> SystemEnvironmentSnapshot
    private let notificationCenter: NotificationCenter
    private let workspaceNotificationCenter: NotificationCenter

    /// The optional detector supports deterministic event/lifecycle verification without asking
    /// WindowServer to change Spaces or open fullscreen windows. Production uses the native query.
    /// Injectable centers isolate synthetic event counts from unrelated desktop notifications.
    public init(
        fullscreenDetector: (() -> Bool)? = nil,
        supervisingProcessID: pid_t? = nil,
        environmentSnapshot: @escaping () -> SystemEnvironmentSnapshot = { SystemEnvironmentSnapshot.capture() },
        notificationCenter: NotificationCenter = .default,
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) {
        self.fullscreenDetector = fullscreenDetector
        self.supervisingProcessID = supervisingProcessID.flatMap { $0 > 1 ? $0 : nil }
        self.environmentSnapshot = environmentSnapshot
        self.notificationCenter = notificationCenter
        self.workspaceNotificationCenter = workspaceNotificationCenter
    }

    public func start() {
        guard !started else { return }
        started = true
        sessionInactiveEventLatched = false
        screenSleepDuringPendingChange = false
        generation &+= 1
        let activeGeneration = generation
        let center = notificationCenter
        let workspaceCenter = workspaceNotificationCenter

        func observeDefault(_ name: Notification.Name, force: Bool = false, _ handler: @escaping () -> Void) {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self, self.started, self.generation == activeGeneration else { return }
                handler()
                self.notifyChanged(force: force)
            })
        }

        func observeWorkspace(_ name: Notification.Name, _ handler: @escaping () -> Void) {
            workspaceObservers.append(workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self, self.started, self.generation == activeGeneration else { return }
                handler()
                self.notifyChanged()
            })
        }

        observeWorkspace(NSWorkspace.willSleepNotification) { [weak self] in
            _ = self?.power.apply(.willSleep)
        }
        observeWorkspace(NSWorkspace.didWakeNotification) { [weak self] in
            guard let self else { return }
            self.environmentNeedsRefresh = true
            if self.power.apply(.didWake) { self.onWake?() }
        }
        observeWorkspace(NSWorkspace.screensDidSleepNotification) { [weak self] in
            self?.screenSleepDuringPendingChange = true
            _ = self?.power.apply(.screensDidSleep)
        }
        observeWorkspace(NSWorkspace.screensDidWakeNotification) { [weak self] in
            guard let self else { return }
            self.screenSleepDuringPendingChange = false
            self.environmentNeedsRefresh = true
            if self.power.apply(.screensDidWake) { self.onWake?() }
        }
        observeWorkspace(NSWorkspace.sessionDidResignActiveNotification) { [weak self] in
            guard let self else { return }
            self.sessionInactiveEventLatched = true
            _ = self.power.apply(.sessionDidResignActive)
        }
        observeWorkspace(NSWorkspace.sessionDidBecomeActiveNotification) { [weak self] in
            guard let self else { return }
            self.sessionInactiveEventLatched = false
            _ = self.power.apply(.sessionDidBecomeActive)
            self.environmentNeedsRefresh = true
            self.foregroundNeedsRefresh = true
            self.fullscreenNeedsRefresh = true
        }
        observeWorkspace(NSWorkspace.didActivateApplicationNotification) { [weak self] in
            self?.foregroundNeedsRefresh = true
            self?.fullscreenNeedsRefresh = true
        }
        observeWorkspace(NSWorkspace.activeSpaceDidChangeNotification) { [weak self] in
            self?.scheduleSpaceSettlement()
        }
        observeDefault(NSApplication.didChangeScreenParametersNotification) { [weak self] in
            self?.fullscreenNeedsRefresh = true
            self?.environmentNeedsRefresh = true
        }
        observeDefault(ProcessInfo.thermalStateDidChangeNotification) { [weak self] in
            self?.thermal = ThermalLevel.from(ProcessInfo.processInfo.thermalState)
        }
        // Reconcile the civil-time schedule immediately after a clock adjustment. The product
        // clock stays in Asia/Shanghai even when the system's display time zone changes.
        observeDefault(.NSSystemClockDidChange, force: true) {}
        observeDefault(.NSSystemTimeZoneDidChange, force: true) {}

        observers.append(center.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: ProcessInfo.processInfo, queue: .main
        ) { [weak self] _ in
            guard let self, self.started, self.generation == activeGeneration else { return }
            self.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
            self.notifyChanged()
        })

        let distributed = DistributedNotificationCenter.default()
        for (name, event) in [
            ("com.apple.screenIsLocked", PowerEvent.screenLocked),
            ("com.apple.screenIsUnlocked", PowerEvent.screenUnlocked),
        ] {
            distributedObservers.append(distributed.addObserver(
                forName: NSNotification.Name(name), object: nil, queue: .main
            ) { [weak self] _ in
                guard let self, self.started, self.generation == activeGeneration else { return }
                _ = self.power.apply(event)
                self.notifyChanged()
            })
        }

        lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        thermal = ThermalLevel.from(ProcessInfo.processInfo.thermalState)
        refreshForegroundApp(from: nil)
        refreshFullscreen()
        // Register observers before sampling so startup cannot miss a subsequent environment
        // event. Resampling on every restart also corrects changes while monitoring was stopped.
        let environment = environmentSnapshot()
        power.beginMonitoring(screenAwake: screenSleepDuringPendingChange ? false : environment.screenAwake,
                              sessionActive: sessionInactiveEventLatched ? false : environment.sessionActive)
        lastDeliveredContext = snapshot()
        startMemoryPressureObservation(generation: activeGeneration)
    }

    public func stop() {
        started = false
        generation &+= 1
        pendingContextChange?.cancel()
        pendingContextChange = nil
        forceContextChange = false
        fullscreenNeedsRefresh = false
        foregroundNeedsRefresh = false
        environmentNeedsRefresh = false
        screenSleepDuringPendingChange = false
        spaceSettlement?.cancel()
        spaceSettlement = nil
        memoryPressureSource?.cancel()
        memoryPressureSource = nil
        lastMemoryPressure = nil
        lastDeliveredContext = nil
        observers.forEach { notificationCenter.removeObserver($0) }
        workspaceObservers.forEach { workspaceNotificationCenter.removeObserver($0) }
        distributedObservers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        observers.removeAll()
        workspaceObservers.removeAll()
        distributedObservers.removeAll()
    }

    deinit { stop() }

    public func snapshot() -> RuntimeContext {
        RuntimeContext(
            screenAwake: power.screenAwake,
            systemAwake: power.systemAwake,
            screenLocked: power.screenLocked,
            sessionActive: power.sessionActive,
            desktopVisible: desktopVisible ?? true,
            fullscreenAppActive: fullscreenAppActive,
            lowPowerMode: lowPowerMode,
            thermal: thermal,
            foregroundAppBundleID: foregroundAppBundleID
        )
    }

    public func setDesktopVisible(_ visible: Bool?) {
        guard desktopVisible != visible else { return }
        desktopVisible = visible
        notifyChanged()
    }

    // MARK: - Internals

    private func notifyChanged(force: Bool = false) {
        guard started else { return }
        forceContextChange = forceContextChange || force
        guard pendingContextChange == nil else { return }
        let activeGeneration = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.started, self.generation == activeGeneration else { return }
            self.pendingContextChange = nil
            if self.foregroundNeedsRefresh { self.refreshForegroundApp(from: nil) }
            if self.fullscreenNeedsRefresh { self.refreshFullscreen() }
            if self.environmentNeedsRefresh {
                let environment = self.environmentSnapshot()
                self.power.reconcileEnvironment(
                    screenAwake: self.screenSleepDuringPendingChange ? false : environment.screenAwake,
                    // A known inactive query is deliberately restrictive even after an active
                    // event; unknown retains that event. This does not assume query timing faults.
                    sessionActive: self.sessionInactiveEventLatched ? false : environment.sessionActive
                )
            }
            self.foregroundNeedsRefresh = false
            self.fullscreenNeedsRefresh = false
            self.environmentNeedsRefresh = false
            self.screenSleepDuringPendingChange = false
            let context = self.snapshot()
            let shouldDeliver = self.forceContextChange || context != self.lastDeliveredContext
            self.forceContextChange = false
            self.lastDeliveredContext = context
            if shouldDeliver { self.onContextChanged?() }
        }
        pendingContextChange = work
        DispatchQueue.main.async(execute: work)
    }

    private func scheduleSpaceSettlement() {
        // WindowServer may settle after the Space event. Keep one bounded follow-up per burst,
        // and invalidate it across stop/restart so an old Space cannot inspect a new session.
        spaceSettlement?.cancel()
        spaceSettlementRevision &+= 1
        let activeRevision = spaceSettlementRevision
        let activeGeneration = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.started, self.generation == activeGeneration,
                  self.spaceSettlementRevision == activeRevision else { return }
            self.spaceSettlement = nil
            self.foregroundNeedsRefresh = true
            self.fullscreenNeedsRefresh = true
            self.notifyChanged()
        }
        spaceSettlement = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func startMemoryPressureObservation(generation activeGeneration: UInt64) {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        memoryPressureSource = source
        source.setEventHandler { [weak self] in
            guard let self, self.started, self.generation == activeGeneration,
                  let events = self.memoryPressureSource?.data else { return }
            let pressure: SystemMemoryPressure
            if events.contains(.critical) { pressure = .critical }
            else if events.contains(.warning) { pressure = .warning }
            else if events.contains(.normal) { pressure = .normal }
            else { return }
            guard pressure != self.lastMemoryPressure else { return }
            self.lastMemoryPressure = pressure
            self.onMemoryPressureChanged?(pressure)
        }
        source.resume()
    }

    private func refreshForegroundApp(from note: Notification?) {
        let app: NSRunningApplication?
        if let note, let activated = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            app = activated
        } else {
            app = NSWorkspace.shared.frontmostApplication
        }
        foregroundAppBundleID = (app?.activationPolicy == .regular) ? app?.bundleIdentifier : nil
    }

    /// Fullscreen heuristic (AuraFlow-derived, simplified for the main display): parse the
    /// on-screen window list into candidate records, then defer to the pure Core classifier
    /// (FullscreenClassifier) so the decision is deterministically tested without a window server.
    private func refreshFullscreen() {
        if let fullscreenDetector {
            fullscreenAppActive = fullscreenDetector()
            return
        }
        guard let screen = NSScreen.main else {
            fullscreenAppActive = false
            return
        }
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            fullscreenAppActive = false
            return
        }

        let detected = detectsFullscreen(windowInfo: list, screenArea: screen.frame.width * screen.frame.height) { pid in
            NSRunningApplication(processIdentifier: pid).map { $0.activationPolicy == .regular }
        }
        if detected != fullscreenAppActive {
            fullscreenAppActive = detected
        }
    }

    /// Shared production metadata path. The Agent and its captured ControlApp supervisor are
    /// one application for this policy; an unrelated regular app still counts as fullscreen.
    /// A nil owner lookup means the process is not a known running application.
    public func detectsFullscreen(
        windowInfo: [[String: Any]], screenArea: Double,
        applicationIsRegular: (pid_t) -> Bool?
    ) -> Bool {
        let currentProcessID = ProcessInfo.processInfo.processIdentifier
        var candidates: [FullscreenCandidate] = []
        for info in windowInfo {
            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1
            let bounds = info[kCGWindowBounds as String] as? [String: NSNumber]
            guard let w = bounds?["Width"]?.doubleValue, let h = bounds?["Height"]?.doubleValue else { continue }
            // Only windows whose owner resolves to a running app are classified; an unknown owner
            // can never count as a fullscreen app (documented heuristic).
            guard let pidValue = (info[kCGWindowOwnerPID as String] as? NSNumber)?.intValue,
                  let regularApp = applicationIsRegular(pid_t(pidValue)) else { continue }
            candidates.append(FullscreenCandidate(
                layer: layer,
                width: w,
                height: h,
                regularApp: regularApp,
                ownProcess: pid_t(pidValue) == currentProcessID || pid_t(pidValue) == supervisingProcessID
            ))
        }

        return FullscreenClassifier.detectsFullscreen(candidates: candidates, screenArea: screenArea)
    }

    static func map(_ state: ProcessInfo.ThermalState) -> ThermalLevel {
        ThermalLevel.from(state)
    }
}

extension ThermalLevel {
    static func from(_ state: ProcessInfo.ThermalState) -> ThermalLevel {
        switch state {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .nominal
        }
    }
}
