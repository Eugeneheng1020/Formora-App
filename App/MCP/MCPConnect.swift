import Foundation

/// Connecting an MCP server by asking (7h, B4, B9): from the recommended catalog, a URL or a pasted config, then tested
/// at once — a sign-in opens the browser. Bob and the Agents share it. What is already there is said, not added again
/// (spec §8.8).
@MainActor
enum MCPConnect {
    static let catalogSpec = ToolSpec(
        name: "mcp_catalog",
        description: "List the recommended MCP services Formora connects in one step: id, name, what it does, how it signs in. Pass an id from here to mcp_add.",
        parameters: #"{"type":"object","properties":{}}"#,
        tier: .read)

    static let addSpec = ToolSpec(
        name: "mcp_add",
        description: "Connect an MCP service: by `catalog_id` (from mcp_catalog), by `url` (a Streamable HTTP endpoint) with a `name`, or by `config` (a pasted JSON config). A `token` the user gave becomes the service's key (a header, or a local server's environment variable). It is tested at once; a service that needs signing in opens the user's browser."
            + (MCPBuild.supportsStdio ? "" : " Only HTTP services work in this build.")
            + " Connecting enables it for no Agent — the user does that in the Agent's MCP tab.",
        parameters: #"{"type":"object","properties":{"catalog_id":{"type":"string"},"url":{"type":"string"},"name":{"type":"string"},"config":{"type":"string","description":"A pasted MCP config, JSON"},"token":{"type":"string","description":"An API key or token the user gave"}}}"#,
        tier: .write)

    static func catalogText() -> String {
        MCPCatalogEntry.all.map { entry in
            let access: String
            // A local (stdio) server is only out of reach outside the Developer ID build (9d; D92 found it said so everywhere).
            if entry.isStdio, !MCPBuild.supportsStdio {
                access = "要在本机启动，这个版本接不了"
            } else if entry.usesOAuth {
                access = "浏览器登录" + (entry.field != nil ? "，也可以填令牌" : "")
            } else if let field = entry.field {
                // Where to make one (D93): Bob tells the user, who pastes it in the chat.
                access = "要填「\(field.label)」：" + field.hint.trimmingCharacters(in: CharacterSet(charactersIn: "。"))
            } else {
                access = "不用登录"
            }
            // The caveat too (D91): what a service needs or can't do, so Bob says so rather than guess.
            return "- \(entry.id)：\(entry.name)——\(entry.summary)（\(access)）" + (entry.note.map { " \($0)" } ?? "")
        }.joined(separator: "\n")
    }

    enum Plan {
        case add(server: MCPServerConfig, secrets: [String: String])
        /// Nothing to add — already there, or something missing: said to the model without asking the user.
        /// `existing`: the server that is already there.
        case answer(ToolResult, existing: String?)
    }

