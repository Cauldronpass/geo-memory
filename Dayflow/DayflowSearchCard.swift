//  DayflowSearchCard.swift
//  Dayflow
//
//  Search from the Action Button: one word, then everything that matched, with
//  the line it matched on.
//
//  **Built to answer, not to navigate** (D370). If every search ended in tapping
//  through to an app, this card would be a slower route to an app that was
//  already one tap away. It earns its place on the searches that end by reading
//  it and closing it — "did I already capture that", "what was that receipt
//  called", "is there still an open task about the house". Opening is the escape
//  hatch for the one you actually wanted.
//
//  **The engine is the one the apps already use, not a new one.**
//  `MacSearchEngine.run` walks one corpus with one set of field weights and one
//  ranking rule for the Mac, Trace, Satchel and now this. Its matching is
//  literal, case-insensitive substring — which is exactly the wildcard David
//  described: "house" finds "Find house papers" and a mortgage statement whose
//  title says nothing about a house.
//
//  **Document bodies are searched, and that is the point.** The most useful
//  results here are files whose titles do not contain the word at all.

import AppIntents
import SwiftUI

// MARK: - What was searched

@MainActor
@Observable
final class DayflowSearchDraft {
    static let shared = DayflowSearchDraft()

    /// The tabs, in the order they are drawn. **Five is the width of a phone**,
    /// so people, places and endeavors share one — they are in the corpus
    /// because dropping them would hide real content, and collapsed because
    /// they are rarely what the Action Button is for.
    enum Tab: String, CaseIterable {
        case all, tasks, notes, documents, other

        var label: String {
            switch self {
            case .all:       return "All"
            case .tasks:     return "Tasks"
            case .notes:     return "Notes"
            case .documents: return "Docs"
            case .other:     return "Other"
            }
        }

        func accepts(_ kind: MacSearchKind) -> Bool {
            switch self {
            case .all:       return true
            case .tasks:     return kind == .task
            case .notes:     return kind == .note
            case .documents: return kind == .document
            case .other:     return kind == .person || kind == .place || kind == .endeavor
            }
        }
    }

    var term: String = ""
    var results: [MacSearchResult] = []
    var tab: Tab = .all
    /// Ids ticked during this card's life, so a row can strike through and stay
    /// put rather than vanishing under the finger that hit it.
    var completed: Set<String> = []
    /// True while document bodies are still being read. See `run`.
    var reading = false
    var searched = false

    private var corpus = MacSearchCorpus()

    private init() {}

    // MARK: Running it

    func run(term raw: String) async {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        term = query
        completed = []
        tab = .all
        results = []
        searched = false
        guard !query.isEmpty else { return }

        // **Tasks first, because they are already in memory.** Everything else
        // needs a filesystem walk, and a card that showed nothing at all for a
        // second or two would read as broken. This also means the commonest
        // question — is there an open task about this — is answered before the
        // disk is touched.
        await ReminderTaskStore.shared.refreshAll()
        reading = true
        results = MacSearchEngine.run(query: query,
                                      corpus: MacSearchCorpus(),
                                      documents: [],
                                      people: [],
                                      places: [],
                                      tasks: openTasks)
        searched = true

        // Then the corpus and the documents.
        if let url = NoteStore.shared.containerURL {
            let built = await Task.detached(priority: .userInitiated) {
                MacSearchCorpus.build(containerURL: url)
            }.value
            corpus = built
        }
        await TraceSatchelChipStore.shared.refresh()

        results = MacSearchEngine.run(query: query,
                                      corpus: corpus,
                                      documents: TraceSatchelChipStore.shared.all,
                                      people: NotionService.shared.people,
                                      places: NotionService.shared.places,
                                      tasks: openTasks)
        reading = false
    }

    /// **Finished tasks are left out.** One matching "house" answers a different
    /// question from an open one, and mixing them is how a card reports
    /// something as handled when it is not.
    private var openTasks: [ThingsTask] {
        ReminderTaskStore.shared.allTasks
    }

    // MARK: Reading it

    var shown: [MacSearchResult] {
        results.filter { tab.accepts($0.kind) }
    }

    func count(_ t: Tab) -> Int {
        results.filter { t.accepts($0.kind) }.count
    }

    /// Grouped by kind rather than interleaved by score: he almost always
    /// arrives knowing what sort of thing he is after, even when he does not
    /// know which one.
    var groups: [MacSearchGroup] {
        MacSearchEngine.grouped(shown)
    }

