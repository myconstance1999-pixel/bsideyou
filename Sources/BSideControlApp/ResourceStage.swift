import BSideCore

/// ControlApp's resource-loading state. Failure carries its meaning with the state, so UI
/// wording changes and restoring a cancelled picker cannot change the failure classification.
public enum ResourceStage: Equatable {
    case unconfigured, selecting, validating, loading, startingPlayback, ready
    case failed(HealthProjection.FailureKind)

    /// Stable diagnostic labels; this UI state is not persisted or sent over IPC.
    var logName: String {
        switch self {
        case .unconfigured: return "unconfigured"
        case .selecting: return "selecting"
        case .validating: return "validating"
        case .loading: return "loading"
        case .startingPlayback: return "startingPlayback"
        case .ready: return "ready"
        case .failed: return "failed"
        }
    }

    var failureKind: HealthProjection.FailureKind? {
        guard case .failed(let kind) = self else { return nil }
        return kind
    }

    /// The Settings label and semantic health read the same typed cause, never the detail text.
    var settingsDescription: String {
        switch self {
        case .unconfigured: return "未配置"
        case .selecting: return "正在选择目录…"
        case .validating: return "正在验证…"
        case .loading: return "正在加载…"
        case .startingPlayback: return "正在启动…"
        case .ready: return "已就绪"
        case .failed(.resourceUnavailable): return "读取失败"
        case .failed(.service): return "服务异常"
        }
    }
}
