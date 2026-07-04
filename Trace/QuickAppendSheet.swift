import SwiftUI

// MARK: - QuickAppendSheet
//
// Presented when the user long-presses the daily note card on HomeView.
// Replaces the old plain-text QuickAppendSheet with:
//   • MarkdownEditorView — full formatting toolbar (same as daily note editor)
//   • Destination picker — Daily Note / Inbox / Bucket
//   • Date picker — only shown for Daily Note destination; defaults to today

struct QuickAppendSheet: View {

    /// Called after a successful save so the caller can reload its preview.
    let onDone: () -> Void

    @State private var text: String = ""
    @State private var selectedDate: Date = Date()
    @State private var destination: NoteDestination = .daily
    @State private var availableBuckets: [String] = []
    @State private var isSaving = false
    @Environment(\.dismiss) private var dismiss

    // MARK: - Destination

    enum NoteDestination: Equatable {
        case daily, inbox, project(String)

        var label: String {
            switch self {
            case .daily:             return "Daily Note"
            case .inbox:             return "Inbox"
            case .project(let name): return name
            }
        }

        var icon: String {
            switch self {
            case .daily:   return "calendar"
            case .inbox:   return "tray"
            case .project: return "folder"
            }
        }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {

                // — Destination + Date row —
                HStack(spacing: 12) {
                    Menu {
                        Button { destination = .daily } label: {
                            Label("Daily Note", systemImage: "calendar")
                        }
                        Button { destination = .inbox } label: {
                            Label("Inbox", systemImage: "tray")
                        }
                        if !availableBuckets.isEmpty {
                            Menu {
                                ForEach(availableBuckets, id: \.self) { name in
                                    Button(name) { destination = .project(name) }
                                }
                            } label: {
                                Label("Project", systemImage: "folder")
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: destination.icon)
                                .foregroundStyle(Color.accentColor)
                            Text(destination.label)
                                .font(.subheadline.weight(.medium))
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.quaternary, in: Capsule())
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    if case .daily = destination {
                        DatePicker("", selection: $selectedDate, displayedComponents: .date)
                            .labelsHidden()
                            .datePickerStyle(.compact)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                Divider()

                // — Markdown editor with formatting toolbar above keyboard —
                MarkdownEditorView(
                    text: $text,
                    placeholder: "Write something…"
                )
            }
            .navigationTitle("Add Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                }
            }
        }
        .onAppear { loadBuckets() }
    }

    // MARK: - Helpers

    private func loadBuckets() {
        let files = (try? NoteStore.shared.listFiles(in: "Notes/Projects")) ?? []
        availableBuckets = files
            .filter { $0.hasSuffix(".md") }
            .map { String($0.dropLast(3)) }
            .sorted()
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSaving else { return }
        isSaving = true
        Task {
            do {
                switch destination {
                case .daily:
                    try NoteStore.shared.appendToDailyNote(trimmed, date: selectedDate)

                case .inbox:
                    let ts = inboxTimestamp()
                    try NoteStore.shared.writeFile("Notes/Inbox/\(ts).md", content: trimmed)

                case .project(let name):
                    let path = "Notes/Projects/\(name).md"
                    let existing = (try? NoteStore.shared.readFile(path)) ?? "# \(name)\n\n"
                    let separator = existing.hasSuffix("\n") ? "\n" : "\n\n"
                    try NoteStore.shared.writeFile(path, content: existing + separator + trimmed)
                }
            } catch {
                print("QuickAppendSheet save error: \(error)")
            }
            await MainActor.run {
                isSaving = false
                dismiss()
                onDone()
            }
        }
    }

    private func inboxTimestamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.string(from: Date())
    }
}
