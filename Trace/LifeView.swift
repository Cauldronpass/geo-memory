import SwiftUI

struct LifeView: View {
    @Environment(NotionService.self) private var notion

    var body: some View {
        NavigationStack {
            List {
                LifeMenuRow(icon: "airplane", color: .blue, title: "Trips", subtitle: "Upcoming & past trips") {
                    LifePlaceholderView(title: "Trips", icon: "airplane")
                }
                LifeMenuRow(icon: "figure.run", color: .orange, title: "Fitness", subtitle: "Workouts & OrangeTheory") {
                    FitnessView()
                }
                LifeMenuRow(icon: "8.circle.fill", color: .green, title: "Billiards", subtitle: "Match journal & season stats") {
                    LifePlaceholderView(title: "Billiards", icon: "8.circle.fill")
                }
                LifeMenuRow(icon: "person.2.fill", color: .purple, title: "People", subtitle: "Personal contacts & connections") {
                    LifePeopleView()
                }
                LifeMenuRow(icon: "fork.knife", color: .red, title: "Food Log", subtitle: "What you ordered & loved") {
                    LifePlaceholderView(title: "Food Log", icon: "fork.knife")
                }
            }
            .navigationTitle("Life")
            .drawerToolbar()
        }
    }
}

// MARK: - Menu Row

struct LifeMenuRow<Destination: View>: View {
    let icon: String
    let color: Color
    let title: String
    let subtitle: String
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        NavigationLink(destination: destination()) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(color)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

// MARK: - Placeholder

struct LifePlaceholderView: View {
    let title: String
    let icon: String

    var body: some View {
        ContentUnavailableView(
            title,
            systemImage: icon,
            description: Text("Coming soon")
        )
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.large)
        .drawerToolbar()
    }
}

// MARK: - People List

struct LifePeopleView: View {
    @Environment(NotionService.self) private var notion
    @State private var searchText = ""
    @State private var selectedRelationship: String? = nil
    @State private var selectedPerson: Person? = nil
    @State private var showAddPerson = false

    private var relationshipTypes: [String] {
        Array(Set(notion.people.compactMap { $0.relationship })).sorted()
    }

    private var filtered: [Person] {
        notion.people.filter { person in
            let matchesSearch = searchText.isEmpty
                || person.name.localizedCaseInsensitiveContains(searchText)
            let matchesType = selectedRelationship == nil
                || person.relationship == selectedRelationship
            return matchesSearch && matchesType
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Search bar
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search people", text: $searchText)
                        .autocorrectionDisabled()
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(10)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 8)

                // Filter pills
                if !relationshipTypes.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            PeoplePill(label: "All", isActive: selectedRelationship == nil) {
                                selectedRelationship = nil
                            }
                            ForEach(relationshipTypes, id: \.self) { type in
                                PeoplePill(label: type, isActive: selectedRelationship == type) {
                                    selectedRelationship = selectedRelationship == type ? nil : type
                                }
                            }
                        }
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                    }
                }

                // People list
                LazyVStack(spacing: 0) {
                    ForEach(filtered) { person in
                        Button {
                            selectedPerson = person
                        } label: {
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(Color.purple.opacity(0.15))
                                    .frame(width: 36, height: 36)
                                    .overlay(
                                        Text(String(person.name.prefix(1)))
                                            .font(.system(size: 15, weight: .medium))
                                            .foregroundStyle(.purple)
                                    )
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(person.name)
                                        .foregroundStyle(.primary)
                                        .font(.body)
                                    if let rel = person.relationship {
                                        Text(rel)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)

                        if person.id != filtered.last?.id {
                            Divider().padding(.leading, 60)
                        }
                    }
                }
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)
                .padding(.bottom, 20)
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("People")
        .navigationBarTitleDisplayMode(.large)
        .drawerToolbar()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showAddPerson = true } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(item: $selectedPerson) { person in
            PersonDetailView(personID: person.id, personName: person.name)
                .environment(NotionService.shared)
        }
        .sheet(isPresented: $showAddPerson) {
            AddPersonView()
                .environment(notion)
        }
    }
}

// MARK: - People Filter Pill

struct PeoplePill: View {
    let label: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.subheadline)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(isActive ? Color.purple : Color(.secondarySystemGroupedBackground))
                .foregroundStyle(isActive ? .white : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Add Person

struct AddPersonView: View {
    @Environment(NotionService.self) private var notion
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Full name", text: $name)
                        .autocorrectionDisabled()
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
                    Button("Add") {
                        Task { await save() }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private func save() async {
        isSaving = true
        do {
            _ = try await notion.addPerson(name: name.trimmingCharacters(in: .whitespaces))
            await notion.fetchPeople()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }
}
