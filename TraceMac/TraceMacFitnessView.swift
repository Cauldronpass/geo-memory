// TraceMacFitnessView.swift
// Browse and log workouts from Mac.
// Mac-only — do not add to iOS, Widget, or Share Extension targets.
//
// Data model: `Workout` + `WorkoutDraft` (Models.swift)
// API:        notion.fetchWorkouts() / logWorkout(_:) / updateWorkoutNotes(_:notes:)

import SwiftUI
import PhotosUI

// MARK: - Stat period (iOS parity — This Week / This Month / All Time)

private enum FitnessStatPeriod: String, CaseIterable, Identifiable {
    case week, month, allTime
    var id: String { rawValue }
    var label: String {
        switch self {
        case .week:    return "This Week"
        case .month:   return "This Month"
        case .allTime: return "All Time"
        }
    }
}

// MARK: - Main view

struct TraceMacFitnessView: View {
    @Environment(NotionService.self) private var notion

    @State private var selectedID:   String?
    @State private var showNewSheet  = false
    @State private var searchText    = ""
    @State private var typeFilter:   String? = nil
    @State private var isLoading     = false
    @State private var listCollapsed = false

    private let typeOrder = ["OrangeTheory", "Run", "Bike", "Hike", "Lift"]

    private var sortedWorkouts: [Workout] {
        notion.workouts.sorted { $0.date > $1.date }
    }

    private var availableTypes: [String] {
        let used    = Set(sortedWorkouts.map { $0.type })
        let ordered = typeOrder.filter { used.contains($0) }
        let extras  = used.subtracting(Set(typeOrder)).sorted()
        return ordered + extras
    }

    private var filteredWorkouts: [Workout] {
        var base = sortedWorkouts
        if let filter = typeFilter {
            base = base.filter { $0.type == filter }
        }
        guard !searchText.isEmpty else { return base }
        let q = searchText.lowercased()
        return base.filter {
            $0.name.lowercased().contains(q) ||
            $0.type.lowercased().contains(q) ||
            ($0.notes?.lowercased().contains(q) ?? false)
        }
    }

    private var selectedWorkout: Workout? {
        filteredWorkouts.first { $0.id == selectedID }
    }

