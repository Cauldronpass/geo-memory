import Foundation
import CoreLocation
import SwiftUI

struct Place: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    var city: String
    var address: String
    var category: String
    var latitude: Double
    var longitude: Double
    var flagged: Bool
    var googlePlaceID: String?
    var googleMapsURL: String?
    var phone: String?
    var website: String?
    var hours: String?
    var status: String
    var ratingExternal: Double?
    var ratingPersonal: Int?
    var visitCount: Int
    var lastVisited: Date?
    var tags: [String]
    var aiSummary: String?
    var notes: String?
    var frequent: Bool = false        // Notion "Frequent" checkbox — wide geofence + Nearby priority
    var dwellTime: Int? = nil         // Notion "Dwell Time" (minutes) — nil = use 3 min default
    var geofenceRadius: Int? = nil    // Notion "Geofence Radius" (metres) — nil = use default (50m / 200m for frequent)
    var geofenceExcluded: Bool = false  // Notion "Geofence Excluded" checkbox — opt this place out entirely
    var promptLog: Bool = false          // Notion "Prompt Log" checkbox — fire a log prompt on exit (workout, billiards, etc.)
    var skipEnrichment: Bool = false    // Notion "Skip Enrichment" checkbox — exclude from Enrich Visits prompts
    var enrichmentStatus: String?      // Notion "Enrichment Status" select — e.g. "Enriched", "Needs Review"

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

struct Visit: Identifiable, Codable {
    let id: String
    var placeID: String
    var placeName: String
    var date: Date
    var rating: Int?
    var notes: String?
    var photoURLs: [String]
    var peopleIDs: [String]   // Notion relation IDs into the People DB
    var skipEnrichment: Bool = false  // Notion "Skip Enrichment" checkbox — hides from Enrich Visits list
}

struct Person: Identifiable, Codable {
    let id: String
    var name: String
    var relationship: String?
    var relationshipStrength: String?   // "new", "active", "dormant", or "archived"
    var agenda: String?     // Newline-delimited; fetched alongside name/relationship in fetchPeople
    /// Session 48 (Trace redesign) — bulk-fetched alongside the rest of Person
    /// so Home's "Coming Up" birthdays list doesn't need a per-person detail
    /// fetch. Previously this field only existed on PersonDetail (see below);
    /// same Notion "Birthday" property, just also pulled into the lightweight
    /// list model now. Year component is whatever Notion has on file — treat
    /// as month/day only when computing "next occurrence."
    var birthday: Date? = nil

    var isArchived: Bool { relationshipStrength == "archived" }
}


// MARK: - Agenda items
//
// David, 2026-08-01: *"does the coming up in trace all for people agenda items
// specific timing? I think that we set that up as a single text file that gets
// seggregated if there are more than one agenda for a person."*
//
// He remembered right. `Person.agenda` is one Notion rich-text property, newline
// delimited, with no date anywhere — so Coming Up listed everyone who had
// anything queued and an item sat there until deleted. *"the agenda problem you
// mention where things stay forever needs an answer."*
//
// **The date goes in the line, and there is no new database.** He asked whether a
// Notion reminders table was warranted; it is not, and the reason matters: the
// system he wants reminders across is only half in Notion. People, places and
// visits are records; **Endeavors are markdown files and Satchel documents are
// sidecars.** A reminders table could relate to the first half and would have to
// store file PATHS for the second — which is exactly the coupling that made
// archiving a project require rewriting `linked_note` in every document sidecar,
// repeated at a larger scale.
//
// So the date lives next to the thing it belongs to. For a person, that is the
// agenda line:
//
//     2026-08-14 Ask about Megan's new place
//     Send the Traverse City photos
//
// No Notion schema change, still readable and editable in Notion by hand, and an
// undated line is still valid.
//
// **Undated is deliberate and load-bearing.** Those are a someday list and stay
// OUT of Coming Up, so the only things that can pile up there are things David
// put a date on. That is half the answer to "stays forever". The other half is
// that overdue items never expire on their own — see `AgendaBucket`.

struct AgendaItem: Identifiable, Hashable {
    /// The line exactly as stored, which is what edits and deletions match on.
    let raw: String
    let due: Date?
    let text: String
    var id: String { raw }

    var isOverdue: Bool {
        guard let due else { return false }
        return Calendar.current.startOfDay(for: due) < Calendar.current.startOfDay(for: Date())
    }

