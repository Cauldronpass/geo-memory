import SwiftUI

// MARK: - DayflowVisitDetailView / DayflowInteractionDetailView
//
// Read-only drill-in for the Visit/Interaction rows in DayflowWikiSummaryView.swift's
// Activity/Log/Visits tabs (Session 20, 2026-07-20). Deliberately NOT Trace's real
// VisitDetailView.swift — same CRM-light boundary as DayflowWikiSummaryView itself
// (Session 17): no rating edit, no notes edit, no photo add/remove, no billiards/
// workout/skip-enrichment cascade. Presentation only, against data already sitting in
// memory by the time these rows render — NotionService.shared.visits/.people/.places
// are all fetched once at launch (DayflowApp.swift), same freshness characteristics
// as everywhere else in this file.
//
// Given a Person's Activity-tab Visit row and a Place's Visits-tab History row are the
// exact same `Visit` struct rendered two different ways, one shared
// DayflowVisitDetailView covers both entry points rather than building two.
//
// Chaining (David, 2026-07-20): tapping an attendee name (either card), a Visit's
// place, or an Interaction's linked Visit opens the next card one hop further — same
// nested .sheet(item:) pattern DayflowWikiSummaryView already uses on itself for
// wikilink taps, just extended one hop past Person/Place. No new plumbing: the
// person/place lookups here are the same inline scans placeVisitsTab/personActivityTab
// already do; the "next" sheet is a struct these views already know how to present.

struct DayflowVisitDetailView: View {
    let visit: Visit

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var wikiLinkTarget: WikiLinkTarget? = nil

    private var place: Place? {
        NotionService.shared.places.first(where: { $0.id == visit.placeID })
    }

    private var attendees: [Person] {
        visit.peopleIDs.compactMap { id in
            NotionService.shared.people.first(where: { $0.id == id })
        }
    }

    var body: some View {
        List {
            Section {
                Button {
                    if let place { wikiLinkTarget = .place(place) }
                } label: {
                    HStack {
                        Text(visit.placeName).font(.headline)
                        Spacer()
                        if place != nil {
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(place != nil ? .primary : .secondary)
                .disabled(place == nil)

                LabeledContent("Date", value: visit.date.formatted(.dateTime.month(.wide).day().year()))
                if let rating = visit.rating, rating > 0 {
                    LabeledContent("Rating") {
                        Text(String(repeating: "★", count: min(rating, 7)))
                            .foregroundStyle(.orange)
                    }
                }
            }

            if let notes = visit.notes, !notes.isEmpty {
                Section("Notes") { Text(notes) }
            }

            if !attendees.isEmpty {
                Section("With") {
                    ForEach(attendees) { person in
                        Button {
                            wikiLinkTarget = .person(person)
                        } label: {
                            HStack {
                                Text(person.name)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.primary)
                    }
                }
            }

            Section("Photos") {
                if !visit.photoURLs.isEmpty {
                    photoStrip(visit.photoURLs)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                } else {
                    Text("No photos logged yet").foregroundStyle(.secondary).font(.subheadline)
                }
                // Trace hand-off, 2026-07-21 (Session 25): trace://addphoto has no
                // visit/place param support on Trace's side (unlike checkin — see
                // DayflowWikiSummaryView.swift's "Log a Visit in Trace" button), so
                // this opens Trace's general Add Photo capture, not scoped to this
                // visit specifically. Still the fastest path to the read-only gap
                // this section otherwise has no fix for.
                Button {
                    if let url = URL(string: "trace://addphoto") { openURL(url) }
                } label: {
                    Label("Add a Photo in Trace", systemImage: "arrow.up.forward.app")
                }
            }
        }
        .navigationTitle("Visit")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
        .sheet(item: $wikiLinkTarget) { target in
            NavigationStack {
                DayflowWikiSummaryView(target: target)
            }
        }
    }
}

struct DayflowInteractionDetailView: View {
    let interaction: Interaction

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var wikiLinkTarget: WikiLinkTarget? = nil
    @State private var linkedVisit: Visit? = nil

    private var attendees: [Person] {
        interaction.personIDs.compactMap { id in
            NotionService.shared.people.first(where: { $0.id == id })
        }
    }

    private var visit: Visit? {
        guard let visitID = interaction.visitID else { return nil }
        return NotionService.shared.visits.first(where: { $0.id == visitID })
    }

    // Independent copy of DayflowWikiSummaryView's interactionIcon(_:) — same
    // convention this codebase already uses for small helpers needed in more than
    // one file (e.g. DayflowQuickAddSheet's stripListToken vs. applyHighlight's
    // identical scan), rather than threading a shared method across files for one line.
    private func icon(for type: String) -> String {
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
        List {
            Section {
                Label(interaction.type.capitalized, systemImage: icon(for: interaction.type))
                    .font(.headline)
                LabeledContent("Date", value: interaction.date.formatted(.dateTime.month(.wide).day().year()))
            }

            if !interaction.summary.isEmpty {
                Section("Summary") { Text(interaction.summary) }
            }
            if let notes = interaction.notes, !notes.isEmpty {
                Section("Notes") { Text(notes) }
            }

            if !attendees.isEmpty {
                Section("With") {
                    ForEach(attendees) { person in
                        Button {
                            wikiLinkTarget = .person(person)
                        } label: {
                            HStack {
                                Text(person.name)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.primary)
                    }
                }
            }

            if let visit {
                Section {
                    Button {
                        linkedVisit = visit
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Part of a visit to \(visit.placeName)")
                                Text(visit.date.formatted(.dateTime.month(.abbreviated).day().year()))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                }
            }

            Section("Photos") {
                if !interaction.photoURLs.isEmpty {
                    photoStrip(interaction.photoURLs)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                } else {
                    Text("No photos logged yet").foregroundStyle(.secondary).font(.subheadline)
                }
                // Same generic (not interaction-scoped) hand-off as
                // DayflowVisitDetailView's Photos section above — see that
                // view's comment for why it can't be scoped further.
                Button {
                    if let url = URL(string: "trace://addphoto") { openURL(url) }
                } label: {
                    Label("Add a Photo in Trace", systemImage: "arrow.up.forward.app")
                }
            }
        }
        .navigationTitle("Interaction")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
        .sheet(item: $wikiLinkTarget) { target in
            NavigationStack {
                DayflowWikiSummaryView(target: target)
            }
        }
        .sheet(item: $linkedVisit) { v in
            NavigationStack {
                DayflowVisitDetailView(visit: v)
            }
        }
    }
}

// MARK: - Shared read-only photo strip (no add/remove — Visit/Interaction photos are
// display-only here, same CRM-light boundary as everything else in this file)

@ViewBuilder
private func photoStrip(_ urls: [String]) -> some View {
    ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
            ForEach(urls, id: \.self) { urlString in
                if let url = URL(string: urlString) {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        ProgressView()
                    }
                    .frame(width: 100, height: 100)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }
}
