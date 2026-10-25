// BSideCore — Runtime snapshot the agent reports to ControlApp (diagnostics + UI state).

public enum AgentState: String, Codable {
    case starting
    case ready
    case playing
    case paused
    case degraded
    case error
}

public struct RuntimeSnapshot: Codable, Hashable {
    public var state: AgentState
    public var currentClip: String?
    /// Actual daily transition source (also retained while paused); currentClip remains the
    /// logical target combination. Nil after entering its loop. Not first-frame/advance proof.
    public var transitionClip: String?
    public var musicVolume: Double
    public var ambientVolume: Double
    public var visual: VisualPolicy
    public var reasons: [String]
    public var catalogSummary: String?
    public var lastError: String?
    /// Latest automatic lighting intent waiting for a complete daily unit to finish.
    /// Optional additive IPC v2 field; absence in an older snapshot means no known wait.
    public var pendingDailyTime: TimeOfDay?
    /// Supported daily filenames discovered by the current catalog load, not playback proof.
    /// nil means unknown (including old IPC senders or a failed reload); [] means none found.
    public var dailyContentKeys: [ContentKey]?
    /// Number of ambient files found in the same directory discovery; not playback proof.
    /// nil is unknown, including snapshots predating this optional field.
    public var dailyAmbientTrackCount: Int?
    /// Available soundtrack identities from the current catalog; nil means discovery is unknown.
    public var dailyAmbientTracks: [AmbientTrack]?
    /// Retained soundtrack identity, including explicit pause; not proof of audible playback.
    public var currentDailyAmbientTrackID: ContentID?
    /// A known missing daily target is a resource choice error, independent of player faults.
    public var missingDailyContent: ContentKey?
    /// Directory loading failed; unlike a missing combination, catalog discovery is unknown.
    public var dailyAssetIssue: DailyAssetIssue?
    /// A changed daily source is waiting for the current complete unit, not a new time of day.
    public var pendingDailyRefresh: Bool?
    /// Most recent directory refresh whose success or failure is reflected in this snapshot.
    public var dailyRefreshID: String?

    public init(
        state: AgentState,
        currentClip: String? = nil,
        transitionClip: String? = nil,
        musicVolume: Double = 0,
        ambientVolume: Double = 0,
        visual: VisualPolicy = .full,
        reasons: [String] = [],
        catalogSummary: String? = nil,
        lastError: String? = nil,
        pendingDailyTime: TimeOfDay? = nil,
        dailyContentKeys: [ContentKey]? = nil,
        dailyAmbientTrackCount: Int? = nil,
        dailyAmbientTracks: [AmbientTrack]? = nil,
        currentDailyAmbientTrackID: ContentID? = nil,
        missingDailyContent: ContentKey? = nil,
        dailyAssetIssue: DailyAssetIssue? = nil,
        pendingDailyRefresh: Bool? = nil,
        dailyRefreshID: String? = nil
    ) {
        self.state = state
        self.currentClip = currentClip
        self.transitionClip = transitionClip
        self.musicVolume = musicVolume
        self.ambientVolume = ambientVolume
        self.visual = visual
        self.reasons = reasons
        self.catalogSummary = catalogSummary
        self.lastError = lastError
        self.pendingDailyTime = pendingDailyTime
        self.dailyContentKeys = dailyContentKeys
        self.dailyAmbientTrackCount = dailyAmbientTrackCount
        self.dailyAmbientTracks = dailyAmbientTracks
        self.currentDailyAmbientTrackID = currentDailyAmbientTrackID
        self.missingDailyContent = missingDailyContent
        self.dailyAssetIssue = dailyAssetIssue
        self.pendingDailyRefresh = pendingDailyRefresh
        self.dailyRefreshID = dailyRefreshID
    }
}
