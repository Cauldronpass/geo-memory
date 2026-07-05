// DocumentScanService.swift
// Uses Claude to extract tags and a short description from a document (PDF or image).
// Mac-only — do not add to iOS, Widget, or Share Extension targets.

import Foundation
import PDFKit
import AppKit

// DocumentScanResult is defined in TraceDocumentModels.swift (shared).

// MARK: - Errors

enum DocumentScanError: LocalizedError {
    case noContent
    case apiError(String)
    case parseError(String)
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .noContent:             return "Claude returned no content."
        case .apiError(let msg):     return "API error: \(msg)"
        case .parseError(let msg):   return "Parse error: \(msg)"
        case .unsupportedFormat:     return "Unsupported file format."
        }
    }
}

// MARK: - Service

enum DocumentScanService {

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let model    = "claude-haiku-4-5-20251001"   // fast + cheap for metadata extraction

    private static var apiKey: String {
        UserDefaults(suiteName: "group.com.david.trace")?.string(forKey: "claude_api_key") ?? ""
    }

    // MARK: - Public entry point

    /// Scans a document and returns suggested tags + description.
    /// - Parameters:
    ///   - doc: The document to scan.
    ///   - noteStore: Used to resolve the file URL.
    ///   - existingTags: All tags already in use across the library — Claude will prefer these.
    static func scan(
        doc: TraceMacDocument,
        noteStore: NoteStore,
        existingTags: [String],
        userContext: String = ""
    ) async throws -> DocumentScanResult {
        guard let fileURL = noteStore.resolvedURL(for: doc.relativePath) else {
            throw DocumentScanError.noContent
        }

        if doc.isPDF {
            return try await scanPDF(at: fileURL, filename: doc.filename, existingTags: existingTags, userContext: userContext)
        } else if doc.isImage {
            return try await scanImage(at: fileURL, filename: doc.filename, existingTags: existingTags, userContext: userContext)
        } else {
            throw DocumentScanError.unsupportedFormat
        }
    }

    // MARK: - PDF scanning

    private static func scanPDF(at url: URL, filename: String, existingTags: [String], userContext: String) async throws -> DocumentScanResult {
        guard let pdf = PDFDocument(url: url) else {
            throw DocumentScanError.noContent
        }

        // Extract text from up to the first 4 pages (enough for metadata, avoids huge prompts)
        var extractedText = ""
        let pageLimit = min(pdf.pageCount, 4)
        for i in 0..<pageLimit {
            if let page = pdf.page(at: i), let text = page.string {
                extractedText += text + "\n"
            }
        }

        let textPreview = String(extractedText.prefix(3000))   // cap at ~3k chars
        guard !textPreview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DocumentScanError.noContent
        }

