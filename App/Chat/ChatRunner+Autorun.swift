import Foundation

/// `/loop` and `/goal` (7g, A1–A4): one Agent — or the group, in turn — works round after round on its own. The stop,
/// the banner and the dividers are the relay's; a goal is checked by another Agent, in a read-only subtask.
extension ChatRunner {
    struct Autorun: Equatable {
        enum Mode: Equatable {
            /// What each round does (may be empty: carry on).
            case loop(String)
            case goal(String)
        }

        var mode: Mode
        /// Rounds to run (loop), or at most (goal).
        var rounds: Int
        var round = 0
        /// Who answers in each round, in order.
        var members: [UUID]
        /// The first round's divider: tokens are counted from there.
        var startID: UUID?
        /// goal_done in this round, with its evidence.
        var claim: String?
        /// The check under way: its subtask.
        var checkID: UUID?
        /// Bob checking it (9e, G): his one call, no subtask.
        var bobChecks = false

        var objective: String? {
            if case .goal(let objective) = mode { return objective }
            return nil
        }
    }

    enum AutorunEnd: Equatable {
        case finished
        case met(String)
        case unchecked
        case budget
        case rounds
        case stopped
        case interrupted(String)
    }

    /// Rounds begin at once; more than the cap runs the cap (the caller says so).
    func startAutorun(_ id: UUID, mode: Autorun.Mode, rounds: Int, members: [UUID]) {
        guard !isRunning(id), !members.isEmpty, conversations.conversation(id) != nil else { return }
        autoruns[id] = Autorun(mode: mode, rounds: min(max(rounds, 1), TeamLimits.rounds), members: members)
        nextRound(id)
    }

    /// Tokens used since the first round began.
    func autorunTokens(_ id: UUID) -> Int {
        guard let conversation = conversations.conversation(id), let start = autoruns[id]?.startID,
              let index = conversation.messages.firstIndex(where: { $0.id == start }) else { return 0 }
        return conversation.messages[index...].reduce(0) { total, message in
            total + (message.role == .agent || message.isUpkeep ? (message.usage?.input ?? 0) + (message.usage?.output ?? 0) : 0)
        }
    }

