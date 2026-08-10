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
                    summary: body.summary
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
    func saveSidecar(
        for doc: TraceMacDocument,
        title: String,
        tags: [String],
        linkedNote: String?,
        people: [String],
        description: String = "",
        date: Date? = nil                // explicit override; falls back to doc.created or today
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

        data.endeavor     = existing?.endeavor     ?? doc.endeavor
        data.endeavorName = existing?.endeavorName ?? doc.endeavorName
        data.pinned       = existing?.pinned       ?? doc.pinned
        data.icon         = existing?.icon         ?? doc.icon
        data.tint         = existing?.tint         ?? doc.tint
        data.kitOrder     = existing?.kitOrder     ?? doc.kitOrder
        data.remindOn     = existing?.remindOn     ?? doc.remindOn

        try noteStore.writeFile(doc.sidecarPath, content: renderSidecar(data, body: body))
    }

    /// Moves a document (and its sidecar) to a different category subfolder.
    func moveDocument(_ doc: TraceMacDocument, to newCategory: String) throws {
        let newRelativePath = "Documents/\(newCategory)/\(doc.filename)"
        let newSidecarPath: String = {
            let base = newRelativePath.hasSuffix(".\(doc.fileExtension)")
                ? String(newRelativePath.dropLast(doc.fileExtension.count + 1))
                : newRelativePath
            return "\(base).md"
        }()
        // Move the binary document file using the iCloud-safe mover
        try noteStore.moveItem(from: doc.relativePath, to: newRelativePath)
        // Move sidecar if it exists (text file — moveFile is fine)
        if let sidecar = try? noteStore.readFile(doc.sidecarPath), !sidecar.isEmpty {
            try? noteStore.moveFile(from: doc.sidecarPath, to: newSidecarPath)
        }
    }

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
        let relativePath = try noteStore.writeDocument(data, category: "Inbox", filename: filename)
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
        var extra: String = ""

        var isEmpty: Bool {
            note.isEmpty && summary.isEmpty && extra.isEmpty
        }
    }

    static let noteHeading = "## Note"
    static let summaryHeading = "## Summary"

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

        enum Section { case none, note, summary }
        var section: Section = .none
        var note: [String] = [], summary: [String] = [], extra: [String] = []

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == Self.noteHeading {
                section = .note
            } else if trimmed == Self.summaryHeading {
                section = .summary
            } else if trimmed.hasPrefix("## ") {
                // An unrecognised heading — hand it and everything under it to
                // `extra` rather than swallowing it into the previous section.
                section = .none
                extra.append(line)
            } else {
                switch section {
                case .note:    note.append(line)
                case .summary: summary.append(line)
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
