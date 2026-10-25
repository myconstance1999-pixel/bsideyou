// BSideCore — RuntimeContext + effective playback state. Pure value types.

/// Thermal state mirrored from ProcessInfo so Core stays framework-free.
public enum ThermalLevel: String, Codable {
    case nominal
    case fair
    case serious
    case critical
}

/// Everything the PlaybackPolicy needs to know about "right now", gathered by monitors.
/// Monitors produce this; they never act on players (ADR-005).
public struct RuntimeContext: Codable, Hashable {
    public var screenAwake: Bool
    public var systemAwake: Bool
    public var screenLocked: Bool
    /// Whether this user's console session is active; activity does not imply an unlocked screen.
    public var sessionActive: Bool
    /// Actual Agent-owned home surface visibility, never a persisted preference.
    public var homeCompanionVisible: Bool
    public var desktopVisible: Bool
    public var fullscreenAppActive: Bool
    public var lowPowerMode: Bool
    public var thermal: ThermalLevel
    /// Bundle identifier of the frontmost regular application, if known.
    public var foregroundAppBundleID: String?

    public init(
        screenAwake: Bool = true,
        systemAwake: Bool = true,
        screenLocked: Bool = false,
        sessionActive: Bool = true,
        desktopVisible: Bool = true,
        homeCompanionVisible: Bool = false,
        fullscreenAppActive: Bool = false,
        lowPowerMode: Bool = false,
        thermal: ThermalLevel = .nominal,
        foregroundAppBundleID: String? = nil
    ) {
        self.screenAwake = screenAwake
        self.systemAwake = systemAwake
        self.screenLocked = screenLocked
        self.sessionActive = sessionActive
        self.desktopVisible = desktopVisible
        self.homeCompanionVisible = homeCompanionVisible
        self.fullscreenAppActive = fullscreenAppActive
        self.lowPowerMode = lowPowerMode
        self.thermal = thermal
        self.foregroundAppBundleID = foregroundAppBundleID
    }
}

public enum VisualPolicy: String, Codable {
    case full
    case paused
}

/// The final computed playback state. Audio values are already master-applied, factor- and
/// mute-resolved, clamped to 0...1 — the agent applies them verbatim.
public struct EffectivePlaybackState: Codable, Hashable {
    public var visual: VisualPolicy
    public var musicVolume: Double
    public var ambientVolume: Double
    /// Performance clock intent, independent of daily visuals in listen mode and of mute/volume.
    public var performancePaused: Bool
    /// Retain the ambient item without advancing it. Safety/mute/source removal still release it.
    public var ambientPaused: Bool
    /// Human-readable reasons for every restriction that fired (diagnostics + tests).
    public var reasons: [String]

    public init(
        visual: VisualPolicy, musicVolume: Double, ambientVolume: Double,
        performancePaused: Bool = false, ambientPaused: Bool = false, reasons: [String] = []
    ) {
        self.visual = visual
        self.musicVolume = musicVolume
        self.ambientVolume = ambientVolume
        self.performancePaused = performancePaused
        self.ambientPaused = ambientPaused
        self.reasons = reasons
    }
}
