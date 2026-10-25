// BSidePlatform — App support: paths, atomic JSON persistence, stderr logging,
// compatibility snapshot. ControlApp owns persistent read-only directory bookmarks;
// the Agent receives only temporary access grants, never this preference store.

import AppKit
import BSideCore

public enum AppLog {
    private static let lock = NSLock()

    /// Writer ownership of the shared `control.log`.
    ///
    /// `control.log` may have exactly ONE writer process. `RotatingFileLog` serializes appends
    /// only within its own instance (a process-local `NSLock`), and every append is an
    /// open + seek-to-end + write that is not atomic across instances or processes. Two
    /// processes appending the same file can therefore resolve the same end offset and one
    /// write overwrites the other's just-written record. The witnessed failure was exactly
    /// that: an Agent `[INFO] agent: daily-video installed …` line landed on the offset of a
    /// concurrent ControlApp `[CTRL] performance.report … state=ended …` line and replaced
    /// its prefix, so a strict reader could no longer see a valid end-of-performance event.
    private enum Sink {
        /// Production default: this process owns `AppPaths.controlLogURL` (ControlApp).
        case unconfigured
        case owned(RotatingFileLog)
        /// This process must never open `control.log` at all (the disposable Agent).
        case disowned
    }
    private static var sink: Sink = .unconfigured

    /// Declare whether THIS process owns the shared `control.log`.
    ///
    /// The Agent calls this with `false`: its diagnostics already leave through its own stderr,
    /// which the supervising ControlApp drains into `agent.log` (supervisor-owned, with the
    /// same 5 MiB + one `.1` rotation). Relinquishing the file sink keeps `control.log`
    /// single-writer without dropping any diagnostic record. `url` is injectable so a test can
    /// keep the sink inside a temp directory instead of the real Application Support path.
    public static func setControlLogOwnership(_ owned: Bool, url: URL? = nil) {
        lock.lock(); defer { lock.unlock() }
        sink = owned ? .owned(RotatingFileLog(url: url ?? AppPaths.controlLogURL)) : .disowned
    }

    public static func error(_ message: String) { write("ERROR", message) }
    public static func info(_ message: String) { write("INFO", message) }
    /// ControlApp chain-of-custody log (menu click → panel → validation → agent → playback).
    public static func control(_ message: String) { write("CTRL", message) }

    /// The file sink this process currently owns. The production default is resolved lazily so
    /// merely using `AppLog` never opens or creates a log file before the first record.
    private static func activeSink() -> RotatingFileLog? {
        lock.lock(); defer { lock.unlock() }
        switch sink {
        case .unconfigured:
            let log = RotatingFileLog(url: AppPaths.controlLogURL)   // control.log: 5 MiB + one .1 backup
            sink = .owned(log)
            return log
        case .owned(let log):
            return log
        case .disowned:
            return nil
        }
    }

    private static func write(_ level: String, _ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(stamp)] [\(level)] \(message)\n"
        let data = Data(line.utf8)
        // stderr is this process's own diagnostic channel and is ALWAYS written. The Agent's
        // stderr is captured by the supervisor into agent.log, so a disowned file sink still
        // preserves every record — it only removes the second writer from control.log.
        FileHandle.standardError.write(data)
        activeSink()?.append(data)
    }
}

/// Explicit, fixed run variant of this build. The variant is compiled into `Info.plist` by
/// `scripts/build_app.sh` (bundle identifier + display name) and is the ONLY input that decides
/// whether an app with no `BSIDEMAC_SUPPORT_DIR` override resolves the ordinary or the candidate
/// support directory. It is never inferred from the executable path, argv or a marker file.
public enum AppVariant: String, Equatable {
    case normal = "default"
    /// Long-lived daily candidate: its own bundle identity and its own default support folder,
    /// so a directly launched candidate never reads or writes the ordinary application's data.
    case dailyCandidate = "daily-candidate"
    case desktopPreview = "desktop-preview"
}

