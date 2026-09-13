import AppKit
import Foundation
import Observation

enum AccountIdentity {
    /// The avatar letter: first grapheme of the trimmed name, uppercased. `nil` when there is no name.
    static func initial(of name: String) -> String? {
        name.trimmingCharacters(in: .whitespacesAndNewlines).first.map { String($0).uppercased() }
    }
}

/// UI state that is not project data: which section is showing, which overlay is open, toasts.
@MainActor
@Observable
final class AppState {
    enum ProjectMenu: Equatable {
        case list
        case newProject
    }

    /// Which provider the 模型 editor dialog is open for.
    enum ProviderEditorTarget: Equatable, Identifiable {
        case provider(String)
        case newCustom

        var id: String {
            switch self {
            case .provider(let id): id
            case .newCustom: "new"
            }
        }
    }

    enum AgentTab: String, CaseIterable, Identifiable {
        case overview, model, skills, mcp

        var id: String { rawValue }
        var title: String {
            switch self {
            case .overview: "概览"
            case .model: "模型与权限"
            case .skills: "Skills"
            case .mcp: "MCP"
            }
        }
    }

    /// The add / edit dialog of 设置 → MCP.
    enum MCPDialog: Equatable, Identifiable {
        case add(MCPAddMode)
        case edit(String)

        var id: String {
            switch self {
            case .add(let mode): "add-\(mode.rawValue)"
            case .edit(let id): "edit-\(id)"
            }
        }
    }

    /// Spec §8.4's three ways in.
    enum MCPAddMode: String, CaseIterable, Hashable {
        case catalog, paste, manual

        var title: String {
            switch self {
            case .catalog: "推荐"
            case .paste: "粘贴配置"
            case .manual: "手动填写"
            }
        }
    }

    /// An environment navigation waiting for 「继续编辑 / 放弃修改并离开」 (design spec §8.6).
    struct PendingNavigation: Identifiable {
        let id = UUID()
        let consequence: String
        let proceed: @MainActor () -> Void
    }

    /// A group chat dialog: ⊕ creates one, 群设置 edits one (C6, C8).
    enum GroupDialog: Equatable, Identifiable {
        case create
        case settings(UUID)

        var id: String {
            switch self {
            case .create: "create"
            case .settings(let id): "settings-\(id.uuidString)"
            }
        }
    }

    /// What the composer holds for one conversation until it is sent.
    struct ComposerDraft: Equatable {
        var text = ""
        var attachments: [Attachment] = []
    }

    /// A search hit to scroll to and flash (C15).
    struct MessageJump: Equatable {
        let conversationID: UUID
        let messageID: UUID
    }

