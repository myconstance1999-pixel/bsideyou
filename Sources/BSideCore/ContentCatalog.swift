// BSideCore — ContentCatalog: logical view of the official media set. No paths, no IO.

/// Logical catalog of playable content. Built by BSidePlatform.OfficialAssetProvider at agent
/// startup and rebuilt on `reloadAssets`; never persisted with media.
public struct ContentCatalog: Codable, Hashable {
    public var loops: [ContentKey: ContentID]
    /// Discovered filename directions, not reviewed joins between exact source versions.
    /// An entry carries no outfit or visual-boundary evidence; do not use it as an activity graph.
    public var transitions: [TransitionKey: ContentID]
    public var ambientTracks: [AmbientTrack]
    /// Files present in the asset tree that did not match any known pattern.
    public var unknownFiles: [String]
    /// Human-readable identifier of the source layout (e.g. official build 0.0.9.627 / buildid).
    public var sourceLabel: String

    public init(
        loops: [ContentKey: ContentID] = [:],
        transitions: [TransitionKey: ContentID] = [:],
        ambientTracks: [AmbientTrack] = [],
        unknownFiles: [String] = [],
        sourceLabel: String = ""
    ) {
        self.loops = loops
        self.transitions = transitions
        self.ambientTracks = ambientTracks
        self.unknownFiles = unknownFiles
        self.sourceLabel = sourceLabel
    }

    public func loop(for key: ContentKey) -> ContentID? { loops[key] }

    public func transition(scene: Scene, from: TimeOfDay, to: TimeOfDay) -> ContentID? {
        transitions[TransitionKey(scene: scene, from: from, to: to)]
    }

    /// An explicit missing ID stays unavailable; it never substitutes another soundtrack.
    public func ambientTrack(selection: DailySoundtrackSelection) -> AmbientTrack? {
        switch selection {
        case .silent: return nil
        case .track(let id): return ambientTracks.first { $0.id == id }
        case .legacyDefault:
            return ambientTracks.min { ($0.index, $0.id.rawValue) < ($1.index, $1.id.rawValue) }
        }
    }

    public var isEmpty: Bool { loops.isEmpty && ambientTracks.isEmpty }
}
