// DayflowTaskMenu.swift
// Dayflow. D429 — what a long press on a task offers.
//
// D428 put Flag behind a long press. David then: *"are there any other things
// you can think of that we might add to the long press for tasks?"* and
// *"build"* on this list, top to bottom:
//
//   Flag / Unflag
//   Do Today · Do Tomorrow · Later…        (Later opens the When sheet)
//   Move to list ›                          (Someday, then every list)
//   Open link                               (only when the task has one)
//   Delete                                  (red; the undo pill catches it)
//
// **One menu, three rows.** Today, Upcoming and the list pools each draw their
// own task row; the menu is written once here so the three cannot offer
// different things for the same task. Each row passes only what it alone
// knows: how to open its When sheet.
//
// **Every action goes through the path the app already uses for it**: the When
// sheet's `update` for dates, the selection bar's `update` / `moveToSomeday`
// for lists, `DayflowUndoStack.record` then `remove` for delete. Nothing here
// is a second way of doing something.
//
// Not on the menu, deliberately: Complete (the circle is already one tap) and
// Copy (rarely wanted).

import SwiftUI
import UIKit

struct DayflowTaskMenu: View {
    let task: ThingsTask
    /// Open this row's When sheet for the task.
    var onLater: () -> Void

    var body: some View {
        Button {
            let id: String = task.id
            let value: Bool = !task.flagged
            Task { await ReminderTaskStore.shared.setFlagged(value, taskID: id) }
        } label: {
            Label(task.flagged ? "Unflag" : "Flag",
                  systemImage: task.flagged ? "flag.slash" : "flag")
        }

        Divider()

        Button {
            setDay(Calendar.current.startOfDay(for: Date()))
        } label: {
            Label("Do Today", systemImage: "sun.max")
        }
        Button {
            let cal = Calendar.current
            let tomorrow: Date = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date())) ?? Date()
            setDay(tomorrow)
        } label: {
            Label("Do Tomorrow", systemImage: "sunrise")
        }
        Button(action: onLater) {
            Label("Later\u{2026}", systemImage: "calendar")
        }

        Divider()

        Menu {
            Button {
                let id: String = task.id
                Task { _ = await ReminderTaskStore.shared.moveToSomeday(taskID: id) }
            } label: {
                Label(ReminderTaskStore.somedayListName, systemImage: "archivebox")
            }
            Divider()
            ForEach(otherLists, id: \.self) { name in
                Button(name) { move(to: name) }
            }
        } label: {
            Label("Move to list", systemImage: "arrow.right")
        }

        if let link = firstLink {
            Button {
                UIApplication.shared.open(link)
            } label: {
                Label("Open link", systemImage: "link")
            }
        }

        Divider()

        Button(role: .destructive) {
            let target: ThingsTask = task
            DayflowUndoStack.shared.record([target])
            Task { _ = await ReminderTaskStore.shared.remove(taskID: target.id) }
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private var otherLists: [String] {
        ReminderTaskStore.shared.listNames.filter {
            $0 != ReminderTaskStore.somedayListName && $0 != task.list
        }
    }

    /// A web page first, then a Satchel document: the order the task sheet's
    /// Linked section lists them.
    private var firstLink: URL? {
        if let web = task.webLinks.first { return web }
        if let path = task.linkedDocumentPaths.first {
            return TraceSatchelHandoff.documentURL(path: path)
        }
        return nil
    }

    /// The When sheet's own write: a day, the list untouched, the note kept.
    private func setDay(_ day: Date) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let target: ThingsTask = task
        Task {
            _ = await ReminderTaskStore.shared.update(
                taskID: target.id, title: target.title,
                date: day, clearDate: false,
                list: nil, notes: target.notes)
        }
    }

    /// The selection bar's own write, for one task.
    private func move(to list: String) {
        let target: ThingsTask = task
        Task {
            _ = await ReminderTaskStore.shared.update(
                taskID: target.id, title: target.title, date: nil,
                clearDate: false, list: list, notes: target.notes)
        }
    }
}
