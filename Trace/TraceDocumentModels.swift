// TraceDocumentModels.swift
// Shared document model types used by the Trace (iOS), TraceMac and Satchel targets.
// Add this file to: Trace (iOS), TraceMac, Satchel. Do NOT add to Widget or Share Extension.
//
// Session 50 (2026-07-27) — Satchel build step 3, "widen the model".
// Adds the five sidecar keys from `Documents-App-Scope.md` §4 to `TraceMacDocument`
// (`endeavor`, `endeavorName`, `pinned`, `icon`, `tint`) and `icon` + `tint` to
// `DocumentScanResult`. Every new property is defaulted, so the four existing
// memberwise-init call sites (IOSDocumentStore, IOSDocumentsView,
// TraceMacDocumentStore, TraceMacDocumentsView) keep compiling untouched.
//
// Foundation-only by design: this file is shared with TraceMac, so the icon and
// tint vocabularies live here as *tokens*, and the SwiftUI rendering of those
// tokens (SF Symbol lookup, tint Color) lives in `SatchelSkin.swift`.

import Foundation

// MARK: - Document icon

/// The fixed SF Symbol vocabulary a document icon may come from.
///
/// Scope doc §5 "Document icons": the AI scan picks one of these at capture
/// time and it is cached in the sidecar forever, so rendering is a local
/// symbol lookup with no network. The set is deliberately *fixed* — free
/// choice drifts into a jumble and the tiles stop reading as one system.
///
/// The raw value is what lands in the sidecar (`icon: receipt`). The SF Symbol
/// name is an implementation detail mapped in `sfSymbol` below, so a symbol
/// can be swapped for a better one without rewriting a single sidecar.
enum DocumentIcon: String, CaseIterable, Hashable, Codable, Sendable {
    case document
    case receipt
    case contract
    case legal
    case passport
    case id
    case card
    case ticket
    case plane
    case train
    case car
    case lodging
    case medical
    case home
    case work
    case finance
    case education
    case photo
    case map
    case note
    case manual
    case menu
    case reading
    /// Session 72. David: *"the arlington heights animal hospital receipt shows
    /// as a document which is true but the more important aspect to get right is
    /// that it is a receipt for my dogs health."*
    case pet
    /// Session 102 (D384). A saved web address: the document IS the link, so
    /// the glyph says so rather than borrowing `document`. The `.webloc`
    /// extension resolves here by default; the scanner may still choose a
    /// subject (a hotel page is `lodging`) and that choice wins.
    case link

    /// SF Symbol name. Kept to long-established symbols (all iOS 16 or earlier,
    /// well under the 26.5 deployment target) because a wrong symbol name fails
    /// *silently* at render time rather than at compile time.
    var sfSymbol: String {
        switch self {
        case .document:  return "doc.text"
        case .receipt:   return "banknote"
        case .contract:  return "signature"
        case .legal:     return "building.columns"
        case .passport:  return "person.text.rectangle"
        case .id:        return "person.crop.rectangle"
        case .card:      return "creditcard"
        case .ticket:    return "ticket"
        case .plane:     return "airplane"
        case .train:     return "tram.fill"
        case .car:       return "car"
        case .lodging:   return "bed.double"
        case .medical:   return "cross.case"
        case .home:      return "house"
        case .work:      return "briefcase"
        case .finance:   return "chart.bar.doc.horizontal"
        case .education: return "graduationcap"
        case .photo:     return "photo"
        case .map:       return "map"
        case .note:      return "note.text"
        case .manual:    return "book.closed"
        case .menu:      return "fork.knife"
        case .reading:   return "newspaper"
        case .pet:       return "pawprint"
        case .link:      return "link"
        }
    }

    /// Human-readable label for the icon picker on the capture and detail screens.
    var label: String {
        switch self {
        case .document:  return "Document"
        case .receipt:   return "Receipt"
        case .contract:  return "Contract"
        case .legal:     return "Legal"
        case .passport:  return "Passport"
        case .id:        return "ID"
        case .card:      return "Card"
        case .ticket:    return "Ticket"
        case .plane:     return "Flight"
        case .train:     return "Rail"
        case .car:       return "Vehicle"
        case .lodging:   return "Lodging"
        case .medical:   return "Medical"
        case .home:      return "Home"
        case .work:      return "Work"
        case .finance:   return "Finance"
        case .education: return "Education"
        case .photo:     return "Photo"
        case .map:       return "Map"
        case .note:      return "Note"
        case .manual:    return "Manual"
        // "Dining", not "Menu", since Session 72 widened it — the token stays
        // `menu` so no sidecar has to be rewritten, but nothing in the UI should
        // still tell David a restaurant reservation is a menu.
        case .menu:      return "Dining"
        case .reading:   return "Reading"
        case .pet:       return "Pet"
        case .link:      return "Link"
        }
    }

