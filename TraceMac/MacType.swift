// MacType.swift
// TraceMac's type scale. Six roles. A caller picks a role, never a number.
//
// Session 64. David, on the redrawn right rail: *"It reads clearer."*
//
// ── What was actually wrong ───────────────────────────────────────────────
//
// Not "there is no scale". TraceMac had 520 font call sites and **414 of them
// already used a macOS semantic style** (`.caption`, `.body`, `.headline`, and
// the good form `.font(.system(.callout, weight: .medium))`). The scale existed
// and covered 80% of the app. 106 sites had opted out with a hard number.
//
// And the opt-outs were concentrated, not diffuse:
//
//     TraceMacCalendarPanel    0 semantic /  7 numeric   100%
//     TraceMacSectionHeader    0 semantic /  1 numeric   100%
//     TraceMacJournalView     23 semantic / 20 numeric    47%
//     TraceMacContentView     50 semantic / 20 numeric    29%
//     everything else        336 semantic / 58 numeric   under 25%
//
// Which put all of it on the screen the app opens to. The month grid and the
// This Week panel were entirely hand-tuned; the editor eighteen points to
// their left was entirely semantic. Two type systems touching on one screen.
//
// Reachable text sizes were 10, 11, 12, 13, 15, 17, 22 (macOS, real gaps)
// plus 8, 8.5, 9, 9.5, 10.5, 11.5, 14, 18 (nudges). Four of the eight were
// half-points, and a half-point is never a decision, it is somebody squinting.
//
// The two findings that settled it without an argument:
//
//   * `Text("\(dayNum)")`, a calendar day number, was written at **11, 12 and
//     14** in three separate places. All three are `.row` now.
//   * `Text(initials)`, an avatar, at **8, 10 and 18** — the 18 twice, at two
//     different weights, in one file.
//
// ── Why this is an enum of roles and not a list of sizes ──────────────────
//
// A scale nobody is forced through is a suggestion, and a suggestion is what
// produced 8.5. **A role owns a size and a weight together.** There is no
// `MacType.size(12)` and there is deliberately no way to ask for a weight
// that a role does not offer: each has at most a base and one emphasis form,
// because "bold when selected" is the only real reason any of these varied.
//
// Rejected: designing a new scale. The 414 semantic sites were the majority of
// the evidence and did not need moving. Each role below states the macOS style
// it matches, so the two systems are the same system.
//
// Rejected: keeping half-points "because that screen was tuned". Tuned against
// what? Each one was set in isolation on a screen nobody was comparing to the
// one beside it. That is the definition of the problem, not a defence of it.
//
// ── Scope of the first pass ───────────────────────────────────────────────
//
// Text only, and only in `TraceMacCalendarPanel`, `TraceMacSectionHeader` and
// `TraceMacJournalView` — the three files David saw redrawn. Two things are
// deliberately still outstanding:
//
//   1. **Standalone glyphs.** 37 `Image(systemName:)` sites across 9 sizes,
//      including 24 empty-state symbols at 28–52pt that are one component
//      nobody wrote. That needs its own proposal. Glyphs that sit *inside* a
//      text run (a mappin before a place name, the chevrons flanking the month
//      title) take the text role of the run they belong to, which is why some
//      appear below.
//   2. **The remaining ~70 opt-outs** in ContentView, PeopleView, Documents,
//      Discover and the rest. Mechanical once these are proven on device.

import SwiftUI

enum MacType {

    // MARK: Roles

    /// The single subject name on a detail page — a person, a place.
    /// macOS `.title2`. Absorbs the old 22 and 18.
    static let title = Font.system(size: 17, weight: .semibold)

    /// Section headers, group titles, the calendar's month title.
    /// macOS `.headline`. Absorbs the old 13 semibold and 12 semibold.
    static let heading = Font.system(size: 13, weight: .semibold)

    /// Editor text, text fields, prose. macOS `.body`.
    static let body = Font.system(size: 13, weight: .regular)

    /// Every list row's primary line, and every calendar day number.
    /// macOS `.callout`. Absorbs the old 11, 11.5, 12 and 14.
    static let row = Font.system(size: 12, weight: .regular)

    /// `row` for the one item that is today or selected. The only reason a row
    /// ever varied.
    static let rowEmphasis = Font.system(size: 12, weight: .semibold)

    /// Secondary lines, dates, counts, week numbers.
    /// macOS `.caption`. Absorbs the old 9, 9.5, 10 and 10.5.
    static let meta = Font.system(size: 10, weight: .regular)

    /// `meta` carrying a number that has to be found — a visit count, a total.
    static let metaEmphasis = Font.system(size: 10, weight: .semibold)

    /// Small-caps section labels: THIS WEEK, SATURDAY, the M T W T F S S row.
    /// Always paired with `.macLabel()`, which adds the case and the tracking;
    /// the bare font is exposed only for the rare label that must not uppercase.
    static let label = Font.system(size: 10, weight: .bold)

    /// One tracking value for every small-caps label. Was 0.5 in one place and
    /// 0.6 in another, twelve points apart on the same screen.
    static let labelTracking: CGFloat = 0.5
}

extension View {

    /// The complete small-caps label treatment: size, weight, case, tracking.
    /// Applying `MacType.label` without this is how the two tracking values
    /// happened, so the modifier is the supported path and the font is not.
    func macLabel() -> some View {
        self.font(MacType.label)
            .textCase(.uppercase)
            .tracking(MacType.labelTracking)
    }
}

// MARK: - Stars

/// A rating is not text.
///
/// It was `Text(String(repeating: "★", count: rating))` at 8pt — off the scale
/// entirely, and 8 because five glyphs of anything larger did not fit a row
/// that had never been sized for them. Rendering it as a real row of symbols
/// means the size is a property of the component rather than a workaround for
/// a string that grows with its value.
///
/// Capped at 5 deliberately: the week note records up to 6 (Melas park, 19 Jul,
/// is `★★★★★★`), but the row has room for five and a rating that overflows its
/// row silently is worse than one that clamps visibly.
struct MacStars: View {
    let rating: Int
    var body: some View {
        HStack(spacing: 0.5) {
            ForEach(0..<min(rating, 5), id: \.self) { _ in
                Image(systemName: "star.fill")
                    .font(.system(size: 7.5))
            }
        }
        .foregroundStyle(Color.orange.opacity(0.8))
        .accessibilityLabel("\(rating) star\(rating == 1 ? "" : "s")")
    }
}
