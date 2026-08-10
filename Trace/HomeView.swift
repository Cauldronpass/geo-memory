import SwiftUI
import CoreLocation
import Combine

// MARK: - HomeView
//
// Session 48 (Trace redesign) — full rebuild per Session 47 addendum's locked
// mockup (trace-redesign-mockup-v7.html, "Home" frame). Removed entirely per
// that addendum: the time-of-day greeting theme, the Oura widget, Apple Watch
// Activity Rings, the Things integration, the Horizons week/month note
// helpers, and the second Calendar/Daily-note pass (Notes > Daily already
// owns that data). Also dropped, following the mockup itself rather than the
// addendum prose (the mockup is the source of truth per the Session 48
// starter prompt): the "Next Up" calendar-events card and the
// nearby-geofenced-place card — neither appears anywhere in v7's Home frame.
//
// The FAB is no longer owned by this view — ContentView.swift now shows its
// existing global quick-capture menu on every tab including Home (previously
// Home had no FAB at all). The mockup's own sketch of a dedicated
// tap-for-text/hold-for-voice natural-language capture FAB is NOT built here:
// Session 47's addendum explicitly flags that parsing approach as an
// undecided open question "for whenever this gets built."
//
// Session 48 follow-up (same day, after David used the first build) —
// reworked per his direct feedback:
//   - Recent was one long merged Visits+Interactions feed and monopolized the
//     screen; it's now two short side-by-side lists (Visits, Interactions),
//     each capped at 5 with a chevron/"See All" that opens the existing full
//     screen for that type (VisitsView as a sheet, matching how PlacesView
//     already presents it; PeopleView's Interactions segment as a sheet).
//     The 30-day back-window is gone — capping by count made it redundant.
//   - Coming Up's "N people have something queued" row was a bug, not just a
//     thin design: it only ever opened agendaPeople.first regardless of N.
//     Now each queued person is its own row (mirroring how birthdays already
//     render), with a one-line preview of their first agenda item instead of
//     just a name list.
//   - This Week's tiles are now tappable (jump straight to Fitness/Billiards)
//     and each gained a lifetime line — Orange Theory's total class count,
//     Billiards' overall 8-Ball/9-Ball win-loss record (reusing the same
//     format/result filter BilliardsView.swift already computes). The
//     separate Jump To grid is removed — redundant now that the tiles
//     themselves are the jump targets, and it frees vertical space.
//   - Dropped the "placement TBD" caption from the stat tiles — now that
//     they're tappable and clearly placed/usable, it read as clutter rather
//     than a real open question. The underlying question (do Fitness/
//     Billiards deserve their own tab someday) is unchanged and still live,
//     just not restated in the UI itself.
//
// All styling routes through TraceSkin.

struct HomeView: View {
    @Environment(NotionService.self) private var notion
    @Environment(\.openURL) private var openURL
    @Environment(LocationManager.self) private var locationManager

    private enum HomeSegment: String, CaseIterable { case recent = "Recent", comingUp = "Coming Up" }

    @State private var homeSegment: HomeSegment = .recent
    @State private var selectedVisit: Visit? = nil
    @State private var selectedPerson: Person? = nil
    /// Session 48 follow-up — which tab selectedPerson's sheet should open to.
    /// Birthday rows leave this false (default Info tab); Coming Up's agenda
    /// rows set it true first so the sheet lands on the person's Log tab
    /// (Agenda + Interactions) instead of the top of their card.
    @State private var openPersonToAgenda = false
    /// Session 48 follow-up — tapping a Recent > Interactions row now opens
    /// the interaction itself (InteractionDetailSheet, promoted to internal
    /// visibility in PersonDetailView.swift for this) rather than the whole
    /// person's card, per David's request.
    @State private var selectedInteraction: Interaction? = nil
    @State private var navigateToFitness = false
    @State private var navigateToBilliards = false
    @State private var showingAllVisits = false
    @State private var showingAllInteractions = false

    private var cal: Calendar { Calendar.current }

    // MARK: - Recent — Visits and Interactions, each its own short list

    private var recentVisits: [Visit] {
        notion.visits.sorted { $0.date > $1.date }
    }

    private var recentInteractionsList: [Interaction] {
        notion.recentInteractions.sorted { $0.date > $1.date }
    }

