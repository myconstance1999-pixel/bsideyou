// BSideTestRunner — RotatingFileLog regression suites (log-rotation slice).
// Deterministic temp-directory tests: never reads official media and never touches the
// real Application Support directory. Exercises the production 5 MiB bound with real
// bytes, and every failure path that is safely testable in-process.

import Foundation
import Darwin
import BSidePlatform

private enum LogRotationFixture {
    static func freshTempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bsidemac-logrot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static let lineBytes = 4096
    /// Lines it takes to fill the active file to exactly 5 MiB (1280).
    static let exactLines = Int(RotatingFileLog.maxFileSize) / lineBytes

    /// One deterministic newline-terminated line of exactly `lineBytes` bytes; the index
    /// lets content-level assertions identify which generation a file holds.
    static func line(_ index: Int) -> Data {
        let head = String(format: "line-%05d-", index)
        let pad = String(repeating: "x", count: lineBytes - head.utf8.count - 1)
        return Data((head + pad + "\n").utf8)
    }

    static func size(of url: URL) -> UInt64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return 0 }
        return size.uint64Value
    }

    /// Append `count` lines starting at `startIndex` (active ends at count × lineBytes).
    static func fill(_ log: RotatingFileLog, _ count: Int, startIndex: Int) {
        for i in 0..<count { log.append(line(startIndex + i)) }
    }
}

/// Redirects fd 2 to a fresh O_APPEND temp file for the duration of `body`, then restores it.
/// O_APPEND keeps concurrent records atomic so the writer-ownership suites can prove stderr
/// diagnostics survive a disowned file sink. Test-only; never used by production code.
private enum StderrCapture {
    static func capture(_ body: () -> Void) -> Data {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bsidemac-stderr-capture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { return Data() }
        let fd = open(url.path, O_WRONLY | O_APPEND)
        guard fd >= 0 else { return Data() }
        let saved = dup(STDERR_FILENO)
        guard saved >= 0 else { close(fd); return Data() }
        dup2(fd, STDERR_FILENO)
        body()
        fsync(fd)
        dup2(saved, STDERR_FILENO)
        close(saved)
        close(fd)
        return (try? Data(contentsOf: url)) ?? Data()
    }
}