    /// One-line hint used in the scan prompt so the model picks sensibly.
    var promptHint: String {
        switch self {
        case .document:  return "LAST RESORT for paper that fits nothing else"
        case .receipt:   return "receipts, invoices, bills, expense claims"
        case .contract:  return "agreements with no better home: leases, service contracts, insurance policies. NOT vehicle documents (use car) and NOT wills or deeds (use legal)"
        case .passport:  return "passport and visa ONLY"
        case .id:        return "government photo ID: driver's licence, state ID, Global Entry"
        case .card:      return "any other wallet-sized card: insurance, medical, credit, membership, loyalty"
        case .ticket:    return "every other ticketed thing: events, attractions, vouchers"
        case .plane:     return "AIR travel only: boarding pass, flight confirmation, airline itinerary"
        case .train:     return "RAIL travel only: rail pass, train ticket, transit pass"
        case .car:       return "anything about a vehicle, INCLUDING rental agreements: registration, insurance for the car, service records"
        case .lodging:   return "hotel or ryokan confirmation, booking"
        case .medical:   return "medical records, prescriptions, allergies, test results"
        case .home:      return "home maintenance and reference — paint colours, appliance models and serial numbers, filter sizes, contractor quotes, service and inspection records. Often a PHOTO rather than paper. NOT the mortgage or deed (legal) and NOT the utility bill (finance)"
        case .work:      return "work documents, offers, contracts of employment"
        case .finance:   return "money: bank statements, tax forms, UTILITY BILLS, financial reports"
        case .education: return "certificates, transcripts, course materials"
        case .photo:     return "LAST RESORT for an image with no other identifiable purpose. If a photograph is OF a receipt, a card, a vehicle, a paint colour or a whiteboard, use that type instead"
        case .map:       return "maps, floor plans, directions"
        case .note:      return "handwritten or typed notes"
        case .manual:    return "the manufacturer's own document: manuals, guides, warranties. Your own record about the house is home"
        case .legal:     return "wills, deeds, mortgage, titles, court documents, powers of attorney"
        case .menu:      return "DINING in the broad sense: restaurants and food. Menus, reservations and confirmations, a restaurant's contact details, a food order or pickup receipt. If the document is about a place you eat, this is the type"
        case .reading:   return "articles and PDFs you mean to read, whether temporary or kept"
        case .pet:       return "anything about an animal: vet visits and bills, vaccination records, medication, grooming, boarding, licence tags"
        case .link:      return "a saved web address with no better subject: a portal, a tool, a folder on SharePoint, a reference page. If the page is clearly about a hotel, a flight, a restaurant or a purchase, prefer that subject instead"
        }
    }

    /// **Swatch colour for pickers only. NOT what a document is tinted.**
    ///
    /// Session 72 gave colour its own meaning — see `DocumentTint` — so a
    /// document's colour can no longer be a function of its icon: the two axes
    /// answer different questions, and deriving one from the other would make
    /// every document's type read as a restatement of its subject.
    /// `resolvedTint` now falls back to `.gray`, not to this.
    ///
    /// Kept because the icon pickers draw a swatch per candidate and a grid of
    /// twenty-four grey tiles is harder to scan than a coloured one. Nothing
    /// here is written to a sidecar.
    ///
    /// The tint this icon carries when the scan did not supply one. Pairing the
    /// default to the icon rather than to the file type is what keeps the grid
    /// coherent when several documents fall back at once.
    var defaultTint: DocumentTint {
        switch self {
        case .document:  return .gray
        case .receipt:   return .amber
        case .contract:  return .blue
        case .legal:     return .indigo
        case .passport:  return .teal
        case .id:        return .blue
        case .card:      return .rose
        // D344 rebalance. Eight tints over twenty-five icons collide by
        // arithmetic, so the collisions are put where they cost least: two
        // icons David rarely files side by side may share, the ones that fill
        // a travel endeavor may not. Ticket left indigo beside plane made a
        // trip's flights and its shuttles the same colour, which is the one
        // list where telling them apart matters most.
        case .ticket:    return .amber
        case .plane:     return .indigo
        case .train:     return .teal
        case .car:       return .blue
        case .lodging:   return .rose
        case .medical:   return .red
        case .home:      return .green
        case .work:      return .blue
        case .finance:   return .amber
        case .education: return .indigo
        case .photo:     return .teal
        case .map:       return .teal
        case .note:      return .blue
        case .manual:    return .gray
        case .menu:      return .green
        case .reading:   return .teal
        case .pet:       return .green
        // Teal, not blue: the Kind row spells a tint out, and blue reads
        // "Confirmation, reservation, ticket". A saved link is closest to
        // Reference, which is teal. Seen on the first pasted link, 2026-09-13.
        case .link:      return .teal
        }
    }

    /// Lenient parse for sidecar and model output. Unknown tokens return nil so
    /// the caller falls back to the type-based rule rather than rendering blank.
    static func parse(_ raw: String?) -> DocumentIcon? {
        guard let raw else { return nil }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty, key != "null", key != "none" else { return nil }
        return DocumentIcon(rawValue: key)
    }

    /// Comma-separated token list for the scan prompt.
    static var promptTokenList: String {
        allCases.map(\.rawValue).joined(separator: ", ")
    }

    /// `token — hint` lines for the scan prompt.
    static var promptGuide: String {
        allCases.map { "  \($0.rawValue) — \($0.promptHint)" }.joined(separator: "\n")
    }
}

// MARK: - Document tint

