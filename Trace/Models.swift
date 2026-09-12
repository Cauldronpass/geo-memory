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

// MARK: - Todoist token

/// The Todoist token, for the Work chip on Dayflow's task card (D368).
///
/// **Beside the Claude key deliberately.** Both are pasted secrets that leave
/// the device, both are per-device, and a person who has found one should find
/// the other in the same place rather than learning that Dayflow keeps its
/// secrets in two rooms.
///
/// **Per device, and the footer says so out loud.** `TodoistKeyStore` reads the
/// Mac's keychain on macOS and this device's App Group defaults on iOS, and App
/// Groups do not cross devices. The Mac having a working token is exactly the
/// thing that makes a phone with none look broken rather than unconfigured,
/// which is why the sentence is here and not left to be discovered.
struct TodoistKeySection: View {

    @State private var entry = ""
    @State private var editing = false
    @State private var storedKey = ""

    private var trimmedEntry: String {
        entry.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var masked: String {
        guard !storedKey.isEmpty else { return "Not set" }
        guard storedKey.count > 12 else { return "Set" }
        return "\(storedKey.prefix(6))…\(storedKey.suffix(4))"
    }

    @ViewBuilder
    private var secureEntryField: some View {
        #if os(iOS)
        SecureField("API token", text: $entry)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        #else
        SecureField("API token", text: $entry)
            .autocorrectionDisabled()
        #endif
    }

    var body: some View {
        Section {
            if editing {
                secureEntryField
                HStack {
                    // `.borderless` on every button: a Form row with more than
                    // one Button hands them all the row's tap, which is how Save
                    // came to run Cancel first and store an empty string (see
                    // the Claude key section's own note).
                    Button("Cancel") {
                        entry = ""
                        editing = false
                    }
                    .buttonStyle(.borderless)

                    Spacer()

                    Button("Save") {
                        TodoistKeyStore.set(entry)
                        storedKey = TodoistKeyStore.key
                        entry = ""
                        editing = false
                    }
                    .buttonStyle(.borderless)
                    .fontWeight(.semibold)
                    .disabled(trimmedEntry.isEmpty)
                }
            } else {
                LabeledContent("Token") {
                    Text(masked)
                        .foregroundStyle(storedKey.isEmpty ? Color.secondary : Color.secondary)
                        .monospaced()
                }
                Button(storedKey.isEmpty ? "Add token" : "Replace token") {
                    entry = ""
                    editing = true
                }
                .buttonStyle(.borderless)

                if !storedKey.isEmpty {
                    Button("Remove token", role: .destructive) {
                        TodoistKeyStore.set("")
                        storedKey = ""
                    }
                    .buttonStyle(.borderless)
                }
            }
        } header: {
            Text("Todoist token")
        } footer: {
            Text("Used by the Work list on the task card, which sends straight to your Todoist Inbox instead of creating a reminder. Stored on this device only — the token on your Mac does not carry over. Todoist ▸ Settings ▸ Integrations ▸ Developer.")
        }
        .onAppear { storedKey = TodoistKeyStore.key }
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

    /// The canonical list, and now the ONLY one (D333, Session 93).
    ///
    /// The note here used to read "was duplicated in four files". It was still
    /// duplicated in six when David asked for more categories — every picker in
    /// both apps carried its own copy, so adding one in the obvious place would
    /// have added it to exactly one screen. All six now read this array.
    ///
    /// **Five added 2026-09-06, appended rather than sorted in.** David:
    /// *"Denver for example should be City which isnt a choice. I also had a
    /// gas station that was not a choice."* Existing order is left alone so
    /// nothing he already knows moves in a picker.
    ///
    /// - **City** — Denver, Savannah. The one that was structurally missing:
    ///   an endeavor's destination is almost always a city, and Create now
    ///   writes those names onto endeavors (D332), so they had nowhere to sit.
    /// - **Gas** — road trips. He drives to Fort Collins.
    /// - **School** — a campus. Hannah's graduation is an endeavor already.
    /// - **Parking** — a garage or a lot. Bookings have had a Parking kind
    ///   since D267 and the place it happens had no category.
    /// - **Service** — the mechanic, the vet, the dry cleaner, the salon. The
    ///   errand bucket that was falling into Shop, which is where you buy
    ///   things rather than have something done.
    ///
    /// **Notion needs no schema edit.** Writing an unknown option to a select
    /// creates it, so the first place saved under a new category adds it there.
    static let all = ["Restaurant", "Bar", "Cafe", "Hotel", "Shop",
                      "Attraction", "Venue", "House", "Fitness",
                      "Office", "Airport", "Medical", "Park", "Grocery",
                      "City", "Gas", "School", "Parking", "Service"]

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
            // Added with the five new categories (D333).
            "locality": "City", "administrative_area_level_1": "City",
            "administrative_area_level_2": "City", "political": "City",
            "gas_station": "Gas", "electric_vehicle_charging_station": "Gas",
            "school": "School", "university": "School", "primary_school": "School",
            "secondary_school": "School", "library": "School",
            "parking": "Parking",
            "car_repair": "Service", "car_wash": "Service", "veterinary_care": "Service",
            "hair_salon": "Service", "beauty_salon": "Service", "laundry": "Service",
            "bank": "Service", "atm": "Service", "post_office": "Service",
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
        // The tail for the five added in D333, ABOVE the Shop line on purpose:
        // "car_repair_shop" is a Service and "gas_station_store" is a Gas, and
        // both contain "shop"/"store". Order is the rule here, not the words.
        if raw.contains("gas") || raw.contains("charging")      { return "Gas" }
        if raw.contains("school") || raw.contains("universit")  { return "School" }
        if raw.contains("parking")                              { return "Parking" }
        if raw.contains("repair") || raw.contains("salon")      { return "Service" }
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


// MARK: - Bookings (D266)

/// One row of the Bookings database: a flight, a shuttle, a hotel, a car, a
/// parking reservation. ONE database for every kind rather than one per kind
/// (D266) - the columns are nearly identical, and it is one fetch and one rail
/// section instead of six.
///
/// Keyed to its endeavor by the SLUG, `Endeavor.id`, which is never edited
/// after creation (D9). Not by name: the name is editable, and a rename would
/// orphan every row silently.
struct Booking: Identifiable, Codable {
    let id: String
    /// Written by the app in piece two from Provider, Number, From and To, so
    /// it is never typed and never drifts from the fields it describes. A
    /// hand-added row may carry anything, including nothing.
    var name: String
    /// An open String, not an enum, for `Endeavor.type`'s reason (D10): a Kind
    /// option added in Notion must render rather than crash. Both functions
    /// over it in `BookingKind` are total, with a default.
    var kind: String
    /// The endeavor slug, matched exactly against `Endeavor.id`.
    var endeavorID: String
    /// Notion relation ids into the People database, like `Visit.peopleIDs`.
    var whoIDs: [String]
    var start: Date?
    var end: Date?
    /// Whether Notion's `start` carried a clock time rather than being a bare
    /// date. A date-only booking still has a real `start`, so `start != nil`
    /// cannot answer this, and a row that asked it would print "12:00 AM" as
    /// if midnight meant something.
    var hasTime: Bool
    var from: String?
    var to: String?
    var provider: String?
    var number: String?
    var confirmation: String?
    var notes: String?
    var cost: Double?
    var booked: Bool
    /// The ledger's own state: Quoted, Accepted, Declined, or nil (D268,
    /// Session 87).
    ///
    /// **Not `booked` under another name.** `booked` says a reservation is
    /// confirmed and its false state is a to-do - NOT BOOKED is the row you are
    /// looking for on an itinerary. A ledger asks a different question with
    /// three answers, and a checkbox cannot say which of the last two a false
    /// means: a declined quote and an undecided one would look identical.
    ///
    /// An open String for `kind`'s reason (D10): a select option added in
    /// Notion must render rather than crash. `BookingStatus` below is total
    /// over it.
    var status: String?
}

/// What a ledger row's Status MEANS, total over `String`.
///
/// Three cases and a default, for `BookingKind`'s reason: Status is a Notion
/// select and a fourth option can be added to it in ten seconds. Nothing here
/// switches exhaustively over an enum, so a new word renders as "no opinion"
/// rather than crashing or needing a migration.
enum BookingStatus {

    static let quoted   = "Quoted"
    static let accepted = "Accepted"
    static let declined = "Declined"

    /// The one Notion writes for a new ledger row. A quote arrives quoted.
    static let initial  = quoted

    static func isAccepted(_ status: String?) -> Bool {
        (status ?? "").lowercased() == accepted.lowercased()
    }

    static func isDeclined(_ status: String?) -> Bool {
        (status ?? "").lowercased() == declined.lowercased()
    }

    /// What the ledger row prints at its right, or nil for nothing.
    ///
    /// **Quoted prints nothing, deliberately.** It is the resting state of
    /// every row in the band, and a column that says the same word on every
    /// line is a column that says nothing. Accepted and Declined are the
    /// exceptions, and an exception is what a right-hand column is for - the
    /// same argument D267 settled for NOT BOOKED.
    static func rowLabel(_ status: String?) -> String? {
        if isAccepted(status) { return accepted }
        if isDeclined(status) { return declined }
        return nil
    }
}

/// The glyph and the colour for a booking's Kind.
///
/// Both are total functions over `String` with a default, deliberately. Kind is
/// a Notion select and an option can be added to it in ten seconds; a `switch`
/// over an enum would make that a crash or a migration.
enum BookingKind {

    /// An SF Symbol. Anything unrecognised gets a ticket, which is honest: it
    /// is a booking of some sort and we do not know which.
    static func glyph(for kind: String) -> String {
        switch kind.lowercased() {
        case "flight":     return "airplane"
        case "shuttle":    return "bus"
        case "train":      return "tram"
        case "hotel":      return "bed.double"
        case "car rental": return "car"
        case "parking":    return "parkingsign"
        default:           return "ticket"
        }
    }

    /// A `DocumentTint`, because both platforms already map those eight to
    /// colours and a ninth palette would be a ninth thing to keep in step.
    ///
    /// **Parking is teal, not amber.** The brief asked for an orange shuttle
    /// and an amber parking sign, and `DocumentTint` has exactly one warm case,
    /// `amber`, which the Mac renders as orange. The shuttle keeps it, because
    /// that is the row on the mockup that was approved; parking takes the one
    /// unused case rather than becoming the shuttle's twin.
    static func tint(for kind: String) -> DocumentTint {
        switch kind.lowercased() {
        case "flight":     return .blue
        case "shuttle":    return .amber
        case "train":      return .red
        case "hotel":      return .indigo
        case "car rental": return .green
        case "parking":    return .teal
        default:           return .gray
        }
    }


    // MARK: What a Kind means for the sheet (D267)

    /// Journeys move you between two places; stays put you at one. `Other` is
    /// neither and is its own group on purpose.
    ///
    /// This is the rule David chose for what happens when the Kind changes
    /// mid-edit: **keep a value when it still means the same thing.** Flight to
    /// Shuttle keeps DEN and ORD, because a shuttle has a From and a To exactly
    /// like a flight. Flight to Hotel clears them, because offering "ORD" as
    /// the name of a hotel is worse than an empty field.
    enum Group { case journey, stay, other }

    static func group(for kind: String) -> Group {
        switch kind.lowercased() {
        case "flight", "shuttle", "train", "car rental": return .journey
        case "hotel", "parking":                         return .stay
        default:                                         return .other
        }
    }

    /// What the sheet's fields are CALLED for this kind. The thirteen columns
    /// underneath never change; only these words do (D267).
    ///
    /// `from` is optional because a hotel has no From. A nil label means the
    /// field is not shown at all, rather than shown with a word that does not
    /// apply to it.
    struct Labels {
        let start: String
        let end: String
        let from: String?
        let to: String
        let provider: String
        let number: String
    }

    static func labels(for kind: String) -> Labels {
        switch kind.lowercased() {
        case "flight":
            return Labels(start: "Departs", end: "Arrives", from: "From", to: "To",
                          provider: "Airline", number: "Flight")
        case "hotel":
            return Labels(start: "Check in", end: "Check out", from: nil, to: "Where",
                          provider: "Brand", number: "Room")
        case "car rental":
            return Labels(start: "Pick up", end: "Drop off", from: "Pick up at", to: "Drop off at",
                          provider: "Company", number: "Reservation")
        case "parking":
            return Labels(start: "Starts", end: "Ends", from: nil, to: "Where",
                          provider: "Operator", number: "Space")
        default:
            return Labels(start: "Starts", end: "Ends", from: "From", to: "To",
                          provider: "Provider", number: "Number")
        }
    }

    /// One field of the booking sheet and what it is, in this Kind's own words.
    ///
    /// Lives here rather than in the view for the reason `labels`, `group` and
    /// `writtenName` do: the phone's sheet has to say the same thing, and help
    /// text authored twice is help text that disagrees with itself the first
    /// time a field changes.
    struct FieldHelp: Identifiable {
        let label: String
        let text: String
        var id: String { label }
    }

    /// The booking sheet's fields, in the sheet's order, with what each is
    /// (D278, Session 87).
    ///
    /// David: *"a little i for information about every field to explain what it
    /// is if i ever forget this."*
    ///
    /// **Written per Kind because the labels are.** Six of these are renamed by
    /// `labels(for:)` — Departs/Check in, From/Pick up at, Airline/Brand — and
    /// help text that said "Airline" on a hotel would be worse than none. The
    /// list is built from the same `Labels` the sheet renders, so the two
    /// cannot describe different fields.
    ///
    /// **Where a field's meaning is really a rule about somewhere else, it is
    /// said in one clause** — a cost with no date makes a ledger row, Status is
    /// three-valued because a quote is. That is the part you forget while
    /// looking at the sheet, and the sheet is where you are.
    static func help(for kind: String) -> [FieldHelp] {
        let l = labels(for: kind)
        var nameParts = [l.provider, l.number]
        if let from = l.from { nameParts.append(from) }
        nameParts.append(l.to)
        let builtFrom = nameParts.joined(separator: ", ")

        var out: [FieldHelp] = [
            FieldHelp(label: "Kind", text: "Which of the seven this is. It changes what the fields below are CALLED and nothing else — the same fourteen columns are saved either way."),
            FieldHelp(label: "Who", text: "Who is on it. This endeavor's people are listed first; the search finds anyone else in People, and offers to create a name it does not know."),
            FieldHelp(label: "Has a date", text: "Off saves no date at all. A row with a cost and no date is what the QUOTES band on the endeavor is built from, so this is the switch between an itinerary line and a quote you are still choosing."),
            FieldHelp(label: "Include times", text: "Off saves the day without an hour. For a hotel night, or anything where the time is not the point."),
            FieldHelp(label: l.start, text: "When it begins."),
            FieldHelp(label: l.end, text: "When it ends. The toggle above removes it for a booking with only one end.")
        ]
        if let from = l.from {
            out.append(FieldHelp(label: from, text: "Where it starts from."))
        }
        out += [
            FieldHelp(label: l.to, text: "Where it goes — or, for a stay, where it is."),
            FieldHelp(label: l.provider, text: "Who is providing it. On a quote this is the contractor."),
            FieldHelp(label: l.number, text: "Their reference for the thing itself — the one printed on the ticket or the door. On a quote it is the job number."),
            FieldHelp(label: "Confirmation", text: "The booking reference you would read out on the phone. Separate from \(l.number) because the two are rarely the same string."),
            FieldHelp(label: "Cost", text: "What it costs. A cost with no date is what puts the row in QUOTES rather than on the schedule."),
            FieldHelp(label: "Booked", text: "Whether it is actually reserved. On an itinerary the row you are looking for is the UNbooked one, which is why this stays a plain checkbox."),
            FieldHelp(label: "Status", text: "Quoted, Accepted or Declined, for an option you are still deciding between. A checkbox has two states and a quote has three, which is why this is not Booked. Leave it None on anything already settled."),
            FieldHelp(label: "Notes", text: "Anything else."),
            FieldHelp(label: "Will save as", text: "The Name the app writes for you, built from \(builtFrom). It is the one field you cannot type, shown here so it is never a surprise.")
        ]
        return out
    }

    /// The Name the APP writes, so it is never typed and never drifts from the
    /// fields it describes (D267).
    ///
    /// **Descriptive rather than short.** Session 86 nearly wrote a rule for
    /// abbreviating these, because "Landline · Fort Collins → DEN" clipped on
    /// the 248pt rail. D268 moved the rows into the body at full width and the
    /// clipping went with it, so the reason to abbreviate is gone. Fixing the
    /// data to suit a layout that has since changed is how a name ends up
    /// wrong everywhere to look right in one place.
    static func writtenName(kind: String,
                            provider: String,
                            number: String,
                            from: String,
                            to: String,
                            start: Date?,
                            end: Date?) -> String {
        let provider = provider.trimmingCharacters(in: .whitespacesAndNewlines)
        let number   = number.trimmingCharacters(in: .whitespacesAndNewlines)
        let from     = from.trimmingCharacters(in: .whitespacesAndNewlines)
        let to       = to.trimmingCharacters(in: .whitespacesAndNewlines)

        func joined(_ parts: [String]) -> String {
            parts.filter { !$0.isEmpty }.joined(separator: " · ")
        }

        let name: String
        switch group(for: kind) {
        case .journey:
            // "UA 1642 · DEN → ORD", and "Landline · Fort Collins → DEN" for a
            // shuttle that has a provider and no number.
            let lead  = number.isEmpty ? provider : number
            let route = from.isEmpty || to.isEmpty ? joined([from, to]) : "\(from) → \(to)"
            name = joined([lead, route])
        case .stay:
            // "Lakemore Resort · 7 nights".
            // Falls through to the kind. David created a hotel with neither
            // a Brand nor a Where and got a row headed "4 nights", which reads
            // as a fragment rather than a subject.
            let lead = provider.isEmpty ? (to.isEmpty ? kind : to) : provider
            let nights: Int = {
                guard let start, let end else { return 0 }
                let cal = Calendar.current
                let days = cal.dateComponents([.day],
                                              from: cal.startOfDay(for: start),
                                              to: cal.startOfDay(for: end)).day ?? 0
                return max(days, 0)
            }()
            name = nights > 0 ? joined([lead, nights == 1 ? "1 night" : "\(nights) nights"]) : lead
        case .other:
            name = joined([provider, to])
        }
        // Never empty. A row with no subject on screen is worse than one named
        // after its kind.
        return name.isEmpty ? kind : name
    }
}
