// MacTextEditor.swift
// The Mac markdown editor: `MacTextEditor` (NSViewRepresentable), its
// `MarkdownNSTextView` subclass, `MacEditorActions` (the direct command
// channel) and `MacEditorCommand`.
// Mac-only — do not add to iOS, Widget, or Share Extension targets.
//
// Session 83 (2026-09-03), D217. Lifted out of `TraceMacJournalView.swift`
// as a PURE relocation: the block below is byte-identical to what sat in that
// file between the "AppKit text editor" and "Shared markdown editor" marks.
// It moved because three screens now use it (the journal, Today's day note,
// the endeavor note) and a 4,000-line journal file is not where a shared
// component lives. No pbxproj change: `TraceMac/` is a synchronized folder.

import SwiftUI
import AppKit

// MARK: - AppKit text editor (no scrollbar)

// MARK: - Editor command enum

enum MacEditorCommand: Equatable {
    case bold, italic, strike, highlight
    case heading, bullet, checkbox
    case indent, outdent
    case link, date
    case undo, redo
    case timestamp
    case requestMove
    case applyWikiSuggestion(String)
    /// Raw text at the cursor. The photo button's insert goes through here
    /// rather than through the `text` binding, for the same reason every other
    /// command does: the binding round-trip loses the caret.
    case insertText(String)
}

// MARK: - NSTextView subclass: checkbox click detection

/// Intercepts mouseDown to toggle ☐/☑ when the user clicks the checkbox glyph.
/// Also rejects file-URL drags so they propagate up to the Documents drop zone
/// instead of being pasted as text paths.
/// Internal rather than private since Session 80, and not by preference.
///
/// `MacTextEditor` became internal so the day note could use it, which makes its
/// nested `Coordinator` internal too — and the coordinator stores a
/// `MarkdownNSTextView?`. Swift refuses an internal property whose type is
/// private, so the visibility had to follow. Nothing outside this file
/// references it, and nothing should.
final class MarkdownNSTextView: NSTextView {

    /// Fired when this view takes or loses first responder.
    ///
    /// **SwiftUI's `@FocusState` cannot see inside an `NSViewRepresentable`**,
    /// and the day note needs to know: its accent rule, its Escape handler and
    /// its collapse-the-open-card behaviour all hang off focus (D206). This is
    /// the AppKit fact those three were already using indirectly, reported
    /// directly instead of inferred.
    ///
    /// Same lesson as the arrows and the click-outside collapse: stop trying to
    /// make SwiftUI observe the event, and hand it the fact AppKit already has.
    var onFocusChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocusChange?(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { onFocusChange?(false) }
        return ok
    }

    /// Fired when the view's WIDTH changes, so thumbnail overlays can be
    /// re-laid out. Session 65.
    ///
    /// Overlays are positioned in absolute points rather than by a layout
    /// system, so nothing moves them when the window resizes — the picture
    /// would sit at its old width while the text reflowed around it. Width
    /// only: a height change is the document growing, which moves nothing
    /// horizontally and would fire this on every keystroke.
    var onWidthChange: (() -> Void)?

    /// Handed image bytes from a ⌘V. Returns true if it consumed them.
    ///
    /// **This is the primary gesture on a Mac and the toolbar button is the
    /// secondary one**, which is the reverse of the phone. A screenshot goes
    /// to the clipboard, not to a photo library, and asking someone to save it
    /// to disk first so a file panel can find it again is the phone's
    /// constraint imported into a place that does not have it.
    var onPasteImage: ((Data) -> Bool)?

    override func paste(_ sender: Any?) {
        if let onPasteImage {
            let pb = NSPasteboard.general
            // TIFF first: that is what a screenshot and most drags arrive as.
            // PNG second, for the sources that only offer it. Both are re-encoded
            // downstream, so which one wins does not affect what is stored.
            if let data = pb.data(forType: .tiff) ?? pb.data(forType: .png),
               onPasteImage(data) { return }
        }
        super.paste(sender)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let before = frame.width
        super.setFrameSize(newSize)
        if abs(before - newSize.width) > 0.5 { onWidthChange?() }
    }

    // Refuse file-URL drags — let the Documents left-column .onDrop handle them.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let fileTypes: [NSPasteboard.PasteboardType] = [
            .fileURL,
            NSPasteboard.PasteboardType("public.file-url"),
            NSPasteboard.PasteboardType(rawValue: "NSFilenamesPboardType")
        ]
        if fileTypes.contains(where: { sender.draggingPasteboard.types?.contains($0) == true }) {
            return []
        }
        return super.draggingEntered(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let fileTypes: [NSPasteboard.PasteboardType] = [
            .fileURL,
            NSPasteboard.PasteboardType("public.file-url"),
            NSPasteboard.PasteboardType(rawValue: "NSFilenamesPboardType")
        ]
        if fileTypes.contains(where: { sender.draggingPasteboard.types?.contains($0) == true }) {
            return false
        }
        return super.prepareForDragOperation(sender)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let adj = NSPoint(x: point.x - textContainerInset.width,
                          y: point.y - textContainerInset.height)
        if let lm = layoutManager, let tc = textContainer {
            let glyphIdx = lm.glyphIndex(for: adj, in: tc,
                                          fractionOfDistanceThroughGlyph: nil)
            let charIdx  = lm.characterIndexForGlyph(at: glyphIdx)
            if charIdx < (textStorage?.length ?? 0) {
                // Click on [[wikilink]] → navigate to record.
                // Single-click navigates and places cursor; Cmd+click navigates without moving cursor.
                if let target = textStorage?.attribute(.macWikiTarget, at: charIdx,
                                                       effectiveRange: nil) as? String {
                    // **A link click never reaches `super.mouseDown`.** Session
                    // 83, two crashes: `[[2026-W35]]` navigated to Today and
                    // died with "String index is out of bounds" INSIDE
                    // `-[NSTextView mouseDown:]`. That method runs a nested
                    // event loop tracking the drag until mouse-up. A link
                    // that changes section tears this view's host down while
                    // that loop is still reading the storage — posting the
                    // notification synchronously (first crash) or one
                    // run-loop turn later (second crash, the loop was still
                    // running) makes no difference. Before D255 a note link
                    // stayed in the Notes section and the view outlived the
                    // click by luck of the route.
                    //
                    // So: place the caret ourselves (the only thing the fall-
                    // through to super was for), post on the next turn so the
                    // click has fully returned, and return. ⌘-click leaves the
                    // caret where it was, as before.
                    if !event.modifierFlags.contains(.command) {
                        setSelectedRange(NSRange(location: charIdx, length: 0))
                    }
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: .openWikilink, object: nil,
                                                        userInfo: ["name": target])
                    }
                    return
                }
                // Click on checkbox → toggle
                if textStorage?.attribute(.macCheckboxState, at: charIdx,
                                          effectiveRange: nil) != nil {
                    let ns = (textStorage?.string ?? "") as NSString
                    let lineRange = ns.lineRange(for: NSRange(location: charIdx, length: 0))
                    let line = ns.substring(with: lineRange)
                    if line.hasPrefix("☐ ") {
                        textStorage?.replaceCharacters(in: lineRange,
                                                       with: "☑ " + String(line.dropFirst(2)))
                    } else if line.hasPrefix("☑ ") {
                        textStorage?.replaceCharacters(in: lineRange,
                                                       with: "☐ " + String(line.dropFirst(2)))
                    }
                    didChangeText()
                    return
                }
            }
        }
        super.mouseDown(with: event)
    }
}

