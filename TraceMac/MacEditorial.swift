// MacEditorial.swift
// The Editorial register — the Mac's half of Dayflow's design language.
// Mac-only — do not add to iOS, Widget, or Share Extension targets.
//
// Session 79 (2026-08-30), D189. Trace on the Mac grew three screens that
// speak Dayflow's language rather than TraceMac's: Today, Upcoming and Tasks.
// This file is what they speak it with.
//
// ── Why this is not an extension of MacType ───────────────────────────────
//
// `MacType` is a deliberate, audited scale (Session 64, D19): six roles,
// 17/13/13/12/10/10, built for dense Mac list UI, with the rule that a caller
// picks a role and never a number. It is not an accident to be tidied away,
// and nothing here weakens it — the seven RECORDS sections keep using it,
// untouched.
//
// But Editorial is a different register, not a bigger version of the same one.
// A newspaper masthead at 38pt serif heavy and a caps standfirst tracked at
// 2.2 are not `MacType.title` and `MacType.label` with the numbers moved; they
// are a second voice. Trying to express both through one six-role scale would
// mean either flattening Editorial into Mac list typography (which is exactly
// the joy David is asking for, deleted) or inflating MacType's roles until
// they no longer describe the screens that use them.
//
// So: two registers, one rule each, and the rule is MacType's own — **roles,
// never numbers**. There is no `MacEditorialType.size(16)` here either. The
// values come from `DayflowSkin.swift` and the iOS screens verbatim, so the
// Mac and the phone stay one design rather than two that resemble each other.
//
// ── Colour goes through macDynamic, as MacColor requires ──────────────────
//
// `MacColor.swift` deleted `Color(hex:)` on purpose: a bare hex is how you get
// a token that looks right in one appearance and fails contrast in the other.
// Every colour below is a `macDynamic(light:dark:)` pair, and both halves are
// the pair Dayflow already ships — `Color.dayflowPaper` and friends resolve
// exactly these values on iOS. One token, two apps, one answer, which is what
// `Color.traceOrange` still cannot say about itself.
//
// ── And they live in an enum, not on `Color` ──────────────────────────────
//
// First cut of this file put the nine tokens on `extension Color`, matching
// `Color.traceOrange`. TraceMac then failed to build with "the compiler is
// unable to type-check this expression in reasonable time" in
// `TraceMacDocumentsView` — a 3,800-line file with expressions already close
// to the type-checker's budget, tipped over by nine more static members in
// `Color`'s overload set. No expression in that file changed; the search space
// around it did.
//
// `MacPalette` was already an enum for reasons of its own, and this is a
// second one: a namespace costs seven characters at every call site
// (`MacEditorialColor.ink` rather than a member on `Color`) and costs the type
// checker nothing.
// `traceOrange` stays where it is — one member is not a budget.

import SwiftUI

// MARK: - Colour

enum MacEditorialColor {

    /// The page. Cards are retired in this register — Editorial screens are
    /// full-bleed paper divided by rules, not floating panels.
    static let paper = Color.macDynamic(light: "FFFFFF", dark: "1B1916")

    /// The ground behind the paper. Warm off-white in light, the same ink-brown
    /// as paper in dark (Dayflow's locked dark frame has no second ground).
    static let canvas = Color.macDynamic(light: "FBF9F4", dark: "1B1916")

    /// The sidebar, and any rail that should sit a step back from the page.
    static let panel = Color.macDynamic(light: "F7F7F5", dark: "23201B")

    /// Headline ink. Mastheads, section labels, rules that mean something.
    static let ink = Color.macDynamic(light: "1A1814", dark: "EDE7DA")

    /// Body copy, one step softer than ink. Note text, the weekday beside the
    /// date numeral.
    static let noteText = Color.macDynamic(light: "33302A", dark: "CFC8B8")

    /// Standfirsts and secondary values — present, subordinate.
    static let muted = Color.macDynamic(light: "6E6A64", dark: "A69F90")

    /// Furniture that should be findable but never read first: counts, empty
    /// states, unset field values, the offer line.
    static let faint = Color.macDynamic(light: "A6A29B", dark: "6E6759")

    /// The 1pt line between rows. Not a rule — a rule is ink and means a
    /// section; a hairline is separation and means nothing.
    static let hairline = Color.macDynamic(light: "E9E8E4", dark: "33302A")

    /// The ONE accent. It means active, or acting, and nothing else. Never
    /// decoration, never a second colour to reach for.
    static let accent = Color.macDynamic(light: "C24D2A", dark: "D0603C")

