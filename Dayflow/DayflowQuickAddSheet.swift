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
// This view only builds a DayflowQuickAddDraft and hands it to `onSave` —
// actually persisting it (ThingsService.addTask / a future EventKit write)
// is the caller's job, so this stays reusable from both the main Agenda "+"
// and (later) the widget deep-link.

struct DayflowQuickAddSheet: View {
    var onSave: (DayflowQuickAddDraft) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var kind: DayflowEntryKind = .task
    @State private var rawText: String = ""
    @State private var when: DayflowWhenValue = .none          // Task mode's full range
    @State private var list: String?
    @State private var notes: String = ""                      // Task mode only. Added 2026-07-20.
    @State private var eventDate: Date = Date()                 // Event mode — always concrete
    @State private var eventStart: Date = DayflowQuickAddSheet.roundedNow()
    @State private var eventEnd: Date = DayflowQuickAddSheet.roundedNow(addingMinutes: 30)
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
                        if kind == .task, let parsedList {
                            list = parsedList
                        }
                    },
                    accessoryContent: kind == .task ? AnyView(quickInsertBar) : nil,
                    height: $fieldHeight
                )
                .frame(height: max(fieldHeight, 22))
                .padding(8)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))

                Text("Type naturally — recognized dates and /list tokens highlight live and fill Date/List below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if kind == .event {
                    eventProminentRow
                    Text("Writes to your default calendar (EventKit write support isn't built yet — which calendar is default will be a Settings toggle, not chosen per event).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    detailsSection
                }

                Spacer(minLength: 0)
            }
            .padding(20)
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

    private func save() {
        let trimmedTitle = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
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
            eventEnd: eventEnd
        )
        onSave(draft)
        dismiss()
    }
}
