import Foundation
import UIKit

enum PhotoType: String, CaseIterable {
    case place = "place"
    case receipt = "receipt"
    case document = "document"

    var label: String {
        switch self {
        case .place: return "Place Photo"
        case .receipt: return "Receipt"
        case .document: return "Document"
        }
    }

    var emoji: String {
        switch self {
        case .place: return "📷"
        case .receipt: return "🧾"
        case .document: return "📄"
        }
    }
}

class NASService: NSObject {
    static let shared = NASService()

    let nasIP = "100.82.150.100"
    let port = 5006
    let basePath = "/Photos/Trace"
    let username = "David"

    var password: String {
        get { UserDefaults.standard.string(forKey: "nas_password") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "nas_password") }
    }

    private lazy var session: URLSession = {
        URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }()

    func upload(_ image: UIImage, filename: String) async throws -> String {
        guard let data = image.jpegData(compressionQuality: 0.85) else {
            throw NASError.encodingFailed
        }
        let urlString = "https://\(nasIP):\(port)\(basePath)/\(filename)"
        guard let url = URL(string: urlString) else { throw NASError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        let credentials = Data("\(username):\(password)".utf8).base64EncodedString()
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        let (_, response) = try await session.upload(for: request, from: data)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) || http.statusCode == 201 else {
            throw NASError.uploadFailed((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return "https://\(nasIP):\(port)\(basePath)/\(filename)"
    }
}

extension NASService: URLSessionDelegate {
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.host == nasIP,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

enum NASError: LocalizedError {
    case encodingFailed, invalidURL, uploadFailed(Int)
    var errorDescription: String? {
        switch self {
        case .encodingFailed: return "Failed to encode image."
        case .invalidURL: return "Invalid NAS URL."
        case .uploadFailed(let code): return "NAS upload failed (HTTP \(code)). Is Tailscale running?"
        }
    }
}
