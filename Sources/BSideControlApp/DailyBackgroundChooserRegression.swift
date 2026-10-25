// BSideControlApp — daily background chooser regression (ADR-024).
//
// Drives the real chooser model with an injected preview seam: no media access, no AVFoundation,
// no window, no player. It pins the observable chooser contract: candidates are exactly the
// admitted whole videos across dayparts, one preview request is active at a time, a stale
// result can never be displayed, a failure is reported honestly, and applying uses the ordinary
// whole-combination path without a claim that playback restarted.
import AppKit
import Combine
import Foundation
import BSideCore
import BSidePlatform

func runDailyBackgroundChooserRegression(expect: (Bool, String) -> Void) {
    let noonA = ContentKey(scene: .a, outfit: .r1, time: .noon)
    let noonB = ContentKey(scene: .a, outfit: .r2, time: .noon)
    let noonC = ContentKey(scene: .b, outfit: .r2, time: .noon)
    let evening = ContentKey(scene: .a, outfit: .r1, time: .evening)
    // A discovered set: three noon combinations plus one evening combination. The three
    // product-excluded combinations simply never appear here (they are not admitted at the
    // catalog level), which is exactly how the chooser must treat them.
    let discovered = [noonA, noonB, noonC, evening]

    // The home preview follows the chosen source independently of chooser work and rejects
    // results from hidden, resized or superseded requests without any playback command.
    let home = CompanionHomePreview()
    var homeRequests: [(ContentKey, (DailyBackgroundPreviewResult) -> Void)] = []
    var homeCancels = 0
    home.request = { key, _, done in homeRequests.append((key, done)) }
    home.cancel = { homeCancels += 1 }
    home.geometry(CGSize(width: 400, height: 300), scale: 2)
    home.update(key: noonA, windowVisible: true)
    expect(homeRequests.isEmpty, "unmounted home cannot extract")
    home.setMounted(true)
    expect(homeRequests.count == 1 && homeRequests[0].0 == noonA, "home requests selected daily scene")
    home.update(key: noonB, windowVisible: true)
    homeRequests[0].1(.image(noonA, Data([1])))
    expect(home.result == nil, "old scene cannot overwrite a changed selection")
    homeRequests[1].1(.image(noonB, Data([2])))
    expect(home.result?.key == noonB, "matching selected scene is displayed")
    home.geometry(CGSize(width: 600, height: 300), scale: 2)
    expect(homeRequests.count == 2 && home.result?.key == noonB, "resizing retains the still without another extraction")
    home.invalidate()
    home.update(key: noonB, windowVisible: true)
    home.setChooserPresented(true)
    homeRequests[2].1(.image(noonB, Data([3])))
    expect(home.result == nil, "chooser suspension rejects in-flight home result")
    home.setChooserPresented(false)
    expect(homeRequests.count == 4, "closing chooser resumes one current preview")
    home.update(key: noonB, windowVisible: false)
    homeRequests[3].1(.image(noonB, Data([4])))
    expect(home.result == nil && homeCancels > 0, "hidden window cancels and rejects result")
    home.update(key: noonB, windowVisible: true)
    homeRequests[4].1(.image(noonB, Data([5])))
    home.update(key: noonB, windowVisible: true)
    expect(homeRequests.count == 5, "unchanged pushes reuse completed still")
    home.invalidate()
    expect(home.result == nil, "authorization loss immediately clears displayed still")

    let streamHome = CompanionHomePreview()
    let view = HomeCompanionFrameView()
    var streams: [HomeCompanionStreamRequest] = []
    streamHome.streamChanged = { streams.append($0) }
    streamHome.attach(view)
    streamHome.setNativeVisible(true, view: view)
    streamHome.setMounted(true)
    expect(streams.isEmpty, "no buffer is offered before accepted Agent readiness")
    streamHome.agentReady()
    let first = streams.last?.stream
    expect(first != nil, "visible mounted home creates a bounded capability")
    streamHome.update(key: noonA, windowVisible: true)
    streamHome.update(key: noonB, windowVisible: true)
    expect(streams.count == 1, "scene change does not replace the stream or player")
    streamHome.setChooserPresented(true)
    expect(streams.last?.stream == nil, "chooser withdraws the stream")
    streamHome.agentReady()
    expect(streams.last?.stream == nil, "restart cannot resurrect a covered stream")
    streamHome.setChooserPresented(false)
    expect(streams.last?.stream?.id != first?.id, "reopening creates a fresh generation")
    streamHome.agentLost()
    expect(streams.last?.stream == nil, "Agent loss withdraws its capability")
    streamHome.agentReady()
    streamHome.detach(view)
    expect(streams.last?.stream == nil, "unmount revokes the current stream")
    expect(first.map { !FileManager.default.fileExists(atPath: $0.bufferPath) } == true,
           "closed generation removes its owned temporary pixels")

    // Real view/window attachment and notification delivery, with controlled visibility only.
    // The fixture never orders a window onto the owner's desktop.
    let retainedWindow = CompanionRetainedWindowFixture(contentRect: NSRect(x: 0, y: 0, width: 400, height: 225),
        styleMask: [.titled], backing: .buffered, defer: false)
    retainedWindow.isReleasedWhenClosed = false
    let retainedHome = CompanionHomePreview()
    let retainedView = CompanionSurfaceResizeFixture(frame: NSRect(x: 0, y: 0, width: 400, height: 225))
    retainedView.model = retainedHome
    retainedHome.attach(retainedView)
    retainedHome.setMounted(true)
    retainedWindow.contentView = retainedView
    var retainedRequests: [HomeCompanionStreamRequest] = []
    retainedHome.streamChanged = { retainedRequests.append($0) }
    retainedHome.agentReady()
    RunLoop.main.run(until: Date().addingTimeInterval(0.03))
    expect(retainedRequests.last?.stream != nil, "attached visible retained window starts stream")
    retainedWindow.fixtureVisible = false
    NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: retainedWindow)
    expect(retainedRequests.last?.stream == nil, "close immediately withdraws the retained window stream")
    retainedWindow.fixtureVisible = true
    NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: retainedWindow)
    RunLoop.main.run(until: Date().addingTimeInterval(0.03))
    expect(retainedRequests.last?.stream != nil, "menu reopen event restores stream without another view attachment")
    let requestsBeforeResize = retainedRequests.count
    retainedView.fixtureResizing = true; retainedView.fixtureEmpty = true
    retainedWindow.fixtureOccluded = true
    retainedView.scheduleVisibility()
    RunLoop.main.run(until: Date().addingTimeInterval(0.03))
    expect(retainedRequests.count == requestsBeforeResize, "active-Space live resize retains stream across transient occlusion and empty rect")
    retainedWindow.fixtureOnActiveSpace = false
    retainedView.scheduleVisibility()
    RunLoop.main.run(until: Date().addingTimeInterval(0.03))
    expect(retainedRequests.last?.stream == nil, "leaving the Space withdraws even during a live resize")
    retainedView.fixtureResizing = false; retainedView.fixtureEmpty = false
    retainedView.viewDidEndLiveResize()
    retainedWindow.fixtureOnActiveSpace = true; retainedWindow.fixtureKey = true
    retainedView.fixtureApplicationActive = true
    retainedView.scheduleVisibility()
    RunLoop.main.run(until: Date().addingTimeInterval(0.03))
    expect(retainedRequests.last?.stream != nil, "active key window survives a stale occlusion flag after native fullscreen completion")
    let activeKeyRequests = retainedRequests.count
    retainedWindow.fixtureOccluded = false
    retainedView.scheduleVisibility()
    RunLoop.main.run(until: Date().addingTimeInterval(0.03))
    expect(retainedRequests.count == activeKeyRequests, "subsequent accurate occlusion report keeps the same stream")
    retainedWindow.fixtureOccluded = true; retainedView.fixtureApplicationActive = false
    NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
    RunLoop.main.run(until: Date().addingTimeInterval(0.03))
    expect(retainedRequests.last?.stream == nil, "inactive app withdraws despite a stale key-window flag")
    retainedView.fixtureApplicationActive = true
    NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
    RunLoop.main.run(until: Date().addingTimeInterval(0.03))
    expect(retainedRequests.last?.stream != nil, "actual app activation restores its key visible stream")
    retainedWindow.fixtureOnActiveSpace = false
    retainedView.scheduleVisibility()
    RunLoop.main.run(until: Date().addingTimeInterval(0.03))
    expect(retainedRequests.last?.stream == nil, "key and active app cannot retain an occluded window on another Space")
    retainedWindow.fixtureOnActiveSpace = true; retainedWindow.fixtureKey = false
    retainedView.scheduleVisibility()
    RunLoop.main.run(until: Date().addingTimeInterval(0.03))
    expect(retainedRequests.last?.stream == nil, "an active app's covered nonkey window still withdraws")
    retainedView.detach()
    retainedWindow.contentView = nil

    let allKeys = Scene.allCases.flatMap { scene in Outfit.allCases.flatMap { outfit in
        TimeOfDay.allCases.map { ContentKey(scene: scene, outfit: outfit, time: $0) }
    }}.filter { ![ContentKey(scene: .b, outfit: .r1, time: .evening),
                  ContentKey(scene: .b, outfit: .r1, time: .night),
                  ContentKey(scene: .c, outfit: .r1, time: .evening)].contains($0) }
    let catalogControl = ControlCenterModel()
    catalogControl.resourceConfigured = true
    catalogControl.apply(desired: DesiredState(timeMode: .auto), stage: .ready, stageDetail: "",
        snapshot: RuntimeSnapshot(state: .playing, dailyContentKeys: allKeys), supervision: .running)
    let wholeVideos = DailyBackgroundChooserModel()
    wholeVideos.availableKeysProvider = { allKeys }
    wholeVideos.onRequestPreview = { key, _, done in done(.image(key, Data([1]))) }
    wholeVideos.onApply = { catalogControl.selectDailyContent($0) }
    wholeVideos.present(currentKey: nil)
    expect(wholeVideos.candidates.count == 24 && wholeVideos.visibleCandidates.count == 3,
           "all 24 admitted full videos are reachable from three source families")
    for candidate in wholeVideos.candidates {
        wholeVideos.select(candidate)
        expect(wholeVideos.selectedFamilyVariants.contains(candidate), "every exact video is reachable through its family variants")
        expect(wholeVideos.applySelection() && catalogControl.desired.dailySourceKey == candidate.key,
               "applying an exact video pins its own time and source without seeking or inventing a clip")
    }
    expect(wholeVideos.positionText == "3 / 3", "main footer counts the three source families after browsing all 24 variants")
    let lastVariant = wholeVideos.selectedCandidate!.key
    wholeVideos.selectPrevious()
    expect(wholeVideos.selectedCandidate?.key.scene == .b && wholeVideos.positionText == "2 / 3",
           "main arrows change family while variant menu retains all exact videos")
    wholeVideos.selectNext()
    expect(wholeVideos.selectedCandidate?.key == lastVariant, "family navigation restores its remembered variant without autoplay")
    let visibleKey = catalogControl.desired.dailySourceKey!
    catalogControl.setTimeAuto()
    wholeVideos.followsAutomaticTime = { catalogControl.desired.timeMode == .auto }
    wholeVideos.present(currentKey: visibleKey)
    expect(wholeVideos.selectionIsCurrent && wholeVideos.canApplySelection && wholeVideos.applyActionTitle == "播放此视频",
           "current-playing indication does not hide the command to pin an automatic video")
    expect(wholeVideos.applySelection() && catalogControl.desired.dailySourceKey == visibleKey
           && !wholeVideos.canApplySelection && wholeVideos.applyActionTitle == "当前设置",
           "explicit current-video selection pins its exact time once without changing the selected file")
    wholeVideos.dismissed()

    let model = DailyBackgroundChooserModel()
    var requested: [ContentKey] = []
    var requestedSizes: [DailyPreviewPixelSize] = []
    var pending: [(key: ContentKey, size: DailyPreviewPixelSize,
                   settle: (DailyBackgroundPreviewResult) -> Void)] = []
    var cancels = 0
    var applied: [ContentKey] = []
    var applyResult = true
    model.onRequestPreview = { key, pixelSize, completion in
        requested.append(key)
        requestedSizes.append(pixelSize)
        pending.append((key, pixelSize, completion))
    }
    model.onCancelPreview = { cancels += 1 }
    model.onApply = { key in
        guard applyResult else { return false }
        applied.append(key)
        return true
    }
    model.timeProvider = { .noon }
    model.availableKeysProvider = { discovered }

    // 1) Every admitted whole video remains reachable, grouped by its source family.
    model.present(currentKey: noonB)
    expect(model.candidates.count == 4,
           "all admitted full videos are offered across dayparts")
    expect(Set(model.candidates.map(\.key)) == Set(discovered),
           "no admitted video is hidden by the current daypart")
    expect(model.candidates.map(\.key) == [noonB, noonA, evening, noonC],
           "the current background comes first and the rest keep a deterministic order")
    expect(model.candidates[0].isCurrent && !model.candidates[1].isCurrent,
           "exactly the current combination is marked as current")
    expect(model.positionText == "1 / 2",
           "the main position counts families, not all versions")
    expect(model.selectedCandidate?.title == "原片 1 · 服装 2 · 白天"
           && !model.selectedCandidate!.title.contains("素材组")
           && model.selectedCandidate!.technicalDetail.contains(noonB.description),
           "exact source version and daypart are shown without inventing footage")
    expect(requested == [noonB],
           "opening the chooser requests exactly one preview, never a batch")
    expect(requestedSizes == [DailyPreview.defaultPreviewPixelSize],
           "before the view reports real geometry the request uses the bounded product default")
    expect(model.isPreviewing && model.previewImageData == nil && model.previewFailure == nil,
           "a pending preview is a loading state, not a fabricated image")

    // 2) Stepping wraps, cancels the superseded request, and never applies anything.
    let cancelsBeforeStep = cancels
    model.selectNext()
    expect(model.selectedCandidate?.key == noonC && cancels > cancelsBeforeStep && applied.isEmpty,
           "stepping must cancel the superseded request and apply nothing")
    model.selectPrevious()
    expect(model.selectedCandidate?.key == noonB, "previous restores the last browsed variant of that family")
    model.selectPrevious()
    expect(model.selectedCandidate?.key == noonC, "previous wraps between source families")
    model.selectNext()
    expect(model.selectedCandidate?.key == noonB, "next wraps between source families")

    // 3) A stale result can never be displayed: after stepping, the older request's completion
    //    is ignored even though it carries real image data.
    guard let firstRequest = pending.first else {
        expect(false, "the chooser must have requested a preview")
        return
    }
    let staleKey = firstRequest.key
    model.selectNext()
    let currentKey = model.selectedCandidate?.key
    firstRequest.settle(.image(staleKey, Data([0x01])))
    expect(model.previewImageData == nil && model.previewFailure == nil,
           "a superseded preview result must not be installed")
    guard let latest = pending.last, let currentKey, latest.key == currentKey else {
        expect(false, "a new selection must request its own preview")
        return
    }
    latest.settle(.image(currentKey, Data([0x02])))
    expect(model.previewImageData == Data([0x02]) && model.previewFailure == nil
           && !model.isPreviewing,
           "the current request's image must be displayed")

    // 4) A failed preview reports an honest unavailable state instead of a generic illustration.
    model.selectNext()
    guard let failing = pending.last else {
        expect(false, "stepping must request the next preview")
        return
    }
    failing.settle(.unavailable(failing.key, "这段画面暂时无法生成预览。"))
    expect(model.previewImageData == nil
           && model.previewFailure == "这段画面暂时无法生成预览。"
           && !model.isPreviewing,
           "a missing/failed preview must state its own honest reason")

    // 5) Apply goes through the ordinary command, only for a non-current candidate, and the
    //    chooser never claims that a change happened when the command refused it.
    let cancelCountBeforeClose = cancels
    model.cancelPreview()
    expect(cancels > cancelCountBeforeClose && !model.isPreviewing,
           "closing the chooser must cancel any in-flight request")
    dailyPreviewRaceCheck(expect: expect)
    guard let current = model.candidates.first(where: { $0.isCurrent }) else {
        expect(false, "the fixture must keep exactly one current candidate")
        return
    }
    model.select(current)
    expect(!model.canApplySelection,
           "the already-current background must not offer a misleading change")
    expect(model.applySelection() == false && applied.isEmpty,
           "applying the current background must be a no-op")
    let other = model.candidates.first { !$0.isCurrent }
    guard let other else {
        expect(false, "the fixture must provide a non-current candidate")
        return
    }
    model.select(other)
    pending.last?.settle(.image(other.key, Data([0x04])))
    expect(model.canApplySelection && model.applySelection() && applied == [other.key],
           "applying a different background must use the ordinary selection path once")
    expect(model.selectionIsCurrent && model.canApplySelection == false,
           "after the accepted change the applied background is the current one")
    applyResult = false
    model.select(model.candidates.first { !$0.isCurrent } ?? other)
    if let selection = model.selectedCandidate { pending.last?.settle(.image(selection.key, Data([0x05]))) }
    let appliedBefore = applied.count
    expect(model.applySelection() == false && applied.count == appliedBefore,
           "a refused command must not record a successful change")

    // 6) The current daypart changes the current marker, not access to admitted videos.
    model.timeProvider = { .evening }
    model.refresh(currentKey: evening)
    expect(model.candidates.map(\.key) == [evening, noonA, noonB, noonC],
           "the current evening video is first and other full videos remain reachable")
    expect(model.canGoNext && model.canGoPrevious,
           "cross-daypart navigation remains available")

    // 7) No discovery at all is an honest empty state, never a substitute background.
    model.availableKeysProvider = { nil }
    model.refresh(currentKey: nil)
    expect(model.candidates.isEmpty && model.emptyMessage != nil
           && model.selectedCandidate == nil && !model.canApplySelection,
           "undiscovered daily content must show an honest empty state")

    // 8) Root invalidation/failure/rebinding drops the displayed still and rebuilds candidates
    //    from the current discovered keys. Closed, it starts no extraction; open, it requests a
    //    fresh (re-authorized) preview.
    let invalidated = DailyBackgroundChooserModel()
    var invalidatedRequests: [ContentKey] = []
    var invalidatedCancels = 0
    invalidated.timeProvider = { .noon }
    invalidated.availableKeysProvider = { discovered }
    invalidated.currentKeyProvider = { noonA }
    invalidated.onRequestPreview = { key, _, _ in invalidatedRequests.append(key) }
    invalidated.onCancelPreview = { invalidatedCancels += 1 }
    invalidated.present(currentKey: noonA)
    expect(invalidatedRequests == [noonA] && invalidated.candidates.count == 4,
           "an open chooser requests exactly one preview and lists the discovered backgrounds")
    invalidated.dismissed()
    let cancelsBeforeInvalidation = invalidatedCancels
    invalidated.rootInvalidated()
    expect(invalidated.candidates.count == 4 && invalidated.previewImageData == nil
           && invalidated.previewFailure == nil && !invalidated.isPreviewing,
           "invalidating the accepted root must drop the displayed preview and rebuild candidates")
    expect(invalidatedRequests == [noonA] && invalidatedCancels > cancelsBeforeInvalidation,
           "a closed chooser must cancel the old request without starting a new extraction")
    invalidated.present(currentKey: noonA)
    let requestsBeforeOpenInvalidation = invalidatedRequests.count
    invalidated.rootInvalidated()
    expect(invalidatedRequests.count == requestsBeforeOpenInvalidation + 1,
           "an open chooser must request a fresh preview after an invalidation")

    // 9) The preview authorization gate refuses a lease whose fresh identity conflicts with the
    //    identity captured when the daily root was accepted, and tolerates unknown evidence.
    let acceptedIdentity = DirectoryIdentitySnapshot(
        volumeUUID: "VOL-ACCEPTED", inode: 41, persistentIDsSupported: true,
        provenance: .explicitSelection)
    let replacedInode = DirectoryIdentitySnapshot(
        volumeUUID: "VOL-ACCEPTED", inode: 42, persistentIDsSupported: true,
        provenance: .legacyAdopted)
    let replacedVolume = DirectoryIdentitySnapshot(
        volumeUUID: "VOL-OTHER", inode: 41, persistentIDsSupported: true,
        provenance: .legacyAdopted)
    let consistentIdentity = DirectoryIdentitySnapshot(
        volumeUUID: "VOL-ACCEPTED", inode: 41, persistentIDsSupported: true,
        provenance: .legacyAdopted)
    expect(!DailyPreviewAuthorization.accepts(accepted: acceptedIdentity, fresh: replacedInode),
           "a replaced inode at the accepted path must refuse the preview")
    expect(!DailyPreviewAuthorization.accepts(accepted: acceptedIdentity, fresh: replacedVolume),
           "a different volume must refuse the preview")
    expect(DailyPreviewAuthorization.accepts(accepted: acceptedIdentity, fresh: consistentIdentity),
           "a matching accepted identity permits the preview")
    expect(DailyPreviewAuthorization.accepts(accepted: nil, fresh: replacedInode)
           && DailyPreviewAuthorization.accepts(accepted: acceptedIdentity, fresh: nil),
           "unknown identity evidence cannot prove a conflict and must not block a preview")

    // 10) Change-detected updates while the surface is open: auto mode resolves the current key
    //     from scene + outfit + effective time (Core's dailySourceKey stays nil there), an
    //     accepted discovery/current/daypart change rebuilds the candidates, an unrelated
    //     unchanged push does not regenerate, invalidation drops the still and rejects stale
    //     callbacks, and a closed surface starts no extraction.
    dailyBackgroundChooserSyncCheck(expect: expect)

    // 11) Preview geometry: the pixel bounds come from the REAL rendered container and the display
    //     backing scale, a resize/scale change is a new request identity, and geometry changes
    //     apply nothing.
    dailyBackgroundChooserGeometryCheck(expect: expect)
    dailyBackgroundThumbnailCheck(expect: expect)
    dailyBackgroundApplyAdmissionCheck(expect: expect)
}

