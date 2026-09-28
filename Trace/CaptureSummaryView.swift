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

/// What the host app lets this card do in-process (D517).
///
/// **Both of the card's Trace buttons were dead in the merged app.** They open
/// `trace://saveplace` and `trace://discover`, and since the merged app took the
/// `trace://` scheme that is the app opening its own URL while frontmost -
/// which D376 found does not fire `onOpenURL`. The old Trace app used to answer
/// both; it retired on 2026-09-20. David pressed Save as a Place on Dayflow
/// build 94: *"nothing happens."*
///
/// This file is also compiled by Jot, so it cannot name `TraceRouter` or
/// `SaveCaptureAsPlaceSheet` (not in Jot's list) - D440's trap. The host sets
/// these at launch, the D493/D507 shape. **Where nothing sets them the card
/// behaves exactly as before**: Jot opens the URL, which is another app there
/// and does cross.
enum CaptureCardHost {
    /// Hands a `trace://` URL to the host's router. `true` if it was taken.
    @MainActor static var deliver: ((URL) -> Bool)? = nil
    /// Builds the host's save-as-place sheet for a loaded capture.
    @MainActor static var savePlaceSheet: ((Capture) -> AnyView)? = nil
}

/// The pin's line in its day note: `[label](capture://open?id=<id>)` (D401).
///
/// Rewrites the LABEL of the one marker carrying this capture's ID, in the day
/// note of the day it was pinned. Link and every other line are untouched.
/// Best effort: a note that cannot be read or written changes nothing else.
/// D518 wrote it for Save as a Place; D520 moved it here so Rename and Match
/// use the same code.
enum PinMarker {
    @MainActor
    static func relabel(captureID: String, pinnedAt: Date, to newLabel: String) {
        let label = newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "]", with: ")")
            .replacingOccurrences(of: "[", with: "(")
        guard !label.isEmpty else { return }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        let path = "Calendar/\(f.string(from: pinnedAt)).md"
        guard let raw = try? NoteStore.shared.readFile(path), !raw.isEmpty else { return }
        let id = NSRegularExpression.escapedPattern(for: captureID)
        guard let regex = try? NSRegularExpression(
            pattern: "\\[[^\\]]*\\]\\((capture://open\\?id=\(id))\\)") else { return }
        let range = NSRange(raw.startIndex..., in: raw)
        let template = "[" + NSRegularExpression.escapedTemplate(for: label) + "]($1)"
        let updated = regex.stringByReplacingMatches(in: raw, range: range, withTemplate: template)
        guard updated != raw else { return }
        try? NoteStore.shared.writeFile(path, content: updated)
    }
}

struct CaptureSummaryView: View {
    let captureID: String
    /// One sub-sheet host for the card's three sheets (D517, D520): Save as a
    /// Place, Match a place, Rename. One `.sheet(item:)` rather than three
    /// stacked `.sheet` modifiers, the rule the task edit sheet taught.
    private enum CardSheet: Identifiable {
        case save(Capture), match(Capture), rename(Capture)
        var id: String {
            switch self {
            case .save(let c):   return "save-\(c.id)"
            case .match(let c):  return "match-\(c.id)"
            case .rename(let c): return "rename-\(c.id)"
            }
        }
    }
    @State private var cardSheet: CardSheet? = nil

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
        .sheet(item: $cardSheet) { sheet in
            switch sheet {
            case .save(let c):
                if let make = CaptureCardHost.savePlaceSheet { make(c) }
            case .match(let c):
                PinMatchPlaceSheet(capture: c) { place in
                    capture?.placeID = place.id
                    capture?.placeName = place.name
                }
                .environment(notion)
            case .rename(let c):
                PinRenameSheet(capture: c) { name, category, notes in
                    capture?.placeName = name
                    capture?.category = category
                    capture?.notes = notes
                }
                .environment(notion)
            }
        }
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

