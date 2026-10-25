import AVFoundation
import Foundation

public enum PerformanceMediaProbe {
    /// Inspect an already identity-verified local MP4. Missing video is a capability result;
    /// unreadable media remains an error and must not select another playback backend.
    public static func hasVideo(_ url: URL) async throws -> Bool {
        let asset = AVURLAsset(url: url)
        guard try await asset.load(.isPlayable) else {
            throw PerformanceAssetError.unreadable("所选歌曲无法播放")
        }
        let tracks = try await asset.loadTracks(withMediaType: .video)
        return !tracks.isEmpty
    }

    /// Inspect only the chosen file; the actual player still reports asynchronous failures.
    public static func validate(_ url: URL) async throws {
        let asset = AVURLAsset(url: url)
        let playable = try await asset.load(.isPlayable)
        let duration = try await asset.load(.duration)
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        guard playable, duration.seconds.isFinite, duration.seconds > 0, !video.isEmpty, !audio.isEmpty else {
            throw PerformanceAssetError.unreadable("所选演奏需要可播放的视频和音轨")
        }
    }
}
