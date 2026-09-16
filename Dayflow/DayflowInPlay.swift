// DayflowInPlay.swift
// Dayflow. D427 — IN PLAY on the phone.
//
// Approved mockup: `System/Trace-Swift/dayflow-in-play-mockup-v1.html` (D426),
// amended by David: *"can we always start with In Play folded whenever I go to
// Today?"*
//
// The Mac's rail group (D411) rebuilt for a screen with no rail: a fold under
// Today's masthead, in the spot the endeavor presence lines already held.
// Four kinds, in the Mac's order, from the same sources the Mac reads:
//
//   endeavors      `DayflowEndeavorPresence`'s own rule and rows (D182)
//   flagged tasks  reminder `priority` (D413)
//   pinned notes   `DayflowFlagStore`, the shared pin index (D423)
//   Kit            `KitWindow` over Satchel's documents (D420)
//
// **Today only.** On any other day this draws the plain endeavor presence lines
// exactly as before, because IN PLAY describes now, not that day.
//
// **Folded on every arrival** (D426 amended). Plain `@State`, reset when this
// view appears (the Today tab being chosen, or swiping back to today recreates
// it) and when the app comes back to the foreground. Never `@AppStorage`: the
// point is that it does not remember.

import SwiftUI

struct DayflowInPlay: View {
    let date: Date
    var onOpenEndeavor: (String) -> Void

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    @State private var expanded = false
    @State private var showAll = false
    @State private var editingTask: ThingsTask? = nil
    @State private var satchelUnavailable = false

    @State private var endeavorStore = EndeavorStore.shared
    @State private var taskStore = ReminderTaskStore.shared
    @State private var pins = DayflowFlagStore.shared
    @State private var documents = TraceSatchelChipStore.shared

    /// Rows after the endeavor lines before "N more".
    private static let rowCap = 5

    var body: some View {
        if Calendar.current.isDateInToday(date) {
            today
        } else {
            DayflowEndeavorPresence(onOpen: onOpenEndeavor)
        }
    }

    // MARK: Today

