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
    var personDetailCache: [String: PersonDetail] = [:]
    var isLoading = false
    var error: String?

    private let placesDBID = "3edc903daeaa41eaa82f93fb0ec55e60"
    private let visitsDBID = "ecd8cdc617e74c78b090afc5092cbdee"
    private let capturesDBID = "7e292efac9754d7f8e5fceef5e9dc0e2"
    private let peopleDBID = "50261ebf9c3c49bc926542e3ccfaa4aa"
    private let workoutsDBID = "b7dab8c1a46542ab83c442e1b76f002a"
    private let notionVersion = "2022-06-28"
    private let baseURL = "https://api.notion.com/v1"

    var token: String {
        get { UserDefaults.standard.string(forKey: "notion_token") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "notion_token") }
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
            "Date Visited": ["date": ["start": ISO8601DateFormatter().string(from: date)]],
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

    func updatePlace(_ place: Place, name: String, category: String, status: String, tags: [String]? = nil) async throws {
        var props: [String: Any] = [
            "Name": ["title": [["text": ["content": name]]]],
            "Category": ["select": ["name": category]],
            "Status": ["select": ["name": status]]
        ]
        if let tags {
            props["Tags"] = ["multi_select": tags.map { ["name": $0] }]
        }
        let body: [String: Any] = ["properties": props]
        _ = try await patch("\(baseURL)/pages/\(place.id)", body: body)
        if let index = places.firstIndex(where: { $0.id == place.id }) {
            places[index].name = name
            places[index].category = category
            places[index].status = status
            if let tags { places[index].tags = tags }
        }
    }

    func archivePlace(_ place: Place) async throws {
        let body: [String: Any] = ["properties": ["Status": ["select": ["name": "Archived"]]]]
        _ = try await patch("\(baseURL)/pages/\(place.id)", body: body)
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
            props["Date Visited"] = ["date": ["start": ISO8601DateFormatter().string(from: date)]]
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
            let fmt = ISO8601DateFormatter()
            fmt.formatOptions = [.withFullDate]
            props["Date"] = ["date": ["start": fmt.string(from: d)]]
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

        let df = ISO8601DateFormatter()
        df.formatOptions = [.withFullDate]
        let date: Date = {
            guard let s = ((props["Date"] as? [String: Any])?["date"] as? [String: Any])?["start"] as? String
            else { return Date() }
            return df.date(from: s) ?? Date()
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

    func enrichPerson(id: String, relationship: String?, relationshipStrength: String?,
                      companyContext: String?, city: String?, howWeMet: String?, tags: [String]) async throws {
        var props: [String: Any] = [:]
        if let r = relationship, !r.isEmpty { props["Relationship"] = ["select": ["name": r]] }
        if let rs = relationshipStrength, !rs.isEmpty { props["Relationship Strength"] = ["select": ["name": rs]] }
        if let cc = companyContext { props["Company/Context"] = ["rich_text": [["text": ["content": cc]]]] }
        if let c = city { props["City"] = ["rich_text": [["text": ["content": c]]]] }
        if let h = howWeMet { props["How We Met"] = ["rich_text": [["text": ["content": h]]]] }
        props["Tags"] = ["multi_select": tags.map { ["name": $0] }]
        guard !props.isEmpty else { return }
        _ = try await patch("\(baseURL)/pages/\(id)", body: ["properties": props])
        personDetailCache.removeValue(forKey: id)
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
            lastInteractionDate: lastInteractionDate
        )
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
            frequent: checkbox(props["Frequent"]),
            dwellTime: (props["Dwell Time"] as? [String: Any])?["number"] as? Int,
            geofenceExcluded: checkbox(props["Geofence Excluded"])
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

    private func parseVisit(_ page: [String: Any]) -> Visit? {
        guard let id = page["id"] as? String,
              let props = page["properties"] as? [String: Any] else { return nil }
        let rawName = title(props["Name"]) ?? "Visit"
        let name = rawName.components(separatedBy: " · ").first ?? rawName
        let dateStr = (props["Date Visited"] as? [String: Any]).flatMap {
            ($0["date"] as? [String: Any])?["start"] as? String
        } ?? ""
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = TimeZone.current
        let visitDate = formatter.date(from: dateStr) ?? Date()
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
            peopleIDs: peopleIDs
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
