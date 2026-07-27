import SwiftUI

// MARK: - Life tab — retired (Session 48, Trace redesign)
//
// Session 47 addendum locked the removal: the Life tab's menu (Activity
// calendar, Trips placeholder, Fitness, Billiards, People) is gone as a
// screen. Fitness and Billiards are now reached from Home's Jump To tiles
// straight into the existing FitnessView/BilliardsView (unchanged). People is
// promoted to its own top-level tab — see PeopleView.swift (formerly
// LifePeopleView, moved out of this file). The Trips placeholder is retired
// in favor of the new Endeavor system (not yet built — Session 47 addendum).
// The Activity calendar (`LifeCalendarView` + its Day*/MixedDayPicker sheets)
// had no addendum-specified new home and is dropped outright — nothing else
// in the app referenced it (confirmed via grep across the Trace target
// before removal).
//
// What's left in this file: three shared sheets the app-wide FAB (see
// ContentView.swift's fabPeopleButtons) still opens regardless of which tab
// you're on — these were never Life-tab-specific, just declared in the same
// file historically. Kept in place rather than moved, to minimize the diff.

// MARK: - FAB: Log Interaction (people picker + type + notes)

struct FABLogInteractionSheet: View {
    @Environment(NotionService.self) private var notion
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""
    @State private var selectedPerson: Person? = nil
    @State private var selectedType = "call"
    @State private var date = Date()
    @State private var notes = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    private let typeOptions = ["call", "email", "meeting", "coffee", "social", "other"]

