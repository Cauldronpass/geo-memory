import SwiftUI
import CoreLocation
import Observation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Pin address (D398, Session 103)

/// What a dropped pin is CALLED.
///
/// **A pin marks where you are; it does not claim you went anywhere.** Until
/// Session 103 both pin paths named the line after the nearest Trace place
/// within 500 m, which meant standing in the kitchen produced "Sorelle Italian
/// Market" in the daily note. David: *"I wouldnt necessarily use this for
/// adding that i was at a place... thats what check-in is for."* Right, and the
/// place lookup is gone from the pin for that reason. Check-in keeps it, which
/// is the whole difference between the two.
///
/// The street address is what replaced it, and that also makes the "Address"
/// pin honest: it used to write the literal word `Address` and geocode nothing,
/// a button naming something it never produced.
///
/// **Three answers, in falling order of usefulness, and it never throws.** A
/// street; failing that the coordinates, which are still a real location a map
/// can open; failing that nil, and the caller says "Dropped Pin". A pin taken
/// in a car park with no signal has to land in the note regardless, because
/// that is exactly where it was worth taking.
enum PinAddress {

    static func describe(_ coordinate: CLLocationCoordinate2D) async -> String? {
        let loc = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let marks = try? await CLGeocoder().reverseGeocodeLocation(loc)
        guard let pm = marks?.first else { return coordinates(coordinate) }

        // Street first. `name` is often the street line already and sometimes
        // a venue; number + thoroughfare is the one that is reliably a street,
        // so it wins when both are there.
        let street = [pm.subThoroughfare, pm.thoroughfare]
            .compactMap { $0 }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        if !street.isEmpty {
            if let city = pm.locality, !city.isEmpty, city != street {
                return "\(street), \(city)"
            }
            return street
        }
        // No street: a park, a lake, a motorway. The locality still beats
        // a pair of numbers.
        if let name = pm.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty { return name }
        if let city = pm.locality, !city.isEmpty { return city }
        return coordinates(coordinate)
    }

    /// Four decimal places is about 11 m, which is the right precision for
    /// "where I parked" and short enough to read in a note line.
    static func coordinates(_ c: CLLocationCoordinate2D) -> String {
        String(format: "%.4f, %.4f", c.latitude, c.longitude)
    }
}

// MARK: - A pin sent to Discover for context (D403)

/// Somewhere to look at, handed to the Discover map from another screen.
///
/// David, on the capture card: *"is there a way to add a button to show that
/// pin in Trace Discover tab on the map next to my other places? that would be
/// nice to see context."* The context is the point: a lone coordinate on a map
/// says almost nothing, and the same coordinate with his saved places around it
/// says where he was.
///
/// Latitude and longitude rather than a `CLLocationCoordinate2D` because this
/// has to be `Equatable` to drive `onChange`, and Apple's coordinate type is
/// not.
struct DiscoverDroppedPin: Equatable, Hashable {
    let latitude: Double
    let longitude: Double
    let label: String

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// The way a pin reaches Discover when the sender is ALREADY INSIDE TRACE.
///
/// **`openURL` on your own scheme does nothing when your app is frontmost.**
/// Dayflow learned this in D376 and wrote it down: *"Dayflow's own search card
/// asks the system to open a `dayflow://` URL while Dayflow is already the
/// running app, and in that case the app is brought forward without
/// `onOpenURL` firing — so the link arrived nowhere."* `CaptureSummaryView` is
/// shown inside Trace as well as inside Dayflow, so its "Show on My Map"
/// button hit exactly that: from Dayflow it worked, from Trace it did nothing
/// at all, which is what David reported.
///
/// So the button does both. It sets this, which Trace's `ContentView` observes
/// and acts on; and it opens the URL, which is what carries the pin across
/// from Dayflow or Jot. Whichever app is running, exactly one of the two is
/// the live path and the other is inert.
///
/// It lives here rather than beside `DiscoverView` because this file is
/// compiled by Dayflow too, and the shared card cannot name a Trace-only type.
@Observable
final class TraceDiscoverRouter {
    static let shared = TraceDiscoverRouter()
    var pin: DiscoverDroppedPin?
    private init() { }
}

// MARK: - Quick Pin (D401, Session 103)

#if !os(macOS)

/// Dropping a pin, in one place, for whichever app is asking.
///
/// **It moved out of Trace's `ContentView` because the Action Button should not
/// launch an app.** A `trace://` URL has no choice: iOS brings the app forward,
/// every time, and David's pin was opening Trace for no visible reason and
/// leaving him to go to Dayflow to see the result. Only an `AppIntent` with
/// `openAppWhenRun = false` runs without a launch, Dayflow already has four of
/// those, and the daily note this writes has been Dayflow's file since D392.
/// So the action belongs to Dayflow and the logic belongs to neither — it
/// belongs here, where both compile it.
///
/// **Guarded off macOS** because `LocationManager` is not in the TraceMac
/// target, and this file is.
@MainActor
enum QuickPin {

