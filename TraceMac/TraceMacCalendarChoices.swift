// TraceMacCalendarChoices.swift
// Which calendars the Mac's day views read.
// Mac-only — do not add to iOS, Widget, or Share Extension targets.
//
// Session 80 (2026-08-31). David: "The app has multiple calendars being used.
// I would like to be able to turn on and off certain ones. My wife's calendar
// is currently showing in addition to mine which is not what i want."
//
// ── There is no new plumbing here, and that is the point ─────────────────
//
// `CalendarService.includedCalendarsForDayflow()` already reads a
// comma-separated list of `EKCalendar.calendarIdentifier`s from
// `dayflow_included_calendar_ids` in `UserDefaults.standard`, and already
// treats an EMPTY value as "no filter — show everything", so nobody's day goes
// silently blank because they never opened Settings. This file is the Mac's
// way of writing that key. Nothing in the service changed.
//
// **`UserDefaults.standard` is scoped per bundle ID**, and TraceMac's is
// `com.david.Trace.TraceMac` — a different domain from Dayflow's
// `com.david.Dayflow`. So turning a calendar off here turns it off on the Mac
// ONLY. The phone keeps whatever it had. That is the right default for a
// preference about a screen's contents rather than about the data, and if he
// later wants them to agree the fix is to move the key to the shared App Group
// suite deliberately, not to discover they were shared by accident.
//
// The key keeps its `dayflow_` name. Renaming it would mean editing the shared
// service and breaking Dayflow's saved setting to make a string prettier.

import SwiftUI
import EventKit

@MainActor
@Observable
final class MacCalendarChoices {

    static let shared = MacCalendarChoices()

    static let defaultsKey = "dayflow_included_calendar_ids"

    private let store = EKEventStore()

    /// Every event calendar EventKit can see, source first so a household
    /// account's calendars sit together.
    private(set) var calendars: [EKCalendar] = []

    /// Identifiers currently switched ON. Empty means "not configured", which
    /// the service reads as everything — so the UI shows all of them ticked
    /// rather than none, which is what is actually true on screen.
    private(set) var included: Set<String> = []

    /// Calendars that belong to somebody else (D193). A shown-but-not-mine
    /// calendar is a real third state: David wants his wife's events visible
    /// on his day without them reading as HIS meetings, and without them
    /// borrowing a colour from a system where colour means a category of
    /// work. Stored separately from `included` because the two questions are
    /// independent — you can hide a calendar of your own, and show one that
    /// is not.
    private(set) var foreign: Set<String> = []

    static let foreignKey = "tracemac.foreign_calendar_ids"

    private init() {}

    func load() async {
        guard await ensureAccess() else { return }
        calendars = store.calendars(for: .event)
            .sorted { lhs, rhs in
                let lSource = lhs.source?.title ?? ""
                let rSource = rhs.source?.title ?? ""
                if lSource != rSource { return lSource < rSource }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
        let raw = UserDefaults.standard.string(forKey: Self.defaultsKey) ?? ""
        if raw.isEmpty {
            included = Set(calendars.map(\.calendarIdentifier))
        } else {
            included = Set(raw.split(separator: ",").map(String.init))
        }
        let rawForeign = UserDefaults.standard.string(forKey: Self.foreignKey) ?? ""
        foreign = Set(rawForeign.split(separator: ",").map(String.init))
    }

    /// Whether an event's calendar has been flagged as somebody else's.
    /// Identifier, never title — titles get renamed.
    func isForeign(_ calendarIdentifier: String) -> Bool {
        guard !calendarIdentifier.isEmpty else { return false }
        return foreign.contains(calendarIdentifier)
    }


    /// The three states a calendar can be in, as David actually thinks about
    /// them. Session 80: the first cut exposed the two stored sets as two
    /// separate controls — a switch and a link — and he read the switch as the
    /// only one, hid his wife's calendar, and lost the events he wanted to
    /// keep. Two booleans in the model do not have to be two controls on
    /// screen, and here they must not be: the states are mutually exclusive,
    /// so they are one picker.
    enum Mode: String, CaseIterable, Identifiable {
        case hidden
        case mine
        case theirs
        var id: String { rawValue }
        var label: String {
            switch self {
            case .hidden: return "Hidden"
            case .mine:   return "Mine"
            case .theirs: return "Theirs"
            }
        }
    }

    func mode(_ calendar: EKCalendar) -> Mode {
        let id = calendar.calendarIdentifier
        guard included.contains(id) else { return .hidden }
        return foreign.contains(id) ? .theirs : .mine
    }

    func setMode(_ mode: Mode, for calendar: EKCalendar) {
        let id = calendar.calendarIdentifier
        switch mode {
        case .hidden:
            included.remove(id)
        case .mine:
            included.insert(id)
            foreign.remove(id)
        case .theirs:
            included.insert(id)
            foreign.insert(id)
        }
        persist()
    }

    private func persist() {
        // "Everything shown" is stored as an EMPTY string rather than the full
        // list, so a calendar added later appears by itself instead of being
        // invisible until he remembers to come back here.
        let all = Set(calendars.map(\.calendarIdentifier))
        let rawIncluded: String = (included == all) ? "" : included.sorted().joined(separator: ",")
        UserDefaults.standard.set(rawIncluded, forKey: Self.defaultsKey)
        UserDefaults.standard.set(foreign.sorted().joined(separator: ","),
                                  forKey: Self.foreignKey)
    }

    func isOn(_ calendar: EKCalendar) -> Bool {
        included.contains(calendar.calendarIdentifier)
    }

    // `toggle(_:)` and `toggleForeign(_:)` retired, Session 80 — both are
    // `setMode(_:for:)` now, because the UI that needed two of them was the
    // UI that lost David his daycare calendar.


    private func ensureAccess() async -> Bool {
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess { return true }
        return (try? await store.requestFullAccessToEvents()) ?? false
    }
}

// MARK: - Settings section

struct MacCalendarChoicesSection: View {

    @State private var choices = MacCalendarChoices.shared

    var body: some View {
        Section("Calendars") {
            if choices.calendars.isEmpty {
                Text("No calendars visible yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(choices.calendars, id: \.calendarIdentifier) { calendar in
                    row(calendar)
                }
                Text("Hidden keeps a calendar out of the day entirely. Theirs still shows every event, in baby blue, so it never reads as one of yours. Showing everything stores no filter, so a calendar you add later appears on its own \u{2014} and this is a Mac-only setting; the phone keeps its own.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task { await choices.load() }
    }

    /// One row, ONE control. Hidden / Mine / Theirs, segmented, because the
    /// three are mutually exclusive and a person choosing between them should
    /// not have to work out that two separate widgets combine into three
    /// states.
    ///
    /// The previous version put a `Button` inside a `Toggle`'s label. On macOS
    /// the toggle swallows that click, so the second control was effectively
    /// invisible — David hid a calendar he wanted to keep and had no way to
    /// reach the state he was actually after. Do not nest interactive views in
    /// a `Toggle` label here or anywhere else.
    private func row(_ calendar: EKCalendar) -> some View {
        let source: String = calendar.source?.title ?? ""
        let current: MacCalendarChoices.Mode = choices.mode(calendar)
        let binding = Binding<MacCalendarChoices.Mode>(
            get: { current },
            set: { choices.setMode($0, for: calendar) }
        )
        return HStack(spacing: 10) {
            Circle()
                .fill(Color(nsColor: calendar.color ?? .gray))
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(calendar.title)
                if !source.isEmpty {
                    Text(source)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 16)
            Picker("", selection: binding) {
                ForEach(MacCalendarChoices.Mode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .padding(.vertical, 2)
    }
}