/// The fixed eight-colour tint palette. Scope doc §5.
///
/// Hex values are the approved ones from `satchel-mockup-v4.html` and are
/// reproduced here as documentation only — the actual `Color` values live in
/// `SatchelSkin.swift` so a restyle stays a one-file change.
///
/// | token  | background | foreground |
/// |--------|------------|------------|
/// | teal   | #DBF0F1    | #0E7C86    |
/// | blue   | #E5F0FF    | #0A84FF    |
/// | green  | #E4F7EA    | #248A3D    |
/// | rose   | #FDEAF3    | #CF2F77    |
/// | indigo | #ECEEFF    | #5856D6    |
/// | amber  | #FFF2E0    | #C9760A    |
/// | red    | #FFE6E9    | #D70015    |
/// | gray   | #ECEEF0    | #6B6B70    |
enum DocumentTint: String, CaseIterable, Hashable, Codable, Sendable {
    case teal
    case blue
    case green
    case rose
    case indigo
    case amber
    case red
    case gray

    var label: String { rawValue.capitalized }

    // MARK: What a colour MEANS, since Session 72
    //
    // **Two axes, and each answers one question.** The icon says what a document
    // is ABOUT; the colour says what KIND of thing it is. Before this they both
    // tried to answer the first, badly: the scan prompt said *"choose what the
    // document IS, not what it is about"*, which forced the shape onto the type
    // axis, and colour was left as "whatever matches the document's character"
    // and defaulted from the icon — a second copy of the shape.
    //
    // David, on three real documents that were all correctly typed and all
    // useless: the Panera screenshot read `receipt`, the vet bill read
    // `document`, the Nick's reservation read `card`. *"The type is a secondary
    // thing that yes i will look for but only occasionally. What does color
    // signify? can we use that in the rule?"* Exactly right, and colour is the
    // correct home for a secondary signal — you read shape first and hunt by
    // colour only when you are looking for one.
    //
    // **Two of the eight are spoken for and stay out of the type palette.**
    // `amber` reads as private everywhere in this app since Session 71 (orange
    // with a lock), so an amber receipt would be misread at a glance. `red` used
    // to mean medical, which is now the icon's job, so it is free — held for
    // "needs action" rather than reassigned, because a colour that means two
    // things is how this whole problem started.
    var typeMeaning: String? {
        switch self {
        case .green:  return "Receipt, bill, proof of payment"
        case .blue:   return "Confirmation, reservation, ticket"
        case .indigo: return "Contract, policy, anything official"
        case .teal:   return "Reference: contact details, amenities, manuals"
        case .rose:   return "Personal, keepsake"
        case .gray:   return "Unclassified"
        case .amber:  return nil   // private, app-wide
        case .red:    return nil   // held for "needs action"
        }
    }

    /// The six a document may be typed as. `amber` and `red` are deliberately
    /// absent — see `typeMeaning`.
    static var typeCases: [DocumentTint] { [.green, .blue, .indigo, .teal, .rose, .gray] }

    /// The tint half of the scan prompt, built from the same table the pickers
    /// read, so the model and the UI cannot describe different colours.
    static var promptGuide: String {
        typeCases.compactMap { t in t.typeMeaning.map { "  \(t.rawValue) — \($0)" } }
            .joined(separator: "\n")
    }

    /// Lenient parse. Unknown tokens return nil so the icon's `defaultTint` applies.
    static func parse(_ raw: String?) -> DocumentTint? {
        guard let raw else { return nil }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty, key != "null", key != "none" else { return nil }
        return DocumentTint(rawValue: key)
    }

    /// Comma-separated token list for the scan prompt.
    static var promptTokenList: String {
        allCases.map(\.rawValue).joined(separator: ", ")
    }
}

// MARK: - Article state

/// What the fetch behind a saved link concluded, sidecar key `article`
/// (D407 Build 2.1).
///
/// **It was a boolean for one build, and one build was enough to show why it
/// could not be.** The first rule was three hundred words of anything: a
/// chatty product description cleared it and became an article, and so did a
/// paywalled news page whose "article" was two paragraphs and an invitation to
/// log in. The second is worse than the first — a TRUNCATED article filed as a
/// complete one is a screen that looks finished and is not, and nothing
/// anywhere says so.
///
/// Blocked is therefore its own answer rather than a shade of `false`. It is
/// what the sign-in sheet exists to repair, so it has to be findable; and it is
/// the difference between "this was never going to be reading" and "this is
/// reading you cannot see yet", which is the difference between a card that
/// says nothing and a card that says what to do.
///
/// Raw values are the on-disk spellings and the first two are deliberately
/// `true` and `false`, so every sidecar written before this change still reads
/// correctly and nothing has to be migrated.
enum ArticleState: String {
    /// Real prose. The text is in `## Text` and the document is on the Shelf.
    case article = "true"
    /// A product page, a store, a map, a tool. A plain link in the library,
    /// D384's behaviour unchanged.
    case link = "false"
    /// The page said, in one way or another, that this is for subscribers. The
    /// stub it did show is in `## Text`; a sign-in and a Retry is what fixes it.
    case blocked = "blocked"

    /// Lenient, like every other sidecar parse in this file. Anything
    /// unrecognised is `nil`, which reads as "never tried" and lets the fetch
    /// have another go rather than freezing a value nobody can explain.
    static func parse(_ raw: String) -> ArticleState? {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "true", "yes", "1": return .article
        case "false", "no", "0": return .link
        case "blocked":          return .blocked
        default:                 return nil
        }
    }
}

// MARK: - Document model

