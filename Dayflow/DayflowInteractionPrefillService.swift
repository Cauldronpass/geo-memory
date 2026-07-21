import Foundation

// MARK: - DayflowInteractionPrefillService
//
// Session 28 — AI-prefill for the "Log an Interaction in Trace" (person) and
// "Log a Visit in Trace" (place) hand-off buttons in DayflowWikiSummaryView.swift.
// Design locked Session 27 (person scope only), extended to place scope in
// Session 27's addendum — see Dayflow-HANDOFF.md for the full design writeup.
//
// Mirrors OTScanService.swift's pattern exactly: same
// https://api.anthropic.com/v1/messages endpoint, same Config.claudeAPIKey,
// same "ask for JSON only, strip code fences, decode" approach — just a text
// block in the request instead of a base64 image. Dayflow does the search +
// Claude call itself, using the note text already sitting in the calling
// editor's own @State (no re-read from disk needed). Trace never gets its own
// Claude integration for this — Dayflow passes the finished suggestion to
// Trace as query params on the trace:// hand-off URL.
//
// CRM-light boundary (Session 17, still governing): this service only ever
// *suggests* text for a field Trace's own sheet already has — nothing here
// writes to Notion. If the Claude call fails or times out for any reason, the
// caller just gets nil back and the hand-off opens exactly as it did before
// this feature existed (blank Type/Notes, David fills in by hand).

struct DayflowPrefillSuggestion {
    /// nil for the place ("Log a Visit") case — CheckInView has no Type field,
    /// only LogInteractionSheet's person case does.
    let type: String?
    let notes: String?
}

enum DayflowInteractionPrefillService {

    // MARK: Three-tier source-text resolution (locked design, Session 27)
    //
    // 1. Last occurrence of today's date stamp, formatted exactly as
    //    MarkdownEditorView.swift's toolbar calendar button inserts it
    //    ("MMMM d, yyyy" — confirmed real inline text, not a placeholder or
    //    structural marker). If found, take everything from there to the end
    //    of the note as "today's slice."
    // 2. Confirm that slice actually contains a wikilink to the target
    //    ([[Name]]). If it does, that slice is the source text. If a date
    //    stamp was found but the target isn't mentioned in that slice, don't
    //    guess at a different search — return nil (degrades to a blank field
    //    for manual entry, per David's explicit call on this).
    // 3. Only if no date stamp for today exists anywhere in the note at all:
    //    fall back to the last paragraph (split on blank lines) that mentions
    //    the target.
    //
    // "Last occurrence wins" applies symmetrically to both the date-stamp
    // search and the wikilink search — confirmed explicitly with David.
    static func resolveSourceText(noteText: String?, targetName: String) -> String? {
        guard let noteText, !noteText.isEmpty else {
            print("[DayflowPrefill] resolveSourceText: no source note text at all")
            return nil
        }

        let wikilink = "[[\(targetName)]]"

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone.current
        dateFormatter.dateFormat = "MMMM d, yyyy"
        let todayStamp = dateFormatter.string(from: Date())

        if let dateRange = noteText.range(of: todayStamp, options: .backwards) {
            let slice = String(noteText[dateRange.lowerBound...])
            let matched = slice.contains(wikilink)
            print("[DayflowPrefill] resolveSourceText: searching for \(wikilink) — today's date stamp found in note; present in the slice after it = \(matched)")
            return matched ? slice : nil
        }

        // No date stamp anywhere in the note — last paragraph mentioning the target.
        // Diagnostic (content-safe — no note text echoed): reports whether the literal
        // wikilink string exists ANYWHERE in the note vs. specifically within one
        // \n\n-delimited paragraph, so a paste that introduced an extra blank line
        // (splitting the wikilink from its description into two separate paragraphs)
        // shows up as "contains wikilink = true" but "matched paragraph = false".
        let paragraphs = noteText.components(separatedBy: "\n\n")
        let match = paragraphs.last(where: { $0.contains(wikilink) })
        print("[DayflowPrefill] resolveSourceText: searching for \(wikilink) — no date stamp; \(paragraphs.count) paragraph(s) total; note contains wikilink literal anywhere = \(noteText.contains(wikilink)); matched within one paragraph = \(match != nil)")
        return match
    }

    // MARK: Claude suggestion calls

    static func suggestForPerson(sourceText: String, personName: String) async -> DayflowPrefillSuggestion? {
        // Prompt loosened Session 28 continued — David hit this exact null-out on the
        // place side (see suggestForPlace below) with a note written in anticipatory
        // tense ("Today is the day for pool... I hope to win"); Claude read "planned
        // for later" and correctly followed the old instruction to bail. His call:
        // tapping the hand-off button IS the confirmation this is worth logging —
        // don't have Claude re-litigate that, regardless of tense. Applied here too
        // for consistency even though this prompt hadn't failed yet in practice.
        let prompt = """
            This is an excerpt from a personal journal note that mentions \(personName), \
            pulled because David just tapped "Log an Interaction in Trace" for \
            \(personName) — he's already confirmed this is worth logging, so don't \
            second-guess whether it counts as a real interaction. Suggest a brief \
            "Log Interaction" entry for a personal CRM app, based only on what's \
            actually written — don't invent details, and don't worry about tense (an \
            interaction that's upcoming or in progress is just as valid to summarize as \
            one already finished). Return JSON only, no explanation: \
            {"type": one of "visit", "dinner", "lunch", "coffee", "call", "video call", "text", \
            "email", "meeting", "event", "workout", "other", "notes": a short 1-2 sentence \
            summary in your own words}. Only return {"type": null, "notes": null} if the \
            excerpt truly has nothing to summarize beyond the bare mention of \(personName)'s name.

            Excerpt:
            \(sourceText)
            """
        guard let result: PersonSuggestionResult = await call(prompt: prompt) else {
            print("[DayflowPrefill] suggestForPerson: call() returned nil — see the preceding log line for why")
            return nil
        }
        guard result.type != nil || result.notes != nil else {
            print("[DayflowPrefill] suggestForPerson: Claude decided this wasn't a real interaction (type and notes both null)")
            return nil
        }
        return DayflowPrefillSuggestion(type: result.type, notes: result.notes)
    }

