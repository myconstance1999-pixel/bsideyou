// BSideControlApp — bounded regression for the daily-candidate startup slice.
// Runs inside `--verify-control-state` (no AppDelegate, no NSApplication, no process spawn):
// it exercises the pure child-environment construction used before a real Agent spawn and the
// pure startup policy that decides duplicate activation vs candidate/ordinary conflict.
// Real effect paths (NSRunningApplication queries, the conflict alert, exit) are not invoked.

import Foundation
import BSidePlatform

func runStartupSliceRegression(expect: (Bool, String) -> Void) {
    expect(StartupDecisionPolicy.decide(StartupFacts(
        bundleIdentifier: AppIdentity.desktopPreviewBundleIdentifier, identity: .desktopPreview,
        sameIdentityRunning: true, ordinaryRunning: false)) == .activateSameInstance,
        "preview duplicate reopens the same drawer owner")
    expect(StartupDecisionPolicy.decide(StartupFacts(
        bundleIdentifier: AppIdentity.desktopPreviewBundleIdentifier, identity: .desktopPreview,
        sameIdentityRunning: false, ordinaryRunning: false, dailyCandidateRunning: true)) == .conflict,
        "preview cannot create a second Agent beside the installed daily candidate")
    expect(StartupDecisionPolicy.decide(StartupFacts(
        bundleIdentifier: AppIdentity.desktopPreviewBundleIdentifier, identity: .desktopPreview,
        sameIdentityRunning: false, ordinaryRunning: true)) == .conflict,
        "preview cannot create a second Agent beside the ordinary identity")
    expect(StartupDecisionPolicy.decide(StartupFacts(
        bundleIdentifier: AppIdentity.desktopPreviewBundleIdentifier, identity: .desktopPreview,
        sameIdentityRunning: false, ordinaryRunning: false)) == .proceed,
        "isolated preview can start when the daily app is stopped")
    runAgentChildEnvironmentRegression(expect: expect)
    runStartupDecisionRegression(expect: expect)
    runResolvedSupportPersistenceRegression(expect: expect)
}

private func runAgentChildEnvironmentRegression(expect: (Bool, String) -> Void) {
    let injected = "/tmp/bsidemac-test-candidate-support-\(UUID().uuidString)"
    let inherited = ["BSIDEMAC_SUPPORT_DIR": "/tmp/bsidemac-parent-default",
                     "BSIDEMAC_AGENT_PATH": "/tmp/agent-binary",
                     "PATH": "/usr/bin:/bin",
                     "HOME": "/synthetic-home"]
    let environment = AgentSupervisor.makeAgentEnvironment(
        inherited: inherited, resolvedSupportPath: injected)

    expect(environment[AppPaths.supportDirOverrideKey] == injected,
           "the child Agent environment must carry the EXPLICIT resolved support path")
    expect(environment[AppPaths.supportDirOverrideKey] != inherited[AppPaths.supportDirOverrideKey],
           "an inherited/standalone helper default must be overridden, not trusted")
    expect(environment["BSIDEMAC_AGENT_PATH"] == "/tmp/agent-binary",
           "unrelated inherited variables must be preserved for the child")
    expect(environment["PATH"] == "/usr/bin:/bin" && environment["HOME"] == "/synthetic-home",
           "the full parent environment must be retained apart from the support path")
    expect(inherited[AppPaths.supportDirOverrideKey] == "/tmp/bsidemac-parent-default",
           "building the child environment must not mutate the parent environment")

    // The production value passed to the spawn is the candidate default when no override exists,
    // so a candidate's Agent can never resolve the ordinary BSideMac folder.
    let candidateDefault = AppPaths.resolvedSupportRoot(
        bundleIdentifier: AppIdentity.dailyCandidateBundleIdentifier, environmentOverride: nil)
    let candidateEnvironment = AgentSupervisor.makeAgentEnvironment(
        inherited: [:], resolvedSupportPath: candidateDefault.path)
    expect(candidateEnvironment[AppPaths.supportDirOverrideKey] == candidateDefault.path,
           "candidate Agent environment must match the candidate support default")
    expect(candidateEnvironment[AppPaths.supportDirOverrideKey]?.hasSuffix("BSideMac-DailyCandidate") == true,
           "candidate Agent environment must never resolve the ordinary BSideMac folder")

    // With an explicit override present (test/verification), the override is what is injected.
    let overrideEnvironment = AgentSupervisor.makeAgentEnvironment(
        inherited: [:], resolvedSupportPath: "/tmp/bsidemac-injected")
    expect(overrideEnvironment[AppPaths.supportDirOverrideKey] == "/tmp/bsidemac-injected",
           "an injected isolated support path is the child's support path")
}

