// SatchelDocTasksPanel.swift
// Satchel
//
// The tasks a document has — the iOS half of D230, built Session 81 (D234).
// David's call: Satchel and Dayflow both standalone but connected; the Mac
// experience comes to the phone rather than a hand-off that would have
// dropped the band.
//
// Same shape as the Mac's DocTasksPanel, same rules, Satchel's dress:
//
//   * The link lives in ONE place — a `satchel:doc:<relativePath>` line in
//     the task's notes (D227). This panel is a filter over that, never a
//     second record. Nothing is written to the document or its sidecar.
//   * No date filter on the open list: a task made here is born undated in
//     the Inbox and graduates to Personal the moment it is dated (D225).
//     Filtering on undated would make it vanish from the document at exactly
//     the moment he acted on it — the D210 failure.
//   * Completion is DERIVED (one bounded query per document opened, since the
//     document's own created date), never written — a task can be ticked in
//     Apple's Reminders, on the Watch, or by Siri, where no app of ours sees
//     it happen.
//   * Open tasks always; finished behind a toggle. The finished query is
//     re-keyed on the store's `revision` so a completion that happens while
//     the panel is on screen moves the row instead of losing it.
//
// What deliberately did NOT port: the Mac's task card. Satchel shows,
// completes, unticks and creates; EDITING a task (date, list, note) is the
// task apps' job, and the D177 promote lesson applies — a second editor is a
// second writer's worth of drift for a screen whose subject is the document.

import SwiftUI
import UIKit

struct SatchelDocTasksPanel: View {

    let document: TraceMacDocument

    @State private var finished: [ThingsTask] = []
    @State private var showFinished = false
    @State private var composing = false
    @State private var composeTitle = ""
    @State private var addFailed: String? = nil
    @State private var loading = false
    @FocusState private var composeFocused: Bool
    @Environment(\.openURL) private var openURL

    private var store: ReminderTaskStore { ReminderTaskStore.shared }

    private var open: [ThingsTask] {
        store.allTasks.filter { $0.linkedDocumentPaths.contains(document.relativePath) }
    }

