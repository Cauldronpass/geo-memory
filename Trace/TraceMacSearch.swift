// TraceMacSearch.swift
// The literal half of global search: build a corpus, match a query, rank the
// hits. No API, no key, nothing leaves the machine — spec §8 step 1.
// Mac-only — do not add to iOS, Widget, or Share Extension targets.
//
// ── Why this is a file walk and not an index ──────────────────────────────
//
// The container is 107 markdown files and about 7,000 words. `findWikilinkMentions`
// already enumerates the whole of it on every People and Places detail view and
// nobody has ever noticed. An index would be a second copy of the truth that has
// to be kept in sync with a folder four apps write to, and the sync is where the
// bugs would live. Session 69 found three separate versions of that bug in one
// evening (D83, D89, D91), each one a rule that was correct while a single
// program was the only participant.
//
// So: read the disk, every time the panel opens. If that ever stops being fast
// the fix is a cache with an mtime check, not an index.
//
// ── What is deliberately NOT in the corpus ────────────────────────────────
//
//   * `Photos/`            — binaries with no text.
//   * `Documents/`         — the sidecars are read through `TraceMacDocumentStore`
//                            instead, because it owns `sidecarPath`'s
//                            case-insensitivity (D91) and the body parse. A second
//                            reader of that rule is exactly the shape of D91.
//   * `Drafts/`            — scratch. Two files, one of them a `.txt` dump.
//   * anything under a `_to_delete` folder — parked deletions, not records.
//
// ── One deviation from the spec, stated rather than slipped in ────────────
//
// Spec §6 lists the in-scope folders and `Notes/People/` is not among them. That
// reads as an oversight rather than a decision: those notes are David's own
// writing about people — the `## Done` agenda log that `logCompletedAgendaItem`
// appends to — and *"what did I tell Mickey I would do in July"* is the spec's
// own example question, answered out of that folder and nowhere else. It is in.
//
// It does not get its own row, though: see the folding note on `run` below.

import Foundation

// MARK: - Kinds

enum MacSearchKind: String, CaseIterable, Identifiable, Sendable {
    case note, document, person, place, endeavor, task

    var id: String { rawValue }

    /// Plural, because it heads a group.
    var label: String {
        switch self {
        case .note:     return "Notes"
        // The section is called Satchel and the folder is called Documents; the
        // group header follows the section, same call as `MacSection.documents`.
        case .document: return "Satchel"
        case .person:   return "People"
        case .place:    return "Places"
        case .endeavor: return "Endeavors"
        case .task:     return "Tasks"
        }
    }

    var icon: String {
        switch self {
        case .note:     return "book.pages"
        case .document: return "doc.richtext"
        case .person:   return "person"
        case .place:    return "mappin.and.ellipse"
        case .endeavor: return "flag"
        case .task:     return "checklist"
        }
    }
}

// MARK: - Where Return goes

/// What pressing Return on a row does.
///
/// **Every case here is a route that exists today.** There is no `.openNote`
/// that hopes something downstream knows what to do with it: `TraceMacNotesView`
/// splits `deepLinkNotePath` on exactly two folders (Calendar and
/// Notes/Projects) and ignores anything else, so a third folder handed to it
/// would switch the section, land on Daily, and quietly do nothing.
///
/// `.preview` is the honest case and it is not a failure. A place note whose
/// Notion record is gone still has words in it worth reading; the panel expands
/// it in place instead of pretending there is a screen for it. Session 69 spent
/// an evening on two controls that advertised actions they could not perform,
/// and the cleanup note that closed it is one sentence: a dead menu item and a
/// dead drop target are the same defect.
enum MacSearchDestination: Hashable, Sendable {
    /// `Calendar/…` or `Notes/Projects/…`, container-relative. The only two
    /// folders `TraceMacNotesView` can route.
    case dailyOrProjectNote(String)
    /// Bare filename. Rides `pendingHorizonsFile`, which predates the note-path
    /// binding and takes a filename rather than a path.
    case weeklyNote(String)
    /// Bare filename, into the Inbox list.
    case inboxNote(String)
    /// Notion page id.
    case person(String)
    case place(String)
    /// Endeavor slug — the frontmatter `id:`, never the filename.
    case endeavor(String)
    /// A reminder's `calendarItemIdentifier`. The Tasks screen finds which pool
    /// holds it and opens the card there — see `TraceMacTasksView`'s deep link.
    ///
    /// A real route, not a hopeful one. The rule at the top of this enum is that
    /// every case here goes somewhere that exists, and a task id would have been
    /// the easiest place in the file to break it: `.preview` was available and
    /// would have compiled, and a task has almost nothing to preview.
    case task(String)
    /// Container-relative path to the *binary*, not the sidecar.
    case document(String)
    /// No screen shows this record. Expand it in the panel instead.
    case preview
}

