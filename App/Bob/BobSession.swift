import Foundation
import Observation

/// Bob at work (7h): his conversation and its loop — the model answers, the tools it calls run, reading ones at once
/// and the rest after 允许 (B5), until he answers without a call. The conversation lives while the app runs (B7).
@MainActor
@Observable
final class BobSession {
    /// The project he looks at: the one open in the window.
    struct Project: Equatable {
        let id: UUID
        let name: String
        let root: URL?
    }

    /// One tool call in one of his turns, its result and its card.
    struct Step: Identifiable, Equatable {
        let call: ToolCall
        var result: ToolResult?
        var card: BobResult?

        var id: String { call.id }
    }

    struct Entry: Identifiable, Equatable {
        enum Role: Equatable {
            case user, bob
        }

        let id = UUID()
        let role: Role
        var text: String
        var steps: [Step] = []
        var failure: String?
        var note: String?
    }

    /// A step waiting for 允许 / 不用了 (B5).
    struct Confirmation: Equatable {
        let callID: String
        let summary: String
        let detail: String
    }

    private(set) var entries: [Entry] = []
    private(set) var isBusy = false
    /// His words as they stream in.
    private(set) var draft = ""
    private(set) var confirmation: Confirmation?
    /// The call running now.
    private(set) var running: String?
    var input = ""
    var project: Project?

    @ObservationIgnored private var history: [ChatTurn] = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var decision: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private let providers: ProviderStore
    @ObservationIgnored private let agents: AgentStore
    @ObservationIgnored private let conversations: ConversationStore
    @ObservationIgnored private let chat: ChatRunner
    @ObservationIgnored private let skills: SkillLibrary
    @ObservationIgnored private let mcp: MCPStore
    @ObservationIgnored private let notifications: NotificationSettings
    @ObservationIgnored let model: BobModel
    @ObservationIgnored private let client: ChatClient
    /// His own memory, the same in every project (D95).
    @ObservationIgnored let memory: MemoryStore
    @ObservationIgnored private let mcpClient: MCPClient
    @ObservationIgnored var userName: () -> String = { "" }
    /// The wait before retry `attempt` of a transient failure; tests make it instant.
    @ObservationIgnored var retryDelay: (Int) -> Duration = { .seconds($0) }

    static let callLimit = 20
    static let retryLimit = 3
    static let hint = "问我 Formora 怎么用、现在什么情况，或者直接让我去改设置。要改东西之前我都会先问你。"
    static let suggestions = ["Formora 都有哪些 Agent？", "/compact 是干什么用的？", "帮我建一个叫「验收标准检查」的 Skill"]
    /// What 设置 → Bob lists (B1): one group per kind of thing he does.
    struct ExampleGroup: Identifiable {
        let title: String
        let items: [String]

        var id: String { title }
    }

    static let examples = [
        ExampleGroup(title: "问 Formora 怎么用", items: ["/compact 是干什么用的？", "群聊里不 @ 人，消息会交给谁？"]),
        ExampleGroup(title: "查现在的情况", items: ["Formora 都有哪些 Agent？", "当前项目的任务都做到哪了？"]),
        ExampleGroup(title: "替你改设置", items: ["帮我建一个叫「验收标准检查」的 Skill", "接入 Notion", "关掉消息提示音"]),
    ]
    static let noModel = "Bob 还没有可用的模型：先去「模型」给一个服务商填上 API Key。"
    /// The project his memory is filed under: none in particular (D95).
    static let everywhere = UUID(uuidString: "B0B00000-0000-4000-8000-0000000000EE")!

    init(providers: ProviderStore, agents: AgentStore, conversations: ConversationStore, chat: ChatRunner, skills: SkillLibrary,
         mcp: MCPStore, notifications: NotificationSettings, model: BobModel, client: ChatClient = ChatClient(),
         memory: MemoryStore = MemoryStore(folder: nil), mcpClient: MCPClient = MCPClient()) {
        self.memory = memory
        self.mcpClient = mcpClient
        self.providers = providers
        self.agents = agents
        self.conversations = conversations
        self.chat = chat
        self.skills = skills
        self.mcp = mcp
        self.notifications = notifications
        self.model = model
        self.client = client
    }

