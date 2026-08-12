import Foundation
import EventKit
import ImageIO
import UniformTypeIdentifiers
import SwiftUI

// MARK: - NoteStore
//
// Trace's own iCloud Drive note store.
// Files live at: iCloud Drive → Trace → (Calendar / Notes / Photos / Documents)
// No user setup required — iCloud capability in Xcode handles everything.

// MARK: - Claude API key store
//
// **Here because this is the only file every relevant target compiles.**
// Computed from `project.pbxproj` rather than guessed, after getting it wrong
// twice on 2026-08-01:
//
//   Config.swift      Trace, Dayflow, Satchel
//   Models.swift      Trace, Dayflow, Jot, TraceMac
//   AppGroup.swift    Trace, Satchel, SatchelShareExtension
//   NoteStore.swift   Trace, Dayflow, Jot, JotWidget, Satchel, TraceMac  <-- all of them
//
// Putting the store in `Config` broke TraceMac (which has no Config); moving it
// to `Models` broke Satchel (which has no Models). There is no third guess: this
// is the only shared floor. Foundation-only on purpose, so it stays that way —
// the SwiftUI settings section that reads it lives in `Models.swift`.

/// Read/write for the shared Claude key. One place, so no screen invents its own
/// suite name or spelling of the key.
enum ClaudeKeyStore {
    static let suiteName = "group.com.david.trace"
    static let defaultsKey = "claude_api_key"

    static var key: String {
        UserDefaults(suiteName: suiteName)?.string(forKey: defaultsKey) ?? ""
    }

    static var hasKey: Bool { !key.isEmpty }

    static func set(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let defaults = UserDefaults(suiteName: suiteName) else { return }
        if trimmed.isEmpty {
            defaults.removeObject(forKey: defaultsKey)
        } else {
            defaults.set(trimmed, forKey: defaultsKey)
        }
    }

    /// Never show a key in full. Enough to confirm which one is loaded, not
    /// enough to be worth a screenshot.
    static var masked: String {
        let k = key
        guard k.count > 12 else { return k.isEmpty ? "Not set" : "Set" }
        return "\(k.prefix(8))…\(k.suffix(4))"
    }
}

// ── Concurrency, Session 65 ───────────────────────────────────────────────
//
// The project sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so this class
// is on the main actor without saying so. Four places in the apps deliberately
// read notes OFF the main thread — the Mac's day-preview scan and the People
// and Places backlink scans, all `Task.detached` — because one file read per
// row inside a list row builder is how a scroll turns to treacle.
//
// Those cross-actor calls are warnings today and errors the moment the language
// mode moves to 6. **They were not fixable by adding `await`**: that compiles
// and defeats the point, hopping straight back to the main actor and doing a
// main-thread scan with extra steps.
//
// So the read-only file methods below are `nonisolated`, which is what they
// already were in spirit. There is precedent in this very file: `downscaled`
// and `maxDimension` are `nonisolated` for the same reason, and their comments
// say so.
//
// **The one claim being made, stated plainly.** `documentsURL` is `nonisolated`:
// written exactly once, during container resolution at launch, on the main
// thread, and only read afterwards.
//
// **It took three builds and the compiler contradicted itself once**, so the
// reasoning is here rather than in a changelog.
//
//   1. `nonisolated(unsafe)` → *"has no effect on property 'documentsURL',
//      consider using 'nonisolated'."* `@Observable` had rewritten the stored
//      property into a computed one over hidden storage, and `(unsafe)` means
//      nothing on a computed property.
//   2. `nonisolated` → *"cannot be applied to mutable stored properties."*
//      Which is the opposite premise. Both diagnostics are locally correct and
//      together they are unsatisfiable, because the macro is what decides which
//      of the two the property is.
//   3. `@ObservationIgnored` settles it. The property becomes a genuine stored
//      `var` again, which is exactly what `nonisolated(unsafe)` is for.
//
// **`@ObservationIgnored` costs nothing here, and that is checked rather than
// assumed.** Nothing observes this value. It is `private`; the only way out is
// the `containerURL` accessor, and all six call sites read it inside a function
// body — `IOSDocumentStore`, `MarkdownEditorView`, `TraceMacPhotosView`,
// `TraceMacDocumentStore` — never in a `View` body where a re-render would
// depend on it. What views actually watch is `hasAccess`, which stays observed;
// `TraceSatchelHandoff`'s own comment records that pattern and the three bugs
// that taught it.
//
// `shared` went round the same loop for the same reason. *"'nonisolated(unsafe)'
// is unnecessary for a constant with 'Sendable' type 'NoteStore'"* means **drop
// the `(unsafe)`**, not drop the annotation — read as the latter, it came back
// as four *"Main actor-isolated static property 'shared' cannot be accessed
// from outside of the actor"*.
//
// ── The rule the two of them add up to ────────────────────────────────────
//
// Under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, anything a nonisolated
// caller must reach needs one of exactly two spellings, and which one is
// decided by mutability alone:
//
//   • immutable stored `let` of a `Sendable` type  →  `nonisolated`
//   • mutable stored `var`                          →  `nonisolated(unsafe)`,
//     plus `@ObservationIgnored` inside an `@Observable` class
//
// Both were guessed at first and corrected by a build. Written down so the next
// one is not.
//
// The reason this is documentation rather than a new risk: **the detached scans
// have been reading it from a background thread since they were written.**
// Swift 6 is naming a situation that already existed, not creating one. If that
// ever stops being true — if anything reassigns `documentsURL` after launch —
// this annotation becomes a lie and the fix is a real one, not another
// `unsafe`.
@Observable
class NoteStore {
    /// `nonisolated` and not `nonisolated(unsafe)`: an immutable stored `let` of
    /// a `Sendable` type needs no unsafety opt-out to leave the actor. See the
    /// rule in the concurrency note above.
    nonisolated static let shared = NoteStore()

    /// True once the iCloud container URL has been resolved.
    var hasAccess: Bool = false

    /// The Documents subdirectory of Trace's iCloud container.
    /// This is the user-visible root (appears as "Trace" in Files app).
    ///
    /// Written once at launch on the main thread, read forever after, including
    /// from the detached scans. `@ObservationIgnored` is what makes the
    /// `nonisolated(unsafe)` legal AND meaningful — see the numbered sequence in
    /// the concurrency note on the class, and the check that nothing observes
    /// this.
    @ObservationIgnored nonisolated(unsafe) private var documentsURL: URL?

    /// The resolved container path, for display in Settings debug panel.
    var containerPath: String = "resolving…"