    /// Days until due. Negative when overdue, nil when undated.
    var daysAway: Int? {
        guard let due else { return nil }
        let cal = Calendar.current
        return cal.dateComponents([.day],
                                  from: cal.startOfDay(for: Date()),
                                  to: cal.startOfDay(for: due)).day
    }
}

enum AgendaLine {

    /// Horizon for the forward half of Coming Up. Matches the birthday window
    /// already used there, so one card does not run on two clocks.
    static let horizonDays = 30

    private static var formatter: DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }

    /// `2026-08-14 Ask about the wedding` → date + text. Anything else is undated
    /// and kept verbatim, including a line that merely starts with digits.
    static func parse(_ raw: String) -> AgendaItem {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard line.count > 10 else { return AgendaItem(raw: raw, due: nil, text: line) }
        let head = String(line.prefix(10))
        let rest = String(line.dropFirst(10))
        guard rest.first == " " || rest.isEmpty,
              let due = formatter.date(from: head) else {
            return AgendaItem(raw: raw, due: nil, text: line)
        }
        return AgendaItem(raw: raw, due: due,
                          text: rest.trimmingCharacters(in: .whitespaces))
    }

    static func compose(due: Date?, text: String) -> String {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let due else { return body }
        return "\(formatter.string(from: due)) \(body)"
    }

    static func items(from agenda: String?) -> [AgendaItem] {
        (agenda ?? "")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { parse(String($0)) }
            .filter { !$0.text.isEmpty }
    }

    static func joined(_ items: [AgendaItem]) -> String {
        items.map(\.raw).joined(separator: "\n")
    }

    /// What Coming Up should show for one person: dated items only, overdue first,
    /// then anything inside the horizon. **Undated items are absent by design** and
    /// **overdue items are never dropped** — something you meant to raise last
    /// Tuesday and did not is still true, and silently ageing a reminder out is
    /// worse than leaving a stale one on screen.
    static func comingUp(from agenda: String?, horizonDays: Int = AgendaLine.horizonDays) -> [AgendaItem] {
        items(from: agenda)
            .filter { item in
                guard let days = item.daysAway else { return false }
                return days <= horizonDays
            }
            .sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
    }
}

// MARK: - Claude API key settings UI
//
// The STORE lives in `NoteStore.swift` — see the target-membership note there.
// Only the SwiftUI section lives here, because it needs SwiftUI and is only ever
// shown by Dayflow, which compiles this file.

// MARK: - Settings section
//
// Lives here rather than in a view file so every app that compiles Models.swift
// can drop it into its own settings without another target-membership change in
// Xcode.

struct ClaudeAPIKeySection: View {

    @State private var entry = ""
    @State private var editing = false
    /// Mirror of the stored key, held in `@State` so the row redraws when it
    /// changes. **This replaces an `.id(saved)` hack** that forced a redraw by
    /// changing the view's identity — which recreates the view and therefore
    /// resets the very `@State` driving the id. A value in state is the honest
    /// way to say "this changed".
    @State private var storedKey = ""

