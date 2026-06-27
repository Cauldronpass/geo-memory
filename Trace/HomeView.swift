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

    @State private var selectedVisit: Visit?
    @State private var navigateToPlace: Place?
    @State private var calPageIndex = 0
    @State private var selectedCalEvent: NextCalendarEvent? = nil
    @State private var notePlanContent: String = ""
    @State private var notePlanLoaded: Bool = false
    @State private var weekNoteContent: String = ""
    @State private var monthNoteContent: String = ""
    @State private var showNotesView: Bool = false
    @State private var showingMoveDailyNote: Bool = false
    @State private var moveDailyNoteDate: Date = Date()
    @State private var showingVisitsView: Bool = false
    @State private var showingQuickAppend: Bool = false
    @State private var showingWeekNote: Bool = false
    @State private var showingMonthNote: Bool = false
    @State private var notePageIndex: Int = 0

    private var oura: OuraService { OuraService.shared }
    private var cal: CalendarService { CalendarService.shared }
    private var things: ThingsService { ThingsService.shared }
    private var healthKit: HealthKitService { HealthKitService.shared }
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
                        activityRingsSection
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
            await healthKit.requestAuthorizationAndFetch()
            if let content = try? NoteStore.shared.readDailyNote() {
                notePlanContent = content
            }
            notePlanLoaded = true
            weekNoteContent = (try? NoteStore.shared.readFile(weekNoteRelativePath)) ?? ""
            monthNoteContent = (try? NoteStore.shared.readFile(monthNoteRelativePath)) ?? ""
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            Task {
                await cal.fetchUpcomingEvents()
                await things.fetch()
                await oura.fetchToday()
                await healthKit.fetchToday()
                if let content = try? NoteStore.shared.readDailyNote() {
                    notePlanContent = content
                }
                weekNoteContent = (try? NoteStore.shared.readFile(weekNoteRelativePath)) ?? ""
                monthNoteContent = (try? NoteStore.shared.readFile(monthNoteRelativePath)) ?? ""
            }
        }
        // Reload preview whenever the daily note changes (e.g. from NotesView or capture drawer).
        .onReceive(NotificationCenter.default.publisher(for: .noteStoreCalendarDidChange)) { _ in
            if let content = try? NoteStore.shared.readDailyNote() {
                notePlanContent = content
            }
        }
        .onReceive(Timer.publish(every: 900, on: .main, in: .common).autoconnect()) { _ in
            Task {
                await oura.fetchToday()
                await healthKit.fetchToday()
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
        return VStack(alignment: .center, spacing: 2) {
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
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(bg, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: – Activity Rings (Apple Watch / HealthKit)

    @ViewBuilder
    private var activityRingsSection: some View {
        if healthKit.isAvailable {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    sectionLabel("Activity")
                    Spacer()
                    Button {
                        UIApplication.shared.open(URL(string: "x-apple-health://")!)
                    } label: {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                HStack(spacing: 7) {
                    activityRingTile(
                        label: "Move",
                        value: healthKit.moveCalories.map { Int($0) }.map { "\($0)" } ?? "–",
                        unit: "kcal",
                        goal: healthKit.moveGoal.map { Int($0) }.map { "/ \($0)" },
                        progress: healthKit.moveProgress() ?? 0,
                        color: Color(red: 1.0, green: 0.22, blue: 0.36)
                    )
                    activityRingTile(
                        label: "Exercise",
                        value: healthKit.exerciseMinutes.map { Int($0) }.map { "\($0)" } ?? "–",
                        unit: "min",
                        goal: healthKit.exerciseGoal.map { Int($0) }.map { "/ \($0)" },
                        progress: healthKit.exerciseProgress() ?? 0,
                        color: Color(red: 0.42, green: 0.95, blue: 0.39)
                    )
                    activityRingTile(
                        label: "Stand",
                        value: healthKit.standHours.map { Int($0) }.map { "\($0)" } ?? "–",
                        unit: "hrs",
                        goal: healthKit.standGoal.map { Int($0) }.map { "/ \($0)" },
                        progress: healthKit.standProgress() ?? 0,
                        color: Color(red: 0.18, green: 0.85, blue: 0.95)
                    )
                }
            }
        }
    }

    private func activityRingTile(label: String, value: String, unit: String,
                                   goal: String?, progress: Double, color: Color) -> some View {
        VStack(alignment: .center, spacing: 6) {
            // Ring graphic
            ZStack {
                Circle()
                    .stroke(color.opacity(0.18), lineWidth: 9)
                Circle()
                    .trim(from: 0, to: min(CGFloat(progress), 1.0))
                    .stroke(color, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                // Overdone second lap (>100%) — thin inner ring
                if progress > 1.0 {
                    Circle()
                        .trim(from: 0, to: min(CGFloat(progress - 1.0), 1.0))
                        .stroke(color.opacity(0.55), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
            }
            .frame(width: 42, height: 42)

            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(color)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Color.primary)
                Text(unit)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            if let goal {
                Text(goal)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(Color(UIColor.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 10))
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

    // MARK: – Daily note

    @ViewBuilder
    private var noteSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                sectionLabel("Notes")
                Spacer()
                Button { showNotesView = true } label: {
                    Image(systemName: "note.text")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                // Move-to-tomorrow only relevant on the daily card
                if notePageIndex == 0 {
                    Button {
                        moveDailyNoteDate = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
                        showingMoveDailyNote = true
                    } label: {
                        Image(systemName: "arrow.right.square")
                            .font(.caption)
                            .foregroundStyle(notePlanContent.isEmpty ? .tertiary : .secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(notePlanContent.isEmpty)
                }
            }

            TabView(selection: $notePageIndex) {
                // Card 0 — Daily note
                noteCard(
                    label: dailyCardLabel,
                    labelColor: .accentColor,
                    isLoading: !notePlanLoaded,
                    isEmpty: notePlanContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    preview: notePlanPreviewAttributed,
                    emptyPrompt: "Long-press to add a note, or tap to open Notes…",
                    onTap: { showNotesView = true },
                    onLongPress: { showingQuickAppend = true }
                )
                .tag(0)

                // Card 1 — Week note
                noteCard(
                    label: weekLabel,
                    labelColor: .orange,
                    isLoading: false,
                    isEmpty: weekNoteContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    preview: horizonPreview(weekNoteContent),
                    emptyPrompt: "Tap to start this week's note…",
                    onTap: { showingWeekNote = true },
                    onLongPress: { showingWeekNote = true }
                )
                .tag(1)

                // Card 2 — Month note
                noteCard(
                    label: monthLabel,
                    labelColor: .blue,
                    isLoading: false,
                    isEmpty: monthNoteContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    preview: horizonPreview(monthNoteContent),
                    emptyPrompt: "Tap to start this month's note…",
                    onTap: { showingMonthNote = true },
                    onLongPress: { showingMonthNote = true }
                )
                .tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .frame(height: 130)
        }
        .sheet(isPresented: $showNotesView, onDismiss: {
            Task {
                if let content = try? NoteStore.shared.readDailyNote() {
                    notePlanContent = content
                }
            }
        }) {
            NotesView()
        }
        .sheet(isPresented: $showingWeekNote, onDismiss: {
            weekNoteContent = (try? NoteStore.shared.readFile(weekNoteRelativePath)) ?? ""
        }) {
            NavigationStack {
                NoteEditorView(relativePath: weekNoteRelativePath, title: weekLabel)
            }
        }
        .sheet(isPresented: $showingMonthNote, onDismiss: {
            monthNoteContent = (try? NoteStore.shared.readFile(monthNoteRelativePath)) ?? ""
        }) {
            NavigationStack {
                NoteEditorView(relativePath: monthNoteRelativePath, title: monthLabel)
            }
        }
        .sheet(isPresented: $showingQuickAppend) {
            QuickAppendSheet {
                notePlanContent = (try? NoteStore.shared.readDailyNote()) ?? ""
            }
        }
        .sheet(isPresented: $showingMoveDailyNote) {
            MoveDailyNoteSheet(targetDate: $moveDailyNoteDate) {
                Task {
                    try? NoteStore.shared.moveDailyNote(from: Date(), to: moveDailyNoteDate)
                    notePlanContent = (try? NoteStore.shared.readDailyNote()) ?? ""
                    showingMoveDailyNote = false
                }
            }
        }
    }

    @ViewBuilder
    private func noteCard(
        label: String,
        labelColor: Color,
        isLoading: Bool,
        isEmpty: Bool,
        preview: AttributedString,
        emptyPrompt: String,
        onTap: @escaping () -> Void,
        onLongPress: @escaping () -> Void
    ) -> some View {
        if isLoading {
            sectionCard {
                ProgressView().frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 2)
        } else {
            Button(action: onTap) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(label)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(labelColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(labelColor.opacity(0.12), in: Capsule())
                    if isEmpty {
                        Text(emptyPrompt)
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(preview)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                            .lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(UIColor.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .simultaneousGesture(LongPressGesture().onEnded { _ in onLongPress() })
            .padding(.horizontal, 2)
        }
    }

    // Renders the daily note preview with live bold/italic using SwiftUI's AttributedString
    // markdown parser. Heading and bullet prefixes are stripped; inline ** and * are rendered
    // as actual bold/italic so the preview matches what the user wrote.
    private var notePlanPreviewAttributed: AttributedString {
        var lines = notePlanContent.components(separatedBy: "\n")
        // Strip the date header (# YYYY-MM-DD) and leading blank lines
        if let first = lines.first,
           first.hasPrefix("# "),
           first.dropFirst(2).range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
            lines.removeFirst()
            while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
                lines.removeFirst()
            }
        }
        let preview = lines
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .prefix(3)
            .map { stripLinePrefix($0) }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined(separator: "\n")
        return styledPreview(preview)
    }

    // Strips heading/bullet/checkbox line prefixes only; leaves inline ** * ~~ for
    // AttributedString to render as bold/italic/strikethrough.
    private func stripLinePrefix(_ line: String) -> String {
        var s = line
        for prefix in ["### ", "## ", "# "] {
            if s.hasPrefix(prefix) { return String(s.dropFirst(prefix.count)) }
        }
        for prefix in ["- [x] ", "- [ ] ", "• ", "- "] {
            if s.hasPrefix(prefix) { return String(s.dropFirst(prefix.count)) }
        }
        return s
    }

    /// Builds an AttributedString from raw markdown preview text, manually handling
    /// **bold**, *italic*, ~~strikethrough~~, and ==highlight== (yellow bg). SwiftUI's
    /// built-in markdown parser doesn't understand ~~ or == syntax, so we do the full pass ourselves.
    private func styledPreview(_ raw: String) -> AttributedString {
        struct Span {
            let start: String.Index; let end: String.Index
            let inner: String
            let isBold: Bool; let isItalic: Bool; let isHighlight: Bool; let isStrike: Bool
        }
        var spans: [Span] = []

        func collect(pattern: String, markerLen: Int, bold: Bool, italic: Bool, highlight: Bool, strike: Bool = false) {
            guard let re = try? NSRegularExpression(pattern: pattern) else { return }
            let ns = raw as NSString
            for m in re.matches(in: raw, range: NSRange(raw.startIndex..., in: raw)) {
                guard let fullRange = Range(m.range, in: raw) else { continue }
                let innerNS = NSRange(location: m.range.location + markerLen,
                                     length: m.range.length - 2 * markerLen)
                guard innerNS.length > 0 else { continue }
                let inner = ns.substring(with: innerNS)
                spans.append(Span(start: fullRange.lowerBound, end: fullRange.upperBound,
                                  inner: inner, isBold: bold, isItalic: italic, isHighlight: highlight, isStrike: strike))
            }
        }
        collect(pattern: #"\*\*(.+?)\*\*"#,             markerLen: 2, bold: true,  italic: false, highlight: false)
        collect(pattern: #"(?<!\*)\*([^*\n]+)\*(?!\*)"#, markerLen: 1, bold: false, italic: true,  highlight: false)
        collect(pattern: "==(.+?)==",                    markerLen: 2, bold: false, italic: false, highlight: true)
        collect(pattern: #"~~(.+?)~~"#,                  markerLen: 2, bold: false, italic: false, highlight: false, strike: true)
        spans.sort { $0.start < $1.start }

        var result = AttributedString()
        var cursor = raw.startIndex

        func seg(_ str: String, bold: Bool = false, italic: Bool = false, highlight: Bool = false, strike: Bool = false) {
            guard !str.isEmpty else { return }
            var a = AttributedString(str)
            if bold        { a.font = .system(size: 14, weight: .semibold) }
            else if italic { a.font = .system(size: 14).italic() }
            else           { a.font = .system(size: 14) }
            if highlight   { a.backgroundColor = Color(UIColor.systemYellow.withAlphaComponent(0.4)) }
            if strike      { a.strikethroughStyle = .single }
            result += a
        }

        for span in spans {
            guard span.start >= cursor else { continue }
            seg(String(raw[cursor..<span.start]))
            seg(span.inner, bold: span.isBold, italic: span.isItalic, highlight: span.isHighlight, strike: span.isStrike)
            cursor = span.end
        }
        if cursor < raw.endIndex { seg(String(raw[cursor...])) }
        return result
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

    // MARK: - Horizons note helpers

    private var isoCal: Calendar = {
        var c = Calendar(identifier: .iso8601)
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()

    private var currentWeekFilename: String {
        let week = isoCal.component(.weekOfYear, from: Date())
        let year = isoCal.component(.yearForWeekOfYear, from: Date())
        return String(format: "%d-W%02d.md", year, week)
    }

    private var currentMonthFilename: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM"
        return "\(f.string(from: Date())).md"
    }

    private var weekNoteRelativePath: String { "Notes/Horizons/\(currentWeekFilename)" }
    private var monthNoteRelativePath: String { "Notes/Horizons/\(currentMonthFilename)" }

    private var weekLabel: String {
        let week = isoCal.component(.weekOfYear, from: Date())
        return "Week \(week)"
    }

    private var monthLabel: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMMM yyyy"
        return f.string(from: Date())
    }

    private var dailyCardLabel: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d"
        return "Daily · \(f.string(from: Date()))"
    }

    private func horizonPreview(_ raw: String) -> AttributedString {
        let lines = raw.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .prefix(3)
            .map { stripLinePrefix($0) }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return styledPreview(lines.joined(separator: "\n"))
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
            HStack(spacing: 6) {
                sectionLabel("Recent visits")
                Spacer()
                Button { showingVisitsView = true } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
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
        .sheet(isPresented: $showingVisitsView) {
            NavigationStack {
                VisitsView()
                    .environment(NotionService.shared)
                    .environment(LocationManager.shared)
            }
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