    @ViewBuilder
    private var today: some View {
        let endeavors: [Endeavor] = DayflowEndeavorPresence.qualifying(endeavorStore.endeavors)
        let items: [DayflowInPlayItem] = rows
        VStack(alignment: .leading, spacing: 0) {
            if !endeavors.isEmpty || !items.isEmpty {
                if expanded {
                    header
                    DayflowEndeavorPresence(onOpen: onOpenEndeavor)
                    list(items)
                } else {
                    folded(endeavors: endeavors, items: items)
                }
            }
        }
        .onAppear {
            expanded = false
            showAll = false
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                expanded = false
                showAll = false
            }
        }
        .task(id: NoteStore.shared.hasAccess) {
            await documents.loadIfNeeded()
        }
        .sheet(item: $editingTask) { task in
            DayflowTaskEditSheet(taskID: task.id, initialTitle: task.title,
                                 initialDate: task.date, initialList: task.list,
                                 initialNotes: task.notes) {
                Task { await ReminderTaskStore.shared.refreshAll() }
            }
        }
        .alert("Satchel isn't installed on this phone", isPresented: $satchelUnavailable) {
            Button("OK", role: .cancel) { }
        }
    }

    // MARK: Folded

    private func folded(endeavors: [Endeavor], items: [DayflowInPlayItem]) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { expanded = true }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("IN PLAY")
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(2)
                    .foregroundStyle(Color.dayflowInk)
                Text(countLine(endeavors: endeavors, items: items))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.dayflowMuted)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.dayflowFaint)
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.dayflowHairline).frame(height: 1)
        }
    }

    /// "1 trip · 1 flagged · 2 notes · 3 in Kit". Never a blank header: the
    /// line says what is behind the fold, which is what makes starting folded
    /// safe (a trip three days out is visible without opening anything).
    private func countLine(endeavors: [Endeavor], items: [DayflowInPlayItem]) -> String {
        var parts: [String] = []
        if !endeavors.isEmpty {
            let allTravel: Bool = endeavors.allSatisfy(\.isTravel)
            let noun: String = allTravel ? "trip" : "endeavor"
            parts.append("\(endeavors.count) \(noun)" + (endeavors.count == 1 ? "" : "s"))
        }
        let flagged: Int = items.filter { $0.kind == .task }.count
        let notes: Int = items.filter { $0.kind == .note }.count
        let kit: Int = items.filter { $0.kind == .document }.count
        if flagged > 0 { parts.append("\(flagged) flagged") }
        if notes > 0 { parts.append(notes == 1 ? "1 note" : "\(notes) notes") }
        if kit > 0 { parts.append("\(kit) in Kit") }
        return parts.joined(separator: " \u{00B7} ")
    }

    // MARK: Open

    private var header: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { expanded = false }
        } label: {
            HStack(alignment: .firstTextBaseline) {
                Text("IN PLAY")
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(2)
                    .foregroundStyle(Color.dayflowInk)
                Spacer()
                Image(systemName: "chevron.up")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.dayflowFaint)
            }
            .padding(.top, 10)
            .padding(.bottom, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func list(_ items: [DayflowInPlayItem]) -> some View {
        let shown: [DayflowInPlayItem] = showAll ? items : Array(items.prefix(Self.rowCap))
        let hidden: [DayflowInPlayItem] = showAll ? [] : Array(items.dropFirst(Self.rowCap))
        ForEach(shown) { item in
            row(item)
        }
        if !hidden.isEmpty {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showAll = true }
            } label: {
                Text(moreLine(hidden))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dayflowMuted)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .padding(.leading, 27)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func moreLine(_ hidden: [DayflowInPlayItem]) -> String {
        let names: String = hidden.prefix(2).map(\.title).joined(separator: ", ")
        return "\(hidden.count) more \u{00B7} " + names
    }

    private func row(_ item: DayflowInPlayItem) -> some View {
        let glyphColor: Color = item.kind == .task ? Color.dayflowAccent : Color.dayflowFaint
        return Button {
            open(item)
        } label: {
            HStack(spacing: 11) {
                Image(systemName: item.symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(glyphColor)
                    .frame(width: 16)
                Text(item.title)
                    .font(.dayflowSerif(15, weight: .regular))
                    .foregroundStyle(Color.dayflowInk)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                Text(item.trailing)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.dayflowFaint)
                    .lineLimit(1)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.dayflowHairline).frame(height: 1)
        }
    }

    private func open(_ item: DayflowInPlayItem) {
        switch item.kind {
        case .task:
            editingTask = taskStore.allTasks.first { $0.id == item.id }
        case .note:
            // The router every other note jump uses; the root picks the tab
            // (project notes open on Records, daily notes on Today).
            DayflowQuickFindRouter.shared.pendingDestination = .dailyOrProjectNote(item.id)
        case .document:
            guard let url = TraceSatchelHandoff.documentURL(path: item.id) else { return }
            openURL(url) { accepted in
                if !accepted { satchelUnavailable = true }
            }
        }
    }

    // MARK: Rows

    /// Flagged tasks, then pinned notes, then Kit. The Mac's order (D411):
    /// most fixed to least.
    private var rows: [DayflowInPlayItem] {
        var out: [DayflowInPlayItem] = []
        for task in taskStore.allTasks where task.flagged {
            out.append(DayflowInPlayItem(kind: .task, id: task.id, title: task.title,
                                         symbol: "flag.fill", trailing: Self.dueLabel(task.date)))
        }
        let pinned: [String] = pins.flaggedAt
            .sorted { $0.value < $1.value }
            .map(\.key)
        for path in pinned {
            let name: String = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            out.append(DayflowInPlayItem(kind: .note, id: path, title: name,
                                         symbol: "pin", trailing: "note"))
        }
        for doc in kitDocuments {
            out.append(DayflowInPlayItem(kind: .document, id: doc.relativePath, title: doc.title,
                                         symbol: doc.resolvedIcon.sfSymbol, trailing: "Kit"))
        }
        return out
    }

    /// Pins, then the active trip's documents: `KitWindow`, the same code
    /// Satchel's Kit and the Mac's rail run.
    private var kitDocuments: [TraceMacDocument] {
        let all: [TraceMacDocument] = documents.all
        var docs: [TraceMacDocument] = KitWindow.pinned(all)
        if let trip = KitWindow.activeTrip(in: endeavorStore.endeavors) {
            docs += KitWindow.tripDocuments(all, tripID: trip.id)
        }
        return docs
    }

    private static func dueLabel(_ date: Date?) -> String {
        guard let date else { return "" }
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInTomorrow(date) { return "Tomorrow" }
        return date.formatted(.dateTime.weekday(.abbreviated))
    }
}

struct DayflowInPlayItem: Identifiable {
    enum Kind { case task, note, document }
    let kind: Kind
    let id: String
    let title: String
    let symbol: String
    let trailing: String
}