    private var trimmedEntry: String {
        entry.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Never show a key in full: enough to confirm which one is loaded, not
    /// enough to be worth a screenshot.
    private var masked: String {
        guard !storedKey.isEmpty else { return "Not set" }
        guard storedKey.count > 12 else { return "Set" }
        return "\(storedKey.prefix(8))…\(storedKey.suffix(4))"
    }

    /// `textInputAutocapitalization` is iOS-only and this file compiles into
    /// TraceMac as well, so the modifier is fenced rather than the whole view.
    @ViewBuilder
    private var secureEntryField: some View {
        #if os(iOS)
        SecureField("sk-ant-…", text: $entry)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        #else
        SecureField("sk-ant-…", text: $entry)
            .autocorrectionDisabled()
        #endif
    }

    var body: some View {
        Section {
            if editing {
                secureEntryField
                HStack {
                    // `.borderless` ON EVERY BUTTON, and it is not cosmetic.
                    //
                    // A Form row containing more than one Button gives them all
                    // the row's tap by default, so tapping Save ALSO ran Cancel.
                    // Cancel cleared `entry`, Save then wrote the empty string,
                    // and `set("")` removes the key — David tapped Save and the
                    // row still read "Not set", 2026-08-01.
                    Button("Cancel") {
                        entry = ""
                        editing = false
                    }
                    .buttonStyle(.borderless)

                    Spacer()

                    Button("Save") {
                        ClaudeKeyStore.set(entry)
                        storedKey = ClaudeKeyStore.key
                        entry = ""
                        editing = false
                    }
                    .buttonStyle(.borderless)
                    .fontWeight(.semibold)
                    .disabled(trimmedEntry.isEmpty)
                }
            } else {
                LabeledContent("Key") {
                    Text(masked)
                        .foregroundStyle(storedKey.isEmpty ? Color.red : Color.secondary)
                        .monospaced()
                }
                Button(storedKey.isEmpty ? "Add key" : "Replace key") {
                    entry = ""
                    editing = true
                }
                .buttonStyle(.borderless)

                if !storedKey.isEmpty {
                    Button("Remove key", role: .destructive) {
                        ClaudeKeyStore.set("")
                        storedKey = ""
                    }
                    .buttonStyle(.borderless)
                }
            }
        } header: {
            Text("Claude API key")
        } footer: {
            Text("Shared by Trace, Dayflow, Satchel and the Mac app. Stored on this device, not in the app itself. Without it, document scanning, photo scanning, note pre-fill and place-category suggestions quietly do nothing.")
        }
        .onAppear { storedKey = ClaudeKeyStore.key }
    }
}

// MARK: - Place categories

/// Guessing a place's category from what Google already told us.
///
/// **The default was the literal string "Restaurant"**, hardcoded in
/// `DiscoverView`, regardless of what was being saved. David, 2026-08-01:
/// *"clicking a place and adding it to Trace it always defaults to restaurant
/// which I don't want."*
///
/// `GooglePlace.primaryType` has been fetched, parsed and carried on the model
/// the whole time — `GooglePlacesService` even asks for it in its field mask —
/// and nothing ever read it. **Tenth thing this week that was already there.**
///
/// **Deliberately not AI.** David asked whether it could play a part, and it
/// could, but this map answers the overwhelming majority of cases instantly,
/// offline, for free, and identically every time. A model call would add a
/// network round trip to a screen where the next thing you do is tap Save,
/// and it would be wrong in ways that are hard to explain. If the tail turns
/// out to matter, the place to add it is `suggest(from:)`'s `nil` return, which
/// is deliberately distinguishable from a confident answer.
enum PlaceCategory {

    /// The canonical list. Was duplicated in four files.
    static let all = ["Restaurant", "Bar", "Cafe", "Hotel", "Shop",
                      "Attraction", "Venue", "House", "Fitness",
                      "Office", "Airport", "Medical", "Park", "Grocery"]