    private func person(for interaction: Interaction) -> Person? {
        interaction.personIDs.compactMap { id in notion.people.first { $0.id == id } }.first
    }

    // MARK: - Coming Up — birthdays + agenda-queued people, ~30 days forward

    private struct UpcomingBirthday: Identifiable {
        let person: Person
        let nextOccurrence: Date
        var id: String { person.id }
        var daysAway: Int {
            Calendar.current.dateComponents(
                [.day],
                from: Calendar.current.startOfDay(for: Date()),
                to: nextOccurrence
            ).day ?? 0
        }
    }

    /// Next occurrence of each person's birthday (month/day only — the stored
    /// year is whatever Notion has on file, not meaningful here), rolled
    /// forward a year if this year's date has already passed. Capped to a
    /// ~30-day forward window.
    private var upcomingBirthdays: [UpcomingBirthday] {
        let today = cal.startOfDay(for: Date())
        return notion.people.compactMap { person -> UpcomingBirthday? in
            guard let birthday = person.birthday else { return nil }
            var comps = cal.dateComponents([.month, .day], from: birthday)
            comps.year = cal.component(.year, from: today)
            guard let thisYear = cal.date(from: comps) else { return nil }
            var next = thisYear
            if next < today {
                comps.year = (comps.year ?? 0) + 1
                guard let nextYear = cal.date(from: comps) else { return nil }
                next = nextYear
            }
            return UpcomingBirthday(person: person, nextOccurrence: next)
        }
        .filter { $0.daysAway <= 30 }
        .sorted { $0.nextOccurrence < $1.nextOccurrence }
    }

    /// Every DATED agenda item across everyone, inside the horizon, overdue
    /// included. Undated items are absent on purpose — see `AgendaLine`.
    private var agendaEntries: [(person: Person, item: AgendaItem)] {
        notion.people.flatMap { person in
            AgendaLine.comingUp(from: person.agenda).map { (person: person, item: $0) }
        }
    }

    /// Birthdays and agenda items in ONE date-sorted list.
    ///
    /// They used to be two blocks, birthdays above everyone-with-anything-queued.
    /// That made the card impossible to read as a sequence: a birthday twenty-nine
    /// days out sat above something due tomorrow. Both carry a real date now, so
    /// there is no reason to keep them apart.
    private enum ComingUpEntry: Identifiable {
        case birthday(UpcomingBirthday)
        case agenda(person: Person, item: AgendaItem)
        case document(TraceMacDocument)

        var id: String {
            switch self {
            case .birthday(let b):      return "b-\(b.id)"
            case .agenda(let p, let i): return "a-\(p.id)-\(i.raw)"
            case .document(let d):      return "d-\(d.relativePath)"
            }
        }
        var date: Date {
            switch self {
            case .birthday(let b):   return b.nextOccurrence
            case .agenda(_, let i):  return i.due ?? .distantFuture
            case .document(let d):   return d.remindOn ?? .distantFuture
            }
        }
    }

    /// Satchel documents with a `remind:` date. David, 2026-08-01, on wanting one
    /// place to look: Trace already compiles the document store, so this costs a
    /// read of something already loaded rather than a new dependency.
    ///
    /// **No horizon on the far side.** A birthday eleven months out is noise; a
    /// document dated eleven months out is a passport expiring, and dropping it
    /// off the list is how you find out too late.
    private var documentEntries: [TraceMacDocument] {
        // Observation reaches through: `TraceSatchelChipStore` is @Observable but
        // holds its store in a `let`, so IT never notifies — the tracking comes
        // from `iOSDocumentStore.documents`, which is @Observable and mutated by
        // `reload()`. Reading it from a body registers on that inner object, so
        // Home refreshes when the sweep finishes. Worth stating, because a `let`
        // on an @Observable class looks like it would break this and does not.
        TraceSatchelChipStore.shared.dated
    }

    private var allEntries: [ComingUpEntry] {
        (upcomingBirthdays.map { ComingUpEntry.birthday($0) }
         + agendaEntries.map { ComingUpEntry.agenda(person: $0.person, item: $0.item) }
         + documentEntries.map { ComingUpEntry.document($0) })
            .sorted { $0.date < $1.date }
    }

