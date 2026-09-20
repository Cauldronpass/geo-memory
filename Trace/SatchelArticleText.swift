// SatchelArticleText.swift
// Shared (moved from `Satchel/` in D420 so TraceMac reads the same format).
// Membership: Satchel and TraceMac, explicit; Trace compiles its whole folder.
// D419 — the article's structure, as it is written to `## Text`
// and as the reader reads it back.
//
// **Why light markings and not HTML.** The research for D419 was unanimous:
// Matter, Instapaper and GoodLinks all keep an article's headings, quotes and
// photos, and none of them shows plain text. The flat paragraphs Build 2 wrote
// were below that bar. But the text still has to live in the sidecar's
// `## Text` (E40: no third file per link), still has to be searchable, and has
// to read sensibly if he opens the sidecar in Obsidian. A few line prefixes do
// all three; an HTML blob does none of them.
//
// The format, one block per paragraph, blocks separated by a blank line:
//
//   <!-- byline: Jane Doe -->          hidden in Obsidian, read by the reader
//   <!-- published: 2026-09-09 -->
//   ### A heading
//   > A quote
//   - A bullet
//   1. A numbered item
//   ![The caption](https://example.com/photo.jpg)
//   Anything else is a paragraph.
//
// **`###`, never `##`.** Both stores' `parseBody` treat a line starting "## "
// as the start of a new sidecar section, so a `##` heading inside an article
// would cut the article off at that heading and hand the rest to `extra`.
// Three hashes do not match that prefix.
//
// **Old articles read as they are.** A flat `## Text` from before D419 has no
// markings, so every block is a paragraph, which is exactly what it was.

import Foundation
import SwiftUI
import PDFKit
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

enum SatchelArticleText {

    enum Block: Hashable {
        case paragraph(String)
        case heading(String)
        case quote(String)
        case bullet(String)
        case numbered(String, String)   // marker ("3."), text
        case image(URL, String)         // address, caption (may be empty)
    }

    struct Parsed {
        var byline: String?
        var published: Date?
        var blocks: [Block] = []
    }

    static let bylinePrefix = "<!-- byline:"
    static let publishedPrefix = "<!-- published:"

    private static let dayFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt
    }()

    // MARK: Read

    static func parse(_ raw: String) -> Parsed {
        var parsed = Parsed()
        let normalized: String = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let chunks: [String] = normalized.components(separatedBy: "\n\n")
        for chunk in chunks {
            let lines: [String] = chunk
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            // A chunk can hold two meta lines, or a list written one item per
            // line by hand in Obsidian. Lines that carry their own marking are
            // blocks of their own; unmarked lines join the paragraph they sit in.
            var pending: [String] = []
            for line in lines {
                if let block = marked(line, into: &parsed) {
                    flush(&pending, into: &parsed)
                    if let block { parsed.blocks.append(block) }
                } else {
                    pending.append(line)
                }
            }
            flush(&pending, into: &parsed)
        }
        return parsed
    }

    private static func flush(_ pending: inout [String], into parsed: inout Parsed) {
        guard !pending.isEmpty else { return }
        parsed.blocks.append(.paragraph(pending.joined(separator: " ")))
        pending.removeAll()
    }

    /// `nil` when the line is an ordinary one. `.some(nil)` when it is a meta
    /// line, consumed into `parsed` and drawn as nothing.
    private static func marked(_ line: String, into parsed: inout Parsed) -> Block?? {
        if line.hasPrefix(bylinePrefix) {
            let value: String = metaValue(line, prefix: bylinePrefix)
            if !value.isEmpty { parsed.byline = value }
            return .some(nil)
        }
        if line.hasPrefix(publishedPrefix) {
            let value: String = metaValue(line, prefix: publishedPrefix)
            parsed.published = dayFormatter.date(from: value)
            return .some(nil)
        }
        if line.hasPrefix("### ") || line.hasPrefix("#### ") {
            let text: String = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            if text.isEmpty { return .some(nil) }
            return .some(Block.heading(text))
        }
        if line.hasPrefix("> ") {
            return .some(Block.quote(String(line.dropFirst(2))))
        }
        if line.hasPrefix("- ") {
            return .some(Block.bullet(String(line.dropFirst(2))))
        }
        if let image = imageBlock(line) {
            return .some(image)
        }
        if let numbered = numberedBlock(line) {
            return .some(numbered)
        }
        return nil
    }

    private static func metaValue(_ line: String, prefix: String) -> String {
        var body: Substring = line.dropFirst(prefix.count)
        if body.hasSuffix("-->") { body = body.dropLast(3) }
        return body.trimmingCharacters(in: .whitespaces)
    }

    /// `![caption](address)`. The caption is split at the LAST `](` so a caption
    /// is never the thing that breaks it; the fetch strips brackets from
    /// captions and escapes `)` in addresses, so there is only ever one.
    private static func imageBlock(_ line: String) -> Block? {
        guard line.hasPrefix("!["), line.hasSuffix(")"),
              let split = line.range(of: "](", options: .backwards) else { return nil }
        let caption: String = String(line[line.index(line.startIndex, offsetBy: 2)..<split.lowerBound])
        let address: String = String(line[split.upperBound..<line.index(before: line.endIndex)])
        guard let url = URL(string: address),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else { return nil }
        return .image(url, caption.trimmingCharacters(in: .whitespaces))
    }

    private static func numberedBlock(_ line: String) -> Block? {
        guard let dot = line.firstIndex(of: "."), line.distance(from: line.startIndex, to: dot) <= 3 else { return nil }
        let digits: Substring = line[line.startIndex..<dot]
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        let after: Substring = line[line.index(after: dot)...]
        guard after.hasPrefix(" ") else { return nil }
        return .numbered(String(digits) + ".", after.trimmingCharacters(in: .whitespaces))
    }

    // MARK: Derived

    /// Words a person reads, for the minutes on every row. Photo addresses and
    /// meta lines are not reading; a caption is, and is counted.
    ///
    /// **Line by line, not through `parse`.** This runs for every row on the
    /// Shelf on every render; a full parse per row is the kind of cost that
    /// shows up as a stutter in a long list and nowhere in a code review. Text
    /// with no photo or meta lines — every article saved before D419 — takes
    /// the same one-split path it always did.
    static func wordCount(_ raw: String) -> Int {
        guard raw.contains("![") || raw.contains("<!--") else {
            return words(in: raw)
        }
        var count = 0
        for line in raw.split(separator: "\n") {
            let trimmed: Substring = line.drop(while: { $0 == " " })
            if trimmed.hasPrefix("<!--") { continue }
            if trimmed.hasPrefix("!["), let split = trimmed.range(of: "](", options: .backwards) {
                let captionStart = trimmed.index(trimmed.startIndex, offsetBy: 2)
                if captionStart <= split.lowerBound {
                    count += words(in: trimmed[captionStart..<split.lowerBound])
                }
                continue
            }
            count += words(in: trimmed)
        }
        return count
    }

    /// The text with photo lines removed, for the detail screen's Links row —
    /// which would otherwise list every photo address in the article as a link
    /// he saved.
    static func withoutImages(_ raw: String) -> String {
        guard raw.contains("![") else { return raw }
        return raw
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("![") }
            .joined(separator: "\n")
    }

    private static func words<S: StringProtocol>(in text: S) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }
}

