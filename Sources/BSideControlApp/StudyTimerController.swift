import AppKit
import Combine
import BSideCore
import BSidePlatform

/// Read-only rendering contract, independent of notch geometry, artwork and lighting.
struct StudyTimerPresentation: Equatable {
    let mode: StudyTimerMode
    let elapsed: Double
    let remaining: Double
    let isRunning: Bool
    let hasSession: Bool
    let isComplete: Bool
    let title: String
    let sessionID: String?
    let targetSeconds: Double
    let needsAttention: Bool

    var timeText: String {
        let seconds = Int(min(Double(Int.max / 2), max(0, mode == .countdown ? ceil(remaining) : floor(elapsed))))
        return seconds >= 3600
            ? String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
    var status: String { needsAttention ? "记录待处理" : isComplete ? "本次已完成" : hasSession ? (isRunning ? "专注中" : "已暂停") : "准备开始" }
}

struct StudyTimerActions {
    var selectMode: (StudyTimerMode) -> Void = { _ in }
    var toggle: () -> Void = { }
    var finish: () -> Void = { }
    var openHistory: () -> Void = { }
}

/// One owner for study state and its atomic local file. Playback and rendering have no timer authority.
final class StudyTimerController: ObservableObject {
    @Published private(set) var ledger = StudyTimerLedger()
    @Published private(set) var isRunning = false
    @Published private(set) var isComplete = false
    @Published private(set) var error: String?
    private(set) var loadFailed = false
    private let fileURL: URL
    private let now: () -> Date
    private let uptime: () -> Double
    private var anchor: Double?
    private var deadline: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var lockObserver: NSObjectProtocol?

    init(fileURL: URL = AppPaths.applicationSupport.appendingPathComponent("study.json"),
         now: @escaping () -> Date = Date.init,
         uptime: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.fileURL = fileURL
        self.now = now
        self.uptime = uptime
        load()
    }

    func observeSystem() {
        guard workspaceObservers.isEmpty else { return }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main) { [weak self] _ in self?.pause() })
        }
        // Existing platform lock signal, used only as an event, never as a command mailbox.
        lockObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) {
                [weak self] _ in self?.pause()
            }
    }

    var presentation: StudyTimerPresentation {
        let session = ledger.active
        let elapsed = session?.measured(adding: anchor.map { max(0, uptime() - $0) } ?? 0) ?? (isComplete ? Double(ledger.countdownMinutes * 60) : 0)
        let target = session?.targetSeconds ?? Double(ledger.countdownMinutes * 60)
        return StudyTimerPresentation(mode: session?.mode ?? ledger.mode, elapsed: elapsed,
            remaining: max(0, target - elapsed), isRunning: isRunning, hasSession: session != nil,
            isComplete: isComplete, title: session?.title ?? ledger.title,
            sessionID: session?.id ?? (isComplete ? ledger.records.last?.id : nil),
            targetSeconds: target, needsAttention: error != nil)
    }

    func selectMode(_ mode: StudyTimerMode) {
        guard ledger.active == nil, !loadFailed else { return }
        ledger.mode = mode
        isComplete = false
        _ = save()
    }

    func configure(title: String? = nil, minutes: Int? = nil) {
        guard ledger.active == nil, !loadFailed else { return }
        isComplete = false
        if let title { ledger.title = title }
        if let minutes { ledger.countdownMinutes = min(240, max(1, minutes)) }
        _ = save()
    }

    func toggle() { isRunning ? pause() : start() }

    func start() {
        guard !loadFailed, !isRunning else { return }
        if ledger.active == nil {
            ledger.active = StudySession(startedAt: now(), title: ledger.title.trimmingCharacters(in: .whitespacesAndNewlines),
                mode: ledger.mode, targetSeconds: Double(ledger.countdownMinutes * 60))
        }
        isComplete = false
        isRunning = true
        anchor = uptime()
        _ = save()
        schedule()
    }

    func pause() {
        guard isRunning else { return }
        checkpoint()
        isRunning = false
        anchor = nil
        deadline?.invalidate()
        deadline = nil
        if ledger.active?.reachedTarget == true { finish() }
        else { _ = save() }
    }

    func finish() {
        guard ledger.active != nil else { return }
        checkpoint()
        isRunning = false
        anchor = nil
        deadline?.invalidate()
        deadline = nil
        if let session = ledger.active {
            isComplete = session.reachedTarget
            if session.elapsed > 0 { ledger.records.append(StudyRecord(session: session, endedAt: now())) }
        }
        ledger.active = nil
        _ = save()
    }

    private func checkpoint() {
        guard let anchor else { return }
        ledger.active?.accumulate(max(0, uptime() - anchor))
        self.anchor = uptime()
    }

    /// One deadline: completion or a 60-second persistence checkpoint, only while running.
    /// Display seconds come from visible TimelineViews; no background one-second ticker.
    private func schedule() {
        deadline?.invalidate()
        let interval = presentation.mode == .countdown ? min(60, presentation.remaining) : 60
        deadline = Timer(timeInterval: max(0.01, interval), repeats: false) { [weak self] _ in
            self?.checkpointDue()
        }
        if let deadline { RunLoop.main.add(deadline, forMode: .common) }
    }

    func checkpointDue() {
        guard isRunning else { return }
        checkpoint()
        if ledger.active?.reachedTarget == true { finish() }
        else { _ = save(); schedule() }
    }

    func retry() {
        if loadFailed { load() } else { _ = save() }
    }

    private func load() {
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let decoded = try JSONDecoder().decode(StudyTimerLedger.self, from: Data(contentsOf: fileURL))
                guard decoded.isValid else { throw CocoaError(.coderReadCorrupt) }
                ledger = decoded
            }
            loadFailed = false
            error = nil
        } catch {
            loadFailed = true
            self.error = "自习记录无法读取，原文件已保留。"
        }
    }

    @discardableResult func save() -> Bool {
        guard !loadFailed else { return false }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(ledger).write(to: fileURL, options: .atomic)
            error = nil
            return true
        } catch {
            self.error = "自习记录尚未保存，请重试。"
            return false
        }
    }

    @discardableResult func prepareToQuit() -> Bool {
        pause()
        return loadFailed || save()
    }

    func shutdown() {
        deadline?.invalidate()
        deadline = nil
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        workspaceObservers.removeAll()
        if let lockObserver { DistributedNotificationCenter.default().removeObserver(lockObserver) }
        lockObserver = nil
    }

    deinit { shutdown() }
}
