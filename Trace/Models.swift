import Foundation
import CoreLocation

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

    var isArchived: Bool { relationshipStrength == "archived" }
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
    var type: String        // call / email / meeting / coffee / other (Notion select values)
    var notes: String?
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
