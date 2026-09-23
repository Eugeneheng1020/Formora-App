import Foundation

/// The dispatcher and relay (7g, M1–M5): in a group the work moves sideways, member to member, in one thread.
extension ChatRunner {
    /// A chain under way: what one user message set off (M3). The banner reads it.
    struct Relay: Equatable {
        var hops = 0
        var from = ""
        var to = ""
    }

    /// Who takes over, and what they read (M2).
    struct Handoff {
        let agent: AgentRecord
        let brief: String
    }

    enum RelayEnd {
        case done, stopped, paused
    }

    // MARK: Who can work

    /// §8.7's judgement without the open-project check: active, allowed into the project, a model it can call.
    func canWork(_ agent: AgentRecord, in projectID: UUID) -> Bool {
        agent.isActive && agent.projectIDs.contains(projectID) && AgentReadiness.isUsable(agent.primaryModel, providers: providers)
    }

    /// The group's members able to take work: not muted here, and able to work (spec §9.10).
    func workers(in conversation: Conversation) -> [AgentRecord] {
        let muted = Set(conversation.members.filter(\.isMuted).map(\.agentID))
        return ConversationReadiness.members(of: conversation, agents: agents)
            .filter { !muted.contains($0.id) && canWork($0, in: conversation.projectID) }
    }

    /// Not answering anywhere right now.
    func isIdle(_ agentID: UUID) -> Bool { !activeRuns.values.contains { $0.agentID == agentID } }

    // MARK: The dispatcher (M1)

    /// A group message that `@`-s nobody: one member able to work takes it at once; otherwise a model picks by the
    /// task's nature, and whoever answered last (else the first idle member) is the fallback.
    func assign(_ id: UUID, message messageID: UUID) {
        guard activeRuns[id] == nil, !dispatching.contains(id), let conversation = conversations.conversation(id), conversation.isGroup,
              let message = conversation.messages.first(where: { $0.id == messageID }) else { return }
        let able = workers(in: conversation)
        guard let first = able.first else { return }
        if able.count == 1 {
            recordDispatch(first, reason: "群里只有它能接活", message: messageID, in: id)
            return dispatch(id, to: [first.id])
        }
        let ableIDs = able.map(\.id)
        dispatching.insert(id)
        dispatchTasks[id] = Task { [weak self] in
            guard let self else { return }
            let pick = await self.pick(message.text, in: id, among: ableIDs)
            // Stopped while it chose: nobody takes it.
            guard self.dispatching.remove(id) != nil else { return }
            self.dispatchTasks[id] = nil
            guard let pick else { return }
            self.recordDispatch(pick.agent, reason: pick.reason, message: messageID, in: id)
            self.dispatch(id, to: [pick.agent.id])
        }
    }

    private func pick(_ text: String, in id: UUID, among ableIDs: [UUID]) async -> (agent: AgentRecord, reason: String)? {
        guard let conversation = conversations.conversation(id) else { return nil }
        let able = ableIDs.compactMap { agents.agent($0) }
        guard let first = able.first else { return nil }
        let visible = conversation.messages.filter { !$0.isHidden && $0.event == nil }
        let lastSpeaker = visible.last { $0.role == .agent }.flatMap { message in able.first { $0.id == message.agentID } }
        let fallback = lastSpeaker.map { ($0, "接着它刚才的活") } ?? (able.first { isIdle($0.id) } ?? first, "它现在空闲")
        var candidates: [ModelReference] = []
        for agent in (lastSpeaker.map { [$0] } ?? []) + able.filter({ $0.id != lastSpeaker?.id }) {
            for model in [agent.primaryModel].compactMap({ $0 }) where !candidates.contains(model) {
                candidates.append(model)
            }
        }
        let members = able.map { Dispatcher.Member(name: $0.displayName, role: $0.role.name, subtitle: $0.subtitle, isBusy: !isIdle($0.id)) }
        let recent = visible.dropLast().suffix(6).map { message in
            (speaker: message.role == .user ? "用户" : message.speakerName ?? "Agent", text: String(message.text.prefix(120)))
        }
        guard let reply = await oneShot(system: Dispatcher.system, prompt: Dispatcher.request(message: text, members: members, recent: Array(recent)),
                                        candidates: candidates) else { return fallback }
        // The choice costs a call: it counts in /cost (like the memory's, 7f).
        conversations.append(Message(role: .user, text: "", model: reply.model, usage: reply.usage, isHidden: true, isUpkeep: true), to: id)
        guard let answer = Dispatcher.parse(reply.summary),
              let agent = TeamTools.resolve(answer.to, among: able, isIdle: { self.isIdle($0) }) else { return fallback }
        return (agent, answer.reason.isEmpty ? "按任务的性质" : answer.reason)
    }

