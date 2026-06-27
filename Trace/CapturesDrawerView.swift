import SwiftUI
import CoreLocation

// MARK: - InboxNote
//
// Represents one file from Notes/Inbox/YYYY-MM-DD-HHmmss.md.
// Written by AddCaptureView (text notes) and AddPhotoView (photo captures).

struct InboxNote: Identifiable {
    let filename: String     // e.g. "2026-06-26-143022.md"
    let content: String      // raw file content
    let date: Date           // parsed from filename prefix

    var id: String { filename }

    var hasPhoto: Bool { content.contains("![](") }

    /// Everything after the leading # header line(s) and blank lines.
    var bodyContent: String {
        let lines = content.components(separatedBy: "\n")
        let body = lines.drop(while: { $0.hasPrefix("#") || $0.trimmingCharacters(in: .whitespaces).isEmpty })
        return body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Short preview for the list row — skips photo/PDF reference lines and place metadata.
    var previewLine: String {
        bodyContent.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("![]") && !$0.hasPrefix("📎") && !$0.hasPrefix("**Place:**") && !$0.isEmpty }
            .first ?? (hasPhoto ? "(photo)" : "(empty)")
    }

    /// Extracts the place name from a `**Place:** Name` line embedded by AddCaptureView, if present.
    var placeNameInBody: String? {
        for line in bodyContent.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("**Place:**") {
                let name = String(t.dropFirst("**Place:**".count))
                    .trimmingCharacters(in: .whitespaces)
                return name.isEmpty ? nil : name
            }
        }
        return nil
    }

    /// Body content with the `**Place:** Name` metadata line stripped — used when routing to a place note.
    var bodyWithoutPlace: String {
        bodyContent.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("**Place:**") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    init?(filename: String, content: String) {
        self.filename = filename
        self.content = content
        let bare = filename.replacingOccurrences(of: ".md", with: "")
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        guard let d = f.date(from: bare) else { return nil }
        self.date = d
    }
}

// MARK: - CapturesDrawerView

struct CapturesDrawerView: View {
    @Binding var isShowing: Bool
    @Environment(NotionService.self) private var notion

