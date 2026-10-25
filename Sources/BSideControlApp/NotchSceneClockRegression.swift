import Foundation

func runNotchSceneClockRegression(expect: (Bool, String) -> Void) {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    func date(_ day: Int, _ hour: Int, _ minute: Int = 0, month: Int = 10) -> Date {
        cal.date(from: DateComponents(year: 2026, month: month, day: day,
                                      hour: hour, minute: minute))!
    }
    let schedule = NotchSceneSchedule()
    for (hour, choice) in [(0, NotchSceneChoice.lamplitSofa), (5, .lamplitSofa),
                          (6, .cloudyDesk), (11, .cloudyDesk), (12, .goldenDesk),
                          (17, .goldenDesk), (18, .lamplitSofa), (23, .lamplitSofa)] {
        expect(schedule.choice(at: date(2, hour), calendar: cal) == choice,
               "local scene must match exact boundary hour \(hour)")
    }
    expect(schedule.nextBoundary(after: date(2, 23, 59), calendar: cal) == date(3, 6),
           "night must schedule the next local morning across midnight")
    expect(schedule.nextBoundary(after: date(2, 12), calendar: cal) == date(2, 18),
           "an exact boundary must schedule the next boundary, not itself")
    let spring = date(8, 1, 30, month: 3)
    let fall = date(1, 0, 30, month: 11)
    expect(schedule.nextBoundary(after: spring, calendar: cal)?.timeIntervalSince(spring) == 3.5 * 3600,
           "spring DST must schedule local 06:00 after the missing hour")
    expect(schedule.nextBoundary(after: fall, calendar: cal)?.timeIntervalSince(fall) == 6.5 * 3600,
           "fall DST must schedule local 06:00 after the repeated hour")

    var now = date(2, 8)
    var reduced = false; var power = false
    let model = NotchSceneChoiceModel(now: { now }, calendar: { cal },
                                     reduceMotion: { reduced }, lowPower: { power })
    expect(model.choice == .cloudyDesk && model.scheduledDate == nil,
           "initial scene must use injected local time without hidden deadlines")
    model.setVisible(true)
    expect(!model.motionAllowed && model.scheduledDate == schedule.nextBoundary(after: now, calendar: cal),
           "visible but unavailable artwork must retain boundaries without light frame work")
    model.setArtworkAvailable(true)
    expect(model.motionAllowed && model.scheduledDate == now.addingTimeInterval(60),
           "visible light updates must have one next-minute deadline")
    model.setVisible(false)
    let hiddenLight = model.light
    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    expect(model.scheduledDate == nil && !model.motionAllowed && model.light == hiddenLight,
           "hidden state must cancel both deadline and queued interpolation")

    now = date(3, 20)
    model.refreshEnvironment()
    expect(model.choice == .lamplitSofa && model.scheduledDate == nil,
           "wake across a day must recompute the scene without restarting hidden light work")
    model.setVisible(true)
    cal.timeZone = TimeZone(identifier: "Asia/Tokyo")!
    NotificationCenter.default.post(name: .NSSystemTimeZoneDidChange, object: nil)
    expect(model.choice == schedule.choice(at: now, calendar: cal),
           "timezone notification must use the new calendar in the same model")
    reduced = true; model.refreshEnvironment()
    expect(!model.motionAllowed && model.scheduledDate == schedule.nextBoundary(after: now, calendar: cal),
           "Reduce Motion must retain scene boundaries and cancel minute light work")
    reduced = false; power = true; model.refreshEnvironment()
    expect(!model.motionAllowed && model.scheduledDate == schedule.nextBoundary(after: now, calendar: cal),
           "Low Power Mode must retain scenes without continuous light animation")
    power = false; model.refreshEnvironment()
    expect(model.motionAllowed && model.scheduledDate == now.addingTimeInterval(60),
           "lifting power protection must resume light updates in the same visible model")

    model.preview(hour: 8)
    expect(model.choice == .cloudyDesk && model.scheduledDate == nil && model.motionAllowed,
           "review time holds scene deadlines while eligible artwork animation stays active")
    model.setArtworkAvailable(false)
    expect(!model.motionAllowed && model.scheduledDate == nil,
           "missing artwork or an unrevealed surface must stop preview animation")
    model.setArtworkAvailable(true)
    model.preview(hour: 20)
    expect(model.choice == .lamplitSofa, "evening preview must use unchanged R16")
    expect(!model.setSchedule(.init(morning: 12, afternoon: 6, evening: 18)) && model.schedule == schedule,
           "invalid boundaries must leave the last valid schedule intact")
    expect(model.setSchedule(.init(morning: 7, afternoon: 13, evening: 19)),
           "valid custom hour boundaries must be accepted")
    model.preview(hour: 12)
    expect(model.choice == .cloudyDesk, "custom afternoon boundary must affect scene selection")
    model.preview(hour: nil)
    expect(model.choice == model.schedule.choice(at: now, calendar: cal),
           "automatic mode must return to actual local time")

    for boundary in [date(4, 0), date(4, 6), date(4, 12), date(4, 18)] {
        let before = NotchAmbientLight.at(boundary.addingTimeInterval(-1), calendar: cal)
        let after = NotchAmbientLight.at(boundary, calendar: cal)
        expect(abs(before.red - after.red) < 0.001 && abs(before.blue - after.blue) < 0.001
               && abs(before.strength - after.strength) < 0.001,
               "ambient light must remain continuous across scene boundaries and midnight")
    }
    let morningLight = NotchAmbientLight.at(date(4, 8), calendar: cal)
    let laterLight = NotchAmbientLight.at(date(4, 9), calendar: cal)
    expect(morningLight != laterLight && schedule.choice(at: date(4, 8), calendar: cal)
           == schedule.choice(at: date(4, 9), calendar: cal),
           "light must vary independently while the same scene remains selected")
    model.shutdown()
    let count = model.refreshCount
    NotificationCenter.default.post(name: .NSSystemTimeZoneDidChange, object: nil)
    model.setVisible(true); model.refreshEnvironment()
    expect(model.isShutDown && !model.isVisible && model.scheduledDate == nil && model.refreshCount == count,
           "shutdown must release observers and reject late scene work")
}
