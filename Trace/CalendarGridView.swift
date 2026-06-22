import SwiftUI

// MARK: - Generic Calendar Entry

/// Controls how a CalendarEntry renders inside a day cell.
/// `.fill`   — fills the whole cell background (default; used by Fitness and Visits calendars)
/// `.circle` — small colored circle indicator below the day number (visits in Life calendar)
/// `.square` — small colored square indicator below the day number (workouts in Life calendar)
enum EntryShape {
    case fill, circle, square
}

struct CalendarEntry: Identifiable {
    let id: String
    let date: Date
    let color: Color
    let cellStat: String?      // small text inside the colored day cell (fill mode only)
    let displayName: String    // shown in multi-select picker
    var value: Double?         // generic numeric for week/month aggregation (e.g. miles)
    var shape: EntryShape = .fill
}

// MARK: - Reusable Calendar Grid

struct CalendarGridView: View {
    let entries: [CalendarEntry]
    /// Day notes keyed by "YYYY-M-D" (matches dateKey format). Default empty.
    let notesByDate: [String: DayNote]
    /// Bucket notes (scope != nil) to display above the grid.
    let bucketNotes: [DayNote]
    /// Set false to suppress the bucket-note cards + add button above the grid.
    let showBucketControls: Bool
    /// Optional second line in weekly summary (e.g. "5.2" for miles). Return nil to omit.
    let weekSecondary: ([CalendarEntry]) -> String?
    /// (value, label) pairs for the monthly summary bar at the bottom.
    let monthStats: ([CalendarEntry]) -> [(String, String)]
    /// Called with ALL entries for a tapped day — single or multiple.
    let onSelect: ([CalendarEntry]) -> Void
    /// Called when a day cell or bucket note is tapped for note actions. Optional.
    let onNoteAction: ((DayNoteAction) -> Void)?
    /// Called when a monthly stat tile is tapped. Receives the label (e.g. "workouts") and all month entries.
    let onStatTap: ((String, [CalendarEntry]) -> Void)?

    @State private var displayMonth: Date
    @State private var showScopePicker = false

    private let cal = Calendar.current
    private let weekdayLetters = ["S", "M", "T", "W", "T", "F", "S"]
    private let bucketOrder = ["This Week", "Next Week", "This Month", "Next Month"]

    init(
        entries: [CalendarEntry],
        notesByDate: [String: DayNote] = [:],
        bucketNotes: [DayNote] = [],
        showBucketControls: Bool = true,
        weekSecondary: @escaping ([CalendarEntry]) -> String? = { _ in nil },
        monthStats: @escaping ([CalendarEntry]) -> [(String, String)],
        onSelect: @escaping ([CalendarEntry]) -> Void,
        onNoteAction: ((DayNoteAction) -> Void)? = nil,
        onStatTap: ((String, [CalendarEntry]) -> Void)? = nil
    ) {
        self.entries = entries
        self.notesByDate = notesByDate
        self.bucketNotes = bucketNotes
        self.showBucketControls = showBucketControls
        self.weekSecondary = weekSecondary
        self.monthStats = monthStats
        self.onSelect = onSelect
        self.onNoteAction = onNoteAction
        self.onStatTap = onStatTap
        let comps = Calendar.current.dateComponents([.year, .month], from: Date())
        _displayMonth = State(initialValue: Calendar.current.date(from: comps)!)
    }

    // MARK: Data

    private func dateKey(_ date: Date) -> String {
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return "\(c.year!)-\(c.month!)-\(c.day!)"
    }

    private var entryMap: [String: [CalendarEntry]] {
        Dictionary(grouping: entries, by: { dateKey($0.date) })
    }

    private var weeks: [CGWeek] {
        let firstWeekday = cal.component(.weekday, from: displayMonth) - 1
        let daysInMonth = cal.range(of: .day, in: .month, for: displayMonth)!.count

        var days: [CGDay?] = Array(repeating: nil, count: firstWeekday)
        for d in 0..<daysInMonth {
            let date = cal.date(byAdding: .day, value: d, to: displayMonth)!
            days.append(CGDay(date: date, entries: entryMap[dateKey(date)] ?? []))
        }
        while days.count % 7 != 0 { days.append(nil) }

        return stride(from: 0, to: days.count, by: 7).map { i in
            CGWeek(days: Array(days[i..<i+7]))
        }
    }