// MARK: - Shelf membership (moved from Satchel/SatchelShelf.swift, D422)
//
// Shared so the Mac's Shelf and the phone's cannot disagree about what is
// queued, what is new and what is read. Pure filters and sorts over documents
// both stores already hold.

/// Who is on the shelf, and in what order.
///
/// A plain namespace over `[TraceMacDocument]` rather than a store: every
/// question here is a filter and a sort over documents the store already holds,
/// so a second thing to keep in step would be E40's mistake in miniature.
enum SatchelShelf {

    /// Words a minute. The number every reading-time estimate uses, and it only
    /// has to be roughly right — the figure exists to separate "a coffee" from
    /// "an evening", not to be accurate to the minute.
    static let wordsPerMinute = 230

    static func isArticle(_ doc: TraceMacDocument) -> Bool {
        doc.articleState == .article
    }

    /// Ordered, and the order IS `read_next` (D407): moving item 1 to fourth
    /// drops it off Home and keeps it on the Shelf.
    static func upNext(_ documents: [TraceMacDocument]) -> [TraceMacDocument] {
        documents
            .filter { isArticle($0) && $0.readOn == nil && $0.readNext != nil }
            .sorted { ($0.readNext ?? 0) < ($1.readNext ?? 0) }
    }

    /// Everything else that is readable and unread, newest arrival first.
    static func newArrivals(_ documents: [TraceMacDocument]) -> [TraceMacDocument] {
        documents
            .filter { isArticle($0) && $0.readOn == nil && $0.readNext == nil }
            .sorted { ($0.listDate ?? .distantPast) > ($1.listDate ?? .distantPast) }
    }

    /// Articles leave Recent (D407). Read ones leave too: a piece he has
    /// finished is not what "recent" is asking about.
    static func notOnShelf(_ documents: [TraceMacDocument]) -> [TraceMacDocument] {
        documents.filter { !isArticle($0) }
    }

    /// Minutes to read, from the pulled text. Never zero — an article with a
    /// word count under a minute still took a decision to save.
    static func minutes(_ doc: TraceMacDocument) -> Int {
        // Through the article format (D419): photo addresses and the byline
        // line are not reading, and counting them would add a minute per
        // dozen photos.
        let words: Int = SatchelArticleText.wordCount(doc.extractedText)
        return max(1, Int((Double(words) / Double(wordsPerMinute)).rounded()))
    }

    static func totalMinutes(_ documents: [TraceMacDocument]) -> Int {
        documents.reduce(0) { $0 + minutes($1) }
    }

    /// The site, for the kicker under a title. The host without `www.`, which
    /// is what a reader recognises.
    static func site(_ doc: TraceMacDocument) -> String {
        guard let url = TraceMacDocument.openableURL(doc.url), let host = url.host else { return "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Finished, most recently read first. **The shelf keeps them** (D418): a
    /// read article that vanishes from every screen is what happened to the
    /// Emmys piece, and the only way back was to know it had gone. Folded by
    /// default, because it is a record and not a queue.
    static func read(_ documents: [TraceMacDocument]) -> [TraceMacDocument] {
        documents
            .filter { isArticle($0) && $0.readOn != nil }
            .sorted { ($0.readOn ?? .distantPast) > ($1.readOn ?? .distantPast) }
    }

    /// "read Sep 13", for a card in the library.
    static func readLine(_ doc: TraceMacDocument) -> String? {
        guard let read = doc.readOn else { return nil }
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d"
        return "read \(fmt.string(from: read))"
    }
}

// MARK: - Drawing the article (D422)
//
// **One renderer for both screens.** The phone's reader drew these blocks
// itself; the Mac reader needed the same drawing, and two copies of "what a
// quote looks like" is the renderer drift this project has paid for before. The
// header (kicker, headline, recap, lead photo) stays with each screen, because
// the chrome around an article is genuinely different on a phone and a Mac;
// the article itself is not.

/// The five colours an article is drawn in. Each screen resolves its theme to
/// these; the article does not know which theme it is in.
struct SatchelArticleInk {
    let ink: Color
    let secondary: Color
    let faint: Color
    let card: Color
    let accent: Color
    /// The highlight wash (D430). Defaulted so a palette that predates
    /// highlights still compiles; both readers set their own, because a yellow
    /// that reads on white is a glare on the dark paper.
    var highlight: Color = Color(red: 1.0, green: 0.898, blue: 0.541)
    /// The rule under a highlight that carries one of his lines (D432).
    var highlightLine: Color = Color(red: 0.85, green: 0.67, blue: 0.16)
}

enum SatchelArticleLayout {
    /// Extra space between lines as a fraction of the text size, for Tight,
    /// Normal and Loose.
    static func lineGap(size: Double, spacing: Int) -> CGFloat {
        let factors: [Double] = [0.22, 0.42, 0.66]
        let index: Int = min(max(spacing, 0), 2)
        return CGFloat(size * factors[index])
    }
}

struct SatchelArticleBody: View {
    let blocks: [SatchelArticleText.Block]
    let size: Double
    let serif: Bool
    let spacing: Int
    let colors: SatchelArticleInk
    /// How far a photo reaches past the text on each side. The phone runs
    /// photos edge to edge; the Mac keeps them inside the reading column.
    let photoBleed: CGFloat
    /// Where the highlights sit in this article as it reads now, by block
    /// (D431). Worked out once by the reader, never here: this view redraws
    /// with every scroll of a long article.
    var marks: [Int: [SatchelTextMark]] = [:]
    /// A passage was chosen: the block it is in, its place in that block, and
    /// the words themselves.
    var onMakeHighlight: ((Int, NSRange, String) -> Void)? = nil
    /// An existing highlight was tapped (phone) or right-clicked (Mac).
    var onOpenMark: ((String) -> Void)? = nil
    /// Remove, straight from the Mac's right-click menu (D441).
    var onRemoveMark: ((String) -> Void)? = nil

    private var design: Font.Design { serif ? .serif : .default }
    private var bodySize: CGFloat { CGFloat(size) }
    private var lineGap: CGFloat { SatchelArticleLayout.lineGap(size: size, spacing: spacing) }
    private var bodyFont: Font { .system(size: bodySize, weight: .regular, design: design) }

    /// What a block is called inside the article's scroll view.
    static func blockID(_ index: Int) -> String { "satchel-block-\(index)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { item in
                block(item.element, at: item.offset)
                    // Named so the Highlights list can jump to a passage
                    // (D435). Costs nothing when nothing jumps.
                    .id(SatchelArticleBody.blockID(item.offset))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func block(_ block: SatchelArticleText.Block, at index: Int) -> some View {
        switch block {
        case .paragraph(let text):
            paragraph(text, at: index)
        case .heading(let text):
            heading(text)
        case .quote(let text):
            quote(text, at: index)
        case .bullet(let text):
            listItem(marker: "\u{2022}", text: text, at: index)
        case .numbered(let marker, let text):
            listItem(marker: marker, text: text, at: index)
        case .image(let url, let caption):
            SatchelArticlePhoto(url: url, caption: caption, colors: colors,
                                gap: bodySize, bleed: photoBleed)
        }
    }

    private func paragraph(_ text: String, at index: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            selectable(text, at: index, size: bodySize, weight: .regular, italic: false)
            lines(at: index)
        }
        .padding(.bottom, bodySize * 0.9)
    }

    /// **What he wrote, under the paragraph he wrote it about** (D444). Until
    /// this, a line showed only as an underline on the passage: the words were
    /// stored, sent to the note, and visible on no screen at all.
    @ViewBuilder
    private func lines(at index: Int) -> some View {
        let written: [SatchelTextMark] = (marks[index] ?? []).filter { $0.hasLine }
        if !written.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(written, id: \.id) { mark in
                    Text(mark.line)
                        .font(.system(size: bodySize * 0.82, design: design).italic())
                        .foregroundStyle(colors.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 11)
                        .overlay(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 1, style: .continuous)
                                .fill(colors.highlightLine)
                                .frame(width: 2)
                        }
                }
            }
            .padding(.top, bodySize * 0.35)
        }
    }

    /// One block, drawn by the platform's text view so a selection can be read
    /// back (D430). The type, colour and line spacing are the same values the
    /// SwiftUI version used.
    private func selectable(_ text: String, at index: Int,
                            size: CGFloat, weight: Font.Weight, italic: Bool) -> some View {
        SatchelSelectableText(
            text: text,
            font: SatchelArticleFont.make(size: size, weight: platformWeight(weight),
                                          serif: serif, italic: italic),
            color: platformColor(colors.ink),
            lineSpacing: lineGap,
            marks: marks[index] ?? [],
            markColor: platformColor(colors.highlight),
            markLine: platformColor(colors.highlightLine),
            onMakeHighlight: { range, selected in
                onMakeHighlight?(index, range, selected)
            },
            onOpenMark: { id in
                onOpenMark?(id)
            },
            onRemoveMark: { id in
                onRemoveMark?(id)
            }
        )
        // Horizontally greedy, vertically its own size: the block fills the
        // reading column rather than negotiating a width with it (D445).
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func heading(_ text: String) -> some View {
        Text(text)
            .font(.system(size: bodySize * 1.14, weight: .bold, design: design))
            .foregroundStyle(colors.ink)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, bodySize * 0.6)
            .padding(.bottom, bodySize * 0.5)
    }

    /// Set apart by a rule in the accent colour. An overlay rather than an
    /// `HStack` with a rectangle in it: a shape in a stack inside a vertical
    /// scroll view is offered unlimited height and can take it.
    private func quote(_ text: String, at index: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            selectable(text, at: index, size: bodySize * 1.06, weight: .regular, italic: true)
            lines(at: index)
        }
            .padding(.leading, 17)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(colors.accent)
                    .frame(width: 3)
            }
            .padding(.top, bodySize * 0.3)
            .padding(.bottom, bodySize * 1.0)
    }

    private func listItem(marker: String, text: String, at index: Int) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(marker)
                .font(bodyFont)
                .foregroundStyle(colors.secondary)
                .frame(minWidth: 16, alignment: .trailing)
            VStack(alignment: .leading, spacing: 0) {
                selectable(text, at: index, size: bodySize, weight: .regular, italic: false)
                lines(at: index)
            }
        }
        .padding(.leading, 2)
        .padding(.bottom, bodySize * 0.45)
    }

    // MARK: Platform bridges

    #if os(iOS)
    private func platformColor(_ color: Color) -> UIColor { UIColor(color) }
    private func platformWeight(_ weight: Font.Weight) -> UIFont.Weight {
        weight == .bold ? .bold : .regular
    }
    #elseif os(macOS)
    private func platformColor(_ color: Color) -> NSColor { NSColor(color) }
    private func platformWeight(_ weight: Font.Weight) -> NSFont.Weight {
        weight == .bold ? .bold : .regular
    }
    #endif
}

