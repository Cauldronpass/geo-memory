import Foundation
import Observation

@Observable
class NotionService {
    static let shared = NotionService()

    var places: [Place] = []
    var visits: [Visit] = []
    var captures: [Capture] = []
    var people: [Person] = []
    var workouts: [Workout] = []
    var dayNotes: [DayNote] = []
    var personDetailCache: [String: PersonDetail] = [:]
    var isLoading = false
    var error: String?

    private let placesDBID = "3edc903daeaa41eaa82f93fb0ec55e60"
    private let visitsDBID = "ecd8cdc617e74c78b090afc5092cbdee"
    private let capturesDBID = "7e292efac9754d7f8e5fceef5e9dc0e2"
    private let peopleDBID = "50261ebf9c3c49bc926542e3ccfaa4aa"
    private let workoutsDBID = "b7dab8c1a46542ab83c442e1b76f002a"
    private let dayNotesDBID = "da0768bf98ae4ab09e341a80131d4b52"
    private let notionVersion = "2022-06-28"
    private let baseURL = "https://api.notion.com/v1"

    // Stored in the shared App Group suite so the TraceWidget extension can read it.
    // App Group "group.com.david.trace" must be enabled on both targets in Xcode.
    private var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: "group.com.david.trace") ?? .standard
    }

    var token: String {
        get {
            // Read from shared suite first
            if let t = sharedDefaults.string(forKey: "notion_token"), !t.isEmpty {
                return t
            }
            // One-time migration: pull from standard defaults (pre-App-Group installs)
            if let legacy = UserDefaults.standard.string(forKey: "notion_token"), !legacy.isEmpty {
                sharedDefaults.set(legacy, forKey: "notion_token")
                UserDefaults.standard.removeObject(forKey: "notion_token")
                return legacy
            }
            return ""
        }
        set { sharedDefaults.set(newValue, forKey: "notion_token") }
    }

    private var headers: [String: String] {
        [
            "Authorization": "Bearer \(token)",
            "Notion-Version": notionVersion,
            "Content-Type": "application/json"
        ]
    }

    func fetchPlaces() async {
        isLoading = true
        do {
            var allPlaces: [Place] = []
            var cursor: String? = nil
            repeat {
                var body: [String: Any] = [
                    "filter": [
                        "and": [
                            ["property": "Status", "select": ["does_not_equal": "Archived"]],
                            ["property": "Temporary", "checkbox": ["equals": false]]
                        ]
                    ],
                    "sorts": [["property": "Name", "direction": "ascending"]],
                    "page_size": 100
                ]
                if let cursor { body["start_cursor"] = cursor }
                let data = try await post("\(baseURL)/databases/\(placesDBID)/query", body: body)
                let result = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                let pages = result["results"] as? [[String: Any]] ?? []
                allPlaces += pages.compactMap { parsePage($0) }
                cursor = result["has_more"] as? Bool == true ? result["next_cursor"] as? String : nil
            } while cursor != nil
            places = allPlaces
            isLoading = false
        } catch {
            self.error = error.localizedDescription
            isLoading = false
        }
    }

    func fetchVisits() async {
        if visits.isEmpty { isLoading = true }
        do {
            var allVisits: [Visit] = []
            var cursor: String? = nil
            repeat {
                var body: [String: Any] = [
                    "sorts": [["property": "Date Visited", "direction": "descending"]],
                    "page_size": 100
                ]
                if let cursor { body["start_cursor"] = cursor }
                let data = try await post("\(baseURL)/databases/\(visitsDBID)/query", body: body)
                let result = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                let pages = result["results"] as? [[String: Any]] ?? []
                allVisits += pages.compactMap { parseVisit($0) }
                cursor = result["has_more"] as? Bool == true ? result["next_cursor"] as? String : nil
            } while cursor != nil
            visits = allVisits
            isLoading = false
        } catch {
            self.error = error.localizedDescription
            isLoading = false
        }
    }

    func fetchCaptures() async {
        do {
            var allCaptures: [Capture] = []
            var cursor: String? = nil
            repeat {
                var body: [String: Any] = [
                    "filter": [
                        "property": "Status",
                        "select": ["equals": "Unlinked"]
                    ],
                    "sorts": [["property": "Timestamp", "direction": "descending"]],
                    "page_size": 100
                ]
                if let cursor { body["start_cursor"] = cursor }
                let data = try await post("\(baseURL)/databases/\(capturesDBID)/query", body: body)
                let result = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                let pages = result["results"] as? [[String: Any]] ?? []
                allCaptures += pages.compactMap { parseCapture($0) }
                cursor = result["has_more"] as? Bool == true ? result["next_cursor"] as? String : nil
            } while cursor != nil
            captures = allCaptures
        } catch {
            self.error = error.localizedDescription
        }
    }

    func checkIn(place: Place, rating: Int? = nil, notes: String? = nil, date: Date = Date(), people: [String]? = nil) async throws -> String {
        var props: [String: Any] = [
            "Name": ["title": [["text": ["content": place.name]]]],
            "Date Visited": ["date": ["start": localDateString(from: date)]],
            "Place": ["relation": [["id": place.id]]]
        ]
        if let rating { props["Rating"] = ["number": rating] }
        if let notes { props["Notes"] = ["rich_text": [["text": ["content": notes]]]] }
        if let people, !people.isEmpty {
            props["Companion"] = ["relation": people.map { ["id": $0] }]
        }
        let body: [String: Any] = [
            "parent": ["database_id": visitsDBID],
            "properties": props
        ]
        let data = try await post("\(baseURL)/pages", body: body)
        let result = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        return result["id"] as? String ?? ""
    }

    /// Returns the new page ID.
    @discardableResult
    func addPlace(name: String, address: String, city: String, category: String,
                  latitude: Double, longitude: Double, googlePlaceID: String?,
                  phone: String?, website: String?, status: String = "Visited",
                  expires: Date? = nil, notes: String? = nil, flagged: Bool = false,
                  temporary: Bool = false)
        async throws -> String {
        var props: [String: Any] = [
            "Name": ["title": [["text": ["content": name]]]],
            "Address": ["rich_text": [["text": ["content": address]]]],
            "City": ["rich_text": [["text": ["content": city]]]],
            "Category": ["select": ["name": category]],
            "Latitude": ["number": latitude],
            "Longitude": ["number": longitude],
            "Status": ["select": ["name": status]],
            "Flagged": ["checkbox": flagged]
        ]
        if temporary { props["Temporary"] = ["checkbox": true] }
        if let googlePlaceID { props["Google Place ID"] = ["rich_text": [["text": ["content": googlePlaceID]]]] }
        if let phone { props["Phone"] = ["phone_number": phone] }
        if let website { props["Website"] = ["url": website] }
        if let notes, !notes.isEmpty { props["Notes Raw"] = ["rich_text": [["text": ["content": notes]]]] }
        if let expires {
            let iso = ISO8601DateFormatter()
            props["Expires"] = ["date": ["start": iso.string(from: expires)]]
        }
        let body: [String: Any] = [
            "parent": ["database_id": placesDBID],
            "properties": props
        ]
        let data = try await post("\(baseURL)/pages", body: body)
        let result = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        return result["id"] as? String ?? ""
    }

    /// Appends a photo URL to the "Photo URLs" rich_text field on any page (visit or place).
    func addPhotoToPage(_ pageID: String, photoURL: String) async throws {
        // Fetch current Photo URLs
        let pageData = try await get("\(baseURL)/pages/\(pageID)")
        let pageResult = try JSONSerialization.jsonObject(with: pageData) as! [String: Any]
        let props = pageResult["properties"] as? [String: Any] ?? [:]
        let existingURLs = ((props["Photo URLs"] as? [String: Any])?["rich_text"] as? [[String: Any]] ?? [])
            .compactMap { ($0["text"] as? [String: Any])?["content"] as? String }
            .filter { !$0.isEmpty && $0 != "\n" }
        let allURLs = existingURLs + [photoURL]
        var rtArray: [[String: Any]] = []
        for (i, u) in allURLs.enumerated() {
            if i > 0 { rtArray.append(["type": "text", "text": ["content": "\n"]]) }
            rtArray.append(["type": "text", "text": ["content": u, "link": ["url": u]]])
        }
        _ = try await patch("\(baseURL)/pages/\(pageID)", body: [
            "properties": ["Photo URLs": ["rich_text": rtArray]]
        ])
        // Update local visit cache if applicable
        if let idx = visits.firstIndex(where: { $0.id == pageID }) {
            visits[idx].photoURLs = allURLs
        }
    }

    func updatePlace(_ place: Place, name: String, category: String, status: String,
                     tags: [String]? = nil, city: String? = nil, notes: String? = nil) async throws {
        var props: [String: Any] = [
            "Name": ["title": [["text": ["content": name]]]],
            "Category": ["select": ["name": category]],
            "Status": ["select": ["name": status]]
        ]
        if let tags { props["Tags"] = ["multi_select": tags.map { ["name": $0] }] }
        if let city { props["City"] = ["rich_text": [["text": ["content": city]]]] }
        if let notes { props["Notes Raw"] = ["rich_text": [["text": ["content": notes]]]] }
        _ = try await patch("\(baseURL)/pages/\(place.id)", body: ["properties": props])
        if let i = places.firstIndex(where: { $0.id == place.id }) {
            places[i].name = name
            places[i].category = category
            places[i].status = status
            if let tags  { places[i].tags  = tags  }
            if let city  { places[i].city  = city  }
            if let notes { places[i].notes = notes }
        }
    }

    /// Re-enriches a place record using fresh Google Places data.
    /// Updates name, address, city, coordinates, place ID, phone, website, hours, rating, and maps URL.
    func enrichPlace(_ place: Place, from googlePlace: GooglePlace) async throws {
        let mapsURL = "https://maps.google.com/?place_id=\(googlePlace.id)"
        var props: [String: Any] = [
            "Name":             ["title": [["text": ["content": googlePlace.name]]]],
            "Address":          ["rich_text": [["text": ["content": googlePlace.formattedAddress]]]],
            "City":             ["rich_text": [["text": ["content": googlePlace.city]]]],
            "Latitude":         ["number": googlePlace.latitude],
            "Longitude":        ["number": googlePlace.longitude],
            "Google Place ID":  ["rich_text": [["text": ["content": googlePlace.id]]]],
            "Google Maps URL":  ["url": mapsURL],
            "Enrichment Status": ["select": ["name": "Enriched"]]
        ]
        if let phone = googlePlace.phone, !phone.isEmpty {
            props["Phone"] = ["phone_number": phone]
        }
        if let website = googlePlace.website, !website.isEmpty {
            props["Website"] = ["url": website]
        }
        if !googlePlace.weekdayDescriptions.isEmpty {
            props["Hours"] = ["rich_text": [["text": ["content": googlePlace.weekdayDescriptions.joined(separator: "\n")]]]]
        }
        if let rating = googlePlace.rating {
            props["Rating External"] = ["number": rating]
        }
        _ = try await patch("\(baseURL)/pages/\(place.id)", body: ["properties": props])
        // Update local cache
        if let i = places.firstIndex(where: { $0.id == place.id }) {
            places[i].name           = googlePlace.name
            places[i].address        = googlePlace.formattedAddress
            places[i].city           = googlePlace.city
            places[i].latitude       = googlePlace.latitude
            places[i].longitude      = googlePlace.longitude
            places[i].googlePlaceID  = googlePlace.id
            places[i].googleMapsURL  = mapsURL
            if let phone = googlePlace.phone, !phone.isEmpty { places[i].phone = phone }
            if let website = googlePlace.website, !website.isEmpty { places[i].website = website }
            if !googlePlace.weekdayDescriptions.isEmpty {
                places[i].hours = googlePlace.weekdayDescriptions.joined(separator: "\n")
            }
            if let rating = googlePlace.rating { places[i].ratingExternal = rating }
        }
    }

    func markPlaceForReview(_ place: Place) async throws {
        let body: [String: Any] = ["properties": ["Enrichment Status": ["select": ["name": "Needs Review"]]]]
        _ = try await patch("\(baseURL)/pages/\(place.id)", body: body)
    }

    func archivePlace(_ place: Place) async throws {
        let body: [String: Any] = ["properties": ["Status": ["select": ["name": "Archived"]]]]
        _ = try await patch("\(baseURL)/pages/\(place.id)", body: body)
        if let i = places.firstIndex(where: { $0.id == place.id }) {
            places[i].status = "Archived"
        }
    }

    func clearReviewFlag(_ place: Place) async throws {
        let body: [String: Any] = ["properties": ["Enrichment Status": ["select": ["name": "Enriched"]]]]
        _ = try await patch("\(baseURL)/pages/\(place.id)", body: body)
        if let i = places.firstIndex(where: { $0.id == place.id }) {
            places[i].enrichmentStatus = "Enriched"
        }
    }

    func toggleFlagged(_ place: Place) async throws {
        let body: [String: Any] = ["properties": ["Flagged": ["checkbox": !place.flagged]]]
        _ = try await patch("\(baseURL)/pages/\(place.id)", body: body)
        if let index = places.firstIndex(where: { $0.id == place.id }) {
            places[index].flagged = !place.flagged
        }
    }

    func updateVisit(_ visit: Visit, rating: Int?, notes: String?, date: Date? = nil, people: [String]? = nil) async throws {
        var props: [String: Any] = [:]
        props["Rating"] = rating != nil ? ["number": rating!] : ["number": NSNull()]
        props["Notes"] = ["rich_text": [["text": ["content": notes ?? ""]]]]
        if let date {
            props["Date Visited"] = ["date": ["start": localDateString(from: date)]]
        }
        if let people {
            props["Companion"] = ["relation": people.map { ["id": $0] }]
        }
        let body: [String: Any] = ["properties": props]
        _ = try await patch("\(baseURL)/pages/\(visit.id)", body: body)
        if let index = visits.firstIndex(where: { $0.id == visit.id }) {
            visits[index].rating = rating
            visits[index].notes = notes?.isEmpty == true ? nil : notes
            if let date { visits[index].date = date }
            if let people { visits[index].peopleIDs = people }
        }
    }

    func skipVisitEnrichment(_ visit: Visit) async throws {
        let body: [String: Any] = ["properties": ["Skip Enrichment": ["checkbox": true]]]
        _ = try await patch("\(baseURL)/pages/\(visit.id)", body: body)
        if let index = visits.firstIndex(where: { $0.id == visit.id }) {
            visits[index].skipEnrichment = true
        }
    }

    func saveCapture(notes: String, placeID: String?, placeName: String?, lat: Double?, lon: Double?, photoURL: String? = nil) async throws {
        var props: [String: Any] = [
            "Name": ["title": [["text": ["content": placeName ?? "Capture"]]]],
            "Notes": ["rich_text": [["text": ["content": notes]]]],
            "Timestamp": ["date": ["start": ISO8601DateFormatter().string(from: Date())]],
            "Status": ["select": ["name": "Unlinked"]]
        ]
        if let lat { props["GPS Lat"] = ["number": lat] }
        if let lon { props["GPS Lon"] = ["number": lon] }
        if let placeID { props["Place"] = ["relation": [["id": placeID]]] }
        if let photoURL { props["Photo URL"] = ["url": photoURL] }
        let body: [String: Any] = [
            "parent": ["database_id": capturesDBID],
            "properties": props
        ]
        _ = try await post("\(baseURL)/pages", body: body)
    }

    func fetchPeople() async {
        guard let data = try? await post("\(baseURL)/databases/\(peopleDBID)/query",
                                         body: ["sorts": [["property": "Name", "direction": "ascending"]], "page_size": 200]) else { return }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pages = json["results"] as? [[String: Any]] else { return }
        people = pages.compactMap { page -> Person? in
            guard let id = page["id"] as? String,
                  let props = page["properties"] as? [String: Any],
                  let name = title(props["Name"]) else { return nil }
            let relationship = select(props["Relationship"])
            return Person(id: id, name: name, relationship: relationship)
        }
    }

    // MARK: - Workouts

    func fetchWorkouts() async {
        do {
            var all: [Workout] = []
            var cursor: String? = nil
            repeat {
                var body: [String: Any] = [
                    "sorts": [["property": "Date", "direction": "descending"]],
                    "page_size": 100
                ]
                if let cursor { body["start_cursor"] = cursor }
                let data = try await post("\(baseURL)/databases/\(workoutsDBID)/query", body: body)
                let result = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                let pages = result["results"] as? [[String: Any]] ?? []
                all += pages.compactMap { parseWorkout($0) }
                cursor = result["has_more"] as? Bool == true ? result["next_cursor"] as? String : nil
            } while cursor != nil
            workouts = all
        } catch {
            self.error = error.localizedDescription
        }
    }

    func logWorkout(_ w: WorkoutDraft) async throws -> String {
        var props: [String: Any] = [
            "Name": ["title": [["text": ["content": w.name]]]],
            "Type": ["select": ["name": w.type]]
        ]
        if let d = w.date {
            props["Date"] = ["date": ["start": localDateString(from: d)]]
        }
        func num(_ val: Int?, key: String) { if let v = val { props[key] = ["number": v] } }
        func numD(_ val: Double?, key: String) { if let v = val { props[key] = ["number": v] } }
        func txt(_ val: String?, key: String) { if let v = val, !v.isEmpty { props[key] = ["rich_text": [["text": ["content": v]]]] } }
        func rel(_ id: String?, key: String) { if let id { props[key] = ["relation": [["id": id]]] } }

        num(w.duration,     key: "Duration")
        num(w.calories,     key: "Calories")
        num(w.heartRateAvg, key: "Heart Rate Avg")
        num(w.heartRateMax, key: "Heart Rate Max")
        num(w.splatPoints,  key: "Splat Points")
        num(w.output,       key: "Output")
        num(w.zone1,        key: "Zone 1")
        num(w.zone2,        key: "Zone 2")
        num(w.zone3,        key: "Zone 3")
        num(w.zone4,        key: "Zone 4")
        num(w.zone5,        key: "Zone 5")
        num(w.feel,         key: "Feel")
        numD(w.distance,    key: "Distance")
        txt(w.notes,        key: "Notes")
        rel(w.placeID,      key: "Place")
        rel(w.visitID,      key: "Visit")
        if let ct = w.classType, !ct.isEmpty { props["Class Type"] = ["select": ["name": ct]] }
        num(w.steps,          key: "Steps")
        numD(w.elevation,     key: "Elevation")
        txt(w.treadPace,      key: "Tread Pace")
        if let hr = w.hasRower { props["Has Rower"] = ["checkbox": hr] }
        num(w.rowerDistance,  key: "Rower Distance")
        num(w.rowerWattsAvg,  key: "Rower Watts Avg")
        txt(w.rowerPace,      key: "Rower Pace 500m")
        num(w.rowerStrokeAvg, key: "Rower Stroke Avg")

        let body: [String: Any] = [
            "parent": ["database_id": workoutsDBID],
            "properties": props
        ]
        let data = try await post("\(baseURL)/pages", body: body)
        let result = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let id = result["id"] as? String ?? ""
        await fetchWorkouts()
        return id
    }

    func updateWorkoutFeel(_ pageID: String, feel: Int) async throws {
        let body: [String: Any] = ["properties": ["Feel": ["number": feel]]]
        _ = try await patch("\(baseURL)/pages/\(pageID)", body: body)
        if let idx = workouts.firstIndex(where: { $0.id == pageID }) {
            workouts[idx].feel = feel
        }
    }

    func updateWorkoutNotes(_ pageID: String, notes: String) async throws {
        let props: [String: Any] = notes.isEmpty
            ? ["Notes": ["rich_text": []]]
            : ["Notes": ["rich_text": [["text": ["content": notes]]]]]
        let body: [String: Any] = ["properties": props]
        _ = try await patch("\(baseURL)/pages/\(pageID)", body: body)
        // Refresh local copy
        if let idx = workouts.firstIndex(where: { $0.id == pageID }) {
            workouts[idx].notes = notes.isEmpty ? nil : notes
        }
    }

    private func parseWorkout(_ page: [String: Any]) -> Workout? {
        guard let id = page["id"] as? String,
              let props = page["properties"] as? [String: Any] else { return nil }

        func num(_ prop: Any?) -> Int? {
            guard let n = (prop as? [String: Any])?["number"] as? Double else { return nil }
            return Int(n)
        }
        func numD(_ prop: Any?) -> Double? {
            return (prop as? [String: Any])?["number"] as? Double
        }

        let date: Date = {
            guard let s = ((props["Date"] as? [String: Any])?["date"] as? [String: Any])?["start"] as? String
            else { return Date() }
            return notionDate(from: s) ?? Date()
        }()

        let placeID = ((props["Place"] as? [String: Any])?["relation"] as? [[String: Any]])?.first?["id"] as? String
        let visitID = ((props["Visit"] as? [String: Any])?["relation"] as? [[String: Any]])?.first?["id"] as? String

        let hasRower = (props["Has Rower"] as? [String: Any])?["checkbox"] as? Bool

        return Workout(
            id: id,
            name: title(props["Name"]) ?? "",
            date: date,
            type: select(props["Type"]) ?? "Other",
            duration:     num(props["Duration"]),
            calories:     num(props["Calories"]),
            heartRateAvg: num(props["Heart Rate Avg"]),
            heartRateMax: num(props["Heart Rate Max"]),
            splatPoints:  num(props["Splat Points"]),
            output:       num(props["Output"]),
            zone1: num(props["Zone 1"]),
            zone2: num(props["Zone 2"]),
            zone3: num(props["Zone 3"]),
            zone4: num(props["Zone 4"]),
            zone5: num(props["Zone 5"]),
            distance: numD(props["Distance"]),
            feel:     num(props["Feel"]),
            notes:    richText(props["Notes"]),
            placeID:  placeID,
            visitID:  visitID,
            classType:      select(props["Class Type"]),
            steps:          num(props["Steps"]),
            elevation:      numD(props["Elevation"]),
            treadPace:      richText(props["Tread Pace"]),
            hasRower:       hasRower,
            rowerDistance:  num(props["Rower Distance"]),
            rowerWattsAvg:  num(props["Rower Watts Avg"]),
            rowerPace:      richText(props["Rower Pace 500m"]),
            rowerStrokeAvg: num(props["Rower Stroke Avg"])
        )
    }

    func addPerson(name: String) async throws -> Person {
        let body: [String: Any] = [
            "parent": ["database_id": peopleDBID],
            "properties": ["Name": ["title": [["text": ["content": name]]]]]
        ]
        let data = try await post("\(baseURL)/pages", body: body)
        let result = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let id = result["id"] as? String ?? UUID().uuidString
        let person = Person(id: id, name: name)
        people.append(person)
        people.sort { $0.name < $1.name }
        return person
    }

    func linkCapture(_ captureID: String, toVisit visitID: String, captureNotes: String = "", photoURL: String? = nil) async throws {
        // Mark capture as linked + set Visit relation in one call
        _ = try await patch("\(baseURL)/pages/\(captureID)", body: ["properties": [
            "Status": ["select": ["name": "Linked"]],
            "Visit": ["relation": [["id": visitID]]]
        ]])

        // Fetch visit once if we need to update either field
        let needsFetch = !captureNotes.isEmpty || photoURL != nil
        var visitProps: [String: Any] = [:]
        if needsFetch {
            let visitData = try await get("\(baseURL)/pages/\(visitID)")
            let visitResult = try JSONSerialization.jsonObject(with: visitData) as! [String: Any]
            visitProps = visitResult["properties"] as? [String: Any] ?? [:]
        }

        // Append capture notes text to Notes field (no photo URL here)
        if !captureNotes.isEmpty {
            let existing = richText(visitProps["Notes"]) ?? ""
            let appended = existing.isEmpty ? captureNotes : "\(existing)\n\(captureNotes)"
            _ = try await patch("\(baseURL)/pages/\(visitID)", body: [
                "properties": ["Notes": ["rich_text": [["text": ["content": String(appended.prefix(2000))]]]]]
            ])
            if let idx = visits.firstIndex(where: { $0.id == visitID }) {
                visits[idx].notes = appended
            }
        }

        // Append photo URL to "Photo URLs" as clickable rich_text links
        if let url = photoURL {
            let existingURLs = ((visitProps["Photo URLs"] as? [String: Any])?["rich_text"] as? [[String: Any]] ?? [])
                .compactMap { ($0["text"] as? [String: Any])?["content"] as? String }
                .filter { !$0.isEmpty && $0 != "\n" }
            let allURLs = existingURLs + [url]

            // Build rich_text array: each URL as a clickable link, separated by newlines
            var rtArray: [[String: Any]] = []
            for (i, u) in allURLs.enumerated() {
                if i > 0 { rtArray.append(["type": "text", "text": ["content": "\n"]]) }
                rtArray.append(["type": "text", "text": ["content": u, "link": ["url": u]]])
            }
            _ = try await patch("\(baseURL)/pages/\(visitID)", body: [
                "properties": ["Photo URLs": ["rich_text": rtArray]]
            ])
            if let idx = visits.firstIndex(where: { $0.id == visitID }) {
                visits[idx].photoURLs = allURLs
            }
        }

        captures.removeAll { $0.id == captureID }
    }

    /// Fetches captures linked to a specific place that have GPS coordinates (for Place-level Spots Map).
    func fetchCapturesForPlace(placeID: String) async throws -> [Capture] {
        let body: [String: Any] = [
            "filter": [
                "and": [
                    ["property": "Place", "relation": ["contains": placeID]],
                    ["property": "GPS Lat", "number": ["is_not_empty": true]]
                ]
            ],
            "sorts": [["property": "Timestamp", "direction": "ascending"]],
            "page_size": 100
        ]
        let data = try await post("\(baseURL)/databases/\(capturesDBID)/query", body: body)
        let result = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let pages = result["results"] as? [[String: Any]] ?? []
        return pages.compactMap { parseCapture($0) }
    }

    /// Appends a timestamped note to a capture's Notes field.
    func appendCaptureNotes(id: String, text: String) async throws {
        let data = try await get("\(baseURL)/pages/\(id)")
        let result = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let props = result["properties"] as? [String: Any] ?? [:]
        let existing = richText(props["Notes"]) ?? ""
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        let stamp = formatter.string(from: Date())
        let combined = existing.isEmpty ? "[\(stamp)] \(text)" : "\(existing)\n[\(stamp)] \(text)"
        _ = try await patch("\(baseURL)/pages/\(id)", body: [
            "properties": ["Notes": ["rich_text": [["text": ["content": String(combined.prefix(2000))]]]]]
        ])
    }

    /// Fetches captures linked to a specific visit that have GPS coordinates (for Spots Map).
    func fetchCapturesForVisit(visitID: String) async throws -> [Capture] {
        let body: [String: Any] = [
            "filter": [
                "and": [
                    ["property": "Visit", "relation": ["contains": visitID]],
                    ["property": "GPS Lat", "number": ["is_not_empty": true]]
                ]
            ],
            "sorts": [["property": "Timestamp", "direction": "ascending"]],
            "page_size": 100
        ]
        let data = try await post("\(baseURL)/databases/\(capturesDBID)/query", body: body)
        let result = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let pages = result["results"] as? [[String: Any]] ?? []
        return pages.compactMap { parseCapture($0) }
    }

    func dismissCapture(_ captureID: String) async throws {
        let props: [String: Any] = ["Status": ["select": ["name": "Standalone"]]]
        _ = try await patch("\(baseURL)/pages/\(captureID)", body: ["properties": props])
        captures.removeAll { $0.id == captureID }
    }

    func deleteCapture(_ captureID: String) async throws {
        let body: [String: Any] = ["archived": true]
        _ = try await patch("\(baseURL)/pages/\(captureID)", body: body)
        captures.removeAll { $0.id == captureID }
    }

    func appendToPlaceNotes(placeID: String, text: String) async throws {
        let data = try await get("\(baseURL)/pages/\(placeID)")
        let result = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let props = result["properties"] as? [String: Any] ?? [:]
        let existing = richText(props["Notes Raw"]) ?? ""
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        let stamp = formatter.string(from: Date())
        let combined = existing.isEmpty ? "[\(stamp)] \(text)" : "\(existing)\n[\(stamp)] \(text)"
        let body: [String: Any] = [
            "properties": [
                "Notes Raw": ["rich_text": [["text": ["content": combined]]]]
            ]
        ]
        _ = try await patch("\(baseURL)/pages/\(placeID)", body: body)
    }

    // MARK: - People detail, enrich, notes

    func fetchPersonDetail(id: String) async throws -> PersonDetail {
        if let cached = personDetailCache[id] { return cached }
        let data = try await get("\(baseURL)/pages/\(id)")
        let result = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let detail = parsePersonDetail(result)
        personDetailCache[id] = detail
        return detail
    }

    func enrichPerson(id: String,
                      relationship: String?,
                      relationshipStrength: String?,
                      companyContext: String?,
                      city: String?,
                      howWeMet: String?,
                      tags: [String],
                      phone: String? = nil,
                      email: String? = nil,
                      address: String? = nil,
                      photoURL: String? = nil) async throws {
        var props: [String: Any] = [:]
        if let r = relationship {
            props["Relationship"] = r.isEmpty ? ["select": NSNull()] : ["select": ["name": r]]
        }
        if let rs = relationshipStrength, !rs.isEmpty {
            props["Relationship Strength"] = ["select": ["name": rs]]
        }
        if let cc = companyContext {
            props["Company/Context"] = ["rich_text": cc.isEmpty ? [] : [["text": ["content": cc]]]]
        }
        if let c = city {
            props["City"] = ["rich_text": c.isEmpty ? [] : [["text": ["content": c]]]]
        }
        if let h = howWeMet {
            props["How We Met"] = ["rich_text": h.isEmpty ? [] : [["text": ["content": h]]]]
        }
        if let ph = phone {
            props["Phone"] = ph.isEmpty ? ["phone_number": NSNull()] : ["phone_number": ph]
        }
        if let em = email {
            props["Email"] = em.isEmpty ? ["email": NSNull()] : ["email": em]
        }
        if let ad = address {
            props["Address"] = ["rich_text": ad.isEmpty ? [] : [["text": ["content": ad]]]]
        }
        props["Tags"] = ["multi_select": tags.map { ["name": $0] }]
        if let url = photoURL {
            props["Photo"] = ["files": [["type": "external", "name": "photo.jpg", "external": ["url": url]]]]
        }
        guard !props.isEmpty else { return }
        _ = try await patch("\(baseURL)/pages/\(id)", body: ["properties": props])
        personDetailCache.removeValue(forKey: id)
    }

    /// Links (or unlinks) a person to a Place via the "Home Place" relation property.
    func linkPersonToPlace(personID: String, placeID: String?) async throws {
        let relation: Any = placeID != nil ? [["id": placeID!]] : []
        _ = try await patch("\(baseURL)/pages/\(personID)", body: [
            "properties": ["Home Place": ["relation": relation]]
        ])
        personDetailCache.removeValue(forKey: personID)
    }

    func updatePersonStatus(id: String, relationshipStrength: String) async throws {
        _ = try await patch("\(baseURL)/pages/\(id)", body: [
            "properties": ["Relationship Strength": ["select": ["name": relationshipStrength]]]
        ])
        personDetailCache.removeValue(forKey: id)
    }

    func appendPersonNotes(id: String, text: String) async throws {
        let data = try await get("\(baseURL)/pages/\(id)")
        let result = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let props = result["properties"] as? [String: Any] ?? [:]
        let existing = richText(props["Notes"]) ?? ""
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        let stamp = formatter.string(from: Date())
        let combined = existing.isEmpty ? "[\(stamp)] \(text)" : "\(existing)\n[\(stamp)] \(text)"
        _ = try await patch("\(baseURL)/pages/\(id)", body: [
            "properties": ["Notes": ["rich_text": [["text": ["content": String(combined.prefix(2000))]]]]]
        ])
        personDetailCache.removeValue(forKey: id)
    }

    private func parsePersonDetail(_ page: [String: Any]) -> PersonDetail {
        let id = page["id"] as? String ?? ""
        let props = page["properties"] as? [String: Any] ?? [:]

        // Visit Count rollup (count → number)
        let visitCount = ((props["Visit Count"] as? [String: Any])?["rollup"] as? [String: Any])?["number"] as? Int

        // Last Visit Date rollup (latest_date → date)
        let lastVisitDate: Date? = {
            guard let r = (props["Last Visit Date"] as? [String: Any])?["rollup"] as? [String: Any],
                  let d = r["date"] as? [String: Any],
                  let s = d["start"] as? String else { return nil }
            return ISO8601DateFormatter().date(from: s)
        }()

        // Last Interaction Date (regular date field)
        let lastInteractionDate = dateProp(props["Last Interaction Date"])

        // Birthday (regular date field)
        let birthday = dateProp(props["Birthday"])

        let tags = ((props["Tags"] as? [String: Any])?["multi_select"] as? [[String: Any]])?
            .compactMap { $0["name"] as? String } ?? []

        let phone = (props["Phone"] as? [String: Any])?["phone_number"] as? String
        let email = (props["Email"] as? [String: Any])?["email"] as? String
        let address = richText(props["Address"])

        // "Photo" is a Files & media property — supports both Notion-hosted and external URLs
        let photoURL: String? = {
            guard let files = (props["Photo"] as? [String: Any])?["files"] as? [[String: Any]],
                  let first = files.first else { return nil }
            if let ext = first["external"] as? [String: Any] { return ext["url"] as? String }
            if let file = first["file"] as? [String: Any] { return file["url"] as? String }
            return nil
        }()

        // Home Place relation (single linked place)
        let homePlaceID = ((props["Home Place"] as? [String: Any])?["relation"] as? [[String: Any]])?.first?["id"] as? String

        return PersonDetail(
            id: id,
            name: title(props["Name"]) ?? "",
            city: richText(props["City"]),
            companyContext: richText(props["Company/Context"]),
            relationship: select(props["Relationship"]),
            relationshipStrength: select(props["Relationship Strength"]),
            howWeMet: richText(props["How We Met"]),
            notes: richText(props["Notes"]),
            tags: tags,
            birthday: birthday,
            phone: phone,
            email: email,
            address: address,
            photoURL: photoURL,
            visitCount: visitCount,
            lastVisitDate: lastVisitDate,
            lastInteractionDate: lastInteractionDate,
            homePlaceID: homePlaceID
        )
    }

    // MARK: - Day Notes — computed index

    /// Keyed by "YYYY-M-D" (same format as CalendarGridView.dateKey).
    /// dayNotes is sorted descending (newest first), so the first entry for each key
    /// is the most recent note — `if map[key] == nil` preserves that.
    var dayNotesByDate: [String: DayNote] {
        var map: [String: DayNote] = [:]
        let cal = Calendar.current
        for note in dayNotes {
            guard let date = note.date else { continue }
            let c = cal.dateComponents([.year, .month, .day], from: date)
            guard let y = c.year, let m = c.month, let d = c.day else { continue }
            let key = "\(y)-\(m)-\(d)"
            if map[key] == nil { map[key] = note }  // keep newest per day
        }
        return map
    }

    // MARK: - Day Notes — fetch

    func fetchDayNotes() async {
        do {
            var allNotes: [DayNote] = []
            var cursor: String? = nil
            repeat {
                var body: [String: Any] = [
                    "sorts": [["property": "Date", "direction": "descending"]],
                    "page_size": 100
                ]
                if let cursor { body["start_cursor"] = cursor }
                let data = try await post("\(baseURL)/databases/\(dayNotesDBID)/query", body: body)
                let result = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                let pages = result["results"] as? [[String: Any]] ?? []
                allNotes += pages.compactMap { parseDayNote($0) }
                cursor = result["has_more"] as? Bool == true ? result["next_cursor"] as? String : nil
            } while cursor != nil
            dayNotes = allNotes.filter { $0.status != "Archived" }
        } catch {
            self.error = error.localizedDescription
        }
        await autoArchiveOldDayNotes()
    }

    func autoArchiveOldDayNotes() async {
        let cutoff = Calendar.current.date(byAdding: .day, value: -90, to: Date())!
        let toArchive = dayNotes.filter { note in
            guard let date = note.date else { return false }  // bucket notes never auto-archived
            return date < cutoff
        }
        guard !toArchive.isEmpty else { return }
        for note in toArchive {
            let props: [String: Any] = ["Status": ["select": ["name": "Archived"]]]
            try? await patch("\(baseURL)/pages/\(note.id)", body: ["properties": props])
        }
        dayNotes.removeAll { note in toArchive.contains(where: { $0.id == note.id }) }
    }

    // MARK: - Day Notes — save / update / delete

    @discardableResult
    func saveDayNote(date: Date, noteBody: String) async throws -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withFullDate]
        iso.timeZone = TimeZone.current
        let props: [String: Any] = [
            "Body": ["title": [["text": ["content": noteBody]]]],
            "Date": ["date": ["start": iso.string(from: date)]]
        ]
        let body: [String: Any] = [
            "parent": ["database_id": dayNotesDBID],
            "properties": props
        ]
        let data = try await post("\(baseURL)/pages", body: body)
        let result = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let id = result["id"] as? String ?? ""
        let note = DayNote(id: id, date: date, scope: nil, body: noteBody)
        dayNotes.insert(note, at: 0)
        return id
    }

    @discardableResult
    func saveBucketNote(scope: String, noteBody: String) async throws -> String {
        let props: [String: Any] = [
            "Body": ["title": [["text": ["content": noteBody]]]],
            "Scope": ["select": ["name": scope]]
        ]
        let body: [String: Any] = [
            "parent": ["database_id": dayNotesDBID],
            "properties": props
        ]
        let data = try await post("\(baseURL)/pages", body: body)
        let result = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let id = result["id"] as? String ?? ""
        let note = DayNote(id: id, date: nil, scope: scope, body: noteBody)
        dayNotes.append(note)
        return id
    }

    func updateDayNote(id: String, noteBody: String) async throws {
        let props: [String: Any] = [
            "Body": ["title": [["text": ["content": noteBody]]]]
        ]
        _ = try await patch("\(baseURL)/pages/\(id)", body: ["properties": props])
        if let idx = dayNotes.firstIndex(where: { $0.id == id }) {
            dayNotes[idx].body = noteBody
        }
    }

    func moveDayNote(id: String, toDate: Date) async throws {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withFullDate]
        iso.timeZone = TimeZone.current
        let props: [String: Any] = [
            "Date":  ["date": ["start": iso.string(from: toDate)]],
            "Scope": ["select": NSNull()]
        ]
        _ = try await patch("\(baseURL)/pages/\(id)", body: ["properties": props])
        if let i = dayNotes.firstIndex(where: { $0.id == id }) {
            dayNotes[i].date  = toDate
            dayNotes[i].scope = nil
        }
    }

    func moveDayNoteToBucket(id: String, scope: String) async throws {
        let props: [String: Any] = [
            "Scope": ["select": ["name": scope]],
            "Date":  ["date": NSNull()]
        ]
        _ = try await patch("\(baseURL)/pages/\(id)", body: ["properties": props])
        if let i = dayNotes.firstIndex(where: { $0.id == id }) {
            dayNotes[i].scope = scope
            dayNotes[i].date  = nil
        }
    }

    func deleteDayNote(id: String) async throws {
        _ = try await patch("\(baseURL)/pages/\(id)", body: ["archived": true])
        dayNotes.removeAll { $0.id == id }
    }

    // MARK: - Day Notes — parse

    private func parseDayNote(_ page: [String: Any]) -> DayNote? {
        guard let id = page["id"] as? String,
              let props = page["properties"] as? [String: Any] else { return nil }
        let body = title(props["Body"]) ?? ""
        guard !body.isEmpty else { return nil }

        let dateStr = (props["Date"] as? [String: Any]).flatMap {
            ($0["date"] as? [String: Any])?["start"] as? String
        }
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withFullDate]
        fmt.timeZone = TimeZone.current
        let date = dateStr.flatMap { fmt.date(from: $0) }
        // Normalize: empty string from Notion → nil; homeless notes (no date, no scope) → Inbox
        let rawScope = select(props["Scope"])
        let normalizedScope = rawScope.flatMap { $0.isEmpty ? nil : $0 }
        let status   = select(props["Status"])
        let scope = (normalizedScope == nil && date == nil) ? "Inbox" : normalizedScope

        return DayNote(id: id, date: date, scope: scope, body: body, status: status)
    }

    private func post(_ urlString: String, body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: URL(string: urlString)!)
        request.httpMethod = "POST"
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw NotionError.apiError(http.statusCode, msg)
        }
        return data
    }

    private func patch(_ urlString: String, body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: URL(string: urlString)!)
        request.httpMethod = "PATCH"
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw NotionError.apiError(http.statusCode, msg)
        }
        return data
    }

    private func get(_ urlString: String) async throws -> Data {
        var request = URLRequest(url: URL(string: urlString)!)
        request.httpMethod = "GET"
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw NotionError.apiError(http.statusCode, msg)
        }
        return data
    }

    private func parsePage(_ page: [String: Any]) -> Place? {
        guard let id = page["id"] as? String,
              let props = page["properties"] as? [String: Any] else { return nil }
        let lat = (props["Latitude"] as? [String: Any])?["number"] as? Double ?? 0
        let lon = (props["Longitude"] as? [String: Any])?["number"] as? Double ?? 0
        guard lat != 0, lon != 0 else { return nil }
        return Place(
            id: id,
            name: title(props["Name"]) ?? "",
            city: richText(props["City"]) ?? "",
            address: richText(props["Address"]) ?? "",
            category: select(props["Category"]) ?? "",
            latitude: lat,
            longitude: lon,
            flagged: checkbox(props["Flagged"]),
            googlePlaceID: richText(props["Google Place ID"]),
            googleMapsURL: urlProp(props["Google Maps URL"]),
            phone: phoneProp(props["Phone"]),
            website: urlProp(props["Website"]),
            hours: richText(props["Hours"]),
            status: select(props["Status"]) ?? "",
            ratingExternal: (props["Rating External"] as? [String: Any])?["number"] as? Double,
            ratingPersonal: (props["Rating Personal"] as? [String: Any])?["number"] as? Int,
            visitCount: ((props["Visit Count"] as? [String: Any])?["rollup"] as? [String: Any])?["number"] as? Int ?? 0,
            lastVisited: dateProp((props["Last Visited"] as? [String: Any])?["rollup"]),
            tags: ((props["Tags Raw"] as? [String: Any])?["multi_select"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? [],
            aiSummary: richText(props["AI Summary"]),
            notes: richText(props["Notes Raw"]),
            frequent: checkbox(props["Frequent"]),
            dwellTime: (props["Dwell Time"] as? [String: Any])?["number"] as? Int,
            geofenceRadius: (props["Geofence Radius"] as? [String: Any])?["number"] as? Int,
            geofenceExcluded: checkbox(props["Geofence Excluded"]),
            promptLog: checkbox(props["Prompt Log"]),
            skipEnrichment: checkbox(props["Skip Enrichment"]),
            enrichmentStatus: selectProp(props["Enrichment Status"])
        )
    }

    // MARK: - Toggle Frequent

    func toggleFrequent(_ place: Place) async throws {
        let body: [String: Any] = [
            "properties": ["Frequent": ["checkbox": !place.frequent]]
        ]
        _ = try await patch("\(baseURL)/pages/\(place.id)", body: body)
        if let index = places.firstIndex(where: { $0.id == place.id }) {
            places[index].frequent = !place.frequent
        }
        if GeofenceManager.shared.isMonitoring {
            GeofenceManager.shared.startMonitoring(places: places)
        }
    }

    // MARK: - Set Dwell Time

    func setDwellTime(_ place: Place, minutes: Int?) async throws {
        let value: Any = minutes.map { $0 as Any } ?? NSNull()
        let body: [String: Any] = ["properties": ["Dwell Time": ["number": value]]]
        _ = try await patch("\(baseURL)/pages/\(place.id)", body: body)
        if let index = places.firstIndex(where: { $0.id == place.id }) {
            places[index].dwellTime = minutes
        }
    }

    // MARK: - Set Geofence Radius

    func setGeofenceRadius(_ place: Place, metres: Int?) async throws {
        let value: Any = metres.map { $0 as Any } ?? NSNull()
        let body: [String: Any] = ["properties": ["Geofence Radius": ["number": value]]]
        _ = try await patch("\(baseURL)/pages/\(place.id)", body: body)
        if let index = places.firstIndex(where: { $0.id == place.id }) {
            places[index].geofenceRadius = metres
        }
        if GeofenceManager.shared.isMonitoring {
            GeofenceManager.shared.startMonitoring(places: places)
        }
    }

    // MARK: - Toggle Geofence Excluded

    func toggleGeofenceExcluded(_ place: Place) async throws {
        let body: [String: Any] = [
            "properties": ["Geofence Excluded": ["checkbox": !place.geofenceExcluded]]
        ]
        _ = try await patch("\(baseURL)/pages/\(place.id)", body: body)
        if let index = places.firstIndex(where: { $0.id == place.id }) {
            places[index].geofenceExcluded = !place.geofenceExcluded
        }
        if GeofenceManager.shared.isMonitoring {
            GeofenceManager.shared.startMonitoring(places: places)
        }
    }

    func togglePromptLog(_ place: Place) async throws {
        let body: [String: Any] = [
            "properties": ["Prompt Log": ["checkbox": !place.promptLog]]
        ]
        _ = try await patch("\(baseURL)/pages/\(place.id)", body: body)
        if let index = places.firstIndex(where: { $0.id == place.id }) {
            places[index].promptLog = !place.promptLog
        }
    }

    func toggleSkipEnrichment(_ place: Place) async throws {
        let body: [String: Any] = [
            "properties": ["Skip Enrichment": ["checkbox": !place.skipEnrichment]]
        ]
        _ = try await patch("\(baseURL)/pages/\(place.id)", body: body)
        if let index = places.firstIndex(where: { $0.id == place.id }) {
            places[index].skipEnrichment = !place.skipEnrichment
        }
    }

    private func parseVisit(_ page: [String: Any]) -> Visit? {
        guard let id = page["id"] as? String,
              let props = page["properties"] as? [String: Any] else { return nil }
        let rawName = title(props["Name"]) ?? "Visit"
        let name = rawName.components(separatedBy: " · ").first ?? rawName
        let dateStr = (props["Date Visited"] as? [String: Any]).flatMap {
            ($0["date"] as? [String: Any])?["start"] as? String
        } ?? ""
        let visitDate = notionDate(from: dateStr) ?? Date()
        let photoURLs = ((props["Photo URLs"] as? [String: Any])?["rich_text"] as? [[String: Any]] ?? [])
            .compactMap { ($0["text"] as? [String: Any])?["content"] as? String }
            .filter { !$0.isEmpty && $0 != "\n" }
        let peopleIDs = ((props["Companion"] as? [String: Any])?["relation"] as? [[String: Any]] ?? [])
            .compactMap { $0["id"] as? String }
        return Visit(
            id: id,
            placeID: ((props["Place"] as? [String: Any])?["relation"] as? [[String: Any]])?.first?["id"] as? String ?? "",
            placeName: name,
            date: visitDate,
            rating: (props["Rating"] as? [String: Any])?["number"] as? Int,
            notes: richText(props["Notes"]),
            photoURLs: photoURLs,
            peopleIDs: peopleIDs,
            skipEnrichment: checkbox(props["Skip Enrichment"])
        )
    }

    private func parseCapture(_ page: [String: Any]) -> Capture? {
        guard let id = page["id"] as? String,
              let props = page["properties"] as? [String: Any] else { return nil }
        let timestampStr = (props["Timestamp"] as? [String: Any]).flatMap {
            ($0["date"] as? [String: Any])?["start"] as? String
        } ?? ""
        return Capture(
            id: id,
            notes: richText(props["Notes"]) ?? "",
            gpsLat: (props["GPS Lat"] as? [String: Any])?["number"] as? Double,
            gpsLon: (props["GPS Lon"] as? [String: Any])?["number"] as? Double,
            timestamp: ISO8601DateFormatter().date(from: timestampStr) ?? Date(),
            placeID: ((props["Place"] as? [String: Any])?["relation"] as? [[String: Any]])?.first?["id"] as? String,
            placeName: title(props["Name"]),
            status: select(props["Status"]) ?? "Unlinked",
            photoURL: (props["Photo URL"] as? [String: Any])?["url"] as? String
        )
    }

    private func title(_ prop: Any?) -> String? {
        guard let p = prop as? [String: Any],
              let arr = p["title"] as? [[String: Any]] else { return nil }
        let t = arr.compactMap { ($0["text"] as? [String: Any])?["content"] as? String }.joined()
        return t.isEmpty ? nil : t
    }

    private func richText(_ prop: Any?) -> String? {
        guard let p = prop as? [String: Any] else { return nil }
        let arr = (p["rich_text"] as? [[String: Any]]) ?? (p["title"] as? [[String: Any]]) ?? []
        let t = arr.compactMap { ($0["text"] as? [String: Any])?["content"] as? String }.joined()
        return t.isEmpty ? nil : t
    }

    private func select(_ prop: Any?) -> String? {
        guard let p = prop as? [String: Any],
              let s = p["select"] as? [String: Any] else { return nil }
        return s["name"] as? String
    }

    private func selectProp(_ prop: Any?) -> String? {
        ((prop as? [String: Any])?["select"] as? [String: Any])?["name"] as? String
    }

    private func checkbox(_ prop: Any?) -> Bool {
        (prop as? [String: Any])?["checkbox"] as? Bool ?? false
    }

    private func urlProp(_ prop: Any?) -> String? {
        (prop as? [String: Any])?["url"] as? String
    }

    private func phoneProp(_ prop: Any?) -> String? {
        (prop as? [String: Any])?["phone_number"] as? String
    }

    private func dateProp(_ prop: Any?) -> Date? {
        guard let p = prop as? [String: Any],
              let d = p["date"] as? [String: Any],
              let s = d["start"] as? String else { return nil }
        return notionDate(from: s)
    }

    /// Formats a Date as a local-timezone date-only string ("2026-06-18") for Notion date fields.
    /// Using a UTC timestamp would cause Notion to truncate to the UTC date, shifting evening
    /// entries (after midnight UTC / 7 pm CDT) to the next day.
    private func localDateString(from date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        f.timeZone = TimeZone.current
        return f.string(from: date)
    }

    /// Parses a Notion date string. Handles both date-only ("2026-06-18") and full
    /// ISO-8601 ("2026-06-18T22:00:00Z" / "2026-06-18T17:00:00.000-05:00").
    /// Date-only strings use the local timezone so days never shift at UTC midnight.
    /// Full timestamps carry their own offset and convert correctly via the system.
    private func notionDate(from s: String) -> Date? {
        if s.count == 10 {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withFullDate]
            f.timeZone = TimeZone.current
            return f.date(from: s)
        }
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: s) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        if let d = f2.date(from: s) { return d }
        return ISO8601DateFormatter().date(from: s)
    }
}

enum NotionError: LocalizedError {
    case apiError(Int, String)
    var errorDescription: String? {
        if case .apiError(let code, let msg) = self {
            return "Notion error \(code): \(msg)"
        }
        return nil
    }
}
