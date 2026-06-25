import UIKit

// MARK: - MarkdownTextStorage
//
// NSTextStorage subclass that applies live markdown styling (TextKit 1).
// Supports: **bold**, - bullet lists, - [ ] / - [x] checkboxes,
// standard URLs, and custom URL schemes (x-devonthink-item://, obsidian://, etc.)
//
// Key pattern: applyStyles() modifies `backing` (NSMutableAttributedString) directly,
// never `self`, to avoid re-entrant processEditing calls.

final class MarkdownTextStorage: NSTextStorage {

    // MARK: - Backing store
    private let backing = NSMutableAttributedString()

    // MARK: - Style constants
    static let bodyFont     = UIFont.systemFont(ofSize: 16)
    static let boldFont     = UIFont.systemFont(ofSize: 16, weight: .semibold)
    static let checkboxFont = UIFont.monospacedSystemFont(ofSize: 15, weight: .regular)

    static let textColor:    UIColor = .label
    static let dimColor:     UIColor = .tertiaryLabel
    static let linkColor:    UIColor = .systemBlue
    static let checkColor:   UIColor = .systemGreen
    static let uncheckColor: UIColor = UIColor(red: 0.9, green: 0.5, blue: 0.1, alpha: 1)

    // MARK: - Required NSTextStorage overrides

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

    // MARK: - Process editing

    override func processEditing() {
        applyStyles()
        super.processEditing()
    }

    // MARK: - Full-document styling pass
    // Re-styles every line on each edit. Fine for note-sized documents (< 100 KB).

    func applyStyles() {
        guard backing.length > 0 else { return }
        let full = NSRange(location: 0, length: backing.length)

        // Reset to base
        backing.setAttributes([
            .font: Self.bodyFont,
            .foregroundColor: Self.textColor
        ], range: full)

        (backing.string as NSString).enumerateSubstrings(
            in: full, options: .byLines
        ) { [weak self] sub, subRange, _, _ in
            guard let self, let line = sub else { return }
            self.styleLine(line, in: subRange)
        }
    }

    // MARK: - Per-line styling

    private func styleLine(_ line: String, in range: NSRange) {
        // Checkboxes must be checked before generic bullets
        if line.hasPrefix("- [x]") { styleCheckbox(checked: true,  line: line, in: range); return }
        if line.hasPrefix("- [ ]") { styleCheckbox(checked: false, line: line, in: range); return }
        if line.hasPrefix("- ")   { styleBulletPrefix(in: range) }
        applyBold(in: line, lineRange: range)
        applyLinks(in: line, lineRange: range)
    }

    // MARK: Bullet prefix

    private func styleBulletPrefix(in range: NSRange) {
        guard range.length >= 2 else { return }
        backing.addAttribute(.foregroundColor, value: Self.dimColor,
                             range: NSRange(location: range.location, length: 2))
    }

    // MARK: Checkbox

    private func styleCheckbox(checked: Bool, line: String, in range: NSRange) {
        // "- [ ] " or "- [x] " = 6 chars
        let prefixLen = min(6, range.length)
        let prefixRange = NSRange(location: range.location, length: prefixLen)
        let color = checked ? Self.checkColor : Self.uncheckColor

        backing.addAttributes([
            .foregroundColor: color,
            .font: Self.checkboxFont
        ], range: prefixRange)

        let textStart = range.location + prefixLen
        let textLen   = range.length - prefixLen
        guard textLen > 0 else { return }
        let textRange = NSRange(location: textStart, length: textLen)

        if checked {
            backing.addAttributes([
                .foregroundColor: Self.dimColor,
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .strikethroughColor: Self.dimColor
            ], range: textRange)
        }
    }

    // MARK: Bold — **text**

    private func applyBold(in line: String, lineRange: NSRange) {
        guard line.contains("**"),
              let regex = try? NSRegularExpression(pattern: #"\*\*(.+?)\*\*"#) else { return }
        let ns = line as NSString
        for m in regex.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            guard m.range.length >= 5 else { continue }
            let base = lineRange.location + m.range.location
            let len  = m.range.length
            // Dim the ** markers
            backing.addAttribute(.foregroundColor, value: Self.dimColor,
                                 range: NSRange(location: base, length: 2))
            // Bold the inner text
            backing.addAttribute(.font, value: Self.boldFont,
                                 range: NSRange(location: base + 2, length: len - 4))
            backing.addAttribute(.foregroundColor, value: Self.dimColor,
                                 range: NSRange(location: base + len - 2, length: 2))
        }
    }

    // MARK: Links

    private static let customPattern =
        "(x-devonthink-item|obsidian|things|noteplan|bear|drafts)://\\S+"

    private func applyLinks(in line: String, lineRange: NSRange) {
        let ns = line as NSString
        let lineLen = NSRange(location: 0, length: ns.length)

        // Standard URLs (http/https/etc.)
        if let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue
        ) {
            for m in detector.matches(in: line, range: lineLen) {
                guard let url = m.url else { continue }
                let r = NSRange(location: lineRange.location + m.range.location,
                                length: m.range.length)
                backing.addAttributes([.link: url, .foregroundColor: Self.linkColor], range: r)
            }
        }

        // Custom URL schemes
        if let regex = try? NSRegularExpression(
            pattern: Self.customPattern, options: .caseInsensitive
        ) {
            for m in regex.matches(in: line, range: lineLen) {
                let substr = ns.substring(with: m.range)
                guard let url = URL(string: substr) else { continue }
                let r = NSRange(location: lineRange.location + m.range.location,
                                length: m.range.length)
                backing.addAttributes([.link: url, .foregroundColor: Self.linkColor], range: r)
            }
        }
    }
}
