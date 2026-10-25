// BSideControlApp — curated display context for the bundled performance library.
//
// Presentation only. Every entry is keyed by the EXISTING manifest track ID (ADR-013
// identity) and never edits the fingerprinted manifest, media paths/hashes/order or any
// playback semantic. `PerformanceDisplayTable` holds the reviewed data; this file holds
// the shared accessor so the library rows, search and queue present one consistent label.
//
// Rules the table follows:
//  - `source` is a short, verified origin label (game/franchise, composer, or tradition).
//  - `album` names the verified soundtrack/album or familiar collection when the public
//    source documents it; `work` adds a familiar work/opus context. `work` is only set
//    when the public catalog ordering supports it — an ambiguous or mislabelled opus is
//    never silently corrected, and an uncertain opus is flagged as uncertain. `work` stays
//    concise and never repeats the manifest's English title.
//  - `detail` is the concise ordinary-playlist context (source/composer plus album or work,
//    no provenance/research narrative). It stays part of the search surface rather than a
//    second copy in the detail pane, which already shows the row's shared label.
//    Genuinely ambiguous titles stay `confidence: .unconfirmed` with source 来源未确认 and
//    one short concrete reason in `detail` (曲名待确认 / 收录来源未确认).
//
// Evidence is recorded per entry in `PerformanceDisplayTable` as inline provenance: the
// public URL actually consulted plus the exact claim it supports. Community Fandom game
// wikis are fan-maintained references, never official/authoritative publications; they can
// corroborate a franchise association but are labelled as community references. Where only
// a search-hit list was available (no fetched page text), the claim says so.
import Foundation
import BSideCore
import BSidePlatform

/// One reviewed display context for one manifest track. `evidence` records the public
/// source URL and the exact claim it supports; it is metadata, never copied lyrics/text.
struct PerformanceDisplayContext: Equatable {
    enum Confidence: String, Equatable {
        case verified
        case unconfirmed
    }

    struct Evidence: Equatable {
        let url: String
        let claim: String
    }

    /// Short origin/composer label shown on a library row (e.g. 原神, 崩坏3, 肖邦).
    let source: String
    /// Optional verified soundtrack/album context (e.g. 崩坏3 毕业旅行, 原神 璃月 OST).
    let album: String?
    /// Optional familiar work/opus context appended to the row label (e.g. 夜曲 Op.9 No.2).
    let work: String?
    /// Fuller verified context for the detail pane. Nil falls back to the row label.
    let detail: String?
    /// Additional searchable terms (English/Japanese titles, composer, work). Aliases never
    /// replace or rewrite the manifest title.
    let aliases: [String]
    let confidence: Confidence
    let evidence: [Evidence]
}

/// Shared presentation helper: one label for the library list, search and the queue.
enum PerformanceDisplay {
    /// Shown when a title could not be confirmed against an authoritative source.
    static let unconfirmedSource = "来源未确认"

    static func context(for track: PerformanceManifest.Track) -> PerformanceDisplayContext? {
        PerformanceDisplayTable.contexts[track.id]
    }

    /// Short row context: "<source> · <album>" or "<source> · <work>". Nil for a track
    /// without a reviewed entry, so an unknown future track never gets an invented label.
    static func rowContext(for track: PerformanceManifest.Track) -> String? {
        guard let context = context(for: track) else { return nil }
        if let album = context.album, !album.isEmpty { return "\(context.source) · \(album)" }
        guard let work = context.work, !work.isEmpty else { return context.source }
        if track.title.contains(work) { return context.source }
        return "\(context.source) · \(work)"
    }

    /// Verified performance-kind wording; the one secondary fact the detail pane keeps.
    static func kindLabel(for track: PerformanceManifest.Track) -> String {
        track.kind == .pianoSolo ? "钢琴演奏" : "弹唱演奏"
    }

    /// Detail-pane secondary metadata for one track. The library row already presents the
    /// manifest title and the shared reviewed source/composer label, so the detail keeps only
    /// the verified kind: it never repeats the original title (subtitle), the reviewed work or
    /// the fuller context line. Those remain searchable through `matches`, which is the reason
    /// removing them from the detail does not remove them from the library.
    static func detailMetadataLines(for track: PerformanceManifest.Track) -> [String] {
        [kindLabel(for: track)]
    }

    /// Combined search surface: the manifest title/subtitle plus the curated labels and
    /// aliases, so the new Chinese source/composer labels and the originals both match.
    /// Matching is case- and diacritic-insensitive, so "Etude"/"Gymnopedie" also reach the
    /// accented catalogue spellings, and surrounding whitespace is ignored.
    static func matches(_ track: PerformanceManifest.Track, search: String) -> Bool {
        let needle = folded(search.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !needle.isEmpty else { return true }
        var candidates: [String] = [track.title, track.subtitle]
        if let context = context(for: track) {
            candidates.append(context.source)
            if let album = context.album { candidates.append(album) }
            if let work = context.work { candidates.append(work) }
            if let detail = context.detail { candidates.append(detail) }
            candidates.append(contentsOf: context.aliases)
        }
        return candidates.contains { !$0.isEmpty && folded($0).contains(needle) }
    }

    private static func folded(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    // One shared Chinese wording for lighting/presentation/mode so the library, the queue and
    // the unified shell's music strip can never disagree. These are internal (single-module)
    // helpers, not file-private, because more than one ControlApp view now consumes them.
    static func label(for lighting: PerformanceLighting) -> String {
        switch lighting {
        case .daylight: return "白天"
        case .sunset: return "傍晚"
        case .night: return "夜晚"
        }
    }

    static func label(for presentation: PerformancePresentation) -> String {
        presentation == .sidePerformance ? "侧面" : "正面"
    }

    static func label(for mode: PerformancePlaybackMode) -> String {
        mode == .listen ? "只听音乐" : "观看演奏"
    }
}