/// One recognized app identity pair (bundle identifier + display name) and the support folder
/// that identity owns by default. The ordinary and candidate pairs are fixed here; a bundle
/// whose identifier matches neither pair is unrecognized, not silently treated as ordinary.
public enum AppIdentity {
    public static let normalBundleIdentifier = "local.bsidesmac.app"
    /// Visible product branding only. Bundle identifiers, module/executable names and support
    /// folder names below stay unchanged: the rename is branding, never a data migration.
    public static let normalDisplayName = "bsideyou"
    public static let normalSupportFolderName = "BSideMac"

    public static let dailyCandidateBundleIdentifier = "local.bsidemac.dailycandidate.pzbl6ez3"
    /// The EXACT lowercase product name is shared by both variants. The candidate is still
    /// distinct through its bundle identifier, candidate flag and support folder — never through
    /// a longer display name.
    public static let dailyCandidateDisplayName = "bsideyou"
    public static let dailyCandidateSupportFolderName = "BSideMac-DailyCandidate"

    public static let desktopPreviewBundleIdentifier = "local.bsidemac.desktoppreview"
    public static let desktopPreviewDisplayName = "bsideyou Desktop Preview"
    public static let desktopPreviewSupportFolderName = "BSideMac-DesktopPreview"

    /// Bundle identifiers of every recognized identity pair, candidate included.
    public static let recognizedBundleIdentifiers: Set<String> = [
        normalBundleIdentifier, dailyCandidateBundleIdentifier, desktopPreviewBundleIdentifier,
    ]

    /// Human-readable pair for a recognizable bundle identifier; nil for anything else.
    public static func displayName(forBundleIdentifier identifier: String) -> String? {
        switch identifier {
        case normalBundleIdentifier: return normalDisplayName
        case dailyCandidateBundleIdentifier: return dailyCandidateDisplayName
        case desktopPreviewBundleIdentifier: return desktopPreviewDisplayName
        default: return nil
        }
    }

    /// The app variant a recognizable bundle identifier belongs to; unrecognized → nil.
    public static func variant(forBundleIdentifier identifier: String) -> AppVariant? {
        switch identifier {
        case normalBundleIdentifier: return .normal
        case dailyCandidateBundleIdentifier: return .dailyCandidate
        case desktopPreviewBundleIdentifier: return .desktopPreview
        default: return nil
        }
    }

    /// Support folder a recognizable bundle identifier owns. An unrecognized identifier resolves
    /// to nil so callers keep the ordinary folder instead of inventing a per-identifier path.
    public static func supportFolderName(forBundleIdentifier identifier: String) -> String? {
        switch identifier {
        case normalBundleIdentifier: return normalSupportFolderName
        case dailyCandidateBundleIdentifier: return dailyCandidateSupportFolderName
        case desktopPreviewBundleIdentifier: return desktopPreviewSupportFolderName
        default: return nil
        }
    }
}

public enum AppPaths {
    public static let supportDirOverrideKey = "BSIDEMAC_SUPPORT_DIR"

    /// The one support-root rule for every process of this app family:
    /// 1. an explicit non-empty `BSIDEMAC_SUPPORT_DIR` always wins (test/verification isolation);
    /// 2. otherwise the folder owned by the current bundle identity (candidate or ordinary);
    /// 3. a bundle whose identifier is unrecognized (dev/SwiftPM/test executable) keeps ordinary.
    /// Pure: it computes a URL and never creates anything. `environmentOverride` defaults to the
    /// process environment so production callers pass nothing while tests inject explicitly.
    public static func resolvedSupportRoot(bundleIdentifier: String?,
                                           environmentOverride: String? =
                                               ProcessInfo.processInfo.environment[supportDirOverrideKey]) -> URL {
        if let override = environmentOverride, !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let folderName = bundleIdentifier
            .flatMap { AppIdentity.supportFolderName(forBundleIdentifier: $0) }
            ?? AppIdentity.normalSupportFolderName
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(folderName, isDirectory: true)
    }

