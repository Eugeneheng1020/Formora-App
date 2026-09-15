import Foundation

/// 10h: 旁审 in the run (V1–V7).
extension ChatRunner {
    /// Bob's model (设置 → Bob); without one, the Agent's own — in a call of its own, with its own instructions.
    func advisorModel(for agent: AgentRecord) -> ModelReference? { conductorModel() ?? agent.primaryModel }

    /// The watcher reads what is new in `runID`: after a step that changed something, or its last answer (`final`).
    /// `/review` (`manual`) reads the whole run whatever the switch says. It runs beside the Agent, never holding it up.
    func advise(_ id: UUID, runID: UUID, agent: AgentRecord, final: Bool, focus: String? = nil, manual: Bool = false,
                steps given: [Message]? = nil) async {
        guard let conversation = conversations.conversation(id), let model = advisorModel(for: agent) else { return }
        if !manual {
            // Not plan mode (nothing changes), not a subtask (its requester checks it) — a lane is the member's own work.
            guard agent.reviewsOwnWork, !conversation.planMode, !conversation.isSubtask || conversation.isLane else { return }
            if !final, let quiet = advisorQuiet[id], quiet > 0 {
                advisorQuiet[id] = quiet - 1
                return
            }
        }
        let run = given ?? conversation.messages.filter { $0.runID == runID && !$0.isUpkeep }
        var fresh = run
        if !manual, let mark = advisorMarks[id], let index = run.firstIndex(where: { $0.id == mark }) { fresh = Array(run[(index + 1)...]) }
        guard let last = fresh.last else { return }
        advisorMarks[id] = last.id
        let ask = conversation.messages.last { $0.role == .user && !$0.isHidden && $0.event == nil }?.text ?? ""
        // A run that operated the computer (user 2026-09-15): its last screenshot goes with the final look.
        let screenshot = final ? Self.lastScreenshot(of: run) : nil
        let prompt = Advisor.request(ask: ask, agent: agent.displayName, role: agent.role.name, steps: fresh, final: final, focus: focus,
                                     screenshot: screenshot != nil)
        // `/review` asks for a full, graded review (10k); watching asks for one note at most.
        let system = manual ? Advisor.reviewSystem : Advisor.system
        let task = Task { [weak self] in
            guard let self, let reply = await self.oneShot(system: system, prompt: prompt, candidates: [model], images: screenshot.map { [$0] } ?? [])
            else { return }
            // Its call counts in /cost, like Bob's.
            self.conversations.append(Message(role: .user, text: "", model: reply.model, usage: reply.usage, isHidden: true, isUpkeep: true),
                                      to: id)
            guard !Task.isCancelled else { return }
            if manual, let review = Advisor.parseReview(reply.summary) {
                self.deliverReview(review, in: id, runID: runID, agent: agent)
            } else if let note = Advisor.parse(reply.summary) {
                self.deliver(note, in: id, runID: runID, agent: agent, manual: manual)
            } else if manual {
                self.announce(Advisor.clear(agentID: agent.id, runID: runID), in: id)
            }
        }
        advisorTasks[id] = Array(((advisorTasks[id] ?? []) + [task]).suffix(8))
        if advisesInline { await task.value }
    }

    /// While its run goes on, the Agent reads the note before its next step; after it, the note is a card — and a
    /// 必须停, or a 担心 the user asked for with `/review`, sends the Agent back to deal with it, once.
    private func deliver(_ note: Advisor.Note, in id: UUID, runID: UUID, agent: AgentRecord, manual: Bool) {
        guard let conversation = conversations.conversation(id),
              !conversation.messages.contains(where: { Advisor.isSame($0, note) }),
              !(steering[id] ?? []).contains(where: { Advisor.isSame($0, note) }) else { return }
        let message = Advisor.message(note, agentID: agent.id, runID: runID)
        if activeRuns[id]?.id == runID {
            steer(id, message)
            if note.severity != .nit { advisorQuiet[id] = Advisor.quietSteps }
            return
        }
        announce(message, in: id)
        let sendsBack = note.severity == .blocker || (manual && note.severity == .concern)
        guard sendsBack, manual || !advisorSentBack.contains(runID), !isRunning(id) else { return }
        let next = UUID()
        advisorSentBack.insert(next)
        start(id, agent: agent, runID: next)
    }

    /// `/review`'s answer (10k): the graded review as a card; with a P0 or P1 the Agent goes back to fix them.
    private func deliverReview(_ review: Advisor.Review, in id: UUID, runID: UUID, agent: AgentRecord) {
        announce(Advisor.message(review, agentID: agent.id, runID: runID), in: id)
        guard !review.passes, !isRunning(id) else { return }
        let next = UUID()
        advisorSentBack.insert(next)
        start(id, agent: agent, runID: next)
    }

    /// The last screenshot a `computer` call that acted brought back in the run — what the watcher checks the goal against.
    nonisolated static func lastScreenshot(of run: [Message]) -> String? {
        run.flatMap(\.toolCalls)
            .filter { $0.name == ComputerTool.name && ComputerTool.acts($0.arguments) }
            .compactMap { $0.result?.images?.last }
            .last
    }

    /// 停止, or the conversation going: a look in flight says nothing.
    func dropAdvice(_ id: UUID) {
        advisorTasks.removeValue(forKey: id)?.forEach { $0.cancel() }
        advisorQuiet[id] = nil
    }
}
