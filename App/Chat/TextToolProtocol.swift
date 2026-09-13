import Foundation

/// 兼容模式 (7d, D8; old app 2026-09-06, ReAct answer B): tool calls written as text, for hosts and models without
/// native ones. One dialect — omp's hermes (`<tool_call>{"name","arguments"}</tool_call>`, results in
/// `<tool_response>`) — rather than omp's catalogue of a dozen. The tools go in the system prompt, earlier calls and
/// results go back as text, and a reply that starts writing a `<tool_response>` of its own is cut there (omp
/// `owned-stream`: the model is inventing a result).
enum TextToolProtocol {
    /// A `<tool_call>` that isn't valid JSON: it becomes a call of this name, which fails and says how to fix it.
    static let malformedName = "tool_call_error"

    static func prompt(_ tools: [ToolSpec]) -> String {
        let lines = tools.map { tool in
            json(["name": tool.name, "description": tool.description, "parameters": tool.schema])
        }
        return """
        # 工具

        这个模型通过文字调用工具：按下面的格式把调用写在回复里，不要用其他格式。

        可用的工具，每行一个 JSON：
        <tools>
        \(lines.joined(separator: "\n"))
        </tools>

        ## 调用格式

        每个调用写成一个 <tool_call> 块，里面是一行 JSON，包含 name 和 arguments：

        <tool_call>
        {"name":"工具名","arguments":{"参数":"值"}}
        </tool_call>

        结果之后会以 <tool_response> 块发回给你：

        <tool_response name="工具名">
        工具的原样输出
        </tool_response>

        ## 规则

        - name 必须是上面列出的工具；arguments 是 JSON 对象，不要写成字符串。
        - 参数里的字符串只用 JSON 的转义（\\"、\\\\、\\n），不要做 HTML 转义。
        - 要调用几个工具，就连续写几个 <tool_call> 块；说明的话写在块外面。
        - 绝对不要自己写 <tool_response>：结果只能由系统发回。写完调用就停下，等结果。
        - 说要调用工具，就把 <tool_call> 完整写出来，不要只说不写。
        """
    }

    /// The history as a text-protocol model reads it: calls inside the assistant's words, results as the user's
    /// next turn (with the user's own words, if any, in the same turn — some protocols insist on alternation).
    static func encode(_ turns: [ChatTurn]) -> [ChatTurn] {
        var out: [ChatTurn] = []
        // A result's pictures ride on the user side with it (7j, V3).
        func add(_ role: ChatTurn.Role, _ text: String, _ images: [ChatImage] = []) {
            guard !text.isEmpty || !images.isEmpty else { return }
            if let last = out.last, last.role == role {
                out[out.count - 1].text = [last.text, text].filter { !$0.isEmpty }.joined(separator: "\n\n")
                out[out.count - 1].images += images
            } else {
                out.append(ChatTurn(role: role, text: text, images: images))
            }
        }
        for turn in turns {
            switch turn.role {
            case .tool:
                add(.user, renderResult(name: turn.toolName ?? "", text: turn.text, isError: turn.isError), turn.images)
            case .assistant:
                add(.assistant, [turn.text, renderCalls(turn.toolCalls)].filter { !$0.isEmpty }.joined(separator: "\n"))
            case .user:
                add(.user, turn.text, turn.images)
            }
        }
        return out
    }

    static func renderCalls(_ calls: [ToolCall]) -> String {
        calls.map { call in
            let body = call.name == malformedName ? call.arguments
                : json(["name": call.name, "arguments": ToolArguments.parse(call.arguments) ?? [:]])
            return "<tool_call>\n\(body)\n</tool_call>"
        }.joined(separator: "\n")
    }

    static func renderResult(name: String, text: String, isError: Bool) -> String {
        "<tool_response name=\"\(name)\">\n\(isError ? "[没有成功] " : "")\(text)\n</tool_response>"
    }

    /// One `<tool_call>` body as a call; not valid JSON → a call of `malformedName` carrying what was written.
    static func call(from body: String) -> ToolCall {
        let id = "call_" + UUID().uuidString.prefix(8).lowercased()
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let name = (object["name"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            return ToolCall(id: id, name: malformedName, arguments: text)
        }
        switch object["arguments"] {
        case nil:
            return ToolCall(id: id, name: name, arguments: "{}")
        case let fields as [String: Any]:
            return ToolCall(id: id, name: name, arguments: json(fields))
        case let string as String where ToolArguments.parse(string) != nil:
            // Stringified JSON, against the rules but unambiguous.
            return ToolCall(id: id, name: name, arguments: string)
        default:
            return ToolCall(id: id, name: malformedName, arguments: text)
        }
    }

    private static func json(_ object: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    /// Reads the reply as it streams: words pass through, `<tool_call>` blocks come out as calls, a tag split across
    /// pieces is held back until it is whole, and a `<tool_response>` the model writes itself ends the reading.
    struct Scanner {
        struct Output: Equatable {
            var text = ""
            var calls: [ToolCall] = []
            /// The model began writing a result of its own: stop reading, keep what came before.
            var fabricated = false
        }

        private static let open = "<tool_call>"
        private static let close = "</tool_call>"
        private static let response = "<tool_response"

        private var buffer = ""
        private var body = ""
        private var inCall = false
        private(set) var isStopped = false

        mutating func feed(_ piece: String) -> Output {
            var out = Output()
            guard !isStopped else { return out }
            buffer += piece
            while true {
                if inCall {
                    if let range = buffer.range(of: Self.close) {
                        body += buffer[..<range.lowerBound]
                        out.calls.append(TextToolProtocol.call(from: body))
                        body = ""
                        inCall = false
                        buffer = String(buffer[range.upperBound...])
                        continue
                    }
                    let keep = Self.partialSuffix(of: buffer, for: [Self.close])
                    body += buffer.dropLast(keep)
                    buffer = String(buffer.suffix(keep))
                    return out
                }
                let opening = buffer.range(of: Self.open)
                if let invented = buffer.range(of: Self.response), opening.map({ invented.lowerBound < $0.lowerBound }) ?? true {
                    out.text += buffer[..<invented.lowerBound]
                    buffer = ""
                    isStopped = true
                    out.fabricated = true
                    return out
                }
                if let opening {
                    out.text += buffer[..<opening.lowerBound]
                    buffer = String(buffer[opening.upperBound...])
                    inCall = true
                    continue
                }
                let keep = Self.partialSuffix(of: buffer, for: [Self.open, Self.response])
                out.text += buffer.dropLast(keep)
                buffer = String(buffer.suffix(keep))
                return out
            }
        }

        /// The reply is over: an unclosed call still counts (a host may stop right on it); anything held back is words.
        mutating func finish() -> Output {
            var out = Output()
            guard !isStopped else { return out }
            if inCall {
                let rest = (body + buffer).trimmingCharacters(in: .whitespacesAndNewlines)
                if !rest.isEmpty { out.calls.append(TextToolProtocol.call(from: rest)) }
            } else {
                out.text = buffer
            }
            buffer = ""
            body = ""
            inCall = false
            return out
        }

        /// How many characters at the end could be the start of one of the tags.
        static func partialSuffix(of text: String, for tags: [String]) -> Int {
            var longest = 0
            for tag in tags {
                for length in stride(from: min(tag.count - 1, text.count), to: 0, by: -1) where text.hasSuffix(tag.prefix(length)) {
                    longest = max(longest, length)
                    break
                }
            }
            return longest
        }
    }
}
