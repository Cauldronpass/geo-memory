// TraceMacDocumentFacets.swift
// The Satchel filter pane — a weighted, faceted cloud over subject, type and tags.
// Mac-only — do not add to iOS, Widget, or Share Extension targets.
//
// Session 73. David, on Yep by Ironic Software: *"The tags had a unique way of
// presenting and I am including a description of that panel. Can we do the
// same? … This is more of a nostalgia thing for me."*
//
// ── Why it is not only a tag cloud ────────────────────────────────────────
//
// Yep's cloud worked on a library of a few thousand documents, where tag
// frequency has a distribution to draw from. Satchel has 24 documents and 65
// distinct tags, and 55 of those appear exactly once. Weighted on tags alone
// this pane is three legible words — receipt 11, august 2026 8, wedding 6 —
// and a wall of identical small ones.
//
// What does have a distribution is the pair of axes Session 72 built: ten icons
// and six tints in use, every document carrying one of each, and nothing in the
// app navigating by either. So the pane has three sections and the cloud is the
// third of them. This is the first surface where colour-as-type (D123) is
// something you can steer by rather than only read.
//
// ── Three rules, each one a decision ──────────────────────────────────────
//
// **Font size is weighted by the LIBRARY total, never by the live count.** Yep
// resized as you narrowed. Copying that means every word in the pane changes
// size on every click, and a cloud whose shape moves cannot be learned. Size is
// the stable fact — how much of this library is receipts. The number beside the
// chip is the live one — how many are reachable from where you are standing.
//
// **Order is alphabetical and fixed, for the same reason.** Sorting by live
// count would reshuffle the pane under the pointer between clicks.
//
// **A facet that falls to zero is DIMMED, never removed.** Yep's sidebar
// removed them. Session 72 charged for exactly this shape twice in one day: a
// bucket header suppressed for tidiness hid the one misfiled document, and a
// `skipped:` key rendered nowhere could not be seen or taken back. A facet that
// vanishes when you narrow hides precisely the document filed against the
// grain, which is the document you are hunting. Dimmed facets stay clickable —
// clicking one lands on "No matches", which is an answer rather than a wall.
//
// ── Semantics, which differ per axis and had to ───────────────────────────
//
// A document has ONE icon and ONE tint, so selecting two icons must mean OR.
// AND would return the empty set every time and read as a broken control.
// A document has MANY tags, so selecting two tags means AND — that is the
// progressive narrowing Yep is actually remembered for. Across axes it is AND.
//
// Counts follow the same split. An icon's count is computed with the icon axis
// itself excluded, or every unselected icon would read zero the moment one was
// picked. A tag's count is computed with the tag axis included, because adding
// a second tag genuinely narrows.
//
// ── Layout ────────────────────────────────────────────────────────────────
//
// Rows are packed by measuring each chip with `NSAttributedString` against the
// pane's known width, rather than through SwiftUI's `Layout` protocol or the
// `alignmentGuide` flow trick. The pane's width is a stored number this view is
// handed, so there is nothing to discover at render time and no state write in
// a layout pass. Measurement carries a couple of points of slack per chip; the
// cost of being wrong is a row that wraps one chip early, which is invisible.

import SwiftUI
import AppKit

// MARK: - Facet model

/// Everything the pane draws, computed once per change by the parent.
///
/// A value type rather than eleven parameters: the three axes need the same
/// four things each (order, library total, live count, and the selection),
/// and passing them loose is how one of them ends up computed differently.
struct DocFacetModel {

    var iconOrder: [DocumentIcon] = []
    var tintOrder: [DocumentTint] = []
    var tagOrder:  [String] = []

    /// Counts across the WHOLE library. Drives font size, which must not move.
    var iconTotal: [DocumentIcon: Int] = [:]
    var tintTotal: [DocumentTint: Int] = [:]
    var tagTotal:  [String: Int] = [:]

    /// Counts under the current filter. Drives the number and the dimming.
    var iconLive: [DocumentIcon: Int] = [:]
    var tintLive: [DocumentTint: Int] = [:]
    var tagLive:  [String: Int] = [:]

