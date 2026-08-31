// MacPlacePicker.swift
// "Where is this meeting, really?" — asked once per location, answered by hand.
// Mac-only.
//
// Session 80 (2026-08-31), David's design: "it could have a button that i would
// press whenever a Where is filled in. when we press it it would look up the
// places in the database and google places just like discover does and then i
// can choose. once chosen, it would add the place to my list of places if it
// was not already there and then make the address clickable as well as the
// place itself."
//
// ── Two sources, one list, and the order is the argument ────────────────
//
// YOUR PLACES first, then FROM GOOGLE. Not alphabetical, not interleaved by
// score: a place already in the database is a place he has already decided
// about — named it, categorised it, maybe written a note on it. Offering a
// fresh Google result above it would invite him to create a second record for
// something he already has, which is the one outcome this screen must not
// produce.
//
// Google is searched only when there is a query, and its results are labelled,
// so "this one will be added" is never a surprise.
//
// ── Why the save reuses Discover's sheet ────────────────────────────────
//
// `AddDiscoveredPlaceSheet` already turns a `GooglePlace` into a Notion record:
// category picker, status, the address-with-region choice, and the guard that
// refuses to store an Apple result's id in the Google Place ID field (D138).
// Writing a second saver here would mean two paths into the Places database
// disagreeing about any of those — the drift this project has paid for twice.
//
// So this screen finds and chooses; that sheet creates. Neither does the
// other's job.

import SwiftUI
import AppKit

struct MacPlacePicker: View {

    /// The meeting's raw WHERE text. Seeds the search and becomes the link key.
    let location: String
    /// Handed the chosen place's Notion id once it exists.
    let onPicked: (String) -> Void

    @Environment(NotionService.self) private var notion
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var googleResults: [GooglePlace] = []
    @State private var searching = false
    @State private var searchError: String? = nil
    @State private var adding: GooglePlace? = nil
    @State private var searchToken = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            MacEditorialRule.heavy
            field
            MacEditorialRule.hair
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    mine
                    fromGoogle
                    Spacer(minLength: 12)
                }
            }
            MacEditorialRule.hair
            footer
        }
        .frame(width: 460, height: 480)
        .background(MacEditorialColor.paper)
        .onAppear {
            // Seeded with the invitation's own words, because nine times in ten
            // they are the search. The field stays editable for the tenth,
            // where the location is a room number and the building is implied.
            if query.isEmpty { query = location }
        }
        .sheet(item: $adding) { result in
            AddDiscoveredPlaceSheet(result: result) {
                // Notion has the record now, but this app's copy does not until
                // it refetches — and the caller needs an id that resolves, not
                // one that will in a moment.
                let before = Set(notion.places.map(\.id))
                await notion.fetchPlaces()
                // **Newest id first, name second.** Matching on name alone
                // would hand back an existing record whenever he saves a second
                // "Starbucks" — and the whole point of this screen is that the
                // link goes to the place he just chose. The id set is taken
                // before the refetch, so "new" means new to this app since he
                // pressed save.
                let made = notion.places.first { !before.contains($0.id) && $0.name == result.name }
                    ?? notion.places.first { !before.contains($0.id) }
                if let made {
                    onPicked(made.id)
                    dismiss()
                }
            }
            .environment(notion)
        }
    }

    // MARK: - Chrome

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Match a place").editorialKicker()
            Text(location)
                .font(MacEditorialType.fieldValue)
                .foregroundStyle(MacEditorialColor.muted)
                .lineLimit(2)
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    private var field: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(MacEditorialColor.faint)
            TextField("Search your places and Google", text: $query)
                .textFieldStyle(.plain)
                .font(MacEditorialType.fieldValue)
                .onSubmit { searchToken += 1 }
            if searching { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .task(id: searchToken) { await runGoogle() }
    }

    private var footer: some View {
        HStack {
            if let searchError {
                Text(searchError)
                    .font(MacEditorialType.meta)
                    .foregroundStyle(MacEditorialColor.accent)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Button("Cancel") { dismiss() }
                .buttonStyle(.plain)
                .font(MacEditorialType.meta)
                .foregroundStyle(MacEditorialColor.muted)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
    }

    // MARK: - Your places

    private var matches: [Place] {
        let base = MacPlaceLink.suggestions(for: query, in: notion.places)
        // A typed query that matches nothing structurally still deserves the
        // plain substring answer — he is searching now, not being suggested to.
        guard base.isEmpty else { return base }
        let needle = MacPlaceLink.normalise(query)
        guard needle.count >= 2 else { return [] }
        return notion.places
            .filter { MacPlaceLink.normalise($0.name).contains(needle) }
            .prefix(6)
            .map { $0 }
    }

    @ViewBuilder
    private var mine: some View {
        if !matches.isEmpty {
            Text("Your places").editorialFieldLabel()
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 4)
            ForEach(matches) { place in
                row(title: place.name,
                    subtitle: [place.address, place.city]
                        .filter { !$0.isEmpty }.joined(separator: " · "),
                    icon: placeIcon(for: place.category),
                    tint: placeColor(for: place.category)) {
                    // Already a record — nothing to create, just remember it.
                    onPicked(place.id)
                    dismiss()
                }
            }
        }
    }

    // MARK: - Google

    @ViewBuilder
    private var fromGoogle: some View {
        if !googleResults.isEmpty {
            Text("From Google").editorialFieldLabel()
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 4)
            ForEach(googleResults) { result in
                row(title: result.name,
                    subtitle: result.addressWithRegion,
                    icon: "mappin.and.ellipse",
                    tint: MacEditorialColor.faint) {
                    // Not saved yet. `AddDiscoveredPlaceSheet` asks for the
                    // category, which is the one field no geocoder can answer.
                    adding = result
                }
            }
        } else if !searching && searchError == nil && !query.isEmpty && matches.isEmpty {
            Text("Nothing found. Try fewer words — an invitation often carries a room name the map has never heard of.")
                .font(MacEditorialType.meta)
                .foregroundStyle(MacEditorialColor.faint)
                .padding(.horizontal, 18)
                .padding(.top, 16)
        }
    }

    private func runGoogle() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 3 else { googleResults = []; return }
        searching = true
        searchError = nil
        do {
            // No coordinate: a meeting's location is an address or a venue
            // name, not a "near me" search, and biasing toward the current
            // map centre would rank a same-named place across town above the
            // right one.
            googleResults = try await GooglePlacesService.shared.textSearch(query: text,
                                                                           coordinate: nil)
        } catch {
            googleResults = []
            searchError = error.localizedDescription
        }
        searching = false
    }

    // MARK: - A row

    private func row(title: String, subtitle: String, icon: String,
                     tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(tint)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(MacEditorialType.fieldValue)
                        .foregroundStyle(MacEditorialColor.ink)
                        .lineLimit(1)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(MacEditorialType.meta)
                            .foregroundStyle(MacEditorialColor.faint)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
