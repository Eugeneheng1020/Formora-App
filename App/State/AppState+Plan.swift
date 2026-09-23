import Foundation

/// Plan mode and self-review from the composer (7d, D5, D7).
extension AppState {
    /// `/plan`: plan mode on or off. `/plan 文字` turns it on and sends the words, so the Agent starts planning them.
    func togglePlanMode(_ id: UUID, message: String, projectRoot: URL?, projectName: String?) -> String? {
        guard let conversation = conversations.conversation(id) else { return nil }
        let isOn = message.isEmpty ? !conversation.planMode : true
        conversations.setPlanMode(isOn, in: id)
        guard !message.isEmpty else {
            toasts.show(isOn ? "已开启计划模式" : "已关闭计划模式",
                        note: isOn ? "每件事它先看、先问、先出方案，你点「按这个计划做」它才动手；一直开着，再点 plan 关闭" : "恢复直接执行", seconds: 3)
            return nil
        }
        sendFromCommand(message, to: id, projectRoot: projectRoot, projectName: projectName)
        return nil
    }

    /// 「按这个计划做」 under a plan-mode run: the Agent that planned is told to go, and the plan is carried out without asking
    /// (dangerous commands still ask). Plan mode stays on for what comes next (user 2026-09-23).
    func executePlan(_ id: UUID, projectRoot: URL?, projectName: String?) {
        conversations.setPlanApproved(true, in: id)
        sendFromCommand(PlanTool.goAhead, to: id, projectRoot: projectRoot, projectName: projectName)
    }

    /// `/review` (10h): 旁审 reads what the Agent did in its latest run — its note lands in the thread.
    func startReview(_ id: UUID, focus: String) -> String? {
        guard let conversation = conversations.conversation(id), let agent = commandAgent(conversation) else {
            return "这条对话里没有能审阅的 Agent"
        }
        guard !chat.isRunning(id) else { return "它还在做，等这一轮做完再审" }
        guard conversation.messages.contains(where: { $0.role == .agent && $0.failure == nil && !$0.isHidden }) else {
            return "它还没有交付过东西"
        }
        chat.review(id, agent: agent, focus: focus)
        toasts.show("旁审在看", note: "看完会写在对话里", seconds: 2)
        return nil
    }

    /// `/loop N [要做的事]`, `/goal 目标` (7g, A1): rounds begin at once — in a group the `@`-ed members in turn, else
    /// every member able to work.
    func startAutorun(_ id: UUID, action: ComposerCommand.Action, argument: String) -> String? {
        guard let conversation = conversations.conversation(id) else { return nil }
        guard !chat.isRunning(id) else { return "它还在做，等这一轮做完，或者先停止" }
        let members: [UUID]
        if conversation.isGroup {
            let named = Mentions.assignees(in: argument, members: ConversationReadiness.members(of: conversation, agents: agents))
            members = named.isEmpty ? chat.workers(in: conversation).map(\.id) : named
        } else {
            members = [conversation.agentID].compactMap { $0 }
        }
        guard !members.isEmpty else { return "没有能接活的 Agent" }
        if action == .loop {
            guard let parsed = Autoruns.parseLoop(argument) else { return "写上轮数，比如 /loop 3 接着完善这份需求" }
            if parsed.rounds > TeamLimits.rounds {
                toasts.show("最多 \(TeamLimits.rounds) 轮", note: "按 \(TeamLimits.rounds) 轮跑", seconds: 3)
            }
            chat.startAutorun(id, mode: .loop(parsed.text), rounds: parsed.rounds, members: members)
        } else {
            guard !argument.isEmpty else { return "写上目标，比如 /goal 把会员体系的 PRD 写完并自审通过" }
            chat.startAutorun(id, mode: .goal(argument), rounds: TeamLimits.rounds, members: members)
        }
        return nil
    }

    /// A message from a command: in a group it goes to whom it `@`-s, else to the Agent the command is about.
    func sendFromCommand(_ text: String, to id: UUID, projectRoot: URL?, projectName: String?) {
        guard let conversation = conversations.conversation(id) else { return }
        var assignees: [UUID] = []
        if conversation.isGroup {
            assignees = Mentions.assignees(in: text, members: ConversationReadiness.members(of: conversation, agents: agents))
            if assignees.isEmpty, let agent = commandAgent(conversation) { assignees = [agent.id] }
        }
        Task {
            if let reason = await submit(id, text: text, attachments: [], assignees: assignees, projectRoot: projectRoot,
                                         projectName: projectName) {
                toasts.show("没有发送", note: reason, isError: true)
            }
        }
    }
}
