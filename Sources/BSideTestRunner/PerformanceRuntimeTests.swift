import Foundation
import Darwin
import BSideCore
import BSidePlatform

private func performanceManifestFixture(full: Data, body: Data? = nil, fullSHA256: String? = nil) throws -> [String: Any] {
    let portable = try PerformanceLibrary.bundled()
    var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(portable.manifest)) as! [String: Any]
    var first = (json["tracks"] as! [[String: Any]])[0]
    var variants = first["variants"] as! [[String: Any]]
    let fullHash = fullSHA256 ?? PerformanceSemanticCatalogJoin.sha256Hex(of: full)
    let bodyHash = body.map { PerformanceSemanticCatalogJoin.sha256Hex(of: $0) }
    for index in variants.indices {
        variants[index]["byteSize"] = full.count
        variants[index]["sha256"] = fullHash
        variants[index].removeValue(forKey: "mediaByteSize")
        variants[index].removeValue(forKey: "mediaSHA256")
        if let body {
            variants[index]["mediaByteSize"] = body.count
            variants[index]["mediaSHA256"] = bodyHash
        }
    }
    first["variants"] = variants
    json["tracks"] = [first]
    return json
}

private func performanceFixtureSelection(_ library: PerformanceLibrary) throws -> ResolvedPerformanceVariant {
    let track = library.manifest.tracks[0]
    let record = track.variants[0]
    guard case .resolved(let selected) = VariantResolver.resolve(trackID: PerformanceID(track.id), in: library.snapshot,
        effectiveLighting: record.lighting, presentationPreference: .explicit(record.presentation)) else {
        throw PerformanceAssetError.invalidManifest("synthetic fixture did not resolve")
    }
    return selected
}

private func performanceCandidateFixture(in root: URL, data: Data) throws
    -> (library: PerformanceLibrary, variant: PerformanceManifest.Variant, file: URL) {
    let library = try PerformanceLibrary(data: JSONSerialization.data(withJSONObject: performanceManifestFixture(full: data)))
    let variant = library.manifest.tracks[0].variants[0]
    let file = root.appendingPathComponent(variant.relativePath)
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: file)
    return (library, variant, file)
}

private func performancePhysicalURL(_ url: URL) throws -> URL {
    try url.withUnsafeFileSystemRepresentation { path in
        guard let path, let resolved = realpath(path, nil) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { free(resolved) }
        return URL(fileURLWithFileSystemRepresentation: resolved, isDirectory: false, relativeTo: nil)
    }
}

private let performanceUIDTrailer = Data("__UID_TAG__".utf8) + Data(repeating: 0, count: 5)
    + Data("123456".utf8) + Data([6, 0, 0, 0])

