import SwiftUI

// MARK: - DayflowInboxView
//
// Browse: Inbox — the fourth destination off the top-bar calendar icon menu,
// alongside Upcoming/Calendar/Anytime (Dayflow-Design-Plan.md "Top bar &
// navigation"; build order step 5b). Requested 2026-07-20, after the original
// three-destination mockup review — Dayflow-Mockup.html never covered this
// screen, so there's no locked ground-truth interaction spec the way Upcoming/
// Calendar/Anytime have. Closest reference is DayflowAnytimeView.swift, but
// unlike Anytime (which groups by list/area), Inbox tasks are unfiled by
// definition — `things-jxa-server.py`'s `/inbox` endpoint always sends
// `project_title: ""` for every row (see that file's header comment) — so
// this view is a flat list rather than grouped sections. If that turns out to
// be wrong once David sees real data on-device, revisit; this is a judgment
// call, not a confirmed spec.
//
// Same interaction pattern as the other three Browse views: tapping a task's
// checkbox completes it directly via `ThingsService.complete(taskID:)`;
// tapping its title opens `DayflowTaskEditSheet` (title/date/list) — setting a
// date or list on an Inbox task is exactly how you'd file it out of the Inbox,
// so this is probably the most-used edit path of any Browse screen once it's
// on-device tested.

struct DayflowInboxView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var editingTask: ThingsTask? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if ThingsService.shared.isLoadingInbox && ThingsService.shared.inboxTasks.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        if ThingsService.shared.inboxTasks.isEmpty {
                            Text("Nothing here.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .padding(.top, 24)
                        } else {
                            ForEach(ThingsService.shared.inboxTasks) { task in
                                taskRow(task)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                }
            }
        }
        .task { await ThingsService.shared.fetchInbox() }
        .sheet(item: $editingTask) { task in
            DayflowTaskEditSheet(taskID: task.id, initialTitle: task.title,
                                  initialDate: task.date, initialList: task.list) {
                Task { await ThingsService.shared.fetchInbox() }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)

            Spacer()
            Text("Inbox")
                .font(.custom("Georgia", size: 20).weight(.bold))
            Spacer()

            Color.clear.frame(width: 32, height: 32)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }

    // MARK: Task row

    private func taskRow(_ task: ThingsTask) -> some View {
        HStack(spacing: 9) {
            Button {
                Task { await ThingsService.shared.complete(taskID: task.id) }
            } label: {
                Circle()
                    .strokeBorder(Color.gray.opacity(0.45), lineWidth: 2)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Complete \(task.title)")

            Text(task.title)
                .font(.system(size: 13.5))
                .lineLimit(2)
                .contentShape(Rectangle())
                .onTapGesture { editingTask = task }
        }
        .padding(.vertical, 5)
    }
}