    static func suggestForPlace(sourceText: String, placeName: String) async -> DayflowPrefillSuggestion? {
        // Prompt loosened Session 28 continued — David's real test: "Today is the day
        // for pool at [[Arlington Lanes]]. I hope to win..." resolveSourceText found
        // the excerpt correctly (confirmed via console), but Claude read the
        // anticipatory tense as "planned for later" and returned notes: null per the
        // old instruction below. David's call: tapping "Log a Visit in Trace" IS the
        // confirmation this is a real visit worth logging — don't have Claude
        // re-litigate that from tense alone.
        let prompt = """
            This is an excerpt from a personal journal note that mentions \(placeName), \
            pulled because David just tapped "Log a Visit in Trace" for \(placeName) — \
            he's already confirmed this is worth logging, so don't second-guess whether \
            it counts as a real visit. Suggest a short "notes" summary for a personal CRM \
            app's visit log, based only on what's actually written — don't invent details, \
            and don't worry about tense (a visit that's upcoming or in progress is just as \
            valid to summarize as one already finished). Return JSON only, no explanation: \
            {"notes": a short 1-2 sentence summary in your own words, or null only if the \
            excerpt truly has nothing to summarize beyond the bare mention of \(placeName)'s name}.

            Excerpt:
            \(sourceText)
            """
        guard let result: PlaceSuggestionResult = await call(prompt: prompt) else {
            print("[DayflowPrefill] suggestForPlace: call() returned nil — see the preceding log line for why")
            return nil
        }
        guard let notes = result.notes else {
            print("[DayflowPrefill] suggestForPlace: Claude decided this wasn't a real visit (notes null)")
            return nil
        }
        return DayflowPrefillSuggestion(type: nil, notes: notes)
    }

    // MARK: - Private

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let model = "claude-sonnet-5"
    private static var apiKey: String { Config.claudeAPIKey }

    private struct PersonSuggestionResult: Decodable { let type: String?; let notes: String? }
    private struct PlaceSuggestionResult: Decodable { let notes: String? }

    private static func call<T: Decodable>(prompt: String) async -> T? {
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 512,
            "messages": [
                ["role": "user", "content": prompt]
            ]
        ]
        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else {
            print("[DayflowPrefill] call: failed to encode request body")
            return nil
        }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = httpBody

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            print("[DayflowPrefill] call: network request failed — \(error.localizedDescription)")
            return nil
        }

        guard let http = response as? HTTPURLResponse else {
            print("[DayflowPrefill] call: no HTTP response")
            return nil
        }
        guard http.statusCode == 200 else {
            let rawBody = String(data: data, encoding: .utf8) ?? "<no body>"
            print("[DayflowPrefill] call: HTTP \(http.statusCode) — \(rawBody.prefix(300))")
            return nil
        }

        guard let envelope = try? JSONDecoder().decode(PrefillClaudeEnvelope.self, from: data),
              let text = envelope.content.first(where: { $0.type == "text" })?.text else {
            let rawBody = String(data: data, encoding: .utf8) ?? "<undecodable>"
            print("[DayflowPrefill] call: couldn't unwrap Claude's response envelope — \(rawBody.prefix(300))")
            return nil
        }

        // Hardened this session — extractJSON now pulls the {...} substring out
        // of Claude's reply instead of requiring the *entire* trimmed response to
        // already be valid JSON. stripCodeFence alone only handled the
        // code-fence-wrapped case; a reply with any surrounding prose despite the
        // "JSON only, no explanation" instruction would fail JSONDecoder outright
        // and silently return nil here, indistinguishable from every other
        // failure mode. This doesn't change behavior for a clean JSON reply.
        let jsonString = extractJSON(text)
        guard let jsonData = jsonString.data(using: .utf8) else {
            print("[DayflowPrefill] call: extracted JSON string wasn't valid UTF-8")
            return nil
        }
        do {
            return try JSONDecoder().decode(T.self, from: jsonData)
        } catch {
            print("[DayflowPrefill] call: JSON decode failed (\(error)) — Claude said: \(text.prefix(300))")
            return nil
        }
    }

    private static func stripCodeFence(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix("```") else { return s }
        let lines = s.components(separatedBy: "\n")
        return lines.dropFirst().dropLast()
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractJSON(_ raw: String) -> String {
        let stripped = stripCodeFence(raw)
        if let start = stripped.firstIndex(of: "{"), let end = stripped.lastIndex(of: "}"), start < end {
            return String(stripped[start...end])
        }
        return stripped
    }
}

// MARK: - Private response envelope
//
// Deliberately named PrefillClaudeEnvelope/PrefillClaudeBlock rather than
// reusing OTScanService.swift's private ClaudeEnvelope/ClaudeBlock — both
// pairs are file-private (Swift's top-level `private` is file-scoped), so
// there's no actual collision, but distinct names avoid any confusion for a
// future session reading both files side by side.

private struct PrefillClaudeEnvelope: Decodable {
    let content: [PrefillClaudeBlock]
}

private struct PrefillClaudeBlock: Decodable {
    let type: String
    let text: String?
}