func runPerformanceRuntimeTests() {
    run("PerformanceRuntime.portableManifestAndResolution") { t in
        do {
            let library = try PerformanceLibrary.bundled()
            t.expectEqual(library.manifest.tracks.count, 129, "portable tracks")
            t.expectEqual(library.manifest.tracks.flatMap(\.variants).count, 480, "portable variants")
            t.expectEqual(library.manifest.exclusions.count, 3, "explicit unsupported tracks")
            for track in library.manifest.tracks {
                for variant in track.variants {
                    let result = VariantResolver.resolve(trackID: PerformanceID(track.id), in: library.snapshot,
                        effectiveLighting: variant.lighting, presentationPreference: .explicit(variant.presentation))
                    guard case .resolved(let resolved) = result else { t.expect(false, "every admitted cell resolves"); continue }
                    t.expectEqual(try library.record(for: resolved).id, variant.id, "exact binding")
                    t.expect(!variant.relativePath.hasPrefix("/"), "no absolute media reference")
                }
            }
        } catch { t.expect(false, "\(error)") }
    }
    // The bundled manifest decode is reused across song changes. That reuse must keep the exact
    // validated value (same revision, same admitted cells), stay safe under concurrent first use,
    // and never bypass the layout/size/SHA-256 checks that run per media file.
    run("PerformanceRuntime.bundledManifestReuseStaysValidatedAndNeverSkipsMediaChecks") { t in
        do {
            let first = try PerformanceLibrary.bundled()
            let second = try PerformanceLibrary.bundled()
            t.expectEqual(first.snapshot.revision, second.snapshot.revision,
                          "reuse keeps the exact validated catalog revision")
            t.expectEqual(second.manifest.tracks.count, 129, "reuse keeps the validated track set")
            t.expectEqual(second.manifest.tracks.flatMap(\.variants).count, 480,
                          "reuse keeps every admitted variant")

            // Concurrent first use must never publish a partial or unvalidated value.
            let lock = NSLock()
            var concurrent: [Int] = []
            DispatchQueue.concurrentPerform(iterations: 4) { _ in
                let count = (try? PerformanceLibrary.bundled())?.manifest.tracks.count ?? -1
                lock.lock(); concurrent.append(count); lock.unlock()
            }
            t.expectEqual(concurrent.count, 4, "every concurrent call returned")
            t.expect(concurrent.allSatisfy { $0 == 129 },
                     "no concurrent first use produced a partial manifest")

            // Layout/containment still runs on the reused value: a variant whose file is absent
            // from the chosen root is rejected exactly as a freshly decoded library would reject it.
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("bside-bundled-reuse-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let resolved = try performanceFixtureSelection(second)
            do {
                _ = try second.verifiedURL(for: resolved, root: root)
                t.expect(false, "an absent media file must still fail on the reused manifest")
            } catch let error as PerformanceAssetError {
                guard case .missing = error else {
                    t.expect(false, "absent media must report .missing, got \(error)")
                    return
                }
            }
        } catch { t.expect(false, "\(error)") }
    }
    run("PerformanceRuntime.sessionPolicyAndStaleReports") { t in
        do {
            let library = try PerformanceLibrary.bundled()
            let id = PerformanceID(library.manifest.tracks[0].id)
            guard case .resolved(let variant) = VariantResolver.resolve(trackID: id, in: library.snapshot,
                effectiveLighting: .daylight, presentationPreference: .automatic) else { return t.expect(false, "resolve") }
            var session = PerformanceSession(id: "active", variant: variant)
            var state = PerformanceSessionState()
            state.start(session)
            t.expect(!state.accept(PerformanceReport(sessionID: "old", state: .ended)), "old completion ignored")
            t.expect(!state.pause(true, sessionID: "old"), "old pause ignored")
            var desired = DesiredState()
            let before = desired
            let active = PlaybackPolicy.evaluate(desired: desired, context: RuntimeContext(), performance: session)
            t.expectNear(active.ambientVolume, 0, "no ambient overlay")
            t.expect(active.musicVolume > 0, "music uses policy")
            t.expect(!active.performancePaused, "watch clock runs with its visual")
            session.paused = true
            let paused = PlaybackPolicy.evaluate(desired: desired, context: RuntimeContext(), performance: session)
            t.expectEqual(paused.visual, .full, "song pause leaves daily scene running")
            t.expect(paused.performancePaused, "watch clock pauses with its visual")
            t.expectNear(paused.musicVolume, 0, "transient pause mutes")
            t.expectEqual(desired, before, "wallpaper preferences unchanged")
            session.paused = false
            desired.muteAudioOnFullscreen = false
            let system = PlaybackPolicy.evaluate(desired: desired, context: RuntimeContext(fullscreenAppActive: true), performance: session)
            t.expectEqual(system.visual, .paused, "daily respects other fullscreen Spaces")
            t.expect(!system.performancePaused, "Space fullscreen state cannot pause an explicit song")
            t.expect(system.musicVolume > 0, "watch audio continues with the single video clock")
            t.expectEqual(session.variant, variant, "variant never changed")
            state.agentLost()
            t.expectNil(state.session, "crash/restart ends transient intent")
            state.start(session)
            t.expect(state.accept(PerformanceReport(sessionID: "active", state: .ended)), "current end accepted")
            t.expectNil(state.session, "natural end returns to daily")
        } catch { t.expect(false, "\(error)") }
    }
    run("PerformanceRuntime.playbackModeCodingAndLockedSession") { t in
        do {
            let variant = try performanceFixtureSelection(PerformanceLibrary.bundled())
            let oldSession = PerformanceSession(id: "same-identity", variant: variant, paused: true)
            t.expectEqual(oldSession.mode, .watch, "existing initializers retain audiovisual intent")
            var oldJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(oldSession)) as! [String: Any]
            oldJSON.removeValue(forKey: "mode")
            let decoded = try JSONDecoder().decode(PerformanceSession.self, from: JSONSerialization.data(withJSONObject: oldJSON))
            t.expectEqual(decoded, oldSession, "old missing mode defaults to watch without changing identity or pause")
            for mode in [PerformancePlaybackMode.watch, .listen] {
                let session = PerformanceSession(id: "locked", variant: variant, mode: mode)
                t.expectEqual(try JSONDecoder().decode(PerformanceSession.self, from: JSONEncoder().encode(session)),
                              session, "mode survives session coding")
                var state = PerformanceSessionState()
                state.start(session)
                t.expect(state.pause(true, sessionID: session.id), "active session pauses")
                t.expectEqual(state.session?.mode, mode, "pausing cannot change mode")
                t.expectEqual(state.session?.variant, variant, "pausing cannot replace the resolved variant")
                t.expectEqual(state.session?.id, session.id, "pausing keeps the same session")
            }
            for invalidMode: Any in ["future-mode", NSNull(), 3] {
                oldJSON["mode"] = invalidMode
                t.expectThrows("present invalid mode is rejected, never silently switched to watch") {
                    _ = try JSONDecoder().decode(PerformanceSession.self, from: JSONSerialization.data(withJSONObject: oldJSON))
                }
            }
            let effective = EffectivePlaybackState(visual: .paused, musicVolume: 0, ambientVolume: 0)
            t.expect(!effective.performancePaused, "effective initializer does not infer clock pause from mute or visual")
        } catch { t.expect(false, "mode coding failed: \(error)") }
    }
    run("PerformanceRuntime.queueContinuationCodingIsExplicit") { t in
        do {
            let variant = try performanceFixtureSelection(PerformanceLibrary.bundled())
            for mode in [PerformancePlaybackMode.watch, .listen] {
                let independent = PerformanceSession(id: "independent", variant: variant, mode: mode, paused: true)
                t.expect(!independent.continuesQueue, "ordinary starts remain independent by default")
                var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(independent)) as! [String: Any]
                legacy.removeValue(forKey: "continuesQueue")
                t.expectEqual(try JSONDecoder().decode(PerformanceSession.self,
                    from: JSONSerialization.data(withJSONObject: legacy)), independent,
                    "missing queue flag retains the original mode, variant, identity and pause")
                let queued = PerformanceSession(id: "queued", variant: variant, mode: mode,
                                                paused: true, continuesQueue: true)
                let encoded = try JSONEncoder().encode(queued)
                let json = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
                t.expectEqual(json["continuesQueue"] as? Bool, true, "queue ownership is explicitly encoded")
                t.expectEqual(try JSONDecoder().decode(PerformanceSession.self, from: encoded), queued,
                              "queued session retains all fields through coding")
                for invalid: Any in [NSNull(), "true", 1, [true]] {
                    legacy["continuesQueue"] = invalid
                    t.expectThrows("a present invalid queue flag must not become an independent session") {
                        _ = try JSONDecoder().decode(PerformanceSession.self,
                            from: JSONSerialization.data(withJSONObject: legacy))
                    }
                }
            }
        } catch { t.expect(false, "queue continuation coding failed: \(error)") }
    }
    run("PerformanceRuntime.queueAwaitingNextRetainsTheCorrectClocks") { t in
        do {
            let variant = try performanceFixtureSelection(PerformanceLibrary.bundled())
            let contexts: [(String, DesiredState, RuntimeContext)] = [
                ("normal", DesiredState(), RuntimeContext()),
                ("covered", DesiredState(), RuntimeContext(desktopVisible: false)),
                ("low power", DesiredState(), RuntimeContext(lowPowerMode: true)),
                ("global pause", DesiredState(paused: true), RuntimeContext()),
                ("screen asleep", DesiredState(), RuntimeContext(screenAwake: false))
            ]
            for mode in [PerformancePlaybackMode.watch, .listen] {
                let session = PerformanceSession(variant: variant, mode: mode, continuesQueue: true)
                let playing = PlaybackPolicy.evaluate(desired: DesiredState(), context: RuntimeContext(), performance: session)
                t.expect(!playing.performancePaused && playing.musicVolume > 0,
                         "queue ownership itself does not pause the playing song")
                for (name, desired, context) in contexts {
                    let before = desired
                    let daily = PlaybackPolicy.evaluate(desired: desired, context: context)
                    let waiting = PlaybackPolicy.evaluate(desired: desired, context: context, performance: session,
                                                         performanceAwaitingNext: true)
                    t.expect(waiting.performancePaused, "\(mode.rawValue) \(name): the ended music clock stays paused")
                    t.expectNear(waiting.musicVolume, 0, "\(mode.rawValue) \(name): no completed song audio")
                    t.expectNear(waiting.ambientVolume, 0, "\(mode.rawValue) \(name): waiting must not briefly restore ambient")
                    t.expectEqual(waiting.visual, daily.visual, "queue handoff preserves daily policy")
                    t.expect(waiting.reasons.contains("performance-awaiting-next"), "waiting has its own diagnostic")
                    t.expectEqual(desired, before, "waiting never changes persistent pause or volume intent")
                    let noSession = PlaybackPolicy.evaluate(desired: desired, context: context,
                                                           performanceAwaitingNext: true)
                    t.expectEqual(noSession, daily, "\(name): stale waiting flag without a session cannot suppress daily playback")
                }
                let released = PlaybackPolicy.evaluate(desired: DesiredState(), context: RuntimeContext(), performance: session,
                                                      performanceAwaitingNext: false)
                t.expectEqual(released, playing, "new playback intent clears only the temporary waiting restriction")
            }
        } catch { t.expect(false, "queue waiting policy failed: \(error)") }
    }
    run("PerformanceRuntime.bothModesRespectWholeSessionRestrictions") { t in
        do {
            let variant = try performanceFixtureSelection(PerformanceLibrary.bundled())
            let appID = "test.pause-all"
            let pauseProfile = Profile(id: "rule", name: "Rule", musicFactor: 1, ambientFactor: 1,
                                       appRules: [AppRule(bundleID: appID, action: .pauseAll)])
            let cases: [(String, DesiredState, RuntimeContext)] = [
                ("user-paused", DesiredState(paused: true), RuntimeContext()),
                ("profile:movie", DesiredState(profile: .movie), RuntimeContext()),
                ("system-asleep", DesiredState(), RuntimeContext(systemAwake: false)),
                ("screen-asleep", DesiredState(), RuntimeContext(screenAwake: false)),
                ("screen-locked", DesiredState(), RuntimeContext(screenLocked: true)),
                ("session-inactive", DesiredState(), RuntimeContext(sessionActive: false)),
                ("thermal-serious", DesiredState(), RuntimeContext(thermal: .serious)),
                ("thermal-critical", DesiredState(), RuntimeContext(thermal: .critical)),
                ("app-rule:\(appID):pause", DesiredState(profile: pauseProfile), RuntimeContext(foregroundAppBundleID: appID))
            ]
            for mode in [PerformancePlaybackMode.watch, .listen] {
                for (reason, desired, context) in cases {
                    let session = PerformanceSession(variant: variant, mode: mode)
                    let result = PlaybackPolicy.evaluate(desired: desired, context: context, performance: session)
                    let label = "\(mode.rawValue) \(reason)"
                    t.expectEqual(result.visual, .paused, "\(label) pauses visual")
                    t.expect(result.performancePaused, "\(label) pauses the performance clock")
                    t.expectNear(result.musicVolume, 0, "\(label) silences music")
                    t.expectNear(result.ambientVolume, 0, "\(label) does not restore ambient")
                    t.expect(result.reasons.contains(reason), "\(label) retains its diagnostic")
                }
            }
        } catch { t.expect(false, "whole-session matrix failed: \(error)") }
    }
    run("PerformanceRuntime.listenSeparatesDailyVisualAndMusicClock") { t in
        do {
            let variant = try performanceFixtureSelection(PerformanceLibrary.bundled())
            let music = 0.8 * 0.7
            let appID = "test.music-rule"
            let muteProfile = Profile(id: "mute", name: "Mute", musicFactor: 1, ambientFactor: 1,
                                      appRules: [AppRule(bundleID: appID, action: .muteAudio)])
            let duckProfile = Profile(id: "duck", name: "Duck", musicFactor: 1, ambientFactor: 1,
                                      appRules: [AppRule(bundleID: appID, action: .duckAudio, duckFactor: 0.25)])
            let cases: [(String, DesiredState, RuntimeContext, Bool, VisualPolicy, Bool, Double)] = [
                ("normal", DesiredState(), RuntimeContext(), false, .full, false, music),
                ("session pause", DesiredState(), RuntimeContext(), true, .full, true, 0),
                ("covered", DesiredState(), RuntimeContext(desktopVisible: false), false, .paused, false, music),
                ("low power", DesiredState(), RuntimeContext(lowPowerMode: true), false, .paused, false, music),
                ("fair thermal", DesiredState(), RuntimeContext(thermal: .fair), false, .full, false, music),
                ("fullscreen visual only", DesiredState(muteAudioOnFullscreen: false),
                 RuntimeContext(fullscreenAppActive: true), false, .paused, false, music),
                ("fullscreen mute only", DesiredState(pauseVisualOnFullscreen: false),
                 RuntimeContext(fullscreenAppActive: true), false, .full, false, music),
                ("fullscreen both", DesiredState(), RuntimeContext(fullscreenAppActive: true), false, .paused, false, music),
                ("music muted", DesiredState(musicMuted: true), RuntimeContext(), false, .full, false, 0),
                ("channel zero", DesiredState(musicVolume: 0), RuntimeContext(), false, .full, false, 0),
                ("master zero", DesiredState(masterVolume: 0), RuntimeContext(), false, .full, false, 0),
                ("silent profile", DesiredState(profile: .silent), RuntimeContext(), false, .full, false, 0),
                ("app mute", DesiredState(profile: muteProfile), RuntimeContext(foregroundAppBundleID: appID), false, .full, false, 0),
                ("app duck", DesiredState(profile: duckProfile), RuntimeContext(foregroundAppBundleID: appID), false, .full, false, music * 0.25)
            ]
            for (name, desired, context, paused, visual, clockPaused, volume) in cases {
                let savedIntent = desired
                let session = PerformanceSession(variant: variant, mode: .listen, paused: paused)
                let result = PlaybackPolicy.evaluate(desired: desired, context: context, performance: session)
                let daily = PlaybackPolicy.evaluate(desired: desired, context: context)
                t.expectEqual(result.visual, visual, "\(name): expected daily visual")
                t.expectEqual(result.visual, daily.visual, "\(name): listening leaves ordinary daily visual policy intact")
                t.expectEqual(result.performancePaused, clockPaused, "\(name): independent music clock")
                t.expectNear(result.musicVolume, volume, "\(name): requested effective music volume")
                t.expectNear(result.ambientVolume, 0, "\(name): active session never overlays unclassified ambient")
                t.expect(!daily.performancePaused, "\(name): no session has no performance pause intent")
                t.expectEqual(desired, savedIntent, "\(name): persistent preferences are unchanged")
            }
            // These daily restrictions must retain watch's accepted audiovisual exception.
            for context in [RuntimeContext(desktopVisible: false), RuntimeContext(lowPowerMode: true),
                            RuntimeContext(desktopVisible: false, lowPowerMode: true)] {
                let watch = PlaybackPolicy.evaluate(desired: DesiredState(), context: context,
                    performance: PerformanceSession(variant: variant, mode: .watch))
                t.expectEqual(watch.visual, .paused, "daily pauses while song remains independent")
                t.expect(!watch.performancePaused, "watch's single clock keeps running")
                t.expectNear(watch.musicVolume, music, "watch music remains requested")
                t.expectNear(watch.ambientVolume, 0, "watch still suppresses ambient")
            }
            let pausedListen = PlaybackPolicy.evaluate(desired: DesiredState(), context: RuntimeContext(desktopVisible: false),
                performance: PerformanceSession(variant: variant, mode: .listen, paused: true))
            t.expectEqual(pausedListen.visual, .paused, "listening pause does not remove daily occlusion restriction")
            t.expect(pausedListen.performancePaused, "covered listening session still respects its own pause")
        } catch { t.expect(false, "listen policy matrix failed: \(error)") }
    }
    run("PerformanceRuntime.BeijingReturnAndFixedPreference") { t in
        let desired = DesiredState()
        t.expectEqual(PlaybackPolicy.performanceLighting(desired: desired, minuteOfDay: 16 * 60), .daylight, "start day")
        t.expectEqual(PlaybackPolicy.performanceLighting(desired: desired, minuteOfDay: 21 * 60), .night, "stop now night")
        t.expectEqual(ContentResolver.resolve(currentKey: nil, desired: desired, catalog: ContentCatalog(), minuteOfDay: 21 * 60).targetKey.time, .night, "daily now night")
        t.expectEqual(PlaybackPolicy.performanceLighting(desired: DesiredState(timeMode: .fixed(.noon)), minuteOfDay: 21 * 60), .daylight, "fixed preserved")
    }
    run("PerformanceRuntime.IPCSessionRoundTripsAndOldVersionRejected") { t in
        do {
            let library = try PerformanceLibrary.bundled()
            guard case .resolved(let variant) = VariantResolver.resolve(trackID: PerformanceID(library.manifest.tracks[0].id), in: library.snapshot,
                effectiveLighting: .night, presentationPreference: .automatic) else { return t.expect(false, "resolve") }
            let session = PerformanceSession(id: "a", variant: variant, paused: true)
            let commands: [AgentCommand] = [.startPerformance(PerformanceStartRequest(session: session, mediaRoot: "/tmp/music")),
                .pausePerformance(PerformancePauseRequest(sessionID: "a", paused: false)), .stopPerformance(sessionID: "a")]
            for command in commands {
                let line = IPCCoding.encodeLine(IPCEnvelope(payload: command))!
                t.expectEqual(IPCCoding.decodeLine(line, as: AgentCommand.self)?.payload, command, "wire roundtrip")
            }
            for status in [PerformanceReport.State.loading, .playing, .paused, .ended, .stopped, .failed] {
                let event = AgentEvent.performance(PerformanceReport(sessionID: "a", state: status, detail: "fixture"))
                t.expectEqual(IPCCoding.decodeLine(IPCCoding.encodeLine(IPCEnvelope(payload: event))!, as: AgentEvent.self)?.payload, event, "event roundtrip")
            }
            let old = #"{"protocolVersion":1,"messageID":"x","sentAt":0,"payload":{"healthCheck":true}}"#
            t.expectNil(IPCCoding.decodeLine(old, as: AgentCommand.self), "v1 cannot accidentally control v2")
        } catch { t.expect(false, "\(error)") }
    }
    run("PerformanceRuntime.bindingPartialRelocationHashAndEscape") { t in
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bside-binding-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let data = Data("test-video-bytes".utf8)
            let json = try performanceManifestFixture(full: data)
            let tracks = json["tracks"] as! [[String: Any]]
            let first = tracks[0]
            let variants = first["variants"] as! [[String: Any]]
            let library = try PerformanceLibrary(data: JSONSerialization.data(withJSONObject: json))
            let record = library.manifest.tracks[0].variants[0]
            guard case .resolved(let selected) = VariantResolver.resolve(trackID: PerformanceID(first["id"] as! String), in: library.snapshot,
                effectiveLighting: record.lighting, presentationPreference: .explicit(record.presentation)) else { return t.expect(false, "resolve") }
            let file = root.appendingPathComponent(record.relativePath)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
            t.expectEqual(try library.verifiedURL(for: selected, root: root), file, "partial root binds exact file")
            t.expectEqual(try library.availability(root: root).count, variants.count - 1, "missing cells explicit, catalog intact")
            try Data(repeating: 0x42, count: data.count).write(to: file)
            do { _ = try library.verifiedURL(for: selected, root: root); t.expect(false, "same-size wrong hash rejected") }
            catch PerformanceAssetError.changed { t.expect(true, "hash mismatch typed") }
            try data.write(to: file)
            // Canonical media identity survives a known account trailer but not changed media.
            var canonicalJSON = json
            var canonicalTrack = first
            var canonicalVariants = variants
            for i in canonicalVariants.indices {
                canonicalVariants[i]["mediaByteSize"] = data.count
                canonicalVariants[i]["mediaSHA256"] = PerformanceSemanticCatalogJoin.sha256Hex(of: data)
            }
            canonicalTrack["variants"] = canonicalVariants
            canonicalJSON["tracks"] = [canonicalTrack]
            let canonicalLibrary = try PerformanceLibrary(data: JSONSerialization.data(withJSONObject: canonicalJSON))
            guard case .resolved(let canonicalSelection) = VariantResolver.resolve(trackID: selected.performanceID,
                in: canonicalLibrary.snapshot, effectiveLighting: record.lighting,
                presentationPreference: .explicit(record.presentation)) else { return t.expect(false, "canonical resolve") }
            let trailer = performanceUIDTrailer
            try (data + trailer).write(to: file)
            t.expectEqual(try PerformanceLibrary.mediaBodySize(file), Int64(data.count), "known UID trailer size")
            t.expectEqual(try canonicalLibrary.verifiedURL(for: canonicalSelection, root: root), file, "same media across accounts")
            try (data + Data("unknown-tail".utf8)).write(to: file)
            do { _ = try canonicalLibrary.verifiedURL(for: canonicalSelection, root: root); t.expect(false, "unknown trailing bytes rejected") }
            catch { t.expect(true, "unknown trailer is not stripped") }
            try data.write(to: file)
            let moved = root.appendingPathComponent("moved")
            try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: file.deletingLastPathComponent(), to: moved.appendingPathComponent(file.deletingLastPathComponent().lastPathComponent))
            t.expectEqual(try library.verifiedURL(for: selected, root: moved).lastPathComponent, file.lastPathComponent, "relocated root works")
            // A root-contained symlink to outside is refused before hash validation.
            let escapeRoot = root.appendingPathComponent("escape")
            try FileManager.default.createDirectory(at: escapeRoot, withIntermediateDirectories: true)
            let link = escapeRoot.appendingPathComponent(record.relativePath).deletingLastPathComponent()
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: moved.appendingPathComponent(file.deletingLastPathComponent().lastPathComponent))
            do { _ = try library.verifiedURL(for: selected, root: escapeRoot); t.expect(false, "escape rejected") }
            catch PerformanceAssetError.outsideRoot { t.expect(true, "symlink containment") }
            var invalid = json
            var bad = tracks[0]; var badVariants = variants
            badVariants[0]["relativePath"] = "../bad.mp4"; bad["variants"] = badVariants; invalid["tracks"] = [bad]
            do { _ = try PerformanceLibrary(data: JSONSerialization.data(withJSONObject: invalid)); t.expect(false, "traversal rejected") }
            catch { t.expect(true, "invalid relative reference rejected") }
        } catch { t.expect(false, "\(error)") }
    }
    run("PerformanceRuntime.candidateRefreshTracksFileLossAndRestoration") { t in
        do {
            let root = try ProviderFixture.freshTempRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let data = Data("owned-candidate-bytes".utf8)
            let fixture = try performanceCandidateFixture(in: root, data: data)
            let library = fixture.library
            let id = fixture.variant.id
            let other = library.manifest.tracks[0].variants[1]
            let first = try library.refreshCandidates(root: root, previous: nil, changedPaths: nil)
            t.expect(first.snapshot.unavailable[id] == nil, "the initial file is a candidate")
            let otherFailure = first.snapshot.unavailable[other.id]
            t.expect(otherFailure != nil, "another variant starts missing")
            let otherFile = root.appendingPathComponent(other.relativePath)
            let otherLocation = try performancePhysicalURL(otherFile.deletingLastPathComponent()).appendingPathComponent(otherFile.lastPathComponent)
            t.expect(first.snapshot.candidateLocations[other.id]?.contains(otherLocation) == true,
                     "missing locations are indexed before files exist")
            // The other file now exists, but its separate event has not arrived. A refresh
            // of this file must neither erase nor silently recompute that unrelated evidence.
            try data.write(to: otherFile)
            try FileManager.default.removeItem(at: fixture.file)
            let missing = try library.refreshCandidates(root: root, previous: first.snapshot,
                changedPaths: [fixture.file.path])
            t.expect(!missing.fullScan && missing.checkedVariantIDs == Set([id]), "a known file tombstone selects only its variant")
            t.expect(missing.snapshot.unavailable[id] != nil, "deleting a candidate makes it unavailable")
            t.expectEqual(missing.snapshot.unavailable[other.id], otherFailure, "other variant evidence survives the patch")

            try data.write(to: fixture.file)
            let restored = try library.refreshCandidates(root: root, previous: missing.snapshot,
                changedPaths: [fixture.file.path])
            t.expect(!restored.fullScan && restored.checkedVariantIDs == Set([id]), "restoring a missing indexed file stays incremental")
            t.expect(restored.snapshot.unavailable[id] == nil, "restoration clears the old failure")
            t.expectEqual(restored.snapshot.unavailable[other.id], otherFailure, "restoration does not erase unrelated failures")

            let otherArrived = try library.refreshCandidates(root: root, previous: restored.snapshot,
                changedPaths: [otherFile.path])
            t.expect(otherArrived.snapshot.unavailable[other.id] == nil, "the later event updates the previously missing indexed location")
            t.expectEqual(otherArrived.snapshot.unavailable, try library.availability(root: root),
                          "incremental evidence matches a fresh pass after all file events arrive")

            try Data(repeating: 0x42, count: data.count).write(to: fixture.file)
            let changed = try library.refreshCandidates(root: root, previous: otherArrived.snapshot,
                changedPaths: [fixture.file.path])
            t.expect(changed.snapshot.unavailable[id] == nil, "same-size bytes remain only a metadata candidate")
            do {
                _ = try library.verifiedURL(for: performanceFixtureSelection(library), root: root)
                t.expect(false, "candidate refresh must not bypass the complete selected-file hash")
            } catch PerformanceAssetError.changed { t.expect(true, "point-of-play verification still rejects changed bytes") }
        } catch { t.expect(false, "candidate file refresh failed: \(error)") }
    }
    run("PerformanceRuntime.candidateRefreshFindsNewAndRemovedDuplicates") { t in
        do {
            let root = try ProviderFixture.freshTempRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let data = Data("owned-duplicate-bytes".utf8)
            let fixture = try performanceCandidateFixture(in: root, data: data)
            let duplicate = root.appendingPathComponent("alternative").appendingPathComponent(fixture.variant.relativePath)
            try FileManager.default.createDirectory(at: duplicate.deletingLastPathComponent(), withIntermediateDirectories: true)
            let initial = try fixture.library.refreshCandidates(root: root, previous: nil, changedPaths: nil)
            let duplicateLocation = try performancePhysicalURL(duplicate.deletingLastPathComponent()).appendingPathComponent(duplicate.lastPathComponent)
            t.expect(initial.snapshot.candidateLocations[fixture.variant.id]?.contains(duplicateLocation) == true,
                     "an absent alternative remains in the index")
            try data.write(to: duplicate)
            let ambiguous = try fixture.library.refreshCandidates(root: root, previous: initial.snapshot,
                changedPaths: [duplicate.path])
            t.expect(!ambiguous.fullScan && ambiguous.checkedVariantIDs == Set([fixture.variant.id]),
                     "new duplicate file rechecks the exact variant across its existing candidate roots")
            t.expectEqual(ambiguous.snapshot.unavailable[fixture.variant.id],
                PerformanceAssetError.ambiguous(fixture.variant.relativePath).description, "a duplicate blocks the candidate")
            try FileManager.default.removeItem(at: duplicate)
            let unique = try fixture.library.refreshCandidates(root: root, previous: ambiguous.snapshot,
                changedPaths: [duplicate.path])
            t.expect(!unique.fullScan && unique.snapshot.unavailable[fixture.variant.id] == nil,
                     "removing the duplicate restores the surviving original")
        } catch { t.expect(false, "candidate duplicate refresh failed: \(error)") }
    }
    run("PerformanceRuntime.candidateRefreshRebuildsForDirectoryAndRootChanges") { t in
        do {
            let parent = try ProviderFixture.freshTempRoot()
            defer { try? FileManager.default.removeItem(at: parent) }
            let root = parent.appendingPathComponent("first-root")
            let data = Data("owned-root-change".utf8)
            let fixture = try performanceCandidateFixture(in: root, data: data)
            let library = fixture.library
            let allIDs = Set(library.manifest.tracks.flatMap(\.variants).map(\.id))
            let initial = try library.refreshCandidates(root: root, previous: nil, changedPaths: nil)
            let directory = try library.refreshCandidates(root: root, previous: initial.snapshot,
                changedPaths: [fixture.file.deletingLastPathComponent().path])
            t.expect(directory.fullScan && directory.checkedVariantIDs == allIDs, "a directory event rechecks all metadata")
            try FileManager.default.createDirectory(at: root.appendingPathComponent("new-category"), withIntermediateDirectories: true)
            let topology = try library.refreshCandidates(root: root, previous: directory.snapshot,
                changedPaths: [fixture.file.path])
            t.expect(topology.fullScan && topology.checkedVariantIDs == allIDs,
                     "a changed candidate-root set invalidates even a file-level update")
            let nextRoot = parent.appendingPathComponent("second-root")
            _ = try performanceCandidateFixture(in: nextRoot, data: data)
            let moved = try library.refreshCandidates(root: nextRoot, previous: topology.snapshot, changedPaths: [])
            t.expect(moved.fullScan && moved.checkedVariantIDs == allIDs, "a different selected root never reuses old evidence")
            t.expectEqual(moved.snapshot.root.path, try performancePhysicalURL(nextRoot).path, "snapshot belongs to the current physical root")
            t.expect(moved.snapshot.unavailable[fixture.variant.id] == nil, "the replacement root is checked independently")
        } catch { t.expect(false, "candidate root refresh failed: \(error)") }
    }
    run("PerformanceRuntime.candidateRefreshConservativelyTracksSymlinkTargets") { t in
        do {
            let root = try ProviderFixture.freshTempRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let data = Data("owned-symlink-target".utf8)
            let fixture = try performanceCandidateFixture(in: root, data: data)
            let target = root.appendingPathComponent("synthetic-source.bin")
            try FileManager.default.moveItem(at: fixture.file, to: target)
            try FileManager.default.createSymbolicLink(at: fixture.file, withDestinationURL: target)
            let initial = try fixture.library.refreshCandidates(root: root, previous: nil, changedPaths: nil)
            t.expect(initial.snapshot.unavailable[fixture.variant.id] == nil, "an in-root alias starts as a valid candidate")
            try Data([0x42]).write(to: target)
            let changed = try fixture.library.refreshCandidates(root: root, previous: initial.snapshot, changedPaths: [target.path])
            t.expect(changed.fullScan && changed.snapshot.unavailable[fixture.variant.id] != nil,
                     "an event on the unindexed alias target still refreshes its candidate")
            try data.write(to: target)
            let restored = try fixture.library.refreshCandidates(root: root, previous: changed.snapshot, changedPaths: [target.path])
            t.expect(restored.fullScan && restored.snapshot.unavailable[fixture.variant.id] == nil,
                     "target restoration is visible without weakening alias containment")
        } catch { t.expect(false, "candidate symlink refresh failed: \(error)") }
    }
    run("PerformanceRuntime.candidateRefreshPropagatesPreCancellation") { t in
        do {
            let root = try ProviderFixture.freshTempRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let data = Data("owned-cancelled-scan".utf8)
            let fixture = try performanceCandidateFixture(in: root, data: data)
            let (gate, releaseGate) = AsyncStream<Void>.makeStream()
            let finished = DispatchSemaphore(value: 0)
            let cancelled = DispatchSemaphore(value: 0)
            let task = Task.detached {
                for await _ in gate {}
                defer { finished.signal() }
                do { _ = try fixture.library.refreshCandidates(root: root, previous: nil, changedPaths: nil) }
                catch is CancellationError { cancelled.signal() }
                catch { /* Filesystem or candidate failures do not satisfy cancellation. */ }
            }
            task.cancel()
            releaseGate.finish()
            t.expect(finished.wait(timeout: .now() + 5) == .success, "pre-cancelled candidate scan terminates")
            t.expect(cancelled.wait(timeout: .now()) == .success, "cancellation is thrown, not stored as unavailability")
            t.expectEqual(try Data(contentsOf: fixture.file), data, "cancelled metadata scan leaves input bytes intact")
        } catch { t.expect(false, "candidate cancellation fixture failed: \(error)") }
    }
    run("PerformanceRuntime.sharedHashPrefixPreservesBothIndependentIdentities") { t in
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bside-hash-boundaries-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            // The trailer crosses a read boundary in the first case, starts exactly at
            // one in the second, and follows a multi-chunk body in the third.
            for bodySize in [1_048_576 - 13, 1_048_576, 2 * 1_048_576 + 17] {
                let body = Data(repeating: 0x53, count: bodySize)
                for trailer in [Data(), performanceUIDTrailer] {
                    let full = body + trailer
                    for bodyOnly in [false, true] {
                        // Full-only omits the body alternative; body-only deliberately
                        // mismatches full SHA. Neither side of the OR can mask the other.
                        let json = try performanceManifestFixture(full: full, body: bodyOnly ? body : nil,
                            fullSHA256: bodyOnly ? String(repeating: "0", count: 64) : nil)
                        let library = try PerformanceLibrary(data: JSONSerialization.data(withJSONObject: json))
                        let selected = try performanceFixtureSelection(library)
                        let file = root.appendingPathComponent(try library.record(for: selected).relativePath)
                        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try full.write(to: file)
                        t.expectEqual(try PerformanceLibrary.mediaBodySize(file), Int64(bodySize), "exact synthetic body boundary")
                        t.expectEqual(try library.verifiedURL(for: selected, root: root), file,
                                      "one-shot SHA identity matches streamed \(bodyOnly ? "body" : "full") at \(bodySize), tail=\(trailer.count)")
                    }
                }
            }
        } catch { t.expect(false, "\(error)") }
    }
    run("PerformanceRuntime.sharedHashRejectsBodyTrailerAndSizeCorruption") { t in
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bside-hash-corruption-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let body = Data(repeating: 0x53, count: 1_048_576 + 17)
            let full = body + performanceUIDTrailer
            let fullLibrary = try PerformanceLibrary(data: JSONSerialization.data(withJSONObject: performanceManifestFixture(full: full)))
            let bodyLibrary = try PerformanceLibrary(data: JSONSerialization.data(withJSONObject:
                performanceManifestFixture(full: full, body: body, fullSHA256: String(repeating: "0", count: 64))))
            let file = root.appendingPathComponent(fullLibrary.manifest.tracks[0].variants[0].relativePath)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            var changedBody = full
            changedBody[1_048_576] ^= 1
            var malformedTail = full
            malformedTail[body.count + 16] = 0x78 // UID must remain decimal digits.
            for damaged in [changedBody, malformedTail, Data(full.dropLast()), full + Data([0x01]), Data()] {
                try damaged.write(to: file)
                for library in [fullLibrary, bodyLibrary] {
                    do {
                        _ = try library.verifiedURL(for: performanceFixtureSelection(library), root: root)
                        t.expect(false, "changed body, malformed UID, truncated/appended or empty file must fail")
                    } catch PerformanceAssetError.changed { t.expect(true, "original integrity refusal retained") }
                }
            }
            // A valid different account trailer must alter the full digest while leaving
            // the reviewed body alternative usable; this proves the suffix was hashed.
            var changedUID = full
            changedUID[body.count + 16] = 0x39
            try changedUID.write(to: file)
            do {
                _ = try fullLibrary.verifiedURL(for: performanceFixtureSelection(fullLibrary), root: root)
                t.expect(false, "full identity must include all UID trailer bytes")
            } catch PerformanceAssetError.changed { t.expect(true, "different complete-file hash refused") }
            t.expectEqual(try bodyLibrary.verifiedURL(for: performanceFixtureSelection(bodyLibrary), root: root), file,
                          "known UID variation still accepts the unchanged reviewed body")
        } catch { t.expect(false, "\(error)") }
    }
    run("PerformanceRuntime.sharedHashPreservesTaskCancellation") { t in
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bside-hash-cancel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let full = Data(repeating: 0x53, count: 2 * 1_048_576 + 17) + performanceUIDTrailer
            let library = try PerformanceLibrary(data: JSONSerialization.data(withJSONObject: performanceManifestFixture(full: full)))
            let selected = try performanceFixtureSelection(library)
            let file = root.appendingPathComponent(try library.record(for: selected).relativePath)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try full.write(to: file)
            let (gate, releaseGate) = AsyncStream<Void>.makeStream()
            let finished = DispatchSemaphore(value: 0)
            let cancelled = DispatchSemaphore(value: 0)
            let task = Task.detached {
                // An empty async stream suspends until cancellation or explicit finish;
                // neither can happen here before the parent has cancelled this task.
                for await _ in gate {}
                defer { finished.signal() }
                do { _ = try library.verifiedURL(for: selected, root: root) }
                catch is CancellationError { cancelled.signal() }
                catch { /* An integrity/IO error must not satisfy the cancellation assertion. */ }
            }
            task.cancel()
            releaseGate.finish()
            t.expect(finished.wait(timeout: .now() + 5) == .success, "cancelled verification finishes within the test deadline")
            t.expect(cancelled.wait(timeout: .now()) == .success, "streaming cancellation is propagated as CancellationError")
            t.expectEqual(try Data(contentsOf: file), full, "verification and cancellation never modify synthetic input")
        } catch { t.expect(false, "\(error)") }
    }
}
