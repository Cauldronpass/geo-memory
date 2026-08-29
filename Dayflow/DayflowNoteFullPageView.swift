import SwiftUI

// MARK: - DayflowNoteFullPageView
//
// Dayflow-Design-Plan.md "Daily Note section" full-page expand view. Ground
// truth: Dayflow-Mockup.html's #noteFullScrim — same note content as the
// main-view card, just without Agenda competing for space. Header mirrors
// the main topbar's layout (back arrow / day-pill / calendar icon) but:
//   - the day-pill here is Today/Tomorrow only, not Yesterday/Today/Tomorrow
//     (per the mockup's #noteFullDayPill — Yesterday wasn't requested in
//     this context; still an open question in Dayflow-Design-Plan.md
//     "Open questions" whether that's intentional or just unmentioned, not
//     re-decided here)
//   - the calendar icon opens *just* the month-grid Calendar view (via
//     DayflowCalendarBrowseView.swift, built for Browse views/step 5), not
//     the full Upcoming/Calendar/Anytime browse menu (Upcoming/Anytime
//     aren't relevant when you're only viewing one note)
//
// Presented as a full-screen cover from ContentView (mirrors the mockup's
// full-viewport scrim) rather than a sheet, since this is meant to feel like
// "its own full page," not a partial overlay.
//
// **Revised 2026-07-20, Browse views (build order step 5).** Was `@State
// private var selectedDay: DayflowRelativeDay`, clamped to Today whenever the
// initial value wasn't Today/Tomorrow. Changed to `selectedDate: Date` to
// match ContentView.swift's own refactor (same header comment there has the
// full reasoning) — the Calendar icon below now genuinely needs to be able to
// land on any date, not just Today/Tomorrow, and clamping a real Calendar
// pick back to Today would silently discard what was just selected. The
// Today/Tomorrow pill still only offers those two buttons, but now simply
// shows neither as active when `selectedDate` is some other day (e.g. this
// view was opened while ContentView was on Yesterday, or Calendar was used to
// jump elsewhere) — the note for that exact date still loads and displays
// correctly either way, since DayflowDailyNoteEditor has always been
// date-driven, not enum-driven. Deliberate interpretation, not a silent
// guess: previously, opening this view from ContentView's Yesterday pill
// silently reset to Today's note; now it correctly shows Yesterday's note
// instead. Flag if the old clamp-to-Today behavior was actually wanted.
//
// **`selectedDate` changed from a private `@State` (seeded once via
// `initialDate:`) to a `@Binding` straight to ContentView's own `selectedDate`
// — Session 18, 2026-07-20.** David reported Agenda and the Daily Note "not
// lining up": navigate to Tomorrow in here (Today/Tomorrow pill or the
// Calendar picker), dismiss back to the main screen, and Agenda + the Daily
// Note card were still showing whatever ContentView's `selectedDate` had been
// before this view ever opened — because that was a completely separate
// piece of state, one-way-seeded at open time and never reported back. Now
// this view shares the exact same `selectedDate` ContentView's Agenda section
// reads, so any navigation in here (or in ContentView, or in the Calendar
// browse view launched from either place) is immediately the one true "what
// date is Dayflow looking at" — no separate sync step needed, no stale state
// possible. (Separately, in the same session: a real data-loss bug existed in
// `MarkdownEditorView.swift` where typing after a date change could silently
// save into the *previous* date's file — fixed there, see that file's
// `updateUIView` header comment. That bug existed independently of this
// binding change and would have kept happening even with dates lined up.)
//
// **Date headline repurposed as the Related Notes entry point, 2026-07-23
// (Session 38 addendum 2).** The inline "Link a note" row this screen had
// (via DayflowRelatedNotesSection's own empty-state affordance) looked
// rough in practice once David tried it on-device — flagged directly as
// "formatting on the expanded note is not good." Rather than tune that row's
// styling, he asked for the same fix already applied to the home card
// (Session 38 addendum 1): move the entry point onto an existing, already-
// prominent piece of chrome instead of a dedicated row. There it was the
// header pencil icon; here it's this screen's own large date headline,
// which was previously inert text. Wrapped in the same `dayflowLinkKindMenu
// Items` Menu, and `DayflowDailyNoteEditor` is now told
// `showInlineLinkAffordance: false` here too, so the section stays fully
// hidden (same as the card, same as Project Note) until something's
// actually linked — no dedicated empty-state row anywhere in this app
// anymore, both hosts now trigger from existing chrome.
//
// **Pin added, 2026-07-23 (Session 38 addendum 7).** Companion to the home
// card's pin toggle (see DayflowDailyNoteSection.swift's own header comment
// for the full design discussion). This screen never had a Share button to
// fold anything into, so David asked for Pin as its own new icon instead,
// placed next to the existing calendar icon. Reuses `DayflowFlagStore.shared`
// exactly as the card and Project Note both do.

