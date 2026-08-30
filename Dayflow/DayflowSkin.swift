import SwiftUI

// MARK: - DayflowSkin
//
// Visual skin locked 2026-07-21 (Session 29) via iterative HTML mockup review
// — see Dayflow-Design-Plan.md "Visual skin — confirmed via mockup review"
// and the canonical reference Dayflow-Skin-Mockup.html (same folder) for the
// full spec and exact values this file implements. Centralizes the skin's
// colors, font, and custom icon shapes so DayflowContentView.swift,
// DayflowAgendaSection.swift, and DayflowDailyNoteSection.swift all draw from
// one place rather than duplicating hex values / Path math.
//
// **Two of the mockup's six icon slots (collapse, refresh) are drawn here
// using REAL SF Symbols instead of hand-rolled custom shapes** —
// `chevron.up.chevron.down` and `arrow.triangle.2.circlepath` respectively.
// The mockup's own hand-drawn versions were explicitly built as
// approximations of exactly these two real symbols (see the Design Plan), so
// using the real thing is a strictly safer implementation choice than
// reproducing circular-arc Path math with no simulator available in this
// sandbox to visually verify it against. The other three custom icons
// (expand, Notes & Projects, and the Daily Note title's pencil+writing-line)
// have no real SF Symbol equivalent and are implemented below as custom
// `Shape`s using only straight lines / rects / a circle — no arcs, so no
// unverified curve-geometry risk the sync-loop icon would have carried.
//
// Not independently verified in Xcode/Simulator — same standing limitation as
// every other Dayflow session. Check the icon sizes/weights on first build;
// the stroke widths below are reasoned to match the existing header icon
// buttons' visual weight (11-12pt SF Symbols at .semibold), not measured
// against a real render.

// MARK: Background

extension View {
    /// The background gradient — warm-neutral. **Re-tuned 2026-07-21 (Session
    /// 30, post-implementation round 2).** The original Session 29 values
    /// (#F9F7F2/#F5F2EB/#F0ECE3) rendered too close to plain white once seen
    /// on a real device — David compared a real build against a reference
    /// photo and asked for something "more pronounced." Picked option "C"
    /// from a 4-option strength comparison (A = original, B/C/D progressively
    /// warmer) rendered as a quick side-by-side swatch image rather than a
    /// full Xcode rebuild per round. These values are NOT from
    /// Dayflow-Skin-Mockup.html — that file still has the original, paler
    /// Session 29 gradient; this is a deliberate real-device correction on
    /// top of it. If the mockup HTML is ever revisited, update it to match.
    func dayflowSkinBackground() -> some View {
        // Editorial skin (Session 77, locked 2026-08-28 on the "Dayflow Skin"
        // canvas): flat paper, no gradient — light #FBF9F4, dark #1B1916.
        // The cream gradient above this line's history was Session 29/30;
        // David moved off it ("I no longer like the parchment skin").
        self.background(Color.dayflowPaper.ignoresSafeArea())
    }

    /// The locked card treatment — larger radius, soft warm-tinted shadow, no
    /// stroke border. Replaces the previous `.background(.background, in:
    /// RoundedRectangle(cornerRadius: 16))` + quaternary-stroke overlay used
    /// on both the Agenda and Daily Note cards before this skin. It keeps the
    /// adaptive `.background` material rather than a hardcoded white.
    ///
    /// **That reasoning was wrong, and is kept here as the record.** The stated
    /// intent was that staying adaptive meant dark mode "doesn't regress". But
    /// the canvas behind these cards is `dayflowSkinBackground`, a HARDCODED
    /// cream gradient — so in dark mode the cards render black on cream, which
    /// is precisely the regression the choice was meant to avoid. David hit it
    /// on device 2026-07-28.
    ///
    /// The app now defaults to light, so this is inert. If dark mode is ever
    /// done properly it is a pass over the whole token set — canvas, cards, ink,
    /// hairlines — not a material swap here.
    @ViewBuilder
    func dayflowCard(enabled: Bool = true) -> some View {
        // Editorial skin (Session 77): the Today sheet dropped cards entirely
        // (label + rule on paper — see DayflowTodaySection); the browse
        // screens keep this treatment until their own rebuild rounds, now as
        // a flat panel with a hairline instead of a floating shadow, and
        // dynamic for dark mode. `enabled: false` (Session 78, Notes
        // redesign) lets a screen that is EMBEDDED in an already-Editorial
        // host (To File inside the Notes tab) drop the panel without
        // forking its body.
        if enabled {
            self
                .background(Color.dayflowPanel, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.dayflowHairline, lineWidth: 1))
        } else {
            self
        }
    }
}

