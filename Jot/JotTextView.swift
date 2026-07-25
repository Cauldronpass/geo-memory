// JotTextView.swift — new file, Jot app target.
//
// Replaces CaptureView.swift's plain SwiftUI `TextEditor` with a `UITextView`
// wrapper. Added 2026-07-24 alongside the formatting toolbar
// (JotFormattingToolbar.swift) — SwiftUI's plain `TextEditor(text:)` has no
// reliable way to read/set the cursor position or attach a custom keyboard
// accessory view, both of which the toolbar buttons need (insert/wrap text
// at the cursor, and the toolbar itself has to BE the `inputAccessoryView`).
//
// Deliberately mirrors `MarkdownEditorView.swift`'s own proven
// `UITextView` + `inputAccessoryView` + `UIHostingController`-presented
// reorder-sheet pattern (that file already does exactly this for Trace/
// Dayflow's Notes editor) rather than reaching for newer SwiftUI APIs
// (`TextEditor(text:selection:)`) this environment has no way to
// compile/verify — same "pick the API already proven working in this
// project" reasoning used elsewhere (see DayflowWidget.swift's
// `.periodic(from:by:)` comment for the same call made on a different API).
//
// **What's intentionally NOT here**, unlike MarkdownEditorView.swift: no
// custom `NSTextStorage` subclass, no live markdown-hiding/highlighting, no
// checkbox SF Symbol overlay. This is a plain `UITextView` — Jot shows the
// raw characters (`☐ `, `• `, `**bold**`) as you type, matching its
// existing "raw text, Drafts-style" design. See JotFormattingToolbar.swift's
// header comment for why those specific characters were chosen (they match
// what Dayflow's Notes editor already renders as real checkboxes/bullets).
//
// **Quick Pin, added 2026-07-25** (see CaptureView.swift's header comment
// for the full feature writeup). `onPinSucceeded`/`onPinFailed` are plain
// closures, not bindings — the pin flow is fire-and-forget from
// CaptureView's perspective (it just wants to know when to flash the
// confirmation pill or show an error), unlike `text` which is a live
// two-way value. `dropPin()` itself lives on `Coordinator` below, next to
// the other five formatting actions, so it's just another toolbar button
// from the button-wiring code's perspective — the only thing setting it
// apart is that it's `async` and doesn't touch `text` until the Notion
// save actually succeeds.

import SwiftUI
import UIKit
import CoreLocation

struct JotTextView: UIViewRepresentable {
    @Binding var text: String
    var font: UIFont = .systemFont(ofSize: 17)
    var onPinSucceeded: () -> Void = {}
    var onPinFailed: (String) -> Void = { _ in }
    /// Fires with the capture's Notion page ID when a
    /// `[label](capture://open?id=ID)` marker is tapped — Session 45
    /// addendum 6. Plain closure, not a
    /// binding, same "fire and forget, caller decides what to do" shape as
    /// onPinSucceeded/onPinFailed above.
    var onCaptureTap: (String) -> Void = { _ in }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.font = font
        tv.text = text
        tv.backgroundColor = .clear
        tv.textContainerInset = UIEdgeInsets(top: 8, left: 6, bottom: 8, right: 6)
        tv.delegate = context.coordinator
        tv.inputAccessoryView = context.coordinator.makeToolbar(for: tv)

        // Capture-marker tap detection — Session 45 addendum 6. Jot has no
        // custom NSTextStorage/attribute system (see this file's header
        // comment), so unlike MarkdownEditorView.swift's handleTap (which
        // reads a hidden .wikiTarget attribute), this scans the raw text with
        // the same [label](capture://open?id=ID) pattern applyMarkdownLinks()
        // already uses for markdown links, and Jot shows that raw bracket syntax on
        // screen same as it already does for **bold**/☐ — matches David's
        // "first option" call (2026-07-25). Mirrors MarkdownEditorView.swift's
        // own tap-gesture setup (delegate + shouldRecognizeSimultaneouslyWith
        // true) so this doesn't block UITextView's own cursor-placement tap.
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        tap.delegate = context.coordinator
        tv.addGestureRecognizer(tap)