extension MacTextEditor.Coordinator {

    /// Turns `- [ ] ` into `☐ ` as you type it, and `- [x] ` into `☑ `.
    ///
    /// **Why this exists.** The app's stored checkbox is the literal glyph —
    /// `MacMarkdownTextStorage` matches `hasPrefix("☐ ")` and the click-to-toggle
    /// handler rewrites the same two characters. That is a fine format on disk
    /// and an impossible one to type: there is no key for ☐. In the journal a
    /// toolbar button inserts it, so the gap never showed. The day note has no
    /// toolbar, and David hit it immediately: he typed the markdown everyone
    /// types and got a bullet reading "[ ] test".
    ///
    /// **Converting on input rather than teaching the renderer `- [ ]`.** The
    /// second option is tempting — it keeps standard markdown on disk — but it
    /// would mean two checkbox formats in one app: the glyph that iOS writes,
    /// the toolbar inserts and the toggle produces, plus a second one only the
    /// Mac understands. Every reader would then need both, and the one that
    /// forgot would be a silent bug. One format, reachable two ways.
    ///
    /// Fires only on the completing space, and is self-limiting: after the
    /// swap the line starts with the glyph and can never match again.
    ///
    /// `shouldChangeText`/`didChangeText` rather than a bare
    /// `replaceCharacters`, so ⌘Z undoes the substitution as one step instead
    /// of leaving a glyph nothing can remove.
    static func convertTypedCheckbox(in tv: NSTextView) {
        let ns = tv.string as NSString
        let caret = tv.selectedRange().location
        guard caret <= ns.length else { return }
        let lineRange = ns.lineRange(for: NSRange(location: caret, length: 0))
        let line = ns.substring(with: lineRange)

        // **The bullet forms are the ones that actually fire.** Typing `-` then
        // space at line start already converts the dash to `\u{2022}` (see the rule in
        // `shouldChangeTextIn` above), so `- [ ] ` is UNREACHABLE by typing —
        // you always end up at `\u{2022} [ ] `. The first version of this table knew
        // only the dash forms and therefore never matched anything David could
        // produce.
        //
        // The dash forms stay for pasted text, which never passes through that
        // rule. The bare-bracket forms are the shorthand that skips the dance
        // entirely: `[] ` at the start of a line is a checkbox. Safe against
        // markdown links, which are `[text](url)` and never start with an empty
        // pair.
        let swaps: [(String, String)] = [
            ("\u{2022} [ ] ", "\u{2610} "), ("\u{2022} [x] ", "\u{2611} "), ("\u{2022} [X] ", "\u{2611} "),
            ("- [ ] ",  "\u{2610} "), ("- [x] ",  "\u{2611} "), ("- [X] ",  "\u{2611} "),
            ("[ ] ",    "\u{2610} "), ("[] ",     "\u{2610} "),
            ("[x] ",    "\u{2611} "), ("[X] ",    "\u{2611} ")]
        for (typed, glyph) in swaps where line.hasPrefix(typed) {
            let prefix = NSRange(location: lineRange.location, length: (typed as NSString).length)
            guard tv.shouldChangeText(in: prefix, replacementString: glyph) else { return }
            tv.textStorage?.replaceCharacters(in: prefix, with: glyph)
            tv.didChangeText()
            // The line lost four characters; put the caret where the typing was.
            let shift = (typed as NSString).length - (glyph as NSString).length
            tv.setSelectedRange(NSRange(location: max(0, caret - shift), length: 0))
            return
        }
    }
}

// MARK: - MacEditorActions (direct command channel — bypasses SwiftUI binding timing)

/// Shared by TraceMacNoteEditor and MacTextEditor. Toolbar buttons call execute(_:) directly;
/// MacTextEditor wires it to the coordinator in makeNSView. No binding timing issues.
final class MacEditorActions {
    var execute: (MacEditorCommand) -> Void = { _ in }
    /// Called by .requestMove with (textToMove, remainingContent).
    var onMoveRequest: ((String, String) -> Void)?

    /// Rewrites the editor's live body and saves it. Session 65.
    ///
    /// **Why this and not a write to the file.** The Endeavor rail needs to put
    /// a visit into the note the editor beside it is holding. Writing the file
    /// directly loses: the editor's next debounced save takes its own `content`
    /// as the truth for the body, so the rail's line would be gone one keystroke
    /// later, silently. `saveTransform` re-reads the file to protect the
    /// *frontmatter*, which is a different half of the same document.
    ///
    /// So an owner hands in a transform and the editor applies it to what it is
    /// holding, then saves through the one path that already exists. Set by
    /// `TraceMacNoteEditor`; nil until an editor is on screen, which is also the
    /// only time an owner has any business writing into one.
    var applyToBody: ((@escaping (String) -> String) -> Void)?
}

// MARK: - MacTextEditor (NSViewRepresentable)

/// NSTextView backed by MacMarkdownTextStorage with live markdown rendering.
/// **No longer `private`** (Session 80). The day note on the Today screen uses
/// it too, and a second markdown editor written beside this one is the exact
/// drift this project has paid for twice — the iOS and Mac renderers, and the
/// note-prose test that lived privately inside `MacTaskRow`.
///
/// `MarkdownNSTextView` and the coordinator stay private: the day note needs the
/// representable, not its internals. Moving the whole cluster into a file of its
/// own is the right end state and is in Trace-Backlog.md — it is ~400 lines with
/// three types, and lifting it blind mid-session is how a working editor breaks.
struct MacTextEditor: NSViewRepresentable {
    @Binding var text: String
    let actions: MacEditorActions
    /// Reports first-responder changes to a SwiftUI owner. See
    /// `MarkdownNSTextView.onFocusChange`.
    var onFocusChange: ((Bool) -> Void)? = nil
    /// Called when the cursor enters/exits a [[...]] span. Receives the partial name or nil.
    var onWikilinkQuery: ((String?) -> Void)? = nil
    /// Called when the user presses Return while a wikilink session is open.
    /// Returns true if a suggestion was actually applied. False means there was
    /// nothing to accept, and the Return must be allowed through as a newline.
    var onWikilinkAccept: (() -> Bool)? = nil
    /// Called by .requestMove with (textToMove, remainingContent).
    var onMoveRequest: ((String, String) -> Void)? = nil
    /// Handed image bytes from a ⌘V; returns true if it stored and inserted them.
    var onPasteImage: ((Data) -> Bool)? = nil
    /// Lowercased titles of linkable notes, so the storage can paint a note
    /// wikilink in its own colour. See `MacMarkdownTextStorage.noteTitles`.
    var noteTitles: Set<String> = []

    // MARK: makeNSView

    func makeNSView(context: Context) -> NSScrollView {
        let storage   = MacMarkdownTextStorage()
        let manager   = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)

        let tv = MarkdownNSTextView(frame: .zero, textContainer: container)
        let paraStyle = MacMarkdownTextStorage.baseParagraphStyle

