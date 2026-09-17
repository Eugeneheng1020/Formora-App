import Foundation

/// Bob as the conductor (9e). A group message for several members — or for nobody, with several able — is arranged by
/// Bob with his own model: who works together in the background, who after whom, a word to each (A, B); an `@`-ed
/// member who can't work is replaced (F). After a turn he looks whether the work is done and hands it on if not (C);
/// side-by-side results end in his summary (D); a member whose reply failed has its work taken over (E). Without his
/// model, or when he doesn't answer, the rules of 7g stand.
extension ChatRunner {
    /// An arrangement under way (9e). The banner reads it.
    struct Conduct: Equatable {
        let messageID: UUID
        var stages: [[Conductor.Step]]
        /// Each lane's subtask, by member.
        var lanes: [UUID: UUID]
        var stage = 0
        /// Where the thread stood when the stage began: a stage in the thread writes its replies after this.
        var mark = 0
        /// D: Bob's summary asked for — the arrangement ends when it lands.
        var summarized = false
    }

    enum ConductEnd: Equatable {
        case done, stopped, paused
        /// A step didn't finish: what came after needed it.
        case unfinished(String)
    }

    // MARK: Bob

    /// Bob's one call: his model alone — a member's would be the member judging its own work. It counts in the
    /// conversation's /cost, like the dispatcher's (7g). `nil` without his model or an answer.
    func askBob(_ system: String, _ prompt: String, in id: UUID, thinks: Bool = true) async -> String? {
        guard let model = conductorModel(), let reply = await oneShot(system: system, prompt: prompt, candidates: [model], thinks: thinks) else {
            return nil
        }
        conversations.append(Message(role: .user, text: "", model: reply.model, usage: reply.usage, isHidden: true, isUpkeep: true), to: id)
        return reply.summary
    }

    func member(_ agent: AgentRecord) -> Conductor.Member {
        Conductor.Member(name: agent.displayName, role: agent.role.name, subtitle: agent.subtitle, isBusy: !isIdle(agent.id))
    }

    private func name(of agentID: UUID) -> String { agents.agent(agentID)?.displayName ?? ConversationReadiness.deletedAgentName }

    // MARK: Routing

    /// A user's group message: Bob arranges it when he has a model; otherwise the dispatcher (no `@`) or the queue
    /// (`@`), as in 7g.
    func route(_ id: UUID, message messageID: UUID) {
        guard let conversation = conversations.conversation(id), conversation.isGroup,
              let message = conversation.messages.first(where: { $0.id == messageID }) else { return }
        // A new message: failed work may be taken over again (E); a long one's cards get Bob's title (H).
        takeovers[id] = nil
        nameCard(id, message: messageID)
        guard conductorModel() != nil else {
            return message.assignees.isEmpty ? assign(id, message: messageID) : dispatch(id, to: message.assignees)
        }
        conduct(id, message: message)
    }

    /// F: why an `@`-ed member can't work here now, or `nil`.
    func unavailability(_ agent: AgentRecord, in conversation: Conversation) -> String? {
        if conversation.members.first(where: { $0.agentID == agent.id })?.isMuted == true { return "在这个群里停用了" }
        if !agent.isActive { return "已停用" }
        if !agent.projectIDs.contains(conversation.projectID) { return "没有这个项目的权限" }
        return AgentReadiness.isUsable(agent.primaryModel, providers: providers) ? nil : "模型不可用"
    }

    /// F: the `@`-ed who can work, and for each who can't an idle member of the same role; a part nobody of that role
    /// can take is left to Bob. The notes say who was replaced — the one thing of his the user reads.
    func standIns(_ named: [UUID], in conversation: Conversation) -> (agents: [UUID], unplaced: [String], notes: [String]) {
        let able = workers(in: conversation)
        var placed: [UUID] = []
        var unplaced: [String] = []
        var notes: [String] = []
        for id in named {
            guard let agent = agents.agent(id) else { continue }
            guard let reason = unavailability(agent, in: conversation) else {
                if !placed.contains(id) { placed.append(id) }
                continue
            }
            let sameRole = able.filter { $0.roleID == agent.roleID && !named.contains($0.id) && !placed.contains($0.id) }
            if let standIn = sameRole.first(where: { isIdle($0.id) }) ?? sameRole.first {
                placed.append(standIn.id)
                notes.append("\(agent.displayName) 现在不能接活（\(reason)），换成了 \(standIn.displayName)")
            } else {
                unplaced.append(agent.displayName)
                notes.append("\(agent.displayName) 现在不能接活（\(reason)）")
            }
        }
        return (placed, unplaced, notes)
    }

