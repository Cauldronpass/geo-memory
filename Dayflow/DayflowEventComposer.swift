//
//  DayflowEventComposer.swift
//  Dayflow
//
//  The event composer behind Today's + (Session 77, design locked on the
//  "Dayflow Skin" canvas over four rounds — see the two "New Event" frames).
//  Replaces DayflowQuickAddSheet's event mode; the Task/Event mode switch
//  retired with it (dated tasks = "Add for today", undated = the Inbox +).
//
//  The shape, all David's calls:
//  - Serif title, then a DATE ROW that UNFOLDS in place: his hairdresser
//    case — "does September 15th work?" — means the month grid and the day
//    track must be visible TOGETHER. Tapping a day redraws the track for
//    that day and the calendar STAYS OPEN for comparing days; it folds when
//    the row is tapped again. Busy dots under each day (none/light/mid/dark
//    by timed-meeting count, one ranged query per month) half-answer "does
//    it work" before any tap.
//  - The DAY TRACK: 7am-10pm, existing meetings as dark blocks, the new
//    event as the accent block dragged into a gap, 15-minute snapping, live
//    time readout. (Logged, not built: coloring the blocks by his meeting
//    categories — Trace-Backlog "Meeting colors by meaning".)
//  - Duration chips in the order 30M · 1H · 2H · CUSTOM (custom = inline
//    wheel); BUFFERS chip expands to 15M BEFORE / 15M AFTER, wired to the
//    same separate-15-minute-Buffer-events the old sheet created.
//

import SwiftUI
import UIKit

struct DayflowEventComposer: View {
    var initialDate: Date = Date()
    /// Called after a successful save with the event's day, so ContentView
    /// can refresh the visible day's strip.
    var onSaved: (Date) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var eventDate: Date
    @State private var displayedMonth: Date
    /// OPEN by default (David, 2026-08-28: most of his events land on other
    /// days, so the month should never cost a tap; "is there any real reason
    /// to have two versions of the cards?" — there isn't: one card, one
    /// folding calendar, and the fold serves the quick same-day case).
    @State private var showCalendar = true
    @State private var monthCounts: [Int: Int] = [:]
    @State private var dayEvents: [NextCalendarEvent] = []
    @State private var startMinutes: Int
    @State private var durationMinutes = 60
    @State private var showCustomDuration = false
    @State private var showBuffers = false
    @State private var bufferBefore = false
    @State private var bufferAfter = false
    @State private var saving = false
    /// Whether the last drag position overlapped something — drives the
    /// entering-a-conflict haptic (a firmer knock than the 15-min tick).
    @State private var hadOverlap = false
    @State private var errorMessage: String? = nil
    @FocusState private var titleFocused: Bool

    /// The track's window: 7:00 to 22:00.
    private static let windowStart = 7 * 60
    private static let windowEnd = 22 * 60

