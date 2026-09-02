// TraceMacMeetingCard.swift
// A meeting row that opens where it lives, the same gesture as a task (D190).
// Mac-only — do not add to iOS, Widget, or Share Extension targets.
//
// Session 80 (2026-08-31). David: "clicking the calendar items do not open
// them up to see the detail yet."
//
// ── Same card, different contents ────────────────────────────────────────
//
// A task's card is an editor: every row is something you change. A meeting's
// is a briefing: where it is, who is on it, how to join, what the invitation
// said. The SHAPE is deliberately identical — click the row, it opens between
// its neighbours, click again or double-click the title to close — because the
// gesture is the vocabulary and the contents are the sentence.
//
// ── Read-only, deliberately ──────────────────────────────────────────────
//
// Nothing here writes to the event. An invitation belongs to whoever sent it,
// and a half-built event editor in a task app is worse than none: it would
// have to answer recurrence, attendee responses, invitation replies and
// timezones before it could be trusted with a single field. "Open in Calendar"
// hands the whole problem to the app that already solved it, and that is the
// right amount of ambition here.
//
// Composing a NEW event is a different matter and has its own design (D190,
// the compose rail) — placing something in a gap is a job Calendar does badly
// and this app does well.
//
// ── The type-checker ─────────────────────────────────────────────────────
//
// Typed `let`s before every modifier. See `feedback_typecheck_timeout`.

import SwiftUI
import AppKit

struct MacMeetingRow: View {

    let event: NextCalendarEvent
    let isOpen: Bool
    let onToggle: () -> Void
    /// Opens a place record in Directory. Defaulted, so a host that has no
    /// Directory to open says nothing and the link simply does not appear.
    var onOpenPlace: (String) -> Void = { _ in }

    @Environment(NotionService.self) private var notion
    @State private var picking = false
    /// Bumped when a link is made, so the WHERE row re-reads it. `PlaceLink`
    /// stores in `NSUbiquitousKeyValueStore` (D241, was `UserDefaults`), which
    /// SwiftUI does not observe.
    @State private var linkToken = 0
    /// When YOUR next meeting starts after this one ends — nil if this is the
    /// last of your day. Passed in because the answer depends on the whole day
    /// and a row cannot see the day.
    var nextOwnStart: Date? = nil

    // MARK: The agenda's four (D246)
    //
    // All four REQUIRED, unlike `onOpenPlace` above, and that is deliberate.
    // Session 80 lost six bugs to one shape — behaviour attached to the paths
    // that reach a thing rather than to the thing itself — and one of the six
    // was a defaulted closure nobody passed. A required parameter makes the
    // COMPILER do the call-site sweep. There are exactly two screens that build
    // a meeting row, so the cost of requiring them is two lines.

    /// Opens a daily or project note by container-relative path — the agenda's
    /// note rows.
    let onOpenNote: (String) -> Void
    /// The SCREEN's open task card, shared with its TO DO list rather than a
    /// second one of the agenda's own. Today's rule is at most one card open at
    /// a time, so opening a second closes the first; a task opened from an
    /// agenda is the same task, and two open-card universes would break that
    /// promise the first time one task appeared in both places.
    let agendaOpenTaskID: String?
    let onToggleAgendaTask: (ThingsTask) -> Void
    let onAgendaChanged: () -> Void

