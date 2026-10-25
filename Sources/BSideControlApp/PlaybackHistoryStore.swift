// BSideControlApp — concrete Foundation file store for the confirmed-interval ledger.
//
// One synchronous serial owner: every operation runs on the caller's thread in order and no write
// is asynchronous. The URL is caller-supplied by the production controller or isolated tests.
// The current ledger is private and there is deliberately no API that saves an
// arbitrary caller-supplied whole-ledger snapshot — every mutation is validated by Core first.
//
// A successful operation is only reported after the file was written; if the write fails the
// in-memory ledger and the on-disk file both keep their last valid state. Missing file loads the
// empty, recording-disabled ledger; corrupt or unsupported-version data throws without overwriting.

import Foundation
import BSideCore

final class PlaybackHistoryStore {

    enum StoreError: Error, Equatable {
        case corruptFile
        case unsupportedVersion(Int)
    }

    let fileURL: URL
    private(set) var ledger: PlaybackHistoryLedger

    init(fileURL: URL) throws {
        self.fileURL = fileURL
        self.ledger = try Self.load(from: fileURL)
    }

    // MARK: - Mutations (persist atomically before reporting success)

    func setRecording(_ enabled: Bool) throws {
        var candidate = ledger
        guard candidate.setRecording(enabled) else { return }
        try commit(candidate)
    }

    @discardableResult
    func beginCapture(channel: PlaybackChannel, session: String, generation: Int) throws -> Bool {
        var candidate = ledger
        guard candidate.beginCapture(channel: channel, session: session, generation: generation) else {
            return false
        }
        try commit(candidate)
        return true
    }

    @discardableResult
    func submit(_ submission: PlaybackIntervalSubmission) throws -> PlaybackHistorySubmissionResult {
        var candidate = ledger
        let result = candidate.submit(submission)
        if case .accepted = result { try commit(candidate) }
        return result
    }

    /// Apply one whole Agent report under a verified token. A stale epoch/session is rejected
    /// without writing; a capture context is rebound only for a STRICTLY newer source generation
    /// per channel (never from stale input). Every accepted span in the report is committed in
    /// ONE atomic write, regardless of how many spans arrived.
    @discardableResult
    func ingest(
        _ submissions: [PlaybackIntervalSubmission], expected: HistoryRecordingRequest
    ) throws -> [PlaybackHistorySubmissionResult] {
        var candidate = ledger
        guard expected.enabled, candidate.isRecording, candidate.epoch == expected.epoch else {
            return submissions.map { _ in .rejected(.staleEpoch) }
        }
        var results: [PlaybackHistorySubmissionResult] = []
        var acceptedAny = false
        for submission in submissions {
            guard submission.epoch == expected.epoch, submission.session == expected.session else {
                results.append(.rejected(
                    submission.epoch == expected.epoch ? .staleContext : .staleEpoch))
                continue
            }
            if let context = candidate.contexts.first(where: { $0.channel == submission.channel }) {
                // Compare the SESSION first (the expected token was already verified above). A
                // different session is a restart/rebind, not a stale generation: a fresh session
                // may legitimately start at generation 1 even when the previous session reached a
                // higher generation. Generation ordering only applies within one session.
                if context.session != submission.session {
                    _ = candidate.beginCapture(channel: submission.channel,
                                               session: expected.session,
                                               generation: submission.generation)
                } else if submission.generation < context.generation {
                    results.append(.rejected(.staleContext))
                    continue
                } else if submission.generation > context.generation {
                    _ = candidate.beginCapture(channel: submission.channel,
                                               session: expected.session,
                                               generation: submission.generation)
                }
            } else {
                _ = candidate.beginCapture(channel: submission.channel,
                                           session: expected.session,
                                           generation: submission.generation)
            }
            let result = candidate.submit(submission)
            if case .accepted = result { acceptedAny = true }
            results.append(result)
        }
        if acceptedAny { try commit(candidate) }
        return results
    }

    func crop(retainingAfter cutoff: Date) throws {
        var candidate = ledger
        guard candidate.crop(retainingAfter: cutoff) else { return }
        try commit(candidate)
    }

    func clear() throws {
        var candidate = ledger
        _ = candidate.clear()
        try commit(candidate)
    }

    /// Flush the confirmed ledger as-is. Takes no clock and has no open tail to advance.
    func checkpoint() throws {
        try Self.write(ledger, to: fileURL)
    }

    /// Write the raw versioned records to a caller-supplied URL. Deliberately excludes capture
    /// contexts already; the encoded ledger carries no file paths, bookmarks, user or device ids.
    func export(to url: URL) throws {
        try Self.write(ledger, to: url)
    }

    // MARK: - Persistence

    private func commit(_ candidate: PlaybackHistoryLedger) throws {
        try Self.write(candidate, to: fileURL)
        ledger = candidate
    }

    private static func write(_ ledger: PlaybackHistoryLedger, to url: URL) throws {
        let data = try JSONEncoder().encode(ledger)
        try data.write(to: url, options: .atomic)
    }

    private static func load(from url: URL) throws -> PlaybackHistoryLedger {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return PlaybackHistoryLedger()
        }
        guard let data = try? Data(contentsOf: url) else { throw StoreError.corruptFile }
        guard let version = try? JSONDecoder().decode(LedgerVersion.self, from: data) else {
            throw StoreError.corruptFile
        }
        guard version.version == PlaybackHistoryLedger.currentVersion else {
            throw StoreError.unsupportedVersion(version.version)
        }
        do {
            return try JSONDecoder().decode(PlaybackHistoryLedger.self, from: data)
        } catch {
            throw StoreError.corruptFile
        }
    }

    private struct LedgerVersion: Decodable {
        let version: Int
    }
}
