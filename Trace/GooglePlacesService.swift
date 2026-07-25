import Foundation
import CoreLocation

// MARK: - Model

struct GooglePlace: Identifiable, Equatable {
    let id: String
    let name: String
    let formattedAddress: String
    let latitude: Double
    let longitude: Double
    let phone: String?
    let website: String?
    let rating: Double?
    let ratingCount: Int?
    let primaryType: String?
    let openNow: Bool?
    let weekdayDescriptions: [String]   // e.g. ["Monday: 11:00 AM – 10:00 PM", ...]

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    // "123 Main St, Chicago, IL 60601, USA" → "123 Main St"
    var streetAddress: String {
        let parts = formattedAddress.components(separatedBy: ", ")
        guard parts.count >= 3 else { return formattedAddress }
        return parts.prefix(parts.count - 3).joined(separator: ", ")
    }

    // "123 Main St, Chicago, IL 60601, USA" → "Chicago"
    var city: String {
        let parts = formattedAddress.components(separatedBy: ", ")
        guard parts.count >= 3 else { return "" }
        return parts[parts.count - 3]
    }

    // Today's hours string, e.g. "11:00 AM – 10:00 PM"
    var todayHours: String? {
        guard !weekdayDescriptions.isEmpty else { return nil }
        // weekdayDescriptions index 0 = Monday (Google), weekday() 2 = Monday (Calendar)
        let weekday = Calendar.current.component(.weekday, from: Date()) // 1=Sun, 2=Mon...
        let index = (weekday + 5) % 7  // convert to Mon=0 index
        let line = weekdayDescriptions[safe: index] ?? weekdayDescriptions[0]
        // Strip the day prefix: "Monday: 11 AM – 10 PM" → "11 AM – 10 PM"
        if let colon = line.firstIndex(of: ":") {
            let after = line.index(after: colon)
            return String(line[after...]).trimmingCharacters(in: .whitespaces)
        }
        return line
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Review model (Phase 2 — Place Details call)

struct GooglePlaceReview: Identifiable, Equatable {
    let id: String
    let authorName: String
    let rating: Int
    let text: String?
    let relativeTime: String
}

// MARK: - Service

class GooglePlacesService {
    static let shared = GooglePlacesService()
    private let baseURL = "https://places.googleapis.com/v1/places"

    private var apiKey: String {
        UserDefaults.standard.string(forKey: "google_places_key") ?? ""
    }

    private var fieldMask: String {
        [
            "places.id",
            "places.displayName",
            "places.formattedAddress",
            "places.location",
            "places.internationalPhoneNumber",
            "places.websiteUri",
            "places.rating",
            "places.userRatingCount",
            "places.primaryType",
            "places.currentOpeningHours"
        ].joined(separator: ",")
    }

    // Text search — used by Discover search bar
    func textSearch(query: String, coordinate: CLLocationCoordinate2D?) async throws -> [GooglePlace] {
        var body: [String: Any] = ["textQuery": query]
        if let coord = coordinate {
            body["locationBias"] = [
                "circle": [
                    "center": ["latitude": coord.latitude, "longitude": coord.longitude],
                    "radius": 8000.0
                ]
            ]
        }
        return try await search(body: body)
    }

    // Nearby search — used when tapping a map POI
    func nearbySearch(coordinate: CLLocationCoordinate2D, query: String) async throws -> [GooglePlace] {
        let body: [String: Any] = [
            "textQuery": query,
            "locationBias": [
                "circle": [
                    "center": ["latitude": coordinate.latitude, "longitude": coordinate.longitude],
                    "radius": 100.0
                ]
            ]
        ]
        return try await search(body: body)
    }

    // Place Details — reviews (Phase 2). Separate endpoint/field mask from
    // search(); current `fieldMask` excludes reviews entirely, per Google's
    // API design (search results stay lightweight, details are opt-in).
    // Returns up to 5 individual reviews, the aggregate rating + total review
    // count (the only real "distribution" signal Google's API provides —
    // there's no per-star breakdown available), and the Google Maps URI
    // required for attribution alongside any displayed review content
    // (Google ToS).
    func placeDetails(placeID: String) async throws -> (
        reviews: [GooglePlaceReview],
        googleMapsURI: String?,
        overallRating: Double?,
        totalReviewCount: Int?
    ) {
        guard !apiKey.isEmpty else { return ([], nil, nil, nil) }
        let url = URL(string: "\(baseURL)/\(placeID)")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "X-Goog-Api-Key")
        request.setValue("reviews,googleMapsUri,rating,userRatingCount", forHTTPHeaderField: "X-Goog-FieldMask")
        request.setValue("com.david.Trace", forHTTPHeaderField: "X-Ios-Bundle-Identifier")

        let (data, _) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let reviewsJSON = json["reviews"] as? [[String: Any]] ?? []
        let reviews = reviewsJSON.compactMap { parseReview($0) }
        let mapsURI = json["googleMapsUri"] as? String
        let overallRating = json["rating"] as? Double
        let totalReviewCount = json["userRatingCount"] as? Int
        return (reviews, mapsURI, overallRating, totalReviewCount)
    }

    private func parseReview(_ json: [String: Any]) -> GooglePlaceReview? {
        guard let rating = json["rating"] as? Int else { return nil }
        let textObj = json["text"] as? [String: Any]
        let text = textObj?["text"] as? String
        let author = json["authorAttribution"] as? [String: Any]
        let authorName = author?["displayName"] as? String ?? "Anonymous"
        let relativeTime = json["relativePublishTimeDescription"] as? String ?? ""
        let publishTime = json["publishTime"] as? String ?? UUID().uuidString
        return GooglePlaceReview(
            id: "\(authorName)-\(publishTime)",
            authorName: authorName,
            rating: rating,
            text: text,
            relativeTime: relativeTime
        )
    }

    private func search(body: [String: Any]) async throws -> [GooglePlace] {
        guard !apiKey.isEmpty else { return [] }
        let url = URL(string: "\(baseURL):searchText")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-Goog-Api-Key")
        request.setValue(fieldMask, forHTTPHeaderField: "X-Goog-FieldMask")
        request.setValue("com.david.Trace", forHTTPHeaderField: "X-Ios-Bundle-Identifier")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let places = json["places"] as? [[String: Any]] ?? []
        return places.compactMap { parsePlace($0) }
    }

    private func parsePlace(_ json: [String: Any]) -> GooglePlace? {
        guard
            let id = json["id"] as? String,
            let displayName = json["displayName"] as? [String: Any],
            let name = displayName["text"] as? String,
            let location = json["location"] as? [String: Any],
            let lat = location["latitude"] as? Double,
            let lon = location["longitude"] as? Double
        else { return nil }

        let address     = json["formattedAddress"] as? String ?? ""
        let phone       = json["internationalPhoneNumber"] as? String
        let website     = json["websiteUri"] as? String
        let rating      = json["rating"] as? Double
        let ratingCount = json["userRatingCount"] as? Int
        let primaryType = json["primaryType"] as? String
        let hours       = json["currentOpeningHours"] as? [String: Any]
        let openNow     = hours?["openNow"] as? Bool
        let weekdays    = hours?["weekdayDescriptions"] as? [String] ?? []

        return GooglePlace(
            id: id,
            name: name,
            formattedAddress: address,
            latitude: lat,
            longitude: lon,
            phone: phone,
            website: website,
            rating: rating,
            ratingCount: ratingCount,
            primaryType: primaryType,
            openNow: openNow,
            weekdayDescriptions: weekdays
        )
    }
}