struct DayflowNoteFullPageView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedDate: Date
    /// Session 78, D162 — this screen now CROSSFADES: the cover presents
    /// with animations disabled (ContentView's side) and the content fades
    /// itself in, so the note reads as the card expanding rather than a
    /// screen sliding up from the bottom.
    @State private var appeared = false
    /// Drives the Related Notes link flow from the date headline below —
    /// see this file's header comment. Passed down to DayflowDailyNoteEditor
    /// as `externalActiveLinkFlow`, which still owns the actual sheet
    /// presentation and persistence.
    @State private var activeLinkFlow: DayflowLinkKind? = nil

    private var dateHeadlineText: String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, d MMMM"
        return f.string(from: selectedDate)
    }

    /// Session 38 addendum 7 — same file DayflowDailyNoteEditor/
    /// DayflowDailyNoteSection use for this day's note, computed here too
    /// since the pin toggle lives in this view's own header.
    private var relativePath: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return "Calendar/\(f.string(from: selectedDate)).md"
    }
    private var isFlagged: Bool { DayflowFlagStore.shared.isFlagged(relativePath) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            // Session 38 addendum 2 — was a plain Text, now the Related
            // Notes link-flow entry point (see this file's header comment).
            // Explicit foregroundStyle so Menu's default accent-blue label
            // tinting doesn't leak in — same bug class already fixed
            // elsewhere in this app (e.g. ContentView's top-bar Menu,
            // Session 30; DayflowDailyNoteSection's pencil icon, this same
            // session).
            // The date as an Editorial masthead (Session 78, D162) — and
            // INERT since D163: the same big serif date unfolds the month on
            // the main screen, so a menu springing from it here was two
            // identical elements doing unrelated things (David's catch). The
            // Related Notes flow lives on the header's link glyph now, the
            // pattern DayflowProjectNoteView already had.
            VStack(alignment: .leading, spacing: 0) {
                Rectangle().fill(Color.dayflowInk).frame(height: 3)
                Text(dateHeadlineText)
                    .font(.dayflowSerif(26, weight: .heavy))
                    .foregroundStyle(Color.dayflowInk)
                    .padding(.vertical, 8)
                Rectangle().fill(Color.dayflowInk).frame(height: 1)
            }
            .padding(.horizontal, 20)
            .padding(.top, 2)
            .padding(.bottom, 10)
            DayflowDailyNoteEditor(
                date: selectedDate,
                externalActiveLinkFlow: $activeLinkFlow,
                showInlineLinkAffordance: false
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Skin fix 2026-07-22 (Session 32) — same warm gradient as the home
        // screen. No NavigationStack here (plain VStack), so no risk of the
        // "background on the wrong view" bug Session 30 hit on ContentView.
        .dayflowSkinBackground()
        // Session 78, D162 — the Today/Tomorrow pill and the calendar icon
        // are GONE (duplicated the main screen's day strip and the month
        // unfold; the one-door rule, again), and with them this screen's
        // DayflowCalendarBrowseView cover — that file's last caller.
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.2)) { appeared = true }
        }
    }

    // MARK: Header

    private var header: some View {
        // Session 78, D162: kicker left, pin + DONE right. No back chevron
        // (the last one in daily use), no day pill, no calendar icon — the
        // main screen owns navigation; this screen owns writing.
        HStack(alignment: .center) {
            Text("DAY NOTE")
                .font(.system(size: 11, weight: .medium))
                .tracking(2.2)
                .foregroundStyle(Color.dayflowMuted)
            Spacer()
            Button {
                DayflowFlagStore.shared.toggleFlag(relativePath)
            } label: {
                Image(systemName: isFlagged ? "pin.fill" : "pin")
                    .font(.system(size: 14))
                    .foregroundStyle(isFlagged ? Color.dayflowAccent : Color.dayflowMuted)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isFlagged ? "Unpin this day" : "Pin this day")
            Menu {
                dayflowLinkKindMenuItems { kind in activeLinkFlow = kind }
            } label: {
                // Explicit ink — Menu's accent-blue label tinting, the
                // Session 30 bug class.
                Image(systemName: "link.badge.plus")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.dayflowMuted)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Link a note to this day")
            Button { fadeOut() } label: {
                Text("Done")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.dayflowInk)
                    .frame(height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 8)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
    }

    /// The crossfade out: content fades, then the cover is dropped with
    /// animations disabled so no slide sneaks in behind the fade.
    private func fadeOut() {
        withAnimation(.easeInOut(duration: 0.16)) { appeared = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.17) {
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { dismiss() }
        }
    }
}
