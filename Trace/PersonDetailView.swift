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
    @State private var selectedStrength = "new"
    @State private var strengthLoaded = false
    @State private var phoneForAction: String? = nil
    @State private var showAllVisits = false

    private let strengthOptions = ["new", "active", "dormant"]

    private var sharedVisits: [Visit] {
        notion.visits
            .filter { $0.peopleIDs.contains(personID) }
            .sorted { $0.date > $1.date }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let detail {
                    cardBody(detail)
                } else if let err = loadError {
                    Text(err).foregroundStyle(.red).padding()
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
            // Hero section — photo right, action buttons left
            Section {
                heroSection(d)
            }
            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            .listRowBackground(Color.clear)

            // Identity
            Section {
                if let rel = d.relationship {
                    row("Relationship", value: rel.capitalized)
                }

                HStack {
                    Text("Status").foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: $selectedStrength) {
                        ForEach(strengthOptions, id: \.self) { s in
                            Text(s.capitalized).tag(s)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: selectedStrength) { _, newVal in
                        guard strengthLoaded else { return }
                        Task { try? await notion.updatePersonStatus(id: personID, relationshipStrength: newVal) }
                    }
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
                if let phone = d.phone, !phone.isEmpty {
                    Button { phoneForAction = phone } label: {
                        HStack {
                            Text("Phone").foregroundStyle(.secondary)
                            Spacer()
                            Text(phone).foregroundStyle(.blue)
                        }
                    }
                    .buttonStyle(.plain)
                }
                if let email = d.email, !email.isEmpty {
                    Button {
                        if let url = URL(string: "mailto:\(email)") { openURL(url) }
                    } label: {
                        HStack {
                            Text("Email").foregroundStyle(.secondary)
                            Spacer()
                            Text(email).foregroundStyle(.blue)
                        }
                    }
                    .buttonStyle(.plain)
                }
                if let address = d.address, !address.isEmpty {
                    Button {
                        let encoded = address.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                        if let url = URL(string: "maps://?q=\(encoded)") { openURL(url) }
                    } label: {
                        HStack(alignment: .top) {
                            Text("Address").foregroundStyle(.secondary)
                            Spacer()
                            Text(address).foregroundStyle(.blue).multilineTextAlignment(.trailing)
                        }
                    }
                    .buttonStyle(.plain)
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

            // Activity
            Section {
                HStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(sharedVisits.count)")
                            .font(.title2.bold())
                        Text("visits together")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let lv = d.lastVisitDate {
                        Divider().frame(height: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(lv.formatted(.dateTime.month(.abbreviated).day().year()))
                                .font(.subheadline.weight(.medium))
                            Text("last seen")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)

                if sharedVisits.isEmpty {
                    Text("No visits together yet")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                        .padding(.vertical, 4)
                } else {
                    let visitsToShow = showAllVisits ? sharedVisits : Array(sharedVisits.prefix(5))
                    ForEach(visitsToShow) { visit in
                        HStack(alignment: .center) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(visit.placeName).font(.subheadline)
                                Text(visit.date.formatted(.dateTime.month(.abbreviated).day().year()))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let rating = visit.rating, rating > 0 {
                                Text(String(repeating: "★", count: min(rating, 7)))
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    if sharedVisits.count > 5 {
                        Button(showAllVisits ? "Show less" : "Show all \(sharedVisits.count) visits") {
                            showAllVisits.toggle()
                        }
                        .font(.subheadline)
                        .foregroundStyle(.blue)
                        .padding(.vertical, 2)
                    }
                }
            } header: {
                Text("Activity")
            }

            // Notes
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
        .confirmationDialog("", isPresented: Binding(
            get: { phoneForAction != nil },
            set: { if !$0 { phoneForAction = nil } }
        )) {
            if let phone = phoneForAction {
                let digits = phone.filter { $0.isNumber || $0 == "+" }
                Button("Call") {
                    if let url = URL(string: "tel:\(digits)") { openURL(url) }
                }
                Button("Message") {
                    if let url = URL(string: "sms:\(digits)") { openURL(url) }
                }
                Button("Cancel", role: .cancel) { }
            }
        }
    }

    // MARK: - Hero Section

    @ViewBuilder
    private func heroSection(_ d: PersonDetail) -> some View {
        HStack(alignment: .center, spacing: 20) {
            // Action buttons — left side
            VStack(alignment: .leading, spacing: 10) {
                if let phone = d.phone, !phone.isEmpty {
                    let digits = phone.filter { $0.isNumber || $0 == "+" }
                    quickActionButton(icon: "phone.fill", label: "Call", color: .green) {
                        if let url = URL(string: "tel:\(digits)") { openURL(url) }
                    }
                    quickActionButton(icon: "message.fill", label: "Message", color: .blue) {
                        if let url = URL(string: "sms:\(digits)") { openURL(url) }
                    }
                }
                if let email = d.email, !email.isEmpty {
                    quickActionButton(icon: "envelope.fill", label: "Email", color: .orange) {
                        if let url = URL(string: "mailto:\(email)") { openURL(url) }
                    }
                }
            }

            Spacer()

            // Photo — right side, large
            Group {
                if let urlStr = d.photoURL, let url = URL(string: urlStr) {
                    AsyncImage(url: url) { phase in
                        if let img = phase.image {
                            img.resizable().scaledToFill()
                        } else {
                            initialsCircle(d.name, size: 120)
                        }
                    }
                    .frame(width: 120, height: 120)
                    .clipShape(Circle())
                } else {
                    initialsCircle(d.name, size: 120)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func quickActionButton(icon: String, label: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(color)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

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
        strengthLoaded = false
        do {
            let d = try await notion.fetchPersonDetail(id: personID)
            detail = d
            selectedStrength = d.relationshipStrength ?? "new"
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
        try? await Task.sleep(for: .milliseconds(300))
        strengthLoaded = true
    }

    @ViewBuilder
    private func initialsCircle(_ name: String, size: CGFloat = 80) -> some View {
        let parts = name.split(separator: " ")
        let initials = parts.count >= 2
            ? String(parts[0].prefix(1)) + String(parts[1].prefix(1))
            : String(name.prefix(2)).uppercased()
        Circle()
            .fill(Color.purple.opacity(0.15))
            .frame(width: size, height: size)
            .overlay(
                Text(initials)
                    .font(.system(size: size * 0.33, weight: .medium))
                    .foregroundStyle(.purple)
            )
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
                await loadDetail()
            } catch { }
            isSavingNote = false
        }
    }
}
