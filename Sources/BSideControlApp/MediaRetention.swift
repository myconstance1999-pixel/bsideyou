import Foundation
import BSideCore
import BSidePlatform

/// Explicit, reviewed choices over existing identities. This file is separate from preferences
/// and catalogs: loading or rescanning never rewrites user selection, queue or history records.
struct MediaRetentionDocument: Codable, Equatable {
    struct Official: Codable, Equatable {
        let performanceID: String
        let catalogRevision: PerformanceCatalogRevision
        let retainedVariantID: String
    }
    struct Local: Codable, Equatable {
        let trackID: String
        let retainedFileID: String
        let binding: PerformanceFileBinding
    }
    let version: Int
    let official: [Official]
    let local: [Local]

    var structuralProblem: String? {
        guard version == 1 else { return "unsupported version \(version)" }
        func usable(_ value: String) -> Bool { !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard Set(official.map(\.performanceID)).count == official.count,
              Set(local.map(\.trackID)).count == local.count else { return "duplicate song identity" }
        guard official.allSatisfy({ usable($0.performanceID) && usable($0.retainedVariantID)
            && usable($0.catalogRevision.rawValue) }) else { return "empty official identity" }
        guard local.allSatisfy({ usable($0.trackID) && usable($0.retainedFileID)
            && LocalFileVerifier.isValidRelativePath($0.binding.relativePath, allowEmpty: false)
            && $0.binding.byteSize > 0 && $0.binding.sha256.count == 64
            && $0.binding.sha256.allSatisfy({ "0123456789abcdef".contains($0) }) }) else {
            return "invalid retained file identity"
        }
        return nil
    }

    func catalogProblem(library: PerformanceLibrary?, localCatalog: LocalSongCatalog?) -> String? {
        if let structuralProblem { return structuralProblem }
        for choice in official {
            guard let library, choice.catalogRevision == library.snapshot.revision,
                  let track = library.snapshot.track(for: PerformanceID(choice.performanceID)),
                  track.variants.contains(where: { $0.id.rawValue == choice.retainedVariantID }) else {
                return "official choice does not match the current catalog: \(choice.performanceID)"
            }
        }
        for choice in local {
            guard let track = localCatalog?.track(id: choice.trackID),
                  let file = track.files.first(where: { $0.id == choice.retainedFileID }),
                  file.relativePath == choice.binding.relativePath else {
                return "local choice does not match the current catalog: \(choice.trackID)"
            }
            // A reviewed binding can establish an as-yet-unplayed keeper, but cannot replace a
            // fingerprint that the catalog has already committed for that same file.
            if let digest = file.sha256,
               digest != choice.binding.sha256 || file.fingerprintByteSize != choice.binding.byteSize {
                return "retained file conflicts with its saved fingerprint: \(choice.trackID)"
            }
        }
        return nil
    }
}

enum MediaRetentionState: Equatable {
    case absent
    case loaded(MediaRetentionDocument)
    case invalid(String)

    static let url = AppPaths.applicationSupport.appendingPathComponent("media-retention.json")

    static func load(from url: URL = Self.url) -> Self {
        do {
            let document = try JSONDecoder().decode(MediaRetentionDocument.self, from: Data(contentsOf: url))
            if let problem = document.structuralProblem { return .invalid(problem) }
            return .loaded(document)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .absent
        } catch {
            return .invalid("unable to read the reviewed choices: \(error)")
        }
    }

    var document: MediaRetentionDocument? {
        if case .loaded(let document) = self { return document }
        return nil
    }
}

struct RetainedLocalPlaybackChoice {
    let file: LocalSongFile
    let expectedBinding: PerformanceFileBinding?
}

extension PerformanceBrowserModel {
    func refreshRetentionValidation() {
        let problem: String?
        switch mediaRetention {
        case .absent: problem = nil
        case .invalid(let detail): problem = detail
        case .loaded(let document): problem = document.catalogProblem(library: library, localCatalog: localCatalog)
        }
        retentionProblem = problem.map { "歌曲保留方案不可用，请检查方案后重新检查曲库。\n\($0)" }
    }

