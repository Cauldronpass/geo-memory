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

struct DayflowNoteFullPageView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedDate: Date
    @State private var showCalendar = false

    /// Only Today/Tomorrow render as pill buttons — see header comment above.
    private static let pageDays: [DayflowRelativeDay] = [.today, .tomorrow]

    private var dateHeadlineText: String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, d MMMM"
        return f.string(from: selectedDate)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Text(dateHeadlineText)
                .font(.custom("Georgia", size: 24).weight(.bold))
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 10)
            DayflowDailyNoteEditor(date: selectedDate)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .fullScreenCover(isPresented: $showCalendar) {
            // Calendar only — no switch-to-Upcoming icon here (onSwitchToUpcoming
            // left nil), matching the design plan's "Upcoming and Anytime
            // aren't relevant here." Picking a date sets selectedDate above and
            // DayflowCalendarBrowseView dismisses itself, landing back on this
            // full-page note view (never the main Agenda screen).
            DayflowCalendarBrowseView(onSelect: { picked in selectedDate = picked })
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)

            Spacer()
            dayPill
            Spacer()

            Button {
                showCalendar = true
            } label: {
                Image(systemName: "calendar")
                    .font(.system(size: 15))
                    .frame(width: 32, height: 32)
                    .background(.background, in: Circle())
                    .overlay(Circle().strokeBorder(.quaternary, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

    private var dayPill: some View {
        HStack(spacing: 2) {
            ForEach(Self.pageDays) { day in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { selectedDate = day.date() }
                } label: {
                    Text(day.label)
                        .font(.system(size: 13))
                        .foregroundStyle(isActive(day) ? .white : .secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(isActive(day) ? Color.blue : Color.clear, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(.quaternary.opacity(0.3), in: Capsule())
    }

    private func isActive(_ day: DayflowRelativeDay) -> Bool {
        Calendar.current.isDate(selectedDate, inSameDayAs: day.date())
    }
}
