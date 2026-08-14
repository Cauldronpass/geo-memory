// TraceMacSectionHeader.swift
// The one header row every destination in the detail column starts with.
// Mac-only — do not add to iOS, Widget, or Share Extension targets.
//
// Session 63 (2026-08-02). David, with three screenshots side by side:
// *"when i click on different tabs, the top left of the screen changes
// position. there is different font and in some cases the title extends beyond
// the left column."*
//
// He was describing six different answers to the same question. Before this
// file, the top-left of the detail column was whatever each section happened to
// start with:
//
//   Notes / Directory / Activity   a segmented picker, h16 v8, labels hidden
//   Archive                        a segmented picker, h20 v10, label *visible*
//   Satchel / Inbox                nothing — content began at y = 0
//   Home                           a full-bleed greeting band
//
// …and above all of them, a window title bar that also changed: Archive set
// `.navigationTitle("Archive")` so the window renamed itself, and Daily put its
// list toggle in `ToolbarItem(placement: .navigation)`, the one slot left of the
// title, which shoved the title right on that screen and nowhere else.
//
// None of those six were decisions. They are the order the sections were built
// in. So this is not a compromise between them — it is one row, at one height,
// with one typography, that every section uses:
//
//     MacSectionHeader("Satchel")                     // no tabs
//     MacSectionHeader("Notes") { picker }            // tabs
//
// **Why a title at all**, when the sidebar already says which section you are
// in: because the title is what makes the origin fixed. A header that is only a
// tab strip disappears on the three sections that have no tabs, and their
// content jumps back to y = 0 — which is the bug. The title is the constant;
// the tabs are the variable sitting next to it.
//
// The tabs are **leading**, right after the title, not trailing. Trailing is how
// they read before this change, and what David saw was a control drifting to the
// far edge of a window and clipping. Everything in this row now hangs off the
// left margin, and `Spacer` absorbs whatever the window is wide.
//
// The header does not own the tab *state*. Each container still holds its
// selection in local `@State` — see the note on `TraceMacNotesView` for the
// three attempts it took to learn that — and passes the built control in.

import SwiftUI

/// Layout constants for the detail column's chrome. One place, so a change is
/// a change everywhere rather than a change in five files and a miss in the
/// sixth.
enum MacChrome {
    /// Height of the section header row, excluding its bottom divider.
    static let headerHeight: CGFloat = 38
    /// Left margin of the header, and the margin section content should align
    /// to when it has a choice.
    static let headerInset: CGFloat = 16
    /// Gap between the section title and whatever sits beside it.
    static let headerGap: CGFloat = 12
}

/// The trailing action slot, added Session 65.
///
/// David, after using the `+` on the Endeavor rail: *"can we add a plus to the
/// satchel as well?"* Satchel already had an import, in the **window toolbar**,
/// spelled `square.and.arrow.down` and labelled "Import". Two problems with it,
/// and only the second is about the icon.
///
/// It was nowhere near the thing it acts on, and it sat between Open and
/// Reveal, which act on the *selected document* — so the section's own verb
/// read as a third thing you could do to the file in front of you. And
/// `square.and.arrow.down` is the download glyph: it says the file comes from
/// somewhere, which is true and is not the point.
///
/// The slot lives here rather than in one view because "the section's own
/// action" is something every section either has or conspicuously lacks, and
/// this row already exists to be the one answer for the top of a section.
/// Endeavors wants it next, for a new endeavor.
///
/// Trailing, after the `Spacer`, which is the opposite call from the tabs and
/// deliberately so. Tabs are leading because a control drifting to the far edge
/// of a wide window and clipping is the bug this file was written to fix. A
/// single fixed-width glyph cannot clip, and the right edge is where macOS puts
/// add.
///
/// ── Why `MacHeaderButton?` and not a second `@ViewBuilder` ────────────────
///
/// The obvious shape is `MacSectionHeader<Tabs, Actions>` with an `actions:`
/// builder. **It does not compile at the call sites that already exist.** With
/// both a `tabs`-only and an `actions`-only convenience init in scope, every
/// one of the five `MacSectionHeader("Notes") { picker }` sites becomes
/// ambiguous: one closure, two overloads that each take exactly one closure,
/// and Swift cannot tell which end of the row you meant. Correctly, since they
/// are opposite ends.
///
/// A concrete optional has none of that, and it buys the thing `MacHeaderButton`
/// wants anyway: the four sections that will grow one of these cannot each pick
/// a size. That is D16's `initialsCircle` failure, where a component took a free
/// number and four call sites ignored it.
struct MacSectionHeader<Tabs: View>: View {

