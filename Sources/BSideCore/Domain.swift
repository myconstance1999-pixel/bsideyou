// BSideCore — Domain primitives (pure Swift; no Apple frameworks allowed here, see scripts/check_architecture.sh)

/// Logical identifier for a playable clip. Opaque to Core: it never sees file paths.
/// The string form is a stable URI produced by BSidePlatform.OfficialAssetProvider, e.g.
/// "loop://A/R1/1200", "transition://A/1200->1730", "ambient://7".
public struct ContentID: Hashable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    public var description: String { rawValue }
}

/// Which room/scene the wallpaper shows (official files: A_R1_1200.mp4 …).
public enum Scene: String, Codable, CaseIterable, Hashable {
    case a = "A"
    case b = "B"
    case c = "C"
}

/// Which outfit 林离 wears (official files: _R1/_R2/_R3).
public enum Outfit: String, Codable, CaseIterable, Hashable {
    case r1 = "R1"
    case r2 = "R2"
    case r3 = "R3"
}

/// Time-of-day state. Raw values are the official filename labels (12:00 / 17:30 / 20:00).
/// Official auto-switching boundaries are UNKNOWN; `autoBucket` documents our own defaults.
public enum TimeOfDay: String, Codable, CaseIterable, Hashable {
    case noon = "1200"
    case evening = "1730"
    case night = "2000"

    /// Our automatic daylight boundary; deliberately distinct from the asset label "1200".
    public static let automaticDayStartMinute = 6 * 60

    /// Minute of day that this state represents (noon = 12*60, evening = 17*60+30, night = 20*60).
    public var minuteOfDay: Int {
        switch self {
        case .noon: return 12 * 60
        case .evening: return 17 * 60 + 30
        case .night: return 20 * 60
        }
    }

    /// Our own deterministic bucketing for `TimeMode.auto` (official boundaries UNKNOWN):
    /// [00:00,06:00) night · [06:00,17:30) noon · [17:30,20:00) evening · [20:00,24:00) night.
    public static func autoBucket(minuteOfDay: Int) -> TimeOfDay {
        let m = ((minuteOfDay % 1440) + 1440) % 1440
        if m < automaticDayStartMinute { return .night }
        if m < evening.minuteOfDay { return .noon }
        if m < night.minuteOfDay { return .evening }
        return .night
    }
}

/// A concrete loop target: scene + outfit + time.
public struct ContentKey: Hashable, Codable, CustomStringConvertible {
    public var scene: Scene
    public var outfit: Outfit
    public var time: TimeOfDay

    public init(scene: Scene, outfit: Outfit, time: TimeOfDay) {
        self.scene = scene
        self.outfit = outfit
        self.time = time
    }

    public var description: String { "\(scene.rawValue).\(outfit.rawValue).\(time.rawValue)" }
}

/// Directional transition key. Official transition files exist only for time changes within
/// the same scene (e.g. A_Transition_1200_1730.mp4); outfit-only and cross-scene changes
/// have NO transition asset (confirmed by catalog scan) and resolve to a direct switch.
public struct TransitionKey: Hashable, Codable {
    public var scene: Scene
    public var from: TimeOfDay
    public var to: TimeOfDay

    public init(scene: Scene, from: TimeOfDay, to: TimeOfDay) {
        self.scene = scene
        self.from = from
        self.to = to
    }
}

/// An independently selectable ambient audio track; no pairing with a video is inferred.
public struct AmbientTrack: Hashable, Codable {
    public var id: ContentID
    public var index: Int
    public var label: String

    public init(id: ContentID, index: Int, label: String) {
        self.id = id
        self.index = index
        self.label = label
    }
}