    // MARK: Acting

    func complete(_ id: String) async {
        // `complete` returns nothing — it drops the task from its pools and
        // saves. **The card records the tap itself** rather than re-reading to
        // find out: the store's own arrays are the wrong place to ask, since a
        // completed task leaves them entirely and "gone" and "never there" look
        // identical from here. This set is what lets the row strike through and
        // stay where it is.
        await ReminderTaskStore.shared.complete(taskID: id)
        completed.insert(id)
    }

    /// Where a result opens, or nil when nothing can show it.
    ///
    /// **A chevron that opens nothing is a dead control**, which this codebase
    /// has had to clean up before, so a row whose destination has no screen
    /// simply does not offer one. Notes route by folder through the resolver
    /// Satchel's chips already use: Trace owns people and places, Dayflow owns
    /// projects and days.
    nonisolated static func url(for result: MacSearchResult) -> URL? {
        switch result.destination {
        case .task(let id):
            return route(scheme: "dayflow", host: "task", key: "id", value: id)
        case .document(let path):
            return route(scheme: "satchel", host: "document", key: "path", value: path)
        case .dailyOrProjectNote(let path):
            // **Routed here rather than through Satchel's `noteOwnerAppURL`**,
            // which lives in a Satchel-only file and is invisible to this
            // target. The rule is the same one it applies: Trace owns people
            // and places, Dayflow owns days, projects and endeavors.
            return noteRoute(path)
        case .inboxNote:
            // See `noteRoute`: nothing routes these.
            return nil
        case .endeavor(let id):
            return route(scheme: "dayflow", host: "endeavor", key: "id", value: id)
        case .weeklyNote(let filename):
            // **Was nil, with Horizons listed below as a Trace concept Dayflow
            // has no screen for** (D394). It has one now, so the row is
            // tappable. The case carries a bare filename, not a path — it
            // rides the Mac's `pendingHorizonsFile` — so the folder is added
            // here rather than changing an enum four Mac screens read.
            let name = filename.hasSuffix(".md") ? filename : filename + ".md"
            return route(scheme: "dayflow", host: "note", key: "path",
                         value: "Notes/Horizons/" + name)
        case .person, .place, .preview:
            // People and places live in Trace. Readable on the card, not
            // tappable — this codebase has already spent an evening on
            // controls that advertised actions they could not perform.
            return nil
        }
    }

    nonisolated private static func noteRoute(_ path: String) -> URL? {
        if path.hasPrefix("Notes/People/") || path.hasPrefix("Notes/Places/") {
            return route(scheme: "trace", host: "note", key: "path", value: path)
        }
        // **No `Notes/Inbox/`, though I added it once.** Dayflow's router knows
        // daily notes, project notes and endeavors; an inbox note falls through
        // it and lands nowhere, so those rows get no chevron rather than one
        // that opens the app and does nothing (D376).
        if path.hasPrefix("Calendar/")
            || path.hasPrefix("Notes/Endeavors/")
            || path.hasPrefix("Notes/Projects/") {
            return route(scheme: "dayflow", host: "note", key: "path", value: path)
        }
        return nil
    }

    /// `URLComponents`, never interpolation: an endeavor called "Mum & Dad's
    /// 50th" carries a space and an ampersand, and an unescaped ampersand
    /// truncates the path.
    nonisolated private static func route(scheme: String, host: String,
                                          key: String, value: String) -> URL? {
        var c = URLComponents()
        c.scheme = scheme
        c.host = host
        c.queryItems = [URLQueryItem(name: key, value: value)]
        return c.url
    }
}

// MARK: - The action

struct DayflowSearchIntent: AppIntent {
    static var title: LocalizedStringResource = "Search"
    static var description = IntentDescription(
        "Searches your notes, documents, tasks, people, places and endeavors, and shows what matched."
    )
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Search for", requestValueDialog: "Search for?")
    var term: String

    @MainActor
    func perform() async throws -> some IntentResult & ShowsSnippetIntent {
        await DayflowSearchDraft.shared.run(term: term)
        return .result(snippetIntent: DayflowSearchSnippetIntent())
    }
}

struct DayflowSearchSnippetIntent: SnippetIntent {
    static var title: LocalizedStringResource = "Results"

    @Dependency private var draft: DayflowSearchDraft

    @MainActor
    func perform() async throws -> some IntentResult & ShowsSnippetView {
        .result(view: DayflowSearchCard(draft: draft))
    }
}

