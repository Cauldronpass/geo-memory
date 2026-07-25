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
    private var displayName: String {
        guard let capture, let placeID = capture.placeID,
              let place = notion.places.first(where: { $0.id == placeID }) else {
            return "Dropped Pin"
        }
        return place.name
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
            .navigationTitle(isLoading ? "" : displayName)
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
                Button {
                    var comps = URLComponents()
                    comps.scheme = "trace"
                    comps.host = "capture"
                    comps.queryItems = [URLQueryItem(name: "id", value: capture.id)]
                    if let url = comps.url { openURL(url) }
                } label: {
                    Label("Open in Trace", systemImage: "arrow.up.forward.app")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

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
