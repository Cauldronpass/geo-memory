import Foundation
import Observation

// MARK: - Endeavor
//
// The four-field identity contract from `Documents-App-Scope.md` §3, LOCKED
// 2026-07-27. Endeavor's full schema and its Notion database are a separate
// design pass; these four are the only fields Satchel depends on, and they are
// frozen so Satchel could be built before that pass happens.
//
// | id        | Notion page ID. Authoritative.     |
// | name      | Display name, e.g. "Japan 2026".   |
// | type      | "Travel" or "Project" today.       |
// | dateRange | Start and end, both optional.      |
//
// Do not change these four without checking what breaks in Satchel.

struct Endeavor: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let type: String
    let start: Date?
    let end: Date?

    var isTravel: Bool { type.caseInsensitiveCompare("Travel") == .orderedSame }

    /// True when `date` falls inside a Travel Endeavor's range. This is the
    /// entire basis of auto Kit membership (scope §5), which is why it depends
    /// on nothing but the contract fields — no extra state, nothing to clean up
    /// when a trip ends.
    func isActive(on date: Date) -> Bool {
        guard isTravel else { return false }
        let day = Calendar.current.startOfDay(for: date)
        if let start, day < Calendar.current.startOfDay(for: start) { return false }
        if let end, day > Calendar.current.startOfDay(for: end) { return false }
        // A Travel Endeavor with no dates at all is never "active" — otherwise
        // every undated trip would permanently occupy half the Kit grid.
        return start != nil || end != nil
    }
}

// MARK: - Endeavor store (stubbed)

/// Scope §3, "Endeavor picker behaviour before the database exists": the filing
/// UI ships with the picker **present but returning an empty list**, backed by
/// this stub. When the Notion database exists, `reload()` becomes a real query
/// and every screen fills in with no redesign.
///
/// Everything downstream is written to degrade correctly against an empty list:
/// Kit falls back to four manual pins, the Endeavor browse chip reads zero, and
/// the Endeavor screen is simply unreachable. Nothing renders broken.
@Observable
final class SatchelEndeavorStore {

    private(set) var endeavors: [Endeavor] = []
    private(set) var hasLoaded: Bool = false

    /// STUB — build step 11 replaces this with a `NotionService` query against
    /// the Endeavor database. On device it deliberately returns an empty list
    /// rather than fixture data, so nothing downstream is accidentally built to
    /// depend on values that will not exist on first run.
    ///
    /// In the Simulator it returns the seed's Endeavors instead, which is the
    /// only way to see auto-trip Kit membership before that database exists.
    /// The `#if` means device builds cannot accidentally ship fixture data.
    func reload() async {
#if targetEnvironment(simulator)
        endeavors = SatchelSimulatorSeed.endeavors
#else
        endeavors = []
#endif
        hasLoaded = true
    }

    func endeavor(id: String?) -> Endeavor? {
        guard let id else { return nil }
        return endeavors.first { $0.id == id }
    }

    /// The single Travel Endeavor covering today, if any. If trips ever overlap,
    /// the one ending soonest wins — it is the one about to stop being relevant.
    func activeTrip(on date: Date = Date()) -> Endeavor? {
        endeavors
            .filter { $0.isActive(on: date) }
            .sorted { ($0.end ?? .distantFuture) < ($1.end ?? .distantFuture) }
            .first
    }
}


// MARK: - Kit preferences

/// How many of the four Library grid slots the active trip gets.
///
/// Scope §5 locks the grid at four tiles and defaults the split to 2 pins + 2
/// trip documents, with the stated reason that four manual pins must not be
/// able to crowd the boarding pass out on the day it matters. David asked for
/// the split itself to be adjustable (2026-07-27), so the default stands and
/// the number is now his to move per trip.
///
/// Stored in `UserDefaults`, keyed by Endeavor ID, because it is a **display
/// preference about a trip**, not document data. Nothing here belongs in a
/// sidecar (it describes no single document) and nothing here belongs in Notion
/// (scope §D4). Consequence: it does not follow you to another device. Fine for
/// an iOS-only v1; revisit if Satchel ever ships on the Mac.
enum SatchelKitPreferences {

