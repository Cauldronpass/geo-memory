// TraceSkinBridge.swift
// Dayflow — the host target of the one app (D452).
//
// D467, Session 108. Trace's skin names, answered by Dayflow's tokens.
//
// ── Why a bridge and not a rewrite ──────────────────────────────────────────
//
// Trace's screens that come across in the merge (D454) were written against
// `Trace/TraceSkin.swift`: `Color.traceInk`, `.traceCard()`,
// `traceBackground()`, `traceSectionTitleStyle()` and `TraceSegmentedControl`.
// Those values are static and light-only (a white card with a shadow on a
// warm-grey canvas, six semantic colours). The host is the Editorial skin
// (`DayflowSkin.swift`): dynamic light/dark, paper and panel, one accent, a
// hairline instead of a shadow.
//
// This file defines every name `TraceSkin` defines, with the SAME signatures,
// each answered by the Editorial token it corresponds to. A screen moved into
// this target compiles unchanged and draws Editorial, in both appearances.
// The mapping is one table, here, rather than an edit in every view.
//
// ── The one rule that matters ───────────────────────────────────────────────
//
// **`Trace/TraceSkin.swift` must NEVER be added to the Dayflow target.** Both
// files declare the same names; the second one in is a redeclaration error on
// every line. The bridge is the Dayflow-side copy of the contract; the
// original stays with the old Trace app until pass (c) deletes it.
//
// ── What this does not cover ────────────────────────────────────────────────
//
// Only three Trace screens use these names (`HomeView`, `NotesView`,
// `PeopleView`); Home and Notes retire in the merge, so in practice this
// carries `PeopleView` and whatever else adopts the names later. The person,
// place, check-in and log-interaction screens use SYSTEM colours
// (`systemGroupedBackground`, `.secondary`, stock `List` rows) and are a hand
// re-skin, one screen at a time, in pass (a). The substitution table for that
// work is at the foot of this file, so it is done the same way each time.

import SwiftUI

// MARK: - Background & card

extension View {
    /// Was the warm-grey canvas. Now the paper, which is what every Dayflow
    /// screen sits on, in both appearances.
    func traceBackground() -> some View {
        self.background(Color.dayflowPaper.ignoresSafeArea())
    }

    /// Was white, 18pt radius, a soft shadow. Now the Editorial card: panel,
    /// 12pt radius, a hairline, no shadow (D-series skin rule: nothing floats).
    func traceCard() -> some View {
        self.dayflowCard()
    }
}

// MARK: - Colors
//
// Each old name answered by the closest Editorial meaning. The six semantic
// colours collapse onto the one accent on purpose: the Editorial skin retired
// its sidebar colours for having no meaning, and the same argument applies to
// a blue dot, an orange dot and a purple dot that each meant "look here".

extension Color {
    static let traceCanvas         = Color.dayflowPaper
    static let traceCardBackground = Color.dayflowPanel
    static let traceInk            = Color.dayflowInk
    static let traceSecondary      = Color.dayflowMuted
    static let traceTertiary       = Color.dayflowFaint
    static let traceHairline       = Color.dayflowHairline
    static let traceSegmentTrack   = Color.dayflowPanel
    static let traceBlue           = Color.dayflowAccent
    static let traceOrange         = Color.dayflowAccent
    static let tracePurple         = Color.dayflowAccent
    static let traceAmberInk       = Color.dayflowAccent
    /// The avatar wash: the panel, so initials sit on paper-on-paper rather
    /// than on a cream that exists nowhere else in the skin.
    static let traceAmberBg        = Color.dayflowPanel
    static let traceGreen          = Color.dayflowAccent
    /// "Dormant" relationship cue on People rows. Muted rather than accent:
    /// it is a quiet observation, not a call to act.
    static let traceStale          = Color.dayflowMuted
}

// MARK: - Section title

extension View {
    /// Was 12.5pt bold uppercase grey. Now the Editorial caps row: the same
    /// small tracked capitals every Dayflow section label uses.
    func traceSectionTitleStyle() -> some View {
        self
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(1.6)
            .foregroundStyle(Color.dayflowMuted)
            .textCase(.uppercase)
    }
}

// MARK: - TraceSegmentedControl
//
// Same type, same generic signature, so call sites compile unchanged. The
// pill loses its white-and-shadow active segment for the Editorial one: ink
// on paper, active segment filled with ink, the way Records' scope pills are
// drawn. Selection animation kept.

struct TraceSegmentedControl<Option: Hashable>: View {
    let options: [Option]
    let label: (Option) -> String
    @Binding var selection: Option

    var body: some View {
        HStack(spacing: 3) {
            ForEach(options, id: \.self) { option in
                let active: Bool = selection == option
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { selection = option }
                } label: {
                    Text(label(option))
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(1.0)
                        .textCase(.uppercase)
                        .foregroundStyle(active ? Color.dayflowPaper : Color.dayflowMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(active ? Color.dayflowInk : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color.dayflowPanel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.dayflowHairline, lineWidth: 1))
    }
}

// MARK: - The substitution table for screens that use system colours
//
// For `PersonDetailView`, `PlaceDetailView`, `PlacesView`, `DiscoverView`,
// `CheckInView`, `LogInteractionView` and the sheets they present. Apply in
// this order, one screen per build, and look at it in both appearances.
//
//   Color(.systemGroupedBackground), .traceBackground()   →  Color.dayflowPaper  (or traceBackground())
//   Color(.secondarySystemGroupedBackground), white cards  →  .dayflowCard()
//   .foregroundStyle(.secondary)                           →  Color.dayflowMuted
//   .foregroundStyle(.tertiary)                            →  Color.dayflowFaint
//   Divider()                                              →  Rectangle().fill(Color.dayflowHairline).frame(height: 1)
//   .tint(.blue) / Color.accentColor                       →  Color.dayflowAccent
//   List { … }.listStyle(.insetGrouped)                    →  keep the List; .scrollContentBackground(.hidden)
//                                                             + .background(Color.dayflowPaper); rows keep their
//                                                             system separators (the hairline colour is close enough)
//   Section header Text("…").font(.headline)               →  .traceSectionTitleStyle()
//   Large titles (.largeTitle / .title)                    →  Font.dayflowSerif(30) / dayflowSerif(22, weight: .semibold)
//   Segmented Picker(.segmented)                           →  TraceSegmentedControl (above)
//
// Do not touch: SF Symbols and their sizes, layout, spacing, the map, photo
// tiles. The re-skin is colour, type and card treatment, nothing else; a
// screen that also moves things is two changes and cannot be checked as one.
