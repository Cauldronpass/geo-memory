// TraceSearchIOS.swift — shared iOS presentation for search and Ask.
//
// Session 71. David: *"I want to have the same ability to search across my apps
// on IOS like i do in Mac and use AI Ask if possible."*
//
// **The engine is not forked and must not be.** `TraceMacSearch.swift` and
// `TraceMacAskService.swift` moved out of `TraceMac/` and into this folder in
// the same session, so one corpus walk, one set of field weights, one ranking
// rule and one prompt assembly serve the Mac and the phone. Two copies of the
// ranking rules is the drift this project has already paid for four times, and
// the files needed no edit at all to cross: both are `import Foundation` and
// nothing else, and their entry points already take plain arrays.
//
// **The filenames stayed `TraceMac*`, deliberately.** The types inside are
// `MacSearch…` / `MacAsk…`, and renaming the files while the types keep the old
// prefix would make the name promise something the contents do not. Renaming the
// types is a large, rippling change across five Mac files for no behavioural
// gain, and this is not the session for it.
//
// **What did not cross:** `TraceMacSearchPanel.swift`. Command-K, arrow-key
// selection and a floating `NSPanel` are Mac facts, and none of them mean
// anything on a phone. This file is the phone's answer to the same question.
//
// **Host-agnostic on purpose.** Routing is a closure. Dayflow owns the
// `dayflow://` scheme and the Trace app does not, so a view that routed for
// itself could only ever live in one of them. Nothing here touches Dayflow's
// skin either, for the same reason: this file compiles into the Trace target as
// well, where `dayflowCard()` does not exist.

import SwiftUI

struct TraceSearchView: View {

    /// What a tapped row does, and **whether the host could do it**.
    ///
    /// Returning `false` is a first-class answer, not an error. `Notes/Horizons`
    /// is a Trace weekly/monthly concept that Dayflow deliberately has no screen
    /// for — `DayflowBacklinksView` and `DayflowWikiSummaryView` both say so in
    /// as many words — and People and Places belong to Trace. Dropping those
    /// notes from the corpus would hide real content David has written; routing
    /// them anyway would be a row that navigates somewhere and does nothing,
    /// which D114 was written about this same week. So a declined destination
    /// expands in place instead, exactly as `.preview` does, and the words are
    /// still readable.
    let onOpen: (MacSearchDestination) -> Bool

    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var corpus = MacSearchCorpus()
    @State private var corpusBuilt = false

    /// Rows expanded in place. Only `.preview` results can be — see
    /// `MacSearchDestination.preview`'s own comment for why that case is honest
    /// rather than a failure.
    @State private var expanded: Set<String> = []
    @State private var previews: [String: String] = [:]

    @State private var asking = false
    @State private var answer: MacAskAnswer?
    @State private var askError: String?

    @State private var notion = NotionService.shared
    @State private var chips  = TraceSatchelChipStore.shared
    @State private var noteStore = NoteStore.shared

    @FocusState private var fieldFocused: Bool

    // MARK: - Derived

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Recomputed per keystroke, and that is fine: the corpus is already in
    /// memory, so this is CPU over a few hundred strings and touches no disk.
    /// The walk that *does* touch disk runs once, in `buildCorpus`.
    private var groups: [MacSearchGroup] {
        guard !trimmedQuery.isEmpty else { return [] }
        return MacSearchEngine.grouped(
            MacSearchEngine.run(query: trimmedQuery,
                                corpus: corpus,
                                documents: chips.all,
                                people: notion.people,
                                places: notion.places))
    }

