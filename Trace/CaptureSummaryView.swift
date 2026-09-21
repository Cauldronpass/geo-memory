// CaptureSummaryView.swift — new file, shared across Jot, Dayflow, and Trace targets.
//
// Session 45 addendum 6 — the summary sheet presented when a tappable Quick
// Pin marker (`[label](capture:ID)` in note text — see JotTextView.swift's
// dropPin()/handleTap() and MarkdownEditorView.swift's dropPin()/handleTap())
// is tapped. Same precedent as DayflowWikiSummaryView.swift for people/
// places: a lightweight, dependency-light view usable from Jot/Dayflow, which
// don't have Trace's own Capture screens. Mockup-approved shape (shown to
// David 2026-07-25): place name or "Dropped Pin" header, timestamp, small
// static map preview, "Open in Trace" + "Open in Google Maps" buttons.
//
// **Resolution, not from the cache:** fetches the Capture fresh via
// NotionService.fetchCapture(id:) rather than trusting the in-memory
// notion.captures array. That array is filtered to Status == "Unlinked" (see
// fetchCaptures()), so a capture that's since been linked or archived would
// silently be absent from it even though the marker in the note is still
// perfectly valid — a direct pages/{id} GET resolves regardless of status.
//
// **Place name resolution:** deliberately does NOT read Capture.placeName.
// That field is the Notion page's title, and every existing saveCapture()
// caller (this feature's dropPin() in both text views, and
// QuickPinLabelSheet.swift's own save()) sets it to the capture's timestamp
// string, not the matched place's actual name — so Capture.placeName is
// really "page title," not "place name," despite the property name. Flagged,
// not touched, in this addendum's HANDOFF entry — out of scope here, since
// fixing it would change the Notion database's Name column for every capture
// going forward, unrelated existing call sites included. Instead this view
// resolves the real name itself via Capture.placeID against NotionService's
// already-loaded places list, which is unaffected by that quirk.
//
// **"Open in Trace" is always shown**, no installed-app check — matches
// DayflowWikiSummaryView.swift's existing "Log a Visit in Trace" / "Log
// Interaction in Trace" buttons, which use the same trace:// hand-off pattern
// unconditionally (confirmed 2026-07-25: no canOpenURL check anywhere in this
// project). If Trace isn't installed, openURL silently no-ops, same as those.

import SwiftUI
import MapKit

struct CaptureSummaryView: View {
    let captureID: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(NotionService.self) private var notion

    @State private var capture: Capture?
    @State private var isLoading = true
    @State private var loadFailed = false

