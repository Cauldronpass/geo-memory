import SwiftUI
import CoreLocation
import PhotosUI

// MARK: - Person photo helpers

private func personInitials(_ name: String) -> String {
    let parts = name.split(separator: " ")
    if parts.count >= 2 {
        return String(parts[0].prefix(1)) + String(parts[1].prefix(1))
    }
    return String(name.prefix(2)).uppercased()
}

/// Returns a filesystem-safe filename stem from a person's name (e.g. "Bryan Weiss").
func sanitizedPersonFilename(_ name: String) -> String {
    let bad = CharacterSet(charactersIn: "/\\:*?\"<>|")
    return name.components(separatedBy: bad).joined(separator: "_")
}

/// Returns the canonical NoteStore path for a person's photo if the file exists locally;
/// otherwise returns `fallbackURL` (a legacy Notion external URL).
/// Checks .jpg, .jpeg, .png, and .heic so the extension of the source file doesn't matter.
func resolvePersonPhoto(name: String, fallbackURL: String?) -> String? {
    let stem = sanitizedPersonFilename(name)
    for ext in ["jpg", "jpeg", "png", "heic"] {
        let path = "Photos/People/\(stem).\(ext)"
        if let url = NoteStore.shared.resolvedURL(for: path),
           FileManager.default.fileExists(atPath: url.path) {
            return path
        }
    }
    return fallbackURL
}

/// Loads a person photo from either a NoteStore relative path ("Photos/People/xxx.jpg")
/// or a remote https:// URL. Triggers iCloud file download when needed.
private struct PersonPhotoCircle: View {
    let urlString: String
    let size: CGFloat
    let initials: String

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                Circle()
                    .fill(Color.purple.opacity(0.15))
                    .frame(width: size, height: size)
                    .overlay(
                        Text(initials)
                            .font(.system(size: size * 0.33, weight: .medium))
                            .foregroundStyle(.purple)
                    )
            }
        }
        .task(id: urlString) {
            image = await load()
        }
    }

    private func load() async -> UIImage? {
        if urlString.hasPrefix("Photos/") {
            return await loadNoteStorePhoto()
        }
        guard let url = URL(string: urlString),
              let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return UIImage(data: data)
    }

    private func loadNoteStorePhoto() async -> UIImage? {
        guard let fileURL = NoteStore.shared.resolvedURL(for: urlString) else { return nil }
        // Queue an iCloud download if the file is a cloud-only placeholder.
        try? FileManager.default.startDownloadingUbiquitousItem(at: fileURL)
        // Poll with backoff — iCloud downloads typically take a few seconds.
        // Total wait ceiling: ~17 s before giving up.
        let delays: [UInt64] = [300, 500, 1_000, 1_500, 2_000, 3_000, 4_000, 5_000]
        for delay in delays {
            if let data = try? Data(contentsOf: fileURL),
               let img = UIImage(data: data) {
                return img
            }
            try? await Task.sleep(nanoseconds: delay * 1_000_000)
        }
        return (try? Data(contentsOf: fileURL)).flatMap { UIImage(data: $0) }
    }
}

// MARK: - PersonDetailView

struct PersonDetailView: View {
    @Environment(NotionService.self) private var notion
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    let personID: String
    let personName: String

    @State private var detail: PersonDetail?
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var selectedTab: PersonTab = .info

    // Info tab
    @State private var isArchived = false
    @State private var phoneForAction: String? = nil
    @State private var selectedPlace: Place? = nil
    @State private var showingPlacePicker = false
    @State private var isCreatingPlace = false
    @State private var createPlaceError: String? = nil

    // Activity tab
    @State private var showAllVisits = false
    @State private var selectedVisit: Visit? = nil

    // Log tab — agenda
    @State private var agendaItems: [String] = []
    @State private var isAddingAgendaItem = false
    @State private var newAgendaItem = ""
    @State private var isSavingAgenda = false
    @State private var editingAgendaItem: String? = nil   // the original text of the item being edited
    @State private var editingAgendaText: String = ""

    // Log tab — interactions
    @State private var interactions: [Interaction] = []
    @State private var isLoadingInteractions = false
    @State private var showAllInteractions = false
    @State private var selectedInteraction: Interaction? = nil
    @State private var showingLogInteraction = false

    // Notes tab — NoteStore-backed markdown file
    @State private var noteStoreText = ""
    @State private var isLoadingNoteStore = false

    // Edit sheet
    @State private var showingEdit = false

