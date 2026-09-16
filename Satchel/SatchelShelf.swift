// SatchelShelf.swift
// Satchel only. D407 Build 4 — the reading shelf: Up Next over New, and the
// three rows of Up Next that Home shows.
//
// **Two tiers, no triage duty** (D407). New is where every article lands and
// costs nothing; Up Next is what he pulled forward. An article nobody touches
// sits in New forever, which is the whole design: the required-triage shape is
// what left Reader idle since 2025-12.
//
// Nothing here is a new fact on disk. An article is `article: true`; its place
// in the queue is `read_next:`; whether it is done is `read:`. All three are
// sidecar keys from Build 1, and the reading time is derived at render from the
// word count rather than stored.

import SwiftUI

// MARK: - Membership
//
// `SatchelShelf` — who is on the shelf and in what order — moved to
// `Trace/SatchelArticleText.swift` in D422 so TraceMac's Shelf reads the same
// rule. Nothing about it changed.

// MARK: - Home

/// The first three of Up Next, and a line saying what is waiting behind them.
///
/// **Three, and David chose the number**: *"three is enough yes."*
///
/// Compact rows: number, title, site, minutes, cover. **No recaps here on
/// purpose.** The recap is for CHOOSING, and choosing happens on the Shelf;
/// these three are already chosen.
///
/// ── No door, because the door is the tab bar (D418) ────────────────────────
///
/// The header's "Shelf ›" and the foot's "Open shelf ›" both went. They were
/// written before the Shelf was a tab, and afterwards they were not merely
/// redundant: they pushed a SECOND `SatchelShelfView` onto Home's own
/// navigation stack, so the app could show the shelf in two places, one of
/// them with a back button. One shelf, reached one way.
///
/// ── Folds (D418) ──────────────────────────────────────────────────────────
///
/// David: *"if im on the road and need quick access to a boarding pass then
/// having to contend with the full list of up next items would be in the way."*
/// Right, and the fix is his: fold it. Folded it still says what it is holding
/// — "3 queued · 1 new" — and Kit rises to just under the search field. The
/// state is remembered, like Browse and Kind: a fold you have to redo on every
/// launch is worse than no fold at all.
struct SatchelUpNextSection: View {

    /// **The store, not a snapshot of its documents.** A swipe on the Shelf
    /// rewrites a sidecar and the store updates itself; a view holding an array
    /// passed in at construction is a second copy of that list, and the first
    /// thing it does after a promotion is disagree with the file on disk.
    let store: iOSDocumentStore

    @AppStorage("satchel.upNext.expanded") private var isExpanded = true
    /// Which row is peeled open. One at a time, across the whole section.
    @State private var openSwipe: String?

    private var queue: [TraceMacDocument] { SatchelShelf.upNext(store.documents) }
    private var fresh: [TraceMacDocument] { SatchelShelf.newArrivals(store.documents) }
    private var shown: [TraceMacDocument] { Array(queue.prefix(3)) }

