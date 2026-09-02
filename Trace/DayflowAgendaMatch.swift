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

    static func name(forTitle title: String) -> String? {
        let words = titleWords(title)
        guard !words.isEmpty else { return nil }
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
}