    public static var applicationSupport: URL {
        let dir = resolvedSupportRoot(bundleIdentifier: Bundle.main.bundleIdentifier)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static var preferencesURL: URL { applicationSupport.appendingPathComponent("preferences.json") }
    public static var agentLogURL: URL { applicationSupport.appendingPathComponent("agent.log") }
    public static var controlLogURL: URL { applicationSupport.appendingPathComponent("control.log") }
    /// ADR-022: ControlApp-owned local song catalog. Versioned, atomically replaced; an
    /// unsupported/corrupt file is preserved rather than overwritten.
    public static var localSongsURL: URL { applicationSupport.appendingPathComponent("local-songs.json") }
}

/// JSON value used only to retain identity records this build cannot interpret.
/// Integers stay integers (Int64/UInt64) so large inodes survive unrelated preference saves.
public indirect enum OpaqueJSON: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case uint(UInt64)
    case double(Double)
    case string(String)
    case array([OpaqueJSON])
    case object([String: OpaqueJSON])
}

extension OpaqueJSON: Codable {
    private struct AnyKey: CodingKey {
        let stringValue: String
        let intValue: Int?
        init?(stringValue: String) { self.stringValue = stringValue; self.intValue = nil }
        init?(intValue: Int) { self.stringValue = String(intValue); self.intValue = intValue }
    }

    public init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: AnyKey.self) {
            var object: [String: OpaqueJSON] = [:]
            for key in container.allKeys {
                object[key.stringValue] = try container.decode(OpaqueJSON.self, forKey: key)
            }
            self = .object(object)
            return
        }
        if var container = try? decoder.unkeyedContainer() {
            var array: [OpaqueJSON] = []
            while !container.isAtEnd { array.append(try container.decode(OpaqueJSON.self)) }
            self = .array(array)
            return
        }
        let single = try decoder.singleValueContainer()
        if single.decodeNil() { self = .null; return }
        if let value = try? single.decode(Bool.self) { self = .bool(value); return }
        if let value = try? single.decode(Int64.self) { self = .int(value); return }
        if let value = try? single.decode(UInt64.self) { self = .uint(value); return }
        if let value = try? single.decode(Double.self) { self = .double(value); return }
        if let value = try? single.decode(String.self) { self = .string(value); return }
        throw DecodingError.dataCorruptedError(in: single, debugDescription: "unsupported JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        case .bool(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .int(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .uint(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .double(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .string(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .array(let value):
            var container = encoder.unkeyedContainer()
            for element in value { try container.encode(element) }
        case .object(let value):
            var container = encoder.container(keyedBy: AnyKey.self)
            for (key, element) in value {
                guard let codingKey = AnyKey(stringValue: key) else { continue }
                try container.encode(element, forKey: codingKey)
            }
        }
    }
}

/// Persisted wrapper around a `DirectoryIdentitySnapshot`. An EXISTING but unreadable or
/// unknown-version record must never be mistaken for a legacy bookmark-only root, so its
/// original JSON values are retained without silently rebaselining the record. Decoding never throws,
/// which keeps a malformed new field from resetting every other saved preference.
public enum StoredDirectoryIdentity: Equatable, Sendable {
    case snapshot(DirectoryIdentitySnapshot)
    /// Existing record this build cannot interpret. Preserve its contents; only an
    /// explicit reselection replaces it.
    case unsupported(OpaqueJSON)

    public var snapshotValue: DirectoryIdentitySnapshot? {
        if case .snapshot(let value) = self { return value }
        return nil
    }
}

extension StoredDirectoryIdentity: Codable {
    public init(from decoder: Decoder) throws {
        if let snapshot = try? DirectoryIdentitySnapshot(from: decoder), snapshot.isSupported {
            self = .snapshot(snapshot)
            return
        }
        self = .unsupported((try? OpaqueJSON(from: decoder)) ?? .object([:]))
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .snapshot(let snapshot):
            var container = encoder.singleValueContainer()
            try container.encode(snapshot)
        case .unsupported(let raw):
            var container = encoder.singleValueContainer()
            try container.encode(raw)
        }
    }
}

