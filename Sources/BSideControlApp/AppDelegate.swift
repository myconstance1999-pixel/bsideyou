// BSideControlApp — AppDelegate: app lifecycle, wiring, single resource-selection entry,
// ResourceStage machine, window presentation (accessory ⇄ regular dance), onboarding trigger.
// UI never touches players: everything flows Command → DesiredState → Agent (AGENTS.md #5).

import AppKit
import SwiftUI
import BSideCore
import BSidePlatform

enum ResourceSelectionOutcome {
    case accepted(summary: String)
    case failed(reason: String)
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let supervisor = AgentSupervisor()
    var prefs = AppPreferences.load()
    let statusItemController = StatusItemController()
    let login = LoginItemCoordinator()
    let controlCenterModel = ControlCenterModel()
    let dailyActivityModel = DailyActivityRecommendationModel()
    let playbackHistory = PlaybackHistoryController()
    private let songHistory = SongPlaybackHistoryController()
    private var pendingSongNavigation: UUID?
    let studyTimer = StudyTimerController()
    private var lastPreferencesSaveError: String?
    /// Brief nonmodal identity status for the existing diagnostics projection; nil when quiet.
    private var dailyDirectoryIdentityStatus: String?
    private var performanceDirectoryIdentityStatus: String?

    private(set) var resourceStage: ResourceStage = .unconfigured
    private(set) var resourceStageDetail = ""
    private(set) var resourceStageAt = Date()
    private var resourceStageRevision: UInt64 = 0
    /// A rejected new selection must not borrow discovery or health from the still-running
    /// previous root. Clear only when a directory selection actually validates (or on reset).
    private(set) var dailyCatalogSelectionFailed = false
    private(set) var dailyAssetIssue: DailyAssetIssue?
    private var lastAttemptedResourceURL: URL?
    private var lastAttemptedResourceAccess: DirectoryAccessLease?
    private var dailyDirectoryAccepted = false
    private var dailyDirectoryWatching = false
    private var dailyDirectoryRetryRequested = false
    private lazy var dailyDirectoryMonitor = DailyDirectoryMonitor(
        onRefresh: { [weak self] in self?.refreshDailyDirectory($0) },
        onFailure: { [weak self] issue in
            guard let self else { return }
            self.dailyDirectoryRetryRequested = false
            self.dailyCatalogSelectionFailed = true
            // A rejected new selection preserves the old root. Failure of the accepted root
            // must also stop future Agent discovery/reads, not merely show an error in the UI.
            if self.dailyDirectoryAccepted { self.supervisor.invalidateDailyAssets(issue) }
            self.invalidateDailyPreviewBinding()
            self.setStage(.failed(.resourceUnavailable), issue.recoveryMessage, issue: issue)
        },
        onIdentityConflict: { [weak self] in
            guard let self else { return }
            self.dailyDirectoryRetryRequested = false
            self.dailyCatalogSelectionFailed = true
            if self.dailyDirectoryAccepted { self.supervisor.invalidateDailyAssets(.authorizationRequired) }
            _ = self.dailyIdentityConflict()
        })
    private lazy var performanceDirectories = PerformanceDirectoryController(
        library: { [weak self] in self?.performanceModel.library },
        onUpdate: { [weak self] in self?.applyPerformanceDirectoryUpdate($0) })
    /// ADR-022 owner of the explicit local song catalog. ControlApp is the sole persistent
    /// owner; the Agent only ever receives a typed local reference plus one file binding.
    private lazy var localSongs = LocalSongLibraryController(
        library: { [weak self] in self?.performanceModel.library },
        // Narrow access to the ACCEPTED official source binding only. The local scan uses its
        // exact contained locations to skip reviewed official files; a matching name elsewhere is
        // never treated as duplication.
        officialSourceRoot: { [weak self] in self?.performanceDirectories.binding?.access.url },
        onCatalog: { [weak self] catalog, message in
            self?.performanceModel.localCatalog = catalog
            self?.performanceModel.localMessage = message
        })
    /// ADR-022 automatic discovery. It only PROPOSES a bounded plan; the official bind and every
    /// local import still flow through the existing strict controllers, so this never owns
    /// identity, numbering, selection or persistence.
    private lazy var songResourceDiscovery = AutomaticSongResourceDiscovery(
        seams: {
            var seams = SongResourceDiscoverySeams.production
            seams.savedOfficialRootPath = { [weak self] in self?.prefs.performanceRoot }
            return seams
        }(),
        library: { [weak self] in self?.performanceModel.library },
        onPlan: { [weak self] plan in self?.applySongResourceDiscovery(plan) },
        onFailure: { [weak self] message in self?.performanceModel.localMessage = message })
    private var activeDirectoryPanel: NSOpenPanel?
    /// True while the pending official selection was requested by automatic discovery, so its own
    /// `.ready` does not immediately start a second discovery pass for the same package.
    private var isApplyingAutomaticOfficialBind = false
    /// Manual official choices always win over a late automatic plan (see the discovery helper).
    private let songDiscoveryIntent = SongResourceDiscoveryIntentGate()

    private var resourceRetryURL: URL? {
        lastAttemptedResourceURL ?? prefs.assetPath.map { URL(fileURLWithPath: $0) }
    }
    var canRetryDailyResource: Bool { resourceRetryURL != nil }

    let performanceModel = PerformanceBrowserModel()
    /// ADR-024 daily background chooser state. It resolves its preview URLs and its ordinary
    /// apply command against THIS delegate's authorized binding, so the chooser can never reach a
    /// folder the rest of the app is not already using.
    private lazy var dailyBackgroundsModel: DailyBackgroundChooserModel = {
        let model = DailyBackgroundChooserModel()
        model.onRequestPreview = { [weak self] key, pixelSize, completion in
            guard let self else {
                completion(DailyBackgroundPreviewResult.unavailable(key, "预览服务不可用。"))
                return
            }
            self.requestDailyPreview(key, pixelSize: pixelSize) { outcome in
                completion(DailyBackgroundPreviewResult(outcome))
            }
        }
        model.onCancelPreview = { [weak self] in self?.dailyPreview.cancel() }
        model.timePolicyProvider = { [weak self] in self?.controlCenterModel.subtitle ?? "" }
        model.followsAutomaticTime = { [weak self] in self?.prefs.desired.timeMode == .auto }
        model.pendingSwitchProvider = { [weak self] in self?.controlCenterModel.dailySwitchMessage }
        model.onApply = { [weak self] key in
            self?.controlCenterModel.selectDailyContent(key) ?? false
        }
        // Core's `dailySourceKey` is nil while the time policy is automatic, so the chooser's
        // current/badge key is resolved from scene + outfit + the SAME effective time the daily
        // picture follows. Activity requests keep the unmodified Core semantics.
        model.currentKeyProvider = { [weak self] in
            guard let self else { return nil }
            return DailyBackgroundChooserModel.backdropKey(desired: self.prefs.desired, at: Date())
        }
        return model
    }()
    /// Bounded, on-demand still extraction (Platform). It owns one in-flight request at a time
    /// and retains the accepted directory lease for the duration of each extraction.
    private let dailyPreview = DailyPreview()
    private let homePreviewService = DailyPreview()
    private lazy var homePreview: CompanionHomePreview = {
        let model = CompanionHomePreview()
        model.request = { [weak self] key, size, completion in
            guard let self else { return }
            // These exact evening sources were visually reviewed ten seconds into their rest
            // shot. Other keys and chooser previews retain the generic extraction position.
            let seconds: Double
            if key.scene == .a, key.time == .evening, key.outfit == .r1 || key.outfit == .r2,
               let entry = DailyActivityCatalog.entry(for: key, activityID: .rest) {
                seconds = entry.point.seconds + 10
            } else {
                seconds = 5
            }
            self.requestDailyPreview(key, pixelSize: size, atSeconds: seconds,
                                     service: self.homePreviewService) {
                completion(DailyBackgroundPreviewResult($0))
            }
        }
        model.cancel = { [weak self] in self?.homePreviewService.cancel() }
        model.toggleFullScreen = { [weak self] in self?.companionPresentation.toggle() }
        model.streamChanged = { [weak self] request in self?.supervisor.setHomeCompanionStream(request) }
        model.acknowledge = { [weak self] acknowledgement in self?.supervisor.acknowledgeHomeCompanionFrame(acknowledgement) }
        return model
    }()
    /// The ACCEPTED daily preview binding: the catalog validated for the accepted root, the exact
    /// lease that was accepted for it, and the identity anchor captured at acceptance. A preview
    /// never resolves a bookmark on its own, so it cannot reach a folder the rest of the app has
    /// not already accepted and identity-checked.
    private struct AcceptedDailyPreviewBinding {
        let bundle: AssetBundle
        let lease: DirectoryAccessLease
        let identity: DirectoryIdentitySnapshot?
    }
    private var acceptedDailyPreviewBinding: AcceptedDailyPreviewBinding?
    /// Inert outside the isolated scenario seam: it holds no pending stop unless an
    /// explicitly opted-in scenario step arms one. Product commands never consult it.
    private let performanceScenarioStop = PerformanceScenarioStopController()
    private var performanceWindow: NSWindow?
    private var performanceBoundaryTimer: Timer?
    private var onboardingWindow: NSWindow?
    // Keep navigation and choices across directory-panel callbacks and window reopening.
    private lazy var onboardingModel = OnboardingViewModel(
        pickResource: { [weak self] in self?.runOnboardingResourcePick() },
        finish: { [weak self] login, profile in self?.completeOnboarding(loginEnabled: login, initialProfileID: profile) },
        stageProbe: { [weak self] in
            OnboardingProbe(assetPath: self?.prefs.assetPath, stage: self?.resourceStage ?? .unconfigured,
                            catalogSummary: self?.supervisor.lastSnapshot?.catalogSummary)
        })
    private var settingsWindow: NSWindow?
    private var helpWindow: NSWindow?
    private var diagnosticsWindow: NSWindow?
    private var dailyActivityWindow: NSWindow?
    private var diagnosticsText: NSTextView?
    private var commandWindow: NSWindow?
    private var commandField: NSTextField?
    private var commandHint: NSTextField?
    private var observers: [NSObjectProtocol] = []
    /// Candidate-only persistent main window (ADR-021). It follows the established ADR-010
    /// window lifecycle used by Settings/Help/Onboarding (lazy single instance,
    /// `isReleasedWhenClosed = false`, keeping `.regular` even after its window closes).
    /// Cold launch, the menu icon, ⌘⇧C and a LaunchServices reopen all raise
    /// THIS same retained window; the ordinary variant keeps the transient status-item popover.
    private var candidateWindow: NSWindow?
    private let companionPresentation = CompanionWindowPresentation()
    /// Notch quick-control panel (candidate only). ONE nonactivating NSPanel owned for the app
    /// lifetime once first opened; it reuses the shared models/commands and is shut down (tasks,
    /// observers, window) from `applicationWillTerminate`. Never a playback or desktop-video host.
    private var notchPanelController: NotchPanelController?
    /// Transient candidate page selection. In-memory only, never persisted (ADR-021).
    let candidateNav = CandidateNavigationModel()
    /// True only for the fixed daily-candidate identity pair. A dev/test binary without a
    /// recognized bundle identifier is treated as ordinary.
    var isDailyCandidate: Bool {
        let variant = Bundle.main.bundleIdentifier.flatMap { AppIdentity.variant(forBundleIdentifier: $0) }
        return variant == .dailyCandidate || variant == .desktopPreview
    }

    var isDesktopPreview: Bool {
        Bundle.main.bundleIdentifier == AppIdentity.desktopPreviewBundleIdentifier
    }
    private var desktopWorkspace: DesktopWorkspaceController?

    private func showDesktopDrawer(_ action: DesktopWorkspaceAction) {
        guard isDesktopPreview else { return }
        candidateWindow?.orderOut(nil)
        notchPanelController?.collapse()
        if desktopWorkspace == nil {
            desktopWorkspace = DesktopWorkspaceController(
                storeURL: AppPaths.applicationSupport.appendingPathComponent("desktop-workspace.json"))
        }
        desktopWorkspace?.show(action)
    }

    @objc private func showDesktopApplications() { showDesktopDrawer(.applications) }
    @objc private func showDesktopFiles() { showDesktopDrawer(.files) }

    private func performDesktopAction(_ action: DesktopWorkspaceAction) {
        guard isDesktopPreview else { return }
        switch action {
        case .applications, .files: showDesktopDrawer(action)
        case .music: desktopWorkspace?.close(); showPerformanceLibrary()
        case .toggleMusic:
            if NotchMusicState.make(performanceModel, control: controlCenterModel).canPause {
                toggleMusicPauseFromQuickControl()
            } else {
                desktopWorkspace?.close()
                showPerformanceLibrary()
            }
        case .toggleCompanion:
            if !controlCenterModel.dailyVisualPauseIsRestricted { controlCenterModel.toggleDailyVisualPause() }
        case .companion: desktopWorkspace?.close(); openCandidateWindow(trigger: "desktop-companion", page: .daily)
        case .settings: desktopWorkspace?.close(); showSettings()
        case .study:
            desktopWorkspace?.close()
            openCandidateWindow(trigger: "desktop-study", page: .daily)
            candidateNav.showStudyControls()
        }
    }

    private func refreshDesktopWorkspace() {
        guard isDesktopPreview else { return }
        let music = NotchMusicState.make(performanceModel, control: controlCenterModel)
        supervisor.setDesktopWorkspace(DesktopWorkspacePresentation(isVisible: true,
            musicTitle: music.title, musicIsPlaying: music.canPause && !music.isPaused,
            musicCanToggle: music.canPause,
            pictureIsPaused: prefs.desired.dailyVisualPaused || prefs.desired.paused))
    }

    // MARK: - Lifecycle

    func applicationDidBecomeActive(_ notification: Notification) {
        // Approval/disable may have happened in System Settings while this window stayed open.
        // Read the system on activation; never register a login item from this lifecycle event.
        login.refresh()
        uiRefresh()
    }

    func applicationDidHide(_ notification: Notification) { refreshPerformanceClock() }
    func applicationDidUnhide(_ notification: Notification) { refreshPerformanceClock() }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if !studyTimer.prepareToQuit() {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "自习记录尚未保存"
            alert.informativeText = "留在应用中重试，或退出并放弃尚未保存的自习记录。"
            alert.addButton(withTitle: "留在应用")
            alert.addButton(withTitle: "仍然退出")
            if alert.runModal() != .alertSecondButtonReturn { return .terminateCancel }
        }
        if !playbackHistory.commitPending() {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "播放记录尚未保存"
            alert.informativeText = "本次已确认的播放记录无法保存。你可以留在应用中稍后重试，或退出并放弃未保存的部分。"
            alert.addButton(withTitle: "留在应用")
            alert.addButton(withTitle: "仍然退出")
            if alert.runModal() != .alertSecondButtonReturn { return .terminateCancel }
        }
        guard controlCenterModel.preferencesSaveStatus == .pending ||
              controlCenterModel.preferencesSaveStatus == .failed else { return .terminateNow }
        guard !savePreferences() else { return .terminateNow }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "设置尚未保存"
        alert.informativeText = "本次修改无法保存。现在退出可能丢失这些修改；你可以留在应用中重试保存。"
        alert.addButton(withTitle: "留在应用")
        alert.addButton(withTitle: "仍然退出")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        desktopWorkspace?.shutdown()
        desktopWorkspace = nil
        studyTimer.shutdown()
        // Cancel the notch panel's delayed task/observer and order its one window out before the
        // rest of the shutdown proceeds.
        notchPanelController?.shutdown()
        notchPanelController = nil
        // An accepted quit supersedes any in-flight local identity hash or discovery pass.
        localSongs.cancelPendingPlayback()
        songResourceDiscovery.cancel()
        // Saving and any failure decision happen before termination is accepted.
        performanceModel.queueState.stop()
        invalidateDirectoryPanel()
        dailyDirectoryMonitor.stop()
        performanceDirectories.reset()
        performanceBoundaryTimer?.invalidate()
        // Normal quit: persist the pending confirmed batch synchronously before supervision
        // stops. This is not a crash-recovery promise; an unconfirmed media tail is never kept.
        supervisor.stopAgent(intentional: true)
        lastAttemptedResourceAccess = nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installSingleInstanceGuard()
        installMainMenu()

