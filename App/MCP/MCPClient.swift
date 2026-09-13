import Foundation

enum MCPFailure: Error, Equatable, Sendable {
    /// 401: the server wants credentials; `resourceMetadata` from `WWW-Authenticate` when given (RFC 9728).
    case authRequired(resourceMetadata: String?)
    case http(Int, String)
    case timedOut
    case protocolError(String)
    case network(String)
    /// This build can't run it (stdio outside the Developer ID build).
    case unsupported(String)

    var message: String {
        switch self {
        case .authRequired: "服务要求登录或令牌"
        case .http(let status, let body): body.isEmpty ? "服务返回 \(status)" : "服务返回 \(status)：\(body)"
        case .timedOut: "10 秒内没有响应"
        case .protocolError(let detail): "响应不符合 MCP 协议：\(detail)"
        case .network(let detail): detail
        case .unsupported(let detail): detail
        }
    }
}

struct MCPListing: Equatable, Sendable {
    var serverName: String?
    var protocolVersion: String
    var tools: [MCPTool]
}

/// What a `tools/call` came back with (7f, F3): its content as text, and whether the tool itself failed.
struct MCPCallResult: Equatable, Sendable {
    var text: String
    var isError: Bool

    /// Text parts joined; images, audio and resources named (the model here can't see them); structured content
    /// when there is no text.
    static func from(_ result: JSONValue) -> MCPCallResult {
        var parts: [String] = []
        for item in result["content"]?.array ?? [] {
            switch item["type"]?.string {
            case "text": parts.append(item["text"]?.string ?? "")
            case "image": parts.append("[图片 \(item["mimeType"]?.string ?? "")：这里看不到图片内容]")
            case "audio": parts.append("[音频 \(item["mimeType"]?.string ?? "")]")
            case "resource": parts.append(item["resource"]?["text"]?.string ?? "[资源 \(item["resource"]?["uri"]?.string ?? "")]")
            case "resource_link": parts.append("[链接] \(item["name"]?.string ?? "") \(item["uri"]?.string ?? "")")
            default: break
            }
        }
        if parts.isEmpty, let structured = result["structuredContent"],
           let data = try? JSONSerialization.data(withJSONObject: structured.any, options: [.sortedKeys]) {
            parts.append(String(decoding: data, as: UTF8.self))
        }
        return MCPCallResult(text: parts.joined(separator: "\n\n"), isError: result["isError"]?.bool == true)
    }
}

