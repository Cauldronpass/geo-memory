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
                guard !["txt", "md", "markdown", "text"].contains(ext) else { continue }

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

        result.sort { ($0.created ?? .distantPast) > ($1.created ?? .distantPast) }

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
        summary: String? = nil
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

        data.endeavor     = resolvedString(new: endeavor,     existing: existing?.endeavor)
        data.endeavorName = resolvedString(new: endeavorName, existing: existing?.endeavorName)
        data.pinned       = pinned ?? existing?.pinned ?? false
        data.icon         = icon ?? existing?.icon
        data.tint         = tint ?? existing?.tint
        data.kitOrder     = kitOrder ?? existing?.kitOrder

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
        summary: String? = nil
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
            endeavor: doc.endeavor,
            endeavorName: doc.endeavorName,
            pinned: doc.pinned,
            icon: doc.icon,
            tint: doc.tint,
            kitOrder: doc.kitOrder,
            remindOn: doc.remindOn
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
        var endeavor: String?
        var endeavorName: String?
        var pinned: Bool?
        var icon: DocumentIcon?
        var tint: DocumentTint?
        var kitOrder: Int?
        var remindOn: Date?

        init(
            title: String? = nil,
            tags: [String] = [],
            created: Date? = nil,
            linkedNote: String? = nil,
            people: [String] = [],
            description: String? = nil,
            endeavor: String? = nil,
            endeavorName: String? = nil,
            pinned: Bool? = nil,
            icon: DocumentIcon? = nil,
            tint: DocumentTint? = nil,
            kitOrder: Int? = nil,
            remindOn: Date? = nil
        ) {
            self.title = title
            self.tags = tags
            self.created = created
            self.linkedNote = linkedNote
            self.people = people
            self.description = description
            self.endeavor = endeavor
            self.endeavorName = endeavorName
            self.pinned = pinned
            self.icon = icon
            self.tint = tint
            self.kitOrder = kitOrder
            self.remindOn = remindOn
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
        let trimmedDesc = (data.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedDesc.isEmpty {
            let escaped = trimmedDesc.replacingOccurrences(of: "\"", with: "'")
            content += "description: \"\(escaped)\"\n"
        }
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
            case "description": data.description = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))

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

            default: break
            }
        }
        return data
    }
}