    var iconMax: Int { iconTotal.values.max() ?? 1 }
    var tintMax: Int { tintTotal.values.max() ?? 1 }
    var tagMax:  Int { tagTotal.values.max()  ?? 1 }

    /// Build from the library plus three predicates, each of which applies every
    /// active filter EXCEPT the one named. The parent owns the predicates
    /// because it owns the search text, the project pill and the date pill;
    /// duplicating them here is the drift this app has paid for repeatedly.
    ///
    /// - Parameters:
    ///   - all: every document in the library, unfiltered.
    ///   - matchingWithoutIcons: passes when everything but the icon axis matches.
    ///   - matchingWithoutTints: passes when everything but the tint axis matches.
    ///   - matchingAll: passes when the full current filter matches.
    static func build(all: [TraceMacDocument],
                      matchingWithoutIcons: (TraceMacDocument) -> Bool,
                      matchingWithoutTints: (TraceMacDocument) -> Bool,
                      matchingAll: (TraceMacDocument) -> Bool) -> DocFacetModel {
        var m = DocFacetModel()

        for doc in all {
            m.iconTotal[doc.resolvedIcon, default: 0] += 1
            m.tintTotal[doc.resolvedTint, default: 0] += 1
            // `Set` first: a sidecar with the same tag written twice would
            // otherwise weight that tag double for one document.
            for tag in Set(doc.tags) { m.tagTotal[tag, default: 0] += 1 }
        }

        for doc in all where matchingWithoutIcons(doc) {
            m.iconLive[doc.resolvedIcon, default: 0] += 1
        }
        for doc in all where matchingWithoutTints(doc) {
            m.tintLive[doc.resolvedTint, default: 0] += 1
        }
        for doc in all where matchingAll(doc) {
            for tag in Set(doc.tags) { m.tagLive[tag, default: 0] += 1 }
        }

        // Stable orders. Icons and tags alphabetically by what is drawn; tints
        // in the fixed order the type palette is documented in, so the section
        // reads down the same way as `DocumentTint.promptGuide` and the picker.
        m.iconOrder = m.iconTotal.keys.sorted { $0.label < $1.label }
        m.tagOrder  = m.tagTotal.keys.sorted  { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        let present = Set(m.tintTotal.keys)
        m.tintOrder = (DocumentTint.typeCases + [.amber, .red]).filter { present.contains($0) }
        return m
    }
}

// MARK: - Labels

extension DocumentTint {
    /// What this colour is called in the filter pane.
    ///
    /// Mac-only and deliberately not on the shared enum. `typeMeaning` returns
    /// nil for `amber` and `red` because neither is a type a document may be
    /// scanned as, which is the right answer for the scan prompt and the wrong
    /// one for a pane that has to draw a swatch somebody's document is already
    /// wearing. See the note on `typeMeaning` for why those two are reserved.
    var facetLabel: String {
        typeMeaning ?? (self == .amber ? "Private" : "Needs action")
    }
}

// MARK: - The pane

struct DocFacetPanel: View {

    let model: DocFacetModel
    @Binding var selectedIcons: Set<DocumentIcon>
    @Binding var selectedTints: Set<DocumentTint>
    @Binding var selectedTags:  Set<String>

    /// The pane's own width, so chips can be packed without a `GeometryReader`.
    let width: CGFloat
    /// How many documents the current filter leaves. Drawn in the header so the
    /// pane answers its own question without you looking away from it.
    let resultCount: Int

    private var activeCount: Int {
        selectedIcons.count + selectedTints.count + selectedTags.count
    }

