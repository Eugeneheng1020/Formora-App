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
        guard var request = target.endpoint.request(path, key: target.key),
              let body = try? JSONSerialization.data(withJSONObject: body(target, system: system, history: shielded.history, reasoning: reasoning,
                                                                           sendsReasoning: sendsReasoning, tools: tools)) else { return nil }
        request.httpMethod = "POST"
        request.timeoutInterval = idleTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        for (name, value) in target.headers { request.setValue(value, forHTTPHeaderField: name) }
        if isChatGPT { ChatGPTAuth.addHeaders(&request) }
        request.httpBody = body
        return request
    }

    /// 10a (Y1, Y4): the turns' words and calls and the system prompt with secrets behind placeholders, and one line in the
    /// system prompt when anything was hidden. Thinking goes as it came: a signed block must not change, and it was kept
    /// with its placeholders.
    static func shielded(system: String?, history: [ChatTurn], shield: SecretShield = .shared) -> (system: String?, history: [ChatTurn]) {
        var hidden = false
        func hide(_ text: String) -> String {
            let result = shield.hide(text)
            if result.hidden { hidden = true }
            return result.text
        }
        let turns = history.map { turn -> ChatTurn in
            var turn = turn
            turn.text = hide(turn.text)
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
    static func body(_ target: ChatTarget, system: String? = nil, history: [ChatTurn], reasoning: ReasoningLevel,
                     sendsReasoning: Bool, tools: [ToolSpec] = []) -> [String: Any] {
        let level: ReasoningLevel = sendsReasoning ? reasoning : .auto
        let dialect = ReasoningDialect.of(providerID: target.providerID, apiProtocol: target.endpoint.apiProtocol)
        let system = system.flatMap { $0.isEmpty ? nil : $0 }
        switch target.endpoint.apiProtocol {
        case .openAICompletions:
            var messages: [[String: Any]] = system.map { [["role": "system", "content": $0]] } ?? []
            messages += completionsMessages(history, returnsThinking: dialect == .deepSeek || dialect == .zai)
            var body: [String: Any] = [
                "model": target.modelID,
                "stream": true,
                "stream_options": ["include_usage": true],
                "messages": messages,
            ]
            if !tools.isEmpty {
                body["tools"] = tools.map { ["type": "function", "function": ["name": $0.name, "description": $0.description, "parameters": $0.schema]] }
            }
            applyCompletionsReasoning(&body, dialect: dialect, level: level)
            return body

        case .openAIResponses:
            var body: [String: Any] = [
                "model": target.modelID,
                "stream": true,
                "store": false,
                "input": responsesInput(history),
            ]
            if let system { body["instructions"] = system }
            if !tools.isEmpty {
                body["tools"] = tools.map { ["type": "function", "name": $0.name, "description": $0.description, "parameters": $0.schema] }
            }
            if let effort = responsesEffort(level) {
                body["reasoning"] = effort == "none" ? ["effort": effort] : ["effort": effort, "summary": "auto"]
            }
            return body

        case .anthropicMessages:
            let limit = target.maxOutput ?? 32_000
            var body: [String: Any] = [
                "model": target.modelID,
                "stream": true,
                "messages": anthropicMessages(history),
            ]
            if let system { body["system"] = system }
            if !tools.isEmpty {
                body["tools"] = tools.map { ["name": $0.name, "description": $0.description, "input_schema": $0.schema] }
            }
            if let budget = anthropicBudget(level) {
                // The budget has to fit under max_tokens with room left for the answer.
                let fitted = max(1024, min(budget, limit - 4096))
                body["thinking"] = ["type": "enabled", "budget_tokens": fitted]
                body["max_tokens"] = min(limit, fitted + 16_000)
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
            if sendsReasoning {
                var config: [String: Any] = ["includeThoughts": reasoning != .off]
                if let budget = googleBudget(reasoning) { config["thinkingBudget"] = budget }
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
    private static func completionsMessages(_ history: [ChatTurn], returnsThinking: Bool) -> [[String: Any]] {
        func image(_ picture: ChatImage) -> [String: Any] { ["type": "image_url", "image_url": ["url": picture.dataURL]] }
        var messages: [[String: Any]] = []
        var pending: [ChatImage] = []
        func flush() {
            guard !pending.isEmpty else { return }
            messages.append(["role": "user", "content": [["type": "text", "text": resultImagesNote]] + pending.map(image)])
            pending = []
        }
        for turn in history {
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
                    if turn.text.isEmpty { message["content"] = NSNull() }
                    message["tool_calls"] = turn.toolCalls.map { call -> [String: Any] in
                        ["id": call.id, "type": "function", "function": ["name": call.name, "arguments": arguments(call)]]
                    }
                    if returnsThinking, let thinking = turn.thinking { message["reasoning_content"] = thinking }
                }
                messages.append(message)
            }
        }
        flush()
        return messages
    }

    private static func responsesInput(_ history: [ChatTurn]) -> [[String: Any]] {
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
                input.append(["type": "function_call_output", "call_id": turn.callID ?? "", "output": turn.text])
                pending += turn.images
            case .assistant:
                if !turn.text.isEmpty { input.append(["role": "assistant", "content": turn.text]) }
                for call in turn.toolCalls {
                    input.append(["type": "function_call", "call_id": call.id, "name": call.name, "arguments": arguments(call)])
                }
            }
        }
        flush()
        return input
    }

    /// Content blocks merged by role — the API wants user and assistant to alternate, and one turn's tool results
    /// in one user message. A message that is a single text block goes as a plain string.
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
                // A result may carry its pictures itself (V3).
                let content: Any = turn.images.isEmpty ? turn.text : [["type": "text", "text": turn.text]] + turn.images.map(image)
                var block: [String: Any] = ["type": "tool_result", "tool_use_id": turn.callID ?? "", "content": content]
                if turn.isError { block["is_error"] = true }
                blocks.append(block)
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

    private static func applyCompletionsReasoning(_ body: inout [String: Any], dialect: ReasoningDialect, level: ReasoningLevel) {
        guard level != .auto else { return }
        let on = level != .off
        switch dialect {
        case .deepSeek:
            body["thinking"] = ["type": on ? "enabled" : "disabled"]
            if let effort = completionsEffort(level) { body["reasoning_effort"] = effort == "minimal" ? "low" : effort }
        case .qwen:
            body["enable_thinking"] = on
        case .zai:
            body["thinking"] = ["type": on ? "enabled" : "disabled"]
        case .openRouter:
            if let effort = completionsEffort(level) {
                body["reasoning"] = ["effort": effort]
            } else {
                body["reasoning"] = ["enabled": false]
            }
        case .openAIEffort, .responses, .anthropic, .google:
            if let effort = completionsEffort(level) { body["reasoning_effort"] = effort }
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
                add(ChatTurn(role: .assistant, text: message.text, toolCalls: message.toolCalls,
                             thinking: returnsThinking ? message.thinking : nil,
                             thinkingSignature: returnsThinking ? message.thinkingSignature : nil))
                for call in message.toolCalls {
                    var output = call.result.map { $0.pruned == true ? Compaction.placeholder($0) : $0.output } ?? "没有执行。"
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
