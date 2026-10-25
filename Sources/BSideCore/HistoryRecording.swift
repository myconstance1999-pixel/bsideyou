// ControlApp binds this capture token before the Agent observes media. A late report must
// retain its original epoch/session; receivers must never relabel it with the current token.
import Foundation

public struct HistoryRecordingRequest: Codable, Hashable {
    public var enabled: Bool
    public var epoch: Int
    public var session: String

    public init(enabled: Bool, epoch: Int, session: String) {
        self.enabled = enabled
        self.epoch = epoch
        self.session = session
    }
}