/// The id for a deep link that has to wait for a list to load.
///
/// `.task(id:)` takes one value and these links depend on two: the thing asked
/// for, and whether the collection it must be found in has arrived yet. A link
/// that lands before the load finds nothing and clears itself, which is the
/// silent-no-op this whole binding pattern exists to prevent — so the load's
/// count is part of the id and the task runs again when it changes.
///
/// One type, used by every list that takes a search result. Two private copies
/// in two files is the shape of the drift bugs this project keeps finding.
struct MacDeepLinkKey: Equatable {
    let value: String?
    let loaded: Int
}

// MARK: - A result

struct MacSearchResult: Identifiable, Hashable, Sendable {
    let id: String
    let kind: MacSearchKind
    /// The name of the thing. For a note this is the filename minus `.md`,
    /// because in this container the filename *is* the identity — the flag
    /// index, every wikilink and Dayflow's nav title all key on it, and the
    /// `# Heading` line is body text nothing parses.
    let title: String
    /// One line of provenance: which folder, which category, which relationship.
    let subtitle: String
    /// The matching line from the body, already windowed. `nil` when the match
    /// was in the title and the body adds nothing.
    let snippet: String?
    let destination: MacSearchDestination
    /// Container-relative markdown to show in the inline preview, when the row
    /// is expanded. `nil` for records with no note behind them.
    let previewPath: String?
    let score: Int
    /// Tiebreak within a group. Newest first.
    let sortDate: Date?
}

// MARK: - Corpus

/// One markdown file, read once.
struct MacSearchNote: Sendable {
    let relativePath: String
    let title: String
    /// Container-relative folder, e.g. `Notes/Projects` or `Notes/Projects/Archive`.
    let folder: String
    let body: String
    let modified: Date?
    /// Frontmatter `id:` — Endeavor notes only.
    let endeavorID: String?
    /// Frontmatter `name:` — Endeavor notes only. Falls back to the filename.
    let endeavorName: String?
    /// Frontmatter `type:` and `destination:` — Endeavor notes only.
    let endeavorMeta: [String]
}

struct MacSearchCorpus: Sendable {
    var notes: [MacSearchNote] = []
    var builtAt: Date = .distantPast

    /// Folders the walk will read, in the order they are declared. Anything not
    /// under one of these is skipped — an allow list rather than a deny list,
    /// so a new folder appearing in the container cannot silently join the
    /// corpus.
    nonisolated static let roots = ["Calendar", "Notes"]

