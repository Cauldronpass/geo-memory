// DayflowWikiLink.swift
// Dayflow
//
// **One answer to "what does this `[[name]]` mean", for the whole phone**
// (Session 88, D282).
//
// There were four copies of `resolveWikiLink` and they disagreed with each
// other. The endeavor screen matched case-insensitively, resolved places,
// people and notes, and said WHY when nothing matched. The project note and
// the daily note matched case-sensitively, resolved places and people, and had
// an empty `else` - a tapped name that matched nothing did nothing at all. The
// wiki summary sheet did less still. None of the four knew an endeavor exists,
// so `[[Test Trip 2]]` produced "Nothing named Test Trip 2 exists as a place,
// a person or a note yet" about a record the app was displaying at the time.
//
// So `[[lakemore resort]]` opened the place on one screen and did nothing on
// another, a note link opened on one screen only, and the bug David reported
// as *"the destination pills are not clickable"* was fixed in Session 71 on one
// screen and left standing on three. **One verb, four behaviours, decided by
// which screen you were on** - standing warning FIVE, and the reason this file
// exists rather than a fifth copy.
//
// The split: `resolve` decides WHAT a name is and `follow` decides what to DO,
// with the hosts supplying only what genuinely differs between them - a daily
// note peek exists on two screens and not on the other two, and the endeavor
// screen pushes a project note onto its own stack instead of routing away.
// Everything else is identical everywhere by construction.

import SwiftUI

/// Why a name opened nothing.
///
/// **Three cases, not one** (warning TWELVE, and D94's rule before it). On a
/// cold launch `places` and `people` are still arriving from Notion, so a tap
/// before they land must say "still loading" and never "there is no such
/// place". A screen must not report an absence it cannot tell from ignorance.
enum DayflowWikiMiss {
    case loading
    case failed
    case notFound
}

/// What a `[[name]]` turned out to be.
enum DayflowWikiResolution {
    case dailyNote(Date)
    case place(Place)
    case person(Person)
    case note(LinkableNote)
    case endeavor(id: String, name: String)
    case miss(DayflowWikiMiss)
}

/// A miss worth telling the user about, as sheet-friendly state.
struct DayflowWikiMissNotice: Identifiable {
    let name: String
    let miss: DayflowWikiMiss
    var id: String { name + String(describing: miss) }
}

enum DayflowWikiLink {

    /// What this name is.
    ///
    /// **Records first, then notes, then endeavors** - the Mac's documented
    /// precedence, kept exactly. A Place note and a Place record share a name
    /// and the record is what you want; endeavors go last so that adding them
    /// only catches what used to fall through to a false answer, which is the
    /// same placement D270 chose on the Mac.
    ///
    /// **Case-insensitive throughout.** The endeavor screen learned this in
    /// its own comment: two of its three branches were case-sensitive and one
    /// was not, so `[[lakemore resort]]` opened nothing while
    /// `[[Lakemore Resort]]` opened the place, and *nobody chose that
    /// difference.* It is chosen here, once.
    static func resolve(_ raw: String) -> DayflowWikiResolution {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let notion = NotionService.shared

        if let date = DayflowRelatedNotesEngine.parseDailyNoteDate(name) {
            return .dailyNote(date)
        }
        if let place = notion.places.first(where: {
            $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }) {
            return .place(place)
        }
        if let person = notion.people.first(where: {
            $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }) {
            return .person(person)
        }
        if let note = NoteStore.shared.linkableNotes().first(where: {
            $0.title.localizedCaseInsensitiveCompare(name) == .orderedSame
        }) {
            return .note(note)
        }
        let endeavors = EndeavorFile.nameIndex(from: NoteStore.shared)
        if let match = endeavors.first(where: {
            $0.key.localizedCaseInsensitiveCompare(name) == .orderedSame
        }) {
            return .endeavor(id: match.value, name: match.key)
        }
        if notion.placesLoad == .loading || notion.peopleLoad == .loading {
            return .miss(.loading)
        }
        if notion.placesLoad == .failed || notion.peopleLoad == .failed {
            return .miss(.failed)
        }
        return .miss(.notFound)
    }

