import Foundation

/// 10e: 修改 on a message the user sent — back to it, and it goes again, changed.
extension AppState {
    /// Offered on the user's own words in a conversation that isn't working — not a subtask's brief.
    func canEdit(_ message: Message, in conversation: Conversation) -> Bool {
        message.role == .user && !message.isHidden && message.event == nil && conversation.parent == nil
            && !chat.isRunning(conversation.id)
    }

    /// The thread goes back to before the message, then the new words go as the composer sends them — hooks, a group's
    /// `@`, the card it was on, its attachments. A hook that keeps them unsent puts the thread back (files already
    /// restored stay restored). Returns why it wasn't sent.
    func resend(_ id: UUID, message messageID: UUID, text raw: String, restoringFiles: Bool,
                projectRoot: URL?, projectName: String?) async -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let conversation = conversations.conversation(id),
              let original = conversation.messages.first(where: { $0.id == messageID }) else { return "找不到这条消息。" }
        guard !text.isEmpty || !original.attachments.isEmpty else { return ConversationProblem.emptyMessage.message }
        let busy = "它还在做事：等它做完，或者先停止。"
        guard !chat.isRunning(id) else { return busy }
        // `@` files as they are now (D3), read off the main actor.
        var mentions: [FileMention] = []
        if let projectRoot { mentions = await Task.detached { FileMentions.snapshot(text, root: projectRoot) }.value }
        guard let rewind = chat.rewind(id, from: messageID, restoringFiles: restoringFiles) else { return busy }
        let assignees = conversation.isGroup
            ? Mentions.assignees(in: text, members: ConversationReadiness.members(of: conversation, agents: agents)) : []
        let board = original.boardParent == nil && original.boardCard == nil ? nil
            : BoardDispatch.Plan(card: original.boardCard, parent: original.boardParent, assignees: assignees, joining: [], handover: nil)
        if let reason = await submit(id, text: text, attachments: original.attachments, assignees: assignees, mentions: mentions,
                                     projectRoot: projectRoot, projectName: projectName, board: board) {
            conversations.restore(rewind.version, in: id)
            return rewind.restoredFiles.isEmpty ? reason : reason + "（之后改过的文件已经恢复原样）"
        }
        return nil
    }
}
