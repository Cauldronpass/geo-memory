// DocumentScanService.swift
// Uses Claude to extract tags and a short description from a document (PDF or image).
// Mac-only — do not add to iOS, Widget, or Share Extension targets.

import Foundation
import PDFKit
import AppKit

// DocumentScanResult is defined in TraceDocumentModels.swift (shared).

// MARK: - Errors

enum DocumentScanError: LocalizedError {
    /// Tagged `private`. See `TraceMacDocument.isPrivate`. The view's dialog
    /// explains; this enforces.
    case isPrivate
    case noContent
    case apiError(String)
    case parseError(String)
    case unsupportedFormat
    case noKey

    var errorDescription: String? {
        switch self {
        case .isPrivate:             return "This document is tagged private. Nothing about it has been sent."
        case .noContent:             return "Claude returned no content."
        case .apiError(let msg):     return "API error: \(msg)"
        case .parseError(let msg):   return "Parse error: \(msg)"
        case .unsupportedFormat:     return "Unsupported file format."
        case .noKey:
            // Session 63 (2026-08-02). David saw the raw 401 JSON printed under
            // a document: `{"type":"error","error":{"type":"authentication_error"
            // ,"message":"API key is invalid."}}`.
            //
            // The key lives in App Group `UserDefaults`, and **App Groups are
            // per-device** — they share between apps on one machine, not
            // between a Mac and an iPhone. The key entered on the phone was
            // never going to be here. That is configuration, not a fault, and
            // the app should say which one rather than making a doomed call
            // and pasting the server's reply on screen.
            return "No Claude API key on this Mac. Add one in Settings (⌘,). "
                 + "Keys are stored per-device, so the one on your iPhone does not carry over."
        }
    }
}

// MARK: - What a confirmation turned into

/// A dropped confirmation, read into the fields `MacBookingSheet` already has
/// (D319, Session 92).
///
/// **Every field is optional and nothing here is written anywhere.** This is a
/// seed for a sheet, not a record: David corrects it and presses Save, and the
/// save is the ordinary `NotionService.saveBooking` every other row goes
/// through. A parse that guessed badly costs him a correction; a parse that
/// wrote would cost him a row he did not ask for.
///
/// **`found` is the count the document holds, not the count returned.** A
/// return flight is one PDF with two legs, and v1 seeds the first and says so
/// at the top of the sheet. Silently seeding one of two would be the Session 86
/// class of bug — a screen reporting an absence that is not true.
struct BookingParse {
    /// One of `MacBookingSheet.kinds`, or nil when the document did not say.
    var kind: String?         = nil
    /// "United", "Marriott", "Go Airport Shuttle".
    var provider: String?     = nil
    /// Flight number, job number, reservation number.
    var number: String?       = nil
    var confirmation: String? = nil
    /// Airport or city. Nil on a hotel, which has no from.
    var from: String?         = nil
    /// Airport or city; on a hotel, the property's city.
    var to: String?           = nil
    /// Departure, or check-in.
    var start: Date?          = nil
    /// Arrival, or check-out.
    var end: Date?            = nil
    /// False for a hotel with no clock time on it. The sheet's Include times.
    var hasTime: Bool         = false
    var cost: Double?         = nil
    /// Recorded, never converted. The sheet is USD; a euro figure typed into it
    /// silently means something else, so it is said in the notes instead.
    var currency: String?     = nil
    /// Bookings the document holds. 0 means nothing was read.
    var found: Int            = 0
    var notes: String?        = nil
    /// Set when the year the model returned is not a year the document prints
    /// (D330). Shown at the top of the sheet, above the fields it is about.
    var dateWarning: String?  = nil

    /// True when there is something worth putting on a sheet.
    ///
    /// A date alone is not enough — every confirmation has a date somewhere and
    /// a sheet seeded with only a date looks read when it was not.
    var hasAnything: Bool {
        kind != nil || provider != nil || number != nil
            || confirmation != nil || from != nil || to != nil || cost != nil
    }
}

// MARK: - What a sentence turned into

/// An endeavor described in plain language, read into the fields
/// `MacEndeavorSheet` already has (D317, D321, Session 93).
///
/// **Every field is optional and nothing here is written anywhere.** Same rule
/// as `BookingParse`: this is a seed for a sheet, not a record. David corrects
/// it and presses Create, and the create is the ordinary
/// `TraceMacEndeavorStore.create` the `+` already calls.
///
/// **`peopleNamed` and `placesNamed` are RAW names.** Whether a name is
/// somebody in Notion is decided in code, against `notionService.people` and
/// `.places`, case-insensitively — never by asking the model whether it knows
/// them. D330's rule, generalised: the model never supplies a value the source
/// already states.
struct EndeavorDraft {
    var name: String?        = nil
    /// One of `Endeavor.offeredTypes`, or nil when the sentence did not say.
    var type: String?        = nil
    var starts: Date?        = nil
    var ends: Date?          = nil
    /// Where it is. Also the cover search term, which is why filling it is all
    /// the banner needs (D321) and why there is no photo code to write.
    var destination: String? = nil
    /// Prose for the note's `## Summary`, in the endeavor's own skeleton.
    var summary: String?     = nil
    var peopleNamed: [String] = []
    var placesNamed: [String] = []

