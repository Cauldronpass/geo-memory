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

/// One field, so `.sheet(item:)` has something Identifiable to hold. The third
/// of these in the app; each file keeps its own rather than sharing one, which
/// is what `DayflowAgendaSection` and `DayflowWikiSummaryView` already do.
private struct VisitEndeavorRef: Identifiable {
    let id: String
}

struct DayflowVisitDetailView: View {
    let visit: Visit

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var wikiLinkTarget: WikiLinkTarget? = nil
    /// Pushed when the Endeavor row is tapped. Session 72.
    @State private var openEndeavorID: String? = nil

    private var place: Place? {
        NotionService.shared.places.first(where: { $0.id == visit.placeID })
    }

    /// The endeavor this visit was part of, if any.
    ///
    /// Session 72. David: *"if i click the visit it would be helpful to see on
    /// the visit screen what endeavor that was part of."*
    ///
    /// `claimsVisit` is the shared rule on the model — inside the dates AND
    /// named in the endeavor's trip log — the same one the endeavor screen's own
    /// Visits list reads. A visit sitting under "Also that day" over there gets
    /// nothing here, which is the answer David curates by hand.
    ///
    /// Off `EndeavorStore.shared`, which this app already keeps loaded, rather
    /// than a walk of its own.
    private var matchedEndeavor: Endeavor? {
        EndeavorStore.shared.endeavors.first {
            $0.claimsVisit(placeName: visit.placeName, on: visit.date)
        }
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

                if let endeavor = matchedEndeavor {
                    Button {
                        openEndeavorID = endeavor.id
                    } label: {
                        HStack {
                            Text("Endeavor")
                            Spacer()
                            Text(endeavor.name)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    // Hosted on the Button, not on the List.
                    //
                    // **D36.** The List already carries `.sheet(item:
                    // $wikiLinkTarget)`, and two `.sheet` modifiers on one view
                    // is a coin flip that the later one wins in silence. A
                    // distinct host view is the pattern this app already uses
                    // for exactly this — `DayflowAgendaSection` and
                    // `DayflowWikiSummaryView` both open an endeavor this way,
                    // each with its own one-field Identifiable wrapper.
                    .sheet(item: Binding(
                        get: { openEndeavorID.map(VisitEndeavorRef.init) },
                        set: { openEndeavorID = $0?.id }
                    )) { ref in
                        NavigationStack {
                            DayflowEndeavorView(endeavorID: ref.id)
                        }
                    }
                }

                if let rating = visit.rating, rating > 0 {
                    LabeledContent("Rating") {
                        Text(String(repeating: "★", count: min(rating, 7)))
                            .foregroundStyle(.orange)
                    }
                }
            }

            // ALWAYS DRAWN, EVEN WHEN EMPTY — 2026-08-01. David tapped through
            // from an Endeavor note to this card and found nothing where notes
            // should be. The visit genuinely has none (he rated Nick's on the
            // Lake and left the field blank), but the section was omitted
            // entirely when empty, so "you wrote nothing here" and "this screen
            // failed to load" looked identical.
            //
            // The Photos section three rows below has always handled its own
            // empty case — "No photos logged yet" plus a hand-off. Notes was the
            // odd one out. Same shape now.
            Section("Notes") {
                if let notes = visit.notes, !notes.isEmpty {
                    Text(notes)
                } else {
                    Text("No notes on this visit")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
                // The way OUT of the read-only boundary, 2026-08-01. Trace's
                // VisitDetailView has had a notes editor all along; there was
                // simply no route to it, so the only way to write a note on a
                // visit you were already looking at was to open Trace and find
                // it again by hand.
                //
                // Unlike the photo hand-off below, this one IS scoped to this
                // visit — `trace://visit?id=` resolves the exact record. Shown
                // whether or not there are notes already, because the second
                // reason to come here is to add to what you wrote.
                Button {
                    if let url = URL(string: "trace://visit?id=\(visit.id)") { openURL(url) }
                } label: {
                    Label(visit.notes?.isEmpty == false ? "Edit in Trace" : "Add Notes in Trace",
                          systemImage: "arrow.up.forward.app")
                }
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
        // The Endeavor row reads `EndeavorStore.shared`, and this sheet can be
        // reached on a launch where nothing has loaded it yet — from a Place
        // card, from Search. An unloaded store and a visit that belongs to no
        // endeavor look identical from here, so load rather than assume.
        .task {
            if EndeavorStore.shared.endeavors.isEmpty { EndeavorStore.shared.reload() }
        }
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
        InteractionStyle.icon(for: type)
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
