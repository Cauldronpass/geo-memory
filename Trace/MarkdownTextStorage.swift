import UIKit

// MARK: - BlockInfo
//
// Moved here from NotesView.swift (2026-07-19, Dayflow Session 1) — it's
// MarkdownEditorView's own long-press-block callback type
// (`onBlockLongPress: ((BlockInfo) -> Void)?`), so it belongs with the
// editor component, not with one particular Trace-side caller. Purely
// self-contained (Foundation only), so moving it doesn't change behavior for
// NotesView.swift, which still resolves it via the same Trace/TraceMac
// target membership as before. This unblocked Dayflow's target from having
// to compile all of NotesView.swift just to get one small struct.
struct BlockInfo: Identifiable {
    let id = UUID()
    let text: String
    let nsRange: NSRange

    /// First non-empty, non-timestamp content line — used as default title for promote.
    var firstLineTitle: String {
        let lines = text.components(separatedBy: "\n")
        for line in lines.dropFirst() {
            var t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { continue }
            // Strip leading markdown list/checkbox prefixes
            t = t.replacingOccurrences(of: "^[•\\-] ", with: "", options: .regularExpression)
            t = t.replacingOccurrences(of: "^- \\[.\\] ", with: "", options: .regularExpression)
            // Strip bold wrapper
            if t.hasPrefix("**") && t.hasSuffix("**") && t.count > 4 {
                t = String(t.dropFirst(2).dropLast(2))
            }
            return t.isEmpty ? "Note" : t
        }
        return "Note"
    }
}

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
    static let bodyFont = UIFont.systemFont(ofSize: 16)
    static let boldFont = UIFont.systemFont(ofSize: 16, weight: .semibold)

    static let textColor:    UIColor = .label
    static let dimColor:     UIColor = .tertiaryLabel
    static let linkColor:    UIColor = .systemBlue
    static let checkColor:   UIColor = .systemGreen
    static let uncheckColor: UIColor = UIColor(red: 0.9, green: 0.5, blue: 0.1, alpha: 1)
    // Tiny invisible font used to hide markdown syntax markers (**, *, ☐, ☑, etc.)
    static let hiddenFont:   UIFont  = UIFont.systemFont(ofSize: 0.1)
    // Same idea as hiddenFont (invisible: .clear color), but large enough that
    // TextKit's layout manager doesn't classify the glyph as "null." Used only for
    // the checkbox line's trailing hidden space — see styleCheckboxLine's comment
    // and MarkdownEditorView.refreshCheckboxOverlays for why this distinction
    // matters (found 2026-07-20, the "checkbox overlaps the row above when the
    // checklist item is still empty" bug).
    static let hiddenAnchorFont: UIFont = UIFont.systemFont(ofSize: 3)
    // Fixed row height for checkbox lines — see styleCheckboxLine's comment for
    // why a *multiplier* (lineHeightMultiple) isn't enough on its own (found
    // 2026-07-20, second pass at the checkbox-overlap bug). bodyFont.lineHeight
    // is the natural single-line height of real 16pt task text; × 1.4 matches the
    // same visual row height every other checklist/bullet line already uses.
    static let checkboxLineHeight: CGFloat = bodyFont.lineHeight * 1.4
    // Left indent reserved for the SF Symbol checkbox overlay (18pt icon + 4pt gap)
    static let checkboxIndent: CGFloat = 22

    // Base paragraph style — 1.4x line height for comfortable reading.
    // Any custom paragraph style (checkboxes, HR) must also set lineHeightMultiple
    // to avoid losing this spacing when it overrides the base.
    static var baseParagraphStyle: NSParagraphStyle {
        let para = NSMutableParagraphStyle()
        para.lineHeightMultiple = 1.4
        return para
    }

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

    // MARK: processEditing — DELIBERATELY NO LONGER RESTYLES
    //
    // This override used to call `applyStyles()` and then re-issue
    // `edited(.editedAttributes, range: paragraphRange…)`. **That is the bug the
    // Mac spent Session 65 on** (D50), ported here 2026-08-04. It is the standard
    // syntax-highlighter pattern and it is wrong for an editor with hidden
    // markers, for a reason that is a property of `NSTextStorage` rather than of
    // this code:
    //
    // `NSTextStorage` **merges** edit notifications. The `.editedAttributes` edit
    // issued from inside `processEditing` is coalesced with the user's own
    // `.editedCharacters` edit into ONE notification spanning the union of both
    // ranges. The layout manager then "fixes" the selection across all of it —
    // which is the caret jumping to the end of the note, or down a row, that
    // David reported for weeks. (Christian Tietze documented the mechanism in
    // 2017; see `TraceMac-Editor-Options.md`.)
    //
    // Eight different ranges were tried on the Mac before the range turned out to
    // be the wrong variable. **The fix is to style outside the edit cycle**, from
    // the delegate's `textViewDidChange`, where the attribute edit is its own
    // notification and cannot be merged into anything. See
    // `applyStylesForEdit()` below and `Coordinator.restyleAfterEdit(in:)`.
    //
    // **The fix is to style outside the edit cycle.** The Mac does that from its
    // delegate's `textDidChange`. iOS cannot: this editor has a dozen paths that
    // call `textStorage.replaceCharacters` directly and return false from
    // `shouldChangeTextIn`, so the delegate callback never fires for list
    // continuation, bullet conversion, timestamp insertion, badge appends or the
    // initial load. Driving styling from the delegate would have left every one
    // of those unstyled — a worse bug than the one being fixed.
    //
    // So the trigger stays here and only the *timing* moves: a hop to the next
    // runloop turn, at which point the edit cycle has finished and the
    // `.editedAttributes` notification is its own rather than merged into the
    // user's. Every mutation path still restyles, and none of them can drag the
    // caret with them.
    //
    // Coalesced on `restylePending`: fast typing must not queue one full pass per
    // character.
    override func processEditing() {
        if editedMask.contains(.editedCharacters), !restylePending {
            restylePending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.restylePending = false
                self.applyStylesForEdit()
            }
        }
        super.processEditing()
    }

    private var restylePending = false

    /// The text view this storage draws into, set once in `makeUIView`.
    ///
    /// Only used to force a repaint — see `applyStylesForEdit()`. Weak, and the
    /// storage works without it: no host means styling still happens and only the
    /// forced redraw is skipped.
    weak var hostTextView: UITextView?

    // MARK: - Full-document styling pass
    // Re-styles every line on each edit. Fine for note-sized documents (< 100 KB).

    func applyStyles() {
        guard backing.length > 0 else { return }
        let full = NSRange(location: 0, length: backing.length)

        // --- Snapshot fold state and sendTarget BEFORE attribute reset ---
        // Both are custom attributes that survive the setAttributes reset by being
        // snapshotted here and restored after the per-line styling pass.
        // NSAttributedString keeps attribute ranges aligned with their characters
        // as the string is edited, so character indices here are always current.
        var foldedCharIndices = Set<Int>()
        backing.enumerateAttribute(.foldState, in: full, options: []) { value, range, _ in
            if value as? Bool == true {
                foldedCharIndices.insert(range.location)
            }
        }
        var sendTargets = [Int: String]()   // character index of ☐ → "things" | "tweek"
        backing.enumerateAttribute(.sendTarget, in: full, options: []) { value, range, _ in
            if let target = value as? String {
                sendTargets[range.location] = target
            }
        }

        // Reset to base — includes 1.4x line height for comfortable reading
        backing.setAttributes([
            .font: Self.bodyFont,
            .foregroundColor: Self.textColor,
            .paragraphStyle: Self.baseParagraphStyle
        ], range: full)

        // Collect per-line metadata while running the normal styling pass.
        // We need the full line list afterward to identify child ranges for folding.
        //
        // TWO ranges per line:
        //   subRange      — content only, NO trailing newline (what enumerateSubstrings gives)
        //   enclosingRange — content + trailing newline / line terminator
        //
        // CRITICAL: fold-hiding paragraph style MUST be applied to enclosingRange, not subRange.
        // NSTextStorage.processEditing() calls fixParagraphStyleAttribute() which inspects the
        // paragraph terminator (\n). If \n retains baseParagraphStyle (from the reset), fix-attrs
        // overwrites the whole child paragraph back to baseParagraphStyle — erasing hidePara and
        // making the fold invisible. Applying hidePara to enclosingRange (so \n also has hidePara)
        // causes fix-attrs to extend hidePara instead, keeping the 1pt line height. This is the
        // root cause of "folding does nothing" and was confirmed by seeing setAttributes() above
        // get called via fixParagraphStyleAttribute during super.processEditing().
        struct LineInfo {
            let range: NSRange          // subRange (content only, no \n) — used for styleLine
            let enclosingRange: NSRange // full range incl. \n — used for fold-hiding paragraph style
            let indentLevel: Int
            let isBullet: Bool
            let bulletCharIndex: Int    // absolute index of • in backing; -1 if not a bullet
        }
        var lineInfos: [LineInfo] = []

        (backing.string as NSString).enumerateSubstrings(
            in: full, options: .byLines
        ) { [weak self] sub, subRange, enclosingRange, _ in
            guard let self, let line = sub else { return }
            let leadingSpaces = line.prefix(while: { $0 == " " }).count
            let level = leadingSpaces / 2
            let trimmed = String(line.dropFirst(leadingSpaces))
            let isBullet = trimmed.hasPrefix("\u{2022} ")
            lineInfos.append(LineInfo(
                range: subRange,
                enclosingRange: enclosingRange,
                indentLevel: level,
                isBullet: isBullet,
                bulletCharIndex: isBullet ? (subRange.location + leadingSpaces) : -1
            ))
            self.styleLine(line, in: subRange)
        }

        // Restore sendTarget attributes — must run before the fold guard so it
        // fires even when no bullets are folded.
        for (idx, target) in sendTargets {
            guard idx < backing.length else { continue }
            backing.addAttribute(.sendTarget, value: target,
                                 range: NSRange(location: idx, length: 1))
        }

        // Re-apply fold state and hide child lines for each folded parent bullet.
        // "Children" = consecutive lines after the parent whose indent level is
        // strictly greater. They get 0.1pt height + clear color (same trick as
        // the --- HR reserved slot, just at near-zero instead of 24pt).
        guard !foldedCharIndices.isEmpty else { return }

        let hidePara: NSMutableParagraphStyle = {
            let p = NSMutableParagraphStyle()
            // 1.0pt — functionally invisible on Retina (0.5 physical pixels) but
            // avoids pathological TextKit 1 layout behaviour that 0.1pt can trigger.
            p.minimumLineHeight = 1.0
            p.maximumLineHeight = 1.0
            return p
        }()

        for (i, info) in lineInfos.enumerated() {
            guard info.isBullet, info.bulletCharIndex >= 0 else { continue }
            guard foldedCharIndices.contains(info.bulletCharIndex) else { continue }

            // Restore .foldState on this parent • character
            backing.addAttribute(.foldState, value: true,
                                 range: NSRange(location: info.bulletCharIndex, length: 1))

            // Hide all consecutive child lines.
            // Use enclosingRange (with \n) for ALL attributes so that the paragraph
            // terminator has hidePara — fixParagraphStyleAttribute will then extend
            // hidePara across the whole paragraph rather than restoring baseParagraphStyle.
            var j = i + 1
            while j < lineInfos.count && lineInfos[j].indentLevel > info.indentLevel {
                backing.addAttributes([
                    .paragraphStyle:  hidePara,
                    .foregroundColor: UIColor.clear,
                    .font:            Self.hiddenFont
                ], range: lineInfos[j].enclosingRange)
                j += 1
            }
        }
    }

    // MARK: - Fold toggle support

    /// Flips the .foldState Bool attribute on a bullet's • character in the backing store.
    /// Call applyStylesAndNotify() immediately after to re-layout.
    func toggleFoldState(at characterIndex: Int) {
        guard characterIndex < backing.length else { return }
        let current = backing.attribute(.foldState, at: characterIndex,
                                       effectiveRange: nil) as? Bool ?? false
        backing.addAttribute(.foldState, value: !current,
                             range: NSRange(location: characterIndex, length: 1))
    }

    // MARK: - Send-target support

    /// Stores (or clears) a send destination on the ☐/☑ character at characterIndex.
    /// Pass nil to remove. Writes directly to backing — does NOT trigger processEditing.
    /// applyStyles() snapshots and restores this on every subsequent keystroke.
    func setSendTarget(_ target: String?, at characterIndex: Int) {
        guard characterIndex < backing.length else { return }
        if let target = target {
            backing.addAttribute(.sendTarget, value: target,
                                 range: NSRange(location: characterIndex, length: 1))
        } else {
            backing.removeAttribute(.sendTarget,
                                    range: NSRange(location: characterIndex, length: 1))
        }
    }

    /// Returns the stored send destination ("things" or "tweek") for the ☐/☑ at
    /// characterIndex, or nil if none is set.
    func getSendTarget(at characterIndex: Int) -> String? {
        guard characterIndex < backing.length else { return nil }
        return backing.attribute(.sendTarget, at: characterIndex,
                                 effectiveRange: nil) as? String
    }

    /// Runs a full applyStyles() pass then fires an .editedAttributes notification
    /// so the layout manager re-measures line fragment rects (paragraph heights).
    ///
    /// WHY .editedAttributes (not .editedCharacters):
    ///   WWDC 2018 Session 221 + Apple docs: BOTH masks cause the LM to invalidate
    ///   glyphs and re-layout line fragment rects. .editedAttributes is sufficient
    ///   for paragraph-style / line-height changes. Using .editedCharacters over the
    ///   full document range has a severe side-effect: UITextView internally calls
    ///   _fixSelectionAfterChange with the full range and repositions the cursor to
    ///   position 0 (first row). That's the "cursor stuck at top" bug. .editedAttributes
    ///   does not trigger _fixSelectionAfterChange, so the cursor stays put.
    ///
    /// WHY applyStyles() does NOT run a second time (unlike the .editedCharacters path):
    ///   processEditing() only re-runs applyStyles() when editedMask has .editedCharacters.
    ///   With .editedAttributes only, processEditing falls through to super.processEditing()
    ///   which notifies the LM. That is exactly what we want: the LM sees the fold-hiding
    ///   attributes that applyStyles() just wrote to backing.
    ///
    /// WHY the caller also needs tv.setNeedsDisplay():
    ///   UITextView's display layer does not automatically redraw on attribute-only LM
    ///   notifications the same way it does after character edits. Without an explicit
    ///   setNeedsDisplay() call in the Coordinator, the LM's new 1pt line heights are
    ///   computed but the on-screen pixels are never refreshed (fold appears to do nothing).
    /// The `textViewDidChange` entry point. **This is the one the editor uses.**
    ///
    /// `applyStyles()` writes through the private `backing`, which emits no
    /// notifications at all, so the layout manager repaints only what the user
    /// physically typed and anything recoloured outside that range keeps a stale
    /// glyph — most visibly a line-start ☐ going blank while you type to its
    /// right. One `edited(.editedAttributes,…)` over the whole document fixes
    /// that.
    ///
    /// **Whole document, and safely so**, because this runs outside the edit
    /// cycle: the notification is its own, not merged into the user's, so a wide
    /// range costs a repaint rather than moving the caret. Notes are small.
    ///
    /// Deliberately NOT `applyStylesAndNotify()` below, which additionally calls
    /// `invalidateLayout` on every layout manager. That is needed for folding,
    /// where paragraph line heights change; on an ordinary keystroke it is a full
    /// re-layout per character.
    func applyStylesForEdit() {
        guard backing.length > 0 else { return }
        applyStyles()
        let full = NSRange(location: 0, length: backing.length)
        beginEditing()
        edited(.editedAttributes, range: full, changeInLength: 0)
        endEditing()
        // D53. Not belt-and-braces. Range invalidation can only dirty the area a
        // character range *currently* occupies, and stale pixels sit where
        // characters USED to be — below the used rect, mapped to no character at
        // all. Only a view-level redraw reaches them. That is the "row went
        // missing" and "the row is drawn twice" symptom, which are the same bug
        // in two directions.
        hostTextView?.setNeedsDisplay()
    }

    func applyStylesAndNotify() {
        guard backing.length > 0 else { return }
        applyStyles()   // writes fold-hiding paragraph styles + clear color to backing
        let full = NSRange(location: 0, length: backing.length)
        beginEditing()
        edited(.editedAttributes, range: full, changeInLength: 0)
        endEditing()    // → processEditing → super.processEditing() → LM notified
        //
        // WHY the explicit invalidateLayout call below is required:
        //
        // In TextKit 1, .editedAttributes notifies the LM about attribute changes.
        // However, the LM's response to .editedAttributes is to invalidate DISPLAY
        // (glyph redraw) — NOT LAYOUT (line fragment rect re-computation). Paragraph
        // style changes (hidePara: minimumLineHeight = maximumLineHeight = 1pt) only
        // affect LINE HEIGHT, which requires layout re-computation. Without this call,
        // ensureLayout() in refreshFoldOverlays finds no pending layout work and returns
        // immediately using the old (22pt) line heights — fold appears to do nothing.
        //
        // Calling invalidateLayout AFTER endEditing() (i.e., after processEditing
        // completes) is safe — we are no longer inside the notification pipeline.
        for lm in layoutManagers {
            lm.invalidateLayout(forCharacterRange: full, actualCharacterRange: nil)
        }
    }

    // MARK: - Per-line styling

    private func styleLine(_ line: String, in range: NSRange) {
        // Horizontal rule — hide `---` text; Coordinator overlays a UIView separator (tag 9_003)
        if line.trimmingCharacters(in: .whitespacesAndNewlines) == "---" {
            backing.addAttributes([
                .font: Self.hiddenFont,
                .foregroundColor: UIColor.clear
            ], range: range)
            // Fixed 24pt height gives the overlay line a comfortable slot
            let para = NSMutableParagraphStyle()
            para.minimumLineHeight = 24
            para.maximumLineHeight = 24
            backing.addAttribute(.paragraphStyle, value: para, range: range)
            return
        }
        // Headings — dim markers, apply larger semibold font to text
        if line.hasPrefix("### ") { styleHeading(line, in: range, level: 3); return }
        if line.hasPrefix("## ")  { styleHeading(line, in: range, level: 2); return }
        if line.hasPrefix("# ")   { styleHeading(line, in: range, level: 1); return }
        // Checkboxes — ☑ / ☐ stored as Unicode; hidden glyph + SF Symbol overlay
        if line.hasPrefix("☑ ") { styleCheckboxLine(checked: true,  line: line, in: range); return }
        if line.hasPrefix("☐ ") { styleCheckboxLine(checked: false, line: line, in: range); return }
        if line.hasPrefix("\u{2022} ")      { styleBulletPrefix(in: range) }
        else if line.contains("\u{2022} ") { styleIndentedBulletPrefix(line, in: range) }
        if line.hasPrefix("- ")            { styleBulletPrefix(in: range) }
        applyBold(in: line, lineRange: range)
        applyItalic(in: line, lineRange: range)
        applyStrike(in: line, lineRange: range)
        applyHighlight(in: line, lineRange: range)
        applyHashtags(in: line, lineRange: range)
        applyLinks(in: line, lineRange: range)
        applyMarkdownLinks(in: line, lineRange: range)
        applyImageLinks(in: line, lineRange: range)
        applyThumbnailImageLinks(in: line, lineRange: range)
        applyPDFLinks(in: line, lineRange: range)
        // Wikilinks run last so nothing after them can override the hidden [[ / ]] attrs.
        applyWikilinks(in: line, lineRange: range)
    }

    // MARK: Heading — # / ## / ###
    // Dims the # prefix chars; applies larger semibold font to the heading text.
    // level 1 = 22pt, level 2 = 19pt, level 3 = 17pt (body is 16pt).

    private func styleHeading(_ line: String, in range: NSRange, level: Int) {
        let markerLen = level + 1          // "# " = 2, "## " = 3, "### " = 4
        guard range.length >= markerLen else { return }

        // Hide the # markers entirely (same approach as ** and * markers)
        let markerRange = NSRange(location: range.location, length: markerLen)
        backing.addAttribute(.font,            value: Self.hiddenFont, range: markerRange)
        backing.addAttribute(.foregroundColor, value: UIColor.clear,   range: markerRange)

        let textLen = range.length - markerLen
        guard textLen > 0 else { return }
        let textRange = NSRange(location: range.location + markerLen, length: textLen)
        let size: CGFloat = level == 1 ? 22 : (level == 2 ? 19 : 17)
        backing.addAttribute(.font,
                             value: UIFont.systemFont(ofSize: size, weight: .semibold),
                             range: textRange)
    }

    // MARK: Bullet prefix

    private func styleBulletPrefix(in range: NSRange) {
        guard range.length >= 2 else { return }
        backing.addAttribute(.foregroundColor, value: Self.dimColor,
                             range: NSRange(location: range.location, length: 2))
    }

    /// Dims the "• " in an indented bullet like "  • item" and applies a hanging indent
    /// so that wrapped continuation lines align with the content start (not the left margin).
    private func styleIndentedBulletPrefix(_ line: String, in range: NSRange) {
        guard let bulletRange = line.range(of: "\u{2022} ") else { return }
        // String.UTF16View.Index IS String.Index — distance gives the UTF-16 offset directly.
        let utf16Offset = line.utf16.distance(from: line.utf16.startIndex,
                                              to: bulletRange.lowerBound)
        let nsOffset = range.location + utf16Offset
        guard nsOffset + 2 <= range.location + range.length else { return }

        // Dim the bullet glyph and its trailing space.
        backing.addAttribute(.foregroundColor, value: Self.dimColor,
                             range: NSRange(location: nsOffset, length: 2))

        // Hanging indent: measure "  • " (indent spaces + bullet + space) so that any
        // continuation lines start at the same x-position as the first content character.
        // firstLineHeadIndent stays 0 (the spaces render normally on the first line);
        // headIndent shifts continuation lines rightward by the same visual width.
        let prefixStr = (line as NSString).substring(to: utf16Offset + 2)  // e.g. "  • "
        let prefixWidth = (prefixStr as NSString).size(
            withAttributes: [.font: Self.bodyFont]).width
        let para = NSMutableParagraphStyle()
        para.lineHeightMultiple = 1.4   // preserve base line height
        para.headIndent = prefixWidth
        backing.addAttribute(.paragraphStyle, value: para, range: range)
    }

    // MARK: Checkbox
    // ☐ (U+2610) = unchecked, ☑ (U+2611) = checked.
    // Both characters are stored as-is in the backing string so the file format is
    // unchanged. However, U+2610/U+2611 are absent from SF Pro — CoreText falls back
    // to a font that renders them as a "W"-like glyph. We avoid the problem entirely
    // by hiding the character (hiddenFont + clear color) and letting MarkdownEditorView
    // overlay an SF Symbol UIImageView at the glyph's line-fragment position.
    //
    // .checkboxState (Bool) is written onto the hidden character so that
    // refreshCheckboxOverlays can find every checkbox line via enumerateAttribute.
    // The paragraph indent (firstLineHeadIndent + headIndent = 22pt) pushes task text
    // to the right of the 18pt icon, matching the same pattern used for --- HR overlays.
    //
    // **The trailing space uses `hiddenAnchorFont` (3pt), not `hiddenFont` (0.1pt) —
    // found 2026-07-20.** refreshCheckboxOverlays needs a real, on-this-line glyph
    // to query for vertical position. It can't use the ☐ character itself (0.1pt
    // is small enough that the layout manager treats it as a "null glyph," which
    // can report y=0 — collapsing the overlay to the top of the document). So it
    // used to skip 2 characters ahead to the first real *task text* character —
    // fine when the checklist item has text, but when the item is still empty
    // (just inserted, nothing typed after it yet) there IS no character 2 ahead;
    // the query lands on the paragraph's own newline/terminator, which TextKit can
    // resolve to the PRECEDING line's rect — exactly the "checkbox overlaps the
    // row above" bug. Giving the trailing space a small-but-not-null font means
    // refreshCheckboxOverlays can anchor 1 character ahead (a glyph that always
    // exists, is always part of THIS line, and is never null-sized) instead of 2,
    // which works whether or not the item has real text yet. Still fully invisible
    // (.clear foreground color either way).
    //
    // **Second pass, found 2026-07-20 — the trailing-space fix above was only a
    // partial fix.** It made the position QUERY more reliable, but didn't touch
    // the paragraph's actual rendered HEIGHT. `lineHeightMultiple` is a *multiplier*
    // on whatever the natural line height works out to from the fonts actually
    // present on that line. An empty checkbox line's only content is the hidden
    // ☐ (0.1pt) and the hidden space (3pt, per the fix above) — both tiny — so the
    // natural line height TextKit computes for that paragraph is tiny too, and
    // 1.4× a tiny number is still tiny. The line is genuinely too short, not just
    // mis-positioned, until real 16pt task text exists on it to drive the natural
    // height back up. Real fix: pin the checkbox paragraph to an explicit fixed
    // height (`checkboxLineHeight`, computed once from real body-text metrics)
    // via minimumLineHeight/maximumLineHeight, the same technique this file
    // already uses for `---` horizontal rules just below — so the row is always
    // full height, whether or not it has text yet.

    private func styleCheckboxLine(checked: Bool, line: String, in range: NSRange) {
        guard range.length >= 2 else { return }

        // Indent the whole line to leave room for the SF Symbol icon at the left margin.
        let para = NSMutableParagraphStyle()
        para.lineHeightMultiple  = 1.4                        // kept for intent/continuity
        para.minimumLineHeight   = Self.checkboxLineHeight     // the real fix — see comment above
        para.maximumLineHeight   = Self.checkboxLineHeight
        para.firstLineHeadIndent = Self.checkboxIndent
        para.headIndent          = Self.checkboxIndent
        backing.addAttribute(.paragraphStyle, value: para, range: range)

        // Hide ☐/☑ and tag it so refreshCheckboxOverlays can locate it.
        backing.addAttributes([
            .font:          Self.hiddenFont,
            .foregroundColor: UIColor.clear,
            .checkboxState: checked
        ], range: NSRange(location: range.location, length: 1))

        // Hide the trailing space too — it has no visible role now that we indent.
        // hiddenAnchorFont (not hiddenFont) — see the MARK: Checkbox comment above.
        backing.addAttributes([
            .font:           Self.hiddenAnchorFont,
            .foregroundColor: UIColor.clear
        ], range: NSRange(location: range.location + 1, length: 1))

        let textStart = range.location + 2
        let textLen   = range.length - 2
        guard textLen > 0 else { return }
        let textRange = NSRange(location: textStart, length: textLen)

        if checked {
            backing.addAttributes([
                .foregroundColor:    Self.dimColor,
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .strikethroughColor: Self.dimColor
            ], range: textRange)
        }

        // INLINE MARKUP INSIDE A CHECKBOX LINE. Added 2026-08-03.
        //
        // David: *"the wikilink for Hannah in the Sunday Aug 2nd note is not
        // clickable."* It was `☐ Check on apartment insurance for
        // [[Hannah Weiss]]` — a wikilink inside a checkbox line.
        //
        // `styleLine` **returns** after calling this method, so until now none
        // of the inline stylers ran on a checkbox line at all. No wikilinks, so
        // no `.wikiTarget` attribute, so `onWikiTap` had nothing to find and the
        // link was dead. Bold, italic, strikethrough, highlight, hashtags and
        // URLs were equally inert there, and the `[[ ]]` brackets showed raw.
        //
        // **The Mac has always done this correctly** — `MacMarkdownTextStorage
        // .styleCheckbox` ends by running the inline stylers over the text after
        // the marker. This is that, ported. The two files are two renderers of
        // one on-disk format, and this is the third time a rule existed on one
        // side and not the other.
        //
        // Run over `textLine` with `textRange` as the base, exactly as the Mac
        // does: the stylers take a line and the absolute range it starts at, so
        // dropping the `☐ ` prefix from both keeps their offsets aligned.
        //
        // Wikilinks run LAST for the same reason they do in `styleLine` —
        // nothing after them can override the hidden `[[` / `]]` attributes.
        let textLine = String(line.dropFirst(2))
        applyBold(in: textLine, lineRange: textRange)
        applyItalic(in: textLine, lineRange: textRange)
        applyStrike(in: textLine, lineRange: textRange)
        applyHighlight(in: textLine, lineRange: textRange)
        applyHashtags(in: textLine, lineRange: textRange)
        applyLinks(in: textLine, lineRange: textRange)
        applyMarkdownLinks(in: textLine, lineRange: textRange)
        applyWikilinks(in: textLine, lineRange: textRange)
    }

    // MARK: Bold — **text**
    // The ** markers are set to a near-zero invisible font so they vanish visually
    // while remaining in the backing store (file on disk is valid markdown).

    private func applyBold(in line: String, lineRange: NSRange) {
        guard line.contains("**"),
              let regex = try? NSRegularExpression(pattern: #"\*\*(.+?)\*\*"#) else { return }
        let ns = line as NSString
        let hidden: [NSAttributedString.Key: Any] = [
            .font: Self.hiddenFont,
            .foregroundColor: UIColor.clear
        ]
        for m in regex.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            guard m.range.length >= 5 else { continue }
            let base = lineRange.location + m.range.location
            let len  = m.range.length
            // Hide the ** markers
            backing.addAttributes(hidden, range: NSRange(location: base, length: 2))
            // Bold the inner text
            backing.addAttribute(.font, value: Self.boldFont,
                                 range: NSRange(location: base + 2, length: len - 4))
            backing.addAttributes(hidden, range: NSRange(location: base + len - 2, length: 2))
        }
    }

    // MARK: Italic — *text*
    // Same approach: hide the * markers, apply italic font to inner text.
    // Negative lookaround prevents matching inside ** bold spans.

    private func applyItalic(in line: String, lineRange: NSRange) {
        guard line.contains("*"),
              let regex = try? NSRegularExpression(
                  pattern: #"(?<!\*)\*([^*\n]+)\*(?!\*)"#) else { return }
        let ns = line as NSString
        let hidden: [NSAttributedString.Key: Any] = [
            .font: Self.hiddenFont,
            .foregroundColor: UIColor.clear
        ]
        for m in regex.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            guard m.range.length >= 3 else { continue }
            let base = lineRange.location + m.range.location
            let len  = m.range.length
            backing.addAttributes(hidden, range: NSRange(location: base, length: 1))
            backing.addAttribute(.font, value: UIFont.italicSystemFont(ofSize: 16),
                                 range: NSRange(location: base + 1, length: len - 2))
            backing.addAttributes(hidden, range: NSRange(location: base + len - 1, length: 1))
        }
    }

    // MARK: Strikethrough — ~~text~~
    // Hides the ~~ markers, applies strikethrough to inner text.

    private func applyStrike(in line: String, lineRange: NSRange) {
        guard line.contains("~~"),
              let regex = try? NSRegularExpression(pattern: #"~~(.+?)~~"#) else { return }
        let ns = line as NSString
        let hidden: [NSAttributedString.Key: Any] = [
            .font: Self.hiddenFont,
            .foregroundColor: UIColor.clear
        ]
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

    // MARK: Hashtags — #tag
    // Colors the entire #tag span purple. Markers are NOT hidden — #tag is the visible form.
    // Pattern: # preceded by start-of-line or whitespace, followed by a letter then word chars.

    private static let hashtagRegex: NSRegularExpression? =
        try? NSRegularExpression(pattern: #"(?:^|(?<=\s))#([a-zA-Z][a-zA-Z0-9_]*)"#,
                                 options: .anchorsMatchLines)

    private func applyHashtags(in line: String, lineRange: NSRange) {
        guard line.contains("#"), let regex = Self.hashtagRegex else { return }
        let ns = line as NSString
        for m in regex.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            let base = lineRange.location + m.range.location
            let len  = m.range.length
            backing.addAttribute(.foregroundColor,
                                 value: UIColor.systemPurple,
                                 range: NSRange(location: base, length: len))
        }
    }

    // MARK: Highlight — ==text==
    // Hides the == markers, applies yellow background to inner text.

    private func applyHighlight(in line: String, lineRange: NSRange) {
        guard line.contains("=="),
              let regex = try? NSRegularExpression(pattern: "==(.+?)==") else { return }
        let ns = line as NSString
        let hidden: [NSAttributedString.Key: Any] = [
            .font: Self.hiddenFont,
            .foregroundColor: UIColor.clear
        ]
        for m in regex.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            guard m.range.length >= 5 else { continue }
            let base = lineRange.location + m.range.location
            let len  = m.range.length
            backing.addAttributes(hidden, range: NSRange(location: base, length: 2))
            backing.addAttribute(.backgroundColor,
                                 value: UIColor.systemYellow.withAlphaComponent(0.4),
                                 range: NSRange(location: base + 2, length: len - 4))
            backing.addAttributes(hidden, range: NSRange(location: base + len - 2, length: 2))
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

    // MARK: Wikilinks — [[name]] and [[target|display]]
    // Hides the brackets (and, on an alias, the `target|` half); colors what is left
    // in linkColor. Adds .wikiTarget on the visible span so handleTap/handleLongPress
    // can detect it without a second regex pass. .wikiTarget is re-derived from text on
    // every applyStyles() pass (unlike .sendTarget which is user-set state), so no
    // snapshot/restore needed.
    //
    // ALIASES, 2026-08-01. `[[Nick's on the Lake (formerly known as Popeye's)|Nick's on
    // the Lake]]` shows "Nick's on the Lake" and still resolves against the full Notion
    // name, which is the string resolveWikiLink() matches on. Written by the Endeavor
    // trip log (TripLogName in DayflowEndeavor.swift). Typed wikilinks and the
    // autocomplete pills still produce the plain form and take the path they always
    // did. Obsidian uses this exact syntax, so the file also reads correctly in David's
    // vault rather than only inside these apps.
    //
    // THE TWO FORMS SHARE ONE CODE PATH. They differ only in where the visible span
    // starts: everything from the match start up to it is hidden, everything from its
    // end to the match end is hidden. Written that way deliberately — as two branches
    // it would be possible to hide the right characters for one form and the wrong
    // ones for the other, and a wrong hide is invisible in the editor and permanent in
    // the file.

    private func applyWikilinks(in line: String, lineRange: NSRange) {
        guard line.contains("[["),
              let regex = try? NSRegularExpression(
                  pattern: #"\[\[([^\]|]+)(?:\|([^\]]*))?\]\]"#) else { return }
        let ns = line as NSString
        let hidden: [NSAttributedString.Key: Any] = [
            .font: Self.hiddenFont,
            .foregroundColor: UIColor.clear
        ]
        for m in regex.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            guard m.numberOfRanges >= 2, m.range.length >= 5 else { continue }
            let targetRange = m.range(at: 1)
            guard targetRange.location != NSNotFound, targetRange.length > 0 else { continue }
            let target = ns.substring(with: targetRange)

            // The display half, when there is one. A degenerate `[[name|]]` shows the
            // target rather than rendering as nothing at all — an empty visible span
            // would leave a wikilink that cannot be seen, tapped or deleted.
            let aliasRange = m.numberOfRanges >= 3
                ? m.range(at: 2)
                : NSRange(location: NSNotFound, length: 0)
            let visible = (aliasRange.location != NSNotFound && aliasRange.length > 0)
                ? aliasRange
                : targetRange

            let matchStart = m.range.location
            let matchEnd   = m.range.location + m.range.length
            let visibleEnd = visible.location + visible.length

            // Hide the leading `[[`, plus `target|` when this is an alias.
            // Strip any residual .link or .foregroundColor set by applyLinks first.
            let prefixLen = visible.location - matchStart
            if prefixLen > 0 {
                let openRange = NSRange(location: lineRange.location + matchStart,
                                        length: prefixLen)
                backing.removeAttribute(.link,            range: openRange)
                backing.removeAttribute(.foregroundColor, range: openRange)
                backing.removeAttribute(.wikiTarget,      range: openRange)
                backing.addAttributes(hidden, range: openRange)
            }

            // Color the visible span and tag it for tap detection.
            // Remove .link first — NSDataDetector (applyLinks) may have matched the
            // text if it looks like a domain. We handle wikilink taps via .wikiTarget,
            // not UITextView's native link menu.
            let visibleNsRange = NSRange(location: lineRange.location + visible.location,
                                         length: visible.length)
            backing.removeAttribute(.link, range: visibleNsRange)
            backing.addAttributes([
                .foregroundColor: Self.linkColor,
                .wikiTarget:      target
            ], range: visibleNsRange)

            // Hide the trailing `]]`, plus a `|` and any empty-alias remainder.
            let suffixLen = matchEnd - visibleEnd
            if suffixLen > 0 {
                let closeRange = NSRange(location: lineRange.location + visibleEnd,
                                         length: suffixLen)
                backing.removeAttribute(.link,            range: closeRange)
                backing.removeAttribute(.foregroundColor, range: closeRange)
                backing.removeAttribute(.wikiTarget,      range: closeRange)
                backing.addAttributes(hidden, range: closeRange)
            }
        }
    }

    // MARK: Markdown links — [label](url)
    // Hides `[`, `]`, and `(url)`; colors label in linkColor; sets .link on label so
    // UITextView's shouldInteractWith fires on tap (same path as bare http:// URLs).
    // Runs after applyLinks so NSDataDetector's .link on the raw URL is removed from the
    // hidden `](url)` suffix — without this removal, the hidden suffix is still tappable.
    // Negative lookbehind (?<![!]) prevents matching `![desc](path)` image links.

    private func applyMarkdownLinks(in line: String, lineRange: NSRange) {
        guard line.contains("["),
              let regex = try? NSRegularExpression(
                  pattern: #"(?<![!])\[([^\]]+)\]\(([^)]+)\)"#) else { return }
        let ns = line as NSString
        let hidden: [NSAttributedString.Key: Any] = [
            .font: Self.hiddenFont,
            .foregroundColor: UIColor.clear
        ]
        for m in regex.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            guard m.numberOfRanges >= 3 else { continue }
            let labelRange = m.range(at: 1)
            let urlRange   = m.range(at: 2)
            guard labelRange.location != NSNotFound,
                  urlRange.location   != NSNotFound else { continue }
            let urlStr = ns.substring(with: urlRange)
            let base   = lineRange.location + m.range.location
            let total  = m.range.length

            // Hide opening `[`
            let openBracket = NSRange(location: base, length: 1)
            backing.removeAttribute(.link, range: openBracket)
            backing.addAttributes(hidden, range: openBracket)

            // Color label in linkColor + set .link so shouldInteractWith fires on tap
            let labelBase = lineRange.location + labelRange.location
            var labelAttrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: Self.linkColor,
                .mdLinkLabel: true
            ]
            if let url = URL(string: urlStr) { labelAttrs[.link] = url }
            backing.addAttributes(labelAttrs,
                                  range: NSRange(location: labelBase, length: labelRange.length))

            // Hide `](url)` — from `]` after label to end of match.
            // Also removes .link that applyLinks may have set on the raw URL inside the parens.
            let afterLabelInLine    = labelRange.location + labelRange.length
            let afterLabelInBacking = lineRange.location + afterLabelInLine
            let suffixLen = (m.range.location + total) - afterLabelInLine
            if suffixLen > 0 {
                let suffixRange = NSRange(location: afterLabelInBacking, length: suffixLen)
                backing.removeAttribute(.link, range: suffixRange)
                backing.addAttributes(hidden, range: suffixRange)
            }
        }
    }

    // MARK: Image links — ![desc](path)
    // Hides `![` and `](path)`, shows desc in orange with .imageNoteStorePath attribute.
    // Tapping the visible desc in MarkdownEditorView's handleTap reads this attribute to open
    // the photo viewer.

    private func applyImageLinks(in line: String, lineRange: NSRange) {
        guard line.contains("!["),
              let regex = try? NSRegularExpression(
                  pattern: #"!\[([^\]]*)\]\(([^)]+)\)"#) else { return }
        let ns = line as NSString
        let hidden: [NSAttributedString.Key: Any] = [
            .font: Self.hiddenFont,
            .foregroundColor: UIColor.clear
        ]
        let orange = UIColor.systemOrange
        for m in regex.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            guard m.numberOfRanges >= 3 else { continue }
            let descRange = m.range(at: 1)   // alt text (may be empty)
            let pathRange = m.range(at: 2)   // relative path
            guard pathRange.location != NSNotFound else { continue }
            let path = ns.substring(with: pathRange)
            let base = lineRange.location + m.range.location

            // Same `.link` strip as `applyPDFLinks` above. Images are currently
            // protected by `applyMarkdownLinks`' `(?<![!])` lookbehind, so this
            // is defensive rather than a fix — but relying on another function's
            // regex to stay exclusive is the kind of coupling that breaks
            // silently, and the whole point of running last is to win.
            backing.removeAttribute(.link,
                                    range: NSRange(location: base, length: m.range.length))

            // Hide `![` (2 ASCII chars at start of match)
            backing.addAttributes(hidden, range: NSRange(location: base, length: 2))

            if descRange.length > 0 {
                // Show desc in orange + store path for tap detection
                let descBase = lineRange.location + descRange.location
                backing.addAttributes([
                    .foregroundColor: orange,
                    .imageNoteStorePath: path
                ], range: NSRange(location: descBase, length: descRange.length))
            } else {
                // Empty desc — derive a display label from the filename in the path.
                // `![` stays hidden; we un-hide just the filename portion from the `](path)` suffix.
                let filename = (path as NSString).lastPathComponent
                let filenameOffsetInPath = path.count - filename.count
                // Hide `![](` + path-prefix-up-to-filename  (base … base + 4 + filenameOffsetInPath)
                let prefixLen = 4 + filenameOffsetInPath   // "![" + "](" + dirs
                backing.addAttributes(hidden, range: NSRange(location: base, length: prefixLen))
                // Show filename in orange, tappable
                let filenameBase = base + prefixLen
                backing.addAttributes([
                    .foregroundColor: orange,
                    .imageNoteStorePath: path
                ], range: NSRange(location: filenameBase, length: filename.count))
                // Hide closing `)`
                backing.addAttributes(hidden,
                                      range: NSRange(location: filenameBase + filename.count, length: 1))
                continue   // suffix already handled above — skip the generic suffix block
            }

            // Hide `](path)` — everything after the desc to end of match
            let afterDescInLine = descRange.location + descRange.length
            let afterDescInBacking = lineRange.location + afterDescInLine
            let suffixLen = (m.range.location + m.range.length) - afterDescInLine
            if suffixLen > 0 {
                backing.addAttributes(hidden,
                                      range: NSRange(location: afterDescInBacking, length: suffixLen))
            }
        }
    }


    // MARK: Thumbnail image lines — !![desc](path)
    // Makes the entire line invisible (the Coordinator overlays a UIImageView at this rect)
    // and reserves 200pt of vertical space via paragraph style.
    // .imageNoteStorePath is set on the full line so tap/long-press detection works.

    private func applyThumbnailImageLinks(in line: String, lineRange: NSRange) {
        guard line.hasPrefix("!![") else { return }
        guard let regex = try? NSRegularExpression(
                  pattern: #"^!!\[([^\]]*)\]\(([^)]+)\)"#),
              let match = regex.firstMatch(
                  in: line, range: NSRange(location: 0, length: (line as NSString).length)),
              match.numberOfRanges >= 3,
              match.range(at: 2).location != NSNotFound else { return }

        let path = (line as NSString).substring(with: match.range(at: 2))

        // Hide all text on the line — UIImageView overlay renders the image
        backing.addAttributes([
            .font: Self.hiddenFont,
            .foregroundColor: UIColor.clear
        ], range: lineRange)

        // Reserve 200pt vertical space for the thumbnail
        let para = NSMutableParagraphStyle()
        para.minimumLineHeight = 200
        para.maximumLineHeight = 200
        backing.addAttribute(.paragraphStyle, value: para, range: lineRange)

        // Store path so tap and long-press detect this as an image line
        backing.addAttribute(.imageNoteStorePath, value: path, range: lineRange)
    }

    // MARK: PDF links — 📎 [desc](path)
    // Keeps `📎 ` visible in orange, hides `[` and `](path)`, shows desc in orange.
    // 📎 is U+1F4CE — encodes as 2 UTF-16 code units, so `📎 ` = 3 UTF-16 units.

    private func applyPDFLinks(in line: String, lineRange: NSRange) {
        guard line.contains("📎"),
              let regex = try? NSRegularExpression(
                  pattern: "📎 \\[([^\\]]*)\\]\\(([^)]+)\\)") else { return }
        let ns = line as NSString
        let hidden: [NSAttributedString.Key: Any] = [
            .font: Self.hiddenFont,
            .foregroundColor: UIColor.clear
        ]
        let orange = UIColor.systemOrange
        for m in regex.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            guard m.numberOfRanges >= 3 else { continue }
            let descRange = m.range(at: 1)
            let pathRange = m.range(at: 2)
            guard pathRange.location != NSNotFound else { continue }
            let path = ns.substring(with: pathRange)
            let base = lineRange.location + m.range.location

            // STRIP `.link` FIRST, over the whole match.
            //
            // `applyMarkdownLinks` runs before this one and its `(?<![!])`
            // lookbehind only excludes IMAGE links. A PDF line is
            // `📎 [desc](path)` — the character before `[` is a space, so it
            // matches, and the label gets `.foregroundColor: linkColor` plus a
            // `.link`. UITextView renders any `.link` range with
            // `linkTextAttributes`, which OVERRIDES a foreground colour set
            // afterwards, so the orange below never appeared: David's PDF
            // attachments rendered blue (screenshot, 2026-07-31), and his
            // earlier "I click on the blue word and nothing happens" is the
            // same cause — `.link` routes the tap through
            // `shouldInteractWith(url:)` instead of `handleTap`, which is what
            // reads `.pdfNoteStorePath`.
            //
            // `applyWikilinks` and `applyMarkdownLinks` both already do this.
            // This function and `applyImageLinks` were the two that did not.
            backing.removeAttribute(.link,
                                    range: NSRange(location: base, length: m.range.length))

            // Keep `📎 ` (3 UTF-16 units) visible in orange; store path for tap detection
            backing.addAttributes([
                .foregroundColor: orange,
                .pdfNoteStorePath: path
            ], range: NSRange(location: base, length: 3))

            // Hide `[` (1 unit at offset 3)
            backing.addAttributes(hidden, range: NSRange(location: base + 3, length: 1))

            // Show desc in orange + store path
            if descRange.length > 0 {
                let descBase = lineRange.location + descRange.location
                backing.addAttributes([
                    .foregroundColor: orange,
                    .pdfNoteStorePath: path
                ], range: NSRange(location: descBase, length: descRange.length))
            }

            // Hide `](path)` — from end of desc to end of match
            let afterDescInLine = descRange.location + descRange.length
            let afterDescInBacking = lineRange.location + afterDescInLine
            let suffixLen = (m.range.location + m.range.length) - afterDescInLine
            if suffixLen > 0 {
                backing.addAttributes(hidden,
                                      range: NSRange(location: afterDescInBacking, length: suffixLen))
            }
        }
    }
}

