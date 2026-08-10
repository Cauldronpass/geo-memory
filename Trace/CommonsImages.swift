// CommonsImages.swift
// Trace
//
// Moved out of `Dayflow/DayflowCommonsImages.swift` in Session 65, otherwise
// unchanged. Shared by Dayflow and TraceMac.
//
// WHY IT MOVED. David: *"Id like the same way to add the cover image like we
// did with the iphone. It looks up photos based on my search."* The service is
// pure Foundation — a URL request, a JSON parse and a ranking rule — with no
// UIKit anywhere in it, so there was never anything Dayflow-specific about it
// beyond where the file happened to sit. Copying it would have duplicated the
// three-pass category cascade and the `ranked` heuristic, which are the whole
// value of the file and the two things most likely to be tuned again.
//
// ── TARGET MEMBERSHIP IS NOT INHERITED ────────────────────────────────────
//
// `Trace/` is not a buildable folder. This file needs **Dayflow** and
// **TraceMac** ticked by hand in the File Inspector, exactly as
// `Trace/Endeavor.swift` and `Trace/TripLog.swift` did. Session 64 learned this
// by breaking the Dayflow build with 34 errors after assuming otherwise.
//
// The original file's header follows, verbatim.

// DayflowCommonsImages.swift
// Dayflow
//
// Cover photographs for Endeavors, from Wikimedia Commons.
//
// WHY COMMONS AND NOT UNSPLASH. Unsplash was the obvious choice and was ruled
// out on 2026-07-29 by its own API guidelines: "All API uses must use the
// hotlinked image URLs returned by the API" — storing the file locally is not
// permitted. D8 requires the opposite, and for a reason that cannot be
// negotiated away: a cover that is a remote URL goes blank on a plane, which is
// exactly when a trip note is most likely to be open.
//
// Commons hosts its images under Creative Commons and public-domain licences,
// which exist precisely to permit copying and storing. No account, no API key,
// no rate limit worth thinking about.
//
// ATTRIBUTION IS REAL. Most Commons images require crediting the photographer
// and naming the licence. It comes back from the same request, so it is captured
// into the note's `cover_credit` frontmatter automatically and shown on the
// details sheet — not on the Endeavor screen, which is meant to stay quiet.
//
// QUALITY IS THE REAL PROBLEM, not licensing. A plain search for "Kyoto" returns
// beautiful photography mixed with blurry snapshots, maps, diagrams and scans.
// Commons runs two peer-reviewed assessments, so this walks them in order of
// strictness and stops as soon as the grid is full:
//
//   1. Featured pictures — a few tens of thousands site-wide, individually voted
//      on. The best photographs on Commons, and often nothing at all for a
//      specific town.
//   2. Quality images — hundreds of thousands, reviewed against technical
//      standards rather than by vote. Reliably good, less often remarkable.
//   3. Everything, bitmaps only — the safety net, so a small place still returns
//      something.
//
// Each pass only runs if the ones before it came up short, so the common case
// for a famous destination is one request. That cascade is the difference
// between this feeling inspiring and feeling like a jumble.
//
// UNVERIFIED: the Featured pictures category name below could not be checked
// against a live response — Commons is unreachable from the authoring
// environment. If it is wrong, CirrusSearch returns nothing rather than an
// error, so the pass falls through to Quality images and the picker behaves
// exactly as it did before this cascade existed. The failure mode is a wasted
// request, not a broken feature. Confirm it by searching a destination that
// certainly has featured photographs (Kyoto, Venice, Yosemite) and seeing
// whether the first results differ from a Quality-images-only search.
//
// SHAPE MATTERS, AND SUBJECT MATTERS MORE. Added 2026-07-29 after the first run
// on device: "the phots were not great for the six". Part of that was the frame
// — the cover renders full width at 132pt, roughly 3:1, so a portrait
// photograph arrives as a narrow band cropped to its middle, a fine picture of
// a temple rendered as a slice of one wall.
//
// The larger part was subject. Commons search matches categories and
// descriptions, and its curated sets lean heavily toward macro nature
// photography, so "Japan" returned award-winning pictures of a damselfly, a
// butterfly and a goby — all taken in Japan, none of them of Japan.
//
// So each pass fetches wider than it shows and `ranked` orders it: files whose
// TITLE names the place first, landscape before portrait within that. Unknown
// dimensions rank in the middle rather than last, because a missing field is not
// evidence of a bad shape.
//
// VERIFIED 2026-07-29: the request shape and `extmetadata` parsing below were
// written without ever seeing a live response (Commons is unreachable from the
// authoring environment) and needed no correction against the real payload.
// Parsing is still deliberately defensive — every field optional, a malformed
// entry skipped rather than failing the whole search — because being right was
// luck and the failure mode of that luck running out should be "no results",
// not a crash.

