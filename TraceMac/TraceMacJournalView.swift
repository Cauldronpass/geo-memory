// TraceMacJournalView.swift
// The Projects screen, the shared note editor, and the daily Move sheet.
// (Daily, Weekly and the Notes tab container retired in Session 83, D254/D255.)
// Mac-only — do not add to iOS, Widget, or Share Extension targets.

import SwiftUI
import AppKit
// `.image` for the photo panel's allowedContentTypes. Session 65.
import UniformTypeIdentifiers

// MARK: - Notification for Horizons deep-link from calendar panel

extension Notification.Name {
    static let openHorizonsFile  = Notification.Name("trace.openHorizonsFile")
    static let openWikilink      = Notification.Name("trace.openWikilink")
    static let selectDocument    = Notification.Name("trace.selectDocument")
    static let reloadDocuments   = Notification.Name("trace.reloadDocuments")
    /// Navigate to a record from any context. userInfo: ["type": "person"|"place", "id": String]
    static let navigateToRecord  = Notification.Name("trace.navigateToRecord")

    // `selectPerson` and `selectPlace` were removed in Session 63 (2026-08-02).
    //
    // Neither ever crossed a real boundary. Both existed so that
    // `TraceMacContentView` could switch section and then, after a hand-tuned
    // delay, post a notification to a view it had just asked to appear —
    // 0.1s for a wikilink, 0.15s from Home, 0.35s for a record. The target view
    // now takes the id as a `Binding` and consumes it in `.task(id:)`, which
    // does not care whether it was already on screen.
    //
    // Deleted rather than left in place: an unused notification name is an
    // invitation to wire the race back up.
}

// MARK: - Retired rooms (Session 83)
//
// `TraceMacNotesView` (the Daily / Weekly / Projects tab container) and
// `TraceMacDailyView` were deleted here in Session 83 (D254, D255). The day
// list lives in `MacDaysList.swift` and is reached from Today's DAYS word; the
// week notes are its week rules; the Projects screen below is the whole of
// this sidebar destination now. The Daily view's day-note creator — the
// second instance of the dead existence test D249 found — went with it, so
// the Session 82 open question is closed by deletion rather than by a fix.

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

    /// Was a second definition of the same calendar. Now one name for the
    /// shared one, so the call sites below did not have to change.
    private static let isoCal: Calendar = .traceWeekPOSIX

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
                        .font(MacGlyph.small)
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

// MARK: - Projects view (D256: list · note · rail, in the Editorial register)

struct TraceMacProjectsView: View {
    /// Bare `<Title>.md`, set by `TraceMacContentView` from a note wikilink or
    /// a search result (`routeNote`, Session 83).
    var deepLinkFile: Binding<String?>? = nil

    private let subfolder = "Notes/Projects"
    /// Bumped when the editor saves, so `MacProjectHubSidebar` re-derives its
    /// People / Places / Notes from the new body, and this list re-reads the
    /// row's first line and date.
    @State private var hubReload = 0

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
    @State private var docStore: TraceMacDocumentStore? = nil
    @State private var fileContents: [String: String] = [:]
    /// What the rows say (D256): the first meaningful line, when the file was
    /// last written, the first `[[person]]` it names, and the endeavors that
    /// link it. All read in `loadFiles`, re-read on save.
    @State private var previews:   [String: String] = [:]
    @State private var lastEdited: [String: Date]   = [:]
    @State private var personLink: [String: String] = [:]
    @State private var allEndeavors: [Endeavor] = []
    /// Row under the cursor, so an unpinned row can offer a pin to click (D82).
    @State private var hoveredFile: String? = nil

    // MARK: Derived

