// TraceMacPeopleView.swift
// People section — tabbed detail matching iOS PersonDetailView.
// Mac-only — do not add to iOS, Widget, or Share Extension targets.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Photo helpers (mirrors PersonDetailView.swift — keep in sync)

/// Returns a filesystem-safe filename stem from a person's name.
private func sanitizedPersonFilename(_ name: String) -> String {
    let bad = CharacterSet(charactersIn: "/\\:*?\"<>|")
    return name.components(separatedBy: bad).joined(separator: "_")
}

/// Returns the canonical NoteStore path for a person's photo if the file exists locally;
/// otherwise returns the fallback URL (a legacy Notion external URL).
/// Checks .jpg, .jpeg, .png, and .heic so the extension of the source file doesn't matter.
private func resolvePersonPhoto(name: String, fallbackURL: String?) -> String? {
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

// MARK: - Root

struct TraceMacPeopleView: View {

    @Environment(NotionService.self) private var notionService

    @State private var selectedID: String? = nil
    @State private var searchText = ""
    @State private var detail: PersonDetail? = nil
    @State private var interactions: [Interaction] = []
    @State private var isLoading = false
    @State private var selectedTab: PeopleTab = .info

    @State private var showAddPerson = false
    @State private var showDeletePerson = false
    @State private var showEditPerson = false
    @State private var listCollapsed = false
    @State private var isUploadingPhoto = false
    @State private var avatarHovering = false
    @State private var showArchived = false

    enum PeopleTab: String, CaseIterable {
        case info     = "Info"
        case activity = "Activity"
        case log      = "Log"
        case notes    = "Notes"
    }

    private var filteredPeople: [Person] {
        let sorted = notionService.people
            .filter { showArchived ? $0.isArchived : !$0.isArchived }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guard !searchText.isEmpty else { return sorted }
        return sorted.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        HStack(spacing: 0) {
            if !listCollapsed { peopleList }
            CollapseHandle(isCollapsed: $listCollapsed, collapsesRight: false, showLine: true, panelColor: .clear)
            detailArea.frame(maxWidth: .infinity)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showAddPerson = true } label: {
                    Label("New Person", systemImage: "person.badge.plus")
                }
            }
            if detail != nil {
                ToolbarItem {
                    Button { showEditPerson = true } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .help("Edit person")
                }
                ToolbarItem {
                    Button { selectedTab = .log } label: {
                        Label("Log", systemImage: "bubble.left.and.bubble.right")
                    }
                    .keyboardShortcut("l", modifiers: .command)
                    .help("Log Interaction (⌘L)")
                }
            }
        }
        .sheet(isPresented: $showAddPerson) {
            AddPersonSheet(notionService: notionService) { newPerson in
                selectedID = newPerson.id
            }
        }
        .sheet(isPresented: $showEditPerson) {
            if let d = detail {
                MacPersonEditSheet(personID: d.id, detail: d, notionService: notionService) {
                    Task { await reloadDetail(id: d.id) }
                }
            }
        }
        .task {
            if notionService.people.isEmpty { await notionService.fetchPeople() }
            if notionService.visits.isEmpty { await notionService.fetchVisits() }
            if notionService.places.isEmpty { await notionService.fetchPlaces() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectPerson)) { note in
            if let id = note.userInfo?["id"] as? String {
                selectedID = id
            }
        }
        .onChange(of: selectedID) { _, newID in
            guard let id = newID else { detail = nil; interactions = []; return }
            selectedTab = .info
            Task { await loadDetail(id: id) }
        }
    }

    // MARK: - People list

    private var peopleList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                TextField("Search", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                Button {
                    showArchived.toggle()
                    selectedID = nil
                } label: {
                    Image(systemName: showArchived ? "archivebox.fill" : "archivebox")
                        .foregroundStyle(showArchived ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help(showArchived ? "Showing archived — click to return" : "Show archived")
            }
            .padding(10)
            if showArchived {
                Text("Archived").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.bottom, 4)
            }
            Divider()
            if filteredPeople.isEmpty {
                Spacer()
                Text(showArchived ? "No archived people." : notionService.people.isEmpty ? "No people yet." : "No matches.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
            } else {
                List(filteredPeople, selection: $selectedID) { person in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(person.name)
                            .font(.system(.body, weight: .medium))
                        if let rel = person.relationship {
                            Text(rel.capitalized)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 3)
                    .tag(person.id)
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .frame(width: 200)
    }

    // MARK: - Detail area

    @ViewBuilder
    private var detailArea: some View {
        if isLoading {
            ProgressView("Loading…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let d = detail {
            VStack(spacing: 0) {
                personHeader(d)
                Divider()
                Picker("Tab", selection: $selectedTab) {
                    ForEach(PeopleTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                Divider()

                switch selectedTab {
                case .info:
                    MacInfoTab(
                        detail: d,
                        notionService: notionService,
                        onDeletePerson: { showDeletePerson = true }
                    )
                case .activity:
                    MacActivityTab(
                        personID: d.id,
                        detail: d,
                        notionService: notionService
                    )
                case .log:
                    MacLogTab(
                        detail: d,
                        interactions: $interactions,
                        notionService: notionService
                    )
                case .notes:
                    NotesTab(personName: d.name)
                }
            }
            .confirmationDialog(
                "Delete \"\(d.name)\"?",
                isPresented: $showDeletePerson,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) { deletePerson(d) }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This will archive the person in Notion.")
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

    // MARK: - Person header (avatar + name + quick actions)

    private func personHeader(_ d: PersonDetail) -> some View {
        HStack(spacing: 20) {
            // Avatar — click to upload a photo
            Button {
                pickPhoto(for: d)
            } label: {
                ZStack {
                    Group {
                        if let urlString = d.photoURL {
                            if urlString.hasPrefix("Photos/"),
                               let fileURL = NoteStore.shared.resolvedURL(for: urlString),
                               let nsImg = NSImage(contentsOf: fileURL) {
                                Image(nsImage: nsImg)
                                    .resizable()
                                    .scaledToFill()
                            } else if let webURL = URL(string: urlString) {
                                AsyncImage(url: webURL) { phase in
                                    if let img = phase.image { img.resizable().scaledToFill() }
                                    else { initialsCircle(d.name, size: 72) }
                                }
                            } else {
                                initialsCircle(d.name, size: 72)
                            }
                        } else {
                            initialsCircle(d.name, size: 72)
                        }
                    }
                    .frame(width: 72, height: 72)
                    .clipShape(Circle())

                    // Camera badge revealed on hover
                    if avatarHovering || isUploadingPhoto {
                        Circle()
                            .fill(.black.opacity(0.45))
                            .frame(width: 72, height: 72)
                        Image(systemName: isUploadingPhoto ? "arrow.2.circlepath" : "camera.fill")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 72, height: 72)
                .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { avatarHovering = $0 }
            .help("Click to upload a photo")

            // Name + meta
            VStack(alignment: .leading, spacing: 3) {
                Text(d.name)
                    .font(.system(size: 22, weight: .semibold))
                HStack(spacing: 6) {
                    if let rel = d.relationship {
                        Text(rel.capitalized).font(.subheadline).foregroundStyle(.secondary)
                    }
                    if let co = d.companyContext, !co.isEmpty {
                        if d.relationship != nil { Text("·").foregroundStyle(.tertiary) }
                        Text(co).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                if let strength = d.relationshipStrength {
                    strengthBadge(strength)
                }
                if let last = d.lastInteractionDate {
                    let days = Calendar.current.dateComponents([.day], from: last, to: Date()).day ?? 0
                    Text(days == 0 ? "Seen today" : days == 1 ? "Seen yesterday" : "Last seen \(days) days ago")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }

            Spacer()

            // Quick action buttons (matching iOS hero)
            VStack(alignment: .leading, spacing: 8) {
                if let phone = d.phone, !phone.isEmpty {
                    let digits = phone.filter { $0.isNumber || $0 == "+" }
                    quickAction(icon: "phone.fill", label: "Call", color: .green) {
                        NSWorkspace.shared.open(URL(string: "tel:\(digits)")!)
                    }
                    quickAction(icon: "message.fill", label: "Message", color: .blue) {
                        NSWorkspace.shared.open(URL(string: "sms:\(digits)")!)
                    }
                }
                if let email = d.email, !email.isEmpty {
                    quickAction(icon: "envelope.fill", label: "Email", color: .orange) {
                        NSWorkspace.shared.open(URL(string: "mailto:\(email)")!)
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func quickAction(icon: String, label: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(color)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func strengthBadge(_ strength: String) -> some View {
        if strength == "archived" {
            Text("Archived")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Color.secondary.opacity(0.12))
                .foregroundStyle(Color.secondary)
                .clipShape(Capsule())
        }
    }

    @ViewBuilder
    private func initialsCircle(_ name: String, size: CGFloat) -> some View {
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

    // MARK: - Photo helpers

    /// Resolves a photo URL string to a URL usable by AsyncImage.
    /// Local relative paths (e.g. "Photos/People/…") go through NoteStore;
    /// everything else is treated as a web URL.
    private func resolvedPhotoURL(_ urlString: String) -> URL? {
        if urlString.hasPrefix("Photos/") {
            return NoteStore.shared.resolvedURL(for: urlString)
        }
        return URL(string: urlString)
    }

    private func pickPhoto(for d: PersonDetail) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.jpeg, .png, .heic]
        panel.title = "Choose a photo for \(d.name)"
        guard panel.runModal() == .OK, let fileURL = panel.url else { return }
        guard let data = try? Data(contentsOf: fileURL) else { return }
        isUploadingPhoto = true
        Task {
            defer { isUploadingPhoto = false }
            // Delete the old NoteStore photo before writing the new one.
            if let oldPath = d.photoURL, oldPath.hasPrefix("Photos/") {
                try? NoteStore.shared.deleteFile(oldPath)
            }
            let ext = fileURL.pathExtension.lowercased()
            let safeName = sanitizedPersonFilename(d.name)
            let filename = "\(safeName).\(ext.isEmpty ? "jpg" : ext)"
            // Write to NoteStore (iCloud). resolvePersonPhoto picks this up at next load.
            // Photo is NOT written to Notion — NoteStore is the sole photo store.
            guard (try? NoteStore.shared.writePhoto(data, category: "People", filename: filename)) != nil else { return }
            await reloadDetail(id: d.id)
        }
    }

    // MARK: - Actions

    private func loadDetail(id: String) async {
        isLoading = true
        detail = nil
        interactions = []
        async let d = notionService.fetchPersonDetail(id: id)
        async let i = notionService.fetchInteractions(personID: id)
        var fetched = try? await d
        if let f = fetched {
            fetched?.photoURL = resolvePersonPhoto(name: f.name, fallbackURL: f.photoURL)
        }
        detail = fetched
        interactions = (try? await i) ?? []
        isLoading = false
    }

    private func reloadDetail(id: String) async {
        notionService.personDetailCache.removeValue(forKey: id)
        var d = try? await notionService.fetchPersonDetail(id: id)
        if let fetched = d {
            d?.photoURL = resolvePersonPhoto(name: fetched.name, fallbackURL: fetched.photoURL)
        }
        detail = d
    }

    private func deletePerson(_ d: PersonDetail) {
        Task {
            try? await notionService.deletePerson(id: d.id)
            detail = nil; interactions = []; selectedID = nil
        }
    }
}

// MARK: - Info tab

struct MacInfoTab: View {

    let detail: PersonDetail
    let notionService: NotionService
    let onDeletePerson: () -> Void

    @State private var isArchived: Bool
    @State private var editPhone: String
    @State private var editEmail: String
    @State private var editAddress: String
    @State private var isSavingContact = false

    init(detail: PersonDetail, notionService: NotionService, onDeletePerson: @escaping () -> Void) {
        self.detail = detail
        self.notionService = notionService
        self.onDeletePerson = onDeletePerson
        _isArchived  = State(initialValue: detail.isArchived)
        _editPhone   = State(initialValue: detail.phone   ?? "")
        _editEmail   = State(initialValue: detail.email   ?? "")
        _editAddress = State(initialValue: detail.address ?? "")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                // Identity fields
                infoSection {
                    infoRow("Relationship", value: detail.relationship.map { $0.capitalized } ?? "None")
                    if let co = detail.companyContext, !co.isEmpty { infoRow("Company", value: co) }
                    if let city = detail.city, !city.isEmpty { infoRow("City", value: city) }
                    if let bday = detail.birthday {
                        infoRow("Birthday", value: bday.formatted(.dateTime.month(.wide).day()))
                    }
                    if let met = detail.howWeMet, !met.isEmpty { infoRow("How We Met", value: met) }
                }

                // Contact — always shown, inline editable
                sectionHeader("Contact")
                infoSection {
                    contactEditRow("Phone", text: $editPhone, placeholder: "Add phone") {
                        let digits = editPhone.filter { $0.isNumber || $0 == "+" }
                        if !digits.isEmpty { NSWorkspace.shared.open(URL(string: "tel:\(digits)")!) }
                    }
                    Divider().padding(.leading, 20)
                    contactEditRow("Email", text: $editEmail, placeholder: "Add email") {
                        if !editEmail.isEmpty { NSWorkspace.shared.open(URL(string: "mailto:\(editEmail)")!) }
                    }
                    Divider().padding(.leading, 20)
                    contactEditRow("Address", text: $editAddress, placeholder: "Add address") {
                        let encoded = editAddress.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                        if !encoded.isEmpty { NSWorkspace.shared.open(URL(string: "maps://?q=\(encoded)")!) }
                    }
                }
                .onChange(of: detail.id) { _, _ in
                    editPhone   = detail.phone   ?? ""
                    editEmail   = detail.email   ?? ""
                    editAddress = detail.address ?? ""
                }

                // Home place
                sectionHeader("Place")
                infoSection {
                    placeSection
                }

                // Tags
                if !detail.tags.isEmpty {
                    sectionHeader("Tags")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(detail.tags, id: \.self) { tag in
                                Text(tag)
                                    .font(.caption)
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(Color.accentColor.opacity(0.12))
                                    .foregroundStyle(Color.accentColor)
                                    .clipShape(Capsule())
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                    }
                }

                Divider()

                // Delete
                HStack {
                    Spacer()
                    // Archive toggle icon
                    Button {
                        let newVal = !isArchived
                        isArchived = newVal
                        Task {
                            try? await notionService.updatePersonStatus(
                                id: detail.id,
                                relationshipStrength: newVal ? "archived" : ""
                            )
                        }
                    } label: {
                        Image(systemName: isArchived ? "archivebox.fill" : "archivebox")
                            .font(.system(size: 13))
                            .foregroundStyle(isArchived ? Color.accentColor : Color.secondary.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                    .help(isArchived ? "Unarchive person" : "Archive person")

                    Divider()
                        .frame(height: 14)
                        .padding(.horizontal, 8)

                    Button(role: .destructive, action: onDeletePerson) {
                        Image(systemName: "trash")
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Delete person")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        }
    }

    // MARK: - Place section

    @ViewBuilder
    private var placeSection: some View {
        if let placeID = detail.homePlaceID,
           let place = notionService.places.first(where: {
               $0.id.replacingOccurrences(of: "-", with: "").lowercased() ==
               placeID.replacingOccurrences(of: "-", with: "").lowercased()
           }) {
            HStack(spacing: 12) {
                Image(systemName: placeIcon(for: place.category))
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(placeColor(for: place.category))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 2) {
                    Text(place.name).font(.callout)
                    if !place.city.isEmpty {
                        Text(place.city).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 20).padding(.vertical, 8)
            Button(role: .destructive) {
                Task {
                    try? await notionService.linkPersonToPlace(personID: detail.id, placeID: nil)
                }
            } label: {
                Text("Unlink Place").font(.callout).foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20).padding(.bottom, 8)
        } else {
            Text("No home place linked.")
                .font(.callout).foregroundStyle(.tertiary)
                .padding(.horizontal, 20).padding(.vertical, 8)
        }
    }

    // MARK: - Row builders

    @ViewBuilder
    private func infoSection<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.12)))
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private func infoRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary).font(.callout)
            Spacer()
            Text(value).font(.callout).multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 20).padding(.vertical, 8)
    }

    private func tappableRow(_ label: String, value: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(label).foregroundStyle(.secondary).font(.callout)
                Spacer()
                Text(value).foregroundStyle(Color.accentColor).font(.callout).multilineTextAlignment(.trailing)
            }
            .padding(.horizontal, 20).padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }

    /// Inline-editable contact field. Saves on Return; action button fires if value is non-empty.
    private func contactEditRow(
        _ label: String,
        text: Binding<String>,
        placeholder: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .font(.callout)
                .frame(width: 64, alignment: .leading)
            TextField(placeholder, text: text)
                .font(.callout)
                .foregroundStyle(text.wrappedValue.isEmpty ? .tertiary : .primary)
                .multilineTextAlignment(.leading)
                .onSubmit { saveContactFields() }
            Spacer(minLength: 0)
            if !text.wrappedValue.isEmpty {
                Button(action: action) {
                    Image(systemName: label == "Phone" ? "phone" : label == "Email" ? "envelope" : "map")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 8)
    }

    private func saveContactFields() {
        guard !isSavingContact else { return }
        isSavingContact = true
        Task {
            defer { isSavingContact = false }
            try? await notionService.enrichPerson(
                id: detail.id,
                relationship: nil,
                relationshipStrength: nil,
                companyContext: nil,
                city: nil,
                howWeMet: nil,
                tags: detail.tags,
                phone: editPhone.isEmpty   ? nil : editPhone,
                email: editEmail.isEmpty   ? nil : editEmail,
                address: editAddress.isEmpty ? nil : editAddress
            )
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 4)
    }
}

// MARK: - Activity tab

struct MacActivityTab: View {

    let personID: String
    let detail: PersonDetail
    let notionService: NotionService

    @State private var showAllVisits = false

    private var sharedVisits: [Visit] {
        notionService.visits
            .filter { $0.peopleIDs.contains(personID) }
            .sorted { $0.date > $1.date }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                // Stats row
                HStack(spacing: 24) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(sharedVisits.count)")
                            .font(.title2.bold())
                        Text("visits together")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let lv = detail.lastVisitDate {
                        Divider().frame(height: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(lv.formatted(.dateTime.month(.abbreviated).day().year()))
                                .font(.subheadline.weight(.medium))
                            Text("last visit")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(20)

                Divider()

                // Visits
                sectionHeader("Visits Together")

                if sharedVisits.isEmpty {
                    Text("No visits together yet.")
                        .font(.callout).foregroundStyle(.tertiary)
                        .padding(.horizontal, 20).padding(.top, 8)
                } else {
                    let visitsToShow = showAllVisits ? sharedVisits : Array(sharedVisits.prefix(5))
                    VStack(spacing: 0) {
                        ForEach(visitsToShow) { visit in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(visit.placeName).font(.callout)
                                    Text(visit.date.formatted(.dateTime.month(.abbreviated).day().year()))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let r = visit.rating, r > 0 {
                                    Text(String(repeating: "★", count: min(r, 7)))
                                        .font(.caption).foregroundStyle(.orange)
                                }
                            }
                            .padding(.horizontal, 20).padding(.vertical, 8)
                            if visit.id != visitsToShow.last?.id { Divider().padding(.leading, 20) }
                        }
                    }
                    if sharedVisits.count > 5 {
                        Button(showAllVisits ? "Show less" : "Show all \(sharedVisits.count) visits") {
                            showAllVisits.toggle()
                        }
                        .font(.subheadline).foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 20).padding(.vertical, 8)
                    }
                }

                Spacer(minLength: 20)
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 4)
    }
}

// MARK: - Log tab (Agenda + Log form)

struct MacLogTab: View {

    let detail: PersonDetail
    @Binding var interactions: [Interaction]
    let notionService: NotionService

    @State private var agendaItems: [String] = []
    @State private var newAgendaItem = ""
    @State private var isAddingAgenda = false
    @State private var isSavingAgenda = false
    @State private var editingAgendaItem: String? = nil
    @State private var editingAgendaText = ""

    @State private var editingInteraction: Interaction? = nil
    @State private var deleteCandidate: Interaction? = nil
    @State private var showDeleteConfirm = false

    @State private var type = "meeting"
    @State private var date = Date()
    @State private var notes = ""
    @State private var isSaving = false
    @State private var saveError: String? = nil

    private let types = ["meeting", "call", "email", "coffee", "social", "other"]

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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                // Agenda section
                agendaHeader
                agendaBody

                Divider().padding(.vertical, 12)

                // Interaction history
                HStack {
                    Text("INTERACTIONS")
                        .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(.horizontal, 20).padding(.bottom, 4)

                if interactions.isEmpty {
                    Text("No interactions logged yet.")
                        .font(.callout).foregroundStyle(.tertiary)
                        .padding(.horizontal, 20).padding(.bottom, 12)
                } else {
                    VStack(spacing: 0) {
                        ForEach(interactions) { ix in
                            MacInteractionRow(interaction: ix)
                                .contentShape(Rectangle())
                                .onTapGesture { editingInteraction = ix }
                                .contextMenu {
                                    Button("Edit") { editingInteraction = ix }
                                    Divider()
                                    Button("Delete", role: .destructive) {
                                        deleteCandidate = ix
                                        showDeleteConfirm = true
                                    }
                                }
                            if ix.id != interactions.last?.id { Divider().padding(.leading, 20) }
                        }
                    }
                }

                Divider().padding(.vertical, 12)

                // Log form
                Text("LOG INTERACTION")
                    .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    .padding(.horizontal, 20).padding(.bottom, 8)

                VStack(alignment: .leading, spacing: 14) {
                    Picker("Type", selection: $type) {
                        ForEach(types, id: \.self) { t in Text(t.capitalized).tag(t) }
                    }
                    .pickerStyle(.segmented)

                    DatePicker("Date", selection: $date, displayedComponents: .date)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Notes").font(.caption).foregroundStyle(.secondary)
                        ZStack(alignment: .topLeading) {
                            TextEditor(text: $notes)
                                .font(.system(size: 13))
                                .frame(minHeight: 70)
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
                            if notes.isEmpty {
                                Text("What did you talk about?")
                                    .foregroundStyle(Color.secondary.opacity(0.5))
                                    .font(.system(size: 13))
                                    .padding(.top, 8).padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }
                    }

                    if let err = saveError {
                        Text(err).font(.caption).foregroundStyle(.red)
                    }

                    HStack {
                        Spacer()
                        if isSaving { ProgressView().controlSize(.small) }
                        Button("Save") { saveInteraction() }
                            .buttonStyle(.borderedProminent)
                            .disabled(isSaving)
                            .keyboardShortcut(.return, modifiers: .command)
                    }
                }
                .padding(.horizontal, 20)

                Spacer(minLength: 20)
            }
            .padding(.top, 8)
        }
        .onAppear {
            agendaItems = (detail.agenda ?? "")
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)
        }
        .sheet(item: $editingInteraction) { ix in
            EditInteractionSheet(interaction: ix, notionService: notionService) { updated in
                if let idx = interactions.firstIndex(where: { $0.id == updated.id }) {
                    interactions[idx] = updated
                }
            }
        }
        .confirmationDialog("Delete this interaction?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let ix = deleteCandidate {
                    Task {
                        try? await notionService.deleteInteraction(id: ix.id)
                        interactions.removeAll { $0.id == ix.id }
                    }
                }
            }
            Button("Cancel", role: .cancel) { }
        }
    }

    // MARK: - Agenda sub-views

    private var agendaHeader: some View {
        HStack {
            Text("AGENDA")
                .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            if isSavingAgenda { ProgressView().scaleEffect(0.6).padding(.leading, 2) }
            Spacer()
            Button { isAddingAgenda = true } label: {
                Image(systemName: "plus").font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .disabled(isAddingAgenda)
        }
        .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 4)
    }

    private var agendaBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            if agendaItems.isEmpty && !isAddingAgenda {
                Text("Nothing queued")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.horizontal, 20).padding(.vertical, 6)
            }
            ForEach(agendaItems, id: \.self) { item in
                Group {
                    if editingAgendaItem == item {
                        TextField("", text: $editingAgendaText)
                            .font(.callout)
                            .onSubmit { commitEdit(original: item) }
                            .padding(.horizontal, 20).padding(.vertical, 6)
                    } else {
                        HStack {
                            Text(item).font(.callout)
                            Spacer()
                        }
                        .padding(.horizontal, 20).padding(.vertical, 6)
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
                    } label: { Label("Done", systemImage: "checkmark") }
                }
                if item != agendaItems.last { Divider().padding(.leading, 20) }
            }
            if isAddingAgenda {
                HStack {
                    TextField("Add item…", text: $newAgendaItem)
                        .font(.callout)
                        .onSubmit { commitAgendaItem() }
                    Button("Add") { commitAgendaItem() }
                        .disabled(newAgendaItem.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 20).padding(.vertical, 6)
            }
        }
    }

    // MARK: - Agenda helpers

    private func commitEdit(original: String) {
        let trimmed = editingAgendaText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, let idx = agendaItems.firstIndex(of: original) {
            agendaItems[idx] = trimmed
            persistAgenda()
        }
        editingAgendaItem = nil
        editingAgendaText = ""
    }

    private func commitAgendaItem() {
        let trimmed = newAgendaItem.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        agendaItems.append(trimmed)
        newAgendaItem = ""
        isAddingAgenda = false
        persistAgenda()
    }

    private func persistAgenda() {
        isSavingAgenda = true
        let joined = agendaItems.joined(separator: "\n")
        Task {
            try? await notionService.updatePersonAgenda(id: detail.id, agenda: joined)
            isSavingAgenda = false
        }
    }

    private func saveInteraction() {
        isSaving = true
        saveError = nil
        Task {
            do {
                let ix = try await notionService.createInteraction(
                    personID: detail.id,
                    summary: "\(type.capitalized) with \(detail.name)",
                    date: date,
                    type: type,
                    notes: notes
                )
                await MainActor.run {
                    interactions.insert(ix, at: 0)
                    notes = ""
                    date = Date()
                    type = "meeting"
                }
            } catch {
                saveError = "Save failed — check your connection."
            }
            isSaving = false
        }
    }
}

// MARK: - Notes tab

struct NotesTab: View {
    let personName: String

    private var relativePath: String { "Notes/People/\(personName).md" }

    var body: some View {
        TraceMacNoteEditor(relativePath: relativePath)
            .environment(NoteStore.shared)
            .onAppear {
                let store = NoteStore.shared
                if ((try? store.readFile(relativePath)) ?? "").isEmpty {
                    try? store.writeFile(relativePath, content: "# \(personName)\n\n")
                }
            }
    }
}

// MARK: - Add Person sheet

struct AddPersonSheet: View {

    let notionService: NotionService
    let onSaved: (Person) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var phone = ""
    @State private var email = ""
    @State private var relationship = ""
    @State private var tagsText = ""
    @State private var isSaving = false
    @State private var error: String? = nil

    private let relationships = ["Friend", "Family", "Colleague", "Acquaintance", "Client", "Mentor", "Business", "Pool Team", "Other"]

    var body: some View {
        VStack(spacing: 0) {
            Text("New Person").font(.headline).padding()
            Divider()
            Form {
                Section {
                    TextField("Name (required)", text: $name)
                    TextField("Phone", text: $phone)
                    TextField("Email", text: $email)
                }
                Section {
                    Picker("Relationship", selection: $relationship) {
                        Text("None").tag("")
                        ForEach(relationships, id: \.self) { r in Text(r).tag(r) }
                    }
                    TextField("Tags (comma-separated)", text: $tagsText)
                }
            }
            .formStyle(.grouped)
            if let err = error { Text(err).font(.caption).foregroundStyle(.red).padding(.horizontal) }
            Divider()
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                if isSaving { ProgressView().controlSize(.small) }
                Button("Create") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .padding()
        }
        .frame(width: 420, height: 360)
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }
        isSaving = true
        error = nil
        Task {
            do {
                let person = try await notionService.addPerson(name: trimmedName)
                let tags = tagsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                if !phone.isEmpty || !email.isEmpty || !relationship.isEmpty || !tags.isEmpty {
                    try? await notionService.enrichPerson(
                        id: person.id,
                        relationship: relationship.isEmpty ? nil : relationship.lowercased(),
                        relationshipStrength: nil, companyContext: nil, city: nil, howWeMet: nil,
                        tags: tags,
                        phone: phone.isEmpty ? nil : phone,
                        email: email.isEmpty ? nil : email
                    )
                }
                await MainActor.run { onSaved(person); dismiss() }
            } catch {
                self.error = "Could not create person."
            }
            isSaving = false
        }
    }
}

// MARK: - Edit Person sheet (Mac equivalent of iOS PersonEditSheet)

struct MacPersonEditSheet: View {

    let personID: String
    let detail: PersonDetail
    let notionService: NotionService
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss

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
    @State private var photoURL = ""
    @State private var isSaving = false
    @State private var error: String? = nil
    @State private var newCustomTag = ""
    @State private var showAddTag = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Text(detail.name).font(.headline)
                Spacer()
                Button(isSaving ? "Saving…" : "Save") { Task { await save() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving)
            }
            .padding()

            Divider()

            Form {
                Section("Name") {
                    TextField("Full name", text: $name)
                }
                Section("Identity") {
                    Picker("Category", selection: $relationship) {
                        Text("None").tag("")
                        ForEach(relationships, id: \.self) { r in Text(r.capitalized).tag(r) }
                    }
                    Toggle("Archived", isOn: $isArchived)
                    TextField("Company / Context", text: $companyContext)
                    TextField("City", text: $city)
                    TextField("How We Met", text: $howWeMet)
                }
                Section("Contact") {
                    TextField("Phone", text: $phone)
                    TextField("Email", text: $email)
                    TextField("Address", text: $address)
                }
                Section("Photo URL") {
                    TextField("https://…", text: $photoURL)
                }
                Section("Tags") {
                    FlowLayout(spacing: 8) {
                        ForEach(tagOptions, id: \.self) { tag in tagChip(tag) }
                        let customTags = Array(selectedTags).filter { !tagOptions.contains($0) }.sorted()
                        ForEach(customTags, id: \.self) { tag in tagChip(tag) }
                        Button { showAddTag = true } label: {
                            Label("Add", systemImage: "plus")
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Color.secondary.opacity(0.1))
                                .foregroundStyle(.secondary)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                }
            }
            .formStyle(.grouped)

            if let err = error {
                Text(err).font(.caption).foregroundStyle(.red).padding(.horizontal)
            }
        }
        .frame(width: 480, height: 560)
        .onAppear { prefill() }
        .alert("Add Tag", isPresented: $showAddTag) {
            TextField("Tag name", text: $newCustomTag)
            Button("Add") {
                let tag = newCustomTag.trimmingCharacters(in: .whitespaces)
                if !tag.isEmpty { selectedTags.insert(tag) }
                newCustomTag = ""
            }
            Button("Cancel", role: .cancel) { newCustomTag = "" }
        }
    }

    private func tagChip(_ tag: String) -> some View {
        Button {
            if selectedTags.contains(tag) { selectedTags.remove(tag) }
            else { selectedTags.insert(tag) }
        } label: {
            Text(tag)
                .font(.caption)
                .padding(.horizontal, 10).padding(.vertical, 5)
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
        photoURL = detail.photoURL ?? ""
        selectedTags = Set(detail.tags)
    }

    private func save() async {
        isSaving = true
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        do {
            try await notionService.enrichPerson(
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
                address: address,
                photoURL: photoURL.isEmpty ? nil : photoURL
            )
            await MainActor.run { onSaved(); dismiss() }
        } catch {
            self.error = error.localizedDescription
        }
        isSaving = false
    }
}

// MARK: - Edit Interaction sheet

struct EditInteractionSheet: View {

    let interaction: Interaction
    let notionService: NotionService
    let onSaved: (Interaction) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var type: String
    @State private var date: Date
    @State private var summary: String
    @State private var notes: String
    @State private var isSaving = false
    @State private var error: String? = nil

    private let types = ["meeting", "call", "email", "coffee", "social", "other"]

    init(interaction: Interaction, notionService: NotionService, onSaved: @escaping (Interaction) -> Void) {
        self.interaction = interaction
        self.notionService = notionService
        self.onSaved = onSaved
        _type    = State(initialValue: interaction.type)
        _date    = State(initialValue: interaction.date)
        _summary = State(initialValue: interaction.summary)
        _notes   = State(initialValue: interaction.notes ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Edit Interaction").font(.headline).padding()
            Divider()
            Form {
                Section {
                    Picker("Type", selection: $type) {
                        ForEach(types, id: \.self) { t in Text(t.capitalized).tag(t) }
                    }
                    .pickerStyle(.segmented)
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    TextField("Summary", text: $summary)
                }
                Section("Notes") {
                    TextEditor(text: $notes)
                        .font(.system(size: 13))
                        .frame(minHeight: 80)
                }
            }
            .formStyle(.grouped)
            if let err = error { Text(err).font(.caption).foregroundStyle(.red).padding(.horizontal) }
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
        Task {
            do {
                try await notionService.updateInteraction(
                    id: interaction.id, summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
                    type: type, date: date, notes: notes
                )
                var updated = interaction
                updated.summary = summary; updated.type = type; updated.date = date
                updated.notes = notes.isEmpty ? nil : notes
                await MainActor.run { onSaved(updated); dismiss() }
            } catch {
                self.error = "Save failed."
            }
            isSaving = false
        }
    }
}

// MARK: - Interaction row

struct MacInteractionRow: View {
    let interaction: Interaction

    private var typeColor: Color {
        switch interaction.type.lowercased() {
        case "call":    return .green
        case "email":   return .blue
        case "meeting": return .orange
        case "coffee":  return .brown
        case "visit":   return .purple
        case "social":  return .pink
        default:        return .secondary
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
                    .font(.system(.callout, weight: .medium)).lineLimit(2)
            }
            if let notes = interaction.notes, !notes.isEmpty {
                Text(notes).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}