struct TraceMacDocument: Identifiable, Hashable {
    let id: UUID = UUID()
    let relativePath: String     // "Documents/Inbox/2026-07-02-receipt.pdf"
    let filename: String         // "2026-07-02-receipt.pdf"
    let category: String         // "Inbox", "Project", "Place", "Trip", etc.
    let fileExtension: String    // "pdf", "jpg", "png", etc. (lowercased)
    var title: String            // from sidecar or derived from filename
    var tags: [String]           // from sidecar frontmatter
    var created: Date?           // from sidecar or filesystem
    var linkedNote: String?      // from sidecar `linked_note` field
    var people: [String]         // from sidecar `people` field
    var description: String      // from sidecar `description` field

    // MARK: Satchel additions (scope doc §4). All defaulted — existing memberwise
    // call sites in Trace and TraceMac are unaffected.

    /// Notion page ID of the Endeavor this document is filed against. Authoritative.
    var endeavor: String? = nil
    /// Cached Endeavor display name so the library renders offline with no network.
    /// A cache only: `endeavor` wins on mismatch and this is refreshed on next fetch.
    var endeavorName: String? = nil
    /// Manual pin. `true` puts the document in Kit permanently until unpinned.
    /// Active-trip Kit membership is computed at render time and writes nothing here.
    var pinned: Bool = false
    /// Position within whichever Kit group this document is in, ascending.
    /// Session 50 addition, sidecar key `kit_order`.
    ///
    /// NOT in the original §4 key list. Added because §5 locks Kit sort to
    /// "user order, drag to reorder" — a rule with nowhere to write its result.
    ///
    /// **One field serves both groups.** A document is either a manual pin or an
    /// active-trip member, never both (trip membership explicitly excludes
    /// pinned documents), so a second ordering key would only ever be half
    /// populated. It was briefly named `pin_order`; renamed once trip documents
    /// became reorderable too, since the name would then have been a lie.
    ///
    /// `nil` sorts last, so documents that predate the key fall to the end
    /// rather than jumping to the front.
    var kitOrder: Int? = nil
    /// Icon token chosen by the AI scan at capture time. nil until scanned.
    var icon: DocumentIcon? = nil
    /// Tint token chosen by the AI scan at capture time. nil until scanned.
    var tint: DocumentTint? = nil

    // MARK: Sidecar BODY (scope §4 "Sidecar BODY", added 2026-07-28)
    //
    // These two live BELOW the frontmatter as markdown, not as YAML keys. The
    // sidecar parser is line-based and splits each line on its first colon, so
    // multi-line prose in frontmatter would be mangled. The body is where prose
    // belongs, and it stays readable as plain markdown.
    //
    // Declared LAST on purpose: the memberwise initialiser follows declaration
    // order, and every call site appends new arguments at the end. Inserting
    // these in the middle is what broke the build on 2026-07-27.

    /// When this document needs attention, sidecar key `remind`.
    ///
    /// David, 2026-08-01: *"For satchel if there is no copy of the date how is it
    /// saved? I would want to see items with dates somehow."*
    ///
    /// I had left it out on purpose that morning, reasoning that a stored date
    /// with no screen reading it is a field with no reader. **He then asked for
    /// the screen**, which retires the argument: the Library now has a Due
    /// section, so the date has somewhere to be read.
    ///
    /// Declared before the two body fields but after everything else, per the
    /// rule at the top of this block — the memberwise initialiser follows
    /// declaration order and every call site appends at the end.
    var remindOn: Date? = nil

    /// David's own note about the document, under `## Note`.
    /// **Never written by AI** — sharing a field with the summary would mean
    /// re-summarising deletes what he typed.
    var note: String = ""
    /// The on-demand AI summary, under `## Summary`. Runs only when asked and
    /// rewrites only its own section. Distinct from `description`, which is the
    /// short capture-time line the list rows render.
    var summary: String = ""
    /// Words read off the file itself — Vision OCR for an image, the PDF text
    /// layer or an OCR pass for a PDF — under `## Text`. Session 70, spec §8
    /// step 2. Written once at capture, never by hand, and never sent anywhere
    /// to produce it.
    ///
    /// Empty is a real answer: a photograph with no writing in it.
    var extractedText: String = ""
    /// Whether the extraction pass has run at all, which is a different
    /// question from whether it found anything. See
    /// `TraceMacDocumentStore.SidecarBody.hasTextSection` for why this is not a
    /// frontmatter key and why the distinction matters.
    var textExtracted: Bool = false
    /// When this document landed in Satchel, as opposed to the date printed on
    /// it (D347).
    ///
    /// **Two different dates, and the list needs the other one.** `created` is
    /// the document's OWN date — the scan sets it from what the page says, so a
    /// rental confirmation for next May carries next May. Sorted by that, a
    /// booking made today sits above everything for a year, which is right for
    /// "when is this" and wrong for "what did I just add". David, looking at a
    /// list headed MAY 10: *"Id like the normal sort order to be by date with
    /// the newest at the top."* It already was; the date was the wrong one.
    ///
    /// Read from the filename's own `yyyy-MM-dd-HHmmss-` stamp, which every
    /// import writes and nothing edits, falling back to the filesystem's
    /// creation date. Declared last so no existing call site's argument order
    /// moves.
    var arrived: Date? = nil

    /// The date every LIST in either app sorts by and labels rows with: when it
    /// landed, falling back to the document's own date when nothing recorded an
    /// arrival.
    ///
    /// **One property so the order and the label cannot disagree.** A list that
    /// sorts on arrival while its rows print `created` reads as shuffled, and
    /// nothing on screen explains why - the two dates differ on exactly the
    /// documents where the order matters, which is bookings and confirmations.
    /// Every list in Satchel reads this; none reads `arrived` directly.
    ///
    /// `created` keeps its own job untouched: it is what the document SAYS, and
    /// it is what the Due band and the viewer show.
    var listDate: Date? { arrived ?? created }

