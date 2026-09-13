import AppKit
import Foundation
import UniformTypeIdentifiers

/// The composer's `/` commands at work (7d, D1–D2).
extension AppState {
    /// Whose commands a conversation has: its Agent's role, or in a group every member's.
    func commandRoles(_ conversation: Conversation) -> Set<String> {
        if conversation.isGroup { return Set(ConversationReadiness.members(of: conversation, agents: agents).map(\.roleID)) }
        return Set([agents.agent(conversation.agentID)?.roleID].compactMap { $0 })
    }

    /// The Agent a command is about: the direct chat's; in a group whoever answered last, else the first member.
    func commandAgent(_ conversation: Conversation) -> AgentRecord? {
        guard conversation.isGroup else { return agents.agent(conversation.agentID) }
        if let last = conversation.messages.last(where: { $0.role == .agent && !$0.isHidden }), let agent = agents.agent(last.agentID) {
            return agent
        }
        return ConversationReadiness.members(of: conversation, agents: agents).first
    }

    /// Runs one command. `nil` when it ran; otherwise why not, for the toast.
    func runCommand(_ command: ComposerCommand, argument: String, in id: UUID, projectRoot: URL?, projectName: String?) async -> String? {
        guard let conversation = conversations.conversation(id) else { return nil }
        switch command.action {
        case .help:
            let rows = Commands.available(roles: commandRoles(conversation)).map { CommandCard.Row(name: $0.name, note: $0.note) }
            commandCards[id] = CommandCard(kicker: "help", title: "可用指令", body: .rows(rows))
        case .clear:
            guard !chat.isRunning(id) else { return "它还在做，先停止再清空" }
            guard conversation.messages.contains(where: { !$0.isHidden }) else { return "这条对话还没有消息" }
            conversationToClear = id
        case .dump:
            let text = ConversationExport.plainText(conversation, agents: agents, userName: accountName, projectName: projectName)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            let count = conversation.messages.filter { !$0.isHidden }.count
            toasts.show("已复制", note: "\(count) 条消息已复制到剪贴板", seconds: 2)
        case .export:
            let panel = NSSavePanel()
            panel.title = "导出对话"
            panel.nameFieldStringValue = ConversationExport.fileName(conversation)
            panel.allowedContentTypes = [.html]
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return nil }
            let html = ConversationExport.html(conversation, agents: agents, userName: accountName, projectName: projectName)
            do {
                try Data(html.utf8).write(to: url, options: .atomic)
                toasts.show("已导出", note: url.lastPathComponent)
            } catch {
                return error.localizedDescription
            }
        case .git:
            guard let root = projectRoot else { return "项目文件夹现在打不开" }
            let result = await Shell.run("git status --short --branch && echo && git log --oneline -8", cwd: root, timeout: 15,
                                         environment: Shell.environment(projectPath: root.path))
            commandCards[id] = CommandCard(kicker: "git", title: "仓库状态", body: .mono(Self.gitText(result)))
        case .go(let destination):
            go(destination, agent: commandAgent(conversation))
        case .cost:
            commandCards[id] = CommandCard(kicker: "cost", title: "本次对话的用量", body: .usage)
        case .compact:
            if let reason = await chat.compact(id, focus: argument) { return reason }
            if let record = conversations.conversation(id)?.messages.last(where: { $0.compaction != nil })?.compaction {
                toasts.show("已压缩", note: "上下文从约 \(ContextBudget.format(record.tokensBefore)) 降到约 "
                                + "\(ContextBudget.format(record.tokensAfter)) token（估算）", seconds: 3)
            } else {
                toasts.show("已精简", note: "旧的工具输出换成了占位，原文还在卡片里", seconds: 3)
            }
        case .memory:
            guard let agent = commandAgent(conversation) else { return "这条对话里没有 Agent" }
            commandCards[id] = CommandCard(kicker: "memory", title: "\(agent.displayName) 的记忆", body: .memory)
        case .plan:
            return togglePlanMode(id, message: argument, projectRoot: projectRoot, projectName: projectName)
        case .todo:
            if !argument.isEmpty {
                conversations.addPlanItem(argument, in: id)
                toasts.show("已加进计划", note: argument, seconds: 2)
            }
            commandCards[id] = CommandCard(kicker: "todo", title: "计划", body: .plan)
        case .review:
            return startReview(id, focus: argument)
        case .side:
            return startSide(id, question: argument, projectRoot: projectRoot, projectName: projectName)
        case .loop, .goal:
            return startAutorun(id, action: command.action, argument: argument)
        }
        return nil
    }

    /// `/skill:<id> 文字` (7f, F1): a message asking the Agent to work with that Skill — which it must have enabled.
    func runSkill(_ skillID: String, text: String, in id: UUID, projectRoot: URL?, projectName: String?) -> String? {
        guard let conversation = conversations.conversation(id), let skill = skills.skill(skillID) else {
            return "没有叫 \(skillID) 的 Skill，输入 / 看能用的"
        }
        guard let agent = commandAgent(conversation), agent.enabledSkills.contains(skillID) else {
            return "「\(skill.name)」没有在这个 Agent 上启用，去它的 Skills 标签打开"
        }
        sendFromCommand("用「\(skill.name)」这个 Skill" + (text.isEmpty ? "。" : "：\(text)"), to: id, projectRoot: projectRoot,
                        projectName: projectName)
        return nil
    }

    /// The Skills the `/` menu offers: the enabled ones of the Agent a command is about.
    func commandSkills(_ conversation: Conversation) -> [Skill] {
        (commandAgent(conversation)?.enabledSkills ?? []).compactMap { skills.skill($0) }
    }

    /// What `git status` and `git log` said, or why git didn't answer.
    nonisolated static func gitText(_ result: Shell.Result) -> String {
        if result.exit == 0 { return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
        let said = [result.failure, result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)].compactMap { $0 }.filter { !$0.isEmpty }
            .joined(separator: "\n")
        if said.contains("not a git repository") { return "这个项目文件夹还不是 git 仓库。" }
        return "git 没有运行成功：\(said)\n\n沙盒里 macOS 自带的 /usr/bin/git 用不了，需要 Homebrew 装的 git（brew install git）。"
    }

    /// The jumps: an explicit destination, so the composer's draft isn't guarded (spec §9.8, §8.6).
    private func go(_ destination: ComposerCommand.Destination, agent: AgentRecord?) {
        switch destination {
        case .model, .skills, .mcp, .agents:
            if let agent { selectedAgentID = agent.id }
            agentTab = switch destination {
            case .model: .model
            case .skills: .skills
            case .mcp: .mcp
            default: .overview
            }
            select(.agents)
        case .files:
            select(.files)
        case .settings:
            settingsCategory = .account
            select(.settings)
        case .hooks:
            settingsCategory = .hooks
            select(.settings)
        }
    }
}