    /// Events from a calendar David has flagged as somebody else's (D193,
    /// amended Session 80). The one colour in this app that does NOT name a
    /// category of meeting — it names WHOSE meeting it is, and it replaces the
    /// classifier's verdict entirely rather than sitting beside it.
    ///
    /// The first version of D193 drew these hollow, with a half-height track
    /// block. David killed it for a better reason than the one that built it:
    /// weight is a RELATIVE signal, and on a day whose events are all his
    /// wife's there is nothing on screen to be relative to. Colour is absolute.
    ///
    /// Baby blue, with the risk named rather than hidden: the meeting-colour
    /// system already owns a blue (`#6E9CE8`, forecast meetings — 3+9, 6+6,
    /// 9+3, 12+0). This is deliberately PALER and cooler so that at 8pt it
    /// reads as a different thing rather than a lighter version of the same
    /// thing, and forecast meetings are rare enough that a confusion would be
    /// uncommon and cheap. Every surface reads this token; change it here.
    static let foreignEvent = Color.macDynamic(light: "8ECAE6", dark: "7CB6D2")
}

// MARK: - Type

/// Editorial's roles. Same contract as `MacType`: a caller picks a role.
///
/// Serif roles resolve to New York via `design: .serif`; that is the face
/// Dayflow's mastheads and row titles wear, and the pairing with the system
/// sans for all caps furniture is the whole look.
enum MacEditorialType {

    // MARK: Serif — the voice

    /// The day numeral on Today. The largest thing on any screen.
    static let mastheadNumeral = Font.system(size: 38, weight: .heavy, design: .serif)

    /// The weekday beside it, deliberately a step down and a step softer.
    static let mastheadWeekday = Font.system(size: 22, weight: .semibold, design: .serif)

    /// A screen's own name where there is no date to lead with — "Upcoming",
    /// "Tasks".
    static let masthead = Font.system(size: 34, weight: .heavy, design: .serif)

    /// A day heading inside a list of days (Upcoming's spread).
    static let dayNumeral = Font.system(size: 23, weight: .heavy, design: .serif)

    /// The subject of an inspector — the selected task's title.
    static let subject = Font.system(size: 21, weight: .semibold, design: .serif)

    /// A meeting on the day.
    static let rowTitle = Font.system(size: 16, design: .serif)

    /// A task row. Half a point under `rowTitle` because a task sits beside a
    /// circle and a meeting sits beside a time.
    static let taskTitle = Font.system(size: 15.5, design: .serif)

    /// Prose in the day note.
    static let note = Font.system(size: 15.5, design: .serif)

    /// A value in the inspector's field rows.
    static let fieldValue = Font.system(size: 13.5, design: .serif)

    // MARK: Sans — the furniture

    /// Clock times. Tabular so a column of them does not shimmer.
    static let time = Font.system(size: 12).monospacedDigit()

    /// Durations, counts, anything parenthetical beside a title.
    static let meta = Font.system(size: 12)

    // MARK: Caps — always through the modifiers below
    //
    // MacType exposes `label` bare only for the rare label that must not
    // uppercase, and pairs it with `.macLabel()` everywhere else, because two
    // tracking values on one screen is what produced that rule. Same here:
    // each caps role has a font AND a tracking, and they are shipped together
    // by a modifier. Reaching for the font alone is how they drift apart.

    /// The standfirst over a masthead: "AUGUST · 73° AND CLEAR".
    static let kicker = Font.system(size: 11, weight: .medium)
    static let kickerTracking: CGFloat = 2.2

    /// A section's name on the page: "THE DAY", "TO DO", "DAY NOTE".
    static let sectionLabel = Font.system(size: 11, weight: .bold)
    static let sectionTracking: CGFloat = 2.0

    /// A group of navigation rows: "THE DAY", "RECORDS".
    static let groupLabel = Font.system(size: 9, weight: .bold)
    static let groupTracking: CGFloat = 1.8

    /// A navigation row itself: "TODAY", "SATCHEL".
    static let navLabel = Font.system(size: 11, weight: .semibold)
    static let navLabelActive = Font.system(size: 11, weight: .bold)
    static let navTracking: CGFloat = 1.2

    /// An inspector field's name: "WHEN", "LIST", "REMIND".
    static let fieldLabel = Font.system(size: 9.5, weight: .bold)
    static let fieldTracking: CGFloat = 1.6

    /// The fold line under a meeting: "AGENDA · 2". Also the offer line's
    /// "+ REPEAT · + PLACE · + WEB".
    static let quietLabel = Font.system(size: 10, weight: .semibold)
    static let quietTracking: CGFloat = 1.4

    /// A list name at the right of a task row: "FINANCE".
    static let listLabel = Font.system(size: 9.5)
    static let listTracking: CGFloat = 1.1
}

extension View {

