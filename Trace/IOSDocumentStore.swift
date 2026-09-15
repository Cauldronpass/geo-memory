// iOSDocumentStore.swift
// iOS document store — reads the same iCloud Documents/ folder as the Mac.
// Shares TraceMacDocument model. No AppKit dependencies.
// iOS-only — do not add to Mac target (Mac uses TraceMacDocumentStore).
//
// Session 50 (2026-07-27) — Satchel build step 3, "widen the store".
// Reads and writes the five sidecar keys from `Documents-App-Scope.md` §4:
// `endeavor`, `endeavor_name`, `pinned`, `icon`, `tint`. Every key is optional
// with a sane default (`pinned: false`; `icon`/`tint` fall back to the
// type-based rule on `TraceMacDocument`), so sidecars written before Satchel
// existed keep loading unchanged.
//
// IMPORTANT — non-destructive writes. Trace keeps its own Documents editor
// alive until Satchel is trusted (scope doc §7), and that editor calls
// `saveSidecar` without knowing the new keys exist. So the new parameters
// default to nil meaning **preserve whatever is already on disk**, and the
// writer merges rather than replaces. Without this, one save from Trace's
// detail sheet would silently wipe a document's pin, icon and Endeavor.

import Foundation
import Observation

// MARK: - Store

@Observable
class iOSDocumentStore {

    var documents: [TraceMacDocument] = []
    var isLoading: Bool = false

    private let noteStore: NoteStore

    init(noteStore: NoteStore = .shared) {
        self.noteStore = noteStore
    }

    // MARK: - Load

    func reload() async {
        guard noteStore.hasAccess else { return }
        await MainActor.run { isLoading = true }

        var result: [TraceMacDocument] = []

        let subfolders = (try? listSubfolders(in: "Documents")) ?? []
        let scanTargets = subfolders.isEmpty ? ["Documents"] : subfolders.map { "Documents/\($0)" }

        for folder in scanTargets {
            let category = folder == "Documents" ? "Inbox" : String(folder.split(separator: "/").last ?? "")
            let files = (try? noteStore.listDocumentFiles(in: folder)) ?? []

            for filename in files {
                guard !filename.hasPrefix(".") else { continue }

                if let url = noteStore.resolvedURL(for: "\(folder)/\(filename)") {
                    let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                    if isDir { continue }
                }

                let relativePath = "\(folder)/\(filename)"
                let ext = (filename as NSString).pathExtension.lowercased()
                // `.md` is never a document: a document's sidecar is its own
                // path with the extension swapped for `.md`.
                guard !["md", "markdown"].contains(ext) else { continue }
                // **`.txt` is a document only when a sidecar sits beside it**,
                // the Mac's D337 rule, ported here in Session 102 (D385). Until
                // now this store skipped `.txt` unconditionally, so a research
                // reading the Mac wrote into Satchel (D313) and a text snippet
                // shared from the phone were both on disk and invisible here.
                // A loose `.txt` with no sidecar is still skipped, as before.
                if ["txt", "text"].contains(ext) {
                    let companion = String(relativePath.dropLast(ext.count + 1)) + ".md"
                    guard noteStore.fileExists(companion) else { continue }
                }

                let sidecarRelative = relativePath.hasSuffix(".\(ext)")
                    ? String(relativePath.dropLast(ext.count + 1)) + ".md"
                    : relativePath + ".md"

                let sidecar = parseSidecar(at: sidecarRelative)
                let body = readBody(at: sidecarRelative)

                let nameNoExt = filename.hasSuffix(".\(ext)")
                    ? String(filename.dropLast(ext.count + 1))
                    : filename
                let timestampPattern = #"^\d{4}-\d{2}-\d{2}-\d{6}-"#
                let stripped = nameNoExt.replacingOccurrences(
                    of: timestampPattern, with: "", options: .regularExpression)
                let derivedTitle = stripped
                    .replacingOccurrences(of: "-", with: " ")
                    .replacingOccurrences(of: "_", with: " ")

                var fsDate: Date? = nil
                if let url = noteStore.resolvedURL(for: relativePath) {
                    fsDate = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.creationDate] as? Date
                }

                // **When it landed, from the filename** (D381, porting the Mac's
                // D347). Every import writes `yyyy-MM-dd-HHmmss-` at the front
                // and nothing edits it afterwards, which makes it a better
                // record of arrival than the filesystem: iCloud rewrites
                // creation dates when it materialises a file, so `fsDate` can be
                // the day this phone downloaded it rather than the day it was
                // filed.
                let arrivedAt = TraceMacDocument.arrivalDate(fromFilename: filename) ?? fsDate

                let doc = TraceMacDocument(
                    relativePath: relativePath,
                    filename: filename,
                    category: category,
                    fileExtension: ext,
                    title: sidecar?.title ?? derivedTitle,
                    tags: sidecar?.tags ?? [],
                    created: sidecar?.created ?? fsDate,
                    linkedNote: sidecar?.linkedNote,
                    people: sidecar?.people ?? [],
                    description: sidecar?.description ?? "",
                    endeavor: sidecar?.endeavor,
                    endeavorName: sidecar?.endeavorName,
                    pinned: sidecar?.pinned ?? false,
                    kitOrder: sidecar?.kitOrder,
                    icon: sidecar?.icon,
                    tint: sidecar?.tint,
                    remindOn: sidecar?.remindOn,
                    note: body.note,
                    summary: body.summary,
                    extractedText: body.text,
                    textExtracted: body.hasTextSection,
                    arrived: arrivedAt,
                    // A saved link carries its address in the file (D384); the
                    // sidecar copy wins when it exists, the file fills in when
                    // it does not, so a `.webloc` filed by hand still opens.
                    url: sidecar?.url ?? urlFromWebloc(ext: ext, relativePath: relativePath) ?? "",
                    places: sidecar?.places ?? [],
                    // Reading shelf (D407). All five absent on every document
                    // that is not a fetched link, which is the default state
                    // the model already describes.
                    articleState: sidecar?.articleState,
                    fetchedOn: sidecar?.fetchedOn,
                    readNext: sidecar?.readNext,
                    readOn: sidecar?.readOn,
                    readPosition: sidecar?.readPosition
                )
                result.append(doc)
            }
        }

