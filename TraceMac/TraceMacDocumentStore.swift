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
// The Mac deliberately gets no *writers* for these keys. v1 of Satchel is
// iOS-only (build starter, "Deliberately NOT in v1"), so the Mac's job here is
// to not destroy what it does not manage. Key order in `renderSidecar` is kept
// byte-identical to the iOS store's so the two apps do not churn the same file
// back and forth.

import Foundation
import Observation

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

                // Documents section is for binary/media files only.
                // Skip .txt and .md files — those are notes and belong in Journal sections.
                guard !["txt","md","markdown","text"].contains(ext) else { continue }

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
                    textExtracted: body.hasTextSection
                )
                result.append(doc)
            }
        }

        // Sort newest first
        result.sort {
            ($0.created ?? .distantPast) > ($1.created ?? .distantPast)
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
        endeavor: EndeavorAssignment? = nil
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
        data.icon         = existing?.icon         ?? doc.icon
        data.tint         = existing?.tint         ?? doc.tint
        data.kitOrder     = existing?.kitOrder     ?? doc.kitOrder
        data.remindOn     = existing?.remindOn     ?? doc.remindOn

        try noteStore.writeFile(doc.sidecarPath, content: renderSidecar(data, body: body))
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
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd-HHmmss"
        let timestamp = fmt.string(from: Date())
        let filename = "\(timestamp)-\(sourceURL.lastPathComponent)"
        let data = try Data(contentsOf: sourceURL)
        let relativePath = try noteStore.writeDocument(data,
                                                       category: NoteStore.documentFolder(),
                                                       filename: filename)
        guard let endeavor else { return relativePath }

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
        data2.endeavor     = endeavor.id
        data2.endeavorName = endeavor.name
        data2.linkedNote   = endeavor.relativePath
        try noteStore.writeFile(sidecarPath, content: renderSidecar(data2))
        return relativePath
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
                // A sidecar that EXISTS and does not say private is an answer,
                // and answers do not need waiting for. The delay applies only
                // when there is no sidecar at all, which is the one state that
                // cannot be told apart from "the sidecar has not landed yet".
                // So a drop that arrives with its metadata is scanned as
                // promptly as it ever was, and only the genuinely ambiguous
                // case pays the fifteen seconds.
                //
                // `?? false` on the date: a file whose creation date cannot be
                // read waits rather than proceeds. Failing closed is the only
                // sane default when the thing being guarded is unrecoverable.
                && (sidecarExists(doc)
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
            if isPrivateOnDisk(doc) { continue }
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
            try? saveSidecar(
                for: doc,
                title: result.title ?? doc.title,
                tags: result.tags,
                linkedNote: doc.linkedNote,
                people: doc.people,
                description: result.description
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
    /// Whether a sidecar file is present for this document right now.
    func sidecarExists(_ doc: TraceMacDocument) -> Bool {
        guard let url = noteStore.resolvedURL(for: doc.sidecarPath) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// The `private` tag as it stands on disk right now, not as it stood when
    /// `documents` was last built.
    func isPrivateOnDisk(_ doc: TraceMacDocument) -> Bool {
        guard let data = parseSidecar(at: doc.sidecarPath) else { return false }
        return data.tags.contains { $0.caseInsensitiveCompare("private") == .orderedSame }
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
        var extra: String = ""

        var isEmpty: Bool {
            note.isEmpty && summary.isEmpty && extra.isEmpty
                && text.isEmpty && !hasTextSection
        }
    }

    static let noteHeading = "## Note"
    static let summaryHeading = "## Summary"
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
        content += "---\n"
        content += renderBody(body)
        return content
    }

    // MARK: - Sidecar parser

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
            case "linked_note":
                data.linkedNote = value
            case "people":
                let stripped = value
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                data.people = stripped.components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            case "description":
                // Strip surrounding double quotes if present
                data.description = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))

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

            default:
                break
            }
        }
        return data
    }
}
