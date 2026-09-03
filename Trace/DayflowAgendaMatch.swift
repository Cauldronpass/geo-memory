// DayflowAgendaMatch.swift
// The meeting → person/place/note matcher, shared by every surface that grows
// an AGENDA line.
//
// Extracted from Dayflow/DayflowTodaySection.swift in Session 82 (D244).
// Lives in Trace/ with membershipExceptions for Dayflow and TraceMac, because
// the Mac's Today and Upcoming are about to grow the same line and a second
// copy of this logic is exactly what the original extraction note warned
// against.
//
// NOTE ON MEMBERSHIP: Trace/ is native to the **Trace** target, so the Trace
// app compiles this file too. That is harmless — every type it touches
// (NotionService, NoteStore/NoteMention, ReminderTaskStore, ThingsTask,
// Models) already lives in Trace/ and is therefore already in that target.
// Trace still shows no tasks UI; that is a design decision, and it was never
// enforced by file membership (Session 82 correction to D224).
//
// ── Agenda matching (Session 78, D171/D172/D173) ────────────────────────
//
// ONE matcher for every surface that grows an AGENDA line (Today and, since
// D173, Upcoming) — extracted so the two can never drift. Draw-time, in
// memory, never written anywhere. People: full multi-word name first, then a
// bare first name only while unique. Places: every word of the name present,
// unambiguous. Person wins over place.

import Foundation

enum DayflowAgendaMatch {

