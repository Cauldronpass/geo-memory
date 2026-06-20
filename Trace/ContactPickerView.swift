import SwiftUI

// MARK: - Notion People Picker Sheet

struct NotionPeoplePicker: View {
    @Environment(NotionService.self) private var notion
    @Binding var selectedIDs: [String]
    @Environment(\.dismiss) private var dismiss

    @State private var search = ""
    @State private var isAdding = false
    @State private var showingAddAlert = false
    @State private var newPersonName = ""
    @State private var justAddedPerson: Person?
    @State private var personToEnrich: Person?
    @State private var showingEnrich = false

    private var filteredPeople: [Person] {
        if search.isEmpty { return notion.people }
        return notion.people.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(filteredPeople) { person in
                    Button {
                        if selectedIDs.contains(person.id) {
                            selectedIDs.removeAll { $0 == person.id }
                        } else {
                            selectedIDs.append(person.id)
                        }
                    } label: {
                        HStack {
                            Text(person.name)
                                .foregroundStyle(.primary)
                            Spacer()
                            if selectedIDs.contains(person.id) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.blue)
                                    .fontWeight(.semibold)
                            }
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "Search people")
            .navigationTitle("Who was I with?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        newPersonName = search
                        showingAddAlert = true
                    } label: {
                        Label("New Person", systemImage: "person.badge.plus")
                    }
                    .disabled(isAdding)
                }
            }
            .alert("Add to People", isPresented: $showingAddAlert) {
                TextField("Full name", text: $newPersonName)
                Button("Add") {
                    let name = newPersonName.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    Task { await addPerson(name) }
                }
                Button("Cancel", role: .cancel) { newPersonName = "" }
            } message: {
                Text("This will create a new entry in your Notion People database.")
            }
            .task {
                if notion.people.isEmpty {
                    await notion.fetchPeople()
                }
            }
            .overlay {
                if isAdding {
                    ProgressView("Adding…")
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let p = justAddedPerson {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("\(p.name) added.")
                            .font(.subheadline)
                        Spacer()
                        Button("Add details →") {
                            personToEnrich = p
                            withAnimation { justAddedPerson = nil }
                            showingEnrich = true
                        }
                        .font(.subheadline.weight(.semibold))
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(.regularMaterial)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.25), value: justAddedPerson?.id)
            .sheet(isPresented: $showingEnrich) {
                if let p = personToEnrich {
                    PersonEnrichSheet(person: p)
                        .environment(notion)
                }
            }
        }
    }

    private func addPerson(_ name: String) async {
        isAdding = true
        if let person = try? await notion.addPerson(name: name) {
            selectedIDs.append(person.id)
            newPersonName = ""
            search = ""
            withAnimation { justAddedPerson = person }
            // Auto-dismiss toast after 5 seconds if not tapped
            Task {
                try? await Task.sleep(for: .seconds(5))
                if justAddedPerson?.id == person.id {
                    withAnimation { justAddedPerson = nil }
                }
            }
        }
        isAdding = false
    }
}

// MARK: - Reusable "With" section for forms

struct PeoplePickerSection: View {
    @Environment(NotionService.self) private var notion
    @Binding var selectedIDs: [String]
    var onPersonTap: ((Person) -> Void)? = nil
    @State private var showingPicker = false

    private var selectedPeople: [Person] {
        selectedIDs.compactMap { id in notion.people.first { $0.id == id } }
    }

    var body: some View {
        Section("With (optional)") {
            if !selectedPeople.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(selectedPeople) { person in
                            HStack(spacing: 4) {
                                // Name area — tappable if onPersonTap is wired
                                if let tap = onPersonTap {
                                    Button {
                                        tap(person)
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: "person.fill")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                            Text(person.name)
                                                .font(.subheadline)
                                                .foregroundStyle(.blue)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                } else {
                                    Image(systemName: "person.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Text(person.name)
                                        .font(.subheadline)
                                }
                                // Remove button
                                Button {
                                    selectedIDs.removeAll { $0 == person.id }
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.secondary.opacity(0.12))
                            .clipShape(Capsule())
                        }
                    }
                    .padding(.vertical, 2)
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }

            Button {
                showingPicker = true
            } label: {
                Label(selectedPeople.isEmpty ? "Add people" : "Edit people", systemImage: "person.badge.plus")
                    .font(.subheadline)
            }
            .sheet(isPresented: $showingPicker) {
                NotionPeoplePicker(selectedIDs: $selectedIDs)
                    .environment(notion)
            }
        }
    }
}
