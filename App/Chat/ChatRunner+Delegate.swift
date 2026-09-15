import Foundation

/// 委派 (7g, S1–S8): a helper works a subtask in a conversation of its own, run by this runner like any other; the
/// report comes back as the delegate call's result.
extension ChatRunner {
    /// How a subtask ended (S5).
    enum SubtaskEnd: Equatable, Sendable {
        case done
        case failed(String)
        case limit(String)
        case stopped
    }

    private enum Prepared {
        /// The helper, and the subagent's definition when the name was one (user 2026-09-15).
        case go(Delegation, AgentRecord, SubagentDefinition?)
        case refused(String)
        /// Named someone who can't take it (9e, I): Bob may find a stand-in; else the refusal.
        case unplaced(Delegation, name: String, refusal: String)
    }

    /// The project's Agents able to work, the Agent itself aside (S1).
    func colleagues(of agent: AgentRecord, in projectID: UUID) -> [AgentRecord] {
        agents.agents.filter { $0.id != agent.id && canWork($0, in: projectID) }
    }

    /// A subtask of this conversation waiting for 允许 / 拒绝: its parent's row says 「等你确认」 too (S6).
    func subtaskWaiting(_ id: UUID) -> Conversation? {
        conversations.subtasks(of: id).first { approvals[$0.id] != nil }
    }

    /// Delegate calls side by side (S3): each goes through the gate in turn — approvals ask one at a time — then the
    /// helpers work at once, four at a time; each result lands as soon as it is in.
    func delegate(_ calls: [ToolCall], message messageID: UUID, conversationID id: UUID, runID: UUID, agent: AgentRecord,
                  state: inout RunState) async {
        var cleared: [(callID: String, delegation: Delegation, helperID: UUID, note: String?, subagent: SubagentDefinition?)] = []
        for call in calls {
            guard isCurrent(runID, id) else { return }
            switch await gate(call, messageID: messageID, conversationID: id, runID: runID, agent: agent, state: &state) {
            case .refused(let result):
                conversations.setToolResult(result, call: call.id, message: messageID, in: id)
            case .cleared:
                switch prepare(call, conversationID: id, agent: agent, state: state) {
                case .refused(let reason):
                    conversations.setToolResult(.failed(reason), call: call.id, message: messageID, in: id)
                case let .go(delegation, helper, subagent):
                    state.delegations += 1
                    cleared.append((call.id, delegation, helper.id, nil, subagent))
                case let .unplaced(delegation, name, refusal):
                    // I (9e): the colleague it named can't take it — Bob finds one who can, or it's refused as before.
                    let helper = await substitute(for: name, delegation: delegation, conversationID: id, agent: agent)
                    guard isCurrent(runID, id) else { return }
                    guard let helper else {
                        conversations.setToolResult(.failed(refusal), call: call.id, message: messageID, in: id)
                        continue
                    }
                    state.delegations += 1
                    cleared.append((call.id, delegation, helper.id, "「\(name)」现在不能接活，换成了 \(helper.displayName)。", nil))
                }
            }
        }
        guard isCurrent(runID, id), !cleared.isEmpty else { return }
        let requesterID = agent.id
        // Four at a time: they start together, and the next four once those are in.
        for start in stride(from: 0, to: cleared.count, by: TeamLimits.concurrentSubtasks) {
            let jobs = cleared[start..<min(start + TeamLimits.concurrentSubtasks, cleared.count)].map { job in
                Task {
                    // Timed inside: they finish in any order, and each step's time is its own (8c).
                    let began = Date()
                    let done = await self.runSubtask(job.delegation, helperID: job.helperID, callID: job.callID, message: messageID, parent: id,
                                                     requesterID: requesterID, subagent: job.subagent)
                    return (done: done, seconds: Date().timeIntervalSince(began), note: job.note)
                }
            }
            for job in jobs {
                let (done, seconds, note) = await job.value
                state.delegatedTokens += done.tokens
                var result = done.result
                result.seconds = seconds
                if let note { result.output = note + "\n\n" + result.output }
                if isCurrent(runID, id) { conversations.setToolResult(result, call: done.callID, message: messageID, in: id) }
            }
        }
    }