        // Auto-focus — Jot's whole point is opening straight into an active
        // text field. `becomeFirstResponder()` called synchronously here can
        // silently no-op before the view is actually in the window hierarchy,
        // so it's deferred one runloop tick, a standard, reliable fix for
        // that specific timing issue.
        DispatchQueue.main.async {
            tv.becomeFirstResponder()
        }
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        // Only push external changes (e.g. CaptureView's day-reset clearing
        // the field) into the UITextView — an unconditional `tv.text = text`
        // on every SwiftUI re-render would reset the cursor to the start on
        // every keystroke, since typing itself already round-trips through
        // `textViewDidChange` → the `text` binding, making this a no-op
        // check most of the time, not a real external change.
        if tv.text != text {
            tv.text = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onPinSucceeded: onPinSucceeded, onPinFailed: onPinFailed, onCaptureTap: onCaptureTap)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        var text: Binding<String>
        var onPinSucceeded: () -> Void
        var onPinFailed: (String) -> Void
        var onCaptureTap: (String) -> Void
        weak var textView: UITextView?
        weak var formattingStack: UIStackView?
        weak var toolbarContainer: UIView?

        init(text: Binding<String>, onPinSucceeded: @escaping () -> Void, onPinFailed: @escaping (String) -> Void, onCaptureTap: @escaping (String) -> Void) {
            self.text = text
            self.onPinSucceeded = onPinSucceeded
            self.onPinFailed = onPinFailed
            self.onCaptureTap = onCaptureTap
        }

        func textViewDidChange(_ tv: UITextView) {
            text.wrappedValue = tv.text
        }

