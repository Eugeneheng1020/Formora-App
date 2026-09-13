import Foundation

/// Tokens from a browser sign-in; kept in the Keychain as JSON (`<server id>/oauth`).
struct MCPOAuthCredential: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    var clientID: String
    var tokenEndpoint: String
    var resource: String?

    /// A minute's margin so a token doesn't expire mid-request.
    func isExpired(now: Date = .now) -> Bool {
        expiresAt.map { $0.addingTimeInterval(-60) <= now } ?? false
    }
}

struct OAuthServerMetadata: Equatable, Sendable {
    var authorizationEndpoint: String
    var tokenEndpoint: String
    var registrationEndpoint: String?
}

enum MCPOAuthError: Error, Equatable, Sendable {
    /// `notAllowed`: registration answered 401/403 — the service admits only clients it approved (Figma, 2026-09-13, D91).
    case discovery(String), registration(String), notAllowed, denied(String), stateMismatch, token(String)

    var message: String {
        switch self {
        case .discovery(let detail): "找不到这个服务的登录地址：\(detail)"
        case .registration(let detail): "没能向服务注册 Formora：\(detail)"
        case .notAllowed: "这个服务只让它认可的应用用浏览器登录，Formora 不在它的名单上，所以没有打开浏览器"
        case .denied(let reason): "登录没有完成：\(reason)"
        case .stateMismatch: "登录回跳和发出的请求对不上，已拒绝"
        case .token(let detail): "没能换到令牌：\(detail)"
        }
    }
}

/// The MCP browser sign-in (old app 2026-09-07; omp `oauth-discovery.ts` / `oauth-flow.ts`, codex
/// `rmcp-client`): RFC 9728 protected-resource metadata → RFC 8414 / OpenID metadata (falling back to
/// `/authorize` `/token` `/register`) → RFC 7591 dynamic registration (public client, no secret) → PKCE S256
/// with `state` and the RFC 8707 `resource` → token, refreshed when it expires.
struct MCPOAuth: Sendable {
    typealias HTTP = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    static let live: HTTP = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    let http: HTTP

    init(http: @escaping HTTP = MCPOAuth.live) {
        self.http = http
    }

    // MARK: Discovery

    struct Discovery: Equatable, Sendable {
        var metadata: OAuthServerMetadata
        /// RFC 8707: what the token is for.
        var resource: String
        /// From the protected-resource metadata, when it lists any.
        var scopes: String?
    }

    func discover(serverURL: String, resourceMetadata: String?) async throws -> Discovery {
        guard let server = URL(string: serverURL), let origin = Self.origin(of: server) else {
            throw MCPOAuthError.discovery("地址无效")
        }
        var resource = serverURL
        var scopes: String?
        var issuers: [URL] = []
        if let url = resourceMetadata.flatMap(URL.init(string:)) ?? Self.protectedResourceMetadataURL(for: server),
           let document = await getJSON(url) {
            if let value = document["resource"]?.string { resource = value }
            issuers = (document["authorization_servers"]?.array ?? []).compactMap { $0.string.flatMap(URL.init(string:)) }
            scopes = document["scopes_supported"]?.array?.compactMap(\.string).joined(separator: " ").nilIfEmpty
        }
        if issuers.isEmpty { issuers = [origin] }
        for issuer in issuers {
            for url in Self.metadataURLs(forIssuer: issuer) {
                guard let document = await getJSON(url),
                      let authorize = document["authorization_endpoint"]?.string,
                      let token = document["token_endpoint"]?.string else { continue }
                return Discovery(metadata: OAuthServerMetadata(authorizationEndpoint: authorize, tokenEndpoint: token,
                                                               registrationEndpoint: document["registration_endpoint"]?.string),
                                 resource: resource, scopes: scopes)
            }
        }
        // MCP 2025-03-26 fallback: the default endpoints at the server's origin.
        let base = origin.absoluteString.hasSuffix("/") ? String(origin.absoluteString.dropLast()) : origin.absoluteString
        return Discovery(metadata: OAuthServerMetadata(authorizationEndpoint: base + "/authorize", tokenEndpoint: base + "/token",
                                                       registrationEndpoint: base + "/register"),
                         resource: resource, scopes: scopes)
    }

    /// RFC 9728 §3.1: the well-known segment goes between the origin and the resource's path.
    static func protectedResourceMetadataURL(for server: URL) -> URL? {
        guard var components = URLComponents(url: server, resolvingAgainstBaseURL: false) else { return nil }
        let path = components.path == "/" ? "" : components.path
        components.path = "/.well-known/oauth-protected-resource" + path
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// RFC 8414 §3.1 and OpenID Discovery, most specific first.
    static func metadataURLs(forIssuer issuer: URL) -> [URL] {
        guard var components = URLComponents(url: issuer, resolvingAgainstBaseURL: false) else { return [] }
        let path = components.path == "/" ? "" : components.path
        components.query = nil
        components.fragment = nil
        var urls: [URL] = []
        for suffix in ["/.well-known/oauth-authorization-server", "/.well-known/openid-configuration"] {
            components.path = suffix + path
            if let url = components.url { urls.append(url) }
        }
        if !path.isEmpty {
            components.path = path + "/.well-known/openid-configuration"
            if let url = components.url { urls.append(url) }
        }
        return urls
    }

    static func origin(of url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false), components.host != nil else { return nil }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }

