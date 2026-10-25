// Clock and source changes may wait for the current complete daily unit. This is a container
// boundary, not a claim that arbitrary clips share a visually seamless/safe join.
// The Agent re-resolves at the actual end; this reducer never retains a playback plan.
public struct DailySwitchLifecycle: Equatable {
    public enum Effect: Equatable { case none, waitForEnd, install }

    public private(set) var pendingTarget: ContentKey?
    private var wasPaused = false

    public init() {}

    public mutating func update(current: ContentKey?, selection: ContentSelection,
                                automatic: Bool, paused: Bool, hasVideo: Bool,
                                reload: Bool = false, sourceChanged: Bool = false,
                                atUnitEnd: Bool = false) -> Effect {
        let resuming = wasPaused && !paused
        wasPaused = paused
        pendingTarget = nil
        guard !paused else { return .none }
        let target = selection.targetKey
        let differentKey = current.map { $0 != target } ?? false
        let automaticTimeChange = automatic && current.map {
            $0.scene == target.scene && $0.outfit == target.outfit && $0.time != target.time
        } == true
        let explicitChange = differentKey && !automaticTimeChange
        let canWait = hasVideo && !reload && !atUnitEnd

        // The Agent owns source-version differences across pause and resource release. A live
        // unit finishes even if its replacement vanished; EOF hands that absence to the owner.
        // Explicit choices and resume to a different key keep their existing immediate behavior.
        if sourceChanged, canWait, !explicitChange, !(resuming && differentKey) {
            pendingTarget = selection.isPlayable && automaticTimeChange ? target : nil
            return .waitForEnd
        }

        guard selection.isPlayable else { return .install } // owner reports/stops a missing target
        guard current != target || reload || sourceChanged || !hasVideo else { return .none }

        // Without a source difference, preserve the existing automatic lighting-change rule.
        if automaticTimeChange, !resuming, canWait {
            pendingTarget = target
            return .waitForEnd
        }
        return .install
    }

    public mutating func reset() {
        pendingTarget = nil
        wasPaused = false
    }
}
