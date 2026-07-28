import SwiftUI
import PDFKit

// MARK: - SatchelViewerView
//
// Build step 8. Frames 5 (PDF) and 6 (photo) of `satchel-mockup-v4.html`.
//
// Scope §5: "Viewer — full screen, direct tap from any row." That is the whole
// point of this screen. §6 calls the existing `iOSPDFView` and
// `AsyncImagePreview` in `iOSDocumentsView.swift` "already solid" and says the
// viewer "becomes the front door instead of sitting behind the in-note markdown
// link path" — the cumbersome flow David remembered.
//
// A note on "promote out of `iOSDocumentsView.swift`": that file is 38 KB of
// Trace's own UI and is NOT in the Satchel target, so nothing could be shared
// without either adding it wholesale or hand-editing `project.pbxproj`'s
// membership exception set. Neither is worth it, because the reusable part is a
// twelve-line `UIViewRepresentable` around `PDFView` — boilerplate, not logic.
// What is actually reused is the *approach*: PDFKit for PDFs, and the
// iCloud-aware "still downloading" handling for images, which matters because a
// document may exist as a placeholder before its bytes arrive. Both are
// reimplemented here to the mockup's design rather than copied.

struct SatchelViewerView: View {

    let document: TraceMacDocument
    let store: iOSDocumentStore

    @State private var noteStore = NoteStore.shared
    @State private var endeavorStore = SatchelEndeavorStore()
    @State private var pageCount: Int = 0
    @State private var isWorking = false

    /// The active trip this document belongs to, if it is in Kit *because of*
    /// that trip rather than because it was pinned. Kit has two kinds of member
    /// (scope §5) and a button that reads only `pinned` describes half of them
    /// wrongly: a boarding pass sitting in Kit all week still said "Add to Kit".
    private var kitTrip: Endeavor? {
        guard !current.pinned, let id = current.endeavor else { return nil }
        guard let trip = endeavorStore.activeTrip(), trip.id == id else { return nil }
        return trip
    }

    private var fileURL: URL? {
        noteStore.resolvedURL(for: document.relativePath)
    }

    /// The live copy from the store, so a pin toggle updates this screen's
    /// button without a reload. Falls back to the value it was pushed with.
    private var current: TraceMacDocument {
        store.documents.first { $0.relativePath == document.relativePath } ?? document
    }