/// Preview geometry wiring: the still's request bounds follow the real rendered container and the
/// display backing scale; a resize or scale change re-requests instead of reusing an undersized
/// still; a late result for superseded geometry can never be displayed; and none of it applies a
/// combination or sends a playback change.
private func dailyBackgroundChooserGeometryCheck(expect: (Bool, String) -> Void) {
    let noonA = ContentKey(scene: .a, outfit: .r1, time: .noon)
    let noonB = ContentKey(scene: .a, outfit: .r2, time: .noon)
    let model = DailyBackgroundChooserModel()
    var requested: [(key: ContentKey, size: DailyPreviewPixelSize)] = []
    var pending: [(key: ContentKey, size: DailyPreviewPixelSize,
                   settle: (DailyBackgroundPreviewResult) -> Void)] = []
    var cancels = 0
    var applied: [ContentKey] = []
    model.availableKeysProvider = { [noonA, noonB] }
    model.timeProvider = { .noon }
    model.onApply = { key in applied.append(key); return true }
    model.onCancelPreview = { cancels += 1 }
    model.onRequestPreview = { key, size, completion in
        requested.append((key, size))
        pending.append((key, size, completion))
    }

    model.present(currentKey: noonA)
    expect(requested.count == 1 && requested[0].size == DailyPreview.defaultPreviewPixelSize,
           "the first request uses the bounded product default until real geometry is reported")

    // The real chooser container: 480x220 pt inside the 520x460 sheet, on a 2x display.
    model.updatePreviewMetrics(size: CGSize(width: 480, height: 220), scale: 2)
    let twox = DailyPreviewPixelSize(width: 960, height: 440)
    expect(requested.count == 2 && requested[1].size == twox,
           "a 2x 480x220 container must request exactly its own device-pixel bounds")
    expect(model.previewPixelSize == twox && model.previewContainerSize == CGSize(width: 480, height: 220),
           "the reported geometry is the current request identity")
    expect(applied.isEmpty && model.selectedCandidate?.key == noonA && model.candidates.count == 2,
           "reporting geometry must not apply a combination or change the selection")

    // An unchanged report is inert: no re-request, no churn.
    model.updatePreviewMetrics(size: CGSize(width: 480, height: 220), scale: 2)
    expect(requested.count == 2, "an unchanged container/scale report must not re-request")

    // A move to a 1x display is a genuinely different pixel demand.
    model.updatePreviewMetrics(size: CGSize(width: 480, height: 220), scale: 1)
    let onex = DailyPreviewPixelSize(width: 480, height: 220)
    expect(requested.count == 3 && requested[2].size == onex,
           "a display-scale change must re-request at the correct smaller pixel bounds")

    // The late 2x result belongs to a superseded geometry and must never be displayed.
    pending[1].settle(.image(noonA, Data([0x11])))
    expect(model.previewImageData == nil && model.previewFailure == nil,
           "a late result for an older geometry must not be installed")

    // A half-size container at 2x has the SAME pixel demand as the full container at 1x: identity
    // is the pixel size, so this is correctly NOT a new request.
    model.updatePreviewMetrics(size: CGSize(width: 240, height: 110), scale: 2)
    expect(requested.count == 3,
           "two containers with the same pixel demand must not re-request")

    guard let current = pending.last else {
        expect(false, "the geometry fixture must have a current request")
        return
    }
    current.settle(.image(noonA, Data([0x12])))
    expect(model.previewImageData == Data([0x12]) && !model.isPreviewing,
           "the current geometry's result must be displayed")

    // A real resize keeps the still visible until the correctly sized replacement arrives.
    model.updatePreviewMetrics(size: CGSize(width: 480, height: 220), scale: 2)
    expect(requested.count == 4 && requested[3].size == twox,
           "resizing back to the larger container must re-request at the larger bounds")
    expect(model.previewImageData == Data([0x12]) && model.isPreviewing,
           "a geometry re-request must retain the displayed still while loading")
    guard let replacement = pending.last else {
        expect(false, "a resize must produce a new request")
        return
    }
    replacement.settle(.image(noonA, Data([0x13])))
    expect(model.previewImageData == Data([0x13]) && model.previewFailure == nil,
           "the correctly sized replacement must replace the retained still")
    expect(cancels > 0 && applied.isEmpty,
           "geometry changes may cancel superseded extractions but never apply content")
}

