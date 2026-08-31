// TraceMacNavigator.swift
// Back and forward, across every section. Mac-only.
//
// David: *"in the endeavor for Megan I clicked on the Satchel document for the
// Megan & Ryan wedding timeline. Now I want to go back to where I was and there
// is no easy way other than navigating manually."*
//
// ── What counts as a place, and what does not ────────────────────────────
//
// Asked and answered before building: *"go back to where i was not to the way i
// got there."* So switching from Notes ▸ Daily to Notes ▸ Projects on the way to
// opening a note is **not** a step. Reading 2026-08-12, then opening
// `Megan Wedding Text`, then pressing back returns to 2026-08-12 in one press —
// not to an empty Projects list in two.
//
// A tab is how you got somewhere. A record is where you were.
//
// ── Why the entries are `MacSearchDestination` ──────────────────────────
//
// Because `TraceMacContentView.openSearchResult` already replays exactly that
// type, into the pending-link bindings every deep link in this app rides. Going
// back is re-issuing a destination. A second vocabulary of places, with its own
// switch over the same seven folders, is the drift this project has paid for
// three times — see D105, where the same reasoning made
// `MacSearchEngine.destination(for:)` stop being private.

import Foundation

/// Somewhere worth returning to.
enum MacPlace: Hashable, Sendable {
    /// A section with nothing selected in it.
    case section(MacSection)
    /// A specific record, replayable through the existing router.
    case record(MacSearchDestination)

    /// Which section this place lives in. Used to collapse "clicked the sidebar,
    /// and the list then selected its first row" into one entry rather than two.
    var section: MacSection {
        switch self {
        case .section(let value): return value
        case .record(let destination):
            switch destination {
            case .dailyOrProjectNote, .weeklyNote, .preview: return .notes
            case .inboxNote:                                 return .inbox
            case .person, .place:                            return .directory
            case .endeavor:                                  return .endeavors
            case .document:                                  return .documents
            // Session 80. Note that this is the section a task LIVES in, which
            // is always Tasks — even for a dated task, whose deep link lands on
            // its context list rather than a pool. Back should return to the
            // screen, and the screen is the same one either way.
            case .task:                                      return .tasks
            }
        }
    }
}

@MainActor
@Observable
final class MacNavigator {

    static let shared = MacNavigator()
    private init() {}

    private(set) var current: MacPlace?
    private(set) var backStack: [MacPlace] = []
    private(set) var forwardStack: [MacPlace] = []

    /// Set by the header arrows, consumed by `TraceMacContentView`.
    ///
    /// The header is drawn inside every section and has no access to the
    /// pending-link state, so it asks rather than acts — the same
    /// consume-and-clear shape as `MacSearchRoute`, and for the same reason: the
    /// view that can perform the move is not the view that holds the button.
    var pendingReplay: MacPlace?

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    /// Fifty is well past anyone's memory of where they have been, and it stops
    /// a long session growing this without bound.
    private static let limit = 50

    // MARK: Recording

    /// Report where the app now is. Safe to call on every selection change.
    ///
    /// **Three no-ops, and each one exists because of a way this would otherwise
    /// produce entries a person did not make:**
    ///
    /// 1. Same place as now — a view re-reporting on redraw is not a visit.
    /// 2. Replaying — `current` is set to the target *before* the move, so the
    ///    section that lands reports the place it was sent to and this returns
    ///    immediately. That is why there is no `isReplaying` flag: a flag would
    ///    have to stay true across an async `.task(id:)` hand-off and nobody
    ///    knows for how long.
    /// 3. A bare section immediately followed by a record inside it — clicking
    ///    "Endeavors" in the sidebar, where the rail then selects its first row,
    ///    is **one** move. The section entry is replaced rather than pushed, so
    ///    back does not land on the screen you are already looking at.
    func record(_ place: MacPlace) {
        guard place != current else { return }

        // 4. A bare section report matching where we already are.
        //
        // **This is what made back take two presses.** `goBack` sets `current`
        // to the target and asks `TraceMacContentView` to replay it; replaying a
        // document sets `selectedSection = .documents`, and the section watcher
        // reports `.section(.documents)`. That is not equal to
        // `.record(.document(path))`, and no-op 3 does not catch it because it
        // tests the OLD value for being a section, not the new one. So every
        // back press pushed the place it had just returned to, and the stack
        // grew as fast as he could unwind it.
        //
        // A bare section is only ever a *step* when it moves you between
        // sections. Arriving at the section you are already in — by replay, or
        // by clicking the sidebar item for the screen you are looking at — is
        // not a move, and recording it says otherwise.
        //
        // Still no `isReplaying` flag, for the reason recorded on no-op 2: this
        // is knowable from the values themselves, and a flag would have to
        // survive an async hand-off of unknown length.
        if case .section(let value) = place, current?.section == value { return }

        if let existing = current {
            if case .section(let value) = existing, place.section == value {
                current = place
                return
            }
            backStack.append(existing)
            if backStack.count > Self.limit {
                backStack.removeFirst(backStack.count - Self.limit)
            }
        }
        current = place
        // Going somewhere new ends the forward branch, exactly as a browser does.
        forwardStack.removeAll()
    }

    // MARK: Moving

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        if let existing = current { forwardStack.append(existing) }
        current = previous
        pendingReplay = previous
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        if let existing = current { backStack.append(existing) }
        current = next
        pendingReplay = next
    }
}
