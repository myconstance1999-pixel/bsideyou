// BSideControlApp — reviewed classical-repertoire membership for the bundled library.
//
// Category browsing needs one thing the manifest does not encode: whether a piano track is
// classical repertoire or a modern/game/crossover piano piece. That is a curation judgment,
// so it is recorded here as an EXPLICIT, STABLE set of manifest track IDs. Runtime membership
// is decided by ID equality only:
//
//   * there is NO runtime title/composer/string heuristic anywhere in this feature;
//   * `composer` below is review provenance — it is the exact `source` label already carried by
//     `PerformanceDisplayTable` for that ID — and is never matched against at runtime. The
//     focused regression asserts it still equals the live table, so a metadata edit that moves a
//     composer cannot silently change the classical bucket;
//   * an unknown/unconfirmed origin is never listed here, so those tracks keep their existing
//     piano/vocal category (the requirement "unknown origins remain existing piano/vocal").
//
// Review basis (against `PerformanceDisplayTable` metadata, reviewed 2026-09-22):
//   - Included: the Western classical catalogue — Baroque through late-Romantic solo piano
//     repertoire by Bach, Beethoven, Chopin, Debussy, Grieg, Liszt, Mendelssohn, Mozart,
//     Pachelbel, Rachmaninoff, Ravel, Saint-Saëns, Satie, Scarlatti, Schubert, Schumann,
//     Scriabin and Tchaikovsky — plus one clearly identified classical ADAPTATION whose
//     underlying work is classical repertoire: the jazz arrangement of Rimsky-Korsakov's
//     「野蜂飞舞」 (Flight of the Bumblebee), which the table itself sources to
//     里姆斯基-科萨科夫.
//   - Excluded deliberately, even though they are piano tracks: the game/franchise OST
//     arrangements (原神 / 崩坏：星穹铁道 — source labels are franchises, not composers), the
//     contemporary crossover/easy-listening originals (马克西姆·姆尔维察 「克罗地亚狂想曲」,
//     理查德·克莱德曼 「星空」, 保罗·塞内维尔 「梦中的婚礼」 — modern works, not repertoire or
//     adaptations of repertoire), and every 来源未确认 entry.
//
// Membership is a subset of `pianoSolo`; vocal tracks are never classical (Vocal is unchanged).
// Adding or removing a track is an ordinary source change that must update this list and the
// focused regression's expected count at the same time.
import Foundation
import BSideCore
import BSidePlatform

enum PerformanceClassicalCatalog {
    /// One reviewed entry: the stable manifest track ID plus the `PerformanceDisplayTable`
    /// `source` label that justified including it. `composer` is provenance, not a matcher.
    struct ReviewedEntry: Equatable {
        let id: String
        let composer: String
    }

