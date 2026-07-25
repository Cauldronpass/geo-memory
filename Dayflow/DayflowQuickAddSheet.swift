import SwiftUI

// MARK: - DayflowQuickAddSheet
//
// The quick-add half-sheet — Dayflow-Design-Plan.md calls this "the single
// most important piece to borrow" from Parchment. Ground truth is
// Dayflow-Mockup.html's #scrim/.sheet. Present with a SINGLE fixed detent,
// e.g. `.sheet { ... }.presentationDetents([.medium])` — detents aren't set
// here since that's the presenter's call, not this view's, but avoid offering
// more than one. With multiple detents available, iOS auto-promotes the sheet
// to the largest one the instant a focused text field inside would otherwise
// be cramped by the keyboard (found 2026-07-19: `[.medium, .large]` made Task
// mode's sheet silently jump to near-fullscreen the moment typing started,
// leaving a large dead gap below the sparse Details content — nothing to do
// with this view's own sizing, purely the presenter's detent choice).
//
// This view only builds a DayflowQuickAddDraft and hands it to `onSave` —
// actually persisting it (ThingsService.addTask / a future EventKit write)
// is the caller's job, so this stays reusable from both the main Agenda "+"
// and (later) the widget deep-link.
//
// **Fixed 2026-07-20 (Session 12), David reported on-device.** With the
// single-`.medium`-detent choice above still deliberately in place, the body
// content was one plain `VStack` with no `ScrollView` — fine for Event mode
// and Task mode with Details collapsed, but expanding Task mode's Details
// (Date/List/Notes/Tags rows, plus the Notes `TextEditor`) pushed the
// VStack's natural height well past what a `.medium` sheet actually presents.
// SwiftUI has nowhere to put the overflow without a ScrollView, which is what
// read as the segmented control / toolbar Cancel-Save / Details content all
// visually overlapping. Fix: the whole body now lives inside a `ScrollView`,
// so an expanded Details section scrolls within the fixed-height sheet
// instead of fighting it for space — the single-detent choice above is
// untouched, this only changes how content taller than the sheet behaves.

struct DayflowQuickAddSheet: View {
    var onSave: (DayflowQuickAddDraft) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var kind: DayflowEntryKind
    /// Lets a caller open straight into Event mode instead of the sheet's
    /// long-standing Task-mode default — added 2026-07-24 for the Dayflow
    /// widget's "+" quick-add tap target, which this file's own header
    /// comment already called out as a planned caller ("reusable from both
    /// the main Agenda + and (later) the widget deep-link"). The normal
    /// Agenda "+" (ContentView.swift) keeps passing `.task` explicitly so
    /// nothing about its existing behavior changes.
    init(initialKind: DayflowEntryKind = .task, onSave: @escaping (DayflowQuickAddDraft) -> Void) {
        self.onSave = onSave
        self._kind = State(initialValue: initialKind)
    }
    @State private var rawText: String = ""
    @State private var when: DayflowWhenValue = .none          // Task mode's full range
    @State private var list: String?
    @State private var notes: String = ""                      // Task mode only. Added 2026-07-20.
    @State private var eventDate: Date = Date()                 // Event mode — always concrete
    @State private var eventStart: Date = DayflowQuickAddSheet.roundedNow()
    @State private var eventEnd: Date = DayflowQuickAddSheet.roundedNow(addingMinutes: 30)
    // Event mode — Buffer checkboxes, added 2026-07-24 (backlog item 12).
    // See DayflowQuickAddDraft's matching fields for what these actually do
    // on save; here they only drive the live preview/UI state.
    @State private var bufferBefore = false
    @State private var bufferAfter = false
    /// Event mode's "Nearby on your calendar" panel — the whole day's real
    /// events for `eventDate`, fetched once per day (see the `.task(id:
    /// eventDate)` on `nearbyBox`) and filtered live against
    /// `eventStart`/`eventEnd` by `nearbyEvents` below, so adjusting the
    /// time pickers or a duration pill updates the panel without a refetch.
    /// Added 2026-07-24, David's ask: see what's around a meeting time
    /// without leaving the sheet. Known gap: doesn't fetch the adjacent day,
    /// so a meeting within 2 hours of midnight won't show spillover from the
    /// day before/after — same "not specially handled" tradeoff the buffer
    /// events below accept.
    @State private var nearbyDayEvents: [NextCalendarEvent] = []
    @State private var detailsExpanded = false
    @State private var showWhenPicker = false
    // Real content height of the NL field, kept in sync by
    // DayflowNLHighlightField itself — applied below as an explicit
    // `.frame(height:)` rather than trusting SwiftUI to size the field on its
    // own. See DayflowNLHighlightField.swift's header note: without this, the
    // field has no real intrinsic size opinion and instead competes with the
    // trailing Spacer for whatever's left over in the VStack, which made Task
    // mode's field balloon since its sibling content (a collapsed Details
    // row) is much shorter than Event mode's date/time pill row.
    @State private var fieldHeight: CGFloat = 22

