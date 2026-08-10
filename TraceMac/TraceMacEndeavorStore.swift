// TraceMacEndeavorStore.swift
// Reads `Notes/Endeavors/` for the Mac. Mac-only.
//
// Session 64. Deliberately **not** Dayflow's `EndeavorStore`, which is a
// different target and carries covers, deletion, the widget feed and the trip
// log. This one lists files and parses them, and the rule it was written under
// was: the moment it needs to *write*, the question is whether the writing
// should move to `Trace/` rather than whether this one should learn to save.
//
// Session 65 answered that question the way the rule asked. David: *"I also
// have no way to add an endeavor currently in this mac app."* So `create` below
// is four lines, and every one of them is a call into `EndeavorFile` — the id
// form, the default `stamp_captures`, the skeleton, the filename and the
// frontmatter renderer all moved out of Dayflow's store and into the file that
// already owned the parser. **This store still contains no knowledge of what an
// Endeavor note looks like**, which was the property worth protecting; it now
// knows how to ask for one.
//
// What did NOT come with it: covers, deletion, the widget feed, the trip log's
// day-note scan. Those are Dayflow features with Dayflow surfaces, and a store
// that grows them here is the duplicate this split exists to prevent.
//
// The parse is `EndeavorFile.parse` — the shared one in `Trace/Endeavor.swift`.
// That is the whole point of the split: this file contains no knowledge of what
// an Endeavor note looks like, so it cannot drift from the app that writes them.
// Satchel's own store carries the comment that the duplicate it replaced had to
// *"stay in step"* by hand.

import SwiftUI
import Observation

@Observable
final class TraceMacEndeavorStore {

    private(set) var endeavors: [Endeavor] = []
    private(set) var hasLoaded = false

    private let noteStore: NoteStore

    init(noteStore: NoteStore) {
        self.noteStore = noteStore
    }

    func reload() async {
        guard noteStore.hasAccess else { return }
        let files = (try? noteStore.listFiles(in: EndeavorFile.folder)) ?? []
        var parsed: [Endeavor] = []
        for filename in files where filename.hasSuffix(".md") {
            let path = "\(EndeavorFile.folder)/\(filename)"
            guard let raw = try? noteStore.readFile(path) else { continue }
            if let e = EndeavorFile.parse(raw: raw, path: path, filename: filename) {
                parsed.append(e)
            }
        }
        // Running now first, then what is coming, then what is done — the same
        // `sortKey` Dayflow's browse list uses, because it moved with the model
        // and is now the one definition of "the order these read in".
        endeavors = parsed.sorted { $0.sortKey() < $1.sortKey() }
        hasLoaded = true
    }

    // MARK: Create

    /// Writes a new endeavor note and returns it.
    ///
    /// The optimistic append at the end mirrors Dayflow's `save`, and it is
    /// there for the reason recorded in that file rather than by imitation:
    /// `reload` opens with `guard noteStore.hasAccess` and re-lists the folder,
    /// so a momentarily unavailable container, or a file that has not settled by
    /// the time the directory is read, returns without the thing that was just
    /// created. The write has already succeeded at that point, so the model is
    /// known good. Without it, a successful create is indistinguishable from a
    /// failed one: the sheet closes and the list is unchanged. David hit exactly
    /// that on the phone, 2026-07-29.
    @discardableResult
    func create(name: String,
                type: String,
                starts: Date?,
                ends: Date?,
                destination: String? = nil) async throws -> Endeavor {
        let endeavor = EndeavorFile.newEndeavor(
            name: name,
            type: type,
            starts: starts,
            ends: ends,
            destination: destination,
            existingIDs: endeavors.map(\.id)
        )
        try noteStore.writeFile(endeavor.relativePath,
                                content: EndeavorFile.render(endeavor))
        await reload()
        if !endeavors.contains(where: { $0.id == endeavor.id }) {
            endeavors.append(endeavor)
            endeavors.sort { $0.sortKey() < $1.sortKey() }
        }
        return endeavor
    }

    // MARK: Update and delete

    /// Saves an edited Endeavor.
    ///
    /// **The filename is deliberately NOT renamed to follow the name** (D9, and
    /// the same note sits in `DayflowEndeavorViews`). The slug is the identity,
    /// the path is where the bytes are, and moving a file to keep it
    /// cosmetically in step would break `linked_note` on every document filed
    /// against it — which on the Mac now includes everything dropped on the
    /// Satchel rail this session.
    ///
    /// The body is re-read off disk for the same reason `setCover` does it: the
    /// editor beside the sheet saves on a one-second debounce, so the `Endeavor`
    /// the sheet was built from carries a body that is stale by construction.
    @discardableResult
    func update(_ endeavor: Endeavor) async throws -> Endeavor {
        var updated = endeavor
        if let raw = try? noteStore.readFile(endeavor.relativePath) {
            updated.body = EndeavorFile.splitRaw(raw).body
        }
        try noteStore.writeFile(updated.relativePath, content: EndeavorFile.render(updated))
        await reload()
        return updated
    }

