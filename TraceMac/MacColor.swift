// MacColor.swift
// The colours TraceMac chooses for itself, resolved per appearance.
//
// Session 64. David, shown the sidebar in both appearances: *"lets go with C"*
// — one value per appearance, only the failing side moves.
//
// ── The audit that produced this ──────────────────────────────────────────
//
// 91 colour decisions in TraceMac. **68 are `Color(nsColor:)` semantic
// colours** (36 controlBackground, 19 windowBackground, 6 separator, 4
// textBackground) and adapt on their own. There is no `.preferredColorScheme`
// pin, so D7 holds, and there is not one hardcoded white background.
//
// So dark mode was never broken. Three quarters of the colour work had been
// delegated rather than chosen, and delegation is what carried it. **What was
// wrong was exactly the part somebody chose** — six fixed hex literals, five
// of which fail the 3:1 bar for icons and UI components:
//
//     Notes / Home  #F4793A   light 2.33  FAIL   dark 5.21
//     Activity      #16A34A   light 2.79  FAIL   dark 4.35
//     Satchel       #0A84FF   light 3.09         dark 3.93
//     Archive       #92400E   light 6.01         dark 2.02  FAIL
//     Billiards     #2563EB   light 4.38         dark 2.77  FAIL
//
// measured against #ECECEE and #2A2A2C.
//
// **This was never a dark-mode problem.** `traceOrange` — the brand colour —
// sits at 2.33:1 in the appearance David has been using all along. Turning
// dark mode on did not break it. It is what finally made somebody measure.
//
// And the whole finding fits in one `switch`: `SidebarSection.iconColor` has
// seven cases, of which Directory (`.indigo`) and Inbox (`.gray`) use SwiftUI
// system colours and are correct, and the other five are frozen hex. Two rows
// right, five wrong, seven consecutive lines.
//
// ── Why `NSColor(name:dynamicProvider:)` and not `@Environment` ───────────
//
// The obvious SwiftUI answer is `@Environment(\.colorScheme)` and a ternary at
// each call site. Rejected:
//
//   * It is per-call-site, which is the thing this whole session has been
//     removing. A colour you have to remember to fork is `initialsCircle` all
//     over again (D16).
//   * It does not reach AppKit. `MacMarkdownTextStorage` draws the editor's
//     horizontal rule with a raw `NSColor` and has no SwiftUI environment to
//     read.
//   * It reads the *view's* scheme, not the window's appearance, so it is
//     wrong under a per-window appearance override.
//
// A dynamic `NSColor` resolves at draw time, works identically from SwiftUI
// and AppKit, and needs no plumbing at any call site. `Color(nsColor:)` keeps
// the dynamism — it does not snapshot.
//
// ── Values ────────────────────────────────────────────────────────────────
//
// Only the failing side moved; the passing side is untouched. Satchel blue
// passes both and does not move at all. Each retuned value keeps its hue and
// changes lightness only, landing at ~3.3:1 rather than exactly 3.0 so that
// rounding and a slightly different background do not push it under.
//
// **Left for David, not decided here:** `traceOrange` is *two* colours.
// `TraceSkin.swift` on iOS says #FF9500 (light 1.86:1, worse than the Mac's).
// Same token name, two apps. This file fixes the Mac; iOS still has it.

import SwiftUI
import AppKit

// MARK: - Hex for AppKit

extension NSColor {
    /// The dynamic provider below needs an AppKit hex initialiser.
    ///
    /// The SwiftUI twin, `Color(hex:)`, was **deleted** from
    /// TraceMacColors.swift in the same pass: it had six callers, five of
    /// which failed a contrast check, and leaving it available is how the
    /// seventh literal gets written. Hex now only reaches a colour through
    /// `macDynamic(light:dark:)`, which cannot be called without answering
    /// the question the audit asked — what does it look like in the other
    /// appearance?
    convenience init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                  green:   CGFloat((v >> 8)  & 0xFF) / 255,
                  blue:    CGFloat( v        & 0xFF) / 255,
                  alpha:   1)
    }
}

// MARK: - Appearance-resolving colour

extension NSColor {
    /// Resolves at draw time, so one instance is correct in both appearances
    /// and in a window whose appearance has been overridden.
    static func macDynamic(light: String, dark: String) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        }
    }
}

extension Color {
    /// SwiftUI wrapper. `Color(nsColor:)` preserves the dynamic provider
    /// rather than snapshotting the current appearance.
    static func macDynamic(light: String, dark: String) -> Color {
        Color(nsColor: .macDynamic(light: light, dark: dark))
    }
}

// MARK: - The palette
//
// Every value below is a colour TraceMac picks for itself. Anything that can
// be a `Color(nsColor: .someSemanticColor)` should be that instead and is not
// here — that is the 68 sites this audit found already doing the right thing.

enum MacPalette {

    /// Brand. Notes and Home in the sidebar.
    /// Was a flat #F4793A, which is 2.33:1 in light.
    static let orange = Color.macDynamic(light: "CA6430", dark: "F4793A")

    /// Activity. Was a flat #16A34A, 2.79:1 in light.
    static let green = Color.macDynamic(light: "149443", dark: "16A34A")

    /// Satchel. Passes both today, so it does not move. Kept as a token so it
    /// is not the one colour still spelled as a literal.
    static let blue = Color.macDynamic(light: "0A84FF", dark: "0A84FF")

    /// Archive. Was a flat #92400E, 2.02:1 in dark — the worst of the six.
    static let brown = Color.macDynamic(light: "92400E", dark: "C85813")

    /// The Billiards rack icon. Was a flat #2563EB, 2.77:1 in dark.
    static let rackBlue = Color.macDynamic(light: "2563EB", dark: "3A73EF")

    /// Satchel's eight document tints, for the Mac.
    ///
    /// **Deliberately the system colours rather than a third copy of the hex
    /// values.** Two copies already exist — `SatchelSkin.swift`'s extension on
    /// `DocumentTint`, and a second set of statics inside
    /// `SatchelDocumentChips`, whose own comment says neither is the source of
    /// truth (`satchel-mockup-v2.html` is) and explains why it could not reuse
    /// the first. Neither is reachable from this target: Satchel's is in the
    /// Satchel target, and the chips file is UIKit-flavoured. A third
    /// hand-copied palette would be the third thing that has to be kept in step
    /// with a mockup nobody opens.
    ///
    /// Reading the phone's values back confirms they are the system palette
    /// already, darkened for contrast on white: `blue` is exactly #0A84FF,
    /// `indigo` exactly #5856D6, `gray` a system grey. So the system colours
    /// are not an approximation of a bespoke palette, they are what it was
    /// derived from — and they carry a dark-mode variant, which the phone's
    /// fixed literals do not and which TraceMac needs because it does not pin
    /// `.light` (D7).
    ///
    /// The cost, stated rather than hidden: side by side, a Mac tile is a
    /// shade brighter than the same document's tile on the phone. Worth
    /// revisiting in the skin pass, where the whole colour question is open
    /// anyway, rather than by pasting eight more literals here.
    static func documentTint(_ tint: DocumentTint) -> Color {
        switch tint {
        case .teal:   return .teal
        case .blue:   return .blue
        case .green:  return .green
        case .rose:   return .pink
        case .indigo: return .indigo
        case .amber:  return .orange
        case .red:    return .red
        case .gray:   return .gray
        }
    }
}
