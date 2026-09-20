// TraceMacDocumentStore.swift
// Scans Trace's iCloud Documents/ folder and builds a browsable list.
// Sidecar .md files store optional title/tag metadata alongside each document.
// Mac-only — do not add to iOS, Widget, or Share Extension targets.
//
// Session 50 (2026-07-27) — defensive parity with `IOSDocumentStore`.
//
// Satchel writes extra sidecar keys into the SAME shared `Documents/` folder
// this store reads. This file is a separate implementation from the iOS store,
// and as written it rebuilt each sidecar from scratch on every save, so one edit
// in TraceMac's Documents view would silently erase a document's pin, icon, tint
// and Endeavor.
//
// THE RULE, not the list (Session 63, 2026-08-01). The original version of this
// comment named five keys — `endeavor`, `endeavor_name`, `pinned`, `icon`,
// `tint` — and the parser and renderer each carried a matching hand-kept list.
// `remind` was then added on iOS. Nothing here knew about it, so for a month any
// Mac save silently deleted a reminder date set on iPhone.
//
// A guard written as an enumeration of the things it guards is wrong the moment
// the set grows, and it is wrong silently, because the omission compiles. So:
// **the only correct way to add a sidecar key on iOS is to add it here in the
// same change.** `SidecarData`, `parseSidecar` and `renderSidecar` are one table
// read in three directions and must be edited together. If you are reading this
// because a key went missing again, that is the bug, and the fix is not to add
// a sixth entry to a list.
//
// Two changes, both non-behavioural for existing Mac features:
//   1. The parser reads the Satchel keys, so `TraceMacDocument` carries them on
//      the Mac too and nothing renders blank if Mac UI ever wants them.
//   2. `saveSidecar` merges rather than replaces — same preserve-by-default
//      semantics as the iOS store, so all three TraceMacDocumentsView call sites
//      stay correct with no edits.
//
// Session 105 (2026-09-14) added five more — `article`, `fetched`, `read_next`,
// `read`, `read_position`, the reading shelf (D407) — in the same build as the
// iOS side, which is what the rule above asks for and what `remind` did not get.
//
// **One of those keys got a writer on 2026-09-14 (D412): `pinned`.** The
// sentence below was true while Satchel was iOS-only and the Mac was a
// bystander. The Mac now has a Satchel screen and a rail that SHOWS what is in
// Kit, and a screen that shows a thing you cannot change is a screen that sends
// you to your phone to change it. `setPinned` is the one writer; everything
// else here still only reads and re-emits, and the paragraph above — add a key
// in both stores in the same change — is unaffected.
//
// The Mac deliberately gets no *other* writers for these keys. v1 of Satchel is
// iOS-only (build starter, "Deliberately NOT in v1"), so the Mac's job here is
// to not destroy what it does not manage. Key order in `renderSidecar` is kept
// byte-identical to the iOS store's so the two apps do not churn the same file
// back and forth.

import Foundation
import Observation
import LinkPresentation

// TraceMacDocument, DocumentScanResult, DocumentIcon and DocumentTint are
// defined in TraceDocumentModels.swift (shared).

// MARK: - Store

@Observable
class TraceMacDocumentStore {

    var documents: [TraceMacDocument] = []
    var isLoading: Bool = false

    private let noteStore: NoteStore

    init(noteStore: NoteStore) {
        self.noteStore = noteStore
    }

    // MARK: - Filed against a note

    /// The documents filed against one note, newest first.
    ///
    /// **Exact string match, deliberately.** Satchel tidies the path on the way
    /// in precisely so both sides settle on one spelling, and a case-folded or
    /// fuzzy match here would paper over a hand-off writing the WRONG path and
    /// make the real bug much harder to see. That is the phone's shared chips
    /// view's own rule; this is the Mac saying the same thing.
    ///
    /// `remindingOn` is for a DAY note. A document whose `remind:` falls on that
    /// day belongs on that day's page even though it is filed somewhere else, so
    /// a receipt scanned on the 4th and marked ready on the 6th is on the 6th.
    /// Pass nil for anything that is not a day. A document that is both filed
    /// here and reminding that day appears once.
    ///
    /// **The Mac's four older filters are not this function yet.** Places,
    /// People, the project note hub and the Notes list each wrote their own, and
    /// they DIFFER rather than being copies: two fold case, one unions on a
    /// person, one unions on an endeavor. Retiring them onto one rule is a
    /// change to four screens that nobody is testing today, so it is backlogged
    /// rather than folded into the change that adds a fifth caller.
    func filed(to notePath: String, remindingOn day: Date? = nil) -> [TraceMacDocument] {
        var out = documents.filter { $0.linkedNote == notePath }
        if let day {
            let already = Set(out.map(\.relativePath))
            let cal = Calendar.current
            out += documents.filter { doc in
                guard !already.contains(doc.relativePath), let due = doc.remindOn else { return false }
                return cal.isDate(due, inSameDayAs: day)
            }
        }
        return out.sorted { ($0.created ?? .distantPast) > ($1.created ?? .distantPast) }
    }

    // MARK: - Load

