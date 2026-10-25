// BSideCore — PowerState: pure reducer for the system power/lock notifications the monitors
// observe (ADR-005). It owns the mapping from a raw notification kind to the context fields that
// PlaybackPolicy consumes, plus the one extra action a wake implies: reasserting the desktop host.
// SystemMonitors only observes NSWorkspace / DistributedNotificationCenter and applies the results.

/// The power/lock notification kinds SystemMonitors observes.
public enum PowerEvent: Equatable {
    case willSleep
    case didWake
    case screensDidSleep
    case screensDidWake
    case screenLocked
    case screenUnlocked
    case sessionDidResignActive
    case sessionDidBecomeActive
}

/// Pure power-state reducer. `apply` returns true when the event should also trigger a desktop
/// host reassert (system or screen wake) so the shell can wire the dedicated wake path.
public struct PowerState: Equatable {
    public private(set) var systemAwake = true
    public private(set) var screenAwake = true
    public private(set) var screenLocked = false
    public private(set) var sessionActive = true

    public init() {}

    /// A running monitor establishes that the process can execute again, but says nothing about
    /// user presence. Refresh known screen/session facts without treating session activity as unlock.
    public mutating func beginMonitoring(screenAwake: Bool?, sessionActive: Bool?) {
        systemAwake = true
        reconcileEnvironment(screenAwake: screenAwake, sessionActive: sessionActive)
    }

    /// Unknown samples preserve the latest event or sample. Lock and system sleep have separate
    /// evidence and cannot be cleared by a display or console-session query.
    public mutating func reconcileEnvironment(screenAwake: Bool?, sessionActive: Bool?) {
        if let screenAwake { self.screenAwake = screenAwake }
        if let sessionActive { self.sessionActive = sessionActive }
    }

    /// Fold one power/lock event into the context. Returns true iff the event is a wake that
    /// should reassert the desktop host (WindowServer can detach desktop-level windows during
    /// wake; the policy reconcile happens separately via the context change).
    @discardableResult
    public mutating func apply(_ event: PowerEvent) -> Bool {
        switch event {
        case .willSleep:
            systemAwake = false
            return false
        case .didWake:
            systemAwake = true
            return true
        case .screensDidSleep:
            screenAwake = false
            return false
        case .screensDidWake:
            screenAwake = true
            return true
        case .screenLocked:
            screenLocked = true
            return false
        case .screenUnlocked:
            screenLocked = false
            return false
        case .sessionDidResignActive:
            sessionActive = false
            return false
        case .sessionDidBecomeActive:
            sessionActive = true
            return false
        }
    }
}
