// MacTaskDocumentPicker.swift
// "Which document is this task about?" Mac-only.
//
// Session 80 (2026-08-31), D227. David: "i scanned the document for the tax and
// then i separately created a task and i want to link to that document."
//
// ── Why this is a picker over a search, and not a search over everything ──
//
// The task already exists and so does the document; the only thing missing is
// the sentence joining them. That is a choosing problem, not a finding problem,
// so the whole screen is a list you scroll and a field you narrow it with —
// no modes, no facets, no sections. The Documents screen is where you go
// looking; this is where you point.
//
// ── Its own store, like every other document surface on the Mac ───────────
//
// `TraceMacDocumentStore` is not in the environment: `TraceMacDocumentsView`,
// `TraceMacPlacesView` and `TraceMacSearchPanel` each build one from
// `NoteStore` and reload it. This follows that, rather than introducing a
// shared instance for one sheet — the reload is a folder scan, it happens once
// on appear, and a picker that showed a cached list could offer a document that
// has been deleted or miss one scanned a minute ago.

import SwiftUI
import AppKit

struct MacTaskDocumentPicker: View {

    /// Paths already linked to this task, at the moment the sheet opened.
    /// Seeds `ticked` and is not read again.
    let linked: [String]
    /// Called with a relative path to toggle. The caller owns the notes.
    let onToggle: (String) -> Void

    @Environment(NoteStore.self) private var noteStore
    @Environment(\.dismiss) private var dismiss

    @State private var store: TraceMacDocumentStore? = nil
    @State private var query = ""
    @State private var loading = true
    /// **The sheet's own view of what is linked**, because the caller's copy
    /// cannot keep up. `onToggle` writes to Reminders and the task only comes
    /// back changed after a fetch, by which point this sheet has already been
    /// looking at a stale `linked` for a second or more. Ticking optimistically
    /// is right here: the write is local, it effectively cannot fail, and a
    /// tick that appears a beat after the click reads as a bug.
    @State private var ticked: Set<String> = []
    @State private var seeded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            MacEditorialRule.heavy
            field
            MacEditorialRule.hair
            body_
            MacEditorialRule.hair
            footer
        }
        .frame(width: 460, height: 500)
        .background(MacEditorialColor.paper)
        .task {
            // `seeded` rather than `onAppear`: this runs again if the view is
            // rebuilt, and re-seeding would throw away ticks made since.
            if !seeded { ticked = Set(linked); seeded = true }
            if store == nil { store = TraceMacDocumentStore(noteStore: noteStore) }
            await store?.reload()
            loading = false
        }
    }

    // MARK: - Chrome

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Link a document").editorialKicker()
            Text("Satchel")
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
            TextField("Search titles, tags and descriptions", text: $query)
                .textFieldStyle(.plain)
                .font(MacEditorialType.fieldValue)
            if loading { ProgressView().controlSize(.small) }
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
        if loading { return "Reading Satchel\u{2026}" }
        let n = matches.count
        return n == 1 ? "1 document" : "\(n) documents"
    }

    // MARK: - The list

    /// Newest first, and that is the whole sort.
    ///
    /// The linking case is nearly always a document scanned minutes ago — the
    /// tax bill he had just captured. Alphabetical would bury it under years of
    /// receipts; relevance ranking would need a query, and the common path has
    /// no query at all because the thing he wants is already on top.
    ///
    /// **Linked documents are NOT floated to the top.** They are ticked in
    /// place, so the list does not reorder itself under his cursor the moment
    /// he taps one — the reordering-on-select bug that makes a multi-select
    /// list feel haunted.
    private var matches: [TraceMacDocument] {
        let all = (store?.documents ?? []).sorted {
            ($0.created ?? .distantPast) > ($1.created ?? .distantPast)
        }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return all }
        return all.filter { doc in
            doc.title.lowercased().contains(needle)
                || doc.filename.lowercased().contains(needle)
                || doc.description.lowercased().contains(needle)
                || doc.tags.contains { $0.lowercased().contains(needle) }
        }
    }

    @ViewBuilder
    private var body_: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !loading && matches.isEmpty {
                    Text(query.isEmpty
                         ? "Nothing in Satchel yet."
                         : "Nothing matches. Try the year, or a word from the file name.")
                        .font(MacEditorialType.meta)
                        .foregroundStyle(MacEditorialColor.faint)
                        .padding(.horizontal, 18)
                        .padding(.top, 18)
                }
                ForEach(matches) { doc in
                    row(doc)
                }
                Spacer(minLength: 12)
            }
        }
    }

    private func row(_ doc: TraceMacDocument) -> some View {
        let isLinked: Bool = ticked.contains(doc.relativePath)
        return Button {
            if isLinked { ticked.remove(doc.relativePath) }
            else { ticked.insert(doc.relativePath) }
            onToggle(doc.relativePath)
        } label: {
            HStack(spacing: 11) {
                MacIconBadge(icon: doc.resolvedIcon.sfSymbol,
                             tint: MacPalette.documentTint(doc.resolvedTint),
                             size: .compact)
                VStack(alignment: .leading, spacing: 1) {
                    Text(doc.title)
                        .font(MacEditorialType.fieldValue)
                        .foregroundStyle(MacEditorialColor.ink)
                        .lineLimit(1)
                    Text(subtitle(doc))
                        .font(MacEditorialType.meta)
                        .foregroundStyle(MacEditorialColor.faint)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                // A tick, not a checkbox: this list is mostly read, and an
                // empty box on every row would make forty documents look like
                // forty pending decisions.
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

    private func subtitle(_ doc: TraceMacDocument) -> String {
        var parts: [String] = []
        if let created = doc.created {
            let f = DateFormatter()
            f.dateFormat = "d MMM yyyy"
            parts.append(f.string(from: created))
        }
        if !doc.category.isEmpty { parts.append(doc.category) }
        if !doc.fileExtension.isEmpty { parts.append(doc.fileExtension.uppercased()) }
        return parts.joined(separator: " \u{00B7} ")
    }
}