    /// The standfirst over a masthead. Muted by default; a caller that wants
    /// it accent (the endeavor presence line) passes its own colour after.
    func editorialKicker() -> some View {
        font(MacEditorialType.kicker)
            .textCase(.uppercase)
            .tracking(MacEditorialType.kickerTracking)
            .foregroundStyle(MacEditorialColor.muted)
    }

    /// A section's name on the page. Ink, because a section heading is
    /// structure and structure is ink.
    func editorialSectionLabel() -> some View {
        font(MacEditorialType.sectionLabel)
            .textCase(.uppercase)
            .tracking(MacEditorialType.sectionTracking)
            .foregroundStyle(MacEditorialColor.ink)
    }

    /// A navigation group's name in the sidebar.
    func editorialGroupLabel() -> some View {
        font(MacEditorialType.groupLabel)
            .textCase(.uppercase)
            .tracking(MacEditorialType.groupTracking)
            .foregroundStyle(MacEditorialColor.faint)
    }

    /// A navigation row. Accent + bold when it is the one you are on, which is
    /// the only thing the accent ever says.
    func editorialNavLabel(active: Bool) -> some View {
        font(active ? MacEditorialType.navLabelActive : MacEditorialType.navLabel)
            .textCase(.uppercase)
            .tracking(MacEditorialType.navTracking)
            .foregroundStyle(active ? MacEditorialColor.accent : MacEditorialColor.muted)
    }

    /// An inspector field's name.
    func editorialFieldLabel() -> some View {
        font(MacEditorialType.fieldLabel)
            .textCase(.uppercase)
            .tracking(MacEditorialType.fieldTracking)
            .foregroundStyle(MacEditorialColor.faint)
    }

    /// The quiet caps line: an agenda fold, an offer line, a count.
    func editorialQuietLabel() -> some View {
        font(MacEditorialType.quietLabel)
            .textCase(.uppercase)
            .tracking(MacEditorialType.quietTracking)
            .foregroundStyle(MacEditorialColor.faint)
    }

    /// A list name trailing a task row.
    func editorialListLabel() -> some View {
        font(MacEditorialType.listLabel)
            .textCase(.uppercase)
            .tracking(MacEditorialType.listTracking)
            .foregroundStyle(MacEditorialColor.faint)
    }
}

// MARK: - Rules
//
// Three weights, and the difference between them is meaning, not taste:
//
//   heavy (3pt ink)  opens a masthead. One per screen.
//   ink   (1pt ink)  closes a masthead, or underlines a section that owns
//                    what follows it.
//   hair  (1pt)      separates two rows of the same kind. Says nothing.
//
// A screen that uses `ink` where it means `hair` reads as a stack of sections
// with no hierarchy, which is the failure mode this enum exists to prevent.

enum MacEditorialRule {

    static var heavy: some View {
        Rectangle().fill(MacEditorialColor.ink).frame(height: 3)
    }

    static var ink: some View {
        Rectangle().fill(MacEditorialColor.ink).frame(height: 1)
    }

    static var hair: some View {
        Rectangle().fill(MacEditorialColor.hairline).frame(height: 1)
    }

    /// The month masthead's rule on Upcoming — accent, because a month turning
    /// over is the one structural event that earns the accent.
    static var accent: some View {
        Rectangle().fill(MacEditorialColor.accent).frame(height: 2)
    }
}

// MARK: - Layout
//
// The widths the three screens were drawn at ("Trace Mac Day" canvas,
// Session 79). Here rather than in each view for the same reason `MacChrome`
// exists: a change should be a change everywhere, not a change in two files
// and a miss in the third.

enum MacEditorialLayout {

    /// The sidebar. Fixed — it is a masthead footer stood on its end, not a
    /// resizable pane.
    static let sidebarWidth: CGFloat = 208

    /// THE DAY column on Today. A reading measure, deliberately not elastic:
    /// a day that stretches to fill a widescreen monitor stops being a column.
    static let dayColumnWidth: CGFloat = 524

    /// The month rail on Today and Upcoming.
    static let railWidth: CGFloat = 248

    /// The task inspector on Tasks.
    static let inspectorWidth: CGFloat = 348

    /// A list column beside a note — Projects (D256). Narrower than THE DAY's
    /// reading measure, wider than a rail: a title, a first line and a date
    /// need the room; a column of meetings needs more.
    static let listColumnWidth: CGFloat = 400

    /// Left margin of a page's content, and the margin everything on it aligns
    /// to. Wider than `MacChrome.headerInset` (16) on purpose — Editorial pages
    /// breathe, list sections do not.
    static let margin: CGFloat = 34

    /// Top padding above a masthead.
    static let topMargin: CGFloat = 26

    /// The floating capture square, bottom-trailing on Today, Upcoming and
    /// Tasks (D188).
    static let plusSize: CGFloat = 46
    static let plusInset: CGFloat = 24
}
