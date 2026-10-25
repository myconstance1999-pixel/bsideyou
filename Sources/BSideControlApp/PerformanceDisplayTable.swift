// BSideControlApp — canonical reviewed display table for the bundled performance library.
//
// This file IS the reviewed source of truth for curated display context. It is maintained and
// reviewed as ordinary source; the JSON exports under dist/playlist-context-g5o1996r/ are
// derived reports from the bounded offline research pass, not the authority. Every entry
// carries its own inline provenance:
//
//   - `source`  short row label (franchise, composer or tradition). 来源未确认 means the
//               identity could not be established and nothing is guessed.
//   - `album`   verified soundtrack/album context, shown on the row when known.
//   - `work`    familiar work/opus context, kept concise and in Chinese; it never repeats
//               the manifest's English title. An uncertain opus is flagged as uncertain and
//               a conflicting opus is never silently retitled.
//   - `detail`  concise ordinary-playlist context for the detail pane: the source/composer
//               plus the album or work (e.g. 原神 · 游戏原声, 肖邦 · 练习曲 Op.10 No.3「离别」).
//               No provenance/research narrative. For unconfirmed entries it is one short
//               concrete reason (曲名待确认 / 收录来源未确认), never an invented origin.
//   - `evidence` the public URL actually consulted plus the exact claim it supports. Game
//               franchise associations rest on community-maintained Fandom wikis — fan
//               references, NOT official or authoritative publications — and each claim
//               says so. Where only a search-hit list was available the claim says that
//               explicitly; a fetched page extract is only claimed where one was actually
//               retrieved.
//
// Presentation only: keyed by the existing manifest track ID. The fingerprinted manifest,
// media paths/hashes/order and all playback semantics are untouched.
import Foundation

