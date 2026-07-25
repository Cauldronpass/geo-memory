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
