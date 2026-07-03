// TraceMacDocumentStore.swift
// Scans Trace's iCloud Documents/ folder and builds a browsable list.
// Sidecar .md files store optional title/tag metadata alongside each document.
// Mac-only — do not add to iOS, Widget, or Share Extension targets.

import Foundation
import Observation

// MARK: - Document model

struct TraceMacDocument: Identifiable, Hashable {
    let id: UUID = UUID()
    let relativePath: String     // "Documents/Inbox/2026-07-02-receipt.pdf"
    let filename: String         // "2026-07-02-receipt.pdf"
    let category: String         // "Inbox", "Project", "Place", etc.
    let fileExtension: String    // "pdf", "jpg", "png", etc. (lowercased)
    var title: String            // from sidecar or derived from filename
    var tags: [String]           // from sidecar frontmatter
    var created: Date?           // from sidecar or filesystem
    var linkedNote: String?      // from sidecar `linked_note` field

    var isPDF: Bool   { fileExtension == "pdf" }
    var isImage: Bool { ["jpg","jpeg","png","heic","gif","webp"].contains(fileExtension) }

    /// Relative path of the sidecar markdown file.
    var sidecarPath: String {
        let base = relativePath.hasSuffix(".\(fileExtension)")
            ? String(relativePath.dropLast(fileExtension.count + 1))
            : relativePath
        return "\(base).md"
    }
}

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
                    linkedNote: sidecar?.linkedNote
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

    func saveSidecar(for doc: TraceMacDocument, title: String, tags: [String], linkedNote: String?) throws {
        let tagLine = tags.isEmpty ? "[]" : "[" + tags.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.joined(separator: ", ") + "]"
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let dateStr = doc.created.map { fmt.string(from: $0) } ?? fmt.string(from: Date())
        var content = "---\ntitle: \(title)\ntags: \(tagLine)\ncreated: \(dateStr)\n"
        if let note = linkedNote, !note.isEmpty {
            content += "linked_note: \(note)\n"
        }
        content += "---\n"
        try noteStore.writeFile(doc.sidecarPath, content: content)
    }

    // MARK: - Import

    func importDocument(from sourceURL: URL) throws {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd-HHmmss"
        let timestamp = fmt.string(from: Date())
        let filename = "\(timestamp)-\(sourceURL.lastPathComponent)"
        let data = try Data(contentsOf: sourceURL)
        try noteStore.writeDocument(data, category: "Inbox", filename: filename)
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

    // MARK: - Sidecar parser

    private struct SidecarData {
        var title: String?
        var tags: [String]
        var created: Date?
        var linkedNote: String?
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

        var data = SidecarData(tags: [])
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
            default:
                break
            }
        }
        return data
    }
}