    var body: some View {
        VStack(spacing: 0) {
            stage
            metaStrip
            actions
            Spacer(minLength: 0)
        }
        .satchelBackground()
        .navigationTitle(navTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let fileURL {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: fileURL) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
        .task {
            await endeavorStore.reload()
            guard document.isPDF, let fileURL else { return }
            pageCount = PDFDocument(url: fileURL)?.pageCount ?? 0
        }
    }

    private var navTitle: String {
        if document.isPDF && pageCount > 0 {
            return pageCount == 1 ? "1 page" : "\(pageCount) pages"
        }
        return document.isImage ? "Photo" : "Document"
    }

    // MARK: Stage

    /// The dark stage from frames 5 and 6. Deliberately near-black rather than
    /// the app canvas: a document is the subject here, and a light ground makes
    /// a white page float without an edge.
    @ViewBuilder
    private var stage: some View {
        ZStack {
            Color(red: 0.173, green: 0.173, blue: 0.180) // #2c2c2e

            if let fileURL {
                if document.isPDF {
                    // Inset so the dark ground shows on all four sides. Without
                    // this, `autoScales` fits the page to the full width, the
                    // stage is completely covered and the page loses its edge —
                    // it reads as a plain white screen rather than a document
                    // sitting on a surface. The mockup's paper is deliberately
                    // narrower than its stage for exactly this reason.
                    SatchelPDFView(url: fileURL)
                        .padding(.horizontal, 34)
                        .padding(.vertical, 18)
                } else if document.isImage {
                    SatchelImagePreview(url: fileURL)
                } else {
                    unsupported
                }
            } else {
                unsupported
            }
        }
        .frame(height: 460)
    }

    private var unsupported: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.questionmark")
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(.white.opacity(0.5))
            Text("Cannot preview this file")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
            Text(document.filename)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    // MARK: Meta

    private var metaStrip: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                SatchelDocumentMark.header(current)
                VStack(alignment: .leading, spacing: 2) {
                    Text(current.title)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color.satchelInk)
                        .lineLimit(2)
                    Text(subtitle)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.satchelSecondary)
                }
                Spacer(minLength: 0)
            }

            if !current.tags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(current.tags, id: \.self) { tag in
                        SatchelTagPill(text: tag)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 11)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
    }

    private var subtitle: String {
        var parts: [String] = []
        if current.isPDF {
            parts.append(pageCount > 1 ? "PDF · \(pageCount) pages" : "PDF")
        } else {
            parts.append(kindLabel(for: current))
        }
        let when = relativeDateLabel(current.created)
        if !when.isEmpty { parts.append(when) }
        if let name = current.endeavorName, !name.isEmpty { parts.append(name) }
        return parts.joined(separator: " · ")
    }

    // MARK: Actions

    private var actions: some View {
        VStack(spacing: 7) {
            HStack(spacing: 10) {
                if let fileURL {
                    ShareLink(item: fileURL) {
                        actionLabel("Share")
                    }
                    .buttonStyle(.plain)
                }

                NavigationLink {
                    SatchelDocumentDetailView(document: current, store: store)
                } label: {
                    actionLabel("Edit info")
                }
                .buttonStyle(.plain)

                Button {
                    togglePin()
                } label: {
                    actionLabel(kitButtonTitle, symbol: kitButtonSymbol, tint: kitButtonTint)
                }
                .buttonStyle(.plain)
                .disabled(isWorking)
            }

            if let kitTrip {
                Text(tripCaption(for: kitTrip))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.satchelSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
    }

    // Three states, because Kit has two kinds of member and "not in Kit" is a
    // third thing entirely.
    //   pinned          → the way out
    //   in Kit via trip → the way to make it permanent, not "Add"
    //   neither         → add
    private var kitButtonTitle: String {
        if current.pinned { return "Remove from Kit" }
        return kitTrip != nil ? "Keep in Kit" : "Add to Kit"
    }

    private var kitButtonSymbol: String? {
        if current.pinned { return "pin.slash" }
        return kitTrip != nil ? "pin" : nil
    }

    private var kitButtonTint: Color {
        current.pinned ? Color.satchelPin : Color.satchelBlue
    }

    private func tripCaption(for trip: Endeavor) -> String {
        var phrase = "In Kit while \(trip.name) is running"
        if let end = trip.end {
            let fmt = DateFormatter()
            fmt.dateFormat = "MMM d"
            phrase += ", through \(fmt.string(from: end))"
        }
        return phrase + ". Keep it to hold its place afterwards."
    }

    private func actionLabel(_ text: String, symbol: String? = nil, tint: Color = .satchelBlue) -> some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(tint)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .satchelTile(cornerRadius: 12)
    }

    private func togglePin() {
        isWorking = true
        defer { isWorking = false }
        _ = try? store.setPinned(!current.pinned, for: current)
    }
}

// MARK: - PDF

/// PDFKit wrapper. Same shape as Trace's `iOSPDFView`, restyled for the dark
/// stage. `autoScales` plus continuous vertical paging is what makes a
/// multi-page receipt behave like a document rather than a slideshow.
struct SatchelPDFView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = UIColor(red: 0.173, green: 0.173, blue: 0.180, alpha: 1)
        // Drop shadows give the page a physical edge against the dark ground,
        // and the gap makes a multi-page document read as separate sheets
        // rather than one long scroll.
        view.pageShadowsEnabled = true
        view.pageBreakMargins = UIEdgeInsets(top: 0, left: 0, bottom: 12, right: 0)
        view.document = PDFDocument(url: url)
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        // Only rebuild when the file actually changed — reassigning `document`
        // on every SwiftUI update resets scroll position mid-read.
        if uiView.document?.documentURL != url {
            uiView.document = PDFDocument(url: url)
        }
    }
}

