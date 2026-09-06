// MacLocalIntelligence.swift — Apple's on-device model, for documents that must
// not leave this Mac.
//
// Session 71. David, after a local tag pass turned his sentence into eleven
// tags including "this", "the" and "her": *"there is no reasoning that the AI
// can give to get better?… It should look at the meaning of what i was trying
// to get across and use a few and only a few (say 3 at most) tags that get at
// that intention."*
//
// He is right, and the honest answer was that a keyword heuristic cannot do
// that — but a language model can, and since the 26 releases there is one on
// the machine. **Nothing here touches the network.** That is the entire point:
// this path exists for documents tagged `private`, where the alternative was a
// bank statement going to an API or a screenshot called
// `CleanShot 2026-08-14 at 17.35.50` forever.
//
// **Shared, as of the same session it was written.** It began Mac-only in
// `TraceMac/` on the argument that no iOS screen needed it. That stopped being
// true within hours: Satchel's private capture refuses the cloud scan by
// design, so a privately captured document arrived named after its own file.
// The local pass is the only thing that can title it, and it is exactly what
// this was built for.
//
// Now in `Trace/`, with membership in TraceMac and Satchel. The prefix is
// vestigial and stays, for the reason the search engine's filenames stayed:
// renaming the file while the types keep the `Mac` prefix makes the name
// promise something the contents do not.
//
// **Availability is checked, never assumed.** The model needs Apple silicon,
// a supported OS, Apple Intelligence switched on, and the assets downloaded —
// four things, any of which can be false on a machine that compiles this fine.
// David's Mini is an M4 on macOS 26.3.1 with it enabled, which is why this is
// worth building; a future machine, or his phone, will not necessarily be. The
// caller gets `nil` and falls back rather than an error it has to explain.
//
// **`canImport` guard on the framework itself.** If the module is not present
// in whatever SDK this is built against, the file still compiles and the whole
// feature reports unavailable. A build failure in a privacy fallback is a
// worse outcome than the fallback being off.

import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

enum MacLocalIntelligence {

    /// Why the on-device model cannot be used, in words a person can act on.
    enum Availability: Equatable {
        case ready
        /// The framework is not in this SDK at all.
        case notBuilt
        /// Present, but the machine or its settings say no.
        case unavailable(String)

        var isReady: Bool { self == .ready }
    }

    /// What the model is asked to produce. Three tags is David's number, and it
    /// is a ceiling rather than a target: two good ones beat three with a filler.
    struct Suggestion: Sendable {
        let tags: [String]
        let summary: String
    }

    /// A confirmation read on this machine (Session 92, D319/D322).
    ///
    /// **All strings, and empty means absent.** The cloud path gets JSON with
    /// real nulls; guided generation on device is happier filling a fixed set
    /// of string fields than reasoning about which ones to omit, and an empty
    /// string is a shape it cannot get wrong. The Mac side turns these into a
    /// `BookingParse`, which is where the dates are parsed and the Kind is
    /// matched against the seven — the same conversion the cloud answer gets,
    /// so a field means the same thing whichever model read it.
    ///
    /// **No cost currency, no count of bookings, no notes.** Nine fields is
    /// already a lot to ask of a small on-device model, and those three are the
    /// ones a wrong answer would be least useful and most confident about.
    struct BookingFacts: Sendable {
        let kind: String
        let provider: String
        let number: String
        let confirmation: String
        let from: String
        let to: String
        let start: String
        let end: String
        let cost: String
    }

#if canImport(FoundationModels)

    @Generable
    struct DocumentFacts {
        @Guide(description: "At most three short lowercase tags naming what this document IS and who or what it concerns. Single words or hyphenated pairs. No generic words like document, file, page, text, information.")
        var tags: [String]

        @Guide(description: "One plain sentence saying what this document is, naming the organisation and the subject if they appear. No preamble, no 'this document'.")
        var summary: String
    }

    @Generable
    struct BookingDraft {
        @Guide(description: "Exactly one of: Flight, Shuttle, Train, Hotel, Car rental, Parking, Other. Empty string if the text does not say which.")
        var kind: String

        @Guide(description: "Who provides it: the airline, the hotel brand, the rental company, the shuttle operator. Empty string if absent.")
        var provider: String

        @Guide(description: "The reference for the thing itself, printed on the ticket or the door: a flight number, a room number, a rental reservation number. Empty string if absent.")
        var number: String

        @Guide(description: "The booking confirmation code, the one you would read out on the phone. Empty string if absent.")
        var confirmation: String

        @Guide(description: "Where it departs from, as an airport code or a city. Empty string for a hotel or a car park.")
        var from: String

        @Guide(description: "Where it arrives; for a stay, the city it is in. Empty string if absent.")
        var to: String

        @Guide(description: "Departure or check-in, written as 2026-11-25T17:40 when a clock time is printed, or 2026-11-25 when only a day is. Empty string if absent.")
        var start: String

