// BSideCore — DesiredState, profiles, app rules. This is what ControlApp owns and persists;
// it is replayed verbatim to the agent on every (re)connect (ADR-007).

/// How the time-of-day state is chosen. Encoded as a flat string for IPC friendliness:
/// "auto" or "fixed:<TimeOfDay.rawValue>" (e.g. "fixed:1730").
public enum TimeMode: Hashable {
    /// Follow Beijing time using TimeOfDay.autoBucket (our documented boundaries).
    case auto
    /// User pinned a specific state.
    case fixed(TimeOfDay)
}

extension TimeMode: Codable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .auto: try container.encode("auto")
        case .fixed(let time): try container.encode("fixed:\(time.rawValue)")
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if raw == "auto" {
            self = .auto
        } else if raw.hasPrefix("fixed:") {
            self = .fixed(TimeOfDay(rawValue: String(raw.dropFirst("fixed:".count))) ?? .noon)
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath,
                                      debugDescription: "unknown TimeMode: \(raw)"))
        }
    }
}

/// Per-app playback rule evaluated against the foreground application.
public struct AppRule: Codable, Hashable {
    public enum Action: String, Codable {
        /// Pause visuals and mute audio while this app is foreground (e.g. movie players).
        case pauseAll
        /// Keep visuals, mute both audio channels.
        case muteAudio
        /// Keep visuals, scale both audio channels by `duckFactor`.
        case duckAudio
    }

    public var bundleID: String
    public var action: Action
    /// Volume multiplier for `.duckAudio` (0...1). Ignored by other actions.
    public var duckFactor: Double

    public init(bundleID: String, action: Action, duckFactor: Double = 0.3) {
        self.bundleID = bundleID
        self.action = action
        self.duckFactor = duckFactor
    }
}

/// A playback profile: premade factors applied by PlaybackPolicy (ADR-005).
public struct Profile: Codable, Hashable {
    public var id: String
    public var name: String
    public var musicFactor: Double
    public var ambientFactor: Double
    public var visualPaused: Bool
    public var appRules: [AppRule]

    public init(
        id: String, name: String, musicFactor: Double, ambientFactor: Double,
        visualPaused: Bool = false, appRules: [AppRule] = []
    ) {
        self.id = id
        self.name = name
        self.musicFactor = Self.clamp(musicFactor)
        self.ambientFactor = Self.clamp(ambientFactor)
        self.visualPaused = visualPaused
        self.appRules = appRules
    }

    public static let normal = Profile(id: "normal", name: "Normal", musicFactor: 1, ambientFactor: 1)
    public static let quiet = Profile(id: "quiet", name: "Quiet", musicFactor: 0.3, ambientFactor: 0.3)
    public static let silent = Profile(id: "silent", name: "Silent", musicFactor: 0, ambientFactor: 0)
    public static let coding = Profile(id: "coding", name: "Coding", musicFactor: 0.15, ambientFactor: 0.15)
    /// Movie-style: visuals paused, audio muted.
    public static let movie = Profile(id: "movie", name: "Movie", musicFactor: 0, ambientFactor: 0, visualPaused: true)
    /// Neutral factors; used when the user sets volumes directly (honest profile label, prompt rule #13).
    public static let custom = Profile(id: "custom", name: "自定义", musicFactor: 1, ambientFactor: 1)
    public static let builtIn: [Profile] = [.normal, .quiet, .silent, .coding, .movie]

    public static func builtIn(id: String) -> Profile? { builtIn.first { $0.id == id } }

    static func clamp(_ v: Double) -> Double { min(max(v, 0), 1) }
}

/// Independent soundtrack intent. Missing legacy preferences are pinned after catalog admission.
public enum DailySoundtrackSelection: Codable, Hashable {
    case legacyDefault
    case silent
    case track(ContentID)
}

