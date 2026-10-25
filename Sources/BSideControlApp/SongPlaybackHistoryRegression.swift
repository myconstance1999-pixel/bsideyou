import Foundation
import BSideCore
import BSidePlatform

func runSongPlaybackHistoryRegression(expect: (Bool, String) -> Void) {
    let root = AppPaths.applicationSupport.appendingPathComponent("song-history-regression-\(UUID().uuidString)")
    do {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("songs.json")
        let binding = PerformanceFileBinding(relativePath: "test.mp4", byteSize: 90, sha256: String(repeating: "a", count: 64))
        let record = SongPlaybackRecord(target: .localFile(.init(trackID: "track", fileID: "file", catalogRevision: .init("r"))),
            fileBinding: binding, mode: .listen, title: "Saved title", lastPlayed: Date(timeIntervalSince1970: 10))
        let store = try SongPlaybackHistoryStore(url: url)
        expect(store.history.records.isEmpty, "missing song history starts empty")
        expect(!FileManager.default.fileExists(atPath: url.path), "loading never writes or restores playback")
        try store.record(record)
        let saved = try Data(contentsOf: url)
        let restored = try SongPlaybackHistoryStore(url: url)
        expect(restored.history.records == [record], "song history reload retains exact identities date mode and fingerprint")
        enum WriteFailure: Error { case denied }
        let failing = try SongPlaybackHistoryStore(url: url, write: { _, _ in throw WriteFailure.denied })
        do { try failing.record(record); expect(false, "write failure must throw") } catch {}
        expect(failing.history.records == [record], "failed save preserves valid in-memory song history")
        expect(try Data(contentsOf: url) == saved, "failed save preserves valid on-disk song history")
        let controller = SongPlaybackHistoryController(url: url)
        try Data("{broken".utf8).write(to: url)
        controller.reload()
        expect(controller.error != nil && controller.records == [record], "corrupt reload reports error and keeps last valid display")
        controller.record(record)
        expect(try Data(contentsOf: url) == Data("{broken".utf8), "failed load cannot overwrite corrupt song history")
        do { try restored.record(record); expect(false, "external changed history must refuse save") } catch {}
        try Data("{\"version\":99,\"records\":[]}".utf8).write(to: url)
        let unsupported = try Data(contentsOf: url)
        controller.reload(); controller.record(record)
        expect(controller.error != nil, "unsupported history version is actionable")
        expect(try Data(contentsOf: url) == unsupported, "unsupported history remains untouched")
        try saved.write(to: url)
        controller.reload()
        expect(controller.error == nil && controller.records == [record], "explicit retry loads repaired history")
        let brokenRecord = SongPlaybackRecord(target: record.target, mode: .listen, title: "Missing binding", lastPlayed: Date())
        var invalid = SongPlaybackHistory()
        invalid.record(brokenRecord)
        expect(invalid.records.isEmpty, "unbound local history is never admitted")

        let model = PerformanceBrowserModel()
        expect(model.songHistoryTitle(record) == "Saved title", "unavailable history has meaningful saved title")
        expect(model.songHistoryUnavailableReason(record) != nil, "missing local history is visibly unavailable")
        var catalog = LocalSongCatalog()
        let localRoot = LocalSongRoot(id: "root", displayPath: "/private/test", bookmark: Data([1]))
        catalog.roots = [localRoot]
        catalog.tracks = [LocalSongTrack(id: "track", number: 1, customTitle: "Current renamed song", rootID: "root", groupRelativePath: "", files: [LocalSongFile(id: "file", relativePath: "test.mp4", basename: "test.mp4",
                byteSize: 90, sha256: binding.sha256, fingerprintByteSize: 90)], selectedFileID: "file")]
        model.localCatalog = catalog
        expect(model.songHistoryTitle(record) == "Current renamed song", "history prefers current display name")
        expect(model.songHistoryUnavailableReason(record) == nil, "matching local history is replayable")
        model.songNavigation.installed(sessionID: "first", item: .init(record: record, queueEntry: nil))
        _ = model.songNavigation.received(.init(sessionID: "first", state: .playing), at: Date())
        let second = SongPlaybackRecord(target: .localFile(.init(trackID: "second", fileID: "other", catalogRevision: .init("r"))),
            fileBinding: binding, mode: .listen, title: "Second", lastPlayed: Date())
        model.songNavigation.installed(sessionID: "second", item: .init(record: second, queueEntry: nil))
        _ = model.songNavigation.received(.init(sessionID: "second", state: .playing), at: Date())
        model.sessionState.start(.init(id: "second", target: second.target, mode: .listen))
        expect(model.canPreviousSong, "available prior confirmed song enables previous")
        catalog.tracks[0].files[0].isPresent = false
        model.localCatalog = catalog
        expect(model.songHistoryUnavailableReason(record) != nil, "missing exact file cannot fall back to a sibling")
        expect(!model.canPreviousSong, "unavailable prior target disables previous without silent substitution")
        let queueEntry = model.queueEntry(for: record)
        expect(queueEntry.target == .localFile(trackID: "track", fileID: "file"), "history command captures exact file")
        model.songNavigation.reset()
        expect(!model.canPreviousSong, "new run cannot navigate persisted history implicitly")
    } catch {
        expect(false, "song-history regression threw \(error)")
    }
}
