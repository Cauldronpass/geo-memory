//
//  DayflowTaskPoolRow.swift
//  Dayflow
//
//  Session 89. ONE task row for every pool screen on the phone.
//
//  This row was Quick Find's `swipeableRow`, lifted here unchanged so the
//  Tasks room and the Quick Find card cannot draw two different rows for the
//  same task. Session 88 found seven copies of one list and D289 collapsed
//  them; making an eighth copy of a row that already carries four marks, two
//  swipe grammars and a completion target would be the same mistake with a
//  session's less excuse.
//
//  Two variants, because the Logbook needs a row and an open pool's row is
//  the wrong one for it:
//
//  - `DayflowTaskPoolRow`  an OPEN task. Tap the circle to finish it, tap the
//    row to open it, swipe right for the When card, swipe left into
//    multi-select (the root's selection bar floats above every host).
//  - `DayflowTaskLogRow`  a FINISHED task. Tap the circle to put it back.
//    No swipes: When on a task you already did is a question with no answer,
//    and a completed row that offers one is warning FIFTEEN drawn on purpose.
//
//  **Why the completed row has a live circle at all.** The store's own
//  comment says the Logbook exists for two things, and one of them is undoing
//  a tick you did not mean. A screen that knows the record exists owes a door
//  to it (warning FOURTEEN), and the circle IS that door.
//

import SwiftUI
import UIKit

struct DayflowTaskPoolRow: View {
    let task: ThingsTask
    var meta: String? = nil
    /// Handed in, never reached for  `EndeavorFile.nameIndex` walks the
    /// endeavor files, which is cheap once per screen and unaffordable once
    /// per row (D270's split, kept).
    var endeavorNames: Set<String> = []
    /// Owned by the HOST, so a row sliding in one screen is not also sliding
    /// in another that happens to show the same task.
    @Binding var dragOffsets: [String: CGFloat]
    var onOpen: (ThingsTask) -> Void
    var onWhen: (ThingsTask) -> Void

    @State private var selection = DayflowTodaySelection.shared

    var body: some View {
        let selected = selection.ids.contains(task.id)
        // NOT a Button (Simulator lesson, 2026-08-29): a Button's own
        // recognizer claims the touch before an attached DragGesture can
        // win, so the swipes read as dead. Today's rows are plain stacks
        // with onTapGesture for exactly this reason — same shape here.
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            if selection.isActive {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(selected ? Color.dayflowAccent : Color.dayflowFaint)
            } else {
                // Tappable (2026-08-29 night — David: "Anytime list doesnt
                // allow me to check anything off"): the circle was
                // decoration. Its own onTapGesture wins over the row's
                // (innermost first), so tapping it completes rather than
                // opening the edit sheet.
                Circle()
                    .strokeBorder(Color.dayflowInk, lineWidth: 1.5)
                    .frame(width: 16, height: 16)
                    .padding(6)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        Task { await ReminderTaskStore.shared.complete(taskID: task.id) }
                    }
                    .padding(-6)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.dayflowSerif(15))
                    .foregroundStyle(Color.dayflowInk)
                    .lineLimit(1)
                if let meta, !meta.isEmpty {
                    Text(meta)
                        .font(.system(size: 10.5))
                        .tracking(0.8)
                        .foregroundStyle(Color.dayflowFaint)
                }
            }
            Spacer()
            // The Mac row's bolt (D239): a shortcut fires in passing — the
            // Button takes the tap before the row's own gesture, so running
            // it does not also open the task.
            if let source = task.dayflowSource, source.icon == "bolt" {
                Button {
                    UIApplication.shared.open(source.url)
                } label: {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.dayflowAccent)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            // D229 marks (Session 81): these pool rows are the phone's list
            // rail, and a row that says nothing about its note or its link is
            // the failure D229 was written against. Same glyphs, same accent
            // as Today's rows.
            // Flagged (D413/D427): the reminder's priority, in accent, first in
            // the cluster, because it is the one mark he set on purpose.
            if task.flagged {
                Image(systemName: "flag.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.dayflowAccent)
            }
            if task.hasNoteProse {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.dayflowAccent)
            }
            if task.hasFollowableLink {
                Image(systemName: "link")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.dayflowAccent)
            }
            if task.repeats {
                Image(systemName: "repeat")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.dayflowFaint)
            }
            // **The endeavor mark** (D270). David, on the Mac: *"could you add
            // a small icon indicator when i look at the task that is in an
            // endeavor?"* - and, on the phone one session later, *"there is no
            // icon to tell me that the task I called How'd was from an
            // endeavor."*
            //
            // `flag`, because the Mac sidebar has called an endeavor a flag
            // since the room existed, so the mark needs no learning. The type
            // glyph was rejected on the Mac for a reason that holds here: an
            // airplane on a task row reads as "travel task" rather than "on a
            // trip", and five glyphs meaning one thing is five things to learn.
            //
            // **Faint, not accent.** The note and link marks are accent because
            // they say there is more to open; this is a fact about where the
            // task sits, and a passive mark should not scold.
            //
            // Placed beside `repeat`, the other faint mark, and LAST of the
            // four so it is the one that yields when a title is long. The Mac
            // caps its cluster at three; the phone now draws four in the rare
            // case where a task has prose, a link, an endeavor and a repeat,
            // and that is the row to watch if the cluster ever feels crowded.
            //
            // **No tap target here, deliberately.** Every mark in this cluster
            // is passive, and a 10pt glyph competing with the row tap on a
            // phone is a worse door than the one that already exists: the row
            // opens the task, and its Linked section names the endeavor and
            // opens it (D285, and the resolver in D282).
            // **`bookmark`, not `flag`, since D427.** On a task, `flag` now
            // means flagged (D413), drawn in accent just above; an endeavor
            // link keeps its faint mark under the Mac's new glyph.
            if EndeavorFile.linkedName(in: task.notes, among: endeavorNames) != nil {
                Image(systemName: "bookmark")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.dayflowFaint)
            }
        }
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        // Long press: the task menu (D428 Flag, D429 the rest; DayflowTaskMenu).
        // Long press to flag (D428). David: *"Isnt there an easier way to flag
        // it"* — the switch was three screens deep. A menu, not a third swipe:
        // right is When and left is select, and a long press is the gesture a
        // phone already offers on every row for "more to do with this".
        .contextMenu {
            DayflowTaskMenu(task: task) { onWhen(task) }
        }
        .onTapGesture {
            if selection.isActive {
                if selected { selection.ids.remove(task.id) }
                else { selection.ids.insert(task.id) }
                if selection.ids.isEmpty { selection.exit() }
            } else {
                onOpen(task)
            }
        }
        // `.offset` is visual only; the `.background` AFTER it keeps the
        // original frame, so the glyph stays put while the row slides
        // (DayflowTodaySection's comment, same trick).
        .offset(x: dragOffsets[task.id] ?? 0)
        .background(alignment: .leading) {
            let progress = min(max((dragOffsets[task.id] ?? 0) / 60, 0), 1)
            if progress > 0 {
                Image(systemName: "calendar")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.dayflowAccent)
                    .opacity(Double(progress))
                    .scaleEffect(0.7 + 0.3 * progress)
                    .padding(.leading, 2)
            }
        }
        .gesture(
            DragGesture(minimumDistance: 25)
                .onChanged { value in
                    guard !selection.isActive else { return }
                    let h = value.translation.width
                    guard abs(h) > abs(value.translation.height) else { return }
                    dragOffsets[task.id] = h > 0 ? min(h, 80) : 0
                }
                .onEnded { value in
                    let h = value.translation.width
                    withAnimation(.spring(duration: 0.3)) { dragOffsets[task.id] = 0 }
                    guard !selection.isActive else { return }
                    guard abs(h) > abs(value.translation.height) * 1.5,
                          abs(h) > 40 else { return }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    if h < 0 {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selection.isActive = true
                            selection.ids = [task.id]
                        }
                    } else {
                        // The settled-gesture hop, same as Today's rows.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                            onWhen(task)
                        }
                    }
                }
        )
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.dayflowHairline).frame(height: 1)
        }
        .animation(.easeInOut(duration: 0.15), value: selection.isActive)
    }
}

