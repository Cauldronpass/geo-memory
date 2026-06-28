import SwiftUI
import UIKit
import PhotosUI
import VisionKit
import UniformTypeIdentifiers
import PDFKit
import AVFoundation

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
    /// NoteStore relative path for this note (e.g. "Notes/Daily/2026-06-28.md").
    /// Used to extract the note date for task scheduling when sending to Things / Tweek.
    var relativePath: String? = nil

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

        // Refresh overlays after layout completes (initial load)
        let tvForThumb = tv
        let coord = context.coordinator
        DispatchQueue.main.async {
            tvForThumb.layoutManager.ensureLayout(for: tvForThumb.textContainer)
            coord.refreshThumbnails(in: tvForThumb)
            coord.refreshCheckboxOverlays(in: tvForThumb)
        }

        return tv
    }

    // MARK: Update

    private func _updateUIView(_ tv: UITextView, context: Context) {
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
        let extCoord = context.coordinator
        DispatchQueue.main.async {
            tv.layoutManager.ensureLayout(for: tv.textContainer)
            extCoord.refreshCheckboxOverlays(in: tv)
            extCoord.refreshThumbnails(in: tv)
        }
    }

    func makeCoordinator() -> Coordinator {
        let c = Coordinator(text: $text, onSave: onSave, onFocusChange: onFocusChange, onBlockLongPress: onBlockLongPress)
        c.relativePath = relativePath
        return c
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        // Keep relativePath in sync if the caller changes it after initial creation.
        context.coordinator.relativePath = relativePath
        _updateUIView(tv, context: context)
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

        // Order: B · ~~ · H · − · ☐(UIMenu) · ← · → · 📎(UIMenu) · 🔗 · # · 📅
        let leadingItems: [(title: String, bold: Bool, action: Selector)] = [
            ("B",   true,  #selector(Coordinator.insertBold)),
            ("~~",  false, #selector(Coordinator.insertStrike)),
            ("H",   false, #selector(Coordinator.insertHighlight)),
            ("−",   false, #selector(Coordinator.insertBullet)),
            // ☐ is added below as a UIMenu button
            ("←",   false, #selector(Coordinator.outdentLine)),
            ("→",   false, #selector(Coordinator.indentLine)),
        ]
        let trailingItems: [(title: String, bold: Bool, action: Selector)] = [
            ("🔗",  false, #selector(Coordinator.insertLink)),
            ("#",   false, #selector(Coordinator.insertHeading)),
            ("📅",  false, #selector(Coordinator.insertDate)),
        ]
        for (i, item) in leadingItems.enumerated() {
            stack.addArrangedSubview(
                makeToolbarButton(item.title, bold: item.bold,
                                  coordinator: coordinator, action: item.action)
            )
            // Insert ☐ UIMenu after the − button (index 3)
            if i == 3 {
                stack.addArrangedSubview(makeCheckboxMenuButton(coordinator: coordinator))
            }
        }
        // 📎 uses UIMenu — no presenting VC needed, no keyboard conflicts
        stack.addArrangedSubview(makeAttachMenuButton(coordinator: coordinator))
        for item in trailingItems {
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

    // 📎 attach button — UIMenu so it appears contextually without a presenting VC,
    // working correctly regardless of keyboard state.
    private func makeAttachMenuButton(coordinator: Coordinator) -> UIButton {
        let btn = UIButton(type: .system)
        btn.setAttributedTitle(
            NSAttributedString(string: "📎",
                               attributes: [.font: UIFont.systemFont(ofSize: 17),
                                            .foregroundColor: UIColor.label]),
            for: .normal
        )
        btn.menu = UIMenu(title: "", children: [
            UIAction(title: "Take Photo",
                     image: UIImage(systemName: "camera")) { [weak coordinator] _ in
                coordinator?.triggerCameraCapture()
            },
            UIAction(title: "Photo Library",
                     image: UIImage(systemName: "photo.on.rectangle")) { [weak coordinator] _ in
                coordinator?.triggerPhotoLibrary()
            },
            UIAction(title: "Camera Scan",
                     image: UIImage(systemName: "doc.viewfinder")) { [weak coordinator] _ in
                coordinator?.triggerDocumentCamera()
            },
            UIAction(title: "PDF from Files",
                     image: UIImage(systemName: "doc.badge.plus")) { [weak coordinator] _ in
                coordinator?.triggerDocumentPicker()
            },
        ])
        btn.showsMenuAsPrimaryAction = true
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.widthAnchor.constraint(greaterThanOrEqualToConstant: 42).isActive = true
        btn.heightAnchor.constraint(equalToConstant: 43).isActive = true
        return btn
    }

    // ☐ checkbox picker — UIMenu with 3 options: local / Things / Tweek.
    // Selecting Things or Tweek inserts `- [ ] ` AND immediately fires the send.
    private func makeCheckboxMenuButton(coordinator: Coordinator) -> UIButton {
        let btn = UIButton(type: .system)
        btn.setAttributedTitle(
            NSAttributedString(string: "☐",
                               attributes: [.font: UIFont.systemFont(ofSize: 17),
                                            .foregroundColor: UIColor.label]),
            for: .normal
        )
        btn.menu = UIMenu(title: "", children: [
            UIAction(title: "Local   ☐", image: nil) { [weak coordinator] _ in
                coordinator?.insertCheckbox()
            },
            UIAction(title: "Things  🔵", image: nil) { [weak coordinator] _ in
                coordinator?.insertCheckboxAndSend(to: .things)
            },
            UIAction(title: "Tweek  🪶", image: nil) { [weak coordinator] _ in
                coordinator?.insertCheckboxAndSend(to: .tweek)
            },
        ])
        btn.showsMenuAsPrimaryAction = true
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.widthAnchor.constraint(greaterThanOrEqualToConstant: 42).isActive = true
        btn.heightAnchor.constraint(equalToConstant: 43).isActive = true
        return btn
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
                             UIImagePickerControllerDelegate,
                             UINavigationControllerDelegate,
                             VNDocumentCameraViewControllerDelegate,
                             UIDocumentPickerDelegate {

        // MARK: - App target for task sends
        enum SendApp { case things, tweek }

        @Binding var text: String
        var onSave: ((String) -> Void)?
        var onFocusChange: ((Bool) -> Void)?
        var onBlockLongPress: ((BlockInfo) -> Void)?
        weak var textView: UITextView?
        private var saveWork: DispatchWorkItem?
        var lastTimestampTrigger: Date?
        /// NoteStore relative path — set by MarkdownEditorView so we can extract note date.
        var relativePath: String?
        /// Set to true when a long-press fires; prevents the tap gesture from
        /// also firing (which would open the photo immediately after the sheet appears).
        private var suppressNextTap = false
        /// Cache of loaded UIImages keyed by NoteStore path, for fast thumbnail redraws.
        private var thumbnailImageCache: [String: UIImage] = [:]
        /// Tag applied to UIImageViews overlaid for !![desc](path) thumbnail lines.
        private static let thumbnailTag = 8_001
        /// Paths for which an iCloud-download retry is already scheduled (prevents duplicate timers).
        private var thumbnailRetryPaths: Set<String> = []
        /// Tag applied to UIButtons overlaid for tappable checkbox circles (E2) and Things send buttons (E11).
        private static let checkboxOverlayTag = 9_002

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
            refreshThumbnails(in: tv)
            refreshCheckboxOverlays(in: tv)
            checkForTextExpansion(tv)
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
                // textViewDidChange may not fire when returning false — refresh overlays explicitly
                DispatchQueue.main.async { [weak self] in
                    if let tv = self?.textView { self?.refreshCheckboxOverlays(in: tv) }
                }
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

        // MARK: - Note date helpers

        /// Extracts the ISO date (YYYY-MM-DD) from the note's relativePath filename.
        /// Returns nil for non-daily notes (week notes, month notes, etc.).
        func noteDate() -> String? {
            guard let path = relativePath else { return nil }
            let pattern = #"\d{4}-\d{2}-\d{2}"#
            guard let range = path.range(of: pattern, options: .regularExpression) else { return nil }
            return String(path[range])
        }

        /// Strips any known send badge suffix from a line string (no newline manipulation).
        /// Used before retrying a failed send so the old badge is replaced cleanly.
        private func stripBadges(from line: String) -> String {
            var s = line.trimmingCharacters(in: .newlines)
            for badge in [" ⚠️🔵", " ⚠️🪶", " 🔵", " 🪶"] {
                if s.hasSuffix(badge) {
                    s = String(s.dropLast(badge.count))
                    break
                }
            }
            return s
        }

        // MARK: - E1: Long-press block detection

        @objc func handleLongPress(_ gr: UILongPressGestureRecognizer) {
            guard gr.state == .began, let tv = textView else { return }

            // Block the tap gesture from firing after this long-press completes
            suppressNextTap = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.suppressNextTap = false
            }

            let point = gr.location(in: tv)
            guard let textPos = tv.closestPosition(to: point) else { return }
            let charIndex = tv.offset(from: tv.beginningOfDocument, to: textPos)

            // Image/PDF attachment long-press takes priority over block detection
            if charIndex < tv.textStorage.length {
                let attrs = tv.textStorage.attributes(at: charIndex, effectiveRange: nil)
                if let path = attrs[.imageNoteStorePath] as? String {
                    handleAttachmentLongPress(at: charIndex, path: path, isImage: true)
                    return
                }
                if let path = attrs[.pdfNoteStorePath] as? String {
                    handleAttachmentLongPress(at: charIndex, path: path, isImage: false)
                    return
                }
            }

            // Fall through to block detection (E1)
            let fullText = tv.textStorage.string
            guard let blockInfo = findBlock(in: fullText, at: charIndex) else { return }

            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            DispatchQueue.main.async { [weak self] in
                self?.onBlockLongPress?(blockInfo)
            }
        }

        /// Long-press on an image/PDF link: shows Open / Edit Caption / Remove / Delete File options.
        private func handleAttachmentLongPress(at charIndex: Int, path: String, isImage: Bool) {
            guard let tv = textView, let vc = presentingViewController() else { return }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()

            let ns = tv.text as NSString
            let lineRange = ns.lineRange(for: NSRange(location: charIndex, length: 0))
            let line = ns.substring(with: lineRange)

            // .alert style centers on screen — avoids keyboard/popover positioning issues
            // that occur when presenting .actionSheet inside a SwiftUI .sheet.
            let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .alert)

            // Open viewer
            sheet.addAction(UIAlertAction(title: "Open", style: .default) { [weak self] _ in
                guard let self, let url = NoteStore.shared.resolvedURL(for: path) else { return }
                if isImage { self.showImageViewer(at: url) } else { self.showPDFViewer(at: url) }
            })

            // Edit caption / rename
            sheet.addAction(UIAlertAction(title: isImage ? "Edit Caption" : "Rename",
                                          style: .default) { [weak self] _ in
                guard let self else { return }
                // Extract current desc between first [ and ]
                let currentDesc: String
                if let openIdx = line.firstIndex(of: "["),
                   let afterOpen = line.index(openIdx, offsetBy: 1, limitedBy: line.endIndex),
                   let closeIdx = line.range(of: "]", range: afterOpen..<line.endIndex)?.lowerBound {
                    currentDesc = String(line[afterOpen..<closeIdx])
                } else {
                    currentDesc = ""
                }
                let alert = UIAlertController(
                    title: isImage ? "Edit Caption" : "Rename",
                    message: nil,
                    preferredStyle: .alert
                )
                alert.addTextField { tf in
                    tf.text = currentDesc
                    tf.autocapitalizationType = .sentences
                }
                alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self] _ in
                    guard let self else { return }
                    let newDesc = (alert.textFields?.first?.text ?? "")
                        .trimmingCharacters(in: .whitespaces)
                    var updatedLine = line
                    if let openIdx = updatedLine.firstIndex(of: "["),
                       let afterOpen = updatedLine.index(openIdx, offsetBy: 1,
                                                         limitedBy: updatedLine.endIndex),
                       let closeRange = updatedLine.range(of: "]",
                                                          range: afterOpen..<updatedLine.endIndex) {
                        updatedLine.replaceSubrange(afterOpen..<closeRange.lowerBound,
                                                    with: newDesc.isEmpty ? currentDesc : newDesc)
                    }
                    tv.textStorage.replaceCharacters(in: lineRange, with: updatedLine)
                    self.text = tv.text
                    self.scheduleSave(tv.text)
                })
                alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
                vc.present(alert, animated: true)
            })

            // Toggle thumbnail vs. plain link (images only)
            if isImage {
                let isThumbnail = line.hasPrefix("!![")
                sheet.addAction(UIAlertAction(
                    title: isThumbnail ? "Show as Link" : "Show Thumbnail",
                    style: .default
                ) { [weak self] _ in
                    guard let self, let tv = self.textView else { return }
                    let updatedLine = isThumbnail
                        ? String(line.dropFirst(1))   // "!![…" → "![…"
                        : "!" + line                  // "![…"  → "!![…"
                    tv.textStorage.replaceCharacters(in: lineRange, with: updatedLine)
                    self.text = tv.text
                    self.scheduleSave(tv.text)
                    self.refreshThumbnails(in: tv)
                })
            }

            // Remove link from note (file stays in iCloud)
            sheet.addAction(UIAlertAction(title: "Remove from Note",
                                          style: .destructive) { [weak self] _ in
                guard let self, let tv = self.textView else { return }
                tv.textStorage.replaceCharacters(in: lineRange, with: "")
                self.text = tv.text
                self.scheduleSave(tv.text)
                self.refreshThumbnails(in: tv)
            })

            // Delete file + remove from note
            sheet.addAction(UIAlertAction(title: isImage ? "Delete Photo" : "Delete File",
                                          style: .destructive) { [weak self] _ in
                guard let self else { return }
                let confirm = UIAlertController(
                    title: isImage ? "Delete Photo?" : "Delete File?",
                    message: "Permanently deletes the file. Cannot be undone.",
                    preferredStyle: .alert
                )
                confirm.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
                    guard let self, let tv = self.textView else { return }
                    tv.textStorage.replaceCharacters(in: lineRange, with: "")
                    self.text = tv.text
                    self.scheduleSave(tv.text)
                    self.refreshThumbnails(in: tv)
                    try? NoteStore.shared.deleteFile(path)
                })
                confirm.addAction(UIAlertAction(title: "Cancel", style: .cancel))
                vc.present(confirm, animated: true)
            })

            sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            vc.present(sheet, animated: true)
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

        @objc func insertDate() {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "MMMM d, yyyy"
            insertAtCursor(formatter.string(from: Date()))
        }

        @objc func dismissKeyboard() {
            textView?.resignFirstResponder()
        }

        // MARK: - Image and PDF viewers

        private func showImageViewer(at url: URL) {
            guard let vc = presentingViewController() else { return }
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            let host = UIHostingController(rootView: PhotoViewerSheet(url: url))
            host.modalPresentationStyle = .fullScreen
            vc.present(host, animated: true)
        }

        private func showPDFViewer(at url: URL) {
            guard let vc = presentingViewController() else { return }
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            let host = UIHostingController(rootView: PDFViewerSheet(url: url))
            host.modalPresentationStyle = .pageSheet
            vc.present(host, animated: true)
        }

        // MARK: - Attachment description prompt
        //
        // Unified prompt for both images (![desc](path)) and PDFs (📎 [desc](path)).
        // `defaultDesc` pre-fills the field and is used as fallback on Skip.

        private func promptForAttachmentDescription(path: String,
                                                     isImage: Bool,
                                                     defaultDesc: String = "") {
            // Strong self: this can be called after camera/picker dismissal, when SwiftUI
            // may have unmounted the view. A weak ref would be nil and nothing would insert.
            let insert: (String) -> Void = { [self] desc in
                if isImage {
                    self.insertAtCursor("![\(desc)](\(path))")
                } else {
                    self.insertAtCursor("📎 [\(desc)](\(path))")
                }
            }
            guard let vc = presentingViewController() else {
                insert(defaultDesc)
                return
            }
            let alert = UIAlertController(
                title: isImage ? "Photo Caption" : "Document Name",
                message: "Optional — shown in the note",
                preferredStyle: .alert
            )
            alert.addTextField { tf in
                tf.text = defaultDesc
                tf.placeholder = isImage ? "e.g. OT Stats June 27" : "e.g. Boarding Pass"
                tf.autocapitalizationType = .sentences
            }
            alert.addAction(UIAlertAction(title: "Add", style: .default) { _ in
                let desc = alert.textFields?.first?.text?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                insert(desc.isEmpty ? defaultDesc : desc)
            })
            alert.addAction(UIAlertAction(title: "Skip", style: .cancel) { _ in
                insert(defaultDesc)
            })
            vc.present(alert, animated: true)
        }

        // MARK: - Attach menu triggers (called from UIMenu UIActions)
        // UIMenu dismisses itself before calling these, so presentingViewController()
        // finds the correct VC without any timing or keyboard issues.

        func triggerCameraCapture() {
            guard let vc = presentingViewController() else { return }
            showCameraPicker(from: vc)
        }
        func triggerPhotoLibrary() {
            guard let vc = presentingViewController() else { return }
            showPhotoPicker(from: vc)
        }
        func triggerDocumentCamera() {
            guard let vc = presentingViewController() else { return }
            showDocumentCamera(from: vc)
        }
        func triggerDocumentPicker() {
            guard let vc = presentingViewController() else { return }
            showDocumentPicker(from: vc)
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
            guard gr.state == .ended, !suppressNextTap, let tv = textView else { return }

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

            // Check for tappable image or PDF attachment before line-level handling
            let tapAttrs = tv.textStorage.attributes(at: charIdx, effectiveRange: nil)
            if let path = tapAttrs[.imageNoteStorePath] as? String,
               let url = NoteStore.shared.resolvedURL(for: path) {
                showImageViewer(at: url)
                return
            }
            if let path = tapAttrs[.pdfNoteStorePath] as? String,
               let url = NoteStore.shared.resolvedURL(for: path) {
                showPDFViewer(at: url)
                return
            }

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
            if let tv = textView {
                // Text view is live — insert directly into storage.
                let insertLoc: Int
                if tv.isFirstResponder, let sel = tv.selectedTextRange {
                    insertLoc = tv.offset(from: tv.beginningOfDocument, to: sel.end)
                } else {
                    insertLoc = tv.textStorage.length
                }
                let safeInsertLoc = min(insertLoc, tv.textStorage.length)
                tv.textStorage.replaceCharacters(
                    in: NSRange(location: safeInsertLoc, length: 0),
                    with: str
                )
                text = tv.text
                scheduleSave(tv.text)
            } else {
                // textView is nil — SwiftUI dismounted the view (e.g. while camera was fullscreen).
                // Update the binding directly; updateUIView will sync it to the text view on
                // the next render cycle.
                let updated = text + str
                text = updated
                onSave?(updated)
            }
        }


        // MARK: - Thumbnail image overlay

        // Scans the text storage for !![desc](path) lines and overlays UIImageViews
        // at the correct content-coordinate positions. Called after every text change
        // and on initial load. The overlays scroll with the text view (they are
        // subviews of UITextView which is a UIScrollView — subview frames are in
        // content coordinate space, not viewport space).

        func refreshThumbnails(in tv: UITextView) {
            // Remove previous overlays
            tv.subviews
                .filter { $0.tag == Self.thumbnailTag }
                .forEach { $0.removeFromSuperview() }

            // Find all !![desc](path) lines
            guard let regex = try? NSRegularExpression(
                pattern: #"^!!\[([^\]]*)\]\(([^)]+)\)"#,
                options: .anchorsMatchLines
            ) else { return }
            let ns = tv.textStorage.string as NSString
            let matches = regex.matches(
                in: tv.textStorage.string,
                range: NSRange(location: 0, length: ns.length)
            )
            guard !matches.isEmpty else { return }

            // Ensure layout is current before querying rects
            tv.layoutManager.ensureLayout(for: tv.textContainer)

            for match in matches {
                guard match.range(at: 2).location != NSNotFound else { continue }
                let path = ns.substring(with: match.range(at: 2))

                // Load image — try direct read first (fast path for locally-present files).
                // Only trigger iCloud download and schedule a single retry if the direct read fails.
                let image: UIImage?
                if let cached = thumbnailImageCache[path] {
                    image = cached
                } else if let url = NoteStore.shared.resolvedURL(for: path) {
                    if let data = try? Data(contentsOf: url),
                       let loaded = UIImage(data: data) {
                        thumbnailImageCache[path] = loaded
                        image = loaded
                    } else {
                        // File not local yet — request download and retry once after 1.5 s.
                        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                        if !thumbnailRetryPaths.contains(path) {
                            thumbnailRetryPaths.insert(path)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                                self?.thumbnailRetryPaths.remove(path)
                                if let tv = self?.textView {
                                    self?.refreshThumbnails(in: tv)
                                }
                            }
                        }
                        image = nil
                    }
                } else {
                    image = nil
                }
                guard let img = image else { continue }

                // Line rect in text-container coords → shift by textContainerInset
                let lineCharRange = ns.lineRange(for: match.range)
                let glyphRange = tv.layoutManager.glyphRange(
                    forCharacterRange: lineCharRange, actualCharacterRange: nil)
                var lineRect = tv.layoutManager.boundingRect(
                    forGlyphRange: glyphRange, in: tv.textContainer)
                lineRect = lineRect.offsetBy(
                    dx: tv.textContainerInset.left,
                    dy: tv.textContainerInset.top)

                // Scale to fit, preserving aspect ratio, max 196pt height
                let availableWidth = lineRect.width
                let maxHeight: CGFloat = 196
                let scale = min(availableWidth / img.size.width,
                                maxHeight / img.size.height,
                                1.0)
                let displaySize = CGSize(width:  img.size.width  * scale,
                                        height: img.size.height * scale)

                let iv = UIImageView(frame: CGRect(
                    x: lineRect.origin.x,
                    y: lineRect.origin.y + (lineRect.height - displaySize.height) / 2,
                    width:  displaySize.width,
                    height: displaySize.height
                ))
                iv.image = img
                iv.contentMode = .scaleAspectFit
                iv.layer.cornerRadius = 6
                iv.clipsToBounds = true
                iv.tag = Self.thumbnailTag
                iv.isUserInteractionEnabled = false
                tv.addSubview(iv)
            }
        }

        // MARK: - Checkbox circle overlays (E2) + send buttons (E11/Tweek)
        //
        // Scans for `- [ ]` / `- [x]` lines. For each:
        //  • Circle UIButton at left indent — toggles checkbox.
        //  • Right-edge button based on badge state:
        //      no badge        → UIMenu "Send to…" (Things + Tweek)
        //      🔵 or 🪶        → nothing (already sent)
        //      ⚠️🔵 or ⚠️🪶   → retry button for the appropriate app
        // Called after every text change and on initial load.

        func refreshCheckboxOverlays(in tv: UITextView) {
            tv.subviews
                .filter { $0.tag == Self.checkboxOverlayTag }
                .forEach { $0.removeFromSuperview() }

            tv.layoutManager.ensureLayout(for: tv.textContainer)

            let ns = tv.textStorage.string as NSString
            var pos = 0
            while pos < ns.length {
                let lineRange = ns.lineRange(for: NSRange(location: pos, length: 0))
                guard lineRange.length > 0 else { break }
                let line = ns.substring(with: lineRange)

                if line.hasPrefix("- [ ]") || line.hasPrefix("- [x]") {
                    let isChecked = line.hasPrefix("- [x]")

                    let glyphIdx = tv.layoutManager.glyphIndexForCharacter(at: lineRange.location)
                    let lineFragRect = tv.layoutManager.lineFragmentRect(
                        forGlyphAt: glyphIdx, effectiveRange: nil)
                    let lineY = lineFragRect.origin.y + tv.textContainerInset.top
                    let lineH = lineFragRect.height

                    // --- Circle toggle button ---
                    let circleSize: CGFloat = 18
                    let circleBtn = UIButton(type: .custom)
                    circleBtn.frame = CGRect(
                        x: tv.textContainerInset.left + 1,
                        y: lineY + (lineH - circleSize) / 2,
                        width: circleSize, height: circleSize)
                    circleBtn.tag = Self.checkboxOverlayTag
                    let symCfg   = UIImage.SymbolConfiguration(pointSize: 15, weight: .regular)
                    let symName  = isChecked ? "checkmark.circle.fill" : "circle"
                    let symColor : UIColor = isChecked
                        ? MarkdownTextStorage.checkColor
                        : MarkdownTextStorage.uncheckColor
                    circleBtn.setImage(
                        UIImage(systemName: symName, withConfiguration: symCfg)?
                            .withTintColor(symColor, renderingMode: .alwaysOriginal),
                        for: .normal)
                    let captureLoc = lineRange.location
                    let captureLen = lineRange.length
                    circleBtn.addAction(UIAction { [weak self, weak tv] _ in
                        guard let self, let tv else { return }
                        let nsNow  = tv.text as NSString
                        let safeL  = min(captureLen, nsNow.length - captureLoc)
                        guard safeL > 0, captureLoc + safeL <= nsNow.length else { return }
                        let lr     = NSRange(location: captureLoc, length: safeL)
                        let cur    = nsNow.substring(with: lr)
                        if cur.hasPrefix("- [ ]") {
                            tv.textStorage.replaceCharacters(in: lr, with: "- [x]" + cur.dropFirst(5))
                        } else if cur.hasPrefix("- [x]") {
                            tv.textStorage.replaceCharacters(in: lr, with: "- [ ]" + cur.dropFirst(5))
                        }
                        self.text = tv.text; self.scheduleSave(tv.text)
                    }, for: .touchUpInside)
                    tv.addSubview(circleBtn)

                    // --- Right-edge send / retry button (unchecked lines only) ---
                    guard !isChecked else {
                        pos = lineRange.location + lineRange.length
                        if lineRange.length == 0 { break }
                        continue
                    }
                    let rawTitle = String(line.dropFirst(6))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !rawTitle.isEmpty else {
                        pos = lineRange.location + lineRange.length
                        if lineRange.length == 0 { break }
                        continue
                    }

                    let hasSentThings   = rawTitle.hasSuffix("🔵") && !rawTitle.hasSuffix("⚠️🔵")
                    let hasSentTweek    = rawTitle.hasSuffix("🪶") && !rawTitle.hasSuffix("⚠️🪶")
                    let hasWarnThings   = rawTitle.hasSuffix("⚠️🔵")
                    let hasWarnTweek    = rawTitle.hasSuffix("⚠️🪶")

                    if hasSentThings || hasSentTweek {
                        // Already sent — no button.
                    } else if hasWarnThings || hasWarnTweek {
                        // Retry button — orange exclamationmark.circle
                        let retryApp: SendApp = hasWarnThings ? .things : .tweek
                        let cleanTitle = stripBadges(from: rawTitle)
                        let btnSize: CGFloat = 16
                        let retryBtn = UIButton(type: .custom)
                        retryBtn.frame = CGRect(
                            x: tv.bounds.width - tv.textContainerInset.right - btnSize - 4,
                            y: lineY + (lineH - btnSize) / 2,
                            width: btnSize, height: btnSize)
                        retryBtn.tag = Self.checkboxOverlayTag
                        let rCfg = UIImage.SymbolConfiguration(pointSize: 12, weight: .light)
                        retryBtn.setImage(
                            UIImage(systemName: "exclamationmark.circle", withConfiguration: rCfg)?
                                .withTintColor(UIColor.systemOrange, renderingMode: .alwaysOriginal),
                            for: .normal)
                        retryBtn.addAction(UIAction { [weak self, weak tv] _ in
                            guard let self, let tv else { return }
                            // Strip the warning badge from backing store before retrying.
                            let nsNow  = tv.text as NSString
                            let safeL  = min(captureLen, nsNow.length - captureLoc)
                            guard safeL > 0, captureLoc + safeL <= nsNow.length else { return }
                            let lr     = NSRange(location: captureLoc, length: safeL)
                            let rawLine = nsNow.substring(with: lr)
                            let stripped = self.stripBadges(from: rawLine)
                            tv.textStorage.replaceCharacters(in: lr, with: stripped + "\n")
                            self.text = tv.text; self.scheduleSave(tv.text)
                            let newNs       = tv.text as NSString
                            let newLineRange = newNs.lineRange(for: NSRange(location: captureLoc, length: 0))
                            let date = self.noteDate()
                            switch retryApp {
                            case .things:
                                self.sendToThings(taskTitle: cleanTitle, date: date,
                                                   lineLocation: newLineRange.location,
                                                   lineLength: newLineRange.length, in: tv)
                            case .tweek:
                                self.sendToTweek(taskTitle: cleanTitle, date: date,
                                                  lineLocation: newLineRange.location,
                                                  lineLength: newLineRange.length, in: tv)
                            }
                        }, for: .touchUpInside)
                        tv.addSubview(retryBtn)

                    } else {
                        // Send UIMenu button — arrow.up.right.circle with Things + Tweek options
                        let sendSize: CGFloat = 16
                        let sendBtn = UIButton(type: .custom)
                        sendBtn.frame = CGRect(
                            x: tv.bounds.width - tv.textContainerInset.right - sendSize - 4,
                            y: lineY + (lineH - sendSize) / 2,
                            width: sendSize, height: sendSize)
                        sendBtn.tag = Self.checkboxOverlayTag
                        let sCfg = UIImage.SymbolConfiguration(pointSize: 12, weight: .light)
                        sendBtn.setImage(
                            UIImage(systemName: "arrow.up.right.circle", withConfiguration: sCfg)?
                                .withTintColor(UIColor.systemBlue.withAlphaComponent(0.55),
                                               renderingMode: .alwaysOriginal),
                            for: .normal)
                        let captureTitle = rawTitle
                        sendBtn.menu = UIMenu(title: "", children: [
                            UIAction(title: "Things  🔵", image: nil) { [weak self, weak tv] _ in
                                guard let self, let tv else { return }
                                self.sendToThings(taskTitle: captureTitle, date: self.noteDate(),
                                                   lineLocation: captureLoc, lineLength: captureLen,
                                                   in: tv)
                            },
                            UIAction(title: "Tweek  🪶", image: nil) { [weak self, weak tv] _ in
                                guard let self, let tv else { return }
                                self.sendToTweek(taskTitle: captureTitle, date: self.noteDate(),
                                                  lineLocation: captureLoc, lineLength: captureLen,
                                                  in: tv)
                            },
                        ])
                        sendBtn.showsMenuAsPrimaryAction = true
                        tv.addSubview(sendBtn)
                    }
                }

                pos = lineRange.location + lineRange.length
                if lineRange.length == 0 { break }
            }
        }

        // MARK: - Insert checkbox + immediately send (toolbar picker shortcut)

        func insertCheckboxAndSend(to app: SendApp) {
            guard let tv = textView else { return }
            let cursorRange = tv.selectedRange
            let ns = tv.text as NSString
            let lineRange = ns.lineRange(for: NSRange(location: cursorRange.location, length: 0))
            let line = ns.substring(with: lineRange)

            // Task title = current line content (stripped of any existing checkbox prefix)
            var rawTitle = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if rawTitle.hasPrefix("- [ ] ") { rawTitle = String(rawTitle.dropFirst(6)) }
            else if rawTitle.hasPrefix("- [x] ") { rawTitle = String(rawTitle.dropFirst(6)) }

            // Insert checkbox prefix if not already present
            let alreadyCheckbox = line.hasPrefix("- [ ] ") || line.hasPrefix("- [x] ")
            if !alreadyCheckbox {
                if let insertPos = tv.position(from: tv.beginningOfDocument,
                                                offset: lineRange.location),
                   let r = tv.textRange(from: insertPos, to: insertPos) {
                    tv.replace(r, withText: "- [ ] ")
                }
            }
            text = tv.text; scheduleSave(tv.text)

            guard !rawTitle.isEmpty else { return }   // nothing to send on an empty line

            // Recompute line range after insertion
            let newNs        = tv.text as NSString
            let newLineRange = newNs.lineRange(for: NSRange(location: lineRange.location, length: 0))
            let date = noteDate()
            switch app {
            case .things:
                sendToThings(taskTitle: rawTitle, date: date,
                             lineLocation: newLineRange.location,
                             lineLength: newLineRange.length, in: tv)
            case .tweek:
                sendToTweek(taskTitle: rawTitle, date: date,
                             lineLocation: newLineRange.location,
                             lineLength: newLineRange.length, in: tv)
            }
        }

        // MARK: - E11 / Tweek: Send task to external app
        //
        // Things:  Mini server first (POST /add, 4-second timeout), URL scheme fallback.
        // Tweek:   Mini server only (POST /tweek-add, 4-second timeout), no URL scheme fallback.
        // On success: appends ` 🔵` / ` 🪶`.
        // On failure: appends ` ⚠️🔵` / ` ⚠️🪶` — tap the orange retry button to retry.
        // Simulator: both paths skipped to avoid error noise during development.

        private func sendToThings(taskTitle: String,
                                   date: String?,
                                   lineLocation: Int,
                                   lineLength: Int,
                                   in tv: UITextView) {
#if targetEnvironment(simulator)
            return   // skip network calls in simulator
#endif
            let baseURL = UserDefaults.standard.string(forKey: "things_api_url") ?? ""
            let token   = UserDefaults.standard.string(forKey: "things_api_token") ?? ""

            if !baseURL.isEmpty, let serverURL = URL(string: baseURL + "/add") {
                var request = URLRequest(url: serverURL,
                                         cachePolicy: .reloadIgnoringLocalCacheData,
                                         timeoutInterval: 4)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
                var body: [String: String] = ["title": taskTitle, "notes": "From Trace"]
                if let d = date, !d.isEmpty { body["date"] = d }
                request.httpBody = try? JSONSerialization.data(withJSONObject: body)

                URLSession.shared.dataTask(with: request) { [weak self, weak tv] _, response, error in
                    DispatchQueue.main.async {
                        guard let self, let tv else { return }
                        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                        if error == nil && code == 200 {
                            self.appendBadge(" 🔵", lineLocation: lineLocation, lineLength: lineLength, in: tv)
                        } else {
                            self.openThingsURLScheme(taskTitle: taskTitle, date: date,
                                                     lineLocation: lineLocation, lineLength: lineLength, in: tv)
                        }
                    }
                }.resume()
            } else {
                openThingsURLScheme(taskTitle: taskTitle, date: date,
                                    lineLocation: lineLocation, lineLength: lineLength, in: tv)
            }
        }

        private func openThingsURLScheme(taskTitle: String,
                                          date: String?,
                                          lineLocation: Int,
                                          lineLength: Int,
                                          in tv: UITextView) {
#if targetEnvironment(simulator)
            return
#endif
            var comps = URLComponents(string: "things:///add")!
            var items: [URLQueryItem] = [
                URLQueryItem(name: "title", value: taskTitle),
                URLQueryItem(name: "notes", value: "From Trace"),
                URLQueryItem(name: "show-quick-entry", value: "false"),
            ]
            if let d = date, !d.isEmpty {
                items.append(URLQueryItem(name: "when", value: d))
            }
            comps.queryItems = items
            guard let url = comps.url else {
                appendBadge(" ⚠️🔵", lineLocation: lineLocation, lineLength: lineLength, in: tv)
                return
            }
            UIApplication.shared.open(url, options: [:]) { [weak self, weak tv] success in
                guard let self, let tv else { return }
                DispatchQueue.main.async {
                    self.appendBadge(success ? " 🔵" : " ⚠️🔵",
                                     lineLocation: lineLocation, lineLength: lineLength, in: tv)
                }
            }
        }

        private func sendToTweek(taskTitle: String,
                                  date: String?,
                                  lineLocation: Int,
                                  lineLength: Int,
                                  in tv: UITextView) {
#if targetEnvironment(simulator)
            return
#endif
            let baseURL = UserDefaults.standard.string(forKey: "things_api_url") ?? ""
            let token   = UserDefaults.standard.string(forKey: "things_api_token") ?? ""

            guard !baseURL.isEmpty, let serverURL = URL(string: baseURL + "/tweek-add") else {
                appendBadge(" ⚠️🪶", lineLocation: lineLocation, lineLength: lineLength, in: tv)
                return
            }
            var request = URLRequest(url: serverURL,
                                     cachePolicy: .reloadIgnoringLocalCacheData,
                                     timeoutInterval: 4)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            var body: [String: String] = ["title": taskTitle]
            if let d = date, !d.isEmpty { body["date"] = d }
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)

            URLSession.shared.dataTask(with: request) { [weak self, weak tv] _, response, error in
                DispatchQueue.main.async {
                    guard let self, let tv else { return }
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    self.appendBadge(error == nil && code == 200 ? " 🪶" : " ⚠️🪶",
                                     lineLocation: lineLocation, lineLength: lineLength, in: tv)
                }
            }.resume()
        }

        /// Appends a badge string to the task line, stripping any prior badge first.
        private func appendBadge(_ badge: String, lineLocation: Int, lineLength: Int, in tv: UITextView) {
            let ns = tv.text as NSString
            let safeLen = min(lineLength, ns.length - lineLocation)
            guard safeLen > 0, lineLocation + safeLen <= ns.length else { return }
            let lr = NSRange(location: lineLocation, length: safeLen)
            let currentLine = ns.substring(with: lr)
            let stripped = stripBadges(from: currentLine)
            tv.textStorage.replaceCharacters(in: lr, with: stripped + badge + "\n")
            text = tv.text
            scheduleSave(tv.text)
        }

        // MARK: - E5: Text expansion — `xdt` → today's date

        private func checkForTextExpansion(_ tv: UITextView) {
            let cursorLoc = tv.selectedRange.location
            guard cursorLoc >= 3 else { return }
            let ns = tv.text as NSString
            let startLoc = cursorLoc - 3
            let last3 = ns.substring(with: NSRange(location: startLoc, length: 3))
            guard last3 == "xdt" else { return }

            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "MMMM d, yyyy"
            let dateStr = formatter.string(from: Date())
            tv.textStorage.replaceCharacters(
                in: NSRange(location: startLoc, length: 3), with: dateStr)
            tv.selectedRange = NSRange(location: startLoc + (dateStr as NSString).length, length: 0)
            text = tv.text
            scheduleSave(tv.text)
        }

        // MARK: - Presenting helpers

        private func presentingViewController() -> UIViewController? {
            // Walk the responder chain up from the text view — more reliable than
            // walking down from rootViewController in SwiftUI UIViewRepresentable contexts.
            var responder: UIResponder? = textView
            while let r = responder {
                if let vc = r as? UIViewController {
                    return vc.topmostViewController()
                }
                responder = r.next
            }
            // Fallback: key window root
            return UIApplication.shared.connectedScenes
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
            guard let result = results.first else {
                picker.dismiss(animated: true)
                return
            }
            // Dismiss first so the picker is fully gone before we touch the text view.
            // No caption prompt — inserts directly. User can long-press to rename.
            picker.dismiss(animated: true) { [weak self] in
                guard let self else { return }
                result.itemProvider.loadDataRepresentation(
                    forTypeIdentifier: "public.image"
                ) { [weak self] data, _ in
                    guard let self, let data else { return }
                    let now = Date()
                    let cal = Calendar.current
                    let year = cal.component(.year, from: now)
                    let month = String(format: "%02d", cal.component(.month, from: now))
                    let formatter = DateFormatter()
                    formatter.locale = Locale(identifier: "en_US_POSIX")
                    formatter.dateFormat = "yyyy-MM-dd-HHmmss"
                    let filename = "\(formatter.string(from: now)).jpg"
                    let jpegData = UIImage(data: data).flatMap { $0.jpegData(compressionQuality: 0.85) } ?? data
                    Task {
                        do {
                            let path = try NoteStore.shared.writePhoto(jpegData, category: "\(year)/\(month)", filename: filename)
                            await MainActor.run {
                                self.promptForAttachmentDescription(path: path, isImage: true)
                            }
                        } catch { }
                    }
                }
            }
        }

        // MARK: - Camera picker (Take Photo → JPEG → NoteStore)

        private func showCameraPicker(from vc: UIViewController) {
            guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
                let alert = UIAlertController(title: "Camera Unavailable",
                                             message: "Camera is not supported on this device.",
                                             preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                vc.present(alert, animated: true)
                return
            }
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            switch status {
            case .authorized:
                presentCameraPickerUI(from: vc)
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        if granted {
                            self.presentCameraPickerUI(from: vc)
                        } else {
                            let alert = UIAlertController(
                                title: "Camera Access Denied",
                                message: "Enable camera access in Settings → Privacy & Security → Camera.",
                                preferredStyle: .alert
                            )
                            alert.addAction(UIAlertAction(title: "Open Settings", style: .default) { _ in
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    UIApplication.shared.open(url)
                                }
                            })
                            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
                            vc.present(alert, animated: true)
                        }
                    }
                }
            case .denied, .restricted:
                let alert = UIAlertController(
                    title: "Camera Access Required",
                    message: "Enable camera access in Settings → Privacy → Camera.",
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: "Open Settings", style: .default) { _ in
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                })
                alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
                vc.present(alert, animated: true)
            @unknown default:
                presentCameraPickerUI(from: vc)
            }
        }

        private func presentCameraPickerUI(from vc: UIViewController) {
            let picker = UIImagePickerController()
            picker.sourceType = .camera
            picker.delegate = self
            vc.present(picker, animated: true)
        }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            guard let image = info[.originalImage] as? UIImage,
                  let data = image.jpegData(compressionQuality: 0.85) else {
                picker.dismiss(animated: true)
                return
            }
            let now = Date()
            let cal = Calendar.current
            let year = cal.component(.year, from: now)
            let month = String(format: "%02d", cal.component(.month, from: now))
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd-HHmmss"
            let filename = "\(formatter.string(from: now)).jpg"
            picker.dismiss(animated: true) { [self] in
                do {
                    let path = try NoteStore.shared.writePhoto(data, category: "\(year)/\(month)", filename: filename)
                    // Brief delay: camera dismissal leaves the window hierarchy in a
                    // transitional state. presentingViewController() finds nil immediately
                    // after dismiss; a short wait lets UIKit restore the key window.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        self.promptForAttachmentDescription(path: path, isImage: true,
                                                           defaultDesc: "photo")
                    }
                } catch {
                    self.insertAtCursor("![photo - save failed](error)\n")
                }
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
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
                    let path = try NoteStore.shared.writeDocument(pdfData, category: "Scans", filename: filename)
                    await MainActor.run {
                        self.insertAtCursor("📎 [Scan](\(path))\n")
                    }
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
                    await MainActor.run {
                        self.insertAtCursor("📎 [\(displayName)](\(path))\n")
                    }
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

