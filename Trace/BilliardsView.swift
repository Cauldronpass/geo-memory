import SwiftUI

struct BilliardsView: View {
    @Environment(NotionService.self) private var notion
    @State private var showingWizard    = false
    @State private var isRefreshing    = false
    @State private var formatFilter: String? = nil    // nil = All, "8-Ball", "9-Ball"
    @State private var opponentFilter: String? = nil  // nil = All, else opponent name

    // MARK: - Source data

    private var allSessions: [BilliardsSession] { notion.billiardsSessions }

    private var opponents: [String] {
        Array(Set(allSessions.map { $0.opponent }.filter { !$0.isEmpty })).sorted()
    }

    private var filtered: [BilliardsSession] {
        allSessions.filter { s in
            (formatFilter == nil   || s.format   == formatFilter) &&
            (opponentFilter == nil || s.opponent == opponentFilter)
        }
    }

    private var hasFilter: Bool { formatFilter != nil || opponentFilter != nil }

    private func record(for opponent: String) -> String {
        let s = allSessions.filter { $0.opponent == opponent }
        let w = s.filter { $0.result == "Win" }.count
        let l = s.filter { $0.result == "Loss" }.count
        return "\(w)-\(l)"
    }

    // Stats always computed on the full set so the header stays meaningful
    private var wins: Int   { allSessions.filter { $0.result == "Win" }.count }
    private var losses: Int { allSessions.filter { $0.result == "Loss" }.count }

    private var eightBallW: Int { allSessions.filter { $0.format == "8-Ball" && $0.result == "Win"  }.count }
    private var eightBallL: Int { allSessions.filter { $0.format == "8-Ball" && $0.result == "Loss" }.count }
    private var nineBallW:  Int { allSessions.filter { $0.format == "9-Ball" && $0.result == "Win"  }.count }
    private var nineBallL:  Int { allSessions.filter { $0.format == "9-Ball" && $0.result == "Loss" }.count }

    // Group filtered sessions by date, newest first
    private var grouped: [(date: Date, sessions: [BilliardsSession])] {
        let cal = Calendar.current
        let byDay = Dictionary(grouping: filtered) { cal.startOfDay(for: $0.date) }
        return byDay.keys.sorted(by: >).map { day in
            (date: day, sessions: byDay[day]!.sorted { ($0.matchNumber ?? 0) > ($1.matchNumber ?? 0) })
        }
    }

    // MARK: - Body

