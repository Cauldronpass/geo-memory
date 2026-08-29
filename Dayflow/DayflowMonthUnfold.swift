import SwiftUI
import UIKit

// MARK: - DayflowMonthUnfold
//
// The month, unfolding IN PLACE under the Today masthead (Session 78 —
// canvas frame "Today · month unfolded", David: "yes this is great lets
// build it"). Replaces the date-headline door's DayflowCalendarBrowseView
// cover: that screen was pre-Editorial, slid up from the bottom and cost a
// back arrow; this is the composer's month-grid language living inside the
// page. Tap a day = fold + go there (the caller sets selectedDate); tap the
// headline again = fold without going anywhere. TO DO and THE DAY slide
// down but stay visible the whole time.
//
// Dots carried over from the old screen, same sources: a faint dot for a
// day with a Calendar note (NoteStore listing, loaded once per appearance —
// the old screen's freshness rule), an accent dot for a pinned day
// (DayflowFlagStore, computed live). The selected day wears the solid
// accent square; today, when not selected, wears the accent numeral.

struct DayflowMonthUnfold: View {
    var selectedDate: Date
    var onPick: (Date) -> Void
    /// The italic hint line — the masthead unfold's default; the edit
    /// sheet's date pick passes its own (Session 78 round 3).
    var hint: String = "tap a day to go there"

    @State private var cursor: Date = Date()
    @State private var datesWithNotes: Set<Date> = []

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 2 // Monday, matching every grid in the app
        return c
    }

    /// Pinned days for the accent dot — DayflowCalendarBrowseView's exact
    /// parse (Calendar/ prefix, yyyy-MM-dd stems), computed live.
    private var pinnedDates: Set<Date> {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        let cal = self.cal
        let dates = DayflowFlagStore.shared.flaggedAt.keys.compactMap { path -> Date? in
            guard path.hasPrefix("Calendar/"), path.hasSuffix(".md") else { return nil }
            let stem = String(path.dropFirst("Calendar/".count).dropLast(3))
            guard let parsed = formatter.date(from: stem) else { return nil }
            return cal.startOfDay(for: parsed)
        }
        return Set(dates)
    }

    /// 42 cells, Monday-first, covering the cursor's month.
    private var cells: [Date] {
        let cal = self.cal
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: cursor)) ?? cursor
        let weekday = cal.component(.weekday, from: monthStart)
        // Days back to Monday: weekday is 1=Sun...7=Sat; Monday-first offset.
        let back = (weekday - cal.firstWeekday + 7) % 7
        let gridStart = cal.date(byAdding: .day, value: -back, to: monthStart) ?? monthStart
        return (0..<42).compactMap { cal.date(byAdding: .day, value: $0, to: gridStart) }
    }

    private var monthLabel: String {
        let f = DateFormatter(); f.dateFormat = "MMMM yyyy"
        return f.string(from: cursor).uppercased()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                pager("chevron.left", by: -1)
                Spacer()
                Text(monthLabel)
                    .font(.system(size: 11, weight: .bold))
                    .tracking(2)
                    .foregroundStyle(Color.dayflowInk)
                Spacer()
                pager("chevron.right", by: 1)
            }
            HStack(spacing: 0) {
                ForEach(["M", "T", "W", "T", "F", "S", "S"].indices, id: \.self) { i in
                    Text(["M", "T", "W", "T", "F", "S", "S"][i])
                        .font(.system(size: 9.5, weight: .medium))
                        .tracking(0.8)
                        .foregroundStyle(Color.dayflowFaint)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 2)
            ForEach(0..<6, id: \.self) { week in
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { col in
                        dayCell(cells[week * 7 + col])
                    }
                }
            }
            HStack {
                HStack(spacing: 10) {
                    HStack(spacing: 4) {
                        Circle().fill(Color.dayflowFaint).frame(width: 3, height: 3)
                        Text("note")
                    }
                    HStack(spacing: 4) {
                        Circle().fill(Color.dayflowAccent).frame(width: 4, height: 4)
                        Text("pinned")
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(Color.dayflowFaint)
                Spacer()
                Text(hint)
                    .font(.system(size: 10.5))
                    .italic()
                    .foregroundStyle(Color.dayflowFaint)
            }
            .padding(.top, 4)
            Rectangle().fill(Color.dayflowInk).frame(height: 1)
                .padding(.top, 4)
        }
        .padding(.top, 8)
        .onAppear {
            cursor = selectedDate
            Task { await loadDatesWithNotes() }
        }
    }

    private func pager(_ icon: String, by months: Int) -> some View {
        Button {
            cursor = cal.date(byAdding: .month, value: months, to: cursor) ?? cursor
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.dayflowMuted)
                .frame(width: 34, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func dayCell(_ day: Date) -> some View {
        let cal = self.cal
        let inMonth = cal.isDate(day, equalTo: cursor, toGranularity: .month)
        let isSelected = cal.isDate(day, inSameDayAs: selectedDate)
        let isToday = cal.isDateInToday(day)
        let start = cal.startOfDay(for: day)
        let hasNote = datesWithNotes.contains(start)
        let isPinned = pinnedDates.contains(start)
        return Button {
            UISelectionFeedbackGenerator().selectionChanged()
            onPick(start)
        } label: {
            VStack(spacing: 2) {
                Text("\(cal.component(.day, from: day))")
                    .font(.system(size: 13.5, weight: isSelected ? .bold : .regular))
                    .foregroundStyle(
                        isSelected ? Color.dayflowPaper
                        : isToday ? Color.dayflowAccent
                        : inMonth ? Color.dayflowInk
                        : Color.dayflowHairline)
                    .frame(width: 30, height: 30)
                    .background(isSelected ? Color.dayflowAccent : Color.clear)
                if inMonth && isPinned {
                    Circle().fill(Color.dayflowAccent).frame(width: 4, height: 4)
                } else if inMonth && hasNote && !isSelected {
                    Circle().fill(Color.dayflowFaint).frame(width: 3, height: 3)
                } else {
                    Color.clear.frame(width: 4, height: 4)
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The old Calendar screen's note-dot load, verbatim reasoning: one
    /// listing covers every month this unfold will page to.
    private func loadDatesWithNotes() async {
        guard let filenames = try? NoteStore.shared.listFiles(in: "Calendar") else { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        let cal = self.cal
        let dates = filenames.compactMap { filename -> Date? in
            let stem = filename.hasSuffix(".md") ? String(filename.dropLast(3)) : filename
            guard let parsed = formatter.date(from: stem) else { return nil }
            return cal.startOfDay(for: parsed)
        }
        datesWithNotes = Set(dates)
    }
}