    /// Best guess for a Google `primaryType`, or nil when there is no honest one.
    ///
    /// Exact matches first, then keyword contains — Google's type vocabulary is
    /// long and grows, and `*_store` or `*_restaurant` variants are common
    /// enough that falling back on substrings catches most of the tail.
    static func suggest(from primaryType: String?) -> String? {
        guard let raw = primaryType?.lowercased().trimmingCharacters(in: .whitespaces),
              !raw.isEmpty else { return nil }

        let exact: [String: String] = [
            "restaurant": "Restaurant", "meal_takeaway": "Restaurant",
            "meal_delivery": "Restaurant", "fast_food_restaurant": "Restaurant",
            "bar": "Bar", "night_club": "Bar", "pub": "Bar", "wine_bar": "Bar",
            "cafe": "Cafe", "coffee_shop": "Cafe", "bakery": "Cafe",
            "lodging": "Hotel", "hotel": "Hotel", "motel": "Hotel", "resort_hotel": "Hotel",
            "supermarket": "Grocery", "grocery_store": "Grocery",
            "gym": "Fitness", "fitness_center": "Fitness", "yoga_studio": "Fitness",
            "park": "Park", "national_park": "Park", "hiking_area": "Park",
            "airport": "Airport", "international_airport": "Airport",
            "hospital": "Medical", "doctor": "Medical", "dentist": "Medical",
            "pharmacy": "Medical", "physiotherapist": "Medical",
            "tourist_attraction": "Attraction", "museum": "Attraction",
            "art_gallery": "Attraction", "zoo": "Attraction", "aquarium": "Attraction",
            "stadium": "Venue", "movie_theater": "Venue", "concert_hall": "Venue",
            "performing_arts_theater": "Venue", "event_venue": "Venue",
            "corporate_office": "Office", "accounting": "Office", "lawyer": "Office",
            "store": "Shop", "shopping_mall": "Shop", "clothing_store": "Shop",
        ]
        if let hit = exact[raw] { return hit }

        // The tail.
        if raw.contains("restaurant") || raw.contains("food")   { return "Restaurant" }
        if raw.contains("bar") || raw.contains("brewery")       { return "Bar" }
        if raw.contains("cafe") || raw.contains("coffee")       { return "Cafe" }
        if raw.contains("hotel") || raw.contains("lodging")     { return "Hotel" }
        if raw.contains("grocery") || raw.contains("market")    { return "Grocery" }
        if raw.contains("gym") || raw.contains("fitness")       { return "Fitness" }
        if raw.contains("park")                                 { return "Park" }
        if raw.contains("airport")                              { return "Airport" }
        if raw.contains("health") || raw.contains("medical") ||
           raw.contains("clinic")                               { return "Medical" }
        if raw.contains("museum") || raw.contains("attraction") { return "Attraction" }
        if raw.contains("theater") || raw.contains("stadium")   { return "Venue" }
        if raw.contains("office")                               { return "Office" }
        if raw.contains("store") || raw.contains("shop")        { return "Shop" }
        return nil
    }
}

/// Asks Claude for a category when Google has not told us one.
///
/// **Only ever the fallback.** `PlaceCategory.suggest(from:)` answers instantly,
/// offline and identically every time, and handles anything added from the map
/// or from search. This exists for the two cases that have no Google record at
/// all — a place typed in by hand, and a dropped pin — plus the tail where
/// Google's type is real but unmapped. In those the place's NAME is the only
/// signal there is, and no lookup table anyone would maintain gets from
/// "Arlington Lanes" to Venue.
///
/// **Non-blocking by design.** The caller fires this and forgets it; if it is
/// slow or fails or the key is missing, nothing happens and the plain default
/// stands. Never put a spinner on this — the next thing the user does on that
/// screen is tap Save.
///
/// Returns nil rather than guessing when the answer is not one of the known
/// categories, so a confused model cannot invent a category that does not exist.
enum PlaceCategoryAI {

    static func suggest(name: String, address: String) async -> String? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, ClaudeKeyStore.hasKey else { return nil }

        let prompt = """
            Classify this place into exactly one of these categories:
            \(PlaceCategory.all.joined(separator: ", "))

            Name: \(trimmedName)
            Address: \(address)

            Reply with the single category word and nothing else. If none of them \
            clearly fits, reply with: unknown
            """

        let body: [String: Any] = [
            // Haiku: this is a one-word classification and the screen is waiting.
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 10,
            "messages": [["role": "user", "content": prompt]]
        ]

        guard let url = URL(string: "https://api.anthropic.com/v1/messages"),
              let bodyData = try? JSONSerialization.data(withJSONObject: body)
        else { return nil }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(ClaudeKeyStore.key,  forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01",        forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json",  forHTTPHeaderField: "Content-Type")
        req.httpBody = bodyData
        // Short. A classification that has not answered by now has lost its
        // race with the user, and the default is already on screen.
        req.timeoutInterval = 8

        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = (json["content"] as? [[String: Any]])?.first,
              let text = content["text"] as? String
        else { return nil }

        let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Matched against the real list, case-insensitively. A model that
        // answers "Coffee Shop" gets nil, not a category the app does not have.
        return PlaceCategory.all.first { $0.caseInsensitiveCompare(answer) == .orderedSame }
    }
}

// MARK: - Interaction styling
//
// **One place that knows what an interaction type looks like.** There were four
// before this: `PersonDetailView.interactionIcon`, `DayflowWikiSummaryView`'s
// copy, `DayflowVisitDetailView`'s copy (whose own comment called itself an
// "independent copy"), and the colour map in `PeopleView`. The icon maps knew
// five types out of twelve, so lunch, dinner, visit, text, video call, event and
// workout all fell through to the same speech bubble — David, 2026-07-31:
// *"lately they have all been bubbles."* The colour map, in a different file,
// knew eleven. Two partial answers to the same question in four places.
//
// Filled variants throughout, deliberately. The old set mixed `phone` with
// `figure.socialdance`, and a set that mixes weights looks accidental rather
// than chosen.
enum InteractionStyle {

