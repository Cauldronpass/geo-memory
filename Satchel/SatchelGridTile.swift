import SwiftUI
import UIKit
import PDFKit
import ImageIO

// MARK: - SatchelDocumentGrid
//
// Session 102, D386. Show all drawn as thumbnails, two columns, the way
// Scrappy's grid reads: the picture first, the name under it, the filing line
// under that. One library, every kind in it; the Format filter is what narrows
// it to links, and this grid never knows or cares which filter it is under.
//
// Tap opens the same viewer a row opens, handed the whole ordered set so a
// swipe there moves through THIS grid's order (D386). The pin and task swipes
// stay on the rows: a tile is too small to carry two horizontal gestures
// honestly, and the list is one toggle away.

struct SatchelDocumentGrid: View {
    let documents: [TraceMacDocument]
    /// The full ordered set the viewer should swipe through, which is wider
    /// than `documents` when the screen is grouped by month.
    let ordered: [TraceMacDocument]
    let store: iOSDocumentStore

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    /// The long press's three destinations (D389), same as the row's.
    @State private var taskFor: TraceMacDocument? = nil
    @State private var editing: TraceMacDocument? = nil
    @State private var pendingDelete: TraceMacDocument? = nil

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
            ForEach(documents, id: \.relativePath) { doc in
                NavigationLink {
                    SatchelViewerView(document: doc, store: store, siblings: ordered)
                } label: {
                    SatchelGridTile(document: doc)
                }
                .buttonStyle(.plain)
                .satchelDocumentMenu(doc,
                                     onTask: { taskFor = doc },
                                     onEdit: { editing = doc },
                                     onPin: { togglePin(doc) },
                                     onDelete: { pendingDelete = doc },
                                     onRetry: {
                                         Task {
                                             await SatchelArticleSweep.retry(
                                                 doc, store: store, noteStore: NoteStore.shared)
                                         }
                                     })
            }
        }
        .sheet(item: $taskFor) { doc in
            SatchelTaskCard(document: doc)
        }
        .sheet(item: $editing) { doc in
            NavigationStack {
                SatchelDocumentDetailView(document: doc, store: store)
            }
        }
        .confirmationDialog(
            "Delete \(pendingDelete?.title ?? "this document")?",
            isPresented: Binding(get: { pendingDelete != nil },
                                 set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let doc = pendingDelete { _ = try? store.deleteDocument(doc); Task { await store.reload() } }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("The file and its sidecar are removed from the shared container. This cannot be undone from inside Satchel.")
        }
    }

    private func togglePin(_ doc: TraceMacDocument) {
        _ = try? store.setPinned(!doc.pinned, for: doc)
        Task { await store.reload() }
    }
}

// MARK: - SatchelGridTile

struct SatchelGridTile: View {
    let document: TraceMacDocument
    @State private var noteStore = NoteStore.shared
    @State private var thumbnail: UIImage? = nil
    @State private var textExcerpt: String? = nil