    /// Whom a delegation goes to, or why it can't go (S1, S4).
    private func prepare(_ call: ToolCall, conversationID id: UUID, agent: AgentRecord, state: RunState) -> Prepared {
        guard let conversation = conversations.conversation(id), !conversation.isSubtask else { return .refused("子任务里不能再委派。") }
        guard let delegation = Delegation.parse(call.arguments) else { return .refused("task 要写：交待的事。没有委派出去。") }
        if state.delegations >= TeamLimits.delegationsPerRun {
            return .refused("这一轮已经委派了 \(TeamLimits.delegationsPerRun) 次（上限），剩下的自己做。")
        }
        if state.delegatedTokens >= TeamLimits.delegatedTokensPerRun {
            return .refused("这一轮的子任务已经用了约 \(ContextBudget.format(TeamLimits.delegatedTokensPerRun)) token（上限），剩下的自己做。")
        }
        guard let name = delegation.to else { return .go(delegation, agent, nil) }
        // A subagent (user 2026-09-15): the Agent lends its model and tools, the definition its prompt and limits.
        if let definition = subagents?.definition(named: name) { return .go(delegation, agent, definition) }
        let able = colleagues(of: agent, in: conversation.projectID)
        // The Agent's own name, or its role's with no idle colleague of that role, is its clone.
        guard let helper = TeamTools.resolve(name, among: [agent] + able, isIdle: { self.isIdle($0) }) else {
            let names = able.map(\.displayName)
            return .unplaced(delegation, name: name, refusal: "没有叫「\(name)」的同事能接活。"
                             + (names.isEmpty ? "现在没有同事能接活" : "能委派的：" + names.joined(separator: "、")) + "；不写 to 就是交给你自己的分身。")
        }
        return .go(delegation, helper, nil)
    }

    /// I (9e): a stand-in for a colleague who can't take the work — one of its role first, else Bob's pick.
    private func substitute(for name: String, delegation: Delegation, conversationID id: UUID, agent: AgentRecord) async -> AgentRecord? {
        guard conductorModel() != nil, let conversation = conversations.conversation(id) else { return nil }
        let able = colleagues(of: agent, in: conversation.projectID)
        guard !able.isEmpty else { return nil }
        let named = TeamTools.resolve(name, among: agents.agents.filter { $0.id != agent.id }, isIdle: { _ in true })
        let situation = named.map { "\(agent.displayName) 想交给 \($0.displayName)，但它现在不能接活" } ?? "\(agent.displayName) 想交给「\(name)」，没有这个同事"
        return await standIn(for: named, among: able, task: delegation.task, situation: situation, in: id)
    }

    /// One subtask, start to end (S2, S5): its conversation, the brief with the files' text, the helper's run, then
    /// the report.
    func runSubtask(_ delegation: Delegation, helperID: UUID, callID: String, message messageID: UUID, parent id: UUID,
                    requesterID: UUID, subagent: SubagentDefinition? = nil) async -> (callID: String, result: ToolResult, tokens: Int) {
        guard let parent = conversations.conversation(id), let helper = agents.agent(helperID), let requester = agents.agent(requesterID) else {
            return (callID, .failed("子任务没能开始：对话或 Agent 不在了。"), 0)
        }
        var link = SubtaskLink(conversationID: id, messageID: messageID, callID: callID, requesterID: requesterID,
                               requesterName: requester.displayName, readOnly: delegation.readOnly, isCheck: false)
        link.subagent = subagent?.name
        let child = conversations.openSubtask(projectID: parent.projectID, agentID: helperID, title: delegation.title, link: link)
        conversations.setSubtask(child.id, call: callID, message: messageID, in: id)
        let files = delegation.files.map { "@" + $0 }.joined(separator: " ")
        let mentions = files.isEmpty ? [] : workRoot(for: parent).map { FileMentions.snapshot(files, root: $0) } ?? []
        conversations.append(Message(role: .user, text: delegation.brief(from: requester.displayName), mentions: mentions), to: child.id)
        let end = await work(child.id, helper: helper)
        let finished = conversations.conversation(child.id) ?? child
        let name = subagent?.displayName ?? (helperID == requesterID ? "分身" : helper.displayName)
        return (callID, Subtasks.report(finished, end: end, helper: name), Subtasks.tokens(finished))
    }

    /// `/名字 任务` (user 2026-09-15): the conversation's Agent lends its model and tools; the subtask runs at once and the
    /// report comes back as the subagent's own message. The delegate call is written into the thread as the card.
    func runSubagent(_ definition: SubagentDefinition, task: String, in id: UUID, requester: AgentRecord) async {
        let callID = "sub-" + UUID().uuidString.prefix(8).lowercased()
        let arguments = String(decoding: (try? JSONSerialization.data(withJSONObject: ["to": definition.name, "task": task])) ?? Data(),
                               as: UTF8.self)
        let message = Message(role: .agent, agentID: requester.id, speakerName: requester.displayName, text: "", note: "你用 /\(definition.name) 派的",
                              toolCalls: [ToolCall(id: callID, name: TeamTools.delegateName, arguments: arguments)], runID: UUID())
        conversations.append(message, to: id)
        let done = await runSubtask(Delegation(to: definition.name, task: task), helperID: requester.id, callID: callID, message: message.id,
                                    parent: id, requesterID: requester.id, subagent: definition)
        conversations.setToolResult(done.result, call: callID, message: message.id, in: id)
        announce(Message(role: .agent, agentID: nil, speakerName: definition.displayName,
                         text: "**\(definition.displayName)交回的报告**\n\n" + done.result.output, runID: UUID()), in: id)
    }

