import SwiftUI
import CoreLocation
import Combine

// MARK: - Time-of-day theme

private enum HomeTheme {
    case morning, afternoon, evening

    static var current: HomeTheme {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return .morning
        case 12..<17: return .afternoon
        default:     return .evening
        }
    }

    var greeting: String {
        switch self {
        case .morning:   return "Good morning"
        case .afternoon: return "Good afternoon"
        case .evening:   return "Good evening"
        }
    }

    // Teal / Amber / Purple — lightest fill
    var headerBg: Color {
        switch self {
        case .morning:   return Color(red: 0.882, green: 0.961, blue: 0.933)
        case .afternoon: return Color(red: 0.980, green: 0.933, blue: 0.855)
        case .evening:   return Color(red: 0.933, green: 0.929, blue: 0.996)
        }
    }

    var headerTitle: Color {
        switch self {
        case .morning:   return Color(red: 0.016, green: 0.204, blue: 0.173)
        case .afternoon: return Color(red: 0.255, green: 0.141, blue: 0.008)
        case .evening:   return Color(red: 0.149, green: 0.129, blue: 0.361)
        }
    }

    var headerSub: Color {
        switch self {
        case .morning:   return Color(red: 0.059, green: 0.431, blue: 0.337)
        case .afternoon: return Color(red: 0.522, green: 0.310, blue: 0.043)
        case .evening:   return Color(red: 0.325, green: 0.290, blue: 0.718)
        }
    }
}

// MARK: - HomeView

struct HomeView: View {
    @Environment(NotionService.self) private var notion
    @Environment(LocationManager.self) private var locationManager

    @State private var dayNoteAction: DayNoteAction? = nil
    @State private var selectedVisit: Visit?
    @State private var navigateToPlace: Place?
    @State private var notePageIndex = 0
    @State private var calPageIndex = 0
    @State private var selectedBucketScope: String? = nil
    @State private var showDeleteNoteConfirm = false
    @State private var showMoveNoteDialog = false
    @State private var selectedCalEvent: NextCalendarEvent? = nil

    private var oura: OuraService { OuraService.shared }
    private var cal: CalendarService { CalendarService.shared }
    private var things: ThingsService { ThingsService.shared }
    private let theme = HomeTheme.current

    // MARK: - Next Up items (calendar + bedtime merged)

    private enum NextUpItem: Identifiable {
        case event(NextCalendarEvent)
        case bedtime(OuraSleepTime)

        var id: String {
            switch self {
            case .event(let e):   return "event-\(e.startDate.timeIntervalSince1970)"
            case .bedtime:        return "bedtime"
            }
        }

        var sortDate: Date {
            switch self {
            case .event(let e):   return e.startDate
            case .bedtime(let s): return s.bedtimeDate ?? Date.distantFuture
            }
        }
    }

    /// Merged, time-sorted list of upcoming calendar events + tonight's bedtime.
    /// After noon: uses Oura recommendation if available, otherwise 10:30 PM default.
    private var nextUpItems: [NextUpItem] {
        var items: [NextUpItem] = cal.upcomingEvents.map { .event($0) }
        let hour = Calendar.current.component(.hour, from: Date())
        // Show bedtime from 4 PM onward; keep showing even after it passes (red "past bedtime")
        // until midnight so the reminder remains visible late at night.
        if hour >= 16 || hour < 2 {
            let st = oura.sleepTime ?? OuraSleepTime.userDefault()
            if st.bedtimeDate != nil {
                items.append(.bedtime(st))
            }
        }
        return items.sorted { $0.sortDate < $1.sortDate }
    }

    // MARK: Computed data

    private var todayNote: DayNote? {
        notion.dayNotes.first {
            $0.scope == nil &&
            $0.status != "Archived" &&
            ($0.date.map { Calendar.current.isDateInToday($0) } ?? false)
        }
    }

    private var nearbyPlace: Place? {
        guard let userLoc = locationManager.location else { return nil }
        return notion.places.first { place in
            guard !place.geofenceExcluded && place.status != "Archived" else { return false }
            let radius = Double(place.geofenceRadius ?? (place.frequent ? 200 : 150))
            return CLLocation(latitude: place.latitude, longitude: place.longitude)
                .distance(from: userLoc) <= radius
        }
    }

