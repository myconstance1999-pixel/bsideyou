import Foundation
import Darwin
import BSideCore

public extension DailyAssetIssue {
    /// Preserve a useful, path-free reason across process/UI boundaries. Foundation can wrap
    /// a POSIX cause, so inspect a bounded chain without relying on localized error wording.
    static func classify(_ error: Error) -> Self {
        var current: Error? = error
        var seen: Set<ObjectIdentifier> = []
        for _ in 0..<8 {
            guard let error = current else { break }
            if let validation = error as? AssetValidationError {
                switch validation {
                case .directoryNotFound: return .missingLocation
                case .notDirectory, .layoutNotRecognized: return .unsupportedLayout
                case .ambiguousLayouts: return .ambiguousLayouts
                case .noContentFound: return .noDailyContent
                }
            }
            let system = error as NSError
            guard seen.insert(ObjectIdentifier(system)).inserted else { break }
            if system.domain == NSCocoaErrorDomain {
                switch system.code {
                case CocoaError.Code.fileNoSuchFile.rawValue, CocoaError.Code.fileReadNoSuchFile.rawValue:
                    return .missingLocation
                case CocoaError.Code.fileReadNoPermission.rawValue, CocoaError.Code.fileWriteNoPermission.rawValue:
                    return .accessDenied
                default: break
                }
            } else if system.domain == NSPOSIXErrorDomain {
                switch system.code {
                case Int(ENOENT): return .missingLocation
                case Int(ENOTDIR): return .unsupportedLayout
                case Int(EACCES), Int(EPERM): return .accessDenied
                default: break
                }
            }
            current = system.userInfo[NSUnderlyingErrorKey] as? Error
        }
        return .readFailed
    }
}