    static func roundedNow(addingMinutes: Int = 0) -> Date {
        let cal = Calendar.current
        let now = Date()
        let minute = cal.component(.minute, from: now)
        let rounded = cal.date(bySettingHour: cal.component(.hour, from: now), minute: (minute / 30) * 30, second: 0, of: now) ?? now
        return cal.date(byAdding: .minute, value: addingMinutes, to: rounded) ?? rounded
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                Picker("", selection: $kind) {
                    Text("Event").tag(DayflowEntryKind.event)
                    Text("Task").tag(DayflowEntryKind.task)
                }
                .pickerStyle(.segmented)

                DayflowNLHighlightField(
                    text: $rawText,
                    placeholder: kind == .event ? "Team offsite tomorrow" : "Take out trash tomorrow /Personal",
                    onParse: { parsedDate, parsedList in
                        if let parsedDate {
                            if kind == .event {
                                eventDate = parsedDate
                            } else {
                                when = .date(parsedDate)
                            }
                        }
                        // Unconditional assignment (including nil) — fixed
                        // 2026-07-20. The old `if let parsedList` only ever
                        // set `list`, never cleared it, so deleting the
                        // visible "/token" text left `list` holding a stale
                        // value with no on-screen indication — a task could
                        // silently file to an area the field no longer shows
                        // any token for. `list` should always mirror what the
                        // live text currently parses to, same as `parsedList`
                        // already does moment to moment.
                        if kind == .task {
                            list = parsedList
                        }
                    },
                    accessoryContent: kind == .task ? AnyView(quickInsertBar) : nil,
                    height: $fieldHeight
                )
                .frame(height: max(fieldHeight, 22))
                .padding(8)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))

                // Kind-specific — Event mode has no /list-token concept, so
                // that half of the sentence doesn't apply there. Was one
                // unconditional string until 2026-07-24 (David: /list
                // tokens/"Personal" only ever apply to Tasks, this caption
                // shouldn't reference it in Event mode).
                Text(kind == .event
                     ? "Type naturally — recognized dates highlight live and fill Date below."
                     : "Type naturally — recognized dates and /list tokens highlight live and fill Date/List below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if kind == .event {
                    // Old placeholder line here ("Writes to your default
                    // calendar...") removed 2026-07-24 — it was also stale,
                    // written before CalendarService.createEvent actually
                    // existed. Replaced with the Duration pills, Buffer
                    // checkboxes, the "creates N events" preview, and the
                    // Nearby panel — all added the same day, walked through
                    // via HTML mockup review before any of this was written.
                    // See each section's own doc comment below for design
                    // reasoning.
                    eventProminentRow
                    durationRow
                    bufferRow
                    if bufferBefore || bufferAfter {
                        eventsPreviewBox
                    }
                    nearbyBox
                } else {
                    detailsSection
                }
                }
                .padding(20)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .disabled(rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .sheet(isPresented: $showWhenPicker) {
                DayflowWhenPickerSheet(
                    kind: kind,
                    currentValue: kind == .event
                        ? (Calendar.current.isDateInToday(eventDate) ? .today : .date(eventDate))
                        : when
                ) { picked in
                    if kind == .event {
                        switch picked {
                        case .none, .today: eventDate = Date()
                        case .date(let d): eventDate = d
                        case .thisEvening, .someday: break // not offered in Event mode's picker
                        }
                    } else {
                        when = picked
                    }
                }
                .presentationDetents([.medium, .large])
            }
        }
    }

    // MARK: Event mode

    private var eventDateLabel: String {
        Calendar.current.isDateInToday(eventDate) ? "Today" : {
            let f = DateFormatter(); f.dateFormat = "EEE MMM d"
            return f.string(from: eventDate)
        }()
    }

    private var eventProminentRow: some View {
        HStack(spacing: 10) {
            eventDatePill
            timePill(label: "Starts", selection: $eventStart)
            timePill(label: "Ends", selection: $eventEnd)
        }
    }

    /// Date is a plain Button (its own tap target, opens the When picker).
    private var eventDatePill: some View {
        Button {
            showWhenPicker = true
        } label: {
            pillFrame(label: "Date") {
                Text(eventDateLabel)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.blue)
            }
        }
        .buttonStyle(.plain)
    }

    /// Starts/Ends embed a native DatePicker, which has its own tap handling —
    /// deliberately no extra onTapGesture layered on top of it here, since that
    /// would fight the DatePicker for the tap.
    private func timePill(label: String, selection: Binding<Date>) -> some View {
        pillFrame(label: label) {
            DatePicker("", selection: selection, displayedComponents: .hourAndMinute)
                .labelsHidden()
                .datePickerStyle(.compact)
                .tint(.blue)
        }
    }

    private func pillFrame<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            content()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Event mode — Duration pills, Buffer, preview, Nearby
    //
    // Added 2026-07-24 (backlog item 12), all four pieces walked through via
    // HTML mockup review with David before any of this was written,
    // including a final skin-matching pass against DayflowSkin.swift's real
    // color values (dayflowInk / dayflowColumnLabel / the gap tile's
    // ink-opacity fills) rather than plain system colors, so this reads as
    // part of the app rather than a bolted-on mockup:
    //
    //   1. Duration pills (30m/45m/1h/1:30/2h) — tapping one sets `eventEnd`
    //      to `eventStart` plus that many minutes; whichever pill currently
    //      matches the live Starts/Ends gap shows selected, none if the gap
    //      doesn't match any pill (hand-edited Starts/Ends, or a duration
    //      not offered). David explicitly didn't want a 3-hour pill — cut to
    //      keep this on one row.
    //   2. Buffer checkboxes ("Buffer -15m" / "Buffer +15m") — two
    //      independent checkboxes (David preferred this over a single
    //      combined checkbox after seeing both mocked up), each adding a
    //      separate 15-minute "Buffer" calendar hold immediately before
    //      Starts / after Ends. Deliberately does NOT change the Starts/Ends
    //      pill values themselves — David's explicit ask, so the real
    //      meeting's real start/end time stays exactly what's shown, and the
    //      buffer is just travel time blocked off around it as its own
    //      event. Actually written in ContentView.saveDraft(_:)'s `.event`
    //      case — this file only tracks the two checkbox states.
    //   3. The "Creates N calendar events" preview box — only shown once at
    //      least one buffer checkbox is on (with neither checked there's
    //      nothing beyond what the Starts/Ends pills already show). Confirms
    //      exactly what Save is about to write, including the buffer's own
    //      computed times, before it happens.
    //   4. The "Nearby on your calendar" panel — David's own addition mid-
    //      review: while deciding on a meeting time, show what's already on
    //      the calendar within 2 hours either side, without leaving the
    //      sheet. Always visible in Event mode (no toggle) — reads as an
    //      empty "Nothing else nearby" state when there's nothing in range.

    private static let bufferMinutes = 15

    private static let durationOptions: [(label: String, minutes: Int)] = [
        ("30m", 30), ("45m", 45), ("1h", 60), ("1:30", 90), ("2h", 120)
    ]

    /// Minutes between `eventStart`/`eventEnd` if it matches one of
    /// `durationOptions` exactly, else nil (hand-edited to something the
    /// pills don't offer) — drives which pill (if any) shows selected.
    private var selectedDurationMinutes: Int? {
        let diff = Int(eventEnd.timeIntervalSince(eventStart) / 60)
        return Self.durationOptions.contains { $0.minutes == diff } ? diff : nil
    }

    private var durationRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DURATION")
                .font(.system(size: 10.5, weight: .medium))
                .tracking(0.4)
                .foregroundStyle(Color.dayflowColumnLabel)
            HStack(spacing: 6) {
                ForEach(Self.durationOptions, id: \.label) { option in
                    let isSelected = selectedDurationMinutes == option.minutes
                    Button {
                        eventEnd = Calendar.current.date(byAdding: .minute, value: option.minutes, to: eventStart) ?? eventEnd
                    } label: {
                        Text(option.label)
                            .font(.system(size: 12, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .foregroundStyle(isSelected ? .white : Color.blue)
                            .background(isSelected ? Color.blue : Color.blue.opacity(0.08),
                                        in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.bottom, 16)
    }

    private var bufferRow: some View {
        HStack(spacing: 22) {
            bufferCheckbox(label: "Buffer -\(Self.bufferMinutes)m", isOn: $bufferBefore)
            bufferCheckbox(label: "Buffer +\(Self.bufferMinutes)m", isOn: $bufferAfter)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.dayflowInk.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        .padding(.bottom, 14)
    }

    /// No explanatory subtext by design — David's call ("I'll know what it
    /// means"), matching how compact the mockup ended up.
    private func bufferCheckbox(label: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(isOn.wrappedValue ? Color.blue : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(isOn.wrappedValue ? Color.blue : Color.gray.opacity(0.45), lineWidth: 2)
                    )
                    .overlay(
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .opacity(isOn.wrappedValue ? 1 : 0)
                    )
                    .frame(width: 18, height: 18)
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.dayflowInk)
            }
        }
        .buttonStyle(.plain)
    }

    private static let previewTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    private func timeRange(_ start: Date, _ end: Date) -> String {
        "\(Self.previewTimeFormatter.string(from: start))–\(Self.previewTimeFormatter.string(from: end))"
    }

    private var bufferBeforeRange: (start: Date, end: Date) {
        (Calendar.current.date(byAdding: .minute, value: -Self.bufferMinutes, to: eventStart) ?? eventStart, eventStart)
    }

    private var bufferAfterRange: (start: Date, end: Date) {
        (eventEnd, Calendar.current.date(byAdding: .minute, value: Self.bufferMinutes, to: eventEnd) ?? eventEnd)
    }

    /// Falls back to a placeholder while the title field is still empty —
    /// Save is disabled in that state anyway, this is purely so the preview
    /// box doesn't show a blank row while typing.
    private var previewEventTitle: String {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "This event" : trimmed
    }

    private var eventsPreviewBox: some View {
        let count = 1 + (bufferBefore ? 1 : 0) + (bufferAfter ? 1 : 0)
        return VStack(alignment: .leading, spacing: 0) {
            Text("CREATES \(count) CALENDAR EVENT\(count == 1 ? "" : "S")")
                .font(.system(size: 10.5, weight: .medium))
                .tracking(0.4)
                .foregroundStyle(Color.dayflowColumnLabel)
                .padding(.horizontal, 12)
                .padding(.top, 9)
                .padding(.bottom, 7)
            if bufferBefore {
                previewRow(time: timeRange(bufferBeforeRange.start, bufferBeforeRange.end), title: "Buffer", isBuffer: true)
            }
            previewRow(time: timeRange(eventStart, eventEnd), title: previewEventTitle, isBuffer: false)
            if bufferAfter {
                previewRow(time: timeRange(bufferAfterRange.start, bufferAfterRange.end), title: "Buffer", isBuffer: true)
            }
        }
        .padding(.bottom, 9)
        .background(Color.dayflowInk.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        .padding(.bottom, 14)
    }

    private func previewRow(time: String, title: String, isBuffer: Bool) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isBuffer ? Color.blue.opacity(0.5) : Color.dayflowInk.opacity(0.55))
                .frame(width: 6, height: 6)
            Text(time)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            Text(title)
                .font(.system(size: 12.5))
                .italic(isBuffer)
                .foregroundStyle(isBuffer ? Color.blue : Color.dayflowInk)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
        .opacity(isBuffer ? 0.85 : 1)
    }

    /// Events on `eventDate` (fetched by `nearbyBox`'s `.task(id:)`) that
    /// fall within 2 hours of the current Starts/Ends — live off
    /// `eventStart`/`eventEnd` with no refetch needed, since a duration pill
    /// or a hand-edited time only changes the filter window, not which
    /// day's events are in play.
    private var nearbyEvents: [NextCalendarEvent] {
        let windowStart = Calendar.current.date(byAdding: .hour, value: -2, to: eventStart) ?? eventStart
        let windowEnd = Calendar.current.date(byAdding: .hour, value: 2, to: eventEnd) ?? eventEnd
        return nearbyDayEvents
            .filter { !$0.isAllDay }
            .filter { $0.startDate < windowEnd && $0.endDate > windowStart }
            .sorted { $0.startDate < $1.startDate }
    }

    /// Dashed ink-tint treatment — deliberately the SAME visual language
    /// DayflowAgendaSection.swift's open-time gap tile already uses (dashed
    /// Color.dayflowInk.opacity(0.22) border, 0.035 fill, 0.5-opacity italic
    /// text), since both represent ambient/informational content rather
    /// than something being acted on — unlike the solid-fill Buffer/preview
    /// boxes above, which represent real events about to be created.
    private var nearbyBox: some View {
        let events = nearbyEvents
        return VStack(alignment: .leading, spacing: 0) {
            Text("NEARBY ON YOUR CALENDAR")
                .font(.system(size: 10.5, weight: .medium))
                .tracking(0.4)
                .foregroundStyle(Color.dayflowColumnLabel)
                .padding(.horizontal, 12)
                .padding(.top, 9)
                .padding(.bottom, 2)
            Text("Within 2 hours of \(timeRange(eventStart, eventEnd))")
                .font(.system(size: 10, weight: .medium))
                .italic()
                .foregroundStyle(Color.dayflowInk.opacity(0.5))
                .padding(.horizontal, 12)
                .padding(.bottom, 7)
            if events.isEmpty {
                Text("Nothing else nearby")
                    .font(.system(size: 11.5))
                    .italic()
                    .foregroundStyle(Color.dayflowInk.opacity(0.5))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 9)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(events) { ev in
                        HStack(spacing: 8) {
                            Circle().fill(Color.dayflowInk.opacity(0.3)).frame(width: 6, height: 6)
                            Text(timeRange(ev.startDate, ev.endDate))
                                .font(.system(size: 12))
                                .italic()
                                .foregroundStyle(Color.dayflowInk.opacity(0.5))
                                .frame(width: 92, alignment: .leading)
                            Text(ev.title)
                                .font(.system(size: 12))
                                .italic()
                                .foregroundStyle(Color.dayflowInk.opacity(0.5))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 12)
                    }
                }
                .padding(.bottom, 9)
            }
        }
        .background(Color.dayflowInk.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.dayflowInk.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        )
        .task(id: eventDate) {
            nearbyDayEvents = await CalendarService.shared.fetchDayEvents(for: eventDate)
        }
    }

    // MARK: Task mode — Details

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation { detailsExpanded.toggle() }
            } label: {
                HStack {
                    Text("Details").foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: detailsExpanded ? "chevron.down" : "chevron.right")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if detailsExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    Button { showWhenPicker = true } label: {
                        fieldRow(
                            label: "Date",
                            value: when == .none ? "No date +" : when.label,
                            valueColor: when == .none ? .secondary : .blue
                        )
                    }
                    .buttonStyle(.plain)

                    fieldRow(label: "List (area/project)", value: list ?? "—", valueColor: .blue)

                    notesField

                    fieldRow(label: "Tags", value: "— (out of scope v1)", valueColor: .secondary)
                        .opacity(0.6)

                    Text("Title above stays freely editable — it's just the text field. Defaults to no date (lands in Anytime once a list is set, matching Things' own behavior). List routes into Things 3. Notes are optional and go straight into the task's real Things notes. Tags intentionally not exposed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                }
            }
        }
    }

    /// Optional multi-line notes/description field — added 2026-07-20, David
    /// asked for a way to attach a description (previously there was none;
    /// every task got a hardcoded "From Trace" note that he found useless and
    /// asked to remove). Unlike the other Details rows (single-line label +
    /// value), this one is directly editable inline rather than opening a
    /// picker, since free text has no picker to open. TextEditor has no
    /// built-in placeholder, so one's overlaid manually when empty — same
    /// pattern DayflowTaskEditSheet's own Notes section uses.
    private var notesField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Notes").foregroundStyle(.primary)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $notes)
                    .frame(minHeight: 60)
                    .padding(4)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                if notes.isEmpty {
                    Text("Add a note (optional)")
                        .foregroundStyle(.tertiary)
                        .padding(.top, 12)
                        .padding(.leading, 9)
                        .allowsHitTesting(false)
                }
            }
        }
        .padding(.vertical, 8)
    }

    private func fieldRow(label: String, value: String, valueColor: Color) -> some View {
        HStack {
            Text(label).foregroundStyle(.primary)
            Spacer()
            Text(value).foregroundStyle(valueColor)
        }
        .padding(.vertical, 8)
    }

    // MARK: Quick-insert keyboard accessory

    private var quickInsertBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Text("Quick insert:").font(.caption).foregroundStyle(.secondary)
                ForEach(DayflowThingsAreas.displayNames, id: \.self) { name in
                    Button {
                        insertList(name)
                    } label: {
                        Text(name)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.quaternary, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        // Now rendered as the text view's native inputAccessoryView (see
        // DayflowNLHighlightField), not a SwiftUI keyboard toolbar item — it
        // sits directly above the keyboard rather than inside the sheet's own
        // layout, so it needs its own opaque bar background to read as part
        // of the keyboard chrome instead of floating over it.
        .background(.bar)
    }

    /// A task has exactly one list — tapping a different chip replaces
    /// whatever "/…" token is already there instead of stacking a second one.
    private func insertList(_ name: String) {
        var value = rawText
        if let slashRange = value.range(of: "/") {
            value.removeSubrange(slashRange.lowerBound..<value.endIndex)
        }
        while value.hasSuffix(" ") { value.removeLast() }
        rawText = value.isEmpty ? "/\(name)" : "\(value) /\(name)"
        list = name
    }

    // MARK: Save

    /// Removes the trailing "/List" token from the title text before saving.
    /// Same "last '/' through end of string" scan `DayflowNLHighlightField`'s
    /// `applyHighlight` already uses to detect the token in the first place
    /// (see that file's comment) — kept as a separate, deliberately identical
    /// scan here rather than threading the detected range back out of the
    /// highlight view, since `save()` only needs the resulting string, not
    /// the range itself.
    ///
    /// Fixed 2026-07-20 — found by David testing on-device: a task typed as
    /// "Test myself /Relationships" correctly filed into the Relationships
    /// area (the JXA-side list-matching fix from the same day), but the
    /// task's actual title in Things was left as the literal
    /// "Test myself /Relationships" — the "/Relationships" text was parsed
    /// out into `list` for filing purposes, but was never removed from the
    /// string that became the title, so it went into Things twice: once as
    /// the real list assignment, once again baked into the title text.
    private func stripListToken(from text: String) -> String {
        guard let slashRange = text.range(of: "/", options: .backwards) else { return text }
        var stripped = String(text[text.startIndex..<slashRange.lowerBound])
        while stripped.hasSuffix(" ") { stripped.removeLast() }
        return stripped
    }

    private func save() {
        // Only strip the token when a list was actually parsed for Task mode
        // — Event mode has no list concept, and if `list` is nil there's no
        // token to remove (a bare "/" a user might type for some other
        // reason stays untouched).
        let titleSource = (kind == .task && list != nil) ? stripListToken(from: rawText) : rawText
        let trimmedTitle = titleSource.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let draft = DayflowQuickAddDraft(
            kind: kind,
            title: trimmedTitle,
            when: kind == .event ? .date(eventDate) : when,
            list: kind == .task ? list : nil,
            notes: kind == .task && !trimmedNotes.isEmpty ? trimmedNotes : nil,
            eventDate: eventDate,
            eventStart: eventStart,
            eventEnd: eventEnd,
            bufferBefore: kind == .event && bufferBefore,
            bufferAfter: kind == .event && bufferAfter
        )
        onSave(draft)
        dismiss()
    }
}
