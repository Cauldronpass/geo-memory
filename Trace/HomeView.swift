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

    private var agendaPeople: [Person] {
        notion.people
            .filter { !($0.agenda ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.name < $1.name }
    }

    /// First non-empty line of a person's agenda field, as a row preview.
    /// `Person.agenda` is newline-delimited (see Models.swift).
    private func agendaPreview(_ person: Person) -> String {
        (person.agenda ?? "")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? "Something queued"
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
            InteractionDetailSheet(interaction: interaction)
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
                rowTitle: { person(for: $0)?.name ?? $0.summary },
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
        if upcomingBirthdays.isEmpty && agendaPeople.isEmpty {
            emptyRow("Nothing queued in the next 30 days")
        } else {
            VStack(spacing: 0) {
                ForEach(Array(upcomingBirthdays.enumerated()), id: \.element.id) { idx, bday in
                    Button { openPersonToAgenda = false; selectedPerson = bday.person } label: {
                        activityRow(
                            icon: "birthday.cake.fill", iconColor: .pink,
                            title: "\(bday.person.name)'s birthday",
                            subtitle: "In \(bday.daysAway) day\(bday.daysAway == 1 ? "" : "s") · "
                                + bday.nextOccurrence.formatted(.dateTime.month(.abbreviated).day()),
                            trailing: nil
                        )
                    }
                    .buttonStyle(.plain)
                    if idx < upcomingBirthdays.count - 1 || !agendaPeople.isEmpty {
                        Divider().padding(.leading, 54)
                    }
                }
                // Session 48 follow-up — each queued person is now its own
                // row (was previously one summary row that only ever opened
                // agendaPeople.first, a real bug David caught: tapping it
                // never reached anyone but the first person regardless of
                // how many were actually queued).
                ForEach(Array(agendaPeople.enumerated()), id: \.element.id) { idx, person in
                    Button { openPersonToAgenda = true; selectedPerson = person } label: {
                        activityRow(
                            icon: "bubble.left.and.bubble.right.fill", iconColor: .blue,
                            title: person.name,
                            subtitle: agendaPreview(person),
                            trailing: nil
                        )
                    }
                    .buttonStyle(.plain)
                    if idx < agendaPeople.count - 1 {
                        Divider().padding(.leading, 54)
                    }
                }
            }
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