    /// The `yyyy-MM-dd-HHmmss-` stamp every import writes at the front of a
    /// filename, or nil for a file that arrived some other way.
    ///
    /// **On the model because both stores need it**, the Mac since D347 and the
    /// phone since D381. It lived private inside `TraceMacDocumentStore`, and
    /// porting it would have meant a second copy of one fact - the mistake the
    /// week calculation made, where two definitions agreed all year and
    /// disagreed in a January nobody was watching. Same reasoning as
    /// `openableURL` below: one function, not two kept aligned.
    static func arrivalDate(fromFilename filename: String) -> Date? {
        guard filename.count > 18 else { return nil }
        let stamp = String(filename.prefix(17))
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = .current
        fmt.dateFormat = "yyyy-MM-dd-HHmmss"
        return fmt.date(from: stamp)
    }

    /// A website this document is ABOUT, typed by hand. Sidecar key `url`.
    ///
    /// David: *"I could use a URL field here that I could add when documents
    /// have a related website."*
    ///
    /// **Not the same thing as the Links row, and that is why it is stored.**
    /// `TraceMacTextExtraction.links(in:)` finds every address printed ON the
    /// page and is deliberately derived rather than saved - it cannot go stale
    /// and it costs no keys. This is the opposite case: the shuttle timetable
    /// that prompted it has no usable address in its own text, and the booking
    /// site he actually wants is a fact about the document that the document
    /// does not contain. Nothing can recompute that, so it has to be written
    /// down.
    ///
    /// A `String` rather than a `URL` so a half-typed address survives a save
    /// and reads back exactly as he left it. Whether it can be opened is a
    /// question the row asks at the moment it draws the button.
    ///
    /// Declared last so no existing call site's argument order moves.
    var url: String = ""

    /// Places this document is about, sidecar key `places` (D385, Session 101).
    ///
    /// **The one association the sidecar could not carry.** `endeavor`,
    /// `people` and `linked_note` were all in use; no sidecar anywhere held a
    /// place, and David asked for places by name when the scrapbook was
    /// designed: a link to a hotel's site is about the hotel. Same shape as
    /// `people`, a list of names, resolved the same way.
    ///
    /// Added to BOTH stores in one pass, key order fixed directly after
    /// `people`, for the reason D350 records: a store that rebuilds
    /// frontmatter without a key is a store that DELETES it. Declared last so
    /// no existing call site's argument order moves.
    var places: [String] = []

    // MARK: Reading shelf (D407, Session 105)
    //
    // Five optional keys, link documents only, all declared LAST so no existing
    // call site's argument order moves. Every one of them must exist in
    // `SidecarData`, `parseSidecar` and `renderSidecar` in BOTH stores — the Mac
    // gets no UI for any of this and must simply not destroy it. A key one store
    // does not know is a key that store DELETES on its next save; that is the
    // `remind` bug (Session 63) and the reason for the comment at the top of
    // `TraceMacDocumentStore`.

    /// What the page behind this link turned out to be, sidecar key `article`.
    ///
    /// `nil` means the fetch has never run. Otherwise see `ArticleState`.
    /// Written by the fetch; the manual flip edits it.
    var articleState: ArticleState? = nil

    /// Convenience for the one question most screens ask.
    var isArticle: Bool { articleState == .article }

    /// The day the article fetch ran for this link, sidecar key `fetched`,
    /// success or not.
    ///
    /// Its job is to stop the sweep retrying forever. Absent means never tried,
    /// which is the only state the sweep picks up. Retry clears it.
    var fetchedOn: Date? = nil

    /// Position in Up Next, ascending, sidecar key `read_next`.
    ///
    /// Exactly the `kitOrder` pattern: the order is saved and IS the order, so
    /// moving item 1 to fourth drops it off Home and keeps it on the Shelf.
    /// `nil` means the article is in New, which is where everything lands and
    /// where an article nobody touches sits forever at no cost.
    var readNext: Int? = nil

    /// The day this article was marked read, sidecar key `read`.
    ///
    /// Written by the deliberate Done tap at the end of the article or by the
    /// Read swipe on a New card, never automatically on scroll. Absent means
    /// unread; Keep for later clears it and the article returns to New.
    var readOn: Date? = nil

    /// How far through the text he got, 0.0–1.0, sidecar key `read_position`.
    ///
    /// A FRACTION rather than an offset so a change of text size does not lose
    /// the place. Written when the reader is left, not on every scroll: a key
    /// rewritten sixty times a minute is an iCloud sync storm and a sidecar
    /// whose modification date stops meaning anything.
    var readPosition: Double? = nil

