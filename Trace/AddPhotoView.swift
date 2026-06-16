import SwiftUI
import UIKit
import CoreLocation

struct AddPhotoView: View {
    @Environment(NotionService.self) private var notion
    @Environment(LocationManager.self) private var locationManager
    @Environment(\.dismiss) private var dismiss

    @State private var photoType: PhotoType? = nil
    @State private var capturedImage: UIImage? = nil
    @State private var showingCamera = false
    @State private var notes = ""
    @State private var selectedPlace: Place? = nil
    @State private var showingPlacePicker = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showingPasswordEntry = false
    @State private var nasPasswordInput = ""

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
                                    if cameraAvailable { showingCamera = true }
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
                    VStack(spacing: 20) {
                        Spacer()
                        Image(systemName: "camera.fill").font(.system(size: 60)).foregroundStyle(.secondary)
                        Text("Camera not available on this device").foregroundStyle(.secondary)
                        Spacer()
                    }
                } else {
                    Form {
                        Section {
                            Image(uiImage: capturedImage!)
                                .resizable().scaledToFit()
                                .frame(maxHeight: 260)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            Button("Retake") { showingCamera = true }
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
            .sheet(isPresented: $showingPlacePicker) {
                PlacePickerView(selectedPlace: $selectedPlace)
                    .environment(notion)
                    .environment(locationManager)
            }
            .alert("NAS Password", isPresented: $showingPasswordEntry) {
                SecureField("DSM Password", text: $nasPasswordInput)
                Button("Save & Upload") {
                    NASService.shared.password = nasPasswordInput
                    nasPasswordInput = ""
                    Task { await save() }
                }
                Button("Cancel", role: .cancel) { isSaving = false }
            } message: {
                Text("Enter your DiskStation password once to enable NAS uploads.")
            }
        }
    }

    private func save() async {
        guard let image = capturedImage, let type = photoType else { return }

        if NASService.shared.password.isEmpty {
            showingPasswordEntry = true
            return
        }

        isSaving = true
        errorMessage = nil

        // 1. Save to Camera Roll
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)

        // 2. Upload to NAS
        var nasURL: String? = nil
        do {
            nasURL = try await NASService.shared.upload(image, type: type)
        } catch {
            errorMessage = "NAS upload failed (is Tailscale on?). Saved to Camera Roll only."
        }

        // 3. Create Notion capture
        let coord = locationManager.location?.coordinate
        var noteText = "\(type.emoji) \(notes.isEmpty ? type.label : notes)"
        if let url = nasURL { noteText += "\nNAS: \(url)" }

        do {
            try await notion.saveCapture(
                notes: noteText,
                placeID: type == .place ? selectedPlace?.id : nil,
                placeName: type == .place ? selectedPlace?.name : nil,
                lat: coord?.latitude,
                lon: coord?.longitude
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

