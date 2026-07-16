import Foundation

/// Google Drive REST v3 client for the session upload: folder tree, multipart file
/// upload, and anyone-with-link sharing. Works with the `drive.file` scope (only
/// files this app creates are visible to it).
struct DriveUploader {
    let accessToken: String

    private var authHeader: [String: String] {
        ["Authorization": "Bearer \(accessToken)"]
    }

    /// Finds a folder by name under `parentID` (or root), creating it if missing.
    func ensureFolder(name: String, parentID: String?) async throws -> String {
        if let existing = try await findFolder(name: name, parentID: parentID) {
            return existing
        }
        return try await createFolder(name: name, parentID: parentID)
    }

    func createFolder(name: String, parentID: String?) async throws -> String {
        var metadata: [String: Any] = [
            "name": name,
            "mimeType": "application/vnd.google-apps.folder"
        ]
        if let parentID { metadata["parents"] = [parentID] }

        var request = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authHeader.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.httpBody = try JSONSerialization.data(withJSONObject: metadata)

        let json = try await send(request)
        guard let id = json["id"] as? String else { throw DriveError.badResponse(json) }
        return id
    }

    private func findFolder(name: String, parentID: String?) async throws -> String? {
        let escaped = name.replacingOccurrences(of: "'", with: "\\'")
        var q = "name = '\(escaped)' and mimeType = 'application/vnd.google-apps.folder' and trashed = false"
        if let parentID { q += " and '\(parentID)' in parents" }
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        components.queryItems = [
            .init(name: "q", value: q),
            .init(name: "fields", value: "files(id,name)")
        ]
        var request = URLRequest(url: components.url!)
        authHeader.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let json = try await send(request)
        return (json["files"] as? [[String: Any]])?.first?["id"] as? String
    }

    /// Multipart upload of one file into a folder.
    func upload(fileURL: URL, as name: String, mimeType: String, parentID: String) async throws {
        let fileData = try Data(contentsOf: fileURL)
        let metadata: [String: Any] = ["name": name, "parents": [parentID]]
        let metadataData = try JSONSerialization.data(withJSONObject: metadata)

        let boundary = "photobooth-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".data(using: .utf8)!)
        body.append(metadataData)
        body.append("\r\n--\(boundary)\r\nContent-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--".data(using: .utf8)!)

        var request = URLRequest(url: URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart")!)
        request.httpMethod = "POST"
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        authHeader.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.httpBody = body

        let json = try await send(request)
        guard json["id"] is String else { throw DriveError.badResponse(json) }
    }

    /// Makes a file/folder readable by anyone with the link.
    func makePublic(fileID: String) async throws {
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files/\(fileID)/permissions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authHeader.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["role": "reader", "type": "anyone"])
        _ = try await send(request)
    }

    static func folderLink(id: String) -> URL {
        URL(string: "https://drive.google.com/drive/folders/\(id)")!
    }

    private func send(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw DriveError.httpError(http.statusCode, json)
        }
        return json
    }

    enum DriveError: LocalizedError {
        case badResponse([String: Any])
        case httpError(Int, [String: Any])

        var errorDescription: String? {
            switch self {
            case .badResponse(let json): "Unexpected Drive response: \(json)"
            case .httpError(let code, let json): "Drive error \(code): \((json["error"] as? [String: Any])?["message"] as? String ?? "\(json)")"
            }
        }
    }
}
