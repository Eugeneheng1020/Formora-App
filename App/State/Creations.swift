import Foundation

/// `/skills 描述`、`/mcp 描述`、`/hooks 描述` (user 2026-09-23: 「都是创建对应的内容，而不是现在的跳转」): like `/agent`, the
/// user writes what they want, a model drafts it in one go (Bob's, else the conversation's Agent's), and it is made without a
/// form. A Skill is only words and is saved at once; an MCP service and a Hook run things on this Mac, so they wait for one
/// 允许 first — above the composer, or on a card in Bob's panel. The prompts, the parsing and the checks live here, pure.
enum Creations {
    enum Kind: String, Sendable {
        case skill, mcp, hook

        var label: String {
            switch self {
            case .skill: "Skill"
            case .mcp: "MCP 服务"
            case .hook: "Hook"
            }
        }

        var command: String {
            switch self {
            case .skill: "/skills"
            case .mcp: "/mcp"
            case .hook: "/hooks"
            }
        }

        /// What the command asks for when it came without words.
        var example: String {
            switch self {
            case .skill: "写上要它会什么，比如 /skills 按我们的格式写周报"
            case .mcp: "写上要接什么，比如 /mcp GitHub，或者 /mcp https://… 的地址"
            case .hook: "写上什么时候做什么，比如 /hooks 每次改完 Swift 文件就跑 swiftformat"
            }
        }
    }

    /// Something that waits for 允许 before it is made.
    struct Pending: Equatable, Identifiable {
        enum Payload: Equatable {
            case mcp(server: MCPServerConfig, secrets: [String: String])
            case hook(HookHandler, event: HookEvent, matcher: String?, root: URL)
        }

        let id = UUID()
        let kind: Kind
        let title: String
        /// Under the title: where it runs, when, what — the command or address in full.
        let lines: [String]
        /// Mono: the command or address, as it will run.
        let code: String?
        let payload: Payload

        static func == (a: Pending, b: Pending) -> Bool { a.id == b.id }
    }

    /// Where a request ends up.
    enum Outcome: Equatable {
        case made(title: String, detail: String)
        case confirm(Pending)
        case failed(String)
    }

    // MARK: The prompts

    @MainActor static func system(_ kind: Kind) -> String {
        switch kind {
        case .skill:
            return """
            你替用户写一个 Formora 的 Skill：一份教 Agent 按某种做法干活的说明，存成 SKILL.md。只输出一个 JSON 对象，不要别的字：
            {"name": "英文名，小写字母、数字和 -，字母开头，比如 weekly-report", "description": "中文一句话：它做什么、什么时候用，用用户会说的词", "instructions": "SKILL.md 的正文，Markdown"}
            正文写法：开头一句说清目的；然后按顺序写步骤，每步写具体做法和标准，不写空话；有固定格式就给出模板；最后写交付前要核对的几条。只写模型默认做不到或者这个用户特有的要求，常识不写。不编造用户没提的事实、数据和工具。
            """
        case .mcp:
            return """
            你把用户想接入的 MCP 服务，写成接入参数。只输出一个 JSON 对象，不要别的字，字段按需选：
            {"catalog_id": "推荐目录里的 id"} ——用户要的服务在下面的推荐目录里时，优先用它；
            {"url": "https://…", "name": "起个短名字"} ——用户给了一个 Streamable HTTP 地址；
            {"config": "用户贴的整段 JSON 配置，原样作为字符串"} ——用户贴了配置；
            用户给了令牌、密钥，放进 "token"（原样照抄，包括 $$SECRET_…$$ 这样的占位符）；给了文件夹路径放进 "folder"；某个服务要几样值，按目录里写的名字放进 "values"。
            用户没给的令牌、路径不要编，留空。目录里没有、用户也没给地址或配置时，输出 {"missing": "中文一句话：还缺什么、去哪儿拿"}。
            推荐目录：
            \(MCPConnect.catalogText())
            """
        case .hook:
            let events = HookEvent.allCases.map { "- \($0.rawValue)：\($0.label)。\($0.note)" }.joined(separator: "\n")
            return """
            你把用户的要求写成一个 Formora 的 Hook：在某个时刻自动运行一条命令，或者往一个网址发通知。只输出一个 JSON 对象，不要别的字：
            {"event": "下面的时刻之一（英文原名）", "matcher": "只有 PreToolUse / PostToolUse 用：工具名，多个用 | 分隔，比如 write|edit；不限工具就不写", "type": "command 或 http", "command": "type 是 command 时：在项目文件夹里用 zsh 运行的一条命令", "url": "type 是 http 时：接收通知的地址", "format": "type 是 http 时：raw、feishu、wecom、dingtalk、slack 之一", "timeout": 秒数（可不写）}
            时刻：
            \(events)
            Agent 的工具名：read、glob、grep、write、edit、bash、web_search、fetch、open_url。
            命令收到的输入是标准输入里的一段 JSON（tool_name、tool_input、prompt 等字段），要读就用 jq。命令要短、能直接跑，不装东西、不删东西、不联网（除非用户明说）。用户没说清的，按最常见、最安全的理解写。
            """
        }
    }

