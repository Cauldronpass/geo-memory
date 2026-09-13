//  SatchelTaskCard.swift
//  Satchel
//
//  Make a task out of a document, from the library row, without opening it.
//
//  **The link is the reason this exists, and it was already built.** A task
//  carries `satchel:doc:<relativePath>` in its notes (D227) and both Satchel's
//  document panel and the Mac read it. This card writes the same marker the
//  panel's compose row writes; it adds no second record and touches neither the
//  document nor its sidecar.
//
//  **Same grammar as Dayflow's task card (D368), not the same code.** That one
//  is a Shortcuts snippet: every control is a `Button(intent:)` handing state to
//  a shared draft, because a snippet has no continuous view to hold it. In an app
//  a button is a button, so this is the same three decisions in Satchel's dress
//  and about a quarter of the size.
//
//  **Three lists, and Work is deliberately absent (D382).** Dayflow offers a
//  fourth that posts to Todoist and never touches Reminders. Here that would be
//  a task carrying a link back to a document, created from that document, and
//  then invisible in that document's own panel, which filters Reminders. The one
//  screen built to show the task would show nothing, having just made one.
//  David: *"I wouldnt send a document to work task."*
//
//  **The words are NOT read for a date, unlike Dayflow's card.** `TaskLineParser`
//  is not in Satchel's target and adding it means editing `project.pbxproj`,
//  this project's riskiest move, needing Xcode quit. Dayflow needs the parser
//  because Siri can create a task there with no card on screen. Here the date
//  chips are already under his thumb.

import SwiftUI
import UIKit

struct SatchelTaskCard: View {

    let document: TraceMacDocument

    @Environment(\.dismiss) private var dismiss
    @FocusState private var titleFocused: Bool

    @State private var title = ""
    @State private var destination: Destination = .inbox
    @State private var when: When = .anytime
    @State private var pickedDate = Calendar.current.startOfDay(for: Date())
    @State private var showingPicker = false
    @State private var correction: String?
    @State private var failure: String?
    @State private var saving = false

    private var store: ReminderTaskStore { ReminderTaskStore.shared }

    // MARK: - What is being captured

    enum Destination: String, CaseIterable, Identifiable {
        case inbox, personal, financial
        var id: String { rawValue }

        var label: String {
            switch self {
            case .inbox:     return "Inbox"
            case .personal:  return "Personal"
            case .financial: return "Financial"
            }
        }

        var listName: String {
            switch self {
            case .inbox:     return ReminderTaskStore.inboxListName
            case .personal:  return ReminderTaskStore.personalListName
            case .financial: return "Financial"
            }
        }
    }

    enum When: Equatable {
        case anytime, today, tomorrow, on(Date)

        var isDated: Bool { self != .anytime }

        func label(_ picked: Date) -> String {
            switch self {
            case .anytime:  return "Anytime"
            case .today:    return "Today"
            case .tomorrow: return "Tomorrow"
            case .on:       return Self.stamp(picked)
            }
        }

