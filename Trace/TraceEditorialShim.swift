// TraceEditorialShim.swift
// Trace — the OLD app, which is still installed until merge pass (c).
//
// D473, Session 109. The Editorial token names, answered by Trace's own skin,
// so the old app still builds once a shared screen has been re-skinned.
//
// ── Why this file exists ────────────────────────────────────────────────────
//
// The merge re-skins Trace's screens to Dayflow's Editorial tokens, one screen
// per build, by the substitution table at the foot of
// `Dayflow/TraceSkinBridge.swift`. Those screens live in `Trace/`, and **every
// file in `Trace/` is compiled by the old Trace app as well** — that folder is
// the Trace target's own root group, and its only exclusion is `Info.plist`.
// `DayflowSkin.swift` is in `Dayflow/` and reaches the merged target alone.
//
// So the first `Color.dayflowMuted` written into a shared screen would break
// the old app's build outright. Not a cosmetic problem: Trace is still the
// only place the Notion token can be entered (see the Session 109 note on the
// Simulator), and it is what David would open to check the merge against.
//
// This file is `TraceSkinBridge.swift` facing the other way. It lives in
// `Trace/` and so compiles into the Trace target ONLY — the other seven
// targets reach this folder through inclusion lists in the project file, and
// this file is on none of them, which is what keeps it from colliding with the
// real `DayflowSkin.swift` in the merged target.
//
// **The old app looks exactly as it did.** Every name below answers with the
// TraceSkin value that screen was already drawing, so a re-skinned screen
// renders its old colours in Trace and Editorial in the merged app, from one
// source file. It retires with the old app in pass (c).

import SwiftUI

extension Color {
    /// Trace's warm-grey canvas, where the merged app has paper.
    static let dayflowPaper    = Color.traceCanvas
    /// Trace's white card, where the merged app has the panel.
    static let dayflowPanel    = Color.traceCardBackground
    static let dayflowInk      = Color.traceInk
    static let dayflowMuted    = Color.traceSecondary
    static let dayflowFaint    = Color.traceTertiary
    static let dayflowHairline = Color.traceHairline
    /// Trace's action colour. The merged app's single accent is a burnt
    /// orange; here it stays the blue every link and action in this app has
    /// always been, because nothing about the old app is being restyled.
    static let dayflowAccent   = Color.traceBlue
}

extension Font {
    /// The merged app sets headings in a serif. Trace never did, so this is
    /// the same system face at the same size and weight the screen used
    /// before, and the old app's typography is unchanged.
    static func dayflowSerif(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight)
    }
}
