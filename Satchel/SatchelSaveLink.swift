import Foundation
import UIKit

// MARK: - SatchelSaveLink
//
// D390's Save to Satchel, the Satchel half. Session 103.
//
// **Why the work is here and not in Trace.** The obvious build was for Trace's
// Place page to write the `.webloc` and its sidecar itself and show its own
// confirmation, staying where David already was. `TraceSatchelHandoff.swift`
// says in capitals why that is wrong: Trace hands across INTENT, never data,
// and must not become a second writer of sidecars again. So Trace sends an
// address and where it came from; everything below happens in the app that owns
// the store.
//
// The cost is an app switch, which is paid back by the return action on the
// confirmation.
//
// **The dedupe is the part with a decision in it.** Saving the same address
// twice is not an edge case: a restaurant's site sits on the place's website
// field AND gets pasted into an endeavor note. So a second save finds the first
// document by its normalised address and adds the new origin rather than
// creating a twin.
//
// `places:` is a list, so a second place simply joins. `endeavor` is a single
// field, and David's call (Session 103) is that an existing one is KEPT and the
// confirmation says so. Silently moving a document out of an endeavor is a
// change he did not ask for, and the one he can see is the one he can fix.

enum SatchelSaveLinkOutcome {
    /// A new document. `filedTo` is the origin it was given, if any.
    case created(title: String, filedTo: String?)
    /// The address was already a document. `addedTo` is what this save added;
    /// `keptEndeavor` names an endeavor that was left alone.
    case alreadyFiled(title: String, addedTo: String?, keptEndeavor: String?)
    case failed(String)
}

@MainActor
enum SatchelSaveLink {

    static func perform(_ request: SatchelSaveLinkRequest,
                        store: iOSDocumentStore) async -> SatchelSaveLinkOutcome {
        let address = request.url.absoluteString
        let key = TraceMacDocument.normalisedURL(address)
        guard !key.isEmpty else { return .failed("That address could not be read.") }

        // **Look before writing, and look at a CURRENT store.** A hand-off can
        // arrive at a cold launch, where `documents` is still empty; filing
        // against that would create a twin of something already on disk and the
        // duplicate would be invisible until the next reload.
        if store.documents.isEmpty { await store.reload() }

        if let existing = store.documents.first(where: {
            !$0.url.isEmpty && TraceMacDocument.normalisedURL($0.url) == key
        }) {
            return merge(request, into: existing, store: store)
        }
        return await create(request, address: address, store: store)
    }

    // MARK: The second save

    private static func merge(_ request: SatchelSaveLinkRequest,
                              into doc: TraceMacDocument,
                              store: iOSDocumentStore) -> SatchelSaveLinkOutcome {
        var places = doc.places
        var added: String?

        if let place = request.place, !place.isEmpty,
           !places.contains(where: { $0.caseInsensitiveCompare(place) == .orderedSame }) {
            places.append(place)
            added = place
        }

        // The single field. Filled only when it is empty; never overwritten.
        var endeavorID: String?
        var endeavorName: String?
        var kept: String?
        if let id = request.endeavorID, !id.isEmpty {
            if doc.endeavor == nil || doc.endeavor?.isEmpty == true {
                endeavorID = id
                endeavorName = request.endeavorName
                if added == nil { added = request.endeavorName ?? "this endeavor" }
            } else if doc.endeavor != id {
                kept = doc.endeavorName ?? "its endeavor"
            }
        }

        guard added != nil || kept != nil else {
            return .alreadyFiled(title: doc.title, addedTo: nil, keptEndeavor: nil)
        }
        do {
            _ = try store.updateSidecar(for: doc,
                                        endeavor: endeavorID,
                                        endeavorName: endeavorName,
                                        places: added != nil ? places : nil)
            return .alreadyFiled(title: doc.title, addedTo: added, keptEndeavor: kept)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: The first save

    private static func create(_ request: SatchelSaveLinkRequest,
                               address: String,
                               store: iOSDocumentStore) async -> SatchelSaveLinkOutcome {
        guard let data = TraceMacDocument.weblocData(for: address) else {
            return .failed("That address could not be written.")
        }

        var host = request.url.host ?? "link"
        if host.lowercased().hasPrefix("www.") { host = String(host.dropFirst(4)) }

        let now = Date()
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd-HHmmss"
        let slug = host.components(separatedBy: .whitespacesAndNewlines).joined(separator: "-")
            .replacingOccurrences(of: "/", with: "-")
        let filename = "\(fmt.string(from: now))-\(slug).webloc"
        let year = NoteStore.documentFolder(for: now)

        let relativePath: String
        do {
            relativePath = try NoteStore.shared.writeDocument(data, category: year, filename: filename)
        } catch {
            return .failed(error.localizedDescription)
        }

        // **The host is the title until the page offers a better one, and it
        // stays the title if the page refuses** (D384). SharePoint and anything
        // else behind a login never yields one, which is the honest name for a
        // link the phone cannot see.
        let fetched = await SatchelLinkPreview.fetch(for: address)
        let title = fetched.title ?? host

        let doc = TraceMacDocument(
            relativePath: relativePath,
            filename: filename,
            category: year,
            fileExtension: "webloc",
            title: title,
            tags: [],
            created: now,
            linkedNote: request.noteLink,
            people: [],
            description: ""
        )

        do {
            try store.saveSidecar(
                for: doc,
                title: title,
                tags: [],
                linkedNote: request.noteLink,
                people: [],
                date: now,
                endeavor: request.endeavorID,
                endeavorName: request.endeavorName,
                url: .some(address),
                places: request.place.map { [$0] } ?? []
            )
        } catch {
            return .failed(error.localizedDescription)
        }

        await store.reload()
        return .created(title: title,
                        filedTo: request.place ?? request.endeavorName)
    }
}

// MARK: - What the confirmation says

extension SatchelSaveLinkOutcome {
    /// One line each, because the toast is one line each. The wording carries
    /// the fact the caller most needs and no more: what happened, and to what.
    var headline: String {
        switch self {
        case .created:      return "Saved to Satchel"
        case .alreadyFiled: return "Already in Satchel"
        case .failed:       return "Couldn't save that link"
        }
    }

    var detail: String? {
        switch self {
        case .created(let title, let filedTo):
            return filedTo.map { "\(title) · filed to \($0)" } ?? title
        case .alreadyFiled(let title, let addedTo, let kept):
            if let kept, let addedTo { return "\(addedTo) added · still filed to \(kept)" }
            if let kept              { return "\(title) · still filed to \(kept)" }
            if let addedTo           { return "Also filed to \(addedTo)" }
            return title
        case .failed(let reason):
            return reason
        }
    }

    var isFailure: Bool { if case .failed = self { return true }; return false }
}
