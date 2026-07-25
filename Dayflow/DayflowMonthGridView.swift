import SwiftUI

// MARK: - DayflowMonthGridView
//
// Shared month-grid renderer, added 2026-07-20 for Browse views (build order
// step 5). Dayflow-Mockup.html's Calendar browse view explicitly says it
// "reuses the same renderer as the task/event date picker" — factored out of
// DayflowWhenPickerSheet.swift's own month grid (build order step 2,
// Dayflow-HANDOFF.md Session 3) rather than writing a second, slightly
// different grid implementation for DayflowCalendarBrowseView.swift.
// DayflowWhenPickerSheet.swift switched to this component in the same pass —
// same visual behavior there, no functional change to that file.
//
// Month/weekday math: Gregorian, Monday-first week, matching
// DayflowWhenPickerSheet's existing convention exactly (copied verbatim, not
// re-derived).
//
// **Note-dot indicator added 2026-07-21 (Session 24).** A small dot renders
// under the day number for any date present in `datesWithNotes` — the
// long-parked "dot/highlight on Calendar days with content" idea, finally
// built. David's calls, confirmed before building: (1) Browse: Calendar
// only, not the task/event date picker (`DayflowWhenPickerSheet`) — that
// picker is about choosing a future date for something new, not reviewing
// what's already written, so dots there would just be noise; (2) style —
// walked a mockup first (a 32pt-vs-40pt cell comparison, since a dot needs
// room under the number that the original tight 32pt cell didn't have) and
// he picked the plain small-dot treatment over a ring or a background tint.
// `datesWithNotes` defaults to empty, so `DayflowWhenPickerSheet` needed zero
// changes to keep showing no dots — it just never populates the set. Cell
// height moved from 32pt to 40pt for both callers (this component is shared,
// and a uniform cell size across both is simpler than branching the layout
// on whether dots are enabled) — David saw and approved this exact size
// change in the mockup before committing.

struct DayflowMonthGridView: View {
    @Binding var monthCursor: Date
    /// Optional — highlights one specific date (filled blue) in addition to
    /// today's date (outlined). Neither DayflowWhenPickerSheet nor
    /// DayflowCalendarBrowseView currently pass this (both are "jump to a
    /// date," not "here's the currently active date"), but the hook is here
    /// since it's a one-line addition and an obvious thing a future caller
    /// might want.
    var selectedDate: Date? = nil
    /// Start-of-day dates that should show the small "has a note" dot. Empty
    /// (default) renders no dots at all — see this file's header comment.
    var datesWithNotes: Set<Date> = []
    /// Start-of-day dates that are pinned (DayflowFlagStore) — added
    /// 2026-07-23 (Session 38 addendum 8). Empty (default) renders every dot
    /// grey, same as before this existed, so DayflowWhenPickerSheet and the
    /// Related Notes Daily Note picker (neither passes this) need zero
    /// changes. Only DayflowCalendarBrowseView passes real data, per David's
    /// ask to see pinned days at a glance on that screen specifically.
    var pinnedDates: Set<Date> = []
    var onSelect: (Date) -> Void

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 2 // Monday
        return c
    }

    private var monthLabel: String {
        let f = DateFormatter(); f.dateFormat = "MMMM yyyy"
        return f.string(from: monthCursor)
    }

    /// nil entries are leading blank cells before day 1.
    private var monthCells: [Int?] {
        let comps = calendar.dateComponents([.year, .month], from: monthCursor)
        guard let firstOfMonth = calendar.date(from: DateComponents(year: comps.year, month: comps.month, day: 1)) else { return [] }
        let weekday = calendar.component(.weekday, from: firstOfMonth) // 1=Sun...7=Sat
        let leading = (weekday + 5) % 7 // convert to Mon-first offset
        let daysInMonth = calendar.range(of: .day, in: .month, for: firstOfMonth)?.count ?? 30
        var cells: [Int?] = Array(repeating: nil, count: leading)
        cells.append(contentsOf: (1...daysInMonth).map { $0 })
        return cells
    }

    private func date(forDay day: Int) -> Date? {
        let comps = calendar.dateComponents([.year, .month], from: monthCursor)
        return calendar.date(from: DateComponents(year: comps.year, month: comps.month, day: day))
    }

    private func isToday(_ day: Int) -> Bool {
        guard let d = date(forDay: day) else { return false }
        return calendar.isDateInToday(d)
    }

    private func isSelected(_ day: Int) -> Bool {
        guard let selectedDate, let d = date(forDay: day) else { return false }
        return calendar.isDate(d, inSameDayAs: selectedDate)
    }

    private func hasNote(_ day: Int) -> Bool {
        guard let d = date(forDay: day) else { return false }
        return datesWithNotes.contains(calendar.startOfDay(for: d))
    }

    private func isPinned(_ day: Int) -> Bool {
        guard let d = date(forDay: day) else { return false }
        return pinnedDates.contains(calendar.startOfDay(for: d))
    }

    var body: some View {
        VStack(spacing: 12) {
            monthNav
            weekdayHeader
            monthGrid
        }
    }

    private var monthNav: some View {
        HStack {
            Button { monthCursor = calendar.date(byAdding: .month, value: -1, to: monthCursor) ?? monthCursor } label: {
                Image(systemName: "chevron.left")
            }
            Spacer()
            Text(monthLabel).font(.subheadline.weight(.semibold))
            Spacer()
            Button { monthCursor = calendar.date(byAdding: .month, value: 1, to: monthCursor) ?? monthCursor } label: {
                Image(systemName: "chevron.right")
            }
        }
    }

    private var weekdayHeader: some View {
        HStack {
            ForEach(["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"], id: \.self) { d in
                Text(d)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var monthGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 8) {
            ForEach(Array(monthCells.enumerated()), id: \.offset) { _, cell in
                if let day = cell {
                    Button {
                        if let d = date(forDay: day) { onSelect(d) }
                    } label: {
                        VStack(spacing: 3) {
                            Text("\(day)")
                                .font(isToday(day) ? .body.weight(.bold) : .body)
                                .foregroundStyle(isSelected(day) ? .white : (isToday(day) ? .blue : .primary))
                                .frame(width: 30, height: 30)
                                .background(isSelected(day) ? Color.blue : Color.clear, in: Circle())
                            Circle()
                                .fill(isPinned(day) ? Color.red : Color.secondary)
                                .frame(width: 5, height: 5)
                                .opacity(hasNote(day) ? 1 : 0)
                        }
                        .frame(maxWidth: .infinity, minHeight: 40)
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear.frame(maxWidth: .infinity, minHeight: 40)
                }
            }
        }
    }
}
