// BSideTestRunner entry point — exits non-zero when any check fails (gate relies on this).

import Foundation
import BSideCore

if CommandLine.arguments.contains("--probe-desktop-visibility") {
    runDesktopVisibilityProbe()
}
if CommandLine.arguments.contains("--cover-desktop-only") {
    runDesktopCoverFixture()
}

if CommandLine.arguments.contains("--emit-desired-sample") {
    var desired = DesiredState(scene: .b, outfit: .r2, timeMode: .fixed(.night))
    desired.masterVolume = 0.8
    desired.profile = .normal
    print(String(data: try! JSONEncoder().encode(desired), encoding: .utf8)!)
    exit(0)
}

// Metadata-only import summary for one explicitly selected local root (ADR-022). Inert in the
// ordinary gate run; used to re-count a known root without reading any media payload.
if let index = CommandLine.arguments.firstIndex(of: "--local-import-summary"),
   CommandLine.arguments.count > index + 2 {
    do {
        try writeLocalImportSummary(rootPath: CommandLine.arguments[index + 1],
                                    outputPath: CommandLine.arguments[index + 2])
        exit(0)
    } catch {
        print("local-import-summary failed: \(error)")
        exit(2)
    }
}

if CommandLine.arguments.contains("--verify-home-frames") {
    runHomeCompanionFrameTests()
    print("Home frames: \(suiteTotal) suites, \(suiteFailed) failed, \(failureCount) assertions")
    exit(suiteFailed == 0 ? 0 : 1)
}

if CommandLine.arguments.contains("--verify-desktop-workspace") {
    runAppIdentityTests()
    runDesktopWorkspaceTests()
    print("Desktop workspace: \(suiteTotal) suites, \(suiteFailed) failed, \(failureCount) assertions")
    exit(suiteFailed == 0 ? 0 : 1)
}

let started = Date()
runAppIdentityTests()
runDesktopWorkspaceTests()
runTimeBucketTests()
runBeijingClockTests()
runContentResolverTests()
runPlaybackPolicyTests()
runIPCTests()
runNewlineFrameReaderTests()
runDesiredStateTests()
runPreferencesSaveTests()
runDirectoryAccessTests()
runDirectoryChangeMonitorTests()
runProviderTests()
runOnboardingStateTests()
runCommandParserTests()
runAgentLifecycleTests()
runHealthProjectionTests()
runPlaybackLifecycleTests()
runPlaybackHistoryTests()
runPlaybackProgressTests()
runDailyResourceLifecycleTests()
runDailySwitchLifecycleTests()
runDailyActivityTests()
runPlaybackEngineTests()
runHomeCompanionFrameTests()
runPerformanceAudioPlayerTests()
runFullscreenClassifierTests()
runPowerStateTests()
runHostReassertTests()
runDesktopHostRecoveryTests()
runPlatformWiringTests()
runEnergyMonitorTests()
runLoginItemProjectionTests()
runLogRotationTests()
runDiagnosticsTests()
runPerformanceTests()
runPerformanceRuntimeTests()
runPerformanceQueueTests()
runSongPlaybackHistoryTests()
runStudyTimerTests()
runPerformanceCatalogLoaderTests()
runPerformanceSemanticSidecarTests()
runLocalSongTests()
runWatchPresentationTests()
runRuntimeAcceptanceTests()

let elapsed = Date().timeIntervalSince(started)
print("\(suiteTotal) suites, \(suiteTotal - suiteFailed) passed, \(suiteFailed) failed, \(failureCount) assertion failures [\(String(format: "%.2fs", elapsed))]")
exit(suiteFailed == 0 ? 0 : 1)
