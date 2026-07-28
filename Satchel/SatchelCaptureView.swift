import SwiftUI
import PhotosUI
import VisionKit
import UniformTypeIdentifiers
import PDFKit

// MARK: - SatchelCaptureView
//
// Build step 9. Frame 7 of `satchel-mockup-v4.html`.
//
// Four sources, one save form. Scope §5 "Photos" is explicit that the scanner
// and the camera are DIFFERENT TOOLS, not one tool with a mode:
//
//   Scanner — VNDocumentCameraViewController. Finds page edges, deskews,
//             corrects perspective, multi-page, outputs PDF. For paper.
//   Camera  — a raw uncorrected photo. For everything that is not paper: a
//             whiteboard, a serial number, rental car damage, a wine label.
//             The scanner mangles these by cropping them to a rectangle.
//
// ONE FILE PER DOCUMENT, locked. A single photo stays the original image at
// full quality. Several images captured together are combined into one PDF, so
// the viewer and page handling work unchanged and the model keeps its
// one-file-per-document shape.
//
// NOTE on Trace's existing scanner: `DocumentScannerView` in `AddPhotoView.swift`
// takes `scan.imageOfPage(at: 0)` and discards the rest. That is fine for its
// purpose and wrong for this one, so the scanner here is its own thing and
// keeps every page.
//
// ORDER OF OPERATIONS. The file is written to disk BEFORE the form appears,
// because `iOSDocumentScanService.scan` resolves a URL from a document's
// relativePath — it reads a file, not a blob. That means cancelling the form
// has to clean up after itself, or every abandoned capture leaves an orphan in
// Inbox. `discardDraft()` handles it.

struct SatchelCaptureView: View {

    let source: SatchelCaptureSource
    let store: iOSDocumentStore
    var onSaved: (() -> Void)? = nil
    /// Set only by a `satchel://…?note=` hand-off from another app in the family
    /// — today that means Trace's Place or Person note offering "Add document".
    /// Seeds `linkedNote` so the user never has to re-find the note they were
    /// looking at a second ago. Declared LAST on purpose: adding a property in
    /// the middle of a view reorders its memberwise initialiser and breaks every
    /// call site, which has already cost this project two build cycles.
    var prefilledNote: String? = nil

    @Environment(\.dismiss) private var dismiss

    @State private var noteStore = NoteStore.shared
    @State private var endeavorStore = SatchelEndeavorStore()

    // Source presentation
    @State private var showScanner = false
    @State private var showCamera = false
    @State private var showFiles = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showPhotos = false
    @State private var hasLaunchedSource = false

    // Draft
    @State private var draft: TraceMacDocument?
    @State private var previews: [UIImage] = []
    @State private var isWriting = false
    @State private var isScanning = false
    /// Which fields the AI actually supplied. The "AI" badge claims authorship,
    /// so it must not appear on a field that fell back to a local rule — that
    /// is how a photo ended up looking like the model had picked its icon when
    /// it had returned nothing.
    @State private var aiFilled: Set<String> = []
    @State private var isSaving = false
    @State private var errorText: String?

    // Form
    @State private var title = ""
    @State private var descriptionText = ""
    @State private var tags: [String] = []
    @State private var newTag = ""
    @State private var icon: DocumentIcon = .document
    @State private var tint: DocumentTint = .gray
    @State private var showIconPicker = false
    @State private var endeavorID: String?
    @State private var endeavorName: String?
    @State private var linkedNote: String?
    @State private var showNotePicker = false
    @State private var pinned = false

