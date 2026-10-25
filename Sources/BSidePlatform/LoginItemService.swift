// BSidePlatform — Launch-at-login via the official SMAppService API (prompt rules #6/#23).
// No LaunchAgents plists, no shell hacks. Ad-hoc local bundles may not register cleanly —
// the mapping below reports the REAL system state; UI must never pretend success.

import ServiceManagement

public final class LoginItemService {
    public enum LoginItemState: String {
        case enabled
        case disabled
        case requiresApproval
        case error
    }

    public struct LoginItemResult {
        public let state: LoginItemState
        public let message: String?

        public init(state: LoginItemState, message: String?) {
            self.state = state
            self.message = message
        }
    }

    public init() {}

    public func currentState() -> LoginItemResult {
        if #available(macOS 13.0, *) {
            switch SMAppService.mainApp.status {
            case .enabled:
                return LoginItemResult(state: .enabled, message: nil)
            case .requiresApproval:
                return LoginItemResult(state: .requiresApproval,
                                       message: "需要在系统设置 → 通用 → 登录项中批准")
            case .notRegistered:
                return LoginItemResult(state: .disabled, message: nil)
            case .notFound:
                return LoginItemResult(state: .error, message: "暂时无法设置登录启动，请手动打开 bsideyou。")
            @unknown default:
                return LoginItemResult(state: .error, message: "未知的 SMAppService 状态")
            }
        }
        return LoginItemResult(state: .error, message: "需要 macOS 13 或更高版本")
    }

    @discardableResult
    public func setEnabled(_ enabled: Bool) -> LoginItemResult {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                let current = currentState()
                // register() throws when approval is pending — surface the REAL state.
                if current.state == .requiresApproval {
                    return current
                }
                return LoginItemResult(state: .error, message: "\(error)")
            }
            return currentState()
        }
        return LoginItemResult(state: .error, message: "需要 macOS 13 或更高版本")
    }

    /// Human-readable summary for Settings/Help (honest about environment limits).
    public func describe() -> String {
        let result = currentState()
        switch result.state {
        case .enabled: return "已开启"
        case .disabled: return "未开启"
        case .requiresApproval: return result.message ?? "待批准"
        case .error: return "不可用：\(result.message ?? "未知原因")"
        }
    }
}
