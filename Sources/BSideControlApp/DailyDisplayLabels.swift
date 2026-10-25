// BSideControlApp — shared presentation names for the two daily dimensions.
//
// `Scene`/`Outfit` raw values (A/B/C, R1/R2/R3) stay the identity used by Core, IPC,
// persistence and media path resolution. The computed properties below are user-facing
// display text only: they never encode, migrate or compare persisted state, so every
// existing raw key and apply path is unchanged.

import BSideCore

extension Scene {
    /// Whole-source material-group name. Raw "A"/"B"/"C" remains the persisted identity.
    var dailyDisplayName: String {
        switch self {
        case .a: return "素材组一"
        case .b: return "素材组二"
        case .c: return "素材组三"
        }
    }
}

extension Outfit {
    /// Full daily-version name. Raw "R1"/"R2"/"R3" remains the persisted identity.
    var dailyDisplayName: String {
        switch self {
        case .r1: return "日常版本一"
        case .r2: return "日常版本二"
        case .r3: return "日常版本三"
        }
    }
}

extension ContentKey {
    /// One compact readable identity shared by the Control Center status line, the
    /// combination menu, the recommendation target and the resource-error message.
    /// Test/troubleshooting only: ADR-024 removed numbered material ids from ordinary surfaces.
    var dailyDisplayLabel: String {
        "\(scene.dailyDisplayName) · \(outfit.dailyDisplayName) · \(time.controlCenterLabel)"
    }

    /// The ordinary product word for this combination: its daypart. Safe for primary surfaces
    /// because it names what the user can see, not an internal material id.
    var daypartLabel: String { time.controlCenterLabel }
}
