import UIKit
import UniformTypeIdentifiers

// MARK: - ShareViewController
//
// Principal class for the TraceShareExtension share extension.
// Receives a file from the iOS share sheet, stages it to the App Group shared
// container via AppGroup.stageIncoming(), shows a brief confirmation, then dismisses.
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
        l.text = "Saving to Trace…"
        l.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
        l.textAlignment = .center
        l.textColor = .label
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    private let subtitleLabel: UILabel = {
        let l = UILabel()
        l.text = "Open Trace to finish routing the file."
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

    private func handleIncoming() async {
        guard let item = extensionContext?.inputItems.first as? NSExtensionItem,
              let attachments = item.attachments, !attachments.isEmpty else {
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
                    await finish(success: false)
                }
                return
            }
        }
        await finish(success: false)
    }

    private func loadFile(from provider: NSItemProvider) async -> (data: Data, filename: String, contentType: String)? {
        // PDF
        if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
            if let data = await loadData(provider: provider, type: UTType.pdf.identifier) {
                return (data, makeFilename(ext: "pdf", suggested: provider.suggestedName), "pdf")
            }
        }
        // Markdown / plain text
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let data = await loadData(provider: provider, type: UTType.plainText.identifier) {
                let ext = (provider.suggestedName as NSString?)?.pathExtension.lowercased() == "md" ? "md" : "txt"
                return (data, makeFilename(ext: ext, suggested: provider.suggestedName), ext)
            }
        }
        // JPEG
        if provider.hasItemConformingToTypeIdentifier(UTType.jpeg.identifier) {
            if let data = await loadData(provider: provider, type: UTType.jpeg.identifier) {
                return (data, makeFilename(ext: "jpg", suggested: provider.suggestedName), "image")
            }
        }
        // PNG
        if provider.hasItemConformingToTypeIdentifier(UTType.png.identifier) {
            if let data = await loadData(provider: provider, type: UTType.png.identifier) {
                return (data, makeFilename(ext: "png", suggested: provider.suggestedName), "image")
            }
        }
        // Generic file URL (catches anything else)
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            return await loadFileURL(from: provider)
        }
        return nil
    }

    private func loadData(provider: NSItemProvider, type: String) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    private func loadFileURL(from provider: NSItemProvider) async -> (data: Data, filename: String, contentType: String)? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let url = item as? URL else {
                    continuation.resume(returning: nil)
                    return
                }
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else {
                    continuation.resume(returning: nil)
                    return
                }
                let ext = url.pathExtension.isEmpty ? "bin" : url.pathExtension.lowercased()
                let name = self.makeFilename(ext: ext, suggested: url.lastPathComponent)
                continuation.resume(returning: (data, name, ext))
            }
        }
    }

    private func makeFilename(ext: String, suggested: String?) -> String {
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
        spinner.stopAnimating()
        if success {
            iconView.image = UIImage(systemName: "checkmark.circle.fill")
            iconView.tintColor = .systemGreen
            titleLabel.text = "Saved to Trace"
        } else {
            iconView.image = UIImage(systemName: "xmark.circle.fill")
            iconView.tintColor = .systemRed
            titleLabel.text = "Couldn't save file"
            subtitleLabel.text = "Try opening Trace and using Add Document."
        }
        try? await Task.sleep(nanoseconds: 1_400_000_000)
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }
}