    var body: some View {
        NavigationStack {
            Group {
                if draft == nil {
                    waiting
                } else {
                    form
                }
            }
            .satchelBackground()
            .navigationTitle(draft == nil ? source.title : "New Document")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { cancel() }
                }
                if draft != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Save") { save() }
                            .fontWeight(.semibold)
                            .disabled(isSaving || isWriting)
                    }
                }
            }
            .task {
                // Before anything async, so the Note row is already filled in
                // the first time the form is drawn rather than popping in.
                // Guarded on nil so a re-entrant `.task` can never overwrite a
                // note the user picked by hand.
                if linkedNote == nil { linkedNote = prefilledNote }

                await endeavorStore.reload()
                guard !hasLaunchedSource else { return }
                hasLaunchedSource = true
                // The document picker and the camera are UIKit controllers, and
                // presenting one while this sheet is still animating in gets
                // swallowed silently — the picker simply never appears. Let the
                // presentation settle first.
                try? await Task.sleep(for: .milliseconds(350))
                launchSource()
            }
            .sheet(isPresented: $showScanner) {
                SatchelScannerView { pages in
                    showScanner = false
                    if pages.isEmpty { dismiss() } else { ingest(images: pages, fromScanner: true) }
                } onCancel: {
                    showScanner = false
                    dismiss()
                }
                .ignoresSafeArea()
            }
            .sheet(isPresented: $showCamera) {
                SatchelCameraView { image in
                    showCamera = false
                    if let image { ingest(images: [image], fromScanner: false) } else { dismiss() }
                }
                .ignoresSafeArea()
            }
            .photosPicker(
                isPresented: $showPhotos,
                selection: $photoItems,
                maxSelectionCount: 12,
                matching: .images
            )
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                Task { await ingestPhotoItems(items) }
            }
            .fileImporter(
                isPresented: $showFiles,
                allowedContentTypes: [.pdf, .image, .plainText, .data],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first { ingest(fileAt: url) } else { dismiss() }
                case .failure(let error):
                    // Was `dismiss()`, which threw away the only evidence of what
                    // went wrong. A failing import now says so.
                    errorText = "Could not open that file.\n\n\(error.localizedDescription)"
                }
            }
            .sheet(isPresented: $showIconPicker) {
                SatchelIconPickerView(icon: $icon, tint: $tint)
            }
            .sheet(isPresented: $showNotePicker) {
                SatchelNotePickerView(linkedNote: $linkedNote)
            }
        }
        .interactiveDismissDisabled(draft != nil)
    }

    // MARK: Waiting

    private var waiting: some View {
        VStack(spacing: 12) {
            if let errorText {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(Color.satchelSecondary)
                Text(errorText)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.satchelSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 34)
                Button("Close") { dismiss() }
                    .font(.system(size: 14, weight: .semibold))
            } else {
                ProgressView()
                Text(isWriting ? "Saving…" : source.title)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.satchelSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Form

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                pageStrip
                aiRow
                iconField
                labelled("Title", aiKey: "title") {
                    TextField("Title", text: $title)
                        .font(.system(size: 14))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .satchelCard()
                }
                labelled("Description", aiKey: "description") {
                    TextEditor(text: $descriptionText)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .frame(height: 78)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .satchelCard()
                }
                tagField
                fileToField
            }
            .padding(.bottom, 30)
        }
    }

    // MARK: Page strip

    private var pageStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(previews.indices, id: \.self) { index in
                    Image(uiImage: previews[index])
                        .resizable()
                        .scaledToFill()
                        .frame(width: 62, height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(alignment: .bottomTrailing) {
                            if previews.count > 1 {
                                Text("\(index + 1)")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.black.opacity(0.55), in: Capsule())
                                    .padding(4)
                            }
                        }
                }
                if previews.isEmpty, let draft {
                    SatchelDocumentMark(draft, size: 62, cornerRadius: 8, glyphSize: 26)
                        .frame(height: 80)
                }
            }
            .padding(.horizontal, 15)
        }
        .padding(.top, 12)
        .padding(.bottom, 14)
    }

    // MARK: Ask AI

    /// Explicit re-run. The scan fires once automatically on capture, but it can
    /// come back thin, or fail silently on a bad connection, and there was no
    /// way to ask again short of discarding the capture and starting over.
    /// Re-running OVERWRITES, unlike the automatic pass — asking for it is a
    /// clear instruction to replace what is there.
    @ViewBuilder
    private var aiRow: some View {
        if draft != nil {
            Button {
                guard let draft else { return }
                Task { await runScan(on: draft, overwrite: true) }
            } label: {
                HStack(spacing: 7) {
                    if isScanning {
                        ProgressView().controlSize(.small)
                        Text("Reading the document…")
                    } else {
                        Image(systemName: "sparkles")
                            .font(.system(size: 12, weight: .semibold))
                        Text(aiFilled.isEmpty ? "Ask AI to fill this in" : "Ask AI again")
                    }
                    Spacer(minLength: 0)
                }
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(isScanning ? Color.satchelSecondary : Color.satchelAI)
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .satchelCard()
            }
            .buttonStyle(.plain)
            .disabled(isScanning)
            .padding(.horizontal, 15)
            .padding(.bottom, 14)
        }
    }

    // MARK: Icon

    private var iconField: some View {
        labelled("Icon", aiKey: "icon") {
            HStack(spacing: 11) {
                SatchelDocumentMark(icon: icon, tint: tint, size: 38, cornerRadius: 11, glyphSize: 19)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(icon.rawValue) · \(tint.rawValue)")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color.satchelInk)
                    Text("Tap to change")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.satchelSecondary)
                }
                Spacer(minLength: 6)
                // Scope §5: three likely alternates inline, full set behind the tap.
                // The model picks well most of the time and badly some of the
                // time, and a wrong icon should cost one tap, not a trip into a
                // grid of twenty.
                ForEach(alternates, id: \.self) { alt in
                    Button {
                        icon = alt
                        tint = alt.defaultTint
                    } label: {
                        SatchelDocumentMark(icon: alt, tint: alt.defaultTint,
                                            size: 28, cornerRadius: 8, glyphSize: 14)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .satchelCard()
            .contentShape(Rectangle())
            .onTapGesture { showIconPicker = true }
        }
    }

    /// Three plausible alternates, never repeating the current pick.
    private var alternates: [DocumentIcon] {
        var pool: [DocumentIcon] = []
        if let draft {
            pool.append(TraceMacDocument.fallbackIcon(
                category: draft.category, tags: tags, fileExtension: draft.fileExtension))
        }
        pool += [.document, .receipt, .contract, .photo, .card]
        var seen = Set<DocumentIcon>([icon])
        var out: [DocumentIcon] = []
        for candidate in pool where !seen.contains(candidate) {
            seen.insert(candidate)
            out.append(candidate)
            if out.count == 3 { break }
        }
        return out
    }

    // MARK: Tags

    private var tagField: some View {
        labelled("Tags", aiKey: "tags") {
            VStack(alignment: .leading, spacing: 8) {
                if !tags.isEmpty {
                    SatchelFlowLayout {
                        ForEach(tags, id: \.self) { tag in
                            Button {
                                tags.removeAll { $0 == tag }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(tag)
                                    Image(systemName: "xmark")
                                        .font(.system(size: 8, weight: .bold))
                                }
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color(red: 0.420, green: 0.420, blue: 0.439))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 3)
                                .background(Color.satchelFill, in: RoundedRectangle(cornerRadius: 7))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                HStack(spacing: 8) {
                    TextField("Add a tag", text: $newTag)
                        .font(.system(size: 12.5))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit { addTag() }
                    if !newTag.trimmingCharacters(in: .whitespaces).isEmpty {
                        Button("Add") { addTag() }
                            .font(.system(size: 12, weight: .semibold))
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .satchelCard()
        }
    }

    private func addTag() {
        let value = newTag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty, !tags.contains(value) else { newTag = ""; return }
        tags.append(value)
        newTag = ""
    }

    // MARK: File to

    private var fileToField: some View {
        labelled("File to") {
            VStack(spacing: 0) {
                Menu {
                    Button("None") { endeavorID = nil; endeavorName = nil }
                    ForEach(endeavorStore.endeavors) { endeavor in
                        Button(endeavor.name) {
                            endeavorID = endeavor.id
                            endeavorName = endeavor.name
                        }
                    }
                } label: {
                    pickerRow("Endeavor", value: endeavorName ?? "None",
                              highlight: endeavorName != nil)
                }
                Divider().overlay(Color.satchelHairline).padding(.leading, 14)

                Button {
                    showNotePicker = true
                } label: {
                    pickerRow("Note", value: noteDisplayName(linkedNote) ?? "None",
                              highlight: linkedNote != nil)
                }
                .buttonStyle(.plain)
                Divider().overlay(Color.satchelHairline).padding(.leading, 14)

                Toggle(isOn: $pinned) {
                    Text("Pin to Kit")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.satchelInk)
                }
                .tint(Color.satchelPin)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            .satchelCard()

            Text(endeavorStore.endeavors.isEmpty
                 ? "The Endeavor picker is present but empty until the Notion database exists. Group trips by tag in the meantime."
                 : "Filed documents fold into Kit automatically while the trip is running.")
                .font(.system(size: 10.5))
                .foregroundStyle(Color.satchelSecondary)
                .padding(.horizontal, 6)
                .padding(.top, 7)
        }
    }

    private func pickerRow(_ label: String, value: String, highlight: Bool) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 14))
                .foregroundStyle(Color.satchelInk)
            Spacer(minLength: 10)
            Text(value)
                .font(.system(size: 13))
                .foregroundStyle(highlight ? Color.satchelAuto : Color.satchelSecondary)
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.satchelTertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    // MARK: Field wrapper

    @ViewBuilder
    private func labelled<Content: View>(
        _ label: String, aiKey: String? = nil, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(label.uppercased())
                    .font(.system(size: 11.5, weight: .bold))
                    .kerning(0.5)
                    .foregroundStyle(Color.satchelSecondary)
                if let aiKey {
                    if isScanning {
                        ProgressView().controlSize(.mini)
                    } else if aiFilled.contains(aiKey) {
                        SatchelAIBadge()
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            content()
        }
        .padding(.horizontal, 15)
        .padding(.bottom, 14)
    }

    // MARK: Source launch

    private func launchSource() {
        switch source {
        case .scan:
            guard VNDocumentCameraViewController.isSupported else {
                errorText = "This device has no document scanner."
                return
            }
            showScanner = true
        case .photo:
            guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
                errorText = "This device has no camera. Try Choose from Library."
                return
            }
            showCamera = true
        case .library:
            showPhotos = true
        case .file:
            showFiles = true
        }
    }

    // MARK: Ingest

    private func ingestPhotoItems(_ items: [PhotosPickerItem]) async {
        var images: [UIImage] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                images.append(image)
            }
        }
        if images.isEmpty {
            dismiss()
        } else {
            ingest(images: images, fromScanner: false)
        }
    }

    /// Scope §5, locked: one file per document. A single image stays the
    /// original at full quality; several become one PDF.
    private func ingest(images: [UIImage], fromScanner: Bool) {
        guard !images.isEmpty else { dismiss(); return }
        isWriting = true
        previews = images

        let data: Data
        let ext: String
        if images.count == 1 && !fromScanner {
            data = images[0].jpegData(compressionQuality: 0.9) ?? Data()
            ext = "jpg"
        } else {
            // A scan is always a PDF even at one page: it has been deskewed and
            // perspective-corrected, so it is a page, not a photo.
            data = Self.pdf(from: images)
            ext = "pdf"
        }
        finishWrite(data: data, ext: ext, baseName: fromScanner ? "scan" : "photo")
    }

    private func ingest(fileAt url: URL) {
        isWriting = true
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        guard let data = readImportedFile(at: url) else {
            errorText = """
            Could not read that file.

            If it lives in iCloud Drive it may not have downloaded yet. Open it \
            once in the Files app so it downloads, then try again.
            """
            isWriting = false
            return
        }
        let ext = url.pathExtension.isEmpty ? "pdf" : url.pathExtension.lowercased()
        let base = (url.lastPathComponent as NSString).deletingPathExtension
        if let image = UIImage(data: data) { previews = [image] }
        finishWrite(data: data, ext: ext, baseName: base)
    }

    /// A file picked out of iCloud Drive can be a placeholder with no bytes on
    /// device yet, and a plain `Data(contentsOf:)` on one just fails. Ask for the
    /// download, then read under a file coordinator so the read waits for it.
    private func readImportedFile(at url: URL) -> Data? {
        if let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey]),
           values.isUbiquitousItem == true {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        }

        var coordinated: Data?
        var coordinatorError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinatorError) { readURL in
            coordinated = try? Data(contentsOf: readURL)
        }
        return coordinated ?? (try? Data(contentsOf: url))
    }

    private func finishWrite(data: Data, ext: String, baseName: String) {
        guard !data.isEmpty else {
            errorText = "Nothing to save."
            isWriting = false
            return
        }

        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd-HHmmss"
        let slug = baseName
            .components(separatedBy: .whitespacesAndNewlines).joined(separator: "-")
            .replacingOccurrences(of: "/", with: "-")
        let filename = "\(fmt.string(from: Date()))-\(slug).\(ext)"

        do {
            let relativePath = try noteStore.writeDocument(data, category: "Inbox", filename: filename)
            let document = TraceMacDocument(
                relativePath: relativePath,
                filename: filename,
                category: "Inbox",
                fileExtension: ext,
                title: slug.replacingOccurrences(of: "-", with: " "),
                tags: [],
                created: Date(),
                linkedNote: nil,
                people: [],
                description: ""
            )
            draft = document
            title = document.title
            icon = document.resolvedIcon
            tint = document.resolvedTint
            isWriting = false
            Task { await runScan(on: document) }
        } catch {
            errorText = error.localizedDescription
            isWriting = false
        }
    }

    // MARK: AI pre-fill

    private func runScan(on document: TraceMacDocument, overwrite: Bool = false) async {
        isScanning = true
        defer { isScanning = false }

        let existing = Array(Set(store.documents.flatMap { $0.tags })).sorted()
        guard let result = try? await iOSDocumentScanService.scan(
            doc: document,
            noteStore: noteStore,
            existingTags: existing,
            // Every Satchel capture invents its own filename, so the model must
            // never be asked to judge whether "scan" is descriptive. It is not.
            filenameIsGenerated: true
        ) else { return }

        // The automatic pass never clobbers something already typed — it can take
        // several seconds and the form is live throughout. An explicit re-run does.
        if let suggested = result.title,
           overwrite || title.trimmingCharacters(in: .whitespacesAndNewlines) == document.title {
            title = suggested
            aiFilled.insert("title")
        }
        if !result.description.isEmpty, overwrite || descriptionText.isEmpty {
            descriptionText = result.description
            aiFilled.insert("description")
        }
        if !result.tags.isEmpty, overwrite || tags.isEmpty {
            tags = result.tags
            aiFilled.insert("tags")
        }
        if let suggestedIcon = result.icon {
            icon = suggestedIcon
            tint = result.tint ?? suggestedIcon.defaultTint
            aiFilled.insert("icon")
        } else if let suggestedTint = result.tint {
            tint = suggestedTint
        }
    }

    // MARK: Save / cancel

    private func save() {
        guard let draft else { return }
        isSaving = true

        let finalTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? draft.title
            : title.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            try store.saveSidecar(
                for: draft,
                title: finalTitle,
                tags: tags,
                linkedNote: linkedNote,
                people: [],
                description: descriptionText.trimmingCharacters(in: .whitespacesAndNewlines),
                date: draft.created,
                endeavor: endeavorID ?? "",
                endeavorName: endeavorName ?? "",
                pinned: pinned,
                icon: icon,
                tint: tint,
                kitOrder: pinned ? nextKitOrder() : nil
            )
        } catch {
            errorText = error.localizedDescription
            isSaving = false
            return
        }

        Task {
            await store.reload()
            onSaved?()
            dismiss()
        }
    }

    private func nextKitOrder() -> Int {
        (store.documents.filter { $0.pinned }.compactMap { $0.kitOrder }.max() ?? -1) + 1
    }

    /// The file is already on disk by the time the form appears, so cancelling
    /// has to remove it. Without this, every abandoned capture leaves an orphan
    /// in Inbox that the library then lists.
    private func cancel() {
        discardDraft()
        dismiss()
    }

    private func discardDraft() {
        guard let draft else { return }
        _ = try? store.deleteDocument(draft)
        self.draft = nil
    }

    // MARK: PDF assembly

    /// Combines pages into one PDF, capping the long edge so a six-page scan of
    /// 12-megapixel images does not produce a 30 MB document that then has to
    /// sync through iCloud.
    @MainActor
    private static func pdf(from images: [UIImage], maxDimension: CGFloat = 1700) -> Data {
        let scaled = images.map { image -> UIImage in
            var working = image
            let longest = max(image.size.width, image.size.height)
            if longest > maxDimension {
                let factor = maxDimension / longest
                let size = CGSize(width: image.size.width * factor, height: image.size.height * factor)
                working = UIGraphicsImageRenderer(size: size).image { _ in
                    image.draw(in: CGRect(origin: .zero, size: size))
                }
            }
            // Re-encode as JPEG before drawing. Drawing a raw bitmap into a PDF
            // context embeds it losslessly: David's first real scan came out at
            // 30 MB, which then has to sync through iCloud on a document meant
            // to be carried. A JPEG-backed image embeds as JPEG.
            if let data = working.jpegData(compressionQuality: 0.72),
               let recoded = UIImage(data: data) {
                working = recoded
            }
            return working
        }

        let first = scaled.first?.size ?? CGSize(width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: first))
        return renderer.pdfData { context in
            for image in scaled {
                let bounds = CGRect(origin: .zero, size: image.size)
                context.beginPage(withBounds: bounds, pageInfo: [:])
                image.draw(in: bounds)
            }
        }
    }
}

