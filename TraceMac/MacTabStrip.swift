// MacTabStrip.swift
// The section-header tab control. Mac-only.
//
// Replaces `Picker(.segmented)` in all five headers that have tabs.
//
// ── Why, and it is not taste ──────────────────────────────────────────────
//
// Session 66. David: *"the buttons Upcoming and Past have a very small
// clickable area."* Then, after a `fixedSize` fix and a measurement build:
// *"i have to click on the far left edge only of upcoming."*
//
// **Those two reports together are the diagnosis.** The clickable band moves as
// you go right, and the first tab is fine — the error is zero at the left edge
// and grows with x. That is a scale mismatch between what the control draws and
// what it hit-tests, inside the control.
//
// A measurement build settled that it was not our layout: a red tint on the
// picker's frame lined up exactly with the drawn segments. The frame was right;
// the stock control's internal geometry was not.
//
// Two attempts had already gone into `Picker` at that point. Rather than a
// third guess at `NSSegmentedControl`'s internals, the hit area becomes
// something we own: one `Button` per tab, each with an explicit
// `contentShape(Rectangle())`. There is nothing left to disagree about.
//
// Same move that finally worked on the editor after eight failed fixes: narrow
// what you touch instead of arguing with the framework.
//
// ── Appearance ────────────────────────────────────────────────────────────
//
// Deliberately close to what it replaces, because the header's job is to be the
// one fixed origin in every section (see this file's neighbour,
// `TraceMacSectionHeader`) and five sections changing shape overnight is not an
// improvement anybody asked for. Rounded 6, a soft track, the selected tab
// filled with the control background and a hairline, `MacType.row` throughout.
//
// Sized by its content with symmetric padding, so it behaves the same as the
// picker did in the header's `fixedSize(horizontal:)` slot.

import SwiftUI

struct MacTabStrip<Value: Hashable>: View {

    let options: [Value]
    @Binding var selection: Value
    /// How each option reads. A closure rather than a `RawRepresentable`
    /// constraint: `ArchiveTab` is keyed on `\.self` while the others are
    /// `Identifiable`, and a label closure does not care which.
    let label: (Value) -> String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let isOn = option == selection
                Button {
                    // Assign unconditionally rather than guarding on change:
                    // re-selecting the current tab is a no-op to the eye and
                    // the extra write costs nothing.
                    selection = option
                } label: {
                    Text(label(option))
                        .font(isOn ? MacType.rowEmphasis : MacType.row)
                        .foregroundStyle(isOn ? Color.primary : Color.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .frame(maxHeight: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(isOn ? Color(nsColor: .controlBackgroundColor) : .clear)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 5)
                                        .strokeBorder(isOn ? Color.primary.opacity(0.12) : .clear,
                                                      lineWidth: 0.5)
                                )
                        )
                        // THE POINT OF THE WHOLE FILE. Every pixel of the tab
                        // is the button, including the padding and the gaps
                        // inside its own background.
                        .contentShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .frame(height: 24)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.secondary.opacity(0.12))
        )
    }
}