    var selectedSection: AppSection = .messages
    let conversations: ConversationStore
    /// Replies in flight (6b).
    let chat: ChatRunner
    let notifications: NotificationSettings
    /// 设置 → 电脑操作's three permissions (7j, B2).
    let computer = ComputerAccess()
    /// Sound and banner for a reply the user didn't see; set by the app (tests stay silent).
    var replyAlert: (Conversation, Message) -> Void = { _, _ in }
    /// Re-reads (`false`) or asks for (`true`) macOS's notification permission; set by the app.
    var checkNotificationPermission: (Bool) -> Void = { _ in }
    /// The conversation on screen in 消息, so a reply landing there isn't unread.
    var displayedConversationID: UUID?
    var selectedConversationID: UUID?
    /// `nil` = 全部.
    var messageFilter: ConversationStatus?
    /// Inside 「已隐藏的会话」 (spec §9.1b: a level deeper, not a fourth filter).
    var showsHiddenConversations = false
    var messageSearch = ""
    var groupDialog: GroupDialog?
    /// The archived conversation the delete confirmation is open for.
    var conversationToDelete: UUID?
    var composerDrafts: [UUID: ComposerDraft] = [:]
    var messageJump: MessageJump?
    /// 10e: the user's message open in 修改 — one at a time.
    var editingMessage: UUID?
    /// The conversation whose reasoning menu is open; the menu is drawn above everything, at the pill.
    var reasoningMenuFor: UUID?
    /// The reasoning pill's frame in window coordinates, so the menu can open right above it.
    var reasoningButtonFrame: CGRect = .zero
    let account: AccountStore
    let providers: ProviderStore
    let agents: AgentStore
    let skills: SkillLibrary
    let mcp: MCPStore
    /// Unsaved MCP tab edits, per Agent (explicit save, spec §8.6).
    var mcpDrafts: [UUID: [MCPAccess]] = [:]
    /// `nil` = the MCP dialog is closed.
    var mcpDialog: MCPDialog?
    /// The Skill the uninstall confirmation is open for.
    var skillToUninstall: String?
    /// The hooks (7b′).
    let hooks: HookStore
    /// Bob, in 设置 (7h).
    let bob: BobSession
    let bobModel: BobModel
    /// 10b: the steps each project no longer asks about.
    let approvalRules: ApprovalRuleStore
    /// When the window went to the background (9e, K): back after a while, a sentence on what happened.
    @ObservationIgnored var awaySince: Date?
    /// `nil` = the hook editor is closed.
    var hookEditor: HookEditorTarget?
    /// The hook the delete confirmation is open for.
    var hookToDelete: HookTarget?
    var selectedAgentID: UUID?
    var agentTab: AgentTab = .overview
    /// 看板 (8b): the conversation on the canvas, the focused card (K11: focus = selection), the list's search.
    var boardConversationID: UUID?
    var boardFocus: String?
    var boardSearch = ""
    /// The board's cards per conversation, kept while nothing they come from changed (9a): the list and the canvas
    /// derive them on every redraw otherwise.
    @ObservationIgnored var boardCardCache: [UUID: (key: BoardCardsKey, cards: [BoardCard])] = [:]
    var isCreatingAgent = false
    /// Verification hook only (`-FormoraCreateAgentStep`): the creation dialog opens prefilled on a step.
    var createAgentPreset: CreateAgentFlow?
    /// Unsaved 模型与权限 edits, per Agent; kept when leaving so coming back finds them (spec §8.6).
    var modelDrafts: [UUID: AgentModelDraft] = [:]
    var pendingNavigation: PendingNavigation?
    /// The Agent the delete confirmation is open for.
    var agentToDelete: UUID?
    var settingsCategory: SettingsCategory = .account
    /// Bob's floating panel over 设置 (7h, B1); leaving 设置 closes it.
    var bobPanelOpen = false
    /// A command's one-off output under the thread, per conversation (7d, D2).
    var commandCards: [UUID: CommandCard] = [:]
    /// `/clear` waits for its confirmation (R1).
    var conversationToClear: UUID?
    /// A question's answers so far, one per question, while the rest are still open (7d, D6).
    var askAnswers: [UUID: [AskTool.Answer]] = [:]
    /// QA only (`-FormoraRevealCompaction`): a new compaction's divider scrolls into view with its summary open.
    var revealsCompaction = false
    /// `nil` = the provider editor is closed.
    var providerEditor: ProviderEditorTarget?
    /// Providers whose model list is expanded in 设置 → 模型.
    var openModelLists: Set<String> = []
    /// `nil` = the footer switcher's panel is closed.
    var projectMenu: ProjectMenu?
    var isManagingProjects = false
    /// Verification hook only (`-FormoraOverlay launchNewProject`): the launch flow opens on the form.
    var launchStartsOnNewProject = false
    /// Verification hook only (`-FormoraOverlay launchModel` / `launchAgent` / `launchReady`, 9f): the launch flow
    /// opens on that step of the cold start.
    var launchStartsOnStep: LaunchSetup.Step?
    let toasts = ToastCenter()
    /// The open project's folder tree; `nil` while no reachable folder is open.
    var files: FileBrowser?

