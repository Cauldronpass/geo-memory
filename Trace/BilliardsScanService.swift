import Foundation
import UIKit

// MARK: - Result model

struct BilliardsScanResult: Decodable {
    let format: String?         // "8-Ball" or "9-Ball"
    let player1Name: String?
    let player1Sl: Int?         // skill level
    let player1Score: Int?      // points earned (9-ball) or games won (8-ball)
    let player1Needed: Int?     // points needed (9-ball) or games needed (8-ball)
    let player2Name: String?
    let player2Sl: Int?
    let player2Score: Int?
    let player2Needed: Int?
    let innings: Int?
    let player1TeamPoints: Int?  // APA team points earned (e.g. 2 or 0)
    let player2TeamPoints: Int?
    let winner: String?          // "player1" or "player2" or null
    let lagWinner: String?       // "player1" or "player2" or null

    enum CodingKeys: String, CodingKey {
        case format
        case player1Name        = "player1_name"
        case player1Sl          = "player1_sl"
        case player1Score       = "player1_score"
        case player1Needed      = "player1_needed"
        case player1TeamPoints  = "player1_team_points"
        case player2Name        = "player2_name"
        case player2Sl          = "player2_sl"
        case player2Score       = "player2_score"
        case player2Needed      = "player2_needed"
        case player2TeamPoints  = "player2_team_points"
        case innings
        case winner
        case lagWinner          = "lag_winner"
    }
}

// MARK: - Service

enum BilliardsScanService {

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let model    = "claude-haiku-4-5-20251001"
    private static let prompt   = """
        This is a photo of an APA (American Poolplayers Association) match scorecard or \
        screenshot from the APA app. Extract the following fields and return JSON only, no explanation. \
        \
        CRITICAL DISTINCTION — two different "points" values appear for every player: \
        (A) TEAM POINTS — a small integer (0, 2, 4, 6, 8, 10, etc.) awarded for the match result. \
            Shown as "18 Points", "2 Points", "0 Points", etc. as a standalone label. \
            This goes in player1_team_points / player2_team_points. \
        (B) GAME SCORE — for 9-Ball, shown as "X/Y Ball Points" (e.g. "39/38 Ball Points") where \
            X is the accumulated ball points and Y is the points needed to win. \
            X goes in player1_score / player2_score and Y goes in player1_needed / player2_needed. \
        Do NOT put the team points value (A) into the score field. \
        \
        For 8-Ball: each player has a row of small boxes. Count the number of boxes that are \
        filled/checked/marked — that is player score (games won). The games needed to win is \
        printed separately as a number near the player's name or skill level. \
        For 9-Ball: read the "X/Y Ball Points" fraction — X = score, Y = needed. \
        \
        Fields to extract: \
        format ("8-Ball" or "9-Ball"), \
        player1_name (string — left or top player), \
        player1_sl (int — skill level, the shield icon number), \
        player1_score (int — GAME score only: games WON for 8-ball, ball points EARNED for 9-ball), \
        player1_needed (int — games or ball points NEEDED to win), \
        player1_team_points (int — team points awarded, e.g. 18 or 2 — the standalone "X Points" label), \
        player2_name (string — right or bottom player), \
        player2_sl (int), \
        player2_score (int), \
        player2_needed (int), \
        player2_team_points (int — team points awarded), \
        innings (int or null — labeled "Innings"), \
        winner ("player1" or "player2" — whoever reached their needed score, or null), \
        lag_winner ("player1" or "player2" or null — player with "LAG" badge or "Lag" label). \
        If a field is not visible, use null.
        """

    /// Sends `image` to Claude and returns extracted APA scorecard stats.
    static func scan(image: UIImage) async throws -> BilliardsScanResult {
        guard let jpeg = image.jpegData(compressionQuality: 0.8) else {
            throw BilliardsScanError.imageEncodingFailed
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
            throw BilliardsScanError.apiError(detail)
        }

        let envelope = try JSONDecoder().decode(BilliardsClaudeEnvelope.self, from: data)
        guard let text = envelope.content.first(where: { $0.type == "text" })?.text else {
            throw BilliardsScanError.noContent
        }

        let jsonString = stripCodeFence(text)
        guard let jsonData = jsonString.data(using: .utf8) else {
            throw BilliardsScanError.parseError("Response not UTF-8")
        }

        return try JSONDecoder().decode(BilliardsScanResult.self, from: jsonData)
    }

    // MARK: - Private helpers

    private static func stripCodeFence(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix("```") else { return s }
        let lines = s.components(separatedBy: "\n")
        return lines.dropFirst().dropLast()
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Private response envelope

private struct BilliardsClaudeEnvelope: Decodable {
    let content: [BilliardsClaudeBlock]
}

private struct BilliardsClaudeBlock: Decodable {
    let type: String
    let text: String
}

// MARK: - Errors

enum BilliardsScanError: LocalizedError {
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
