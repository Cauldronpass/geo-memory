import SwiftUI
import UIKit

// MARK: - DayflowInboxView
//
// Step (c) of the task UI build (Session 77, Dayflow-Tasks-Design.md §
// Inbox): ONE ITEM AT A TIME. The old flat "Unfiled Tasks" list (this file's
// pre-77 life — see git for its history and the Things-era comments) is
// gone; processing an inbox is a decision loop, not a scroll.
//
// The screen, top to bottom: Editorial header ("TO DECIDE" / Inbox), the
// current card (added-day · list, serif title, notes, "1 of 4" counter),
// four choices — Today · Tomorrow · Pick day · Delete (Delete asks nothing,
// David's locked call) — a Done tick underneath, a small list chooser that
// moves the task to another Reminders list, and the "Up next" queue below.
// Swiping the card sideways SKIPS: the task goes to the back of the queue,
// nothing is written to Reminders.
//
// Source: undated reminders in the Personal list
// (ReminderTaskStore.inboxTasks). Dating a task (Today/Tomorrow/Pick day),
// completing it, deleting it, or moving it off Personal all remove it from
// the queue naturally — the queue is a local ORDER over live store data,
// never a copy of it.
//
// The + here captures INTO the inbox (title + optional note → undated,
// Personal) — deliberately smaller than the Today tab's Quick Add: the
// inbox + is for catching a stray thought mid-triage, not for scheduling.
// Judgment call, flagged to David 2026-08-28.

struct DayflowInboxView: View {
    @Environment(\.dismiss) private var dismiss
    /// Session 77: true when hosted as the Inbox tab in DayflowRootView —
    /// hides the chevron (there is no presentation to dismiss there).
    var isTabRoot: Bool = false

    /// Task ids in decision order. An order over `inboxTasks`, resynced on
    /// every store change: existing order kept, new arrivals appended,
    /// departed ids dropped.
    @State private var queue: [String] = []
    @State private var editingTask: ThingsTask? = nil
    @State private var showDatePicker = false
    @State private var pickedDate = Date()
    @State private var showCapture = false
    @State private var captureTitle = ""
    @State private var captureNotes = ""
    @State private var cardOffset: CGFloat = 0
    /// The Home Screen "Add Task" quick action lands here since the composer
    /// round (Today's + is event-only): the root selects this tab and the
    /// capture card opens ready to type.
    @State private var quickActions = DayflowQuickActionRouter.shared
    @FocusState private var captureFocused: Bool

