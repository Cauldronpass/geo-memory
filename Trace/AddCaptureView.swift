import SwiftUI
import MapKit
import CoreLocation
import PhotosUI
import VisionKit

struct AddCaptureView: View {
    @Environment(NotionService.self) private var notion
    @Environment(LocationManager.self) private var locationManager
    @Environment(\.dismiss) private var dismiss

    @State private var notes = ""
    @State private var selectedPlace: Place? = nil
    @State private var isSaving = false
    @State private var showingPlacePicker = false

    // Person
    @State private var selectedPerson: Person? = nil
    @State private var showingPersonPicker = false

    // Photo — reuses CameraView / DocumentScannerView from AddPhotoView.swift
    @State private var capturedImage: UIImage? = nil
    @State private var showingCamera = false
    @State private var showingScanner = false
    @State private var selectedPhotoItem: PhotosPickerItem? = nil
    @State private var showingPhotoPicker = false
    @State private var showingReplaceOptions = false

    // MARK: - Photo section (extracted to avoid type-checker timeout)

    @ViewBuilder private var personSection: some View {
        Section("Person") {
            if let person = selectedPerson {
                HStack {
                    Text(person.name).font(.body)
                    Spacer()
                    Button("Change") { showingPersonPicker = true }.font(.caption)
                    Button("Remove", role: .destructive) { selectedPerson = nil }.font(.caption)
                }
            } else {
                Button { showingPersonPicker = true } label: {
                    HStack {
                        Text("Select a person").foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary).font(.caption)
                    }
                }
            }
        }
    }

    @ViewBuilder private var photoSection: some View {
        Section("Photo") {
            if let image = capturedImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 200)
                    .cornerRadius(8)
                HStack {
                    Button("Replace") { showingReplaceOptions = true }.font(.caption)
                    Spacer()
                    Button("Remove", role: .destructive) {
                        capturedImage = nil
                        selectedPhotoItem = nil
                    }
                    .font(.caption)
                }
            } else {
                Button { showingPhotoPicker = true } label: {
                    Label("Choose from Library", systemImage: "photo.on.rectangle")
                }
                Button { showingCamera = true } label: {
                    Label("Take Photo", systemImage: "camera")
                }
                Button { showingScanner = true } label: {
                    Label("Scan Document", systemImage: "doc.viewfinder")
                }
            }
        }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Form {
                Section("Place") {
                    if let place = selectedPlace {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(place.name).font(.body)
                                Text(place.city).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Change") { showingPlacePicker = true }.font(.caption)
                        }
                    } else {
                        Button { showingPlacePicker = true } label: {
                            HStack {
                                Text("Select a place").foregroundStyle(.secondary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.tertiary).font(.caption)
                            }
                        }
                    }
                    Button("Save without a place") { selectedPlace = nil }
                        .font(.caption).foregroundStyle(.secondary)
                }

                personSection

                photoSection

                Section("Notes") {
                    TextEditor(text: $notes)
                        .frame(minHeight: 100)
                }
            }
            .navigationTitle("Add to Inbox")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") { save() }
                        .disabled((notes.isEmpty && capturedImage == nil) || isSaving)
                }
            }
            .sheet(isPresented: $showingPlacePicker) {
                PlacePickerView(selectedPlace: $selectedPlace)
                    .environment(notion)
                    .environment(locationManager)
            }
            .sheet(isPresented: $showingPersonPicker) {
                CapturePersonPickerView(selectedPerson: $selectedPerson)
                    .environment(notion)
            }
            .sheet(isPresented: $showingCamera) {
                CameraView(image: $capturedImage, isPresented: $showingCamera)
                    .ignoresSafeArea()
            }
            .sheet(isPresented: $showingScanner) {
                DocumentScannerView(image: $capturedImage, isPresented: $showingScanner)
                    .ignoresSafeArea()
            }
            .photosPicker(isPresented: $showingPhotoPicker, selection: $selectedPhotoItem, matching: .images)
            .onChange(of: selectedPhotoItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        await MainActor.run { capturedImage = image }
                    }
                    await MainActor.run { selectedPhotoItem = nil }
                }
            }
            .confirmationDialog("Replace Photo", isPresented: $showingReplaceOptions) {
                Button("Choose from Library") { showingPhotoPicker = true }
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button("Take Photo") { showingCamera = true }
                }
                if VNDocumentCameraViewController.isSupported {
                    Button("Scan Document") { showingScanner = true }
                }
                Button("Cancel", role: .cancel) { }
            }
        }
    }

    // MARK: - Save

    func save() {
        isSaving = true
        Task {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd-HHmmss"
            let timestamp = formatter.string(from: Date())

            var photoPath: String? = nil
            if let image = capturedImage,
               let jpegData = image.jpegData(compressionQuality: 0.85) {
                photoPath = try? NoteStore.shared.writePhoto(
                    jpegData, category: "Inbox", filename: "\(timestamp).jpg"
                )
            }

            var lines = ["# Note"]
            let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedNotes.isEmpty { lines += ["", trimmedNotes] }
            if let place = selectedPlace { lines += ["", "**Place:** \(place.name)"] }
            if let person = selectedPerson { lines += ["", "**Person:** [[\(person.name)]]"] }
            if let path = photoPath { lines += ["", "![[../../\(path)]]"] }

            try? NoteStore.shared.writeFile(
                "Notes/Inbox/\(timestamp).md",
                content: lines.joined(separator: "\n")
            )
            await MainActor.run { isSaving = false; dismiss() }
        }
    }
}

