import Foundation

// MARK: - Result model

struct OTScanResult: Decodable {
    let splatPoints: Int?
    let calories: Int?
    let durationMinutes: Int?
    let classDate: String?      // "YYYY-MM-DD" or nil
    let zones: OTZones?
    let maxHr: Int?
    let avgHr: Int?
    let distanceMiles: Double?
    let steps: Int?
    let avgSpeedMph: Double?    // converted to min/mi pace in the view
    let elevationFt: Double?

    enum CodingKeys: String, CodingKey {
        case splatPoints    = "splat_points"
        case calories
        case durationMinutes = "duration_minutes"
        case classDate      = "class_date"
        case zones
        case maxHr          = "max_hr"
        case avgHr          = "avg_hr"
        case distanceMiles  = "distance_miles"
        case steps
        case avgSpeedMph    = "avg_speed_mph"
        case elevationFt    = "elevation_ft"
    }
}

struct OTZones: Decodable {
    let gray: OTZone?
    let blue: OTZone?
    let green: OTZone?
    let orange: OTZone?
    let red: OTZone?
}

struct OTZone: Decodable {
    let minutes: Int?
    let percent: Int?
}

// MARK: - Service

enum OTScanService {

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let model    = "claude-sonnet-5"

    private static var apiKey: String {
        #if os(macOS)
        return UserDefaults(suiteName: "group.com.david.trace")?.string(forKey: "claude_api_key") ?? ""
        #else
        return Config.claudeAPIKey
        #endif
    }
    private static let prompt   = """
        This is a photo of an OrangeTheory Fitness class summary screen. \
        Extract the following fields and return JSON only, no explanation: \
        splat_points (int), calories (int), duration_minutes (int), \
        class_date (YYYY-MM-DD or null), \
        zones (object with keys gray/blue/green/orange/red, each with minutes and percent as ints or null), \
        max_hr (int or null), avg_hr (int or null), \
        distance_miles (float or null), steps (int or null), \
        avg_speed_mph (float or null), elevation_ft (float or null). \
        If a field is not visible, use null.
        """

    /// Detects image format from magic bytes. Anthropic supports jpeg, png, gif, webp.
    private static func mediaType(for data: Data) -> String {
        if data.prefix(2) == Data([0xFF, 0xD8])                              { return "image/jpeg" }
        if data.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47])                 { return "image/png"  }
        if data.prefix(3) == Data([0x47, 0x49, 0x46])                       { return "image/gif"  }
        if data.count > 12 && data[8..<12] == Data([0x57, 0x45, 0x42, 0x50]) { return "image/webp" }
        return "image/jpeg"
    }

    /// Sends `imageData` to Claude and returns extracted OT stats.
    /// Accepts any format Anthropic supports (JPEG, PNG, GIF, WebP) — format is auto-detected.
    static func scan(imageData: Data) async throws -> OTScanResult {
        let base64 = imageData.base64EncodedString()

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "image",
                            "source": [
                                "type": "base64",
                                "media_type": mediaType(for: imageData),
                                "data": base64
                            ]
                        ],
                        [
                            "type": "text",
                            "text": prompt
                        ]
                    ]
                ]
            ]
        ]

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01",        forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json",  forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)

        let rawBody = String(data: data, encoding: .utf8) ?? "no body"

        guard let http = response as? HTTPURLResponse else {
            throw OTScanError.apiError("No HTTP response")
        }
        guard http.statusCode == 200 else {
            throw OTScanError.apiError("HTTP \(http.statusCode): \(rawBody.prefix(300))")
        }

        // Unwrap Claude response envelope → text content
        // Use lenient decode so blocks without a `text` field don't crash the decoder
        guard let envelope = try? JSONDecoder().decode(ClaudeEnvelope.self, from: data),
              let text = envelope.content.first(where: { $0.type == "text" })?.text else {
            throw OTScanError.noContent
        }

        // Strip markdown code fences Claude sometimes wraps around JSON
        let jsonString = stripCodeFence(text)
        guard let jsonData = jsonString.data(using: .utf8) else {
            throw OTScanError.parseError("Response not UTF-8")
        }

        do {
            return try JSONDecoder().decode(OTScanResult.self, from: jsonData)
        } catch {
            // Surface the raw text so you can see what Claude actually returned
            throw OTScanError.parseError("JSON decode failed. Raw: \(jsonString.prefix(400))")
        }
    }

    // MARK: - Private helpers

    private static func stripCodeFence(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix("```") else { return s }
        let lines = s.components(separatedBy: "\n")
        // Drop first line (```json or ```) and last line (```)
        return lines.dropFirst().dropLast()
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Private response envelope

private struct ClaudeEnvelope: Decodable {
    let content: [ClaudeBlock]
}

private struct ClaudeBlock: Decodable {
    let type: String
    let text: String?   // optional — non-text blocks (e.g. tool_use) have no text field
}

// MARK: - Errors

enum OTScanError: LocalizedError {
    case imageEncodingFailed
    case apiError(String)
    case noContent
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .imageEncodingFailed:  return "Could not encode image."
        case .apiError(let msg):    return "API error: \(msg)"
        case .noContent:            return "Claude returned no text content."
        case .parseError(let msg):  return "Could not parse response: \(msg)"
        }
    }
}