import Foundation

// MARK: - Model

struct CommonsImage: Identifiable, Hashable {
    /// The `File:` title, unique on Commons.
    let id: String
    let thumbURL: URL
    let fullURL: URL
    /// Photographer, tags stripped. Nil when Commons does not record one.
    let artist: String?
    /// e.g. "CC BY-SA 4.0", "Public domain".
    let licenseName: String?
    /// Pixel dimensions of the original. Nil when Commons does not report them,
    /// which happens rarely and must not be treated as a verdict on the image.
    let pixelWidth: Int?
    let pixelHeight: Int?

    enum Shape {
        case landscape
        case unknown
        case portrait
    }

    /// 1.2 rather than 1.0 because a near-square photograph crops nearly as
    /// badly as a portrait one in a 3:1 band, and calling it "landscape" would
    /// promote it over an actually-wide picture.
    var shape: Shape {
        guard let w = pixelWidth, let h = pixelHeight, w > 0, h > 0 else { return .unknown }
        return Double(w) / Double(h) >= 1.2 ? .landscape : .portrait
    }

    /// One line for the `cover_credit` frontmatter field. Empty when the image
    /// is public domain and names no author — there is genuinely nothing to say.
    var credit: String {
        switch (artist, licenseName) {
        case let (a?, l?): return "\(a) · \(l)"
        case let (a?, nil): return a
        case let (nil, l?): return l
        default: return ""
        }
    }
}

// MARK: - Service

enum CommonsImageService {

    enum ServiceError: LocalizedError {
        case badQuery
        case transport(String)
        case noResults

        var errorDescription: String? {
            switch self {
            case .badQuery:            return "That search could not be built into a request."
            case .transport(let why):  return why
            case .noResults:           return "Nothing on Wikimedia Commons matched that."
            }
        }
    }

    /// Wikimedia asks for a descriptive User-Agent and blocks requests without
    /// one. Not optional politeness — anonymous or generic agents get refused.
    private static let userAgent =
        "Dayflow/1.0 (personal notes app; https://github.com/dweiss/trace) Swift-URLSession"

    /// How many photographs the picker shows.
    ///
    /// Was six, raised on 2026-07-29: "can you make it more than six - i dont
    /// think that costs us anything to be honest." It costs one thing and only
    /// one — scroll length, since the tiles are full width so that the crop
    /// shown is the crop you get. Twelve is about two screens. Thumbnails load
    /// lazily, so the ones below the fold cost nothing until they are reached.
    static let resultCount = 12

    /// How many candidates to pull per pass relative to how many are shown.
    ///
    /// Ranking by shape is only worth anything if there is a choice to rank. At
    /// 1x, "landscape first" just reorders the ones that were coming anyway. The
    /// cost of 3x is a larger JSON body on the same single request — no extra
    /// round trip, and thumbnails are only fetched for what is displayed.
    private static let overFetch = 3

    /// Search passes, strictest curation first. Empty string means no category
    /// filter at all, which is why it is last.
    ///
    /// `incategory:` matches DIRECT membership only — it does not descend into
    /// subcategories. That is deliberate: `deepcategory:` exists but is capped
    /// and slow, and both assessment templates tag the file itself.
    private static let categoryPasses = [
        "incategory:\"Featured pictures on Wikimedia Commons\"",
        "incategory:\"Quality images\"",
        ""
    ]

