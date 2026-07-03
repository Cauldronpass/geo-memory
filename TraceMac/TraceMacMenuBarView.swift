// TraceMacMenuBarView.swift
// Menu bar quick-entry panel — capture a note from any app without switching windows.
// Mac-only — do not add to iOS, Widget, or Share Extension targets.

import SwiftUI

enum MenuBarDestination: String, CaseIterable {
    case daily   = "Daily Note"
    case inbox   = "Inbox"
    case project = "Project"
    case agenda  = "Person Agenda"
}

struct TraceMacMenuBarView: View {

    @Environment(NoteStore.self)     private var noteStore
    @Environment(NotionService.self) private var notionService

    @State private var text = ""
    @State private var destination: MenuBarDestination = .daily
    @State private var selectedProject: String? = nil
    @State private var selectedPersonID: String? = nil
    @State private var isSaving = false
    @State private var savedMessage: String? = nil

    // Projects list: filenames in Notes/Projects/
    @State private var projects: [String] = []

    var body: some View {
        VStack(spacing: 0) {

            // Destination row
            HStack(spacing: 6) {
                ForEach(MenuBarDestination.allCases, id: \.self) { d in
                    Button(d.rawValue) { destination = d }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(destination == d
                                    ? Color.accentColor.opacity(0.15) : Color.clear)
                        .foregroundStyle(destination == d
                                         ? Color.accentColor : Color.secondary)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 6)

            // Secondary picker (Project or Person)
            if destination == .project {
                Picker("Project", selection: $selectedProject) {
                    Text("Pick a project…").tag(String?.none)
                    ForEach(projects, id: \.self) { p in
                        Text(p.replacingOccurrences(of: ".md", with: "")).tag(String?.some(p))
                    }
                }
                .labelsHidden()
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            } else if destination == .agenda {
                Picker("Person", selection: $selectedPersonID) {
                    Text("Pick a person…").tag(String?.none)
                    ForEach(notionService.people.sorted { $0.name < $1.name }) { p in
                        Text(p.name).tag(String?.some(p.id))
                    }
                }
                .labelsHidden()
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            }

            // Text entry
            TextEditor(text: $text)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.25))
                )
                .padding(.horizontal, 10)
                .frame(minHeight: 90, maxHeight: 120)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Type a note…")
                            .font(.system(size: 14))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 18)
                            .padding(.top, 16)
                            .allowsHitTesting(false)
                    }
                }

            // Footer
            HStack {
                if let msg = savedMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isSaving {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Save") { save() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || (destination == .project && selectedProject == nil)
                                  || (destination == .agenda && selectedPersonID == nil))
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .padding(10)
        }
        .frame(width: 340)
        .task {
            projects = (try? noteStore.listFiles(in: "Notes/Projects")) ?? []
            if notionService.people.isEmpty { await notionService.fetchPeople() }
        }
    }

    // MARK: - Save

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSaving = true

        Task {
            do {
                switch destination {
                case .daily:
                    try appendToDaily(trimmed)
                case .inbox:
                    try createInboxNote(trimmed)
                case .project:
                    if let proj = selectedProject {
                        try appendToProject(trimmed, filename: proj)
                    }
                case .agenda:
                    if let pid = selectedPersonID {
                        try await appendToAgenda(trimmed, personID: pid)
                    }
                }
                await MainActor.run {
                    text = ""
                    savedMessage = "Saved ✓"
                    isSaving = false
                }
                try? await Task.sleep(for: .seconds(2))
                await MainActor.run { savedMessage = nil }
            } catch {
                await MainActor.run {
                    savedMessage = "Save failed"
                    isSaving = false
                }
            }
        }
    }

    // MARK: - Routing

    private func appendToDaily(_ text: String) throws {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let filename = "\(fmt.string(from: Date())).md"
        let path = "Calendar/\(filename)"
        var existing = (try? noteStore.readFile(path)) ?? ""
        if existing.isEmpty {
            existing = "# \(fmt.string(from: Date()))\n\n"
        }
        existing += "\n- \(text)"
        try noteStore.writeFile(path, content: existing)
    }

    private func createInboxNote(_ text: String) throws {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd-HHmmss"
        let filename = "\(fmt.string(from: Date())).md"
        try noteStore.writeFile("Notes/Inbox/\(filename)", content: "# Inbox\n\n\(text)\n")
    }

    private func appendToProject(_ text: String, filename: String) throws {
        let path = "Notes/Projects/\(filename)"
        var existing = (try? noteStore.readFile(path)) ?? ""
        if existing.isEmpty {
            let name = filename.replacingOccurrences(of: ".md", with: "")
            existing = "# \(name)\n\n"
        }
        existing += "\n- \(text)"
        try noteStore.writeFile(path, content: existing)
    }

    private func appendToAgenda(_ text: String, personID: String) async throws {
        let detail = try await notionService.fetchPersonDetail(id: personID)
        var lines = (detail.agenda ?? "")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        lines.append(text)
        try await notionService.updatePersonAgenda(id: personID, agenda: lines.joined(separator: "\n"))
    }
}
