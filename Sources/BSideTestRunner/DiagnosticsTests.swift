// BSideTestRunner — Diagnostics projection suites (Diagnostics/Help cleanup slice).
// These exercise the EXACT DiagnosticsBuilder the Diagnostics window and Copy Diagnostics
// share (BSidePlatform.DiagnosticsBuilder), proving the two surfaces project ONE coherent,
// current view: authoritative desired state + stage + supervision + agent snapshot + login
// + system, with home paths redacted and no ambiguous duplicate "state:" rows. AppKit
// windows are not needed — the shared text projection is all these surfaces render.

import Foundation
import BSideCore
import BSidePlatform

/// Same fixed label column the builder uses, so tests pin the exact aligned shape.
private func pad(_ s: String) -> String { s.padding(toLength: 14, withPad: " ", startingAt: 0) }

private func diagInput(
    prefs: AppPreferences = AppPreferences(),
    stage: String = "ready",
    stageDetail: String = "",
    stageAt: Date = Date(timeIntervalSince1970: 1_600_000_000),
    supervisionState: String = "running",
    abnormalExits: Int = 0,
    maxFailures: Int = 5,
    lastExitSummary: String? = nil,
    launchedAt: Date? = nil,
    lastSnapshot: RuntimeSnapshot? = nil,
    login: LoginItemProjection? = nil
) -> DiagnosticsBuilder.Input {
    DiagnosticsBuilder.Input(
        prefs: prefs, stage: stage, stageDetail: stageDetail, stageAt: stageAt,
        supervisionState: supervisionState, abnormalExits: abnormalExits,
        maxFailures: maxFailures, lastExitSummary: lastExitSummary,
        launchedAt: launchedAt, lastSnapshot: lastSnapshot, login: login)
}