    /// True when there is something worth putting on a sheet.
    var hasAnything: Bool {
        (name?.isEmpty == false) || type != nil || starts != nil
            || (destination?.isEmpty == false) || (summary?.isEmpty == false)
            || !peopleNamed.isEmpty || !placesNamed.isEmpty
    }
}

/// One name the sentence produced, after the app has looked it up (D321).
///
/// **`exists` is decided in code, never by the model.** The draft carries raw
/// names; whether "Hannah" is somebody in Notion is answered by
/// `notionService.people`, which is the authority. D330's rule generalised: the
/// model never supplies a value the app can already look up.
///
/// **`resolvedName` is what gets written.** A sentence says "Hannah" and the
/// record is "Hannah Weiss"; the endeavor should carry the record's name, not
/// the nickname, or the link stops resolving. For an unmatched name the two are
/// the same string.
struct EndeavorSeedName: Identifiable, Hashable {
    enum Kind: Hashable { case person, place }
    /// As the sentence wrote it.
    let name: String
    /// As Notion has it, or `name` when nothing matched.
    let resolvedName: String
    let kind: Kind
    let exists: Bool
    var id: String { "\(kind)-\(name.lowercased())" }
}

// MARK: - Service

enum DocumentScanService {

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let model    = "claude-haiku-4-5-20251001"   // fast + cheap for metadata extraction

    /// The confirmation parse only (D327). Ask's model, `TraceMacAskService`.
    ///
    /// **Haiku was tried and it could not hold a date.** Two runs over the same
    /// United PDF returned the same flight number and confirmation code and two
    /// different dates and two different fares — 24 Feb / $300, then 12 May /
    /// $200 — both in 2026, on a document printing 2024 twice. Two prompt
    /// rewrites did not move it, and instability across runs on fields the
    /// document states plainly is a capability signal, not a wording one. The
    /// starter for this session named this exact escalation in advance.
    ///
    /// **Scoped to this one call.** `scan` stays on Haiku: tags and a
    /// one-sentence description are what it is good at, it runs on every
    /// document that arrives, and nothing about it has ever been wrong this way.
    private static let bookingModel = "claude-sonnet-5"

    private static var apiKey: String {
        // Was a direct `UserDefaults(suiteName:)` read. Routed through
        // `ClaudeKeyStore` on 2026-08-11 so the macOS keychain applies here
        // too — a bypass of the single accessor is a call site that keeps
        // reading the plaintext copy after it has been emptied.
        ClaudeKeyStore.key
    }

    // MARK: - Public entry point

    /// Scans a document and returns suggested tags + description.
    /// - Parameters:
    ///   - doc: The document to scan.
    ///   - noteStore: Used to resolve the file URL.
    ///   - existingTags: All tags already in use across the library — Claude will prefer these.
    static func scan(
        doc: TraceMacDocument,
        noteStore: NoteStore,
        existingTags: [String],
        userContext: String = "",
        knownPeople: [String] = []
    ) async throws -> DocumentScanResult {
        // Before everything, including the key check: a private document is not
        // sent for any reason, and the cheapest possible refusal is the right
        // one.
        guard !doc.isPrivate else { throw DocumentScanError.isPrivate }
        // Checked before any work: rendering pages and base64-encoding an image
        // only to be told the request was unauthenticated wastes time and, on a
        // large scan, a noticeable amount of it.
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DocumentScanError.noKey
        }

        guard let fileURL = noteStore.resolvedURL(for: doc.relativePath) else {
            throw DocumentScanError.noContent
        }