// MARK: - Scanner
//
// Keeps EVERY page, unlike Trace's `DocumentScannerView` which takes page 0 and
// drops the rest. Scope §5 requires multi-page scan-to-PDF.

struct SatchelScannerView: UIViewControllerRepresentable {
    let onFinish: ([UIImage]) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let parent: SatchelScannerView
        init(_ parent: SatchelScannerView) { self.parent = parent }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFinishWith scan: VNDocumentCameraScan
        ) {
            var pages: [UIImage] = []
            for index in 0..<scan.pageCount {
                pages.append(scan.imageOfPage(at: index))
            }
            parent.onFinish(pages)
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            parent.onCancel()
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFailWithError error: Error
        ) {
            parent.onCancel()
        }
    }
}

// MARK: - Camera

struct SatchelCameraView: UIViewControllerRepresentable {
    let onCapture: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: SatchelCameraView
        init(_ parent: SatchelCameraView) { self.parent = parent }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            parent.onCapture(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onCapture(nil)
        }
    }
}

// MARK: - Icon picker
//
// The full set behind the tap. Icon and tint are chosen separately, because the
// model's default pairing is usually right but the two are independent choices
// and forcing them together would mean twenty icons times eight tints of rows.

struct SatchelIconPickerView: View {
    @Binding var icon: DocumentIcon
    @Binding var tint: DocumentTint
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 64), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SatchelSectionTitle("Icon")
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(DocumentIcon.allCases, id: \.self) { candidate in
                            Button {
                                icon = candidate
                            } label: {
                                VStack(spacing: 5) {
                                    SatchelDocumentMark(icon: candidate, tint: tint,
                                                        size: 44, cornerRadius: 12, glyphSize: 21)
                                    Text(candidate.label)
                                        .font(.system(size: 9.5))
                                        .foregroundStyle(Color.satchelSecondary)
                                        .lineLimit(1)
                                }
                                .padding(4)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(candidate == icon ? Color.satchelBlue : .clear, lineWidth: 2)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.bottom, 22)

                    SatchelSectionTitle("Tint")
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(DocumentTint.allCases, id: \.self) { candidate in
                            Button {
                                tint = candidate
                            } label: {
                                VStack(spacing: 5) {
                                    SatchelDocumentMark(icon: icon, tint: candidate,
                                                        size: 44, cornerRadius: 12, glyphSize: 21)
                                    Text(candidate.label)
                                        .font(.system(size: 9.5))
                                        .foregroundStyle(Color.satchelSecondary)
                                }
                                .padding(4)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(candidate == tint ? Color.satchelBlue : .clear, lineWidth: 2)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 15)
                .padding(.top, 10)
                .padding(.bottom, 30)
            }
            .satchelBackground()
            .navigationTitle("Icon")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
    }
}

// MARK: - Flow layout

/// Wrapping row of chips. A real `Layout` rather than the classic
/// `alignmentGuide` trick, which works by mutating captured state during view
/// evaluation and misbehaves the moment the content resizes.
/// `LazyVGrid(.adaptive)` is the other obvious option and is wrong here: it
/// gives every cell equal width, which looks broken for tags of very
/// different lengths.
struct SatchelFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
