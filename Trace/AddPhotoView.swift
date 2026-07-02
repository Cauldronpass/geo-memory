import SwiftUI
import UIKit
import CoreLocation
import PhotosUI
import VisionKit

// MARK: - PhotoType
// Moved here from NASService.swift (B2/NAS retired 2026-06-26)

enum PhotoType: String, CaseIterable {
    case place = "place"
    case receipt = "receipt"
    case document = "document"

    var label: String {
        switch self {
        case .place: return "Place Photo"
        case .receipt: return "Receipt"
        case .document: return "Document"
        }
    }

    var emoji: String {
        switch self {
        case .place: return "📷"
        case .receipt: return "🧾"
        case .document: return "📄"
        }
    }
}

// MARK: - AddPhotoView

struct AddPhotoView: View {
    @Environment(NotionService.self) private var notion
    @Environment(LocationManager.self) private var locationManager
    @Environment(\.dismiss) private var dismiss

    @State private var photoType: PhotoType? = nil
    @State private var capturedImage: UIImage? = nil
    @State private var showingCamera = false
    @State private var showingDocumentScanner = false
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
                                    switch type {
                                    case .place:
                                        // Regular camera for place photos
                                        if cameraAvailable { showingCamera = true }
                                        else { showingPhotoPicker = true }
                                    case .receipt, .document:
                                        // Document scanner for flat captures — auto edge-detect + perspective correction
                                        if VNDocumentCameraViewController.isSupported { showingDocumentScanner = true }
                                        else { showingPhotoPicker = true }
                                    }
                                } label: {
                                    HStack {
                                        Text(type.emoji).font(.title2)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(type.label).foregroundStyle(.primary)
                                            Text("Saves to iCloud")
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
                            // Retake / Re-scan depending on type
                            if photoType == .place {
                                if cameraAvailable {
                                    Button("Retake") { showingCamera = true }
                                }
                            } else {
                                if VNDocumentCameraViewController.isSupported {
                                    Button("Re-scan") { showingDocumentScanner = true }
                                }
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
                                Image(systemName: "icloud")
                                    .foregroundStyle(.blue)
                                Text("Saves to iCloud")
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
            .sheet(isPresented: $showingDocumentScanner, onDismiss: {
                if capturedImage == nil { photoType = nil }
            }) {
                DocumentScannerView(image: $capturedImage, isPresented: $showingDocumentScanner)
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

    // MARK: - Save
    // Writes photo to NoteStore iCloud container (Photos/Visits/) and creates
    // an Inbox note at Notes/Inbox/ with the photo reference and any user notes.
    // B2 and NAS upload paths retired 2026-06-26.

    private func save() async {
        guard let image = capturedImage, let type = photoType else { return }
        guard let data = image.jpegData(compressionQuality: 0.85) else {
            errorMessage = "Failed to encode image."
            return
        }

        isSaving = true
        errorMessage = nil

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let timestamp = formatter.string(from: Date())
        let filename = "\(type.rawValue)-\(timestamp).jpg"

        do {
            // Write photo to NoteStore
            let photoPath = try NoteStore.shared.writePhoto(data, category: "Visits", filename: filename)

            // Write Inbox note with photo reference and any user notes
            var inboxLines = ["# Photo — \(type.label)", "", "![\(type.label)](\(photoPath))"]
            if let place = selectedPlace {
                inboxLines += ["", "**Place:** \(place.name)"]
            }
            let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedNotes.isEmpty {
                inboxLines += ["", trimmedNotes]
            }
            try NoteStore.shared.writeFile("Notes/Inbox/\(timestamp).md",
                                           content: inboxLines.joined(separator: "\n"))
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            isSaving = false
        }
    }
}

// MARK: - DocumentScannerView
// Uses VNDocumentCameraViewController for auto-edge-detect + perspective correction.
// Used for Receipt and Document types. Returns the first scanned page as a UIImage.

struct DocumentScannerView: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    @Binding var isPresented: Bool

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let vc = VNDocumentCameraViewController()
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let parent: DocumentScannerView
        init(_ parent: DocumentScannerView) { self.parent = parent }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFinishWith scan: VNDocumentCameraScan) {
            parent.image = scan.imageOfPage(at: 0)
            parent.isPresented = false
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            parent.isPresented = false
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFailWithError error: Error) {
            parent.isPresented = false
        }
    }
}

// MARK: - CameraView

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