/// A photo in the article. Loaded from the site when the article is opened,
/// cached by the system's URL cache, never saved beside the link (E40).
/// Offline, or when the site refuses, a grey box with the caption under it.
struct SatchelArticlePhoto: View {
    let url: URL
    let caption: String
    let colors: SatchelArticleInk
    let gap: CGFloat
    let bleed: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFit()
                case .failure:
                    placeholder(loading: false)
                case .empty:
                    placeholder(loading: true)
                @unknown default:
                    placeholder(loading: false)
                }
            }
            .padding(.horizontal, -bleed)
            if !caption.isEmpty {
                Text(caption)
                    .font(.system(size: 12.5))
                    .foregroundStyle(colors.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, gap * 0.3)
        .padding(.bottom, gap * 1.1)
    }

    private func placeholder(loading: Bool) -> some View {
        ZStack {
            colors.card
            if loading {
                ProgressView()
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 22))
                    .foregroundStyle(colors.faint)
            }
        }
        .frame(height: 200)
    }
}

// MARK: - Highlights (D430–D437, Session 107)
//
// **What a highlight is.** A passage he marked while reading, plus an optional
// line of his own. It belongs to the document, not to a screen, and it has to
// survive Fetch again — which rewrites `## Text` wholesale — so it is kept in a
// section of its own and found again BY ITS OWN WORDS (D431). The block number
// is a shortcut, not the address: if the article is re-fetched and the
// paragraphs shift, the words still find their place; if the site rewrote the
// sentence, the highlight stays in the list and reaches the note, and only the
// drawing is lost.
//
// **Why a section and not a frontmatter key.** The trap rule: a key one store
// does not know is deleted by that store's next save. A `## ` section is the
// opposite — both stores already hand an unrecognised section to `extra` and
// re-emit it untouched, so the worst a stale build can do is leave it alone.
// Both stores parse it properly as of this build.
//
// On disk, one entry per blank-line-separated chunk:
//
//   > Companies holding more than a year of operating cash underperformed.
//   <!-- hl: b4 | id 8FC21A03 | made 2026-09-17 | sent 2026-09-17 -->
//   Ask Treasury what our months of cover is.

struct SatchelHighlight: Identifiable, Hashable {
    /// Eight hex characters, made once when the highlight is made. Stable
    /// across a re-fetch and across devices, which the text cannot be: two
    /// identical sentences in one article would otherwise be one highlight.
    let id: String
    /// Which block it was made in. A hint for the search, nothing more.
    var block: Int
    /// The passage, exactly as it read when he marked it.
    var text: String
    /// His own line, or empty. One line by design (D432).
    var line: String
    var made: Date
    /// When it last went to a note, or nil for one that has never been sent.
    var sent: Date?

    var isSent: Bool { sent != nil }

    static func newID() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).uppercased()
    }
}

enum SatchelHighlightText {

    static let heading = "## Highlights"
    private static let metaPrefix = "<!-- hl:"