    /// Synchronous filesystem walk. **Call off the main thread** — same
    /// convention `findWikilinkMentions` and `TagIndex.seedFromNotes` use, and
    /// for the same reason: it opens and reads every markdown file in the
    /// container.
    ///
    /// `nonisolated`, and it has to be. The project sets
    /// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` on every target, so an
    /// unannotated static method is main-actor isolated — which means the
    /// `Task.detached` that calls this would be hopping straight back to the
    /// main actor to do the very work it detached to keep off it. A warning in
    /// Swift 5 and an error in 6, and in both cases the wrong thread. Same note
    /// `NoteStore` carries above `findWikilinkMentions`.
    nonisolated static func build(containerURL: URL) -> MacSearchCorpus {
        var out: [MacSearchNote] = []
        let rootPath = containerURL.path

        for root in roots {
            let dir = containerURL.appendingPathComponent(root)
            guard let walker = FileManager.default.enumerator(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let url as URL in walker {
                guard url.pathExtension.lowercased() == "md" else { continue }

                var relative = url.path
                if relative.hasPrefix(rootPath) {
                    relative = String(relative.dropFirst(rootPath.count))
                    if relative.hasPrefix("/") { relative.removeFirst() }
                }

                // Parked deletions are not records. `Documents/_to_delete/` and
                // `_to_delete/` both exist in the live container right now, put
                // there by Session 69 because the device bridge cannot unlink.
                // Underscore-prefixed *folders* are the convention for that; a
                // file is judged on its folder, never on its own name.
                let dirs = relative.split(separator: "/").dropLast()
                guard !dirs.contains(where: { $0.hasPrefix("_") }) else { continue }

                guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }

                let folder = (relative as NSString).deletingLastPathComponent
                let title = url.deletingPathExtension().lastPathComponent
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate

                let fm = frontmatter(raw)
                out.append(MacSearchNote(
                    relativePath: relative,
                    title: title,
                    folder: folder,
                    body: raw,
                    modified: modified,
                    endeavorID: fm["id"],
                    endeavorName: fm["name"],
                    endeavorMeta: ["type", "destination"].compactMap { fm[$0] }
                ))
            }
        }

        return MacSearchCorpus(notes: out, builtAt: Date())
    }

    /// Scalar frontmatter keys only, and only the handful the Endeavor fold
    /// needs. Not a YAML parser and not trying to be one — `TraceMacEndeavorStore`
    /// owns Endeavor parsing, and this is a search hint, not a second reader of
    /// the record. If it ever needs a list value, that is the moment to call the
    /// store instead of growing this.
    nonisolated private static func frontmatter(_ raw: String) -> [String: String] {
        guard raw.hasPrefix("---") else { return [:] }
        var out: [String: String] = [:]
        var started = false
        for line in raw.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces) == "---" {
                if started { break }
                started = true
                continue
            }
            guard started, let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard !key.isEmpty, !value.isEmpty else { continue }
            out[key] = value
        }
        return out
    }
}

/// One type's worth of results, with its own count.
///
/// A `struct` and not a `(kind:items:)` tuple: `ForEach(_:id:)` needs a
/// `KeyPath`, and Swift has no key paths into tuple elements.
struct MacSearchGroup: Identifiable, Sendable {
    let kind: MacSearchKind
    let items: [MacSearchResult]
    var id: MacSearchKind { kind }
}

// MARK: - Matching

/// Literal, case-insensitive, substring. Every term must appear somewhere.
///
/// **Not fuzzy, deliberately.** Fuzzy matching is the thing that turns a search
/// box into a ranking nobody can explain — spec §2 names that as the failure
/// mode to avoid, and it is the reason Ask is a separate button producing a
/// different kind of thing rather than a better sort of this one. If a query
/// returns nothing here, it is because those letters are not in the container,
/// and that is a fact the user can act on.
enum MacSearchEngine {

    /// Field weights. A term found in a title beats the same term found in a
    /// body, and the gaps are wide enough that no amount of body matches can
    /// outrank one title match.
    private enum Weight {
        static let titlePrefix = 1000
        static let titleWord   = 800
        static let title       = 600
        static let tag         = 500
        static let meta        = 300
        static let body        = 100
        /// The whole query, contiguous, in the title. "megan wedding" should put
        /// `Megan Wedding Text` above a note that says "Megan" at the top and
        /// "wedding" forty lines down.
        static let phrase      = 500
    }

    /// Cap per group before "N more". Five is what fits without scrolling on a
    /// panel this size; the count of what is hidden is always shown, because a
    /// silent truncation reads as "that is everything" when it is not — the same
    /// rule spec §3 sets for the token budget.
    static let groupLimit = 5

