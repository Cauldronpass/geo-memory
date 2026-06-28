import Foundation
import SwiftUI

// MARK: - NoteStore
//
// Trace's own iCloud Drive note store.
// Files live at: iCloud Drive → Trace → (Calendar / Notes / Photos / Documents)
// No user setup required — iCloud capability in Xcode handles everything.

@Observable
class NoteStore {
    static let shared = NoteStore()

    /// True once the iCloud container URL has been resolved.
    var hasAccess: Bool = false

    /// The Documents subdirectory of Trace's iCloud container.
    /// This is the user-visible root (appears as "Trace" in Files app).
    private var documentsURL: URL?

    /// The resolved container path, for display in Settings debug panel.
    var containerPath: String = "resolving…"

    init() {
        // url(forUbiquityContainerIdentifier:) is a blocking call — must run on a GCD thread,
        // NOT inside Swift's cooperative thread pool (Task.detached), which causes thread starvation.
        DispatchQueue.global(qos: .userInitiated).async {
            let containerID = "iCloud.com.david.Trace"
            let container = FileManager.default.url(forUbiquityContainerIdentifier: containerID)
            let url = container?.appendingPathComponent("Documents")
            // Create the Documents directory immediately so it appears in Files app.
            if let url {
                try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            }
            let path = url?.path ?? "nil — iCloud container not found"
            DispatchQueue.main.async {
                self.documentsURL = url
                self.hasAccess = url != nil
                self.containerPath = path
            }
        }
    }

    // MARK: - Daily notes

