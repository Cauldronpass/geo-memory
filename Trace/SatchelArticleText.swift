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

    private var design: Font.Design { serif ? .serif : .default }
    private var bodySize: CGFloat { CGFloat(size) }
    private var lineGap: CGFloat { SatchelArticleLayout.lineGap(size: size, spacing: spacing) }
    private var bodyFont: Font { .system(size: bodySize, weight: .regular, design: design) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { item in
                block(item.element)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func block(_ block: SatchelArticleText.Block) -> some View {
        switch block {
        case .paragraph(let text):
            paragraph(text)
        case .heading(let text):
            heading(text)
        case .quote(let text):
            quote(text)
        case .bullet(let text):
            listItem(marker: "\u{2022}", text: text)
        case .numbered(let marker, let text):
            listItem(marker: marker, text: text)
        case .image(let url, let caption):
            SatchelArticlePhoto(url: url, caption: caption, colors: colors,
                                gap: bodySize, bleed: photoBleed)
        }
    }

    private func paragraph(_ text: String) -> some View {
        Text(text)
            .font(bodyFont)
            .foregroundStyle(colors.ink)
            .lineSpacing(lineGap)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, bodySize * 0.9)
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
    private func quote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: bodySize * 1.06, weight: .regular, design: design).italic())
            .foregroundStyle(colors.ink)
            .lineSpacing(lineGap)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 17)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(colors.accent)
                    .frame(width: 3)
            }
            .padding(.top, bodySize * 0.3)
            .padding(.bottom, bodySize * 1.0)
    }

    private func listItem(marker: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(marker)
                .font(bodyFont)
                .foregroundStyle(colors.secondary)
                .frame(minWidth: 16, alignment: .trailing)
            Text(text)
                .font(bodyFont)
                .foregroundStyle(colors.ink)
                .lineSpacing(lineGap)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 2)
        .padding(.bottom, bodySize * 0.45)
    }
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
