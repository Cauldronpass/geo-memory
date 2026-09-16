// KitWindow.swift
// Shared. What is in his bag: the rule, in ONE place, for Satchel and the Mac.
//
// D420, Session 106. Kit is manual pins plus the documents of a trip close
// enough to need in hand. The second half was decided by
// `Endeavor.isKitRelevant(on:)`, which lived on Satchel's own four-field
// `Endeavor` inside `Satchel/` — a different type from the shared `Endeavor`
// the Mac and Dayflow use, and invisible to them. So the Mac's IN PLAY showed
// pins only, and its source comment said why: *"A copy of that rule on the Mac
// would be two definitions of what is in his bag."*
//
// ── Why a protocol, and not a move ────────────────────────────────────────
//
// The two `Endeavor` types cannot become one here: Satchel cannot compile
// `Trace/Endeavor.swift` (it drags the note store's whole model with it, and
// the names collide). What CAN be one is everything Kit asks of a trip — five
// read-only facts — and the three decisions made from them: is this trip
// relevant today, which trip wins when two are, and what order its documents
// and the pins sit in. Both `Endeavor`s conform; neither owns the rule.
//
// Membership: Satchel, TraceMac and Dayflow (explicit, in `project.pbxproj`),
// and Trace (which compiles its whole folder). Dayflow is there only because
// `Endeavor.swift` conforms, not because Dayflow draws a Kit.

import Foundation

/// The five facts Kit needs from a trip. Nothing else.
protocol KitTrip {
    var id: String { get }
    var name: String { get }
    var isTravel: Bool { get }
    var kitIsCancelled: Bool { get }
    var kitStart: Date? { get }
    var kitEnd: Date? { get }
}

enum KitWindow {

    /// Days before `start` that a trip's documents start appearing in Kit.
    ///
    /// Scope §5 reserves Kit slots so pins "cannot crowd the boarding pass out
    /// **on the day it matters**", and it matters the evening before, checking
    /// in and packing. David's number, 2026-07-29.
    static let leadInDays = 3

    /// Days after `end` that they stay. The return leg is flown on the last day
    /// and receipts are collected on it.
    static let tailDays = 1

    /// True when this trip is near enough that its documents belong to hand.
    ///
    /// **NOT the same question as "has it started"** — `Endeavor.status(on:)`
    /// answers that one and must stay strict. Kit asks "do I need this now?".
    /// A Travel endeavor with no dates at all is never relevant, or every
    /// undated trip would permanently occupy Kit.
    static func isRelevant(_ trip: some KitTrip, on date: Date) -> Bool {
        guard trip.isTravel, !trip.kitIsCancelled else { return false }
        guard trip.kitStart != nil || trip.kitEnd != nil else { return false }

        let cal = Calendar.current
        let day = cal.startOfDay(for: date)

        if let start = trip.kitStart,
           let opens = cal.date(byAdding: .day, value: -leadInDays, to: cal.startOfDay(for: start)),
           day < opens {
            return false
        }
        if let end = trip.kitEnd,
           let closes = cal.date(byAdding: .day, value: tailDays, to: cal.startOfDay(for: end)),
           day > closes {
            return false
        }
        return true
    }

    /// The single trip whose documents belong in Kit today. If two windows
    /// overlap, the one ending soonest wins — it is about to stop mattering.
    static func activeTrip<T: KitTrip>(in trips: [T], on date: Date = Date()) -> T? {
        trips
            .filter { isRelevant($0, on: date) }
            .sorted { ($0.kitEnd ?? .distantFuture) < ($1.kitEnd ?? .distantFuture) }
            .first
    }

    /// Manual pins in his order. `kit_order` ascending; pins from before the key
    /// existed sort after the ordered ones by arrival, oldest first, so they
    /// land at the end instead of jumping to the front.
    static func pinned(_ documents: [TraceMacDocument]) -> [TraceMacDocument] {
        documents
            .filter(\.pinned)
            .sorted { lhs, rhs in
                switch (lhs.kitOrder, rhs.kitOrder) {
                case let (l?, r?): return l < r
                case (nil, _?):    return false
                case (_?, nil):    return true
                case (nil, nil):
                    return (lhs.listDate ?? .distantPast) < (rhs.listDate ?? .distantPast)
                }
            }
    }

    /// A trip's documents, pins excluded (a pinned one is already in the bag).
    /// `kit_order` first, then most recently ARRIVED first — `listDate`, never
    /// `created`, which is the date printed on the document and points forward
    /// for a trip (D381).
    static func tripDocuments(_ documents: [TraceMacDocument], tripID: String) -> [TraceMacDocument] {
        documents
            .filter { $0.endeavor == tripID && !$0.pinned }
            .sorted { lhs, rhs in
                switch (lhs.kitOrder, rhs.kitOrder) {
                case let (l?, r?): return l < r
                case (nil, _?):    return false
                case (_?, nil):    return true
                case (nil, nil):
                    return (lhs.listDate ?? .distantPast) > (rhs.listDate ?? .distantPast)
                }
            }
    }
}
