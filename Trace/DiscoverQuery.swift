import Foundation
import CoreLocation

// MARK: - DiscoverQuery
//
// Session 102, D393. Discover answers a sentence: "pizza within 10 miles of
// Traverse City", "coffee near Mount Prospect", "bookstores in Evanston".
// Google's text search already understands most of that on its own; what it
// cannot know is that David means a circle around a town he is not standing
// in, or how wide. So the sentence is read once here, the anchor is geocoded
// with MapKit (no new key), and the search is RESTRICTED to that circle
// instead of biased around the phone. Shared by the phone and the Mac.
//
// The parse is deliberately narrow: three phrasings, tail of the sentence
// only, so "in-n-out burger" and "near me" do not turn into anchors.

struct DiscoverQuery: Equatable {
    /// What is searched for, with the anchor phrase removed: "pizza".
    var terms: String
    /// The town or place to centre on, as typed: "Traverse City". Nil when
    /// the sentence names none, in which case the phone's location applies.
    var anchorName: String?
    /// The radius in metres when the sentence gave one; nil otherwise.
    var radiusMeters: Double?

    static let defaultRadiusMeters: Double = 8_000

    static func parse(_ raw: String) -> DiscoverQuery {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()

        // "within 10 miles of X" / "within 5 km of X" / "within 5 miles" (of here)
        let within = try! NSRegularExpression(
            pattern: #"^(.*?)\s+within\s+(\d+(?:\.\d+)?)\s*(miles?|mi|km|kilometers?|kilometres?)(?:\s+(?:of|from)\s+(.+))?$"#,
            options: [.caseInsensitive])
        if let m = within.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let termsR = Range(m.range(at: 1), in: text),
           let numR = Range(m.range(at: 2), in: text),
           let unitR = Range(m.range(at: 3), in: text),
           let number = Double(text[numR]) {
            let unit = text[unitR].lowercased()
            let meters = unit.hasPrefix("k") ? number * 1_000 : number * 1_609.34
            var anchor: String? = nil
            if m.range(at: 4).location != NSNotFound, let anchorR = Range(m.range(at: 4), in: text) {
                let a = String(text[anchorR]).trimmingCharacters(in: .whitespaces)
                if !["me", "here", "my location"].contains(a.lowercased()) { anchor = a }
            }
            // "within 5 miles" and nothing after it: the circle is around
            // the phone. David's first real search was exactly this.
            return DiscoverQuery(terms: String(text[termsR]).trimmingCharacters(in: .whitespaces),
                                 anchorName: anchor,
                                 radiusMeters: meters)
        }

        // "X near Y" / "X in Y" / "X around Y", but never "near me" / "near here".
        let near = try! NSRegularExpression(
            pattern: #"^(.+?)\s+(near|around|in)\s+(.+)$"#, options: [.caseInsensitive])
        if let m = near.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let termsR = Range(m.range(at: 1), in: text),
           let anchorR = Range(m.range(at: 3), in: text) {
            let anchor = String(text[anchorR]).trimmingCharacters(in: .whitespaces)
            let anchorLower = anchor.lowercased()
            if !["me", "here", "my area", "my location"].contains(anchorLower), anchor.count >= 3 {
                return DiscoverQuery(terms: String(text[termsR]).trimmingCharacters(in: .whitespaces),
                                     anchorName: anchor, radiusMeters: nil)
            }
        }
        _ = lower
        return DiscoverQuery(terms: text, anchorName: nil, radiusMeters: nil)
    }

    /// The anchor's coordinate, from MapKit's geocoder. Nil when the sentence
    /// named nothing or the name did not resolve; the caller then searches
    /// around the phone and says so.
    static func geocode(_ name: String) async -> CLLocationCoordinate2D? {
        let geocoder = CLGeocoder()
        guard let marks = try? await geocoder.geocodeAddressString(name),
              let coord = marks.first?.location?.coordinate else { return nil }
        return coord
    }

    /// Whether the sentence asked for anything beyond a plain term.
    var hasScope: Bool { anchorName != nil || radiusMeters != nil }

    /// What the chip under the search field says: "Traverse City · 10 mi",
    /// or "here · 5 mi" when only a radius was given.
    var anchorLabel: String? {
        guard hasScope else { return nil }
        let name = anchorName ?? "here"
        guard let radiusMeters else { return name }
        let miles = radiusMeters / 1_609.34
        let shown = miles >= 10 ? String(format: "%.0f mi", miles) : String(format: "%.1f mi", miles)
        return "\(name) · \(shown)"
    }
}