/// Sync/dismissal wiring: the three inputs the chooser actually shows are the only ones that may
/// rebuild it, and no push may start an extraction while the sheet is closed.
private func dailyBackgroundChooserSyncCheck(expect: (Bool, String) -> Void) {
    let now = Date()
    let autoDesired = DesiredState(scene: .a, outfit: .r1, timeMode: .auto)
    let effectiveTime = DailyActivityRecommendationModel.resolvedTime(desired: autoDesired, now: now)
    let autoKey = ContentKey(scene: .a, outfit: .r1, time: effectiveTime)
    let autoOther = ContentKey(scene: .a, outfit: .r2, time: effectiveTime)
    let eveningKey = ContentKey(scene: .a, outfit: .r1, time: .evening)
    let firstDiscovery = [autoKey, autoOther]
    let expandedDiscovery = firstDiscovery + [eveningKey]

    expect(DailyBackgroundChooserModel.backdropKey(desired: autoDesired, at: now) == autoKey
           && autoDesired.dailySourceKey == nil,
           "the chooser must resolve the current backdrop key under the automatic time policy")

    // The auto-mode resolution itself is pinned by the assertion above; this fixture uses the
    // resolved key/time directly so the real clock cannot change the bucket mid-run.
    let sync = DailyBackgroundChooserModel()
    var requested: [ContentKey] = []
    var pending: [(key: ContentKey, size: DailyPreviewPixelSize,
                   settle: (DailyBackgroundPreviewResult) -> Void)] = []
    var discovery = firstDiscovery
    sync.availableKeysProvider = { discovery }
    sync.timeProvider = { effectiveTime }
    sync.currentKeyProvider = { autoKey }
    sync.onRequestPreview = { key, pixelSize, completion in
        requested.append(key)
        pending.append((key, pixelSize, completion))
    }

    sync.syncState(desired: autoDesired, keys: discovery, effectiveTime: effectiveTime, at: now)
    expect(requested.isEmpty && sync.candidates.isEmpty,
           "a closed chooser must not rebuild or extract on an owner push")
    sync.present(currentKey: nil)
    expect(sync.candidates.map(\.key) == [autoKey, autoOther] && sync.candidates[0].isCurrent
           && requested == [autoKey],
           "an open chooser in auto mode must mark and preview the resolved current background")

    sync.syncState(desired: autoDesired, keys: discovery, effectiveTime: effectiveTime, at: now)
    expect(requested == [autoKey] && sync.candidates.map(\.key) == [autoKey, autoOther],
           "an unchanged owner push must not regenerate the candidate list or re-request")

    discovery = expandedDiscovery
    sync.syncState(desired: autoDesired, keys: expandedDiscovery, effectiveTime: effectiveTime, at: now)
    expect(Set(sync.candidates.map(\.key)) == Set(expandedDiscovery),
           "changed discovery exposes every admitted time without duplicate keys")
    expect(requested.count == 2 && pending.last?.key == autoKey,
           "a changed discovery must cancel and re-request the selected background once")

    let stale = pending.last?.settle
    sync.rootInvalidated()
    expect(sync.previewImageData == nil && sync.previewFailure == nil,
           "invalidation must clear the displayed still")
    expect(Set(sync.candidates.map(\.key)) == Set(expandedDiscovery),
           "invalidation must keep browsing the current truth")
    stale?(.image(autoKey, Data([0x09])))
    expect(sync.previewImageData == nil,
           "a callback from the invalidated admission must never be displayed")

    guard let fresh = pending.last?.settle else {
        expect(false, "an open chooser must request a fresh preview after invalidation")
        return
    }
    fresh(.image(autoKey, Data([0x0A])))
    expect(sync.previewImageData == Data([0x0A]),
           "the current admission's image must be displayed")

    discovery = expandedDiscovery + [ContentKey(scene: .b, outfit: .r1, time: effectiveTime)]
    sync.dismissed()
    let requestsAfterDismissal = requested.count
    sync.syncState(desired: autoDesired, keys: discovery, effectiveTime: effectiveTime, at: now)
    expect(requested.count == requestsAfterDismissal,
           "a changed discovery while the chooser is closed must start no extraction")
    expect(sync.previewImageData == nil && sync.previewFailure == nil && !sync.isPreviewing,
           "a dismissed chooser must hold no still and no in-flight request")
    sync.present(currentKey: nil)
    expect(requested.count == requestsAfterDismissal + 1
           && Set(sync.candidates.map(\.key)) == Set(discovery),
           "reopening must rebuild from current truth with exactly one preview request")
}

