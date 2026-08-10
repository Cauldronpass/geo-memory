// DayflowEndeavor.swift
// Dayflow
//
// An Endeavor is a trip, a project, or anything else with a beginning, an end,
// and things that accumulate against it. Full design record and the sixteen
// locked decisions: `Endeavor-Design.md` (vault). The load-bearing ones:
//
// **D2 — the NOTE is the source of truth, not Notion.** One markdown file per
// Endeavor at `Notes/Endeavors/<name>.md` in the shared container. `type`,
// `status` and the dates live in its frontmatter. This revises the original
// scope §3, which had a Notion page ID as authoritative. There is no Notion
// Endeavor database and there is not going to be one (D11) — every field it
// would have held either moved here, belongs to a document sidecar, is already
// a `[[wikilink]]`, or is computable.
//
// **D9 — identity is a stable slug**, `id: japan-2026`, assigned once and never
// edited. Not the note's path: rename "Japan" to "Japan — Harvey's 70th" in
// August and a path-keyed link would silently orphan every document filed to
// it, with no error and nothing on screen to explain it.
//
// **D12 — status is DERIVED, not stored.** No start date means an idea; a start
// in the future means upcoming; between the dates means active; past the end
// means past. All of it read off two numbers already in the file. This is what
// retires weekly-sweep Step 1c, a Sunday job whose whole purpose was writing
// down an answer the dates already contained. The one stored field is an
// override for the two states a calendar genuinely cannot express — paused and
// abandoned. "Done" is not a status, it is an end date.
//
// **D4 — the editor never sees the frontmatter.** The screen parses it, strips
// it, hands the editor pure prose, and draws the header itself. Raw
// `starts: 2026-09-14` must never render as body text.
//
// WHERE THIS FILE LIVES. `Dayflow/`, so it needs no target-membership step.
// When Satchel adopts Endeavors (build step 11, unblocked by D2 — its picker
// becomes a folder scan rather than a Notion query), this moves to `Trace/` and
// is ticked into both. At that point **`Satchel/SatchelEndeavor.swift`'s own
// `Endeavor` and `SatchelEndeavorStore` must be deleted** — they are the stub
// this replaces, and two types with one name in one target will not compile.

import Foundation
import WidgetKit
import Observation
import ImageIO
import CoreGraphics

// MARK: - Model and status: MOVED
//
// Session 64. `EndeavorStatus` and `struct Endeavor` now live in
// `Trace/Endeavor.swift`, shared by Trace, Dayflow, Jot and TraceMac, with
// the frontmatter parser beside them as `EndeavorFile`.
//
// The trigger was the one this codebase named for itself: SatchelEndeavor.swift
// said the duplicate was tolerable *because there were only two*. TraceMac made
// three. Moved verbatim — every line of the struct and the enum is byte-identical
// to what was here, verified by hashing the sorted non-blank lines of the original
// against the parts.
//
// What stayed in this file: `EndeavorStore` (read/write, covers, create, delete),
// `TripLog`, the widget feed and agenda surfacing. The store's `slug`, `date`,
// `string`, `bool`, `safeFilename` and `splitFrontmatter` statics are still here
// as one-line forwarders to `EndeavorFile`, so none of their call sites moved.
// MARK: - Store

@Observable
final class EndeavorStore {

    static let shared = EndeavorStore()

    private(set) var endeavors: [Endeavor] = []
    private(set) var isLoading = false

    static let folder = "Notes/Endeavors"

    private var noteStore: NoteStore { .shared }

    private init() { }

    // MARK: Load

    /// Reads every Endeavor note. No caching, deliberately — the same decision
    /// the document chip reader arrived at after three cache bugs in two days.
    /// There will be tens of these files, not thousands.
    func reload() {
        guard noteStore.hasAccess else { return }
        isLoading = true
        defer { isLoading = false }

        let files = (try? noteStore.listFiles(in: Self.folder)) ?? []
        endeavors = files
            .filter { $0.hasSuffix(".md") }
            .compactMap { parse(filename: $0) }
            .sorted { $0.sortKey() < $1.sortKey() }

        // Republish on every reload rather than only on save. `reload()` is what
        // runs after an edit made anywhere, including one made on another device
        // and synced in, and the feed is cheap to write. A widget showing last
        // week's trip because the edit happened somewhere this code did not watch
        // is the failure worth spending a few hundred bytes to avoid.
        publishWidgetFeed()
    }

