import SwiftUI
import BSideCore

/// A shared projection for the existing Control Center, Settings and library. Actions use
/// their ordinary coordinator entries; this view never validates resources or starts a player.
struct ResourceRecoveryGuidance {
    enum Action: Equatable {
        case chooseResource, retryResource, restartAgent

        var title: String {
            switch self {
            case .chooseResource: return "选择日常素材…"
            case .retryResource: return "重试此目录"
            case .restartAgent: return "重启壁纸服务"
            }
        }

        var request: ControlCenterRequest {
            switch self {
            case .chooseResource: return .chooseResource
            case .retryResource: return .retryResource
            case .restartAgent: return .restartAgent
            }
        }
    }

    let message: String
    let action: Action?
    let secondaryAction: Action?

    init(message: String, action: Action?, secondaryAction: Action? = nil) {
        self.message = message
        self.action = action
        self.secondaryAction = secondaryAction
    }
}

extension ControlCenterModel {
    var resourceRecoveryGuidance: ResourceRecoveryGuidance? {
        if stage.failureKind == .resourceUnavailable {
            let retry = canRetryDailyResource && dailyAssetIssue != .ambiguousLayouts
            return .init(message: stageDetail.isEmpty
                ? "无法读取日常素材。请确认目录可访问，或重新选择。" : stageDetail,
                         action: retry ? .retryResource : .chooseResource,
                         secondaryAction: retry ? .chooseResource : nil)
        }
        if stage == .unconfigured {
            return .init(message: "请选择日常素材目录。", action: .chooseResource)
        }
        switch supervision {
        case .starting, .stopping, .backoff:
            return .init(message: "正在恢复播放器，请稍候。", action: nil)
        case .idle, .running, .degraded:
            break
        }
        if health == .serviceProblem || (stage == .ready && supervision == .idle) {
            return resourceConfigured
                ? .init(message: stage == .failed(.service) && !stageDetail.isEmpty
                        ? stageDetail
                        : "播放器未能正常运行，请重启壁纸服务。",
                        action: .restartAgent)
                : .init(message: "请先选择日常素材目录。", action: .chooseResource)
        }
        switch stage {
        case .selecting, .validating, .loading, .startingPlayback:
            return .init(message: stage.settingsDescription, action: nil)
        case .ready where health == .preparing:
            return .init(message: "正在确认播放器状态…", action: nil)
        default:
            return nil
        }
    }
}

struct ResourceRecoveryFeedback: View {
    @ObservedObject var model: ControlCenterModel

    var body: some View {
        if let guidance = model.resourceRecoveryGuidance {
            VStack(alignment: .leading, spacing: 6) {
                Text(guidance.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("resource-recovery-message")
                if let action = guidance.action {
                    HStack(spacing: 8) {
                        Button(action.title) { model.onRequest(action.request) }
                            .accessibilityIdentifier("resource-recovery-action")
                        if let secondary = guidance.secondaryAction {
                            Button(secondary.title) { model.onRequest(secondary.request) }
                                .accessibilityIdentifier("resource-recovery-secondary")
                        }
                    }
                    .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
        }
    }
}
