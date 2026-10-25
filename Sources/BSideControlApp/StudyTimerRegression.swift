import AppKit
import BSideCore

func runStudyTimerRegression(expect: (Bool, String) -> Void) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("bsidemac-study-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("study.json")
    var clock = 100.0
    var date = Date(timeIntervalSince1970: 1000)
    let controller = StudyTimerController(fileURL: file, now: { date }, uptime: { clock })
    expect(controller.ledger.records.isEmpty && !controller.isRunning, "a new study store is idle")
    controller.configure(title: "Reading")
    controller.start()
    clock += 12
    date = Date(timeIntervalSince1970: 500)
    expect(controller.presentation.elapsed == 12, "wall-clock rollback does not change study duration")
    controller.pause()
    clock += 100
    expect(controller.presentation.elapsed == 12, "paused time is excluded")
    let restored = StudyTimerController(fileURL: file, now: { date }, uptime: { clock })
    expect(!restored.isRunning && restored.presentation.elapsed == 12, "relaunch restores a paused checkpoint without offline time")
    controller.start()
    clock += 8
    controller.finish()
    controller.finish()
    expect(controller.ledger.records.count == 1 && controller.ledger.records[0].session.elapsed == 20,
           "finishing saves one measured record; duplicate finish is inert")
    expect(controller.ledger.records[0].session.title == "Reading", "record retains the session name")
    let history = StudyTimerController(fileURL: file)
    expect(history.ledger.records == controller.ledger.records, "history survives disk reload")

    controller.selectMode(.countdown)
    controller.configure(minutes: 1)
    controller.start()
    clock += 80
    controller.checkpointDue()
    expect(controller.isComplete && !controller.isRunning && controller.ledger.active == nil,
           "countdown completion stops and closes the session")
    expect(controller.ledger.records.last?.session.elapsed == 60 && controller.presentation.timeText == "00:00",
           "late countdown callback records only the target and displays zero")
    controller.checkpointDue()
    expect(controller.ledger.records.count == 2, "a stale deadline cannot create another record")

    controller.configure(minutes: 2)
    expect(!controller.isComplete && controller.presentation.timeText == "02:00",
           "changing the next countdown resets the completed display")
    controller.selectMode(.countUp)
    controller.observeSystem()
    controller.start()
    clock += 5
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
    expect(!controller.isRunning && controller.presentation.elapsed == 5, "workspace sleep pauses the study owner")
    expect(controller.prepareToQuit(), "normal quit saves the paused checkpoint")
    controller.shutdown()

    do {
        let corrupt = root.appendingPathComponent("corrupt.json")
        let original = Data("invalid study history".utf8)
        try original.write(to: corrupt)
        let broken = StudyTimerController(fileURL: corrupt)
        broken.start()
        expect(broken.loadFailed && broken.error != nil && !broken.isRunning, "corrupt storage blocks timing with an explicit error")
        expect((try Data(contentsOf: corrupt)) == original, "corrupt storage is never overwritten")
        expect(broken.prepareToQuit(), "read failure alone does not trap the user at quit")
        try JSONEncoder().encode(StudyTimerLedger()).write(to: corrupt, options: .atomic)
        broken.retry()
        expect(!broken.loadFailed, "explicit retry can reload repaired storage")

        let blockedParent = root.appendingPathComponent("blocked")
        try Data().write(to: blockedParent)
        let blocked = StudyTimerController(fileURL: blockedParent.appendingPathComponent("study.json"),
                                           now: { date }, uptime: { clock })
        blocked.start()
        clock += 10
        blocked.finish()
        expect(blocked.error != nil && blocked.ledger.records.count == 1,
               "write failure preserves the unsaved record in memory and shows an error")
        expect(!blocked.prepareToQuit(), "unsaved records require an explicit quit decision")
        try FileManager.default.removeItem(at: blockedParent)
        blocked.retry()
        let recovered = StudyTimerController(fileURL: blockedParent.appendingPathComponent("study.json"))
        expect(blocked.error == nil && recovered.ledger.records.count == 1, "retry persists the original pending record")
    } catch { expect(false, "study filesystem regression failed: \(error)") }
}
