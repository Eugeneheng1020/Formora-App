import Foundation

/// 看板 (8b): the cards of a conversation as the canvas shows them, and the moves the board makes.
extension AppState {
    /// The project's conversations the board frames as chains: the ones 消息 lists, subtasks left out (they are cards).
    func boardConversations(project: UUID?) -> [Conversation] {
        conversations.list(project: project, hiddenView: false)
    }

    /// The conversation's cards (8a), with the runner's word on who is working and who waits.
    func boardCards(_ conversation: Conversation) -> [BoardCard] {
        let names = Dictionary(agents.agents.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
        let children = Dictionary(conversations.subtasks(of: conversation.id).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var activity: [UUID: BoardCards.Activity] = [:]
        for id in [conversation.id] + Array(children.keys) {
            activity[id] = BoardCards.Activity(runningAgent: chat.activeRuns[id]?.agentID, waiting: chat.waiting[id])
        }
        // Unchanged conversations compare in no time: their message arrays still share one buffer.
        let key = BoardCardsKey(conversation: conversation, subtasks: children, activity: activity, names: names)
        if let kept = boardCardCache[conversation.id], kept.key == key { return kept.cards }
        let cards = BoardCards.derive(conversation, name: { names[$0] }, subtask: { children[$0] },
                                      activity: { activity[$0] ?? BoardCards.Activity() })
        boardCardCache[conversation.id] = (key, cards)
        return cards
    }

    /// Another conversation on the canvas: nothing stays focused.
    func selectBoardConversation(_ id: UUID?) {
        guard boardConversationID != id else { return }
        boardConversationID = id
        boardFocus = nil
    }

    /// The canvas composer's send (8d, K13): the plan decides where it goes, then it goes out as 消息 sends it —
    /// hooks, steering, dispatch. Returns why it wasn't sent.
    func boardSend(_ id: UUID, card: BoardCard, text: String, attachments: [Attachment], mentioned: [UUID], mentions: [FileMention],
                   projectRoot: URL?, projectName: String?, currentProject: ProjectRecord?) async -> String? {
        guard let conversation = conversations.conversation(id) else { return nil }
        switch BoardDispatch.plan(conversation, card: card, mentioned: mentioned) {
        case .refused(let reason):
            return reason
        case .send(let plan):
            let reason = await submit(id, text: text, attachments: attachments, assignees: plan.assignees, mentions: mentions,
                                      projectRoot: projectRoot, projectName: projectName, board: plan, currentProject: currentProject)
            // The mockup's word that it went where it was meant to.
            if reason == nil {
                if plan.card != nil {
                    toasts.show("已补充", note: "内容已并入「\(card.title)」", seconds: 2)
                } else {
                    let names = plan.assignees.compactMap { agents.agent($0)?.displayName }.joined(separator: "、")
                    toasts.show("已派活", note: "\(names) 接手了「\(card.title)」", seconds: 2)
                }
            }
            return reason
        }
    }

    /// The `@`-ed join the conversation (K14), each able to work in the project. Returns why they couldn't.
    func joinFromBoard(_ id: UUID, _ joining: [UUID], currentProject: ProjectRecord?) -> String? {
        do {
            try conversations.join(id, agents: joining, names: { agents.agent($0)?.displayName ?? ConversationReadiness.deletedAgentName },
                                   reasonFor: { agentID in
                                       guard let agent = agents.agent(agentID) else { return "这个 Agent 已被删除" }
                                       return AgentReadiness.blockReason(of: agent, currentProject: currentProject, providers: providers)
                                   })
            return nil
        } catch {
            return (error as? ConversationProblem)?.message ?? error.localizedDescription
        }
    }

    /// A card's file row (K12): 文件, with the file selected.
    func openBoardFile(_ path: String) {
        select(.files)
        Task { await files?.reveal(relativePath: path) }
    }
}

/// Everything a conversation's cards come from (9a): the same inputs, the same cards.
struct BoardCardsKey: Equatable {
    let conversation: Conversation
    let subtasks: [UUID: Conversation]
    let activity: [UUID: BoardCards.Activity]
    let names: [UUID: String]
}