    /// SF Symbol for an interaction type. Unknown types get a speech bubble,
    /// which is now a real fallback rather than the majority case.
    static func icon(for type: String) -> String {
        switch type.lowercased() {
        case "visit":               return "mappin.circle.fill"
        case "lunch":               return "fork.knife"
        case "dinner":              return "wineglass.fill"
        case "coffee":              return "cup.and.saucer.fill"
        case "call", "phone":       return "phone.fill"
        case "video call", "video": return "video.fill"
        case "text":                return "message.fill"
        case "email":               return "envelope.fill"
        case "meeting":             return "person.2.fill"
        case "event":               return "ticket.fill"
        case "social":              return "figure.socialdance"
        case "workout":             return "figure.run"
        default:                    return "bubble.left.fill"
        }
    }

    /// Tint for the same type. Moved here from `PeopleView` unchanged — it was
    /// already the more complete of the two maps, it was just in the wrong place
    /// and only one screen could see it.
    static func color(for type: String) -> Color {
        switch type.lowercased() {
        case "call", "phone":        return .blue
        case "email":                return Color(.systemGray)
        case "meeting":              return .indigo
        case "coffee":               return Color(red: 0.55, green: 0.35, blue: 0.1)
        case "dinner", "lunch":      return .orange
        case "video call", "video":  return .cyan
        case "social", "event":      return .green
        case "text":                 return .teal
        case "visit":                return .teal
        case "workout":              return .orange
        default:                     return .purple
        }
    }
}

// MARK: - WikiLinkTarget
//
// Moved here from NotesView.swift (2026-07-19, Dayflow Session 1) — it's
// PersonDetailView/PlaceDetailView's own discriminated union (used by
// onWikiTap to present the right detail sheet), not something specific to
// NotesView, and it only depends on Place/Person, both already here. No
// behavior change for Trace — NotesView.swift still resolves it via the
// same Trace/TraceMac target membership as before.
enum WikiLinkTarget: Identifiable {
    case place(Place)
    case person(Person)
    var id: String {
        switch self {
        case .place(let p):  return "place-\(p.id)"
        case .person(let p): return "person-\(p.id)"
        }
    }
}

struct PersonDetail: Identifiable {
    let id: String
    var name: String
    var city: String?
    var companyContext: String?
    var relationship: String?
    var relationshipStrength: String?
    var isArchived: Bool { relationshipStrength == "archived" }
    var howWeMet: String?
    var notes: String?
    var agenda: String?              // Newline-delimited agenda items (Notion "Agenda" rich_text field)
    var tags: [String]
    var birthday: Date?
    var phone: String?
    var email: String?
    var address: String?
    var photoURL: String?
    var visitCount: Int?
    var lastVisitDate: Date?
    var lastInteractionDate: Date?
    var homePlaceID: String?         // Relation to Places DB ("Home Place" property)
}

struct Interaction: Identifiable {
    let id: String
    var summary: String
    var date: Date
    var type: String        // visit / dinner / lunch / coffee / call / video call / text / email / meeting / event / workout / other
    var notes: String?
    var photoURLs: [String] // stored as "Photo URLs" rich_text on the Notion page (newline-separated URLs)
    var personIDs: [String] // relation to People DB
    var visitID: String?    // Related Visit relation (optional)
}

struct QueuedItem: Identifiable, Codable {
    let id: UUID
    var type: QueuedItemType
    var content: String?
    var photoPath: String?
    var sessionID: UUID?
    var placeName: String?
    var createdAt: Date
    var processed: Bool

    init(type: QueuedItemType, content: String? = nil, photoPath: String? = nil, sessionID: UUID? = nil, placeName: String? = nil) {
        self.id = UUID()
        self.type = type
        self.content = content
        self.photoPath = photoPath
        self.sessionID = sessionID
        self.placeName = placeName
        self.createdAt = Date()
        self.processed = false
    }
}