    /// Short and human. A search row is scanned, not read, so "Tomorrow" beats
    /// a date nobody has to parse.
    nonisolated static func taskDateLabel(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInTomorrow(day) { return "Tomorrow" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        let f = DateFormatter()
        f.dateFormat = cal.isDate(day, equalTo: Date(), toGranularity: .year)
            ? "EEE d MMM" : "d MMM yyyy"
        return f.string(from: day)
    }

    static func terms(in query: String) -> [String] {
        query.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    // MARK: The run

    /// Records first, notes last — and notes about records do not get their own
    /// row at all.
    ///
    /// **The fold is the important part.** `Notes/People/Bryan Weiss.md` and the
    /// Notion person "Bryan Weiss" are one thing to David and two things to the
    /// filesystem. Emitting both would put two rows a pixel apart under two
    /// different headings, and the one he wants — the record, with the phone
    /// number on it — would be the second. So a person note is searched as the
    /// *body* of its person, and the row that appears is the record.
    ///
    /// Same for places, and Endeavors are the pure case: the note **is** the
    /// record, so it is only ever one row.
    ///
    /// A note in those folders with no matching record is not dropped. It comes
    /// out as a `.preview` note row — see `MacSearchDestination`.
    static func run(query: String,
                    corpus: MacSearchCorpus,
                    documents: [TraceMacDocument],
                    people: [Person],
                    places: [Place],
                    tasks: [ThingsTask] = []) -> [MacSearchResult] {

        // `Self.` is load-bearing: a local named `terms` shadows the static
        // `terms(in:)` from the point of its own declaration, so the unqualified
        // form is the local variable being used inside its own initialiser.
        let terms = Self.terms(in: query)
        guard !terms.isEmpty else { return [] }
        let phrase = query.lowercased().trimmingCharacters(in: .whitespaces)

        // Partition the corpus once.
        var peopleNotes: [String: MacSearchNote] = [:]
        var placeNotes:  [String: MacSearchNote] = [:]
        var endeavorNotes: [MacSearchNote] = []
        var plainNotes: [MacSearchNote] = []

        for note in corpus.notes {
            switch note.folder {
            case "Notes/People":    peopleNotes[note.title.lowercased()] = note
            case "Notes/Places":    placeNotes[note.title.lowercased()]  = note
            case "Notes/Endeavors": endeavorNotes.append(note)
            default:                plainNotes.append(note)
            }
        }

        var out: [MacSearchResult] = []
        var claimedPeopleNotes = Set<String>()
        var claimedPlaceNotes  = Set<String>()

        // ── People ────────────────────────────────────────────────────────
        for person in people {
            let key = person.name.lowercased()
            let note = peopleNotes[key]
            if note != nil { claimedPeopleNotes.insert(key) }
            let body = [note?.body, person.agenda].compactMap { $0 }.joined(separator: "\n")
            guard let hit = match(terms: terms, phrase: phrase,
                                  title: person.name,
                                  tags: [],
                                  meta: [person.relationship, person.relationshipStrength].compactMap { $0 },
                                  body: body) else { continue }
            out.append(MacSearchResult(
                id: "person:\(person.id)",
                kind: .person,
                title: person.name,
                subtitle: [person.relationship, person.isArchived ? "Archived" : nil]
                    .compactMap { $0 }.joined(separator: " · "),
                snippet: hit.snippet,
                destination: .person(person.id),
                previewPath: note?.relativePath,
                score: hit.score,
                sortDate: note?.modified))
        }

        // ── Places ────────────────────────────────────────────────────────
        for place in places {
            let key = place.name.lowercased()
            let note = placeNotes[key]
            if note != nil { claimedPlaceNotes.insert(key) }
            let body = [note?.body, place.notes, place.aiSummary]
                .compactMap { $0 }.joined(separator: "\n")
            guard let hit = match(terms: terms, phrase: phrase,
                                  title: place.name,
                                  tags: place.tags,
                                  meta: [place.city, place.address, place.category],
                                  body: body) else { continue }
            out.append(MacSearchResult(
                id: "place:\(place.id)",
                kind: .place,
                title: place.name,
                subtitle: [place.city, place.category].filter { !$0.isEmpty }
                    .joined(separator: " · "),
                snippet: hit.snippet,
                destination: .place(place.id),
                previewPath: note?.relativePath,
                score: hit.score,
                sortDate: place.lastVisited))
        }

        // ── Tasks ─────────────────────────────────────────────────────────
        //
        // Open tasks only: `allTasks` is the incomplete set, so nothing here
        // resurrects something finished. A completed task IS findable, but in
        // the Logbook, which is the screen that admits it is looking backwards.
        //
        // The body searched is the note's PROSE, not the raw notes field. A
        // task whose note is a `shortcuts://` URL should not match the word
        // "shortcuts", and one whose note is a `[[wikilink]]` should be found by
        // the linked name — which it is, because the person or place row carries
        // that name already. Same test the row's note mark uses, so "this task
        // has a note" and "this task matched on its note" can never disagree.
        for task in tasks {
            guard let hit = match(terms: terms, phrase: phrase,
                                  title: task.title,
                                  tags: [],
                                  meta: [task.list].compactMap { $0 },
                                  body: task.noteProse) else { continue }
            out.append(MacSearchResult(
                id: "task:\(task.id)",
                kind: .task,
                title: task.title,
                // The list, and the date when there is one — the two facts that
                // tell you WHICH "call Bryan" this is.
                subtitle: [task.list, task.date.map(Self.taskDateLabel)]
                    .compactMap { $0 }.joined(separator: " · "),
                snippet: hit.snippet,
                destination: .task(task.id),
                previewPath: nil,
                score: hit.score,
                sortDate: nil))
        }

        // ── Endeavors ─────────────────────────────────────────────────────
        for note in endeavorNotes {
            let name = note.endeavorName ?? note.title
            guard let hit = match(terms: terms, phrase: phrase,
                                  title: name,
                                  tags: [],
                                  meta: note.endeavorMeta,
                                  body: note.body) else { continue }
            out.append(MacSearchResult(
                id: "endeavor:\(note.relativePath)",
                kind: .endeavor,
                title: name,
                subtitle: note.endeavorMeta.joined(separator: " · "),
                snippet: hit.snippet,
                // No `id:` in the frontmatter means nothing can select it in the
                // Endeavors rail, so the row says preview rather than guessing a
                // slug from the name. `TraceMacEndeavorStore` writes the id at
                // creation and never edits it (D9), so this is a repair case,
                // not a normal one.
                destination: note.endeavorID.map { MacSearchDestination.endeavor($0) } ?? .preview,
                previewPath: note.relativePath,
                score: hit.score,
                sortDate: note.modified))
        }

        // ── Documents ─────────────────────────────────────────────────────
        //
        // The `private` tag does NOT hide a document here, and that is the
        // design rather than an oversight. Spec §5b binds Ask, which sends text
        // to an API; this is a string comparison over files already on the disk
        // and nothing leaves the machine. Hiding a private document from local
        // search would make it unfindable in the one place it is safe to find.
        for doc in documents {
            guard doc.category != "_to_delete" else { continue }
            guard let hit = match(terms: terms, phrase: phrase,
                                  title: doc.title,
                                  tags: doc.tags,
                                  meta: [doc.filename, doc.linkedNote, doc.endeavorName]
                                      .compactMap { $0 },
                                  // `extractedText` is spec §8 step 2: the
                                  // words read off the file itself. It is what
                                  // makes a phrase inside a PDF findable at
                                  // all, which the spec calls the larger of
                                  // the two wins.
                                  body: [doc.description, doc.note, doc.summary,
                                         doc.extractedText]
                                      .joined(separator: "\n")) else { continue }
            out.append(MacSearchResult(
                id: "document:\(doc.relativePath)",
                kind: .document,
                title: doc.title,
                subtitle: [doc.fileExtension.uppercased(),
                           doc.tags.prefix(3).joined(separator: ", ")]
                    .filter { !$0.isEmpty }.joined(separator: " · "),
                snippet: hit.snippet,
                destination: .document(doc.relativePath),
                previewPath: nil,
                score: hit.score,
                sortDate: doc.created))
        }

        // ── Notes ─────────────────────────────────────────────────────────
        let orphans = Array(peopleNotes.filter { !claimedPeopleNotes.contains($0.key) }.values)
                    + Array(placeNotes.filter  { !claimedPlaceNotes.contains($0.key)  }.values)
        for note in plainNotes + orphans {
            guard let hit = match(terms: terms, phrase: phrase,
                                  title: note.title,
                                  tags: [],
                                  meta: [note.folder],
                                  body: note.body) else { continue }
            out.append(MacSearchResult(
                id: "note:\(note.relativePath)",
                kind: .note,
                title: note.title,
                subtitle: subtitle(for: note),
                snippet: hit.snippet,
                destination: destination(for: note),
                previewPath: note.relativePath,
                score: hit.score,
                sortDate: note.modified))
        }

        return out
    }

    // MARK: Grouping

    /// Groups in best-score order, not in a fixed order.
    ///
    /// David's own framing of the prize is *"hitting a shortcut key… and asking
    /// for Megan's number"*. A fixed Notes-first order would put twelve daily
    /// notes that mention Megan above the record that has the number on it, and
    /// the keystroke would be worth less than the app it was meant to replace.
    /// Typing a name puts the thing with that name at the top; that is the only
    /// ordering rule a person has to hold in their head.
    static func grouped(_ results: [MacSearchResult]) -> [MacSearchGroup] {
        Dictionary(grouping: results, by: \.kind)
            .map { MacSearchGroup(kind: $0.key, items: $0.value.sorted(by: rank)) }
            .sorted { a, b in
                let sa = a.items.first?.score ?? 0
                let sb = b.items.first?.score ?? 0
                if sa != sb { return sa > sb }
                // Stable tiebreak, so two groups that tie do not swap places
                // between keystrokes.
                return a.kind.rawValue < b.kind.rawValue
            }
    }

    /// `nonisolated` because it is handed to `sorted(by:)` as a plain closure.
    ///
    /// The project sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so without
    /// the annotation this is a main-actor method being passed where a
    /// non-isolated comparator is expected — a warning in Swift 5 and an error
    /// in 6. It was there on the Mac too and nobody had looked at the warning
    /// list closely enough to see it; moving the file into three more targets
    /// printed it three more times, which is how it surfaced. Pure comparison
    /// over `Sendable` values, so there is nothing to isolate.
    nonisolated private static func rank(_ a: MacSearchResult, _ b: MacSearchResult) -> Bool {
        if a.score != b.score { return a.score > b.score }
        let da = a.sortDate ?? .distantPast
        let db = b.sortDate ?? .distantPast
        if da != db { return da > db }
        return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
    }

    // MARK: Scoring

    private struct Hit { let score: Int; let snippet: String? }

    /// Returns `nil` unless **every** term appears in at least one field.
    private static func match(terms: [String],
                              phrase: String,
                              title: String,
                              tags: [String],
                              meta: [String],
                              body: String) -> Hit? {
        let lowerTitle = title.lowercased()
        let lowerTags  = tags.map { $0.lowercased() }
        let lowerMeta  = meta.joined(separator: " ").lowercased()
        let lowerBody  = body.lowercased()

        var total = 0
        var matchedInBody = false

        for term in terms {
            var best = 0
            if lowerTitle.hasPrefix(term) {
                best = Weight.titlePrefix
            } else if titleHasWord(lowerTitle, term) {
                best = Weight.titleWord
            } else if lowerTitle.contains(term) {
                best = Weight.title
            }
            if best < Weight.tag, lowerTags.contains(where: { $0 == term || $0.contains(term) }) {
                best = max(best, Weight.tag)
            }
            if best < Weight.meta, lowerMeta.contains(term) {
                best = max(best, Weight.meta)
            }
            if lowerBody.contains(term) {
                matchedInBody = true
                best = max(best, Weight.body)
            }
            guard best > 0 else { return nil }
            total += best
        }

        if terms.count > 1, lowerTitle.contains(phrase) { total += Weight.phrase }

        // A snippet is offered only when the body is where the match was. A
        // title-only hit with a line of unrelated prose under it looks like
        // evidence and is not.
        let snippet = matchedInBody ? line(in: body, matching: terms) : nil
        return Hit(score: total, snippet: snippet)
    }

    /// True when `term` starts a word in `title`. Cheap, and it is what makes
    /// "wedding" rank `Megan Wedding Text` above `Latest Megan Wedding Speech`
    /// only by way of the other rules — this one just separates a word start
    /// from a letter sequence buried mid-word.
    private static func titleHasWord(_ lowerTitle: String, _ term: String) -> Bool {
        var index = lowerTitle.startIndex
        while let found = lowerTitle.range(of: term, range: index..<lowerTitle.endIndex) {
            if found.lowerBound == lowerTitle.startIndex {
                return true
            }
            let before = lowerTitle[lowerTitle.index(before: found.lowerBound)]
            if !before.isLetter && !before.isNumber { return true }
            index = found.upperBound
            if index >= lowerTitle.endIndex { break }
        }
        return false
    }

    /// The first body line containing any term, windowed to something that fits
    /// on one row. Frontmatter is skipped: `tags: [private]` is a true match and
    /// a useless quotation.
    private static func line(in body: String, matching terms: [String]) -> String? {
        var inFrontmatter = body.hasPrefix("---")
        var isFirst = true
        for raw in body.components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if inFrontmatter {
                if trimmed == "---" && !isFirst { inFrontmatter = false }
                isFirst = false
                continue
            }
            isFirst = false
            guard !trimmed.isEmpty else { continue }
            // Case-insensitive search against `trimmed` itself, NOT against a
            // lowercased copy. `lowercased()` is not length-preserving in every
            // locale, so an index taken from the copy and used on the original
            // is a crash that waits for one accented character — and this
            // container has `Megan’s Wedding Week` in it already.
            guard let first = terms.compactMap({ trimmed.range(of: $0, options: .caseInsensitive) })
                .min(by: { $0.lowerBound < $1.lowerBound }) else { continue }
            return window(trimmed, around: first.lowerBound)
        }
        return nil
    }

    private static func window(_ line: String, around index: String.Index, width: Int = 150) -> String {
        guard line.count > width else { return line }
        let offset = line.distance(from: line.startIndex, to: index)
        let lead = max(0, offset - 40)
        let start = line.index(line.startIndex, offsetBy: lead)
        let end = line.index(start, offsetBy: width, limitedBy: line.endIndex) ?? line.endIndex
        var out = String(line[start..<end])
        if lead > 0 { out = "…" + out }
        if end < line.endIndex { out += "…" }
        return out
    }

    // MARK: Note labelling and routing

    private static func subtitle(for note: MacSearchNote) -> String {
        switch note.folder {
        case "Calendar":
            // The filename is the identity and stays the title; the friendly
            // date goes here, where it costs nothing.
            return ["Daily", longDate(note.title)].compactMap { $0 }.joined(separator: " · ")
        case NoteStore.projectsFolder:          return "Project"
        case NoteStore.archivedProjectsFolder:  return "Project · Archived"
        case "Notes/Horizons":                  return "Weekly"
        case "Notes/Inbox":                     return "Inbox"
        case "Notes/People":                    return "Person note · no record"
        case "Notes/Places":                    return "Place note · no record"
        default:                                return note.folder
        }
    }

    /// Internal rather than private: `MacAskService` resolves a citation to the
    /// same screen a search result opens. Two routing tables for one set of
    /// folders is the drift this project keeps paying for.
    static func destination(for note: MacSearchNote) -> MacSearchDestination {
        switch note.folder {
        case "Calendar", NoteStore.projectsFolder:
            return .dailyOrProjectNote(note.relativePath)
        case "Notes/Horizons":
            return .weeklyNote((note.relativePath as NSString).lastPathComponent)
        case "Notes/Inbox":
            return .inboxNote((note.relativePath as NSString).lastPathComponent)
        default:
            // Archived projects included. `TraceMacNotesView` would accept the
            // path — `Notes/Projects/Archive/x.md` passes its `hasPrefix` test —
            // and then hand `x.md` to a Projects list that does not contain it,
            // which is a row that navigates somewhere and does nothing. Preview
            // is the truthful answer until the Archive list takes a deep link.
            return .preview
        }
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let longFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE d MMMM yyyy"
        return f
    }()

    private static func longDate(_ filename: String) -> String? {
        guard let date = dayFormatter.date(from: filename) else { return nil }
        return longFormatter.string(from: date)
    }
}
