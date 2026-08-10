import UIKit
import UniformTypeIdentifiers

// MARK: - ShareViewController
//
// Principal class for the TraceShareExtension share extension.
// Receives a file from the iOS share sheet, stages it to the App Group shared
// container via AppGroup.stageIncoming(), shows a brief confirmation, then dismisses.
//
// THE EXTENSION IS APP-AGNOSTIC and always was — it stages a file and names no
// app. That is why Satchel needed no share extension of its own (scope §10's
// open question, settled 2026-07-29): only the CONSUMER moved. Trace stopped
// calling `consumeIncoming()`; `SatchelLibraryView.consumeSharedFile()` calls it
// now. The user-facing copy below is the only part that ever mentioned an app,
// and it now says Satchel.
//
// The extension still ships inside the Trace app, so the share sheet lists it
// under Trace's name and icon. Cosmetic, and a separate change — it is
// `CFBundleDisplayName` in the extension's Info.plist.
//
// The main Trace app picks up the staged file the next time it comes to foreground
// (ContentView.checkIncomingDocument()) and presents AddDocumentView pre-populated.
//
// Target membership: TraceShareExtension only.
// AppGroup.swift must be in BOTH Trace and TraceShareExtension targets.

class ShareViewController: UIViewController {

    // MARK: - UI

    private let card: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor.secondarySystemGroupedBackground
        v.layer.cornerRadius = 20
        v.layer.shadowColor = UIColor.black.cgColor
        v.layer.shadowOpacity = 0.12
        v.layer.shadowRadius = 16
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    private let iconView: UIImageView = {
        let iv = UIImageView(image: UIImage(systemName: "doc.badge.plus"))
        iv.tintColor = .systemBlue
        iv.contentMode = .scaleAspectFit
        iv.translatesAutoresizingMaskIntoConstraints = false
        return iv
    }()

    private let titleLabel: UILabel = {
        let l = UILabel()
        l.text = "Saving to Satchel…"
        l.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
        l.textAlignment = .center
        l.textColor = .label
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    private let subtitleLabel: UILabel = {
        let l = UILabel()
        l.text = "Open Satchel to file it."
        l.font = UIFont.systemFont(ofSize: 13, weight: .regular)
        l.textAlignment = .center
        l.textColor = .secondaryLabel
        l.numberOfLines = 2
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    private let spinner: UIActivityIndicatorView = {
        let s = UIActivityIndicatorView(style: .medium)
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        setupUI()
        Task { await handleIncoming() }

        // WATCHDOG. Added 2026-07-30: David shared a PDF from Mail and got a
        // spinner that never resolved. Every path through `handleIncoming` calls
        // `finish`, so something never returned — most likely `NSItemProvider`
        // never calling back for that particular attachment, which no amount of
        // code reading here can rule out.
        //
        // A share extension that hangs is the worst of the available failures: the
        // user cannot tell whether the file was saved, and the only way out is to
        // swipe the sheet away, which looks like it worked. **Failing visibly beats
        // waiting invisibly.**
        Task { [weak self] in
            // Longer than the chain can take: at most two representations are
            // attempted for any real share (the type checks skip the rest), each
            // capped at `representationTimeout`, plus slack. A watchdog that fires
            // while the work is still legitimately running would be its own bug.
            try? await Task.sleep(for: .seconds(20))
            guard let self, !self.hasFinished else { return }
            self.failureDetail = "The file took too long to load. It may still be downloading from iCloud."
            await self.finish(success: false)
        }
    }

    private func setupUI() {
        spinner.startAnimating()

        card.addSubview(iconView)
        card.addSubview(titleLabel)
        card.addSubview(subtitleLabel)
        card.addSubview(spinner)
        view.addSubview(card)

        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: 260),

            iconView.topAnchor.constraint(equalTo: card.topAnchor, constant: 28),
            iconView.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 40),
            iconView.heightAnchor.constraint(equalToConstant: 40),

            titleLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),