    // MARK: From the page

    func send(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isBusy, !text.isEmpty else { return }
        entries.append(Entry(role: .user, text: text))
        history.append(ChatTurn(role: .user, text: text))
        input = ""
        isBusy = true
        task = Task { [weak self] in
            await self?.run()
            self?.end()
        }
    }

    /// 允许 / 不用了 on the card.
    func decide(_ allow: Bool) {
        guard confirmation != nil else { return }
        decision?.resume(returning: allow)
        decision = nil
    }

    /// 停止: what had arrived stays, marked as stopped; a waiting card is 不用了.
    func stop() {
        guard isBusy else { return }
        task?.cancel()
        decision?.resume(returning: false)
        decision = nil
        let arrived = ChatText.clean(draft)
        if !arrived.isEmpty { entries.append(Entry(role: .bob, text: arrived, note: "已停止")) }
        if let last = entries.indices.last, entries[last].role == .bob {
            for index in entries[last].steps.indices where entries[last].steps[index].result == nil {
                entries[last].steps[index].result = ToolResult(status: .stopped, output: "用户停止了，这一步没有执行。")
            }
        }
        // The history stays paired: every call gets a result.
        if let calls = history.last(where: { $0.role == .assistant })?.toolCalls {
            let answered = Set(history.compactMap(\.callID))
            for call in calls where !answered.contains(call.id) {
                history.append(ChatTurn(role: .tool, text: "用户停止了，这一步没有执行。", callID: call.id, toolName: call.name, isError: true))
            }
        }
        if !arrived.isEmpty { history.append(ChatTurn(role: .assistant, text: arrived)) }
        end()
    }

    func clear() {
        guard !isBusy else { return }
        entries = []
        history = []
    }

    /// 撤销 on a step that wrote a file (D95, 10d): the file back to before it, the step marked, and Bob told before his
    /// next answer. `nil`: done; otherwise why not.
    func undo(_ stepID: String) -> String? {
        guard !isBusy else { return "Bob 正在做事，等他停下来再撤销。" }
        for entry in entries.indices {
            guard let index = entries[entry].steps.firstIndex(where: { $0.id == stepID }) else { continue }
            guard let result = entries[entry].steps[index].result, let change = result.change, let path = result.savedPath else {
                return "这一步没有改文件。"
            }
            guard FileHistory.canUndo(change) else { return "这次修改撤不回去。" }
            guard let root = project?.root else { return "项目文件夹现在打不开。" }
            if let problem = FileHistory.undo(change, path: path, root: root, history: chat.fileHistoryFolder) { return problem }
            entries[entry].steps[index].result?.change?.undone = true
            history.append(ChatTurn(role: .user, text: "〔用户撤销了对 \(path) 的这次修改，文件回到了修改之前的样子〕"))
            return nil
        }
        return "找不到这次修改。"
    }

    private func end() {
        task = nil
        isBusy = false
        draft = ""
        running = nil
        confirmation = nil
    }

    // MARK: The loop