    // MARK: Bob's arrangement (A, B)

    /// One member and nothing else to place goes straight to it; anything more is Bob's to arrange.
    func conduct(_ id: UUID, message: Message) {
        guard activeRuns[id] == nil, !dispatching.contains(id), conducts[id] == nil,
              let conversation = conversations.conversation(id) else { return }
        let able = workers(in: conversation)
        guard !able.isEmpty else { return }
        let named = standIns(message.assignees, in: conversation)
        if named.unplaced.isEmpty, named.agents.count == 1 || (message.assignees.isEmpty && able.count == 1) {
            let agentID = named.agents.first ?? able[0].id
            // An `@` as sent needs no line; a stand-in or a pick does.
            if !named.notes.isEmpty || message.assignees.isEmpty { recordPick(agentID, notes: named.notes, message: message.id, in: id) }
            return dispatch(id, to: [agentID])
        }
        let allowed = message.assignees.isEmpty || !named.unplaced.isEmpty ? able : named.agents.compactMap { agents.agent($0) }
        dispatching.insert(id)
        dispatchTasks[id] = Task { [weak self] in
            guard let self else { return }
            let stages = await self.plan(message, in: id, allowed: allowed, required: named.agents, unplaced: named.unplaced)
            // Stopped while he thought: nothing starts.
            guard self.dispatching.remove(id) != nil else { return }
            self.dispatchTasks[id] = nil
            if let stages { return self.arrange(id, message: message, stages: stages, notes: named.notes) }
            // No answer from Bob: 7g's rules — the dispatcher, or the `@`-ed one after another.
            if named.agents.isEmpty { return self.assign(id, message: message.id) }
            self.arrange(id, message: message, stages: named.agents.map { [Conductor.Step(agentID: $0, brief: "")] }, notes: named.notes)
        }
    }

    private func plan(_ message: Message, in id: UUID, allowed: [AgentRecord], required: [UUID], unplaced: [String]) async -> [[Conductor.Step]]? {
        guard let conversation = conversations.conversation(id) else { return nil }
        let before = conversation.messages.prefix { $0.id != message.id }.filter { !$0.isHidden && $0.event == nil && !$0.text.isEmpty }
        let recent = before.suffix(6).map { (speaker: $0.role == .user ? "用户" : $0.speakerName ?? "Agent", text: String($0.text.prefix(160))) }
        let request = Conductor.request(message: message.text, members: allowed.map(member), named: required.map { name(of: $0) },
                                        unavailable: unplaced, files: message.mentions.map(\.path), recent: Array(recent),
                                        handover: companions(of: message.id, in: conversation).first)
        guard let reply = await askBob(Conductor.system, request, in: id), let parsed = Conductor.parse(reply) else { return nil }
        let steps = Conductor.steps(parsed, resolve: { TeamTools.resolve($0, among: allowed, isIdle: { self.isIdle($0) })?.id }, required: required)
        return steps.isEmpty ? nil : steps
    }

