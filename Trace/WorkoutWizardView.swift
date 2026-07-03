import SwiftUI
import PhotosUI

// MARK: - Wizard

struct WorkoutWizardView: View {
    @Environment(NotionService.self) private var notion
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    let visitID: String?
    let initialDate: Date?
    private let editingID: String?

    // Create mode
    init(visitID: String? = nil, initialDate: Date? = nil) {
        self.visitID = visitID
        self.initialDate = initialDate
        self.editingID = nil
        var d = WorkoutDraft()
        d.visitID = visitID
        d.date = initialDate
        _draft = State(initialValue: d)
        _calStr = State(initialValue: "")
        _hrAvgStr = State(initialValue: "")
        _hrMaxStr = State(initialValue: "")
        _splatsStr = State(initialValue: "")
        _outputStr = State(initialValue: "")
        _durationStr = State(initialValue: "")
        _distanceStr = State(initialValue: "")
        _z1Str = State(initialValue: "")
        _z2Str = State(initialValue: "")
        _z3Str = State(initialValue: "")
        _z4Str = State(initialValue: "")
        _z5Str = State(initialValue: "")
        _classType = State(initialValue: "Tread 50")
        _stepsStr = State(initialValue: "")
        _elevationStr = State(initialValue: "")
        _treadPaceStr = State(initialValue: "")
        _hasRower = State(initialValue: false)
        _rowerDistStr = State(initialValue: "")
        _rowerWattsStr = State(initialValue: "")
        _rowerPaceStr = State(initialValue: "")
        _rowerStrokeStr = State(initialValue: "")
    }

    // Edit mode — pre-fills from an existing Workout
    init(editing w: Workout) {
        self.visitID = w.visitID
        self.initialDate = w.date
        self.editingID = w.id
        var d = WorkoutDraft()
        d.name = w.name
        d.type = w.type
        d.date = w.date
        d.duration = w.duration
        d.calories = w.calories
        d.heartRateAvg = w.heartRateAvg
        d.heartRateMax = w.heartRateMax
        d.splatPoints = w.splatPoints
        d.output = w.output
        d.zone1 = w.zone1
        d.zone2 = w.zone2
        d.zone3 = w.zone3
        d.zone4 = w.zone4
        d.zone5 = w.zone5
        d.distance = w.distance
        d.feel = w.feel
        d.notes = w.notes
        d.placeID = w.placeID
        d.visitID = w.visitID
        d.classType = w.classType
        d.steps = w.steps
        d.elevation = w.elevation
        d.treadPace = w.treadPace
        d.hasRower = w.hasRower
        d.rowerDistance = w.rowerDistance
        d.rowerWattsAvg = w.rowerWattsAvg
        d.rowerPace = w.rowerPace
        d.rowerStrokeAvg = w.rowerStrokeAvg
        _draft = State(initialValue: d)
        _calStr = State(initialValue: w.calories.map { "\($0)" } ?? "")
        _hrAvgStr = State(initialValue: w.heartRateAvg.map { "\($0)" } ?? "")
        _hrMaxStr = State(initialValue: w.heartRateMax.map { "\($0)" } ?? "")
        _splatsStr = State(initialValue: w.splatPoints.map { "\($0)" } ?? "")
        _outputStr = State(initialValue: w.output.map { "\($0)" } ?? "")
        _durationStr = State(initialValue: w.duration.map { "\($0)" } ?? "")
        _distanceStr = State(initialValue: w.distance.map { String(format: "%.2f", $0) } ?? "")
        _z1Str = State(initialValue: w.zone1.map { "\($0)" } ?? "")
        _z2Str = State(initialValue: w.zone2.map { "\($0)" } ?? "")
        _z3Str = State(initialValue: w.zone3.map { "\($0)" } ?? "")
        _z4Str = State(initialValue: w.zone4.map { "\($0)" } ?? "")
        _z5Str = State(initialValue: w.zone5.map { "\($0)" } ?? "")
        _classType = State(initialValue: w.classType ?? "Tread 50")
        _stepsStr = State(initialValue: w.steps.map { "\($0)" } ?? "")
        _elevationStr = State(initialValue: w.elevation.map { String(format: "%.0f", $0) } ?? "")
        _treadPaceStr = State(initialValue: w.treadPace ?? "")
        _hasRower = State(initialValue: w.hasRower ?? false)
        _rowerDistStr = State(initialValue: w.rowerDistance.map { "\($0)" } ?? "")
        _rowerWattsStr = State(initialValue: w.rowerWattsAvg.map { "\($0)" } ?? "")
        _rowerPaceStr = State(initialValue: w.rowerPace ?? "")
        _rowerStrokeStr = State(initialValue: w.rowerStrokeAvg.map { "\($0)" } ?? "")
    }

