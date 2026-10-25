// BSideControlApp — AgentSupervisor: handshake, full-state replay, bounded backoff restart,
// crash classification, tiered shutdown. Architecture ideas from Mirage (GPL, reference-only)
// and AuraFlow (MIT); implementation original (ADR-002/007/008).
//
// All lifecycle *decisions* live in BSideCore.AgentLifecycle (pure, deterministic, tested).
// This class is only the effect shell: Process / Dispatch / FileHandle / IPC transmission.
// Launch identity is a generation counter; every timer and callback is generation-scoped so a
// stale deadline/ready/termination can never kill or mutate a newer agent.
//
// Exactly-one-process-slot invariant: the reducer keeps `liveGeneration` occupied until the
// process's own termination callback, so this shell's `process` is only ever overwritten after
// the previous process is confirmed dead. Reducer time is monotonic (systemUptime) so a wall-clock
// jump can never break the one-shot handshake deadline. A timeout kill carries an explicit
// failure disposition (`timeoutKillReason`) that the termination callback reports back to the
// reducer as the timeout failure — never as a generic intentional stop or bare signal 9.

import AppKit
import Foundation
import BSideCore
import BSidePlatform

final class AgentSupervisor {
    enum SupervisionState: String {
        case idle, starting, running, degraded
    }

    var onEvent: (AgentEvent) -> Void = { _ in }
    var onSupervisionChanged: () -> Void = { }

    /// Public projection of the pure reducer's phase.
    var state: SupervisionState {
        switch lifecycle.phase {
        case .idle: return .idle
        case .running: return .running
        case .degraded: return .degraded
        case .starting, .stopping, .backoff: return .starting
        }
    }
    /// The precise reducer phase — drives the pure health projection (Core), which distinguishes
    /// starting/stopping/backoff (recovering) from degraded (service problem).
    var lifecyclePhase: AgentLifecycle.Phase { lifecycle.phase }
    var consecutiveAbnormalExits: Int { lifecycle.consecutiveAbnormalExits }
    var lastExitSummary: String? { lifecycle.lastFailureReason }
    private(set) var launchedAt: Date?
    /// The CURRENT generation's accepted runtime snapshot. Belongs to one generation and to the
    /// RUNNING phase only: it is cleared on every transition out of .running and on termination,
    /// so a stale process's snapshot can never project normal/green again.
    private(set) var lastSnapshot: RuntimeSnapshot?

    static let maxConsecutiveFailures = AgentLifecycle.maxConsecutiveFailures

    /// Pure decision engine (production-used; tested deterministically in BSideTestRunner).
    private var lifecycle = AgentLifecycle()
    /// ControlApp's current root access outlives all restart attempts. Each new child receives
    /// a newly created temporary bookmark, never the persisted app-scoped bookmark.
    private var dailyAccess: DirectoryAccessLease?
    private var desktopWorkspace = DesktopWorkspacePresentation()
    private var queuedDailyRefresh: DirectoryAccessLease?
    private var queuedDailyFailure: DailyAssetIssue?
    private var pendingDailyRefreshID: String?

    private var process: Process?
    private var currentGeneration: Int?
    private var stdinHandle: FileHandle?
    /// Pure newline-frame reader for agent stdout (ADR-007). Bounded: an oversized frame is
    /// dropped whole (logged) and framing resynchronizes at the next newline, so a hostile
    /// agent can never grow this buffer unboundedly (see BSideCore.NewlineFrameReader).
    private var framer = NewlineFrameReader()
    /// True while the live process is expected to terminate (graceful stop or restart shutdown),
    /// so its exit is not misclassified as an abnormal crash.
    private var expectedTermination = false
    /// Set when the live process was force-killed for a handshake timeout. The eventual
    /// termination must be reported to the reducer as the timeout failure (abnormal), with this
    /// reason — never as a normal intentional stop and never as a generic signal 9.
    private var timeoutKillReason: String?

    private var handshakeTimer: DispatchWorkItem?
    private var backoffTimer: DispatchWorkItem?

    /// agent.log rotation (5 MiB + one .1 backup), write-triggered only — independent of
    /// control.log (each logical log owns its own RotatingFileLog instance). Resolved lazily so
    /// the support root (override or candidate default) is fixed before any IO.
    private lazy var agentLog = RotatingFileLog(url: AppPaths.agentLogURL)

