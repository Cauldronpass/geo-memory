import SwiftUI
import EventKit
import UIKit

// MARK: - DayNoteAction

/// Passed from calendar/nearby into DayNoteSheet to describe what was tapped.
enum DayNoteAction: Identifiable {
    /// Tapped a specific calendar day (note may already exist, or nil to create).
    case tapDate(Date, DayNote?)
    /// Tapped a fuzzy bucket section header or an existing bucket note.
    case tapBucket(String, DayNote?)

    var id: String {
        switch self {
        case .tapDate(let d, let n):
            return "date-\(d.timeIntervalSince1970)-\(n?.id ?? "new")"
        case .tapBucket(let s, let n):
            return "bucket-\(s)-\(n?.id ?? "new")"
        }
    }

    var existingNote: DayNote? {
        switch self {
        case .tapDate(_, let n): return n
        case .tapBucket(_, let n): return n
        }
    }

    var headerTitle: String {
        switch self {
        case .tapDate(let d, _):
            return d.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
        case .tapBucket(let s, _):
            return s
        }
    }

    var isCreating: Bool { existingNote == nil }
}

// MARK: - DayNoteSheet

struct DayNoteSheet: View {
    let action: DayNoteAction

    @Environment(NotionService.self) private var notion
    @Environment(\.dismiss) private var dismiss

    @State private var noteText: String
    @State private var addReminder = false
    @State private var reminderTime: Date
    @State private var isSaving = false
    @State private var showDeleteConfirm = false
    @State private var showMoveDatePicker = false
    @State private var moveTargetDate = Date()
    @State private var showMoveBucketPicker = false
    @State private var copiedCapture = false
    @State private var errorMessage: String?

    private let bucketScopes = ["This Week", "Next Week", "This Month", "Next Month"]

    init(action: DayNoteAction) {
        self.action = action
        self._noteText = State(initialValue: action.existingNote?.body ?? "")
        // Default reminder to 9am on the target date (future date notes), or today for buckets
        let anchor: Date
        if case .tapDate(let d, _) = action { anchor = d } else { anchor = Date() }
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: anchor)
        comps.hour = 9
        comps.minute = 0
        self._reminderTime = State(initialValue: Calendar.current.date(from: comps) ?? anchor)
    }

    var body: some View {
        NavigationStack {
            Form {
                // Header / context
                Section {
                    Text(action.headerTitle)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }

                // Note body
                Section {
                    TextEditor(text: $noteText)
                        .frame(minHeight: 120)
                        .font(.body)
                }

                // Reminder
                Section {
                    Toggle("Remind me", isOn: $addReminder)
                    if addReminder {
                        DatePicker("Time", selection: $reminderTime, displayedComponents: [.date, .hourAndMinute])
                        Button {
                            openDue()
                        } label: {
                            Label("Use Due instead", systemImage: "arrow.up.right")
                                .font(.subheadline)
                                .foregroundStyle(.orange)
                        }
                    }
                }

                // Actions
                Section {
                    Button {
                        copyAsCapture()
                    } label: {
                        Label(
                            copiedCapture ? "Copied — tap + to add as place note" : "Also save as place note",
                            systemImage: copiedCapture ? "checkmark" : "location.circle"
                        )
                        .foregroundStyle(copiedCapture ? .green : .primary)
                    }
                }

                // Move / Delete (edit mode only)
                if action.existingNote != nil {
                    Section("Move") {
                        Button {
                            if case .tapDate(let d, _) = action { moveTargetDate = d }
                            showMoveDatePicker = true
                        } label: {
                            Label("Move to Different Day", systemImage: "calendar")
                        }
                        Button {
                            showMoveBucketPicker = true
                        } label: {
                            Label("Move to Bucket", systemImage: "tray")
                        }
                    }

                    Section {
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            Label("Delete Note", systemImage: "trash")
                        }
                    }
                }

                if let msg = errorMessage {
                    Section {
                        Text(msg)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle(action.isCreating ? "New Note" : "Edit Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") {
                            Task { await save() }
                        }
                        .disabled(noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .confirmationDialog("Delete this note?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    Task { await delete() }
                }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Move to Bucket", isPresented: $showMoveBucketPicker, titleVisibility: .visible) {
                ForEach(bucketScopes, id: \.self) { scope in
                    Button(scope) { Task { await moveToBucket(scope) } }
                }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(isPresented: $showMoveDatePicker) {
                MoveDatePickerSheet(initialDate: moveTargetDate) { newDate in
                    Task { await moveToDate(newDate) }
                }
            }
        }
    }

    // MARK: - Save

    private func save() async {
        let text = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isSaving = true
        do {
            if let existing = action.existingNote {
                try await notion.updateDayNote(id: existing.id, noteBody: text)
            } else {
                switch action {
                case .tapDate(let date, _):
                    try await notion.saveDayNote(date: date, noteBody: text)
                case .tapBucket(let scope, _):
                    try await notion.saveBucketNote(scope: scope, noteBody: text)
                }
            }
            if addReminder { scheduleReminder(text: text) }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }

    // MARK: - Move

    private func moveToDate(_ date: Date) async {
        guard let existing = action.existingNote else { return }
        do {
            try await notion.moveDayNote(id: existing.id, toDate: date)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func moveToBucket(_ scope: String) async {
        guard let existing = action.existingNote else { return }
        do {
            try await notion.moveDayNoteToBucket(id: existing.id, scope: scope)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Delete

    private func delete() async {
        guard let existing = action.existingNote else { return }
        do {
            try await notion.deleteDayNote(id: existing.id)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Reminder helpers

    private func scheduleReminder(text: String) {
        let store = EKEventStore()
        let handler: (Bool, Error?) -> Void = { granted, _ in
            guard granted else { return }
            let reminder = EKReminder(eventStore: store)
            reminder.title = String(text.prefix(100))
            reminder.addAlarm(EKAlarm(absoluteDate: reminderTime))
            reminder.calendar = store.defaultCalendarForNewReminders()
            try? store.save(reminder, commit: true)
        }
        if #available(iOS 17.0, *) {
            store.requestFullAccessToReminders(completion: handler)
        } else {
            store.requestAccess(to: .reminder, completion: handler)
        }
    }

    private func openDue() {
        let text = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let encoded = text.prefix(100).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd'T'HHmmss"
        let dateStr = fmt.string(from: reminderTime)
        if let url = URL(string: "due:///add?title=\(encoded)&duedate=\(dateStr)") {
            UIApplication.shared.open(url)
        }
    }

    // MARK: - Copy as capture

    private func copyAsCapture() {
        UIPasteboard.general.string = noteText
        withAnimation { copiedCapture = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            copiedCapture = false
        }
    }
}

// MARK: - Move Date Picker Sheet

struct MoveDatePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let initialDate: Date
    let onConfirm: (Date) -> Void

    @State private var selectedDate: Date

    init(initialDate: Date, onConfirm: @escaping (Date) -> Void) {
        self.initialDate = initialDate
        self.onConfirm = onConfirm
        _selectedDate = State(initialValue: initialDate)
    }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker(
                    "Move to date",
                    selection: $selectedDate,
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
            }
            .navigationTitle("Move Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Move") {
                        onConfirm(selectedDate)
                        dismiss()
                    }
                }
            }
        }
    }
}
