import Foundation

/// 按 Tab 联想下一句 (user 2026-09-20). The composer, empty and with nothing running, asks the conversation's own
/// model what the user would say next; it arrives as grey text in the input, and Tab takes it.
///
/// Nothing is asked until the user presses Tab (user 2026-09-20: 「输入框空着时按 Tab 才去算」) — not once per reply, so a
/// conversation the user never asks costs nothing. What is asked is the conversation as it stands, with the primary
/// model, so the request's prefix is the run's own: the host's cache is hit rather than paid for again (the cache
/// test's rule, see `scripts/cache-check.py`). It is an upkeep call: it writes nothing into the thread.
extension ChatRunner {
    /// Whether the composer may ask at all: nothing running, and something to go on.
    func canSuggest(_ id: UUID) -> Bool {
        guard !isRunning(id), suggesting.contains(id) == false, let conversation = conversations.conversation(id) else { return false }
        return conversation.messages.contains { $0.role == .agent && !$0.isHidden }
    }

    /// Asks what the user would say next. The answer lands in `suggestions[id]`; a failure, an empty answer or a
    /// conversation that has moved on leaves nothing — the composer says so once and forgets it.
    func suggestNext(_ id: UUID) {
        guard canSuggest(id), let conversation = conversations.conversation(id),
              let reference = suggestModel(for: conversation) else { return }
        let mark = conversation.messages.last?.id
        suggesting.insert(id)
        Task { [weak self] in
            let line = await self?.askNext(conversation, reference: reference)
            guard let self else { return }
            suggesting.remove(id)
            // Typed into meanwhile, or the conversation moved on: what came back is no longer about what is on screen.
            guard conversations.conversation(id)?.messages.last?.id == mark, !isRunning(id) else { return }
            suggestions[id] = line
            if line == nil { suggestFailures.insert(id) }
        }
    }

    /// Drops what is showing — typed over, sent, or the conversation left.
    func clearSuggestion(_ id: UUID) {
        suggestions[id] = nil
        suggestFailures.remove(id)
    }

    /// Which model answers: the conversation's own Agent's primary, in a group whoever spoke last (user 2026-09-20 chose
    /// the primary model over the 省事模型 — the suggestion is only worth having when it can hold the conversation's
    /// detail), else Bob's.
    private func suggestModel(for conversation: Conversation) -> ModelReference? {
        suggestAgent(conversation)?.primaryModel ?? conductorModel()
    }

    private func askNext(_ conversation: Conversation, reference: ModelReference) async -> String? {
        guard let target = await suggestTarget(reference) else { return nil }
        let agentID = conversation.isGroup ? suggestAgent(conversation)?.id : nil
        var history = ChatText.history(conversation.messages, as: agentID,
                                       keepsEarlierThinking: ChatWire.keepsEarlierThinking(target))
        guard !history.isEmpty else { return nil }
        // The ask goes after the conversation, so everything before it is the run's own prefix, word for word.
        if history.last?.role == .user, history.last?.toolCalls.isEmpty == true {
            history[history.count - 1].text += "\n\n" + NextMessage.ask
        } else {
            history.append(ChatTurn(role: .user, text: NextMessage.ask))
        }
        // 不思考：联想一句话不值得一轮推理（起名同理，真实测试 2026-09-18）；服务商不认这个字段就不带它再问一次。
        for sendsReasoning in [false, true] {
            guard let request = ChatWire.request(target, system: NextMessage.system, history: history,
                                                 reasoning: .off, sendsReasoning: sendsReasoning) else { return nil }
            var text = ""
            do {
                for try await event in suggestClient.stream(request, apiProtocol: target.endpoint.apiProtocol) {
                    switch event {
                    case .text(let piece): text += piece
                    case .failed(let message): throw ChatFailure.provider(message)
                    default: break
                    }
                }
            } catch {
                if !sendsReasoning, ChatFailure.from(error).rejectsReasoning { continue }
                return nil
            }
            return NextMessage.parse(SecretShield.shared.restore(text))
        }
        return nil
    }
}
