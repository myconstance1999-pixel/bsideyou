// BSideCore — validity of the daily media the Agent currently has installed or retained.
// A retained AVPlayer can keep a media clock advancing over a frozen picture after its accepted
// root disappears, and a later read can report identical path/version metadata while that same
// stale item is still the installed one. Accepted discovery alone therefore cannot prove the
// installed item is fresh. This reducer owns only the invalidation bit and its reset points; the
// Agent still decides when a loss is known and when an actual installation happened.

public struct DailyInstalledMediaValidity: Equatable {
    /// True after a known accepted-root loss until an actual fresh item is installed.
    public private(set) var needsReplacement = false

    public init() {}

    /// A known accepted-root resource loss (grant failure, failed read, explicit invalidation)
    /// invalidates the installed/retained daily item. That item must not be reused as an
    /// equal-source result and must not confirm visual history.
    public mutating func invalidatedByResourceLoss() {
        needsReplacement = true
    }

    /// Only an actual fresh installation of accepted daily media clears the invalidation. A
    /// refresh that merely re-reads the same path/version must not call this.
    public mutating func replacedByFreshInstall() {
        needsReplacement = false
    }

    /// The retained item may contribute confirmed visual history only while discovery is accepted
    /// and no known loss invalidated that exact installed item.
    public func historyEligible(discoveryAccepted: Bool) -> Bool {
        discoveryAccepted && !needsReplacement
    }

    /// An invalidated item is itself a pending source change: a same-metadata refresh must still
    /// schedule a replacement at the current unit's natural end rather than keeping the stale item.
    public func indicatesSourceChange(metadataDiffers: Bool) -> Bool {
        metadataDiffers || needsReplacement
    }
}
