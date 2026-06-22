import Foundation
import UIKit

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
    private static let model    = "claude-haiku-4-5-20251001"
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

    /// Sends `image` to Claude and returns extracted OT stats.
    static func scan(image: UIImage) async throws -> OTScanResult {
        guard let jpeg = image.jpegData(compressionQuality: 0.8) else {
            throw OTScanError.imageEncodingFailed
        }
        let base64 = jpeg.base64EncodedString()

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 512,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "image",
                            "source": [
                                "type": "base64",
                                "media_type": "image/jpeg",
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
        req.setValue(Config.claudeAPIKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01",        forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json",  forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let detail = String(data: data, encoding: .utf8) ?? "no body"
            throw OTScanError.apiError(detail)
        }

        // Unwrap Claude response envelope → text content
        let envelope = try JSONDecoder().decode(ClaudeEnvelope.self, from: data)
        guard let text = envelope.content.first(where: { $0.type == "text" })?.text else {
            throw OTScanError.noContent
        }

        // Strip markdown code fences Claude sometimes wraps around JSON
        let jsonString = stripCodeFence(text)
        guard let jsonData = jsonString.data(using: .utf8) else {
            throw OTScanError.parseError("Response not UTF-8")
        }

        return try JSONDecoder().decode(OTScanResult.self, from: jsonData)
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
    let text: String
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
