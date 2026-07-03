// TraceMacBilliardsView.swift
// Browse and log billiards sessions from Mac.
// Mac-only — do not add to iOS, Widget, or Share Extension targets.

import SwiftUI
import PhotosUI

// MARK: - Main view

struct TraceMacBilliardsView: View {
    @Environment(NotionService.self) private var notion

    @State private var selectedID: String?
    @State private var showNewSheet = false
    @State private var searchText   = ""
    @State private var isLoading    = false
    @State private var listCollapsed = false

    private var sessions: [BilliardsSession] {
        let sorted = notion.billiardsSessions.sorted { $0.date > $1.date }
        guard !searchText.isEmpty else { return sorted }
        let q = searchText.lowercased()
        return sorted.filter {
            $0.opponent.lowercased().contains(q) ||
            ($0.result?.lowercased().contains(q) ?? false) ||
            ($0.notes?.lowercased().contains(q) ?? false)
        }
    }

    private var selectedSession: BilliardsSession? {
        sessions.first { $0.id == selectedID }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left column — session list
            if !listCollapsed {
                VStack(spacing: 0) {
                    searchBar
                    Divider()
                    if notion.billiardsSessions.isEmpty && isLoading {
                        ProgressView("Loading sessions…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if sessions.isEmpty {
                        emptyState
                    } else {
                        List(sessions, id: \.id, selection: $selectedID) { session in
                            BilliardsSessionRow(session: session)
                                .tag(session.id)
                        }
                        .listStyle(.sidebar)
                        .scrollContentBackground(.hidden)
                        .background(Color(nsColor: .windowBackgroundColor))
                    }
                }
                .frame(width: 260)
            }

            CollapseHandle(isCollapsed: $listCollapsed, collapsesRight: false, showLine: true, panelColor: .clear)

            // Right column — detail / edit panel
            Group {
                if let session = selectedSession {
                    BilliardsSessionDetailPanel(session: session)
                        .environment(notion)
                } else {
                    placeholderDetail
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showNewSheet = true } label: {
                    Label("New Session", systemImage: "plus")
                }
                .help("Log a billiards session (⌘N)")
                .keyboardShortcut("n", modifiers: .command)
            }
        }
        .task {
            isLoading = true
            await notion.fetchBilliardsSessions()
            isLoading = false
        }
        .sheet(isPresented: $showNewSheet) {
            NewBilliardsSessionSheet()
                .environment(notion)
        }
    }