// MARK: - PhotoViewerSheet
// Full-screen photo viewer presented when user taps an ![desc](path) image link.
// Supports pinch-to-zoom via ZoomableImageView. Share button shares the file URL.

struct PhotoViewerSheet: View {
    let url: URL
    @State private var image: UIImage?
    @State private var isLoading = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if isLoading {
                    ProgressView().tint(.white)
                } else if let img = image {
                    ZoomableImageView(image: img)
                        .ignoresSafeArea()
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "photo.slash")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("Could not load image")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .task {
                // Trigger iCloud download if the file is not yet local
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                if let data = try? Data(contentsOf: url) {
                    image = UIImage(data: data)
                }
                isLoading = false
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(.white)
                }
                if image != nil {
                    ToolbarItem(placement: .primaryAction) {
                        ShareLink(item: url) {
                            Image(systemName: "square.and.arrow.up")
                                .foregroundStyle(.white)
                        }
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }
}

// MARK: - ZoomableImageView
// UIScrollView-backed image view with pinch-to-zoom (1x–5x).

struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = 5.0
        scrollView.backgroundColor = .black
        scrollView.delegate = context.coordinator
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false

        let iv = UIImageView(image: image)
        iv.contentMode = .scaleAspectFit
        iv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        iv.frame = scrollView.bounds
        scrollView.addSubview(iv)
        context.coordinator.imageView = iv
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {}

    func makeCoordinator() -> ZoomCoordinator { ZoomCoordinator() }

    final class ZoomCoordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    }
}

// MARK: - PDFViewerSheet
// Page-sheet PDF viewer presented when user taps a 📎 [desc](path) link.
// Uses PDFKit for rendering; share button shares the file URL.

struct PDFViewerSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var title: String {
        url.deletingPathExtension().lastPathComponent
    }

    var body: some View {
        NavigationStack {
            PDFKitView(url: url)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        ShareLink(item: url) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
        }
    }
}

// MARK: - PDFKitView

struct PDFKitView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        // Trigger iCloud download if needed before PDFKit tries to read the file
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.backgroundColor = UIColor.systemGroupedBackground
        if let doc = PDFDocument(url: url) {
            pdfView.document = doc
        }
        return pdfView
    }

    func updateUIView(_ pdfView: PDFView, context: Context) {
        // Re-load if document is nil (e.g. iCloud file became available after initial render)
        if pdfView.document == nil, let doc = PDFDocument(url: url) {
            pdfView.document = doc
        }
    }
}
