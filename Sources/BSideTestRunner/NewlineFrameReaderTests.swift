// BSideTestRunner — pure NewlineFrameReader tests (Beta Slice 6).
// Deterministic transport-framing coverage that the real-pipe fixture (verify_ipc_fixture.sh)
// exercises end-to-end against the production readers: partial reads/writes, multiple frames
// per read, malformed-line skip, oversized drop + resync at the next newline, memory bound
// without any newline, and EOF tail handling.

import Foundation
import BSideCore

func runNewlineFrameReaderTests() {
    run("Framer.partialLineAcrossFeeds") { t in
        var f = NewlineFrameReader()
        let first = "{\"protocolVersion\":\(IPC.protocolVersion),\"messageID\":\"a\",\"sentAt\":0,\"payl"
        let second = "oad\":{\"health\":1}}"
        t.expectEqual(f.feed(Data(first.utf8)).count, 0, "no newline yet — no frame")
        t.expectEqual(f.bufferedBytes, first.utf8.count, "partial bytes buffered")
        t.expectEqual(f.feed(Data(second.utf8)).count, 0, "still no newline")
        let frames = f.feed(Data("\n".utf8))
        t.expectEqual(frames.count, 1, "newline completes the one partial frame")
        t.expectEqual(String(data: frames[0], encoding: .utf8), first + second, "frame content assembled across writes")
        t.expectEqual(f.bufferedBytes, 0, "buffer drained")
    }

    run("Framer.multipleFramesInOneFeed") { t in
        var f = NewlineFrameReader()
        let frames = f.feed(Data("one\ntwo\nthree\n".utf8))
        t.expectEqual(frames.count, 3, "three frames from one read")
        t.expectEqual(frames.map { String(data: $0, encoding: .utf8) }, ["one", "two", "three"], "in order, no trailing newline")
        t.expectEqual(f.framesRead, 3, "framesRead counts all")
    }

    run("Framer.emptyLinesReturnedAndTrailingNewlineInert") { t in
        var f = NewlineFrameReader()
        let frames = f.feed(Data("a\n\nb\n".utf8))
        t.expectEqual(frames.count, 3, "blank line is its own (empty) frame")
        t.expectEqual(frames[0].isEmpty, false, "a non-empty")
        t.expectEqual(frames[1].isEmpty, true, "blank frame empty")
        t.expectEqual(String(data: frames[2], encoding: .utf8), "b", "b intact")
    }

    run("Framer.exactlyMaxFrameSizeAccepted") { t in
        var f = NewlineFrameReader()
        let line = String(repeating: "x", count: NewlineFrameReader.maxFrameSize)
        var chunk = Data(line.utf8)
        chunk.append(0x0A)
        let frames = f.feed(chunk)
        t.expectEqual(frames.count, 1, "frame exactly at the bound is accepted")
        t.expectEqual(frames[0].count, NewlineFrameReader.maxFrameSize, "full content kept")
        t.expectEqual(f.oversizeDropped, 0, "no drop at the bound")
    }

    run("Framer.oversizedLineDroppedThenResyncInSameFeed") { t in
        var f = NewlineFrameReader()
        var chunk = Data(repeating: 0x61, count: NewlineFrameReader.maxFrameSize + 1)  // 'a'
        chunk.append(0x0A)
        chunk.append(Data("next-valid\n".utf8))
        let frames = f.feed(chunk)
        t.expectEqual(frames.count, 1, "oversized frame dropped; only the next frame survives")
        t.expectEqual(String(data: frames[0], encoding: .utf8), "next-valid", "framing resynced at the newline")
        t.expectEqual(f.oversizeDropped, 1, "one oversized frame counted")
        t.expectEqual(f.bytesDropped, NewlineFrameReader.maxFrameSize + 2, "dropped = frame bytes + newline")
        t.expectEqual(f.bufferedBytes, 0, "no residue buffered")
    }

    run("Framer.oversizeAcrossFeedsDiscardsUntilNewlineThenRecovers") { t in
        var f = NewlineFrameReader()
        // Feed exactly the bound with no newline: buffered, not yet classified oversized.
        _ = f.feed(Data(repeating: 0x61, count: NewlineFrameReader.maxFrameSize))
        t.expectEqual(f.bufferedBytes, NewlineFrameReader.maxFrameSize, "buffer holds the bound")
        t.expectEqual(f.oversizeDropped, 0, "not oversized until more bytes arrive")
        // More bytes with no newline → classification happens, discard starts.
        _ = f.feed(Data("overflow".utf8))
        t.expectEqual(f.bufferedBytes, 0, "oversized prefix dropped immediately")
        // Newline arrives: terminates the oversized frame; content after it is a fresh frame.
        let frames = f.feed(Data("tail-ignored\nvalid-after\n".utf8))
        t.expectEqual(f.oversizeDropped, 1, "oversized frame counted at its terminating newline")
        t.expectEqual(frames.count, 1, "only the post-newline frame survives")
        t.expectEqual(String(data: frames[0], encoding: .utf8), "valid-after", "recovered at the next newline")
    }

    run("Framer.memoryBoundedWithoutNewline") { t in
        var f = NewlineFrameReader()
        let chunk = Data(repeating: 0x61, count: 64 * 1024)
        for _ in 0..<128 { _ = f.feed(chunk) }   // 8 MiB, no newline ever
        t.expect(f.bufferedBytes <= NewlineFrameReader.maxFrameSize,
                 "buffer never exceeds maxFrameSize despite 8 MiB of input (got \(f.bufferedBytes))")
        t.expectEqual(f.bufferedBytes, 0, "the capped frame was dropped at overflow, not retained")
        t.expectEqual(f.framesRead, 0, "no frame emitted")
        _ = f.feed(Data("\n".utf8))   // close the oversized frame
        t.expectEqual(f.oversizeDropped, 1, "the capped-out frame counted oversized at its newline")
        let frames = f.feed(Data("ok\n".utf8))
        t.expectEqual(frames.count, 1, "clean frame accepted after resync")
        t.expectEqual(String(data: frames[0], encoding: .utf8), "ok", "content correct")
    }

    run("Framer.oversizedLineMidStreamKeepsFollowingFrames") { t in
        var f = NewlineFrameReader()
        var line = "before\n"
        line += String(repeating: "y", count: NewlineFrameReader.maxFrameSize + 500)
        line += "\nafter\n"
        let frames = f.feed(Data(line.utf8))
        t.expectEqual(frames.count, 2, "before and after survive; only the giant line dropped")
        t.expectEqual(String(data: frames[0], encoding: .utf8), "before", "leading frame kept")
        t.expectEqual(String(data: frames[1], encoding: .utf8), "after", "trailing frame kept")
        t.expectEqual(f.oversizeDropped, 1, "exactly the one oversized frame dropped")
    }

    run("Framer.finishReturnsUnterminatedTail") { t in
        var f = NewlineFrameReader()
        _ = f.feed(Data("partial-no-newline".utf8))
        let final = f.finish()
        t.expectEqual(String(data: final ?? Data(), encoding: .utf8), "partial-no-newline",
                      "EOF turns the buffered tail into a final frame (readLine semantics)")
        t.expectEqual(f.framesRead, 1, "tail counted as a frame")
        t.expectNil(f.finish(), "finish is idempotent — second call returns nil")
    }

    run("Framer.finishDropsOversizedTail") { t in
        var f = NewlineFrameReader()
        _ = f.feed(Data(repeating: 0x61, count: NewlineFrameReader.maxFrameSize + 10))
        let final = f.finish()
        t.expectNil(final, "oversized unterminated tail is dropped, not surfaced")
        t.expectEqual(f.oversizeDropped, 1, "tail accounted as one oversized frame")
    }

    run("Framer.productionSequencePartialMalformedMultipleOversize") { t in
        // Simulate one hostile agent output stream end-to-end (the fixture's framing-abuse
        // sequence): malformed line, a frame split across writes, two frames in one write,
        // an oversized line, then a valid frame that must be accepted.
        var f = NewlineFrameReader()
        // 1. malformed garbage line
        _ = f.feed(Data("this is not json\n".utf8))
        // 2. valid envelope split across two writes
        _ = f.feed(Data("{\"protocolVersion\":\(IPC.protocolVersion),\"messageID\":\"p1\",\"sentA".utf8))
        let p1 = f.feed(Data("t\":0,\"payload\":{\"health\":1}}\n".utf8))
        t.expectEqual(p1.count, 1, "split frame completed")
        // 3. two frames in one write
        let burst = f.feed(Data("{\"protocolVersion\":\(IPC.protocolVersion),\"messageID\":\"p2\",\"sentAt\":0,\"payload\":{\"health\":2}}\n{\"protocolVersion\":\(IPC.protocolVersion),\"messageID\":\"p3\",\"sentAt\":0,\"payload\":{\"health\":3}}\n".utf8))
        t.expectEqual(burst.count, 2, "two frames from one write")
        // 4. oversized line
        _ = f.feed(Data(repeating: 0x61, count: NewlineFrameReader.maxFrameSize + 123))
        _ = f.feed(Data("\n".utf8))
        t.expectEqual(f.oversizeDropped, 1, "oversized line dropped")
        // 5. valid frame after all damage — must be accepted
        let ready = f.feed(Data("{\"protocolVersion\":\(IPC.protocolVersion),\"messageID\":\"p4\",\"sentAt\":0,\"payload\":{\"ready\":\(IPC.protocolVersion)}}\n".utf8))
        t.expectEqual(ready.count, 1, "valid frame accepted after malformed/oversized damage")
        let decoded = IPCCoding.decodeLine(String(data: ready[0], encoding: .utf8) ?? "", as: AgentEvent.self)
        t.expectEqual(decoded?.payload, .ready(protocolVersion: IPC.protocolVersion), "frame decodes to a ready event")
    }
}