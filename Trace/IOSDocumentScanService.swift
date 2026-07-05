// iOSDocumentScanService.swift
// iOS port of DocumentScanService — replaces AppKit/NSImage with UIKit/UIImage.
// PDFKit is available on iOS 11+. Same Claude API call, same prompt, same JSON output.
// iOS-only — do not add to Mac target (Mac uses DocumentScanService).

import Foundation
import PDFKit
import UIKit

// MARK: - Errors

enum iOSDocumentScanError: LocalizedError {
    case noContent
    case apiError(String)
    case parseError(String)
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
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

    static func scan(
        doc: TraceMacDocument,
        noteStore: NoteStore,
        existingTags: [String],
        userContext: String = ""
    ) async throws -> DocumentScanResult {
        guard let fileURL = noteStore.resolvedURL(for: doc.relativePath) else {
            throw iOSDocumentScanError.noContent
        }

        if doc.isPDF {
            return try await scanPDF(at: fileURL, filename: doc.filename,
                                     existingTags: existingTags, userContext: userContext)
        } else if doc.isImage {
            return try await scanImage(at: fileURL, filename: doc.filename,
                                       existingTags: existingTags, userContext: userContext)
        } else {
            throw iOSDocumentScanError.unsupportedFormat
        }
    }

    // MARK: - PDF scanning

    private static func scanPDF(at url: URL, filename: String,
                                 existingTags: [String], userContext: String) async throws -> DocumentScanResult {
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
        guard !textPreview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw iOSDocumentScanError.noContent
        }
        let prompt = buildPrompt(content: textPreview, existingTags: existingTags,
                                 isText: true, filename: filename, userContext: userContext)
        return try await callClaude(textPrompt: prompt)
    }

    // MARK: - Image scanning

    private static func scanImage(at url: URL, filename: String,
                                   existingTags: [String], userContext: String) async throws -> DocumentScanResult {
        guard let rawData = try? Data(contentsOf: url) else {
            throw iOSDocumentScanError.noContent
        }
        // Resize to max 1024px before sending — iPhone photos are 3-5 MB and make
        // the base64 payload huge. Resizing cuts upload time from minutes to seconds.
        let data = await Task.detached(priority: .userInitiated) {
            resizeImageData(rawData, maxDimension: 1024)
        }.value
        let prompt = buildPrompt(content: nil, existingTags: existingTags,
                                 isText: false, filename: filename, userContext: userContext)
        return try await callClaude(imageData: data, textPrompt: prompt)
    }

    // MARK: - Image resize helper

    private static func resizeImageData(_ data: Data, maxDimension: CGFloat) -> Data {
        guard let image = UIImage(data: data) else { return data }
        let size = image.size
        guard size.width > maxDimension || size.height > maxDimension else { return data }
        let scale = maxDimension / max(size.width, size.height)
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
        return resized.jpegData(compressionQuality: 0.85) ?? data
    }

    // MARK: - Prompt

    private static func buildPrompt(content: String?, existingTags: [String],
                                    isText: Bool, filename: String, userContext: String) -> String {
        let tagHint = existingTags.isEmpty
            ? ""
            : "Prefer tags from this existing list when they fit: [\(existingTags.joined(separator: ", "))]. You may suggest new tags if none fit."
        let docRef = isText ? "document text" : "document image"
        let stamp = monthYearStamp
        let contextLine = userContext.isEmpty
            ? ""
            : "\n\nUser-provided context (treat as authoritative): \(userContext)"

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
        - title: suggest a short human-readable title (3–6 words, title case) ONLY if the filename looks auto-generated (e.g. IMG_xxxx, CleanShot timestamp, DSC_xxxx, screenshot dates, random strings). The original filename is: \(filename). If the filename is already descriptive, return null for title. If the content is unrecognizable or too generic to name meaningfully, use the fallback title "Image \(stamp)".
        - Return valid JSON only. No other text.\(contextLine)
        \(content.map { "\n\nDocument text:\n\($0)" } ?? "")
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

// MARK: - Claude envelope (iOS-local to avoid conflict with Mac's private types)

private struct ClaudeEnvelopeiOS: Decodable {
    let content: [ClaudeContentiOS]
}
private struct ClaudeContentiOS: Decodable {
    let type: String
    let text: String?
}
