import Foundation
import BSideCore

private func queueEntry(_ id: String, song: String = "same-song", mode: PerformancePlaybackMode = .watch)
    -> PerformanceQueueEntry {
    PerformanceQueueEntry(id: id, performanceID: PerformanceID(song), presentation: .sidePerformance, mode: mode)
}

private func queueEnd(_ state: inout PerformanceQueueState, _ session: String,
                      chooseIndex: (Int) -> Int = { _ in 0 }) -> PerformanceQueueState.Outcome {
    guard state.bind(sessionID: session) else { return .ignored }
    return state.received(PerformanceReport(sessionID: session, state: .ended), chooseIndex: chooseIndex)
}

func runPerformanceQueueTests() {
    let a = queueEntry("a"), b = queueEntry("b", mode: .listen), c = queueEntry("c"), d = queueEntry("d")

    run("PerformanceQueue.favoriteWeightAndFiniteRun") { t in
        let ordinary = queueEntry("ordinary", song: "ordinary-song")
        let favorite = queueEntry("favorite", song: "favorite-song")
        let favorites: Set<PerformanceQueueTarget> = [favorite.target]
        var drawn: [String] = []
        // Exhaust every possible initial ticket: exact 1:3 odds without a statistical test.
        for ticket in 0..<4 {
            var state = PerformanceQueueState(configuration:
                PerformanceQueueConfiguration(entries: [ordinary, favorite], order: .shuffle))
            let first = state.begin(favorites: favorites, chooseIndex: { total in
                t.expectEqual(total, 4, "favorite has three tickets and ordinary has one")
                return ticket
            })
            drawn.append(first?.id ?? "missing")
            _ = state.bind(sessionID: "weighted")
            let next = state.received(PerformanceReport(sessionID: "weighted", state: .ended),
                                     favorites: favorites, chooseIndex: { _ in 0 })
            t.expectEqual(next, .play(first == ordinary ? favorite : ordinary), "no repeat within the run")
            _ = state.bind(sessionID: "last")
            t.expectEqual(state.received(PerformanceReport(sessionID: "last", state: .ended),
                favorites: favorites, chooseIndex: { _ in 0 }), .stopped, "finite shuffle still ends")
        }
        t.expectEqual(drawn, ["ordinary", "favorite", "favorite", "favorite"], "exact favorite draw weight")
        var state = PerformanceQueueState(configuration:
            PerformanceQueueConfiguration(entries: [ordinary, favorite], order: .shuffle))
        t.expectNil(state.begin(favorites: favorites, chooseIndex: { $0 }), "invalid ticket cannot select a track")
        _ = state.begin(entryID: ordinary.id, favorites: favorites, chooseIndex: { _ in -1 })
        t.expectEqual(state.next(favorites: [], chooseIndex: { total in
            t.expectEqual(total, 1, "unfavoriting affects the next draw immediately")
            return 0
        }), .play(favorite), "explicit next shares the finite sampler")
    }

    run("PerformanceQueue.localFavoriteWeight") { t in
        let ordinary = queueEntry("ordinary")
        let local = PerformanceQueueEntry(id: "local", trackID: "local-song", fileID: "exact-file", mode: .listen)
        for ticket in 0..<4 {
            var state = PerformanceQueueState(configuration: PerformanceQueueConfiguration(entries: [ordinary, local], order: .shuffle))
            t.expectEqual(state.begin(favorites: [local.target], chooseIndex: { total in
                t.expectEqual(total, 4, "local favorites share the same weighting")
                return ticket
            }), ticket == 0 ? ordinary : local, "the exact local file remains captured")
        }
    }

    run("PerformanceQueue.configurationRestoresOnlySelectionIntent") { t in
        do {
            let configuration = PerformanceQueueConfiguration(entries: [a, b], order: .shuffle)
            let data = try JSONEncoder().encode(configuration)
            let decoded = try JSONDecoder().decode(PerformanceQueueConfiguration.self, from: data)
            t.expectEqual(decoded, configuration, "same song with distinct entry identities survives persistence")
            let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            t.expectEqual(Set(json.keys), Set(["entries", "order"]), "no runtime is persisted")
            let entries = json["entries"] as! [[String: Any]]
            t.expectEqual(Set(entries[0].keys), Set(["id", "target", "mode"]),
                          "new entries persist the unambiguous typed target only")
            let target = entries[0]["target"] as! [String: Any]
            t.expectEqual(Set(target.keys), Set(["official"]),
                          "an official target carries the semantic choice, no variant/lighting/path")
            t.expectEqual(Set((target["official"] as! [String: Any]).keys),
                          Set(["performanceID", "presentation"]),
                          "official target keeps exactly the performance id and camera")
            // Legacy official-only queue JSON still decodes unchanged.
            let legacy = #"{"entries":[{"id":"legacy","performanceID":"same-song","presentation":"sidePerformance","mode":"listen"}],"order":"stopAfterQueue"}"#
            guard let restoredLegacy = try? JSONDecoder().decode(PerformanceQueueConfiguration.self,
                                                                 from: Data(legacy.utf8)) else {
                t.expect(false, "a legacy official-only queue must still decode")
                return
            }
            t.expectEqual(restoredLegacy.entries.first?.performanceID, PerformanceID("same-song"),
                          "legacy performance id survives")
            t.expectEqual(restoredLegacy.entries.first?.presentation, .sidePerformance,
                          "legacy presentation survives")
            t.expectEqual(restoredLegacy.entries.first?.mode, .listen, "legacy mode survives")
            t.expect(restoredLegacy.entries.first?.target.localSelection == nil,
                     "a legacy entry never invents a local target")
            let restored = PerformanceQueueState(configuration: decoded)
            t.expect(!restored.isRunning && !restored.paused, "loading saved configuration never starts playback")
            t.expectNil(restored.activeEntry, "no restored current entry")
            t.expectNil(restored.activeSessionID, "no restored session")
            var invalid = json
            invalid["entries"] = [entries[0], entries[0]]
            t.expectThrows("duplicate stable entry IDs cannot silently collapse queue positions") {
                _ = try JSONDecoder().decode(PerformanceQueueConfiguration.self,
                    from: JSONSerialization.data(withJSONObject: invalid))
            }
            invalid = json
            invalid["order"] = "future-order"
            t.expectThrows("unknown order does not guess a playback policy") {
                _ = try JSONDecoder().decode(PerformanceQueueConfiguration.self,
                    from: JSONSerialization.data(withJSONObject: invalid))
            }
        } catch { t.expect(false, "queue configuration coding failed: \(error)") }
    }
    run("PerformanceQueue.sequentialIdentityAndExplicitStart") { t in
        var state = PerformanceQueueState(configuration: PerformanceQueueConfiguration(entries: [a, b, c]))
        t.expectEqual(state.begin(chooseIndex: { _ in -1 }), a, "sequential order does not consult randomness")
        t.expect(state.isRunning && state.activeSessionID == nil, "begin is pending a new session binding")
        t.expectEqual(queueEnd(&state, "a-session"), .play(b), "duplicate song in a distinct entry plays separately")
        t.expectEqual(state.activeEntry?.mode, .listen, "next entry carries its explicit playback mode")
        t.expectEqual(queueEnd(&state, "b-session"), .play(c), "ordered next entry")
        t.expectEqual(queueEnd(&state, "c-session"), .stopped, "one finite pass stops")
        t.expectEqual(state.configuration.entries, [a, b, c], "finishing retains the saved queue")
        t.expectEqual(state.begin(entryID: "b", chooseIndex: { _ in -1 }), b, "explicit middle start")
        t.expectEqual(queueEnd(&state, "middle"), .play(c), "sequential start skips the preceding prefix")
        t.expectEqual(queueEnd(&state, "last"), .stopped, "skipped prefix does not appear after the tail")
    }
    run("PerformanceQueue.liveEditsKeepCurrentAndUseUnvisitedOrder") { t in
        var state = PerformanceQueueState(configuration: PerformanceQueueConfiguration(entries: [a, b, c]))
        _ = state.begin(chooseIndex: { _ in 0 })
        t.expect(state.bind(sessionID: "current"), "bind current session")
        t.expect(state.setPaused(true), "pause intent belongs to the run")
        t.expect(state.move(entryID: "c", to: 0), "move an unplayed entry before the active entry")
        t.expect(state.remove(entryID: "b"), "remove an unplayed entry")
        t.expect(state.append(d), "new entry joins the remaining queue")
        t.expect(!state.append(a), "same entry identity cannot be appended twice")
        t.expectEqual(state.activeEntry, a, "editing never replaces the active snapshot")
        t.expectEqual(state.activeSessionID, "current", "editing never revokes the current binding")
        t.expect(state.isRunning && state.paused, "editing does not pause or stop the current run")
        t.expectEqual(state.received(PerformanceReport(sessionID: "current", state: .ended), chooseIndex: { _ in 0 }),
                      .play(c), "new list order selects only unvisited entries")
        t.expect(state.paused, "natural next keeps pause intent")
        t.expectEqual(queueEnd(&state, "c-next"), .play(d), "visited active entry is not replayed after a reorder")
        t.expectEqual(queueEnd(&state, "d-next"), .stopped, "appended item participates exactly once")
    }
    run("PerformanceQueue.removingOrClearingCurrentWaitsForItsEnd") { t in
        var state = PerformanceQueueState(configuration: PerformanceQueueConfiguration(entries: [a, b], order: .repeatOne))
        _ = state.begin(chooseIndex: { _ in 0 })
        _ = state.bind(sessionID: "removed-current")
        t.expect(state.remove(entryID: "a"), "remove the current queue entry")
        t.expectEqual(state.activeEntry, a, "current item remains represented until its real end")
        t.expect(state.isRunning, "removal does not stop current media")
        t.expectEqual(state.received(PerformanceReport(sessionID: "removed-current", state: .ended), chooseIndex: { _ in 0 }),
                      .play(b), "repeat-one cannot replay a deleted entry")
        _ = state.bind(sessionID: "cleared-current")
        state.clear()
        t.expectEqual(state.activeEntry, b, "clear preserves the currently playing snapshot")
        t.expectEqual(state.activeSessionID, "cleared-current", "clear preserves its completion binding")
        t.expectEqual(state.received(PerformanceReport(sessionID: "cleared-current", state: .ended), chooseIndex: { _ in 0 }),
                      .stopped, "cleared queue stops at current end")
        t.expect(state.configuration.entries.isEmpty, "clear remains persisted intent")
        _ = state.append(a)
        _ = state.begin(chooseIndex: { _ in 0 })
        state.clear()
        _ = state.append(c)
        t.expectEqual(queueEnd(&state, "cleared-then-appended"), .play(c), "append after clear can join before current end")
    }
    run("PerformanceQueue.repeatOneNeedsANewBindingAndManualNextSkipsIt") { t in
        var state = PerformanceQueueState(configuration: PerformanceQueueConfiguration(entries: [a, b], order: .repeatOne))
        _ = state.begin(chooseIndex: { _ in 0 })
        _ = state.setPaused(true)
        t.expectEqual(queueEnd(&state, "once"), .play(a), "natural end repeats the existing queue entry")
        t.expectNil(state.activeSessionID, "each repeat must bind a freshly resolved session")
        t.expectEqual(state.received(PerformanceReport(sessionID: "once", state: .ended), chooseIndex: { _ in 0 }),
                      .ignored, "duplicate old completion cannot consume the pending repeat")
        t.expect(state.bind(sessionID: "repeat"), "bind the next repeat")
        t.expectEqual(state.next(chooseIndex: { _ in 0 }), .play(b), "manual next escapes repeat-one")
        t.expect(state.paused, "manual next keeps the running pause intent")
        t.expectEqual(state.received(PerformanceReport(sessionID: "repeat", state: .ended), chooseIndex: { _ in 0 }),
                      .ignored, "old repeat callback is invalidated by manual next")
        t.expectEqual(state.next(chooseIndex: { _ in 0 }), .stopped, "manual next at the final entry stops")
    }
    run("PerformanceQueue.repeatAllWrapsTheCurrentConfiguration") { t in
        var state = PerformanceQueueState(configuration: PerformanceQueueConfiguration(entries: [a, b, c], order: .repeatAll))
        _ = state.begin(entryID: "b", chooseIndex: { _ in 0 })
        t.expectEqual(queueEnd(&state, "first-b"), .play(c), "first partial cycle starts at the requested position")
        t.expectEqual(queueEnd(&state, "first-c"), .play(a), "new cycle includes the previous prefix")
        _ = state.remove(entryID: "b")
        _ = state.append(d)
        t.expectEqual(queueEnd(&state, "second-a"), .play(c), "next cycle uses live removal")
        t.expectEqual(queueEnd(&state, "second-c"), .play(d), "next cycle includes live append")
        t.expectEqual(queueEnd(&state, "second-d"), .play(a), "repeat-all resets only after all current entries are visited")
    }
    run("PerformanceQueue.shuffleIsOneRoundWithoutRepeats") { t in
        var state = PerformanceQueueState(configuration: PerformanceQueueConfiguration(entries: [a, b, c, d], order: .shuffle))
        var choices: [Int] = []
        func last(_ count: Int) -> Int { choices.append(count); return count - 1 }
        var seen: [String] = []
        if let first = state.begin(chooseIndex: last) { seen.append(first.id) }
        for index in 0..<4 {
            let outcome = queueEnd(&state, "shuffle-\(index)", chooseIndex: last)
            if case .play(let entry) = outcome { seen.append(entry.id) }
            else { t.expectEqual(outcome, .stopped, "shuffle ends after its finite round") }
        }
        t.expectEqual(seen, ["d", "c", "b", "a"], "injected random indices choose from only remaining entries")
        t.expectEqual(Set(seen).count, 4, "same-song entries each play once by their independent identity")
        t.expectEqual(choices, [4, 3, 2, 1], "random chooser sees shrinking candidates, never an empty list")
        t.expect(!state.isRunning, "shuffle does not silently begin another round")
        t.expectEqual(state.begin(entryID: "c", chooseIndex: { _ in -1 }), c, "explicit shuffle start bypasses random choice")
        t.expectEqual(queueEnd(&state, "chosen-c"), .play(a), "explicit shuffle start marks only its selected entry")
        t.expectEqual(queueEnd(&state, "chosen-a"), .play(b), "shuffle still includes the preceding entries")
    }
    run("PerformanceQueue.orderChangesTakeEffectAtTheNextDecision") { t in
        var state = PerformanceQueueState(configuration: PerformanceQueueConfiguration(entries: [a, b], order: .repeatOne))
        _ = state.begin(chooseIndex: { _ in 0 })
        _ = state.bind(sessionID: "keep-playing")
        state.setOrder(.stopAfterQueue)
        t.expectEqual(state.activeSessionID, "keep-playing", "order change does not interrupt current media")
        t.expectEqual(state.received(PerformanceReport(sessionID: "keep-playing", state: .ended), chooseIndex: { _ in 0 }),
                      .play(b), "leaving repeat-one allows the next entry")
        state.setOrder(.repeatAll)
        t.expectEqual(queueEnd(&state, "end-b"), .play(a), "entering repeat-all wraps at the next end")
        state.setOrder(.shuffle)
        t.expectEqual(queueEnd(&state, "end-a"), .play(b), "new shuffle order respects entries already visited this round")
        t.expectEqual(queueEnd(&state, "shuffle-end"), .stopped, "shuffle change does not create endless rounds")
    }
    run("PerformanceQueue.reportAndLifetimeGuards") { t in
        for terminal in [PerformanceReport.State.failed, .stopped] {
            var state = PerformanceQueueState(configuration: PerformanceQueueConfiguration(entries: [a, b]))
            t.expect(!state.setPaused(true), "stopped queue cannot collect a pause intent")
            t.expect(!state.bind(sessionID: "idle"), "stopped queue cannot bind a session")
            _ = state.begin(chooseIndex: { _ in 0 })
            t.expect(!state.bind(sessionID: ""), "empty binding is refused")
            t.expect(state.bind(sessionID: "active"), "active entry binds once")
            t.expect(!state.bind(sessionID: "other"), "binding cannot be replaced behind the current media")
            _ = state.setPaused(true)
            for report in [PerformanceReport(sessionID: "old", state: .ended),
                           PerformanceReport(sessionID: "old", state: .failed),
                           PerformanceReport(sessionID: "active", state: .playing),
                           PerformanceReport(sessionID: "active", state: .paused)] {
                t.expectEqual(state.received(report, chooseIndex: { _ in 0 }), .ignored, "only the bound terminal event may advance")
            }
            t.expect(state.paused, "system reports cannot overwrite the queue's requested pause")
            t.expectEqual(state.received(PerformanceReport(sessionID: "active", state: terminal), chooseIndex: { _ in 0 }),
                          .stopped, "failure/stop cannot silently skip to another track")
            t.expect(!state.isRunning && !state.paused, "terminal event clears runtime intent")
            t.expectNil(state.activeEntry, "terminal event removes the active snapshot")
            t.expectEqual(state.configuration.entries, [a, b], "failure preserves saved choices")
            _ = state.begin(chooseIndex: { _ in 0 })
            _ = state.bind(sessionID: "new-generation")
            state.agentLost()
            t.expectEqual(state.received(PerformanceReport(sessionID: "new-generation", state: .ended), chooseIndex: { _ in 0 }),
                          .ignored, "agent loss prevents a late end from restarting the queue")
            t.expect(!state.isRunning, "agent recovery cannot restart transient queue state")
            state.stop()
            t.expectEqual(state.configuration.entries, [a, b], "stop remains idempotent and keeps configuration")
        }
    }
    run("PerformanceQueue.emptyAndInvalidChoicesAreSafe") { t in
        var state = PerformanceQueueState()
        var called = false
        t.expectNil(state.begin(chooseIndex: { _ in called = true; return 0 }), "empty begin returns no work")
        t.expectEqual(state.next(chooseIndex: { _ in called = true; return 0 }), .ignored, "empty next has no work")
        t.expect(!called, "empty queue never asks for a random index")
        t.expect(!state.append(queueEntry(" ")), "blank identities cannot enter configuration")
        _ = state.append(a)
        _ = state.append(b)
        t.expectNil(state.begin(entryID: "missing", chooseIndex: { _ in 0 }), "invalid explicit entry does not pick a replacement")
        state.setOrder(.shuffle)
        t.expectNil(state.begin(chooseIndex: { $0 }), "out-of-range initial choice cannot trap or fallback")
        _ = state.begin(chooseIndex: { _ in 0 })
        t.expectEqual(state.next(chooseIndex: { _ in -1 }), .stopped, "out-of-range next choice stops instead of guessing")
        t.expectEqual(state.configuration.entries, [a, b], "invalid choices preserve configuration")
        t.expect(!state.move(entryID: "a", to: 2), "invalid final move index is rejected")
        t.expect(!state.remove(entryID: "missing"), "unknown removal is a no-op")
    }
    run("PerformanceQueue.insertAfterActiveIsImmediateAndNonInterrupting") { t in
        var state = PerformanceQueueState(configuration: PerformanceQueueConfiguration(entries: [a, b, c]))
        // Nothing is playing: the explicit next cannot be honored, and nothing is inserted.
        t.expect(!state.insertAfterActive(d), "an idle queue must refuse an explicit next")
        t.expect(state.configuration.entries == [a, b, c], "a refused next leaves the list untouched")
        _ = state.begin(entryID: "a", chooseIndex: { _ in 0 })
        t.expect(state.bind(sessionID: "playing-a"), "bind the running entry")
        _ = state.setPaused(true)
        t.expect(state.insertAfterActive(d), "a running queue accepts an explicit next")
        t.expectEqual(state.configuration.entries.map(\.id), ["a", "d", "b", "c"],
                      "the inserted entry sits immediately after the active one")
        t.expectEqual(state.activeEntry, a, "the current entry snapshot is unchanged")
        t.expectEqual(state.activeSessionID, "playing-a", "the current binding is unchanged")
        t.expect(state.isRunning && state.paused, "insertion neither stops nor resumes the current run")
        t.expect(!state.insertAfterActive(d), "the same identity cannot be inserted twice")
        t.expectEqual(state.received(PerformanceReport(sessionID: "playing-a", state: .ended),
                                     chooseIndex: { _ in -1 }),
                      .play(d), "the inserted entry is next, and the random chooser is not consulted")
        t.expect(state.paused, "the explicit next keeps the pause intent")
        t.expectEqual(state.received(PerformanceReport(sessionID: "d-session", state: .ended),
                                     chooseIndex: { _ in 0 }),
                      .ignored, "an unbound session cannot advance the queue")
        _ = state.bind(sessionID: "d-session")
        t.expectEqual(state.received(PerformanceReport(sessionID: "d-session", state: .ended),
                                     chooseIndex: { _ in 0 }),
                      .play(b), "the priority is consumed once and never replayed")
    }
    run("PerformanceQueue.explicitNextSurvivesShuffleAndLeavesWithItsEntry") { t in
        var state = PerformanceQueueState(configuration: PerformanceQueueConfiguration(entries: [a, b, c],
                                                                                       order: .shuffle))
        _ = state.begin(entryID: "b", chooseIndex: { _ in 0 })
        _ = state.bind(sessionID: "shuffle-b")
        t.expect(state.insertAfterActive(d), "shuffle accepts an explicit next")
        t.expectEqual(state.received(PerformanceReport(sessionID: "shuffle-b", state: .ended),
                                     chooseIndex: { _ in 0 }),
                      .play(d), "an explicit next outranks the shuffle draw exactly once")
        _ = state.bind(sessionID: "shuffle-d")
        var seen: [String] = []
        for index in 0..<3 {
            guard case .play(let entry) = state.received(
                PerformanceReport(sessionID: "shuffle-\(index)", state: .ended),
                chooseIndex: { _ in 0 }), state.bind(sessionID: "shuffle-\(index)") else { break }
            seen.append(entry.id)
        }
        t.expectEqual(Set(seen).count, seen.count, "shuffle still never repeats inside a round")
        t.expect(!seen.contains("d"), "the explicit next does not replay in the same round")
        // Removing the pending priority before it plays drops the intent.
        var removed = PerformanceQueueState(configuration: PerformanceQueueConfiguration(entries: [a, b],
                                                                                         order: .shuffle))
        _ = removed.begin(entryID: "a", chooseIndex: { _ in 0 })
        _ = removed.insertAfterActive(d)
        t.expect(removed.remove(entryID: "d"), "the pending next can be removed")
        _ = removed.bind(sessionID: "removed-a")
        t.expectEqual(removed.received(PerformanceReport(sessionID: "removed-a", state: .ended),
                                       chooseIndex: { _ in 0 }),
                      .play(b), "a removed priority is never played")
        // Stop clears the intent.
        var stopped = PerformanceQueueState(configuration: PerformanceQueueConfiguration(entries: [a, b]))
        _ = stopped.begin(entryID: "a", chooseIndex: { _ in 0 })
        _ = stopped.insertAfterActive(d)
        stopped.stop()
        _ = stopped.begin(entryID: "a", chooseIndex: { _ in 0 })
        _ = stopped.bind(sessionID: "restarted-a")
        t.expectEqual(stopped.received(PerformanceReport(sessionID: "restarted-a", state: .ended),
                                       chooseIndex: { _ in 0 }),
                      .play(d), "stopping clears the previous explicit next")
    }
    run("PerformanceQueue.explicitNextIsHonoredOnNaturalEndInRepeatOne") { t in
        var state = PerformanceQueueState(configuration: PerformanceQueueConfiguration(entries: [a, b],
                                                                                       order: .repeatOne))
        _ = state.begin(entryID: "a", chooseIndex: { _ in 0 })
        _ = state.bind(sessionID: "repeat-a")
        t.expect(state.insertAfterActive(d), "repeat-one accepts an explicit next")
        t.expectEqual(state.received(PerformanceReport(sessionID: "repeat-a", state: .ended),
                                     chooseIndex: { _ in 0 }),
                      .play(d), "an explicit next outranks repeat-one on the natural end")
        _ = state.bind(sessionID: "repeat-d")
        t.expectEqual(state.received(PerformanceReport(sessionID: "repeat-d", state: .ended),
                                     chooseIndex: { _ in 0 }),
                      .play(d), "the priority is consumed once; repeat-one then repeats the current entry")
        // Repeat-one still repeats when nothing was queued, and manual next still escapes it.
        var plain = PerformanceQueueState(configuration: PerformanceQueueConfiguration(entries: [a, b],
                                                                                       order: .repeatOne))
        _ = plain.begin(entryID: "a", chooseIndex: { _ in 0 })
        _ = plain.bind(sessionID: "plain-a")
        t.expectEqual(plain.received(PerformanceReport(sessionID: "plain-a", state: .ended),
                                     chooseIndex: { _ in 0 }),
                      .play(a), "repeat-one repeats when no explicit next is pending")
        _ = plain.bind(sessionID: "plain-a2")
        t.expectEqual(plain.next(chooseIndex: { _ in 0 }), .play(b),
                      "manual next still escapes repeat-one")
    }
    run("PerformanceQueue.explicitNextSurvivesModeChangeAfterInsertion") { t in
        // Insertion under a sequential order, then a later switch to shuffle: the explicit next
        // must still be the next entry, not a random draw.
        var state = PerformanceQueueState(configuration: PerformanceQueueConfiguration(entries: [a, b],
                                                                                       order: .stopAfterQueue))
        _ = state.begin(entryID: "a", chooseIndex: { _ in 0 })
        _ = state.bind(sessionID: "seq-a")
        t.expect(state.insertAfterActive(d), "a sequential queue accepts an explicit next")
        state.setOrder(.shuffle)
        t.expectEqual(state.received(PerformanceReport(sessionID: "seq-a", state: .ended),
                                     chooseIndex: { _ in 0 }),
                      .play(d), "the explicit next survives a later switch to shuffle")
        // The reverse direction: inserted under shuffle, switched to repeat-one before it played.
        var reversed = PerformanceQueueState(configuration: PerformanceQueueConfiguration(entries: [a, b],
                                                                                           order: .shuffle))
        _ = reversed.begin(entryID: "a", chooseIndex: { _ in 0 })
        _ = reversed.bind(sessionID: "shuffle-a")
        t.expect(reversed.insertAfterActive(d), "a shuffle queue accepts an explicit next")
        reversed.setOrder(.repeatOne)
        t.expectEqual(reversed.received(PerformanceReport(sessionID: "shuffle-a", state: .ended),
                                        chooseIndex: { _ in 0 }),
                      .play(d), "the explicit next still outranks repeat-one after the mode changed")
    }
}
