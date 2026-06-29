import SwiftUI
import UniformTypeIdentifiers

// MARK: - DocDestination

enum DocDestination: String, CaseIterable {
    case inbox   = "Inbox"
    case today   = "Today"
    case project = "Project"
    case place   = "Place"
}

// MARK: - AddDocumentView
//
// Imports a document and saves it to NoteStore iCloud container.
//
// PDF / image / other files:
//   → file stored at Documents/Inbox/<timestamp>-<filename>
//   → 📎 link written to the chosen destination note
//   → falls back to Notes/Inbox/<timestamp>.md if destination can't be resolved
//
// Markdown (.md) files:
//   → imported directly as Notes/Inbox/<timestamp>-<title>.md
//   → destination picker not shown (always Inbox for .md)
//
// Entry points:
//   • FAB "Add Document" in ContentView — starts at file picker
//   • trace://adddocument URL scheme — starts at file picker
//   • Share Extension handoff via AppGroup — starts at save form with file pre-loaded

struct AddDocumentView: View {

    var incomingDocument: IncomingDocument? = nil

    @Environment(\.dismiss) private var dismiss

    @State private var showingFilePicker = false

    // File state
    @State private var selectedURL: URL?
    @State private var preloadedData: Data?
    @State private var preloadedFilename: String = ""
    @State private var fileSize: String = ""

    @State private var documentTitle: String = ""
    @State private var notes = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    // Destination
    @State private var destination: DocDestination = .inbox

    // Project picker state
    @State private var projectSearch: String = ""
    @State private var confirmedProject: String = ""
    @State private var existingProjects: [String] = []

    // Place picker state
    @State private var placeSearch: String = ""
    @State private var confirmedPlace: String = ""

    private var hasFile: Bool { selectedURL != nil || preloadedData != nil }

    private var effectiveExtension: String {
        if let url = selectedURL { return url.pathExtension.lowercased() }
        return (preloadedFilename as NSString).pathExtension.lowercased()
    }

    private var isMarkdown: Bool { effectiveExtension == "md" }

    // MARK: - Filtered lists

