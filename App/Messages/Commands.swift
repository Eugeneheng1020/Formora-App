import Foundation

/// A `/` command of the composer (7d, D1–D2; spec §9.8): only the ones with a real counterpart in the app, each
/// appearing in the step that makes it work (`/cost` and `/compact` came with 7e; `/memory` and `/skill:` come with
/// 7f, `/loop` and `/goal` with 7g).
struct ComposerCommand: Identifiable, Equatable, Sendable {
    enum Action: Equatable, Sendable {
        case clear, cost, plan, compact, todo, memory, review, side, export, dump, help, git, loop, goal
        /// `/agent 目的` (user 2026-09-15): a subagent from its purpose.
        case subagent
        /// `/model 关键词` (user 2026-09-18): the Agent's main model, picked from a list in the composer's popover.
        case model
        /// `/skills`, `/mcp`, `/hooks` + what's wanted (user 2026-09-23): made, not a page to go to.
        case create(Creations.Kind)
        /// `/effort 档位` (user 2026-09-23): the conversation's reasoning level, picked from a list in the popover.
        case effort
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
        ComposerCommand(name: "/memory", note: "看这条对话用得到的记忆：全局、本项目、这个 Agent 自己的（只读）", action: .memory),
        ComposerCommand(name: "/review", note: "请旁审把它最近一轮做的审一遍：给结论和分级的问题（/review 重点 指定要看什么）", action: .review),
        ComposerCommand(name: "/side", note: "岔开问一句：临时问点别的，主对话不受影响（/side 问题）", takesArgument: true, action: .side),
        ComposerCommand(name: "/loop", note: "自主运行 N 轮：/loop 3 接着完善这份需求（最多 10 轮）", takesArgument: true, action: .loop),
        ComposerCommand(name: "/goal", note: "朝一个目标自主运行，做到了由另一个 Agent 复核：/goal 目标", takesArgument: true, action: .goal),
        ComposerCommand(name: "/export", note: "导出当前对话为 HTML 文件", action: .export),
        ComposerCommand(name: "/dump", note: "复制整段对话到剪贴板", action: .dump),
        ComposerCommand(name: "/help", note: "列出全部可用指令", action: .help),
        ComposerCommand(name: "/git", note: "查看仓库状态和最近的提交", roles: ["dev"], action: .git),
        ComposerCommand(name: "/effort", note: "调推理强度：列出这个模型有的档位，只影响这个对话", takesArgument: true, action: .effort),
        ComposerCommand(name: "/model", note: "切换这个 Agent 的主模型：/model 关键词 只看匹配的", takesArgument: true, action: .model),
        ComposerCommand(name: "/skills", note: "创建一个 Skill：/skills 写清要它会什么", takesArgument: true, action: .create(.skill)),
        ComposerCommand(name: "/mcp", note: "接入一个 MCP 服务：/mcp 服务名、地址或配置", takesArgument: true, action: .create(.mcp)),
        ComposerCommand(name: "/hooks", note: "创建一个 Hook：/hooks 什么时候做什么", takesArgument: true, action: .create(.hook)),
        ComposerCommand(name: "/agent", note: "创建一个子代理：/agent 写清它的目的，名字、提示词由模型起草", takesArgument: true, action: .subagent),
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
        /// `/名字 任务` (user 2026-09-15): work for that subagent, by its own name.
        case subagentRun(String, argument: String)
        /// It is written like a command but isn't one here: why.
        case unknown(String)
        /// An ordinary message — `/Users/…` and the like included.
        case text
    }

    /// A line the user sends: `/name` and an optional argument (`/plan 做一个会员体系`, `/todo 补埋点`,
    /// `/review 重点看验收标准`).
    static func parse(_ raw: String, roles: Set<String>, subagents: [String] = []) -> Line {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("/") else { return .text }
        let head = String(text.dropFirst().prefix { !$0.isWhitespace })
        if head.hasPrefix("skill:"), head.count > 6 {
            return .skill(String(head.dropFirst(6)), argument: String(text.dropFirst(1 + head.count)).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        // A subagent's name — Chinese included — is its command.
        if let subagent = subagents.first(where: { SubagentNames.normalize($0) == SubagentNames.normalize(head) }) {
            return .subagentRun(subagent, argument: String(text.dropFirst(1 + head.count)).trimmingCharacters(in: .whitespacesAndNewlines))
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
