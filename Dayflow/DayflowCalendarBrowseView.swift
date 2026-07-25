import SwiftUI

// MARK: - DayflowCalendarBrowseView
//
// Browse: Calendar — originally one of the destinations off the top-bar
// calendar icon menu (Dayflow-Design-Plan.md "Top bar & navigation"; build
// order step 5). Ground truth: Dayflow-Mockup.html's #calendarScrim — "a real
// month grid, tap any date to jump the main Agenda there." Built on
// DayflowMonthGridView.swift, the same renderer DayflowWhenPickerSheet.swift
// uses, per the mockup's explicit call-out that this view "reuses the same
// renderer as the task/event date picker."
//
// **Entry points narrowed to two, 2026-07-21 (Session 24).** This used to
// have three ways in: the top-bar Menu's "Calendar" entry, the main screen's
// date-headline tap (Session 21), and DayflowNoteFullPageView.swift's own
// calendar icon. David's call after walking the navigation fresh: Calendar
// browsing should have exactly one door from the main screen, not two/three
// — the top-bar Menu's "Calendar" entry (and Browse: Upcoming's matching
// "switch to Calendar" shortcut) were both removed for the same reason. See
// DayflowModels.swift's `DayflowBrowseDestination` header comment for the
// full reasoning. `onSwitchToUpcoming` (a toggle button that used to render
// in this view's own header when reached via the menu) was removed along
// with it — every remaining caller only ever passed `nil` for it, so keeping
// that optionality around after the menu entry was gone would've just been
// unreachable code pretending to still be a real choice.
//
// `onSelect` is the caller's job to interpret and this view always dismisses
// itself right after calling it: ContentView.swift sets its own
// `selectedDate` (closing the whole browse cover, landing back on the main
// Agenda); DayflowNoteFullPageView.swift sets its own `selectedDate` instead
// (closing just this Calendar cover, staying on the full-page note) — per the
// design plan's "Picking a date there returns you to the full-page note view,
// not the main Agenda screen."

struct DayflowCalendarBrowseView: View {
    var onSelect: (Date) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var monthCursor: Date = Date()
    /// Loaded once on appear — see `loadDatesWithNotes()` below. Not
    /// reloaded per month navigated to; `NoteStore.listFiles(in:)` already
    /// returns every Calendar note in the vault regardless of month, so one
    /// load covers wherever this session's browsing goes, matching the
    /// "fetch once, no periodic refresh" freshness already used for
    /// NotionService.people/places elsewhere in Dayflow.
    @State private var datesWithNotes: Set<Date> = []

    /// Pinned days for the red-dot indicator — added 2026-07-23 (Session 38
    /// addendum 8), per David's ask on this exact screen ("use the calendar
    /// ... to denote the pinned days"). Computed live from
    /// DayflowFlagStore.shared (an @Observable singleton, same one the Daily
    /// Note card/full-page pin toggle and Project Note pin both write to)
    /// rather than cached in @State like datesWithNotes above — pin/unpin can
    /// happen anywhere in the app and this should reflect it immediately the
    /// next time this view's body recomputes, no separate reload call needed.
    /// Parsing mirrors loadDatesWithNotes() below exactly, just run against
    /// flaggedAt's keys instead of a NoteStore directory listing, and with an
    /// explicit "Calendar/" prefix check since DayflowFlagStore's paths cover
    /// Project Notes too (a Project Note's flagged path lives under a
    /// different folder, not "Calendar/", so it's naturally excluded here).
    private var pinnedDates: Set<Date> {
        let calendarPrefix = "Calendar/"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2
        let dates = DayflowFlagStore.shared.flaggedAt.keys.compactMap { path -> Date? in
            guard path.hasPrefix(calendarPrefix), path.hasSuffix(".md") else { return nil }
            let stem = String(path.dropFirst(calendarPrefix.count).dropLast(3))
            guard let parsed = formatter.date(from: stem) else { return nil }
            return cal.startOfDay(for: parsed)
        }
        return Set(dates)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                DayflowMonthGridView(monthCursor: $monthCursor, datesWithNotes: datesWithNotes, pinnedDates: pinnedDates) { picked in
                    onSelect(picked)
                    dismiss()
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)

                Text("Tap any date to jump the main Agenda there — that day's tasks + events, same layout as today's screen.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(20)
            }
        }
        .task { await loadDatesWithNotes() }
    }

    /// Builds the note-dot data — Session 24, 2026-07-21. `NoteStore.
    /// listFiles(in:)` returns Calendar note filenames as plain
    /// "YYYY-MM-DD.md" strings (the same naming convention every other
    /// date-parsing call site in this codebase already assumes, e.g.
    /// DayflowBacklinksView.openMention's Calendar-prefix case) — parsed here
    /// into start-of-day `Date`s so `DayflowMonthGridView.hasNote(_:)` can do
    /// a plain `Set` lookup per cell instead of any string comparison.
    private func loadDatesWithNotes() async {
        guard let filenames = try? NoteStore.shared.listFiles(in: "Calendar") else { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2
        let dates = filenames.compactMap { filename -> Date? in
            let stem = filename.hasSuffix(".md") ? String(filename.dropLast(3)) : filename
            guard let parsed = formatter.date(from: stem) else { return nil }
            return cal.startOfDay(for: parsed)
        }
        datesWithNotes = Set(dates)
    }

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)

            Spacer()
            // Skin fix 2026-07-22 (Session 32) — was .custom("Georgia", ...),
            // same fix applied across the rest of the skin. Font only this
            // pass — background/pill consistency not yet done on this
            // screen, see Dayflow-HANDOFF.md Session 32. See DayflowSkin.swift.
            Text("Calendar")
                .font(.dayflowSerif(20))
            Spacer()

            // Was a conditional "switch to Upcoming" button here, shown only
            // when reached via the top-bar Menu — removed 2026-07-21
            // (Session 24) along with that Menu entry itself; see this file's
            // header comment. Fixed empty placeholder now, same balancing
            // convention used everywhere else in this file's sibling headers.
            Color.clear.frame(width: 32, height: 32)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }
}
