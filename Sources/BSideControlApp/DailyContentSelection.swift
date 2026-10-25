import BSideCore

extension ControlCenterModel {
    /// Discovery belongs to the accepted resource request and current Agent generation.
    /// A missing target is still a useful catalog; a failed directory choice is not.
    private var dailyDiscoveryBelongsToCurrentRun: Bool {
        guard resourceConfigured, !dailyCatalogSelectionFailed, supervision == .running else { return false }
        switch stage {
        case .unconfigured, .validating, .loading, .startingPlayback: return false
        case .selecting, .ready, .failed: return true
        }
    }

    var dailyContentKeys: [ContentKey]? {
        dailyDiscoveryBelongsToCurrentRun ? snapshot?.dailyContentKeys : nil
    }

    /// The deliberate soundtrack picker and legacy pin use the same admitted catalog boundary.
    var dailySoundtrackCatalog: [AmbientTrack]? {
        dailyDiscoveryBelongsToCurrentRun ? snapshot?.dailyAmbientTracks : nil
    }

    /// The ambient count comes from the same latest confirmed directory read as the daily
    /// combinations: nil is unknown, 0 is a confirmed empty set, a positive number is discovery
    /// evidence only — never proof the file is playable.
    var dailyAmbientTrackCount: Int? {
        dailyDiscoveryBelongsToCurrentRun ? snapshot?.dailyAmbientTrackCount : nil
    }

    /// One quiet, concise resource line for the Control Center and Settings. The counts are the
    /// same confirmed discovery as before (unknown is still distinct from a known empty set and
    /// never proves playability); missing periods and read failures stay in the separate
    /// notice/recovery views, so this line never has to carry a failure or a recovery action.
    var dailyResourceSummary: String {
        guard let keys = dailyContentKeys else { return "日常素材待确认" }
        let ambient: String
        switch dailyAmbientTrackCount {
        case .some(0): ambient = "未找到环境声"
        case .some(let count): ambient = "环境声 \(count) 段"
        case .none: ambient = "环境声待确认"
        }
        return "日常画面 \(keys.count) 组 · \(ambient)"
    }

    private func hasDailyContent(scene: BSideCore.Scene, outfit: Outfit, time: TimeOfDay?) -> Bool {
        guard let keys = dailyContentKeys else { return true }
        return keys.contains { $0.scene == scene && $0.outfit == outfit && (time == nil || $0.time == time) }
    }

    private var fixedDailyTime: TimeOfDay? {
        if case .fixed(let time) = desired.timeMode { return time }
        return nil
    }

    func dailySceneIsEnabled(_ scene: BSideCore.Scene) -> Bool {
        hasDailyContent(scene: scene, outfit: desired.outfit, time: fixedDailyTime)
    }

    func dailyOutfitIsEnabled(_ outfit: Outfit) -> Bool {
        hasDailyContent(scene: desired.scene, outfit: outfit, time: fixedDailyTime)
    }

    func dailyTimeIsEnabled(_ time: TimeOfDay) -> Bool {
        hasDailyContent(scene: desired.scene, outfit: desired.outfit, time: time)
    }

    /// A partial day remains an explicit automatic choice, with missing periods disclosed.
    /// Coverage is independent of the current clock, so this projection needs no UI timer.
    var dailyAutoIsEnabled: Bool {
        hasDailyContent(scene: desired.scene, outfit: desired.outfit, time: nil)
    }

    var dailyContentNotice: String? {
        guard dailyContentKeys != nil else { return nil }
        if let time = fixedDailyTime {
            // A saved choice can be unavailable because the supported set no longer offers it.
            // State that plainly and point at an available choice; do not imply that obtaining
            // more footage is the fix.
            return dailyTimeIsEnabled(time) ? nil : "当前组合在已找到的日常素材中不可用，请切换到其他组合。"
        }
        let missing = TimeOfDay.allCases.filter { !dailyTimeIsEnabled($0) }
        guard !missing.isEmpty else { return nil }
        return "自动时段缺少：\(missing.map(\.controlCenterLabel).joined(separator: "、"))。可切换到已找到的固定组合。"
    }
}
