// TraceMacAskService.swift
// Ask: one question, the whole corpus, a written answer with citations.
// Spec §8 step 3. Mac-only — do not add to iOS, Widget, or Share Extension targets.
//
// ── Why there is no index in here ────────────────────────────────────────
//
// The container is ~107 markdown files and about 7,000 words: roughly 9,400
// tokens against a 200,000-token window. **The whole corpus fits in one
// prompt.** So there is no chunking, no embedding, no vector store, no
// retrieval step that can fetch the wrong five paragraphs and no index to keep
// in sync with a folder four apps write to. One call reads everything, every
// time.
//
// That single fact is what makes Ask a feature rather than a project, and it is
// the most important line in the spec. It has years of headroom — five years of
// everything is maybe 50,000 tokens — and when it stops being true the answer
// is `budget`, below: cap by recency and **say so on screen**. Silent truncation
// is the thing to avoid, not the cap.
//
// ── What leaves the Mac, and only on a press ─────────────────────────────
//
// The text of the notes in scope plus the question, over HTTPS to
// api.anthropic.com. Nothing else. Search never leaves the machine at all; this
// does, and only when the button is pressed — never as you type.
//
//   * **People and Places are out** (spec §6), switchable in Settings and off by
//     default. Not squeamishness: those records are other people's phone
//     numbers, addresses and birthdays, and they did not choose this. It also
//     buys nothing — "what is Megan's number" is answered by Search, locally,
//     with no API call at all.
//   * **`private` documents contribute title and tags only** (spec §5b). Ask can
//     say "your State Farm document covers this" and point at it without the
//     policy number leaving the Mac. Full invisibility was considered and is
//     worse: the user would lose the routing as well as the reading.

import Foundation

// MARK: - Result

struct MacAskCitation: Identifiable, Hashable, Sendable {
    /// The `[n]` the model wrote.
    let number: Int
    let title: String
    /// Container-relative path, or a document path. Empty when unresolvable.
    let path: String
    let destination: MacSearchDestination
    var id: Int { number }
}

struct MacAskAnswer: Sendable {
    let text: String
    let citations: [MacAskCitation]
    /// How many records went into the prompt.
    let recordsRead: Int
    /// How many were left out by the token cap, and therefore not read.
    let recordsSkipped: Int
    let seconds: Double
    let inputTokens: Int?
    let outputTokens: Int?
    /// Tokens written into the prompt cache on this call. Non-zero on the first
    /// question of a sitting and zero after.
    let cacheWritten: Int?
    /// Tokens served from the cache instead of re-read. The number that says the
    /// cache is working.
    let cacheRead: Int?

    /// The line under every answer. Says what was read, what was not, and how
    /// long it took — an answer whose sources you cannot see is not checkable,
    /// and a corpus that was silently trimmed is not either.
    var receipt: String {
        var parts = ["read \(recordsRead) record\(recordsRead == 1 ? "" : "s")"]
        if recordsSkipped > 0 {
            parts.append("\(recordsSkipped) left out by the size cap")
        }
        parts.append(String(format: "%.1fs", seconds))
        if let inputTokens, let outputTokens {
            parts.append("\(inputTokens) in / \(outputTokens) out")
        }
        // Printed because it is the only way to see whether caching is doing
        // anything. A cache that silently stopped hitting would otherwise look
        // exactly like one that never existed, and the bill would be the first
        // place it showed up.
        if let cacheRead, cacheRead > 0 {
            parts.append("\(cacheRead) cached")
        } else if let cacheWritten, cacheWritten > 0 {
            parts.append("\(cacheWritten) cache written")
        }
        return parts.joined(separator: " · ")
    }
}

enum MacAskError: LocalizedError {
    case noKey
    case empty
    case api(String)

    var errorDescription: String? {
        switch self {
        case .noKey:
            // Same wording as `DocumentScanService.noKey`, and for the same
            // reason: App Groups are per-device, so the key entered on the phone
            // was never going to be here. That is configuration, not a fault.
            return "No Claude API key on this Mac. Add one in Settings (⌘,). "
                 + "Keys are stored per-device, so the one on your iPhone does not carry over."
        case .empty:  return "There is nothing in scope to read yet."
        case .api(let message): return message
        }
    }
}

// MARK: - Service