    /// Unfolded or not. Local `@State`, where iOS keeps a `Set` on the screen:
    /// the row's identity inside its `ForEach` is the event id, so this survives
    /// the host's reloads on its own.
    @State private var agendaExpanded = false
    /// Wikilink mentions, fetched once on first unfold. `nil` means NOT LOADED,
    /// which is exactly what `DayflowAgendaMatch.displayNotes` expects as its
    /// cache argument — it is not the same thing as "loaded and empty".
    @State private var agendaMentions: [NoteMention]? = nil
    @State private var agendaHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isOpen { card } else { collapsed }
            agenda
        }
    }

    // MARK: - Shared bits

    /// Foreign events take `MacEditorialColor.foreignEvent` and skip the
    /// classifier entirely (D193 amended): the colour says WHOSE meeting it is,
    /// which matters more than what kind it is when it is not yours to attend.
    private var isForeign: Bool {
        MacCalendarChoices.shared.isForeign(event.calendarIdentifier)
    }

    private var chipColor: Color {
        if isForeign { return MacEditorialColor.foreignEvent }
        let verdict = DayflowMeetingColor.classify(event.title, organizer: event.organizerName)
        return verdict.chip ?? MacEditorialColor.faint
    }

    private func clock(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f.string(from: d)
    }

    private static func span(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }

    private var durationText: String? {
        let minutes = Int(event.endDate.timeIntervalSince(event.startDate) / 60)
        guard minutes > 0 else { return nil }
        return "(\(Self.span(minutes)))"
    }

    /// The row's parenthetical is FREE TIME after this meeting, not its length.
    ///
    /// This went out and came back in one session, and the round trip is worth
    /// recording. D194 put the gap here; David then read "(10m)" on a 2h30
    /// Travel event and asked what had happened, so I moved it to a separate
    /// line between the rows. He rejected that: "no thats not right at all. i
    /// want free time not duration...i just didnt realize the math on the
    /// travel wrigley. And 10 minutes shouldnt show."
    ///
    /// So the placement was never the problem — the FLOOR was. A ten-minute
    /// seam is not free time in any useful sense, and printing it invited
    /// exactly the misreading it caused. At a 30-minute minimum every number
    /// that appears is a genuine window, and the case that confused him cannot
    /// arise. Duration lives in the card's WHEN row, which is where there is
    /// room to label it.
    ///
    /// Counted against HIS calendars only: a foreign meeting is context, not an
    /// appointment, and must never shorten the time he actually has.
    private static let freeTimeFloorMinutes = 30

    private var gapText: String? {
        guard !isForeign, let next = nextOwnStart else { return nil }
        let minutes = Int(next.timeIntervalSince(event.endDate) / 60)
        guard minutes >= Self.freeTimeFloorMinutes else { return nil }
        return "(\(Self.span(minutes)) free)"
    }


    // MARK: - Collapsed

    private var collapsed: some View {
        let tint: Color = chipColor
        let duration: String? = gapText
        return HStack(spacing: 10) {
            Text(clock(event.startDate))
                .font(MacEditorialType.time)
                .foregroundStyle(MacEditorialColor.muted)
                .frame(width: 66, alignment: .leading)
            Rectangle()
                .fill(tint)
                .frame(width: 8, height: 8)
            Text(event.title)
                .font(MacEditorialType.rowTitle)
                .foregroundStyle(MacEditorialColor.ink)
                .lineLimit(1)
            if let duration {
                Text(duration)
                    .font(MacEditorialType.meta)
                    .foregroundStyle(MacEditorialColor.faint)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 32)
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
    }

    // MARK: - AGENDA (D171-D176, on the Mac at last — D246)
    //
    // Option A of three, David's pick. The line lives UNDER the row with its own
    // fold, so the count is visible while you scan the day and the contents are
    // one click away without opening the meeting's briefing card. B (agenda as a
    // section inside the card) and C (count outside, contents inside) both lost
    // for the same reason: D171 says this screen is the prep sheet, and a prep
    // sheet you have to open a card to read is a filing cabinet.
    //
    // **It lives on the ROW, not on Today.** Today and Upcoming both draw this
    // type, so putting the agenda here is the same argument the iOS matcher's
    // own header makes ("extracted so the two can never drift"), one level up.
    // Building it on Today and porting it to Upcoming afterwards is how the
    // `rehab` filter got missed three times.
    //
    // Draw-time, like the phone: nothing cached, nothing written to the event.
    // The note check is a `FileManager.fileExists` per meeting per redraw, which
    // is what iOS has done since Session 78.

    /// The matched person or place, or the meeting's own title when nothing
    /// matches (D175 round two — the Brewers game still gets an agenda).
    private var agendaAnchor: String {
        DayflowAgendaMatch.agendaAnchor(forTitle: event.title)
    }

    @ViewBuilder
    private var agenda: some View {
        let anchor: String = agendaAnchor
        let tasks: [ThingsTask] = DayflowAgendaMatch.tasks(linkedTo: anchor)
        let notePath: String? = DayflowAgendaMatch.meetingNotePath(forTitle: event.title)
        // D176: the running note IS agenda by existence, so a task-less meeting
        // that has one still earns the line. Sarah's catch-up is the case.
        let count: Int = tasks.count + (notePath == nil ? 0 : 1)
        if count > 0 {
            agendaFold(count: count)
            if agendaExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(tasks) { task in
                        MacTaskRow(task: task,
                                   isOpen: agendaOpenTaskID == task.id,
                                   onToggle: { onToggleAgendaTask(task) },
                                   onChanged: onAgendaChanged,
                                   // Neither the day nor the list is implied
                                   // here: an agenda mixes lists and mixes dated
                                   // with undated, exactly like a document's
                                   // band. Same answer, same reason.
                                   trailing: .dateElseList)
                    }
                    agendaNoteRows
                }
                .padding(.leading, 28)
                .task { loadAgendaMentions(anchor) }
            }
        }
    }

    private func agendaFold(count: Int) -> some View {
        let glyph: String = agendaExpanded ? "chevron.up" : "chevron.down"
        // Quiet by default, a step darker under the pointer. Session 80, David
        // on the month grid's hover: a control that answers the pointer says it
        // is a control before you commit to clicking it, and everything in this
        // design is too quiet to say so any other way.
        let tint: Color = agendaHovering ? MacEditorialColor.muted : MacEditorialColor.faint
        return Button {
            withAnimation(.easeInOut(duration: 0.16)) { agendaExpanded.toggle() }
        } label: {
            HStack(spacing: 6) {
                // Clears the clock column (66) plus the row's spacing (10), so
                // AGENDA starts under the colour chip and not under the time.
                Spacer().frame(width: 76)
                Text("Agenda \u{00B7} \(count)")
                    .editorialQuietLabel()
                    .foregroundStyle(tint)
                Image(systemName: glyph)
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(tint)
                Spacer(minLength: 0)
            }
            .frame(height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { agendaHovering = $0 }
    }

    /// Notes under the tasks, with their own glyph. The meeting's own running
    /// note rides first (D176); the rest are wikilink mentions of the anchor.
    @ViewBuilder
    private var agendaNoteRows: some View {
        let mentions: [NoteMention] = DayflowAgendaMatch.displayNotes(cached: agendaMentions,
                                                                     forTitle: event.title)
        ForEach(mentions.prefix(4)) { mention in
            agendaNoteRow(mention)
        }
    }

    private func agendaNoteRow(_ mention: NoteMention) -> some View {
        // Calendar/ and Notes/Projects/ are the only two folders the Mac's note
        // screen can route (see MacSearchDestination.dailyOrProjectNote). A row
        // outside them still SHOWS — it is real context — but it does not
        // pretend to be a link.
        let openable: Bool = mention.relativePath.hasPrefix("Calendar/")
            || mention.relativePath.hasPrefix("Notes/Projects/")
        let tint: Color = openable ? MacEditorialColor.noteText : MacEditorialColor.faint
        return Button {
            guard openable else { return }
            onOpenNote(mention.relativePath)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "doc.text")
                    .font(.system(size: 11))
                    .foregroundStyle(MacEditorialColor.faint)
                    .frame(width: 18)
                Text(mention.title)
                    .font(MacEditorialType.meta)
                    .foregroundStyle(tint)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Same lazy once-per-unfold shape as iOS: the scan is a regex over every
    /// note, so it is not something to run on a redraw.
    private func loadAgendaMentions(_ anchor: String) {
        guard agendaMentions == nil else { return }
        Task { agendaMentions = NoteStore.shared.findWikilinkMentions(of: anchor) }
    }

    // MARK: - Expanded

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            fields
            notesBlock
            MacEditorialRule.hair
            footer
        }
        .padding(18)
        .background(MacEditorialColor.paper)
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(MacEditorialColor.hairline, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.10), radius: 12, y: 4)
        .padding(.vertical, 8)
        // A meeting card closes on Escape too. It was asked for on tasks, but
        // the two cards share a shape and a gesture on purpose (D190), and a
        // key that works on one of two identical-looking things is worse than
        // a key that works on neither.
        .escapeCloses { onToggle() }
    }

    private var header: some View {
        let tint: Color = chipColor
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Rectangle()
                .fill(tint)
                .frame(width: 8, height: 8)
            // A `Text`, not a field — see TraceMacTaskCard's `titleField` note.
            // Nothing here is editable, so the double-click is unopposed.
            Text(event.title)
                .font(MacEditorialType.subject)
                .foregroundStyle(MacEditorialColor.ink)
                .lineLimit(2)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { onToggle() }
            Spacer(minLength: 0)
            Button(action: onToggle) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(MacEditorialColor.faint)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Fields — only what the invitation actually carries

    @ViewBuilder
    private var fields: some View {
        VStack(alignment: .leading, spacing: 0) {
            MacEditorialRule.hair
            fieldRow("When") {
                Text(whenText)
                    .font(MacEditorialType.fieldValue)
                    .foregroundStyle(MacEditorialColor.ink)
            }
            if let place = trimmed(event.location) {
                MacEditorialRule.hair
                fieldRow("Where") { whereValue(place) }
            }
            if let link = joinLink {
                MacEditorialRule.hair
                fieldRow("Join") {
                    Button {
                        NSWorkspace.shared.open(link)
                    } label: {
                        Text(link.host ?? link.absoluteString)
                            .font(MacEditorialType.fieldValue)
                            .foregroundStyle(MacEditorialColor.accent)
                            .lineLimit(1)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            if !people.isEmpty {
                MacEditorialRule.hair
                fieldRow("With") {
                    Text(peopleText)
                        .font(MacEditorialType.fieldValue)
                        .foregroundStyle(MacEditorialColor.ink)
                        .lineLimit(3)
                }
            }
            MacEditorialRule.hair
            fieldRow("Calendar") {
                HStack(spacing: 6) {
                    Text(event.calendarTitle.isEmpty ? "Unknown" : event.calendarTitle)
                        .font(MacEditorialType.fieldValue)
                        .foregroundStyle(MacEditorialColor.ink)
                    if isForeign {
                        Text("not yours").editorialQuietLabel()
                    }
                }
            }
        }
        .padding(.leading, 18)
        .padding(.top, 12)
    }

    /// The WHERE row, in one of two states.
    ///
    /// **Unlinked:** the invitation's text, and a button to say what it means.
    /// **Linked:** the place's own name opening its record, and its address
    /// opening Maps — David: "make the address clickable as well as the place
    /// itself."
    ///
    /// The invitation's own words are kept underneath when they differ from the
    /// place name, because they sometimes carry the half the map does not know:
    /// a room, a floor, a door code. Dropping them in favour of a tidy record
    /// name would lose the only part that tells you where to walk.
    ///
    /// `_ = linkToken` is what ties this to the link being made. The store is
    /// `UserDefaults` and SwiftUI does not observe it, so without reading the
    /// counter the row would keep showing the button after a successful match.
    @ViewBuilder
    private func whereValue(_ location: String) -> some View {
        let _ = linkToken
        let linked: Place? = PlaceLink.place(for: location, in: notion.places)

        VStack(alignment: .leading, spacing: 3) {
            if let linked {
                Button { onOpenPlace(linked.id) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: placeIcon(for: linked.category))
                            .font(.system(size: 10))
                            .foregroundStyle(placeColor(for: linked.category))
                        Text(linked.name)
                            .font(MacEditorialType.fieldValue)
                            .foregroundStyle(MacEditorialColor.accent)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open in Directory")

                if !linked.address.isEmpty {
                    // `openMapsDirections` and not a new `openMapsPlace`.
                    // Directions were spelled four different ways in this
                    // project before PlaceHelpers consolidated them, and the
                    // address under a meeting is read by someone who has to
                    // get there.
                    Button { openMapsDirections(to: linked) } label: {
                        Text(linked.address)
                            .font(MacEditorialType.meta)
                            .foregroundStyle(MacEditorialColor.muted)
                            .lineLimit(2)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Directions")
                }

                // Kept only when it says something the record does not.
                if PlaceLink.normalise(location) != PlaceLink.normalise(linked.name) {
                    Text(location)
                        .font(MacEditorialType.meta)
                        .foregroundStyle(MacEditorialColor.faint)
                        .lineLimit(2)
                }
            } else {
                Text(location)
                    .font(MacEditorialType.fieldValue)
                    .foregroundStyle(MacEditorialColor.ink)
                    .lineLimit(2)
                Button { picking = true } label: {
                    Text("Match a place")
                        .font(MacEditorialType.meta)
                        .foregroundStyle(MacEditorialColor.accent)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .sheet(isPresented: $picking) {
            MacPlacePicker(location: location) { placeID in
                PlaceLink.link(location, to: placeID)
                linkToken += 1
            }
            .environment(notion)
        }
    }

    private func fieldRow<Content: View>(_ label: String,
                                         @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(label)
                .editorialFieldLabel()
                .frame(width: 74, alignment: .leading)
                .padding(.top, 9)
            content()
                .padding(.vertical, 7)
            Spacer(minLength: 0)
        }
        .frame(minHeight: 34)
    }

    @ViewBuilder
    private var notesBlock: some View {
        if let body = trimmed(event.notes) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Invitation").editorialFieldLabel()
                Text(body)
                    .font(MacEditorialType.fieldValue)
                    .foregroundStyle(MacEditorialColor.noteText)
                    .lineLimit(6)
                    .padding(.top, 6)
            }
            .padding(.leading, 18)
            .padding(.top, 14)
            .padding(.bottom, 4)
        }
    }

    private var footer: some View {
        HStack(spacing: 7) {
            MacEditorialPill(label: "Open in Calendar") { openInCalendar() }
            Spacer(minLength: 0)
        }
        .padding(.top, 14)
    }

    // MARK: - Values

    private var whenText: String {
        if event.isAllDay { return "All day" }
        let span = "\(clock(event.startDate)) \u{2013} \(clock(event.endDate))"
        guard let duration = durationText else { return span }
        return "\(span) \(duration)"
    }

    /// A conferencing add-on puts its link in `url` sometimes and buries it in
    /// the notes other times; `videoLink` is `CalendarService`'s own detector
    /// for the second case, so both are covered without a second scanner here.
    private var joinLink: URL? {
        event.url ?? event.videoLink
    }

    /// Organizer first when Exchange left them out of `attendees`, which it
    /// does — that gap is why `organizerName` exists as a separate field.
    private var people: [String] {
        var out: [String] = []
        if let organizer = trimmed(event.organizerName) { out.append(organizer) }
        for name in event.attendeeNames where !out.contains(name) { out.append(name) }
        return out
    }

    private var peopleText: String {
        let shown = people.prefix(8)
        let rest = people.count - shown.count
        let joined = shown.joined(separator: ", ")
        return rest > 0 ? "\(joined) and \(rest) more" : joined
    }

    private func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let out = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? nil : out
    }

    /// `ical://ekevent/<identifier>` is Calendar's own URL scheme for showing a
    /// single event. Falls back to opening Calendar on the right day when the
    /// identifier is missing, which beats doing nothing.
    private func openInCalendar() {
        if let id = event.eventIdentifier,
           let url = URL(string: "ical://ekevent/\(id)?method=show&options=more") {
            NSWorkspace.shared.open(url)
            return
        }
        if let url = URL(string: "ical://") {
            NSWorkspace.shared.open(url)
        }
    }
}