    /// SPLIT, NOT JUST SORTED. David: *"wouldnt having past due also be a view?"*
    ///
    /// Overdue at the top of one list is a sort; a heading is a state. With three
    /// sources feeding this card the difference stops being cosmetic — "two things
    /// are late" is a different sentence from "here is your month, and the first
    /// two happen to be behind you".
    private var pastDueEntries: [ComingUpEntry] {
        allEntries.filter { cal.startOfDay(for: $0.date) < cal.startOfDay(for: Date()) }
    }
    private var upcomingEntries: [ComingUpEntry] {
        allEntries.filter { cal.startOfDay(for: $0.date) >= cal.startOfDay(for: Date()) }
    }
    private var comingUpEntries: [ComingUpEntry] { allEntries }

    /// "Overdue by 4 days" / "Today" / "In 13 days · 14 Aug".
    private func whenLabel(_ days: Int, on date: Date) -> String {
        let stamp = date.formatted(.dateTime.month(.abbreviated).day())
        if days < 0 { return "Overdue by \(-days) day\(days == -1 ? "" : "s") · \(stamp)" }
        if days == 0 { return "Today · \(stamp)" }
        return "In \(days) day\(days == 1 ? "" : "s") · \(stamp)"
    }

    /// Ticking an item deletes its line and saves. There is no done state: the
    /// record of having spoken to someone is the interaction log, not a checked
    /// box on a prompt to speak to them.
    private func completeAgendaItem(_ person: Person, _ item: AgendaItem) {
        let remaining = AgendaLine.items(from: person.agenda).filter { $0.raw != item.raw }
        // Kept, not dropped. See `NoteStore.logCompletedAgendaItem` — the live
        // queue is a Notion field with a size limit; the history is his note.
        NoteStore.shared.logCompletedAgendaItem(person: person.name, text: item.text)
        Task {
            try? await notion.updatePersonAgenda(id: person.id,
                                                 agenda: AgendaLine.joined(remaining))
            await ReminderService.complete(key: "\(person.id)|\(item.raw)")
        }
    }

    // MARK: - This Week stats

    private var thisWeekRange: Range<Date>? {
        cal.dateInterval(of: .weekOfYear, for: Date()).map { $0.start..<$0.end }
    }

    private var thisWeekOTWorkouts: [Workout] {
        guard let range = thisWeekRange else { return [] }
        return notion.workouts.filter { $0.isOTF && range.contains($0.date) }.sorted { $0.date > $1.date }
    }

    private var thisWeekBilliards: [BilliardsSession] {
        guard let range = thisWeekRange else { return [] }
        return notion.billiardsSessions.filter { range.contains($0.date) }.sorted { $0.date > $1.date }
    }

    private var lifetimeOTCount: Int {
        notion.workouts.filter { $0.isOTF }.count
    }