    /// Usable width inside the pane's horizontal padding.
    private var contentWidth: CGFloat { max(width - 24, 80) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !model.iconOrder.isEmpty { subjectSection }
                    if !model.tintOrder.isEmpty { typeSection }
                    if !model.tagOrder.isEmpty  { tagSection }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 14)
                .frame(width: width, alignment: .leading)
            }
        }
        .frame(width: width)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            Text("FILTER")
                .font(MacType.label)
                .tracking(MacType.labelTracking)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            // The result count belongs here rather than only under the list.
            // The whole point of the pane is that you narrow while looking at
            // it, and a number you have to glance away to read is a number you
            // stop reading.
            Text("\(resultCount)")
                .font(MacType.meta)
                .foregroundStyle(.secondary)
                .help("\(resultCount) document\(resultCount == 1 ? "" : "s") match")
            if activeCount > 0 {
                Button {
                    selectedIcons.removeAll()
                    selectedTints.removeAll()
                    selectedTags.removeAll()
                } label: {
                    Image(systemName: "xmark.circle.fill").font(MacGlyph.control)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor.opacity(0.7))
                .help("Clear \(activeCount) filter\(activeCount == 1 ? "" : "s")")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: MacChrome.headerHeight)
    }

    // MARK: Subject — the icon axis

    private var subjectSection: some View {
        section("SUBJECT") {
            cloud(items: model.iconOrder.map { icon in
                CloudItem(key: icon.rawValue,
                          text: icon.label,
                          symbol: icon.sfSymbol,
                          size: Self.weight(model.iconTotal[icon] ?? 0, max: model.iconMax),
                          live: model.iconLive[icon] ?? 0,
                          selected: selectedIcons.contains(icon),
                          colour: MacPalette.documentTint(icon.defaultTint),
                          help: "\(icon.promptHint)")
            }) { key in
                guard let icon = DocumentIcon(rawValue: key) else { return }
                if selectedIcons.contains(icon) { selectedIcons.remove(icon) }
                else { selectedIcons.insert(icon) }
            }
        }
    }

    // MARK: Type — the colour axis

    /// Not a cloud. Six entries with sentence-length labels ("Receipt, bill,
    /// proof of payment") do not pack, and the thing being scanned here is the
    /// swatch rather than the word — so this is a list with the colour first,
    /// which is how you actually use it.
    private var typeSection: some View {
        // "KIND", not "TYPE". Session 73: the phone called the ICON axis Type,
        // this pane called the COLOUR axis TYPE, and one word named opposite
        // things in two apps built from one model. Kind is D123's own phrase for
        // what colour answers, and it is now the word on both.
        section("KIND") {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(model.tintOrder, id: \.self) { tint in
                    let live = model.tintLive[tint] ?? 0
                    let isOn = selectedTints.contains(tint)
                    Button {
                        if selectedTints.contains(tint) { selectedTints.remove(tint) }
                        else { selectedTints.insert(tint) }
                    } label: {
                        HStack(spacing: 7) {
                            Circle()
                                .fill(MacPalette.documentTint(tint))
                                .frame(width: 9, height: 9)
                            Text(tint.facetLabel)
                                .font(MacType.row)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 4)
                            Text("\(live)")
                                .font(MacType.meta)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(isOn ? Color.accentColor.opacity(0.15) : Color.clear)
                        .foregroundStyle(isOn ? Color.accentColor : Color.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointerStyle(.link)
                    .opacity(live == 0 && !isOn ? 0.32 : 1)
                    .help(tint.facetLabel)
                }
            }
        }
    }

    // MARK: Tags — the cloud proper

    private var tagSection: some View {
        section("TAGS") {
            cloud(items: model.tagOrder.map { tag in
                CloudItem(key: tag,
                          text: tag,
                          symbol: tag.caseInsensitiveCompare("private") == .orderedSame
                                  ? "lock.fill" : nil,
                          size: Self.weight(model.tagTotal[tag] ?? 0, max: model.tagMax),
                          live: model.tagLive[tag] ?? 0,
                          selected: selectedTags.contains(tag),
                          // Through the shared function, not a second copy of
                          // the rule. `private` is orange in three other places
                          // and this is the fourth — see the note on
                          // `DocListRow`, where the third one drifted.
                          colour: DocChipsEditor.tint(for: tag, base: .accentColor),
                          help: "\(model.tagTotal[tag] ?? 0) in the library")
            }) { key in
                if selectedTags.contains(key) { selectedTags.remove(key) }
                else { selectedTags.insert(key) }
            }
        }
    }

    // MARK: Section chrome

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(MacType.label)
                .tracking(MacType.labelTracking)
                .foregroundStyle(.secondary)
            content()
        }
    }

    // MARK: Weighting

    /// Point size for a facet appearing `count` times in a library whose
    /// commonest facet appears `max` times.
    ///
    /// Square root rather than linear. With a long tail of ones and a single
    /// value at eleven, linear scaling spends most of its range on the gap
    /// between the top two entries and renders everything below them at the
    /// floor — which is the failure this pane exists to avoid.
    static func weight(_ count: Int, max: Int) -> CGFloat {
        guard count > 0, max > 1 else { return 11 }
        let t = (Double(count).squareRoot() - 1) / (Double(max).squareRoot() - 1)
        return 11 + CGFloat(t) * 8      // 11pt … 19pt
    }
}

