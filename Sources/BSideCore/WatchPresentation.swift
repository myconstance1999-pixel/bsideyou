// BSideCore — presentation-only lifecycle for an independently playing song (ADR-029).
// Readiness never opens a window. Only an explicit request may show it; hiding keeps the
// media session, and a video queue successor may reuse an already opened window.
public struct WatchPresentation {
    public enum Effect: Equatable {
        case enterFullScreen
        case exitFullScreen
        case returnToDesktop // Legacy effect spelling: exit, then hide; never a desktop rendition.
        case orderOut
        case none
    }

    public private(set) var sessionID: String?
    public private(set) var ownsLayer = false
    public private(set) var isFullScreen = false
    public private(set) var isEntering = false
    public private(set) var isEnding = false
    private var isClosing = false
    private var closeAfterEntry = false
    private var mediaReady = false
    private var mediaEligible = false
    private var openRequested = false

    public init() {}
    public var isActiveRun: Bool { sessionID != nil || isEnding }
    public var isExitDeferredForEnter: Bool { isEnding && isEntering && !ownsLayer }

    public mutating func adoptSession(_ sessionID: String) {
        self.sessionID = sessionID
        mediaReady = false
        mediaEligible = false
        // Preserve only an actually opened presentation, never a previous hidden request.
        if !ownsLayer { openRequested = false }
    }

    public mutating func mediaBecameReady(sessionID: String, eligible: Bool,
                                        automaticallyEnterFullScreen: Bool = false) -> Effect {
        guard self.sessionID == sessionID else { return .none }
        self.sessionID = sessionID
        mediaReady = true
        mediaEligible = eligible
        // The legacy automatic-entry flag is deliberately ignored.
        return openIfRequested()
    }

    public mutating func reconcileEligibility(sessionID: String, eligible: Bool) -> Effect {
        guard self.sessionID == sessionID else { return .none }
        mediaEligible = eligible
        return openIfRequested()
    }

    public mutating func explicitFullScreenRequested() -> Effect {
        guard sessionID != nil, mediaReady, !ownsLayer, !isEnding, !isClosing else { return .none }
        openRequested = true
        return openIfRequested()
    }

    private mutating func openIfRequested() -> Effect {
        guard openRequested, mediaReady, mediaEligible, sessionID != nil,
              !ownsLayer, !isEntering, !isEnding, !isClosing else { return .none }
        ownsLayer = true
        isEntering = true
        closeAfterEntry = false
        return .enterFullScreen
    }

    public mutating func closeRequested() -> Effect {
        openRequested = false
        guard ownsLayer, !isEnding, !isClosing else { return .none }
        if isEntering {
            closeAfterEntry = true
            return .none
        }
        if isFullScreen {
            isClosing = true
            return .returnToDesktop
        }
        return hide()
    }

    public mutating func contentDoubleClicked() -> Effect { closeRequested() }

    public mutating func endRun(sessionID: String?) -> Effect {
        guard sessionID == nil || self.sessionID == sessionID else { return .none }
        self.sessionID = nil
        mediaReady = false
        mediaEligible = false
        openRequested = false
        closeAfterEntry = false
        let hadLayer = ownsLayer
        ownsLayer = false
        if isEntering { isEnding = true; return .none }
        if isFullScreen { isEnding = true; return .exitFullScreen }
        isEnding = false
        isClosing = false
        return hadLayer ? .orderOut : .none
    }

    public mutating func willEnterFullScreen() {
        guard ownsLayer, !isEnding else { return }
        isEntering = true
    }

    public mutating func didEnterFullScreen() -> Effect {
        guard isEntering else { return .none }
        isEntering = false
        isFullScreen = true
        if isEnding || !ownsLayer { return .exitFullScreen }
        if closeAfterEntry {
            closeAfterEntry = false
            isClosing = true
            return .returnToDesktop
        }
        return .none
    }

    public mutating func didFailToEnterFullScreen() -> Effect {
        guard isEntering || isEnding else { return .none }
        return hide()
    }

    public mutating func didExitFullScreen(programmatic: Bool) -> Effect {
        guard ownsLayer || isFullScreen || isClosing || isEnding else { return .none }
        return hide()
    }

    public mutating func didFailToExitFullScreen(isFullScreen: Bool) -> Effect {
        guard ownsLayer || isEnding || isClosing else { return .none }
        if isFullScreen && ownsLayer && !isEnding {
            self.isFullScreen = true
            isEntering = false
            isClosing = false
            return .none // Actual native state wins; no automatic retry.
        }
        return hide()
    }

    private mutating func hide() -> Effect {
        ownsLayer = false
        isEntering = false
        isFullScreen = false
        isEnding = false
        isClosing = false
        closeAfterEntry = false
        openRequested = false
        // Keep session/readiness so explicit reopening uses the same media item.
        return .orderOut
    }

    public mutating func shutdown() -> Effect {
        let active = isActiveRun || ownsLayer
        self = Self()
        return active ? .orderOut : .none
    }
}
