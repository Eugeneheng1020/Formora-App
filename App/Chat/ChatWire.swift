import CryptoKit
import Foundation

/// One turn of what is sent to the model.
struct ChatTurn: Equatable, Sendable {
    enum Role: String, Sendable {
        case user, assistant, tool
    }

    var role: Role
    var text: String
    /// Assistant turns: the tools it called; their results are the tool turns after it (7b).
    var toolCalls: [ToolCall] = []
    /// Tool turns: the call answered, its tool, and whether it went wrong.
    var callID: String?
    var toolName: String?
    var isError = false
    /// Assistant tool-call turns since the user last spoke: the thinking some providers want back (L7).
    var thinking: String?
    var thinkingSignature: String?
    /// User and tool turns: pictures the model sees with the words (7j, V1).
    var images: [ChatImage] = []
}

/// Where one reply goes: a provider's host, its key, the model.
struct ChatTarget: Sendable {
    let providerID: String
    let modelID: String
    let endpoint: ProviderEndpoint
    let key: String
    /// The model's output limit when the catalog knows it (Anthropic needs `max_tokens`).
    var maxOutput: Int?
    /// Headers of the account behind the key: ChatGPT's account (7i, U3).
    var headers: [String: String] = [:]
    /// The conversation a request belongs to — the ChatGPT backend caches per session (omp's Codex wire); `nil` for a
    /// one-off request.
    var session: String?
}

/// How a provider wants the reasoning level said — omp's `thinkingFormat` for OpenAI-compatible hosts, and
/// one encoder per other protocol.
enum ReasoningDialect: Equatable, Sendable {
    /// `reasoning_effort` (MiniMax, custom hosts).
    case openAIEffort
    /// `thinking: {type}` plus `reasoning_effort`.
    case deepSeek
    /// `enable_thinking` (DashScope compatible mode).
    case qwen
    /// `thinking: {type: enabled | disabled}` (Z.AI, Moonshot).
    case zai
    /// `reasoning: {effort}` or `{enabled: false}`.
    case openRouter
    /// `reasoning: {effort, summary}` (OpenAI Responses).
    case responses
    /// `thinking: {type: enabled, budget_tokens}`.
    case anthropic
    /// `generationConfig.thinkingConfig`.
    case google

    static func of(providerID: String, apiProtocol: APIProtocol) -> ReasoningDialect {
        switch apiProtocol {
        case .openAIResponses: return .responses
        case .anthropicMessages: return .anthropic
        case .googleGenerativeAI: return .google
        case .openAICompletions:
            switch providerID {
            case "deepseek": return .deepSeek
            case "qwen": return .qwen
            case "zai", "moonshot": return .zai
            case "openrouter": return .openRouter
            default: return .openAIEffort
            }
        }
    }
}

/// Request bodies for the four protocols (omp `openai-completions.ts`, `openai-responses.ts`, `anthropic.ts`,
/// `google.ts`): the system prompt, the history with its tool calls and results, the tools on offer.
enum ChatWire {
    /// The longest silence allowed between two pieces of a streamed reply.
    static let idleTimeout: TimeInterval = 90
    /// The beta that unlocks `output_config.effort` on Anthropic's API (omp `effortBeta`).
    static let anthropicEffortBeta = "effort-2025-11-24"

    /// omp `ANTHROPIC_THINKING`.
    static func anthropicBudget(_ level: ReasoningLevel) -> Int? {
        switch level {
        case .auto, .off: nil
        case .minimal: 1024
        case .low: 4096
        case .medium: 8192
        case .high: 16384
        case .xhigh, .max: 32768
        }
    }

    /// omp `GOOGLE_THINKING`; 关闭 is a zero budget.
    static func googleBudget(_ level: ReasoningLevel) -> Int? {
        switch level {
        case .auto: nil
        case .off: 0
        case .minimal: 1024
        case .low: 4096
        case .medium: 8192
        case .high: 16384
        case .xhigh: 24575
        case .max: 32768
        }
    }

    /// `reasoning_effort` as most OpenAI-compatible hosts accept it (no xhigh there).
    static func completionsEffort(_ level: ReasoningLevel) -> String? {
        switch level {
        case .auto, .off: nil
        case .minimal: "minimal"
        case .low: "low"
        case .medium: "medium"
        case .high, .xhigh, .max: "high"
        }
    }

    static func responsesEffort(_ level: ReasoningLevel) -> String? {
        switch level {
        case .auto: nil
        case .off: "none"
        case .minimal: "minimal"
        case .low: "low"
        case .medium: "medium"
        case .high: "high"
        case .xhigh, .max: "xhigh"
        }
    }

    static func path(for apiProtocol: APIProtocol, modelID: String) -> String {
        switch apiProtocol {
        case .openAICompletions: return "/chat/completions"
        case .openAIResponses: return "/responses"
        case .anthropicMessages: return "/v1/messages"
        case .googleGenerativeAI:
            let model = modelID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? modelID
            return "/models/\(model):streamGenerateContent?alt=sse"
        }
    }

