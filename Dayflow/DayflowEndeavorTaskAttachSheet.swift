// DayflowEndeavorTaskAttachSheet.swift
// Dayflow
//
// Put an EXISTING task on an endeavor (Session 88). `MacTaskAttachSheet`'s
// design, which D269 built after David said, on the Mac: *"there is no way to
// add one that already exists on the rail."* He said the same thing about the
// phone one session later, and the hole is the same one: an endeavor's link is
// a `[[<name>]]` line in a task's notes, and until now the only thing that ever
// wrote one was the `+`, while creating a brand new task. A task made on
// Tuesday in the Inbox could never join a trip.
//
// **Multi-select, not one at a time.** The real case is three tasks that all
// belong to the same project, and a sheet that closes after each makes you open
// it three times.
//
// **Chosen rows stay on screen when the search stops matching them.**
// `DayflowBookingSheet.offeredPeople` solves the same problem the same way: a
// ticked row that vanishes is a decision the user cannot see or undo.
//
// **What a link IS lives on `EndeavorFile`**, not here and not at the call
// site. If this sheet's "already attached" filter and the band's own query ever
// disagreed, a task would be offered here and then fail to appear in the band
// after being attached, which is the worst answer available.

import SwiftUI

struct DayflowEndeavorTaskAttachSheet: View {

    let endeavorName: String
    /// The link line this sheet filters on. Passed in rather than derived, so
    /// there is one definition of it per screen rather than per view.
    let link: String
    let tasks: [ThingsTask]
    let onAttach: ([ThingsTask]) async -> Bool
    /// Hands over to the composer, carrying whatever has been typed into the
    /// search field. **It does not present a second sheet** - it asks the host
    /// to change which one is showing, because two sheets racing on one view is
    /// a coin flip and this file's host has already been bitten by it.
    let onNewTask: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var chosen: Set<String> = []
    @State private var saving = false
    @State private var failure: String? = nil

    /// How many rows to offer before a search narrows them. Enough to pick a
    /// recent task without typing, few enough that this is not a second task
    /// list.
    private static let browseCap = 12

    private var candidates: [ThingsTask] {
        tasks.filter { !($0.notes ?? "").contains(link) }
    }

    private var matches: [ThingsTask] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let pool = candidates.filter { !chosen.contains($0.id) }
        guard !q.isEmpty else { return Array(pool.prefix(Self.browseCap)) }
        return Array(pool.filter { $0.title.localizedCaseInsensitiveContains(q) }
                         .prefix(Self.browseCap))
    }

    private var chosenTasks: [ThingsTask] {
        candidates.filter { chosen.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Search your tasks\u{2026}", text: $query)
                }

                if !chosenTasks.isEmpty {
                    Section("Adding") {
                        ForEach(chosenTasks) { task in
                            Button { chosen.remove(task.id) } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color.dayflowAccent)
                                    Text(task.title)
                                        .foregroundStyle(Color.dayflowInk)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section(chosenTasks.isEmpty ? "Your tasks" : "More") {
                    if matches.isEmpty {
                        Text(candidates.isEmpty
                             ? "Every open task is already on this endeavor."
                             : "Nothing matches.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(matches) { task in
                            Button { chosen.insert(task.id) } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "plus.circle")
                                        .foregroundStyle(Color.dayflowFaint)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(task.title)
                                            .foregroundStyle(Color.dayflowInk)
                                            .lineLimit(1)
                                        if let list = task.list, !list.isEmpty {
                                            Text(list)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section {
                    // **Carries the search text.** Whatever narrowed this
                    // list is almost always the title of the task that turned
                    // out not to exist, and retyping it is the tax on having
                    // looked first.
                    Button { onNewTask(query.trimmingCharacters(in: .whitespacesAndNewlines)) } label: {
                        Label("New task instead\u{2026}", systemImage: "square.and.pencil")
                    }
                    .buttonStyle(.plain)
                    .disabled(saving)
                }

                if let failure {
                    Section {
                        Text(failure)
                            .font(.footnote)
                            .foregroundStyle(Color.dayflowAccent)
                    }
                }
            }
            .navigationTitle("Add a task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(chosen.count > 1 ? "Add \(chosen.count)" : "Add") { attach() }
                        .disabled(saving || chosen.isEmpty)
                }
            }
        }
    }

    private func attach() {
        let picked = chosenTasks
        guard !picked.isEmpty else { return }
        saving = true
        failure = nil
        Task {
            let ok = await onAttach(picked)
            if ok {
                dismiss()
            } else {
                // Stays open with the picks intact. A sheet that closes on a
                // failed write throws away the work and says nothing.
                failure = "Could not write to Reminders."
                saving = false
            }
        }
    }
}
