import Foundation

/// One tool a server offers. Annotations decide the approval tier later (old app 2026-09-07, 决定三):
/// `readOnlyHint` = read, `destructiveHint` (true by default in the MCP spec) = run code, else write.
struct MCPTool: Codable, Equatable, Hashable, Identifiable, Sendable {
    let name: String
    var title: String?
    var summary: String?
    var readOnly: Bool?
    var destructive: Bool?
    /// The arguments' JSON Schema as the server listed it (7f): what the model is told to send.
    var inputSchema: String?

    var id: String { name }
    var displayName: String { title ?? name }
}

/// A configured MCP server (spec §8.4). Secret header / environment values and OAuth tokens live in the
/// Keychain; only their names are stored here.
struct MCPServerConfig: Codable, Equatable, Identifiable, Sendable {
    enum Transport: Codable, Equatable, Sendable {
        case http(url: String)
        case stdio(command: String, args: [String])
    }

    enum Auth: Codable, Equatable, Sendable {
        case none
        /// A secret request header whose value is in the Keychain.
        case header(name: String)
        /// Browser sign-in; the tokens are in the Keychain.
        case oauth
    }

    struct TestRecord: Codable, Equatable, Sendable {
        var succeeded: Bool
        var message: String?
        var at: Date
        /// The server answered 401 and wants the browser sign-in.
        var needsSignIn: Bool?
    }

    let id: String
    var name: String
    var transport: Transport
    var auth: Auth = .none
    /// Non-secret request headers (HTTP), shown in the row.
    var plainHeaders: [String: String] = [:]
    /// Secret header names (HTTP) or environment variable names (stdio) held in the Keychain.
    var secretNames: [String] = []
    /// Non-secret environment variables (stdio).
    var plainEnvironment: [String: String] = [:]
    /// The recommended-catalog entry it came from, if any.
    var catalogID: String?
    /// The global switch (spec §8.7: MCP has one because it opens real connections).
    var isEnabled = true
    /// From the last successful connection test — what an Agent can choose from.
    var tools: [MCPTool] = []
    var lastTest: TestRecord?

    var mark: String { String(name.trimmingCharacters(in: .whitespaces).prefix(2)).uppercased() }
    var isStdio: Bool { if case .stdio = transport { true } else { false } }

    /// 「连到哪」 for the row: the URL, or the command line — never a secret (spec §8.4 1b).
    var endpointSummary: String {
        switch transport {
        case .http(let url): url
        case .stdio(let command, let args): ([command] + args).joined(separator: " ")
        }
    }

    var transportLabel: String { isStdio ? "stdio" : "Streamable HTTP" }

    static func newID() -> String { "mcp-\(UUID().uuidString.prefix(8).lowercased())" }
}

/// Which servers and tools one Agent may use (spec §8.4). Stored on `AgentRecord`.
struct MCPAccess: Codable, Equatable, Hashable, Sendable {
    enum Mode: String, Codable, Sendable { case all, selected }

    var serverID: String
    var mode: Mode = .all
    var toolNames: [String] = []
}

/// What this build can run. stdio launches local processes — only the Developer ID build may (old app 2026-09-07,
/// 决定一; 9d, S1); in the App Store build's sandbox `npx -y` can't download and run packages.
enum MCPBuild {
    #if FORMORA_DEVELOPER_ID
    static let supportsStdio = true
    #else
    static let supportsStdio = false
    #endif
}
