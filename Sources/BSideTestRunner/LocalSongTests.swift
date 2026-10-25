// BSideTestRunner — explicit local song additions (ADR-022): bounded scan grouping, stable
// numbers/ids, missing-file records, rename validation, corrupt-store preservation, single-file
// identity verification and typed Core targets. Tiny synthesized fixtures only; no media.
import Foundation
import CryptoKit
import BSideCore
import BSidePlatform

private func localFixtureRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("bside-local-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@discardableResult
private func writeLocalFile(_ url: URL, bytes: Int, fill: UInt8 = 7) throws -> URL {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: fill, count: bytes).write(to: url)
    return url
}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func runLocalSongTests() {
    run("LocalSongScanner.rootChildAndCategoryLayouts") { t in
        do {
            let root = try localFixtureRoot()
            defer { try? FileManager.default.removeItem(at: root) }

            // Root itself holds supported files → exactly one group for the selected root.
            try writeLocalFile(root.appendingPathComponent("b.mp4"), bytes: 4)
            try writeLocalFile(root.appendingPathComponent("a.mp4"), bytes: 4)
            let selfGroups = try LocalSongScanner.scan(root: root)
            t.expectEqual(selfGroups.count, 1, "a root with files is a single group")
            t.expectEqual(selfGroups.first?.relativePath, "", "the root group's relative path is empty")
            t.expectEqual(selfGroups.first?.files.map(\.basename), ["a.mp4", "b.mp4"],
                          "files are stably sorted by basename, not filesystem order")

            // Immediate children with files (no root files) → one group per child.
            let childRoot = try localFixtureRoot()
            defer { try? FileManager.default.removeItem(at: childRoot) }
            try writeLocalFile(childRoot.appendingPathComponent("workB/y.mp4"), bytes: 4)
            try writeLocalFile(childRoot.appendingPathComponent("workA/x.mp4"), bytes: 4)
            try writeLocalFile(childRoot.appendingPathComponent("empty/readme.txt"), bytes: 4)
            let childGroups = try LocalSongScanner.scan(root: childRoot)
            t.expectEqual(childGroups.map(\.relativePath), ["workA", "workB"],
                          "immediate work children become groups; an empty child is skipped")

            // category/work depth 2 (the known additional root layout).
            let categoryRoot = try localFixtureRoot()
            defer { try? FileManager.default.removeItem(at: categoryRoot) }
            try writeLocalFile(categoryRoot.appendingPathComponent("cat1/work1/a.mp4"), bytes: 4)
            try writeLocalFile(categoryRoot.appendingPathComponent("cat1/work1/b.mp4"), bytes: 4)
            try writeLocalFile(categoryRoot.appendingPathComponent("cat1/work2/c.mp4"), bytes: 4)
            try writeLocalFile(categoryRoot.appendingPathComponent("cat2/work3/d.mp4"), bytes: 4)
            let categoryGroups = try LocalSongScanner.scan(root: categoryRoot)
            t.expectEqual(categoryGroups.map(\.relativePath),
                          ["cat1/work1", "cat1/work2", "cat2/work3"],
                          "category/work depth 2 is scanned as one group per work folder")
            t.expectEqual(categoryGroups.first?.files.count, 2, "each group keeps its own files")
        } catch { t.expect(false, "local scan layout fixture failed: \(error)") }
    }

    run("LocalSongScanner.keepsSupportedFilesAndNeverGuessesByBasename") { t in
        do {
            let root = try localFixtureRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            try writeLocalFile(root.appendingPathComponent("work/0_1_1200.mp4"), bytes: 4)
            try writeLocalFile(root.appendingPathComponent("work/Untitled Clip.MP4"), bytes: 4)
            try writeLocalFile(root.appendingPathComponent("work/notes.txt"), bytes: 4)
            try writeLocalFile(root.appendingPathComponent("work/audio.mp3"), bytes: 4)
            let groups = try LocalSongScanner.scan(root: root)
            t.expectEqual(groups.count, 1, "the work folder remains one group")
            t.expectEqual(Set(groups.first?.files.map(\.basename) ?? []),
                          Set(["0_1_1200.mp4", "Untitled Clip.MP4"]),
                          "supported extensions match case-insensitively and a name alone never excludes")
        } catch { t.expect(false, "local extension fixture failed: \(error)") }
    }

    run("LocalSongScanner.neverFollowsSymlinksOutOfRoot") { t in
        do {
            let root = try localFixtureRoot()
            let outside = try localFixtureRoot()
            defer {
                try? FileManager.default.removeItem(at: root)
                try? FileManager.default.removeItem(at: outside)
            }
            try writeLocalFile(outside.appendingPathComponent("secret.mp4"), bytes: 8)
            try writeLocalFile(root.appendingPathComponent("work/local.mp4"), bytes: 8)
            // A symlinked directory and a symlinked file both point outside the authorized root.
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"),
                withDestinationURL: outside)
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("work/link.mp4"),
                withDestinationURL: outside.appendingPathComponent("secret.mp4"))
            let groups = try LocalSongScanner.scan(root: root)
            let names = groups.flatMap { $0.files.map(\.basename) }
            t.expectEqual(names, ["local.mp4"], "neither a symlinked directory nor a symlinked file escapes")
            t.expect(!groups.contains { $0.relativePath == "escape" }, "a symlinked directory is not a group")
        } catch { t.expect(false, "local symlink fixture failed: \(error)") }
    }

    run("LocalSongCatalog.stableNumbersIdsAndDuplicateFreeRescan") { t in
        do {
            let root = try localFixtureRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            try writeLocalFile(root.appendingPathComponent("cat/work1/a.mp4"), bytes: 4)
            try writeLocalFile(root.appendingPathComponent("cat/work1/b.mp4"), bytes: 4)
            try writeLocalFile(root.appendingPathComponent("cat/work2/c.mp4"), bytes: 4)
            var catalog = LocalSongCatalog()
            catalog.registerRoot(id: "root-1", displayPath: root.path, bookmark: nil, identity: nil)
            let groups = try LocalSongScanner.scan(root: root)
            let first = catalog.applyScan(rootID: "root-1", groups: groups)
            t.expectEqual(first.newTracks, 2, "two groups become two tracks")
            t.expectEqual(first.newFiles, 3, "three files become three file records")
            let numbers = catalog.tracks.map(\.number).sorted()
            t.expectEqual(numbers, [1, 2], "the first additions receive the next global numbers")
            t.expectEqual(catalog.tracks.first { $0.groupRelativePath == "cat/work1" }?.displayTitle,
                          "未命名曲目001", "the stable temporary title uses the allocated number")
            let ids = Dictionary(uniqueKeysWithValues: catalog.tracks.map { ($0.groupRelativePath, $0.id) })
            let fileIDs = Dictionary(uniqueKeysWithValues:
                catalog.tracks.flatMap { track in track.files.map { ($0.relativePath, $0.id) } })

            // A repeat scan must not duplicate or renumber anything.
            let beforeRepeat = catalog
            let second = catalog.applyScan(rootID: "root-1", groups: try LocalSongScanner.scan(root: root))
            t.expectEqual(catalog, beforeRepeat, "an unchanged scan preserves the complete catalog and revision")
            t.expectEqual(second.newTracks, 0, "a repeat scan creates no track")
            t.expectEqual(second.newFiles, 0, "a repeat scan creates no file")
            t.expectEqual(catalog.tracks.count, 2, "no duplicate group rows")
            t.expectEqual(catalog.tracks.flatMap { $0.files }.count, 3, "no duplicate file rows")
            for track in catalog.tracks {
                t.expectEqual(track.id, ids[track.groupRelativePath], "track identity survives a rescan")
                for file in track.files {
                    t.expectEqual(file.id, fileIDs[file.relativePath], "file identity survives a rescan")
                }
            }
            t.expectEqual(catalog.nextNumber, 3, "numbers are never reused or re-allocated")

            // A NEW group receives the next number; existing numbers never move.
            try writeLocalFile(root.appendingPathComponent("cat/work3/d.mp4"), bytes: 4)
            catalog.applyScan(rootID: "root-1", groups: try LocalSongScanner.scan(root: root))
            t.expectEqual(catalog.tracks.first { $0.groupRelativePath == "cat/work3" }?.number, 3,
                          "a later addition takes the next global number")
            t.expectEqual(catalog.tracks.first { $0.groupRelativePath == "cat/work1" }?.number, 1,
                          "existing numbers never move")
        } catch { t.expect(false, "local numbering fixture failed: \(error)") }
    }

    run("LocalSongCatalog.distinctFoldersAreNotMergedAndMissingFilesAreRetained") { t in
        do {
            let root = try localFixtureRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            // Same basename and same size in different folders: separate tracks, never merged.
            try writeLocalFile(root.appendingPathComponent("left/song.mp4"), bytes: 16)
            try writeLocalFile(root.appendingPathComponent("right/song.mp4"), bytes: 16)
            var catalog = LocalSongCatalog()
            catalog.registerRoot(id: "root-1", displayPath: root.path, bookmark: nil, identity: nil)
            catalog.applyScan(rootID: "root-1", groups: try LocalSongScanner.scan(root: root))
            t.expectEqual(catalog.tracks.count, 2, "similar folders stay distinct tracks")
            t.expect(Set(catalog.tracks.map(\.id)).count == 2, "each distinct folder gets its own identity")

            let selected = catalog.tracks.first { $0.groupRelativePath == "left" }
            t.expectNotNil(selected?.selectedFileID, "the first file is the explicit default selection")
            let selectedFileID = selected?.selectedFileID
            try FileManager.default.removeItem(at: root.appendingPathComponent("left/song.mp4"))
            let missing = catalog.applyScan(rootID: "root-1", groups: try LocalSongScanner.scan(root: root))
            t.expect(missing.missingFiles >= 1, "a removed file is reported missing")
            let retained = catalog.tracks.first { $0.groupRelativePath == "left" }
            t.expectEqual(retained?.id, selected?.id, "the missing track record is retained")
            t.expectEqual(retained?.files.first?.isPresent, false, "the file record is marked unavailable")
            t.expectEqual(retained?.selectedFileID, selectedFileID,
                          "a missing selected file is never silently replaced or rebased")
            t.expectEqual(retained?.isAvailable, false, "no present file means the track is unavailable")

            // Reappearance keeps the SAME ids and the same remembered selection.
            try writeLocalFile(root.appendingPathComponent("left/song.mp4"), bytes: 16)
            catalog.applyScan(rootID: "root-1", groups: try LocalSongScanner.scan(root: root))
            let restored = catalog.tracks.first { $0.groupRelativePath == "left" }
            t.expectEqual(restored?.id, selected?.id, "reappearance keeps the track identity")
            t.expectEqual(restored?.selectedFileID, selectedFileID, "reappearance keeps the remembered file")
            t.expectEqual(restored?.isAvailable, true, "reappearance restores availability")
        } catch { t.expect(false, "local missing-file fixture failed: \(error)") }
    }

    run("LocalSongCatalog.renameValidatesAndPreservesIdentity") { t in
        do {
            let root = try localFixtureRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            try writeLocalFile(root.appendingPathComponent("work/a.mp4"), bytes: 4)
            var catalog = LocalSongCatalog()
            catalog.registerRoot(id: "root-1", displayPath: root.path, bookmark: nil, identity: nil)
            catalog.applyScan(rootID: "root-1", groups: try LocalSongScanner.scan(root: root))
            let track = catalog.tracks[0]
            try catalog.rename(trackID: track.id, to: "  我的歌  ")
            t.expectEqual(catalog.tracks[0].displayTitle, "我的歌", "rename trims surrounding whitespace")
            t.expectEqual(catalog.tracks[0].id, track.id, "rename never changes the opaque id")
            t.expectEqual(catalog.tracks[0].number, track.number, "rename never changes the number")
            t.expectThrows("a whitespace-only rename is rejected") {
                try catalog.rename(trackID: track.id, to: "   ")
            }
            t.expectEqual(catalog.tracks[0].displayTitle, "我的歌", "a rejected rename leaves the title unchanged")
            t.expectThrows("an unknown track cannot be renamed") {
                try catalog.rename(trackID: "missing", to: "x")
            }
        } catch { t.expect(false, "local rename fixture failed: \(error)") }
    }

    run("LocalSongCatalog.selectionAndFingerprintNeverRebaseline") { t in
        do {
            let root = try localFixtureRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            try writeLocalFile(root.appendingPathComponent("work/b.mp4"), bytes: 8, fill: 1)
            try writeLocalFile(root.appendingPathComponent("work/a.mp4"), bytes: 8, fill: 2)
            var catalog = LocalSongCatalog()
            catalog.registerRoot(id: "root-1", displayPath: root.path, bookmark: nil, identity: nil)
            catalog.applyScan(rootID: "root-1", groups: try LocalSongScanner.scan(root: root))
            let track = catalog.tracks[0]
            t.expectEqual(track.sortedFiles.map(\.basename), ["a.mp4", "b.mp4"],
                          "neutral version order is the stable basename order")
            t.expectEqual(track.selectedFileID, track.sortedFiles.first?.id,
                          "the default selection is the first file in that order")
            let second = track.sortedFiles[1]
            try catalog.selectFile(trackID: track.id, fileID: second.id)
            t.expectEqual(catalog.tracks[0].selectedFileID, second.id, "an explicit selection is remembered")

            let digestA = sha256Hex(Data(repeating: 2, count: 8))
            try catalog.setFingerprint(trackID: track.id, fileID: track.sortedFiles[0].id,
                                       sha256: digestA, byteSize: 8)
            let revisionAfterFingerprint = catalog.revision
            // Confirming the same identity is idempotent.
            try catalog.setFingerprint(trackID: track.id, fileID: track.sortedFiles[0].id,
                                       sha256: digestA, byteSize: 8)
            t.expectEqual(catalog.revision, revisionAfterFingerprint, "a confirmed identity does not bump the revision")
            // A changed file is a typed failure, never a silent rebaseline.
            t.expectThrows("a changed file must not be silently rebaselined") {
                try catalog.setFingerprint(trackID: track.id, fileID: track.sortedFiles[0].id,
                                           sha256: sha256Hex(Data(repeating: 9, count: 8)), byteSize: 8)
            }
            t.expectEqual(catalog.tracks[0].sortedFiles[0].sha256, digestA,
                          "the prior identity survives a rejected rebaseline")
        } catch { t.expect(false, "local selection fixture failed: \(error)") }
    }

    run("LocalSongStore.atomicRoundTripAndPreservesUnreadableStore") { t in
        do {
            let dir = try localFixtureRoot()
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = LocalSongStore(url: dir.appendingPathComponent("local-songs.json"))
            t.expectEqual(store.load(), .empty, "a missing store is empty, not corrupt")

            var catalog = LocalSongCatalog()
            catalog.registerRoot(id: "root-1", displayPath: "/synthetic", bookmark: nil, identity: nil)
            catalog.applyScan(rootID: "root-1", groups: [LocalSongScannedGroup(relativePath: "work",
                files: [LocalSongScannedFile(relativePath: "work/a.mp4", basename: "a.mp4", byteSize: 4)])])
            // A rename and an explicit selection must survive a save/load (restart) unchanged.
            let track = catalog.tracks[0]
            let chosen = track.files[0]
            try catalog.rename(trackID: track.id, to: "重启后保留")
            try catalog.selectFile(trackID: track.id, fileID: chosen.id)
            let savedTitle = catalog.tracks[0].displayTitle
            try store.save(catalog)
            t.expectEqual(store.load(), .loaded(catalog), "a saved catalog round-trips exactly")
            guard case .loaded(let reloaded) = store.load() else { return }
            t.expectEqual(reloaded.tracks[0].displayTitle, savedTitle,
                          "a renamed title survives a restart")
            t.expectEqual(reloaded.tracks[0].id, track.id, "the opaque id survives a restart")
            t.expectEqual(reloaded.tracks[0].selectedFileID, chosen.id,
                          "the remembered file selection survives a restart")

            // Corrupt store: typed failure, original bytes preserved.
            let corruptURL = dir.appendingPathComponent("corrupt.json")
            let corruptBytes = Data("{not json".utf8)
            try corruptBytes.write(to: corruptURL)
            let corruptStore = LocalSongStore(url: corruptURL)
            if case .corrupt = corruptStore.load() {} else { t.expect(false, "corrupt store must be typed") }
            t.expectEqual(try Data(contentsOf: corruptURL), corruptBytes, "a corrupt store is never rewritten")

            // Unsupported version: typed failure, original bytes preserved.
            let unsupportedURL = dir.appendingPathComponent("unsupported.json")
            let unsupportedBytes = Data(#"{"version":99,"revision":1,"nextNumber":1,"roots":[],"tracks":[]}"#.utf8)
            try unsupportedBytes.write(to: unsupportedURL)
            let unsupportedStore = LocalSongStore(url: unsupportedURL)
            if case .unsupported = unsupportedStore.load() {} else {
                t.expect(false, "an unknown store version must be typed unsupported")
            }
            t.expectEqual(try Data(contentsOf: unsupportedURL), unsupportedBytes,
                          "an unsupported store is never overwritten")
        } catch { t.expect(false, "local store fixture failed: \(error)") }
    }

    run("LocalSongStore.v1MigrationPreservesEveryValueWithoutWriting") { t in
        do {
            let dir = try localFixtureRoot()
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = LocalSongStore(url: dir.appendingPathComponent("v1.json"))
            let bytes = Data(#"{"version":1,"revision":42,"nextNumber":10,"roots":[{"id":"root-legacy","displayPath":"/synthetic/legacy","bookmark":"AQID","isMissing":true}],"tracks":[{"id":"track-legacy","number":9,"customTitle":"Retained title","rootID":"root-legacy","groupRelativePath":"work","files":[{"id":"file-legacy","relativePath":"work/a.mp4","basename":"a.mp4","byteSize":8,"sha256":"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff","fingerprintByteSize":8,"isPresent":false}],"selectedFileID":"file-legacy","isAvailable":false}]}"#.utf8)
            try bytes.write(to: store.url)
            let expected = LocalSongCatalog(revision: 42, nextNumber: 10,
                roots: [LocalSongRoot(id: "root-legacy", displayPath: "/synthetic/legacy",
                                     bookmark: Data([1, 2, 3]), isMissing: true)],
                tracks: [LocalSongTrack(id: "track-legacy", number: 9, customTitle: "Retained title",
                    rootID: "root-legacy", groupRelativePath: "work",
                    files: [LocalSongFile(id: "file-legacy", relativePath: "work/a.mp4", basename: "a.mp4",
                        byteSize: 8, sha256: String(repeating: "f", count: 64), fingerprintByteSize: 8,
                        isPresent: false)], selectedFileID: "file-legacy", isAvailable: false)])
            t.expectEqual(store.load(), .loaded(expected),
                          "v1 migration changes only the schema version; every existing value survives")
            t.expectEqual(try Data(contentsOf: store.url), bytes, "loading v1 never eagerly rewrites its bytes")
            try store.save(expected)
            let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as? [String: Any]
            t.expectEqual(saved?["version"] as? Int, 2, "the next ordinary save writes explicit schema v2")
            t.expectEqual(store.load(), .loaded(expected), "the migrated catalog remains identical after saving")
        } catch { t.expect(false, "v1 migration fixture failed: \(error)") }
    }

    run("LocalSongCatalog.classificationRoundTripRescanAndRename") { t in
        do {
            let dir = try localFixtureRoot()
            defer { try? FileManager.default.removeItem(at: dir) }
            var catalog = LocalSongCatalog()
            catalog.registerRoot(id: "r1", displayPath: "/synthetic", bookmark: Data([7]), identity: nil)
            let groups = [LocalSongScannedGroup(relativePath: "work", files: [
                LocalSongScannedFile(relativePath: "work/a.mp4", basename: "a.mp4", byteSize: 4)])]
            catalog.applyScan(rootID: "r1", groups: groups)
            let original = catalog.tracks[0]
            let automatic = LocalSongClassification(category: .piano, style: .gentle, origin: .automatic,
                analyzedFileID: original.files[0].id, modelID: "local-test-model", modelRevision: "revision-1")
            try catalog.setClassification(trackID: original.id, classification: automatic)
            var expected = original
            expected.classification = automatic
            t.expectEqual(catalog.tracks[0], expected,
                          "classification alone changes no track identity, title, root, files or selection")
            let store = LocalSongStore(url: dir.appendingPathComponent("v2.json"))
            try store.save(catalog)
            t.expectEqual(store.load(), .loaded(catalog), "automatic classification and provenance round-trip in v2")
            try catalog.rename(trackID: original.id, to: "A retained name")
            catalog.applyScan(rootID: "r1", groups: [])
            catalog.applyScan(rootID: "r1", groups: groups)
            t.expectEqual(catalog.tracks[0].classification, automatic,
                          "classification survives a rename, disappearance and successful rescan")
            t.expectEqual(catalog.tracks[0].selectedFileID, original.selectedFileID,
                          "classification and rescan preserve the remembered file")
            let manual = LocalSongClassification(category: .instrumental, style: .unclassified, origin: .manual)
            try catalog.setClassification(trackID: original.id, classification: manual)
            try store.save(catalog)
            t.expectEqual(store.load(), .loaded(catalog), "manual correction round-trips with explicit uncertainty")
            t.expectThrows("classification cannot invent an unknown track") {
                try catalog.setClassification(trackID: "unknown", classification: manual)
            }
        } catch { t.expect(false, "classification persistence fixture failed: \(error)") }
    }

    run("LocalSongStore.malformedClassificationFailsClosed") { t in
        do {
            let dir = try localFixtureRoot()
            defer { try? FileManager.default.removeItem(at: dir) }
            var catalog = LocalSongCatalog()
            catalog.registerRoot(id: "r1", displayPath: "/synthetic", bookmark: nil, identity: nil)
            catalog.applyScan(rootID: "r1", groups: [LocalSongScannedGroup(relativePath: "", files: [])])
            let valid: [String: Any] = ["category": "piano", "style": "gentle", "origin": "automatic"]
            var cases: [[String: Any]] = []
            for (key, value) in [("category", "classical"), ("style", "game"), ("origin", "guessed")] {
                var invalid = valid
                invalid[key] = value
                cases.append(invalid)
            }
            var missing = valid
            missing.removeValue(forKey: "style")
            cases.append(missing)
            var wrongType = valid
            wrongType["modelRevision"] = 123
            cases.append(wrongType)
            let base = try JSONSerialization.jsonObject(with: JSONEncoder().encode(catalog)) as! [String: Any]
            for (index, classification) in cases.enumerated() {
                var object = base
                var tracks = object["tracks"] as! [[String: Any]]
                tracks[0]["classification"] = classification
                object["tracks"] = tracks
                let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
                let store = LocalSongStore(url: dir.appendingPathComponent("invalid-\(index).json"))
                try bytes.write(to: store.url)
                if case .corrupt = store.load() {} else {
                    t.expect(false, "unknown, incomplete or malformed classification must be refused")
                }
                t.expectEqual(try Data(contentsOf: store.url), bytes, "refused classification never rewrites the store")
            }
            // A v1 writer could not author classification. Do not silently discard such a payload.
            var inconsistent = base
            inconsistent["version"] = 1
            var tracks = inconsistent["tracks"] as! [[String: Any]]
            tracks[0]["classification"] = valid
            inconsistent["tracks"] = tracks
            let store = LocalSongStore(url: dir.appendingPathComponent("inconsistent-v1.json"))
            let bytes = try JSONSerialization.data(withJSONObject: inconsistent)
            try bytes.write(to: store.url)
            if case .corrupt = store.load() {} else { t.expect(false, "a classified v1 document is inconsistent") }
            t.expectEqual(try Data(contentsOf: store.url), bytes, "inconsistent v1 data is preserved")
        } catch { t.expect(false, "malformed classification fixture failed: \(error)") }
    }

    run("LocalSongStore.saveFailureIsTypedAndUnsupportedIdentityPreserved") { t in
        do {
            let dir = try localFixtureRoot()
            defer { try? FileManager.default.removeItem(at: dir) }
            // The store path's parent is a regular file, so the atomic save must fail typed.
            let blocked = dir.appendingPathComponent("blocked")
            try Data(repeating: 1, count: 4).write(to: blocked)
            let failingStore = LocalSongStore(url: blocked.appendingPathComponent("local-songs.json"))
            t.expectThrows("an unwritable store path surfaces a typed save failure") {
                try failingStore.save(LocalSongCatalog())
            }

            // An unreadable identity record survives a catalog save/load without being reinterpreted.
            let store = LocalSongStore(url: dir.appendingPathComponent("local-songs.json"))
            var catalog = LocalSongCatalog()
            catalog.registerRoot(id: "root-1", displayPath: "/synthetic", bookmark: nil,
                                 identity: .unsupported(.object(["version": .int(99)])))
            try store.save(catalog)
            guard case .loaded(let loaded) = store.load(),
                  case .unsupported = loaded.roots.first?.identity else {
                t.expect(false, "an unsupported identity record must be preserved verbatim")
                return
            }
            t.expectNotNil(DirectoryIdentityStatus.describe(loaded.roots.first?.identity, fresh: nil),
                           "an unreadable identity is surfaced as unverified, never silently adopted")
        } catch { t.expect(false, "local store failure fixture failed: \(error)") }
    }

    run("LocalSongStore.structuralInvariantsRejectCorruptCatalog") { t in
        do {
            let dir = try localFixtureRoot()
            defer { try? FileManager.default.removeItem(at: dir) }
            // Syntactically valid JSON that violates structural invariants must be treated as
            // corrupt and preserved rather than trusted or rewritten.
            let cases: [(String, String)] = [
                ("nextNumberNotAboveMax",
                 #"{"version":1,"revision":1,"nextNumber":1,"roots":[{"id":"r1","displayPath":"/x","isMissing":false}],"tracks":[{"id":"t1","number":1,"rootID":"r1","groupRelativePath":"","files":[],"isAvailable":true}]}"#),
                ("duplicateTrackNumber",
                 #"{"version":1,"revision":1,"nextNumber":3,"roots":[{"id":"r1","displayPath":"/x","isMissing":false}],"tracks":[{"id":"t1","number":1,"rootID":"r1","groupRelativePath":"","files":[],"isAvailable":true},{"id":"t2","number":1,"rootID":"r1","groupRelativePath":"g","files":[],"isAvailable":true}]}"#),
                ("unknownSelectedFile",
                 #"{"version":1,"revision":1,"nextNumber":2,"roots":[{"id":"r1","displayPath":"/x","isMissing":false}],"tracks":[{"id":"t1","number":1,"rootID":"r1","groupRelativePath":"","files":[],"selectedFileID":"nope","isAvailable":true}]}"#),
                ("incompleteFingerprintPair",
                 #"{"version":1,"revision":1,"nextNumber":2,"roots":[{"id":"r1","displayPath":"/x","isMissing":false}],"tracks":[{"id":"t1","number":1,"rootID":"r1","groupRelativePath":"","files":[{"id":"f1","relativePath":"a.mp4","basename":"a.mp4","sha256":"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff","isPresent":true}],"isAvailable":true}]}"#),
                ("invalidRelativePath",
                 #"{"version":1,"revision":1,"nextNumber":2,"roots":[{"id":"r1","displayPath":"/x","isMissing":false}],"tracks":[{"id":"t1","number":1,"rootID":"r1","groupRelativePath":"","files":[{"id":"f1","relativePath":"../escape.mp4","basename":"escape.mp4","isPresent":true}],"isAvailable":true}]}"#),
            ]
            for (name, json) in cases {
                let url = dir.appendingPathComponent("\(name).json")
                let bytes = Data(json.utf8)
                try bytes.write(to: url)
                let loaded = LocalSongStore(url: url).load()
                if case .corrupt = loaded {} else {
                    t.expect(false, "\(name): structurally invalid catalog must load as corrupt")
                }
                t.expectEqual(try Data(contentsOf: url), bytes,
                              "\(name): a structurally invalid store is never overwritten")
            }
        } catch { t.expect(false, "structural invariant fixture failed: \(error)") }
    }

    run("LocalSongScanner.exactOfficialLocationsExcludedWithoutBasenameGuessing") { t in
        do {
            guard let library = try? PerformanceLibrary.bundled() else {
                t.expect(false, "the bundled library must load for the official location fixture")
                return
            }
            t.expectEqual(library.manifest.tracks.count, 129, "the 129 official rows stay untouched")
            let variants = library.manifest.tracks.flatMap { $0.variants }
            t.expectEqual(variants.count, 480, "the bundled official variants stay untouched")
            guard let variant = variants.first else {
                t.expect(false, "the fixture needs one official variant")
                return
            }
            let fixture = try localFixtureRoot()
            defer { try? FileManager.default.removeItem(at: fixture) }
            let officialRoot = fixture.appendingPathComponent("official", isDirectory: true)
            let userRoot = fixture.appendingPathComponent("user", isDirectory: true)
            // The exact reviewed file at its exact contained location inside the accepted source.
            let officialFile = officialRoot.appendingPathComponent(variant.relativePath)
            try FileManager.default.createDirectory(at: officialFile.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data().write(to: officialFile)
            // An unrelated user folder holding a file with the SAME basename.
            let officialName = (variant.relativePath as NSString).lastPathComponent
            try FileManager.default.createDirectory(at: userRoot, withIntermediateDirectories: true)
            try writeLocalFile(userRoot.appendingPathComponent(officialName), bytes: 4)

            let source = LocalSongOfficialSource.from(library, root: officialRoot)
            let officialGroups = try LocalSongScanner.scan(root: officialRoot, officialSource: source)
            t.expectEqual(officialGroups.flatMap { $0.files.map(\.basename) }, [],
                          "the exact reviewed official file at its official location is excluded")
            let userGroups = try LocalSongScanner.scan(root: userRoot, officialSource: source)
            t.expectEqual(userGroups.flatMap { $0.files.map(\.basename) }, [officialName],
                          "a same-named file outside the official source is preserved")
            let noBinding = try LocalSongScanner.scan(root: officialRoot)
            t.expectEqual(noBinding.flatMap { $0.files.map(\.basename) }, [officialName],
                          "with no accepted official binding nothing is guessed away by name")
        } catch { t.expect(false, "official location fixture failed: \(error)") }
    }

    run("LocalSongPlaybackTarget.queueAdvancesLocalEntryOnEOF") { t in
        let first = PerformanceQueueEntry(id: "l1", trackID: "track-1", fileID: "file-1", mode: .listen)
        let second = PerformanceQueueEntry(id: "l2", trackID: "track-2", fileID: "file-2", mode: .watch)
        var state = PerformanceQueueState(configuration: PerformanceQueueConfiguration(entries: [first, second]))
        t.expectEqual(state.begin(chooseIndex: { _ in 0 }), first, "the first local entry starts")
        t.expect(state.bind(sessionID: "local-session-1"), "the local session binds")
        t.expectEqual(state.received(PerformanceReport(sessionID: "local-session-1", state: .ended),
                                     chooseIndex: { _ in 0 }),
                      .play(second),
                      "a natural EOF advances to the next local entry through the existing queue policy")
        t.expectEqual(state.activeEntry?.target.localSelection?.fileID, "file-2",
                      "the advanced entry keeps its own captured file")
        t.expectEqual(state.activeEntry?.mode, .watch, "the advanced entry keeps its own mode")
    }

    run("LocalFileVerifier.identityTraversalAndChangedFile") { t in
        do {
            let root = try localFixtureRoot()
            let outside = try localFixtureRoot()
            defer {
                try? FileManager.default.removeItem(at: root)
                try? FileManager.default.removeItem(at: outside)
            }
            let content = Data(repeating: 3, count: 128)
            try writeLocalFile(root.appendingPathComponent("work/song.mp4"), bytes: 128, fill: 3)
            let digest = sha256Hex(content)
            let binding = PerformanceFileBinding(relativePath: "work/song.mp4", byteSize: 128, sha256: digest)
            let resolved = try LocalFileVerifier.resolveAndVerify(binding: binding, root: root)
            t.expect(resolved.lastPathComponent == "song.mp4", "the exact selected file resolves")

            // Traversal and absolute paths are refused before any read.
            t.expectThrows("a parent traversal is refused") {
                _ = try LocalFileVerifier.validatedRelativePath("../secret.mp4")
            }
            t.expectThrows("an absolute path is refused") {
                _ = try LocalFileVerifier.validatedRelativePath("/etc/passwd")
            }
            t.expectThrows("an empty component is refused") {
                _ = try LocalFileVerifier.validatedRelativePath("work//song.mp4")
            }
            t.expectThrows("a NUL byte is refused") {
                _ = try LocalFileVerifier.validatedRelativePath("work/song\0.mp4")
            }
            t.expectThrows("a symlink escape is refused") {
                try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("work/link.mp4"),
                    withDestinationURL: outside.appendingPathComponent("secret.mp4"))
                _ = try LocalFileVerifier.resolveAndVerify(
                    binding: PerformanceFileBinding(relativePath: "work/link.mp4", byteSize: 8,
                                                    sha256: sha256Hex(Data(repeating: 5, count: 8))),
                    root: root)
            }
            // Wrong digest / wrong size are typed changed-file failures.
            t.expectThrows("a wrong digest is a changed file") {
                _ = try LocalFileVerifier.resolveAndVerify(
                    binding: PerformanceFileBinding(relativePath: "work/song.mp4", byteSize: 128,
                                                    sha256: sha256Hex(Data(repeating: 4, count: 128))),
                    root: root)
            }
            t.expectThrows("a wrong size is a changed file") {
                _ = try LocalFileVerifier.resolveAndVerify(
                    binding: PerformanceFileBinding(relativePath: "work/song.mp4", byteSize: 64, sha256: digest),
                    root: root)
            }
            t.expectThrows("a malformed digest is refused") {
                _ = try LocalFileVerifier.resolveAndVerify(
                    binding: PerformanceFileBinding(relativePath: "work/song.mp4", byteSize: 128, sha256: "ABC"),
                    root: root)
            }
        } catch { t.expect(false, "local verifier fixture failed: \(error)") }
    }

    run("LocalSongPlaybackTarget.sessionLegacyAndTypedCoding") { t in
        let variant = ResolvedPerformanceVariant(
            performanceID: PerformanceID("olivia.performance.solo.fixture"),
            variantID: PerformanceVariantID("olivia.performance.solo.fixture.variant.noon"),
            lighting: .daylight, presentation: .sidePerformance,
            catalogRevision: PerformanceCatalogRevision("rev-1"), reason: .automaticPolicy)
        let reference = LocalPerformanceReference(trackID: "local.track.1", fileID: "local.file.2",
                                                  catalogRevision: PerformanceCatalogRevision("local.1.4"))
        t.expect(reference.isUsable, "a fully-populated local reference is usable")
        t.expect(!LocalPerformanceReference(trackID: " ", fileID: "b",
            catalogRevision: PerformanceCatalogRevision("r")).isUsable, "a blank track id is unusable")
        t.expect(!LocalPerformanceReference(trackID: "a", fileID: "",
            catalogRevision: PerformanceCatalogRevision("r")).isUsable, "a blank file id is unusable")

        // New sessions write the unambiguous typed target and never the legacy `variant` key.
        let official = PerformanceSession(id: "s-official", variant: variant, mode: .watch)
        let local = PerformanceSession(id: "s-local", target: .localFile(reference), mode: .listen)
        for session in [official, local] {
            guard let data = try? JSONEncoder().encode(session),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                t.expect(false, "session encode failed")
                return
            }
            t.expectNotNil(json["target"], "new sessions encode a typed target")
            t.expectNil(json["variant"], "the legacy variant key is never produced")
        }
        t.expectEqual(official.target.officialVariant, variant, "official convenience keeps the resolved variant")
        t.expectEqual(local.target.localReference, reference, "local target keeps the opaque reference")
        t.expectNil(local.variant, "a local session reports no official variant instead of a fabricated one")

        // Legacy official-only JSON (an embedded `variant`) still decodes to the catalog case.
        guard let variantData = try? JSONEncoder().encode(variant),
              let variantJSON = String(data: variantData, encoding: .utf8) else {
            t.expect(false, "variant encode failed")
            return
        }
        let legacyJSON = #"{"id":"s-legacy","variant":\#(variantJSON),"mode":"listen","paused":true,"continuesQueue":true}"#
        guard let legacy = try? JSONDecoder().decode(PerformanceSession.self, from: Data(legacyJSON.utf8)) else {
            t.expect(false, "legacy official session payload must still decode")
            return
        }
        t.expectEqual(legacy.target.officialVariant, variant, "legacy variant becomes the catalog target")
        t.expectEqual(legacy.mode, .listen, "legacy mode survives")
        t.expect(legacy.paused && legacy.continuesQueue, "legacy pause/queue intent survives")

        // Round-trip both typed cases.
        for session in [official, local] {
            guard let data = try? JSONEncoder().encode(session),
                  let decoded = try? JSONDecoder().decode(PerformanceSession.self, from: data) else {
                t.expect(false, "typed session round trip failed")
                return
            }
            t.expectEqual(decoded, session, "typed target round-trips exactly")
        }
    }

    run("LocalSongPlaybackTarget.queueMixedRoundTripAndLegacyDecode") { t in
        let official = PerformanceQueueEntry(id: "q-official", performanceID: PerformanceID("p1"),
                                             presentation: .portraitPerformance, mode: .watch)
        let local = PerformanceQueueEntry(id: "q-local", trackID: "local.track.1", fileID: "local.file.9",
                                          mode: .listen)
        let configuration = PerformanceQueueConfiguration(entries: [official, local], order: .repeatAll)
        guard let data = try? JSONEncoder().encode(configuration),
              let decoded = try? JSONDecoder().decode(PerformanceQueueConfiguration.self, from: data) else {
            t.expect(false, "mixed queue round trip failed")
            return
        }
        t.expectEqual(decoded, configuration, "official + local entries round-trip together")
        t.expectEqual(decoded.entries[1].target.localSelection?.fileID, "local.file.9",
                      "a local entry captures the exact selected file")
        t.expectEqual(decoded.entries[1].performanceID, nil, "a local entry has no official performance id")

        // A legacy official-only row still decodes; a new row's keys are typed only.
        let legacyJSON = #"{"entries":[{"id":"legacy","performanceID":"p1","presentation":"sidePerformance","mode":"watch"}],"order":"stopAfterQueue"}"#
        let legacy = try? JSONDecoder().decode(PerformanceQueueConfiguration.self, from: Data(legacyJSON.utf8))
        t.expectEqual(legacy?.entries.first?.target.officialSelection?.presentation, .sidePerformance,
                      "the legacy flat shape decodes to the official target")
        let entryJSON = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let entries = entryJSON?["entries"] as? [[String: Any]]
        let firstKeys: Set<String> = (entries?.first).map { Set($0.keys) } ?? []
        t.expectEqual(firstKeys, Set(["id", "target", "mode"]),
                      "new queue rows persist only the typed target")
    }

    run("LocalSongPlaybackTarget.startRequestAdmissionAndIPC") { t in
        let reference = LocalPerformanceReference(trackID: "local.track.1", fileID: "local.file.2",
                                                  catalogRevision: PerformanceCatalogRevision("local.1.4"))
        let binding = PerformanceFileBinding(relativePath: "work/a.mp4", byteSize: 4,
                                             sha256: sha256Hex(Data(repeating: 7, count: 4)))
        let localSession = PerformanceSession(id: "s-local", target: .localFile(reference), mode: .listen)
        // A local request requires BOTH its per-file binding and a transferred directory grant.
        let localRequest = PerformanceStartRequest(session: localSession, mediaRoot: "/synthetic/root",
                                                   accessBookmark: Data([9, 9, 9]), fileBinding: binding)
        t.expectNil(localRequest.admissionIssue, "a local target with a binding and grant is admitted")

        let missingBinding = PerformanceStartRequest(session: localSession, mediaRoot: "/synthetic/root",
                                                     accessBookmark: Data([9, 9, 9]))
        t.expectEqual(missingBinding.admissionIssue, .localRequiresBinding,
                      "a local target REQUIRES a per-file binding")

        let missingGrant = PerformanceStartRequest(session: localSession, mediaRoot: "/synthetic/root",
                                                   fileBinding: binding)
        t.expectEqual(missingGrant.admissionIssue, .localRequiresGrant,
                      "a local target REQUIRES a transferred directory grant, never a saved path")

        let variant = ResolvedPerformanceVariant(
            performanceID: PerformanceID("p1"), variantID: PerformanceVariantID("p1.variant.noon"),
            lighting: .daylight, presentation: .sidePerformance,
            catalogRevision: PerformanceCatalogRevision("rev"), reason: .automaticPolicy)
        let officialSession = PerformanceSession(id: "s-official", variant: variant, mode: .watch)
        let officialWithBinding = PerformanceStartRequest(session: officialSession, mediaRoot: "/synthetic/root",
                                                          fileBinding: binding)
        t.expectEqual(officialWithBinding.admissionIssue, .officialRejectsBinding,
                      "an official target must reject an extraneous local binding")
        t.expectNil(PerformanceStartRequest(session: officialSession, mediaRoot: "/synthetic/root").admissionIssue,
                    "an ordinary official request stays admitted")

        // IPC round trip: the binding travels with the start request and decodes identically.
        guard let line = IPCCoding.encodeLine(IPCEnvelope(payload: AgentCommand.startPerformance(localRequest))),
              let decoded = IPCCoding.decodeLine(line, as: AgentCommand.self) else {
            t.expect(false, "local start request must encode and decode over IPC")
            return
        }
        t.expectEqual(decoded.payload, .startPerformance(localRequest), "binding survives the wire")
        guard case .startPerformance(let roundTripped) = decoded.payload else {
            t.expect(false, "decoded command must be a start request")
            return
        }
        t.expectEqual(roundTripped.fileBinding, binding, "the exact binding is preserved")
    }

    run("LocalSongPlaybackTarget.listenWatchAndPolicy") { t in
        let reference = LocalPerformanceReference(trackID: "local.track.1", fileID: "local.file.2",
                                                  catalogRevision: PerformanceCatalogRevision("local.1.4"))
        let session = PerformanceSession(id: "s-local", target: .localFile(reference), mode: .listen)
        let policy = PlaybackPolicy.evaluate(desired: DesiredState(), context: RuntimeContext(),
                                             performance: session)
        t.expectEqual(session.mode, .listen, "a local listen session keeps its explicit mode")
        t.expect(policy.musicVolume > 0, "listen mode keeps the music channel audible")
        var paused = session
        paused.paused = true
        let pausedPolicy = PlaybackPolicy.evaluate(desired: DesiredState(), context: RuntimeContext(),
                                                   performance: paused)
        t.expect(pausedPolicy.musicVolume == 0, "a paused local session mutes the music channel")
        // No official variant is fabricated for either mode.
        t.expectNil(session.variant, "a local session never fabricates a lighting/camera cell")
    }
}
