import SwiftUI
import UIKit

// MARK: - DayflowDailyNoteSection
//
// Dayflow-Design-Plan.md "Daily Note section" (build order step 4), main-view
// card. Ground truth: Dayflow-Mockup.html's #noteBodyScroll card — a bounded
// note box, not one that grows the whole page indefinitely with a long note.
//
// **Revised 2026-07-19, same day, after real-device testing.** The mockup
// implements "grows when Agenda is collapsed" as two fixed CSS max-heights
// (190px / 430px). The first SwiftUI pass copied that idea with two hardcoded
// `.frame(height:)` constants — David tested it and reported the card felt
// "way too small," correctly guessing collapsed/empty Agenda ought to free up
// more room than it was. The real bug: a fixed-height card can't use freed
// space unless something recomputes the fixed number, and two hardcoded
// constants only account for one binary state (collapsed or not), not "how
// much room did Agenda actually leave." Fix: this card now takes
// `.frame(maxHeight: .infinity)` and ContentView's outer container dropped
// its wrapping `ScrollView`, so this card simply absorbs whatever vertical
// space Agenda and the rest of the fixed-height chrome don't use — smaller
// when Agenda is showing a full grid, bigger when Agenda is collapsed to its
// one-line summary or genuinely empty, with no magic numbers to keep in sync.
// `agendaCollapsed` is no longer threaded in from ContentView — it's not
// needed for sizing anymore since the layout is now driven by actual
// available space, not a state flag.
//
// **Icon order + third icon, added 2026-07-20 (Session 11).** Was Expand/
// Share (mirroring the mockup's ⤢ / ↗ order). David asked for Share / Expand
// / Notes, left to right — matches Agenda's own header, which also ends with
// its highest-commitment action on the right (the blue "+"). Notes
// (DayflowNotesView — search over notes, plus project-note create/view/
// append) is new.
//
// **Real Share implementation, added 2026-07-22 (Session 36).** Was a dummy
// stub the whole time (`onShare` from ContentView just logged "Share — not
// built yet" to the Xcode console) — David flagged this directly. Now reads
// today's note fresh off disk (via `NoteStore`, same backend
// `DayflowDailyNoteEditor` itself reads/writes) at the moment Share is
// tapped and hands it to the system share sheet. Deliberately NOT threading
// the editor's live in-memory `content` up through a new binding —
// `DayflowDailyNoteEditor` already establishes (Session 31's staleness fix)
// that its `save(_:)` writes to disk in real time on every edit, so a fresh
// disk read at tap time is exactly as current as the in-memory state would
// be, with far less surface area than piping a new `@Binding` through this
// view and `ContentView` just for this one button. `onShare` (the old
// console-only callback) is gone — this view is self-contained for Share now.
//
// **Pencil icon repurposed as the Related Notes entry point, 2026-07-23
// (Session 38 addendum).** The Related Notes feature (see
// DayflowRelatedNotes.swift / DayflowDailyNoteEditor.swift) first shipped
// with an always-visible inline "Link a note" row under the note text —
// David tried it and correctly flagged that on this card specifically
// (already tight, especially with a short note) it cost real estate the
// card can't spare, unlike the full-page view where it still lives inline.
// His fix: reuse the existing pencil icon here as the entry point instead —
// it's already decorative chrome next to the title, doing nothing on tap.
// Wrapped in a Menu now (same five-option `dayflowLinkKindMenuItems` Project
// Note's own header Menu uses), and `DayflowDailyNoteEditor` is told
// `showInlineLinkAffordance: false` so its Related Notes section stops
// rendering the inline row and — same as Project Note — stays hidden
// entirely until something's actually linked. The Menu writes into
// `activeLinkFlow` here, passed down as `externalActiveLinkFlow` so
// `DayflowDailyNoteEditor` still owns the actual link-flow sheet and
// persistence; see that file's header comment for the full reasoning.
//
// **Pin added, Share folded into the pencil Menu, 2026-07-23 (Session 38
// addendum 7).** Design discussion for pinning Daily Notes (deferred from
// earlier this session until the Related Notes build + its bugs were done):
// pin needed to be its own always-visible toggle, not folded into a Menu
// like Share was, since David specifically wanted to be able to tell at a
// glance whether a day is pinned — a Menu item can't show that without being
// opened. But both of this card's two obvious icon slots were already
// spoken for (pencil → Related Notes Menu, and there was no third slot to
// spare without crowding). David's own fix: since Share is a one-off action
// with no state to display, it can live inside the pencil Menu just fine
// (added as a final item below the five link types, past a Divider) — that
// frees the icon slot Share used to occupy for the new Pin toggle, which
// does need to be its own dedicated, state-reflecting button. Pin reuses
// `DayflowFlagStore.shared` exactly as Project Note's own pin button
// does — no changes needed to that store, this was purely a UI wiring
// question. Full-page parity: David asked for a separate Pin icon next to
// the calendar icon there instead, since that screen never had a Share
// button to fold anything into — see DayflowNoteFullPageView.swift.

