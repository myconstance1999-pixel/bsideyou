import Foundation
import BSideCore

func runSongPlaybackHistoryTests() {
    func item(_ name: String, revision: String = "r1") -> SongPlaybackNavigation.Item {
        let record = SongPlaybackRecord(target: .localFile(.init(trackID: name, fileID: "file-\(name)",
            catalogRevision: .init(revision))), fileBinding: .init(relativePath: "\(name).mp4", byteSize: 100,
            sha256: String(repeating: "a", count: 64)), mode: .listen, title: name, lastPlayed: Date(timeIntervalSince1970: 1))
        return .init(record: record, queueEntry: .init(id: name, trackID: name, fileID: "file-\(name)", mode: .listen))
    }
    let a = item("A"), b = item("B"), c = item("C")
    func play(_ nav: inout SongPlaybackNavigation, _ item: SongPlaybackNavigation.Item, _ session: String) {
        nav.installed(sessionID: session, item: item)
        _ = nav.received(.init(sessionID: session, state: .playing), at: Date())
    }
    run("SongHistory.confirmationAndStaleReports") { t in
        var nav = SongPlaybackNavigation()
        nav.installed(sessionID: "a", item: a)
        t.expectNil(nav.received(.init(sessionID: "old", state: .playing), at: Date()), "stale cannot record")
        t.expectNil(nav.received(.init(sessionID: "a", state: .loading), at: Date()), "loading cannot record")
        t.expectNil(nav.received(.init(sessionID: "a", state: .paused), at: Date()), "initial paused cannot record")
        t.expect(nav.path.isEmpty, "paused preflight does not enter navigation")
        t.expect(nav.received(.init(sessionID: "a", state: .playing), at: Date()) != nil, "confirmed play records once")
        _ = nav.received(.init(sessionID: "a", state: .paused), at: Date())
        t.expectNil(nav.received(.init(sessionID: "a", state: .playing), at: Date()), "resume never duplicates")
        _ = nav.received(.init(sessionID: "a", state: .failed), at: Date())
        t.expectNil(nav.received(.init(sessionID: "a", state: .playing), at: Date()), "terminal consumes authority")
        t.expectEqual(nav.path.count, 1, "one successful file")
    }
    run("SongHistory.previousForwardAndPausedReadiness") { t in
        var nav = SongPlaybackNavigation()
        for (i, entry) in [a, c, b].enumerated() { play(&nav, entry, "s\(i)") }
        let previous = nav.requestMove(-1)!
        t.expectEqual(previous.item.record.title, "C", "actual shuffle order")
        nav.installed(sessionID: "back", item: previous.item, navigationIndex: previous.index)
        t.expectNil(nav.received(.init(sessionID: "back", state: .paused), at: Date()), "paused move records no play")
        t.expectEqual(nav.cursor, 1, "paused readiness commits cursor")
        let first = nav.requestMove(-1)!
        t.expectEqual(first.item.record.title, "A", "second previous does not toggle")
        nav.installed(sessionID: "first", item: first.item, navigationIndex: first.index)
        _ = nav.received(.init(sessionID: "first", state: .paused), at: Date())
        t.expect(!nav.canPrevious, "oldest previous disabled")
        let forward = nav.requestMove(1)!
        t.expectEqual(forward.item.record.title, "C", "next retraces forward path")
        nav.installed(sessionID: "forward", item: forward.item, navigationIndex: forward.index)
        _ = nav.received(.init(sessionID: "forward", state: .playing), at: Date())
        t.expectEqual(nav.path.map { $0.record.title }, ["A", "C", "B"], "traversal does not append or branch")
        t.expectEqual(nav.requestMove(1)?.item.record.title, "B", "forward frontier remains")
    }
    run("SongHistory.repeatFailedStartPendingAndReset") { t in
        var nav = SongPlaybackNavigation()
        play(&nav, a, "a"); play(&nav, b, "b")
        play(&nav, item("B", revision: "metadata-change"), "repeat")
        t.expectEqual(nav.path.count, 2, "same local file coalesces despite catalog metadata edits")
        nav.installed(sessionID: "failed", item: c)
        t.expectEqual(nav.requestMove(-1)?.item.record.title, "B", "previous during unconfirmed start returns last success")
        t.expectEqual(nav.requestMove(-1)?.item.record.title, "A", "rapid pending previous advances request cursor")
        nav.cancelMove()
        _ = nav.received(.init(sessionID: "failed", state: .failed), at: Date())
        t.expectEqual(nav.path.count, 2, "failed start adds nothing")
        t.expectEqual(nav.cursor, 1, "failed admission does not commit cursor")
        nav.reset()
        t.expect(!nav.canPrevious && !nav.canForward && nav.path.isEmpty, "stop/loss clears transient navigation")
        t.expectNil(nav.received(.init(sessionID: "repeat", state: .playing), at: Date()), "reset rejects late reports")
    }
    run("SongHistory.boundedPersistenceAndBranch") { t in
        var history = SongPlaybackHistory()
        for index in 0..<205 { history.record(item("\(index)").record) }
        t.expectEqual(history.records.count, 200, "bounded newest starts")
        t.expectEqual(history.records.first?.title, "204", "newest first")
        t.expectEqual(history.records.last?.title, "5", "oldest cropped")
        history.record(item("204", revision: "changed-metadata").record)
        t.expectEqual(history.records.count, 200, "repeat-one cannot flood persisted history")
        let restored = try! JSONDecoder().decode(SongPlaybackHistory.self, from: JSONEncoder().encode(history))
        t.expectEqual(restored, history, "exact target binding mode date survive reload")
        t.expect(restored.isValid, "valid stored record")
        var nav = SongPlaybackNavigation()
        play(&nav, a, "a"); play(&nav, b, "b"); play(&nav, c, "c")
        let back = nav.requestMove(-1)!
        nav.installed(sessionID: "back", item: back.item, navigationIndex: back.index)
        _ = nav.received(.init(sessionID: "back", state: .paused), at: Date())
        play(&nav, a, "explicit-history")
        t.expectEqual(nav.path.map { $0.record.title }, ["A", "B", "A"], "explicit replay creates confirmed branch")
        t.expect(!nav.canForward, "abandoned future not replayed after explicit selection")
    }
    run("SongHistory.queuePriorityEditsAndStaleTerminal") { t in
        for order in [PerformanceQueueOrder.shuffle, .repeatOne, .repeatAll, .stopAfterQueue] {
            var queue = PerformanceQueueState(configuration: .init(entries: [a.queueEntry!, b.queueEntry!, c.queueEntry!], order: order))
            _ = queue.begin(entryID: "A", chooseIndex: { _ in 0 }); _ = queue.bind(sessionID: "original")
            let priority = item("P").queueEntry!
            _ = queue.insertAfterActive(priority)
            _ = queue.next(chooseIndex: { _ in 0 }) // Consume P normally first.
            _ = queue.bind(sessionID: "p")
            let nextPriority = item("N").queueEntry!
            _ = queue.insertAfterActive(nextPriority)
            let saved = queue.configuration
            queue.bindHistory(a.queueEntry!, sessionID: "history")
            _ = queue.setPaused(true)
            t.expectEqual(queue.configuration, saved, "history does not edit configuration")
            t.expectEqual(queue.received(.init(sessionID: "original", state: .ended), chooseIndex: { _ in 0 }), .ignored, "old EOF cannot advance")
            _ = queue.remove(entryID: "A")
            _ = queue.move(entryID: "C", to: 0)
            t.expect(queue.paused, "edits preserve pause")
            t.expectEqual(queue.next(chooseIndex: { _ in 0 }), .play(nextPriority), "play-next priority survives history and edits")
            t.expect(queue.paused, "normal advancement retains pause intent")
        }
    }
}
