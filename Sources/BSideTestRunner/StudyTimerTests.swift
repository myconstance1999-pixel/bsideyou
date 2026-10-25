import Foundation
import BSideCore

func runStudyTimerTests() {
    run("StudyTimer.countdownClampsAtTarget") { t in
        var session = StudySession(startedAt: Date(), title: "", mode: .countdown, targetSeconds: 60)
        session.accumulate(20)
        t.expectEqual(session.measured(adding: 100), 60, "delayed delivery cannot overcount a countdown")
        session.accumulate(100)
        t.expect(session.reachedTarget, "the target is reached exactly once")
    }
    run("StudyTimer.countUpAndNegativeDelta") { t in
        var session = StudySession(startedAt: Date(), title: "", mode: .countUp, targetSeconds: 60)
        session.accumulate(90)
        session.accumulate(-100)
        t.expectEqual(session.elapsed, 90, "count-up is unbounded by countdown target and never subtracts time")
        t.expect(!session.reachedTarget, "count-up never completes itself")
    }
    run("StudyTimer.ledgerRejectsInvalidAndDuplicateRecords") { t in
        var ledger = StudyTimerLedger()
        let session = StudySession(startedAt: Date(), title: "", mode: .countUp, targetSeconds: 60, elapsed: 20)
        ledger.records = [StudyRecord(session: session, endedAt: Date())]
        t.expect(ledger.isValid, "valid record")
        ledger.active = session
        t.expect(!ledger.isValid, "an active session cannot already be a finished record")
        ledger.active = nil
        ledger.records.append(ledger.records[0])
        t.expect(!ledger.isValid, "duplicate identities cannot silently duplicate study totals")
        ledger.records = []
        ledger.version = 2
        t.expect(!ledger.isValid, "unsupported versions are preserved as unreadable")
    }
}
