import Foundation

/// How a provider is reached (7i): a key, or a ChatGPT subscription sign-in.
enum ProviderAccess: Equatable, Sendable {
    case key, chatGPT
}

/// A sign-in under way, shown under its row (7i, U1).
enum SignInProgress: Equatable, Sendable {
    /// The browser is open; the way back is being waited for.
    case waiting
    /// Port 1455 was taken: a code to type on a web page.
    case deviceCode(String)
    case failed(String)
}

/// A signed-in ChatGPT account (7i, U2), kept in the Keychain as JSON.
struct ChatGPTCredential: Codable, Equatable, Sendable {
    var access: String
    var refresh: String
    var expires: Date
    var accountID: String
    var email: String?
    var plan: String?

    /// Refreshed five minutes early, so no request leaves with a token about to lapse.
    func needsRefresh(now: Date = .now) -> Bool { expires.timeIntervalSince(now) < 5 * 60 }

    var summary: String {
        let plan = plan.map { " · " + $0.prefix(1).uppercased() + $0.dropFirst() } ?? ""
        return "已登录 \(email ?? "ChatGPT 账号")\(plan)"
    }

    func encoded() -> String { String(decoding: (try? JSONEncoder().encode(self)) ?? Data(), as: UTF8.self) }

    static func decode(_ text: String) -> ChatGPTCredential? { try? JSONDecoder().decode(Self.self, from: Data(text.utf8)) }
}

/// ChatGPT Plus / Pro sign-in (7i, U1–U3): Codex's public OAuth client — the way OpenAI lets tools use a ChatGPT plan —
/// with PKCE; Formora names itself as the originator, as omp does. Refresh and the device code follow codex and omp.
enum ChatGPTAuth {
    static let providerID = "chatgpt"
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let issuer = "https://auth.openai.com"
    static let scope = "openid profile email offline_access api.connectors.read api.connectors.invoke"
    /// The only way back registered for the client (codex `login/server.rs`).
    static let callbackPort: UInt16 = 1455
    static let callbackPath = "/auth/callback"
    static let deviceURL = URL(string: "https://auth.openai.com/codex/device")!
    static let deviceRedirect = "https://auth.openai.com/deviceauth/callback"
    static let baseURL = "https://chatgpt.com/backend-api"
    static let responsesPath = "/codex/responses"
    static let originator = "formora"
    static let accountHeader = "chatgpt-account-id"
    /// The backend wants instructions on every request.
    static let defaultInstructions = "You are a helpful assistant."

    struct Problem: Error, Equatable {
        let message: String
    }

    struct DeviceCode: Equatable, Sendable {
        let authID: String
        let userCode: String
        let interval: TimeInterval
    }

    static func authorizationURL(challenge: String, state: String, redirect: URL) -> URL {
        var components = URLComponents(string: issuer + "/oauth/authorize")!
        components.queryItems = [
            ("response_type", "code"), ("client_id", clientID), ("redirect_uri", redirect.absoluteString), ("scope", scope),
            ("code_challenge", challenge), ("code_challenge_method", "S256"), ("state", state),
            ("id_token_add_organizations", "true"), ("codex_cli_simplified_flow", "true"), ("originator", originator),
        ].map { URLQueryItem(name: $0.0, value: $0.1) }
        return components.url!
    }

