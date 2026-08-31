// DocTasksPanel.swift
// The tasks a document has. Mac-only.
//
// Session 80 (2026-08-31), D230 — the second half of D227. David: "ideally when
// i created the document i could have hit a button in the document to add a
// task."
//
// ── Nothing is written to the document ───────────────────────────────────
//
// The link lives in ONE place: a `satchel:doc:<relativePath>` line in the
// task's notes (D227). This panel is a filter over that, not a second record.
//
// David asked whether completion could instead be "written when the related
// task for that document is completed", which would make the answer free to
// read. It would also be wrong: a task can be ticked in Apple's Reminders, on
// the Watch, or by Siri, where neither app sees it happen — the reason
// `ReminderTaskStore` observes `EKEventStoreChanged` at all. A mark written on
// completion would simply be missing for those, and a document showing no mark
// reads as "no task was ever made", which is the exact wrong answer in the exact
// case he would be relying on it.
//
// Derived, therefore, and never stale.
//
// ── Open always, finished behind a toggle ────────────────────────────────
//
// Open tasks are free: `allTasks` is already in memory. Finished ones need
// `predicateForCompletedReminders`, which is a real query, so it runs once when
// the document opens and its RESULT drives both the summary line and the
// disclosure. One query, two uses.

import SwiftUI
import AppKit

struct DocTasksPanel: View {

    let doc: TraceMacDocument
    /// Fired after a task is added or changed, so the host can refresh anything
    /// of its own that counts tasks.
    var onChanged: () -> Void = {}

    @State private var finished: [ThingsTask] = []
    @State private var showFinished = false
    @State private var composing = false
    @State private var openTaskID: String? = nil
    @State private var loading = false

    private var store: ReminderTaskStore { ReminderTaskStore.shared }

    /// **No date filter, deliberately.** A task made here is born undated in the
    /// Inbox; the moment he triages it, it gains a date and (D225) graduates to
    /// Personal. Filtering on undated would make it vanish from the document at
    /// exactly the moment he acted on it — the D210 failure, where a record
    /// disappears from the place you were looking.
    private var open: [ThingsTask] {
        store.allTasks.filter { $0.linkedDocumentPaths.contains(doc.relativePath) }
    }

    /// **Keyed on the store's revision as well as the document.**
    ///
    /// `.task(id: doc.relativePath)` alone ran once per document opened, which
    /// was wrong the moment anything completed while the panel was on screen.
    /// David found it in one pass: two tasks completed, only the first shown.
    /// The second was ticked in Apple's Reminders, which fires
    /// `EKEventStoreChanged` → `refreshAll` → the open list updates and the task
    /// vanishes from the band, while `finished` still holds the answer from
    /// when the document opened.
    ///
    /// The re-query costs one completed fetch per applied store fetch while a
    /// document is open. That is exactly the number `[DocTasks]` is logging, so
    /// it is measured rather than assumed.
    private var loadKey: String { "\(doc.relativePath)#\(store.revision)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading
            if open.isEmpty && finished.isEmpty {
                Text("No tasks yet.")
                    .font(MacEditorialType.meta)
                    .foregroundStyle(MacEditorialColor.faint)
                    .padding(.top, 6)
            }
            ForEach(open) { task in
                MacEditorialRule.hair
                MacTaskRow(task: task,
                           isOpen: openTaskID == task.id,
                           onToggle: { openTaskID = openTaskID == task.id ? nil : task.id },
                           onChanged: { refresh() },
                           trailing: .dateElseList)
            }
            finishedSection
        }
        .padding(.vertical, 10)
        .task(id: loadKey) { await loadFinished() }
        .sheet(isPresented: $composing) {
            // Inbox and undated (D230): a task made from a document has made no
            // when-decision, and the document IS its context, the way an
            // endeavor's agenda anchor is.
            MacTaskComposer(defaultDate: nil,
                            onAdded: { refresh() },
                            defaultList: ReminderTaskStore.inboxListName,
                            extraNoteLines: [ThingsTask.documentMarkerPrefix + doc.relativePath])
        }
    }

    // MARK: - Heading

    private var heading: some View {
        HStack(spacing: 8) {
            Text("Tasks").editorialKicker()
            if let done = doneSummary {
                // Accent, matching the row marks: this is the line that answers
                // "did I deal with this?", which is most of why he opens an old
                // document at all.
                Text(done)
                    .font(MacEditorialType.meta)
                    .foregroundStyle(MacEditorialColor.accent)
            }
            Spacer(minLength: 0)
            if loading { ProgressView().controlSize(.small) }
            Button { composing = true } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(MacEditorialColor.muted)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Add a task for this document")
        }
    }

    /// "Done 12 Sep" for one, a count for several. The DATE is the whole point
    /// for a single finished task — "did I pay this, and when" is one question.
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

    // MARK: - Finished

    @ViewBuilder
    private var finishedSection: some View {
        if !finished.isEmpty {
            MacEditorialRule.hair
            Button { showFinished.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: showFinished ? "chevron.down" : "chevron.right")
                        .font(.system(size: 7, weight: .bold))
                    Text(showFinished ? "Hide finished" : "Show finished")
                        .editorialQuietLabel()
                }
                .foregroundStyle(MacEditorialColor.faint)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showFinished {
                ForEach(finished) { task in
                    MacTaskRow(task: task,
                               isOpen: false,
                               onToggle: { },
                               onChanged: { refresh() },
                               completed: true)
                    MacEditorialRule.hair
                }
            }
        }
    }

    // MARK: - Data

    private func loadFinished() async {
        loading = true
        finished = await store.completedLinkedTo(documentPath: doc.relativePath,
                                                 since: doc.created)
        loading = false
    }

    /// `refreshAll` bumps `revision`, which re-keys `loadKey` and re-runs
    /// `loadFinished` on its own — so this does not call it a second time.
    private func refresh() {
        onChanged()
        Task { await store.refreshAll() }
    }

    private static func day(_ key: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: key)
    }
}