    /// Environment for the child Agent. The ControlApp's own resolved support root is passed
    /// EXPLICITLY, so an Agent that somehow started without this parent (or a future direct
    /// launch) can never silently fall back to the ordinary app's folder while a candidate is
    /// running. Every other inherited variable is retained unchanged.
    static func makeAgentEnvironment(inherited: [String: String],
                                     resolvedSupportPath: String) -> [String: String] {
        var environment = inherited
        environment[AppPaths.supportDirOverrideKey] = resolvedSupportPath
        return environment
    }

    /// Agent binary location: env override (dev), else sibling of our executable
    /// (packaged bundle) / SwiftPM build dir sibling (dev run).
    var agentBinaryURL: URL? {
        if let override = ProcessInfo.processInfo.environment["BSIDEMAC_AGENT_PATH"] {
            return URL(fileURLWithPath: override)
        }
        let sibling = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("BSideWallpaperAgent")
        if let sibling, FileManager.default.fileExists(atPath: sibling.path) { return sibling }
        return nil
    }

    func setDesktopWorkspace(_ presentation: DesktopWorkspacePresentation) {
        guard presentation != desktopWorkspace else { return }
        desktopWorkspace = presentation
        if state == .running { send(.setDesktopWorkspace(presentation)) }
    }

    // MARK: - Control surface

    func start(assetPath: String, desired: DesiredState, access: DirectoryAccessLease? = nil) {
        AppLog.control("supervisor.start intent=start asset=\(assetPath)")
        dailyAccess = access
        queuedDailyRefresh = nil
        queuedDailyFailure = nil
        pendingDailyRefreshID = nil
        apply(.start(assetPath: assetPath, desired: desired.sanitized()))
    }

    /// Update restart ownership without ending a live performance or replacing daily video.
    func refreshAssets(access: DirectoryAccessLease, desired: DesiredState) {
        dailyAccess = access
        lifecycle.recordAssetPath(access.url.path)
        lifecycle.recordDesired(desired.sanitized())
        queuedDailyRefresh = access
        queuedDailyFailure = nil
        // Failed service recovery remains an explicit action. A directory event only updates
        // the existing restart intent; it must not undo the supervisor's degraded boundary.
        if state == .running { sendQueuedDailyRefresh() }
    }

    /// The accepted root failed authorization before an Agent scan could begin. Invalidate
    /// discovery without giving the Agent an old path or a fabricated transfer bookmark.
    func invalidateDailyAssets(_ issue: DailyAssetIssue) {
        dailyAccess = nil // crash recovery must not mint another grant from a rejected path
        queuedDailyRefresh = nil
        queuedDailyFailure = issue
        if state == .running { sendQueuedDailyRefresh() }
    }

    private func sendQueuedDailyRefresh() {
        guard state == .running else { return }
        if let issue = queuedDailyFailure {
            queuedDailyFailure = nil
            let id = UUID().uuidString
            pendingDailyRefreshID = id
            lastSnapshot = nil
            send(.invalidateDailyAssets(DailyAssetInvalidation(issue: issue, refreshID: id)))
            onSupervisionChanged()
            return
        }
        guard let access = queuedDailyRefresh else { return }
        queuedDailyRefresh = nil
        do {
            let id = UUID().uuidString
            let request = DirectoryAccessRequest(path: access.url.path,
                bookmark: try access.makeTransferBookmark(), refreshID: id)
            pendingDailyRefreshID = id
            lastSnapshot = nil
            send(.refreshAssets(request))
            onSupervisionChanged()
        } catch {
            invalidateDailyAssets(.authorizationRequired)
            onEvent(.error(code: "assetAuthorization", message: "directory access grant unavailable"))
        }
    }

    /// Keep restart intent current without defeating the UI's IPC coalescing.
    func recordDesiredState(_ desired: DesiredState) {
        lifecycle.recordDesired(desired.sanitized())
    }

    func sendDesiredState(_ desired: DesiredState) {
        recordDesiredState(desired)
        send(.setDesiredState(desired.sanitized()))
    }

    @discardableResult func startPerformance(_ session: PerformanceSession, mediaRoot: String,
                                             accessBookmark: Data? = nil,
                                             fileBinding: PerformanceFileBinding? = nil,
                                             automaticallyEnterFullScreen: Bool = true) -> Bool {
        guard state == .running else { return false }
        send(.startPerformance(PerformanceStartRequest(session: session, mediaRoot: mediaRoot,
                                                       accessBookmark: accessBookmark,
                                                       fileBinding: fileBinding,
                                                       automaticallyEnterFullScreen: automaticallyEnterFullScreen)))
        return true
    }
    func pausePerformance(id: String, paused: Bool) {
        send(.pausePerformance(PerformancePauseRequest(sessionID: id, paused: paused)))
    }
    func stopPerformance(id: String) { send(.stopPerformance(sessionID: id)) }

