// Real recommendation projection plus the real daily-selection command. No media, player,
// preferences or Agent: only existing in-memory model paths are exercised.
import Foundation
import BSideCore

/// Absolute instant for a Beijing wall-clock time on a fixed day. Beijing has no DST, so this
/// is deterministic and independent of the Mac's own zone (the same rule BeijingClock uses).
private func beijingInstant(hour: Int, minute: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    return calendar.date(from: DateComponents(year: 2026, month: 1, day: 15,
                                              hour: hour, minute: minute))!
}

private func dailyKey(_ scene: Scene, _ outfit: Outfit, _ time: TimeOfDay) -> ContentKey {
    ContentKey(scene: scene, outfit: outfit, time: time)
}

func runDailyActivityRecommendationRegression(expect: (Bool, String) -> Void) {
    let reviewedNoon = dailyKey(.a, .r1, .noon)
    let reviewedEvening = dailyKey(.a, .r1, .evening)
    let reviewedNight = dailyKey(.a, .r1, .night)
    let reviewedR2Evening = dailyKey(.a, .r2, .evening)
    let qualifiedSources = [reviewedNoon, reviewedEvening, reviewedNight, reviewedR2Evening]
    let r1State = DesiredState(scene: .b, outfit: .r1, timeMode: .fixed(.noon),
                               masterVolume: 0.42, musicVolume: 0.31, ambientVolume: 0.22,
                               musicMuted: true, ambientMuted: false, paused: true, profile: .quiet)

    // 1) Evidence eligibility: exactly the four reviewed whole sources are offered, each derived
    // from the reviewed inventory, with the per-version supported view derived (never hardcoded).
    // ADR-024: the offerable set is no longer a user-visible card list (backgrounds are chosen
    // visually), so these assertions pin the underlying catalog truth and its ordinary wording.
    let cards = DailyActivityRecommendationCatalog.recommendations
    expect(cards.count == 4 && cards.map(\.target) == qualifiedSources
           && Set(cards.map(\.target)).count == 4,
           "exactly the four reviewed whole sources must remain offerable")
    expect(cards.allSatisfy { !$0.timeLabel.isEmpty },
           "every offerable combination must carry an ordinary daypart word")
    expect(DailyActivityRecommendationCatalog.qualifiedTimes(for: .r1) == [.noon, .evening, .night]
           && DailyActivityRecommendationCatalog.qualifiedTimes(for: .r2) == [.evening]
           && DailyActivityRecommendationCatalog.qualifiedTimes(for: .r3).isEmpty,
           "R1 supports all three times, R2 only sunset, R3 nothing")
    // No primary-surface wording may expose an internal numbered material id (ADR-024), and no
    // visible copy may promise desk-only playback, a loop or acceptance vocabulary.
    let primaryWording = cards.map(\.timeLabel).joined()
    expect(!primaryWording.contains("素材组") && !primaryWording.contains("日常版本")
           && !primaryWording.contains("仅书桌") && !primaryWording.contains("已审查")
           && !primaryWording.contains("校验") && !primaryWording.contains("循环"),
           "no primary daily copy may expose material ids or acceptance vocabulary")
    expect(qualifiedSources.allSatisfy { target in
               DailyActivityID.allCases.allSatisfy {
                   DailyActivityCatalog.entry(for: target, activityID: $0) != nil
               }
           },
           "every offered combination must be backed by its own reviewed entry points")

    // 1b) The old two-choice model must not resurrect: no recommendation for an unqualified source.
    expect(DailyActivityRecommendationCatalog.recommendation(for: dailyKey(.a, .r2, .noon)) == nil
           && DailyActivityRecommendationCatalog.recommendation(for: dailyKey(.a, .r3, .evening)) == nil
           && DailyActivityRecommendationCatalog.recommendation(for: dailyKey(.b, .r1, .evening)) == nil,
           "an unreviewed source is never offered and never substituted")
    expect(DailyActivityRecommendationCatalog.isQualified(reviewedR2Evening)
           && !DailyActivityRecommendationCatalog.isQualified(dailyKey(.a, .r2, .night)),
           "qualification is per exact source, not per version")

    // 2) Presentation default uses the existing time resolution: the initial tab is the actual
    // resolved desired time. No timer/polling, no media change.
    let model = DailyActivityRecommendationModel()
    var applied: [ContentKey] = []
    model.onApply = { applied.append($0); return true }
    model.update(desired: r1State, resourceReady: true, dailyContentKeys: qualifiedSources,
                 performanceActive: false, pendingSwitchMessage: nil)
    model.prepareForPresentation(now: beijingInstant(hour: 12, minute: 0))
    expect(model.timeTab == .noon && model.desired == r1State && applied.isEmpty,
           "a fixed noon desired time must open on the daytime tab without any change")

    var fixedNight = r1State
    fixedNight.timeMode = .fixed(.night)
    model.update(desired: fixedNight, resourceReady: true, dailyContentKeys: qualifiedSources,
                 performanceActive: false, pendingSwitchMessage: nil)
    model.prepareForPresentation(now: beijingInstant(hour: 12, minute: 0))
    expect(model.timeTab == .night,
           "a saved fixed night choice must open on the night tab even at Beijing noon")

    var fixedEvening = r1State
    fixedEvening.timeMode = .fixed(.evening)
    model.update(desired: fixedEvening, resourceReady: true, dailyContentKeys: qualifiedSources,
                 performanceActive: false, pendingSwitchMessage: nil)
    model.prepareForPresentation(now: beijingInstant(hour: 22, minute: 0))
    expect(model.timeTab == .evening,
           "a saved fixed evening choice must open on the sunset tab even at Beijing night")

    var automatic = r1State
    automatic.timeMode = .auto
    model.update(desired: automatic, resourceReady: true, dailyContentKeys: qualifiedSources,
                 performanceActive: false, pendingSwitchMessage: nil)
    model.prepareForPresentation(now: beijingInstant(hour: 22, minute: 0))
    expect(model.timeTab == .night, "automatic Beijing night must open on the night tab")
    model.prepareForPresentation(now: beijingInstant(hour: 18, minute: 0))
    expect(model.timeTab == .evening, "automatic Beijing evening must open on the sunset tab")
    model.prepareForPresentation(now: beijingInstant(hour: 2, minute: 0))
    expect(model.timeTab == .night, "automatic Beijing after-midnight must open on the night tab")
    model.prepareForPresentation(now: beijingInstant(hour: 9, minute: 0))
    expect(model.timeTab == .noon, "automatic Beijing daytime must open on the daytime tab")
    expect(model.desired == automatic && applied.isEmpty,
           "presentation defaults must never change desired state or apply media")
    // A state refresh alone must not silently overwrite an explicit browsing tab.
    model.timeTab = .night
    model.update(desired: automatic, resourceReady: true, dailyContentKeys: qualifiedSources,
                 performanceActive: false, pendingSwitchMessage: nil)
    expect(model.timeTab == .night,
           "an update refresh must not re-select the tab until the next explicit opening")

    // 2c) Browsing is presentation-only: changing the tab must not apply or mutate state.
    model.timeTab = .evening
    expect(model.desired == automatic && applied.isEmpty && model.lastAppliedTarget == nil,
           "switching the browsing tab must not change desired state or apply anything")

    // 2d) Direct exact three-way mapping between the browsing tabs and the official times, in both
    // directions, plus the initial presentation seeding. The tab tags ("noon"/"evening"/"night")
    // are deliberately NOT `TimeOfDay` raw values ("1200"/"1730"/"2000"), so a raw-value round trip
    // or a fallback would silently collapse tabs onto one time.
    let tabTimes: [(DailyActivityTimeTab, TimeOfDay)] =
        [(.noon, .noon), (.evening, .evening), (.night, .night)]
    expect(DailyActivityTimeTab.allCases.count == 3
           && DailyActivityTimeTab.allCases.map(\.time) == [.noon, .evening, .night],
           "the three browsing tabs must map to exactly noon, sunset and night")
    expect(tabTimes.allSatisfy { $0.0.time == $0.1 }
           && tabTimes.allSatisfy { DailyActivityRecommendationModel.tab(for: $0.1) == $0.0 }
           && DailyActivityTimeTab.allCases.allSatisfy {
               DailyActivityRecommendationModel.tab(for: $0.time) == $0
           },
           "the tab/time mapping must be an exact three-way bijection without fallback")
    expect(DailyActivityTimeTab.allCases.map(\.rawValue) == ["noon", "evening", "night"]
           && DailyActivityTimeTab.allCases.map(\.time.rawValue) == ["1200", "1730", "2000"],
           "the tab tags must stay distinct from the official numeric time identifiers")
    for (tab, time) in tabTimes {
        var fixed = r1State
        fixed.timeMode = .fixed(time)
        let presented = DailyActivityRecommendationModel()
        presented.update(desired: fixed, resourceReady: true, dailyContentKeys: qualifiedSources,
                         performanceActive: false, pendingSwitchMessage: nil)
        presented.prepareForPresentation(now: beijingInstant(hour: 12, minute: 0))
        expect(presented.timeTab == tab && presented.timeTab.time == time,
               "the initial presentation time must open the exact \(time.controlCenterLabel) tab")
    }

    // 3) Readiness/session gating for the whole-source cards. Pause is intent the ordinary
    // command preserves, not a block.
    model.update(desired: automatic, resourceReady: true, dailyContentKeys: [reviewedEvening],
                 performanceActive: false, pendingSwitchMessage: nil)
    expect(model.canApply(reviewedEvening), "the reviewed combination with a ready service must be applicable")

    model.update(desired: automatic, resourceReady: true, dailyContentKeys: [reviewedEvening],
                 performanceActive: true, pendingSwitchMessage: nil)
    expect(!model.canApply(reviewedEvening) && model.applyRecommendation(reviewedEvening) == false
           && applied.isEmpty,
           "an active performance or queue must block the daily action")

    model.update(desired: automatic, resourceReady: false, dailyContentKeys: [reviewedEvening],
                 performanceActive: false, pendingSwitchMessage: nil)
    expect(!model.canApply(reviewedEvening) && model.applyRecommendation(reviewedEvening) == false
           && applied.isEmpty,
           "an unready daily resource or service must block the daily action")

    model.update(desired: automatic, resourceReady: true, dailyContentKeys: nil,
                 performanceActive: false, pendingSwitchMessage: nil)
    expect(!model.canApply(reviewedEvening) && model.applyUnavailableReason(for: reviewedEvening) != nil,
           "undiscovered daily content must block the daily action")

    model.update(desired: automatic, resourceReady: true, dailyContentKeys: [reviewedNoon],
                 performanceActive: false, pendingSwitchMessage: nil)
    expect(!model.canApply(reviewedEvening)
           && model.applyUnavailableReason(for: reviewedEvening) == "当前素材目录缺少这段日常。",
           "each card needs its own discovered combination, not any daily content")

    // 3b) The other same-version cards keep the same guards: a discovered sunset unit must not
    // unlock them, and each has its own truthful missing-target explanation.
    for target in [reviewedNoon, reviewedNight] {
        model.update(desired: automatic, resourceReady: true, dailyContentKeys: [reviewedEvening],
                     performanceActive: false, pendingSwitchMessage: nil)
        expect(!model.canApply(target) && model.applyRecommendation(target) == false && applied.isEmpty
               && model.applyUnavailableReason(for: target) == "当前素材目录缺少这段日常。",
               "a card must require its own discovered source: \(target)")
        model.update(desired: automatic, resourceReady: true, dailyContentKeys: [target],
                     performanceActive: false, pendingSwitchMessage: nil)
        expect(model.canApply(target) && model.applyUnavailableReason(for: target) == nil,
               "the discovered combination must unlock only its own card: \(target)")
    }

    // 3b-ii) A combination whose outfit differs from the manually selected one is never applied
    // behind the user's back: it stays unavailable with a concise reason that points at the
    // chooser, and the manual selection is preserved with no automatic version switch.
    model.update(desired: automatic, resourceReady: true, dailyContentKeys: [reviewedR2Evening],
                 performanceActive: false, pendingSwitchMessage: nil)
    expect(!model.canApply(reviewedR2Evening)
           && model.applyRecommendation(reviewedR2Evening) == false && applied.isEmpty,
           "a combination for a different daily version must never apply while another is selected")
    guard let mismatchReason = model.applyUnavailableReason(for: reviewedR2Evening) else {
        expect(false, "the refused combination must explain itself")
        return
    }
    expect(mismatchReason.contains("更换背景")
           && !mismatchReason.contains(Outfit.r2.rawValue)
           && !mismatchReason.contains(Outfit.r1.rawValue)
           && !mismatchReason.contains("素材组") && !mismatchReason.contains("日常版本"),
           "the mismatch reason must point at the chooser without raw codes or internal ids")
    // The same-version card is unaffected by the different-version card beside it.
    model.update(desired: automatic, resourceReady: true, dailyContentKeys: qualifiedSources,
                 performanceActive: false, pendingSwitchMessage: nil)
    expect(model.canApply(reviewedEvening) && !model.canApply(reviewedR2Evening),
           "only the card matching the manual version stays applicable")

    // 3c) R3 has no reviewed entry: no offer, no automatic version fallback, and the explanation
    // never names an internal id.
    expect(model.noRecommendationMessage == nil,
           "a qualified manual version has no empty-state message")
    for outfit in [Outfit.r3] {
        var other = r1State
        other.outfit = outfit
        model.update(desired: other, resourceReady: true, dailyContentKeys: qualifiedSources,
                     performanceActive: false, pendingSwitchMessage: nil)
        expect(!model.canEnterActivity
               && model.noRecommendationMessage?.contains("不会自动更换背景") == true
               && model.noRecommendationMessage?.contains("素材组") == false
               && model.noRecommendationMessage?.contains("日常版本") == false
               && model.noRecommendationMessage?.contains(outfit.rawValue) == false,
               "a version without reviewed evidence must offer no entry and change nothing")
    }

    // 4) The explicit whole-source action must use the one real daily selection command, changing
    // only scene/outfit/fixed time while preserving pause, audio and every remaining preference.
    let center = ControlCenterModel()
    center.resourceConfigured = true
    let snapshot = RuntimeSnapshot(state: .playing, currentClip: "B.R1.1200",
                                   dailyContentKeys: qualifiedSources)
    center.apply(desired: r1State, stage: .ready, stageDetail: "", snapshot: snapshot,
                 supervision: .running)
    var changes: [DesiredState] = []
    center.onDesiredChange = { changes.append($0) }

    let activity = DailyActivityRecommendationModel()
    activity.onApply = { center.selectDailyContent($0) }
    activity.update(desired: center.desired,
                    resourceReady: center.stage == .ready && center.supervision == .running,
                    dailyContentKeys: center.dailyContentKeys,
                    performanceActive: false,
                    pendingSwitchMessage: center.dailySwitchMessage)
    expect(activity.canApply(reviewedEvening)
           && center.dailyContentKeys?.contains(reviewedEvening) == true,
           "the real daily discovery must make the reviewed evening combination applicable")
    expect(activity.applyRecommendation(reviewedEvening) && changes.count == 1,
           "the explicit action must use the one real daily selection command")
    let changed = changes[0]
    expect(changed.scene == .a && changed.outfit == .r1 && changed.timeMode == .fixed(.evening),
           "the explicit action must change scene, outfit and fixed time to that exact source")
    expect(changed.paused && changed.masterVolume == r1State.masterVolume
           && changed.musicVolume == r1State.musicVolume
           && changed.ambientVolume == r1State.ambientVolume
           && changed.musicMuted == r1State.musicMuted
           && changed.ambientMuted == r1State.ambientMuted
           && changed.profile == r1State.profile
           && changed.desktopMode == r1State.desktopMode
           && changed.pauseVisualOnFullscreen == r1State.pauseVisualOnFullscreen
           && changed.muteAudioOnFullscreen == r1State.muteAudioOnFullscreen,
           "the explicit action must preserve outfit, pause, audio levels and remaining preferences")

    // 4b) A different card (R2/sunset) must run through that same real command and retain every
    // non-target preference, changing only the source coordinates.
    var r2State = r1State
    r2State.outfit = .r2
    let r2Center = ControlCenterModel()
    r2Center.resourceConfigured = true
    let r2Snapshot = RuntimeSnapshot(state: .playing, currentClip: "A.R2.1730",
                                     dailyContentKeys: qualifiedSources)
    r2Center.apply(desired: r2State, stage: .ready, stageDetail: "", snapshot: r2Snapshot,
                   supervision: .running)
    var r2Changes: [DesiredState] = []
    r2Center.onDesiredChange = { r2Changes.append($0) }
    let r2Activity = DailyActivityRecommendationModel()
    r2Activity.onApply = { r2Center.selectDailyContent($0) }
    r2Activity.update(desired: r2Center.desired,
                      resourceReady: r2Center.stage == .ready && r2Center.supervision == .running,
                      dailyContentKeys: r2Center.dailyContentKeys,
                      performanceActive: false,
                      pendingSwitchMessage: r2Center.dailySwitchMessage)
    expect(r2Activity.canApply(reviewedR2Evening)
           && r2Activity.applyRecommendation(reviewedR2Evening) && r2Changes.count == 1,
           "the R2 sunset card must use the one real daily selection command")
    let r2Changed = r2Changes[0]
    expect(r2Changed.scene == .a && r2Changed.outfit == .r2 && r2Changed.timeMode == .fixed(.evening)
           && r2Changed.paused && r2Changed.masterVolume == r2State.masterVolume
           && r2Changed.musicVolume == r2State.musicVolume
           && r2Changed.ambientVolume == r2State.ambientVolume
           && r2Changed.musicMuted == r2State.musicMuted
           && r2Changed.ambientMuted == r2State.ambientMuted
           && r2Changed.profile == r2State.profile,
           "the R2 action must change only the source coordinates while preserving every preference")

    // 4c) Reported defect: with manual R1 selected, clicking the full-source A.R2.1730 card must
    // not change the saved daily version. The card is refused at the real guarded command
    // boundary, so the ordinary selection is never invoked and the persisted desired state keeps
    // its manual outfit. The R2 source IS discovered here, so the refusal is the version guard,
    // not the discovery guard.
    let versionCenter = ControlCenterModel()
    versionCenter.resourceConfigured = true
    versionCenter.apply(desired: r1State, stage: .ready, stageDetail: "",
                        snapshot: RuntimeSnapshot(state: .playing, currentClip: "A.R2.1730",
                                                  dailyContentKeys: qualifiedSources),
                        supervision: .running)
    var versionChanges: [DesiredState] = []
    versionCenter.onDesiredChange = { versionChanges.append($0) }
    let versionModel = DailyActivityRecommendationModel()
    versionModel.onApply = { versionCenter.selectDailyContent($0) }
    versionModel.update(desired: versionCenter.desired,
                        resourceReady: versionCenter.stage == .ready && versionCenter.supervision == .running,
                        dailyContentKeys: versionCenter.dailyContentKeys,
                        performanceActive: false,
                        pendingSwitchMessage: versionCenter.dailySwitchMessage)
    expect(versionCenter.desired.outfit == .r1
           && versionCenter.dailyContentKeys?.contains(reviewedR2Evening) == true,
           "the manual R1 selection and the discovered R2 card must coexist before the click")
    expect(!versionModel.canApply(reviewedR2Evening)
           && versionModel.applyRecommendation(reviewedR2Evening) == false
           && versionChanges.isEmpty && versionCenter.desired.outfit == .r1,
           "the A.R2.1730 card must not change the saved daily version while R1 is selected")
    expect(versionModel.applyUnavailableReason(for: reviewedR2Evening)?.contains("更换背景") == true
           && versionModel.applyUnavailableReason(for: reviewedR2Evening)?.contains("素材组") == false
           && versionModel.applyUnavailableReason(for: reviewedR2Evening)?
               .contains(Outfit.r2.rawValue) == false,
           "the refused combination must explain the mismatch and point at the chooser")
    // The same-version evening card still applies through that same real command.
    expect(versionModel.canApply(reviewedEvening)
           && versionModel.applyRecommendation(reviewedEvening) && versionChanges.count == 1
           && versionChanges[0].outfit == .r1 && versionChanges[0].timeMode == .fixed(.evening),
           "a card matching the manual version must still apply through the same real command")

    // 4d) Mirror direction: with manual R2 selected, every R1 card is refused the same way, and
    // only the R2 card stays applicable.
    let r2GuardModel = DailyActivityRecommendationModel()
    var r2GuardApplied: [ContentKey] = []
    r2GuardModel.onApply = { r2GuardApplied.append($0); return true }
    r2GuardModel.update(desired: r2State, resourceReady: true, dailyContentKeys: qualifiedSources,
                        performanceActive: false, pendingSwitchMessage: nil)
    for target in [reviewedNoon, reviewedEvening, reviewedNight] {
        expect(!r2GuardModel.canApply(target)
               && r2GuardModel.applyRecommendation(target) == false && r2GuardApplied.isEmpty,
               "a manual R2 selection must refuse every R1 combination: \(target)")
        expect(r2GuardModel.applyUnavailableReason(for: target)?.contains("更换背景") == true
               && r2GuardModel.applyUnavailableReason(for: target)?
                   .contains(target.outfit.rawValue) == false,
               "the refused combination must point at the chooser without raw codes: \(target)")
    }
    expect(r2GuardModel.canApply(reviewedR2Evening)
           && r2GuardModel.applyRecommendation(reviewedR2Evening) && r2GuardApplied.count == 1,
           "the card matching the manual R2 version must stay applicable")

    // 5) Post-apply reporting: the requested setting plus existing pending/paused state,
    // never a fabricated playback success. A refused guarded command reports nothing.
    let refusing = DailyActivityRecommendationModel()
    refusing.onApply = { _ in false }
    refusing.update(desired: r1State, resourceReady: true, dailyContentKeys: qualifiedSources,
                    performanceActive: false, pendingSwitchMessage: nil)
    expect(refusing.applyRecommendation(reviewedEvening) == false && refusing.appliedStatus == nil,
           "a refused guarded application must not report an applied setting")

    activity.update(desired: changed, resourceReady: true, dailyContentKeys: qualifiedSources,
                    performanceActive: false, pendingSwitchMessage: "本段结束后切换至傍晚")
    expect(activity.appliedStatus?.contains("已请求切换背景：傍晚") == true
           && activity.appliedStatus?.contains("本段结束后切换至傍晚") == true
           && activity.appliedStatus?.contains("播放") == false
           && activity.appliedStatus?.contains("R1") == false
           && activity.appliedStatus?.contains("素材组") == false,
           "post-apply status must report the ordinary daypart and pending switch, not playback")
    var paused = changed
    paused.paused = true
    activity.update(desired: paused, resourceReady: true, dailyContentKeys: qualifiedSources,
                    performanceActive: false, pendingSwitchMessage: nil)
    expect(activity.appliedStatus?.contains("全局暂停") == true,
           "post-apply status must report the existing paused state")
    // The daily page line states the real switching policy, never an immediate-play claim.
    expect(activity.backgroundChoiceNotice?.contains("当前全局暂停") == true
           && activity.backgroundChoiceNotice?.contains("素材组") == false
           && activity.backgroundChoiceNotice?.contains("日常版本") == false,
           "the daily page notice must state the real paused consequence without internal ids")
    var resumable = paused
    resumable.paused = false
    activity.update(desired: resumable, resourceReady: true, dailyContentKeys: qualifiedSources,
                    performanceActive: false, pendingSwitchMessage: nil)
    expect(activity.backgroundChoiceNotice?.contains("本段结束后") == true,
           "the daily page must state that a background change takes effect after the current unit")
    // Browsing another tab must not mislabel the last applied source.
    activity.timeTab = .night
    expect(activity.appliedStatus?.contains("已请求切换背景：傍晚") == true
           && activity.appliedStatus?.contains("夜晚") == false,
           "browsing another tab must not relabel the last applied source")
    // A real source change clears the obsolete applied status.
    var changedElsewhere = paused
    changedElsewhere.scene = .c
    activity.update(desired: changedElsewhere, resourceReady: true, dailyContentKeys: qualifiedSources,
                    performanceActive: false, pendingSwitchMessage: nil)
    expect(activity.appliedStatus == nil, "a source change must clear the obsolete applied status")

    // 6) Identity: the raw/persisted keys are unchanged; primary surfaces use the ordinary
    // daypart, and the numbered material names survive only as a diagnostic projection.
    expect(Scene.a.rawValue == "A" && Scene.b.rawValue == "B" && Scene.c.rawValue == "C"
           && Outfit.r1.rawValue == "R1" && Outfit.r2.rawValue == "R2" && Outfit.r3.rawValue == "R3",
           "the persisted raw scene/outfit identities must not change")
    expect(reviewedEvening.daypartLabel == "傍晚"
           && !reviewedEvening.daypartLabel.contains("素材组")
           && !reviewedEvening.daypartLabel.contains("日常版本"),
           "the primary daypart label must never expose an internal material id")
    let encodedKey = String(data: (try? JSONEncoder().encode(reviewedEvening)) ?? Data(),
                            encoding: .utf8) ?? ""
    expect(encodedKey.contains("\"A\"") && encodedKey.contains("\"R1\"") && encodedKey.contains("\"1730\""),
           "the persisted ContentKey encoding must keep the raw scene/outfit/time values")
    expect(reviewedEvening.description == "A.R1.1730",
           "the diagnostic ContentKey description must keep the raw identity")
    let statusCenter = ControlCenterModel()
    statusCenter.apply(desired: DesiredState(scene: .a, outfit: .r1, timeMode: .fixed(.evening)),
                       stage: .ready, stageDetail: "", snapshot: nil, supervision: .idle)
    expect(statusCenter.subtitle == "固定傍晚"
           && !statusCenter.subtitle.contains("R1")
           && !statusCenter.subtitle.contains("素材组")
           && !statusCenter.subtitle.contains("日常版本"),
           "the Control Center status line must show the ordinary daypart without internal ids")
    let autoCenter = ControlCenterModel()
    autoCenter.apply(desired: DesiredState(scene: .a, outfit: .r1, timeMode: .auto),
                     stage: .ready, stageDetail: "", snapshot: nil, supervision: .idle)
    expect(autoCenter.subtitle.contains("按北京时间")
           && autoCenter.subtitle.contains("现在")
           && !autoCenter.subtitle.contains("素材组"),
           "the automatic status line must state the clock policy and the current daypart")

    // 7) Explicit activity entry: the entry target resolves material group A + CURRENT manual
    // outfit + BROWSED time, and every reviewed source is reachable.
    expect(DailyActivityEntryChoice.allCases.map(\.activityID) == [.desk, .rest],
           "the companion window must offer exactly the two reviewed entry activities")
    expect(DailyActivityEntryChoice.allCases.allSatisfy {
               !$0.title.contains("阅读") && !$0.title.contains("自习")
           },
           "entry wording must not invent reading/study activity")

    let entryModel = DailyActivityRecommendationModel()
    var sent: [DailyActivityRequest] = []
    entryModel.onStartActivity = { sent.append($0); return true }
    entryModel.update(desired: r1State, resourceReady: true, dailyContentKeys: qualifiedSources,
                      performanceActive: false, pendingSwitchMessage: nil)
    entryModel.timeTab = .noon
    expect(entryModel.entrySourceKey == reviewedNoon && entryModel.canEnterActivity
           && entryModel.entryUnavailableReason == nil,
           "R1 with a ready service must resolve the browsed noon source")
    expect(entryModel.startActivity(.desk) && sent.count == 1,
           "an explicit click must send exactly one entry request")
    let request = sent[0]
    expect(!request.requestID.isEmpty && request.activityID == .desk,
           "each entry request must carry its activity and a fresh request id")
    expect(request.desired.scene == .a && request.desired.outfit == .r1
           && request.desired.timeMode == .fixed(.noon),
           "entry must disclose material group A and fix the browsed time while keeping the manual outfit")
    expect(request.desired.paused && request.desired.masterVolume == r1State.masterVolume
           && request.desired.musicVolume == r1State.musicVolume
           && request.desired.ambientVolume == r1State.ambientVolume
           && request.desired.musicMuted == r1State.musicMuted
           && request.desired.ambientMuted == r1State.ambientMuted
           && request.desired.profile == r1State.profile
           && request.desired.pauseVisualOnFullscreen == r1State.pauseVisualOnFullscreen
           && request.desired.muteAudioOnFullscreen == r1State.muteAudioOnFullscreen,
           "entry must carry the complete current desired state atomically (pause/volume/profile)")
    expect(entryModel.activityState == .verifying
           && entryModel.activityStatus?.contains("正在准备进入白天") == true
           && entryModel.activityStatus?.contains("书桌日常") == true
           && entryModel.activityStatus?.contains("播放") != true
           && entryModel.activityStatus?.contains("素材组") == false
           && entryModel.activityStatus?.contains("日常版本") == false,
           "an outstanding entry reports its actual daypart and pending state, never internal ids")

    // Stale reports cannot change the latest request; only its own report does.
    entryModel.receiveActivityReport(DailyActivityReport(requestID: "stale", state: .failed, detail: "x"))
    expect(entryModel.activityState == .verifying, "a stale report must be ignored")
    entryModel.receiveActivityReport(DailyActivityReport(requestID: request.requestID, state: .applied))
    expect(entryModel.activityState == .applied
           && entryModel.activityStatus?.contains("已选择白天的书桌日常") == true
           && entryModel.activityStatus?.contains("恢复后从进入点") != true
           && entryModel.activityStatus?.contains("素材组") == false,
           "an applied entry acknowledges selection without promising a restart on later resume")

    // Same activity re-click is a NEW request that starts the entry again, for this same source.
    expect(entryModel.startActivity(.desk) && sent.count == 2
           && sent[1].requestID != sent[0].requestID
           && sent[1].desired == sent[0].desired,
           "re-clicking the same activity must start a new entry request for the same resolved source")

    // Browsing another tab alone must not mislabel the outstanding request's source.
    entryModel.timeTab = .night
    expect(entryModel.activityStatus?.contains("正在准备进入白天") == true
           && entryModel.activityStatus?.contains("夜晚") == false
           && entryModel.activityState == .verifying,
           "browsing another tab must not relabel the outstanding requested source")

    // Failure is visible with its real detail and does not disable unrelated controls.
    entryModel.receiveActivityReport(DailyActivityReport(requestID: sent[1].requestID, state: .failed,
                                                         detail: "已审查的日常原片内容校验不通过"))
    expect(entryModel.activityState == .failed
           && entryModel.activityStatus?.contains("已审查的日常原片内容校验不通过") == true,
           "a failed entry must show its real failure detail")

    // Agent loss cancels the transient request and never replays it.
    entryModel.agentLost()
    expect(entryModel.activityState == .cancelled && sent.count == 2,
           "Agent loss must cancel the transient entry without sending another request")
    entryModel.agentLost()
    expect(entryModel.activityState == .cancelled, "repeated Agent loss stays cancelled")

    // A real source change clears the obsolete entry status and ignores its late report.
    var changedSource = r1State
    changedSource.outfit = .r3
    entryModel.update(desired: changedSource, resourceReady: true, dailyContentKeys: qualifiedSources,
                      performanceActive: false, pendingSwitchMessage: nil)
    entryModel.receiveActivityReport(DailyActivityReport(requestID: sent[1].requestID, state: .applied))
    expect(entryModel.activityStatus == nil && entryModel.activityRequestID == nil,
           "a source change clears the obsolete entry status and ignores its late report")

    // 7a) The real AppDelegate applies the request's desired source synchronously inside
    // `onStartActivity`, so the entry's own source refresh must not be mistaken for an unrelated
    // source change. Starting from a different source (B/R1/evening -> browsed A/R1/noon), the
    // request must be retained and its Agent report accepted.
    let synchronous = DailyActivityRecommendationModel()
    var synchronousSent: [DailyActivityRequest] = []
    synchronous.onStartActivity = { request in
        synchronousSent.append(request)
        synchronous.update(desired: request.desired, resourceReady: true,
                           dailyContentKeys: qualifiedSources, performanceActive: false,
                           pendingSwitchMessage: nil)
        return true
    }
    var differentStartingSource = r1State
    differentStartingSource.scene = .b
    differentStartingSource.timeMode = .fixed(.evening)
    synchronous.update(desired: differentStartingSource, resourceReady: true,
                       dailyContentKeys: qualifiedSources, performanceActive: false,
                       pendingSwitchMessage: nil)
    synchronous.timeTab = .noon
    expect(synchronous.entrySourceKey == reviewedNoon && synchronous.canEnterActivity,
           "a different starting source must still resolve the browsed entry target")
    expect(synchronous.startActivity(.desk) && synchronousSent.count == 1,
           "the explicit click must send one entry request from the different starting source")
    expect(synchronous.activityRequestID == synchronousSent[0].requestID
           && synchronous.activitySourceKey == reviewedNoon
           && synchronous.activityState == .verifying,
           "the synchronous own-source refresh must retain the outstanding request")
    synchronous.receiveActivityReport(
        DailyActivityReport(requestID: synchronousSent[0].requestID, state: .applied))
    expect(synchronous.activityState == .applied
           && synchronous.activityStatus?.contains("白天") == true
           && synchronous.activityStatus?.contains("素材组") == false,
           "the Agent report for the retained own-source request must still be accepted")

    // 7b) Every reviewed source is enterable in its own time tab, including a manual R2/sunset.
    for (outfit, time) in [(Outfit.r1, TimeOfDay.noon), (.r1, .evening), (.r1, .night), (.r2, .evening)] {
        var desired = r1State
        desired.outfit = outfit
        let perSource = DailyActivityRecommendationModel()
        var perSent: [DailyActivityRequest] = []
        perSource.onStartActivity = { perSent.append($0); return true }
        perSource.update(desired: desired, resourceReady: true, dailyContentKeys: qualifiedSources,
                         performanceActive: false, pendingSwitchMessage: nil)
        perSource.timeTab = DailyActivityRecommendationModel.tab(for: time)
        let expectedKey = dailyKey(.a, outfit, time)
        expect(perSource.entrySourceKey == expectedKey && perSource.canEnterActivity
               && perSource.startActivity(.rest) && perSent.count == 1
               && perSent[0].desired.outfit == outfit
               && perSent[0].desired.dailySourceKey == expectedKey,
               "the reviewed source \(expectedKey) must be enterable without changing the manual version")
    }

    // 7c) Browsing is always available: every time tab stays browseable for R1, R2 and R3 (R2
    // daytime/night and all R3 times included) and browsing alone applies or switches nothing.
    // Only the entry/apply action is unavailable without a reviewed source.
    let tabAvailability = DailyActivityRecommendationModel()
    var tabApplies = 0
    tabAvailability.onApply = { _ in tabApplies += 1; return true }
    expect(DailyActivityTimeTab.allCases.count == 3,
           "the three official whole-source time tabs must stay the browsing set")
    for outfit in Outfit.allCases {
        var availabilityState = r1State
        availabilityState.outfit = outfit
        tabAvailability.update(desired: availabilityState, resourceReady: true,
                               dailyContentKeys: qualifiedSources,
                               performanceActive: false, pendingSwitchMessage: nil)
        for tab in DailyActivityTimeTab.allCases {
            tabAvailability.timeTab = tab
            expect(tabAvailability.entryTimeIsEnabled(tab)
                   && tabAvailability.timeTab == tab
                   && tabAvailability.desired == availabilityState,
                   "every browsing tab must stay browseable and inert for \(outfit.dailyDisplayName): \(tab.title)")
        }
        expect(tabApplies == 0,
               "browsing tabs for \(outfit.dailyDisplayName) must not apply any source")
    }

    let r2Unsupported = DailyActivityRecommendationModel()
    var r2UnsupportedSent = 0
    r2Unsupported.onStartActivity = { _ in r2UnsupportedSent += 1; return true }
    for outfit in [Outfit.r1, .r2] {
        for time in [TimeOfDay.noon, .evening, .night] where DailyActivityCatalog.entry(
            for: dailyKey(.a, outfit, time), activityID: .desk) == nil {
            var desired = r1State
            desired.outfit = outfit
            r2Unsupported.update(desired: desired, resourceReady: true, dailyContentKeys: qualifiedSources,
                                 performanceActive: false, pendingSwitchMessage: nil)
            r2Unsupported.timeTab = DailyActivityRecommendationModel.tab(for: time)
            expect(r2Unsupported.entrySourceKey == nil && !r2Unsupported.canEnterActivity
                   && r2Unsupported.startActivity(.desk) == false && r2UnsupportedSent == 0,
                   "an unreviewed time must be unavailable without fallback: \(outfit)/\(time)")
            expect(r2Unsupported.entryUnavailableReason?.contains(time.controlCenterLabel) == true
                   && r2Unsupported.entryUnavailableReason?.contains("不会自动") == true
                   && r2Unsupported.entryUnavailableReason?.contains("素材组") == false
                   && r2Unsupported.entryUnavailableReason?.contains("日常版本") == false
                   && r2Unsupported.entryUnavailableReason?.contains(outfit.rawValue) == false,
                   "the unavailable reason must name the daypart readably without internal ids: \(outfit)/\(time)")
        }
    }
    for outfit in [Outfit.r2, .r3] {
        var other = r1State
        other.outfit = outfit
        let blocked = DailyActivityRecommendationModel()
        var blockedSent = 0
        blocked.onStartActivity = { _ in blockedSent += 1; return true }
        blocked.update(desired: other, resourceReady: true, dailyContentKeys: qualifiedSources,
                       performanceActive: false, pendingSwitchMessage: nil)
        blocked.timeTab = .night
        expect(!blocked.canEnterActivity && blocked.startActivity(.rest) == false && blockedSent == 0,
               "R2/night and every R3 time must not enter or auto-switch")
        expect(blocked.entryUnavailableReason?.contains("不会自动") == true
               && blocked.entryUnavailableReason?.contains("素材组") == false
               && blocked.entryUnavailableReason?.contains("日常版本") == false
               && blocked.entryUnavailableReason?.contains(outfit.rawValue) == false,
               "the blocked entry must stay honest without naming internal ids")
    }

    // Readiness/performance/discovery gating mirrors the ordinary apply guards.
    let gated = DailyActivityRecommendationModel()
    gated.onStartActivity = { _ in true }
    gated.timeTab = .noon
    gated.update(desired: r1State, resourceReady: true, dailyContentKeys: qualifiedSources,
                 performanceActive: true, pendingSwitchMessage: nil)
    expect(!gated.canEnterActivity && gated.entryUnavailableReason?.contains("演奏") == true,
           "an active performance or queue must block entry")
    gated.update(desired: r1State, resourceReady: false, dailyContentKeys: qualifiedSources,
                 performanceActive: false, pendingSwitchMessage: nil)
    expect(!gated.canEnterActivity, "an unready service must block entry")
    gated.update(desired: r1State, resourceReady: true, dailyContentKeys: nil,
                 performanceActive: false, pendingSwitchMessage: nil)
    expect(!gated.canEnterActivity, "undiscovered daily content must block entry")
    gated.update(desired: r1State, resourceReady: true, dailyContentKeys: [reviewedEvening],
                 performanceActive: false, pendingSwitchMessage: nil)
    expect(!gated.canEnterActivity && gated.entryUnavailableReason?.contains("缺少") == true,
           "the browsed noon source must not be unlocked by the sunset source alone")
    gated.update(desired: r1State, resourceReady: true, dailyContentKeys: [reviewedNoon],
                 performanceActive: false, pendingSwitchMessage: nil)
    expect(gated.canEnterActivity, "the matching discovered source must unlock the noon entry")
}
