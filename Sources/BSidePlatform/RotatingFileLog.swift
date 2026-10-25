// BSidePlatform — RotatingFileLog: write-triggered, size-bounded rotation for the
// app-owned plaintext logs (control.log / agent.log). An append that would push the
// active file beyond 5 MiB first rotates it to <name>.1 (replacing any older .1), so
// each logical log holds at most active + one backup. Rotation happens only inside
// appends — never on a timer or poll. Every operation fails soft: a rotation or write
// problem is swallowed and the append is still attempted, so logging can never crash
// the app.

import Foundation

/// Size-bounded plaintext log at `url` that keeps exactly one previous generation.
///
/// Invariants (all enforced inside `append`, under one lock):
///  - the active file never exceeds `maxFileSize` after an append (a rotate happens
///    *before* the append that would cross the bound);
///  - at most two files exist per logical log: `name` (active) and `name.1` (backup);
///  - rotation replaces any older `.1`, never accumulating a `.2`/`.3`;
///  - failures (missing file, unreadable size, blocked rename, unwritable handle) are
///    swallowed — `append` never throws and never crashes the caller.
///
/// `control.log` and `agent.log` each get their own instance, so rotating one never
/// affects the other.
public final class RotatingFileLog {
    /// Rotation bound: 5 MiB. The active log is rotated before an append would take it
    /// beyond this size, so the active file is at most 5 MiB after every append.
    public static let maxFileSize: UInt64 = 5 * 1024 * 1024

    private let activeURL: URL
    private let backupURL: URL
    private let lock = NSLock()

    public init(url: URL) {
        self.activeURL = url
        self.backupURL = url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + ".1")
    }

    /// Append `data` (usually one newline-terminated line), rotating first when needed.
    public func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }

        let fm = FileManager.default
        // Preserve create-on-first-append behavior for a missing active file.
        if !fm.fileExists(atPath: activeURL.path) {
            fm.createFile(atPath: activeURL.path, contents: nil)
        }

        if size(of: activeURL) + UInt64(data.count) > Self.maxFileSize {
            rotate(fm: fm)
            // A failed move must not leave the active file missing for the append below.
            if !fm.fileExists(atPath: activeURL.path) {
                fm.createFile(atPath: activeURL.path, contents: nil)
            }
        }

        // Open-per-append keeps the original file-handle lifecycle while making every
        // append an explicit rotation checkpoint (no long-lived fd to bypass the bound).
        guard let handle = try? FileHandle(forWritingTo: activeURL) else { return }
        handle.seekToEndOfFile()
        try? handle.write(contentsOf: data)
        try? handle.close()
    }

    /// Best-effort rotation: drop any older `.1`, then move the active file into its place.
    private func rotate(fm: FileManager) {
        try? fm.removeItem(at: backupURL)
        try? fm.moveItem(at: activeURL, to: backupURL)
    }

    private func size(of url: URL) -> UInt64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return 0 }
        return size.uint64Value
    }
}