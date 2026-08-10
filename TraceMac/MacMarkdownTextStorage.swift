// MacMarkdownTextStorage.swift
// AppKit port of MarkdownTextStorage for the Mac note editor.
// Mac-only — do not add to iOS, Widget, or Share Extension targets.

import AppKit

// MARK: - Mac attribute keys

extension NSAttributedString.Key {
    /// Bool — true = checked, false = unchecked. Set on the ☐/☑ character.
    static let macCheckboxState = NSAttributedString.Key("com.david.trace.mac.checkboxState")
    /// String — inner name of a [[wikilink]] span.
    static let macWikiTarget    = NSAttributedString.Key("com.david.trace.mac.wikiTarget")
    /// String — container-relative path of a `!![desc](path)` thumbnail line.
    /// Set on the WHOLE line, so a click anywhere on the picture finds it.
    static let macImagePath     = NSAttributedString.Key("com.david.trace.mac.imagePath")
}

// MARK: - MacMarkdownTextStorage

final class MacMarkdownTextStorage: NSTextStorage {

    private let backing = NSMutableAttributedString()

    /// Lowercased titles of the notes a `[[wikilink]]` may open — Projects and
    /// Daily, per D49. Set by `MacTextEditor.updateNSView`; empty until then,
    /// which simply means every wikilink paints as a record link, the behaviour
    /// this file had before D64.
    ///
    /// **This is the only thing the storage knows about the outside world.** It
    /// had exactly one stored property before, and adding a whole `NoteStore`
    /// reference to answer a colour question would have been the wrong trade —
    /// a set of strings the owner refreshes is the smallest thing that works.
    var noteTitles: Set<String> = []

    // MARK: Style constants

