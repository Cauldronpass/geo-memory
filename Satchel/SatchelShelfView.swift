// SatchelShelfView.swift
// Satchel only. D407 Build 4 — the Shelf: Up Next over New, on one screen.
//
// Its own file, and its own `View` types throughout, per
// `feedback_typecheck_timeout`: `SatchelLibraryView` is already 4,000 lines and
// this session has paid three build cycles for adding to a view file that had
// no room left.

import SwiftUI

struct SatchelShelfView: View {

    /// The store, not a snapshot — see `SatchelUpNextSection`.
    let store: iOSDocumentStore

    @State private var query: String = ""
    @State private var editing: EditMode = .inactive
    /// Finished articles, folded (D418). Folded because it is a record, not a
    /// queue; present because D407 Build 4 shipped a swipe that made an article
    /// vanish from every screen in the app, and David found that out by losing
    /// the Emmys piece: *"it left the shelf and now i dont know where it is."*
    @State private var showRead = false

    // MARK: Lists

    private var queue: [TraceMacDocument] { filtered(SatchelShelf.upNext(store.documents)) }
    private var fresh: [TraceMacDocument] { filtered(SatchelShelf.newArrivals(store.documents)) }
    /// Capped. The shelf is about what is ahead; the tail is a way back to
    /// something recent, not an archive. Everything read is still in All.
    private var done: [TraceMacDocument] { Array(filtered(SatchelShelf.read(store.documents)).prefix(12)) }

    /// **The Shelf's own field, scoped to articles, sharing the library's
    /// matcher.**
    ///
    /// David's question from the mockup was whether this should be the library
    /// search with an Articles filter instead. It should not: he is on this
    /// screen to choose what to read, and sending him to a search that returns
    /// the receipt and the cargo liner and then asking him to narrow by format
    /// is two steps out of the room he is standing in.
    ///
    /// The duplication that would normally argue the other way is avoided by
    /// calling `DocumentSearch` — the same tokens, the same fields, tags and
    /// pulled text included. One matcher, two doors, which is the rule this
    /// project applies to every other "two spellings of one thing".
    private func filtered(_ docs: [TraceMacDocument]) -> [TraceMacDocument] {
        let tokens = DocumentSearch.tokens(from: query)
        guard !tokens.isEmpty else { return docs }
        return docs.filter { DocumentSearch.matches($0, tokens: tokens) }
    }

    // MARK: Body

    var body: some View {
        List {
            if !queue.isEmpty {
                Section {
                    ForEach(Array(queue.enumerated()), id: \.element.relativePath) { pair in
                        row(pair.element, index: pair.offset + 1)
                    }
                    .onMove(perform: move)
                } header: {
                    SatchelShelfHeader(text: "Up next",
                                       trailing: editing == .active ? "drag to reorder" : nil)
                }
            }
            if !fresh.isEmpty {
                Section {
                    ForEach(fresh, id: \.relativePath) { doc in
                        row(doc, index: nil)
                    }
                } header: {
                    SatchelShelfHeader(text: "New", trailing: "newest first")
                }
            }
            if queue.isEmpty && fresh.isEmpty && done.isEmpty {
                SatchelShelfEmpty(searching: !query.isEmpty)
            }
            if !done.isEmpty {
                Section {
                    if showRead {
                        ForEach(done, id: \.relativePath) { doc in
                            readRow(doc)
                        }
                    }
                } header: {
                    Button {
                        withAnimation(.snappy(duration: 0.22)) { showRead.toggle() }
                    } label: {
                        SatchelShelfHeader(text: "Read",
                                           trailing: showRead ? "swipe to put back" : "\(done.count)",
                                           chevronDown: showRead)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.plain)
        .environment(\.editMode, $editing)
        .searchable(text: $query, prompt: "Search articles")
        .navigationTitle("Shelf")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) { standfirst }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // **Reorder behind a button, not always on.** A `List` only
                // offers drag-to-reorder in edit mode, and the alternatives —
                // forcing edit mode permanently, or a custom drag — cost either
                // the row design or a gesture nobody would find. David's "drag
                // to reorder" from the mockup is here; it asks first.
                if !SatchelShelf.upNext(store.documents).isEmpty {
                    Button(editing == .active ? "Done" : "Reorder") {
                        editing = editing == .active ? .inactive : .active
                    }
                    .font(.system(size: 14, weight: .semibold))
                }
            }
        }
    }

