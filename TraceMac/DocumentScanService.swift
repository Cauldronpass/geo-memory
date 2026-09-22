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

// MARK: - Todoist (D348, Session 95)

/// Sends one task to Todoist, and nothing else.
///
/// **Lives in this file rather than a new one** so `project.pbxproj` is
/// untouched, the same trade Session 92 made for the booking parse. It has
/// nothing to do with document scanning and the file's name will be wrong
/// about it; that is recorded here rather than paid for with an Xcode project
/// edit in a session that has already shipped a lot uncompiled.
///
/// **One call, no sync.** Trace does not read Todoist back, does not track
/// completion there, and does not hold an id it would have to keep valid. The
/// task LEAVES — the reminder is completed and the day note records the
/// hand-off (D348) — so there is nothing here that can drift out of step with
/// what David sees at work.

// MARK: - Research (D314)

/// What a research run came back with.
struct MacResearchReading: Sendable {
    /// The prose, as the model wrote it.
    var text: String
    /// Every page it actually read, in the order it read them, deduplicated by
    /// URL. Title first, address second.
    var sources: [(title: String, url: String)]
    /// How many searches it ran. Kept for the footer line, but NOT the test
    /// for whether this reading came off the web - see `isUnsourced`.
    var searches: Int

    /// **Nothing it read is under this reading**, whether it searched or not.
    ///
    /// The first version of this guard tested `searches == 0`, and David's
    /// first real run walked straight through it: the model spent all five
    /// searches, found nothing it could cite, and wrote three paragraphs of
    /// general knowledge - the memory-wearing-a-paragraph D314 forbids,
    /// arriving with a search count of five. The COUNT was never the question.
    /// A reading with no sources under it has nothing behind it, and that is
    /// as true at fifty searches as at none.
    var isUnsourced: Bool { sources.isEmpty }

    /// What the SEARCH TOOL said went wrong, if anything, in David's words
    /// rather than the model's.
    ///
    /// **The model's excuse is not the error.** Two runs in a row came back
    /// with a polite sentence - *"I ran out of search attempts for this turn"*,
    /// then *"the tool has hit its call limit for this response"* - describing
    /// a failure it cannot actually see the cause of, and both times the real
    /// answer was sitting unread in a `web_search_tool_result` block this code
    /// was skipping. One of those excuses was even wrong: the second run had a
    /// cap of ten and had not run a single search.
    ///
    /// This app's own rule, from `MacAskService.explain`: say which of
    /// configuration or fault it is. A model narrating its own tool failure can
    /// do neither, because it was not told.
    var searchError: String?

    /// The reading as it is written to the Satchel document and shown in the
    /// window: the prose, then a Sources block.
    ///
    /// **The sources are part of the TEXT, not decoration around it.** Keep
    /// files this as a plain document (D313) and the pane renders that file;
    /// a source list living only in the window would be gone the moment it was
    /// kept, which is the half of the answer you most need next week.
    var rendered: String {
        guard !sources.isEmpty else {
            let why = searchError
                ?? "Claude ran \(searches == 1 ? "1 search" : "\(searches) searches") and cited nothing."
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
                 + "\n\n[No sources. \(why) Read everything above as Claude's general "
                 + "knowledge rather than as anything it looked up.]"
        }
        var out = text.trimmingCharacters(in: .whitespacesAndNewlines)
        out += "\n\nSources\n"
        for (i, s) in sources.enumerated() {
            let title = s.title.trimmingCharacters(in: .whitespacesAndNewlines)
            out += title.isEmpty ? "\(i + 1). \(s.url)\n"
                                 : "\(i + 1). \(title) — \(s.url)\n"
        }
        return out
    }
}

