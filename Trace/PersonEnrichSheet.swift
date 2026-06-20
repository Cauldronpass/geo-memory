import SwiftUI

struct PersonEnrichSheet: View {
    @Environment(NotionService.self) private var notion
    @Environment(\.dismiss) private var dismiss

    let person: Person

    private let relationships = ["colleague", "friend", "family", "neighbor", "client", "mentor", "Pool Team", "other"]
    private let strengthOptions = ["new", "active", "dormant"]
    private let tagOptions = ["kearney", "personal", "finance", "travel-buddy", "pool-league",
                               "treasury", "gbu", "family", "chicago", "french"]

    @State private var relationship = ""
    @State private var relationshipStrength = "new"
    @State private var companyContext = ""
    @State private var city = ""
    @State private var howWeMet = ""
    @State private var selectedTags: Set<String> = []
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Relationship", selection: $relationship) {
                        Text("—").tag("")
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

                Section("Tags") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110))], spacing: 8) {
                        ForEach(tagOptions, id: \.self) { tag in
                            Button {
                                if selectedTags.contains(tag) { selectedTags.remove(tag) }
                                else { selectedTags.insert(tag) }
                            } label: {
                                Text(tag)
                                    .font(.caption)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .frame(maxWidth: .infinity)
                                    .background(selectedTags.contains(tag) ? Color.accentColor : Color.secondary.opacity(0.12))
                                    .foregroundStyle(selectedTags.contains(tag) ? .white : .primary)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                }

                if let err = errorMessage {
                    Section {
                        Text(err).foregroundStyle(.red).font(.caption)
                    }
                }
            }
            .navigationTitle(person.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") { save() }
                        .disabled(isSaving)
                }
            }
        }
    }

    private func save() {
        isSaving = true
        Task {
            do {
                try await notion.enrichPerson(
                    id: person.id,
                    relationship: relationship.isEmpty ? nil : relationship,
                    relationshipStrength: relationshipStrength.isEmpty ? nil : relationshipStrength,
                    companyContext: companyContext.isEmpty ? nil : companyContext,
                    city: city.isEmpty ? nil : city,
                    howWeMet: howWeMet.isEmpty ? nil : howWeMet,
                    tags: Array(selectedTags)
                )
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }
}
