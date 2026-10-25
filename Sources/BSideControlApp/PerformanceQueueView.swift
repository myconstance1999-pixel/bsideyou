// Queue presentation and action forwarding. AppDelegate owns edits, persistence and playback.
import SwiftUI
import BSideCore

extension PerformanceBrowserModel {
    var canEnqueueSelection: Bool {
        guard retentionProblem == nil else { return false }
        guard let selectedID else { return false }
        // A local row enqueues its remembered file; an official row keeps the existing rule.
        if let local = localTrack(selectedID) {
            return localSelectionProblem(local) == nil && displayedLocalFile(local) != nil
        }
        guard let track = library?.manifest.tracks.first(where: { $0.id == selectedID }) else { return false }
        // Lighting is resolved when this entry starts. A missing current candidate must
        // not prevent saving a supported camera choice for a future time of day.
        return track.variants.contains { $0.presentation == preferredPresentation(for: track.id) }
    }

    func enqueueSelection() {
        guard canEnqueueSelection, let selectedID else { return }
        if let local = localTrack(selectedID), let fileID = displayedLocalFile(local)?.id {
            // Capture the exact file now; a later preferred-version change cannot retarget it.
            enqueueLocal(local.id, fileID, playbackMode)
            return
        }
        enqueue(selectedID, preferredPresentation(for: selectedID), playbackMode)
    }

    /// The exact entry for `加入并播放`: the current selection, its exact local file version and
    /// the current mode/camera, but ONLY while it can start right now. Nil for an unknown row or a
    /// currently blocked/unavailable selection, so a one-click add-and-play can never mutate the
    /// queue or interrupt the current song for something that cannot start.
    var playableSelectionEntry: PerformanceQueueEntry? {
        guard canEnqueueSelection, selectionProblem == nil, let selectedID else { return nil }
        if let local = localTrack(selectedID), let fileID = displayedLocalFile(local)?.id {
            // The remembered explicit file is captured now; a later version change never retargets it.
            return PerformanceQueueEntry(target: .localFile(trackID: local.id, fileID: fileID),
                                         mode: playbackMode)
        }
        guard let track = library?.manifest.tracks.first(where: { $0.id == selectedID }) else { return nil }
        return PerformanceQueueEntry(target: .official(performanceID: PerformanceID(track.id),
                                                       presentation: preferredPresentation(for: track.id)), mode: playbackMode)
    }

    var canAddSelectionAndPlay: Bool { playableSelectionEntry != nil }

    /// One-click selected song: the owner appends this exact entry and starts that new entry.
    func addSelectionAndPlay() {
        guard let entry = playableSelectionEntry else { return }
        addAndPlay(entry)
    }

    /// Snapshot of ALL currently filtered library rows that are eligible right now (never a List
    /// page). Official rows capture their preferred camera and resolve under the existing readiness /
    /// scan rules; local rows keep their remembered explicit file. No media is read, decoded or
    /// hashed here — an unavailable row is simply excluded. Entry identity is derived from the
    /// unique row ID, so one snapshot can never contain a duplicate entry identity.
    ///
    /// The same snapshot feeds both list actions; the order mode is applied by the owner side.
    var visibleListSnapshot: [PerformanceQueueEntry] {
        let date = Date()
        var entries: [PerformanceQueueEntry] = []
        for row in visibleRows {
            switch row {
            case .official(let track):
                let presentation = preferredPresentation(for: track.id, at: date)
                guard playbackProblem(id: track.id, presentation: presentation, at: date) == nil else { continue }
                entries.append(PerformanceQueueEntry(id: "listed-official-\(track.id)",
                    target: .official(performanceID: PerformanceID(track.id), presentation: presentation),
                    mode: playbackMode))
            case .local(let track):
                guard localSelectionProblem(track) == nil, let fileID = displayedLocalFile(track)?.id else { continue }
                entries.append(PerformanceQueueEntry(id: "listed-local-\(track.id)",
                    target: .localFile(trackID: track.id, fileID: fileID), mode: playbackMode))
            }
        }
        return entries
    }

    /// Why 随机播放 cannot run right now; nil when the snapshot is non-empty. The action itself
    /// stays a no-op for every non-nil reason, so the old queue, order and playback are untouched.
    var filteredShuffleProblem: String? {
        guard !visibleRows.isEmpty else { return "当前筛选结果没有曲目。" }
        guard !visibleListSnapshot.isEmpty else { return "当前筛选结果没有可用素材，队列和播放保持不变。" }
        return nil
    }

    /// Library 随机播放: hand the exact snapshot to the owner. An empty snapshot is never emitted.
    func startFilteredShufflePlayback() {
        let snapshot = visibleListSnapshot
        guard !snapshot.isEmpty else { return }
        startFilteredShuffle(snapshot)
    }