    func endeavor(id: String) -> Endeavor? {
        endeavors.first { $0.id == id }
    }

    // MARK: Parse

    private func parse(filename: String) -> Endeavor? {
        let path = "\(Self.folder)/\(filename)"
        guard let raw = try? noteStore.readFile(path) else { return nil }
        // The whole body of this function moved to `EndeavorFile.parse`, which
        // Satchel will call too once it compiles `Trace/`. Reading the file is
        // the only part that is this store's business.
        return EndeavorFile.parse(raw: raw, path: path, filename: filename)
    }



    // MARK: Save

    /// Writes frontmatter + body. The body is passed through untouched.
    ///
    /// Keys are written in a fixed order so a file does not churn in git or in
    /// iCloud's version history every time an unrelated field changes. Empty
    /// optional values are omitted rather than written blank — `ends:` with
    /// nothing after it parses back as nil anyway, and its absence reads as
    /// "open-ended" to a human.
    func save(_ endeavor: Endeavor) throws {
        // Rendered by `EndeavorFile`, Session 65, so TraceMac can write these
        // files too. The key order and the omit-empty rule the comment above
        // describes moved with it, verbatim; nothing about the output changed.
        try noteStore.writeFile(endeavor.relativePath,
                                content: EndeavorFile.render(endeavor))
        reload()

        // BELT AND BRACES. `reload()` opens with `guard noteStore.hasAccess`
        // and rescans the folder — so if the container is momentarily
        // unavailable, or the just-written file has not settled by the time the
        // directory is listed, it returns without the thing that was only just
        // saved. The write already succeeded at this point, so the model is
        // known-good; show it rather than pretending it does not exist.
        //
        // Without this, a successful create is indistinguishable from a failed
        // one: the sheet closes and the list is still empty. David hit exactly
        // that on the first run, 2026-07-29.
        if !endeavors.contains(where: { $0.id == endeavor.id }) {
            endeavors.append(endeavor)
            endeavors.sort { $0.sortKey() < $1.sortKey() }
        }
    }

    // MARK: Cover

    /// Stores a cover image and points the Endeavor at it.
    ///
    /// **Copied into the container, referenced by path — never a URL** (D8). A
    /// trip note whose cover is a remote link goes blank on a plane, which is
    /// precisely the moment it is most likely to be open.
    ///
    /// FILENAME IS STAMPED, NOT FIXED — `<slug>-yyyyMMdd-HHmmss.jpg`.
    ///
    /// It was `<slug>.jpg` until 2026-07-29, on the reasoning that re-choosing a
    /// cover should overwrite rather than litter. That reasoning was right about
    /// storage and wrong about everything else: **the path in the note never
    /// changed, so nothing on screen ever changed.** `EndeavorCoverImage` keys
    /// its load on the path, the list row keys its thumbnail on the path, and
    /// iCloud tracks bytes by path too. David chose a new photograph, it was
    /// written correctly, and the old one stayed on screen. A new filename makes
    /// the replacement observable everywhere at once, which is the only version
    /// of this that does not need a cache-busting trick in every view.
    ///
    /// Previous covers are deleted after the note points at the new one — see
    /// `pruneCovers`.
    ///
    /// Downscaled first. A modern phone photo is 3-5MB and this is drawn at
    /// 132pt — storing the original would put tens of megabytes into a container
    /// whose entire premise is that everything in it is worth carrying.
    @discardableResult
    func setCover(_ imageData: Data, credit: String? = nil,
                  for endeavor: Endeavor) throws -> Endeavor {
        // RE-READ before writing. Every caller holds a snapshot taken when its
        // screen was built — the details sheet and the Commons picker both do —
        // and saving that snapshot back would quietly undo whatever else has
        // changed since. One guard here covers all of them.
        let base = endeavors.first { $0.id == endeavor.id } ?? endeavor

        // Downscaling, the stamped filename and the matcher that recognises it
        // all moved to `EndeavorFile` in Session 65, so TraceMac writes covers
        // by the same rule this one prunes by. Behaviour unchanged.
        let data = EndeavorFile.downscaledJPEG(imageData) ?? imageData
        let filename = EndeavorFile.coverFilename(slug: base.id)
        let path = try noteStore.writePhoto(data, category: "Endeavors", filename: filename)

        var updated = base
        updated.cover = path
        // Overwritten every time, including to nil — a credit left over from a
        // previous cover is worse than none, because it names the wrong
        // photographer.
        updated.coverCredit = credit?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        try save(updated)

        // AFTER the save, never before. A delete that went first would leave the
        // note pointing at a file that no longer exists if the save then failed.
        pruneCovers(for: base.id, keeping: filename)
        return updated
    }

