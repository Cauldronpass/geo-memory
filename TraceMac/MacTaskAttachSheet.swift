// MacTaskAttachSheet.swift
// Put an EXISTING task on an endeavor (Session 87). Mac-only target.
//
// David, on his first Project: *"i can add a new task but there is no way to
// add one that already exists on the rail."* He is right, and the hole is older
// than this session: an endeavor's link is a `[[<name>]]` line in a task's
// notes, and the only thing that has ever written one is the `+`, which writes
// it while creating a brand new task. A task made on Tuesday in the Inbox could
// never join a trip on either platform.
//
// **Multi-select, not one at a time.** The real case is three tasks that all
// belong to the same project, and a sheet that closes after each one makes you
// open it three times.
//
// **Selected rows stay on screen when the search no longer matches them.**
// `MacBookingSheet.offeredPeople` solved the same problem the same way: a
// ticked row that disappears is a decision the user cannot see or undo.

import SwiftUI

struct MacTaskAttachSheet: View {

    /// The endeavor being attached to, for the title.
    let endeavorName: String
    /// The link line this sheet's filter looks for, passed in rather than
    /// derived here. One definition of what a link is, in the view that owns
    /// the endeavor.
    let link: String
    /// Every open task the store knows about. Filtering happens here rather
    /// than at the call site so the "already attached" rule and the search
    /// live together.
    let tasks: [ThingsTask]
    /// Attaches the chosen tasks. The write is the caller's, because it is the
    /// caller that owns the store.
    let onAttach: ([ThingsTask]) async -> Bool
    /// Hands over to the composer. The sheet does not present a second sheet;
    /// it asks its host to change which one is showing (D36, one host).
    let onNewTask: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var chosen: Set<String> = []
    @State private var saving = false
    @State private var failure: String? = nil

    /// How many rows to offer before a search narrows them. Enough to pick a
    /// recent task without typing, few enough that the sheet is not a second
    /// task list.
    private static let browseCap = 8

    /// Everything not already on this endeavor.
    ///
    /// **The same `contains` the band's own query uses.** If these two ever
    /// disagreed, a task would be offered here and then not appear in the band
    /// after it was attached, which is the worst possible answer.
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
        VStack(alignment: .leading, spacing: 0) {
            Text("Add a task to \(endeavorName)")
                .font(MacType.heading)
                .lineLimit(1)
                .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)

            Form {
                Section {
                    TextField("Search your tasks…", text: $query)
                }

                if !chosenTasks.isEmpty {
                    Section("Adding") {
                        ForEach(chosenTasks) { task in
                            Button { chosen.remove(task.id) } label: {
                                Label(task.title, systemImage: "checkmark.circle.fill")
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
                            .font(MacType.meta)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(matches) { task in
                            Button { chosen.insert(task.id) } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "plus.circle")
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(task.title).lineLimit(1)
                                        if let list = task.list, !list.isEmpty {
                                            Text(list)
                                                .font(MacType.meta)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section {
                    // The other half of what this `+` means. It hands over
                    // rather than presenting: two sheets on one view is a coin
                    // flip (D36), so the host swaps which one is showing.
                    Button { onNewTask() } label: {
                        Label("New task instead…", systemImage: "square.and.pencil")
                    }
                    .buttonStyle(.plain)
                    .disabled(saving)
                }
            }
            .formStyle(.grouped)

            if let failure {
                Text(failure)
                    .font(MacType.meta)
                    .foregroundStyle(MacEditorialColor.accent)
                    .padding(.horizontal, 20).padding(.bottom, 6)
            }

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(chosen.count > 1 ? "Add \(chosen.count)" : "Add") { attach() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || chosen.isEmpty)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 440)
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