    /// The explicit reviewed set, grouped for auditability. Order is review order, not runtime.
    static let reviewed: [ReviewedEntry] = [
        // Bach
        .init(id: "olivia.performance.solo.air-on-the-g-string-from-orchestral-suite-no3-in-d-major-bwv-1068", composer: "巴赫"),
        .init(id: "olivia.performance.solo.prelude-and-fugue-in-c-minor-bwv-847-p1", composer: "巴赫"),
        .init(id: "olivia.performance.solo.prelude-and-fugue-in-c-minor-bwv-847-p2", composer: "巴赫"),
        // Beethoven
        .init(id: "olivia.performance.solo.beethoven-piano-sonata-no8-in-c-minor-op13-2-adagio-cantabile", composer: "贝多芬"),
        .init(id: "olivia.performance.solo.piano-sonata-no17-in-d-minor-op31-no2-tempest-1-largo", composer: "贝多芬"),
        // Chopin
        .init(id: "olivia.performance.solo.chopin-etude-op10-no1", composer: "肖邦"),
        .init(id: "olivia.performance.solo.chopin-etude-op10-no3", composer: "肖邦"),
        .init(id: "olivia.performance.solo.chopin-etude-op10-no5", composer: "肖邦"),
        .init(id: "olivia.performance.solo.chopin-etude-op10-no8", composer: "肖邦"),
        .init(id: "olivia.performance.solo.chopin-etude-op10-no9", composer: "肖邦"),
        .init(id: "olivia.performance.solo.chopin-etude-op10-no12", composer: "肖邦"),
        .init(id: "olivia.performance.solo.chopin-etude-op25-no2", composer: "肖邦"),
        .init(id: "olivia.performance.solo.chopin-etude-op25-no12-in-c-minor", composer: "肖邦"),
        .init(id: "olivia.performance.solo.chopin-nocturne-op9-no2", composer: "肖邦"),
        .init(id: "olivia.performance.solo.chopin-op25-no3", composer: "肖邦"),
        .init(id: "olivia.performance.solo.chopin-op28-no4", composer: "肖邦"),
        .init(id: "olivia.performance.solo.chopin-op40-no1", composer: "肖邦"),
        .init(id: "olivia.performance.solo.chopin-op64-no2", composer: "肖邦"),
        .init(id: "olivia.performance.solo.grande-polonaise-brillante-op22-p1", composer: "肖邦"),
        .init(id: "olivia.performance.solo.grande-polonaise-brillante-op22-p2", composer: "肖邦"),
        .init(id: "olivia.performance.solo.minute-waltz-op64-no1", composer: "肖邦"),
        .init(id: "olivia.performance.solo.nocturne-no3-in-b-major-for-piano-solo", composer: "肖邦"),
        // Debussy
        .init(id: "olivia.performance.solo.arabesque-no2", composer: "德彪西"),
        .init(id: "olivia.performance.solo.debussy-moonlight", composer: "德彪西"),
        .init(id: "olivia.performance.solo.debussy-reverie", composer: "德彪西"),
        // Grieg
        .init(id: "olivia.performance.solo.notturno-op-54-no4", composer: "格里格"),
        // Liszt
        .init(id: "olivia.performance.solo.consolation-no3-in-d-flat-major", composer: "李斯特"),
        .init(id: "olivia.performance.solo.dance-of-the-gnomes-no2", composer: "李斯特"),
        .init(id: "olivia.performance.solo.rhapsodie-espagnole-s254-p1", composer: "李斯特"),
        .init(id: "olivia.performance.solo.rhapsodie-espagnole-s254-p2", composer: "李斯特"),
        .init(id: "olivia.performance.solo.the-little-bell-no3", composer: "李斯特"),
        // Mendelssohn
        .init(id: "olivia.performance.solo.song-without-words-op67-no2", composer: "门德尔松"),
        // Mozart
        .init(id: "olivia.performance.solo.piano-sonata-no13-k333", composer: "莫扎特"),
        .init(id: "olivia.performance.solo.piano-sonata-no16-k545", composer: "莫扎特"),
        .init(id: "olivia.performance.solo.turkish-march", composer: "莫扎特"),
        // Pachelbel
        .init(id: "olivia.performance.solo.canon-in-d", composer: "帕赫贝尔"),
        // Rachmaninoff
        .init(id: "olivia.performance.solo.prelude-in-g-minor-op23-no5", composer: "拉赫玛尼诺夫"),
        // Ravel
        .init(id: "olivia.performance.solo.pavane-for-a-dead-princess", composer: "拉威尔"),
        // Rimsky-Korsakov: the reviewed classical ADAPTATION (jazz arrangement of 野蜂飞舞).
        .init(id: "olivia.performance.solo.flight-of-the-bumblebee-jazz-version", composer: "里姆斯基-科萨科夫"),
        // Saint-Saëns
        .init(id: "olivia.performance.solo.the-swan", composer: "圣-桑"),
        // Satie
        .init(id: "olivia.performance.solo.gymnopedie-no1", composer: "萨蒂"),
        // Scarlatti
        .init(id: "olivia.performance.solo.scarlatti-sonata-in-d-minor-k213", composer: "斯卡拉蒂"),
        // Schubert
        .init(id: "olivia.performance.solo.impromptu-in-g-flat-major-op90-no3", composer: "舒伯特"),
        .init(id: "olivia.performance.solo.moment-musical-no3-in-f-minor-op94", composer: "舒伯特"),
        // Schumann
        .init(id: "olivia.performance.solo.scene-from-childhood-op-15-no7-dreaming", composer: "舒曼"),
        .init(id: "olivia.performance.solo.schumann-papillons-op2", composer: "舒曼"),
        // Scriabin
        .init(id: "olivia.performance.solo.scriabin-etude-in-c-sharp-minor-op19-no2", composer: "斯克里亚宾"),
        // Tchaikovsky
        .init(id: "olivia.performance.solo.the-seasons-op-37a-x-october-autumn-song", composer: "柴可夫斯基"),
    ]

    /// Stable membership set. This is the ONLY value the category filter consults.
    static let trackIDs: Set<String> = Set(reviewed.map(\.id))

    /// ID-only membership; never inspects the title, subtitle, composer or any curated string.
    static func contains(_ track: PerformanceManifest.Track) -> Bool { trackIDs.contains(track.id) }

    static func contains(id: String) -> Bool { trackIDs.contains(id) }
}