    private var recentVisits: [Visit] {
        Array(notion.visits.sorted { $0.date > $1.date }.prefix(3))
    }

    private var activityLabel: String {
        guard let day = oura.activity?.day else { return "Activity" }
        let today = Calendar.current.startOfDay(for: Date())
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        if let d = fmt.date(from: day), Calendar.current.startOfDay(for: d) < today {
            return "Activity ↑"   // showing a prior day's data
        }
        return "Activity"
    }

    private func companions(for visit: Visit) -> [Person] {
        notion.people.filter { visit.peopleIDs.contains($0.id) }
    }

    private func placeFor(_ visit: Visit) -> Place? {
        notion.places.first { $0.id == visit.placeID }
    }

    private func placeVisits(_ place: Place) -> [Visit] {
        notion.visits.filter { $0.placeID == place.id }.sorted { $0.date > $1.date }
    }

    private func avgRating(_ place: Place) -> Double? {
        let r = notion.visits.filter { $0.placeID == place.id }.compactMap { $0.rating }
        guard !r.isEmpty else { return nil }
        return Double(r.reduce(0, +)) / Double(r.count)
    }

    // MARK: Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    headerSection

                    VStack(spacing: 10) {
                        ouraSection
                        calendarSection
                        noteSection
                        thingsSection
                        placeSection
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 28)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color(UIColor.systemGroupedBackground))
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        NotificationCenter.default.post(name: .traceOpenLeftDrawer, object: nil)
                    } label: {
                        Image(systemName: "line.3.horizontal")
                            .foregroundStyle(theme.headerTitle)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        NotificationCenter.default.post(name: .traceOpenRightDrawer, object: nil)
                    } label: {
                        Image(systemName: "tray")
                            .foregroundStyle(theme.headerTitle)
                    }
                }
            }
            .navigationDestination(item: $navigateToPlace) { place in
                PlaceDetailView(place: place)
                    .environment(NotionService.shared)
                    .environment(LocationManager.shared)
            }
        }
        .task {
            await oura.fetchToday()
            await cal.requestAndFetch()
            await things.fetch()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            Task {
                await cal.fetchUpcomingEvents()
                await things.fetch()
                await oura.fetchToday()
            }
        }
        .onReceive(Timer.publish(every: 900, on: .main, in: .common).autoconnect()) { _ in
            Task { await oura.fetchToday() }
        }
        .sheet(item: $dayNoteAction) { action in
            DayNoteSheet(action: action)
                .environment(NotionService.shared)
        }
        .sheet(isPresented: Binding(
            get: { selectedBucketScope != nil },
            set: { if !$0 { selectedBucketScope = nil } }
        )) {
            if let scope = selectedBucketScope {
                BucketNoteSheet(scope: scope)
                    .environment(NotionService.shared)
            }
        }
        .sheet(item: $selectedVisit) { visit in
            VisitDetailView(visit: visit)
                .environment(NotionService.shared)
                .environment(LocationManager.shared)
        }
    }

    // MARK: – Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(dateString)
                .font(.subheadline)
                .foregroundStyle(theme.headerSub)
            Text("\(theme.greeting), David")
                .font(.title2.weight(.medium))
                .foregroundStyle(theme.headerTitle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 16)
        .background(theme.headerBg)
    }

    private var dateString: String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMMM d"
        return f.string(from: Date())
    }

    // MARK: – Oura

    @ViewBuilder
    private var ouraSection: some View {
        if let err = oura.lastError, oura.sleep == nil {
            sectionCard {
                HStack {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 5) {
                sectionLabel("Oura ring")
                HStack(spacing: 7) {
                    ouraTile(
                        label: "Sleep",
                        score: oura.sleep?.score,
                        detail: OuraService.formatDuration(oura.sleep?.totalSleepDuration)
                             ?? oura.sleep?.lowestHeartRate.map { "HR \($0) bpm" }
                    )
                    ouraTile(
                        label: "Readiness",
                        score: oura.readiness?.score,
                        detail: oura.sleep?.averageHrv.map { "HRV \($0)ms" }
                             ?? oura.sleep?.lowestHeartRate.map { "HR \($0) bpm" }
                    )
                    ouraTile(
                        label: activityLabel,
                        score: oura.activity?.score,
                        detail: oura.activity?.steps.map { "\($0.formatted()) steps" }
                    )
                }
            }
        }
    }

    /// Oura score → (background, label, value) color triple matching Oura's app palette.
    private func ouraTileColors(_ score: Int?) -> (bg: Color, label: Color, value: Color) {
        guard let score else {
            // No data — neutral
            return (
                Color(UIColor.secondarySystemGroupedBackground),
                Color.secondary.opacity(0.6),
                Color.secondary.opacity(0.3)
            )
        }
        if score >= 85 {
            // Optimal — green
            return (
                Color(red: 0.871, green: 0.957, blue: 0.925),
                Color(red: 0.063, green: 0.435, blue: 0.310),
                Color(red: 0.012, green: 0.220, blue: 0.157)
            )
        } else if score >= 70 {
            // Good — amber
            return (
                Color(red: 0.997, green: 0.953, blue: 0.867),
                Color(red: 0.580, green: 0.380, blue: 0.020),
                Color(red: 0.380, green: 0.230, blue: 0.008)
            )
        } else {
            // Pay attention — red
            return (
                Color(red: 0.998, green: 0.898, blue: 0.898),
                Color(red: 0.680, green: 0.130, blue: 0.130),
                Color(red: 0.480, green: 0.060, blue: 0.060)
            )
        }
    }

    private func ouraTile(label: String, score: Int?, detail: String?) -> some View {
        let (bg, labelColor, valueColor) = ouraTileColors(score)
        return VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(labelColor)
            Group {
                if let score {
                    Text("\(score)")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(valueColor)
                } else {
                    Text("–")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(labelColor)
                }
            }
            Text(detail ?? " ")
                .font(.system(size: 9))
                .foregroundStyle(labelColor)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(bg, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: – Calendar

    @ViewBuilder
    private var calendarSection: some View {
        let items = nextUpItems

        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                sectionLabel("Next up")
                Spacer()
                if items.count > 1 {
                    HStack(spacing: 4) {
                        ForEach(0..<items.count, id: \.self) { i in
                            Circle()
                                .fill(i == calPageIndex
                                      ? theme.headerSub
                                      : Color.secondary.opacity(0.3))
                                .frame(width: 5, height: 5)
                        }
                    }
                }
                Button {
                    UIApplication.shared.open(URL(string: "fantastical://")!)
                } label: {
                    Image(systemName: "calendar")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            if items.isEmpty {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.secondary.opacity(0.25))
                        .frame(width: 3, height: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No events in the next 18 hours")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if let next = cal.nextEventBeyondWindow {
                            Text("Next: \(next.nextEventLabel)")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(UIColor.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 10))
            } else if items.count == 1 {
                nextUpCard(items[0])
            } else {
                TabView(selection: $calPageIndex) {
                    ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                        nextUpCard(item).tag(idx)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(height: 56)
            }
        }
        .sheet(item: $selectedCalEvent) { event in
            CalendarEventDetailSheet(event: event)
        }
    }

    @ViewBuilder
    private func nextUpCard(_ item: NextUpItem) -> some View {
        switch item {
        case .event(let event):  eventCard(event)
        case .bedtime(let st):   bedtimeCard(st)
        }
    }

    private func eventCard(_ event: NextCalendarEvent) -> some View {
        Button {
            selectedCalEvent = event
        } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(event.color)
                    .frame(width: 3, height: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(event.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("\(event.startTimeString) · \(event.durationLabel) · \(event.calendarTitle)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text(event.timeLabel)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(event.color)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(UIColor.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private func bedtimeCard(_ st: OuraSleepTime) -> some View {
        let bedtimeStr = st.bedtimeDate.map {
            DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .short)
        } ?? "Tonight"

        let minsUntilBed: Int? = st.bedtimeDate.map { Int($0.timeIntervalSinceNow / 60) }
        let timeLabel: String = {
            guard let mins = minsUntilBed else { return "" }
            if mins < 0  { return "past bedtime" }
            if mins < 60 { return "in \(mins)m" }
            let h = mins / 60; let m = mins % 60
            return m > 0 ? "in \(h)h \(m)m" : "in \(h)h"
        }()

        let isOura = st.isOuraRecommended
        let accentColor = isOura ? Color.indigo : Color.secondary
        let timeLabelColor: Color = {
            guard let mins = minsUntilBed else { return accentColor }
            if mins < 0   { return .red }
            if mins <= 30 { return Color(red: 0.95, green: 0.75, blue: 0.1) }
            return accentColor
        }()
        let cardTitle = isOura ? "Recommended bedtime" : "Target bedtime"
        let subtitle: String = {
            if isOura {
                return st.recommendationLabel.isEmpty ? bedtimeStr : "\(bedtimeStr) · \(st.recommendationLabel)"
            } else {
                return "\(bedtimeStr) · your default"
            }
        }()

        return HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(accentColor.opacity(0.6))
                .frame(width: 3, height: 36)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Image(systemName: isOura ? "moon.stars" : "moon")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(accentColor)
                    Text(cardTitle)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if !timeLabel.isEmpty {
                Text(timeLabel)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(timeLabelColor)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(UIColor.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: – Day note

    /// All non-archived day notes: today's date note first, then scope notes ("This Week", etc.).
    private var allActiveNotes: [DayNote] {
        var result: [DayNote] = []
        let todayNotes = notion.dayNotes
            .filter {
                $0.scope == nil && $0.status != "Archived" &&
                ($0.date.map { Calendar.current.isDateInToday($0) } ?? false)
            }
            .sorted { ($0.date ?? Date.distantPast) > ($1.date ?? Date.distantPast) }
        result.append(contentsOf: todayNotes)
        return result
    }

    @ViewBuilder
    private var noteSection: some View {
        let notes = allActiveNotes
        let label = (notePageIndex < notes.count)
            ? (notes[notePageIndex].scope ?? "Today's note")
            : "Today's note"

        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                sectionLabel(label)
                Spacer()
                if notes.count > 1 {
                    HStack(spacing: 4) {
                        ForEach(0..<notes.count, id: \.self) { i in
                            Circle()
                                .fill(i == notePageIndex
                                      ? theme.headerSub
                                      : Color.secondary.opacity(0.3))
                                .frame(width: 5, height: 5)
                        }
                    }
                }
                if !notes.isEmpty {
                    Button { showMoveNoteDialog = true } label: {
                        Image(systemName: "folder")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .confirmationDialog(
                        "Move to bucket",
                        isPresented: $showMoveNoteDialog,
                        titleVisibility: .visible
                    ) {
                        let note = notes[min(notePageIndex, notes.count - 1)]
                        ForEach(["Inbox", "This Week", "Next Week", "This Month", "Next Month"], id: \.self) { target in
                            Button(target) {
                                Task {
                                    try? await notion.moveDayNoteToBucket(id: note.id, scope: target)
                                }
                            }
                        }
                        Button("Cancel", role: .cancel) {}
                    }

                    Button { showDeleteNoteConfirm = true } label: {
                        Image(systemName: "trash")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .confirmationDialog(
                        "Delete this note?",
                        isPresented: $showDeleteNoteConfirm,
                        titleVisibility: .visible
                    ) {
                        let note = notes[min(notePageIndex, notes.count - 1)]
                        Button("Delete", role: .destructive) {
                            Task { try? await notion.deleteDayNote(id: note.id) }
                        }
                        Button("Cancel", role: .cancel) {}
                    }
                }
                Image(systemName: "pencil")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if notes.isEmpty {
                Button { dayNoteAction = .tapDate(Date(), nil) } label: {
                    Text("Tap to add a note for today…")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color(UIColor.secondarySystemGroupedBackground),
                                    in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Inbox")      { selectedBucketScope = "Inbox"      }
                    Button("This Week")  { selectedBucketScope = "This Week"  }
                    Button("This Month") { selectedBucketScope = "This Month" }
                    Button("Next Week")  { selectedBucketScope = "Next Week"  }
                    Button("Next Month") { selectedBucketScope = "Next Month" }
                }
            } else if notes.count == 1 {
                noteCard(notes[0])
            } else {
                TabView(selection: $notePageIndex) {
                    ForEach(Array(notes.enumerated()), id: \.offset) { idx, note in
                        noteCard(note).tag(idx)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(height: 72)
            }
        }
    }

    private func noteCard(_ note: DayNote) -> some View {
        Button {
            dayNoteAction = note.scope != nil
                ? .tapBucket(note.scope!, note)
                : .tapDate(note.date ?? Date(), note)
        } label: {
            Group {
                if !note.body.isEmpty {
                    Text(note.body)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                } else {
                    Text("Tap to add a note…")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(UIColor.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Inbox")      { selectedBucketScope = "Inbox"      }
            Button("This Week")  { selectedBucketScope = "This Week"  }
            Button("This Month") { selectedBucketScope = "This Month" }
            Button("Next Week")  { selectedBucketScope = "Next Week"  }
            Button("Next Month") { selectedBucketScope = "Next Month" }
        }
    }

    // MARK: – Things

    @ViewBuilder
    private var thingsSection: some View {
        if things.shouldShow {
            let shown = Array(things.tasks.prefix(3))
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    sectionLabel("Today in Things")
                    Spacer()
                    if things.inboxCount > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "tray")
                                .font(.system(size: 9, weight: .semibold))
                            Text("\(things.inboxCount)")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color(red: 0.114, green: 0.620, blue: 0.459))
                        .clipShape(Capsule())
                    }
                    if things.totalCount > 3 {
                        Text("\(shown.count) of \(things.totalCount)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        UIApplication.shared.open(URL(string: "things:///show?id=today")!)
                    } label: {
                        Text("Open Things →")
                            .font(.system(size: 10))
                            .foregroundStyle(Color(red: 0.114, green: 0.620, blue: 0.459))
                    }
                    .buttonStyle(.plain)
                }

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(shown) { task in
                        HStack(alignment: .top, spacing: 8) {
                            Circle()
                                .fill(Color.secondary.opacity(0.45))
                                .frame(width: 4, height: 4)
                                .padding(.top, 6)
                            Text(task.title)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if let list = task.list, !list.isEmpty {
                                Text(list)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                    }
                }
                .background(Color(UIColor.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    // MARK: – Place / recent visits

    @ViewBuilder
    private var placeSection: some View {
        if let place = nearbyPlace {
            placeMemoryCard(place)
        } else {
            recentVisitsSection
        }
    }

    // At a known place
    private func placeMemoryCard(_ place: Place) -> some View {
        let visits = placeVisits(place)
        let lastVisit = visits.first
        let rating = avgRating(place)

        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                sectionLabel("You're at a saved place")
                Spacer()
                Circle()
                    .fill(Color(red: 0.114, green: 0.620, blue: 0.459))
                    .frame(width: 7, height: 7)
            }
            VStack(spacing: 0) {
                // Place row — taps to PlaceDetailView
                Button { navigateToPlace = place } label: {
                    HStack(spacing: 10) {
                        placeIconView(place)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(place.name)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text([place.category, place.city]
                                .filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)

                Divider().padding(.horizontal, 12)

                // Stats row
                HStack(spacing: 0) {
                    statCell(value: "\(visits.count)", label: "visits")
                    Divider().frame(height: 28)

                    if let lv = lastVisit {
                        Button { selectedVisit = lv } label: {
                            statCell(
                                value: shortDate(lv.date),
                                label: "last visit",
                                valueColor: Color(red: 0.094, green: 0.371, blue: 0.647)
                            )
                        }
                        .buttonStyle(.plain)
                    } else {
                        statCell(value: "–", label: "last visit")
                    }

                    Divider().frame(height: 28)
                    statCell(
                        value: rating.map { String(format: "★ %.1f", $0) } ?? "–",
                        label: "avg rating"
                    )
                }
                .padding(.vertical, 8)
            }
            .background(Color(UIColor.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 10))
        }
    }

    // Fallback: recent visits list
    private var recentVisitsSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            sectionLabel("Recent visits")
            VStack(spacing: 0) {
                ForEach(Array(recentVisits.enumerated()), id: \.element.id) { idx, visit in
                    let place = placeFor(visit)
                    let comps = companions(for: visit)

                    Button { selectedVisit = visit } label: {
                        HStack(spacing: 10) {
                            placeIconView(place)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(visit.placeName)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                HStack(spacing: 4) {
                                    Text(relativeDate(visit.date))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if let cnt = place?.visitCount, cnt > 0 {
                                        Text("·").font(.caption).foregroundStyle(.secondary)
                                        Text("\(cnt) visits").font(.caption).foregroundStyle(.secondary)
                                    }
                                    if !comps.isEmpty {
                                        Text("·").font(.caption).foregroundStyle(.secondary)
                                        companionRow(comps)
                                    }
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                    }
                    .buttonStyle(.plain)

                    if idx < recentVisits.count - 1 {
                        Divider().padding(.horizontal, 12)
                    }
                }
            }
            .background(Color(UIColor.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: – Reusable sub-views

    private func placeIconView(_ place: Place?) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(placeColor(for: place?.category ?? ""))
                .frame(width: 34, height: 34)
            Image(systemName: placeIcon(for: place?.category ?? ""))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
        }
    }

    private func companionRow(_ comps: [Person]) -> some View {
        HStack(spacing: 2) {
            ForEach(comps.prefix(3)) { person in
                let initials = person.name
                    .components(separatedBy: " ")
                    .compactMap { $0.first.map { String($0) } }
                    .prefix(2).joined()
                let colors = companionColors(person.name)
                Text(initials)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(colors.text)
                    .frame(width: 15, height: 15)
                    .background(colors.bg, in: Circle())
            }
            Text(comps.prefix(2).map { $0.name.components(separatedBy: " ").first ?? $0.name }
                .joined(separator: ", "))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func companionColors(_ name: String) -> (bg: Color, text: Color) {
        let options: [(Color, Color)] = [
            (Color(red: 0.933, green: 0.929, blue: 0.996), Color(red: 0.149, green: 0.129, blue: 0.361)),
            (Color(red: 0.882, green: 0.961, blue: 0.933), Color(red: 0.016, green: 0.204, blue: 0.173)),
            (Color(red: 0.980, green: 0.927, blue: 0.906), Color(red: 0.290, green: 0.113, blue: 0.047)),
            (Color(red: 0.900, green: 0.953, blue: 0.871), Color(red: 0.092, green: 0.428, blue: 0.067)),
        ]
        return options[abs(name.hashValue) % options.count]
    }

    @ViewBuilder
    private func sectionCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(UIColor.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 10))
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
    }

    private func statCell(value: String, label: String, valueColor: Color = .primary) -> some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(valueColor)
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func shortDate(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "MMM d"
        return f.string(from: date)
    }

    private func relativeDate(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            let mins = Int(Date().timeIntervalSince(date) / 60)
            if mins < 1  { return "Just now" }
            if mins < 60 { return "\(mins)m ago" }
            return "\(mins / 60)h ago"
        }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let days = cal.dateComponents([.day], from: date, to: Date()).day ?? 0
        if days < 7 { return "\(days) days ago" }
        let f = DateFormatter(); f.dateFormat = "MMM d"
        return f.string(from: date)
    }
}

// MARK: - Calendar Event Detail Sheet

private struct CalendarEventDetailSheet: View {
    let event: NextCalendarEvent
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Pull indicator
            Capsule()
                .fill(Color.secondary.opacity(0.3))
                .frame(width: 36, height: 4)
                .padding(.top, 12)
                .padding(.bottom, 20)

            // Color bar + title
            HStack(alignment: .top, spacing: 14) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(event.color)
                    .frame(width: 4, height: 52)
                VStack(alignment: .leading, spacing: 4) {
                    Text(event.title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(event.calendarTitle)
                        .font(.subheadline)
                        .foregroundStyle(event.color)
                }
                Spacer()
            }
            .padding(.horizontal, 24)

            Divider().padding(.vertical, 20).padding(.horizontal, 24)

            // Detail rows
            VStack(spacing: 14) {
                detailRow(icon: "clock", label: "Time", value: timeRangeString)
                detailRow(icon: "timer", label: "Duration", value: event.durationLabel)
                detailRow(icon: "calendar", label: "When", value: event.timeLabel)
            }
            .padding(.horizontal, 24)

            Spacer()

            // Open in Fantastical
            Button {
                UIApplication.shared.open(URL(string: "fantastical://")!)
                dismiss()
            } label: {
                HStack {
                    Image(systemName: "calendar.badge.plus")
                    Text("Open in Fantastical")
                        .fontWeight(.medium)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color(red: 0.98, green: 0.35, blue: 0.24))
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.hidden)
    }

    private var timeRangeString: String {
        let start = DateFormatter.localizedString(from: event.startDate, dateStyle: .none, timeStyle: .short)
        let end   = DateFormatter.localizedString(from: event.endDate,   dateStyle: .none, timeStyle: .short)
        return "\(start) – \(end)"
    }

    private func detailRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundStyle(.secondary)
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
        }
        .font(.subheadline)
    }
}
