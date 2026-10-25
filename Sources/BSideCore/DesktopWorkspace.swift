// Transient desktop presentation and semantic actions. No file paths or playback authority.
import Foundation

public enum DesktopWorkspaceAction: String, Codable, Hashable, CaseIterable {
    case applications, files, music, toggleMusic, toggleCompanion, companion, study, settings
}

public struct DesktopWorkspacePresentation: Codable, Hashable {
    public var isVisible: Bool
    public var musicTitle: String
    public var musicIsPlaying: Bool
    public var musicCanToggle: Bool
    public var pictureIsPaused: Bool

    public init(isVisible: Bool = false, musicTitle: String = "", musicIsPlaying: Bool = false,
                musicCanToggle: Bool = false,
                pictureIsPaused: Bool = false) {
        self.isVisible = isVisible
        self.musicTitle = musicTitle
        self.musicIsPlaying = musicIsPlaying
        self.musicCanToggle = musicCanToggle
        self.pictureIsPaused = pictureIsPaused
    }
}