    /// What a typed address opens to, or nil when it does not open to anything.
    ///
    /// **On the model rather than in either app's editor, because both draw the
    /// same button from the same string.** The Mac wrote this test first
    /// (D350) and Satchel needs precisely the same answer: a row that offered
    /// to open `kearney.com` on the phone and refused it on the Mac would be
    /// one field disagreeing with itself about what it holds, and the two
    /// copies would drift on the first fix made to only one of them.
    ///
    /// `URL(string:)` alone is far too generous - it accepts "denver airport"
    /// and hands back a relative URL with no host, which would give the row an
    /// open button that opens nothing. A host with a dot in it is the test that
    /// matches what people mean by a web address.
    ///
    /// A bare `kearney.com` is accepted and opened as `https://kearney.com`.
    /// What gets SAVED is still exactly what he typed: rewriting the field
    /// under the cursor is how a value stops matching the thing that produced
    /// it.
    /// One spelling of an address, for every purpose that has to decide whether
    /// two addresses are the same one.
    ///
    /// **It had two copies before this** (Session 103): `SatchelLinkPreview`
    /// and `MacLinkPreview` each carried an identical `normalised`, written for
    /// the D387 preview-cache key. D390's Save to Satchel needs the SAME answer
    /// for a different question — is this link already a document — and two
    /// copies of a rule that decides identity is how one app starts believing
    /// a link is new while another has its picture already cached. Both
    /// previews now call this; nobody re-derives it.
    ///
    /// `https://www.Example.com/` and `example.com` are one address. The query
    /// string is deliberately KEPT: a tracking parameter is noise, but so is a
    /// page id, and dropping the second to spite the first would merge two real
    /// pages into one record.
    static func normalisedURL(_ urlString: String) -> String {
        var s = urlString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasPrefix("http://") { s.removeFirst(7) }
        if s.hasPrefix("https://") { s.removeFirst(8) }
        if s.hasPrefix("www.") { s.removeFirst(4) }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    static func openableURL(_ text: String) -> URL? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let candidate = t.lowercased().hasPrefix("http://") || t.lowercased().hasPrefix("https://")
            ? t : "https://" + t
        guard let url = URL(string: candidate),
              let host = url.host, host.contains("."), !host.hasSuffix(".") else { return nil }
        return url
    }

    /// A web address as a phone-width label: host without `www.`, plus the last
    /// path component when it says something and the whole thing still fits on
    /// one line.
    ///
    /// **Here for the same reason `openableURL` is** (D355). Three screens draw
    /// this now - the Mac's Links row, Satchel's Links row, and Satchel's URL
    /// chip - and it was already copied byte for byte into two of them before
    /// the third asked for it. A label is a smaller thing to get wrong than a
    /// validator and it drifts the same way.
    static func webLabel(_ url: URL) -> String {
        var host = url.host ?? url.absoluteString
        if host.lowercased().hasPrefix("www.") { host = String(host.dropFirst(4)) }
        let last = url.pathComponents.last ?? ""
        if last.count > 1, last != "/", host.count + last.count < 44 {
            return "\(host)/\(last)"
        }
        return host
    }

    /// Tagged `private`. **The single definition, in the file every target
    /// compiles**, because this decides whether the document may be sent.
    ///
    /// Session 71 shipped this guard three times in three places and leaked
    /// three times: the automatic scan at capture, then the library's AI button,
    /// then the Summarise button that nobody had thought about. Each fix was a
    /// button. **A rule enforced per button is a rule you re-discover per
    /// button** — and David found each one, in minutes, by pressing it.
    var isPrivate: Bool {
        tags.contains { $0.caseInsensitiveCompare("private") == .orderedSame }
    }

    var isPDF: Bool   { fileExtension == "pdf" }
    var isImage: Bool { ["jpg","jpeg","png","heic","gif","webp"].contains(fileExtension) }
    /// A saved web link (D384): the file is a `.webloc`, the plist macOS writes
    /// when a link is dragged to Finder, and `url` carries the address it
    /// holds. A link keeps the two-file shape every other document has rather
    /// than becoming a sidecar with no file, which no store or viewer expects.
    var isLink: Bool { fileExtension == "webloc" }

    /// The address inside a `.webloc`, or nil when the bytes are not one.
    ///
    /// **On the model because three writers and two readers need it**: the
    /// share extension and Paste write the file, both stores read it back into
    /// `url` at load when the sidecar has none. One parser, not three kept
    /// aligned, per `arrivalDate(fromFilename:)` above.
    static func url(inWebloc data: Data) -> String? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = plist as? [String: Any],
              let url = dict["URL"] as? String else { return nil }
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The bytes of a `.webloc` holding `url`. XML plist, the form Finder
    /// itself writes, so the file opens in Safari from Finder and Quick Look
    /// reads it without help.
    static func weblocData(for url: String) -> Data? {
        let dict: [String: String] = ["URL": url.trimmingCharacters(in: .whitespacesAndNewlines)]
        return try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    }
    /// Plain text this app can read on screen rather than hand to another app
    /// (Session 95). Added for research documents, which are written as `.txt`
    /// — but a `.csv` or a `.log` dropped into Satchel is equally readable and
    /// was previously shown as an icon and a byte count.
    var isText: Bool { ["txt","md","markdown","csv","tsv","log","json"].contains(fileExtension) }