    /// One-shot presentation request for the CURRENT watch session (the menu-bar 进入全屏 item).
    /// Only a RUNNING generation may receive it and it is never replayed to a later process; it
    /// never starts a song, changes the queue or toggles pause. Returns false when no running Agent
    /// can accept the request.
    @discardableResult
    func enterPerformanceFullScreen(sessionID: String) -> Bool {
        guard state == .running else { return false }
        send(.enterPerformanceFullScreen(sessionID: sessionID))
        return true
    }

    @discardableResult
    func exitPerformanceFullScreen(sessionID: String) -> Bool {
        guard state == .running else { return false }
        send(.exitPerformanceFullScreen(sessionID: sessionID))
        return true
    }

    func setHomeCompanionStream(_ request: HomeCompanionStreamRequest) {
        guard state == .running else { return }
        send(.setHomeCompanionStream(request))
    }

    func acknowledgeHomeCompanionFrame(_ acknowledgement: HomeCompanionFrameAcknowledgement) {
        guard state == .running else { return }
        send(.acknowledgeHomeCompanionFrame(acknowledgement))
    }

    func sendReload() { send(.reloadAssets) }
    func requestHealth() { send(.healthCheck) }

    /// One explicit daily activity entry. Only the RUNNING current generation may receive it, and
    /// it is never replayed to a later process (the desired state it carries is persisted
    /// separately). Returns false when no running Agent can accept the request.
    @discardableResult
    func startDailyActivity(_ request: DailyActivityRequest) -> Bool {
        guard state == .running else { return false }
        send(.startDailyActivity(request))
        return true
    }

    /// Opt-in recording token. Only a RUNNING current generation may receive it; a lost Agent
    /// stops history authority because the token is never replayed to a later process.
    @discardableResult
    func setHistoryRecording(_ request: HistoryRecordingRequest) -> Bool {
        guard state == .running else { return false }
        send(.setHistoryRecording(request))
        return true
    }

    func restartAgent() {
        guard let pending = lifecycle.pending else {
            AppLog.control("supervisor.restart ignored (no current asset/desired intent)")
            return
        }
        AppLog.control("supervisor.restart intent=restart")
        apply(.start(assetPath: pending.assetPath, desired: pending.desired))
    }

    /// Intentional stop: app quit and reset-preferences both route here. Cancels any pending
    /// replacement, backoff, or handshake action (a later explicit start is required to relaunch).
    func stopAgent(intentional: Bool) {
        AppLog.control("supervisor.stop intentional=\(intentional)")
        apply(.stop)
        dailyAccess = nil
        queuedDailyRefresh = nil
        queuedDailyFailure = nil
        pendingDailyRefreshID = nil
    }

    // MARK: - Reducer shell

    private func apply(_ event: AgentLifecycle.Event) {
        // Monotonic clock for reducer time/deadline math (ADR-002 deadline semantics); a
        // wall-clock adjustment must never make the one-shot timeout callback miss its deadline.
        let now = ProcessInfo.processInfo.systemUptime
        let before = lifecycle.phase
        let effects = lifecycle.reduce(event, now: now)
        // Minimal observability (Slice 3 regression): every phase transition with the launch
        // generation identity it belongs to, so tests/logs can prove process identity and
        // health transitions without guessing. No behavior change — pure logging.
        if lifecycle.phase != before {
            let gen = lifecycle.liveGeneration.map { "\($0)" } ?? "-"
            AppLog.control("agent.phase \(lifecycle.phase.rawValue) gen=\(gen)")
        }

        // Reconcile timers with the reducer's authoritative state. A stale event that the
        // reducer ignores leaves its state unchanged, so live timers survive untouched.
        if lifecycle.phase != .starting {
            handshakeTimer?.cancel(); handshakeTimer = nil
        }
        if lifecycle.phase != .backoff {
            backoffTimer?.cancel(); backoffTimer = nil
        }

        // Snapshot ownership (runtime rule): a snapshot belongs to the generation that produced
        // it, and to the RUNNING phase only. Any transition out of running — start/stop intent,
        // timeout, termination, backoff, DEGRADED, idle — means the old process's snapshot is
        // stale evidence and must never project normal/green again.
        if lifecycle.phase != .running {
            lastSnapshot = nil
            pendingDailyRefreshID = nil
        }

        for effect in effects { execute(effect, now: now) }
        onSupervisionChanged()
    }

