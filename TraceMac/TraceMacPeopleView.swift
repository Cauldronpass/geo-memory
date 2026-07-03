// TraceMacPeopleView.swift
// Browse people, view detail, log interactions, manage agenda — Mac.
// Mac-only — do not add to iOS, Widget, or Share Extension targets.

import SwiftUI

// MARK: - Root

struct TraceMacPeopleView: View {

    @Environment(NotionService.self) private var notionService

    @State private var selectedID: String? = nil
    @State private var searchText = ""
    @State private var detail: PersonDetail? = nil
    @State private var interactions: [Interaction] = []
    @State private var isLoading = false
    @State private var showLogSheet = false

    private var filteredPeople: [Person] {
        let sorted = notionService.people.sorted { $0.name < $1.name }
        guard !searchText.isEmpty else { return sorted }
        return sorted.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        HSplitView {
            peopleList
            if isLoading {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let d = detail {
                HSplitView {
                    personDetail(d)
                    MacAgendaPanel(detail: d, notionService: notionService) {
                        showLogSheet = true
                    }
                    .frame(minWidth: 220, maxWidth: 260)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 52, weight: .ultraLight))
                        .foregroundStyle(.tertiary)
                    Text("Select a person")
                        .font(.title3).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar {
            if detail != nil {
                ToolbarItem {
                    Button { showLogSheet = true } label: {
                        Label("Log Interaction", systemImage: "bubble.left.and.bubble.right")
                    }
                    .keyboardShortcut("l", modifiers: .command)
                }
            }
        }
        .sheet(isPresented: $showLogSheet) {
            if let d = detail {
                MacLogInteractionSheet(person: d, notionService: notionService) { newInteraction in
                    interactions.insert(newInteraction, at: 0)
                }
            }
        }
        .task {
            if notionService.people.isEmpty {
                await notionService.fetchPeople()
            }
        }
        .onChange(of: selectedID) { _, newID in
            guard let id = newID else { detail = nil; interactions = []; return }
            Task { await loadDetail(id: id) }
        }
    }

    // MARK: - People list

    private var peopleList: some View {
        VStack(spacing: 0) {
            TextField("Search", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(10)
            Divider()
            if filteredPeople.isEmpty {
                Spacer()
                Text(notionService.people.isEmpty ? "No people yet." : "No matches.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
            } else {
                List(filteredPeople, selection: $selectedID) { person in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(person.name)
                            .font(.system(.body, weight: .medium))
                        if let rel = person.relationship {
                            Text(rel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 3)
                    .tag(person.id)
                }
                .listStyle(.sidebar)
            }
        }
        .frame(minWidth: 200, maxWidth: 240)
    }

    // MARK: - Person detail

    private func personDetail(_ d: PersonDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                // Hero block
                VStack(alignment: .leading, spacing: 6) {
                    Text(d.name)
                        .font(.system(size: 26, weight: .semibold))

                    HStack(spacing: 12) {
                        if let rel = d.relationship {
                            Text(rel).font(.subheadline).foregroundStyle(.secondary)
                        }
                        if let co = d.companyContext {
                            Text("·").foregroundStyle(.tertiary)
                            Text(co).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }

                    if let last = d.lastInteractionDate {
                        let days = Calendar.current.dateComponents([.day], from: last, to: Date()).day ?? 0
                        Text(days == 0 ? "Seen today"
                             : days == 1 ? "Seen yesterday"
                             : "Last seen \(days) days ago")
                            .font(.caption).foregroundStyle(.tertiary)
                    }

                    if !d.tags.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(d.tags, id: \.self) { tag in
                                    Text(tag)
                                        .font(.caption)
                                        .padding(.horizontal, 8).padding(.vertical, 3)
                                        .background(Color.accentColor.opacity(0.1))
                                        .foregroundStyle(Color.accentColor)
                                        .clipShape(Capsule())
                                }
                            }
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)

                Divider()

                // Contact info
                if d.phone != nil || d.email != nil || d.city != nil {
                    VStack(alignment: .leading, spacing: 10) {
                        if let phone = d.phone {
                            contactRow(icon: "phone", value: phone)
                        }
                        if let email = d.email {
                            contactRow(icon: "envelope", value: email)
                        }
                        if let city = d.city {
                            contactRow(icon: "mappin", value: city)
                        }
                    }
                    .padding(20)
                    Divider()
                }

                // Interactions
                VStack(alignment: .leading, spacing: 12) {
                    Text("Interactions")
                        .font(.system(.headline, weight: .semibold))
                        .foregroundStyle(.primary)

                    if interactions.isEmpty {
                        Text("No interactions logged yet.")
                            .font(.callout).foregroundStyle(.tertiary)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(interactions.prefix(10)) { ix in
                                MacInteractionRow(interaction: ix)
                                    .padding(.vertical, 10)
                                if ix.id != interactions.prefix(10).last?.id {
                                    Divider()
                                }
                            }
                        }
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.15))
                        )
                    }
                }
                .padding(20)
            }
        }
        .frame(minWidth: 340)
    }

    private func contactRow(icon: String, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .frame(width: 18)
                .foregroundStyle(.secondary)
                .font(.callout)
            Text(value)
                .font(.callout)
        }
    }

    // MARK: - Load

    private func loadDetail(id: String) async {
        isLoading = true
        detail = nil
        interactions = []
        do {
            async let d = notionService.fetchPersonDetail(id: id)
            async let i = notionService.fetchInteractions(personID: id)
            let (fd, fi) = try await (d, i)
            detail = fd
            interactions = fi
        } catch { }
        isLoading = false
    }
}

