// Real filesystem tests of the public save result. Every destination and failure fixture
// belongs to a unique temporary directory; no user preferences or media are read or changed.
import Foundation
import BSideCore
import BSidePlatform

private enum PreferencesSaveFixture {
    static func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bsidemac-prefs-save-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    static func preferences(in root: URL, volume: Double) -> AppPreferences {
        var desired = DesiredState()
        desired.masterVolume = volume
        var prefs = AppPreferences(desired: desired,
            assetPath: root.appendingPathComponent("synthetic-daily").path,
            onboardingCompleted: true)
        prefs.performanceRoot = root.appendingPathComponent("synthetic-music").path
        // Persistence treats bookmark bytes as opaque; these are deliberately not real grants.
        prefs.assetBookmark = Data([0x00, 0xFF, 0x2F, 0x80, 0x00])
        prefs.performanceBookmark = Data([0xFE, 0x00, 0x5C, 0x01, 0x7F])
        prefs.assetIdentity = .snapshot(DirectoryIdentitySnapshot(
            volumeUUID: "DAILY-VOLUME", inode: 111, persistentIDsSupported: true,
            provenance: .explicitSelection))
        prefs.performanceIdentity = .snapshot(DirectoryIdentitySnapshot(
            volumeUUID: "MUSIC-VOLUME", inode: 222, persistentIDsSupported: true,
            provenance: .legacyAdopted, capturedAt: Date(timeIntervalSince1970: 1_700_000_000)))
        return prefs
    }

    static func read(_ url: URL) throws -> AppPreferences {
        try JSONDecoder().decode(AppPreferences.self, from: Data(contentsOf: url))
    }

    /// An immutable existing file rejects atomic replacement even when its parent is writable.
    /// Unlike permission-bit tests this does not depend on the runner's effective UID.
    static func setImmutable(_ immutable: Bool, at url: URL) throws {
        try FileManager.default.setAttributes([.immutable: immutable], ofItemAtPath: url.path)
    }
}

