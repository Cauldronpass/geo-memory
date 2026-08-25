// AppleMapsSearchService.swift — new file, Trace target.
//
// A second search backend for Discover, added 2026-08-24 (D138).
//
// **Why this exists.** David's Google Places key started returning
// `HTTP 403 PERMISSION_DENIED` — a Google Cloud project problem, not an app
// problem — and Discover's text search went completely dark for a whole trip
// while he worked around it by zooming the map and tapping each place by hand.
// That workaround is the tell: **MapKit knew every one of those places the
// whole time.** `MKLocalSearch` is the same engine, it needs no API key, no
// billing account and no quota, and it cannot be switched off by a console
// setting.
//
// Google stays primary because it carries what MapKit does not: ratings,
// review counts, opening hours and the stable place ID that
// `Place.googlePlaceID` is matched on. Apple fills in when Google returns
// nothing, for whatever reason. See `DiscoverView.performSearch()` for the
// order and `GooglePlace.source` for how a result's origin travels with it.
//
// **The address string is built to Google's exact shape on purpose.**
// `GooglePlace.city`, `.streetAddress` and `.addressWithRegion` all parse
// `formattedAddress` by splitting on ", " and counting from the end —
// "street, city, ST zip, Country". An Apple result that formatted its address
// any other way would parse into the wrong fields silently, and a place would
// be saved with a city of "IL 60601" without anything failing. Matching the
// shape is what lets one set of accessors serve both sources.

import Foundation
import MapKit
import CoreLocation

enum AppleMapsSearchService {

    /// Natural-language POI search through MapKit.
    ///
    /// Returns `[]` rather than throwing when MapKit simply finds nothing —
    /// same contract `GooglePlacesService.search(body:)` now has, where an
    /// empty array means "ran, matched nothing" and nothing else. A real
    /// failure still throws, so the caller can tell the difference; that
    /// distinction is the whole point of D137 and it would be careless to
    /// build the second backend without it.
    static func search(query: String,
                       near coordinate: CLLocationCoordinate2D?) async throws -> [GooglePlace] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmed
        request.resultTypes = [.pointOfInterest, .address]

        // **50km, not the 16km this first shipped with.** Google's 8km
        // `locationBias` is a *bias* — it ranks nearby results higher but still
        // returns distant ones — whereas MKLocalSearch's `region` behaves much
        // more like a filter. Searching "Galaxy" from Des Plaines returned 20
        // Google results out to 9 miles and exactly 1 from MapKit, because
        // Wheeling, Deerfield and Schiller Park fell outside a 16km box.
        // **The two parameters have the same name in English and different
        // meanings in practice**, and matching the number instead of the
        // behaviour is what produced a one-result list that looked like MapKit
        // simply knowing less.
        if let coordinate {
            request.region = MKCoordinateRegion(
                center: coordinate,
                latitudinalMeters: 50_000,
                longitudinalMeters: 50_000
            )
        }

        do {
            let response = try await MKLocalSearch(request: request).start()
            return response.mapItems.compactMap { place(from: $0) }
        } catch let error as NSError {
            // MapKit reports "nothing found" as an error rather than an empty
            // response. That is a no-match, not a failure, and surfacing it as
            // a red banner would recreate the exact confusion D137 removed.
            if error.domain == MKErrorDomain,
               error.code == MKError.placemarkNotFound.rawValue {
                return []
            }
            throw error
        }
    }

    // MARK: - Mapping

    private static func place(from item: MKMapItem) -> GooglePlace? {
        let placemark = item.placemark
        guard let name = item.name ?? placemark.name else { return nil }
        let coord = placemark.coordinate

        return GooglePlace(
            // **Not a Google place ID, and it must never be stored as one.**
            // The `apple:` prefix is what `DiscoverView.savePlace()` and
            // `isInDatabase(_:)` key off, alongside `source`, so a saved Apple
            // result leaves `googlePlaceID` nil and stays eligible for real
            // enrichment later instead of carrying a fake ID that would match
            // nothing forever.
            id: "apple:" + (placemark.title.map { "\($0)|\(coord.latitude),\(coord.longitude)" }
                            ?? UUID().uuidString),
            name: name,
            formattedAddress: formattedAddress(from: placemark),
            latitude: coord.latitude,
            longitude: coord.longitude,
            phone: item.phoneNumber,
            website: item.url?.absoluteString,
            // MapKit publishes no rating, no review count and no opening
            // hours. Left nil rather than faked — a zero rating would draw an
            // empty star row that reads as "rated badly" instead of "unknown".
            rating: nil,
            ratingCount: nil,
            primaryType: category(from: item),
            openNow: nil,
            weekdayDescriptions: [],
            source: .apple,
            // **The important half.** Handing over real components means
            // `city` and `streetAddress` never have to be recovered by counting
            // commas backwards, which is what put a street address in the city
            // slot the first time this ran. See `PlaceAddress`.
            addressComponents: components(from: placemark)
        )
    }

    private static func components(from placemark: MKPlacemark) -> PlaceAddress {
        PlaceAddress(
            street: [placemark.subThoroughfare, placemark.thoroughfare]
                .compactMap { $0 }
                .joined(separator: " "),
            city: placemark.locality ?? placemark.subAdministrativeArea ?? "",
            regionAndPostcode: [placemark.administrativeArea, placemark.postalCode]
                .compactMap { $0 }
                .joined(separator: " "),
            country: placemark.country ?? ""
        )
    }

    /// The human-readable one-line address, for the places that display it raw
    /// (`PlaceDetailView`, both Mac Discover cards).
    ///
    /// **No longer load-bearing.** It was originally shaped to Google's
    /// "street, city, ST zip, Country" so the accessors could parse it, which
    /// worked only while every component was present and broke the moment
    /// MapKit omitted one. `addressComponents` carries the structure now, and
    /// this is free to just read well: empty parts are dropped rather than
    /// emitted as ", ,".
    private static func formattedAddress(from placemark: MKPlacemark) -> String {
        let street = [placemark.subThoroughfare, placemark.thoroughfare]
            .compactMap { $0 }
            .joined(separator: " ")

        let regionAndPostcode = [placemark.administrativeArea, placemark.postalCode]
            .compactMap { $0 }
            .joined(separator: " ")

        let parts = [
            street.isEmpty ? nil : street,
            placemark.locality,
            regionAndPostcode.isEmpty ? nil : regionAndPostcode,
            placemark.country
        ].compactMap { $0 }

        return parts.joined(separator: ", ")
    }

    private static func category(from item: MKMapItem) -> String? {
        guard let raw = item.pointOfInterestCategory?.rawValue else { return nil }
        // "MKPOICategoryRestaurant" → "restaurant", so it reads like Google's
        // own `primaryType` values rather than an Apple symbol name.
        let stripped = raw.hasPrefix("MKPOICategory")
            ? String(raw.dropFirst("MKPOICategory".count))
            : raw
        return stripped.isEmpty ? nil : stripped.lowercased()
    }
}