enum MacAskService {

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    /// Sonnet, not the Haiku `DocumentScanService` uses.
    ///
    /// That service extracts three fields from one document and Haiku is the
    /// right tool. This one reads the whole corpus and reasons across it — *"what
    /// did I tell Mickey I would do in July"* — which is the job the extra cost
    /// buys.
    ///
    /// **Sonnet 5, changed from `claude-sonnet-4-5-20250929` on 2026-08-11.**
    /// David asked whether it would cost more. Checked rather than assumed, and
    /// it is the cheaper model on paper: $2/$10 per million against 4.5's
    /// $3/$15. The catch is in the same table's footnote — **4.7 and later use a
    /// newer tokenizer that produces about 30% more tokens for the same text**,
    /// so the per-question cost lands within a few percent of where it was. The
    /// reason to switch is the model, not the bill.
    ///
    /// It is also the row already provisioned in his workspace at 200,000 input
    /// tokens per minute, against 4.x's 100,000.
    ///
    /// The **alias**, not a dated snapshot. `DocumentScanService` pins
    /// `claude-haiku-4-5-20251001` and that is right for a service whose output
    /// is parsed as JSON with a fixed shape; this one returns prose for a person
    /// to read, so a newer point release is an improvement rather than a risk.
    private static let model = "claude-sonnet-5"

    /// Leaves room for the answer inside a 200k window while being far above
    /// anything this container will produce for years. **Enforced by dropping
    /// oldest-first and reporting the count** — see `MacAskAnswer.receipt`.
    static let tokenBudget = 120_000

    /// Rough, but **calibrated against a real answer rather than the folklore
    /// number.**
    ///
    /// The first version used four characters per token, which is the figure the
    /// docs quote for English prose. David's first successful Ask billed 37,101
    /// input tokens for a 91,439-character corpus: **2.46 characters per
    /// token**, and the estimate was 38% low.
    ///
    /// Two reasons, and both are permanent here. Markdown is dense — wikilinks,
    /// ISO dates, frontmatter and OCR fragments tokenize far worse than prose —
    /// and Sonnet 5 uses the newer tokenizer that the pricing table's own
    /// footnote says produces about 30% more tokens for the same text.
    ///
    /// **Being 38% low mattered, which is why this is not left as "rough".**
    /// `tokenBudget` is enforced through this function, so a 120,000-token cap
    /// was really letting through ~195,000 — inside a 200,000 window by a margin
    /// smaller than the error itself, and with the answer still to be written.
    /// The guard existed and would not have guarded. 2.5 lands within 1% on his
    /// actual corpus and errs pessimistic, which is the right direction for a
    /// cap.
    nonisolated static func estimatedTokens(_ text: String) -> Int {
        Int(Double(text.count) / 2.5)
    }

    // MARK: Ask

    static func ask(_ question: String,
                    corpus: MacSearchCorpus,
                    documents: [TraceMacDocument],
                    people: [Person],
                    places: [Place],
                    includeNotionRecords: Bool) async throws -> MacAskAnswer {

        guard ClaudeKeyStore.hasKey else { throw MacAskError.noKey }

        let started = Date()
        let assembled = assemble(corpus: corpus,
                                 documents: documents,
                                 people: includeNotionRecords ? people : [],
                                 places: includeNotionRecords ? places : [])
        guard !assembled.entries.isEmpty else { throw MacAskError.empty }

        // ── Prompt caching ───────────────────────────────────────────────
        //
        // `cache_control` caches everything up to **and including** the block it
        // sits on, so the breakpoint goes on the records and the question comes
        // after it. That ordering is the whole mechanism: the expensive part of
        // this prompt is fixed and the cheap part varies, which is the one shape
        // caching is worth anything for.
        //
        // Writing costs 1.25× a normal read and a hit costs 0.1×, so it pays for
        // itself on the second question of a sitting and costs about a quarter
        // extra if there never is one. Measured against David's corpus: 7.4¢ a
        // question today, 9.3¢ then 0.7¢ with this.
        //
        // Two things it does not change, stated because they are easy to assume
        // it does: the first question still sends the whole corpus, and the
        // cached block sits on Anthropic's side for the five-minute window on
        // top of the 30-day retention that already applied.
        //
        // Five minutes rather than an hour. A hit refreshes the clock, so a run
        // of questions keeps it alive on its own, and the 1-hour write costs 2×
        // — which needs two reads to break even rather than one.
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1500,
            "system": [[
                "type": "text",
                "text": systemPrompt
            ]],
            "messages": [[
                "role": "user",
                "content": [
                    [
                        "type": "text",
                        "text": assembled.text,
                        "cache_control": ["type": "ephemeral"]
                    ],
                    [
                        "type": "text",
                        "text": "Question: \(question)"
                    ]
                ]
            ]]
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(ClaudeKeyStore.key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01",       forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        // A whole-corpus prompt is a bigger request than anything else this app
        // sends, and the default 60s has been the wrong number before.
        request.timeoutInterval = 120

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MacAskError.api("No HTTP response.")
        }
        guard http.statusCode == 200 else {
            throw explain(status: http.statusCode, body: data)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let blocks = json?["content"] as? [[String: Any]] ?? []
        let text = blocks.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { throw MacAskError.api("Empty answer.") }

        let usage = json?["usage"] as? [String: Any]

        return MacAskAnswer(
            text: text,
            citations: citations(in: text, from: assembled.entries),
            recordsRead: assembled.entries.count,
            recordsSkipped: assembled.skipped,
            seconds: Date().timeIntervalSince(started),
            inputTokens: usage?["input_tokens"] as? Int,
            outputTokens: usage?["output_tokens"] as? Int,
            cacheWritten: usage?["cache_creation_input_tokens"] as? Int,
            cacheRead: usage?["cache_read_input_tokens"] as? Int)
    }

    // MARK: Errors the user can act on

    /// Turns an HTTP failure into a sentence naming the thing to change.
    ///
    /// **The first version pasted the server's JSON on screen**, and David got
    /// exactly what `DocumentScanError.noKey` was written to stop happening two
    /// sessions ago: *`{"type":"error","error":{"type":"rate_limit_error",...`*
    /// spilling across the panel. That comment says it plainly — the app should
    /// say which of configuration or fault it is, rather than making a doomed
    /// call and pasting the server's reply.
    ///
    /// This one was configuration, and a specific one: the Trace apps workspace
    /// had this model capped at **0 input tokens per minute**, so every Ask was
    /// refused before it started. A raw 429 does not tell anyone that; the
    /// sentence below does, and names where to change it.
    private static func explain(status: Int, body: Data) -> MacAskError {
        let raw = String(data: body, encoding: .utf8) ?? ""
        // Anthropic's message is the useful part and is often precise (it named
        // the workspace and the zero limit). Kept, but framed rather than dumped.
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
        case 500...599:
            return .api("Anthropic had a server error (\(status)). Nothing was sent twice; try again.")
        default:
            return .api("Claude returned HTTP \(status). \(detail)")
        }
    }

