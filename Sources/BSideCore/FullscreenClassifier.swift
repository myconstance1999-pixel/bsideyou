// BSideCore — FullscreenClassifier: the pure geometry/classification seam behind the
// documented CGWindowList fullscreen heuristic (feeds RuntimeContext.fullscreenAppActive →
// PlaybackPolicy "fullscreen-app"). SystemMonitors parses CGWindowListCopyWindowInfo into
// candidate records and asks this function; the heuristic itself lives here so it is
// deterministically testable with no AppKit / window-server dependency.

/// One parsed on-screen window record, reduced to the fields the heuristic needs.
public struct FullscreenCandidate: Equatable, Hashable {
    /// WindowServer layer (0 = normal document layer; menu bar / Dock live above 0).
    public var layer: Int
    /// Window size in screen points.
    public var width: Double
    public var height: Double
    /// Owner is a regular (non-accessory) application.
    public var regularApp: Bool
    /// Owner is our own process (never counts as a fullscreen app).
    public var ownProcess: Bool

    public init(layer: Int, width: Double, height: Double, regularApp: Bool, ownProcess: Bool) {
        self.layer = layer
        self.width = width
        self.height = height
        self.regularApp = regularApp
        self.ownProcess = ownProcess
    }
}

public enum FullscreenClassifier {
    /// Documented heuristic (AuraFlow-derived, simplified for the main display): a layer-0
    /// on-screen window owned by a regular app (not ourselves) covering ≥ `coverage` of the
    /// screen. Menu bar / Dock / any nonzero-layer window, accessory/background owners, our own
    /// windows, and near-fullscreen (sub-threshold) windows are all excluded. HEURISTIC STATUS:
    /// unchanged from Alpha; a real fullscreen app uses a borderless layer-0 window at the full
    /// screen frame, which this catches, while 94%-coverage "maximized" windows do not trip it.
    public static func detectsFullscreen(
        candidates: [FullscreenCandidate],
        screenArea: Double,
        coverage: Double = 0.95
    ) -> Bool {
        for candidate in candidates {
            guard candidate.layer == 0 else { continue }
            guard candidate.width * candidate.height >= screenArea * coverage else { continue }
            guard candidate.regularApp, !candidate.ownProcess else { continue }
            return true
        }
        return false
    }
}