    /// The arrangement lands: the message's assignees, the line — the arrangement, no reasons — the lanes opened; the
    /// first stage starts.
    func arrange(_ id: UUID, message: Message, stages: [[Conductor.Step]], notes: [String]) {
        guard let conversation = conversations.conversation(id), activeRuns[id] == nil, conducts[id] == nil else { return }
        let everyone = stages.flatMap { $0.map(\.agentID) }
        guard let first = everyone.first else { return }
        guard everyone.count > 1 else {
            recordPick(first, notes: notes, message: message.id, in: id)
            return dispatch(id, to: [first])
        }
        conversations.setAssignees(everyone, message: message.id, in: id)
        // H: each step's card is named by its part.
        for step in stages.joined() where !step.brief.isEmpty {
            conversations.setCardTitle(Conductor.laneTitle(step.brief, message: message.text), for: "\(message.id)#\(step.agentID)", in: id)
        }
        var lanes: [ThreadEvent.Arrangement.Lane] = []
        for stage in stages where stage.count > 1 {
            for step in stage {
                let link = SubtaskLink(conversationID: id, messageID: message.id, callID: "", requesterID: Conductor.bobID,
                                       requesterName: conversation.groupName, readOnly: false, isCheck: false, lane: true)
                let lane = conversations.openSubtask(projectID: conversation.projectID, agentID: step.agentID,
                                                     title: Conductor.laneTitle(step.brief, message: message.text), link: link)
                lanes.append(.init(agentID: step.agentID, subtaskID: lane.id))
            }
        }
        let arrangement = ThreadEvent.Arrangement(messageID: message.id, stages: stages.map { $0.map(\.agentID) }, lanes: lanes)
        let event = ThreadEvent(kind: .conduct, title: Conductor.title(stages.map { $0.map { name(of: $0.agentID) } }),
                                detail: notes.joined(separator: "；"), arrangement: arrangement)
        conversations.append(Message(role: .user, text: "", event: event), to: id)
        conducts[id] = Conduct(messageID: message.id, stages: stages,
                               lanes: Dictionary(lanes.map { ($0.agentID, $0.subtaskID) }, uniquingKeysWith: { first, _ in first }))
        runStage(id)
    }

    private func recordPick(_ agentID: UUID, notes: [String], message messageID: UUID, in id: UUID) {
        conversations.setAssignees([agentID], message: messageID, in: id)
        conversations.append(Message(role: .user, text: "", event: ThreadEvent(kind: .dispatch, title: "分配给 \(name(of: agentID))",
                                                                              detail: notes.joined(separator: "；"), agentID: agentID)), to: id)
    }

    /// What came with the message, hidden: the canvas's hand-over, a hook's background (8d, 7b′).
    func companions(of messageID: UUID, in conversation: Conversation) -> [String] {
        guard let index = conversation.messages.firstIndex(where: { $0.id == messageID }) else { return [] }
        return conversation.messages[(index + 1)...].prefix { $0.role == .user && $0.isHidden && $0.event == nil && !$0.isUpkeep }.map(\.text)
    }

    // MARK: Stages

    /// The stage now: one member works in the thread, reading Bob's word first; several work in the background. After
    /// the last, a side-by-side ending gets Bob's summary (D).
    func runStage(_ id: UUID) {
        guard var conduct = conducts[id] else { return }
        guard conduct.stage < conduct.stages.count else {
            if let last = conduct.stages.last, last.count > 1, !conduct.summarized { return summarize(id) }
            return endConduct(id, .done)
        }
        let stage = conduct.stages[conduct.stage]
        conduct.mark = conversations.conversation(id)?.messages.count ?? 0
        conducts[id] = conduct
        guard stage.count > 1 else {
            // An empty stage can't happen (`Conductor.parse` drops them), but skipping it beats indexing into nothing.
            guard let step = stage.first else {
                conduct.stage += 1
                conducts[id] = conduct
                return runStage(id)
            }
            let after = conduct.stage > 0 ? conduct.stages[conduct.stage - 1].map { name(of: $0.agentID) } : []
            if !step.brief.isEmpty || !after.isEmpty {
                conversations.append(Message(role: .user, text: Conductor.stepBrief(step.brief, after: after), isHidden: true), to: id)
            }
            queues[id] = [step.agentID] + pending(id).filter { $0 != step.agentID }
            return advance(id)
        }
        conductTasks[id] = Task { [weak self] in
            guard let self else { return }
            let ends = await self.runLanes(id, stage)
            let rescued = await self.rescue(id, ends)
            self.stageEnded(id, lanes: rescued)
        }
    }

