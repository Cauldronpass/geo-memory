// JotFormattingToolbar.swift — new file, Jot app target.
//
// The formatting-toolbar model + reorder sheet for Jot's keyboard accessory
// bar. Added 2026-07-24, David's ask (app expansion item 1): Bold, Bullet,
// Checkbox, Indent, Outdent, plus a gear icon to drag-reorder them.
//
// **Deliberately a fresh, Jot-only implementation, not a reuse of
// `MarkdownEditorView.swift`'s existing `ToolbarItemID`/`ToolbarCustomizeSheet`**
// (Trace/Dayflow's Notes editor already has almost this exact feature —
// found while scoping this). Two reasons this is a new file instead of
// adding that one to Jot's target:
//   1. `MarkdownEditorView.swift` is a large (~150KB), tightly-coupled
//      `UITextView` subclass with a custom `NSTextStorage` doing live
//      markdown rendering (hiding `**`, drawing checkbox glyphs as SF
//      Symbol overlays, syntax highlighting, wikilinks, block folding).
//      Jot deliberately doesn't want any of that — it's a plain,
//      minimal, one-screen capture field, and pulling in that whole file
//      just for the toolbar model risks pulling in its dependency graph
//      too, undermining exactly why Jot exists as its own lightweight app.
//   2. Jot's own toolbar order should persist independently of Trace/
//      Dayflow's Notes editor preference, not share it — a different
//      `UserDefaults` key (`jotToolbarOrder`, not `markdownToolbarOrder`).
//
// The on-disk formatting characters DO match Trace/Dayflow's Notes editor
// exactly, though (confirmed by reading `MarkdownTextStorage.swift`'s live
// `applyStyles()` line-styling switch before writing this, not just its
// header comment): checkboxes are `☐ `/`☑ ` (U+2610/U+2611), bullets are
// `• ` (U+2022), bold is `**...**`, indent is 2 literal spaces per level.
// Writing the same characters here means a note started in Jot renders
// identically — real checkbox, real bullet — the moment it's opened in
// Dayflow, even though Jot itself just shows the raw glyphs while typing
// (no live-hiding of `**`, matching Jot's whole "raw text, Drafts-style"
// design, not a gap).
//
// **`.pin` added 2026-07-25** (Quick Pin, see CaptureView.swift's own
// header comment for the full feature writeup). Unlike the other five
// items, tapping it doesn't insert/wrap text directly — it triggers
// `JotTextView.swift`'s `dropPin()`, which does an async location fetch +
// Notion save, then inserts a short marker at the cursor once that
// finishes. Included here in the same enum/order/reorder system as the
// other five deliberately, so it's just another draggable toolbar button
// from David's perspective, not a visually distinct special case.

import SwiftUI

// MARK: - Toolbar item model

enum JotToolbarItemID: String, CaseIterable, Identifiable {
    case bold, bullet, checkbox, indent, outdent, pin

    var id: String { rawValue }

    var label: String {
        switch self {
        case .bold:      return "Bold (**)"
        case .bullet:    return "Bullet (•)"
        case .checkbox:  return "Checkbox (☐)"
        case .indent:    return "Indent (→)"
        case .outdent:   return "Outdent (←)"
        case .pin:       return "Quick Pin"
        }
    }

    /// Same SF Symbol choices as MarkdownEditorView.swift's ToolbarItemID,
    /// for visual consistency with the Notes editor's toolbar even though
    /// the two aren't the same code. `.pin` originally used a bold filled
    /// pin ("mappin.circle.fill") but David flagged it as too visually
    /// heavy next to the other five thin outline icons — switched to
    /// "scope" (a plain crosshair/reticle glyph, David's "position
    /// indicator" ask) 2026-07-25. The note itself still gets the bold
    /// 📍 emoji marker on a successful pin — only the toolbar button
    /// changed.
    var systemImage: String {
        switch self {
        case .bold:      return "bold"
        case .bullet:    return "list.bullet"
        case .checkbox:  return "checkmark.square"
        case .indent:    return "increase.indent"
        case .outdent:   return "decrease.indent"
        case .pin:       return "scope"
        }
    }
}

private let kJotToolbarOrderKey = "jotToolbarOrder"
private let kJotFontSizeKey = "jotFontSize"

/// Jot's editor body size. Added 2026-08-24, David's ask: the field read as
/// "very small," and the cause was that `CaptureView` passed
/// `.systemFont(ofSize: 17)` — the plain iOS default — into `JotTextView`.
///
/// **A fixed, settable number rather than Dynamic Type**, David's call when
/// asked: `UIFont.preferredFont(forTextStyle: .body)` would honour Settings →
/// Display & Brightness → Text Size and grow on any future device, but it
/// also relayouts every other piece of Jot's chrome (the 12/13pt header, pill
/// and toolbar labels), which is a bigger change than the one being asked
/// for. This keeps the chrome exactly where it is and moves only the text
/// he types.
///
/// Default is 20, not 17. The clamp exists because the value is read back
/// from `UserDefaults` and a garbage/absent read must not produce an
/// unreadable or comically large field — same defensive shape as
/// `loadJotToolbarOrder()` above, which repairs a stale saved order rather
/// than trusting it.
let kJotFontSizeDefault: CGFloat = 20
let kJotFontSizeRange: ClosedRange<CGFloat> = 15...28

