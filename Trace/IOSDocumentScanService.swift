// iOSDocumentScanService.swift
// iOS port of DocumentScanService — replaces AppKit/NSImage with UIKit/UIImage.
// PDFKit is available on iOS 11+. Same Claude API call, same prompt, same JSON output.
// iOS-only — do not add to Mac target (Mac uses DocumentScanService).
//
// Session 50 (2026-07-27) — Satchel build step 3, "extend the scan service".
//
// 1. The prompt now also asks for `icon` and `tint`, chosen from the fixed
//    vocabularies on `DocumentIcon` / `DocumentTint` in `TraceDocumentModels.swift`,
//    and they are parsed into `DocumentScanResult`. Scope doc §5 "Document icons":
//    computed once at capture, cached in the sidecar forever, so rendering is a
//    local SF Symbol lookup with no network. Unrecognised tokens parse to nil and
//    the model's type-based fallback applies rather than rendering blank.
//
// 2. `resizeImageData` was main-actor-isolated (UIKit rendering under the
//    project's default MainActor isolation) yet called from `Task.detached` —
//    a warning today, a hard error under Swift 6. Rewritten on ImageIO, which
//    is thread-safe, has no actor isolation, honours EXIF orientation and uses
//    far less memory downscaling a 12MP photo than UIGraphicsImageRenderer did.

import Foundation
import PDFKit
import UIKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - Errors

enum iOSDocumentScanError: LocalizedError {
    /// The document is tagged `private` and must not be sent.
    ///
    /// **Thrown by the service, not checked by the caller.** Every UI guard is
    /// an explanation; this is the enforcement. A future button wired straight
    /// to `scan` or `summarize` now fails loudly instead of leaking quietly.
    case isPrivate
    case noContent
    case apiError(String)
    case parseError(String)
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .isPrivate:           return "This document is tagged private. Nothing about it has been sent."
        case .noContent:           return "Claude returned no content."
        case .apiError(let msg):   return "API error: \(msg)"
        case .parseError(let msg): return "Parse error: \(msg)"
        case .unsupportedFormat:   return "Unsupported file format."
        }
    }
}

// MARK: - Service

enum iOSDocumentScanService {

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let model    = "claude-haiku-4-5-20251001"

    private static var apiKey: String {
        // Shared App Group key (same as BilliardsScanService / OTScanService)
        UserDefaults(suiteName: "group.com.david.trace")?.string(forKey: "claude_api_key")
            ?? Config.claudeAPIKey
    }