            spinner.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 14),
            spinner.centerXAnchor.constraint(equalTo: card.centerXAnchor),

            subtitleLabel.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 14),
            subtitleLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            subtitleLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            subtitleLabel.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -28),
        ])
    }

    // MARK: - File handling

    /// Set before `finish(success: false)` so the sheet says WHICH thing failed.
    /// Every failure used to read "Couldn't save file", which is true of a missing
    /// app group, an unreadable attachment and a full disk alike — and tells the
    /// person nothing about whether trying again would help.
    private var failureDetail: String?

    /// Guards the watchdog against finishing a request that already completed.
    private var hasFinished = false

    private func handleIncoming() async {
        guard let item = extensionContext?.inputItems.first as? NSExtensionItem,
              let attachments = item.attachments, !attachments.isEmpty else {
            failureDetail = "Nothing was attached to that share."
            await finish(success: false)
            return
        }

        for provider in attachments {
            if let result = await loadFile(from: provider) {
                do {
                    try AppGroup.stageIncoming(
                        data: result.data,
                        filename: result.filename,
                        originalName: provider.suggestedName ?? result.filename,
                        contentType: result.contentType
                    )
                    await finish(success: true)
                } catch {
                    // Almost always the App Group being unavailable, which is a
                    // provisioning problem rather than anything the user did.
                    failureDetail = "Could not write to the shared folder. \(error.localizedDescription)"
                    await finish(success: false)
                }
                return
            }
        }
        // Reached when every attachment was offered but none could be read. The
        // type identifiers are the useful fact here: they say what Mail actually
        // handed over, which is what a fix would start from.
        let offered = attachments
            .flatMap { $0.registeredTypeIdentifiers }
            .joined(separator: ", ")
        failureDetail = offered.isEmpty
            ? "That attachment could not be read."
            : "Could not read that attachment. It was offered as: \(offered)"
        await finish(success: false)
    }

    private func loadFile(from provider: NSItemProvider) async -> (data: Data, filename: String, contentType: String)? {
        // PDF
        if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
            if let data = await loadData(provider: provider, type: UTType.pdf.identifier) {
                return (data, Self.makeFilename(ext: "pdf", suggested: provider.suggestedName), "pdf")
            }
        }
        // Markdown / plain text
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let data = await loadData(provider: provider, type: UTType.plainText.identifier) {
                let ext = (provider.suggestedName as NSString?)?.pathExtension.lowercased() == "md" ? "md" : "txt"
                return (data, Self.makeFilename(ext: ext, suggested: provider.suggestedName), ext)
            }
        }
        // JPEG
        if provider.hasItemConformingToTypeIdentifier(UTType.jpeg.identifier) {
            if let data = await loadData(provider: provider, type: UTType.jpeg.identifier) {
                return (data, Self.makeFilename(ext: "jpg", suggested: provider.suggestedName), "image")
            }
        }
        // PNG
        if provider.hasItemConformingToTypeIdentifier(UTType.png.identifier) {
            if let data = await loadData(provider: provider, type: UTType.png.identifier) {
                return (data, Self.makeFilename(ext: "png", suggested: provider.suggestedName), "image")
            }
        }
        // Generic file URL (catches anything else)
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            return await loadFileURL(from: provider)
        }
        return nil
    }

    /// How long any one representation gets before the chain moves on.
    ///
    /// **Why a per-step timeout and not just the watchdog.** David was not sharing
    /// a Mail attachment — he used Spark's "export this email as PDF", which
    /// GENERATES the file when asked. A provider that renders on demand can take a
    /// while, and if it never calls back, `loadFile` is stuck on its first branch
    /// and never reaches the file-URL fallback that would have worked. The
    /// watchdog alone turns that into an honest failure; a per-step timeout turns
    /// it into a successful import.
    private static let representationTimeoutSeconds: TimeInterval = 6

    /// Guarantees a continuation is resumed exactly once, whichever of the two
    /// callers gets there first: the item provider, or the timeout.
    ///
    /// A plain flag would not do — the provider calls back on its own queue while
    /// the timer fires on the main one, so the check and the set have to be atomic.
    /// Resuming a `CheckedContinuation` twice is a hard crash, not a warning.
    private final class OneShot<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T?, Never>?

        init(_ continuation: CheckedContinuation<T?, Never>) {
            self.continuation = continuation
        }

        func resume(_ value: T?) {
            lock.lock()
            let c = continuation
            continuation = nil
            lock.unlock()
            c?.resume(returning: value)
        }
    }

    private func loadData(provider: NSItemProvider, type: String) async -> Data? {
        await withCheckedContinuation { continuation in
            let once = OneShot<Data>(continuation)
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                once.resume(data)
            }
            // The provider cannot be cancelled — `NSItemProvider` has no such API —
            // so a late callback just resolves a continuation nobody is waiting on.
            // Wasted work in an extension about to be torn down, and a far better
            // trade than a sheet that never resolves.
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.representationTimeoutSeconds) {
                once.resume(nil)
            }
        }
    }

    private func loadFileURL(from provider: NSItemProvider) async -> (data: Data, filename: String, contentType: String)? {
        await withCheckedContinuation { continuation in
            let once = OneShot<(data: Data, filename: String, contentType: String)>(continuation)
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let url = item as? URL else {
                    once.resume(nil)
                    return
                }
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else {
                    once.resume(nil)
                    return
                }
                let ext = url.pathExtension.isEmpty ? "bin" : url.pathExtension.lowercased()
                let name = Self.makeFilename(ext: ext, suggested: url.lastPathComponent)
                once.resume((data, name, ext))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.representationTimeoutSeconds) {
                once.resume(nil)
            }
        }
    }

    private static func makeFilename(ext: String, suggested: String?) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let ts = formatter.string(from: Date())
        if let suggested, !suggested.isEmpty {
            let safe = suggested
                .components(separatedBy: .whitespacesAndNewlines)
                .joined(separator: "-")
            return safe.hasSuffix(".\(ext)") ? "\(ts)-\(safe)" : "\(ts)-\(safe).\(ext)"
        }
        return "\(ts)-document.\(ext)"
    }

    // MARK: - Completion

    @MainActor
    private func finish(success: Bool) async {
        // The watchdog and the real work can both arrive here. Whichever is first
        // wins; the second returns without touching a request already completed.
        guard !hasFinished else { return }
        hasFinished = true

        spinner.stopAnimating()
        if success {
            iconView.image = UIImage(systemName: "checkmark.circle.fill")
            iconView.tintColor = .systemGreen
            titleLabel.text = "Saved to Satchel"
            subtitleLabel.text = "Open Satchel to file it."
        } else {
            iconView.image = UIImage(systemName: "xmark.circle.fill")
            iconView.tintColor = .systemRed
            titleLabel.text = "Couldn't save file"
            subtitleLabel.text = failureDetail ?? "Try opening Satchel and scanning it instead."
            subtitleLabel.numberOfLines = 0
        }
        // Longer on failure: the message is now worth reading, and 1.4 seconds is
        // not enough to read a sentence and a list of type identifiers.
        try? await Task.sleep(for: .seconds(success ? 1.4 : 6))
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }
}
