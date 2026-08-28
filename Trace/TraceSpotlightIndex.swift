// TraceSpotlightIndex.swift — donates the search corpus to the system index.
//
// 2026-08-25. David: *"lets do trace door first then spotlight."*
//
// One idea: **the Spotlight index is the search corpus, nothing more and nothing
// less.** The same four inputs `MacSearchEngine.run` takes — the note walk, the
// Satchel documents, People and Places from Notion — become `CSSearchableItem`s,
// and a tapped result comes back as the same `MacSearchDestination` a search row
// would have produced. So the home-screen pull-down (and, on the Mac, Command-
// Space) finds what the in-app search finds, and opens it through the host's
// existing `openSearchDestination`. No second corpus, no second routing table.
//
// **What is deliberately not donated:**
//
// - A document tagged `private`. David's call, 2026-08-25, after the trade was
//   laid out: the in-app search *does* show private documents, on the argument
//   that nothing leaves the disk, and the Spotlight index is also on the disk —
//   but it surfaces a snippet on the home screen before Trace is open, and iOS
//   27's Siri reads this same index and can hand it to Private Cloud Compute.
//   `private` was created to mean "do not send this anywhere," so it means
//   "not in the system index" too. *"If it becomes an irritation then i can
//   redo it to include."* That is one `guard` below.
// - Anything the host cannot open. `canOpen` is the same predicate the search
//   screen asks before a row is tappable, so a Spotlight result never lands the
//   user in the app with nothing on screen. On the phone that excludes Inbox
//   and weekly notes; on the Mac it excludes nothing but archived projects.
// - `_to_delete` documents, as search already skips them.
//
// **Full text is indexed, on purpose.** `textContent` carries the note body or
// the document's OCR text, so a receipt is findable by what is printed on it,
// which is the whole reason to do this. The index is per device and never
// syncs; each Mac and each phone builds its own from its own copy of the
// container.
//
// `import Foundation` and `CoreSpotlight` only. Compiles into the Trace target
// by folder membership and into TraceMac via `membershipExceptions`, like the
// two engine files beside it.

import Foundation
import CoreSpotlight
import UniformTypeIdentifiers

enum TraceSpotlightIndex {

    // MARK: - Identifiers

    /// One domain per kind, so a future partial reindex (or a "forget
    /// documents" button) can address a kind without touching the rest.
    private static let domainPrefix = "com.david.Trace"

    private static func domain(_ kind: String) -> String { "\(domainPrefix).\(kind)" }

    /// The destination, written as a string the system will hand back on tap.
    /// The raw values are the ones search rows already use for `id`, so the two
    /// namespaces agree by construction. `nil` for `.preview`, which has
    /// nowhere to go.
    nonisolated static func identifier(for destination: MacSearchDestination) -> String? {
        switch destination {
        case .dailyOrProjectNote(let path): return "note:\(path)"
        case .weeklyNote(let file):         return "weekly:\(file)"
        case .inboxNote(let file):          return "inbox:\(file)"
        case .person(let id):               return "person:\(id)"
        case .place(let id):                return "place:\(id)"
        case .endeavor(let id):             return "endeavor:\(id)"
        case .document(let path):           return "document:\(path)"
        case .preview:                      return nil
        }
    }

    /// The inverse. An identifier from an older build that no longer parses
    /// returns `nil` and the host does nothing, rather than guessing.
    nonisolated static func destination(for identifier: String) -> MacSearchDestination? {
        guard let colon = identifier.firstIndex(of: ":") else { return nil }
        let kind = String(identifier[..<colon])
        let value = String(identifier[identifier.index(after: colon)...])
        guard !value.isEmpty else { return nil }
        switch kind {
        case "note":     return .dailyOrProjectNote(value)
        case "weekly":   return .weeklyNote(value)
        case "inbox":    return .inboxNote(value)
        case "person":   return .person(value)
        case "place":    return .place(value)
        case "endeavor": return .endeavor(value)
        case "document": return .document(value)
        default:         return nil
        }
    }

    // MARK: - Building