    /// Where this document's sidecar lives: the same path with the extension
    /// swapped for `.md`.
    ///
    /// **The comparison is case-insensitive, and it was not until Session 69.**
    /// `fileExtension` is lowercased when the store builds it
    /// (`TraceMacDocumentStore.reload`), but `hasSuffix` is not — so a file named
    /// `IMG_2528.PNG` failed the test, kept its extension, and got a sidecar at
    /// `IMG_2528.PNG.md` while `IMG_2528.png` would get `IMG_2528.md`. Two
    /// conventions decided by the case of three letters nobody chose.
    ///
    /// Self-consistent inside the app, which is why it survived: the same wrong
    /// name was written and read back. It surfaced the moment something else
    /// wrote a sidecar — the Dropzone `private` action put its tag at
    /// `IMG_2528.md`, the app looked at `IMG_2528.PNG.md`, found nothing, and
    /// scanned a document that had explicitly asked not to be.
    ///
    /// **iPhone screenshots arrive as `.PNG`.** This was not an edge case, it was
    /// every photo off the phone.
    var sidecarPath: String {
        let suffix = ".\(fileExtension)"          // already lowercased by the store
        let base = relativePath.lowercased().hasSuffix(suffix)
            ? String(relativePath.dropLast(suffix.count))
            : relativePath
        return "\(base).md"
    }

    // MARK: Rendering

    /// The icon to draw. Never nil — falls back to a type-based rule so a
    /// pre-Satchel document that has never been scanned still renders a
    /// sensible glyph instead of a blank tile.
    var resolvedIcon: DocumentIcon {
        if let icon { return icon }
        return Self.fallbackIcon(category: category, tags: tags, fileExtension: fileExtension)
    }

    /// The tint to draw. Never nil — an explicit tint wins, otherwise the
    /// resolved icon's own default, which keeps fallback documents coherent.
    var resolvedTint: DocumentTint {
        // **Colour follows the SUBJECT again (D344, 2026-09-07), reversing
        // Session 72 at David's word.** He asked twice, an hour apart, looking
        // at the same list: *"can we make many of the icons in satchel more
        // colorful. the ones at the top are all grey"*, then — once the Mac's
        // scanner finally answered the type question and painted them —
        // *"they are all blue. Id like different categories to have different
        // colors."*
        //
        // Both complaints are the same complaint, and Session 72's rule
        // produced both. Colour meaning TYPE is defensible in the abstract and
        // fails on his actual library: nearly everything he files is a booking
        // confirmation, so a colour keyed to type paints one hue down the
        // whole list and carries no information at all. Keyed to subject it
        // separates the flight from the hotel from the restaurant, which is
        // what he is scanning the list for.
        //
        // **A hand-set tint still wins**, and is now the only thing that writes
        // this field — the scanner no longer answers the tint question, so
        // `tint` means "David chose this" rather than "something chose this".
        // Set it back to Auto in the panel to fall through to the icon.
        //
        // The type axis is not lost. It is the Kind field, in words, where it
        // cannot be confused with anything else.
        tint ?? resolvedIcon.defaultTint
    }

    /// Type-based fallback: category first (it is the folder David filed it in,
    /// so it is the strongest signal available without a scan), then tags, then
    /// the file extension.
    static func fallbackIcon(category: String, tags: [String], fileExtension: String) -> DocumentIcon {
        let cat = category.lowercased()
        switch cat {
        case "trip", "travel":      return .plane
        case "place", "places":     return .home
        case "project", "projects": return .work
        case "medical", "health":   return .medical
        case "receipt", "receipts": return .receipt
        case "finance", "tax":      return .finance
        case "vehicle", "car":      return .car
        case "home", "house":       return .home
        default: break
        }

        let lowerTags = Set(tags.map { $0.lowercased() })
        let tagRules: [(String, DocumentIcon)] = [
            ("receipt", .receipt), ("invoice", .receipt), ("expense", .receipt),
            ("contract", .contract), ("lease", .contract), ("agreement", .contract),
            ("passport", .passport), ("visa", .passport),
            ("licence", .id), ("license", .id), ("id", .id),
            ("insurance", .card), ("card", .card),
            ("ticket", .ticket), ("voucher", .ticket),
            ("flight", .plane), ("boarding", .plane),
            ("rail", .train), ("train", .train),
            ("hotel", .lodging), ("booking", .lodging),
            ("medical", .medical), ("prescription", .medical),
            ("utility", .finance), ("bill", .finance),
            ("tax", .finance), ("statement", .finance),
            ("manual", .manual), ("warranty", .manual),
            ("legal", .legal), ("deed", .legal), ("will", .legal), ("mortgage", .legal),
            ("menu", .menu), ("restaurant", .menu),
            ("article", .reading), ("reading", .reading),
            ("paint", .home), ("maintenance", .home),
            ("map", .map), ("whiteboard", .photo)
        ]
        for (needle, icon) in tagRules where lowerTags.contains(needle) {
            return icon
        }

        if ["jpg","jpeg","png","heic","gif","webp"].contains(fileExtension) { return .photo }
        if fileExtension == "webloc" { return .link }
        return .document
    }
}

// MARK: - Scan result

struct DocumentScanResult {
    let tags: [String]          // suggested tags (lowercased)
    let description: String     // 1–2 sentence summary
    let title: String?          // suggested title; nil if filename is already human-readable
    let icon: DocumentIcon?     // suggested icon token; nil if the model returned nothing usable
    let tint: DocumentTint?     // suggested tint token; nil falls back to icon.defaultTint
    /// A date the document itself states as when it needs attention — ready
    /// for pickup, due, expires, appointment. 2026-08-27, David's call: set
    /// `remind:` from this automatically and mark it AI-filled, because *"a
    /// receipt with a pickup date that does not remind you"* is the failure
    /// the field exists to prevent. Appended last, per the rule on this struct.
    let remindOn: Date?
    /// The date the document is about — transaction, statement, event. Goes to
    /// the document's own date (`created`), not to `remind:`. A meal receipt's
    /// date is when it happened, and David agreed it should not remind.
    let datedOn: Date?
    /// Names from the caller's known-people list only; raw model output,
    /// re-filtered by the caller through `PeopleIndex.known` before use.
    let people: [String]

