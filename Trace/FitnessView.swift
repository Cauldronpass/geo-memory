import SwiftUI

// MARK: - Main Fitness View

struct FitnessView: View {
    @Environment(NotionService.self) private var notion
    @State private var showWizard = false
    @State private var showCalendar = false
    @State private var isLoading = false
    @State private var selectedWorkout: Workout? = nil
    @State private var showAll = false
    @State private var selectedPeriod: StatPeriod? = nil
    @State private var typeFilter: String? = nil

    private let typeOrder = ["OrangeTheory", "Run", "Bike", "Hike", "Lift"]

    private var sortedWorkouts: [Workout] {
        notion.workouts.sorted { $0.date > $1.date }
    }

    private var filteredWorkouts: [Workout] {
        guard let filter = typeFilter else { return sortedWorkouts }
        return sortedWorkouts.filter { $0.type == filter }
    }

    private var displayedWorkouts: [Workout] {
        showAll ? filteredWorkouts : Array(filteredWorkouts.prefix(5))
    }

    private var availableTypes: [String] {
        let used = Set(sortedWorkouts.map { $0.type })
        let ordered = typeOrder.filter { used.contains($0) }
        let extras = used.subtracting(Set(typeOrder)).sorted()
        return ordered + extras
    }

    private func workoutsIn(_ period: StatPeriod) -> [Workout] {
        let cal = Calendar.current
        let now = Date()
        switch period {
        case .week:
            let start = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))!
            return sortedWorkouts.filter { $0.date >= start }
        case .month:
            let start = cal.date(from: cal.dateComponents([.year, .month], from: now))!
            return sortedWorkouts.filter { $0.date >= start }
        case .allTime:
            return sortedWorkouts
        }
    }

    private func miles(_ workouts: [Workout]) -> Double {
        workouts.compactMap { $0.distance }.reduce(0, +)
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && notion.workouts.isEmpty {
                    ProgressView("Loading…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if showCalendar {
                    ScrollView {
                        FitnessCalendarView(workouts: sortedWorkouts)
                            .environment(notion)
                            .padding(.vertical)
                    }
                } else {
                    List {
                        statsSection
                        if !sortedWorkouts.isEmpty {
                            typeFilterSection
                        }
                        workoutsSection
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Fitness")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showWizard = true } label: { Image(systemName: "plus") }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        withAnimation { showCalendar.toggle() }
                    } label: {
                        Image(systemName: showCalendar ? "list.bullet" : "calendar")
                    }
                }
            }
            .task {
                isLoading = true
                await notion.fetchWorkouts()
                isLoading = false
            }
            .refreshable { await notion.fetchWorkouts() }
            .sheet(isPresented: $showWizard) {
                WorkoutWizardView().environment(notion)
            }
            .sheet(item: $selectedWorkout) { w in
                WorkoutDetailView(workout: w).environment(notion)
            }
            .sheet(item: $selectedPeriod) { period in
                PeriodWorkoutListSheet(period: period, workouts: workoutsIn(period))
                    .environment(notion)
            }
        }
        .drawerToolbar()
    }

    // MARK: - Stats

    @ViewBuilder
    private var statsSection: some View {
        Section {
            HStack(spacing: 0) {
                ForEach(StatPeriod.allCases) { period in
                    let ws = workoutsIn(period)
                    let mi = miles(ws)
                    Button { selectedPeriod = period } label: {
                        VStack(spacing: 6) {
                            Text(period.label)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                                .tracking(0.5)
                            Text("\(ws.count)")
                                .font(.title3.bold())
                                .foregroundStyle(.primary)
                            Text("workouts")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            if mi > 0 {
                                Text(String(format: "%.1f mi", mi))
                                    .font(.caption.bold())
                                    .foregroundStyle(.orange)
                            } else {
                                Text("— mi")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if period != .allTime {
                        Divider().frame(height: 60)
                    }
                }
            }
            .padding(.vertical, 10)
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
    }

    // MARK: - Type filter chips

    @ViewBuilder
    private var typeFilterSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(availableTypes, id: \.self) { type in
                        typeFilterChip(type)
                    }
                    if typeFilter != nil {
                        Button {
                            typeFilter = nil
                        } label: {
                            Text("Clear")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
        }
        .listRowBackground(Color.clear)
    }

    private func chipColor(for type: String) -> Color {
        switch type {
        case "OrangeTheory": return .orange
        case "Run":          return .blue
        case "Bike":         return .green
        case "Hike":         return .brown
        case "Lift":         return .purple
        default:             return .gray
        }
    }

    private func chipLabel(for type: String) -> String {
        switch type {
        case "OrangeTheory": return "OTF"
        default: return type
        }
    }

    private func typeFilterChip(_ type: String) -> some View {
        let isActive = typeFilter == type
        return Button {
            typeFilter = isActive ? nil : type
        } label: {
            Text(chipLabel(for: type))
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isActive ? chipColor(for: type) : Color(.secondarySystemGroupedBackground))
                .foregroundStyle(isActive ? .white : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Workouts list

    @ViewBuilder
    private var workoutsSection: some View {
        Section("Recent") {
            if sortedWorkouts.isEmpty {
                Text("No workouts logged yet")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            } else if filteredWorkouts.isEmpty {
                Text("No \(chipLabel(for: typeFilter ?? "")) workouts logged yet")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            } else {
                ForEach(displayedWorkouts) { w in
                    Button { selectedWorkout = w } label: { WorkoutRow(workout: w) }
                        .buttonStyle(.plain)
                }
                if filteredWorkouts.count > 5 {
                    Button {
                        withAnimation { showAll.toggle() }
                    } label: {
                        Text(showAll ? "Show less" : "Show all \(filteredWorkouts.count) workouts")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Stat Period

enum StatPeriod: String, CaseIterable, Identifiable {
    case week, month, allTime
    var id: String { rawValue }
    var label: String {
        switch self {
        case .week: return "This Week"
        case .month: return "This Month"
        case .allTime: return "All Time"
        }
    }
}

// MARK: - Workout Row

struct WorkoutRow: View {
    let workout: Workout
    private let feelEmoji = ["", "😴", "😕", "😐", "🙂", "😊", "💪", "🔥"]

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(typeColor.opacity(0.15))
                    .frame(width: 44, height: 44)
                Image(systemName: typeIcon)
                    .font(.system(size: 20))
                    .foregroundStyle(typeColor)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(workout.name.isEmpty ? workout.type : workout.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                HStack(spacing: 5) {
                    Text(workout.date.formatted(.dateTime.month(.abbreviated).day()))
                        .font(.caption).foregroundStyle(.secondary)
                    if let dur = workout.duration {
                        dot; Text("\(dur) min").font(.caption).foregroundStyle(.secondary)
                    }
                    if let dist = workout.distance {
                        dot; Text(String(format: "%.2f mi", dist)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                let hasSub = workout.splatPoints != nil || workout.feel != nil
                if hasSub {
                    HStack(spacing: 5) {
                        if let splats = workout.splatPoints {
                            Text("🔥 \(splats) splats").font(.caption).foregroundStyle(.orange)
                        }
                        if let feel = workout.feel, feel >= 1, feel <= 7 {
                            if workout.splatPoints != nil { dot }
                            Text("\(feelEmoji[feel]) \(feel)/7").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(workout.date.formatted(.dateTime.weekday(.abbreviated)))
                    .font(.subheadline.weight(.medium))
                if let cal = workout.calories {
                    Text("\(cal) cal").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var dot: some View {
        Text("·").font(.caption).foregroundStyle(.tertiary)
    }

    var typeColor: Color {
        switch workout.type {
        case "OrangeTheory": return .orange
        case "Run":          return .blue
        case "Bike":         return .green
        case "Hike":         return .brown
        case "Lift":         return .purple
        default:             return .gray
        }
    }

    var typeIcon: String {
        switch workout.type {
        case "OrangeTheory": return "flame.fill"
        case "Run":          return "figure.run"
        case "Bike":         return "figure.outdoor.cycle"
        case "Hike":         return "figure.hiking"
        case "Lift":         return "dumbbell.fill"
        default:             return "figure.mixed.cardio"
        }
    }
}

// MARK: - Period Workout List Sheet

struct PeriodWorkoutListSheet: View {
    let period: StatPeriod
    let workouts: [Workout]
    @Environment(NotionService.self) private var notion
    @Environment(\.dismiss) private var dismiss
    @State private var selectedWorkout: Workout? = nil

    private func miles() -> Double {
        workouts.compactMap { $0.distance }.reduce(0, +)
    }

    var body: some View {
        NavigationStack {
            List {
                // Summary banner
                Section {
                    HStack(spacing: 24) {
                        VStack(spacing: 2) {
                            Text("\(workouts.count)").font(.title2.bold())
                            Text("workouts").font(.caption).foregroundStyle(.secondary)
                        }
                        let mi = miles()
                        if mi > 0 {
                            VStack(spacing: 2) {
                                Text(String(format: "%.1f", mi)).font(.title2.bold()).foregroundStyle(.orange)
                                Text("miles").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        let cals = workouts.compactMap { $0.calories }.reduce(0, +)
                        if cals > 0 {
                            VStack(spacing: 2) {
                                Text("\(cals)").font(.title2.bold())
                                Text("kcal").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }

                // Workout rows
                Section {
                    if workouts.isEmpty {
                        Text("No workouts in this period")
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                    } else {
                        ForEach(workouts) { w in
                            Button { selectedWorkout = w } label: { WorkoutRow(workout: w) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(period.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $selectedWorkout) { w in
                WorkoutDetailView(workout: w).environment(notion)
            }
        }
    }
}

// MARK: - Fitness Calendar View (thin wrapper over CalendarGridView)

struct FitnessCalendarView: View {
    let workouts: [Workout]
    @Environment(NotionService.self) private var notion
    @State private var selectedWorkout: Workout?
    @State private var multipleWorkouts: [Workout]?

    private func workoutColor(_ w: Workout) -> Color {
        switch w.type {
        case "OrangeTheory": return .orange
        case "Run":          return .blue
        case "Bike":         return .green
        case "Hike":         return .brown
        case "Lift":         return .purple
        default:             return .gray
        }
    }

    private func workoutCellStat(_ w: Workout) -> String? {
        if let s = w.splatPoints { return "\(s)🔥" }
        if let d = w.distance    { return String(format: "%.1f", d) }
        if let c = w.calories    { return "\(c)" }
        return String(w.type.prefix(1))
    }

    private var entries: [CalendarEntry] {
        workouts.map { w in
            CalendarEntry(
                id: w.id,
                date: w.date,
                color: workoutColor(w),
                cellStat: workoutCellStat(w),
                displayName: w.name.isEmpty ? w.type : w.name,
                value: w.distance
            )
        }
    }

    private func monthStats(_ monthEntries: [CalendarEntry]) -> [(String, String)] {
        let ids = Set(monthEntries.map { $0.id })
        let ws = workouts.filter { ids.contains($0.id) }
        let miles = ws.compactMap { $0.distance }.reduce(0, +)
        let cals  = ws.compactMap { $0.calories  }.reduce(0, +)
        var stats: [(String, String)] = [
            ("\(ws.count)", "workouts"),
            (miles > 0 ? String(format: "%.1f mi", miles) : "— mi", "distance")
        ]
        if cals > 0 { stats.append(("\(cals)", "calories")) }
        return stats
    }

    var body: some View {
        CalendarGridView(
            entries: entries,
            weekSecondary: { weekEntries in
                let miles = weekEntries.compactMap { $0.value }.reduce(0, +)
                return miles > 0 ? String(format: "%.1f", miles) : nil
            },
            monthStats: monthStats,
            onSelect: { dayEntries in
                if dayEntries.count == 1 {
                    selectedWorkout = workouts.first { $0.id == dayEntries[0].id }
                } else {
                    multipleWorkouts = dayEntries.compactMap { e in workouts.first { $0.id == e.id } }
                }
            }
        )
        .sheet(item: $selectedWorkout) { w in
            WorkoutDetailView(workout: w).environment(notion)
        }
        .confirmationDialog("Choose Workout", isPresented: Binding(
            get: { multipleWorkouts != nil },
            set: { if !$0 { multipleWorkouts = nil } }
        ), titleVisibility: .visible) {
            ForEach(multipleWorkouts ?? []) { w in
                Button(w.name.isEmpty ? w.type : w.name) {
                    selectedWorkout = w
                    multipleWorkouts = nil
                }
            }
            Button("Cancel", role: .cancel) { multipleWorkouts = nil }
        }
    }
}

// MARK: - Workout Detail View

struct WorkoutDetailView: View {
    let workout: Workout
    @Environment(NotionService.self) private var notion
    @Environment(\.dismiss) private var dismiss

    @State private var editNotes: String = ""
    @State private var editFeel: Int = 0
    @State private var isSavingNotes = false
    @State private var notesSaved = false
    @State private var isSavingFeel = false
    @State private var feelSaved = false
    @State private var isEditingNotes = false

    private let feelEmoji = ["", "😴", "😕", "😐", "🙂", "😊", "💪", "🔥"]
    private var notesChanged: Bool { editNotes != (workout.notes ?? "") }
    private var feelChanged: Bool { editFeel != (workout.feel ?? 0) && editFeel > 0 }

    private var notionURL: URL? {
        let clean = workout.id.replacingOccurrences(of: "-", with: "")
        return URL(string: "https://www.notion.so/\(clean)")
    }

    var body: some View {
        NavigationStack {
            List {
                // Header
                Section {
                    HStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(typeColor.opacity(0.15))
                                .frame(width: 52, height: 52)
                            Image(systemName: typeIcon)
                                .font(.system(size: 24))
                                .foregroundStyle(typeColor)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(workout.name.isEmpty ? workout.type : workout.name)
                                .font(.headline)
                            Text(workout.date.formatted(.dateTime.weekday(.wide).month(.wide).day().year()))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                // Summary
                Section("Summary") {
                    if let dur = workout.duration    { row("Duration", "\(dur) min") }
                    if let cal = workout.calories    { row("Calories", "\(cal) kcal") }
                    if let ha  = workout.heartRateAvg { row("HR Avg", "\(ha) bpm") }
                    if let hm  = workout.heartRateMax { row("HR Max", "\(hm) bpm") }

                    // Feel — editable
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Feel").foregroundStyle(.secondary)
                            Spacer()
                            if editFeel > 0 {
                                Text("\(feelEmoji[editFeel]) \(editFeel)/7").fontWeight(.medium)
                            } else {
                                Text("—").foregroundStyle(.tertiary)
                            }
                        }
                        HStack(spacing: 6) {
                            ForEach(1...7, id: \.self) { val in
                                Button {
                                    editFeel = val
                                } label: {
                                    Text(feelEmoji[val])
                                        .font(.title3)
                                        .padding(6)
                                        .background(
                                            editFeel == val ? Color.orange.opacity(0.2) : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 8)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        if feelChanged {
                            Button { Task { await saveFeel() } } label: {
                                HStack {
                                    if isSavingFeel { ProgressView().scaleEffect(0.8) }
                                    else if feelSaved { Image(systemName: "checkmark").foregroundStyle(.green) }
                                    Text(feelSaved ? "Saved" : "Save Rating")
                                }
                                .frame(maxWidth: .infinity).font(.subheadline)
                            }
                            .disabled(isSavingFeel)
                        }
                    }
                    .padding(.vertical, 4)
                }

                // OTF
                if workout.isOTF {
                    Section("OTF") {
                        if let ct = workout.classType   { row("Class Type", ct) }
                        if let sp = workout.splatPoints  { row("Splat Points", "\(sp)") }
                        if let op = workout.output       { row("Output", "\(op) W") }
                    }

                    let allZones: [(String, Color, Int?)] = [
                        ("Gray (Z1)",   .gray,   workout.zone1),
                        ("Blue (Z2)",   .blue,   workout.zone2),
                        ("Green (Z3)",  .green,  workout.zone3),
                        ("Orange (Z4)", .orange, workout.zone4),
                        ("Red (Z5)",    .red,    workout.zone5)
                    ]
                    let filledZones = allZones.filter { $0.2 != nil }
                    let zoneTotal = filledZones.compactMap { $0.2 }.reduce(0, +)
                    if !filledZones.isEmpty {
                        Section("Zone Minutes") {
                            ForEach(filledZones, id: \.0) { label, color, val in
                                let mins = val!
                                let pct = zoneTotal > 0 ? Int((Double(mins) / Double(zoneTotal) * 100).rounded()) : 0
                                HStack {
                                    Text(label).foregroundStyle(color).fontWeight(.medium)
                                    Spacer()
                                    Text("\(mins) min").fontWeight(.medium)
                                    Text("· \(pct)%").foregroundStyle(.secondary).font(.subheadline)
                                }
                            }
                        }
                    }
                }

                // Cardio
                let hasCardio = workout.distance != nil || workout.steps != nil
                    || workout.treadPace != nil || workout.elevation != nil
                if hasCardio {
                    Section("Treadmill / Cardio") {
                        if let d = workout.distance  { row("Distance",  String(format: "%.2f mi", d)) }
                        if let s = workout.steps     { row("Steps",     "\(s)") }
                        if let p = workout.treadPace { row("Avg Pace",  "\(p) min/mi") }
                        if let e = workout.elevation { row("Elevation", String(format: "%.0f ft", e)) }
                    }
                }

                // Rower
                if workout.hasRower == true {
                    Section("Rower") {
                        if let d = workout.rowerDistance  { row("Distance",    "\(d) m") }
                        if let w = workout.rowerWattsAvg  { row("Avg Watts",   "\(w) W") }
                        if let p = workout.rowerPace      { row("500m Pace",   p) }
                        if let s = workout.rowerStrokeAvg { row("Stroke Rate", "\(s) spm") }
                    }
                }

                // Notes
                Section {
                    if isEditingNotes {
                        ZStack(alignment: .topLeading) {
                            TextEditor(text: $editNotes)
                                .frame(minHeight: 120)
                                .scrollContentBackground(.hidden)
                            if editNotes.isEmpty {
                                Text("Add a note…")
                                    .foregroundStyle(Color(.placeholderText))
                                    .padding(.top, 8).padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }
                        if notesChanged {
                            Button { Task { await saveNotes() } } label: {
                                HStack {
                                    if isSavingNotes { ProgressView().scaleEffect(0.8) }
                                    else if notesSaved { Image(systemName: "checkmark").foregroundStyle(.green) }
                                    Text(notesSaved ? "Saved" : "Save Notes")
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .disabled(isSavingNotes)
                        }
                        Button("Done Editing") {
                            isEditingNotes = false
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                    } else {
                        if editNotes.isEmpty {
                            Text("No notes")
                                .foregroundStyle(.tertiary)
                                .italic()
                        } else {
                            Text(editNotes)
                                .font(.body)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Button {
                            isEditingNotes = true
                        } label: {
                            Label(editNotes.isEmpty ? "Add Note" : "Edit", systemImage: editNotes.isEmpty ? "plus" : "pencil")
                                .font(.subheadline)
                                .foregroundStyle(.orange)
                        }
                    }
                } header: {
                    Text("Notes")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if let url = notionURL {
                        Link(destination: url) {
                            Image(systemName: "arrow.up.right.square")
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                editNotes = workout.notes ?? ""
                editFeel = workout.feel ?? 0
                isEditingNotes = false
            }
        }
    }

    private func saveNotes() async {
        isSavingNotes = true
        try? await notion.updateWorkoutNotes(workout.id, notes: editNotes)
        isSavingNotes = false
        notesSaved = true
        try? await Task.sleep(for: .seconds(1.5))
        notesSaved = false
    }

    private func saveFeel() async {
        isSavingFeel = true
        try? await notion.updateWorkoutFeel(workout.id, feel: editFeel)
        isSavingFeel = false
        feelSaved = true
        try? await Task.sleep(for: .seconds(1.5))
        feelSaved = false
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.medium)
        }
    }

    private var typeColor: Color {
        switch workout.type {
        case "OrangeTheory": return .orange
        case "Run":  return .blue
        case "Bike": return .green
        case "Hike": return .brown
        case "Lift": return .purple
        default:     return .gray
        }
    }

    private var typeIcon: String {
        switch workout.type {
        case "OrangeTheory": return "flame.fill"
        case "Run":  return "figure.run"
        case "Bike": return "figure.outdoor.cycle"
        case "Hike": return "figure.hiking"
        case "Lift": return "dumbbell.fill"
        default:     return "figure.mixed.cardio"
        }
    }
}
