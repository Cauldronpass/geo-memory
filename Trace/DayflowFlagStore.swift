import SwiftUI

// MARK: - DayflowFlagStore
//
// Generic "flagged / pinned" index — added 2026-07-22 (Session 37), built for
// Project Notes' pin/sort first (David's original ask) but deliberately
// path-keyed and note-kind-agnostic so the exact same mechanism covers Daily
// Notes (or anything else) later without a redesign — David asked directly
// for this to be transferable, not Project-Notes-only.
//
// **Storage decision, walked through with David before building.** Note
// files themselves have no frontmatter anywhere in this vault (just a plain
// "# Title" header + body), and that file format is shared with Trace's own
// Notes tab — baking a "pinned" marker into the file content risked Trace's
// editor showing it as literal text, or clobbering it on its own next save.
// So flag state lives entirely separately, in one small JSON file
// (`Dayflow-Flags.json`, vault root) written through the same `NoteStore`
// backend every other Dayflow file already goes through — same sync, same
// iCloud container, zero risk to how any note's own content reads elsewhere.
//
// **Moved from `Dayflow/` to `Trace/` in Session 69 (2026-08-10), and it is
// now a member of the TraceMac target as well.** Queue item 19 asked for the
// Mac to pin a project note the way the phone does, and the queue note said
// to find out where the pin lives before building anything: if it were
// `UserDefaults`, the Mac would need its own store and the two would disagree.
// It is not. It is a file in the shared iCloud container, keyed on the same
// vault-relative path (`Notes/Projects/<Name>.md`) that the Mac's project
// list already builds — so both apps read and write one index and there is
// no second copy of the format to keep in step. See D78.
//
// The type keeps its `Dayflow` name deliberately. Renaming it touches fifteen
// call sites across six files with no compiler in this session, on the same
// day as a feature, and buys nothing a comment cannot say. Logged as a
// follow-up, not done here.
//
// **The `NoteStore.shared` read below is correct on both platforms, checked
// rather than assumed (D77).** `TraceMacApp.swift:9` is
// `@State private var noteStore = NoteStore.shared` — the Mac injects the
// singleton itself, so `.shared` here is the same instance the app populates,
// not the empty second instance D77 was written about.
//
// Not independently verified in Xcode/Simulator — same standing limitation
// as every other Dayflow session.

@Observable
final class DayflowFlagStore {
    static let shared = DayflowFlagStore()

    /// Vault-relative path → when it was flagged. Exposed as a dictionary
    /// (not just a Set) so a future "recently flagged" sort has real data to
    /// work with, even though today's only consumer (Project Notes'
    /// flagged-first ordering) just needs membership.
    private(set) var flaggedAt: [String: Date] = [:]

    private static let storePath = "Dayflow-Flags.json"

    private struct FlagEntry: Codable {
        let path: String
        let flaggedAt: Date
    }

    private init() {
        load()
    }

    func isFlagged(_ path: String) -> Bool {
        flaggedAt[path] != nil
    }

    func toggleFlag(_ path: String) {
        if flaggedAt[path] != nil {
            flaggedAt.removeValue(forKey: path)
        } else {
            flaggedAt[path] = Date()
        }
        save()
    }

    /// Drops a flag without needing to know whether one was set.
    ///
    /// `toggleFlag` is wrong for deletion: on an unpinned note it would *set*
    /// a flag for a path that no longer exists.
    func clearFlag(_ path: String) {
        guard flaggedAt[path] != nil else { return }
        flaggedAt.removeValue(forKey: path)
        save()
    }

    /// Carries a flag across a rename, keeping its original date.
    ///
    /// **Added Session 69 because the Mac is the first surface that can rename
    /// a project note.** The index is keyed on the vault-relative path, so a
    /// rename silently breaks the key: the pin stays in the JSON pointing at a
    /// file that is gone, and the note David pinned comes back unpinned. Keeping
    /// the original `Date` rather than stamping a new one matters for the same
    /// reason this is a dictionary and not a Set — a rename is not a re-pin, and
    /// a future "recently flagged" sort would be wrong if it were recorded as one.
    func moveFlag(from oldPath: String, to newPath: String) {
        guard let when = flaggedAt[oldPath] else { return }
        flaggedAt.removeValue(forKey: oldPath)
        flaggedAt[newPath] = when
        save()
    }

    /// Re-reads `Dayflow-Flags.json` from disk.
    ///
    /// **Added Session 69, and the feature does not work without it.** This is
    /// a singleton that loaded once, at first touch. Within one app that is
    /// fine: every mutation goes through `toggleFlag`, so memory and disk
    /// agree. Across two apps it is not — and item 19's motivating case is
    /// exactly the cross-device one. David pinned a note on the phone and it
    /// did not stand out on the Mac; if the Mac answered from a dictionary it
    /// filled at launch, the pin would still not show until it was relaunched,
    /// which is the same complaint wearing a different hat.
    ///
    /// Callers invoke this when a list that reads flags appears. A missing or
    /// unparseable file leaves the current state alone rather than clearing
    /// it: `readFile` returns "" for a file that is not there, and an empty
    /// string is what an iCloud item that has not downloaded yet also looks
    /// like. Wiping pins on that reading would be a data loss caused by a
    /// sync delay.
    func reload() {
        load()
    }

    // MARK: Persistence

    private func load() {
        guard let raw = try? NoteStore.shared.readFile(Self.storePath),
              let data = raw.data(using: .utf8),
              let entries = try? JSONDecoder().decode([FlagEntry].self, from: data)
        else { return }
        flaggedAt = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0.flaggedAt) })
    }

    private func save() {
        let entries = flaggedAt.map { FlagEntry(path: $0.key, flaggedAt: $0.value) }
        guard let data = try? JSONEncoder().encode(entries),
              let json = String(data: data, encoding: .utf8)
        else { return }
        try? NoteStore.shared.writeFile(Self.storePath, content: json)
    }
}
