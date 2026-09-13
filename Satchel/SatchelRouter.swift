import SwiftUI
import Observation

// MARK: - SatchelRouter
//
// Build step 12: the `satchel://` URL scheme.
//
// The scheme is already registered in `Satchel/Info.plist` (Session 49). This is
// the half that does something with it. Same job `ShortcutRouter.swift` does for
// Trace's `trace://` scheme, and the same pattern Dayflow already uses to reach
// Trace for `checkin` / `addplace` / `addperson` / `loginteraction`.
//
// WHY THIS MATTERS BEYOND SHORTCUTS: scope doc §7 is the real consumer. Once
// Satchel is trusted, Trace retires its own Documents browser and keeps only a
// descriptive reference chip — title, type icon, thumbnail — that hands off to
// Satchel by URL. `satchel://document?path=…` is that hand-off, and it is why
// the document route takes a container-relative path rather than an opaque ID:
// the path is what Trace already has in its markdown links.
//
//   satchel://                              open the Library
//   satchel://scan                          straight into the document scanner
//   satchel://photo                         straight into the camera
//   satchel://library                       photo library picker
//   satchel://import                        file importer
//   satchel://kit                           the full Kit screen
//   satchel://all                           all documents, sorted and filterable
//   satchel://search?q=passport             Library with a search already run
//   satchel://document?path=Documents/…     open one document in the viewer
//   satchel://savelink?url=…                file a web address as a document
//
// `savelink` is D390's door (Session 103). Trace and Dayflow long-press a link
// — printed in an endeavor note, or a place's website field — and hand the
// address across with where it came from:
//
//   satchel://savelink?url=https://x.com/y&place=Scratchboard%20Kitchen
//   satchel://savelink?url=https://x.com/y&endeavor=<id>&endeavor_name=Japan
//   satchel://savelink?url=https://x.com/y&note=Notes/Places/la-bella.md
//   …&return=trace://place?id=<notion id>   where to send him back to
//
// **The direction of travel is the whole point, and it is the rule this file
// already states below.** The obvious build was for Trace to write the
// `.webloc` and its sidecar itself and show its own confirmation, which would
// have made Trace a second writer of sidecars — the one thing
// `TraceSatchelHandoff.swift` says in capitals it must never become again.
// Trace sends an address and an origin; Satchel decides whether it is already
// a document, names it from the page, writes the sidecar and says what it did.
//
// All four capture routes also accept `&note=<note relative path>`:
//
//   satchel://scan?note=Notes/Places/la-bella.md
//
// which is the OTHER half of the §7 hand-off. §7 covers Trace reading a document
// and pushing to Satchel to view it; this covers Trace's Place or Person note
// offering "Add document" and pushing to Satchel to CREATE one, with the link
// already set. Without it, a document captured from a note costs the user a trip
// through the note picker to re-find the note they were just looking at.
//
// Note the direction of travel: Trace hands across INTENT, never data. Satchel
// still writes the sidecar, still owns `linked_note`, still decides everything
// else about the document. That is what keeps §7's retirement of Trace's
// document handling clean — Trace never becomes a second writer again.
//
// Unknown hosts fall through to the Library rather than failing. A URL scheme is
// a public surface — anything can send anything, and landing somewhere sensible
// beats doing nothing with no explanation.

@Observable
final class SatchelRouter {

    /// Set when a URL asks for a capture source. The Library presents it.
    var pendingCapture: SatchelCaptureSource?
    /// Set alongside `pendingCapture` when the URL also names the note the new
    /// document should belong to. Read and cleared by the Library in the same
    /// breath as `pendingCapture`, so it can never leak into a later capture the
    /// user started themselves from the scan button.
    var pendingNoteLink: String?
    /// Set when a URL asks for a search. The Library fills its field.
    var pendingSearch: String?
    /// Set when a URL asks to push a screen. The Library appends it to its path.
    var pendingDestination: SatchelDeepLink?
    /// Set when a URL asks for a web address to be filed (D390). Drained by the
    /// Library in `drainRouter`, exactly as the capture sources are.
    var pendingSaveLink: SatchelSaveLinkRequest?

