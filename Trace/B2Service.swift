import Foundation
import UIKit
import CryptoKit

class B2Service {
    static let shared = B2Service()

    private let bucketID = "03304fd347b3d12a90ea0d1b"
    private let bucketName = "trace-place-photos"

    var keyID: String {
        get { UserDefaults.standard.string(forKey: "b2_key_id") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "b2_key_id") }
    }

    var applicationKey: String {
        get { UserDefaults.standard.string(forKey: "b2_application_key") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "b2_application_key") }
    }

    func upload(_ image: UIImage, filename: String) async throws -> String {
        guard !keyID.isEmpty, !applicationKey.isEmpty else {
            throw B2Error.noCredentials
        }
        guard let data = image.jpegData(compressionQuality: 0.85) else {
            throw B2Error.encodingFailed
        }

        let (authToken, apiURL, downloadURL) = try await authorize()
        let (uploadURL, uploadAuthToken) = try await getUploadURL(apiURL: apiURL, authToken: authToken)

        let sha1 = Insecure.SHA1.hash(data: data)
            .map { String(format: "%02x", $0) }.joined()

        let encodedFilename = filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filename

        var request = URLRequest(url: URL(string: uploadURL)!)
        request.httpMethod = "POST"
        request.setValue(uploadAuthToken, forHTTPHeaderField: "Authorization")
        request.setValue(encodedFilename, forHTTPHeaderField: "X-Bz-File-Name")
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.setValue("\(data.count)", forHTTPHeaderField: "Content-Length")
        request.setValue(sha1, forHTTPHeaderField: "X-Bz-Content-Sha1")

        let (_, response) = try await URLSession.shared.upload(for: request, from: data)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw B2Error.uploadFailed(code)
        }

        return "\(downloadURL)/file/\(bucketName)/\(filename)"
    }

    private func authorize() async throws -> (authToken: String, apiURL: String, downloadURL: String) {
        let credentials = Data("\(keyID):\(applicationKey)".utf8).base64EncodedString()
        var request = URLRequest(url: URL(string: "https://api.backblazeb2.com/b2api/v3/b2_authorize_account")!)
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw B2Error.authFailed
        }
        let result = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        guard let authToken = result["authorizationToken"] as? String,
              let apiInfo = result["apiInfo"] as? [String: Any],
              let storageApi = apiInfo["storageApi"] as? [String: Any],
              let apiURL = storageApi["apiUrl"] as? String,
              let downloadURL = storageApi["downloadUrl"] as? String else {
            throw B2Error.authFailed
        }
        return (authToken, apiURL, downloadURL)
    }

    private func getUploadURL(apiURL: String, authToken: String) async throws -> (uploadURL: String, authToken: String) {
        var request = URLRequest(url: URL(string: "\(apiURL)/b2api/v3/b2_get_upload_url")!)
        request.httpMethod = "POST"
        request.setValue(authToken, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["bucketId": bucketID])

        let (data, _) = try await URLSession.shared.data(for: request)
        let result = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        guard let uploadURL = result["uploadUrl"] as? String,
              let uploadAuthToken = result["authorizationToken"] as? String else {
            throw B2Error.getUploadURLFailed
        }
        return (uploadURL, uploadAuthToken)
    }
}

enum B2Error: LocalizedError {
    case noCredentials, encodingFailed, authFailed, getUploadURLFailed, uploadFailed(Int)

    var errorDescription: String? {
        switch self {
        case .noCredentials: return "B2 credentials not set — open Settings to add them."
        case .encodingFailed: return "Failed to encode image."
        case .authFailed: return "B2 authorization failed — check credentials in Settings."
        case .getUploadURLFailed: return "Failed to get B2 upload slot."
        case .uploadFailed(let code): return "B2 upload failed (HTTP \(code))."
        }
    }
}