    /// Searches Commons for photographs matching `term`.
    ///
    /// Walks `categoryPasses` in order and stops the moment the grid is full, so
    /// a destination with featured photographs costs one request and an obscure
    /// one costs three. Duplicates are dropped across passes because a file can
    /// hold both assessments.
    ///
    /// Within each pass, `ranked` puts files whose title names the place first
    /// and landscape before portrait. Ordering ACROSS the passes is never
    /// disturbed: a featured picture still outranks a quality image, because
    /// curation is the stronger signal than either.
    /// `limit` defaults to `resultCount`, resolved INSIDE the body rather than as a
    /// default argument. A default argument expression is evaluated at the call
    /// site, in the caller's isolation, which under the project's default
    /// main-actor isolation produced "Main actor-isolated static property
    /// 'resultCount' cannot be referenced from a nonisolated context" — a warning
    /// today and an error in Swift 6 language mode.
    static func search(_ term: String, limit: Int? = nil) async throws -> [CommonsImage] {
        let limit = limit ?? resultCount
        let cleaned = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw ServiceError.badQuery }

        var out: [CommonsImage] = []
        var seen = Set<String>()

        for category in categoryPasses {
            // `filetype:bitmap` on every pass, including the curated ones —
            // featured and quality assessments both cover SVG maps and diagrams,
            // which are excellent of their kind and useless as a cover.
            // Named to avoid shadowing this very function inside its own body.
            let searchString = category.isEmpty
                ? "\(cleaned) filetype:bitmap"
                : "\(cleaned) filetype:bitmap \(category)"

            // Hoisted rather than inlined into the for-in: `try await` in a
            // sequence expression compiles, but reads as if the await happens
            // per iteration, and it does not.
            let found = ranked(try await query(searchString, limit: limit * overFetch), term: cleaned)

            for image in found where !seen.contains(image.id) {
                out.append(image)
                seen.insert(image.id)
                if out.count == limit { return out }
            }
        }