    /// A stage is over. One that didn't finish ends the arrangement there: what came after needed its work. In the
    /// thread the stage's last reply says — whoever gave it (a hand-off, a takeover).
    func stageEnded(_ id: UUID, lanes ends: [(agentID: UUID, end: SubtaskEnd)]? = nil) {
        guard var conduct = conducts[id] else { return }
        conductTasks[id] = nil
        let unfinished: UUID? = if let ends {
            ends.first { $0.end != .done }?.agentID
        } else {
            conduct.stages[conduct.stage].first.flatMap { step in
                let last = conversations.conversation(id)?.messages.dropFirst(conduct.mark).last { $0.role == .agent && !$0.isHidden }
                return last == nil || last?.failure != nil || last?.isStopped == true ? step.agentID : nil
            }
        }
        if let unfinished, conduct.stage + 1 < conduct.stages.count { return endConduct(id, .unfinished(name(of: unfinished))) }
        conduct.stage += 1
        conducts[id] = conduct
        runStage(id)
    }

    /// The arrangement is over. Ended early, a line says so and who never started; someone `@`-ed meanwhile is next.
    func endConduct(_ id: UUID, _ end: ConductEnd) {
        guard let conduct = conducts.removeValue(forKey: id) else { return }
        conductTasks[id] = nil
        let left = conduct.stages.dropFirst(conduct.stage + 1).flatMap { $0 }.map { name(of: $0.agentID) }
        let notStarted = left.isEmpty ? "" : " · \(left.joined(separator: "、")) 没有开始"
        let title: String? = switch end {
        case .done: nil
        case .stopped: "安排已停止" + notStarted
        case .paused: "安排停下来等你" + notStarted
        case .unfinished(let who): "\(who) 没有做完，安排停在这里" + notStarted
        }
        if let title {
            let arrangement = ThreadEvent.Arrangement(messageID: conduct.messageID, stages: conduct.stages.map { $0.map(\.agentID) })
            conversations.append(Message(role: .user, text: "", event: ThreadEvent(kind: .conductEnd, title: title, arrangement: arrangement)), to: id)
        }
        if end != .stopped, end != .paused, activeRuns[id] == nil, !pending(id).isEmpty { advance(id) }
    }

    /// The banner's line (9e): who works now.
    func conductLine(_ id: UUID) -> String? {
        guard let conduct = conducts[id] else { return nil }
        guard conduct.stage < conduct.stages.count else { return conduct.summarized ? "正在汇总" : nil }
        let names = conduct.stages[conduct.stage].map { name(of: $0.agentID) }
        guard let first = names.first else { return nil }
        let now = names.count > 1 ? names.joined(separator: "、") + " 同时在做" : first + " 在做"
        return conduct.stages.count > 1 ? "第 \(conduct.stage + 1)/\(conduct.stages.count) 步 · " + now : now
    }

    // MARK: Lanes (「各自在后台开工」)

    /// A stage's lanes, four at a time (S3's limit); each reply goes to the group as soon as it is in.
    private func runLanes(_ id: UUID, _ stage: [Conductor.Step]) async -> [(agentID: UUID, end: SubtaskEnd)] {
        var ends: [(agentID: UUID, end: SubtaskEnd)] = []
        for start in stride(from: 0, to: stage.count, by: TeamLimits.concurrentSubtasks) {
            guard conducts[id] != nil else { break }
            let jobs = stage[start..<min(start + TeamLimits.concurrentSubtasks, stage.count)].map { step in
                Task { (agentID: step.agentID, end: await self.runLane(id, step)) }
            }
            for job in jobs { ends.append(await job.value) }
        }
        return ends
    }

