import Foundation
import AppKit
import Network
import CryptoKit
import Security

/// Google OAuth for a native desktop app: opens the browser, catches the redirect on a
/// localhost loopback listener (PKCE), and keeps tokens in the Keychain. Same flow the
/// memoribox Electron app uses, without any SDK.
@Observable
@MainActor
final class GoogleAuthService {
    static let shared = GoogleAuthService()

    private static let scope = "https://www.googleapis.com/auth/drive.file"

    /// Settings-screen override first, then the credentials baked in at build time
    /// (Secrets.swift), so a distributed .app works with no setup.
    var clientID: String {
        get {
            let stored = UserDefaults.standard.string(forKey: "gdrive.clientID") ?? ""
            return stored.isEmpty ? Secrets.gdriveClientID : stored
        }
        set { UserDefaults.standard.set(newValue, forKey: "gdrive.clientID") }
    }
    var clientSecret: String {
        get {
            let stored = UserDefaults.standard.string(forKey: "gdrive.clientSecret") ?? ""
            return stored.isEmpty ? Secrets.gdriveClientSecret : stored
        }
        set { UserDefaults.standard.set(newValue, forKey: "gdrive.clientSecret") }
    }

    /// Top-level Drive folder every event/session lives under.
    var masterFolderName: String {
        get {
            let stored = UserDefaults.standard.string(forKey: "gdrive.masterFolder") ?? ""
            return stored.isEmpty ? "Photobooth" : stored
        }
        set { UserDefaults.standard.set(newValue, forKey: "gdrive.masterFolder") }
    }

    private(set) var isSignedIn: Bool = KeychainStore.load(key: "refreshToken") != nil
    var statusMessage: String?

    private var accessToken: String?
    private var accessTokenExpiry: Date?

    // MARK: Sign in / out

    func signIn() async throws {
        guard !clientID.isEmpty, !clientSecret.isEmpty else {
            throw AuthError.missingClient
        }
        let verifier = Self.randomURLSafeString(length: 64)
        let challenge = Self.codeChallenge(for: verifier)

        let server = LoopbackServer()
        let port = try await server.start()
        let redirectURI = "http://127.0.0.1:\(port)"

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: Self.scope),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent")
        ]
        NSWorkspace.shared.open(components.url!)

        let code = try await server.waitForCode()
        server.stop()
        try await exchangeCode(code, verifier: verifier, redirectURI: redirectURI)
        isSignedIn = true
        statusMessage = nil
    }

    func signOut() {
        KeychainStore.delete(key: "refreshToken")
        accessToken = nil
        accessTokenExpiry = nil
        isSignedIn = false
    }

    /// Returns a valid access token, refreshing it if expired.
    func validAccessToken() async throws -> String {
        if let token = accessToken, let expiry = accessTokenExpiry, expiry > Date.now.addingTimeInterval(60) {
            return token
        }
        guard let refreshToken = KeychainStore.load(key: "refreshToken") else {
            throw AuthError.notSignedIn
        }
        let body = [
            "client_id": clientID,
            "client_secret": clientSecret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token"
        ]
        let response = try await postForm(url: URL(string: "https://oauth2.googleapis.com/token")!, fields: body)
        guard let token = response["access_token"] as? String else {
            throw AuthError.tokenExchangeFailed(String(describing: response))
        }
        accessToken = token
        accessTokenExpiry = Date.now.addingTimeInterval(TimeInterval(response["expires_in"] as? Int ?? 3600))
        return token
    }

    // MARK: Internals

    private func exchangeCode(_ code: String, verifier: String, redirectURI: String) async throws {
        let body = [
            "client_id": clientID,
            "client_secret": clientSecret,
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code"
        ]
        let response = try await postForm(url: URL(string: "https://oauth2.googleapis.com/token")!, fields: body)
        guard let token = response["access_token"] as? String else {
            throw AuthError.tokenExchangeFailed(String(describing: response))
        }
        accessToken = token
        accessTokenExpiry = Date.now.addingTimeInterval(TimeInterval(response["expires_in"] as? Int ?? 3600))
        if let refresh = response["refresh_token"] as? String {
            KeychainStore.save(refresh, key: "refreshToken")
        }
    }

    private func postForm(url: URL, fields: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = fields
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: request)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private static func randomURLSafeString(length: Int) -> String {
        let charset = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        return String((0..<length).map { _ in charset.randomElement()! })
    }

    private static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    enum AuthError: LocalizedError {
        case missingClient
        case notSignedIn
        case tokenExchangeFailed(String)
        case loopbackFailed

        var errorDescription: String? {
            switch self {
            case .missingClient: "Enter your Google OAuth Client ID and Secret first (Dashboard → Google Drive settings)."
            case .notSignedIn: "Not signed in to Google Drive."
            case .tokenExchangeFailed(let detail): "Google sign-in failed: \(detail)"
            case .loopbackFailed: "Could not start the local sign-in listener."
            }
        }
    }
}

// MARK: - Loopback HTTP listener (catches the OAuth redirect)

@MainActor
private final class LoopbackServer {
    private var listener: NWListener?
    private var codeContinuation: CheckedContinuation<String, Error>?

    func start() async throws -> UInt16 {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
                let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let html = "<html><body style='font-family:sans-serif;text-align:center;padding-top:80px'><h2>✅ Signed in — you can close this tab and return to the Photobooth app.</h2></body></html>"
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\n\r\n\(html)"
                connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })
                Task { @MainActor [weak self] in
                    self?.handle(request: request)
                }
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue {
                        continuation.resume(returning: port)
                    } else {
                        continuation.resume(throwing: GoogleAuthService.AuthError.loopbackFailed)
                    }
                    listener.stateUpdateHandler = nil
                case .failed:
                    continuation.resume(throwing: GoogleAuthService.AuthError.loopbackFailed)
                    listener.stateUpdateHandler = nil
                default:
                    break
                }
            }
            listener.start(queue: .main)
        }
    }

    func waitForCode() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            codeContinuation = continuation
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(request: String) {
        guard let continuation = codeContinuation else { return }
        // First line looks like: GET /?code=XYZ&scope=... HTTP/1.1
        guard let firstLine = request.components(separatedBy: "\r\n").first,
              let pathPart = firstLine.components(separatedBy: " ").dropFirst().first,
              let components = URLComponents(string: "http://127.0.0.1\(pathPart)") else { return }
        if let code = components.queryItems?.first(where: { $0.name == "code" })?.value {
            codeContinuation = nil
            continuation.resume(returning: code)
        } else if let error = components.queryItems?.first(where: { $0.name == "error" })?.value {
            codeContinuation = nil
            continuation.resume(throwing: GoogleAuthService.AuthError.tokenExchangeFailed(error))
        }
    }
}

// MARK: - Keychain

enum KeychainStore {
    private static let service = "NotulensaApp.GoogleDrive"

    static func save(_ value: String, key: String) {
        delete(key: key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: Data(value.utf8)
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