        tv.isEditable              = true
        tv.isRichText              = false
        tv.allowsUndo              = true
        tv.backgroundColor         = NSColor.clear
        tv.isVerticallyResizable   = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask        = [.width]
        tv.minSize                 = NSSize(width: 0, height: 0)
        tv.maxSize                 = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                            height: CGFloat.greatestFiniteMagnitude)
        tv.textContainerInset      = NSSize(width: 40, height: 24)
        tv.defaultParagraphStyle = paraStyle as? NSMutableParagraphStyle
        tv.typingAttributes = [
            NSAttributedString.Key.font:            MacMarkdownTextStorage.bodyFont,
            NSAttributedString.Key.foregroundColor: MacMarkdownTextStorage.textColor,
            NSAttributedString.Key.paragraphStyle:  paraStyle
        ] as [NSAttributedString.Key: Any]
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled  = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        // Session 64/65. Kept, but NOT the fix for David's *"after the first
        // character it auto completes the link"* — that was diagnosed here
        // first and it was wrong. The real cause was the link button inserting
        // a *complete* `[[]]` pair, which made `applyWikilinks` match at one
        // typed character and hide the brackets; see `beginWikilink` below.
        //
        // These two stay disabled on their own merits, matching iOS
        // (`MarkdownEditorView.swift:395`, `autocorrectionType = .no`, comment
        // *"disabled — pill bar is the autocomplete surface"*): the Mac had
        // disabled three of the four members of that family, and these are the
        // ones that complete and rewrite rather than merely flag. Continuous
        // spell *checking* is left on deliberately.
        tv.isAutomaticTextCompletionEnabled  = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.delegate = context.coordinator
        context.coordinator.textView = tv
        tv.onWidthChange = { [weak coord = context.coordinator, weak tv] in
            guard let coord, let tv else { return }
            coord.refreshHorizontalRules(in: tv)
            coord.refreshThumbnails(in: tv)
        }

        // Wire toolbar actions directly to coordinator — no SwiftUI binding round-trip.
        let coord = context.coordinator
        actions.execute = { [weak coord] cmd in
            guard let c = coord, let tv = c.textView else { return }
            c.execute(cmd, in: tv)
        }
        coord.onWikilinkQuery  = onWikilinkQuery
        coord.onWikilinkAccept = onWikilinkAccept
        coord.onMoveRequest    = onMoveRequest
        actions.onMoveRequest  = onMoveRequest
        tv.onPasteImage        = onPasteImage

        let scrollView = NSScrollView()
        scrollView.documentView          = tv
        scrollView.hasVerticalScroller   = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers    = false
        scrollView.backgroundColor       = NSColor.clear
        scrollView.drawsBackground       = false

        if !text.isEmpty {
            storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
            // Explicit: a programmatic `replaceCharacters` does not go through
            // the delegate, so nothing else would style the loaded document now
            // that `processEditing` no longer does.
            storage.applyStyles()
            // `DispatchQueue.main.async`, deliberately, and reverted back to it
            // in Session 65.
            //
            // It was converted to `Task { @MainActor in }` to silence a
            // cross-actor warning on `NoteStore.shared`. That warning is gone by
            // a better route — `readFile`, `resolvedURL` and `findWikilinkMentions`
            // are `nonisolated` now — so the conversion buys nothing.
            //
            // And it is not free. GCD schedules on the runloop; a `Task` runs on
            // the main actor's cooperative executor, which can land at a
            // different point relative to AppKit's own text-input processing.
            // These blocks manipulate the text view — subviews, wikilink state —
            // and a caret bug that appeared the same day as that conversion is
            // not something to leave a rewritten scheduler under. **If it is
            // ever changed again, that is a text-input timing change, not a
            // concurrency tidy-up.**
            DispatchQueue.main.async { [weak coord] in
                guard let c = coord, let tv = c.textView else { return }
                c.refreshHorizontalRules(in: tv)
                c.refreshThumbnails(in: tv)
            }
        }

        return scrollView
    }

    // MARK: updateNSView

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        // Re-wire on every update so the closure always reaches the live coordinator.
        let coord = context.coordinator
        actions.execute = { [weak coord] cmd in
            guard let c = coord, let tv = c.textView else { return }
            c.execute(cmd, in: tv)
        }
        coord.onWikilinkQuery  = onWikilinkQuery
        coord.onWikilinkAccept = onWikilinkAccept
        coord.onMoveRequest    = onMoveRequest
        actions.onMoveRequest  = onMoveRequest
        guard let tv = scrollView.documentView as? MarkdownNSTextView else { return }
        tv.onPasteImage = onPasteImage
        tv.onFocusChange = onFocusChange
        // Before the text guard below, deliberately. The set changes when a new
        // project note appears while the text has not changed at all, and the
        // guard would skip the restyle and leave the link the wrong colour.
        if let storage = tv.textStorage as? MacMarkdownTextStorage,
           storage.noteTitles != noteTitles {
            storage.noteTitles = noteTitles
            storage.applyStyles()
            tv.needsDisplay = true
        }
        guard tv.string != text else { return }
        let savedRange = tv.selectedRange()
        tv.textStorage?.replaceCharacters(
            in: NSRange(location: 0, length: tv.textStorage?.length ?? 0),
            with: text)
        (tv.textStorage as? MacMarkdownTextStorage)?.applyStyles()
        let newLen = tv.textStorage?.length ?? 0
        tv.setSelectedRange(NSRange(location: min(savedRange.location, newLen), length: 0))
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    // MARK: Sizing

    /// Fully flexible: adopt whatever SwiftUI proposes; never report an intrinsic
    /// minimum. Without this, SwiftUI derives sizing from the scroll view's fitting
    /// size, which reads as a wide minimum once the text view has laid out wide and
    /// refuses to compress — pushing sibling columns (e.g. the calendar) off-window.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> NSSize? {
        guard proposal.width != nil || proposal.height != nil else { return nil }
        return NSSize(width: proposal.width ?? nsView.frame.width,
                      height: proposal.height ?? nsView.frame.height)
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        weak var textView: MarkdownNSTextView?
        /// Last known selection — stored here so commands can use it even after focus leaves the text view.
        var lastSelection = NSRange(location: 0, length: 0)
        /// Called when cursor enters/exits a [[...]] span.
        var onWikilinkQuery: ((String?) -> Void)?
        /// Called when user presses Return while a wikilink session is open.
        /// True if a suggestion was applied; false leaves the Return alone.
        var onWikilinkAccept: (() -> Bool)?
        /// Called by .requestMove with (textToMove, remainingContent).
        var onMoveRequest: ((String, String) -> Void)?
        /// Character position of the opening [[ in the active wikilink session.
        private var wikilinkOpenLoc: Int? = nil

        /// Marker subclass for thin NSView separators overlaid on `---` lines.
        private final class HROverlay: NSView {}
        /// Marker subclass for pictures overlaid on `!![desc](path)` lines.
        /// A subclass rather than `tag`, matching `HROverlay` — `NSView.tag` is
        /// a read-only property and overriding it to carry a magic number is a
        /// worse way to say "mine" than a type is.
        private final class ThumbOverlay: NSImageView {
            /// Invisible to the mouse. `isEditable = false` stops an image view
            /// accepting a drop; it does not stop it swallowing clicks, and a
            /// picture that eats the click is a picture you cannot put the
            /// caret next to — so you cannot select the line, and you cannot
            /// delete it with the keyboard. The marker is text and must stay
            /// reachable as text.
            override func hitTest(_ point: NSPoint) -> NSView? { nil }
        }
        /// Decoded images, by container-relative path. Cleared by nothing: a
        /// note holds a handful of pictures and the coordinator dies with the
        /// pane.
        private var thumbCache: [String: NSImage] = [:]
        /// Paths with an iCloud download in flight, so one miss schedules one
        /// retry rather than one per refresh.
        private var thumbRetries: Set<String> = []
        /// Bounded backstop for the case where the view has no width yet.
        private var thumbLayoutRetries: [String: Int] = [:]

        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            // Before styling and before the binding: the substitution changes
            // the text, and both of those want the final version.
            Self.convertTypedCheckbox(in: tv)
            // Reset typing attributes so new text never inherits markdown styles (bold, color, etc.)
            tv.typingAttributes = [
                NSAttributedString.Key.font:            MacMarkdownTextStorage.bodyFont,
                NSAttributedString.Key.foregroundColor: MacMarkdownTextStorage.textColor,
                NSAttributedString.Key.paragraphStyle:  MacMarkdownTextStorage.baseParagraphStyle
            ] as [NSAttributedString.Key: Any]
            // STYLE HERE, not in `MacMarkdownTextStorage.processEditing` — see
            // the long note at the top of that file. Restyling inside the edit
            // cycle gets its `.editedAttributes` notification merged into the
            // user's `.editedCharacters` one, and the layout manager then fixes
            // the selection across the union of both ranges. That is the caret
            // bug, and every symptom of it, in one sentence.
            //
            // Out here it is a second, separate pass carrying attributes alone.
            (tv.textStorage as? MacMarkdownTextStorage)?.applyStyles()
            if text.wrappedValue != tv.string { text.wrappedValue = tv.string }
            // GCD, not `Task` — see the note in `makeNSView`. This is the block
            // that runs on every keystroke, so it is the one where scheduling
            // against AppKit's text input matters most.
            DispatchQueue.main.async { [weak self, weak tv] in
                guard let self, let tv else { return }
                // Force layout for anything the edit left pending.
                //
                // David, after the paragraph-scoped restyle landed: pressing
                // Return at the end of the first row made the LAST row vanish,
                // and double-clicking it brought it back. Double-clicking forces
                // layout, which is the tell — the line's attributes were never
                // wrong, its layout was simply never generated.
                //
                // The insertion shifts every character index after it, and the
                // attribute notification that follows covers only the edited
                // paragraph, so the tail can be left with pending layout that
                // nothing asks for. The final line is the one that shows it,
                // because it has no trailing newline and therefore no following
                // fragment to drag it into being laid out.
                //
                // `ensureLayout` GENERATES pending layout. It does not
                // invalidate, does not touch attributes and does not move the
                // caret — which is what makes it the right tool here after six
                // attempts with `invalidateGlyphs` / `invalidateLayout` /
                // `invalidateDisplay`, every one of which threw something away
                // in order to rebuild it. `refreshHorizontalRules` below has
                // called this for months without incident.
                if let lm = tv.layoutManager, let tc = tv.textContainer {
                    lm.ensureLayout(for: tc)
                }
                // Generate any layout the edit left pending.
                //
                // Safe here in a way it was not before: styling now happens in
                // `textDidChange` rather than inside `processEditing`, so by the
                // time this runs the attribute edit has already been announced
                // over the whole document and the layout it invalidated needs
                // generating rather than replacing. `ensureLayout` only
                // generates — it does not invalidate, touch attributes or move
                // the caret.
                //
                // The symptom it exists for: deleting a blank row could leave
                // the row below it undrawn until clicked, and a click forces
                // layout. `refreshHorizontalRules` has called this for months.
                if let lm = tv.layoutManager, let tc = tv.textContainer {
                    lm.ensureLayout(for: tc)
                }
                // REDRAW THE VIEW, not a character range.
                //
                // Instrumented rather than guessed, 2026-08-04. Deleting the
                // blank row between a title and a checkbox line drew the
                // checkbox row TWICE, and the log said:
                //
                //   chars=55 lines=5 laidOutChars=0..<55 usedH=128 frameH=919
                //
                // Two copies of that line cannot fit in 55 characters, and the
                // document was fully laid out in 128pt of a 919pt frame. **The
                // duplicate was never in the document.** It was the pixels of
                // the row's previous position, never repainted after the text
                // above it shrank.
                //
                // That is also why `invalidateDisplay(forCharacterRange:)` did
                // nothing when it was tried: it can only dirty the area a
                // character range currently occupies, and stale pixels sit where
                // characters USED to be — below the used rect, mapped to no
                // character at all. Only a view-level redraw reaches them.
                //
                // The same mechanism, in the other direction, is the "row goes
                // missing" symptom: the row is drawn where it no longer is, and
                // blank where it now is.
                //
                // Cheap: `usedH` is ~128pt for a real note, and AppKit coalesces
                // this to one repaint per runloop turn. It touches neither
                // layout, attributes, nor the selection.
                tv.needsDisplay = true
                self.refreshHorizontalRules(in: tv)
                self.refreshThumbnails(in: tv)
                self.checkForWikilink(in: tv)
                // Order matters: `checkForWikilink` is what sets `wikilinkOpenLoc`
                // for the text as it stands now, and the converter reads it.
                // Text-change path only — mutating the storage from inside
                // `textViewDidChangeSelection` is how you get re-entrancy.
                self.convertURLWikilink(in: tv)
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            // Only snapshot the selection while the text view actually owns focus.
            // When the user clicks a toolbar button macOS collapses the selection
            // *before* the button action fires — if we saved that we'd lose the range.
            if tv.window?.firstResponder === tv {
                lastSelection = tv.selectedRange()
            }
            checkForWikilink(in: tv)
        }

        // MARK: - Thumbnail overlays
        //
        // Session 65. A port of iOS `refreshThumbnails`, including the bug it
        // documents, because the bug is a property of the approach rather than
        // of UIKit and would have been rewritten here otherwise.
        //
        // Overlays are subviews of the text view, which is the scroll view's
        // document view, so their frames are in content coordinates and they
        // scroll with the text for free. Same as iOS, where the text view is
        // itself a scroll view.

        /// Draws a picture over every `!![desc](path)` line.
        ///
        /// Called after every text change, once on load, and on width change.
        func refreshThumbnails(in tv: NSTextView) {
            tv.subviews
                .compactMap { $0 as? ThumbOverlay }
                .forEach { $0.removeFromSuperview() }

            guard tv.string.contains("!!["),
                  let regex = try? NSRegularExpression(
                      pattern: #"^!!\[([^\]]*)\]\(([^)]+)\)"#,
                      options: .anchorsMatchLines),
                  let lm = tv.layoutManager,
                  let tc = tv.textContainer else { return }

            let ns = tv.string as NSString
            let matches = regex.matches(in: tv.string,
                                        range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { return }
            lm.ensureLayout(for: tc)

            // WIDTH COMES FROM THE VIEW, NOT FROM THE LINE.
            //
            // iOS measured this from `boundingRect(forGlyphRange:)` and spent
            // two days on the consequence. That rect means two different things
            // depending on where the line sits: with a line terminator in the
            // glyph range it spans the whole fragment, i.e. the container width,
            // which is right by accident. **The last line of a document has no
            // terminator**, so the rect collapses to the tight bounds of the
            // glyphs — and every glyph on a thumbnail line is deliberately
            // hidden behind a 0.01pt font. Near-zero width, zero-size image
            // view, invisible picture, while the reserved 200pt line and the
            // click target stay exactly where they were.
            //
            // The observation that identified it was David's: adding a second
            // photo brought the first one back and hid the new one. *"like the
            // bug switched spots."* Nothing about a layout race explains that.
            //
            // `refreshHorizontalRules` below already measures from `tv.bounds`,
            // for the same reason.
            let padding = tc.lineFragmentPadding
            let available = tv.bounds.width
                - tv.textContainerInset.width * 2
                - padding * 2

            for match in matches {
                guard match.range(at: 2).location != NSNotFound else { continue }
                let path = ns.substring(with: match.range(at: 2))

                guard available > 2 else {
                    // No frame yet. `onWidthChange` is the real answer and calls
                    // back when there is one; this is a bounded backstop so a
                    // host that never resizes still lands.
                    let n = thumbLayoutRetries[path, default: 0]
                    if n < 3 {
                        thumbLayoutRetries[path] = n + 1
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak tv] in
                            guard let self, let tv else { return }
                            self.refreshThumbnails(in: tv)
                        }
                    }
                    continue
                }
                thumbLayoutRetries[path] = nil

                guard let image = thumbImage(at: path, in: tv) else { continue }

                let lineCharRange = ns.lineRange(for: match.range)
                let glyphRange = lm.glyphRange(forCharacterRange: lineCharRange,
                                               actualCharacterRange: nil)
                var lineRect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
                lineRect = lineRect.offsetBy(dx: tv.textContainerInset.width,
                                             dy: tv.textContainerInset.height)

                // 196 against the 200 reserved, so the picture never touches the
                // lines above and below it. `1.0` in the min so a small image is
                // shown at its own size rather than blown up into mush.
                let maxHeight: CGFloat = 196
                let scale = min(available / image.size.width,
                                maxHeight / image.size.height,
                                1.0)
                let size = NSSize(width:  image.size.width  * scale,
                                  height: image.size.height * scale)

                let iv = ThumbOverlay(frame: NSRect(
                    x: tv.textContainerInset.width + padding,
                    y: lineRect.origin.y + (lineRect.height - size.height) / 2,
                    width:  size.width,
                    height: size.height))
                iv.image = image
                iv.imageScaling = .scaleProportionallyUpOrDown
                iv.wantsLayer = true
                iv.layer?.cornerRadius = 6
                iv.layer?.masksToBounds = true
                // Non-interactive: clicks fall through to the text view, which
                // is what puts the caret on the line so the marker can be
                // selected and deleted like any other text. A picture you
                // cannot delete with the keyboard would be worse than no
                // picture.
                iv.isEditable = false
                tv.addSubview(iv)
            }
        }

        /// The image at a container path, waiting out iCloud when it has to.
        ///
        /// Same staircase as the document preview and the endeavor cover: try
        /// the direct read, and only if that fails start the download and
        /// schedule ONE retry. A permanent placeholder for a file that is on its
        /// way is the wrong answer, and so is a retry per refresh.
        private func thumbImage(at path: String, in tv: NSTextView) -> NSImage? {
            if let cached = thumbCache[path] { return cached }
            guard let url = NoteStore.shared.resolvedURL(for: path) else { return nil }
            if let data = try? Data(contentsOf: url), let image = NSImage(data: data) {
                thumbCache[path] = image
                return image
            }
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            if !thumbRetries.contains(path) {
                thumbRetries.insert(path)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self, weak tv] in
                    guard let self else { return }
                    self.thumbRetries.remove(path)
                    if let tv { self.refreshThumbnails(in: tv) }
                }
            }
            return nil
        }

        // MARK: - Horizontal rule overlay

        func refreshHorizontalRules(in tv: NSTextView) {
            tv.subviews
                .compactMap { $0 as? HROverlay }
                .forEach { $0.removeFromSuperview() }

            guard tv.string.contains("---"),
                  let lm = tv.layoutManager,
                  let tc = tv.textContainer else { return }
            lm.ensureLayout(for: tc)

            let ns = tv.string as NSString
            var pos = 0
            while pos < ns.length {
                let lineRange = ns.lineRange(for: NSRange(location: pos, length: 0))
                guard lineRange.length > 0 else { break }
                let line = ns.substring(with: lineRange)
                if line.trimmingCharacters(in: .whitespacesAndNewlines) == "---" {
                    let glyphRange = lm.glyphRange(forCharacterRange: lineRange,
                                                   actualCharacterRange: nil)
                    let lineRect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
                    let insetW = tv.textContainerInset.width
                    let insetH = tv.textContainerInset.height
                    let midY   = lineRect.origin.y + lineRect.height / 2 + insetH
                    let xLeft  = insetW + 16
                    let xRight = tv.bounds.width - insetW - 16

                    let rule = HROverlay(frame: NSRect(x: xLeft, y: midY - 0.5,
                                                       width: max(0, xRight - xLeft), height: 1.0))
                    rule.wantsLayer = true
                    // Session 64: was NSColor(white: 0.45), a frozen grey that
                    // ignored appearance and was legible in dark by luck. This is
                    // the case that ruled out `@Environment(\.colorScheme)` for the
                    // palette — an AppKit overlay has no SwiftUI environment to
                    // read. `tertiaryLabelColor` rather than `separatorColor`: a
                    // markdown rule is content, and separator weight is a hairline.
                    // Swap if it reads heavy.
                    rule.layer?.backgroundColor = NSColor.tertiaryLabelColor.cgColor
                    tv.addSubview(rule)
                }
                pos = lineRange.location + lineRange.length
            }
        }

        // MARK: - Wikilink autocomplete detection

        private func checkForWikilink(in tv: NSTextView) {
            let cursorLoc = tv.selectedRange().location
            let ns = tv.string as NSString

            // Only check within the current line
            let lineRange = ns.lineRange(for: NSRange(location: cursorLoc, length: 0))
            let lineStart = lineRange.location
            guard cursorLoc > lineStart + 1 else {
                endWikilinkSession()
                return
            }

            // Scan backward from cursor on this line for [[
            let beforeCursor = ns.substring(with: NSRange(location: lineStart,
                                                          length: cursorLoc - lineStart))
            let bns = beforeCursor as NSString

            var scanIdx = bns.length - 2
            var found: (openLoc: Int, partial: String)? = nil
            while scanIdx >= 0 {
                if bns.character(at: scanIdx)     == 91 &&   // '['
                   bns.character(at: scanIdx + 1) == 91 {   // '['
                    let partial = bns.substring(from: scanIdx + 2)
                    if !partial.contains("]]") && !partial.contains("\n") {
                        found = (lineStart + scanIdx, partial)
                    }
                    break
                }
                scanIdx -= 1
            }

            if let ctx = found {
                wikilinkOpenLoc = ctx.openLoc
                onWikilinkQuery?(ctx.partial)
            } else {
                endWikilinkSession()
            }
        }

        private func endWikilinkSession() {
            guard wikilinkOpenLoc != nil else { return }
            wikilinkOpenLoc = nil
            onWikilinkQuery?(nil)
        }

        /// `[[` followed by a URL is not a wikilink and never becomes one.
        ///
        /// David: *"when i click the link in the editor, two brackets appear but
        /// it doesnt format the link like it does in IOS."* The note on disk read
        /// `[[https://www.zola.com/wedding/lahaieweiss/poi` — unclosed, under
        /// `## Reference`, with no `]]` anywhere on the line.
        ///
        /// That is `beginWikilink` working exactly as designed, meeting an input
        /// it was never designed for. The button opens a *session*: it writes
        /// `[[` and leaves the closing pair to `applyWikiSuggestion`, because
        /// Session 65 established that a wikilink is not finished until a name is
        /// chosen. Paste a URL and no name is ever chosen, so the `]]` never
        /// arrives and the `[[` sits there permanently.
        ///
        /// **The phone hides this rather than solving it.** Its button writes the
        /// finished `[[]]` up front, so a pasted URL lands as `[[https://…]]` —
        /// closed, painted blue, and a wikilink to a note that cannot exist. It
        /// looks right and does nothing when tapped.
        ///
        /// So neither platform's answer was actually a link. A URL wants
        /// markdown's own form, `[label](url)`, which `applyMarkdownLinks` already
        /// renders on both sides: label in link colour, brackets and URL hidden,
        /// genuinely clickable. The conversion fires the moment a scheme shows up
        /// after `[[`, leaves the caret in the empty label so the next thing typed
        /// is the link text, and closes the suggestion list.
        ///
        /// Keying on `://` is safe: no place, person or note title in this vault
        /// contains one, and a title that did could not be opened as a wikilink
        /// anyway.
        @discardableResult
        private func convertURLWikilink(in tv: NSTextView) -> Bool {
            guard let openLoc = wikilinkOpenLoc, let storage = tv.textStorage else { return false }
            let ns = tv.string as NSString
            let cursorLoc = tv.selectedRange().location
            guard cursorLoc > openLoc + 2, cursorLoc <= ns.length else { return false }
            let partial = ns.substring(with: NSRange(location: openLoc + 2,
                                                     length: cursorLoc - openLoc - 2))
            guard partial.contains("://") else { return false }

            let url = partial.trimmingCharacters(in: .whitespaces)
            guard !url.isEmpty else { return false }
            // A real label, not an empty one — `applyMarkdownLinks` needs at
            // least one character or the whole thing renders as raw markdown.
            let label = NoteStore.linkLabel(for: url)
            let replacement = "[\(label)](\(url))"
            storage.replaceCharacters(in: NSRange(location: openLoc, length: cursorLoc - openLoc),
                                      with: replacement)
            tv.didChangeText()
            // The label is SELECTED, not an empty caret: leave it and you have a
            // link that reads `zola.com`, type and you have replaced it.
            tv.setSelectedRange(NSRange(location: openLoc + 1,
                                        length: (label as NSString).length))
            text.wrappedValue = tv.string
            endWikilinkSession()
            return true
        }

        private func applyWikiSuggestion(_ name: String, in tv: NSTextView) {
            let cursorLoc = tv.selectedRange().location
            guard let openLoc = wikilinkOpenLoc, openLoc <= cursorLoc else { return }
            let replaceRange = NSRange(location: openLoc, length: cursorLoc - openLoc)
            let replacement  = "[[\(name)]]"
            tv.textStorage?.replaceCharacters(in: replaceRange, with: replacement)
            tv.didChangeText()
            let newLoc = openLoc + (replacement as NSString).length
            tv.setSelectedRange(NSRange(location: newLoc, length: 0))
            text.wrappedValue = tv.string
            wikilinkOpenLoc = nil
            onWikilinkQuery?(nil)
        }

        // MARK: Smart keyboard — auto-list continuation and dash-to-bullet conversion

        func textView(_ tv: NSTextView,
                      shouldChangeTextIn affectedCharRange: NSRange,
                      replacementString replacement: String?) -> Bool {
            guard let replacement else { return true }
            let ns = tv.string as NSString
            let lineRange = ns.lineRange(for: NSRange(location: affectedCharRange.location, length: 0))
            let line = ns.substring(with: lineRange)

            // ── Typing third "-" to complete "---" → create HR and move cursor below ──
            let lineWithoutNewline0 = line.hasSuffix("\n") ? String(line.dropLast()) : line
            if replacement == "-" && lineWithoutNewline0 == "--" {
                tv.textStorage?.replaceCharacters(in: affectedCharRange, with: "-\n")
                tv.didChangeText()
                tv.setSelectedRange(NSRange(location: affectedCharRange.location + 2, length: 0))
                text.wrappedValue = tv.string
                return false
            }

            // ── Tab: indent line ──────────────────────────────────────────────────
            if replacement == "\t" {
                tv.textStorage?.replaceCharacters(in: lineRange, with: "  " + line)
                tv.didChangeText()
                tv.setSelectedRange(NSRange(location: affectedCharRange.location + 2, length: 0))
                return false
            }

            // ── Space after lone "-" at line start → bullet ───────────────────────
            // Checks the character immediately before the cursor is "-" and everything
            // before it on the line is spaces. Handles both mid-doc and last-line cases.
            if replacement == " " && affectedCharRange.location > 0 {
                let dashPos = affectedCharRange.location - 1
                let charBefore = ns.character(at: dashPos)
                if charBefore == UInt16(UnicodeScalar("-").value) {
                    let lineStart = lineRange.location
                    if dashPos >= lineStart {
                        let prefix = ns.substring(with: NSRange(location: lineStart,
                                                                length: dashPos - lineStart))
                        if prefix.allSatisfy({ $0 == " " }) {
                            tv.textStorage?.replaceCharacters(
                                in: NSRange(location: dashPos, length: 1), with: "\u{2022}")
                            tv.didChangeText()
                            return true   // let the space insert normally
                        }
                    }
                }
            }

            // ── Return while wikilink session active → accept top suggestion ──────
            //
            // Only swallow the Return if something was actually accepted. A
            // session is open from the moment `[[` exists, including while the
            // query is still empty, and unconditionally returning false there
            // meant Return did nothing at all and said nothing — the same
            // silent-no-op shape as the visit date picker.
            if replacement == "\n" && wikilinkOpenLoc != nil {
                if onWikilinkAccept?() == true { return false }
            }

            // ── Return key: continue or exit list ─────────────────────────────────
            guard replacement == "\n" else { return true }

            // RETURN AT THE START OF A LINE PUSHES IT DOWN. It does not start a
            // new list item.
            //
            // David, 2026-08-03: *"I went to the beginning of the top row before
            // the checkbox and hit enter and it added an extra check box for
            // some reason rather than just moving it down a row."*
            //
            // All three continuations below test the LINE for a marker and never
            // asked where the caret is. With the caret at offset 0 of
            // `☐ Facetime…` the checkbox branch saw a non-empty checkbox line,
            // inserted `"\n☐ "` at the caret, and produced a stray `☐ ` on the
            // new empty line above. Bullets and dashes had the identical flaw.
            //
            // Continuation means "I finished this item, give me the next one",
            // which cannot be true when nothing on the line is behind the caret.
            // Mid-line and end-of-line behaviour is unchanged: splitting a list
            // item still carries the marker onto the second half, which is what
            // every markdown editor does.
            guard affectedCharRange.location > lineRange.location else { return true }

            let lineWithoutNewline = line.hasSuffix("\n") ? String(line.dropLast()) : line

            // Bullet continuation
            let bulletPrefix = "\u{2022} "
            if let bulletRange = lineWithoutNewline.range(of: bulletPrefix) {
                let indent = String(lineWithoutNewline[lineWithoutNewline.startIndex..<bulletRange.lowerBound])
                let afterBullet = lineWithoutNewline[bulletRange.upperBound...]
                if afterBullet.trimmingCharacters(in: .whitespaces).isEmpty {
                    // Empty bullet — exit list
                    tv.textStorage?.replaceCharacters(in: lineRange, with: "\n")
                    tv.didChangeText()
                    tv.setSelectedRange(NSRange(location: lineRange.location + 1, length: 0))
                } else {
                    // Continue bullet
                    let insert = "\n" + indent + bulletPrefix
                    tv.textStorage?.replaceCharacters(in: affectedCharRange, with: insert)
                    tv.didChangeText()
                    tv.setSelectedRange(NSRange(location: affectedCharRange.location + (insert as NSString).length,
                                                length: 0))
                }
                text.wrappedValue = tv.string
                return false
            }

            // Dash list continuation ("- item")
            if let dashRange = lineWithoutNewline.range(of: "- ") {
                let prefixSlice = lineWithoutNewline[lineWithoutNewline.startIndex..<dashRange.lowerBound]
                guard prefixSlice.allSatisfy({ $0 == " " }) else { return true }
                let indent = String(prefixSlice)
                let afterDash = lineWithoutNewline[dashRange.upperBound...]
                if afterDash.trimmingCharacters(in: .whitespaces).isEmpty {
                    tv.textStorage?.replaceCharacters(in: lineRange, with: "\n")
                    tv.didChangeText()
                    tv.setSelectedRange(NSRange(location: lineRange.location + 1, length: 0))
                } else {
                    let insert = "\n" + indent + "- "
                    tv.textStorage?.replaceCharacters(in: affectedCharRange, with: insert)
                    tv.didChangeText()
                    tv.setSelectedRange(NSRange(location: affectedCharRange.location + (insert as NSString).length,
                                                length: 0))
                }
                text.wrappedValue = tv.string
                return false
            }

            // Checkbox continuation
            let checkPrefixes = ["☐ ", "☑ "]
            for prefix in checkPrefixes {
                if lineWithoutNewline.hasPrefix(prefix) {
                    let afterCheck = lineWithoutNewline.dropFirst(prefix.count)
                    if afterCheck.trimmingCharacters(in: .whitespaces).isEmpty {
                        tv.textStorage?.replaceCharacters(in: lineRange, with: "\n")
                        tv.didChangeText()
                        tv.setSelectedRange(NSRange(location: lineRange.location + 1, length: 0))
                    } else {
                        let insert = "\n☐ "
                        tv.textStorage?.replaceCharacters(in: affectedCharRange, with: insert)
                        tv.didChangeText()
                        tv.setSelectedRange(NSRange(location: affectedCharRange.location + (insert as NSString).length,
                                                    length: 0))
                    }
                    text.wrappedValue = tv.string
                    return false
                }
            }

            return true
        }

        // MARK: Command execution

        func execute(_ command: MacEditorCommand, in tv: NSTextView) {
            switch command {
            case .bold:      wrapSelection("**", in: tv)
            case .italic:    wrapSelection("*", in: tv)
            case .strike:    wrapSelection("~~", in: tv)
            case .highlight: wrapSelection("==", in: tv)
            case .link:      beginWikilink(in: tv)
            case .heading:   toggleLinePrefix("## ", in: tv)
            case .bullet:    toggleBullet(in: tv)
            case .checkbox:  toggleCheckbox(in: tv)
            case .indent:    indentLine(in: tv)
            case .outdent:   outdentLine(in: tv)
            case .date:      insertDate(in: tv)
            case .timestamp: insertTimestamp(in: tv)
            case .requestMove: requestMove(in: tv)
            case .undo:      tv.undoManager?.undo()
            case .redo:      tv.undoManager?.redo()
            case .applyWikiSuggestion(let name): applyWikiSuggestion(name, in: tv)
            case .insertText(let raw): insertText(raw, in: tv)
            }
        }

        /// Wraps the selection (or inserts an empty pair) in a symmetric marker.
        /// The asymmetric `closing:` parameter was removed in Session 65 when
        /// `.link` stopped being a caller — it had no other one, and a spare
        /// parameter is an invitation to build the bug `beginWikilink` fixed.
        private func wrapSelection(_ marker: String, in tv: NSTextView) {
            let close   = marker
            let range   = lastSelection
            guard let storage = tv.textStorage else { return }
            if range.length == 0 {
                let pair = marker + close
                storage.replaceCharacters(in: range, with: pair)
                tv.didChangeText()
                let newLoc = range.location + (marker as NSString).length
                tv.setSelectedRange(NSRange(location: newLoc, length: 0))
            } else if let swiftRange = Range(range, in: storage.string) {
                let selected = String(storage.string[swiftRange])
                storage.replaceCharacters(in: range, with: marker + selected + close)
                tv.didChangeText()
            }
            text.wrappedValue = storage.string
        }

        /// The link button, Session 65.
        ///
        /// David: *"when i press the link button in the editor, i can start
        /// typing but after the first character it auto completes the link."*
        ///
        /// It was never autocomplete. The button used to insert the finished
        /// pair `[[]]` and drop the cursor in the middle, so the very first
        /// character typed produced `[[M]]` — five characters, which is exactly
        /// `applyWikilinks`' `m.range.length >= 5` threshold. The storage then
        /// did what it is supposed to do to a complete wikilink: hid `[[` and
        /// `]]` behind `hiddenFont` and painted the middle in link colour. One
        /// keystroke, and the link looked finished.
        ///
        /// The phone never had this because on the phone you type `[[`
        /// yourself and there is no closing pair until a suggestion is
        /// accepted, so the regex cannot match while you are still typing. So
        /// the button now opens a session rather than writing a link:
        /// `applyWikiSuggestion` supplies the `]]` when a name is chosen, which
        /// is the one moment the link genuinely is complete.
        ///
        /// A non-empty selection still wraps to a finished `[[name]]`, because
        /// there the name is already known and rendering it immediately is
        /// correct rather than premature.
        ///
        /// **Session 67 — the button now recognises a URL.** Two cases that used
        /// to produce a wikilink to a page that cannot exist:
        ///
        /// - the selection *is* a URL, which becomes `[](url)` with the caret in
        ///   the empty label;
        /// - the selection is text and the clipboard holds a URL, which becomes
        ///   `[selection](url)` — the paste-a-link-onto-words gesture every other
        ///   Mac editor has.
        ///
        /// Everything else is unchanged: known name wraps, empty selection opens a
        /// session.
        private func beginWikilink(in tv: NSTextView) {
            guard let storage = tv.textStorage else { return }
            let range = lastSelection
            let clipboard = NSPasteboard.general.string(forType: .string)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if range.length > 0, let swiftRange = Range(range, in: storage.string) {
                let selected = String(storage.string[swiftRange])
                if selected.contains("://") {
                    let url   = selected.trimmingCharacters(in: .whitespaces)
                    let label = NoteStore.linkLabel(for: url)
                    let link  = "[\(label)](\(url))"
                    storage.replaceCharacters(in: range, with: link)
                    tv.didChangeText()
                    tv.setSelectedRange(NSRange(location: range.location + 1,
                                                length: (label as NSString).length))
                    text.wrappedValue = storage.string
                    return
                }
                if clipboard.contains("://"), !clipboard.contains(" ") {
                    let link = "[\(selected)](\(clipboard))"
                    storage.replaceCharacters(in: range, with: link)
                    tv.didChangeText()
                    tv.setSelectedRange(NSRange(location: range.location + (link as NSString).length,
                                                length: 0))
                    text.wrappedValue = storage.string
                    return
                }
                storage.replaceCharacters(in: range, with: "[[" + selected + "]]")
                tv.didChangeText()
            } else {
                storage.replaceCharacters(in: range, with: "[[")
                tv.didChangeText()
                tv.setSelectedRange(NSRange(location: range.location + 2, length: 0))
            }
            text.wrappedValue = storage.string
        }

        /// Inserts text at the cursor, on its own line when it needs one.
        ///
        /// A `!![…]` marker is only recognised at the start of a line, so
        /// inserting one mid-sentence would write a marker that never renders
        /// and never says why. The trailing newline is not cosmetic either: a
        /// marker on the final line of the file has no line terminator, and
        /// that is the bug iOS spent two days on — see `refreshThumbnails`.
        private func insertText(_ raw: String, in tv: NSTextView) {
            guard let storage = tv.textStorage else { return }
            let ns = storage.string as NSString
            let loc = min(lastSelection.location, ns.length)
            let atLineStart = loc == 0 || ns.character(at: loc - 1) == 10   // newline
            let block = (atLineStart ? "" : "\n") + raw + "\n"
            storage.replaceCharacters(in: NSRange(location: loc, length: 0), with: block)
            tv.didChangeText()
            tv.setSelectedRange(NSRange(location: loc + (block as NSString).length, length: 0))
            text.wrappedValue = storage.string
        }

        private func toggleLinePrefix(_ prefix: String, in tv: NSTextView) {
            guard let storage = tv.textStorage else { return }
            let ns        = storage.string as NSString
            let lineRange = ns.lineRange(for: NSRange(location: lastSelection.location, length: 0))
            let line      = ns.substring(with: lineRange)
            if line.hasPrefix(prefix) {
                storage.replaceCharacters(in: lineRange, with: String(line.dropFirst(prefix.count)))
                tv.didChangeText()
                let newLoc = max(lineRange.location, lastSelection.location - (prefix as NSString).length)
                tv.setSelectedRange(NSRange(location: newLoc, length: 0))
            } else {
                storage.replaceCharacters(in: lineRange, with: prefix + line)
                tv.didChangeText()
                tv.setSelectedRange(NSRange(location: lastSelection.location + (prefix as NSString).length,
                                            length: 0))
            }
            text.wrappedValue = storage.string
        }

        private func toggleBullet(in tv: NSTextView) {
            guard let storage = tv.textStorage else { return }
            let ns        = storage.string as NSString
            let lineRange = ns.lineRange(for: NSRange(location: lastSelection.location, length: 0))
            let line      = ns.substring(with: lineRange)
            let bullet    = "\u{2022} "
            if line.hasPrefix(bullet) {
                storage.replaceCharacters(in: lineRange, with: String(line.dropFirst(2)))
                tv.didChangeText()
                let newLoc = max(lineRange.location, lastSelection.location - 2)
                tv.setSelectedRange(NSRange(location: newLoc, length: 0))
            } else {
                storage.replaceCharacters(in: lineRange, with: bullet + line)
                tv.didChangeText()
                tv.setSelectedRange(NSRange(location: lastSelection.location + 2, length: 0))
            }
            text.wrappedValue = storage.string
        }

        private func toggleCheckbox(in tv: NSTextView) {
            guard let storage = tv.textStorage else { return }
            let ns        = storage.string as NSString
            let lineRange = ns.lineRange(for: NSRange(location: lastSelection.location, length: 0))
            let line      = ns.substring(with: lineRange)
            if line.hasPrefix("☑ ") {
                storage.replaceCharacters(in: lineRange, with: "☐ " + String(line.dropFirst(2)))
                tv.didChangeText()
                tv.setSelectedRange(NSRange(location: lastSelection.location, length: 0))
            } else if line.hasPrefix("☐ ") {
                storage.replaceCharacters(in: lineRange, with: String(line.dropFirst(2)))
                tv.didChangeText()
                let newLoc = max(lineRange.location, lastSelection.location - 2)
                tv.setSelectedRange(NSRange(location: newLoc, length: 0))
            } else {
                storage.replaceCharacters(in: lineRange, with: "☐ " + line)
                tv.didChangeText()
                tv.setSelectedRange(NSRange(location: lastSelection.location + 2, length: 0))
            }
            text.wrappedValue = storage.string
        }

        private func indentLine(in tv: NSTextView) {
            guard let storage = tv.textStorage else { return }
            let ns        = storage.string as NSString
            let lineRange = ns.lineRange(for: NSRange(location: lastSelection.location, length: 0))
            let line      = ns.substring(with: lineRange)
            storage.replaceCharacters(in: lineRange, with: "  " + line)
            tv.didChangeText()
            tv.setSelectedRange(NSRange(location: lastSelection.location + 2, length: 0))
            text.wrappedValue = storage.string
        }

        private func outdentLine(in tv: NSTextView) {
            guard let storage = tv.textStorage else { return }
            let ns        = storage.string as NSString
            let lineRange = ns.lineRange(for: NSRange(location: lastSelection.location, length: 0))
            let line      = ns.substring(with: lineRange)
            let toRemove  = line.hasPrefix("  ") ? 2 : (line.hasPrefix(" ") ? 1 : 0)
            guard toRemove > 0 else { return }
            storage.replaceCharacters(in: lineRange, with: String(line.dropFirst(toRemove)))
            tv.didChangeText()
            let newLoc = max(lineRange.location, lastSelection.location - toRemove)
            tv.setSelectedRange(NSRange(location: newLoc, length: 0))
            text.wrappedValue = storage.string
        }

        private func insertDate(in tv: NSTextView) {
            guard let storage = tv.textStorage else { return }
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.dateFormat = "MMMM d, yyyy"
            let str   = fmt.string(from: Date()) + " "
            let range = lastSelection
            storage.replaceCharacters(in: range, with: str)
            tv.didChangeText()
            tv.setSelectedRange(NSRange(location: range.location + (str as NSString).length, length: 0))
            text.wrappedValue = storage.string
        }

        private func insertTimestamp(in tv: NSTextView) {
            guard let storage = tv.textStorage else { return }
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.dateFormat = "h:mm a"
            let timeStr = fmt.string(from: Date())
            let insert  = "\n\n**\(timeStr)**\n\n"
            // Insert at end of document
            let endLoc = storage.length
            storage.replaceCharacters(in: NSRange(location: endLoc, length: 0), with: insert)
            tv.didChangeText()
            let newLoc = endLoc + (insert as NSString).length
            tv.setSelectedRange(NSRange(location: newLoc, length: 0))
            tv.scrollRangeToVisible(NSRange(location: newLoc, length: 0))
            text.wrappedValue = storage.string
        }

        private func requestMove(in tv: NSTextView) {
            let sel = lastSelection
            let fullText = tv.string
            if sel.length > 0, let r = Range(sel, in: fullText) {
                let selected  = String(fullText[r])
                let remaining = fullText.replacingCharacters(in: r, with: "")
                onMoveRequest?(selected, remaining)
            } else {
                onMoveRequest?(fullText, "")
            }
        }
    }
}