    /// Overall 8-Ball/9-Ball win-loss record across all logged sessions —
    /// same format/result filter BilliardsView.swift already uses for its own
    /// stats header, reused here rather than re-deriving the logic.
    private var lifetimeBilliardsRecord: String {
        let eightW = notion.billiardsSessions.filter { $0.format == "8-Ball" && $0.result == "Win" }.count
        let eightL = notion.billiardsSessions.filter { $0.format == "8-Ball" && $0.result == "Loss" }.count
        let nineW  = notion.billiardsSessions.filter { $0.format == "9-Ball" && $0.result == "Win" }.count
        let nineL  = notion.billiardsSessions.filter { $0.format == "9-Ball" && $0.result == "Loss" }.count
        return "8-Ball \(eightW)-\(eightL) · 9-Ball \(nineW)-\(nineL)"
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    recentComingUpSection
                    thisWeekSection
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 28)
            }
            .traceBackground()
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        NotificationCenter.default.post(name: .traceOpenLeftDrawer, object: nil)
                    } label: {
                        Image(systemName: "line.3.horizontal").foregroundStyle(Color.traceInk)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        NotificationCenter.default.post(name: .traceOpenRightDrawer, object: nil)
                    } label: {
                        Image(systemName: "tray").foregroundStyle(Color.traceInk)
                    }
                }
            }
            .navigationDestination(isPresented: $navigateToFitness) {
                FitnessView().environment(notion)
            }
            .navigationDestination(isPresented: $navigateToBilliards) {
                BilliardsView().environment(notion)
            }
        }
        .task {
            // Home reads Satchel's sidecars for the Due entries. Shared,
            // load-once store — this is a no-op after the first screen that
            // asked for it, and iCloud may not have resolved before now.
            await TraceSatchelChipStore.shared.loadIfNeeded()
            await notion.fetchVisits()
            await notion.fetchRecentInteractions()
            await notion.fetchWorkouts()
            if notion.billiardsSessions.isEmpty {
                await notion.fetchBilliardsSessions()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            Task {
                await notion.fetchVisits()
                await notion.fetchRecentInteractions()
            }
        }
        .sheet(item: $selectedVisit) { visit in
            VisitDetailView(visit: visit)
                .environment(NotionService.shared)
                .environment(LocationManager.shared)
        }
        .sheet(item: $selectedPerson) { person in
            PersonDetailView(personID: person.id, personName: person.name, openToAgenda: openPersonToAgenda)
                .environment(NotionService.shared)
        }
        .sheet(item: $selectedInteraction) { interaction in
            // Explicit injection, matching this file's own habit two lines
            // above. The sheet reads NotionService now that it can edit.
            InteractionDetailSheet(interaction: interaction)
                .environment(NotionService.shared)
        }
        // "See All" destinations for the two Recent columns — both presented
        // as sheets rather than pushes, matching how VisitsView is already
        // shown elsewhere (PlacesView presents it as a sheet too, since it
        // owns its own internal NavigationStack). PeopleView doesn't own one
        // itself (ContentView supplies it for the People tab), so it's
        // wrapped here for a "Done" toolbar button.
        .sheet(isPresented: $showingAllVisits) {
            VisitsView().environment(notion)
        }
        .sheet(isPresented: $showingAllInteractions) {
            NavigationStack {
                PeopleView()
                    .environment(notion)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showingAllInteractions = false }
                        }
                    }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(dateString)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Color.traceSecondary)
                .textCase(.uppercase)
            Text("Home")
                .font(.system(size: 27, weight: .bold))
                .foregroundStyle(Color.traceInk)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var dateString: String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMMM d"
        return f.string(from: Date())
    }

    // MARK: - Recent / Coming Up

    private var recentComingUpSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            TraceSegmentedControl(options: HomeSegment.allCases, label: { $0.rawValue }, selection: $homeSegment)
            if homeSegment == .recent {
                recentSplitRow
            } else {
                comingUpCard.traceCard()
            }
        }
    }

    private var recentSplitRow: some View {
        HStack(alignment: .top, spacing: 10) {
            recentColumn(
                title: "Visits",
                icon: "mappin.circle.fill",
                iconColor: .teal,
                items: Array(recentVisits.prefix(5)),
                rowTitle: { $0.placeName },
                rowDate: { $0.date },
                onTap: { selectedVisit = $0 },
                onSeeAll: { showingAllVisits = true }
            )
            recentColumn(
                title: "Interactions",
                icon: "person.crop.circle.fill",
                iconColor: .purple,
                items: Array(recentInteractionsList.prefix(5)),
                // WHAT it was, not WHO it was with.
                //
                // This titled each row with the person's name, so two different
                // interactions with the same person rendered as two identical
                // rows — David, 2026-07-31: "you see that Bronwyn is shown twice
                // for interactions." They were not duplicates; the column simply
                // was not saying which was which.
                //
                // It also stopped matching the tap: since Session 48 these rows
                // open the interaction rather than the person's card, so the
                // title should describe the thing that opens. The People tab's
                // own list has always titled by summary and reads correctly.
                rowTitle: { $0.summary.isEmpty ? (person(for: $0)?.name ?? "Interaction") : $0.summary },
                rowDate: { $0.date },
                // Session 48 follow-up — opens the interaction itself now,
                // not the person's whole card (see selectedInteraction above).
                onTap: { selectedInteraction = $0 },
                onSeeAll: { showingAllInteractions = true }
            )
        }
    }

    /// Shared shape for both Recent columns — a short (capped) list in its
    /// own card, a title row with a "See All" chevron, and compact rows
    /// (icon + title + relative date) sized to sit side by side on one
    /// screen width. Generic over any Identifiable item so Visit and
    /// Interaction (different types) can share this instead of duplicating
    /// near-identical column views.
    private func recentColumn<Item: Identifiable>(
        title: String,
        icon: String,
        iconColor: Color,
        items: [Item],
        rowTitle: @escaping (Item) -> String,
        rowDate: @escaping (Item) -> Date,
        onTap: @escaping (Item) -> Void,
        onSeeAll: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.traceSecondary)
                    .textCase(.uppercase)
                Spacer(minLength: 4)
                Button(action: onSeeAll) {
                    HStack(spacing: 2) {
                        Text("See All").font(.caption2.weight(.semibold))
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(Color.traceSecondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            if items.isEmpty {
                Text("Nothing yet")
                    .font(.caption)
                    .foregroundStyle(Color.traceTertiary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                        Button { onTap(item) } label: {
                            HStack(spacing: 8) {
                                ZStack {
                                    Circle().fill(iconColor.opacity(0.15)).frame(width: 26, height: 26)
                                    Image(systemName: icon)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(iconColor)
                                }
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(rowTitle(item))
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(Color.traceInk)
                                        .lineLimit(1)
                                    Text(relativeDate(rowDate(item)))
                                        .font(.caption2)
                                        .foregroundStyle(Color.traceSecondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if idx < items.count - 1 {
                            Divider().padding(.leading, 12)
                        }
                    }
                }
                .padding(.bottom, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .traceCard()
    }

    @ViewBuilder
    private var comingUpCard: some View {
        if comingUpEntries.isEmpty {
            emptyRow("Nothing queued in the next 30 days")
        } else {
            VStack(spacing: 0) {
                if !pastDueEntries.isEmpty {
                    groupHeader("Past due", count: pastDueEntries.count, tint: .orange)
                    ForEach(Array(pastDueEntries.enumerated()), id: \.element.id) { idx, entry in
                        entryRow(entry)
                        if idx < pastDueEntries.count - 1 || !upcomingEntries.isEmpty {
                            Divider().padding(.leading, 54)
                        }
                    }
                }
                if !upcomingEntries.isEmpty {
                    // Only headed when there is something above it to be told
                    // apart from. On its own the card title already says it.
                    if !pastDueEntries.isEmpty {
                        groupHeader("Coming up", count: upcomingEntries.count, tint: .secondary)
                    }
                    ForEach(Array(upcomingEntries.enumerated()), id: \.element.id) { idx, entry in
                        entryRow(entry)
                        if idx < upcomingEntries.count - 1 {
                            Divider().padding(.leading, 54)
                        }
                    }
                }
            }
        }
    }

    private func groupHeader(_ title: String, count: Int, tint: Color) -> some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold))
                .kerning(0.5)
                .foregroundStyle(tint)
            Text("\(count)")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private func entryRow(_ entry: ComingUpEntry) -> some View {
        switch entry {
        case .birthday(let bday):
            Button { openPersonToAgenda = false; selectedPerson = bday.person } label: {
                activityRow(icon: "birthday.cake.fill", iconColor: .pink,
                            title: "\(bday.person.name)'s birthday",
                            subtitle: whenLabel(bday.daysAway, on: bday.nextOccurrence),
                            trailing: nil)
            }
            .buttonStyle(.plain)

        case .agenda(let person, let item):
            HStack(spacing: 0) {
                Button { openPersonToAgenda = true; selectedPerson = person } label: {
                    activityRow(
                        icon: item.isOverdue ? "exclamationmark.circle.fill"
                                             : "bubble.left.and.bubble.right.fill",
                        iconColor: item.isOverdue ? .orange : .blue,
                        title: item.text,
                        subtitle: "\(person.name) · \(whenLabel(item.daysAway ?? 0, on: item.due ?? Date()))",
                        trailing: nil)
                }
                .buttonStyle(.plain)
                Button { completeAgendaItem(person, item) } label: {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 17))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 6)
                        .padding(.trailing, 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Done: \(item.text)")
            }

        case .document(let doc):
            // OPENS SATCHEL, not something in Trace. Documents are Satchel's and
            // the row says so by going there — a Trace-side viewer would be a
            // second place that renders the same file and drifts from it.
            Button {
                let path = doc.relativePath
                    .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? doc.relativePath
                if let url = URL(string: "satchel://document?path=\(path)") { openURL(url) }
            } label: {
                activityRow(
                    icon: "doc.text.fill",
                    iconColor: (doc.remindOn.map { cal.startOfDay(for: $0) < cal.startOfDay(for: Date()) } ?? false)
                        ? .orange : .indigo,
                    title: doc.title,
                    subtitle: "Satchel · " + whenLabel(
                        cal.dateComponents([.day], from: cal.startOfDay(for: Date()),
                                           to: cal.startOfDay(for: doc.remindOn ?? Date())).day ?? 0,
                        on: doc.remindOn ?? Date()),
                    trailing: nil)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func activityRow(icon: String, iconColor: Color, title: String, subtitle: String, trailing: String?) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(iconColor.opacity(0.15)).frame(width: 34, height: 34)
                Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(iconColor)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.medium)).foregroundStyle(Color.traceInk).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(Color.traceSecondary).lineLimit(1)
            }
            Spacer()
            if let trailing {
                Text(trailing).font(.caption).foregroundStyle(Color.traceSecondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(Color.traceSecondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 24)
    }

    private func relativeDate(_ date: Date) -> String {
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let days = cal.dateComponents([.day], from: date, to: Date()).day ?? 0
        if days < 7 { return "\(days)d ago" }
        let f = DateFormatter(); f.dateFormat = "MMM d"
        return f.string(from: date)
    }

    // MARK: - This Week

    private var thisWeekSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("This Week").traceSectionTitleStyle()
            HStack(spacing: 10) {
                statTile(
                    icon: "figure.run", color: .orange, label: "Orange Theory",
                    value: "\(thisWeekOTWorkouts.count) class\(thisWeekOTWorkouts.count == 1 ? "" : "es")",
                    detail: thisWeekOTWorkouts.first.map { workoutDetail($0) },
                    lifetime: "\(lifetimeOTCount) lifetime class\(lifetimeOTCount == 1 ? "" : "es")",
                    action: { navigateToFitness = true }
                )
                statTile(
                    icon: "circle.grid.3x3.fill", color: Color(.systemGray), label: "Billiards",
                    value: "\(thisWeekBilliards.count) session\(thisWeekBilliards.count == 1 ? "" : "s")",
                    detail: thisWeekBilliards.first.map { billiardsDetail($0) },
                    lifetime: lifetimeBilliardsRecord,
                    action: { navigateToBilliards = true }
                )
            }
        }
    }

    private func workoutDetail(_ w: Workout) -> String {
        var parts = ["Last: \(w.date.formatted(.dateTime.weekday(.abbreviated)))"]
        if let splat = w.splatPoints { parts.append("Splat +\(splat)") }
        return parts.joined(separator: ", ")
    }

    private func billiardsDetail(_ s: BilliardsSession) -> String {
        var parts = ["Last: \(s.date.formatted(.dateTime.weekday(.abbreviated)))"]
        if let mine = s.myTeamPoints, let theirs = s.opponentTeamPoints {
            parts.append("\(mine)–\(theirs)")
        } else if let result = s.result {
            parts.append(result)
        }
        return parts.joined(separator: ", ")
    }

    /// Session 48 follow-up — tiles are now tappable (jump straight to
    /// Fitness/Billiards, replacing the separate Jump To grid this same
    /// change removed) and each carries a lifetime line under the existing
    /// "Last: ..." detail. The old "placement TBD" caption is gone — see this
    /// file's header comment for why.
    private func statTile(icon: String, color: Color, label: String, value: String, detail: String?, lifetime: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    ZStack {
                        Circle().fill(color.opacity(0.15)).frame(width: 24, height: 24)
                        Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
                    }
                    Text(label).font(.caption.weight(.semibold)).foregroundStyle(Color.traceInk)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.traceTertiary)
                }
                Text(value).font(.system(size: 17, weight: .bold)).foregroundStyle(Color.traceInk)
                if let detail {
                    Text(detail).font(.caption2).foregroundStyle(Color.traceSecondary).lineLimit(1)
                }
                Text(lifetime).font(.caption2.weight(.medium)).foregroundStyle(Color.traceTertiary).lineLimit(1)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .traceCard()
        }
        .buttonStyle(.plain)
    }
}