    /// Filesystem-safe stem for "Notes/Projects/<title>.md".
    ///
    /// Moved here from `DayflowMeetingActions` in Session 82 (D244). It was
    /// the one thing keeping this matcher inside the iOS file: that enum also
    /// carries `DayflowQuickFindRouter` routing, which no other target has.
    /// The stem is a fact about a FILENAME, not about routing, so this is
    /// where it belonged anyway.
    static func noteStem(_ title: String) -> String {
        title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: " -")
            .trimmingCharacters(in: .whitespaces)
    }

    static func titleWords(_ title: String) -> Set<String> {
        Set(title.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
    }

    /// The person whose calendar this is, so their own name can be ignored in a
    /// meeting title. Comma-separated; usually one word.
    ///
    /// **Why this exists.** David, looking at a Tuesday: four of eleven meetings
    /// were "<him> and one other person" — `David <> Kosta Catch up`,
    /// `Catch up - David <> Sarah`, `Mickey <> David Catch up`,
    /// `David / Martin | Weekly 1:1`. Every one of them matched NOBODY, because
    /// the bare-first-name rule requires exactly one candidate and each title
    /// carries two. The rule is right; it was just counting a person who is
    /// present in every meeting he attends.
    ///
    /// Removing his own name first turns all four into a single candidate. It is
    /// not a special case for the `<>` shape — it works on any separator,
    /// which is what he asked for ("`<>` or some equivalent").
    ///
    /// Stored in iCloud KVS on D241's rail so the phone inherits whatever the
    /// Mac sets, with `UserDefaults` as a local fallback for a target that has
    /// no KVS entitlement. Empty means the old behaviour exactly.
    static var ownerNames: String {
        get {
            let kv = NSUbiquitousKeyValueStore.default.string(forKey: ownerKey)
            if let kv, !kv.isEmpty { return kv }
            return UserDefaults.standard.string(forKey: ownerKey) ?? seededOwnerName
        }
        set {
            NSUbiquitousKeyValueStore.default.set(newValue, forKey: ownerKey)
            NSUbiquitousKeyValueStore.default.synchronize()
            UserDefaults.standard.set(newValue, forKey: ownerKey)
        }
    }

    private static let ownerKey = "trace.owner.names"

    /// A first guess, so this works before anybody visits Settings.
    ///
    /// macOS knows the account's full name; iOS does not, and does not need to —
    /// once the Mac has written a real value it rides KVS to the phone. A guess
    /// is safe here in a way it would not be elsewhere: the worst case is that
    /// one word stops being counted as a candidate, and if that word is not in
    /// People it was never a candidate anyway.
    private static var seededOwnerName: String {
        #if os(macOS)
        return NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
        #else
        return ""
        #endif
    }

    private static var ownerWords: Set<String> {
        Set(ownerNames.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
    }

    static func name(forTitle title: String) -> String? {
        let all = titleWords(title)
        guard !all.isEmpty else { return nil }
        // The owner is dropped BEFORE counting candidates, not after matching.
        // Doing it after would still see two people and still refuse.
        let stripped = all.subtracting(ownerWords)
        // A title that is nothing but your own name has no other subject; fall
        // back rather than inventing one, so nothing that matched before stops.
        let words = stripped.isEmpty ? all : stripped
        let people = NotionService.shared.people.filter { !$0.isArchived }
        if let full = people.first(where: { person in
            let nameWords = person.name.lowercased()
                .split(whereSeparator: { !$0.isLetter }).map(String.init)
            return nameWords.count > 1 && Set(nameWords).isSubset(of: words)
        }) { return full.name }
        let firstMatches = people.filter { person in
            guard let first = person.name.lowercased()
                .split(whereSeparator: { !$0.isLetter }).first else { return false }
            return words.contains(String(first))
        }
        if firstMatches.count == 1 { return firstMatches[0].name }
        guard firstMatches.isEmpty else { return nil }
        let placeMatches = NotionService.shared.places.filter { place in
            let nameWords = place.name.lowercased()
                .split(whereSeparator: { !$0.isLetter }).map(String.init)
            return !nameWords.isEmpty && Set(nameWords).isSubset(of: words)
        }
        return placeMatches.count == 1 ? placeMatches[0].name : nil
    }

    static func tasks(linkedTo name: String) -> [ThingsTask] {
        ReminderTaskStore.shared.allTasks.filter {
            ($0.notes ?? "").contains("[[\(name)]]")
        }
    }

    /// The agenda anchor for ANY meeting: the matched person/place, else the
    /// meeting's own title (D175 round two — "Brewers @Cubs" matches nobody,
    /// but a ticket task linked [[Brewers @Cubs]] still belongs under it).
    static func agendaAnchor(forTitle title: String) -> String {
        name(forTitle: title) ?? title.trimmingCharacters(in: .whitespaces)
    }

    /// The meeting's own running note ("Notes/Projects/<stem>.md"), when the
    /// file exists. Found by PATH, not wikilink — an unmatched meeting's note
    /// carries no [[anchor]] mention of itself ("Sarah <> David Catch up"
    /// matches nobody when Sarah and David are both people, two candidates =
    /// no match), so the wikilink scan alone left it off the agenda entirely.
    /// David, Session 78: "I added a project note for Sarah and it never made
    /// it to the agenda."
    static func meetingNotePath(forTitle title: String) -> String? {
        let stem = noteStem(title)
        guard !stem.isEmpty, let root = NoteStore.shared.containerURL else { return nil }
        let path = "Notes/Projects/\(stem).md"
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)
        else { return nil }
        return path
    }

    /// The note rows an expanded agenda shows: the meeting's own running note
    /// first (by path, per meetingNotePath above), then the cached wikilink
    /// mentions, deduped against it. Draw-time, so a note created seconds ago
    /// by the left swipe shows without invalidating the once-per-open
    /// mention cache.
    static func displayNotes(cached: [NoteMention]?, forTitle title: String) -> [NoteMention] {
        var out = cached ?? []
        if let path = meetingNotePath(forTitle: title) {
            out.removeAll { $0.relativePath == path }
            out.insert(NoteMention(relativePath: path,
                                   title: title.trimmingCharacters(in: .whitespaces),
                                   modified: nil), at: 0)
        }
        return out
    }

    // MARK: - The meeting's running note (D175, one writer as of D250)

    /// Create — or add today's heading to — the meeting's running note, and give
    /// back its path.
    ///
    /// **One writer for both platforms.** This was `DayflowMeetingActions`'
    /// private business until the Mac grew a Running-note pill and would have
    /// needed a second copy. A note format with two authors is the drift this
    /// project has paid for repeatedly; the difference between the platforms is
    /// only where they route afterwards, so only the routing stayed behind.
    ///
    /// **The bug it was carrying.** The original read
    /// `if let existing = try? NoteStore.shared.readFile(path)`, and `readFile`
    /// returns "" for a missing file rather than throwing — so `existing` was
    /// never nil, the create branch was unreachable, and every meeting note ever
    /// made by the iOS swipe was born WITHOUT its `# Title` line and without the
    /// `[[person]]` link that branch adds. Same mistake, same evening, as the
    /// + button's project note (D249). It is fixed here by asking
    /// `fileExists` — the question, by name.
    ///
    /// One occurrence per heading: a meeting you open twice in a day does not
    /// get two identical dated headings.
    @discardableResult
    static func ensureMeetingNote(title: String, occurring startDate: Date) -> String? {
        let stem = noteStem(title)
        guard !stem.isEmpty else { return nil }
        let path = "\(NoteStore.projectsFolder)/\(stem).md"
        let store = NoteStore.shared
        let f = DateFormatter(); f.dateFormat = "EEE, MMM d yyyy"
        let heading = "## \(f.string(from: startDate))"

        if store.fileExists(path) {
            let existing = (try? store.readFile(path)) ?? ""
            guard !existing.contains(heading) else { return path }
            let grown = existing.hasSuffix("\n")
                ? existing + "\n\(heading)\n\n"
                : existing + "\n\n\(heading)\n\n"
            do { try store.writeFile(path, content: grown) } catch { return nil }
            return path
        }

        var body = "# \(title.trimmingCharacters(in: .whitespaces))\n"
        // The wikilink is what puts this note in the person's own Mentioned In
        // list and in every backlink view, for free. It has never actually been
        // written until now.
        if let matched = name(forTitle: title) { body += "\n[[\(matched)]]\n" }
        body += "\n\(heading)\n\n"
        do { try store.writeFile(path, content: body) } catch { return nil }
        return path
    }
}
