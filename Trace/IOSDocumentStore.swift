// iOSDocumentStore.swift
// iOS document store — reads the same iCloud Documents/ folder as the Mac.
// Shares TraceMacDocument model. No AppKit dependencies.
// iOS-only — do not add to Mac target (Mac uses TraceMacDocumentStore).

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
                    description: sidecar?.description ?? ""
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

    func saveSidecar(
        for doc: TraceMacDocument,
        title: String,
        tags: [String],
        linkedNote: String?,
        people: [String],
        description: String = "",
        date: Date? = nil
    ) throws {
        let tagLine = tags.isEmpty ? "[]" : "[" + tags.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.joined(separator: ", ") + "]"
        let peopleLine = people.isEmpty ? "[]" : "[" + people.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ", ") + "]"
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let resolvedDate = date ?? doc.created ?? Date()
        let dateStr = fmt.string(from: resolvedDate)
        var content = "---\ntitle: \(title)\ntags: \(tagLine)\ncreated: \(dateStr)\n"
        if let note = linkedNote, !note.isEmpty { content += "linked_note: \(note)\n" }
        if !people.isEmpty { content += "people: \(peopleLine)\n" }
        let trimmedDesc = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedDesc.isEmpty {
            let escaped = trimmedDesc.replacingOccurrences(of: "\"", with: "'")
            content += "description: \"\(escaped)\"\n"
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

    // MARK: - Delete

    func deleteDocument(_ doc: TraceMacDocument) throws {
        try noteStore.deleteFile(doc.relativePath)
        // Best-effort sidecar removal — ignore if it doesn't exist.
        try? noteStore.deleteFile(doc.sidecarPath)
    }

    // MARK: - Move

    func moveDocument(_ doc: TraceMacDocument, to newCategory: String) throws {
        let newRelativePath = "Documents/\(newCategory)/\(doc.filename)"
        let newSidecarPath: String = {
            let base = newRelativePath.hasSuffix(".\(doc.fileExtension)")
                ? String(newRelativePath.dropLast(doc.fileExtension.count + 1))
                : newRelativePath
            return "\(base).md"
        }()
        try noteStore.moveItem(from: doc.relativePath, to: newRelativePath)
        if let sidecar = try? noteStore.readFile(doc.sidecarPath), !sidecar.isEmpty {
            try? noteStore.moveFile(from: doc.sidecarPath, to: newSidecarPath)
        }
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
        var people: [String]
        var description: String?
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

        var data = SidecarData(tags: [], people: [])
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
            default: break
            }
        }
        return data
    }
}