func loadJotFontSize() -> CGFloat {
    let saved = UserDefaults.standard.double(forKey: kJotFontSizeKey)
    // `double(forKey:)` returns 0 for an absent key, which is also the only
    // value that can't be a real size — so 0 means "never set," not "set to
    // zero," and falls through to the default.
    guard saved > 0 else { return kJotFontSizeDefault }
    return min(max(CGFloat(saved), kJotFontSizeRange.lowerBound), kJotFontSizeRange.upperBound)
}

func saveJotFontSize(_ size: CGFloat) {
    UserDefaults.standard.set(Double(size), forKey: kJotFontSizeKey)
}

/// Returns the saved toolbar order, or the default (declaration) order if
/// none saved yet, or if a saved order is missing/has stale entries (e.g.
/// after a future item is added or removed) — same defensive pattern as
/// MarkdownEditorView.swift's loadToolbarOrder().
func loadJotToolbarOrder() -> [JotToolbarItemID] {
    guard let saved = UserDefaults.standard.array(forKey: kJotToolbarOrderKey) as? [String] else {
        return JotToolbarItemID.allCases
    }
    let mapped = saved.compactMap { JotToolbarItemID(rawValue: $0) }
    let missing = JotToolbarItemID.allCases.filter { !mapped.contains($0) }
    return mapped + missing
}

func saveJotToolbarOrder(_ order: [JotToolbarItemID]) {
    UserDefaults.standard.set(order.map(\.rawValue), forKey: kJotToolbarOrderKey)
}

// MARK: - Settings sheet

/// Presented from the toolbar's slider button (see JotTextView.swift's
/// Coordinator). Two sections: the drag-to-reorder toolbar list this sheet
/// was originally built for, and a text-size slider added 2026-08-24.
///
/// **Why the size control lives here rather than as A- / A+ buttons in the
/// toolbar row**, David's call when asked: the row already carries six
/// formatting buttons plus this one and a Done button, and on an iPhone that
/// is a full bar. The sheet is a tap he already makes, and it has room for a
/// live preview line, which two nudge buttons do not.
///
/// `onDone` now hands back both values. It stayed a single callback rather
/// than splitting into two so the caller keeps one place to rebuild from —
/// the toolbar and the font are applied in the same pass.
struct JotSettingsSheet: View {
    @State private var items: [JotToolbarItemID]
    @State private var fontSize: CGFloat
    var onDone: ([JotToolbarItemID], CGFloat) -> Void
    @Environment(\.dismiss) private var dismiss

    init(currentOrder: [JotToolbarItemID],
         currentFontSize: CGFloat,
         onDone: @escaping ([JotToolbarItemID], CGFloat) -> Void) {
        _items = State(initialValue: currentOrder)
        _fontSize = State(initialValue: currentFontSize)
        self.onDone = onDone
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    // Preview sits above the slider so the thumb never covers
                    // it under a dragging finger.
                    Text("The quick brown fox jumps over the lazy dog.")
                        .font(.system(size: fontSize))
                        .foregroundStyle(.primary)
                        .padding(.vertical, 4)

                    HStack(spacing: 12) {
                        Text("A")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        Slider(
                            value: $fontSize,
                            in: kJotFontSizeRange,
                            step: 1
                        )
                        Text("A")
                            .font(.system(size: 20))
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Size")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(fontSize))")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        // An explicit way back to 20 — a slider with no
                        // marked default gives no way to find it again once
                        // it has been moved.
                        Button("Reset") {
                            fontSize = kJotFontSizeDefault
                        }
                        .buttonStyle(.borderless)
                        .disabled(fontSize == kJotFontSizeDefault)
                    }
                    .font(.system(size: 13))
                } header: {
                    Text("Text Size")
                } footer: {
                    Text("Applies to the text you type. The header and toolbar stay the same size.")
                }

                Section {
                    ForEach(items) { item in
                        Label(item.label, systemImage: item.systemImage)
                    }
                    .onMove { source, destination in
                        items.move(fromOffsets: source, toOffset: destination)
                    }
                } header: {
                    Text("Toolbar")
                } footer: {
                    Text("Drag to reorder toolbar buttons")
                }
                // Scoped to this Section, not the whole List as it was before
                // the Text Size section existed. An always-active editMode on
                // the List indents every row and can grey out controls in
                // rows that aren't movable, which would reach the slider and
                // the Reset button.
                .environment(\.editMode, .constant(.active))
            }
            .navigationTitle("Jot Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        saveJotToolbarOrder(items)
                        saveJotFontSize(fontSize)
                        onDone(items, fontSize)
                        dismiss()
                    }
                }
            }
        }
    }
}
