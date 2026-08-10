// MacIconBadge.swift
// The coloured shape with a category glyph in it.
//
// Session 64. David, shown soft / solid / hybrid on his own visit list:
// *"ok lets go witih C and round"* — soft in rows, solid in headers, circles.
//
// ── The finding this replaced ─────────────────────────────────────────────
//
// Seven of these existed, and the glyph sizes looked like the worst drift left
// in the app: 12, 12, 13, 13, 14, 15, 15. **They were not drifting.** Every
// one sits inside a shape of a stated diameter, and the glyph tracks it:
//
//     Places   compact row     Circle  15%   28 → 12    0.43
//     Content  home row        Circle  solid 28 → 12    0.43
//     Discover list row        Circle  18%   30 → 13    0.43
//     People   place row       Rect 7  solid 30 → 13    0.43
//     Fitness  workout row     Rect 8  15%   34 → 15    0.44
//     Places   visit row       Circle  15%   36 → 14    0.39
//     Discover info card       Circle  solid 36 → 15    0.42
//
// Six of seven land on 0.42–0.44. One rule, correctly applied, written out
// seven times as a pair of magic numbers. **Standardising the glyph sizes,
// which is what the numbers invited, would have broken a ratio that was
// right.** What actually drifted was underneath: four diameters, three fills,
// three shapes, two glyph colours.
//
// The lesson generalised in D18: a set of numbers that varies is not
// automatically drift. Check what it is a function of before naming it a
// problem.
//
// ── What David decided, and why the rule is structural ────────────────────
//
// Fill was genuinely open — solid and soft each appeared at 36pt, at 28–30,
// and inside list rows, so it tracked neither size nor position nor file.
// Option C: **soft in rows, solid in headers.** A badge earns weight where it
// is the subject; in a list of forty visits it is one of forty, and forty
// saturated dots pull harder than the place names, which are what you read.
//
// So there is deliberately **no `emphasis` parameter**. Fill is a property of
// the rung, not a choice at the call site. Offering both and documenting the
// rule is exactly how the app arrived at two treatments in the first place —
// see D16, where `TraceMacPeopleView` had already written `initialsCircle`
// and four sites ignored it because it took a free number.
//
// ── Shape ─────────────────────────────────────────────────────────────────
//
// Circles everywhere, per David. The rejected alternative was round-for-people
// and rounded-square-for-things, which would have let the shape say what kind
// of row you are looking at for free. Recorded because it is a real option and
// a future session should not have to rediscover it: it is one `clipShape`.
//
// Rounded rectangles at radius 7 (People) and 8 (Fitness) both become circles.

import SwiftUI

struct MacIconBadge: View {

    enum Size {
        /// A compact list row. Absorbs the old 28 and 30.
        case compact
        /// A standard list row with two lines of text. Absorbs the old 34 and 36.
        case standard
        /// A detail header, where the badge is the subject rather than one of
        /// forty. The only rung that fills solid.
        case header

        var diameter: CGFloat {
            switch self {
            case .compact:  28
            case .standard: 36
            case .header:   36
            }
        }

        /// 0.43 of the diameter, which is what six of the seven old sites had
        /// independently arrived at.
        var glyph: CGFloat {
            switch self {
            case .compact:  12
            case .standard: 15
            case .header:   15
            }
        }

        /// Soft in rows, solid in headers. Not a parameter.
        var isSolid: Bool { self == .header }
    }

    let icon: String
    let tint: Color
    var size: Size = .compact

    /// 15%, which is `MacAvatar`'s value and the majority of the old sites.
    /// Discover's 18% folds in; nobody could tell them apart side by side.
    private static let softFill: Double = 0.15

    var body: some View {
        Circle()
            .fill(size.isSolid ? AnyShapeStyle(tint)
                               : AnyShapeStyle(tint.opacity(Self.softFill)))
            .frame(width: size.diameter, height: size.diameter)
            .overlay(
                Image(systemName: icon)
                    .font(.system(size: size.glyph))
                    .foregroundStyle(size.isSolid ? AnyShapeStyle(.white)
                                                  : AnyShapeStyle(tint))
            )
    }
}