    private static let dayFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt
    }()

    // MARK: Read

    /// Tolerant on purpose. A chunk with no meta line still yields a highlight
    /// (it just gets a fresh id and today's date), because a passage he marked
    /// is worth more than the bookkeeping around it.
    static func parse(_ raw: String) -> [SatchelHighlight] {
        let normalized: String = raw.replacingOccurrences(of: "\r\n", with: "\n")
        var out: [SatchelHighlight] = []
        for chunk in normalized.components(separatedBy: "\n\n") {
            let lines: [String] = chunk
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !lines.isEmpty else { continue }
            var passage: [String] = []
            var meta: String = ""
            var line: [String] = []
            for entry in lines {
                if entry.hasPrefix("> ") {
                    passage.append(String(entry.dropFirst(2)))
                } else if entry.hasPrefix(metaPrefix) {
                    meta = entry
                } else if !passage.isEmpty {
                    line.append(entry)
                }
            }
            let text: String = passage.joined(separator: " ")
            guard !text.isEmpty else { continue }
            let fields: [String: String] = metaFields(meta)
            let highlight = SatchelHighlight(
                id: fields["id"] ?? SatchelHighlight.newID(),
                block: Int(fields["b"] ?? "") ?? 0,
                text: text,
                line: line.joined(separator: " "),
                made: dayFormatter.date(from: fields["made"] ?? "") ?? Date(),
                sent: dayFormatter.date(from: fields["sent"] ?? "")
            )
            out.append(highlight)
        }
        return out
    }

    /// `<!-- hl: b4 | id 8FC21A03 | made 2026-09-17 -->` into a dictionary.
    private static func metaFields(_ meta: String) -> [String: String] {
        guard meta.hasPrefix(metaPrefix) else { return [:] }
        var body: Substring = meta.dropFirst(metaPrefix.count)
        if body.hasSuffix("-->") { body = body.dropLast(3) }
        var fields: [String: String] = [:]
        for part in body.components(separatedBy: "|") {
            let words: [String] = part
                .trimmingCharacters(in: .whitespaces)
                .components(separatedBy: " ")
                .filter { !$0.isEmpty }
            guard let key = words.first else { continue }
            if key.hasPrefix("b"), words.count == 1 {
                fields["b"] = String(key.dropFirst())
            } else if words.count >= 2 {
                fields[key] = words[1]
            }
        }
        return fields
    }

    // MARK: Write

    /// Rendered in reading order, which is how they are always shown.
    static func render(_ highlights: [SatchelHighlight]) -> String {
        let ordered: [SatchelHighlight] = highlights.sorted { $0.block < $1.block }
        var chunks: [String] = []
        for highlight in ordered {
            var chunk: String = "> \(highlight.text)\n"
            chunk += meta(for: highlight)
            if !highlight.line.isEmpty {
                chunk += "\n\(highlight.line)"
            }
            chunks.append(chunk)
        }
        return chunks.joined(separator: "\n\n")
    }

    private static func meta(for highlight: SatchelHighlight) -> String {
        var parts: [String] = ["b\(highlight.block)",
                               "id \(highlight.id)",
                               "made \(dayFormatter.string(from: highlight.made))"]
        if let sent = highlight.sent {
            parts.append("sent \(dayFormatter.string(from: sent))")
        }
        return "<!-- hl: " + parts.joined(separator: " | ") + " -->"
    }

    // MARK: Finding them again

    /// Where each highlight sits in the article as it reads NOW.
    ///
    /// The block number first, then every block in order. A highlight whose
    /// words are nowhere in the article gets no entry here and is simply not
    /// drawn; it keeps its place in the list and in any note it reached.
    static func placements(_ highlights: [SatchelHighlight],
                           in blocks: [SatchelArticleText.Block]) -> [Int: [(range: NSRange, highlight: SatchelHighlight)]] {
        var out: [Int: [(range: NSRange, highlight: SatchelHighlight)]] = [:]
        let texts: [String] = blocks.map { plainText($0) }
        for highlight in highlights {
            guard let found = locate(highlight, in: texts) else { continue }
            out[found.block, default: []].append((found.range, highlight))
        }
        for key in out.keys {
            out[key]?.sort { $0.range.location < $1.range.location }
        }
        return out
    }

    private static func locate(_ highlight: SatchelHighlight,
                               in texts: [String]) -> (block: Int, range: NSRange)? {
        let needle: String = highlight.text
        guard !needle.isEmpty else { return nil }
        var order: [Int] = []
        if highlight.block >= 0 && highlight.block < texts.count { order.append(highlight.block) }
        for index in texts.indices where index != highlight.block { order.append(index) }
        for index in order {
            let haystack: NSString = texts[index] as NSString
            let range: NSRange = haystack.range(of: needle)
            if range.location != NSNotFound { return (index, range) }
        }
        return nil
    }

    /// What each block has to draw, ready for `SatchelArticleBody`.
    static func marks(_ highlights: [SatchelHighlight],
                      in blocks: [SatchelArticleText.Block]) -> [Int: [SatchelTextMark]] {
        let placed = placements(highlights, in: blocks)
        var out: [Int: [SatchelTextMark]] = [:]
        for (block, entries) in placed {
            out[block] = entries.map { entry in
                SatchelTextMark(id: entry.highlight.id,
                                range: entry.range,
                                line: entry.highlight.line)
            }
        }
        return out
    }

    /// The words a block shows, which is what a selection inside it is measured
    /// against. A photo has none.
    static func plainText(_ block: SatchelArticleText.Block) -> String {
        switch block {
        case .paragraph(let text): return text
        case .heading(let text):   return text
        case .quote(let text):     return text
        case .bullet(let text):    return text
        case .numbered(_, let text): return text
        case .image:               return ""
        }
    }

    /// Whether a selection is worth keeping as a highlight (D443).
    ///
    /// A stray drag can select a single curly quote or a comma, and one landed
    /// in David's first real note as a highlight reading `“`. Three characters
    /// and at least one letter or number is the floor: enough to reject
    /// punctuation and a mis-grab, low enough to keep a short phrase or a
    /// figure.
    static func worthKeeping(_ text: String) -> Bool {
        let trimmed: String = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return false }
        return trimmed.contains(where: { $0.isLetter || $0.isNumber })
    }

    /// The count for a Shelf row, without parsing anything (D436's lesson).
    static func count(_ raw: String) -> Int {
        guard !raw.isEmpty else { return 0 }
        var count = 0
        for line in raw.split(separator: "\n") where line.hasPrefix("> ") {
            count += 1
        }
        return count
    }
}

// MARK: - The text a highlight can be made in (D430)
//
// **Why the article's text is no longer drawn by SwiftUI `Text`.** Neither
// platform will tell an app which words are selected inside a `Text`: iOS has
// no selection in one at all, and the Mac's `.textSelection(.enabled)` selects
// for copying and reports nothing back. The whole feature rests on knowing what
// he chose, so the block has to be drawn by the platform's own text view —
// `UITextView` on the phone, `NSTextView` on the Mac — which also brings the
// selection handles, the loupe and the edit menu he already knows.
//
// Everything else about the reading surface is unchanged: same font, same
// measure, same line spacing, same colours. The header, photos and headings
// stay SwiftUI.
//
// **One block per text view, not one for the article.** It keeps the change
// inside `SatchelArticleBody`'s existing per-block loop, keeps a photo a photo,
// and keeps each view small enough to lay out cheaply. The cost is the D430
// rule David accepted: a highlight cannot cross a paragraph break.

/// A stretch of a block that is drawn as a highlight.
struct SatchelTextMark: Equatable {
    let id: String
    let range: NSRange
    /// His own line, or empty. **Carried here since D444**: the underline said a
    /// line existed and nothing on any screen showed what it said, so a line he
    /// typed was invisible everywhere.
    let line: String
    /// Drawn with an underline so a highlight carrying one of his lines can be
    /// told from one that does not (D432).
    var hasLine: Bool { !line.isEmpty }
}

#if os(iOS)

final class SatchelHighlightTextView: UITextView {
    var marks: [SatchelTextMark] = []
    var onMakeHighlight: ((NSRange, String) -> Void)?
    var onOpenMark: ((String) -> Void)?

