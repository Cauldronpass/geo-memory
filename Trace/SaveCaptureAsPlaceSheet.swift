import SwiftUI
import CoreLocation
import UserNotifications

struct SaveCaptureAsPlaceSheet: View {
    @Environment(NotionService.self) private var notion
    @Environment(\.dismiss) private var dismiss

    let capture: Capture

    enum SaveMode: String, CaseIterable {
        case personal = "Personal"
        case temp = "Temp"
    }

    private let placeCategories = [
        "Restaurant", "Bar", "Cafe", "Hotel", "Shop", "Attraction",
        "Venue", "House", "Fitness", "Office", "Airport", "Medical",
        "Park", "Grocery"
    ]

    @State private var saveMode: SaveMode = .personal
    @State private var name = ""
    @State private var category = "Attraction"
    @State private var address = ""
    @State private var city = ""
    @State private var tempLabel = ""
    @State private var tempDuration: TempDuration = .eightHours
    @State private var isGeocoding = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var coord: CLLocationCoordinate2D? {
        guard let lat = capture.gpsLat, let lon = capture.gpsLon else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    var body: some View {
        NavigationStack {
            Form {
                // Mode picker
                Section {
                    Picker("Type", selection: $saveMode) {
                        ForEach(SaveMode.allCases, id: \.self) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                }

                if saveMode == .personal {
                    Section("Place Details") {
                        TextField("Name", text: $name)
                        Picker("Category", selection: $category) {
                            ForEach(placeCategories, id: \.self) { cat in
                                Text(cat).tag(cat)
                            }
                        }
                    }

                    Section("Address") {
                        if isGeocoding {
                            HStack {
                                ProgressView().scaleEffect(0.8)
                                Text("Looking up address…")
                                    .foregroundStyle(.secondary)
                                    .font(.subheadline)
                            }
                        } else {
                            TextField("Address", text: $address)
                            TextField("City", text: $city)
                        }
                    }
                } else {
                    Section("Temp Place") {
                        TextField("Label (optional)", text: $tempLabel)
                        Picker("Expires", selection: $tempDuration) {
                            ForEach(TempDuration.allCases, id: \.self) { d in
                                Text(d.label).tag(d)
                            }
                        }
                    }

                    Section {
                        HStack(spacing: 8) {
                            Image(systemName: "clock.badge.exclamationmark")
                                .foregroundStyle(.orange)
                            Text("Expires \(tempDuration.expiry.formatted(.dateTime.month(.abbreviated).day().hour().minute()))")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red).font(.caption)
                    }
                }

                Section {
                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving {
                            HStack { Spacer(); ProgressView(); Spacer() }
                        } else {
                            Text(saveMode == .personal ? "Save Personal Place" : "Save Temp Place")
                                .frame(maxWidth: .infinity)
                                .bold()
                        }
                    }
                    .disabled(isSaving || (saveMode == .personal && name.trimmingCharacters(in: .whitespaces).isEmpty))
                }
            }
            .navigationTitle(saveMode == .personal ? "Add Personal Place" : "Add Temp Place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { await geocode() }
        }
    }

    // MARK: - Geocode

    private func geocode() async {
        guard let coord else { return }
        isGeocoding = true
        let geocoder = CLGeocoder()
        let loc = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        if let placemark = try? await geocoder.reverseGeocodeLocation(loc).first {
            let number = placemark.subThoroughfare ?? ""
            let street = placemark.thoroughfare ?? ""
            address = [number, street].filter { !$0.isEmpty }.joined(separator: " ")
            city = placemark.locality ?? ""
            if name.isEmpty {
                name = placemark.name ?? street
            }
        }
        isGeocoding = false
    }

    // MARK: - Save

    private func save() async {
        guard let coord else {
            errorMessage = "No GPS coordinates on this capture."
            return
        }
        isSaving = true
        do {
            if saveMode == .personal {
                let placeID = try await notion.addPlace(
                    name: name.trimmingCharacters(in: .whitespaces),
                    address: address,
                    city: city,
                    category: category,
                    latitude: coord.latitude,
                    longitude: coord.longitude,
                    googlePlaceID: nil,
                    phone: nil,
                    website: nil,
                    status: "Visited",
                    expires: nil
                )
                await notion.fetchPlaces()
                // Auto check-in using the capture's timestamp
                if let place = notion.places.first(where: { $0.id == placeID }) {
                    let visitID = try await notion.checkIn(
                        place: place,
                        rating: nil,
                        notes: nil,
                        date: capture.timestamp
                    )
                    await notion.fetchVisits()
                    // Link and remove capture from the shelf
                    try await notion.linkCapture(capture.id, toVisit: visitID, captureNotes: capture.notes)
                    await notion.fetchCaptures()
                }
            } else {
                let formatter = DateFormatter()
                formatter.dateFormat = "h:mm a"
                let timeStr = formatter.string(from: Date())
                let placeName = tempLabel.trimmingCharacters(in: .whitespaces).isEmpty
                    ? "Temp · \(timeStr)"
                    : tempLabel.trimmingCharacters(in: .whitespaces)
                let placeID = try await notion.addPlace(
                    name: placeName,
                    address: address,
                    city: city,
                    category: "Attraction",
                    latitude: coord.latitude,
                    longitude: coord.longitude,
                    googlePlaceID: nil,
                    phone: nil,
                    website: nil,
                    status: "Visited",
                    expires: tempDuration.expiry,
                    temporary: true
                )
                scheduleExpiryNotification(placeID: placeID, name: placeName, expiry: tempDuration.expiry)
                await notion.fetchPlaces()
                // Dismiss the capture from the shelf (no visit for temp places)
                try await notion.dismissCapture(capture.id)
                await notion.fetchCaptures()
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            isSaving = false
        }
    }

    // MARK: - Notification

    private func scheduleExpiryNotification(placeID: String, name: String, expiry: Date) {
        Task.detached {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            let content = UNMutableNotificationContent()
            content.title = "Temp Place Expiring"
            content.body = "\"\(name)\" is set to expire. Open Trace to remove or extend."
            content.sound = .default
            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: expiry)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            let request = UNNotificationRequest(
                identifier: "trace-temp-\(placeID)",
                content: content,
                trigger: trigger
            )
            try? await center.add(request)
        }
    }
}