    private func execute(_ effect: AgentLifecycle.Effect, now: TimeInterval) {
        switch effect {
        case .spawn(let generation, let assetPath, let desired, let handshakeDeadline):
            spawn(generation: generation, assetPath: assetPath, desired: desired,
                  handshakeDeadline: handshakeDeadline, now: now)
        case .shutdown:
            shutdownLiveProcess()
        case .kill(let reason):
            forceKillLiveProcess(reason: reason)
        case .scheduleBackoff(let token, let after):
            scheduleBackoff(token: token, after: after)
        case .degraded(let reason):
            // Slice 3 observability: an explicit marker when the supervisor enters DEGRADED
            // (5 consecutive failures or a failed spawn) so regressions can assert the
            // bounded-failure state without parsing UI wording.
            AppLog.control("agent.degraded reason=\(reason)")
            onEvent(.degraded(reason: reason))
        }
    }

    // MARK: - Process management

    private func spawn(
        generation: Int, assetPath: String, desired: DesiredState,
        handshakeDeadline: TimeInterval, now: TimeInterval
    ) {
        let initialization: AgentCommand
        do {
            guard let dailyAccess, dailyAccess.url.path == assetPath else {
                throw CocoaError(.fileReadNoPermission)
            }
            initialization = .initialize(DirectoryAccessRequest(path: assetPath,
                bookmark: try dailyAccess.makeTransferBookmark()))
            guard let line = IPCCoding.encodeLine(IPCEnvelope(payload: initialization)),
                  line.utf8.count <= NewlineFrameReader.maxFrameSize else {
                throw CocoaError(.fileReadTooLarge)
            }
        } catch {
            // An unusable grant needs resource recovery, not repeated process launches.
            AppLog.error("supervisor: directory grant failed: \(error)")
            // The reducer has reserved this generation, but no Process exists yet to send a
            // termination event. Release that reservation before cancelling retry intent.
            apply(.spawnFailed(generation: generation, reason: "directory access grant unavailable"))
            apply(.stop)
            onEvent(.error(code: "assetAuthorization", message: "directory access grant unavailable"))
            return
        }
        guard let binaryURL = agentBinaryURL else {
            AppLog.error("supervisor: agent binary missing — bundle=\(Bundle.main.bundlePath)")
            apply(.spawnFailed(
                generation: generation,
                reason: "agent binary not found (set BSIDEMAC_AGENT_PATH for dev runs)"))
            return
        }

        let process = Process()
        process.executableURL = binaryURL
        // Explicit, not inherited-by-accident: the child resolves the SAME support root as this
        // ControlApp (candidate default or the test/verification override), so a standalone
        // helper default can never leak into agent.log or any other agent-side path.
        process.environment = Self.makeAgentEnvironment(
            inherited: ProcessInfo.processInfo.environment,
            resolvedSupportPath: AppPaths.applicationSupport.path)
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderrSink()

        process.terminationHandler = { [weak self] terminated in
            DispatchQueue.main.async { self?.handleTermination(terminated, generation: generation) }
        }
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil      // stdout EOF: drain any partial tail
                CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) { self?.handleEOF(generation: generation) }
                CFRunLoopWakeUp(CFRunLoopGetMain())
                return
            }
            CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) { self?.ingest(data, generation: generation) }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }

        do {
            try process.run()
        } catch {
            AppLog.error("supervisor: process.run failed: \(error)")
            apply(.spawnFailed(generation: generation, reason: "launch failed: \(error.localizedDescription)"))
            return
        }

        self.process = process
        self.currentGeneration = generation
        self.stdinHandle = stdin.fileHandleForWriting
        self.expectedTermination = false
        self.timeoutKillReason = nil
        launchedAt = Date()
        framer = NewlineFrameReader()   // framer state belongs to the current generation
        // Chain-of-custody (Slice 7): the supervisor logs the parent (this ControlApp's own
        // PID) next to the child agent PID, so acceptance fixtures can verify the
        // exactly-one-owned-Agent relationship from the log even where process-table
        // enumeration (ps) is unavailable to the probe.
        AppLog.control("agent.launch gen=\(generation) pid=\(process.processIdentifier) parent=\(ProcessInfo.processInfo.processIdentifier) binary=\(binaryURL.path)")

        // Handshake deadline for THIS generation only (ADR-007: bounded 10 s).
        scheduleHandshake(generation: generation, deadline: handshakeDeadline, now: now)

        // Full-state replay (ADR-007): complete DesiredState before initialize, preserving pause.
        send(.setDesiredState(desired.sanitized()))
        send(initialization)
        // Slice 3 observability: the exact single-line JSON replayed to THIS generation, so
        // the regression can prove full-state replay equals the persisted preferences.
        AppLog.control("agent.replay gen=\(generation) desired=\(Self.desiredLog(desired))")
    }

    /// Single-line JSON projection of the replayed DesiredState (identical encoding to the
    /// persisted preferences — both use JSONEncoder on the same Codable type).
    private static func desiredLog(_ desired: DesiredState) -> String {
        guard let data = try? JSONEncoder().encode(desired.sanitized()),
              let line = String(data: data, encoding: .utf8), !line.contains("\n") else {
            return "unencodable"
        }
        return line
    }

    /// Agent stderr is drained by us (rather than handed to the process as a raw fd) so
    /// every write to agent.log is a rotation checkpoint — the same bounded 5 MiB + one
    /// `.1` backup rule as control.log, enforced by RotatingFileLog on append. Rotation
    /// stays write-triggered: no timers, no polling. If agent.log cannot be written the
    /// append fails soft and the agent's stderr is still drained (never blocks the child).
    private func stderrSink() -> Pipe {
        let pipe = Pipe()
        let reader = pipe.fileHandleForReading
        reader.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil   // agent stderr EOF
                return
            }
            self?.agentLog.append(data)
        }
        return pipe
    }

    private func scheduleHandshake(generation: Int, deadline: TimeInterval, now: TimeInterval) {
        handshakeTimer?.cancel()
        let delay = max(0, deadline - now)
        let item = DispatchWorkItem { [weak self] in
            self?.apply(.handshakeTimeout(generation: generation))
        }
        handshakeTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func scheduleBackoff(token: Int, after delay: TimeInterval) {
        backoffTimer?.cancel()
        AppLog.control("agent.backoff scheduled token=\(token) after=\(delay)s")
        // Stale/cancelled timers are harmless: the reducer only accepts `.backoffElapsed`
        // when `token` matches the currently armed backoff, so a late fire is a no-op.
        let item = DispatchWorkItem { [weak self] in
            self?.apply(.backoffElapsed(token: token))
        }
        backoffTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func shutdownLiveProcess() {
        guard let process else { return }
        expectedTermination = true
        AppLog.control("agent.shutdown requested pid=\(process.processIdentifier)")
        send(.shutdown)
        try? stdinHandle?.close()
        stdinHandle = nil
        // Tiered escalation (single set of constants): graceful → SIGTERM (1.5 s) → SIGKILL (+1.5 s).
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    private func forceKillLiveProcess(reason: String) {
        guard let process else { return }
        // Timeout kill, NOT an intentional restart: record the failure disposition so the
        // termination callback classifies this as the timeout failure rather than a normal stop.
        timeoutKillReason = reason
        AppLog.control("agent.kill never-ready pid=\(process.processIdentifier)")
        kill(process.processIdentifier, SIGKILL)
    }

    private func ingest(_ data: Data, generation: Int) {
        guard generation == currentGeneration else { return }   // stale stdout from an old agent
        let beforeOversize = framer.oversizeDropped
        let frames = framer.feed(data)
        reportOversizedDrops(before: beforeOversize)
        processFrames(frames, generation: generation)
    }

    /// stdout EOF (agent exited or closed its stdout). Drain any final unterminated frame so a
    /// valid line flushed without its trailing newline is still processed; the termination
    /// callback owns the lifecycle transition from here.
    private func handleEOF(generation: Int) {
        guard generation == currentGeneration else { return }
        let beforeOversize = framer.oversizeDropped
        let final = framer.finish()
        reportOversizedDrops(before: beforeOversize)
        if let final, !final.isEmpty {
            processFrames([final], generation: generation)
        }
    }

    private func reportOversizedDrops(before: Int) {
        if framer.oversizeDropped > before {
            AppLog.error("supervisor: dropped oversized agent frame " +
                         "(\(framer.oversizeDropped) frames, \(framer.bytesDropped) bytes dropped total)")
        }
    }

    private func processFrames(_ frames: [Data], generation: Int) {
        for frame in frames {
            guard !frame.isEmpty, let line = String(data: frame, encoding: .utf8) else { continue }
            guard let envelope = IPCCoding.decodeLine(line, as: AgentEvent.self) else {
                AppLog.error("supervisor: dropped malformed agent line")
                continue
            }
            forwardCurrentEvidence(envelope.payload, generation: generation)
        }
    }

    /// Runtime-event gate (runtime rules): only CURRENT-generation evidence may reach the app
    /// state machine. A ready/snapshot/failure from a generation the reducer no longer considers
    /// live — or, for runtime evidence, no longer RUNNING — belongs to a dead or doomed process:
    /// it must never promote resourceStage to ready, never overwrite the visible snapshot, and
    /// never be forwarded as a healthy event. The lifecycle reducer remains the authoritative
    /// acceptance check; these guards only decide what the shell lets through.
    private func forwardCurrentEvidence(_ payload: AgentEvent, generation: Int) {
        switch payload {
        case .ready:
            guard lifecycle.acceptsReady(generation: generation) else {
                AppLog.error("supervisor: dropped late ready from gen \(generation)")
                return
            }
            AppLog.control("agent.handshake ready gen=\(generation)")
            apply(.ready(generation: generation))
            sendQueuedDailyRefresh()
            send(.setDesktopWorkspace(desktopWorkspace))
            onEvent(payload)                        // only a genuinely accepted ready is healthy
        case .runtimeSnapshot(let snapshot):
            guard lifecycle.acceptsRuntimeEvents(generation: generation) else {
                AppLog.error("supervisor: dropped runtime snapshot from non-running gen \(generation)")
                return
            }
            if let pendingDailyRefreshID {
                guard snapshot.dailyRefreshID == pendingDailyRefreshID else { return }
                self.pendingDailyRefreshID = nil
            }
            lastSnapshot = snapshot                 // current-generation, running-owned evidence
            onEvent(payload)
        case .error, .degraded:
            // Only starting/running failures are user-visible. A stopping or timed-out process is
            // already doomed; its late report must not replace the truthful recovery state.
            guard lifecycle.acceptsFailureReports(generation: generation) else {
                AppLog.error("supervisor: dropped non-authoritative failure from gen \(generation)")
                return
            }
            onEvent(payload)
        case .desktopWorkspaceAction, .performance, .performancePresentation, .homeCompanionFrame, .dailyActivity, .historyIntervals, .playbackStarted, .playbackPaused, .contentChanged, .health:
            guard lifecycle.acceptsRuntimeEvents(generation: generation) else { return }
            onEvent(payload)
        }
    }

    private func handleTermination(_ terminated: Process, generation: Int) {
        guard let current = process, current === terminated else { return }   // stale/duplicate
        process = nil
        currentGeneration = nil
        stdinHandle = nil

        // Classification priority: a recorded timeout kill wins (it is a failure with an exact
        // reason, never a generic signal 9); otherwise an expected graceful stop is normal;
        // anything else is an abnormal crash/exit.
        let abnormal: Bool
        let reason: String
        if let timeoutReason = timeoutKillReason {
            abnormal = true
            reason = timeoutReason
            AppLog.error("supervisor: agent \(reason)")
        } else if expectedTermination {
            abnormal = false
            reason = "stopped with status \(terminated.terminationStatus)"
        } else {
            abnormal = true
            let signal = terminated.terminationStatus & 0x7F
            reason = terminated.terminationReason == .uncaughtSignal
                ? "crashed with signal \(signal)"
                : "exited with status \(terminated.terminationStatus)"
            AppLog.error("supervisor: agent \(reason)")
        }
        timeoutKillReason = nil
        expectedTermination = false
        AppLog.control("agent.terminated gen=\(generation) pid=\(terminated.processIdentifier) status=\(terminated.terminationStatus) abnormal=\(abnormal)")
        apply(.terminated(generation: generation, abnormal: abnormal, reason: reason))
    }

    private func send(_ command: AgentCommand) {
        guard let stdinHandle else { return }
        guard let line = IPCCoding.encodeLine(IPCEnvelope(payload: command)) else { return }
        stdinHandle.write(Data((line + "\n").utf8))
    }
}
