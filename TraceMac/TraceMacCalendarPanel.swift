// TraceMacCalendarPanel.swift
// Fixed-width monthly calendar panel for the Daily note right column.
// Mac-only — do not add to iOS, Widget, or Share Extension targets.

import SwiftUI

// MARK: - Calendar panel

struct TraceMacCalendarPanel: View {
    @Binding var selectedDateFile: String?
    let datesWithEntries: Set<String>        // "YYYY-MM-DD" strings
    let onOpenHorizonsNote: (String) -> Void // bare filename within Notes/Horizons, e.g. "2026-W27.md"

    @State private var displayMonth: Date = {
        let cal = Calendar.current
        return cal.date(from: cal.dateComponents([.year, .month], from: Date())) ?? Date()
    }()

    private let cal = Calendar.current
    private let fmt = makeDayFmt()

    private var selectedDateStr: String? {
        selectedDateFile?.replacingOccurrences(of: ".md", with: "")
    }

    // MARK: Month grid — rows of 7 optional Dates (nil = padding cell)

    private var monthGrid: [[Date?]] {
        guard let range    = cal.range(of: .day, in: .month, for: displayMonth),
              let firstDay = cal.date(from: cal.dateComponents([.year, .month], from: displayMonth))
        else { return [] }

        let firstWeekday = cal.component(.weekday, from: firstDay)
        let leadingNils  = (firstWeekday + 5) % 7   // Mon=0, Sun=6

        var cells: [Date?] = Array(repeating: nil, count: leadingNils)
        for d in range {
            cells.append(cal.date(byAdding: .day, value: d - 1, to: firstDay))
        }
        while cells.count % 7 != 0 { cells.append(nil) }
        return stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<($0 + 7)]) }
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            navHeader
            Divider()
            dowRow
            gridRows
            Spacer(minLength: 0)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onChange(of: selectedDateFile) { _, newFile in
            guard let f = newFile,
                  let d = fmt.date(from: f.replacingOccurrences(of: ".md", with: "")) else { return }
            let dm = cal.date(from: cal.dateComponents([.year, .month], from: d)) ?? d
            if !cal.isDate(dm, equalTo: displayMonth, toGranularity: .month) {
                displayMonth = dm
            }
        }
    }

    // MARK: Nav header

    private var navHeader: some View {
        HStack(spacing: 0) {
            Button { step(-1) } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            Button { openMonth() } label: {
                Text(displayMonth, format: .dateTime.month(.wide).year())
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            Button { step(1) } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
    }

    // MARK: Day-of-week header row

    // Indexed tuples avoid ForEach keying issues with duplicate letters (T, S appear twice).
    private let dowLabels = [(0,"M"),(1,"T"),(2,"W"),(3,"T"),(4,"F"),(5,"S"),(6,"S")]

    private var dowRow: some View {
        HStack(spacing: 0) {
            // Invisible placeholder — keeps day columns aligned with week-number column below
            Text("99")
                .font(.system(size: 9))
                .foregroundStyle(.clear)
                .frame(width: 22)

            ForEach(dowLabels, id: \.0) { _, letter in
                Text(letter)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    // MARK: Grid rows

    private var gridRows: some View {
        VStack(spacing: 1) {
            ForEach(Array(monthGrid.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 0) {
                    weekNumButton(for: row)
                    ForEach(Array(row.enumerated()), id: \.offset) { _, date in
                        dayCell(date)
                    }
                }
                .padding(.horizontal, 6)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: Week number button

    private func weekNumButton(for row: [Date?]) -> some View {
        let anchor = row.compactMap { $0 }.first ?? displayMonth
        let wn     = cal.component(.weekOfYear, from: anchor)
        let yr     = cal.component(.yearForWeekOfYear, from: anchor)
        return Button {
            onOpenHorizonsNote(String(format: "%d-W%02d.md", yr, wn))
        } label: {
            Text("\(wn)")
                .font(.system(size: 9))
                .foregroundStyle(.orange)
                .frame(width: 22, alignment: .center)
        }
        .buttonStyle(.plain)
    }

    // MARK: Day cell

    @ViewBuilder
    private func dayCell(_ date: Date?) -> some View {
        if let date {
            let dateStr    = fmt.string(from: date)
            let isToday    = cal.isDateInToday(date)
            let isSelected = dateStr == selectedDateStr
            let inMonth    = cal.isDate(date, equalTo: displayMonth, toGranularity: .month)
            let hasEntry   = datesWithEntries.contains(dateStr)

            Button {
                selectedDateFile = dateStr + ".md"
                let dm = cal.date(from: cal.dateComponents([.year, .month], from: date)) ?? date
                if !cal.isDate(dm, equalTo: displayMonth, toGranularity: .month) {
                    displayMonth = dm
                }
            } label: {
                VStack(spacing: 1) {
                    ZStack {
                        if isToday {
                            Circle().fill(Color.accentColor).frame(width: 24, height: 24)
                        } else if isSelected {
                            Circle().fill(Color.accentColor.opacity(0.22)).frame(width: 24, height: 24)
                        }
                        Text("\(cal.component(.day, from: date))")
                            .font(.system(size: 11, weight: isToday ? .bold : .regular))
                            .foregroundStyle(isToday ? Color.white : inMonth ? Color.primary : Color(nsColor: .tertiaryLabelColor))
                    }
                    .frame(height: 24)

                    // Entry dot
                    Circle()
                        .fill(hasEntry ? Color.accentColor : Color.clear)
                        .frame(width: 3, height: 3)
                }
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
        } else {
            Color.clear
                .frame(height: 28)
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: Navigation actions

    private func step(_ delta: Int) {
        displayMonth = cal.date(byAdding: .month, value: delta, to: displayMonth) ?? displayMonth
    }

    private func openMonth() {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM"
        onOpenHorizonsNote("\(f.string(from: displayMonth)).md")
    }
}

// MARK: - Helpers

private func makeDayFmt() -> DateFormatter {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    return f
}