    // MARK: - ADR-024 list playback

    /// The snapshot entry for one visible row, or nil when that row cannot start right now.
    /// This is what makes "explicit unavailable selection never substitutes another row" exact:
    /// the clicked row is looked up in the SAME snapshot the continuation uses.
    func listEntry(forRow id: String) -> PerformanceQueueEntry? {
        visibleListSnapshot.first { entry in
            switch entry.target {
            case .official(let performanceID, _): return performanceID.rawValue == id
            case .localFile(let trackID, _): return trackID == id
            }
        }
    }

    /// Whether 播放 is offered at all (a non-empty eligible snapshot).
    var listPlayIsAvailable: Bool { !visibleListSnapshot.isEmpty }

    /// Primary library play / row double-click: snapshot the CURRENT visible eligible rows in
    /// displayed order, start the clicked/selected row, and continue through that snapshot under
    /// the chosen existing queue mode. Browsing or filter changes after this cannot mutate it.
    ///
    /// An explicit unavailable (or unknown) row selects itself and reports the existing reason; it
    /// never starts a different row and never replaces the queue.
    func playListRow(_ id: String) {
        selectedID = id
        guard let entry = listEntry(forRow: id) else { return }
        let snapshot = visibleListSnapshot
        guard !snapshot.isEmpty else { return }
        startListPlayback(snapshot, entry.id)
    }

    /// Detail-pane 播放: the same list continuation, starting at the selected row.
    func playSelectedFromList() {
        guard let selectedID else { return }
        playListRow(selectedID)
    }

    /// Detail-pane 只播放这首: the retained single-song convenience. It keeps the existing exact
    /// single-selection dispatch and never touches the queue.
    func playSelectedEntryOnly() {
        playSelection()
    }

    // MARK: - 下一首播放

    /// Whether 下一首播放 can be honored right now: an insertable entry AND a running queue with
    /// a still-present active entry to insert after. It never restarts or replaces anything.
    var canPlaySelectionNext: Bool {
        guard queueState.isRunning, queueState.activeEntry != nil,
              playableSelectionEntry != nil else { return false }
        return true
    }

    /// Insert the current selection immediately after the current song without interrupting it.
    func playSelectionNext() {
        guard canPlaySelectionNext, let entry = playableSelectionEntry else { return }
        playNext(entry)
    }

    /// Queue row double-click: select that exact entry and start it through the existing owner
    /// path (including a localfile entry). An unknown entry changes nothing at all; a known but
    /// currently unavailable entry only selects, so the running media is never interrupted.
    func playQueueEntryOnDoubleClick(_ id: String) {
        guard queueState.configuration.entries.contains(where: { $0.id == id }) else { return }
        selectedQueueEntryID = id
        playSelectedQueueEntry()
    }

    var selectedQueueEntry: PerformanceQueueEntry? {
        queueState.configuration.entries.first { $0.id == selectedQueueEntryID }
    }

    var queueStartProblem: String? {
        guard !queueState.configuration.entries.isEmpty else { return "先从曲库加入曲目。" }
        return playbackReadinessProblem
    }

    var selectedQueuePlaybackProblem: String? {
        guard let entry = selectedQueueEntry else { return "从队列中选择一项。" }
        if let problem = queueEntryUnavailableReason(entry) { return problem }
        switch entry.target {
        case .official(let performanceID, let presentation):
            return playbackProblem(id: performanceID.rawValue, presentation: presentation)
        case .localFile(let trackID, let fileID):
            guard let track = localTrack(trackID) else { return "曲目不在当前记录中，条目仍保留在队列中。" }
            guard track.files.contains(where: { $0.id == fileID }) else {
                return "队列保存的文件不再存在，条目仍保留在队列中。"
            }
            guard serviceReady else { return "播放器尚未就绪，请查看上方的提示。" }
            return localPlaybackProblem(track, fileID: fileID)
        }
    }

    func beginQueue() {
        guard queueStartProblem == nil else { return }
        startQueue(nil)
    }

    func playSelectedQueueEntry() {
        guard let entry = selectedQueueEntry, selectedQueuePlaybackProblem == nil else { return }
        startQueue(entry.id)
    }

    func canMoveSelectedQueueEntry(by offset: Int) -> Bool {
        guard let index = queueState.configuration.entries.firstIndex(where: { $0.id == selectedQueueEntryID }) else { return false }
        return queueState.configuration.entries.indices.contains(index + offset)
    }

