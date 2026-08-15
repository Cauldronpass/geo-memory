import SwiftUI
import PhotosUI
import Observation

// MARK: - Draft store

/// Where an in-progress match lives.
///
/// It used to live in `@State` on `BilliardsWizardView`, which is presented as
/// a sheet, and a sheet can be taken down without the user asking for it. That
/// is exactly what kept happening. The Opponent SL field sat inside the one
/// `Section` that also carried a `.sheet` modifier, so editing it churned a
/// presentation anchor inside a `Form` row and dismissed the whole wizard.
/// David landed back on the visit or the Billiards list with a scan and several
/// minutes of typing gone, reliably, and nothing had reached Notion because
/// `save()` had never run. Confirmed before any code changed: no partial rows
/// and no archived rows in the Billiards Sessions database.
///
/// Two changes make that impossible rather than unlikely. The anchor moved onto
/// the `Form`, and the draft moved here, outside the view's lifetime. This
/// object is cleared only by an explicit act: Cancel, Done, or Log Another. A
/// sheet that vanishes for any other reason now costs a tap to get back to
/// rather than a re-scan.
///
/// In memory only, deliberately. The failure being fixed is a torn-down sheet
/// inside a running app, not a terminated one. If a draft is ever lost to a
/// kill, disk persistence is the next step and this is where it goes.
@Observable
final class BilliardsDraftStore {

    static let shared = BilliardsDraftStore()

    var draft        = BilliardsDraft()
    var step         = 0
    var scanComplete = false

    // Form string fields, converted to numbers on save.
    var opponentSLStr         = ""
    var myScoreStr            = ""
    var opponentScoreStr      = ""
    var myNeededStr           = ""
    var opponentNeededStr     = ""
    var myTeamPointsStr       = ""
    var opponentTeamPointsStr = ""
    var inningsStr            = ""
    var matchNumberStr        = ""
    var matchNotes            = ""

    /// Set by `markSaved()`. The values stay readable for the confirmation
    /// screen; the draft simply stops counting as unsaved work.
    private(set) var isSaved = false

    private init() {}

    /// True when there is unsaved work worth resuming.
    var hasContent: Bool {
        if isSaved { return false }
        if !draft.opponent.isEmpty { return true }
        if scanComplete || step > 0 { return true }
        return ![opponentSLStr, myScoreStr, opponentScoreStr, myNeededStr,
                 opponentNeededStr, myTeamPointsStr, opponentTeamPointsStr,
                 inningsStr, matchNumberStr, matchNotes].allSatisfy(\.isEmpty)
    }

    /// Start a new draft. Wednesday is 8-ball night, hence `eightBallDefault`.
    func begin(visitID: String?, date: Date, defaultSL: Int, eightBallDefault: Bool) {
        clear()
        draft.visitID      = visitID
        draft.date         = date
        draft.mySkillLevel = defaultSL
        if eightBallDefault { draft.format = "8-Ball" }
    }

    /// Start the next match of the same night: keeps the visit and the date,
    /// bumps the match number.
    func beginNext(defaultSL: Int, eightBallDefault: Bool, nextMatchNumber: Int) {
        let vid  = draft.visitID
        let date = draft.date
        begin(visitID: vid, date: date, defaultSL: defaultSL,
              eightBallDefault: eightBallDefault)
        draft.matchNumber = nextMatchNumber
        matchNumberStr    = "\(nextMatchNumber)"
    }

    func markSaved() { isSaved = true }

    func clear() {
        draft        = BilliardsDraft()
        step         = 0
        scanComplete = false
        isSaved      = false
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
    }
}


// MARK: - Wizard

struct BilliardsWizardView: View {
    @Environment(NotionService.self) private var notion
    @Environment(\.dismiss) private var dismiss

    /// Notion visit ID to link to. Optional — session is saved unlinked if nil.
    let visitID: String?
    /// Pre-fill the match date (e.g. from the visit date when opening from VisitDetailView).
    let initialDate: Date?

    /// The draft lives outside this view on purpose. See `BilliardsDraftStore`.
    @State private var store = BilliardsDraftStore.shared
    /// True when this open resumed work a torn-down sheet left behind.
    @State private var resumedDraft = false
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var done = false
    @State private var loggedCount = 0

    // Scan state
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var isScanning = false
    @State private var scanError: String?

    // Post-save state
    @State private var savedSessionID: String? = nil
    @State private var postSaveNotes = ""
    @State private var isSavingNotes = false
    @State private var showingVisitLinker = false
    @State private var linkedVisitName: String? = nil