    @State private var draft: WorkoutDraft
    @State private var step = 0
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var done = false

    // OTF-specific string inputs (convert on save)
    @State private var calStr: String
    @State private var hrAvgStr: String
    @State private var hrMaxStr: String
    @State private var splatsStr: String
    @State private var outputStr: String
    @State private var durationStr: String
    @State private var distanceStr: String

    // Zone minute fields
    @State private var z1Str: String
    @State private var z2Str: String
    @State private var z3Str: String
    @State private var z4Str: String
    @State private var z5Str: String

    // Extra fields
    @State private var classType: String
    @State private var stepsStr: String
    @State private var elevationStr: String
    @State private var treadPaceStr: String
    @State private var hasRower: Bool
    @State private var rowerDistStr: String
    @State private var rowerWattsStr: String
    @State private var rowerPaceStr: String
    @State private var rowerStrokeStr: String

    // OT scan state
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var isScanning = false
    @State private var scanComplete = false
    @State private var scanError: String?

    private let workoutTypes = ["OrangeTheory", "Run", "Bike", "Hike", "Lift", "Other"]
    private let otfClassTypes = ["Tread 50", "2G", "3G", "Strength 50", "Tornado", "Other"]
    private let feelLabels = ["😴 1", "😕 2", "😐 3", "🙂 4", "😊 5", "💪 6", "🔥 7"]

    var body: some View {
        NavigationStack {
            Group {
                if done {
                    doneView
                } else {
                    stepView
                }
            }
            .navigationTitle(stepTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if step == 0 {
                        Button("Cancel") { dismiss() }
                    } else {
                        Button("Back") { step -= 1 }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    if isLastStep {
                        Button("Save") { Task { await save() } }
                            .disabled(isSaving)
                            .fontWeight(.semibold)
                    } else {
                        Button("Next") { step += 1 }
                            .disabled(!canAdvance)
                            .fontWeight(.semibold)
                    }
                }
            }
        }
    }

    // MARK: - Step routing

    @ViewBuilder
    private var stepView: some View {
        if step == 0 {
            typeStep
        } else if step == 1 {
            coreStep
        } else if step == 2 {
            metricsStep
        } else {
            feelStep
        }
    }

    private var stepTitle: String {
        if done { return editingID != nil ? "Updated!" : "Logged!" }
        switch step {
        case 0: return "Workout Type"
        case 1: return "When & How Long"
        case 2: return draft.type == "OrangeTheory" ? "OTF Metrics" : "Metrics"
        case 3: return "How'd It Feel?"
        default: return ""
        }
    }

    private var isLastStep: Bool { step == 3 }

    private var canAdvance: Bool {
        switch step {
        case 0: return !draft.type.isEmpty
        default: return true
        }
    }

    // MARK: - Steps