/// Result of comparing a saved/historical anchor to a freshly resolved directory before any
/// renewal, scan, activation or grant. `identity` is always what should be kept or committed.
public struct DirectoryIdentityOutcome: Equatable, Sendable {
    public enum Verdict: Equatable, Sendable {
        case consistent
        case conflict(DirectoryIdentityConflictReason)
        case unknown
    }

    public let verdict: Verdict
    /// Anchor to keep or commit; unchanged from the saved record unless adoption is requested.
    public let identity: StoredDirectoryIdentity?
    /// True only when no usable anchor existed and the current tuple may be adopted once,
    /// after successful ordinary validation, as `legacyAdopted`.
    public let adoptAfterValidation: Bool

    public var conflictReason: DirectoryIdentityConflictReason? {
        if case .conflict(let reason) = verdict { return reason }
        return nil
    }
}

/// Pure ControlApp/Platform decision shared by daily and music bindings. It never performs
/// IO and never rebaselines an existing record.
public enum DirectoryIdentityResolver {
    public static func resolve(stored: StoredDirectoryIdentity?, bookmark: Data,
                               fresh: DirectoryIdentitySnapshot?) -> DirectoryIdentityOutcome {
        switch stored {
        case .unsupported(let raw):
            // Preserve the unreadable record values; never adopt over it.
            return DirectoryIdentityOutcome(verdict: .unknown, identity: .unsupported(raw),
                                            adoptAfterValidation: false)
        case .snapshot(let anchor):
            guard let fresh else {
                return DirectoryIdentityOutcome(verdict: .unknown, identity: .snapshot(anchor),
                                                adoptAfterValidation: false)
            }
            switch anchor.comparison(with: fresh) {
            case .conflict(let reason):
                return DirectoryIdentityOutcome(verdict: .conflict(reason), identity: .snapshot(anchor),
                                                adoptAfterValidation: false)
            case .consistent:
                return DirectoryIdentityOutcome(verdict: .consistent, identity: .snapshot(anchor),
                                                adoptAfterValidation: false)
            case .unknown:
                // Known anchor must not be replaced by unknown current data.
                return DirectoryIdentityOutcome(verdict: .unknown, identity: .snapshot(anchor),
                                                adoptAfterValidation: false)
            }
        case nil:
            // Legacy bookmark-only root: salvage historical evidence before any renewal.
            guard let historical = DirectoryAccessLease.historicalIdentity(fromBookmarkData: bookmark) else {
                return DirectoryIdentityOutcome(verdict: .unknown, identity: nil,
                                                adoptAfterValidation: true)
            }
            guard let fresh else {
                return DirectoryIdentityOutcome(verdict: .unknown, identity: .snapshot(historical),
                                                adoptAfterValidation: false)
            }
            switch historical.comparison(with: fresh) {
            case .conflict(let reason):
                return DirectoryIdentityOutcome(verdict: .conflict(reason), identity: .snapshot(historical),
                                                adoptAfterValidation: false)
            case .consistent:
                return DirectoryIdentityOutcome(verdict: .consistent, identity: .snapshot(historical),
                                                adoptAfterValidation: false)
            case .unknown:
                // Historical evidence is insufficient: preserve it now, adopt current after validation.
                return DirectoryIdentityOutcome(verdict: .unknown, identity: .snapshot(historical),
                                                adoptAfterValidation: true)
            }
        }
    }

    /// Prospective adoption for a root with no usable anchor. Returns nil when the current
    /// tuple is itself insufficient, leaving the root explicitly unverified.
    public static func adopt(fresh: DirectoryIdentitySnapshot?) -> StoredDirectoryIdentity? {
        guard let fresh, let adopted = fresh.adoptedForLegacyMigration() else { return nil }
        return .snapshot(adopted)
    }

    /// An explicit user selection always records SOMETHING, even when this build cannot
    /// capture fresh metadata. The explicit-selection record blocks any later automatic
    /// legacy adoption from silently establishing a new baseline.
    public static func explicitSelection(fresh: DirectoryIdentitySnapshot?) -> StoredDirectoryIdentity {
        if let fresh, fresh.isSupported { return .snapshot(fresh) }
        return .snapshot(DirectoryIdentitySnapshot(volumeUUID: nil, inode: nil,
                                                   persistentIDsSupported: nil,
                                                   provenance: .explicitSelection))
    }
}

