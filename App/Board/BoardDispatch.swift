import Foundation

/// Sending from the canvas (8d, K13): one rule, 「聚焦谁」×「@ 了谁」. Focus B, no `@` → added to B, its Agent answers;
/// `@` one → a child of B; `@` two → two children side by side — B's output handed on as background either way. The
/// `@`-ed who aren't in the conversation join it (K14).
enum BoardDispatch {
    struct Plan: Equatable, Sendable {
        /// Added to this card (no `@`).
        var card: String?
        /// Branched from this card (`@`).
        var parent: String?
        /// Who answers: in a group the card's Agent or the `@`-ed; a direct chat's Agent answers anyway.
        var assignees: [UUID]
        /// `@`-ed, not in the conversation yet: they join before it goes out.
        var joining: [UUID]
        /// The card's output for the children, sent hidden with the message.
        var handover: String?
    }

    enum Outcome: Equatable, Sendable {
        case send(Plan)
        case refused(String)
    }

    static let subtaskEnded = "委派和复核的子任务已经结束，不能再往里补充。要接着做，@ 一个角色从这张卡分出去"
    /// How much of the card's output travels with the children.
    static let handoverLimit = 4_000

    static func plan(_ conversation: Conversation, card: BoardCard, mentioned: [UUID]) -> Outcome {
        guard !mentioned.isEmpty else {
            // A helper's run lives in its subtask, which has ended: nothing to add to.
            guard card.kind == .assignment || card.kind == .round else { return .refused(subtaskEnded) }
            return .send(Plan(card: card.id, parent: nil, assignees: conversation.isGroup ? [card.agentID] : [], joining: [], handover: nil))
        }
        let present = conversation.isGroup ? conversation.members.map(\.agentID) : [conversation.agentID].compactMap { $0 }
        return .send(Plan(card: nil, parent: card.id, assignees: mentioned, joining: mentioned.filter { !present.contains($0) },
                          handover: handover(card)))
    }

    /// What the children get besides the user's words: the upstream task, its latest output, the files it wrote — what
    /// the line between the cards means.
    static func handover(_ card: BoardCard) -> String {
        let output = card.entries.reversed().lazy.compactMap { entry -> String? in
            if case let .said(speaker, text, isUser) = entry.kind, !isUser, speaker == card.agentName { return text }
            return nil
        }.first?.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts = ["以下是上游任务「\(card.title)」（\(card.agentName)）的产出，这条消息要你接着它往下做："]
        if let output {
            parts.append(output.count > handoverLimit ? String(output.prefix(handoverLimit)) + "…" : output)
        } else {
            parts.append("（它还没有产出）")
        }
        if !card.files.isEmpty { parts.append("它写过的文件：" + card.files.joined(separator: "、")) }
        return parts.joined(separator: "\n\n")
    }
}
