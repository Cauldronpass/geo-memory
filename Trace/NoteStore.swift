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

    /// Public accessor for the resolved documents root — used by TagIndex for note scanning.
    var containerURL: URL? { documentsURL }

    /// True when running in Simulator (iCloud unavailable) — uses app Documents folder instead.
    private(set) var isLocalMode: Bool = false

    /// Watches the iCloud container for externally-delivered file changes (e.g. from Mac app).
    private var metadataQuery: NSMetadataQuery?
    private var metadataObserver: Any?

    init() {
#if targetEnvironment(simulator)
        // Simulator never has iCloud — skip the blocking container lookup entirely
        // and go straight to local mode so the UI is ready immediately on launch.
        activateLocalMode()
#else
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

            if let url {
                // iCloud available — normal path
                DispatchQueue.main.async {
                    self.documentsURL = url
                    self.hasAccess = true
                    self.isLocalMode = false
                    self.containerPath = url.path
                    self.startObservingICloudChanges()
                }
            } else {
                // iCloud unavailable — fall back to local Documents directory.
                DispatchQueue.main.async { self.activateLocalMode() }
            }
        }
#endif
    }

    private func activateLocalMode() {
        let localRoot = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TraceNotes")
        try? FileManager.default.createDirectory(at: localRoot, withIntermediateDirectories: true)
        documentsURL = localRoot
        hasAccess = true
        isLocalMode = true
        containerPath = localRoot.path + " (LOCAL — no iCloud)"
        seedLocalContent(at: localRoot)
    }

    // MARK: - Simulator test content
    // Seeds a sample daily note + a scratch note in the local store so there's something
    // to tap and edit in the Simulator without needing TestFlight or iCloud.
    // Safe to call repeatedly — skips files that already exist.

    private func seedLocalContent(at root: URL) {
        let calDir = root.appendingPathComponent("Calendar")
        try? FileManager.default.createDirectory(at: calDir, withIntermediateDirectories: true)

        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        let today = fmt.string(from: Date())
        let dailyFile = calDir.appendingPathComponent("\(today).md")

        // Always overwrite during development so seed changes take effect on next launch.
        // Switch to the fileExists guard once the content is stable.

        let sample = """
        # \(today)

        **Morning note** — seeded test note for Simulator.

        ## Heading 2

        ### Heading 3

        ---

        Plain paragraph. **Bold** and *italic* and ==highlighted==.

        ---

        • Bullet item one
        • Bullet item two
        • Bullet item three

        ---

        - [ ] Unchecked task — tap the circle to check
        - [x] Already done — strike-through rendered
        - [ ] Another task to send to Things

        ---

        Notes:
        • Type --- on its own line, then Return → horizontal rule
        • Tap → toolbar button to indent a bullet, then Return continues at that indent
        • Tap ☐ toolbar button to insert a checkbox
        """
        try? sample.write(to: dailyFile, atomically: true, encoding: .utf8)
    }

    // MARK: - iCloud change observation
    //
    // NSMetadataQuery watches the ubiquitous Documents scope and fires when iCloud
    // delivers a file written by another device (e.g. the Mac app). We translate
    // those events into the same NotificationCenter posts the views already observe,
    // so no view-layer changes are needed.

    private func startObservingICloudChanges() {
        let query = NSMetadataQuery()
        query.notificationBatchingInterval = 1.0
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        // Watch all .md files in the container
        query.predicate = NSPredicate(format: "%K LIKE '*.md'", NSMetadataItemFSNameKey)

        metadataObserver = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidUpdate,
            object: query,
            queue: .main
        ) { [weak self] notification in
            self?.handleMetadataUpdate(notification)
        }

        metadataQuery = query
        query.start()
    }

    private func handleMetadataUpdate(_ notification: Notification) {
        guard let query = notification.object as? NSMetadataQuery else { return }
        query.disableUpdates()
        defer { query.enableUpdates() }

        let changed = (notification.userInfo?[NSMetadataQueryUpdateChangedItemsKey] as? [NSMetadataItem]) ?? []
        let added   = (notification.userInfo?[NSMetadataQueryUpdateAddedItemsKey]   as? [NSMetadataItem]) ?? []

        for item in changed + added {
            guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
            let filename = (path as NSString).lastPathComponent

            if path.contains("/Calendar/") {
                NotificationCenter.default.post(
                    name: .noteStoreCalendarDidChange,
                    object: "Calendar/\(filename)"
                )
            } else if path.contains("/Notes/Places/") {
                let placeName = filename.replacingOccurrences(of: ".md", with: "")
                NotificationCenter.default.post(
                    name: .noteStorePlaceNoteDidChange,
                    object: placeName
                )
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

    /// Like listFiles but returns all files regardless of extension (for Documents/ subfolders).
    func listDocumentFiles(in subfolder: String) throws -> [String] {
        guard let documentsURL else { throw NoteStoreError.iCloudUnavailable }
        let folderURL = documentsURL.appendingPathComponent(subfolder)
        guard FileManager.default.fileExists(atPath: folderURL.path) else { return [] }
        let items = try FileManager.default.contentsOfDirectory(atPath: folderURL.path)
        return items.filter { !$0.hasPrefix(".") }.sorted(by: >)  // newest first
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