    /// Removes this Endeavor's earlier cover files, keeping the current one.
    ///
    /// Needed only because the filename is stamped now. Also sweeps up the file
    /// `clearCover` deliberately leaves behind, and the pre-2026-07-29
    /// `<slug>.jpg` from before stamping existed, so no migration is required.
    ///
    /// MATCHED NARROWLY, and this is not fussiness. A plain prefix match on
    /// "<slug>-" would let the Endeavor `japan` delete the covers belonging to
    /// `japan-2027`. So the part after the slug has to be exactly a stamp.
    ///
    /// Failures are swallowed: an undeleted old cover is 200KB of clutter, and
    /// throwing here would fail a `setCover` that has already fully succeeded.
    private func pruneCovers(for slug: String, keeping current: String) {
        // `listDocumentFiles`, NOT `listFiles` — the latter filters to ".md"
        // only, so it would find no covers at all and this would silently do
        // nothing. The name says "for Documents/ subfolders"; it takes any path.
        let files = (try? noteStore.listDocumentFiles(in: "Photos/Endeavors")) ?? []
        for file in files where file != current {
            guard EndeavorFile.isCoverFile(file, slug: slug) else { continue }
            try? noteStore.deleteFile("Photos/Endeavors/\(file)")
        }
    }

    /// Forwarder, Session 65. The implementation moved to `EndeavorFile`.
    static func isStampedCover(_ filename: String, slug: String) -> Bool {
        EndeavorFile.isStampedCover(filename, slug: slug)
    }

    /// Clears the reference. **Leaves the file**, deliberately: an image is
    /// cheap and a mis-tap that silently destroys a photo is not.
    ///
    /// The old justification was "it is overwritten next time anyway, since the
    /// filename is the slug". Stamped filenames killed that, so `pruneCovers`
    /// picks the orphan up the next time a cover is set — the outcome is the
    /// same, by a different route.
    func clearCover(for endeavor: Endeavor) throws {
        // Same re-read as setCover, for the same reason.
        var updated = endeavors.first { $0.id == endeavor.id } ?? endeavor
        updated.cover = nil
        updated.coverCredit = nil
        try save(updated)
    }

    /// ImageIO rather than UIKit, matching the fix already made in
    /// `IOSDocumentScanService.resizeImageData` — it is off the main actor and it
    /// respects EXIF orientation, which the UIKit path got wrong on portrait
    /// photos.
    /// Forwarder, Session 65. The implementation moved to `EndeavorFile`.
    static func downscaledJPEG(_ data: Data, maxDimension: CGFloat = 1600) -> Data? {
        EndeavorFile.downscaledJPEG(data, maxDimension: maxDimension)
    }