    /// One lane: Bob's word and the group's context (hidden), the user's words as sent, the member's run, the reply
    /// posted.
    private func runLane(_ id: UUID, _ step: Conductor.Step) async -> SubtaskEnd {
        guard let conduct = conducts[id], let laneID = conduct.lanes[step.agentID], let agent = agents.agent(step.agentID),
              let group = conversations.conversation(id), let index = group.messages.firstIndex(where: { $0.id == conduct.messageID })
        else { return .failed("没能开始：对话或 Agent 不在了") }
        let message = group.messages[index]
        let others = conduct.stages[conduct.stage].filter { $0.agentID != step.agentID }.map { (name: name(of: $0.agentID), brief: $0.brief) }
        let recent = group.messages[..<index].filter { !$0.isHidden && $0.event == nil && !$0.text.isEmpty }.suffix(6)
            .map { (speaker: $0.role == .user ? "用户" : $0.speakerName ?? "Agent", text: String($0.text.prefix(400))) }
        // What earlier stages produced: this stage came after them.
        let earlier = group.messages[(index + 1)...].filter { $0.role == .agent && !$0.isHidden && !$0.text.isEmpty }
            .map { "〔\($0.speakerName ?? "Agent")〕" + String($0.text.prefix(4_000)) }
        let extra = companions(of: message.id, in: group) + (earlier.isEmpty ? [] : ["前面几步的产出：\n" + earlier.joined(separator: "\n\n")])
        conversations.append(Message(role: .user, text: Conductor.laneBrief(group: group.groupName, brief: step.brief, others: others,
                                                                            recent: Array(recent), extra: extra), isHidden: true), to: laneID)
        conversations.append(Message(role: .user, text: message.text, attachments: message.attachments, mentions: message.mentions), to: laneID)
        // 10l: its own copy of the project while it works — nobody else writes over it, nor it over them.
        if let folder = laneCopiesFolder, let source = projectRoot(group.projectID) {
            laneCopies[laneID] = await Task.detached { LaneCopies.make(from: source, id: laneID, in: folder) }.value
        }
        let began = Date()
        let end = await work(laneID, helper: agent)
        let merged = await mergeLane(laneID, agent: agent)
        postLane(id, lane: laneID, agent: agent, end: end, seconds: Date().timeIntervalSince(began), merged: merged)
        return end
    }

    /// 10l: where a conversation's tools work — a lane's own copy while it works (a helper it asked: the same copy),
    /// else the project.
    func workRoot(for conversation: Conversation) -> URL? {
        if let copy = laneCopies[conversation.id] { return copy.root }
        if let link = conversation.parent, let copy = laneCopies[link.conversationID] { return copy.root }
        return projectRoot(conversation.projectID)
    }

    /// 10l: the lane's changes back into the project — one lane at a time — and its copy gone. `nil`: it had none.
    private func mergeLane(_ laneID: UUID, agent: AgentRecord) async -> LaneCopies.Merge? {
        guard let copy = laneCopies.removeValue(forKey: laneID) else { return nil }
        jobs.stop(conversation: laneID)
        let merge = await LaneCopies.mergeSerially(copy, name: agent.displayName)
        Task.detached { LaneCopies.remove(copy) }
        return merge
    }

    /// A lane's last reply goes to the group under the member's name; its steps stay in the lane (「看过程」). Its tokens
    /// are counted there, not again here.
    private func postLane(_ id: UUID, lane laneID: UUID, agent: AgentRecord, end: SubtaskEnd, seconds: Double,
                          merged: LaneCopies.Merge? = nil) {
        guard let lane = conversations.conversation(laneID), conversations.conversation(id) != nil else { return }
        let text = lane.messages.last { $0.role == .agent && !$0.isHidden && $0.failure == nil && !$0.text.isEmpty }?.text ?? ""
        var posted = Message(role: .agent, agentID: agent.id, speakerName: agent.displayName, text: text, durationSeconds: seconds, runID: UUID())
        switch end {
        case .done: if text.isEmpty { posted.note = "没有写下文字，做了什么在过程里" }
        case .failed(let reason): if text.isEmpty { posted.failure = reason } else { posted.note = "没有做完：出错了（\(reason)）" }
        case .limit(let reason): posted.note = "没有做完：\(reason)"
        case .stopped: posted.isStopped = true
        }
        // 10l: what came back from its copy, and what was kept beside.
        if let words = merged.flatMap(LaneCopies.note) { posted.note = Self.joined(posted.note, [words]) }
        posted.lane = laneID
        announce(posted, in: id)
    }

    // MARK: Taking over (E, I)

