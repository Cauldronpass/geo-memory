// TraceRoute.swift
// Dayflow — the host target of the one app (D452).
//
// D466, Session 108. One route table for both URL schemes, and one router that
// holds a route until the data it needs has loaded.
//
// ── What this replaces, and why ─────────────────────────────────────────────
//
// Until the merge, `trace://` is parsed in `Trace/ContentView.swift` (seventeen
// hosts) and `dayflow://` in `Dayflow/ContentView.swift` and `DayflowRootView`
// (nine hosts). Each parser keeps its own pending IDs and its own `onChange`
// watchers that retry when Notion places, people or visits finish loading,
// and Dayflow carries `DayflowRouteInbox` besides, because a URL opened from
// Dayflow's own intent never fires `onOpenURL`. Copying all of that into one
// app would leave the merged app with two parsers and five retry mechanisms
// for hops across a wall that no longer exists.
//
// So: `TraceRoute` is every door into the app as a value, parsed from EITHER
// scheme, so every Shortcut, widget link and Satchel return URL keeps working
// unchanged. `TraceRouter` takes a route from a URL, an intent or a quick
// action, holds it until the stores it needs report ready, and hands it to a
// screen exactly once. Screens ask the router; nothing keeps its own pending
// state. Intents deliver into the router directly, so the inbox goes.
//
// ── Wiring, as of D468 (merge pass (a), Session 109) ─────────────────────────
//
// Written ahead of the merge so pass (a) has a spine (D457 step 4). What is
// live now: the three stores report readiness through `wireStores()` at the
// foot of this file, and `Dayflow/ContentView.swift` delivers every URL that
// reaches the app, from `onOpenURL` and from `DayflowRouteInbox` alike.
//
// What is NOT live: nothing TAKES a route yet. `handleDeepLink` still does the
// real work for every `dayflow://` host, exactly as before, and the screens
// that come across from Trace are wired to `take(where:)` one at a time as
// they arrive. A delivered route that no screen accepts simply expires after
// `patience`, which is what that timer is for. The two `ContentView` parsers
// and the pending-ID watchers retire in pass (c), branch by branch, as their
// screens move over.

import Foundation
import Observation

// MARK: - The routes

/// Every door into the one app, from either scheme.
///
/// Cases are named for what they DO, not for the host that carried them:
/// `trace://addnote`, `trace://quicknote` and the NewNote quick action are all
/// `.addNote`. The host spellings live only in `init?(url:)`.
enum TraceRoute: Equatable, Sendable {

    // Records (Trace's screens, coming across in pass (a))

    /// Check in at a place; `placeID` nil opens the picker. `trace://checkin?placeID=&notes=`
    case checkIn(placeID: String?, notes: String?)
    /// Log an interaction with a person. `trace://loginteraction?personID=&type=&notes=`
    case logInteraction(personID: String, type: String?, notes: String?)
    /// Open a visit. `trace://visit?id=`
    case visit(id: String)
    /// Open a capture's card; nil opens the captures drawer. `trace://capture?id=`
    case capture(id: String?)
    /// Promote a capture to a Place. `trace://saveplace?id=`
    case savePlace(captureID: String)
    /// Drop a pin on the map among the saved places. `trace://discover?lat=&lon=&label=`
    case discover(lat: Double, lon: Double, label: String?)
    /// Write a pin marker into today's day note, no UI (D398). `trace://pinhere?label=&emoji=`
    case pinHere(label: String?, emoji: String?)
    /// The quick-pin label sheet. `trace://pin`
    case quickPin

    // Notes and days (Dayflow's screens)

    /// Open a note by container path. `trace://note?path=` and `dayflow://note?path=`
    case note(path: String)
    /// Open an endeavor. `dayflow://endeavor?id=`
    case endeavor(id: String)
    /// The day in blocks, today when `date` is nil. `dayflow://day?date=yyyy-MM-dd`
    case day(date: String?)
    /// Open a task's edit sheet. `dayflow://task?id=`
    case task(id: String)

    // Compose

    case addTask
    case addEvent
    case addNote
    case addPhoto
    case addPlace
    case addPerson
    /// Hands to Satchel (`satchel://scan`); stays a hop, Satchel is its own app (D452).
    case addDocument
    case workout
    /// The compose menu on Today (D454). `trace://homefab`
    case compose

    // Launcher tiles and hand-offs

    /// `dayflow://launch?target=today|capture|checkin|file`
    case launch(LaunchTarget)
    /// Fantastical if present, else Calendar. `dayflow://openCalendar`
    case openCalendar
    /// `dayflow://openJot`
    case openJot

    enum LaunchTarget: String, Sendable {
        case today, capture, checkin, file
    }

    // MARK: Parsing