// MARK: - Custom attribute keys for tappable image and PDF links

extension NSAttributedString.Key {
    /// Stores the NoteStore-relative path of an image. Set by MarkdownTextStorage on `![desc](path)` spans.
    static let imageNoteStorePath = NSAttributedString.Key("com.david.trace.imageNoteStorePath")
    /// Stores the NoteStore-relative path of a PDF. Set by MarkdownTextStorage on `📎 [desc](path)` spans.
    static let pdfNoteStorePath   = NSAttributedString.Key("com.david.trace.pdfNoteStorePath")
    /// Bool — true = checked, false = unchecked. Set on the hidden ☐/☑ character.
    /// Read by MarkdownEditorView.refreshCheckboxOverlays to place SF Symbol overlays.
    static let checkboxState      = NSAttributedString.Key("com.david.trace.checkboxState")
    /// Bool — true = folded (children hidden). Set on the parent • character by
    /// toggleFoldState(); snapshotted and restored across every applyStyles() pass.
    static let foldState          = NSAttributedString.Key("com.david.trace.foldState")
    /// String ("things" or "tweek") — pending send destination for this checkbox.
    /// Set by insertCheckboxAndSend() when the user picks from the toolbar UIMenu.
    /// Consumed by the Return-key handler in shouldChangeTextIn to fire the send.
    /// Snapshotted and restored across every applyStyles() pass.
    static let sendTarget         = NSAttributedString.Key("com.david.trace.sendTarget")
    /// String — the inner name of a [[wikilink]] span (e.g. "Blue Bottle Coffee").
    /// Set by applyWikilinks() on the visible name characters (between the hidden [[ and ]]).
    /// Re-derived from text on every applyStyles() pass; no snapshot/restore needed.
    /// Read by handleTap (navigate) and handleLongPress (select name for editing).
    static let wikiTarget         = NSAttributedString.Key("com.david.trace.wikiTarget")
    /// Marks the visible label span of a `[label](url)` link.
    ///
    /// `.link` is no good for this: `NSDataDetector` sets it on bare URLs too, so
    /// it cannot tell a named link from an address someone typed. This is on the
    /// label characters only, which is exactly the range a long-press should
    /// select — the same trick `.wikiTarget` already plays for `[[name]]`.
    static let mdLinkLabel        = NSAttributedString.Key("com.david.trace.mdLinkLabel")
    /// Bool marker — set alongside .backgroundColor on search-result highlight spans.
    /// Lets applySearchHighlights clear only its own marks without touching markdown bg attrs.
    /// processEditing() does NOT call applyStyles() for attribute-only edits, so these are
    /// safe from the MarkdownTextStorage restyle cycle (wipe on user edit is intentional).
    static let searchHighlight    = NSAttributedString.Key("com.david.trace.searchHighlight")
}
