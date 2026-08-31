// MacPlaceLink.swift
// Ties a meeting's WHERE text to a record in Places. Mac-only.
//
// Session 80 (2026-08-31). David: "it could have a button that i would press
// whenever a Where is filled in. when we press it it would look up the places in
// the database and google places just like discover does and then i can choose.
// once chosen, it would add the place to my list of places if it was not already
// there and then make the address clickable as well as the place itself."
//
// ── Why his design beat the one it replaced ─────────────────────────────
//
// The backlog carried this as two halves: automatically LINK a location that
// already matched a place, and separately ADD one that did not. The second half
// was the expensive one, and every part of its cost came from the app guessing
// — a wrong automatic match claims a meeting is somewhere it is not, and a
// one-click geocode files a meeting room in the wrong city.
//
// **A picker removes the guessing, and with it the cost.** He chooses from what
// is already in Places and from what Google returns, so there is nothing to get
// wrong silently. The two halves collapse into one flow that is simpler than
// either was.
//
// ── Keyed by the WHERE text, not by the event ───────────────────────────
//
// An `EKEvent` is not ours to write to, so the association lives here. The key
// could have been the event identifier; the location STRING is better, and not
// only because it avoids a per-occurrence row.
//
// A calendar carries the same WHERE over and over: every instance of a
// recurring meeting, every future one not yet created, and every unrelated
// meeting that happens to be in the same building. **Matching once teaches all
// of them.** Keying by event would mean answering the same question every
// Tuesday.
//
// Normalised on the way in — trimmed, case-folded, whitespace collapsed — so
// "Wrigley Field " and "wrigley field" are one key rather than two.
//
// ── Local, and for weaker reasons than MacTaskOrder ─────────────────────
//
// `UserDefaults`, this Mac only. Unlike the task order (D221) there is no
// principled argument that this SHOULD be local — a link is a durable fact, not
// a fact about a morning, and the phone would benefit from it.
//
// It is local because the meeting card is Mac-only today, so there is nothing
// on iOS to share it with yet. When Dayflow grows the same row, this is a
// candidate for the app group or iCloud rather than a thing to duplicate. The
// seam is the same shape as `MacTaskOrder`'s: two functions, one key format.

import Foundation

enum MacPlaceLink {

    private static let prefix = "tracemac.placeLink."

    /// Trimmed, case-folded, inner whitespace collapsed.
    ///
    /// Collapsing runs of spaces matters more than it looks: calendar invitations
    /// routinely carry a location pasted from somewhere with a double space or a
    /// stray tab, and two keys for one place would make the link work on Tuesday
    /// and not on Thursday.
    static func normalise(_ location: String) -> String {
        location
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func key(_ location: String) -> String {
        prefix + normalise(location)
    }

    // MARK: - Reading

    /// The Notion page id this WHERE text points at, if it has been matched.
    static func placeID(for location: String) -> String? {
        let name = normalise(location)
        guard !name.isEmpty else { return nil }
        return UserDefaults.standard.string(forKey: prefix + name)
    }

    /// The `Place` itself, or nil if it was never matched — or was matched and
    /// has since been deleted in Notion.
    ///
    /// **Resolving through the live list rather than trusting the stored id** is
    /// what stops a deleted place from leaving a link that goes nowhere. The
    /// stored id is a pointer, never a copy of the record.
    static func place(for location: String, in places: [Place]) -> Place? {
        guard let id = placeID(for: location) else { return nil }
        return places.first { $0.id == id }
    }

    // MARK: - Writing

    static func link(_ location: String, to placeID: String) {
        let name = normalise(location)
        guard !name.isEmpty else { return }
        UserDefaults.standard.set(placeID, forKey: prefix + name)
    }

    static func unlink(_ location: String) {
        UserDefaults.standard.removeObject(forKey: key(location))
    }

    // MARK: - Suggesting

    /// Places already in the database that look like this location.
    ///
    /// Deliberately generous, because **this list is a suggestion and not a
    /// decision** — he picks from it, so a false positive costs a glance while a
    /// false negative costs a search. That is the opposite of the automatic
    /// matcher this replaced, where a wrong answer was silent and stuck.
    ///
    /// Name containment either way ("Wrigley" finds "Wrigley Field", and a
    /// location of "Wrigley Field, Chicago" finds the place called "Wrigley
    /// Field"), then address, then city. Ranked by how early the match sits,
    /// which puts a leading match above an incidental one.
    static func suggestions(for location: String, in places: [Place]) -> [Place] {
        let needle = normalise(location)
        guard needle.count >= 3 else { return [] }

        func score(_ place: Place) -> Int? {
            let name = normalise(place.name)
            if name == needle { return 0 }
            if name.contains(needle) || needle.contains(name) { return 1 }
            let address = normalise(place.address)
            if !address.isEmpty,
               address.contains(needle) || needle.contains(address) { return 2 }
            // City alone is the weakest signal and is checked one way only:
            // a location that mentions "Chicago" may be in Chicago, but a place
            // whose city is Chicago tells us nothing about this meeting.
            let city = normalise(place.city)
            if !city.isEmpty, city.count >= 4, needle.contains(city) { return 3 }
            return nil
        }

        return places
            .compactMap { place in score(place).map { (place, $0) } }
            .sorted { $0.1 < $1.1 }
            .prefix(6)
            .map(\.0)
    }
}