    /// The words of a string, for `keywords`. iOS Spotlight weights `title` and
    /// `keywords` and does not search `contentDescription` at all — verified
    /// on device 2026-08-25: "tomato" found Wild Tomato, "wild" and "sister
    /// bay" did not, while the Mac found all three. So every word a person
    /// might type goes into `keywords` explicitly: the title's own tokens
    /// (iOS does not reliably match a mid-title word), the subtitle's, and
    /// the kind's own facets. Single characters are dropped; two-letter words
    /// stay — "CD One Price Cleaners" lost its "CD" to a >2 rule on the first
    /// TestFlight round and was unfindable by its own name (2026-08-25).
    nonisolated static func tokens(_ strings: [String?]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for string in strings.compactMap({ $0 }) {
            for raw in string.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
                let word = String(raw)
                guard word.count > 1 else { continue }
                let key = word.lowercased()
                if seen.insert(key).inserted { out.append(word) }
            }
        }
        return out
    }

    /// Everything the host can open, as searchable items. Cheap: a few hundred
    /// strings, no disk. The walk that touches disk is `MacSearchCorpus.build`,
    /// which the caller has already done.
    static func items(corpus: MacSearchCorpus,
                      documents: [TraceMacDocument],
                      people: [Person],
                      places: [Place],
                      canOpen: (MacSearchDestination) -> Bool) -> [CSSearchableItem] {
        var out: [CSSearchableItem] = []

        // The same partition `MacSearchEngine.run` makes, so a person's note
        // body rides on the Person item rather than appearing twice.
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

        func add(_ destination: MacSearchDestination,
                 kind: String,
                 title: String,
                 subtitle: String,
                 body: String,
                 keywords: [String] = [],
                 date: Date? = nil,
                 configure: ((CSSearchableItemAttributeSet) -> Void)? = nil) {
            guard canOpen(destination),
                  let id = identifier(for: destination) else { return }
            let attrs = CSSearchableItemAttributeSet(contentType: .text)
            attrs.title = title
            attrs.contentDescription = subtitle.isEmpty
                ? String(body.prefix(200))
                : subtitle
            attrs.textContent = body
            // Title and subtitle tokens first, then the caller's facets, so the
            // phrase a person remembers ("sister bay") matches word by word.
            attrs.keywords = tokens([title, subtitle] + keywords)
            attrs.contentModificationDate = date
            configure?(attrs)
            let item = CSSearchableItem(uniqueIdentifier: id,
                                        domainIdentifier: domain(kind),
                                        attributeSet: attrs)
            out.append(item)
        }

        for person in people {
            let note = peopleNotes[person.name.lowercased()]
            add(.person(person.id), kind: "person",
                title: person.name,
                subtitle: person.relationship ?? "",
                body: [note?.body, person.agenda].compactMap { $0 }.joined(separator: "\n"),
                keywords: [person.relationship ?? ""],
                date: note?.modified)
        }

        for place in places {
            let note = placeNotes[place.name.lowercased()]
            add(.place(place.id), kind: "place",
                title: place.name,
                subtitle: [place.city, place.category].filter { !$0.isEmpty }
                    .joined(separator: " · "),
                body: [place.address, note?.body, place.aiSummary].compactMap { $0 }
                    .joined(separator: "\n"),
                keywords: place.tags + [place.category],
                date: place.lastVisited ?? note?.modified) { attrs in
                    attrs.city = place.city
                    if place.latitude != 0 || place.longitude != 0 {
                        attrs.latitude  = NSNumber(value: place.latitude)
                        attrs.longitude = NSNumber(value: place.longitude)
                    }
                }
        }

        for note in endeavorNotes {
            guard let id = note.endeavorID else { continue }
            add(.endeavor(id), kind: "endeavor",
                title: note.endeavorName ?? note.title,
                subtitle: note.endeavorMeta.joined(separator: " · "),
                body: note.body,
                keywords: note.endeavorMeta,
                date: note.modified)
        }

        for note in plainNotes {
            add(MacSearchEngine.destination(for: note), kind: "note",
                title: note.title,
                subtitle: note.folder,
                body: note.body,
                date: note.modified)
        }

        for doc in documents {
            guard doc.category != "_to_delete" else { continue }
            // The one rule that differs from in-app search. See the header.
            guard !doc.isPrivate else { continue }
            add(.document(doc.relativePath), kind: "document",
                title: doc.title,
                subtitle: [doc.fileExtension.uppercased(),
                           doc.tags.prefix(3).joined(separator: ", ")]
                    .filter { !$0.isEmpty }.joined(separator: " · "),
                body: [doc.description, doc.note, doc.summary, doc.extractedText]
                    .filter { !$0.isEmpty }.joined(separator: "\n"),
                keywords: doc.tags + doc.people
                    + [doc.filename, doc.linkedNote ?? "", doc.endeavorName ?? ""],
                date: doc.created)
        }

        return out
    }

    // MARK: - Writing

    /// Replace the whole index with `items`. Whole, not incremental: the corpus
    /// is a few hundred records and a full rewrite is under a second, whereas an
    /// incremental index has to answer "what was deleted since last time" and
    /// that question is exactly the kind of cache-assumption this project has
    /// paid for four times (D83, D89, D91, D103).
    ///
    /// Silent on failure by design at the call sites — a Spotlight write that
    /// fails leaves search inside the app untouched — but the error is returned
    /// so a host that wants to log it can.
    @discardableResult
    static func replaceAll(with items: [CSSearchableItem]) async -> Error? {
        guard CSSearchableIndex.isIndexingAvailable() else { return nil }
        let index = CSSearchableIndex.default()
        do {
            try await index.deleteAllSearchableItems()
            try await index.indexSearchableItems(items)
            return nil
        } catch {
            return error
        }
    }

    /// Everything a host needs to go from loaded data to a written index.
    static func reindex(corpus: MacSearchCorpus,
                        documents: [TraceMacDocument],
                        people: [Person],
                        places: [Place],
                        canOpen: (MacSearchDestination) -> Bool) async {
        let built = items(corpus: corpus, documents: documents,
                          people: people, places: places, canOpen: canOpen)
        // Never replace a full index with an empty one. An empty build means
        // nothing has loaded yet, not that nothing exists; the next arrival
        // re-fires the caller and writes the real thing.
        guard !built.isEmpty else {
            print("[Spotlight] nothing loaded yet, index left as it was")
            return
        }
        if let error = await replaceAll(with: built) {
            print("[Spotlight] reindex failed: \(error.localizedDescription)")
        } else {
            print("[Spotlight] indexed \(built.count) records")
        }
    }
}