/// Brief nonmodal status projection for the existing diagnostics/settings surface.
/// A consistent ordinary root stays quiet (nil); only unverified/migrated states surface.
public enum DirectoryIdentityStatus {
    public static func describe(_ stored: StoredDirectoryIdentity?,
                                fresh: DirectoryIdentitySnapshot?) -> String? {
        switch stored {
        case .unsupported:
            return "identity record unreadable; kept unchanged (unverified)"
        case .snapshot(let anchor):
            switch anchor.provenance {
            case .explicitSelection:
                guard let fresh else { return "identity unverified; explicit selection not captured" }
                switch anchor.comparison(with: fresh) {
                case .consistent: return nil
                case .conflict: return "identity conflict; explicit reselection required"
                case .unknown: return "identity unverified; explicit selection could not be checked"
                }
            case .bookmarkHistorical:
                return "identity from bookmark history only; not an identity guarantee"
            case .legacyAdopted:
                return "identity tracking began during migration; original selection not independently verified"
            }
        case nil:
            return "identity not recorded; unverified"
        }
    }
}

/// ControlApp-owned persisted state (ADR-002/#7): DesiredState survives agent crashes.
public struct AppPreferences: Codable {
    public var desired: DesiredState
    public var assetPath: String?
    public var performanceRoot: String?
    public var assetBookmark: Data?
    public var performanceBookmark: Data?
    /// Best-effort historical identity anchors, kept SEPARATE from the renewable bookmarks.
    /// Ordinary renewal/move carries these forward unchanged; only explicit reselection or a
    /// one-time prospective legacy adoption replaces them. Optional in older files.
    public var assetIdentity: StoredDirectoryIdentity?
    public var performanceIdentity: StoredDirectoryIdentity?
    /// Configuration only. Missing in older files; execution and position never auto-resume.
    public var performanceQueue: PerformanceQueueConfiguration?
    public var favoritePerformanceIDs: Set<PerformanceID>?
    public var favoriteLocalTrackIDs: Set<String>?
    /// Optional fields decode as nil from older preference files (forward/backward safe).
    public var onboardingCompleted: Bool?

    /// State-driven (KeyPoint pattern): onboarding shows exactly when no asset is configured.
    public var needsOnboarding: Bool { assetPath == nil }

    /// A NEW persisted preference starts on the reviewed A/R1 evening material as an explicit
    /// fixed choice. The Core `DesiredState()` default stays `.auto` for callers that build
    /// domain state directly; an existing saved file always decodes to exactly what it stored
    /// (including a saved `.auto`) and never passes through this default.
    public init(desired: DesiredState = DesiredState(scene: .a, outfit: .r1, timeMode: .fixed(.evening)),
                assetPath: String? = nil, onboardingCompleted: Bool? = nil) {
        self.desired = desired
        self.assetPath = assetPath
        self.performanceRoot = nil
        self.assetBookmark = nil
        self.performanceBookmark = nil
        self.assetIdentity = nil
        self.performanceIdentity = nil
        self.performanceQueue = nil
        self.favoritePerformanceIDs = nil
        self.favoriteLocalTrackIDs = nil
        self.onboardingCompleted = onboardingCompleted
    }

    public static func load() -> AppPreferences {
        guard let data = try? Data(contentsOf: AppPaths.preferencesURL),
              var prefs = try? JSONDecoder().decode(AppPreferences.self, from: data) else {
            return AppPreferences()
        }
        prefs.desired = prefs.desired.sanitized()
        return prefs
    }

    @discardableResult
    public func save(to url: URL = AppPaths.preferencesURL) -> Result<Void, Error> {
        let data: Data
        do {
            data = try JSONEncoder().encode(self)
        } catch {
            AppLog.error("prefs: JSON encode failed — preferences NOT saved: \(error)")
            return .failure(error)
        }
        do {
            try data.write(to: url, options: [.atomic])
            AppLog.control("prefs.saved path=\(url.path)")
            return .success(())
        } catch {
            AppLog.error("prefs: save failed: \(error)")
            return .failure(error)
        }
    }
}