    var body: some View {
        if !queue.isEmpty || !fresh.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                SatchelCollapsibleSectionTitle(title: "Up next",
                                               isExpanded: $isExpanded,
                                               collapsedNote: collapsedNote)
                if isExpanded {
                    VStack(spacing: 0) {
                        ForEach(Array(shown.enumerated()), id: \.element.relativePath) { pair in
                            row(pair.element, index: pair.offset + 1)
                            if pair.offset < shown.count - 1 {
                                Divider().overlay(Color.satchelHairline).padding(.leading, 48)
                            }
                        }
                        foot
                    }
                    .satchelCard()
                }
            }
            .padding(.horizontal, 15)
            .padding(.bottom, 14)
        }
    }

    /// Both numbers, because folded it is the only thing on screen saying the
    /// shelf has anything on it.
    private var collapsedNote: String {
        let q = queue.count
        let n = fresh.count
        if q == 0 { return n == 1 ? "1 new" : "\(n) new" }
        if n == 0 { return "\(q) queued" }
        return "\(q) queued · \(n) new"
    }

    /// One row, wrapped in the same two swipes the Shelf has and meaning the
    /// same thing on both screens (D418). Read on the leading side because it
    /// is the everyday one and the thumb reaches that way first.
    private func row(_ doc: TraceMacDocument, index: Int) -> some View {
        SatchelSwipeRow(
            id: doc.relativePath,
            openID: $openSwipe,
            leading: SatchelSwipeAction(label: "Read", icon: "checkmark", tint: .green) {
                _ = try? store.setRead(Date(), for: doc)
            },
            trailing: SatchelSwipeAction(label: "Off shelf", icon: "arrow.down.to.line", tint: Color.satchelSecondary) {
                _ = try? store.setReadNext(false, for: doc)
            }
        ) {
            NavigationLink {
                SatchelOpenView(document: doc, store: store, siblings: queue)
            } label: {
                SatchelUpNextRow(index: index, document: doc)
            }
            .buttonStyle(.plain)
        }
    }

    /// What is waiting behind the three. **Text, not a link** (D418) — the way
    /// to the shelf is the tab. Still drawn when the queue is empty, reading
    /// "Nothing queued · N new": a shelf with six unread articles on it and no
    /// section on Home is a shelf he will forget he has, and the whole point of
    /// no-triage is that New accumulates quietly rather than invisibly.
    private var foot: some View {
        let count: Int = fresh.count
        let mins: Int = SatchelShelf.totalMinutes(fresh)
        let lead: String = queue.isEmpty ? "Nothing queued" : "\(count) more in New"
        let detail: String = count == 0 ? "" : " · \(mins) min"
        return HStack(spacing: 6) {
            Text(queue.isEmpty ? "\(lead) · \(count) new" : lead + detail)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Color.satchelSecondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .overlay(alignment: .top) {
            Divider().overlay(Color.satchelHairline).padding(.leading, 14)
        }
    }
}

/// One compact Home row: the number he put it in, the title, the site, the
/// minutes, and the cover.
struct SatchelUpNextRow: View {

    let index: Int
    let document: TraceMacDocument

    var body: some View {
        let site: String = SatchelShelf.site(document)
        HStack(alignment: .top, spacing: 11) {
            SatchelQueueNumber(index: index)
            VStack(alignment: .leading, spacing: 3) {
                Text(document.title)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(Color.satchelInk)
                    .lineLimit(2)
                HStack(spacing: 5) {
                    if !site.isEmpty {
                        Text(site)
                        Text("·")
                    }
                    Text("\(SatchelShelf.minutes(document)) min")
                }
                .font(.system(size: 12))
                .foregroundStyle(Color.satchelSecondary)
                .lineLimit(1)
                if let progress = document.readPosition, progress > 0.02, progress < 0.98 {
                    SatchelReadBar(progress: progress)
                }
            }
            Spacer(minLength: 8)
            SatchelCoverThumb(document: document)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// How far in he got, drawn under the kicker. Only for an article he has
/// actually started: a bar sitting at zero on every row is noise, and a bar at
/// 100% belongs to something that has left the shelf.
struct SatchelReadBar: View {

    let progress: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.satchelFill)
                Capsule()
                    .fill(Color.satchelBlue.opacity(0.7))
                    .frame(width: max(3, geo.size.width * min(1, max(0, progress))))
            }
        }
        .frame(height: 3)
        .padding(.top, 3)
    }
}

/// The ordinal, drawn as a small square. It is the ORDER, not a count, which is
/// why it is shown at all: the queue is his and the numbers are how he reads it
/// back.
struct SatchelQueueNumber: View {

    let index: Int

    var body: some View {
        Text("\(index)")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(Color.satchelSecondary)
            .frame(width: 20, height: 20)
            .background(Color.satchelFill, in: RoundedRectangle(cornerRadius: 5))
            .padding(.top, 2)
    }
}