    func moveSelectedQueueEntry(by offset: Int) {
        guard let id = selectedQueueEntryID, canMoveSelectedQueueEntry(by: offset) else { return }
        moveQueueEntry(id, offset)
    }

    func removeSelectedQueueEntry() {
        guard let entry = selectedQueueEntry else { return }
        removeQueueEntry(entry.id)
    }

    func queueEntryTitle(_ entry: PerformanceQueueEntry) -> String {
        switch entry.target {
        case .official(let performanceID, _):
            return library?.manifest.tracks.first { $0.id == performanceID.rawValue }?.title ?? "不可用曲目"
        case .localFile(let trackID, _):
            return localTrack(trackID)?.displayTitle ?? "不可用曲目"
        }
    }

    /// Shared curated context so a queue row carries the same source/composer label as the
    /// library row. Nil for an unknown or local entry: a local entry carries no source class.
    func queueEntryContext(_ entry: PerformanceQueueEntry) -> String? {
        switch entry.target {
        case .official(let performanceID, _):
            guard let track = library?.manifest.tracks.first(where: { $0.id == performanceID.rawValue }) else {
                return nil
            }
            return PerformanceDisplay.rowContext(for: track)
        case .localFile:
            // A local entry carries no source/composer class.
            return nil
        }
    }

    func queueEntryDetail(_ entry: PerformanceQueueEntry) -> String {
        switch entry.target {
        case .official(let id, let presentation):
            let camera = (retainedOfficialVariant(id.rawValue)?.presentation ?? presentation) == .sidePerformance ? "侧面素材" : "正面素材"
            return camera
        case .localFile(let trackID, let fileID):
            // The exact neutral version; never a camera label or a source class.
            let resolvedID = (try? localPlaybackChoice(trackID: trackID, requestedFileID: fileID).file.id) ?? fileID
            guard let version = localTrack(trackID)?.versionNumber(ofFile: resolvedID) else { return "版本不可用" }
            return "版本\(version)"
        }
    }

    func queueEntryUnavailableReason(_ entry: PerformanceQueueEntry) -> String? {
        if let retentionProblem { return retentionProblem }
        switch entry.target {
        case .localFile(let trackID, let fileID):
            guard let track = localTrack(trackID) else {
                return "曲目不在当前记录中，条目仍保留在队列中。"
            }
            guard track.files.contains(where: { $0.id == fileID }) else {
                return "队列保存的文件不再存在，条目仍保留在队列中。"
            }
            if localCatalog?.root(id: track.rootID)?.isMissing == true {
                return "歌曲目录当前不可用，条目仍保留在队列中。"
            }
            if mediaRetention.document?.local.contains(where: { $0.trackID == trackID }) == true {
                return localPlaybackProblem(track, fileID: fileID)
            }
            return nil
        case .official(let performanceID, let presentation):
            guard let library else { return "演奏清单不可用，条目仍保留在队列中。" }
            guard let track = library.manifest.tracks.first(where: { $0.id == performanceID.rawValue }) else {
                return "清单中未找到此曲目，条目仍保留在队列中。"
            }
            guard track.variants.contains(where: { $0.presentation == presentation }) else {
                return "此曲目不支持条目所选的机位。"
            }
            return nil
        }
    }

    func queueEntryStatus(_ entry: PerformanceQueueEntry) -> String? {
        guard queueState.isRunning, queueState.activeEntry?.id == entry.id else { return nil }
        return sessionStatus
    }

    /// Opaque identity text for an unavailable entry. Never a path.
    func queueEntryIdentityText(_ entry: PerformanceQueueEntry) -> String {
        switch entry.target {
        case .official(let performanceID, _): return performanceID.rawValue
        case .localFile(let trackID, let fileID): return "local:\(trackID)/\(fileID)"
        }
    }

    var queueEditExplanation: String {
        if queueState.isRunning, let active = queueState.activeEntry,
           !queueState.configuration.entries.contains(where: { $0.id == active.id }) {
            return "增删队列条目不会打断当前曲目。"
        }
        return "移除条目不会打断当前曲目；清空后，当前曲目播完即停。"
    }
}

extension PerformanceQueueOrder {
    var controlLabel: String {
        switch self {
        case .stopAfterQueue: return "顺序播完"
        case .shuffle: return "随机顺序"
        case .repeatAll: return "列表循环"
        case .repeatOne: return "单曲循环"
        }
    }
}

