import CryptoKit
import Foundation

/// One MCP tool as an Agent's own (7f, F3).
struct MCPBinding: Sendable {
    let spec: ToolSpec
    let serverID: String
    let serverName: String
    /// The name the server knows it by.
    let toolName: String
}

/// MCP tools in the loop (7f, F3): every tool of an enabled HTTP server the Agent may use, named as Claude Code names
/// them — `mcp__<server>__<tool>` — so hook matchers written for Claude Code keep working; the tier from the tool's
/// annotations (old app 2026-09-07, 决定三): read-only → read, not destructive → write, otherwise run — MCP's own
/// default is destructive. stdio servers run in the Developer ID build only (9d).
enum MCPTools {
    static let prefix = "mcp__"
    static let nameLimit = 64
    static let outputLimit = 30_000
    /// An older listing carried no schema: the model may send any object.
    static let openSchema = #"{"type":"object","properties":{},"additionalProperties":true}"#

    static func name(server: String, serverID: String, tool: String) -> String {
        let serverPart = sanitize(server).isEmpty ? sanitize(serverID) : sanitize(server)
        let toolPart = sanitize(tool).isEmpty ? "tool" : sanitize(tool)
        let full = prefix + serverPart + "__" + toolPart
        guard full.count > nameLimit else { return full }
        let hash = SHA256.hash(data: Data(full.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        return String(full.prefix(nameLimit - hash.count - 1)) + "_" + hash
    }

    /// What a tool name may hold on every provider: letters, digits, `_` and `-`.
    static func sanitize(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9_-]+"#, with: "_", options: .regularExpression)
            .replacingOccurrences(of: #"_+"#, with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }

    static func tier(_ tool: MCPTool) -> ToolTier {
        if tool.readOnly == true { return .read }
        if tool.destructive == false { return .write }
        return .exec
    }

    /// The tools one Agent has from its MCP tab: enabled HTTP servers with a listing, every tool or the chosen ones.
    @MainActor
    static func bindings(for agent: AgentRecord, in store: MCPStore) -> [MCPBinding] {
        var seen = Set<String>()
        var bindings: [MCPBinding] = []
        for access in agent.mcpAccess {
            guard let server = store.server(access.serverID), server.isEnabled, !server.isStdio || MCPBuild.supportsStdio else { continue }
            for tool in server.tools where access.mode == .all || access.toolNames.contains(tool.name) {
                let name = name(server: server.name, serverID: server.id, tool: tool.name)
                guard seen.insert(name).inserted else { continue }
                bindings.append(MCPBinding(spec: spec(server: server, tool: tool, name: name), serverID: server.id,
                                           serverName: server.name, toolName: tool.name))
            }
        }
        return bindings
    }

    static func spec(server: MCPServerConfig, tool: MCPTool, name: String) -> ToolSpec {
        let about = [tool.summary, tool.title].compactMap { $0 }.first { !$0.isEmpty } ?? tool.name
        return ToolSpec(name: name, description: "\(about) (MCP server \(server.name))",
                        parameters: tool.inputSchema ?? openSchema, tier: tier(tool))
    }

    /// Calls it with the server's headers (a sign-in token refreshed when it expired).
    @MainActor
    static func call(_ binding: MCPBinding, arguments: String, store: MCPStore, client: MCPClient) async -> ToolResult {
        guard let server = store.server(binding.serverID) else {
            return .failed("MCP 服务「\(binding.serverName)」已经不在了，这一步没有执行。")
        }
        guard server.isEnabled else { return .failed("「\(server.name)」在「设置 → MCP」里关掉了，这一步没有执行。") }
        let outcome: Result<MCPCallResult, MCPFailure>
        switch server.transport {
        case .http(let url):
            let headers = await store.requestHeaders(for: server)
            outcome = await client.callTool(url: url, headers: headers, name: binding.toolName, arguments: arguments)
        case .stdio:
            guard MCPBuild.supportsStdio else { return .failed("「\(server.name)」要在本机启动进程，这个版本跑不了。") }
            // Its process, started or started again as needed, in the open project's folder (9d).
            do {
                outcome = await MCPClient.callTool(on: try await store.stdioConnection(server), name: binding.toolName, arguments: arguments)
            } catch {
                outcome = .failure(error as? MCPFailure ?? .network(error.localizedDescription))
            }
        }
        switch outcome {
        case .success(let result):
            let text = Compaction.headAndTail(result.text.isEmpty ? "（没有返回内容）" : result.text, limit: outputLimit)
            return result.isError ? .failed("「\(server.name)」的 \(binding.toolName) 报错：\(text)") : .done(text)
        case .failure(.authRequired):
            return .failed("「\(server.name)」要求登录或令牌已过期：请用户去「设置 → MCP」重新登录，然后再试。")
        case .failure(let failure):
            return .failed("调用「\(server.name)」的 \(binding.toolName) 没有成功：\(failure.message)")
        }
    }

    /// `mcp__deepwiki__ask_question` → (deepwiki, ask_question), for the card.
    static func parts(of name: String) -> (server: String, tool: String)? {
        guard name.hasPrefix(prefix) else { return nil }
        let rest = name.dropFirst(prefix.count)
        guard let split = rest.range(of: "__") else { return (String(rest), "") }
        return (String(rest[..<split.lowerBound]), String(rest[split.upperBound...]))
    }
}