    private var store: ReminderTaskStore { ReminderTaskStore.shared }
    private var orderedTasks: [ThingsTask] {
        queue.compactMap { id in store.inboxTasks.first { $0.id == id } }
    }
    private var current: ThingsTask? { orderedTasks.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if store.isLoadingInbox && store.inboxTasks.isEmpty {
                Spacer()
                ProgressView().frame(maxWidth: .infinity)
                Spacer()
            } else if let task = current {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        card(task)
                        choices(task)
                        doneRow(task)
                        upNext
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 80)
                }
                .scrollIndicators(.hidden)
            } else {
                emptyState
            }
        }
        .dayflowSkinBackground()
        .task {
            await store.fetchInbox()
            resyncQueue()
            consumeQuickAction()
        }
        .onChange(of: quickActions.pending) { _, _ in consumeQuickAction() }
        .onChange(of: store.inboxTasks.map(\.id)) { _, _ in resyncQueue() }
        .sheet(item: $editingTask) { task in
            DayflowTaskEditSheet(taskID: task.id, initialTitle: task.title,
                                 initialDate: task.date, initialList: task.list,
                                 initialNotes: task.notes) {
                Task { await store.fetchInbox() }
            }
        }
        .sheet(isPresented: $showDatePicker) { datePickerSheet }
        .overlay(alignment: .bottomTrailing) {
            if isTabRoot {
                Button {
                    captureTitle = ""; captureNotes = ""
                    withAnimation(.easeOut(duration: 0.15)) { showCapture = true }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(Color.dayflowPaper)
                        .frame(width: 50, height: 50)
                        .background(Color.dayflowFloatingAction, in: RoundedRectangle(cornerRadius: 2))
                        .shadow(color: .black.opacity(0.22), radius: 8, x: 0, y: 4)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 20)
                .padding(.bottom, 8)
            }
        }
        .overlay {
            if showCapture { captureOverlay.transition(.opacity) }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                if !isTabRoot {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
            }
            Text("TO DECIDE")
                .font(.system(size: 11, weight: .medium))
                .tracking(2.2)
                .foregroundStyle(Color.dayflowMuted)
            Text("Inbox")
                .font(.dayflowSerif(30, weight: .heavy))
                .foregroundStyle(Color.dayflowInk)
        }
        .padding(.horizontal, 24)
        .padding(.top, isTabRoot ? 22 : 8)
        .padding(.bottom, 10)
    }

    // MARK: The card

    private func card(_ task: ThingsTask) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(metaLine(task))
                    .font(.system(size: 11))
                    .tracking(0.5)
                    .foregroundStyle(Color.dayflowFaint)
                Spacer()
                Text("1 of \(orderedTasks.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dayflowFaint)
            }
            Text(task.title)
                .font(.dayflowSerif(22, weight: .semibold))
                .foregroundStyle(Color.dayflowInk)
            if let notes = task.notes, !notes.isEmpty {
                Text(notes)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.dayflowMuted)
                    .lineLimit(5)
            }
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { editingTask = task }
        .offset(x: cardOffset)
        .gesture(
            DragGesture(minimumDistance: 20)
                .onChanged { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    cardOffset = value.translation.width
                }
                .onEnded { value in
                    // Sideways past the threshold = SKIP: back of the queue,
                    // nothing written. Only meaningful with a queue to go to.
                    if abs(value.translation.width) > 90, orderedTasks.count > 1 {
                        let direction: CGFloat = value.translation.width > 0 ? 1 : -1
                        withAnimation(.easeIn(duration: 0.15)) { cardOffset = direction * 420 }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                            skipCurrent()
                            cardOffset = -direction * 60
                            withAnimation(.easeOut(duration: 0.2)) { cardOffset = 0 }
                        }
                    } else {
                        withAnimation(.spring(duration: 0.3)) { cardOffset = 0 }
                    }
                }
        )
    }

    /// "Added Tuesday · Personal" — weekday within the last six days,
    /// "Added Aug 12" beyond, list name always.
    private func metaLine(_ task: ThingsTask) -> String {
        var parts: [String] = []
        if let created = task.createdDate {
            let cal = Calendar.current
            let f = DateFormatter()
            if cal.isDateInToday(created) {
                parts.append("Added today")
            } else if let days = cal.dateComponents([.day],
                                                    from: cal.startOfDay(for: created),
                                                    to: cal.startOfDay(for: Date())).day,
                      days < 7 {
                f.dateFormat = "EEEE"
                parts.append("Added \(f.string(from: created))")
            } else {
                f.dateFormat = "MMM d"
                parts.append("Added \(f.string(from: created))")
            }
        }
        if let list = task.list { parts.append(list) }
        return parts.joined(separator: " \u{00B7} ")
    }

    // MARK: The four choices

    private func choices(_ task: ThingsTask) -> some View {
        HStack(spacing: 8) {
            choiceButton("Today") { decide(task) { await date(task, Date()) } }
            choiceButton("Tomorrow") {
                decide(task) {
                    await date(task, Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date())
                }
            }
            choiceButton("Pick day") {
                pickedDate = Date()
                showDatePicker = true
            }
            choiceButton("Delete", isDestructive: true) {
                // Asks nothing — locked in the design review.
                decide(task) { _ = await store.remove(taskID: task.id) }
            }
        }
        .padding(.top, 10)
    }

    private func choiceButton(_ label: String, isDestructive: Bool = false,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isDestructive ? Color.dayflowAccent : Color.dayflowInk)
                .frame(maxWidth: .infinity, minHeight: 44)
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isDestructive ? Color.dayflowAccent : Color.dayflowHairline,
                                  lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func doneRow(_ task: ThingsTask) -> some View {
        HStack {
            Button {
                decide(task) { await store.complete(taskID: task.id) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 15))
                    Text("Done")
                        .font(.system(size: 13.5))
                }
                .foregroundStyle(Color.dayflowMuted)
            }
            .buttonStyle(.plain)
            Spacer()
            Menu {
                ForEach(store.listNames.filter { $0 != task.list }, id: \.self) { name in
                    Button(name) { decide(task) { _ = await move(task, to: name) } }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(task.list ?? ReminderTaskStore.personalListName)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
                .font(.system(size: 12))
                .foregroundStyle(Color.dayflowFaint)
            }
        }
        .frame(minHeight: 44)
    }

    // MARK: Up next

    private var upNext: some View {
        let rest = Array(orderedTasks.dropFirst())
        return VStack(alignment: .leading, spacing: 0) {
            if !rest.isEmpty {
                Text("UP NEXT")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(2)
                    .foregroundStyle(Color.dayflowInk)
                    .padding(.top, 24)
                    .padding(.bottom, 6)
                Rectangle().fill(Color.dayflowInk).frame(height: 1)
                ForEach(rest.prefix(6)) { task in
                    Text(task.title)
                        .font(.system(size: 14))
                        .foregroundStyle(Color.dayflowMuted)
                        .lineLimit(1)
                        .frame(minHeight: 36, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Rectangle().fill(Color.dayflowHairline).frame(height: 1)
                }
                if rest.count > 6 {
                    Text("and \(rest.count - 6) more")
                        .font(.system(size: 12))
                        .italic()
                        .foregroundStyle(Color.dayflowFaint)
                        .padding(.top, 8)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Spacer()
            Text("Nothing to decide.")
                .font(.dayflowSerif(17))
                .foregroundStyle(Color.dayflowMuted)
            Text("New thoughts land here until you give them a day.")
                .font(.system(size: 13))
                .foregroundStyle(Color.dayflowFaint)
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Sheets

    private var datePickerSheet: some View {
        VStack(spacing: 12) {
            DatePicker("Day", selection: $pickedDate, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .tint(Color.dayflowAccent)
            Button {
                showDatePicker = false
                if let task = current {
                    decide(task) { await date(task, pickedDate) }
                }
            } label: {
                Text("Set day")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.dayflowPaper)
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .background(Color.dayflowInk, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
        .padding(20)
        .presentationDetents([.medium, .large])
    }

    /// Things-style capture (David, 2026-08-28: "it needs to place the
    /// cursor in the field to start typing right away... Things moves this
    /// input window center screen"). A floating card in a ZStack, not a
    /// bottom sheet: the keyboard's safe-area inset shrinks the ZStack, so
    /// the card centers itself in the space ABOVE the keyboard — the Things
    /// position — with no keyboard math. Focus lands one runloop hop after
    /// appearance; setting it synchronously in onAppear loses the race with
    /// the field's own setup and costs the extra tap David hit.
    private var captureOverlay: some View {
        ZStack {
            Color.black.opacity(0.25)
                .ignoresSafeArea()
                .onTapGesture {
                    captureFocused = false
                    withAnimation(.easeOut(duration: 0.15)) { showCapture = false }
                }
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Circle()
                        .strokeBorder(Color.dayflowFaint, lineWidth: 1.5)
                        .frame(width: 20, height: 20)
                    TextField("New to-do", text: $captureTitle)
                        .font(.dayflowSerif(19, weight: .semibold))
                        .focused($captureFocused)
                        .submitLabel(.done)
                        .onSubmit { commitCapture() }
                }
                TextField("Notes", text: $captureNotes, axis: .vertical)
                    .font(.system(size: 14))
                    .lineLimit(1...3)
                    .padding(.leading, 32)
                HStack {
                    Text("INBOX \u{00B7} PERSONAL")
                        .font(.system(size: 10, weight: .medium))
                        .tracking(1.5)
                        .foregroundStyle(Color.dayflowFaint)
                    Spacer()
                    Button { commitCapture() } label: {
                        Text("Add")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(captureTitle.trimmingCharacters(in: .whitespaces).isEmpty
                                             ? Color.dayflowFaint : Color.dayflowAccent)
                    }
                    .buttonStyle(.plain)
                    .disabled(captureTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.top, 2)
            }
            .padding(18)
            .background(Color.dayflowPaper, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.dayflowHairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.20), radius: 20, x: 0, y: 8)
            .padding(.horizontal, 24)
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                captureFocused = true
            }
        }
    }

    // MARK: Actions

    private func consumeQuickAction() {
        guard isTabRoot, quickActions.pending == "AddTask" else { return }
        quickActions.pending = nil
        captureTitle = ""; captureNotes = ""
        withAnimation(.easeOut(duration: 0.15)) { showCapture = true }
    }

    private func resyncQueue() {
        let live = store.inboxTasks.map(\.id)
        var next = queue.filter { live.contains($0) }
        for id in live where !next.contains(id) { next.append(id) }
        queue = next
    }

    private func skipCurrent() {
        guard queue.count > 1 else { return }
        let head = queue.removeFirst()
        queue.append(head)
    }

    /// Runs a write with a small send-off animation; the store refresh drops
    /// the task from `inboxTasks` and `resyncQueue` advances the queue.
    private func decide(_ task: ThingsTask, _ write: @escaping () async -> Void) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task {
            await write()
            await store.fetchInbox()
        }
    }

    private func date(_ task: ThingsTask, _ day: Date) async {
        _ = await store.update(taskID: task.id, title: task.title,
                               date: day, clearDate: false, list: nil,
                               notes: task.notes)
    }

    private func move(_ task: ThingsTask, to list: String) async -> Bool {
        await store.update(taskID: task.id, title: task.title,
                           date: nil, clearDate: false, list: list,
                           notes: task.notes)
    }

    private func commitCapture() {
        let title = captureTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let notes = captureNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        captureFocused = false
        withAnimation(.easeOut(duration: 0.15)) { showCapture = false }
        Task {
            _ = await store.addTask(title: title,
                                    list: ReminderTaskStore.personalListName,
                                    notes: notes.isEmpty ? nil : notes)
        }
    }
}