// MARK: Column label color

extension Color {
    /// Editorial token set (Session 77, locked 2026-08-28). Every color is
    /// dynamic — light/dark values straight from the two locked frames on
    /// the "Dayflow Skin" canvas — so the Settings Appearance row
    /// (light/dark/system) finally does what it says.
    private static func editorial(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }

    /// The page. Everything sits directly on this.
    static let dayflowPaper = editorial(0xFFFFFF, 0x1B1916)
    /// Panels for screens still using dayflowCard(), and the note editor well.
    static let dayflowPanel = editorial(0xF7F7F5, 0x23201B)
    /// Secondary text — times, counts, quiet copy.
    static let dayflowMuted = editorial(0x6E6A64, 0xA69F90)
    /// Tertiary — gap parentheticals, folds, inactive pill days, dashes.
    static let dayflowFaint = editorial(0xA6A29B, 0x6E6759)
    /// Row separators.
    static let dayflowHairline = editorial(0xE9E8E4, 0x33302A)
    /// The one accent — active tab, TODAY pill, source chips.
    static let dayflowAccent = editorial(0xC24D2A, 0xD0603C)
    /// Body copy a step softer than ink (day note text, the weekday).
    static let dayflowNoteText = editorial(0x33302A, 0xCFC8B8)
    /// The floating + — ink square in light, ACCENT square in dark (the
    /// locked dark frame; an inverted-ink square read as a white button,
    /// David flagged it 2026-08-28). Glyph is dayflowPaper in both.
    static let dayflowFloatingAction = editorial(0x1A1814, 0xD0603C)

    /// Pre-Editorial name kept for existing call sites.
    static let dayflowColumnLabel = dayflowFaint

    /// Near-black ink used for icons/text that should read as monochrome
    /// black in the mockup, NOT the system accent blue. Added Session 30
    /// (post-implementation fix) after David compared a real build against
    /// `Dayflow-Skin-Mockup.html` and flagged the top-bar day pill and the
    /// top-bar calendar (Browse menu) icon as rendering in default Button/Menu
    /// accent blue — pre-existing code from before the skin work, never
    /// touched by Session 29/30 because it wasn't assumed to need touching.
    /// `Menu`'s label content tints with the environment accent color by
    /// default unless a `.foregroundStyle` override breaks that; a plain
    /// `Label` (like Agenda's calendar icon) does not have this problem,
    /// which is why only the Menu-based top-bar icon was affected.
    static let dayflowInk = editorial(0x1A1814, 0xEDE7DA)

    /// Inactive day-pill text color (Yesterday/Tomorrow) — muted warm gray,
    /// not `.secondary`'s cooler system gray. Added alongside `dayflowInk`,
    /// same Session 30 fix.
    static let dayflowPillInactiveText = dayflowFaint
}

// MARK: Serif font

