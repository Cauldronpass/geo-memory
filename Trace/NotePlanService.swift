import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - NotePlanService

@Observable
class NotePlanService {
    static let shared = NotePlanService()

    private let bookmarkKey = "noteplan_folder_bookmark"
    var hasAccess: Bool = false

    init() {
        hasAccess = UserDefaults.standard.data(forKey: bookmarkKey) != nil
    }

    // MARK: - Bookmark management

    /// Called from the document picker callback with the user-selected URL.
    func saveBookmark(for url: URL) throws {
        _ = url.startAccessingSecurityScopedResource()
        defer { url.stopAccessingSecurityScopedResource() }
        let data = try url.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(data, forKey: bookmarkKey)
        hasAccess = true
    }

    func clearBookmark() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        hasAccess = false
    }

    private func resolvedURL() throws -> URL {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else {
            throw NotePlanError.noAccess
        }
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        if isStale {
            // Refresh the bookmark while we have access
            _ = url.startAccessingSecurityScopedResource()
            if let fresh = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) {
                UserDefaults.standard.set(fresh, forKey: bookmarkKey)
            }
            url.stopAccessingSecurityScopedResource()
        }
        return url
    }

    /// Resolves the bookmark, starts security scope, runs block, stops scope.
    private func withAccess<T>(_ block: (URL) throws -> T) throws -> T {
        let url = try resolvedURL()
        guard url.startAccessingSecurityScopedResource() else {
            throw NotePlanError.accessDenied
        }
        defer { url.stopAccessingSecurityScopedResource() }
        return try block(url)
    }

    // MARK: - Daily note

    /// Appends a markdown string to today's (or a given date's) daily note.
    /// Creates the file with a date header if it doesn't exist yet.
    func appendToDailyNote(_ text: String, date: Date = Date()) throws {
        try withAccess { documentsURL in
            let calURL = documentsURL.appendingPathComponent("Calendar")
            try FileManager.default.createDirectory(at: calURL, withIntermediateDirectories: true)

            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            let dateStr = formatter.string(from: date)
            let fileURL = calURL.appendingPathComponent("\(dateStr).md")

            if FileManager.default.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                handle.seekToEndOfFile()
                handle.write(Data("\n\(text)".utf8))
                handle.closeFile()
            } else {
                let content = "# \(dateStr)\n\n\(text)"
                try content.write(to: fileURL, atomically: true, encoding: .utf8)
            }
        }
    }

    // MARK: - Place notes

    func placeNoteFilename(for placeName: String) -> String {
        placeName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
    }

    func placeNoteExists(for placeName: String) -> Bool {
        guard let url = try? resolvedURL() else { return false }
        guard url.startAccessingSecurityScopedResource() else { return false }
        defer { url.stopAccessingSecurityScopedResource() }
        return FileManager.default.fileExists(
            atPath: placeNoteURL(documentsURL: url, placeName: placeName).path
        )
    }

    private func placeNoteURL(documentsURL: URL, placeName: String) -> URL {
        documentsURL
            .appendingPathComponent("Notes")
            .appendingPathComponent("Places")
            .appendingPathComponent("\(placeNoteFilename(for: placeName)).md")
    }

    /// Creates a place note with a standard template if one doesn't already exist.
    func createPlaceNoteIfNeeded(for placeName: String) throws {
        try withAccess { documentsURL in
            let placesURL = documentsURL.appendingPathComponent("Notes").appendingPathComponent("Places")
            try FileManager.default.createDirectory(at: placesURL, withIntermediateDirectories: true)

            let fileURL = placeNoteURL(documentsURL: documentsURL, placeName: placeName)
            guard !FileManager.default.fileExists(atPath: fileURL.path) else { return }

            let content = """
            # \(placeName)

            ## Notes


            ## Want to Try


            ## Visit History

            """
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    /// Appends text to a place note. Creates the note first if needed.
    func appendToPlaceNote(for placeName: String, text: String) throws {
        try createPlaceNoteIfNeeded(for: placeName)
        try withAccess { documentsURL in
            let fileURL = placeNoteURL(documentsURL: documentsURL, placeName: placeName)
            let handle = try FileHandle(forWritingTo: fileURL)
            handle.seekToEndOfFile()
            handle.write(Data("\n\(text)".utf8))
            handle.closeFile()
        }
    }

    // MARK: - File read / write

    /// Reads a file at a path relative to the NotePlan documents folder.
    /// Returns an empty string if the file does not exist yet.
    func readFile(_ relativePath: String) throws -> String {
        try withAccess { documentsURL in
            let fileURL = documentsURL.appendingPathComponent(relativePath)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return "" }
            return try String(contentsOf: fileURL, encoding: .utf8)
        }
    }

    /// Writes content to a file at a path relative to the NotePlan documents folder.
    /// Creates any intermediate directories automatically.
    func writeFile(_ relativePath: String, content: String) throws {
        try withAccess { documentsURL in
            let fileURL = documentsURL.appendingPathComponent(relativePath)
            let dir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    /// Returns the full content of the daily note for a given date.
    /// Returns an empty string if the note doesn't exist yet.
    func readDailyNote(date: Date = Date()) throws -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let dateStr = formatter.string(from: date)
        return try readFile("Calendar/\(dateStr).md")
    }

    /// Returns the filenames (not full paths) of all `.md` files in a subfolder.
    /// Pass a path relative to the NotePlan documents folder, e.g. "Notes/Places".
    func listFiles(in subfolder: String) throws -> [String] {
        try withAccess { documentsURL in
            let folderURL = documentsURL.appendingPathComponent(subfolder)
            guard FileManager.default.fileExists(atPath: folderURL.path) else { return [] }
            let items = try FileManager.default.contentsOfDirectory(atPath: folderURL.path)
            return items.filter { $0.hasSuffix(".md") }.sorted()
        }
    }

    // MARK: - Open in NotePlan (URL scheme)

    /// Opens today's daily note in NotePlan.
    func openDailyNote(date: Date = Date()) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        if let url = URL(string: "noteplan://x-callback-url/openNote?noteDate=\(formatter.string(from: date))") {
            UIApplication.shared.open(url)
        }
    }

    /// Opens a place note in NotePlan by title.
    func openPlaceNote(for placeName: String) {
        let encoded = placeNoteFilename(for: placeName)
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? placeName
        if let url = URL(string: "noteplan://x-callback-url/openNote?noteTitle=\(encoded)") {
            UIApplication.shared.open(url)
        }
    }
}

// MARK: - Error

enum NotePlanError: LocalizedError {
    case noAccess
    case accessDenied

    var errorDescription: String? {
        switch self {
        case .noAccess:
            return "NotePlan folder not linked. Go to Settings → NotePlan to grant access."
        case .accessDenied:
            return "Could not access NotePlan folder. Try re-linking in Settings → NotePlan."
        }
    }
}

// MARK: - Folder Picker (UIViewControllerRepresentable)

struct NotePlanFolderPicker: UIViewControllerRepresentable {
    var onPick: (URL) -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.folder])
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: NotePlanFolderPicker
        init(_ parent: NotePlanFolderPicker) { self.parent = parent }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            parent.onPick(url)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.onCancel()
        }
    }
}