        // Launch-at-login truth: RE-QUERY the real system status on every launch — a persisted
        // or remembered state is never trusted as authority (Slice 7 relaunch acceptance).
        login.refresh()

        supervisor.onEvent = { [weak self] event in self?.handleEvent(event) }
        supervisor.onSupervisionChanged = { [weak self] in self?.uiRefresh() }
        // Recording is opt-in and Agent-scoped: the controller mints the token, the supervisor
        // only delivers it to the CURRENT running generation.
        playbackHistory.onSend = { [weak self] request in
            _ = self?.supervisor.setHistoryRecording(request)
        }
        playbackHistory.onChange = { [weak self] in self?.uiRefresh() }

        // Page selection is transient presentation. Opening the daily page resolves its
        // presentation-time recommendation; it never issues a playback command.
        studyTimer.observeSystem()
        candidateNav.onPageSelected = { [weak self] page in
            guard let self, page == .daily else { return }
            self.dailyActivityModel.prepareForPresentation()
        }

        statusItemController.install { [weak self] in self?.statusItemPrimaryAction() }
        if isDailyCandidate {
            // Candidate quick controls kept as the RIGHT-click fallback: open, explicit fullscreen,
            // wallpaper pause/resume, music pause/resume, quit. A left click toggles the notch
            // panel instead (see `statusItemPrimaryAction`).
            statusItemController.installQuickMenu([
                .openWindow: { [weak self] in self?.openCandidateWindow(trigger: "status-menu") },
                .enterFullScreen: { [weak self] in self?.performanceModel.togglePicture() },
                .toggleWallpaperPause: { [weak self] in self?.controlCenterModel.togglePause() },
                .toggleMusicPause: { [weak self] in self?.toggleMusicPauseFromQuickControl() },
                .quit: { [weak self] in self?.quit() },
            ])
        }
        wireControlCenterModel()
        wirePerformanceModel()

        observers.append(NotificationCenter.default.addObserver(
            forName: .bsideOpenGuide, object: nil, queue: .main) { [weak self] _ in
            self?.showHelp()
        })

        if prefs.needsOnboarding {
            AppLog.control("onboarding.shown reason=needs-setup")
            showOnboarding()
        } else {
            // Present the retained candidate window before restoring either saved root.
            // Native directory-monitor registration can block; its earlier OS wait is unresolved.
            if !isDesktopPreview { presentCandidateWindow(trigger: "startup") }
            if let path = prefs.assetPath {
                AppLog.control("launch.autostart path=\(path)")
                restoreDailyResource()
            }
        }
        uiRefresh()
        // Restore the music root after the startup surface has been created.
        restorePerformanceDirectory()

        // The candidate's primary quick control is the collapsed shelf: create the affordance on
        // normal startup so it exists without hunting the menu. It starts collapsed and inert —
        // creating it issues no playback/queue/preference change. `--show-notch` is kept as an
        // explicit review seam and is idempotent.
        if isDailyCandidate {
            _ = ensureNotchPanel()
        }

        if let index = CommandLine.arguments.firstIndex(of: "--performance-scenario"),
           CommandLine.arguments.indices.contains(index + 1) {
            runPerformanceScenario(path: CommandLine.arguments[index + 1])
        }

