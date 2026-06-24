import EventKit
import SwiftUI
import Observation

// MARK: - Model

struct NextCalendarEvent: Identifiable {
    var id: String { "\(startDate.timeIntervalSinceReferenceDate)-\(title)" }
    let title: String
    let startDate: Date
    let endDate: Date
    let calendarTitle: String
    let isAllDay: Bool
    let colorR: Double
    let colorG: Double
    let colorB: Double

    var color: Color { Color(red: colorR, green: colorG, blue: colorB) }

    var startTimeString: String {
        guard !isAllDay else { return "All day" }
        return DateFormatter.localizedString(from: startDate, dateStyle: .none, timeStyle: .short)
    }

    var timeLabel: String {
        guard startDate > Date() else { return "Now" }
        let mins = Int(startDate.timeIntervalSinceNow / 60)
        guard mins > 0 else { return "Now" }
        if mins < 60 { return "in \(mins)m" }
        let h = mins / 60; let m = mins % 60
        return m > 0 ? "in \(h)h \(m)m" : "in \(h)h"
    }

    var durationLabel: String {
        guard !isAllDay else { return "All day" }
        let mins = Int(endDate.timeIntervalSince(startDate) / 60)
        if mins < 60 { return "\(mins) min" }
        let h = mins / 60; let m = mins % 60
        return m > 0 ? "\(h)h \(m)m" : "\(h)h"
    }

    /// Label used in the "no events" empty state to show when the next event is.
    var nextEventLabel: String {
        let cal = Calendar.current
        let timeStr = startTimeString
        if cal.isDateInToday(startDate)    { return "Today · \(timeStr)" }
        if cal.isDateInTomorrow(startDate) { return "Tomorrow · \(timeStr)" }
        let f = DateFormatter(); f.dateFormat = "EEEE · h:mm a"
        return f.string(from: startDate)
    }
}

// MARK: - Service

@Observable
final class CalendarService {
    static let shared = CalendarService()
    private init() {}

    private let store = EKEventStore()

    // Title substrings that should never appear on the Home screen.
    // "travel to the office" is a phrase match — "travel" alone is intentionally NOT excluded
    // because David manages the travel team and has many legitimate travel-related events.
    private static let excludedPhrases: [String] = [
        "hold",
        "rehab",
        "blood",
        "travel to the office",
        "you're invited",
        "townhall"
    ]

    private func shouldExclude(title: String) -> Bool {
        let lower = title.lowercased()
        return Self.excludedPhrases.contains { lower.contains($0) }
    }

    /// Max events shown in the Home calendar section.
    private let maxEvents = 5

    /// Events within the next 18 hours (excluding all-day unless setting enabled).
    var upcomingEvents: [NextCalendarEvent] = []

    /// Next event beyond the 18-hour window — used for the empty-state "next up" hint.
    var nextEventBeyondWindow: NextCalendarEvent?

    var showAllDayEvents: Bool {
        UserDefaults.standard.bool(forKey: "cal_show_all_day")
    }

    private var hasAccess: Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(iOS 17, *) { return status == .fullAccess }
        return status == .authorized
    }

    func requestAndFetch() async {
        if !hasAccess {
            if #available(iOS 17, *) {
                _ = try? await store.requestFullAccessToEvents()
            } else {
                await withCheckedContinuation { cont in
                    store.requestAccess(to: .event) { _, _ in cont.resume() }
                }
            }
        }
        await fetchUpcomingEvents()
    }

    @MainActor
    func fetchUpcomingEvents() async {
        guard hasAccess else { return }
        let now = Date()
        let windowEnd = Calendar.current.date(byAdding: .hour, value: 18, to: now) ?? now

        let pred = store.predicateForEvents(withStart: now, end: windowEnd, calendars: nil)
        let events = store.events(matching: pred)
            .filter { showAllDayEvents || !$0.isAllDay }
            .filter { $0.status != .canceled }
            .filter { !shouldExclude(title: $0.title ?? "") }
            .sorted { $0.startDate < $1.startDate }

        upcomingEvents = Array(events.prefix(maxEvents)).map { makeEvent($0) }

        // If window is empty after filtering, peek up to 7 days ahead for the next event
        if upcomingEvents.isEmpty {
            let farEnd = Calendar.current.date(byAdding: .day, value: 7, to: now) ?? now
            let farPred = store.predicateForEvents(withStart: windowEnd, end: farEnd, calendars: nil)
            let farEvents = store.events(matching: farPred)
                .filter { showAllDayEvents || !$0.isAllDay }
                .filter { $0.status != .canceled }
                .filter { !shouldExclude(title: $0.title ?? "") }
                .sorted { $0.startDate < $1.startDate }
            nextEventBeyondWindow = farEvents.first.map { makeEvent($0) }
        } else {
            nextEventBeyondWindow = nil
        }
    }

    private func makeEvent(_ ev: EKEvent) -> NextCalendarEvent {
        let comps = ev.calendar?.cgColor?.components ?? [0.22, 0.36, 0.93, 1.0]
        return NextCalendarEvent(
            title: ev.title ?? "Event",
            startDate: ev.startDate,
            endDate: ev.endDate,
            calendarTitle: ev.calendar?.title ?? "",
            isAllDay: ev.isAllDay,
            colorR: comps.count > 0 ? Double(comps[0]) : 0.22,
            colorG: comps.count > 1 ? Double(comps[1]) : 0.36,
            colorB: comps.count > 2 ? Double(comps[2]) : 0.93
        )
    }
}