struct PerformanceQueueView: View {
    @ObservedObject var model: PerformanceBrowserModel
    /// The unified shell opens the library panel; nil keeps the standalone section switch.
    var showLibrary: (() -> Void)? = nil
    var showsHistorySelector = true
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // Interactive controls must remain outside List rows: macOS combines row children
        // into a selectable accessibility element, hiding their individual actions.
        VStack(spacing: 0) {
            if showsHistorySelector {
                SongQueueSelector(model: model).padding(.horizontal, 16).padding(.vertical, 10)
            }
            if showsHistorySelector && model.showingSongHistory {
                SongPlaybackHistoryView(model: model)
            } else {
            ScrollView {
                controls.padding(.horizontal, 16).padding(.vertical, 12)
            }
            .frame(minHeight: 90, maxHeight: 174)
            Divider()
            if model.queueState.configuration.entries.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("播放队列为空").font(.callout.weight(.medium))
                        Text("在曲库选择曲目后点“稍后播放”加入，点“加入并播放”立即播放。")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("返回曲库") {
                            if let showLibrary { showLibrary() } else { model.section = .library }
                        }
                            .buttonStyle(.borderless)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                }
                .frame(minHeight: 80)
            } else {
                List(selection: $model.selectedQueueEntryID) {
                    ForEach(model.queueState.configuration.entries) { entry in
                        entryRow(entry)
                            .tag(entry.id)
                            // Double-click starts exactly this entry, localfile included, through
                            // the existing owner path. `simultaneousGesture` keeps the List's own
                            // single-click selection and the keyboard/accessibility controls intact;
                            // `count: 2` never fires on a single click.
                            .contentShape(Rectangle())
                            .simultaneousGesture(TapGesture(count: 2).onEnded {
                                model.playQueueEntryOnDoubleClick(entry.id)
                            })
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 80)
            }
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Picker("播放顺序", selection: Binding(
                    get: { model.queueState.configuration.order },
                    set: model.setQueueOrder)) {
                    ForEach([PerformanceQueueOrder.stopAfterQueue, .shuffle, .repeatAll, .repeatOne], id: \.self) { order in
                        Text(order.controlLabel).tag(order)
                    }
                }
                .pickerStyle(.menu).frame(width: 230)
                .accessibilityLabel("播放顺序")
                Spacer(minLength: 8)
                Button("开始队列", action: model.beginQueue)
                    .buttonStyle(.borderedProminent)
                    .tint(FrontendAppearance.actionTint(for: colorScheme))
                    .foregroundStyle(FrontendAppearance.actionForeground(for: colorScheme))
                    .disabled(model.queueStartProblem != nil)
            }
            HStack(spacing: 10) {
                Button("从所选条目播放", action: model.playSelectedQueueEntry)
                    .disabled(model.selectedQueuePlaybackProblem != nil)
                Button("移除", action: model.removeSelectedQueueEntry)
                    .disabled(model.selectedQueueEntry == nil)
                Button { model.moveSelectedQueueEntry(by: -1) } label: {
                    Image(systemName: "arrow.up")
                }
                .accessibilityLabel("上移所选条目").help("上移所选条目")
                .disabled(!model.canMoveSelectedQueueEntry(by: -1))
                Button { model.moveSelectedQueueEntry(by: 1) } label: {
                    Image(systemName: "arrow.down")
                }
                .accessibilityLabel("下移所选条目").help("下移所选条目")
                .disabled(!model.canMoveSelectedQueueEntry(by: 1))
                Spacer(minLength: 8)
                Button("清空列表", action: model.clearQueue)
                    .disabled(model.queueState.configuration.entries.isEmpty)
            }
            .buttonStyle(.bordered)
            Text("顺序调整仅影响后续播放，不切换当前曲目。")
                .font(.caption).foregroundStyle(.secondary)
            if model.queueState.configuration.order == .shuffle {
                Text("随机顺序：每条播放一次，播完停止。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("双击条目立即播放。")
                .font(.caption).foregroundStyle(.secondary)
            Text(model.queueEditExplanation)
                .font(.caption).foregroundStyle(.secondary)
            if let problem = model.queueStartProblem ?? (model.selectedQueueEntry == nil ? nil : model.selectedQueuePlaybackProblem) {
                Text(problem).font(.caption).foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func entryRow(_ entry: PerformanceQueueEntry) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(model.queueEntryTitle(entry)).font(.body)
                    .lineLimit(2)
                if let context = model.queueEntryContext(entry) {
                    Text(context).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(model.queueEntryDetail(entry)).font(.caption).foregroundStyle(.secondary)
                if let unavailable = model.queueEntryUnavailableReason(entry) {
                    Text(unavailable).font(.caption).foregroundStyle(.secondary)
                    Text(model.queueEntryIdentityText(entry)).font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).help(model.queueEntryIdentityText(entry))
                }
            }
            Spacer(minLength: 6)
            if let status = model.queueEntryStatus(entry) {
                Text("当前 · \(status)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 7)
    }
}
