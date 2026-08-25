import Foundation
import CoreLocation

// MARK: - Model

/// Which backend produced a result.
///
/// Added 2026-08-24 with the MapKit fallback (D138). It exists mainly to stop
/// one specific data corruption: `DiscoverView.savePlace()` writes
/// `googlePlaceID: place.id`, and an Apple result's id is not a Google place
/// ID. Storing one would mean the record never matches a real Google lookup
/// again and never gets enriched, **while looking completely fine in the
/// database** — a silent write is worse than a failed one.
enum PlaceSource: String, Equatable {
    case google
    case apple
}

/// Address parts a source handed us directly, rather than as one string to be
/// picked apart.
///
/// **Added 2026-08-24 the same evening the MapKit fallback shipped, because the
/// first real Apple result got its city wrong and said nothing about it.**
/// `GooglePlace`'s address accessors count backwards through a comma-separated
/// string — Google always sends four parts, so `city` is `parts[count - 3]` and
/// that has been reliable for as long as Google was the only source. MapKit
/// hands back a placemark with a nil field whenever it does not know one, and
/// dropping a nil shifted every remaining part one slot left: a three-part
/// address made `city` return "1417 Ellinwood St".
///
/// It rendered as a *missing* city in the results row, which is the mild
/// version. The severe version is one tap further on, where the save sheet
/// would have written that street into the Notion record's City field, and
/// nothing anywhere would have failed.
///
/// **The parsing exists only because Google hands us one string.** A source
/// with real components should not be made to pretend otherwise, so this is
/// filled by MapKit and left nil by Google, and the accessors prefer it when
/// it is there.
struct PlaceAddress: Equatable {
    let street: String
    let city: String
    let regionAndPostcode: String
    let country: String
}

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
    /// **Declared last, with a default, and `var` rather than `let`.** The
    /// last part is not style: Swift omits a `let` property that already has a
    /// default value from the memberwise initialiser entirely, so
    /// `GooglePlace(..., source: .apple)` would not compile at all. A `var`
    /// with a default gets a defaulted parameter in final position, which is
    /// what is wanted — every existing construction site (DiscoverView's MapKit
    /// feature fallback, PlaceDetailView, the two Mac views) keeps compiling
    /// untouched and keeps meaning `.google`, which is what they all are.
    var source: PlaceSource = .google
    /// Set when the source gave us structured address parts. See `PlaceAddress`.
    var addressComponents: PlaceAddress? = nil

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    // "123 Main St, Chicago, IL 60601, USA" → "123 Main St"
    var streetAddress: String {
        if let c = addressComponents { return c.street }
        let parts = formattedAddress.components(separatedBy: ", ")
        guard parts.count >= 3 else { return formattedAddress }
        return parts.prefix(parts.count - 3).joined(separator: ", ")
    }

    /// `"123 Main St, Chicago, IL 60601, USA"` → `"123 Main St, Chicago, IL 60601"`.
    ///
    /// Everything Google gave us except the country.
    ///
    /// **Why this exists.** `streetAddress` above drops the city, the state AND
    /// the postcode, because `Place` stores city separately. City survives in
    /// its own field; the state and postcode were simply thrown away and stored
    /// nowhere. David, saving Lakemore Resort as a destination for a five-hour
    /// drive: *"The address is not showing in the place record."* It was — just
    /// the street line, with `MI 49696` gone.
    ///
    /// `Place.address` is only ever displayed or searched — no parser depends on
    /// it being street-only — so the fuller string is safe to store there, and it
    /// needs no Notion schema change, which a separate postcode field would.
    ///
    /// The country is dropped because every place in this vault is in one, and a
    /// line ending "USA" is noise on a card you read at a glance.
    var addressWithRegion: String {
        if let c = addressComponents {
            return [c.street, c.city, c.regionAndPostcode]
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
        }
        let parts = formattedAddress.components(separatedBy: ", ")
        guard parts.count >= 2 else { return formattedAddress }
        return parts.dropLast().joined(separator: ", ")
    }

    // "123 Main St, Chicago, IL 60601, USA" → "Chicago"
    var city: String {
        if let c = addressComponents { return c.city }
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

/// Why a search came back with nothing.
///
/// **Added 2026-08-24 because "nothing" had four different causes and one
/// appearance.** David, after a trip: *"the Trace Discover search does not seem
/// to be working for places not in my database"* — he ended up zooming the map
/// and tapping each place by hand. A missing key returned `[]`, a rejected key
/// returned a body with no `places` array which also became `[]`, a network
/// failure was swallowed by a bare `catch { searchResults = [] }` in
/// `DiscoverView`, and a genuine no-match returned `[]` as well. **Four
/// failures, one empty list, no way to tell them apart — from inside the app
/// or from reading the source.**
///
/// The map-tap path hid this for months because it has a fallback the search
/// path does not: `DiscoverView.swift`'s `onChange(of: selectedMapFeature)`
/// falls back to MapKit's own feature data when Google returns nothing, so a
/// tapped place still opened a sheet — with a name and no address, which is
/// exactly what David's screenshot showed. **A working workaround is not
/// evidence the thing it works around is healthy.**
enum GooglePlacesError: LocalizedError {
    /// No key stored under `google_places_key` in this app's `UserDefaults`.
    /// Note this is per-app: the key typed into TraceMac's settings is not the
    /// key Trace on the phone reads, and neither is the key in a Simulator.
    case missingKey
    /// Non-200 from the API, with whatever Google said about it.
    case http(status: Int, googleStatus: String?, message: String?)
    /// 200 with a body that could not be read as JSON.
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "No Google Places API key saved on this device."
        case let .http(status, googleStatus, message):
            let detail = [googleStatus, message].compactMap { $0 }.joined(separator: ": ")
            return detail.isEmpty
                ? "Google Places returned HTTP \(status)."
                : "Google Places (HTTP \(status)) \(detail)"
        case .malformedResponse:
            return "Google Places returned a response that could not be read."
        }
    }
}

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
        // Deliberately still soft: reviews are decoration on an info card that
        // is already populated, so a failure here should not blank the card.
        // Unlike `search(body:)` above, an empty result is not mistaken for a
        // broken feature. Revisit only if a missing-reviews report arrives.
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

    /// **Throws now instead of returning `[]` on failure.** See
    /// `GooglePlacesError` above for why: an empty array was the answer to
    /// "no key", "key rejected", "quota gone" and "nothing matched" alike,
    /// and a caller cannot tell the user what it does not know itself.
    ///
    /// An empty array still means exactly one thing after this change:
    /// **the search ran and matched nothing.**
    private func search(body: [String: Any]) async throws -> [GooglePlace] {
        guard !apiKey.isEmpty else { throw GooglePlacesError.missingKey }
        let url = URL(string: "\(baseURL):searchText")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-Goog-Api-Key")
        request.setValue(fieldMask, forHTTPHeaderField: "X-Goog-FieldMask")
        request.setValue("com.david.Trace", forHTTPHeaderField: "X-Ios-Bundle-Identifier")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        // Parse first: Google puts its explanation in the body of a 4xx, and
        // that string ("API key not valid", "This API project is not
        // authorized to use this API", "Places API (New) has not been used in
        // project ... before or it is disabled") is the entire diagnostic.
        // Reading it and dropping it would repeat the original mistake one
        // level down.
        let parsed = try? JSONSerialization.jsonObject(with: data)
        let json = parsed as? [String: Any]

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let err = json?["error"] as? [String: Any]
            throw GooglePlacesError.http(
                status: http.statusCode,
                googleStatus: err?["status"] as? String,
                message: err?["message"] as? String
            )
        }

        guard let json else { throw GooglePlacesError.malformedResponse }

        // A 200 can still carry an `error` object on this API.
        if let err = json["error"] as? [String: Any] {
            throw GooglePlacesError.http(
                status: (err["code"] as? Int) ?? 200,
                googleStatus: err["status"] as? String,
                message: err["message"] as? String
            )
        }

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
