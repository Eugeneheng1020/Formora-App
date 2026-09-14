import Foundation

/// What a streamed reply is made of, whatever the protocol.
enum ChatEvent: Equatable, Sendable {
    case text(String)
    case thinking(String)
    /// Anthropic signs its thinking; the signature goes back with a tool-call turn (7b, L7).
    case thinkingSignature(String)
    /// A tool call whose arguments have all arrived.
    case toolCall(ToolCall)
    /// Why the model stopped.
    case stop(ChatStop)
    /// Tokens as the provider counted them (7e, E1): `input` includes cache reads and writes; `cached` and
    /// `reasoning` are parts of `input` and `output`.
    case usage(input: Int?, output: Int?, cached: Int? = nil, reasoning: Int? = nil)
    case failed(String)
}

/// Why a model call ended: done, waiting for its tools, or cut at the length limit.
enum ChatStop: Equatable, Sendable {
    case end, toolUse, length
}

enum ChatFailure: Error, Equatable, Sendable {
    case http(status: Int, message: String?)
    /// An error event inside an accepted stream.
    case provider(String)
    case network(String)
    case timedOut
    case cancelled
    /// The model answered with nothing at all.
    case empty

    static func from(_ error: Error) -> ChatFailure {
        if let failure = error as? ChatFailure { return failure }
        if error is CancellationError { return .cancelled }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled: return .cancelled
            case .timedOut: return .timedOut
            default: return .network(urlError.localizedDescription)
            }
        }
        return .network(error.localizedDescription)
    }

    var message: String {
        switch self {
        case let .http(status, message):
            let detail = message.map { "：\($0)" } ?? ""
            switch status {
            case 401, 403: return "服务商没有接受这个 API Key（\(status)）\(detail)"
            case 404: return "找不到这个模型或地址（404）\(detail)"
            case 429: return "请求太多或额度用完了（429）\(detail)"
            case 500...: return "服务商那边出错了（\(status)）\(detail)"
            default: return "服务商拒绝了这次请求（\(status)）\(detail)"
            }
        case .provider(let message): return message
        case .network(let message): return "连不上服务商：\(message)"
        case .timedOut: return "等了 \(Int(ChatWire.idleTimeout)) 秒没有收到新内容"
        case .cancelled: return "已停止"
        case .empty: return "模型没有返回任何内容"
        }
    }

    /// A 400 / 422 whose words point at the reasoning fields — worth one retry without them.
    var rejectsReasoning: Bool {
        guard case let .http(status, message) = self, status == 400 || status == 422 else { return false }
        let text = (message ?? "").lowercased()
        return ["reasoning", "thinking", "effort", "budget"].contains { text.contains($0) }
    }

    /// The request was too long for the model's window (omp `error/flags.ts`): compact and go again (7e, E4). Checked
    /// before `rejectsTools` — an overflow message can mention the tools too.
    var isContextOverflow: Bool {
        let text: String
        switch self {
        case let .http(status, message):
            guard [400, 413, 422].contains(status) || status >= 500 else { return false }
            text = message ?? ""
        case .provider(let message): text = message
        default: return false
        }
        return Self.overflowPatterns.contains { text.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    private static let overflowPatterns = [
        #"prompt is too long"#, #"input is too long for requested model"#, #"exceeds the context window"#,
        #"input token count.*exceeds the maximum"#, #"maximum prompt length is \d+"#, #"reduce the length of the messages"#,
        #"maximum context length is \d+ tokens"#, #"exceeds the available context size"#,
        #"requested tokens?.*exceed.*context (window|length|size)"#, #"context (window|length|size).*(exceeded|overflow|too small)"#,
        #"(prompt|input).*(too long|too large).*(context|n_ctx)"#, #"greater than the context length"#,
        #"context window exceeds limit"#, #"exceeded model token limit"#, #"context[_ ]length[_ ]exceeded"#,
        #"too many tokens"#, #"token limit exceeded"#, #"model_context_window_exceeded"#, #"exceeds the limit of \d+ tokens?\b"#,
        #"上下文.*(过长|超出|超过)"#,
    ]

    /// A 400 / 422 about the tool list: this host or model takes no tools — one retry without them (7b, L7).
    var rejectsTools: Bool {
        guard !isContextOverflow else { return false }
        guard case let .http(status, message) = self, status == 400 || status == 422 else { return false }
        let text = (message ?? "").lowercased()
        return ["tool", "function"].contains { text.contains($0) }
    }

    /// Worth waiting and trying the same model again (L3): throttling, the host's own errors, the network.
    /// A 429, or a provider saying it is rate-limited: the board says 「等待限流」 while it waits (8a, K5).
    var isRateLimit: Bool {
        switch self {
        case .http(let status, _): status == 429
        case .provider(let message): message.lowercased().contains("rate")
        default: false
        }
    }

    var isTransient: Bool {
        switch self {
        case let .http(status, _): return [408, 409, 425, 429].contains(status) || status >= 500
        case .network, .timedOut: return true
        case .provider(let message):
            let text = message.lowercased()
            // A stream the host cut short counts too (user 2026-09-14: OpenRouter's 「Upstream error … Response payload is
            // not completed」): what arrived is dropped and the reply goes again.
            return ["overload", "rate limit", "rate_limit", "timeout", "temporarily", "try again", "upstream error",
                    "payload is not completed", "not enough data", "transferencodingerror", "connection reset", "unexpected end",
                    "stream ended", "incomplete", "socket hang up", "bad gateway", "gateway timeout", "service unavailable",
                    "internal server error"].contains { text.contains($0) }
        case .cancelled, .empty: return false
        }
    }
}

/// Turns SSE lines into `ChatEvent`s for one protocol. A body that isn't SSE at all — a host that ignored
/// `stream: true` — is read whole at the end (old app 2026-09-06), so a reply arrives either way. Tool calls
/// are put together from their pieces and handed over whole (7b).
struct ChatStreamDecoder {
    let apiProtocol: APIProtocol

    private var pending = ""
    private var sawData = false
    private var body = ""
    /// Tool calls whose arguments are still arriving, by the protocol's index.
    private var partialCalls: [Int: PartialCall] = [:]
    private var callCount = 0

    private struct PartialCall {
        var id = ""
        var name = ""
        var arguments = ""
    }

    init(apiProtocol: APIProtocol) {
        self.apiProtocol = apiProtocol
    }

    mutating func feed(_ line: String) -> [ChatEvent] {
        if line.hasPrefix("data:") {
            sawData = true
            var payload = String(line.dropFirst(5))
            if payload.hasPrefix(" ") { payload.removeFirst() }
            if payload.trimmingCharacters(in: .whitespaces) == "[DONE]" {
                pending = ""
                return []
            }
            // A data line that isn't complete JSON yet is joined with the next.
            pending = pending.isEmpty ? payload : pending + "\n" + payload
            guard let json = Self.object(pending) as? [String: Any] else { return [] }
            pending = ""
            return Self.events(chunk: json, apiProtocol: apiProtocol) + toolEvents(json)
        }
        if line.isEmpty {
            pending = ""
            return []
        }
        if line.hasPrefix("event:") || line.hasPrefix(":") || line.hasPrefix("id:") || line.hasPrefix("retry:") { return [] }
        if !sawData { body += line + "\n" }
        return []
    }

    mutating func finish() -> [ChatEvent] {
        if sawData { return flushCalls() }
        guard let object = Self.object(body) else { return [] }
        if let chunks = object as? [[String: Any]] {
            var events: [ChatEvent] = []
            for chunk in chunks { events += Self.events(chunk: chunk, apiProtocol: apiProtocol) + toolEvents(chunk) }
            return events + flushCalls()
        }
        guard let json = object as? [String: Any] else { return [] }
        return Self.events(whole: json, apiProtocol: apiProtocol) + Self.wholeToolEvents(json, apiProtocol: apiProtocol)
    }

    private static func object(_ text: String) -> Any? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(text.utf8))
    }

    /// `{"error":{"message":…}}` or `{"error":"…"}` — the same shapes the key check reads.
    private static func errorMessage(_ json: [String: Any]) -> String? {
        if let error = json["error"] as? [String: Any] { return (error["message"] as? String) ?? "服务返回了错误" }
        return json["error"] as? String
    }

    /// One streamed chunk: text, thinking, usage, errors.
    static func events(chunk json: [String: Any], apiProtocol: APIProtocol) -> [ChatEvent] {
        if json["type"] as? String != "response.failed", let message = errorMessage(json) { return [.failed(message)] }
        switch apiProtocol {
        case .openAICompletions:
            var events: [ChatEvent] = []
            if let choices = json["choices"] as? [[String: Any]], let delta = choices.first?["delta"] as? [String: Any] {
                // omp: the first non-empty of the three aliases, so a chunk carrying two isn't doubled.
                for field in ["reasoning_content", "reasoning", "reasoning_text"] {
                    if let thinking = delta[field] as? String, !thinking.isEmpty {
                        events.append(.thinking(thinking))
                        break
                    }
                }
                if let text = contentText(delta["content"]), !text.isEmpty { events.append(.text(text)) }
            }
            if let usage = json["usage"] as? [String: Any] {
                events.append(Self.completionsUsage(usage))
            }
            return events

        case .openAIResponses:
            switch json["type"] as? String {
            case "response.output_text.delta":
                return (json["delta"] as? String).map { [.text($0)] } ?? []
            case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
                return (json["delta"] as? String).map { [.thinking($0)] } ?? []
            case "response.completed", "response.incomplete":
                let usage = (json["response"] as? [String: Any])?["usage"] as? [String: Any]
                return usage.map { [Self.responsesUsage($0)] } ?? []
            case "response.failed":
                let error = (json["response"] as? [String: Any])?["error"] as? [String: Any]
                return [.failed((error?["message"] as? String) ?? "回复失败")]
            case "error":
                return [.failed((json["message"] as? String) ?? "服务返回了错误")]
            default:
                return []
            }

        case .anthropicMessages:
            switch json["type"] as? String {
            case "message_start":
                let usage = (json["message"] as? [String: Any])?["usage"] as? [String: Any]
                return usage.map { [Self.anthropicUsage($0)] } ?? []
            case "content_block_delta":
                guard let delta = json["delta"] as? [String: Any] else { return [] }
                switch delta["type"] as? String {
                case "text_delta": return (delta["text"] as? String).map { [.text($0)] } ?? []
                case "thinking_delta": return (delta["thinking"] as? String).map { [.thinking($0)] } ?? []
                default: return []
                }
            case "message_delta":
                let usage = json["usage"] as? [String: Any]
                return usage.map { [.usage(input: nil, output: $0["output_tokens"] as? Int)] } ?? []
            default:
                return []
            }

        case .googleGenerativeAI:
            var events: [ChatEvent] = []
            let candidates = json["candidates"] as? [[String: Any]]
            let parts = ((candidates?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
            for part in parts {
                guard let text = part["text"] as? String, !text.isEmpty else { continue }
                events.append(part["thought"] as? Bool == true ? .thinking(text) : .text(text))
            }
            if let usage = json["usageMetadata"] as? [String: Any] { events.append(Self.googleUsage(usage)) }
            return events
        }
    }

    // MARK: Usage per protocol (7e, E1)

    /// OpenAI-compatible: cache hits as OpenAI (`prompt_tokens_details.cached_tokens`) or DeepSeek
    /// (`prompt_cache_hit_tokens`) report them; reasoning under `completion_tokens_details`.
    static func completionsUsage(_ usage: [String: Any]) -> ChatEvent {
        let cached = ((usage["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int)
            ?? (usage["prompt_cache_hit_tokens"] as? Int)
        let reasoning = (usage["completion_tokens_details"] as? [String: Any])?["reasoning_tokens"] as? Int
        return .usage(input: usage["prompt_tokens"] as? Int, output: usage["completion_tokens"] as? Int, cached: cached, reasoning: reasoning)
    }

    static func responsesUsage(_ usage: [String: Any]) -> ChatEvent {
        .usage(input: usage["input_tokens"] as? Int, output: usage["output_tokens"] as? Int,
               cached: (usage["input_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int,
               reasoning: (usage["output_tokens_details"] as? [String: Any])?["reasoning_tokens"] as? Int)
    }

    /// Anthropic counts cache reads and writes apart from `input_tokens`; the context sent is all three.
    static func anthropicUsage(_ usage: [String: Any]) -> ChatEvent {
        let read = usage["cache_read_input_tokens"] as? Int
        let written = usage["cache_creation_input_tokens"] as? Int
        let input = (usage["input_tokens"] as? Int).map { $0 + (read ?? 0) + (written ?? 0) }
        return .usage(input: input, output: nil, cached: read)
    }

    /// A whole Responses or Messages body: Anthropic's cache reads and writes join the input, as when streamed.
    static func wholeUsage(_ usage: [String: Any]) -> ChatEvent {
        let read = usage["cache_read_input_tokens"] as? Int
        let written = usage["cache_creation_input_tokens"] as? Int
        let input = (usage["input_tokens"] as? Int).map { $0 + (read ?? 0) + (written ?? 0) }
        let cached = read ?? (usage["input_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int
        return .usage(input: input, output: usage["output_tokens"] as? Int, cached: cached,
                      reasoning: (usage["output_tokens_details"] as? [String: Any])?["reasoning_tokens"] as? Int)
    }

    /// Gemini: thinking is billed as output, so it is added in and also reported as reasoning.
    static func googleUsage(_ usage: [String: Any]) -> ChatEvent {
        let thoughts = usage["thoughtsTokenCount"] as? Int
        let output = (usage["candidatesTokenCount"] as? Int ?? 0) + (thoughts ?? 0)
        return .usage(input: usage["promptTokenCount"] as? Int, output: output,
                      cached: usage["cachedContentTokenCount"] as? Int, reasoning: thoughts)
    }

    /// One streamed chunk: tool calls (put together from their pieces), signatures, the stop reason.
    mutating func toolEvents(_ json: [String: Any]) -> [ChatEvent] {
        switch apiProtocol {
        case .openAICompletions:
            guard let choice = (json["choices"] as? [[String: Any]])?.first else { return [] }
            if let calls = (choice["delta"] as? [String: Any])?["tool_calls"] as? [[String: Any]] {
                for (position, call) in calls.enumerated() {
                    let index = call["index"] as? Int ?? position
                    var partial = partialCalls[index] ?? PartialCall()
                    if let id = call["id"] as? String, !id.isEmpty { partial.id = id }
                    if let function = call["function"] as? [String: Any] {
                        // Some hosts repeat the name in every piece: it is set, the arguments are appended.
                        if let name = function["name"] as? String, !name.isEmpty { partial.name = name }
                        if let piece = function["arguments"] as? String { partial.arguments += piece }
                    }
                    partialCalls[index] = partial
                }
            }
            guard let reason = choice["finish_reason"] as? String else { return [] }
            return flushCalls() + [.stop(Self.completionsStop(reason))]

        case .openAIResponses:
            switch json["type"] as? String {
            case "response.output_item.done":
                guard let item = json["item"] as? [String: Any], item["type"] as? String == "function_call" else { return [] }
                callCount += 1
                return [.toolCall(ToolCall(id: item["call_id"] as? String ?? item["id"] as? String ?? "",
                                           name: item["name"] as? String ?? "", arguments: item["arguments"] as? String ?? "{}"))]
            case "response.completed":
                return [.stop(callCount > 0 ? .toolUse : .end)]
            case "response.incomplete":
                return [.stop(.length)]
            default:
                return []
            }

        case .anthropicMessages:
            switch json["type"] as? String {
            case "content_block_start":
                guard let index = json["index"] as? Int, let block = json["content_block"] as? [String: Any],
                      block["type"] as? String == "tool_use" else { return [] }
                partialCalls[index] = PartialCall(id: block["id"] as? String ?? "", name: block["name"] as? String ?? "")
                return []
            case "content_block_delta":
                guard let delta = json["delta"] as? [String: Any] else { return [] }
                switch delta["type"] as? String {
                case "input_json_delta":
                    if let index = json["index"] as? Int { partialCalls[index]?.arguments += delta["partial_json"] as? String ?? "" }
                    return []
                case "signature_delta":
                    return (delta["signature"] as? String).map { [.thinkingSignature($0)] } ?? []
                default:
                    return []
                }
            case "content_block_stop":
                guard let index = json["index"] as? Int, let call = partialCalls.removeValue(forKey: index) else { return [] }
                callCount += 1
                return [.toolCall(ToolCall(id: call.id, name: call.name, arguments: call.arguments.isEmpty ? "{}" : call.arguments))]
            case "message_delta":
                guard let reason = (json["delta"] as? [String: Any])?["stop_reason"] as? String else { return [] }
                return [.stop(Self.anthropicStop(reason))]
            default:
                return []
            }

        case .googleGenerativeAI:
            var events: [ChatEvent] = []
            let candidate = (json["candidates"] as? [[String: Any]])?.first
            let parts = ((candidate?["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
            for part in parts {
                guard let function = part["functionCall"] as? [String: Any] else { continue }
                callCount += 1
                events.append(.toolCall(ToolCall(id: function["id"] as? String ?? "call_\(callCount)", name: function["name"] as? String ?? "",
                                                 arguments: Self.jsonText(function["args"]), signature: part["thoughtSignature"] as? String)))
            }
            if let reason = candidate?["finishReason"] as? String {
                events.append(.stop(reason == "MAX_TOKENS" ? .length : callCount > 0 ? .toolUse : .end))
            }
            return events
        }
    }

    /// A whole, non-streamed response: text, thinking, usage.
    static func events(whole json: [String: Any], apiProtocol: APIProtocol) -> [ChatEvent] {
        if let message = errorMessage(json) { return [.failed(message)] }
        switch apiProtocol {
        case .openAICompletions:
            var events: [ChatEvent] = []
            if let choices = json["choices"] as? [[String: Any]], let message = choices.first?["message"] as? [String: Any] {
                if let thinking = (message["reasoning_content"] ?? message["reasoning"]) as? String, !thinking.isEmpty {
                    events.append(.thinking(thinking))
                }
                if let text = contentText(message["content"]), !text.isEmpty { events.append(.text(text)) }
            }
            if let usage = json["usage"] as? [String: Any] {
                events.append(Self.completionsUsage(usage))
            }
            return events

        case .openAIResponses:
            var events: [ChatEvent] = []
            for item in json["output"] as? [[String: Any]] ?? [] {
                switch item["type"] as? String {
                case "reasoning":
                    let summary = (item["summary"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n\n")
                    if !summary.isEmpty { events.append(.thinking(summary)) }
                case "message":
                    let text = (item["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined()
                    if !text.isEmpty { events.append(.text(text)) }
                default:
                    break
                }
            }
            if let usage = json["usage"] as? [String: Any] {
                events.append(Self.wholeUsage(usage))
            }
            return events

        case .anthropicMessages:
            var events: [ChatEvent] = []
            for block in json["content"] as? [[String: Any]] ?? [] {
                if block["type"] as? String == "thinking", let thinking = block["thinking"] as? String { events.append(.thinking(thinking)) }
                if block["type"] as? String == "text", let text = block["text"] as? String { events.append(.text(text)) }
            }
            if let usage = json["usage"] as? [String: Any] {
                events.append(Self.wholeUsage(usage))
            }
            return events

        case .googleGenerativeAI:
            return events(chunk: json, apiProtocol: apiProtocol)
        }
    }

    /// A whole, non-streamed response: tool calls, signatures, the stop reason.
    static func wholeToolEvents(_ json: [String: Any], apiProtocol: APIProtocol) -> [ChatEvent] {
        guard errorMessage(json) == nil else { return [] }
        switch apiProtocol {
        case .openAICompletions:
            guard let choice = (json["choices"] as? [[String: Any]])?.first else { return [] }
            let calls = (choice["message"] as? [String: Any])?["tool_calls"] as? [[String: Any]] ?? []
            var events: [ChatEvent] = calls.enumerated().map { index, call in
                let function = call["function"] as? [String: Any]
                return .toolCall(ToolCall(id: call["id"] as? String ?? "call_\(index + 1)", name: function?["name"] as? String ?? "",
                                          arguments: function?["arguments"] as? String ?? "{}"))
            }
            if let reason = choice["finish_reason"] as? String { events.append(.stop(completionsStop(reason))) }
            return events

        case .openAIResponses:
            var events: [ChatEvent] = []
            for item in json["output"] as? [[String: Any]] ?? [] where item["type"] as? String == "function_call" {
                events.append(.toolCall(ToolCall(id: item["call_id"] as? String ?? item["id"] as? String ?? "",
                                                 name: item["name"] as? String ?? "", arguments: item["arguments"] as? String ?? "{}")))
            }
            events.append(.stop(json["status"] as? String == "incomplete" ? .length : events.isEmpty ? .end : .toolUse))
            return events

        case .anthropicMessages:
            var events: [ChatEvent] = []
            for block in json["content"] as? [[String: Any]] ?? [] {
                if block["type"] as? String == "thinking", let signature = block["signature"] as? String {
                    events.append(.thinkingSignature(signature))
                }
                if block["type"] as? String == "tool_use" {
                    events.append(.toolCall(ToolCall(id: block["id"] as? String ?? "", name: block["name"] as? String ?? "",
                                                     arguments: jsonText(block["input"]))))
                }
            }
            if let reason = json["stop_reason"] as? String { events.append(.stop(anthropicStop(reason))) }
            return events

        case .googleGenerativeAI:
            var decoder = ChatStreamDecoder(apiProtocol: apiProtocol)
            return decoder.toolEvents(json)
        }
    }

    private mutating func flushCalls() -> [ChatEvent] {
        let calls = partialCalls.sorted { $0.key < $1.key }.map(\.value)
        partialCalls = [:]
        callCount += calls.count
        return calls.map { .toolCall(ToolCall(id: $0.id, name: $0.name, arguments: $0.arguments.isEmpty ? "{}" : $0.arguments)) }
    }

    private static func completionsStop(_ reason: String) -> ChatStop {
        switch reason {
        case "length": .length
        case "tool_calls", "function_call": .toolUse
        default: .end
        }
    }

    private static func anthropicStop(_ reason: String) -> ChatStop {
        switch reason {
        case "max_tokens": .length
        case "tool_use": .toolUse
        default: .end
        }
    }

    private static func jsonText(_ value: Any?) -> String {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// `content` is a string for nearly everyone; some hosts stream an array of `{text}` parts (omp).
    private static func contentText(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let parts = value as? [[String: Any]] { return parts.compactMap { $0["text"] as? String }.joined() }
        return nil
    }
}

/// Streams one reply. The transport yields lines, so tests can play recorded streams.
struct ChatClient: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, Error>)

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = ChatWire.idleTimeout
        configuration.timeoutIntervalForResource = 15 * 60
        return URLSession(configuration: configuration)
    }()

    /// Reading happens off the main thread — the old app's stream froze the window when it didn't (2026-09-06).
    static let live: Transport = { request in
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw ChatFailure.network("不是 HTTP 响应") }
        let lines = AsyncThrowingStream<String, Error> { continuation in
            let task = Task.detached {
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

    init(transport: @escaping Transport = ChatClient.live) {
        self.transport = transport
    }

    func stream(_ request: URLRequest, apiProtocol: APIProtocol) -> AsyncThrowingStream<ChatEvent, Error> {
        let transport = transport
        return AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    let (response, lines) = try await transport(request)
                    guard (200..<300).contains(response.statusCode) else {
                        var body = ""
                        for try await line in lines {
                            body += line + "\n"
                            if body.utf8.count > 16_000 { break }
                        }
                        let message = ProviderClient.providerMessage(from: Data(body.utf8))
                        AppLog.warn("model", "HTTP \(response.statusCode) \(request.url?.host() ?? "") \(message?.prefix(200) ?? "")")
                        throw ChatFailure.http(status: response.statusCode, message: message)
                    }
                    var decoder = ChatStreamDecoder(apiProtocol: apiProtocol)
                    for try await line in lines {
                        for event in decoder.feed(line) { continuation.yield(event) }
                    }
                    for event in decoder.finish() { continuation.yield(event) }
                    continuation.finish()
                } catch {
                    let failure = ChatFailure.from(error)
                    if failure != .cancelled { AppLog.warn("model", "请求中断 \(request.url?.host() ?? "") \(String(describing: failure).prefix(200))") }
                    continuation.finish(throwing: failure)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