    /// Resolved via Capture.placeID against notion.places — see header
    /// comment for why Capture.placeName itself isn't used here.
    /// The one place this card names the spot.
    ///
    /// **It used to be printed twice** — navigation title and body headline —
    /// which was survivable while pins matched a nearby place and read
    /// "Sorelle Italian Market" in both. D398 stopped pins looking up places,
    /// so `placeID` is now nil on every pin and both lines fell through to
    /// "Dropped Pin", one above the other. David, seeing it: *"the 'dropped
    /// Pin' is still there twice."*
    ///
    /// The fallback order changed with it. `placeName` used to be ignored
    /// deliberately, because every caller set it to a timestamp string and the
    /// field was "page title" wearing a place's name. **The pin now writes the
    /// street address there** (D401), so it is worth reading — and a capture
    /// old enough to hold a timestamp still reads better than "Dropped Pin".
    private var displayName: String {
        if let capture, let placeID = capture.placeID,
           let place = notion.places.first(where: { $0.id == placeID }) {
            return place.name
        }
        if let name = capture?.placeName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return name
        }
        return "Dropped Pin"
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let capture {
                    content(for: capture)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "mappin.slash")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("Couldn't load this pin")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            // **"Pin", not the name.** The name is the headline four points
            // below this; a title bar repeating it is the duplication David
            // reported, and a card this short has no need of a second label.
            .navigationTitle(isLoading ? "" : "Pin")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.bold()
                }
            }
        }
        .task { await load() }
    }

    @ViewBuilder
    private func content(for capture: Capture) -> some View {
        // **A `ScrollView`, which is the fix for the title collision** (D482).
        //
        // David: *"when i pin a location the word 'Pin' is scrunched by the
        // address. when I drag the card up it expands and looks ok."* Exactly
        // right, and the "when I drag it up" half is the diagnosis: this card
        // is presented at `.medium`, and its content — headline, timestamp, a
        // 180pt map and three buttons — is taller than half a phone. With no
        // scroller, the stack had nowhere to go and rode up under the inline
        // navigation title, so "Pin" and the street address drew on the same
        // line. At `.large` there is room, so it looked correct there, which
        // is what made it read as a rendering glitch rather than an overflow.
        //
        // Fixed here rather than at the five call sites that present this
        // sheet, and fixed by letting the content scroll rather than by
        // dropping the `.medium` detent — a half card that expands is the
        // right shape for a pin, and it was only ever the overflow that was
        // wrong.
        ScrollView {
        VStack(spacing: 20) {
            VStack(spacing: 4) {
                Text(displayName)
                    .font(.title2.weight(.semibold))
                Text(capture.timestamp.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 12)

            if let lat = capture.gpsLat, let lon = capture.gpsLon {
                // Static preview — David confirmed 2026-07-25 he wants this,
                // specifically as something shown on every marker tap. Fixed
                // initial camera position, no live $binding, plus
                // allowsHitTesting(false) so it can't be panned/zoomed away —
                // this is a preview, not Trace's own interactive MapView.swift.
                // First MapKit usage in the Jot/Dayflow targets — if either
                // target's build fails on `import MapKit` specifically, add
                // MapKit under that target's Build Phases → Link Binary With
                // Libraries in Xcode (system frameworks in Swift are usually
                // auto-linked, but flagging this as the one manual-Xcode-step
                // fallback per this project's own convention of calling out
                // new dependencies).
                Map(initialPosition: .region(MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                    span: MKCoordinateSpan(latitudeDelta: 0.006, longitudeDelta: 0.006)
                ))) {
                    Marker(displayName, coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon))
                }
                .allowsHitTesting(false)
                .frame(height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 20)
            }

            VStack(spacing: 10) {
                // **Was "Open in Trace", and it had stopped meaning anything**
                // (Session 103). David: *"the link still says open in trace
                // which means nothing now."* He is right: this card IS the
                // capture, so opening Trace only drew the same card in another
                // app. What Trace can do that Dayflow cannot is make this spot
                // a Place — places are Trace's, and "this one is worth keeping"
                // is the only thing left to say about a pin you are looking at.
                Button {
                    var comps = URLComponents()
                    comps.scheme = "trace"
                    comps.host = "saveplace"
                    comps.queryItems = [URLQueryItem(name: "id", value: capture.id)]
                    if let url = comps.url { openURL(url) }
                } label: {
                    Label("Save as a Place", systemImage: "mappin.and.ellipse")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                // **Context, which the preview above cannot give** (D403).
                // David: *"show that pin in Trace Discover tab on the map next
                // to my other places… nice to see context."* The static map
                // here says where the point is; Discover says what of his is
                // around it, which is the question actually being asked.
                if let lat = capture.gpsLat, let lon = capture.gpsLon {
                    Button {
                        // **Both paths, because this card runs in two apps.**
                        // Inside Trace, `openURL` on a `trace://` URL does
                        // nothing at all — D376's lesson, in Dayflow's own
                        // words — so the router is what carries it. Inside
                        // Dayflow or Jot the router is inert and the URL is
                        // what crosses. Exactly one is live either way.
                        TraceDiscoverRouter.shared.pin = DiscoverDroppedPin(
                            latitude: lat, longitude: lon, label: displayName)
                        var comps = URLComponents()
                        comps.scheme = "trace"
                        comps.host = "discover"
                        comps.queryItems = [
                            URLQueryItem(name: "lat", value: String(lat)),
                            URLQueryItem(name: "lon", value: String(lon)),
                            URLQueryItem(name: "label", value: displayName)
                        ]
                        if let url = comps.url { openURL(url) }
                        // The map is the destination; a card still covering it
                        // is the same dead end in a different costume.
                        dismiss()
                    } label: {
                        Label("Show on My Map", systemImage: "map.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                if let lat = capture.gpsLat, let lon = capture.gpsLon,
                   let mapsURL = URL(string: "https://maps.google.com/?q=\(lat),\(lon)") {
                    Button {
                        openURL(mapsURL)
                    } label: {
                        Label("Open in Google Maps", systemImage: "map")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal, 20)

            Spacer(minLength: 0)
        }
        .padding(.bottom, 16)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func load() async {
        // notion.places is needed for displayName's placeID lookup. Only
        // fetched if empty — Jot/Dayflow are separate processes from Trace,
        // each with their own NotionService.shared instance, so there's no
        // guarantee places were ever loaded this launch; but if they were
        // (e.g. dropPin() itself already touches NotionService.shared.places
        // for the proximity match), no need to refetch just to show a sheet.
        if notion.places.isEmpty {
            await notion.fetchPlaces()
        }
        do {
            capture = try await notion.fetchCapture(id: captureID)
        } catch {
            loadFailed = true
        }
        isLoading = false
    }
}