    init(account: AccountStore, providers: ProviderStore, agents: AgentStore, skills: SkillLibrary, mcp: MCPStore,
         conversations: ConversationStore, notifications: NotificationSettings, hooks: HookStore = HookStore(folder: nil),
         chatClient: ChatClient = ChatClient(), memory: MemoryStore = MemoryStore(folder: nil),
         bobModel: BobModel = BobModel(defaults: nil), approvalRules: ApprovalRuleStore = ApprovalRuleStore(fileURL: nil)) {
        self.account = account
        self.approvalRules = approvalRules
        self.hooks = hooks
        self.providers = providers
        self.agents = agents
        self.skills = skills
        self.mcp = mcp
        self.conversations = conversations
        self.notifications = notifications
        chat = ChatRunner(conversations: conversations, agents: agents, providers: providers, client: chatClient)
        self.bobModel = bobModel
        bob = BobSession(providers: providers, agents: agents, conversations: conversations, chat: chat, skills: skills, mcp: mcp,
                         notifications: notifications, model: bobModel, client: chatClient)
        // 9e: Bob arranges group work with the model chosen on his page.
        chat.conductorModel = { [weak bobModel, weak providers] in
            guard let bobModel, let providers else { return nil }
            return bobModel.current(providers)
        }
        // 10b: what each project no longer asks about.
        chat.approvalRules = approvalRules
        // 7f: the Agents' Skills, MCP tools and memory.
        chat.skillLibrary = skills
        chat.mcp = mcp
        chat.memory = memory
        providers.usage = { [weak agents] id in agents?.usage(ofProvider: id) ?? 0 }
        skills.usage = { [weak agents] id in agents?.usage(ofSkill: id) ?? 0 }
        mcp.usage = { [weak agents] id in agents?.usage(ofMCP: id) ?? 0 }
        chat.isVisible = { [weak self] id in
            guard let self else { return false }
            return selectedSection == .messages && displayedConversationID == id && NSApplication.shared.isActive
        }
        chat.onUnseenReply = { [weak self] conversation, message in self?.replyAlert(conversation, message) }
        chat.userName = { [weak account] in account?.displayName ?? "" }
        bob.userName = { [weak account] in account?.displayName ?? "" }
        chat.hooks = { [weak hooks] event, input, root in await hooks?.run(event, input, projectRoot: root) ?? HookOutcome() }
        selectedAgentID = agents.agents.first?.id
    }

    /// Sending (7b′, H6): UserPromptSubmit hooks see the message first — they can keep it unsent, or hand the Agent
    /// some background with it; then it goes out, or, while the Agent works, waits as steering (L4). Returns why it
    /// wasn't sent.
    func submit(_ id: UUID, text: String, attachments: [Attachment], assignees: [UUID], mentions: [FileMention] = [],
                projectRoot: URL?, projectName: String?, board: BoardDispatch.Plan? = nil, currentProject: ProjectRecord? = nil) async -> String? {
        guard let conversation = conversations.conversation(id) else { return nil }
        commandCards[id] = nil
        let agent = conversation.isGroup ? nil : agents.agent(conversation.agentID)
        var input = HookInput(event: .userPromptSubmit, conversationID: id, title: conversation.title, projectPath: projectRoot?.path,
                              projectName: projectName, agentID: agent?.id, agentName: agent?.displayName, agentRole: agent?.roleID,
                              permissionMode: agent?.approvalMode.rawValue,
                              message: "你在「\(projectName ?? "项目")」发了一条消息：\(text.prefix(200))")
        input.prompt = text
        let outcome = await hooks.run(.userPromptSubmit, input, projectRoot: projectRoot)
        for note in outcome.notes { toasts.show("Hook", note: note, seconds: 4) }
        if let reason = outcome.blocked { return reason }
        // From the canvas (8d, K14): who was `@`-ed but isn't in the conversation joins it first — in place.
        if let board, !board.joining.isEmpty, let reason = joinFromBoard(id, board.joining, currentProject: currentProject) { return reason }
        let isGroup = conversations.conversation(id)?.isGroup ?? conversation.isGroup
        let handover = board?.handover.map { Message(role: .user, text: $0, isHidden: true) }
        let background = outcome.context.isEmpty ? nil
            : Message(role: .user, text: "以下是 Hook 为这条消息补充的背景：\n" + outcome.context.joined(separator: "\n\n"), isHidden: true)
        // A question waits (spec §9.8b): what the user writes answers it, and clears it.
        if !chat.isRunning(id), attachments.isEmpty, chat.pendingQuestion(id) != nil {
            let typed = mentions.isEmpty ? text : text + "\n\n" + FileMentions.context(mentions)
            let answers = (askAnswers[id] ?? []) + [AskTool.Answer(typed: typed)]
            askAnswers[id] = nil
            if let background { conversations.append(background, to: id) }
            chat.answer(id, answers)
            return nil
        }
        if chat.isRunning(id) {
            var steering = Message(role: .user, text: text, attachments: attachments, assignees: assignees, mentions: mentions)
            steering.boardParent = board?.parent
            steering.boardCard = board?.card
            chat.steer(id, steering)
            if let handover { chat.steer(id, handover) }
            if let background { chat.steer(id, background) }
            return nil
        }
        let sent: Message
        do {
            sent = try conversations.send(id, text: text, attachments: attachments, assignees: assignees, mentions: mentions,
                                          boardParent: board?.parent, boardCard: board?.card)
        } catch {
            return (error as? ConversationProblem)?.message ?? error.localizedDescription
        }
        if let handover { conversations.append(handover, to: id) }
        if let background { conversations.append(background, to: id) }
        if !isGroup {
            chat.reply(to: id)
        } else {
            // Bob arranges it (9e); without his model, 7g's dispatcher or queue.
            chat.route(id, message: sent.id)
        }
        return nil
    }

