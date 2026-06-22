import SwiftUI

struct PersonEnrichSheet: View {
    @Environment(NotionService.self) private var notion
    @Environment(\.dismiss) private var dismiss

    let person: Person

    private let relationships = ["colleague", "friend", "family", "neighbor", "client", "mentor", "Pool Team", "other"]
    private let strengthOptions = ["new", "active", "dormant"]
    private let tagOptions = ["Family", "Business", "Friend", "Network", "Work", "Pool", "Reference"]

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
                Section("Identity") {
                    Picker("Category", selection: $relationship) {
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

                Section("Contact") {
                    TextField("Phone", text: $phone)
                        .keyboardType(.phonePad)
                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Address", text: $address)
                }

                tagSection

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

    private var tagSection: some View {
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
                    tags: Array(selectedTags),
                    phone: phone.isEmpty ? nil : phone,
                    email: email.isEmpty ? nil : email,
                    address: address.isEmpty ? nil : address
                )
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }
}
