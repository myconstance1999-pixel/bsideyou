// BSideControlApp — LoginItemCoordinator (Slice 7): the ONLY production surface for the login
// item. Wraps BSidePlatform.LoginItemService (SMAppService.mainApp, ADR-011) behind the pure
// Core projection, so Settings toggle/subtitle and Diagnostics show ONE reconciled truth:
// system status is authoritative and is RE-QUERIED on launch/activation/settings-open/change; the
// remembered request outcome only refines messaging (it can never flip the toggle). It changes
// launchd state only when the user toggles Settings — no silent registrations anywhere.

import Foundation
import BSideCore
import BSidePlatform

final class LoginItemCoordinator {
    private let service: LoginItemService
    private(set) var lastRequest: LoginRequestOutcome = .idle
    private(set) var projection = LoginItemProjection(system: .unknown)

    init(service: LoginItemService = LoginItemService()) {
        self.service = service
    }

    /// Re-query the REAL system status and rebuild the projection (launch, settings-open,
    /// refresh paths). Never trusts a previously seen status or any persisted intent.
    @discardableResult
    func refresh() -> LoginItemProjection {
        let result = service.currentState()
        let system = LoginSystemStatus(platformRawValue: result.state.rawValue)
        projection = LoginItemProjection(
            system: system,
            request: lastRequest,
            persistedIntent: nil,
            // The service collapses SMAppService `.notFound` into its `.error` bucket with a
            // concise message; surface it as the (still brief) ordinary-UI note, never a raw error.
            systemNote: (system == .unknown || system == .notFound) ? result.message : nil)
        let outcome = outcomeLog(lastRequest)
        AppLog.control("loginItem.query system=\(system.rawValue) toggle=\(projection.toggleOn) outcome=\(outcome)")
        return projection
    }

    /// User toggled the login item. Performs the REAL register/unregister through the service,
    /// classifies the outcome against the system status that followed, and records it so the
    /// ordinary UI can never treat a failed/approval-pending request as silent success.
    @discardableResult
    func setEnabled(_ enabled: Bool) -> LoginItemProjection {
        let requestResult = service.setEnabled(enabled)
        // A thrown register/unregister request is not a system-status observation. Query the
        // service again so (for example) a failed disable cannot project toggle OFF while the
        // real login item is still enabled.
        let observed = service.currentState()
        let system = LoginSystemStatus(platformRawValue: observed.state.rawValue)
        lastRequest = LoginRequestClassifier.classify(
            requestedEnabled: enabled,
            callSucceeded: requestResult.state != .error,
            systemAfter: system,
            errorCause: requestResult.message ?? observed.message)
        projection = LoginItemProjection(
            system: system,
            request: lastRequest,
            persistedIntent: nil,
            systemNote: (system == .unknown || system == .notFound) ? observed.message : nil)
        AppLog.control("loginItem.set enabled=\(enabled) system=\(system.rawValue) outcome=\(outcomeLog(lastRequest))")
        return projection
    }

    /// Concise ordinary-UI line for the Settings subtitle.
    var summary: String { projection.summary }

    /// Technical line for Diagnostics / Copy Diagnostics.
    var diagnosticLine: String { projection.diagnosticLine }

    private func outcomeLog(_ outcome: LoginRequestOutcome) -> String {
        switch outcome {
        case .idle: return "idle"
        case .succeeded: return "succeeded"
        case .approvalPending: return "approvalPending"
        case .failed(let cause): return "failed(\(cause))"
        }
    }
}
