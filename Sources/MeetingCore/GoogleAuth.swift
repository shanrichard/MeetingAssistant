import Foundation
import CryptoKit

/// The organization's desktop OAuth client, injected into release builds by the GCP administrator.
/// A desktop client secret is not confidential to Google; it is still kept out of the public repository.
public struct GoogleOAuthConfiguration: Equatable, Sendable {
    public static let clientIDKey = "GoogleOAuthClientID"
    public static let clientSecretKey = "GoogleOAuthClientSecret"
    public var clientID: String
    public var clientSecret: String
    public init(clientID: String, clientSecret: String) { self.clientID = clientID; self.clientSecret = clientSecret }
    public init?(info: [String: Any]?) {
        guard let id = (info?[Self.clientIDKey] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              id.hasSuffix(".apps.googleusercontent.com"),
              let secret = (info?[Self.clientSecretKey] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !secret.isEmpty else { return nil }
        self.init(clientID: id, clientSecret: secret)
    }
}

public enum GoogleScope {
    public static let identity = ["openid", "email"]
    public static let calendar = "https://www.googleapis.com/auth/calendar.events.readonly"
    public static let mail = "https://www.googleapis.com/auth/gmail.readonly"
    /// Requested on every connection; Google keeps earlier grants through include_granted_scopes.
    public static let all = identity + [calendar, mail]
}

public enum GoogleError: LocalizedError, Equatable {
    case notConfigured, notConnected, reconnectRequired, missingRefreshToken, stateMismatch, timedOut, mailNotAuthorized
    case denied(String), server(String), invalidResponse
    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "这个版本没有配置组织的 Google 客户端。请使用公司发布的版本，或由管理员按文档配置后重新构建。"
        case .notConnected: return "尚未连接 Google 账号。"
        case .reconnectRequired: return "Google 授权已失效或被撤销，请在设置中重新连接 Google 账号。"
        case .missingRefreshToken: return "Google 没有返回长期授权。请在 Google 账号权限页移除 Meeting Assistant 后重新连接。"
        case .stateMismatch: return "收到的授权回调与本次请求不一致，已忽略。请重新连接。"
        case .timedOut: return "等待浏览器授权超时，请重新连接。"
        case .mailNotAuthorized: return "尚未授权读取邮件。重新连接 Google 账号并允许读取邮件后，会前说明会参考相关邮件。"
        case .denied(let reason): return reason == "access_denied" ? "你在浏览器中取消了授权。" : "Google 拒绝了授权：\(reason)"
        case .server(let message): return "Google 请求失败：\(message)"
        case .invalidResponse: return "Google 返回了无法识别的响应。"
        }
    }
}