    static let defaultTripSlots = 2
    static let range = 0...4

    private static func key(for endeavorID: String) -> String {
        "satchel.kit.tripSlots.\(endeavorID)"
    }

    static func tripSlots(for endeavorID: String?) -> Int {
        guard let endeavorID else { return defaultTripSlots }
        let stored = UserDefaults.standard.object(forKey: key(for: endeavorID)) as? Int
        return stored.map { min(max($0, range.lowerBound), range.upperBound) } ?? defaultTripSlots
    }

    static func setTripSlots(_ value: Int, for endeavorID: String) {
        UserDefaults.standard.set(min(max(value, range.lowerBound), range.upperBound),
                                  forKey: key(for: endeavorID))
    }
}

// MARK: - Kit

/// One member of Kit, and how it got there.
struct KitEntry: Identifiable, Hashable {
    enum Kind: Hashable {
        /// `pinned: true` in the sidecar. Orange pushpin. Permanent until unpinned.
        case pinned
        /// Computed from `endeavor` + the Endeavor's date range. Indigo plane.
        /// Writes nothing to the sidecar and disappears when the trip ends.
        case activeTrip(endeavorName: String)
    }

    let document: TraceMacDocument
    let kind: Kind

    var id: String { document.relativePath }

    var isPinned: Bool {
        if case .pinned = kind { return true }
        return false
    }
}

/// The Kit assembly rules, kept out of the view so they can be read and changed
/// as rules. All of §5 "Kit display, overflow and sorting" lives here.
enum KitMembership {

    struct Layout {
        /// Exactly what the Library grid draws. Never more than 4.
        var grid: [KitEntry] = []
        /// Full membership, uncapped — what the Full Kit screen draws.
        var all: [KitEntry] = []
        var pinnedCount: Int = 0
        var tripCount: Int = 0
        var activeTrip: Endeavor?
        /// Grid slots currently reserved for the active trip. Meaningless with
        /// no trip; carried so the Kit screen can show and change it.
        var tripSlots: Int = SatchelKitPreferences.defaultTripSlots

        /// Scope §5: hidden entirely when Kit has 4 or fewer items, rather than
        /// sitting there dead.
        var showsSeeAll: Bool { all.count > 4 }
    }

    /// Grid is **always at most 4 tiles**. Kit's footprint on the Library never
    /// grows, whatever the trip size — only *which* four changes. With an active
    /// trip the split is 2 pins + 2 trip documents, and the slots are reserved so
    /// four manual pins cannot crowd the boarding pass out on the day it matters.
    /// If either side has fewer than its 2, the other backfills so the grid still
    /// fills out.
    static let gridCapacity = 4