    /// goal_done (A3): the claim waits for the round's end, where another Agent checks it. The run ends with this turn.
    func claimGoal(_ call: ToolCall, conversationID id: UUID, state: inout RunState) -> ToolResult {
        guard autoruns[id]?.objective != nil else { return .failed("现在不是目标模式。") }
        let evidence = (ToolArguments.parse(call.arguments)?["evidence"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !evidence.isEmpty else { return .failed("evidence 要写：每一项交付物、依据和你怎么核对的。") }
        autoruns[id]?.claim = evidence
        state.goalClaimed = true
        return .done("已提交，另一个 Agent 会来复核。你这一轮到这里结束。")
    }

    /// A round's members are done (A2): a claim is checked, else the next round begins, or it ends.
    func roundEnded(_ id: UUID) {
        guard let autorun = autoruns[id] else { return }
        if let claim = autorun.claim, let objective = autorun.objective {
            autoruns[id]?.claim = nil
            return check(id, objective: objective, evidence: claim)
        }
        nextRound(id)
    }

    private func nextRound(_ id: UUID) {
        guard var autorun = autoruns[id] else { return }
        if autorun.objective != nil, autorunTokens(id) >= TeamLimits.goalTokens { return endAutorun(id, .budget) }
        if autorun.round >= autorun.rounds { return endAutorun(id, autorun.objective == nil ? .finished : .rounds) }
        autorun.round += 1
        let loopText: String? = if case .loop(let text) = autorun.mode { text } else { nil }
        let instruction = Autoruns.instruction(round: autorun.round, of: autorun.rounds, loopText: loopText, objective: autorun.objective)
        let title = autorun.objective == nil
            ? "自主运行 · 第 \(autorun.round)/\(autorun.rounds) 轮"
            : "目标 · 第 \(autorun.round) 轮（最多 \(autorun.rounds) 轮）"
        let detail = autorun.round == 1 ? (autorun.objective ?? loopText ?? "") : ""
        // Written into the thread (spec §9.8c): how many rounds ran is what an autorun should leave behind.
        let divider = Message(role: .user, text: instruction, event: ThreadEvent(kind: .round, title: title, detail: detail))
        if autorun.startID == nil { autorun.startID = divider.id }
        autoruns[id] = autorun
        conversations.append(divider, to: id)
        queues[id] = autorun.members
        advance(id)
    }

    /// G (9e): Bob checks when he has a model — against the objective, the evidence and what the rounds wrote, as it is
    /// now; met ends it, not met opens the next round with his reasons. No answer from him: another Agent checks (A3).
    private func check(_ id: UUID, objective: String, evidence: String) {
        guard conductorModel() != nil, let autorun = autoruns[id] else { return agentCheck(id, objective: objective, evidence: evidence) }
        let executor = autorun.members.compactMap { agents.agent($0)?.displayName }.joined(separator: "、")
        let request = Conductor.checkRequest(objective: objective, evidence: evidence, executor: executor, files: goalFiles(id))
        autoruns[id]?.bobChecks = true
        Task { [weak self] in
            guard let self else { return }
            let report = await self.askBob(Conductor.checkSystem, request, in: id)?.trimmingCharacters(in: .whitespacesAndNewlines)
            // Stopped meanwhile: nothing more to say.
            guard self.autoruns[id]?.bobChecks == true else { return }
            self.autoruns[id]?.bobChecks = false
            guard let report, !report.isEmpty else { return self.agentCheck(id, objective: objective, evidence: evidence) }
            let passed = Autoruns.verdict(report)
            let event = ThreadEvent(kind: .goalCheck, title: passed ? "复核通过 · Bob" : "复核未通过 · Bob", detail: passed ? "" : report, passed: passed)
            self.conversations.append(Message(role: .user, text: passed ? "" : "〔Bob 复核：未达成〕\n\(report)", event: event), to: id)
            if passed { self.endAutorun(id, .met("Bob")) } else { self.nextRound(id) }
        }
    }

    /// G: what the rounds wrote, as it is now — Bob reads it instead of opening the project himself: the last six files,
    /// 4,000 characters each.
    func goalFiles(_ id: UUID) -> [(path: String, text: String)] {
        guard let conversation = conversations.conversation(id), let root = projectRoot(conversation.projectID) else { return [] }
        let start = autoruns[id]?.startID.flatMap { start in conversation.messages.firstIndex { $0.id == start } } ?? 0
        var paths: [String] = []
        for call in conversation.messages[start...].flatMap(\.toolCalls) {
            if call.result?.status == .done, let path = call.result?.savedPath, !paths.contains(path) { paths.append(path) }
        }
        return paths.suffix(6).compactMap { path in
            guard let text = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) else { return nil }
            return (path, text.count > 4_000 ? String(text.prefix(4_000)) + "\n…（后面还有）" : text)
        }
    }

    /// A3: another Agent checks, read-only, in a subtask; met ends it, not met opens the next round with the reasons.
    /// Nobody else able to work: it ends saying the check wasn't done — never pretending it was.
    private func agentCheck(_ id: UUID, objective: String, evidence: String) {
        guard let conversation = conversations.conversation(id), let autorun = autoruns[id] else { return }
        let executor = autorun.members.compactMap { agents.agent($0)?.displayName }.joined(separator: "、")
        guard let reviewer = checker(for: conversation, excluding: autorun.members) else { return endAutorun(id, .unchecked) }
        let link = SubtaskLink(conversationID: id, messageID: conversation.messages.last?.id ?? UUID(), callID: "",
                               requesterID: autorun.members.first ?? reviewer.id, requesterName: executor, readOnly: true, isCheck: true)
        let child = conversations.openSubtask(projectID: conversation.projectID, agentID: reviewer.id, title: "复核目标", link: link)
        autoruns[id]?.checkID = child.id
        conversations.append(Message(role: .user, text: Autoruns.checkBrief(objective: objective, evidence: evidence, executor: executor)),
                             to: child.id)
        let reviewerID = reviewer.id
        Task { [weak self] in
            guard let self, let reviewer = self.agents.agent(reviewerID) else { return }
            let end = await self.work(child.id, helper: reviewer)
            // Stopped meanwhile: nothing more to say.
            guard self.autoruns[id]?.checkID == child.id else { return }
            self.autoruns[id]?.checkID = nil
            let report = self.conversations.conversation(child.id)?.messages
                .last { $0.role == .agent && !$0.isHidden && $0.failure == nil && !$0.text.isEmpty }?.text ?? ""
            let passed = end == .done && Autoruns.verdict(report)
            let reasons = report.isEmpty ? "复核没有给出结论（\(Self.endText(end))），按未达成算。" : report
            let event = ThreadEvent(kind: .goalCheck, title: (passed ? "复核通过 · " : "复核未通过 · ") + reviewer.displayName,
                                    detail: passed ? "" : reasons, agentID: reviewerID, passed: passed, subtaskID: child.id)
            self.conversations.append(Message(role: .user, text: passed ? "" : "〔\(reviewer.displayName) 复核：未达成〕\n\(reasons)", event: event),
                                      to: id)
            if passed { self.endAutorun(id, .met(reviewer.displayName)) } else { self.nextRound(id) }
        }
    }

    private static func endText(_ end: SubtaskEnd) -> String {
        switch end {
        case .done: "做完了"
        case .failed(let reason): "出错了：\(reason)"
        case .limit(let reason): "到了上限：\(reason)"
        case .stopped: "被停止了"
        }
    }

    /// Who checks a goal (A3): in a group a member not working on it, else another Agent of the project able to work;
    /// the idle one first.
    private func checker(for conversation: Conversation, excluding members: [UUID]) -> AgentRecord? {
        let inGroup = conversation.isGroup ? workers(in: conversation).filter { !members.contains($0.id) } : []
        if let pick = inGroup.first(where: { isIdle($0.id) }) ?? inGroup.first { return pick }
        let others = agents.agents.filter { !members.contains($0.id) && canWork($0, in: conversation.projectID) }
        return others.first { isIdle($0.id) } ?? others.first
    }

    /// The end, as a line in the thread (A4).
    func endAutorun(_ id: UUID, _ end: AutorunEnd) {
        guard let autorun = autoruns.removeValue(forKey: id) else { return }
        if let check = autorun.checkID, isRunning(check) { stop(check) }
        let ran = autorun.round
        let title = switch end {
        case .finished: "自主运行结束 · 做完 \(autorun.rounds) 轮"
        case .met(let reviewer): "目标达成 · \(reviewer) 复核通过 · 用了 \(ran) 轮"
        case .unchecked: "目标达成 · 这一轮没有做交叉复核，复核需要另一个 Agent · 用了 \(ran) 轮"
        case .budget: "目标没有达成 · 用满了约 \(ContextBudget.format(TeamLimits.goalTokens)) token · 跑了 \(ran) 轮"
        case .rounds: "目标没有达成 · 到了 \(autorun.rounds) 轮的上限"
        case .stopped: "自主运行已停止 · 跑了 \(ran) 轮"
        case .interrupted(let reason): "自主运行停在第 \(ran) 轮 · \(reason)"
        }
        let passed: Bool? = switch end {
        case .met, .unchecked: true
        case .budget, .rounds: false
        default: nil
        }
        conversations.append(Message(role: .user, text: "", event: ThreadEvent(kind: .autorunEnd, title: title, passed: passed)), to: id)
    }
}