/// Startup capability snapshot (prompt rule #18) — the `=== system ===` block of Diagnostics.
public struct CompatibilitySnapshot {
    public init() {}

    public var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }
    public var macOSVersion: String { ProcessInfo.processInfo.operatingSystemVersionString }
    public var architecture: String { "arm64" }
    public var lowPowerMode: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }
    public var thermal: ThermalLevel { ThermalLevel.from(ProcessInfo.processInfo.thermalState) }
}

/// Deterministic diagnostics text projection — the ONE builder shared by the Diagnostics
/// window and Copy Diagnostics, so the two surfaces can never disagree (ADR-007 slice).
/// Lives in BSidePlatform so the formatting is regression-tested by BSideTestRunner;
/// BSideControlApp only feeds it the current authoritative state. Raw technical causes
/// belong HERE (prompt rules #22/#27): the normal UI never shows this text.
public enum DiagnosticsBuilder {
    public struct Input {
        public var prefs: AppPreferences
        /// ResourceStage's stable log label (user-visible loading machine, not the supervision axis).
        public var stage: String
        public var stageDetail: String
        public var stageAt: Date
        /// Coarse supervisor projection: idle | starting | running | degraded.
        public var supervisionState: String
        public var abnormalExits: Int
        public var maxFailures: Int
        public var lastExitSummary: String?
        public var launchedAt: Date?
        public var lastSnapshot: RuntimeSnapshot?
        /// Slice 7: login-item projection (system truth + request outcome + technical cause).
        public var login: LoginItemProjection?
        public var preferencesSaveStatus: String
        public var preferencesSaveError: String?
        /// Brief nonmodal directory identity status; nil when an ordinary consistent root is quiet.
        public var dailyDirectoryIdentity: String?
        public var performanceDirectoryIdentity: String?

        public init(prefs: AppPreferences, stage: String, stageDetail: String, stageAt: Date,
                    supervisionState: String, abnormalExits: Int, maxFailures: Int,
                    lastExitSummary: String?, launchedAt: Date?, lastSnapshot: RuntimeSnapshot?,
                    login: LoginItemProjection?, preferencesSaveStatus: String = "unchanged",
                    preferencesSaveError: String? = nil,
                    dailyDirectoryIdentity: String? = nil,
                    performanceDirectoryIdentity: String? = nil) {
            self.prefs = prefs
            self.stage = stage
            self.stageDetail = stageDetail
            self.stageAt = stageAt
            self.supervisionState = supervisionState
            self.abnormalExits = abnormalExits
            self.maxFailures = maxFailures
            self.lastExitSummary = lastExitSummary
            self.launchedAt = launchedAt
            self.lastSnapshot = lastSnapshot
            self.login = login
            self.preferencesSaveStatus = preferencesSaveStatus
            self.preferencesSaveError = preferencesSaveError
            self.dailyDirectoryIdentity = dailyDirectoryIdentity
            self.performanceDirectoryIdentity = performanceDirectoryIdentity
        }
    }

    /// Fixed label column so every row aligns and the projection stays greppable.
    private static func label(_ s: String) -> String {
        s.padding(toLength: 14, withPad: " ", startingAt: 0)
    }

    private static func fmt2(_ v: Double) -> String { String(format: "%.2f", v) }

    private static func timeModeLine(_ mode: TimeMode) -> String {
        switch mode {
        case .auto: return "auto"
        case .fixed(let t): return "fixed:\(t.rawValue)"
        }
    }

    /// Home path redaction for shareable output (prompt rule #22).
    public static func build(_ input: Input) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        func redact(_ s: String) -> String { s.replacingOccurrences(of: home, with: "~") }

        var lines: [String] = []
        let compat = CompatibilitySnapshot()
        let desired = input.prefs.desired

