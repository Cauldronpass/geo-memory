// DocumentSearchPredicate.swift — new file, Trace target, opted into by
// Satchel and TraceMac via `membershipExceptions`.
//
// **One predicate, because two were never kept in step.** Until now
// `SatchelDocumentSearch.matches` (iOS) and `TraceMacDocumentsView.matches(_:)`
// (Mac) answered the same question in two places by hand. D134 is the record
// of what that cost: the Mac was missing five fields the phone had matched for
// months, so a document findable in one second on the phone was unfindable on
// the Mac — including by the words printed on it, which is what you reach for
// when the AI title is unhelpful and all a `private` capture has.
//
// **Nobody reported it, and that is the point.** A search that returns too
// little still returns *something*, and a plausible short list makes no claim
// about what it left out. It surfaced only when the two predicates were read
// side by side. The comment left behind then said the two lists were written in
// the same order so a future reader could diff them by eye — which is a comment
// doing a compiler's job, and this file is that comment being retired.
//
// **Two known gaps are closed in the same move**, since they were only open
// because closing them twice was twice the work: iOS never matched `filename`,
// and **neither side matched `note` or `summary`**, so the note David himself
// types about a document was unsearchable on both platforms.
//
// **Token matching, not substring matching.** David: *"if I type Arlington
// Animal it should find Arlington Heights Animal Hospital even though i changed
// the order of the search terms."* Every search in this app did
// `haystack.contains(wholeQuery)`, so any reordering or any word in between
// failed. A query is now split on whitespace and **every token must appear
// somewhere in the document**, which is the behaviour people expect from a
// search box and the reason nobody thinks to report it as a bug — they just
// retype the query in a different order until it works.
//
// **"Somewhere in the document", not "in the same field" — David's call when
// asked.** A business card filed against `Notes/People/Mitch Weiss.md` matches
// "mitch invoice" because "Mitch" is in `people` and "invoice" is in the page's
// extracted text. The cost is that `extractedText` on a long PDF holds hundreds
// of common words, so a two-word query can land on a document that merely
// contains both somewhere. The looser rule was chosen deliberately, because the
// stricter one breaks exactly the query that motivated the fix.

import Foundation

enum DocumentSearch {

    /// Splits a raw query into lowercased tokens. Returns `[]` for an empty or
    /// whitespace-only query.
    ///
    /// **Lowercasing only, deliberately — not `TokenMatch.normalize`.** The
    /// place searches fold diacritics and strip punctuation because their
    /// haystacks always did; document haystacks never have, and folding one
    /// side without the other silently breaks matches. Stripping punctuation
    /// from a query would also make "2026-07-02" fail against a filename that
    /// still contains the dashes. **Each search keeps the normalisation it
    /// already had and gains only token order** — this pass is about word
    /// order, and changing two things at once is how you lose the ability to
    /// say which one broke it.
    ///
    /// Call this **once per search**, not once per document — it is the only
    /// reason `matches(_:tokens:)` is the primary entry point and the
    /// string-taking overload is the convenience.
    static func tokens(from raw: String) -> [String] {
        raw.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
    }

