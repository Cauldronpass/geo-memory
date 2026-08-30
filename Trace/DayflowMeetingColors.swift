import SwiftUI

// MARK: - DayflowMeetingColors
//
// Session 78, D184 — the meeting color system, ported FAITHFULLY from
// David's own vault reference (System/Color-Key-Time-Block-Plan.md and the
// daily-plan-colors.css snippet, tuned over months of daily use in his
// Obsidian time-block plan). The keywords, special rules and precedence are
// HIS, not invented here; when this file and that doc disagree, the doc
// wins and this file has a bug.
//
// Precedence (bank pre-check and Sarah rule run before the loop, per the
// doc's own 2026-05-03 notes; Mint and Orange were absent from the doc's
// written conflict order and slot after Blue and Yellow respectively —
// proposed to David 2026-08-29, accepted with the chip+track placement):
//   banks → Sarah → Red → Purple → Teal → Blue → Mint → Yellow → Orange
//
// Where color lands (David's call, same day): the 8pt row chip on Today and
// Upcoming (replacing the calendar-source color, which meant nothing), and
// THE DAY track's blocks — the latter behind `tintTrackBlocks`, ONE flag,
// because he is "not sold on the tracks": flip it false and the track
// returns to ink while the chips stay.
//
// Two tones per color: `chip` is deepened (the plan's pale washes vanish in
// an 8pt square on paper); `block` is the plan's own pastel, right at the
// track's larger size. No-match renders PLAIN per the doc — a quiet faint
// chip, an ink track block.

enum DayflowMeetingColor {
    case red, purple, teal, blue, mint, yellow, orange
    case none

    /// Deepened, hue-matched to the Obsidian key — for the 8pt row chip.
    var chip: Color? {
        switch self {
        case .red:    return Color(red: 0.94, green: 0.31, blue: 0.43)   // from #FF5582
        case .purple: return Color(red: 0.69, green: 0.50, blue: 0.91)   // from #CA9FF5
        case .teal:   return Color(red: 0.25, green: 0.75, blue: 0.66)   // from #A8E8DC
        case .blue:   return Color(red: 0.43, green: 0.61, blue: 0.91)   // from #ADCCFF
        case .mint:   return Color(red: 0.28, green: 0.75, blue: 0.41)   // from #A8EDB4
        case .yellow: return Color(red: 0.89, green: 0.75, blue: 0.18)   // from #FFF3A3
        case .orange: return Color(red: 0.94, green: 0.60, blue: 0.28)   // from #FFB86C
        case .none:   return nil
        }
    }

    /// The plan's own pastels — for THE DAY track's blocks.
    var block: Color? {
        switch self {
        case .red:    return Color(red: 1.00, green: 0.33, blue: 0.51)
        case .purple: return Color(red: 0.79, green: 0.62, blue: 0.96)
        case .teal:   return Color(red: 0.66, green: 0.91, blue: 0.86)
        case .blue:   return Color(red: 0.68, green: 0.80, blue: 1.00)
        case .mint:   return Color(red: 0.66, green: 0.93, blue: 0.71)
        case .yellow: return Color(red: 1.00, green: 0.90, blue: 0.53)   // #FFF3A3 nudged for track contrast
        case .orange: return Color(red: 1.00, green: 0.72, blue: 0.42)
        case .none:   return nil
        }
    }

    /// One flag, per David ("not sold on the tracks... is that easy to
    /// switch back"): false returns the track to ink; the chips stay.
    static let tintTrackBlocks = true

    // MARK: Classification

    // "usbank" (squashed) catches email-shaped organizers like
    // invites@usbank.com; the dotted and Bancorp forms are how invites
    // write the name (David, 2026-08-29). Word-boundary matching keeps the
    // short forms honest.
    private static let banks = ["boa", "hsbc", "citi", "bnp", "bmo", "us bank",
                                "u.s. bank", "u.s. bancorp", "us bancorp",
                                "bancorp", "usbank",
                                "associated bank", "jpmorgan", "wells fargo", "chase"]
    private static let social = ["catch up", "catch-up", "1:1", "1 on 1", "check-in",
                                 "check in", "touch base", "lunch", "dinner", "happy hour"]
    private static let redKeywords = ["mplt", "board", "f&a", "flt", "martin denman", "martin",
                              "stephen parker", "affan", "abby", "suketu", "suketu gandhi",
                              "per hong", "ramez", "ramez shehadi", "bharat", "kt",
                              "business review", "state of the region",
                              "state of the practice", "state of practice", "blood"]
    private static let purpleKeywords = ["gbu", "practice", "apac", "amer", "mea", "emea",
                                 "d&a", "activate", "optano", "connected planning",
                                 "customer platforms", "core enterprise", "product software",
                                 "sgot", "ignite", "sustainability", "ev8",
                                 "transformation studio", "prokura", "kos", "perl",
                                 "foresight", "innovation & ventures", "silicon foundry",
                                 "sif", "hoptek"]
    private static let tealKeywords = ["performance review", "annual review", "interview",
                               "hiring", "onboarding", "recruiting", "hr", "candidate"]
    private static let blueKeywords = ["forecast", "3+9", "6+6", "9+3", "12+0"]
    private static let mintKeywords = ["treasury", "finance leadership", "cash", "banking"]
    private static let yellowKeywords = ["catch up", "catch-up", "1:1", "1 on 1"]
    private static let orangeKeywords = ["commute", "drive", "uber", "flight", "airport",
                                 "train", "transit"]

