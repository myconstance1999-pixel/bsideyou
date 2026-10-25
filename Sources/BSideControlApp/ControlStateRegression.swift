// Runs the real UI models with bundled metadata only, without a delegate or media process.
// Kept in this executable so the test gate does not need a fifth product boundary.
import Foundation
import BSideCore
import BSidePlatform

func runControlStateRegression() -> Int32 {
    let model = ControlCenterModel()
    var owner = DesiredState()
    var sent: [DesiredState] = []
    var failures: [String] = []
    var checks = 0
    func expect(_ value: Bool, _ message: String) {
        checks += 1
        if !value { failures.append(message) }
    }
    func refresh() {
        model.apply(desired: owner, stage: .ready, stageDetail: "",
                    snapshot: nil, supervision: .idle)
    }
    let sceneControl = ControlCenterModel()
    let sceneDesired = DesiredState(scene: .a, outfit: .r3, timeMode: .fixed(.evening), musicVolume: 0.66, paused: true, profile: .coding)
    sceneControl.desired = sceneDesired
    var sceneChanges: [DesiredState] = []
    sceneControl.onDesiredChange = { sceneChanges.append($0) }
    sceneControl.toggleDailyVisualPause()
    var expectedScene = sceneDesired; expectedScene.dailyVisualPaused = true
    expect(sceneChanges.last == expectedScene, "scene pause changes only its own intent, preserving global/profile/song settings")
    sceneControl.toggleDailyVisualPause()
    expect(sceneChanges.last == sceneDesired, "scene resume restores only its own flag")
    expect(sceneControl.dailyVisualPauseIsRestricted && sceneControl.dailyVisualPauseActionTitle == "陪伴画面已随全部暂停",
           "scene action identifies global pause without promising scene-only recovery")
    sceneControl.desired.paused = false; sceneControl.desired.dailyVisualPaused = true
    expect(sceneControl.dailyVisualPauseActionTitle == "恢复陪伴画面" && !sceneControl.dailyVisualPauseIsRestricted,
           "own scene pause offers only scene recovery")
    sceneControl.snapshot = .init(state: .paused, visual: .paused, reasons: ["daily-user-paused", "screen-locked"])
    expect(sceneControl.dailyVisualPauseIsRestricted && sceneControl.dailyVisualPauseActionTitle == "陪伴画面暂不可播放",
           "confirmed safety pause prevents a misleading moving-picture promise")
    sceneControl.snapshot = nil; sceneControl.desired.profile = .movie
    expect(sceneControl.dailyVisualPauseIsRestricted && sceneControl.dailyVisualPauseActionTitle == "陪伴画面已随模式暂停",
           "scene control preserves and identifies profile restriction")
    let music = PerformanceBrowserModel()
    let target = LocalPerformanceReference(trackID: "resume", fileID: "file", catalogRevision: PerformanceCatalogRevision("test"))
    // Preserve profile restrictions while clearing only the explicit global pause.
    var resumeDesired = DesiredState(paused: true, profile: .movie)
    let resumeControl = ControlCenterModel()
    resumeControl.onDesiredChange = { resumeDesired = $0 }
    resumeControl.apply(desired: resumeDesired, stage: .ready, stageDetail: "", snapshot: nil, supervision: .idle)
    music.desired = resumeDesired
    music.sessionState.start(PerformanceSession(target: .localFile(target), mode: .watch, paused: true))
    expect(music.primaryMusicIsPaused && music.sessionPauseActionTitle == "恢复全部",
           "explicit global pause offers honest resume-all even with song pause")
    resumeControl.resumeUserPause()
    expect(!resumeDesired.paused && resumeDesired.profile == .movie,
           "resume-all user action cannot clear the profile restriction")
    expect(PlaybackPolicy.evaluate(desired: resumeDesired, context: RuntimeContext(),
        performance: music.sessionState.session).performancePaused,
        "profile and song pause still remain policy-authoritative")

    // Exercise the real pre-spawn failure path: no Process exists to deliver termination.
    // A rejected grant must free the reducer's reserved generation so reselection can retry.
    let rejectedGrantSupervisor = AgentSupervisor()
    var rejectedGrantCodes: [String] = []
    rejectedGrantSupervisor.onEvent = { event in
        if case .error(let code, _) = event { rejectedGrantCodes.append(code) }
    }
    rejectedGrantSupervisor.start(assetPath: "/missing-directory-access-grant", desired: DesiredState())
    expect(rejectedGrantSupervisor.lifecyclePhase == .idle,
           "grant failure before spawn must not wait forever for a nonexistent process")
    rejectedGrantSupervisor.restartAgent()
    expect(rejectedGrantSupervisor.lifecyclePhase == .idle,
           "failed authorization clears automatic and manual restart intent")
    rejectedGrantSupervisor.start(assetPath: "/another-missing-directory-access-grant", desired: DesiredState())
    expect(rejectedGrantSupervisor.lifecyclePhase == .idle && rejectedGrantCodes == ["assetAuthorization", "assetAuthorization"],
           "a later resource attempt reuses the released process slot and reports its own failure")

    model.onDesiredChange = { owner = $0 }
    model.onDesiredSettled = { sent.append(owner) }
    refresh()

    model.setMasterVolume(0.23)
    expect(owner.masterVolume == 0.23, "intent must reach the owner before a runtime refresh")
    refresh() // A snapshot/login-status refresh during the old 150 ms pending window.
    expect(model.desired.masterVolume == 0.23, "refresh must preserve the user's volume edit")
    model.setAmbientVolume(0.42)
    expect(owner.masterVolume == 0.23 && owner.ambientVolume == 0.42,
           "successive edits must compose across intervening refreshes")
    expect(model.profileOptions.filter { $0.id == owner.profile.id }.count == 1,
           "custom selection must have exactly one Picker tag on both surfaces")

    // A command from another UI surface must also survive the delayed save/send.
    owner.paused = true
    refresh()
    expect(sent.isEmpty, "rapid edits must not send synchronously")
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    model.preferencesDidChange()
    expect(model.preferencesSaveStatus == .pending, "an edit is not reported as saved before IO")
    model.preferencesSaveCompleted(succeeded: false)
    refresh()
    expect(model.preferencesSaveStatus == .failed, "runtime refresh must not erase save failure")
    model.preferencesDidChange()
    expect(model.preferencesSaveStatus == .failed, "another edit must keep unresolved failure visible")
    model.preferencesSaveCompleted(succeeded: true)
    expect(model.preferencesSaveStatus == .saved && model.desired == owner,
           "successful retry clears the failure without rolling back user intent")
    expect(sent == [owner], "one settled delivery must use the latest canonical state")
    expect(model.desired.paused, "external pause must not be undone by a pending slider edit")

    model.setProfile(.normal)
    expect(model.profileOptions == Profile.builtIn, "built-in selection must not retain a stale custom row")
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))

    // Resource errors must keep their meaning when wording is edited or localized. In
    // particular, ambiguous layouts are a resource problem although their message has no
    // "无法读取" substring. Both UI surfaces consume this same stage.
    for detail in ["发现多个可用版本，请选择具体版本文件夹。", "Choose a supported resource folder."] {
        model.apply(desired: owner, stage: .failed(.resourceUnavailable), stageDetail: detail,
                    snapshot: nil, supervision: .running)
        expect(model.health == .resourceUnavailable && model.stage.settingsDescription == "读取失败",
               "resource classification must survive a wording/language change")
    }
    model.apply(desired: owner, stage: .failed(.service), stageDetail: "无法读取播放器状态",
                snapshot: nil, supervision: .running)
    expect(model.health == .serviceProblem && model.stage.settingsDescription == "服务异常",
           "a service error must not become a resource error because of its wording")

    // The same guidance drives the Control Center, Settings and performance library.
    // Assert the recovery action and relevant evidence, not every rendered sentence.
    let recoveryModel = ControlCenterModel()
    let activeDesired = DesiredState()
    recoveryModel.apply(desired: activeDesired, stage: .unconfigured, stageDetail: "",
                        snapshot: nil, supervision: .idle)
    expect(recoveryModel.resourceRecoveryGuidance?.action == .chooseResource,
           "an unconfigured library flow must offer resource selection")

    let ambiguity = "发现多个可用版本，请选择具体版本文件夹。"
    recoveryModel.resourceConfigured = true
    recoveryModel.apply(desired: activeDesired, stage: .failed(.resourceUnavailable), stageDetail: ambiguity,
                        snapshot: nil, supervision: .degraded)
    expect(recoveryModel.resourceRecoveryGuidance?.message == ambiguity
           && recoveryModel.resourceRecoveryGuidance?.action == .chooseResource,
           "ambiguous resources must retain their actionable detail and offer selection, not restart")

    recoveryModel.apply(desired: activeDesired, stage: .failed(.service), stageDetail: "播放器未响应",
                        snapshot: nil, supervision: .degraded)
    expect(recoveryModel.resourceRecoveryGuidance?.action == .restartAgent
           && recoveryModel.resourceRecoveryGuidance?.message == "播放器未响应",
           "a service failure must preserve its specific recovery detail and offer restart")
    recoveryModel.apply(desired: activeDesired, stage: .failed(.service), stageDetail: "播放器未响应",
                        snapshot: nil, supervision: .backoff)
    expect(recoveryModel.resourceRecoveryGuidance?.message.contains("请稍候") == true
           && recoveryModel.resourceRecoveryGuidance?.action == nil,
           "automatic backoff must show waiting guidance without offering a duplicate restart")

    let playingSnapshot = RuntimeSnapshot(state: .playing, currentClip: "loop://A/R1/1200")
    recoveryModel.apply(desired: activeDesired, stage: .ready, stageDetail: "",
                        snapshot: playingSnapshot, supervision: .running)
    expect(recoveryModel.health == .normal && recoveryModel.resourceRecoveryGuidance == nil,
           "healthy playback must not carry stale error recovery guidance")
    var pausedDesired = activeDesired
    pausedDesired.paused = true
    recoveryModel.apply(desired: pausedDesired, stage: .ready, stageDetail: "",
                        snapshot: playingSnapshot, supervision: .running)
    expect(recoveryModel.health == .paused && recoveryModel.resourceRecoveryGuidance == nil,
           "global pause is user intent, not a service error requiring recovery")

    recoveryModel.resourceConfigured = false
    recoveryModel.apply(desired: activeDesired, stage: .failed(.service), stageDetail: "播放器未响应",
                        snapshot: nil, supervision: .degraded)
    expect(recoveryModel.resourceRecoveryGuidance?.action == .chooseResource,
           "without a resource root, service failure must not offer a restart that cannot run")

    let failedDirectoryModel = ControlCenterModel()
    failedDirectoryModel.apply(desired: activeDesired, stage: .failed(.resourceUnavailable),
        stageDetail: DailyAssetIssue.accessDenied.recoveryMessage,
        snapshot: RuntimeSnapshot(state: .degraded, dailyAssetIssue: .accessDenied), supervision: .running,
        dailyAssetIssue: .accessDenied, canRetryDailyResource: true)
    expect(failedDirectoryModel.health == .resourceUnavailable
           && failedDirectoryModel.resourceRecoveryGuidance?.action == .retryResource
           && failedDirectoryModel.resourceRecoveryGuidance?.secondaryAction == .chooseResource,
           "permission failure offers retry of the attempted directory plus an explicit relocation path")
    expect(!failedDirectoryModel.resourceConfigured && failedDirectoryModel.canRetryDailyResource,
           "a failed first selection can be retried before any resource preference is saved")
    failedDirectoryModel.apply(desired: activeDesired, stage: .failed(.resourceUnavailable),
        stageDetail: "New wording", snapshot: nil, supervision: .running,
        dailyAssetIssue: .ambiguousLayouts, canRetryDailyResource: true)
    expect(failedDirectoryModel.resourceRecoveryGuidance?.action == .chooseResource
           && failedDirectoryModel.resourceRecoveryGuidance?.secondaryAction == nil,
           "multiple versions require an explicit choice rather than retrying an ambiguous root")
    failedDirectoryModel.apply(desired: activeDesired, stage: .failed(.resourceUnavailable),
        stageDetail: DailyAssetIssue.missingLocation.recoveryMessage, snapshot: nil, supervision: .running,
        dailyAssetIssue: .missingLocation, canRetryDailyResource: false)
    expect(failedDirectoryModel.resourceRecoveryGuidance?.action == .chooseResource,
           "without a concrete retry target the UI must offer relocation, not a no-op retry")
    expect(DailyAssetIssue.missingLocation.recoveryMessage.contains("可能")
           && DailyAssetIssue.accessDenied.recoveryMessage.contains("权限")
           && DailyAssetIssue.noDailyContent.recoveryMessage.contains("日常视频"),
           "missing path, denied access and readable empty media have distinct actionable explanations")

    // FileManager error codes select recovery guidance independently of localization;
    // raw descriptions and UserInfo paths belong in local diagnostics, not the UI.
    let pendingSnapshot = RuntimeSnapshot(state: .playing, currentClip: "A.R1.1200", pendingDailyTime: .evening)
    var automaticDesired = activeDesired
    automaticDesired.timeMode = .auto
    recoveryModel.apply(desired: automaticDesired, stage: .ready, stageDetail: "",
                        snapshot: pendingSnapshot, supervision: .running)
    expect(recoveryModel.dailySwitchMessage?.contains("本段结束后") == true
           && recoveryModel.snapshot?.currentClip == "A.R1.1200",
           "pending lighting must be visible without relabeling the currently installed clip")
    automaticDesired.paused = true
    recoveryModel.apply(desired: automaticDesired, stage: .ready, stageDetail: "",
                        snapshot: pendingSnapshot, supervision: .running)
    expect(recoveryModel.dailySwitchMessage == nil, "pause must suppress a lagging pending snapshot")
    automaticDesired.paused = false
    automaticDesired.timeMode = .fixed(.night)
    recoveryModel.apply(desired: automaticDesired, stage: .ready, stageDetail: "",
                        snapshot: pendingSnapshot, supervision: .running)
    expect(recoveryModel.dailySwitchMessage == nil, "fixed choice must suppress a lagging automatic wait")
    let refreshSnapshot = RuntimeSnapshot(state: .playing, currentClip: "A.R1.2000", pendingDailyRefresh: true)
    recoveryModel.apply(desired: automaticDesired, stage: .ready, stageDetail: "",
                        snapshot: refreshSnapshot, supervision: .running)
    expect(recoveryModel.dailySwitchMessage == "本段结束后更新日常素材",
           "fixed time can explain a changed source without claiming a time-of-day switch")
    automaticDesired.paused = true
    recoveryModel.apply(desired: automaticDesired, stage: .ready, stageDetail: "",
                        snapshot: refreshSnapshot, supervision: .running)
    expect(recoveryModel.dailySwitchMessage == nil, "pause suppresses a stale source refresh wait")
    automaticDesired.paused = false
    automaticDesired.timeMode = .auto
    recoveryModel.apply(desired: automaticDesired, stage: .ready, stageDetail: "",
                        snapshot: pendingSnapshot, supervision: .backoff)
    expect(recoveryModel.dailySwitchMessage == nil, "lost service must not advertise stale pending work")

    automaticDesired.timeMode = .fixed(.evening)
    var transitionSnapshot = RuntimeSnapshot(state: .playing, currentClip: "A.R1.1730",
        transitionClip: "transition://A/1200->1730")
    recoveryModel.apply(desired: automaticDesired, stage: .ready, stageDetail: "",
                        snapshot: transitionSnapshot, supervision: .running)
    expect(recoveryModel.dailySwitchMessage == "正在切换日常光照",
           "actual transition is explained even when the target is a fixed time")
    transitionSnapshot.transitionClip = nil
    recoveryModel.apply(desired: automaticDesired, stage: .ready, stageDetail: "",
                        snapshot: transitionSnapshot, supervision: .running)
    expect(recoveryModel.dailySwitchMessage == nil, "entering the real loop clears the transition hint")
    transitionSnapshot.transitionClip = "transition://A/1200->1730"
    automaticDesired.paused = true
    recoveryModel.apply(desired: automaticDesired, stage: .ready, stageDetail: "",
                        snapshot: transitionSnapshot, supervision: .running)
    expect(recoveryModel.dailySwitchMessage == nil, "paused retained transition must not claim active switching")
    automaticDesired.paused = false
    automaticDesired.timeMode = .auto
    transitionSnapshot.pendingDailyTime = .night
    recoveryModel.apply(desired: automaticDesired, stage: .ready, stageDetail: "",
                        snapshot: transitionSnapshot, supervision: .running)
    expect(recoveryModel.dailySwitchMessage == "本段结束后切换至夜晚",
           "new automatic intent retains priority while the current transition finishes")

    let dailyModel = ControlCenterModel()
    dailyModel.resourceConfigured = true
    let dayKey = ContentKey(scene: .a, outfit: .r1, time: .noon)
    let sparseKey = ContentKey(scene: .b, outfit: .r2, time: .night)
    var dailyDesired = DesiredState(timeMode: .fixed(.noon), paused: true)
    let dailySnapshot = RuntimeSnapshot(state: .paused, dailyContentKeys: [dayKey, sparseKey])
    dailyModel.apply(desired: dailyDesired, stage: .ready, stageDetail: "",
                     snapshot: dailySnapshot, supervision: .running)
    expect(!dailyModel.dailySceneIsEnabled(.b) && !dailyModel.dailyOutfitIsEnabled(.r2)
           && !dailyModel.dailyTimeIsEnabled(.night), "fixed pickers must reject missing exact combinations")
    var dailyChanges: [DesiredState] = []
    dailyModel.onDesiredChange = { dailyChanges.append($0) }
    dailyModel.setTimeMode(.fixed(.night))
    dailyModel.setScene(.b)
    expect(dailyChanges.isEmpty, "settings and control-center setters cannot bypass known missing content")
    dailyModel.selectDailyContent(sparseKey)
    expect(dailyChanges.count == 1 && dailyModel.desired.scene == .b && dailyModel.desired.outfit == .r2
           && dailyModel.desired.timeMode == .fixed(.night), "sparse cross-dimension choice must be one explicit edit")
    var expectedDaily = dailyDesired
    expectedDaily.scene = .b; expectedDaily.outfit = .r2; expectedDaily.timeMode = .fixed(.night)
    expect(dailyModel.desired == expectedDaily, "whole combination selection preserves pause, audio and all other preferences")
    dailyModel.setTimeMode(.auto)
    expect(dailyModel.desired.timeMode == .auto && dailyModel.dailyContentNotice?.contains("白天、傍晚") == true,
           "partial automatic coverage remains explicit without claiming that all periods exist")
    dailyDesired.timeMode = .fixed(.night)
    dailyModel.apply(desired: dailyDesired, stage: .failed(.resourceUnavailable), stageDetail: "Missing target",
                     snapshot: dailySnapshot, supervision: .running)
    expect(dailyModel.dailyContentKeys?.count == 2 && dailyModel.dailyContentNotice != nil,
           "a missing current target must keep the found combinations accessible for recovery")
    dailyModel.apply(desired: dailyDesired, stage: .ready, stageDetail: "old root still runs",
                     snapshot: dailySnapshot, supervision: .running, dailyCatalogSelectionFailed: true)
    expect(dailyModel.dailyContentKeys == nil, "old healthy snapshots cannot supply capability for a rejected new selection")
    dailyModel.selectDailyContent(dayKey)
    expect(dailyModel.desired == dailyDesired, "a stale open combination menu cannot apply an invalidated catalog choice")
    for stage in [ResourceStage.validating, .loading, .startingPlayback] {
        dailyModel.apply(desired: dailyDesired, stage: stage, stageDetail: "",
                         snapshot: dailySnapshot, supervision: .running)
        expect(dailyModel.dailyContentKeys == nil, "pending directory replacement must project unknown")
    }
    dailyModel.apply(desired: dailyDesired, stage: .selecting, stageDetail: "",
                     snapshot: dailySnapshot, supervision: .running)
    expect(dailyModel.dailyContentKeys?.count == 2, "opening a directory picker alone does not invalidate the accepted root")
    dailyModel.apply(desired: dailyDesired, stage: .ready, stageDetail: "",
                     snapshot: dailySnapshot, supervision: .backoff)
    expect(dailyModel.dailyContentKeys == nil, "capability cannot survive a lost Agent generation")
    dailyModel.apply(desired: dailyDesired, stage: .ready, stageDetail: "",
                     snapshot: RuntimeSnapshot(state: .paused), supervision: .running)
    expect(dailyModel.dailyContentKeys == nil && dailyModel.dailyTimeIsEnabled(.night),
           "unknown legacy discovery must not pretend every option is missing")
    dailyModel.apply(desired: dailyDesired, stage: .ready, stageDetail: "",
                     snapshot: RuntimeSnapshot(state: .paused, dailyContentKeys: []), supervision: .running)
    expect(dailyModel.dailyContentKeys == [] && !dailyModel.dailyAutoIsEnabled,
           "a known empty daily set differs from unknown, including ambient-only roots")

    // Ambient discovery is the same confirmed directory read as the daily combinations:
    // unknown is not "none", zero is confirmed empty, and a positive count must never be
    // presented as playback proof.
    dailyModel.apply(desired: dailyDesired, stage: .ready, stageDetail: "",
                     snapshot: RuntimeSnapshot(state: .paused, dailyContentKeys: [dayKey]),
                     supervision: .running)
    expect(dailyModel.dailyAmbientTrackCount == nil
           && dailyModel.dailyResourceSummary == "日常画面 1 组 · 环境声待确认",
           "a snapshot without ambient discovery must stay unknown rather than report none")
    dailyModel.apply(desired: dailyDesired, stage: .ready, stageDetail: "",
                     snapshot: RuntimeSnapshot(state: .paused, dailyContentKeys: [dayKey],
                                               dailyAmbientTrackCount: 22), supervision: .running)
    expect(dailyModel.dailyAmbientTrackCount == 22
           && dailyModel.dailyResourceSummary == "日常画面 1 组 · 环境声 22 段"
           && !dailyModel.dailyResourceSummary.contains("播放"),
           "a positive ambient count is discovery evidence only and must not claim playback")
    dailyModel.apply(desired: dailyDesired, stage: .ready, stageDetail: "",
                     snapshot: RuntimeSnapshot(state: .paused, dailyContentKeys: [dayKey],
                                               dailyAmbientTrackCount: 0), supervision: .running)
    expect(dailyModel.dailyAmbientTrackCount == 0
           && dailyModel.dailyResourceSummary == "日常画面 1 组 · 未找到环境声",
           "a confirmed empty ambient set must differ from unknown")
    // The refreshed catalog is the latest confirmed discovery even while the current video
    // waits for its unit boundary, so its ambient count is reported rather than any retained one.
    dailyModel.apply(desired: dailyDesired, stage: .ready, stageDetail: "",
                     snapshot: RuntimeSnapshot(state: .playing, currentClip: "A.R1.1200",
                                               dailyContentKeys: [dayKey],
                                               dailyAmbientTrackCount: 5, pendingDailyRefresh: true),
                     supervision: .running)
    expect(dailyModel.dailyAmbientTrackCount == 5,
           "a refreshed catalog waiting for the current unit still reports its own ambient discovery")
    // A failed refresh is unknown, not the previously retained successful count.
    dailyModel.apply(desired: dailyDesired, stage: .failed(.resourceUnavailable), stageDetail: "读取失败",
                     snapshot: RuntimeSnapshot(state: .degraded, dailyAssetIssue: .readFailed),
                     supervision: .running)
    expect(dailyModel.dailyAmbientTrackCount == nil
           && dailyModel.dailyResourceSummary == "日常素材待确认",
           "a failed refresh must not reuse the last successful ambient count")
    // Losing the Agent generation invalidates the same discovery.
    dailyModel.apply(desired: dailyDesired, stage: .ready, stageDetail: "",
                     snapshot: RuntimeSnapshot(state: .paused, dailyContentKeys: [dayKey],
                                               dailyAmbientTrackCount: 22), supervision: .backoff)
    expect(dailyModel.dailyAmbientTrackCount == nil,
           "a lost Agent generation cannot keep reporting ambient discovery")

    // Product-excluded daily combinations surface through the existing missing-content flow:
    // the saved intent is preserved without automatic migration, the unsupported key is not part
    // of the projected capability, and the wording points at switching to a supported choice
    // rather than at obtaining new resources.
    let excludedKey = ContentKey(scene: .b, outfit: .r1, time: .evening)
    let admittedNeighbors = [
        ContentKey(scene: .a, outfit: .r1, time: .noon),
        ContentKey(scene: .b, outfit: .r1, time: .noon),
        ContentKey(scene: .b, outfit: .r2, time: .evening),
    ]
    let savedExcluded = DesiredState(scene: .b, outfit: .r1, timeMode: .fixed(.evening))
    dailyModel.apply(desired: savedExcluded, stage: .ready, stageDetail: "",
                     snapshot: RuntimeSnapshot(state: .paused, dailyContentKeys: admittedNeighbors),
                     supervision: .running)
    expect(dailyModel.desired == savedExcluded,
           "an excluded saved intent is not silently migrated to another combination")
    expect(dailyModel.dailyContentKeys?.contains(excludedKey) == false
           && !dailyModel.dailyTimeIsEnabled(.evening),
           "the excluded combination is absent from the projected supported capability")
    expect(dailyModel.dailyContentNotice?.contains("不可用") == true
           && dailyModel.dailyContentNotice?.contains("重新选择资源") != true
           && dailyModel.dailyContentNotice?.contains("下载") != true,
           "excluded wording is concise unavailable wording, not a download invitation")
    expect(!dailyModel.selectDailyContent(excludedKey),
           "the capability path refuses the excluded combination")
    expect(dailyModel.desired == savedExcluded,
           "a refused excluded selection leaves the saved intent byte-for-byte unchanged")
    expect(dailyModel.selectDailyContent(ContentKey(scene: .b, outfit: .r1, time: .noon))
           && dailyModel.desired.scene == .b && dailyModel.desired.outfit == .r1
           && dailyModel.desired.timeMode == .fixed(.noon),
           "an admitted neighboring time remains an explicit switch target")

    // The visual background chooser is background-only: it changes scene/outfit through the same
    // ordinary desired-state pipeline while preserving the user's automatic/fixed daypart choice.
    var backgroundAutoIntent = dailyDesired
    backgroundAutoIntent.timeMode = .auto
    dailyModel.apply(desired: backgroundAutoIntent, stage: .ready, stageDetail: "",
                     snapshot: RuntimeSnapshot(state: .paused, dailyContentKeys: admittedNeighbors),
                     supervision: .running)
    let changesBeforeBackground = dailyChanges.count
    expect(dailyModel.selectDailyBackground(ContentKey(scene: .b, outfit: .r2, time: .evening))
           && dailyModel.desired.timeMode == .auto
           && dailyModel.desired.scene == .b && dailyModel.desired.outfit == .r2,
           "a background-only choice must preserve automatic time switching")
    expect(dailyChanges.count == changesBeforeBackground + 1,
           "a background-only choice is exactly one ordinary desired-state edit")
    expect(!dailyModel.selectDailyBackground(excludedKey)
           && dailyModel.desired.timeMode == .auto,
           "a background-only choice refuses an undiscovered combination and keeps the daypart mode")
    dailyModel.setTimeFixed(.evening)
    expect(dailyModel.selectDailyBackground(ContentKey(scene: .b, outfit: .r2, time: .evening))
           && dailyModel.desired.timeMode == .fixed(.evening),
           "a background-only choice preserves an existing fixed daypart")

    var autoExcludedIntent = savedExcluded
    autoExcludedIntent.timeMode = .auto
    dailyModel.apply(desired: autoExcludedIntent, stage: .ready, stageDetail: "",
                     snapshot: RuntimeSnapshot(state: .paused, dailyContentKeys: admittedNeighbors),
                     supervision: .running)
    expect(dailyModel.dailyAutoIsEnabled
           && dailyModel.dailyContentNotice?.contains("傍晚") == true
           && dailyModel.dailyContentNotice?.contains("夜晚") == true,
           "automatic mode stays available for admitted periods and discloses the excluded ones")

    let permissionMessages = ["Access denied at /private/synthetic-media", "无法打开受限目录"].map {
        PerformanceBrowserModel.scanFailureMessage(NSError(
            domain: NSCocoaErrorDomain, code: 257,
            userInfo: [NSLocalizedDescriptionKey: $0, NSFilePathErrorKey: "/private/synthetic-media"]))
    }
    expect(permissionMessages[0] == permissionMessages[1]
           && permissionMessages[0].contains("目录权限")
           && permissionMessages[0].contains("重新检查")
           && permissionMessages[0].contains("选择其他目录"),
           "permission recovery must depend on Cocoa code 257, not localized text")
    expect([CocoaError.Code.fileNoSuchFile, .fileReadNoSuchFile].allSatisfy {
        let message = PerformanceBrowserModel.scanFailureMessage(
            NSError(domain: NSCocoaErrorDomain, code: $0.rawValue))
        return message.contains("已移动或不存在") && message.contains("重新选择目录")
    }, "both missing-file codes must direct the user to select the moved or missing directory again")
    let unknownScanMessage = PerformanceBrowserModel.scanFailureMessage(NSError(
        domain: "SyntheticScanError", code: 257,
        userInfo: [NSLocalizedDescriptionKey: "RAW_SCAN_SENTINEL", NSFilePathErrorKey: "/private/synthetic-media"]))
    expect(unknownScanMessage.contains("目录可访问") && unknownScanMessage.contains("重新检查")
           && unknownScanMessage.contains("选择其他目录") && !unknownScanMessage.contains("目录权限"),
           "an unknown error domain must use general recovery even when its code is 257")
    expect(!unknownScanMessage.contains("RAW_SCAN_SENTINEL")
           && !unknownScanMessage.contains("/private/synthetic-media")
           && !permissionMessages[0].contains("/private/synthetic-media"),
           "scan guidance must not expose raw descriptions or UserInfo paths")

    // Resolve a real bundled manifest entry, but never bind, stat, verify or play media.
    // The synthetic root is only UI state; the coordinator owns scan execution.
    let browser = PerformanceBrowserModel()
    do {
        let library = try PerformanceLibrary.bundled()
        browser.library = library
        browser.root = "/synthetic/bside-regression-only"
        browser.serviceReady = true
        browser.desired = DesiredState(timeMode: .fixed(.noon))
        browser.presentation = .sidePerformance
        if let track = library.manifest.tracks.first(where: {
            $0.variants.contains { $0.lighting == .daylight && $0.presentation == .sidePerformance }
        }) {
            browser.selectedID = track.id
            expect(browser.selection(track.id) != nil,
                   "the metadata fixture must resolve the explicitly selected daylight side view")
            browser.scanning = true
            let scanningProblem = browser.selectionProblem
            expect(scanningProblem == "正在检查素材目录…",
                   "an active scan must block playback with in-progress guidance")

            browser.scanning = false
            browser.scanned = false
            let scanError = "无法访问所选文件夹"
            browser.scanFailure = scanError
            expect(browser.selectionProblem?.contains(scanError) == true
                   && browser.selectionProblem != scanningProblem,
                   "a completed failed scan must expose its error instead of claiming progress")

            browser.scanFailure = nil
            browser.scanning = true
            expect(browser.selectionProblem == scanningProblem,
                   "retry must replace the stale failure with the current scan state")
            browser.scanning = false
            browser.scanned = true
            expect(browser.selectionProblem == nil,
                   "successful retry must restore selection eligibility for available metadata")

            // Selection and command intent are not runtime confirmation. The separate
            // session footer must not claim playback from an absent/previous report.
            if let variant = browser.selection(track.id) {
                let session = PerformanceSession(id: "control-layout-current", variant: variant)
                browser.sessionState.start(session)
                expect(browser.sessionStatus == "等待播放器确认",
                       "starting intent alone must not be presented as confirmed playback")
                browser.report = PerformanceReport(sessionID: "control-layout-old", state: .playing)
                expect(browser.sessionStatus == "等待播放器确认",
                       "a previous session's playing report must not describe the current session")
                browser.report = PerformanceReport(sessionID: session.id, state: .playing)
                browser.selectedID = library.manifest.tracks.first { $0.id != track.id }?.id
                expect(browser.sessionStatus == "播放中" && browser.sessionTitle == track.title,
                       "browsing another track must not relabel the active reported performance")
                browser.report = PerformanceReport(sessionID: session.id, state: .paused)
                expect(browser.sessionStatus == "已暂停",
                       "the footer must show the Agent's actual paused state even if intent differs")
                browser.selectedID = track.id
            }

            // A candidate filter composes with search and the current variant. An empty
            // missing-file map is not evidence until its directory scan has succeeded.
            let unfilteredIDs = browser.rows.map(\.id)
            browser.onlyFound = true
            browser.scanned = false
            expect(browser.rows.isEmpty, "unscanned metadata must never appear as found")
            browser.scanned = true
            browser.scanning = true
            expect(browser.rows.isEmpty, "rescan must not expose the previous directory's candidates")
            browser.scanning = false
            browser.scanFailure = "synthetic scan failure"
            expect(browser.rows.isEmpty, "failed scans must not expose stale candidates")
            browser.scanFailure = nil
            browser.root = nil
            expect(browser.rows.isEmpty, "a missing root must not expose stale candidates")
            browser.root = "/synthetic/bside-regression-only"

            if let candidate = browser.selection(track.id) {
                browser.unavailable = Dictionary(uniqueKeysWithValues: library.manifest.tracks.flatMap {
                    $0.variants.map { ($0.id, "synthetic missing file") }
                })
                browser.unavailable.removeValue(forKey: candidate.variantID.rawValue)
                browser.serviceReady = false
                expect(browser.rows.map(\.id) == [track.id] && browser.selectionProblem != nil,
                       "found means a file candidate, independently of player readiness")
                browser.search = track.subtitle
                expect(browser.rows.map(\.id) == [track.id], "subtitle search must compose with the candidate filter")
                browser.search = "NO_MATCH_REGRESSION_ONLY"
                expect(browser.rows.isEmpty, "search must also restrict found candidates")
                browser.search = ""
                browser.presentation = .portraitPerformance
                expect(browser.rows.isEmpty, "another camera must not reuse the side-view candidate")
                browser.presentation = .sidePerformance
                browser.desired.timeMode = .fixed(.night)
                expect(browser.rows.isEmpty, "another lighting must not reuse the daylight candidate")
                browser.desired.timeMode = .fixed(.noon)
                expect(browser.rows.map(\.id) == [track.id], "returning to the found variant must restore its row")
                browser.presentation = .portraitPerformance
                browser.unavailable = [:]
                expect(browser.rows.allSatisfy { browser.selection($0.id) != nil }
                       && browser.rows.count < unfilteredIDs.count,
                       "unsupported variants must be excluded even with no missing-file entries")
                browser.onlyFound = false
                expect(browser.rows.map(\.id) == unfilteredIDs,
                       "showing all must restore the complete list without altering variant selection")
                expect(browser.selectedID == track.id && browser.sessionStatus == "已暂停"
                       && browser.sessionTitle == track.title,
                       "filtering and browsing must not mutate selection or the active performance")
                browser.presentation = .sidePerformance
                browser.serviceReady = true
            }

            browser.library = nil
            expect(browser.selectionProblem?.contains("清单不可用") == true,
                   "missing bundled metadata must block playback with a manifest-specific reason")
            browser.library = library
            browser.serviceReady = false
            let serviceProblem = browser.selectionProblem
            expect(serviceProblem?.contains("上方") == true
                   && serviceProblem?.contains("导入日常素材") == false,
                   "an unavailable service must point to actual recovery guidance, not demand another import")
        } else {
            expect(false, "bundled metadata must provide a daylight side-view regression fixture")
        }
    } catch {
        expect(false, "bundled metadata must load for the browser regression: \(error)")
    }

    runPerformanceDirectoryRegression(expect: expect)
    runPerformanceListeningRegression(expect: expect)
    runPerformanceRowPlaybackRegression(expect: expect)
    runPerformanceQueueRegression(expect: expect)
    runPerformanceScenarioStopRegression(expect: expect)
    runPerformanceDisplayMetadataRegression(expect: expect)
    runUnifiedWindowRegression(expect: expect)
    // Notch quick-control panel: pure geometry, hover/pin/shutdown ownership, shared-model actions.
    runNotchControlRegression(expect: expect)
    runLocalSongLibraryRegression(expect: expect)
    runLocalSongControllerRegression(expect: expect)
    runDailyDirectoryRegression(expect: expect)
    runPlaybackHistoryRegression(expect: expect)
    runSongPlaybackHistoryRegression(expect: expect)
    runMediaRetentionRegression(expect: expect)
    runStudyTimerRegression(expect: expect)
    runDailyActivityRecommendationRegression(expect: expect)
    // ADR-024 background chooser: candidate enumeration, one-request preview and stale rejection.
    runDailyBackgroundChooserRegression(expect: expect)
    // Daily-candidate startup slice: child-Agent support environment + duplicate/conflict policy.
    runStartupSliceRegression(expect: expect)
    // Use-case presentation: copy keyed by stable id, unknown ids fall back to the stored name.
    runProfilePresentationRegression(expect: expect)
    for failure in failures { print("ControlStateRegression FAIL: \(failure)") }
    print("ControlStateRegression: \(failures.isEmpty ? "PASS" : "FAIL") (\(checks) checks)")
    return failures.isEmpty ? 0 : 1
}