    /// In-memory account, providers, Agents, Skills and MCP (tests, previews): nothing touches disk or the Keychain.
    convenience init(accountName: String) {
        // An in-memory store cannot fail to open.
        let container = try! ProjectStore.makeContainer(storeURL: nil)
        self.init(account: AccountStore(defaults: nil, folder: nil, systemName: accountName),
                  providers: ProviderStore(secrets: InMemorySecretStore(), fileURL: nil),
                  agents: AgentStore(container: container, avatarFolder: nil),
                  skills: SkillLibrary(folder: nil, builtInFolder: nil, defaults: nil),
                  mcp: MCPStore(secrets: InMemorySecretStore(), fileURL: nil, openURL: { _ in }),
                  conversations: ConversationStore(folder: nil), notifications: NotificationSettings(defaults: nil))
    }

    /// 「发起对话」 (C6): a new direct chat, opened in 消息. Not guarded — the button says where it goes (§8.6).
    func startConversation(with agent: AgentRecord, project: ProjectRecord?) {
        guard let project else { return }
        do {
            let reason = AgentReadiness.blockReason(of: agent, currentProject: project, providers: providers)
            let conversation = try conversations.startDirect(agentID: agent.id, projectID: project.id, blockReason: reason)
            openConversation(conversation.id)
        } catch {
            toasts.show("无法发起对话", note: (error as? ConversationProblem)?.message ?? error.localizedDescription, isError: true)
        }
    }

    /// Shows a conversation in 消息 — inside 已隐藏 when it is hidden — optionally scrolled to one message.
    func openConversation(_ id: UUID, jumpTo messageID: UUID? = nil) {
        guard let conversation = conversations.conversation(id) else { return }
        showsHiddenConversations = conversation.visibility == .hidden
        selectedConversationID = id
        conversations.markRead(id)
        messageJump = messageID.map { MessageJump(conversationID: id, messageID: $0) }
        select(.messages)
    }

    var selectedAgent: AgentRecord? { agents.agent(selectedAgentID) ?? agents.agents.first }

    /// A model or MCP draft that differs from what's saved (spec §8.6: both are explicit-save).
    func hasUnsavedDraft(_ id: UUID?) -> Bool {
        guard let id, let agent = agents.agent(id) else { return false }
        if let draft = modelDrafts[id], !draft.matches(agent) { return true }
        if let access = mcpDrafts[id], access != agent.mcpAccess { return true }
        return false
    }

    /// Switching Agent, rail section or project asks once while the open Agent has an unsaved model draft.
    /// Buttons that say where they go (前往模型设置, 发起对话) don't go through here (spec §8.6).
    func guardNavigation(_ consequence: String, _ proceed: @escaping @MainActor () -> Void) {
        if selectedSection == .agents, hasUnsavedDraft(selectedAgent?.id) {
            pendingNavigation = PendingNavigation(consequence: consequence, proceed: proceed)
        } else {
            proceed()
        }
    }

    /// 「放弃修改并离开」.
    func discardDraftAndProceed() {
        guard let pending = pendingNavigation else { return }
        if let id = selectedAgent?.id {
            modelDrafts[id] = nil
            mcpDrafts[id] = nil
        }
        pendingNavigation = nil
        pending.proceed()
    }

    func requestSection(_ section: AppSection) {
        guard section != selectedSection else { return }
        guardNavigation("离开 Agent 配置") { self.select(section) }
    }

    func requestAgent(_ id: UUID) {
        guard id != selectedAgent?.id, let target = agents.agent(id) else { return }
        guardNavigation("切换到 \(target.displayName)") {
            self.selectedAgentID = id
            self.agentTab = .overview
        }
    }

    var accountName: String { account.displayName }
    var accountInitial: String? { account.initial }

    func select(_ section: AppSection) {
        selectedSection = section
    }

    /// The rail avatar's action (design spec §5).
    func openAccountSettings() {
        selectedSection = .settings
        settingsCategory = .account
    }

    func openManageProjects() {
        projectMenu = nil
        isManagingProjects = true
    }
}