    static func request(_ words: String, problem: String?) -> String {
        "用户的要求：\n\(words)" + (problem.map { "\n\n上一次你写的不能用：\($0)。这次改掉，其余照旧，仍然只输出 JSON。" } ?? "")
    }

    /// The JSON in a reply — fenced or bare.
    static func object(_ reply: String) -> [String: Any]? {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
              let data = String(reply[start...end]).data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func text(_ object: [String: Any], _ key: String) -> String {
        (object[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Skill

    struct SkillDraft: Equatable {
        var name: String
        var description: String
        var instructions: String
    }

    /// `nil` with why, for the second try.
    static func skill(_ reply: String) -> Result<SkillDraft, Problem> {
        guard let object = object(reply) else { return .failure(Problem("回复不是一个能读的 JSON 对象")) }
        let draft = SkillDraft(name: text(object, "name"), description: text(object, "description"), instructions: text(object, "instructions"))
        guard !draft.name.isEmpty, !draft.description.isEmpty, !draft.instructions.isEmpty else {
            return .failure(Problem("name、description、instructions 缺了"))
        }
        return .success(draft)
    }

    /// The English name it is saved under: as given, folded into lower-case and hyphens when it isn't, numbered when taken.
    static func skillName(_ raw: String, taken: [String]) -> String? {
        let given = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = EnglishSlug.isValid(given) ? given : SubagentNames.slug(given)
        guard base.count >= 2 else { return nil }
        let used = Set(taken.map(FileSearch.normalize))
        var candidate = base
        var number = 2
        while used.contains(FileSearch.normalize(candidate)) {
            candidate = "\(base)-\(number)"
            number += 1
            if number > 99 { return nil }
        }
        return candidate
    }

    // MARK: MCP

    /// The drafted arguments, as `mcp_add` takes them — or what's missing, said by the model.
    static func mcpArguments(_ reply: String) -> Result<String, Problem> {
        guard let object = object(reply) else { return .failure(Problem("回复不是一个能读的 JSON 对象")) }
        let missing = text(object, "missing")
        if !missing.isEmpty, text(object, "catalog_id").isEmpty, text(object, "url").isEmpty, text(object, "config").isEmpty {
            return .failure(Problem(missing, final: true))
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return .failure(Problem("回复不是一个能读的 JSON 对象")) }
        return .success(json)
    }

    static func mcpLines(_ server: MCPServerConfig) -> (lines: [String], code: String?) {
        switch server.transport {
        case .http(let url):
            return (["连接这个网址上的 MCP 服务，接入后在 Agent 的 MCP 标签里启用才会用到。"], url)
        case let .stdio(command, arguments):
            return (["在这台 Mac 上以你的身份启动下面这条命令，接入后在 Agent 的 MCP 标签里启用才会用到。"],
                    ([command] + arguments).joined(separator: " "))
        }
    }

    // MARK: Hook

    struct HookDraft: Equatable {
        var event: HookEvent
        var matcher: String?
        var handler: HookHandler
    }

    static func hook(_ reply: String) -> Result<HookDraft, Problem> {
        guard let object = object(reply) else { return .failure(Problem("回复不是一个能读的 JSON 对象")) }
        guard let event = HookEvent(rawValue: text(object, "event")) else {
            return .failure(Problem("event「\(text(object, "event"))」不是能用的时刻，要用英文原名，比如 PostToolUse"))
        }
        let matcher = event.usesToolMatcher && !text(object, "matcher").isEmpty ? text(object, "matcher") : nil
        let timeout = (object["timeout"] as? NSNumber)?.intValue
        switch text(object, "type").isEmpty ? "command" : text(object, "type") {
        case "command":
            let command = text(object, "command")
            guard !command.isEmpty else { return .failure(Problem("type 是 command，却没有 command")) }
            return .success(HookDraft(event: event, matcher: matcher, handler: HookHandler(kind: .command(command), timeout: timeout)))
        case "http":
            let url = text(object, "url")
            guard let parsed = URL(string: url), ["http", "https"].contains(parsed.scheme?.lowercased() ?? "") else {
                return .failure(Problem("type 是 http，url 要是 http:// 或 https:// 开头的地址"))
            }
            let format = WebhookFormat(rawValue: text(object, "format")) ?? .raw
            return .success(HookDraft(event: event, matcher: matcher, handler: HookHandler(kind: .http(url: url, format: format), timeout: timeout)))
        default:
            return .failure(Problem("type 只能是 command 或 http"))
        }
    }

    static func hookLines(_ draft: HookDraft) -> (lines: [String], code: String?) {
        let when = draft.event.label + (draft.matcher.map { "（工具：\($0)）" } ?? "")
        switch draft.handler.kind {
        case .command(let command):
            return (["\(when)，在项目文件夹里运行下面这条命令。存在本项目，直接启用。"], command)
        case let .http(url, format):
            return (["\(when)，把消息发到下面这个地址（\(format.label)）。存在本项目，直接启用。"], url)
        case .unsupported:
            return ([when], nil)
        }
    }

    struct Problem: Error, Equatable {
        let message: String
        /// Asked again it would come back the same: said to the user as it is.
        var final = false

        init(_ message: String, final: Bool = false) {
            self.message = message
            self.final = final
        }
    }
}