    init(
        tags: [String],
        description: String,
        title: String?,
        icon: DocumentIcon? = nil,
        tint: DocumentTint? = nil,
        remindOn: Date? = nil,
        datedOn: Date? = nil,
        people: [String] = []
    ) {
        self.tags = tags
        self.description = description
        self.title = title
        self.icon = icon
        self.tint = tint
        self.remindOn = remindOn
        self.datedOn = datedOn
        self.people = people
    }

    /// `"2026-08-15"` → that day, local calendar. Anything else, including
    /// `null` and prose, is nil. Shared by both scan services so the two
    /// platforms cannot drift on the format the prompt asks for.
    nonisolated static func parseRemind(_ raw: Any?) -> Date? {
        guard let s = raw as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count == 10, t.lowercased() != "null" else { return nil }
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: t)
    }
}

// MARK: - Buckets
//
// Session 72. David, looking at Megan's Wedding Week on the phone: *"for these
// travel endeavors, we have some sort of organization for the various notes and
// documents on IOS… i could have flight tickets for example or hotel
// confirmation documents, or dinner reservation screen shots or other
// attraction documents or notes."*
//
// **The key is `DocumentIcon`, which already exists and is already populated.**
// The scan model assigns exactly one per document ("what the document IS, not
// what it is about"), it is already drawn on every chip and row, and
// `SatchelIconPickerView` lets a wrong one be corrected by hand — so a document
// in the wrong bucket is a one-tap fix in the app that owns it. No new field, no
// picker at attach time, no migration, nothing to backfill. D119's argument
// again: this is readable off something already stored.
//
// **`tags:` was the obvious alternative and it is unusable for this.** Read the
// real ones: `[panera bread, pickup, order, receipt, illinois]`, `[album, music,
// rock, tom petty, wedding, wildflowers]`. They are model-written descriptions
// of content, near-unique per document, and would produce roughly ninety buckets
// over twenty-five files.
//
// **Bucketed on `resolvedIcon`, not on `icon`.** Only sixteen of about
// twenty-five sidecars carry an explicit `icon:` key today, and bucketing on the
// raw field would drop the other nine into `.other` while the chip beside them
// drew a perfectly good glyph from `fallbackIcon`. **The rule that matters: a
// document's group must agree with the picture on its own chip**, or the way to
// fix a wrong group stops being obvious. So both read the same property, and an
// unscanned document is typed by its category, tags and extension exactly as it
// is drawn.
//
// Linked notes are not documents and have no icon. They stay their own row.
enum DocumentBucket: String, CaseIterable, Hashable, Sendable {
    case travel
    case stay
    case tickets
    case food
    case receipts
    case papers
    case other

    /// David's own words for these, in his order.
    var label: String {
        switch self {
        case .travel:   return "Travel"
        case .stay:     return "Stay"
        case .tickets:  return "Tickets & Attractions"
        case .food:     return "Food"
        case .receipts: return "Receipts"
        case .papers:   return "Papers"
        case .other:    return "Other"
        }
    }

    /// Shorter, for the Mac rail, which is 232pt wide.
    var shortLabel: String {
        self == .tickets ? "Tickets" : label
    }

    /// The bucket's own glyph, not any member document's. Long-established SF
    /// Symbols only, for the reason `DocumentIcon.sfSymbol` states: a wrong
    /// symbol name fails silently at render rather than at compile.
    var sfSymbol: String {
        switch self {
        case .travel:   return "airplane"
        case .stay:     return "bed.double"
        case .tickets:  return "ticket"
        case .food:     return "fork.knife"
        case .receipts: return "banknote"
        case .papers:   return "doc.text"
        case .other:    return "tray"
        }
    }

    /// Which bucket an icon belongs to. `nil` — a document scanned before the
    /// icon field existed, or one the model declined to type — is `.other`
    /// rather than a fourth state, because "we do not know" and "none of the
    /// above" want the same row and the same fix.
    static func of(_ icon: DocumentIcon?) -> DocumentBucket {
        guard let icon else { return .other }
        switch icon {
        case .plane, .train, .car, .map:                 return .travel
        case .lodging, .home:                            return .stay
        case .ticket:                                    return .tickets
        case .menu:                                      return .food
        case .receipt, .card, .finance:                  return .receipts
        case .passport, .id, .contract, .legal,
             .medical, .work, .education, .pet:          return .papers
        case .document, .note, .photo, .reading, .manual, .link: return .other
        }
    }

    /// Documents grouped, in the fixed order above, empty buckets dropped.
    ///
    /// **Fixed order, not sorted by count.** A list whose rows move as documents
    /// are added is a list you have to re-read every time; travel-then-stay-then
    /// -tickets is the order of a trip and it holds still. `.other` is last by
    /// enum order, which is also where it belongs.
    static func group(_ documents: [TraceMacDocument]) -> [(bucket: DocumentBucket, documents: [TraceMacDocument])] {
        let byBucket = Dictionary(grouping: documents) { of($0.resolvedIcon) }
        return allCases.compactMap { bucket in
            guard let docs = byBucket[bucket], !docs.isEmpty else { return nil }
            return (bucket, docs)
        }
    }
}