    // PERFORMANCE (2026-08-29 night — David: "the slow aspect of this app
    // now is the worst part"). classify() compiled up to ~85
    // NSRegularExpressions PER TITLE PER RENDER; Today and Upcoming call it
    // for every row and every track block, and a tab switch re-evaluates
    // both, so every switch paid thousands of regex compiles. Two layers
    // now: each keyword's regex compiles exactly once for the app's life
    // (patternCache), and each title's verdict is memoized (verdictCache).
    // Both are touched only from SwiftUI body evaluation — main thread —
    // hence nonisolated(unsafe) with no lock. verdictCache is capped
    // defensively; a personal calendar holds hundreds of distinct titles,
    // not tens of thousands.
    nonisolated(unsafe) private static var patternCache: [String: NSRegularExpression] = [:]
    nonisolated(unsafe) private static var verdictCache: [String: DayflowMeetingColor] = [:]

    static func classify(_ title: String, organizer: String? = nil) -> DayflowMeetingColor {
        let key = organizer.map { title + "\u{1F}" + $0 } ?? title
        if let cached = verdictCache[key] { return cached }
        let verdict = classifyUncached(title, organizer: organizer)
        if verdictCache.count > 2000 { verdictCache.removeAll(keepingCapacity: true) }
        verdictCache[key] = verdict
        return verdict
    }

    private static func classifyUncached(_ title: String, organizer: String?) -> DayflowMeetingColor {
        // Bank ORGANIZER rule (2026-08-29, David: "Brewers vs Cubs is a bank
        // sponsored event since US Bank is the invitor... should be mint").
        // The invitor is the signal a title keyword can't carry — a title
        // rule would tint his personal Brewers games too. Written into the
        // vault color key the same day.
        if let organizer, matches(organizer, banks) { return .mint }
        // Bank pre-check (doc, 2026-05-03): an institution name always wins —
        // even over yellow's separator patterns.
        if matches(title, banks) { return .mint }

        // Sarah rule (doc, 2026-05-03): non-social Sarah meetings are
        // Treasury work; her catch-ups and 1:1s stay Yellow.
        if matches(title, ["sarah"]),
           !matches(title, social), !isPairPattern(title) {
            return .mint
        }

        if matches(title, redKeywords) { return .red }
        if matches(title, purpleKeywords) { return .purple }
        if matches(title, tealKeywords) { return .teal }
        // "Cash Forecast" is treasury, not forecast — the doc's one Blue
        // exception, kept by letting cash-bearing titles fall past Blue.
        if matches(title, blueKeywords), !matches(title, ["cash"]) { return .blue }
        if matches(title, mintKeywords) { return .mint }
        if matches(title, yellowKeywords) || isPairPattern(title) { return .yellow }
        if matches(title, orangeKeywords) { return .orange }
        return .none
    }

    /// Word-boundary matching, not bare substring: "boa" must not claim
    /// "Board", "kt" must not claim "cocktail", "citi" must not claim
    /// "citizen". Boundaries are "not letter/number on either side", which
    /// also handles "f&a" and "3+9" cleanly.
    private static func matches(_ title: String, _ keywords: [String]) -> Bool {
        keywords.contains { kw in
            let regex: NSRegularExpression
            if let cached = patternCache[kw] {
                regex = cached
            } else {
                guard let built = try? NSRegularExpression(
                    pattern: "(?<![\\p{L}\\p{N}])"
                        + NSRegularExpression.escapedPattern(for: kw)
                        + "(?![\\p{L}\\p{N}])",
                    options: [.caseInsensitive]) else { return false }
                patternCache[kw] = built
                regex = built
            }
            return regex.firstMatch(in: title,
                                    range: NSRange(title.startIndex..., in: title)) != nil
        }
    }

    /// The doc's "Name x Name / Name / Name / Name <> Name" catch-up shapes.
    private static func isPairPattern(_ title: String) -> Bool {
        if title.contains("<>") { return true }
        if title.contains(" / ") { return true }
        return title.range(of: #"\S\s+x\s+\S"#,
                           options: [.regularExpression, .caseInsensitive]) != nil
    }
}