    private var filteredProjects: [String] {
        let q = projectSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return existingProjects }
        return existingProjects.filter { $0.localizedCaseInsensitiveContains(q) }
    }

    private var filteredPlaces: [String] {
        let allNames = NotionService.shared.places.map { $0.name }.sorted()
        let q = placeSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return allNames }
        return allNames.filter { $0.localizedCaseInsensitiveContains(q) }
    }

    private var projectSearchHasExactMatch: Bool {
        let q = projectSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return existingProjects.contains { $0.lowercased() == q }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Group {
                if !hasFile {
                    pickPrompt
                } else {
                    saveForm
                }
            }
            .navigationTitle(hasFile ? (isMarkdown ? "Import Note" : "Save Document") : "Add Document")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if hasFile {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Back") { clearFile() }
                    }
                }
            }
            .fileImporter(
                isPresented: $showingFilePicker,
                allowedContentTypes: [.pdf, .png, .jpeg, .tiff, .plainText, .item],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    selectedURL = url
                    preloadedData = nil
                    if documentTitle.isEmpty {
                        documentTitle = url.deletingPathExtension().lastPathComponent
                    }
                    fileSize = computeFileSize(url)
                }
            }
            .onAppear {
                if let incoming = incomingDocument, preloadedData == nil {
                    preloadedData = incoming.data
                    preloadedFilename = incoming.filename
                    fileSize = ByteCountFormatter.string(
                        fromByteCount: Int64(incoming.data.count), countStyle: .file)
                    if documentTitle.isEmpty {
                        documentTitle = (incoming.originalName as NSString).deletingPathExtension
                    }
                }
                loadExistingProjects()
            }
        }
    }

    // MARK: - Pick prompt

    private var pickPrompt: some View {
        Form {
            Section {
                Button {
                    showingFilePicker = true
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "doc.badge.plus")
                            .font(.title2)
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Choose File").foregroundStyle(.primary)
                            Text("PDF, images, text, markdown — saved to iCloud")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.tertiary).font(.caption)
                    }
                }
            }
        }
    }

    // MARK: - Save form

    private var saveForm: some View {
        Form {
            // File info
            Section {
                HStack(spacing: 12) {
                    Image(systemName: iconName)
                        .font(.system(size: 30))
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(displayFilename)
                            .font(.subheadline)
                            .lineLimit(2)
                        if !fileSize.isEmpty {
                            Text(fileSize).font(.caption).foregroundStyle(.secondary)
                        }
                        if isMarkdown {
                            Text("Will be imported as a note")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
                if incomingDocument == nil {
                    Button("Change File") { showingFilePicker = true }
                        .font(.subheadline)
                }
            }

            // Title
            Section("Title") {
                TextField("Document title", text: $documentTitle)
            }

            // Destination — not shown for .md
            if !isMarkdown {
                Section("Save to") {
                    Picker("Destination", selection: $destination) {
                        ForEach(DocDestination.allCases, id: \.self) { dest in
                            Text(dest.rawValue).tag(dest)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: destination) { _, _ in
                        confirmedProject = ""
                        confirmedPlace = ""
                        projectSearch = ""
                        placeSearch = ""
                    }
                }

                // Project sub-picker
                if destination == .project {
                    Section {
                        HStack {
                            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                            TextField("Search projects…", text: $projectSearch)
                                .autocorrectionDisabled()
                        }

                        if !confirmedProject.isEmpty {
                            HStack {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                Text(confirmedProject).bold()
                                Spacer()
                                Button("Clear") {
                                    confirmedProject = ""
                                    projectSearch = ""
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        } else {
                            // Filtered results
                            ForEach(filteredProjects, id: \.self) { name in
                                Button {
                                    confirmedProject = name
                                    projectSearch = name
                                } label: {
                                    Text(name).foregroundStyle(.primary)
                                }
                            }

                            // Create new option
                            let q = projectSearch.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !q.isEmpty && !projectSearchHasExactMatch {
                                Button {
                                    confirmedProject = q
                                } label: {
                                    Label("Create \"\(q)\"", systemImage: "plus.circle")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }

                            // Inbox escape
                            if filteredProjects.isEmpty && projectSearch.isEmpty {
                                Text("No projects yet — type a name to create one")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }

                        Button("Save to Inbox instead") {
                            destination = .inbox
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    } header: {
                        Text("Project")
                    }
                }

                // Place sub-picker
                if destination == .place {
                    Section {
                        HStack {
                            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                            TextField("Search places…", text: $placeSearch)
                                .autocorrectionDisabled()
                        }

                        if !confirmedPlace.isEmpty {
                            HStack {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                Text(confirmedPlace).bold()
                                Spacer()
                                Button("Clear") {
                                    confirmedPlace = ""
                                    placeSearch = ""
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        } else {
                            ForEach(filteredPlaces, id: \.self) { name in
                                Button {
                                    confirmedPlace = name
                                    placeSearch = name
                                } label: {
                                    Text(name).foregroundStyle(.primary)
                                }
                            }

                            if filteredPlaces.isEmpty {
                                Text(placeSearch.isEmpty ? "No places loaded" : "No matches")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }

                        Button("Save to Inbox instead") {
                            destination = .inbox
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    } header: {
                        Text("Place")
                    }
                }

                Section("Note (optional)") {
                    TextField("Add a note…", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                }
            }

            if let err = errorMessage {
                Section {
                    Text(err).foregroundStyle(.red).font(.caption)
                }
            }

            Section {
                Button {
                    Task { await save() }
                } label: {
                    if isSaving {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    } else {
                        Text(isMarkdown ? "Import as Note" : "Save")
                            .frame(maxWidth: .infinity).bold()
                    }
                }
                .disabled(isSaving || saveBlocked)
            }

            Section {
                HStack {
                    Image(systemName: "icloud").foregroundStyle(.blue)
                    Text(destinationSummary)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Destination summary

    private var saveBlocked: Bool {
        switch destination {
        case .project: return confirmedProject.isEmpty
        case .place:   return confirmedPlace.isEmpty
        default:       return false
        }
    }

    private var destinationSummary: String {
        if isMarkdown { return "Saved to Notes/Inbox in iCloud" }
        switch destination {
        case .inbox:   return "Saved to Notes/Inbox in iCloud"
        case .today:   return "Appended to today's note in iCloud"
        case .project: return confirmedProject.isEmpty ? "Select or create a project above" : "Appended to Notes/Projects/\(confirmedProject)"
        case .place:   return confirmedPlace.isEmpty ? "Select a place above" : "Appended to \(confirmedPlace) place note"
        }
    }

    // MARK: - Helpers

    private var displayFilename: String {
        selectedURL?.lastPathComponent ?? preloadedFilename
    }

    private var iconName: String {
        switch effectiveExtension {
        case "pdf":                                 return "doc.richtext"
        case "png", "jpg", "jpeg", "tiff", "heic": return "photo"
        case "txt":                                 return "doc.text"
        case "md":                                  return "note.text"
        default:                                    return "doc.fill"
        }
    }

    private func clearFile() {
        selectedURL = nil
        preloadedData = nil
        preloadedFilename = ""
        fileSize = ""
        destination = .inbox
        confirmedProject = ""
        confirmedPlace = ""
        projectSearch = ""
        placeSearch = ""
    }

    private func computeFileSize(_ url: URL) -> String {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else { return "" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    private func loadExistingProjects() {
        let names = (try? NoteStore.shared.listFiles(in: "Notes/Projects"))?.compactMap { filename -> String? in
            let name = (filename as NSString).deletingPathExtension
            return name.isEmpty ? nil : name
        }.sorted() ?? []
        existingProjects = names
    }

    // MARK: - Save

    private func save() async {
        isSaving = true
        errorMessage = nil

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let timestamp = formatter.string(from: Date())

        do {
            let data: Data
            let filename: String

            if let preloaded = preloadedData {
                data = preloaded
                filename = preloadedFilename
            } else if let url = selectedURL {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                data = try Data(contentsOf: url)
                let safe = url.lastPathComponent
                    .components(separatedBy: .whitespacesAndNewlines)
                    .joined(separator: "-")
                filename = "\(timestamp)-\(safe)"
            } else {
                isSaving = false
                return
            }

            let title = documentTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? (filename as NSString).deletingPathExtension
                : documentTitle.trimmingCharacters(in: .whitespacesAndNewlines)

            if isMarkdown {
                let rawText = String(data: data, encoding: .utf8) ?? ""
                let noteContent = rawText.hasPrefix("# ") ? rawText : "# \(title)\n\n\(rawText)"
                let safeName = title
                    .components(separatedBy: .whitespacesAndNewlines)
                    .joined(separator: "-")
                    .replacingOccurrences(of: "/", with: "-")
                try NoteStore.shared.writeFile(
                    "Notes/Inbox/\(timestamp)-\(safeName).md",
                    content: noteContent
                )
            } else {
                let docPath = try NoteStore.shared.writeDocument(
                    data, category: "Inbox", filename: filename)

                let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
                var linkLines = ["📎 [\(title)](\(docPath))", "", "**Saved:** \(timestamp)"]
                if !trimmedNotes.isEmpty { linkLines += ["", trimmedNotes] }
                let linkBlock = linkLines.joined(separator: "\n")

                try writeToDestination(title: title, timestamp: timestamp, linkBlock: linkBlock)
            }

            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            isSaving = false
        }
    }

    private func writeToDestination(title: String, timestamp: String, linkBlock: String) throws {
        switch destination {

        case .inbox:
            try writeInbox(title: title, timestamp: timestamp, linkBlock: linkBlock)

        case .today:
            do {
                try NoteStore.shared.appendToDailyNote("\n" + linkBlock)
            } catch {
                try writeInbox(title: title, timestamp: timestamp, linkBlock: linkBlock)
            }

        case .project:
            do {
                let safe = confirmedProject
                    .components(separatedBy: .whitespacesAndNewlines).joined(separator: "-")
                    .replacingOccurrences(of: "/", with: "-")
                let projPath = "Notes/Projects/\(safe).md"
                let existing = (try? NoteStore.shared.readFile(projPath)) ?? "# \(confirmedProject)\n\n"
                let sep = existing.hasSuffix("\n\n") ? "" : existing.hasSuffix("\n") ? "\n" : "\n\n"
                try NoteStore.shared.writeFile(projPath, content: existing + sep + linkBlock + "\n")
            } catch {
                try writeInbox(title: title, timestamp: timestamp, linkBlock: linkBlock)
            }

        case .place:
            do {
                try NoteStore.shared.appendToPlaceNote(for: confirmedPlace, text: linkBlock)
            } catch {
                try writeInbox(title: title, timestamp: timestamp, linkBlock: linkBlock)
            }
        }
    }

    private func writeInbox(title: String, timestamp: String, linkBlock: String) throws {
        let lines = ["# \(title)", "", linkBlock]
        try NoteStore.shared.writeFile(
            "Notes/Inbox/\(timestamp).md",
            content: lines.joined(separator: "\n")
        )
    }
}
