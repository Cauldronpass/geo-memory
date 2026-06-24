import SwiftUI
import PhotosUI

// MARK: - Wizard

struct BilliardsWizardView: View {
    @Environment(NotionService.self) private var notion
    @Environment(\.dismiss) private var dismiss

    /// Notion visit ID to link to. Optional — session is saved unlinked if nil.
    let visitID: String?
    /// Pre-fill the match date (e.g. from the visit date when opening from VisitDetailView).
    let initialDate: Date?

    @State private var draft = BilliardsDraft()
    @State private var step = 0
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var done = false
    @State private var loggedCount = 0

    // Scan state
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var isScanning = false
    @State private var scanComplete = false
    @State private var scanError: String?

    // Opponent picker
    @State private var showingOpponentPicker = false

    // Form string fields (converted on save)
    @State private var opponentSLStr        = ""
    @State private var myScoreStr           = ""
    @State private var opponentScoreStr     = ""
    @State private var myNeededStr          = ""
    @State private var opponentNeededStr    = ""
    @State private var myTeamPointsStr       = ""
    @State private var opponentTeamPointsStr = ""
    @State private var inningsStr            = ""
    @State private var matchNumberStr        = ""
    @State private var matchNotes            = ""

    // Cached defaults
    private var myName: String {
        let s = UserDefaults.standard.string(forKey: "billiards_my_name") ?? ""
        return s.isEmpty ? "Dave" : s
    }
    private var defaultSL: Int {
        let v = UserDefaults.standard.integer(forKey: "billiards_my_sl")
        return v > 0 ? v : 5
    }

    /// 3 = Tue, 4 = Wed (Calendar weekday: 1=Sun … 7=Sat)
    private var weekday: Int { Calendar.current.component(.weekday, from: Date()) }

    // MARK: - Init