// MARK: - Interaction row

struct MacInteractionRow: View {
    let interaction: Interaction

    private var typeColor: Color {
        switch interaction.type.lowercased() {
        case "call":       return .green
        case "email":      return .blue
        case "meeting":    return .orange
        case "coffee":     return .brown
        case "visit":      return .purple
        case "social":     return .pink
        default:           return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Text(interaction.type.capitalized)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(typeColor.opacity(0.12))
                    .foregroundStyle(typeColor)
                    .clipShape(Capsule())
                Spacer()
                Text(interaction.date, style: .date)
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            if !interaction.summary.isEmpty {
                Text(interaction.summary)
                    .font(.system(.callout, weight: .medium))
                    .lineLimit(2)
            }
            if let notes = interaction.notes, !notes.isEmpty {
                Text(notes)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - Agenda panel

struct MacAgendaPanel: View {
    let detail: PersonDetail
    let notionService: NotionService
    let onLog: () -> Void

    @State private var items: [String] = []
    @State private var newItem = ""
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Header
            HStack {
                Text("Agenda")
                    .font(.system(.headline, weight: .semibold))
                Spacer()
                Button { onLog() } label: {
                    Image(systemName: "plus.bubble")
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Log Interaction (⌘L)")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            // Add field
            HStack(spacing: 6) {
                TextField("Add item…", text: $newItem)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
                    .onSubmit { addItem() }
                Button(action: addItem) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title3)
                        .foregroundStyle(newItem.trimmingCharacters(in: .whitespaces).isEmpty
                                         ? Color.secondary.opacity(0.4) : Color.accentColor)
                }
                .buttonStyle(.plain)
                .disabled(newItem.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
            }
            .padding(10)

            Divider()

            if items.isEmpty {
                Spacer()
                VStack(spacing: 6) {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 24, weight: .ultraLight))
                        .foregroundStyle(.tertiary)
                    Text("Nothing queued")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "circle.fill")
                                    .font(.system(size: 5))
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 6)
                                Text(item)
                                    .font(.callout)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer()
                                Button {
                                    items.remove(at: idx)
                                    save()
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            if idx < items.count - 1 {
                                Divider().padding(.leading, 28)
                            }
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            items = (detail.agenda ?? "")
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
    }

    private func addItem() {
        let text = newItem.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        items.append(text)
        newItem = ""
        save()
    }

    private func save() {
        isSaving = true
        let joined = items.joined(separator: "\n")
        Task {
            try? await notionService.updatePersonAgenda(id: detail.id, agenda: joined)
            isSaving = false
        }
    }
}

// MARK: - Log Interaction sheet

struct MacLogInteractionSheet: View {
    let person: PersonDetail
    let notionService: NotionService
    let onSave: (Interaction) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var type = "meeting"
    @State private var date = Date()
    @State private var summary = ""
    @State private var notes = ""
    @State private var isSaving = false
    @State private var error: String? = nil

    private let types = ["meeting", "call", "email", "coffee", "social", "other"]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Log Interaction")
                        .font(.headline)
                    Text("with \(person.name)")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()

            Divider()

            Form {
                Section {
                    Picker("Type", selection: $type) {
                        ForEach(types, id: \.self) { t in
                            Text(t.capitalized).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    TextField("Summary (optional)", text: $summary)
                }
                Section("Notes") {
                    TextEditor(text: $notes)
                        .font(.system(size: 13))
                        .frame(minHeight: 80)
                }
            }
            .formStyle(.grouped)

            if let err = error {
                Text(err).font(.caption).foregroundStyle(.red).padding(.horizontal)
            }

            Divider()

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                if isSaving { ProgressView().controlSize(.small) }
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .padding()
        }
        .frame(width: 480, height: 400)
    }

    private func save() {
        isSaving = true
        error = nil
        Task {
            do {
                let ix = try await notionService.createInteraction(
                    personID: person.id,
                    summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
                    date: date,
                    type: type,
                    notes: notes
                )
                await MainActor.run { onSave(ix); dismiss() }
            } catch {
                self.error = "Save failed — check your connection."
            }
            isSaving = false
        }
    }
}