/// The third AI path: the brief plus a slice of the endeavor, to Anthropic,
/// **with the server-side web search tool switched on** (D314).
///
/// David: *"we definately need the AI to be able to look at the web for this
/// use case which is different i assume from the other AI buttons."* It is.
/// `MacLocalIntelligence` never leaves the Mac and cannot see the web;
/// `MacAskService` sends the note corpus with no tools, so its answer about a
/// price is its memory. Neither can do this job.
///
/// **There is no local fallback, deliberately.** A Research button that
/// silently dropped to the on-device model would produce confident unsourced
/// prices — the exact failure D316's tilde exists to prevent. No key means an
/// error saying so, never a quieter answer.
enum MacResearchService {

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    /// Sonnet, matching `MacAskService`. The job is reading a handful of pages
    /// and writing a paragraph, not reasoning hard about them.
    private static let model = "claude-sonnet-5"

    /// **Ten, raised from five on the first real run.** David asked for
    /// Thanksgiving rental-car prices and got back "I ran out of search
    /// attempts for this turn": five is enough to look one thing up and not
    /// enough to compare several, which is most of what this button is for.
    /// The ceiling still exists because this bills per search rather than per
    /// press - a guard against a runaway loop, not a budget.
    private static let maxSearches = 10

    enum ResearchError: LocalizedError {
        case noKey
        case api(String)
        case empty

        var errorDescription: String? {
            switch self {
            case .noKey:
                return "No Claude key on this Mac. Add one in Settings (⌘,). "
                     + "Research always searches the web — it has no offline mode."
            case .api(let message):
                return message
            case .empty:
                return "Claude answered with nothing. Try the brief again, more specifically."
            }
        }
    }

    static func run(brief: String, context: String) async throws -> MacResearchReading {
        let key = ClaudeKeyStore.key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw ResearchError.noKey }

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 2000,
            "system": systemPrompt,
            // One extra entry in the request body, which is all D314 said it
            // would take.
            "tools": [[
                "type": "web_search_20250305",
                "name": "web_search",
                "max_uses": maxSearches
            ]],
            "messages": [[
                "role": "user",
                "content": context.isEmpty ? brief : context + "\n\nBrief: " + brief
            ]]
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(key,                forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01",       forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        // Several live web fetches happen inside this one call, so it is the
        // slowest request the app makes. 60s has not been enough in testing.
        request.timeoutInterval = 180

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ResearchError.api("No HTTP response from Claude.")
        }
        guard http.statusCode == 200 else { throw explain(status: http.statusCode, body: data) }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let blocks = json?["content"] as? [[String: Any]] ?? []

        var text = ""
        var sources: [(title: String, url: String)] = []
        var seen = Set<String>()
        var searches = 0
        var searchFailure: String? = nil

