// A transport-safe reason for a daily resource load failure. Filesystem errors and paths stay
// in Platform/local logs; ControlApp chooses wording and recovery actions from this value.
public enum DailyAssetIssue: String, Codable, Hashable {
    case missingLocation
    case accessDenied
    case authorizationRequired
    case unsupportedLayout
    case ambiguousLayouts
    case noDailyContent
    case readFailed
}