    private static let thumbHeight: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                picture
                    .frame(maxWidth: .infinity)
                    .frame(height: Self.thumbHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                kindGlyph
                    .padding(8)
                if SatchelPrivateTag.isPrivate(document) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.orange)
                        .padding(6)
                        .background(.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .topTrailing)
                }
            }
            .shadow(color: .black.opacity(0.08), radius: 3, x: 0, y: 1)

            Text(document.title)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(Color.satchelInk)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
                .padding(.horizontal, 2)

            HStack(spacing: 5) {
                Text(relativeDateLabel(document.listDate))
                if let filing = filingLabel {
                    Text("·").foregroundStyle(Color.satchelGrip)
                    Text(filing).lineLimit(1)
                }
                if document.pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.satchelPin)
                }
            }
            .font(.system(size: 11.5))
            .foregroundStyle(Color.satchelSecondary)
            .padding(.top, 3)
            .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        .task(id: document.relativePath) { await loadPicture() }
    }

    /// Endeavor first, then the first person, then the first tag: the one
    /// thing the row's chip would have said.
    private var filingLabel: String? {
        if let name = document.endeavorName, !name.isEmpty { return name }
        if let person = document.people.first { return person }
        if let tag = document.tags.first(where: { $0.caseInsensitiveCompare("private") != .orderedSame }) { return tag }
        return nil
    }

    // MARK: Picture

    @ViewBuilder
    private var picture: some View {
        if document.isLink {
            linkPicture
        } else if document.isText {
            textPicture
        } else if let thumbnail {
            Image(uiImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: document.isPDF ? .fit : .fill)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(document.isPDF ? Color.white : Color.satchelFill)
        } else {
            // Not loaded yet, or nothing to load. The mark, larger, on its
            // tint: the same picture the row draws, so nothing is ever blank.
            SatchelDocumentMark(document, size: 64, cornerRadius: 16, glyphSize: 30)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.satchelCard)
        }
    }

    /// The Scrappy tile: preview with a caption band, or the host large on
    /// the document's tint when the page offered nothing (a login wall,
    /// SharePoint). Never an empty box.
    @ViewBuilder
    private var linkPicture: some View {
        let web = TraceMacDocument.openableURL(document.url)
        let host = web.map { TraceMacDocument.webLabel($0) } ?? document.url
        if let thumbnail {
            ZStack(alignment: .bottomLeading) {
                Image(uiImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 1) {
                    Text(document.title)
                        .font(.system(size: 10.5, weight: .bold))
                        .lineLimit(1)
                    Text(host)
                        .font(.system(size: 9.5))
                        .opacity(0.85)
                        .lineLimit(1)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "link")
                    .font(.system(size: 26, weight: .medium))
                Text(shortHostName(host))
                    .font(.system(size: 12, weight: .bold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(host)
                    .font(.system(size: 9.5, weight: .semibold))
                    .opacity(0.75)
                    .lineLimit(1)
            }
            .padding(10)
            .foregroundStyle(document.resolvedTint.foreground)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(document.resolvedTint.background)
        }
    }

    /// "sharepoint" out of `atkearney.sharepoint.com`, the word a person would
    /// use for the place. The full host sits under it.
    private func shortHostName(_ host: String) -> String {
        let bare = host.split(separator: "/").first.map(String.init) ?? host
        let parts = bare.split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return bare }
        let name = parts[parts.count - 2]
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// The opening words on warm paper, the way a clipping reads.
    private var textPicture: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\u{201C}")
                .font(.system(size: 22, weight: .bold, design: .serif))
                .foregroundStyle(DocumentTint.amber.foreground)
                .frame(height: 12, alignment: .top)
            Text(textExcerpt ?? "")
                .font(.system(size: 11, design: .serif))
                .foregroundStyle(Color(red: 0.227, green: 0.227, blue: 0.235))
                .lineSpacing(2)
                .lineLimit(7)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(red: 1.0, green: 0.992, blue: 0.969))
    }

    private var kindGlyph: some View {
        Image(systemName: document.isPDF ? "doc.text" : document.isImage ? "photo" : document.isLink ? "link" : document.isText ? "text.alignleft" : "doc")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color.satchelSecondary)
            .frame(width: 22, height: 22)
            .background(.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    // MARK: Loading

    private func loadPicture() async {
        if document.isLink {
            thumbnail = SatchelLinkPreview.image(for: document.url)
            return
        }
        if document.isText {
            if !document.extractedText.isEmpty {
                textExcerpt = Self.excerpt(document.extractedText)
            } else if let url = noteStore.resolvedURL(for: document.relativePath),
                      let raw = try? String(contentsOf: url, encoding: .utf8) {
                textExcerpt = Self.excerpt(raw)
            }
            return
        }
        if let cached = SatchelThumbnailCache.shared.image(for: document.relativePath) {
            thumbnail = cached
            return
        }
        guard let url = noteStore.resolvedURL(for: document.relativePath) else { return }
        let path = document.relativePath
        let isPDF = document.isPDF
        let isImage = document.isImage
        let made: UIImage? = await Task.detached(priority: .utility) {
            if isPDF { return SatchelThumbnailCache.pdfThumbnail(url: url) }
            if isImage { return SatchelThumbnailCache.imageThumbnail(url: url) }
            return nil
        }.value
        if let made {
            SatchelThumbnailCache.shared.store(made, for: path)
            thumbnail = made
        }
    }

    private static func excerpt(_ text: String) -> String {
        let collapsed = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return String(collapsed.prefix(240))
    }
}

// MARK: - Thumbnail cache

/// In-memory only, per launch. A first page or a downsampled photo is cheap
/// to make and expensive to hold in bulk; `NSCache` evicts under pressure
/// and the tile simply makes it again. Nothing here touches the container.
final class SatchelThumbnailCache {
    static let shared = SatchelThumbnailCache()
    private let cache = NSCache<NSString, UIImage>()
    private init() { cache.countLimit = 300 }

    func image(for path: String) -> UIImage? { cache.object(forKey: path as NSString) }
    func store(_ image: UIImage, for path: String) { cache.setObject(image, forKey: path as NSString) }