    /// Reads a cover back, waiting for iCloud when the bytes are not local yet.
    ///
    /// Same shape as the fix to Satchel's PDF viewer: a file can exist in the
    /// container as a stub before it has downloaded, and asking for it directly
    /// returns nothing with no error — which draws as a blank space and reads as
    /// a bug.
    /// The actual read, split out and **`nonisolated`** so it can run off the main
    /// actor.
    ///
    /// `EndeavorCoverImage` reads covers inside `Task.detached` precisely because
    /// this can block: an undownloaded iCloud file makes it wait on the download
    /// and then on a file coordinator. But `coverData` is main-actor isolated (it
    /// touches `noteStore`), so calling it from a detached task was a cross-actor
    /// call — *"Expression is 'async' but is not marked with 'await'; this is an
    /// error in the Swift 6 language mode"*.
    ///
    /// Adding `await` would have silenced the warning by hopping the read **back
    /// onto the main actor**, which is the opposite of what the detached task is
    /// for — a green build that reintroduces a hitch. Splitting the path
    /// resolution (main actor, cheap) from the bytes (nonisolated, slow) keeps the
    /// work where it belongs and leaves one copy of the download-and-coordinate
    /// logic.
    nonisolated static func coverBytes(at url: URL) -> Data? {
        if let data = try? Data(contentsOf: url) { return data }

        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        var bytes: Data?
        var coordinatorError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinatorError) { readURL in
            bytes = try? Data(contentsOf: readURL)
        }
        return bytes
    }

    // MARK: Delete

    /// Removes the note.
    ///
    /// WHAT THIS DOES NOT DO, on purpose: it does not touch documents. A
    /// sidecar filed against this Endeavor keeps `endeavor: <slug>` and its
    /// cached `endeavor_name`, and one linked to the note keeps `linked_note`.
    /// Satchel owns sidecars (scope §7) and Dayflow reaching into them to tidy
    /// up would make it a second writer — the exact thing the whole cross-app
    /// model exists to prevent.
    ///
    /// The consequence is a document pointing at a slug nothing answers to. It
    /// renders from the cached name and files under nothing, which is survivable
    /// and honest. Silently rewriting somebody's documents because they deleted
    /// a trip note would not be.
    func delete(_ endeavor: Endeavor) throws {
        try noteStore.deleteFile(endeavor.relativePath)
        endeavors.removeAll { $0.id == endeavor.id }
        reload()
    }

    // MARK: Create

    /// Creates the note, with the five fixed sections already in place (D5).
    ///
    /// The sections are seeded rather than left to the user because "not
    /// free-form" is the entire point: the same five headings every time, with
    /// their meaning shifting by type — Plan is an itinerary for a trip and a
    /// list of stages for a renovation.
    @discardableResult
    func create(name: String, type: String, starts: Date?, ends: Date?,
                destination: String? = nil, placeID: String? = nil,
                stampsCaptures: Bool? = nil) throws -> Endeavor {
        let endeavor = EndeavorFile.newEndeavor(
            name: name,
            type: type,
            starts: starts,
            ends: ends,
            destination: destination,
            placeID: placeID,
            stampsCaptures: stampsCaptures,
            existingIDs: endeavors.map(\.id)
        )
        try save(endeavor)
        return endeavor
    }

    /// NO `# Name` HEADING. The name already appears twice above the editor —
    /// in the navigation bar and in the header card — so a third copy inside the
    /// body was pure repetition, and at 22pt against the sections' 19pt it did
    /// not read as a title so much as a slightly larger heading among six.
    /// David flagged it on the first Endeavor he made, 2026-07-29.
    ///
    /// The name is not lost by leaving it out: it is in the frontmatter as
    /// `name:`, which is the field the app actually reads.
    ///
    /// Takes `name` anyway — unused today, but a skeleton that cannot see the
    /// thing it describes is a worse signature the moment a section wants it.
    static func skeleton(name: String) -> String {
        _ = name
        return EndeavorFile.skeleton()
    }

    // MARK: Slugs and filenames

    /// `japan-2026`. The year comes from the start date when there is one,
    /// because "japan" alone collides the second time he goes.
    private func uniqueSlug(for name: String, on starts: Date?) -> String {
        EndeavorFile.uniqueSlug(for: name, on: starts, existing: endeavors.map(\.id))
    }

    // Forwarders, Session 64. The implementations moved to `EndeavorFile` in
    // Trace/Endeavor.swift so Satchel and TraceMac can reach them; these keep
    // the `Self.slug(…)` spelling this file already uses in a dozen places.
    static func slug(from name: String) -> String { EndeavorFile.slug(from: name) }

    /// Kept because `DayflowNotesView` calls `EndeavorStore.splitFrontmatter`
    /// twice to strip frontmatter off arbitrary notes — nothing to do with
    /// Endeavors, it just needed a frontmatter splitter and this was the one in
    /// scope. Worth its own home eventually; not worth moving two call sites
    /// during a model split.
    static func splitFrontmatter(_ raw: String) -> ([String: String], String) {
        EndeavorFile.splitFrontmatter(raw)
    }

    /// The filename keeps the human name — this is a note somebody may open in
    /// a file browser. Only the characters a path genuinely cannot hold are
    /// replaced, the same short list `NoteStore.placeNoteFilename` uses.
    static func safeFilename(_ name: String) -> String { EndeavorFile.safeFilename(name) }

    // MARK: Dates

    static func date(_ raw: String?) -> Date? { EndeavorFile.date(raw) }

    static func string(_ date: Date) -> String { EndeavorFile.string(date) }

    /// Tolerant on purpose — these files are hand-editable, and "yes" in a
    /// frontmatter key should not silently mean false.
    static func bool(_ raw: String?) -> Bool? { EndeavorFile.bool(raw) }
}