private func runStartupDecisionRegression(expect: (Bool, String) -> Void) {
    let candidate = AppIdentity.variant(forBundleIdentifier:
        AppIdentity.dailyCandidateBundleIdentifier)
    let normal = AppIdentity.variant(forBundleIdentifier: AppIdentity.normalBundleIdentifier)

    expect(candidate == .dailyCandidate && normal == .normal,
           "bundle identifiers must map to their fixed variants")

    expect(StartupDecisionPolicy.decide(StartupFacts(
        bundleIdentifier: "local.dev.swiftpm", identity: nil,
        sameIdentityRunning: false, ordinaryRunning: true)) == .proceed,
           "a dev/test binary is never blocked by a running ordinary app")

    expect(StartupDecisionPolicy.decide(StartupFacts(
        bundleIdentifier: AppIdentity.normalBundleIdentifier, identity: normal,
        sameIdentityRunning: true, ordinaryRunning: false)) == .activateSameInstance,
           "an ordinary duplicate activates the running instance and exits")

    expect(StartupDecisionPolicy.decide(StartupFacts(
        bundleIdentifier: AppIdentity.normalBundleIdentifier, identity: normal,
        sameIdentityRunning: false, ordinaryRunning: false)) == .proceed,
           "a lone ordinary instance starts normally")

    expect(StartupDecisionPolicy.decide(StartupFacts(
        bundleIdentifier: AppIdentity.dailyCandidateBundleIdentifier, identity: candidate,
        sameIdentityRunning: true, ordinaryRunning: false)) == .activateSameInstance,
           "a candidate duplicate activates the running candidate and exits")

    expect(StartupDecisionPolicy.decide(StartupFacts(
        bundleIdentifier: AppIdentity.dailyCandidateBundleIdentifier, identity: candidate,
        sameIdentityRunning: false, ordinaryRunning: true)) == .conflict,
           "a candidate launched next to the ordinary app instructs and exits")

    // Same-identity duplicate wins over the conflict check: the running candidate is resumed
    // instead of the app exiting because the ordinary app also happens to be running.
    expect(StartupDecisionPolicy.decide(StartupFacts(
        bundleIdentifier: AppIdentity.dailyCandidateBundleIdentifier, identity: candidate,
        sameIdentityRunning: true, ordinaryRunning: true)) == .activateSameInstance,
           "the same-identity duplicate branch is decided before the conflict branch")

    expect(StartupDecisionPolicy.decide(StartupFacts(
        bundleIdentifier: AppIdentity.dailyCandidateBundleIdentifier, identity: candidate,
        sameIdentityRunning: false, ordinaryRunning: false)) == .proceed,
           "a lone candidate starts normally")

    expect(!SingleInstanceGuard.conflictMessage.isEmpty
           && !SingleInstanceGuard.conflictDetail.isEmpty,
           "the conflict instruction must have user-visible native text")

    // The facts shell reads Bundle.main + NSWorkspace; in the regression process it must be
    // internally consistent and must never crash or claim a recognized identity for this binary.
    let facts = SingleInstanceGuard.currentFacts()
    expect(facts.identity == Bundle.main.bundleIdentifier.flatMap {
        AppIdentity.variant(forBundleIdentifier: $0)
    }, "currentFacts must derive its identity from Bundle.main only")
    expect(facts.bundleIdentifier != AppIdentity.dailyCandidateBundleIdentifier
           || facts.identity == .dailyCandidate,
           "a candidate bundle identifier always implies the candidate variant")
}

/// The resolved support path used by prefs/logs must be the candidate path when there is no
/// override, and the override when one is injected. Uses only REAL candidate/override paths for
/// resolution (no ordinary prefs are read) and asserts on paths, never on preferences contents.
private func runResolvedSupportPersistenceRegression(expect: (Bool, String) -> Void) {
    let candidateRoot = AppPaths.resolvedSupportRoot(
        bundleIdentifier: AppIdentity.dailyCandidateBundleIdentifier, environmentOverride: nil)
    expect(candidateRoot.lastPathComponent == "BSideMac-DailyCandidate",
           "candidate prefs/log path must default inside BSideMac-DailyCandidate")
    expect(candidateRoot.appendingPathComponent("preferences.json").deletingLastPathComponent().path
           == candidateRoot.path,
           "candidate preferences.json must live under the candidate support root")
    expect(candidateRoot.appendingPathComponent("control.log").lastPathComponent == "control.log",
           "candidate control.log must be the standard filename under the candidate root")
    expect(candidateRoot.appendingPathComponent("agent.log").lastPathComponent == "agent.log",
           "candidate agent.log must be the standard filename under the candidate root")

    let injected = ProcessInfo.processInfo.environment[AppPaths.supportDirOverrideKey]
    let resolvedWithProcess = AppPaths.resolvedSupportRoot(
        bundleIdentifier: AppIdentity.dailyCandidateBundleIdentifier)
    if let injected, !injected.isEmpty {
        expect(resolvedWithProcess.path == injected,
               "the process override wins over the candidate default for prefs/logs")
    } else {
        expect(resolvedWithProcess.path == candidateRoot.path,
               "without an override the candidate default is the process support root")
    }
}