    /// Deletes the note.
    ///
    /// **Leaves cover files and documents alone.** The cover is picked up by
    /// `pruneCovers` only when a cover is next set for that slug, which will
    /// never happen now — a known, cheap orphan, and the same trade Dayflow's
    /// `clearCover` makes on the reasoning that an image is cheap and silently
    /// destroying a photograph is not. Documents are Satchel's, and a document
    /// filed against a deleted endeavor is still a document.
    func delete(_ endeavor: Endeavor) async throws {
        try noteStore.deleteFile(endeavor.relativePath)
        endeavors.removeAll { $0.id == endeavor.id }
        await reload()
    }

    /// Clears the cover reference. **Leaves the file**, matching Dayflow: an
    /// image is cheap and a mis-click that silently destroys a photograph is
    /// not. `pruneCovers` sweeps it up the next time a cover is set.
    func clearCover(for endeavor: Endeavor) async throws {
        var updated = endeavors.first { $0.id == endeavor.id } ?? endeavor
        if let raw = try? noteStore.readFile(updated.relativePath) {
            updated.body = EndeavorFile.splitRaw(raw).body
        }
        updated.cover = nil
        updated.coverCredit = nil
        try noteStore.writeFile(updated.relativePath, content: EndeavorFile.render(updated))
        await reload()
    }

    // MARK: Cover

    /// Stores a cover image and points the Endeavor at it.
    ///
    /// **Copied into the container, referenced by path, never a URL** (D8). A
    /// trip note whose cover is a remote link goes blank on a plane, which is
    /// exactly the moment it is most likely to be open. It is also why the
    /// picker is Wikimedia Commons rather than Unsplash: Unsplash's own API
    /// terms require hotlinking, which D8 forbids.
    ///
    /// Every rule about what a stored cover is called and how a stale one is
    /// recognised lives in `EndeavorFile`, so this and Dayflow cannot disagree
    /// about which files are safe to delete.
    ///
    /// **Re-reads before writing**, like Dayflow's. The caller holds a snapshot
    /// taken when its sheet was built, and saving that back would undo anything
    /// changed since — including a body the editor saved while the picker was
    /// open, which on the Mac is a live possibility rather than a theoretical
    /// one.
    @discardableResult
    func setCover(_ imageData: Data, credit: String?, for endeavor: Endeavor) async throws -> Endeavor {
        let base = endeavors.first { $0.id == endeavor.id } ?? endeavor
        let data = EndeavorFile.downscaledJPEG(imageData) ?? imageData
        let filename = EndeavorFile.coverFilename(slug: base.id)
        let path = try noteStore.writePhoto(data, category: "Endeavors", filename: filename)

        var updated = base
        // The body is re-read off disk rather than carried from `base`, which
        // was parsed whenever the list last reloaded. The editor beside this
        // saves on a one-second debounce, so a snapshot taken when the picker
        // opened is stale by construction.
        if let raw = try? noteStore.readFile(base.relativePath) {
            updated.body = EndeavorFile.splitRaw(raw).body
        }
        updated.cover = path
        // Overwritten every time, including to nil — a credit left over from a
        // previous cover is worse than none, because it names the wrong
        // photographer.
        let trimmed = credit?.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.coverCredit = (trimmed?.isEmpty ?? true) ? nil : trimmed
        // Reset for the same reason the credit is: a framing chosen for the old
        // photograph means nothing on the new one, and inheriting it would open
        // the band on an arbitrary slice of a picture just chosen.
        updated.coverOffset = 0.5

        try noteStore.writeFile(updated.relativePath, content: EndeavorFile.render(updated))
        // AFTER the save, never before. A delete that went first would leave the
        // note pointing at a file that no longer exists if the save then failed.
        pruneCovers(for: base.id, keeping: filename)
        await reload()
        return updated
    }

    /// Removes this Endeavor's earlier cover files, keeping the current one.
    ///
    /// `listDocumentFiles`, **not** `listFiles` — the latter filters to `.md`
    /// only, so it would find no covers at all and this would silently do
    /// nothing. The name says "for Documents/ subfolders"; it takes any path.
    private func pruneCovers(for slug: String, keeping current: String) {
        let files = (try? noteStore.listDocumentFiles(in: EndeavorFile.photoFolder)) ?? []
        for file in files where file != current {
            guard EndeavorFile.isCoverFile(file, slug: slug) else { continue }
            try? noteStore.deleteFile("\(EndeavorFile.photoFolder)/\(file)")
        }
    }
}
