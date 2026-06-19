import SwiftUI

struct PlaceDetailView: View {
    let place: Place
    @Environment(NotionService.self) private var notionService
    @Environment(LocationManager.self) private var locationManager
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTab = 0
    @State private var showingCheckIn = false
    @State private var editingVisit: Visit? = nil
    @State private var showingEditPlace = false

    private var placeVisits: [Visit] {
        notionService.visits
            .filter { $0.placeID == place.id }
            .sorted { $0.date > $1.date }
    }
    private var livePlace: Place {
        notionService.places.first { $0.id == place.id } ?? place
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                placeHeader
                Picker("", selection: $selectedTab) {
                    Text("Overview").tag(0)
                    Text("Info").tag(1)
                    Text("Visits").tag(2)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)

                TabView(selection: $selectedTab) {
                    overviewTab.tag(0)
                    infoTab.tag(1)
                    visitsTab.tag(2)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                actionBar
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    HStack(spacing: 16) {
                        Button {
                            showingEditPlace = true
                        } label: {
                            Image(systemName: "pencil")
                        }
                        Button {
                            Task {
                                await notionService.fetchPlaces()
                                await notionService.fetchVisits()
                            }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showingCheckIn) {
            CheckInView(preselectedPlace: livePlace)
                .environment(NotionService.shared)
                .environment(LocationManager.shared)
        }
        .sheet(item: $editingVisit) { visit in
            VisitEditSheet(visit: visit)
                .environment(NotionService.shared)
        }
        .sheet(isPresented: $showingEditPlace) {
            PlaceEditSheet(place: livePlace)
                .environment(NotionService.shared)
        }
    }

    // MARK: - Header

    private var placeHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(place.name)
                .font(.title2.bold())
            HStack(spacing: 4) {
                if !place.category.isEmpty {
                    Text(place.category)
                }
                if !place.city.isEmpty {
                    Text("·")
                    Text(place.city)
                }
                if let dist = locationManager.formattedDistance(to: place) {
                    Text("·")
                    Text(dist)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }

    // MARK: - Overview

    private var overviewTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DetailRow(label: "Status") {
                    Text(place.status)
                        .foregroundStyle(place.status == "Visited" ? .green : .orange)
                        .bold()
                }
                if let summary = place.aiSummary, !summary.isEmpty {
                    DetailRow(label: "Summary") {
                        Text(summary)
                    }
                }
                if !place.tags.isEmpty {
                    DetailRow(label: "Tags") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(place.tags, id: \.self) { tag in
                                    Text(tag)
                                        .font(.caption)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                        .background(Color.secondary.opacity(0.15))
                                        .clipShape(Capsule())
                                }
                            }
                        }
                    }
                }
                if let rating = place.ratingPersonal {
                    DetailRow(label: "Your rating") {
                        StarDisplay(rating: rating)
                    }
                }
                if let external = place.ratingExternal {
                    DetailRow(label: "Google rating") {
                        Text(String(format: "%.1f", external))
                    }
                }
                DetailRow(label: "Visits") {
                    Text("\(place.visitCount)")
                }
                if let last = place.lastVisited {
                    DetailRow(label: "Last visited") {
                        Text(last, style: .date)
                    }
                }
            }
            .padding()
        }
    }

    // MARK: - Info

    private var infoTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !place.address.isEmpty {
                    DetailRow(label: "Address") {
                        Text(place.address)
                    }
                }
                if let phone = place.phone, !phone.isEmpty {
                    Button {
                        if let url = URL(string: "tel://\(phone.filter { $0.isNumber })") {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        DetailRow(label: "Phone") {
                            Text(phone).foregroundStyle(.blue)
                        }
                    }
                    .tint(.primary)
                }
                if let website = place.website, !website.isEmpty {
                    Button {
                        if let url = URL(string: website) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        DetailRow(label: "Website") {
                            Text(website)
                                .foregroundStyle(.blue)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .tint(.primary)
                }
                if let hours = place.hours, !hours.isEmpty {
                    DetailRow(label: "Hours") {
                        Text(hours)
                    }
                }
            }
            .padding()
        }
    }

    // MARK: - Visits

    private var visitsTab: some View {
        ScrollView {
            if placeVisits.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("No visits yet")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(placeVisits) { visit in
                        Button {
                            editingVisit = visit
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(visit.date, style: .date)
                                            .font(.subheadline.bold())
                                        Spacer()
                                        if !visit.photoURLs.isEmpty {
                                            Label("\(visit.photoURLs.count)", systemImage: "photo")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        if let rating = visit.rating {
                                            StarDisplay(rating: rating)
                                        }
                                    }
                                    if let notes = visit.notes, !notes.isEmpty {
                                        Text(notes)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .padding(.leading, 4)
                            }
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
                .padding()
            }
        }
        .refreshable { await notionService.fetchVisits() }
    }

    // MARK: - Action bar

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button {
                let url = URL(string: "maps://?daddr=\(place.latitude),\(place.longitude)")!
                UIApplication.shared.open(url)
            } label: {
                Label("Directions", systemImage: "arrow.triangle.turn.up.right.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .minimumScaleFactor(0.8)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button {
                showingCheckIn = true
            } label: {
                Label("Check In", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .minimumScaleFactor(0.8)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            Button {
                Task { try? await notionService.toggleFlagged(place) }
            } label: {
                Image(systemName: livePlace.flagged ? "star.fill" : "star")
                    .font(.title3)
                    .frame(width: 36)
            }
            .buttonStyle(.bordered)
            .tint(livePlace.flagged ? .yellow : .secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

// MARK: - Visit Edit Sheet

struct VisitEditSheet: View {
    let visit: Visit
    @Environment(NotionService.self) private var notion
    @Environment(\.dismiss) private var dismiss

    @State private var rating: Int
    @State private var notes: String
    @State private var isSaving = false

    init(visit: Visit) {
        self.visit = visit
        _rating = State(initialValue: visit.rating ?? 0)
        _notes = State(initialValue: visit.notes ?? "")
    }

    private var livePhotoURLs: [String] {
        notion.visits.first { $0.id == visit.id }?.photoURLs ?? visit.photoURLs
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Date") {
                    Text(visit.date, style: .date)
                        .foregroundStyle(.secondary)
                }
                if !livePhotoURLs.isEmpty {
                    Section("Photos") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(livePhotoURLs, id: \.self) { urlString in
                                    if let url = URL(string: urlString) {
                                        AsyncImage(url: url) { phase in
                                            switch phase {
                                            case .success(let image):
                                                image.resizable()
                                                    .scaledToFill()
                                                    .frame(width: 130, height: 130)
                                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                            case .failure:
                                                RoundedRectangle(cornerRadius: 10)
                                                    .fill(Color.secondary.opacity(0.15))
                                                    .frame(width: 130, height: 130)
                                                    .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
                                            default:
                                                RoundedRectangle(cornerRadius: 10)
                                                    .fill(Color.secondary.opacity(0.1))
                                                    .frame(width: 130, height: 130)
                                                    .overlay(ProgressView())
                                            }
                                        }
                                    }
                                }
                            }
                            .padding(.vertical, 6)
                        }
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    }
                }
                Section("Rating") {
                    HStack(spacing: 6) {
                        ForEach(1...7, id: \.self) { star in
                            Button {
                                rating = (rating == star) ? 0 : star
                            } label: {
                                Image(systemName: star <= rating ? "star.fill" : "star")
                                    .foregroundStyle(star <= rating ? .yellow : .secondary)
                                    .font(.title3)
                            }
                            .buttonStyle(.plain)
                        }
                        if rating > 0 {
                            Button { rating = 0 } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                                    .font(.callout)
                            }
                            .buttonStyle(.plain)
                            .padding(.leading, 4)
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section("Notes") {
                    TextField("Add notes…", text: $notes, axis: .vertical)
                        .lineLimit(3...8)
                }
                Section {
                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving {
                            HStack { Spacer(); ProgressView(); Spacer() }
                        } else {
                            Text("Save").frame(maxWidth: .infinity).bold()
                        }
                    }
                    .disabled(isSaving)
                }
            }
            .refreshable { await refreshFromNotion() }
            .navigationTitle("Edit Visit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await refreshFromNotion() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isSaving)
                }
            }
            .task { await refreshFromNotion() }
        }
    }

    private func refreshFromNotion() async {
        await notion.fetchVisits()
        if let fresh = notion.visits.first(where: { $0.id == visit.id }) {
            notes = fresh.notes ?? ""
            rating = fresh.rating ?? 0
        }
    }

    private func save() async {
        isSaving = true
        try? await notion.updateVisit(
            visit,
            rating: rating == 0 ? nil : rating,
            notes: notes.isEmpty ? nil : notes
        )
        await notion.fetchVisits()
        dismiss()
    }
}