    /// The pick is written on the message, as if `@`-ed, and as a line in the thread.
    private func recordDispatch(_ agent: AgentRecord, reason: String, message messageID: UUID, in id: UUID) {
        conversations.setAssignees([agent.id], message: messageID, in: id)
        conversations.append(Message(role: .user, text: "", event: ThreadEvent(kind: .dispatch, title: "分配给 \(agent.displayName)",
                                                                              detail: reason, agentID: agent.id)), to: id)
    }

    // MARK: Relay (M2–M5)

    /// handoff and goal_done are offered here with delegate (M5, S1, A3); none in a subtask.
    func teamTools(_ conversation: Conversation, agent: AgentRecord) -> [ToolSpec] {
        guard !conversation.isSubtask else { return [] }
        var specs: [ToolSpec] = []
        if conversation.isGroup, autoruns[conversation.id] == nil, workers(in: conversation).contains(where: { $0.id != agent.id }) {
            specs.append(TeamTools.handoff)
        }
        specs.append(TeamTools.delegate(colleagues: colleagues(of: agent, in: conversation.projectID).map(\.displayName),
                                        subagents: subagents?.definitions.map { ($0.name, $0.description) } ?? []))
        if autoruns[conversation.id]?.objective != nil { specs.append(TeamTools.goalDone) }
        return specs
    }

    /// The handoff tool: checked now, carried out when the turn is done — the run ends there (M2).
    func handOff(_ call: ToolCall, conversationID id: UUID, agent: AgentRecord, state: inout RunState) -> ToolResult {
        guard conversations.conversation(id)?.plansOnly == false else {
            return .failed("现在是计划模式：先把方案给用户，用户确认后再交接。")
        }
        guard let args = TeamTools.handoffArguments(call.arguments) else { return .failed("to 和 brief 都要写。没有交出去。") }
        if let earlier = state.handoff { return .failed("这一轮已经交给 \(earlier.agent.displayName) 了，一次只能交给一个人。") }
        let holder = nextHolder(args.to, conversationID: id, from: agent)
        guard let target = holder.agent else { return .failed(holder.refusal ?? "没有交出去。") }
        state.handoff = Handoff(agent: target, brief: args.brief)
        return .done("已交给 \(target.displayName)。你这一轮到这里结束，不用再回复。")
    }

    /// A reply's last line `@名字 交待` (M2): the hand-off, or a note on the reply when it can't go.
    func trailingHandoff(_ text: String, conversationID id: UUID, agent: AgentRecord) -> (handoff: Handoff?, note: String?) {
        guard let conversation = conversations.conversation(id), conversation.isGroup, !conversation.isSubtask, !conversation.plansOnly,
              autoruns[id] == nil else { return (nil, nil) }
        let others = ConversationReadiness.members(of: conversation, agents: agents).filter { $0.id != agent.id }
        guard let line = TeamTools.trailingHandoff(in: text, names: others.flatMap { [$0.displayName, $0.customName, $0.role.name] })
        else { return (nil, nil) }
        let holder = nextHolder(line.name, conversationID: id, from: agent)
        guard let target = holder.agent else { return (nil, "没有交给「\(line.name)」：\(holder.refusal ?? "")") }
        return (Handoff(agent: target, brief: line.brief.isEmpty ? "接着做" : line.brief), nil)
    }

