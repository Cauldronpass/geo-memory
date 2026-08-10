// MacGlyph.swift
// Two rungs for a glyph that is a control.
//
// Session 64, fourth and last component of the type pass.
//
// ── The distinction this file exists to make ──────────────────────────────
//
// D13 settled that **a glyph inside a text run takes the role of the run** —
// the mappin before a place name is `MacType.meta`, the chevrons flanking the
// month title are `MacType.heading`. That covers glyphs whose size is decided
// by the words next to them.
//
// It does not cover a glyph that *is* a button. A trash icon in a row action,
// a chevron in a sort control, an xmark that clears a search field: none of
// those have text beside them to agree with. **Their size is decided by the
// hit target they sit in**, which is a layout fact, not a typographic one.
// Sizing them off the type scale would be answering the wrong question
// precisely.
//
// ── What was there ────────────────────────────────────────────────────────
//
// Twenty control glyphs at 8, 8.5, 9, 11, 12, 13 and 15. Three examples of
// one job at three sizes:
//
//   * `xmark.circle.fill`, the clear-this-field affordance — 15, 15, 15, 12.
//   * `isSaved ? "star.fill" : "mappin"`, the save toggle in Discover — 11 in
//     the compact row, 13 in the standard row, 15 in the detail header. Three
//     sizes for one button, and the button does the same thing in all three.
//   * `chevron.up.chevron.down`, the sort control — 9, 9, 9. **Already
//     consistent**, in three files, by nobody's instruction. That is the rung.
//
// ── Two rungs, because there are two hit targets ──────────────────────────
//
// The 9s are all glyphs living inside something small and already-bounded: a
// filter chip, a sort control, a dismiss on a token. The 11–15s are all
// glyphs living in a 24–30pt button. There is no third population; 15 was not
// a third size, it was four buttons that happened to be set larger.
//
// Rejected: keeping 15 as a rung for "prominent" buttons. Nothing about the
// four 15pt sites is more prominent than the 13pt ones — one of them is a
// search-field clear button, which is as incidental as a control gets.
//
// Not covered here, deliberately: the 20pt camera glyph filling the 72pt
// photo well in `TraceMacPeopleView`, which belongs to that well rather than
// to any scale, and the interactive star row in Discover, which is a rating
// control and wants the same treatment as `MacStars` when someone builds it.

import SwiftUI

enum MacGlyph {

    /// A glyph inside something small and already bounded: a filter chip, a
    /// sort control, a dismiss on a token. Absorbs the old 8, 8.5 and 9 —
    /// and 9 is not a chosen number, it is where the three sort chevrons had
    /// independently landed.
    static let small = Font.system(size: 9)

    /// A glyph that is a button, in a 24–30pt hit target. Row actions,
    /// toolbar buttons, field affordances. Absorbs the old 11, 12, 13 and 15.
    static let control = Font.system(size: 13)

    /// `control`, for the handful of chip glyphs that were set bold to hold
    /// their weight against a tinted background.
    static let smallBold = Font.system(size: 9, weight: .bold)
}
