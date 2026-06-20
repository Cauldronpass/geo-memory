import SwiftUI

struct PersonDetailView: View {
    @Environment(NotionService.self) private var notion
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    let personID: String
    let personName: String

    @State private var detail: PersonDetail?
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var newNote = ""
    @State private var isSavingNote = false
    @State private var noteSaved = false

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let detail {
                    cardBody(detail)
                } else if let err = loadError {
                    Text(err)
                        .foregroundStyle(.red)
                        .padding()
                }
            }
            .navigationTitle(personName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        let cleanID = personID.replacingOccurrences(of: "-", with: "")
                        if let url = URL(string: "https://notion.so/\(cleanID)") {
                            openURL(url)
                        }
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                    }
                }
            }
            .task { await loadDetail() }
        }
    }

    @ViewBuilder
    private func cardBody(_ d: PersonDetail) -> some View {
        Form {
            // Identity
            Section {
                if let rel = d.relationship {
                    row("Relationship", value: rel.capitalized)
                }
                if let rs = d.relationshipStrength {
                    row("Status", value: rs.capitalized)
                }
                if let co = d.companyContext, !co.isEmpty {
                    row("Company / Context", value: co)
                }
                if let city = d.city, !city.isEmpty {
                    row("City", value: city)
                }
                if let bday = d.birthday {
                    row("Birthday", value: bday.formatted(.dateTime.month(.wide).day()))
                }
                if let met = d.howWeMet, !met.isEmpty {
                    row("How We Met", value: met)
                }
            }

            // Tags
            if !d.tags.isEmpty {
                Section("Tags") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(d.tags, id: \.self) { tag in
                                Text(tag)
                                    .font(.caption)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color.accentColor.opacity(0.12))
                                    .foregroundStyle(Color.accentColor)
                                    .clipShape(Capsule())
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }
            }

            // Activity stats
            Section("Activity") {
                if let vc = d.visitCount {
                    row("Visits together", value: "\(vc)")
                }
                if let lv = d.lastVisitDate {
                    row("Last visit", value: lv.formatted(.dateTime.month(.abbreviated).day().year()))
                }
                if let li = d.lastInteractionDate {
                    row("Last interaction", value: li.formatted(.dateTime.month(.abbreviated).day().year()))
                }
            }

            // Notes — existing (read-only) + append input
            Section("Notes") {
                if let existing = d.notes, !existing.isEmpty {
                    Text(existing)
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $newNote)
                        .frame(minHeight: 80)
                    if newNote.isEmpty {
                        Text("Add a note…")
                            .foregroundStyle(Color(.placeholderText))
                            .font(.body)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
                if !newNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button(isSavingNote ? "Saving…" : noteSaved ? "Saved" : "Save note") {
                        saveNote()
                    }
                    .disabled(isSavingNote || noteSaved)
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ label: String, value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
    }

    private func loadDetail() async {
        isLoading = true
        do {
            detail = try await notion.fetchPersonDetail(id: personID)
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func saveNote() {
        let trimmed = newNote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSavingNote = true
        Task {
            do {
                try await notion.appendPersonNotes(id: personID, text: trimmed)
                newNote = ""
                noteSaved = true
                try? await Task.sleep(for: .seconds(1.5))
                noteSaved = false
                await loadDetail()  // refresh to show the appended note
            } catch { /* silent fail — note didn't save */ }
            isSavingNote = false
        }
    }
}