    // MARK: Registration and authorization

    /// RFC 7591: a public client (no secret) with the loopback redirect.
    func register(_ metadata: OAuthServerMetadata, redirectURI: URL) async throws -> String {
        guard let endpoint = metadata.registrationEndpoint.flatMap(URL.init(string:)) else {
            throw MCPOAuthError.registration("这个服务不支持自动注册客户端")
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = JSONValue.object([
            "client_name": .string("Formora"),
            "redirect_uris": .array([.string(redirectURI.absoluteString)]),
            "grant_types": .array([.string("authorization_code"), .string("refresh_token")]),
            "response_types": .array([.string("code")]),
            "token_endpoint_auth_method": .string("none"),
        ]).encoded()
        let (data, response) = try await http(request)
        if [401, 403].contains(response.statusCode) { throw MCPOAuthError.notAllowed }
        guard (200..<300).contains(response.statusCode), let clientID = JSONValue.parse(data)?["client_id"]?.string else {
            throw MCPOAuthError.registration(Self.errorText(data, status: response.statusCode))
        }
        return clientID
    }

    static func authorizationURL(_ discovery: Discovery, clientID: String, redirectURI: URL, challenge: String, state: String) -> URL? {
        guard var components = URLComponents(string: discovery.metadata.authorizationEndpoint) else { return nil }
        var items = components.queryItems ?? []
        items += [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "resource", value: discovery.resource),
        ]
        if let scopes = discovery.scopes { items.append(URLQueryItem(name: "scope", value: scopes)) }
        components.queryItems = items
        return components.url
    }

    // MARK: Tokens

    func exchange(code: String, verifier: String, redirectURI: URL, clientID: String, discovery: Discovery,
                  now: Date = .now) async throws -> MCPOAuthCredential {
        let (data, status) = try await postForm(discovery.metadata.tokenEndpoint, [
            ("grant_type", "authorization_code"), ("code", code), ("redirect_uri", redirectURI.absoluteString),
            ("client_id", clientID), ("code_verifier", verifier), ("resource", discovery.resource),
        ])
        return try Self.credential(from: data, status: status, clientID: clientID, tokenEndpoint: discovery.metadata.tokenEndpoint,
                                   resource: discovery.resource, previousRefresh: nil, now: now)
    }

    func refresh(_ credential: MCPOAuthCredential, now: Date = .now) async throws -> MCPOAuthCredential {
        guard let refreshToken = credential.refreshToken else { throw MCPOAuthError.token("没有刷新令牌，需要重新登录") }
        var fields = [("grant_type", "refresh_token"), ("refresh_token", refreshToken), ("client_id", credential.clientID)]
        if let resource = credential.resource { fields.append(("resource", resource)) }
        let (data, status) = try await postForm(credential.tokenEndpoint, fields)
        return try Self.credential(from: data, status: status, clientID: credential.clientID, tokenEndpoint: credential.tokenEndpoint,
                                   resource: credential.resource, previousRefresh: refreshToken, now: now)
    }

    static func credential(from data: Data, status: Int, clientID: String, tokenEndpoint: String, resource: String?,
                           previousRefresh: String?, now: Date) throws -> MCPOAuthCredential {
        guard (200..<300).contains(status), let json = JSONValue.parse(data), let access = json["access_token"]?.string else {
            throw MCPOAuthError.token(errorText(data, status: status))
        }
        return MCPOAuthCredential(accessToken: access, refreshToken: json["refresh_token"]?.string ?? previousRefresh,
                                  expiresAt: json["expires_in"]?.int.map { now.addingTimeInterval(TimeInterval($0)) },
                                  clientID: clientID, tokenEndpoint: tokenEndpoint, resource: resource)
    }

    /// `application/x-www-form-urlencoded`, unreserved characters only left as they are.
    static func formBody(_ fields: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encode = { (text: String) in text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text }
        return Data(fields.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&").utf8)
    }

    private func postForm(_ endpoint: String, _ fields: [(String, String)]) async throws -> (Data, Int) {
        guard let url = URL(string: endpoint) else { throw MCPOAuthError.token("令牌地址无效") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Self.formBody(fields)
        let (data, response) = try await http(request)
        return (data, response.statusCode)
    }

    private func getJSON(_ url: URL) async -> JSONValue? {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await http(request), (200..<300).contains(response.statusCode) else { return nil }
        return JSONValue.parse(data)
    }

    static func errorText(_ data: Data, status: Int) -> String {
        let json = JSONValue.parse(data)
        let text = json?["error_description"]?.string ?? json?["error"]?.string ?? String(data: data, encoding: .utf8) ?? ""
        return text.isEmpty ? "服务返回 \(status)" : String(text.prefix(200))
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
