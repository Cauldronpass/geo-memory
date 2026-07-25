import SwiftUI
import UIKit
import Foundation

// MARK: - DayflowNLHighlightField
//
// The quick-add sheet's natural-language text field. Mirrors Dayflow-Mockup.html's
// `renderNLHighlight()` — recognized date phrases and a trailing "/List" token
// highlight live as you type — but uses real detection instead of the mockup's
// illustrative regex-only demo:
//   - Dates: NSDataDetector(.date), per Dayflow-Design-Plan.md's explicit
//     recommendation ("same underlying tech as Messages/Mail's date-suggestion
//     banners"). Returns a real `Date`, not just a highlighted label.
//   - List token: "/" through the end of the line, same convention as the
//     mockup — real area names have emoji + spaces ("🏡Home and Household"),
//     so a token can't be split on whitespace. Uses the LAST "/" in the text,
//     not the first (see the 2026-07-19 addendum below) — a task has exactly
//     one list, so if you manually type a second "/token" it should win, not
//     get appended to the first one.
//
// A UIViewRepresentable wrapping UITextView (not TextField) because live
// per-character attributed-string highlighting while preserving cursor
// position isn't something SwiftUI's TextField exposes directly.
//
// Cursor-jump bug history (2026-07-19): the first implementation re-highlighted
// on every keystroke by reassigning `textView.attributedText` wholesale, which
// resets `selectedRange` to 0 as a side effect. A re-entrancy guard +
// `DispatchQueue.main.async` cursor restore was tried first and did NOT fix it.
// The real fix, used below, mirrors Trace's own `MarkdownTextStorage.swift`
// pattern (see its header comment: "applyStyles() modifies backing directly,
// never self, to avoid re-entrant processEditing calls"): edit
// `textView.textStorage` in place via
// beginEditing()/setAttributes/addAttributes/endEditing() instead of ever
// reassigning `.attributedText`. This part of the bug turned out to be a red
// herring for the specific "EnewR" repro (root cause was a keyboard-toolbar
// item gated on focus state in DayflowQuickAddSheet, since fixed there), but
// the in-place textStorage edit is still the correct approach for this kind
// of live-highlight-while-typing view and is kept regardless.
//
// Quick-insert accessory bar (2026-07-19, second addendum): originally shown
// via a SwiftUI `ToolbarItemGroup(placement: .keyboard)` in
// DayflowQuickAddSheet, gated on a manually-tracked `fieldFocused` @State bool
// fed by this view's `onFocusChange`. That never reliably appeared — SwiftUI's
// `.toolbar(placement: .keyboard)` is designed around SwiftUI's own
// `@FocusState`-managed focus, and this field's focus is tracked entirely
// through UIKit's responder chain (`textViewDidBeginEditing`/`didEndEditing`)
// instead, so SwiftUI had no reliable signal that a keyboard-eligible view was
// active. Fixed by attaching the accessory bar directly to the underlying
// `UITextView.inputAccessoryView` instead — a native UIKit mechanism tied
// directly to this specific view becoming first responder, independent of
// SwiftUI's focus-state plumbing entirely.
//
// Height sizing (2026-07-19, third addendum): first tried reporting the
// content height via the `sizeThatFits(_:uiView:context:)` UIViewRepresentable
// hook. That fixed the *idle* size (Task mode's field no longer stretched to
// fill the leftover VStack space left by the collapsed Details row), but broke
// again specifically at the moment the field gained focus and the keyboard
// slid up — a one-off layout pass with its own proposal/timing quirks that
// `sizeThatFits` doesn't handle reliably here. Replaced with a fully
// deterministic approach instead: the coordinator computes the real content
// height itself off `UITextView.sizeThatFits` and reports it through an
// explicit `height` binding, which the caller applies as a plain
// `.frame(height:)`. This doesn't depend on SwiftUI's layout-proposal
// negotiation at all, so it can't be disrupted by whatever's happening during
// the keyboard's show/hide transition.