extension Font {
    /// `design: .serif` resolves to New York on Apple platforms — the actual
    /// fix for David's "capital J doesn't match Parchment" note (Georgia was
    /// never going to match Parchment's real letterforms; New York almost
    /// certainly is what Parchment itself uses). Used for the main date
    /// headline and both card titles ("Agenda", "Daily Note").
    static func dayflowSerif(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
}

// MARK: Custom icon shapes
//
// Each Shape below is built in a fixed "design space" (24×24 unless noted)
// and scales to whatever rect SwiftUI gives it — `.frame(width:, height:)`
// at the call site controls the rendered size. Non-square icons (the pencil,
// below) need a frame matching their real aspect ratio, not a square one.

/// Daily Note's "Expand to full page" icon — corner brackets + diagonal
/// lines, deliberately NOT the real `arrow.up.left.and.arrow.down.right` SF
/// Symbol (which draws arrowheads, not brackets) — a custom composite David
/// picked over three other options in the icon-review round. Design space
/// 24×24.
struct DayflowExpandIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 24
        let sy = rect.height / 24
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy)
        }
        var p = Path()
        // top-left bracket
        p.move(to: pt(9, 3)); p.addLine(to: pt(3, 3)); p.addLine(to: pt(3, 9))
        // bottom-right bracket
        p.move(to: pt(15, 21)); p.addLine(to: pt(21, 21)); p.addLine(to: pt(21, 15))
        // diagonals from each corner toward the center
        p.move(to: pt(3, 3)); p.addLine(to: pt(9.5, 9.5))
        p.move(to: pt(21, 21)); p.addLine(to: pt(14.5, 14.5))
        return p
    }
}

/// Daily Note's "Notes & Projects" icon — a short list (two bars) plus a
/// magnifying glass. Replaces `doc.text.magnifyingglass` (the original
/// placeholder guess, flagged as visually unconfirmed in this file's own
/// prior header comment, and it turned out David didn't like it once he saw
/// it rendered). Reasoned against what the button actually does: it opens
/// search, and lets you add a project note/place/person from inside that
/// same sheet — not just "browse a document." Design space 24×24.
struct DayflowNotesProjectsIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 24
        let sy = rect.height / 24
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy)
        }
        var p = Path()
        p.addRoundedRect(
            in: CGRect(x: pt(3, 4.5).x, y: pt(3, 4.5).y, width: 13 * sx, height: 4 * sy),
            cornerSize: CGSize(width: sx, height: sy)
        )
        p.addRoundedRect(
            in: CGRect(x: pt(3, 11).x, y: pt(3, 11).y, width: 10 * sx, height: 4 * sy),
            cornerSize: CGSize(width: sx, height: sy)
        )
        let lensCenter = pt(17.5, 17)
        p.addEllipse(in: CGRect(x: lensCenter.x - 3.6 * sx, y: lensCenter.y - 3.6 * sy,
                                 width: 7.2 * sx, height: 7.2 * sy))
        p.move(to: pt(20, 19.5)); p.addLine(to: pt(22, 21.5))
        return p
    }
}

/// Daily Note's title icon — a slim, straight-edged pencil (David rejected an
/// earlier rounder/kite-shaped body after seeing it in context) with its
/// eraser-division accent line restored, plus a separate straight "writing
/// line" to the LEFT of the tip (not underneath it), aligned to the pencil's
/// bottom edge, with a deliberate gap before the tip — representing a line of
/// handwriting on the page, distinct from the eraser line. Went through the
/// most iteration rounds of any icon in this skin — see Dayflow-HANDOFF.md
/// Session 29 for the full back-and-forth. Design space is 30×24 (NOT
/// square) — give this shape a frame matching that ~1.25:1 aspect, e.g.
/// `.frame(width: 22, height: 17.6)`.
struct DayflowPencilIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 30
        let sy = rect.height / 24
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy)
        }
        var p = Path()
        // Pencil body — slim, straight-edged hexagon (shape "A" from the
        // icon-review round; the original rounder/kite-shaped body was
        // rejected once David saw it in context).
        p.move(to: pt(23, 3))
        p.addLine(to: pt(27, 7))
        p.addLine(to: pt(15, 19))
        p.addLine(to: pt(10, 20))
        p.addLine(to: pt(11, 15))
        p.closeSubpath()
        // Eraser-division accent line, near the blunt end — restored after
        // David clarified he wanted this back (distinct from the separate
        // writing-line request below).
        p.move(to: pt(19.5, 6.5)); p.addLine(to: pt(23.5, 10.5))
        // Writing line — to the left of the tip, aligned to the pencil's
        // bottom edge (y matches the tip's y), with a gap before the tip
        // rather than touching it.
        p.move(to: pt(0, 20)); p.addLine(to: pt(6, 20))
        return p
    }
}