    /// The character under a tap, or nil when the tap is past the end of the
    /// text (tapping the empty half of a last line should do nothing).
    func characterIndex(at point: CGPoint) -> Int? {
        guard let position = closestPosition(to: point) else { return nil }
        let index: Int = offset(from: beginningOfDocument, to: position)
        guard index >= 0, index < attributedText.length else { return nil }
        return index
    }
}

/// One block of article text, selectable, with **Highlight** in its edit menu.
struct SatchelSelectableText: UIViewRepresentable {
    let text: String
    let font: UIFont
    let color: UIColor
    let lineSpacing: CGFloat
    let marks: [SatchelTextMark]
    let markColor: UIColor
    let markLine: UIColor
    var onMakeHighlight: ((NSRange, String) -> Void)?
    var onOpenMark: ((String) -> Void)?
    /// Unused on the phone, where a tap opens the highlight's own menu and
    /// Remove sits in it. Taken so both platforms have one set of arguments.
    var onRemoveMark: ((String) -> Void)?

    func makeUIView(context: Context) -> SatchelHighlightTextView {
        let view = SatchelHighlightTextView(frame: .zero, textContainer: nil)
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.textContainer.lineBreakMode = .byWordWrapping
        view.delegate = context.coordinator
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.tapped(_:)))
        tap.delegate = context.coordinator
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
        context.coordinator.view = view
        return view
    }

    func updateUIView(_ view: SatchelHighlightTextView, context: Context) {
        context.coordinator.parent = self
        view.marks = marks
        view.onMakeHighlight = onMakeHighlight
        view.onOpenMark = onOpenMark
        view.attributedText = attributed()
    }

    func sizeThatFits(_ proposal: ProposedViewSize,
                      uiView: SatchelHighlightTextView,
                      context: Context) -> CGSize? {
        // The Mac's rule, applied here too (D445): answer with the width
        // offered, never with the view's own idea of one.
        var width: CGFloat = proposal.width ?? uiView.bounds.width
        if width <= 1 { width = uiView.bounds.width }
        if width <= 1 { width = UIScreen.main.bounds.width - 44 }
        let fitted: CGSize = uiView.sizeThatFits(CGSize(width: width,
                                                        height: CGFloat.greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(fitted.height))
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    private func attributed() -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.lineBreakMode = .byWordWrapping
        let body = NSMutableAttributedString(
            string: text,
            attributes: [.font: font,
                         .foregroundColor: color,
                         .paragraphStyle: paragraph]
        )
        let whole = NSRange(location: 0, length: body.length)
        for mark in marks {
            let range: NSRange = NSIntersectionRange(mark.range, whole)
            guard range.length > 0 else { continue }
            body.addAttribute(.backgroundColor, value: markColor, range: range)
            if mark.hasLine {
                body.addAttribute(.underlineStyle,
                                  value: NSUnderlineStyle.single.rawValue,
                                  range: range)
                body.addAttribute(.underlineColor, value: markLine, range: range)
            }
        }
        return body
    }

    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        var parent: SatchelSelectableText
        weak var view: SatchelHighlightTextView?

        init(parent: SatchelSelectableText) { self.parent = parent }

        /// **Highlight first, then what the system offers.** Copy, Look Up and
        /// Share stay where they are; the new item leads because it is the one
        /// this screen exists for.
        func textView(_ textView: UITextView,
                      editMenuForTextIn range: NSRange,
                      suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard range.length > 0 else { return UIMenu(children: suggestedActions) }
            let source: NSString = textView.attributedText.string as NSString
            let selected: String = source.substring(with: range)
            let make = UIAction(title: "Highlight",
                                image: UIImage(systemName: "highlighter")) { [weak textView] _ in
                textView?.selectedRange = NSRange(location: range.location, length: 0)
                self.parent.onMakeHighlight?(range, selected)
            }
            return UIMenu(children: [make] + suggestedActions)
        }

        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            guard let view else { return }
            guard view.selectedRange.length == 0 else { return }
            let point: CGPoint = gesture.location(in: view)
            guard let index = view.characterIndex(at: point) else { return }
            for mark in view.marks where NSLocationInRange(index, mark.range) {
                view.onOpenMark?(mark.id)
                return
            }
        }

        /// The tap must not fight the text view's own recognisers: a tap that
        /// lands on nothing still has to reach the reader, which uses it to
        /// bring the bars back (D419).
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

#elseif os(macOS)

final class SatchelHighlightTextView: NSTextView {
    var marks: [SatchelTextMark] = []
    var onMakeHighlight: ((NSRange, String) -> Void)?
    var onOpenMark: ((String) -> Void)?
    var onRemoveMark: ((String) -> Void)?

