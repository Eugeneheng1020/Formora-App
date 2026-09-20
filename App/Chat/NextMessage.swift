import Foundation

/// 按 Tab 联想下一句 (user 2026-09-20): the composer, empty and idle, asks the conversation's own model what the user
/// would say next — written as the user, in one line, for Tab to take. Nothing like it in omp or Codex (their
/// completions are all local: commands, files, emoji), so the shape is ours: the answer comes inside a marker, as
/// 起任务名 does (TaskTitle), because a forced tool call isn't offered by every host.
enum NextMessage {
    /// Long enough for a real instruction, short enough to read at a glance before pressing Tab.
    static let maxLength = 60

    static let system = """
    你在帮用户写他要发给 AI Agent 的下一条消息。读完整段对话，写出用户此刻最可能发出的下一句话。

    规则：
    - 用第一人称，用户的口吻，像用户自己打出来的，不是助手的建议。
    - 一句话，不超过 \(maxLength) 个字，不加引号、不加编号、不给多个选项。
    - 接住对话里真正悬着的事：它问你的问题、回复里的未决项、计划里没做完的步骤、刚写出来还没验证的东西。
    - 事情已经收尾、或者想不出用户还会说什么，就回答 <next/>，不要硬凑。

    只回答那句话，放在 <next></next> 里。

    示例：
    （它刚写完 PRD，问「已经领过其他券的用户要不要排除？」）
    回答：<next>排除，领过券的这次不发</next>
    （它刚改完登录接口，说本地跑通了）
    回答：<next>跑一遍测试，把结果贴给我</next>
    （用户刚说「谢谢，就这样」）
    回答：<next/>
    """

    /// The turn put after the conversation, asking for the next line.
    static let ask = "〔现在写出我最可能发出的下一句话，放在 <next></next> 里。〕"

    /// `<next>一句话</next>` → that line, trimmed and capped; `<next/>`, an empty marker or no marker → `nil`
    /// (an answer without the marker isn't trusted to be the user's words).
    static func parse(_ reply: String) -> String? {
        guard let open = reply.range(of: "<next>"),
              let close = reply.range(of: "</next>", range: open.upperBound..<reply.endIndex) else { return nil }
        var line = String(reply[open.upperBound..<close.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // One line: a model that wrote several is taken at its first.
        if let newline = line.firstIndex(where: \.isNewline) { line = String(line[..<newline]) }
        line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        for quote in ["\"", "「", "“", "'"] where line.hasPrefix(quote) {
            line = String(line.dropFirst())
        }
        for quote in ["\"", "」", "”", "'"] where line.hasSuffix(quote) {
            line = String(line.dropLast())
        }
        line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        return String(line.prefix(maxLength))
    }
}