/// Small race-shaped check: an old completion delivered after a cancel must still be ignored.
private func dailyPreviewRaceCheck(expect: (Bool, String) -> Void) {
    var settle: ((DailyBackgroundPreviewResult) -> Void)?
    let racing = DailyBackgroundChooserModel()
    racing.availableKeysProvider = { [ContentKey(scene: .a, outfit: .r1, time: .noon)] }
    racing.timeProvider = { .noon }
    racing.onRequestPreview = { _, _, completion in settle = completion }
    racing.present(currentKey: nil)
    guard let settle else {
        expect(false, "the race fixture must request one preview")
        return
    }
    racing.cancelPreview()
    settle(.image(ContentKey(scene: .a, outfit: .r1, time: .noon), Data([0x03])))
    expect(racing.previewImageData == nil,
           "a completion delivered after cancellation must not be displayed")
}

/// Visible demand, scheduling, failure recovery and bounded memory use the actual shared model.
private func dailyBackgroundThumbnailCheck(expect: (Bool, String) -> Void) {
    let keys = Scene.allCases.flatMap { scene in
        Outfit.allCases.map { ContentKey(scene: scene, outfit: $0, time: .noon) }
    }
    let model = DailyBackgroundChooserModel()
    model.availableKeysProvider = { keys }
    model.timeProvider = { .noon }
    model.currentKeyProvider = { keys[0] }
    var calls: [(ContentKey, DailyPreviewPixelSize, (DailyBackgroundPreviewResult) -> Void)] = []
    model.onRequestPreview = { calls.append(($0, $1, $2)) }
    model.present(currentKey: keys[0])
    model.updateVisibleThumbnails(keys: model.visibleCandidates.map(\.key),
        size: CGSize(width: 76, height: 43), scale: 2, in: .window)
    expect(model.visibleCandidates.count == 3 && calls.count == 1,
           "one representative per family never interrupts the selected request")
    calls[0].2(.image(keys[0], Data([1])))
    expect(calls.count == 2 && calls[1].0 == keys[3]
           && calls[1].1 == DailyPreviewPixelSize(width: 152, height: 86),
           "selected completion starts exactly one thumbnail at its rendered pixel bounds")
    let oldThumbnail = calls[1]
    model.select(model.candidates[2])
    expect(calls.count == 3 && calls[2].0 == keys[2] && model.isPreviewing,
           "a direct picture selection preempts the thumbnail and requests the large preview")
    oldThumbnail.2(.image(oldThumbnail.0, Data([2])))
    expect(model.thumbnailResults.isEmpty && model.previewImageData == nil,
           "a canceled thumbnail cannot populate either the cache or selected preview")
    calls[2].2(.unavailable(keys[2], "synthetic preview failure"))
    expect(model.previewFailure == "synthetic preview failure" && !model.isPreviewing,
           "selected failure remains honest while other visible thumbnails may continue")
    let beforeRetry = calls.count
    model.retryPreview()
    expect(calls.count == beforeRetry + 1 && calls.last?.0 == keys[2] && model.isPreviewing,
           "preview retry preempts any thumbnail and retries the selected key")
    calls.last?.2(.image(keys[2], Data([3])))
    let beforeRefresh = calls.count
    let stale = calls.last!
    model.refresh(currentKey: keys[0], keys: [keys[0], keys[2]])
    expect(model.selectedCandidate?.key == keys[2] && model.candidates.count == 2
           && model.thumbnailResults.isEmpty && calls.count == beforeRefresh + 1,
           "mid-browse discovery refresh retains an admitted selection and clears the old thumbnail cache")
    stale.2(.image(stale.0, Data([4])))
    expect(model.thumbnailResults.isEmpty, "discovery refresh rejects old thumbnail completions")
    calls.last?.2(.image(keys[2], Data([5])))
    model.onApply = { _ in false }
    expect(!model.applySelection() && model.applyFailed && model.applyNotice != nil
           && !model.selectionIsCurrent && model.isPresented,
           "apply rejection is visible and leaves the chooser open with the original current setting")
    model.onApply = { _ in true }
    expect(model.applySelection() && !model.applyFailed && model.applyNotice != nil
           && model.selectionIsCurrent && model.isPresented && model.pendingSwitchMessage == nil,
           "accepted apply stays visible and does not fabricate a runtime pending switch")
    model.updatePlaybackStatus(pending: "runtime pending", timePolicy: "fixed time")
    expect(model.pendingSwitchMessage == "runtime pending" && model.timePolicySummary == "fixed time",
           "runtime pending and time policy are projections of the owner state")
    var statusPublications = 0
    let statusObservation = model.objectWillChange.sink { statusPublications += 1 }
    let statusImage = model.previewImageData, statusRequests = calls.count
    model.updatePlaybackStatus(pending: "runtime pending", timePolicy: "fixed time")
    expect(statusPublications == 0, "unchanged playback status does not invalidate image views")
    model.updatePlaybackStatus(pending: nil, timePolicy: "fixed time")
    expect(statusPublications == 1 && model.pendingSwitchMessage == nil,
           "clearing a pending switch still publishes its visible change")
    model.updatePlaybackStatus(pending: nil, timePolicy: "automatic time")
    expect(statusPublications == 2 && model.timePolicySummary == "automatic time",
           "changed time policy still publishes its visible change")
    expect(model.previewImageData == statusImage && calls.count == statusRequests,
           "playback status changes preserve the selected image and preview requests")
    statusObservation.cancel()
    model.select(model.candidates.first { !$0.isCurrent }!)
    model.returnToCurrent()
    expect(model.selectionIsCurrent, "return-to-current returns to the applied preference")
    model.dismissed()
    let closedCalls = calls.count
    model.updateVisibleThumbnails(keys: keys, size: CGSize(width: 76, height: 43), scale: 2, in: .window)
    expect(model.thumbnailResults.isEmpty && model.thumbnailByteCount == 0
           && calls.count == closedCalls && model.previewImageData == nil,
           "dismissal drops all images and hidden thumbnail reports cannot start requests")

    // Immediate completions must still serialize; oversized outcomes cannot grow the cache.
    let synchronous = DailyBackgroundChooserModel()
    synchronous.availableKeysProvider = { keys }
    synchronous.timeProvider = { .noon }
    var synchronousKeys: [ContentKey] = []
    synchronous.onRequestPreview = { key, _, completion in
        synchronousKeys.append(key)
        completion(.image(key, Data(repeating: 1, count: 900_000)))
    }
    synchronous.present(currentKey: keys[0], in: .island)
    synchronous.updateVisibleThumbnails(keys: keys, size: CGSize(width: 76, height: 43), scale: 2, in: .island)
    expect(synchronousKeys == Array(keys.prefix(7)) && synchronous.thumbnailResults.count == 6,
           "synchronous completions finish only the visible seven keys without duplicate or catalog requests")
    expect(synchronous.thumbnailByteCount <= DailyBackgroundChooserModel.maximumThumbnailBytes,
           "thumbnail memory remains under its explicit four-MiB cap")
    let beforeWindowChange = synchronousKeys.count
    synchronous.select(synchronous.candidates.last!)
    expect(synchronousKeys.dropFirst(beforeWindowChange).first == keys.last
           && synchronous.visibleCandidates.map(\.key) == [keys[0], keys[3], keys[8]],
           "direct variant selection requests its large image first and retains only the three family representatives")
    let currentCalls = synchronousKeys.count
    synchronous.updateVisibleThumbnails(keys: keys, size: CGSize(width: 76, height: 43), scale: 2, in: .window)
    expect(synchronousKeys.count == currentCalls && synchronous.isPresentedInIsland,
           "a hidden window surface cannot alter island demand or routing")
    synchronous.rootInvalidated()
    expect(synchronous.thumbnailByteCount <= DailyBackgroundChooserModel.maximumThumbnailBytes,
           "root invalidation reauthorizes visible requests within the memory bound")
    synchronous.refresh(currentKey: nil, keys: [])
    expect(synchronous.emptyMessage != nil && !synchronous.isPreviewing
           && synchronous.thumbnailResults.isEmpty && synchronous.previewImageData == nil,
           "empty discovery shows an empty state and holds no spinner or old picture")
}