    /// True when **every** token appears somewhere in the document's searchable
    /// text.
    ///
    /// **Empty tokens means "no constraint" and returns true**, so a caller
    /// filtering an unsearched list gets everything. Both Satchel call sites
    /// guard on an empty query before they get here and the Mac's predicate
    /// used to spell this as `searchText.isEmpty || ...`; this collapses both
    /// into one honest default rather than leaving each caller to remember.
    static func matches(_ doc: TraceMacDocument, tokens: [String]) -> Bool {
        guard !tokens.isEmpty else { return true }

        // Cheap fields, built once per document. Ordered roughly by how likely
        // each is to carry the query, though every one of them is scanned
        // before `extractedText` is even lowercased.
        var haystacks: [String] = [
            doc.title.lowercased(),
            doc.filename.lowercased(),
            doc.description.lowercased(),
            // David's own note about the document, and the on-demand AI
            // summary. Neither side searched these before. The note is the one
            // piece of text on a document that a person deliberately wrote, and
            // it was the only such field that could not be found.
            doc.note.lowercased(),
            doc.summary.lowercased(),
            // The resolved icon and tint, not the stored ones: the row draws
            // the resolved pair, and a search that disagrees with the list it
            // filters is the same defect as two renderers that disagree (D127).
            doc.resolvedIcon.label.lowercased()
        ]
        haystacks.append(contentsOf: doc.tags.map { $0.lowercased() })
        haystacks.append(contentsOf: doc.people.map { $0.lowercased() })
        if let name = doc.endeavorName { haystacks.append(name.lowercased()) }
        if let note = doc.linkedNote { haystacks.append(noteDisplayName(note).lowercased()) }
        // **Colour by its MEANING, name second.** Nobody types "green" to mean
        // a bill, so `typeMeaning` is what carries the query: "bill",
        // "payment", "reservation", "policy", "keepsake" all land. The raw
        // token is matched too, for the case where you do know the palette.
        if let meaning = doc.resolvedTint.typeMeaning { haystacks.append(meaning.lowercased()) }
        haystacks.append(doc.resolvedTint.rawValue)

        // **The words on the page, last and lazily.** It is the whole text
        // layer of a PDF and there is no reason to lowercase it when the title
        // already matched. Computed at most once per document per search, no
        // matter how many tokens fall through to it.
        var lowercasedText: String?

        // Written out rather than delegated to `TokenMatch.matchesAll`, which
        // takes all its haystacks up front: `extractedText` must stay lazy, and
        // paying for it eagerly on every document in the library to save four
        // lines here would be a bad trade.
        for token in tokens {
            if haystacks.contains(where: { $0.contains(token) }) { continue }
            if lowercasedText == nil { lowercasedText = doc.extractedText.lowercased() }
            if lowercasedText?.contains(token) == true { continue }
            // One token found nowhere is enough to rule the document out —
            // every token must land, which is what makes word order irrelevant
            // rather than merely forgiving.
            return false
        }
        return true
    }

    /// Convenience for a single call. Prefer `tokens(from:)` plus
    /// `matches(_:tokens:)` when filtering a list, so the query is split once
    /// rather than once per document.
    static func matches(_ doc: TraceMacDocument, query: String) -> Bool {
        matches(doc, tokens: tokens(from: query))
    }

    /// `Notes/People/Mitch Weiss.md` → `Mitch Weiss`.
    static func noteDisplayName(_ path: String) -> String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }
}

// MARK: - Token matching, used beyond documents

/// The token rule on its own, so the place searches can share it too.
///
/// **Added the same pass as the document predicate**, because the whole-string
/// bug David reported was never a Satchel bug: *every* search in this app did
/// `haystack.contains(wholeQuery)`, including Discover's on both platforms.
/// Fixing only the one he happened to name would have left three searches
/// disagreeing about what a two-word query means, which is the drift this file
/// exists to end.
enum TokenMatch {

    /// Lowercased, diacritic-folded, punctuation-stripped tokens.
    ///
    /// **The folding is not decoration.** Discover's place filter already
    /// normalised this way — "Cafe" had to find "Café" and a trailing comma in
    /// an address had to not matter — and a token splitter that skipped it
    /// would have quietly made those searches worse while fixing word order.
    static func tokens(from raw: String) -> [String] {
        normalize(raw)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
    }

    /// Normalises one haystack the same way `tokens(from:)` normalises the
    /// query. Both sides must agree or the folding does nothing.
    static func normalize(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.punctuationCharacters)
            .joined()
    }

    /// True when every token appears in at least one haystack.
    ///
    /// Haystacks must already be normalised by the caller — they are usually
    /// reused across many tokens, and normalising inside would redo that work
    /// per token.
    static func matchesAll(_ tokens: [String], inNormalized haystacks: [String]) -> Bool {
        guard !tokens.isEmpty else { return true }
        for token in tokens {
            if !haystacks.contains(where: { $0.contains(token) }) { return false }
        }
        return true
    }
}
