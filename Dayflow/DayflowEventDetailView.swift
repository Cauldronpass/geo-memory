import SwiftUI

// MARK: - DayflowEventDetailView
//
// Read-only drill-in for a calendar event — the last item from the Session 19
// documentation-pass backlog, built Session 23 (2026-07-21). Reached by
// tapping an event row in the Agenda card (DayflowAgendaSection.swift),
// Browse: Upcoming (DayflowUpcomingView.swift), or Browse: Search
// (DayflowAgendaSearchView.swift) — all three previously had this exact
// comment: "no edit path exists for EventKit events in this build, so the tap
// is a no-op." Same CRM-light-style precedent as DayflowVisitDetailView.swift
// (Session 20): presentation only, no edit path. David's explicit call when
// asked read-only-vs-editable: read-only — real EventKit write support for an
// EXISTING event means handling recurring-event edit scope ("this event" vs.
// "all future events") and a real form UI, meaningfully bigger than what was
// asked for this round.
//
// Needed `NextCalendarEvent` (CalendarService.swift) widened first — it only
// carried title/startDate/endDate/calendarTitle/isAllDay/color before this,
// not enough to build a detail view from. `makeEvent(_:)` there now also
// reads `location`/`notes`/`url`/`attendeeNames`/`eventIdentifier` off the
// underlying EKEvent.
//
// David's ask, verbatim: "all the details of the meeting available like the
// notes and the link to the video as well as the attendees." `videoLink`
// (computed on `NextCalendarEvent`, see that file) is a best-effort join-link
// detector — checks `EKEvent.url` first, then scans `location`/`notes` text
// for the first `http(s)` URL, since conferencing add-ons (Zoom, Meet, Teams)
// don't agree on which field they populate. Surfaced as its own prominent
// tappable "Join" row when found; full location/notes text is still shown
// below regardless, so nothing's hidden even when the detector guesses wrong
// or finds nothing.
//
// **Attendees fix, same day.** David found the Attendees section missing
// entirely on a real Teams-meeting event with a known organizer and
// invitee — `EKParticipant.name` is frequently nil on Exchange/Office
// 365-synced calendars, and the original `hasAttendees` pre-check in
// `CalendarService.makeEvent(_:)` was itself unreliable for that event (came
// back false despite real attendee data existing). Fixed at the source: that
// gate was dropped, name resolution now falls back to the participant's
// `mailto:` address when `.name` is nil, and the organizer is captured
// separately (`organizerName`) since some providers omit the organizer from
// `.attendees` entirely. See `otherAttendees`/`attendeeSectionCount` below —
// the organizer is shown once, labeled, never duplicated into the plain list.

struct DayflowEventDetailView: View {
    let event: NextCalendarEvent

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private var timeRangeLabel: String {
        guard !event.isAllDay else { return "All day" }
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return "\(f.string(from: event.startDate)) \u{2013} \(f.string(from: event.endDate))"
    }

    /// `attendeeNames` as returned by CalendarService can include the
    /// organizer again as a plain attendee (provider-dependent — some
    /// include them, some don't) — filtered out here so they're never shown
    /// twice, once as "Organizer" and again in the plain list below it.
    private var otherAttendees: [String] {
        guard let organizer = event.organizerName else { return event.attendeeNames }
        return event.attendeeNames.filter { $0.caseInsensitiveCompare(organizer) != .orderedSame }
    }

    private var attendeeSectionCount: Int {
        (event.organizerName != nil ? 1 : 0) + otherAttendees.count
    }

    var body: some View {
        List {
            Section {
                HStack(alignment: .top, spacing: 8) {
                    Circle().fill(event.color).frame(width: 10, height: 10).padding(.top, 5)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.title).font(.headline)
                        if !event.calendarTitle.isEmpty {
                            Text(event.calendarTitle).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 2)

                LabeledContent("Date", value: event.startDate.formatted(.dateTime.month(.wide).day().year()))
                LabeledContent("Time", value: timeRangeLabel)

                if let location = event.location, !location.isEmpty {
                    LabeledContent("Location", value: location)
                }
            }

            // Deliberately its own section, above Notes — the one field
            // David specifically called out ("the link to the video").
            if let videoLink = event.videoLink {
                Section {
                    Button {
                        openURL(videoLink)
                    } label: {
                        HStack {
                            Image(systemName: "video.fill")
                            Text("Join")
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.dayflowAccent)
                }
            }

            if event.organizerName != nil || !event.attendeeNames.isEmpty {
                Section("Attendees (\(attendeeSectionCount))") {
                    if let organizer = event.organizerName {
                        HStack {
                            Text(organizer)
                            Spacer()
                            Text("Organizer").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(otherAttendees, id: \.self) { name in
                        Text(name)
                    }
                }
            }

            if let notes = event.notes, !notes.isEmpty {
                Section("Notes") { Text(notes) }
            }
        }
        .navigationTitle("Event")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
    }
}