/// "What the user wants 林离 to be." Persisted by ControlApp; the agent never is its sole holder.
public struct DesiredState: Codable, Hashable {
    public var scene: Scene
    public var outfit: Outfit
    public var timeMode: TimeMode
    public var masterVolume: Double
    public var musicVolume: Double
    public var ambientVolume: Double
    public var musicMuted: Bool
    public var ambientMuted: Bool
    public var paused: Bool
    /// Explicit daily-picture pause; independent of song/session and global pause.
    public var dailyVisualPaused: Bool
    /// Explicit soundtrack pause; retains its current item independently of the picture.
    public var dailyMusicPaused: Bool
    public var dailySoundtrack: DailySoundtrackSelection
    public var profile: Profile
    /// Preference: pause visuals while a fullscreen app is frontmost (default true).
    public var pauseVisualOnFullscreen: Bool
    /// Preference: mute audio while a fullscreen app is frontmost (default true).
    public var muteAudioOnFullscreen: Bool
    /// true = desktop-level wallpaper host; false = floating preview window (ADR-006).
    public var desktopMode: Bool

    public init(
        scene: Scene = .a,
        outfit: Outfit = .r1,
        timeMode: TimeMode = .auto,
        masterVolume: Double = 0.8,
        musicVolume: Double = 0.7,
        ambientVolume: Double = 0.5,
        musicMuted: Bool = false,
        ambientMuted: Bool = false,
        paused: Bool = false,
        dailyVisualPaused: Bool = false,
        dailyMusicPaused: Bool = false,
        dailySoundtrack: DailySoundtrackSelection = .silent,
        profile: Profile = .normal,
        pauseVisualOnFullscreen: Bool = true,
        muteAudioOnFullscreen: Bool = true,
        desktopMode: Bool = true
    ) {
        self.scene = scene
        self.outfit = outfit
        self.timeMode = timeMode
        self.masterVolume = Self.clampVolume(masterVolume)
        self.musicVolume = Self.clampVolume(musicVolume)
        self.ambientVolume = Self.clampVolume(ambientVolume)
        self.musicMuted = musicMuted
        self.ambientMuted = ambientMuted
        self.paused = paused
        self.dailyVisualPaused = dailyVisualPaused
        self.dailyMusicPaused = dailyMusicPaused
        self.dailySoundtrack = dailySoundtrack
        self.profile = profile
        self.pauseVisualOnFullscreen = pauseVisualOnFullscreen
        self.muteAudioOnFullscreen = muteAudioOnFullscreen
        self.desktopMode = desktopMode
    }

    private enum CodingKeys: String, CodingKey {
        case scene, outfit, timeMode, masterVolume, musicVolume, ambientVolume, musicMuted, ambientMuted
        case paused, dailyVisualPaused, dailyMusicPaused, dailySoundtrack, profile, pauseVisualOnFullscreen, muteAudioOnFullscreen, desktopMode
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        scene = try values.decode(Scene.self, forKey: .scene)
        outfit = try values.decode(Outfit.self, forKey: .outfit)
        timeMode = try values.decode(TimeMode.self, forKey: .timeMode)
        masterVolume = try values.decode(Double.self, forKey: .masterVolume)
        musicVolume = try values.decode(Double.self, forKey: .musicVolume)
        ambientVolume = try values.decode(Double.self, forKey: .ambientVolume)
        musicMuted = try values.decode(Bool.self, forKey: .musicMuted)
        ambientMuted = try values.decode(Bool.self, forKey: .ambientMuted)
        paused = try values.decode(Bool.self, forKey: .paused)
        dailyVisualPaused = try values.decodeIfPresent(Bool.self, forKey: .dailyVisualPaused) ?? false
        dailyMusicPaused = try values.decodeIfPresent(Bool.self, forKey: .dailyMusicPaused) ?? false
        dailySoundtrack = try values.decodeIfPresent(DailySoundtrackSelection.self, forKey: .dailySoundtrack) ?? .legacyDefault
        profile = try values.decode(Profile.self, forKey: .profile)
        pauseVisualOnFullscreen = try values.decode(Bool.self, forKey: .pauseVisualOnFullscreen)
        muteAudioOnFullscreen = try values.decode(Bool.self, forKey: .muteAudioOnFullscreen)
        desktopMode = try values.decode(Bool.self, forKey: .desktopMode)
    }

    public static func clampVolume(_ v: Double) -> Double { min(max(v, 0), 1) }

    /// Sanitized copy (volumes clamped) — used after decoding persisted/user input.
    public func sanitized() -> DesiredState {
        var copy = self
        copy.masterVolume = Self.clampVolume(masterVolume)
        copy.musicVolume = Self.clampVolume(musicVolume)
        copy.ambientVolume = Self.clampVolume(ambientVolume)
        return copy
    }
}
