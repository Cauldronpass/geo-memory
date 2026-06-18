import SwiftUI
import UIKit
import CoreLocation
import PhotosUI

struct AddPhotoView: View {
    @Environment(NotionService.self) private var notion
    @Environment(LocationManager.self) private var locationManager
    @Environment(\.dismiss) private var dismiss

    @State private var photoType: PhotoType? = nil
    @State private var capturedImage: UIImage? = nil
    @State private var showingCamera = false
    @State private var showingPhotoPicker = false
    @State private var selectedPhotoItem: PhotosPickerItem? = nil
    @State private var notes = ""
    @State private var selectedPlace: Place? = nil
    @State private var showingPlacePicker = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    var cameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    var body: some View {
        NavigationStack {
            Group {
                if photoType == nil {
                    Form {
                        Section("What are you capturing?") {
                            ForEach(PhotoType.allCases, id: \.self) { type in
                                Button {
                                    photoType = type
                                    if cameraAvailable {
                                        showingCamera = true
                                    } else {
                                        showingPhotoPicker = true
                                    }
                                } label: {
                                    HStack {
                                        Text(type.emoji).font(.title2)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(type.label).foregroundStyle(.primary)
                                            Text(type == .place
                                                ? "Camera Roll + NAS (public later via Backblaze)"
                                                : "Camera Roll + NAS via Tailscale (private)")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .foregroundStyle(.tertiary).font(.caption)
                                    }
                                }
                            }
                        }
                    }
                } else if capturedImage == nil {
                    // Shouldn't normally be visible — picker opens immediately
                    VStack(spacing: 20) {
                        Spacer()
                        Image(systemName: "photo").font(.system(size: 60)).foregroundStyle(.secondary)
                        Text("No photo selected").foregroundStyle(.secondary)
                        Button("Choose from Library") { showingPhotoPicker = true }
                            .buttonStyle(.borderedProminent)
                        Spacer()
                    }
                } else {
                    Form {
                        Section {
                            Image(uiImage: capturedImage!)
                                .resizable().scaledToFit()
                                .frame(maxHeight: 260)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            if cameraAvailable {
                                Button("Retake") { showingCamera = true }
                            }
                            Button("Choose from Library") { showingPhotoPicker = true }
                        }

                        if photoType == .place {
                            Section("Place (optional)") {
                                if let place = selectedPlace {
                                    HStack {
                                        Text(place.name)
                                        Spacer()
                                        Button("Change") { showingPlacePicker = true }.font(.caption)
                                    }
                                } else {
                                    Button {
                                        showingPlacePicker = true
                                    } label: {
                                        HStack {
                                            Text("Select a place").foregroundStyle(.secondary)
                                            Spacer()
                                            Image(systemName: "chevron.right")
                                                .foregroundStyle(.tertiary).font(.caption)
                                        }
                                    }
                                }
                            }
                        }

                        Section("Note (optional)") {
                            TextField("Add a note…", text: $notes, axis: .vertical)
                                .lineLimit(3...6)
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
                                    Text("Save").frame(maxWidth: .infinity).bold()
                                }
                            }
                            .disabled(isSaving)
                        }

                        Section {
                            HStack {
                                Image(systemName: photoType == .place ? "photo.on.rectangle" : "lock.fill")
                                    .foregroundStyle(photoType == .place ? .blue : .green)
                                Text(photoType == .place
                                    ? "Saves to Camera Roll + NAS"
                                    : "Saves to Camera Roll + NAS (private)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle(photoType?.label ?? "Add Photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if photoType != nil {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Back") {
                            photoType = nil
                            capturedImage = nil
                        }
                    }
                }
            }
            .sheet(isPresented: $showingCamera, onDismiss: {
                if capturedImage == nil { photoType = nil }
            }) {
                CameraView(image: $capturedImage, isPresented: $showingCamera)
                    .ignoresSafeArea()
            }
            .photosPicker(isPresented: $showingPhotoPicker,
                          selection: $selectedPhotoItem,
                          matching: .images)
            .onChange(of: selectedPhotoItem) { _, newItem in
                guard let newItem else { return }
                Task {
                    if let data = try? await newItem.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        capturedImage = image
                    }
                    selectedPhotoItem = nil
                }
            }
            .sheet(isPresented: $showingPlacePicker) {
                PlacePickerView(selectedPlace: $selectedPlace)
                    .environment(notion)
                    .environment(locationManager)
            }
        }
    }

    private func save() async {
        guard let image = capturedImage, let type = photoType else { return }

        if NASService.shared.password.isEmpty {
            errorMessage = "NAS password not set — swipe right from the left edge to open Settings."
            isSaving = false
            return
        }

        isSaving = true
        errorMessage = nil

        // 1. Save to Camera Roll
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)

        // Generate shared filename so NAS and B2 use the same name
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let filename = "\(type.rawValue)-\(formatter.string(from: Date())).jpg"

        // 2. Upload to B2 (preferred — public HTTPS URL)
        var photoURL: String? = nil
        if !B2Service.shared.keyID.isEmpty {
            do {
                photoURL = try await B2Service.shared.upload(image, filename: filename)
            } catch {
                errorMessage = "B2 upload failed: \(error.localizedDescription)."
            }
        }

        // 3. Upload to NAS (backup — always attempt if password set)
        if !NASService.shared.password.isEmpty {
            do {
                let nasURL = try await NASService.shared.upload(image, filename: filename)
                if photoURL == nil { photoURL = nasURL }
            } catch {
                let nasMsg = "NAS backup failed: \(error.localizedDescription)."
                errorMessage = errorMessage == nil ? nasMsg : "\(errorMessage!) \(nasMsg)"
            }
        }

        // 4. Create Notion capture
        // Pass only user-typed notes — auto-generated place name text never clutters visit Notes
        let coord = locationManager.location?.coordinate

        do {
            try await notion.saveCapture(
                notes: notes,
                placeID: type == .place ? selectedPlace?.id : nil,
                placeName: type == .place ? selectedPlace?.name : nil,
                lat: coord?.latitude,
                lon: coord?.longitude,
                photoURL: photoURL
            )
            await notion.fetchCaptures()
            if errorMessage == nil { dismiss() } else { isSaving = false }
        } catch {
            errorMessage = error.localizedDescription
            isSaving = false
        }
    }
}

struct CameraView: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    @Binding var isPresented: Bool

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraView
        init(_ parent: CameraView) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.image = image }
            parent.isPresented = false
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.isPresented = false
        }
    }
}