    /// Who takes over from `agent`: an idle member of its role first, else Bob's pick; `nil`, nobody. Those still to
    /// come in the arrangement are asked last — they have their own part.
    func standIn(for agent: AgentRecord?, among able: [AgentRecord], task: String, situation: String, in id: UUID) async -> AgentRecord? {
        let later = conducts[id].map { Set($0.stages.dropFirst($0.stage + 1).joined().map(\.agentID)) } ?? []
        let free = able.filter { !later.contains($0.id) }
        let pool = free.isEmpty ? able : free
        guard !pool.isEmpty else { return nil }
        if let agent {
            let sameRole = pool.filter { $0.roleID == agent.roleID }
            if let pick = sameRole.first(where: { isIdle($0.id) }) ?? sameRole.first { return pick }
        }
        guard let answer = await askBob(Conductor.pickSystem, Conductor.pickRequest(task: task, situation: situation, members: pool.map(member)),
                                        in: id),
              let pick = Dispatcher.parse(answer) else { return nil }
        return TeamTools.resolve(pick.to, among: pool, isIdle: { self.isIdle($0) })
    }

    /// E: a member's reply failed in the thread — its work goes to another who can do it: a line says who, the one
    /// taking over reads what it takes on. `true` while Bob chooses (the queue goes on once he has).
    func takeOver(_ id: UUID, from agent: AgentRecord, reason: String) -> Bool {
        guard conductorModel() != nil, autoruns[id] == nil, (takeovers[id] ?? 0) < TeamLimits.takeovers,
              let conversation = conversations.conversation(id), conversation.isGroup, !conversation.isSubtask else { return false }
        let able = workers(in: conversation).filter { $0.id != agent.id }
        guard !able.isEmpty else { return false }
        takeovers[id, default: 0] += 1
        let task = conversation.messages.last { $0.role == .user && !$0.isHidden && $0.event == nil }?.text ?? ""
        dispatching.insert(id)
        dispatchTasks[id] = Task { [weak self] in
            guard let self else { return }
            let next = await self.standIn(for: agent, among: able, task: task, situation: "\(agent.displayName) 做这件事时出错了：\(reason)", in: id)
            guard self.dispatching.remove(id) != nil else { return }
            self.dispatchTasks[id] = nil
            if let next {
                let event = ThreadEvent(kind: .takeover, title: "\(agent.displayName) 出错了，改由 \(next.displayName) 接手", agentID: next.id,
                                        from: agent.id)
                self.conversations.append(Message(role: .user, text: Conductor.takeoverBrief(from: agent.displayName, reason: reason), event: event),
                                          to: id)
                self.queues[id] = [next.id] + self.pending(id).filter { $0 != next.id }
            }
            self.advance(id)
        }
        return true
    }

    /// E for lanes: a lane that failed gives its part to another member, who works it in the thread right after this
    /// stage — what comes next still gets it. Its end then counts as done.
    private func rescue(_ id: UUID, _ ends: [(agentID: UUID, end: SubtaskEnd)]) async -> [(agentID: UUID, end: SubtaskEnd)] {
        var result = ends
        let failed = Set(ends.filter { if case .failed = $0.end { true } else { false } }.map(\.agentID))
        for (index, lane) in ends.enumerated() {
            guard case .failed(let reason) = lane.end, conductorModel() != nil, (takeovers[id] ?? 0) < TeamLimits.takeovers,
                  let conduct = conducts[id], let agent = agents.agent(lane.agentID), let conversation = conversations.conversation(id),
                  let step = conduct.stages[conduct.stage].first(where: { $0.agentID == lane.agentID }) else { continue }
            let task = step.brief.isEmpty ? conversation.messages.first { $0.id == conduct.messageID }?.text ?? "" : step.brief
            let able = workers(in: conversation).filter { !failed.contains($0.id) }
            guard let next = await standIn(for: agent, among: able, task: task, situation: "\(agent.displayName) 做这部分时出错了：\(reason)", in: id),
                  var current = conducts[id] else { continue }
            takeovers[id, default: 0] += 1
            let brief = "接手 \(agent.displayName) 没做完的部分" + (step.brief.isEmpty ? "" : "：\(step.brief)")
            current.stages.insert([Conductor.Step(agentID: next.id, brief: brief)], at: current.stage + 1)
            conducts[id] = current
            conversations.append(Message(role: .user, text: "", event: ThreadEvent(kind: .takeover, title: "\(agent.displayName) 出错了，改由 \(next.displayName) 接手",
                                                                                  agentID: next.id, from: agent.id)), to: id)
            result[index].end = .done
        }
        return result
    }

    // MARK: After a turn (C) and at the end (D)

