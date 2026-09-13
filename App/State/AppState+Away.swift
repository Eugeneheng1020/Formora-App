import Foundation

/// K (9e): away a while and back — one sentence on what happened in the project meanwhile, as a toast.
extension AppState {
    func wentAway(now: Date = .now) { awaySince = now }

    /// Back sooner than the threshold: nothing to say.
    func cameBack(project: UUID?, now: Date = .now) {
        guard let since = awaySince else { return }
        awaySince = nil
        guard now.timeIntervalSince(since) >= AwayDigest.threshold else { return }
        showAwayDigest(since: since, project: project)
    }

    /// The facts first — a step waiting for the user leads — then Bob's sentence from them, or the facts as one.
    func showAwayDigest(since: Date, project: UUID?) {
        let list = conversations.list(project: project, hiddenView: false)
        let headline = { (conversation: Conversation) in ConversationReadiness.headline(of: conversation, agents: self.agents) }
        var facts = AwayDigest.facts(list, since: since, name: headline)
        let waiting = list.filter { chat.approvals[$0.id] != nil || chat.subtaskWaiting($0.id) != nil }.map { "「\(headline($0))」" }
        if !waiting.isEmpty { facts.insert(waiting.joined(separator: "、") + " 有一步在等你确认", at: 0) }
        guard !facts.isEmpty else { return }
        let plain = AwayDigest.plain(facts)
        guard let model = chat.conductorModel() else { return toasts.show(AwayDigest.title, note: plain, seconds: 10) }
        Task { [weak self] in
            guard let self else { return }
            let reply = await self.chat.oneShot(system: AwayDigest.system, prompt: facts.joined(separator: "\n"), candidates: [model])
            let sentence = reply.map { AwayDigest.line($0.summary) } ?? ""
            self.toasts.show(AwayDigest.title, note: sentence.isEmpty ? plain : sentence, seconds: 10)
        }
    }
}
