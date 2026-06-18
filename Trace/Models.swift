import Foundation
import CoreLocation

struct Place: Identifiable, Codable {
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
