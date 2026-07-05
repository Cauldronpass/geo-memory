// TraceMacJournalView.swift
// Journal section for Trace Mac — Daily, Projects, Places.
// Mac-only — do not add to iOS, Widget, or Share Extension targets.

import SwiftUI
import AppKit

// MARK: - Notification for Horizons deep-link from calendar panel

extension Notification.Name {
    static let openHorizonsFile  = Notification.Name("trace.openHorizonsFile")
    static let openWikilink      = Notification.Name("trace.openWikilink")
    static let selectPerson      = Notification.Name("trace.selectPerson")
    static let selectPlace       = Notification.Name("trace.selectPlace")
    static let selectDocument    = Notification.Name("trace.selectDocument")
    static let reloadDocuments   = Notification.Name("trace.reloadDocuments")
    /// Navigate to a record from any context. userInfo: ["type": "person"|"place", "id": String]
    static let navigateToRecord  = Notification.Name("trace.navigateToRecord")
}

// MARK: - Journal root (dispatches to the right tab)

struct TraceMacJournalView: View {
    let section: MacSection  // .daily, .projects, or .places
    var deepLinkFile: Binding<String?>? = nil   // set by TraceMacContentView for .horizons deep links

    @Environment(NoteStore.self)     private var noteStore
    @Environment(NotionService.self) private var notionService

    var body: some View {
        switch section {
        case .daily:
            TraceMacDailyView()
                .environment(noteStore)
                .environment(notionService)
        case .projects:
            TraceMacProjectsView()
                .environment(noteStore)
                .environment(notionService)
        case .horizons:
            TraceMacNoteListView(
                subfolder: "Notes/Horizons",
                sectionTitle: "Horizons",
                newNotePrompt: "e.g. Week of July 7",
                emptyMessage: "No horizon notes yet.",
                deepLinkFile: deepLinkFile
            )
            .environment(noteStore)
        case .places:
            TraceMacPlaceNoteView()
                .environment(noteStore)
                .environment(notionService)
        default:
            EmptyView()
        }
    }
}

// MARK: - Daily notes — NoteStore backed

struct TraceMacDailyView: View {
    @Environment(NoteStore.self)     private var noteStore
    @Environment(NotionService.self) private var notionService

    @State private var dateFiles: [String] = []
    @State private var selectedDateFile: String? = nil
    @State private var sidebarCollapsed = false
    @State private var calendarCollapsed = false
    @State private var searchText = ""

    private let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private var datesWithEntries: Set<String> {
        Set(dateFiles.map { $0.replacingOccurrences(of: ".md", with: "") })
    }