    private static var monthYearStamp: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MM-yyyy"
        return fmt.string(from: Date())
    }

    // MARK: - Public entry point

    /// - Parameter filenameIsGenerated: pass `true` when the app invented the
    ///   filename rather than the user choosing it — every Satchel capture, where
    ///   names are `…-scan.pdf` or `…-photo.jpg`. The default title rule only
    ///   suggests a name when the filename *looks* auto-generated, which was
    ///   right for Trace (users imported files that were already named) and
    ///   wrong here: "scan" reads as descriptive to the model, so it returned
    ///   null and every scanned document stayed titled "scan".
    static func scan(
        doc: TraceMacDocument,
        noteStore: NoteStore,
        existingTags: [String],
        userContext: String = "",
        filenameIsGenerated: Bool = false
    ) async throws -> DocumentScanResult {
        guard !doc.isPrivate else { throw iOSDocumentScanError.isPrivate }
        guard let fileURL = noteStore.resolvedURL(for: doc.relativePath) else {
            throw iOSDocumentScanError.noContent
        }

        if doc.isPDF {
            return try await scanPDF(at: fileURL, filename: doc.filename,
                                     existingTags: existingTags, userContext: userContext,
                                     filenameIsGenerated: filenameIsGenerated)
        } else if doc.isImage {
            return try await scanImage(at: fileURL, filename: doc.filename,
                                       existingTags: existingTags, userContext: userContext,
                                       filenameIsGenerated: filenameIsGenerated)
        } else {
            throw iOSDocumentScanError.unsupportedFormat
        }
    }

    // MARK: - Summarize (on demand)

    /// A fuller read, run only when David presses the button.
    ///
    /// Deliberately a SEPARATE entry point from `scan`, not a longer version of
    /// it, because the two answer different questions. `scan` runs automatically
    /// at capture and must be fast, so it stops at 4 pages and returns one or two
    /// sentences into `description`, which is what list rows render. Summarize is
    /// a decision to spend the call: it reads far deeper and returns prose that
    /// lands in the sidecar body under `## Summary`, leaving `description` alone.
    ///
    /// Returns plain text, not JSON — there is nothing to parse into fields.
    static func summarize(
        doc: TraceMacDocument,
        noteStore: NoteStore,
        userContext: String = ""
    ) async throws -> String {
        guard !doc.isPrivate else { throw iOSDocumentScanError.isPrivate }
        guard let fileURL = noteStore.resolvedURL(for: doc.relativePath) else {
            throw iOSDocumentScanError.noContent
        }

        let contextLine = userContext.isEmpty
            ? ""
            : "\n\nThe owner added this context, treat it as authoritative: \(userContext)"

        let instruction = """
        Summarise this document for someone who filed it and is coming back to it later, \
        possibly months from now.

        - Lead with what it is and who it is from or with.
        - Keep every figure, date, deadline, account number, reference and party that would \
          matter later. Those are the reason the document was kept.
        - Note anything time-sensitive: expiry, renewal, a date something is due.
        - 2 to 4 short paragraphs. No preamble, no "this document appears to be". \
          Plain prose, no markdown headings.
        - If the document is unreadable, say so in one line rather than inventing content.\(contextLine)
        """

        if doc.isPDF {
            guard let pdf = PDFDocument(url: fileURL) else { throw iOSDocumentScanError.noContent }

            // 12 pages rather than scan's 4 — a lease or a policy carries the
            // things worth remembering well past page four.
            var text = ""
            for i in 0..<min(pdf.pageCount, 12) {
                if let page = pdf.page(at: i), let pageText = page.string {
                    text += pageText + "\n"
                }
            }
            let preview = String(text.prefix(12000))

            if preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Scanned PDF, no text layer — same fallback as `scan`.
                guard let page = pdf.page(at: 0), let image = renderPageImage(page) else {
                    throw iOSDocumentScanError.noContent
                }
                return try await sendForText(imageData: image, prompt: instruction)
            }
            return try await sendForText(prompt: instruction + "\n\nDocument text:\n" + preview)
        }

        if doc.isImage {
            guard let raw = try? Data(contentsOf: fileURL) else {
                throw iOSDocumentScanError.noContent
            }
            let data = await Task.detached(priority: .userInitiated) {
                ScanImage.downscaled(raw, maxDimension: 1536)
            }.value
            return try await sendForText(imageData: data, prompt: instruction)
        }

        throw iOSDocumentScanError.unsupportedFormat
    }

    // MARK: - Plain-text sender

    private static func sendForText(imageData: Data? = nil, prompt: String) async throws -> String {
        var content: [[String: Any]] = []
        if let imageData {
            content.append([
                "type": "image",
                "source": ["type": "base64",
                           "media_type": detectMediaType(imageData),
                           "data": imageData.base64EncodedString()]
            ])
        }
        content.append(["type": "text", "text": prompt])

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1200,
            "messages": [["role": "user", "content": content]]
        ]

        var req = URLRequest(url: endpoint, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue(apiKey,             forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01",       forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw iOSDocumentScanError.apiError("No HTTP response")
        }
        guard http.statusCode == 200 else {
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw iOSDocumentScanError.apiError("HTTP \(http.statusCode): \(raw.prefix(200))")
        }
        guard let envelope = try? JSONDecoder().decode(ClaudeEnvelopeiOS.self, from: data),
              let text = envelope.content.first(where: { $0.type == "text" })?.text,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw iOSDocumentScanError.noContent
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - PDF scanning

    private static func scanPDF(at url: URL, filename: String,
                                 existingTags: [String], userContext: String,
                                 filenameIsGenerated: Bool = false) async throws -> DocumentScanResult {
        guard let pdf = PDFDocument(url: url) else {
            throw iOSDocumentScanError.noContent
        }
        var extractedText = ""
        let pageLimit = min(pdf.pageCount, 4)
        for i in 0..<pageLimit {
            if let page = pdf.page(at: i), let text = page.string {
                extractedText += text + "\n"
            }
        }
        let textPreview = String(extractedText.prefix(3000))

        // A PDF from VNDocumentCameraViewController is PAGE IMAGES with no text
        // layer, so `page.string` returns nothing and this used to throw
        // `.noContent` — every scanned document silently got no AI at all, which
        // is why scans stayed titled "scan" while camera photos came back fully
        // described. Fall back to sending the rendered first page as an image
        // and letting the model read it.
        guard !textPreview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            guard let page = pdf.page(at: 0) else { throw iOSDocumentScanError.noContent }
            let rendered = renderPageImage(page)
            guard let rendered else { throw iOSDocumentScanError.noContent }
            let imagePrompt = buildPrompt(content: nil, existingTags: existingTags,
                                          isText: false, filename: filename, userContext: userContext,
                                          filenameIsGenerated: filenameIsGenerated)
            return try await callClaude(imageData: rendered, textPrompt: imagePrompt)
        }

        let prompt = buildPrompt(content: textPreview, existingTags: existingTags,
                                 isText: true, filename: filename, userContext: userContext,
                                 filenameIsGenerated: filenameIsGenerated)
        return try await callClaude(textPrompt: prompt)
    }

    /// Renders a PDF page to JPEG for the image path. Capped at 1600px on the
    /// long edge, which is comfortably enough for the model to read a receipt
    /// and keeps the upload small.
    @MainActor
    private static func renderPageImage(_ page: PDFPage) -> Data? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(1600 / max(bounds.width, bounds.height), 4)
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        return page.thumbnail(of: size, for: .mediaBox).jpegData(compressionQuality: 0.8)
    }

    // MARK: - Image scanning

    private static func scanImage(at url: URL, filename: String,
                                   existingTags: [String], userContext: String,
                                   filenameIsGenerated: Bool = false) async throws -> DocumentScanResult {
        guard let rawData = try? Data(contentsOf: url) else {
            throw iOSDocumentScanError.noContent
        }
        // Resize to max 1024px before sending — iPhone photos are 3-5 MB and make
        // the base64 payload huge. Resizing cuts upload time from minutes to seconds.
        let data = await Task.detached(priority: .userInitiated) {
            ScanImage.downscaled(rawData, maxDimension: 1024)
        }.value
        let prompt = buildPrompt(content: nil, existingTags: existingTags,
                                 isText: false, filename: filename, userContext: userContext,
                                 filenameIsGenerated: filenameIsGenerated)
        return try await callClaude(imageData: data, textPrompt: prompt)
    }

    // MARK: - Image resize helper
    //
    // MOVED to `ScanImage.downscaled` in NoteStore.swift, 2026-08-01, when it turned
    // out `OTScanService` and `BilliardsScanService` had never had one. The
    // implementation and its reasoning went across unchanged; only the address
    // moved, so there is one of these rather than three.

    // MARK: - Prompt

    private static func buildPrompt(content: String?, existingTags: [String],
                                    isText: Bool, filename: String, userContext: String,
                                    filenameIsGenerated: Bool = false) -> String {
        let tagHint = existingTags.isEmpty
            ? ""
            : "Prefer tags from this existing list when they fit: [\(existingTags.joined(separator: ", "))]. You may suggest new tags if none fit."
        let docRef = isText ? "document text" : "document image"
        let stamp = monthYearStamp
        let contextLine = userContext.isEmpty
            ? ""
            : "\n\nUser-provided context (treat as authoritative): \(userContext)"

        // THE TEMPLATE AND THE RULES MUST NOT DISAGREE. This block used to offer
        // `"title": "…" or null` unconditionally, while `titleRule` below told the
        // model never to return null for an app-generated filename. The model is
        // Haiku — a small model follows the concrete output template over a
        // paragraph of prose further down, so it took the null every time. On
        // device that looked like the AI half-working: correct icon, correct
        // tint, good tags, no title and no description. Found 2026-07-28.
        let titleSlot = filenameIsGenerated
            ? "\"Short descriptive title\""
            : "\"Short descriptive title\" or null"

        return """
        Analyze this \(docRef) and return JSON only — no explanation, no markdown fences.

        Return exactly this structure:
        {
          "tags": ["tag1", "tag2", "tag3"],
          "description": "One to two sentence summary of what this document is.",
          "title": \(titleSlot),
          "icon": "one token from the icon list below",
          "tint": "one token from the tint list below"
        }

        Rules:
        - EVERY key above is required. Never omit one, and never return an empty string for description.
        - tags: 2–5 short lowercase words or phrases. \(tagHint)
        - description: factual, concise, never empty. Include key amounts, dates, or parties if present.
        - title: \(titleRule(filename: filename, stamp: stamp, generated: filenameIsGenerated))
        - icon: EXACTLY one token from this list, nothing else. Choose what the document IS, not what it is about. Reserve "photo" for images with no other identifiable purpose — if a photograph is OF a receipt, a card, a vehicle or a whiteboard, use that icon instead.
        \(DocumentIcon.promptGuide)
        - tint: EXACTLY one token from this list, nothing else: \(DocumentTint.promptTokenList).
          Pick the colour that best matches the document's own character. Reserve "red" for medical and urgent documents, and "gray" for things with no strong character of their own.
        - If you are unsure of the icon, use "document". If unsure of the tint, use "gray".
        - Return valid JSON only. No other text.\(contextLine)
        \(content.map { "\n\nDocument text:\n\($0)" } ?? "")
        """
    }

    /// The title instruction, which differs by where the document came from.
    ///
    /// A user-chosen filename is usually meaningful and should be left alone.
    /// An app-generated one ("scan", "photo") never is, and the model has no
    /// way to know the difference — asked to judge, it reads "scan" as
    /// descriptive and returns null.
    private static func titleRule(filename: String, stamp: String, generated: Bool) -> String {
        if generated {
            return """
            ALWAYS suggest a short human-readable title (3–6 words, title case) describing what this document is. \
            The filename carries no information — it was generated by the app, not chosen by anyone — so never return null. \
            Name it from the content: the party, the document type and a date or amount if present, e.g. "Marriott Denver Receipt" \
            or "ComEd Bill, July 2026". If the content is unrecognizable, use "Scan \(stamp)".
            """
        }
        return """
        suggest a short human-readable title (3–6 words, title case) ONLY if the filename looks auto-generated \
        (e.g. IMG_xxxx, CleanShot timestamp, DSC_xxxx, screenshot dates, random strings). The original filename is: \(filename). \
        If the filename is already descriptive, return null for title. If the content is unrecognizable or too generic to name \
        meaningfully, use the fallback title "Image \(stamp)".
        """
    }

    // MARK: - API call (text)

    private static func callClaude(textPrompt: String) async throws -> DocumentScanResult {
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 512,
            "messages": [["role": "user", "content": textPrompt]]
        ]
        return try await sendRequest(body: body)
    }

    // MARK: - API call (image + text)

    private static func callClaude(imageData: Data, textPrompt: String) async throws -> DocumentScanResult {
        let base64 = imageData.base64EncodedString()
        let mediaType = detectMediaType(imageData)
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 512,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image", "source": ["type": "base64", "media_type": mediaType, "data": base64]],
                    ["type": "text", "text": textPrompt]
                ]
            ]]
        ]
        return try await sendRequest(body: body)
    }

    // MARK: - Shared sender

    private static func sendRequest(body: [String: Any]) async throws -> DocumentScanResult {
        var req = URLRequest(url: endpoint, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue(apiKey,             forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01",       forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        let rawBody = String(data: data, encoding: .utf8) ?? ""

        guard let http = response as? HTTPURLResponse else {
            throw iOSDocumentScanError.apiError("No HTTP response")
        }
        guard http.statusCode == 200 else {
            throw iOSDocumentScanError.apiError("HTTP \(http.statusCode): \(rawBody.prefix(200))")
        }

        guard let envelope = try? JSONDecoder().decode(ClaudeEnvelopeiOS.self, from: data),
              let text = envelope.content.first(where: { $0.type == "text" })?.text else {
            throw iOSDocumentScanError.noContent
        }

        let cleaned = stripCodeFence(text)
        guard let jsonData = cleaned.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw iOSDocumentScanError.parseError("Could not parse JSON: \(cleaned.prefix(200))")
        }

        let tags = (obj["tags"] as? [String] ?? []).map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
        let description = obj["description"] as? String ?? ""
        let title: String? = {
            guard let t = obj["title"] as? String,
                  !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  t.lowercased() != "null" else { return nil }
            return t.trimmingCharacters(in: .whitespacesAndNewlines)
        }()

        // Fixed vocabularies. An off-list token parses to nil rather than being
        // written to the sidecar, so the type-based fallback on TraceMacDocument
        // takes over and the tile still renders.
        let icon = DocumentIcon.parse(obj["icon"] as? String)
        let tint = DocumentTint.parse(obj["tint"] as? String)

        return DocumentScanResult(
            tags: tags,
            description: description,
            title: title,
            icon: icon,
            tint: tint
        )
    }

    // MARK: - Helpers

    private static func detectMediaType(_ data: Data) -> String {
        if data.prefix(2) == Data([0xFF, 0xD8])                               { return "image/jpeg" }
        if data.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47])                  { return "image/png"  }
        if data.prefix(3) == Data([0x47, 0x49, 0x46])                        { return "image/gif"  }
        if data.count > 12 && data[8..<12] == Data([0x57, 0x45, 0x42, 0x50]) { return "image/webp" }
        return "image/jpeg"
    }

    private static func stripCodeFence(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            s = s.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
            if s.hasSuffix("```") { s = String(s.dropLast(3)) }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Claude envelope (iOS-local to avoid conflict with Mac's private types)

private struct ClaudeEnvelopeiOS: Decodable {
    let content: [ClaudeContentiOS]
}
private struct ClaudeContentiOS: Decodable {
    let type: String
    let text: String?
}