        // Regression seam (real business entry without operating NSOpenPanel).
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--select-resource"), args.indices.contains(index + 1) {
            let path = args[index + 1]
            AppLog.control("seam.--select-resource path=\(path)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                _ = self?.handleSelectedResourceURL(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
            }
        }

        // Regression seam: schedule the PRODUCTION quit path (quit() → NSApp terminate →
        // shouldTerminate saves/asks on failure → willTerminate stops) N seconds after launch.
        // regression quit the real app without NSOpenPanel/GUI automation (Journey B seed / E).
        if let index = args.firstIndex(of: "--quit-after"), args.indices.contains(index + 1),
           let delay = Double(args[index + 1]), delay > 0 {
            AppLog.control("seam.quit-after \(delay)s")
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.quit()
            }
        }

        // Regression seam: programmatic PRODUCTION-METHOD lifecycle coverage — this is NOT
        // human GUI automation. It opens each real window/popover through the exact production
        // entry (showSettings / showHelp / showAbout / showDiagnostics / toggleControlCenter)
        // and dismisses each through the production close path, proving window-close is not
        // Quit. Inert in normal launches.
        if let index = args.firstIndex(of: "--exercise-windows"), args.indices.contains(index + 1) {
            let names = args[index + 1].split(separator: ",").map(String.init)
            AppLog.control("seam.exercise windows=\(names.joined(separator: ","))")
            exerciseWindows(names)
        }
    }

    /// One ControlApp + one status item + one agent (prompt rule #5). Belt-and-braces: the same
    /// identity-pair policy as the pre-NSApplication gate, reusing the effect shell so the log
    /// line is identical. A candidate/ordinary conflict cannot reach here (it exits in main).
    private func installSingleInstanceGuard() {
        SingleInstanceGuard.exitIfDuplicate()
    }

    /// Minimal main menu so ⌘, and ⌘Q work while any window is key.
    private func installMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 bsideyou", action: #selector(showAbout), keyEquivalent: "")
        let controlCenterItem = appMenu.addItem(withTitle: "控制中心", action: #selector(toggleControlCenter), keyEquivalent: "c")
        controlCenterItem.keyEquivalentModifierMask = [.command, .shift]
        if isDesktopPreview {
            let appsItem = appMenu.addItem(withTitle: "应用…", action: #selector(showDesktopApplications), keyEquivalent: "a")
            appsItem.keyEquivalentModifierMask = [.command, .shift]
            appsItem.target = self
            let filesItem = appMenu.addItem(withTitle: "文件盒…", action: #selector(showDesktopFiles), keyEquivalent: "f")
            filesItem.keyEquivalentModifierMask = [.command, .shift]
            filesItem.target = self
        }
        // Accessible application-menu command for the notch quick-control panel, so CUA/keyboard
        // can open or collapse it even when the menu-bar icon is not a practical target. Inert in
        // the ordinary variant (the notch panel is a candidate surface).
        let notchItem = appMenu.addItem(withTitle: "打开/收起浮窗", action: #selector(toggleNotchPanel), keyEquivalent: "n")
        notchItem.keyEquivalentModifierMask = [.command, .shift]
        appMenu.addItem(withTitle: "演奏曲库…", action: #selector(showPerformanceLibrary), keyEquivalent: "l")
        appMenu.addItem(withTitle: "播放队列…", action: #selector(showPerformanceQueue), keyEquivalent: "u")
        appMenu.addItem(withTitle: "日常…", action: #selector(showDailyActivityRecommendations), keyEquivalent: "d")
        appMenu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        // Diagnostics leaves the Control Center primary panel but stays reachable: Settings →
        // Advanced and this menu item both use the ordinary production window entry.
        appMenu.addItem(withTitle: "诊断…", action: #selector(showDiagnostics), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 bsideyou", action: #selector(quit), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        if isDesktopPreview {
            let editItem = NSMenuItem()
            let editMenu = NSMenu(title: "编辑")
            editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
            let redoItem = editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
            redoItem.keyEquivalentModifierMask = [.command, .shift]
            editMenu.addItem(.separator())
            editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
            editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
            editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
            editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
            editItem.submenu = editMenu
            mainMenu.addItem(editItem)
        }

        let helpItem = NSMenuItem()
        mainMenu.addItem(helpItem)
        let helpMenu = NSMenu(title: "帮助")
        helpMenu.addItem(withTitle: "bsideyou 使用指南", action: #selector(showHelp), keyEquivalent: "")
        helpItem.submenu = helpMenu
        NSApp.mainMenu = mainMenu
    }

    private func wireControlCenterModel() {
        controlCenterModel.onDesiredChange = { [weak self] desired in
            guard let self else { return }
            self.prefs.desired = desired.sanitized()
            self.controlCenterModel.preferencesDidChange()
            self.supervisor.recordDesiredState(self.prefs.desired)
            self.pushModelUpdate()
        }
        controlCenterModel.onDesiredSettled = { [weak self] in
            guard let self else { return }
            self.savePreferences()
            self.supervisor.sendDesiredState(self.prefs.desired)
        }
        controlCenterModel.onRequest = { [weak self] request in
            self?.perform(request)
        }
        // The explicit companion action reuses the ordinary guarded whole-combination command.
        dailyActivityModel.onApply = { [weak self] key in
            self?.controlCenterModel.selectDailyContent(key) ?? false
        }
        // The explicit activity entry is a transient current-session request: it persists the
        // resulting ordinary source preference but sends only the one activity request.
        dailyActivityModel.onStartActivity = { [weak self] request in
            self?.startDailyActivity(request) ?? false
        }
        // The current marker follows the daily clock; browsing exposes all admitted full videos.
        dailyBackgroundsModel.timeProvider = { [weak self] in
            guard let self else { return .evening }
            return DailyActivityRecommendationModel.resolvedTime(desired: self.prefs.desired, now: Date())
        }
        dailyBackgroundsModel.availableKeysProvider = { [weak self] in
            self?.controlCenterModel.dailyContentKeys
        }
        pushModelUpdate()
    }

    private func perform(_ request: ControlCenterRequest) {
        switch request {
        case .performanceLibrary: showPerformanceLibrary()
        case .dailyActivity: showDailyActivityRecommendations()
        case .settings: showSettings()
        case .chooseResource:
            statusItemController.closePopover()
            changeResourceFromUI()
        case .retryResource: retryDailyResource()
        case .help: showHelp()
        case .diagnostics: showDiagnostics()
        case .about: showAbout()
        case .commandBar: showCommandBar()
        case .restartAgent: restartAgent()
        case .retrySave: savePreferences()
        case .quit: quit()
        }
    }

    // MARK: - State plumbing

    /// Every preference write uses this one result path. Failure preserves in-memory intent and
    /// the last saved file; runtime health is independent, and only success clears the warning.
    @discardableResult
    private func savePreferences() -> Bool {
        let succeeded: Bool
        switch prefs.save() {
        case .success:
            lastPreferencesSaveError = nil
            succeeded = true
        case .failure(let error):
            lastPreferencesSaveError = String(describing: error)
            succeeded = false
        }
        controlCenterModel.preferencesSaveCompleted(succeeded: succeeded)
        refreshDiagnosticsText()
        return succeeded
    }

    private func mutate(_ change: (inout DesiredState) -> Void) {
        var desired = prefs.desired
        change(&desired)
        prefs.desired = desired.sanitized()
        savePreferences()
        supervisor.sendDesiredState(prefs.desired)
        pushModelUpdate()
    }

    /// One explicit activity entry. The resulting ordinary source preference is persisted and
    /// recorded for restart intent, but NO separate coalesced `setDesiredState` is emitted: the
    /// activity request carries the complete desired state atomically, so an ordinary source
    /// install cannot race in front of the entry. The transient request itself is never persisted
    /// and never replayed after Agent loss.
    private func startDailyActivity(_ request: DailyActivityRequest) -> Bool {
        guard supervisor.state == .running else { return false }
        prefs.desired = request.desired.sanitized()
        controlCenterModel.preferencesDidChange()
        pushModelUpdate()
        _ = savePreferences()
        supervisor.recordDesiredState(prefs.desired)
        guard supervisor.startDailyActivity(request) else { return false }
        AppLog.control("daily-activity.start id=\(request.requestID) activity=\(request.activityID.rawValue)")
        return true
    }

    // MARK: - Daily background preview (ADR-024)

    /// Resolve one exact authorized loop URL from the accepted binding. Nil when the binding does
    /// not admit this combination or no binding has been resolved yet.
    /// One bounded still request for the chooser. It reads ONLY the accepted binding: the catalog
    /// that was validated for the daily root plus the exact lease accepted with it. It never
    /// resolves a bookmark, never loads a catalog and never writes a preference on its own, so a
    /// preview cannot reach a directory the ordinary daily flow has not already accepted and
    /// identity-checked. The lease is handed to the request and retained there until the extraction
    /// callback ends.
    ///
    /// `pixelSize` is the chooser's real rendered pixel bounds (container size x backing scale,
    /// already product-bounded). It is carried into the request identity, so a resize or a display
    /// change can never reuse an undersized still. It never changes playback.
    private func requestDailyPreview(_ key: ContentKey,
                                     pixelSize: DailyPreviewPixelSize,
                                     atSeconds: Double = 5,
                                     service: DailyPreview? = nil,
                                     completion: @escaping (DailyPreviewOutcome) -> Void) {
        guard let accepted = acceptedDailyPreviewBinding else {
            completion(DailyPreviewOutcome.unavailable(key, "尚未授权日常素材目录，无法生成预览。"))
            return
        }
        // A detectable identity conflict (or a root that is not currently accepted) refuses the
        // preview instead of reading whatever now sits at the old path.
        guard dailyDirectoryAccepted, !dailyCatalogSelectionFailed,
              DailyPreviewAuthorization.accepts(
                  accepted: accepted.identity,
                  fresh: accepted.lease.identitySnapshot(provenance: .legacyAdopted)) else {
            completion(DailyPreviewOutcome.unavailable(key, "日常素材目录当前不可用，无法生成预览。"))
            return
        }
        guard let loopURL = accepted.bundle.loopFileURL(for: key) else {
            completion(DailyPreviewOutcome.unavailable(key, "这段画面不在当前素材目录中。"))
            return
        }
        (service ?? dailyPreview).request(DailyPreviewRequest(key: key, loopURL: loopURL,
                                                            atSeconds: atSeconds, pixelSize: pixelSize),
                             retaining: accepted.lease, completion: completion)
    }

    /// The daily root is invalidated, failed, rebound or replaced. The accepted preview binding
    /// and any in-flight or displayed still belong to the previous authorization, so all of them
    /// are dropped immediately. The chooser rebuilds its candidate list from the current
    /// discovered keys; while it is closed that rebuild starts no extraction.
    private func invalidateDailyPreviewBinding() {
        acceptedDailyPreviewBinding = nil
        dailyPreview.cancel()
        homePreview.invalidate()
        dailyBackgroundsModel.rootInvalidated()
    }

    private func pushModelUpdate() {
        controlCenterModel.resourceConfigured = prefs.assetPath != nil
        performanceModel.desired = prefs.desired
        refreshPerformanceClock()
        performanceModel.serviceReady = supervisor.state == .running && resourceStage == .ready
        if supervisor.state != .running { playbackHistory.agentLost(); homePreview.agentLost() }
        // A transient activity request cannot outlive its Agent: clear/cancel it (never replay).
        if supervisor.state != .running { dailyActivityModel.agentLost() }
        if supervisor.state != .running, performanceModel.queueState.isRunning {
            performanceModel.queueState.agentLost()
        }
        // An Agent loss invalidates every pending local request, session or not.
        if supervisor.state != .running {
            localSongs.cancelPendingPlayback()
            pendingSongNavigation = nil
            performanceModel.songNavigation.reset()
        }
        if supervisor.state != .running, performanceModel.sessionState.session != nil {
            performanceModel.sessionState.agentLost()
            performanceScenarioStop.cancel()
            performanceModel.report = nil
            performanceModel.message = "演奏已随播放器断开而结束；日常恢复后可重新点播。"
        }
        // Picture status belongs only to the live Agent generation.
        if supervisor.state != .running { performanceModel.clearPicturePresentation() }
        controlCenterModel.apply(desired: prefs.desired, stage: resourceStage,
                                 stageDetail: resourceStageDetail, snapshot: supervisor.lastSnapshot,
                                 supervision: supervisor.lifecyclePhase,
                                 dailyCatalogSelectionFailed: dailyCatalogSelectionFailed,
                                 dailyAssetIssue: dailyAssetIssue,
                                 canRetryDailyResource: canRetryDailyResource)
        // Companion window projects the same state; readiness is the existing resource/service
        // truth. Daily activity now has an independent engine and cannot replace the song.
        dailyActivityModel.update(
            desired: prefs.desired,
            resourceReady: resourceStage == .ready && supervisor.state == .running,
            dailyContentKeys: controlCenterModel.dailyContentKeys,
            performanceActive: false,
            pendingSwitchMessage: controlCenterModel.dailySwitchMessage)
        // An OPEN background chooser follows the same truth as the daily surface: an accepted
        // discovery, a preference change or a new effective daypart rebuilds it, while an
        // unrelated snapshot/progress push changes none of those and must not regenerate it.
        syncDailyBackgroundChooser()
        // Menu bar + Control Center share ONE semantic health projection — they cannot disagree.
        statusItemController.refresh(health: controlCenterModel.health,
                                     accessibilityText: controlCenterModel.statusText)
        refreshQuickMenuState()
        refreshDesktopWorkspace()
    }

    /// Change-detected refresh for the open daily background chooser. The three inputs it shows —
    /// the resolved backdrop key, the discovered keys and the effective daypart — are computed
    /// once and compared by the chooser; an unchanged push is a no-op, and a closed chooser does
    /// no work at all, so no extraction can be started behind it.
    private func syncDailyBackgroundChooser() {
        guard dailyBackgroundsModel.isPresented else { return }
        let now = Date()
        dailyBackgroundsModel.updatePlaybackStatus(pending: controlCenterModel.dailySwitchMessage,
                                                  timePolicy: controlCenterModel.subtitle)
        dailyBackgroundsModel.syncState(
            desired: prefs.desired,
            keys: controlCenterModel.dailyContentKeys,
            effectiveTime: DailyActivityRecommendationModel.resolvedTime(desired: prefs.desired, now: now),
            at: now)
    }

    func windowWillEnterFullScreen(_ notification: Notification) { companionPresentation.willTransition(notification.object as? NSWindow) }
    func windowWillExitFullScreen(_ notification: Notification) { companionPresentation.willTransition(notification.object as? NSWindow) }
    func windowDidEnterFullScreen(_ notification: Notification) { companionPresentation.didTransition(notification.object as? NSWindow) }
    func windowDidExitFullScreen(_ notification: Notification) { companionPresentation.didTransition(notification.object as? NSWindow) }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        companionPresentation.failed(window); homePreview.fullScreenTransitionFailed()
    }
    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        companionPresentation.failed(window); homePreview.fullScreenTransitionFailed()
    }

    private func handleEvent(_ event: AgentEvent) {
        switch event {
        case .desktopWorkspaceAction(let action):
            performDesktopAction(action)
        case .performance(let report):
            let previousSession = performanceModel.sessionState.session
            let accepted = performanceModel.sessionState.accept(report)
            AppLog.control("performance.report id=\(report.sessionID) state=\(report.state.rawValue) detail=\(report.detail ?? "-") accepted=\(accepted)")
            guard accepted else { return }
            performanceModel.report = report
            if report.isTerminal { performanceModel.clearPicturePresentation() }
            if let record = performanceModel.songNavigation.received(report, at: Date()) {
                songHistory.record(record)
                publishSongHistory()
            }
            // Scenario-only: an opted-in deferred stop fires here, once, on the matching
            // session's own accepted playing report. Inert when nothing is pending.
            performanceScenarioStop.receive(report)
            switch report.state {
            case .loading: performanceModel.message = "正在校验所选文件并加载音乐…"
            case .playing:
                if performanceModel.queueState.isRunning {
                    performanceModel.message = "正在播放队列。"
                } else {
                    performanceModel.message = "音乐播放中。"
                }
            case .paused: performanceModel.message = "音乐已暂停。"
            case .ended: performanceModel.message = "音乐已结束。"
            case .stopped: performanceModel.message = "音乐已停止。"
            case .failed: performanceModel.message = report.detail ?? "音乐无法播放。"
            }
            if report.state == .ended, pendingSongNavigation == nil,
               performanceModel.songNavigation.canForward {
                navigateSongHistory(1, mode: previousSession?.mode, paused: previousSession?.paused)
                return
            }
            if pendingSongNavigation != nil, report.isTerminal {
                // An explicit pending file admission owns the next decision, not an old EOF.
                if let previousSession { supervisor.stopPerformance(id: previousSession.id) }
                return
            }
            if let previousSession, previousSession.continuesQueue, report.isTerminal {
                switch performanceModel.queueState.received(report, favorites: performanceModel.favoriteQueueTargets, chooseIndex: Self.queueRandomIndex) {
                case .play(let entry):
                    startQueuedPerformance(entry, replacing: previousSession.id, explicitUserRequest: false)
                case .stopped:
                    if report.state == .ended {
                        supervisor.stopPerformance(id: previousSession.id)
                        performanceModel.message = "队列已播完；日常按当前策略继续。"
                    } else if report.state == .failed {
                        performanceModel.message = "队列已停止：\(performanceModel.message) 列表已保留，可处理后重新开始。"
                    }
                case .ignored:
                    // Stop can precede an already-enqueued EOF; the consumed item still needs release.
                    if report.state == .ended { supervisor.stopPerformance(id: previousSession.id) }
                }
            }
        case .performancePresentation(let report):
            performanceModel.receivePicturePresentation(report)
            refreshQuickMenuState()
        case .ready:
            AppLog.control("agent.handshake ready")
            playbackHistory.agentReady()
            refreshPerformanceClock()
            homePreview.agentReady()
        case .homeCompanionFrame(let frame):
            homePreview.receive(frame)
            return // Frame delivery never republishes UI or reevaluates playback policy.
        case .historyIntervals(let submissions):
            playbackHistory.receive(submissions)
        case .dailyActivity(let report):
            AppLog.control("daily-activity.report id=\(report.requestID) state=\(report.state.rawValue) detail=\(report.detail ?? "-")")
            dailyActivityModel.receiveActivityReport(report)
        case .runtimeSnapshot(let snap):
            AppLog.control("runtime.snapshot state=\(snap.state.rawValue) clip=\(snap.currentClip ?? "-") music=\(snap.musicVolume) ambient=\(snap.ambientVolume) reasons=\(snap.reasons.joined(separator: ","))")
            guard !dailyCatalogSelectionFailed else { uiRefresh(); return }
            if let issue = snap.dailyAssetIssue {
                setStage(.failed(.resourceUnavailable), issue.recoveryMessage, issue: issue)
            } else if let key = snap.missingDailyContent {
                // A saved or automatic target the supported set no longer offers: say it is
                // unavailable and point at the in-app background chooser, never at new footage.
                // The message names the ordinary daypart, not an internal material id (ADR-024).
                setStage(.failed(.resourceUnavailable),
                         "当前选择的日常画面（\(key.daypartLabel)）不可用，请在“日常”页更换背景或选择其他时段。")
            } else if snap.state == .playing || snap.state == .paused {
                if resourceStage != .ready { setStage(.ready, snap.currentClip ?? "") }
            } else if snap.state == .degraded || snap.state == .error {
                setStage(.failed(.service), Self.friendlyError(code: "snapshot", message: snap.lastError ?? snap.state.rawValue))
            }
        case .error(let code, let message):
            if code == "assetAuthorization" {
                dailyCatalogSelectionFailed = true
                setStage(.failed(.resourceUnavailable), DailyAssetIssue.authorizationRequired.recoveryMessage,
                         issue: .authorizationRequired)
                return
            }
            guard !dailyCatalogSelectionFailed else { uiRefresh(); return }
            setStage(.failed(code == "asset" ? .resourceUnavailable : .service),
                     Self.friendlyError(code: code, message: message),
                     issue: code == "asset" ? .readFailed : nil)
        case .degraded(let reason):
            guard !dailyCatalogSelectionFailed else { uiRefresh(); return }
            setStage(.failed(.service), Self.friendlyError(code: "degraded", message: reason))
        default:
            break
        }
        uiRefresh()
    }

    private func setStage(_ stage: ResourceStage, _ detail: String = "", issue: DailyAssetIssue? = nil) {
        resourceStageRevision &+= 1
        resourceStage = stage
        resourceStageDetail = detail
        dailyAssetIssue = issue
        resourceStageAt = Date()
        AppLog.control("stage=\(stage.logName) detail=\(detail.isEmpty ? "-" : detail)")
        pushModelUpdate()
    }

    private func uiRefresh() {
        pushModelUpdate()
        refreshDiagnosticsText()
    }

    /// Display wording only. Failure classification comes from the producer/code, never text.
    static func friendlyError(code: String, message: String) -> String {
        if code == "asset" { return "无法读取所选 BSide 资源" }
        if message.contains("无法读取") { return message }
        return "播放器遇到问题，正在保护当前状态"
    }

    // MARK: - THE resource selection entry (menu / onboarding / settings / seam all use this)

    private typealias DirectoryBinding = (lease: DirectoryAccessLease, persistentData: Data)
    /// One accepted restore/selection: lease + bookmark plus the identity anchor decision.
    private typealias DirectoryRestore = (lease: DirectoryAccessLease, persistentData: Data,
                                         identity: StoredDirectoryIdentity?,
                                         fresh: DirectoryIdentitySnapshot?,
                                         adoptAfterValidation: Bool)
    private static let dailyScopeMessage = "日常画面和环境音需要共同的目录授权。请改选包含 Wallpaper_Presence 与 Wallpaper_Ambience 的 assets、具体版本或安装目录。"

    /// Resolve the saved bookmark and compare the historical anchor to FRESH metadata BEFORE
    /// any renewal/validation/activation. A detectable conflict throws and leaves the saved
    /// path, bookmark and anchor untouched.
    private func restoreDirectory(path: String, bookmark: Data?,
                                  identity: StoredDirectoryIdentity?) throws -> DirectoryRestore {
        if let bookmark {
            let restored = try DirectoryAccessLease.resolvePersistent(bookmark)
            let fresh = restored.lease.identitySnapshot(provenance: .legacyAdopted)
            let outcome = DirectoryIdentityResolver.resolve(stored: identity, bookmark: bookmark, fresh: fresh)
            if let reason = outcome.conflictReason { throw DirectoryIdentityError.conflict(reason) }
            return (restored.lease, restored.renewedData ?? bookmark, outcome.identity, fresh,
                    outcome.adoptAfterValidation)
        }
        // Legacy paths can migrate only with the access the process actually has. A failed
        // bookmark resolution never enters this branch or falls back to the stored path.
        let migrated = try DirectoryAccessLease.migrateLegacyPath(path)
        let fresh = migrated.lease.identitySnapshot(provenance: .legacyAdopted)
        if let identity {
            // Existing record with no renewable bookmark: preserve it, never rebaseline.
            let outcome = DirectoryIdentityResolver.resolve(stored: identity, bookmark: Data(), fresh: fresh)
            if let reason = outcome.conflictReason { throw DirectoryIdentityError.conflict(reason) }
            return (migrated.lease, migrated.persistentData, outcome.identity, fresh, false)
        }
        // Prospective legacy adoption, committed only after ordinary validation succeeds.
        return (migrated.lease, migrated.persistentData, nil, fresh, true)
    }

    /// Honest, nonmodally-projected cross-restart identity conflict. The existing directory
    /// selection action is the only way to accept a new binding; cancelling changes nothing.
    /// Any still shown for the previous admission belongs to that admission: it is dropped here,
    /// like every other failed/rebound root, so a conflicting directory cannot keep displaying an
    /// already-extracted image.
    private func dailyIdentityConflict() -> ResourceSelectionOutcome {
        let message = "已保存的日常资源目录与当前目录身份不一致（可能已被替换）。原路径与授权保持不变；请重新选择原目录。取消不会更改已保存的绑定。"
        AppLog.error("resource.identity-conflict detail=saved-anchor-mismatch")
        invalidateDailyPreviewBinding()
        setStage(.failed(.resourceUnavailable), message, issue: .authorizationRequired)
        return .failed(reason: message)
    }

    @discardableResult
    func handleSelectedResourceURL(_ url: URL) -> ResourceSelectionOutcome {
        AppLog.control("resource.selected path=\(url.path)")
        dailyDirectoryMonitor.stop()
        dailyDirectoryWatching = false
        dailyDirectoryAccepted = false
        dailyDirectoryRetryRequested = false
        lastAttemptedResourceURL = url
        dailyCatalogSelectionFailed = true
        // A new explicit selection is a rebinding: the previous preview authorization and any
        // displayed still are no longer valid.
        invalidateDailyPreviewBinding()
        setStage(.validating, url.path)
        guard url.lastPathComponent != "Wallpaper_Presence" else {
            setStage(.failed(.resourceUnavailable), Self.dailyScopeMessage, issue: .authorizationRequired)
            return .failed(reason: Self.dailyScopeMessage)
        }
        do {
            // An explicit selection is a new binding: its fresh identity becomes the anchor.
            // If fresh metadata is unavailable, an explicit unverified record still blocks
            // any later automatic legacy adoption from establishing a new baseline.
            let selected = try DirectoryAccessLease.fromSelectedURL(url)
            let fresh = selected.lease.identitySnapshot(provenance: .explicitSelection)
            return validateDailyDirectory((selected.lease, selected.persistentData,
                DirectoryIdentityResolver.explicitSelection(fresh: fresh), fresh, false))
        } catch {
            return dailyAuthorizationFailed(error)
        }
    }

    private func restoreDailyResource() {
        guard let path = prefs.assetPath else { return }
        dailyDirectoryMonitor.stop()
        dailyDirectoryWatching = false
        dailyDirectoryAccepted = false
        dailyCatalogSelectionFailed = true
        // A new binding resolution invalidates the previous accepted catalog/lease used for
        // previews, cancels any still in flight and clears the chooser's displayed state.
        invalidateDailyPreviewBinding()
        setStage(.loading, path)
        do {
            let restored = try restoreDirectory(path: path, bookmark: prefs.assetBookmark,
                                                identity: prefs.assetIdentity)
            guard restored.lease.url.lastPathComponent != "Wallpaper_Presence" else {
                setStage(.failed(.resourceUnavailable), Self.dailyScopeMessage, issue: .authorizationRequired)
                return
            }
            _ = validateDailyDirectory(restored)
        } catch is DirectoryIdentityError {
            // Cold-start conflict: keep observing the SAVED anchor so a later automatic or
            // manual retry cannot silently adopt the replacement.
            dailyDirectoryMonitor.start(path: path, bookmark: prefs.assetBookmark,
                                        identity: prefs.assetIdentity, access: nil)
            dailyDirectoryWatching = true
            _ = dailyIdentityConflict()
        } catch {
            dailyDirectoryMonitor.start(path: path, bookmark: prefs.assetBookmark,
                                        identity: prefs.assetIdentity, access: nil)
            dailyDirectoryWatching = true
            _ = dailyAuthorizationFailed(error)
        }
    }

    private func dailyAuthorizationFailed(_ error: Error) -> ResourceSelectionOutcome {
        AppLog.error("resource.authorization failed: \(error)")
        invalidateDailyPreviewBinding()
        let filesystemIssue = DailyAssetIssue.classify(error)
        let issue: DailyAssetIssue = [.missingLocation, .accessDenied].contains(filesystemIssue)
            ? filesystemIssue : .authorizationRequired
        setStage(.failed(.resourceUnavailable), issue.recoveryMessage, issue: issue)
        return .failed(reason: issue.recoveryMessage)
    }

    private func validateDailyDirectory(_ restored: DirectoryRestore) -> ResourceSelectionOutcome {
        let url = restored.lease.url
        // Even a failed validation may be retried from this explicitly selected location.
        // Keep its access alive while the old Agent retains its own previous-root grant.
        lastAttemptedResourceAccess = restored.lease
        dailyDirectoryMonitor.start(path: url.path, bookmark: restored.persistentData,
                                    identity: restored.identity, access: restored.lease)
        dailyDirectoryWatching = true
        setStage(.validating, url.path)
        do {
            let bundle = try OfficialAssetProvider(assetPath: url.path).loadCatalog()
            let summary = "loops:\(bundle.catalog.loops.count) transitions:\(bundle.catalog.transitions.count) ambient:\(bundle.catalog.ambientTracks.count) unknown:\(bundle.catalog.unknownFiles.count)"
            AppLog.control("resource.validated \(summary)")
            setStage(.loading, url.path)
            // Prospective legacy adoption is committed only now, after validation succeeded.
            let adopted = restored.adoptAfterValidation ? DirectoryIdentityResolver.adopt(fresh: restored.fresh) : nil
            let committedIdentity = adopted ?? restored.identity
            prefs.assetPath = url.path
            prefs.assetBookmark = restored.persistentData
            prefs.assetIdentity = committedIdentity
            savePreferences()
            dailyDirectoryMonitor.commitIdentity(committedIdentity)
            dailyDirectoryIdentityStatus = DirectoryIdentityStatus.describe(committedIdentity, fresh: restored.fresh)
            setStage(.startingPlayback, url.path)
            dailyCatalogSelectionFailed = false
            dailyDirectoryAccepted = true
            // Keep this binding's catalog and exact accepted lease so the background chooser
            // resolves an exact loop URL from the SAME admission the rest of the app uses, and
            // retains that lease for as long as a still extraction can run.
            homePreview.invalidate()
            acceptedDailyPreviewBinding = AcceptedDailyPreviewBinding(
                bundle: bundle, lease: restored.lease, identity: restored.fresh)
            supervisor.start(assetPath: url.path, desired: prefs.desired, access: restored.lease)
            return .accepted(summary: summary)
        } catch {
            AppLog.error("resource.validation failed: \(error)")
            // A failed validation must never leave the previous accepted preview binding behind.
            invalidateDailyPreviewBinding()
            let issue = DailyAssetIssue.classify(error)
            if let validation = error as? AssetValidationError,
               case .ambiguousLayouts(let paths) = validation {
                let versions = paths.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: "、")
                let message = "发现多个可用版本（\(versions)），请选择其中一个版本文件夹。"
                setStage(.failed(.resourceUnavailable), message, issue: issue)
                return .failed(reason: message)
            }
            setStage(.failed(.resourceUnavailable), issue.recoveryMessage, issue: issue)
            return .failed(reason: issue.recoveryMessage)
        }
    }

    private func retryDailyResource() {
        if dailyDirectoryWatching {
            dailyDirectoryRetryRequested = true
            dailyDirectoryMonitor.refresh()
        } else if let url = lastAttemptedResourceURL {
            _ = handleSelectedResourceURL(url)
        } else {
            restoreDailyResource()
        }
    }

    private func refreshDailyDirectory(_ binding: DailyDirectoryMonitor.Binding) {
        let requestedRetry = dailyDirectoryRetryRequested
        dailyDirectoryRetryRequested = false
        guard dailyDirectoryAccepted else {
            // The user selected this directory but it was not yet usable. Completing that
            // outstanding selection retains the original validation/start behavior.
            _ = validateDailyDirectory((binding.access, binding.bookmark, binding.identity,
                                        binding.freshIdentity, binding.adoptAfterValidation))
            return
        }
        lastAttemptedResourceURL = binding.access.url
        lastAttemptedResourceAccess = binding.access
        let adopted = binding.adoptAfterValidation ? DirectoryIdentityResolver.adopt(fresh: binding.freshIdentity) : nil
        let committedIdentity = adopted ?? binding.identity
        if prefs.assetPath != binding.access.url.path || prefs.assetBookmark != binding.bookmark
            || prefs.assetIdentity != committedIdentity {
            prefs.assetPath = binding.access.url.path
            prefs.assetBookmark = binding.bookmark
            prefs.assetIdentity = committedIdentity
            savePreferences()
        }
        dailyDirectoryIdentityStatus = DirectoryIdentityStatus.describe(committedIdentity, fresh: binding.freshIdentity)
        // Carry the finalized record back so a later ordinary refresh cannot re-adopt.
        dailyDirectoryMonitor.commitIdentity(committedIdentity)
        dailyCatalogSelectionFailed = false
        // The monitor verified this refreshed lease's identity before publishing it. Keep the
        // accepted preview binding current: renew its lease for the same root, or drop a catalog
        // that no longer describes the monitored root.
        if let accepted = acceptedDailyPreviewBinding {
            if accepted.lease.url.path == binding.access.url.path {
                acceptedDailyPreviewBinding = AcceptedDailyPreviewBinding(
                    bundle: accepted.bundle, lease: binding.access, identity: binding.freshIdentity)
            } else {
                invalidateDailyPreviewBinding()
            }
        }
        // Current-generation snapshots are additionally correlated to the new refresh ID.
        // Older playback reports cannot clear this loading state while discovery is pending.
        setStage(.loading, binding.access.url.path)
        if requestedRetry && (supervisor.state == .idle || supervisor.state == .degraded) {
            supervisor.start(assetPath: binding.access.url.path, desired: prefs.desired, access: binding.access)
        } else {
            supervisor.refreshAssets(access: binding.access, desired: prefs.desired)
        }
    }

    /// Foreground directory picker. Pre-navigated to a detected candidate when available.
    func presentResourcePicker(completion: @escaping (URL?) -> Void) {
        guard !focusExistingDirectoryPanel() else { return }
        AppLog.control("resourceMenu.clicked")
        let previousStage = resourceStage
        let previousDetail = resourceStageDetail
        let previousIssue = dailyAssetIssue
        setStage(.selecting)
        let selectionRevision = resourceStageRevision
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        if let current = resourceRetryURL {
            // A suggested parent is navigation only; the user's new OK supplies its grant.
            panel.directoryURL = current.lastPathComponent == "Wallpaper_Presence" ? current.deletingLastPathComponent() : current
            panel.message = current.lastPathComponent == "Wallpaper_Presence" ? Self.dailyScopeMessage : "选择原目录以重试，或定位移动后的新目录。找不到？按 ⌘⇧G 输入路径。"
        } else if let candidate = DefaultLocations.firstExisting() {
            panel.directoryURL = candidate
            panel.message = "已定位到检测到的目录（可直接点“选取”）。找不到？按 ⌘⇧G 输入路径。"
        } else {
            panel.message = "选择同时包含日常画面和环境音的安装目录、具体版本或 assets 文件夹。找不到？按 ⌘⇧G 输入路径。"
        }
        beginDirectoryPanel(panel) { [weak self] response, url in
            guard let self else { return }
            AppLog.control("resourcePanel.dismissed response=\(response.rawValue) url=\(url?.path ?? "-")")
            let selectedURL = response == .OK ? url : nil
            if selectedURL == nil, self.resourceStageRevision == selectionRevision {
                // Runtime events continue while the panel is open. Restore only our own
                // selecting state, never a newer ready/failure report.
                self.setStage(previousStage, previousDetail, issue: previousIssue)
            }
            completion(selectedURL)
        }
    }

    private func focusExistingDirectoryPanel() -> Bool {
        guard let panel = activeDirectoryPanel else { return false }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        return true
    }

    private func beginDirectoryPanel(_ panel: NSOpenPanel,
                                     completion: @escaping (NSApplication.ModalResponse, URL?) -> Void) {
        activeDirectoryPanel = panel
        // runModal inside a SwiftUI action can leave the native Open button disabled.
        // The asynchronous AppKit API lets that action return without a nested modal loop.
        panel.begin { [weak self, weak panel] response in
            guard let self, let panel, self.activeDirectoryPanel === panel else { return }
            self.activeDirectoryPanel = nil
            completion(response, panel.url)
        }
    }

    private func invalidateDirectoryPanel() {
        let panel = activeDirectoryPanel
        // Invalidate before cancelling: a completion delivered during cancellation must not
        // rebind resources or restart the Agent after reset/accepted termination.
        activeDirectoryPanel = nil
        panel?.cancel(nil)
    }

    func changeResourceFromUI() {
        presentResourcePicker { [weak self] url in
            guard let self, let url else { return }
            _ = self.handleSelectedResourceURL(url)
        }
    }

    // MARK: - Window presentation (accessory ⇄ regular dance, WinHub pattern)

    private func presentInOwnWindow(_ window: NSWindow) {
        // Opening another app-owned window does not reliably dismiss a transient popover.
        statusItemController.closePopover()
        window.delegate = self
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === performanceWindow || notification.object as? NSWindow === candidateWindow {
            performanceBoundaryTimer?.invalidate()
            performanceBoundaryTimer = nil
        }
        DispatchQueue.main.async {
            let visibleWindows = NSApp.windows.filter { $0.isVisible && $0.level == .normal }
            if visibleWindows.isEmpty && !self.isDailyCandidate {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        if notification.object as? NSWindow === performanceWindow || notification.object as? NSWindow === candidateWindow { refreshPerformanceClock() }
    }

    func windowDidMiniaturize(_ notification: Notification) {
        if notification.object as? NSWindow === performanceWindow || notification.object as? NSWindow === candidateWindow { refreshPerformanceClock() }
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        if notification.object as? NSWindow === performanceWindow || notification.object as? NSWindow === candidateWindow { refreshPerformanceClock() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Candidate-only LaunchServices reopen (Finder double-click / Dock click of the already
    /// running candidate, and the reopen that a raw duplicate process asks LaunchServices to
    /// deliver). It raises the candidate's persistent Control Center window; the SAME retained
    /// window is restored even when it is already open or miniaturized. It never starts or
    /// restarts an Agent, never closes the window and never creates a second control surface.
    /// Missing setup keeps its own surface, re-raised through the same production entry cold
    /// launch uses. The ordinary variant keeps AppKit's default reopen behavior (return true).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard isDailyCandidate else { return true }
        if prefs.needsOnboarding {
            showOnboarding()
            return true
        }
        if isDesktopPreview { showDesktopDrawer(.applications); return true }
        AppLog.control("candidate.reopen has-visible-windows=\(flag)")
        presentCandidateWindow(trigger: "reopen")
        return true
    }

    // MARK: - Control Center

    @objc func toggleControlCenter() {
        if isDesktopPreview { showDesktopDrawer(.applications); return }
        // The candidate has ONE control surface: the persistent Control Center window. The menu
        // icon and ⌘⇧C open/raise it; the ordinary app keeps the established transient popover.
        if isDailyCandidate {
            presentCandidateWindow(trigger: "menu")
            return
        }
        statusItemController.togglePopover { [weak self] in
            self?.controlCenterController() ?? NSViewController()
        }
    }

    /// The single Control Center content factory shared by the ordinary popover and the
    /// candidate window, so both surfaces are the same view over the same model.
    private func controlCenterController() -> NSViewController {
        NSHostingController(rootView: ControlCenterView(model: controlCenterModel))
    }

    /// Candidate main-window presentation for cold launch, LaunchServices reopen, the menu icon
    /// and every navigation entry. The candidate surface is ONE persistent, retained, resizable
    /// window hosting the unified shell (sidebar + selected page + shared music strip), because
    /// the previous separate Control Center/library/queue/settings windows were not one findable
    /// surface. It is presented through the established ADR-010 window path
    /// (`presentInOwnWindow`: `.regular` + activate + `makeKeyAndOrderFront`), which places and
    /// keeps it on the CURRENT Space without an all-spaces collection behavior. Idempotent:
    ///  * a VISIBLE onboarding window means setup is already the surface — nothing is presented;
    ///  * the window is created once and every repeat open raises that SAME retained instance (a
    ///    miniaturized one is restored); closing HIDES it, it is never toggled closed or duplicated.
    /// No Agent is started or restarted and no playback state is touched by this path.
    @discardableResult
    private func presentCandidateWindow(trigger: String) -> NSWindow? {
        guard isDailyCandidate else { return nil }
        guard onboardingWindow?.isVisible != true else { return nil }
        if let window = candidateWindow {
            if window.isMiniaturized { window.deminiaturize(nil) }
            presentInOwnWindow(window)
            refreshQuickMenuState()
            return window
        }
        let root = UnifiedCandidateWindow(
            navigation: candidateNav,
            controlCenter: controlCenterModel,
            performance: performanceModel,
            study: studyTimer,
            dailyActivity: dailyActivityModel,
            dailyBackgrounds: dailyBackgroundsModel,
            homePreview: homePreview, presentation: companionPresentation,
            showQueuePage: { [weak self] in self?.candidateNav.select(.queue) },
            makeSettingsActions: { [weak self] in
                self?.makeSettingsActions() ?? AppDelegate.placeholderSettingsActions()
            })
        let window = CompanionMainWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 740),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "bsideyou"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: root)
        window.contentMinSize = NSSize(width: 960, height: 680)
        window.setContentSize(NSSize(width: 1040, height: 740))
        window.center()
        candidateWindow = window
        companionPresentation.attach(window)
        window.exitCompanionFullScreen = { [weak self] in self?.companionPresentation.request(fullScreen: false) }
        AppLog.control("candidate.\(trigger) unified-window created size=1040x740 min=960x680 page=\(candidateNav.page.rawValue)")
        presentInOwnWindow(window)
        refreshQuickMenuState()
        return window
    }

    /// Raise the candidate window (if needed) and select a page. Page selection is transient
    /// state only: it never issues a playback or wallpaper command.
    func openCandidateWindow(trigger: String, page: CandidatePage? = nil) {
        guard isDailyCandidate else { return }
        desktopWorkspace?.close()
        // Navigation to another surface collapses the shelf first, so a pinned shelf can never
        // cover the destination. Presentation only: no playback/queue/preference change.
        notchPanelController?.collapse()
        presentCandidateWindow(trigger: trigger)
        if let page {
            let changedPage = candidateNav.select(page)
            // Presentation-time default only: resolve the current desired time and preselect
            // the matching reviewed material. A changed page already runs its selection callback;
            // reopening the selected daily page still needs a fresh presentation-time default.
            if page == .daily && !changedPage { dailyActivityModel.prepareForPresentation() }
        }
        refreshQuickMenuState()
    }

    /// Inert fallback for the Settings actions factory. Reached only if the delegate is already
    /// gone while the window is still hosted, in which case no action can do useful work.
    private static func placeholderSettingsActions() -> SettingsActions {
        SettingsActions(
            changeResource: {}, validateNow: {}, rerunOnboarding: {}, restartAgent: {},
            openLogs: {}, copyDiagnostics: {}, showDiagnostics: {}, resetPreferences: {},
            changeLogin: { _ in },
            loginState: { LoginItemProjection(system: .unknown) },
            loginDescribe: { "不可用" },
            catalogSummary: { "未加载" },
            historySettings: {
                PlaybackHistorySettings(isEnabled: false, intervalCount: 0, visualDuration: 0,
                                        musicDuration: 0, ambientDuration: 0, error: "历史记录不可用")
            },
            setHistoryEnabled: { _ in }, retryHistory: {}, clearHistory: {}, exportHistory: {},
            cropHistory: { _ in })
    }

    /// Music pause/resume from the menu-bar quick control. Delegates to the same model command
    /// the window strip uses, selecting the song or the independent companion soundtrack.
    func toggleMusicPauseFromQuickControl() {
        controlCenterModel.toggleCurrentMusicPause(performance: performanceModel)
        refreshQuickMenuState()
        refreshDesktopWorkspace()
    }

    /// The picture action only changes the current Agent window presentation. The home remains
    /// open and playback/session/queue/pause intent is untouched, including native Esc/close.
    func enterPerformanceFullScreenFromQuickControl() {
        setPerformancePictureExpanded(true)
    }

    private func setPerformancePictureExpanded(_ expanded: Bool) {
        guard let session = performanceModel.sessionState.session, session.mode == .watch,
              performanceModel.canTogglePicture else { return }
        let sent = expanded ? supervisor.enterPerformanceFullScreen(sessionID: session.id)
            : supervisor.exitPerformanceFullScreen(sessionID: session.id)
        if sent { notchPanelController?.collapse() }
    }

    /// Push current truth into the candidate quick menu (titles + enabled state).
    private func refreshQuickMenuState() {
        guard isDailyCandidate else { return }
        let session = performanceModel.sessionState.session
        statusItemController.refreshQuickMenu(StatusQuickMenuState.make(
            wallpaperPaused: prefs.desired.paused,
            musicSessionPresent: session != nil,
            musicSessionPaused: performanceModel.primaryMusicIsPaused,
            queueRunning: performanceModel.queueState.isRunning,
            watchSessionActive: performanceModel.canTogglePicture,
            pictureExpanded: performanceModel.pictureIsExpanded,
            companion: NotchMusicState.make(performanceModel, control: controlCenterModel)))
    }

    // MARK: - Notch quick-control panel (candidate)

    /// Status-item left click. The candidate's primary quick control is the notch panel; every
    /// other variant keeps the established Control Center popover. A right click is handled inside
    /// `StatusItemController` and still shows the full quick menu.
    private func statusItemPrimaryAction() {
        if isDailyCandidate {
            toggleNotchPanel()
        } else {
            toggleControlCenter()
        }
    }

    /// Accessible menu/status action: open the notch panel if needed, then toggle collapsed ⇄
    /// expanded. Presentation only: it never starts/restarts the player, drains or edits the
    /// queue, changes the selected version or writes preferences.
    @objc func toggleNotchPanel() {
        guard let controller = ensureNotchPanel() else { return }
        controller.toggle()
        AppLog.control("notch.toggle expanded=\(controller.isExpanded)")
    }

    /// Create the ONE retained panel on first use (idempotent) and show it collapsed.
    @discardableResult
    private func ensureNotchPanel() -> NotchPanelController? {
        guard isDailyCandidate else { return nil }
        if let existing = notchPanelController { return existing }
        let controller = makeNotchPanelController()
        controller.install()
        notchPanelController = controller
        AppLog.control("notch.install screen=\(NSScreen.main.map { "\(Int($0.frame.width))x\(Int($0.frame.height))" } ?? "none")")
        return controller
    }

    private func makeNotchPanelController() -> NotchPanelController {
        NotchPanelController(
            // Leaving the island's background page (back, close, collapse, screen change) releases
            // the shared chooser's in-flight request and displayed still. It applies nothing.
            onLeaveBackgroundPage: { [weak self] in
                guard let self, self.dailyBackgroundsModel.isPresentedInIsland else { return }
                self.dailyBackgroundsModel.dismissed()
            },
            contentBuilder: { [weak self] presentation, pageModel, layout in
                guard let self else {
                    // Delegate already gone while the hosted view is still alive: a fully inert view,
                    // so no action can reach a nil owner.
                    return NotchPanelRootView(presentation: presentation,
                                              pageModel: pageModel,
                                              controlCenter: ControlCenterModel(),
                                              performance: PerformanceBrowserModel(),
                                              study: StudyTimerController(),
                                              backgrounds: DailyBackgroundChooserModel(),
                                              layout: layout,
                                              actions: NotchControlActions())
                }
                return self.makeNotchRootView(presentation: presentation,
                                              pageModel: pageModel,
                                              layout: layout)
            })
    }

    private func makeNotchRootView(presentation: NotchPanelPresentation,
                                   pageModel: NotchIslandPageModel,
                                   layout: NotchShelfLayout) -> NotchPanelRootView {
        NotchPanelRootView(presentation: presentation,
                           pageModel: pageModel,
                           controlCenter: controlCenterModel,
                           performance: performanceModel,
                           study: studyTimer,
                           backgrounds: dailyBackgroundsModel,
                           layout: layout,
                           actions: makeNotchActions(),
                           studyActions: makeStudyActions())
    }

    /// Every island control forwards to the SAME shared model/command the full window and the
    /// status quick menu use. Music pause/volume target the currently active audio source;
    /// the queue/background pages live INSIDE the island (same shared models, same commands), and
    /// the full window stays an explicit secondary escape. Browsing never captures or replaces the
    /// queue and never starts playback.
    private func makeStudyActions() -> StudyTimerActions {
        StudyTimerActions(selectMode: { [weak self] in self?.studyTimer.selectMode($0) },
            toggle: { [weak self] in self?.studyTimer.toggle() },
            finish: { [weak self] in self?.studyTimer.finish() },
            openHistory: { [weak self] in self?.openCandidateWindow(trigger: "study-history", page: .study) })
    }

    private func makeNotchActions() -> NotchControlActions {
        var actions = NotchControlActions()
        actions.pauseOrResumeMusic = { [weak self] in self?.toggleMusicPauseFromQuickControl() }
        actions.previous = { [weak self] in self?.performanceModel.previousSong() }
        actions.next = { [weak self] in
            guard let self else { return }
            guard self.performanceModel.sessionState.session != nil
                    || self.performanceModel.queueState.isRunning else { return }
            self.performanceModel.nextInQueue()
            self.refreshQuickMenuState()
        }
        actions.stop = { [weak self] in self?.performanceModel.stop() }
        actions.toggleFavorite = { [weak self] in
            guard let self, let id = self.performanceModel.currentSongID else { return }
            self.performanceModel.toggleFavorite(id)
        }
        // Music volume through the existing Control Center setter: the same preference path the
        // Control Center popover and Settings use, and the same one the Agent is sent.
        actions.setMusicVolume = { [weak self] value in
            guard let self else { return }
            self.controlCenterModel.setCurrentMusicVolume(value, performance: self.performanceModel)
        }
        actions.playList = { [weak self] in self?.performanceModel.playSelectedFromList() }
        actions.shuffle = { [weak self] in self?.performanceModel.startFilteredShufflePlayback() }
        actions.chooseSongs = { [weak self] in
            self?.openCandidateWindow(trigger: "notch-choose", page: .library)
        }
        // The queue and background live INSIDE the island: same models, same existing commands, no
        // second window and no full-window detour for a routine adjustment. Opening the background
        // page presents the SAME shared chooser the daily page uses; the island only projects it and
        // applying stays an explicit `applySelection()` through the ordinary preference path.
        actions.setQueueOrder = { [weak self] in self?.performanceModel.setQueueOrder($0) }
        actions.openQueuePage = { [weak self] in self?.notchPanelController?.showQueuePage() }
        actions.openBackgroundPage = { [weak self] in
            guard let self else { return }
            // Presented at the ISLAND destination: the same chooser state and the same bounded
            // preview, but never the window/settings sheet and no Space activation.
            self.dailyBackgroundsModel.present(currentKey: nil, in: .island)
            self.notchPanelController?.showBackgroundPage()
        }
        actions.showMainPage = { [weak self] in self?.notchPanelController?.showMainPage() }
        actions.playQueueEntry = { [weak self] id in
            guard let self else { return }
            self.performanceModel.selectedQueueEntryID = id
            self.performanceModel.playSelectedQueueEntry()
        }
        actions.toggleGlobalPause = { [weak self] in self?.controlCenterModel.togglePause() }
        actions.enterFullScreen = { [weak self] in
            self?.enterPerformanceFullScreenFromQuickControl()
        }
        actions.openFullWindow = { [weak self] in
            self?.openCandidateWindow(trigger: "notch-home", page: .daily)
        }
        actions.toggle = { [weak self] in self?.toggleNotchPanel() }
        actions.collapse = { [weak self] in self?.notchPanelController?.collapse() }
        return actions
    }

    // MARK: - Performance library (ControlApp owns transient intent)

    private func wirePerformanceModel() {
        performanceModel.setPictureExpanded = { [weak self] expanded in
            self?.setPerformancePictureExpanded(expanded)
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: .NSSystemClockDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.refreshPerformanceClock()
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshPerformanceClock()
        })
        do { performanceModel.library = try PerformanceLibrary.bundled() }
        catch { performanceModel.message = String(describing: error) }
        performanceModel.root = prefs.performanceRoot
        performanceModel.queueState = PerformanceQueueState(configuration: prefs.performanceQueue ?? PerformanceQueueConfiguration())
        performanceModel.favorites = prefs.favoritePerformanceIDs ?? []
        performanceModel.favoriteLocalTrackIDs = prefs.favoriteLocalTrackIDs ?? []
        performanceModel.toggleFavorite = { [weak self] id in
            guard let self else { return }
            if self.performanceModel.localTrack(id) != nil {
                if !self.performanceModel.favoriteLocalTrackIDs.insert(id).inserted {
                    self.performanceModel.favoriteLocalTrackIDs.remove(id)
                }
            } else {
                let key = PerformanceID(id)
                if !self.performanceModel.favorites.insert(key).inserted {
                    self.performanceModel.favorites.remove(key)
                }
            }
            self.prefs.favoritePerformanceIDs = self.performanceModel.favorites
            self.prefs.favoriteLocalTrackIDs = self.performanceModel.favoriteLocalTrackIDs
            self.savePreferences()
        }
        performanceModel.pickRoot = { [weak self] in self?.pickPerformanceRoot() }
        performanceModel.refresh = { [weak self] in
            // The one explicit refresh action re-checks the official root and every local root,
            // and reruns the bounded discovery (a package downloaded since the last run appears
            // here without any new monitoring or polling).
            self?.reloadMediaRetention()
            self?.performanceDirectories.refresh()
            self?.localSongs.refresh()
            self?.songResourceDiscovery.discover()
        }
        // Explicit local songs (ADR-022): the same library surface, no separate source bucket.
        localSongs.load()
        reloadMediaRetention()
        performanceModel.addLocalRoot = { [weak self] in self?.pickLocalSongRoot() }
        performanceModel.refreshLocal = { [weak self] in
            self?.reloadMediaRetention()
            self?.localSongs.refresh()
        }
        performanceModel.renameLocal = { [weak self] trackID, title in
            self?.localSongs.rename(trackID: trackID, to: title)
        }
        performanceModel.classifyLocal = { [weak self] trackID, classification in
            self?.localSongs.setClassification(trackID: trackID, classification: classification)
        }
        performanceModel.selectLocalFile = { [weak self] trackID, fileID in
            self?.localSongs.selectFile(trackID: trackID, fileID: fileID)
        }
        performanceModel.playLocal = { [weak self] trackID, fileID, mode in
            self?.playLocalPerformance(trackID: trackID, fileID: fileID, mode: mode)
        }
        performanceModel.enqueueLocal = { [weak self] trackID, fileID, mode in
            self?.enqueueLocalPerformance(trackID: trackID, fileID: fileID, mode: mode)
        }
        performanceModel.play = { [weak self] id, presentation, mode in
            self?.playPerformance(id: id, presentation: presentation, mode: mode)
        }
        performanceModel.pause = { [weak self] in
            guard let self, let session = self.performanceModel.sessionState.session else { return }
            if self.prefs.desired.paused {
                self.controlCenterModel.resumeUserPause()
                self.setPerformancePaused(false)
            } else {
                self.setPerformancePaused(!session.paused)
            }
        }
        performanceModel.stop = { [weak self] in self?.stopMusicPlayback() }
        performanceModel.enqueue = { [weak self] id, presentation, mode in
            self?.enqueuePerformance(id: id, presentation: presentation, mode: mode)
        }
        performanceModel.startFilteredShuffle = { [weak self] snapshot in
            self?.startFilteredShufflePerformance(snapshot)
        }
        performanceModel.startListPlayback = { [weak self] snapshot, entryID in
            self?.startListPerformance(snapshot, entryID: entryID)
        }
        performanceModel.addAndPlay = { [weak self] entry in
            self?.addSelectionAndPlay(entry)
        }
        performanceModel.playNext = { [weak self] entry in
            self?.playNextPerformance(entry)
        }
        performanceModel.startQueue = { [weak self] in self?.startPerformanceQueue(entryID: $0) }
        performanceModel.nextInQueue = { [weak self] in self?.nextQueuedPerformance() }
        performanceModel.previousSong = { [weak self] in self?.navigateSongHistory(-1) }
        performanceModel.replaySongHistory = { [weak self] in self?.startSongHistory($0) }
        performanceModel.retrySongHistory = { [weak self] in
            self?.songHistory.reload()
            self?.publishSongHistory()
        }
        publishSongHistory()
        performanceModel.removeQueueEntry = { [weak self] id in
            guard let self else { return }
            let wasActive = self.performanceModel.queueState.activeEntry?.id == id
            guard self.performanceModel.queueState.remove(entryID: id) else { return }
            // Removing the entry whose local request is still being prepared invalidates it.
            if wasActive { self.localSongs.cancelPendingPlayback() }
            self.savePerformanceQueue()
        }
        performanceModel.moveQueueEntry = { [weak self] id, offset in
            guard let self, let index = self.performanceModel.queueState.configuration.entries.firstIndex(where: { $0.id == id }),
                  self.performanceModel.queueState.move(entryID: id, to: index + offset) else { return }
            self.savePerformanceQueue()
        }
        performanceModel.clearQueue = { [weak self] in
            guard let self else { return }
            self.performanceModel.queueState.clear()
            self.savePerformanceQueue()
        }
        performanceModel.setQueueOrder = { [weak self] order in
            guard let self, self.performanceModel.queueState.configuration.order != order else { return }
            self.performanceModel.queueState.setOrder(order)
            self.savePerformanceQueue()
        }
    }

    /// Start reconciling the saved performance root. Deliberately NOT part of `wirePerformanceModel`:
    /// the saved root may live under an OS-authorized location (the fixture and the owner's daily
    /// root do: `~/Downloads/...`). Registering the native change stream opens the root and every
    /// one of its ancestors, and the OS can hold that open while the folder authorization is
    /// undecided — so this must never run before the app's own user-visible surface exists.
    /// The caller invokes it only after the Control Center window has been presented; the scan
    /// itself was already asynchronous.
    /// Host evidence and the unresolved OS-gate question:
    /// `dist/bsideyou-closeout-excm_hnp/startup-repair/DIAGNOSIS.md`.
    private func restorePerformanceDirectory() {
        // Explicit local roots restore and rescan through the same non-blocking path.
        localSongs.restoreAndScan()
        if let root = prefs.performanceRoot {
            performanceDirectories.restore(path: root, bookmark: prefs.performanceBookmark,
                                           identity: prefs.performanceIdentity)
        }
        // Bounded automatic discovery runs only after the startup surface exists, exactly like the
        // saved-root restore above: discovering the already-downloaded known package must not add
        // a second manual click, but it must also never precede or replace the saved bindings.
        songResourceDiscovery.discover()
    }

    /// Apply a discovery plan through the existing controllers. Every step stays transactional:
    /// an absent/denied candidate is reported by the ordinary controller that already owns that
    /// recovery message, and manual selectors remain the fallback for unrecognized locations.
    private func applySongResourceDiscovery(_ plan: SongResourceDiscoveryPlan) {
        // A manual official choice always wins: a stale automatic plan is dropped entirely (the
        // manual-ready callback starts a NEW pass with the current saved binding).
        guard let plan = songDiscoveryIntent.planToApply(plan) else { return }
        // A saved official binding is authoritative and is never rebound from a candidate path.
        if let official = plan.official, prefs.performanceRoot == nil {
            isApplyingAutomaticOfficialBind = true
            performanceDirectories.select(official)
        }
        for extra in plan.extras { localSongs.admitAutoRoot(extra) }
    }

    @objc func showPerformanceLibrary() {
        // Candidate: a sidebar page of the single main window, never a second business window.
        if isDailyCandidate {
            openCandidateWindow(trigger: "menu-library", page: .library)
            return
        }
        if performanceWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 640),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "bsideyou 演奏曲库"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: PerformanceBrowserView(model: performanceModel,
                                                                               saveModel: controlCenterModel))
            window.center()
            performanceWindow = window
        }
        presentInOwnWindow(performanceWindow!)
        refreshPerformanceClock()
    }

    /// Music/settings menu entries select the matching page of the candidate main window;
    /// the ordinary variant keeps its standalone library window and menu behavior.
    @objc func showPerformanceQueue() {
        if isDailyCandidate {
            openCandidateWindow(trigger: "menu-queue", page: .queue)
            return
        }
        showPerformanceLibrary()
        performanceModel.section = .queue
    }

    // MARK: - Companion activity recommendations (own window, existing window lifecycle)

    @objc func showDailyActivityRecommendations() {
        // Candidate: the reviewed activity cards are part of the daily page.
        if isDailyCandidate {
            openCandidateWindow(trigger: "menu-daily", page: .daily)
            return
        }
        if dailyActivityWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 460),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "日常"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: DailyActivityRecommendationView(model: dailyActivityModel))
            window.center()
            dailyActivityWindow = window
        }
        // Refresh the projection before presenting; readiness may have changed since last open.
        pushModelUpdate()
        // Presentation-time default only: resolve the current desired time (Beijing clock for
        // automatic, the saved fixed choice otherwise) and preselect the matching material.
        // Browsing never applies or switches media, and no timer/polling is involved.
        dailyActivityModel.prepareForPresentation()
        presentInOwnWindow(dailyActivityWindow!)
    }

    private func refreshPerformanceClock() {
        // The Agent may intentionally have no clock timer while paused or performing.
        // Keep visible library candidates current without polling or waking hidden UI.
        performanceModel.objectWillChange.send()
        let visible = (isDailyCandidate ? candidateWindow : performanceWindow).map {
            $0.isVisible && !$0.isMiniaturized && !NSApp.isHidden && $0.occlusionState.contains(.visible)
        } ?? false
        homePreview.update(key: DailyBackgroundChooserModel.backdropKey(desired: prefs.desired, at: Date()),
                           windowVisible: visible)
        let next = visible && prefs.desired.timeMode == .auto ? BeijingClock.nextBoundary(after: Date()) : nil
        if let next, let timer = performanceBoundaryTimer, timer.isValid, timer.fireDate == next { return }
        performanceBoundaryTimer?.invalidate()
        performanceBoundaryTimer = nil
        guard let next else { return }
        let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            self?.performanceBoundaryTimer = nil
            self?.refreshPerformanceClock()
        }
        timer.tolerance = 1
        performanceBoundaryTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func pickPerformanceRoot() {
        guard !focusExistingDirectoryPanel() else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.message = "选择官方音乐总目录、分类目录或单首曲目文件夹。仅检查这个目录内的已知素材。"
        if let root = prefs.performanceRoot { panel.directoryURL = URL(fileURLWithPath: root) }
        beginDirectoryPanel(panel) { [weak self] response, url in
            guard response == .OK, let url else { return }
            self?.bindPerformanceURL(url)
        }
    }

    /// Generic Add Songs directory action (ADR-022): one explicitly selected folder becomes an
    /// authorized local root. Only metadata is scanned; no whole-disk traversal.
    private func pickLocalSongRoot() {
        guard !focusExistingDirectoryPanel() else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.message = "可选择父目录：每个包含视频的文件夹都会成为一首曲目，其中的文件是可选择的版本。"
        beginDirectoryPanel(panel) { [weak self] response, url in
            guard response == .OK, let url else { return }
            self?.localSongs.addRoot(url)
        }
    }

    func bindPerformanceRoot(_ root: String) {
        bindPerformanceURL(URL(fileURLWithPath: root))
    }

    private func bindPerformanceURL(_ url: URL) {
        // A manual choice is authoritative. Cancel any in-flight automatic discovery and record the
        // manual intent BEFORE the asynchronous selection starts, so a late plan cannot rebind the
        // official root while prefs.performanceRoot is still nil. The eventual ready event launches
        // a fresh discovery pass with the now-saved binding.
        songResourceDiscovery.cancel()
        songDiscoveryIntent.noteManualOfficialSelection()
        // Choosing a new root is an explicit rebind. Manual and automatic refreshes go
        // directly to discovery and never send a stop command for the active session.
        stopMusicPlayback()
        performanceDirectories.select(url)
    }

    private func applyPerformanceDirectoryUpdate(_ update: PerformanceDirectoryController.Update) {
        switch update {
        case .checking(let root):
            performanceModel.root = root.path
            performanceModel.scanning = true
            performanceModel.scanned = false
            performanceModel.scanFailure = nil
            performanceModel.scanDetail = nil
            performanceModel.message = "正在检查目录中的已知素材…"
        case .ready(let binding, let result, let monitoring):
            let wasManualOfficialSelection = songDiscoveryIntent.isManualOfficialSelectionPending
            songDiscoveryIntent.settleManualOfficialSelection()
            let officialRootChanged = prefs.performanceRoot != binding.access.url.path
            performanceModel.root = binding.access.url.path
            performanceModel.unavailable = result.snapshot.unavailable
            performanceModel.scanning = false
            performanceModel.scanned = true
            performanceModel.scanFailure = nil
            let total = performanceModel.library?.manifest.tracks.reduce(0) { $0 + $1.variants.count } ?? 0
            let count = total - result.snapshot.unavailable.count
            // The header shows one concise availability line; this technical count/validation
            // detail lives in that line's tooltip. A monitoring failure is actionable recovery,
            // so it remains the visible message instead of being folded into the tooltip.
            performanceModel.scanDetail = "找到 \(count) / \(total) 个已知版本；点播时校验完整文件。"
            performanceModel.message = monitoring ? "" : "自动检查暂不可用，请手动重新检查。"
            // Ordinary file events update candidates only. Do not rewrite preferences or
            // accidentally clear an unrelated save warning on every completed scan.
            let adopted = binding.adoptAfterValidation
                ? DirectoryIdentityResolver.adopt(fresh: binding.freshIdentity) : nil
            let committedIdentity = adopted ?? binding.identity
            if prefs.performanceRoot != binding.access.url.path || prefs.performanceBookmark != binding.bookmark
                || prefs.performanceIdentity != committedIdentity {
                prefs.performanceRoot = binding.access.url.path
                prefs.performanceBookmark = binding.bookmark
                prefs.performanceIdentity = committedIdentity
                savePreferences()
            }
            performanceDirectoryIdentityStatus = DirectoryIdentityStatus.describe(committedIdentity,
                                                                                  fresh: binding.freshIdentity)
            AppLog.control("performance.bound candidates=\(count) missing=\(result.snapshot.unavailable.count)")
            // A successfully chosen/changed official root reruns bounded discovery so the known
            // package's local sibling appears without a manual Add Songs click. The automatic
            // bind's own ready callback is skipped: it already ran discovery for this package.
            // A completed MANUAL selection always reruns discovery with the now-saved binding.
            if wasManualOfficialSelection || (officialRootChanged && !isApplyingAutomaticOfficialBind) {
                songResourceDiscovery.discover()
            }
            isApplyingAutomaticOfficialBind = false
        case .failed(let root, let message):
            songDiscoveryIntent.settleManualOfficialSelection()
            isApplyingAutomaticOfficialBind = false
            performanceModel.root = root.path
            performanceModel.scanning = false
            performanceModel.scanned = false
            performanceModel.scanFailure = message
            performanceModel.scanDetail = nil
            performanceModel.message = message
        }
    }

    func playPerformance(id: String, presentation: PerformancePresentation, mode: PerformancePlaybackMode = .watch) {
        pendingSongNavigation = nil
        performanceModel.songNavigation.cancelMove()
        // A new official play supersedes any in-flight local identity hash.
        localSongs.cancelPendingPlayback()
        // Explicit single-track playback exits queue execution without deleting its list.
        performanceModel.queueState.stop()
        performanceModel.selectedID = id
        if !performanceModel.automaticCamera { performanceModel.presentation = presentation }
        performanceModel.playbackMode = .watch
        guard let request = preparePerformance(id: id, presentation: presentation, mode: mode) else { return }
        _ = installPerformance(request)
    }

    /// Automatic advancement uses explicit entry values, leaving browsing selection alone.
    private func preparePerformance(id: String, presentation: PerformancePresentation,
                                    mode: PerformancePlaybackMode, paused: Bool = false,
                                    continuesQueue: Bool = false) -> PerformanceStartRequest? {
        let date = Date()
        performanceModel.desired = prefs.desired
        if let problem = performanceModel.playbackProblem(id: id, presentation: presentation, at: date) {
            performanceModel.message = problem
            return nil
        }
        guard let variant = performanceModel.selection(id, presentation: presentation, at: date) else {
            performanceModel.message = "所选曲目没有当前时段与机位的版本。"
            return nil
        }
        let grant: (root: String, bookmark: Data)
        do {
            // The controller checks the directory's runtime identity at this point.
            // Bookmark resolution can spell the same directory as /private/var rather
            // than /var, or follow a rename before its filesystem event updates the UI.
            grant = try performanceDirectories.transfer()
        } catch {
            performanceModel.scanFailure = "无法传递演奏素材的访问授权。请重新选择演奏素材目录。"
            performanceModel.message = performanceModel.scanFailure ?? ""
            AppLog.control("performance.grant-failed detail=\(error)")
            return nil
        }
        let session = PerformanceSession(variant: variant, mode: mode, paused: paused, continuesQueue: continuesQueue)
        return PerformanceStartRequest(session: session, mediaRoot: grant.root, accessBookmark: grant.bookmark)
    }

    /// Preserve origin for diagnostics; every accepted song uses the same player and never
    /// opens fullscreen or hides the home as a side effect of track selection.
    @discardableResult private func installPerformance(_ request: PerformanceStartRequest,
                                                       explicitUserRequest: Bool = true,
                                                       navigationIndex: Int? = nil,
                                                       navigationEntry: PerformanceQueueEntry? = nil) -> Bool {
        let request = UnifiedMusicPlayback.request(request)
        // Shared Core admission rule: a local request without its per-file binding and
        // transferred grant is refused here, before any media is read or request is sent.
        if let issue = request.admissionIssue {
            performanceModel.message = issue.description
            return false
        }
        controlCenterModel.selectSongSoundtrack()
        let session = request.session
        AppLog.control("performance.install session=\(session.id) mode=\(session.mode.rawValue) local=\(session.target.isLocalFile) explicit=\(explicitUserRequest) global-paused=\(prefs.desired.paused) session-paused=\(session.paused)")
        performanceModel.clearPicturePresentation()
        performanceModel.sessionState.start(session)
        // A new install replaces the previous session; a scenario-deferred stop must not
        // outlive the session it was armed for.
        performanceScenarioStop.reconcile(activeSessionID: session.id)
        performanceModel.report = PerformanceReport(sessionID: session.id, state: .loading)
        // Flush latest ControlApp intent before start; a coalesced pause must not trail the song.
        supervisor.sendDesiredState(prefs.desired)
        if !supervisor.startPerformance(session, mediaRoot: request.mediaRoot,
                                        accessBookmark: request.accessBookmark,
                                        fileBinding: request.fileBinding,
                                        automaticallyEnterFullScreen: false) {
            performanceModel.sessionState.agentLost()
            performanceModel.message = "播放器尚未就绪，请稍后重试。"
            return false
        }
        pendingSongNavigation = nil
        let record = SongPlaybackRecord(target: session.target, fileBinding: request.fileBinding,
            mode: session.mode, title: performanceModel.sessionTitle ?? "未命名歌曲", lastPlayed: Date())
        let queueEntry = navigationEntry ?? (performanceModel.queueState.activeSessionID == session.id
            ? performanceModel.queueState.activeEntry : nil)
        performanceModel.songNavigation.installed(sessionID: session.id,
            item: .init(record: record, queueEntry: queueEntry), navigationIndex: navigationIndex)
        // A new song starts in the existing desktop rendition. The home stays open.
        return true
    }

    /// Explicit single local song. The selected file is hashed and its identity persisted
    /// BEFORE the request is produced; a changed/missing file fails instead of falling back.
    private func playLocalPerformance(trackID: String, fileID: String, mode: PerformancePlaybackMode) {
        pendingSongNavigation = nil
        performanceModel.songNavigation.cancelMove()
        // Explicit single-track playback exits queue execution without deleting its list.
        performanceModel.queueState.stop()
        performanceModel.selectedID = trackID
        performanceModel.playbackMode = .watch
        prepareLocalPerformance(trackID: trackID, fileID: fileID) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.performanceModel.message = (error as? LocalSongError)?.description ?? String(describing: error)
            case .success(let grant):
                let session = PerformanceSession(target: .localFile(grant.reference), mode: mode)
                let request = PerformanceStartRequest(session: session, mediaRoot: grant.root,
                    accessBookmark: grant.transferBookmark, fileBinding: grant.binding)
                _ = self.installPerformance(request)
            }
        }
    }

    private static func queueRandomIndex(_ count: Int) -> Int {
        count > 0 ? Int.random(in: 0..<count) : 0
    }

    private func reloadMediaRetention() {
        let next = MediaRetentionState.load()
        guard next != performanceModel.mediaRetention else { return }
        // An explicit recheck may replace the reviewed choices. Do not deliver a grant that
        // was still being hashed under the previous choice; active playback is unchanged.
        localSongs.cancelPendingPlayback()
        pendingSongNavigation = nil
        performanceModel.songNavigation.cancelMove()
        performanceModel.mediaRetention = next
        // A queued local start may have been awaiting that canceled hash. Re-resolve the same
        // entry so it either starts the new keeper or follows the ordinary failed-start path.
        if performanceModel.queueState.isRunning, performanceModel.queueState.activeSessionID == nil,
           let entry = performanceModel.queueState.activeEntry {
            startQueuedPerformance(entry, replacing: performanceModel.sessionState.session?.id,
                                   explicitUserRequest: false)
        }
    }

    private func prepareLocalPerformance(trackID: String, fileID: String,
                                         completion: @escaping (Result<LocalPlaybackGrant, Error>) -> Void) {
        do {
            let choice = try performanceModel.localPlaybackChoice(trackID: trackID, requestedFileID: fileID)
            localSongs.preparePlayback(trackID: trackID, fileID: choice.file.id,
                                       expectedBinding: choice.expectedBinding, completion: completion)
        } catch { completion(.failure(error)) }
    }

    private func savePerformanceQueue() {
        prefs.performanceQueue = performanceModel.queueState.configuration
        savePreferences()
    }

    private func enqueuePerformance(id: String, presentation: PerformancePresentation, mode: PerformancePlaybackMode) {
        guard let track = performanceModel.library?.manifest.tracks.first(where: { $0.id == id }),
              track.variants.contains(where: { $0.presentation == presentation }) else {
            performanceModel.message = "所选曲目没有这个机位，无法加入队列。"
            return
        }
        let entry = PerformanceQueueEntry(performanceID: PerformanceID(id), presentation: presentation, mode: mode)
        guard performanceModel.queueState.append(entry) else { return }
        savePerformanceQueue()
    }

    /// A local entry captures the exact selected file at enqueue time. Changing the preferred
    /// version later never retargets this already saved entry.
    private func enqueueLocalPerformance(trackID: String, fileID: String, mode: PerformancePlaybackMode) {
        guard let track = localSongs.track(id: trackID),
              track.files.contains(where: { $0.id == fileID }) else {
            performanceModel.message = "曲目或文件不存在，无法加入队列。"
            return
        }
        let entry = PerformanceQueueEntry(trackID: trackID, fileID: fileID, mode: mode)
        guard performanceModel.queueState.append(entry) else { return }
        savePerformanceQueue()
    }

    /// Library 随机播放: replace the saved queue with the exact filtered snapshot, select the
    /// existing shuffle order and start immediately. A refused (empty/malformed) snapshot leaves
    /// the old queue, order and current playback untouched; a later per-entry start failure uses
    /// the existing stop path, never a skip or an alternate version.
    private func startFilteredShufflePerformance(_ snapshot: [PerformanceQueueEntry]) {
        AppLog.control("performance.shuffle-request count=\(snapshot.count) mode=\(performanceModel.playbackMode.rawValue) global-paused=\(prefs.desired.paused)")
        guard PerformanceQueueEdit.replaceWithShuffledSnapshot(&performanceModel.queueState,
                                                               snapshot: snapshot) else {
            performanceModel.message = "当前筛选结果没有可用素材，队列和播放保持不变。"
            return
        }
        savePerformanceQueue()
        startPerformanceQueue(entryID: nil)
    }

    /// Selected song 加入并播放: append the exact captured entry, persist it, then start THAT new
    /// entry in the same click. A refused append (empty/duplicate identity) changes nothing.
    private func addSelectionAndPlay(_ entry: PerformanceQueueEntry) {
        guard PerformanceQueueEdit.appendForImmediatePlay(&performanceModel.queueState, entry: entry) != nil else {
            performanceModel.message = "无法加入该条目，队列和播放保持不变。"
            return
        }
        savePerformanceQueue()
        startPerformanceQueue(entryID: entry.id)
    }

    private func startPerformanceQueue(entryID: String?) {
        pendingSongNavigation = nil
        performanceModel.songNavigation.cancelMove()
        // Beginning (or reselecting) a queue entry supersedes any in-flight local hash.
        localSongs.cancelPendingPlayback()
        let previousID = performanceModel.sessionState.session?.id
        guard let entry = performanceModel.queueState.begin(entryID: entryID, favorites: performanceModel.favoriteQueueTargets, chooseIndex: Self.queueRandomIndex) else {
            if let previousID { supervisor.stopPerformance(id: previousID) }
            performanceModel.message = "队列为空或所选条目已移除。"
            return
        }
        AppLog.control("performance.queue-selection entry=\(entry.id) mode=\(entry.mode.rawValue) global-paused=\(prefs.desired.paused) replacing=\(previousID ?? "none")")
        startQueuedPerformance(entry, replacing: previousID, explicitUserRequest: true)
    }

    /// ADR-024 list playback: replace the saved queue with the exact ordered snapshot of the
    /// currently visible eligible rows, keep the user's existing queue mode, and start the
    /// clicked/selected row. The snapshot was captured by the UI when the user acted, so later
    /// filter or search changes cannot mutate what continues after this row.
    private func startListPerformance(_ snapshot: [PerformanceQueueEntry], entryID: String) {
        guard PerformanceQueueEdit.replaceWithListSnapshot(&performanceModel.queueState,
                                                           snapshot: snapshot) else {
            performanceModel.message = "当前列表没有可用素材，队列和播放保持不变。"
            return
        }
        savePerformanceQueue()
        startPerformanceQueue(entryID: entryID)
    }

    /// 下一首播放: insert one exact entry immediately after the current one. The running song,
    /// its binding, the pause intent and the queue order are untouched; the queue is persisted
    /// because the inserted entry is durable selection intent.
    private func playNextPerformance(_ entry: PerformanceQueueEntry) {
        guard performanceModel.queueState.insertAfterActive(entry) else {
            performanceModel.message = "当前没有正在播放的歌曲，无法插入“下一首播放”；可用“稍后播放”加入队列。"
            return
        }
        savePerformanceQueue()
        performanceModel.message = "已设为下一首播放。"
    }

    /// Preserve explicit versus automatic origin for diagnostics; both retain the current
    /// picture presentation and never hide the home.
    private func startQueuedPerformance(_ entry: PerformanceQueueEntry, replacing previousID: String?,
                                        explicitUserRequest: Bool) {
        guard performanceModel.queueState.isRunning else { return }
        switch entry.target {
        case .official(let performanceID, let presentation):
            guard let request = preparePerformance(id: performanceID.rawValue, presentation: presentation,
                mode: entry.mode, paused: performanceModel.queueState.paused, continuesQueue: true),
                  performanceModel.queueState.bind(sessionID: request.session.id),
                  installPerformance(request, explicitUserRequest: explicitUserRequest) else {
                stopFailedQueueStart(replacing: previousID)
                return
            }
            AppLog.control("performance.queue-start entry=\(entry.id) session=\(request.session.id)")
        case .localFile(let trackID, let fileID):
            startQueuedLocalPerformance(entry, trackID: trackID, fileID: fileID,
                                        replacing: previousID, explicitUserRequest: explicitUserRequest)
        }
    }

    /// Local queue start: hash and record the captured file's identity first, then bind and
    /// install. A missing/changed file stops the queue with an actionable message.
    private func startQueuedLocalPerformance(_ entry: PerformanceQueueEntry, trackID: String,
                                             fileID: String, replacing previousID: String?,
                                             explicitUserRequest: Bool) {
        prepareLocalPerformance(trackID: trackID, fileID: fileID) { [weak self] result in
            // Only the exact entry that is still the active queue entry may install. `isRunning`
            // alone would let a previously active entry's late callback hijack a newer entry.
            guard let self, self.performanceModel.queueState.isRunning,
                  self.performanceModel.queueState.activeEntry?.id == entry.id else { return }
            switch result {
            case .failure(let error):
                self.performanceModel.message = (error as? LocalSongError)?.description ?? String(describing: error)
                self.stopFailedQueueStart(replacing: previousID)
            case .success(let grant):
                let session = PerformanceSession(target: .localFile(grant.reference), mode: entry.mode,
                    paused: self.performanceModel.queueState.paused, continuesQueue: true)
                let request = PerformanceStartRequest(session: session, mediaRoot: grant.root,
                    accessBookmark: grant.transferBookmark, fileBinding: grant.binding)
                guard self.performanceModel.queueState.bind(sessionID: request.session.id),
                      self.installPerformance(request, explicitUserRequest: explicitUserRequest) else {
                    self.stopFailedQueueStart(replacing: previousID)
                    return
                }
                AppLog.control("performance.queue-start entry=\(entry.id) session=\(request.session.id) local=1")
            }
        }
    }

    private func stopFailedQueueStart(replacing previousID: String?) {
        performanceModel.queueState.stop()
        performanceModel.sessionState.agentLost()
        if let previousID { supervisor.stopPerformance(id: previousID) }
        performanceModel.message = "队列已停止：\(performanceModel.message) 列表已保留，可处理后重新开始。"
    }

    private func nextQueuedPerformance() {
        if performanceModel.songNavigation.canForward {
            navigateSongHistory(1)
            return
        }
        pendingSongNavigation = nil
        performanceModel.songNavigation.cancelMove()
        // Advancing the queue supersedes any in-flight local hash from the previous entry.
        localSongs.cancelPendingPlayback()
        let previousID = performanceModel.sessionState.session?.id ?? performanceModel.queueState.activeSessionID
        switch performanceModel.queueState.next(favorites: performanceModel.favoriteQueueTargets, chooseIndex: Self.queueRandomIndex) {
        case .play(let entry): startQueuedPerformance(entry, replacing: previousID, explicitUserRequest: false)
        case .stopped:
            if let previousID { supervisor.stopPerformance(id: previousID) }
            performanceModel.message = "没有下一首，本次队列已停止。"
        case .ignored: break
        }
    }

    private func publishSongHistory() {
        performanceModel.songHistory = songHistory.records
        performanceModel.songHistoryError = songHistory.error
    }

    private func navigateSongHistory(_ offset: Int, mode: PerformancePlaybackMode? = nil,
                                     paused: Bool? = nil) {
        guard let move = performanceModel.songNavigation.requestMove(offset) else { return }
        startSongHistory(move.item.record, navigationIndex: move.index,
                         queueEntry: move.item.queueEntry, mode: mode, paused: paused)
    }

    /// History never edits queue configuration. A running queue keeps its visited set and next
    /// priority while an exact history target temporarily replaces its active snapshot.
    private func startSongHistory(_ record: SongPlaybackRecord, navigationIndex: Int? = nil,
                                  queueEntry: PerformanceQueueEntry? = nil,
                                  mode: PerformancePlaybackMode? = nil, paused: Bool? = nil) {
        localSongs.cancelPendingPlayback()
        let token = UUID()
        pendingSongNavigation = token
        performanceModel.songHistoryPlaybackError = nil
        let playbackMode = mode ?? performanceModel.sessionState.session?.mode ?? record.mode
        let pauseIntent = paused ?? performanceModel.sessionState.session?.paused ?? performanceModel.queueState.paused
        func failed(_ message: String) {
            guard pendingSongNavigation == token else { return }
            pendingSongNavigation = nil
            performanceModel.songNavigation.cancelMove()
            if performanceModel.sessionState.session == nil {
                performanceModel.queueState.stop()
            }
            performanceModel.message = "无法播放历史曲目：\(message) 请重新检查歌曲目录。"
            performanceModel.songHistoryPlaybackError = performanceModel.message
        }
        if let problem = performanceModel.songHistoryUnavailableReason(record) { failed(problem); return }
        let resolvedHistory: (PerformancePlaybackTarget, PerformanceFileBinding?)
        do { resolvedHistory = try performanceModel.historyPlaybackTarget(record) }
        catch { failed("保存的歌曲身份或保留版本不可用。"); return }
        func install(_ target: PerformancePlaybackTarget, root: String, bookmark: Data,
                     binding: PerformanceFileBinding?) {
            guard pendingSongNavigation == token else { return }
            let latestPause = performanceModel.sessionState.session?.paused
                ?? (performanceModel.queueState.isRunning ? performanceModel.queueState.paused : pauseIntent)
            let session = PerformanceSession(target: target, mode: playbackMode, paused: latestPause,
                continuesQueue: performanceModel.queueState.isRunning || performanceModel.songNavigation.canForward)
            let entry = queueEntry ?? performanceModel.queueEntry(for: record)
            let request = PerformanceStartRequest(session: session, mediaRoot: root,
                accessBookmark: bookmark, fileBinding: binding)
            guard installPerformance(request, explicitUserRequest: false,
                                     navigationIndex: navigationIndex, navigationEntry: entry) else {
                failed(performanceModel.message)
                return
            }
            performanceModel.queueState.bindHistory(entry, sessionID: session.id)
        }
        switch resolvedHistory.0 {
        case .catalog(let variant):
            do {
                guard let library = performanceModel.library else { failed("演奏清单不可用。"); return }
                _ = try library.record(for: variant)
                let grant = try performanceDirectories.transfer()
                install(.catalog(variant), root: grant.root, bookmark: grant.bookmark, binding: nil)
            } catch { failed("保存的官方版本或目录不可用。") }
        case .localFile(let reference):
            prepareLocalPerformance(trackID: reference.trackID, fileID: reference.fileID) { [weak self] result in
                guard let self, self.pendingSongNavigation == token else { return }
                switch result {
                case .failure(let error):
                    failed((error as? LocalSongError)?.description ?? String(describing: error))
                case .success(let grant):
                    guard grant.binding == resolvedHistory.1 else {
                        failed("保存的文件版本已改变，未替换为其他文件。")
                        return
                    }
                    install(.localFile(grant.reference), root: grant.root,
                            bookmark: grant.transferBookmark, binding: grant.binding)
                }
            }
        }
    }

    private func setPerformancePaused(_ paused: Bool) {
        guard let session = performanceModel.sessionState.session else { return }
        if performanceModel.queueState.isRunning { performanceModel.queueState.setPaused(paused) }
        performanceModel.sessionState.pause(paused, sessionID: session.id)
        supervisor.pausePerformance(id: session.id, paused: paused)
    }

    private func stopMusicPlayback() {
        pendingSongNavigation = nil
        performanceModel.songNavigation.reset()
        // An immediate stop supersedes any scenario-deferred stop and any in-flight local
        // identity hash whose late result must not start a session.
        performanceScenarioStop.cancel()
        localSongs.cancelPendingPlayback()
        let previousID = performanceModel.sessionState.session?.id ?? performanceModel.queueState.activeSessionID
        performanceModel.queueState.stop()
        if let previousID { supervisor.stopPerformance(id: previousID) }
    }

    /// Explicit local regression seam; inert in ordinary launches. Uses production commands
    /// and an isolated BSIDEMAC_SUPPORT_DIR, not a separate player or simulated event stream.
    private func runPerformanceScenario(path: String) {
        struct Step: Decodable {
            let after: Double
            let action: String
            let value: String?
            /// Optional opt-in for `stop`: `"playing"` stops once the session active at
            /// request time has reported its own accepted `playing` — immediately when that
            /// accepted state already exists, otherwise when a matching report arrives.
            /// Absent = unchanged.
            let waitFor: String?
        }
        guard ProcessInfo.processInfo.environment["BSIDEMAC_SUPPORT_DIR"] != nil,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let steps = try? JSONDecoder().decode([Step].self, from: data) else {
            AppLog.error("performance.scenario rejected: requires isolated support and valid steps")
            return
        }
        for step in steps where step.after >= 0 && step.after <= 600 {
            DispatchQueue.main.asyncAfter(deadline: .now() + step.after) { [weak self] in
                guard let self else { return }
                AppLog.control("performance.scenario action=\(step.action)")
                switch step.action {
                case "bind": if let root = step.value { self.bindPerformanceRoot(root) }
                case "show": self.showPerformanceLibrary()
                case "play": if let id = step.value { self.playPerformance(id: id, presentation: .sidePerformance) }
                case "listen": if let id = step.value { self.playPerformance(id: id, presentation: .sidePerformance, mode: .listen) }
                case "portrait": if let id = step.value { self.playPerformance(id: id, presentation: .portraitPerformance) }
                case "enqueueWatch": if let id = step.value { self.enqueuePerformance(id: id, presentation: .sidePerformance, mode: .watch) }
                case "enqueueListen": if let id = step.value { self.enqueuePerformance(id: id, presentation: .sidePerformance, mode: .listen) }
                case "startQueue": self.startPerformanceQueue(entryID: step.value)
                case "next": self.nextQueuedPerformance()
                case "previous": self.navigateSongHistory(-1)
                case "clearQueue":
                    self.performanceModel.queueState.clear()
                    self.savePerformanceQueue()
                case "pause", "resume":
                    self.setPerformancePaused(step.action == "pause")
                case "stop":
                    let sessionID = self.performanceModel.sessionState.session?.id
                    let deferred = self.performanceScenarioStop.handleStop(
                        waitFor: step.waitFor, sessionID: sessionID,
                        currentReport: self.performanceModel.report,
                        immediateStop: { [weak self] in self?.performanceModel.stop() })
                    if deferred {
                        AppLog.control("performance.scenario stop-deferred waitFor=\(step.waitFor ?? "-") session=\(sessionID ?? "-")")
                    }
                case "reload": self.supervisor.sendReload()
                case "refresh": self.performanceModel.refresh()
                case "globalPause": self.mutate { $0.paused = true }
                case "globalResume": self.mutate { $0.paused = false }
                case "night": self.mutate { $0.timeMode = .fixed(.night) }
                case "day": self.mutate { $0.timeMode = .fixed(.noon) }
                case "auto": self.mutate { $0.timeMode = .auto }
                case "restart": self.restartAgent()
                case "quit": self.quit()
                default: AppLog.error("performance.scenario unknown action")
                }
            }
        }
    }

    // MARK: - Journey-E seam (programmatic production-method lifecycle coverage)

    /// Sequentially open → dismiss each named window/popover through the REAL production
    /// entries, proving "closing a window is not Quit". Labeled explicitly as a programmatic
    /// test seam, NOT human GUI automation; inert unless --exercise-windows is passed.
    private func exerciseWindows(_ names: [String]) {
        var remaining = names
        func next() {
            guard !remaining.isEmpty else {
                AppLog.control("seam.exercise complete windows=\(names.joined(separator: ","))")
                return
            }
            let name = remaining.removeFirst()
            AppLog.control("seam.exercise \(name) open")
            let dismiss: () -> Void
            switch name {
            case "settings":
                showSettings()
                dismiss = { self.settingsWindow?.close() }
            case "help":
                showHelp()
                dismiss = { self.helpWindow?.close() }
            case "about":
                showAbout()
                dismiss = { self.closeAboutPanel() }
            case "diagnostics":
                showDiagnostics()
                dismiss = { self.diagnosticsWindow?.close() }
            case "dailyActivity":
                showDailyActivityRecommendations()
                dismiss = { self.dailyActivityWindow?.close() }
            case "controlCenter":
                // The candidate's production entry is the persistent window; the ordinary app
                // keeps the transient popover. Both are exercised through toggleControlCenter().
                if isDailyCandidate {
                    exerciseCandidateControlCenterWindow()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { next() }
                    return
                }
                guard statusItemController.canShowPopover() else {
                    AppLog.control("seam.exercise controlCenter skipped status-item-unavailable")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { next() }
                    return
                }
                toggleControlCenter()
                let state = statusItemController.presentationState()
                AppLog.control("seam.exercise controlCenter presented shown=\(state.shown) key=\(state.key) fitsScreen=\(state.fitsScreen)")
                dismiss = {
                    self.statusItemController.closePopover()
                    let state = self.statusItemController.presentationState()
                    AppLog.control("seam.exercise controlCenter dismissed shown=\(state.shown)")
                }
            default:
                AppLog.control("seam.exercise \(name) unknown")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { next() }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                dismiss()
                AppLog.control("seam.exercise \(name) close")
                next()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { next() }
    }

    /// Candidate-only regression through the PRODUCTION candidate entry (`toggleControlCenter`,
    /// which is also what the menu icon and ⌘⇧C call): the surface is one retained window, a
    /// repeat open reuses the SAME instance, closing it is not Quit and leaves it recoverable, and
    /// the next open restores that same window. Programmatic test seam, inert in normal launches;
    /// the ordinary variant is explicitly skipped.
    private func exerciseCandidateControlCenterWindow() {
        guard isDailyCandidate else {
            AppLog.control("seam.exercise controlCenter skipped ordinary-variant")
            return
        }
        guard onboardingWindow?.isVisible != true else {
            AppLog.control("seam.exercise controlCenter skipped onboarding-visible")
            return
        }
        toggleControlCenter()
        guard let first = candidateWindow else {
            AppLog.control("seam.exercise controlCenter window-unavailable")
            return
        }
        AppLog.control("seam.exercise controlCenter presented shown=\(first.isVisible) key=\(first.isKeyWindow) fitsScreen=\(controlCenterWindowFitsScreen(first))")
        toggleControlCenter()
        AppLog.control("seam.exercise controlCenter repeat same-instance=\(candidateWindow === first) shown=\(first.isVisible)")
        first.close()
        AppLog.control("seam.exercise controlCenter closed shown=\(first.isVisible)")
        toggleControlCenter()
        AppLog.control("seam.exercise controlCenter reopened same-instance=\(candidateWindow === first) shown=\(first.isVisible)")
        first.close()
        AppLog.control("seam.exercise controlCenter final-close shown=\(first.isVisible)")
    }

    /// Screen containment read by the candidate window regression: a show call alone is not
    /// evidence that the window is reachable on the current display.
    private func controlCenterWindowFitsScreen(_ window: NSWindow?) -> Bool {
        guard let window, let screen = window.screen ?? NSScreen.main else { return false }
        return screen.visibleFrame.contains(window.frame)
    }

    /// Close the standard About panel (owned by NSApp, not by us) through its real window:
    /// the first visible normal-level window that is none of the app's owned windows.
    private func closeAboutPanel() {
        let owned = Set([settingsWindow, helpWindow, diagnosticsWindow, commandWindow, onboardingWindow, performanceWindow, dailyActivityWindow, candidateWindow].compactMap { $0 })
        let panel = NSApp.windows.first { window in
            guard window.isVisible, !owned.contains(window) else { return false }
            return window.level != .statusBar && window.level != .popUpMenu
        }
        if let panel {
            AppLog.control("seam.exercise about window=\"\(panel.title)\" level=\(panel.level.rawValue)")
            panel.close()
        } else {
            AppLog.error("seam.exercise about close-FAILED no-visible-panel")
        }
    }

    // MARK: - Actions

    @objc func showSettings() {
        // Candidate: Settings is a page of the single main window; the view/model pairing and
        // every existing setting are unchanged.
        if isDailyCandidate {
            openCandidateWindow(trigger: "menu-settings", page: .settings)
            return
        }
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 600),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "bsideyou 设置"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(model: controlCenterModel,
                                                                      actions: makeSettingsActions(),
                                                                      backgrounds: dailyBackgroundsModel))
            settingsWindow = window
        }
        // Settings open always RE-QUERIES the real system status (no cached truth).
        login.refresh()
        pushModelUpdate()
        presentInOwnWindow(settingsWindow!)
    }

    private func makeSettingsActions() -> SettingsActions {
        SettingsActions(
            changeResource: { [weak self] in self?.changeResourceFromUI() },
            validateNow: { [weak self] in
                self?.retryDailyResource()
            },
            rerunOnboarding: { [weak self] in self?.resetOnboardingAndShow() },
            restartAgent: { [weak self] in self?.restartAgent() },
            openLogs: {
                NSWorkspace.shared.activateFileViewerSelecting([AppPaths.applicationSupport])
            },
            copyDiagnostics: { [weak self] in self?.copyDiagnostics() },
            showDiagnostics: { [weak self] in self?.showDiagnostics() },
            resetPreferences: { [weak self] in self?.resetPreferences() },
            changeLogin: { [weak self] enabled in
                guard let self else { return }
                let projection = self.login.setEnabled(enabled)
                AppLog.control("loginItem change detail=\(projection.diagnosticLine)")
                // Synchronize every visible surface (toggle subtitle, menu bar, diagnostics)
                // with the outcome — a failed/approval-pending request is never silent.
                self.pushModelUpdate()
            },
            loginState: { [weak self] in self?.login.projection
                ?? LoginItemProjection(system: .unknown) },
            loginDescribe: { [weak self] in self?.login.summary ?? "不可用" },
            catalogSummary: { [weak self] in self?.supervisor.lastSnapshot?.catalogSummary ?? "未加载" },
            historySettings: { [weak self] in
                self?.playbackHistory.settings ?? PlaybackHistorySettings(
                    isEnabled: false, intervalCount: 0, visualDuration: 0,
                    musicDuration: 0, ambientDuration: 0, error: "历史记录不可用")
            },
            setHistoryEnabled: { [weak self] enabled in
                _ = self?.playbackHistory.setEnabled(enabled)
            },
            retryHistory: { [weak self] in
                _ = self?.playbackHistory.commitPending()
            },
            clearHistory: { [weak self] in
                _ = self?.playbackHistory.clear()
            },
            exportHistory: { [weak self] in
                self?.exportPlaybackHistory()
            },
            cropHistory: { [weak self] days in
                guard let self, days > 0 else { return }
                _ = self.playbackHistory.crop(
                    retainingAfter: Date().addingTimeInterval(-Double(days) * 86_400))
            })
    }

    /// Native save panel for the raw versioned history records. The controller never invents a
    /// destination, and the panel's cancel path writes nothing.
    private func exportPlaybackHistory() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "bsideyou-history.json"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = playbackHistory.export(to: url)
    }

    @objc func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let credits = "本地、非官方的个人 macOS 桌面伴侣。\n使用你自己合法持有的 BSide Offline 资源，仅在本机读取。\n与米哈游官方无关。"
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "bsideyou",
            .credits: NSAttributedString(string: credits),
        ])
    }

    @objc func showHelp() {
        if helpWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "bsideyou 使用指南"
            window.isReleasedWhenClosed = false
            let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: 620))
            scrollView.hasVerticalScroller = true
            scrollView.autoresizingMask = [.width, .height]
            let textView = NSTextView(frame: scrollView.bounds)
            textView.isEditable = false
            textView.textContainerInset = NSSize(width: 14, height: 14)
            scrollView.documentView = textView
            window.contentView = scrollView
            if let attributed = try? NSAttributedString(
                markdown: UserGuideText.markdown,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                textView.textStorage?.setAttributedString(attributed)
            } else {
                textView.string = UserGuideText.markdown
            }
            helpWindow = window
        }
        presentInOwnWindow(helpWindow!)
    }

    @objc func showDiagnostics() {
        if diagnosticsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 480),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "bsideyou 诊断"
            window.isReleasedWhenClosed = false
            let scrollView = NSScrollView(frame: window.contentView!.bounds)
            scrollView.hasVerticalScroller = true
            scrollView.autoresizingMask = [.width, .height]
            let textView = NSTextView(frame: scrollView.bounds)
            textView.isEditable = false
            textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            scrollView.documentView = textView
            window.contentView = scrollView
            diagnosticsWindow = window
            diagnosticsText = textView
        }
        refreshDiagnosticsText()
        presentInOwnWindow(diagnosticsWindow!)
    }

    func refreshDiagnosticsText() {
        guard let text = diagnosticsText else { return }
        text.string = DiagnosticsBuilder.build(diagnosticsInput())
    }

    func copyDiagnostics() {
        let text = DiagnosticsBuilder.build(diagnosticsInput())
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// One shared diagnostics input so the window and Copy Diagnostics can never disagree.
    private func diagnosticsInput() -> DiagnosticsBuilder.Input {
        DiagnosticsBuilder.Input(
            prefs: prefs, stage: resourceStage.logName, stageDetail: resourceStageDetail,
            stageAt: resourceStageAt, supervisionState: supervisor.state.rawValue,
            abnormalExits: supervisor.consecutiveAbnormalExits,
            maxFailures: AgentSupervisor.maxConsecutiveFailures,
            lastExitSummary: supervisor.lastExitSummary, launchedAt: supervisor.launchedAt,
            lastSnapshot: supervisor.lastSnapshot,
            login: login.projection,
            preferencesSaveStatus: controlCenterModel.preferencesSaveStatus.rawValue,
            preferencesSaveError: lastPreferencesSaveError,
            dailyDirectoryIdentity: dailyDirectoryIdentityStatus,
            performanceDirectoryIdentity: performanceDirectoryIdentityStatus)
    }

    @objc func showCommandBar() {
        if commandWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 110),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "bsideyou 命令条"
            let field = NSTextField(frame: NSRect(x: 16, y: 66, width: 428, height: 26))
            field.placeholderString = "夜晚 R2 / 音乐 20% / 环境音静音 / 暂停 / 恢复 / 工作模式"
            field.target = self
            field.action = #selector(commandSubmitted)
            window.contentView?.addSubview(field)
            let hint = NSTextField(labelWithString: "回车提交；命令会立即应用到桌面。")
            hint.frame = NSRect(x: 16, y: 30, width: 428, height: 22)
            hint.textColor = .secondaryLabelColor
            hint.font = NSFont.systemFont(ofSize: 11)
            window.contentView?.addSubview(hint)
            commandWindow = window
            commandField = field
            commandHint = hint
        }
        presentInOwnWindow(commandWindow!)
        commandWindow?.makeFirstResponder(commandField)
    }

    @objc private func commandSubmitted() {
        guard let field = commandField, let hint = commandHint else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        var desired = prefs.desired
        if let error = CommandParser.apply(text, to: &desired) {
            hint.stringValue = error
            return
        }
        prefs.desired = desired.sanitized()
        let saved = savePreferences()
        supervisor.sendDesiredState(prefs.desired)
        field.stringValue = ""
        hint.stringValue = saved ? "已应用并保存。" : "已应用，但未保存；请打开设置重试。"
        pushModelUpdate()
    }

    @objc func restartAgent() {
        supervisor.restartAgent()
    }

    @objc func quit() {
        AppLog.control("quit requested")
        NSApp.terminate(nil)
    }

    private func resetPreferences() {
        AppLog.control("preferences.reset")
        localSongs.cancelPendingPlayback()
        invalidateDirectoryPanel()
        dailyDirectoryMonitor.stop()
        dailyDirectoryWatching = false
        dailyDirectoryAccepted = false
        dailyDirectoryRetryRequested = false
        supervisor.stopAgent(intentional: true)
        prefs = AppPreferences()
        dailyCatalogSelectionFailed = false
        dailyDirectoryIdentityStatus = nil
        performanceDirectoryIdentityStatus = nil
        lastAttemptedResourceURL = nil
        lastAttemptedResourceAccess = nil
        performanceDirectories.reset()
        performanceModel.root = nil
        performanceModel.scanning = false
        performanceModel.scanned = false
        performanceModel.scanFailure = nil
        performanceModel.unavailable = [:]
        performanceModel.selectedID = nil
        performanceModel.sessionState.agentLost()
        performanceScenarioStop.cancel()
        performanceModel.favorites = []
        performanceModel.favoriteLocalTrackIDs = []
        performanceModel.onlyFavorites = false
        performanceModel.styleFilter = .all
        performanceModel.queueState = PerformanceQueueState()
        performanceModel.selectedQueueEntryID = nil
        performanceModel.report = nil
        performanceModel.message = "选择你的官方演奏素材文件夹。"
        savePreferences()
        setStage(.unconfigured)
        resetOnboardingAndShow()
    }

    // MARK: - Onboarding

    func runOnboardingResourcePick() {
        presentResourcePicker { [weak self] url in
            guard let self else { return }
            guard let url else {
                self.refreshOnboarding()
                return
            }
            switch self.handleSelectedResourceURL(url) {
            case .accepted(let summary):
                self.onboardingModel.state.recordValidation(path: url.path, summary: summary)
            case .failed(let reason):
                self.onboardingModel.state.recordValidationFailure(reason)
            }
            self.refreshOnboarding()
        }
    }

    func completeOnboarding(loginEnabled: Bool?, initialProfileID: String?) {
        if let enabled = loginEnabled {
            let projection = login.setEnabled(enabled)
            AppLog.control("onboarding.loginItem detail=\(projection.diagnosticLine)")
        }
        if let id = initialProfileID, let profile = Profile.builtIn(id: id) {
            mutate { $0.profile = profile }
        }
        prefs.onboardingCompleted = true
        if savePreferences() {
            AppLog.control("onboarding.completed")
            onboardingWindow?.close()
        }
        uiRefresh()
    }

    func resetOnboardingAndShow() {
        onboardingModel.state = OnboardingState()
        showOnboarding()
    }

    private func refreshOnboarding() {
        showOnboarding()
    }

    func showOnboarding() {
        if onboardingWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 430),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "欢迎使用 bsideyou"
            window.isReleasedWhenClosed = false
            onboardingWindow = window
        }
        onboardingWindow?.contentView = NSHostingView(rootView: OnboardingView(model: onboardingModel,
                                                                            saveModel: controlCenterModel))
        presentInOwnWindow(onboardingWindow!)
    }
}