// MARK: - Cloud

/// One chip in a packed cloud.
struct CloudItem: Identifiable {
    /// Stable identity for the toggle callback. The raw enum token or the tag.
    let key: String
    let text: String
    let symbol: String?
    let size: CGFloat
    let live: Int
    let selected: Bool
    let colour: Color
    let help: String

    var id: String { key }
}

extension DocFacetPanel {

    /// Pack `items` into rows against `contentWidth` and draw them.
    @ViewBuilder
    func cloud(items: [CloudItem], onTap: @escaping (String) -> Void) -> some View {
        let rows = Self.pack(items, into: contentWidth)
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 5) {
                    ForEach(row) { item in
                        chip(item, onTap: onTap)
                    }
                }
            }
        }
    }

    func chip(_ item: CloudItem, onTap: @escaping (String) -> Void) -> some View {
        Button { onTap(item.key) } label: {
            HStack(spacing: 3) {
                if let symbol = item.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: item.size * 0.82))
                }
                Text(item.text)
                    .font(.system(size: item.size,
                                  weight: item.selected ? .semibold : .regular))
                Text("\(item.live)")
                    .font(.system(size: Swift.max(item.size - 3, 9)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(item.selected ? item.colour.opacity(0.20) : item.colour.opacity(0.07))
            .foregroundStyle(item.selected ? item.colour : Color.primary.opacity(0.85))
            .overlay(
                Capsule().strokeBorder(item.selected ? item.colour.opacity(0.55) : .clear,
                                       lineWidth: 1)
            )
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        // Dimmed, not removed. See the file header.
        .opacity(item.live == 0 && !item.selected ? 0.32 : 1)
        .help(item.help)
    }

    /// Greedy first-fit packing. Widths come from AppKit text measurement
    /// against the same point sizes SwiftUI is handed, plus the chip's own
    /// padding and a couple of points of slack.
    static func pack(_ items: [CloudItem], into width: CGFloat) -> [[CloudItem]] {
        var rows: [[CloudItem]] = []
        var row: [CloudItem] = []
        var used: CGFloat = 0
        for item in items {
            let w = measure(item)
            // An item wider than the pane still gets its own row rather than
            // being dropped; it truncates, which is visible, instead of
            // vanishing, which is not.
            if !row.isEmpty && used + 5 + w > width {
                rows.append(row)
                row = [item]
                used = w
            } else {
                used += (row.isEmpty ? 0 : 5) + w
                row.append(item)
            }
        }
        if !row.isEmpty { rows.append(row) }
        return rows
    }

    static func measure(_ item: CloudItem) -> CGFloat {
        let font = NSFont.systemFont(ofSize: item.size,
                                     weight: item.selected ? .semibold : .regular)
        let text = (item.text as NSString)
            .size(withAttributes: [.font: font]).width
        let countFont = NSFont.monospacedDigitSystemFont(ofSize: Swift.max(item.size - 3, 9),
                                                         weight: .regular)
        let count = ("\(item.live)" as NSString)
            .size(withAttributes: [.font: countFont]).width
        let glyph: CGFloat = item.symbol == nil ? 0 : item.size * 0.82 + 3
        return text + count + glyph + 12 /* padding */ + 3 /* gap */ + 3 /* slack */
    }
}
