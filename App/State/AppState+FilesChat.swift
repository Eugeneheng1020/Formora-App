import Foundation

/// 文件区的对话面板 (user 2026-09-22): its numbers, its keys, and the two pure rules the tests pin down.
enum FileChat {
    static let minWidth: CGFloat = 320
    static let maxWidth: CGFloat = 800
    static let defaultWidth: CGFloat = 420
    /// The preview keeps this much beside the panel.
    static let minPreview: CGFloat = 320

    static let openKey = "filesChat.open"
    static let widthKey = "filesChat.width"
    static let carriesKey = "filesChat.carries"
    static func agentKey(_ project: UUID) -> String { "filesChat.agent." + project.uuidString }
    static func pinKey(project: UUID, agent: UUID) -> String { "filesChat.pinned." + project.uuidString + "." + agent.uuidString }

    /// At most 800 and what the preview leaves; never under 320 — at the window's minimum both minimums fit exactly
    /// (84 + 300 + 320 + 320 = 1024).
    static func clampWidth(_ width: CGFloat, detailWidth: CGFloat) -> CGFloat {
        let cap = min(maxWidth, detailWidth - minPreview)
        return max(minWidth, min(width, cap))
    }

    /// The chosen file or folder goes on the end as an `@` token, exactly as typed by hand — unless the words already
    /// mention that path.
    static func outgoingText(_ text: String, carry path: String?) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let path, !path.isEmpty, !FileMentions.tokens(in: trimmed).contains(path) else { return trimmed }
        let token = FileMentions.token(for: path)
        return trimmed.isEmpty ? token : trimmed + " " + token
    }
}

extension AppState {
    var filesChatOpen: Bool {
        get { filesChatOpenStored }
        set {
            filesChatOpenStored = newValue
            defaults?.set(newValue, forKey: FileChat.openKey)
        }
    }

    var filesChatWidth: CGFloat {
        get { filesChatWidthStored }
        set {
            let clamped = min(max(newValue, FileChat.minWidth), FileChat.maxWidth)
            filesChatWidthStored = clamped
            defaults?.set(Double(clamped), forKey: FileChat.widthKey)
        }
    }

    var filesChatCarries: Bool {
        get { filesChatCarriesStored }
        set {
            filesChatCarriesStored = newValue
            defaults?.set(newValue, forKey: FileChat.carriesKey)
        }
    }

    func toggleFilesChat() { filesChatOpen.toggle() }

    /// The Agent the panel last had in this project; none until the user picks one (spec §0.3: never the first of a list).
    func filesChatAgentID(project: UUID) -> UUID? {
        if let id = filesChatAgents[project] { return id }
        return defaults?.string(forKey: FileChat.agentKey(project)).flatMap(UUID.init(uuidString:))
    }

    /// The conversation pinned for this Agent here (user 2026-09-23: 「每个 agent 都是固定一个消息，而不是最新的消息，不然上下文会
    /// 错乱」): `nil` = never pinned; a pinned one may since have been archived or deleted.
    private func filesChatPin(project: UUID, agent: UUID) -> UUID? {
        let key = FileChat.pinKey(project: project, agent: agent)
        if let id = filesChatPins[key] { return id }
        return defaults?.string(forKey: key).flatMap(UUID.init(uuidString:))
    }

    private func pinFilesChat(_ conversation: UUID, project: UUID, agent: UUID) {
        let key = FileChat.pinKey(project: project, agent: agent)
        filesChatPins[key] = conversation
        defaults?.set(conversation.uuidString, forKey: key)
    }

    /// The conversation the panel shows: the one pinned for that Agent here, while it lives — a chat started in 消息 later
    /// doesn't take its place. Hidden still counts; archived or deleted is gone, and a new one is started in its place. Never
    /// pinned (panels from 1.0.26): the latest normal direct chat, which `ensureFilesChatConversation` pins — the user
    /// 2026-09-23 chose keeping the one already shown.
    func filesChatConversation(project: UUID) -> Conversation? {
        guard let agentID = filesChatAgentID(project: project) else { return nil }
        guard let pinned = filesChatPin(project: project, agent: agentID) else {
            return conversations.latestDirect(agentID: agentID, project: project)
        }
        guard let conversation = conversations.conversation(pinned), conversation.parent == nil,
              conversation.visibility != .archived else { return nil }
        return conversation
    }

    func chooseFilesChatAgent(_ id: UUID, project: ProjectRecord) {
        filesChatAgents[project.id] = id
        defaults?.set(id.uuidString, forKey: FileChat.agentKey(project.id))
        ensureFilesChatConversation(project: project)
        if let shown = filesChatConversation(project: project.id) { selectedConversationID = shown.id }
    }

    /// The panel has an Agent: its pinned conversation stays; never pinned, the one shown is pinned; none (or the pinned one
    /// archived or deleted), a new one is started and pinned, as 「发起对话」 would — unless the Agent can't take work, and
    /// then the reason (the same judgement, spec §6.3) is for the panel to show. Returns why nothing was started.
    @discardableResult
    func ensureFilesChatConversation(project: ProjectRecord) -> String? {
        guard let agentID = filesChatAgentID(project: project.id) else { return nil }
        if let shown = filesChatConversation(project: project.id) {
            if filesChatPin(project: project.id, agent: agentID) != shown.id { pinFilesChat(shown.id, project: project.id, agent: agentID) }
            return nil
        }
        guard let agent = agents.agent(agentID) else { return "这个 Agent 已被删除" }
        if let reason = AgentReadiness.blockReason(of: agent, currentProject: project, providers: providers) { return reason }
        do {
            let started = try conversations.startDirect(agentID: agentID, projectID: project.id, blockReason: nil)
            pinFilesChat(started.id, project: project.id, agent: agentID)
            selectedConversationID = started.id
            return nil
        } catch {
            return (error as? ConversationProblem)?.message ?? error.localizedDescription
        }
    }
}