    // Opponent picker
    @State private var showingOpponentPicker = false

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
                    } else if store.step == 0 {
                        Button("Cancel") { store.clear(); dismiss() }
                    } else {
                        Button("Back") { store.step -= 1 }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    if !done {
                        if store.step == 0 {
                            Button("Next") { store.step = 1 }
                                .fontWeight(.semibold)
                        } else {
                            Button("Save") { Task { await save() } }
                                .disabled(isSaving || store.draft.opponent.trimmingCharacters(in: .whitespaces).isEmpty)
                                .fontWeight(.semibold)
                        }
                    }
                }
            }
        }
        // Never clear the draft here. `onAppear` fires on every re-entry,
        // including ones the user did not ask for, and clearing on it was half
        // of what lost David's records (Session 71). A first open starts a new
        // draft; anything else resumes the one already in flight.
        .onAppear {
            if store.hasContent {
                resumedDraft = true
                if store.draft.visitID == nil { store.draft.visitID = visitID }
            } else {
                store.begin(visitID: visitID,
                            date: initialDate ?? Date(),
                            defaultSL: defaultSL,
                            eightBallDefault: weekday == 4)
            }
        }
    }

    // MARK: - Step routing

    private var navTitle: String {
        if done { return "Match Logged!" }
        return store.step == 0 ? "Scan Scorecard" : "Match Details"
    }

    @ViewBuilder
    private var stepView: some View {
        if store.step == 0 { scanStep   }
        else          { detailStep }
    }

    // MARK: – Step 0: Scan + format

    private var scanStep: some View {
        Form {
            Section("Format") {
                Picker("Format", selection: $store.draft.format) {
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

                } else if store.scanComplete {
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
                if !store.scanComplete && !isScanning {
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
                    get: { store.draft.date },
                    set: { store.draft.date = $0 }
                ), displayedComponents: .date)

                HStack {
                    Text("Match #").foregroundStyle(.secondary)
                    Spacer()
                    TextField("—", text: $store.matchNumberStr)
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
            if resumedDraft {
                Section {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "arrow.uturn.backward.circle.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Picked up where you left off")
                                .font(.caption.weight(.semibold))
                            Text("Nothing was lost. Nothing has been saved to Notion yet either.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Button("Start fresh") {
                            store.begin(visitID: visitID,
                                        date: initialDate ?? Date(),
                                        defaultSL: defaultSL,
                                        eightBallDefault: weekday == 4)
                            scanError     = nil
                            selectedPhoto = nil
                            resumedDraft  = false
                        }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                    }
                }
            }

            if store.scanComplete {
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
                        Text(store.draft.opponent.isEmpty ? "Select opponent…" : store.draft.opponent)
                            .foregroundStyle(store.draft.opponent.isEmpty ? .secondary : .primary)
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
                    TextField("—", text: $store.opponentSLStr)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 60)
                }
            }
            // The opponent picker's sheet used to hang off the Section above,
            // which put a presentation anchor inside a Form row. Editing the
            // Opponent SL field in that same section churned the anchor and
            // took this entire wizard sheet down with it, every time. It now
            // lives on the Form. Sheets belong on a stable container, never on
            // a row. Session 71.

            Section("Scores") {
                let neededLabel = store.draft.format == "9-Ball" ? "pts needed" : "games needed"
                scoreRow(label: "My score",
                         scoreBinding: $store.myScoreStr,
                         neededBinding: $store.myNeededStr,
                         neededLabel: neededLabel)
                scoreRow(label: "Opponent score",
                         scoreBinding: $store.opponentScoreStr,
                         neededBinding: $store.opponentNeededStr,
                         neededLabel: neededLabel)
                HStack {
                    Text("My team pts").foregroundStyle(.secondary)
                    Spacer()
                    TextField("0", text: $store.myTeamPointsStr)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 48)
                }
                HStack {
                    Text("Opponent team pts").foregroundStyle(.secondary)
                    Spacer()
                    TextField("0", text: $store.opponentTeamPointsStr)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 48)
                }
                HStack {
                    Text("Innings").foregroundStyle(.secondary)
                    Spacer()
                    TextField("—", text: $store.inningsStr)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 60)
                }
            }

            Section("Result") {
                Picker("Result", selection: Binding(
                    get: { store.draft.result ?? "" },
                    set: { store.draft.result = $0.isEmpty ? nil : $0 }
                )) {
                    Text("—").tag("")
                    Text("Win").tag("Win")
                    Text("Loss").tag("Loss")
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))

                Toggle("Won lag", isOn: $store.draft.wonLag)
            }

            Section {
                HStack {
                    Text("My skill level").foregroundStyle(.secondary)
                    Spacer()
                    Stepper("\(store.draft.mySkillLevel)", value: $store.draft.mySkillLevel, in: 1...9)
                }
            } header: {
                Text("My SL")
            } footer: {
                Text("Change your SL default anytime in Settings → Billiards.")
                    .font(.caption)
            }

            Section("Notes") {
                TextField("How'd it go?", text: $store.matchNotes, axis: .vertical)
                    .lineLimit(3...6)
            }

            if let err = saveError {
                Section {
                    Text(err).foregroundStyle(.red).font(.caption)
                }
            }
        }
        // numberPad has no Return key, so give the keyboard a way out that does
        // not depend on finding one. Same call CheckInView already makes.
        .scrollDismissesKeyboard(.interactively)
        .sheet(isPresented: $showingOpponentPicker) {
            OpponentPickerSheet(
                selected: $store.draft.opponent,
                knownOpponents: notion.billiardsSessions
                    .map { $0.opponent }
                    .filter { !$0.isEmpty }
                    .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                    .sorted()
            )
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
        ScrollView {
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 60))
                        .foregroundStyle(.green)
                    Text(loggedCount == 1 ? "Match logged!" : "\(loggedCount) matches logged!")
                        .font(.title2.bold())
                    if !store.draft.opponent.isEmpty {
                        Text("vs \(store.draft.opponent) · \(store.draft.format)")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 32)

                // Post-save notes
                VStack(alignment: .leading, spacing: 8) {
                    Text("Notes")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    TextEditor(text: $postSaveNotes)
                        .frame(minHeight: 90)
                        .padding(8)
                        .background(Color(UIColor.secondarySystemGroupedBackground),
                                    in: RoundedRectangle(cornerRadius: 10))
                    if !postSaveNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button {
                            Task { await savePostNotes() }
                        } label: {
                            if isSavingNotes {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                            } else {
                                Text("Save Notes")
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(isSavingNotes)
                    }
                }
                .padding(.horizontal, 24)

                // Visit linking (only when wizard was opened without a visitID)
                if visitID == nil, let sessionID = savedSessionID {
                    Divider().padding(.horizontal, 24)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Link to Visit")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                        if let name = linkedVisitName {
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text(name)
                                    .foregroundStyle(.primary)
                            }
                        } else {
                            Button {
                                showingVisitLinker = true
                            } label: {
                                Label("Link to a visit…", systemImage: "link")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.horizontal, 24)
                    .sheet(isPresented: $showingVisitLinker) {
                        BilliardsVisitLinkerSheet(sessionID: sessionID) { visitID, visitName in
                            linkedVisitName = visitName
                        }
                        .environment(notion)
                    }
                }

                Spacer(minLength: 16)

                // Actions
                VStack(spacing: 12) {
                    Button("Log Another Match") { logAnother() }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    Button("Done") { store.clear(); dismiss() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func savePostNotes() async {
        guard let id = savedSessionID,
              !postSaveNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isSavingNotes = true
        try? await notion.updateBilliardsSessionNotes(id: id, notes: postSaveNotes)
        isSavingNotes = false
    }

    // MARK: – Scan

    private func performScan(item: PhotosPickerItem) async {
        isScanning = true
        scanError  = nil
        store.scanComplete = false
        defer { isScanning = false }

        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                scanError = "Could not load photo."
                return
            }
            let result = try await BilliardsScanService.scan(imageData: data)
            applyScanResult(result)
            store.scanComplete = true
        } catch {
            scanError = error.localizedDescription
        }
    }

    private func applyScanResult(_ result: BilliardsScanResult) {
        if let fmt = result.format { store.draft.format = fmt }

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

        if let n  = oppName, !n.isEmpty { store.draft.opponent = n }
        // A scan that cannot read the opponent's shield number returns 0, and
        // writing a literal 0 into the field is what sent David to edit it in
        // the first place. The my-SL line below has always had this guard.
        if let sl = oppSL, sl > 0       { store.opponentSLStr  = "\(sl)" }
        if let sl = mySLScan, sl > 0    { store.draft.mySkillLevel = sl }
        if let sc = myScore             { store.myScoreStr     = "\(sc)" }
        if let n  = myNeeded            { store.myNeededStr    = "\(n)"  }
        if let sc = oppScore            { store.opponentScoreStr = "\(sc)" }
        if let n  = oppNeeded           { store.opponentNeededStr = "\(n)" }
        if let tp = myTeamPts           { store.myTeamPointsStr      = "\(tp)" }
        if let tp = oppTeamPts          { store.opponentTeamPointsStr = "\(tp)" }
        if let inn = result.innings     { store.inningsStr     = "\(inn)" }

        // Auto-detect result from scores (more reliable than scan's winner field)
        let myS = myScore ?? -1;  let myN = myNeeded ?? Int.max
        let opS = oppScore ?? -1; let opN = oppNeeded ?? Int.max
        if      myS >= myN && myN > 0 { store.draft.result = "Win"  }
        else if opS >= opN && opN > 0 { store.draft.result = "Loss" }
        else {
            // Fall back to scan's winner field
            let myWon  = (iAmP1 && winnerKey == "player1") || (!iAmP1 && winnerKey == "player2")
            let oppWon = (iAmP1 && winnerKey == "player2") || (!iAmP1 && winnerKey == "player1")
            if      myWon  { store.draft.result = "Win"  }
            else if oppWon { store.draft.result = "Loss" }
        }

        // Lag
        if let lagKey {
            let iWonLag = (iAmP1 && lagKey == "player1") || (!iAmP1 && lagKey == "player2")
            store.draft.wonLag = iWonLag
        }
    }

    // MARK: – Save

    private func save() async {
        store.draft.opponentSkillLevel = Int(store.opponentSLStr)
        store.draft.innings            = Int(store.inningsStr)
        store.draft.matchNumber        = Int(store.matchNumberStr)

        // Build "score/needed" strings
        let myS  = Int(store.myScoreStr);       let myN  = Int(store.myNeededStr)
        let oppS = Int(store.opponentScoreStr); let oppN = Int(store.opponentNeededStr)
        if let s = myS,  let n = myN  { store.draft.myScore       = "\(s)/\(n)" }
        else if let s = myS           { store.draft.myScore       = "\(s)" }
        if let s = oppS, let n = oppN { store.draft.opponentScore = "\(s)/\(n)" }
        else if let s = oppS          { store.draft.opponentScore = "\(s)" }

        // Team points are separate from game score — use their own fields
        store.draft.myTeamPoints       = Int(store.myTeamPointsStr)
        store.draft.opponentTeamPoints = Int(store.opponentTeamPointsStr)
        store.draft.notes              = store.matchNotes

        isSaving = true
        do {
            let sessionID = try await notion.logBilliardsSession(store.draft)
            savedSessionID = sessionID
            loggedCount += 1
            // Values stay readable so the confirmation screen and Log Another
            // still work, but the draft stops counting as unsaved work — a
            // torn-down sheet must not resurrect a match already in Notion.
            store.markSaved()
            done = true
        } catch {
            saveError = error.localizedDescription
        }
        isSaving = false
    }

    // MARK: – Log another (keeps date + visitID, increments match number)

    private func logAnother() {
        store.beginNext(defaultSL: defaultSL,
                        eightBallDefault: weekday == 4,
                        nextMatchNumber: (store.draft.matchNumber ?? loggedCount) + 1)
        savedSessionID  = nil
        postSaveNotes   = ""
        linkedVisitName = nil
        resumedDraft    = false
        scanError       = nil
        selectedPhoto   = nil
        done = false
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

// MARK: - Billiards Visit Linker Sheet

struct BilliardsVisitLinkerSheet: View {
    @Environment(NotionService.self) private var notion
    @Environment(\.dismiss) private var dismiss

    let sessionID: String
    var onLink: (String, String) -> Void   // (visitID, visitName)

    @State private var isLinking = false
    @State private var errorMessage: String?

    /// Visits to billiards places in the last 30 days, newest first.
    private var candidateVisits: [Visit] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        let billiardsPlaceIDs = Set(
            notion.places
                .filter { $0.category.lowercased() == "billiards" }
                .map { $0.id }
        )
        return notion.visits
            .filter { billiardsPlaceIDs.contains($0.placeID) && $0.date >= cutoff }
            .sorted { $0.date > $1.date }
    }

    private func visitLabel(_ v: Visit) -> String {
        let df = DateFormatter(); df.dateFormat = "MMM d"
        return "\(v.placeName) · \(df.string(from: v.date))"
    }

    var body: some View {
        NavigationStack {
            Group {
                if candidateVisits.isEmpty {
                    ContentUnavailableView(
                        "No recent billiards visits",
                        systemImage: "8.circle",
                        description: Text("No billiards place visits found in the last 30 days.")
                    )
                } else {
                    List(candidateVisits) { visit in
                        Button {
                            Task { await link(to: visit) }
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(visit.placeName)
                                    .foregroundStyle(.primary)
                                Text(visit.date.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .disabled(isLinking)
                    }
                }
            }
            .navigationTitle("Link to Visit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .overlay {
                if isLinking { ProgressView() }
            }
            .alert("Link failed", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private func link(to visit: Visit) async {
        isLinking = true
        do {
            try await notion.linkBilliardsSessionToVisit(sessionID: sessionID, visitID: visit.id)
            onLink(visit.id, visitLabel(visit))
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLinking = false
    }
}
