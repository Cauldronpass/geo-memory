import SwiftUI
import UIKit
import PhotosUI
import VisionKit
import UniformTypeIdentifiers

// MARK: - MarkdownEditorView
//
// UIViewRepresentable wrapping UITextView with MarkdownTextStorage (TextKit 1).
// Features:
//   • Live markdown syntax highlighting via MarkdownTextStorage
//   • Scrollable toolbar: B · I · ~~ · H · # · − · → · ← · ☐ · 📎 · 🔗 ‖ Done
//   • Auto-save: 0.8 s debounce after last keystroke
//   • Checkbox tap: tapping a checkbox line toggles - [ ] ↔ - [x]
//   • Link tap: opens URLs (http/https and custom schemes) via UIApplication.open
//   • Placeholder label shown when text is empty
//   • Timestamp insert: triggered externally via timestampTrigger binding

struct MarkdownEditorView: UIViewRepresentable {

    @Binding var text: String
    var onSave: ((String) -> Void)?
    var placeholder: String = "Start writing…"
    /// Set to Date() from outside to insert a bold timestamp at the end of the document.
    var timestampTrigger: Binding<Date?>? = nil
    /// Called with true when the editor gains first responder, false when it resigns.
    var onFocusChange: ((Bool) -> Void)? = nil
    /// Called when user long-presses a timestamp-delimited block (E1).
    var onBlockLongPress: ((BlockInfo) -> Void)? = nil

    // MARK: Make

    func makeUIView(context: Context) -> UITextView {
        // Build TextKit 1 stack with custom storage
        let storage   = MarkdownTextStorage()
        let manager   = NSLayoutManager()
        let container = NSTextContainer(size: .zero)
        container.widthTracksTextView = true
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)

        let tv = UITextView(frame: .zero, textContainer: container)
        tv.delegate               = context.coordinator
        tv.backgroundColor        = .systemBackground
        tv.textColor              = .label
        tv.font                   = MarkdownTextStorage.bodyFont
        tv.textContainerInset     = UIEdgeInsets(top: 14, left: 12, bottom: 60, right: 12)
        tv.autocorrectionType     = .default
        tv.autocapitalizationType = .sentences
        tv.keyboardDismissMode    = .interactive
        tv.alwaysBounceVertical   = true

        context.coordinator.textView = tv
        tv.inputAccessoryView = makeScrollToolbar(context.coordinator)

        // Checkbox / link tap gesture
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                        action: #selector(Coordinator.handleTap(_:)))
        tap.delegate = context.coordinator
        tv.addGestureRecognizer(tap)

        // Block long-press — identifies timestamp-delimited blocks (E1)
        let longPress = UILongPressGestureRecognizer(target: context.coordinator,
                                                     action: #selector(Coordinator.handleLongPress(_:)))
        longPress.minimumPressDuration = 0.5
        longPress.delegate = context.coordinator
        tv.addGestureRecognizer(longPress)

        addPlaceholder(to: tv, text: placeholder)

        if !text.isEmpty {
            storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
        }
        updatePlaceholderVisibility(tv)

        return tv
    }

    // MARK: Update