        // What the user asked for — the reference axis every other block is compared against.
        lines.append("=== desired ===")
        lines.append("\(Self.label("scene"))\(desired.scene.rawValue)")
        lines.append("\(Self.label("outfit"))\(desired.outfit.rawValue)")
        lines.append("\(Self.label("time"))\(timeModeLine(desired.timeMode))")
        lines.append("\(Self.label("profile"))\(desired.profile.id) (\(desired.profile.name))")
        lines.append("\(Self.label("paused"))\(desired.paused ? "on" : "off")")
        lines.append("\(Self.label("mode"))\(desired.desktopMode ? "desktop" : "preview")")
        lines.append("\(Self.label("volumes"))master \(fmt2(desired.masterVolume)) / music \(fmt2(desired.musicVolume)) / ambient \(fmt2(desired.ambientVolume))")
        lines.append("\(Self.label("mutes"))music \(desired.musicMuted ? "on" : "off") / ambient \(desired.ambientMuted ? "on" : "off")")
        lines.append("\(Self.label("saved"))\(input.preferencesSaveStatus)")
        if let error = input.preferencesSaveError {
            lines.append("\(Self.label("save error"))\(redact(error))")
        }
        lines.append("")
        lines.append("=== resource ===")
        lines.append("\(Self.label("stage"))\(input.stage)")
        lines.append("\(Self.label("detail"))\(input.stageDetail.isEmpty ? "-" : redact(input.stageDetail))")
        lines.append("\(Self.label("since"))\(ISO8601DateFormatter().string(from: input.stageAt))")
        lines.append("\(Self.label("path"))\(input.prefs.assetPath.map(redact) ?? "-")")
        if let status = input.dailyDirectoryIdentity {
            lines.append("\(Self.label("daily id"))\(status)")
        }
        if let status = input.performanceDirectoryIdentity {
            lines.append("\(Self.label("music id"))\(status)")
        }
        lines.append("")
        lines.append("=== supervision ===")
        lines.append("\(Self.label("phase"))\(input.supervisionState)")
        lines.append("\(Self.label("abnormal ×"))\(input.abnormalExits) / \(input.maxFailures)")
        lines.append("\(Self.label("last exit"))\(input.lastExitSummary ?? "-")")
        if let launched = input.launchedAt {
            lines.append("\(Self.label("uptime"))\(String(format: "%.0fs", Date().timeIntervalSince(launched)))")
        }
        if let snap = input.lastSnapshot {
            lines.append("")
            lines.append("=== agent snapshot ===")
            lines.append("\(Self.label("state"))\(snap.state.rawValue)")
            lines.append("\(Self.label("clip"))\(snap.currentClip ?? "-")")
            lines.append("\(Self.label("visual"))\(snap.visual.rawValue)")
            lines.append("\(Self.label("volumes"))music \(fmt2(snap.musicVolume)) / ambient \(fmt2(snap.ambientVolume))")
            lines.append("\(Self.label("reasons"))\(snap.reasons.isEmpty ? "-" : snap.reasons.joined(separator: ", "))")
            lines.append("\(Self.label("catalog"))\(snap.catalogSummary ?? "-")")
            lines.append("\(Self.label("last error"))\(snap.lastError.map(redact) ?? "-")")
        }
        if let login = input.login {
            lines.append("")
            lines.append("=== login item ===")
            lines.append("\(Self.label("summary"))\(login.summary)")
            lines.append("\(Self.label("detail"))\(login.diagnosticLine)")
        }
        lines.append("")
        lines.append("=== system ===")
        lines.append("\(Self.label("app"))\(compat.appVersion)")
        lines.append("\(Self.label("IPC required"))\(IPC.protocolVersion)")
        lines.append("\(Self.label("macOS"))\(compat.macOSVersion)")
        lines.append("\(Self.label("arch"))\(compat.architecture)")
        lines.append("\(Self.label("low power"))\(compat.lowPowerMode ? "on" : "off")")
        lines.append("\(Self.label("thermal"))\(compat.thermal.rawValue)")
        return lines.joined(separator: "\n")
    }
}
