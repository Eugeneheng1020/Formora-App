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

    /// The conversation the panel shows: that Agent's latest normal direct chat here (§4 of the design) — a hard rule,
    /// nothing remembered.
    func filesChatConversation(project: UUID) -> Conversation? {
        guard let agentID = filesChatAgentID(project: project) else { return nil }
        return conversations.latestDirect(agentID: agentID, project: project)
    }

    func chooseFilesChatAgent(_ id: UUID, project: ProjectRecord) {
        filesChatAgents[project.id] = id
        defaults?.set(id.uuidString, forKey: FileChat.agentKey(project.id))
        ensureFilesChatConversation(project: project)
    }

    /// The panel has an Agent but no conversation: start one, as 「发起对话」 would — unless it can't take work, and then
    /// the reason (the same judgement, spec §6.3) is for the panel to show. Returns why nothing was started.
    @discardableResult
    func ensureFilesChatConversation(project: ProjectRecord) -> String? {
        guard let agentID = filesChatAgentID(project: project.id) else { return nil }
        if let existing = conversations.latestDirect(agentID: agentID, project: project.id) {
            selectedConversationID = existing.id
            return nil
        }
        guard let agent = agents.agent(agentID) else { return "这个 Agent 已被删除" }
        if let reason = AgentReadiness.blockReason(of: agent, currentProject: project, providers: providers) { return reason }
        do {
            let started = try conversations.startDirect(agentID: agentID, projectID: project.id, blockReason: nil)
            selectedConversationID = started.id
            return nil
        } catch {
            return (error as? ConversationProblem)?.message ?? error.localizedDescription
        }
    }
}