// MARK: - Image

/// Image preview with the iCloud-placeholder handling Trace's
/// `AsyncImagePreview` already got right: a document can exist in the container
/// as a stub before its bytes arrive, so the download is kicked off explicitly
/// and the not-yet-available case says so instead of showing a broken frame.
struct SatchelImagePreview: View {
    let url: URL

    @State private var image: UIImage?
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .tint(.white)
            } else if let image {
                SatchelZoomableImage(image: image)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "icloud.and.arrow.down")
                        .font(.system(size: 38, weight: .thin))
                        .foregroundStyle(.white.opacity(0.5))
                    Text("Image not available")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                    Text("It may still be downloading from iCloud.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.45))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        // Nudge iCloud if this is still a placeholder rather than real bytes.
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)

        let target = url
        let loaded: UIImage? = await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: target) else { return nil }
            return UIImage(data: data)
        }.value

        image = loaded
        isLoading = false
    }
}

// MARK: - Zoomable image
//
// A 12-megapixel photo has no business being laid out at its intrinsic size,
// which is exactly what `ScrollView { Image.resizable().scaledToFit() }` does:
// inside a two-axis ScrollView there is no bounded width to fit into, so the
// image renders at full pixel size and you are left looking at a few hundred
// pixels of the middle of it with no way out.
//
// `UIScrollView` is the right tool and is why PDFs already behaved: it owns the
// zoom scale, so the image can start fitted, pinch between fitted and 4x, and
// double-tap to toggle. Rebuilding that on SwiftUI gestures would mean
// reimplementing rubber-banding, momentum and centring for no gain.

struct SatchelZoomableImage: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> ZoomableImageScrollView {
        ZoomableImageScrollView(image: image)
    }

    func updateUIView(_ uiView: ZoomableImageScrollView, context: Context) {
        uiView.setImage(image)
    }
}

final class ZoomableImageScrollView: UIScrollView, UIScrollViewDelegate {

    private let imageView = UIImageView()
    private var lastBounds: CGSize = .zero

    init(image: UIImage) {
        super.init(frame: .zero)
        delegate = self
        backgroundColor = .clear
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        bouncesZoom = true
        contentInsetAdjustmentBehavior = .never

        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)

        setImage(image)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setImage(_ image: UIImage) {
        guard imageView.image !== image else { return }
        imageView.image = image
        imageView.frame = CGRect(origin: .zero, size: image.size)
        contentSize = image.size
        lastBounds = .zero          // force a rescale on next layout
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != lastBounds {
            lastBounds = bounds.size
            configureScale()
        }
        centreContent()
    }

    /// Fit the whole image on screen to begin with. Zooming OUT past fit is
    /// pointless, so fitted is the minimum; 4x fit is a sane ceiling for reading
    /// a serial number off a photographed label.
    private func configureScale() {
        guard let size = imageView.image?.size, size.width > 0, size.height > 0,
              bounds.width > 0, bounds.height > 0 else { return }

        let fit = min(bounds.width / size.width, bounds.height / size.height)
        minimumZoomScale = fit
        maximumZoomScale = max(fit * 4, 1.5)
        zoomScale = fit
    }

    private func centreContent() {
        let x = max(0, (bounds.width - contentSize.width) / 2)
        let y = max(0, (bounds.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale * 1.05 {
            setZoomScale(minimumZoomScale, animated: true)
        } else {
            let point = gesture.location(in: imageView)
            let target = min(minimumZoomScale * 3, maximumZoomScale)
            let w = bounds.width / target
            let h = bounds.height / target
            zoom(to: CGRect(x: point.x - w / 2, y: point.y - h / 2, width: w, height: h), animated: true)
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { centreContent() }
}
