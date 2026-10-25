// BSideControlApp — SingleInstanceGuard (Slice 7): duplicate-open protection that runs BEFORE
// NSApplication/AppDelegate construction (from main.swift), so a second activation can never
// even create a second NSStatusItem, AppDelegate, or AgentSupervisor (prompt rule #5). Dev runs
// (no bundle identifier) and non-bundle contexts are skipped. `applicationDidFinishLaunching`
// keeps its own guard call with the same log line as belt-and-braces; both are inert in a
// healthy single instance.
//
// The decision is a pure function over already-collected inputs so the ordinary duplicate case,
// the candidate duplicate case and the candidate-versus-ordinary conflict are regression-tested
// without launching a second process. The effect shell NEVER terminates another application: a
// duplicate activation asks LaunchServices to reopen the running instance (the same native path a
// Finder double-click uses, so the existing instance really receives
// `applicationShouldHandleReopen`), and a candidate meeting the ordinary app only shows a short
// native instruction and exits. No custom IPC, polling or background monitor is involved.

import AppKit
import BSidePlatform

/// Pure startup decision (Slice: normal double-click daily candidate). Nothing here touches
/// processes or UI; the effect shell below maps each outcome to real AppKit calls.
enum StartupDecision: Equatable {
    /// No recognized duplication/conflict: continue into normal startup.
    case proceed
    /// Another instance of THIS identity is already running: resume it and exit.
    case activateSameInstance
    /// The candidate started while the ordinary app is running: explain briefly and exit.
    case conflict
}

struct StartupFacts: Equatable {
    /// Bundle identifier of this process' app (nil for dev/SwiftPM/test executables).
    let bundleIdentifier: String?
    /// Recognized app identity pair for this bundle, nil when unrecognized.
    let identity: AppVariant?
    /// Another running application with exactly this bundle identifier (self excluded).
    let sameIdentityRunning: Bool
    /// Another running application with the ordinary identifier (self excluded).
    let ordinaryRunning: Bool
    let dailyCandidateRunning: Bool

    init(bundleIdentifier: String?, identity: AppVariant?, sameIdentityRunning: Bool,
         ordinaryRunning: Bool, dailyCandidateRunning: Bool = false) {
        self.bundleIdentifier = bundleIdentifier
        self.identity = identity
        self.sameIdentityRunning = sameIdentityRunning
        self.ordinaryRunning = ordinaryRunning
        self.dailyCandidateRunning = dailyCandidateRunning
    }
}

enum StartupDecisionPolicy {
    static func decide(_ facts: StartupFacts) -> StartupDecision {
        // Only a packaged, recognized identity participates: a dev/test binary must never be
        // blocked by, or block, a real app.
        guard facts.identity != nil else { return .proceed }
        if facts.sameIdentityRunning { return .activateSameInstance }
        if facts.identity == .dailyCandidate && facts.ordinaryRunning { return .conflict }
        if facts.identity == .desktopPreview && (facts.ordinaryRunning || facts.dailyCandidateRunning) { return .conflict }
        return .proceed
    }
}

enum SingleInstanceGuard {
    static let bundleID = AppIdentity.normalBundleIdentifier
    /// The conflict instruction is intentionally short and native (no Terminal, no scenario).
    /// The ordinary app already installed on this Mac is still named BSideMac, so the text asks
    /// the user to quit the ordinary version without pretending that app was renamed.
    static let conflictMessage = "bsideyou 无法与正在运行的普通版同时运行。"
    static let conflictDetail = "请先退出正在运行的普通版，再打开 bsideyou。"

    private static func runningBundleIdentifiers() -> Set<String> {
        var identifiers: Set<String> = []
        let running = NSWorkspace.shared.runningApplications
        for app in running where app != NSRunningApplication.current {
            if let identifier = app.bundleIdentifier { identifiers.insert(identifier) }
        }
        return identifiers
    }

    /// Collect the facts the policy needs from the real process table. `Bundle.main` values are
    /// the trusted identity source; no path/argv inference is used.
    static func currentFacts() -> StartupFacts {
        let bundleIdentifier = Bundle.main.bundleIdentifier
        let running = runningBundleIdentifiers()
        return StartupFacts(
            bundleIdentifier: bundleIdentifier,
            identity: bundleIdentifier.flatMap { AppIdentity.variant(forBundleIdentifier: $0) },
            sameIdentityRunning: bundleIdentifier.map { running.contains($0) } ?? false,
            ordinaryRunning: running.contains(AppIdentity.normalBundleIdentifier),
            dailyCandidateRunning: running.contains(AppIdentity.dailyCandidateBundleIdentifier))
    }

    /// Exit immediately (code 0) when this identity must not start. Runs before NSApplication.
    static func exitIfDuplicate() {
        let facts = currentFacts()
        switch StartupDecisionPolicy.decide(facts) {
        case .proceed:
            return
        case .activateSameInstance:
            activateSameInstance(bundleIdentifier: facts.bundleIdentifier)
            AppLog.control("single-instance: another instance is running — exiting")
            exit(0)
        case .conflict:
            presentConflictInstruction(isDesktopPreview: facts.identity == .desktopPreview)
            AppLog.control("single-instance: ordinary app running — candidate exits without starting")
            exit(0)
        }
    }

    /// Resume the already-running instance of THIS identity so a raw duplicate activation shows
    /// its existing UI instead of only focusing a windowless menu-bar app. LaunchServices is
    /// asked to open the app again with `createsNewApplicationInstance = false`: that is the same
    /// native reopen path a Finder double-click uses, so the running instance receives a real
    /// `applicationShouldHandleReopen` event. No custom IPC, polling or background monitor.
    /// Never terminates or modifies the running instance.
    static func activateSameInstance(bundleIdentifier: String?) {
        guard let bundleIdentifier else { return }
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        where app != NSRunningApplication.current {
            requestReopen(of: app)
        }
    }

    /// Request a LaunchServices reopen of `running`. This duplicate process exits right after the
    /// startup gate, so the asynchronous open request is awaited BOUNDED (a single short deadline)
    /// before exit; `activate` is the deterministic fallback only when LaunchServices cannot be
    /// asked at all (no bundle URL or no accepted reply). No repeating timer, no polling.
    private static func requestReopen(of running: NSRunningApplication) {
        guard let bundleURL = running.bundleURL else {
            running.activate(options: [.activateAllWindows])
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = false
        configuration.activates = true
        configuration.addsToRecentItems = false
        let lock = NSLock()
        var accepted = false
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, _ in
            lock.lock(); accepted = true; lock.unlock()
        }
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            lock.lock(); let done = accepted; lock.unlock()
            if done { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        lock.lock(); let delivered = accepted; lock.unlock()
        if !delivered { running.activate(options: [.activateAllWindows]) }
    }

    /// Candidate-versus-ordinary conflict: a brief native alert, then exit. It does not activate
    /// the ordinary app, change its state, or create any candidate persistence/Agent/status item.
    static func presentConflictInstruction(isDesktopPreview: Bool = false) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = isDesktopPreview ? "桌面预览无法与正在运行的 bsideyou 同时运行。" : conflictMessage
        alert.informativeText = isDesktopPreview ? "请先退出日常使用的 bsideyou，再打开 Desktop Preview。原应用与数据不会被替换。" : conflictDetail
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}