    /// Whom a hand-off may go to, or why not (M2, M3).
    private func nextHolder(_ name: String, conversationID id: UUID, from agent: AgentRecord) -> (agent: AgentRecord?, refusal: String?) {
        guard let conversation = conversations.conversation(id) else { return (nil, "对话不在了。") }
        if let limit = relayLimit(conversation) { return (nil, limit) }
        let able = workers(in: conversation).filter { $0.id != agent.id }
        let members = ConversationReadiness.members(of: conversation, agents: agents)
        guard let target = TeamTools.resolve(name, among: able, isIdle: { self.isIdle($0) })
                ?? TeamTools.resolve(name, among: members, isIdle: { self.isIdle($0) }) else {
            return (nil, "群里没有叫「\(name)」的成员。能交给：" + able.map(\.displayName).joined(separator: "、"))
        }
        guard target.id != agent.id else { return (nil, "不能交给自己。") }
        if conversation.members.first(where: { $0.agentID == target.id })?.isMuted == true {
            return (nil, "\(target.displayName) 在这个群里停用了，交不了。")
        }
        guard canWork(target, in: conversation.projectID) else {
            return (nil, "\(target.displayName) 现在不能接活（已停用、没有这个项目的权限，或者模型不可用）。")
        }
        return (target, nil)
    }

    /// M3: why a chain can't go on, or `nil`.
    func relayLimit(_ conversation: Conversation) -> String? {
        if (relays[conversation.id]?.hops ?? 0) >= TeamLimits.hops {
            return "这条消息已经交接了 \(TeamLimits.hops) 次（上限），不再往下交。把你的结论和还没做完的事直接写给用户。"
        }
        if chainTokens(conversation) >= TeamLimits.chainTokens {
            return "这条接力已经用了约 \(ContextBudget.format(TeamLimits.chainTokens)) token（上限），不再往下交。把你的结论和还没做完的事直接写给用户。"
        }
        return nil
    }

    /// Tokens the Agents used since the user's message that started the chain.
    func chainTokens(_ conversation: Conversation) -> Int {
        let start = conversation.messages.lastIndex { $0.role == .user && !$0.isHidden && $0.event == nil } ?? 0
        return conversation.messages[start...].reduce(0) { total, message in
            total + (message.role == .agent ? (message.usage?.input ?? 0) + (message.usage?.output ?? 0) : 0)
        }
    }

    /// The hand-off happens: a line in the thread — which the member reads as its brief — and the member first in line.
    func relayOnward(_ id: UUID, from agent: AgentRecord, _ handoff: Handoff) {
        var relay = relays[id] ?? Relay()
        relay.hops += 1
        relay.from = agent.displayName
        relay.to = handoff.agent.displayName
        relays[id] = relay
        let event = ThreadEvent(kind: .handoff, title: "\(agent.displayName) → \(handoff.agent.displayName) · 第 \(relay.hops)/\(TeamLimits.hops) 次",
                                detail: handoff.brief, agentID: handoff.agent.id)
        conversations.append(Message(role: .user, text: "〔\(agent.displayName) 把接下来的工作交给了 \(handoff.agent.displayName)〕\n\(handoff.brief)",
                                     event: event), to: id)
        queues[id] = [handoff.agent.id] + pending(id).filter { $0 != handoff.agent.id }
    }

    /// A chain's end, with its count (M4). Nothing when nothing was handed on.
    func endRelay(_ id: UUID, _ end: RelayEnd) {
        guard let relay = relays.removeValue(forKey: id) else { return }
        let title = switch end {
        case .done: "接力结束 · 共交接 \(relay.hops) 次"
        case .stopped: "接力已停止 · 交接了 \(relay.hops) 次"
        case .paused: "接力停下来等你 · 已交接 \(relay.hops) 次"
        }
        conversations.append(Message(role: .user, text: "", event: ThreadEvent(kind: .relayEnd, title: title)), to: id)
    }
}