    /// Accepts `trace://` and `dayflow://`. Hosts are matched without case, so
    /// `dayflow://addEvent` and `dayflow://addevent` are the same door.
    /// Returns nil for a scheme or host this app does not know, and the
    /// caller decides whether to log it or open it elsewhere.
    init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "trace" || scheme == "dayflow",
              let host = url.host?.lowercased() else { return nil }
        let items: [URLQueryItem] = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        /// A query value, trimmed, nil when absent or blank. Names match without case.
        func value(_ name: String) -> String? {
            let raw = items.first { $0.name.lowercased() == name }?.value?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (raw?.isEmpty ?? true) ? nil : raw
        }

        switch host {
        case "checkin":
            self = .checkIn(placeID: value("placeid"), notes: value("notes"))
        case "loginteraction":
            guard let person = value("personid") else { return nil }
            self = .logInteraction(personID: person, type: value("type"), notes: value("notes"))
        case "visit":
            guard let id = value("id") else { return nil }
            self = .visit(id: id)
        case "capture":
            self = .capture(id: value("id"))
        case "saveplace":
            guard let id = value("id") else { return nil }
            self = .savePlace(captureID: id)
        case "discover":
            guard let lat = value("lat").flatMap(Double.init),
                  let lon = value("lon").flatMap(Double.init) else { return nil }
            self = .discover(lat: lat, lon: lon, label: value("label"))
        case "pinhere":
            self = .pinHere(label: value("label"), emoji: value("emoji"))
        case "pin":
            self = .quickPin
        case "note":
            guard let path = value("path") else { return nil }
            self = .note(path: path)
        case "endeavor":
            guard let id = value("id") else { return nil }
            self = .endeavor(id: id)
        case "day":
            self = .day(date: value("date"))
        case "task":
            guard let id = value("id") else { return nil }
            self = .task(id: id)
        case "addtask":
            self = .addTask
        case "addevent":
            self = .addEvent
        case "addnote", "quicknote":
            self = .addNote
        case "addphoto":
            self = .addPhoto
        case "addplace":
            self = .addPlace
        case "addperson":
            self = .addPerson
        case "adddocument":
            self = .addDocument
        case "workout":
            self = .workout
        case "homefab":
            self = .compose
        case "launch":
            guard let target = value("target").flatMap(LaunchTarget.init(rawValue:)) else { return nil }
            self = .launch(target)
        case "opencalendar":
            self = .openCalendar
        case "openjot":
            self = .openJot
        default:
            return nil
        }
    }

    /// The home-screen quick actions, by their `UIApplicationShortcutItem` type.
    /// Both apps' sets, so either set of installed icons keeps working (D457
    /// step 4 chooses which four the merged app shows).
    init?(quickAction type: String) {
        switch type {
        case "quickpin":            self = .quickPin
        case "checkin":             self = .checkIn(placeID: nil, notes: nil)
        case "addnote", "NewNote":  self = .addNote
        case "addphoto":            self = .addPhoto
        case "AddTask":             self = .addTask
        case "AddEvent":            self = .addEvent
        default:                    return nil
        }
    }

    // MARK: What a route needs before it can be shown

    /// The stores a route reads before a screen can act on it. A route with an
    /// empty set is shown at once. This is what the per-screen `onChange`
    /// watchers were each re-deriving by hand.
    var needs: Set<TraceRouter.Need> {
        switch self {
        case .checkIn(let placeID, _):  return placeID == nil ? [] : [.places]
        case .logInteraction:           return [.people]
        case .visit:                    return [.visits]
        case .capture(let id):          return id == nil ? [] : [.captures]
        case .savePlace:                return [.places, .captures]
        case .note, .endeavor, .day:    return [.notes]
        case .task:                     return [.tasks]
        case .discover, .pinHere, .quickPin,
             .addTask, .addEvent, .addNote, .addPhoto, .addPlace, .addPerson,
             .addDocument, .workout, .compose, .launch, .openCalendar, .openJot:
            return []
        }
    }
}

// MARK: - The router

/// Holds routes until their stores are ready, then hands each to a screen once.
///
/// **One mechanism for every source.** `onOpenURL`, an `AppIntent`'s
/// `OpenURLIntent`, a quick action and a Spotlight tap all end in `deliver`,
/// and a screen that can show a kind of route asks `take` for it. The screen
/// never holds an ID of its own and never watches a store; it watches
/// `version` and asks again.
///
/// **Readiness is reported, not inferred.** `NotionService` says places are
/// loaded; `NoteStore` says the container is reachable. A route that needs
/// something not yet ready waits, and a route that has waited longer than
/// `patience` is dropped rather than firing into a screen the person left
/// minutes ago, which is the fault the old pending-ID retries could commit.
@MainActor
@Observable
final class TraceRouter {

    static let shared = TraceRouter()

    /// What a route can wait for. Stores call `markReady` when they have it.
    enum Need: Hashable, Sendable {
        case places, people, visits, captures, notes, tasks
    }

    private struct Held {
        let serial: Int
        let route: TraceRoute
        let deliveredAt: Date
    }