// MARK: - Day notes
//
// David, 2026-08-01: *"Maybe there is a way to add content in daily notes that
// pertain to the endeavor in the endeavor note when I press the button? … If you
// think that there is a possibility that hallucinations might occur, maybe we can
// use some sort of indicator I can type within the note … Id only want to do that
// if its necessary though."*
//
// **IT IS NOT NECESSARY, BECAUSE THE MODEL NEVER WRITES ANYTHING.** It is handed
// numbered lines and returns numbers. The app then copies those lines out of its
// own array, verbatim. There is no path by which model output reaches the note, so
// fabrication is not unlikely here, it is impossible.
//
// What remains is the model choosing a line that is not really about the trip.
// That is a wrong guess, not a hallucination, and it lands in the review sheet
// David already uses to take things out.
//
// The `#trip` tag still earns its keep: a tagged line skips the model entirely.
// He had already typed one at the foot of his 31 July note before asking.


extension TripLog {

    /// A line the model may be asked about, with the index it will answer by.
    struct DayNoteCandidate {
        let day: Date
        let index: Int
        let text: String
        let tagged: Bool
    }

    enum DayNoteScanError: Error {
        /// No API key. Distinct from a failure on purpose — the sheet says
        /// "add a key in Settings", which is actionable, rather than "something
        /// went wrong", which is not.
        case noKey
        case failed
    }

    /// David's own marker. Optional, and treated as certain when present.
    static let tripTag = "#trip"

    /// **Per day, and enforced here rather than trusted to the model.**
    ///
    /// David, 2026-08-01: *"the list of the items might be ling so lets be careful
    /// about creating a lot of work for me when I press the button."* A cap in the
    /// prompt is a request; a cap in the code is a cap. Both exist, and this is the
    /// one that holds.
    static let maxDayNoteLines = 3

    // MARK: Candidates