        guard !out.isEmpty else { throw ServiceError.noResults }
        return out
    }

    /// Orders one pass's results: **subject first, then shape.**
    ///
    /// WHY SUBJECT NEEDS A RANK AT ALL. Commons search matches a file's
    /// categories and description, not just its title, and its curated sets are
    /// dominated by macro nature photography. So "Japan" returns superb,
    /// correctly-tagged photographs of a damselfly, a butterfly and a goby —
    /// all taken in Japan, none of them of Japan. David got exactly that on
    /// 2026-07-29: a car park, three animals and some trees.
    ///
    /// A file whose TITLE names the place is overwhelmingly likely to be a
    /// photograph of it. "Mount Fuji from Fujiyoshida, Japan.jpg" says where it
    /// is because the place is the subject; "Calopteryx atrata male.jpg" does
    /// not, because the subject is the insect and Japan is only where it was
    /// standing. That is the discriminator, and it costs no extra request —
    /// the title is already in every result.
    ///
    /// Subject outranks shape deliberately. A tall photograph of the right thing
    /// beats a wide photograph of the wrong thing; the crop is a nuisance, the
    /// wrong subject is useless.
    ///
    /// Six buckets, stable within each, so search relevance still breaks ties.
    private static func ranked(_ images: [CommonsImage], term: String) -> [CommonsImage] {
        // Words of three letters or more: "of", "in" and "la" match everything
        // and would rank the whole page as a title match.
        let words = term.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .filter { $0.count > 2 }

        func namesTheSubject(_ image: CommonsImage) -> Bool {
            guard !words.isEmpty else { return false }
            let title = image.id.lowercased()
            return words.allSatisfy { title.contains($0) }
        }

        var buckets: [[CommonsImage]] = Array(repeating: [], count: 6)
        for image in images {
            let subject = namesTheSubject(image) ? 0 : 1
            let shape: Int
            switch image.shape {
            case .landscape: shape = 0
            case .unknown:   shape = 1
            case .portrait:  shape = 2
            }
            buckets[subject * 3 + shape].append(image)
        }
        return buckets.flatMap { $0 }
    }

    /// Downloads the full image. Returned as raw bytes; `EndeavorStore.setCover`
    /// does the downscaling, so there is exactly one place that decides what a
    /// stored cover looks like.
    static func download(_ image: CommonsImage) async throws -> Data {
        var request = URLRequest(url: image.fullURL, timeoutInterval: 30)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ServiceError.transport("Could not download that photo.")
        }
        return data
    }

    // MARK: One request

    private static func query(_ search: String, limit: Int) async throws -> [CommonsImage] {
        var comps = URLComponents(string: "https://commons.wikimedia.org/w/api.php")
        comps?.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "formatversion", value: "2"),
            URLQueryItem(name: "generator", value: "search"),
            URLQueryItem(name: "gsrsearch", value: search),
            // Namespace 6 is File:. Without this the search returns article
            // pages, which have no imageinfo at all.
            URLQueryItem(name: "gsrnamespace", value: "6"),
            URLQueryItem(name: "gsrlimit", value: String(limit)),
            URLQueryItem(name: "prop", value: "imageinfo"),
            // `size` is what carries width and height — the shape ranking is
            // blind without it, and blind here means every image ranks "unknown".
            URLQueryItem(name: "iiprop", value: "url|size|extmetadata|mime"),
            // A thumbnail URL comes back alongside the original, so the grid
            // does not pull six full-resolution photographs to draw at 100pt.
            URLQueryItem(name: "iiurlwidth", value: "400")
        ]
        guard let url = comps?.url else { throw ServiceError.badQuery }

        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ServiceError.transport("No response from Wikimedia Commons.")
        }
        guard http.statusCode == 200 else {
            throw ServiceError.transport("Wikimedia Commons returned HTTP \(http.statusCode).")
        }

        // `formatversion=2` makes `pages` an ARRAY rather than a dictionary
        // keyed by page ID, which also means search relevance order is
        // preserved. The dictionary form loses it, which is why it is asked for.
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let query = root["query"] as? [String: Any],
              let pages = query["pages"] as? [[String: Any]]
        else { return [] }

        return pages.compactMap(parse)
    }

    private static func parse(_ page: [String: Any]) -> CommonsImage? {
        guard let title = page["title"] as? String,
              let infos = page["imageinfo"] as? [[String: Any]],
              let info = infos.first
        else { return nil }

        // Photographs only. Commons is full of SVG diagrams, PDFs, TIFF scans
        // and audio for any given place name, and `filetype:bitmap` narrows but
        // does not guarantee.
        let mime = (info["mime"] as? String) ?? ""
        guard mime == "image/jpeg" || mime == "image/png" else { return nil }

        guard let fullString = info["url"] as? String, let fullURL = URL(string: fullString)
        else { return nil }

        // Fall back to the original if no thumbnail came back — a heavier grid
        // beats an empty one.
        let thumbString = (info["thumburl"] as? String) ?? fullString
        guard let thumbURL = URL(string: thumbString) else { return nil }

        let meta = info["extmetadata"] as? [String: Any]
        let artist = strippingTags(value(meta, "Artist"))
        let license = value(meta, "LicenseShortName")

        // Original dimensions, with the thumbnail's as a fallback: the thumbnail
        // is a proportional resize, so its ratio is the original's ratio.
        let width = (info["width"] as? Int) ?? (info["thumbwidth"] as? Int)
        let height = (info["height"] as? Int) ?? (info["thumbheight"] as? Int)

        return CommonsImage(id: title, thumbURL: thumbURL, fullURL: fullURL,
                            artist: artist, licenseName: license,
                            pixelWidth: width, pixelHeight: height)
    }

    private static func value(_ meta: [String: Any]?, _ key: String) -> String? {
        guard let entry = meta?[key] as? [String: Any],
              let raw = entry["value"] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// `extmetadata` values are HTML — the Artist field routinely arrives as an
    /// anchor tag wrapping a name. Stripped rather than rendered: this ends up in
    /// a frontmatter field a human reads, and markup in a note is worse than a
    /// slightly plainer credit.
    private static func strippingTags(_ html: String?) -> String? {
        guard let html else { return nil }
        let stripped = html
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#039;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
        let collapsed = stripped
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }
}