// MARK: - The finished row

/// A task in the Logbook. Muted, ticked, and reversible.
struct DayflowTaskLogRow: View {
    let task: ThingsTask
    var onOpen: (ThingsTask) -> Void
    var onChanged: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(Color.dayflowFaint)
                .padding(6)
                .contentShape(Rectangle())
                .onTapGesture {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    Task {
                        _ = await ReminderTaskStore.shared.uncomplete(taskID: task.id)
                        await ReminderTaskStore.shared.refreshAll()
                        onChanged()
                    }
                }
                .padding(-6)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.dayflowSerif(15))
                    .foregroundStyle(Color.dayflowMuted)
                    .lineLimit(1)
                if let list = task.list, !list.isEmpty {
                    Text(list.uppercased())
                        .font(.system(size: 10.5))
                        .tracking(0.8)
                        .foregroundStyle(Color.dayflowFaint)
                }
            }
            Spacer()
        }
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { onOpen(task) }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.dayflowHairline).frame(height: 1)
        }
    }
}

// MARK: - Drag to reorder

/// Undated rows with drag-to-reorder: long-press lifts a row (the horizontal
/// swipes and taps are untouched — different activations), dropping on a row
/// inserts before it, the tail strip drops at the end.
///
/// Lifted out of Quick Find with the row, and for the same reason: the order
/// is stored under a KEY, so two screens showing the same pool must agree
/// about both the key and the drop rules or a drag in one silently re-sorts
/// the other.
struct DayflowReorderableRows: View {
    let tasks: [ThingsTask]
    let key: String
    var meta: (ThingsTask) -> String? = { _ in nil }
    var endeavorNames: Set<String> = []
    @Binding var dragOffsets: [String: CGFloat]
    var onOpen: (ThingsTask) -> Void
    var onWhen: (ThingsTask) -> Void

    @State private var order = DayflowTaskOrder.shared

    var body: some View {
        let ids = tasks.map(\.id)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(tasks) { task in
                DayflowTaskPoolRow(task: task, meta: meta(task),
                                   endeavorNames: endeavorNames,
                                   dragOffsets: $dragOffsets,
                                   onOpen: onOpen, onWhen: onWhen)
                    .draggable(task.id)
                    .dropDestination(for: String.self) { items, _ in
                        guard let moved = items.first else { return false }
                        order.move(id: moved, before: task.id, key: key, current: ids)
                        return true
                    }
            }
            Color.clear
                .frame(height: 28)
                .contentShape(Rectangle())
                .dropDestination(for: String.self) { items, _ in
                    guard let moved = items.first else { return false }
                    order.move(id: moved, before: nil, key: key, current: ids)
                    return true
                }
        }
    }
}