    func reload() async {
        guard noteStore.hasAccess else { return }
        await MainActor.run { isLoading = true }

        var result: [TraceMacDocument] = []

        // Scan all immediate subfolders of Documents/
        let subfolders = (try? listSubfolders(in: "Documents")) ?? []
        let scanTargets = subfolders.isEmpty ? ["Documents"] : subfolders.map { "Documents/\($0)" }

        for folder in scanTargets {
            let category = folder == "Documents" ? "Inbox" : String(folder.split(separator: "/").last ?? "")
            let files = (try? noteStore.listDocumentFiles(in: folder)) ?? []

            for filename in files {
                // Skip hidden files
                guard !filename.hasPrefix(".") else { continue }

                // Skip directories (e.g. Documents/Notes/Horizons/ is a subfolder, not a file)
                if let url = noteStore.resolvedURL(for: "\(folder)/\(filename)") {
                    let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                    if isDir { continue }
                }

                let relativePath = "\(folder)/\(filename)"
                let ext = (filename as NSString).pathExtension.lowercased()

                // **`.md` is never a document, and cannot be.** A document's
                // sidecar path is its own path with the extension swapped for
                // `.md`, so a markdown document would be its own metadata file.
                guard !["md","markdown"].contains(ext) else { continue }

                // **`.txt` is a document only when this app wrote one** (D337,
                // Session 95). The original rule here was "Documents is for
                // binary/media files only — skip .txt and .md, those are notes",
                // and it was right for every file that arrives from outside:
                // the window's drop zone still refuses a dropped `.txt` and
                // routes it to `importAsNote`.
                //
                // Research readings broke that assumption from the inside. They
                // are prose the app writes INTO Satchel on purpose (D313), and
                // an unconditional extension test filtered them out after they
                // had been written — the file was on disk and invisible in both
                // the rail and Satchel, which is how David found this.
                //
                // A sidecar beside it is what tells the two apart, and it is
                // not a proxy: a loose note dropped into the folder by hand has
                // no sidecar and is still skipped, exactly as before.
                if ["txt","text"].contains(ext) {
                    let companion = String(relativePath.dropLast(ext.count + 1)) + ".md"
                    guard noteStore.fileExists(companion) else { continue }
                }

                let sidecarRelative = relativePath.hasSuffix(".\(ext)")
                    ? String(relativePath.dropLast(ext.count + 1)) + ".md"
                    : relativePath + ".md"

                // Read sidecar if present
                let sidecar = parseSidecar(at: sidecarRelative)
                let body = readBody(at: sidecarRelative)

                // Derive title from filename — strip leading timestamp (yyyy-MM-dd-HHmmss-)
                let nameNoExt = filename.hasSuffix(".\(ext)")
                    ? String(filename.dropLast(ext.count + 1))
                    : filename
                let timestampPattern = #"^\d{4}-\d{2}-\d{2}-\d{6}-"#
                let stripped = nameNoExt.replacingOccurrences(
                    of: timestampPattern, with: "", options: .regularExpression)
                let derivedTitle = stripped
                    .replacingOccurrences(of: "-", with: " ")
                    .replacingOccurrences(of: "_", with: " ")

                // Filesystem creation date as fallback
                var fsDate: Date? = nil
                if let url = noteStore.resolvedURL(for: relativePath) {
                    fsDate = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.creationDate] as? Date
                }

                // **When it landed, from the filename** (D347). Every import
                // writes `yyyy-MM-dd-HHmmss-` at the front and nothing edits
                // it afterwards, which makes it a better record of arrival than
                // the filesystem — iCloud rewrites creation dates when it
                // materialises a file, so `fsDate` can be the day the Mac
                // downloaded it rather than the day it was filed.
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
                    // it does not, so a `.webloc` dragged in from Finder opens.
                    url: sidecar?.url ?? urlFromWebloc(ext: ext, relativePath: relativePath) ?? "",
                    places: sidecar?.places ?? [],
                    // Reading shelf (D407). Read so the Mac carries them and
                    // re-emits them; no Mac screen shows any of this.
                    articleState: sidecar?.articleState,
                    fetchedOn: sidecar?.fetchedOn,
                    readNext: sidecar?.readNext,
                    readOn: sidecar?.readOn,
                    readPosition: sidecar?.readPosition,
                    highlightsRaw: body.highlights,
                    noteFile: sidecar?.noteFile
                )
                result.append(doc)
            }
        }

        // **Newest ARRIVAL first** (D347), not newest printed date. `created`
        // falls back behind it so a document with no parseable stamp and no
        // filesystem date still sorts somewhere sensible instead of to the
        // bottom.
        result.sort {
            let l = $0.arrived ?? $0.created ?? .distantPast
            let r = $1.arrived ?? $1.created ?? .distantPast
            return l > r
        }

        await MainActor.run {
            documents = result
            isLoading = false
        }
    }

    /// Moved to `TraceMacDocument.arrivalDate(fromFilename:)` in Session 100, so
    /// the phone's port reads the same function rather than a copy of it.

    // MARK: - Sidecar write

    /// Writes a document's sidecar.
    ///
    /// `title`, `tags`, `linkedNote`, `people`, `description` and `date` behave
    /// exactly as they always have. Satchel's keys are **not parameters** here —
    /// the Mac has no UI that sets them — and are instead read back from the
    /// sidecar on disk and re-emitted unchanged. That is the whole point of this
    /// method: TraceMac must not destroy metadata it does not manage.
    ///
    /// Every `existing?.x ?? doc.x` line below must have a counterpart in
    /// `SidecarData`, `parseSidecar` and `renderSidecar`. Four places, one key.
    /// What a save should do to the document's Endeavor.
    ///
    /// **This file could read the association and never change it**, which is
    /// why the Mac had no way to file a document to an Endeavor: you could add
    /// a document from inside an Endeavor, and never the other way round.
    /// David: *"There doesnt seem to be a way to connect a document when im in
    /// satchel to an endeavor… is that true and fixable?"* True, and this is it.
    enum EndeavorAssignment {
        case set(id: String, name: String)
        case clear
    }

    func saveSidecar(
        for doc: TraceMacDocument,
        title: String,
        tags: [String],
        linkedNote: String?,
        people: [String],
        description: String = "",
        date: Date? = nil,               // explicit override; falls back to doc.created or today
        endeavor: EndeavorAssignment? = nil,
        /// Session 72. **Double optional, the same shape `enrichPerson`'s
        /// `birthday: Date??` already uses here**, because this field has three
        /// states and a single optional only carries two: `nil` leaves whatever
        /// is on disk, `.some(nil)` clears it back to the automatic glyph, and
        /// `.some(icon)` sets one. Added last so every existing labelled call
        /// site reads unchanged.
        icon: DocumentIcon?? = nil,
        /// Same three-state shape as `icon`. Session 72 gave colour its own
        /// meaning (the document's TYPE), so it needs its own control and its
        /// own way to be cleared back to gray.
        tint: DocumentTint?? = nil,
        /// Same three-state shape. `nil` preserves (every existing caller),
        /// `.some(date)` sets, `.some(nil)` clears. Added 2026-08-27 so the AI
        /// scan's stated date can be written from the Mac too.
        remindOn: Date?? = nil,
        /// Same three-state shape as `icon` and `remindOn`: `nil` preserves
        /// what is on disk, `.some("")` clears it, `.some(text)` sets it.
        /// Added last so every existing labelled call site reads unchanged.
        url: String?? = nil,
        /// Preserve-by-default like every Satchel key: `nil` keeps what is on
        /// disk, a list (empty included) replaces it. D385, Session 102.
        places: [String]? = nil
    ) throws {
        // Preserve whatever Satchel wrote. Disk wins over the in-memory doc,
        // which may be a synthetic value built by a move (see
        // TraceMacDocumentsView's `movedDoc`) and therefore carry defaults.
        // moveDocument relocates the sidecar before this is called, so reading
        // at doc.sidecarPath finds the real file in both the move and edit paths.
        let existing = parseSidecar(at: doc.sidecarPath)
        // Same reason as everything else in this file: TraceMac must not destroy
        // what it does not manage. The note and summary are read back and
        // re-emitted untouched.
        let body = readBody(at: doc.sidecarPath)

        var data = SidecarData()
        data.title       = title
        data.tags        = tags
        data.created     = date ?? doc.created ?? Date()
        data.linkedNote  = (linkedNote?.isEmpty ?? true) ? nil : linkedNote
        data.people      = people
        data.description = description

        // **Three states, not two.** `nil` means "leave it alone", which is
        // what every existing caller wants and gets by omitting the argument;
        // `.clear` means "remove it". Collapsing those two into one optional is
        // how a save of the title would silently unfile a document.
        switch endeavor {
        case .none:
            data.endeavor     = existing?.endeavor     ?? doc.endeavor
            data.endeavorName = existing?.endeavorName ?? doc.endeavorName
        case .clear:
            data.endeavor     = nil
            data.endeavorName = nil
        case .set(let id, let name):
            data.endeavor     = id
            data.endeavorName = name
        }
        data.pinned       = existing?.pinned       ?? doc.pinned
        // An explicit choice wins; absent one, preserve whatever Satchel wrote.
        if let icon { data.icon = icon }
        else { data.icon = existing?.icon ?? doc.icon }
        if let tint { data.tint = tint }
        else { data.tint = existing?.tint ?? doc.tint }
        data.kitOrder     = existing?.kitOrder     ?? doc.kitOrder
        switch remindOn {
        case .none:            data.remindOn = existing?.remindOn ?? doc.remindOn
        case .some(let value): data.remindOn = value
        }
        switch url {
        case .none:
            data.url = existing?.url ?? (doc.url.isEmpty ? nil : doc.url)
        case .some(let value):
            let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            data.url = trimmed.isEmpty ? nil : trimmed
        }
        data.places = places ?? existing?.places ?? doc.places
        // Preserved, never an argument (D433): only Send to note sets it.
        data.noteFile = existing?.noteFile ?? doc.noteFile
        // Reading shelf (D407). Not parameters: the Mac has no screen that sets
        // any of them, and its whole job here is to hand back what Satchel
        // wrote. Disk wins over the in-memory doc, as everywhere else above.
        data.articleState = existing?.articleState ?? doc.articleState
        data.fetchedOn    = existing?.fetchedOn    ?? doc.fetchedOn
        data.readNext     = existing?.readNext     ?? doc.readNext
        data.readOn       = existing?.readOn       ?? doc.readOn
        data.readPosition = existing?.readPosition ?? doc.readPosition

        try noteStore.writeFile(doc.sidecarPath, content: renderSidecar(data, body: body))
    }

    // MARK: - Kit

    /// Put a document in Kit, or take it out. The Mac's first writer of a
    /// Satchel key (D412).
    ///
    /// **Pinning appends to the END of the order**, the same rule as
    /// `iOSDocumentStore.setPinned` and for the same reason: scope §5's default
    /// is "order pinned", and a new pin jumping ahead of the passport is exactly
    /// the muscle-memory break that rule exists to prevent. Two machines that
    /// appended at different ends would make the Kit order depend on which one
    /// you happened to be sitting at.
    ///
    /// **Unpinning leaves `kit_order` alone.** It means nothing while the
    /// document is out of a Kit group, re-pinning overwrites it, and clearing it
    /// would throw away a position for no gain. Again, iOS's rule, copied
    /// deliberately rather than re-derived.
    ///
    /// Everything else in the sidecar is read back and re-emitted by the same
    /// parse/render pair every other write here uses, so this cannot become the
    /// next key-drop.
    @discardableResult
    func setPinned(_ pinned: Bool, for doc: TraceMacDocument) throws -> TraceMacDocument {
        // Seed from disk, falling back to the in-memory document so a
        // never-scanned file still ends up with a complete sidecar rather than
        // a titleless one.
        var data = parseSidecar(at: doc.sidecarPath) ?? SidecarData()
        if data.title == nil { data.title = doc.title }
        if data.tags.isEmpty { data.tags = doc.tags }
        if data.created == nil { data.created = doc.created ?? Date() }
        if data.people.isEmpty { data.people = doc.people }
        if data.places.isEmpty { data.places = doc.places }
        if data.linkedNote == nil { data.linkedNote = doc.linkedNote }
        if data.description == nil { data.description = doc.description }
        if data.url == nil { data.url = doc.url.isEmpty ? nil : doc.url }
        if data.noteFile == nil { data.noteFile = doc.noteFile }

        data.pinned = pinned
        if pinned {
            let highest = documents.filter(\.pinned).compactMap(\.kitOrder).max() ?? -1
            data.kitOrder = highest + 1
        }

        let body = readBody(at: doc.sidecarPath)
        try noteStore.writeFile(doc.sidecarPath, content: renderSidecar(data, body: body))

        var updated = doc
        updated.pinned = pinned
        updated.kitOrder = data.kitOrder
        if let idx = documents.firstIndex(where: { $0.relativePath == doc.relativePath }) {
            documents[idx] = updated
        }
        return updated
    }

    // MARK: - Reading shelf (D422)

    /// The Mac's writers for the three reading keys, so the Mac reader and
    /// Shelf move the same queue the phone does.
    ///
    /// **The phone's rules, copied deliberately rather than re-derived**, for
    /// the reason `setPinned` gives: two machines that disagreed about where a
    /// promoted article lands would make Up Next depend on which one he was
    /// sitting at. Queue appends to the end; reading clears the queue place;
    /// unreading returns to New, not to the old place.
    @discardableResult
    func setReadNext(_ inQueue: Bool, for doc: TraceMacDocument) throws -> TraceMacDocument {
        let value: Int? = inQueue ? (documents.compactMap(\.readNext).max() ?? -1) + 1 : nil
        return try writeReading(for: doc) { data in
            data.readNext = value
        }
    }

    @discardableResult
    func setRead(_ read: Date?, for doc: TraceMacDocument) throws -> TraceMacDocument {
        try writeReading(for: doc) { data in
            data.readNext = nil
            data.readOn = read
        }
    }

    /// Nil clears it (back at the top).
    @discardableResult
    func setReadPosition(_ position: Double?, for doc: TraceMacDocument) throws -> TraceMacDocument {
        try writeReading(for: doc) { data in
            data.readPosition = position
        }
    }

    /// Rewrite every Up Next position to its index, as the phone does.
    func reorderUpNext(_ ordered: [TraceMacDocument]) throws {
        for (index, doc) in ordered.enumerated() {
            try writeReading(for: doc) { data in
                data.readNext = index
            }
        }
    }

    /// Rewrites `## Highlights` and nothing else (D431, Session 107).
    ///
    /// The frontmatter is seeded exactly as `writeReading` seeds it, so a
    /// highlight made on the Mac cannot drop a key the phone wrote; the rest of
    /// the body is read back and put down again untouched.
    /// Takes the rendered section rather than the highlights themselves, so the
    /// two stores' writers have one shape; the phone's must, because Dayflow
    /// compiles its store without the file the highlight type lives in.
    ///
    /// `noteFile` rides along when Send to note has just made or found the
    /// document's own note: one write for both facts.
    @discardableResult
    func setHighlights(_ rendered: String,
                       for doc: TraceMacDocument,
                       noteFile: String? = nil) throws -> TraceMacDocument {
        var data: SidecarData = seededSidecar(for: doc)
        if let noteFile, !noteFile.isEmpty { data.noteFile = noteFile }
        var body = readBody(at: doc.sidecarPath)
        body.highlights = rendered.trimmingCharacters(in: .whitespacesAndNewlines)

        try noteStore.writeFile(doc.sidecarPath, content: renderSidecar(data, body: body))

        var updated = doc
        updated.highlightsRaw = body.highlights
        updated.noteFile = data.noteFile
        if let index = documents.firstIndex(where: { $0.relativePath == doc.relativePath }) {
            documents[index] = updated
        }
        return updated
    }

    /// What is on disk, with anything missing filled in from the document in
    /// memory. Extracted from `writeReading` in Session 107 so the highlights
    /// writer seeds identically rather than growing a second copy of the rule.
    private func seededSidecar(for doc: TraceMacDocument) -> SidecarData {
        var data = parseSidecar(at: doc.sidecarPath) ?? SidecarData()
        if data.title == nil { data.title = doc.title }
        if data.tags.isEmpty { data.tags = doc.tags }
        if data.created == nil { data.created = doc.created ?? Date() }
        if data.people.isEmpty { data.people = doc.people }
        if data.places.isEmpty { data.places = doc.places }
        if data.linkedNote == nil { data.linkedNote = doc.linkedNote }
        if data.description == nil { data.description = doc.description }
        if data.url == nil { data.url = doc.url.isEmpty ? nil : doc.url }
        if data.noteFile == nil { data.noteFile = doc.noteFile }
        return data
    }

    /// One write path for the three keys, seeded exactly as `setPinned` seeds,
    /// so none of them can become the next key-drop.
    private func writeReading(for doc: TraceMacDocument,
                              change: (inout SidecarData) -> Void) throws -> TraceMacDocument {
        var data: SidecarData = seededSidecar(for: doc)

        change(&data)

        let body = readBody(at: doc.sidecarPath)
        try noteStore.writeFile(doc.sidecarPath, content: renderSidecar(data, body: body))

        var updated = doc
        updated.readNext = data.readNext
        updated.readOn = data.readOn
        updated.readPosition = data.readPosition
        if let idx = documents.firstIndex(where: { $0.relativePath == doc.relativePath }) {
            documents[idx] = updated
        }
        return updated
    }

    // `moveDocument` removed Session 69. It wrote `Documents/<Category>/`,
    // the axis `Documents-App-Scope.md` retired on 2026-07-28 — that doc
    // states the move command "was never built, deliberately", and this was
    // it, built anyway. Its two useful callers set `linked_note` on the way
    // past; that association is now edited directly and nothing moves.

    // MARK: - Import

    /// Imports a file, optionally filing it against an Endeavor in the same step.
    ///
    /// **This is the first Mac writer of Satchel's `endeavor` keys**, and the
    /// header comment above saying the Mac deliberately has none is now out of
    /// date rather than wrong: it was written when Satchel v1 was iOS-only and
    /// the Mac's only job was to not destroy what it did not manage. TraceMac
    /// now has the whole Documents section and an Endeavors destination, and
    /// David asked for exactly this. The non-destruction rule is untouched —
    /// `saveSidecar` still merges, and this method only ever writes a sidecar
    /// for a file it has just created, which by definition has none.
    ///
    /// **Both association keys are written, on purpose.** `endeavor` is what
    /// Satchel's capture sets and what the Mac's rail filters on; `linked_note`
    /// is what `SatchelDocumentChips` on the phone filters on, keyed to the
    /// Endeavor note's own path. They are two different associations that
    /// happen to mean the same thing here, and writing one without the other
    /// produces a document that is visible on one device and invisible on the
    /// other. Setting both is cheaper than choosing, and matches what a
    /// document filed from the phone's Endeavor screen already carries.
    @discardableResult
    func importDocument(from sourceURL: URL, filedTo endeavor: Endeavor? = nil) throws -> String {
        // **The same file dropped on the same endeavor twice is the same file**
        // (D331, Session 92). David dropped his United itinerary a second time
        // to re-run the read and got a second copy in the rail. Re-dropping is
        // the only way to ask a filed document to be read again, so the gesture
        // is right and the duplicate is not: it reuses what is already there
        // and the three verbs come up on it.
        //
        // **Matched on the ORIGINAL filename and on the endeavor, both.** The
        // import prefixes a timestamp precisely so two files called
        // `boarding-pass.pdf` can coexist, and they should — the same name
        // filed to two different trips is two documents. This only collapses a
        // repeat of the same file onto the same trip.
        //
        // Only when there IS an endeavor. A screenshot dropped on the window
        // twice keeps both copies, exactly as it does today; nothing about
        // that gesture says the second one was a mistake.
        if let endeavor,
           let existing = existingImport(named: sourceURL.lastPathComponent, filedTo: endeavor) {
            return existing
        }

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd-HHmmss"
        let timestamp = fmt.string(from: Date())
        let filename = "\(timestamp)-\(sourceURL.lastPathComponent)"
        let data = try Data(contentsOf: sourceURL)
        let relativePath = try noteStore.writeDocument(data,
                                                       category: NoteStore.documentFolder(),
                                                       filename: filename)

        // Same derivation `moveDocument` uses: drop the extension, add `.md`.
        let ext = sourceURL.pathExtension
        let base = (!ext.isEmpty && relativePath.hasSuffix(".\(ext)"))
            ? String(relativePath.dropLast(ext.count + 1))
            : relativePath
        let sidecarPath = "\(base).md"

        var data2 = SidecarData()
        // The original name, not the timestamped filename. The timestamp exists
        // so two files called `boarding-pass.pdf` can coexist on disk; showing
        // it in the rail would be leaking a storage detail into a title.
        data2.title       = sourceURL.deletingPathExtension().lastPathComponent
        data2.created     = Date()
        // **The sidecar is written whether or not there is an endeavor**
        // (Session 92). It used to return early with no endeavor, which meant
        // every file dropped on the window rather than on an endeavor landed
        // with no sidecar at all — and therefore no title. David dropped a
        // United itinerary and got a row with a blank name sitting above its
        // own date, which is what sent me looking at this method.
        //
        // The title is the only thing that needs writing in that case; the two
        // association keys stay nil, which is exactly what "filed, not filed to
        // anything" means. **Both are written when there IS one**, on purpose.
        //
        // **Corrected 2026-09-07.** This comment used to claim the phone
        // filtered on `linked_note` alone, and that filing without it made a
        // document invisible there. Checked rather than repeated:
        // `SatchelEndeavor` filters on `endeavor`, and `TraceSatchelHandoff`
        // accepts either — so does the Mac's rail. Writing both is still right,
        // because a document filed to an endeavor IS linked to its note and the
        // second key is what a note-side reader would look for, but nothing
        // breaks on one alone. The reason is redundancy, not rescue.
        if let endeavor {
            data2.endeavor     = endeavor.id
            data2.endeavorName = endeavor.name
            data2.linkedNote   = endeavor.relativePath
        }
        try noteStore.writeFile(sidecarPath, content: renderSidecar(data2))
        return relativePath
    }

    /// Writes a web address into Satchel as a `.webloc` document (D384),
    /// the Mac half of the phone's share-sheet and Paste doors (D385, D386).
    ///
    /// Same split as `createTextDocument`: the title is the real name, the
    /// file carries a timestamp. The address is written twice on purpose,
    /// once inside the plist (so Finder and Quick Look open it) and once as
    /// the sidecar's `url` (so the Open button and the web chip read it
    /// without touching the file). Both stores fill `url` from the plist at
    /// load when the sidecar has none, so a `.webloc` dragged in by hand is
    /// still whole.
    @discardableResult
    func createLinkDocument(url: String,
                            title: String? = nil,
                            filedTo endeavor: Endeavor? = nil) throws -> String {
        guard let web = TraceMacDocument.openableURL(url),
              let data = TraceMacDocument.weblocData(for: web.absoluteString) else {
            throw NoteStoreError.iCloudUnavailable
        }
        var host = web.host ?? "link"
        if host.lowercased().hasPrefix("www.") { host = String(host.dropFirst(4)) }
        let name = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let displayTitle = name.isEmpty ? host : name
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd-HHmmss"
        let safe = host.replacingOccurrences(of: "/", with: "-")
        let filename = "\(fmt.string(from: Date()))-\(safe).webloc"
        let relativePath = try noteStore.writeDocument(data,
                                                       category: NoteStore.documentFolder(),
                                                       filename: filename)
        let sidecarPath = String(relativePath.dropLast(7)) + ".md"
        var sidecar = SidecarData()
        sidecar.title   = displayTitle
        sidecar.created = Date()
        sidecar.url     = web.absoluteString
        sidecar.icon    = .link
        if let endeavor {
            sidecar.endeavor     = endeavor.id
            sidecar.endeavorName = endeavor.name
            sidecar.linkedNote   = endeavor.relativePath
        }
        try noteStore.writeFile(sidecarPath, content: renderSidecar(sidecar))
        return relativePath
    }

    /// Names a freshly pasted link after its page (Session 102), the Mac half
    /// of the phone's `fillFromLink`. The title is replaced only while it is
    /// still the host the paste gave it: a name David has since typed is never
    /// overwritten by a fetch that finished late. A page that refuses (a login
    /// wall, SharePoint) leaves the host in place, which is the honest name
    /// for a page the Mac cannot read. Never throws; a refusal is normal.
    func fetchLinkTitle(for relativePath: String) async {
        guard let doc = documents.first(where: { $0.relativePath == relativePath }),
              doc.isLink,
              let web = TraceMacDocument.openableURL(doc.url) else { return }
        let hostName: String = {
            var h = web.host ?? ""
            if h.lowercased().hasPrefix("www.") { h = String(h.dropFirst(4)) }
            return h
        }()
        guard doc.title == hostName else { return }
        let provider = LPMetadataProvider()
        provider.timeout = 12
        provider.shouldFetchSubresources = false
        guard let metadata = try? await provider.startFetchingMetadata(for: web),
              let fetched = metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !fetched.isEmpty else { return }
        // Re-read: the row may have been edited while the fetch was out.
        guard let fresh = documents.first(where: { $0.relativePath == relativePath }),
              fresh.title == hostName else { return }
        try? saveSidecar(for: fresh,
                         title: fetched,
                         tags: fresh.tags,
                         linkedNote: fresh.linkedNote,
                         people: fresh.people,
                         description: fresh.description)
        await reload()
    }

    /// Writes text into Satchel as a document, filed to an endeavor.
    ///
    /// **`.txt`, not `.md`, and that is forced rather than chosen** (Session
    /// 95). A document's sidecar path is its own path with the extension
    /// swapped for `.md`, so a document called `Research.md` would have
    /// `Research.md` as its own sidecar — the file would be its own metadata.
    /// `.txt` is the nearest thing that cannot collide.
    ///
    /// **The title is the real name; the file on disk carries a timestamp.**
    /// Same split `importDocument` makes, for the same reason: two research
    /// runs on one endeavor in one day must not overwrite each other, and the
    /// timestamp is storage, not something to read in a rail.
    @discardableResult
    func createTextDocument(title: String,
                            text: String,
                            filedTo endeavor: Endeavor?,
                            tags: [String] = [],
                            description: String = "") throws -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd-HHmmss"
        let safe = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let filename = "\(fmt.string(from: Date()))-\(safe).txt"

        guard let data = text.data(using: .utf8) else {
            throw NoteStoreError.iCloudUnavailable
        }
        let relativePath = try noteStore.writeDocument(data,
                                                       category: NoteStore.documentFolder(),
                                                       filename: filename)

        let sidecarPath = String(relativePath.dropLast(4)) + ".md"
        var sidecar = SidecarData()
        sidecar.title       = title
        sidecar.created     = Date()
        sidecar.tags        = tags
        sidecar.description = description
        if let endeavor {
            sidecar.endeavor     = endeavor.id
            sidecar.endeavorName = endeavor.name
            sidecar.linkedNote   = endeavor.relativePath
        }
        try noteStore.writeFile(sidecarPath, content: renderSidecar(sidecar))
        return relativePath
    }

    /// A document already filed to this endeavor that came from a file of this
    /// name, or nil (D331).
    ///
    /// Reads the folder rather than `documents`, because the one caller that
    /// needs this most builds a store of its own and never loads it — see
    /// `TraceMacContentView.handleGlobalDrop`. A directory listing and at most
    /// a few sidecar reads is cheap next to a drag the user just finished.
    ///
    /// **This year's folder only.** `documentFolder()` is the year, imports go
    /// there, and a re-drop happens seconds after the first one. A copy filed
    /// last December is not what "I just dropped this twice" means.
    private func existingImport(named originalFilename: String, filedTo endeavor: Endeavor) -> String? {
        let folder = "Documents/\(NoteStore.documentFolder())"
        let suffix = "-\(originalFilename)"
        guard let names = try? noteStore.listDocumentFiles(in: folder) else { return nil }
        for name in names where name.hasSuffix(suffix) {
            let relativePath = "\(folder)/\(name)"
            let ext = (name as NSString).pathExtension
            let base = ext.isEmpty ? relativePath : String(relativePath.dropLast(ext.count + 1))
            guard let sidecar = parseSidecar(at: "\(base).md"),
                  sidecar.endeavor == endeavor.id else { continue }
            return relativePath
        }
        return nil
    }

    // MARK: - Auto-scan on arrival (Session 69)

    /// Paths already attempted this session, so a document the model has nothing
    /// to say about is not re-scanned on every reload.
    ///
    /// **Without this it is an unbounded loop, not a retry.** The "needs a scan"
    /// test is "no tags and no description" — which is exactly the state a
    /// scan that returned nothing leaves behind. Every reload would spend
    /// another API call re-asking a question already answered with silence.
    private var scanAttempted: Set<String> = []

    /// Scans documents that have just arrived, when there are few enough of them.
    ///
    /// **The cap is a decision, not a safeguard.** David, on whether new files
    /// should scan themselves: *"single or two files or even up to five seem ok
    /// to me."* One screenshot dropped for filing is worth a call without being
    /// asked; twenty files dragged in at once is a batch he is filing, not
    /// reading, and twenty unrequested calls is a surprise. Over the limit the
    /// documents still scan — on the first open, exactly as they always have.
    ///
    /// Fires after a reload triggered from outside the app, which is the only
    /// time documents appear that nobody in this process just created.
    /// How long a newly arrived file is left alone before it can be scanned.
    ///
    /// **A private drop is TWO files, and the tag that protects it is in the
    /// second one.** David's workflow is CleanShot to Dropzone to here, and
    /// Dropzone writes the image and then a sidecar carrying `tags: [private]`;
    /// nothing in this codebase ever writes that tag, it only reads it. The
    /// view above already notes that "a single drop lands as two events, the
    /// binary and then its sidecar", and debounces 400ms before reloading.
    ///
    /// That debounce is a guess about file ordering, and what it guards is a
    /// screenshot of a bank statement going to Anthropic. `tags.isEmpty` on a
    /// document whose sidecar has not arrived does not mean "no tags", it means
    /// **not known yet** — and the two must never collapse into each other when
    /// the consequence of guessing wrong is unrecoverable. Same rule as D94 and
    /// D116, applied where it costs the most to get wrong.
    ///
    /// Fifteen seconds is far longer than two adjacent file writes and far
    /// shorter than anyone waiting for a title. A deferred document is NOT
    /// marked attempted, so the sidecar landing triggers another reload and it
    /// is reconsidered then.
    private static let arrivalSettleSeconds: TimeInterval = 15

    func autoScanNewArrivals(limit: Int = 5) async {
        let now = Date()
        let candidates = documents.filter { doc in
            (doc.isPDF || doc.isImage)
                && doc.tags.isEmpty
                && doc.description.isEmpty
                && !scanAttempted.contains(doc.relativePath)
                // A sidecar that READS and does not say private is an answer,
                // and answers do not need waiting for — a drop that arrives with
                // its metadata is scanned as promptly as it ever was.
                //
                // **`readable`, not `exists`.** An iCloud sidecar can be present
                // as a stub whose contents have not arrived, which is exactly
                // how a private capture from the phone got scanned here: the
                // file existed, so the delay was skipped, and it could not be
                // parsed, so it read as not private.
                //
                // Everything else waits out the settle window and is
                // reconsidered, including a file whose creation date cannot be
                // read (`?? false`). Failing closed is the only sane default
                // when the thing being guarded is unrecoverable.
                && (privacyOnDisk(doc) == .notPrivate
                    || (doc.created.map { now.timeIntervalSince($0) >= Self.arrivalSettleSeconds } ?? false))
        }
        guard !candidates.isEmpty, candidates.count <= limit else {
            // Mark an over-limit batch as seen so it does not re-evaluate on
            // every reload — they will scan on first open.
            if candidates.count > limit {
                candidates.forEach { scanAttempted.insert($0.relativePath) }
            }
            return
        }

        for doc in candidates {
            // **Re-read the sidecar from disk immediately before sending.**
            // `documents` was built when the folder was last walked, and the
            // tag that forbids this may have landed since. The settle delay
            // above makes that unlikely; this makes it not matter. Two cheap
            // checks against one irreversible mistake.
            //
            // Not marked attempted: if it is private it will fail the
            // `tags.isEmpty` filter next time anyway, and if this read failed
            // for some other reason it deserves another look.
            // **Only a definite "not private" proceeds.** `.unknown` waits: it
            // is not marked attempted, so the next reload — after iCloud has
            // finished delivering the sidecar — reconsiders it.
            guard privacyOnDisk(doc) == .notPrivate else { continue }
            scanAttempted.insert(doc.relativePath)
            guard let result = try? await DocumentScanService.scan(
                doc: doc,
                noteStore: noteStore,
                existingTags: [],
                userContext: ""
            ) else { continue }

            // The title is the whole point of doing this unprompted. The model
            // returns one only when the filename looks auto-generated, which a
            // `CleanShot 2026-08-10 at 20.19.45.png` does — and `doc.title`
            // falls back to that filename, so passing it through unchanged when
            // the model declines is correct rather than lazy.
            // **Icon and tint too, since Session 95 (D343).** The phone's
            // scanner has asked for both since Session 72 and this one never
            // did, so a document that arrived on the Mac came out grey and
            // Unclassified while the same document captured on the phone came
            // out coloured and typed. David, looking at his list: *"can we make
            // many of the icons in satchel more colorful. the ones at the top
            // are all grey."* They were the ones the Mac had scanned.
            //
            // Grey is not a missing colour — `resolvedTint` returns grey for a
            // document with no KIND, deliberately (Session 72: colour says what
            // kind of thing a document is, and an untyped one is honestly
            // uncoloured rather than borrowing a hue that means something else).
            // The defect was never the rule; it was one scanner not answering
            // the question.
            try? saveSidecar(
                for: doc,
                title: result.title ?? doc.title,
                tags: result.tags,
                linkedNote: doc.linkedNote,
                people: doc.people,
                description: result.description,
                icon: .some(result.icon),
                tint: .some(result.tint)
            )
        }
        await reload()
    }

    // MARK: - Text extraction

    /// Reads the words out of every document that has not been read yet, and
    /// writes them into the sidecar under `## Text`.
    ///
    /// **No limit, unlike `autoScanNewArrivals`.** That function caps at five
    /// because each one is a network call to Claude that costs money and sends
    /// the document out. This is Vision and PDFKit on this Mac: no key, no
    /// network, no per-item cost. The only reason to cap it would be time, and
    /// the whole container is eighteen files.
    ///
    /// So the first run after this ships is a backfill of everything already in
    /// Satchel, and every run after that is however many arrived since.
    ///
    /// **The `private` tag is not consulted, deliberately.** §5b binds Ask,
    /// which sends text to an API. Nothing here leaves the machine, and a
    /// private document that cannot be found by local search is unfindable in
    /// the one place it was safe to find.
    func extractTextForNewArrivals() async {
        let pending = documents.filter { doc in
            (doc.isPDF || doc.isImage) && !doc.textExtracted
        }
        guard !pending.isEmpty else { return }

        var wrote = false
        for doc in pending {
            guard let url = noteStore.resolvedURL(for: doc.relativePath) else { continue }
            // Detached: Vision on a full page is tens of milliseconds, and a
            // scanned PDF is that per page. Same rule `findWikilinkMentions` and
            // the tag scan follow.
            let text = await Task.detached { MacTextExtraction.extract(from: url) }.value
            // `nil` means "not a kind this can read" and must not write a
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

    /// Writes only the `## Text` section, preserving everything else on disk.
    ///
    /// **When no sidecar exists yet it writes one with no title**, which looks
    /// like an omission and is the opposite. `importDocument` deliberately
    /// leaves the title empty so `DocumentScanService` still sees a question
    /// worth answering; the Dropzone action learned the same lesson the hard way
    /// (HANDOFF addendum 11) when a helpfully pre-filled title stopped the model
    /// ever suggesting one. `renderSidecar` emits a bare `title:` line, and
    /// `parseSidecar` reads that back as nil, so the derived title still wins
    /// and the document is still a scan candidate.
    /// What the disk says about this document's privacy, **including "I cannot
    /// tell yet".**
    ///
    /// **The two-valued version of this shipped a private document to Anthropic.**
    /// David captured one on his phone with the new private button; the Mac
    /// picked it up over iCloud, ran the AI on it, and the result synced back.
    /// `isPrivateOnDisk` had been `guard let data = parseSidecar(…) else {
    /// return false }` — so a sidecar that exists but has not finished
    /// downloading, and therefore cannot be read, answered **"not private"**.
    ///
    /// That is the identical defect as D114, D116 and D117, committed inside the
    /// function written to prevent it. Absence of an answer is not an answer,
    /// and when the consequence is a bank statement leaving the machine it has
    /// to be its own case with its own name.
    enum DiskPrivacy {
        case notPrivate
        case isPrivate
        /// No sidecar, or one that could not be read. **Never scan on this.**
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

    private func writeExtractedText(_ text: String, for doc: TraceMacDocument) throws {
        var body = readBody(at: doc.sidecarPath)
        body.text = text
        body.hasTextSection = true

        var data = parseSidecar(at: doc.sidecarPath) ?? SidecarData()
        if data.created == nil { data.created = doc.created ?? Date() }

        try noteStore.writeFile(doc.sidecarPath, content: renderSidecar(data, body: body))
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

    // MARK: - Sidecar model

    private struct SidecarData {
        var title: String?
        var tags: [String] = []
        var created: Date?
        var linkedNote: String?
        var people: [String] = []
        var description: String?
        /// Sidecar key `url` (D350). Every note on `remindOn` below applies: a
        /// key this store does not know is a key this store DELETES, because
        /// `saveSidecar` rebuilds the frontmatter from this struct. Added to
        /// `IOSDocumentStore` in the same pass for that reason - one store
        /// knowing it is worse than neither, since the phone would then strip
        /// it on its next save and the loss would look like the Mac's bug.
        var url: String?
        var endeavor: String?
        var endeavorName: String?
        var pinned: Bool?
        var icon: DocumentIcon?
        var tint: DocumentTint?
        var kitOrder: Int?
        /// Sidecar key `remind`. Session 63 (2026-08-01).
        ///
        /// This field did not exist and its absence was destroying data. The
        /// header comment on this file lists the five Satchel keys it protects;
        /// `remind` was added on iOS *after* that comment was written, so the
        /// parser had no `case` for it and the renderer never emitted it. Since
        /// `saveSidecar` rebuilds frontmatter from this struct, retitling a
        /// document on the Mac silently erased a reminder date set on iPhone.
        ///
        /// The guard was a hand-kept list of the things it guarded, which is a
        /// guard that goes wrong the first time the set grows. It grew.
        var remindOn: Date?
        /// Sidecar key `places` (D385). Same rule as `url` and `remind`: a
        /// key this struct does not carry is a key the next save deletes.
        /// Added to `IOSDocumentStore` in the same pass.
        var places: [String] = []
        /// The document's OWN note, sidecar key `note_file` (D433, Session 107).
        ///
        /// **Not `linked_note`.** That one links the document to a PROJECT note
        /// shared by every document in the project, and this app's project
        /// filtering reads it; pointing it at a per-document note would pull the
        /// document out of its project. This is a second, separate link, and the
        /// endeavor is a third. Both stores gained it in the same build, before
        /// anything could write one, which is the rule `remind` did not get.
        var noteFile: String?
        /// Reading shelf keys (D407, Session 105): `article`, `fetched`,
        /// `read_next`, `read`, `read_position`. The rule at the top of this
        /// file, applied on time for once: these went into both stores in the
        /// same build, BEFORE anything on the phone could write one, so there
        /// was never a window in which a Mac save could delete them.
        var articleState: ArticleState?
        var fetchedOn: Date?
        var readNext: Int?
        var readOn: Date?
        var readPosition: Double?
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
        /// On-device OCR / PDF text layer. Written once when the document
        /// arrives, read by search forever after. Session 70, spec §8 step 2.
        var text: String = ""
        /// Whether a `## Text` heading is present on disk, **independently of
        /// whether there is anything under it.**
        ///
        /// This is the marker that stops a photograph of a sunset being
        /// re-OCR’d on every launch. "Needs extraction" is *no heading*, not
        /// *no text* — because a pass that found nothing leaves behind exactly
        /// what "no text" looks like. Same trap D90 named for the AI scan,
        /// where a scan returning nothing left a document looking unscanned.
        ///
        /// **Deliberately not a frontmatter key.** A key would have to be added
        /// to `SidecarData`, `parseSidecar` and `renderSidecar` here *and* in
        /// `IOSDocumentStore`, or the phone would drop it on its next save.
        /// Eight places for one flag. A body heading needs none of that: iOS
        /// does not recognise `## Text`, so its parser files the whole section
        /// under `extra` and re-emits it untouched, which is what `extra` is
        /// for.
        var hasTextSection: Bool = false
    /// Highlights he made while reading, under `## Highlights` (D431).
    ///
    /// **A body section, not a frontmatter key**, for the same reason `## Text`
    /// is one: a key the other store does not know is a key that store's next
    /// save deletes. Both stores parse and re-emit this section as of the same
    /// build, which is the D407 Build 1 rule.
    var highlights: String = ""
        var extra: String = ""

        var isEmpty: Bool {
            note.isEmpty && summary.isEmpty && extra.isEmpty
                && text.isEmpty && !hasTextSection && highlights.isEmpty
        }
    }

    static let noteHeading = "## Note"
    static let summaryHeading = "## Summary"
    static let textHeading = "## Text"
    /// Byte-identical in both stores, like `textHeading`, and spelt out here
    /// rather than borrowed from `SatchelHighlightText` so neither store gains
    /// a compile-time dependency on a file its target may not carry.
    static let highlightsHeading = "## Highlights"

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

        enum Section { case none, note, summary, text, highlights }
        var section: Section = .none
        var note: [String] = [], summary: [String] = [], extra: [String] = []
        var text: [String] = []
        var highlights: [String] = []

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
            } else if trimmed == Self.highlightsHeading {
                section = .highlights
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
                case .highlights: highlights.append(line)
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
        body.highlights = tidy(highlights)
        body.extra = tidy(extra)
        // A round trip through the phone puts `## Text` and its contents into
        // `extra`, because iOS does not recognise the heading. Recovered here
        // so the Mac does not decide the document is unextracted and run Vision
        // over it again every time a document is edited on the phone.
        if !body.hasTextSection, let range = body.extra.range(of: Self.textHeading) {
            body.hasTextSection = true
            body.text = String(body.extra[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            body.extra = String(body.extra[..<range.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
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
        // The heading is written even when the text is empty. That is the whole
        // marker: it says the pass ran and this file has nothing readable in it.
        if body.hasTextSection {
            out += body.text.isEmpty
                ? "\n\(Self.textHeading)\n"
                : "\n\(Self.textHeading)\n\n\(body.text)\n"
        }
        // After the article and before `extra`, in both stores. Only a
        // document with highlights gains the section at all, so nothing that
        // has none is rewritten by this build.
        if !body.highlights.isEmpty {
            out += "\n\(Self.highlightsHeading)\n\n\(body.highlights)\n"
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

    /// Key order is byte-identical to `IOSDocumentStore.renderSidecar` on purpose:
    /// the original six, then icon/tint, then the Endeavor pair, then the pin.
    /// If the two ever diverge, every document edited on both machines rewrites
    /// its sidecar on each save and iCloud churns for no reason.
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
        // Directly after `people`, byte-identical to `IOSDocumentStore` (D385).
        if !data.places.isEmpty {
            let placesLine = "[" + data.places.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ", ") + "]"
            content += "places: \(placesLine)\n"
        }
        let trimmedDesc = (data.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedDesc.isEmpty {
            // Escape internal double quotes and store as a single quoted line
            let escaped = trimmedDesc.replacingOccurrences(of: "\"", with: "'")
            content += "description: \"\(escaped)\"\n"
        }
        // `remind` sits between `description` and `icon` because that is where
        // `IOSDocumentStore.renderSidecar` puts it. Position matters as much as
        // presence here: emitting the same key in a different order makes every
        // document edited on both machines rewrite its sidecar on each save,
        // which is the iCloud churn the comment above is about.
        // `url` sits between `description` and `remind`, and `IOSDocumentStore`
        // emits it in the same place. Key ORDER is part of this format's
        // contract: the same keys in a different order rewrites the file on
        // every save and churns iCloud for nothing.
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
        // stores. Key ORDER is part of this format's contract, for the reason
        // written above `url`.
        //
        // `article: false` is written, not skipped: it records that the fetch
        // ran and this page is not prose, which is a different fact from
        // "never tried".
        if let article = data.articleState { content += "article: \(article.rawValue)\n" }
        if let fetched = data.fetchedOn { content += "fetched: \(fmt.string(from: fetched))\n" }
        if let next = data.readNext { content += "read_next: \(next)\n" }
        if let read = data.readOn { content += "read: \(fmt.string(from: read))\n" }
        // Three decimals, fixed, matching iOS exactly.
        if let pos = data.readPosition {
            content += "read_position: \(String(format: "%.3f", pos))\n"
        }
        if let noteFile = data.noteFile, !noteFile.isEmpty {
            content += "note_file: \(noteFile)\n"
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

        // Extract YAML frontmatter between --- delimiters
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
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"

        for line in yamlLines {
            let parts = line.split(separator: ":", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            let key = parts[0]; let value = parts[1]
            switch key {
            case "title":
                data.title = value
            case "tags":
                let stripped = value
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                data.tags = stripped.components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            case "created":
                data.created = dateFmt.date(from: value)
            case "note_file":
                let v = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                data.noteFile = v.isEmpty ? nil : v
            case "linked_note":
                data.linkedNote = value
            case "people":
                let stripped = value
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                data.people = stripped.components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            case "places":
                let stripped = value
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                data.places = stripped.components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            case "description":
                // Strip surrounding double quotes if present
                data.description = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))

            case "url":
                // `maxSplits: 1` above is what makes this safe: the colon in
                // `https://` stays in the value.
                let v = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                data.url = v.isEmpty ? nil : v

            // MARK: Satchel keys — read and preserved, never written by Mac UI
            case "endeavor":
                let v = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                data.endeavor = v.isEmpty ? nil : v
            case "endeavor_name":
                let v = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                data.endeavorName = v.isEmpty ? nil : v
            case "pinned":
                let v = value.lowercased()
                data.pinned = (v == "true" || v == "yes" || v == "1")
            case "icon":
                data.icon = DocumentIcon.parse(value)
            case "tint":
                data.tint = DocumentTint.parse(value)
            case "remind":
                data.remindOn = dateFmt.date(from: value)
            case "kit_order", "pin_order":
                data.kitOrder = Int(value.trimmingCharacters(in: .whitespaces))

            // MARK: Reading shelf keys (D407) — read and preserved, no Mac UI
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

            default:
                break
            }
        }
        return data
    }
}
