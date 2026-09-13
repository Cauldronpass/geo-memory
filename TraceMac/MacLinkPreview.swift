import AppKit
import SwiftUI
import LinkPresentation
import CryptoKit

// MARK: - MacLinkPreview
//
// Session 102, the Mac half of D387. The phone caches a page's preview image
// for its grid; the Mac has no grid, but it has a reading pane, and David
// looking at a pasted link saw a glyph, a title and a host and asked for the
// picture the phone gets. Same reader (`LPMetadataProvider`), same rule about
// where it lives: the app's Caches directory, keyed by the normalised address,
// derived and rebuildable, never a third file in the container.
//
// The Mac draws it with `LPLinkView`, the system's own rich link card, the
// one Messages and Notes use. It knows how to lay out a title, an image, a
// video embed and a favicon without this app deciding any of that, and it
// does the right thing for a YouTube address, which the phone's flat image
// cannot.

@MainActor
enum MacLinkPreview {

    private static let memory = NSCache<NSString, LPLinkMetadata>()

    /// Cached first, fetched otherwise. Nil when the page refuses (a login
    /// wall, SharePoint), which is normal and leaves the plain pane in place.
    static func metadata(for urlString: String) async -> LPLinkMetadata? {
        guard let url = TraceMacDocument.openableURL(urlString) else { return nil }
        let key = normalised(url.absoluteString)
        if let hit = memory.object(forKey: key as NSString) { return hit }
        if let disk = readDisk(key: key) {
            memory.setObject(disk, forKey: key as NSString)
            return disk
        }
        let provider = LPMetadataProvider()
        provider.timeout = 12
        provider.shouldFetchSubresources = true
        guard let fetched = try? await provider.startFetchingMetadata(for: url) else { return nil }
        memory.setObject(fetched, forKey: key as NSString)
        writeDisk(fetched, key: key)
        return fetched
    }

    static func normalised(_ urlString: String) -> String {
        var s = urlString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasPrefix("http://") { s.removeFirst(7) }
        if s.hasPrefix("https://") { s.removeFirst(8) }
        if s.hasPrefix("www.") { s.removeFirst(4) }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    // MARK: Disk

    private static var directory: URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let dir = caches.appendingPathComponent("link-previews", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func fileURL(key: String) -> URL? {
        guard let dir = directory else { return nil }
        let digest = SHA256.hash(data: Data(key.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined().prefix(32)
        return dir.appendingPathComponent("\(name).lpmeta")
    }

    /// `LPLinkMetadata` is `NSSecureCoding`, image and all, so the archive is
    /// the whole card and a cold launch draws it without a network call.
    private static func readDisk(key: String) -> LPLinkMetadata? {
        guard let file = fileURL(key: key), let data = try? Data(contentsOf: file) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: LPLinkMetadata.self, from: data)
    }

    private static func writeDisk(_ metadata: LPLinkMetadata, key: String) {
        guard let file = fileURL(key: key),
              let data = try? NSKeyedArchiver.archivedData(withRootObject: metadata, requiringSecureCoding: true) else { return }
        try? data.write(to: file, options: .atomic)
    }
}

// MARK: - MacLinkCard

/// The system's rich link card, sized by its own content. `LPLinkView` picks
/// its layout from what the metadata holds: image on top for a page, an
/// inline player for a video, a compact row when there is only a title.
struct MacLinkCard: NSViewRepresentable {
    let metadata: LPLinkMetadata

    func makeNSView(context: Context) -> LPLinkView {
        let view = LPLinkView(metadata: metadata)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateNSView(_ view: LPLinkView, context: Context) {
        view.metadata = metadata
    }
}