    /// A request's own headers (U3): the Responses beta, who is calling, a session for the backend's cache.
    static func addHeaders(_ request: inout URLRequest) {
        request.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
        request.setValue(originator, forHTTPHeaderField: "originator")
        request.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "session_id")
    }

    // MARK: Tokens

    static func exchange(code: String, verifier: String, redirect: String, transport: ProviderClient.Transport) async throws -> ChatGPTCredential {
        let (data, status) = try await post(issuer + "/oauth/token", form: [
            ("grant_type", "authorization_code"), ("client_id", clientID), ("code", code), ("code_verifier", verifier),
            ("redirect_uri", redirect),
        ], transport: transport)
        return try credential(from: data, status: status, previous: nil)
    }

    static func refresh(_ credential: ChatGPTCredential, transport: ProviderClient.Transport) async throws -> ChatGPTCredential {
        let (data, status) = try await post(issuer + "/oauth/token", json: [
            "grant_type": "refresh_token", "client_id": clientID, "refresh_token": credential.refresh, "scope": "openid profile email",
        ], transport: transport)
        return try self.credential(from: data, status: status, previous: credential)
    }

    /// The device code (codex `device_code_auth.rs`): a code the user types at auth.openai.com/codex/device.
    static func requestDeviceCode(transport: ProviderClient.Transport) async throws -> DeviceCode {
        let (data, status) = try await post(issuer + "/api/accounts/deviceauth/usercode", json: ["client_id": clientID], transport: transport)
        guard status == 200, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let authID = object["device_auth_id"] as? String, let code = object["user_code"] as? String else {
            throw Problem(message: "拿不到登录码（\(status)）")
        }
        let interval = (object["interval"] as? Double) ?? Double(object["interval"] as? String ?? "") ?? 5
        return DeviceCode(authID: authID, userCode: code, interval: max(interval, 2))
    }

    /// Asks every few seconds until the code is used; `nil` when `keepGoing` says stop. At most ten minutes.
    static func waitForDevice(_ device: DeviceCode, transport: ProviderClient.Transport,
                              keepGoing: @MainActor @Sendable () -> Bool) async throws -> ChatGPTCredential? {
        let deadline = Date.now.addingTimeInterval(600)
        while Date.now < deadline {
            try? await Task.sleep(for: .seconds(device.interval))
            guard await keepGoing() else { return nil }
            let (data, status) = try await post(issuer + "/api/accounts/deviceauth/token",
                                                json: ["device_auth_id": device.authID, "user_code": device.userCode], transport: transport)
            if status == 403 || status == 404 { continue }
            guard status == 200, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let code = object["authorization_code"] as? String, let verifier = object["code_verifier"] as? String else {
                throw Problem(message: "登录码没能换成登录（\(status)）")
            }
            return try await exchange(code: code, verifier: verifier, redirect: deviceRedirect, transport: transport)
        }
        throw Problem(message: "十分钟内没有完成登录")
    }

    // MARK: The tokens' claims

    /// The account (the plan's workspace), email and plan, from the access token or else the id token.
    static func profile(access: String, idToken: String?) -> (accountID: String?, email: String?, plan: String?) {
        let claims = [self.claims(access), idToken.flatMap { self.claims($0) }].compactMap { $0 }
        func auth(_ key: String) -> String? {
            claims.lazy.compactMap { ($0["https://api.openai.com/auth"] as? [String: Any])?[key] as? String }.first { !$0.isEmpty }
        }
        let email = claims.lazy.compactMap { ($0["https://api.openai.com/profile"] as? [String: Any])?["email"] as? String ?? $0["email"] as? String }
            .first { !$0.isEmpty }
        return (auth("chatgpt_account_id"), email?.lowercased(), auth("chatgpt_plan_type")?.lowercased())
    }

    static func claims(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func message(_ error: Error) -> String {
        if let problem = error as? Problem { return problem.message }
        return error.localizedDescription
    }

    // MARK: Wire

    private static func credential(from data: Data, status: Int, previous: ChatGPTCredential?) throws -> ChatGPTCredential {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard status == 200, let access = object["access_token"] as? String else {
            let reason = [object["error"] as? String, object["error_description"] as? String].compactMap { $0 }.joined(separator: "：")
            throw Problem(message: "OpenAI 没有同意（\(status)\(reason.isEmpty ? "" : "，\(reason)")）")
        }
        let profile = profile(access: access, idToken: object["id_token"] as? String)
        guard let accountID = profile.accountID ?? previous?.accountID else {
            throw Problem(message: "登录结果里没有 ChatGPT 账号，这个账号可能没有 Plus / Pro 订阅")
        }
        let lifetime = (object["expires_in"] as? Double) ?? 3600
        return ChatGPTCredential(access: access, refresh: object["refresh_token"] as? String ?? previous?.refresh ?? "",
                                 expires: .now.addingTimeInterval(lifetime), accountID: accountID,
                                 email: profile.email ?? previous?.email, plan: profile.plan ?? previous?.plan)
    }

    private static func post(_ address: String, form: [(String, String)], transport: ProviderClient.Transport) async throws -> (Data, Int) {
        var request = URLRequest(url: URL(string: address)!, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = MCPOAuth.formBody(form)
        let (data, response) = try await transport(request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private static func post(_ address: String, json: [String: String], transport: ProviderClient.Transport) async throws -> (Data, Int) {
        var request = URLRequest(url: URL(string: address)!, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
        let (data, response) = try await transport(request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