    private func run() async {
        guard let reference = model.current(providers), let target = await target(reference) else {
            entries.append(Entry(role: .bob, text: "", failure: Self.noModel))
            return
        }
        var sendsTools = true
        var note: String?
        var attempts = 0
        var calls = 0
        while calls < Self.callLimit {
            guard !Task.isCancelled else { return }
            let tools = sendsTools ? BobTools.all + MCPTools.allBindings(in: mcp).map(\.spec) : []
            guard let request = ChatWire.request(target, system: systemPrompt(), history: history, reasoning: .auto, sendsReasoning: false,
                                                 tools: tools) else {
                entries.append(Entry(role: .bob, text: "", failure: "「\(reference.providerID)」的 Base URL 无效"))
                return
            }
            var text = ""
            var thinking = ""
            var signature: String?
            var toolCalls: [ToolCall] = []
            do {
                for try await event in client.stream(request, apiProtocol: target.endpoint.apiProtocol) {
                    guard !Task.isCancelled else { return }
                    switch event {
                    case .text(let piece):
                        text += piece
                        draft = SecretShield.shared.restore(text)
                    case .thinking(let piece):
                        thinking += piece
                    case .thinkingSignature(let piece):
                        signature = (signature ?? "") + piece
                    case .toolCall(var call):
                        if call.id.isEmpty { call.id = "call_" + UUID().uuidString.prefix(8).lowercased() }
                        toolCalls.append(call)
                    case .failed(let message):
                        throw ChatFailure.provider(message)
                    default:
                        break
                    }
                }
            } catch {
                let failure = ChatFailure.from(error)
                guard !Task.isCancelled, failure != .cancelled else { return }
                if text.isEmpty, sendsTools, failure.rejectsTools {
                    sendsTools = false
                    note = "这个模型不支持工具调用，Bob 这次只能凭说明回答，查不了现状、改不了设置"
                    continue
                }
                if text.isEmpty, failure.isTransient, attempts < Self.retryLimit {
                    attempts += 1
                    try? await Task.sleep(for: retryDelay(attempts))
                    continue
                }
                draft = ""
                entries.append(Entry(role: .bob, text: ChatText.clean(text), failure: failure.message))
                return
            }
            calls += 1
            attempts = 0
            draft = ""
            // 10a: placeholders back to their values before anything is shown or run.
            toolCalls = SecretShield.shared.restore(toolCalls)
            let words = ChatText.clean(SecretShield.shared.restore(text))
            entries.append(Entry(role: .bob, text: words, steps: toolCalls.map { Step(call: $0) }, note: note))
            note = nil
            history.append(ChatTurn(role: .assistant, text: words, toolCalls: toolCalls,
                                    thinking: toolCalls.isEmpty || thinking.isEmpty ? nil : thinking, thinkingSignature: signature))
            guard !toolCalls.isEmpty else { return }
            let turn = entries.count - 1
            for (index, call) in toolCalls.enumerated() {
                guard !Task.isCancelled else { return }
                running = call.id
                let (result, card) = await perform(call, search: WebTools.nativeSearchTarget(target))
                running = nil
                guard !Task.isCancelled else { return }
                entries[turn].steps[index].result = result
                entries[turn].steps[index].card = card
                history.append(ChatTurn(role: .tool, text: result.output, callID: call.id, toolName: call.name, isError: result.status != .done))
            }
        }
        entries.append(Entry(role: .bob, text: "", note: "这次连续调用了 \(Self.callLimit) 次，先停在这里；要接着做就再说一句。"))
    }

    /// Reading runs; a change waits on its card (B5).
    private func perform(_ call: ToolCall, search: ChatTarget?) async -> (ToolResult, BobResult?) {
        let context = BobTools.Context(agents: agents, conversations: conversations, chat: chat, providers: providers, skills: skills,
                                       mcp: mcp, notifications: notifications, project: project, model: model.current(providers), search: search,
                                       memory: memory, history: chat.fileHistoryFolder, mcpClient: mcpClient)
        switch await BobTools.prepare(call, context: context) {
        case let .done(result, card):
            return (result, card)
        case let .ask(summary, detail, work):
            confirmation = Confirmation(callID: call.id, summary: summary, detail: detail)
            let allowed = await withCheckedContinuation { decision = $0 }
            confirmation = nil
            guard allowed, !Task.isCancelled else {
                return (ToolResult(status: .denied, output: "用户没有同意（\(summary)）。别换个工具再试同一件事；问用户想怎么做。"), nil)
            }
            return await work()
        }
    }

    private func target(_ reference: ModelReference) async -> ChatTarget? {
        guard !reference.modelID.isEmpty, let authorization = await providers.authorization(reference.providerID),
              let endpoint = providers.endpoints(for: reference.providerID).first else { return nil }
        return ChatTarget(providerID: reference.providerID, modelID: reference.modelID, endpoint: endpoint, key: authorization.key,
                          maxOutput: providers.modelInfo(reference.providerID, reference.modelID)?.maxOutput, headers: authorization.headers)
    }

    // MARK: His prompt (B8: the old app's 2026-09-09 text, with today's tools)

