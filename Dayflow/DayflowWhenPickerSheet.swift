import SwiftUI

// MARK: - DayflowWhenPickerSheet
//
// Things-style When? picker, per Dayflow-Design-Plan.md "Quick-add half-sheet"
// and Dayflow-Mockup.html's #whenScrim. Today / This Evening (Task only) / a
// pageable week-of-buttons strip / "Pick a specific date…" → a real month grid
// / Someday (Task only) / Clear. Uses real Calendar/Date math throughout —
// not fixed presets — per the design plan's explicit call-out.
//
// This Evening / Someday are Things-native buckets the Mac Mini bridge can't
// express today (it only takes an arbitrary date). That's an open
// architecture question (Design Plan "Open questions") — the picker UI is
// built to spec regardless; how Save actually routes those two is handled
// (and flagged) where drafts get persisted, not here.
//
// **Revised 2026-07-20, Browse views (build order step 5).** The month-grid
// section (monthNav/weekdayHeader/monthGrid/monthCells/date(forDay:)) moved
// out into the new shared DayflowMonthGridView.swift — Dayflow-Mockup.html's
// Calendar browse view explicitly says it "reuses the same renderer as the
// task/event date picker," so this file's own grid became the shared
// implementation instead of DayflowCalendarBrowseView.swift duplicating it.
// No visual or behavioral change to this sheet from the refactor.
//
// **Fixed 2026-07-20 (Session 12), David reported on-device.** Two bugs:
// (1) `weekStart` used `calendar.nextDate(after: Date(), matching: weekday:
// 2, matchingPolicy: .nextTime)`, which by definition finds the next Monday
// STRICTLY AFTER today — so opening this picker on a Monday (as David did)
// jumped straight to *next* week's strip, and the back-arrow was disabled at
// `weekIndex == 0`, leaving no way to get back to the current week short of
// "Pick a specific date…". Fixed by anchoring `weekStart` to
// `calendar.dateInterval(of: .weekOfYear, for: Date())?.start` instead —
// with `firstWeekday = 2` already set on this Calendar, that's the Monday of
// the CURRENT week whether today is that Monday or any other day inside it,
// so `weekIndex == 0` now always means "this week" and the disabled-at-0 back
// arrow is correct (no reason to page earlier than the current week from the
// quick strip; "Pick a specific date…" still covers the past if ever needed).
// (2) David also asked for today's date to read as visually distinct — the
// week grid button for `calendar.isDateInToday(day)` now gets a filled blue
// background + white text instead of the plain unstyled number every other
// day gets.

struct DayflowWhenPickerSheet: View {
    let kind: DayflowEntryKind
    let currentValue: DayflowWhenValue
    let onPick: (DayflowWhenValue) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var weekIndex = 0
    @State private var showMonthPicker = false
    @State private var monthCursor: Date = DayflowWhenPickerSheet.defaultMonthCursor()

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 2 // Monday
        return c
    }

    private static func defaultMonthCursor() -> Date {
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents([.year, .month], from: Date())
        let currentMonthStart = cal.date(from: DateComponents(year: comps.year, month: comps.month, day: 1)) ?? Date()
        // Two months out — the natural "next" month past what the 3-page week
        // strip already covers, same reasoning as the mockup.
        return cal.date(byAdding: .month, value: 2, to: currentMonthStart) ?? Date()
    }

    // MARK: Week strip

    private var weekStart: Date {
        // The Monday (firstWeekday = 2) of the week containing today, not
        // "the next Monday after today" — see the 2026-07-20 fix note above.
        let base = calendar.dateInterval(of: .weekOfYear, for: Date())?.start
            ?? calendar.startOfDay(for: Date())
        return calendar.date(byAdding: .day, value: weekIndex * 7, to: base) ?? base
    }

    private var weekDays: [Date] {
        (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: weekStart) }
    }

    private var weekLabel: String {
        guard let first = weekDays.first, let last = weekDays.last else { return "" }
        let monthDay = DateFormatter(); monthDay.dateFormat = "MMM d"
        let dayOnly = DateFormatter(); dayOnly.dateFormat = "d"
        let sameMonth = calendar.component(.month, from: first) == calendar.component(.month, from: last)
        return sameMonth
            ? "\(monthDay.string(from: first)) – \(dayOnly.string(from: last))"
            : "\(monthDay.string(from: first)) – \(monthDay.string(from: last))"
    }

    private var captionText: String {
        kind == .event
            ? "For events, no Evening/Someday language — those are Things concepts. Today + a real date, written straight to your default calendar via EventKit."
            : "Modeled on Things' own When picker — Today/Evening/Someday route through the Things URL scheme directly from-device, not the Mini bridge, so this works offline too."
    }

    // MARK: Body

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack {
                    Text("When?").font(.title2.bold())
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(spacing: 2) {
                    whenRow(systemImage: "star.fill", tint: .yellow, title: "Today",
                          checked: currentValue == .today) {
                        pick(.today)
                    }
                    if kind == .task {
                        whenRow(systemImage: "moon.stars.fill", tint: .indigo, title: "This Evening",
                                checked: currentValue == .thisEvening) {
                            pick(.thisEvening)
                        }
                    }
                }

                weekNav
                weekdayHeader
                weekGrid

                Button {
                    withAnimation { showMonthPicker.toggle() }
                } label: {
                    Text(showMonthPicker ? "or use the week view above ↑" : "Pick a specific date…")
                        .font(.subheadline.weight(.medium))
                }

                if showMonthPicker {
                    DayflowMonthGridView(monthCursor: $monthCursor) { picked in
                        pick(.date(picked))
                    }
                }

                if kind == .task {
                    whenRow(systemImage: "tray.fill", tint: .orange, title: "Someday", checked: currentValue == .someday) {
                        pick(.someday)
                    }
                }

                Button {
                    pick(.none)
                } label: {
                    Text("Clear")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue) // accent blue, not red — see design plan

                Text(captionText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }
            .padding(20)
        }
    }

    private func pick(_ value: DayflowWhenValue) {
        onPick(value)
        dismiss()
    }

    // MARK: Subviews

    private func whenRow(systemImage: String, tint: Color, title: String, checked: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: systemImage).foregroundStyle(tint).frame(width: 22)
                Text(title).foregroundStyle(.primary)
                Spacer()
                if checked {
                    Image(systemName: "checkmark").foregroundStyle(.blue)
                }
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var weekNav: some View {
        HStack {
            Button { weekIndex = max(0, weekIndex - 1) } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(weekIndex == 0)
            Spacer()
            Text(weekLabel).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            Button { weekIndex += 1 } label: {
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

    private var weekGrid: some View {
        HStack(spacing: 4) {
            ForEach(weekDays, id: \.self) { day in
                let isToday = calendar.isDateInToday(day)
                Button {
                    pick(.date(day))
                } label: {
                    Text("\(calendar.component(.day, from: day))")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(isToday ? .white : .primary)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(isToday ? Color.blue : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
    }
}