    private var typeStep: some View {
        Form {
            Section {
                Picker("Type", selection: $draft.type) {
                    ForEach(workoutTypes, id: \.self) { t in
                        Text(typeIcon(t) + "  " + t).tag(t)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .onAppear {
                    if draft.name.isEmpty {
                        autoName(draft.type)
                    }
                }
                .onChange(of: draft.type) { _, newType in
                    autoName(newType)
                    // Reset scan state when switching away from OTF
                    if newType != "OrangeTheory" {
                        scanComplete = false
                        scanError = nil
                        selectedPhoto = nil
                    }
                }
            } header: {
                Text("Workout Type")
            } footer: {
                Text(draft.type == "OrangeTheory"
                     ? "OTF metrics (Splat Points, zones, output) available in step 3."
                     : " ")
                    .font(.caption)
            }

            Section("Name") {
                TextField("Workout name", text: $draft.name)
            }

            // OT scan section — only shown for OrangeTheory
            if draft.type == "OrangeTheory" {
                Section {
                    if isScanning {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Reading stats…")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 2)

                    } else if scanComplete {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Stats loaded — review in step 3")
                            Spacer()
                            PhotosPicker(
                                selection: $selectedPhoto,
                                matching: .images,
                                photoLibrary: .shared()
                            ) {
                                Text("Re-scan")
                                    .font(.caption)
                                    .foregroundStyle(Color.accentColor)
                            }
                        }

                    } else {
                        PhotosPicker(
                            selection: $selectedPhoto,
                            matching: .images,
                            photoLibrary: .shared()
                        ) {
                            Label("Scan OT Stats Photo", systemImage: "camera.viewfinder")
                        }
                        if let err = scanError {
                            Text(err)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                } header: {
                    Text("Quick Scan")
                } footer: {
                    if !scanComplete && !isScanning {
                        Text("Pick your end-of-class stats photo. Claude reads the numbers and pre-fills your metrics.")
                            .font(.caption)
                    }
                }
                .onChange(of: selectedPhoto) { _, item in
                    guard let item else { return }
                    Task { await performScan(item: item) }
                }
            }
        }
    }

    private var coreStep: some View {
        Form {
            Section("Date") {
                DatePicker("Date", selection: Binding(
                    get: { draft.date ?? Date() },
                    set: { draft.date = $0 }
                ), displayedComponents: [.date])
                .datePickerStyle(.compact)
            }

            Section("Duration") {
                HStack {
                    TextField("Minutes", text: $durationStr)
                        .keyboardType(.numberPad)
                    Text("min").foregroundStyle(.secondary)
                }
            }

            if draft.type == "OrangeTheory" {
                Section("Class Type") {
                    Picker("Class", selection: $classType) {
                        ForEach(otfClassTypes, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.menu)
                }
            }
        }
    }

    private var metricsStep: some View {
        Form {
            if draft.type == "OrangeTheory" && scanComplete {
                Section {
                    Label("Pre-filled from scan — edit anything below", systemImage: "wand.and.stars")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Calories & Heart Rate") {
                fieldRow("Calories", binding: $calStr, unit: "kcal")
                fieldRow("HR Average", binding: $hrAvgStr, unit: "bpm")
                fieldRow("HR Max", binding: $hrMaxStr, unit: "bpm")
            }

            if draft.type == "OrangeTheory" {
                Section("OTF") {
                    fieldRow("Splat Points", binding: $splatsStr, unit: "pts")
                    fieldRow("Output (Watts)", binding: $outputStr, unit: "W")
                }

                Section("Zone Minutes") {
                    fieldRow("Gray (Z1)",   binding: $z1Str, unit: "min")
                    fieldRow("Blue (Z2)",   binding: $z2Str, unit: "min")
                    fieldRow("Green (Z3)",  binding: $z3Str, unit: "min")
                    fieldRow("Orange (Z4)", binding: $z4Str, unit: "min")
                    fieldRow("Red (Z5)",    binding: $z5Str, unit: "min")
                }
            }

            if ["Run", "Bike", "Hike", "OrangeTheory", "Other"].contains(draft.type) {
                Section("Treadmill / Cardio") {
                    fieldRow("Distance", binding: $distanceStr,  unit: "mi",     keyboard: .decimalPad)
                    fieldRow("Steps",    binding: $stepsStr,     unit: "steps")
                    fieldRow("Avg Pace", binding: $treadPaceStr, unit: "min/mi", keyboard: .numbersAndPunctuation)
                    fieldRow("Elevation", binding: $elevationStr, unit: "ft")
                }
            }

            if draft.type == "OrangeTheory" {
                Section {
                    Toggle("Includes Rower", isOn: $hasRower)
                    if hasRower {
                        fieldRow("Distance",    binding: $rowerDistStr,   unit: "m")
                        fieldRow("Avg Watts",   binding: $rowerWattsStr,  unit: "W")
                        fieldRow("500m Pace",   binding: $rowerPaceStr,   unit: "min",  keyboard: .numbersAndPunctuation)
                        fieldRow("Stroke Rate", binding: $rowerStrokeStr, unit: "spm")
                    }
                } header: {
                    Text("Rower")
                }
            }
        }
    }

    private var feelStep: some View {
        Form {
            Section("How'd it feel?") {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Spacer()
                        Text(feelLabels[max(0, (draft.feel ?? 4) - 1)])
                            .font(.largeTitle)
                        Spacer()
                    }
                    Slider(
                        value: Binding(
                            get: { Double(draft.feel ?? 4) },
                            set: { draft.feel = Int($0.rounded()) }
                        ),
                        in: 1...7,
                        step: 1
                    )
                    HStack {
                        Text("1").foregroundStyle(.secondary).font(.caption)
                        Spacer()
                        Text("7").foregroundStyle(.secondary).font(.caption)
                    }
                }
                .padding(.vertical, 8)
                .onAppear { if draft.feel == nil { draft.feel = 4 } }
            }

            Section("Notes") {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: Binding(
                        get: { draft.notes ?? "" },
                        set: { draft.notes = $0.isEmpty ? nil : $0 }
                    ))
                    .frame(minHeight: 100)
                    if (draft.notes ?? "").isEmpty {
                        Text("Anything worth remembering…")
                            .foregroundStyle(Color(.placeholderText))
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
            }

            if let err = saveError {
                Section {
                    Text(err).foregroundStyle(.red).font(.caption)
                }
            }
        }
    }

    // MARK: - Done

    private var doneView: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(.green)
            Text(editingID != nil ? "Workout updated!" : "Workout logged!")
                .font(.title2.bold())
            if let cal = draft.calories {
                Text("\(cal) calories · \(draft.type)")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - OT Scan

    private func performScan(item: PhotosPickerItem) async {
        isScanning = true
        scanError = nil
        scanComplete = false
        defer { isScanning = false }

        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                scanError = "Could not load photo."
                return
            }
            let result = try await OTScanService.scan(imageData: data)
            applyScanResult(result)
            scanComplete = true
        } catch {
            scanError = error.localizedDescription
        }
    }

    private func applyScanResult(_ result: OTScanResult) {
        if let v = result.splatPoints,    v > 0 { splatsStr    = "\(v)" }
        if let v = result.calories,       v > 0 { calStr        = "\(v)" }
        if let v = result.durationMinutes, v > 0 { durationStr = "\(v)" }
        if let v = result.avgHr,          v > 0 { hrAvgStr     = "\(v)" }
        if let v = result.maxHr,          v > 0 { hrMaxStr     = "\(v)" }

        // Parse class date if returned
        if let dateStr = result.classDate {
            let fmt = ISO8601DateFormatter()
            fmt.formatOptions = [.withFullDate]
            if let date = fmt.date(from: dateStr) {
                draft.date = date
                // Refresh auto-name with the scanned date
                let df = DateFormatter()
                df.dateFormat = "M/d"
                draft.name = "OrangeTheory \(df.string(from: date))"
            }
        }

        // Zone minutes
        if let z = result.zones {
            if let v = z.gray?.minutes   { z1Str = "\(v)" }
            if let v = z.blue?.minutes   { z2Str = "\(v)" }
            if let v = z.green?.minutes  { z3Str = "\(v)" }
            if let v = z.orange?.minutes { z4Str = "\(v)" }
            if let v = z.red?.minutes    { z5Str = "\(v)" }
        }

        // Treadmill fields
        if let v = result.distanceMiles,  v > 0 { distanceStr  = String(format: "%.1f", v) }
        if let v = result.steps,          v > 0 { stepsStr     = "\(v)" }
        if let v = result.elevationFt,    v > 0 { elevationStr = String(format: "%.0f", v) }

        // Convert avg speed (mph) → pace (min/mi) as "M:SS"
        if let speed = result.avgSpeedMph, speed > 0 {
            let pace = 60.0 / speed
            let minutes = Int(pace)
            let seconds = Int((pace - Double(minutes)) * 60)
            treadPaceStr = String(format: "%d:%02d", minutes, seconds)
        }
    }

    // MARK: - Save

    private func save() async {
        // Commit string inputs
        draft.calories     = Int(calStr)
        draft.heartRateAvg = Int(hrAvgStr)
        draft.heartRateMax = Int(hrMaxStr)
        draft.splatPoints  = Int(splatsStr)
        draft.output       = Int(outputStr)
        draft.duration     = Int(durationStr)
        draft.distance     = Double(distanceStr)
        draft.zone1        = Int(z1Str)
        draft.zone2        = Int(z2Str)
        draft.zone3        = Int(z3Str)
        draft.zone4        = Int(z4Str)
        draft.zone5        = Int(z5Str)
        draft.classType    = draft.type == "OrangeTheory" ? classType : nil
        draft.steps        = Int(stepsStr)
        draft.elevation    = Double(elevationStr)
        draft.treadPace    = treadPaceStr.isEmpty ? nil : treadPaceStr
        draft.hasRower     = draft.type == "OrangeTheory" ? hasRower : nil
        draft.rowerDistance  = Int(rowerDistStr)
        draft.rowerWattsAvg  = Int(rowerWattsStr)
        draft.rowerPace      = rowerPaceStr.isEmpty ? nil : rowerPaceStr
        draft.rowerStrokeAvg = Int(rowerStrokeStr)

        isSaving = true
        do {
            if let id = editingID {
                try await notion.updateWorkout(id, draft: draft)
            } else {
                _ = try await notion.logWorkout(draft)
            }
            done = true
        } catch {
            saveError = error.localizedDescription
        }
        isSaving = false
    }

    // MARK: - Helpers

    @ViewBuilder
    private func fieldRow(_ label: String, binding: Binding<String>, unit: String,
                          keyboard: UIKeyboardType = .numberPad) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            TextField("—", text: binding)
                .keyboardType(keyboard)
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
            Text(unit).foregroundStyle(.secondary).font(.caption)
        }
    }

    private func typeIcon(_ type: String) -> String {
        switch type {
        case "OrangeTheory": return "🔥"
        case "Run":          return "🏃"
        case "Bike":         return "🚴"
        case "Hike":         return "🥾"
        case "Lift":         return "🏋️"
        default:             return "💪"
        }
    }

    private func autoName(_ type: String) {
        let df = DateFormatter()
        df.dateFormat = "M/d"
        draft.name = "\(type) \(df.string(from: draft.date ?? Date()))"
        if type == "OrangeTheory" && durationStr.isEmpty {
            durationStr = "60"
        }
    }

}