// MARK: - Buttons

struct DayflowSearchTabIntent: AppIntent {
    static var title: LocalizedStringResource = "Filter Results"
    static var openAppWhenRun: Bool = false
    static var isDiscoverable: Bool = false

    @Parameter(title: "Tab") var tab: String

    init() {}
    init(tab: String) { self.tab = tab }

    @Dependency private var draft: DayflowSearchDraft

    @MainActor
    func perform() async throws -> some IntentResult {
        if let t = DayflowSearchDraft.Tab(rawValue: tab) { draft.tab = t }
        return .result()
    }
}

struct DayflowSearchCompleteIntent: AppIntent {
    static var title: LocalizedStringResource = "Tick It Off"
    static var openAppWhenRun: Bool = false
    static var isDiscoverable: Bool = false

    @Parameter(title: "Task") var taskID: String

    init() {}
    init(taskID: String) { self.taskID = taskID }

    @Dependency private var draft: DayflowSearchDraft

    @MainActor
    func perform() async throws -> some IntentResult {
        await draft.complete(taskID)
        return .result()
    }
}

/// Opening one result. **This one does leave**, and the card goes with it.
struct DayflowSearchOpenIntent: AppIntent {
    static var title: LocalizedStringResource = "Open It"
    /// **`true`, and it is the whole reason this button works** (D373). Every
    /// other intent on these cards is `false`, because bringing an app forward
    /// to tick a box is a slower version of the thing it replaces — and that
    /// default was copied here without thinking, onto the one intent whose
    /// entire job is to bring an app forward. An intent that declares it will
    /// not open the app, then returns an intent that opens a URL, is asking for
    /// two contradictory things and gets the one it declared.
    static var openAppWhenRun: Bool = true
    static var isDiscoverable: Bool = false

    @Parameter(title: "URL") var target: String

    init() {}
    init(target: String) { self.target = target }

    @MainActor
    func perform() async throws -> some IntentResult & OpensIntent {
        guard let url = URL(string: target) else { return .result() }
        // **Both, and they do different halves** (D376). `OpenURLIntent` brings
        // the app forward, which only the system can do. For a `dayflow://`
        // link that app is the one this intent is already running inside, and
        // in that case `onOpenURL` does not fire — so the URL is also handed
        // over directly, and `ContentView` routes whichever arrives.
        // `satchel://` and `trace://` are genuinely other apps and need only
        // the first half.
        if url.scheme == "dayflow" {
            DayflowRouteInbox.shared.deliver(url)
        }
        return .result(opensIntent: OpenURLIntent(url))
    }
}

/// Asking again without pressing the Action Button twice: the second search is
/// usually a correction of the first.
struct DayflowSearchAgainIntent: AppIntent {
    static var title: LocalizedStringResource = "Search Again"
    static var openAppWhenRun: Bool = false
    static var isDiscoverable: Bool = false

    @Parameter(title: "Search for", requestValueDialog: "Search for?")
    var term: String

    @Dependency private var draft: DayflowSearchDraft

    @MainActor
    func perform() async throws -> some IntentResult {
        await draft.run(term: term)
        return .result()
    }
}

// MARK: - The card

