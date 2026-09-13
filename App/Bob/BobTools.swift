import Foundation

/// A change Bob made, and the way to see it (7h, B6).
struct BobResult: Equatable, Sendable {
    enum Jump: Equatable, Sendable {
        case settings(SettingsCategory)
        /// Relative to the project folder.
        case file(String)
    }

    var title: String
    var meta: String
    var jump: Jump?

    var jumpLabel: String {
        switch jump {
        case .settings(.mcp): "去 MCP 看看"
        case .settings(.skills): "去 Skills 看看"
        case .settings(.notifications): "去通知看看"
        case .settings: "去看看"
        case .file: "在文件中查看"
        case nil: ""
        }
    }
}

/// Bob's tools (7h, B3–B5): reading ones run by themselves; each one that changes something waits for 允许 — unless
/// it would change nothing, which is said without asking.
@MainActor
enum BobTools {
    static let help = ToolSpec(
        name: "formora_help",
        description: "Read one topic of Formora's built-in guide before answering how Formora works, what a feature or command does, or where something is set. Topics: \(BobKnowledge.topicList).",
        parameters: #"{"type":"object","properties":{"topic":{"type":"string","enum":["overview","commands","agents","skills-mcp","settings","files-board"]}},"required":["topic"]}"#,
        tier: .read)

    static let state = ToolSpec(
        name: "formora_state",
        description: "Look up Formora's live state instead of guessing: agents (each Agent, its role, model, status, whether it is working), tasks (the current project's conversations, their status, who is on them, what is running or waiting), project (the current project and the folders: project, attachments, Skills), models (providers with a key, Bob's model), skills (installed Skills, where they come from, which Agents use them, their folders), mcp (connected services, their state and tools), notifications.",
        parameters: #"{"type":"object","properties":{"section":{"type":"string","enum":["agents","tasks","project","models","skills","mcp","notifications"]}},"required":["section"]}"#,
        tier: .read)

    static let skillCreate = ToolSpec(
        name: "skill_create",
        description: "Create a Skill in Formora's global library: a name, a one-line description of when to use it, and the instructions — written like a how-to for a colleague: when it applies, the steps, what the result looks like. It is enabled for no Agent; the user turns it on in an Agent's Skills tab.",
        parameters: #"{"type":"object","properties":{"name":{"type":"string"},"description":{"type":"string"},"instructions":{"type":"string"}},"required":["name","description","instructions"]}"#,
        tier: .write)

    static let folderCreate = ToolSpec(
        name: "folder_create",
        description: "Create a folder in the current project, e.g. `PRD/会员体系`. Relative to the project folder.",
        parameters: #"{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}"#,
        tier: .write)

    static let notificationSet = ToolSpec(
        name: "notification_set",
        description: "Turn one of Formora's notifications on or off: desktop (a system notification when a reply lands), sound (a sound for a new reply), badge (the unread count on the Dock icon).",
        parameters: #"{"type":"object","properties":{"setting":{"type":"string","enum":["desktop","sound","badge"]},"on":{"type":"boolean"}},"required":["setting","on"]}"#,
        tier: .write)

    /// Everything he remembers, gone, when the user asks — it asks first (D95: his memory has no page of its own).
    static let memoryClear = ToolSpec(
        name: "memory_clear",
        description: "Forget everything you remember, in every project, when the user asks you to. The user is asked first.",
        parameters: #"{"type":"object","properties":{}}"#,
        tier: .write)

    /// Everything Bob is offered — and every enabled MCP server's tools, added per request (D95).
    static let all: [ToolSpec] = [help, state, AgentTools.read, AgentTools.glob, AgentTools.grep, AgentTools.webSearch, AgentTools.fetch,
                                  AgentTools.write, AgentTools.edit, AgentTools.bash, SkillTools.load, MemoryTools.remember, memoryClear,
                                  MCPConnect.catalogSpec, MCPConnect.addSpec, skillCreate, folderCreate, notificationSet, AgentTools.openURL]

    static func tier(_ name: String) -> ToolTier? { all.first { $0.name == name }?.tier }

    /// What Bob can see and change.
    struct Context {
        let agents: AgentStore
        let conversations: ConversationStore
        let chat: ChatRunner
        let providers: ProviderStore
        let skills: SkillLibrary
        let mcp: MCPStore
        let notifications: NotificationSettings
        let project: BobSession.Project?
        let model: ModelReference?
        /// The model answering now, when its provider searches the web natively.
        let search: ChatTarget?
        /// His memory, the same in every project (D95).
        var memory: MemoryStore?
        /// Where a file's earlier text is kept for 撤销 — the Agents' folder (10d).
        var history: URL?
        var mcpClient = MCPClient()
        /// Where the files the user gave him are (D96).
        var attachmentsFolder: URL?