    /// Every line from the daily notes inside the endeavor's range that is worth
    /// asking about. Strictly inside the range — David declined the days either
    /// side, 2026-08-01.
    ///
    /// The filtering below is all mechanical and happens before any model sees
    /// anything. Each rule drops something that could never be worth writing into a
    /// trip note, which keeps the prompt small, the guessing narrow, and the review
    /// list short:
    ///
    /// - The `# yyyy-MM-dd` title, which is the file's own name.
    /// - `## Related Notes` and its table rows. **Machine-written** by
    ///   `DayflowRelatedNotesEngine`. Feeding generated text back in as source
    ///   would be the app quoting itself.
    /// - Lines struck through end to end. He crossed them out; that is an answer.
    /// - A bare capture link with no words after it. Captures have their own route
    ///   into an endeavor (`stampsCaptures`) and a link alone carries no sentence.
    ///
    /// Checkbox markers are stripped but the text is kept: "Confirm Friday with
    /// Bronwyn" belongs in a trip note, a live checkbox in the middle of a trip
    /// narrative does not.
    static func dayNoteCandidates(for endeavor: Endeavor,
                                  store: NoteStore = .shared) -> [DayNoteCandidate] {
        guard let starts = endeavor.starts, let ends = endeavor.ends else { return [] }
        let cal = Calendar.current
        var day = cal.startOfDay(for: starts)
        let last = cal.startOfDay(for: ends)

        var out: [DayNoteCandidate] = []
        while day <= last {
            guard let raw = try? store.readDailyNote(date: day) else {
                day = cal.date(byAdding: .day, value: 1, to: day) ?? last.addingTimeInterval(1)
                continue
            }
            // A `#trip` ANYWHERE IN THE FILE tags the whole day.
            //
            // This is how David actually used it: the tag sits alone on the last
            // line of his 31 July note, which is Obsidian's convention — a tag
            // anywhere tags the note. Read line by line it would have attached to
            // nothing, and then been dropped as empty, so the one marker he had
            // already typed would have done nothing at all.
            let dayTagged = raw.contains(tripTag)
            for line in raw.components(separatedBy: "\n") {
                guard let text = candidateText(from: line) else { continue }
                out.append(DayNoteCandidate(day: day,
                                            index: out.count,
                                            text: text,
                                            tagged: dayTagged || line.contains(tripTag)))
            }
            guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return out
    }

    /// One line, cleaned up, or nil if it is not worth asking about.
    /// Split out from the walk above so it can be reasoned about on its own.
    static func candidateText(from line: String) -> String? {
        var t = line.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }

        // Generated block: the heading and the table rows under it.
        if t.hasPrefix("## Related Notes") { return nil }
        if t.hasPrefix("|") && t.hasSuffix("|") { return nil }

        // The file's own title, "# 2026-07-31".
        if t.range(of: #"^#\s+\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil { return nil }

        // Struck through end to end.
        if t.range(of: #"^~~.*~~$"#, options: .regularExpression) != nil { return nil }

        // A capture link and nothing else.
        if t.range(of: #"^\[[^\]]*\]\(capture://[^)]*\)$"#, options: .regularExpression) != nil { return nil }

        // App-written attachment furniture: the 📎 row an added document leaves
        // behind, and the "**Saved:**" stamp beside it. Found by running this
        // filter over all 32 of David's real daily notes rather than guessing at
        // what they contain.
        if t.hasPrefix("📎 [") { return nil }
        if t.hasPrefix("**Saved:**") { return nil }

        // A horizontal rule is punctuation, not a sentence.
        if t.range(of: #"^-{3,}$"#, options: .regularExpression) != nil { return nil }

        // Checkbox marker off, text kept. Both spellings: the ☐/☑ this app
        // writes, and the "- [ ]" markdown David types by hand — both appear in
        // his real notes.
        for marker in ["☑ ", "☐ ", "☑", "☐"] where t.hasPrefix(marker) {
            t = String(t.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        if let box = t.range(of: #"^- \[[ xX]\]\s*"#, options: .regularExpression) {
            t = String(t[box.upperBound...]).trimmingCharacters(in: .whitespaces)
        }

        // The control marker itself is not content.
        t = t.replacingOccurrences(of: tripTag, with: "")
             .trimmingCharacters(in: .whitespaces)

        return t.isEmpty ? nil : t
    }

    // MARK: Selection

    /// Asks which candidates belong to this trip, and returns INDICES.
    ///
    /// Throws rather than returning empty on failure. Every other AI call site in
    /// this codebase swallows its errors, which is why a rate limit there looks
    /// exactly like the feature deciding to do nothing. Here the difference is
    /// visible, because "no lines were relevant" and "I could not ask" are things
    /// David needs to be able to tell apart before he writes to a note.
    static func selectDayNoteIndices(_ candidates: [DayNoteCandidate],
                                     endeavor: Endeavor) async throws -> Set<Int> {
        let judged = candidates.filter { !$0.tagged }
        // Everything already carries the tag: nothing to ask, nothing to spend.
        guard !judged.isEmpty else { return [] }
        guard ClaudeKeyStore.hasKey else { throw DayNoteScanError.noKey }

        let dayFmt = DateFormatter()
        dayFmt.locale = Locale(identifier: "en_US_POSIX")
        dayFmt.dateFormat = "yyyy-MM-dd"

        let listing = judged
            .map { "\($0.index): [\(dayFmt.string(from: $0.day))] \($0.text)" }
            .joined(separator: "\n")

        // An empty destination string is not the same as no destination, and
        // " in " reads as a typo in a prompt.
        let place = endeavor.destination?.trimmingCharacters(in: .whitespacesAndNewlines)
        let where_ = (place?.isEmpty == false) ? " in \(place!)" : ""
        let prompt = """
            These are lines from a person's daily notes, written during a trip \
            called "\(endeavor.name)"\(where_).

            Which of them are about that trip? Include a line only if it is clearly \
            about the trip itself: where they went, who they were with, what they \
            did, saw, ate, planned for it or thought about it. Leave out anything \
            that is ordinary life happening to fall on those dates — work, errands, \
            chores, bills, health, notes about software.

            Prefer leaving a line out when you are unsure, and choose at most \
            \(maxDayNoteLines) lines per date.

            \(listing)

            Reply with only a JSON array of the numbers, for example [0,4,5]. \
            If none of them are about the trip, reply with: []
            """

        let body: [String: Any] = [
            // Haiku: this is a selection task over short lines, and a sheet is
            // waiting on it.
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 300,
            "messages": [["role": "user", "content": prompt]]
        ]

        guard let url = URL(string: "https://api.anthropic.com/v1/messages"),
              let bodyData = try? JSONSerialization.data(withJSONObject: body)
        else { throw DayNoteScanError.failed }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(ClaudeKeyStore.key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01",       forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = bodyData
        req.timeoutInterval = 20

        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = (json["content"] as? [[String: Any]])?.first,
              let text = content["text"] as? String
        else { throw DayNoteScanError.failed }

        // Read the numbers out of whatever came back, rather than requiring the
        // reply to be nothing but JSON. A model that says "Here you go: [0,4]"
        // has still answered the question.
        // NSRegularExpression rather than a `/\d+/` literal: the project builds at
        // SWIFT_VERSION 5.0, where bare-slash regex literals are off by default.
        let valid = Set(judged.map(\.index))
        var picked = Set<Int>()
        if let digits = try? NSRegularExpression(pattern: #"\d+"#) {
            let ns = text as NSString
            for m in digits.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                guard let n = Int(ns.substring(with: m.range)), valid.contains(n) else { continue }
                picked.insert(n)
            }
        }
        return picked
    }
}

// MARK: - Widget hand-off

/// What Dayflow leaves in the shared container for its widget to read.
///
/// **The widget cannot see endeavors.** Its target compiles its own file plus
/// `CalendarService`, and `EndeavorStore` reads sidecars through `NoteStore`,
/// which the widget has neither of. So Dayflow publishes; the widget reads.
///
/// **A LIST WITH DATES, NOT "the active one".** Publishing a single boolean
/// answer would mean a trip starting tomorrow stays dark until the app is next
/// opened, because nothing runs at midnight to change the answer. Publishing the
/// ranges lets the widget decide for itself on every timeline refresh, and the
/// system refreshes it across a date boundary for free. Same reasoning as Kit
/// membership being derived at render rather than written to the sidecar.
///
/// One `UserDefaults` key holding one JSON blob, deliberately: every string
/// shared across a target boundary is a chance for the two sides to drift, so
/// there is exactly one of them. The reader is `DayflowWidget.swift`'s
/// `ActiveEndeavorFeed` — **change one and you must change the other.**
struct PublishedEndeavor: Codable {
    let id: String
    let name: String
    let starts: Date
    let ends: Date
}

enum EndeavorWidgetFeed {
    static let suiteName = "group.com.david.trace"
    static let key = "dayflow_endeavor_feed"

    /// Horizon for what gets published. Bounded so the blob stays small and a
    /// decade of past trips never ships to a widget that cannot use them.
    static let lookAheadDays = 45
}

extension EndeavorStore {

    /// Writes the feed and asks the widget to refresh. Safe to call often.
    func publishWidgetFeed(now: Date = Date()) {
        guard let defaults = UserDefaults(suiteName: EndeavorWidgetFeed.suiteName) else { return }
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let horizon = cal.date(byAdding: .day, value: EndeavorWidgetFeed.lookAheadDays, to: today) ?? today

        let feed: [PublishedEndeavor] = endeavors.compactMap { e in
            guard let starts = e.starts, let ends = e.ends else { return nil }
            if e.statusOverride == .onHold || e.statusOverride == .cancelled { return nil }
            let first = cal.startOfDay(for: starts)
            let last  = cal.startOfDay(for: ends)
            // Ended before today, or starts beyond the horizon: of no use to a
            // widget that only ever asks "what is today".
            guard last >= today, first <= horizon else { return nil }
            return PublishedEndeavor(id: e.id, name: e.name, starts: first, ends: last)
        }

        if let data = try? JSONEncoder().encode(feed) {
            defaults.set(data, forKey: EndeavorWidgetFeed.key)
        } else {
            defaults.removeObject(forKey: EndeavorWidgetFeed.key)
        }
        WidgetCenter.shared.reloadAllTimelines()
    }
}

// MARK: - Agenda surfacing

/// What an endeavor should say on a given day's agenda, or nil for silence.
///
/// **The rules are David's, 2026-07-31.** Three days or fewer shows every day;
/// longer shows only the first and last. *"In the middle of the trip I'll know
/// I'm on vacation anyway."* Plus the day before, always, because that is the
/// only one of the three you can still act on.
///
/// Note the deliberate asymmetry with `defaultStampsCaptures`, which uses the
/// same three-day threshold pointing the other way: a short endeavor shows more
/// and files less, a long one the reverse. Both follow from the same fact, that
/// a long trip is impossible to forget and accumulates a lot.
struct EndeavorAgendaEntry {
    let endeavor: Endeavor
    /// The row's second line, e.g. "Travel · Day 1 of 9".
    let meta: String
}

extension EndeavorStore {

    /// Entries for `date`, soonest-ending first. Empty on any day nothing applies.
    func agendaEntries(on date: Date = Date()) -> [EndeavorAgendaEntry] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: date)

        return endeavors.compactMap { e -> EndeavorAgendaEntry? in
            // Both dates or nothing: the rules are all expressed in terms of a
            // range, and half a range has no first day, last day or length.
            guard let starts = e.starts, let ends = e.ends, let days = e.dayCount else { return nil }
            // Paused and abandoned endeavors do not narrate the day.
            if e.statusOverride == .onHold || e.statusOverride == .cancelled { return nil }

            let first = cal.startOfDay(for: starts)
            let last  = cal.startOfDay(for: ends)
            guard let dayBefore = cal.date(byAdding: .day, value: -1, to: first) else { return nil }

            let meta: String
            if today == dayBefore {
                // The Kit nudge. Named as an action because that is the point of
                // surfacing this day at all rather than the two bookends alone.
                meta = "\(e.type) · Starts tomorrow. Check your Kit."
            } else if today == first {
                meta = days == 1 ? "\(e.type) · Today" : "\(e.type) · Day 1 of \(days)"
            } else if today == last {
                meta = "\(e.type) · Last day"
            } else if today > first && today < last {
                // Middle days: only short endeavors. A six-week project would
                // otherwise put an unchanging row on forty-two consecutive days,
                // which is how a signal turns into wallpaper.
                guard days <= 3 else { return nil }
                let n = (cal.dateComponents([.day], from: first, to: today).day ?? 0) + 1
                meta = "\(e.type) · Day \(n) of \(days)"
            } else {
                return nil
            }
            return EndeavorAgendaEntry(endeavor: e, meta: meta)
        }
        .sorted { ($0.endeavor.ends ?? .distantFuture) < ($1.endeavor.ends ?? .distantFuture) }
    }
}

// MARK: - Small helper

private extension String {
    var nilIfEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