enum QueuedItemType: String, Codable {
    case note
    case photo
}
struct Capture: Identifiable, Codable {
    let id: String
    var notes: String
    var gpsLat: Double?
    var gpsLon: Double?
    var timestamp: Date
    var placeID: String?
    var placeName: String?
    var status: String // "Unlinked", "Linked", "Archived"
    var photoURL: String?
}
struct Workout: Identifiable, Codable {
    let id: String
    var name: String
    var date: Date
    var type: String           // "OrangeTheory", "Run", "Bike", "Hike", "Lift", "Other"
    var duration: Int?         // minutes
    var calories: Int?
    var heartRateAvg: Int?
    var heartRateMax: Int?
    var splatPoints: Int?      // OTF only
    var output: Int?           // OTF only — watts
    var zone1: Int?            // minutes in Gray
    var zone2: Int?            // minutes in Blue
    var zone3: Int?            // minutes in Green
    var zone4: Int?            // minutes in Orange
    var zone5: Int?            // minutes in Red
    var distance: Double?      // miles (treadmill)
    var feel: Int?             // 1–7
    var notes: String?
    var placeID: String?
    var visitID: String?
    // OTF class detail
    var classType: String?     // "Tread 50", "2G", "3G", "Strength 50", "Tornado"
    var steps: Int?
    var elevation: Double?     // feet
    var treadPace: String?     // avg pace, e.g. "9:23"
    // Rower
    var hasRower: Bool?
    var rowerDistance: Int?    // meters
    var rowerWattsAvg: Int?
    var rowerPace: String?     // 500m split, e.g. "2:17"
    var rowerStrokeAvg: Int?

    var isOTF: Bool { type == "OrangeTheory" }
    var isCardio: Bool { ["Run", "Bike", "Hike"].contains(type) }
}

struct WorkoutDraft {
    var name: String = ""
    var type: String = "OrangeTheory"
    var date: Date? = Date()
    var duration: Int? = nil
    var calories: Int? = nil
    var heartRateAvg: Int? = nil
    var heartRateMax: Int? = nil
    var splatPoints: Int? = nil
    var output: Int? = nil
    var zone1: Int? = nil
    var zone2: Int? = nil
    var zone3: Int? = nil
    var zone4: Int? = nil
    var zone5: Int? = nil
    var distance: Double? = nil
    var feel: Int? = nil
    var notes: String? = nil
    var placeID: String? = nil
    var visitID: String? = nil
    var classType: String? = nil
    var steps: Int? = nil
    var elevation: Double? = nil
    var treadPace: String? = nil
    var hasRower: Bool? = nil
    var rowerDistance: Int? = nil
    var rowerWattsAvg: Int? = nil
    var rowerPace: String? = nil
    var rowerStrokeAvg: Int? = nil
}

struct DayNote: Identifiable, Codable {
    let id: String
    var date: Date?      // nil for bucket notes
    var scope: String?   // nil for date notes; "This Week" / "Next Week" / "This Month" / "Next Month"
    var body: String
    var status: String?  // "Archived" or nil (active)
}

struct CheckInSession: Identifiable, Codable {
    let id: UUID
    var placeID: String
    var placeName: String
    var startedAt: Date
    var endedAt: Date?
    var visitNotionID: String?

    init(placeID: String, placeName: String) {
        self.id = UUID()
        self.placeID = placeID
        self.placeName = placeName
        self.startedAt = Date()
    }
}

// MARK: - Billiards

struct BilliardsDraft {
    var date: Date = Date()
    var format: String = "8-Ball"
    var opponent: String = ""
    var mySkillLevel: Int = 5
    var opponentSkillLevel: Int? = nil
    var result: String? = nil            // "Win" or "Loss"
    var myTeamPoints: Int? = nil
    var opponentTeamPoints: Int? = nil
    var myScore: String? = nil           // "score/needed" e.g. "39/38" or "4/5"
    var opponentScore: String? = nil
    var innings: Int? = nil
    var wonLag: Bool = false
    var notes: String = ""
    var visitID: String? = nil
    var matchNumber: Int? = nil
}

struct BilliardsSession: Identifiable, Codable {
    let id: String
    var date: Date
    var format: String
    var opponent: String
    var mySkillLevel: Int?
    var opponentSkillLevel: Int?
    var result: String?
    var myTeamPoints: Int?
    var opponentTeamPoints: Int?
    var myScore: String?
    var opponentScore: String?
    var innings: Int?
    var wonLag: Bool
    var notes: String?
    var visitID: String?
    var matchNumber: Int?
}