// MARK: - Person Picker

struct CapturePersonPickerView: View {
    @Environment(NotionService.self) private var notion
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedPerson: Person?
    @State private var searchText = ""

    private var filtered: [Person] {
        let sorted = notion.people.sorted { $0.name < $1.name }
        if searchText.isEmpty { return sorted }
        return sorted.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            List(filtered, id: \.id) { person in
                Button {
                    selectedPerson = person
                    dismiss()
                } label: {
                    Text(person.name).foregroundStyle(.primary)
                }
            }
            .searchable(text: $searchText, prompt: "Search people")
            .navigationTitle("Select Person")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Place Picker

struct PlacePickerView: View {
    @Environment(NotionService.self) private var notion
    @Environment(LocationManager.self) private var locationManager
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedPlace: Place?

    @State private var searchText = ""
    @State private var searchResults: [MKMapItem] = []
    @State private var isSearching = false

    var nearbyPlaces: [Place] {
        notion.places.sorted {
            let a = locationManager.distance(to: $0) ?? .infinity
            let b = locationManager.distance(to: $1) ?? .infinity
            return a < b
        }
    }

    var filteredNearby: [Place] {
        if searchText.isEmpty { return Array(nearbyPlaces.prefix(10)) }
        return nearbyPlaces.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            List {
                if !filteredNearby.isEmpty {
                    Section("Your Places") {
                        ForEach(filteredNearby) { place in
                            Button {
                                selectedPlace = place
                                dismiss()
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(place.name).foregroundStyle(.primary)
                                        HStack(spacing: 4) {
                                            Text(place.category).foregroundStyle(.secondary)
                                            Text("·").foregroundStyle(.secondary)
                                            Text(place.city).foregroundStyle(.secondary)
                                        }
                                        .font(.caption)
                                    }
                                    Spacer()
                                    if let dist = locationManager.formattedDistance(to: place) {
                                        Text(dist).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }

                if isSearching {
                    Section { HStack { Spacer(); ProgressView(); Spacer() } }
                } else if !searchResults.isEmpty {
                    Section("Search Results") {
                        ForEach(searchResults, id: \.self) { item in
                            Button {
                                let coord = item.placemark.coordinate
                                let tempPlace = Place(
                                    id: UUID().uuidString,
                                    name: item.name ?? "Unknown",
                                    city: item.placemark.locality ?? "",
                                    address: [item.placemark.subThoroughfare,
                                              item.placemark.thoroughfare]
                                        .compactMap { $0 }.joined(separator: " "),
                                    category: "Restaurant",
                                    latitude: coord.latitude,
                                    longitude: coord.longitude,
                                    flagged: false,
                                    googlePlaceID: nil,
                                    googleMapsURL: nil,
                                    phone: nil,
                                    website: nil,
                                    hours: nil,
                                    status: "Visited",
                                    ratingExternal: nil,
                                    ratingPersonal: nil,
                                    visitCount: 0,
                                    lastVisited: nil,
                                    tags: [],
                                    aiSummary: nil
                                )
                                selectedPlace = tempPlace
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name ?? "Unknown").foregroundStyle(.primary)
                                    Text(item.placemark.locality ?? "")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Select Place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .searchable(text: $searchText, prompt: "Search your places or nearby")
            .onChange(of: searchText) { _, newValue in
                if newValue.count > 2 { performSearch(newValue) } else { searchResults = [] }
            }
        }
    }

    func performSearch(_ query: String) {
        isSearching = true
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let coord = locationManager.location?.coordinate {
            request.region = MKCoordinateRegion(
                center: coord, latitudinalMeters: 10000, longitudinalMeters: 10000
            )
        }
        Task {
            let search = MKLocalSearch(request: request)
            let response = try? await search.start()
            await MainActor.run {
                searchResults = response?.mapItems ?? []
                isSearching = false
            }
        }
    }
}
