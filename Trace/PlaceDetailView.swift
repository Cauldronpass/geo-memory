import SwiftUI

struct PlaceDetailView: View {
    let place: Place
    @Environment(NotionService.self) private var notionService
    @Environment(LocationManager.self) private var locationManager
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTab = 0
    @State private var showingCheckIn = false

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
            }
        }
        .sheet(isPresented: $showingCheckIn) {
            CheckInView()
                .environment(NotionService.shared)
                .environment(LocationManager.shared)
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
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(visit.date, style: .date)
                                    .font(.subheadline.bold())
                                Spacer()
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
                        .padding(.vertical, 8)
                        Divider()
                    }
                }
                .padding()
            }
        }
    }

    // MARK: - Action bar

    private var actionBar: some View {
        HStack(spacing: 12) {
            Button {
                let url = URL(string: "maps://?daddr=\(place.latitude),\(place.longitude)")!
                UIApplication.shared.open(url)
            } label: {
                Label("Directions", systemImage: "arrow.triangle.turn.up.right.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button {
                showingCheckIn = true
            } label: {
                Label("Check In", systemImage: "checkmark.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            Button {
                Task { try? await notionService.toggleFlagged(place) }
            } label: {
                Image(systemName: livePlace.flagged ? "star.fill" : "star")
                    .font(.title3)
            }
            .buttonStyle(.bordered)
            .tint(livePlace.flagged ? .yellow : .secondary)
        }
        .padding()
        .background(.bar)
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