        // **Newest ARRIVAL first** (D381), not newest printed date, matching the
        // Mac's D347. `created` is what the document SAYS, and the scan reads it
        // off the page - a rental confirmation for next May carries next May, so
        // sorting on it parked four travel bookings at the top of Recent for six
        // days with no way for anything newer to displace them. `created` falls
        // back behind arrival so a document with no parseable stamp and no
        // filesystem date still sorts somewhere sensible instead of to the
        // bottom.
        result.sort {
            let l = $0.listDate ?? .distantPast
            let r = $1.listDate ?? .distantPast
            return l > r
        }

        await MainActor.run {
            documents = result
            isLoading = false
        }
    }

    // MARK: - Sidecar write

    /// Writes a document's sidecar.
    ///
    /// `title`, `tags`, `linkedNote`, `people`, `description` and `date` behave
    /// exactly as they always have — the value passed is the value written.
    ///
    /// The five Satchel keys use **preserve-by-default** semantics:
    /// - `nil` (the default) keeps whatever is already in the sidecar on disk.
    /// - A value overwrites it.
    /// - For the two string keys, `""` clears the key.
    ///
    /// That is what lets Trace's existing Documents editor keep calling this
    /// method unmodified without destroying Satchel's metadata.
    func saveSidecar(
        for doc: TraceMacDocument,
        title: String,
        tags: [String],
        linkedNote: String?,
        people: [String],
        description: String = "",
        date: Date? = nil,
        endeavor: String? = nil,
        endeavorName: String? = nil,
        pinned: Bool? = nil,
        icon: DocumentIcon? = nil,
        tint: DocumentTint? = nil,
        kitOrder: Int? = nil,
        note: String? = nil,
        summary: String? = nil,
        /// Three states, same shape as `updateSidecar`: `nil` preserves what is
        /// on disk, `.some(nil)` clears, `.some(date)` sets. **Preserving is
        /// new (2026-08-27).** Until now this method rebuilt `SidecarData`
        /// without `remindOn`, so every full save from Satchel's editor or
        /// capture sheet silently deleted the reminder date — the same bug the
        /// Mac store fixed for itself and recorded at its top.
        remindOn: Date?? = nil,
        /// Same three-state shape as `remindOn`: `nil` preserves what is on
        /// disk, `.some("")` clears the key, `.some(text)` sets it. Added
        /// Session 96 with Satchel's URL row - until then this method could
        /// only preserve `url`, which was right while nothing on the phone
        /// could type one and wrong the moment something could.
        url: String?? = nil,
        /// Preserve-by-default like every Satchel key: `nil` keeps what is on
        /// disk, a list (empty included) replaces it. D385, Session 102.
        places: [String]? = nil,
        // MARK: Reading shelf keys (D407, Session 105)
        //
        // Same preserve-by-default rule as everything above. `article` is a
        // plain `Bool?` because an optional already carries three states — nil
        // preserves, true and false both set — and nothing ever needs to erase
        // it back to "never tried". The other four are double optionals: the
        // Retry action clears `fetched`, Keep for later clears `read`, and an
        // article leaving Up Next clears `read_next`, so each needs a way to say
        // "remove this" that a single optional cannot express.
        articleState: ArticleState? = nil,
        fetchedOn: Date?? = nil,
        readNext: Int?? = nil,
        readOn: Date?? = nil,
        readPosition: Double?? = nil
    ) throws {
        let existing = parseSidecar(at: doc.sidecarPath)
        // Read the body back BEFORE rewriting. Every caller that does not know
        // about notes still preserves them, which is the whole point.
        var body = readBody(at: doc.sidecarPath)
        if let note { body.note = note.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let summary { body.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines) }

        var data = SidecarData(tags: [], people: [])
        data.title       = title
        data.tags        = tags
        data.created     = date ?? doc.created ?? Date()
        data.linkedNote  = (linkedNote?.isEmpty ?? true) ? nil : linkedNote
        data.people      = people
        data.description = description
        // **Preserve-by-default, exactly as the Mac store does it** (D350). A
        // store that rebuilds frontmatter without a key is a store that DELETES
        // that key on its next save, which is the Session 63 `remind` bug. Every
        // caller that knows nothing about `url` still passes nil and still keeps
        // it; only Satchel's URL row passes a value.
        switch url {
        case .none:
            data.url = existing?.url ?? (doc.url.isEmpty ? nil : doc.url)
        case .some(let value):
            let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            data.url = trimmed.isEmpty ? nil : trimmed
        }

        data.places       = places ?? existing?.places ?? doc.places

        data.articleState = articleState ?? existing?.articleState ?? doc.articleState
        switch fetchedOn {
        case .none:            data.fetchedOn = existing?.fetchedOn ?? doc.fetchedOn
        case .some(let value): data.fetchedOn = value
        }
        switch readNext {
        case .none:            data.readNext = existing?.readNext ?? doc.readNext
        case .some(let value): data.readNext = value
        }
        switch readOn {
        case .none:            data.readOn = existing?.readOn ?? doc.readOn
        case .some(let value): data.readOn = value
        }
        switch readPosition {
        case .none:            data.readPosition = existing?.readPosition ?? doc.readPosition
        case .some(let value): data.readPosition = value
        }

        data.endeavor     = resolvedString(new: endeavor,     existing: existing?.endeavor)
        data.endeavorName = resolvedString(new: endeavorName, existing: existing?.endeavorName)
        data.pinned       = pinned ?? existing?.pinned ?? false
        data.icon         = icon ?? existing?.icon
        data.tint         = tint ?? existing?.tint
        data.kitOrder     = kitOrder ?? existing?.kitOrder
        switch remindOn {
        case .none:            data.remindOn = existing?.remindOn ?? doc.remindOn
        case .some(let value): data.remindOn = value
        }

        try noteStore.writeFile(doc.sidecarPath, content: renderSidecar(data, body: body))
    }

    /// Updates only the Satchel keys, preserving every existing field.
    ///
    /// This is the write path for a pin toggle, an icon override or filing a
    /// document against an Endeavor — none of which should require the caller
    /// to re-supply the title, tags and people just to change one flag.
    /// Same preserve-by-default semantics as `saveSidecar`.
    @discardableResult
    func updateSidecar(
        for doc: TraceMacDocument,
        endeavor: String? = nil,
        endeavorName: String? = nil,
        pinned: Bool? = nil,
        icon: DocumentIcon? = nil,
        tint: DocumentTint? = nil,
        kitOrder: Int? = nil,
        /// `.some(nil)` clears the date; `nil` leaves it alone. A plain `Date?`
        /// could not express "remove this" — the same distinction `endeavor`
        /// solves with an empty string.
        remindOn: Date?? = nil,
        note: String? = nil,
        summary: String? = nil,
        places: [String]? = nil,
        /// Reading shelf keys (D407). All five are three-state here: `nil`
        /// preserves, `.some(nil)` clears, `.some(value)` sets.
        ///
        /// **`articleState` joined them in Build 3.** It was a plain optional
        /// on the reasoning that nothing ever erases a verdict back to "never
        /// tried" — and then Retry did exactly that, which is the whole point
        /// of Retry. `saveSidecar`'s copy stays preserve-only: it has no caller
        /// that clears, and widening it would be a shape with no user.
        articleState: ArticleState?? = nil,
        fetchedOn: Date?? = nil,
        readNext: Int?? = nil,
        readOn: Date?? = nil,
        readPosition: Double?? = nil
    ) throws -> TraceMacDocument {
        // Seed from disk when a sidecar exists, otherwise from the in-memory doc
        // so a never-scanned document still ends up with a complete sidecar.
        var data = parseSidecar(at: doc.sidecarPath) ?? SidecarData(
            title: doc.title,
            tags: doc.tags,
            created: doc.created,
            linkedNote: doc.linkedNote,
            people: doc.people,
            description: doc.description,
            url: doc.url.isEmpty ? nil : doc.url,
            endeavor: doc.endeavor,
            endeavorName: doc.endeavorName,
            pinned: doc.pinned,
            icon: doc.icon,
            tint: doc.tint,
            kitOrder: doc.kitOrder,
            remindOn: doc.remindOn,
            places: doc.places,
            articleState: doc.articleState,
            fetchedOn: doc.fetchedOn,
            readNext: doc.readNext,
            readOn: doc.readOn,
            readPosition: doc.readPosition
        )

        if data.title == nil   { data.title = doc.title }
        if data.created == nil { data.created = doc.created ?? Date() }

        data.endeavor     = resolvedString(new: endeavor,     existing: data.endeavor)
        data.endeavorName = resolvedString(new: endeavorName, existing: data.endeavorName)
        if let pinned   { data.pinned   = pinned }
        if let icon     { data.icon     = icon }
        if let tint     { data.tint     = tint }
        if let kitOrder { data.kitOrder = kitOrder }
        if let remindOn { data.remindOn = remindOn }
        if let places   { data.places   = places }
        if let articleState { data.articleState = articleState }   // .some(nil) clears
        if let fetchedOn    { data.fetchedOn    = fetchedOn }
        if let readNext     { data.readNext     = readNext }
        if let readOn       { data.readOn       = readOn }
        if let readPosition { data.readPosition = readPosition }

        var body = readBody(at: doc.sidecarPath)
        if body.isEmpty { body.note = doc.note; body.summary = doc.summary }
        if let note { body.note = note.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let summary { body.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines) }

        try noteStore.writeFile(doc.sidecarPath, content: renderSidecar(data, body: body))

        var updated = doc
        updated.endeavor     = data.endeavor
        updated.endeavorName = data.endeavorName
        updated.pinned       = data.pinned ?? false
        updated.icon         = data.icon
        updated.tint         = data.tint
        updated.kitOrder     = data.kitOrder
        updated.remindOn     = data.remindOn
        updated.places       = data.places
        updated.articleState = data.articleState
        updated.fetchedOn    = data.fetchedOn
        updated.readNext     = data.readNext
        updated.readOn       = data.readOn
        updated.readPosition = data.readPosition
        updated.note         = body.note
        updated.summary      = body.summary

        if let idx = documents.firstIndex(where: { $0.relativePath == doc.relativePath }) {
            documents[idx] = updated
        }
        return updated
    }

    /// Convenience: write the user's own note. Never touches the summary.
    @discardableResult
    func setNote(_ note: String, for doc: TraceMacDocument) throws -> TraceMacDocument {
        try updateSidecar(for: doc, note: note)
    }

    /// Convenience: write the on-demand AI summary. Never touches the note.
    @discardableResult
    func setSummary(_ summary: String, for doc: TraceMacDocument) throws -> TraceMacDocument {
        try updateSidecar(for: doc, summary: summary)
    }

    /// Convenience: toggle a manual Kit pin.
    ///
    /// Pinning appends to the end of the pinned order rather than the front.
    /// §5's default is "order pinned", and a new pin jumping ahead of the
    /// passport would be exactly the muscle-memory break that rule exists to
    /// prevent. Unpinning leaves the order value alone; it is meaningless until
    /// the document is in a Kit group again, and re-pinning overwrites it.
    @discardableResult
    func setPinned(_ pinned: Bool, for doc: TraceMacDocument) throws -> TraceMacDocument {
        guard pinned else { return try updateSidecar(for: doc, pinned: false) }
        let nextOrder = (documents.filter { $0.pinned }.compactMap { $0.kitOrder }.max() ?? -1) + 1
        return try updateSidecar(for: doc, pinned: true, kitOrder: nextOrder)
    }

    /// Persists a drag-to-reorder of one Kit group — pinned OR active-trip.
    ///
    /// Rewrites every document's `kit_order` to its new index rather than nudging
    /// the moved one. Sparse or duplicate indices drift into an order that reads
    /// as random, and the whole point of the rule is that the order never
    /// surprises you.
    ///
    /// Deliberately does NOT force `pinned: true` or skip unpinned documents:
    /// active-trip documents are ordered by the same field. A document is only
    /// ever in one Kit group, so one field serves both.
    func reorderKitGroup(_ ordered: [TraceMacDocument]) throws {
        for (index, doc) in ordered.enumerated() {
            try updateSidecar(for: doc, kitOrder: index)
        }
    }

    // MARK: - Reading shelf (D407 Build 4)

    /// Put an article in Up Next, or take it out (`nil`).
    ///
    /// **Appends to the END of the queue**, the same rule as `setPinned` and
    /// for the same reason: §5's "order pinned" default exists so a new arrival
    /// does not displace what you already meant to do first. It also keeps the
    /// order he promoted things in, where inserting at the front would reverse
    /// it — promote three articles in a row and you would read them backwards.
    /// With an empty queue, appending IS first, which is the common case and
    /// the reason the swipe can honestly say "Read next".
    @discardableResult
    func setReadNext(_ inQueue: Bool, for doc: TraceMacDocument) throws -> TraceMacDocument {
        guard inQueue else { return try updateSidecar(for: doc, readNext: .some(nil)) }
        let highest = documents.compactMap(\.readNext).max() ?? -1
        return try updateSidecar(for: doc, readNext: .some(highest + 1))
    }

    /// Mark an article read, or return it to New (`nil`).
    ///
    /// Reading it also takes it out of Up Next: a finished article sitting in
    /// the queue is the queue lying about what is left. "Keep for later" is the
    /// other direction and clears the date, which puts it back in New rather
    /// than at its old place in the queue — D407's wording, and the honest one,
    /// since the position was spent when it was read.
    @discardableResult
    func setRead(_ read: Date?, for doc: TraceMacDocument) throws -> TraceMacDocument {
        try updateSidecar(for: doc, readNext: .some(nil), readOn: .some(read))
    }

    /// Persist a drag-to-reorder of Up Next.
    ///
    /// Rewrites every position to its new index rather than nudging the moved
    /// one, exactly as `reorderKitGroup` does: sparse or duplicate indices drift
    /// into an order that reads as random, and the whole point of the rule is
    /// that the order never surprises you.
    func reorderUpNext(_ ordered: [TraceMacDocument]) throws {
        for (index, doc) in ordered.enumerated() {
            try updateSidecar(for: doc, readNext: .some(index))
        }
    }

    /// Convenience: override the icon and tint chosen by the scan.
    @discardableResult
    func setAppearance(icon: DocumentIcon, tint: DocumentTint, for doc: TraceMacDocument) throws -> TraceMacDocument {
        try updateSidecar(for: doc, icon: icon, tint: tint)
    }

    /// Sets or clears the date this document needs attention.
    @discardableResult
    func setReminder(on date: Date?, for doc: TraceMacDocument) throws -> TraceMacDocument {
        try updateSidecar(for: doc, remindOn: .some(date))
    }

    /// Convenience: file a document against an Endeavor. Pass `nil` for both to
    /// leave it alone; pass `id: ""` to unfile it.
    @discardableResult
    func setEndeavor(id: String?, name: String?, for doc: TraceMacDocument) throws -> TraceMacDocument {
        // Clearing the ID clears the cached name too — a name with no ID behind
        // it is exactly the stale denormalised copy scope doc §D4 rules out.
        let resolvedName = (id?.isEmpty == true) ? "" : name
        return try updateSidecar(for: doc, endeavor: id, endeavorName: resolvedName)
    }

    // MARK: - Import

    func importDocument(from sourceURL: URL) throws {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd-HHmmss"
        let timestamp = fmt.string(from: Date())
        let filename = "\(timestamp)-\(sourceURL.lastPathComponent)"
        let data = try Data(contentsOf: sourceURL)
        try noteStore.writeDocument(data, category: NoteStore.documentFolder(), filename: filename)
    }

    // MARK: - Delete

    func deleteDocument(_ doc: TraceMacDocument) throws {
        try noteStore.deleteFile(doc.relativePath)
        // Best-effort sidecar removal — ignore if it doesn't exist.
        try? noteStore.deleteFile(doc.sidecarPath)
    }

    // `moveDocument` removed Session 69, with no callers. It wrote
    // `Documents/<Category>/`, the axis `Documents-App-Scope.md` retired on
    // 2026-07-28 — that doc states the move command "was never built,
    // deliberately", and this was it, built anyway. Documents are filed by
    // `linked_note` and `endeavor`; the folder is the year and nothing moves.

    // MARK: - Helpers

    // MARK: - Text extraction

    /// Read the words off every image and PDF that has not been read yet.
    ///
    /// The Mac's `extractTextForNewArrivals`, on the phone, deliberately down to
    /// the name. The Mac has backfilled phone-captured documents since Session
    /// 70, so this is not a hole it fills — it is a **latency** one. Capture a
    /// scorecard or a rental confirmation on the phone and, until the Mac next
    /// opens and sweeps, the phone could not search its contents. That window
    /// did not matter before Session 71, because the phone had no search.
    ///
    /// **The `private` tag is not consulted, deliberately.** §5b binds Ask,
    /// which sends text to an API. Nothing here leaves the device, and a private
    /// document that cannot be found by local search is unfindable in the one
    /// place it was safe to find. Same reasoning, same words, as the Mac's.
    func extractTextForNewArrivals() async {
        let pending = documents.filter { doc in
            (doc.isPDF || doc.isImage) && !doc.textExtracted
        }
        guard !pending.isEmpty else { return }

        var wrote = false
        for doc in pending {
            guard let url = noteStore.resolvedURL(for: doc.relativePath) else { continue }
            // Detached, and it has to be: the project sets
            // `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so a plain `Task`
            // would run Vision on the main actor (D106). Tens of milliseconds
            // for a photo, and that per page for a scanned PDF.
            let text = await Task.detached { MacTextExtraction.extract(from: url) }.value
            // `nil` means "not a kind this can read" and must NOT write a
            // marker — a `.txt` arriving one day should not be recorded as
            // having no text. An empty string DOES write one: the pass ran and
            // this photograph has no writing in it, and without the marker it
            // would be re-read on every launch forever.
            guard let text else { continue }
            do {
                try writeExtractedText(text, for: doc)
                wrote = true
            } catch { continue }
        }
        if wrote { await reload() }
    }

    /// Put text under `## Text` without touching anything else.
    ///
    /// **Internal rather than private since Session 105 (D407 Build 2).** The
    /// article fetch lives in `Satchel/` — it needs WebKit, and `Trace/` is
    /// compiled by Dayflow and Trace, neither of which has any business
    /// carrying a hidden web view — so it calls in here rather than growing a
    /// second writer of the same section.
    ///
    /// **The titleless-sidecar rule does not bite a link.** This rebuilds from
    /// `parseSidecar(...) ?? SidecarData()`, and the empty fallback is what
    /// leaves a never-scanned image's sidecar without a title so the derived
    /// one still wins and it stays a scan candidate. A saved link always has a
    /// sidecar already, with the title `LPMetadataProvider` read off the page
    /// (D384), so `parseSidecar` returns it and the title survives. That is the
    /// behaviour wanted here: the page named itself, and nothing downstream
    /// should rename it.
    func writeExtractedText(_ text: String, for doc: TraceMacDocument) throws {
        var body = readBody(at: doc.sidecarPath)
        body.text = text
        body.hasTextSection = true

        var data = parseSidecar(at: doc.sidecarPath) ?? SidecarData()
        if data.created == nil { data.created = doc.created ?? Date() }

        try noteStore.writeFile(doc.sidecarPath, content: renderSidecar(data, body: body))
    }

    // MARK: - Privacy

    /// What the DISK says about this document's privacy, including "I cannot
    /// tell yet".
    ///
    /// **A port of `TraceMacDocumentStore.privacyOnDisk`, and of the incident
    /// that produced it.** The two-valued version of that function shipped a
    /// private document to Anthropic: a sidecar that exists but has not
    /// finished downloading cannot be read, and `guard let data = parseSidecar
    /// (…) else { return false }` answered "not private". Absence of an answer
    /// is not an answer.
    ///
    /// The phone never needed this while every send was a button: `doc`
    /// belonged to a row he was looking at, so its sidecar had plainly
    /// arrived. **The article sweep is the phone's first autonomous send**, and
    /// it runs over whatever the store happens to hold seconds after launch,
    /// which is exactly the window in which a sidecar is still a placeholder.
    enum DiskPrivacy {
        case notPrivate
        case isPrivate
        /// No sidecar, or one that could not be read. **Never send on this.**
        case unknown
    }

    func privacyOnDisk(_ doc: TraceMacDocument) -> DiskPrivacy {
        guard let url = noteStore.resolvedURL(for: doc.sidecarPath),
              FileManager.default.fileExists(atPath: url.path)
        else { return .unknown }
        guard let data = parseSidecar(at: doc.sidecarPath) else { return .unknown }
        return data.tags.contains { $0.caseInsensitiveCompare("private") == .orderedSame }
            ? .isPrivate : .notPrivate
    }

    // MARK: - Helpers

    private func listSubfolders(in subfolder: String) throws -> [String] {
        guard let base = noteStore.containerURL else { return [] }
        let folderURL = base.appendingPathComponent(subfolder)
        guard FileManager.default.fileExists(atPath: folderURL.path) else { return [] }
        let items = try FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        )
        return items.compactMap { url -> String? in
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            return isDir ? url.lastPathComponent : nil
        }.sorted()
    }

    /// nil = preserve, "" = clear, anything else = overwrite.
    private func resolvedString(new: String?, existing: String?) -> String? {
        guard let new else { return existing }
        let trimmed = new.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Sidecar model

    private struct SidecarData {
        var title: String?
        var tags: [String]
        var created: Date?
        var linkedNote: String?
        var people: [String]
        var description: String?
        /// Sidecar key `url` (D350). Mirrors `TraceMacDocumentStore`. Present
        /// here so the phone's next save does not strip a URL typed on the Mac
        /// - the `remind` bug, which is the reason that field carries the
        /// longest comment in this file.
        var url: String?
        var endeavor: String?
        var endeavorName: String?
        var pinned: Bool?
        var icon: DocumentIcon?
        var tint: DocumentTint?
        var kitOrder: Int?
        var remindOn: Date?
        /// Sidecar key `places` (D385). Same rule as `url` and `remind`: a
        /// key this struct does not carry is a key the next save deletes.
        var places: [String]
        /// Reading shelf keys (D407, Session 105): `article`, `fetched`,
        /// `read_next`, `read`, `read_position`. Same rule again, and this time
        /// the rule was applied to both stores in the same build BEFORE any UI
        /// could write one of them.
        var articleState: ArticleState?
        var fetchedOn: Date?
        var readNext: Int?
        var readOn: Date?
        var readPosition: Double?

        init(
            title: String? = nil,
            tags: [String] = [],
            created: Date? = nil,
            linkedNote: String? = nil,
            people: [String] = [],
            description: String? = nil,
            url: String? = nil,
            endeavor: String? = nil,
            endeavorName: String? = nil,
            pinned: Bool? = nil,
            icon: DocumentIcon? = nil,
            tint: DocumentTint? = nil,
            kitOrder: Int? = nil,
            remindOn: Date? = nil,
            places: [String] = [],
            articleState: ArticleState? = nil,
            fetchedOn: Date? = nil,
            readNext: Int? = nil,
            readOn: Date? = nil,
            readPosition: Double? = nil
        ) {
            self.title = title
            self.tags = tags
            self.created = created
            self.linkedNote = linkedNote
            self.people = people
            self.description = description
            self.url = url
            self.endeavor = endeavor
            self.endeavorName = endeavorName
            self.pinned = pinned
            self.icon = icon
            self.tint = tint
            self.kitOrder = kitOrder
            self.remindOn = remindOn
            self.places = places
            self.articleState = articleState
            self.fetchedOn = fetchedOn
            self.readNext = readNext
            self.readOn = readOn
            self.readPosition = readPosition
        }
    }


    // MARK: - Sidecar body
    //
    // Everything below the closing `---`. Scope §4 "Sidecar BODY": the user note
    // and the on-demand AI summary live here as markdown, because the frontmatter
    // parser is line-based and would mangle multi-line prose.
    //
    // `extra` exists so this is non-destructive. Anything in the body that is not
    // one of the two recognised sections is carried through untouched — a heading
    // someone added by hand in Obsidian, a stray paragraph, whatever. Rebuilding
    // the file from only what we understand is precisely the bug this replaces.

    struct SidecarBody {
        var note: String = ""
        var summary: String = ""
        /// On-device OCR / PDF text layer, under `## Text`.
        ///
        /// **iOS used to leave this in `extra` on purpose.** The Mac's own
        /// comment on `SidecarBody.hasTextSection` says so in as many words: a
        /// body heading rather than a frontmatter key precisely *because* the
        /// phone would file the section under `extra` and re-emit it untouched,
        /// which costs nothing when the phone has no use for it.
        ///
        /// **Session 71 gave the phone a use for it.** iOS search and Ask index
        /// `doc.extractedText`, so an unparsed `## Text` meant the Satchel group
        /// on the phone could only ever match a document's title and tags — the
        /// words on the page were sitting in the sidecar, on this device,
        /// unreadable. Round-tripping was the right call for preservation and
        /// the wrong one the moment search shipped.
        var text: String = ""
        /// Whether a `## Text` heading is present on disk, **independently of
        /// whether there is anything under it.** "Needs extraction" is *no
        /// heading*, not *no text*: a pass that found nothing leaves behind
        /// exactly what "no text" looks like, and without the marker a
        /// photograph of a sunset is re-OCR'd forever. Same trap D90 named.
        var hasTextSection: Bool = false
        var extra: String = ""

        var isEmpty: Bool {
            note.isEmpty && summary.isEmpty && extra.isEmpty
                && text.isEmpty && !hasTextSection
        }
    }

    static let noteHeading = "## Note"
    static let summaryHeading = "## Summary"
    /// Must stay byte-identical to `TraceMacDocumentStore.textHeading`. Two
    /// spellings of one heading is two parsers that disagree about the same file.
    static let textHeading = "## Text"

    func parseBody(_ raw: String) -> SidecarBody {
        var body = SidecarBody()
        let lines = raw.components(separatedBy: "\n")

        // Skip the frontmatter: everything up to and including the SECOND `---`.
        var index = 0
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            index = 1
            while index < lines.count,
                  lines[index].trimmingCharacters(in: .whitespaces) != "---" {
                index += 1
            }
            index += 1
        }

        enum Section { case none, note, summary, text }
        var section: Section = .none
        var note: [String] = [], summary: [String] = [], extra: [String] = []
        var text: [String] = []

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == Self.noteHeading {
                section = .note
            } else if trimmed == Self.summaryHeading {
                section = .summary
            } else if trimmed == Self.textHeading {
                section = .text
                body.hasTextSection = true
            } else if trimmed.hasPrefix("## ") {
                // An unrecognised heading — hand it and everything under it to
                // `extra` rather than swallowing it into the previous section.
                section = .none
                extra.append(line)
            } else {
                switch section {
                case .note:    note.append(line)
                case .summary: summary.append(line)
                case .text:    text.append(line)
                case .none:    extra.append(line)
                }
            }
            index += 1
        }

        func tidy(_ block: [String]) -> String {
            block.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        body.note = tidy(note)
        body.summary = tidy(summary)
        body.text = tidy(text)
        body.extra = tidy(extra)
        return body
    }

    func renderBody(_ body: SidecarBody) -> String {
        guard !body.isEmpty else { return "" }
        var out = ""
        if !body.note.isEmpty {
            out += "\n\(Self.noteHeading)\n\n\(body.note)\n"
        }
        if !body.summary.isEmpty {
            out += "\n\(Self.summaryHeading)\n\n\(body.summary)\n"
        }
        // Order matches `TraceMacDocumentStore.renderBody` exactly: note,
        // summary, text, extra. A different order here would rewrite every
        // sidecar the other device touched and churn iCloud for nothing.
        //
        // The heading is written even when the text is empty. That IS the
        // marker: the pass ran and this file has nothing readable in it.
        if body.hasTextSection {
            out += body.text.isEmpty
                ? "\n\(Self.textHeading)\n"
                : "\n\(Self.textHeading)\n\n\(body.text)\n"
        }
        if !body.extra.isEmpty {
            out += "\n\(body.extra)\n"
        }
        return out
    }

    /// Reads the body of an existing sidecar so a metadata-only save can put it
    /// back. Without this, `renderSidecar` rebuilds the file from frontmatter
    /// alone and every note is erased on the next save of anything else.
    func readBody(at relativePath: String) -> SidecarBody {
        guard let raw = try? noteStore.readFile(relativePath), !raw.isEmpty else {
            return SidecarBody()
        }
        return parseBody(raw)
    }

    // MARK: - Sidecar renderer

    /// Key order matches the approved sidecar sample in `satchel-mockup-v4.html`:
    /// the original six first, then icon/tint, then the Endeavor pair, then the pin.
    private func renderSidecar(_ data: SidecarData, body: SidecarBody = SidecarBody()) -> String {
        let tagLine = data.tags.isEmpty
            ? "[]"
            : "[" + data.tags.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.joined(separator: ", ") + "]"
        let peopleLine = data.people.isEmpty
            ? "[]"
            : "[" + data.people.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ", ") + "]"

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let dateStr = fmt.string(from: data.created ?? Date())

        var content = "---\n"
        content += "title: \(data.title ?? "")\n"
        content += "tags: \(tagLine)\n"
        content += "created: \(dateStr)\n"
        if let note = data.linkedNote, !note.isEmpty { content += "linked_note: \(note)\n" }
        if !data.people.isEmpty { content += "people: \(peopleLine)\n" }
        // Directly after `people`, byte-identical to the Mac store (D385).
        if !data.places.isEmpty {
            let placesLine = "[" + data.places.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ", ") + "]"
            content += "places: \(placesLine)\n"
        }
        let trimmedDesc = (data.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedDesc.isEmpty {
            let escaped = trimmedDesc.replacingOccurrences(of: "\"", with: "'")
            content += "description: \"\(escaped)\"\n"
        }
        // Between `description` and `remind`, byte-identical to
        // `TraceMacDocumentStore.renderSidecar`. See the note there on order.
        if let url = data.url, !url.isEmpty { content += "url: \(url)\n" }
        if let remind = data.remindOn { content += "remind: \(fmt.string(from: remind))\n" }
        if let icon = data.icon { content += "icon: \(icon.rawValue)\n" }
        if let tint = data.tint { content += "tint: \(tint.rawValue)\n" }
        if let endeavor = data.endeavor, !endeavor.isEmpty {
            content += "endeavor: \(endeavor)\n"
            if let name = data.endeavorName, !name.isEmpty {
                content += "endeavor_name: \(name)\n"
            }
        }
        if data.pinned == true { content += "pinned: true\n" }
        // `kit_order` is written whenever it exists, NOT only alongside
        // `pinned: true`. It was nested inside the pinned branch when the key was
        // still called `pin_order` and only pins had an order. Once trip
        // documents became reorderable the nesting silently swallowed every trip
        // reorder: the index was computed, assigned, and then dropped by this
        // renderer, so the drag animated and the order reverted on reload.
        if let order = data.kitOrder { content += "kit_order: \(order)\n" }
        // Reading shelf (D407), after `kit_order` and in this order in BOTH
        // stores. Key ORDER is part of this format's contract: the same keys
        // emitted in a different order rewrite the file on every save and churn
        // iCloud for nothing.
        //
        // `article: false` is written, not skipped. It is the record that the
        // fetch ran and this page is not prose, which is a different fact from
        // "never tried" and is what keeps the sweep off it.
        if let article = data.articleState { content += "article: \(article.rawValue)\n" }
        if let fetched = data.fetchedOn { content += "fetched: \(fmt.string(from: fetched))\n" }
        if let next = data.readNext { content += "read_next: \(next)\n" }
        if let read = data.readOn { content += "read: \(fmt.string(from: read))\n" }
        // Three decimals, fixed: `\(0.1 + 0.2)` is how a position key rewrites
        // itself with a longer number on every save.
        if let pos = data.readPosition {
            content += "read_position: \(String(format: "%.3f", pos))\n"
        }
        content += "---\n"
        content += renderBody(body)
        return content
    }

    // MARK: - Sidecar parser

    /// The address inside a `.webloc` document's own file, for a link whose
    /// sidecar carries no `url` yet (D384). Nil for every other extension, so
    /// the load loop pays nothing for PDFs and images.
    private func urlFromWebloc(ext: String, relativePath: String) -> String? {
        guard ext == "webloc",
              let fileURL = noteStore.resolvedURL(for: relativePath),
              let data = try? Data(contentsOf: fileURL) else { return nil }
        return TraceMacDocument.url(inWebloc: data)
    }

    private func parseSidecar(at relativePath: String) -> SidecarData? {
        guard let raw = try? noteStore.readFile(relativePath), !raw.isEmpty else { return nil }
        let lines = raw.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        var yamlLines: [String] = []
        var inFrontmatter = false
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces) == "---" {
                if !inFrontmatter { inFrontmatter = true; continue }
                else { break }
            }
            if inFrontmatter { yamlLines.append(line) }
        }
        guard !yamlLines.isEmpty else { return nil }

        var data = SidecarData()
        let dateFmt = DateFormatter(); dateFmt.dateFormat = "yyyy-MM-dd"

        for line in yamlLines {
            let parts = line.split(separator: ":", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            let key = parts[0]; let value = parts[1]
            switch key {
            case "title":       data.title = value
            case "tags":
                let stripped = value.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                data.tags = stripped.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            case "created":     data.created = dateFmt.date(from: value)
            case "linked_note": data.linkedNote = value
            case "people":
                let stripped = value.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                data.people = stripped.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            case "places":
                let stripped = value.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                data.places = stripped.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            case "description": data.description = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            case "url":
                let v = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                data.url = v.isEmpty ? nil : v

            // MARK: Satchel keys (scope doc §4)
            case "endeavor":
                let v = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                data.endeavor = v.isEmpty ? nil : v
            case "endeavor_name":
                let v = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                data.endeavorName = v.isEmpty ? nil : v
            case "pinned":
                let v = value.lowercased()
                data.pinned = (v == "true" || v == "yes" || v == "1")
            case "icon":        data.icon = DocumentIcon.parse(value)
            case "tint":        data.tint = DocumentTint.parse(value)
            // `pin_order` is the key's original name from earlier the same day,
            // read so nothing written in between scrambles. Only `kit_order` is
            // ever written.
            case "remind":
                data.remindOn = dateFmt.date(from: value)
            case "kit_order", "pin_order":
                data.kitOrder = Int(value.trimmingCharacters(in: .whitespaces))

            // MARK: Reading shelf keys (D407)
            case "article":
                data.articleState = ArticleState.parse(value)
            case "fetched":
                data.fetchedOn = dateFmt.date(from: value)
            case "read_next":
                data.readNext = Int(value.trimmingCharacters(in: .whitespaces))
            case "read":
                data.readOn = dateFmt.date(from: value)
            case "read_position":
                data.readPosition = Double(value.trimmingCharacters(in: .whitespaces))

            default: break
            }
        }
        return data
    }
}