func runDiagnosticsTests() {

    run("Diagnostics.saveFailureIsSeparateAndRedacted") { t in
        var input = diagInput()
        input.preferencesSaveStatus = "failed"
        input.preferencesSaveError = "Cannot write " + FileManager.default.homeDirectoryForCurrentUser.path + "/Library/preferences.json"
        let text = DiagnosticsBuilder.build(input)
        t.expect(text.contains("\(pad("saved"))failed"), "persistence failure is explicit")
        t.expect(text.contains("\(pad("stage"))ready"), "persistence does not rewrite resource health")
        t.expect(text.contains("~/Library/preferences.json"), "technical cause is redacted")
        input.preferencesSaveStatus = "saved"
        input.preferencesSaveError = nil
        t.expect(!DiagnosticsBuilder.build(input).contains("save error"), "successful save clears obsolete cause")
    }

    run("Diagnostics.desiredBlockProjectsAuthoritativeState") { t in
        var desired = DesiredState(scene: .b, outfit: .r2, timeMode: .fixed(.night))
        desired.masterVolume = 0.8
        desired.musicVolume = 0.7
        desired.ambientVolume = 0.5
        desired.musicMuted = true
        desired.ambientMuted = false
        desired.paused = true
        desired.profile = .quiet
        desired.desktopMode = false
        let prefs = AppPreferences(desired: desired.sanitized())
        let text = DiagnosticsBuilder.build(diagInput(prefs: prefs))

        t.expect(text.contains("=== desired ==="), "desired section header present")
        t.expect(text.contains("\(pad("scene"))B"), "scene projected from persisted desired")
        t.expect(text.contains("\(pad("outfit"))R2"), "outfit projected from persisted desired")
        t.expect(text.contains("\(pad("time"))fixed:2000"), "fixed time projected (IPC spelling)")
        t.expect(text.contains("\(pad("profile"))quiet (Quiet)"), "profile id + name projected")
        t.expect(text.contains("\(pad("paused"))on"), "user pause projected")
        t.expect(text.contains("\(pad("mode"))preview"), "desktopMode off → preview mode")
        t.expect(text.contains("\(pad("volumes"))master 0.80 / music 0.70 / ambient 0.50"),
                 "all three desired volumes projected")
        t.expect(text.contains("\(pad("mutes"))music on / ambient off"), "channel mutes projected")
    }

    run("Diagnostics.blocksInCoherentOrderAndSingleStateRow") { t in
        let text = DiagnosticsBuilder.build(diagInput(
            stage: "playing",
            supervisionState: "running",
            lastSnapshot: RuntimeSnapshot(state: .playing, currentClip: "loop://A/R1/1200"),
            login: LoginItemProjection(system: .enabled)))

        // One coherent narrative: what the user asked → loading stage → supervision →
        // agent runtime → login → environment.
        let headers = ["=== desired ===", "=== resource ===", "=== supervision ===",
                       "=== agent snapshot ===", "=== login item ===", "=== system ==="]
        var previousEnd = -1
        for header in headers {
            guard let range = text.range(of: header) else {
                t.expect(false, "header present: \(header)")
                continue
            }
            t.expect(text.distance(from: text.startIndex, to: range.lowerBound) > previousEnd,
                     "\(header) appears in narrative order")
            previousEnd = text.distance(from: text.startIndex, to: range.upperBound)
        }

        // "state:" is the agent runtime axis ONLY — the supervisor row is "phase:", so the
        // two blocks never show ambiguous duplicate "state:" labels.
        t.expect(text.contains("\(pad("state"))playing"),
                 "agent snapshot state row keeps the runtime state")
        t.expect(text.contains("\(pad("phase"))running"), "supervision row labeled phase")
        t.expect(!text.contains("\(pad("state"))running"), "no duplicate ambiguous state row")

        let supervisorOnly = DiagnosticsBuilder.build(diagInput(supervisionState: "idle"))
        t.expect(supervisorOnly.contains("\(pad("phase"))idle"), "supervision-only: phase row")
        t.expect(!supervisorOnly.contains(pad("state")), "supervision-only: no state row at all")
    }

    run("Diagnostics.homePathRedactedToTilde") { t in
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = home + "/Documents/MyBsideAssets"
        let text = DiagnosticsBuilder.build(diagInput(
            prefs: AppPreferences(assetPath: path),
            stage: "loading",
            stageDetail: home + "/Documents/MyBsideAssets/assets"))

        t.expect(!text.contains(home), "no raw home path leaks into shareable output")
        t.expect(text.contains("~/Documents/MyBsideAssets/assets"),
                 "stage detail redacted with ~")
        t.expect(text.contains("~/Documents/MyBsideAssets"),
                 "asset path redacted with ~")
        t.expect(text.contains(pad("path")) && !text.contains(home),
                 "path row exists and stays redacted")
    }

    run("Diagnostics.buildIsDeterministic") { t in
        let input = diagInput(
            prefs: AppPreferences(desired: {
                var d = DesiredState(scene: .c, outfit: .r3, timeMode: .fixed(.evening))
                d.masterVolume = 0.6
                d.profile = .coding
                return d.sanitized()
            }()),
            stage: "ready",
            stageDetail: "loop://C/R3/1730",
            supervisionState: "running",
            abnormalExits: 1,
            maxFailures: 5,
            lastExitSummary: "crashed with signal 11",
            lastSnapshot: RuntimeSnapshot(
                state: .paused, currentClip: "loop://C/R3/1730", musicVolume: 0.4,
                ambientVolume: 0.3, visual: .full, reasons: ["fullscreen-app"],
                catalogSummary: "loops:27 transitions:9 ambient:22 unknown:0"),
            login: LoginItemProjection(system: .disabled, request: .failed(cause: "SMAppServiceError.notPermitted")))

        let first = DiagnosticsBuilder.build(input)
        let second = DiagnosticsBuilder.build(input)
        t.expectEqual(first, second, "identical input produces identical diagnostics text")
        t.expect(first.contains("abnormal ×") , "supervision failure counter present")
        t.expect(first.contains("crashed with signal 11"), "last exit technical cause present")
        t.expect(first.contains("fullscreen-app"), "policy reason present in snapshot block")
        t.expect(first.contains("catalog"), "catalog summary row present")
    }

    run("Diagnostics.loginBlockCarriesTechnicalDetailOnlyInDiagnostics") { t in
        let projection = LoginItemProjection(
            system: .disabled,
            request: .failed(cause: "SMAppServiceError.notPermitted"),
            systemNote: "系统找不到本应用（未安装为正式 bundle？）")
        let text = DiagnosticsBuilder.build(diagInput(login: projection))

        // Ordinary-UI line keeps user language; technical cause lives in the detail row.
        t.expect(text.contains("\(pad("summary"))未开启 · 上次操作未生效"),
                 "login block shows the truthful user-facing summary")
        t.expect(text.contains("\(pad("detail"))system=disabled"),
                 "login block carries system truth")
        t.expect(text.contains("SMAppServiceError.notPermitted"),
                 "technical cause preserved for troubleshooting")
        t.expect(text.contains("note=系统找不到本应用"),
                 "system note preserved for troubleshooting")
    }
}