    /// **D94, on the phone.** People and Places arrive from Notion and the
    /// corpus is a filesystem walk; a search that runs before either lands must
    /// say so. "No matches" during a cold launch is a lie, and it is a lie the
    /// user acts on by concluding the thing is not there.
    private var stillLoading: Bool {
        !corpusBuilt
            || notion.placesLoad == .loading
            || notion.peopleLoad == .loading
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                field
                Divider()
                content
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task(id: noteStore.hasAccess) { await buildCorpus() }
        .onAppear { fieldFocused = true }
    }

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Notes, documents, people, places, endeavors", text: $query)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($fieldFocused)
                .submitLabel(.search)
                // A new question is not an answer to the old one. Clearing here
                // means a stale answer can never sit under a different query,
                // which is the one way a citation list becomes actively wrong.
                .onChange(of: query) { _, _ in
                    answer = nil
                    askError = nil
                }
            if !query.isEmpty {
                Button {
                    query = ""
                    fieldFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if trimmedQuery.isEmpty {
            placeholder
        } else {
            List {
                askSection
                if groups.isEmpty {
                    Section {
                        Text(stillLoading
                             ? "Still loading. Notes are being read and Notion records are on their way."
                             : "Nothing in the container contains those letters.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.items) { row($0) }
                        } header: {
                            Label("\(group.kind.label) (\(group.items.count))",
                                  systemImage: group.kind.icon)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text("Literal, case-insensitive, every word must appear.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if stillLoading {
                Text("Still reading the container…")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(_ result: MacSearchResult) -> some View {
        Button {
            if case .preview = result.destination {
                toggle(result)
            } else if !onOpen(result.destination) {
                toggle(result)
            }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(result.title)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(result.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let snippet = result.snippet {
                    Text(snippet)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
                if expanded.contains(result.id), let text = previews[result.id] {
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggle(_ result: MacSearchResult) {
        if expanded.contains(result.id) {
            expanded.remove(result.id)
            return
        }
        expanded.insert(result.id)
        guard previews[result.id] == nil else { return }
        if let path = result.previewPath {
            previews[result.id] = (try? NoteStore.shared.readFile(path))
                ?? "This note could not be read."
        } else {
            // A record with no note behind it and no screen in this app. Saying
            // so is the point; the alternative is a row that does nothing.
            previews[result.id] = "No screen in this app opens this record."
        }
    }

    // MARK: - Ask

    @ViewBuilder
    private var askSection: some View {
        Section {
            if let answer {
                VStack(alignment: .leading, spacing: 10) {
                    Text(answer.text)
                        .font(.subheadline)
                        .textSelection(.enabled)
                    if !answer.citations.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(answer.citations) { citation in
                                Button {
                                    _ = onOpen(citation.destination)
                                } label: {
                                    Text("[\(citation.number)] \(citation.title)")
                                        .font(.caption)
                                        .foregroundStyle(Color.accentColor)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    // The receipt is not decoration. An answer whose sources you
                    // cannot see is not checkable, and a corpus silently trimmed
                    // by the size cap is not either. Same line the Mac prints.
                    Text(answer.receipt)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 2)
            } else if let askError {
                Text(askError)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                Button {
                    Task { await runAsk() }
                } label: {
                    HStack(spacing: 8) {
                        if asking {
                            ProgressView().scaleEffect(0.8)
                            Text("Reading your notes…")
                        } else {
                            Image(systemName: "sparkles")
                            Text("Ask about \"\(trimmedQuery)\"")
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(asking || stillLoading)
                .foregroundStyle(stillLoading ? Color.secondary : Color.accentColor)
            }
        } header: {
            Text("Ask")
        } footer: {
            if answer == nil && askError == nil {
                Text(stillLoading
                     ? "Available once the container has been read."
                     : "Sends your notes, documents and records to Claude and answers in a sentence, with sources.")
                    .font(.caption2)
            }
        }
    }

    private func runAsk() async {
        asking = true
        askError = nil
        defer { asking = false }
        do {
            answer = try await MacAskService.ask(trimmedQuery,
                                                 corpus: corpus,
                                                 documents: chips.all,
                                                 people: notion.people,
                                                 places: notion.places,
                                                 includeNotionRecords: true)
        } catch let error as MacAskError {
            askError = error.errorDescription ?? "Ask failed."
        } catch {
            askError = error.localizedDescription
        }
    }

    // MARK: - Corpus

    /// Built once per appearance, off the main thread.
    ///
    /// `Task.detached` and not a plain `Task`: the project sets
    /// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` on every target, so a plain
    /// `Task` inherits the main actor and would do a full container read on it
    /// (D106). `MacSearchCorpus.build` is `nonisolated` for exactly this reason.
    ///
    /// Keyed on `hasAccess`, because on a cold launch the iCloud container has
    /// not resolved when this first runs and the walk would find nothing and
    /// cache it — the failure `TraceSatchelChipStore` was bitten by twice.
    private func buildCorpus() async {
        guard let url = NoteStore.shared.containerURL else { return }
        let built = await Task.detached(priority: .userInitiated) {
            MacSearchCorpus.build(containerURL: url)
        }.value
        corpus = built
        corpusBuilt = true
        // Documents come from the shared chip store, which sweeps sidecars.
        await chips.refresh()
    }
}