    func updateUIView(_ tv: UITextView, context: Context) {
        // Handle timestamp trigger
        if let triggerBinding = timestampTrigger,
           let trigger = triggerBinding.wrappedValue,
           trigger != context.coordinator.lastTimestampTrigger {
            context.coordinator.lastTimestampTrigger = trigger
            DispatchQueue.main.async {
                context.coordinator.insertTimestamp()
                triggerBinding.wrappedValue = nil
            }
        }

        // Only overwrite when text diverged externally (avoid cursor jumps on every keystroke)
        guard tv.text != text else {
            updatePlaceholderVisibility(tv)
            return
        }
        let saved = tv.selectedRange
        tv.textStorage.beginEditing()
        tv.textStorage.replaceCharacters(
            in: NSRange(location: 0, length: tv.textStorage.length),
            with: text
        )
        tv.textStorage.endEditing()
        // Force the layout manager to complete its pass synchronously so the scroll
        // view's contentSize is accurate before we restore the selected range.
        // Without this, scroll is locked until the next render cycle (Bug 4).
        tv.layoutIfNeeded()
        let newLen = tv.textStorage.length
        tv.selectedRange = NSRange(location: min(saved.location, newLen), length: 0)
        updatePlaceholderVisibility(tv)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSave: onSave, onFocusChange: onFocusChange, onBlockLongPress: onBlockLongPress)
    }

    // MARK: - Placeholder helpers

    private func addPlaceholder(to tv: UITextView, text: String) {
        let lbl = UILabel()
        lbl.tag = 9_001
        lbl.text = text
        lbl.font = MarkdownTextStorage.bodyFont
        lbl.textColor = .placeholderText
        lbl.numberOfLines = 0
        lbl.isUserInteractionEnabled = false
        lbl.translatesAutoresizingMaskIntoConstraints = false
        tv.addSubview(lbl)
        NSLayoutConstraint.activate([
            lbl.topAnchor.constraint(equalTo: tv.topAnchor, constant: 14),
            lbl.leadingAnchor.constraint(equalTo: tv.leadingAnchor, constant: 16),
            lbl.trailingAnchor.constraint(equalTo: tv.trailingAnchor, constant: -16)
        ])
    }

    private func updatePlaceholderVisibility(_ tv: UITextView) {
        tv.viewWithTag(9_001)?.isHidden = !tv.text.isEmpty
    }

    // MARK: - Scrollable Toolbar
    //
    // Layout: [← scrollable formatting buttons →] | [Done]
    // The Done button is always pinned to the trailing edge.
    // Formatting buttons scroll horizontally so all 9 fit on any screen width.

    private func makeScrollToolbar(_ coordinator: Coordinator) -> UIView {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        container.autoresizingMask = [.flexibleWidth]
        container.backgroundColor = UIColor.systemGroupedBackground

        // Top hairline border
        let border = UIView()
        border.backgroundColor = UIColor.separator
        border.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(border)

        // Done button — always visible, trailing edge
        let doneBtn = UIButton(type: .system)
        doneBtn.setTitle("Done", for: .normal)
        doneBtn.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        doneBtn.addTarget(coordinator,
                          action: #selector(Coordinator.dismissKeyboard),
                          for: .touchUpInside)
        doneBtn.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(doneBtn)

        // Thin separator between scroll area and Done
        let sep = UIView()
        sep.backgroundColor = UIColor.separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(sep)

        // Scrollable area
        let scrollView = UIScrollView()
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.isDirectionalLockEnabled = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)

        // Horizontal stack inside scroll view
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 0
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)

        // Order: B · ~~ · H · − · ☐ · ← · → · 📎 · 🔗 · #
        let items: [(title: String, bold: Bool, action: Selector)] = [
            ("B",   true,  #selector(Coordinator.insertBold)),
            ("~~",  false, #selector(Coordinator.insertStrike)),
            ("H",   false, #selector(Coordinator.insertHighlight)),
            ("−",   false, #selector(Coordinator.insertBullet)),
            ("☐",   false, #selector(Coordinator.insertCheckbox)),
            ("←",   false, #selector(Coordinator.outdentLine)),
            ("→",   false, #selector(Coordinator.indentLine)),
            ("📎",  false, #selector(Coordinator.showAttachMenu)),
            ("🔗",  false, #selector(Coordinator.insertLink)),
            ("#",   false, #selector(Coordinator.insertHeading)),
        ]

        for item in items {
            stack.addArrangedSubview(
                makeToolbarButton(item.title, bold: item.bold,
                                  coordinator: coordinator, action: item.action)
            )
        }

        NSLayoutConstraint.activate([
            // Top border
            border.topAnchor.constraint(equalTo: container.topAnchor),
            border.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            border.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            border.heightAnchor.constraint(equalToConstant: 0.5),

            // Done button
            doneBtn.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            doneBtn.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            // Separator
            sep.trailingAnchor.constraint(equalTo: doneBtn.leadingAnchor, constant: -8),
            sep.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            sep.widthAnchor.constraint(equalToConstant: 0.5),
            sep.heightAnchor.constraint(equalToConstant: 22),

            // Scroll view
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: sep.leadingAnchor, constant: -4),
            scrollView.topAnchor.constraint(equalTo: border.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            // Stack inside scroll view
            stack.topAnchor.constraint(equalTo: scrollView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            stack.heightAnchor.constraint(equalTo: scrollView.heightAnchor),
        ])

        return container
    }

    private func makeToolbarButton(_ title: String, bold: Bool,
                                    coordinator: Coordinator, action: Selector) -> UIButton {
        let btn = UIButton(type: .system)
        let font: UIFont = bold ? .boldSystemFont(ofSize: 17) : .systemFont(ofSize: 17)
        btn.setAttributedTitle(
            NSAttributedString(string: title,
                               attributes: [.font: font, .foregroundColor: UIColor.label]),
            for: .normal
        )
        btn.setAttributedTitle(
            NSAttributedString(string: title,
                               attributes: [.font: font, .foregroundColor: UIColor.secondaryLabel]),
            for: .highlighted
        )
        btn.addTarget(coordinator, action: action, for: .touchUpInside)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.widthAnchor.constraint(greaterThanOrEqualToConstant: 42).isActive = true
        btn.heightAnchor.constraint(equalToConstant: 43).isActive = true
        return btn
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject,
                             UITextViewDelegate,
                             UIGestureRecognizerDelegate,
                             PHPickerViewControllerDelegate,
                             VNDocumentCameraViewControllerDelegate,
                             UIDocumentPickerDelegate {

        @Binding var text: String
        var onSave: ((String) -> Void)?
        var onFocusChange: ((Bool) -> Void)?
        var onBlockLongPress: ((BlockInfo) -> Void)?
        weak var textView: UITextView?
        private var saveWork: DispatchWorkItem?
        var lastTimestampTrigger: Date?

        init(text: Binding<String>,
             onSave: ((String) -> Void)?,
             onFocusChange: ((Bool) -> Void)?,
             onBlockLongPress: ((BlockInfo) -> Void)? = nil) {
            _text = text
            self.onSave = onSave
            self.onFocusChange = onFocusChange
            self.onBlockLongPress = onBlockLongPress
        }

        // MARK: UITextViewDelegate

        func textViewDidChange(_ tv: UITextView) {
            text = tv.text
            tv.viewWithTag(9_001)?.isHidden = !tv.text.isEmpty
            scheduleSave(tv.text)
        }

        func textViewDidBeginEditing(_ tv: UITextView) {
            onFocusChange?(true)
        }

        func textViewDidEndEditing(_ tv: UITextView) {
            onFocusChange?(false)
        }

        // MARK: Auto-continue bullets and checkboxes on Return

        func textView(_ tv: UITextView,
                      shouldChangeTextIn range: NSRange,
                      replacementText text: String) -> Bool {
            guard text == "\n" else { return true }
            let ns = tv.text as NSString
            let lineRange = ns.lineRange(for: NSRange(location: range.location, length: 0))
            let line = ns.substring(with: lineRange)

            // Round bullet — • item
            if line.hasPrefix("• ") {
                let content = String(line.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
                if content.isEmpty {
                    // Double-return on empty bullet exits the list
                    tv.textStorage.replaceCharacters(in: lineRange, with: "\n")
                    tv.selectedRange = NSRange(location: lineRange.location + 1, length: 0)
                } else {
                    tv.textStorage.replaceCharacters(in: range, with: "\n• ")
                    tv.selectedRange = NSRange(location: range.location + 3, length: 0)
                }
                self.text = tv.text; scheduleSave(tv.text)
                return false
            }

            // Checkbox — - [ ] item
            if line.hasPrefix("- [ ] ") {
                let content = String(line.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
                if content.isEmpty {
                    tv.textStorage.replaceCharacters(in: lineRange, with: "\n")
                    tv.selectedRange = NSRange(location: lineRange.location + 1, length: 0)
                } else {
                    tv.textStorage.replaceCharacters(in: range, with: "\n- [ ] ")
                    tv.selectedRange = NSRange(location: range.location + 7, length: 0)
                }
                self.text = tv.text; scheduleSave(tv.text)
                return false
            }

            return true
        }

        func textView(_ tv: UITextView,
                      shouldInteractWith url: URL,
                      in characterRange: NSRange,
                      interaction: UITextItemInteraction) -> Bool {
            guard interaction == .invokeDefaultAction else { return true }
            UIApplication.shared.open(url)
            return false
        }

        // MARK: Auto-save — 0.8 s debounce

        private func scheduleSave(_ content: String) {
            saveWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.onSave?(content)
            }
            saveWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
        }

        // MARK: - E1: Long-press block detection

        @objc func handleLongPress(_ gr: UILongPressGestureRecognizer) {
            guard gr.state == .began, let tv = textView else { return }

            // Find character under touch
            let point = gr.location(in: tv)
            guard let textPos = tv.closestPosition(to: point) else { return }
            let charIndex = tv.offset(from: tv.beginningOfDocument, to: textPos)

            let fullText = tv.textStorage.string
            guard let blockInfo = findBlock(in: fullText, at: charIndex) else { return }

            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            DispatchQueue.main.async { [weak self] in
                self?.onBlockLongPress?(blockInfo)
            }
        }

        /// Locate the timestamp-delimited block that contains the character at `charIndex`.
        /// Returns nil if the tap is not inside any block.
        private func findBlock(in text: String, at charIndex: Int) -> BlockInfo? {
            // NSString for safe UTF-16 range arithmetic
            let ns = text as NSString
            let totalLen = ns.length
            guard charIndex >= 0, charIndex <= totalLen else { return nil }

            // Split into lines, recording each line's NSRange in the NSString
            var lineRanges: [(text: String, nsRange: NSRange)] = []
            var pos = 0
            while pos < totalLen {
                let lineRange = ns.lineRange(for: NSRange(location: pos, length: 0))
                let lineText = ns.substring(with: lineRange)
                lineRanges.append((lineText, lineRange))
                pos = lineRange.location + lineRange.length
                if lineRange.length == 0 { break }  // safety
            }

            // Timestamp pattern: **HH:MM AM/PM** at start of line
            let pattern = #"^\*\*\d{1,2}:\d{2} [AP]M\*\*"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            func isTimestamp(_ s: String) -> Bool {
                let r = NSRange(s.startIndex..., in: s)
                return regex.firstMatch(in: s, range: r) != nil
            }

            // Which line does charIndex land on?
            guard let targetIdx = lineRanges.firstIndex(where: {
                $0.nsRange.location <= charIndex && charIndex < $0.nsRange.location + $0.nsRange.length
            }) ?? (charIndex == totalLen ? lineRanges.indices.last : nil) else { return nil }

            // Scan backwards to find the nearest timestamp line
            var blockStart = -1
            for i in stride(from: targetIdx, through: 0, by: -1) {
                if isTimestamp(lineRanges[i].text) {
                    blockStart = i
                    break
                }
            }
            guard blockStart >= 0 else { return nil }  // not inside any block

            // Scan forwards to find end (exclusive) — next timestamp line or EOF
            var blockEnd = lineRanges.count - 1
            for i in (blockStart + 1)..<lineRanges.count {
                if isTimestamp(lineRanges[i].text) {
                    blockEnd = i - 1
                    break
                }
            }

            // Compute NSRange for the block (including trailing newline of last line)
            let startNS = lineRanges[blockStart].nsRange.location
            let endLineRange = lineRanges[blockEnd].nsRange
            let endNS = endLineRange.location + endLineRange.length
            let blockRange = NSRange(location: startNS, length: endNS - startNS)

            // Trim trailing whitespace/newline from displayed text but keep range intact
            var blockText = ns.substring(with: blockRange)
            while blockText.hasSuffix("\n") { blockText = String(blockText.dropLast()) }

            return BlockInfo(text: blockText, nsRange: blockRange)
        }

        // MARK: - Toolbar: formatting actions

        @objc func insertBold() {
            guard let tv = textView, let range = tv.selectedTextRange else { return }
            if range.isEmpty {
                tv.replace(range, withText: "****")
                if let afterReplace = tv.selectedTextRange?.start,
                   let newPos = tv.position(from: afterReplace, offset: -2) {
                    tv.selectedTextRange = tv.textRange(from: newPos, to: newPos)
                }
            } else {
                let selected = tv.text(in: range) ?? ""
                tv.replace(range, withText: "**\(selected)**")
            }
            text = tv.text; scheduleSave(tv.text)
        }

        @objc func insertItalic() {
            guard let tv = textView, let range = tv.selectedTextRange else { return }
            if range.isEmpty {
                tv.replace(range, withText: "**")   // two single * chars
                if let afterReplace = tv.selectedTextRange?.start,
                   let newPos = tv.position(from: afterReplace, offset: -1) {
                    tv.selectedTextRange = tv.textRange(from: newPos, to: newPos)
                }
            } else {
                let selected = tv.text(in: range) ?? ""
                tv.replace(range, withText: "*\(selected)*")
            }
            text = tv.text; scheduleSave(tv.text)
        }

        @objc func insertHighlight() {
            guard let tv = textView, let range = tv.selectedTextRange else { return }
            if range.isEmpty {
                tv.replace(range, withText: "====")
                if let afterReplace = tv.selectedTextRange?.start,
                   let newPos = tv.position(from: afterReplace, offset: -2) {
                    tv.selectedTextRange = tv.textRange(from: newPos, to: newPos)
                }
            } else {
                let selected = tv.text(in: range) ?? ""
                tv.replace(range, withText: "==\(selected)==")
            }
            text = tv.text; scheduleSave(tv.text)
        }

        @objc func insertStrike() {
            guard let tv = textView, let range = tv.selectedTextRange else { return }
            if range.isEmpty {
                tv.replace(range, withText: "~~~~")
                if let afterReplace = tv.selectedTextRange?.start,
                   let newPos = tv.position(from: afterReplace, offset: -2) {
                    tv.selectedTextRange = tv.textRange(from: newPos, to: newPos)
                }
            } else {
                let selected = tv.text(in: range) ?? ""
                tv.replace(range, withText: "~~\(selected)~~")
            }
            text = tv.text; scheduleSave(tv.text)
        }

        @objc func insertHeading() {
            guard let tv = textView else { return }
            toggleLinePrefix(tv: tv, prefix: "## ")
        }

        @objc func insertBullet() {
            guard let tv = textView else { return }
            let cursorRange = tv.selectedRange
            let ns = tv.text as NSString
            let lineRange = ns.lineRange(for: NSRange(location: cursorRange.location, length: 0))
            let line = ns.substring(with: lineRange)

            if line.hasPrefix("• ") {
                // Toggle off — remove bullet
                let stripped = String(line.dropFirst(2))
                tv.textStorage.replaceCharacters(in: lineRange, with: stripped)
                let newLoc = max(lineRange.location, cursorRange.location - 2)
                tv.selectedRange = NSRange(location: newLoc, length: 0)
            } else if line.hasPrefix("- ") {
                // Upgrade old dash bullet to round bullet
                let content = String(line.dropFirst(2))
                tv.textStorage.replaceCharacters(in: lineRange, with: "• " + content)
                tv.selectedRange = NSRange(location: cursorRange.location, length: 0)
            } else {
                // Add round bullet
                tv.textStorage.replaceCharacters(
                    in: NSRange(location: lineRange.location, length: 0), with: "• ")
                tv.selectedRange = NSRange(location: cursorRange.location + 2, length: 0)
            }
            text = tv.text; scheduleSave(tv.text)
        }

        /// Adds one indent level (2 spaces) at the start of the current line.
        @objc func indentLine() {
            guard let tv = textView else { return }
            let cursorRange = tv.selectedRange
            let ns = tv.text as NSString
            let lineRange = ns.lineRange(for: NSRange(location: cursorRange.location, length: 0))
            tv.textStorage.replaceCharacters(
                in: NSRange(location: lineRange.location, length: 0), with: "  ")
            tv.selectedRange = NSRange(location: cursorRange.location + 2, length: 0)
            text = tv.text; scheduleSave(tv.text)
        }

        /// Removes one indent level (up to 2 spaces) from the start of the current line.
        @objc func outdentLine() {
            guard let tv = textView else { return }
            let cursorRange = tv.selectedRange
            let ns = tv.text as NSString
            let lineRange = ns.lineRange(for: NSRange(location: cursorRange.location, length: 0))
            let line = ns.substring(with: lineRange)
            let toRemove = line.hasPrefix("  ") ? 2 : (line.hasPrefix(" ") ? 1 : 0)
            guard toRemove > 0 else { return }
            tv.textStorage.replaceCharacters(
                in: NSRange(location: lineRange.location, length: toRemove), with: "")
            let newLoc = max(lineRange.location, cursorRange.location - toRemove)
            tv.selectedRange = NSRange(location: newLoc, length: 0)
            text = tv.text; scheduleSave(tv.text)
        }

        @objc func insertCheckbox() {
            guard let tv = textView else { return }
            let cursorRange = tv.selectedRange
            let ns = tv.text as NSString
            let lineRange = ns.lineRange(for: NSRange(location: cursorRange.location, length: 0))
            let line = ns.substring(with: lineRange)

            func uiRange(from loc: Int, length: Int) -> UITextRange? {
                guard let s = tv.position(from: tv.beginningOfDocument, offset: loc),
                      let e = tv.position(from: tv.beginningOfDocument, offset: loc + length)
                else { return nil }
                return tv.textRange(from: s, to: e)
            }

            if line.hasPrefix("- [x] ") {
                // Checked → unchecked
                guard let r = uiRange(from: lineRange.location, length: 6) else { return }
                tv.replace(r, withText: "- [ ] ")
                tv.selectedRange = NSRange(location: cursorRange.location, length: 0)
            } else if line.hasPrefix("- [ ] ") {
                // Unchecked → remove prefix
                guard let r = uiRange(from: lineRange.location, length: 6) else { return }
                tv.replace(r, withText: "")
                let newLoc = max(lineRange.location, cursorRange.location - 6)
                tv.selectedRange = NSRange(location: newLoc, length: 0)
            } else {
                // No checkbox — add one
                guard let insertPos = tv.position(from: tv.beginningOfDocument,
                                                  offset: lineRange.location),
                      let r = tv.textRange(from: insertPos, to: insertPos) else { return }
                tv.replace(r, withText: "- [ ] ")
                tv.selectedRange = NSRange(location: cursorRange.location + 6, length: 0)
            }
            // tv.replace() fires textViewDidChange → text binding + scheduleSave handled there
        }

        @objc func insertLink() {
            guard let tv = textView, let range = tv.selectedTextRange else { return }
            if range.isEmpty {
                tv.replace(range, withText: "[[]]")
                if let afterReplace = tv.selectedTextRange?.start,
                   let newPos = tv.position(from: afterReplace, offset: -2) {
                    tv.selectedTextRange = tv.textRange(from: newPos, to: newPos)
                }
            } else {
                let selected = tv.text(in: range) ?? ""
                tv.replace(range, withText: "[[\(selected)]]")
            }
            text = tv.text; scheduleSave(tv.text)
        }

        @objc func dismissKeyboard() {
            textView?.resignFirstResponder()
        }

        // MARK: - Toolbar: Attach menu

        @objc func showAttachMenu() {
            guard let vc = presentingViewController() else { return }
            let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
            sheet.addAction(UIAlertAction(title: "Camera Scan", style: .default) { [weak self] _ in
                self?.showDocumentCamera(from: vc)
            })
            sheet.addAction(UIAlertAction(title: "Photo", style: .default) { [weak self] _ in
                self?.showPhotoPicker(from: vc)
            })
            sheet.addAction(UIAlertAction(title: "PDF from Files", style: .default) { [weak self] _ in
                self?.showDocumentPicker(from: vc)
            })
            sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            // iPad popover anchor
            if let pop = sheet.popoverPresentationController {
                pop.sourceView = textView
                pop.sourceRect = textView?.bounds ?? .zero
            }
            vc.present(sheet, animated: true)
        }

        // MARK: - Timestamp insert (triggered by + button via binding)

        func insertTimestamp() {
            guard let tv = textView else { return }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "h:mm a"
            formatter.amSymbol = "AM"
            formatter.pmSymbol = "PM"
            let timeStr = formatter.string(from: Date())
            let stamp = "\n\n**\(timeStr)**\n\n"

            // Insert at end of document
            let end = tv.endOfDocument
            if let endRange = tv.textRange(from: end, to: end) {
                tv.replace(endRange, withText: stamp)
            }
            text = tv.text
            scheduleSave(tv.text)
            tv.becomeFirstResponder()
            // Position cursor after the timestamp line (before the trailing newline)
            let newEnd = tv.endOfDocument
            if let before = tv.position(from: newEnd, offset: -1) {
                tv.selectedTextRange = tv.textRange(from: before, to: before)
                tv.scrollRangeToVisible(tv.selectedRange)
            }
        }

        // MARK: - Checkbox tap

        @objc func handleTap(_ gr: UITapGestureRecognizer) {
            guard gr.state == .ended, let tv = textView else { return }

            let point = gr.location(in: tv)
            let adj = CGPoint(
                x: point.x - tv.textContainerInset.left,
                y: point.y - tv.textContainerInset.top
            )
            let lm = tv.layoutManager
            let tc = tv.textContainer
            let charIdx = lm.characterIndex(
                for: adj, in: tc,
                fractionOfDistanceBetweenInsertionPoints: nil
            )
            let ns = tv.text as NSString
            guard charIdx < ns.length else { return }

            let lineRange = ns.lineRange(for: NSRange(location: charIdx, length: 0))
            let line = ns.substring(with: lineRange)

            if line.hasPrefix("- [ ]") {
                let toggled = "- [x]" + line.dropFirst(5)
                tv.textStorage.replaceCharacters(in: lineRange, with: toggled)
                text = tv.text; scheduleSave(tv.text)
            } else if line.hasPrefix("- [x]") {
                let toggled = "- [ ]" + line.dropFirst(5)
                tv.textStorage.replaceCharacters(in: lineRange, with: toggled)
                text = tv.text; scheduleSave(tv.text)
            }
        }

        func gestureRecognizer(
            _ gr: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool { true }

        // MARK: - Prefix toggle helper

        private func toggleLinePrefix(tv: UITextView, prefix: String) {
            let cursorRange = tv.selectedRange
            let ns = tv.text as NSString
            let lineRange = ns.lineRange(
                for: NSRange(location: cursorRange.location, length: 0)
            )
            let line = ns.substring(with: lineRange)

            if line.hasPrefix(prefix) {
                let stripped = String(line.dropFirst(prefix.count))
                tv.textStorage.replaceCharacters(in: lineRange, with: stripped)
                let newLoc = max(lineRange.location, cursorRange.location - prefix.count)
                tv.selectedRange = NSRange(location: newLoc, length: 0)
            } else {
                tv.textStorage.replaceCharacters(
                    in: NSRange(location: lineRange.location, length: 0),
                    with: prefix
                )
                tv.selectedRange = NSRange(
                    location: cursorRange.location + prefix.count,
                    length: 0
                )
            }
            text = tv.text; scheduleSave(tv.text)
        }

        private func insertAtCursor(_ str: String) {
            guard let tv = textView else { return }
            let insertRange: UITextRange
            if let sel = tv.selectedTextRange {
                insertRange = sel
            } else {
                let endPos = tv.endOfDocument
                guard let r = tv.textRange(from: endPos, to: endPos) else { return }
                insertRange = r
            }
            tv.replace(insertRange, withText: str)
            text = tv.text; scheduleSave(tv.text)
        }

        // MARK: - Presenting helpers

        private func presentingViewController() -> UIViewController? {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first(where: { $0.isKeyWindow })?
                .rootViewController?
                .topmostViewController()
        }

        // MARK: - Photo picker

        private func showPhotoPicker(from vc: UIViewController) {
            var config = PHPickerConfiguration(photoLibrary: .shared())
            config.selectionLimit = 1
            config.filter = .images
            let picker = PHPickerViewController(configuration: config)
            picker.delegate = self
            vc.present(picker, animated: true)
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let result = results.first else { return }
            result.itemProvider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
                guard let self,
                      let image = object as? UIImage,
                      let data = image.jpegData(compressionQuality: 0.85) else { return }
                let cal = Calendar.current
                let now = Date()
                let year = cal.component(.year, from: now)
                let month = String(format: "%02d", cal.component(.month, from: now))
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "yyyy-MM-dd-HHmmss"
                let filename = "\(formatter.string(from: now)).jpg"
                Task {
                    do {
                        let path = try NoteStore.shared.writePhoto(data, category: "\(year)/\(month)", filename: filename)
                        await MainActor.run { self.insertAtCursor("![](\(path))") }
                    } catch { /* silent — iCloud write failure */ }
                }
            }
        }

        // MARK: - Camera scan (document scanner → PDF)

        private func showDocumentCamera(from vc: UIViewController) {
            guard VNDocumentCameraViewController.isSupported else {
                let alert = UIAlertController(title: "Not Available",
                                             message: "Camera scanning is not supported on this device.",
                                             preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                vc.present(alert, animated: true)
                return
            }
            let scanner = VNDocumentCameraViewController()
            scanner.delegate = self
            vc.present(scanner, animated: true)
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFinishWith scan: VNDocumentCameraScan) {
            controller.dismiss(animated: true)
            guard let pdfData = scanToPDF(scan) else { return }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            let filename = "\(formatter.string(from: Date()))-scan.pdf"
            Task {
                do {
                    let path = try NoteStore.shared.writeDocument(pdfData, category: "Receipts", filename: filename)
                    await MainActor.run { self.insertAtCursor("📎 [Scan](\(path))") }
                } catch { }
            }
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            controller.dismiss(animated: true)
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFailWithError error: Error) {
            controller.dismiss(animated: true)
        }

        private func scanToPDF(_ scan: VNDocumentCameraScan) -> Data? {
            let pageSize = CGSize(width: 612, height: 792) // US Letter
            let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize))
            return renderer.pdfData { ctx in
                for i in 0..<scan.pageCount {
                    ctx.beginPage()
                    let image = scan.imageOfPage(at: i)
                    let bounds = ctx.pdfContextBounds
                    let scale = min(bounds.width / image.size.width,
                                   bounds.height / image.size.height)
                    let w = image.size.width * scale
                    let h = image.size.height * scale
                    image.draw(in: CGRect(x: (bounds.width - w) / 2,
                                         y: (bounds.height - h) / 2,
                                         width: w, height: h))
                }
            }
        }

        // MARK: - PDF document picker

        private func showDocumentPicker(from vc: UIViewController) {
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.pdf])
            picker.delegate = self
            picker.allowsMultipleSelection = false
            vc.present(picker, animated: true)
        }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            let didStart = url.startAccessingSecurityScopedResource()
            defer { if didStart { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { return }
            let filename = url.lastPathComponent
            let displayName = url.deletingPathExtension().lastPathComponent
            Task {
                do {
                    let path = try NoteStore.shared.writeDocument(data, category: "Other", filename: filename)
                    await MainActor.run { self.insertAtCursor("📎 [\(displayName)](\(path))") }
                } catch { }
            }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { }
    }
}

// MARK: - UIViewController topmost helper

private extension UIViewController {
    func topmostViewController() -> UIViewController {
        if let nav = self as? UINavigationController {
            return nav.visibleViewController?.topmostViewController() ?? self
        }
        if let tab = self as? UITabBarController {
            return tab.selectedViewController?.topmostViewController() ?? self
        }
        if let presented = presentedViewController {
            return presented.topmostViewController()
        }
        return self
    }
}