struct DayflowDailyNoteSection: View {
    let date: Date
    /// Session 38 addendum 5 — bumped by ContentView whenever the full-page
    /// view (a separate DayflowDailyNoteEditor instance) is dismissed, so
    /// this card picks up whatever was just edited there. See ContentView's
    /// `dailyNoteReloadToken` comment for the full reasoning; this card's
    /// own `.task(id: date)` reload only fires on a real date change or the
    /// app returning from the background, neither of which happens when a
    /// `.fullScreenCover` is presented and dismissed in the same session.
    var reloadToken: Int = 0
    var onExpand: () -> Void
    var onOpenNotes: () -> Void

    @State private var showShareSheet = false
    @State private var shareText: String = ""
    /// Drives the Related Notes link flow from this card's header pencil
    /// icon — see this file's header comment. Passed down to
    /// DayflowDailyNoteEditor as `externalActiveLinkFlow`, which still owns
    /// the actual sheet presentation and persistence.
    @State private var activeLinkFlow: DayflowLinkKind? = nil

    /// Session 38 addendum 7 — same file NoteStore/DayflowDailyNoteEditor
    /// use internally for this day's note, computed here too since the pin
    /// toggle lives in this view's own header, not inside the editor.
    private var relativePath: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return "Calendar/\(f.string(from: date)).md"
    }
    private var isFlagged: Bool { DayflowFlagStore.shared.isFlagged(relativePath) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            DayflowDailyNoteEditor(
                date: date,
                reloadToken: reloadToken,
                externalActiveLinkFlow: $activeLinkFlow,
                showInlineLinkAffordance: false
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.top, 8)
        }
        .padding(14)
        .frame(maxHeight: .infinity)
        // Skin locked 2026-07-21 (Session 29) — was a 16pt-radius background +
        // quaternary-stroke border; see DayflowSkin.swift's `dayflowCard()`.
        .dayflowCard()
        .sheet(isPresented: $showShareSheet) {
            DayflowActivityView(activityItems: [shareText])
        }
    }

    // MARK: Share
    //
    // Reads NoteStore directly rather than the plain-file path
    // `DayflowDailyNoteEditor` uses internally, but the same backend and the
    // same header-strip helper (widened from `private` this session so it
    // can be reused here — see that file's comment on `stripDateHeader`).
    // Silently does nothing if the note is empty — no point presenting a
    // share sheet with nothing in it, and this matches how the button
    // behaved before (tapping it produced no visible UI either way).
    //
    // **Session 38 addition.** Now that a Daily Note can carry its own
    // "## Related Notes" table (same feature Project Note got Session 37),
    // also splits that section out via the shared
    // `DayflowRelatedNotesEngine.split(_:)` and shares only the prose half —
    // otherwise the raw `| [[Name]] | Description |` markdown would show up
    // verbatim in whatever the share sheet hands off to (Messages, Mail,
    // etc.), which is exactly the "ugly unrendered text" problem Session 37
    // already fixed for the in-app editor view.

    private func shareNote() {
        let raw = (try? NoteStore.shared.readDailyNote(date: date)) ?? ""
        let headerStripped = DayflowDailyNoteEditor.stripDateHeader(raw)
        let (prose, _) = DayflowRelatedNotesEngine.split(headerStripped)
        let stripped = prose.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripped.isEmpty else { return }
        let f = DateFormatter()
        f.dateFormat = "EEEE, d MMMM"
        shareText = "# \(f.string(from: date))\n\n\(stripped)"
        showShareSheet = true
    }

    private var header: some View {
        HStack(spacing: 8) {
            // Skin locked 2026-07-21 (Session 29) — was
            // Label("Daily Note", systemImage: "pencil"), which drew the
            // stock SF Symbol pencil. David wanted a specific pencil silhouette
            // (slim straight-edged body + eraser line + separate writing line
            // to the left of the tip) with no real SF Symbol match, so this is
            // now a custom HStack combining DayflowPencilIcon with the title
            // text, both under the shared serif font. See DayflowSkin.swift.
            // Session 38 addendum — was a plain, non-interactive HStack; now
            // the Related Notes link-flow entry point (see this file's
            // header comment). Explicit foregroundStyle on the label so
            // Menu's default accent-blue label tinting doesn't leak in —
            // same bug class already fixed elsewhere in this app (e.g.
            // ContentView's top-bar Menu, Session 30).
            Menu {
                dayflowLinkKindMenuItems { kind in activeLinkFlow = kind }
                // Session 38 addendum 7 — Share moved in here from its own
                // icon (see this file's header comment) to free that slot
                // for a dedicated Pin toggle. A Divider separates the five
                // "link a note" actions above from this unrelated one.
                Divider()
                Button(action: shareNote) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            } label: {
                HStack(spacing: 6) {
                    DayflowPencilIcon()
                        .stroke(Color.primary, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                        .frame(width: 22, height: 17.6)
                    Text("Daily Note")
                }
                .font(.dayflowSerif(14.5, weight: .semibold))
                .foregroundStyle(Color.primary)
            }
            Spacer()
            // Session 38 addendum 7 — was the Share icon; Share moved into
            // the pencil Menu above (see this file's header comment) so this
            // slot could become the Pin toggle instead. Pin needs to be its
            // own always-visible button (not a Menu item) so its filled/
            // outline state is visible at a glance, same as Project Note's
            // own pin button.
            iconButton(accessibilityLabel: isFlagged ? "Unpin this day" : "Pin this day", action: {
                DayflowFlagStore.shared.toggleFlag(relativePath)
            }) {
                Image(systemName: isFlagged ? "pin.fill" : "pin")
                    .font(.system(size: 12))
                    .foregroundStyle(isFlagged ? Color.dayflowInk : .secondary)
            }
            // Skin locked 2026-07-21 (Session 29) — was
            // arrow.up.left.and.arrow.down.right, which draws arrowheads, not
            // the corner-bracket look David picked in the icon-review round.
            // No real SF Symbol match, so this is a custom shape. See
            // DayflowSkin.swift.
            iconButton(accessibilityLabel: "Expand to full page", action: onExpand) {
                DayflowExpandIcon()
                    .stroke(Color.secondary, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                    .frame(width: 13, height: 13)
            }
            // Skin locked 2026-07-21 (Session 29) — was
            // doc.text.magnifyingglass, flagged in this file's own prior
            // comment as visually unconfirmed; David didn't like it once
            // rendered in the icon-review round and picked option "D" — a
            // custom list+magnifying-glass composite reasoned against what
            // this button actually does (search notes, add a project
            // note/place/person). No real SF Symbol match. See
            // DayflowSkin.swift.
            iconButton(accessibilityLabel: "Notes & Projects", action: onOpenNotes) {
                DayflowNotesProjectsIcon()
                    .stroke(Color.secondary, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .frame(width: 13, height: 13)
            }
        }
    }

    // Session 38 addendum 7 — the plain SF-Symbol-string overload that used
    // to wrap this one (kept originally for Share's call site) was removed;
    // Share moved into the pencil Menu above and Pin uses the generic
    // overload directly (its filled/outline state needs a conditional
    // Image, not a fixed symbol name). Expand and Notes & Projects already
    // used this generic overload for the same reason (no matching SF Symbol).
    //
    // Skin locked 2026-07-21 (Session 29) — generic overload added so Expand
    // and Notes & Projects can supply a custom Shape-based icon (no matching
    // SF Symbol) while sharing the same circular button chrome as Share's
    // SF-Symbol icon.
    private func iconButton<Icon: View>(accessibilityLabel: String,
                                         action: @escaping () -> Void,
                                         @ViewBuilder icon: () -> Icon) -> some View {
        Button(action: action) {
            icon()
                .frame(width: 26, height: 26)
                .background(.quaternary.opacity(0.6), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

// MARK: - DayflowActivityView
//
// Thin UIKit bridge for the system share sheet. Not SwiftUI's `ShareLink`
// deliberately — `ShareLink`'s `item:` is whatever this view's `body` last
// rendered, but the note text lives in a sibling view
// (`DayflowDailyNoteEditor`) and is only read fresh at the moment Share is
// tapped (see `shareNote()` above); a plain `Button` + `.sheet(isPresented:)`
// driving a `UIActivityViewController` guarantees the share sheet always
// gets exactly what was read at tap time, not a value from some earlier
// render pass. Added 2026-07-22 (Session 36).

private struct DayflowActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