    func handle(_ url: URL) {
        guard url.scheme?.lowercased() == "satchel" else { return }

        // `satchel://scan` parses with "scan" as the HOST, not the path — a
        // two-slash URL has no path component at all. Checking both means
        // `satchel://scan` and `satchel:///scan` behave the same, which is the
        // sort of difference nobody should have to remember when writing a
        // Shortcut at speed.
        let host = url.host()?.lowercased()
        let firstPath = url.pathComponents.first(where: { $0 != "/" })?.lowercased()
        let route = host ?? firstPath

        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name.lowercased() == name }?.value
        }

        // Assigned BEFORE `pendingCapture` in every capture case below. Both
        // mutations land in the same synchronous block so SwiftUI sees them
        // together, but the ordering is written down anyway: the Library's
        // observer keys off `pendingCapture`, and a future refactor that made
        // these two separate assignments would silently drop the link.
        let noteLink = normalizedNote(
            value("note") ?? value("linked_note") ?? value("linkednote")
        )

        switch route {
        case "scan":
            pendingNoteLink = noteLink
            pendingCapture = .scan
        case "photo":
            pendingNoteLink = noteLink
            pendingCapture = .photo
        case "library":
            pendingNoteLink = noteLink
            pendingCapture = .library
        case "import":
            pendingNoteLink = noteLink
            pendingCapture = .file
        case "kit":      pendingDestination = .kit
        case "all":      pendingDestination = .allDocuments
        case "search":
            pendingSearch = value("q") ?? value("query") ?? ""
        case "savelink", "link":
            // An address with no scheme is forgiven the way a note path with no
            // extension is: `openableURL` adds `https://`, and refuses anything
            // that is not a host. A `savelink` with nothing usable in it does
            // nothing rather than filing a document named after a typo.
            if let raw = value("url") ?? value("address"),
               let url = TraceMacDocument.openableURL(raw),
               ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                pendingSaveLink = SatchelSaveLinkRequest(
                    url: url,
                    place: value("place")?.trimmingCharacters(in: .whitespacesAndNewlines),
                    endeavorID: value("endeavor"),
                    endeavorName: value("endeavor_name") ?? value("endeavorname"),
                    noteLink: noteLink,
                    returnURL: value("return").flatMap { URL(string: $0) })
            }
        case "document":
            // Accept `?path=` or a trailing path, so both of these work:
            //   satchel://document?path=Documents/Inbox/x.pdf
            //   satchel://document/Documents/Inbox/x.pdf
            if let path = value("path") ?? value("relativepath") {
                pendingDestination = .document(path)
            } else {
                let trailing = url.pathComponents
                    .drop(while: { $0 == "/" || $0.lowercased() == "document" })
                    .joined(separator: "/")
                if !trailing.isEmpty { pendingDestination = .document(trailing) }
            }
        default:
            // Includes a bare `satchel://` — open the Library, which is where it
            // already is. Deliberately not an error.
            break
        }
    }

    /// Tidies a note path handed over by another app into the exact shape
    /// `linked_note` is stored in, because a near-miss here is worse than a
    /// miss: the sidecar would be written with a path that renders fine in
    /// Satchel and matches nothing when Trace runs its reverse lookup, so the
    /// chip would simply never appear and there would be nothing on screen to
    /// explain why.
    ///
    /// Leading slashes go (paths are container-relative, never absolute), and a
    /// final component with no extension gets `.md` — Trace has the full path in
    /// hand and should send it, but "Notes/Places/la-bella" is the obvious thing
    /// to send by mistake and the obvious thing to forgive.
    private func normalizedNote(_ raw: String?) -> String? {
        guard var path = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else { return nil }

        while path.hasPrefix("/") { path.removeFirst() }
        guard !path.isEmpty else { return nil }

        if let last = path.components(separatedBy: "/").last, !last.contains(".") {
            path += ".md"
        }
        return path
    }
}

// MARK: - Save a link (D390)

/// Everything `satchel://savelink` carries, in one value.
///
/// One struct rather than five `pending…` properties on the router, for the
/// reason the capture request already learned: separate properties are two
/// mutations a later refactor can split apart, and the half that gets dropped
/// is always the origin — the whole point of the hand-off.
struct SatchelSaveLinkRequest: Hashable {
    let url: URL
    /// A place NAME, because `places:` holds names. It is also why a renamed
    /// place loses the association, which is D385's choice and not revisited
    /// here.
    let place: String?
    let endeavorID: String?
    let endeavorName: String?
    let noteLink: String?
    /// Where to offer to send him back to, if the sender said. Satchel opens
    /// it only on a deliberate tap, never on its own.
    let returnURL: URL?
}

// MARK: - Deep link targets

/// Value-based navigation targets, so a URL can push a screen the same way a tap
/// does. Kept `Hashable` and free of model objects: a deep link arrives before
/// the store has necessarily loaded, so it carries a path and resolves later.
enum SatchelDeepLink: Hashable {
    case kit
    case allDocuments
    case document(String)   // container-relative path
}
