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

// MARK: - Reorder sheet

/// Presented from the toolbar's gear button (see JotTextView.swift's
/// Coordinator). A plain drag-to-reorder List — no icons-in-a-row editor,
/// just the standard iOS reorder pattern (EditButton-style drag handles),
/// same interaction MarkdownEditorView.swift's own ToolbarCustomizeSheet
/// already uses.
struct JotToolbarCustomizeSheet: View {
    @State private var items: [JotToolbarItemID]
    var onDone: ([JotToolbarItemID]) -> Void
    @Environment(\.dismiss) private var dismiss

    init(current: [JotToolbarItemID], onDone: @escaping ([JotToolbarItemID]) -> Void) {
        _items = State(initialValue: current)
        self.onDone = onDone
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(items) { item in
                        Label(item.label, systemImage: item.systemImage)
                    }
                    .onMove { source, destination in
                        items.move(fromOffsets: source, toOffset: destination)
                    }
                } footer: {
                    Text("Drag to reorder toolbar buttons")
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Customize Toolbar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        saveJotToolbarOrder(items)
                        onDone(items)
                        dismiss()
                    }
                }
            }
        }
    }
}