func runLogRotationTests() {
    run("Log.rotationBoundIsFiveMiB") { t in
        t.expectEqual(RotatingFileLog.maxFileSize, 5 * 1024 * 1024, "production rotation bound is 5 MiB")
    }

    run("Log.rotationBelowThresholdAppendsWithoutRotating") { t in
        do {
            let root = try LogRotationFixture.freshTempRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let url = root.appendingPathComponent("control.log")
            let log = RotatingFileLog(url: url)

            LogRotationFixture.fill(log, LogRotationFixture.exactLines - 1, startIndex: 0)   // 1279 lines
            t.expectEqual(LogRotationFixture.size(of: url),
                          UInt64((LogRotationFixture.exactLines - 1) * LogRotationFixture.lineBytes),
                          "1279 lines stay below the bound")
            t.expect(!FileManager.default.fileExists(atPath: url.path + ".1"), "no .1 below the bound")

            log.append(LogRotationFixture.line(1_000_000))   // lands at exactly 5 MiB — not beyond
            t.expectEqual(LogRotationFixture.size(of: url),
                          UInt64(LogRotationFixture.exactLines * LogRotationFixture.lineBytes),
                          "exactly 5 MiB is still allowed (rotation only when beyond)")
            t.expect(!FileManager.default.fileExists(atPath: url.path + ".1"), "no .1 at exactly 5 MiB")

            let text = String(data: try Data(contentsOf: url), encoding: .utf8) ?? ""
            t.expect(text.hasPrefix(String(data: LogRotationFixture.line(0), encoding: .utf8)!),
                     "first line preserved in order")
            t.expect(text.hasSuffix(String(data: LogRotationFixture.line(1_000_000), encoding: .utf8)!),
                     "last line preserved in order")
        } catch {
            t.expect(false, "unexpected throw: \(error)")
        }
    }

    run("Log.rotationCrossingThresholdRotatesAndActiveAcceptsTrigger") { t in
        do {
            let root = try LogRotationFixture.freshTempRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let url = root.appendingPathComponent("control.log")
            let log = RotatingFileLog(url: url)

            LogRotationFixture.fill(log, LogRotationFixture.exactLines, startIndex: 0)   // exactly 5 MiB
            log.append(LogRotationFixture.line(2_000_000))                               // triggering line

            t.expect(FileManager.default.fileExists(atPath: url.path + ".1"), "crossing the bound rotated")
            t.expectEqual(LogRotationFixture.size(of: url), UInt64(LogRotationFixture.lineBytes),
                          "new active holds only the triggering line")
            t.expectEqual(LogRotationFixture.size(of: URL(fileURLWithPath: url.path + ".1")),
                          UInt64(LogRotationFixture.exactLines * LogRotationFixture.lineBytes),
                          "backup holds the full previous generation")

            let active = try Data(contentsOf: url)
            t.expectEqual(active, LogRotationFixture.line(2_000_000),
                          "active content is exactly the triggering line")
            let backup = try Data(contentsOf: URL(fileURLWithPath: url.path + ".1"))
            t.expect(backup.starts(with: LogRotationFixture.line(0)), "backup starts with the original first line")
        } catch {
            t.expect(false, "unexpected throw: \(error)")
        }
    }

    run("Log.rotationReplacesOlderBackupAtMostOneGeneration") { t in
        do {
            let root = try LogRotationFixture.freshTempRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let url = root.appendingPathComponent("control.log")
            let log = RotatingFileLog(url: url)

            LogRotationFixture.fill(log, LogRotationFixture.exactLines, startIndex: 0)
            log.append(LogRotationFixture.line(2_000_000))                                  // rotation 1
            t.expectEqual(LogRotationFixture.size(of: url), UInt64(LogRotationFixture.lineBytes),
                          "rotation 1 left a fresh active")

            // Keep appending until rotation 2 replaces the older .1 with the immediate
            // previous generation. Bounded so a failure fails the test, never hangs it.
            var rotations = 1
            var triggerIndex = 0
            var index = 3_000_000
            while rotations < 2 && index < 3_000_000 + 5000 {
                let before = LogRotationFixture.size(of: url)
                let current = index
                log.append(LogRotationFixture.line(current))
                index += 1
                if before + UInt64(LogRotationFixture.lineBytes) > RotatingFileLog.maxFileSize {
                    rotations += 1
                    triggerIndex = current
                }
            }

            t.expectEqual(rotations, 2, "a second rotation happened")
            let backup = try Data(contentsOf: URL(fileURLWithPath: url.path + ".1"))
            t.expect(backup.starts(with: LogRotationFixture.line(2_000_000)),
                     "replaced .1 begins with the immediate previous generation (not the original)")
            t.expect(backup.suffix(LogRotationFixture.lineBytes) == LogRotationFixture.line(triggerIndex - 1),
                     "replaced .1 ends with the generation just before the triggering line")
            t.expectEqual(LogRotationFixture.size(of: url), UInt64(LogRotationFixture.lineBytes),
                          "new active holds only the newest triggering line")
            t.expectEqual(try Data(contentsOf: url), LogRotationFixture.line(triggerIndex),
                          "active content is exactly the newest triggering line")

            let names = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
            t.expectEqual(names, ["control.log", "control.log.1"],
                          "exactly active + one backup persisted (no .2/.3)")
        } catch {
            t.expect(false, "unexpected throw: \(error)")
        }
    }

    run("Log.rotationIndependentLogicalLogs") { t in
        do {
            let root = try LogRotationFixture.freshTempRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let control = RotatingFileLog(url: root.appendingPathComponent("control.log"))
            let agent = RotatingFileLog(url: root.appendingPathComponent("agent.log"))

            let marker = Data("agent-marker-42\n".utf8)
            agent.append(marker)
            LogRotationFixture.fill(control, LogRotationFixture.exactLines, startIndex: 10_000_000)
            control.append(LogRotationFixture.line(11_000_000))                            // rotate control only

            t.expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("control.log.1").path),
                     "control.log rotated")
            t.expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("agent.log.1").path),
                     "agent.log untouched by control rotation")
            t.expectEqual(LogRotationFixture.size(of: root.appendingPathComponent("agent.log")),
                          UInt64(marker.count), "agent.log content unchanged")
            t.expectEqual(try Data(contentsOf: root.appendingPathComponent("agent.log")), marker,
                          "agent.log bytes identical")
        } catch {
            t.expect(false, "unexpected throw: \(error)")
        }
    }

    run("Log.rotationHostileBackupFailsSoft") { t in
        do {
            let root = try LogRotationFixture.freshTempRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let url = root.appendingPathComponent("control.log")
            // Occupy the .1 slot with a non-empty directory — an adversarial state that
            // must resolve without throwing, crashing, or accumulating extra backups.
            let blocker = URL(fileURLWithPath: url.path + ".1")
            try FileManager.default.createDirectory(at: blocker.appendingPathComponent("junk"),
                                                    withIntermediateDirectories: true)

            let log = RotatingFileLog(url: url)
            LogRotationFixture.fill(log, LogRotationFixture.exactLines, startIndex: 20_000_000)  // active at 5 MiB
            let trigger = LogRotationFixture.line(21_000_000)
            log.append(trigger)    // crossing the bound with a hostile .1 — must not throw/crash

            t.expect(FileManager.default.fileExists(atPath: url.path), "active file still present")
            let active = try Data(contentsOf: url)
            t.expect(active == trigger || active.suffix(LogRotationFixture.lineBytes) == trigger,
                     "triggering line is recorded in the active log")
            let backup = try Data(contentsOf: URL(fileURLWithPath: url.path + ".1"))
            t.expectEqual(backup.count, LogRotationFixture.exactLines * LogRotationFixture.lineBytes,
                          ".1 resolved to a file holding the full previous generation")
            t.expect(backup.starts(with: LogRotationFixture.line(20_000_000)),
                     "backup content is the immediate previous generation")

            let names = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
            t.expectEqual(names, ["control.log", "control.log.1"],
                          "hostile .1 still resolves to exactly active + one backup (no .2/.3)")
        } catch {
            t.expect(false, "unexpected throw: \(error)")
        }
    }

    run("Log.rotationWriteFailureFailsSoft") { t in
        do {
            let root = try LogRotationFixture.freshTempRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            // Active path occupied by a directory: the size read and handle-open both fail.
            let dirURL = root.appendingPathComponent("control.log", isDirectory: true)
            try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)

            let log = RotatingFileLog(url: dirURL)
            log.append(Data("would-be-line\n".utf8))          // must not throw or crash

            t.expect(FileManager.default.fileExists(atPath: dirURL.path),
                     "directory untouched by the failed append")
            t.expectEqual(LogRotationFixture.size(of: URL(fileURLWithPath: dirURL.path + ".1")), 0,
                          "no backup was created")
        } catch {
            t.expect(false, "unexpected throw: \(error)")
        }
    }

    // MARK: - Writer ownership (log-record integrity)

    // `control.log` may have exactly one writer process. RotatingFileLog serializes only inside
    // its own instance, and its open + seek-to-end + write is not atomic across instances, so a
    // second process can resolve a stale end offset and overwrite a concurrent record. These
    // suites pin the ownership contract that removes the second writer.

    run("Log.controlLogSingleWriterPreservesEveryRecord") { t in
        do {
            let root = try LogRotationFixture.freshTempRoot()
            defer {
                try? FileManager.default.removeItem(at: root)
                AppLog.setControlLogOwnership(false)   // never resolve the real support path in tests
            }
            let url = root.appendingPathComponent("control.log")
            AppLog.setControlLogOwnership(true, url: url)

            let writers = 8
            let perWriter = 32
            let group = DispatchGroup()
            let queue = DispatchQueue(label: "log-single-writer", attributes: .concurrent)
            let captured = StderrCapture.capture {
                for writer in 0..<writers {
                    queue.async(group: group) {
                        for record in 0..<perWriter {
                            AppLog.control("record-\(writer)-\(record) performance.report state=ended")
                        }
                    }
                }
                group.wait()
            }

            let data = try Data(contentsOf: url)
            let text = String(decoding: data, as: UTF8.self)
            let fields = text.split(separator: "\n", omittingEmptySubsequences: false)
            let lines = fields.dropLast()   // the trailing newline leaves one empty field
            t.expect(fields.last?.isEmpty == true, "control.log ends on a complete record boundary")
            t.expectEqual(lines.count, writers * perWriter, "exactly one intact line per emitted record")

            let expected = Set((0..<writers).flatMap { w in (0..<perWriter).map { "record-\(w)-\($0)" } })
            var seen = Set<String>()
            var malformed = 0
            for line in lines {
                guard line.hasPrefix("["), line.contains("] [CTRL] "), line.hasSuffix("state=ended"),
                      let tokenRange = line.range(of: "record-") else { malformed += 1; continue }
                let token = String(line[tokenRange.lowerBound...].prefix { $0 != " " })
                if expected.contains(token) { seen.insert(token) } else { malformed += 1 }
            }
            t.expectEqual(malformed, 0, "no overwritten prefix or concatenated fragment survived")
            t.expectEqual(seen.count, expected.count, "every distinct record present exactly once")
            t.expect(!FileManager.default.fileExists(atPath: url.path + ".1"),
                     "one writer stays well below the 5 MiB rotation bound")
            t.expect(String(decoding: captured, as: UTF8.self).contains("[CTRL] record-0-0"),
                     "the owning process still emits every record to stderr as well")
        } catch {
            t.expect(false, "unexpected throw: \(error)")
        }
    }

    run("Log.agentRoleNeverClaimsSharedControlLog") { t in
        do {
            let root = try LogRotationFixture.freshTempRoot()
            defer {
                try? FileManager.default.removeItem(at: root)
                AppLog.setControlLogOwnership(false)
            }
            let url = root.appendingPathComponent("control.log")
            // ControlApp role: the sole owner of control.log.
            let owner = RotatingFileLog(url: url)
            // Agent role: the file sink is relinquished; only stderr remains.
            AppLog.setControlLogOwnership(false)

            let ownerRecords = 160
            let agentRecords = 160
            let group = DispatchGroup()
            let queue = DispatchQueue(label: "log-role-ownership", attributes: .concurrent)
            let agentStderr = StderrCapture.capture {
                for i in 0..<ownerRecords {
                    queue.async(group: group) {
                        owner.append(Data("owner-\(i) performance.report state=ended\n".utf8))
                    }
                }
                for i in 0..<agentRecords {
                    queue.async(group: group) { AppLog.info("agent-marker-\(i)") }
                }
                group.wait()
            }

            let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
            let fields = text.split(separator: "\n", omittingEmptySubsequences: false)
            let lines = fields.dropLast()
            t.expect(fields.last?.isEmpty == true, "owner log ends on a complete record boundary")
            t.expectEqual(lines.count, ownerRecords, "control.log holds exactly the owner's records")
            t.expect(lines.allSatisfy { $0.hasPrefix("owner-") && $0.hasSuffix(" state=ended") },
                     "no owner record was overwritten or left fragmented")
            t.expect(!text.contains("agent-marker-"), "the agent role never appends to control.log")

            let stderrLines = String(decoding: agentStderr, as: UTF8.self)
                .split(separator: "\n").filter { $0.contains("agent-marker-") }
            t.expectEqual(stderrLines.count, agentRecords,
                          "the disowned agent still emits every diagnostic to stderr")
        } catch {
            t.expect(false, "unexpected throw: \(error)")
        }
    }

    run("Log.disownedRoleStillEmitsStderrDiagnostics") { t in
        AppLog.setControlLogOwnership(false)
        let marker = "stderr-preserved-\(UUID().uuidString)"
        let captured = StderrCapture.capture { AppLog.info(marker) }
        let text = String(decoding: captured, as: UTF8.self)
        t.expect(text.contains("[INFO] \(marker)"),
                 "a process without the control.log sink still writes the record to stderr")
    }
}