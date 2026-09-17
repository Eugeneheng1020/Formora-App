import Foundation

/// A `/` command of Bob's panel (D96, user 2026-09-13): his conversation's own, his memory, the settings pages behind
/// the panel — not an Agent's (plan mode, loops, 旁审 belong to an Agent's conversation). `/skill:名字` asks for a Skill.
struct BobCommand: Identifiable, Equatable, Sendable {
    enum Action: Equatable, Sendable {
        case clear, help, dump, export, memory
        case go(SettingsCategory)
    }

    let name: String
    let note: String
    let action: Action

    var id: String { name }
}

enum BobCommands {
    static let all: [BobCommand] = [
        BobCommand(name: "/clear", note: "清空和 Bob 的对话", action: .clear),
        BobCommand(name: "/memory", note: "看 Bob 读得到的记忆：全局的和他自己的（只读）", action: .memory),
        BobCommand(name: "/help", note: "列出这里能用的指令", action: .help),
        BobCommand(name: "/dump", note: "把和 Bob 的对话复制到剪贴板", action: .dump),
        BobCommand(name: "/export", note: "把和 Bob 的对话导出成 HTML 文件", action: .export),
        BobCommand(name: "/model", note: "去「设置 → Bob」选他用的模型", action: .go(.bob)),
        BobCommand(name: "/skills", note: "去「设置 → Skills」", action: .go(.skills)),
        BobCommand(name: "/mcp", note: "去「设置 → MCP」", action: .go(.mcp)),
        BobCommand(name: "/hooks", note: "去「设置 → Hooks」", action: .go(.hooks)),
        BobCommand(name: "/notifications", note: "去「设置 → 通知」", action: .go(.notifications)),
        BobCommand(name: "/computer", note: "去「设置 → 电脑操作」", action: .go(.computer)),
    ]

    /// The list for what follows the `/`.
    static func matching(_ query: String) -> [BobCommand] {
        let needle = FileSearch.normalize(query)
        return all.filter { needle.isEmpty || FileSearch.normalize($0.name).contains(needle) }
    }

    /// What /help answers, without asking the model.
    static var helpText: String {
        "这里能用的指令：\n\n" + all.map { "- `\($0.name)`：\($0.note)" }.joined(separator: "\n")
            + "\n- `/skill:名字 要做的事`：按某个 Skill 的做法来做（输入 / 能看到所有已安装的 Skill）"
    }

    enum Line: Equatable {
        case command(BobCommand)
        /// `/skill:<id> 文字`: a message asking for that Skill.
        case skill(String, argument: String)
        /// Written like a command, but not one here: why.
        case unknown(String)
        /// An ordinary message — `/Users/…` and the like included.
        case text
    }

    static func parse(_ raw: String) -> Line {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("/") else { return .text }
        let head = String(text.dropFirst().prefix { !$0.isWhitespace })
        if head.hasPrefix("skill:"), head.count > 6 {
            return .skill(String(head.dropFirst(6)), argument: String(text.dropFirst(1 + head.count)).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard head.range(of: #"^[A-Za-z][A-Za-z0-9_-]*$"#, options: .regularExpression) != nil else { return .text }
        let name = "/" + head.lowercased()
        if let command = all.first(where: { $0.name == name }) { return .command(command) }
        if Commands.all.contains(where: { $0.name == name }) {
            return .unknown("\(name) 是 Agent 对话里的指令，在 Bob 这里用不了。输入 / 看这里能用的")
        }
        return .unknown("\(name) 不是可用指令，输入 / 看这里能用的")
    }
}