    private var filteredFiles: [String] {
        guard !searchText.isEmpty else { return dateFiles }
        return dateFiles.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    private func label(for filename: String) -> String {
        let dateStr = filename.replacingOccurrences(of: ".md", with: "")
        guard let date = dateFmt.date(from: dateStr) else { return dateStr }
        let cal = Calendar.current
        if cal.isDateInToday(date)     { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    var body: some View {
        HStack(spacing: 0) {
            // Column 1: date list (fixed 200pt — same pattern as TraceMacProjectsView)
            if !sidebarCollapsed {
                VStack(spacing: 0) {
                    TextField("Search", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .padding(10)
                    if dateFiles.isEmpty {
                        Spacer()
                        Text("No daily notes yet.")
                            .font(.caption).foregroundStyle(.secondary).padding()
                        Spacer()
                    } else {
                        List(filteredFiles, id: \.self, selection: $selectedDateFile) { file in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(label(for: file))
                                    .font(.system(.callout, weight: .medium))
                                Text(file.replacingOccurrences(of: ".md", with: ""))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                            .tag(file as String?)
                        }
                        .listStyle(.sidebar)
                        .scrollContentBackground(.hidden)
                        .background(Color(nsColor: .windowBackgroundColor))
                    }
                }
                .frame(width: 200)
            }

            CollapseHandle(isCollapsed: $sidebarCollapsed, collapsesRight: false,
                           showLine: true, panelColor: .clear)

            // Columns 2+3: flexible region (editor + fixed calendar) — mirrors the
            // Projects hub layout (editor .frame(maxWidth:) + fixed-width sidebar
            // inside a Group .frame(maxWidth: .infinity)).
            Group {
                HStack(spacing: 0) {
                    editorColumn
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    // Handle lives outside the `if !calendarCollapsed` block (same
                    // pattern as the date-list handle above) so it's still there to
                    // re-expand the panel once collapsed — previously this was a
                    // plain separator Rectangle inside the conditional, so there was
                    // no way to bring the calendar back except the ⌘⇧K toolbar toggle.
                    CollapseHandle(isCollapsed: $calendarCollapsed, collapsesRight: true,
                                   showLine: true, panelColor: .clear)

                    if !calendarCollapsed {
                        TraceMacCalendarPanel(
                            selectedDateFile: $selectedDateFile,
                            datesWithEntries: datesWithEntries,
                            onOpenHorizonsNote: { filename in
                                NotificationCenter.default.post(
                                    name: .openHorizonsFile,
                                    object: nil,
                                    userInfo: ["filename": filename]
                                )
                            }
                        )
                        .frame(width: 240)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .onChange(of: selectedDateFile) { _, newFile in
            guard let f = newFile else { return }
            ensureFileExists(f)
        }
        .task { await loadDates() }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                        sidebarCollapsed.toggle()
                    }
                } label: { Label("Toggle List", systemImage: "sidebar.leading") }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Today") { openToday() }
            }
            ToolbarItem {
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                        calendarCollapsed.toggle()
                    }
                } label: { Label("Toggle Calendar", systemImage: "calendar") }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            }
        }
    }

    // MARK: - Editor column

    @ViewBuilder
    private var editorColumn: some View {
        if let file = selectedDateFile,
           let date = dateFmt.date(from: file.replacingOccurrences(of: ".md", with: "")) {
            TraceMacNoteEditor(
                relativePath: "Calendar/\(file)",
                showMoveButton: true,
                moveSourceDate: date
            )
            .environment(noteStore)
            .environment(notionService)
        } else {
            VStack(spacing: 16) {
                Spacer()
                Text("Select a date")
                    .font(.callout).foregroundStyle(.tertiary)
                Button("Open Today") { openToday() }
                    .buttonStyle(.borderedProminent)
                Spacer()
            }
        }
    }

    // MARK: - Actions

    private func openToday() {
        let filename = dateFmt.string(from: Date()) + ".md"
        ensureFileExists(filename)
        selectedDateFile = filename
    }

    private func ensureFileExists(_ filename: String) {
        let path = "Calendar/\(filename)"
        if (try? noteStore.readFile(path)) == nil {
            try? noteStore.writeFile(path, content: "")
        }
        if !dateFiles.contains(filename) {
            dateFiles.insert(filename, at: 0)
        }
    }

    private func loadDates() async {
        let files = (try? noteStore.listFiles(in: "Calendar")) ?? []
        let sorted = files
            .filter { $0.hasSuffix(".md") }
            .filter { dateFmt.date(from: $0.replacingOccurrences(of: ".md", with: "")) != nil }
            .sorted(by: >)
        await MainActor.run {
            dateFiles = sorted
            if selectedDateFile == nil {
                let todayFile = dateFmt.string(from: Date()) + ".md"
                if sorted.contains(todayFile) { selectedDateFile = todayFile }
            }
        }
    }
}

// MARK: - Mac daily move sheet

struct MacDailyMoveSheet: View {
    let sourceDate: Date
    let sourceContent: String
    let onMoved: () -> Void

    @Environment(NotionService.self) private var notionService
    @Environment(NoteStore.self)     private var noteStore
    @Environment(\.dismiss)          private var dismiss

    enum Dest: String, CaseIterable {
        case day, visit, project, horizon, place
        var label: String {
            switch self {
            case .day:     return "Another Day"
            case .visit:   return "Visit"
            case .project: return "Project"
            case .horizon: return "Horizon"
            case .place:   return "Place"
            }
        }
        var icon: String {
            switch self {
            case .day:     return "calendar"
            case .visit:   return "checkmark.circle"
            case .project: return "folder"
            case .horizon: return "square.stack"
            case .place:   return "mappin"
            }
        }
    }

    @State private var dest: Dest = .day
    @State private var targetDate = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    @State private var showDatePopover = false
    @State private var selectedVisit: Visit? = nil
    @State private var selectedPlace: Place? = nil
    @State private var selectedFile: String? = nil
    @State private var files: [String] = []
    @State private var searchText = ""
    @State private var isMoving = false
    @State private var errorMessage: String? = nil

    private let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private var canMove: Bool {
        switch dest {
        case .day:               return !isSameAsSource
        case .visit:             return selectedVisit != nil
        case .place:             return selectedPlace != nil
        case .project, .horizon: return selectedFile != nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Move Content").font(.title3.weight(.semibold))
                Spacer()
                Button("Cancel") { dismiss() }
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
            Divider()

            // Destination type pills
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Dest.allCases, id: \.rawValue) { d in
                        Button {
                            dest = d
                            selectedVisit = nil; selectedPlace = nil
                            selectedFile = nil; searchText = ""
                        } label: {
                            Label(d.label, systemImage: d.icon)
                                .font(.subheadline.weight(dest == d ? .semibold : .regular))
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(
                                    dest == d ? Color.accentColor
                                              : Color(nsColor: .controlBackgroundColor),
                                    in: Capsule()
                                )
                                .foregroundStyle(dest == d ? .white : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
            Divider()

            // Content preview
            Text(sourceContent.prefix(200))
                .font(.callout).foregroundStyle(.secondary)
                .lineLimit(4)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 4)

            // Destination-specific picker
            Group {
                switch dest {
                case .day:     dayPicker
                case .visit:   visitList
                case .project: fileListView(subfolder: "Notes/Projects")
                case .horizon: horizonListView
                case .place:   placeList
                }
            }

            if let err = errorMessage {
                Text(err).font(.caption).foregroundStyle(.red)
                    .padding(.horizontal, 20).padding(.bottom, 4)
            }

            Spacer(minLength: 0)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                if isMoving {
                    ProgressView().controlSize(.small).padding(.trailing, 4)
                } else {
                    Button("Move") { Task { await performMove() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canMove)
                }
            }
            .padding(16)
        }
        .frame(width: 440, height: 560)
        .task(id: dest) { await loadFilesForDest() }
    }

    // MARK: Day picker

    private var isSameAsSource: Bool {
        Calendar.current.isDate(targetDate, inSameDayAs: sourceDate)
    }

    private var dayPicker: some View {
        VStack(spacing: 4) {
            DatePicker("", selection: $targetDate, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .padding(.horizontal, 16)
                .frame(maxWidth: 360)
            if isSameAsSource {
                Text("Same as source — pick a different date.")
                    .font(.caption).foregroundStyle(.red)
            }
        }
    }

    // MARK: Visit list

    private var filteredVisits: [Visit] {
        let sorted = notionService.visits.sorted { $0.date > $1.date }
        if searchText.isEmpty { return Array(sorted.prefix(40)) }
        return sorted.filter { $0.placeName.localizedCaseInsensitiveContains(searchText) }
    }

    private var visitList: some View {
        VStack(spacing: 0) {
            TextField("Search visits", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 20).padding(.top, 8)
            List(filteredVisits) { visit in
                Button { selectedVisit = visit } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(visit.placeName).foregroundStyle(.primary)
                            Text(visit.date.formatted(.dateTime.month(.abbreviated).day().year()))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if selectedVisit?.id == visit.id {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.accentColor).fontWeight(.semibold)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Project / general file list

    private func fileListView(subfolder: String) -> some View {
        VStack(spacing: 0) {
            TextField("Search", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 20).padding(.top, 8)
            if files.isEmpty {
                Spacer()
                Text("No files found.").font(.caption).foregroundStyle(.secondary)
                Spacer()
            } else {
                let filtered = files.filter {
                    searchText.isEmpty || $0.localizedCaseInsensitiveContains(searchText)
                }
                List(filtered, id: \.self) { file in
                    Button { selectedFile = file } label: {
                        HStack {
                            Image(systemName: "doc.text").foregroundStyle(.secondary)
                            Text(file.replacingOccurrences(of: ".md", with: "")).foregroundStyle(.primary)
                            Spacer()
                            if selectedFile == file {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor).fontWeight(.semibold)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Horizon list

    private static let isoCal: Calendar = {
        var c = Calendar(identifier: .iso8601)
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()

    private var currentWeekFile: String {
        let wk = Self.isoCal.component(.weekOfYear, from: Date())
        let yr = Self.isoCal.component(.yearForWeekOfYear, from: Date())
        return String(format: "%d-W%02d.md", yr, wk)
    }

    private var currentMonthFile: String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM"
        return "\(f.string(from: Date())).md"
    }

    private var horizonListView: some View {
        List {
            Section("This Period") {
                horizonRow(file: currentWeekFile,
                           label: "Week \(Self.isoCal.component(.weekOfYear, from: Date()))",
                           icon: "calendar.badge.clock")
                horizonRow(file: currentMonthFile,
                           label: Date().formatted(.dateTime.month(.wide).year()),
                           icon: "calendar")
            }
            let past = files.filter { $0 != currentWeekFile && $0 != currentMonthFile }.sorted(by: >)
            if !past.isEmpty {
                Section("Past") {
                    ForEach(past, id: \.self) { file in
                        horizonRow(file: file,
                                   label: file.replacingOccurrences(of: ".md", with: ""),
                                   icon: "doc.text")
                    }
                }
            }
        }
    }

    private func horizonRow(file: String, label: String, icon: String) -> some View {
        Button { selectedFile = file } label: {
            HStack {
                Image(systemName: icon).foregroundStyle(.secondary)
                Text(label).foregroundStyle(.primary)
                Spacer()
                if selectedFile == file {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor).fontWeight(.semibold)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Place list

    private var filteredPlaces: [Place] {
        let sorted = notionService.places.sorted { $0.name < $1.name }
        if searchText.isEmpty { return sorted }
        return sorted.filter { $0.name.localizedCaseInsensitiveContains(searchText) ||
                               $0.city.localizedCaseInsensitiveContains(searchText) }
    }

    private var placeList: some View {
        VStack(spacing: 0) {
            TextField("Search places", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 20).padding(.top, 8)
            if notionService.places.isEmpty {
                Spacer()
                Text("No places loaded.").font(.caption).foregroundStyle(.secondary)
                Spacer()
            } else {
                List(filteredPlaces) { place in
                    Button { selectedPlace = place } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(place.name).foregroundStyle(.primary)
                                if !place.city.isEmpty {
                                    Text(place.city).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if selectedPlace?.id == place.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor).fontWeight(.semibold)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .task {
            if notionService.places.isEmpty { await notionService.fetchPlaces() }
        }
    }

    // MARK: Data loading

    private func loadFilesForDest() async {
        let subfolder: String
        switch dest {
        case .project: subfolder = "Notes/Projects"
        case .horizon: subfolder = "Notes/Horizons"
        default: return
        }
        let list = (try? noteStore.listFiles(in: subfolder)) ?? []
        await MainActor.run { files = list.filter { $0.hasSuffix(".md") }.sorted(by: >) }
    }

    // MARK: Perform move

    private func performMove() async {
        isMoving = true
        errorMessage = nil
        do {
            switch dest {
            case .day:
                let path = "Calendar/\(dateFmt.string(from: targetDate)).md"
                try appendToFile(path: path, header: dateFmt.string(from: targetDate))
            case .visit:
                guard let visit = selectedVisit else { return }
                try await notionService.appendVisitNotes(visitID: visit.id, text: stripped(sourceContent))
            case .project:
                guard let file = selectedFile else { return }
                try appendToFile(path: "Notes/Projects/\(file)",
                                 header: file.replacingOccurrences(of: ".md", with: ""))
            case .horizon:
                guard let file = selectedFile else { return }
                try appendToFile(path: "Notes/Horizons/\(file)",
                                 header: file.replacingOccurrences(of: ".md", with: ""))
            case .place:
                guard let place = selectedPlace else { return }
                try appendToFile(path: "Notes/Places/\(place.name).md", header: place.name)
            }
            await MainActor.run { onMoved(); dismiss() }
        } catch {
            await MainActor.run { errorMessage = error.localizedDescription; isMoving = false }
        }
    }

    private func appendToFile(path: String, header: String) throws {
        let text = stripped(sourceContent)
        let existing = (try? noteStore.readFile(path)) ?? ""
        let updated = existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "# \(header)\n\n\(text)"
            : existing + "\n\n" + text
        try noteStore.writeFile(path, content: updated)
    }

    private func stripped(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        if let first = lines.first,
           first.hasPrefix("# "),
           first.dropFirst(2).range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
            lines.removeFirst()
            while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
        }
        return lines.joined(separator: "\n")
    }
}


// MARK: - Hover-reveal collapse handle

/// A 12-wide hit zone containing a 1px separator and a hover-reveal circle button.
/// collapsesRight = true  → manages the panel to the RIGHT (e.g. calendar)
/// collapsesRight = false → manages the panel to the LEFT  (e.g. file list)
/// 12px HStack element with a hover-reveal circle collapse button.
///
/// showLine:    draw a separator at the LEADING edge of the zone (the panel boundary)
/// lineWidth:   separator width in points (default 1)
/// panelColor:  fill the zone with this color — use calendarGray on the calendar side
///              so the 12px zone merges into the 240px calendar panel visually
struct CollapseHandle: View {
    @Binding var isCollapsed: Bool
    let collapsesRight: Bool
    var showLine: Bool = true
    var lineWidth: CGFloat = 1
    var panelColor: Color = .clear

    @State private var isHovering = false

    private var icon: String {
        collapsesRight
            ? (isCollapsed ? "chevron.left"  : "chevron.right")
            : (isCollapsed ? "chevron.right" : "chevron.left")
    }

    var body: some View {
        ZStack {
            panelColor  // fills the zone — blends handle into the adjacent shaded panel

            if showLine {
                // Separator pinned to the LEADING edge of the zone so it sits exactly
                // at the panel boundary (white editor → separator → gray calendar).
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor))
                        .frame(width: lineWidth)
                    Spacer(minLength: 0)
                }
            }

            Button {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                    isCollapsed.toggle()
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(Color(nsColor: .windowBackgroundColor))
                        .overlay(Circle().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.14), radius: 2, x: 0, y: 1)
                        .frame(width: 18, height: 18)
                    Image(systemName: icon)
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .opacity(isHovering ? 1 : 0)
            .animation(.easeInOut(duration: 0.12), value: isHovering)
        }
        .frame(width: 12)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }
}

// MARK: - Generic note list (Projects, custom subfolders)

struct TraceMacNoteListView: View {
    let subfolder: String
    let sectionTitle: String
    let newNotePrompt: String
    let emptyMessage: String
    var deepLinkFile: Binding<String?>? = nil   // non-nil triggers selection + clears itself

    @Environment(NoteStore.self) private var noteStore

    @State private var files: [String] = []
    @State private var selectedFile: String? = nil
    @State private var searchText = ""
    @State private var showingNewNote = false
    @State private var newNoteName = ""
    @State private var deleteCandidate: String? = nil
    @State private var showDeleteConfirm = false
    @State private var renameCandidate: String? = nil
    @State private var showRenameSheet = false
    @State private var renameDraft = ""
    @State private var fileListCollapsed = false
    @State private var selectedTags: Set<String> = []
    @State private var allTags: [String] = []
    @State private var fileContents: [String: String] = [:]

    private var filtered: [String] {
        let base = searchText.isEmpty ? files : files.filter { $0.localizedCaseInsensitiveContains(searchText) }
        guard !selectedTags.isEmpty else { return base }
        return base.filter { filename in
            let content = fileContents[filename] ?? ""
            return selectedTags.allSatisfy { content.range(of: "#\($0)", options: .caseInsensitive) != nil }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left: file list
            if !fileListCollapsed {
                VStack(spacing: 0) {
                    TextField("Search", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .padding(10)
                    MacTagChipRow(tags: allTags, selected: $selectedTags)

                    if files.isEmpty {
                        Spacer()
                        Text(emptyMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding()
                        Spacer()
                    } else {
                        List(filtered, id: \.self, selection: $selectedFile) { filename in
                            Text(filename.replacingOccurrences(of: ".md", with: ""))
                                .font(.system(.callout, weight: .medium))
                                .lineLimit(1)
                                .padding(.vertical, 4)
                                .tag(filename)
                                .contextMenu {
                                    Button {
                                        renameCandidate = filename
                                        renameDraft = filename.replacingOccurrences(of: ".md", with: "")
                                        showRenameSheet = true
                                    } label: {
                                        Label("Rename", systemImage: "pencil")
                                    }
                                    Divider()
                                    Button(role: .destructive) {
                                        deleteCandidate = filename
                                        showDeleteConfirm = true
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                        }
                        .listStyle(.sidebar)
                        .scrollContentBackground(.hidden)
                        .background(Color(nsColor: .windowBackgroundColor))
                    }
                }
                .frame(width: 200)
            }

            CollapseHandle(
                isCollapsed: $fileListCollapsed,
                collapsesRight: false,
                showLine: true,
                panelColor: .clear
            )

            // Right: editor (with optional horizon calendar header)
            Group {
                if let file = selectedFile {
                    VStack(spacing: 0) {
                        if let kind = HorizonKind(filename: file) {
                            HorizonCalendarHeader(kind: kind)
                                .padding(.horizontal, 24)
                                .padding(.top, 16)
                                .padding(.bottom, 12)
                            Divider()
                        }
                        TraceMacNoteEditor(relativePath: "\(subfolder)/\(file)")
                            .environment(noteStore)
                    }
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 40, weight: .thin))
                            .foregroundStyle(.tertiary)
                        Text("Select a note or create one")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingNewNote = true } label: {
                    Label("New Note", systemImage: "plus")
                }
            }
            if let file = selectedFile {
                ToolbarItem {
                    Button(role: .destructive) {
                        deleteCandidate = file
                        showDeleteConfirm = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .keyboardShortcut(.delete, modifiers: .command)
                }
            }
        }
        .confirmationDialog(
            "Delete \"\(deleteCandidate?.replacingOccurrences(of: ".md", with: "") ?? "")\"?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let f = deleteCandidate { deleteNote(f) }
            }
            Button("Cancel", role: .cancel) { }
        }
        .sheet(isPresented: $showingNewNote) {
            newNoteSheet
        }
        .sheet(isPresented: $showRenameSheet) {
            renameSheet
        }
        .task { await loadFiles() }
        .task(id: deepLinkFile?.wrappedValue) {
            guard let filename = deepLinkFile?.wrappedValue else { return }
            if files.isEmpty {
                let loaded = (try? noteStore.listFiles(in: subfolder)) ?? []
                files = loaded.sorted()
            }
            if !files.contains(filename) {
                files.append(filename)
                files.sort()
            }
            selectedFile = filename
            deepLinkFile?.wrappedValue = nil
        }
    }

    private var newNoteSheet: some View {
        VStack(spacing: 16) {
            Text("New \(sectionTitle) Note")
                .font(.headline)
            TextField(newNotePrompt, text: $newNoteName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit { createNote() }
            HStack {
                Button("Cancel") {
                    newNoteName = ""
                    showingNewNote = false
                }
                Button("Create") { createNote() }
                    .buttonStyle(.borderedProminent)
                    .disabled(newNoteName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
    }

    private var renameSheet: some View {
        VStack(spacing: 16) {
            Text("Rename Note")
                .font(.headline)
            TextField("Name", text: $renameDraft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit { renameNote() }
            HStack {
                Button("Cancel") {
                    showRenameSheet = false
                    renameCandidate = nil
                }
                Button("Rename") { renameNote() }
                    .buttonStyle(.borderedProminent)
                    .disabled(renameDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
    }

    private func loadFiles() async {
        let loaded = (try? noteStore.listFiles(in: subfolder)) ?? []
        files = loaded.sorted()
        let sf = subfolder
        var contents: [String: String] = [:]
        var tagSet = Set<String>()
        let regex = try? NSRegularExpression(pattern: #"(?<![&\w])#([a-zA-Z][a-zA-Z0-9_]*)"#)
        for filename in files {
            let content = (try? noteStore.readFile("\(sf)/\(filename)")) ?? ""
            contents[filename] = content
            guard let regex else { continue }
            let ns = content as NSString
            regex.enumerateMatches(in: content, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                if let m, let r = Range(m.range(at: 1), in: content) {
                    tagSet.insert(String(content[r]).lowercased())
                }
            }
        }
        fileContents = contents
        allTags = tagSet.sorted()
    }

    private func renameNote() {
        guard let old = renameCandidate else { return }
        let newName = renameDraft.trimmingCharacters(in: .whitespaces)
        guard !newName.isEmpty else { return }
        let newFilename = newName + ".md"
        guard newFilename != old else {
            showRenameSheet = false; renameCandidate = nil; return
        }
        try? noteStore.moveFile(from: "\(subfolder)/\(old)", to: "\(subfolder)/\(newFilename)")
        if let idx = files.firstIndex(of: old) {
            files[idx] = newFilename
            files.sort()
        }
        if selectedFile == old { selectedFile = newFilename }
        showRenameSheet = false
        renameCandidate = nil
    }

    private func deleteNote(_ filename: String) {
        try? noteStore.deleteFile("\(subfolder)/\(filename)")
        files.removeAll { $0 == filename }
        if selectedFile == filename { selectedFile = nil }
        deleteCandidate = nil
    }

    private func createNote() {
        let name = newNoteName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let filename = "\(name).md"
        let path = "\(subfolder)/\(filename)"
        try? noteStore.writeFile(path, content: "# \(name)\n\n")
        if !files.contains(filename) {
            files.append(filename)
            files.sort()
        }
        selectedFile = filename
        newNoteName = ""
        showingNewNote = false
    }
}

// MARK: - Projects view (hub layout: editor + Documents/People/Places tabs)

struct TraceMacProjectsView: View {
    private let subfolder = "Notes/Projects"

    @Environment(NoteStore.self)     private var noteStore
    @Environment(NotionService.self) private var notionService

    @State private var files: [String] = []
    @State private var selectedFile: String? = nil
    @State private var searchText = ""
    @State private var showingNewNote = false
    @State private var newNoteName = ""
    @State private var deleteCandidate: String? = nil
    @State private var showDeleteConfirm = false
    @State private var renameCandidate: String? = nil
    @State private var showRenameSheet = false
    @State private var renameDraft = ""
    @State private var fileListCollapsed = false
    @State private var docStore: TraceMacDocumentStore? = nil
    @State private var selectedTags: Set<String> = []
    @State private var allTags: [String] = []
    @State private var fileContents: [String: String] = [:]

    private var filtered: [String] {
        let base = searchText.isEmpty ? files : files.filter { $0.localizedCaseInsensitiveContains(searchText) }
        guard !selectedTags.isEmpty else { return base }
        return base.filter { filename in
            let content = fileContents[filename] ?? ""
            return selectedTags.allSatisfy { content.range(of: "#\($0)", options: .caseInsensitive) != nil }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left: project list
            if !fileListCollapsed {
                VStack(spacing: 0) {
                    TextField("Search", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .padding(10)
                    MacTagChipRow(tags: allTags, selected: $selectedTags)

                    if files.isEmpty {
                        Spacer()
                        Text("No projects yet.")
                            .font(.caption).foregroundStyle(.secondary).padding()
                        Spacer()
                    } else {
                        List(filtered, id: \.self, selection: $selectedFile) { filename in
                            Label(
                                filename.replacingOccurrences(of: ".md", with: ""),
                                systemImage: "folder.fill"
                            )
                            .font(.system(.callout, weight: .medium))
                            .lineLimit(1)
                            .padding(.vertical, 4)
                            .tag(filename)
                            .contextMenu {
                                Button {
                                    renameCandidate = filename
                                    renameDraft = filename.replacingOccurrences(of: ".md", with: "")
                                    showRenameSheet = true
                                } label: { Label("Rename", systemImage: "pencil") }
                                Divider()
                                Button(role: .destructive) {
                                    deleteCandidate = filename
                                    showDeleteConfirm = true
                                } label: { Label("Delete", systemImage: "trash") }
                            }
                        }
                        .listStyle(.sidebar)
                        .scrollContentBackground(.hidden)
                        .background(Color(nsColor: .windowBackgroundColor))
                    }
                }
                .frame(width: 200)
            }

            CollapseHandle(isCollapsed: $fileListCollapsed, collapsesRight: false,
                           showLine: true, panelColor: .clear)

            // Right: hub (editor + entity sidebar)
            Group {
                if let file = selectedFile, let store = docStore {
                    let notePath = "\(subfolder)/\(file)"
                    HStack(spacing: 0) {
                        TraceMacNoteEditor(relativePath: notePath)
                            .frame(maxWidth: .infinity)
                        Divider()
                        MacProjectHubSidebar(notePath: notePath, store: store)
                            .frame(width: 260)
                    }
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "folder")
                            .font(.system(size: 40, weight: .thin)).foregroundStyle(.tertiary)
                        Text("Select a project or create one")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingNewNote = true } label: {
                    Label("New Project", systemImage: "plus")
                }
            }
            if let file = selectedFile {
                ToolbarItem {
                    Button(role: .destructive) {
                        deleteCandidate = file
                        showDeleteConfirm = true
                    } label: { Label("Delete", systemImage: "trash") }
                    .keyboardShortcut(.delete, modifiers: .command)
                }
            }
        }
        .confirmationDialog(
            "Delete \"\(deleteCandidate?.replacingOccurrences(of: ".md", with: "") ?? "")\"?",
            isPresented: $showDeleteConfirm, titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let f = deleteCandidate { deleteNote(f) }
            }
            Button("Cancel", role: .cancel) { }
        }
        .sheet(isPresented: $showingNewNote) { newNoteSheet }
        .sheet(isPresented: $showRenameSheet) { renameSheet }
        .task {
            await loadFiles()
            if docStore == nil {
                docStore = TraceMacDocumentStore(noteStore: noteStore)
            }
            await docStore?.reload()
        }
    }

    // MARK: - Sheets

    private var newNoteSheet: some View {
        VStack(spacing: 16) {
            Text("New Project").font(.headline)
            TextField("Project name", text: $newNoteName)
                .textFieldStyle(.roundedBorder).frame(width: 280)
                .onSubmit { createNote() }
            HStack {
                Button("Cancel") { newNoteName = ""; showingNewNote = false }
                Button("Create") { createNote() }
                    .buttonStyle(.borderedProminent)
                    .disabled(newNoteName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
    }

    private var renameSheet: some View {
        VStack(spacing: 16) {
            Text("Rename Project").font(.headline)
            TextField("Name", text: $renameDraft)
                .textFieldStyle(.roundedBorder).frame(width: 280)
                .onSubmit { renameNote() }
            HStack {
                Button("Cancel") { showRenameSheet = false; renameCandidate = nil }
                Button("Rename") { renameNote() }
                    .buttonStyle(.borderedProminent)
                    .disabled(renameDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
    }

    // MARK: - Actions

    private func loadFiles() async {
        let loaded = (try? noteStore.listFiles(in: subfolder)) ?? []
        files = loaded.sorted()
        var contents: [String: String] = [:]
        var tagSet = Set<String>()
        let regex = try? NSRegularExpression(pattern: #"(?<![&\w])#([a-zA-Z][a-zA-Z0-9_]*)"#)
        for filename in files {
            let content = (try? noteStore.readFile("\(subfolder)/\(filename)")) ?? ""
            contents[filename] = content
            guard let regex else { continue }
            let ns = content as NSString
            regex.enumerateMatches(in: content, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                if let m, let r = Range(m.range(at: 1), in: content) {
                    tagSet.insert(String(content[r]).lowercased())
                }
            }
        }
        fileContents = contents
        allTags = tagSet.sorted()
    }

    private func createNote() {
        let name = newNoteName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let filename = "\(name).md"
        let path = "\(subfolder)/\(filename)"
        let today = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        let content = """
        ---
        title: \(name)
        type: project
        created: \(today)
        people: []
        places: []
        tags: []
        linked_notes: []
        ---

        """
        try? noteStore.writeFile(path, content: content)
        if !files.contains(filename) { files.append(filename); files.sort() }
        selectedFile = filename
        newNoteName = ""
        showingNewNote = false
        Task { await docStore?.reload() }
    }

    private func renameNote() {
        guard let old = renameCandidate else { return }
        let newName = renameDraft.trimmingCharacters(in: .whitespaces)
        guard !newName.isEmpty else { return }
        let newFilename = newName + ".md"
        guard newFilename != old else { showRenameSheet = false; renameCandidate = nil; return }
        try? noteStore.moveFile(from: "\(subfolder)/\(old)", to: "\(subfolder)/\(newFilename)")
        if let idx = files.firstIndex(of: old) { files[idx] = newFilename; files.sort() }
        if selectedFile == old { selectedFile = newFilename }
        showRenameSheet = false; renameCandidate = nil
    }

    private func deleteNote(_ filename: String) {
        try? noteStore.deleteFile("\(subfolder)/\(filename)")
        files.removeAll { $0 == filename }
        if selectedFile == filename { selectedFile = nil }
        deleteCandidate = nil
    }
}

// MARK: - Place notes

struct TraceMacPlaceNoteView: View {
    @Environment(NoteStore.self)     private var noteStore
    @Environment(NotionService.self) private var notionService

    @State private var files: [String] = []
    @State private var selectedFile: String? = nil
    @State private var searchText = ""
    @State private var showingPlacePicker = false
    @State private var deleteCandidate: String? = nil
    @State private var showDeleteConfirm = false
    @State private var fileListCollapsed = false

    private var filtered: [String] {
        if searchText.isEmpty { return files }
        return files.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left: file list
            if !fileListCollapsed {
                VStack(spacing: 0) {
                    TextField("Search", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .padding(10)

                    if files.isEmpty {
                        Spacer()
                        Text("No place notes yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    } else {
                        List(filtered, id: \.self, selection: $selectedFile) { filename in
                            Text(filename.replacingOccurrences(of: ".md", with: ""))
                                .font(.system(.callout, weight: .medium))
                                .lineLimit(1)
                                .padding(.vertical, 4)
                                .tag(filename)
                                .contextMenu {
                                    Button(role: .destructive) {
                                        deleteCandidate = filename
                                        showDeleteConfirm = true
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                        }
                        .listStyle(.sidebar)
                        .scrollContentBackground(.hidden)
                        .background(Color(nsColor: .windowBackgroundColor))
                    }
                }
                .frame(width: 200)
            }

            CollapseHandle(
                isCollapsed: $fileListCollapsed,
                collapsesRight: false,
                showLine: true,
                panelColor: .clear
            )

            // Right: editor
            Group {
                if let file = selectedFile {
                    TraceMacNoteEditor(relativePath: "Notes/Places/\(file)")
                        .environment(noteStore)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "mappin")
                            .font(.system(size: 40, weight: .thin))
                            .foregroundStyle(.tertiary)
                        Text("Select a place note or create one")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingPlacePicker = true } label: {
                    Label("New Place Note", systemImage: "plus")
                }
            }
            if let file = selectedFile {
                ToolbarItem {
                    Button(role: .destructive) {
                        deleteCandidate = file
                        showDeleteConfirm = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .keyboardShortcut(.delete, modifiers: .command)
                }
            }
        }
        .confirmationDialog(
            "Delete \"\(deleteCandidate?.replacingOccurrences(of: ".md", with: "") ?? "")\"?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let f = deleteCandidate { deletePlaceNote(f) }
            }
            Button("Cancel", role: .cancel) { }
        }
        .sheet(isPresented: $showingPlacePicker) {
            placePickerSheet
        }
        .task { await loadFiles() }
    }

    private var placePickerSheet: some View {
        VStack(spacing: 0) {
            Text("Choose a Place")
                .font(.headline)
                .padding()

            Divider()

            if notionService.places.isEmpty {
                ProgressView("Loading places…")
                    .padding()
            } else {
                List(notionService.places.sorted { $0.name < $1.name }) { place in
                    Button(action: { createPlaceNote(for: place.name) }) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(place.name).foregroundStyle(.primary)
                            if !place.city.isEmpty {
                                Text(place.city).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()

            Button("Cancel") { showingPlacePicker = false }
                .padding()
        }
        .frame(width: 320, height: 420)
    }

    private func loadFiles() async {
        let loaded = (try? noteStore.listFiles(in: "Notes/Places")) ?? []
        files = loaded.sorted()
    }

    private func deletePlaceNote(_ filename: String) {
        try? noteStore.deleteFile("Notes/Places/\(filename)")
        files.removeAll { $0 == filename }
        if selectedFile == filename { selectedFile = nil }
        deleteCandidate = nil
    }

    private func createPlaceNote(for placeName: String) {
        let filename = "\(placeName).md"
        let path = "Notes/Places/\(filename)"
        if (try? noteStore.readFile(path))?.isEmpty ?? true {
            try? noteStore.writeFile(path, content: "# \(placeName)\n\n")
        }
        if !files.contains(filename) {
            files.append(filename)
            files.sort()
        }
        selectedFile = filename
        showingPlacePicker = false
    }
}

// MARK: - Horizon file classification

/// Parses a Horizons filename into a week or month kind.
/// "2026-W27.md" → .week(2026, 27)
/// "2026-07.md"  → .month(2026, 7)
/// Anything else → nil (no header shown)
private enum HorizonKind {
    case week(year: Int, week: Int)
    case month(year: Int, month: Int)

    init?(filename: String) {
        let name = filename.replacingOccurrences(of: ".md", with: "")
        // Weekly: "YYYY-Www"
        if let wRange = name.range(of: "-W") {
            let yearStr = String(name[name.startIndex ..< wRange.lowerBound])
            let weekStr = String(name[wRange.upperBound...])
            if let y = Int(yearStr), let w = Int(weekStr), w >= 1, w <= 53 {
                self = .week(year: y, week: w)
                return
            }
        }
        // Monthly: exactly "YYYY-MM"
        let parts = name.split(separator: "-").map(String.init)
        if parts.count == 2, parts[0].count == 4, parts[1].count == 2,
           let y = Int(parts[0]), let m = Int(parts[1]), m >= 1, m <= 12 {
            self = .month(year: y, month: m)
            return
        }
        return nil
    }
}

// MARK: - Horizon calendar header

private struct HorizonCalendarHeader: View {

    let kind: HorizonKind

    private var isoCalendar: Calendar {
        var cal = Calendar(identifier: .iso8601)
        cal.locale = Locale.current
        return cal
    }

    var body: some View {
        switch kind {
        case .week(let year, let week):   weekView(year: year, week: week)
        case .month(let year, let month): monthView(year: year, month: month)
        }
    }

    // MARK: Weekly header

    private func weekDates(year: Int, week: Int) -> [Date] {
        var comps = DateComponents()
        comps.yearForWeekOfYear = year
        comps.weekOfYear = week
        comps.weekday = 2   // Monday = first day in ISO week
        guard let monday = isoCalendar.date(from: comps) else { return [] }
        return (0..<7).compactMap { isoCalendar.date(byAdding: .day, value: $0, to: monday) }
    }

    private func weekRangeLabel(_ dates: [Date]) -> String {
        guard let first = dates.first, let last = dates.last else { return "" }
        let mFmt = DateFormatter(); mFmt.dateFormat = "MMMM"
        let dFmt = DateFormatter(); dFmt.dateFormat = "d"
        let yFmt = DateFormatter(); yFmt.dateFormat = "yyyy"
        let firstMonth = isoCalendar.component(.month, from: first)
        let lastMonth  = isoCalendar.component(.month, from: last)
        let year = yFmt.string(from: last)
        if firstMonth == lastMonth {
            return "\(mFmt.string(from: first)) \(dFmt.string(from: first))–\(dFmt.string(from: last)), \(year)"
        } else {
            return "\(mFmt.string(from: first)) \(dFmt.string(from: first)) – \(mFmt.string(from: last)) \(dFmt.string(from: last)), \(year)"
        }
    }

    @ViewBuilder
    private func weekView(year: Int, week: Int) -> some View {
        let dates    = weekDates(year: year, week: week)
        let abbrevs  = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

        VStack(alignment: .leading, spacing: 8) {
            Text(weekRangeLabel(dates))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            HStack(spacing: 0) {
                ForEach(Array(zip(abbrevs, dates)), id: \.0) { abbrev, date in
                    let dayNum    = isoCalendar.component(.day, from: date)
                    let isWeekend = abbrev == "Sat" || abbrev == "Sun"

                    VStack(spacing: 5) {
                        Text(abbrev)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(isWeekend ? .secondary : .primary)

                        Text("\(dayNum)")
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(isWeekend ? .secondary : .primary)
                            .frame(width: 28, height: 28)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    // MARK: Monthly header

    private func monthDates(year: Int, month: Int) -> [Date?] {
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = 1
        guard let firstDay = isoCalendar.date(from: comps) else { return [] }
        guard let range = isoCalendar.range(of: .day, in: .month, for: firstDay) else { return [] }
        let weekday = isoCalendar.component(.weekday, from: firstDay)
        let offset  = (weekday + 5) % 7   // Mon=0 … Sun=6
        var result: [Date?] = Array(repeating: nil, count: offset)
        for d in range {
            var dc = comps; dc.day = d
            result.append(isoCalendar.date(from: dc))
        }
        while result.count % 7 != 0 { result.append(nil) }
        return result
    }

    private func monthHeaderLabel(year: Int, month: Int) -> String {
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = 1
        guard let date = isoCalendar.date(from: comps) else { return "" }
        let fmt = DateFormatter(); fmt.dateFormat = "MMMM yyyy"
        return fmt.string(from: date)
    }

    @ViewBuilder
    private func monthView(year: Int, month: Int) -> some View {
        let dates   = monthDates(year: year, month: month)
        let rows    = stride(from: 0, to: dates.count, by: 7).map {
            Array(dates[$0 ..< min($0 + 7, dates.count)])
        }
        let headers = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        let label   = monthHeaderLabel(year: year, month: month)

        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)

            // Column headers
            HStack(spacing: 0) {
                ForEach(Array(headers.enumerated()), id: \.offset) { idx, h in
                    Text(h)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(idx >= 5 ? .secondary : .primary)
                        .frame(maxWidth: .infinity)
                }
            }

            // Date rows
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 0) {
                    ForEach(Array(row.enumerated()), id: \.offset) { colIdx, date in
                        if let date = date {
                            let dayNum    = isoCalendar.component(.day, from: date)
                            let isWeekend = colIdx >= 5
                            Text("\(dayNum)")
                                .font(.system(size: 12, weight: .regular))
                                .foregroundStyle(isWeekend ? .secondary : .primary)
                                .frame(maxWidth: .infinity)
                                .frame(height: 26)
                        } else {
                            Color.clear.frame(maxWidth: .infinity).frame(height: 26)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - AppKit text editor (no scrollbar)

// MARK: - Editor command enum

enum MacEditorCommand: Equatable {
    case bold, italic, strike, highlight
    case heading, bullet, checkbox
    case indent, outdent
    case link, date
    case undo, redo
    case timestamp
    case requestMove
    case applyWikiSuggestion(String)
}

// MARK: - NSTextView subclass: checkbox click detection

/// Intercepts mouseDown to toggle ☐/☑ when the user clicks the checkbox glyph.
/// Also rejects file-URL drags so they propagate up to the Documents drop zone
/// instead of being pasted as text paths.
private final class MarkdownNSTextView: NSTextView {

    // Refuse file-URL drags — let the Documents left-column .onDrop handle them.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let fileTypes: [NSPasteboard.PasteboardType] = [
            .fileURL,
            NSPasteboard.PasteboardType("public.file-url"),
            NSPasteboard.PasteboardType(rawValue: "NSFilenamesPboardType")
        ]
        if fileTypes.contains(where: { sender.draggingPasteboard.types?.contains($0) == true }) {
            return []
        }
        return super.draggingEntered(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let fileTypes: [NSPasteboard.PasteboardType] = [
            .fileURL,
            NSPasteboard.PasteboardType("public.file-url"),
            NSPasteboard.PasteboardType(rawValue: "NSFilenamesPboardType")
        ]
        if fileTypes.contains(where: { sender.draggingPasteboard.types?.contains($0) == true }) {
            return false
        }
        return super.prepareForDragOperation(sender)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let adj = NSPoint(x: point.x - textContainerInset.width,
                          y: point.y - textContainerInset.height)
        if let lm = layoutManager, let tc = textContainer {
            let glyphIdx = lm.glyphIndex(for: adj, in: tc,
                                          fractionOfDistanceThroughGlyph: nil)
            let charIdx  = lm.characterIndexForGlyph(at: glyphIdx)
            if charIdx < (textStorage?.length ?? 0) {
                // Click on [[wikilink]] → navigate to record.
                // Single-click navigates and places cursor; Cmd+click navigates without moving cursor.
                if let target = textStorage?.attribute(.macWikiTarget, at: charIdx,
                                                       effectiveRange: nil) as? String {
                    NotificationCenter.default.post(name: .openWikilink, object: nil,
                                                    userInfo: ["name": target])
                    if event.modifierFlags.contains(.command) { return }
                    // Fall through to super so cursor is placed at the click position
                }
                // Click on checkbox → toggle
                if textStorage?.attribute(.macCheckboxState, at: charIdx,
                                          effectiveRange: nil) != nil {
                    let ns = (textStorage?.string ?? "") as NSString
                    let lineRange = ns.lineRange(for: NSRange(location: charIdx, length: 0))
                    let line = ns.substring(with: lineRange)
                    if line.hasPrefix("☐ ") {
                        textStorage?.replaceCharacters(in: lineRange,
                                                       with: "☑ " + String(line.dropFirst(2)))
                    } else if line.hasPrefix("☑ ") {
                        textStorage?.replaceCharacters(in: lineRange,
                                                       with: "☐ " + String(line.dropFirst(2)))
                    }
                    didChangeText()
                    return
                }
            }
        }
        super.mouseDown(with: event)
    }
}

// MARK: - MacEditorActions (direct command channel — bypasses SwiftUI binding timing)

/// Shared by TraceMacNoteEditor and MacTextEditor. Toolbar buttons call execute(_:) directly;
/// MacTextEditor wires it to the coordinator in makeNSView. No binding timing issues.
final class MacEditorActions {
    var execute: (MacEditorCommand) -> Void = { _ in }
    /// Called by .requestMove with (textToMove, remainingContent).
    var onMoveRequest: ((String, String) -> Void)?
}

// MARK: - MacTextEditor (NSViewRepresentable)

/// NSTextView backed by MacMarkdownTextStorage with live markdown rendering.
private struct MacTextEditor: NSViewRepresentable {
    @Binding var text: String
    let actions: MacEditorActions
    /// Called when the cursor enters/exits a [[...]] span. Receives the partial name or nil.
    var onWikilinkQuery: ((String?) -> Void)? = nil
    /// Called when the user presses Return while a wikilink suggestion is active.
    var onWikilinkAccept: (() -> Void)? = nil
    /// Called by .requestMove with (textToMove, remainingContent).
    var onMoveRequest: ((String, String) -> Void)? = nil

    // MARK: makeNSView

    func makeNSView(context: Context) -> NSScrollView {
        let storage   = MacMarkdownTextStorage()
        let manager   = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)

        let tv = MarkdownNSTextView(frame: .zero, textContainer: container)
        let paraStyle = MacMarkdownTextStorage.baseParagraphStyle

        tv.isEditable              = true
        tv.isRichText              = false
        tv.allowsUndo              = true
        tv.backgroundColor         = NSColor.clear
        tv.isVerticallyResizable   = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask        = [.width]
        tv.minSize                 = NSSize(width: 0, height: 0)
        tv.maxSize                 = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                            height: CGFloat.greatestFiniteMagnitude)
        tv.textContainerInset      = NSSize(width: 40, height: 24)
        tv.defaultParagraphStyle = paraStyle as? NSMutableParagraphStyle
        tv.typingAttributes = [
            NSAttributedString.Key.font:            MacMarkdownTextStorage.bodyFont,
            NSAttributedString.Key.foregroundColor: MacMarkdownTextStorage.textColor,
            NSAttributedString.Key.paragraphStyle:  paraStyle
        ] as [NSAttributedString.Key: Any]
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled  = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.delegate = context.coordinator
        context.coordinator.textView = tv

        // Wire toolbar actions directly to coordinator — no SwiftUI binding round-trip.
        let coord = context.coordinator
        actions.execute = { [weak coord] cmd in
            guard let c = coord, let tv = c.textView else { return }
            c.execute(cmd, in: tv)
        }
        coord.onWikilinkQuery  = onWikilinkQuery
        coord.onWikilinkAccept = onWikilinkAccept
        coord.onMoveRequest    = onMoveRequest
        actions.onMoveRequest  = onMoveRequest

        let scrollView = NSScrollView()
        scrollView.documentView          = tv
        scrollView.hasVerticalScroller   = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers    = false
        scrollView.backgroundColor       = NSColor.clear
        scrollView.drawsBackground       = false

        if !text.isEmpty {
            storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
            DispatchQueue.main.async { [weak coord] in
                guard let c = coord, let tv = c.textView else { return }
                c.refreshHorizontalRules(in: tv)
            }
        }

        return scrollView
    }

    // MARK: updateNSView

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        // Re-wire on every update so the closure always reaches the live coordinator.
        let coord = context.coordinator
        actions.execute = { [weak coord] cmd in
            guard let c = coord, let tv = c.textView else { return }
            c.execute(cmd, in: tv)
        }
        coord.onWikilinkQuery  = onWikilinkQuery
        coord.onWikilinkAccept = onWikilinkAccept
        coord.onMoveRequest    = onMoveRequest
        actions.onMoveRequest  = onMoveRequest
        guard let tv = scrollView.documentView as? MarkdownNSTextView else { return }
        guard tv.string != text else { return }
        let savedRange = tv.selectedRange()
        tv.textStorage?.replaceCharacters(
            in: NSRange(location: 0, length: tv.textStorage?.length ?? 0),
            with: text)
        let newLen = tv.textStorage?.length ?? 0
        tv.setSelectedRange(NSRange(location: min(savedRange.location, newLen), length: 0))
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    // MARK: Sizing

    /// Fully flexible: adopt whatever SwiftUI proposes; never report an intrinsic
    /// minimum. Without this, SwiftUI derives sizing from the scroll view's fitting
    /// size, which reads as a wide minimum once the text view has laid out wide and
    /// refuses to compress — pushing sibling columns (e.g. the calendar) off-window.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> NSSize? {
        guard proposal.width != nil || proposal.height != nil else { return nil }
        return NSSize(width: proposal.width ?? nsView.frame.width,
                      height: proposal.height ?? nsView.frame.height)
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        weak var textView: MarkdownNSTextView?
        /// Last known selection — stored here so commands can use it even after focus leaves the text view.
        var lastSelection = NSRange(location: 0, length: 0)
        /// Called when cursor enters/exits a [[...]] span.
        var onWikilinkQuery: ((String?) -> Void)?
        /// Called when user presses Return while a suggestion is active.
        var onWikilinkAccept: (() -> Void)?
        /// Called by .requestMove with (textToMove, remainingContent).
        var onMoveRequest: ((String, String) -> Void)?
        /// Character position of the opening [[ in the active wikilink session.
        private var wikilinkOpenLoc: Int? = nil
        /// Marker subclass for thin NSView separators overlaid on `---` lines.
        private final class HROverlay: NSView {}

        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            // Reset typing attributes so new text never inherits markdown styles (bold, color, etc.)
            tv.typingAttributes = [
                NSAttributedString.Key.font:            MacMarkdownTextStorage.bodyFont,
                NSAttributedString.Key.foregroundColor: MacMarkdownTextStorage.textColor,
                NSAttributedString.Key.paragraphStyle:  MacMarkdownTextStorage.baseParagraphStyle
            ] as [NSAttributedString.Key: Any]
            if text.wrappedValue != tv.string { text.wrappedValue = tv.string }
            DispatchQueue.main.async { [weak self, weak tv] in
                guard let self, let tv else { return }
                self.refreshHorizontalRules(in: tv)
                self.checkForWikilink(in: tv)
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            // Only snapshot the selection while the text view actually owns focus.
            // When the user clicks a toolbar button macOS collapses the selection
            // *before* the button action fires — if we saved that we'd lose the range.
            if tv.window?.firstResponder === tv {
                lastSelection = tv.selectedRange()
            }
            checkForWikilink(in: tv)
        }

        // MARK: - Horizontal rule overlay

        func refreshHorizontalRules(in tv: NSTextView) {
            tv.subviews
                .compactMap { $0 as? HROverlay }
                .forEach { $0.removeFromSuperview() }

            guard tv.string.contains("---"),
                  let lm = tv.layoutManager,
                  let tc = tv.textContainer else { return }
            lm.ensureLayout(for: tc)

            let ns = tv.string as NSString
            var pos = 0
            while pos < ns.length {
                let lineRange = ns.lineRange(for: NSRange(location: pos, length: 0))
                guard lineRange.length > 0 else { break }
                let line = ns.substring(with: lineRange)
                if line.trimmingCharacters(in: .whitespacesAndNewlines) == "---" {
                    let glyphRange = lm.glyphRange(forCharacterRange: lineRange,
                                                   actualCharacterRange: nil)
                    let lineRect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
                    let insetW = tv.textContainerInset.width
                    let insetH = tv.textContainerInset.height
                    let midY   = lineRect.origin.y + lineRect.height / 2 + insetH
                    let xLeft  = insetW + 16
                    let xRight = tv.bounds.width - insetW - 16

                    let rule = HROverlay(frame: NSRect(x: xLeft, y: midY - 0.5,
                                                       width: max(0, xRight - xLeft), height: 1.0))
                    rule.wantsLayer = true
                    rule.layer?.backgroundColor = NSColor(white: 0.45, alpha: 1).cgColor
                    tv.addSubview(rule)
                }
                pos = lineRange.location + lineRange.length
            }
        }

        // MARK: - Wikilink autocomplete detection

        private func checkForWikilink(in tv: NSTextView) {
            let cursorLoc = tv.selectedRange().location
            let ns = tv.string as NSString

            // Only check within the current line
            let lineRange = ns.lineRange(for: NSRange(location: cursorLoc, length: 0))
            let lineStart = lineRange.location
            guard cursorLoc > lineStart + 1 else {
                endWikilinkSession()
                return
            }

            // Scan backward from cursor on this line for [[
            let beforeCursor = ns.substring(with: NSRange(location: lineStart,
                                                          length: cursorLoc - lineStart))
            let bns = beforeCursor as NSString

            var scanIdx = bns.length - 2
            var found: (openLoc: Int, partial: String)? = nil
            while scanIdx >= 0 {
                if bns.character(at: scanIdx)     == 91 &&   // '['
                   bns.character(at: scanIdx + 1) == 91 {   // '['
                    let partial = bns.substring(from: scanIdx + 2)
                    if !partial.contains("]]") && !partial.contains("\n") {
                        found = (lineStart + scanIdx, partial)
                    }
                    break
                }
                scanIdx -= 1
            }

            if let ctx = found {
                wikilinkOpenLoc = ctx.openLoc
                onWikilinkQuery?(ctx.partial)
            } else {
                endWikilinkSession()
            }
        }

        private func endWikilinkSession() {
            guard wikilinkOpenLoc != nil else { return }
            wikilinkOpenLoc = nil
            onWikilinkQuery?(nil)
        }

        private func applyWikiSuggestion(_ name: String, in tv: NSTextView) {
            let cursorLoc = tv.selectedRange().location
            guard let openLoc = wikilinkOpenLoc, openLoc <= cursorLoc else { return }
            let replaceRange = NSRange(location: openLoc, length: cursorLoc - openLoc)
            let replacement  = "[[\(name)]]"
            tv.textStorage?.replaceCharacters(in: replaceRange, with: replacement)
            tv.didChangeText()
            let newLoc = openLoc + (replacement as NSString).length
            tv.setSelectedRange(NSRange(location: newLoc, length: 0))
            text.wrappedValue = tv.string
            wikilinkOpenLoc = nil
            onWikilinkQuery?(nil)
        }

        // MARK: Smart keyboard — auto-list continuation and dash-to-bullet conversion

        func textView(_ tv: NSTextView,
                      shouldChangeTextIn affectedCharRange: NSRange,
                      replacementString replacement: String?) -> Bool {
            guard let replacement else { return true }
            let ns = tv.string as NSString
            let lineRange = ns.lineRange(for: NSRange(location: affectedCharRange.location, length: 0))
            let line = ns.substring(with: lineRange)

            // ── Typing third "-" to complete "---" → create HR and move cursor below ──
            let lineWithoutNewline0 = line.hasSuffix("\n") ? String(line.dropLast()) : line
            if replacement == "-" && lineWithoutNewline0 == "--" {
                tv.textStorage?.replaceCharacters(in: affectedCharRange, with: "-\n")
                tv.didChangeText()
                tv.setSelectedRange(NSRange(location: affectedCharRange.location + 2, length: 0))
                text.wrappedValue = tv.string
                return false
            }

            // ── Tab: indent line ──────────────────────────────────────────────────
            if replacement == "\t" {
                tv.textStorage?.replaceCharacters(in: lineRange, with: "  " + line)
                tv.didChangeText()
                tv.setSelectedRange(NSRange(location: affectedCharRange.location + 2, length: 0))
                return false
            }

            // ── Space after lone "-" at line start → bullet ───────────────────────
            // Checks the character immediately before the cursor is "-" and everything
            // before it on the line is spaces. Handles both mid-doc and last-line cases.
            if replacement == " " && affectedCharRange.location > 0 {
                let dashPos = affectedCharRange.location - 1
                let charBefore = ns.character(at: dashPos)
                if charBefore == UInt16(UnicodeScalar("-").value) {
                    let lineStart = lineRange.location
                    if dashPos >= lineStart {
                        let prefix = ns.substring(with: NSRange(location: lineStart,
                                                                length: dashPos - lineStart))
                        if prefix.allSatisfy({ $0 == " " }) {
                            tv.textStorage?.replaceCharacters(
                                in: NSRange(location: dashPos, length: 1), with: "\u{2022}")
                            tv.didChangeText()
                            return true   // let the space insert normally
                        }
                    }
                }
            }

            // ── Return while wikilink session active → accept top suggestion ──────
            if replacement == "\n" && wikilinkOpenLoc != nil {
                onWikilinkAccept?()
                return false
            }

            // ── Return key: continue or exit list ─────────────────────────────────
            guard replacement == "\n" else { return true }

            let lineWithoutNewline = line.hasSuffix("\n") ? String(line.dropLast()) : line

            // Bullet continuation
            let bulletPrefix = "\u{2022} "
            if let bulletRange = lineWithoutNewline.range(of: bulletPrefix) {
                let indent = String(lineWithoutNewline[lineWithoutNewline.startIndex..<bulletRange.lowerBound])
                let afterBullet = lineWithoutNewline[bulletRange.upperBound...]
                if afterBullet.trimmingCharacters(in: .whitespaces).isEmpty {
                    // Empty bullet — exit list
                    tv.textStorage?.replaceCharacters(in: lineRange, with: "\n")
                    tv.didChangeText()
                    tv.setSelectedRange(NSRange(location: lineRange.location + 1, length: 0))
                } else {
                    // Continue bullet
                    let insert = "\n" + indent + bulletPrefix
                    tv.textStorage?.replaceCharacters(in: affectedCharRange, with: insert)
                    tv.didChangeText()
                    tv.setSelectedRange(NSRange(location: affectedCharRange.location + (insert as NSString).length,
                                                length: 0))
                }
                text.wrappedValue = tv.string
                return false
            }

            // Dash list continuation ("- item")
            if let dashRange = lineWithoutNewline.range(of: "- ") {
                let prefixSlice = lineWithoutNewline[lineWithoutNewline.startIndex..<dashRange.lowerBound]
                guard prefixSlice.allSatisfy({ $0 == " " }) else { return true }
                let indent = String(prefixSlice)
                let afterDash = lineWithoutNewline[dashRange.upperBound...]
                if afterDash.trimmingCharacters(in: .whitespaces).isEmpty {
                    tv.textStorage?.replaceCharacters(in: lineRange, with: "\n")
                    tv.didChangeText()
                    tv.setSelectedRange(NSRange(location: lineRange.location + 1, length: 0))
                } else {
                    let insert = "\n" + indent + "- "
                    tv.textStorage?.replaceCharacters(in: affectedCharRange, with: insert)
                    tv.didChangeText()
                    tv.setSelectedRange(NSRange(location: affectedCharRange.location + (insert as NSString).length,
                                                length: 0))
                }
                text.wrappedValue = tv.string
                return false
            }

            // Checkbox continuation
            let checkPrefixes = ["☐ ", "☑ "]
            for prefix in checkPrefixes {
                if lineWithoutNewline.hasPrefix(prefix) {
                    let afterCheck = lineWithoutNewline.dropFirst(prefix.count)
                    if afterCheck.trimmingCharacters(in: .whitespaces).isEmpty {
                        tv.textStorage?.replaceCharacters(in: lineRange, with: "\n")
                        tv.didChangeText()
                        tv.setSelectedRange(NSRange(location: lineRange.location + 1, length: 0))
                    } else {
                        let insert = "\n☐ "
                        tv.textStorage?.replaceCharacters(in: affectedCharRange, with: insert)
                        tv.didChangeText()
                        tv.setSelectedRange(NSRange(location: affectedCharRange.location + (insert as NSString).length,
                                                    length: 0))
                    }
                    text.wrappedValue = tv.string
                    return false
                }
            }

            return true
        }

        // MARK: Command execution

        func execute(_ command: MacEditorCommand, in tv: NSTextView) {
            switch command {
            case .bold:      wrapSelection("**", in: tv)
            case .italic:    wrapSelection("*", in: tv)
            case .strike:    wrapSelection("~~", in: tv)
            case .highlight: wrapSelection("==", in: tv)
            case .link:      wrapSelection("[[", closing: "]]", in: tv)
            case .heading:   toggleLinePrefix("## ", in: tv)
            case .bullet:    toggleBullet(in: tv)
            case .checkbox:  toggleCheckbox(in: tv)
            case .indent:    indentLine(in: tv)
            case .outdent:   outdentLine(in: tv)
            case .date:      insertDate(in: tv)
            case .timestamp: insertTimestamp(in: tv)
            case .requestMove: requestMove(in: tv)
            case .undo:      tv.undoManager?.undo()
            case .redo:      tv.undoManager?.redo()
            case .applyWikiSuggestion(let name): applyWikiSuggestion(name, in: tv)
            }
        }

        private func wrapSelection(_ marker: String, closing: String? = nil, in tv: NSTextView) {
            let close   = closing ?? marker
            let range   = lastSelection
            guard let storage = tv.textStorage else { return }
            if range.length == 0 {
                let pair = marker + close
                storage.replaceCharacters(in: range, with: pair)
                tv.didChangeText()
                let newLoc = range.location + (marker as NSString).length
                tv.setSelectedRange(NSRange(location: newLoc, length: 0))
            } else if let swiftRange = Range(range, in: storage.string) {
                let selected = String(storage.string[swiftRange])
                storage.replaceCharacters(in: range, with: marker + selected + close)
                tv.didChangeText()
            }
            text.wrappedValue = storage.string
        }

        private func toggleLinePrefix(_ prefix: String, in tv: NSTextView) {
            guard let storage = tv.textStorage else { return }
            let ns        = storage.string as NSString
            let lineRange = ns.lineRange(for: NSRange(location: lastSelection.location, length: 0))
            let line      = ns.substring(with: lineRange)
            if line.hasPrefix(prefix) {
                storage.replaceCharacters(in: lineRange, with: String(line.dropFirst(prefix.count)))
                tv.didChangeText()
                let newLoc = max(lineRange.location, lastSelection.location - (prefix as NSString).length)
                tv.setSelectedRange(NSRange(location: newLoc, length: 0))
            } else {
                storage.replaceCharacters(in: lineRange, with: prefix + line)
                tv.didChangeText()
                tv.setSelectedRange(NSRange(location: lastSelection.location + (prefix as NSString).length,
                                            length: 0))
            }
            text.wrappedValue = storage.string
        }

        private func toggleBullet(in tv: NSTextView) {
            guard let storage = tv.textStorage else { return }
            let ns        = storage.string as NSString
            let lineRange = ns.lineRange(for: NSRange(location: lastSelection.location, length: 0))
            let line      = ns.substring(with: lineRange)
            let bullet    = "\u{2022} "
            if line.hasPrefix(bullet) {
                storage.replaceCharacters(in: lineRange, with: String(line.dropFirst(2)))
                tv.didChangeText()
                let newLoc = max(lineRange.location, lastSelection.location - 2)
                tv.setSelectedRange(NSRange(location: newLoc, length: 0))
            } else {
                storage.replaceCharacters(in: lineRange, with: bullet + line)
                tv.didChangeText()
                tv.setSelectedRange(NSRange(location: lastSelection.location + 2, length: 0))
            }
            text.wrappedValue = storage.string
        }

        private func toggleCheckbox(in tv: NSTextView) {
            guard let storage = tv.textStorage else { return }
            let ns        = storage.string as NSString
            let lineRange = ns.lineRange(for: NSRange(location: lastSelection.location, length: 0))
            let line      = ns.substring(with: lineRange)
            if line.hasPrefix("☑ ") {
                storage.replaceCharacters(in: lineRange, with: "☐ " + String(line.dropFirst(2)))
                tv.didChangeText()
                tv.setSelectedRange(NSRange(location: lastSelection.location, length: 0))
            } else if line.hasPrefix("☐ ") {
                storage.replaceCharacters(in: lineRange, with: String(line.dropFirst(2)))
                tv.didChangeText()
                let newLoc = max(lineRange.location, lastSelection.location - 2)
                tv.setSelectedRange(NSRange(location: newLoc, length: 0))
            } else {
                storage.replaceCharacters(in: lineRange, with: "☐ " + line)
                tv.didChangeText()
                tv.setSelectedRange(NSRange(location: lastSelection.location + 2, length: 0))
            }
            text.wrappedValue = storage.string
        }

        private func indentLine(in tv: NSTextView) {
            guard let storage = tv.textStorage else { return }
            let ns        = storage.string as NSString
            let lineRange = ns.lineRange(for: NSRange(location: lastSelection.location, length: 0))
            let line      = ns.substring(with: lineRange)
            storage.replaceCharacters(in: lineRange, with: "  " + line)
            tv.didChangeText()
            tv.setSelectedRange(NSRange(location: lastSelection.location + 2, length: 0))
            text.wrappedValue = storage.string
        }

        private func outdentLine(in tv: NSTextView) {
            guard let storage = tv.textStorage else { return }
            let ns        = storage.string as NSString
            let lineRange = ns.lineRange(for: NSRange(location: lastSelection.location, length: 0))
            let line      = ns.substring(with: lineRange)
            let toRemove  = line.hasPrefix("  ") ? 2 : (line.hasPrefix(" ") ? 1 : 0)
            guard toRemove > 0 else { return }
            storage.replaceCharacters(in: lineRange, with: String(line.dropFirst(toRemove)))
            tv.didChangeText()
            let newLoc = max(lineRange.location, lastSelection.location - toRemove)
            tv.setSelectedRange(NSRange(location: newLoc, length: 0))
            text.wrappedValue = storage.string
        }

        private func insertDate(in tv: NSTextView) {
            guard let storage = tv.textStorage else { return }
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.dateFormat = "MMMM d, yyyy"
            let str   = fmt.string(from: Date()) + " "
            let range = lastSelection
            storage.replaceCharacters(in: range, with: str)
            tv.didChangeText()
            tv.setSelectedRange(NSRange(location: range.location + (str as NSString).length, length: 0))
            text.wrappedValue = storage.string
        }

        private func insertTimestamp(in tv: NSTextView) {
            guard let storage = tv.textStorage else { return }
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.dateFormat = "h:mm a"
            let timeStr = fmt.string(from: Date())
            let insert  = "\n\n**\(timeStr)**\n\n"
            // Insert at end of document
            let endLoc = storage.length
            storage.replaceCharacters(in: NSRange(location: endLoc, length: 0), with: insert)
            tv.didChangeText()
            let newLoc = endLoc + (insert as NSString).length
            tv.setSelectedRange(NSRange(location: newLoc, length: 0))
            tv.scrollRangeToVisible(NSRange(location: newLoc, length: 0))
            text.wrappedValue = storage.string
        }

        private func requestMove(in tv: NSTextView) {
            let sel = lastSelection
            let fullText = tv.string
            if sel.length > 0, let r = Range(sel, in: fullText) {
                let selected  = String(fullText[r])
                let remaining = fullText.replacingCharacters(in: r, with: "")
                onMoveRequest?(selected, remaining)
            } else {
                onMoveRequest?(fullText, "")
            }
        }
    }
}

// MARK: - Shared markdown editor

struct TraceMacNoteEditor: View {
    let relativePath: String
    var showMoveButton: Bool = false
    var moveSourceDate: Date? = nil

    @Environment(NoteStore.self)     private var noteStore
    @Environment(NotionService.self) private var notionService

    @State private var content        = ""
    @State private var saveTask: Task<Void, Never>? = nil
    @State private var lastSaved: Date? = nil
    // @State keeps the same MacEditorActions instance across re-renders; makeNSView wires it once.
    @State private var editorActions  = MacEditorActions()
    // Wikilink autocomplete state
    @State private var wikiQuery:       String? = nil
    @State private var wikiSuggestions: [String] = []
    // Move sheet state
    @State private var showMoveSheet   = false
    @State private var moveContent     = ""
    @State private var postMoveContent = ""

    var body: some View {
        VStack(spacing: 0) {
            MacTextEditor(text: $content, actions: editorActions,
                          onWikilinkQuery: { query in
                              wikiQuery = query
                              // Read directly from NotionService at query time — avoids the
                              // load-once race where people/places aren't yet fetched.
                              if let q = query, !q.isEmpty {
                                  let people = notionService.people
                                      .filter { !$0.isArchived }
                                      .map(\.name)
                                  let places = notionService.places.map(\.name)
                                  wikiSuggestions = Array((people + places)
                                      .filter { $0.localizedCaseInsensitiveContains(q) }
                                      .sorted()
                                      .prefix(8))
                              } else {
                                  wikiSuggestions = []
                              }
                          },
                          onWikilinkAccept: {
                              if let first = wikiSuggestions.first {
                                  editorActions.execute(.applyWikiSuggestion(first))
                              }
                          },
                          onMoveRequest: showMoveButton ? { textToMove, remaining in
                              moveContent     = textToMove
                              postMoveContent = remaining
                              showMoveSheet   = true
                          } : nil)
                .onChange(of: content) { _, newValue in
                    scheduleSave(content: newValue)
                }

            // Wikilink suggestion pills — shown only when cursor is inside [[...]]
            if !wikiSuggestions.isEmpty {
                Divider()
                wikiSuggestionBar
            }

            // Formatting toolbar
            Divider()
            formattingToolbar

            // Footer
            Divider()
            HStack {
                let wordCount = content.split(separator: " ").count
                Text("\(wordCount) words")
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                if let saved = lastSaved {
                    Text("Saved \(saved.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        .task(id: relativePath) { await loadContent() }
        .onReceive(NotificationCenter.default.publisher(for: .noteStoreCalendarDidChange)) { note in
            guard saveTask == nil else { return }
            guard let changedPath = note.object as? String,
                  changedPath == relativePath else { return }
            Task { await loadContent() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .noteStorePlaceNoteDidChange)) { note in
            guard saveTask == nil else { return }
            if let placeName = note.object as? String,
               relativePath == "Notes/Places/\(placeName).md" {
                Task { await loadContent() }
            }
        }
        .toolbar {
            ToolbarItem {
                Button("Save") { saveNow() }
                    .keyboardShortcut("s", modifiers: .command)
            }
            if showMoveButton {
                ToolbarItem {
                    Button {
                        editorActions.execute(.timestamp)
                    } label: {
                        Label("Timestamp", systemImage: "clock")
                    }
                    .help("Insert timestamp (HH:MM AM)")
                }
                ToolbarItem {
                    Button {
                        editorActions.execute(.requestMove)
                    } label: {
                        Label("Move", systemImage: "arrow.up.right.square")
                    }
                    .help("Move selection (or whole note) to another destination")
                }
            }
        }
        .sheet(isPresented: $showMoveSheet) {
            if let date = moveSourceDate ?? parsedDate(from: relativePath) {
                MacDailyMoveSheet(
                    sourceDate: date,
                    sourceContent: moveContent,
                    onMoved: {
                        content = postMoveContent
                        scheduleSave(content: postMoveContent)
                        saveNow()
                    }
                )
                .environment(noteStore)
                .environment(notionService)
            }
        }
    }

    private func parsedDate(from path: String) -> Date? {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        let base = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        return fmt.date(from: base)
    }

    // MARK: - Wiki suggestion bar

    private var wikiSuggestionBar: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(spacing: 8) {
                ForEach(wikiSuggestions, id: \.self) { name in
                    Button {
                        editorActions.execute(.applyWikiSuggestion(name))
                    } label: {
                        Text(name)
                            .font(.system(size: 11.5, weight: .medium))
                            .lineLimit(1)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.13))
                            .foregroundStyle(Color.accentColor)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 28)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Formatting toolbar

    private var formattingToolbar: some View {
        // Horizontal ScrollView (not a plain HStack) so this row's fixed content
        // (14 buttons + dividers, ~450pt minimum) never forces a minimum width on
        // the parent VStack/editor column — same pattern as wikiSuggestionBar above.
        // A plain HStack here was B9's second constraint: it survived the
        // MacTextEditor sizeThatFits fix because a VStack won't compress below a
        // child's intrinsic minimum width.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                fmtButton("bold",            .bold,      "Bold (**)")
                    .keyboardShortcut("b", modifiers: .command)
                fmtButton("italic",          .italic,    "Italic (*)")
                    .keyboardShortcut("i", modifiers: .command)
                fmtButton("strikethrough",   .strike,    "Strikethrough (~~)")
                fmtButton("highlighter",     .highlight, "Highlight (==)")

                toolbarDivider()

                fmtButton("number",          .heading,   "Heading (##)")
                fmtButton("list.bullet",     .bullet,    "Bullet (•)")
                fmtButton("checkmark.square",.checkbox,  "Checkbox (☐)")

                toolbarDivider()

                fmtButton("decrease.indent", .outdent,   "Outdent")
                fmtButton("increase.indent", .indent,    "Indent")

                toolbarDivider()

                fmtButton("link",            .link,      "Wikilink [[]]")
                fmtButton("calendar",        .date,      "Insert date")

                toolbarDivider()

                fmtButton("arrow.uturn.backward", .undo, "Undo")
                    .keyboardShortcut("z", modifiers: .command)
                fmtButton("arrow.uturn.forward",  .redo, "Redo")
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            .padding(.horizontal, 10)
        }
        .frame(height: 32)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func fmtButton(_ icon: String, _ command: MacEditorCommand, _ tip: String) -> some View {
        Button { editorActions.execute(command) } label: {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .regular))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(tip)
    }

    private func toolbarDivider() -> some View {
        Divider()
            .frame(height: 16)
            .padding(.horizontal, 4)
    }

    // MARK: - Helpers

    private func loadContent() async {
        content = (try? noteStore.readFile(relativePath)) ?? ""
    }

    private func scheduleSave(content: String) {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            saveNow()
            saveTask = nil
        }
    }

    private func saveNow() {
        try? noteStore.writeFile(relativePath, content: content)
        lastSaved = Date()
    }
}

// MARK: - MacTagChipRow

/// Horizontally scrolling `#tag` filter chips for note list views.
/// Shows only when `tags` is non-empty. Selected chips AND-filter the list.
struct MacTagChipRow: View {
    let tags: [String]
    @Binding var selected: Set<String>

    var body: some View {
        if !tags.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(tags, id: \.self) { tag in
                        let on = selected.contains(tag)
                        Button {
                            if on { selected.remove(tag) }
                            else  { selected.insert(tag) }
                        } label: {
                            Text("#\(tag)")
                                .font(.system(size: 10, weight: on ? .semibold : .regular))
                                .foregroundStyle(on ? Color(nsColor: .windowBackgroundColor) : .secondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(
                                    on ? Color.accentColor : Color.secondary.opacity(0.12),
                                    in: Capsule()
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            Divider()
        }
    }
}
