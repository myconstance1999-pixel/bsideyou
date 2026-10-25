// BSidePlatform — explicit Beijing wall-clock conversion for automatic wallpaper lighting.
// Pure date inputs only: the agent owns reading the clock, scheduling, and system events.

import Foundation
import BSideCore

public enum BeijingClock {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }()

    // Share the Core policy's thresholds rather than duplicating its schedule.
    private static let boundaryMinutes = [
        TimeOfDay.automaticDayStartMinute,
        TimeOfDay.evening.minuteOfDay,
        TimeOfDay.night.minuteOfDay,
    ]

    /// The Beijing hour and minute for this absolute instant, independent of the Mac's zone.
    public static func minuteOfDay(at date: Date) -> Int {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return components.hour! * 60 + components.minute!
    }

    /// The next automatic-lighting boundary, strictly later than `date`.
    /// Calendar matching handles the next Beijing day without relying on the system calendar.
    public static func nextBoundary(after date: Date) -> Date {
        let candidates = boundaryMinutes.compactMap { minute in
            calendar.nextDate(
                after: date,
                matching: DateComponents(hour: minute / 60, minute: minute % 60, second: 0),
                matchingPolicy: .nextTime,
                repeatedTimePolicy: .first,
                direction: .forward
            )
        }
        guard let boundary = candidates.min() else {
            preconditionFailure("Automatic lighting policy must have a valid daily boundary")
        }
        return boundary
    }
}