    init(initialDate: Date = Date(), onSaved: @escaping (Date) -> Void = { _ in }) {
        self.initialDate = initialDate
        self.onSaved = onSaved
        _eventDate = State(initialValue: Calendar.current.startOfDay(for: initialDate))
        _displayedMonth = State(initialValue: Calendar.current.startOfDay(for: initialDate))
        // Today starts at the next half hour; any other day at 9:00.
        if Calendar.current.isDateInToday(initialDate) {
            let cal = Calendar.current
            let comps = cal.dateComponents([.hour, .minute], from: Date())
            let now = (comps.hour ?? 9) * 60 + (comps.minute ?? 0)
            let next = ((now / 30) + 1) * 30
            _startMinutes = State(initialValue: min(max(next, Self.windowStart), Self.windowEnd - 60))
        } else {
            _startMinutes = State(initialValue: 9 * 60)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("NEW EVENT")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(2)
                    .foregroundStyle(Color.dayflowInk)
                Rectangle().fill(Color.dayflowInk).frame(height: 1)

                TextField("What is it?", text: $title)
                    .font(.dayflowSerif(20, weight: .semibold))
                    .focused($titleFocused)
                    .submitLabel(.done)
                    .onSubmit { titleFocused = false }

                dateSection
                trackSection
                chipsRow
                if showCustomDuration { customDurationWheel }
                if showBuffers { buffersRow }

                Rectangle().fill(Color.dayflowHairline).frame(height: 1)

                Button { save() } label: {
                    Text(saving ? "Adding\u{2026}" : "Add to Calendar")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.dayflowPaper)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(Color.dayflowInk, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(saving || title.trimmingCharacters(in: .whitespaces).isEmpty)
                .opacity(title.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
            }
            .padding(20)
        }
        .scrollIndicators(.hidden)
        .presentationDetents([.height(showCalendar ? 700 : 460), .large])
        .presentationBackground(Color.dayflowPaper)
        .task {
            await reloadDay()
            await reloadMonth()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { titleFocused = true }
        }
        .alert("Couldn't save", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: Date row + unfolding month

    private var dateLabel: String {
        let cal = Calendar.current
        let f = DateFormatter()
        if cal.isDateInToday(eventDate) { f.dateFormat = "'Today,' EEEE d" }
        else if cal.isDateInTomorrow(eventDate) { f.dateFormat = "'Tomorrow,' EEEE d" }
        else { f.dateFormat = "EEEE d MMMM" }
        return f.string(from: eventDate)
    }

    private var dateSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showCalendar.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "calendar")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.dayflowAccent)
                    Text(dateLabel)
                        .font(.system(size: 14))
                        .foregroundStyle(Color.dayflowInk)
                    Image(systemName: showCalendar ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.dayflowFaint)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showCalendar { monthGrid }
        }
        .padding(12)
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Color.dayflowHairline, lineWidth: 1))
    }

    private var monthGrid: some View {
        let cal = Calendar.current
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: displayedMonth)) ?? displayedMonth
        let dayCount = cal.range(of: .day, in: .month, for: monthStart)?.count ?? 30
        // Monday-first leading blanks.
        let weekday = cal.component(.weekday, from: monthStart) // 1 = Sunday
        let lead = (weekday + 5) % 7
        let monthName: String = {
            let f = DateFormatter(); f.dateFormat = "MMMM yyyy"
            return f.string(from: monthStart).uppercased()
        }()
        let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)

        return VStack(spacing: 6) {
            HStack {
                Button { shiftMonth(-1) } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.dayflowMuted)
                        .frame(width: 32, height: 28)
                }
                .buttonStyle(.plain)
                Spacer()
                Text(monthName)
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.6)
                    .foregroundStyle(Color.dayflowInk)
                Spacer()
                Button { shiftMonth(1) } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.dayflowMuted)
                        .frame(width: 32, height: 28)
                }
                .buttonStyle(.plain)
            }
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(["M", "T", "W", "T2", "F", "S", "S2"], id: \.self) { d in
                    Text(String(d.prefix(1)))
                        .font(.system(size: 10))
                        .foregroundStyle(Color.dayflowFaint)
                }
                ForEach(0..<lead, id: \.self) { _ in Color.clear.frame(height: 40) }
                ForEach(1...dayCount, id: \.self) { day in
                    dayCell(day, monthStart: monthStart)
                }
            }
        }
    }

    private func dayCell(_ day: Int, monthStart: Date) -> some View {
        let cal = Calendar.current
        let date = cal.date(byAdding: .day, value: day - 1, to: monthStart) ?? monthStart
        let selected = cal.isDate(date, inSameDayAs: eventDate)
        let isToday = cal.isDateInToday(date)
        let count = monthCounts[day] ?? 0
        return Button {
            // The calendar STAYS open — comparing days is the use case.
            eventDate = cal.startOfDay(for: date)
            UISelectionFeedbackGenerator().selectionChanged()
            Task { await reloadDay() }
        } label: {
            VStack(spacing: 3) {
                Text("\(day)")
                    .font(.system(size: 13, weight: selected ? .bold : (isToday ? .semibold : .regular)))
                    .foregroundStyle(selected ? Color.dayflowPaper
                                     : (isToday ? Color.dayflowAccent : Color.dayflowInk))
                    .frame(width: 28, height: 28)
                    .background(selected ? Color.dayflowInk : Color.clear, in: Circle())
                Circle()
                    .fill(dotColor(count))
                    .frame(width: 4, height: 4)
            }
            .frame(height: 40)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// None / light / mid / dark by timed-meeting count.
    private func dotColor(_ count: Int) -> Color {
        switch count {
        case 0: return .clear
        case 1: return Color.dayflowFaint.opacity(0.45)
        case 2: return Color.dayflowFaint
        default: return Color.dayflowMuted
        }
    }

    private func shiftMonth(_ delta: Int) {
        let cal = Calendar.current
        displayedMonth = cal.date(byAdding: .month, value: delta, to: displayedMonth) ?? displayedMonth
        Task { await reloadMonth() }
    }

    // MARK: The day track

    private var trackLabel: String {
        let cal = Calendar.current
        if cal.isDateInToday(eventDate) { return "TIME" }
        let f = DateFormatter(); f.dateFormat = "EEE d"
        return "TIME \u{00B7} \(f.string(from: eventDate).uppercased())"
    }

    private var timeReadout: String {
        "\(minutesLabel(startMinutes)) \u{2013} \(minutesLabel(startMinutes + durationMinutes))"
    }

    private func minutesLabel(_ minutes: Int) -> String {
        var comps = DateComponents()
        comps.hour = minutes / 60; comps.minute = minutes % 60
        let date = Calendar.current.date(from: comps) ?? Date()
        return DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
    }

    /// Existing meetings the new block currently intersects. Warn, never
    /// block (David's call, 2026-08-28): a deliberate overlap — a hold over
    /// lunch — must stay possible; the composer's job is that it never
    /// happens unknowingly.
    /// The full footprint INCLUDING chosen buffers — David, 2026-08-28:
    /// buffers count in the proposed length, on the track and in the
    /// overlap math both ("It should be").
    private var bufferedStart: Int { startMinutes - (bufferBefore ? 15 : 0) }
    private var bufferedEnd: Int { startMinutes + durationMinutes + (bufferAfter ? 15 : 0) }

    private var overlappedEvents: [NextCalendarEvent] {
        let newStart = bufferedStart
        let newEnd = bufferedEnd
        return dayEvents.filter { !$0.isAllDay }.filter { ev in
            minutesOfDay(ev.startDate) < newEnd && minutesOfDay(ev.endDate) > newStart
        }
    }

    private var trackSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                // The label line IS the warning surface — no reserved space,
                // no layout jump: TIME becomes OVERLAPS <MEETING> in accent
                // while the blocks intersect, and swaps straight back.
                if let first = overlappedEvents.first {
                    Text(overlappedEvents.count == 1
                         ? "OVERLAPS \(first.title.uppercased())"
                         : "OVERLAPS \(overlappedEvents.count) MEETINGS")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(1.6)
                        .foregroundStyle(Color.dayflowAccent)
                        .lineLimit(1)
                } else {
                    Text(trackLabel)
                        .font(.system(size: 11, weight: .bold))
                        .tracking(1.6)
                        .foregroundStyle(Color.dayflowInk)
                }
                Spacer(minLength: 12)
                Text(timeReadout)
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(Color.dayflowInk)
                    .layoutPriority(1)
            }
            GeometryReader { geo in
                let width = geo.size.width
                let span = CGFloat(Self.windowEnd - Self.windowStart)
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.dayflowHairline.opacity(0.7))
                        .frame(height: 6)
                        .offset(y: 12)
                    ForEach(dayEvents.filter { !$0.isAllDay }, id: \.id) { ev in
                        let s = clampToWindow(minutesOfDay(ev.startDate))
                        let e = clampToWindow(minutesOfDay(ev.endDate))
                        let hit = overlappedEvents.contains { $0.id == ev.id }
                        if e > s {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(hit ? Color.dayflowAccent.opacity(0.55) : Color.dayflowNoteText)
                                .frame(width: max(4, width * CGFloat(e - s) / span), height: 6)
                                .offset(x: width * CGFloat(s - Self.windowStart) / span, y: 12)
                        }
                    }
                    if bufferBefore {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.dayflowAccent.opacity(0.3))
                            .frame(width: max(4, width * 15 / span), height: 10)
                            .offset(x: width * CGFloat(bufferedStart - Self.windowStart) / span, y: 10)
                    }
                    if bufferAfter {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.dayflowAccent.opacity(0.3))
                            .frame(width: max(4, width * 15 / span), height: 10)
                            .offset(x: width * CGFloat(startMinutes + durationMinutes - Self.windowStart) / span, y: 10)
                    }
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.dayflowAccent)
                        .frame(width: max(8, width * CGFloat(durationMinutes) / span), height: 16)
                        .offset(x: width * CGFloat(startMinutes - Self.windowStart) / span, y: 7)
                        .shadow(color: Color.dayflowAccent.opacity(0.4), radius: 4, y: 2)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let fraction = min(max(value.location.x / width, 0), 1)
                            let raw = Self.windowStart + Int(fraction * span) - durationMinutes / 2
                            let snapped = (raw / 15) * 15
                            // The buffers ride along, so the whole buffered
                            // footprint has to fit the window.
                            let lo = Self.windowStart + (bufferBefore ? 15 : 0)
                            let hi = Self.windowEnd - durationMinutes - (bufferAfter ? 15 : 0)
                            let clamped = min(max(snapped, lo), max(lo, hi))
                            if clamped != startMinutes {
                                startMinutes = clamped
                                let overlapping = !overlappedEvents.isEmpty
                                if overlapping && !hadOverlap {
                                    // Entering a conflict: a firmer knock
                                    // than the 15-minute tick.
                                    UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                                } else {
                                    UISelectionFeedbackGenerator().selectionChanged()
                                }
                                hadOverlap = overlapping
                            }
                        }
                )
            }
            .frame(height: 24)
            HStack {
                ForEach([7, 10, 13, 16, 19, 22], id: \.self) { h in
                    Text(h <= 12 ? "\(h)" : "\(h - 12)")
                        .font(.system(size: 8.5))
                        .foregroundStyle(Color.dayflowFaint)
                    if h != 22 { Spacer() }
                }
            }
        }
    }

    private func minutesOfDay(_ date: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    private func clampToWindow(_ m: Int) -> Int {
        min(max(m, Self.windowStart), Self.windowEnd)
    }

    // MARK: Duration + buffers

    private var chipsRow: some View {
        HStack(spacing: 8) {
            durationChip("30M", 30)
            durationChip("1H", 60)
            durationChip("2H", 120)
            chip("CUSTOM", active: showCustomDuration || ![30, 60, 120].contains(durationMinutes)) {
                withAnimation(.easeInOut(duration: 0.15)) { showCustomDuration.toggle() }
            }
            Spacer(minLength: 0)
            chip("BUFFERS", active: bufferBefore || bufferAfter || showBuffers) {
                withAnimation(.easeInOut(duration: 0.15)) { showBuffers.toggle() }
            }
        }
    }

    private func durationChip(_ label: String, _ minutes: Int) -> some View {
        chip(label, active: durationMinutes == minutes && !showCustomDuration) {
            durationMinutes = minutes
            showCustomDuration = false
            clampStart()
        }
    }

    private func chip(_ label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11.5, weight: active ? .bold : .regular))
                .tracking(0.5)
                .foregroundStyle(active ? Color.dayflowAccent : Color.dayflowMuted)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(active ? Color.dayflowAccent : Color.dayflowHairline,
                                  lineWidth: active ? 1.5 : 1))
        }
        .buttonStyle(.plain)
    }

    private var customDurationWheel: some View {
        Picker("Duration", selection: $durationMinutes) {
            ForEach(Array(stride(from: 15, through: 480, by: 15)), id: \.self) { m in
                Text(m < 60 ? "\(m) min"
                     : m % 60 == 0 ? "\(m / 60) h"
                     : "\(m / 60) h \(m % 60) min").tag(m)
            }
        }
        .pickerStyle(.wheel)
        .frame(height: 100)
        .onChange(of: durationMinutes) { _, _ in clampStart() }
    }

    private var buffersRow: some View {
        HStack(spacing: 8) {
            chip("15M BEFORE", active: bufferBefore) { bufferBefore.toggle(); clampStart() }
            chip("15M AFTER", active: bufferAfter) { bufferAfter.toggle(); clampStart() }
            Spacer(minLength: 0)
        }
    }

    /// Keeps the buffered footprint inside the track window whenever the
    /// duration or a buffer changes.
    private func clampStart() {
        let lo = Self.windowStart + (bufferBefore ? 15 : 0)
        let hi = Self.windowEnd - durationMinutes - (bufferAfter ? 15 : 0)
        startMinutes = min(max(startMinutes, lo), max(lo, hi))
    }

    // MARK: Data + save

    private func reloadDay() async {
        dayEvents = await CalendarService.shared.fetchDayEvents(for: eventDate)
    }

    private func reloadMonth() async {
        monthCounts = await CalendarService.shared.fetchMonthEventCounts(for: displayedMonth)
    }

    private func save() {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !saving else { return }
        saving = true
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: eventDate)
        guard let start = cal.date(byAdding: .minute, value: startMinutes, to: dayStart),
              let end = cal.date(byAdding: .minute, value: startMinutes + durationMinutes, to: dayStart)
        else { saving = false; return }
        let calendarIdentifier = UserDefaults.standard.string(forKey: "default_calendar_identifier")
        let day = eventDate
        let withBefore = bufferBefore
        let withAfter = bufferAfter

        Task { @MainActor in
            var ok = true
            if withBefore {
                let bStart = cal.date(byAdding: .minute, value: -15, to: start) ?? start
                ok = await CalendarService.shared.createEvent(
                    title: "Buffer", date: day, startTime: bStart, endTime: start,
                    calendarIdentifier: calendarIdentifier) && ok
            }
            ok = await CalendarService.shared.createEvent(
                title: name, date: day, startTime: start, endTime: end,
                calendarIdentifier: calendarIdentifier) && ok
            if withAfter {
                let bEnd = cal.date(byAdding: .minute, value: 15, to: end) ?? end
                ok = await CalendarService.shared.createEvent(
                    title: "Buffer", date: day, startTime: end, endTime: bEnd,
                    calendarIdentifier: calendarIdentifier) && ok
            }
            saving = false
            if ok {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                dismiss()
                onSaved(day)
            } else {
                errorMessage = "\"\(name)\" wasn't saved to Calendar. Check Calendar access in iOS Settings and your Default Calendar in Dayflow Settings, then try again."
            }
        }
    }
}