    func systemPrompt(date: Date = .now) -> String {
        var context: [String] = []
        if let project { context.append("当前项目：\(project.name)" + (project.root.map { "（\($0.path)）" } ?? "") + "。") }
        context.append("今天是 \(SystemPrompt.dateText(date))。")
        let name = userName().trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { context.append("称呼用户时用「\(name)」。") }
        // D95: his own memory, not the project's — the lines gone stale left out (10j).
        if let remembered = memory.promptText(agent: Conductor.bobID, project: Self.everywhere) {
            context.append("\n\n你的记忆（你自己记下的，不分项目；和现在的情况冲突时以现在为准）：\n" + remembered)
        }
        return """
        你叫 Bob，住在 Formora 里。你帮用户三件事：回答关于 Formora 的问题，替他改设置，以及直接动手做事——用 Skill、用已接入的 MCP 服务、在当前项目里读写文件和运行命令。

        回答问题时：
        - 先查再答。产品怎么用、某个功能是什么意思、指令干什么用——用 formora_help 读说明；现在有哪些 Agent、任务跑到哪、文件在哪个目录、配了哪些模型——用 formora_state 查真实状态。两个都查不到的，说不知道，不要编。
        - 问的是当前项目里的文件，用 read / glob / grep 去看真的文件，别猜。
        - 网上才有的答案用 web_search；给一个网址要正文用 fetch。
        - 答完就停。用户问「有哪些 Agent」就回答有哪些，不要顺手替他改什么。

        动手时：
        - 用户说要做什么，就用工具直接做，不要只回答怎么做：接入 MCP 服务（mcp_catalog 看目录、mcp_add 接入，接完会自动测试连接，要登录的会打开浏览器）、创建 Skill（skill_create，指令正文要写得像给同事的操作说明）、在当前项目建文件夹（folder_create）、改通知设置（notification_set）、在用户的浏览器里打开网址（open_url）。
        - 要做的事有对应的 Skill，先用 skill 读它的做法；所有已安装的 Skill 你都能用。
        - 已接入的 MCP 服务的工具你都能用（名字以 mcp__ 开头）：只读的直接用，会改东西的每一步会先问用户。
        - 在当前项目里写文件、改文件（write / edit）和运行命令（bash），和 Agent 一样只在项目文件夹里；没打开项目时告诉用户做不了。
        - 用户说以后都要怎样、或者定下了什么约定，用 remember 记下来，一句话一条；你的记忆不分项目，每次对话都带着。用户想看你记了什么，照下面「你的记忆」告诉他；让你全忘掉，用 memory_clear（会先问他）。
        - 看文件、搜索、读 Skill、记东西、只读的 MCP 工具之外的每一步——读网页、接入、新建、写文件、改文件、运行命令、会改东西的 MCP 工具、打开网址——都会先弹给用户确认，这是有意的。用户没同意就别换个工具再试一次。
        - 需要用户提供的东西（名字、地址）没有时，先问，别编。
        - 接入要选文件夹的服务（mcp_catalog 里写着「要选…（folder）」的，比如 Obsidian 的笔记库）：问用户那个文件夹的完整路径，填进 mcp_add 的 folder。要填好几项的（写着括号里名字的，比如飞书的 app_id 和 app_secret）：按括号里的名字放进 values。
        - 接入要令牌的服务（mcp_catalog 里写着「要填…」的）：用户还没给令牌，就照目录里的说明告诉他去哪儿生成、要勾哪些权限，请他直接贴在对话里。他贴的令牌你看到的是 $$SECRET_…$$ 占位符：原样填进 mcp_add 的 token，令牌会直接存进钥匙串；不要复述它，也不要让他自己去设置里填。

        说话时：
        - 做完用一两句话说结果，不重复工具已经报告的细节；工具说「已经存在 / 没有重复添加」就照实转述。
        - 听不懂要做什么时，说清你能做哪几类事并给一个具体例子，比如「接入 Notion」，不要瞎猜。
        - 接入 MCP 服务、新建 Skill 之后不要提议替 Agent 启用：那一步由用户在 Agent 的 MCP 或 Skills 标签里做，你告诉用户去那里就行。
        - 用中文，直接、简短；不输出 emoji 和图标符号。

        \(context.joined())
        """
    }
}
