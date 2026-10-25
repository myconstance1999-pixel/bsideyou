// BSideTestRunner — Slice 7 suites: login-item status→UI projection, request-outcome modeling,
// preference/system reconciliation, platform-raw translation, and summary-vs-diagnostics
// separation. These exercise the EXACT pure Core types BSideControlApp's LoginItemCoordinator
// uses (LoginItemProjection / LoginRequestClassifier / LoginSystemStatus), so the SMAppService
// adapter itself stays the thin untested glue between real system calls and this pure layer.

import Foundation
import BSideCore

func runLoginItemProjectionTests() {

    run("LoginItem.systemStatusDrivesToggleAndSummary") { t in
        let enabled = LoginItemProjection(system: .enabled)
        t.expect(enabled.toggleOn, "enabled → toggle ON")
        t.expectEqual(enabled.summary, "已开启", "enabled → concise summary")
        t.expect(!enabled.needsApprovalAction, "enabled never needs approval")

        let disabled = LoginItemProjection(system: .disabled)
        t.expect(!disabled.toggleOn, "disabled → toggle OFF")
        t.expectEqual(disabled.summary, "未开启", "disabled → concise summary")

        let pending = LoginItemProjection(system: .requiresApproval)
        t.expect(!pending.toggleOn, "requiresApproval → toggle OFF (not enabled yet)")
        t.expect(pending.needsApprovalAction, "requiresApproval → needs approval action")
        t.expect(pending.summary.contains("待批准"), "requiresApproval → approval wording")
        t.expect(pending.summary.contains("系统设置"), "requiresApproval mentions where to approve")

        let notFound = LoginItemProjection(system: .notFound)
        t.expect(!notFound.toggleOn, "notFound → toggle OFF")
        t.expectEqual(notFound.summary, "不可用：当前应用未按正式安装包运行", "notFound → concise unavailable")

        let unknown = LoginItemProjection(system: .unknown)
        t.expect(!unknown.toggleOn, "unknown → toggle OFF")
        t.expectEqual(unknown.summary, "不可用", "unknown without note → plain unavailable")

        let unknownNote = LoginItemProjection(system: .unknown, systemNote: "系统找不到本应用（未安装为正式 bundle？）")
        t.expectEqual(unknownNote.summary, "不可用：系统找不到本应用（未安装为正式 bundle？）",
                      "unknown with concise note → surfaced in ordinary UI")
    }

    run("LoginItem.requestOutcomeNeverSilent") { t in
        // A failed request must be visible even when the system state itself is truthful —
        // the toggle stays honest while the summary surfaces the failure.
        let failedWhileEnabled = LoginItemProjection(system: .enabled, request: .failed(cause: "unregister threw"))
        t.expect(failedWhileEnabled.toggleOn, "system enabled after failed disable → toggle stays ON (truth)")
        t.expect(failedWhileEnabled.summary.contains("上次操作未生效"), "failed disable never silent")

        let failedWhileDisabled = LoginItemProjection(system: .disabled, request: .failed(cause: "register threw"))
        t.expect(!failedWhileDisabled.toggleOn, "system disabled after failed enable → toggle stays OFF (truth)")
        t.expect(failedWhileDisabled.summary.contains("上次操作未生效"), "failed enable never silent")

        let succeeded = LoginItemProjection(system: .enabled, request: .succeeded)
        t.expectEqual(succeeded.summary, "已开启", "succeeded → clean summary")
        t.expect(!succeeded.summary.contains("未生效"), "no failure wording after success")

        let pending = LoginItemProjection(system: .requiresApproval, request: .approvalPending)
        t.expect(pending.needsApprovalAction, "approvalPending → needs approval action")
        t.expect(pending.summary.contains("待批准"), "approvalPending → approval wording, not failure")
    }

    run("LoginItem.reconcilePersistedIntentNeverAuthoritative") { t in
        // A stale "user wanted it on" preference must NEVER turn the toggle on.
        let staleOn = LoginItemProjection(system: .disabled, persistedIntent: true)
        t.expect(!staleOn.toggleOn, "persisted intent=true + system disabled → toggle OFF (system wins)")
        t.expectEqual(staleOn.summary, "未开启", "persisted intent must not change the truthful summary")

        let staleOff = LoginItemProjection(system: .enabled, persistedIntent: false)
        t.expect(staleOff.toggleOn, "persisted intent=false + system enabled → toggle ON (system wins)")

        let nilIntent = LoginItemProjection(system: .enabled, persistedIntent: nil)
        t.expect(nilIntent.toggleOn, "no persisted intent + enabled → ON")
        t.expect(!LoginItemProjection(system: .disabled, persistedIntent: nil).toggleOn, "no persisted intent + disabled → OFF")

        let pendingIntent = LoginItemProjection(system: .requiresApproval, persistedIntent: true)
        t.expect(!pendingIntent.toggleOn, "intent=true + requiresApproval → toggle OFF, approval pending")
        t.expect(pendingIntent.summary.contains("待批准"), "intent=true + requiresApproval → approval wording")
        t.expect(pendingIntent.diagnosticLine.contains("persistedIntent=true"),
                  "reconciliation detail (persisted intent) preserved for diagnostics")
    }

    run("LoginItem.classifierMapsRequestsToOutcomes") { t in
        // System followed the request → succeeded.
        t.expectEqual(LoginRequestClassifier.classify(requestedEnabled: true, callSucceeded: true,
                                                      systemAfter: .enabled, errorCause: nil),
                      .succeeded, "register + enabled → succeeded")
        t.expectEqual(LoginRequestClassifier.classify(requestedEnabled: false, callSucceeded: true,
                                                      systemAfter: .disabled, errorCause: nil),
                      .succeeded, "unregister + disabled → succeeded")

        // Approval always wins, even when the call surfaced an error while approval is pending.
        t.expectEqual(LoginRequestClassifier.classify(requestedEnabled: true, callSucceeded: true,
                                                      systemAfter: .requiresApproval, errorCause: nil),
                      .approvalPending, "register + requiresApproval → approvalPending")
        t.expectEqual(LoginRequestClassifier.classify(requestedEnabled: true, callSucceeded: false,
                                                      systemAfter: .requiresApproval, errorCause: "auth denied"),
                      .approvalPending, "approval beats a throwing call")

        // Throwing call → failed with the technical cause preserved.
        let threw = LoginRequestClassifier.classify(requestedEnabled: true, callSucceeded: false,
                                                    systemAfter: .disabled, errorCause: "SMAppServiceError.notPermitted")
        t.expectEqual(threw, LoginRequestOutcome.failed(cause: "SMAppServiceError.notPermitted"),
                      "register threw → failed with exact cause")
        let failedDisableStillEnabled = LoginRequestClassifier.classify(
            requestedEnabled: false, callSucceeded: false,
            systemAfter: .enabled, errorCause: "SMAppServiceError.notPermitted")
        t.expectEqual(failedDisableStillEnabled,
                      LoginRequestOutcome.failed(cause: "SMAppServiceError.notPermitted"),
                      "unregister threw + re-query still enabled → failure preserves system truth")
        t.expect(LoginItemProjection(system: .enabled, request: failedDisableStillEnabled).toggleOn,
                 "failed unregister must leave the toggle ON when the re-queried system is enabled")

        // Call returned but the system did not follow → truthful failure, not silent.
        let stuckOn = LoginRequestClassifier.classify(requestedEnabled: false, callSucceeded: true,
                                                      systemAfter: .enabled, errorCause: nil)
        if case .failed(let cause) = stuckOn {
            t.expect(cause.contains("enabled"), "unregister returned but stayed enabled → failed states the truth")
        } else {
            t.expect(false, "unregister returned but stayed enabled must be a failure")
        }
        let stuckOff = LoginRequestClassifier.classify(requestedEnabled: true, callSucceeded: true,
                                                       systemAfter: .disabled, errorCause: nil)
        if case .failed(let cause) = stuckOff {
            t.expect(cause.contains("disabled"), "register returned but stayed disabled → failed states the truth")
        } else {
            t.expect(false, "register returned but stayed disabled must be a failure")
        }

        // Missing error cause degrades to a clear technical line, never nil/empty.
        let noCause = LoginRequestClassifier.classify(requestedEnabled: true, callSucceeded: false,
                                                      systemAfter: .unknown, errorCause: nil)
        if case .failed(let cause) = noCause {
            t.expect(!cause.isEmpty, "failed without message still carries a technical cause")
        } else {
            t.expect(false, "throwing call without cause must still be a failure")
        }
    }

    run("LoginItem.platformRawTranslation") { t in
        t.expectEqual(LoginSystemStatus(platformRawValue: "enabled"), .enabled, "raw enabled")
        t.expectEqual(LoginSystemStatus(platformRawValue: "disabled"), .disabled, "raw disabled")
        t.expectEqual(LoginSystemStatus(platformRawValue: "requiresApproval"), .requiresApproval, "raw requiresApproval")
        t.expectEqual(LoginSystemStatus(platformRawValue: "notFound"), .notFound, "raw notFound")
        // The adapter's error bucket and any unknown label collapse to .unknown.
        t.expectEqual(LoginSystemStatus(platformRawValue: "error"), .unknown, "adapter error bucket → unknown")
        t.expectEqual(LoginSystemStatus(platformRawValue: "garbage"), .unknown, "unknown label → unknown")
    }

    run("LoginItem.diagnosticsKeepTechnicalCause") { t in
        // Technical cause lives in the diagnostics line only — never in the ordinary UI summary.
        let failed = LoginItemProjection(system: .disabled, request: .failed(cause: "SMAppServiceError.notPermitted"))
        t.expect(failed.diagnosticLine.contains("SMAppServiceError.notPermitted"),
                 "technical cause preserved in diagnostics")
        t.expect(!failed.summary.contains("SMAppServiceError"), "raw cause never leaks into ordinary UI")
        t.expect(failed.diagnosticLine.contains("system=disabled"), "diagnostics carry system truth")
        t.expect(failed.diagnosticLine.contains("toggle=off"), "diagnostics carry the truthful toggle")

        let pending = LoginItemProjection(system: .requiresApproval, request: .approvalPending)
        t.expect(pending.diagnosticLine.contains("needsApproval=true"), "diagnostics mark needs-approval")
        t.expect(!pending.summary.contains("approvalPending"), "technical labels never leak into ordinary UI")

        let noted = LoginItemProjection(system: .unknown, request: .failed(cause: "raw adapter error text"),
                                        systemNote: "系统找不到本应用（未安装为正式 bundle？）")
        t.expect(noted.diagnosticLine.contains("note=系统找不到本应用"), "diagnostics keep the system note")
        t.expect(noted.diagnosticLine.contains("raw adapter error text"), "diagnostics keep raw cause")
        t.expect(!noted.summary.contains("raw adapter error text"), "summary keeps only the concise note")
    }
}