    /// The helper's run, awaited however it ends (S5, S7).
    func work(_ id: UUID, helper: AgentRecord) async -> SubtaskEnd {
        await withCheckedContinuation { continuation in
            subtaskWaiters[id] = continuation
            start(id, agent: helper)
            // It couldn't start (no model): the reply saying so is its end.
            if activeRuns[id] == nil { settleSubtask(id) }
        }
    }

    /// A subtask's run is over, however it ended: the call waiting for it goes on (S5). `false` for any other
    /// conversation.
    @discardableResult
    func settleSubtask(_ id: UUID, _ end: SubtaskEnd? = nil) -> Bool {
        guard let conversation = conversations.conversation(id), conversation.isSubtask else { return false }
        let last = conversation.messages.last { $0.role == .agent && !$0.isHidden }
        let outcome = end ?? (last?.isStopped == true ? .stopped : last?.failure.map { .failed($0) } ?? .done)
        subtaskWaiters.removeValue(forKey: id)?.resume(returning: outcome)
        return true
    }

    /// S4: why a subtask must stop now, or `nil`. A lane is the member's own work (9e): a run's own limits end it.
    func subtaskLimit(_ conversation: Conversation, calls: Int, began: Date) -> String? {
        guard conversation.isSubtask, !conversation.isLane else { return nil }
        if calls >= TeamLimits.subtaskCalls { return "用满了 \(TeamLimits.subtaskCalls) 次模型调用" }
        if Date.now.timeIntervalSince(began) > TeamLimits.subtaskDeadline { return "超过了 \(Int(TeamLimits.subtaskDeadline / 60)) 分钟" }
        if Subtasks.tokens(conversation) >= TeamLimits.subtaskTokens { return "用满了约 \(ContextBudget.format(TeamLimits.subtaskTokens)) token" }
        return nil
    }

    /// At a limit the subtask ends where it is — no 继续 to ask for, the parent decides (S4, S5).
    func endSubtask(_ id: UUID, runID: UUID, reason: String) {
        guard isCurrent(runID, id) else { return }
        end(id)
        conversations.closeOpenCalls(in: id, ToolResult(status: .stopped, output: "子任务到了上限，这一步没有执行。"))
        if let last = conversations.conversation(id)?.messages.last(where: { $0.runID == runID && !$0.isHidden }) {
            conversations.setNote(Self.joined(last.note, ["子任务到了上限：\(reason)"]) ?? "", message: last.id, in: id)
        }
        deliverSteering(id)
        settleSubtask(id, .limit(reason))
    }
}

/// A subtask's report and its accounts (S5).
enum Subtasks {
    static func tokens(_ conversation: Conversation) -> Int {
        conversation.messages.reduce(0) { total, message in
            total + (message.role == .agent || message.isUpkeep ? (message.usage?.input ?? 0) + (message.usage?.output ?? 0) : 0)
        }
    }

    /// The files it wrote, each once.
    static func written(_ conversation: Conversation) -> [String] {
        var files: [String] = []
        for call in conversation.messages.flatMap(\.toolCalls) {
            if let result = call.result, result.status == .done, let path = result.savedPath, !files.contains(path) { files.append(path) }
        }
        return files
    }

    /// The last reply (≤ 6,000 characters), the files, the tokens; an error result unless it finished.
    static func report(_ conversation: Conversation, end: ChatRunner.SubtaskEnd, helper: String) -> ToolResult {
        var text = conversation.messages.last { $0.role == .agent && !$0.isHidden && $0.failure == nil && !$0.text.isEmpty }?.text ?? ""
        if text.count > TeamLimits.reportCharacters {
            text = String(text.prefix(TeamLimits.reportCharacters))
                + "\n\n（报告太长，只交回了前 \(TeamLimits.reportCharacters) 字；全文在子任务「\(conversation.title)」里。）"
        }
        let head = switch end {
        case .done: "\(helper) 做完了。报告："
        case .failed(let reason): "\(helper) 没有做完：出错了（\(reason)）。已经写下的："
        case .limit(let reason): "\(helper) 没有做完：到了子任务的上限（\(reason)）。已经写下的："
        case .stopped: "\(helper) 被用户停止了。已经写下的："
        }
        var parts = [head + "\n\n" + (text.isEmpty ? "（没有写下什么）" : text)]
        let files = written(conversation)
        if !files.isEmpty { parts.append("它写过的文件：" + files.joined(separator: "、")) }
        parts.append("子任务用了约 \(ContextBudget.format(tokens(conversation))) token。")
        return ToolResult(status: end == .done ? .done : .failed, output: parts.joined(separator: "\n\n"))
    }
}
