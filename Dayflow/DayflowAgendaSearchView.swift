import SwiftUI

// MARK: - DayflowAgendaSearchView
//
// Browse: Search — the newest destination off the top-bar calendar icon's
// menu (Dayflow-Design-Plan.md "Top bar & navigation"; added Session 11,
// 2026-07-20). Deliberately separate from DayflowNotesView's notes/#tag
// search: this one searches Things tasks (title + notes) and calendar events
// (title) across every list Dayflow already fetches, not markdown files.
// David's own call during the design conversation — this lives with the
// other "ways to see tasks/events beyond today's Agenda" (Upcoming/Calendar/
// Anytime/Inbox), not behind the Settings gear, which stays single-purpose.
//
// Matches on keyword only, not a date-range picker — jumping to a specific
// date is already Browse: Calendar's job, so a second way to do the same
// thing here would be redundant.
//
// Tapping a task opens the existing DayflowTaskEditSheet (title/date/list/
// notes), same as every other task row in the app.
//
// **Event rows made tappable 2026-07-21 (Session 23).** Calendar events still
// have no edit path anywhere in Dayflow — that hasn't changed — but they now
// open the new read-only DayflowEventDetailView (same destination
// DayflowAgendaSection.swift and DayflowUpcomingView.swift's event rows open)
// instead of being purely informational. `EventHit` already wrapped the real
// `NextCalendarEvent`, so this was just a tap target + a sheet.

struct DayflowAgendaSearchView: View {
    @Environment(\.dismiss) private var dismiss

    private struct EventHit: Identifiable {
        var id: String { "\(event.title)-\(event.startDate.timeIntervalSinceReferenceDate)" }
        let event: NextCalendarEvent
    }

    @State private var searchText = ""
    @State private var allEvents: [NextCalendarEvent] = []
    @State private var isLoadingEvents = false
    @State private var editingTask: ThingsTask? = nil
    @State private var selectedEvent: NextCalendarEvent? = nil

    private var matchingTasks: [ThingsTask] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        let all = ThingsService.shared.tasks + ThingsService.shared.anytimeTasks
            + ThingsService.shared.upcomingTasks + ThingsService.shared.inboxTasks
        var seen = Set<String>()
        var out: [ThingsTask] = []
        for t in all {
            guard !seen.contains(t.id) else { continue }
            let titleMatch = t.title.lowercased().contains(q)
            let notesMatch = (t.notes ?? "").lowercased().contains(q)
            guard titleMatch || notesMatch else { continue }
            seen.insert(t.id)
            out.append(t)
        }
        return out
    }

    private var matchingEvents: [EventHit] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        return allEvents.filter { $0.title.lowercased().contains(q) }.map { EventHit(event: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            searchBar
            // Skin fix 2026-07-22 (Session 32) — same card treatment as the
            // home screen / Notes / Upcoming / Anytime / Inbox. See
            // DayflowSkin.swift.
            Group {
                content
            }
            .dayflowCard()
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        // Skin fix 2026-07-22 (Session 32) — same warm gradient as the home
        // screen. See DayflowSkin.swift.
        .dayflowSkinBackground()
        .task { await loadEvents() }
        .sheet(item: $editingTask) { task in
            DayflowTaskEditSheet(taskID: task.id, initialTitle: task.title,
                                  initialDate: task.date, initialList: task.list,
                                  initialNotes: task.notes) {
                Task { await ThingsService.shared.refreshAll() }
            }
        }
        .sheet(item: $selectedEvent) { event in
            NavigationStack {
                DayflowEventDetailView(event: event)
            }
        }
    }

    // MARK: Header — matches DayflowAnytimeView's Browse-destination header

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
            // See DayflowSkin.swift.
            Text("Search").font(.dayflowSerif(20))
            Spacer()
            Color.clear.frame(width: 32, height: 32)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search tasks and events…", text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.quaternarySystemFill), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var content: some View {
        // Bug fix 2026-07-22 (Session 33). Was `Text(...)` followed by a
        // sibling `Spacer()` in these first two branches. `Group { content }`
        // in `body` applies `.dayflowCard()` to whatever `content` returns —
        // but a `Group` with MULTIPLE children doesn't give its modifiers a
        // combined bounding box; each child gets its own copy of the
        // modifier independently. That put a tightly-fit white card around
        // just the Text (explaining the small floating box David saw) and a
        // separate, invisible one around the zero-width `Spacer()` (since a
        // bare `Spacer()` in a leading-aligned VStack has no width to give a
        // background shape) — leaving the rest of the screen bare gradient.
        // Fixed by making each branch a SINGLE view that fills the available
        // space itself via `.frame(maxWidth: .infinity, maxHeight: .infinity)`
        // instead of a second sibling `Spacer()` — now `.dayflowCard()` wraps
        // one real view per branch and covers the whole area, same as the
        // (already-correct) results branch below.
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            Text("Search across your Things tasks and calendar events.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else if matchingTasks.isEmpty && matchingEvents.isEmpty && !isLoadingEvents {
            Text("No tasks or events match \"\(query)\".")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if !matchingTasks.isEmpty {
                        sectionLabel("TASKS")
                        ForEach(matchingTasks) { task in taskRow(task) }
                    }
                    if !matchingEvents.isEmpty {
                        sectionLabel("EVENTS")
                        ForEach(matchingEvents) { hit in eventRow(hit.event) }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.4)
            .foregroundStyle(.secondary)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }

    @ViewBuilder
    private func taskRow(_ task: ThingsTask) -> some View {
        Button { editingTask = task } label: {
            HStack(spacing: 9) {
                Circle().strokeBorder(Color.gray.opacity(0.45), lineWidth: 2).frame(width: 16, height: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(task.title).font(.system(size: 13.5)).foregroundStyle(.primary).lineLimit(2)
                    if let list = task.list, !list.isEmpty {
                        Text(list).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
        Divider()
    }

    @ViewBuilder
    private func eventRow(_ event: NextCalendarEvent) -> some View {
        Button { selectedEvent = event } label: {
            HStack(spacing: 9) {
                Text("🕒").font(.system(size: 11))
                VStack(alignment: .leading, spacing: 1) {
                    Text(event.title).font(.system(size: 13.5)).foregroundStyle(.primary).lineLimit(2)
                    Text(eventDateLabel(event)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
        Divider()
    }

    private func eventDateLabel(_ event: NextCalendarEvent) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE MMM d"
        return f.string(from: event.startDate)
    }

    // MARK: Data
    //
    // A wide but bounded window (1 year back, 1 year ahead) rather than
    // "everything ever" — EventKit has no keyword-search API of its own, so
    // this fetches a range via the same `fetchEvents(from:to:)` Browse:
    // Upcoming already uses, then filters client-side by title.

    private func loadEvents() async {
        isLoadingEvents = true
        let cal = Calendar.current
        let start = cal.date(byAdding: .year, value: -1, to: Date()) ?? Date()
        let end = cal.date(byAdding: .year, value: 1, to: Date()) ?? Date()
        allEvents = await CalendarService.shared.fetchEvents(from: start, to: end)
        isLoadingEvents = false
    }
}