    // MARK: - Sub-views

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.subheadline)
            TextField("Search sessions", text: $searchText)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "circle.grid.3x3")
                .font(.system(size: 40, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            Text("No sessions yet")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Log your first session with the + button above.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var placeholderDetail: some View {
        VStack(spacing: 10) {
            Image(systemName: "circle.grid.3x3")
                .font(.system(size: 48, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            Text("Select a session")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Session list row

private struct BilliardsSessionRow: View {
    let session: BilliardsSession

    private var resultColor: Color {
        switch session.result {
        case "Win":  return .green
        case "Loss": return .red
        default:     return .secondary
        }
    }

    private var scoreLabel: String {
        if let my = session.myScore, let opp = session.opponentScore {
            return "\(my) – \(opp)"
        }
        return session.format
    }

    var body: some View {
        HStack(spacing: 10) {
            // Win/loss dot
            Circle()
                .fill(resultColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.opponent.isEmpty ? "Unknown opponent" : "vs \(session.opponent)")
                    .font(.callout)
                    .fontWeight(.medium)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(session.date, format: .dateTime.month(.abbreviated).day().year())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(scoreLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if let result = session.result {
                Text(result)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(resultColor.opacity(0.15))
                    .foregroundStyle(resultColor)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Session detail panel

private struct BilliardsSessionDetailPanel: View {
    @Environment(NotionService.self) private var notion

    let session: BilliardsSession

    @State private var notes: String = ""
    @State private var isSavingNotes = false
    @State private var saveError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                headerBlock
                scoreBlock
                infoBlock
                notesBlock
            }
            .padding(28)
        }
        .onAppear {
            notes = session.notes ?? ""
        }
        .onChange(of: session.id) { _, _ in
            notes = session.notes ?? ""
        }
    }

    // MARK: Header

    private var headerBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(session.opponent.isEmpty ? "Unknown opponent" : "vs \(session.opponent)")
                    .font(.title)
                    .fontWeight(.semibold)
                if let result = session.result {
                    resultPill(result)
                }
                Spacer()
            }
            Text(session.date, format: .dateTime.weekday(.wide).month(.wide).day().year())
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Score

    private var scoreBlock: some View {
        HStack(spacing: 32) {
            scoreCell(label: "My Score", value: session.myScore ?? "—")
            scoreCell(label: "Opp Score", value: session.opponentScore ?? "—")
            if let innings = session.innings {
                scoreCell(label: "Innings", value: "\(innings)")
            }
            if let mn = session.matchNumber {
                scoreCell(label: "Match #", value: "\(mn)")
            }
            if let mySL = session.mySkillLevel {
                scoreCell(label: "My SL", value: "\(mySL)")
            }
            if let oppSL = session.opponentSkillLevel {
                scoreCell(label: "Opp SL", value: "\(oppSL)")
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func scoreCell(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title3)
                .fontWeight(.semibold)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Info

    private var infoBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Details")
                .font(.headline)

            infoRow("Format", session.format)
            infoRow("Won Lag", session.wonLag ? "Yes" : "No")
            if let mtp = session.myTeamPoints {
                infoRow("My Team Points", "\(mtp)")
            }
            if let otp = session.opponentTeamPoints {
                infoRow("Opp Team Points", "\(otp)")
            }
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 140, alignment: .leading)
            Text(value)
        }
        .font(.subheadline)
    }

    // MARK: Notes

    private var notesBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notes")
                .font(.headline)

            TextEditor(text: $notes)
                .font(.system(.body, design: .default))
                .frame(minHeight: 100, maxHeight: 240)
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                )

            if let err = saveError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
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
                .disabled(isSavingNotes || notes == (session.notes ?? ""))
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
    }

    private func saveNotes() async {
        isSavingNotes = true
        saveError = nil
        do {
            try await notion.updateBilliardsSessionNotes(id: session.id, notes: notes)
        } catch {
            saveError = error.localizedDescription
        }
        isSavingNotes = false
    }

    private func resultPill(_ result: String) -> some View {
        let color: Color = result == "Win" ? .green : .red
        return Text(result)
            .font(.callout)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}

// MARK: - New session sheet

private struct NewBilliardsSessionSheet: View {
    @Environment(NotionService.self) private var notion
    @Environment(\.dismiss) private var dismiss

    @State private var draft   = BilliardsDraft()
    @State private var isSaving = false
    @State private var saveError: String?

    // String fields for numeric input
    @State private var myScoreStr        = ""
    @State private var opponentScoreStr  = ""
    @State private var inningsStr        = ""

    // Scan state
    @State private var scanPickerItem: PhotosPickerItem?
    @State private var isScanning   = false
    @State private var scanError:   String?
    @State private var scanComplete = false

    private let formats = ["8-Ball", "9-Ball", "10-Ball", "One Pocket", "Bank Pool"]
    private let results = ["Win", "Loss"]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("New Billiards Session")
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

            // Form
            Form {
                DatePicker("Date", selection: $draft.date, displayedComponents: .date)
                    .datePickerStyle(.compact)

                TextField("Opponent", text: $draft.opponent)

                Picker("Format", selection: $draft.format) {
                    ForEach(formats, id: \.self) { Text($0).tag($0) }
                }

                Picker("Result", selection: Binding(
                    get: { draft.result ?? "" },
                    set: { draft.result = $0.isEmpty ? nil : $0 }
                )) {
                    Text("—").tag("")
                    ForEach(results, id: \.self) { Text($0).tag($0) }
                }

                HStack {
                    LabeledContent("My Score") {
                        TextField("e.g. 39/38", text: $myScoreStr)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 120)
                    }
                    LabeledContent("Opp Score") {
                        TextField("e.g. 32/38", text: $opponentScoreStr)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 120)
                    }
                }

                TextField("Innings", text: $inningsStr)

                Toggle("Won Lag", isOn: $draft.wonLag)

                LabeledContent("Notes") {
                    TextEditor(text: $draft.notes)
                        .frame(height: 80)
                }

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
                                Label("Scan Scorecard", systemImage: "camera.viewfinder")
                            }
                            .buttonStyle(.bordered)
                            .help("Pick an APA scorecard photo from Photos to auto-fill stats")
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
            .formStyle(.grouped)
            .padding(.horizontal)

            if let err = saveError {
                Text(err).font(.caption).foregroundStyle(.red).padding(.horizontal)
            }
        }
        .frame(width: 480, height: 620)
    }

    // MARK: - Scorecard Scan

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
            let result = try await BilliardsScanService.scan(imageData: data)
            applyBilliardsScanResult(result)
            withAnimation { scanComplete = true }
        } catch {
            scanError = error.localizedDescription
        }
    }

    private func applyBilliardsScanResult(_ result: BilliardsScanResult) {
        if let fmt = result.format { draft.format = fmt }

        // Identify David's row: check name match, default to player1
        let p1 = (result.player1Name ?? "").lowercased()
        let p2 = (result.player2Name ?? "").lowercased()
        let iAmP1: Bool
        if p1.contains("david") || p1.contains("weiss") { iAmP1 = true  }
        else if p2.contains("david") || p2.contains("weiss") { iAmP1 = false }
        else { iAmP1 = true }

        let myScore   = iAmP1 ? result.player1Score   : result.player2Score
        let myNeeded  = iAmP1 ? result.player1Needed  : result.player2Needed
        let oppScore  = iAmP1 ? result.player2Score   : result.player1Score
        let oppNeeded = iAmP1 ? result.player2Needed  : result.player1Needed
        let oppName   = iAmP1 ? result.player2Name    : result.player1Name
        let winnerKey = result.winner
        let lagKey    = result.lagWinner

        if let n = oppName, !n.isEmpty { draft.opponent = n }
        if let inn = result.innings { inningsStr = "\(inn)" }

        // Score strings as "score/needed"
        if let s = myScore, let n = myNeeded { myScoreStr = "\(s)/\(n)" }
        else if let s = myScore              { myScoreStr = "\(s)" }
        if let s = oppScore, let n = oppNeeded { opponentScoreStr = "\(s)/\(n)" }
        else if let s = oppScore               { opponentScoreStr = "\(s)" }

        // Result: prefer score comparison, fall back to scan winner field
        let myS = myScore ?? -1;  let myN = myNeeded ?? Int.max
        let opS = oppScore ?? -1; let opN = oppNeeded ?? Int.max
        if      myS >= myN && myN > 0 { draft.result = "Win"  }
        else if opS >= opN && opN > 0 { draft.result = "Loss" }
        else if let wk = winnerKey {
            let myWon = (iAmP1 && wk == "player1") || (!iAmP1 && wk == "player2")
            draft.result = myWon ? "Win" : "Loss"
        }

        // Lag
        if let lk = lagKey {
            draft.wonLag = (iAmP1 && lk == "player1") || (!iAmP1 && lk == "player2")
        }
    }

    private func save() async {
        draft.myScore       = myScoreStr.isEmpty ? nil : myScoreStr
        draft.opponentScore = opponentScoreStr.isEmpty ? nil : opponentScoreStr
        draft.innings       = Int(inningsStr)

        isSaving  = true
        saveError = nil
        do {
            _ = try await notion.logBilliardsSession(draft)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
        isSaving = false
    }
}
