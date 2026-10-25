// BSidePlatform — first-run convenience: well-known candidate locations for the user's
// legitimately-held BSide Offline folder. UI guidance only (surfaced in the open panel and
// as a one-click menu item); business logic still only uses the URL the user confirms.
// NOTE: intentionally exempt from the arch-gate "no hardcoded asset paths" check — this is
// the single sanctioned constants file (see scripts/check_architecture.sh).

import Foundation

public enum DefaultLocations {
    public static func candidateDirectoryURLs() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Development/BSideMacLab/BSide-win64", isDirectory: true),
            home.appendingPathComponent("Documents/BSideMacLab/BSide-win64", isDirectory: true),
        ]
    }

    /// First candidate that actually exists on this machine (nil → user navigates manually).
    public static func firstExisting() -> URL? {
        candidateDirectoryURLs().first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