    /// Bumped on every deliver and every readiness change; screens observe it
    /// and call `take` again.
    private(set) var version: Int = 0
    private(set) var ready: Set<Need> = []
    private var held: [Held] = []
    private var serial: Int = 0

    /// How long a route may wait for its stores before it is dropped.
    var patience: TimeInterval = 120

    private init() {}

    // MARK: Delivering

    /// Parses and holds a URL from either scheme. `false` means this app has no
    /// such door; the caller may open it elsewhere or ignore it.
    @discardableResult
    func deliver(_ url: URL) -> Bool {
        guard let route = TraceRoute(url: url) else { return false }
        deliver(route)
        return true
    }

    /// Holds a route from an intent, a quick action or a screen.
    func deliver(_ route: TraceRoute) {
        serial += 1
        held.append(Held(serial: serial, route: route, deliveredAt: Date()))
        version += 1
    }

    // MARK: Readiness

    func markReady(_ need: Need) {
        guard !ready.contains(need) else { return }
        ready.insert(need)
        version += 1
    }

    /// For a store that lost what it had (iCloud access withdrawn, sign-out).
    func markNotReady(_ need: Need) {
        guard ready.contains(need) else { return }
        ready.remove(need)
        version += 1
    }

    // MARK: Taking

    /// The oldest held route this screen accepts whose needs are all ready.
    /// Removed on return, so no route is shown twice. Routes older than
    /// `patience` are dropped as they are passed over.
    func take(where accepts: (TraceRoute) -> Bool) -> TraceRoute? {
        let now = Date()
        held.removeAll { now.timeIntervalSince($0.deliveredAt) > patience }
        guard let index = held.firstIndex(where: { accepts($0.route) && $0.route.needs.isSubset(of: ready) })
        else { return nil }
        let found = held.remove(at: index)
        version += 1
        return found.route
    }

    /// Whether anything is waiting that this screen would accept, ready or not.
    /// For a root that wants to switch tabs before the destination is ready.
    func hasHeld(where accepts: (TraceRoute) -> Bool) -> Bool {
        held.contains { accepts($0.route) }
    }

    /// Drops everything. For sign-out and for tests.
    func clear() {
        held.removeAll()
        version += 1
    }
}

// MARK: - Wiring the stores (D468)

extension TraceRouter {

    /// Connects the three stores' load hooks to `markReady`, and catches up on
    /// anything that loaded before this ran. Called once, at launch, from
    /// `DayflowApp`.
    ///
    /// **Why the stores publish through closures rather than calling this
    /// router.** `NotionService.swift`, `NoteStore.swift` and
    /// `ReminderTaskStore.swift` live in `Trace/` and compile into Trace, Jot,
    /// Satchel, two widget extensions and TraceMac as well as this target.
    /// `TraceRoute.swift` is in `Dayflow/` and compiles into this target alone.
    /// A direct call from a shared store to a type only one target has is
    /// D440's trap: a build breaking in an app nobody was working on. So each
    /// store exposes a closure of its own vocabulary and this file, which knows
    /// about both sides, joins them.
    ///
    /// **Why inside the fetches rather than at their call sites.** Forty-odd
    /// callers across four apps, and the stores already make that argument
    /// themselves for `PlacesFeed.publish` and the `fetchedAt` stamp.
    static func wireStores() {
        NotionService.onFeedLoaded = { feed in
            switch feed {
            case .places:   shared.markReady(.places)
            case .people:   shared.markReady(.people)
            case .visits:   shared.markReady(.visits)
            case .captures: shared.markReady(.captures)
            }
        }
        NoteStore.onAccess = { shared.markReady(.notes) }
        ReminderTaskStore.onLoad = { shared.markReady(.tasks) }

        // ── Catch-up ────────────────────────────────────────────────────────
        //
        // A store can finish before this runs. `NoteStore` resolves its
        // container in `init`, which happens on the FIRST touch of `.shared`
        // anywhere in the app, and that can easily precede the launch `.task`.
        // Waiting for a second event that will never come is how a route sits
        // held until `patience` drops it, with the data it needed sitting
        // loaded the whole time.
        //
        // Each test below is the store's own record of a SUCCESSFUL load, not
        // "is the array non-empty": a loaded-and-empty store is ready, and an
        // empty one that never loaded is not, and only these flags tell them
        // apart.
        if NoteStore.shared.hasAccess { shared.markReady(.notes) }
        if ReminderTaskStore.shared.lastFetched != nil { shared.markReady(.tasks) }
        if NotionService.shared.placesLoad == .loaded { shared.markReady(.places) }
        if NotionService.shared.peopleLoad == .loaded { shared.markReady(.people) }
        // Visits and captures have no load state of their own (the reason is on
        // `loadState(of:)`), so there is nothing here that could tell a cold
        // store from a loaded empty one. Both are fetched after this call on a
        // cold launch, so the hook covers them; a warm relaunch is the gap, and
        // it closes when those two collections get load states of their own.
    }
}