    // MARK: Prompt

    private static let systemPrompt = """
    You are answering questions about one person's personal notes. Everything you \
    know is in the <records> block of the user message. Do not use outside knowledge \
    about the world to fill gaps in their life.

    Rules:
    - Answer from the records only. If they do not contain the answer, say so plainly \
    and name what you did look at. Do not guess and do not pad.
    - Cite with the bracketed number of every record you drew on, inline, like [4]. \
    Cite the record the fact actually came from, not a related one.
    - Some records are marked withheld="true". You can see their title and tags and \
    nothing else. You may point at them — "your State Farm document covers this [12]" \
    — but never claim to know what is inside one.
    - Be brief. Answer the question that was asked. No preamble, no restating the \
    question, no closing summary.
    - Dates in these notes are the user's own. Today's date appears at the top of the \
    records block.
    """

    // MARK: Assembly

    /// One record as it goes into the prompt.
    struct Entry: Sendable {
        let number: Int
        let title: String
        let path: String
        let destination: MacSearchDestination
        let block: String
        let sortDate: Date?
    }

    struct Assembled {
        let text: String
        let entries: [Entry]
        let skipped: Int
    }

    /// Builds the `<records>` block.
    ///
    /// **Newest first, and the cap drops from the bottom.** If the budget ever
    /// bites, the records that survive should be the recent ones — that is the
    /// spec's rule and the only ordering a person could predict. The count that
    /// was dropped is carried out in `skipped` and printed under the answer.
    private static func assemble(corpus: MacSearchCorpus,
                                 documents: [TraceMacDocument],
                                 people: [Person],
                                 places: [Place]) -> Assembled {
        var candidates: [(date: Date?, title: String, path: String,
                          destination: MacSearchDestination, kind: String,
                          meta: String, body: String, withheld: Bool)] = []

        for note in corpus.notes {
            candidates.append((note.modified, note.title, note.relativePath,
                               MacSearchEngine.destination(for: note),
                               noteKind(note.folder), note.folder, note.body, false))
        }

        for doc in documents where doc.category != "_to_delete" {
            // §5b. The tag is honoured here and nowhere else is enough: this is
            // the only function that decides what goes in the prompt, so a
            // second caller cannot reintroduce the hole. Same rule D93 states —
            // enforce a claim at the narrowest point every path crosses.
            let isPrivate = doc.tags.contains { $0.lowercased() == "private" }
            let body = isPrivate
                ? ""
                : [doc.description, doc.note, doc.summary, doc.extractedText]
                    .filter { !$0.isEmpty }.joined(separator: "\n")
            candidates.append((doc.created, doc.title, doc.relativePath,
                               .document(doc.relativePath), "document",
                               doc.tags.joined(separator: ", "), body, isPrivate))
        }

        for person in people {
            let body = [person.relationship, person.agenda]
                .compactMap { $0 }.joined(separator: "\n")
            candidates.append((nil, person.name, "", .person(person.id),
                               "person", person.relationship ?? "", body, false))
        }

        for place in places {
            let body = [place.notes, place.aiSummary].compactMap { $0 }.joined(separator: "\n")
            candidates.append((place.lastVisited, place.name, "", .place(place.id),
                               "place", [place.city, place.category].joined(separator: ", "),
                               body, false))
        }

        // **Sorted with a tiebreaker, and that is a caching requirement rather
        // than tidiness.** Swift's `sort` is not stable, so two records sharing
        // a date — or the many with no date at all, every person and place —
        // could come out in a different order on a later assembly. The cache
        // matches on bytes: one swapped pair anywhere in 91,000 characters is a
        // full miss and a full re-read at full price, with nothing on screen
        // saying why.
        candidates.sort { lhs, rhs in
            let left = lhs.date ?? .distantPast
            let right = rhs.date ?? .distantPast
            if left != right { return left > right }
            if lhs.path != rhs.path { return lhs.path < rhs.path }
            return lhs.title < rhs.title
        }

        let header = "Today is \(Self.today).\n\n<records>\n"
        var text = header
        var entries: [Entry] = []
        var skipped = 0
        var tokens = estimatedTokens(header)

        for candidate in candidates {
            let number = entries.count + 1
            let attributes = [
                "id=\"\(number)\"",
                "title=\"\(escape(candidate.title))\"",
                "kind=\"\(candidate.kind)\"",
                candidate.meta.isEmpty ? nil : "meta=\"\(escape(candidate.meta))\"",
                candidate.withheld ? "withheld=\"true\"" : nil
            ].compactMap { $0 }.joined(separator: " ")

            let block = candidate.withheld
                ? "<record \(attributes)>contents withheld — this document is tagged private</record>\n"
                : "<record \(attributes)>\n\(candidate.body)\n</record>\n"

            let cost = estimatedTokens(block)
            guard tokens + cost <= tokenBudget else { skipped += 1; continue }
            tokens += cost
            text += block
            entries.append(Entry(number: number,
                                 title: candidate.title,
                                 path: candidate.path,
                                 destination: candidate.destination,
                                 block: block,
                                 sortDate: candidate.date))
        }

        text += "</records>"
        return Assembled(text: text, entries: entries, skipped: skipped)
    }

