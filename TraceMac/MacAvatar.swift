// MacAvatar.swift
// The initials circle, which existed five times and once as a helper.
//
// Session 64, third component out of the skin pass.
//
// ── What was there ────────────────────────────────────────────────────────
//
//     TraceMacPlacesView:631     16pt circle,  8pt initials, accent
//     TraceMacContentView:909    28pt circle, 10pt initials, dynamic
//     TraceMacPeopleView:1867    30pt circle, 11pt initials, orange
//     TraceMacArchiveView:230    52pt circle, 18pt initials, purple
//     TraceMacPeopleView:527     `initialsCircle(_:size:)`, initials at size * 0.33, purple
//
// Four diameters, four initials sizes, and **28 against 30 is the whole
// argument**: two person rows, two pixels apart, in two files, for no reason
// anybody could state. Nobody decided that. It is what happens when the same
// small thing is rebuilt from memory a few weeks apart.
//
// The sharpest part is the last line. `TraceMacPeopleView` had **already
// written this component** — `initialsCircle(_:size:)`, with the ratio worked
// out — and the other four sites did not use it, including one in the same
// file 1,300 lines further down. A helper that is not the only way to do the
// thing is a suggestion, and the file it lives in will ignore it.
//
// ── Why named sizes and not a free diameter ───────────────────────────────
//
// `initialsCircle` took any `CGFloat` and derived the initials from it, which
// is why 30 was reachable at all. Four named sizes, one per job, is the thing
// that makes 30 unrepresentable rather than merely discouraged. Same shape as
// `MacType`: the callers who drifted were not being careless, they were being
// offered a number.
//
// Diameters are the ones already in use; the 30 folds into `.row`. Initials
// sizes are `initialsCircle`'s own 0.33 ratio, rounded, except `.inline`,
// where 0.33 of 16 is 5pt and unreadable — 8 is the floor, and that floor is
// the reason `.inline` is a fixed rung and not a formula.

import SwiftUI

struct MacAvatar: View {

    enum Size {
        /// Companion chips in a visit row. Initials only, no room for more.
        case inline
        /// A person row in a list. Absorbs the old 30pt twin.
        case row
        /// An archived-person card, or any header that is not the subject.
        case header
        /// The subject of a detail page.
        case hero

        var diameter: CGFloat {
            switch self {
            case .inline: 16
            case .row:    28
            case .header: 52
            case .hero:   72
            }
        }

        var initials: CGFloat {
            switch self {
            case .inline: 8     // floor, not ratio: 0.33 x 16 is unreadable
            case .row:    10
            case .header: 18
            case .hero:   24
            }
        }
    }

    let name: String
    var size: Size = .row
    var tint: Color = .accentColor

    /// First letters of the first two words, else the first two characters.
    /// Was written out longhand at four of the five old sites, with the
    /// two-word and one-word branches differing subtly between them.
    private var initials: String {
        let parts = name.split(separator: " ")
        if parts.count >= 2 {
            return String(parts[0].prefix(1)) + String(parts[1].prefix(1))
        }
        return String(name.prefix(2)).uppercased()
    }

    var body: some View {
        Circle()
            .fill(tint.opacity(0.15))
            .frame(width: size.diameter, height: size.diameter)
            .overlay(
                Text(initials)
                    .font(.system(size: size.initials, weight: .medium))
                    .foregroundStyle(tint)
            )
            .accessibilityLabel(name)
    }
}