    /// Document plus revision — the Mac panel's loadKey, same reasoning.
    private var loadKey: String { "\(document.relativePath)#\(store.revision)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            labelRow
            VStack(alignment: .leading, spacing: 0) {
                if open.isEmpty && finished.isEmpty && !composing {
                    emptyLine
                }
                ForEach(open) { task in
                    row(task)
                }
                finishedSection
                composeRow
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .satchelCard()
            if let addFailed {
                Text(addFailed)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 4)
            }
        }
        .padding(.horizontal, 15)
        .padding(.bottom, 16)
        // Satchel fetches nothing at launch — tasks load when a document
        // screen first wants them, which is also when the Reminders prompt
        // appears if it never has.
        .task { await store.refreshAll() }
        .task(id: loadKey) { await loadFinished() }
    }

    // MARK: - Label row (matches the detail view's field() label style)

    private var labelRow: some View {
        HStack(spacing: 8) {
            Text("TASKS")
                .font(.system(size: 11.5, weight: .bold))
                .kerning(0.5)
                .foregroundStyle(Color.satchelSecondary)
            if let done = doneSummary {
                // The line that answers "did I deal with this?" — blue, the
                // loudest ink this skin has (the Mac uses its accent here).
                Text(done)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color.satchelBlue)
            }
            Spacer(minLength: 0)
            if loading { ProgressView().controlSize(.mini) }
            Button {
                composing = true
                composeFocused = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.satchelSecondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add a task for this document")
        }
        .padding(.horizontal, 6)
    }

    /// "Done 12 Sep" for one finished task, a count for several — the DATE is
    /// the whole point for one ("did I pay this, and when" is one question).
    private var doneSummary: String? {
        guard !finished.isEmpty else { return nil }
        if finished.count == 1, let key = finished[0].completedDateString,
           let day = Self.day(key) {
            let f = DateFormatter()
            f.dateFormat = Calendar.current.isDate(day, equalTo: Date(), toGranularity: .year)
                ? "d MMM" : "d MMM yyyy"
            return "Done \(f.string(from: day))"
        }
        return "\(finished.count) finished"
    }

    private var emptyLine: some View {
        Text(store.accessGranted == false
             ? "Reminders access is off. Settings › Privacy › Reminders."
             : "No tasks yet.")
            .font(.system(size: 12.5))
            .foregroundStyle(Color.satchelTertiary)
            .padding(.vertical, 11)
    }

    // MARK: - Rows

    private func row(_ task: ThingsTask) -> some View {
        HStack(spacing: 10) {
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                Task { await store.complete(taskID: task.id) }
            } label: {
                Circle()
                    .strokeBorder(Color.satchelSecondary, lineWidth: 1.4)
                    .frame(width: 17, height: 17)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Complete")
            // The rest of the row jumps to the task in Dayflow (Session 81,
            // David: "on the document i have no way to click to go to the
            // task itself in Dayflow"). Same route the tasks widget uses —
            // dayflow://task?id= — and Dayflow HOLDS the id until its store
            // can name the task, so a cold launch still lands.
            Button {
                openTask(task)
            } label: {
                HStack(spacing: 10) {
                    Text(task.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.satchelInk)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    // Date else list — the slot carries whatever the context
                    // does not already imply (the Mac's .dateElseList, D230).
                    Text(trailing(task))
                        .font(.system(size: 10.5, weight: .medium))
                        .kerning(0.5)
                        .foregroundStyle(task.date == nil ? Color.satchelTertiary : Color.satchelBlue)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 9)
    }

    /// Finished rows deliberately do NOT get this: Dayflow's task route
    /// resolves against the incomplete store and drops an id it cannot name,
    /// so a finished row's tap would arrive nowhere. The untick is the way
    /// back — the row returns to open, and open rows open.
    private func openTask(_ task: ThingsTask) {
        guard var comps = URLComponents(string: "dayflow://task") else { return }
        comps.queryItems = [URLQueryItem(name: "id", value: task.id)]
        if let url = comps.url { openURL(url) }
    }

    private func trailing(_ task: ThingsTask) -> String {
        if let due = task.date {
            let cal = Calendar.current
            if cal.isDateInToday(due) { return "TODAY" }
            if cal.isDateInTomorrow(due) { return "TOMORROW" }
            let f = DateFormatter()
            f.dateFormat = cal.isDate(due, equalTo: Date(), toGranularity: .year)
                ? "EEE MMM d" : "MMM d yyyy"
            return f.string(from: due).uppercased()
        }
        return (task.list ?? "").uppercased()
    }

    // MARK: - Finished

    @ViewBuilder
    private var finishedSection: some View {
        if !finished.isEmpty {
            Button { showFinished.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: showFinished ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                    Text(showFinished ? "Hide finished" : "Show finished")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .foregroundStyle(Color.satchelTertiary)
                .frame(minHeight: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showFinished {
                ForEach(finished) { task in
                    finishedRow(task)
                }
            }
        }
    }

    /// The same control, both directions (Session 80): the filled circle
    /// unticks. `uncomplete` writes the reminder directly, so a refresh
    /// follows to move the row back to open.
    private func finishedRow(_ task: ThingsTask) -> some View {
        HStack(spacing: 10) {
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                Task {
                    _ = await store.uncomplete(taskID: task.id)
                    await store.refreshAll()
                }
            } label: {
                ZStack {
                    Circle().fill(Color.satchelTertiary).frame(width: 17, height: 17)
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.white)
                }
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Mark not done")
            Text(task.title)
                .font(.system(size: 13))
                .strikethrough()
                .foregroundStyle(Color.satchelTertiary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }

    // MARK: - Compose

    /// Inline, not a sheet. The Mac's MacTaskComposer is a full composer with
    /// list and date menus; here the task is BORN Inbox and undated (D230 —
    /// the document is its context, the when-decision comes at triage), so
    /// the only input that exists is the title.
    @ViewBuilder
    private var composeRow: some View {
        if composing {
            HStack(spacing: 10) {
                Circle()
                    .strokeBorder(Color.satchelTertiary, lineWidth: 1.4)
                    .frame(width: 17, height: 17)
                TextField("New task", text: $composeTitle)
                    .font(.system(size: 13))
                    .focused($composeFocused)
                    .submitLabel(.done)
                    .onSubmit { addTask() }
                Button { addTask() } label: {
                    Text("Add")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(composeTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                         ? Color.satchelTertiary : Color.satchelBlue)
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 9)
        }
    }

    /// An empty submit closes the row; a real one adds and stays open for the
    /// next, since receipts come in stacks.
    private func addTask() {
        let title = composeTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            composing = false
            return
        }
        addFailed = nil
        Task {
            let ok = await store.addTask(
                title: title,
                list: ReminderTaskStore.inboxListName,
                notes: ThingsTask.documentMarkerPrefix + document.relativePath)
            if ok {
                composeTitle = ""
                composeFocused = true
            } else {
                addFailed = store.lastError ?? "Could not add the task."
            }
        }
    }

    // MARK: - Data

    private func loadFinished() async {
        loading = true
        finished = await store.completedLinkedTo(documentPath: document.relativePath,
                                                 since: document.created)
        loading = false
    }

    private static func day(_ key: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: key)
    }
}