    private let title: String
    private let tabs: Tabs
    private let action: MacHeaderButton?

    init(_ title: String,
         action: MacHeaderButton? = nil,
         @ViewBuilder tabs: () -> Tabs) {
        self.title  = title
        self.action = action
        self.tabs   = tabs()
    }

    /// Back and forward, drawn once and therefore present in every section.
    ///
    /// **This component is the reason the feature is cheap.** Every section in
    /// the app already draws this header, so the arrows needed one insertion
    /// rather than seven — and a section added later gets them without knowing
    /// they exist.
    ///
    /// The buttons ask rather than act: they set `MacNavigator.pendingReplay`,
    /// which `TraceMacContentView` consumes. The header is drawn *inside* a
    /// section and has no access to the pending-link state that performs a move.
    @State private var navigator = MacNavigator.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: MacChrome.headerGap) {
                HStack(spacing: 2) {
                    Button { navigator.goBack() } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(!navigator.canGoBack)
                    .help("Back")

                    Button { navigator.goForward() } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(!navigator.canGoForward)
                    .help("Forward")
                }
                .buttonStyle(.plain)
                .font(MacType.body)
                // Dimmed rather than hidden when there is nowhere to go. A
                // control that disappears makes the row jump and takes its own
                // position with it; a greyed one says "not yet" in place.
                .foregroundStyle(.secondary)

                Text(title)
                    .font(MacType.heading)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // Lower than the tabs' implicit priority: in a narrow window
                    // the word "Directory" shortening is recoverable, a tab you
                    // cannot read is not.
                    .layoutPriority(0)

                // `fixedSize` is the fix for the clipping David saw. A macOS
                // `Picker` handed a wide container spreads to fill it and pins
                // the control to the trailing edge; at its natural width it
                // simply sits where it is put.
                tabs
                    // Horizontal only. The tabs slot sizes to its content and
                    // sits where it is put; the row already has a fixed height,
                    // so fixing the vertical axis as well only creates a second
                    // opinion about it.
                    //
                    // This originally existed to stop a macOS segmented `Picker`
                    // spreading to fill a wide container and pinning itself to
                    // the trailing edge. The tabs are `MacTabStrip` now — see
                    // that file for why the picker is gone — and it does not
                    // spread, but content-sizing is still what this slot wants.
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)


                Spacer(minLength: 0)

                action
            }
            .padding(.horizontal, MacChrome.headerInset)
            .frame(height: MacChrome.headerHeight)

            Divider()
        }
    }
}

extension MacSectionHeader where Tabs == EmptyView {
    /// Sections with no tabs — Satchel, Inbox — so that they still start at the
    /// same y as the ones that do. Takes the action, because Satchel has one and
    /// no tab strip to hang it beside.
    ///
    /// Deliberately has **no closure parameter**, which is what keeps every
    /// existing `MacSectionHeader("Notes") { picker }` unambiguous: a trailing
    /// closure has exactly one init it can bind to.
    init(_ title: String, action: MacHeaderButton? = nil) {
        self.init(title, action: action) { EmptyView() }
    }
}

// MARK: - Header action button

/// The glyph button that goes in a header's action slot.
///
/// A concrete type rather than any view, so the sections that grow one cannot
/// each choose a size — see the note above. Sized by its target per D17: a 12pt
/// glyph in a 22pt hit area, the same relationship the Endeavor rail's `+` uses
/// one rung down.
struct MacHeaderButton: View {

    let icon: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }
}
