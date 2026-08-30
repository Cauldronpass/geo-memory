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
// Source: undated reminders in the INBOX list (option three, D158 — capture
// has its own list; Personal is a topic again and, with the other topical
// lists, forms the Anytime pool). Dating a task (Today/Tomorrow/Pick day),
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
    @State private var whenTask: DayflowWhenRequest? = nil
    /// A task the chooser just moved OFF the Inbox list, held in focus so a
    /// date (or Done, or a way out) can follow in the same visit — David,
    /// 2026-08-29: "hitting personal or trace moves it to that list without
    /// letting me add a date." The list pick is a property edit, not an
    /// exit; any deciding action, a skip, or promoting an Up Next row
    /// releases the hold.
    @State private var held: ThingsTask? = nil
    @State private var showCapture = false
    @State private var captureTitle = ""
    @State private var captureNotes = ""
    /// Capture round three (2026-08-29, David: "improve the joy of this new
    /// to-do window. Add is small and uninspiring"). nil = the Inbox;
    /// 0/1 = Today/Tomorrow — a dated capture is already DECIDED, so it
    /// skips the Inbox and lands in Personal with the date on.
    /// Capture round five (2026-08-29, the task-add friction discussion):
    /// the date is a real Date now — TODAY/TOMORROW chips set it directly,
    /// and PICK DAY unfolds the masthead's own month grid INSIDE the card
    /// (keyboard drops while it's open, comes back after the pick). Any
    /// capture door can now say "August 31."
    @State private var captureDate: Date? = nil
    @State private var captureMonthOpen = false
    /// Capture round four (2026-08-29, TestFlight): the destination label is
    /// a MENU now — "i thought we had the option for me to press that inbox
    /// text and change it directly there to one of the other lists." nil =
    /// the default routing (Inbox; Personal when dated).
    @State private var captureList: String? = nil
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
    private var current: ThingsTask? { held ?? orderedTasks.first }

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
        .sheet(item: $whenTask) { request in
            // The SAME When card as the swipes (calendar + REMIND with lead
            // days) — Pick day from triage can set a reminder in the same
            // breath (David, 2026-08-29).
            DayflowWhenSheet(tasks: request.tasks) {
                held = nil
                Task { await store.fetchInbox() }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if isTabRoot {
                Button {
                    captureTitle = ""; captureNotes = ""; captureDate = nil
                    captureMonthOpen = false; captureList = nil
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .dayflowQuickFindPull(enabled: isTabRoot)
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
                Text("1 of \(orderedTasks.count + (held == nil ? 0 : 1))")
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
                    if abs(value.translation.width) > 90, held != nil || orderedTasks.count > 1 {
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
                whenTask = DayflowWhenRequest(tasks: [task])
            }
            choiceButton("Delete", isDestructive: true) {
                // Asks nothing — locked in the design review. The undo pill
                // (Session 78) is the safety net that lets it stay that way.
                DayflowUndoStack.shared.record([task])
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
            // Session 78, D158 — the two dateless ways out, Things' verbs:
            // ANYTIME (active, no date — files to Personal, the generic
            // topic; the chooser picks a specific one) and SOMEDAY (cold
            // storage). Quiet, next to Done: "not now" costs one tap.
            Button {
                decide(task) { _ = await move(task, to: ReminderTaskStore.personalListName) }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "books.vertical")
                        .font(.system(size: 12))
                    Text("Anytime")
                        .font(.system(size: 13))
                        .lineLimit(1)
                }
                .fixedSize()
                .foregroundStyle(Color.dayflowMuted)
            }
            .buttonStyle(.plain)
            .padding(.leading, 16)
            Button {
                decide(task) { _ = await store.moveToSomeday(taskID: task.id) }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "archivebox")
                        .font(.system(size: 12))
                    Text("Someday")
                        .font(.system(size: 13))
                        .lineLimit(1)
                }
                .fixedSize()
                .foregroundStyle(Color.dayflowMuted)
            }
            .buttonStyle(.plain)
            .padding(.leading, 16)
            Spacer()
            Menu {
                if !store.listNames.contains(ReminderTaskStore.somedayListName) {
                    // Not created yet — offer it anyway; moveToSomeday makes it.
                    Button(ReminderTaskStore.somedayListName) {
                        decide(task) { _ = await store.moveToSomeday(taskID: task.id) }
                    }
                }
                ForEach(store.listNames.filter { $0 != task.list }, id: \.self) { name in
                    Button(name) {
                        if name == ReminderTaskStore.somedayListName {
                            decide(task) { _ = await store.moveToSomeday(taskID: task.id) }
                        } else {
                            // Move now but STAY focused, so a date can
                            // follow in the same visit (David, 2026-08-29).
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            held = task
                            Task {
                                _ = await move(task, to: name)
                                await store.fetchInbox()
                                if let fresh = store.anytimeTasks.first(where: { $0.id == task.id }) {
                                    held = fresh
                                }
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    // The one variable-width element on the row: IT yields
                    // (truncates) so the fixed verbs never wrap — "Anytim e"
                    // beside a Financial list, David's screenshot.
                    Text(task.list ?? ReminderTaskStore.personalListName)
                        .lineLimit(1)
                        .truncationMode(.tail)
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
        let rest = held == nil ? Array(orderedTasks.dropFirst()) : orderedTasks
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
                    // Tap to bring it to the front — swiping through the
                    // queue should never be the ONLY way to reach an item
                    // (David, 2026-08-29).
                    Text(task.title)
                        .font(.system(size: 14))
                        .foregroundStyle(Color.dayflowMuted)
                        .lineLimit(1)
                        .frame(minHeight: 36, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { promote(task.id) }
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
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Circle()
                        .strokeBorder(Color.dayflowFaint, lineWidth: 1.6)
                        .frame(width: 22, height: 22)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
                    TextField("New to-do", text: $captureTitle)
                        .font(.dayflowSerif(22, weight: .semibold))
                        .focused($captureFocused)
                        .submitLabel(.done)
                        .onSubmit { commitCapture() }
                }
                TextField("Notes", text: $captureNotes, axis: .vertical)
                    .font(.system(size: 14))
                    .lineLimit(2...5)
                    .padding(.leading, 34)
                // The one decision worth offering at capture: WHEN, quietly.
                // Tapping a chip means it's decided — the task lands dated
                // in Personal instead of joining the deciding queue.
                HStack(spacing: 8) {
                    captureChip("TODAY", date: Calendar.current.startOfDay(for: Date()))
                    captureChip("TOMORROW", date: Calendar.current.date(
                        byAdding: .day, value: 1,
                        to: Calendar.current.startOfDay(for: Date())) ?? Date())
                    capturePickDayChip
                    Spacer()
                }
                .padding(.leading, 34)
                if captureMonthOpen {
                    DayflowMonthUnfold(selectedDate: captureDate ?? Date(), onPick: { day in
                        captureDate = day
                        withAnimation(.easeInOut(duration: 0.18)) { captureMonthOpen = false }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            captureFocused = true
                        }
                    }, hint: "tap a day to set it")
                }
                Rectangle().fill(Color.dayflowHairline).frame(height: 1)
                HStack(alignment: .center) {
                    Menu {
                        Button {
                            captureList = nil
                        } label: {
                            Label(ReminderTaskStore.inboxListName, systemImage: "tray")
                        }
                        Divider()
                        ForEach(store.listNames.filter { $0 != ReminderTaskStore.inboxListName },
                                id: \.self) { name in
                            Button(name) { captureList = name }
                        }
                        if !store.listNames.contains(ReminderTaskStore.somedayListName) {
                            Button(ReminderTaskStore.somedayListName) {
                                captureList = ReminderTaskStore.somedayListName
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: captureGlyph)
                                .font(.system(size: 10))
                            Text(captureDestinationLabel)
                                .tracking(1.5)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 7, weight: .semibold))
                        }
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.dayflowFaint)
                        .contentShape(Rectangle())
                    }
                    Spacer()
                    Button { commitCapture() } label: {
                        Text("Save")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.dayflowPaper)
                            .padding(.horizontal, 22)
                            .padding(.vertical, 9)
                            .background(captureReady ? Color.dayflowInk : Color.dayflowFaint,
                                        in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .disabled(!captureReady)
                }
            }
            .padding(20)
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
        captureTitle = ""; captureNotes = ""; captureDate = nil
        captureMonthOpen = false; captureList = nil
        withAnimation(.easeOut(duration: 0.15)) { showCapture = true }
    }

    private func resyncQueue() {
        let live = store.inboxTasks.map(\.id)
        var next = queue.filter { live.contains($0) }
        for id in live where !next.contains(id) { next.append(id) }
        queue = next
    }

    /// An Up Next row was tapped: release any hold and move it to the
    /// front of the queue with a spring.
    private func promote(_ id: String) {
        held = nil
        UISelectionFeedbackGenerator().selectionChanged()
        withAnimation(.spring(duration: 0.3)) {
            queue.removeAll { $0 == id }
            queue.insert(id, at: 0)
        }
    }

    private func skipCurrent() {
        if held != nil { held = nil; return }
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
            held = nil
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

    private var captureReady: Bool {
        !captureTitle.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The effective destination list: an explicit pick wins; otherwise the
    /// default routing (dated = decided = Personal; undated = the Inbox).
    private var captureEffectiveList: String {
        if let captureList { return captureList }
        return captureDate == nil
            ? ReminderTaskStore.inboxListName
            : ReminderTaskStore.personalListName
    }

    private var captureGlyph: String {
        if captureDate != nil { return "sun.max" }
        return captureEffectiveList == ReminderTaskStore.inboxListName ? "tray" : "list.bullet"
    }

    private var captureDestinationLabel: String {
        let list = captureEffectiveList
        let listLabel = list == ReminderTaskStore.inboxListName
            ? "THE INBOX" : list.uppercased()
        guard let date = captureDate else { return "TO \(listLabel)" }
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "TO TODAY \u{00B7} \(listLabel)" }
        if cal.isDateInTomorrow(date) { return "TO TOMORROW \u{00B7} \(listLabel)" }
        let f = DateFormatter(); f.dateFormat = "EEE MMM d"
        return "TO \(f.string(from: date).uppercased()) \u{00B7} \(listLabel)"
    }

    private func captureChip(_ label: String, date: Date) -> some View {
        let selected = captureDate.map { Calendar.current.isDate($0, inSameDayAs: date) } ?? false
        return Button {
            withAnimation(.easeInOut(duration: 0.12)) {
                captureDate = selected ? nil : date
                captureMonthOpen = false
            }
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            captureChipLabel(label, selected: selected)
        }
        .buttonStyle(.plain)
    }

    /// PICK DAY: unfolds the month in the card (the keyboard steps aside —
    /// picking a date is not typing); once a day beyond today/tomorrow is
    /// chosen the chip wears it ("AUG 31").
    private var capturePickDayChip: some View {
        let cal = Calendar.current
        let arbitrary = captureDate.map {
            !cal.isDateInToday($0) && !cal.isDateInTomorrow($0)
        } ?? false
        let label: String
        if arbitrary, let date = captureDate {
            let f = DateFormatter(); f.dateFormat = "MMM d"
            label = f.string(from: date).uppercased()
        } else {
            label = "PICK DAY"
        }
        return Button {
            withAnimation(.easeInOut(duration: 0.18)) { captureMonthOpen.toggle() }
            if captureMonthOpen { captureFocused = false }
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            captureChipLabel(label, selected: arbitrary || captureMonthOpen)
        }
        .buttonStyle(.plain)
    }

    private func captureChipLabel(_ label: String, selected: Bool) -> some View {
        Text(label)
            .font(.system(size: 10.5, weight: selected ? .bold : .regular))
            .tracking(1.2)
            .foregroundStyle(selected ? Color.dayflowAccent : Color.dayflowMuted)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .overlay(RoundedRectangle(cornerRadius: 7)
                .strokeBorder(selected ? Color.dayflowAccent : Color.dayflowHairline,
                              lineWidth: selected ? 1.4 : 1))
    }

    private func commitCapture() {
        let title = captureTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let notes = captureNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        let day = captureDate
        let destination = captureEffectiveList
        captureFocused = false
        withAnimation(.easeOut(duration: 0.15)) { showCapture = false }
        captureDate = nil; captureMonthOpen = false; captureList = nil
        Task {
            _ = await store.addTask(title: title,
                                    date: day,
                                    list: destination,
                                    notes: notes.isEmpty ? nil : notes)
        }
    }
}
