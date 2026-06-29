import Foundation

// MARK: - AppGroup
//
// Shared utility for staging files between the TraceShareExtension and the main Trace app.
// Both targets must have the App Group entitlement: group.com.david.trace
//
// Flow:
//   1. Share Extension receives a file → calls AppGroup.stageIncoming(...)
//   2. Main app comes to foreground → calls AppGroup.consumeIncoming()
//   3. If a pending file is found, ContentView presents AddDocumentView pre-populated.

enum AppGroup {

    static let identifier = "group.com.david.trace"

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    private static var incomingURL: URL? {
        containerURL?.appendingPathComponent("incoming")
    }

    // MARK: - Write (called from Share Extension)

    /// Stages an incoming file so the main app can pick it up on next foreground.
    static func stageIncoming(
        data: Data,
        filename: String,
        originalName: String,
        contentType: String
    ) throws {
        guard let incomingURL else { throw AppGroupError.containerUnavailable }
        try FileManager.default.createDirectory(at: incomingURL, withIntermediateDirectories: true)

        // Write file data
        let fileURL = incomingURL.appendingPathComponent(filename)
        try data.write(to: fileURL)

        // Write metadata sidecar
        let meta: [String: String] = [
            "filename": filename,
            "originalName": originalName,
            "contentType": contentType,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        let metaURL = incomingURL.appendingPathComponent("pending.json")
        try JSONSerialization.data(withJSONObject: meta, options: .prettyPrinted).write(to: metaURL)
    }

    // MARK: - Read + consume (called from main app)

    /// Reads and removes the staged file. Returns nil if nothing is pending.
    static func consumeIncoming() -> IncomingDocument? {
        guard let incomingURL,
              let metaData = try? Data(contentsOf: incomingURL.appendingPathComponent("pending.json")),
              let meta = try? JSONSerialization.jsonObject(with: metaData) as? [String: String],
              let filename = meta["filename"]
        else { return nil }

        let fileURL = incomingURL.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: fileURL) else {
            // Clean up orphaned metadata
            try? FileManager.default.removeItem(at: incomingURL.appendingPathComponent("pending.json"))
            return nil
        }

        // Clean up both files
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: incomingURL.appendingPathComponent("pending.json"))

        return IncomingDocument(
            data: data,
            filename: filename,
            originalName: meta["originalName"] ?? filename,
            contentType: meta["contentType"] ?? "file"
        )
    }
}

// MARK: - IncomingDocument

struct IncomingDocument: Identifiable {
    let id = UUID()
    let data: Data
    let filename: String       // timestamped storage name, e.g. "2026-06-28-143022-report.pdf"
    let originalName: String   // original filename from the share source
    let contentType: String    // "pdf", "image", "md", "file", etc.
}

// MARK: - Error

enum AppGroupError: LocalizedError {
    case containerUnavailable
    var errorDescription: String? {
        "App group container is unavailable. Make sure both targets have the group.com.david.trace entitlement."
    }
}