    // Stats for the header strip — This Week / This Month / All Time (iOS parity)
    private func workoutsIn(_ period: FitnessStatPeriod) -> [Workout] {
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
        VStack(spacing: 0) {
            // Pinned header — always visible, not just in the empty-state
            // placeholder (that was the old behavior; iOS shows this at the
            // top of the screen regardless of selection).
            statsStrip
            Divider()

            HStack(spacing: 0) {
                // Left column — list
                if !listCollapsed {
                    VStack(spacing: 0) {
                        searchBar
                        if !availableTypes.isEmpty { typeFilterBar }
                        Divider()
                        if sortedWorkouts.isEmpty && isLoading {
                            ProgressView("Loading workouts…")
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if filteredWorkouts.isEmpty {
                            emptyState
                        } else {
                            List(filteredWorkouts, id: \.id, selection: $selectedID) { workout in
                                WorkoutRow(workout: workout)
                                    .tag(workout.id)
                            }
                            .listStyle(.sidebar)
                            .scrollContentBackground(.hidden)
                            .background(Color(nsColor: .windowBackgroundColor))
                        }
                    }
                    .frame(width: 260)
                }

                CollapseHandle(isCollapsed: $listCollapsed, collapsesRight: false, showLine: true, panelColor: .clear)

                // Right column — detail
                Group {
                    if let workout = selectedWorkout {
                        WorkoutDetailPanel(workout: workout)
                            .environment(notion)
                            .id(workout.id)
                    } else {
                        placeholderDetail
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showNewSheet = true } label: {
                    Label("Log Workout", systemImage: "plus")
                }
                .help("Log a workout (⌘N)")
                .keyboardShortcut("n", modifiers: .command)
            }
        }
        .task {
            isLoading = true
            await notion.fetchWorkouts()
            isLoading = false
        }
        .sheet(isPresented: $showNewSheet) {
            NewWorkoutSheet()
                .environment(notion)
        }
    }

    // MARK: - Sub-views

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.subheadline)
            TextField("Search workouts", text: $searchText)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var typeFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                filterChip("All", isActive: typeFilter == nil) {
                    typeFilter = nil
                }
                ForEach(availableTypes, id: \.self) { type in
                    filterChip(type, isActive: typeFilter == type) {
                        typeFilter = (typeFilter == type) ? nil : type
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func filterChip(_ label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption)
                .fontWeight(isActive ? .semibold : .regular)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(isActive ? Color.accentColor.opacity(0.2) : Color(nsColor: .tertiarySystemFill))
                .foregroundStyle(isActive ? Color.accentColor : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "figure.run")
                .font(.system(size: 40, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            Text(typeFilter != nil ? "No \(typeFilter!) workouts" : "No workouts yet")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var placeholderDetail: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "figure.run")
                .font(.system(size: 48, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            Text("Select a workout")
                .font(.title3)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // This Week / This Month / All Time — matches iOS FitnessView.statsSection.
    private var statsStrip: some View {
        HStack(spacing: 0) {
            ForEach(FitnessStatPeriod.allCases) { period in
                let ws = workoutsIn(period)
                let mi = miles(ws)
                VStack(spacing: 4) {
                    Text(period.label.uppercased())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .tracking(0.5)
                    Text("\(ws.count)")
                        .font(.title2)
                        .fontWeight(.semibold)
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
                if period != .allTime {
                    Divider().frame(height: 50)
                }
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 24)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

// MARK: - Workout row

private struct WorkoutRow: View {
    let workout: Workout
    // Same emoji ladder as iOS FitnessView.WorkoutRow.
    private let feelEmoji = ["", "😴", "😕", "😐", "🙂", "😊", "💪", "🔥"]

    private var typeColor: Color {
        switch workout.type {
        case "OrangeTheory": return .orange
        case "Run":          return .green
        case "Bike":         return .blue
        case "Hike":         return Color(hex: "16A34A")
        case "Lift":         return .purple
        default:             return .gray
        }
    }

    private var typeIcon: String {
        switch workout.type {
        case "OrangeTheory": return "flame.fill"
        case "Run":          return "figure.run"
        case "Bike":         return "figure.outdoor.cycle"
        case "Hike":         return "figure.hiking"
        case "Lift":         return "dumbbell.fill"
        default:             return "figure.mixed.cardio"
        }
    }

    private var dot: some View {
        Text("·").font(.caption).foregroundStyle(.tertiary)
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(typeColor.opacity(0.15))
                    .frame(width: 34, height: 34)
                Image(systemName: typeIcon)
                    .font(.system(size: 15))
                    .foregroundStyle(typeColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(workout.type)
                        .font(.callout)
                        .fontWeight(.medium)
                    if let ct = workout.classType {
                        Text(ct)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)

                HStack(spacing: 4) {
                    Text(workout.date, format: .dateTime.month(.abbreviated).day())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let dur = workout.duration {
                        dot
                        Text("\(dur) min").font(.caption).foregroundStyle(.secondary)
                    }
                    if let dist = workout.distance {
                        dot
                        Text(String(format: "%.2f mi", dist)).font(.caption).foregroundStyle(.secondary)
                    }
                }

                let hasSub = workout.splatPoints != nil || workout.feel != nil
                if hasSub {
                    HStack(spacing: 4) {
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

            VStack(alignment: .trailing, spacing: 3) {
                Text(workout.date, format: .dateTime.weekday(.abbreviated))
                    .font(.caption)
                    .fontWeight(.medium)
                if let cal = workout.calories {
                    Text("\(cal) cal").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Workout detail panel

private struct WorkoutDetailPanel: View {
    @Environment(NotionService.self) private var notion

    let workout: Workout

    @State private var notes:        String = ""
    @State private var isSavingNotes = false
    @State private var saveError:    String?
    @State private var showEditSheet = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                headerBlock
                metricsBlock
                if workout.isOTF { otfBlock }
                notesBlock
            }
            .padding(28)
        }
        .onAppear { notes = workout.notes ?? "" }
        .sheet(isPresented: $showEditSheet) {
            EditWorkoutSheet(workout: workout)
                .environment(notion)
        }
    }

    // MARK: Header

    private var headerBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(workout.name.isEmpty ? workout.type : workout.name)
                    .font(.title)
                    .fontWeight(.semibold)
                if let ct = workout.classType {
                    Text(ct)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Edit") { showEditSheet = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            Text(workout.date, format: .dateTime.weekday(.wide).month(.wide).day().year())
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Metrics

    private var metricsBlock: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            if let dur = workout.duration { metricCell("Duration", "\(dur) min") }
            if let cal = workout.calories { metricCell("Calories", "\(cal)") }
            if let hr = workout.heartRateAvg { metricCell("Avg HR", "\(hr) bpm") }
            if let hrm = workout.heartRateMax { metricCell("Max HR", "\(hrm) bpm") }
            if let dist = workout.distance { metricCell("Distance", String(format: "%.2f mi", dist)) }
            if let feel = workout.feel { metricCell("Feel", "\(feel)/7") }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func metricCell(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.headline)
                .fontWeight(.semibold)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: OTF zones

    private var otfBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("OrangeTheory")
                .font(.headline)

            HStack(spacing: 0) {
                otfZone("Gray",   workout.zone1, color: Color(nsColor: .systemGray))
                otfZone("Blue",   workout.zone2, color: .blue)
                otfZone("Green",  workout.zone3, color: .green)
                otfZone("Orange", workout.zone4, color: .orange)
                otfZone("Red",    workout.zone5, color: .red)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))

            HStack(spacing: 16) {
                if let sp = workout.splatPoints { infoRow("Splat Points", "\(sp)") }
                if let out = workout.output     { infoRow("Output", "\(out) W") }
                if let steps = workout.steps    { infoRow("Steps", "\(steps)") }
            }
        }
    }

    private func otfZone(_ name: String, _ minutes: Int?, color: Color) -> some View {
        let min = minutes ?? 0
        return VStack(spacing: 2) {
            Rectangle()
                .fill(color)
                .frame(height: 8)
            Text("\(min)m")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Notes

    private var notesBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notes")
                .font(.headline)

            TextEditor(text: $notes)
                .font(.body)
                .frame(minHeight: 100, maxHeight: 220)
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                )

            if let err = saveError {
                Text(err).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button {
                    Task { await saveNotes() }
                } label: {
                    if isSavingNotes {
                        ProgressView().scaleEffect(0.7)
                    } else {
                        Text("Save Notes")
                    }
                }
                .disabled(isSavingNotes || notes == (workout.notes ?? ""))
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            Text(value).fontWeight(.medium)
        }
        .font(.subheadline)
    }

    private func saveNotes() async {
        isSavingNotes = true
        saveError = nil
        do {
            try await notion.updateWorkoutNotes(workout.id, notes: notes)
        } catch {
            saveError = error.localizedDescription
        }
        isSavingNotes = false
    }
}

// MARK: - New workout sheet

private struct NewWorkoutSheet: View {
    @Environment(NotionService.self) private var notion
    @Environment(\.dismiss) private var dismiss

    @State private var draft       = WorkoutDraft()
    @State private var isSaving    = false
    @State private var saveError:  String?

    // String inputs for optional numeric fields
    @State private var durationStr     = ""
    @State private var caloriesStr     = ""
    @State private var heartRateAvgStr = ""
    @State private var heartRateMaxStr = ""
    @State private var splatPointsStr  = ""

    // OT scan state
    @State private var scanPickerItem: PhotosPickerItem?
    @State private var isScanning   = false
    @State private var scanError:   String?
    @State private var scanComplete = false

    private let types      = ["OrangeTheory", "Run", "Bike", "Hike", "Lift", "Other"]
    private let classTypes = ["Tread 50", "2G", "3G", "Strength 50", "Tornado"]
    private let feelLabels = ["1 — Drained", "2 — Tired", "3 — Moderate", "4 — Solid", "5 — Good", "6 — Great", "7 — Best"]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Log Workout")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { Task { await save() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .padding()

            Divider()

            Form {
                DatePicker("Date", selection: Binding(
                    get: { draft.date ?? Date() },
                    set: { draft.date = $0 }
                ), displayedComponents: .date)
                .datePickerStyle(.compact)

                Picker("Type", selection: $draft.type) {
                    ForEach(types, id: \.self) { Text($0).tag($0) }
                }

                if draft.type == "OrangeTheory" {
                    Picker("Class Type", selection: Binding(
                        get: { draft.classType ?? "" },
                        set: { draft.classType = $0.isEmpty ? nil : $0 }
                    )) {
                        Text("—").tag("")
                        ForEach(classTypes, id: \.self) { Text($0).tag($0) }
                    }
                }

                TextField("Duration (min)", text: $durationStr)
                TextField("Calories", text: $caloriesStr)
                TextField("Avg Heart Rate", text: $heartRateAvgStr)
                TextField("Max Heart Rate", text: $heartRateMaxStr)

                if draft.type == "OrangeTheory" {
                    TextField("Splat Points", text: $splatPointsStr)

                    LabeledContent("Scan") {
                        HStack(spacing: 8) {
                            if isScanning {
                                ProgressView().scaleEffect(0.75)
                            } else {
                                PhotosPicker(
                                    selection: $scanPickerItem,
                                    matching: .images,
                                    photoLibrary: .shared()
                                ) {
                                    Label("Scan Screenshot", systemImage: "camera.viewfinder")
                                }
                                .buttonStyle(.bordered)
                                .help("Pick an OT summary screenshot from Photos to auto-fill stats")
                            }
                            if scanComplete {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .transition(.scale)
                            }
                        }
                    }
                    .onChange(of: scanPickerItem) { _, item in
                        guard let item else { return }
                        Task { await scanFromPickerItem(item) }
                    }

                    if let err = scanError {
                        Text(err).font(.caption).foregroundStyle(.red)
                    }
                }

                Picker("Feel", selection: Binding(
                    get: { draft.feel ?? 0 },
                    set: { draft.feel = $0 == 0 ? nil : $0 }
                )) {
                    Text("—").tag(0)
                    ForEach(1...7, id: \.self) { i in
                        Text(feelLabels[i - 1]).tag(i)
                    }
                }

                LabeledContent("Notes") {
                    TextEditor(text: Binding(
                        get: { draft.notes ?? "" },
                        set: { draft.notes = $0.isEmpty ? nil : $0 }
                    ))
                    .frame(height: 70)
                }
            }
            .formStyle(.grouped)
            .padding(.horizontal)

            if let err = saveError {
                Text(err).font(.caption).foregroundStyle(.red).padding(.horizontal)
            }
        }
        .frame(width: 460, height: 580)
    }

    // MARK: - OT Scan

    private func scanFromPickerItem(_ item: PhotosPickerItem) async {
        isScanning   = true
        scanError    = nil
        scanComplete = false
        defer { isScanning = false }

        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                scanError = "Could not load photo."
                return
            }
            let result = try await OTScanService.scan(imageData: data)
            applyOTScanResult(result)
            withAnimation { scanComplete = true }
        } catch {
            scanError = error.localizedDescription
        }
    }

    private func applyOTScanResult(_ result: OTScanResult) {
        if let v = result.splatPoints,      v > 0 { splatPointsStr  = "\(v)" }
        if let v = result.calories,         v > 0 { caloriesStr     = "\(v)" }
        if let v = result.durationMinutes,  v > 0 { durationStr     = "\(v)" }
        if let v = result.maxHr,            v > 0 { heartRateMaxStr = "\(v)" }
        if let v = result.avgHr,            v > 0 { heartRateAvgStr = "\(v)" }
        if let d = result.classDate {
            let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
            if let date = df.date(from: d) { draft.date = date }
        }
    }

    private func save() async {
        draft.duration     = Int(durationStr)
        draft.calories     = Int(caloriesStr)
        draft.heartRateAvg = Int(heartRateAvgStr)
        draft.heartRateMax = Int(heartRateMaxStr)
        draft.splatPoints  = Int(splatPointsStr)

        // Build a name from type + date
        let df = DateFormatter(); df.dateFormat = "M/d"
        draft.name = "\(draft.type) · \(df.string(from: draft.date ?? Date()))"

        isSaving  = true
        saveError = nil
        do {
            _ = try await notion.logWorkout(draft)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
        isSaving = false
    }
}

// MARK: - Edit workout sheet

private struct EditWorkoutSheet: View {
    @Environment(NotionService.self) private var notion
    @Environment(\.dismiss) private var dismiss

    let workout: Workout

    @State private var draft         = WorkoutDraft()
    @State private var isSaving          = false
    @State private var saveError:        String?
    @State private var scanPickerItem:   PhotosPickerItem?
    @State private var isScanning        = false
    @State private var scanError:        String?
    @State private var scanComplete      = false

    @State private var durationStr     = ""
    @State private var caloriesStr     = ""
    @State private var heartRateAvgStr = ""
    @State private var heartRateMaxStr = ""
    @State private var splatPointsStr  = ""
    @State private var stepsStr        = ""

    private let types      = ["OrangeTheory", "Run", "Bike", "Hike", "Lift", "Other"]
    private let classTypes = ["Tread 50", "2G", "3G", "Strength 50", "Tornado"]
    private let feelLabels = ["1 — Drained", "2 — Tired", "3 — Moderate", "4 — Solid", "5 — Good", "6 — Great", "7 — Best"]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Edit Workout")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { Task { await save() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .padding()

            Divider()

            Form {
                DatePicker("Date", selection: Binding(
                    get: { draft.date ?? Date() },
                    set: { draft.date = $0 }
                ), displayedComponents: .date)
                .datePickerStyle(.compact)

                Picker("Type", selection: $draft.type) {
                    ForEach(types, id: \.self) { Text($0).tag($0) }
                }

                if draft.type == "OrangeTheory" {
                    Picker("Class Type", selection: Binding(
                        get: { draft.classType ?? "" },
                        set: { draft.classType = $0.isEmpty ? nil : $0 }
                    )) {
                        Text("—").tag("")
                        ForEach(classTypes, id: \.self) { Text($0).tag($0) }
                    }
                }

                TextField("Duration (min)", text: $durationStr)
                TextField("Calories", text: $caloriesStr)
                TextField("Avg Heart Rate", text: $heartRateAvgStr)
                TextField("Max Heart Rate", text: $heartRateMaxStr)

                if draft.type == "OrangeTheory" {
                    TextField("Splat Points", text: $splatPointsStr)
                    TextField("Steps", text: $stepsStr)

                    LabeledContent("Scan") {
                        HStack(spacing: 8) {
                            if isScanning {
                                ProgressView().scaleEffect(0.75)
                            } else {
                                PhotosPicker(
                                    selection: $scanPickerItem,
                                    matching: .images,
                                    photoLibrary: .shared()
                                ) {
                                    Label("Scan Screenshot", systemImage: "camera.viewfinder")
                                }
                                .buttonStyle(.bordered)
                                .help("Pick an OT summary screenshot from Photos to auto-fill stats")
                            }
                            if scanComplete {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .transition(.scale)
                            }
                        }
                    }
                    .onChange(of: scanPickerItem) { _, item in
                        guard let item else { return }
                        Task { await scanFromPickerItem(item) }
                    }

                    if let err = scanError {
                        Text(err).font(.caption).foregroundStyle(.red)
                    }
                }

                Picker("Feel", selection: Binding(
                    get: { draft.feel ?? 0 },
                    set: { draft.feel = $0 == 0 ? nil : $0 }
                )) {
                    Text("—").tag(0)
                    ForEach(1...7, id: \.self) { i in
                        Text(feelLabels[i - 1]).tag(i)
                    }
                }

                LabeledContent("Notes") {
                    TextEditor(text: Binding(
                        get: { draft.notes ?? "" },
                        set: { draft.notes = $0.isEmpty ? nil : $0 }
                    ))
                    .frame(height: 70)
                }
            }
            .formStyle(.grouped)
            .padding(.horizontal)

            if let err = saveError {
                Text(err).font(.caption).foregroundStyle(.red).padding(.horizontal)
            }
        }
        .frame(width: 460, height: 600)
        .onAppear { loadFromWorkout() }
    }

    // MARK: - Load

    private func loadFromWorkout() {
        draft.type      = workout.type
        draft.date      = workout.date
        draft.classType = workout.classType
        draft.feel      = workout.feel
        draft.notes     = workout.notes
        draft.name      = workout.name
        draft.placeID   = workout.placeID
        draft.visitID   = workout.visitID

        durationStr     = workout.duration.map     { "\($0)" } ?? ""
        caloriesStr     = workout.calories.map     { "\($0)" } ?? ""
        heartRateAvgStr = workout.heartRateAvg.map { "\($0)" } ?? ""
        heartRateMaxStr = workout.heartRateMax.map { "\($0)" } ?? ""
        splatPointsStr  = workout.splatPoints.map  { "\($0)" } ?? ""
        stepsStr        = workout.steps.map        { "\($0)" } ?? ""
    }

    // MARK: - OT Scan

    private func scanFromPickerItem(_ item: PhotosPickerItem) async {
        isScanning   = true
        scanError    = nil
        scanComplete = false
        defer { isScanning = false }

        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                scanError = "Could not load photo."
                return
            }
            let result = try await OTScanService.scan(imageData: data)
            applyOTScanResult(result)
            withAnimation { scanComplete = true }
        } catch {
            scanError = error.localizedDescription
        }
    }

    private func applyOTScanResult(_ result: OTScanResult) {
        if let v = result.splatPoints,     v > 0 { splatPointsStr  = "\(v)" }
        if let v = result.calories,        v > 0 { caloriesStr     = "\(v)" }
        if let v = result.durationMinutes, v > 0 { durationStr     = "\(v)" }
        if let v = result.maxHr,           v > 0 { heartRateMaxStr = "\(v)" }
        if let v = result.avgHr,           v > 0 { heartRateAvgStr = "\(v)" }
        if let v = result.steps,           v > 0 { stepsStr        = "\(v)" }
        draft.zone1 = result.zones?.gray?.minutes
        draft.zone2 = result.zones?.blue?.minutes
        draft.zone3 = result.zones?.green?.minutes
        draft.zone4 = result.zones?.orange?.minutes
        draft.zone5 = result.zones?.red?.minutes
        if let d = result.classDate {
            let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
            if let date = df.date(from: d) { draft.date = date }
        }
    }

    // MARK: - Save

    private func save() async {
        draft.duration     = Int(durationStr)
        draft.calories     = Int(caloriesStr)
        draft.heartRateAvg = Int(heartRateAvgStr)
        draft.heartRateMax = Int(heartRateMaxStr)
        draft.splatPoints  = Int(splatPointsStr)
        draft.steps        = Int(stepsStr)

        if draft.name.isEmpty {
            let df = DateFormatter(); df.dateFormat = "M/d"
            draft.name = "\(draft.type) · \(df.string(from: draft.date ?? Date()))"
        }

        isSaving  = true
        saveError = nil
        do {
            try await notion.updateWorkout(workout.id, draft: draft)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
        isSaving = false
    }
}