/// Presentation-only regression: the 使用场景 rows must read their copy from the STABLE profile
/// id, so a legacy English stored name still shows the current Chinese labels, an unknown future
/// id keeps its stored name instead of inventing an effect, and manual volume still maps to the
/// neutral 手动调节 explanation. No SwiftUI view is instantiated and no behavior is exercised.
private func runProfilePresentationRegression(expect: (Bool, String) -> Void) {
    // A persisted legacy profile really does carry the old English name ("Normal").
    let legacyNormal = Profile(id: "normal", name: "Normal", musicFactor: 1, ambientFactor: 1)
    let normal = ProfilePresentationCatalog.presentation(for: legacyNormal)
    expect(normal.title == "日常陪伴"
           && normal.detail == "休息、听歌时使用。音乐和环境音保持当前音量，画面继续播放。",
           "a legacy English stored name must render the current 日常陪伴 copy from the stable id")

    expect(ProfilePresentationCatalog.presentation(for: .quiet).detail
           == "阅读、聊天时使用。音乐和环境音降至当前设置的30%，画面继续播放。",
           "quiet must state the 30% factor relative to the current settings")
    expect(ProfilePresentationCatalog.presentation(for: .coding).detail
           == "写作、编程时使用。音乐和环境音降至当前设置的15%，画面继续播放。",
           "coding must state the 15% factor relative to the current settings")
    expect(ProfilePresentationCatalog.presentation(for: .silent).title == "无声画面"
           && ProfilePresentationCatalog.presentation(for: .silent).detail.contains("静音"),
           "silent must stay presented as muted picture-only use")
    expect(ProfilePresentationCatalog.presentation(for: .movie).detail
           == "开会、看视频时使用。日常画面和歌曲一起暂停，所有声音静音；切换其他场景后按当前暂停状态恢复。",
           "movie must explain the shared pause and restore-on-switch behavior")
    let custom = ProfilePresentationCatalog.presentation(for: .custom)
    expect(custom.title == "手动调节" && custom.isCustom
           && custom.effect == "按你设置的音量播放，不额外降低音量。",
           "custom must stay a neutral manual-volume explanation")

    // A future id is not guessed: it keeps its stored name and says the effect is not described.
    let future = Profile(id: "focus-2030", name: "Focus 2030", musicFactor: 0.5, ambientFactor: 0.5)
    let futurePresentation = ProfilePresentationCatalog.presentation(for: future)
    expect(futurePresentation.title == "Focus 2030" && !futurePresentation.isCustom
           && futurePresentation.effect != custom.effect,
           "an unknown future id must fall back to the stored name, not reuse a built-in label")
    expect(ProfilePresentationCatalog.presentation(id: "future", storedName: "  ").title
           == "未命名使用场景",
           "an unknown id with a blank stored name must still render a truthful placeholder")

    // The current unknown id must remain visible in the options list, ordered for comparison.
    let withFuture = ProfilePresentationCatalog.visibleOptions(selected: future, base: Profile.builtIn)
    expect(withFuture.count == Profile.builtIn.count + 1 && withFuture.last?.id == future.id,
           "an unknown current id must remain visible in the option list")
    let customOptions = ProfilePresentationCatalog.visibleOptions(
        selected: .custom, base: Profile.builtIn + [.custom])
    expect(customOptions.map(\.id) == ["normal", "quiet", "coding", "silent", "movie", "custom"],
           "use-case rows must read loudest-to-paused with 手动调节 last")
}
