import Foundation

/// 10i: 岔开问一句 (`/side`) — opened from a conversation, shown in its place, gone when the user goes back.
extension AppState {
    /// `/side [问题]`: the conversation's side one — an open one again, else a new one — with the question sent in it.
    func startSide(_ id: UUID, question: String, projectRoot: URL?, projectName: String?) -> String? {
        guard let conversation = conversations.conversation(id) else { return nil }
        guard !conversation.isSubtask else { return "这里已经是岔开的对话或子任务，不能再岔开" }
        guard conversation.messages.contains(where: { !$0.isHidden && $0.event == nil }) else { return "先聊几句，再岔开问别的" }
        guard let agent = commandAgent(conversation) else { return "这条对话里没有 Agent" }
        let side = conversations.subtasks(of: id).first(where: \.isSide)
            ?? conversations.openSide(from: conversation, agentID: agent.id, title: Side.title(question))
        selectedConversationID = side.id
        if !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sendFromCommand(question, to: side.id, projectRoot: projectRoot, projectName: projectName)
        }
        return nil
    }

    /// 回到主对话 — or the user went elsewhere (`returning: false`): the side conversation goes, its run with it.
    func closeSide(_ id: UUID, returning: Bool = true) {
        guard let side = conversations.conversation(id), side.isSide else { return }
        chat.discard(id)
        if returning { selectedConversationID = side.parent?.conversationID }
        conversations.removeSide(id)
    }
}