    func retainedOfficialVariant(_ id: String) -> ResolvedPerformanceVariant? {
        guard retentionProblem == nil, let library,
              let choice = mediaRetention.document?.official.first(where: { $0.performanceID == id }),
              let track = library.snapshot.track(for: PerformanceID(id)),
              let keeper = track.variants.first(where: { $0.id.rawValue == choice.retainedVariantID }),
              case .resolved(let resolved) = VariantResolver.resolve(trackID: track.id, in: library.snapshot,
                effectiveLighting: keeper.lighting, presentationPreference: .explicit(keeper.presentation)) else { return nil }
        return resolved
    }

    func localPlaybackChoice(trackID: String, requestedFileID: String?) throws -> RetainedLocalPlaybackChoice {
        if let retentionProblem { throw LocalSongError.invalidBinding(retentionProblem) }
        guard let track = localTrack(trackID) else { throw LocalSongError.unknownTrack(trackID) }
        // A saved source reference must still belong to this song, even when its file is retired.
        if let requestedFileID, !track.files.contains(where: { $0.id == requestedFileID }) {
            throw LocalSongError.unknownFile(requestedFileID)
        }
        let choice = mediaRetention.document?.local.first { $0.trackID == trackID }
        guard let id = choice?.retainedFileID ?? requestedFileID,
              let file = track.files.first(where: { $0.id == id }) else {
            throw LocalSongError.unknownFile(requestedFileID ?? "")
        }
        return RetainedLocalPlaybackChoice(file: file, expectedBinding: choice?.binding)
    }

    func displayedLocalFile(_ track: LocalSongTrack) -> LocalSongFile? {
        try? localPlaybackChoice(trackID: track.id, requestedFileID: track.selectedFileID).file
    }

    func displayedLocalFiles(_ track: LocalSongTrack) -> [LocalSongFile] {
        guard mediaRetention.document?.local.contains(where: { $0.trackID == track.id }) == true else {
            return track.sortedFiles
        }
        return displayedLocalFile(track).map { [$0] } ?? []
    }

    func localPlaybackProblem(_ track: LocalSongTrack, fileID: String?) -> String? {
        if let retentionProblem { return retentionProblem }
        guard let root = localCatalog?.root(id: track.rootID) else { return "歌曲记录不存在。" }
        if root.isMissing { return "歌曲目录当前不可用：\(root.displayPath)" }
        guard let choice = try? localPlaybackChoice(trackID: track.id, requestedFileID: fileID) else {
            return "这首曲目没有可用的文件。"
        }
        guard choice.file.isPresent else { return "所选文件当前不可用：\(choice.file.basename)" }
        if let expected = choice.expectedBinding, let size = choice.file.byteSize, size != expected.byteSize {
            return "保留的歌曲文件已改变，请重新检查。"
        }
        return nil
    }

    /// Only intentionally retired cells are omitted. Unknown choices fail validation rather
    /// than suppressing a missing keeper or weakening the full manifest's admission contract.
    var requiredOfficialVariantIDs: Set<String> {
        guard let library else { return [] }
        return Set(library.manifest.tracks.flatMap { track in
            if let keeper = retainedOfficialVariant(track.id) { return [keeper.variantID.rawValue] }
            return track.variants.map(\.id)
        })
    }

    var requiredUnavailableVariants: [String: String] {
        guard mediaRetention.document != nil else { return unavailable }
        let required = requiredOfficialVariantIDs
        return unavailable.filter { required.contains($0.key) }
    }

    func historyPlaybackTarget(_ record: SongPlaybackRecord) throws -> (PerformancePlaybackTarget, PerformanceFileBinding?) {
        if let retentionProblem { throw LocalSongError.invalidBinding(retentionProblem) }
        switch record.target {
        case .catalog(let original):
            guard let library else { throw PerformanceAssetError.invalidManifest("演奏清单不可用") }
            _ = try library.record(for: original)
            return (.catalog(retainedOfficialVariant(original.performanceID.rawValue) ?? original), nil)
        case .localFile(let original):
            guard original.isUsable, let savedBinding = record.fileBinding else {
                throw LocalSongError.invalidBinding("saved history identity is incomplete")
            }
            let choice = try localPlaybackChoice(trackID: original.trackID, requestedFileID: original.fileID)
            let binding = choice.expectedBinding ?? savedBinding
            guard let localCatalog else { throw LocalSongError.unknownTrack(original.trackID) }
            return (.localFile(LocalPerformanceReference(trackID: original.trackID, fileID: choice.file.id,
                catalogRevision: localCatalog.catalogRevision)), binding)
        }
    }
}