            // NAME THIS PIN (D520). David: *"shouldnt there be a way within the
            // card even later for me to match it to an existing place or rename
            // it?"* Save as a Place was the only naming act, and it creates a
            // place and logs a visit - wrong for "this was Orangetheory" and for
            // "call it the soccer field". Neither of these creates anything.
            VStack(alignment: .leading, spacing: 6) {
                Text("NAME THIS PIN")
                    .font(.caption2.weight(.semibold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button { cardSheet = .match(capture) } label: {
                        Label("Match a place", systemImage: "mappin.and.ellipse")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Button { cardSheet = .rename(capture) } label: {
                        Label("Rename", systemImage: "pencil")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal, 20)

            VStack(spacing: 10) {
                // **Was "Open in Trace", and it had stopped meaning anything**
                // (Session 103). David: *"the link still says open in trace
                // which means nothing now."* He is right: this card IS the
                // capture, so opening Trace only drew the same card in another
                // app. What Trace can do that Dayflow cannot is make this spot
                // a Place — places are Trace's, and "this one is worth keeping"
                // is the only thing left to say about a pin you are looking at.
                Button {
                    // D517: in-process when the host can, the URL otherwise.
                    if CaptureCardHost.savePlaceSheet != nil {
                        cardSheet = .save(capture)
                        return
                    }
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
                        // D517: the merged app's router when it is the host;
                        // opening its own scheme from inside goes nowhere.
                        if let url = comps.url {
                            if let deliver = CaptureCardHost.deliver, deliver(url) {
                                // taken in-process
                            } else {
                                openURL(url)
                            }
                        }
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

// MARK: - Name this pin (D520)

/// His own places, nearest to where the pin was dropped first, with search.
/// Picking one links the pin to it and renames the pin and its note line.
/// **Logs no visit** - a pin records standing somewhere; a visit is a claim he
/// makes through check-in. D398 took the automatic 500 m guess away on purpose,
/// so this list never preselects: he picks.
struct PinMatchPlaceSheet: View {
    let capture: Capture
    let onMatched: (Place) -> Void
    @Environment(NotionService.self) private var notion
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var saving = false
    @State private var errorText: String? = nil

    private func distance(to place: Place) -> Double? {
        guard let lat = capture.gpsLat, let lon = capture.gpsLon else { return nil }
        let a = CLLocation(latitude: lat, longitude: lon)
        return a.distance(from: CLLocation(latitude: place.latitude, longitude: place.longitude))
    }

    private var rows: [Place] {
        let q = search.trimmingCharacters(in: .whitespaces)
        let base = q.isEmpty ? notion.places
            : notion.places.filter { $0.name.localizedCaseInsensitiveContains(q)
                || $0.city.localizedCaseInsensitiveContains(q) }
        return base.sorted { (distance(to: $0) ?? .infinity) < (distance(to: $1) ?? .infinity) }
    }

    private func label(_ meters: Double?) -> String {
        guard let m = meters else { return "" }
        return m < 1000 ? "\(Int(m.rounded())) m" : String(format: "%.1f km", m / 1000)
    }

    var body: some View {
        NavigationStack {
            List {
                if let errorText {
                    Text(errorText).foregroundStyle(.red).font(.footnote)
                }
                Section(search.isEmpty ? "Nearest to this pin" : "Matches") {
                    ForEach(rows.prefix(40)) { place in
                        Button {
                            Task { await pick(place) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(place.name).foregroundStyle(.primary)
                                    Text(place.category).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(label(distance(to: place))).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .disabled(saving)
                    }
                }
            }
            .searchable(text: $search, prompt: "Search your places")
            .navigationTitle("Match a place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .task { if notion.places.isEmpty { await notion.fetchPlaces() } }
        }
    }

    @MainActor
    private func pick(_ place: Place) async {
        saving = true
        do {
            try await notion.matchCapture(id: capture.id, to: place)
            PinMarker.relabel(captureID: capture.id, pinnedAt: capture.timestamp, to: place.name)
            onMatched(place)
            dismiss()
        } catch {
            // A save that did not happen says so; the pin keeps its old name.
            errorText = "Couldn't reach Notion: \(error.localizedDescription)"
            saving = false
        }
    }
}

/// Name, category and note for a pin that is not worth being a place - a
/// parking space, a field. Creates nothing. Time, location and photo are the
/// record of the pin and are deliberately not editable.
struct PinRenameSheet: View {
    let capture: Capture
    let onSaved: (String, String?, String) -> Void
    @Environment(NotionService.self) private var notion
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var category = ""
    @State private var notes = ""
    @State private var saving = false
    @State private var errorText: String? = nil

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("What is this spot?", text: $name)
                }
                Section("Category") {
                    Picker("Category", selection: $category) {
                        Text("None").tag("")
                        ForEach(PlaceCategory.all, id: \.self) { Text($0).tag($0) }
                    }
                }
                Section {
                    TextField("Row F, near the east gate", text: $notes, axis: .vertical)
                        .lineLimit(2...5)
                } header: {
                    Text("Note")
                } footer: {
                    Text("Changes only this pin, here and in the day note. It does not create a place.")
                }
                if let errorText {
                    Text(errorText).foregroundStyle(.red).font(.footnote)
                }
            }
            .navigationTitle("Rename pin")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                name = capture.placeName ?? ""
                category = capture.category ?? ""
                notes = capture.notes
            }
        }
    }

    @MainActor
    private func save() async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let cat: String? = category.isEmpty ? nil : category
        saving = true
        do {
            try await notion.renameCapture(id: capture.id, name: trimmed, category: cat, notes: note)
            PinMarker.relabel(captureID: capture.id, pinnedAt: capture.timestamp, to: trimmed)
            onSaved(trimmed, cat, note)
            dismiss()
        } catch {
            errorText = "Couldn't reach Notion: \(error.localizedDescription)"
            saving = false
        }
    }
}