    /// Title, first line or body. Tags (`#tag` chips) were dropped with the
    /// redesign: none of the notes in the folder used one, and a search over
    /// the body finds a tag anyway.
    private var visible: [String] {
        guard !searchText.isEmpty else { return files }
        return files.filter { f in
            f.localizedCaseInsensitiveContains(searchText)
                || (previews[f]?.localizedCaseInsensitiveContains(searchText) ?? false)
                || (fileContents[f]?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    /// PINNED, then RECENT by last edit — what you are working on is at the
    /// top and finished things sink. Dayflow layers "pinned first" over a
    /// three-way sort menu; this list has one order and no menu.
    private var pinned: [String] { visible.filter { isPinned($0) }.sorted(by: byRecency) }
    private var recent: [String] { visible.filter { !isPinned($0) }.sorted(by: byRecency) }

    private func byRecency(_ a: String, _ b: String) -> Bool {
        (lastEdited[a] ?? .distantPast) > (lastEdited[b] ?? .distantPast)
    }

    private var kicker: String {
        let n = files.count
        if n == 0 { return "Nothing yet" }
        var parts = [n == 1 ? "1 note" : "\(n) notes"]
        let p = files.filter { isPinned($0) }.count
        if p > 0 { parts.append(p == 1 ? "1 pinned" : "\(p) pinned") }
        return parts.joined(separator: " \u{00B7} ")
    }

    // MARK: - Pinning (queue item 19)
    //
    // The pin is not a Mac-local idea. `DayflowFlagStore` keeps one JSON index
    // in the shared iCloud container, keyed on the vault-relative note path, and
    // Dayflow's project list has read it since 2026-07-22. The Mac joins that
    // index rather than starting a second one — see D78, and the file's own
    // header for why the flag is not in the note.
    //
    // **The key has to match exactly, and it does.** Dayflow builds
    // `"Notes/Projects/\(name).md"` from a bare title; this list's `files` are
    // already `<Title>.md`, so `subfolder + "/" + filename` is the same string.
    // Two ways of spelling one key is how an index like this silently splits.

    private func projectNotePath(_ filename: String) -> String { "\(subfolder)/\(filename)" }

    private func isPinned(_ filename: String) -> Bool {
        DayflowFlagStore.shared.isFlagged(projectNotePath(filename))
    }

    private func title(_ filename: String) -> String {
        filename.replacingOccurrences(of: ".md", with: "")
    }

    // MARK: Body

    var body: some View {
        HStack(spacing: 0) {
            listColumn
                .frame(width: MacEditorialLayout.listColumnWidth)
            Rectangle().fill(MacEditorialColor.hairline).frame(width: 1)
            Group {
                if let file = selectedFile, let store = docStore {
                    let notePath = "\(subfolder)/\(file)"
                    HStack(spacing: 0) {
                        TraceMacNoteEditor(relativePath: notePath,
                                           heading: "Project note",
                                           onSaved: {
                                               hubReload += 1
                                               Task { await refreshRow(file) }
                                           })
                            .frame(maxWidth: .infinity)
                        Rectangle().fill(MacEditorialColor.hairline).frame(width: 1)
                        MacProjectHubSidebar(notePath: notePath, store: store,
                                             reloadToken: hubReload)
                            .frame(width: MacEditorialLayout.railWidth)
                    }
                } else {
                    Text(files.isEmpty ? "Nothing yet. Press + to start one." : "Select a note")
                        .font(MacEditorialType.meta)
                        .foregroundStyle(MacEditorialColor.faint)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .background(MacEditorialColor.paper)
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
        .task(id: deepLinkFile?.wrappedValue) {
            guard let filename = deepLinkFile?.wrappedValue else { return }
            if files.isEmpty { await loadFiles() }
            // Only a file that is provably on disk joins the list (D249's
            // phantom: routing to a name that was never written put the
            // editor on nothing, and the editor created it empty on save).
            if !files.contains(filename) {
                guard noteStore.fileExists(projectNotePath(filename)) else {
                    deepLinkFile?.wrappedValue = nil
                    return
                }
                files.append(filename)
                await refreshRow(filename)
            }
            selectedFile = filename
            deepLinkFile?.wrappedValue = nil
        }
        .task {
            // Re-read the shared flag index before the list draws. The store is
            // a singleton that loads once, at first touch; a pin David sets on
            // the phone after this Mac launched would otherwise not appear until
            // the app is relaunched — which is the exact complaint item 19 is
            // about, one layer down. See `DayflowFlagStore.reload()`.
            DayflowFlagStore.shared.reload()
            // The person mark on a row matches `[[names]]` against People, and
            // this can be the first screen opened in a session.
            if notionService.people.isEmpty { await notionService.fetchPeople() }
            await loadFiles()
            if docStore == nil {
                docStore = TraceMacDocumentStore(noteStore: noteStore)
            }
            await docStore?.reload()
        }
    }

    // MARK: - The list

    private var listColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            MacEditorialMasthead(kicker: kicker, title: "Projects")
                .padding(.horizontal, MacEditorialLayout.margin)
                .padding(.top, MacEditorialLayout.topMargin)
            TextField("Search projects", text: $searchText)
                .textFieldStyle(.plain)
                .font(MacEditorialType.meta)
                .foregroundStyle(MacEditorialColor.ink)
                .padding(.top, 14)
                .padding(.bottom, 8)
                .overlay(alignment: .bottom) { MacEditorialRule.hair }
                .padding(.horizontal, MacEditorialLayout.margin)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !pinned.isEmpty {
                        MacEditorialSectionLabel(text: "Pinned").padding(.top, 22)
                        MacEditorialRule.ink
                        ForEach(pinned, id: \.self) { f in row(f) }
                    }
                    if !recent.isEmpty {
                        MacEditorialSectionLabel(text: pinned.isEmpty ? "Notes" : "Recent").padding(.top, 22)
                        MacEditorialRule.ink
                        ForEach(recent, id: \.self) { f in row(f) }
                    }
                    if pinned.isEmpty && recent.isEmpty && !searchText.isEmpty {
                        Text("Nothing matches.")
                            .font(MacEditorialType.meta)
                            .foregroundStyle(MacEditorialColor.faint)
                            .padding(.top, 18)
                    }
                    Spacer(minLength: MacEditorialLayout.plusSize + MacEditorialLayout.plusInset * 2)
                }
                .padding(.horizontal, MacEditorialLayout.margin)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            MacEditorialPlus { showingNewNote = true }
        }
    }

    /// Title in serif with the last-edit date small at the right, the first
    /// line beneath, then a quiet caps line of what is attached. A meeting
    /// note (one D250 wrote) carries the person it names, read from its
    /// `[[wikilink]]`, so it is recognisable without a section of its own —
    /// nothing on disk marks a meeting note, and recency already floats it up
    /// on meeting days.
    private func row(_ filename: String) -> some View {
        let isSelected: Bool = selectedFile == filename
        let wash: Color = isSelected ? MacEditorialColor.canvas : Color.clear
        let pinnedRow: Bool = isPinned(filename)
        let showPin: Bool = pinnedRow || hoveredFile == filename
        let pinTint: Color = pinnedRow ? MacEditorialColor.accent : MacEditorialColor.faint
        let preview: String? = previews[filename]
        let marks: [(glyph: String, text: String)] = attachmentMarks(filename)
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title(filename))
                        .font(MacEditorialType.rowTitle)
                        .foregroundStyle(MacEditorialColor.ink)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(dateText(filename))
                        .editorialListLabel()
                }
                if let preview, !preview.isEmpty {
                    Text(preview)
                        .font(MacEditorialType.meta)
                        .foregroundStyle(MacEditorialColor.muted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    Text("Nothing written yet")
                        .font(MacEditorialType.meta)
                        .foregroundStyle(MacEditorialColor.faint)
                        .italic()
                }
                if !marks.isEmpty {
                    HStack(spacing: 12) {
                        ForEach(Array(marks.enumerated()), id: \.offset) { _, mark in
                            HStack(spacing: 4) {
                                Image(systemName: mark.glyph).font(.system(size: 9))
                                Text(mark.text)
                            }
                            .editorialListLabel()
                        }
                    }
                    .padding(.top, 1)
                }
            }
            // A GLYPH THAT LOOKS LIKE A CONTROL IS A CONTROL (D82). A faint
            // outline pin on the row under the cursor, accent on a pinned row.
            if showPin {
                Button {
                    DayflowFlagStore.shared.toggleFlag(projectNotePath(filename))
                } label: {
                    Image(systemName: pinnedRow ? "pin.fill" : "pin")
                        .font(.system(size: 11))
                        .foregroundStyle(pinTint)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(pinnedRow ? "Unpin" : "Pin")
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, MacEditorialLayout.margin)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(wash)
        .contentShape(Rectangle())
        .onTapGesture { selectedFile = filename }
        .onHover { inside in
            if inside { hoveredFile = filename }
            else if hoveredFile == filename { hoveredFile = nil }
        }
        .padding(.horizontal, -MacEditorialLayout.margin)
        .overlay(alignment: .bottom) { MacEditorialRule.hair }
        .contextMenu {
            Button {
                DayflowFlagStore.shared.toggleFlag(projectNotePath(filename))
            } label: {
                Label(pinnedRow ? "Unpin" : "Pin", systemImage: pinnedRow ? "pin.slash" : "pin")
            }
            Divider()
            Button {
                renameCandidate = filename
                renameDraft = title(filename)
                showRenameSheet = true
            } label: { Label("Rename", systemImage: "pencil") }
            Divider()
            Button(role: .destructive) {
                deleteCandidate = filename
                showDeleteConfirm = true
            } label: { Label("Delete", systemImage: "trash") }
        }
    }

    /// "Today", "Yesterday", "22 Aug", "12 Aug 2025".
    private func dateText(_ filename: String) -> String {
        guard let d = lastEdited[filename] else { return "" }
        let cal = Calendar.current
        if cal.isDateInToday(d)     { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        let f = DateFormatter()
        f.dateFormat = cal.component(.year, from: d) == cal.component(.year, from: Date()) ? "d MMM" : "d MMM yyyy"
        return f.string(from: d)
    }

    /// Person first (it says what kind of note this is), then documents, then
    /// endeavors. Empty when there is nothing to say.
    private func attachmentMarks(_ filename: String) -> [(glyph: String, text: String)] {
        var out: [(glyph: String, text: String)] = []
        if let person = personLink[filename] { out.append(("person", person)) }
        let path = projectNotePath(filename)
        let docs = (docStore?.documents ?? []).filter { $0.linkedNote == path }.count
        if docs > 0 { out.append(("doc.text", docs == 1 ? "1 document" : "\(docs) documents")) }
        let ends = allEndeavors.filter { $0.linksNote(titled: title(filename)) }.count
        if ends > 0 { out.append(("flag", ends == 1 ? "1 endeavor" : "\(ends) endeavors")) }
        return out
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
        allEndeavors = EndeavorFile.loadAll(from: noteStore)
        for filename in files { await refreshRow(filename) }
    }

    /// Everything one row shows, read from the file: the body (for search),
    /// its first meaningful line (the same scan the Days list uses, so a
    /// project's caption and a day's are one rule), its modification date,
    /// and the first `[[name]]` that is a person.
    private func refreshRow(_ filename: String) async {
        let path = projectNotePath(filename)
        let content = (try? noteStore.readFile(path)) ?? ""
        fileContents[filename] = content
        switch MacDayScan.firstMeaningfulLine(of: content) {
        case .prose(let t), .override(let t): previews[filename] = t
        case .none:                           previews.removeValue(forKey: filename)
        }
        if let url = noteStore.containerURL?.appendingPathComponent(path),
           let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let date = attrs[.modificationDate] as? Date {
            lastEdited[filename] = date
        }
        let people = Set(notionService.people.filter { !$0.isArchived }.map { $0.name.lowercased() })
        personLink[filename] = NoteStore.wikilinkTargets(in: content)
            .first { people.contains($0.lowercased()) }
    }

    private func createNote() {
        let name = newNoteName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let filename = "\(name).md"
        let path = "\(subfolder)/\(filename)"
        // **A title line, not frontmatter.** Every project note already in the
        // vault starts `# Name` and nothing else, and the seven-key block this
        // replaced had two writers and zero readers: nothing in either app parses
        // `title:`, `type:`, `created:` or `linked_notes:` on a project note.
        // Tags come from `#tag` in the body, linked notes from `[[wikilinks]]`
        // in the body (D64), documents from Satchel sidecars.
        //
        // It also could not be hidden. `EndeavorFile.parse` splits frontmatter off
        // before an Endeavor note reaches the editor; a project note goes to the
        // generic editor whole, so the block rendered as seven lines of raw text
        // at the top of every new note. David, on the first one he made:
        // *"i added a project note in TraceMac and this came up."*
        let content = """
        # \(name)

        """
        try? noteStore.writeFile(path, content: content)
        if !files.contains(filename) { files.append(filename) }
        selectedFile = filename
        newNoteName = ""
        showingNewNote = false
        Task {
            await refreshRow(filename)
            await docStore?.reload()
        }
    }

    private func renameNote() {
        guard let old = renameCandidate else { return }
        let newName = renameDraft.trimmingCharacters(in: .whitespaces)
        guard !newName.isEmpty else { return }
        let newFilename = newName + ".md"
        guard newFilename != old else { showRenameSheet = false; renameCandidate = nil; return }
        try? noteStore.moveFile(from: "\(subfolder)/\(old)", to: "\(subfolder)/\(newFilename)")
        // The flag index is keyed on the path, so the rename has to carry it or
        // the pin points at a file that no longer exists and the note comes back
        // unpinned. Same reason `deleteNote` clears rather than leaves.
        DayflowFlagStore.shared.moveFlag(from: projectNotePath(old),
                                         to: projectNotePath(newFilename))
        if let idx = files.firstIndex(of: old) { files[idx] = newFilename }
        previews.removeValue(forKey: old); lastEdited.removeValue(forKey: old)
        personLink.removeValue(forKey: old); fileContents.removeValue(forKey: old)
        if selectedFile == old { selectedFile = newFilename }
        showRenameSheet = false; renameCandidate = nil
        Task { await refreshRow(newFilename) }
    }

    private func deleteNote(_ filename: String) {
        try? noteStore.deleteFile("\(subfolder)/\(filename)")
        DayflowFlagStore.shared.clearFlag(projectNotePath(filename))
        files.removeAll { $0 == filename }
        previews.removeValue(forKey: filename); lastEdited.removeValue(forKey: filename)
        personLink.removeValue(forKey: filename); fileContents.removeValue(forKey: filename)
        if selectedFile == filename { selectedFile = nil }
        deleteCandidate = nil
    }
}


// MARK: - The markdown editor lives in MacTextEditor.swift (D217, Session 83)
//
// `MacEditorCommand`, `MarkdownNSTextView`, `MacEditorActions` and
// `MacTextEditor` were defined here until Session 83 and moved out unchanged.

// MARK: - Shared markdown editor

struct TraceMacNoteEditor: View {
    let relativePath: String

    /// The section label over the note — "Day note", "Project note". When
    /// given, the editor draws the Editorial heading row itself: the label,
    /// the `B I U` switch, the ⓘ box, and the rule beneath that turns accent
    /// while the note has the keyboard. Nil draws no heading (the screens
    /// that frame the note some other way). D258, second pass: David found
    /// the controls on Today and not on a project note, and the reason was
    /// that they were Today's, not the note's.
    var heading: String? = nil
    /// How far the heading row sits in from the edge. Defaults to the
    /// Editorial margin, which lines it up with `MacTextEditor`'s own 40pt text
    /// inset the way Today's column does; a host that already pads the whole
    /// column (Today) passes 0.
    var headingInset: CGFloat = MacEditorialLayout.margin
    var showMoveButton: Bool = false
    var moveSourceDate: Date? = nil

    /// File text → what the editor shows. Session 64, for Endeavor notes,
    /// which carry frontmatter a day note does not. Without it the editor puts
    /// the YAML on screen and invites you to break it.
    var loadTransform: ((String) -> String)? = nil

    /// (edited text, the file **as it is on disk right now**) → new file text.
    ///
    /// The second argument is re-read at save time rather than captured at
    /// load, so a change made to the frontmatter elsewhere — the phone editing
    /// dates while this pane holds the body — survives. Same rule as `remind:`:
    /// a save must not rewrite a field it was not asked to change.
    var saveTransform: ((String, String) -> String)? = nil

    /// Fired after a debounced write lands, so an owner can refresh anything
    /// derived from the file. The Endeavor rail reads "which visits does the
    /// log name" straight out of the body, so it has to re-derive on save.
    var onSaved: (() -> Void)? = nil

    /// An externally-owned command channel, so an owner can reach the live
    /// editor — see `MacEditorActions.applyToBody`. Defaulted to nil, so the
    /// eleven call sites that have no such need are untouched and keep the
    /// private instance below.
    var externalActions: MacEditorActions? = nil

    /// AppKit's first-responder fact, passed straight through from
    /// `MacTextEditor`, for an owner that draws a focus signal (Today's accent
    /// rule). D258.
    var onFocusChange: ((Bool) -> Void)? = nil

    @Environment(NoteStore.self)     private var noteStore
    @Environment(NotionService.self) private var notionService

    @State private var content        = ""
    @State private var saveTask: Task<Void, Never>? = nil
    /// AppKit's first-responder fact, kept here for the heading's rule.
    @State private var focused = false
    @State private var showNoteInfo = false
    /// The floating bar's switch — the same `@AppStorage` key ⇧⌘Y and the
    /// `B I U` button write, so every note on the Mac shares one setting.
    @AppStorage(MacNoteToolbarSetting.key) private var showNoteToolbar = false
    // @State keeps the same MacEditorActions instance across re-renders; makeNSView wires it once.
    @State private var ownActions  = MacEditorActions()
    private var editorActions: MacEditorActions { externalActions ?? ownActions }
    // Wikilink autocomplete state
    @State private var wikiQuery:       String? = nil
    @State private var wikiSuggestions: [String] = []
    /// Projects + Daily, per D49. Rebuilt when a wikilink session *opens* rather
    /// than per keystroke — `linkableNotes()` is two directory reads.
    @State private var linkableNotes:   [LinkableNote] = []
    private var noteTitleSet: Set<String> {
        Set(linkableNotes.map { $0.title.lowercased() })
    }
    // Move sheet state
    @State private var showMoveSheet   = false
    @State private var moveContent     = ""
    @State private var postMoveContent = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let heading { headingRow(heading) }
            MacTextEditor(text: $content, actions: editorActions,
                          onFocusChange: { isFocused in
                              focused = isFocused
                              onFocusChange?(isFocused)
                          },
                          onWikilinkQuery: { query in
                              // A session opening is the moment to re-read the note
                              // folders: often enough to catch a note made minutes
                              // ago, rare enough not to hit the disk per keystroke.
                              if wikiQuery == nil, query != nil {
                                  linkableNotes = noteStore.linkableNotes()
                              }
                              wikiQuery = query
                              // Read directly from NotionService at query time — avoids the
                              // load-once race where people/places aren't yet fetched.
                              if let q = query, !q.isEmpty {
                                  let people = notionService.people
                                      .filter { !$0.isArchived }
                                      .map(\.name)
                                  let places = notionService.places.map(\.name)
                                  // D49. Notes are a third source, not a replacement:
                                  // `[[Megan]]` should still offer the person.
                                  let notes  = linkableNotes.map { $0.title }
                                  var seen = Set<String>()
                                  wikiSuggestions = Array((people + places + notes)
                                      .filter { $0.localizedCaseInsensitiveContains(q) }
                                      .sorted()
                                      // The pill row is keyed `id: \.self`, so a note
                                      // titled the same as a person would collide and
                                      // SwiftUI would drop one silently.
                                      .filter { seen.insert($0.lowercased()).inserted }
                                      .prefix(8))
                              } else {
                                  wikiSuggestions = []
                              }
                          },
                          onWikilinkAccept: {
                              guard let first = wikiSuggestions.first else { return false }
                              editorActions.execute(.applyWikiSuggestion(first))
                              return true
                          },
                          onMoveRequest: showMoveButton ? { textToMove, remaining in
                              moveContent     = textToMove
                              postMoveContent = remaining
                              showMoveSheet   = true
                          } : nil,
                          onPasteImage: { data in storeImage(data) != nil },
                          noteTitles: noteTitleSet)
                .onChange(of: content) { _, newValue in
                    scheduleSave(content: newValue)
                }
                .padding(.top, heading == nil ? 0 : 12)
                // `maxHeight: .infinity` and nothing below it in the stack:
                // `MacTextEditor` adopts whatever height it is proposed and
                // never reports a minimum, so anything competing for the
                // column would win it (Today learned this in Session 80).
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        }
        // **One chrome for every note on the Mac** (D258, Session 83).
        //
        // Until Session 83 this editor wore a docked fifteen-button toolbar
        // with a word count and a "Saved" line under it, while Today drew the
        // SAME `MacTextEditor` with its own seven-button capsule floating over
        // the page. Two toolbars over one editor, and nothing keeping them in
        // step — the drift the D217 lift prevented one layer down and not
        // here. David: "lets keep todays view. the other view was more for
        // iOS." So Today's bar moved in here, Today now uses this view, and
        // the docked bar, the word count and the Saved line are gone (the ⓘ
        // box on Today already counts words).
        //
        // Floating, not stacked, for Session 80's reason: an overlay takes
        // nothing from the page. The wikilink suggestions ride above the bar
        // in the same capsule grammar, so `[[` behaves identically on every
        // screen — it had never worked on Today at all.
        .overlay(alignment: .bottom) { floatingChrome }
        .task(id: relativePath) {
            // Re-wired per note, not once: `externalActions` is owned by a view
            // that outlives any single note, so the closure has to close over
            // the right `relativePath` — otherwise switching endeavor and then
            // adding a visit writes into the endeavor you were reading before.
            editorActions.applyToBody = { transform in
                let updated = transform(content)
                guard updated != content else { return }
                content = updated
                scheduleSave(content: updated)
            }
            // Also here, not only when a `[[` session opens: the colour has to be
            // right for links already in the note the moment it appears, and
            // nobody types anything to open a note they are only reading.
            linkableNotes = noteStore.linkableNotes()
            await loadContent()
        }
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

    // MARK: - The heading (D258, second pass)

    /// Label, controls, rule. Moved here from `TraceMacTodayView` so every
    /// note wears it, not only the day's.
    private func headingRow(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
                MacEditorialSectionLabel(text: title)
                Spacer(minLength: 8)
                noteHeaderControls
            }
            // **The rule goes accent while the note has the keyboard.** Session
            // 80, from Today: arrows must move the caret while you are typing,
            // and `MacEditorialArrowKeys` stands down for exactly that reason —
            // but it happened SILENTLY in a large, pale, often empty pane.
            // Accent already means "active, or acting" everywhere in this app,
            // so one rule changing colour says where the keyboard went.
            if focused { MacEditorialRule.accent } else { MacEditorialRule.ink }
        }
        .padding(.horizontal, headingInset)
    }