    static let bodySize: CGFloat  = 15
    static let bodyFont           = NSFont.systemFont(ofSize: bodySize)
    static let boldFont           = NSFont.systemFont(ofSize: bodySize, weight: .semibold)
    static let italicFont: NSFont = {
        let desc = NSFont.systemFont(ofSize: bodySize).fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: desc, size: bodySize) ?? NSFont.systemFont(ofSize: bodySize)
    }()
    /// Near-zero font — makes a glyph invisible AND essentially zero-width, matching the iOS approach.
    static let hiddenFont         = NSFont.systemFont(ofSize: 0.01)

    static let textColor     = NSColor.labelColor
    static let dimColor      = NSColor.tertiaryLabelColor
    static let linkColor     = NSColor.linkColor
    /// Notes get their own colour. David, on D49: *"A different color maybe is
    /// good."* They do a different thing — a person or place link opens a record
    /// card, a note link opens a document — and one colour for both made the
    /// destination unguessable until you clicked.
    static let noteLinkColor = NSColor.systemPurple
    static let checkGreen    = NSColor.systemGreen
    static let uncheckOrange = NSColor(red: 0.9, green: 0.5, blue: 0.1, alpha: 1)

    static var baseParagraphStyle: NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = 1.4
        return p
    }

    // MARK: Required NSTextStorage overrides

    override var string: String { backing.string }

    override func attributes(at location: Int,
                             effectiveRange range: NSRangePointer?) -> [NSAttributedString.Key: Any] {
        backing.attributes(at: location, effectiveRange: range)
    }

    override func replaceCharacters(in range: NSRange, with str: String) {
        beginEditing()
        backing.replaceCharacters(in: range, with: str)
        edited(.editedCharacters, range: range,
               changeInLength: (str as NSString).length - range.length)
        endEditing()
    }

    override func setAttributes(_ attrs: [NSAttributedString.Key: Any]?, range: NSRange) {
        beginEditing()
        backing.setAttributes(attrs, range: range)
        edited(.editedAttributes, range: range, changeInLength: 0)
        endEditing()
    }

    // MARK: processEditing — DELIBERATELY NOT OVERRIDDEN
    //
    // This class used to override `processEditing()` to call `applyStyles()` and
    // then re-issue `edited(.editedAttributes, range:…)`. **That override was
    // the cause of every editor bug in Session 65**, and it must not come back.
    //
    // ── Why, in one paragraph ─────────────────────────────────────────────
    //
    // `NSTextStorage` MERGES edit notifications. The user's keystroke produces
    // an `.editedCharacters` notification over a small range; styling inside
    // `processEditing` then produces an `.editedAttributes` notification over a
    // much larger one. The storage coalesces them into a single notification
    // carrying the UNION of both ranges and BOTH masks, so the layout manager
    // receives one callback with `.editedCharacters` set for the expanded range
    // and runs its selection-fixing across all of it. **The caret is moved to
    // the end of the union of what you typed and what was restyled.**
    //
    // Christian Tietze documented this in 2017 and it is unchanged:
    // https://christiantietze.de/posts/2017/11/syntax-highlight-nstextstorage-insertion-point-change/
    //
    // ── It accounts for every symptom, which is how it was confirmed ──────
    //
    //   announce the whole document  → caret jumps to the end of the note
    //   announce the paragraph       → caret jumps to the next row, because a
    //                                  paragraph range includes its newline
    //   type on the LAST line        → nothing visible, because the union ends
    //                                  at the end of the document. This is why
    //                                  David reported it as a first-row bug and
    //                                  why it survived weeks: appending at the
    //                                  bottom of a note is the one safe case.
    //   hold down Return             → *"the cursor is faster than the words
    //                                  below it"*
    //   stale `☐`, then `Ŵ`, then    → the flip side: attributes rewritten on
    //   nothing at all                 lines the framework was never told about
    //
    // Eight fixes were attempted in one evening, every one of them a different
    // RANGE for that same call. There is no correct range. See D43–D48.
    //
    // ── The fix ───────────────────────────────────────────────────────────
    //
    // Styling now runs from `MacTextEditor.Coordinator.textDidChange`, outside
    // the edit cycle, inside `applyStyles`' own `beginEditing()`/`endEditing()`.
    // Two separate passes occur, the styling pass carries `.editedAttributes`
    // alone, and selection-fixing therefore only ever applies to the real
    // character change.
    //
    // Everything that was bolted on to work around this is gone with it: the
    // `expectedCaret` restore in the coordinator, the paragraph-scoped restyle,
    // and every `invalidateGlyphs` / `invalidateLayout` / `invalidateDisplay`.

    // MARK: Full styling pass

    /// Restyles the whole document and announces it as an attribute-only edit.
    ///
    /// **Called from `textDidChange`, never from `processEditing`** — see the
    /// long note above. Outside the edit cycle the `.editedAttributes` edit
    /// below is its own notification rather than being merged into the user's
    /// `.editedCharacters` one, so it cannot move the caret.
    ///
    /// `beginEditing()`/`endEditing()` batches the whole pass into one layout
    /// update instead of one per line.
    ///
    /// Whole-document rather than the edited paragraph, and that is now a
    /// choice rather than a compromise. Session 65 scoped it to the paragraph to
    /// stop lines outside the announced range going stale; with the announcement
    /// fixed, the scoping is unnecessary and full-document is what it was for
    /// months before. Notes are small. If that ever stops being true, scoping is
    /// a safe optimisation — but announce exactly what you restyle.
    func applyStyles() {
        guard backing.length > 0 else { return }
        let full = NSRange(location: 0, length: backing.length)
        beginEditing()
        backing.setAttributes([
            .font:           Self.bodyFont,
            .foregroundColor: Self.textColor,
            .paragraphStyle: Self.baseParagraphStyle
        ], range: full)
        (backing.string as NSString).enumerateSubstrings(
            in: full, options: .byLines
        ) { [weak self] sub, subRange, _, _ in
            guard let self, let line = sub else { return }
            self.styleLine(line, in: subRange)
        }
        // Attributes only. `applyStyles` never changes characters, so
        // `changeInLength` is always 0 — and because this runs outside the edit
        // cycle, this mask is not coalesced with an `.editedCharacters` one.
        edited(.editedAttributes, range: full, changeInLength: 0)
        endEditing()
    }

    // MARK: Per-line styling

    private func styleLine(_ line: String, in range: NSRange) {
        // Horizontal rule — hide `---` text and reserve a 24pt slot.
        // The coordinator (MacTextEditor.Coordinator.refreshHorizontalRules) overlays
        // a thin NSView separator centered in that slot, identical to the iOS UIView approach.
        if line.trimmingCharacters(in: .whitespacesAndNewlines) == "---" {
            let hrPara = NSMutableParagraphStyle()
            hrPara.minimumLineHeight = 24
            hrPara.maximumLineHeight = 24
            backing.addAttributes([
                .font:            Self.hiddenFont,
                .foregroundColor: NSColor.clear,
                .paragraphStyle:  hrPara
            ], range: range)
            return
        }
        // Thumbnail image line — `!![desc](path)`.
        //
        // Session 65. `grep NSTextAttachment` across TraceMac returned nothing
        // before this: inline photos did not exist in the Endeavor pane and did
        // not exist in the Daily editor either, so this is a Mac gap rather than
        // an Endeavor one. David asked for it twice.
        //
        // **Checked before headings and before everything inline.** The line is
        // hidden whole and given a fixed 200pt height, and any styler that ran
        // after it would paint attributes onto glyphs that must stay invisible.
        // `---` is checked first for the same reason and by the same shape.
        //
        // Not an `NSTextAttachment`, which is the obvious AppKit answer and the
        // wrong one here: an attachment is a character in the run, so it inherits
        // the line's paragraph style and fights the editor over selection,
        // deletion and copy. iOS reserves the space and overlays a view instead,
        // and `refreshHorizontalRules` in this app's own coordinator already
        // proves the pattern on the Mac.
        if line.hasPrefix("!![") { styleThumbnail(line, in: range); return }
        // Headings
        if line.hasPrefix("### ") { styleHeading(line, in: range, level: 3); return }
        if line.hasPrefix("## ")  { styleHeading(line, in: range, level: 2); return }
        if line.hasPrefix("# ")   { styleHeading(line, in: range, level: 1); return }
        // Blockquote — the day-subtitle override (D4).
        //
        // Styled so the marker reads as a control rather than punctuation: the
        // `>` dimmed to tertiary and the text in indigo, matching the `❯` the
        // day column draws for the same line. Not hidden, because hiding a
        // character the user typed means backspacing over something invisible.
        if line.hasPrefix(">") { styleBlockquote(line, in: range); return }
        // Checkboxes
        if line.hasPrefix("☑ ") { styleCheckbox(checked: true,  line: line, in: range); return }
        if line.hasPrefix("☐ ") { styleCheckbox(checked: false, line: line, in: range); return }
        // Bullet prefix dim
        styleBulletIfNeeded(line, in: range)
        // Inline styles
        applyBold(in: line, lineRange: range)
        applyItalic(in: line, lineRange: range)
        applyStrike(in: line, lineRange: range)
        applyHighlight(in: line, lineRange: range)
        applyHashtags(in: line, lineRange: range)
        applyLinks(in: line, lineRange: range)
        applyMarkdownLinks(in: line, lineRange: range)
        applyWikilinks(in: line, lineRange: range)
    }

    // MARK: Thumbnail image line

    /// Hides the whole `!![desc](path)` line, reserves 200pt for it, and tags
    /// the range with the path so the coordinator can find it and a click can
    /// resolve it.
    ///
    /// Kept deliberately in step with iOS `MarkdownTextStorage
    /// .applyThumbnailImageLinks` — same pattern, same 200pt, same
    /// hidden-font-plus-clear-colour. These are two renderers of one on-disk
    /// format, so a change to one that is not made to the other shows up as a
    /// note that renders on the phone and not on the Mac.
    private func styleThumbnail(_ line: String, in range: NSRange) {
        guard let regex = try? NSRegularExpression(
                  pattern: #"^!!\[([^\]]*)\]\(([^)]+)\)"#),
              let match = regex.firstMatch(
                  in: line, range: NSRange(location: 0, length: (line as NSString).length)),
              match.numberOfRanges >= 3,
              match.range(at: 2).location != NSNotFound else { return }

        let path = (line as NSString).substring(with: match.range(at: 2))

        let para = NSMutableParagraphStyle()
        para.minimumLineHeight = 200
        para.maximumLineHeight = 200

        backing.addAttributes([
            .font:            Self.hiddenFont,
            .foregroundColor: NSColor.clear,
            .paragraphStyle:  para,
            .macImagePath:    path
        ], range: range)
    }

    // MARK: Heading

    private func styleHeading(_ line: String, in range: NSRange, level: Int) {
        let markerLen = level + 1   // "# " = 2, "## " = 3, "### " = 4
        guard range.length >= markerLen else { return }
        // Hide the # markers entirely — same pattern as ** and * markers
        let markerRange = NSRange(location: range.location, length: markerLen)
        backing.addAttribute(.font,            value: Self.hiddenFont,  range: markerRange)
        backing.addAttribute(.foregroundColor, value: NSColor.clear, range: markerRange)
        let textLen = range.length - markerLen
        guard textLen > 0 else { return }
        let size: CGFloat = level == 1 ? 22 : (level == 2 ? 19 : 17)
        let headRange = NSRange(location: range.location + markerLen, length: textLen)
        backing.addAttribute(.font, value: NSFont.systemFont(ofSize: size, weight: .semibold),
                             range: headRange)
        // Allow bold + wikilinks inside headings
        let headText = String(line.dropFirst(markerLen))
        applyBold(in: headText, lineRange: headRange)
        applyWikilinks(in: headText, lineRange: headRange)
    }

    // MARK: Bullet prefix

    private func styleBulletIfNeeded(_ line: String, in range: NSRange) {
        let bullet = "\u{2022}"
        guard let bulletIdx = line.range(of: bullet + " ") else { return }
        let offset = line.utf16.distance(from: line.utf16.startIndex, to: bulletIdx.lowerBound)
        let nsOffset = range.location + offset
        guard nsOffset + 2 <= range.location + range.length else { return }
        // Dim the bullet glyph + trailing space
        backing.addAttribute(.foregroundColor, value: Self.dimColor,
                             range: NSRange(location: nsOffset, length: 2))
        // Hanging indent for indented bullets so continuation lines align with content
        if offset > 0 {
            let prefixStr = (line as NSString).substring(to: offset + 2)  // indent + "• "
            let prefixWidth = (prefixStr as NSString).size(
                withAttributes: [.font: Self.bodyFont]).width
            let para = NSMutableParagraphStyle()
            para.lineHeightMultiple = 1.4
            para.headIndent = prefixWidth
            backing.addAttribute(.paragraphStyle, value: para, range: range)
        }
    }

    // MARK: Checkbox

    /// The `>` override line. See `styleLine`.
    private func styleBlockquote(_ line: String, in range: NSRange) {
        backing.addAttribute(.foregroundColor, value: NSColor.systemIndigo, range: range)
        // Just the marker, dimmed. `>` alone on a line has no text after it.
        let markerLen = min(1, range.length)
        if markerLen > 0 {
            backing.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor,
                                 range: NSRange(location: range.location, length: markerLen))
        }
    }

    private func styleCheckbox(checked: Bool, line: String, in range: NSRange) {
        guard range.length >= 2 else { return }
        // Hanging indent: checkbox glyph + space = ~22pt, continuation lines align with text
        let checkboxIndent: CGFloat = 22
        let para = NSMutableParagraphStyle()
        para.lineHeightMultiple = 1.4
        para.firstLineHeadIndent = 0
        para.headIndent = checkboxIndent
        backing.addAttribute(.paragraphStyle, value: para, range: range)
        // Color the ☐/☑ glyph and tag it for click detection
        backing.addAttributes([
            .foregroundColor: checked ? Self.checkGreen : Self.uncheckOrange,
            .macCheckboxState: checked
        ], range: NSRange(location: range.location, length: 1))
        guard range.length > 2 else { return }
        let textRange = NSRange(location: range.location + 2, length: range.length - 2)
        if checked {
            backing.addAttributes([
                .foregroundColor: Self.dimColor,
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .strikethroughColor: Self.dimColor
            ], range: textRange)
        }
        // Hashtags and wikilinks inside checkbox text
        let textLine = String(line.dropFirst(2))
        applyHashtags(in: textLine, lineRange: textRange)
        applyWikilinks(in: textLine, lineRange: textRange)
    }

    // MARK: Bold — **text**

    private func applyBold(in line: String, lineRange: NSRange) {
        guard line.contains("**"),
              let regex = try? NSRegularExpression(pattern: #"\*\*(.+?)\*\*"#) else { return }
        let ns = line as NSString
        let hidden: [NSAttributedString.Key: Any] = [.font: Self.hiddenFont, .foregroundColor: NSColor.clear]
        for m in regex.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            guard m.range.length >= 5 else { continue }
            let base = lineRange.location + m.range.location
            let len  = m.range.length
            backing.addAttributes(hidden, range: NSRange(location: base, length: 2))
            backing.addAttribute(.font, value: Self.boldFont,
                                 range: NSRange(location: base + 2, length: len - 4))
            backing.addAttributes(hidden, range: NSRange(location: base + len - 2, length: 2))
        }
    }

    // MARK: Italic — *text*

    private func applyItalic(in line: String, lineRange: NSRange) {
        guard line.contains("*"),
              let regex = try? NSRegularExpression(
                  pattern: #"(?<!\*)\*([^*\n]+)\*(?!\*)"#) else { return }
        let ns = line as NSString
        let hidden: [NSAttributedString.Key: Any] = [.font: Self.hiddenFont, .foregroundColor: NSColor.clear]
        for m in regex.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            guard m.range.length >= 3 else { continue }
            let base = lineRange.location + m.range.location
            let len  = m.range.length
            backing.addAttributes(hidden, range: NSRange(location: base, length: 1))
            backing.addAttribute(.font, value: Self.italicFont,
                                 range: NSRange(location: base + 1, length: len - 2))
            backing.addAttributes(hidden, range: NSRange(location: base + len - 1, length: 1))
        }
    }

    // MARK: Strikethrough — ~~text~~

    private func applyStrike(in line: String, lineRange: NSRange) {
        guard line.contains("~~"),
              let regex = try? NSRegularExpression(pattern: #"~~(.+?)~~"#) else { return }
        let ns = line as NSString
        let hidden: [NSAttributedString.Key: Any] = [.font: Self.hiddenFont, .foregroundColor: NSColor.clear]
        for m in regex.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            guard m.range.length >= 5 else { continue }
            let base = lineRange.location + m.range.location
            let len  = m.range.length
            backing.addAttributes(hidden, range: NSRange(location: base, length: 2))
            backing.addAttributes([
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .foregroundColor: Self.dimColor
            ], range: NSRange(location: base + 2, length: len - 4))
            backing.addAttributes(hidden, range: NSRange(location: base + len - 2, length: 2))
        }
    }

    // MARK: Highlight — ==text==

    private func applyHighlight(in line: String, lineRange: NSRange) {
        guard line.contains("=="),
              let regex = try? NSRegularExpression(pattern: "==(.+?)==") else { return }
        let ns = line as NSString
        let hidden: [NSAttributedString.Key: Any] = [.font: Self.hiddenFont, .foregroundColor: NSColor.clear]
        for m in regex.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            guard m.range.length >= 5 else { continue }
            let base = lineRange.location + m.range.location
            let len  = m.range.length
            backing.addAttributes(hidden, range: NSRange(location: base, length: 2))
            backing.addAttribute(.backgroundColor,
                                 value: NSColor.systemYellow.withAlphaComponent(0.35),
                                 range: NSRange(location: base + 2, length: len - 4))
            backing.addAttributes(hidden, range: NSRange(location: base + len - 2, length: 2))
        }
    }

    // MARK: Hashtags — #tag

    private static let hashtagRegex: NSRegularExpression? =
        try? NSRegularExpression(pattern: #"(?:^|(?<=\s))#([a-zA-Z][a-zA-Z0-9_]*)"#,
                                 options: .anchorsMatchLines)

    private func applyHashtags(in line: String, lineRange: NSRange) {
        guard line.contains("#"), let regex = Self.hashtagRegex else { return }
        let ns = line as NSString
        for m in regex.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            backing.addAttribute(.foregroundColor, value: NSColor.systemPurple,
                                 range: NSRange(location: lineRange.location + m.range.location,
                                                length: m.range.length))
        }
    }

    // MARK: URLs

    private func applyLinks(in line: String, lineRange: NSRange) {
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue) else { return }
        let ns = line as NSString
        for m in detector.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            guard let url = m.url else { continue }
            let r = NSRange(location: lineRange.location + m.range.location, length: m.range.length)
            backing.addAttributes([.link: url, .foregroundColor: Self.linkColor], range: r)
        }
    }

    // MARK: Markdown links — [label](url)

    private func applyMarkdownLinks(in line: String, lineRange: NSRange) {
        guard line.contains("["),
              let regex = try? NSRegularExpression(
                  pattern: #"(?<![!\[])\[([^\]]+)\]\(([^)]+)\)"#) else { return }
        let ns = line as NSString
        let hidden: [NSAttributedString.Key: Any] = [.font: Self.hiddenFont, .foregroundColor: NSColor.clear]
        for m in regex.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            guard m.numberOfRanges >= 3 else { continue }
            let labelRange = m.range(at: 1)
            let urlRange   = m.range(at: 2)
            guard labelRange.location != NSNotFound, urlRange.location != NSNotFound else { continue }
            let urlStr = ns.substring(with: urlRange)
            let base   = lineRange.location + m.range.location
            backing.addAttributes(hidden, range: NSRange(location: base, length: 1))
            let labelBase = lineRange.location + labelRange.location
            var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: Self.linkColor]
            if let url = URL(string: urlStr) { attrs[.link] = url }
            backing.addAttributes(attrs, range: NSRange(location: labelBase, length: labelRange.length))
            let afterLabel = lineRange.location + labelRange.location + labelRange.length
            let suffixLen  = (base + m.range.length) - afterLabel
            if suffixLen > 0 {
                backing.addAttributes(hidden, range: NSRange(location: afterLabel, length: suffixLen))
            }
        }
    }

    // MARK: Wikilinks — [[name]] and [[target|display]]
    //
    // ALIAS PARITY, 2026-08-01. Kept deliberately in step with the iOS
    // MarkdownTextStorage.applyWikilinks — see the long comment there for why the
    // alias form exists and why both forms share one span calculation. These are two
    // separate implementations of the same renderer (UIKit vs AppKit), so a change to
    // one that is not made to the other shows up as the Mac displaying raw
    // "Full Name|Short" text in a note the phone renders correctly.

    private func applyWikilinks(in line: String, lineRange: NSRange) {
        guard line.contains("[["),
              let regex = try? NSRegularExpression(
                  pattern: #"\[\[([^\]|]+)(?:\|([^\]]*))?\]\]"#) else { return }
        let ns = line as NSString
        let hidden: [NSAttributedString.Key: Any] = [.font: Self.hiddenFont, .foregroundColor: NSColor.clear]
        for m in regex.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            guard m.numberOfRanges >= 2, m.range.length >= 5 else { continue }
            let targetRange = m.range(at: 1)
            guard targetRange.location != NSNotFound, targetRange.length > 0 else { continue }
            let target = ns.substring(with: targetRange)

            // Visible span: the alias when there is a non-empty one, else the target.
            let aliasRange = m.numberOfRanges >= 3
                ? m.range(at: 2)
                : NSRange(location: NSNotFound, length: 0)
            let visible = (aliasRange.location != NSNotFound && aliasRange.length > 0)
                ? aliasRange
                : targetRange

            let matchStart = m.range.location
            let matchEnd   = m.range.location + m.range.length
            let visibleEnd = visible.location + visible.length

            // Hide `[[`, plus `target|` on an alias.
            let prefixLen = visible.location - matchStart
            if prefixLen > 0 {
                backing.addAttributes(hidden, range: NSRange(location: lineRange.location + matchStart,
                                                             length: prefixLen))
            }

            let visibleNsRange = NSRange(location: lineRange.location + visible.location,
                                         length: visible.length)
            backing.removeAttribute(.link, range: visibleNsRange)
            // Case-insensitive, to match how `.openWikilink` resolves a name.
            let isNote = noteTitles.contains(
                target.trimmingCharacters(in: .whitespaces).lowercased())
            backing.addAttributes([
                .foregroundColor: isNote ? Self.noteLinkColor : Self.linkColor,
                .macWikiTarget: target
            ], range: visibleNsRange)

            // Hide `]]`, plus any empty-alias remainder.
            let suffixLen = matchEnd - visibleEnd
            if suffixLen > 0 {
                let closeRange = NSRange(location: lineRange.location + visibleEnd, length: suffixLen)
                backing.removeAttribute(.link, range: closeRange)
                backing.addAttributes(hidden, range: closeRange)
            }
        }
    }
}