    /// Act on it.
    ///
    /// `onDailyNote` and `onNote` are optional because two hosts have a day
    /// peek and two do not, and one host pushes a project note onto its own
    /// stack rather than routing away from itself. **Everything a host does
    /// not override is done here**, so no screen can quietly do less than
    /// another - which is exactly how the four copies drifted.
    @MainActor
    static func follow(_ raw: String,
                       openURL: OpenURLAction,
                       onRecord: (WikiLinkTarget) -> Void,
                       onDailyNote: ((Date) -> Void)? = nil,
                       onNote: ((LinkableNote) -> Void)? = nil,
                       onMiss: (DayflowWikiMissNotice) -> Void) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch resolve(name) {
        case .dailyNote(let date):
            if let onDailyNote {
                onDailyNote(date)
            } else if let note = NoteStore.shared.linkableNotes().first(where: {
                $0.title.localizedCaseInsensitiveCompare(name) == .orderedSame
            }) {
                // No peek on this screen, but the note itself exists, so open
                // it rather than doing nothing - which is what three of the
                // four copies did.
                route(note.relativePath, openURL: openURL)
            } else {
                onMiss(DayflowWikiMissNotice(name: name, miss: .notFound))
            }
        case .place(let place):
            onRecord(.place(place))
        case .person(let person):
            onRecord(.person(person))
        case .note(let note):
            if let onNote { onNote(note) } else { route(note.relativePath, openURL: openURL) }
        case .endeavor(let id, _):
            // `dayflow://endeavor?id=` already exists for Satchel's jump from a
            // document filed to a trip, and it routes by id, which survives the
            // note being renamed. A second mechanism here would be a second
            // opinion about how an endeavor is opened.
            if let url = URL(string: "dayflow://endeavor?id=\(id)") { openURL(url) }
        case .miss(let miss):
            onMiss(DayflowWikiMissNotice(name: name, miss: miss))
        }
    }

    /// The app's own note route. `URLComponents` so a title with an ampersand
    /// survives.
    @MainActor
    private static func route(_ relativePath: String, openURL: OpenURLAction) {
        var comps = URLComponents()
        comps.scheme = "dayflow"
        comps.host = "note"
        comps.queryItems = [URLQueryItem(name: "path", value: relativePath)]
        if let url = comps.url { openURL(url) }
    }

    /// Why it opened nothing, in the user's terms.
    ///
    /// One wording for all four screens. It used to exist on one of them.
    static func message(_ notice: DayflowWikiMissNotice) -> String {
        switch notice.miss {
        case .loading:
            return "Places and people are still loading from Notion. Try \(notice.name) again in a moment."
        case .failed:
            return "Places and people could not be loaded from Notion, so \(notice.name) cannot be resolved. Reopen the app to try again."
        case .notFound:
            return "Nothing named \(notice.name) exists as a place, a person, a note or an endeavor yet."
        }
    }
}

extension View {
    /// The shared "nothing to open" alert.
    ///
    /// **A pill that does nothing is indistinguishable from one that is
    /// broken**, and David reported exactly that as *"the destination pills are
    /// not clickable"*. That fix lived on one screen; this modifier is how the
    /// other three get it without a fourth copy of the words.
    func dayflowWikiMissAlert(_ notice: Binding<DayflowWikiMissNotice?>) -> some View {
        alert("Nothing to open", isPresented: Binding(
            get: { notice.wrappedValue != nil },
            set: { if !$0 { notice.wrappedValue = nil } }
        )) {
            Button("OK", role: .cancel) { notice.wrappedValue = nil }
        } message: {
            Text(notice.wrappedValue.map(DayflowWikiLink.message) ?? "")
        }
    }
}


// MARK: - Backlink rows (Session 88)
//
// **The arrow and the tap must come from the same answer.** A backlink row
// draws a chevron when it thinks it can be opened, and a separate function
// decided what tapping it did. On the backlinks screen the chevron rule was
// "anything except Horizons" while the tap handled four folders, so an
// endeavor row drew an arrow and did nothing. The wiki summary's own comment
// had already named this exact failure when it added its endeavor case:
// *"The chevron was already promising it... the two were written at different
// times and nothing made them agree."* It was fixed there and left standing
// here, which is the same one-screen-only fix that D282 was made of.
//
// Same split as the wikilink resolver above: this decides WHAT a row points
// at, and each screen decides how to show it - one screen swaps its body,
// the other presents. Neither can quietly support fewer destinations than the
// other, because `isOpenable` is derived from the same answer the tap uses.

enum DayflowMentionTarget {
    case projectNote(String)
    case dailyNote(Date)
    case place(Place)
    case person(Person)
    case endeavor(id: String, name: String)
    /// No destination. Today that is Horizons, and anything whose record has
    /// gone missing since the mention was written.
    case none
}

enum DayflowMention {

    private static let dayKey: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// What this row points at.
    ///
    /// **Deliberately not the wikilink resolver.** That one matches a literal
    /// `[[Name]]` typed in a note body against a record's name. A mention
    /// row's title is a FILENAME, and a place's note filename is sanitised for
    /// the filesystem, so the two questions have different right answers. The
    /// wiki summary's own comment made that call and it still holds.
    ///
    /// Endeavors are keyed by slug rather than by title, so the store is asked
    /// rather than the filename trusted.
    static func target(for mention: NoteMention) -> DayflowMentionTarget {
        let path = mention.relativePath
        if path.hasPrefix("Notes/Projects/") {
            return .projectNote(mention.title)
        }
        if path.hasPrefix("Calendar/") {
            if let parsed = dayKey.date(from: mention.title) { return .dailyNote(parsed) }
            return .none
        }
        if path.hasPrefix("Notes/Places/") {
            if let place = NotionService.shared.places.first(where: {
                NoteStore.shared.placeNoteFilename(for: $0.name) == mention.title
            }) { return .place(place) }
            return .none
        }
        if path.hasPrefix("Notes/People/") {
            if let person = NotionService.shared.people.first(where: {
                $0.name.localizedCaseInsensitiveCompare(mention.title) == .orderedSame
            }) { return .person(person) }
            return .none
        }
        if path.hasPrefix("Notes/Endeavors/") {
            if let match = EndeavorStore.shared.endeavors.first(where: {
                $0.name.localizedCaseInsensitiveCompare(mention.title) == .orderedSame
            }) { return .endeavor(id: match.id, name: match.name) }
            return .none
        }
        return .none
    }

    /// Whether to draw the arrow. Derived from `target`, so the promise and
    /// the behaviour cannot drift apart again.
    static func isOpenable(_ mention: NoteMention) -> Bool {
        if case .none = target(for: mention) { return false }
        return true
    }
}
