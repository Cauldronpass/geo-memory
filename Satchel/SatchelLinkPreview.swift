import UIKit
import LinkPresentation
import CryptoKit

// MARK: - SatchelLinkPreview
//
// Session 102, D387. What a saved link LOOKS like, and where that picture lives.
//
// A `.webloc` document (D384) is two files: the plist holding the address and
// the sidecar holding everything else. The page's title goes into the sidecar
// like any other title. Its preview image does NOT: it is a picture of someone
// else's page, it can be fetched again from the address, and a third file per
// link in the iCloud container would be a second store to keep in step with
// the first, which is the mistake E40 warned against.
//
// So the image lives in this app's Caches directory, keyed by the address,
// derived and rebuildable. iOS may purge it under pressure; the tile then draws
// the host on a tinted square (D386) until a fetch refills it. Pages behind a
// login, SharePoint above all, never yield one and draw the host tile forever.
// That is the honest picture of a link the phone cannot see.
//
// `LPMetadataProvider` is the system's own reader: it follows redirects,
// honours the page's own preview tags and is what Messages uses. It runs in
// the APP, never the share extension, which has a memory ceiling and a
// dismiss-quickly contract.

enum SatchelLinkPreview {

    struct Metadata {
        var title: String?
        var image: UIImage?
    }

    // MARK: Fetch

    /// The page's title and preview image, or as much of either as the page
    /// offers. Never throws: a refused page is a normal outcome, not an error,
    /// and the caller carries on with the host as the title.
    static func fetch(for urlString: String) async -> Metadata {
        guard let url = TraceMacDocument.openableURL(urlString) else { return Metadata() }
        let provider = LPMetadataProvider()
        provider.timeout = 12
        provider.shouldFetchSubresources = true
        let metadata: LPLinkMetadata
        do {
            metadata = try await provider.startFetchingMetadata(for: url)
        } catch {
            return Metadata()
        }
        var result = Metadata(title: cleaned(metadata.title))
        if let imageProvider = metadata.imageProvider {
            result.image = await loadImage(from: imageProvider)
            if let image = result.image { store(image, for: urlString) }
        }
        return result
    }

    private static func cleaned(_ title: String?) -> String? {
        let t = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private static func loadImage(from provider: NSItemProvider) async -> UIImage? {
        await withCheckedContinuation { continuation in
            provider.loadObject(ofClass: UIImage.self) { object, _ in
                continuation.resume(returning: object as? UIImage)
            }
        }
    }

    // MARK: Cache

    private static var directory: URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let dir = caches.appendingPathComponent("link-previews", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// One file per address. The key is a hash of the NORMALISED address so
    /// `https://example.com/` and `example.com` share a picture, per E40's
    /// dedupe rule; the hash keeps a long SharePoint address off the filename.
    private static func fileURL(for urlString: String) -> URL? {
        guard let dir = directory else { return nil }
        let key = normalised(urlString)
        let digest = SHA256.hash(data: Data(key.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined().prefix(32)
        return dir.appendingPathComponent("\(name).jpg")
    }

    /// The shared rule, not a second copy of it (Session 103, D390). The
    /// dedupe check that decides whether a saved link is already a document
    /// has to agree with this cache key, and two identical functions in two
    /// files is the arrangement that stops agreeing.
    static func normalised(_ urlString: String) -> String {
        TraceMacDocument.normalisedURL(urlString)
    }

    /// The cached picture, or nil when there is none. Cheap enough for a grid
    /// cell to call on appear; the file is a JPEG a few tens of KB at most.
    static func image(for urlString: String) -> UIImage? {
        guard !urlString.isEmpty, let file = fileURL(for: urlString),
              let data = try? Data(contentsOf: file) else { return nil }
        return UIImage(data: data)
    }

    static func hasImage(for urlString: String) -> Bool {
        guard !urlString.isEmpty, let file = fileURL(for: urlString) else { return false }
        return FileManager.default.fileExists(atPath: file.path)
    }

    /// Downscaled before it is written: a tile is at most a few hundred points
    /// wide and a page's hero image can be several megabytes.
    static func store(_ image: UIImage, for urlString: String) {
        guard let file = fileURL(for: urlString) else { return }
        let maxSide: CGFloat = 800
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        let small = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        guard let data = small.jpegData(compressionQuality: 0.8) else { return }
        try? data.write(to: file, options: .atomic)
    }
}
