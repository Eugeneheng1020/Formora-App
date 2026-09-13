import Foundation

/// 「粘贴配置」 (spec §8.4 layer 2): one server from the JSON a service's docs give. Accepts the three shapes
/// the ecosystem uses — `{"mcpServers":{"名字":{…}}}`, `{"名字":{…}}`, and a bare `{"command":…}` /
/// `{"url":…}` — and reports only what it recognised.
struct ParsedMCPServer: Equatable, Sendable {
    var name: String
    var transport: MCPServerConfig.Transport
    var plainHeaders: [String: String] = [:]
    var secretHeaders: [String: String] = [:]
    var plainEnvironment: [String: String] = [:]
    var secretEnvironment: [String: String] = [:]

    /// The server config plus the values that go to the Keychain.
    func config(name override: String) -> (server: MCPServerConfig, secrets: [String: String]) {
        let shown = override.trimmingCharacters(in: .whitespaces)
        let secrets = secretHeaders.merging(secretEnvironment) { first, _ in first }
        var server = MCPServerConfig(id: MCPServerConfig.newID(), name: shown.isEmpty ? name : shown, transport: transport,
                                     plainHeaders: plainHeaders, secretNames: secrets.keys.sorted(),
                                     plainEnvironment: plainEnvironment)
        if let header = secretHeaders.keys.sorted().first { server.auth = .header(name: header) }
        return (server, secrets)
    }
}

enum MCPConfigParser {
    enum Problem: Error, Equatable {
        case notJSON, empty, several(Int), unrecognised

        /// The mockup's wording (`parseMcpConfig`).
        var message: String {
            switch self {
            case .notJSON: "这不是合法的 JSON。把服务文档里的配置整段复制过来，包含最外层的大括号。"
            case .empty: "没有找到任何服务配置。"
            case .several(let count): "一次只能添加一个服务，这段配置里有 \(count) 个。"
            case .unrecognised: "配置里既没有 command 也没有 url，认不出这是哪种服务。"
            }
        }
    }

    static func parse(_ text: String) -> Result<ParsedMCPServer, Problem> {
        guard let root = JSONValue.parse(text.trimmingCharacters(in: .whitespacesAndNewlines)), case .object(var node) = root else {
            return .failure(.notJSON)
        }
        var key = ""
        if case .object(let servers)? = node["mcpServers"] { node = servers }
        if node["command"] == nil, node["url"] == nil {
            guard !node.isEmpty else { return .failure(.empty) }
            guard node.count == 1, let (name, value) = node.first else { return .failure(.several(node.count)) }
            guard case .object(let inner) = value else { return .failure(.unrecognised) }
            key = name
            node = inner
        }
        if let command = node["command"]?.string {
            let args = node["args"]?.array?.compactMap(\.string) ?? []
            var parsed = ParsedMCPServer(name: key, transport: .stdio(command: command, args: args))
            // Environment values are treated as secrets: they usually carry tokens (spec §8.4).
            for (name, value) in node["env"]?.object ?? [:] {
                if let text = value.string { parsed.secretEnvironment[name] = text }
            }
            return .success(parsed)
        }
        if let url = node["url"]?.string ?? node["serverUrl"]?.string {
            var parsed = ParsedMCPServer(name: key, transport: .http(url: url))
            for (name, value) in node["headers"]?.object ?? [:] {
                guard let text = value.string else { continue }
                if isSecretHeader(name) { parsed.secretHeaders[name] = text } else { parsed.plainHeaders[name] = text }
            }
            return .success(parsed)
        }
        return .failure(.unrecognised)
    }

    /// Authorization and anything named like a key or token is secret.
    static func isSecretHeader(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower == "authorization" || ["key", "token", "secret", "auth", "cookie"].contains { lower.contains($0) }
    }
}