    private enum PersonTab: String, CaseIterable {
        case info = "Info"
        case activity = "Activity"
        case log = "Log"
        case notes = "Notes"
    }

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
                            Button {
                                let newVal = !isArchived
                                isArchived = newVal
                                Task {
                                    try? await notion.updatePersonStatus(
                                        id: personID,
                                        relationshipStrength: newVal ? "archived" : ""
                                    )
                                }
                            } label: {
                                Image(systemName: isArchived ? "archivebox.fill" : "archivebox")
                                    .foregroundStyle(isArchived ? Color.accentColor : .secondary)
                            }
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
            .task {
                await loadDetail()
                await loadInteractions()
            }
            .sheet(item: $selectedInteraction) { interaction in
                InteractionDetailSheet(interaction: interaction)
            }
            .sheet(isPresented: $showingLogInteraction) {
                LogInteractionSheet(personID: personID, personName: personName) {
                    Task { await loadInteractions() }
                }
                .environment(notion)
            }
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

    // MARK: - Card Body

    @ViewBuilder
    private func cardBody(_ d: PersonDetail) -> some View {
        Form {
            // Hero — always visible
            Section {
                heroSection(d)
            }
            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            .listRowBackground(Color.clear)

            // Tab picker
            Section {
                Picker("", selection: $selectedTab) {
                    ForEach(PersonTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }
            .listRowBackground(Color.clear)

            // Tab content
            switch selectedTab {
            case .info:         infoTab(d)
            case .activity:     activityTab(d)
            case .log:          logTab(d)
            case .notes:        notesTab(d)
            }
        }
        .onChange(of: selectedTab) { _, tab in
            if tab == .notes { loadNoteStoreNote() }
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

    // MARK: - Info Tab

    @ViewBuilder
    private func infoTab(_ d: PersonDetail) -> some View {
        Section {
            row("Relationship", value: d.relationship.map { $0.capitalized } ?? "None")
            if let co = d.companyContext, !co.isEmpty { row("Company", value: co) }
            if let city = d.city, !city.isEmpty { row("City", value: city) }
            if let bday = d.birthday {
                row("Birthday", value: bday.formatted(.dateTime.month(.wide).day()))
            }
            if let met = d.howWeMet, !met.isEmpty { row("How We Met", value: met) }
        }

        Section("Contact") {
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

        Section("Place") {
            placeSection(d)
        }

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
    }

    // MARK: - Activity Tab

    @ViewBuilder
    private func activityTab(_ d: PersonDetail) -> some View {
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
        }

        Section {
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
            Text("Visits")
        }
    }

    // MARK: - Log Tab (Agenda + Interactions)

    @ViewBuilder
    private func logTab(_ d: PersonDetail) -> some View {
        // Agenda
        Section {
            if agendaItems.isEmpty && !isAddingAgendaItem {
                Text("Nothing queued")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            } else {
                ForEach(agendaItems, id: \.self) { item in
                    Group {
                        if editingAgendaItem == item {
                            TextField("", text: $editingAgendaText)
                                .font(.subheadline)
                                .onSubmit { commitAgendaEdit(original: item) }
                        } else {
                            Text(item)
                                .font(.subheadline)
                                .onTapGesture(count: 2) {
                                    editingAgendaItem = item
                                    editingAgendaText = item
                                }
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            agendaItems.removeAll { $0 == item }
                            editingAgendaItem = nil
                            persistAgenda()
                        } label: {
                            Label("Done", systemImage: "checkmark")
                        }
                    }
                }
            }
            if isAddingAgendaItem {
                HStack {
                    TextField("Add item…", text: $newAgendaItem)
                        .onSubmit { commitAgendaItem() }
                    Button("Add") { commitAgendaItem() }
                        .disabled(newAgendaItem.trimmingCharacters(in: .whitespaces).isEmpty)
                        .foregroundStyle(.blue)
                }
            }
        } header: {
            HStack {
                Text("Agenda")
                if isSavingAgenda {
                    ProgressView().scaleEffect(0.7).padding(.leading, 4)
                }
                Spacer()
                Button {
                    isAddingAgendaItem = true
                } label: {
                    Image(systemName: "plus")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .disabled(isAddingAgendaItem)
            }
        }

        // Interactions
        Section {
            if isLoadingInteractions {
                ProgressView().frame(maxWidth: .infinity)
            } else if interactions.isEmpty {
                Text("No interactions logged yet")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                    .padding(.vertical, 4)
            } else {
                let shown = showAllInteractions ? interactions : Array(interactions.prefix(5))
                ForEach(shown) { interaction in
                    Button { selectedInteraction = interaction } label: {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Label(interaction.type.capitalized,
                                          systemImage: interactionIcon(interaction.type))
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Text(interaction.date.formatted(.dateTime.month(.abbreviated).day().year()))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if let notes = interaction.notes, !notes.isEmpty {
                                    Text(notes)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .padding(.top, 3)
                        }
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                }
                if interactions.count > 5 {
                    Button(showAllInteractions ? "Show less" : "Show all \(interactions.count)") {
                        showAllInteractions.toggle()
                    }
                    .font(.subheadline)
                    .foregroundStyle(.blue)
                    .padding(.vertical, 2)
                }
            }
        } header: {
            HStack {
                Text("Interactions")
                Spacer()
                Button {
                    showingLogInteraction = true
                } label: {
                    Image(systemName: "plus")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Notes Tab

    @ViewBuilder
    private func notesTab(_ d: PersonDetail) -> some View {
        if isLoadingNoteStore {
            Section {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            }
        } else {
            Section {
                MarkdownEditorView(
                    text: $noteStoreText,
                    onSave: { content in
                        let path = "Notes/People/\(personName).md"
                        try? NoteStore.shared.writeFile(path, content: content)
                    },
                    placeholder: "Notes about \(personName)…",
                    relativePath: "Notes/People/\(personName).md"
                )
                .frame(minHeight: 420)
                .listRowInsets(EdgeInsets())
            }
        }
    }

    // MARK: - Hero Section

    @ViewBuilder
    private func heroSection(_ d: PersonDetail) -> some View {
        HStack(alignment: .center, spacing: 20) {
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
            if let urlStr = d.photoURL, !urlStr.isEmpty {
                PersonPhotoCircle(urlString: urlStr, size: 120, initials: personInitials(d.name))
            } else {
                initialsCircle(d.name, size: 120)
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
            Button(role: .destructive) {
                Task {
                    try? await notion.linkPersonToPlace(personID: personID, placeID: nil)
                    await loadDetail()
                }
            } label: {
                Text("Unlink Place").font(.subheadline)
            }
        } else {
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

    // MARK: - Helpers

    @ViewBuilder
    private func row(_ label: String, value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
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

    private func normalizeID(_ id: String) -> String {
        id.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private func interactionIcon(_ type: String) -> String {
        switch type.lowercased() {
        case "call":    return "phone"
        case "email":   return "envelope"
        case "meeting": return "person.2"
        case "coffee":  return "cup.and.saucer"
        case "social":  return "figure.socialdance"
        default:        return "bubble.left"
        }
    }

    // MARK: - Agenda

    private func commitAgendaEdit(original: String) {
        let trimmed = editingAgendaText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, let idx = agendaItems.firstIndex(of: original) {
            agendaItems[idx] = trimmed
            persistAgenda()
        }
        editingAgendaItem = nil
        editingAgendaText = ""
    }

    private func commitAgendaItem() {
        let trimmed = newAgendaItem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        agendaItems.append(trimmed)
        newAgendaItem = ""
        isAddingAgendaItem = false
        persistAgenda()
    }

    private func persistAgenda() {
        let combined = agendaItems.joined(separator: "\n")
        isSavingAgenda = true
        Task {
            try? await notion.updatePersonAgenda(id: personID, agenda: combined)
            isSavingAgenda = false
        }
    }

    // MARK: - Data loading

    private func loadDetail() async {
        isLoading = true
        do {
            // Always bypass the cache so photos/edits made on other devices are visible immediately.
            notion.personDetailCache.removeValue(forKey: personID)
            var d = try await notion.fetchPersonDetail(id: personID)
            // NoteStore photo (Photos/People/<Name>.jpg) takes precedence over any Notion external URL.
            d.photoURL = resolvePersonPhoto(name: d.name, fallbackURL: d.photoURL)
            detail = d
            isArchived = d.isArchived
            agendaItems = (d.agenda ?? "")
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func loadInteractions() async {
        isLoadingInteractions = true
        interactions = (try? await notion.fetchInteractions(personID: personID)) ?? []
        isLoadingInteractions = false
    }

    private func loadNoteStoreNote() {
        guard !isLoadingNoteStore else { return }
        isLoadingNoteStore = true
        Task {
            let path = "Notes/People/\(personName).md"
            noteStoreText = (try? NoteStore.shared.readFile(path)) ?? ""
            isLoadingNoteStore = false
        }
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
}

// MARK: - Person Edit Sheet

struct PersonEditSheet: View {
    @Environment(NotionService.self) private var notion
    @Environment(\.dismiss) private var dismiss

    let personID: String
    let detail: PersonDetail

    private let relationships = ["colleague", "friend", "family", "neighbor", "client", "mentor", "business", "Pool Team", "other"]
    private let tagOptions = ["Family", "Business", "Friend", "Network", "Work", "Pool", "Reference"]

    @State private var name = ""
    @State private var relationship = ""
    @State private var isArchived = false
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

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        ZStack(alignment: .bottomTrailing) {
                            if let img = pickedImage {
                                Image(uiImage: img)
                                    .resizable().scaledToFill()
                                    .frame(width: 90, height: 90)
                                    .clipShape(Circle())
                            } else if let url = detail.photoURL, !url.isEmpty {
                                PersonPhotoCircle(
                                    urlString: url,
                                    size: 90,
                                    initials: personInitials(detail.name)
                                )
                            } else {
                                personInitialsView
                            }

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
                            Text("Saving photo…").font(.caption).foregroundStyle(.secondary)
                        }
                    } else if pickedImage != nil {
                        Label("Photo ready to save", systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(.green)
                    }
                }

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
                    Toggle("Archived", isOn: $isArchived)
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
                    // Use person name as filename so Photos/People/ stays legible.
                    // Delete the old photo file if it was a NoteStore-relative path.
                    if let oldPath = detail.photoURL, oldPath.hasPrefix("Photos/") {
                        try? NoteStore.shared.deleteFile(oldPath)
                    }
                    let safeName = sanitizedPersonFilename(detail.name)
                    let filename = "\(safeName).jpg"
                    // Write to NoteStore (iCloud). Not stored in Notion — resolvePersonPhoto
                    // picks this file up by name at next load.
                    _ = try? NoteStore.shared.writePhoto(data, category: "People", filename: filename)
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
        name = detail.name
        relationship = detail.relationship ?? ""
        isArchived = detail.isArchived
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
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        do {
            try await notion.enrichPerson(
                id: personID,
                name: trimmedName == detail.name ? nil : trimmedName,
                relationship: relationship,
                relationshipStrength: isArchived ? "archived" : "",
                companyContext: companyContext,
                city: city,
                howWeMet: howWeMet,
                tags: Array(selectedTags),
                phone: phone,
                email: email,
                address: address
                // photoURL intentionally omitted — photo lives in NoteStore at
                // Photos/People/<Name>.jpg and is resolved at load time, not stored in Notion.
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            isSaving = false
        }
    }
}

// MARK: - Interaction Detail Sheet

private struct InteractionDetailSheet: View {
    let interaction: Interaction

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Type", value: interaction.type.capitalized)
                    LabeledContent("Date", value: interaction.date.formatted(.dateTime.month(.wide).day().year()))
                }
                if let notes = interaction.notes, !notes.isEmpty {
                    Section("Notes") {
                        Text(notes).font(.body)
                    }
                }
                Section {
                    Button {
                        let cleanID = interaction.id.replacingOccurrences(of: "-", with: "")
                        if let url = URL(string: "https://notion.so/\(cleanID)") {
                            openURL(url)
                        }
                    } label: {
                        Label("Open in Notion", systemImage: "arrow.up.right.square")
                            .foregroundStyle(.blue)
                    }
                }
            }
            .navigationTitle(interaction.summary.isEmpty ? interaction.type.capitalized : interaction.summary)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Log Interaction Sheet

private struct LogInteractionSheet: View {
    let personID: String
    let personName: String
    let onSaved: () -> Void

    @Environment(NotionService.self) private var notion
    @Environment(\.dismiss) private var dismiss

    private let typeOptions = ["call", "email", "meeting", "coffee", "social", "other"]

    @State private var selectedType = "call"
    @State private var date = Date()
    @State private var notes = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Type") {
                    Picker("Type", selection: $selectedType) {
                        ForEach(typeOptions, id: \.self) { t in
                            Text(t.capitalized).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }
                Section("Date") {
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                        .datePickerStyle(.compact)
                        .labelsHidden()
                }
                Section("Notes (optional)") {
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $notes)
                            .frame(minHeight: 80)
                        if notes.isEmpty {
                            Text("What did you talk about?")
                                .foregroundStyle(Color(.placeholderText))
                                .font(.body)
                                .padding(.top, 8)
                                .padding(.leading, 5)
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
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView().scaleEffect(0.8)
                    } else {
                        Button("Save") { save() }
                    }
                }
            }
        }
    }

    private func save() {
        isSaving = true
        Task {
            do {
                try await notion.createInteraction(
                    personID: personID,
                    summary: "\(selectedType.capitalized) with \(personName)",
                    date: date,
                    type: selectedType,
                    notes: notes
                )
                onSaved()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }
}
