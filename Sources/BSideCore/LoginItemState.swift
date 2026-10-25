// BSideCore — LoginItem domain (Slice 7): pure status/outcome model + projection + request
// classifier for the SMAppService-backed login item (ADR-011). SYSTEM STATUS IS AUTHORITATIVE:
// a persisted user intent expresses past desire only and is never trusted as truth — the
// projection's toggle is derived from system status alone, and reconciliation only refines
// messaging (never flips the toggle). This file is framework-free (arch gate #4) and knows
// nothing about ServiceManagement/AppKit; BSideControlApp owns the SMAppService adapter and
// feeds this pure layer its observations.

/// System truth as the UI understands it — a projection of SMAppService.Status semantics.
public enum LoginSystemStatus: String, Equatable, CaseIterable {
    /// Registered and active as a login item.
    case enabled
    /// Not registered as a login item (SMAppService `.notRegistered` / user turned it off).
    case disabled
    /// Registered, but macOS requires user approval in System Settings → 通用 → 登录项.
    case requiresApproval
    /// The bundle is not recognized as an installed app (SMAppService `.notFound`).
    case notFound
    /// Anything else, including the adapter's error bucket.
    case unknown

    /// Deterministic translation of the adapter's raw state labels, kept in Core so the
    /// status→model mapping is unit-tested without touching SMAppService. The adapter's
    /// `LoginItemService` collapses `.notFound` into its `.error` bucket, so callers pass the
    /// service's concise note separately through `LoginItemProjection(systemNote:)`.
    public init(platformRawValue: String) {
        switch platformRawValue {
        case LoginSystemStatus.enabled.rawValue: self = .enabled
        case LoginSystemStatus.disabled.rawValue: self = .disabled
        case LoginSystemStatus.requiresApproval.rawValue: self = .requiresApproval
        case LoginSystemStatus.notFound.rawValue: self = .notFound
        default: self = .unknown
        }
    }
}

/// What came out of the most recent register()/unregister() request this session. The cause of
/// `.failed` is TECHNICAL detail — it belongs in Diagnostics, never in the ordinary UI line.
public enum LoginRequestOutcome: Equatable {
    /// No request has been made this session (launch-time projection).
    case idle
    /// The request returned and the system state followed it (enabled→enabled / disabled→disabled).
    case succeeded
    /// register() succeeded but macOS now requires user approval in System Settings.
    case approvalPending
    /// The request threw, or the system did not follow it. `cause` is technical (diagnostics only).
    case failed(cause: String)

    /// Whether any failure occurred this session (used by the truthful summary wording).
    public var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// ONE projection driving the Settings login toggle/subtitle and the Diagnostics block.
/// `system` is always the truth source; `request` and `persistedIntent` only refine messaging.
public struct LoginItemProjection: Equatable {
    public let system: LoginSystemStatus
    public let request: LoginRequestOutcome
    /// Optional past user intent (forward-compatible, e.g. a persisted preference). NEVER
    /// authoritative — the toggle ignores it by construction.
    public let persistedIntent: Bool?
    /// Concise system-provided note (adapter passes the service's message for its error bucket,
    /// e.g. "系统找不到本应用（未安装为正式 bundle？）"). Never a raw error dump.
    public let systemNote: String?

    public init(system: LoginSystemStatus,
                request: LoginRequestOutcome = .idle,
                persistedIntent: Bool? = nil,
                systemNote: String? = nil) {
        self.system = system
        self.request = request
        self.persistedIntent = persistedIntent
        self.systemNote = systemNote
    }

    /// The toggle follows SYSTEM TRUTH only: a stale persisted intent can never turn it on.
    public var toggleOn: Bool { system == .enabled }

    /// macOS is waiting for the user to approve in 系统设置 → 通用 → 登录项.
    public var needsApprovalAction: Bool { system == .requiresApproval }

    /// Concise truthful user-language line for the ordinary Settings UI (prompt #27).
    /// A failed request is never silent ("上次操作未生效"), but raw technical causes never
    /// appear here — they live in `diagnosticLine`.
    public var summary: String {
        switch system {
        case .enabled:
            return request.isFailed ? "已开启 · 上次操作未生效" : "已开启"
        case .disabled:
            return request.isFailed ? "未开启 · 上次操作未生效" : "未开启"
        case .requiresApproval:
            return "待批准：请在 系统设置 → 通用 → 登录项 中批准"
        case .notFound:
            return "不可用：当前应用未按正式安装包运行"
        case .unknown:
            if let note = systemNote, !note.isEmpty { return "不可用：\(note)" }
            return "不可用"
        }
    }

    /// Technical detail for Diagnostics / Copy Diagnostics — never the ordinary UI line.
    public var diagnosticLine: String {
        var parts = ["system=\(system.rawValue)", "toggle=\(toggleOn ? "on" : "off")"]
        switch request {
        case .idle: parts.append("request=idle")
        case .succeeded: parts.append("request=succeeded")
        case .approvalPending: parts.append("request=approvalPending")
        case .failed(let cause): parts.append("request=failed(\(cause))")
        }
        if needsApprovalAction { parts.append("needsApproval=true") }
        if let intent = persistedIntent { parts.append("persistedIntent=\(intent)") }
        if let note = systemNote, !note.isEmpty { parts.append("note=\(note)") }
        return parts.joined(separator: " ")
    }
}

/// Pure classifier for the outcome of a register()/unregister() request. The SMAppService
/// adapter feeds it: what the user asked, whether the call threw, and the system status that
/// followed — the classifier owns the outcome semantics (approval-pending vs succeeded vs
/// failed), so this modeling is deterministically tested without touching ServiceManagement.
public enum LoginRequestClassifier {

    /// - Parameters:
    ///   - requestedEnabled: what the user asked (true = enable/register, false = disable/unregister)
    ///   - callSucceeded: whether the adapter's call returned without its error bucket
    ///   - systemAfter: system status observed right after the request
    ///   - errorCause: the adapter's technical error message when `callSucceeded == false`
    public static func classify(
        requestedEnabled: Bool,
        callSucceeded: Bool,
        systemAfter: LoginSystemStatus,
        errorCause: String?
    ) -> LoginRequestOutcome {
        // Approval pending always wins: register() landed (or still needs approval) — that is
        // a "go approve in System Settings" state, NOT a failure, even if the call surfaced an
        // error while approval was pending.
        if systemAfter == .requiresApproval { return .approvalPending }
        switch (requestedEnabled, systemAfter) {
        case (true, .enabled), (false, .disabled):
            // The system followed the request: success.
            return .succeeded
        default:
            // Either the call threw (technical cause preserved) or it returned without the
            // system following (truthful "did not take" failure).
            if !callSucceeded {
                return .failed(cause: errorCause ?? "SMAppService call failed without a message")
            }
            return .failed(cause: "SMAppService returned but status stayed \(systemAfter.rawValue) after \(requestedEnabled ? "register" : "unregister")")
        }
    }
}