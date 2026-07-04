// TraceMacCalendarPanel.swift
// Calendar panel for the Daily section — 240px right column.
// Mac-only — do not add to iOS, Widget, or Share Extension targets.
//
// - Month header with prev/next navigation. Month name taps → opens Horizons month note.
// - 7-column grid (Mon–Sun). Week-number column on left. Week numbers tap → Horizons week note.
// - Today: filled orange circle. Selected date: lighter orange. Dates with entries: small dot below number.
// - Tapping a date sets selectedDateFile and opens/creates the Calendar note.

import SwiftUI

// MARK: - Calendar panel

struct TraceMacCalendarPanel: View {

    /// Binding into TraceMacDailyView — filename like "2026-07-03.md"
    @Binding var selectedDateFile: String?

    /// Set of date strings ("2026-07-03") that have existing notes.
    var datesWithEntries: Set<String>

    /// Called with a relative iCloud path when user taps a week or month link.
    var onOpenHorizonsNote: (String) -> Void

    @State private var displayMonth: Date = {
        // Start on current month
        let cal = Calendar.current
        return cal.date(from: cal.dateComponents([.year, .month], from: Date())) ?? Date()
    }()

    private var cal: Calendar { Calendar.current }

    // MARK: - Derived values

    private var monthTitle: String {
        let df = DateFormatter()
        df.dateFormat = "MMMM yyyy"
        return df.string(from: displayMonth)
    }

    private var monthNotePath: String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM"
        return "Notes/Horizons/\(df.string(from: displayMonth)).md"
    }

    /// All dates to display for the grid (including leading/trailing blanks as nil).
    private var gridDates: [[Date?]] {
        // First day of the display month
        let firstOfMonth = cal.date(from: cal.dateComponents([.year, .month], from: displayMonth))!
        let lastOfMonth  = cal.date(byAdding: DateComponents(month: 1, day: -1), to: firstOfMonth)!

        // Weekday of first day (adjusted to Mon=0 … Sun=6)
        let rawWeekday = cal.component(.weekday, from: firstOfMonth) // 1=Sun…7=Sat
        let offset     = (rawWeekday + 5) % 7  // Mon-based offset

        // Total cells in the grid (multiples of 7)
        let totalDays = cal.component(.day, from: lastOfMonth)
        let totalCells = ((offset + totalDays + 6) / 7) * 7

        var dates: [Date?] = Array(repeating: nil, count: offset)
        var current = firstOfMonth
        while dates.count < offset + totalDays {
            dates.append(current)
            current = cal.date(byAdding: .day, value: 1, to: current)!
        }
        // Pad to fill last row
        while dates.count < totalCells {
            dates.append(nil)
        }

        // Split into weeks
        return stride(from: 0, to: dates.count, by: 7).map { Array(dates[$0..<min($0+7, dates.count)]) }
    }

    private var selectedDate: Date? {
        guard let file = selectedDateFile else { return nil }
        let dateStr = file.replacingOccurrences(of: ".md", with: "")
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        return df.date(from: dateStr)
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Month header
            monthHeader
            Divider()

            // Day-of-week labels
            dayOfWeekRow
            Divider()

            // Calendar grid
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(gridDates.enumerated()), id: \.offset) { rowIndex, week in
                        weekRow(week: week)
                        if rowIndex < gridDates.count - 1 {
                            Divider().opacity(0.4)
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Month header

    private var monthHeader: some View {
        HStack(spacing: 6) {
            Button {
                displayMonth = cal.date(byAdding: .month, value: -1, to: displayMonth) ?? displayMonth
            } label: {
                Image(systemName: "chevron.left")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .help("Previous month")

            Spacer()

            // Month name — tappable to open Horizons month note
            Button {
                onOpenHorizonsNote(monthNotePath)
            } label: {
                Text(monthTitle)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .help("Open \(monthTitle) in Horizons")

            Spacer()

            Button {
                displayMonth = cal.date(byAdding: .month, value: 1, to: displayMonth) ?? displayMonth
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .help("Next month")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // MARK: - Day-of-week row (Mon–Sun)

    private let weekdayLabels = ["M", "T", "W", "T", "F", "S", "S"]

    private var dayOfWeekRow: some View {
        HStack(spacing: 0) {
            // Week-number column label
            Text("W")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 24)

            ForEach(weekdayLabels.indices, id: \.self) { i in
                let isSaturday = i == 5
                let isSunday   = i == 6
                Text(weekdayLabels[i])
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundStyle(isSaturday || isSunday ? .tertiary : .secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 5)
    }

    // MARK: - Week row

    private func weekRow(week: [Date?]) -> some View {
        HStack(spacing: 0) {
            // Week number — tappable to open Horizons week note
            weekNumberButton(for: week)

            ForEach(0..<7, id: \.self) { i in
                dateCell(date: week[i])
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }

    private func weekNumberButton(for week: [Date?]) -> some View {
        let firstDate = week.compactMap { $0 }.first
        let weekNum   = firstDate.map { cal.component(.weekOfYear, from: $0) }
        let year      = firstDate.map { cal.component(.yearForWeekOfYear, from: $0) }

        return Group {
            if let wn = weekNum, let yr = year {
                Button {
                    let path = "Notes/Horizons/\(String(format: "%d-W%02d", yr, wn)).md"
                    onOpenHorizonsNote(path)
                } label: {
                    Text("\(wn)")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color.traceOrange)
                        .frame(width: 24)
                }
                .buttonStyle(.plain)
                .help("Open Week \(wn) in Horizons")
            } else {
                Color.clear.frame(width: 24)
            }
        }
    }

    // MARK: - Date cell

    private func dateCell(date: Date?) -> some View {
        Group {
            if let date {
                let dateStr   = dateString(date)
                let isToday   = cal.isDateInToday(date)
                let isInMonth = cal.isDate(date, equalTo: displayMonth, toGranularity: .month)
                let isSelected = selectedDate.map { cal.isDate($0, inSameDayAs: date) } ?? false
                let hasEntry   = datesWithEntries.contains(dateStr)

                Button {
                    tappedDate(date)
                } label: {
                    VStack(spacing: 2) {
                        ZStack {
                            // Background circle
                            if isToday {
                                Circle()
                                    .fill(Color.traceOrange)
                                    .frame(width: 26, height: 26)
                            } else if isSelected {
                                Circle()
                                    .fill(Color.traceOrange.opacity(0.25))
                                    .frame(width: 26, height: 26)
                            }
                            Text("\(cal.component(.day, from: date))")
                                .font(.system(size: 12, weight: isToday ? .semibold : .regular))
                                .foregroundStyle(
                                    isToday    ? .white :
                                    !isInMonth ? Color.secondary.opacity(0.4) :
                                                 .primary
                                )
                        }
                        // Entry dot
                        Circle()
                            .fill(hasEntry ? Color.traceOrange.opacity(0.7) : .clear)
                            .frame(width: 4, height: 4)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Color.clear
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Actions

    private func tappedDate(_ date: Date) {
        let filename = "\(dateString(date)).md"
        selectedDateFile = filename
        // Jump calendar to that month if tapping a leading/trailing day
        let monthOfTapped = cal.date(from: cal.dateComponents([.year, .month], from: date))!
        let currentMonth  = cal.date(from: cal.dateComponents([.year, .month], from: displayMonth))!
        if monthOfTapped != currentMonth {
            displayMonth = monthOfTapped
        }
    }

    // MARK: - Helpers

    private func dateString(_ date: Date) -> String {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        return df.string(from: date)
    }
}
