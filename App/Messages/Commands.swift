import Foundation

/// A `/` command of the composer (7d, D1–D2; spec §9.8): only the ones with a real counterpart in the app, each
/// appearing in the step that makes it work (`/cost` and `/compact` came with 7e; `/memory` and `/skill:` come with
/// 7f, `/loop` and `/goal` with 7g).
struct ComposerCommand: Identifiable, Equatable, Sendable {
    enum Action: Equatable, Sendable {
        case clear, cost, plan, compact, todo, memory, review, side, export, dump, help, git, loop, goal
        case go(Destination)
    }

    enum Destination: Equatable, Sendable {
        case model, skills, mcp, agents, files, settings, hooks
    }

    /// With its slash — what the popover inserts (spec §9.8: a name without it would be sent as a message).
    let name: String
    let note: String
    /// Picking it inserts the name and waits for the argument, instead of running it at once.
    var takesArgument = false
    /// Only Agents of these roles have it; `nil` = every role.
    var roles: Set<String>?
    let action: Action

    var id: String { name }
}

enum Commands {
    static let all: [ComposerCommand] = [
        ComposerCommand(name: "/clear", note: "清空当前对话的消息", action: .clear),
        ComposerCommand(name: "/cost", note: "这条对话用了多少 token、调用了几次模型", action: .cost),
        ComposerCommand(name: "/plan", note: "切换计划模式：先出方案，你确认后再动手", action: .plan),
        ComposerCommand(name: "/compact", note: "压缩上下文：把前面的对话整理成摘要（/compact 重点 指定要保留的）", action: .compact),
        ComposerCommand(name: "/todo", note: "看当前的计划（/todo 文字 可以加一项）", takesArgument: true, action: .todo),
        ComposerCommand(name: "/memory", note: "看这个 Agent 在当前项目里记下了什么（只读）", action: .memory),
        ComposerCommand(name: "/review", note: "请旁审把它最近一轮做的审一遍：给结论和分级的问题（/review 重点 指定要看什么）", action: .review),
        ComposerCommand(name: "/side", note: "岔开问一句：临时问点别的，主对话不受影响（/side 问题）", takesArgument: true, action: .side),
        ComposerCommand(name: "/loop", note: "自主运行 N 轮：/loop 3 接着完善这份需求（最多 10 轮）", takesArgument: true, action: .loop),
        ComposerCommand(name: "/goal", note: "朝一个目标自主运行，做到了由另一个 Agent 复核：/goal 目标", takesArgument: true, action: .goal),
        ComposerCommand(name: "/export", note: "导出当前对话为 HTML 文件", action: .export),
        ComposerCommand(name: "/dump", note: "复制整段对话到剪贴板", action: .dump),
        ComposerCommand(name: "/help", note: "列出全部可用指令", action: .help),
        ComposerCommand(name: "/git", note: "查看仓库状态和最近的提交", roles: ["dev"], action: .git),
        ComposerCommand(name: "/model", note: "去「模型与权限」", action: .go(.model)),
        ComposerCommand(name: "/skills", note: "去「Skills」", action: .go(.skills)),
        ComposerCommand(name: "/mcp", note: "去「MCP」", action: .go(.mcp)),
        ComposerCommand(name: "/agents", note: "去 Agent 列表", action: .go(.agents)),
        ComposerCommand(name: "/files", note: "去文件", action: .go(.files)),
        ComposerCommand(name: "/settings", note: "去设置", action: .go(.settings)),
        ComposerCommand(name: "/hooks", note: "去「设置 → Hooks」", action: .go(.hooks)),
    ]

    /// What the Agents of a conversation have (spec §9.8: `/git` only for 研发). A group counts every member's role.
    static func available(roles: Set<String>) -> [ComposerCommand] {
        all.filter { $0.roles.map { !$0.isDisjoint(with: roles) } ?? true }
    }

    /// The popover's list for what follows the `/`.
    static func matching(_ query: String, roles: Set<String>) -> [ComposerCommand] {
        let needle = FileSearch.normalize(query)
        return available(roles: roles).filter { needle.isEmpty || FileSearch.normalize($0.name).contains(needle) }
    }

    enum Line: Equatable {
        case command(ComposerCommand, argument: String)
        /// `/skill:<id> 文字` (7f, F1): a message asking for that Skill.
        case skill(String, argument: String)
        /// It is written like a command but isn't one here: why.
        case unknown(String)
        /// An ordinary message — `/Users/…` and the like included.
        case text
    }

    /// A line the user sends: `/name` and an optional argument (`/plan 做一个会员体系`, `/todo 补埋点`,
    /// `/review 重点看验收标准`).
    static func parse(_ raw: String, roles: Set<String>) -> Line {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("/") else { return .text }
        let head = String(text.dropFirst().prefix { !$0.isWhitespace })
        if head.hasPrefix("skill:"), head.count > 6 {
            return .skill(String(head.dropFirst(6)), argument: String(text.dropFirst(1 + head.count)).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard head.range(of: #"^[A-Za-z][A-Za-z0-9_-]*$"#, options: .regularExpression) != nil else { return .text }
        let name = "/" + head.lowercased()
        let argument = String(text.dropFirst(1 + head.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let command = all.first(where: { $0.name == name }) else {
            return .unknown("\(name) 不是可用指令，输入 / 查看全部")
        }
        if let only = command.roles, only.isDisjoint(with: roles) {
            return .unknown("\(name) 只对研发 Agent 可用")
        }
        return .command(command, argument: argument)
    }
}
