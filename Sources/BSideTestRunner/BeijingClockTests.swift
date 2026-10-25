// BSideTestRunner — fixed Beijing time and automatic-lighting schedule regressions.

import Foundation
import BSideCore
import BSidePlatform

private func beijingClockDate(_ value: String) -> Date {
    ISO8601DateFormatter().date(from: value)!
}

func runBeijingClockTests() {
    run("BeijingClock.utcConversionAndBuckets") { t in
        let cases: [(String, Int, TimeOfDay)] = [
            ("2026-09-06T21:59:59Z", 359, .night),
            ("2026-09-06T22:00:00Z", 360, .noon),
            ("2026-09-07T09:29:59Z", 1049, .noon),
            ("2026-09-07T09:30:00Z", 1050, .evening),
            ("2026-09-07T11:59:59Z", 1199, .evening),
            ("2026-09-07T12:00:00Z", 1200, .night),
            ("2026-09-07T15:59:59Z", 1439, .night),
            ("2026-09-07T16:00:00Z", 0, .night),
        ]
        for (utc, expectedMinute, expectedBucket) in cases {
            let minute = BeijingClock.minuteOfDay(at: beijingClockDate(utc))
            t.expectEqual(minute, expectedMinute, "\(utc) Beijing minute")
            t.expectEqual(TimeOfDay.autoBucket(minuteOfDay: minute), expectedBucket, "\(utc) lighting")
        }
    }

    run("BeijingClock.nextBoundaryIsStrictlyFuture") { t in
        let boundaries = [
            "2026-09-06T22:00:00Z",  // Beijing September 7, 06:00
            "2026-09-07T09:30:00Z",  // Beijing September 7, 17:30
            "2026-09-07T12:00:00Z",  // Beijing September 7, 20:00
            "2026-09-07T22:00:00Z",  // Beijing September 8, 06:00
        ].map(beijingClockDate)

        for index in 0..<3 {
            let boundary = boundaries[index]
            for secondsBefore in [60.0, 1.0, 0.25] {
                let before = boundary.addingTimeInterval(-secondsBefore)
                let next = BeijingClock.nextBoundary(after: before)
                t.expectEqual(next, boundary, "before boundary \(index) by \(secondsBefore)s")
                t.expect(next > before, "scheduled instant is strictly future")
            }
            for secondsAfter in [0.0, 0.25, 1.0, 60.0] {
                let atOrAfter = boundary.addingTimeInterval(secondsAfter)
                let next = BeijingClock.nextBoundary(after: atOrAfter)
                t.expectEqual(next, boundaries[index + 1], "at/after boundary \(index) by \(secondsAfter)s")
                t.expect(next > atOrAfter, "an exact boundary cannot immediately reschedule itself")
            }
        }
    }

    run("BeijingClock.nextBoundaryCrossesBeijingDate") { t in
        let cases = [
            ("2026-09-07T15:59:59Z", "2026-09-07T22:00:00Z"),
            ("2026-09-07T16:00:00Z", "2026-09-07T22:00:00Z"),
            ("2026-12-31T15:59:59Z", "2026-12-31T22:00:00Z"),
            ("2026-12-31T16:00:00Z", "2026-12-31T22:00:00Z"),
        ]
        for (input, expected) in cases {
            t.expectEqual(BeijingClock.nextBoundary(after: beijingClockDate(input)),
                          beijingClockDate(expected), "\(input) skips midnight and finds 06:00")
        }
    }

    run("BeijingClock.ignoresSystemTimeZoneAndDaylightSaving") { t in
        // Only the test process default changes; never modifies the Mac's time zone.
        let original = NSTimeZone.default
        defer { NSTimeZone.default = original }

        for identifier in ["America/Los_Angeles", "UTC", "Asia/Tokyo"] {
            NSTimeZone.default = TimeZone(identifier: identifier)!
            for day in ["2026-01-07", "2026-07-07", "2026-11-01"] {
                let date = beijingClockDate("\(day)T09:30:00Z")
                t.expectEqual(BeijingClock.minuteOfDay(at: date), 1050,
                              "\(identifier) on \(day) remains Beijing 17:30")
                t.expectEqual(BeijingClock.nextBoundary(after: date),
                              beijingClockDate("\(day)T12:00:00Z"),
                              "\(identifier) on \(day) schedules Beijing 20:00")
            }
        }
    }
}
