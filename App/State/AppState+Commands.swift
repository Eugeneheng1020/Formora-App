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
        case .subagent:
            let purpose = argument.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !purpose.isEmpty else { return "写上它的目的：/agent 它要替你做什么" }
            startSubagentDraft(purpose: purpose, in: id)
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
        case .model, .skills, .mcp:
            if let agent { selectedAgentID = agent.id }
            agentTab = switch destination {
            case .model: .model
            case .skills: .skills
            default: .mcp
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

// MARK: 子代理 (user 2026-09-15)

extension AppState {
    /// The model that drafts a subagent: Bob's, else the conversation's Agent's.
    private func drafterModels(for conversation: Conversation) -> [ModelReference] {
        [chat.conductorModel(), commandAgent(conversation)?.primaryModel].compactMap { $0 }
    }

    /// `/agent 目的`: the dialog opens at once, the draft fills in as the model answers.
    func startSubagentDraft(purpose: String, in id: UUID) {
        guard let conversation = conversations.conversation(id) else { return }
        subagentDraft = SubagentDraft(conversationID: id, purpose: purpose, scope: subagents.globalFolder == nil ? .project : .project)
        let models = drafterModels(for: conversation)
        guard !models.isEmpty else {
            subagentDraft?.problem = "没有可用的模型来起草，先自己填，或者去「设置 → Bob」选一个模型"
            return
        }
        generateSubagentDraft(with: models)
    }

    func regenerateSubagentDraft() {
        guard let draft = subagentDraft, let conversation = conversations.conversation(draft.conversationID) else { return }
        let models = drafterModels(for: conversation)
        guard !models.isEmpty else { return }
        generateSubagentDraft(with: models)
    }

    private func generateSubagentDraft(with models: [ModelReference]) {
        guard let draft = subagentDraft else { return }
        subagentDraft?.isGenerating = true
        subagentDraft?.problem = nil
        let reserved = Commands.all.map { String($0.name.dropFirst()) } + subagents.names + Array(SubagentNames.reserved)
        let prompt = SubagentGenerator.request(purpose: draft.purpose, reserved: reserved)
        Task { [weak self] in
            guard let self else { return }
            let reply = await chat.oneShot(system: SubagentGenerator.system, prompt: prompt, candidates: models)
            guard var current = subagentDraft, current.id == draft.id else { return }
            current.isGenerating = false
            if let reply, let proposed = SubagentGenerator.parse(reply.summary) {
                current.name = proposed.name
                current.description = proposed.description
                current.tier = proposed.tier
                current.prompt = proposed.prompt
                current.problem = SubagentNames.problem(with: proposed.name, commands: Commands.all.map(\.name) + subagents.names.map { "/" + $0 })
            } else {
                current.problem = "起草没有成功，可以自己填，或者点「重新起草」"
            }
            subagentDraft = current
        }
    }

    /// 保存: the file, the toast, the popover's new command.
    func saveSubagentDraft() {
        guard var draft = subagentDraft else { return }
        let definition = draft.definition
        if let problem = SubagentNames.problem(with: definition.name, commands: Commands.all.map(\.name)) {
            draft.problem = problem
            subagentDraft = draft
            return
        }
        guard !definition.prompt.isEmpty else {
            draft.problem = "提示词不能是空的"
            subagentDraft = draft
            return
        }
        do {
            try subagents.save(definition, scope: draft.scope)
            subagentDraft = nil
            toasts.show("子代理「\(definition.name)」已创建", note: "/\(definition.name) 任务 派活；Agent 也会按需要派它", seconds: 4)
        } catch {
            draft.problem = (error as? SubagentProblem)?.message ?? error.localizedDescription
            subagentDraft = draft
        }
    }

    /// `/名字 任务`: the conversation's Agent lends its model; the report lands in the thread.
    func runSubagentCommand(_ name: String, task: String, in id: UUID) async -> String? {
        guard let conversation = conversations.conversation(id), let definition = subagents.definition(named: name) else { return "没有叫「\(name)」的子代理" }
        guard !task.isEmpty else { return "写上要它做的事：/\(definition.name) 任务" }
        guard let requester = commandAgent(conversation), requester.primaryModel != nil else { return "这条对话的 Agent 还没有配好模型" }
        guard !conversation.isSubtask else { return "子任务里不能再派子代理" }
        await chat.runSubagent(definition, task: task, in: id, requester: requester)
        return nil
    }
}