    init(visitID: String? = nil, initialDate: Date? = nil) {
        self.visitID = visitID
        self.initialDate = initialDate
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Group {
                if done { doneView }
                else     { stepView  }
            }
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if done {
                        EmptyView()
                    } else if step == 0 {
                        Button("Cancel") { dismiss() }
                    } else {
                        Button("Back") { step -= 1 }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    if !done {
                        if step == 0 {
                            Button("Next") { step = 1 }
                                .fontWeight(.semibold)
                        } else {
                            Button("Save") { Task { await save() } }
                                .disabled(isSaving || draft.opponent.trimmingCharacters(in: .whitespaces).isEmpty)
                                .fontWeight(.semibold)
                        }
                    }
                }
            }
        }
        .onAppear { resetDraft(keepVisit: false) }
    }

    // MARK: - Step routing

    private var navTitle: String {
        if done { return "Match Logged!" }
        return step == 0 ? "Scan Scorecard" : "Match Details"
    }

    @ViewBuilder
    private var stepView: some View {
        if step == 0 { scanStep   }
        else          { detailStep }
    }

    // MARK: – Step 0: Scan + format

    private var scanStep: some View {
        Form {
            Section("Format") {
                Picker("Format", selection: $draft.format) {
                    Text("8-Ball").tag("8-Ball")
                    Text("9-Ball").tag("9-Ball")
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            }

            Section {
                if isScanning {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Reading scorecard…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)

                } else if scanComplete {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Scorecard read — review in next step")
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
                        Label("Scan APA Scorecard", systemImage: "camera.viewfinder")
                    }
                    if let err = scanError {
                        Text(err).font(.caption).foregroundStyle(.red)
                    }
                }
            } header: {
                Text("Quick Scan")
            } footer: {
                if !scanComplete && !isScanning {
                    Text("Pick a screenshot of your APA match scorecard. Claude extracts the stats and pre-fills the form. You can also skip and enter manually.")
                        .font(.caption)
                }
            }
            .onChange(of: selectedPhoto) { _, item in
                guard let item else { return }
                Task { await performScan(item: item) }
            }

            Section("Match Info") {
                DatePicker("Date", selection: Binding(
                    get: { draft.date },
                    set: { draft.date = $0 }
                ), displayedComponents: .date)

                HStack {
                    Text("Match #").foregroundStyle(.secondary)
                    Spacer()
                    TextField("—", text: $matchNumberStr)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 60)
                }
            }
        }
    }

    // MARK: – Step 1: Details

    private var detailStep: some View {
        Form {
            if scanComplete {
                Section {
                    Label("Pre-filled from scan — edit anything below",
                          systemImage: "wand.and.stars")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Opponent") {
                Button {
                    showingOpponentPicker = true
                } label: {
                    HStack {
                        Text(draft.opponent.isEmpty ? "Select opponent…" : draft.opponent)
                            .foregroundStyle(draft.opponent.isEmpty ? .secondary : .primary)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                HStack {
                    Text("Opponent SL").foregroundStyle(.secondary)
                    Spacer()
                    TextField("—", text: $opponentSLStr)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 60)
                }
            }
            .sheet(isPresented: $showingOpponentPicker) {
                OpponentPickerSheet(
                    selected: $draft.opponent,
                    knownOpponents: notion.billiardsSessions
                        .map { $0.opponent }
                        .filter { !$0.isEmpty }
                        .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                        .sorted()
                )
            }

            Section("Scores") {
                let neededLabel = draft.format == "9-Ball" ? "pts needed" : "games needed"
                scoreRow(label: "My score",
                         scoreBinding: $myScoreStr,
                         neededBinding: $myNeededStr,
                         neededLabel: neededLabel)
                scoreRow(label: "Opponent score",
                         scoreBinding: $opponentScoreStr,
                         neededBinding: $opponentNeededStr,
                         neededLabel: neededLabel)
                HStack {
                    Text("My team pts").foregroundStyle(.secondary)
                    Spacer()
                    TextField("0", text: $myTeamPointsStr)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 48)
                }
                HStack {
                    Text("Opponent team pts").foregroundStyle(.secondary)
                    Spacer()
                    TextField("0", text: $opponentTeamPointsStr)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 48)
                }
                HStack {
                    Text("Innings").foregroundStyle(.secondary)
                    Spacer()
                    TextField("—", text: $inningsStr)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 60)
                }
            }

            Section("Result") {
                Picker("Result", selection: Binding(
                    get: { draft.result ?? "" },
                    set: { draft.result = $0.isEmpty ? nil : $0 }
                )) {
                    Text("—").tag("")
                    Text("Win").tag("Win")
                    Text("Loss").tag("Loss")
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))

                Toggle("Won lag", isOn: $draft.wonLag)
            }

            Section {
                HStack {
                    Text("My skill level").foregroundStyle(.secondary)
                    Spacer()
                    Stepper("\(draft.mySkillLevel)", value: $draft.mySkillLevel, in: 1...9)
                }
            } header: {
                Text("My SL")
            } footer: {
                Text("Change your SL default anytime in Settings → Billiards.")
                    .font(.caption)
            }

            Section("Notes") {
                TextField("How'd it go?", text: $matchNotes, axis: .vertical)
                    .lineLimit(3...6)
            }

            if let err = saveError {
                Section {
                    Text(err).foregroundStyle(.red).font(.caption)
                }
            }
        }
    }

    @ViewBuilder
    private func scoreRow(label: String,
                          scoreBinding: Binding<String>,
                          neededBinding: Binding<String>,
                          neededLabel: String = "needed") -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            TextField("0", text: scoreBinding)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 48)
            Text("/")
                .foregroundStyle(.secondary)
            TextField("0", text: neededBinding)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 48)
            Text(neededLabel)
                .foregroundStyle(.secondary)
                .font(.caption)
        }
    }

    // MARK: – Done

    private var doneView: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(.green)
            VStack(spacing: 6) {
                Text(loggedCount == 1 ? "Match logged!" : "\(loggedCount) matches logged!")
                    .font(.title2.bold())
                if !draft.opponent.isEmpty {
                    Text("vs \(draft.opponent) · \(draft.format)")
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(spacing: 12) {
                // "Log another" only makes sense on Tuesday when both formats are possible
                Button("Log Another Match") {
                    logAnother()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: – Scan

    private func performScan(item: PhotosPickerItem) async {
        isScanning = true
        scanError  = nil
        scanComplete = false
        defer { isScanning = false }

        do {
            guard let data  = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                scanError = "Could not load photo."
                return
            }
            let result = try await BilliardsScanService.scan(image: image)
            applyScanResult(result)
            scanComplete = true
        } catch {
            scanError = error.localizedDescription
        }
    }

    private func applyScanResult(_ result: BilliardsScanResult) {
        if let fmt = result.format { draft.format = fmt }

        // Identify which row is "me" — first try name match, fall back to player1
        let p1Lower = (result.player1Name ?? "").lowercased()
        let p2Lower = (result.player2Name ?? "").lowercased()
        let meLower = myName.lowercased()
        let iAmP1: Bool
        if p1Lower.contains(meLower)      { iAmP1 = true  }
        else if p2Lower.contains(meLower) { iAmP1 = false }
        else                               { iAmP1 = true  }   // default: assume top row

        let myScore       = iAmP1 ? result.player1Score       : result.player2Score
        let myNeeded      = iAmP1 ? result.player1Needed      : result.player2Needed
        let myTeamPts     = iAmP1 ? result.player1TeamPoints  : result.player2TeamPoints
        let mySLScan      = iAmP1 ? result.player1Sl          : result.player2Sl
        let oppScore      = iAmP1 ? result.player2Score       : result.player1Score
        let oppNeeded     = iAmP1 ? result.player2Needed      : result.player1Needed
        let oppTeamPts    = iAmP1 ? result.player2TeamPoints  : result.player1TeamPoints
        let oppName       = iAmP1 ? result.player2Name        : result.player1Name
        let oppSL         = iAmP1 ? result.player2Sl          : result.player1Sl
        let winnerKey     = result.winner
        let lagKey        = result.lagWinner

        if let n  = oppName, !n.isEmpty { draft.opponent = n }
        if let sl = oppSL               { opponentSLStr  = "\(sl)" }
        if let sl = mySLScan            { draft.mySkillLevel = sl }
        if let sc = myScore             { myScoreStr     = "\(sc)" }
        if let n  = myNeeded            { myNeededStr    = "\(n)"  }
        if let sc = oppScore            { opponentScoreStr = "\(sc)" }
        if let n  = oppNeeded           { opponentNeededStr = "\(n)" }
        if let tp = myTeamPts           { myTeamPointsStr      = "\(tp)" }
        if let tp = oppTeamPts          { opponentTeamPointsStr = "\(tp)" }
        if let inn = result.innings     { inningsStr     = "\(inn)" }

        // Auto-detect result from scores (more reliable than scan's winner field)
        let myS = myScore ?? -1;  let myN = myNeeded ?? Int.max
        let opS = oppScore ?? -1; let opN = oppNeeded ?? Int.max
        if      myS >= myN && myN > 0 { draft.result = "Win"  }
        else if opS >= opN && opN > 0 { draft.result = "Loss" }
        else {
            // Fall back to scan's winner field
            let myWon  = (iAmP1 && winnerKey == "player1") || (!iAmP1 && winnerKey == "player2")
            let oppWon = (iAmP1 && winnerKey == "player2") || (!iAmP1 && winnerKey == "player1")
            if      myWon  { draft.result = "Win"  }
            else if oppWon { draft.result = "Loss" }
        }

        // Lag
        if let lagKey {
            let iWonLag = (iAmP1 && lagKey == "player1") || (!iAmP1 && lagKey == "player2")
            draft.wonLag = iWonLag
        }
    }

    // MARK: – Save

    private func save() async {
        draft.opponentSkillLevel = Int(opponentSLStr)
        draft.innings            = Int(inningsStr)
        draft.matchNumber        = Int(matchNumberStr)

        // Build "score/needed" strings
        let myS  = Int(myScoreStr);       let myN  = Int(myNeededStr)
        let oppS = Int(opponentScoreStr); let oppN = Int(opponentNeededStr)
        if let s = myS,  let n = myN  { draft.myScore       = "\(s)/\(n)" }
        else if let s = myS           { draft.myScore       = "\(s)" }
        if let s = oppS, let n = oppN { draft.opponentScore = "\(s)/\(n)" }
        else if let s = oppS          { draft.opponentScore = "\(s)" }

        // Team points are separate from game score — use their own fields
        draft.myTeamPoints       = Int(myTeamPointsStr)
        draft.opponentTeamPoints = Int(opponentTeamPointsStr)
        draft.notes              = matchNotes

        isSaving = true
        do {
            _ = try await notion.logBilliardsSession(draft)
            loggedCount += 1
            done = true
        } catch {
            saveError = error.localizedDescription
        }
        isSaving = false
    }

    // MARK: – Log another (keeps date + visitID, increments match number)

    private func logAnother() {
        let savedVisitID = draft.visitID
        let savedDate    = draft.date
        let nextMatchNo  = (draft.matchNumber ?? loggedCount) + 1
        resetDraft(keepVisit: true)
        draft.visitID     = savedVisitID
        draft.date        = savedDate
        draft.matchNumber = nextMatchNo
        matchNumberStr    = "\(nextMatchNo)"
        done = false
        step = 0
    }

    // MARK: – Helpers

    private func resetDraft(keepVisit: Bool) {
        let vid  = keepVisit ? draft.visitID : visitID
        let date = keepVisit ? draft.date    : (initialDate ?? Date())
        draft = BilliardsDraft()
        draft.visitID      = vid
        draft.date         = date
        draft.mySkillLevel = defaultSL
        // Wednesday (weekday 4) defaults to 8-ball
        if weekday == 4 { draft.format = "8-Ball" }
        opponentSLStr         = ""
        myScoreStr            = ""
        opponentScoreStr      = ""
        myNeededStr           = ""
        opponentNeededStr     = ""
        myTeamPointsStr       = ""
        opponentTeamPointsStr = ""
        inningsStr            = ""
        matchNumberStr        = ""
        matchNotes            = ""
        scanComplete      = false
        scanError         = nil
        selectedPhoto     = nil
    }
}

// MARK: - Opponent picker sheet

struct OpponentPickerSheet: View {
    @Binding var selected: String
    let knownOpponents: [String]
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""
    @State private var newName    = ""
    @FocusState private var newNameFocused: Bool

    private var filtered: [String] {
        guard !searchText.isEmpty else { return knownOpponents }
        return knownOpponents.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            List {
                // New person entry
                Section {
                    HStack {
                        TextField("New opponent name…", text: $newName)
                            .autocorrectionDisabled()
                            .focused($newNameFocused)
                        if !newName.trimmingCharacters(in: .whitespaces).isEmpty {
                            Button("Use") {
                                selected = newName.trimmingCharacters(in: .whitespaces)
                                dismiss()
                            }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                        }
                    }
                } header: {
                    Text("New person")
                }

                // Known opponents
                if !filtered.isEmpty {
                    Section {
                        ForEach(filtered, id: \.self) { name in
                            Button {
                                selected = name
                                dismiss()
                            } label: {
                                HStack {
                                    Text(name).foregroundStyle(.primary)
                                    Spacer()
                                    if name == selected {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Color.accentColor)
                                            .font(.caption.weight(.semibold))
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text("Known opponents")
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search opponents")
            .navigationTitle("Opponent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