    /// `sendsReasoning == false` leaves every reasoning field out — 自动, and the retry after a host refused them.
    static func request(_ target: ChatTarget, system: String? = nil, history: [ChatTurn], reasoning: ReasoningLevel,
                        sendsReasoning: Bool, tools: [ToolSpec] = []) -> URLRequest? {
        let apiProtocol = target.endpoint.apiProtocol
        // 10a: nothing leaves with a secret in it (Y1, Y4).
        let shielded = shielded(system: system, history: history)
        // A ChatGPT plan (7i, U3): Codex's Responses endpoint, which wants instructions every time.
        let isChatGPT = target.providerID == ChatGPTAuth.providerID
        let path = isChatGPT ? ChatGPTAuth.responsesPath : path(for: apiProtocol, modelID: target.modelID)
        let system = isChatGPT ? (shielded.system.flatMap { $0.isEmpty ? nil : $0 } ?? ChatGPTAuth.defaultInstructions) : shielded.system
        // Keys in a fixed order (user 2026-09-18): a Swift dictionary hands its keys over in an order of its own each
        // time, so the same request read differently on every call — and a provider's cache, automatic or asked for,
        // matches the beginning of a request byte for byte. The tools come first; with their keys shuffled, nothing
        // after them was ever read from the cache (DeepSeek, three calls of one run: 6%).
        let object = body(target, system: system, history: shielded.history, reasoning: reasoning, sendsReasoning: sendsReasoning, tools: tools)
        guard var request = target.endpoint.request(path, key: target.key),
              let body = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        if let folder = requestDumpFolder { dump(body, to: folder) }
        request.httpMethod = "POST"
        request.timeoutInterval = idle(for: target)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        // Anthropic's effort field (Claude 4.6+ / 5, user 2026-09-18) is behind a beta header.
        if apiProtocol == .anthropicMessages, object["output_config"] != nil {
            request.setValue(anthropicEffortBeta, forHTTPHeaderField: "anthropic-beta")
        }
        for (name, value) in target.headers { request.setValue(value, forHTTPHeaderField: name) }
        if isChatGPT { ChatGPTAuth.addHeaders(&request, session: target.session, model: target.modelID) }
        request.httpBody = body
        return request
    }

    /// 10a (Y1, Y4): the turns' words and calls and the system prompt with secrets behind placeholders, and one line in the
    /// system prompt when anything was hidden. Thinking goes as it came: a signed block must not change, and it was kept
    /// with its placeholders.
    static func shielded(system: String?, history: [ChatTurn], shield: SecretShield = .shared) -> (system: String?, history: [ChatTurn]) {
        var hidden = false
        func hide(_ text: String, typedByUser: Bool = false) -> String {
            let result = shield.hide(text, typedByUser: typedByUser)
            if result.hidden { hidden = true }
            return result.text
        }
        let turns = history.map { turn -> ChatTurn in
            var turn = turn
            // D93: in what the user typed, a key in any format after 令牌 / key / token.
            turn.text = hide(turn.text, typedByUser: turn.role == .user)
            turn.toolCalls = turn.toolCalls.map { call in
                var call = call
                call.arguments = hide(call.arguments)
                return call
            }
            return turn
        }
        var system = system.map { hide($0) }
        if hidden { system = (system.map { $0 + "\n\n" } ?? "") + SecretShield.note }
        return (system, turns)
    }

    /// The system prompt goes where each protocol wants it: a leading system message, `instructions`, `system`,
    /// `systemInstruction`. So do the tools, and the calls and results in the history.
    /// QA only (`-FormoraDumpRequests <folder>`, user 2026-09-18): every request body as it leaves, one file a call, so two
    /// calls can be compared byte for byte — what a provider's cache does. A body never holds a key (that is a header).
    nonisolated(unsafe) static var requestDumpFolder: URL?
    nonisolated(unsafe) private static var dumped = 0

    private static func dump(_ body: Data, to folder: URL) {
        dumped += 1
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? body.write(to: folder.appendingPathComponent(String(format: "%04d.json", dumped)))
    }