struct DayflowSearchCard: View {
    let draft: DayflowSearchDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if draft.searched && draft.results.isEmpty && !draft.reading {
                empty
            } else {
                tabs
                ForEach(draft.groups) { group in
                    kindLabel(group.kind)
                    ForEach(group.items) { result in
                        row(result)
                    }
                }
                if draft.reading {
                    HStack(spacing: 6) {
                        Circle().fill(Color.dayflowFaint).frame(width: 5, height: 5)
                        Text("still reading document text…")
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dayflowFaint)
                    .padding(.vertical, 9)
                }
            }
            again
        }
        .padding(14)
        .background(Color.dayflowPaper)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("“\(draft.term)”")
                .font(.dayflowSerif(16))
                .foregroundStyle(Color.dayflowInk)
                .lineLimit(1)
            if !draft.results.isEmpty {
                Text(countLabel)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.dayflowFaint)
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 11)
    }

    private var countLabel: String {
        let n = draft.shown.count
        if draft.tab == .all { return n == 1 ? "1 match" : "\(n) matches" }
        return "\(n) \(draft.tab.label.lowercased())"
    }

    private var tabs: some View {
        DayflowSnippetFlow(spacing: 6) {
            ForEach(DayflowSearchDraft.Tab.allCases, id: \.self) { t in
                // A tab with nothing behind it is not drawn. An empty tab is a
                // control that does nothing, and the count it would show is
                // already the answer.
                if draft.count(t) > 0 {
                    Button(intent: DayflowSearchTabIntent(tab: t.rawValue)) {
                        HStack(spacing: 4) {
                            Text(t.label)
                            Text("\(draft.count(t))")
                                .foregroundStyle(draft.tab == t
                                                 ? Color.dayflowAccent.opacity(0.7)
                                                 : Color.dayflowFaint)
                        }
                        .font(.system(size: 11.5, weight: .semibold))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(draft.tab == t
                                                   ? Color.dayflowAccent.opacity(0.12)
                                                   : Color.dayflowPanel))
                        .overlay(Capsule().stroke(draft.tab == t
                                                  ? Color.dayflowAccent
                                                  : Color.dayflowHairline, lineWidth: 1))
                        .foregroundStyle(draft.tab == t ? Color.dayflowAccent : Color.dayflowInk)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func kindLabel(_ kind: MacSearchKind) -> some View {
        Text(kind.label.uppercased())
            .font(.system(size: 9.5, weight: .bold))
            .tracking(1.1)
            .foregroundStyle(Color.dayflowFaint)
            .padding(.top, 14)
            .padding(.bottom, 4)
    }

    /// **The circle ticks, the rest of the row opens** — the split the Mac
    /// dashboard has used for months, so a task row that answered only to its
    /// circle would be the odd one out.
    private func row(_ result: MacSearchResult) -> some View {
        // **Keyed on the reminder's id, not the result's** (D374). A search
        // result's id is `task:<reminder id>`, and the tick was recorded under
        // the bare reminder id — so the row asked whether a set containing
        // `ABC` contained `task:ABC` and was told no, every time. The reminder
        // really was being completed; only the screen disagreed.
        let taskID: String? = {
            if case .task(let id) = result.destination { return id }
            return nil
        }()
        let done = taskID.map { draft.completed.contains($0) } ?? false
        return HStack(alignment: .top, spacing: 9) {
            if result.kind == .task, let id = taskID {
                Button(intent: DayflowSearchCompleteIntent(taskID: id)) {
                    Circle()
                        .strokeBorder(Color.dayflowAccent, lineWidth: 1.5)
                        .background(Circle().fill(done ? Color.dayflowAccent : Color.clear))
                        .frame(width: 17, height: 17)
                        .padding(.top, 2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(done)
            } else {
                Image(systemName: result.kind.icon)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dayflowFaint)
                    .frame(width: 17)
                    .padding(.top, 2)
            }

            let body = VStack(alignment: .leading, spacing: 2) {
                Text(result.title)
                    .font(.system(size: 13, weight: done ? .regular : .semibold))
                    .foregroundStyle(done ? Color.dayflowFaint : Color.dayflowInk)
                    .strikethrough(done)
                    .lineLimit(2)
                Text(done ? "✓ completed just now" : result.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dayflowFaint)
                    .lineLimit(1)
                // **The matched line is most of the value.** A document whose
                // title says nothing about the word is exactly the result worth
                // having, and without the line it is just a filename.
                if let snippet = result.snippet, !done {
                    Text(snippet)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.dayflowMuted)
                        .lineLimit(2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.dayflowPanel))
                        .padding(.top, 2)
                }
            }

            if let url = DayflowSearchDraft.url(for: result), !done {
                Button(intent: DayflowSearchOpenIntent(target: url.absoluteString)) {
                    HStack(alignment: .top, spacing: 6) {
                        body
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.dayflowFaint)
                            .padding(.top, 3)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                body
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.dayflowHairline).frame(height: 0.5)
        }
    }

    /// **Names what it looked in.** "No results" alone leaves him wondering
    /// whether it searched the thing he meant.
    private var empty: some View {
        Text("Nothing matched. Searched notes, documents, tasks, people, places and endeavors.")
            .font(.system(size: 12.5))
            .foregroundStyle(Color.dayflowMuted)
            .padding(.vertical, 10)
    }

    private var again: some View {
        Button(intent: DayflowSearchAgainIntent()) {
            Text("Search again")
                .font(.system(size: 12.5, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.dayflowHairline, lineWidth: 1))
                .foregroundStyle(Color.dayflowMuted)
        }
        .buttonStyle(.plain)
        .padding(.top, 12)
    }
}
