import AppKit
import Foundation
import Observation

enum MCPProblem: Error, Equatable, Sendable {
    case nameRequired, nameTaken, badURL, commandRequired
    /// Enabled by this many Agents (spec §8.7 rule 2).
    case inUse(Int)

    var message: String {
        switch self {
        case .nameRequired: "名称不能为空"
        case .nameTaken: "已有同名服务"
        case .badURL: "请输入有效的 HTTP URL"
        case .commandRequired: "命令不能为空"
        case .inUse(let count): "有 \(count) 个 Agent 启用了它，先在对应 Agent 的 MCP 标签里关掉"
        }
    }
}

/// 设置 → MCP (spec §8.4): servers configured once, tested for real, shared by the Agents that are allowed.
/// Configs in `MCPServers.json`; secret headers, environment values and sign-in tokens in the Keychain.
@MainActor
@Observable
final class MCPStore {
    enum Status: Equatable, Sendable {
        case configured, testing, waitingForBrowser, unsupported, disabled
        /// `reason`: why the last sign-in didn't work; `nil` when it just hasn't been done yet.
        case needsSignIn(reason: String?)
        case connected(tools: Int)
        case failed(String)

        var label: String {
            switch self {
            case .configured: "已配置"
            case .testing: "测试中…"
            case .waitingForBrowser: "等浏览器登录"
            case .needsSignIn: "需要登录"
            case .unsupported: "只有官网版能用"
            case .disabled: "已停用"
            case .connected: "已连接"
            case .failed: "连接异常"
            }
        }

        var detail: String? {
            switch self {
            case .connected(let tools): "\(tools) 个工具"
            case .failed(let message): message
            case .needsSignIn(let reason): reason ?? "点「浏览器登录」在浏览器里完成授权"
            case .waitingForBrowser: "在打开的浏览器页面里完成登录，最长等 5 分钟"
            case .unsupported: "它要在本机启动进程，App Store 版的沙盒里跑不了"
            default: nil
            }
        }

        var isConnected: Bool { if case .connected = self { true } else { false } }
    }

    /// What a plain 401 records: nothing tried yet, so the row says how to sign in. Any other message on a
    /// needs-sign-in record is why the sign-in failed, and the row shows that instead (D91).
    static let signInPrompt = "需要在浏览器里登录"
    static let fileName = "MCPServers.json"
    static let baseService = "com.eugenecheng.formora.mcp"

    private(set) var servers: [MCPServerConfig] = []
    /// Only while something is happening: testing or waiting for the browser.
    private(set) var activity: [String: Status] = [:]
    /// How many Agents enable a server; wired to `AgentStore` at launch.
    @ObservationIgnored var usage: (String) -> Int = { _ in 0 }

    @ObservationIgnored private let secrets: SecretStore
    @ObservationIgnored private let client: MCPClient
    @ObservationIgnored private let oauth: MCPOAuth
    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private let openURL: @MainActor (URL) -> Void
    @ObservationIgnored private var resourceMetadata: [String: String] = [:]
    /// The stdio servers running now (9d).
    @ObservationIgnored let stdio = MCPStdioPool()
    /// The folder a stdio server starts in: the open project's (9d, S2), home without one. Set by the app.
    @ObservationIgnored var projectRoot: @MainActor () -> URL? = { nil }

    init(secrets: SecretStore, client: MCPClient = MCPClient(), oauth: MCPOAuth = MCPOAuth(), fileURL: URL?,
         openURL: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.secrets = secrets
        self.client = client
        self.oauth = oauth
        self.fileURL = fileURL
        self.openURL = openURL
        if let fileURL, let data = try? Data(contentsOf: fileURL) {
            servers = (try? JSONDecoder().decode([MCPServerConfig].self, from: data)) ?? []
        }
    }

    func server(_ id: String) -> MCPServerConfig? { servers.first { $0.id == id } }

    func status(of id: String) -> Status {
        guard let server = server(id) else { return .configured }
        if let current = activity[id] { return current }
        if !server.isEnabled { return .disabled }
        if server.isStdio, !MCPBuild.supportsStdio { return .unsupported }
        guard let test = server.lastTest else { return .configured }
        if test.succeeded { return .connected(tools: server.tools.count) }
        if test.needsSignIn == true { return .needsSignIn(reason: test.message == Self.signInPrompt ? nil : test.message) }
        return .failed(test.message ?? "连接失败")
    }

    /// Only enabled servers whose last test connected can be switched on for an Agent (spec §8.4).
    func isUsable(_ id: String) -> Bool { status(of: id).isConnected }

    // MARK: Adding and editing