enum PerformanceDisplayTable {
    static let contexts: [String: PerformanceDisplayContext] = [
        // olivia.performance.solo.a-dramatic-irony
        "olivia.performance.solo.a-dramatic-irony": PerformanceDisplayContext(
            source: "崩坏：星穹铁道", album: nil, work: nil,
            detail: "崩坏：星穹铁道 · 游戏原声",
            aliases: ["A Dramatic Irony"],
            confidence: .verified,
            evidence: [
                .init(url: "https://honkai-star-rail.fandom.com/api.php?action=query&list=search&srsearch=A+Dramatic+Irony",
                      claim: "Honkai: Star Rail Fandom（社区维护，非官方） search-hit list only (no fetched page text): 「A Dramatic Irony」. It corroborates this track's association with Honkai: Star Rail."),
            ]),
        // olivia.performance.solo.a-new-day-with-hope
        "olivia.performance.solo.a-new-day-with-hope": PerformanceDisplayContext(
            source: "原神", album: nil, work: nil,
            detail: "原神 · 游戏原声",
            aliases: ["A New Day with Hope"],
            confidence: .verified,
            evidence: [
                .init(url: "https://genshin-impact.fandom.com/api.php?action=query&list=search&srsearch=A+New+Day+with+Hope",
                      claim: "Genshin Impact Fandom（社区维护，非官方） search-hit list only (no fetched page text): 「A New Day with Hope」. It corroborates this track's association with Genshin Impact."),
            ]),
        // olivia.performance.solo.above-the-sea-of-clouds
        "olivia.performance.solo.above-the-sea-of-clouds": PerformanceDisplayContext(
            source: "原神", album: nil, work: nil,
            detail: "原神 · 游戏原声",
            aliases: ["Above the Sea of Clouds"],
            confidence: .verified,
            evidence: [
                .init(url: "https://genshin-impact.fandom.com/api.php?action=query&list=search&srsearch=Above+the+Sea+of+Clouds",
                      claim: "Genshin Impact Fandom（社区维护，非官方） search-hit list only (no fetched page text): 「Above the Sea of Clouds」. It corroborates this track's association with Genshin Impact."),
            ]),
        // olivia.performance.solo.air-on-the-g-string-from-orchestral-suite-no3-in-d-major-bwv-1068
        "olivia.performance.solo.air-on-the-g-string-from-orchestral-suite-no3-in-d-major-bwv-1068": PerformanceDisplayContext(
            source: "巴赫", album: nil, work: "G 弦上的咏叹调",
            detail: "巴赫 · G 弦上的咏叹调",
            aliases: ["Air on the G String"],
            confidence: .verified,
            evidence: [
                .init(url: "https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch=Air+on+the+G+String",
                      claim: "Public catalogue/search reference consulted (search-hit list): public catalogue/search entry 「Air on the G String」 supports 巴赫 — Air on the G String."),
            ]),
        // olivia.performance.solo.another-hopeful-tomorrow
        "olivia.performance.solo.another-hopeful-tomorrow": PerformanceDisplayContext(
            source: "原神", album: nil, work: nil,
            detail: "原神 · 游戏原声",
            aliases: ["Another Hopeful Tomorrow"],
            confidence: .verified,
            evidence: [
                .init(url: "https://genshin-impact.fandom.com/api.php?action=query&list=search&srsearch=Another+Hopeful+Tomorrow",
                      claim: "Genshin Impact Fandom（社区维护，非官方） search-hit list only (no fetched page text): 「Another Hopeful Tomorrow」. It corroborates this track's association with Genshin Impact."),
            ]),
        // olivia.performance.solo.arabesque-no2
        "olivia.performance.solo.arabesque-no2": PerformanceDisplayContext(
            source: "德彪西", album: nil, work: "阿拉伯风格曲 第 2 首",
            detail: "德彪西 · 阿拉伯风格曲 第 2 首",
            aliases: ["Two Arabesques"],
            confidence: .verified,
            evidence: [
                .init(url: "https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch=Two+Arabesques",
                      claim: "Public catalogue/search reference consulted (search-hit list): public catalogue/search entry 「Two Arabesques」 supports 德彪西 — 阿拉伯风格曲 第 2 首."),
            ]),
        // olivia.performance.solo.beethoven-piano-sonata-no8-in-c-minor-op13-2-adagio-cantabile
        "olivia.performance.solo.beethoven-piano-sonata-no8-in-c-minor-op13-2-adagio-cantabile": PerformanceDisplayContext(
            source: "贝多芬", album: nil, work: "第 8 钢琴奏鸣曲「悲怆」第二乐章",
            detail: "贝多芬 · 第 8 钢琴奏鸣曲「悲怆」第二乐章",
            aliases: ["Piano Sonata No. 8 (Beethoven)"],
            confidence: .verified,
            evidence: [
                .init(url: "https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch=Piano+Sonata+No.+8+%28Beethoven%29",
                      claim: "Public catalogue/search reference consulted (search-hit list): public catalogue/search entry 「Piano Sonata No. 8 (Beethoven)」 supports 贝多芬 — 第 8 钢琴奏鸣曲「悲怆」第二乐章."),
            ]),
        // olivia.performance.solo.canon-in-d
        "olivia.performance.solo.canon-in-d": PerformanceDisplayContext(
            source: "帕赫贝尔", album: nil, work: "D 大调卡农",
            detail: "帕赫贝尔 · D 大调卡农",
            aliases: ["Pachelbel's Canon"],
            confidence: .verified,
            evidence: [
                .init(url: "https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch=Pachelbel%27s+Canon",
                      claim: "Public catalogue/search reference consulted (search-hit list): public catalogue/search entry 「Pachelbel's Canon」 supports 帕赫贝尔 — D 大调卡农."),
            ]),
        // olivia.performance.solo.chopin-etude-op10-no1
        "olivia.performance.solo.chopin-etude-op10-no1": PerformanceDisplayContext(
            source: "肖邦", album: nil, work: "练习曲 Op.10 No.1「瀑布」",
            detail: "肖邦 · 练习曲 Op.10 No.1「瀑布」",
            aliases: ["Étude Op. 10, No. 1 (Chopin)"],
            confidence: .verified,
            evidence: [
                .init(url: "https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch=%C3%89tude+Op.+10%2C+No.+1+%28Chopin%29",
                      claim: "Public catalogue/search reference consulted (search-hit list): public catalogue/search entry 「Étude Op. 10, No. 1 (Chopin)」 supports 肖邦 — 练习曲 Op.10 No.1「瀑布」."),
            ]),
        // olivia.performance.solo.chopin-etude-op10-no12
        "olivia.performance.solo.chopin-etude-op10-no12": PerformanceDisplayContext(
            source: "肖邦", album: nil, work: "练习曲 Op.10 No.12「革命」",
            detail: "肖邦 · 练习曲 Op.10 No.12「革命」",
            aliases: ["Étude Op. 10, No. 12 (Chopin)"],
            confidence: .verified,
            evidence: [
                .init(url: "https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch=%C3%89tude+Op.+10%2C+No.+12+%28Chopin%29",
                      claim: "Public catalogue/search reference consulted (search-hit list): public catalogue/search entry 「Étude Op. 10, No. 12 (Chopin)」 supports 肖邦 — 练习曲 Op.10 No.12「革命」."),
            ]),
        // olivia.performance.solo.chopin-etude-op10-no3
        "olivia.performance.solo.chopin-etude-op10-no3": PerformanceDisplayContext(
            source: "肖邦", album: nil, work: "练习曲 Op.10 No.3「离别」",
            detail: "肖邦 · 练习曲 Op.10 No.3「离别」",
            aliases: ["Étude Op. 10, No. 3 (Chopin)"],
            confidence: .verified,
            evidence: [
                .init(url: "https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch=%C3%89tude+Op.+10%2C+No.+3+%28Chopin%29",
                      claim: "Public catalogue/search reference consulted (search-hit list): public catalogue/search entry 「Étude Op. 10, No. 3 (Chopin)」 supports 肖邦 — 练习曲 Op.10 No.3「离别」."),
            ]),
        // olivia.performance.solo.chopin-etude-op10-no5
        "olivia.performance.solo.chopin-etude-op10-no5": PerformanceDisplayContext(
            source: "肖邦", album: nil, work: "练习曲 Op.10 No.5「黑键」",
            detail: "肖邦 · 练习曲 Op.10 No.5「黑键」",
            aliases: ["Étude Op. 10, No. 5 (Chopin)"],
            confidence: .verified,
            evidence: [
                .init(url: "https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch=%C3%89tude+Op.+10%2C+No.+5+%28Chopin%29",
                      claim: "Public catalogue/search reference consulted (search-hit list): public catalogue/search entry 「Étude Op. 10, No. 5 (Chopin)」 supports 肖邦 — 练习曲 Op.10 No.5「黑键」."),
            ]),
        // olivia.performance.solo.chopin-etude-op10-no8
        "olivia.performance.solo.chopin-etude-op10-no8": PerformanceDisplayContext(
            source: "肖邦", album: nil, work: "练习曲 Op.10 No.8",
            detail: "肖邦 · 练习曲 Op.10 No.8",
            aliases: ["Étude Op. 10, No. 8 (Chopin)"],
            confidence: .verified,
            evidence: [
                .init(url: "https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch=%C3%89tude+Op.+10%2C+No.+8+%28Chopin%29",
                      claim: "Public catalogue/search reference consulted (search-hit list): public catalogue/search entry 「Étude Op. 10, No. 8 (Chopin)」 supports 肖邦 — 练习曲 Op.10 No.8."),
            ]),
        // olivia.performance.solo.chopin-etude-op10-no9
        "olivia.performance.solo.chopin-etude-op10-no9": PerformanceDisplayContext(
            source: "肖邦", album: nil, work: "练习曲 Op.10 No.9",
            detail: "肖邦 · 练习曲 Op.10 No.9",
            aliases: ["Étude Op. 10, No. 9 (Chopin)"],
            confidence: .verified,
            evidence: [
                .init(url: "https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch=%C3%89tude+Op.+10%2C+No.+9+%28Chopin%29",
                      claim: "Public catalogue/search reference consulted (search-hit list): public catalogue/search entry 「Étude Op. 10, No. 9 (Chopin)」 supports 肖邦 — 练习曲 Op.10 No.9."),
            ]),
        // olivia.performance.solo.chopin-etude-op25-no12-in-c-minor
        "olivia.performance.solo.chopin-etude-op25-no12-in-c-minor": PerformanceDisplayContext(
            source: "肖邦", album: nil, work: "练习曲 Op.25 No.12「海洋」",
            detail: "肖邦 · 练习曲 Op.25 No.12「海洋」",
            aliases: ["Étude Op. 25, No. 12 (Chopin)"],
            confidence: .verified,
            evidence: [
                .init(url: "https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch=%C3%89tude+Op.+25%2C+No.+12+%28Chopin%29",
                      claim: "Public catalogue/search reference consulted (search-hit list): public catalogue/search entry 「Étude Op. 25, No. 12 (Chopin)」 supports 肖邦 — 练习曲 Op.25 No.12「海洋」."),
            ]),
        // olivia.performance.solo.chopin-etude-op25-no2
        "olivia.performance.solo.chopin-etude-op25-no2": PerformanceDisplayContext(
            source: "肖邦", album: nil, work: "练习曲 Op.25 No.2",
            detail: "肖邦 · 练习曲 Op.25 No.2",
            aliases: ["Étude Op. 25, No. 2 (Chopin)"],
            confidence: .verified,
            evidence: [
                .init(url: "https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch=%C3%89tude+Op.+25%2C+No.+2+%28Chopin%29",
                      claim: "Public catalogue/search reference consulted (search-hit list): public catalogue/search entry 「Étude Op. 25, No. 2 (Chopin)」 supports 肖邦 — 练习曲 Op.25 No.2."),
            ]),
        // olivia.performance.solo.chopin-nocturne-op9-no2
        "olivia.performance.solo.chopin-nocturne-op9-no2": PerformanceDisplayContext(
            source: "肖邦", album: nil, work: "夜曲 Op.9 No.2",
            detail: "肖邦 · 夜曲 Op.9 No.2",
            aliases: ["Nocturnes, Op. 9 (Chopin)"],
            confidence: .verified,
            evidence: [
                .init(url: "https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch=Nocturnes%2C+Op.+9+%28Chopin%29",
                      claim: "Public catalogue/search reference consulted (search-hit list): public catalogue/search entry 「Nocturnes, Op. 9 (Chopin)」 supports 肖邦 — 夜曲 Op.9 No.2."),
            ]),
        // olivia.performance.solo.chopin-op25-no3
        "olivia.performance.solo.chopin-op25-no3": PerformanceDisplayContext(
            source: "肖邦", album: nil, work: "练习曲 Op.25 No.3",
            detail: "肖邦 · 练习曲 Op.25 No.3",
            aliases: ["Étude Op. 25, No. 3 (Chopin)"],
            confidence: .verified,
            evidence: [
                .init(url: "https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch=%C3%89tude+Op.+25%2C+No.+3+%28Chopin%29",
                      claim: "Public catalogue/search reference consulted (search-hit list): public catalogue/search entry 「Étude Op. 25, No. 3 (Chopin)」 supports 肖邦 — 练习曲 Op.25 No.3."),
            ]),
        // olivia.performance.solo.chopin-op28-no4
        "olivia.performance.solo.chopin-op28-no4": PerformanceDisplayContext(
            source: "肖邦", album: nil, work: "前奏曲 Op.28 No.4",
            detail: "肖邦 · 前奏曲 Op.28 No.4",
            aliases: ["Prelude, Op. 28, No. 4 (Chopin)"],
            confidence: .verified,
            evidence: [
                .init(url: "https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch=Prelude%2C+Op.+28%2C+No.+4+%28Chopin%29",
                      claim: "Public catalogue/search reference consulted (search-hit list): public catalogue/search entry 「Prelude, Op. 28, No. 4 (Chopin)」 supports 肖邦 — 前奏曲 Op.28 No.4."),
            ]),
        // olivia.performance.solo.chopin-op40-no1
        "olivia.performance.solo.chopin-op40-no1": PerformanceDisplayContext(
            source: "肖邦", album: nil, work: "波兰舞曲 Op.40 No.1「军队」",
            detail: "肖邦 · 波兰舞曲 Op.40 No.1「军队」",
            aliases: ["Polonaises Op. 40 (Chopin)"],
            confidence: .verified,
            evidence: [
                .init(url: "https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch=Polonaises+Op.+40+%28Chopin%29",
                      claim: "Public catalogue/search reference consulted (search-hit list): public catalogue/search entry 「Polonaises Op. 40 (Chopin)」 supports 肖邦 — 波兰舞曲 Op.40 No.1「军队」."),
            ]),
        // olivia.performance.solo.chopin-op64-no2
        "olivia.performance.solo.chopin-op64-no2": PerformanceDisplayContext(
            source: "肖邦", album: nil, work: "圆舞曲 Op.64 No.2",
            detail: "肖邦 · 圆舞曲 Op.64 No.2",
            aliases: ["Waltz in C-sharp minor, Op. 64, No. 2 (Chopin)"],
            confidence: .verified,
            evidence: [
                .init(url: "https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch=Waltz+in+C-sharp+minor%2C+Op.+64%2C+No.+2+%28Chopin%29",
                      claim: "Public catalogue/search reference consulted (search-hit list): public catalogue/search entry 「Waltz in C-sharp minor, Op. 64, No. 2 (Chopin)」 supports 肖邦 — 圆舞曲 Op.64 No.2."),
            ]),
        // olivia.performance.solo.clear-sky-over-liyue
        "olivia.performance.solo.clear-sky-over-liyue": PerformanceDisplayContext(
            source: "原神", album: nil, work: nil,
            detail: "原神 · 游戏原声",
            aliases: ["Clear Sky Over Liyue"],
            confidence: .verified,
            evidence: [
                .init(url: "https://genshin-impact.fandom.com/api.php?action=query&list=search&srsearch=Clear+Sky+Over+Liyue",
                      claim: "Genshin Impact Fandom（社区维护，非官方） search-hit list only (no fetched page text): 「Clear Sky Over Liyue」. It corroborates this track's association with Genshin Impact."),
            ]),
        // olivia.performance.solo.consolation-no3-in-d-flat-major
        "olivia.performance.solo.consolation-no3-in-d-flat-major": PerformanceDisplayContext(
            source: "李斯特", album: nil, work: "慰藉曲 第 3 首",
            detail: "李斯特 · 慰藉曲 第 3 首",
            aliases: ["Consolations (Liszt)"],
            confidence: .verified,
            evidence: [
                .init(url: "https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch=Consolations+%28Liszt%29",
                      claim: "Public catalogue/search reference consulted (search-hit list): public catalogue/search entry 「Consolations (Liszt)」 supports 李斯特 — 慰藉曲 第 3 首."),
            ]),
        // olivia.performance.solo.croatian-rhapsody
        "olivia.performance.solo.croatian-rhapsody": PerformanceDisplayContext(
            source: "马克西姆·姆尔维察", album: nil, work: "克罗地亚狂想曲",
            detail: "马克西姆·姆尔维察 · 克罗地亚狂想曲",
            aliases: ["Croatian Rhapsody", "Maksim Mrvica"],
            confidence: .verified,
            evidence: [
                .init(url: "https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch=Croatian+Rhapsody+Maksim+Mrvica",
                      claim: "Public catalogue/search reference consulted (search-hit list): 「Croatian Rhapsody / Maksim Mrvica」 attributes the piece to Maksim Mrvica."),
            ]),
        // olivia.performance.solo.dance-of-the-gnomes-no2
        "olivia.performance.solo.dance-of-the-gnomes-no2": PerformanceDisplayContext(
            source: "李斯特", album: nil, work: "精灵之舞 第 2 首",
            detail: "李斯特 · 精灵之舞 第 2 首",
            aliases: ["Two Concert Études (Liszt)"],
            confidence: .verified,
            evidence: [
                .init(url: "https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch=Two+Concert+%C3%89tudes+%28Liszt%29",
                      claim: "Public catalogue/search reference consulted (search-hit list): public catalogue/search entry 「Two Concert Études (Liszt)」 supports 李斯特 — 精灵之舞 第 2 首."),
            ]),
        // olivia.performance.solo.dawn-winery-theme
        "olivia.performance.solo.dawn-winery-theme": PerformanceDisplayContext(
            source: "原神", album: nil, work: nil,
            detail: "原神 · 游戏原声",
            aliases: ["Dawn Winery Theme"],
            confidence: .verified,
            evidence: [
                .init(url: "https://genshin-impact.fandom.com/api.php?action=query&list=search&srsearch=Dawn+Winery+Theme",
                      claim: "Genshin Impact Fandom（社区维护，非官方） search-hit list only (no fetched page text): 「Dawn Winery Theme」. It corroborates this track's association with Genshin Impact."),
            ]),
        // olivia.performance.solo.debussy-moonlight
        "olivia.performance.solo.debussy-moonlight": PerformanceDisplayContext(
            source: "德彪西", album: nil, work: "月光",
            detail: "德彪西 · 月光",
            aliases: ["Suite bergamasque"],
            confidence: .verified,
            evidence: [
                .init(url: "https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch=Suite+bergamasque",
                      claim: "Public catalogue/search reference consulted (search-hit list): public catalogue/search entry 「Suite bergamasque」 supports 德彪西 — 月光."),
            ]),
        // olivia.performance.solo.debussy-reverie
        "olivia.performance.solo.debussy-reverie": PerformanceDisplayContext(
            source: "德彪西", album: nil, work: "梦幻曲",
            detail: "德彪西 · 梦幻曲",
            aliases: ["Rêverie (Debussy)"],
            confidence: .verified,
            evidence: [
                .init(url: "https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch=R%C3%AAverie+%28Debussy%29",
                      claim: "Public catalogue/search reference consulted (search-hit list): public catalogue/search entry 「Rêverie (Debussy)」 supports 德彪西 — 梦幻曲."),
            ]),
        // olivia.performance.solo.down-by-the-forgotten-gardens
        "olivia.performance.solo.down-by-the-forgotten-gardens": PerformanceDisplayContext(
            source: "原神", album: nil, work: nil,
            detail: "原神 · 游戏原声",
            aliases: ["Down by the Forgotten Gardens"],
            confidence: .verified,
            evidence: [
                .init(url: "https://genshin-impact.fandom.com/api.php?action=query&list=search&srsearch=Down+by+the+Forgotten+Gardens",
                      claim: "Genshin Impact Fandom（社区维护，非官方） search-hit list only (no fetched page text): 「Down by the Forgotten Gardens」. It corroborates this track's association with Genshin Impact."),
            ]),
        // olivia.performance.solo.dream-of-scattered-petals
        "olivia.performance.solo.dream-of-scattered-petals": PerformanceDisplayContext(
            source: "原神", album: nil, work: nil,
            detail: "原神 · 游戏原声",
            aliases: ["Dream of Scattered Petals"],
            confidence: .verified,
            evidence: [
                .init(url: "https://genshin-impact.fandom.com/api.php?action=query&list=search&srsearch=Dream+of+Scattered+Petals",
                      claim: "Genshin Impact Fandom（社区维护，非官方） search-hit list only (no fetched page text): 「Dream of Scattered Petals」. It corroborates this track's association with Genshin Impact."),
            ]),
        // olivia.performance.solo.dwelling-in-the-past
        "olivia.performance.solo.dwelling-in-the-past": PerformanceDisplayContext(
            source: "原神", album: nil, work: nil,
            detail: "原神 · 游戏原声",
            aliases: ["Dwelling in the Past"],
            confidence: .verified,
            evidence: [
                .init(url: "https://genshin-impact.fandom.com/api.php?action=query&list=search&srsearch=Dwelling+in+the+Past",
                      claim: "Genshin Impact Fandom（社区维护，非官方） search-hit list only (no fetched page text): 「Dwelling in the Past」. It corroborates this track's association with Genshin Impact."),
            ]),
        // olivia.performance.solo.ethereal-mildness
        "olivia.performance.solo.ethereal-mildness": PerformanceDisplayContext(
            source: "原神", album: nil, work: nil,
            detail: "原神 · 游戏原声",
            aliases: ["Ethereal Mildness"],
            confidence: .verified,
            evidence: [
                .init(url: "https://genshin-impact.fandom.com/api.php?action=query&list=search&srsearch=Ethereal+Mildness",
                      claim: "Genshin Impact Fandom（社区维护，非官方） search-hit list only (no fetched page text): 「Ethereal Mildness」. It corroborates this track's association with Genshin Impact."),
            ]),
        // olivia.performance.solo.flight-of-the-bumblebee-jazz-version
        "olivia.performance.solo.flight-of-the-bumblebee-jazz-version": PerformanceDisplayContext(
            source: "里姆斯基-科萨科夫", album: nil, work: "野蜂飞舞（爵士改编）",
            detail: "里姆斯基-科萨科夫 · 野蜂飞舞（爵士改编）",
            aliases: ["Flight of the Bumblebee"],
            confidence: .verified,
            evidence: [
                .init(url: "https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch=Flight+of+the+Bumblebee",
                      claim: "Public catalogue/search reference consulted (search-hit list): 「Flight of the Bumblebee」 identifies the original work; the jazz arrangement itself has no separate public entry."),
            ]),
        // olivia.performance.solo.footprints
        "olivia.performance.solo.footprints": PerformanceDisplayContext(
            source: "来源未确认", album: nil, work: nil,
            detail: "同名作品较多，具体作品待确认。",
            aliases: ["footprints"],
            confidence: .unconfirmed,
            evidence: [
                .init(url: "https://genshin-impact.fandom.com/api.php?action=query&list=search&srsearch=Footprints+of+the+Traveler",
                      claim: "Footprints of the Traveler is an album name, not an exact track identity match; reject prior attribution."),
            ]),
        // olivia.performance.solo.for-riddles-for-wonders
        "olivia.performance.solo.for-riddles-for-wonders": PerformanceDisplayContext(
            source: "原神", album: nil, work: nil,
            detail: "原神 · 游戏原声",
            aliases: ["For Riddles, for Wonders"],
            confidence: .verified,
            evidence: [
                .init(url: "https://genshin-impact.fandom.com/api.php?action=query&list=search&srsearch=For+Riddles%2C+for+Wonders",
                      claim: "Genshin Impact Fandom（社区维护，非官方） search-hit list only (no fetched page text): 「For Riddles, for Wonders」. It corroborates this track's association with Genshin Impact."),
            ]),
        // olivia.performance.solo.good-night-liyue
        "olivia.performance.solo.good-night-liyue": PerformanceDisplayContext(
            source: "原神", album: nil, work: nil,
            detail: "原神 · 游戏原声",
            aliases: ["Good Night, Liyue"],
            confidence: .verified,
            evidence: [
                .init(url: "https://genshin-impact.fandom.com/api.php?action=query&list=search&srsearch=Good+Night%2C+Liyue",
                      claim: "Genshin Impact Fandom（社区维护，非官方） search-hit list only (no fetched page text): 「Good Night, Liyue」. It corroborates this track's association with Genshin Impact."),
            ]),
        // olivia.performance.solo.grande-polonaise-brillante-op22-p1
        "olivia.performance.solo.grande-polonaise-brillante-op22-p1": PerformanceDisplayContext(
            source: "肖邦", album: nil, work: "大华丽波兰舞曲 Op.22 第一部分",
            detail: "肖邦 · 大华丽波兰舞曲 Op.22 第一部分",
            aliases: ["平靜的行板與華麗的大波蘭舞曲22號 (音樂)"],
            confidence: .verified,
            evidence: [
                .init(url: "https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch=%E5%B9%B3%E9%9D%9C%E7%9A%84%E8%A1%8C%E6%9D%BF%E8%88%87%E8%8F%AF%E9%BA%97%E7%9A%84%E5%A4%A7%E6%B3%A2%E8%98%AD%E8%88%9E%E6%9B%B222%E8%99%9F+%28%E9%9F%B3%E6%A8%82%29",
                      claim: "Public catalogue/search reference consulted (search-hit list): public catalogue/search entry 「平靜的行板與華麗的大波蘭舞曲22號 (音樂)」 supports 肖邦 — 大华丽波兰舞曲 Op.22 第一部分."),
            ]),
        // olivia.performance.solo.grande-polonaise-brillante-op22-p2
        "olivia.performance.solo.grande-polonaise-brillante-op22-p2": PerformanceDisplayContext(
            source: "肖邦", album: nil, work: "大华丽波兰舞曲 Op.22 第二部分",
            detail: "肖邦 · 大华丽波兰舞曲 Op.22 第二部分",
            aliases: ["平靜的行板與華麗的大波蘭舞曲22號 (音樂)"],
            confidence: .verified,
            evidence: [
                .init(url: "https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch=%E5%B9%B3%E9%9D%9C%E7%9A%84%E8%A1%8C%E6%9D%BF%E8%88%87%E8%8F%AF%E9%BA%97%E7%9A%84%E5%A4%A7%E6%B3%A2%E8%98%AD%E8%88%9E%E6%9B%B222%E8%99%9F+%28%E9%9F%B3%E6%A8%82%29",
                      claim: "Public catalogue/search reference consulted (search-hit list): public catalogue/search entry 「平靜的行板與華麗的大波蘭舞曲22號 (音樂)」 supports 肖邦 — 大华丽波兰舞曲 Op.22 第二部分."),
            ]),
        // olivia.performance.solo.gymnopedie-no1
        "olivia.performance.solo.gymnopedie-no1": PerformanceDisplayContext(
            source: "萨蒂", album: nil, work: "裸体舞曲 第 1 首",
            detail: "萨蒂 · 裸体舞曲 第 1 首",
            aliases: ["Gymnopédies"],
            confidence: .verified,
            evidence: [
                .init(url: "https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch=Gymnop%C3%A9dies",
                      claim: "Public catalogue/search reference consulted (search-hit list): public catalogue/search entry 「Gymnopédies」 supports 萨蒂 — 裸体舞曲 第 1 首."),
            ]),
        // olivia.performance.solo.gymnopedies-of-lune
        "olivia.performance.solo.gymnopedies-of-lune": PerformanceDisplayContext(
            source: "原神", album: nil, work: nil,
            detail: "原神 · 游戏原声",
            aliases: ["Gymnopedies of Lune"],
            confidence: .verified,
            evidence: [
                .init(url: "https://genshin-impact.fandom.com/api.php?action=query&list=search&srsearch=Gymnopedies+of+Lune",
                      claim: "Genshin Impact Fandom（社区维护，非官方） search-hit list only (no fetched page text): 「Gymnopedies of Lune」. It corroborates this track's association with Genshin Impact."),
            ]),
        // olivia.performance.solo.hanachirusato
        "olivia.performance.solo.hanachirusato": PerformanceDisplayContext(
            source: "原神", album: nil, work: nil,
            detail: "原神 · 游戏原声",
            aliases: ["Hanachirusato"],
            confidence: .verified,
            evidence: [
                .init(url: "https://genshin-impact.fandom.com/api.php?action=query&list=search&srsearch=Hanachirusato",
                      claim: "Genshin Impact Fandom（社区维护，非官方） search-hit list only (no fetched page text): 「Hanachirusato」. It corroborates this track's association with Genshin Impact."),
            ]),
        // olivia.performance.solo.hence-begins-the-journey
        "olivia.performance.solo.hence-begins-the-journey": PerformanceDisplayContext(
            source: "原神", album: nil, work: nil,
            detail: "原神 · 游戏原声",
            aliases: ["Hence, Begins the Journey"],
            confidence: .verified,
            evidence: [
                .init(url: "https://genshin-impact.fandom.com/api.php?action=query&list=search&srsearch=Hence%2C+Begins+the+Journey",
                      claim: "Genshin Impact Fandom（社区维护，非官方） search-hit list only (no fetched page text): 「Hence, Begins the Journey」. It corroborates this track's association with Genshin Impact."),
            ]),
        // olivia.performance.solo.honkai-star-rail-opening-theme
        "olivia.performance.solo.honkai-star-rail-opening-theme": PerformanceDisplayContext(
            source: "来源未确认", album: nil, work: nil,
            detail: "曲名待确认",
            aliases: ["Honkai: Star Rail Opening Theme"],
            confidence: .unconfirmed,
            evidence: [
                .init(url: "https://honkai-star-rail.fandom.com/api.php?action=query&list=search&srsearch=Honkai%3A+Star+Rail+Opening+Theme",
                      claim: "Honkai: Star Rail Fandom（社区维护，非官方） search-hit list only (no fetched page text): 无同名曲目条目. It corroborates nothing beyond the game's general existence; the specific opening theme stays unidentified."),
            ]),
        // olivia.performance.solo.impromptu-in-g-flat-major-op90-no3
        "olivia.performance.solo.impromptu-in-g-flat-major-op90-no3": PerformanceDisplayContext(
            source: "舒伯特", album: nil, work: "降 G 大调即兴曲 Op.90 No.3",
            detail: "舒伯特 · 降 G 大调即兴曲 Op.90 No.3",
            aliases: ["Impromptus, Op. 90 (Schubert)"],
            confidence: .verified,
            evidence: [
                .init(url: "https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch=Impromptus%2C+Op.+90+%28Schubert%29",
                      claim: "Public catalogue/search reference consulted (search-hit list): public catalogue/search entry 「Impromptus, Op. 90 (Schubert)」 supports 舒伯特 — 降 G 大调即兴曲 Op.90 No.3."),
            ]),
        // olivia.performance.solo.le-duc-sous-leau
        "olivia.performance.solo.le-duc-sous-leau": PerformanceDisplayContext(
            source: "原神", album: nil, work: nil,
            detail: "原神 · 游戏原声",
            aliases: ["Le duc sous l'eau"],
            confidence: .verified,
            evidence: [
                .init(url: "https://genshin-impact.fandom.com/api.php?action=query&list=search&srsearch=Le+duc+sous+l%27eau",
                      claim: "Genshin Impact Fandom（社区维护，非官方） search-hit list only (no fetched page text): 「Le duc sous l'eau」. It corroborates this track's association with Genshin Impact."),
            ]),
        // olivia.performance.solo.leisure-in-painting
        "olivia.performance.solo.leisure-in-painting": PerformanceDisplayContext(
            source: "原神", album: nil, work: nil,
            detail: "原神 · 游戏原声",
            aliases: ["Leisure in Painting"],
            confidence: .verified,
            evidence: [
                .init(url: "https://genshin-impact.fandom.com/api.php?action=query&list=search&srsearch=Leisure+in+Painting",
                      claim: "Genshin Impact Fandom（社区维护，非官方） search-hit list only (no fetched page text): 「Leisure in Painting」. It corroborates this track's association with Genshin Impact."),
            ]),
        // olivia.performance.solo.liyue
        "olivia.performance.solo.liyue": PerformanceDisplayContext(
            source: "原神", album: nil, work: nil,
            detail: "原神 · 游戏原声",
            aliases: ["Liyue"],
            confidence: .verified,
            evidence: [
                .init(url: "https://genshin-impact.fandom.com/api.php?action=query&list=search&srsearch=Liyue",
                      claim: "Genshin Impact Fandom（社区维护，非官方） search-hit list only (no fetched page text): 「Liyue」. It corroborates this track's association with Genshin Impact."),
            ]),
        // olivia.performance.solo.lustrous-stars
        "olivia.performance.solo.lustrous-stars": PerformanceDisplayContext(
            source: "原神", album: nil, work: nil,
            detail: "原神 · 游戏原声",
            aliases: ["Lustrous Stars"],
            confidence: .verified,
            evidence: [
                .init(url: "https://genshin-impact.fandom.com/api.php?action=query&list=search&srsearch=Lustrous+Stars",
                      claim: "Genshin Impact Fandom（社区维护，非官方） search-hit list only (no fetched page text): 「Lustrous Stars」. It corroborates this track's association with Genshin Impact."),
            ]),
        // olivia.performance.solo.lyphard-melody
        "olivia.performance.solo.lyphard-melody": PerformanceDisplayContext(
            source: "理查德·克莱德曼", album: nil, work: "星空 Lyphard Melody",
            detail: "理查德·克莱德曼 · 星空 Lyphard Melody",
            aliases: ["Lyphard Melody", "Richard Clayderman"],
            confidence: .verified,
            evidence: [
                .init(url: "https://zh.wikipedia.org/w/api.php?action=query&list=search&srsearch=%E7%90%86%E6%9F%A5%C2%B7%E5%85%8B%E8%90%8A%E5%BE%B7%E6%9B%BC",
                      claim: "Public catalogue/search reference consulted (search-hit list): 「理查·克萊德曼」 identifies the performer; the Lyphard Melody page text was not fetched."),
            ]),
        // olivia.performance.solo.minute-waltz-op64-no1
        "olivia.performance.solo.minute-waltz-op64-no1": PerformanceDisplayContext(
            source: "肖邦", album: nil, work: "小狗圆舞曲 Op.64 No.1",
            detail: "肖邦 · 小狗圆舞曲 Op.64 No.1",
            aliases: ["Minute Waltz"],
            confidence: .verified,
            evidence: [
                .init(url: "https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch=Minute+Waltz",
                      claim: "Public catalogue/search reference consulted (search-hit list): public catalogue/search entry 「Minute Waltz」 supports 肖邦 — 小狗圆舞曲 Op.64 No.1."),
            ]),
        // olivia.performance.solo.moment-musical-no3-in-f-minor-op94
        "olivia.performance.solo.moment-musical-no3-in-f-minor-op94": PerformanceDisplayContext(
            source: "舒伯特", album: nil, work: "f 小调音乐瞬间 Op.94 No.3",
            detail: "舒伯特 · f 小调音乐瞬间 Op.94 No.3",
            aliases: ["Moment musical"],
            confidence: .verified,
            evidence: [
                .init(url: "https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch=Moment+musical",
                      claim: "Public catalogue/search reference consulted (search-hit list): public catalogue/search entry 「Moment musical」 supports 舒伯特 — f 小调音乐瞬间 Op.94 No.3."),
            ]),
        // olivia.performance.solo.moonlike-smile
        "olivia.performance.solo.moonlike-smile": PerformanceDisplayContext(
            source: "原神", album: "皎洁的笑颜", work: nil,
            detail: "原神 · 游戏原声 · 皎洁的笑颜",
            aliases: ["Moonlike Smile"],
            confidence: .verified,
            evidence: [
                .init(url: "https://genshin-impact.fandom.com/api.php?action=query&list=search&srsearch=Moonlike+Smile",
                      claim: "Genshin Impact Fandom（社区维护，非官方） search-hit list only (no fetched page text): 「Moonlike Smile」. It corroborates this track's association with Genshin Impact."),
            ]),
        // olivia.performance.solo.nocturne-no3-in-b-major-for-piano-solo
        "olivia.performance.solo.nocturne-no3-in-b-major-for-piano-solo": PerformanceDisplayContext(
            source: "肖邦", album: nil, work: "B 大调第 3 夜曲",
            detail: "肖邦 · B 大调第 3 夜曲",
            aliases: ["Nocturnes, Op. 9 (Chopin)"],
            confidence: .verified,
            evidence: [
                .init(url: "https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch=Nocturnes%2C+Op.+9+%28Chopin%29",
                      claim: "Public catalogue/search reference consulted (search-hit list): public catalogue/search entry 「Nocturnes, Op. 9 (Chopin)」 supports 肖邦 — B 大调第 3 夜曲."),
                .init(url: "https://www.chopincompetition.pl/en/compositions/157?id_stage=7",
                      claim: "Public competition repertoire catalogue (controller-verified): the B-major nocturne completing Chopin's Op.9 set is No.3. This corroborates the catalogue title only; it is not audio identification."),
            ]),
        // olivia.performance.solo.notturno-op-54-no4
        "olivia.performance.solo.notturno-op-54-no4": PerformanceDisplayContext(
            source: "格里格", album: nil, work: "夜曲 Op.54 No.4",
            detail: "格里格 · 夜曲 Op.54 No.4",
            aliases: ["Lyric Pieces"],
            confidence: .verified,
            evidence: [
                .init(url: "https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch=Lyric+Pieces",
                      claim: "Public catalogue/search reference consulted (search-hit list): public catalogue/search entry 「Lyric Pieces」 supports 格里格 — 夜曲 Op.54 No.4."),
            ]),
        // olivia.performance.solo.once-joyful-dream
        "olivia.performance.solo.once-joyful-dream": PerformanceDisplayContext(
            source: "原神", album: nil, work: nil,
            detail: "原神 · 游戏原声",
            aliases: ["Once-Joyful Dream"],
            confidence: .verified,
            evidence: [
                .init(url: "https://genshin-impact.fandom.com/api.php?action=query&list=search&srsearch=Once-Joyful+Dream",
                      claim: "Genshin Impact Fandom（社区维护，非官方） search-hit list only (no fetched page text): 「Once-Joyful Dream」. It corroborates this track's association with Genshin Impact."),
            ]),
        // olivia.performance.solo.ondulations-du-rythme
        "olivia.performance.solo.ondulations-du-rythme": PerformanceDisplayContext(
            source: "原神", album: nil, work: nil,
            detail: "原神 · 游戏原声",
            aliases: ["Ondulations du rythme"],
            confidence: .verified,
            evidence: [
                .init(url: "https://genshin-impact.fandom.com/api.php?action=query&list=search&srsearch=Ondulations+du+rythme",
                      claim: "Genshin Impact Fandom（社区维护，非官方） search-hit list only (no fetched page text): 「Ondulations du rythme」. It corroborates this track's association with Genshin Impact."),
            ]),
        // olivia.performance.solo.pathway-to-the-hidden-isles
        "olivia.performance.solo.pathway-to-the-hidden-isles": PerformanceDisplayContext(
            source: "原神", album: nil, work: nil,
            detail: "原神 · 游戏原声",
            aliases: ["Pathway to the Hidden Isles"],
            confidence: .verified,
            evidence: [
                .init(url: "https://genshin-impact.fandom.com/api.php?action=query&list=search&srsearch=Pathway+to+the+Hidden+Isles",
                      claim: "Genshin Impact Fandom（社区维护，非官方） search-hit list only (no fetched page text): 「Pathway to the Hidden Isles」. It corroborates this track's association with Genshin Impact."),
            ]),
        // olivia.performance.solo.pavane-for-a-dead-princess
        "olivia.performance.solo.pavane-for-a-dead-princess": PerformanceDisplayContext(
            source: "拉威尔", album: nil, work: "悼念公主的帕凡舞曲",
            detail: "拉威尔 · 悼念公主的帕凡舞曲",
            aliases: ["Pavane pour une infante défunte"],
            confidence: .verified,
            evidence: [
                .init(url: "https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch=Pavane+pour+une+infante+d%C3%A9funte",
                      claim: "Public catalogue/search reference consulted (search-hit list): public catalogue/search entry 「Pavane pour une infante défunte」 supports 拉威尔 — 悼念公主的帕凡舞曲."),
            ]),
        // olivia.performance.solo.peaceful-wishes
        "olivia.performance.solo.peaceful-wishes": PerformanceDisplayContext(
            source: "原神", album: nil, work: nil,
            detail: "原神 · 游戏原声",
            aliases: ["Peaceful Wishes"],
            confidence: .verified,
            evidence: [
                .init(url: "https://genshin-impact.fandom.com/api.php?action=query&list=search&srsearch=Peaceful+Wishes",
                      claim: "Genshin Impact Fandom（社区维护，非官方） search-hit list only (no fetched page text): 「Peaceful Wishes」. It corroborates this track's association with Genshin Impact."),
            ]),
        // olivia.performance.solo.piano-sonata-no13-k333
        "olivia.performance.solo.piano-sonata-no13-k333": PerformanceDisplayContext(
            source: "莫扎特", album: nil, work: "第 13 钢琴奏鸣曲 K.333",
            detail: "莫扎特 · 第 13 钢琴奏鸣曲 K.333",
            aliases: ["Piano Sonata No. 13 (Mozart)"],
            confidence: .verified,
            evidence: [
                .init(url: "https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch=Piano+Sonata+No.+13+%28Mozart%29",
                      claim: "Public catalogue/search reference consulted (search-hit list): public catalogue/search entry 「Piano Sonata No. 13 (Mozart)」 supports 莫扎特 — 第 13 钢琴奏鸣曲 K.333."),
            ]),
        // olivia.performance.solo.piano-sonata-no16-k545
        "olivia.performance.solo.piano-sonata-no16-k545": PerformanceDisplayContext(
            source: "莫扎特", album: nil, work: "第 16 钢琴奏鸣曲 K.545",
            detail: "莫扎特 · 第 16 钢琴奏鸣曲 K.545",
            aliases: ["Piano Sonata No. 16 (Mozart)"],
            confidence: .verified,
            evidence: [
                .init(url: "https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch=Piano+Sonata+No.+16+%28Mozart%29",
                      claim: "Public catalogue/search reference consulted (search-hit list): public catalogue/search entry 「Piano Sonata No. 16 (Mozart)」 supports 莫扎特 — 第 16 钢琴奏鸣曲 K.545."),
            ]),
        // olivia.performance.solo.piano-sonata-no17-in-d-minor-op31-no2-tempest-1-largo
        "olivia.performance.solo.piano-sonata-no17-in-d-minor-op31-no2-tempest-1-largo": PerformanceDisplayContext(
            source: "贝多芬", album: nil, work: "第 17 钢琴奏鸣曲「暴风雨」第一乐章",
            detail: "贝多芬 · 第 17 钢琴奏鸣曲「暴风雨」第一乐章",
            aliases: ["Piano Sonata No. 17 (Beethoven)"],
            confidence: .verified,
            evidence: [
                .init(url: "https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch=Piano+Sonata+No.+17+%28Beethoven%29",
                      claim: "Public catalogue/search reference consulted (search-hit list): public catalogue/search entry 「Piano Sonata No. 17 (Beethoven)」 supports 贝多芬 — 第 17 钢琴奏鸣曲「暴风雨」第一乐章."),
            ]),
        // olivia.performance.solo.prelude-and-fugue-in-c-minor-bwv-847-p1
        "olivia.performance.solo.prelude-and-fugue-in-c-minor-bwv-847-p1": PerformanceDisplayContext(
            source: "巴赫", album: nil, work: "c 小调前奏曲与赋格 BWV 847 前奏曲",
            detail: "巴赫 · c 小调前奏曲与赋格 BWV 847 前奏曲",
            aliases: ["Prelude and Fugue in C minor, BWV 847"],
            confidence: .verified,
            evidence: [
                .init(url: "https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch=Prelude+and+Fugue+in+C+minor%2C+BWV+847",
                      claim: "Public catalogue/search reference consulted (search-hit list): public catalogue/search entry 「Prelude and Fugue in C minor, BWV 847」 supports 巴赫 — c 小调前奏曲与赋格 BWV 847 前奏曲."),
            ]),
        // olivia.performance.solo.prelude-and-fugue-in-c-minor-bwv-847-p2
        "olivia.performance.solo.prelude-and-fugue-in-c-minor-bwv-847-p2": PerformanceDisplayContext(
            source: "巴赫", album: nil, work: "c 小调前奏曲与赋格 BWV 847 赋格",
            detail: "巴赫 · c 小调前奏曲与赋格 BWV 847 赋格",
            aliases: ["Prelude and Fugue in C minor, BWV 847"],
            confidence: .verified,
            evidence: [
                .init(url: "https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch=Prelude+and+Fugue+in+C+minor%2C+BWV+847",
                      claim: "Public catalogue/search reference consulted (search-hit list): public catalogue/search entry 「Prelude and Fugue in C minor, BWV 847」 supports 巴赫 — c 小调前奏曲与赋格 BWV 847 赋格."),
            ]),
        // olivia.performance.solo.prelude-in-g-minor-op23-no5
        "olivia.performance.solo.prelude-in-g-minor-op23-no5": PerformanceDisplayContext(
            source: "拉赫玛尼诺夫", album: nil, work: "g 小调前奏曲 Op.23 No.5",
            detail: "拉赫玛尼诺夫 · g 小调前奏曲 Op.23 No.5",
            aliases: ["Prelude in G minor (Rachmaninoff)"],
            confidence: .verified,
            evidence: [
                .init(url: "https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch=Prelude+in+G+minor+%28Rachmaninoff%29",
                      claim: "Public catalogue/search reference consulted (search-hit list): public catalogue/search entry 「Prelude in G minor (Rachmaninoff)」 supports 拉赫玛尼诺夫 — g 小调前奏曲 Op.23 No.5."),
            ]),
        // olivia.performance.solo.pure-sky
        "olivia.performance.solo.pure-sky": PerformanceDisplayContext(
            source: "原神", album: nil, work: nil,
            detail: "原神 · 游戏原声",
            aliases: ["Pure Sky"],
            confidence: .verified,
            evidence: [
                .init(url: "https://genshin-impact.fandom.com/api.php?action=query&list=search&srsearch=Pure+Sky",
                      claim: "Genshin Impact Fandom（社区维护，非官方） search-hit list only (no fetched page text): 「Pure Sky」. It corroborates this track's association with Genshin Impact."),
            ]),
        // olivia.performance.solo.qingyun-peak-theme
        "olivia.performance.solo.qingyun-peak-theme": PerformanceDisplayContext(
            source: "原神", album: nil, work: nil,
            detail: "原神 · 游戏原声",
            aliases: ["Qingyun Peak"],
            confidence: .verified,
            evidence: [
                .init(url: "https://genshin-impact.fandom.com/api.php?action=query&list=search&srsearch=Qingyun+Peak",
                      claim: "Genshin Impact Fandom（社区维护，非官方） search-hit list only (no fetched page text): 「Qingyun Peak」. It corroborates this track's association with Genshin Impact."),
            ]),
        // olivia.performance.solo.rays-of-sunlight
        "olivia.performance.solo.rays-of-sunlight": PerformanceDisplayContext(
            source: "原神", album: nil, work: nil,
            detail: "原神 · 游戏原声",
            aliases: ["Rays of Sunlight"],
            confidence: .verified,
            evidence: [
                .init(url: "https://genshin-impact.fandom.com/api.php?action=query&list=search&srsearch=Rays+of+Sunlight",
                      claim: "Genshin Impact Fandom（社区维护，非官方） search-hit list only (no fetched page text): 「Rays of Sunlight」. It corroborates this track's association with Genshin Impact."),
            ]),
        // olivia.performance.solo.resonance-of-khvarena
        "olivia.performance.solo.resonance-of-khvarena": PerformanceDisplayContext(
            source: "原神", album: nil, work: nil,
            detail: "原神 · 游戏原声",
            aliases: ["Resonance of Khvarena"],
            confidence: .verified,
            evidence: [
                .init(url: "https://genshin-impact.fandom.com/api.php?action=query&list=search&srsearch=Resonance+of+Khvarena",
                      claim: "Genshin Impact Fandom（社区维护，非官方） search-hit list only (no fetched page text): 「Resonance of Khvarena」. It corroborates this track's association with Genshin Impact."),
            ]),
        // olivia.performance.solo.rex-incognito
        "olivia.performance.solo.rex-incognito": PerformanceDisplayContext(
            source: "原神", album: nil, work: nil,
            detail: "原神 · 游戏原声",
            aliases: ["Rex Incognito"],
            confidence: .verified,
            evidence: [
                .init(url: "https://genshin-impact.fandom.com/api.php?action=query&list=search&srsearch=Rex+Incognito",
                      claim: "Genshin Impact Fandom（社区维护，非官方） search-hit list only (no fetched page text): 「Rex Incognito」. It corroborates this track's association with Genshin Impact."),
            ]),
        // olivia.performance.solo.rhapsodie-espagnole-s254-p1
        "olivia.performance.solo.rhapsodie-espagnole-s254-p1": PerformanceDisplayContext(
            source: "李斯特", album: nil, work: "西班牙狂想曲 S.254 第一部分",
            detail: "李斯特 · 西班牙狂想曲 S.254 第一部分",
            aliases: ["Rhapsodie espagnole"],
            confidence: .verified,
            evidence: [
                .init(url: "https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch=Rhapsodie+espagnole",
                      claim: "Public catalogue/search reference consulted (search-hit list): public catalogue/search entry 「Rhapsodie espagnole」 supports 李斯特 — 西班牙狂想曲 S.254 第一部分."),
            ]),
        // olivia.performance.solo.rhapsodie-espagnole-s254-p2
        "olivia.performance.solo.rhapsodie-espagnole-s254-p2": PerformanceDisplayContext(
            source: "李斯特", album: nil, work: "西班牙狂想曲 S.254 第二部分",
            detail: "李斯特 · 西班牙狂想曲 S.254 第二部分",
            aliases: ["Rhapsodie espagnole"],
            confidence: .verified,
            evidence: [
                .init(url: "https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch=Rhapsodie+espagnole",
                      claim: "Public catalogue/search reference consulted (search-hit list): public catalogue/search entry 「Rhapsodie espagnole」 supports 李斯特 — 西班牙狂想曲 S.254 第二部分."),
            ]),
        // olivia.performance.solo.scarlatti-sonata-in-d-minor-k213
        "olivia.performance.solo.scarlatti-sonata-in-d-minor-k213": PerformanceDisplayContext(
            source: "斯卡拉蒂", album: nil, work: "d 小调奏鸣曲 K.213",
            detail: "斯卡拉蒂 · d 小调奏鸣曲 K.213",
            aliases: ["Domenico Scarlatti"],
            confidence: .verified,
            evidence: [
                .init(url: "https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch=Domenico+Scarlatti",
                      claim: "Public catalogue/search reference consulted (search-hit list): public catalogue/search entry 「Domenico Scarlatti」 supports 斯卡拉蒂 — d 小调奏鸣曲 K.213."),
            ]),
        // olivia.performance.solo.scene-from-childhood-op-15-no7-dreaming
        "olivia.performance.solo.scene-from-childhood-op-15-no7-dreaming": PerformanceDisplayContext(
            source: "舒曼", album: nil, work: "童年情景 Op.15 No.7「梦幻曲」",
            detail: "舒曼 · 童年情景 Op.15 No.7「梦幻曲」",
            aliases: ["Kinderszenen"],
            confidence: .verified,
            evidence: [
                .init(url: "https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch=Kinderszenen",
                      claim: "Public catalogue/search reference consulted (search-hit list): public catalogue/search entry 「Kinderszenen」 supports 舒曼 — 童年情景 Op.15 No.7「梦幻曲」."),
            ]),
        // olivia.performance.solo.schumann-papillons-op2
        "olivia.performance.solo.schumann-papillons-op2": PerformanceDisplayContext(
            source: "舒曼", album: nil, work: "蝴蝶 Op.2",
            detail: "舒曼 · 蝴蝶 Op.2",
            aliases: ["Papillons"],
            confidence: .verified,
            evidence: [
                .init(url: "https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch=Papillons",
                      claim: "Public catalogue/search reference consulted (search-hit list): public catalogue/search entry 「Papillons」 supports 舒曼 — 蝴蝶 Op.2."),
            ]),
        // olivia.performance.solo.scriabin-etude-in-c-sharp-minor-op19-no2
        "olivia.performance.solo.scriabin-etude-in-c-sharp-minor-op19-no2": PerformanceDisplayContext(
            source: "斯克里亚宾", album: nil, work: "升 c 小调练习曲 Op.19 No.2",
            detail: "斯克里亚宾 · 升 c 小调练习曲 Op.19 No.2（原始编号存疑）",
            aliases: ["Alexander Scriabin"],
            confidence: .verified,
            evidence: [
                .init(url: "https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch=Alexander+Scriabin",
                      claim: "Public catalogue/search reference consulted (search-hit list): public catalogue/search entry 「Alexander Scriabin」 supports 斯克里亚宾 — 升 c 小调练习曲 Op.19 No.2."),
                .init(url: "https://urresearch.rochester.edu/institutionalPublicationPublicView.action?institutionalItemVersionId=15122",
                      claim: "Public catalogue reference (controller-verified): Scriabin Op.19 is the Sonata-Fantasy No.2 in G-sharp minor, conflicting with the local title's Op.19 No.2 C-sharp-minor Etude. The local title is kept unchanged and the conflict is recorded as uncertainty."),
            ]),
        // olivia.performance.solo.simurghs-dream
        "olivia.performance.solo.simurghs-dream": PerformanceDisplayContext(
            source: "原神", album: nil, work: nil,
            detail: "原神 · 游戏原声",
            aliases: ["Simurgh's Dream"],
            confidence: .verified,
            evidence: [
                .init(url: "https://genshin-impact.fandom.com/api.php?action=query&list=search&srsearch=Simurgh%27s+Dream",
                      claim: "Genshin Impact Fandom（社区维护，非官方） search-hit list only (no fetched page text): 「Simurgh's Dream」. It corroborates this track's association with Genshin Impact."),
            ]),
        // olivia.performance.solo.sink-into-oblivion
        "olivia.performance.solo.sink-into-oblivion": PerformanceDisplayContext(
            source: "原神", album: nil, work: nil,
            detail: "原神 · 游戏原声",
            aliases: ["Sink Into Oblivion"],
            confidence: .verified,
            evidence: [
                .init(url: "https://genshin-impact.fandom.com/api.php?action=query&list=search&srsearch=Sink+Into+Oblivion",
                      claim: "Genshin Impact Fandom（社区维护，非官方） search-hit list only (no fetched page text): 「Sink Into Oblivion」. It corroborates this track's association with Genshin Impact."),
            ]),
        // olivia.performance.solo.sipping-in-the-soft-breeze
        "olivia.performance.solo.sipping-in-the-soft-breeze": PerformanceDisplayContext(
            source: "原神", album: nil, work: nil,
            detail: "原神 · 游戏原声",
            aliases: ["Sipping in the Soft Breeze"],
            confidence: .verified,
            evidence: [
                .init(url: "https://genshin-impact.fandom.com/api.php?action=query&list=search&srsearch=Sipping+in+the+Soft+Breeze",
                      claim: "Genshin Impact Fandom（社区维护，非官方） search-hit list only (no fetched page text): 「Sipping in the Soft Breeze」. It corroborates this track's association with Genshin Impact."),
            ]),
        // olivia.performance.solo.slight-distress
        "olivia.performance.solo.slight-distress": PerformanceDisplayContext(
            source: "原神", album: nil, work: nil,
            detail: "原神 · 游戏原声",
            aliases: ["Slight Distress"],
            confidence: .verified,
            evidence: [
                .init(url: "https://genshin-impact.fandom.com/api.php?action=query&list=search&srsearch=Slight+Distress",
                      claim: "Genshin Impact Fandom（社区维护，非官方） search-hit list only (no fetched page text): 「Slight Distress」. It corroborates this track's association with Genshin Impact."),
            ]),
        // olivia.performance.solo.soliloquy-of-the-star
        "olivia.performance.solo.soliloquy-of-the-star": PerformanceDisplayContext(
            source: "原神", album: nil, work: nil,
            detail: "原神 · 游戏原声",
            aliases: ["Soliloquy of the Star"],
            confidence: .verified,
            evidence: [
                .init(url: "https://genshin-impact.fandom.com/api.php?action=query&list=search&srsearch=Soliloquy+of+the+Star",
                      claim: "Genshin Impact Fandom（社区维护，非官方） search-hit list only (no fetched page text): 「Soliloquy of the Star」. It corroborates this track's association with Genshin Impact."),
            ]),
        // olivia.performance.solo.song-without-words-op67-no2
        "olivia.performance.solo.song-without-words-op67-no2": PerformanceDisplayContext(
            source: "门德尔松", album: nil, work: "无词歌 Op.67 No.2",
            detail: "门德尔松 · 无词歌 Op.67 No.2",
            aliases: ["List of compositions by Felix Mendelssohn"],
            confidence: .verified,
            evidence: [
                .init(url: "https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch=List+of+compositions+by+Felix+Mendelssohn",
                      claim: "Public catalogue/search reference consulted (search-hit list): public catalogue/search entry 「List of compositions by Felix Mendelssohn」 supports 门德尔松 — 无词歌 Op.67 No.2."),
            ]),
        // olivia.performance.solo.spacewalk
        "olivia.performance.solo.spacewalk": PerformanceDisplayContext(
            source: "崩坏：星穹铁道", album: "Out of Control", work: nil,
            detail: "崩坏：星穹铁道 · 游戏原声 · Out of Control",
            aliases: ["Space Walk"],
            confidence: .verified,
            evidence: [
                .init(url: "https://honkai-star-rail.fandom.com/api.php?action=query&list=search&srsearch=Space+Walk",
                      claim: "Public wiki page text was fetched during the bounded research pass; the claim quotes only the identifying fact, no long copied text. 「Space Walk」 is a soundtrack from the album 'Out of Control' (track 02)."),
            ]),
        // olivia.performance.solo.stroll-along-the-beach
        "olivia.performance.solo.stroll-along-the-beach": PerformanceDisplayContext(
            source: "原神", album: nil, work: nil,
            detail: "原神 · 游戏原声",
            aliases: ["Stroll Along the Beach"],
            confidence: .verified,
            evidence: [
                .init(url: "https://genshin-impact.fandom.com/api.php?action=query&list=search&srsearch=Stroll+Along+the+Beach",
                      claim: "Genshin Impact Fandom（社区维护，非官方） search-hit list only (no fetched page text): 「Stroll Along the Beach」. It corroborates this track's association with Genshin Impact."),
            ]),
        // olivia.performance.solo.tagelied-nachtlicher-gedanken
        "olivia.performance.solo.tagelied-nachtlicher-gedanken": PerformanceDisplayContext(
            source: "原神", album: nil, work: nil,
            detail: "原神 · 游戏原声",
            aliases: ["Tagelied nächtlicher Gedanken"],
            confidence: .verified,
            evidence: [
                .init(url: "https://genshin-impact.fandom.com/api.php?action=query&list=search&srsearch=Tagelied+n%C3%A4chtlicher+Gedanken",
                      claim: "Genshin Impact Fandom（社区维护，非官方） search-hit list only (no fetched page text): 「Tagelied nächtlicher Gedanken」. It corroborates this track's association with Genshin Impact."),
            ]),
        // olivia.performance.solo.tender-strength
        "olivia.performance.solo.tender-strength": PerformanceDisplayContext(
            source: "原神", album: nil, work: nil,
            detail: "原神 · 游戏原声",
            aliases: ["Tender Strength"],
            confidence: .verified,
            evidence: [
                .init(url: "https://genshin-impact.fandom.com/api.php?action=query&list=search&srsearch=Tender+Strength",
                      claim: "Genshin Impact Fandom（社区维护，非官方） search-hit list only (no fetched page text): 「Tender Strength」. It corroborates this track's association with Genshin Impact."),
            ]),
        // olivia.performance.solo.the-fading-stories
        "olivia.performance.solo.the-fading-stories": PerformanceDisplayContext(
            source: "原神", album: nil, work: nil,
            detail: "原神 · 游戏原声",
            aliases: ["The Fading Stories"],
            confidence: .verified,
            evidence: [
                .init(url: "https://genshin-impact.fandom.com/api.php?action=query&list=search&srsearch=The+Fading+Stories",
                      claim: "Genshin Impact Fandom（社区维护，非官方） search-hit list only (no fetched page text): 「The Fading Stories」. It corroborates this track's association with Genshin Impact."),
            ]),
        // olivia.performance.solo.the-little-bell-no3
        "olivia.performance.solo.the-little-bell-no3": PerformanceDisplayContext(
            source: "李斯特", album: nil, work: "小铃铛 第 3 首",
            detail: "李斯特 · 小铃铛 第 3 首",
            aliases: ["La campanella"],
            confidence: .verified,
            evidence: [
                .init(url: "https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch=La+campanella",
                      claim: "Public catalogue/search reference consulted (search-hit list): public catalogue/search entry 「La campanella」 supports 李斯特 — 小铃铛 第 3 首."),
            ]),
        // olivia.performance.solo.the-seasons-op-37a-x-october-autumn-song
        "olivia.performance.solo.the-seasons-op-37a-x-october-autumn-song": PerformanceDisplayContext(
            source: "柴可夫斯基", album: nil, work: "四季 Op.37a 之十月「秋之歌」",
            detail: "柴可夫斯基 · 四季 Op.37a 之十月「秋之歌」",
            aliases: ["The Seasons (Tchaikovsky)"],
            confidence: .verified,
            evidence: [
                .init(url: "https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch=The+Seasons+%28Tchaikovsky%29",
                      claim: "Public catalogue/search reference consulted (search-hit list): public catalogue/search entry 「The Seasons (Tchaikovsky)」 supports 柴可夫斯基 — 四季 Op.37a 之十月「秋之歌」."),
            ]),
        // olivia.performance.solo.the-shimmering-voyage
        "olivia.performance.solo.the-shimmering-voyage": PerformanceDisplayContext(
            source: "原神", album: "珍珠之歌 The Shimmering Voyage", work: nil,
            detail: "原神 · 游戏原声 · 珍珠之歌 The Shimmering Voyage",
            aliases: ["The Shimmering Voyage"],
            confidence: .verified,
            evidence: [
                .init(url: "https://genshin-impact.fandom.com/api.php?action=query&list=search&srsearch=The+Shimmering+Voyage",
                      claim: "Genshin Impact Fandom（社区维护，非官方） search-hit list only (no fetched page text): 「The Shimmering Voyage」. It corroborates this track's association with Genshin Impact."),
            ]),
        // olivia.performance.solo.the-swan
        "olivia.performance.solo.the-swan": PerformanceDisplayContext(
            source: "圣-桑", album: nil, work: "天鹅",
            detail: "圣-桑 · 天鹅",
            aliases: ["The Carnival of the Animals"],
            confidence: .verified,
            evidence: [
                .init(url: "https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch=The+Carnival+of+the+Animals",
                      claim: "Public catalogue/search reference consulted (search-hit list): public catalogue/search entry 「The Carnival of the Animals」 supports 圣-桑 — 天鹅."),
            ]),
        // olivia.performance.solo.the-wind-catcher-from-a-foreign-land
        "olivia.performance.solo.the-wind-catcher-from-a-foreign-land": PerformanceDisplayContext(
            source: "原神", album: nil, work: nil,
            detail: "原神 · 游戏原声",
            aliases: ["The Outlander Who Caught the Wind"],
            confidence: .verified,
            evidence: [
                .init(url: "https://genshin-impact.fandom.com/api.php?action=query&list=search&srsearch=The+Outlander+Who+Caught+the+Wind",
                      claim: "Genshin Impact Fandom（社区维护，非官方） search-hit list only (no fetched page text): 「The Outlander Who Caught the Wind」. It corroborates this track's association with Genshin Impact."),
            ]),
        // olivia.performance.solo.traum-durch-die-dammerung-erster-satz
        "olivia.performance.solo.traum-durch-die-dammerung-erster-satz": PerformanceDisplayContext(
            source: "原神", album: nil, work: nil,
            detail: "原神 · 游戏原声",
            aliases: ["Traum durch die Dämmerung, erster Satz"],
            confidence: .verified,
            evidence: [
                .init(url: "https://genshin-impact.fandom.com/api.php?action=query&list=search&srsearch=Traum+durch+die+D%C3%A4mmerung%2C+erster+Satz",
                      claim: "Genshin Impact Fandom（社区维护，非官方） search-hit list only (no fetched page text): 「Traum durch die Dämmerung, erster Satz」. It corroborates this track's association with Genshin Impact."),
            ]),
        // olivia.performance.solo.turkish-march
        "olivia.performance.solo.turkish-march": PerformanceDisplayContext(
            source: "莫扎特", album: nil, work: "土耳其进行曲",
            detail: "莫扎特 · 土耳其进行曲",
            aliases: ["Piano Sonata No. 11 (Mozart)"],
            confidence: .verified,
            evidence: [
                .init(url: "https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch=Piano+Sonata+No.+11+%28Mozart%29",
                      claim: "Public catalogue/search reference consulted (search-hit list): public catalogue/search entry 「Piano Sonata No. 11 (Mozart)」 supports 莫扎特 — 土耳其进行曲."),
            ]),
        // olivia.performance.solo.vespers-of-pluviose
        "olivia.performance.solo.vespers-of-pluviose": PerformanceDisplayContext(
            source: "原神", album: nil, work: nil,
            detail: "原神 · 游戏原声",
            aliases: ["Vespers of Pluviose"],
            confidence: .verified,
            evidence: [
                .init(url: "https://genshin-impact.fandom.com/api.php?action=query&list=search&srsearch=Vespers+of+Pluviose",
                      claim: "Genshin Impact Fandom（社区维护，非官方） search-hit list only (no fetched page text): 「Vespers of Pluviose」. It corroborates this track's association with Genshin Impact."),
            ]),
        // olivia.performance.solo.wedding-of-love
        "olivia.performance.solo.wedding-of-love": PerformanceDisplayContext(
            source: "保罗·塞内维尔", album: nil, work: "梦中的婚礼",
            detail: "保罗·塞内维尔 · Mariage d’amour",
            aliases: ["wedding of love"],
            confidence: .verified,
            evidence: [
                .init(url: "https://www.easysong.com/search/songs/song-copyright-holder-information.aspx?s=78757",
                      claim: "Music licensing work record Wedding of Love credits Paul de Senneville. Prior Mesherskaya search hit is unrelated."),
            ]),
        // olivia.performance.solo.where-did-you-go
        "olivia.performance.solo.where-did-you-go": PerformanceDisplayContext(
            source: "来源未确认", album: nil, work: nil,
            detail: "同名作品较多，具体作品待确认。",
            aliases: ["where did you go"],
            confidence: .unconfirmed,
            evidence: [
                .init(url: "https://genshin-impact.fandom.com/api.php?action=query&list=search&srsearch=Where+Did+You+Go",
                      claim: "Existing search record insufficient to identify music work; exact title also names unrelated songs. Reject game association."),
            ]),
        // olivia.performance.solo.wildfire
        "olivia.performance.solo.wildfire": PerformanceDisplayContext(
            source: "崩坏：星穹铁道", album: nil, work: nil,
            detail: "崩坏：星穹铁道 · Of Snow and Ember",
            aliases: ["wildfire"],
            confidence: .verified,
            evidence: [
                .init(url: "https://music.apple.com/us/song/1685173996",
                      claim: "HOYO-MiX publisher release lists Wildfire on Honkai Star Rail Of Snow and Ember."),
            ]),
        // olivia.performance.vocal.da-capo
        "olivia.performance.vocal.da-capo": PerformanceDisplayContext(
            source: "崩坏3", album: "毕业旅行主题曲", work: nil,
            detail: "崩坏3 · 游戏原声 · 毕业旅行主题曲",
            aliases: ["Da Capo"],
            confidence: .verified,
            evidence: [
                .init(url: "https://honkai-impact.fandom.com/api.php?action=query&list=search&srsearch=Da+Capo",
                      claim: "Honkai Impact 3rd Fandom（社区维护，非官方） search-hit list only (no fetched page text): 「Da Capo」. It corroborates this track's association with Honkai Impact 3rd."),
                .init(url: "https://music.apple.com/us/album/da-capo-honkai-impact-3rd-graduation-trip-animated/1675220939",
                      claim: "Official Apple Music release page (controller-verified): 「Da Capo」 is the Honkai Impact 3rd Graduation Trip animated short theme by HOYO-MiX."),
            ]),
        // olivia.performance.vocal.devastation-and-redemption
        "olivia.performance.vocal.devastation-and-redemption": PerformanceDisplayContext(
            source: "原神", album: nil, work: nil,
            detail: "原神 · 游戏原声",
            aliases: ["Devastation and Redemption"],
            confidence: .verified,
            evidence: [
                .init(url: "https://genshin-impact.fandom.com/api.php?action=query&list=search&srsearch=Devastation+and+Redemption",
                      claim: "Genshin Impact Fandom（社区维护，非官方） search-hit list only (no fetched page text): 「Devastation and Redemption」. It corroborates this track's association with 原神."),
            ]),
        // olivia.performance.vocal.emberfire
        "olivia.performance.vocal.emberfire": PerformanceDisplayContext(
            source: "原神", album: nil, work: nil,
            detail: "原神 · 游戏原声",
            aliases: ["Emberfire"],
            confidence: .verified,
            evidence: [
                .init(url: "https://genshin-impact.fandom.com/api.php?action=query&list=search&srsearch=Emberfire",
                      claim: "Genshin Impact Fandom（社区维护，非官方） search-hit list only (no fetched page text): 「Emberfire」. It corroborates this track's association with 原神."),
            ]),
        // olivia.performance.vocal.fen-shua-jiang
        "olivia.performance.vocal.fen-shua-jiang": PerformanceDisplayContext(
            source: "来源未确认", album: nil, work: nil,
            detail: "收录来源未确认",
            aliases: ["粉刷匠"],
            confidence: .unconfirmed,
            evidence: [
                .init(url: "https://zh.wikipedia.org/w/api.php?action=query&list=search&srsearch=%E7%B2%89%E5%88%B7%E5%8C%A0",
                      claim: "Public catalogue/search reference consulted (search-hit list): 「粉刷匠」 search-hit list only; it shows the melody/title exists elsewhere but does not establish this bundled track's origin."),
            ]),
        // olivia.performance.vocal.her-wishes
        "olivia.performance.vocal.her-wishes": PerformanceDisplayContext(
            source: "原神", album: nil, work: nil,
            detail: "原神 · 游戏原声",
            aliases: ["Her Wishes"],
            confidence: .verified,
            evidence: [
                .init(url: "https://genshin-impact.fandom.com/api.php?action=query&list=search&srsearch=Her+Wishes",
                      claim: "Genshin Impact Fandom（社区维护，非官方） search-hit list only (no fetched page text): 「Her Wishes」. It corroborates this track's association with 原神."),
            ]),
        // olivia.performance.vocal.if-i-can-stop-one-heart-from-breaking
        "olivia.performance.vocal.if-i-can-stop-one-heart-from-breaking": PerformanceDisplayContext(
            source: "崩坏：星穹铁道", album: nil, work: nil,
            detail: "崩坏：星穹铁道 · 游戏原声",
            aliases: ["If I Can Stop One Heart From Breaking"],
            confidence: .verified,
            evidence: [
                .init(url: "https://honkai-star-rail.fandom.com/api.php?action=query&list=search&srsearch=If+I+Can+Stop+One+Heart+From+Breaking",
                      claim: "Honkai: Star Rail Fandom（社区维护，非官方） search-hit list only (no fetched page text): 「If I Can Stop One Heart From Breaking」. It corroborates this track's association with 崩坏：星穹铁道."),
            ]),
        // olivia.performance.vocal.liang-zhi-lao-hu
        "olivia.performance.vocal.liang-zhi-lao-hu": PerformanceDisplayContext(
            source: "儿歌", album: nil, work: "两只老虎",
            detail: "儿歌 · 两只老虎",
            aliases: ["兩隻老虎"],
            confidence: .verified,
            evidence: [
                .init(url: "https://zh.wikipedia.org/w/api.php?action=query&list=search&srsearch=%E5%85%A9%E9%9A%BB%E8%80%81%E8%99%8E",
                      claim: "Public catalogue/search reference consulted (search-hit list): public search entry 「兩隻老虎」 maps to the traditional melody named in the claim."),
            ]),
        // olivia.performance.vocal.lucens-ut-risus
        "olivia.performance.vocal.lucens-ut-risus": PerformanceDisplayContext(
            source: "原神", album: nil, work: nil,
            detail: "原神 · 游戏原声",
            aliases: ["Lucens ut risus"],
            confidence: .verified,
            evidence: [
                .init(url: "https://genshin-impact.fandom.com/api.php?action=query&list=search&srsearch=Lucens+ut+risus",
                      claim: "Genshin Impact Fandom（社区维护，非官方） search-hit list only (no fetched page text): 「Lucens ut risus」. It corroborates this track's association with 原神."),
            ]),
        // olivia.performance.vocal.melody-of-brave-seeds
        "olivia.performance.vocal.melody-of-brave-seeds": PerformanceDisplayContext(
            source: "原神", album: nil, work: nil,
            detail: "原神 · 游戏原声",
            aliases: ["Melody of Brave Seeds"],
            confidence: .verified,
            evidence: [
                .init(url: "https://genshin-impact.fandom.com/api.php?action=query&list=search&srsearch=Melody+of+Brave+Seeds",
                      claim: "Genshin Impact Fandom（社区维护，非官方） search-hit list only (no fetched page text): 「Melody of Brave Seeds」. It corroborates this track's association with 原神."),
            ]),
        // olivia.performance.vocal.mo-li-hua
        "olivia.performance.vocal.mo-li-hua": PerformanceDisplayContext(
            source: "中国民歌", album: nil, work: "茉莉花",
            detail: "中国民歌 · 茉莉花",
            aliases: ["茉莉花"],
            confidence: .verified,
            evidence: [
                .init(url: "https://zh.wikipedia.org/w/api.php?action=query&list=search&srsearch=%E8%8C%89%E8%8E%89%E8%8A%B1",
                      claim: "Public catalogue/search reference consulted (search-hit list): public search entry 「茉莉花」 maps to the traditional melody named in the claim."),
            ]),
        // olivia.performance.vocal.moon-halo
        "olivia.performance.vocal.moon-halo": PerformanceDisplayContext(
            source: "崩坏3", album: "动画短片《薪炎永燃》印象曲", work: nil,
            detail: "崩坏3 · 游戏原声 · 动画短片《薪炎永燃》印象曲",
            aliases: ["Moon Halo"],
            confidence: .verified,
            evidence: [
                .init(url: "https://honkai-impact.fandom.com/api.php?action=query&list=search&srsearch=Moon+Halo",
                      claim: "Honkai Impact 3rd Fandom（社区维护，非官方） search-hit list only (no fetched page text): 「Moon Halo」. It corroborates this track's association with Honkai Impact 3rd."),
            ]),
        // olivia.performance.vocal.natlan
        "olivia.performance.vocal.natlan": PerformanceDisplayContext(
            source: "原神", album: nil, work: nil,
            detail: "原神 · 游戏原声",
            aliases: ["Natlan"],
            confidence: .verified,
            evidence: [
                .init(url: "https://genshin-impact.fandom.com/api.php?action=query&list=search&srsearch=Natlan",
                      claim: "Genshin Impact Fandom（社区维护，非官方） search-hit list only (no fetched page text): 「Natlan」. It corroborates this track's association with 原神."),
            ]),
        // olivia.performance.vocal.nod-krai
        "olivia.performance.vocal.nod-krai": PerformanceDisplayContext(
            source: "原神", album: nil, work: nil,
            detail: "原神 · 游戏原声",
            aliases: ["Nod-Krai"],
            confidence: .verified,
            evidence: [
                .init(url: "https://genshin-impact.fandom.com/api.php?action=query&list=search&srsearch=Nod-Krai",
                      claim: "Genshin Impact Fandom（社区维护，非官方） search-hit list only (no fetched page text): 「Nod-Krai」. It corroborates this track's association with 原神."),
            ]),
        // olivia.performance.vocal.petala-ceciderunt
        "olivia.performance.vocal.petala-ceciderunt": PerformanceDisplayContext(
            source: "原神", album: nil, work: nil,
            detail: "原神 · 游戏原声",
            aliases: ["Petala ceciderunt"],
            confidence: .verified,
            evidence: [
                .init(url: "https://genshin-impact.fandom.com/api.php?action=query&list=search&srsearch=Petala+ceciderunt",
                      claim: "Genshin Impact Fandom（社区维护，非官方） search-hit list only (no fetched page text): 「Petala ceciderunt」. It corroborates this track's association with 原神."),
            ]),
        // olivia.performance.vocal.qing-lian
        "olivia.performance.vocal.qing-lian": PerformanceDisplayContext(
            source: "来源未确认", album: nil, work: nil,
            detail: "曲名待确认",
            aliases: ["青莲"],
            confidence: .unconfirmed,
            evidence: [
                .init(url: "https://zh.wikipedia.org/w/api.php?action=query&list=search&srsearch=%E9%9D%92%E8%8E%B2",
                      claim: "Public catalogue/search reference consulted (search-hit list): 「青莲」 search-hit list only; it shows the melody/title exists elsewhere but does not establish this bundled track's origin."),
            ]),
        // olivia.performance.vocal.rubia
        "olivia.performance.vocal.rubia": PerformanceDisplayContext(
            source: "崩坏3", album: nil, work: nil,
            detail: "崩坏3 · Rubia",
            aliases: ["rubia"],
            confidence: .verified,
            evidence: [
                .init(url: "https://music.apple.com/us/album/rubia-honkai-impact-3rd-impressions-single/1666688993",
                      claim: "Publisher single identifies Honkai Impact3. Remove unsupported Apocalypse subtitle."),
            ]),
        // olivia.performance.vocal.ruu-melody
        "olivia.performance.vocal.ruu-melody": PerformanceDisplayContext(
            source: "原神", album: nil, work: nil,
            detail: "原神 · 游戏原声",
            aliases: ["Ruu's Melody"],
            confidence: .verified,
            evidence: [
                .init(url: "https://genshin-impact.fandom.com/api.php?action=query&list=search&srsearch=Ruu%27s+Melody",
                      claim: "Genshin Impact Fandom（社区维护，非官方） search-hit list only (no fetched page text): 「Ruu's Melody」. It corroborates this track's association with 原神."),
            ]),
        // olivia.performance.vocal.sheng-ri-kuai-le-ge
        "olivia.performance.vocal.sheng-ri-kuai-le-ge": PerformanceDisplayContext(
            source: "来源未确认", album: nil, work: nil,
            detail: "收录来源未确认",
            aliases: ["生日快乐歌"],
            confidence: .unconfirmed,
            evidence: [
                .init(url: "https://zh.wikipedia.org/w/api.php?action=query&list=search&srsearch=%E7%94%9F%E6%97%A5%E5%BF%AB%E4%B9%90%E6%AD%8C",
                      claim: "Public catalogue/search reference consulted (search-hit list): 「生日快乐歌」 search-hit list only; it shows the melody/title exists elsewhere but does not establish this bundled track's origin."),
            ]),
        // olivia.performance.vocal.somnias-a-luna
        "olivia.performance.vocal.somnias-a-luna": PerformanceDisplayContext(
            source: "原神", album: nil, work: nil,
            detail: "原神 · 游戏原声",
            aliases: ["Somnias a Luna"],
            confidence: .verified,
            evidence: [
                .init(url: "https://genshin-impact.fandom.com/api.php?action=query&list=search&srsearch=Somnias+a+Luna",
                      claim: "Genshin Impact Fandom（社区维护，非官方） search-hit list only (no fetched page text): 「Somnias a Luna」. It corroborates this track's association with 原神."),
            ]),
        // olivia.performance.vocal.song-bie
        "olivia.performance.vocal.song-bie": PerformanceDisplayContext(
            source: "学堂乐歌", album: nil, work: "送别",
            detail: "学堂乐歌 · 送别",
            aliases: ["送别"],
            confidence: .verified,
            evidence: [
                .init(url: "https://zh.wikipedia.org/w/api.php?action=query&list=search&srsearch=%E9%80%81%E5%88%AB",
                      claim: "Public catalogue/search reference consulted (search-hit list): public search entry 「送别」 maps to the traditional melody named in the claim."),
            ]),
        // olivia.performance.vocal.star-odyssey
        "olivia.performance.vocal.star-odyssey": PerformanceDisplayContext(
            source: "原神", album: nil, work: nil,
            detail: "原神 · 丝柯克角色预告曲",
            aliases: ["star odyssey"],
            confidence: .verified,
            evidence: [
                .init(url: "https://www.youtube.com/watch?v=0Lvr-qtJWAQ",
                      claim: "Official HOYO-MiX artist release, provided by miHoYo, names Genshin Impact and Skirk trailer."),
            ]),
        // olivia.performance.vocal.the-long-way-home
        "olivia.performance.vocal.the-long-way-home": PerformanceDisplayContext(
            source: "原神", album: nil, work: nil,
            detail: "原神 · 游戏原声",
            aliases: ["The Long Way Home"],
            confidence: .verified,
            evidence: [
                .init(url: "https://genshin-impact.fandom.com/api.php?action=query&list=search&srsearch=The+Long+Way+Home",
                      claim: "Genshin Impact Fandom（社区维护，非官方） search-hit list only (no fetched page text): 「The Long Way Home」. It corroborates this track's association with 原神."),
            ]),
        // olivia.performance.vocal.the-rime-of-the-ancient-bargeman-iii
        "olivia.performance.vocal.the-rime-of-the-ancient-bargeman-iii": PerformanceDisplayContext(
            source: "原神", album: nil, work: nil,
            detail: "原神 · 游戏原声",
            aliases: ["The Rime of the Ancient Bargeman (III)"],
            confidence: .verified,
            evidence: [
                .init(url: "https://genshin-impact.fandom.com/api.php?action=query&list=search&srsearch=The+Rime+of+the+Ancient+Bargeman+%28III%29",
                      claim: "Genshin Impact Fandom（社区维护，非官方） search-hit list only (no fetched page text): 「The Rime of the Ancient Bargeman (III)」. It corroborates this track's association with 原神."),
            ]),
        // olivia.performance.vocal.the-road-not-taken
        "olivia.performance.vocal.the-road-not-taken": PerformanceDisplayContext(
            source: "原神", album: nil, work: nil,
            detail: "原神 · 动画短片《未行之路》原声",
            aliases: ["the road not taken"],
            confidence: .verified,
            evidence: [
                .init(url: "https://music.apple.com/us/song/1747442244",
                      claim: "Publisher release listing names Genshin Impact animated short The Road Not Taken."),
            ]),
        // olivia.performance.vocal.the-sanctification-of-tao-dou
        "olivia.performance.vocal.the-sanctification-of-tao-dou": PerformanceDisplayContext(
            source: "原神", album: nil, work: nil,
            detail: "原神 · 游戏原声",
            aliases: ["The Sanctification of Tao Dou"],
            confidence: .verified,
            evidence: [
                .init(url: "https://genshin-impact.fandom.com/api.php?action=query&list=search&srsearch=The+Sanctification+of+Tao+Dou",
                      claim: "Genshin Impact Fandom（社区维护，非官方） search-hit list only (no fetched page text): 「The Sanctification of Tao Dou」. It corroborates this track's association with 原神."),
            ]),
        // olivia.performance.vocal.wai-po-qiao
        "olivia.performance.vocal.wai-po-qiao": PerformanceDisplayContext(
            source: "中国童谣", album: nil, work: "外婆桥",
            detail: "中国童谣 · 外婆桥",
            aliases: ["摇啊摇，摇到外婆桥"],
            confidence: .verified,
            evidence: [
                .init(url: "https://zh.wikipedia.org/w/api.php?action=query&list=search&srsearch=%E6%91%87%E5%95%8A%E6%91%87%EF%BC%8C%E6%91%87%E5%88%B0%E5%A4%96%E5%A9%86%E6%A1%A5",
                      claim: "Public catalogue/search reference consulted (search-hit list): public search entry 「摇啊摇，摇到外婆桥」 maps to the traditional melody named in the claim."),
            ]),
        // olivia.performance.vocal.white-night
        "olivia.performance.vocal.white-night": PerformanceDisplayContext(
            source: "崩坏：星穹铁道", album: nil, work: nil,
            detail: "崩坏：星穹铁道 · 游戏原声",
            aliases: ["WHITE NIGHT"],
            confidence: .verified,
            evidence: [
                .init(url: "https://honkai-star-rail.fandom.com/api.php?action=query&list=search&srsearch=WHITE+NIGHT",
                      claim: "Honkai: Star Rail Fandom（社区维护，非官方） search-hit list only (no fetched page text): 「WHITE NIGHT」. It corroborates this track's association with 崩坏：星穹铁道."),
            ]),
        // olivia.performance.vocal.xiao-tu-zi-guai-guai
        "olivia.performance.vocal.xiao-tu-zi-guai-guai": PerformanceDisplayContext(
            source: "来源未确认", album: nil, work: nil,
            detail: "收录来源未确认",
            aliases: ["小兔子乖乖"],
            confidence: .unconfirmed,
            evidence: [
                .init(url: "https://zh.wikipedia.org/w/api.php?action=query&list=search&srsearch=%E5%B0%8F%E5%85%94%E5%AD%90%E4%B9%96%E4%B9%96",
                      claim: "Public catalogue/search reference consulted (search-hit list): 「小兔子乖乖」 search-hit list only; it shows the melody/title exists elsewhere but does not establish this bundled track's origin."),
            ]),
        // olivia.performance.vocal.yao-lan-qu
        "olivia.performance.vocal.yao-lan-qu": PerformanceDisplayContext(
            source: "来源未确认", album: nil, work: nil,
            detail: "曲名待确认",
            aliases: ["摇篮曲"],
            confidence: .unconfirmed,
            evidence: [
                .init(url: "https://zh.wikipedia.org/w/api.php?action=query&list=search&srsearch=%E6%91%87%E7%AF%AE%E6%9B%B2",
                      claim: "Public catalogue/search reference consulted (search-hit list): 「摇篮曲」 search-hit list only; it shows the melody/title exists elsewhere but does not establish this bundled track's origin."),
            ]),
        // olivia.performance.vocal.you-yi-di-jiu-tian-chang
        "olivia.performance.vocal.you-yi-di-jiu-tian-chang": PerformanceDisplayContext(
            source: "苏格兰民歌", album: nil, work: "友谊地久天长",
            detail: "苏格兰民歌 · 友谊地久天长",
            aliases: ["友誼萬歲"],
            confidence: .verified,
            evidence: [
                .init(url: "https://zh.wikipedia.org/w/api.php?action=query&list=search&srsearch=%E5%8F%8B%E8%AA%BC%E8%90%AC%E6%AD%B2",
                      claim: "Public catalogue/search reference consulted (search-hit list): public search entry 「友誼萬歲」 maps to the traditional melody named in the claim."),
            ]),
        // olivia.performance.vocal.zhao-peng-you
        "olivia.performance.vocal.zhao-peng-you": PerformanceDisplayContext(
            source: "来源未确认", album: nil, work: nil,
            detail: "收录来源未确认",
            aliases: ["找朋友"],
            confidence: .unconfirmed,
            evidence: [
                .init(url: "https://zh.wikipedia.org/w/api.php?action=query&list=search&srsearch=%E6%89%BE%E6%9C%8B%E5%8F%8B",
                      claim: "Public catalogue/search reference consulted (search-hit list): 「找朋友」 search-hit list only; it shows the melody/title exists elsewhere but does not establish this bundled track's origin."),
            ]),
    ]
}