    /// **What was clicked decides the menu, and the click is asked about first**
    /// (D442). A right-click on an existing highlight offers Add a line and
    /// Remove; anywhere else, with a selection, offers Highlight.
    ///
    /// The order matters and the first version had it backwards. `NSTextView`
    /// selects the word under the pointer as part of opening a context menu, so
    /// by the time this runs there is ALWAYS a selection — the selection test
    /// therefore matched on every right-click and the highlight's own items were
    /// unreachable. David: *"i see highlight as an option for right click but not
    /// this highlight"*.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu: NSMenu = super.menu(for: event) ?? NSMenu()
        let point: NSPoint = convert(event.locationInWindow, from: nil)
        let clicked: String? = markID(at: point)
        let selected: NSRange = selectedRange()
        if clicked == nil {
            guard selected.length > 0 else { return menu }
            let item = NSMenuItem(title: "Highlight", action: #selector(makeHighlight(_:)), keyEquivalent: "h")
            item.keyEquivalentModifierMask = [.control, .command]
            item.target = self
            menu.insertItem(item, at: 0)
            menu.insertItem(NSMenuItem.separator(), at: 1)
            return menu
        }
        guard let id = clicked else { return menu }
        // **Both actions in the menu itself** (D441). They were behind one
        // "This highlight…" item opening a dialog: three steps to undo a
        // highlight he made in one.
        let line = NSMenuItem(title: lineTitle(for: id), action: #selector(openMark(_:)), keyEquivalent: "")
        line.target = self
        line.representedObject = id
        let remove = NSMenuItem(title: "Remove highlight", action: #selector(removeMark(_:)), keyEquivalent: "")
        remove.target = self
        remove.representedObject = id
        menu.insertItem(line, at: 0)
        menu.insertItem(remove, at: 1)
        menu.insertItem(NSMenuItem.separator(), at: 2)
        return menu
    }

    private func lineTitle(for id: String) -> String {
        let marked: SatchelTextMark? = marks.first { $0.id == id }
        return (marked?.hasLine ?? false) ? "Edit the line…" : "Add a line…"
    }

    /// ⌃⌘H, Apple Books' own key. Plain ⌘H is Hide on the Mac and is not
    /// available to take (D430).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags: NSEvent.ModifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == [.control, .command], event.charactersIgnoringModifiers?.lowercased() == "h" {
            if selectedRange().length > 0 {
                makeHighlight(nil)
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    // **No `intrinsicContentSize` override, and nothing invalidates layout from
    // inside this view** (D446). D445 added both, and TraceMac then crashed on
    // opening any article: the layout manager resizes the text view while AppKit
    // is drawing it, that resize asked SwiftUI to redo its layout mid-draw, and
    // AppKit turns a layout invalidation inside a display cycle into a fatal
    // exception. The collapse D445 was fixing is handled entirely by
    // `sizeThatFits` never returning nil, which is the part that worked.

    /// **Drop the selection on the way out** (D439). Each block is its own text
    /// view, so clicking into another paragraph leaves this one selected but no
    /// longer focused, and AppKit draws that state in its inactive grey. Across
    /// an article it reads as stray grey blocks trailing behind the reader.
    /// Clearing here is also what he means by moving on: a selection he did not
    /// act on is finished with.
    override func resignFirstResponder() -> Bool {
        setSelectedRange(NSRange(location: 0, length: 0))
        return super.resignFirstResponder()
    }

    @objc func makeHighlight(_ sender: Any?) {
        let range: NSRange = selectedRange()
        guard range.length > 0 else { return }
        let source: NSString = string as NSString
        let selected: String = source.substring(with: range)
        setSelectedRange(NSRange(location: range.location, length: 0))
        onMakeHighlight?(range, selected)
    }

    @objc func openMark(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, let id = item.representedObject as? String else { return }
        onOpenMark?(id)
    }

    @objc func removeMark(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, let id = item.representedObject as? String else { return }
        onRemoveMark?(id)
    }

    private func markID(at point: NSPoint) -> String? {
        let index: Int = characterIndexForInsertion(at: point)
        guard index >= 0, index < (string as NSString).length else { return nil }
        for mark in marks where NSLocationInRange(index, mark.range) { return mark.id }
        return nil
    }
}

/// Measures wrapped text without touching the view that will draw it.
///
/// A `TextKit` stack of its own, reused between calls: making one per paragraph
/// per layout pass is the kind of cost that shows up as a stutter in a long
/// article (D436's lesson), and laying out the live one is what crashed the app
/// (D446).
@MainActor
enum SatchelTextMeasure {
    private static let container: NSTextContainer = {
        // Explicit `CGFloat`s: `width: 100` is an integer literal, and with a
        // bare `.greatestFiniteMagnitude` beside it the compiler cannot tell
        // which `NSSize` initialiser is meant (D447).
        let made = NSTextContainer(size: NSSize(width: CGFloat(100),
                                                height: CGFloat.greatestFiniteMagnitude))
        made.lineFragmentPadding = 0
        made.widthTracksTextView = false
        return made
    }()
    private static let manager: NSLayoutManager = {
        let made = NSLayoutManager()
        made.addTextContainer(container)
        return made
    }()
    private static let storage: NSTextStorage = {
        let made = NSTextStorage()
        made.addLayoutManager(manager)
        return made
    }()

    static func height(of text: NSAttributedString, width: CGFloat) -> CGFloat {
        storage.setAttributedString(text)
        container.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        return ceil(manager.usedRect(for: container).height)
    }
}

/// One block of article text on the Mac. Same contract as the phone's.
struct SatchelSelectableText: NSViewRepresentable {
    let text: String
    let font: NSFont
    let color: NSColor
    let lineSpacing: CGFloat
    let marks: [SatchelTextMark]
    let markColor: NSColor
    let markLine: NSColor
    var onMakeHighlight: ((NSRange, String) -> Void)?
    var onOpenMark: ((String) -> Void)?
    var onRemoveMark: ((String) -> Void)?

    func makeNSView(context: Context) -> SatchelHighlightTextView {
        // **TextKit 1 on purpose.** The measuring below and the click hit-test
        // both go through `layoutManager`, which a TextKit 2 view does not
        // vend. A reading column has no need of what TextKit 2 adds.
        let view = SatchelHighlightTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        // **The view never resizes itself** (D446): the frame comes from
        // `sizeThatFits`, the container follows the frame's width, and nothing
        // here asks AppKit or SwiftUI for a new layout while drawing.
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateNSView(_ view: SatchelHighlightTextView, context: Context) {
        view.marks = marks
        view.onMakeHighlight = onMakeHighlight
        view.onOpenMark = onOpenMark
        view.onRemoveMark = onRemoveMark
        view.textStorage?.setAttributedString(attributed())
    }

    /// **Takes the width it is offered and reports only the height** (D445).
    ///
    /// An unspecified proposal used to return nil, which tells SwiftUI to fall
    /// back on the view's ideal size, and a wrapping text view's ideal width is
    /// its longest word. That is what turned the article into a one-character
    /// column. An unspecified width now answers with the width the view already
    /// has, and failing that with a reading measure, so the answer is always a
    /// real column.
    func sizeThatFits(_ proposal: ProposedViewSize,
                      nsView: SatchelHighlightTextView,
                      context: Context) -> CGSize? {
        var width: CGFloat = proposal.width ?? nsView.bounds.width
        if width <= 1 { width = nsView.bounds.width }
        if width <= 1 { width = 600 }
        // **Measured on a throwaway layout, not on the view's own** (D446).
        // Laying out the live text container from inside a sizing pass is what
        // made AppKit resize the view mid-draw and crash the app.
        guard let storage = nsView.textStorage else {
            return CGSize(width: width, height: 0)
        }
        let height: CGFloat = SatchelTextMeasure.height(of: storage, width: width)
        return CGSize(width: width, height: height)
    }

    private func attributed() -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.lineBreakMode = .byWordWrapping
        let body = NSMutableAttributedString(
            string: text,
            attributes: [.font: font,
                         .foregroundColor: color,
                         .paragraphStyle: paragraph]
        )
        let whole = NSRange(location: 0, length: body.length)
        for mark in marks {
            let range: NSRange = NSIntersectionRange(mark.range, whole)
            guard range.length > 0 else { continue }
            body.addAttribute(.backgroundColor, value: markColor, range: range)
            if mark.hasLine {
                body.addAttribute(.underlineStyle,
                                  value: NSUnderlineStyle.single.rawValue,
                                  range: range)
                body.addAttribute(.underlineColor, value: markLine, range: range)
            }
        }
        return body
    }
}

#endif

// MARK: - Fonts for the platform text views
//
// The article's type, expressed once for UIKit and AppKit. SwiftUI's
// `.system(size:weight:design:)` has no direct platform twin, so this builds the
// same face through the font descriptor: the serif design is New York, the
// default is San Francisco, and italic is a trait on top.

enum SatchelArticleFont {
    #if os(iOS)
    static func make(size: CGFloat, weight: UIFont.Weight, serif: Bool, italic: Bool) -> UIFont {
        let base: UIFont = .systemFont(ofSize: size, weight: weight)
        var descriptor: UIFontDescriptor = base.fontDescriptor
        if serif, let serifed = descriptor.withDesign(.serif) { descriptor = serifed }
        if italic, let slanted = descriptor.withSymbolicTraits(descriptor.symbolicTraits.union(.traitItalic)) {
            descriptor = slanted
        }
        return UIFont(descriptor: descriptor, size: size)
    }
    #elseif os(macOS)
    static func make(size: CGFloat, weight: NSFont.Weight, serif: Bool, italic: Bool) -> NSFont {
        let base: NSFont = .systemFont(ofSize: size, weight: weight)
        var descriptor: NSFontDescriptor = base.fontDescriptor
        if serif, let serifed = descriptor.withDesign(.serif) { descriptor = serifed }
        if italic {
            descriptor = descriptor.withSymbolicTraits(descriptor.symbolicTraits.union(.italic))
        }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }
    #endif
}

// MARK: - Highlights into a note (D433, D434)
//
// **Each document can have a note of its own**, separate from `linked_note`
// (which links the document to a PROJECT note shared by every document in that
// project, and drives project filtering — repointing it would have broken that)
// and separate from the endeavor. David's rail-schedule case is the test: the
// endeavor stays Japan, the project link stays as it was, and the trains he
// highlighted land in the schedule's own note.
//
// These notes live in their own **Reading** group so a month of articles does
// not crowd the project list.
//
// **Only what has not been sent goes, and nothing already written is touched**
// (D434). The note is his: the reader appends to it and never rewrites it.

enum SatchelHighlightNote {

    static let folder = "Notes/Reading"

    private static let dayFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMMM d"
        return fmt
    }()

    /// Where a document's own note goes when it is first made. The title,
    /// stripped of anything a filename cannot carry.
    static func path(forTitle title: String) -> String {
        var name: String = title.trimmingCharacters(in: .whitespacesAndNewlines)
        for bad in ["/", "\\", ":", "*", "?", "\"", "<", ">", "|", "#", "^", "[", "]"] {
            name = name.replacingOccurrences(of: bad, with: " ")
        }
        name = name.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if name.count > 80 { name = String(name.prefix(80)).trimmingCharacters(in: .whitespaces) }
        if name.isEmpty { name = "Reading note" }
        return "\(folder)/\(name).md"
    }

    /// The name shown on a button: "Rail schedule", not the path.
    static func name(of path: String) -> String {
        let file: String = (path as NSString).lastPathComponent
        return (file as NSString).deletingPathExtension
    }

    /// What gets appended for one send.
    ///
    /// The first send carries the article's own line — title, where it came
    /// from, and its address — so the note stands on its own months later. Every
    /// send after that is headed by its date, which is what makes a second press
    /// read as an addition rather than a repeat.
    static func block(for highlights: [SatchelHighlight],
                      title: String,
                      site: String,
                      address: String,
                      firstSend: Bool,
                      /// True when the note already had something in it, so this
                      /// article needs a heading of its own to sit under.
                      intoExistingNote: Bool,
                      on date: Date) -> String {
        var out: String = ""
        if firstSend {
            // **The heading only when the note already exists** (D443). A note
            // made by this very send opens with `# Title`, and writing `## Title`
            // under it printed the article's name twice, one line apart, which is
            // what David's first real note did.
            if intoExistingNote { out += "## \(title)\n" }
            var line: [String] = []
            if !site.isEmpty { line.append(site) }
            line.append(dayFormatter.string(from: date))
            out += line.joined(separator: " · ") + "\n"
            if !address.isEmpty { out += address + "\n" }
        } else {
            out += "**Added \(dayFormatter.string(from: date))**\n"
        }
        for highlight in highlights.sorted(by: { $0.block < $1.block }) {
            out += "\n> \(highlight.text)\n"
            if !highlight.line.isEmpty {
                out += "\n\(highlight.line)\n"
            }
        }
        return out
    }

    /// Whether a note is already there with something in it.
    static func exists(at path: String) -> Bool {
        let raw: String = (try? NoteStore.shared.readFile(path)) ?? ""
        return !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Appends `block` to the note at `path`, making the note if it is not there
    /// yet. Returns false only when the write itself failed.
    ///
    /// **Append, never rewrite.** Anything he has typed, edited or deleted in
    /// this note stays exactly as he left it (D434).
    @discardableResult
    static func append(_ block: String, to path: String, title: String) -> Bool {
        let store = NoteStore.shared
        let existing: String = (try? store.readFile(path)) ?? ""
        var content: String
        if existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            content = "# \(title)\n\n" + block
        } else {
            let separator: String = existing.hasSuffix("\n") ? "\n" : "\n\n"
            content = existing + separator + block
        }
        do {
            try store.writeFile(path, content: content)
            return true
        } catch {
            return false
        }
    }
}

// MARK: - The article's Highlights list (D435)
//
// Everything he marked in ONE article, in reading order, each row saying
// whether it has reached the note. Three jobs, in the order they come up:
//
// 1. **Jumping.** Tap a row and the article scrolls to that passage. In a long
//    piece that beats hunting for yellow.
// 2. **Tidying.** Add a line or remove a highlight without finding it in the
//    text first — the stray one-character highlight in David's first real note
//    would have been one swipe here.
// 3. **Seeing what is unsent** before pressing Send, rather than trusting the
//    number on the button.
//
// **Not a list across all articles.** That was left out of v1 deliberately: the
// Reading notes already collect everything that has been sent, and a second
// screen showing the same passages would mostly repeat them.
//
// One view for both machines. The phone shows it as a sheet with swipes; the
// Mac shows the same list in a panel, where the same actions are on a
// right-click, because a Mac list has no swipe.

struct SatchelHighlightsList: View {
    let highlights: [SatchelHighlight]
    /// Drawn in the article's own ink so the list belongs to the reader it was
    /// opened from rather than to the system.
    let colors: SatchelArticleInk
    var onJump: (SatchelHighlight) -> Void
    var onAddLine: (SatchelHighlight) -> Void
    var onRemove: (SatchelHighlight) -> Void
    var onSend: () -> Void
    var onClose: () -> Void

    private var unsent: Int { highlights.filter { $0.sent == nil }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if highlights.isEmpty {
                empty
            } else {
                list
            }
            if unsent > 0 {
                Divider()
                sendRow
            }
        }
        .frame(minWidth: 320, minHeight: 260)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Highlights")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(colors.ink)
            Spacer()
            Text(countLine)
                .font(.system(size: 12))
                .foregroundStyle(colors.secondary)
            Button("Done", action: onClose)
                .font(.system(size: 13, weight: .semibold))
                .buttonStyle(.plain)
                .foregroundStyle(colors.accent)
                .padding(.leading, 10)
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var countLine: String {
        let total: Int = highlights.count
        let word: String = total == 1 ? "highlight" : "highlights"
        return unsent > 0 ? "\(total) \(word) · \(unsent) not sent" : "\(total) \(word)"
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "highlighter")
                .font(.system(size: 26, weight: .thin))
                .foregroundStyle(colors.faint)
            Text("Nothing marked in this one yet.")
                .font(.system(size: 13))
                .foregroundStyle(colors.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 40)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(highlights) { highlight in
                    row(highlight)
                    Divider().padding(.leading, 18)
                }
            }
        }
    }

    private func row(_ highlight: SatchelHighlight) -> some View {
        Button {
            onJump(highlight)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(highlight.text)
                    .font(.system(size: 14.5))
                    .foregroundStyle(colors.ink)
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if !highlight.line.isEmpty {
                    Text(highlight.line)
                        .font(.system(size: 12.5).italic())
                        .foregroundStyle(colors.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(highlight.isSent ? "Sent" : "Not sent")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(highlight.isSent ? colors.faint : colors.accent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // **A press-and-hold, not a swipe.** `swipeActions` only works inside a
        // `List`, and this is a plain stack so the rows can be drawn in the
        // article's own ink rather than the system's. A long press on the phone
        // and a right-click on the Mac open the same menu, which also means one
        // set of actions to keep correct instead of two.
        .contextMenu { actions(highlight) }
    }

    @ViewBuilder
    private func actions(_ highlight: SatchelHighlight) -> some View {
        Button {
            onAddLine(highlight)
        } label: {
            Label(highlight.line.isEmpty ? "Add a line…" : "Edit the line…",
                  systemImage: "text.alignleft")
        }
        Button(role: .destructive) {
            onRemove(highlight)
        } label: {
            Label("Remove highlight", systemImage: "trash")
        }
    }

    private var sendRow: some View {
        Button(action: onSend) {
            Label(unsent == 1 ? "Send 1 highlight to note"
                              : "Send \(unsent) highlights to note",
                  systemImage: "highlighter")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(colors.ink)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(colors.highlight,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }
}

// MARK: - Highlights in a PDF (D437's Build 2)
//
// **The same passage, the same note, a different drawing surface.** A PDF has
// no blocks, so the page number takes the block's place in the stored entry and
// everything else — the words, his line, the sent date, the note the send
// appends to — is what it already was. One format, two kinds of document.
//
// **The file is never written to.** The yellow is a PDFKit annotation added to
// the document in memory each time it is opened, so a copy he mails is the
// original he was sent. The cost, told to him in D437: the highlights show in
// Satchel and TraceMac and nowhere else.
//
// **Two real limits, also told to him.** A scanned PDF has no text to select,
// so nothing can be highlighted in one; and dragging across a table row can
// catch a neighbouring column, because the page's own text order is what
// PDFKit has to work with.

enum SatchelPDFHighlights {

    /// Marks this app's own annotations, so a redraw can clear exactly what it
    /// drew and leave anything the file itself carries alone.
    private static let stamp = "satchel-highlight"

    /// Draws every highlight it can place, and removes any it drew before.
    ///
    /// Placement matches the article's rule (D431): the stored page first, then
    /// every page, matching on the words. A passage whose words are no longer in
    /// the file is simply not drawn; it keeps its place in the list and in the
    /// note.
    ///
    /// **Pass the view that shows the document** (D459). Adding an annotation
    /// to a page does not make `PDFView` repaint it; removing one does. So the
    /// first highlight on a page sat invisible until the second one arrived and
    /// the clear-then-draw repainted both. `annotationsChanged(on:)` is the
    /// call PDFKit provides for exactly this, once per page touched.
    ///
    /// Answers with how many marks it put on pages (D463), so a caller can tell
    /// a paint that landed from one that ran too early and drew nothing.
    @MainActor
    @discardableResult
    static func apply(_ highlights: [SatchelHighlight],
                      to document: PDFDocument,
                      color: PlatformColor,
                      in view: PDFView? = nil) -> Int {
        var touched: [PDFPage] = clear(from: document)
        var drawn = 0
        for highlight in highlights {
            guard let found = locate(highlight, in: document) else { continue }
            let page: PDFPage = found.page
            var drew = false
            for line in found.selection.selectionsByLine() {
                let bounds: CGRect = line.bounds(for: page)
                guard bounds.width > 1, bounds.height > 1 else { continue }
                let mark = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
                mark.color = color
                mark.contents = highlight.text
                mark.userName = stamp
                page.addAnnotation(mark)
                drew = true
                drawn += 1
            }
            if drew, !touched.contains(where: { $0 === page }) { touched.append(page) }
        }
        guard let view else { return drawn }
        for page in touched { view.annotationsChanged(on: page) }
        #if os(macOS)
        view.needsDisplay = true
        #else
        view.setNeedsDisplay()
        #endif
        return drawn
    }

    /// Takes off only what this app drew. Answers with the pages it touched, so
    /// the caller can tell the view about them.
    @MainActor
    @discardableResult
    static func clear(from document: PDFDocument) -> [PDFPage] {
        var touched: [PDFPage] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            var cleared = false
            for annotation in page.annotations where annotation.userName == stamp {
                page.removeAnnotation(annotation)
                cleared = true
            }
            if cleared { touched.append(page) }
        }
        return touched
    }

    /// The page a highlight sits on and the selection covering it.
    @MainActor
    private static func locate(_ highlight: SatchelHighlight,
                               in document: PDFDocument) -> (page: PDFPage, selection: PDFSelection)? {
        var order: [Int] = []
        if highlight.block >= 0 && highlight.block < document.pageCount { order.append(highlight.block) }
        for index in 0..<document.pageCount where index != highlight.block { order.append(index) }
        for index in order {
            guard let page = document.page(at: index), let text = page.string else { continue }
            guard let range = range(of: highlight.text, in: text),
                  let selection = page.selection(for: range) else { continue }
            return (page, selection)
        }
        return nil
    }

    /// Where `needle` sits in a page's own text, as a range in that text.
    ///
    /// **The passage was stored with its whitespace folded** (`passage(from:)`
    /// collapses line breaks and runs of spaces to one space, so it can match
    /// itself again), **but the page's text still carries every line break.**
    /// Searching the raw text for the folded passage found only a selection that
    /// sat inside one line; anything across a line end was saved, listed, sent,
    /// and never painted (D458). So the page's text is folded the same way here,
    /// with a map from each folded character back to where it came from, and the
    /// match is carried back through the map to the page's real characters.
    private static func range(of needle: String, in text: String) -> NSRange? {
        let source: NSString = text as NSString
        let count: Int = source.length
        var folded: [unichar] = []
        var origin: [Int] = []          // folded unit -> source unit
        folded.reserveCapacity(count)
        origin.reserveCapacity(count)
        var spacePending = false
        for index in 0..<count {
            let unit: unichar = source.character(at: index)
            let isSpace: Bool = UnicodeScalar(unit).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false
            if isSpace {
                spacePending = !folded.isEmpty
                continue
            }
            if spacePending {
                folded.append(0x20)
                origin.append(index)
                spacePending = false
            }
            folded.append(unit)
            origin.append(index)
        }
        guard !folded.isEmpty else { return nil }
        let haystack = NSString(characters: folded, length: folded.count)
        let hit: NSRange = haystack.range(of: needle)
        guard hit.location != NSNotFound, hit.length > 0 else { return nil }
        // The stored passage is trimmed, so a match never starts or ends on the
        // folded space; both ends map to a real character of the page.
        let start: Int = origin[hit.location]
        let end: Int = origin[hit.location + hit.length - 1] + 1
        return NSRange(location: start, length: end - start)
    }

    /// What a selection in the viewer amounts to: the page it starts on and the
    /// words themselves. `nil` when there is nothing worth keeping (D443).
    @MainActor
    static func passage(from selection: PDFSelection?,
                        in document: PDFDocument) -> (page: Int, text: String)? {
        guard let selection else { return nil }
        let raw: String = selection.string ?? ""
        // A selection that runs over a line break carries the break with it; the
        // article's own text has none, and a passage stored with one would never
        // match itself again.
        let text: String = raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard SatchelHighlightText.worthKeeping(text) else { return nil }
        var page: Int = 0
        if let first = selection.pages.first { page = document.index(for: first) }
        return (page, text)
    }

    /// The highlight under a point on a page, if there is one.
    @MainActor
    static func highlight(at point: CGPoint,
                          on page: PDFPage,
                          among highlights: [SatchelHighlight]) -> SatchelHighlight? {
        for annotation in page.annotations where annotation.userName == stamp {
            guard annotation.bounds.contains(point) else { continue }
            let text: String = annotation.contents ?? ""
            if let match = highlights.first(where: { $0.text == text }) { return match }
        }
        return nil
    }
}

#if os(iOS)
typealias PlatformColor = UIColor
#elseif os(macOS)
typealias PlatformColor = NSColor
#endif
