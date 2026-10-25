// Unified music intent. Legacy queue/history modes remain decodable and unchanged on disk;
// only a newly executed request uses the shared audiovisual player, initially on the desktop.
import BSideCore

enum UnifiedMusicPlayback {
    static func request(_ source: PerformanceStartRequest) -> PerformanceStartRequest {
        let old = source.session
        let session = PerformanceSession(id: old.id, target: old.target, mode: .watch,
                                         paused: old.paused, continuesQueue: old.continuesQueue)
        return PerformanceStartRequest(session: session, mediaRoot: source.mediaRoot,
            accessBookmark: source.accessBookmark, fileBinding: source.fileBinding,
            automaticallyEnterFullScreen: false)
    }
}