func runPreferencesSaveTests() {
    run("Preferences.legacyPathsDecodeWithoutBookmarkFields") { t in
        do {
            let expected = PreferencesSaveFixture.preferences(in: URL(fileURLWithPath: "/synthetic-legacy"), volume: 0.41)
            var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(expected)) as! [String: Any]
            legacy.removeValue(forKey: "assetBookmark")
            legacy.removeValue(forKey: "performanceBookmark")
            legacy.removeValue(forKey: "assetIdentity")
            legacy.removeValue(forKey: "performanceIdentity")
            let decoded = try JSONDecoder().decode(AppPreferences.self,
                from: JSONSerialization.data(withJSONObject: legacy))
            t.expectEqual(decoded.desired, expected.desired, "old preference values survive decoding")
            t.expectEqual(decoded.assetPath, expected.assetPath, "old daily path remains available for migration")
            t.expectEqual(decoded.performanceRoot, expected.performanceRoot, "old performance path remains available for migration")
            t.expectEqual(decoded.onboardingCompleted, expected.onboardingCompleted, "old onboarding state is preserved")
            t.expect(decoded.assetBookmark == nil && decoded.performanceBookmark == nil,
                     "absent bookmark fields decode as nil without discarding old preferences")
            t.expectNil(decoded.assetIdentity, "absent daily identity decodes as nil, not as an unsupported record")
            t.expectNil(decoded.performanceIdentity, "absent performance identity decodes as nil")
        } catch {
            t.expect(false, "legacy preference decode failed: \(error)")
        }
    }

    run("Preferences.saveReturnsSuccessAndPersistsValues") { t in
        do {
            let root = try PreferencesSaveFixture.directory()
            defer { try? FileManager.default.removeItem(at: root) }
            let url = root.appendingPathComponent("preferences.json")
            let expected = PreferencesSaveFixture.preferences(in: root, volume: 0.23)

            try expected.save(to: url).get()
            let saved = try PreferencesSaveFixture.read(url)
            t.expectEqual(saved.desired, expected.desired, "saved desired state matches the caller")
            t.expectEqual(saved.assetPath, expected.assetPath, "daily root persists")
            t.expectEqual(saved.performanceRoot, expected.performanceRoot, "performance root persists")
            t.expectEqual(saved.assetBookmark, expected.assetBookmark, "daily opaque bookmark bytes persist exactly")
            t.expectEqual(saved.performanceBookmark, expected.performanceBookmark, "performance opaque bookmark bytes persist exactly")
            t.expectEqual(saved.assetIdentity, expected.assetIdentity, "daily identity snapshot persists exactly")
            t.expectEqual(saved.performanceIdentity, expected.performanceIdentity, "performance identity snapshot persists exactly")
            t.expectEqual(saved.onboardingCompleted, expected.onboardingCompleted, "onboarding state persists")
        } catch {
            t.expect(false, "unexpected save/read failure: \(error)")
        }
    }

    run("Preferences.saveAtomicallyReplacesExistingFile") { t in
        do {
            let root = try PreferencesSaveFixture.directory()
            defer { try? FileManager.default.removeItem(at: root) }
            let url = root.appendingPathComponent("preferences.json")
            let oldLink = root.appendingPathComponent("previous-inode.json")
            let original = PreferencesSaveFixture.preferences(in: root, volume: 0.1)
            try original.save(to: url).get()
            let originalBytes = try Data(contentsOf: url)
            try FileManager.default.linkItem(at: url, to: oldLink)

            var latest = original
            latest.desired.masterVolume = 0.72
            latest.desired.paused = true
            latest.assetPath = root.appendingPathComponent("replacement-daily").path
            latest.assetBookmark = Data([0xFF, 0x00, 0x11])
            latest.performanceRoot = root.appendingPathComponent("replacement-music").path
            latest.performanceBookmark = Data([0x00, 0xFE, 0x22])
            try latest.save(to: url).get()

            let saved = try PreferencesSaveFixture.read(url)
            t.expectEqual(saved.desired, latest.desired, "the destination contains the complete replacement")
            t.expectEqual(saved.assetPath, latest.assetPath, "replacement includes the latest daily path")
            t.expectEqual(saved.assetBookmark, latest.assetBookmark, "daily bookmark changes with its path")
            t.expectEqual(saved.performanceRoot, latest.performanceRoot, "replacement includes the latest performance path")
            t.expectEqual(saved.performanceBookmark, latest.performanceBookmark, "performance bookmark changes with its path")
            t.expectEqual(try Data(contentsOf: oldLink), originalBytes,
                          "the old inode stays intact; save did not truncate/write it in place")
        } catch {
            t.expect(false, "unexpected atomic replacement failure: \(error)")
        }
    }

    run("Preferences.saveIOFailurePreservesExistingFile") { t in
        do {
            let root = try PreferencesSaveFixture.directory()
            let url = root.appendingPathComponent("preferences.json")
            defer {
                try? PreferencesSaveFixture.setImmutable(false, at: url)
                try? FileManager.default.removeItem(at: root)
            }
            let original = PreferencesSaveFixture.preferences(in: root, volume: 0.11)
            try original.save(to: url).get()
            let originalBytes = try Data(contentsOf: url)
            try PreferencesSaveFixture.setImmutable(true, at: url)
            var changed = PreferencesSaveFixture.preferences(in: root, volume: 0.62)
            changed.assetPath = root.appendingPathComponent("unsaved-daily").path
            changed.assetBookmark = Data([0x03, 0x00, 0xFC])
            changed.performanceRoot = root.appendingPathComponent("unsaved-music").path
            changed.performanceBookmark = Data([0x04, 0xFD, 0x00])

            switch changed.save(to: url) {
            case .success:
                t.expect(false, "an immutable destination must return a write failure")
            case .failure(let error):
                t.expect(!(error is EncodingError), "the returned failure comes from filesystem IO")
            }
            t.expectEqual(try Data(contentsOf: url), originalBytes,
                          "failed replacement preserves both old path/bookmark pairs and all previous bytes")
        } catch {
            t.expect(false, "unexpected failure setting up the IO fault: \(error)")
        }
    }

    run("Preferences.saveEncodingFailurePreservesExistingFile") { t in
        do {
            let root = try PreferencesSaveFixture.directory()
            defer { try? FileManager.default.removeItem(at: root) }
            let url = root.appendingPathComponent("preferences.json")
            var prefs = PreferencesSaveFixture.preferences(in: root, volume: 0.17)
            try prefs.save(to: url).get()
            let originalBytes = try Data(contentsOf: url)
            prefs.desired.masterVolume = .nan

            switch prefs.save(to: url) {
            case .success:
                t.expect(false, "a non-finite volume must return the JSON encoding failure")
            case .failure(let error):
                if case EncodingError.invalidValue(_, let context) = error {
                    t.expect(context.codingPath.contains { $0.stringValue == "masterVolume" },
                             "the original encoder error retains the failed field")
                } else {
                    t.expect(false, "encoding failure was replaced by another error: \(error)")
                }
            }
            t.expectEqual(try Data(contentsOf: url), originalBytes,
                          "encoding failure does not touch the previous saved file")
        } catch {
            t.expect(false, "unexpected failure setting up the encoding fault: \(error)")
        }
    }

    run("Preferences.retryAfterIOFaultSavesLatestValues") { t in
        do {
            let root = try PreferencesSaveFixture.directory()
            let url = root.appendingPathComponent("preferences.json")
            defer {
                try? PreferencesSaveFixture.setImmutable(false, at: url)
                try? FileManager.default.removeItem(at: root)
            }
            var prefs = PreferencesSaveFixture.preferences(in: root, volume: 0.13)
            try prefs.save(to: url).get()
            try PreferencesSaveFixture.setImmutable(true, at: url)
            prefs.desired.masterVolume = 0.31
            if case .success = prefs.save(to: url) {
                t.expect(false, "the first changed value must encounter the injected IO fault")
            }

            try PreferencesSaveFixture.setImmutable(false, at: url)
            prefs.desired.masterVolume = 0.83
            prefs.desired.paused = true
            prefs.performanceRoot = root.appendingPathComponent("new-synthetic-music").path
            prefs.performanceBookmark = Data([0x00, 0x83, 0xFF])
            try prefs.save(to: url).get() // Explicit caller retry; save itself never schedules one.

            let saved = try PreferencesSaveFixture.read(url)
            t.expectEqual(saved.desired, prefs.desired, "retry saves the current state, not the failed snapshot")
            t.expectEqual(saved.performanceRoot, prefs.performanceRoot, "retry saves the current resource root")
            t.expectEqual(saved.performanceBookmark, prefs.performanceBookmark, "retry saves the current root's opaque bookmark")
            t.expectEqual(saved.assetBookmark, prefs.assetBookmark, "retry keeps the unchanged daily authorization")
        } catch {
            t.expect(false, "unexpected retry failure: \(error)")
        }
    }

    run("Preferences.malformedIdentityRecordPreservesEverything") { t in
        do {
            let root = try PreferencesSaveFixture.directory()
            defer { try? FileManager.default.removeItem(at: root) }
            let url = root.appendingPathComponent("preferences.json")
            let expected = PreferencesSaveFixture.preferences(in: root, volume: 0.44)
            var malformed = try JSONSerialization.jsonObject(with: JSONEncoder().encode(expected)) as! [String: Any]
            // An existing but unreadable/unsupported-version record: NOT an absent legacy record.
            malformed["assetIdentity"] = "__ASSET__"
            malformed["performanceIdentity"] = "__PERF__"
            var text = String(decoding: try JSONSerialization.data(withJSONObject: malformed), as: UTF8.self)
            // Unknown version, unknown provenance, additional fields, nested values and a > 2^53 integer.
            let assetRecord = #"{"version":999,"provenance":"future","inode":9007199254740993,"nested":{"a":[1,2,{"b":true}]},"note":"keep me"}"#
            let performanceRecord = #"{"unexpected":"shape","deep":[{"x":1},null]}"#
            text = text.replacingOccurrences(of: "\"__ASSET__\"", with: assetRecord)
            text = text.replacingOccurrences(of: "\"__PERF__\"", with: performanceRecord)
            try Data(text.utf8).write(to: url)

            let decoded = try JSONDecoder().decode(AppPreferences.self, from: Data(contentsOf: url))
            t.expectEqual(decoded.desired, expected.desired,
                          "a malformed identity field never resets unrelated desired state")
            t.expectEqual(decoded.assetPath, expected.assetPath, "the daily path survives a malformed identity record")
            t.expectEqual(decoded.assetBookmark, expected.assetBookmark, "the daily bookmark survives a malformed identity record")
            t.expectEqual(decoded.performanceRoot, expected.performanceRoot, "the music path survives")
            t.expectEqual(decoded.performanceBookmark, expected.performanceBookmark, "the music bookmark survives")
            guard let stored = decoded.assetIdentity, case .unsupported = stored else {
                t.expect(false, "an unsupported record is retained, not treated as absent or legacy")
                return
            }
            guard case .unsupported = decoded.performanceIdentity else {
                t.expect(false, "an unknown-shape record is retained as unsupported")
                return
            }

            // Never silently readopt over an existing record, and keep it across ordinary saves.
            let outcome = DirectoryIdentityResolver.resolve(
                stored: stored, bookmark: decoded.assetBookmark!,
                fresh: DirectoryIdentitySnapshot(volumeUUID: "DAILY-VOLUME", inode: 444,
                                                 persistentIDsSupported: true, provenance: .legacyAdopted))
            t.expectEqual(outcome.verdict, .unknown, "an unsupported record yields unknown, not a rebaseline")
            t.expectEqual(outcome.identity, stored, "an unsupported record is preserved unchanged")
            t.expect(!outcome.adoptAfterValidation, "an unsupported record never triggers automatic adoption")

            try decoded.save(to: url).get()
            let reread = try PreferencesSaveFixture.read(url)
            t.expectEqual(reread.assetIdentity, decoded.assetIdentity,
                          "opaque daily record contents survive a save/reload cycle")
            t.expectEqual(reread.performanceIdentity, decoded.performanceIdentity,
                          "opaque performance record contents survive a save/reload cycle")
            if case .unsupported(.object(let object))? = reread.assetIdentity {
                t.expectEqual(object["version"], .int(999), "unknown version survives verbatim")
                t.expectEqual(object["provenance"], .string("future"), "unknown provenance survives verbatim")
                t.expectEqual(object["note"], .string("keep me"), "additional fields survive verbatim")
                t.expectEqual(object["inode"], .int(9007199254740993),
                              "an integer above 2^53 survives without precision loss")
                t.expectEqual(object["nested"],
                              .object(["a": .array([.int(1), .int(2), .object(["b": .bool(true)])])]),
                              "nested values survive verbatim")
            } else {
                t.expect(false, "the retained record is an opaque JSON object")
            }
        } catch {
            t.expect(false, "malformed identity preference decode failed: \(error)")
        }
    }

    run("Preferences.freshDefaultsUseReviewedEveningNotAuto") { t in
        // The Core domain default is unchanged; only a NEW persisted app preference starts from
        // the reviewed A/R1 evening material as an explicit fixed choice.
        t.expectEqual(DesiredState().timeMode, .auto, "Core DesiredState keeps its automatic default")
        let fresh = AppPreferences()
        t.expectEqual(fresh.desired.timeMode, .fixed(.evening),
                      "a fresh AppPreferences starts on the reviewed fixed evening choice, not .auto")
        t.expectEqual(fresh.desired.scene, .a, "fresh scene is the reviewed A")
        t.expectEqual(fresh.desired.outfit, .r1, "fresh outfit is the reviewed R1")
        t.expectNil(fresh.assetPath, "a fresh preference still needs onboarding")
    }

    run("Preferences.savedAutomaticAndQueueLoadUnchanged") { t in
        do {
            let root = try PreferencesSaveFixture.directory()
            defer { try? FileManager.default.removeItem(at: root) }
            let url = root.appendingPathComponent("preferences.json")
            var desired = DesiredState()
            desired.timeMode = .auto
            desired.paused = true
            desired.masterVolume = 0.37
            desired.ambientVolume = 0.19
            var saved = AppPreferences(desired: desired,
                assetPath: root.appendingPathComponent("saved-daily").path,
                onboardingCompleted: true)
            var queue = PerformanceQueueConfiguration()
            queue.order = .shuffle
            queue.entries = [PerformanceQueueEntry(id: "saved-track",
                                                   performanceID: PerformanceID("performance://saved/1"),
                                                   presentation: .sidePerformance, mode: .listen)]
            saved.performanceQueue = queue
            try saved.save(to: url).get()

            let loaded = try PreferencesSaveFixture.read(url)
            t.expectEqual(loaded.desired.timeMode, .auto,
                          "an existing saved automatic choice is never rewritten by the new fresh default")
            t.expect(loaded.desired.paused && loaded.desired.masterVolume == 0.37
                     && loaded.desired.ambientVolume == 0.19,
                     "saved pause and volumes survive the new fresh default")
            t.expectEqual(loaded.performanceQueue, queue,
                          "the saved performance queue is restored unchanged")
        } catch {
            t.expect(false, "saved automatic/queue restore failed: \(error)")
        }
    }
}
