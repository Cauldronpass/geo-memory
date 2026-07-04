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
}

// MARK: - MacMarkdownTextStorage

final class MacMarkdownTextStorage: NSTextStorage {

    private let backing = NSMutableAttributedString()

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

    // MARK: processEditing

    override func processEditing() {
        if editedMask.contains(.editedCharacters) {
            applyStyles()
            let paraRange = (backing.string as NSString).paragraphRange(for: editedRange)
            edited(.editedAttributes, range: paraRange, changeInLength: 0)
        }
        super.processEditing()
    }

    // MARK: Full styling pass

    func applyStyles() {
        guard backing.length > 0 else { return }
        let full = NSRange(location: 0, length: backing.length)
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
        // Headings
        if line.hasPrefix("### ") { styleHeading(line, in: range, level: 3); return }
        if line.hasPrefix("## ")  { styleHeading(line, in: range, level: 2); return }
        if line.hasPrefix("# ")   { styleHeading(line, in: range, level: 1); return }
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

    // MARK: Wikilinks — [[name]]

    private func applyWikilinks(in line: String, lineRange: NSRange) {
        guard line.contains("[["),
              let regex = try? NSRegularExpression(pattern: #"\[\[([^\]]+)\]\]"#) else { return }
        let ns = line as NSString
        let hidden: [NSAttributedString.Key: Any] = [.font: Self.hiddenFont, .foregroundColor: NSColor.clear]
        for m in regex.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            guard m.numberOfRanges >= 2, m.range.length >= 5 else { continue }
            let nameRange = m.range(at: 1)
            guard nameRange.location != NSNotFound, nameRange.length > 0 else { continue }
            let name  = ns.substring(with: nameRange)
            let base  = lineRange.location + m.range.location
            let total = m.range.length
            backing.addAttributes(hidden, range: NSRange(location: base, length: 2))
            let nameBase = lineRange.location + nameRange.location
            backing.removeAttribute(.link, range: NSRange(location: nameBase, length: nameRange.length))
            backing.addAttributes([
                .foregroundColor: Self.linkColor,
                .macWikiTarget: name
            ], range: NSRange(location: nameBase, length: nameRange.length))
            let closeRange = NSRange(location: base + total - 2, length: 2)
            backing.removeAttribute(.link, range: closeRange)
            backing.addAttributes(hidden, range: closeRange)
        }
    }
}