        let prompt = buildPrompt(content: textPreview, existingTags: existingTags, isText: true, filename: filename, userContext: userContext)
        return try await callClaude(textPrompt: prompt)
    }

    // MARK: - Image scanning

    private static func scanImage(at url: URL, filename: String, existingTags: [String], userContext: String) async throws -> DocumentScanResult {
        // Trigger iCloud download if the file is a cloud placeholder
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)

        guard let rawData = try? Data(contentsOf: url), !rawData.isEmpty else {
            throw DocumentScanError.apiError("Could not read image file — it may still be downloading from iCloud.")
        }

        // Resize large images before encoding: Claude's API rejects base64 payloads over ~5 MB.
        // Document scanner images can easily be 4–8 MB; cap the long edge at 1600 px.
        let imageData = resizedImageData(rawData, maxDimension: 1600) ?? rawData

        let prompt = buildPrompt(content: nil, existingTags: existingTags, isText: false, filename: filename, userContext: userContext)
        return try await callClaude(imageData: imageData, textPrompt: prompt)
    }

    /// Returns JPEG data with the long edge capped at `maxDimension`. Returns nil if the image
    /// can't be decoded (caller should fall back to the original data).
    private static func resizedImageData(_ data: Data, maxDimension: CGFloat) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth]  as? CGFloat,
              let h = props[kCGImagePropertyPixelHeight] as? CGFloat else { return nil }

        let longEdge = max(w, h)
        guard longEdge > maxDimension else { return nil }   // already small enough

        let scale  = maxDimension / longEdge
        let newW   = Int(w * scale)
        let newH   = Int(h * scale)

        guard let cgImage = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }

        let ctx = CGContext(
            data: nil,
            width: newW, height: newH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )
        ctx?.draw(cgImage, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        guard let resized = ctx?.makeImage() else { return nil }

        let dest = NSMutableData()
        guard let destRef = CGImageDestinationCreateWithData(dest, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destRef, resized, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destRef) else { return nil }
        return dest as Data
    }

    // MARK: - Prompt

    private static var monthYearStamp: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MM-yyyy"
        return fmt.string(from: Date())
    }

    private static func buildPrompt(content: String?, existingTags: [String], isText: Bool, filename: String, userContext: String = "") -> String {
        let tagHint = existingTags.isEmpty
            ? ""
            : "Prefer tags from this existing list when they fit: [\(existingTags.joined(separator: ", "))]. You may suggest new tags if none fit."

        let docRef = isText ? "document text" : "document image"
        let stamp = monthYearStamp   // e.g. "07-2026"
        let contextLine = userContext.isEmpty
            ? ""
            : "\n\nUser-provided context (treat as authoritative — use it to sharpen the title, tags, and description): \(userContext)"

        return """
        Analyze this \(docRef) and return JSON only — no explanation, no markdown fences.

        Return exactly this structure:
        {
          "tags": ["tag1", "tag2", "tag3"],
          "description": "One to two sentence summary of what this document is.",
          "title": "Short descriptive title" or null
        }

        Rules:
        - tags: 2–5 short lowercase words or phrases. \(tagHint)
        - description: factual, concise. Include key amounts, dates, or parties if present.
        - title: suggest a short human-readable title (3–6 words, title case) ONLY if the filename looks auto-generated (e.g. IMG_xxxx, CleanShot timestamp, DSC_xxxx, screenshot dates, random strings). The original filename is: \(filename). If the filename is already descriptive, return null for title. If the image has recognizable content, use that for the title. If the content is unrecognizable or too generic to name meaningfully (e.g. a plain portrait with no context, a blank or unclear photo), use the fallback title "Image \(stamp)".
        - Return valid JSON only. No other text.\(contextLine)
        \(content.map { "\n\nDocument text:\n\($0)" } ?? "")
        """
    }

    // MARK: - Claude API call (text prompt only)

    private static func callClaude(textPrompt: String) async throws -> DocumentScanResult {
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 512,
            "messages": [[
                "role": "user",
                "content": textPrompt
            ]]
        ]
        return try await sendRequest(body: body)
    }

    // MARK: - Claude API call (image + text prompt)

    private static func callClaude(imageData: Data, textPrompt: String) async throws -> DocumentScanResult {
        let base64 = imageData.base64EncodedString()
        let mediaType = detectMediaType(imageData)
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 512,
            "messages": [[
                "role": "user",
                "content": [
                    [
                        "type": "image",
                        "source": [
                            "type": "base64",
                            "media_type": mediaType,
                            "data": base64
                        ]
                    ],
                    [
                        "type": "text",
                        "text": textPrompt
                    ]
                ]
            ]]
        ]
        return try await sendRequest(body: body)
    }

    // MARK: - Shared request sender

    private static func sendRequest(body: [String: Any]) async throws -> DocumentScanResult {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue(apiKey,            forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01",      forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        let rawBody = String(data: data, encoding: .utf8) ?? ""

        guard let http = response as? HTTPURLResponse else {
            throw DocumentScanError.apiError("No HTTP response")
        }
        guard http.statusCode == 200 else {
            throw DocumentScanError.apiError("HTTP \(http.statusCode): \(rawBody.prefix(200))")
        }

        // Parse Claude envelope
        guard let envelope = try? JSONDecoder().decode(ClaudeEnvelope.self, from: data) else {
            throw DocumentScanError.parseError("Unexpected API response: \(rawBody.prefix(300))")
        }
        guard let text = envelope.content.first(where: { $0.type == "text" })?.text else {
            throw DocumentScanError.noContent
        }

        // Strip code fences if Claude wrapped the JSON anyway
        let cleaned = stripCodeFence(text)
        guard let jsonData = cleaned.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw DocumentScanError.parseError("Could not parse JSON: \(cleaned.prefix(200))")
        }

        let tags = (obj["tags"] as? [String] ?? []).map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
        let description = obj["description"] as? String ?? ""
        let title: String? = {
            guard let t = obj["title"] as? String,
                  !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  t.lowercased() != "null" else { return nil }
            return t.trimmingCharacters(in: .whitespacesAndNewlines)
        }()

        return DocumentScanResult(tags: tags, description: description, title: title)
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

// MARK: - Claude response envelope (shared shape)

private struct ClaudeEnvelope: Decodable {
    let content: [ClaudeContent]
}

private struct ClaudeContent: Decodable {
    let type: String
    let text: String?
}
