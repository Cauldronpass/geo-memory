// MacRecordLinkPicker.swift
// "Who or where is this task about?" Mac-only.
//
// Session 82 (2026-08-31), D247. David, looking at a task card: "doesnt seem
// like i can add a person to a task in TraceMac?" He could not. The card has
// DRAWN person and place chips since Session 79 and nothing on the Mac has ever
// written one — the only way to make one was to type `[[Name]]` into the note
// field by hand, and the only reason anybody would know to do that is by having
// read the source.
//
// ── A read-only display of a thing you cannot create ─────────────────────
//
// Worth naming, because it is a shape this project can produce again. The chip
// row was built as part of the CARD, from data that already existed in the
// notes — tasks made on the phone, where D233 gave iOS the picker. Nothing was
// broken; a whole half of the feature was simply never in anyone's field of
// view, because the half that was there looked finished.
//
// It surfaced now for a reason: the AGENDA line (D246) finds a meeting's tasks
// by matching `[[anchor]]` in their notes, so the first thing anybody would
// want to do after seeing an agenda is put a person on a task. The feature that
// consumes the link is what exposed that nothing on this platform produced one.
//
// ── Why this is a picker and not a search ────────────────────────────────
//
// Same argument as `MacTaskDocumentPicker`, which this deliberately mirrors
// down to the chrome: the task exists and the person exists, and the only thing
// missing is the sentence joining them. That is choosing, not finding. One
// list, one field to narrow it, no facets and no modes.
//
// ── Alphabetical, unlike the document picker ─────────────────────────────
//
// The document picker sorts newest-first and says why: the document you want
// was scanned minutes ago. People have no such recency — `Person` carries no
// last-touched date — and more to the point you already know whose name you are
// looking for, so the field is the real path in and the sort is only what you
// see before you type. Alphabetical is the order a name is easiest to find in
// when you are not searching.
//
// ── Which `NotionService`, and the mistake in between ────────────────────
//
// This file first shipped reading `NotionService.shared` with a confident note
// saying that was the safe choice, "because a sheet is exactly where an
// environment value that was never injected turns into an empty list". The
// list came up empty on the first try — 0 people — and the reason was the
// opposite of the one given: `TraceMacApp` built its OWN `NotionService`, so
// `.shared` was a second object that nothing ever fetched into.
//
// `TraceMacDocumentsView` had already recorded that exact bug, with that exact
// justification, and ended its note with "**Check which instance the app
// actually uses.**" I did not.
//
// D248 removed the divergence at the root: the Mac now takes
// `NotionService.shared` like both iOS apps, so there is one instance and this
// read is correct. It stays a `.shared` read rather than becoming an
// environment read for a concrete reason — this sheet opens from a task card,
// task cards appear on the Tasks screen, and that section is built WITHOUT
// `.environment(notionService)`. An `@Environment(NotionService.self)` here
// would trade an empty list for a crash.

import SwiftUI
import AppKit

struct MacRecordLinkPicker: View {

    enum Kind {
        case person, place

        var title: String {
            switch self {
            case .person: "Link a person"
            case .place:  "Link a place"
            }
        }
        var source: String {
            switch self {
            case .person: "People"
            case .place:  "Places"
            }
        }
        var prompt: String {
            switch self {
            case .person: "Search people"
            case .place:  "Search places, cities and categories"
            }
        }
        var noun: (String, String) {
            switch self {
            case .person: ("person", "people")
            case .place:  ("place", "places")
            }
        }
        var nothing: String {
            switch self {
            case .person: "Nobody by that name."
            case .place:  "Nothing matches. Try the city."
            }
        }
    }

    let kind: Kind
    /// Names already in this task's notes when the sheet opened. Seeds `ticked`
    /// and is not read again.
    let linked: [String]
    /// Called with a record NAME to toggle. The caller owns the notes — this
    /// sheet never writes to a task.
    let onToggle: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    /// **The sheet's own view of what is linked**, for the reason
    /// `MacTaskDocumentPicker` states: the write goes to Reminders and the task
    /// only comes back changed after a fetch, so the caller's copy is stale for
    /// a second or more and a tick that lands a beat late reads as a bug.
    @State private var ticked: Set<String> = []
    @State private var seeded = false
    @FocusState private var focused: Bool