    private var monthEntries: [CalendarEntry] {
        let c = cal.dateComponents([.year, .month], from: displayMonth)
        return entries.filter {
            let wc = cal.dateComponents([.year, .month], from: $0.date)
            return wc.year == c.year && wc.month == c.month
        }
    }

    private var nonEmptyBuckets: [String] {
        bucketOrder.filter { scope in bucketNotes.contains { $0.scope == scope } }
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 8) {
            monthHeader.padding(.horizontal)

            if showBucketControls && onNoteAction != nil {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(nonEmptyBuckets, id: \.self) { scope in
                        bucketCard(scope: scope)
                    }
                    Button {
                        showScopePicker = true
                    } label: {
                        Label("Add bucket note", systemImage: "plus.circle")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }
                    .padding(.horizontal, 4)
                }
                .padding(.horizontal)
                .padding(.top, 4)
                .confirmationDialog("Add Bucket Note", isPresented: $showScopePicker) {
                    ForEach(bucketOrder, id: \.self) { scope in
                        Button(scope) { onNoteAction?(.tapBucket(scope, nil)) }
                    }
                    Button("Cancel", role: .cancel) {}
                }
            }

            weekdayHeader.padding(.horizontal, 6)
            Divider().padding(.horizontal)

            VStack(spacing: 3) {
                ForEach(weeks) { week in weekRow(week) }
            }
            .padding(.horizontal, 6)

            Divider().padding(.horizontal)

