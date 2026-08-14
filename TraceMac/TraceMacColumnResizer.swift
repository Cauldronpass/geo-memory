// TraceMacColumnResizer.swift
// The drag strip that makes a list column wider or narrower. Mac-only.
//
// David: *"I like that the column within the Directory can be dragged left or
// right. The Satchel colmn should also have that same adjustability. Same for
// each of the tabs like Endeavors, or Inbox."*
//
// **It already existed twice.** `TraceMacPeopleView` and `TraceMacPlacesView`
// each carry their own copy of the same fifteen lines — a near-invisible
// `Rectangle`, a `DragGesture` in global coordinates, and an `onHover` that
// pushes the resize cursor. Every other section hard-codes a width: Satchel 240,
// Endeavors 200, Inbox 200.
//
// So this is not a new capability, it is the third copy becoming the only copy.
// Two copies of a behaviour is how they drift; this project has spent three
// sessions on exactly that.
//
// Two things the inline versions did not do, added here because a shared
// component is the only place worth doing them once:
//
//   * **The width persists.** `@State private var sidebarWidth: CGFloat = 200`
//     resets on every launch, so a column widened on Tuesday is narrow again on
//     Wednesday. Callers hand in `@AppStorage`.
//   * **A maximum as well as a minimum.** The originals clamp at 160 and let the
//     column grow until the detail pane is a sliver, which is a state with no
//     way back other than dragging it out again.

import SwiftUI
import AppKit

struct MacColumnResizer: View {

    @Binding var width: Double
    var minWidth: Double = 160
    var maxWidth: Double = 560

    /// Width when the current drag began.
    ///
    /// `DragGesture.translation` is measured from the start of the drag, not
    /// from the previous frame, so adding it to the live width on every update
    /// compounds and the column runs away from the pointer. The inline copies
    /// avoided this by only committing `onEnded` and showing the movement
    /// through a `@GestureState` offset applied to the sibling — which works,
    /// and needs the caller to hold half the mechanism. Holding the start value
    /// keeps the whole thing in here.
    @State private var startWidth: Double?

    var body: some View {
        Rectangle()
            // Not `.clear`. A fully transparent shape receives no hit tests, so
            // the strip would be invisible in both senses. This is the note the
            // original carried and it is the kind that is worth moving with the
            // code.
            .fill(Color.primary.opacity(0.001))
            .frame(width: 6)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let base = startWidth ?? width
                        if startWidth == nil { startWidth = base }
                        width = min(maxWidth, max(minWidth, base + value.translation.width))
                    }
                    .onEnded { _ in startWidth = nil }
            )
            .onHover { inside in
                inside ? NSCursor.resizeLeftRight.push() : NSCursor.pop()
            }
    }
}