    private static func noteKind(_ folder: String) -> String {
        switch folder {
        case "Calendar":                        return "daily note"
        case NoteStore.projectsFolder:          return "project note"
        case NoteStore.archivedProjectsFolder:  return "archived project note"
        case "Notes/Horizons":                  return "weekly note"
        case "Notes/Inbox":                     return "inbox note"
        case "Notes/People":                    return "person note"
        case "Notes/Places":                    return "place note"
        case "Notes/Endeavors":                 return "endeavor"
        default:                                return "note"
        }
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "'")
             .replacingOccurrences(of: "\n", with: " ")
    }

    private static var today: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE d MMMM yyyy"
        return formatter.string(from: Date())
    }

    // MARK: Citations

    /// Every `[n]` the answer actually contains, resolved back to a record.
    ///
    /// **Parsed out of the text rather than asked for as a JSON list.** The
    /// answer is the thing the user reads; a separate list could name a record
    /// the prose never cites, or miss one it does, and nothing would catch the
    /// disagreement. Numbers that match no record are dropped rather than shown
    /// — a citation to nothing is worse than no citation.
    private static func citations(in answer: String, from entries: [Entry]) -> [MacAskCitation] {
        guard let regex = try? NSRegularExpression(pattern: "\\[(\\d{1,4})\\]") else { return [] }
        let range = NSRange(answer.startIndex..., in: answer)
        let byNumber = Dictionary(uniqueKeysWithValues: entries.map { ($0.number, $0) })

        var seen = Set<Int>()
        var out: [MacAskCitation] = []
        for match in regex.matches(in: answer, range: range) {
            guard let numberRange = Range(match.range(at: 1), in: answer),
                  let number = Int(answer[numberRange]),
                  let entry = byNumber[number],
                  seen.insert(number).inserted else { continue }
            out.append(MacAskCitation(number: number,
                                      title: entry.title,
                                      path: entry.path,
                                      destination: entry.destination))
        }
        return out
    }
}