    /// "3 up next · 6 new · 77 min in all", the mockup's line.
    private var standfirst: some View {
        let queued: [TraceMacDocument] = SatchelShelf.upNext(store.documents)
        let unread: [TraceMacDocument] = SatchelShelf.newArrivals(store.documents)
        let parts: String = "\(queued.count) up next · \(unread.count) new · \(SatchelShelf.totalMinutes(queued + unread)) min in all"
        return Text(parts)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.satchelSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.bottom, 8)
            .background(Color.satchelCanvas)
    }

    // MARK: Rows

    private func row(_ doc: TraceMacDocument, index: Int?) -> some View {
        let queued: Bool = index != nil
        return NavigationLink {
            SatchelViewerView(document: doc, store: store, siblings: queue + fresh)
        } label: {
            SatchelShelfRow(document: doc, index: index)
        }
        .listRowInsets(EdgeInsets(top: 4, leading: 14, bottom: 4, trailing: 14))
        .listRowSeparatorTint(Color.satchelHairline)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            // Read, without opening it. D407: "a second, gray Read sits behind
            // it and lets an article go without opening it."
            Button {
                _ = try? store.setRead(Date(), for: doc)
            } label: {
                Label("Read", systemImage: "checkmark")
            }
            .tint(Color.satchelSecondary)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                _ = try? store.setReadNext(!queued, for: doc)
            } label: {
                Label(queued ? "Back to New" : "Read next",
                      systemImage: queued ? "arrow.uturn.down" : "arrow.up")
            }
            .tint(Color.satchelBlue)
        }
    }

    /// A finished article, and the way back onto the shelf.
    ///
    /// **`setRead(nil)` returns it to New, not to its old place in Up Next** —
    /// the store's own rule, and the honest one: the position was spent when it
    /// was read. Putting it back where it was would also silently reorder
    /// whatever has been promoted since.
    private func readRow(_ doc: TraceMacDocument) -> some View {
        NavigationLink {
            SatchelViewerView(document: doc, store: store, siblings: done)
        } label: {
            SatchelShelfRow(document: doc, index: nil, read: true)
        }
        .listRowInsets(EdgeInsets(top: 4, leading: 14, bottom: 4, trailing: 14))
        .listRowSeparatorTint(Color.satchelHairline)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button {
                _ = try? store.setRead(nil, for: doc)
            } label: {
                Label("Unread", systemImage: "arrow.uturn.backward")
            }
            .tint(Color.satchelPin)
        }
    }

    /// Reorder, then write every position (see `reorderUpNext`).
    private func move(from source: IndexSet, to destination: Int) {
        var ordered = SatchelShelf.upNext(store.documents)
        ordered.move(fromOffsets: source, toOffset: destination)
        try? store.reorderUpNext(ordered)
    }
}

// MARK: - Row

/// A Shelf row. **New carries its recap, Up Next does not** — the recap is for
/// choosing, and an article in Up Next has already been chosen.
struct SatchelShelfRow: View {

    let document: TraceMacDocument
    let index: Int?
    /// A finished one: the kicker says when rather than how long.
    var read: Bool = false

    var body: some View {
        let site: String = SatchelShelf.site(document)
        let minutes: Int = SatchelShelf.minutes(document)
        let recap: String = document.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let showsRecap: Bool = index == nil && !recap.isEmpty
        // Hoisted: interpolation inside a ternary inside a `Text` is the exact
        // shape that cost this session a build cycle at D418.
        let kicker: String = read ? "· " + (SatchelShelf.readLine(document) ?? "read")
                                  : "· \(minutes) min"
        HStack(alignment: .top, spacing: 12) {
            if let index {
                SatchelQueueNumber(index: index)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(document.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.satchelInk)
                    .lineLimit(2)
                if showsRecap {
                    Text(recap)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.satchelSecondary)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    if !site.isEmpty {
                        Text(site)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.satchelTertiary)
                    }
                    Text(kicker)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.satchelTertiary)
                    if !recap.isEmpty { SatchelAIBadge() }
                }
                if !read, let progress = document.readPosition, progress > 0.02, progress < 0.98 {
                    SatchelReadBar(progress: progress)
                }
            }
            Spacer(minLength: 8)
            // The cover, on the right so every title starts at one edge (D418).
            SatchelCoverThumb(document: document)
                .opacity(read ? 0.55 : 1)
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Header and empty

struct SatchelShelfHeader: View {

    let text: String
    var trailing: String? = nil
    /// Set only by a header that folds; nil leaves the glyph off entirely, so a
    /// header with no fold does not look like one that is stuck shut.
    var chevronDown: Bool? = nil

    var body: some View {
        HStack {
            Text(text.uppercased())
                .font(.system(size: 11, weight: .bold))
                .kerning(0.6)
                .foregroundStyle(Color.satchelSecondary)
            if let chevronDown {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.satchelTertiary)
                    .rotationEffect(.degrees(chevronDown ? 0 : -90))
            }
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.satchelTertiary)
            }
        }
    }
}

/// **Two different nothings, said differently.** An empty search is a failed
/// search; an empty shelf is a finished one, and telling him he has nothing to
/// read when he has read everything is the wrong sentence for a good outcome.
struct SatchelShelfEmpty: View {

    let searching: Bool

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: searching ? "magnifyingglass" : "book")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Color.satchelTertiary)
            Text(searching ? "No articles match" : "Nothing to read")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.satchelInk)
            Text(searching
                 ? "Try fewer words."
                 : "Links that turn out to be articles land here on their own.")
                .font(.system(size: 12.5))
                .foregroundStyle(Color.satchelSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .listRowSeparator(.hidden)
    }
}