struct DayflowNLHighlightField: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String
    /// Fires whenever parsing finds a date phrase or list token (or loses one).
    /// `date` is nil if no recognizable date phrase is present; `list` is nil
    /// if no trailing "/token" is present.
    var onParse: (_ date: Date?, _ list: String?) -> Void
    var onFocusChange: ((Bool) -> Void)? = nil
    /// Content shown docked above the keyboard while this field is focused
    /// (the "Quick insert" area chips in Task mode). Pass nil to show no
    /// accessory (e.g. Event mode, which has no list concept). Set as the
    /// UITextView's own `inputAccessoryView` — see header note above for why.
    var accessoryContent: AnyView? = nil
    /// The field's actual content height, kept in sync by the coordinator.
    /// Apply as `.frame(height: height)` at the call site — see header note.
    @Binding var height: CGFloat

    static let dateColor = UIColor(red: 47/255, green: 111/255, blue: 237/255, alpha: 1)
    static let dateBG    = UIColor(red: 47/255, green: 111/255, blue: 237/255, alpha: 0.12)
    static let listColor = UIColor(red: 31/255, green: 158/255, blue: 109/255, alpha: 1)
    static let listBG    = UIColor(red: 31/255, green: 158/255, blue: 109/255, alpha: 0.12)
    static let minHeight: CGFloat = 22

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.delegate = context.coordinator
        tv.font = UIFont.preferredFont(forTextStyle: .body)
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.isScrollEnabled = false
        tv.autocorrectionType = .default
        tv.autocapitalizationType = .sentences
        context.coordinator.placeholderLabel = {
            let l = UILabel()
            l.font = tv.font
            l.textColor = .placeholderText
            l.text = placeholder
            l.numberOfLines = 1
            tv.addSubview(l)
            return l
        }()
        // Set the raw text first (plain, no attributes) so the storage's
        // string content matches `text` before we do any in-place attribute
        // editing — applyHighlight assumes the content is already correct.
        tv.text = text
        context.coordinator.applyHighlight(to: tv, rawText: text)
        context.coordinator.syncAccessory(on: tv, content: accessoryContent)
        // Deferred: at this point the view has no real width yet (layout
        // hasn't run), so an accurate height can't be computed synchronously.
        // Mutating the height binding here directly would also be a
        // "modifying state during view update" violation since makeUIView
        // runs as part of a SwiftUI render pass — hop to the next runloop
        // tick instead, same as any other post-layout measurement.
        DispatchQueue.main.async { [weak tv] in
            guard let tv else { return }
            context.coordinator.recomputeHeight(for: tv)
        }
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text {
            // Genuine external content change — e.g. the keyboard-accessory
            // "/List" chip tapped, which rewrites `text` programmatically
            // rather than through typing. Content actually differs here, so
            // the cursor landing at the end (UIKit's default on `.text =`)
            // is expected and matches the mockup's own behavior after a chip
            // insert.
            uiView.text = text
            context.coordinator.applyHighlight(to: uiView, rawText: text)
            DispatchQueue.main.async { [weak uiView] in
                guard let uiView else { return }
                context.coordinator.recomputeHeight(for: uiView)
            }
        }
        // If uiView.text already equals text, this call is just SwiftUI
        // re-rendering after our own textViewDidChange already updated the
        // binding — the highlight was already applied in place there, so
        // there's nothing to do to the text view itself.
        context.coordinator.placeholderLabel?.isHidden = !text.isEmpty
        context.coordinator.placeholderLabel?.frame = CGRect(x: 4, y: 0, width: uiView.bounds.width - 8, height: 22)
        context.coordinator.syncAccessory(on: uiView, content: accessoryContent)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        let parent: DayflowNLHighlightField
        var placeholderLabel: UILabel?
        private let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        private var accessoryHosting: UIHostingController<AnyView>?
        private var hasAccessory = false

        init(_ parent: DayflowNLHighlightField) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            // The typed content is already exactly what's in textView.text —
            // applyHighlight only touches attributes on the existing storage,
            // never the string itself or selectedRange, so no cursor-restore
            // dance is needed here at all.
            let raw = textView.text ?? ""
            parent.text = raw
            applyHighlight(to: textView, rawText: raw)
            recomputeHeight(for: textView)
            placeholderLabel?.isHidden = !raw.isEmpty
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.onFocusChange?(true)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.onFocusChange?(false)
        }

        /// Computes the text view's real content height and writes it to the
        /// `height` binding — the deterministic replacement for asking
        /// SwiftUI's layout system to size this view itself (see the header
        /// note on why `sizeThatFits(_:uiView:context:)` alone wasn't enough).
        /// Safe to call from `textViewDidChange` directly (a UIKit delegate
        /// callback, not a SwiftUI render pass); callers from `makeUIView`/
        /// `updateUIView` must defer via `DispatchQueue.main.async` instead,
        /// since those run inside SwiftUI's own update cycle.
        func recomputeHeight(for textView: UITextView) {
            let width = textView.bounds.width > 0 ? textView.bounds.width : UIScreen.main.bounds.width
            guard width > 0 else { return }
            let fitting = textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
            let newHeight = max(fitting.height, DayflowNLHighlightField.minHeight)
            if abs(parent.height - newHeight) > 0.5 {
                parent.height = newHeight
            }
        }

        /// Attaches/detaches/updates the keyboard accessory view directly on
        /// the UITextView. Native `inputAccessoryView` shows whenever THIS
        /// specific view is first responder — no dependency on SwiftUI's
        /// FocusState, which this field doesn't participate in.
        func syncAccessory(on textView: UITextView, content: AnyView?) {
            guard let content else {
                if hasAccessory {
                    textView.inputAccessoryView = nil
                    hasAccessory = false
                    if textView.isFirstResponder { textView.reloadInputViews() }
                }
                return
            }
            if let hosting = accessoryHosting {
                hosting.rootView = content
            } else {
                let hosting = UIHostingController(rootView: content)
                hosting.view.backgroundColor = .clear
                let width = UIScreen.main.bounds.width
                hosting.view.frame = CGRect(x: 0, y: 0, width: width, height: 44)
                hosting.view.autoresizingMask = [.flexibleWidth]
                accessoryHosting = hosting
            }
            if !hasAccessory {
                textView.inputAccessoryView = accessoryHosting?.view
                hasAccessory = true
                if textView.isFirstResponder { textView.reloadInputViews() }
            }
        }

        /// Re-colors the existing text storage in place — recognized date
        /// phrases and a trailing "/List" token get their highlight
        /// attributes, everything else gets reset to base style. Requires
        /// `textView.text` to already equal `rawText`; this function never
        /// changes the string content, only attributes, so it never moves
        /// the cursor/selection.
        func applyHighlight(to textView: UITextView, rawText: String) {
            let font = textView.font ?? UIFont.preferredFont(forTextStyle: .body)
            let fullRange = NSRange(location: 0, length: (textView.textStorage.string as NSString).length)

            var foundListRange: NSRange?
            // List token: "/" through end of line, same rule as the mockup —
            // area names contain spaces, so this can't stop at whitespace.
            // Uses the LAST "/" in the text, not the first: a task has
            // exactly one list, so if you manually type a second "/token"
            // after an earlier one, the new one should win rather than the
            // whole span from the first "/" to the end being read as one
            // (garbled) list name (found 2026-07-19: typing "/personal
            // /health" by hand produced list "personal /health").
            if let slashRange = rawText.range(of: "/", options: .backwards) {
                let nsRange = NSRange(slashRange.lowerBound..<rawText.endIndex, in: rawText)
                if nsRange.length > 1 {
                    foundListRange = nsRange
                }
            }

            // Date phrase via NSDataDetector — same tech as Messages/Mail's
            // date-suggestion banners, per the design plan. Skip any match that
            // overlaps the list token so a "/" token isn't also date-colored.
            var foundDate: Date?
            var dateRanges: [NSRange] = []
            if let detector {
                let full = NSRange(rawText.startIndex..., in: rawText)
                detector.enumerateMatches(in: rawText, options: [], range: full) { match, _, _ in
                    guard let match, let date = match.date else { return }
                    if let listRange = foundListRange, NSIntersectionRange(match.range, listRange).length > 0 {
                        return
                    }
                    if foundDate == nil { foundDate = date }
                    dateRanges.append(match.range)
                }
            }

            let storage = textView.textStorage
            storage.beginEditing()
            storage.setAttributes([.font: font, .foregroundColor: UIColor.label], range: fullRange)
            if let listRange = foundListRange {
                storage.addAttributes([.foregroundColor: DayflowNLHighlightField.listColor,
                                        .backgroundColor: DayflowNLHighlightField.listBG],
                                       range: listRange)
            }
            for r in dateRanges {
                storage.addAttributes([.foregroundColor: DayflowNLHighlightField.dateColor,
                                        .backgroundColor: DayflowNLHighlightField.dateBG],
                                       range: r)
            }
            storage.endEditing()

            var listName: String?
            if let r = foundListRange, let swiftRange = Range(r, in: rawText) {
                // Drop the leading "/" itself from the reported name.
                listName = String(rawText[swiftRange].dropFirst())
            }
            parent.onParse(foundDate, listName)
        }
    }
}