        for block in blocks {
            switch block["type"] as? String {
            case "text":
                text += block["text"] as? String ?? ""
                // Citations hang off the text block that used them, which is
                // why the sources come out in the order he will read them.
                for c in block["citations"] as? [[String: Any]] ?? [] {
                    guard let url = c["url"] as? String, !seen.contains(url) else { continue }
                    seen.insert(url)
                    sources.append((title: c["title"] as? String ?? "", url: url))
                }
            case "server_tool_use":
                searches += 1
            case "web_search_tool_result":
                // **`content` is an ARRAY of results, or a single object when
                // the search FAILED.** Reading only the array is what let two
                // runs report a vague excuse with the real cause one field
                // away.
                if let failure = block["content"] as? [String: Any],
                   failure["type"] as? String == "web_search_tool_result_error" {
                    searchFailure = failure["error_code"] as? String ?? "unknown"
                    continue
                }
                // **Read as well as the citations, and not instead of them.** A
                // model that searched and then wrote an uncited sentence would
                // otherwise produce a reading with no sources at all, which
                // looks exactly like a reading it made up. Cited pages keep
                // their place at the front; the rest follow.
                for r in block["content"] as? [[String: Any]] ?? [] {
                    guard let url = r["url"] as? String, !seen.contains(url) else { continue }
                    seen.insert(url)
                    sources.append((title: r["title"] as? String ?? "", url: url))
                }
            default:
                break
            }
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ResearchError.empty }
        return MacResearchReading(text: trimmed,
                                  sources: sources,
                                  searches: searches,
                                  searchError: searchFailure.map(explainSearch))
    }

    /// The search tool's own error code, as a sentence naming what to do.
    ///
    /// `too_many_requests` is the one worth spelling out: web search carries an
    /// **organisation-level rate limit separate from the per-request cap**, so
    /// a run can fail having made no searches at all while `max_uses` sat
    /// untouched at ten. That is not a Trace limit and not a key problem, and
    /// without this sentence it arrives as the model apologising for something
    /// it has guessed at.
    private static func explainSearch(_ code: String) -> String {
        switch code {
        case "too_many_requests":
            return "Anthropic rate-limited web search for your workspace, not Trace, and not your key. "
                 + "Web search has its own organisation limit separate from this app's cap of \(maxSearches) "
                 + "per press — see Console ▸ Settings ▸ Rate limits. Waiting a minute usually clears it."
        case "max_uses_exceeded":
            return "Claude used all \(maxSearches) searches without reaching an answer. "
                 + "A narrower brief usually gets there in fewer."
        case "unavailable":
            return "Anthropic's web search had an internal error. Failed searches are not billed; try again."
        case "query_too_long":
            return "Claude built a search query that was too long. Try a shorter brief."
        case "invalid_tool_input":
            return "Anthropic rejected the search query as malformed. Worth reporting if it repeats."
        case "request_too_large":
            return "The search request was too large for Anthropic to accept."
        default:
            return "Web search failed: \(code)."
        }
    }

    /// Same shape as `MacAskService.explain`: name the thing to change, never
    /// paste the server's JSON on screen.
    private static func explain(status: Int, body: Data) -> ResearchError {
        let raw = String(data: body, encoding: .utf8) ?? ""
        let detail: String = {
            guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let error = json["error"] as? [String: Any],
                  let message = error["message"] as? String else {
                return String(raw.prefix(200))
            }
            return message
        }()
        switch status {
        case 401, 403:
            return .api("Claude refused the key on this Mac. Check it in Settings (⌘,). \(detail)")
        case 429:
            return .api("Rate limited by your Anthropic workspace, not by Trace. "
                      + "Raise the per-minute limit for this model in the Console, "
                      + "under Settings ▸ Workspaces ▸ Limits. \(detail)")
        case 400 where detail.lowercased().contains("web search"):
            // Not a tool-level error code: an administrator turning web search
            // off for the organisation fails the whole request instead.
            return .api("Web search is switched off for your Anthropic organisation, so Research "
                      + "cannot work. An admin re-enables it at Console ▸ Settings ▸ Privacy. \(detail)")
        case 500...599:
            return .api("Anthropic had a server error (\(status)). Nothing was sent twice; try again.")
        default:
            return .api("Claude returned HTTP \(status). \(detail)")
        }
    }

    /// **Short, and it asks for prices with dates attached.**
    ///
    /// A research reading whose numbers have no as-of date is a reading that
    /// silently rots: read again in March, "$240" reads as today's price. The
    /// tilde rule is D316's and applies here for the same reason — a figure
    /// carrying false precision is worse than a range.
    private static let systemPrompt = """
    You are researching one thing for David, who will read this once and act on it.

    Search the web before answering. Never answer a question about prices,
    availability, opening hours or anything else that changes, from memory.

    You have a limited number of searches. Spend them on specific queries rather
    than broad ones, and stop as soon as you can answer.

    Some questions cannot be answered from the web at all: a live rental car or
    flight price for particular dates exists only inside a booking engine and is
    on no page. When that is the case, say so in your FIRST sentence, say why,
    and name what would actually answer it. Then stop. Do not fill the space
    with general background about the topic - a short honest "the web does not
    hold this, here is where to look" is the useful answer, and three paragraphs
    of context is not.

    Write plain prose in short paragraphs. No preamble, no restating the brief,
    no offer to help further. Lead with the answer.

    No markdown. No asterisks for bold, no hashes for headings, no bullet
    characters. This is read as plain text in a window and filed as a plain text
    document, so **like this** arrives on screen with the asterisks showing.
    Emphasise by writing the important thing first, not by decorating it.

    Rules for numbers:
    - Give a range with a tilde (~$180–240) rather than false precision.
    - Say when a price or a fact was current, and name the page it came from in
      the sentence when the reader would want to check it.
    - If the web did not answer something, say that plainly instead of guessing.
      "I could not find X" is a useful sentence.

    Keep it under 400 words unless the brief asks for a list.
    """
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
    /// Why nothing was read, in the words of the thing that refused (D338).
    ///
    /// **Every failure used to collapse into "Couldn't read this document."**
    /// That sentence is true of a photograph of a deck and false of a document
    /// the app declined to send because it is tagged private — and the second
    /// is a refusal David can act on, while the first is not. `DocumentScanError`
    /// has always carried the real words; they were being thrown away by a
    /// `try?` at the call site.
    var failureNote: String?  = nil

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
    /// Things to do, one per line, which become `- [ ]` boxes under `## Plan`
    /// (D352). Empty when the text asked for none.
    var plan: [String]       = []
    var peopleNamed: [String] = []
    var placesNamed: [String] = []

    /// True when there is something worth putting on a sheet.
    var hasAnything: Bool {
        (name?.isEmpty == false) || type != nil || starts != nil
            || (destination?.isEmpty == false) || (summary?.isEmpty == false)
            || !peopleNamed.isEmpty || !placesNamed.isEmpty || !plan.isEmpty
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

extension BookingParse {

    /// This parse as a `Booking`, for the tick list (D339).
    ///
    /// **The sheet's `draft()` stays where it is.** That one reads the fields
    /// David has been editing and is the only thing that may write what he
    /// typed; this one reads the parse and is the only thing that may write
    /// what was read. Two callers, two sources, deliberately not merged — a
    /// single function taking both would have to decide which wins, and that
    /// decision belongs to whether a sheet was opened at all.
    func asBooking(endeavorID: String, whoIDs: [String]) -> Booking {
        let kindValue = kind ?? "Other"
        let labels = BookingKind.labels(for: kindValue)
        var noteLines: [String] = []
        if let notes, !notes.isEmpty { noteLines.append(notes) }
        if let currency, currency.uppercased() != "USD" {
            noteLines.append("Printed in \(currency.uppercased()). The cost above is that figure, not converted.")
        }
        return Booking(
            id: "",
            name: BookingKind.writtenName(kind: kindValue,
                                          provider: provider ?? "",
                                          number: number ?? "",
                                          from: from ?? "",
                                          to: to ?? "",
                                          start: start,
                                          end: end),
            kind: kindValue,
            endeavorID: endeavorID,
            whoIDs: whoIDs,
            start: start,
            end: end,
            hasTime: start != nil && hasTime,
            from: labels.from == nil ? nil : from,
            to: to,
            provider: provider,
            number: number,
            confirmation: confirmation,
            notes: noteLines.joined(separator: "\n"),
            cost: cost,
            // A confirmation is a booking somebody made (D319).
            booked: true,
            status: nil)
    }
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

    // MARK: - Summarising a document into the note (D345, Session 95)

    /// What a document says that is worth having in the endeavor's own note.
    struct DocumentDigest {
        /// One of the note's five headings, chosen by whatever read it.
        var section: String
        var text: String
        /// Which model produced it, said out loud on the confirm step so the
        /// answer is never anonymous.
        var readBy: String
    }

    /// The five headings an endeavor note has (`EndeavorFile.skeleton`).
    static let noteSections = ["Summary", "Plan", "Open items", "Log", "Reference"]

    /// Reads a filed document and proposes what to add to the endeavor's note.
    ///
    /// **The privacy tag decides which model reads it, and nothing is asked.**
    /// D322's card exists because a freshly dropped file has no tag yet; a
    /// document already sitting on an endeavor has been through that door
    /// already, and asking twice would be asking a question that has an answer
    /// on disk. Tagged private goes to the on-device model; untagged goes to
    /// the cloud. The confirm step names which one, so the choice is visible
    /// even though it was not re-asked.
    ///
    /// **It proposes; it never writes.** D313 is explicit that the note is
    /// David's voice and the app does not write in it on its own, which is why
    /// research became a document instead. This does not reverse that — it
    /// keeps the half that matters. The summary is shown first and only lands
    /// on Keep, exactly as Research does.
    static func summariseDocument(doc: TraceMacDocument,
                                  noteStore: NoteStore,
                                  endeavor: Endeavor) async throws -> DocumentDigest {
        guard let url = noteStore.resolvedURL(for: doc.relativePath) else {
            throw DocumentScanError.noContent
        }
        let text = await Task.detached { MacTextExtraction.extract(from: url) }.value

        // ── The private path: read here, sent nowhere ────────────────────────
        if doc.isPrivate {
            guard let text, text.contains(where: { $0.isLetter || $0.isNumber }) else {
                throw DocumentScanError.noContent
            }
            guard let facts = await MacLocalIntelligence.suggest(
                text: text,
                hint: "This document is filed to \(endeavor.name), a \(endeavor.type.lowercased())."
            ), !facts.summary.isEmpty else {
                throw DocumentScanError.noContent
            }
            // **Reference, always, on this path.** The on-device model returns
            // one sentence and is not asked to choose a heading — a model that
            // struggles with an arrival time should not be picking where in his
            // note something goes.
            return DocumentDigest(section: "Reference",
                                  text: facts.summary,
                                  readBy: "Read on this Mac")
        }

        // ── The cloud path ───────────────────────────────────────────────────
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DocumentScanError.noKey
        }

        let prompt = """
        A document has been filed to something the owner is planning. Read it and say what is worth keeping in their own notes about it. Return JSON only — no explanation, no markdown fences.

        What it is filed to: "\(endeavor.name)", a \(endeavor.type.lowercased())\(endeavor.destination.map { ", in \($0)" } ?? "").

        Return exactly this structure:
        {
          "section": "Reference",
          "text": "Check-in 4 pm, check-out 10 am. Four bedrooms, sleeps 5. Kayaks and paddleboards on site. Early check-out can be requested on the day for a fee."
        }

        Rules:
        - section: exactly one of Summary, Plan, Open items, Log, Reference. Summary is what this endeavor IS. Plan is what is going to happen. Open items are things still to decide or do. Log is what already happened. **Reference is standing detail you would look up later, and is the right answer for most documents.**
        - text: the useful facts, in plain prose, written for the owner's own notes. Two to five short sentences, or a few lines. No preamble, no "this document says", no heading.
        - **Only what the document actually states.** Never add advice, context or anything you know from elsewhere.
        - Leave out what the endeavor already records: dates and places it obviously knows, and anything that is a booking — flights, hotel reservations and their confirmation codes belong on the itinerary, not in prose.
        - If the document holds nothing worth keeping, return an empty string for text.
        - Return valid JSON only. No other text.

        The document:
        \(String((text ?? "").prefix(8_000)))
        """

        guard let text, text.contains(where: { $0.isLetter || $0.isNumber }) else {
            throw DocumentScanError.noContent
        }
        let body = requestBody(textPrompt: prompt, maxTokens: 900, modelName: bookingModel)
        let raw = try await sendRaw(body: body)
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DocumentScanError.parseError("Could not parse JSON: \(raw.prefix(200))")
        }
        let digest = (obj["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !digest.isEmpty else { throw DocumentScanError.noContent }
        let proposed = (obj["section"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        // Matched against the five in code. A heading the model invented is not
        // a heading this note has, and appending under it would quietly grow a
        // sixth section (D330's rule, on a different field).
        let section = noteSections.first { $0.caseInsensitiveCompare(proposed) == .orderedSame }
            ?? "Reference"
        return DocumentDigest(section: section, text: digest, readBy: "Read by Claude")
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
          "plan": ["Book the hotel", "Reserve a car"],
          "people": ["Hannah"],
          "places": ["Savannah"]
        }

        Rules:
        - name: a short title for it, 2 to 5 words, title case. Not a sentence. Null only if the text names nothing at all.
        - type: exactly one of Travel, Milestone, Gathering, Project, Decision. Travel is a trip. Milestone is a dated life event like a graduation or a wedding. Gathering is people coming together without travel being the point. Project is work with an outcome. Decision is a choice being weighed between options. Null if none of the five fits.
        - starts / ends: "YYYY-MM-DD". Null when the text implies no date. A single day gives the same date twice. Never guess a date from the type — a trip with no timing stated has no dates.
        - destination: where it happens, as a person would say it — "Savannah", "Fort Collins, CO", "Kyoto". Null for anything not tied to a place.
        - summary: one short paragraph in plain prose, written back to the person as a statement of what this is. Their own words and facts, nothing added. Two or three sentences at most. It must NOT list or describe the things still to be done — those go in "plan" and writing them here as well says the same thing twice, once in the wrong place.
        - plan: the things they still have to do, one short imperative per item — "Book the flights", "Arrange dog boarding". These become tick boxes, so write each as an action, not as a note about actions. [] when the text names nothing to do. Asking for "a checklist" or "checkboxes" without saying what goes on it is not itself an item; return [] rather than inventing tasks.
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
        // Through `names`, so a model that answers with a stray empty string
        // does not become an empty tick box nobody can name or tick.
        draft.plan        = names("plan")
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
    static func parseBooking(doc: TraceMacDocument, noteStore: NoteStore) async throws -> [BookingParse] {
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
                var parses = try decodeBookings(raw)
                // The prompt asks; this checks. Asking has failed on two models.
                for i in parses.indices { reconcileYear(&parses[i], printed: years) }
                return parses
            }
            // No text layer — a scanned or photographed confirmation. Same
            // branch `scanPDF` takes, for the same reason.
            guard let page = pdf.page(at: 0), let rendered = renderPageImage(page) else {
                throw DocumentScanError.noContent
            }
            let body = requestBody(imageData: rendered, textPrompt: prompt, maxTokens: 900,
                                   modelName: bookingModel)
            let raw = try await sendRaw(body: body)
            return try decodeBookings(raw)
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
            return try decodeBookings(answer)
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
    static func parseBookingLocally(doc: TraceMacDocument, noteStore: NoteStore) async -> [BookingParse] {
        guard let url = noteStore.resolvedURL(for: doc.relativePath) else { return [] }

        let text = await Task.detached { MacTextExtraction.extract(from: url) }.value
        guard let text, text.contains(where: { $0.isLetter || $0.isNumber }) else { return [] }
        guard let facts = await MacLocalIntelligence.parseBooking(text: text) else { return [] }

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

        // The count the model gave, floored at one when it read anything at
        // all. Same rule the cloud decode uses, and the same sentence at the
        // top of the sheet — "3 bookings in this document, showing the first"
        // — so a three-leg itinerary says so whichever model read it (D338).
        // **One booking, and a count of how many there were.** The on-device
        // model reads a single booking well enough and reading several at once
        // is past it — it produced two different arrival times for one leg on
        // consecutive runs. So the private path keeps v1's shape and says how
        // many it saw; the cloud path returns them all (D339). A list of one is
        // the same type either way, which is what lets the caller stop caring
        // which model answered.
        parse.found = max(facts.bookingCount, parse.hasAnything ? 1 : 0)
        // And the same year check. A smaller model is likelier to need it, not
        // less, and the text is already in hand.
        reconcileYear(&parse, printed: documentYears(text))
        return parse.hasAnything ? [parse] : []
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
          "bookings": [
          {
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
          ]
        }

        Rules:
        - found: how many separate bookings this document holds, and the length of the bookings array. **Describe every one of them**, in the order they are printed.
        - A round trip printed as an outbound and a return is 2 bookings. **Connecting legs of one journey are ONE booking**, not two: DEN to STL to ORD on one ticket, one day, is a single flight from DEN to ORD. Use the first leg's departure and the last leg's arrival, and put the connection in notes.
        - A hotel stay is 1. A car rental is 1. If the document holds no booking at all, return 0 and an empty array.
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
    /// Every booking the document holds, in printed order (D339).
    ///
    /// **v1 read one and said how many there were.** David hit the limit three
    /// times on one round-trip itinerary — *"i have three flights on this
    /// itinary… the other flights are not there"* — which is three times more
    /// than a limitation gets to be described as a design.
    ///
    /// **Tolerant of both shapes.** An older answer, or a model that ignores
    /// the array, comes back as one flat object; that still decodes, as a
    /// single booking. A shape rule enforced only by a prompt is not enforced.
    private static func decodeBookings(_ cleaned: String) throws -> [BookingParse] {
        guard let data = cleaned.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DocumentScanError.parseError("Could not parse JSON: \(cleaned.prefix(200))")
        }
        let declared = (obj["found"] as? NSNumber)?.intValue ?? 0
        let rows = (obj["bookings"] as? [[String: Any]]) ?? [obj]
        var out: [BookingParse] = []
        for row in rows {
            var parse = decodeOne(row)
            guard parse.hasAnything else { continue }
            parse.found = max(declared, rows.count)
            out.append(parse)
        }
        return out
    }

    private static func decodeOne(_ obj: [String: Any]) -> BookingParse {
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

        // **THE TEMPLATE AND THE RULES MUST NOT DISAGREE**, and this Mac copy
        // never learned what the phone learned on 2026-07-28. The template
        // below offered `"title": "…" or null` unconditionally while the rule
        // underneath it described when a title was wanted. A model takes the
        // concrete output template over a paragraph of prose further down, so
        // the null won. See the same comment in
        // `Trace/IOSDocumentScanService.swift`, which is where this was first
        // paid for.
        //
        // **Typed context closes the null off**, because typing context and
        // pressing the button is an explicit request for a better title.
        // Session 111: David typed "Arlington Animal Hospital receipt for Scout
        // meds" on a file called `paymenthistory-2`, pressed Re-run repeatedly,
        // and could not move the title — the context reached the tags and the
        // description and was forbidden to reach the one field he was watching.
        let hasContext = !userContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let titleSlot = hasContext
            ? "\"Short descriptive title\""
            : "\"Short descriptive title\" or null"

        return """
        Analyze this \(docRef) and return JSON only — no explanation, no markdown fences.

        Return exactly this structure:
        {
          "tags": ["tag1", "tag2", "tag3"],
          "description": "One to two sentence summary of what this document is.",
          "title": \(titleSlot),
          "icon": "one token from the icon list below",
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
        - title: a short human-readable title, 3–6 words, title case, taken from the document's own content. The original filename is: \(filename). The test is whether that filename NAMES THIS DOCUMENT, not whether it looks like words. Return null ONLY when the filename already identifies this particular document well enough to find it again. Return a title when the filename names a CATEGORY rather than a document — portal, bank and scanner exports such as paymenthistory, invoice, statement, receipt, summary, document, scan, export, download, with or without a trailing number or copy suffix — or when it is auto-generated (IMG_xxxx, CleanShot timestamps, DSC_xxxx, screenshot dates, random strings). If user-provided context appears below, ALWAYS return a title and let that context shape it; never return null in that case. If the content is unrecognizable or too generic to name meaningfully (e.g. a plain portrait with no context, a blank or unclear photo), use the fallback title "Image \(stamp)".
        - icon: EXACTLY one token from this list, nothing else. Choose what the document is ABOUT — its subject, the part of life it belongs to — NOT what kind of artifact it is. A receipt from a restaurant is "menu". A vet bill is "pet". The fact that something is a receipt, a bill or a screenshot is carried by the tint below and by the tags, so never spend the icon on it. Only fall back to a form-based token ("receipt", "card", "photo", "document") when the document genuinely has no subject.
        \(DocumentIcon.promptGuide)
        - If you are unsure of the icon, use "document".
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
                                  icon: DocumentIcon.parse(obj["icon"] as? String),
                                  // **Not asked for, deliberately** (D344). The
                                  // colour is the icon's now, and a model answer
                                  // here would land in the one field that means
                                  // "David chose this".
                                  tint: nil,
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
