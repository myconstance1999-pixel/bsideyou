import SwiftUI
import BSideCore

extension PerformanceBrowserModel {
    func queueEntry(for record: SongPlaybackRecord) -> PerformanceQueueEntry {
        switch record.target {
        case .catalog(let variant):
            return PerformanceQueueEntry(id: "history-\(record.id)", performanceID: variant.performanceID,
                presentation: variant.presentation, mode: record.mode)
        case .localFile(let reference):
            return PerformanceQueueEntry(id: "history-\(record.id)", trackID: reference.trackID,
                fileID: reference.fileID, mode: record.mode)
        }
    }
    func songHistoryTitle(_ record: SongPlaybackRecord) -> String {
        switch record.target {
        case .catalog(let variant):
            return library?.manifest.tracks.first { $0.id == variant.performanceID.rawValue }?.title ?? record.title
        case .localFile(let reference):
            return localTrack(reference.trackID)?.displayTitle ?? record.title
        }
    }
    func songHistoryUnavailableReason(_ record: SongPlaybackRecord) -> String? {
        if let retentionProblem { return retentionProblem }
        guard let (target, binding) = try? historyPlaybackTarget(record) else { return "保存的歌曲身份或保留版本不可用" }
        switch target {
        case .catalog(let variant):
            guard let library, (try? library.record(for: variant)) != nil else { return "保存的官方版本不可用" }
            guard root != nil, scanned else { return "请先检查官方歌曲目录" }
            return unavailable[variant.variantID.rawValue]
        case .localFile(let reference):
            guard let track = localTrack(reference.trackID),
                  let file = track.files.first(where: { $0.id == reference.fileID }),
                  let root = localCatalog?.root(id: track.rootID), !root.isMissing,
                  root.bookmark != nil, file.isPresent else { return "保存的歌曲文件或目录不可用" }
            if mediaRetention.document?.local.contains(where: { $0.trackID == reference.trackID }) == true,
               let problem = localPlaybackProblem(track, fileID: reference.fileID) { return problem }
            guard let binding, file.relativePath == binding.relativePath,
                  (file.sha256 == binding.sha256 && file.fingerprintByteSize == binding.byteSize)
                    || (mediaRetention.document?.local.contains(where: { $0.trackID == reference.trackID }) == true
                        && file.sha256 == nil && file.fingerprintByteSize == nil) else {
                return "保存的文件版本与当前记录不一致"
            }
            return nil
        }
    }
}

struct SongPlaybackHistoryView: View {
    @ObservedObject var model: PerformanceBrowserModel
    var compact = false
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: compact ? 8 : 12) {
                if let playbackError = model.songHistoryPlaybackError {
                    Text(playbackError).font(.caption)
                }
                if let error = model.songHistoryError {
                    Text(error).font(.caption)
                    Button("重试读取", action: model.retrySongHistory)
                        .accessibilityIdentifier("song-history-retry")
                }
                if model.songHistory.isEmpty {
                    Text("还没有播放历史").font(.callout)
                    Text("歌曲开始播放后会显示在这里，最多保留最近 200 条。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(model.songHistory) { record in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.songHistoryTitle(record)).font(.callout).lineLimit(compact ? 1 : 2)
                            Text(record.lastPlayed, format: .dateTime.month().day().hour().minute())
                                .font(.caption).foregroundStyle(.secondary)
                            if let reason = model.songHistoryUnavailableReason(record) {
                                Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(compact ? 2 : 3)
                            } else if !compact {
                                Text(model.queueEntryDetail(model.queueEntry(for: record)))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 2)
                        Button { model.replaySongHistory(record) } label: {
                            Image(systemName: "play.fill")
                        }
                        .buttonStyle(.borderless)
                        .frame(width: 28, height: 28)
                        .disabled(model.songHistoryUnavailableReason(record) != nil)
                        .accessibilityLabel("重新播放：\(model.songHistoryTitle(record))")
                        .accessibilityIdentifier("song-history-play-\(record.id)")
                    }
                    .accessibilityElement(children: .contain)
                }
            }
            .padding(compact ? 2 : 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("song-history-list")
    }
}

struct SongQueueSelector: View {
    @ObservedObject var model: PerformanceBrowserModel
    var body: some View {
        Picker("队列或历史", selection: $model.showingSongHistory) {
            Text("播放队列").tag(false)
            Text("播放历史").tag(true)
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("song-queue-history-selector")
    }
}