        func date(_ picked: Date) -> Date? {
            let cal = Calendar.current
            switch self {
            case .anytime:  return nil
            case .today:    return cal.startOfDay(for: Date())
            case .tomorrow: return cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date()))
            case .on:       return cal.startOfDay(for: picked)
            }
        }

        static func stamp(_ date: Date) -> String {
            let cal = Calendar.current
            let f = DateFormatter()
            f.dateFormat = cal.isDate(date, equalTo: Date(), toGranularity: .year) ? "MMM d" : "MMM d yyyy"
            return f.string(from: date)
        }
    }

    // MARK: - The one rule this card teaches

    /// **Inbox holds no dates** (D210/D262), so dating a task while Inbox is lit
    /// moves it to Personal. The store already does this on the way in; doing it
    /// here as well, visibly, is the difference between a rule learned once and a
    /// task found later in a list he did not choose. Straight from Dayflow's
    /// `applyRules`, minus the Todoist half, which has no control here to break.
    private func applyRules() {
        if when.isDated, ReminderTaskStore.listRefusesDates(destination.listName) {
            let was = destination.label
            destination = .personal
            correction = "\(was) holds no dates, so this moved to Personal."
        }
    }

    /// What the card claims will happen, in the words it will happen in.
    private var destinationLine: String {
        when.isDated
            ? "Goes to \(destination.label), \(when.label(pickedDate).lowercased())."
            : "Goes to \(destination.label), no date."
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isOnDate: Bool { if case .on = when { return true } else { return false } }

    private var datedChipLabel: String { isOnDate ? When.stamp(pickedDate) : "Pick a date" }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    documentHeader
                    titleField
                    chipBlock("List") {
                        ForEach(Destination.allCases) { option in
                            chip(option.label, selected: destination == option) {
                                destination = option
                                correction = nil
                                applyRules()
                            }
                        }
                    }
                    chipBlock("When") {
                        chip("Anytime", selected: when == .anytime) {
                            when = .anytime; showingPicker = false; correction = nil
                        }
                        chip("Today", selected: when == .today) {
                            when = .today; showingPicker = false; applyRules()
                        }
                        chip("Tomorrow", selected: when == .tomorrow) {
                            when = .tomorrow; showingPicker = false; applyRules()
                        }
                        chip(datedChipLabel, selected: isOnDate) {
                            when = .on(pickedDate)
                            showingPicker.toggle()
                            applyRules()
                        }
                    }
                    if showingPicker {
                        DatePicker("", selection: $pickedDate, displayedComponents: .date)
                            .datePickerStyle(.graphical)
                            .labelsHidden()
                            .onChange(of: pickedDate) { _, _ in
                                when = .on(pickedDate)
                                applyRules()
                            }
                            .padding(.horizontal, 4)
                    }
                    statusLines
                }
                .padding(.horizontal, 18)
                .padding(.top, 6)
                .padding(.bottom, 28)
            }
            .satchelBackground()
            .navigationTitle("New task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Adding" : "Add") { Task { await save() } }
                        .fontWeight(.semibold)
                        .disabled(trimmedTitle.isEmpty || saving)
                }
            }
        }
        .onAppear {
            // The document's title is the obvious first draft of the task's, and
            // it is offered rather than assumed: "Cook County Property Tax Payment
            // Receipt" is a fine task name and a poor one depending on the errand.
            // Empty would make him retype what is already on the screen he swiped.
            if title.isEmpty { title = document.title }
            titleFocused = true
        }
    }

    // MARK: - Pieces

    /// The document this will point at, shown because the link is the whole
    /// reason the card exists and an unnamed link is a promise he cannot check.
    private var documentHeader: some View {
        HStack(spacing: 11) {
            SatchelDocumentMark(icon: document.resolvedIcon,
                                tint: document.resolvedTint,
                                size: 34, cornerRadius: 10, glyphSize: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text("Linked to")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.satchelTertiary)
                Text(document.title)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Color.satchelInk)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .satchelCard()
    }

    private var titleField: some View {
        TextField("What needs doing", text: $title, axis: .vertical)
            .font(.system(size: 15))
            .lineLimit(1...3)
            .focused($titleFocused)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .satchelCard()
    }

    /// Chips scroll sideways rather than wrapping. Four When chips do not fit a
    /// phone width once one of them is showing a date, and a row that wraps
    /// changes height as he taps, which moves everything under it.
    @ViewBuilder
    private func chipBlock<Content: View>(_ label: String,
                                          @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label.uppercased())
                .font(.system(size: 11, weight: .bold))
                .kerning(0.4)
                .foregroundStyle(Color.satchelTertiary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) { content() }
                    .padding(.vertical, 1)
            }
        }
    }

    private func chip(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            Text(label)
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.white : Color.satchelInk)
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
                .background(selected ? Color.satchelBlue : Color.satchelHairline.opacity(0.45),
                            in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var statusLines: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(destinationLine)
                .font(.system(size: 12.5))
                .foregroundStyle(Color.satchelSecondary)
            if let correction {
                Text(correction)
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
            }
            if let failure {
                Text(failure)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.satchelPin)
            }
        }
    }

    // MARK: - Writing

    private func save() async {
        let name = trimmedTitle
        guard !name.isEmpty else { return }
        failure = nil
        saving = true
        defer { saving = false }

        let id = await store.addTaskReturningID(
            title: name,
            date: when.date(pickedDate),
            list: destination.listName,
            notes: ThingsTask.documentMarkerPrefix + document.relativePath
        )
        guard id != nil else {
            failure = store.lastError ?? "Could not add the task. Check Reminders access in iOS Settings."
            return
        }
        // **Refreshed here, or the document's own panel shows nothing.**
        // `allTasks` is a cached array that only `fetch()` repopulates, so a task
        // written and not refetched is a successful write with no screen to show
        // for it. Same shape as the Session 98 tick-key mismatch.
        await store.refreshAll()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        dismiss()
    }
}