    private var filteredPeople: [Person] {
        searchText.isEmpty ? notion.people
            : notion.people.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            if selectedPerson == nil {
                // Step 1: pick person
                List {
                    ForEach(filteredPeople) { person in
                        Button {
                            selectedPerson = person
                        } label: {
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(Color.purple.opacity(0.15))
                                    .frame(width: 32, height: 32)
                                    .overlay(
                                        Text(String(person.name.prefix(1)))
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundStyle(.purple)
                                    )
                                Text(person.name).foregroundStyle(.primary)
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .searchable(text: $searchText, prompt: "Search people")
                .navigationTitle("Log Interaction")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
            } else {
                // Step 2: log details
                Form {
                    Section {
                        Button { selectedPerson = nil } label: {
                            HStack {
                                Text(selectedPerson!.name).foregroundStyle(.primary)
                                Spacer()
                                Text("Change").font(.caption).foregroundStyle(.blue)
                            }
                        }
                        .buttonStyle(.plain)
                    } header: { Text("Person") }

                    Section("Type") {
                        Picker("Type", selection: $selectedType) {
                            ForEach(typeOptions, id: \.self) { Text($0.capitalized).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    }
                    Section("Date") {
                        DatePicker("", selection: $date, displayedComponents: .date)
                            .datePickerStyle(.compact).labelsHidden()
                    }
                    Section("Notes (optional)") {
                        ZStack(alignment: .topLeading) {
                            TextEditor(text: $notes).frame(minHeight: 80)
                            if notes.isEmpty {
                                Text("What did you talk about?")
                                    .foregroundStyle(Color(.placeholderText))
                                    .font(.body).padding(.top, 8).padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                    if let err = errorMessage {
                        Section { Text(err).foregroundStyle(.red).font(.caption) }
                    }
                }
                .navigationTitle("Log Interaction")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        if isSaving { ProgressView().scaleEffect(0.8) }
                        else { Button("Save") { save() } }
                    }
                }
            }
        }
    }

    private func save() {
        guard let person = selectedPerson else { return }
        isSaving = true
        Task {
            do {
                try await notion.createInteraction(
                    personID: person.id,
                    summary: "\(selectedType.capitalized) with \(person.name)",
                    date: date, type: selectedType, notes: notes
                )
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }
}

// MARK: - FAB: Add Agenda Item (people picker + text)

struct FABAddAgendaSheet: View {
    @Environment(NotionService.self) private var notion
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""
    @State private var selectedPerson: Person? = nil
    @State private var itemText = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var filteredPeople: [Person] {
        searchText.isEmpty ? notion.people
            : notion.people.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            if selectedPerson == nil {
                List {
                    ForEach(filteredPeople) { person in
                        Button {
                            selectedPerson = person
                        } label: {
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(Color.purple.opacity(0.15))
                                    .frame(width: 32, height: 32)
                                    .overlay(
                                        Text(String(person.name.prefix(1)))
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundStyle(.purple)
                                    )
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(person.name).foregroundStyle(.primary)
                                    if let agenda = person.agenda,
                                       let first = agenda.split(separator: "\n", omittingEmptySubsequences: true).first {
                                        Text(first).font(.caption).foregroundStyle(.purple).lineLimit(1)
                                    }
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .searchable(text: $searchText, prompt: "Search people")
                .navigationTitle("Add Agenda Item")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                }
            } else {
                Form {
                    Section {
                        Button { selectedPerson = nil } label: {
                            HStack {
                                Text(selectedPerson!.name).foregroundStyle(.primary)
                                Spacer()
                                Text("Change").font(.caption).foregroundStyle(.blue)
                            }
                        }
                        .buttonStyle(.plain)
                    } header: { Text("Person") }

                    Section("Item") {
                        TextField("What do you want to bring up?", text: $itemText)
                            .onSubmit { save() }
                    }

                    // Show existing agenda items for context
                    if let person = selectedPerson,
                       let agenda = person.agenda,
                       !agenda.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let items = agenda.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
                        Section("Already queued") {
                            ForEach(items, id: \.self) {
                                Text($0).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }

                    if let err = errorMessage {
                        Section { Text(err).foregroundStyle(.red).font(.caption) }
                    }
                }
                .navigationTitle("Add Agenda Item")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        if isSaving { ProgressView().scaleEffect(0.8) }
                        else {
                            Button("Add") { save() }
                                .disabled(itemText.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
            }
        }
    }

    private func save() {
        guard let person = selectedPerson else { return }
        let trimmed = itemText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSaving = true
        Task {
            do {
                let existing = (person.agenda ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let combined = existing.isEmpty ? trimmed : "\(existing)\n\(trimmed)"
                try await notion.updatePersonAgenda(id: person.id, agenda: combined)
                // Update local cache so filter reflects immediately
                if let idx = notion.people.firstIndex(where: { $0.id == person.id }) {
                    notion.people[idx].agenda = combined
                }
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }
}

// MARK: - Add Person

struct AddPersonView: View {
    @Environment(NotionService.self) private var notion
    @Environment(\.dismiss) private var dismiss

    private let relationships = ["colleague", "friend", "family", "neighbor", "client", "mentor", "Pool Team", "other"]
    private let strengthOptions = ["new", "active", "dormant"]
    private let tagOptions = ["Family", "Business", "Friend", "Network", "Work", "Pool", "Reference"]

    @State private var name = ""
    @State private var relationship = ""
    @State private var relationshipStrength = "new"
    @State private var phone = ""
    @State private var email = ""
    @State private var companyContext = ""
    @State private var city = ""
    @State private var howWeMet = ""
    @State private var address = ""
    @State private var selectedTags: Set<String> = []
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showingAddTag = false
    @State private var newTagText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Full name", text: $name)
                        .autocorrectionDisabled()
                }

                Section("Identity") {
                    Picker("Category", selection: $relationship) {
                        Text("None").tag("")
                        ForEach(relationships, id: \.self) { r in
                            Text(r.capitalized).tag(r)
                        }
                    }
                    Picker("Status", selection: $relationshipStrength) {
                        ForEach(strengthOptions, id: \.self) { s in
                            Text(s.capitalized).tag(s)
                        }
                    }
                    TextField("Company / Context", text: $companyContext)
                    TextField("City", text: $city)
                    TextField("How We Met", text: $howWeMet)
                }

                Section("Contact") {
                    TextField("Phone", text: $phone)
                        .keyboardType(.phonePad)
                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Address", text: $address)
                }

                Section("Tags") {
                    let customTags = Array(selectedTags).filter { !tagOptions.contains($0) }.sorted()
                    FlowLayout(spacing: 8) {
                        ForEach(tagOptions, id: \.self) { tag in tagChip(tag) }
                        ForEach(customTags, id: \.self) { tag in tagChip(tag) }
                        Button { showingAddTag = true } label: {
                            Label("Add", systemImage: "plus")
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.secondary.opacity(0.1))
                                .foregroundStyle(.secondary)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                }

                if let err = errorMessage {
                    Section {
                        Text(err).foregroundStyle(.red).font(.caption)
                    }
                }
            }
            .navigationTitle("Add Person")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Adding…" : "Add") {
                        Task { await save() }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
                    .fontWeight(.semibold)
                }
            }
            .alert("Add Tag", isPresented: $showingAddTag) {
                TextField("Tag name", text: $newTagText)
                    .autocorrectionDisabled()
                Button("Add") {
                    let tag = newTagText.trimmingCharacters(in: .whitespaces)
                    if !tag.isEmpty { selectedTags.insert(tag) }
                    newTagText = ""
                }
                Button("Cancel", role: .cancel) { newTagText = "" }
            }
        }
    }

    @ViewBuilder
    private func tagChip(_ tag: String) -> some View {
        Button {
            if selectedTags.contains(tag) { selectedTags.remove(tag) }
            else { selectedTags.insert(tag) }
        } label: {
            Text(tag)
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(selectedTags.contains(tag) ? Color.accentColor : Color.secondary.opacity(0.12))
                .foregroundStyle(selectedTags.contains(tag) ? .white : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func save() async {
        isSaving = true
        do {
            let trimmedName = name.trimmingCharacters(in: .whitespaces)
            let person = try await notion.addPerson(name: trimmedName)
            let hasOptional = !relationship.isEmpty || !phone.isEmpty || !email.isEmpty ||
                              !companyContext.isEmpty || !city.isEmpty || !howWeMet.isEmpty ||
                              !address.isEmpty || !selectedTags.isEmpty
            if hasOptional {
                try await notion.enrichPerson(
                    id: person.id,
                    relationship: relationship.isEmpty ? nil : relationship,
                    relationshipStrength: relationshipStrength,
                    companyContext: companyContext.isEmpty ? nil : companyContext,
                    city: city.isEmpty ? nil : city,
                    howWeMet: howWeMet.isEmpty ? nil : howWeMet,
                    tags: Array(selectedTags),
                    phone: phone.isEmpty ? nil : phone,
                    email: email.isEmpty ? nil : email,
                    address: address.isEmpty ? nil : address
                )
            }
            await notion.fetchPeople()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }
}