/// Streamable HTTP, enough for 测试连接: initialize → notifications/initialized → tools/list (paginated),
/// following omp (`mcp/client.ts`, `transports/http.ts`): `Accept: application/json, text/event-stream`,
/// the `Mcp-Session-Id` the server hands out, and `MCP-Protocol-Version` on every request after initialize.
/// A response may be one JSON body or an SSE stream carrying it. Tools are called over the same session steps (7f).
struct MCPClient: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, Error>)

    static let protocolVersion = "2025-11-25"
    /// Design spec §8.4.
    static let testTimeout: TimeInterval = 10
    /// A tool may take a while (a search, a page to render).
    static let callTimeout: TimeInterval = 60

    static let live: Transport = { request in
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw MCPFailure.network("不是 HTTP 响应") }
        let lines = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines { continuation.yield(line) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return (http, lines)
    }

    let transport: Transport

    init(transport: @escaping Transport = MCPClient.live) {
        self.transport = transport
    }

    /// Connects, lists every tool, and gives up after `timeout` seconds.
    func listTools(url: String, headers: [String: String], timeout: TimeInterval = MCPClient.testTimeout) async -> Result<MCPListing, MCPFailure> {
        guard let endpoint = URL(string: url), let scheme = endpoint.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            return .failure(.protocolError("地址不是 http(s) URL"))
        }
        do {
            let listing = try await Self.deadline(timeout) {
                var session = Session(endpoint: endpoint, headers: headers, transport: transport)
                return try await session.list()
            }
            return .success(listing)
        } catch let failure as MCPFailure {
            return .failure(failure)
        } catch let error as URLError where error.code == .timedOut {
            return .failure(.timedOut)
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }

    /// One tool call (7f, F3): a session of its own — initialize, initialized, `tools/call` — within `timeout`.
    func callTool(url: String, headers: [String: String], name: String, arguments: String,
                  timeout: TimeInterval = MCPClient.callTimeout) async -> Result<MCPCallResult, MCPFailure> {
        guard let endpoint = URL(string: url), let scheme = endpoint.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            return .failure(.protocolError("地址不是 http(s) URL"))
        }
        let text = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = JSONValue.parse(text.isEmpty ? "{}" : text), case .object = parsed else {
            return .failure(.protocolError("参数不是 JSON 对象"))
        }
        do {
            let result = try await Self.deadline(timeout) {
                var session = Session(endpoint: endpoint, headers: headers, transport: transport, timeout: timeout)
                return try await session.call(name, arguments: parsed)
            }
            return .success(MCPCallResult.from(result))
        } catch let failure as MCPFailure {
            return .failure(failure == .timedOut ? .unsupported("\(Int(timeout)) 秒内没有结果") : failure)
        } catch let error as URLError where error.code == .timedOut {
            return .failure(.unsupported("\(Int(timeout)) 秒内没有结果"))
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }

    private static func deadline<T: Sendable>(_ seconds: TimeInterval, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw MCPFailure.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw MCPFailure.timedOut }
            return first
        }
    }

    /// One connection's state: session id, negotiated version, next request id.
    struct Session {
        let endpoint: URL
        let headers: [String: String]
        let transport: Transport
        let timeout: TimeInterval
        var sessionID: String?
        var negotiatedVersion: String?
        var nextID = 1

        init(endpoint: URL, headers: [String: String], transport: @escaping Transport, timeout: TimeInterval = MCPClient.testTimeout) {
            self.endpoint = endpoint
            self.headers = headers
            self.transport = transport
            self.timeout = timeout
        }

        /// initialize → notifications/initialized; the server's answer to initialize.
        private mutating func handshake() async throws -> JSONValue {
            let initialize = try await request("initialize", params: .object([
                "protocolVersion": .string(MCPClient.protocolVersion),
                "capabilities": .object([:]),
                "clientInfo": .object(["name": .string("Formora"), "version": .string(Self.appVersion)]),
            ]))
            negotiatedVersion = initialize["protocolVersion"]?.string ?? MCPClient.protocolVersion
            try await notify("notifications/initialized")
            return initialize
        }

        mutating func call(_ tool: String, arguments: JSONValue) async throws -> JSONValue {
            _ = try await handshake()
            return try await request("tools/call", params: .object(["name": .string(tool), "arguments": arguments]))
        }

        mutating func list() async throws -> MCPListing {
            let initialize = try await handshake()
            var tools: [MCPTool] = []
            var cursor: String?
            var pages = 0
            repeat {
                let result = try await request("tools/list", params: cursor.map { .object(["cursor": .string($0)]) } ?? .object([:]))
                tools += (result["tools"]?.array ?? []).compactMap(Self.tool)
                cursor = result["nextCursor"]?.string
                pages += 1
            } while cursor != nil && pages < 50
            return MCPListing(serverName: initialize["serverInfo"]?["name"]?.string,
                              protocolVersion: negotiatedVersion ?? MCPClient.protocolVersion, tools: tools)
        }

        static func tool(_ value: JSONValue) -> MCPTool? {
            guard let name = value["name"]?.string, !name.isEmpty else { return nil }
            let annotations = value["annotations"]
            let schema = value["inputSchema"].flatMap { try? JSONSerialization.data(withJSONObject: $0.any, options: [.sortedKeys]) }
            return MCPTool(name: name, title: value["title"]?.string ?? annotations?["title"]?.string,
                           summary: value["description"]?.string,
                           readOnly: annotations?["readOnlyHint"]?.bool, destructive: annotations?["destructiveHint"]?.bool,
                           inputSchema: schema.map { String(decoding: $0, as: UTF8.self) })
        }

        private static var appVersion: String {
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        }

        private func makeRequest(body: JSONValue) -> URLRequest {
            var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
            request.httpMethod = "POST"
            for (name, value) in headers where name.lowercased() != "mcp-protocol-version" {
                request.setValue(value, forHTTPHeaderField: name)
            }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
            if let negotiatedVersion { request.setValue(negotiatedVersion, forHTTPHeaderField: "MCP-Protocol-Version") }
            request.httpBody = body.encoded()
            return request
        }

        private mutating func notify(_ method: String) async throws {
            let (response, lines) = try await transport(makeRequest(body: .object(["jsonrpc": .string("2.0"), "method": .string(method)])))
            if let id = response.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionID = id }
            for try await _ in lines {} // drain
            guard (200..<300).contains(response.statusCode) else { throw try await Self.failure(response, lines: nil) }
        }

        private mutating func request(_ method: String, params: JSONValue) async throws -> JSONValue {
            let id = nextID
            nextID += 1
            let body = JSONValue.object(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string(method), "params": params])
            let (response, lines) = try await transport(makeRequest(body: body))
            if let session = response.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionID = session }
            guard (200..<300).contains(response.statusCode) else { throw try await Self.failure(response, lines: lines) }
            let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            let message: JSONValue
            if contentType.contains("text/event-stream") {
                message = try await Self.firstSSEMessage(lines, id: id)
            } else {
                var text = ""
                for try await line in lines { text += line + "\n" }
                guard let value = JSONValue.parse(text) else { throw MCPFailure.protocolError("不是 JSON") }
                message = value
            }
            if let error = message["error"] {
                throw MCPFailure.protocolError(error["message"]?.string ?? "服务返回了错误")
            }
            guard let result = message["result"] else { throw MCPFailure.protocolError("缺少 result") }
            return result
        }

        /// `data:` lines carry JSON-RPC messages; the first one answering `id` is the result. A data line
        /// that isn't complete JSON yet is joined with the next.
        static func firstSSEMessage(_ lines: AsyncThrowingStream<String, Error>, id: Int) async throws -> JSONValue {
            var pending = ""
            for try await line in lines {
                guard line.hasPrefix("data:") else {
                    if line.isEmpty { pending = "" }
                    continue
                }
                let chunk = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                pending = pending.isEmpty ? chunk : pending + "\n" + chunk
                guard let value = JSONValue.parse(pending) else { continue }
                pending = ""
                for message in value.array ?? [value] where message["id"]?.int == id {
                    if message["result"] != nil || message["error"] != nil { return message }
                }
            }
            throw MCPFailure.protocolError("事件流结束了，还没收到回复")
        }

        static func failure(_ response: HTTPURLResponse, lines: AsyncThrowingStream<String, Error>?) async throws -> MCPFailure {
            if response.statusCode == 401 {
                return .authRequired(resourceMetadata: resourceMetadata(in: response.value(forHTTPHeaderField: "WWW-Authenticate")))
            }
            var text = ""
            if let lines { for try await line in lines { text += line; if text.count > 400 { break } } }
            let message = JSONValue.parse(text).flatMap { $0["error"]?["message"]?.string ?? $0["error"]?.string ?? $0["message"]?.string }
            return .http(response.statusCode, String((message ?? text).prefix(200)))
        }

        /// `Bearer resource_metadata="https://…"` → the URL.
        static func resourceMetadata(in header: String?) -> String? {
            guard let header, let range = header.range(of: #"resource_metadata\s*=\s*"([^"]+)""#, options: .regularExpression) else {
                return nil
            }
            let match = header[range]
            guard let open = match.firstIndex(of: "\"") else { return nil }
            return String(match[match.index(after: open)...].dropLast())
        }
    }
}