    /// First page only, at tile size. `PDFPage.thumbnail` renders through the
    /// page's own drawing, so a scanned page and a typeset one both come out.
    static func pdfThumbnail(url: URL) -> UIImage? {
        guard let doc = PDFDocument(url: url), let page = doc.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(1, 400 / max(bounds.width, bounds.height))
        let size = CGSize(width: bounds.width * scale * 2, height: bounds.height * scale * 2)
        return page.thumbnail(of: size, for: .mediaBox)
    }

    /// Downsampled at decode, never decoded full size and shrunk: a 12 MP
    /// photo decoded whole is 48 MB, and a grid holds dozens.
    static func imageThumbnail(url: URL) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 600
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - Long press: the document's card (D389)
//
// One modifier for the row and the tile, so the two cannot drift. The preview
// is the native iOS card: mark or thumbnail, title, the description, the
// filing line. The actions beneath it, in order: Open in Safari for a link
// (first, because it is the one thing a link is for), New task from this,
// Edit, Pin to Kit or Unpin, Delete.

struct SatchelDocumentMenu: ViewModifier {
    let document: TraceMacDocument
    let onTask: () -> Void
    let onEdit: () -> Void
    let onPin: () -> Void
    let onDelete: () -> Void
    /// Only a blocked article has anything to retry, so this is optional and
    /// the item is absent for every other document. Defaulted last so no
    /// existing call site moves.
    var onRetry: (() -> Void)? = nil
    @Environment(\.openURL) private var openURL

    func body(content: Content) -> some View {
        content.contextMenu {
            if let web = TraceMacDocument.openableURL(document.url), document.isLink {
                Button {
                    openURL(web)
                } label: {
                    Label("Open in Safari", systemImage: "safari")
                }
            }
            Button(action: onTask) {
                Label("New task from this", systemImage: "checklist")
            }
            Button(action: onEdit) {
                Label("Edit", systemImage: "square.and.pencil")
            }
            Button(action: onPin) {
                Label(document.pinned ? "Unpin from Kit" : "Pin to Kit",
                      systemImage: document.pinned ? "pin.slash" : "pin")
            }
            // **Only when the page refused us** (D407 Build 3). A Retry on a
            // product page would be a button that correctly does nothing, and
            // on a working article it would invite him to throw away a good
            // read. `blocked` is the one state a sign-in can change.
            if document.articleState == .blocked, let onRetry {
                Button(action: onRetry) {
                    Label("Read again", systemImage: "arrow.clockwise")
                }
            }
            Button(role: .destructive, action: onDelete) {
                Label("Delete document", systemImage: "trash")
            }
        } preview: {
            SatchelPeekCard(document: document)
        }
    }
}

extension View {
    func satchelDocumentMenu(_ document: TraceMacDocument,
                             onTask: @escaping () -> Void,
                             onEdit: @escaping () -> Void,
                             onPin: @escaping () -> Void,
                             onDelete: @escaping () -> Void,
                             onRetry: (() -> Void)? = nil) -> some View {
        modifier(SatchelDocumentMenu(document: document, onTask: onTask, onEdit: onEdit,
                                     onPin: onPin, onDelete: onDelete, onRetry: onRetry))
    }
}

/// The card the long press lifts: enough to know what this is without
/// opening it. The description is the one or two sentences the scan or
/// David wrote; a document with none shows its kind and date instead of a
/// blank line.
struct SatchelPeekCard: View {
    let document: TraceMacDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                SatchelDocumentMark(document, size: 44, cornerRadius: 12, glyphSize: 21)
                VStack(alignment: .leading, spacing: 3) {
                    Text(document.title)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color.satchelInk)
                        .lineLimit(3)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.satchelSecondary)
                        .lineLimit(1)
                }
            }
            let blurb = document.description.trimmingCharacters(in: .whitespacesAndNewlines)
            if !blurb.isEmpty {
                Text(blurb)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Color.satchelInk)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !filing.isEmpty {
                Text(filing)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color.satchelSecondary)
                    .lineLimit(2)
            }
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
        .background(Color.satchelCard)
    }

    private var subtitle: String {
        var parts: [String] = [kindLabel(for: document)]
        let when = relativeDateLabel(document.listDate)
        if !when.isEmpty { parts.append(when) }
        return parts.joined(separator: " · ")
    }

    private var filing: String {
        var parts: [String] = []
        if let name = document.endeavorName, !name.isEmpty { parts.append(name) }
        parts.append(contentsOf: document.people)
        parts.append(contentsOf: document.places)
        let tags = document.tags.filter { $0.caseInsensitiveCompare("private") != .orderedSame }
        if !tags.isEmpty { parts.append(tags.map { "#" + $0 }.joined(separator: " ")) }
        return parts.joined(separator: " · ")
    }
}