    static func assemble(
        documents: [TraceMacDocument],
        endeavors: [Endeavor],
        today: Date = Date()
    ) -> Layout {
        var result = Layout()

        // --- Manual pins ---
        // Scope §5 locks the sort to "user order, drag to reorder, default =
        // order pinned" — muscle memory is most of the value on a grab-it-fast
        // surface, and a passport that moves because something else became more
        // relevant is worse than useless in a queue.
        //
        // `kit_order` (Session 50, sixth sidecar key) carries that order.
        // Documents pinned before the key existed have none, and sort AFTER the
        // ordered ones by capture date, so they land at the end instead of
        // shuffling to the front on first launch.
        let pinned = documents
            .filter(\.pinned)
            .sorted { lhs, rhs in
                switch (lhs.kitOrder, rhs.kitOrder) {
                case let (l?, r?): return l < r
                case (nil, _?):    return false
                case (_?, nil):    return true
                case (nil, nil):
                    return (lhs.created ?? .distantPast) < (rhs.created ?? .distantPast)
                }
            }

        // --- Active-trip documents ---
        let trip = endeavors
            .filter { $0.isActive(on: today) }
            .sorted { ($0.end ?? .distantFuture) < ($1.end ?? .distantFuture) }
            .first
        result.activeTrip = trip

        var tripDocs: [TraceMacDocument] = []
        if let trip {
            // Your order first, then the fallback. §5 asks for **imminence**
            // (nearest date first) and that is still not expressible: no
            // sidecar key carries a per-document event date, and `created` is a
            // capture timestamp that always points backwards. So an explicit
            // `kit_order` wins where you have set one, and everything else
            // falls back to most-recently-added — which is a decent proxy for a
            // trip you are actively assembling, and a poor one on flight day.
            tripDocs = documents
                .filter { $0.endeavor == trip.id && !$0.pinned }
                .sorted { lhs, rhs in
                    switch (lhs.kitOrder, rhs.kitOrder) {
                    case let (l?, r?): return l < r
                    case (nil, _?):    return false
                    case (_?, nil):    return true
                    case (nil, nil):
                        return (lhs.created ?? .distantPast) > (rhs.created ?? .distantPast)
                    }
                }
        }

        result.pinnedCount = pinned.count
        result.tripCount = tripDocs.count

        let pinnedEntries = pinned.map { KitEntry(document: $0, kind: .pinned) }
        let tripEntries = tripDocs.map {
            KitEntry(document: $0, kind: .activeTrip(endeavorName: trip?.name ?? "Trip"))
        }

        // Full membership is uncapped: any number may be pinned and they all
        // live on the Full Kit screen. Only the grid is capped.
        result.all = pinnedEntries + tripEntries

        // --- Grid allocation ---
        //
        // The reserved trip share is David's to set per trip (default 2, scope
        // §5). Whatever it is, the grid is still exactly four tiles: only which
        // four changes. Backfill runs BOTH directions, so a side with fewer
        // than its reservation hands the surplus over rather than leaving a
        // hole — four pins and no trip is four pins, no pins and a live trip is
        // four trip documents.
        if tripEntries.isEmpty {
            result.grid = Array(pinnedEntries.prefix(gridCapacity))
        } else {
            let reserved = SatchelKitPreferences.tripSlots(for: trip?.id)
            result.tripSlots = reserved

            var tripSlots = min(reserved, gridCapacity)
            var pinnedSlots = gridCapacity - tripSlots

            if pinnedEntries.count < pinnedSlots {
                tripSlots += pinnedSlots - pinnedEntries.count
                pinnedSlots = pinnedEntries.count
            }
            if tripEntries.count < tripSlots {
                pinnedSlots += tripSlots - tripEntries.count
                tripSlots = tripEntries.count
            }
            pinnedSlots = min(pinnedSlots, pinnedEntries.count)

            result.grid =
                Array(pinnedEntries.prefix(pinnedSlots)) +
                Array(tripEntries.prefix(tripSlots))
        }

        return result
    }

    /// The footnote under the grid: *"4 of 11 · 2 pinned, 2 from Japan 2026
    /// through Sep 24."* Informational first, tappable second — scope §5 is
    /// explicit that it must not be the only door to the full list.
    static func footnote(for result: Layout) -> String? {
        guard !result.all.isEmpty else { return nil }
        var parts: [String] = []
        if result.pinnedCount > 0 {
            parts.append("\(result.pinnedCount) pinned")
        }
        if result.tripCount > 0, let trip = result.activeTrip {
            var phrase = "\(result.tripCount) from \(trip.name)"
            if let end = trip.end {
                let fmt = DateFormatter()
                fmt.dateFormat = "MMM d"
                phrase += " through \(fmt.string(from: end))"
            }
            parts.append(phrase)
        }
        guard !parts.isEmpty else { return nil }
        let shown = min(result.grid.count, result.all.count)
        return "\(shown) of \(result.all.count) · " + parts.joined(separator: ", ")
    }
}