    /// Claude through OpenRouter: the one OpenAI-compatible route whose cache has to be asked for. Only there — another
    /// host may not know the field.
    static func wantsCacheControl(_ target: ChatTarget) -> Bool {
        target.endpoint.apiProtocol == .openAICompletions && target.modelID.lowercased().hasPrefix("anthropic/")
            && URL(string: target.endpoint.baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased().hasSuffix("openrouter.ai") == true
    }

    /// The level a request to `target` carries (user 2026-09-18): the conversation's, brought onto the model's own
    /// ladder — omp's row when there is one, the encoder's levels otherwise. `nil` row = nothing known of the model.
    static func resolve(_ reasoning: ReasoningLevel, for target: ChatTarget) -> (level: ReasoningLevel, profile: ModelThinking.Profile?) {
        let apiProtocol = target.endpoint.apiProtocol
        let base = target.endpoint.baseURL
        let profile = ModelThinking.profile(providerID: target.providerID, modelID: target.modelID, apiProtocol: apiProtocol, baseURL: base)
        let levels = ModelThinking.levels(providerID: target.providerID, modelID: target.modelID, apiProtocol: apiProtocol, baseURL: base)
        return (ModelThinking.clamp(reasoning, to: levels), profile)
    }

    static func body(_ target: ChatTarget, system: String? = nil, history: [ChatTurn], reasoning: ReasoningLevel,
                     sendsReasoning: Bool, tools: [ToolSpec] = []) -> [String: Any] {
        let resolved = resolve(sendsReasoning ? reasoning : .auto, for: target)
        let level = resolved.level
        // The row's transport applies only when it was recorded on the protocol this request speaks.
        let profile = resolved.profile.flatMap { $0.matchesWire ? $0 : nil }
        // omp's compat flags for this model (user 2026-09-18: 「兼容开关参照 omp 来」), when its row is this wire.
        let row = row(for: target)
        let dialect = effectiveDialect(ReasoningDialect.of(providerID: target.providerID, apiProtocol: target.endpoint.apiProtocol), row: row)
        let system = system.flatMap { $0.isEmpty ? nil : $0 }
        switch target.endpoint.apiProtocol {
        case .openAICompletions:
            var messages: [[String: Any]] = system.map { [["role": "system", "content": $0]] } ?? []
            // Thinking back on the tool rounds since the user spoke: DeepSeek and Z.ai always did (L7); the table adds every
            // model that needs it (Kimi K3, OpenRouter's reasoning models). A round without any gets an empty one where
            // the model takes that (DeepSeek, measured; the table's `allowsSynthetic…`) — Z.ai's way is below.
            let returnsThinking = dialect == .deepSeek || dialect == .zai || row?.compat.bool("requiresReasoningContentForToolCalls") == true
            let fillsThinking = level != .off && dialect != .zai
                && (dialect == .deepSeek || row?.compat.bool("allowsSyntheticReasoningContentForToolCalls") == true)
            messages += completionsMessages(history, returnsThinking: returnsThinking, fillsThinking: fillsThinking,
                                            assistantContent: row?.compat.bool("requiresAssistantContentForToolCalls") == true)
            var body: [String: Any] = [
                "model": target.modelID,
                "stream": true,
                "stream_options": ["include_usage": true],
                "messages": messages,
            ]
            if !tools.isEmpty {
                body["tools"] = tools.map { ["type": "function", "function": ["name": $0.name, "description": $0.description, "parameters": $0.schema]] }
            }
            // A host that cuts replies short without a limit (Kimi K3): the model's own output limit, in the field it reads.
            if row?.compat.bool("alwaysSendMaxTokens") == true, let limit = row?.maxOutput ?? target.maxOutput {
                body[row?.compat.string("maxTokensField") ?? "max_tokens"] = limit
            }
            applyCompletionsReasoning(&body, dialect: dialect, level: level, profile: profile, row: row)
            // 提示词缓存 (user 2026-09-17)：OpenAI、DeepSeek、Gemini 在服务端自动缓存，但 OpenRouter 上的 Claude 不会——要在请求
            // 顶层写 cache_control，OpenRouter 才替它在最后一个可缓存的块上打断点、随对话往前挪（它的文档：automatic caching，
            // Anthropic / Vertex / Bedrock / Azure 各路由都支持）。没有这一行，每一步都按全价重发整段历史。
            if Self.wantsCacheControl(target) { body["cache_control"] = ["type": "ephemeral"] }
            // DeepSeek and Z.ai, thinking, want every tool-call round since the last user message back with its thinking
            // (L7), and refuse the request without it (400). A round without any — the model didn't think that step, or a
            // fallback model did it — used to turn thinking off for the request (user 2026-09-14). 真实测试 2026-09-18：
            // 这样一来同一次运行里思考开一下关一下，服务端渲染出来的整段前缀跟着变，那一次调用的缓存全丢（每次运行的最后
            // 一步从 96% 掉到 0）。DeepSeek 接受空的 reasoning_content：补一个空值，思考一直开着，前缀不变。Z.ai / Moonshot
            // 没实测过空值，仍旧这一次不思考。
            if dialect == .zai, lacksThinking(history) {
                body["thinking"] = ["type": "disabled"]
                body["reasoning_effort"] = nil
            }
            return body

        case .openAIResponses:
            var body: [String: Any] = [
                "model": target.modelID,
                "stream": true,
                "store": false,
                "input": responsesInput(history, shortIDs: row?.compat.bool("usesOpenAIToolCallIdLimit") == true),
            ]
            if let system { body["instructions"] = system }
            if !tools.isEmpty {
                body["tools"] = tools.map { ["type": "function", "name": $0.name, "description": $0.description, "parameters": $0.schema] }
            }
            let effort: String? = if let profile { level == .off ? "none" : rowEffort(level, profile) } else { responsesEffort(level) }
            if let effort = effort.map({ mapped($0, row) }) {
                // Grok's Responses has no reasoning summary (the table's `supportsReasoningSummary`).
                let summary = effort != "none" && row?.compat.bool("supportsReasoningSummary") != false
                body["reasoning"] = summary ? ["effort": effort, "summary": "auto"] : ["effort": effort]
            }
            return body

        case .anthropicMessages:
            let limit = target.maxOutput ?? 32_000
            // 提示词缓存 (user 2026-09-16): Anthropic 要显式标 cache_control（OpenAI/DeepSeek/Gemini 等是服务端自动缓存，
            // 不用标）。请求前缀顺序是 tools → system → messages：给 system 打一个断点就把 tools+system 这段稳定前缀缓存了；
            // 再给最后一条消息打一个断点，把不断增长的历史前缀也缓存起来，后续每轮只为新增部分付全价。5 分钟内命中按约 1 折计费。
            var messages = anthropicMessages(history)
            Self.markCache(lastOf: &messages)
            var body: [String: Any] = [
                "model": target.modelID,
                "stream": true,
                "messages": messages,
            ]
            if let system {
                body["system"] = [["type": "text", "text": system, "cache_control": ["type": "ephemeral"]]]
            }
            if !tools.isEmpty {
                var toolList: [[String: Any]] = tools.map { ["name": $0.name, "description": $0.description, "input_schema": $0.schema] }
                // 没有 system 时，缓存断点落在最后一个工具上，让 tools 这段也缓存。
                if system == nil, !toolList.isEmpty { toolList[toolList.count - 1]["cache_control"] = ["type": "ephemeral"] }
                body["tools"] = toolList
            }
            // Claude 4.6+ / 5 (omp's `anthropic-adaptive`, user 2026-09-18): adaptive thinking steered by an effort, no
            // token budget; Fable/Mythos 5 return no thinking unless `display` asks for it. These models reject
            // `thinking: disabled` — 关闭 leaves the field out and pins the effort low (omp's way). The effort field
            // needs the `effort-2025-11-24` beta, which `request` adds when `output_config` is here.
            if let profile, profile.mode == .anthropicAdaptive {
                if level == .off {
                    body["output_config"] = ["effort": "low"]
                } else if let effort = rowEffort(level, profile) {
                    var adaptive = ["type": "adaptive"]
                    if profile.supportsDisplay { adaptive["display"] = "summarized" }
                    body["thinking"] = adaptive
                    body["output_config"] = ["effort": effort]
                }
                body["max_tokens"] = min(limit, 32_000)
            } else if let budget = anthropicBudget(level) {
                // The budget has to fit under max_tokens with room left for the answer.
                let fitted = max(1024, min(budget, limit - 4096))
                body["thinking"] = ["type": "enabled", "budget_tokens": fitted]
                body["max_tokens"] = min(limit, fitted + 16_000)
                // omp's `anthropic-budget-effort` (GLM on an Anthropic-style endpoint): the budget and the effort both.
                if let profile, profile.mode == .anthropicBudgetEffort, let effort = rowEffort(level, profile) {
                    body["output_config"] = ["effort": effort]
                }
            } else {
                body["max_tokens"] = min(limit, 32_000)
            }
            return body

        case .googleGenerativeAI:
            var body: [String: Any] = ["contents": googleContents(history)]
            if let system { body["systemInstruction"] = ["parts": [["text": system]]] }
            if !tools.isEmpty {
                body["tools"] = [["functionDeclarations": tools.map { ["name": $0.name, "description": $0.description, "parameters": $0.schema] }]]
            }
            // Gemini 3 (omp's `google-level`, user 2026-09-18): a named level, not a budget; most can't be turned off
            // (the level was brought onto the row's ladder above). Older Gemini keeps the budget, 关闭 a budget of zero.
            if let profile, profile.mode == .googleLevel {
                if level == .off {
                    body["generationConfig"] = ["thinkingConfig": ["includeThoughts": false, "thinkingLevel": "MINIMAL"]]
                } else if let effort = rowEffort(level, profile) {
                    body["generationConfig"] = ["thinkingConfig": ["includeThoughts": true, "thinkingLevel": googleLevel(effort)]]
                }
            } else if sendsReasoning, level != .auto {
                var config: [String: Any] = ["includeThoughts": level != .off]
                if let budget = googleBudget(level) { config["thinkingBudget"] = budget }
                body["generationConfig"] = ["thinkingConfig": config]
            }
            return body
        }
    }

    // MARK: History per protocol

    private static func arguments(_ call: ToolCall) -> String {
        call.arguments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "{}" : call.arguments
    }

    private static func object(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data((json.isEmpty ? "{}" : json).utf8))) as? [String: Any] ?? [:]
    }

    /// Said before the pictures a tool returned, where they travel in a user message of their own (V3).
    static let resultImagesNote = "上面工具结果里的图片："

    /// A tool message takes only text here, so a batch's pictures follow the results as a user message (V3).
    private static func completionsMessages(_ history: [ChatTurn], returnsThinking: Bool, fillsThinking: Bool = false,
                                            assistantContent: Bool = false) -> [[String: Any]] {
        // Rounds since the last user turn are the ones whose thinking goes back.
        let current = (history.lastIndex { $0.role == .user } ?? -1) + 1
        func image(_ picture: ChatImage) -> [String: Any] { ["type": "image_url", "image_url": ["url": picture.dataURL]] }
        var messages: [[String: Any]] = []
        var pending: [ChatImage] = []
        func flush() {
            guard !pending.isEmpty else { return }
            messages.append(["role": "user", "content": [["type": "text", "text": resultImagesNote]] + pending.map(image)])
            pending = []
        }
        for (index, turn) in history.enumerated() {
            if turn.role != .tool { flush() }
            switch turn.role {
            case .user:
                if turn.images.isEmpty {
                    messages.append(["role": "user", "content": turn.text])
                } else {
                    let words: [[String: Any]] = turn.text.isEmpty ? [] : [["type": "text", "text": turn.text]]
                    messages.append(["role": "user", "content": words + turn.images.map(image)])
                }
            case .tool:
                messages.append(["role": "tool", "tool_call_id": turn.callID ?? "", "content": turn.text])
                pending += turn.images
            case .assistant:
                var message: [String: Any] = ["role": "assistant", "content": turn.text]
                if !turn.toolCalls.isEmpty {
                    // Some hosts refuse a null content beside the calls (the table's `requiresAssistantContentForToolCalls`).
                    if turn.text.isEmpty { message["content"] = assistantContent ? "" : NSNull() }
                    message["tool_calls"] = turn.toolCalls.map { call -> [String: Any] in
                        ["id": call.id, "type": "function", "function": ["name": call.name, "arguments": arguments(call)]]
                    }
                    if returnsThinking, let thinking = turn.thinking ?? (fillsThinking && index >= current ? "" : nil) {
                        message["reasoning_content"] = thinking
                    }
                }
                messages.append(message)
            }
        }
        flush()
        return messages
    }

    private static func responsesInput(_ history: [ChatTurn], shortIDs: Bool = false) -> [[String: Any]] {
        func id(_ raw: String) -> String { shortIDs ? shortID(raw) : raw }
        func image(_ picture: ChatImage) -> [String: Any] { ["type": "input_image", "image_url": picture.dataURL] }
        var input: [[String: Any]] = []
        var pending: [ChatImage] = []
        func flush() {
            guard !pending.isEmpty else { return }
            input.append(["role": "user", "content": [["type": "input_text", "text": resultImagesNote]] + pending.map(image)])
            pending = []
        }
        for turn in history {
            if turn.role != .tool { flush() }
            switch turn.role {
            case .user:
                if turn.images.isEmpty {
                    input.append(["role": "user", "content": turn.text])
                } else {
                    let words: [[String: Any]] = turn.text.isEmpty ? [] : [["type": "input_text", "text": turn.text]]
                    input.append(["role": "user", "content": words + turn.images.map(image)])
                }
            case .tool:
                input.append(["type": "function_call_output", "call_id": id(turn.callID ?? ""), "output": turn.text])
                pending += turn.images
            case .assistant:
                if !turn.text.isEmpty { input.append(["role": "assistant", "content": turn.text]) }
                for call in turn.toolCalls {
                    input.append(["type": "function_call", "call_id": id(call.id), "name": call.name, "arguments": arguments(call)])
                }
            }
        }
        flush()
        return input
    }

    /// Content blocks merged by role — the API wants user and assistant to alternate, and one turn's tool results
    /// in one user message. A message that is a single text block goes as a plain string.
    /// 提示词缓存 (user 2026-09-16): put a cache_control breakpoint on the last message's last content block, so each
    /// turn reuses the cached conversation prefix and pays full price only for what is new. Anthropic ignores it when
    /// the prefix is too small, so it is always safe to add.
    private static func markCache(lastOf messages: inout [[String: Any]]) {
        guard !messages.isEmpty else { return }
        var last = messages[messages.count - 1]
        if let text = last["content"] as? String {
            last["content"] = [["type": "text", "text": text, "cache_control": ["type": "ephemeral"]]]
        } else if var blocks = last["content"] as? [[String: Any]], !blocks.isEmpty {
            blocks[blocks.count - 1]["cache_control"] = ["type": "ephemeral"]
            last["content"] = blocks
        }
        messages[messages.count - 1] = last
    }

    private static func anthropicMessages(_ history: [ChatTurn]) -> [[String: Any]] {
        func image(_ picture: ChatImage) -> [String: Any] {
            ["type": "image", "source": ["type": "base64", "media_type": picture.mediaType, "data": picture.base64]]
        }
        var messages: [(role: String, blocks: [[String: Any]])] = []
        for turn in history {
            let role = turn.role == .assistant ? "assistant" : "user"
            var blocks: [[String: Any]] = []
            switch turn.role {
            case .user:
                if !turn.text.isEmpty { blocks.append(["type": "text", "text": turn.text]) }
                blocks += turn.images.map(image)
            case .tool:
                // A result may carry its pictures itself (V3) — except an error's: Anthropic takes only text in an error
                // result, so its pictures follow it as the user's own blocks (demo 2026-09-15: a failed step's screenshot).
                let inline = turn.images.isEmpty || turn.isError
                let content: Any = inline ? turn.text : [["type": "text", "text": turn.text]] + turn.images.map(image)
                var block: [String: Any] = ["type": "tool_result", "tool_use_id": turn.callID ?? "", "content": content]
                if turn.isError { block["is_error"] = true }
                blocks.append(block)
                if turn.isError { blocks += turn.images.map(image) }
            case .assistant:
                if let thinking = turn.thinking, let signature = turn.thinkingSignature {
                    blocks.append(["type": "thinking", "thinking": thinking, "signature": signature])
                }
                if !turn.text.isEmpty { blocks.append(["type": "text", "text": turn.text]) }
                for call in turn.toolCalls {
                    blocks.append(["type": "tool_use", "id": call.id, "name": call.name, "input": object(call.arguments)])
                }
            }
            guard !blocks.isEmpty else { continue }
            if let last = messages.last, last.role == role {
                messages[messages.count - 1].blocks += blocks
            } else {
                messages.append((role, blocks))
            }
        }
        return messages.map { message -> [String: Any] in
            if message.blocks.count == 1, message.blocks[0]["type"] as? String == "text", let text = message.blocks[0]["text"] as? String {
                return ["role": message.role, "content": text]
            }
            return ["role": message.role, "content": message.blocks]
        }
    }

    /// Gemini has no call ids: a function response names its function, and one turn's responses share a turn.
    private static func googleContents(_ history: [ChatTurn]) -> [[String: Any]] {
        func image(_ picture: ChatImage) -> [String: Any] { ["inlineData": ["mimeType": picture.mediaType, "data": picture.base64]] }
        var contents: [(role: String, parts: [[String: Any]])] = []
        var pending: [ChatImage] = []
        // A batch's pictures come in a user turn of their own after the function responses (V3).
        func flush() {
            guard !pending.isEmpty else { return }
            contents.append(("user", [["text": resultImagesNote]] + pending.map(image)))
            pending = []
        }
        for turn in history {
            if turn.role != .tool { flush() }
            let role = turn.role == .assistant ? "model" : "user"
            var parts: [[String: Any]] = []
            switch turn.role {
            case .user:
                if !turn.text.isEmpty { parts.append(["text": turn.text]) }
                parts += turn.images.map(image)
            case .tool:
                parts.append(["functionResponse": ["name": turn.toolName ?? "", "response": ["content": turn.text]]])
                pending += turn.images
            case .assistant:
                if !turn.text.isEmpty { parts.append(["text": turn.text]) }
                for call in turn.toolCalls {
                    var part: [String: Any] = ["functionCall": ["name": call.name, "args": object(call.arguments)]]
                    if let signature = call.signature { part["thoughtSignature"] = signature }
                    parts.append(part)
                }
            }
            guard !parts.isEmpty else { continue }
            if let last = contents.last, last.role == role {
                contents[contents.count - 1].parts += parts
            } else {
                contents.append((role, parts))
            }
        }
        flush()
        return contents.map { ["role": $0.role, "parts": $0.parts] }
    }

    /// A tool-call round since the last user turn without the thinking that went with it.
    static func lacksThinking(_ history: [ChatTurn]) -> Bool {
        let start = (history.lastIndex { $0.role == .user } ?? -1) + 1
        return history[start...].contains { $0.role == .assistant && !$0.toolCalls.isEmpty && ($0.thinking ?? "").isEmpty }
    }

    /// With omp's row for the model (`profile`, mode `effort`), the level goes as the row has it — DeepSeek V4 and Kimi K3
    /// take `max`, Kimi K2.6 `minimal`; the host's own switch field stays. Without a row, the old collapse.
    private static func applyCompletionsReasoning(_ body: inout [String: Any], dialect: ReasoningDialect, level: ReasoningLevel,
                                                  profile: ModelThinking.Profile?, row: ModelCatalog.Model? = nil) {
        guard level != .auto else { return }
        let on = level != .off
        let word: String? = if let profile, profile.mode == .effort { rowEffort(level, profile) } else { completionsEffort(level) }
        let effort = word.map { mapped($0, row) }
        switch dialect {
        case .deepSeek:
            body["thinking"] = ["type": on ? "enabled" : "disabled"]
            if let effort { body["reasoning_effort"] = profile == nil && effort == "minimal" ? "low" : effort }
        case .qwen:
            body["enable_thinking"] = on
        case .zai:
            body["thinking"] = ["type": on ? "enabled" : "disabled"]
            if profile != nil, let effort { body["reasoning_effort"] = effort }
        case .openRouter:
            if let effort {
                body["reasoning"] = ["effort": effort]
            } else {
                body["reasoning"] = ["enabled": false]
            }
        case .openAIEffort, .responses, .anthropic, .google:
            if let effort { body["reasoning_effort"] = effort }
        }
    }

    /// omp's row for the model a request goes to, when it was recorded on the protocol the request speaks — only then do
    /// its compat flags apply (1.0.21's rule).
    static func row(for target: ChatTarget) -> ModelCatalog.Model? {
        guard let row = ModelCatalog.model(providerID: target.providerID, modelID: target.modelID, baseURL: target.endpoint.baseURL),
              row.matches(target.endpoint.apiProtocol) else { return nil }
        return row
    }

    /// The longest silence this model's stream may keep (the table's `streamIdleTimeoutMs`: DeepSeek 5 minutes; 0 = none,
    /// ten minutes here); 90 seconds otherwise.
    static func idle(for target: ChatTarget) -> TimeInterval {
        guard let ms = row(for: target)?.compat.int("streamIdleTimeoutMs") else { return idleTimeout }
        return ms == 0 ? 600 : TimeInterval(ms) / 1000
    }

    /// A host Formora has no dialect of its own for (a custom platform, MiniMax) speaks the one its model's row names
    /// (`thinkingFormat`): a platform's Qwen wants `enable_thinking`. The built-in dialects stay — they are verified.
    static func effectiveDialect(_ dialect: ReasoningDialect, row: ModelCatalog.Model?) -> ReasoningDialect {
        guard dialect == .openAIEffort else { return dialect }
        switch row?.compat.string("thinkingFormat") {
        case "qwen": return .qwen
        case "zai": return .zai
        case "openrouter": return .openRouter
        default: return dialect
        }
    }

    /// The row's own word for an effort (`reasoningEffortMap`: Grok's minimal is low, Kimi K3's medium is high).
    static func mapped(_ effort: String, _ row: ModelCatalog.Model?) -> String { row?.compat.map("reasoningEffortMap")[effort] ?? effort }

    /// A call id OpenAI takes (at most 40 characters, `usesOpenAIToolCallIdLimit`): a longer one — another provider's —
    /// becomes a short stable one, the same for the call and its result.
    static func shortID(_ id: String) -> String {
        guard id.count > 40 else { return id }
        return "call_" + SHA256.hash(data: Data(id.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// The row's own word for the level: `nil` for 自动 and 关闭 (each protocol says those its own way) and for a level
    /// the row lacks — which `resolve` has already brought onto the ladder.
    static func rowEffort(_ level: ReasoningLevel, _ profile: ModelThinking.Profile) -> String? {
        guard level != .auto, level != .off, profile.efforts.contains(level) else { return nil }
        return level.rawValue
    }

    /// Gemini 3's `thinkingLevel` for a level (omp `mapEffortToGoogleThinkingLevel`): xhigh and max are HIGH.
    static func googleLevel(_ effort: String) -> String {
        switch effort {
        case "minimal": "MINIMAL"
        case "low": "LOW"
        case "medium": "MEDIUM"
        default: "HIGH"
        }
    }
}

/// Text rules for replies.
enum ChatText {
    /// DeepSeek leaks chat-template tokens like `<｜tool_calls_begin｜>` into content (omp
    /// `stripDeepseekSpecialTokens`); the full-width bar never appears in ordinary prose.
    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "<｜[^｜]{0,64}｜>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The history sent with a message: the user's words (and which attachments), the Agent's answers, its tool
    /// calls each followed by its result. Failed replies stay out; text turns of the same side are joined, since
    /// some protocols insist on alternation. In a group (`as` = the Agent about to answer), the other members'
    /// replies come in on the user's side, labelled with who said them — context, not the model's own words.
    /// Thinking goes back only on tool-call turns since the user last spoke (7b, L7). Pictures — a message's image
    /// attachments under `root`, a result's images — go along when the model can see them, and are a line saying
    /// so when it can't (7j, V1–V2).
    static func history(_ messages: [Message], as agentID: UUID? = nil, root: URL? = nil, seesImages: Bool = false) -> [ChatTurn] {
        // A compaction (7e, E3): its summary first, then the messages from its boundary on.
        let effective = Compaction.effective(messages)
        let messages = effective.messages
        let lastSpoken = messages.lastIndex { $0.role == .user && !$0.isHidden } ?? -1
        var turns: [ChatTurn] = []
        func add(_ turn: ChatTurn) {
            if let last = turns.last, last.role == turn.role, turn.role != .tool, last.toolCalls.isEmpty {
                let joined = [last.text, turn.text].filter { !$0.isEmpty }.joined(separator: "\n\n")
                turns[turns.count - 1] = turn
                turns[turns.count - 1].text = joined
                turns[turns.count - 1].images = last.images + turn.images
            } else {
                turns.append(turn)
            }
        }
        if let summary = effective.summary { add(ChatTurn(role: .user, text: Compaction.context(summary.summary))) }
        for (index, message) in messages.enumerated() where !message.isUpkeep {
            switch message.role {
            case .user:
                var text = message.text
                if !message.attachments.isEmpty {
                    text += (text.isEmpty ? "" : "\n\n") + "附件：" + message.attachments.map(\.relativePath).joined(separator: "、")
                }
                // `@` files (7d, D3): their text as it was when sent.
                if !message.mentions.isEmpty {
                    text += (text.isEmpty ? "" : "\n\n") + FileMentions.context(message.mentions)
                }
                var images: [ChatImage] = []
                let pictures = message.attachments.filter { $0.kind == .image }
                if let root, !pictures.isEmpty {
                    if seesImages {
                        images = pictures.compactMap { ChatImages.load(root.appendingPathComponent($0.relativePath)) }
                    } else {
                        text += (text.isEmpty ? "" : "\n\n") + ChatImages.unseen(pictures.count)
                    }
                }
                if !text.isEmpty || !images.isEmpty { add(ChatTurn(role: .user, text: text, images: images)) }
            case .agent:
                if message.failure != nil { continue }
                if let agentID, message.agentID != agentID {
                    if !message.text.isEmpty {
                        add(ChatTurn(role: .user, text: "〔\(message.speakerName ?? "另一个角色")的回复〕\n\(message.text)"))
                    }
                    continue
                }
                guard !message.text.isEmpty || !message.toolCalls.isEmpty else { continue }
                let returnsThinking = index > lastSpoken && !message.toolCalls.isEmpty
                // A file written in an earlier run isn't carried along (user 2026-09-17); the run that wrote it still
                // sees what it wrote (2026-09-18) — the history changes here anyway, where the thinking stops going back.
                let settled = index < lastSpoken
                add(ChatTurn(role: .assistant, text: message.text, toolCalls: settled ? message.toolCalls.map(\.forHistory) : message.toolCalls,
                             thinking: returnsThinking ? message.thinking : nil,
                             thinkingSignature: returnsThinking ? message.thinkingSignature : nil))
                for call in message.toolCalls {
                    var output = call.result.map { $0.pruned == true ? Compaction.placeholder($0) : $0.output } ?? "没有执行。"
                    if settled, call.omitsText { output += ToolCall.omittedNote }
                    var images: [ChatImage] = []
                    if let result = call.result, result.pruned != true, let paths = result.images, !paths.isEmpty {
                        if seesImages {
                            images = paths.compactMap { ChatImages.load(URL(fileURLWithPath: $0)) }
                        } else {
                            output += "\n" + ChatImages.unseen(paths.count)
                        }
                    }
                    add(ChatTurn(role: .tool, text: output, callID: call.id, toolName: call.name,
                                 isError: call.result?.status != .done, images: images))
                }
            }
        }
        return turns
    }
}

extension ToolCall {
    /// A text argument longer than this isn't sent again once it is in the file.
    static let writtenTextLimit = 1_500

    /// What the model is sent of a call in later requests (user 2026-09-17). A file written or edited is on disk: its
    /// text needn't ride along as the call's arguments for the rest of the conversation — one 70,000-character HTML
    /// file cost 45,000 tokens on every later step. The path stays, the text becomes a line saying how much there was
    /// and where to read it. Only once the call went through; only what is long; the thread, 撤销 and the file history
    /// keep the call as it was written. Keys are sorted, so the same history reads the same and the provider's cache hits.
    /// The mark that stands for the text: whose it is and what it isn't. The first wording — 「N 字，已经在文件里……」 — a
    /// model read as its own words: 「I accidentally wrote placeholder content?!」, and it read the whole file back to
    /// check (real test, DeepSeek, 2026-09-18), spending more than the mark had saved.
    static func omitted(_ count: Int) -> String {
        "〔系统省略：你这一步写入的完整内容共 \(count) 字，已经写进文件；为节省上下文，历史里不再重复。这行字是系统的标记，不是文件内容。〕"
    }

    /// What the call's result adds once its text was left out — the result is where a model looks for what happened.
    static let omittedNote = "\n〔系统注：上面这次调用的长文本在历史里已省略显示，文件里是你写的完整内容，不用重读核对；确实要看现在的内容再用 read。〕"

    /// Whether `forHistory` leaves text out of this call.
    var omitsText: Bool { forHistory.arguments != arguments }

    var forHistory: ToolCall {
        guard result?.status == .done, name == AgentTools.write.name || name == AgentTools.edit.name,
              arguments.count > Self.writtenTextLimit, var fields = ToolArguments.parse(arguments) else { return self }
        var changed = false
        for key in ["content", "old_text", "new_text"] {
            guard let text = fields[key] as? String, text.count > Self.writtenTextLimit else { continue }
            fields[key] = Self.omitted(text.count)
            changed = true
        }
        guard changed, let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) else { return self }
        var slim = self
        slim.arguments = String(decoding: data, as: UTF8.self)
        return slim
    }
}
