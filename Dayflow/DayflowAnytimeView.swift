import SwiftUI

// MARK: - DayflowAnytimeView
//
// Browse: Anytime — one of the three destinations off the top-bar calendar
// icon menu (Dayflow-Design-Plan.md "Top bar & navigation"; build order
// step 5). Ground truth: Dayflow-Mockup.html's #anytimeScrim — "every no-date
// task, grouped by list... tapping a checkbox here would complete the task in
// Things directly."
//
// **Real data as of 2026-07-20.** Originally this stood in with
// `ThingsService.shared.tasks` (today's list only) since the Mini bridge had
// no true "every no-date task, all areas" endpoint — David found it "only
// shows the two tasks that are on the today sheet." Fixed by adding a real
// `/anytime` endpoint to `things-jxa-server.py` (`things.lists.byName
// ("Anytime").toDos()`) and `ThingsService.anytimeTasks` /
// `fetchAnytime()`. This view now groups the real Anytime list by list name,
// same as before, with no caveat caption needed anymore.
//
// Tapping a task's title opens DayflowTaskEditSheet (title/date/list); tapping
// the checkbox still completes it directly via `ThingsService.complete(taskID:)`.
//
// **Pull-to-refresh added 2026-07-20** — see DayflowUpcomingView.swift's
// header comment for the "note edited directly in Things didn't show up in
// Dayflow" finding this addresses. This view already reads
// `ThingsService.shared.anytimeTasks` live (no local snapshot), so no other
// change was needed here.

struct DayflowAnytimeView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var expandedLists: Set<String> = []
    @State private var editingTask: ThingsTask? = nil

    private static let collapsedCount = 3

    private var grouped: [(list: String, tasks: [ThingsTask])] {
        let byList = Dictionary(grouping: ThingsService.shared.anytimeTasks) { task -> String in
            let list = task.list ?? ""
            return list.isEmpty ? "No List" : list
        }
        return byList.keys.sorted { lhs, rhs in
            if lhs == "No List" { return false }
            if rhs == "No List" { return true }
            return lhs < rhs
        }.map { (list: $0, tasks: byList[$0] ?? []) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if ThingsService.shared.isLoadingAnytime && ThingsService.shared.anytimeTasks.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        if ThingsService.shared.anytimeTasks.isEmpty {
                            Text("Nothing here.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .padding(.top, 24)
                        } else {
                            ForEach(grouped, id: \.list) { group in
                                listGroup(group)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                }
                .refreshable { await ThingsService.shared.fetchAnytime() }
            }
        }
        .task { await ThingsService.shared.fetchAnytime() }
        .sheet(item: $editingTask) { task in
            DayflowTaskEditSheet(taskID: task.id, initialTitle: task.title,
                                  initialDate: task.date, initialList: task.list,
                                  initialNotes: task.notes) {
                Task { await ThingsService.shared.fetchAnytime() }
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
            Text("Anytime")
                .font(.custom("Georgia", size: 20).weight(.bold))
            Spacer()

            Color.clear.frame(width: 32, height: 32)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }

    // MARK: List groups

    private func listGroup(_ group: (list: String, tasks: [ThingsTask])) -> some View {
        let isExpanded = expandedLists.contains(group.list)
        let visible = isExpanded ? group.tasks : Array(group.tasks.prefix(Self.collapsedCount))
        let remaining = group.tasks.count - visible.count

        return VStack(alignment: .leading, spacing: 2) {
            Text(group.list)
                .font(.system(size: 13, weight: .bold))
                .padding(.top, 14)
                .padding(.bottom, 6)
                .overlay(Divider(), alignment: .bottom)

            ForEach(visible) { task in
                taskRow(task)
            }

            if remaining > 0 {
                Button {
                    expandedLists.insert(group.list)
                } label: {
                    Text("Show \(remaining) more")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.leading, 25)
                .padding(.vertical, 4)
            }
        }
    }

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
        .padding(.vertical, 3)
    }
}