        /// Every installed Skill's folder, and the files the user gave him: his reading tools may look in them.
        @MainActor var readRoots: [URL] { skills.skills.compactMap { skills.folder(of: $0) } + (attachmentsFolder.map { [$0] } ?? []) }
    }

    enum Step {
        case done(ToolResult, BobResult?)
        /// Waits for 允许: what the card says, then the work.
        case ask(summary: String, detail: String, work: @MainActor () async -> (ToolResult, BobResult?))
    }

    static func prepare(_ call: ToolCall, context: Context) async -> Step {
        let args = ToolArguments.parse(call.arguments) ?? [:]
        func text(_ key: String) -> String { (args[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        switch call.name {
        case help.name:
            guard let guide = BobKnowledge.text(text("topic")) else {
                return .done(.failed("没有「\(text("topic"))」这一篇。有这些：\(BobKnowledge.topicList)"), nil)
            }
            return .done(.done(guide), nil)
        case state.name:
            return .done(.done(stateText(text("section"), context)), nil)
        case MCPConnect.catalogSpec.name:
            return .done(.done(MCPConnect.catalogText()), nil)
        case MCPConnect.addSpec.name:
            switch MCPConnect.plan(call.arguments, store: context.mcp) {
            case let .answer(result, existing):
                let card = existing.flatMap { context.mcp.server($0) }
                    .map { BobResult(title: "\($0.name) 已在列表中", meta: "设置 · MCP · 没有重复添加", jump: .settings(.mcp)) }
                return .done(result, card)
            case let .add(server, secrets):
                // One that starts on this Mac shows its command (9d, S6).
                let address = server.isStdio ? "在这台 Mac 上启动：\(server.endpointSummary)" : server.endpointSummary
                return .ask(summary: "接入 MCP 服务「\(server.name)」", detail: address + (secrets.isEmpty ? "" : " · 带 \(secrets.count) 项密钥，存进钥匙串")) {
                    let result = await MCPConnect.add(server, secrets: secrets, store: context.mcp)
                    let connected = context.mcp.servers.last { $0.name == server.name }?.lastTest?.succeeded == true
                    return (result, BobResult(title: "已接入 \(server.name)", meta: connected ? "测试连接成功 · 还没有 Agent 启用" : "已加进列表 · 测试连接没有成功",
                                              jump: .settings(.mcp)))
                }
            }
        case skillCreate.name:
            let name = text("name"), description = text("description"), instructions = text("instructions")
            guard !name.isEmpty, !description.isEmpty, !instructions.isEmpty else {
                return .done(.failed("name、description、instructions 都要写。Skill 没有建。"), nil)
            }
            if let existing = context.skills.skills.first(where: { FileSearch.normalize($0.name) == FileSearch.normalize(name) }) {
                return .done(.done("已经有一个叫「\(existing.name)」的 Skill 了，没有重复创建。"),
                             BobResult(title: "\(existing.name) 已存在", meta: "设置 · Skills", jump: .settings(.skills)))
            }
            return .ask(summary: "新建 Skill「\(name)」", detail: description) {
                do {
                    let skill = try context.skills.create(name: name, description: description, body: instructions)
                    return (.done("已建好「\(skill.name)」，放进了全局 Skills 库，没有为任何 Agent 启用。要用的话去那个 Agent 的 Skills 标签里打开。"),
                            BobResult(title: "已创建 Skill「\(skill.name)」", meta: "全局 Skills 库 · 还没有 Agent 启用", jump: .settings(.skills)))
                } catch let problem as SkillProblem {
                    return (.failed(problem.message + "。Skill 没有建。"), nil)
                } catch {
                    return (.failed(error.localizedDescription), nil)
                }
            }
        case folderCreate.name:
            guard let root = context.project?.root else { return .done(.failed("现在没有打开的项目，建不了文件夹。"), nil) }
            let path = text("path").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !path.isEmpty else { return .done(.failed("path 要写：文件夹的路径，相对于项目文件夹。"), nil) }
            let target: URL
            do {
                target = try ProjectSandbox(root: root).resolve(path, writing: true)
            } catch {
                return .done(.failed("「\(path)」不在项目文件夹里，Bob 只能在项目里建文件夹。"), nil)
            }
            var isFolder: ObjCBool = false
            if FileManager.default.fileExists(atPath: target.path, isDirectory: &isFolder) {
                return .done(.done(isFolder.boolValue ? "「\(path)」已经存在了，没有重复建。" : "「\(path)」是一个已有的文件，没有建文件夹。"),
                             BobResult(title: "\(path) 已存在", meta: "\(context.project?.name ?? "项目")/\(path)", jump: .file(path)))
            }
            return .ask(summary: "在项目里新建文件夹「\(path)」", detail: "\(context.project?.name ?? "项目")/\(path)") {
                do {
                    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                    return (.done("已在项目里建好文件夹「\(path)」。"),
                            BobResult(title: "已创建文件夹「\((path as NSString).lastPathComponent)」", meta: "\(context.project?.name ?? "项目")/\(path)", jump: .file(path)))
                } catch {
                    return (.failed("没建成：\(error.localizedDescription)"), nil)
                }
            }
        case notificationSet.name:
            guard let on = args["on"] as? Bool, let setting = NotificationSetting(rawValue: text("setting")) else {
                return .done(.failed("setting 只能是 desktop、sound、badge，on 是 true 或 false。"), nil)
            }
            let card = BobResult(title: "\(setting.label)已\(on ? "开启" : "关闭")", meta: "设置 · 通知", jump: .settings(.notifications))
            if setting.value(context.notifications) == on { return .done(.done("\(setting.label)本来就是\(on ? "开着" : "关着")的，没有改。"), card) }
            return .ask(summary: "\(on ? "打开" : "关掉")\(setting.label)", detail: "设置 · 通知") {
                setting.set(on, context.notifications)
                return (.done("已经\(on ? "打开" : "关掉")\(setting.label)。"), card)
            }
        case AgentTools.openURL.name:
            let address = text("url")
            return .ask(summary: "在你的浏览器里打开网址", detail: address) {
                (await AgentTools.run(call, root: context.project?.root), nil)
            }
        case AgentTools.fetch.name:
            // Reading a page asks too (D70): Bob reads the project's files, and a page's words could carry them out.
            return .ask(summary: "读取网页", detail: text("url")) {
                (await AgentTools.run(call, root: context.project?.root, search: context.search), nil)
            }
        // D95 (user 2026-09-13): every Skill, his own memory, the project's files and commands, every MCP tool. What only
        // reads runs; every change waits on its card (D55).
        case SkillTools.load.name:
            let skills = context.skills.skills
            guard let skill = SkillTools.find(text("name"), in: skills) else {
                return .done(.failed("没有叫「\(text("name"))」的 Skill。已安装的：" + skills.map { "「\($0.name)」" }.joined(separator: "、")), nil)
            }
            return .done(.done(SkillTools.loaded(skill, folder: context.skills.folder(of: skill))), nil)
        case MemoryTools.remember.name:
            guard let memory = context.memory else { return .done(.failed("这里没有记忆。"), nil) }
            return .done(MemoryTools.run(call.arguments, store: memory, agent: Conductor.bobID, project: BobSession.everywhere), nil)
        case memoryClear.name:
            guard let memory = context.memory, let current = memory.text(agent: Conductor.bobID, project: BobSession.everywhere) else {
                return .done(.done("本来就没有记着什么，不用清空。"), nil)
            }
            let count = current.split(separator: "\n").filter { $0.hasPrefix("- ") }.count
            return .ask(summary: "清空 Bob 的记忆", detail: "一共 \(count) 条，清掉后在哪个项目里都不再记得") {
                memory.rewrite("", agent: Conductor.bobID, project: BobSession.everywhere)
                return (.done("记忆清空了。"), nil)
            }
        case AgentTools.write.name, AgentTools.edit.name:
            guard let root = context.project?.root else { return .done(.failed("现在没有打开的项目，写不了文件。"), nil) }
            let path = text("path")
            let counts = FileHistory.preview(call, root: root).map(lineCounts) ?? ""
            let verb = call.name == AgentTools.write.name ? "写文件" : "改文件"
            return .ask(summary: "\(verb)「\(path)」", detail: "\(context.project?.name ?? "项目")/\(path)" + counts) {
                let result = await AgentTools.run(call, root: root, readRoots: context.readRoots, history: context.history)
                guard result.status == .done, let saved = result.savedPath else { return (result, nil) }
                return (result, BobResult(title: "已\(result.isNewFile == true ? "写好" : "改好")「\((saved as NSString).lastPathComponent)」",
                                          meta: "\(context.project?.name ?? "项目")/\(saved)", jump: .file(saved)))
            }
        case AgentTools.bash.name:
            guard let root = context.project?.root else { return .done(.failed("现在没有打开的项目，运行不了命令。"), nil) }
            let command = text("command")
            let risk = CommandRisk.reason(command).map { "。注意：\($0)" } ?? ""
            return .ask(summary: "在项目里运行命令", detail: command + risk) {
                (await AgentTools.run(call, root: root), nil)
            }
        default:
            if call.name.hasPrefix(MCPTools.prefix) {
                guard let binding = MCPTools.allBindings(in: context.mcp).first(where: { $0.spec.name == call.name }) else {
                    return .done(.failed("\(call.name) 不在现在能用的 MCP 工具里（那个服务可能停用了）。"), nil)
                }
                if binding.spec.tier == .read {
                    return .done(await MCPTools.call(binding, arguments: call.arguments, store: context.mcp, client: context.mcpClient), nil)
                }
                return .ask(summary: "用 \(binding.serverName) 的「\(binding.toolName)」", detail: String(call.arguments.prefix(300))) {
                    (await MCPTools.call(binding, arguments: call.arguments, store: context.mcp, client: context.mcpClient), nil)
                }
            }
            guard [AgentTools.read.name, AgentTools.glob.name, AgentTools.grep.name, AgentTools.webSearch.name]
                    .contains(call.name) else { return .done(.failed("没有 \(call.name) 这个工具。"), nil) }
            // With no project open, read still reaches the files the user gave him (D96).
            let root = context.project?.root ?? (call.name == AgentTools.read.name ? context.attachmentsFolder : nil)
            if call.name != AgentTools.webSearch.name, root == nil {
                return .done(.failed("现在没有打开的项目，看不了项目里的文件。"), nil)
            }
            return .done(await AgentTools.run(call, root: root, search: context.search, readRoots: context.readRoots), nil)
        }
    }

    /// 「 · +2 −1 行」 from a preview's diff, for a card waiting for 允许.
    static func lineCounts(_ diff: String) -> String {
        let lines = diff.split(separator: "\n", omittingEmptySubsequences: false)
        return " · +\(lines.filter { $0.hasPrefix("+") }.count) −\(lines.filter { $0.hasPrefix("-") }.count) 行"
    }

    enum NotificationSetting: String {
        case desktop, sound, badge

        var label: String {
            switch self {
            case .desktop: "桌面通知"
            case .sound: "提示音"
            case .badge: "程序坞未读数"
            }
        }

        @MainActor func value(_ settings: NotificationSettings) -> Bool {
            switch self {
            case .desktop: settings.desktop
            case .sound: settings.sound
            case .badge: settings.badge
            }
        }

        @MainActor func set(_ on: Bool, _ settings: NotificationSettings) {
            switch self {
            case .desktop: settings.setDesktop(on)
            case .sound: settings.setSound(on)
            case .badge: settings.setBadge(on)
            }
        }
    }

    // MARK: formora_state

    static func stateText(_ section: String, _ context: Context) -> String {
        switch section {
        case "agents": return agentsText(context)
        case "tasks": return tasksText(context)
        case "project": return projectText(context)
        case "models": return modelsText(context)
        case "skills": return skillsText(context)
        case "mcp": return mcpText(context)
        case "notifications":
            let settings = context.notifications
            return ["桌面通知：\(settings.desktop ? "开" : "关")", "提示音：\(settings.sound ? "开" : "关")",
                    "程序坞未读数：\(settings.badge ? "开" : "关")"].joined(separator: "\n")
        default:
            return "section 只能是 agents、tasks、project、models、skills、mcp、notifications。"
        }
    }

    private static func modelName(_ reference: ModelReference?, _ providers: ProviderStore) -> String {
        guard let reference else { return "没有配置" }
        return "\(providers.entry(reference.providerID)?.name ?? reference.providerID) · \(reference.modelID)"
    }

    private static func agentsText(_ context: Context) -> String {
        let agents = context.agents.agents
        guard !agents.isEmpty else { return "还没有 Agent。在「Agent」区右上角的加号创建。" }
        let working = Set(context.chat.activeRuns.values.map(\.agentID))
        let lines = agents.map { agent in
            var parts = ["\(agent.displayName)：\(agent.role.name)", agent.isActive ? "已激活" : "已停用",
                         "主模型 \(modelName(agent.primaryModel, context.providers))", "权限模式 \(agent.approvalMode.label)"]
            if let project = context.project { parts.append(agent.projectIDs.contains(project.id) ? "能在当前项目干活" : "没有当前项目的权限") }
            if !agent.enabledSkills.isEmpty { parts.append("启用了 \(agent.enabledSkills.count) 个 Skill") }
            if !agent.mcpAccess.isEmpty { parts.append("能用 \(agent.mcpAccess.count) 个 MCP 服务") }
            if working.contains(agent.id) { parts.append("正在干活") }
            return "- " + parts.joined(separator: "；")
        }
        return "共 \(agents.count) 个 Agent：\n" + lines.joined(separator: "\n")
    }

    private static func tasksText(_ context: Context) -> String {
        guard let project = context.project else { return "现在没有打开的项目。" }
        let list = context.conversations.list(project: project.id, hiddenView: false)
        guard !list.isEmpty else { return "「\(project.name)」里还没有对话。" }
        let lines = list.prefix(30).map { conversation in
            let who = conversation.isGroup
                ? "群聊，成员 " + ConversationReadiness.members(of: conversation, agents: context.agents).map(\.displayName).joined(separator: "、")
                : ConversationReadiness.headline(of: conversation, agents: context.agents)
            var state = conversation.status.label
            if context.chat.isRunning(conversation.id) { state = "正在做" }
            if context.chat.approvals[conversation.id] != nil || context.chat.pendingQuestion(conversation.id) != nil
                || context.chat.subtaskWaiting(conversation.id) != nil { state = "等你确认" }
            let time = ConversationText.timeLabel(conversation.updatedAt, now: .now)
            return "- 「\(conversation.title)」：\(state)；\(who)；最后更新 \(time)；最近一句：\(conversation.preview.prefix(60))"
        }
        let more = list.count > 30 ? "\n（还有 \(list.count - 30) 条没列出）" : ""
        return "「\(project.name)」的对话（\(list.count) 条，新的在前）：\n" + lines.joined(separator: "\n") + more
    }

    private static func projectText(_ context: Context) -> String {
        var lines: [String] = []
        if let project = context.project {
            lines.append("当前项目：\(project.name)")
            if let root = project.root {
                lines.append("项目文件夹：\(root.path)")
                lines.append("附件目录：\(root.appendingPathComponent("附件").path)（发给 Agent 的文件和图片复制到这里）")
            } else {
                lines.append("项目文件夹现在打不开（可能被移动或删除了）。")
            }
        } else {
            lines.append("现在没有打开的项目。")
        }
        if let folder = context.skills.revealDirectory() { lines.append("Skills 目录：\(folder.path)") }
        return lines.joined(separator: "\n")
    }

    private static func modelsText(_ context: Context) -> String {
        let providers = context.providers
        let configured = providers.entries.filter { providers.hasKey($0.id) }
        var lines = ["Bob 用的模型：\(modelName(context.model, providers))"]
        if configured.isEmpty {
            lines.append("还没有填了 Key 的服务商。去「设置 → 模型」给一家填上 API Key。")
        } else {
            lines.append("填了 Key 的服务商：")
            for entry in configured {
                lines.append("- \(entry.name)：\(providers.status(of: entry.id).label)；\(providers.modelCountLabel(entry.id))")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func skillsText(_ context: Context) -> String {
        let skills = context.skills.skills
        guard !skills.isEmpty else { return "还没有安装 Skill。" }
        let lines = skills.map { skill in
            let source = switch skill.source {
            case .builtIn: "内置"
            case .imported: "导入"
            case .created: "AI 创建"
            }
            let users = context.agents.agents.filter { $0.enabledSkills.contains(skill.id) }.map(\.displayName)
            let folder = context.skills.folder(of: skill).map { "；文件夹 \($0.path)" } ?? ""
            return "- \(skill.name)（\(source)，id \(skill.id)）：\(skill.document.description)；"
                + (users.isEmpty ? "没有 Agent 启用" : "启用它的：" + users.joined(separator: "、")) + folder
        }
        return "装了 \(skills.count) 个 Skill：\n" + lines.joined(separator: "\n")
    }

    private static func mcpText(_ context: Context) -> String {
        let servers = context.mcp.servers
        guard !servers.isEmpty else { return "还没有接入 MCP 服务。可以让 Bob 从推荐目录接一个，比如 Notion、GitHub、Figma。" }
        let lines = servers.map { server in
            let address = switch server.transport {
            case .http(let url): url
            case .stdio(let command, _): "本机命令 \(command)"
            }
            let test = server.lastTest.map { $0.succeeded ? "已连接，\(server.tools.count) 个工具" : "测试没通过：\($0.message ?? "")" } ?? "还没测试"
            let users = context.agents.agents.filter { agent in agent.mcpAccess.contains { $0.serverID == server.id } }.map(\.displayName)
            return "- \(server.name)（\(address)）：\(server.isEnabled ? "" : "已停用；")\(test)；"
                + (users.isEmpty ? "没有 Agent 启用" : "能用的 Agent：" + users.joined(separator: "、"))
        }
        return "接入了 \(servers.count) 个 MCP 服务：\n" + lines.joined(separator: "\n")
    }
}