    /// C: after a member's turn — nobody handed on, nobody waiting — Bob looks whether the user's request is done; if
    /// not, he hands it on, within the chain's limits (M3). `true` while he looks (the queue goes on after).
    func reviewTurn(_ id: UUID, agentID: UUID?) -> Bool {
        guard conductorModel() != nil, conducts[id] == nil, autoruns[id] == nil, let conversation = conversations.conversation(id),
              conversation.isGroup, !conversation.isSubtask, !conversation.planMode, relayLimit(conversation) == nil,
              let agent = agents.agent(agentID),
              let reply = conversation.messages.last(where: { $0.role == .agent && !$0.isHidden && $0.agentID == agent.id }), !reply.text.isEmpty,
              let request = conversation.messages.last(where: { $0.role == .user && !$0.isHidden && $0.event == nil }) else { return false }
        let others = workers(in: conversation).filter { $0.id != agent.id }
        guard !others.isEmpty else { return false }
        dispatching.insert(id)
        reviewing.insert(id)
        dispatchTasks[id] = Task { [weak self] in
            guard let self else { return }
            let prompt = Conductor.reviewRequest(message: request.text, speaker: agent.displayName, reply: reply.text, members: others.map(self.member),
                                                 handedOn: self.relays[id]?.hops ?? 0)
            let verdict = await self.askBob(Conductor.reviewSystem, prompt, in: id).flatMap(Conductor.parseReview)
            self.reviewing.remove(id)
            guard self.dispatching.remove(id) != nil else { return }
            self.dispatchTasks[id] = nil
            if case let .handOn(to, brief) = verdict, let next = TeamTools.resolve(to, among: others, isIdle: { self.isIdle($0) }) {
                self.relayOnward(id, from: agent, Handoff(agent: next, brief: brief.isEmpty ? "接着做" : brief))
            }
            self.advance(id)
        }
        return true
    }

    /// D: members who worked side by side at the end — Bob puts their results together for the user, then the
    /// arrangement is over.
    private func summarize(_ id: UUID) {
        guard var conduct = conducts[id], let group = conversations.conversation(id),
              let message = group.messages.first(where: { $0.id == conduct.messageID }) else { return endConduct(id, .done) }
        conduct.summarized = true
        conducts[id] = conduct
        let lanes = Set(conduct.stages.last?.compactMap { conduct.lanes[$0.agentID] } ?? [])
        let results = group.messages.filter { $0.lane.map(lanes.contains) == true }
            .map { (name: $0.speakerName ?? "Agent", text: $0.failure.map { "（出错了：\($0)）" } ?? $0.text) }
        conductTasks[id] = Task { [weak self] in
            guard let self else { return }
            let summary = await self.askBob(Conductor.summarySystem, Conductor.summaryRequest(message: message.text, results: results), in: id)
            // Stopped while he wrote: nothing lands.
            guard self.conducts[id]?.messageID == message.id else { return }
            self.conductTasks[id] = nil
            if let summary {
                self.announce(Message(role: .user, text: "〔Bob 的汇总〕\n" + summary,
                                      event: ThreadEvent(kind: .summary, title: "Bob · 汇总", detail: summary)), in: id)
            }
            self.runStage(id)
        }
    }

    // MARK: Names (H)

    /// A long message's cards get a short title from Bob — for a message that opens cards: any in a group; in a direct
    /// chat the first, or one branched on the canvas.
    func nameCard(_ id: UUID, message messageID: UUID) {
        guard conductorModel() != nil, let conversation = conversations.conversation(id), !conversation.isSubtask,
              conversation.cardTitles[messageID.uuidString] == nil,
              let message = conversation.messages.first(where: { $0.id == messageID }), Conductor.needsCardTitle(message.text),
              let input = TaskTitle.input(from: message.text) else { return }
        if !conversation.isGroup {
            let first = conversation.messages.first { $0.role == .user && !$0.isHidden && $0.event == nil }
            guard first?.id == messageID || message.boardParent != nil else { return }
        }
        Task { [weak self] in
            guard let self, let reply = await self.askBob(TaskTitle.system, input, in: id, thinks: false), let title = TaskTitle.parse(reply) else { return }
            self.conversations.setCardTitle(title, for: messageID.uuidString, in: id)
        }
    }
}