    struct Result {
        /// The line as it was written into the daily note.
        let line: String
        /// Whether the marker carries a `capture://` link. False means Notion
        /// was unreachable and the line went in unlinked, which is the honest
        /// outcome in a car park.
        let linked: Bool
    }

    enum Failure: LocalizedError {
        case noLocation
        case nothingWritten

        var errorDescription: String? {
            switch self {
            case .noLocation:
                return "Couldn't get your location — check Location Services, then try again."
            case .nothingWritten:
                return "Couldn't save the pin — no location note and no capture. Try again."
            }
        }
    }

    /// Waits for a fix, names the spot, files a capture, and appends the marker
    /// to today's daily note.
    ///
    /// **The note line is the deliverable; the capture is only its link.** An
    /// earlier version returned as soon as the Notion write failed, so a pin
    /// with no signal reached nothing at all — and an underground car park is
    /// the likeliest place to press this. A failed capture now costs the marker
    /// its link and nothing else.
    static func drop(label: String? = nil, emoji: String? = nil,
                     date: Date = Date()) async throws -> Result {
        if LocationManager.shared.location == nil {
            LocationManager.shared.requestPermission()
            LocationManager.shared.startUpdating()
            for _ in 0..<20 {
                if LocationManager.shared.location != nil { break }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
        guard let loc = LocationManager.shared.location else { throw Failure.noLocation }

        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        let timeStr = formatter.string(from: date)

        // **No nearest-place match** (D398). A pin marks where you are and makes
        // no claim about having been anywhere; the 500 m match is check-in's.
        let where_ = await PinAddress.describe(loc.coordinate)
        let display: String
        if let label, !label.isEmpty {
            let prefix = emoji.map { "\($0) " } ?? ""
            display = "\(prefix)\(label) · \(where_ ?? "Dropped Pin") · \(timeStr)"
        } else {
            display = "📍 \(where_ ?? "Dropped Pin") · \(timeStr)"
        }

        var pageID: String? = nil
        do {
            pageID = try await NotionService.shared.saveCapture(
                notes: display,
                placeID: nil,
                // Not `display` again: the capture card draws the name and the
                // notes as two lines, and the same string in both printed the
                // pin twice on every card David opened (D401).
                placeName: where_ ?? "Dropped Pin",
                lat: loc.coordinate.latitude,
                lon: loc.coordinate.longitude,
                photoURL: nil
            )
        } catch {
            pageID = nil
        }

        let marker = pageID.map { "[\(display)](capture://open?id=\($0)) " } ?? "\(display) "
        do {
            try NoteStore.shared.appendToDailyNote(marker, date: date)
        } catch {
            throw Failure.nothingWritten
        }
        return Result(line: display, linked: pageID != nil)
    }
}

#endif

// MARK: - Flow Layout (wrapping chips)

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        layout(subviews: subviews, in: proposal.replacingUnspecifiedDimensions().width).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(subviews: subviews, in: bounds.width)
        for (index, frame) in result.frames.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private struct LayoutResult {
        var frames: [CGRect]
        var size: CGSize
    }

    private func layout(subviews: Subviews, in maxWidth: CGFloat) -> LayoutResult {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            lineHeight = max(lineHeight, size.height)
            x += size.width + spacing
        }
        return LayoutResult(frames: frames, size: CGSize(width: maxWidth, height: y + lineHeight))
    }
}

// MARK: - Place colors

func placeColor(for category: String) -> Color {
    switch category.lowercased() {
    case "restaurant": return .orange
    case "bar": return .purple
    case "cafe": return .brown
    case "hotel": return .teal
    case "shop": return .pink
    case "attraction": return .red
    case "venue": return .indigo
    case "house": return .yellow
    case "temp": return .gray
    case "fitness": return .green
    case "office": return .blue
    case "airport": return .cyan
    case "medical": return .mint
    case "park": return Color(red: 0.2, green: 0.6, blue: 0.15)
    case "grocery": return Color(red: 0.8, green: 0.45, blue: 0.0)
    // D333. Five hues chosen to sit apart from the fourteen above rather than
    // near them — the whole job of this colour is telling one pin from another
    // on a map, and a near-miss is worse than an odd choice.
    case "city":    return Color(red: 0.36, green: 0.45, blue: 0.58)   // steel
    case "gas":     return Color(red: 0.80, green: 0.25, blue: 0.30)   // crimson
    case "school":  return Color(red: 0.48, green: 0.52, blue: 0.20)   // olive
    case "parking": return Color(red: 0.45, green: 0.42, blue: 0.68)   // slate violet
    case "service": return Color(red: 0.50, green: 0.42, blue: 0.36)   // warm grey
    default: return .gray
    }
}

// MARK: - Super-category system (4 groups for calendar display)

func superCategoryColor(for category: String) -> Color {
    switch category.lowercased() {
    case "restaurant", "cafe", "bar", "grocery": return .orange
    case "fitness", "park", "medical":            return .green
    case "attraction", "venue", "hotel", "airport", "city": return .indigo
    default: return Color(.systemGray)  // house, office, shop, gas, parking, service, school, temp
    }
}

func superCategoryName(for category: String) -> String {
    switch category.lowercased() {
    case "restaurant", "cafe", "bar", "grocery":    return "Food & Drink"
    case "fitness", "park", "medical":              return "Active & Health"
    // **City joins Out & About, the other four are Everyday** (D333). A city is
    // somewhere you went; a gas station, a garage, a school run and a car park
    // are the texture of a normal week, which is what Everyday is for.
    case "attraction", "venue", "hotel", "airport", "city": return "Out & About"
    default:                                                return "Everyday"
    }
}

func placeIcon(for category: String) -> String {
    switch category.lowercased() {
    case "restaurant": return "fork.knife"
    case "bar": return "wineglass"
    case "cafe": return "cup.and.saucer"
    case "hotel": return "bed.double"
    case "shop": return "bag"
    case "attraction": return "star"
    case "venue": return "music.mic"
    case "house": return "house"
    case "temp": return "clock"
    case "fitness": return "figure.run"
    case "office": return "building.2"
    case "airport": return "airplane"
    case "medical": return "stethoscope"
    case "park": return "leaf"
    case "grocery": return "cart"
    case "city":    return "building.2.crop.circle"
    case "gas":     return "fuelpump"
    case "school":  return "graduationcap"
    case "parking": return "parkingsign"
    case "service": return "wrench.and.screwdriver"
    default: return "mappin"
    }
}

// MARK: - Place pin

struct PlacePin: View {
    let place: Place

