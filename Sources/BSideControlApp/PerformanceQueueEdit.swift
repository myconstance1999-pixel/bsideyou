// Owner-side queue edits for the one-click library actions. These are pure transitions over the
// existing Core queue only: no persistence, no playback dispatch and no media access live here.
// `AppDelegate` stays the sole owner that saves the result and starts playback; the UI only
// forwards the exact snapshot/entry it captured.
import Foundation
import BSideCore

enum PerformanceQueueEdit {
    /// Library 随机播放: replace the saved queue with one filtered-library snapshot and select the
    /// existing shuffle order. An empty or malformed snapshot is refused as a whole, so the
    /// existing queue, its order and any current playback stay exactly as they were.
    @discardableResult
    static func replaceWithShuffledSnapshot(_ state: inout PerformanceQueueState,
                                            snapshot: [PerformanceQueueEntry]) -> Bool {
        guard replaceWithListSnapshot(&state, snapshot: snapshot) else { return false }
        state.setOrder(.shuffle)
        return true
    }

    /// Library 播放 / row double-click (ADR-024): replace the saved queue with the exact ordered
    /// snapshot of the currently visible eligible rows and keep the user's existing queue mode.
    /// An empty or malformed snapshot is refused as a whole, so the existing queue, its order and
    /// any current playback stay exactly as they were.
    @discardableResult
    static func replaceWithListSnapshot(_ state: inout PerformanceQueueState,
                                        snapshot: [PerformanceQueueEntry]) -> Bool {
        guard !snapshot.isEmpty,
              snapshot.allSatisfy({ !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              Set(snapshot.map(\.id)).count == snapshot.count else { return false }
        state.clear()
        for entry in snapshot { _ = state.append(entry) }
        return true
    }

    /// Selected song 加入并播放: append one exact captured entry and return it so the caller can
    /// start that new entry immediately. Existing entries are retained; an entry the queue already
    /// contains (or an empty identity) is refused without any change to the queue or media.
    static func appendForImmediatePlay(_ state: inout PerformanceQueueState,
                                       entry: PerformanceQueueEntry) -> PerformanceQueueEntry? {
        guard state.append(entry) else { return nil }
        return entry
    }
}