            let stats = monthStats(monthEntries)
            if !stats.isEmpty {
                monthSummaryBar(stats: stats, entries: monthEntries)
                    .padding(.horizontal)
                    .padding(.top, 4)
            }
        }
    }

    // MARK: Month header

    private var monthHeader: some View {
        HStack {
            Button {
                displayMonth = cal.date(byAdding: .month, value: -1, to: displayMonth)!
            } label: {
                Image(systemName: "chevron.left")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.orange)
            }
            Spacer()
            Text(displayMonth.formatted(.dateTime.month(.wide).year()))
                .font(.headline)
            Spacer()
            Button {
                displayMonth = cal.date(byAdding: .month, value: 1, to: displayMonth)!
            } label: {
                Image(systemName: "chevron.right")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: Weekday header

    private var weekdayHeader: some View {
        HStack(spacing: 3) {
            ForEach(0..<7, id: \.self) { i in
                Text(weekdayLetters[i])
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
            Color.clear.frame(width: 38)
        }
    }

    // MARK: Bucket cards (above grid)

    private func bucketCard(scope: String) -> some View {
        let notes = bucketNotes.filter { $0.scope == scope }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(scope)
                    .font(.subheadline.weight(.semibold))
                Text("·")
                    .foregroundStyle(.secondary)
                Text("\(notes.count)")
                    .font(.subheadline.bold())
                    .foregroundStyle(.orange)
                Spacer()
                if onNoteAction != nil {
                    Button {
                        onNoteAction?(.tapBucket(scope, nil))
                    } label: {
                        Image(systemName: "plus")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                }
            }
            ForEach(notes) { note in
                Button {
                    onNoteAction?(.tapBucket(scope, note))
                } label: {
                    Text(note.body)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
                .disabled(onNoteAction == nil)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Week row

    @ViewBuilder
    private func weekRow(_ week: CGWeek) -> some View {
        let weekEntries = week.days.compactMap { $0 }.flatMap { $0.entries }
        let activeDays = week.days.compactMap { $0 }.filter { !$0.entries.isEmpty }.count
        let secondary = weekSecondary(weekEntries)

        HStack(spacing: 3) {
            ForEach(0..<7, id: \.self) { i in
                if let day = week.days[i] {
                    dayCell(day)
                } else {
                    Color.clear
                        .frame(maxWidth: .infinity)
                        .aspectRatio(0.8, contentMode: .fit)
                }
            }
            VStack(alignment: .trailing, spacing: 2) {
                if activeDays > 0 {
                    Text("\(activeDays)")
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                    if let sec = secondary {
                        Text(sec)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 38, alignment: .trailing)
        }
    }

    // MARK: Day cell

    @ViewBuilder
    private func dayCell(_ day: CGDay) -> some View {
        let hasEntries = !day.entries.isEmpty
        let key = dateKey(day.date)
        let note = notesByDate[key]
        let hasNote = note != nil
        let isToday = cal.isDateInToday(day.date)
        let isInteractive = hasEntries || onNoteAction != nil
        // Use shape-indicator mode when any entry opts out of fill
        let useShapeMode = day.entries.contains { $0.shape != .fill }

        Button {
            if hasEntries {
                onSelect(day.entries)
            } else {
                onNoteAction?(.tapDate(day.date, note))
            }
        } label: {
            if useShapeMode {
                shapeModeCell(day: day, isToday: isToday, hasNote: hasNote)
            } else {
                fillModeCell(day: day, isToday: isToday, hasNote: hasNote)
            }
        }
        .buttonStyle(.plain)
        .disabled(!isInteractive)
        .frame(maxWidth: .infinity)
        .aspectRatio(0.8, contentMode: .fit)
    }

    /// Original fill-mode cell: entire background tinted with the first entry's color.
    @ViewBuilder
    private func fillModeCell(day: CGDay, isToday: Bool, hasNote: Bool) -> some View {
        let hasEntries = !day.entries.isEmpty
        let primary = day.entries.first
        let color = primary?.color ?? .clear
        let extraCount = max(0, day.entries.count - 1)

        ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill(hasEntries ? color.opacity(0.82) : Color(.secondarySystemGroupedBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(isToday ? Color.orange : Color.clear, lineWidth: 2)
                )
            VStack(spacing: 1) {
                Text("\(cal.component(.day, from: day.date))")
                    .font(.system(size: 12, weight: hasEntries ? .bold : .regular))
                    .foregroundStyle(
                        hasEntries ? .white
                        : isToday ? .orange
                        : .primary
                    )
                if let stat = primary?.cellStat {
                    Text(stat)
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                }
                if extraCount > 0 {
                    HStack(spacing: 2) {
                        ForEach(0..<min(extraCount, 3), id: \.self) { _ in
                            Circle().fill(.white.opacity(0.75)).frame(width: 4, height: 4)
                        }
                    }
                }
                if hasNote {
                    Circle()
                        .fill(hasEntries ? Color.white.opacity(0.55) : Color.indigo)
                        .frame(width: 4, height: 4)
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// Shape-mode cell: neutral background; colored circles (visits) and squares (workouts)
    /// displayed as small indicators below the day number. Used by the Life calendar.
    @ViewBuilder
    private func shapeModeCell(day: CGDay, isToday: Bool, hasNote: Bool) -> some View {
        let hasEntries = !day.entries.isEmpty
        let visible = Array(day.entries.prefix(4))
        let overflow = max(0, day.entries.count - 4)

        ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill(Color(.secondarySystemGroupedBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(isToday ? Color.orange : Color.clear, lineWidth: 2)
                )
            VStack(spacing: 2) {
                Text("\(cal.component(.day, from: day.date))")
                    .font(.system(size: 12, weight: hasEntries ? .semibold : .regular))
                    .foregroundStyle(isToday ? Color.orange : .primary)

                if !visible.isEmpty {
                    // Up to 4 shape indicators in a 2×2 grid-ish flow
                    let rows = visible.chunked(into: 2)
                    ForEach(rows.indices, id: \.self) { ri in
                        HStack(spacing: 2) {
                            ForEach(rows[ri], id: \.id) { entry in
                                entryShapeView(entry)
                            }
                        }
                    }
                    if overflow > 0 {
                        Text("+\(overflow)")
                            .font(.system(size: 7, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }

                if hasNote {
                    Circle()
                        .fill(Color.indigo)
                        .frame(width: 4, height: 4)
                }
            }
            .padding(.vertical, 3)
        }
    }

    @ViewBuilder
    private func entryShapeView(_ entry: CalendarEntry) -> some View {
        switch entry.shape {
        case .circle:
            Circle()
                .fill(entry.color)
                .frame(width: 7, height: 7)
        case .square:
            RoundedRectangle(cornerRadius: 2)
                .fill(entry.color)
                .frame(width: 7, height: 7)
        case .fill:
            Circle()
                .fill(entry.color)
                .frame(width: 7, height: 7)
        }
    }

    // MARK: Monthly summary bar

    private func monthSummaryBar(stats: [(String, String)], entries: [CalendarEntry]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(stats.enumerated()), id: \.offset) { i, stat in
                Button {
                    onStatTap?(stat.1, entries)
                } label: {
                    VStack(spacing: 2) {
                        Text(stat.0).font(.subheadline.bold())
                        Text(stat.1).font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if i < stats.count - 1 {
                    Divider().frame(height: 32)
                }
            }
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Internal models (file-private)

private struct CGWeek: Identifiable {
    let id = UUID()
    let days: [CGDay?]
}

private struct CGDay {
    let date: Date
    let entries: [CalendarEntry]
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
