// BSidePlatform — reviewed daily-entry source identity.
//
// The explicit activity entry is bound to the EXACT chosen file: its byte size and full SHA-256
// are the content identity. Metadata alone (path/size/mtime) is never treated as reviewed-content
// identity. Only the one file selected for the click is streamed; there is no library-wide hash,
// no decode and no speculative fallback. The URL still comes from the existing authorized
// catalog (`AssetBundle.url(for:)`); no absolute path is stored here.

import CryptoKit
import Foundation
import BSideCore

/// Reviewed content identity of a whole daily source unit. Entries in one source share its
/// identity; the caller binds this identity to the activity's resolved catalog URL.
public struct DailyActivitySourceIdentity: Equatable, Sendable {
    public let byteSize: Int64
    public let sha256: String

    public init(byteSize: Int64, sha256: String) {
        self.byteSize = byteSize
        self.sha256 = sha256
    }

    /// The reviewed whole-source identity for one qualified (scene, outfit, time) source. A
    /// combination absent from this table has no reviewed identity and must never be verified
    /// against, or installed as, a different source's digest.
    public static func reviewed(for sourceKey: ContentKey) -> DailyActivitySourceIdentity? {
        table[sourceKey]
    }

    private static let table: [ContentKey: DailyActivitySourceIdentity] = {
        func key(_ scene: Scene, _ outfit: Outfit, _ time: TimeOfDay) -> ContentKey {
            ContentKey(scene: scene, outfit: outfit, time: time)
        }
        return [
            key(.a, .r1, .noon): DailyActivitySourceIdentity(
                byteSize: 125_130_252,
                sha256: "3921fb7f656907ff3f2b95795187da758348f23823ca064fb36bd8f2c8ac571f"),
            key(.a, .r1, .evening): DailyActivitySourceIdentity(
                byteSize: 106_935_332,
                sha256: "7fbc3c21975832c7c0855a287623c86136071c249bf7485d7791b5ad5acfd976"),
            key(.a, .r1, .night): DailyActivitySourceIdentity(
                byteSize: 93_098_638,
                sha256: "3740912fc4efc84633e38e52987fedc2a358e4ed3f3d900311f0f7b209cc6641"),
            key(.a, .r2, .evening): DailyActivitySourceIdentity(
                byteSize: 110_641_767,
                sha256: "14289bb53fcc86e7d6166aa94d2b8fbe4a0aec70f5502d05b45de9dd4f3c92b9"),
        ]
    }()
}

public enum DailyActivityIntegrityError: Error, CustomStringConvertible {
    case unreadable(String)
    case sizeMismatch(expected: Int64, actual: Int64)
    case digestMismatch
    case unreviewedSource

    public var description: String {
        switch self {
        case .unreadable(let path): return "无法读取已审查的日常原片：\(path)"
        case .sizeMismatch(let expected, let actual):
            return "已审查的日常原片长度不符（期望 \(expected) 字节，实际 \(actual) 字节）"
        case .digestMismatch: return "已审查的日常原片内容校验不通过"
        case .unreviewedSource: return "该日常原片未经过进入活动审查，不能进入。"
        }
    }
}

public enum DailyActivityIntegrity {
    private static let chunkSize = 1_048_576

    /// Verify a source against the reviewed identity bound to its own key. An unqualified
    /// combination has no identity and can never be verified (checked before any read).
    public static func verify(url: URL, sourceKey: ContentKey) throws {
        guard let identity = DailyActivitySourceIdentity.reviewed(for: sourceKey) else {
            throw DailyActivityIntegrityError.unreviewedSource
        }
        try verify(url: url, identity: identity)
    }

    /// Stream the chosen file and compare BOTH its size and full SHA-256. Runs off the UI queue;
    /// cancellation is checked per chunk so a superseded entry stops reading promptly. The caller
    /// keeps the directory access lease alive for the whole call.
    public static func verify(url: URL, identity: DailyActivitySourceIdentity) throws {
        try Task.checkCancellation()
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw DailyActivityIntegrityError.unreadable(url.lastPathComponent)
        }
        defer { try? handle.close() }
        let actualSize: Int64
        do {
            actualSize = Int64(try handle.seekToEnd())
            try handle.seek(toOffset: 0)
        } catch {
            throw DailyActivityIntegrityError.unreadable(url.lastPathComponent)
        }
        guard actualSize == identity.byteSize else {
            throw DailyActivityIntegrityError.sizeMismatch(expected: identity.byteSize, actual: actualSize)
        }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            let data: Data
            do {
                data = try handle.read(upToCount: chunkSize) ?? Data()
            } catch {
                throw DailyActivityIntegrityError.unreadable(url.lastPathComponent)
            }
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == identity.sha256 else { throw DailyActivityIntegrityError.digestMismatch }
    }
}