    var body: some View {
        ZStack {
            Circle()
                .fill(place.flagged ? Color.yellow : placeColor(for: place.category))
                .frame(width: 32, height: 32)
            Image(systemName: placeIcon(for: place.category))
                .font(.system(size: 14))
                .foregroundStyle(.white)
        }
        .shadow(radius: 3)
    }
}


// MARK: - Directions

/// Opens turn-by-turn directions to a place in Apple Maps.
///
/// **Directions were written four separate times before this** — iOS's
/// `PlaceDetailView.actionBar`, `DiscoverView`, `TraceMacDiscoverView`'s own
/// `openDirections(to:from:)` and `FlaggedView` — and the four disagreed on the
/// URL scheme, on whether to pass `dirflg`, and on whether to prefer
/// `googleMapsURL` over coordinates. This is the iOS place-detail shape, which
/// is the one David asked the Mac to copy: *"Id like directions to show up like
/// we have in the ios version."*
///
/// `maps://`, **not** `https://maps.apple.com`. The http(s) form silently did
/// nothing on iOS until Session 53 caught it, and the note above
/// `TraceMacDiscoverView.openDirections` records the same finding. The custom
/// scheme behaves identically under `NSWorkspace` on the Mac.
///
/// Coordinates rather than `googleMapsURL`: a Google URL opens a browser and
/// makes you choose an app, where lat/long drops straight into a route. No
/// `saddr`, so the origin is wherever you are — the Mac has no `LocationManager`
/// to ask, and Maps resolves that itself.
func openMapsDirections(to place: Place) {
    let destination: String
    if place.latitude == 0 && place.longitude == 0 {
        // A place added by hand can have no coordinates at all, and routing to
        // 0,0 puts you in the Gulf of Guinea. Fall back to a name search, which
        // at least lands somewhere real.
        let query = "\(place.name) \(place.address)".trimmingCharacters(in: .whitespaces)
        destination = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
    } else {
        destination = "\(place.latitude),\(place.longitude)"
    }
    guard !destination.isEmpty,
          let url = URL(string: "maps://?daddr=\(destination)") else { return }
    #if os(macOS)
    NSWorkspace.shared.open(url)
    #else
    UIApplication.shared.open(url)
    #endif
}

/// Opens a place in Maps to LOOK at it, as opposed to `openMapsDirections`,
/// which opens it to go there.
///
/// `q=` plus `ll=` rather than `daddr=`: the same coordinates, but Maps drops a
/// labelled pin and sits still instead of computing a route from wherever you
/// are. The name is what makes the pin say something when it lands.
func openMapsPlace(_ place: Place) {
    guard place.latitude != 0 || place.longitude != 0 else { return }
    let name = place.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
    guard let url = URL(string: "maps://?q=\(name)&ll=\(place.latitude),\(place.longitude)")
    else { return }
    #if os(macOS)
    NSWorkspace.shared.open(url)
    #else
    UIApplication.shared.open(url)
    #endif
}
