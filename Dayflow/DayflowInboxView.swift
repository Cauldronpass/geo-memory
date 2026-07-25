import SwiftUI

// MARK: - DayflowInboxView
//
// Browse: **Unfiled Tasks** (labeled "Inbox" until 2026-07-24 — renamed in
// Session 44 addendum 10 when "Inbox" became the name of the unrelated
// notes-staging feature, reached by swiping right on the home screen; that
// feature holds evergreen notes waiting to be filed to a Project/Person/
// Place, a completely different concept from the unfiled Things tasks this
// screen shows. The Swift type name `DayflowInboxView` and its file name
// were deliberately left unchanged to avoid touching every call site for a
// pure display-string rename — only what's on screen changed.)
//
// The fourth destination off the top-bar calendar icon menu, alongside
// Upcoming/Calendar/Anytime (Dayflow-Design-Plan.md "Top bar & navigation";
// build order step 5b). Requested 2026-07-20, after the original
// three-destination mockup review — Dayflow-Mockup.html never covered this
// screen, so there's no locked ground-truth interaction spec the way Upcoming/
// Calendar/Anytime have. Closest reference is DayflowAnytimeView.swift, but
// unlike Anytime (which groups by list/area), these tasks are unfiled by
// definition — `things-jxa-server.py`'s `/inbox` endpoint always sends
// `project_title: ""` for every row (see that file's header comment) — so
// this view is a flat list rather than grouped sections. If that turns out to
// be wrong once David sees real data on-device, revisit; this is a judgment
// call, not a confirmed spec.
//
// Same interaction pattern as the other three Browse views: tapping a task's
// checkbox completes it directly via `ThingsService.complete(taskID:)`;
// tapping its title opens `DayflowTaskEditSheet` (title/date/list) — setting a
// date or list on a task here is exactly how you'd file it out of this list,
// so this is probably the most-used edit path of any Browse screen once it's
// on-device tested.
//
// **Pull-to-refresh added 2026-07-20** — see DayflowUpcomingView.swift's
// header comment for the "note edited directly in Things didn't show up in
// Dayflow" finding this addresses. This view already reads
// `ThingsService.shared.inboxTasks` live (no local snapshot), so no other
// change was needed here.

struct DayflowInboxView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var editingTask: ThingsTask? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            // Skin fix 2026-07-22 (Session 32) — same card treatment as the
            // home screen / Notes / Upcoming / Anytime. See DayflowSkin.swift.
            Group {
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
                    .refreshable { await ThingsService.shared.fetchInbox() }
                }
            }
            .dayflowCard()
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        // Skin fix 2026-07-22 (Session 32) — same warm gradient as the home
        // screen. See DayflowSkin.swift.
        .dayflowSkinBackground()
        .task { await ThingsService.shared.fetchInbox() }
        .sheet(item: $editingTask) { task in
            DayflowTaskEditSheet(taskID: task.id, initialTitle: task.title,
                                  initialDate: task.date, initialList: task.list,
                                  initialNotes: task.notes) {
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
            // Skin fix 2026-07-22 (Session 32) — was .custom("Georgia", ...).
            // See DayflowSkin.swift. Renamed from "Inbox" 2026-07-24 — see
            // this file's header comment.
            Text("Unfiled Tasks")
                .font(.dayflowSerif(20))
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