    private struct Row: Identifiable {
        let id: String
        let name: String
        let subtitle: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            MacEditorialRule.heavy
            field
            MacEditorialRule.hair
            list
            MacEditorialRule.hair
            footer
        }
        .frame(width: 460, height: 500)
        .background(MacEditorialColor.paper)
        .task {
            if !seeded { ticked = Set(linked); seeded = true }
            // Both link pickers autofocus (Session 78). A sheet whose whole
            // purpose is a name should not need a click before you can type it.
            focused = true
        }
    }

    // MARK: - Chrome

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(kind.title).editorialKicker()
            Text(kind.source)
                .font(MacEditorialType.fieldValue)
                .foregroundStyle(MacEditorialColor.muted)
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
            TextField(kind.prompt, text: $query)
                .textFieldStyle(.plain)
                .font(MacEditorialType.fieldValue)
                .focused($focused)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
    }

    private var footer: some View {
        HStack {
            Text(countLabel)
                .font(MacEditorialType.meta)
                .foregroundStyle(MacEditorialColor.faint)
            Spacer(minLength: 8)
            Button("Done") { dismiss() }
                .buttonStyle(.plain)
                .font(MacEditorialType.meta)
                .foregroundStyle(MacEditorialColor.muted)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
    }

    private var countLabel: String {
        let n = matches.count
        let (one, many) = kind.noun
        return n == 1 ? "1 \(one)" : "\(n) \(many)"
    }

    // MARK: - The list

    /// Alphabetical, and **linked rows are ticked in place rather than floated
    /// to the top** — the same rule the document picker states, because a list
    /// that reorders itself under the cursor the moment you click one is how a
    /// multi-select list starts feeling haunted.
    private var matches: [Row] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let rows: [Row]
        switch kind {
        case .person:
            // Archived people are out: the list is who you would put on a task
            // today, and an archived record is explicitly not that.
            rows = NotionService.shared.people
                .filter { !$0.isArchived }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                .map { Row(id: $0.id, name: $0.name, subtitle: $0.relationship ?? "") }
        case .place:
            rows = NotionService.shared.places
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                .map { place in
                    var parts: [String] = []
                    if !place.city.isEmpty { parts.append(place.city) }
                    if !place.category.isEmpty { parts.append(place.category) }
                    return Row(id: place.id, name: place.name,
                               subtitle: parts.joined(separator: " \u{00B7} "))
                }
        }
        guard !needle.isEmpty else { return rows }
        return rows.filter {
            $0.name.lowercased().contains(needle) || $0.subtitle.lowercased().contains(needle)
        }
    }

    @ViewBuilder
    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if matches.isEmpty {
                    Text(kind.nothing)
                        .font(MacEditorialType.meta)
                        .foregroundStyle(MacEditorialColor.faint)
                        .padding(.horizontal, 18)
                        .padding(.top, 18)
                }
                ForEach(matches) { item in
                    row(item)
                }
                Spacer(minLength: 12)
            }
        }
    }

    private func row(_ item: Row) -> some View {
        let isLinked: Bool = ticked.contains(item.name)
        return Button {
            if isLinked { ticked.remove(item.name) } else { ticked.insert(item.name) }
            onToggle(item.name)
        } label: {
            HStack(spacing: 11) {
                badge(item)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name)
                        .font(MacEditorialType.fieldValue)
                        .foregroundStyle(MacEditorialColor.ink)
                        .lineLimit(1)
                    if !item.subtitle.isEmpty {
                        Text(item.subtitle)
                            .font(MacEditorialType.meta)
                            .foregroundStyle(MacEditorialColor.faint)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                // A tick, not a checkbox. Ninety empty boxes would make a list
                // you are reading look like ninety pending decisions.
                if isLinked {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(MacEditorialColor.accent)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// **Initials for a person, a badge for a place.** `MacAvatar` at `.row` and
    /// `MacIconBadge` at `.compact` are both 28pt, which is not a coincidence to
    /// rely on quietly: it is why the two kinds of list line up, and it is the
    /// number `MacAvatar`'s header exists to have settled once.
    ///
    /// A column of forty identical `person` glyphs is a list of silhouettes.
    /// Initials are a list of people, and they are what a person looks like
    /// everywhere else in this app.
    @ViewBuilder
    private func badge(_ item: Row) -> some View {
        switch kind {
        case .person:
            MacAvatar(name: item.name, size: .row, tint: MacEditorialColor.accent)
        case .place:
            MacIconBadge(icon: "mappin.and.ellipse",
                         tint: MacEditorialColor.accent,
                         size: .compact)
        }
    }
}