    /// Public accessor for the resolved documents root — used by TagIndex for note scanning.
    nonisolated var containerURL: URL? { documentsURL }

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
        // Every `.md` in the container, PLUS anything under `Documents/`.
        //
        // **The second clause is new in Session 69, and its absence was a real
        // gap.** The query matched `*.md` only, so a PNG or PDF arriving in
        // `Documents/<year>/` from another device — or from the Dropzone action
        // that now feeds Satchel — was invisible until something happened to
        // rebuild the view. David: *"i had to leave satchel tab then go back to
        // see the file."* Every other folder that two devices share got a case
        // here; the one holding binaries never did, because binaries are not
        // `.md` and the predicate was written when only notes were shared.
        //
        // The doubled path is not a typo: the container's own folder is
        // `Documents`, and Satchel's documents live in `Documents/` inside it.
        let notes = NSPredicate(format: "%K LIKE '*.md'", NSMetadataItemFSNameKey)
        let documents = NSPredicate(format: "%K CONTAINS[c] %@",
                                    NSMetadataItemPathKey, "/Documents/Documents/")
        query.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: [notes, documents])

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

            // Checked first: a sidecar in `Documents/` is also a `.md`, and
            // falling through to the note cases would announce it as something
            // it is not.
            if path.contains("/Documents/Documents/") {
                NotificationCenter.default.post(
                    name: .noteStoreDocumentsDidChange,
                    object: path
                )
            } else if path.contains("/Calendar/") {
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
            } else if path.contains("/Notes/Endeavors/") {
                // Added Session 64, when TraceMac gained an Endeavors section
                // and the Mac started writing trip logs. Both apps read this
                // folder now, so a write on one device has to be able to reach
                // the other. Same shape as the three cases around it.
                NotificationCenter.default.post(
                    name: .noteStoreEndeavorsDidChange,
                    object: "Notes/Endeavors/\(filename)"
                )
            } else if path.contains("/Notes/Inbox/") {
                NotificationCenter.default.post(
                    name: .noteStoreInboxDidChange,
                    object: "Notes/Inbox/\(filename)"
                )
            }
        }
    }

    // MARK: - Daily notes

    /// Appends a markdown line to the daily note for the given date.
    /// Creates the file with a date header if it doesn't exist yet.

    /// Inserts `text` as a new paragraph in a daily note's PROSE section,
    /// before a trailing "## Related Notes" table if the note has one —
    /// rather than always appending at the true end of file. Added
    /// 2026-07-25 after a real bug David hit: Jot's plain end-of-file
    /// append landed new content below an existing Related Notes table in
    /// the raw file, and Dayflow's own DayflowRelatedNotesEngine.split()
    /// (which treats every line from the "## Related Notes" heading to the
    /// next "## " heading or end-of-file as table rows) silently swallowed
    /// that stray text as unparseable garbage the next time the Daily Note
    /// editor loaded the file — content that looked present in Files/Bear
    /// vanished the moment Dayflow touched the note again. Detection here
    /// is a plain literal-heading match, not a dependency on
    /// DayflowRelatedNotesEngine itself — NoteStore.swift is shared across
    /// every target (Trace/Dayflow/Jot/TraceMac) and a Dayflow-specific
    /// type dependency isn't warranted for what's fundamentally a
    /// plain-text insertion-point decision.
    private static func insertIntoDailyNoteProse(_ existing: String, appending text: String) -> String {
        let heading = "## Related Notes"
        let lines = existing.components(separatedBy: "\n")
        guard let headingIdx = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == heading }) else {
            // No table — original behavior, append at the true end of file.
            return existing.hasSuffix("\n") ? existing + text : existing + "\n" + text
        }
        var before = Array(lines[..<headingIdx])
        // Trim trailing blank lines directly above the heading so the newly
        // inserted paragraph doesn't pile up extra blank lines before the table.
        while let last = before.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            before.removeLast()
        }
        let after = Array(lines[headingIdx...])
        var result = before
        result.append("")
        result.append(text)
        result.append("")
        result.append(contentsOf: after)
        return result.joined(separator: "\n")
    }

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
                    let updated = Self.insertIntoDailyNoteProse(existing, appending: text)
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

    // MARK: - Inbox filing
    //
    // Added 2026-07-24 (Session 44 addendum 10) — David's Dayflow "Inbox"
    // concept: evergreen notes captured on the go (not tied to a specific
    // day) that get reviewed later and filed to wherever they actually
    // belong. `Notes/Inbox/` already existed as a convention before this —
    // Trace's own `QuickAppendSheet.swift` already writes new captures there
    // (one timestamped .md file per note, e.g. "2026-07-24-143022.md"), and
    // `TraceMacInboxView.swift` already browses/edits/deletes them on Mac.
    // What was missing was a way to move a staged note OUT of the inbox into
    // one of its real homes — that's what `fileInboxNote(_:to:)` below adds.

    /// The real homes an inbox note can be filed to. Matches the exact
    /// destinations Trace's `QuickAppendSheet` already offers when
    /// CAPTURING a note (Daily/Project), extended with Person/Place — real
    /// destinations Dayflow already knows about via
    /// `DayflowRelatedNotesEngine`'s candidate lists (`NotionService.shared
    /// .people`/`.places`) that QuickAppendSheet never needed.
    enum InboxFilingDestination {
        case daily(Date)
        case project(String)
        case person(String)
        case place(String)
    }

    /// Files an inbox note's content into `destination`'s note, then deletes
    /// the source file. An inbox note that's empty (or only whitespace) is
    /// just deleted rather than filed anywhere — nothing meaningful to move.
    ///
    /// Project/Person paths are built directly from the entity's name,
    /// unsanitized — this deliberately matches
    /// `DayflowProjectNoteView.swift`'s `Notes/Projects/\(title).md` and
    /// `PersonDetailView.swift`'s `Notes/People/\(personName).md` exactly,
    /// so a filed note lands in the SAME file those screens already read/
    /// write, not a differently-sanitized duplicate next to it. Place uses
    /// `placeNoteFilename(for:)` for the identical reason —
    /// `PlaceDetailView.swift` already sanitizes place filenames that way.
    func fileInboxNote(_ filename: String, to destination: InboxFilingDestination) throws {
        let sourcePath = "Notes/Inbox/\(filename)"
        let content = try readFile(sourcePath)
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try deleteFile(sourcePath)
            return
        }
        switch destination {
        case .daily(let date):
            try appendToDailyNote(trimmed, date: date)
        case .project(let name):
            try appendToNamedNote(relativePath: "Notes/Projects/\(name).md", title: name, text: trimmed)
        case .person(let name):
            try appendToNamedNote(relativePath: "Notes/People/\(name).md", title: name, text: trimmed)
        case .place(let name):
            let path = "Notes/Places/\(placeNoteFilename(for: name)).md"
            try appendToNamedNote(relativePath: path, title: name, text: trimmed)
        }
        try deleteFile(sourcePath)
    }

    /// Shared existing-or-template append for the three named-note filing
    /// cases above. Note this checks whether `existing` is actually
    /// non-empty (not just whether the read succeeded) before deciding to
    /// apply the "# Title" template — `readFile` returns "" rather than
    /// throwing for a file that doesn't exist yet, so a check that only
    /// gated on the read throwing would silently skip the template and
    /// prepend a bare blank line instead (a gap in `QuickAppendSheet.swift`'s
    /// own hand-rolled version of this same pattern for Projects — fixed
    /// here rather than carried forward, since this is the one place all
    /// three entity kinds now share).
    private func appendToNamedNote(relativePath: String, title: String, text: String) throws {
        let existing = (try? readFile(relativePath)) ?? ""
        if existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try writeFile(relativePath, content: "# \(title)\n\n\(text)")
        } else {
            let separator = existing.hasSuffix("\n") ? "\n" : "\n\n"
            try writeFile(relativePath, content: existing + separator + text)
        }
    }

    /// Records a ticked agenda item in the person's own note, under `## Done`.
    ///
    /// David, 2026-08-01: *"clearing an agenda would not delete it right? where do
    /// the items i no longer need for agendas live?"*
    ///
    /// **They lived nowhere, and that was wrong.** Ticking deleted the line from a
    /// 2000-character Notion field and that was the end of it. The argument for
    /// that — the record of having spoken to someone is the interaction log — holds
    /// for the conversation and not for the intention. "I meant to ask about
    /// Megan's new place, and on 1 August I did" is worth keeping and belongs
    /// nowhere near a live queue.
    ///
    /// The person's note is the right home: it already exists for every person, it
    /// is plain markdown he reads in Obsidian, and it does not consume the Notion
    /// field that the live agenda has to fit inside.
    ///
    /// Appended under a heading rather than written to a marked block that gets
    /// rewritten — same rule as the Endeavor trip log. Anything he types under
    /// these lines is his.
    func logCompletedAgendaItem(person: String, text: String, on date: Date = Date()) {
        let name = person.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !body.isEmpty else { return }

        let path = "Notes/People/\(name).md"
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        let line = "- \(fmt.string(from: date)) \(body)"

        let existing = (try? readFile(path)) ?? ""
        if let range = existing.range(of: "## Done") {
            // Under the heading, newest first — not at the end of the file, which
            // may have other sections after this one.
            //
            // The blank line that follows the heading is consumed and re-laid
            // rather than written around. Inserting straight after "## Done"
            // pushed that blank between the new entry and the previous one, and
            // the list came out ragged from the second item onwards.
            let head = String(existing[..<range.upperBound])
            let rest = String(existing[range.upperBound...])
                .drop(while: { $0 == "\n" })
            try? writeFile(path, content: head + "\n\n" + line
                                 + (rest.isEmpty ? "\n" : "\n" + rest))
        } else {
            try? appendToNamedNote(relativePath: path, title: name,
                                   text: "## Done\n\n" + line)
        }
    }

    /// The `## Done` lines from a person's note, newest first, as `(date, text)`.
    ///
    /// Read back rather than kept in a second store, so the note stays the single
    /// record. If David edits or deletes a line in Obsidian, this reflects it —
    /// which is the point of putting the history somewhere he already reads.
    ///
    /// Stops at the next heading. Anything he writes below the section is his and
    /// is not going to be parsed as history.
    func completedAgendaItems(person: String) -> [(date: String, text: String)] {
        let name = person.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              let content = try? readFile("Notes/People/\(name).md"),
              let range = content.range(of: "## Done") else { return [] }

        var out: [(String, String)] = []
        for raw in content[range.upperBound...].components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { break }
            guard line.hasPrefix("- ") else { continue }
            let body = String(line.dropFirst(2))
            if body.count > 11, body.dropFirst(10).first == " ",
               body.prefix(10).allSatisfy({ $0.isNumber || $0 == "-" }) {
                out.append((String(body.prefix(10)),
                            String(body.dropFirst(11)).trimmingCharacters(in: .whitespaces)))
            } else {
                out.append(("", body))
            }
        }
        return out
    }

    /// Creates `Notes/People/<name>.md` as an empty stub when it does not
    /// already exist. Never touches a note that has content.
    ///
    /// **Why a person needs a file the moment they exist.** People live in
    /// Notion; their notes live here. Satchel's "File to a note" picker lists
    /// FILES, so a person with no note is not offerable — David added Bronwyn,
    /// went to file a document to her, and she was simply not in the list, with
    /// nothing on screen to explain why. The picker was speaking in notes while
    /// he was thinking in people.
    ///
    /// Fixed here rather than in the picker on purpose: Satchel does not compile
    /// `NotionService` and must not start. Its locked design is cached-only,
    /// render with no network — "opens instantly on a plane" — so teaching the
    /// picker to read the Notion people list would trade that away for one
    /// dropdown. Guaranteeing the file exists gets the same result and keeps
    /// Satchel offline.
    ///
    /// The path is built from the raw name, unsanitized, to match
    /// `PersonDetailView.swift`'s `Notes/People/\(personName).md` exactly — see
    /// the note on `fileInboxNote` above. A differently-sanitized filename here
    /// would render fine in the picker and match nothing on the reverse lookup,
    /// so the document chip would never appear on the person's page and nothing
    /// would say why.
    func ensurePersonNote(name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let path = "Notes/People/\(trimmed).md"
        let existing = (try? readFile(path)) ?? ""
        guard existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        try writeFile(path, content: "# \(trimmed)\n\n")
    }

    /// Removes a person's note **only if nothing was ever written in it**.
    ///
    /// David, 2026-08-01, seeing two deleted test people still listed in Satchel's
    /// note picker: *"why do I still see test person and test person too when
    /// they've both been deleted?"*
    ///
    /// Because deleting a person archives the Notion page and **deliberately keeps
    /// the note file** — "it may hold years of writing" — and Satchel's picker is a
    /// filesystem scan, not a Notion read. Two correct decisions produced a wrong
    /// result together.
    ///
    /// That promise is right for a real person and absurd for a stub. `Test
    /// person.md` was 15 bytes: `# Test person` and a newline, which is exactly
    /// what `ensurePersonNote` writes and nothing more. Nothing is being protected
    /// by keeping it.
    ///
    /// So the test is deliberately narrow: the file must reduce to its own title
    /// heading and whitespace. **One line of prose under the heading and it stays.**
    /// Returns true when it deleted something, so callers can word themselves
    /// honestly.
    @discardableResult
    func deletePersonNoteIfUntouched(name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let path = "Notes/People/\(trimmed).md"
        guard let existing = try? readFile(path) else { return false }

        let remainder = existing
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .filter { $0 != "# \(trimmed)" }

        guard remainder.isEmpty else { return false }
        do { try deleteFile(path); return true } catch { return false }
    }

    // MARK: - Project archiving
    //
    // David, 2026-08-01: *"in dayflow, how do i archive the projects? right now
    // they just stay there forever."* There was no archive concept at all —
    // projects are files in `Notes/Projects/` and every list of them is a folder
    // scan.
    //
    // **A subfolder, not a flag.** `listFiles` does not recurse, so moving a note
    // into `Notes/Projects/Archive/` removes it from all SIX surfaces that scan
    // that folder — Dayflow's Notes browse and inbox filing sheet, its
    // related-notes engine, Trace's Notes tab, quick append and Move to Project,
    // and Satchel's note picker — without one of them being taught a new rule. A
    // `#archived` tag would have kept the path intact and required editing all six,
    // and the sixth is the one that gets missed.
    //
    // It is also legible outside the app: a folder in Obsidian and in Files.

    static let projectsFolder = "Notes/Projects"
    static let archivedProjectsFolder = "Notes/Projects/Archive"
    /// Daily notes are NOT under `Notes/`. They are a sibling top-level folder in
    /// the same container, one file per day, named `yyyy-MM-dd.md`. The path was
    /// a bare string literal in eleven places in this file alone before D64
    /// needed a second reader of it.
    static let dailyFolder = "Calendar"

    /// Every note a `[[wikilink]]` is allowed to point at.
    ///
    /// **Project notes and Daily notes only** (D49). David: *"link to daily notes
    /// and project notes only available. I cant see myself linking to other
    /// endeavors."* So no Endeavors, no Inbox, no Horizons, and no Person or
    /// Place notes — those two names already resolve to the Notion record, which
    /// is the thing you actually want when you click one.
    ///
    /// `title` is the filename without `.md`, which is what goes inside the
    /// brackets. For a Project note that is its name; for a Daily note it is the
    /// date, so `[[2026-08-16]]` links to that day.
    ///
    /// Two `contentsOfDirectory` calls. Cheap, but not free per keystroke, so
    /// callers should refresh when a wikilink session *opens* rather than on
    /// every character.
    /// Every `[[target]]` named in a body, in order, deduplicated.
    ///
    /// **The forward direction.** `findWikilinkMentions` below answers "which
    /// notes link to this name" by walking the container and regexing every file;
    /// this answers "what does this one body link to" and does not touch disk.
    /// Both are needed and neither can be built from the other cheaply.
    ///
    /// Same pattern the two text storages render with, deliberately: if the
    /// renderer treats `[[A|B]]` as a link to A, so must anything that lists what
    /// a note links to, or the rail and the page disagree about what is there.
    /// A default label for a markdown link to `url`: the host, without `www.`.
    ///
    /// **Not an empty label.** Both text storages render `[label](url)` with the
    /// pattern `\[([^\]]+)\]\(([^)]+)\)` — one or more label characters,
    /// deliberately, so a bare `[]` in prose is not mistaken for a link. So
    /// `[](https://…)` matches nothing and sits on the page as raw markdown,
    /// which is exactly what David saw: *"it doesnt seem to be able to add the
    /// proper mark down."*
    ///
    /// `zola.com` is a real label, renders immediately, and is usually close
    /// enough to keep. Callers select it so typing replaces it.
    nonisolated static func linkLabel(for url: String) -> String {
        guard let host = URL(string: url)?.host, !host.isEmpty else { return "link" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    nonisolated static func wikilinkTargets(in body: String) -> [String] {
        guard body.contains("[["),
              let regex = try? NSRegularExpression(
                  pattern: #"\[\[([^\]|]+)(?:\|[^\]]*)?\]\]"#) else { return [] }
        let ns = body as NSString
        var seen = Set<String>()
        var out: [String] = []
        for m in regex.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
            guard m.numberOfRanges >= 2, m.range(at: 1).location != NSNotFound else { continue }
            let target = ns.substring(with: m.range(at: 1))
                .trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty, seen.insert(target.lowercased()).inserted else { continue }
            out.append(target)
        }
        return out
    }

    func linkableNotes() -> [LinkableNote] {
        let projects = ((try? listFiles(in: Self.projectsFolder)) ?? [])
            .map { LinkableNote(title: String($0.dropLast(3)),
                                relativePath: "\(Self.projectsFolder)/\($0)",
                                isDaily: false) }
        let daily = ((try? listFiles(in: Self.dailyFolder)) ?? [])
            .map { LinkableNote(title: String($0.dropLast(3)),
                                relativePath: "\(Self.dailyFolder)/\($0)",
                                isDaily: true) }
        return projects + daily
    }

    func listArchivedProjects() -> [String] {
        ((try? listFiles(in: Self.archivedProjectsFolder)) ?? [])
            .map { $0.replacingOccurrences(of: ".md", with: "") }
    }

    @discardableResult
    func archiveProject(name: String) -> Bool {
        moveProject(name: name,
                    from: Self.projectsFolder, to: Self.archivedProjectsFolder)
    }

    @discardableResult
    func unarchiveProject(name: String) -> Bool {
        moveProject(name: name,
                    from: Self.archivedProjectsFolder, to: Self.projectsFolder)
    }

    private func moveProject(name: String, from: String, to: String) -> Bool {
        guard let documentsURL else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let src = documentsURL.appendingPathComponent("\(from)/\(trimmed).md")
        let dstFolder = documentsURL.appendingPathComponent(to)
        let dst = dstFolder.appendingPathComponent("\(trimmed).md")
        guard FileManager.default.fileExists(atPath: src.path),
              !FileManager.default.fileExists(atPath: dst.path) else { return false }

        do {
            try FileManager.default.createDirectory(at: dstFolder,
                                                    withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: src, to: dst)
        } catch { return false }

        // THE LINK COST OF MOVING, PAID HERE. Satchel writes `linked_note:` into a
        // document's sidecar as a LITERAL PATH — David's ComEd bill points at
        // `Notes/Projects/Home Bills.md`. A move that did not do this would leave a
        // document pointing at a file that is no longer there, and nothing would
        // report it: the link would simply stop resolving.
        retargetLinkedNotes(from: "\(from)/\(trimmed).md", to: "\(to)/\(trimmed).md")
        return true
    }

    /// Rewrites `linked_note:` in every document sidecar that names `old`.
    ///
    /// Walks `Documents/` rather than a known list because sidecars live in dated
    /// subfolders (`Documents/2026/`, `Documents/Inbox/`, `Documents/Other/`) and
    /// more will appear each year.
    private func retargetLinkedNotes(from old: String, to new: String) {
        guard let documentsURL else { return }
        let root = documentsURL.appendingPathComponent("Documents")
        guard let walker = FileManager.default.enumerator(at: root,
                                                          includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles]) else { return }
        for case let url as URL in walker where url.pathExtension == "md" {
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  text.contains("linked_note: \(old)") else { continue }
            let updated = text.replacingOccurrences(of: "linked_note: \(old)",
                                                    with: "linked_note: \(new)")
            try? updated.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Weekly check-in log

    /// Appends a check-in entry to the current week's Horizons note under a "Check-in Log:" section.
    /// Creates the note with a bullet-list template if it doesn't exist yet.
    /// New days get their own bold sub-header; multiple check-ins on the same day stack beneath it.
    func appendToWeeklyCheckInLog(_ line: String, date: Date = Date()) throws {
        guard let documentsURL else { throw NoteStoreError.iCloudUnavailable }

        // ISO week path: Notes/Horizons/YYYY-Www.md
        var isoCal = Calendar(identifier: .iso8601)
        isoCal.timeZone = TimeZone.current
        let week = isoCal.component(.weekOfYear, from: date)
        let year = isoCal.component(.yearForWeekOfYear, from: date)
        let filename = String(format: "%d-W%02d.md", year, week)
        let relativePath = "Notes/Horizons/\(filename)"

        // Day sub-header: "**Monday (07-06)**"
        let dayFmt = DateFormatter()
        dayFmt.locale = Locale(identifier: "en_US_POSIX")
        dayFmt.timeZone = TimeZone.current
        dayFmt.dateFormat = "EEEE (MM-dd)"
        let dayHeader = "**\(dayFmt.string(from: date))**"

        // Template for new weekly notes
        let weekLabel = String(format: "Week %d — %d", week, year)
        let template = "# \(weekLabel)\n\n• \n• \n• \n• \n• \n• \n\n---\n\nCheck-in Log:\n"

        // Ensure Horizons folder exists
        let horizonsURL = documentsURL.appendingPathComponent("Notes/Horizons")
        try FileManager.default.createDirectory(at: horizonsURL, withIntermediateDirectories: true)

        let fileURL = documentsURL.appendingPathComponent(relativePath)
        var content: String
        if FileManager.default.fileExists(atPath: fileURL.path) {
            content = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? template
        } else {
            content = template
        }

        // Ensure Check-in Log section exists at the bottom
        let logMarker = "Check-in Log:"
        if !content.contains(logMarker) {
            if !content.hasSuffix("\n") { content += "\n" }
            content += "\n---\n\nCheck-in Log:\n"
        }

        // Ensure today's day header exists in the log section
        if let logRange = content.range(of: logMarker) {
            let afterLog = String(content[logRange.upperBound...])
            if !afterLog.contains(dayHeader) {
                if !content.hasSuffix("\n") { content += "\n" }
                content += "\n\(dayHeader)\n"
            }
        }

        // Append the check-in line
        if !content.hasSuffix("\n") { content += "\n" }
        content += "\(line)\n"

        var coordinatorError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(
            writingItemAt: fileURL, options: .forReplacing, error: &coordinatorError
        ) { url in
            do { try content.write(to: url, atomically: true, encoding: .utf8) } catch { writeError = error }
        }
        if let err = coordinatorError ?? writeError { throw err }
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

    /// The folder a newly captured document belongs in: the year, as a string.
    ///
    /// **One function because it was five copies.** `Documents-App-Scope.md`
    /// settled this on 2026-07-28: the old `Documents/<Category>/` folders mixed
    /// types, Endeavors and workflow states in one list, every one of those is
    /// answered better by `type`, `endeavor`, `linked_note`, tags or Kit, and so
    /// the folder became the year. A year costs no decision at capture time,
    /// keeps directory sizes sane, and matches `Photos/<year>/`.
    ///
    /// Only Satchel got the change. Session 69 found four writers still filing
    /// by hand — `TraceMacDocumentStore.importDocument` and
    /// `IOSDocumentStore.importDocument` both hardcoded `"Inbox"`, and
    /// `MarkdownEditorView` wrote `"Scans"` and `"Other"` — which is why David
    /// was still being asked to empty an Inbox that had been designed out weeks
    /// earlier. Five callers meant five chances to disagree; this is the one
    /// place that answers it now.
    static func documentFolder(for date: Date = Date()) -> String {
        String(Calendar.current.component(.year, from: date))
    }

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

    /// `nonisolated`: called from the Mac's detached day-preview scan. Pure
    /// filesystem read, touching only `documentsURL`.
    nonisolated func readFile(_ relativePath: String) throws -> String {
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
        if relativePath.hasPrefix("Notes/Inbox/") {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .noteStoreInboxDidChange, object: relativePath)
            }
        }
        // A general "some note changed" signal, added 2026-07-30.
        //
        // The three notifications above are each about one folder and one consumer.
        // Anything that derives from notes ACROSS folders — the tag counts on
        // Dayflow's notes screen were the first — had nothing to observe, so it
        // only refreshed when its whole screen was rebuilt. David removed a tag
        // from an Endeavor, went back to the notes list, and the filter chip was
        // still there; leaving the screen entirely and returning cleared it.
        //
        // Posted for every write, not filtered by folder: a filter here is a second
        // place to keep in step with whatever the consumers care about, and the
        // editor already debounces its saves so this does not fire per keystroke.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .noteStoreFileDidChange, object: relativePath)
        }
    }

    /// Resolves a relative path (e.g. "Photos/2026/06/photo.jpg") to an absolute file URL.
    /// Returns nil if the iCloud container has not yet been resolved.
    /// `nonisolated`: one line of path arithmetic, and the thumbnail loader
    /// wants it without a hop.
    nonisolated func resolvedURL(for relativePath: String) -> URL? {
        documentsURL?.appendingPathComponent(relativePath)
    }

    func deleteFile(_ relativePath: String) throws {
        guard let documentsURL else { throw NoteStoreError.iCloudUnavailable }
        let fileURL = documentsURL.appendingPathComponent(relativePath)
        try FileManager.default.removeItem(at: fileURL)
        // Added 2026-07-24 alongside fileInboxNote(_:to:) above — writeFile
        // already posts this notification for Notes/Inbox/ writes (new
        // captures), but deletes never did, so a filed-then-deleted inbox
        // note left both TraceMacInboxView and the new DayflowNotesInboxView
        // showing a stale entry until their next unrelated reload. Same
        // "Calendar/" symmetry gap doesn't apply here — nothing currently
        // deletes Calendar/ files outside moveDailyNote/writeFile, which
        // already notify via their own writeFile("Calendar/...", "") calls.
        if relativePath.hasPrefix("Notes/Inbox/") {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .noteStoreInboxDidChange, object: relativePath)
            }
        }
        // A general "some note changed" signal, added 2026-07-30.
        //
        // The three notifications above are each about one folder and one consumer.
        // Anything that derives from notes ACROSS folders — the tag counts on
        // Dayflow's notes screen were the first — had nothing to observe, so it
        // only refreshed when its whole screen was rebuilt. David removed a tag
        // from an Endeavor, went back to the notes list, and the filter chip was
        // still there; leaving the screen entirely and returning cleared it.
        //
        // Posted for every write, not filtered by folder: a filter here is a second
        // place to keep in step with whatever the consumers care about, and the
        // editor already debounces its saves so this does not fire per keystroke.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .noteStoreFileDidChange, object: relativePath)
        }
    }

    func moveFile(from sourcePath: String, to destPath: String) throws {
        let content = try readFile(sourcePath)
        try writeFile(destPath, content: content)
        try deleteFile(sourcePath)
    }

    /// iCloud-safe binary move — works for PDFs, images, and any non-text file.
    /// Uses NSFileCoordinator to coordinate both source (moving) and dest (replacing).
    func moveItem(from sourcePath: String, to destPath: String) throws {
        guard let documentsURL else { throw NoteStoreError.iCloudUnavailable }
        let src = documentsURL.appendingPathComponent(sourcePath)
        let dst = documentsURL.appendingPathComponent(destPath)
        try FileManager.default.createDirectory(
            at: dst.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var coordinatorError: NSError?
        var moveError: Error?
        NSFileCoordinator().coordinate(
            writingItemAt: src, options: .forMoving,
            writingItemAt: dst, options: .forReplacing,
            error: &coordinatorError
        ) { srcURL, dstURL in
            do { try FileManager.default.moveItem(at: srcURL, to: dstURL) }
            catch { moveError = error }
        }
        if let err = coordinatorError ?? moveError { throw err }
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

    /// A file's last-modified date, or nil if it doesn't exist / the vault isn't
    /// linked yet. Same `.contentModificationDateKey` call `findWikilinkMentions`
    /// already makes per-file during its whole-vault scan below — pulled out as
    /// its own helper since DayflowNotesView.swift (Session 22, search result
    /// metadata + sorting) needs it for exactly one file at a time, not a scan.
    func fileModifiedDate(_ relativePath: String) -> Date? {
        guard let documentsURL else { return nil }
        let fileURL = documentsURL.appendingPathComponent(relativePath)
        return (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    // MARK: - Wikilink mentions (content-based backlinks)

    /// Scans all markdown notes in the vault for a `[[Name]]` wikilink that exactly matches
    /// `name` (case-insensitive on the bracket contents — not a substring match, since Trace's
    /// own `[[...]]` autocomplete always inserts the full display name). Excludes `excludePath`
    /// so an entity's own canonical note never appears as "mentioning itself".
    ///
    /// **Aliases count, 2026-08-01.** `[[Bronwyn Kelly|Bronwyn]]` is a mention of Bronwyn
    /// Kelly. This is the ONLY place in either app that matches a wikilink by name rather
    /// than by rendering one, so it is also the only place that could have quietly stopped
    /// counting them the moment the Endeavor trip log started writing the alias form — the
    /// note would still look right, the link would still open, and the person's "Mentioned
    /// In" list would simply have been missing it. Five call sites read this one method
    /// (Dayflow backlinks and wiki summary, TraceMac's two), so the fix belongs here and
    /// nowhere else.
    ///
    /// Synchronous filesystem walk — call off the main thread (e.g. `Task.detached`), same
    /// convention `TagIndex.seedFromNotes` uses for its tag scan.
    /// `nonisolated`: this is the whole reason the People and Places backlink
    /// sections run it on a `Task.detached`. It enumerates the entire container
    /// and reads every `.md` in it, which is exactly the work that must not
    /// happen on the main thread.
    nonisolated func findWikilinkMentions(of name: String, excluding excludePath: String? = nil) -> [NoteMention] {
        guard let documentsURL else { return [] }
        let escaped = NSRegularExpression.escapedPattern(for: name)
        guard let regex = try? NSRegularExpression(pattern: "\\[\\[\(escaped)(?:\\|[^\\]]*)?\\]\\]", options: .caseInsensitive) else {
            return []
        }

        var results: [NoteMention] = []
        guard let enumerator = FileManager.default.enumerator(
            at: documentsURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let rootPath = documentsURL.path
        for case let url as URL in enumerator {
            guard url.pathExtension == "md" else { continue }
            var relativePath = url.path
            if relativePath.hasPrefix(rootPath) {
                relativePath = String(relativePath.dropFirst(rootPath.count))
                if relativePath.hasPrefix("/") { relativePath.removeFirst() }
            }
            if let excludePath, relativePath == excludePath { continue }
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let range = NSRange(content.startIndex..., in: content)
            guard regex.firstMatch(in: content, range: range) != nil else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let title = url.deletingPathExtension().lastPathComponent
            results.append(NoteMention(relativePath: relativePath, title: title, modified: modified))
        }
        return results
    }
}

/// A note whose body contains a `[[Name]]` wikilink pointing at a person or place.
/// Used by the Mac People/Place "Mentioned in" backlink section.
struct NoteMention: Identifiable, Hashable {
    var id: String { relativePath }
    let relativePath: String
    let title: String
    let modified: Date?
}

// MARK: - Notification names

extension Notification.Name {
    /// Posted on the main queue after any Calendar/ file is written.
    /// `object` is the relative path string, e.g. "Calendar/2026-06-26.md".
    static let noteStoreCalendarDidChange = Notification.Name("com.david.trace.noteStoreCalendarDidChange")
    /// Posted after a Notes/Places/ file is written. `object` is the place name string.
    static let noteStorePlaceNoteDidChange = Notification.Name("com.david.trace.noteStorePlaceNoteDidChange")
    static let noteStoreInboxDidChange = Notification.Name("com.david.trace.noteStoreInboxDidChange")
    /// Posted when an Endeavor note changes on **another device**, via the
    /// iCloud metadata query. Not posted by `writeFile` — a store does not need
    /// telling about its own save, and posting on local writes would make every
    /// save round-trip through a reload.
    static let noteStoreEndeavorsDidChange = Notification.Name("com.david.trace.noteStoreEndeavorsDidChange")
    /// Posted after ANY file is written through `writeFile`. `object` is the
    /// relative path. For consumers that derive something from notes across
    /// folders and therefore cannot use the three folder-specific signals above.
    static let noteStoreFileDidChange = Notification.Name("com.david.trace.noteStoreFileDidChange")

    /// A file appeared or changed under `Documents/`, from another device or
    /// another app on this one. Session 69, for the Dropzone hand-off.
    static let noteStoreDocumentsDidChange = Notification.Name("com.david.trace.noteStoreDocumentsDidChange")
}

// MARK: - Error

enum NoteStoreError: LocalizedError {
    case iCloudUnavailable

    var errorDescription: String? {
        "iCloud is not available. Make sure you are signed in to iCloud in Settings."
    }
}

// MARK: - Image downscaling for the vision calls
//
// **This existed and two of the three callers never used it.** `resizeImageData`
// was written carefully inside `IOSDocumentScanService` — ImageIO rather than
// UIKit so it is actor-free, decoding straight to the target size, EXIF transform
// applied — and `OTScanService` and `BilliardsScanService` both sent
// `item.loadTransferable(type: Data.self)` straight to base64 at full resolution.
//
// David, 2026-08-01, scanning an OrangeTheory stats photo: *"The network
// connection was lost."* That is `NSURLErrorNetworkConnectionLost`, the ordinary
// outcome of a multi-megabyte POST dying in flight — a 12MP photo is several MB
// before base64 adds a third again on top.
//
// **It lives in NoteStore.swift because that is the only file EVERY target
// compiles.** It went into `Models.swift` first and Satchel would not build:
// `Cannot find 'ScanImage' in scope`. Satchel compiles `IOSDocumentScanService`
// and does NOT compile `Models.swift`. Read from the project's own exception
// sets rather than assumed:
//
//   Dayflow            Config, Models, NoteStore, TraceDocumentModels
//   Jot                Models, NoteStore
//   JotWidgetExtension NoteStore
//   Satchel            Config, IOSDocumentScanService, NoteStore, TraceDocumentModels
//   TraceMac           BilliardsScanService, Models, NoteStore, OTScanService, …
//
// The intersection is one file. This is the THIRD time that boundary has bitten
// in two days — `ClaudeKeyStore` hit it twice on the way to the same answer.
// ImageIO and UniformTypeIdentifiers are on both platforms, so the floor holds.

enum ScanImage {

    /// What the vision calls send. 1536 on the long edge, matching the document
    /// scanner and close to the point past which the model gains nothing.
    ///
    /// `nonisolated` because `downscaled` is, and it is used as that method's
    /// default argument. Without it: "Main actor-isolated static property
    /// 'maxDimension' can not be referenced from a nonisolated context" — a
    /// warning today and an error under Swift 6.
    nonisolated static let maxDimension: CGFloat = 1536

    /// Downscale via ImageIO.
    ///
    /// `nonisolated` and UIKit-free on purpose: callers run inside `Task.detached`,
    /// and a `UIGraphicsImageRenderer` implementation would be main-actor isolated,
    /// which warns today and fails to compile under Swift 6. ImageIO has no actor
    /// isolation, decodes straight to the target size instead of materialising the
    /// full-resolution bitmap first, and applies the EXIF orientation transform so
    /// portrait photos are not sent to the model sideways.
    ///
    /// Returns the original bytes untouched when the image is already within
    /// bounds, which keeps small PNG screenshots lossless and keeps every caller's
    /// media-type sniffing honest about what is actually being uploaded.
    nonisolated static func downscaled(_ data: Data,
                                       maxDimension: CGFloat = ScanImage.maxDimension) -> Data {
        guard maxDimension > 0,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return data }

        // Already small enough? Hand back the original bytes.
        // Read as Double — CFNumber bridges cleanly to Double, not to CGFloat.
        let limit = Double(maxDimension)
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = props[kCGImagePropertyPixelWidth] as? Double,
           let height = props[kCGImagePropertyPixelHeight] as? Double,
           width <= limit, height <= limit {
            return data
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxDimension)
        ]
        guard let scaled = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return data
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return data }

        CGImageDestinationAddImage(destination, scaled,
                                   [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length > 0 else { return data }
        return output as Data
    }
}

// MARK: - Apple Reminders
//
// David, 2026-08-01: *"can we connect this entire system to IOS reminders? Is
// that an approach with a way to set the reminder?"*
//
// **Most of this already existed.** Trace declares `NSRemindersUsageDescription`,
// and `MarkdownEditorView`'s coordinator has had a working iOS 17 access flow and
// `EKReminder` write since the Tweek send feature (the 🪶 badges). What it did not
// have was a caller outside a text editor.
//
// Lifted here rather than reached into, because it is wanted from three places
// now — a person's agenda item in Trace, an Endeavor in Dayflow, a document in
// Satchel — and `NoteStore.swift` is the only file every target compiles. The
// editor's own copy is left alone: it carries badge state and retry behaviour
// that belong to a markdown line, not to this.
//
// **Trace owns the date; this only sets an alarm.** David chose that explicitly.
// A reminder created here is a copy, not the record — nothing reads back from it,
// and deleting it in Apple's app does not touch the agenda item. Two-way
// completion is a separate, larger piece and is deliberately not pretended at.
//
// Each app that calls this needs its own Reminders usage description. Trace has
// one. **Dayflow and Satchel do not yet** — a call from either would be denied
// silently, or crash on some OS versions, until that string is added.

/// What a "Remind me" button is doing right now.
///
/// **In NoteStore.swift because three apps need it.** It started in
/// `PersonDetailView`, which is Trace-only, and Dayflow's Endeavor sheet
/// referenced it within the hour — the same cross-target boundary that has now
/// caught me four times in two days. `NoteStore.swift` is the only file every
/// target compiles, and Satchel is next.
enum ReminderButtonState: Equatable {
    case idle, working, added, failed(String)
}

enum ReminderService {

    enum Failure: Error { case denied, saveFailed }

    /// The list new reminders land in. **"Trace", David's call, 2026-08-01.**
    ///
    /// **Its own key, not the Tweek one.** These were briefly sharing
    /// `tweek_reminders_list`, which was wrong in a way that would only have shown
    /// up later: the editor's send-to-Tweek exists so a task gets swept into his
    /// weekly planner, and a birthday reminder has no business being swept
    /// anywhere. Two purposes, two lists, two keys — and the Tweek send is left
    /// exactly as it was.
    ///
    /// Read from the App Group so all three apps agree. The editor's own copy
    /// still reads `UserDefaults.standard`, which is fine now that they are not
    /// pretending to be the same setting.
    static let listKey = "trace_reminders_list"

    static var listName: String {
        UserDefaults(suiteName: "group.com.david.trace")?.string(forKey: listKey) ?? "Trace"
    }

    /// The list to write into, creating it the first time.
    ///
    /// **Creating it matters.** `calendars(for:).first { $0.title == … }` returns
    /// nil until the list exists, and the old fallback quietly used the default
    /// list instead — so the first reminder would land somewhere he did not choose,
    /// with nothing on screen to say why, and the list named in the UI would not
    /// exist. Now it is made once and used thereafter.
    ///
    /// Still falls back to the default list if creation fails, because a reminder
    /// in the wrong list beats no reminder at all.
    private static func targetList(_ store: EKEventStore) -> EKCalendar? {
        let lists = store.calendars(for: .reminder)
        if let existing = lists.first(where: { $0.title == listName }) { return existing }

        // A source that can actually hold reminders. The default list's source is
        // the right answer when there is one; otherwise take the first that is
        // modifiable, since a read-only source would fail on save.
        guard let source = store.defaultCalendarForNewReminders()?.source
                ?? lists.first(where: { $0.allowsContentModifications })?.source
        else { return store.defaultCalendarForNewReminders() }

        let made = EKCalendar(for: .reminder, eventStore: store)
        made.title = listName
        made.source = source
        do {
            try store.saveCalendar(made, commit: true)
            return made
        } catch {
            return store.defaultCalendarForNewReminders()
        }
    }

    static func requestAccess(_ store: EKEventStore) async -> Bool {
        if #available(iOS 17.0, macOS 14.0, *) {
            switch EKEventStore.authorizationStatus(for: .reminder) {
            case .fullAccess: return true
            case .notDetermined:
                return (try? await store.requestFullAccessToReminders()) ?? false
            default: return false
            }
        } else {
            switch EKEventStore.authorizationStatus(for: .reminder) {
            case .authorized: return true
            case .notDetermined:
                return await withCheckedContinuation { c in
                    store.requestAccess(to: .reminder) { granted, _ in c.resume(returning: granted) }
                }
            default: return false
            }
        }
    }

    // MARK: Linking a reminder back to the item that made it
    //
    // David: *"then i have to turn that reminder off as well?"* — yes, and he was
    // right to object. Ticking in Trace now completes the reminder in Apple's app.
    //
    // **One direction only, and deliberately.** Trace → Reminders is where the
    // decision is made. The reverse would mean reading his whole reminders list on
    // every launch for the less useful half of the problem.
    //
    // The identifier is kept OUTSIDE the agenda line. Putting it in the text would
    // show up in Notion and in Obsidian, and this is bookkeeping, not content.
    private static let linkKey = "reminder_links"

    private static var links: [String: String] {
        get { UserDefaults(suiteName: "group.com.david.trace")?
                .dictionary(forKey: linkKey) as? [String: String] ?? [:] }
        set { UserDefaults(suiteName: "group.com.david.trace")?
                .set(newValue, forKey: linkKey) }
    }

    /// Whether something already made a reminder for this key. Callers need it to
    /// decide between moving one and making a second.
    static func isLinked(_ key: String) -> Bool { links[key] != nil }

    static func link(_ identifier: String, to key: String) {
        var all = links; all[key] = identifier; links = all
    }

    /// Re-keys when the item text or date changes, so an edit does not orphan the
    /// reminder it already created.
    static func relink(from old: String, to new: String) {
        guard old != new, let id = links[old] else { return }
        var all = links; all[new] = id; all[old] = nil; links = all
    }

    /// Moves a linked reminder's date. Silent when there is no link.
    ///
    /// **This existed as a bug for about an hour.** Editing an agenda item's date
    /// called `relink`, which moved the KEY to the new line and left the reminder
    /// itself pointing at the old day. So changing "chase this on the 14th" to the
    /// 20th produced a reminder that still fired on the 14th, and nothing said so.
    /// A link is not a schedule; both have to move.
    static func reschedule(key: String, to due: Date?) async {
        guard let id = links[key] else { return }
        let store = EKEventStore()
        guard await requestAccess(store) else { return }
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { return }

        reminder.alarms?.forEach { reminder.removeAlarm($0) }
        if let due {
            reminder.dueDateComponents = Calendar.current
                .dateComponents([.year, .month, .day], from: due)
            reminder.addAlarm(EKAlarm(absoluteDate: Calendar.current
                .date(bySettingHour: 9, minute: 0, second: 0, of: due) ?? due))
        } else {
            reminder.dueDateComponents = nil
        }
        try? store.save(reminder, commit: true)
    }

    /// Marks the linked reminder complete and forgets it. Silent when there is no
    /// link, which is the common case — most items never had a reminder.
    static func complete(key: String) async {
        guard let id = links[key] else { return }
        var all = links; all[key] = nil; links = all

        let store = EKEventStore()
        guard await requestAccess(store) else { return }
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { return }
        reminder.isCompleted = true
        try? store.save(reminder, commit: true)
    }

    /// Creates one reminder. `due` sets a dated (not timed) reminder, matching how
    /// an agenda item is dated — a day, not a moment.
    ///
    /// Returns the identifier so the caller can link it to whatever made it.
    @discardableResult
    /// `repeatsYearly` is for dates that are annual by nature. A birthday
    /// reminder without it is a one-shot: it fires once, and next year nothing
    /// happens and nothing explains why. **The date recurs whether or not the
    /// reminder does**, which is exactly the kind of gap that looks like the app
    /// forgetting.
    static func add(title: String, due: Date?, notes: String? = nil,
                    repeatsYearly: Bool = false) async throws -> String {
        let store = EKEventStore()
        guard await requestAccess(store) else { throw Failure.denied }

        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.notes = notes
        reminder.calendar = targetList(store)

        if let due {
            reminder.dueDateComponents = Calendar.current
                .dateComponents([.year, .month, .day], from: due)
            // An alarm as well as a due date. A due date alone files the reminder
            // under a day; it does not speak up, which is the entire point here.
            reminder.addAlarm(EKAlarm(absoluteDate: Calendar.current
                .date(bySettingHour: 9, minute: 0, second: 0, of: due) ?? due))
            if repeatsYearly {
                reminder.addRecurrenceRule(
                    EKRecurrenceRule(recurrenceWith: .yearly, interval: 1, end: nil))
            }
        }

        do { try store.save(reminder, commit: true) } catch { throw Failure.saveFailed }
        return reminder.calendarItemIdentifier
    }
}


/// A note that a `[[wikilink]]` may target. See `NoteStore.linkableNotes()`.
///
/// Deliberately NOT `NoteMention`. That type is the *reverse* index — "which
/// notes link to this name" — and carries a modification date it reads per file
/// during a whole-container walk. This is the forward direction and must be
/// cheap enough to rebuild whenever someone types `[[`.
struct LinkableNote: Identifiable, Hashable {
    let title: String
    let relativePath: String
    let isDaily: Bool
    var id: String { relativePath }
}