        @Guide(description: "Arrival or check-out, in the same format as start. Empty string if absent.")
        var end: String

        @Guide(description: "The total cost, digits and a decimal point only, for example 318.40. No currency symbol. Empty string if no figure is printed.")
        var cost: String
    }

    /// Reads a confirmation without the text leaving this Mac (D322).
    ///
    /// **This is the whole point of the private verb.** A boarding pass carries
    /// a full name, a record locator and sometimes a card's last four; the
    /// alternative to this path was those going to an API or the document not
    /// being read at all. It will do a worse job than the cloud model and that
    /// is the trade being made, knowingly — every field it fills is editable on
    /// the sheet before anything is saved.
    ///
    /// Returns `nil` on any failure, an unavailable model included. The caller
    /// opens the same empty sheet with the same line it shows when a document
    /// could not be read, which is the honest description of what happened.
    static func parseBooking(text: String) async -> BookingFacts? {
        guard availability.isReady else { return nil }

        // Same cap as `suggest`. A confirmation's useful half is the top of it:
        // the legs, the code and the fare come before the fare rules.
        let body = String(text.prefix(4_000))

        do {
            let session = LanguageModelSession(
                instructions: """
                You read travel confirmations for a private filing system. \
                You are precise and brief. Every field you cannot find in the \
                text is an empty string. You never invent a name, a code, a \
                date or a figure, and you never carry one over from another \
                booking in the same document. Dates keep the year printed on \
                the document; you never substitute the current year to make an \
                old confirmation look upcoming.
                """
            )
            let reply = try await session.respond(
                to: """
                Read this confirmation and fill in the fields. If it holds \
                more than one booking, describe only the first.

                \(body)
                """,
                generating: BookingDraft.self
            )
            let d = reply.content
            return BookingFacts(kind: d.kind,
                                provider: d.provider,
                                number: d.number,
                                confirmation: d.confirmation,
                                from: d.from,
                                to: d.to,
                                start: d.start,
                                end: d.end,
                                cost: d.cost)
        } catch {
            return nil
        }
    }

    static var availability: Availability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .ready
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return .unavailable("This Mac cannot run the on-device model.")
            case .appleIntelligenceNotEnabled:
                return .unavailable("Turn on Apple Intelligence in System Settings to use the local option.")
            case .modelNotReady:
                return .unavailable("The on-device model is still downloading. Try again in a few minutes.")
            @unknown default:
                return .unavailable("The on-device model is not available right now.")
            }
        @unknown default:
            return .unavailable("The on-device model is not available right now.")
        }
    }

    /// Tags and a one-line summary, read on this machine and sent nowhere.
    ///
    /// `hint` is what David typed in Context. It is passed as the person's own
    /// statement of intent rather than as more text to mine — the whole reason
    /// the keyword version failed is that it could not tell the difference
    /// between a sentence describing the document and the document itself.
    ///
    /// Returns `nil` on any failure, including an unavailable model. The caller
    /// has a working fallback and does not need an error to explain.
    static func suggest(text: String, hint: String) async -> Suggestion? {
        guard availability.isReady else { return nil }

        // A cap, because a 20,000 character page would be most of the context
        // window and the useful part of a statement is the top of it.
        let body = String(text.prefix(4_000))
        let trimmedHint = hint.trimmingCharacters(in: .whitespacesAndNewlines)

        var prompt = """
        Read the text below, taken from a document by on-device OCR. It may be a \
        table read one cell per line, so a label is often followed by its value.
        """
        if !trimmedHint.isEmpty {
            prompt += """


            The owner of this document describes it as: \(trimmedHint)
            Treat that as true and let it guide the tags.
            """
        }
        prompt += "\n\nDocument text:\n\(body)"

        do {
            let session = LanguageModelSession(
                instructions: """
                You label personal documents for a private filing system. \
                You are precise and brief. You never invent facts that are not \
                in the text or in the owner's description.
                """
            )
            let reply = try await session.respond(to: prompt, generating: DocumentFacts.self)
            let facts = reply.content
            return Suggestion(tags: clean(facts.tags), summary: facts.summary
                .trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            return nil
        }
    }

#else

    static var availability: Availability { .notBuilt }

    static func suggest(text: String, hint: String) async -> Suggestion? { nil }

    static func parseBooking(text: String) async -> BookingFacts? { nil }

#endif

    /// Tidies what the model returned. **Trust it for meaning, not for shape.**
    /// A tag with a trailing full stop is exactly the defect the keyword version
    /// shipped, and it is cheaper to fix here than to explain in the prompt.
    static func clean(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for tag in raw {
            let t = tag
                .trimmingCharacters(in: CharacterSet.alphanumerics.inverted.subtracting(CharacterSet(charactersIn: "-")))
                .lowercased()
            guard t.count >= 2, t.count <= 24, seen.insert(t).inserted else { continue }
            out.append(t)
            if out.count == 3 { break }
        }
        return out
    }
}