        if doc.isPDF {
            return try await scanPDF(at: fileURL, filename: doc.filename, existingTags: existingTags, userContext: userContext, knownPeople: knownPeople)
        } else if doc.isImage {
            return try await scanImage(at: fileURL, filename: doc.filename, existingTags: existingTags, userContext: userContext, knownPeople: knownPeople)
        } else {
            throw DocumentScanError.unsupportedFormat
        }
    }

    // MARK: - Create parsing (D317, D321, Session 93)

    /// Turns a sentence into the fields of the New Endeavor sheet.
    ///
    /// **Today's date is sent here, and unlike D327 that is correct.** A
    /// confirmation prints its own year and a model substituting the current
    /// one is reading past the page; a SENTENCE says "over spring break" and
    /// means the next one, so the current date is the only thing that can
    /// resolve it. Different source, different rule, stated so the two are not
    /// confused later.
    ///
    /// **Names come back raw.** Whether "Hannah" is somebody in Notion is
    /// decided in code against `notionService.people`, never by asking the model
    /// whether it knows her. D330's rule generalised: the model never supplies a
    /// value the app can already look up.
    static func parseEndeavor(brief: String) async throws -> EndeavorDraft {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DocumentScanError.noKey
        }

        let today = DateFormatter()
        today.dateFormat = "yyyy-MM-dd"
        let stamp = today.string(from: Date())

        let prompt = """
        Someone is describing something they are planning, in one or two sentences. Turn it into the fields below. Return JSON only — no explanation, no markdown fences.

        Today is \(stamp). Use it to resolve relative timing the sentence implies — "next spring", "over Thanksgiving", "in three weeks". Do not invent dates the sentence does not imply.

        Return exactly this structure:
        {
          "name": "Four Days in Savannah",
          "type": "Travel",
          "starts": "2027-03-13",
          "ends": "2027-03-17",
          "destination": "Savannah",
          "summary": "Four days in Savannah over spring break, driving down from Chicago.",
          "people": ["Hannah"],
          "places": ["Savannah"]
        }

        Rules:
        - name: a short title for it, 2 to 5 words, title case. Not a sentence. Null only if the text names nothing at all.
        - type: exactly one of Travel, Milestone, Gathering, Project, Decision. Travel is a trip. Milestone is a dated life event like a graduation or a wedding. Gathering is people coming together without travel being the point. Project is work with an outcome. Decision is a choice being weighed between options. Null if none of the five fits.
        - starts / ends: "YYYY-MM-DD". Null when the text implies no date. A single day gives the same date twice. Never guess a date from the type — a trip with no timing stated has no dates.
        - destination: where it happens, as a person would say it — "Savannah", "Fort Collins, CO", "Kyoto". Null for anything not tied to a place.
        - summary: one short paragraph in plain prose, written back to the person as a statement of what this is. Their own words and facts, nothing added. Two or three sentences at most.
        - people: every person the text names, exactly as written, first names included. [] if none.
        - places: every place the text names. [] if none. The destination may also appear here.
        - Never invent a person, a place, a date or a detail the text does not contain. A field the text does not support is null or empty.
        - Return valid JSON only. No other text.

        The text:
        \(brief)
        """

        let body = requestBody(textPrompt: prompt, maxTokens: 900, modelName: bookingModel)
        let raw = try await sendRaw(body: body)
        return try decodeEndeavor(raw)
    }

    private static func decodeEndeavor(_ cleaned: String) throws -> EndeavorDraft {
        guard let data = cleaned.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DocumentScanError.parseError("Could not parse JSON: \(cleaned.prefix(200))")
        }

        func string(_ key: String) -> String? {
            guard let raw = obj[key] as? String else { return nil }
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, t.lowercased() != "null" else { return nil }
            return t
        }
        func names(_ key: String) -> [String] {
            (obj[key] as? [String] ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }

        var draft = EndeavorDraft()
        draft.name = string("name")
        // Matched against the five in code. A sixth type the model invented is
        // not a type this app has, and the sheet's picker would silently show
        // Travel instead — the exact data loss D268's `types` note describes.
        draft.type = string("type").flatMap { candidate in
            Endeavor.offeredTypes.first { $0.lowercased() == candidate.lowercased() }
        }
        draft.starts      = localDate(obj["starts"]).date
        draft.ends        = localDate(obj["ends"]).date
        draft.destination = string("destination")
        draft.summary     = string("summary")
        draft.peopleNamed = names("people")
        draft.placesNamed = names("places")
        return draft
    }

    // MARK: - Confirmation parsing (D319, Session 92)

    /// Reads a dropped confirmation into booking fields.
    ///
    /// **The private guard is first, in the same position `scan` puts it**, and
    /// for the same reason: a document that must not leave the Mac must be
    /// refused before the key is checked, before the file is opened, and before
    /// anything is encoded. `Read privately` never reaches this entry point at
    /// all — it tags and then goes to `MacLocalIntelligence` — but a second
    /// caller arriving later must hit the same wall this one does.
    ///
    /// Throws rather than returning an empty parse, so the caller can tell
    /// "could not read it" from "read it and it holds no booking". Both open
    /// the same sheet with the same line; keeping them distinct here costs
    /// nothing and a future third answer will need it.
    static func parseBooking(doc: TraceMacDocument, noteStore: NoteStore) async throws -> BookingParse {
        guard !doc.isPrivate else { throw DocumentScanError.isPrivate }
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DocumentScanError.noKey
        }
        guard let fileURL = noteStore.resolvedURL(for: doc.relativePath) else {
            throw DocumentScanError.noContent
        }

        let prompt = bookingPrompt()

        if doc.isPDF {
            guard let pdf = PDFDocument(url: fileURL) else { throw DocumentScanError.noContent }
            // Six pages rather than `scan`'s four. A confirmation email printed
            // to PDF puts the fare breakdown and the confirmation code on
            // different pages, and the useful half is often the second one.
            var text = ""
            for i in 0..<min(pdf.pageCount, 6) {
                if let page = pdf.page(at: i), let s = page.string { text += s + "\n" }
            }
            let preview = String(text.prefix(8_000))
            let years = documentYears(preview)
            // **The same letters-or-digits test the scan path uses**, not
            // "non-empty", so the two cannot disagree about which PDFs have a
            // text layer and fall back differently on the same file.
            if preview.contains(where: { $0.isLetter || $0.isNumber }) {
                let body = requestBody(textPrompt: bookingPrompt(printedYears: years)
                                            + "\n\nDocument text:\n" + preview,
                                       maxTokens: 900, modelName: bookingModel)
                let raw = try await sendRaw(body: body)
                var parse = try decodeBooking(raw)
                // The prompt asks; this checks. Asking has failed on two models.
                reconcileYear(&parse, printed: years)
                return parse
            }
            // No text layer — a scanned or photographed confirmation. Same
            // branch `scanPDF` takes, for the same reason.
            guard let page = pdf.page(at: 0), let rendered = renderPageImage(page) else {
                throw DocumentScanError.noContent
            }
            let body = requestBody(imageData: rendered, textPrompt: prompt, maxTokens: 900,
                                   modelName: bookingModel)
            let raw = try await sendRaw(body: body)
            return try decodeBooking(raw)
        }

        if doc.isImage {
            try? FileManager.default.startDownloadingUbiquitousItem(at: fileURL)
            guard let raw = try? Data(contentsOf: fileURL), !raw.isEmpty else {
                throw DocumentScanError.apiError("Could not read the image — it may still be downloading from iCloud.")
            }
            let imageData = resizedImageData(raw, maxDimension: 1600) ?? raw
            let body = requestBody(imageData: imageData, textPrompt: prompt, maxTokens: 900,
                                   modelName: bookingModel)
            let answer = try await sendRaw(body: body)
            return try decodeBooking(answer)
        }

        throw DocumentScanError.unsupportedFormat
    }

    /// Reads a confirmation on this Mac, for a document tagged `private` (D322).
    ///
    /// **Nothing here touches the network**, which is the entire reason the
    /// verb exists. The text comes off the file by `MacTextExtraction` — the
    /// PDF's own text layer, or Vision on the pages of a scanned one — and goes
    /// to Apple's on-device model.
    ///
    /// **The extraction is detached because it must not run on the main
    /// thread.** `MacTextExtraction` says so in its own header: Vision on a full
    /// page is tens of milliseconds and a scanned PDF is that per page. This
    /// file is main-actor isolated by the project's default, so the hop is
    /// explicit rather than accidental.
    ///
    /// Returns `nil` for every failure — no model on this Mac, no readable
    /// text, a model that returned nothing usable. The caller shows the same
    /// empty sheet and the same line as an unreadable document, because from
    /// where David is standing that is what happened.
    static func parseBookingLocally(doc: TraceMacDocument, noteStore: NoteStore) async -> BookingParse? {
        guard let url = noteStore.resolvedURL(for: doc.relativePath) else { return nil }

        let text = await Task.detached { MacTextExtraction.extract(from: url) }.value
        guard let text, text.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        guard let facts = await MacLocalIntelligence.parseBooking(text: text) else { return nil }

        func value(_ raw: String) -> String? {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, t.lowercased() != "null", t.lowercased() != "n/a" else { return nil }
            return t
        }

        var parse = BookingParse()
        parse.kind = value(facts.kind).flatMap { candidate in
            MacBookingSheet.kinds.first { $0.lowercased() == candidate.lowercased() }
        }
        parse.provider     = value(facts.provider)
        parse.number       = value(facts.number)
        parse.confirmation = value(facts.confirmation)
        parse.from         = value(facts.from)
        parse.to           = value(facts.to)

        let startPair = localDate(facts.start)
        parse.start   = startPair.date
        parse.hasTime = startPair.hasTime
        parse.end     = localDate(facts.end).date

        if let raw = value(facts.cost) {
            let digits = raw.filter { $0.isNumber || $0 == "." }
            if let amount = Double(digits), amount > 0 { parse.cost = amount }
        }

        // Same rule the cloud decode uses: fields without a count is one
        // booking, and no fields at all is nothing read.
        parse.found = parse.hasAnything ? 1 : 0
        // And the same year check. A smaller model is likelier to need it, not
        // less, and the text is already in hand.
        reconcileYear(&parse, printed: documentYears(text))
        return parse.hasAnything ? parse : nil
    }

    /// Every four-digit year the document prints.
    ///
    /// **Bounded by non-digits, and bounded to 1900–2099**, which is what keeps
    /// a flight number out of it: `UA1898` yields 1898 and 1898 is not a year
    /// this rule will accept. A fare of `2024.00` will land in the set, and
    /// that is a false positive worth taking — the set is only ever used to
    /// widen what is allowed, never to narrow it.
    private static func documentYears(_ text: String) -> Set<Int> {
        var years: Set<Int> = []
        var run = ""
        func flush() {
            if run.count == 4, let value = Int(run), (1900...2099).contains(value) {
                years.insert(value)
            }
            run = ""
        }
        for ch in text {
            if ch.isNumber { run.append(ch) } else { flush() }
        }
        flush()
        return years
    }

    /// Puts the parsed dates back into a year the document actually prints
    /// (D330).
    ///
    /// **This exists because two prompts and two models could not stop a model
    /// dating an old confirmation to this year.** The document is the authority
    /// on what year it is about, and the years it prints are a fact that can be
    /// read without asking anyone. A model that returns a year the paper does
    /// not contain has not read it off the paper.
    ///
    /// **One printed year: snap to it, and say so.** That is the overwhelming
    /// case — a confirmation is about one trip in one year — and it is a
    /// correction the sheet can state in a line rather than a guess it has to
    /// hide.
    ///
    /// **More than one: change nothing, and say THAT.** Choosing between 2024
    /// and 2025 by rule would be inventing an answer, which is the thing being
    /// fixed. A flagged date David checks beats a silently corrected one he
    /// does not. Warning TWELVE.
    ///
    /// Never fires when the model's year is already on the document, which is
    /// the normal case, so a correct parse is untouched.
    private static func reconcileYear(_ parse: inout BookingParse, printed: Set<Int>) {
        guard let start = parse.start, !printed.isEmpty else { return }
        let cal = Calendar.current
        let read = cal.component(.year, from: start)
        guard !printed.contains(read) else { return }

        guard printed.count == 1, let only = printed.first else {
            parse.dateWarning = "Check the date — this document does not print \(read) anywhere."
            return
        }

        func moved(_ date: Date) -> Date {
            var parts = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            parts.year = only
            return cal.date(from: parts) ?? date
        }
        parse.start = moved(start)
        if let end = parse.end { parse.end = moved(end) }
        parse.dateWarning = "Year corrected to \(only), the only year on the document. It was read as \(read)."
    }

    /// What the model is asked for.
    ///
    /// **The field descriptions are `BookingKind.help(for:)`'s own words**, cut
    /// down to what a reader of a confirmation needs. David asked for exactly
    /// that, and the reason is that the sheet's info popover and this prompt
    /// must mean the same thing by "Number" — one of them is what he reads when
    /// he forgets, and the other is what decides where the string lands.
    ///
    /// **Today's date is given for one purpose and it is stated.** A boarding
    /// pass often prints "25 NOV" with no year, and a model with no idea what
    /// day it is will pick one. It resolves a missing year; it never supplies a
    /// missing date.
    private static func bookingPrompt(printedYears: Set<Int> = []) -> String {
        let today = DateFormatter()
        today.dateFormat = "yyyy-MM-dd"
        let stamp = today.string(from: Date())

        // Built as a statement rather than a ternary chain: a trailing closure
        // sitting after `:` and between two `+` is exactly the shape Swift's
        // parser reads two ways.
        var yearLine = ""
        if !printedYears.isEmpty {
            let list = printedYears.sorted().map({ String($0) }).joined(separator: ", ")
            yearLine = "\n        - The only years printed anywhere on this document are: "
                     + list + ". Every date you return must use one of them."
        }

        return """
        You are reading a travel or service confirmation. Return JSON only — no explanation, no markdown fences.

        Today is \(stamp), given for one purpose only: see the year rule below. Never invent a date the document does not state.

        Return exactly this structure:
        {
          "found": 1,
          "kind": "Flight",
          "provider": "United",
          "number": "UA 1642",
          "confirmation": "K4M2QP",
          "from": "ORD",
          "to": "DEN",
          "start": "2026-11-25T17:40",
          "end": "2026-11-25T19:12",
          "cost": 318.40,
          "currency": "USD",
          "notes": null
        }

        Rules:
        - found: how many separate bookings this document holds. A round trip printed as two flights is 2. One hotel stay is 1. If it holds no booking at all, return 0 and null for every other field.
        - Describe the FIRST booking only. Ignore the rest.
        - kind: exactly one of Flight, Shuttle, Train, Hotel, Car rental, Parking, Other. Null if it is none of those.
        - provider: who is providing it — the airline, the hotel brand, the rental company, the shuttle operator.
        - number: their reference for the thing itself, the one printed on the ticket or the door — a flight number, a room number, a rental reservation number. Null if none is printed.
        - confirmation: the booking reference you would read out on the phone. Rarely the same string as number; return both when both are printed.
        - from: where it starts from — airport code or city. Null for a hotel or a car park, which have no from.
        - to: where it goes; for a stay, where it IS — the property's city, or the car park.
        - start: departure, check-in, or pick-up. "YYYY-MM-DDTHH:mm" when a clock time is printed, "YYYY-MM-DD" when only a day is. Local time exactly as printed; do not convert between timezones.
        - end: arrival, check-out, or drop-off, in the same two formats. Null when the document states only one end.
        - cost: the total charged, as a plain number with no currency symbol and no thousands separator. Null when no figure is printed. Never estimate one.
        - currency: the ISO code of that figure, e.g. "USD", "EUR". Null when cost is null.
        - notes: anything printed that matters and fits none of the fields above — a seat, a gate, a cancellation deadline, a pickup instruction. One short sentence, or null.
        - YEARS. Use the year printed beside the travel date. If none is printed there, take it from another date on the document — an email header, an issue or purchase date, a printed footer. Only when the document shows no year anywhere at all, use today's. **Never move a date into a different year to make it look upcoming.** An old confirmation is an old confirmation.
        - Every field the document does not state is null. Guessing is worse than null.
        - Return valid JSON only. No other text.\(yearLine)
        """
    }

    /// Turns the model's JSON into a `BookingParse`.
    ///
    /// **Shape is not trusted, only meaning** — the same rule
    /// `MacLocalIntelligence.clean` states. A cost can come back as `318.40`,
    /// `"318.40"` or `"$318.40"`, and a Kind can come back correct but
    /// lowercase. Fixing that here is cheaper than explaining it in the prompt
    /// and, unlike the prompt, it cannot be ignored.
    private static func decodeBooking(_ cleaned: String) throws -> BookingParse {
        guard let data = cleaned.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DocumentScanError.parseError("Could not parse JSON: \(cleaned.prefix(200))")
        }

        func string(_ key: String) -> String? {
            guard let raw = obj[key] as? String else { return nil }
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, t.lowercased() != "null" else { return nil }
            return t
        }

        var parse = BookingParse()
        parse.kind = string("kind").flatMap { candidate in
            MacBookingSheet.kinds.first { $0.lowercased() == candidate.lowercased() }
        }
        parse.provider     = string("provider")
        parse.number       = string("number")
        parse.confirmation = string("confirmation")
        parse.from         = string("from")
        parse.to           = string("to")
        parse.notes        = string("notes")
        parse.currency     = string("currency")

        let startPair = localDate(obj["start"])
        let endPair   = localDate(obj["end"])
        parse.start   = startPair.date
        parse.end     = endPair.date
        // **One flag for the row, taken from the start.** The sheet has a
        // single Include times, because a booking that departs at a clock time
        // and arrives on a day is not a shape it can save. Start is the half he
        // is standing in front of.
        parse.hasTime = startPair.hasTime

        if let n = obj["cost"] as? NSNumber {
            parse.cost = n.doubleValue > 0 ? n.doubleValue : nil
        } else if let s = string("cost") {
            let cleanedCost = s.filter { $0.isNumber || $0 == "." }
            if let value = Double(cleanedCost), value > 0 { parse.cost = value }
        }
        if parse.cost == nil { parse.currency = nil }

        if let n = obj["found"] as? NSNumber {
            parse.found = n.intValue
        } else if let s = string("found"), let value = Int(s) {
            parse.found = value
        }
        // A model that filled the fields and forgot the count has found one.
        // Leaving it at zero would put "Couldn't read this document" above a
        // sheet that is plainly full.
        if parse.found == 0, parse.hasAnything { parse.found = 1 }

        return parse
    }

    /// `"2026-11-25T17:40"` or `"2026-11-25"`, read in this Mac's timezone.
    ///
    /// **Local, not UTC.** A confirmation prints the time at the airport it
    /// leaves from, and the sheet shows what it is given. Parsing 17:40 as UTC
    /// would put a Denver departure on screen at 11:40, which is a wrong answer
    /// that looks like a right one.
    private static func localDate(_ raw: Any?) -> (date: Date?, hasTime: Bool) {
        guard let s = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty, s.lowercased() != "null" else { return (nil, false) }

        let withTime = DateFormatter()
        withTime.locale = Locale(identifier: "en_US_POSIX")
        withTime.timeZone = .current
        withTime.dateFormat = "yyyy-MM-dd'T'HH:mm"
        if let d = withTime.date(from: String(s.prefix(16))), s.count >= 16 {
            return (d, true)
        }

        let dayOnly = DateFormatter()
        dayOnly.locale = Locale(identifier: "en_US_POSIX")
        dayOnly.timeZone = .current
        dayOnly.dateFormat = "yyyy-MM-dd"
        if let d = dayOnly.date(from: String(s.prefix(10))) {
            return (d, false)
        }
        return (nil, false)
    }

    // MARK: - PDF scanning

    /// Scans a PDF, falling back to reading the first page as an image when the
    /// file has no text layer.
    ///
    /// **This is a port of the fix iOS already had**, and the divergence is the
    /// point. `IOSDocumentScanService.scanPDF` has carried the image fallback
    /// for months, with a comment naming the symptom: *"every scanned document
    /// silently got no AI at all, which is why scans stayed titled scan while
    /// camera photos came back fully described."* The Mac's copy was never
    /// touched and threw `.noContent` instead — so a scanned PDF dropped on the
    /// Mac, through Dropzone or the window, got no title, no tags and no
    /// description, and nothing on screen said why.
    ///
    /// Exactly the shape of the Satchel Inbox migration in Session 69: one
    /// writer got the change and the other did not, for two weeks, with nobody
    /// noticing because each app looked correct on its own.
    ///
    /// **Corrected on the way in.** The claim that opened this — that David's
    /// two phone scans had no metadata — was wrong, and his own container said
    /// so: both carry an accurate AI title and description, written by the phone
    /// through this very fallback. The bug is real but its blast radius is
    /// Mac-side capture only. Checking before asserting cost one `cat`.
    private static func scanPDF(at url: URL, filename: String, existingTags: [String], userContext: String, knownPeople: [String] = []) async throws -> DocumentScanResult {
        guard let pdf = PDFDocument(url: url) else {
            throw DocumentScanError.noContent
        }

        // Extract text from up to the first 4 pages (enough for metadata, avoids huge prompts)
        var extractedText = ""
        let pageLimit = min(pdf.pageCount, 4)
        for i in 0..<pageLimit {
            if let page = pdf.page(at: i), let text = page.string {
                extractedText += text + "\n"
            }
        }

        // **Letters or digits, not "non-empty".** Deliberately the same test
        // `MacTextExtraction.fromPDF` uses to decide whether to OCR. If the two
        // disagreed about which PDFs have a text layer, one of them would fall
        // back and the other would not, on the same file.
        let textPreview = String(extractedText.prefix(3000))   // cap at ~3k chars
        guard textPreview.contains(where: { $0.isLetter || $0.isNumber }) else {
            // No text layer. Render page one and let the model read it.
            //
            // **The rendered image, not the sidecar's OCR.** Both were on the
            // table and the image wins on evidence: the OCR of David's tuxedo
            // receipt opens *"The Mer'a Wearhouee, Inc."*, while the description
            // the phone produced from the same page image names the store, the
            // total and the event date correctly. Vision is good enough to make
            // a receipt findable and not good enough to summarise from. It also
            // costs nothing extra — this runs once per document either way.
            guard let page = pdf.page(at: 0), let rendered = renderPageImage(page) else {
                throw DocumentScanError.noContent
            }
            let imagePrompt = buildPrompt(content: nil, existingTags: existingTags,
                                          isText: false, filename: filename,
                                          userContext: userContext, knownPeople: knownPeople)
            return try await callClaude(imageData: rendered, textPrompt: imagePrompt)
        }

        let prompt = buildPrompt(content: textPreview, existingTags: existingTags, isText: true, filename: filename, userContext: userContext, knownPeople: knownPeople)
        return try await callClaude(textPrompt: prompt)
    }

    /// A PDF page as JPEG bytes, for the no-text-layer path above.
    ///
    /// Same numbers as `IOSDocumentScanService.renderPageImage` — 1600 on the
    /// long edge, capped at 4× — because the two now feed the same model the
    /// same kind of input and a difference here would be a difference nobody
    /// chose. `NSImage.jpegData` is TraceMac's own, in `TraceMacColors.swift`;
    /// it uses `CGImageDestination` rather than `NSBitmapImageRep`, which
    /// silently emits PNG when the image has alpha.
    private static func renderPageImage(_ page: PDFPage) -> Data? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(1600 / max(bounds.width, bounds.height), 4)
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        return page.thumbnail(of: size, for: .mediaBox).jpegData(compressionQuality: 0.8)
    }

    // MARK: - Image scanning

    private static func scanImage(at url: URL, filename: String, existingTags: [String], userContext: String, knownPeople: [String] = []) async throws -> DocumentScanResult {
        // Trigger iCloud download if the file is a cloud placeholder
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)

        guard let rawData = try? Data(contentsOf: url), !rawData.isEmpty else {
            throw DocumentScanError.apiError("Could not read image file — it may still be downloading from iCloud.")
        }

        // Resize large images before encoding: Claude's API rejects base64 payloads over ~5 MB.
        // Document scanner images can easily be 4–8 MB; cap the long edge at 1600 px.
        let imageData = resizedImageData(rawData, maxDimension: 1600) ?? rawData

        let prompt = buildPrompt(content: nil, existingTags: existingTags, isText: false, filename: filename, userContext: userContext, knownPeople: knownPeople)
        return try await callClaude(imageData: imageData, textPrompt: prompt)
    }

    /// Returns JPEG data with the long edge capped at `maxDimension`. Returns nil if the image
    /// can't be decoded (caller should fall back to the original data).
    private static func resizedImageData(_ data: Data, maxDimension: CGFloat) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth]  as? CGFloat,
              let h = props[kCGImagePropertyPixelHeight] as? CGFloat else { return nil }

        let longEdge = max(w, h)
        guard longEdge > maxDimension else { return nil }   // already small enough

        let scale  = maxDimension / longEdge
        let newW   = Int(w * scale)
        let newH   = Int(h * scale)

        guard let cgImage = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }

        let ctx = CGContext(
            data: nil,
            width: newW, height: newH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )
        ctx?.draw(cgImage, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        guard let resized = ctx?.makeImage() else { return nil }

        let dest = NSMutableData()
        guard let destRef = CGImageDestinationCreateWithData(dest, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destRef, resized, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destRef) else { return nil }
        return dest as Data
    }

    // MARK: - Prompt

    private static var monthYearStamp: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MM-yyyy"
        return fmt.string(from: Date())
    }

    private static func buildPrompt(content: String?, existingTags: [String], isText: Bool, filename: String, userContext: String = "", knownPeople: [String] = []) -> String {
        let tagHint = existingTags.isEmpty
            ? ""
            : "Prefer tags from this existing list when they fit: [\(existingTags.joined(separator: ", "))]. You may suggest new tags if none fit."

        let docRef = isText ? "document text" : "document image"
        let stamp = monthYearStamp   // e.g. "07-2026"
        let contextLine = userContext.isEmpty
            ? ""
            : "\n\nUser-provided context (treat as authoritative — use it to sharpen the title, tags, and description): \(userContext)"

        return """
        Analyze this \(docRef) and return JSON only — no explanation, no markdown fences.

        Return exactly this structure:
        {
          "tags": ["tag1", "tag2", "tag3"],
          "description": "One to two sentence summary of what this document is.",
          "title": "Short descriptive title" or null,
          "remind": "YYYY-MM-DD" or null,
          "dated": "YYYY-MM-DD" or null,
          "people": ["Exact Name From List"]
        }

        Rules:
        - tags: 2–5 short lowercase words or phrases. \(tagHint)
        - description: factual, concise. Include key amounts, dates, or parties if present.
        - remind: the date the document itself says it needs attention, as "YYYY-MM-DD": a pickup or ready date, a due date, an expiry, an appointment, an RSVP-by. Use the printed date, never today's. Return null if the document states no such date. Never guess one.
        - dated: the date printed on the document as when it was issued or when the event it records happened, as "YYYY-MM-DD" — a receipt's transaction date, a statement date, an event date. Null if none is printed.
        - people: names from this list ONLY, exactly as spelled, of anyone the document is about, for, or from, or whom the owner's context names: [\(knownPeople.joined(separator: ", "))]. Return [] if none apply. Never return a name that is not on the list.
        - title: suggest a short human-readable title (3–6 words, title case) ONLY if the filename looks auto-generated (e.g. IMG_xxxx, CleanShot timestamp, DSC_xxxx, screenshot dates, random strings). The original filename is: \(filename). If the filename is already descriptive, return null for title. If the image has recognizable content, use that for the title. If the content is unrecognizable or too generic to name meaningfully (e.g. a plain portrait with no context, a blank or unclear photo), use the fallback title "Image \(stamp)".
        - Return valid JSON only. No other text.\(contextLine)
        \(content.map { "\n\nDocument text:\n\($0)" } ?? "")
        """
    }

    // MARK: - Request bodies

    /// **One body shape per input, built in one place.** Session 92 added a
    /// second question for the same model; two copies of this dictionary is two
    /// places for the model name and the token cap to drift apart, and the one
    /// that drifts is always the one nobody is looking at.
    private static func requestBody(textPrompt: String, maxTokens: Int = 512,
                                    modelName: String = model) -> [String: Any] {
        [
            "model": modelName,
            "max_tokens": maxTokens,
            "messages": [[
                "role": "user",
                "content": textPrompt
            ]]
        ]
    }

    private static func requestBody(imageData: Data, textPrompt: String, maxTokens: Int = 512,
                                    modelName: String = model) -> [String: Any] {
        [
            "model": modelName,
            "max_tokens": maxTokens,
            "messages": [[
                "role": "user",
                "content": [
                    [
                        "type": "image",
                        "source": [
                            "type": "base64",
                            "media_type": detectMediaType(imageData),
                            "data": imageData.base64EncodedString()
                        ]
                    ],
                    [
                        "type": "text",
                        "text": textPrompt
                    ]
                ]
            ]]
        ]
    }

    // MARK: - Claude API call (text prompt only)

    private static func callClaude(textPrompt: String) async throws -> DocumentScanResult {
        try await sendRequest(body: requestBody(textPrompt: textPrompt))
    }

    // MARK: - Claude API call (image + text prompt)

    private static func callClaude(imageData: Data, textPrompt: String) async throws -> DocumentScanResult {
        try await sendRequest(body: requestBody(imageData: imageData, textPrompt: textPrompt))
    }

    // MARK: - Shared request sender

    /// The HTTP call, the envelope and the fence, and nothing else.
    ///
    /// Split out in Session 92 so the booking parse and the document scan send
    /// the same request through the same error handling and differ only in what
    /// they ask for and what they do with the answer. `sendRequest` below is now
    /// this plus one decode.
    private static func sendRaw(body: [String: Any]) async throws -> String {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue(apiKey,            forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01",      forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        let rawBody = String(data: data, encoding: .utf8) ?? ""

        guard let http = response as? HTTPURLResponse else {
            throw DocumentScanError.apiError("No HTTP response")
        }
        guard http.statusCode == 200 else {
            throw DocumentScanError.apiError("HTTP \(http.statusCode): \(rawBody.prefix(200))")
        }

        // Parse Claude envelope
        guard let envelope = try? JSONDecoder().decode(ClaudeEnvelope.self, from: data) else {
            throw DocumentScanError.parseError("Unexpected API response: \(rawBody.prefix(300))")
        }
        guard let text = envelope.content.first(where: { $0.type == "text" })?.text else {
            throw DocumentScanError.noContent
        }

        // Strip code fences if Claude wrapped the JSON anyway
        return stripCodeFence(text)
    }

    private static func sendRequest(body: [String: Any]) async throws -> DocumentScanResult {
        let cleaned = try await sendRaw(body: body)
        guard let jsonData = cleaned.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw DocumentScanError.parseError("Could not parse JSON: \(cleaned.prefix(200))")
        }

        let tags = (obj["tags"] as? [String] ?? []).map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
        let description = obj["description"] as? String ?? ""
        let title: String? = {
            guard let t = obj["title"] as? String,
                  !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  t.lowercased() != "null" else { return nil }
            return t.trimmingCharacters(in: .whitespacesAndNewlines)
        }()

        return DocumentScanResult(tags: tags, description: description, title: title,
                                  remindOn: DocumentScanResult.parseRemind(obj["remind"]),
                                  datedOn: DocumentScanResult.parseRemind(obj["dated"]),
                                  people: (obj["people"] as? [String]) ?? [])
    }

    // MARK: - Helpers

    private static func detectMediaType(_ data: Data) -> String {
        if data.prefix(2) == Data([0xFF, 0xD8])                               { return "image/jpeg" }
        if data.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47])                  { return "image/png"  }
        if data.prefix(3) == Data([0x47, 0x49, 0x46])                        { return "image/gif"  }
        if data.count > 12 && data[8..<12] == Data([0x57, 0x45, 0x42, 0x50]) { return "image/webp" }
        return "image/jpeg"
    }

    private static func stripCodeFence(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            s = s.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
            if s.hasSuffix("```") { s = String(s.dropLast(3)) }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Claude response envelope (shared shape)

private struct ClaudeEnvelope: Decodable {
    let content: [ClaudeContent]
}

private struct ClaudeContent: Decodable {
    let type: String
    let text: String?
}