    /// The two controls in the corner of the heading.
    ///
    /// Session 80, from a Bear screenshot: "there is a B/I/U icon on the top
    /// right of the area that when clicked brings up the same floating format
    /// bar but it also has the table of contents, statistics, and backlinks in
    /// that information box."
    ///
    /// **Two buttons rather than Bear's one.** Bear's `ⓘ` opens a panel that
    /// happens to contain the formatting controls as well. Here the formatting
    /// bar already exists as a thing that floats over the page, and folding it
    /// into a popover would mean two ways to summon one bar with different
    /// behaviour. So `B I U` toggles the bar — the same state ⇧⌘Y writes, so
    /// the button and the key are the same switch, not two — and `ⓘ` is only
    /// the information.
    ///
    /// In the heading rather than floating over the page, because these are
    /// about the note as a whole. The floating bar acts on the words you are
    /// writing; these two describe the document. Different scope, different
    /// place.
    private var noteHeaderControls: some View {
        HStack(spacing: 1) {
            Button { showNoteToolbar.toggle() } label: {
                Text("B I U")
                    .font(.system(size: 9.5, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(showNoteToolbar ? MacEditorialColor.accent
                                                     : MacEditorialColor.faint)
                    .frame(height: 22)
                    .padding(.horizontal, 5)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Formatting bar (\u{21e7}\u{2318}Y)")

            Button { showNoteInfo.toggle() } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(MacEditorialColor.faint)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("About this note")
            .popover(isPresented: $showNoteInfo, arrowEdge: .bottom) { noteInfo }
        }
    }

    /// What the note is made of. Deliberately small — David: "minimal is fine
    /// now and we can iterate on it later."
    ///
    /// Contents, then counts. Both are read straight off `content`, which
    /// costs one pass over a document that is at most a screen or two; no index,
    /// no cache, nothing to invalidate. A note is not big enough to earn
    /// machinery, and building some would be answering a scale question nobody
    /// has asked.
    ///
    /// **Backlinks are absent on purpose.** `NoteStore.findWikilinkMentions` can
    /// answer "what links to X" and Bear shows exactly that — but a day note's X
    /// is a date, and it is not clear what linking to a date means in this vault
    /// yet. Shipping a section that is empty for every note is worse than not
    /// shipping it. Noted in the backlog with the question that has to be
    /// answered first. (For a project note the question is easier, and this is
    /// where that section would go once it is answered for both.)
    private var noteInfo: some View {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        let headings = lines.filter { $0.hasPrefix("#") }.map(String.init)
        let words = content.split(whereSeparator: { $0.isWhitespace }).count
        let open = lines.filter { $0.hasPrefix("\u{2610} ") }.count
        let done = lines.filter { $0.hasPrefix("\u{2611} ") }.count

        return VStack(alignment: .leading, spacing: 0) {
            Text("Contents").editorialFieldLabel()
            if headings.isEmpty {
                Text("No headings")
                    .font(MacEditorialType.meta)
                    .foregroundStyle(MacEditorialColor.faint)
                    .padding(.top, 4)
            } else {
                ForEach(Array(headings.enumerated()), id: \.offset) { _, heading in
                    let depth = heading.prefix(while: { $0 == "#" }).count
                    Text(heading.drop(while: { $0 == "#" || $0 == " " }))
                        .font(MacEditorialType.fieldValue)
                        .foregroundStyle(MacEditorialColor.ink)
                        .lineLimit(1)
                        // Indent by level, so a note with structure looks like
                        // it has structure.
                        .padding(.leading, CGFloat(max(0, depth - 1)) * 12)
                        .padding(.vertical, 2)
                }
            }

            MacEditorialRule.hair.padding(.vertical, 10)

            Text("Statistics").editorialFieldLabel()
            statRow("Words", "\(words)")
            statRow("Characters", "\(content.count)")
            if open + done > 0 {
                statRow("To do", "\(open)")
                statRow("Done", "\(done)")
            }
        }
        .padding(16)
        .frame(width: 230, alignment: .leading)
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(MacEditorialType.meta)
                .foregroundStyle(MacEditorialColor.muted)
            Spacer(minLength: 12)
            Text(value)
                .font(MacEditorialType.time)
                .foregroundStyle(MacEditorialColor.ink)
        }
        .frame(height: 20)
    }

    // MARK: - The floating chrome (D258)

    /// Suggestions above, formatting bar below, both bottom-centred. Either
    /// can be absent; the stack collapses to whichever is there.
    @ViewBuilder
    private var floatingChrome: some View {
        VStack(spacing: 8) {
            if !wikiSuggestions.isEmpty { wikiSuggestionBar }
            if showNoteToolbar { noteBar }
        }
        .padding(.bottom, 18)
    }

    /// Wikilink suggestions — shown only while the caret is inside `[[…]]`.
    /// Accent pills, because picking one is an act; Return takes the first.
    private var wikiSuggestionBar: some View {
        HStack(spacing: 6) {
            ForEach(wikiSuggestions, id: \.self) { name in
                Button {
                    editorActions.execute(.applyWikiSuggestion(name))
                } label: {
                    Text(name)
                        .font(MacEditorialType.meta)
                        .foregroundStyle(MacEditorialColor.accent)
                        .lineLimit(1)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(MacEditorialColor.accent.opacity(0.10), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(MacEditorialColor.paper, in: Capsule())
        .overlay { Capsule().strokeBorder(MacEditorialColor.hairline, lineWidth: 1) }
        .shadow(color: .black.opacity(0.13), radius: 10, y: 3)
    }

    /// The formatting bar: a capsule floating over the page, toggled by ⇧⌘Y or
    /// by the `B I U` button in a note's heading. Moved here from
    /// `TraceMacTodayView` unchanged (Session 80's reasoning stands there in
    /// the D-record: toggled not focus-gated, floating not stacked,
    /// bottom-centred, seven buttons not thirteen). The bar is
    /// discoverability, not capability — every command is still reachable by
    /// typing, and a photo still arrives by ⌘V through `onPasteImage`.
    private var noteBar: some View {
        HStack(spacing: 1) {
            barButton("textformat.size", "Heading") { editorActions.execute(.heading) }
            barButton("checkmark.square", "Checkbox") { editorActions.execute(.checkbox) }
            barButton("list.bullet", "Bullet") { editorActions.execute(.bullet) }
            Divider().frame(height: 15).padding(.horizontal, 4)
            barButton("bold", "Bold") { editorActions.execute(.bold) }
            barButton("italic", "Italic") { editorActions.execute(.italic) }
            barButton("highlighter", "Highlight") { editorActions.execute(.highlight) }
            barButton("link", "Link") { editorActions.execute(.link) }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(MacEditorialColor.paper, in: Capsule())
        .overlay { Capsule().strokeBorder(MacEditorialColor.hairline, lineWidth: 1) }
        .shadow(color: .black.opacity(0.13), radius: 10, y: 3)
    }

    private func barButton(_ icon: String, _ help: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(MacEditorialColor.muted)
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Helpers

    private func loadContent() async {
        let raw = (try? noteStore.readFile(relativePath)) ?? ""
        content = loadTransform?(raw) ?? raw
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

    // MARK: - Photos

    /// Writes image bytes into the container and inserts a thumbnail marker.
    /// Returns the container-relative path, or nil if nothing was stored.
    ///
    /// **The storage rule is iOS's, spelled the same way**:
    /// `Photos/<year>/<month>/yyyy-MM-dd-HHmmss.jpg`, re-encoded. It is
    /// duplicated here rather than shared, and that is a debt rather than a
    /// decision — iOS has three inline copies of the same eight lines in
    /// `MarkdownEditorView`, so the right fix is one helper on `NoteStore` that
    /// all four adopt. Not done in this change because it edits the largest and
    /// most-used file on the phone in a session that has already shipped a lot
    /// uncompiled. Recorded so it is not rediscovered.
    ///
    /// `EndeavorFile.downscaledJPEG` does the re-encode. Its home is now wrong —
    /// it is ImageIO, not endeavor format — but a fourth copy of a
    /// `CGImageSource` dance would be worse than a misfiled function, and moving
    /// it is a job for whenever a third caller appears.
    @discardableResult
    private func storeImage(_ data: Data) -> String? {
        let jpeg = EndeavorFile.downscaledJPEG(data) ?? data
        let now = Date()
        let cal = Calendar.current
        let year  = cal.component(.year, from: now)
        let month = String(format: "%02d", cal.component(.month, from: now))
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd-HHmmss"
        let filename = "\(fmt.string(from: now)).jpg"
        guard let path = try? noteStore.writePhoto(jpeg,
                                                   category: "\(year)/\(month)",
                                                   filename: filename) else { return nil }
        // TWO bangs: the rendered-thumbnail form. One bang is the compact link
        // form — orange text, no picture — which is what iOS inserted until
        // 2026-07-30 and what produced *"there is no photo rendering"*.
        //
        // The description is the source filename, or the timestamp for a paste.
        // It is hidden by the renderer here, so it exists for the phone, for
        // Obsidian, and for anyone reading the raw file.
        editorActions.execute(.insertText("!![\(imageCaption(filename))](\(path))"))
        return path
    }

    private func imageCaption(_ filename: String) -> String {
        (filename as NSString).deletingPathExtension
    }

    private func saveNow() {
        let out: String
        if let saveTransform {
            let onDisk = (try? noteStore.readFile(relativePath)) ?? ""
            out = saveTransform(content, onDisk)
        } else {
            out = content
        }
        try? noteStore.writeFile(relativePath, content: out)
        onSaved?()
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
                                .font(on ? MacType.metaEmphasis : MacType.meta)
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