/// Preview success, not discovery alone, admits the explicit apply command.
private func dailyBackgroundApplyAdmissionCheck(expect: (Bool, String) -> Void) {
    let current = ContentKey(scene: .a, outfit: .r1, time: .evening)
    let other = ContentKey(scene: .b, outfit: .r2, time: .evening)
    let model = DailyBackgroundChooserModel()
    model.availableKeysProvider = { [current, other] }
    model.timeProvider = { .evening }
    var requests: [(ContentKey, (DailyBackgroundPreviewResult) -> Void)] = []
    var applied: [ContentKey] = []
    model.onRequestPreview = { key, _, completion in requests.append((key, completion)) }
    model.onApply = { applied.append($0); return true }
    model.present(currentKey: current)
    model.selectNext()
    expect(!model.canApplySelection && !model.applySelection() && applied.isEmpty,
           "a pending selected preview blocks both the visible apply action and direct model command")
    let unsupported = DailyPreviewOutcome.unavailable(other, "typed unsupported fixture", kind: .unsupported)
    requests.last?.1(DailyBackgroundPreviewResult(unsupported))
    let failedRequests = requests.count
    model.retryPreview()
    expect(model.previewFailureKind == .unsupported && !model.canRetryPreview
           && requests.count == failedRequests && !model.canApplySelection && !model.applySelection(),
           "typed unsupported evidence survives the Control wrapper, prevents futile retry and blocks apply")
    expect(model.candidates.first { $0.isCurrent }?.key == current && applied.isEmpty,
           "browsing an unsupported resource never changes the configured background")

    // A new authorized presentation can re-evaluate the source. A recoverable failure keeps retry.
    model.present(currentKey: current)
    requests.last?.1(.unavailable(other, "recoverable fixture"))
    expect(model.canRetryPreview && !model.canApplySelection && !model.applySelection(),
           "a recoverable selected failure offers retry while still refusing apply")
    model.retryPreview()
    expect(model.isPreviewing && !model.canApplySelection && !model.applySelection(),
           "retry loading cannot race a new apply")
    requests.last?.1(.image(other, Data([1])))
    expect(model.canApplySelection && model.previewFailureKind == nil,
           "successful recovery clears typed failure and admits the selected resource")
    model.updatePreviewMetrics(size: CGSize(width: 480, height: 220), scale: 2)
    expect(model.previewImageData != nil && model.isPreviewing && !model.applySelection(),
           "retaining an old-size still during geometry reload never admits a pending preview")
    requests.last?.1(.image(other, Data([2])))
    expect(model.applySelection() && applied == [other] && model.selectionIsCurrent,
           "only a completed selected preview permits the ordinary apply command once")
    model.dismissed()
    expect(!model.canApplySelection && model.previewFailureKind == nil,
           "hidden chooser state holds no failure evidence or apply admission")
}

private final class CompanionRetainedWindowFixture: NSWindow {
    var fixtureVisible = true
    var fixtureOccluded = false
    var fixtureOnActiveSpace = true
    var fixtureKey = false
    override var isKeyWindow: Bool { fixtureKey }
    override var isOnActiveSpace: Bool { fixtureOnActiveSpace }
    override var isVisible: Bool { fixtureVisible }
    override var occlusionState: NSWindow.OcclusionState { fixtureVisible && !fixtureOccluded ? [.visible] : [] }
}

private final class CompanionSurfaceResizeFixture: CompanionFrameSurfaceView {
    var fixtureResizing = false
    var fixtureEmpty = false
    var fixtureApplicationActive = false
    override var applicationIsActive: Bool { fixtureApplicationActive }
    override var inLiveResize: Bool { fixtureResizing }
    override var visibleRect: NSRect { fixtureEmpty ? .zero : super.visibleRect }
}