    /// Appends a markdown line to the daily note for the given date.
    /// Creates the file with a date header if it doesn't exist yet.
    func appendToDailyNote(_ text: String, date: Date = Date()) throws {
        guard let documentsURL else { throw NoteStoreError.iCloudUnavailable }

        let calURL = documentsURL.appendingPathComponent("Calendar")
        try FileManager.default.createDirectory(at: calURL, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        let dateStr = formatter.string(from: date)
        let fileURL = calURL.appendingPathComponent("\(dateStr).md")

        var coordinatorError: NSError?
        var writeError: Error?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: fileURL, options: .forReplacing, error: &coordinatorError) { url in
            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                    let updated = existing.hasSuffix("\n") ? existing + text : existing + "\n" + text
                    try updated.write(to: url, atomically: true, encoding: .utf8)
                } else {
                    let content = "# \(dateStr)\n\n\(text)"
                    try content.write(to: url, atomically: true, encoding: .utf8)
                }
            } catch {
                writeError = error
            }
        }
        if let err = coordinatorError ?? writeError { throw err }
        // Notify observers so DailyNoteTab can reload without user having to tap the date.
        let notePath = "Calendar/\(dateStr).md"
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .noteStoreCalendarDidChange, object: notePath)
        }
    }

    /// Moves a daily note's content to another date, merging if destination already has content.
    /// The source date header (# YYYY-MM-DD) is stripped and replaced with a bold timestamp
    /// so the moved block reads naturally in the destination without an embedded title.
    func moveDailyNote(from sourceDate: Date, to destDate: Date) throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        var sourceContent = try readDailyNote(date: sourceDate)
        guard !sourceContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        // Strip the date header so it doesn't embed a duplicate title in the destination.
        var sourceLines = sourceContent.components(separatedBy: "\n")
        if let first = sourceLines.first,
           first.hasPrefix("# "),
           first.dropFirst(2).range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
            sourceLines.removeFirst()
            while sourceLines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
                sourceLines.removeFirst()
            }
        }
        // Prepend a bold timestamp so the block is identifiable in the destination.
        let timeFmt = DateFormatter()
        timeFmt.locale = Locale(identifier: "en_US_POSIX")
        timeFmt.timeZone = TimeZone.current
        timeFmt.dateFormat = "h:mm a"
        let timeStr = timeFmt.string(from: Date())
        sourceLines.insert("**\(timeStr)**", at: 0)
        sourceContent = sourceLines.joined(separator: "\n")

        let destContent = (try? readDailyNote(date: destDate)) ?? ""
        let merged = destContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? sourceContent
            : destContent + "\n\n" + sourceContent
        try writeFile("Calendar/\(formatter.string(from: destDate)).md", content: merged)
        try writeFile("Calendar/\(formatter.string(from: sourceDate)).md", content: "")
    }

    /// Returns the full content of the daily note for a given date.
    func readDailyNote(date: Date = Date()) throws -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return try readFile("Calendar/\(formatter.string(from: date)).md")
    }

    // MARK: - Place notes

    func placeNoteFilename(for placeName: String) -> String {
        placeName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
    }

    func placeNoteExists(for placeName: String) -> Bool {
        guard let documentsURL else { return false }
        return FileManager.default.fileExists(
            atPath: placeNoteURL(documentsURL: documentsURL, placeName: placeName).path
        )
    }

    private func placeNoteURL(documentsURL: URL, placeName: String) -> URL {
        documentsURL
            .appendingPathComponent("Notes")
            .appendingPathComponent("Places")
            .appendingPathComponent("\(placeNoteFilename(for: placeName)).md")
    }

    func createPlaceNoteIfNeeded(for placeName: String) throws {
        guard let documentsURL else { throw NoteStoreError.iCloudUnavailable }
        let fileURL = placeNoteURL(documentsURL: documentsURL, placeName: placeName)
        guard !FileManager.default.fileExists(atPath: fileURL.path) else { return }
        // Minimal template — no empty section scaffolding.
        // Heading rendered in-place via MarkdownTextStorage styleHeading().
        let content = "# \(placeName)\n\n"
        try writeFile("Notes/Places/\(placeNoteFilename(for: placeName)).md", content: content)
    }

    func appendToPlaceNote(for placeName: String, text: String) throws {
        try createPlaceNoteIfNeeded(for: placeName)
        let relativePath = "Notes/Places/\(placeNoteFilename(for: placeName)).md"
        let existing = (try? readFile(relativePath)) ?? ""
        let updated = existing.hasSuffix("\n") ? existing + text : existing + "\n" + text
        try writeFile(relativePath, content: updated)
        NotificationCenter.default.post(name: .noteStorePlaceNoteDidChange, object: placeName)
    }

    // MARK: - Photos
    // Stored at: iCloud Drive → Trace → Photos → <category> → <filename>
    // e.g. Photos/Visits/2026-06-25-arlington-lanes.jpg

    /// Writes photo data and returns the relative path within the store.
    @discardableResult
    func writePhoto(_ data: Data, category: String, filename: String) throws -> String {
        let relativePath = "Photos/\(category)/\(filename)"
        guard let documentsURL else { throw NoteStoreError.iCloudUnavailable }
        let fileURL = documentsURL.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var coordinatorError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(
            writingItemAt: fileURL, options: .forReplacing, error: &coordinatorError
        ) { url in
            do { try data.write(to: url) } catch { writeError = error }
        }
        if let err = coordinatorError ?? writeError { throw err }
        return relativePath
    }

    // MARK: - Documents
    // Stored at: iCloud Drive → Trace → Documents → <category> → <filename>

    /// Writes document data and returns the relative path within the store.
    @discardableResult
    func writeDocument(_ data: Data, category: String, filename: String) throws -> String {
        let relativePath = "Documents/\(category)/\(filename)"
        guard let documentsURL else { throw NoteStoreError.iCloudUnavailable }
        let fileURL = documentsURL.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var coordinatorError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(
            writingItemAt: fileURL, options: .forReplacing, error: &coordinatorError
        ) { url in
            do { try data.write(to: url) } catch { writeError = error }
        }
        if let err = coordinatorError ?? writeError { throw err }
        return relativePath
    }

    // MARK: - Generic file read / write

    func readFile(_ relativePath: String) throws -> String {
        guard let documentsURL else { throw NoteStoreError.iCloudUnavailable }
        let fileURL = documentsURL.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return "" }
        return try String(contentsOf: fileURL, encoding: .utf8)
    }

    func writeFile(_ relativePath: String, content: String) throws {
        guard let documentsURL else { throw NoteStoreError.iCloudUnavailable }
        let fileURL = documentsURL.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var coordinatorError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(
            writingItemAt: fileURL, options: .forReplacing, error: &coordinatorError
        ) { url in
            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                writeError = error
            }
        }
        if let err = coordinatorError ?? writeError { throw err }
        // Notify DailyNoteTab to reload when a Calendar file changes (covers moveDailyNote, save, clear).
        if relativePath.hasPrefix("Calendar/") {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .noteStoreCalendarDidChange, object: relativePath)
            }
        }
    }

    /// Resolves a relative path (e.g. "Photos/2026/06/photo.jpg") to an absolute file URL.
    /// Returns nil if the iCloud container has not yet been resolved.
    func resolvedURL(for relativePath: String) -> URL? {
        documentsURL?.appendingPathComponent(relativePath)
    }

    func deleteFile(_ relativePath: String) throws {
        guard let documentsURL else { throw NoteStoreError.iCloudUnavailable }
        let fileURL = documentsURL.appendingPathComponent(relativePath)
        try FileManager.default.removeItem(at: fileURL)
    }

    func moveFile(from sourcePath: String, to destPath: String) throws {
        let content = try readFile(sourcePath)
        try writeFile(destPath, content: content)
        try deleteFile(sourcePath)
    }

    func listFiles(in subfolder: String) throws -> [String] {
        guard let documentsURL else { throw NoteStoreError.iCloudUnavailable }
        let folderURL = documentsURL.appendingPathComponent(subfolder)
        guard FileManager.default.fileExists(atPath: folderURL.path) else { return [] }
        let items = try FileManager.default.contentsOfDirectory(atPath: folderURL.path)
        return items.filter { $0.hasSuffix(".md") }.sorted()
    }
}

// MARK: - Notification names

extension Notification.Name {
    /// Posted on the main queue after any Calendar/ file is written.
    /// `object` is the relative path string, e.g. "Calendar/2026-06-26.md".
    static let noteStoreCalendarDidChange = Notification.Name("com.david.trace.noteStoreCalendarDidChange")
    /// Posted after a Notes/Places/ file is written. `object` is the place name string.
    static let noteStorePlaceNoteDidChange = Notification.Name("com.david.trace.noteStorePlaceNoteDidChange")
}

// MARK: - Error

enum NoteStoreError: LocalizedError {
    case iCloudUnavailable

    var errorDescription: String? {
        "iCloud is not available. Make sure you are signed in to iCloud in Settings."
    }
}
