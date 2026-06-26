import SwiftUI
import CoreLocation
import PhotosUI

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
    @State private var showingEdit = false
    @State private var showingPlacePicker = false
    @State private var selectedPlace: Place? = nil
    @State private var selectedVisit: Visit? = nil
    @State private var isCreatingPlace = false
    @State private var createPlaceError: String? = nil

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
                    HStack(spacing: 16) {
                        if detail != nil {
                            Button("Edit") { showingEdit = true }
                        }
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
            }
            .task { await loadDetail() }
            .sheet(isPresented: $showingEdit) {
                if let d = detail {
                    PersonEditSheet(personID: personID, detail: d)
                        .environment(notion)
                        .onDisappear { Task { await loadDetail() } }
                }
            }
            .sheet(isPresented: $showingPlacePicker) {
                PersonPlacePickerSheet(places: notion.places) { place in
                    Task {
                        try? await notion.linkPersonToPlace(personID: personID, placeID: place.id)
                        await loadDetail()
                    }
                }
                .environment(notion)
            }
            .sheet(item: $selectedPlace) { place in
                PlaceDetailView(place: place)
                    .environment(NotionService.shared)
                    .environment(LocationManager.shared)
            }
            .sheet(item: $selectedVisit) { visit in
                VisitDetailView(visit: visit)
                    .environment(NotionService.shared)
            }
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

            // Place
            Section("Place") {
                placeSection(d)
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
                        Button { selectedVisit = visit } label: {
                            HStack(alignment: .center) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(visit.placeName)
                                        .font(.subheadline)
                                        .foregroundStyle(.primary)
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
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 2)
                        }
                        .buttonStyle(.plain)
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

    // MARK: - Place section

    @ViewBuilder
    private func placeSection(_ d: PersonDetail) -> some View {
        if let placeID = d.homePlaceID,
           let place = notion.places.first(where: { normalizeID($0.id) == normalizeID(placeID) }) {
            // Linked place row
            Button {
                selectedPlace = place
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: placeIcon(for: place.category))
                        .font(.system(size: 13))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(placeColor(for: place.category))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(place.name).foregroundStyle(.primary)
                        if !place.city.isEmpty {
                            Text(place.city).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(Color(.tertiaryLabel))
                }
            }
            .buttonStyle(.plain)
            // Unlink option
            Button(role: .destructive) {
                Task {
                    try? await notion.linkPersonToPlace(personID: personID, placeID: nil)
                    await loadDetail()
                }
            } label: {
                Text("Unlink Place").font(.subheadline)
            }
        } else {
            // Not linked yet
            Button("Link to Existing Place") {
                showingPlacePicker = true
            }
            if let address = d.address, !address.isEmpty {
                Button {
                    Task { await createPlaceFromAddress(address, for: d) }
                } label: {
                    if isCreatingPlace {
                        HStack { ProgressView(); Text("Creating place…").foregroundStyle(.secondary) }
                    } else {
                        Text("Create Place from Address")
                    }
                }
                .disabled(isCreatingPlace)
            }
            if let err = createPlaceError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func normalizeID(_ id: String) -> String {
        id.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private func createPlaceFromAddress(_ address: String, for d: PersonDetail) async {
        isCreatingPlace = true
        createPlaceError = nil
        do {
            let geocoder = CLGeocoder()
            let placemarks = try await geocoder.geocodeAddressString(address)
            guard let placemark = placemarks.first, let location = placemark.location else {
                createPlaceError = "Could not geocode address"
                isCreatingPlace = false
                return
            }
            let city = placemark.locality ?? d.city ?? ""
            let placeName = "\(d.name.components(separatedBy: " ").first ?? d.name)'s"
            let placeID = try await notion.addPlace(
                name: placeName,
                address: address,
                city: city,
                category: "house",
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                googlePlaceID: nil,
                phone: nil,
                website: nil
            )
            try await notion.linkPersonToPlace(personID: personID, placeID: placeID)
            await notion.fetchPlaces()
            await loadDetail()
        } catch {
            createPlaceError = error.localizedDescription
        }
        isCreatingPlace = false
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

// MARK: - Person Edit Sheet

struct PersonEditSheet: View {
    @Environment(NotionService.self) private var notion
    @Environment(\.dismiss) private var dismiss

    let personID: String
    let detail: PersonDetail

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

    // Photo
    @State private var photoItem: PhotosPickerItem? = nil
    @State private var pickedImage: UIImage? = nil
    @State private var isUploadingPhoto = false
    @State private var uploadedPhotoURL: String? = nil

    var body: some View {
        NavigationStack {
            Form {
                // Photo section
                Section {
                    HStack {
                        Spacer()
                        ZStack(alignment: .bottomTrailing) {
                            Group {
                                if let img = pickedImage {
                                    Image(uiImage: img)
                                        .resizable().scaledToFill()
                                } else if let url = detail.photoURL, let photoURL = URL(string: url) {
                                    AsyncImage(url: photoURL) { phase in
                                        switch phase {
                                        case .success(let img): img.resizable().scaledToFill()
                                        default: personInitialsView
                                        }
                                    }
                                } else {
                                    personInitialsView
                                }
                            }
                            .frame(width: 90, height: 90)
                            .clipShape(Circle())

                            PhotosPicker(selection: $photoItem, matching: .images) {
                                Image(systemName: isUploadingPhoto ? "arrow.triangle.2.circlepath" : "camera.fill")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 26, height: 26)
                                    .background(Color.orange, in: Circle())
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 12, trailing: 0))

                    if isUploadingPhoto {
                        HStack {
                            ProgressView().scaleEffect(0.8)
                            Text("Uploading photo…").font(.caption).foregroundStyle(.secondary)
                        }
                    } else if uploadedPhotoURL != nil {
                        Label("Photo ready to save", systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(.green)
                    }
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

                tagSection

                if let err = errorMessage {
                    Section {
                        Text(err).foregroundStyle(.red).font(.caption)
                    }
                }
            }
            .navigationTitle(detail.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") { Task { await save() } }
                        .disabled(isSaving)
                        .fontWeight(.semibold)
                }
            }
            .onAppear { prefill() }
            .onChange(of: photoItem) { _, newItem in
                guard let newItem else { return }
                Task {
                    isUploadingPhoto = true
                    defer { isUploadingPhoto = false }
                    guard let data = try? await newItem.loadTransferable(type: Data.self),
                          let image = UIImage(data: data) else { return }
                    pickedImage = image
                    let filename = "person-\(personID)-\(Int(Date().timeIntervalSince1970)).jpg"
                    uploadedPhotoURL = try? NoteStore.shared.writePhoto(data, category: "People", filename: filename)
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

    private func prefill() {
        relationship = detail.relationship ?? ""
        relationshipStrength = detail.relationshipStrength ?? "new"
        phone = detail.phone ?? ""
        email = detail.email ?? ""
        companyContext = detail.companyContext ?? ""
        city = detail.city ?? ""
        howWeMet = detail.howWeMet ?? ""
        address = detail.address ?? ""
        selectedTags = Set(detail.tags)
    }

    private var personInitialsView: some View {
        let initials = detail.name.split(separator: " ").prefix(2).compactMap { $0.first }.map { String($0) }.joined()
        return Text(initials.isEmpty ? "?" : initials)
            .font(.system(size: 32, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 90, height: 90)
            .background(Color.purple.opacity(0.6), in: Circle())
    }

    private func save() async {
        isSaving = true
        do {
            try await notion.enrichPerson(
                id: personID,
                relationship: relationship,
                relationshipStrength: relationshipStrength,
                companyContext: companyContext,
                city: city,
                howWeMet: howWeMet,
                tags: Array(selectedTags),
                phone: phone,
                email: email,
                address: address,
                photoURL: uploadedPhotoURL
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            isSaving = false
        }
    }
}
