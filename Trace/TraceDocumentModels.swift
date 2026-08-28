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
        case .ticket:    return .indigo
        case .plane:     return .indigo
        case .train:     return .green
        case .car:       return .gray
        case .lodging:   return .rose
        case .medical:   return .red
        case .home:      return .green
        case .work:      return .blue
        case .finance:   return .amber
        case .education: return .indigo
        case .photo:     return .gray
        case .map:       return .teal
        case .note:      return .blue
        case .manual:    return .gray
        case .menu:      return .rose
        case .reading:   return .teal
        case .pet:       return .green
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
        // Session 72: `.gray`, not the icon's swatch colour. Colour is the
        // document's TYPE now (receipt, confirmation, reference…), which an
        // icon cannot imply — so an untyped document is honestly uncoloured
        // rather than borrowing a hue that means something else.
        tint ?? .gray
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
        case .document, .note, .photo, .reading, .manual: return .other
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
