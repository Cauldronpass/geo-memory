import SwiftUI
import UIKit

// MARK: - MarkdownEditorView
//
// UIViewRepresentable wrapping UITextView with MarkdownTextStorage (TextKit 1).
// Features:
//   • Live markdown syntax highlighting via MarkdownTextStorage
//   • Toolbar: Bold / Bullet / Checkbox / Done
//   • Auto-save: 0.8 s debounce after last keystroke
//   • Checkbox tap: tapping a checkbox line toggles - [ ] ↔ - [x]
//   • Link tap: opens URLs (http/https and custom schemes) via UIApplication.open
//   • Placeholder label shown when text is empty

struct MarkdownEditorView: UIViewRepresentable {

    @Binding var text: String
    var onSave: ((String) -> Void)?
    var placeholder: String = "Start writing…"

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

        // Toolbar
        context.coordinator.textView = tv
        tv.inputAccessoryView = makeToolbar(context.coordinator)

        // Checkbox / link tap gesture
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                        action: #selector(Coordinator.handleTap(_:)))
        tap.delegate = context.coordinator
        tv.addGestureRecognizer(tap)

        // Placeholder
        addPlaceholder(to: tv, text: placeholder)

        // Initial content
        if !text.isEmpty {
            storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
        }
        updatePlaceholderVisibility(tv)

        return tv
    }

    // MARK: Update

    func updateUIView(_ tv: UITextView, context: Context) {
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
        let newLen = tv.textStorage.length
        tv.selectedRange = NSRange(location: min(saved.location, newLen), length: 0)
        updatePlaceholderVisibility(tv)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSave: onSave)
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

    // MARK: - Toolbar

    private func makeToolbar(_ coordinator: Coordinator) -> UIToolbar {
        let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))

        let bold = barButton(title: "B", bold: true, coordinator: coordinator,
                             action: #selector(Coordinator.insertBold))
        let bullet = barButton(title: "−", bold: false, coordinator: coordinator,
                               action: #selector(Coordinator.insertBullet))
        let checkbox = barButton(title: "☐", bold: false, coordinator: coordinator,
                                 action: #selector(Coordinator.insertCheckbox))
        let flex = UIBarButtonItem(barButtonSystemItem: .flexibleSpace,
                                   target: nil, action: nil)
        let done = UIBarButtonItem(title: "Done", style: .done,
                                   target: coordinator,
                                   action: #selector(Coordinator.dismissKeyboard))

        bar.items = [bold, fixedSpace(12), bullet, fixedSpace(12), checkbox, flex, done]
        bar.sizeToFit()
        return bar
    }

    private func barButton(title: String, bold: Bool,
                            coordinator: Coordinator,
                            action: Selector) -> UIBarButtonItem {
        let item = UIBarButtonItem(title: title, style: .plain,
                                   target: coordinator, action: action)
        let font: UIFont = bold
            ? .boldSystemFont(ofSize: 17)
            : .systemFont(ofSize: 17)
        item.setTitleTextAttributes([.font: font], for: .normal)
        item.setTitleTextAttributes([.font: font], for: .highlighted)
        return item
    }

    private func fixedSpace(_ width: CGFloat) -> UIBarButtonItem {
        let s = UIBarButtonItem(barButtonSystemItem: .fixedSpace, target: nil, action: nil)
        s.width = width
        return s
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {

        @Binding var text: String
        var onSave: ((String) -> Void)?
        weak var textView: UITextView?
        private var saveWork: DispatchWorkItem?

        init(text: Binding<String>, onSave: ((String) -> Void)?) {
            _text = text
            self.onSave = onSave
        }

        // MARK: UITextViewDelegate

        func textViewDidChange(_ tv: UITextView) {
            text = tv.text
            tv.viewWithTag(9_001)?.isHidden = !tv.text.isEmpty
            scheduleSave(tv.text)
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

        // MARK: Toolbar actions

        @objc func insertBold() {
            guard let tv = textView,
                  let range = tv.selectedTextRange else { return }
            if range.isEmpty {
                tv.replace(range, withText: "****")
                // Move cursor between the markers
                if let newPos = tv.position(from: range.start, offset: -2) {
                    tv.selectedTextRange = tv.textRange(from: newPos, to: newPos)
                }
            } else {
                let selected = tv.text(in: range) ?? ""
                tv.replace(range, withText: "**\(selected)**")
            }
            text = tv.text
            scheduleSave(tv.text)
        }

        @objc func insertBullet() {
            guard let tv = textView else { return }
            toggleLinePrefix(tv: tv, prefix: "- ")
        }

        @objc func insertCheckbox() {
            guard let tv = textView else { return }
            toggleLinePrefix(tv: tv, prefix: "- [ ] ")
        }

        @objc func dismissKeyboard() {
            textView?.resignFirstResponder()
        }

        // MARK: Checkbox tap

        @objc func handleTap(_ gr: UITapGestureRecognizer) {
            guard gr.state == .ended,
                  let tv = textView else { return }

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
                text = tv.text
                scheduleSave(tv.text)
            } else if line.hasPrefix("- [x]") {
                let toggled = "- [ ]" + line.dropFirst(5)
                tv.textStorage.replaceCharacters(in: lineRange, with: toggled)
                text = tv.text
                scheduleSave(tv.text)
            }
            // Non-checkbox lines: tap falls through to UITextView's own gesture
        }

        // Let our tap and UITextView's gestures coexist
        func gestureRecognizer(
            _ gr: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool { true }

        // MARK: Prefix toggle helper

        private func toggleLinePrefix(tv: UITextView, prefix: String) {
            let cursorRange = tv.selectedRange
            let ns = tv.text as NSString
            let lineRange = ns.lineRange(
                for: NSRange(location: cursorRange.location, length: 0)
            )
            let line = ns.substring(with: lineRange)

            if line.hasPrefix(prefix) {
                // Remove prefix
                let stripped = String(line.dropFirst(prefix.count))
                tv.textStorage.replaceCharacters(in: lineRange, with: stripped)
                let newLoc = max(lineRange.location,
                                 cursorRange.location - prefix.count)
                tv.selectedRange = NSRange(location: newLoc, length: 0)
            } else {
                // Insert prefix at line start
                tv.textStorage.replaceCharacters(
                    in: NSRange(location: lineRange.location, length: 0),
                    with: prefix
                )
                tv.selectedRange = NSRange(
                    location: cursorRange.location + prefix.count,
                    length: 0
                )
            }
            text = tv.text
            scheduleSave(tv.text)
        }
    }
}