    @State private var inboxNotes: [InboxNote] = []
    @State private var isLoading = true
    @State private var actionNote: InboxNote?
    @State private var showingActions = false
    @State private var showingPlacePicker = false
    @State private var selectedPlaceForMove: Place? = nil
    @State private var showingBucketPicker = false
    @State private var showingProjectPicker = false
    @State private var showingDatePicker = false
    @State private var moveTargetDate: Date = Date()

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if inboxNotes.isEmpty {
                    VStack {
                        Spacer()
                        Image(systemName: "tray")
                            .font(.largeTitle).foregroundStyle(.secondary)
                        Text("No pending notes")
                            .foregroundStyle(.secondary).padding(.top, 8)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    List {
                        ForEach(inboxNotes) { note in
                            InboxNoteRow(note: note)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    actionNote = note
                                    showingActions = true
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button("Delete", role: .destructive) { delete(note) }
                                }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Inbox")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        withAnimation(.easeInOut(duration: 0.3)) { isShowing = false }
                    }
                    .bold()
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    if !inboxNotes.isEmpty {
                        Text("\(inboxNotes.count) item\(inboxNotes.count == 1 ? "" : "s")")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .confirmationDialog("What would you like to do?", isPresented: $showingActions, titleVisibility: .visible) {
            if let note = actionNote {
                Button("Add to Today's Note") { addToTodayNote(note) }
                Button("Move to Another Date…") {
                    moveTargetDate = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
                    showingDatePicker = true
                }
                Button("Move to Bucket Note…") { showingBucketPicker = true }
                Button("Move to Project Note…") { showingProjectPicker = true }
                // If the capture already has a place attached, route directly — no picker needed.
                if let placeName = note.placeNameInBody {
                    Button("Move to \(placeName)") {
                        moveToPlaceNoteDirectly(note, placeName: placeName)
                    }
                } else {
                    Button("Move to Place Note…") {
                        selectedPlaceForMove = nil
                        showingPlacePicker = true
                    }
                }
                Button("Delete", role: .destructive) { delete(note) }
                Button("Cancel", role: .cancel) { }
            }
        }
        // Date picker sheet
        .sheet(isPresented: $showingDatePicker) {
            InboxMoveDateSheet(targetDate: $moveTargetDate) {
                if let note = actionNote { moveToDailyNote(note, date: moveTargetDate) }
                showingDatePicker = false
            }
        }
        // Bucket picker sheet
        .sheet(isPresented: $showingBucketPicker) {
            InboxNoteFilePickerSheet(subfolder: "Notes/Buckets", title: "Move to Bucket") { filename in
                if let note = actionNote { moveToFile(note, path: "Notes/Buckets/\(filename)") }
                showingBucketPicker = false
            }
        }
        // Project picker sheet
        .sheet(isPresented: $showingProjectPicker) {
            InboxNoteFilePickerSheet(subfolder: "Notes/Projects", title: "Move to Project") { filename in
                if let note = actionNote { moveToFile(note, path: "Notes/Projects/\(filename)") }
                showingProjectPicker = false
            }
        }
        // Place picker sheet
        .sheet(isPresented: $showingPlacePicker, onDismiss: {
            // Fires after PlacePickerView dismisses — place is set if user made a selection.
            guard let place = selectedPlaceForMove, let note = actionNote else {
                selectedPlaceForMove = nil
                return
            }
            moveToPlaceNote(note, placeName: place.name)
            selectedPlaceForMove = nil
        }) {
            PlacePickerView(selectedPlace: $selectedPlaceForMove)
                .environment(notion)
                .environment(LocationManager.shared)
        }
        .gesture(
            DragGesture(minimumDistance: 30, coordinateSpace: .local)
                .onEnded { value in
                    if value.translation.width > 50 {
                        withAnimation(.easeInOut(duration: 0.3)) { isShowing = false }
                    }
                }
        )
        .task { await loadInbox() }
    }

    // MARK: - Data

    private func loadInbox() async {
        let files = (try? NoteStore.shared.listFiles(in: "Notes/Inbox")) ?? []
        var notes: [InboxNote] = []
        for filename in files.reversed() {  // newest first (listFiles returns sorted ascending)
            let content = (try? NoteStore.shared.readFile("Notes/Inbox/\(filename)")) ?? ""
            if let note = InboxNote(filename: filename, content: content) {
                notes.append(note)
            }
        }
        await MainActor.run {
            inboxNotes = notes
            isLoading = false
        }
    }

    // MARK: - Actions

    private func addToTodayNote(_ note: InboxNote) {
        Task {
            try? NoteStore.shared.appendToDailyNote(note.bodyContent)
            try? NoteStore.shared.deleteFile("Notes/Inbox/\(note.filename)")
            await MainActor.run { inboxNotes.removeAll { $0.id == note.id } }
        }
    }

    private func moveToDailyNote(_ note: InboxNote, date: Date) {
        Task {
            try? NoteStore.shared.appendToDailyNote(note.bodyContent, date: date)
            try? NoteStore.shared.deleteFile("Notes/Inbox/\(note.filename)")
            await MainActor.run { inboxNotes.removeAll { $0.id == note.id } }
        }
    }

    /// Moves inbox note body to any NoteStore file path, appending if the file exists.
    private func moveToFile(_ note: InboxNote, path: String) {
        Task {
            let existing = (try? NoteStore.shared.readFile(path)) ?? ""
            let body = note.bodyContent
            let updated = existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? body
                : existing + "\n\n" + body
            try? NoteStore.shared.writeFile(path, content: updated)
            try? NoteStore.shared.deleteFile("Notes/Inbox/\(note.filename)")
            await MainActor.run { inboxNotes.removeAll { $0.id == note.id } }
        }
    }

    /// Moves a capture to a place note, stripping any embedded **Place:** metadata line.
    private func moveToPlaceNote(_ note: InboxNote, placeName: String) {
        Task {
            let body = note.bodyWithoutPlace.isEmpty ? note.bodyContent : note.bodyWithoutPlace
            try? NoteStore.shared.appendToPlaceNote(for: placeName, text: "\n" + body)
            try? NoteStore.shared.deleteFile("Notes/Inbox/\(note.filename)")
            await MainActor.run { inboxNotes.removeAll { $0.id == note.id } }
        }
    }

    /// Direct route when the capture already carries a place in its body — no picker needed.
    private func moveToPlaceNoteDirectly(_ note: InboxNote, placeName: String) {
        moveToPlaceNote(note, placeName: placeName)
    }

    private func delete(_ note: InboxNote) {
        Task {
            try? NoteStore.shared.deleteFile("Notes/Inbox/\(note.filename)")
            await MainActor.run { inboxNotes.removeAll { $0.id == note.id } }
        }
    }
}

// MARK: - InboxMoveDateSheet

private struct InboxMoveDateSheet: View {
    @Binding var targetDate: Date
    let onMove: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            DatePicker("Select date", selection: $targetDate, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .padding()
            Spacer()
            .navigationTitle("Move to Date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Move") {
                        onMove()
                        dismiss()
                    }
                    .bold()
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - InboxNoteFilePickerSheet
// Lists all files in a NoteStore subfolder so the user can pick one to append to.
// A "New…" option creates the file on the spot.

private struct InboxNoteFilePickerSheet: View {
    let subfolder: String
    let title: String
    let onSelect: (String) -> Void

    @State private var files: [String] = []
    @State private var isLoading = true
    @State private var showingNewName = false
    @State private var newName = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        Button {
                            showingNewName = true
                        } label: {
                            Label("New note…", systemImage: "plus")
                                .foregroundStyle(Color.accentColor)
                        }
                        ForEach(files, id: \.self) { filename in
                            Button {
                                onSelect(filename)
                                dismiss()
                            } label: {
                                Text(filename.replacingOccurrences(of: ".md", with: ""))
                                    .foregroundStyle(.primary)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert("New note", isPresented: $showingNewName) {
                TextField("Name", text: $newName)
                Button("Create") {
                    let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    let filename = "\(name).md"
                    try? NoteStore.shared.writeFile("\(subfolder)/\(filename)", content: "# \(name)\n")
                    onSelect(filename)
                    dismiss()
                }
                Button("Cancel", role: .cancel) { newName = "" }
            } message: {
                Text("Enter a name for the new note.")
            }
        }
        .task {
            files = (try? NoteStore.shared.listFiles(in: subfolder)) ?? []
            isLoading = false
        }
    }
}

// MARK: - InboxNoteRow

private struct InboxNoteRow: View {
    let note: InboxNote

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: note.hasPhoto ? "photo" : "note.text")
                .foregroundStyle(note.hasPhoto ? Color.blue : Color.secondary)
                .font(.title3)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(note.previewLine)
                    .lineLimit(2)
                    .foregroundStyle(.primary)
                Text(note.date, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - PlacePickerSheet
// Still used by CreateVisitFromCaptureView and other call sites.

struct PlacePickerSheet: View {
    let currentPlaceID: String?
    let onSelect: (Place) -> Void
    @Environment(NotionService.self) private var notion
    @Environment(\.dismiss) private var dismiss
    @State private var searchText: String = ""

    private var filtered: [Place] {
        let all = notion.places.filter { $0.status != "Archived" }
        if searchText.isEmpty { return all.sorted { $0.name < $1.name } }
        let q = searchText.lowercased()
        return all
            .filter { $0.name.lowercased().contains(q) || $0.city.lowercased().contains(q) }
            .sorted { $0.name < $1.name }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(filtered, id: \.id) { place in
                    PlacePickerRow(place: place, isSelected: currentPlaceID == place.id) {
                        onSelect(place)
                        dismiss()
                    }
                }
            }
            .searchable(text: $searchText,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search places")
            .navigationTitle("Select Place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

private struct PlacePickerRow: View {
    let place: Place
    let isSelected: Bool
    let onTap: () -> Void

    var subtitle: String {
        place.category.isEmpty ? place.city : "\(place.category) · \(place.city)"
    }

    var body: some View {
        Button(action: onTap) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(place.name).foregroundStyle(.primary)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
