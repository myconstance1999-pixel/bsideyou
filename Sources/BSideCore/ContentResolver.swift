// BSideCore — ContentResolver: DesiredState + clock + catalog → concrete content to play.
// Pure; the agent owns nothing here.

/// What the agent should be playing right now.
public struct ContentSelection: Codable, Hashable {
    /// Target loop. `nil` means the catalog has no loop for this key (agent reports degraded).
    public var loop: ContentID?
    /// Directional clip discovered for playback BEFORE `loop`. This does not certify that
    /// the exact source units or their action/visual join have been reviewed.
    public var transition: ContentID?
    public var ambient: ContentID?
    public var targetKey: ContentKey

    public init(loop: ContentID?, transition: ContentID? = nil, ambient: ContentID?, targetKey: ContentKey) {
        self.loop = loop
        self.transition = transition
        self.ambient = ambient
        self.targetKey = targetKey
    }

    public var isPlayable: Bool { loop != nil }
}

public enum ContentResolver {
    /// - Parameters:
    ///   - currentKey: key of the clip currently on screen (nil at startup — never a transition).
    public static func resolve(
        currentKey: ContentKey?,
        desired: DesiredState,
        catalog: ContentCatalog,
        minuteOfDay: Int
    ) -> ContentSelection {
        let time: TimeOfDay
        switch desired.timeMode {
        case .auto: time = TimeOfDay.autoBucket(minuteOfDay: minuteOfDay)
        case .fixed(let t): time = t
        }
        let target = ContentKey(scene: desired.scene, outfit: desired.outfit, time: time)

        var transition: ContentID?
        if let current = currentKey, current != target {
            // The existing direction index is used only within one scene and outfit. It is
            // filename-based discovery, not an allowlist of reviewed source-to-source joins.
            // There is no reviewed outfit-change transition, including a simultaneous clock
            // change. A time-only asset must not silently stand in for that missing semantic.
            if current.scene == target.scene, current.outfit == target.outfit, current.time != target.time {
                transition = catalog.transition(scene: current.scene, from: current.time, to: target.time)
            }
        }

        let ambient = catalog.ambientTrack(selection: desired.dailySoundtrack)?.id

        return ContentSelection(
            loop: catalog.loop(for: target),
            transition: transition,
            ambient: ambient,
            targetKey: target
        )
    }
}