// MARK: - Place Edit Sheet

private let placeEditCategories = ["Restaurant", "Bar", "Cafe", "Hotel", "Shop",
                                    "Attraction", "Venue", "House", "Fitness",
                                    "Office", "Airport", "Medical", "Park", "Grocery"]

struct PlaceEditSheet: View {
    let place: Place
    @Environment(NotionService.self) private var notion
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var category: String
    @State private var status: String
    @State private var isSaving = false
    @State private var saveError: String?

    init(place: Place) {
        self.place = place
        _name = State(initialValue: place.name)
        _category = State(initialValue: place.category.isEmpty ? "Restaurant" : place.category)
        _status = State(initialValue: place.status.isEmpty ? "Visited" : place.status)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Place name", text: $name)
                }
                Section {
                    HStack {
                        Text("Category")
                        Spacer()
                        Picker("Category", selection: $category) {
                            ForEach(placeEditCategories, id: \.self) { Text($0).tag($0) }
                        }
                        .pickerStyle(.menu)
                    }
                    Picker("Status", selection: $status) {
                        Text("Visited").tag("Visited")
                        Text("Want to Visit").tag("Want to Visit")
                    }
                    .pickerStyle(.segmented)
                }
                if let err = saveError {
                    Section { Text(err).foregroundStyle(.red).font(.caption) }
                }
                Section {
                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving {
                            HStack { Spacer(); ProgressView(); Spacer() }
                        } else {
                            Text("Save").frame(maxWidth: .infinity).bold()
                        }
                    }
                    .disabled(isSaving || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .navigationTitle("Edit Place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func save() async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        isSaving = true
        saveError = nil
        do {
            try await notion.updatePlace(place, name: trimmed, category: category, status: status)
            // updatePlace() already patches the local cache; skip fetchPlaces() here.
            // Calling fetchPlaces() while PlaceDetailView is still on screen causes a brief
            // array replacement that can destabilize the parent view.
            dismiss()
        } catch {
            saveError = error.localizedDescription
            isSaving = false
        }
    }
}

// MARK: - Supporting views

struct DetailRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct StarDisplay: View {
    let rating: Int

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...7, id: \.self) { star in
                Image(systemName: star <= rating ? "star.fill" : "star")
                    .font(.caption)
                    .foregroundStyle(star <= rating ? Color.yellow : Color.secondary)
            }
        }
    }
}