    var body: some View {
        Group {
            if allSessions.isEmpty {
                ContentUnavailableView(
                    "No matches yet",
                    systemImage: "8.circle",
                    description: Text("Check in to Arlington Lanes to log your first match.")
                )
            } else {
                List {
                    Section { statsHeader }

                    // Filter chips
                    Section {
                        filterChips
                            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    }
                    .listRowBackground(Color.clear)

                    if filtered.isEmpty {
                        Section {
                            Text("No matches match the current filter.")
                                .foregroundStyle(.secondary)
                                .font(.subheadline)
                        }
                    } else {
                        ForEach(grouped, id: \.date) { group in
                            Section {
                                ForEach(group.sessions) { session in
                                    NavigationLink(destination: BilliardsSessionDetailView(session: session)) {
                                        SessionRow(session: session)
                                    }
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        Button(role: .destructive) {
                                            Task { try? await notion.deleteBilliardsSession(id: session.id) }
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                }
                            } header: {
                                Text(group.date.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Billiards")
        .navigationBarTitleDisplayMode(.large)
        .drawerToolbar()
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    isRefreshing = true
                    Task {
                        await notion.fetchBilliardsSessions()
                        isRefreshing = false
                    }
                } label: {
                    if isRefreshing {
                        ProgressView().scaleEffect(0.8)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(isRefreshing)
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showingWizard = true } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingWizard) {
            Task { await notion.fetchBilliardsSessions() }
        } content: {
            BilliardsWizardView()
                .environment(notion)
        }
        .task {
            if allSessions.isEmpty {
                await notion.fetchBilliardsSessions()
            }
        }
    }

    // MARK: - Stats header

    private var statsHeader: some View {
        VStack(spacing: 12) {
            HStack(spacing: 0) {
                statPill(value: "\(wins)",   label: "Wins",    color: .green)
                Spacer()
                statPill(value: "\(losses)", label: "Losses",  color: .red)
                Spacer()
                statPill(value: "\(allSessions.count)", label: "Matches", color: .primary)
            }
            Divider()
            HStack(spacing: 20) {
                formatStat(label: "8-Ball", wins: eightBallW, losses: eightBallL)
                formatStat(label: "9-Ball", wins: nineBallW,  losses: nineBallL)
                Spacer()
            }
        }
        .padding(.vertical, 4)
    }

    private func statPill(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title2.bold()).foregroundStyle(color)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(minWidth: 60)
    }

    private func formatStat(label: String, wins: Int, losses: Int) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text("\(wins)-\(losses)").font(.caption).foregroundStyle(.primary)
        }
    }

    // MARK: - Filter chips

    private var filterChips: some View {
        HStack(spacing: 8) {
            // Format filter
            filterChip(label: "8-Ball", isActive: formatFilter == "8-Ball") {
                formatFilter = formatFilter == "8-Ball" ? nil : "8-Ball"
            }
            filterChip(label: "9-Ball", isActive: formatFilter == "9-Ball") {
                formatFilter = formatFilter == "9-Ball" ? nil : "9-Ball"
            }

            // Opponent dropdown
            if !opponents.isEmpty {
                Menu {
                    Button("All opponents") { opponentFilter = nil }
                    Divider()
                    ForEach(opponents, id: \.self) { opp in
                        Button {
                            opponentFilter = opp
                        } label: {
                            if opponentFilter == opp {
                                Label("\(opp) (\(record(for: opp)))", systemImage: "checkmark")
                            } else {
                                Text("\(opp) (\(record(for: opp)))")
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(opponentFilter.map { "\($0) \(record(for: $0))" } ?? "Opponent")
                            .font(.caption.weight(.semibold))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(opponentFilter != nil ? Color.green : Color(.secondarySystemGroupedBackground))
                    .foregroundStyle(opponentFilter != nil ? Color.white : Color.primary)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            // Clear button
            if hasFilter {
                Button {
                    formatFilter   = nil
                    opponentFilter = nil
                } label: {
                    Text("Clear")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
            }

            Spacer()
        }
        .padding(.vertical, 2)
    }

    private func filterChip(label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isActive ? Color.green : Color(.secondarySystemGroupedBackground))
                .foregroundStyle(isActive ? .white : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Session row

private struct SessionRow: View {
    let session: BilliardsSession

    private var resultColor: Color {
        switch session.result {
        case "Win":  return .green
        case "Loss": return .red
        default:     return .secondary
        }
    }

    private var scoreDisplay: String {
        let my = session.myScore ?? "—"
        let op = session.opponentScore ?? "—"
        return "\(my) · \(op)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                if let result = session.result {
                    Text(result)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(resultColor, in: Capsule())
                }
                Text(session.format)
                    .font(.caption).foregroundStyle(.secondary)
                if let matchNo = session.matchNumber {
                    Text("M\(matchNo)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let myTP = session.myTeamPoints {
                    Text("\(myTP) pts")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(myTP > 0 ? .green : .secondary)
                }
            }

            HStack {
                Text("vs \(session.opponent.isEmpty ? "Opponent" : session.opponent)")
                    .font(.body).foregroundStyle(.primary)
                Spacer()
                Text(scoreDisplay)
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }

            if let notes = session.notes, !notes.isEmpty {
                Text(notes)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Session detail

struct BilliardsSessionDetailView: View {
    let session: BilliardsSession
    @Environment(NotionService.self) private var notion
    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteConfirm = false
    @State private var isDeleting = false

    private var resultColor: Color {
        switch session.result {
        case "Win":  return .green
        case "Loss": return .red
        default:     return .secondary
        }
    }

    var body: some View {
        List {
            // Hero result
            Section {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        if let result = session.result {
                            Text(result)
                                .font(.largeTitle.bold())
                                .foregroundStyle(resultColor)
                        }
                        Text("vs \(session.opponent.isEmpty ? "Opponent" : session.opponent)")
                            .font(.title3)
                            .foregroundStyle(.primary)
                        Text(session.date.formatted(.dateTime.weekday(.wide).month(.wide).day().year()))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }

            // Scores
            Section("Scores") {
                detailRow(label: "Format", value: session.format)
                detailRow(label: "My score",       value: session.myScore ?? "—")
                detailRow(label: "Opponent score",  value: session.opponentScore ?? "—")
                if let myTP = session.myTeamPoints {
                    detailRow(label: "My team pts", value: "\(myTP)")
                }
                if let opTP = session.opponentTeamPoints {
                    detailRow(label: "Opponent team pts", value: "\(opTP)")
                }
                if let inn = session.innings {
                    detailRow(label: "Innings", value: "\(inn)")
                }
            }

            // Skill levels
            Section("Players") {
                if let mySL = session.mySkillLevel {
                    detailRow(label: "My SL", value: "\(mySL)")
                }
                if let oppSL = session.opponentSkillLevel {
                    detailRow(label: "Opponent SL", value: "\(oppSL)")
                }
                detailRow(label: "Won lag", value: session.wonLag ? "Yes" : "No")
                if let matchNo = session.matchNumber {
                    detailRow(label: "Match #", value: "\(matchNo)")
                }
            }

            // Notes
            if let notes = session.notes, !notes.isEmpty {
                Section("Notes") {
                    Text(notes)
                        .font(.body)
                        .foregroundStyle(.primary)
                }
            }

            // Delete
            Section {
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    HStack {
                        Spacer()
                        if isDeleting {
                            ProgressView()
                        } else {
                            Text("Delete Match")
                        }
                        Spacer()
                    }
                }
            }
        }
        .navigationTitle("\(session.format) · \(session.date.formatted(.dateTime.month(.abbreviated).day()))")
        .navigationBarTitleDisplayMode(.inline)
        .drawerToolbar()
        .confirmationDialog("Delete this match?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                isDeleting = true
                Task {
                    try? await notion.deleteBilliardsSession(id: session.id)
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).foregroundStyle(.primary)
        }
    }
}