public struct PKCE: Sendable {
    public let verifier: String
    public init(verifier: String = PKCE.randomVerifier()) { self.verifier = verifier }
    public var challenge: String { Self.challenge(for: verifier) }
    public static func randomVerifier() -> String {
        base64URL(Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }))
    }
    public static func challenge(for verifier: String) -> String { base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Stored in the Keychain as one item; never written to preferences, meeting files or logs.
public struct GoogleAccount: Codable, Equatable, Sendable {
    public var email: String
    public var refreshToken: String
    public var scopes: [String]
    public init(email: String, refreshToken: String, scopes: [String]) {
        self.email = email; self.refreshToken = refreshToken; self.scopes = scopes
    }
}

public struct GoogleAccessToken: Sendable {
    public var value: String
    public var expiresAt: Date
    /// Refresh a minute early so a request does not race the expiry.
    public func isUsable(at now: Date) -> Bool { now < expiresAt.addingTimeInterval(-60) }
}

public final class GoogleAuthClient: @unchecked Sendable {
    public static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    public static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    public static let revokeEndpoint = URL(string: "https://oauth2.googleapis.com/revoke")!
    public let configuration: GoogleOAuthConfiguration
    private let session: URLSession
    public init(configuration: GoogleOAuthConfiguration, session: URLSession? = nil) {
        self.configuration = configuration
        self.session = session ?? GoogleAuthClient.makeSession()
    }
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration, delegate: RejectRedirects(), delegateQueue: nil)
    }

    public func authorizationURL(redirectURI: URL, state: String, pkce: PKCE, scopes: [String], loginHint: String? = nil) -> URL {
        var components = URLComponents(url: Self.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "client_id", value: configuration.clientID),
                     URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
                     URLQueryItem(name: "response_type", value: "code"),
                     URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
                     URLQueryItem(name: "state", value: state),
                     URLQueryItem(name: "code_challenge", value: pkce.challenge),
                     URLQueryItem(name: "code_challenge_method", value: "S256"),
                     URLQueryItem(name: "access_type", value: "offline"),
                     // Google only returns a refresh token on consent; ask every time so reconnecting always yields one.
                     URLQueryItem(name: "prompt", value: "consent select_account"),
                     URLQueryItem(name: "include_granted_scopes", value: "true")]
        if let loginHint { items.append(URLQueryItem(name: "login_hint", value: loginHint)) }
        components.queryItems = items
        return components.url!
    }

    public func exchange(code: String, redirectURI: URL, pkce: PKCE, now: Date = Date()) async throws -> (GoogleAccount, GoogleAccessToken) {
        let object = try await token(["grant_type": "authorization_code", "code": code,
                                      "redirect_uri": redirectURI.absoluteString, "code_verifier": pkce.verifier])
        guard let refreshToken = object["refresh_token"] as? String, !refreshToken.isEmpty else { throw GoogleError.missingRefreshToken }
        guard let idToken = object["id_token"] as? String, let email = Self.email(fromIDToken: idToken) else { throw GoogleError.invalidResponse }
        let scopes = (object["scope"] as? String ?? "").split(separator: " ").map(String.init)
        return (GoogleAccount(email: email, refreshToken: refreshToken, scopes: scopes), try Self.accessToken(object, now: now))
    }

    public func refresh(_ account: GoogleAccount, now: Date = Date()) async throws -> GoogleAccessToken {
        try Self.accessToken(try await token(["grant_type": "refresh_token", "refresh_token": account.refreshToken]), now: now)
    }

    /// Best effort: disconnecting locally must not depend on the network.
    public func revoke(_ account: GoogleAccount) async {
        var request = URLRequest(url: Self.revokeEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.form(["token": account.refreshToken])
        _ = try? await session.data(for: request)
    }

    private func token(_ parameters: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: Self.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let all = parameters.merging(["client_id": configuration.clientID, "client_secret": configuration.clientSecret]) { $1 }
        request.httpBody = Self.form(all)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GoogleError.invalidResponse }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(http.statusCode) else {
            let code = object["error"] as? String ?? "HTTP \(http.statusCode)"
            if code == "invalid_grant" { throw GoogleError.reconnectRequired }
            // Error text from Google never contains our secrets, but scrub anyway before it reaches the UI.
            var message = code
            for secret in [configuration.clientSecret, parameters["refresh_token"], parameters["code"]].compactMap({ $0 }) where !secret.isEmpty {
                message = message.replacingOccurrences(of: secret, with: "[redacted]")
            }
            throw GoogleError.server(String(message.prefix(200)))
        }
        return object
    }

    static func accessToken(_ object: [String: Any], now: Date) throws -> GoogleAccessToken {
        guard let value = object["access_token"] as? String, !value.isEmpty else { throw GoogleError.invalidResponse }
        let lifetime = (object["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        return GoogleAccessToken(value: value, expiresAt: now.addingTimeInterval(lifetime))
    }

    static func form(_ parameters: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
        return Data(parameters.sorted { $0.key < $1.key }.map { key, value in
            key + "=" + (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        }.joined(separator: "&").utf8)
    }

    /// The ID token comes straight from Google's token endpoint over TLS, so its claims are read without re-verifying the signature.
    public static func email(fromIDToken token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let email = claims["email"] as? String, !email.isEmpty else { return nil }
        return email.lowercased()
    }
}

/// Holds the connected account and a short-lived access token for API calls.
public actor GoogleSession {
    private let auth: GoogleAuthClient
    private let storage: CredentialStorage
    private var account: GoogleAccount?
    private var token: GoogleAccessToken?
    public init(auth: GoogleAuthClient, storage: CredentialStorage) { self.auth = auth; self.storage = storage }

    public func load() throws -> GoogleAccount? {
        if let account { return account }
        guard let text = try storage.read() else { return nil }
        guard let account = try? JSONDecoder().decode(GoogleAccount.self, from: Data(text.utf8)) else { throw GoogleError.reconnectRequired }
        self.account = account
        return account
    }

    /// Saves before use: an authorization that cannot be stored is not used for requests.
    public func connect(code: String, redirectURI: URL, pkce: PKCE, now: Date = Date()) async throws -> GoogleAccount {
        let (account, token) = try await auth.exchange(code: code, redirectURI: redirectURI, pkce: pkce, now: now)
        let previous = self.account
        try storage.save(String(decoding: try JSONEncoder().encode(account), as: UTF8.self))
        self.account = account; self.token = token
        if let previous, previous.refreshToken != account.refreshToken { await auth.revoke(previous) }
        return account
    }

    public func accessToken(now: Date = Date()) async throws -> String {
        if let token, token.isUsable(at: now) { return token.value }
        guard let account = try load() else { throw GoogleError.notConnected }
        let fresh = try await auth.refresh(account, now: now)
        token = fresh
        return fresh.value
    }

    public func scopes() throws -> [String] { try load()?.scopes ?? [] }

    /// Drops the cached access token after the API rejects it, so the next call refreshes.
    public func invalidateAccessToken() { token = nil }

    public func disconnect() async throws {
        let account = try? load()
        try storage.delete()
        self.account = nil; token = nil
        if let account { await auth.revoke(account) }
    }
}