    /// What `mcp_add` would do, before anyone is asked.
    static func plan(_ arguments: String, store: MCPStore) -> Plan {
        let args = ToolArguments.parse(arguments) ?? [:]
        func text(_ key: String) -> String { (args[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        let token = text("token")
        let config: (server: MCPServerConfig, secrets: [String: String])
        if !text("catalog_id").isEmpty {
            let wanted = text("catalog_id")
            guard let entry = MCPCatalogEntry.entry(wanted.lowercased())
                    ?? MCPCatalogEntry.all.first(where: { FileSearch.normalize($0.name).contains(FileSearch.normalize(wanted)) }) else {
                return .answer(.failed("推荐目录里没有「\(wanted)」。先用 mcp_catalog 看有哪些，或者要用户给地址。"), existing: nil)
            }
            if let existing = store.servers.first(where: { $0.catalogID == entry.id }) {
                return .answer(.done("\(existing.name) 之前已经接入过了，没有重复添加。"), existing: existing.id)
            }
            if entry.isStdio, !MCPBuild.supportsStdio { return .answer(.failed("\(entry.name) 要在本机启动进程，这个版本接不了。"), existing: nil) }
            if entry.tokenIsRequired, token.isEmpty {
                return .answer(.failed("接入 \(entry.name) 要先有「\(entry.field?.label ?? "令牌")」。向用户要，别编。"), existing: nil)
            }
            config = entry.config(name: "", token: token)
        } else if !text("config").isEmpty {
            switch MCPConfigParser.parse(text("config")) {
            case .failure(let problem): return .answer(.failed("这段配置读不出来：\(problem.message)"), existing: nil)
            case .success(let parsed): config = parsed.config(name: text("name"))
            }
        } else if !text("url").isEmpty {
            let address = text("url")
            guard let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                return .answer(.failed("url 要是 http:// 或 https:// 开头的地址。"), existing: nil)
            }
            var server = MCPServerConfig(id: MCPServerConfig.newID(), name: text("name").isEmpty ? (url.host ?? address) : text("name"),
                                         transport: .http(url: address))
            var secrets: [String: String] = [:]
            if !token.isEmpty {
                server.auth = .header(name: "Authorization")
                secrets["Authorization"] = token.lowercased().hasPrefix("bearer ") ? token : "Bearer " + token
            }
            config = (server, secrets)
        } else {
            return .answer(.failed("catalog_id、url、config 至少给一个。"), existing: nil)
        }
        if case .http(let url) = config.server.transport,
           let existing = store.servers.first(where: { if case .http(let other) = $0.transport { other == url } else { false } }) {
            return .answer(.done("\(existing.name) 之前已经接入过了（同一个地址），没有重复添加。"), existing: existing.id)
        }
        if case .stdio = config.server.transport, let existing = store.servers.first(where: { $0.transport == config.server.transport }) {
            return .answer(.done("\(existing.name) 之前已经接入过了（同一条命令），没有重复添加。"), existing: existing.id)
        }
        if let problem = store.problem(name: config.server.name, transport: config.server.transport, editing: nil) {
            return .answer(.failed(problem.message), existing: nil)
        }
        return .add(server: config.server, secrets: config.secrets)
    }

    /// The command an `mcp_add` would start on this Mac, for its approval card (9d, S6); `nil` for a web address.
    nonisolated static func commandLine(_ arguments: String) -> String? {
        let args = ToolArguments.parse(arguments) ?? [:]
        func text(_ key: String) -> String { (args[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        let transport: MCPServerConfig.Transport?
        if !text("catalog_id").isEmpty {
            let wanted = text("catalog_id")
            transport = (MCPCatalogEntry.entry(wanted.lowercased())
                ?? MCPCatalogEntry.all.first { FileSearch.normalize($0.name).contains(FileSearch.normalize(wanted)) })?.transport
        } else if !text("config").isEmpty, case .success(let parsed) = MCPConfigParser.parse(text("config")) {
            transport = parsed.transport
        } else {
            transport = nil
        }
        guard case .stdio(let command, let commandArguments) = transport else { return nil }
        return ([command] + commandArguments).joined(separator: " ")
    }

    /// Added, then tested (a sign-in opens the browser); the result says how the test went.
    static func add(_ server: MCPServerConfig, secrets: [String: String], store: MCPStore) async -> ToolResult {
        let id: String
        do {
            id = try store.add(server, secrets: secrets)
        } catch {
            return .failed((error as? MCPProblem)?.message ?? error.localizedDescription)
        }
        await store.test(id)
        guard let test = store.server(id)?.lastTest else { return .done("已把「\(server.name)」加进 MCP 列表，还没测试连接。") }
        if test.succeeded {
            let tools = store.server(id)?.tools.count ?? 0
            return .done("已接入「\(server.name)」，测试连接成功，有 \(tools) 个工具。要让 Agent 用上，去那个 Agent 的 MCP 标签里启用。")
        }
        return .done("已把「\(server.name)」加进 MCP 列表，但测试连接没有成功：\(test.message ?? "原因不明")。可以在 MCP 列表里重新测试或登录。")
    }
}