    func problem(name: String, transport: MCPServerConfig.Transport, editing id: String?) -> MCPProblem? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .nameRequired }
        let normalized = FileSearch.normalize(trimmed)
        if servers.contains(where: { $0.id != id && FileSearch.normalize($0.name) == normalized }) { return .nameTaken }
        switch transport {
        case .http(let url):
            if !ProviderStore.isValidBaseURL(url) { return .badURL }
        case .stdio(let command, _):
            if command.trimmingCharacters(in: .whitespaces).isEmpty { return .commandRequired }
        }
        return nil
    }

    /// Starts as 已配置 — never 已连接 before a real test (spec §8.4).
    @discardableResult
    func add(_ server: MCPServerConfig, secrets values: [String: String]) throws -> String {
        if let problem = problem(name: server.name, transport: server.transport, editing: nil) { throw problem }
        var stored = server
        stored.name = server.name.trimmingCharacters(in: .whitespacesAndNewlines)
        stored.lastTest = nil
        stored.tools = []
        for (name, value) in values { try secrets.write(value, for: account(stored.id, name)) }
        stored.secretNames = Array(Set(stored.secretNames + values.keys)).sorted()
        servers.append(stored)
        persist()
        return stored.id
    }

    /// The manual form's save. New secret values replace old ones; `nil` keeps them. A different endpoint
    /// makes the last test stale.
    func update(_ id: String, name: String, transport: MCPServerConfig.Transport, plainHeaders: [String: String],
                plainEnvironment: [String: String], secretValues: [String: String]?) throws {
        guard let index = servers.firstIndex(where: { $0.id == id }) else { return }
        if let problem = problem(name: name, transport: transport, editing: id) { throw problem }
        var server = servers[index]
        if server.transport != transport {
            server.lastTest = nil
            server.tools = []
        }
        server.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        server.transport = transport
        server.plainHeaders = plainHeaders
        server.plainEnvironment = plainEnvironment
        if let secretValues {
            for old in server.secretNames where secretValues[old] == nil { try? secrets.delete(account(id, old)) }
            for (key, value) in secretValues { try secrets.write(value, for: account(id, key)) }
            server.secretNames = secretValues.keys.sorted()
            if server.auth != .oauth { server.auth = secretValues.keys.sorted().first.map { .header(name: $0) } ?? .none }
        }
        servers[index] = server
        persist()
        // A running stdio process was started from what just changed (9d, S4).
        stdio.stop(id)
    }

    /// Refused while an Agent enables it; removes its Keychain items too.
    func delete(_ id: String) throws {
        let users = usage(id)
        guard users == 0 else { throw MCPProblem.inUse(users) }
        guard let server = server(id) else { return }
        for name in server.secretNames { try? secrets.delete(account(id, name)) }
        try? secrets.delete(account(id, "oauth"))
        servers.removeAll { $0.id == id }
        activity[id] = nil
        persist()
        stdio.stop(id)
    }

    func setEnabled(_ id: String, _ enabled: Bool) {
        guard let index = servers.firstIndex(where: { $0.id == id }) else { return }
        servers[index].isEnabled = enabled
        persist()
        if !enabled { stdio.stop(id) }
    }

    /// A stdio server's running process (9d), started in the open project's folder with its environment.
    func stdioConnection(_ server: MCPServerConfig) async throws -> MCPStdioConnection {
        try await stdio.connection(for: server, environment: stdioEnvironment(for: server),
                                   cwd: projectRoot() ?? FileManager.default.homeDirectoryForCurrentUser)
    }

    /// Its own variables: the plain ones, and the secret ones from the Keychain.
    func stdioEnvironment(for server: MCPServerConfig) -> [String: String] {
        var environment = server.plainEnvironment
        for name in server.secretNames {
            if let value = try? secrets.read(account(server.id, name)) {
                SecretShield.shared.register(value)
                environment[name] = value
            }
        }
        return environment
    }

    /// Masked for the form: which secret names exist.

    // MARK: Testing and signing in

    /// 测试连接: connect, list the tools, remember the result. A 401 on a server without a token leads to
    /// the browser sign-in (old app 2026-09-07), when `allowSignIn`.
    func test(_ id: String, allowSignIn: Bool = true) async {
        guard let server = server(id) else { return }
        if server.isStdio {
            guard MCPBuild.supportsStdio else {
                record(id, succeeded: false, message: MCPFailure.unsupported("它要在本机启动进程，这个版本跑不了").message)
                return
            }
            // Its process, started (a first `npx -y` downloads — 60 s, S5), introduced, and its tools listed (9d).
            activity[id] = .testing
            let result: Result<MCPListing, MCPFailure>
            do {
                result = await MCPClient.listTools(on: try await stdioConnection(server))
            } catch {
                result = .failure(error as? MCPFailure ?? .network(error.localizedDescription))
            }
            activity[id] = nil
            switch result {
            case .success(let listing):
                guard let index = servers.firstIndex(where: { $0.id == id }) else { return }
                servers[index].tools = listing.tools
                servers[index].lastTest = .init(succeeded: true, message: nil, at: .now)
                persist()
            case .failure(let failure):
                record(id, succeeded: false, message: failure.message)
            }
            return
        }
        guard case .http(let url) = server.transport else { return }
        activity[id] = .testing
        let headers = await requestHeaders(for: server)
        let result = await client.listTools(url: url, headers: headers)
        activity[id] = nil
        switch result {
        case .success(let listing):
            guard let index = servers.firstIndex(where: { $0.id == id }) else { return }
            servers[index].tools = listing.tools
            servers[index].lastTest = .init(succeeded: true, message: nil, at: .now)
            persist()
        case .failure(.authRequired(let metadata)):
            resourceMetadata[id] = metadata
            let hasToken = server.secretNames.contains { $0.lowercased() == "authorization" }
            if hasToken, server.auth != .oauth {
                record(id, succeeded: false, message: "令牌无效或已过期（401）")
            } else {
                setAuth(id, .oauth)
                record(id, succeeded: false, message: Self.signInPrompt, needsSignIn: true)
                if allowSignIn { await signIn(id) }
            }
        case .failure(let failure):
            // A server on this Mac that isn't running says how to switch it on (Figma 桌面版, D91).
            let hint = failure.isUnreachable ? server.catalogID.flatMap(MCPCatalogEntry.entry)?.offlineHint : nil
            record(id, succeeded: false, message: hint ?? failure.message)
        }
    }

    /// Browser sign-in, then a fresh test.
    func signIn(_ id: String) async {
        guard let server = server(id), case .http(let url) = server.transport else { return }
        activity[id] = .waitingForBrowser
        let loopback = OAuthLoopback()
        do {
            let redirect = try await loopback.start()
            let discovery = try await oauth.discover(serverURL: url, resourceMetadata: resourceMetadata[id])
            let clientID = try await oauth.register(discovery.metadata, redirectURI: redirect)
            let verifier = PKCE.makeVerifier()
            let state = PKCE.makeVerifier()
            guard let authorization = MCPOAuth.authorizationURL(discovery, clientID: clientID, redirectURI: redirect,
                                                                challenge: PKCE.challenge(for: verifier), state: state) else {
                throw MCPOAuthError.discovery("登录地址无效")
            }
            openURL(authorization)
            switch await loopback.waitForCallback() {
            case .success(let code, let returned):
                guard returned == state else { throw MCPOAuthError.stateMismatch }
                let credential = try await oauth.exchange(code: code, verifier: verifier, redirectURI: redirect,
                                                          clientID: clientID, discovery: discovery)
                try saveCredential(credential, for: id)
                setAuth(id, .oauth)
                activity[id] = nil
                await test(id, allowSignIn: false)
            case .denied(let reason):
                throw MCPOAuthError.denied(reason)
            case .invalid:
                throw MCPOAuthError.denied("浏览器没有带回授权码")
            }
        } catch {
            loopback.stop()
            activity[id] = nil
            var message = (error as? MCPOAuthError)?.message ?? error.localizedDescription
            // A service that won't have Formora (Figma, D91): where to go instead.
            if (error as? MCPOAuthError) == .notAllowed, let hint = server.catalogID.flatMap(MCPCatalogEntry.entry)?.refusedHint {
                message += "。" + hint
            }
            record(id, succeeded: false, message: message, needsSignIn: true)
        }
    }

    /// Plain headers, secret headers from the Keychain, and the sign-in token (refreshed when expired).
    func requestHeaders(for server: MCPServerConfig) async -> [String: String] {
        var headers = server.plainHeaders
        if !server.isStdio {
            for name in server.secretNames {
                if let value = try? secrets.read(account(server.id, name)) {
                    SecretShield.shared.register(value)
                    headers[name] = value
                }
            }
        }
        if server.auth == .oauth, var credential = oauthCredential(server.id) {
            if credential.isExpired(), credential.refreshToken != nil, let refreshed = try? await oauth.refresh(credential) {
                credential = refreshed
                try? saveCredential(refreshed, for: server.id)
            }
            headers["Authorization"] = "Bearer \(credential.accessToken)"
            SecretShield.shared.register(credential.accessToken)
        }
        return headers
    }

    func isSignedIn(_ id: String) -> Bool { oauthCredential(id) != nil }

    // MARK: Helpers

    private func account(_ id: String, _ name: String) -> String { "\(id)/\(name)" }

    private func oauthCredential(_ id: String) -> MCPOAuthCredential? {
        guard let text = try? secrets.read(account(id, "oauth")) else { return nil }
        return try? JSONDecoder().decode(MCPOAuthCredential.self, from: Data(text.utf8))
    }

    private func saveCredential(_ credential: MCPOAuthCredential, for id: String) throws {
        let data = try JSONEncoder().encode(credential)
        try secrets.write(String(decoding: data, as: UTF8.self), for: account(id, "oauth"))
    }

    private func setAuth(_ id: String, _ auth: MCPServerConfig.Auth) {
        guard let index = servers.firstIndex(where: { $0.id == id }), servers[index].auth != auth else { return }
        servers[index].auth = auth
        persist()
    }

    private func record(_ id: String, succeeded: Bool, message: String?, needsSignIn: Bool = false) {
        guard let index = servers.firstIndex(where: { $0.id == id }) else { return }
        servers[index].lastTest = .init(succeeded: succeeded, message: message, at: .now, needsSignIn: needsSignIn ? true : nil)
        persist()
    }

    private func persist() {
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(servers).write(to: fileURL, options: .atomic)
    }
}