        func gestureRecognizer(
            _ gr: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool { true }

        // MARK: - Capture-marker tap detection (Session 45 addendum 6)
        //
        // No hidden-attribute machinery here (see this file's header comment
        // and the tap-gesture-setup comment in makeUIView above) — scans the
        // raw on-screen text for `[label](capture://open?id=ID)` around the
        // tapped character index. Same regex shape as MarkdownTextStorage.swift's
        // applyMarkdownLinks(), just matched directly against plain text
        // instead of driving attribute hiding.
        @objc func handleTap(_ gr: UITapGestureRecognizer) {
            guard gr.state == .ended, let tv = textView else { return }
            let point = gr.location(in: tv)
            let adj = CGPoint(
                x: point.x - tv.textContainerInset.left,
                y: point.y - tv.textContainerInset.top
            )
            let charIdx = tv.layoutManager.characterIndex(
                for: adj, in: tv.textContainer,
                fractionOfDistanceBetweenInsertionPoints: nil
            )
            let ns = tv.text as NSString
            guard charIdx < ns.length,
                  let regex = try? NSRegularExpression(pattern: #"\[([^\]]+)\]\(capture://open\?id=([^)]+)\)"#) else { return }
            for m in regex.matches(in: tv.text, range: NSRange(location: 0, length: ns.length)) {
                guard m.numberOfRanges >= 3 else { continue }
                if NSLocationInRange(charIdx, m.range) {
                    let idRange = m.range(at: 2)
                    onCaptureTap(ns.substring(with: idRange))
                    return
                }
            }
        }

        // MARK: Toolbar construction — mirrors MarkdownEditorView.swift's
        // makeScrollToolbar(_:), simplified: no Done-button-plus-separator
        // cluster complexity needed for only 5 possible buttons plus the
        // gear, everything just scrolls together if it ever overflows.

        func makeToolbar(for tv: UITextView) -> UIInputView {
            textView = tv
            let container = UIInputView(frame: CGRect(x: 0, y: 0, width: 320, height: 44),
                                        inputViewStyle: .keyboard)
            container.allowsSelfSizing = false
            container.autoresizingMask = [.flexibleWidth]
            container.backgroundColor = .systemGroupedBackground

            let border = UIView()
            border.backgroundColor = .separator
            border.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(border)

            let doneBtn = UIButton(type: .system)
            doneBtn.setTitle("Done", for: .normal)
            doneBtn.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
            doneBtn.addTarget(self, action: #selector(dismissKeyboard), for: .touchUpInside)
            doneBtn.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(doneBtn)

            let gearBtn = UIButton(type: .system)
            let gearCfg = UIImage.SymbolConfiguration(pointSize: 16, weight: .regular)
            gearBtn.setImage(UIImage(systemName: "slider.horizontal.3", withConfiguration: gearCfg), for: .normal)
            gearBtn.tintColor = .secondaryLabel
            gearBtn.addTarget(self, action: #selector(showToolbarCustomize), for: .touchUpInside)
            gearBtn.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(gearBtn)

            let sep = UIView()
            sep.backgroundColor = .separator
            sep.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(sep)

            let scrollView = UIScrollView()
            scrollView.showsHorizontalScrollIndicator = false
            scrollView.alwaysBounceHorizontal = false
            scrollView.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(scrollView)

            let stack = UIStackView()
            stack.axis = .horizontal
            stack.spacing = 0
            stack.alignment = .center
            stack.translatesAutoresizingMaskIntoConstraints = false
            scrollView.addSubview(stack)

            for itemID in loadJotToolbarOrder() {
                stack.addArrangedSubview(makeButton(itemID))
            }

            NSLayoutConstraint.activate([
                border.topAnchor.constraint(equalTo: container.topAnchor),
                border.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                border.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                border.heightAnchor.constraint(equalToConstant: 0.5),

                doneBtn.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
                doneBtn.centerYAnchor.constraint(equalTo: container.centerYAnchor),

                gearBtn.trailingAnchor.constraint(equalTo: doneBtn.leadingAnchor, constant: -8),
                gearBtn.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                gearBtn.widthAnchor.constraint(equalToConstant: 32),
                gearBtn.heightAnchor.constraint(equalToConstant: 43),

                sep.trailingAnchor.constraint(equalTo: gearBtn.leadingAnchor, constant: -6),
                sep.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                sep.widthAnchor.constraint(equalToConstant: 0.5),
                sep.heightAnchor.constraint(equalToConstant: 22),

                scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                scrollView.trailingAnchor.constraint(equalTo: sep.leadingAnchor, constant: -4),
                scrollView.topAnchor.constraint(equalTo: border.bottomAnchor),
                scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

                stack.topAnchor.constraint(equalTo: scrollView.topAnchor),
                stack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
                stack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
                stack.heightAnchor.constraint(equalTo: scrollView.heightAnchor),
            ])

            formattingStack = stack
            toolbarContainer = container
            return container
        }

        private func makeButton(_ itemID: JotToolbarItemID) -> UIButton {
            let action: Selector
            switch itemID {
            case .bold:      action = #selector(insertBold)
            case .bullet:    action = #selector(insertBullet)
            case .checkbox:  action = #selector(insertCheckbox)
            case .indent:    action = #selector(indentLine)
            case .outdent:   action = #selector(outdentLine)
            case .pin:       action = #selector(dropPin)
            }
            let symCfg = UIImage.SymbolConfiguration(pointSize: 16, weight: .regular)
            let btn = UIButton(type: .system)
            btn.setImage(UIImage(systemName: itemID.systemImage, withConfiguration: symCfg), for: .normal)
            btn.tintColor = .label
            btn.addTarget(self, action: action, for: .touchUpInside)
            btn.translatesAutoresizingMaskIntoConstraints = false
            btn.widthAnchor.constraint(greaterThanOrEqualToConstant: 42).isActive = true
            btn.heightAnchor.constraint(equalToConstant: 43).isActive = true
            return btn
        }

        @objc func dismissKeyboard() {
            textView?.resignFirstResponder()
        }

        @objc func showToolbarCustomize() {
            guard let container = toolbarContainer,
                  let windowScene = container.window?.windowScene,
                  let root = windowScene.keyWindow?.rootViewController else { return }
            var top = root
            while let presented = top.presentedViewController { top = presented }

            let currentOrder = loadJotToolbarOrder()
            let sheet = UIHostingController(rootView: JotToolbarCustomizeSheet(current: currentOrder) { [weak self] newOrder in
                guard let self else { return }
                top.dismiss(animated: true)
                self.rebuildToolbar(order: newOrder)
            })
            sheet.modalPresentationStyle = .pageSheet
            if let det = sheet.sheetPresentationController {
                det.detents = [.medium()]
                det.prefersGrabberVisible = true
            }
            top.present(sheet, animated: true)
        }

        private func rebuildToolbar(order: [JotToolbarItemID]) {
            guard let stack = formattingStack else { return }
            stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for itemID in order {
                stack.addArrangedSubview(makeButton(itemID))
            }
        }

        // MARK: - Formatting actions
        //
        // Mirrors MarkdownEditorView.swift's insertBold/insertBullet/
        // indentLine/outdentLine/insertCheckbox exactly (same on-disk
        // characters — see this file's header comment) but simplified:
        // no checklist-send UIMenu, no scheduleSave debounce (Jot doesn't
        // autosave to a file the way the Notes editor does — text only
        // gets written on the checkmark button's commit(), unchanged).

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
            text.wrappedValue = tv.text
        }

        @objc func insertBullet() {
            guard let tv = textView else { return }
            let cursorRange = tv.selectedRange
            let ns = tv.text as NSString
            let lineRange = ns.lineRange(for: NSRange(location: cursorRange.location, length: 0))
            let line = ns.substring(with: lineRange)

            let bullet = "\u{2022} "
            if line.hasPrefix(bullet) {
                let stripped = String(line.dropFirst(2))
                tv.textStorage.replaceCharacters(in: lineRange, with: stripped)
                let newLoc = max(lineRange.location, cursorRange.location - 2)
                tv.selectedRange = NSRange(location: newLoc, length: 0)
            } else if line.hasPrefix("- ") {
                let content = String(line.dropFirst(2))
                tv.textStorage.replaceCharacters(in: lineRange, with: bullet + content)
                tv.selectedRange = NSRange(location: cursorRange.location, length: 0)
            } else {
                tv.textStorage.replaceCharacters(
                    in: NSRange(location: lineRange.location, length: 0), with: bullet)
                tv.selectedRange = NSRange(location: cursorRange.location + 2, length: 0)
            }
            text.wrappedValue = tv.text
        }

        @objc func insertCheckbox() {
            guard let tv = textView else { return }
            let cursorRange = tv.selectedRange
            let ns = tv.text as NSString
            let lineRange = ns.lineRange(for: NSRange(location: cursorRange.location, length: 0))
            let line = ns.substring(with: lineRange)

            if line.hasPrefix("☑ ") {
                tv.textStorage.replaceCharacters(in: NSRange(location: lineRange.location, length: 2), with: "☐ ")
                tv.selectedRange = NSRange(location: cursorRange.location, length: 0)
            } else if line.hasPrefix("☐ ") {
                tv.textStorage.replaceCharacters(in: NSRange(location: lineRange.location, length: 2), with: "")
                let newLoc = max(lineRange.location, cursorRange.location - 2)
                tv.selectedRange = NSRange(location: newLoc, length: 0)
            } else {
                tv.textStorage.replaceCharacters(
                    in: NSRange(location: lineRange.location, length: 0), with: "☐ ")
                tv.selectedRange = NSRange(location: cursorRange.location + 2, length: 0)
            }
            text.wrappedValue = tv.text
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
            text.wrappedValue = tv.text
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
            text.wrappedValue = tv.text
        }

        // MARK: - Quick Pin
        //
        // Added 2026-07-25. Ported from Trace's QuickPinLabelSheet.swift
        // `save(label:emoji:)` with the 6-button label grid and 4-second
        // countdown removed — David's own reason for never using the Trace
        // version ("tough to get to and then to see"). This fires the
        // instant the toolbar button is tapped: no confirmation sheet, no
        // deferred save, matching David's explicit call ("instant save for
        // this aspect of jot"). Saves a time-only capture — same silent
        // nearest-place-within-500m auto-link as the Trace version, zero
        // change to that logic (David: "its fine to do this with speed and
        // i will test if that is working for me as i use it"): no place
        // within 500m just means `placeID` is nil on the Notion page, and
        // multiple candidates always resolve to the single nearest one,
        // never a picker either way.
        //
        // Unlike the five formatting actions above, this doesn't touch
        // `text` synchronously — it's `async` (location fetch + a Notion
        // network call), and only inserts its cursor marker / calls back to
        // `onPinSucceeded` once the save has actually completed. A failed
        // save calls `onPinFailed(_:)` instead and leaves the note's text
        // completely untouched, same "never silently lose or half-do
        // something" principle CaptureView.swift's own commit() follows.
        @objc func dropPin() {
            guard let tv = textView else { return }

            Task { @MainActor in
                // Same up-to-~3s/150ms poll cadence as CaptureView.swift's
                // commit() waits on NoteStore.shared.hasAccess.
                // warmUpPinDependencies() already kicked off
                // LocationManager.shared.startUpdating() on appear, so this
                // is just covering the case where the very first fix hasn't
                // landed yet by the time the button is tapped.
                if LocationManager.shared.location == nil {
                    for _ in 0..<20 {
                        if LocationManager.shared.location != nil { break }
                        try? await Task.sleep(nanoseconds: 150_000_000)
                    }
                }
                guard let loc = LocationManager.shared.location else {
                    self.onPinFailed("Couldn't get your location — check Location Services, then try again.")
                    return
                }

                let formatter = DateFormatter()
                formatter.dateFormat = "h:mm a"
                let timeStr = formatter.string(from: Date())

                // Auto-link to the nearest Trace place within 500 m — exact
                // same logic as QuickPinLabelSheet.swift's save(): filter to
                // candidates within radius, then take the nearest.
                let nearbyPlace = NotionService.shared.places.filter { p in
                    CLLocation(latitude: p.latitude, longitude: p.longitude).distance(from: loc) <= 500
                }.min { a, b in
                    CLLocation(latitude: a.latitude, longitude: a.longitude).distance(from: loc)
                        < CLLocation(latitude: b.latitude, longitude: b.longitude).distance(from: loc)
                }

                let pageID: String
                do {
                    pageID = try await NotionService.shared.saveCapture(
                        notes: timeStr,
                        placeID: nearbyPlace?.id,
                        // Fixed 2026-07-25 (Session 45 addendum 8) — was always
                        // timeStr, so every capture's Notion page title was a
                        // clock time even when a place matched, regardless of
                        // the correct placeID relation set above. Now titles
                        // the page with the matched place's real name when
                        // there is one, falling back to the time otherwise —
                        // only affects captures saved from this point forward.
                        placeName: nearbyPlace?.name ?? timeStr,
                        lat: loc.coordinate.latitude,
                        lon: loc.coordinate.longitude,
                        photoURL: nil
                    )
                } catch {
                    self.onPinFailed("Couldn't save the pin — try again.")
                    return
                }

                // Added 2026-07-25 — matches QuickPinLabelSheet.swift's own
                // save(), which always refreshes the local list right after
                // a successful save. Has no effect on Trace's own in-memory
                // captures list if Trace happens to be running (separate
                // process, separate NotionService.shared instance — see
                // ContentView.swift's matching 2026-07-25 fix for that side),
                // but keeps this app's own state correct if it's ever the one
                // displaying captures, and costs nothing when it isn't.
                await NotionService.shared.fetchCaptures()

                // Insert a short marker wherever the cursor currently sits —
                // deliberately read fresh here, not captured before the
                // `await`s above, since David may keep typing while the
                // save is in flight.
                //
                // Place-aware marker, Session 45 addendum 6: shows the
                // matched place's name when dropPin() found one nearby
                // (nearbyPlace, computed above — same 500m proximity check
                // QuickPinLabelSheet.swift uses), "Dropped Pin" otherwise —
                // David wanted an explicit "nothing found" indicator rather
                // than a silently plain marker. Wrapped as a markdown link
                // `[label](capture://open?id=pageID)` so the ID rides along
                // resolvably — Jot has no hidden-attribute rendering (see
                // this file's header comment), so this shows on screen
                // exactly as typed, same as Jot already shows raw
                // **bold**/☐ — David's locked "first option" call. The
                // scheme://host?query=value shape (not a bare "capture:id"
                // opaque URI) matches MarkdownEditorView.swift's identical
                // marker format and handleTap() below's matching regex —
                // see that file's shouldInteractWith(url:) comment for why.
                let label = nearbyPlace != nil
                    ? "📍 \(nearbyPlace!.name) · \(timeStr)"
                    : "📍 Dropped Pin · \(timeStr)"
                let marker = "[\(label)](capture://open?id=\(pageID)) "
                if let range = tv.selectedTextRange {
                    tv.replace(range, withText: marker)
                }
                self.text.wrappedValue = tv.text
                self.onPinSucceeded()
            }
        }
    }
}
