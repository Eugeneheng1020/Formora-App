import Foundation
import Observation

/// Agents at work, one run per conversation (7b). omp's loop: the model answers, the tools it calls run — asking
/// first when the Agent's 权限模式 says so — their results go back, until it answers without calling one (L1).
/// Primary model, then the fallbacks; transient failures are retried; stopping keeps what arrived; nothing is lost
/// on quit. In a group the `@`-ed members work one after another (spec §9.10). Main actor only — the network and
/// the file system are read off it.
@MainActor
@Observable
final class ChatRunner {
    /// The model's turn being written, shown as it grows. A class observed on its own (9a, P2): a token changes this
    /// draft, not the dictionary of drafts, so only the view drawing it redraws — never the whole thread.
    @Observable
    final class Draft: Equatable {
        var text = ""
        var thinking = ""
        let startedAt: Date
        var thinkingStartedAt: Date?
        var thinkingEndedAt: Date?
        var model: ModelReference
        /// Who is answering (a group has several).
        let agentID: UUID
        /// The run it belongs to: the thread shows a run as one frame (L8).
        let runID: UUID
        var usage: TokenUsage?
        var note: String?

        init(startedAt: Date, model: ModelReference, agentID: UUID, runID: UUID, note: String? = nil) {
            self.startedAt = startedAt
            self.model = model
            self.agentID = agentID
            self.runID = runID
            self.note = note
        }

        nonisolated static func == (lhs: Draft, rhs: Draft) -> Bool { lhs === rhs }

        var thinkingSeconds: Double? {
            guard let start = thinkingStartedAt else { return nil }
            return max(0, (thinkingEndedAt ?? .now).timeIntervalSince(start))
        }
    }

    struct Run: Equatable {
        let id: UUID
        let agentID: UUID
    }

    /// A tool call waiting for 允许 / 拒绝 (L5).
    struct Approval: Equatable {
        let messageID: UUID
        let callID: String
        /// Why it asks whatever the 权限模式: a dangerous command (7c, C3).
        var reason: String?
        /// Bob's one plain sentence on what the step risks (9e, J) — never a decision.
        var risk: String?
        /// What 这个对话里都允许 / 以后都不再问 would remember (10b); `nil` when nothing can be.
        var grant: ApprovalGrant?
        /// 10d: a write or an edit's change, worked out before it is allowed.
        var preview: String?
    }

    // The loop's limits (L2, L3). The per-run turn cap was removed (user 2026-09-16); the deadline is the safety net.
    nonisolated static let deadline: TimeInterval = 60 * 60
    nonisolated static let retryLimit = 10
    nonisolated static let repeatLimit = 5
    nonisolated static let emptyLimit = 3
    /// How often a run is sent back to its plan's open steps (omp's todo reminder: three attempts).
    nonisolated static let planContinueLimit = 3
    nonisolated static let lengthLimit = 3
    /// How often a Stop hook may send the Agent back to work in one run (7b′, H6).
    nonisolated static let stopLimit = 3

    private(set) var drafts: [UUID: Draft] = [:]
    /// Group chats: who is still to answer after the current one.
    var queues: [UUID: [UUID]] = [:]
    /// Conversations with a run under way.
    private(set) var activeRuns: [UUID: Run] = [:]
    private(set) var approvals: [UUID: Approval] = [:]
    /// The call running right now.
    private(set) var executing: [UUID: String] = [:]
    /// A run waiting out a transient failure before its retry (L3): 「等待限流」 on a rate limit, else 「等待重试」 — the
    /// board's cards say so (8a, K5).
    private(set) var waiting: [UUID: String] = [:]
    /// What the user sent while the Agent worked, delivered after the current step (L4).
    private(set) var steering: [UUID: [Message]] = [:]
    /// Unseen, ahead of the user's own words when they arrive mid-run (user 2026-09-17): the message comes first.
    nonisolated static let steeringNote = "〔用户在你工作时发来了下面这条新消息。先处理它：该回答就回答，该照办就照办；再判断原来的事还要不要接着做、要不要调整。〕"
    /// What a run remembered, waiting for the thread's line.
    @ObservationIgnored private var memoryNotes: [UUID: [MemoryChange]] = [:]
    /// 旁审's 提醒 while the run goes on (user 2026-09-17): cards once it rests — no step is spent answering them.
    @ObservationIgnored var heldAdvice: [UUID: [Message]] = [:]
    /// Looks still out, by conversation: a step finished meanwhile waits for the next look (`advise`).
    @ObservationIgnored var advisorLooksOut: [UUID: Int] = [:]
    /// A held note → the last message its look had read (`Advisor.isStale`).
    @ObservationIgnored var heldAdviceMarks: [UUID: UUID] = [:]
    /// The foreground command each conversation is running: a message sent meanwhile asks it to step aside.
    @ObservationIgnored private var asides: [UUID: Shell.Aside] = [:]
    /// Seconds a command gets before a message puts it aside (tests: 0).
    @ObservationIgnored var asideGrace: TimeInterval = 3

    // 7g: Agents working together — the dispatcher, relay, subtasks, autorun.
    /// A dispatcher choosing who takes a group message (M1): the conversation counts as busy meanwhile.
    var dispatching: Set<UUID> = []
    @ObservationIgnored var dispatchTasks: [UUID: Task<Void, Never>] = [:]
    /// Chains of hand-offs under way (M3–M4).
    var relays: [UUID: Relay] = [:]
    /// `/loop` and `/goal` under way (A1).
    var autoruns: [UUID: Autorun] = [:]
    /// Bob's arrangements under way (9e): the stages of one message, and the lanes working in the background.
    var conducts: [UUID: Conduct] = [:]
    @ObservationIgnored var conductTasks: [UUID: Task<Void, Never>] = [:]
    /// The model Bob arranges with — 设置 → Bob (9e); `nil` keeps 7g's rules.
    @ObservationIgnored var conductorModel: () -> ModelReference? = { nil }
    /// Failed work taken over since the user's last message (9e, E).
    @ObservationIgnored var takeovers: [UUID: Int] = [:]
    /// Bob looking whether a turn finished the work (9e, C): the banner says the next step is being arranged.
    var reviewing: Set<UUID> = []
    /// 10h, 旁审: the last message the watcher read, by conversation; the steps it leaves alone after a note; its
    /// looks in flight; the runs a 必须停 started, which aren't sent back again.
    @ObservationIgnored var advisorMarks: [UUID: UUID] = [:]
    @ObservationIgnored var advisorQuiet: [UUID: Int] = [:]
    @ObservationIgnored var advisorTasks: [UUID: [Task<Void, Never>]] = [:]
    @ObservationIgnored var advisorSentBack: Set<UUID> = []
    /// Tests: the watcher answers before the run goes on.
    @ObservationIgnored var advisesInline = false
    /// 10b: 这个对话里都允许, by conversation — gone when the app quits (Codex's session cache).
    @ObservationIgnored var sessionGrants: [UUID: [ApprovalGrant]] = [:]
    /// 10b: what each project no longer asks about; the app hands it in.
    @ObservationIgnored var approvalRules: ApprovalRuleStore?
    /// 10d: where a file is kept as it was before a write or an edit, for 撤销; the app hands it in.
    @ObservationIgnored var fileHistoryFolder: URL?
    /// 10l: where the members Bob starts side by side get their copies of the project — outside every project.
    @ObservationIgnored var laneCopiesFolder: URL?
    /// 10l: the copies being worked in, by lane.
    @ObservationIgnored var laneCopies: [UUID: LaneCopies.Copy] = [:]
    /// A delegate call waiting for its subtask to end (S3), by the subtask.
    @ObservationIgnored var subtaskWaiters: [UUID: CheckedContinuation<SubtaskEnd, Never>] = [:]

    @ObservationIgnored private var runs: [UUID: (id: UUID, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private var decisions: [UUID: CheckedContinuation<Bool, Never>] = [:]
    // Internal, not private: the 7g extensions (ChatRunner+Relay, +Delegate, +Autorun) share them.
    @ObservationIgnored let conversations: ConversationStore
    @ObservationIgnored let agents: AgentStore
    @ObservationIgnored let providers: ProviderStore
    @ObservationIgnored private let client: ChatClient
    /// Whether the user is looking at this conversation now (then a reply isn't unread).
    @ObservationIgnored var isVisible: (UUID) -> Bool = { _ in false }
    /// A reply landed somewhere the user isn't looking — sound and notification (settings decide).
    @ObservationIgnored var onUnseenReply: (Conversation, Message) -> Void = { _, _ in }
    /// Screen updates while text streams in are at most this often; every token would starve the window.
    @ObservationIgnored var publishInterval: TimeInterval = 0.05
    /// After a reply the model names the task (7a); tests that count requests switch it off.
    @ObservationIgnored var namesTasks = true
    /// What the system prompt says about where and for whom the Agent works.
    @ObservationIgnored var projectName: (UUID) -> String? = { _ in nil }
    /// A run ended, whatever its outcome (2026-09-14: the ledger checks the month's budget).
    @ObservationIgnored var onFinished: (UUID) -> Void = { _ in }
    @ObservationIgnored var userName: () -> String = { "" }
    /// The project folder the tools work in, when it can be opened.
    @ObservationIgnored var projectRoot: (UUID) -> URL? = { _ in nil }
    /// The tools a model is offered.
    @ObservationIgnored var tools: [ToolSpec] = AgentTools.all
    /// Commands kept running in the background (10f); one that ends unwatched is told to its conversation.
    @ObservationIgnored lazy var jobs: BackgroundJobs = {
        let jobs = BackgroundJobs()
        jobs.onEnd = { [weak self] job, note in self?.jobEnded(note, in: job.conversationID) }
        return jobs
    }()
    /// The wait before retry `attempt` of a transient failure (L3); tests make it instant.
    @ObservationIgnored var retryDelay: (Int) -> Duration = { attempt in .seconds(min(30, 1 << min(attempt - 1, 5))) }
    /// Runs the hooks of a moment (7b′); tests hand in their own.
    @ObservationIgnored var hooks: (HookEvent, HookInput, URL?) async -> HookOutcome = { _, _, _ in HookOutcome() }
    /// A compaction under way, and why (7e): the thread says 正在压缩上下文….
    private(set) var compacting: [UUID: CompactionRecord.Reason] = [:]
    /// A model's context window: the provider's list or the built-in table; tests and the QA hook hand in their own.
    @ObservationIgnored var contextWindow: (ModelReference) -> Int? = { _ in nil }
    /// Skills, MCP and memory (7f): the app hands them in; a test sets what it exercises.
    @ObservationIgnored var skillLibrary: SkillLibrary?
    /// The subagents (user 2026-09-15): whom `delegate` may name, and what their runs get.
    @ObservationIgnored var subagents: SubagentLibrary?
    @ObservationIgnored var mcp: MCPStore?
    @ObservationIgnored var mcpClient = MCPClient()
    @ObservationIgnored var memory: MemoryStore?
    /// Skill folders an Agent created with skill_create, per conversation: `write` may fill them (F2).
    @ObservationIgnored private var createdSkillFolders: [UUID: [URL]] = [:]
    /// Computer use (7j, C1–C3): the Mac, where screenshots go, and who is told when a run starts and stops operating
    /// it (the stop bar). The app hands them in only in the Developer ID build; tests hand in a stand-in.
    @ObservationIgnored var desktop: (any Desktop)?
    @ObservationIgnored var screenshotFolder: URL?
    @ObservationIgnored var onOperating: (UUID, Bool) -> Void = { _, _ in }
    /// Runs the script layer's commands (7j, S1); tests hand in a stand-in.
    @ObservationIgnored var scriptRunner: ScriptTools.Runner = ScriptTools.system
    @ObservationIgnored private var computerSessions: [UUID: ComputerSession] = [:]

    init(conversations: ConversationStore, agents: AgentStore, providers: ProviderStore, client: ChatClient = ChatClient()) {
        self.conversations = conversations
        self.agents = agents
        self.providers = providers
        self.client = client
        contextWindow = { [providers] reference in providers.modelInfo(reference.providerID, reference.modelID)?.contextWindow }
    }

    /// A run under way — or a dispatcher choosing, an autorun between rounds (7g), an arrangement with its lanes out
    /// (9e): 停止 applies, a message steers.
    func isRunning(_ id: UUID) -> Bool {
        activeRuns[id] != nil || dispatching.contains(id) || autoruns[id] != nil || conducts[id] != nil
    }

    func pending(_ id: UUID) -> [UUID] { queues[id] ?? [] }

    /// A direct chat: its Agent answers the latest message.
    func reply(to id: UUID) {
        guard !isRunning(id), let conversation = conversations.conversation(id), !conversation.isGroup,
              let agent = agents.agent(conversation.agentID) else { return }
        start(id, agent: agent)
        // H (9e): a long first message's card gets Bob's title.
        if let last = conversation.messages.last(where: { $0.role == .user && !$0.isHidden && $0.event == nil }) { nameCard(id, message: last.id) }
    }

    /// A group chat: these members answer, one after another — never at once, or their streams would
    /// interleave in one thread (spec §9.10).
    func dispatch(_ id: UUID, to agentIDs: [UUID]) {
        guard activeRuns[id] == nil, conversations.conversation(id)?.isGroup == true, !agentIDs.isEmpty else { return }
        // Whoever was `@`-ed while a dispatcher chose stays in line after them (7g, M1).
        queues[id] = agentIDs + pending(id).filter { !agentIDs.contains($0) }
        advance(id)
    }

    /// Sent while the Agent works: it reads it after the current step (L4). In a group, newly `@`-ed members join
    /// the queue.
    func steer(_ id: UUID, _ message: Message) {
        guard isRunning(id) else { return }
        steering[id, default: []].append(message)
        // A long command doesn't keep the user waiting (user 2026-09-17): it goes on in the background.
        if Self.isSpoken(message) { asides[id]?.request() }
        guard conversations.conversation(id)?.isGroup == true else { return }
        for agentID in message.assignees where agentID != activeRuns[id]?.agentID && !pending(id).contains(agentID) {
            queues[id, default: []].append(agentID)
        }
    }

    /// 允许 / 拒绝 on the call that waits.
    func decide(_ id: UUID, allow: Bool) {
        guard approvals[id] != nil else { return }
        approvals[id] = nil
        decisions.removeValue(forKey: id)?.resume(returning: allow)
    }

    /// 10b: the card's four answers — allowing once, for this conversation, for the project from now on, or not.
    func decide(_ id: UUID, _ choice: ApprovalChoice) {
        guard let approval = approvals[id] else { return }
        if let grant = approval.grant {
            switch choice {
            case .conversation:
                if !(sessionGrants[id] ?? []).contains(grant) { sessionGrants[id, default: []].append(grant) }
            case .project:
                if let project = conversations.conversation(id)?.projectID { approvalRules?.add(grant, project: project) }
            case .once, .deny:
                break
            }
        }
        decide(id, allow: choice != .deny)
    }

    /// 10d: 撤销 on a save card — the file back to before that step, the card marked, the Agent told before its next
    /// call. `nil`: done; otherwise why not.
    func undoChange(_ id: UUID, message messageID: UUID, call callID: String) -> String? {
        guard let conversation = conversations.conversation(id),
              let call = conversation.messages.first(where: { $0.id == messageID })?.toolCalls.first(where: { $0.id == callID }),
              var result = call.result, let change = result.change, let path = result.savedPath else { return "找不到这次修改。" }
        guard FileHistory.canUndo(change) else { return "这次修改撤不回去。" }
        guard let root = workRoot(for: conversation) else { return "项目文件夹现在打不开。" }
        if let problem = FileHistory.undo(change, path: path, root: root, history: fileHistoryFolder) { return problem }
        result.change?.undone = true
        conversations.setToolResult(result, call: callID, message: messageID, in: id)
        conversations.append(Message(role: .user, text: "〔用户撤销了对 \(path) 的这次修改，文件回到了修改之前的样子〕", isHidden: true), to: id)
        return nil
    }

    /// 10e: a change a step recorded from `messageID` on that can still be undone.
    struct RecordedChange: Equatable {
        var messageID: UUID
        var callID: String
        var path: String
        var change: FileChange
    }

    /// 10e: what going back to a message did.
    struct Rewind {
        var version: EarlierVersion
        /// Put back as they were before the replaced part.
        var restoredFiles: [String]
        /// Changed by the replaced part and still so — the Agent reads which.
        var changedFiles: [String]
    }

    /// The changes recorded from `messageID` on that can still be undone, newest first.
    func changes(since messageID: UUID, in id: UUID) -> [RecordedChange] {
        guard let messages = conversations.conversation(id)?.messages,
              let index = messages.firstIndex(where: { $0.id == messageID }) else { return [] }
        let found = messages[index...].flatMap { message in
            message.toolCalls.compactMap { call -> RecordedChange? in
                guard let change = call.result?.change, let path = call.result?.savedPath, FileHistory.canUndo(change) else { return nil }
                return RecordedChange(messageID: message.id, callID: call.id, path: path, change: change)
            }
        }
        return Array(found.reversed())
    }

    /// 10e: back to `messageID`, before it goes again changed. Asked to, the files the replaced part changed go back
    /// first — newest first, each only while it is still what its step left (10d), so nothing done since is lost; the
    /// Agent reads which stay changed. `nil`: working, or no such message.
    func rewind(_ id: UUID, from messageID: UUID, restoringFiles: Bool) -> Rewind? {
        guard !isRunning(id), let conversation = conversations.conversation(id),
              conversation.messages.contains(where: { $0.id == messageID }) else { return nil }
        let recorded = changes(since: messageID, in: id)
        var restored: [String] = []
        if restoringFiles, let root = workRoot(for: conversation) {
            for item in recorded {
                guard FileHistory.undo(item.change, path: item.path, root: root, history: fileHistoryFolder) == nil,
                      var result = conversations.conversation(id)?.messages.first(where: { $0.id == item.messageID })?
                        .toolCalls.first(where: { $0.id == item.callID })?.result else { continue }
                result.change?.undone = true
                conversations.setToolResult(result, call: item.callID, message: item.messageID, in: id)
                if !restored.contains(item.path) { restored.append(item.path) }
            }
        }
        guard let version = conversations.rewind(id, from: messageID) else { return nil }
        var changed: [String] = []
        for item in recorded.reversed() where !restored.contains(item.path) && !changed.contains(item.path) { changed.append(item.path) }
        if !changed.isEmpty { conversations.append(Message(role: .user, text: Self.rewindNote(changed), isHidden: true), to: id) }
        return Rewind(version: version, restoredFiles: restored, changedFiles: changed)
    }

    /// What the Agent reads when the replaced part's files stay as it left them (10e).
    nonisolated static func rewindNote(_ paths: [String]) -> String {
        "〔用户回到了之前的一条消息，改过之后重新发送，那之后的对话已作废。作废的那部分改过这些文件，它们现在仍是改过的样子："
            + paths.joined(separator: "、") + "〕"
    }

    /// 10b: remembered for this conversation, or for its project.
    func isGranted(_ call: ToolCall, conversationID id: UUID) -> Bool {
        if sessionGrants[id]?.contains(where: { ApprovalGrants.covers($0, call) }) == true { return true }
        guard let project = conversations.conversation(id)?.projectID else { return false }
        return approvalRules?.covers(call, project: project) == true
    }

    /// QA only (`-FormoraSeedApproval`): a step waiting on its card as a run would leave it — nothing resumes it.
    func qaWaitForApproval(_ id: UUID, message messageID: UUID, call: ToolCall, risk: String?, preview: String? = nil) {
        approvals[id] = Approval(messageID: messageID, callID: call.id, reason: AgentTools.forcedApproval(call), risk: risk,
                                 grant: ApprovalGrants.offer(for: call), preview: preview)
    }

    /// 继续 after a paused run (L2): the same Agent picks up where it stopped.
    func resume(_ id: UUID) {
        guard !isRunning(id), let conversation = conversations.conversation(id),
              let paused = conversation.messages.last(where: { $0.pause != nil }) else { return }
        conversations.clearPauses(in: id)
        if conversation.isGroup {
            if let agentID = paused.agentID { dispatch(id, to: [agentID]) }
        } else {
            reply(to: id)
        }
    }

    /// 停止: what had arrived becomes the reply, marked as stopped; every call that didn't run says so; in a group
    /// the rest of the queue doesn't run either — stopping only the current one would be no stop at all (spec §9.10).
    func stop(_ id: UUID) {
        queues[id] = nil
        onOperating(id, false)
        waiting[id] = nil
        dropAdvice(id)
        // 7g: a dispatcher still choosing, and the subtasks this run waits on (M1, S7).
        if dispatching.remove(id) != nil { dispatchTasks.removeValue(forKey: id)?.cancel() }
        reviewing.remove(id)
        for child in conversations.subtasks(of: id) where isRunning(child.id) { stop(child.id) }
        guard let run = runs.removeValue(forKey: id) else {
            flushMemoryNotes(id)
            let spoken = deliverSteering(id)
            stopTeamwork(id)
            if spoken { answerAfterStop(id) }
            return
        }
        run.task.cancel()
        activeRuns[id] = nil
        approvals[id] = nil
        executing[id] = nil
        decisions.removeValue(forKey: id)?.resume(returning: false)
        if let draft = drafts.removeValue(forKey: id) {
            let text = ChatText.clean(draft.text)
            let thinking = draft.thinking.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty || !thinking.isEmpty {
                let agent = agents.agent(draft.agentID)
                conversations.append(Message(role: .agent, agentID: draft.agentID, speakerName: agent?.displayName, text: text,
                                             thinking: thinking.isEmpty ? nil : thinking, thinkingSeconds: draft.thinkingSeconds,
                                             model: draft.model, usage: draft.usage,
                                             durationSeconds: Date.now.timeIntervalSince(draft.startedAt), isStopped: true,
                                             note: draft.note, runID: draft.runID),
                                     to: id)
            }
        }
        conversations.closeOpenCalls(in: id, ToolResult(status: .stopped, output: "用户停止了，这一步没有执行。"))
        flushMemoryNotes(id)
        let spoken = deliverSteering(id)
        stopTeamwork(id)
        if spoken { answerAfterStop(id) }
    }

    /// 停止 with the user's message waiting (user 2026-09-17; Claude Code and Codex do the same): the work stops and
    /// the message is answered as if sent now — nobody sends it twice. A subtask's goes back with its report.
    private func answerAfterStop(_ id: UUID) {
        guard let conversation = conversations.conversation(id), !conversation.isSubtask, !isRunning(id) else { return }
        if conversation.isGroup {
            if let message = conversation.messages.last(where: Self.isSpoken) { route(id, message: message.id) }
        } else {
            reply(to: id)
        }
    }

    /// What 停止 ends besides the run (7g): a chain, an autorun (M4, A4); a subtask's parent gets what it had (S7).
    private func stopTeamwork(_ id: UUID) {
        endRelay(id, .stopped)
        endAutorun(id, .stopped)
        endConduct(id, .stopped)
        settleSubtask(id, .stopped)
    }

    /// The conversation is going away: nothing to keep, and nothing must run on for nothing.
    func discard(_ id: UUID) {
        for child in conversations.subtasks(of: id) { discard(child.id) }
        jobs.stop(conversation: id)
        dropAdvice(id)
        advisorMarks[id] = nil
        // 10l: a lane going mid-work: its copy goes too.
        if let copy = laneCopies.removeValue(forKey: id) { Task.detached { LaneCopies.remove(copy) } }
        queues[id] = nil
        steering[id] = nil
        for message in heldAdvice[id] ?? [] { heldAdviceMarks[message.id] = nil }
        heldAdvice[id] = nil
        computerSessions[id] = nil
        relays[id] = nil
        autoruns[id] = nil
        conducts[id] = nil
        sessionGrants[id] = nil
        conductTasks.removeValue(forKey: id)?.cancel()
        if dispatching.remove(id) != nil { dispatchTasks.removeValue(forKey: id)?.cancel() }
        reviewing.remove(id)
        subtaskWaiters.removeValue(forKey: id)?.resume(returning: .stopped)
        runs.removeValue(forKey: id)?.task.cancel()
        decisions.removeValue(forKey: id)?.resume(returning: false)
        activeRuns[id] = nil
        drafts[id] = nil
        approvals[id] = nil
        executing[id] = nil
    }

    /// 重试 on a failed reply: it goes, and the same Agent is asked again.
    func retry(_ id: UUID) {
        guard !isRunning(id), let conversation = conversations.conversation(id) else { return }
        guard let last = conversation.messages.last(where: { !$0.isHidden }), last.failure != nil else { return }
        conversations.removeMessage(last.id, from: id)
        if conversation.isGroup {
            if let agentID = last.agentID { dispatch(id, to: [agentID]) }
        } else {
            reply(to: id)
        }
    }

    /// Quitting: every partial reply is kept as stopped (old app 2026-09-06).
    func stopAll() {
        for id in Array(activeRuns.keys) { stop(id) }
        // Background commands (10f) and everything they started go with Formora.
        jobs.stopEverything()
        // 10l: what lanes changed in their copies comes back before Formora goes.
        for (laneID, copy) in laneCopies {
            let name = conversations.conversation(laneID).flatMap { agents.agent($0.agentID)?.displayName } ?? "Agent"
            _ = LaneCopies.merge(copy, name: name)
            LaneCopies.remove(copy)
        }
        laneCopies = [:]
    }

    // MARK: Context (7e)

    nonisolated static let midRunCompactionLimit = 3

    enum CompactOutcome: Equatable {
        case done(CompactionRecord)
        /// Pruning alone brought it under the threshold.
        case pruned
        /// Too little to fold.
        case nothing
        case failed(String)
    }

    /// The ring and the hint (E7): how full the context is for the Agent that would answer next.
    func contextUsage(_ id: UUID) -> ContextBudget.Usage? {
        guard let conversation = conversations.conversation(id), conversation.messages.contains(where: { $0.role == .agent }),
              let model = contextAgent(conversation)?.primaryModel else { return nil }
        return ContextBudget.usage(conversation.messages, window: contextWindow(model))
    }

    /// `/compact [重点]` (E4): prune, then summarize everything but the newest part. `nil` when it was done.
    func compact(_ id: UUID, focus: String) async -> String? {
        guard !isRunning(id), compacting[id] == nil else { return "它还在做，等这一轮做完再压缩" }
        guard let conversation = conversations.conversation(id), let agent = contextAgent(conversation) else {
            return "这条对话里没有能压缩的 Agent"
        }
        switch await compactContext(id, agent: agent, reason: .manual, focus: focus.isEmpty ? nil : focus) {
        case .done, .pruned: return nil
        case .nothing: return "这条对话还很短，压缩省不下什么"
        case .failed(let reason): return reason
        }
    }

    /// The Agent a conversation's context is measured for: its own, or in a group whoever answered last.
    private func contextAgent(_ conversation: Conversation) -> AgentRecord? {
        guard conversation.isGroup else { return agents.agent(conversation.agentID) }
        if let last = conversation.messages.last(where: { $0.role == .agent }), let agent = agents.agent(last.agentID) { return agent }
        return ConversationReadiness.members(of: conversation, agents: agents).first
    }

    /// After a run over the threshold (E4): compact in the background; the divider shows when it is done.
    private func compactAfterRun(_ id: UUID, agentID: UUID?) {
        guard let conversation = conversations.conversation(id), let agent = agents.agent(agentID ?? conversation.agentID),
              let model = agent.primaryModel, let window = contextWindow(model),
              ContextBudget.usage(conversation.messages, window: window).isOverThreshold else { return }
        Task { [weak self] in _ = await self?.compactContext(id, agent: agent, reason: .threshold, focus: nil) }
    }

    /// omp's ladder (E3): old tool output pruned first — for an automatic trigger that may be enough — then the newest
    /// part kept and the rest summarized (or the previous summary updated) by the Agent's model.
    private func compactContext(_ id: UUID, agent: AgentRecord, reason: CompactionRecord.Reason, focus: String?) async -> CompactOutcome {
        guard compacting[id] == nil, let conversation = conversations.conversation(id), let primary = agent.primaryModel else {
            return .nothing
        }
        compacting[id] = reason
        defer { compacting[id] = nil }
        let known = contextWindow(primary)
        let window = known ?? 128_000
        let budgets = Compaction.Budgets.forWindow(window)
        let before = ContextBudget.usage(conversation.messages, window: known).tokens
        let candidates = Compaction.pruneCandidates(Compaction.effective(conversation.messages).messages, budgets: budgets)
        conversations.prune(candidates, in: id)
        guard let pruned = conversations.conversation(id) else { return .nothing }
        if !candidates.isEmpty, reason == .threshold || reason == .midRun, known != nil,
           !ContextBudget.usage(pruned.messages, window: known).isOverThreshold {
            return .pruned
        }
        let current = Compaction.effective(pruned.messages)
        guard let cut = Compaction.cutIndex(current.messages, keepRecent: budgets.keepRecent) else {
            return candidates.isEmpty ? .nothing : .pruned
        }
        let prompt = Compaction.request(Array(current.messages[..<cut]), previous: current.summary?.summary, focus: focus) { [agents] message in
            message.role == .user ? "用户" : message.speakerName ?? agents.agent(message.agentID)?.displayName ?? "Agent"
        }
        // 省事: a cheaper model compacts, when one is set (user 2026-09-16).
        let compactChain = [agent.model(for: .chore), primary].compactMap { $0 } + agent.fallbacks
        guard let written = await oneShot(system: Compaction.system, prompt: prompt, candidates: compactChain) else {
            return .failed("压缩没有成功：模型没有写出摘要，稍后再试")
        }
        var record = CompactionRecord(summary: written.summary, firstKeptID: current.messages[cut].id, tokensBefore: before, tokensAfter: 0,
                                      reason: reason, focus: focus)
        let message = Message(role: .user, text: "", model: written.model, usage: written.usage, isHidden: true, compaction: record)
        conversations.append(message, to: id)
        record.tokensAfter = conversations.conversation(id).map { ContextBudget.usage($0.messages, window: known).tokens } ?? 0
        conversations.setCompaction(record, message: message.id, in: id)
        return .done(record)
    }

    /// One request of the app's own — a summary (E3), 旁审, Bob's arranging: no tools, the reasoning level left to the
    /// host's default (a judgement is worth its thinking); the next model if one fails.
    /// One question to a model, no tools; `images` are file paths the model sees with the words (the last screenshot of a
    /// computer task, user 2026-09-15).
    func oneShot(system: String, prompt: String, candidates: [ModelReference], images: [String] = [], thinks: Bool = true) async
        -> (summary: String, model: ModelReference, usage: TokenUsage?)? {
        let pictures = images.compactMap { ChatImages.load(URL(fileURLWithPath: $0)) }
        for reference in candidates {
            guard let target = await target(for: reference) else { continue }
            // `thinks: false`（起名这类不用想的小事）：明说不思考——不说的话 DeepSeek 默认开着思考，一个标题输出五百多 token
            // （真实测试 2026-09-18）。服务商不认这个字段，就不带它再问一次。
            for sendsReasoning in thinks ? [false] : [true, false] {
                guard let request = ChatWire.request(target, system: system, history: [ChatTurn(role: .user, text: prompt, images: pictures)],
                                                     reasoning: .off, sendsReasoning: sendsReasoning) else { break }
                var text = ""
                var usage = TokenUsage()
                do {
                    for try await event in client.stream(request, apiProtocol: target.endpoint.apiProtocol) {
                        switch event {
                        case .text(let piece): text += piece
                        case let .usage(input, output, cached, _):
                            if let input { usage.input = input }
                            if let output { usage.output = output }
                            if let cached { usage.cached = cached }
                        case .failed(let message): throw ChatFailure.provider(message)
                        default: break
                        }
                    }
                } catch {
                    if sendsReasoning, ChatFailure.from(error).rejectsReasoning { continue }
                    break
                }
                let summary = SecretShield.shared.restore(ChatText.clean(text))
                if !summary.isEmpty { return (summary, reference, usage.input == nil && usage.output == nil ? nil : usage) }
                break
            }
        }
        return nil
    }

    // MARK: Questions, plans, review (7d)

    /// Tools every Agent has on top of `tools`: the plan and the question (D4, D6).
    @ObservationIgnored var loopTools: [ToolSpec] = [PlanTool.spec, AskTool.spec]

    /// The question waiting in a conversation (D6): the last visible turn's `ask` call without an answer, while no run
    /// is under way. It is on disk, so it outlives a restart.
    func pendingQuestion(_ id: UUID) -> (message: Message, call: ToolCall, questions: [AskTool.Question])? {
        guard !isRunning(id), let last = conversations.conversation(id)?.messages.last(where: { !$0.isHidden }), last.role == .agent,
              let call = last.toolCalls.last(where: { $0.name == AskTool.spec.name && $0.result == nil }),
              case .success(let questions) = AskTool.parse(call.arguments) else { return nil }
        return (last, call, questions)
    }

    /// Picked or typed (spec §9.8b): the answer is the call's result, and the Agent that asked carries on.
    func answer(_ id: UUID, _ answers: [AskTool.Answer]) {
        guard let pending = pendingQuestion(id) else { return }
        var all = answers
        while all.count < pending.questions.count { all.append(AskTool.Answer()) }
        conversations.setToolResult(ToolResult(status: .done, output: AskTool.text(pending.questions, all), answers: all),
                                    call: pending.call.id, message: pending.message.id, in: id)
        guard let agent = agents.agent(pending.message.agentID) else { return }
        start(id, agent: agent)
    }

    /// `/review` (10h): 旁审 reads the Agent's latest run now, with what the user wants looked at — a 担心 or 必须停
    /// sends the Agent back to deal with it; nothing to say, a line saying so.
    func review(_ id: UUID, agent: AgentRecord, focus: String) {
        guard !isRunning(id), let conversation = conversations.conversation(id),
              let latest = conversation.messages.last(where: { $0.role == .agent && !$0.isHidden && $0.agentID == agent.id }) else { return }
        let runID = latest.runID ?? latest.id
        let steps = latest.runID == nil ? [latest] : nil
        Task { [weak self] in await self?.advise(id, runID: runID, agent: agent, final: true, focus: focus, manual: true, steps: steps) }
    }

    /// The tools of one request: the shared ones, the plan and the question, and the Agent's own (7f); in plan mode
    /// only those that read (D5, F5).
    private func offeredTools(_ conversation: Conversation, agent: AgentRecord) -> [ToolSpec] {
        var all = tools + loopTools + agentTools(agent) + teamTools(conversation, agent: agent)
        // No plan mode, no plan (user 2026-09-17): the list is made in plan mode; outside it the tool stays only while
        // steps are open — a plan being carried out, or the user's own `/todo`.
        if !Self.keepsPlan(conversation) { all.removeAll { $0.name == PlanTool.spec.name } }
        // A subtask (7g, S2): nothing to ask the user, nothing kept for later; `read_only` leaves the read tier.
        if let link = conversation.parent {
            let withheld = Set([AskTool.spec.name, MemoryTools.remember.name, SkillTools.create.name, ComputerTool.name]).union(ScriptTools.names)
            // A read-only helper may still read a page — it asks, like anywhere (D70).
            all = all.filter { !withheld.contains($0.name) && (!link.readOnly || $0.tier == .read || $0.name == AgentTools.fetch.name) }
        }
        // A subagent's definition says what it may touch (user 2026-09-15); reading a page stays, as for any helper.
        // It starts without memory: no directory, nothing to recall.
        if let name = conversation.parent?.subagent, let definition = subagents?.definition(named: name) {
            all = all.filter { ($0.tier <= definition.tier || $0.name == AgentTools.fetch.name) && $0.name != MemoryTools.recall.name }
        }
        // Plan mode: only what reads — and no hand-off: the plan is for the user to approve (D5, M5).
        // Plan mode looks before it acts; reading a page is looking, and it asks (D70).
        let offered = conversation.planMode
            ? all.filter { ($0.tier == .read || $0.name == AgentTools.fetch.name) && $0.name != TeamTools.handoff.name } : all
        // What was started in the background is read and stopped with these — wherever bash is offered (10f).
        return offered.contains { $0.name == AgentTools.bash.name } ? offered + BackgroundJobs.specs : offered
    }

    /// Whether the plan is what this run is about (user 2026-09-17): it worked the plan itself, or the user's latest
    /// words were the plan's go-ahead — 「按这个计划做」, 「继续」. A new request in a conversation that still has an old
    /// plan is answered and left at that; 继续 takes the plan up again.
    nonisolated static func followsPlan(_ conversation: Conversation, touched: Bool) -> Bool {
        if touched { return true }
        guard let latest = conversation.messages.last(where: isSpoken) else { return false }
        return PlanTool.isGoAhead(latest.text)
    }

    /// Whether the `plan` tool belongs in this conversation now (user 2026-09-17).
    nonisolated static func keepsPlan(_ conversation: Conversation) -> Bool {
        conversation.planMode || conversation.plan.contains(where: \.isOpen)
    }

    /// The Agent's own tools (7f): loading its Skills, writing a new one, memory, its MCP tools.
    private func agentTools(_ agent: AgentRecord) -> [ToolSpec] {
        var specs: [ToolSpec] = []
        if !enabledSkills(agent).isEmpty { specs.append(SkillTools.load) }
        if skillLibrary != nil { specs.append(SkillTools.create) }
        if memory != nil { specs += [MemoryTools.remember, MemoryTools.recall] }
        if let mcp {
            specs += MCPTools.bindings(for: agent, in: mcp).map(\.spec)
            // Connecting a new service (7h, B9): always asks, whatever the 权限模式.
            specs += [MCPConnect.catalogSpec, MCPConnect.addSpec]
        }
        // Computer use and its script layer (7j, B3, C1, S1): only an Agent allowed to, in a build that has it.
        if desktop != nil, ComputerBuild.isAvailable, agent.allowsComputer { specs += [ComputerTool.spec] + ScriptTools.all }
        return specs
    }

    private func enabledSkills(_ agent: AgentRecord) -> [Skill] {
        guard let skillLibrary else { return [] }
        return agent.enabledSkills.compactMap { skillLibrary.skill($0) }
    }

    /// A tool's tier wherever it comes from — the approval and plan mode go by it.
    private func tier(of name: String, agent: AgentRecord) -> ToolTier? {
        (tools + loopTools + agentTools(agent) + TeamTools.all + BackgroundJobs.specs).first { $0.name == name }?.tier
    }

    /// skill, skill_create, remember and the MCP tools (7f); `nil` for the file, shell and web tools.
    private func runAgentTool(_ call: ToolCall, conversationID id: UUID, agent: AgentRecord) async -> ToolResult? {
        let args = ToolArguments.parse(call.arguments) ?? [:]
        switch call.name {
        case SkillTools.load.name:
            let skills = enabledSkills(agent)
            let name = args["name"] as? String ?? ""
            guard let skill = SkillTools.find(name, in: skills) else {
                return .failed("没有叫「\(name)」的 Skill。你能用的：" + skills.map { "「\($0.name)」" }.joined(separator: "、"))
            }
            return .done(SkillTools.loaded(skill, folder: skillLibrary?.folder(of: skill)))
        case SkillTools.create.name:
            guard let skillLibrary else { return .failed("这里不能新建 Skill。") }
            let fields = ["name", "description", "instructions"].map { (args[$0] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
            guard !fields.contains(where: \.isEmpty) else { return .failed("name、description、instructions 都要写。Skill 没有建。") }
            do {
                let skill = try skillLibrary.create(name: fields[0], description: fields[1], body: fields[2])
                if !agent.enabledSkills.contains(skill.id) { try? agents.setSkill(agent, skill.id, enabled: true) }
                let folder = skillLibrary.folder(of: skill)
                if let folder { createdSkillFolders[id, default: []].append(folder) }
                let where_ = folder.map { "文件夹：\($0.path)。要放参考资料或脚本，用 write 写进它的 references/、scripts/。" } ?? ""
                return ToolResult(status: .done, output: "已新建 Skill「\(skill.name)」，并为你启用。" + where_)
            } catch let problem as SkillProblem {
                return .failed(problem.message + "。Skill 没有建。")
            } catch {
                return .failed(error.localizedDescription)
            }
        case MCPConnect.catalogSpec.name:
            return .done(MCPConnect.catalogText())
        case MCPConnect.addSpec.name:
            guard let mcp else { return .failed("这里不能接入 MCP。") }
            switch MCPConnect.plan(call.arguments, store: mcp) {
            case .answer(let result, _): return result
            case let .add(server, secrets): return await MCPConnect.add(server, secrets: secrets, store: mcp)
            }
        case MemoryTools.remember.name:
            guard let memory, let conversation = conversations.conversation(id) else { return .failed("这里没有记忆。") }
            let (result, change) = MemoryTools.remember(call.arguments, store: memory, context: memoryContext(conversation, agent: agent))
            // The thread's line (user 2026-09-17) lands when the run rests, so the run's steps stay one group.
            if let change { memoryNotes[id, default: []].append(change) }
            return result
        case MemoryTools.recall.name:
            guard let memory, let conversation = conversations.conversation(id) else { return .failed("这里没有记忆。") }
            return MemoryTools.recall(call.arguments, store: memory, context: memoryContext(conversation, agent: agent))
        case BackgroundJobs.output.name:
            let wait = min(max(ToolArguments.int(args, "wait") ?? 0, 0), 30)
            return await jobs.output(args["id"] as? String ?? "", in: id, wait: TimeInterval(wait))
        case BackgroundJobs.stop.name:
            return await jobs.stop(args["id"] as? String ?? "", in: id)
        default:
            guard call.name.hasPrefix(MCPTools.prefix), let mcp else { return nil }
            guard let binding = MCPTools.bindings(for: agent, in: mcp).first(where: { $0.spec.name == call.name }) else {
                return .failed("\(call.name) 不在你能用的 MCP 工具里（可能在 Agent 的 MCP 标签里关掉了）。")
            }
            executing[id] = call.id
            defer { executing[id] = nil }
            return await MCPTools.call(binding, arguments: call.arguments, store: mcp, client: mcpClient)
        }
    }

    /// Outside the project, the tools may read the Agent's enabled Skills and write a Skill it created here (F1–F2).
    private func readRoots(_ agent: AgentRecord) -> [URL] {
        enabledSkills(agent).compactMap { skillLibrary?.folder(of: $0) }
    }

    // MARK: Memory (user 2026-09-17): layers, a note at a time, the thread's line and its 撤销

    /// What this Agent reads here: what holds everywhere, the project's, its own.
    func memoryScopes(_ conversation: Conversation, agent: AgentRecord) -> [MemoryScope] {
        [.global, .project(conversation.projectID), .agent(agent.id)]
    }

    /// Who is writing, and what a note may rest on: the user's own words in this conversation — a lane's and a
    /// subtask's are in the conversation it works for — and whether a step failed here.
    func memoryContext(_ conversation: Conversation, agent: AgentRecord) -> MemoryTools.Context {
        let scopes = memoryScopes(conversation, agent: agent)
        let above = conversation.parent.flatMap { conversations.conversation($0.conversationID) }?.messages ?? []
        let messages = above + conversation.messages
        // What the user picked or typed on an option card is the user's word too — it lives in the `ask` call's result.
        let answers = messages.flatMap(\.toolCalls).flatMap { $0.result?.answers ?? [] }.flatMap { $0.picked + [$0.typed].compactMap { $0 } }
        return MemoryTools.Context(readable: scopes, writable: Dictionary(uniqueKeysWithValues: scopes.map { ($0.name, $0) }),
                                   userWords: messages.filter(Self.isSpoken).map(\.text) + answers,
                                   hasFailure: messages.contains { $0.toolCalls.contains { $0.result?.status == .failed } },
                                   source: conversation.id)
    }

    /// 「记下了（全局）：……」 with its 撤销, in the thread. The model reads nothing of it. `quietly`: dated as the
    /// conversation's last word, so a look back in the background doesn't lift it to the top of the list.
    func noteMemory(_ change: MemoryChange, in id: UUID, quietly: Bool = false) {
        var event = ThreadEvent(kind: .memory, title: change.line)
        event.memoryChange = change
        let date = quietly ? conversations.conversation(id)?.updatedAt ?? .now : .now
        conversations.append(Message(role: .user, text: "", createdAt: date, event: event), to: id)
    }

    /// Every conversation gone quiet is looked over, one after another (`MemoryUpkeep`) — not one at work.
    func sweepMemory(now: Date = .now) async {
        guard memory != nil else { return }
        for conversation in conversations.conversations where MemoryUpkeep.isDue(conversation, now: now) && !isRunning(conversation.id) {
            await upkeepMemory(conversation.id, now: now)
        }
    }

    /// One look back: the Agent's main model — judging what is worth keeping isn't the cheapest model's job — reads
    /// what was said since the last look and answers with `remember` calls, usually none. Each goes through the
    /// same checks as the Agent's own; what passes is said in the thread. It counts in /cost.
    func upkeepMemory(_ id: UUID, now: Date = .now) async {
        guard let memory, let conversation = conversations.conversation(id), MemoryUpkeep.isDue(conversation, now: now), !isRunning(id),
              let agent = agents.agent(conversation.isGroup ? conversation.messages.last { $0.role == .agent }?.agentID : conversation.agentID),
              let primary = agent.primaryModel else { return }
        let context = memoryContext(conversation, agent: agent)
        let text = Compaction.serialize(MemoryUpkeep.window(conversation)) { [agents] message in
            message.role == .user ? "用户" : message.speakerName ?? agents.agent(message.agentID)?.displayName ?? "Agent"
        }
        // Marked before the call: a look that fails isn't tried again and again.
        conversations.setMemoryPass(now, in: id)
        let prompt = MemoryUpkeep.request(directory: memory.directory(context.readable, now: now), conversation: text,
                                          scopes: context.writable.keys.sorted { $0 > $1 }, now: now)
        guard let reply = await oneShot(system: MemoryUpkeep.system, prompt: prompt, candidates: [primary] + agent.fallbacks) else { return }
        let quiet = conversations.conversation(id)?.updatedAt ?? now
        for operation in MemoryUpkeep.operations(from: reply.summary) {
            if let change = MemoryTools.remember(operation, store: memory, context: context, now: now).change { noteMemory(change, in: id, quietly: true) }
        }
        conversations.append(Message(role: .user, text: "", createdAt: quiet, model: reply.model, usage: reply.usage, isHidden: true, isUpkeep: true), to: id)
    }

    /// What the run remembered, and 旁审's 提醒 that waited, once it rests.
    func flushMemoryNotes(_ id: UUID) {
        for change in memoryNotes.removeValue(forKey: id) ?? [] { noteMemory(change, in: id) }
        for message in heldAdvice.removeValue(forKey: id) ?? [] {
            let mark = heldAdviceMarks.removeValue(forKey: message.id)
            let run = conversations.conversation(id)?.messages.filter { $0.runID == message.runID && !$0.isUpkeep } ?? []
            if let mark, Advisor.isStale(after: mark, in: run) { continue }
            conversations.append(message, to: id)
        }
    }

    /// 旁审's 必须停 while the run goes on (user 2026-09-17): the run stops where it is — what had arrived is kept, the
    /// step that didn't run says so — the note is a card, and the dock asks 「要继续吗」. 继续 picks up with the note in
    /// sight; the user may as well say what to do instead. Before, the note was the Agent's to weigh, and it went on.
    func haltForAdvice(_ id: UUID, runID: UUID, message: Message, note: Advisor.Note) {
        guard isCurrent(runID, id), let run = runs.removeValue(forKey: id) else { return }
        run.task.cancel()
        let draft = drafts[id]
        end(id)
        queues[id] = nil
        decisions.removeValue(forKey: id)?.resume(returning: false)
        if let draft {
            let text = ChatText.clean(draft.text)
            if !text.isEmpty {
                conversations.append(Message(role: .agent, agentID: draft.agentID, speakerName: agents.agent(draft.agentID)?.displayName, text: text,
                                             model: draft.model, usage: draft.usage, durationSeconds: Date.now.timeIntervalSince(draft.startedAt),
                                             isStopped: true, note: draft.note, runID: draft.runID), to: id)
            }
        }
        conversations.closeOpenCalls(in: id, ToolResult(status: .stopped, output: "旁审叫停了，这一步没有执行。"))
        let reason = "旁审认为该停下：" + String(note.text.prefix(120))
        if let last = conversations.conversation(id)?.messages.last(where: { $0.runID == runID && $0.role == .agent && !$0.isHidden }) {
            conversations.setPause(reason, message: last.id, in: id)
        }
        flushMemoryNotes(id)
        deliverSteering(id)
        announce(message, in: id)
        endRelay(id, .paused)
        endAutorun(id, .interrupted(reason))
        endConduct(id, .paused)
        if conversations.conversation(id)?.isLane == true { settleSubtask(id, .limit(reason)) }
    }

    /// 撤销 on a memory line: what was added goes, what was changed or forgotten is back as it was.
    func undoMemory(_ messageID: UUID, in id: UUID) {
        guard let memory, let event = conversations.conversation(id)?.messages.first(where: { $0.id == messageID })?.event,
              event.kind == .memory, event.undone != true, let change = event.memoryChange else { return }
        MemoryTools.undo(change, store: memory)
        conversations.markMemoryUndone(messageID, in: id)
    }

    /// An `ask` call (D6): a malformed one, or a second one, goes back to the model; if the user wrote something
    /// meanwhile the model reads that first; otherwise the run ends on it and waits.
    private func ask(_ call: ToolCall, conversationID id: UUID, state: inout RunState) -> ToolResult? {
        switch AskTool.parse(call.arguments) {
        case .failure(let problem):
            return .failed(problem.message)
        case .success:
            if state.asked { return .failed("一次只能问一组问题。这个没有问出去，等用户回答了上一组再问。") }
            if steering[id]?.isEmpty == false { return .failed("用户刚发来新消息，先看新消息；还需要问再问。") }
            state.asked = true
            return nil
        }
    }

    /// The run ends on its question (D6): nothing queued runs, and the user is told where they aren't looking.
    private func waitForAnswer(_ id: UUID, runID: UUID) {
        guard isCurrent(runID, id) else { return }
        end(id)
        queues[id] = nil
        endRelay(id, .paused)
        endAutorun(id, .interrupted("停下来等你回答"))
        endConduct(id, .paused)
        guard !isVisible(id), let last = conversations.conversation(id)?.messages.last(where: { $0.runID == runID && !$0.isHidden }) else { return }
        conversations.incrementUnread(id)
        if let conversation = conversations.conversation(id) { onUnseenReply(conversation, last) }
    }

    // MARK: The run

    func isCurrent(_ runID: UUID, _ id: UUID) -> Bool { runs[id]?.id == runID }

    /// The next queued member that still exists starts.
    func advance(_ id: UUID) {
        while let next = queues[id]?.first {
            queues[id]?.removeFirst()
            if queues[id]?.isEmpty == true { queues[id] = nil }
            if let agent = agents.agent(next) {
                start(id, agent: agent)
                return
            }
        }
        queues[id] = nil
        // 7g: nobody left in line — a chain has ended (M4); an autorun's round is over (A2).
        endRelay(id, .done)
        // 9e: a stage in the thread is over and the arrangement goes on — not while its lanes are out.
        if conducts[id] != nil {
            if conductTasks[id] == nil { stageEnded(id) }
            return
        }
        if autoruns[id] != nil { roundEnded(id) }
    }

    func start(_ id: UUID, agent: AgentRecord, runID: UUID = UUID()) {
        guard activeRuns[id] == nil, conversations.conversation(id) != nil else { return }
        guard agent.primaryModel != nil else {
            announce(Message(role: .agent, agentID: agent.id, speakerName: speaker(agent, in: id), text: "", failure: "没有配置主模型"), in: id)
            advance(id)
            return
        }
        conversations.clearPauses(in: id)
        // Sent while a dispatcher chose or between rounds (7g): read before the first call.
        flushMemoryNotes(id)
        deliverSteering(id)
        // A question left unanswered: the user moved on (D6).
        conversations.closeOpenCalls(in: id, ToolResult(status: .stopped, output: "用户没有回答这个问题，看用户接下来说的。"))
        activeRuns[id] = Run(id: runID, agentID: agent.id)
        AppLog.info("run", "开始 对话=\(id.uuidString.prefix(8)) Agent=\(agent.displayName) 模型=\(agent.providerID ?? "?")/\(agent.modelID)")
        let task = Task { [weak self] in
            guard let self else { return }
            await self.run(runID: runID, conversationID: id, agent: agent)
        }
        runs[id] = (runID, task)
    }

    /// What one run keeps between its model calls.
    struct RunState {
        var sendsReasoning: Bool
        /// Levels the host refused in this run (user 2026-09-18): one retry on the next level, then none at all.
        var refusedLevels: [ReasoningLevel] = []
        var calls = 0
        var model = 0
        var sendsTools = true
        /// A line for the next message: the fallback answered, a parameter was dropped.
        var note: String?
        var fallbackNoted = false
        var empty = 0
        var continued = 0
        var repeats = 0
        var lastCall: String?
        var stopContinues = 0
        /// A hook said `"continue": false`, and why.
        var stopRequested: String?
        /// The model answering now, when its provider searches the web natively (7c, C5).
        var searchTarget: ChatTarget?
        /// Files write or edit changed in this run: the self-review reads them again (7d, D7).
        var written: [String] = []
        var reviewed = false
        var toolTurns = 0
        /// Times this run was sent back to its plan's open steps (user 2026-09-14).
        var planContinues = 0
        /// This run worked the plan itself — started, ticked or changed a step (user 2026-09-17): stopping short of the
        /// open steps is then its business, whatever the user's words were.
        var touchedPlan = false
        /// The user's message arrived mid-run and its answer is next (user 2026-09-17): whether to go on with the
        /// plan is the Agent's call there, not the loop's. Working on — a turn with calls — clears it.
        var steered = false
        /// An `ask` waits for the user: the run ends on it (D6).
        var asked = false
        /// The model refused native tools in this run: they go as text from here on (D8).
        var textTools = false
        /// Compactions before a model call inside this run (7e, E4), and whether an overflow was compacted once.
        var midCompactions = 0
        var overflowCompacted = false
        /// 7g: who takes over when this turn is done (M2); goal_done was called (A3); delegations so far (S4).
        var handoff: Handoff?
        var goalClaimed = false
        var delegations = 0
        var delegatedTokens = 0
        /// 7j: the user allowed operating the computer in this run (C2); the stop bar is up (C3).
        var computerAllowed = false
        var operating = false
        let began = Date.now
        /// 10g: replies a watched rule stopped in this run — past the limit, the rest of the run goes unwatched.
        var ruleBreaks = 0
        static let ruleBreakLimit = 3
    }

    /// One model call's answer.
    private struct Turn {
        var text = ""
        var thinking = ""
        var signature: String?
        var calls: [ToolCall] = []
        var stop = ChatStop.end
        var usage: TokenUsage?
        var model: ModelReference
        var startedAt: Date
        var thinkingSeconds: Double?
    }

    private enum Outcome {
        case turn(Turn)
        /// The request was too long; the context was compacted, so the loop asks again (7e, E4).
        case compacted
        /// It broke off after some text arrived: that text is kept.
        case interrupted(Turn, ChatFailure)
        case failed(String)
    }

    /// The models a run tries, in order (user 2026-09-16): the plan model when planning, the vision model when the
    /// conversation carries images, then the primary, then the shared fallback — each phase model falls through to
    /// the primary. Deduped by the caller.
    nonisolated static func modelChain(for conversation: Conversation, agent: AgentRecord) -> [ModelReference] {
        var chain: [ModelReference] = []
        func add(_ model: ModelReference?) { if let model, !chain.contains(model) { chain.append(model) } }
        if conversation.planMode { add(agent.model(for: .plan)) }
        if hasImages(conversation) { add(agent.model(for: .vision)) }
        add(agent.primaryModel)
        agent.fallbacks.forEach { add($0) }
        return chain
    }

    /// Whether a conversation carries pictures a model would need to see: image attachments, or a tool result's
    /// screenshots (7j).
    nonisolated static func hasImages(_ conversation: Conversation) -> Bool {
        conversation.messages.contains { message in
            message.attachments.contains { $0.kind == .image }
                || message.toolCalls.contains { ($0.result?.images?.isEmpty == false) }
        }
    }

        /// omp's two loops in one: a turn with tool calls runs them and goes round; a turn without is the stop, unless
    /// the user sent something meanwhile (L1, L4). Six ways out (L2), four guards on the way (L3).
    private func run(runID: UUID, conversationID id: UUID, agent: AgentRecord) async {
        guard let conversation = conversations.conversation(id), let primary = agent.primaryModel else { return }
        // A subagent with a model of its own (user 2026-09-15) tries it first, the caller's chain after; the phase
        // models (user 2026-09-16) order the rest — plan mode leads with the plan model, an image turn with the vision.
        let pinned = conversation.parent?.subagent.flatMap { subagents?.definition(named: $0)?.model }
        var candidates = (pinned.map { [$0] } ?? []) + Self.modelChain(for: conversation, agent: agent)
        candidates = candidates.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        var state = RunState(sendsReasoning: (conversations.conversation(id)?.reasoning ?? .auto) != .auto)
        // A `/review` run is the review: it doesn't review itself again.
        state.reviewed = conversations.conversation(id)?.messages.last?.marker != nil
        // A subtask's work is checked by whoever asked for it (7g, S2). A lane is the member's own work (9e): its
        // hooks, self-review and memory as anywhere.
        let isSubtask = conversations.conversation(id).map { $0.isSubtask && !$0.isLane } ?? false
        if isSubtask { state.reviewed = true }
        // A conversation's first run: SessionStart hooks may hand the Agent some background (7b′, H2).
        if conversations.conversation(id)?.messages.contains(where: { $0.role == .agent }) == false {
            // A subtask's first run is SubagentStart (Claude Code's name; 7g, S2).
            let start = isSubtask
                ? await hook(.subagentStart, id, agent: agent, message: "「\(agent.displayName)」开始做一件子任务")
                : await hook(.sessionStart, id, agent: agent, message: "「\(agent.displayName)」开始了一个新对话")
            guard isCurrent(runID, id) else { return }
            if !start.context.isEmpty {
                nudge(id, runID: runID, "以下是 Hook 提供的背景信息：\n" + start.context.joined(separator: "\n\n"))
            }
            state.note = Self.joined(state.note, start.notes)
        }
        while isCurrent(runID, id) {
            guard let conversation = conversations.conversation(id) else { return }
            if let limit = subtaskLimit(conversation, calls: state.calls, began: state.began) {
                return endSubtask(id, runID: runID, reason: limit)
            }
            if Date.now.timeIntervalSince(state.began) > Self.deadline {
                return pause(id, runID: runID, reason: "这次已经连续工作了 \(Int(Self.deadline / 60)) 分钟，停下来等你确认。")
            }
            // Near the window before a model call (7e, E4): compact first, at most three times in one run.
            if state.midCompactions < Self.midRunCompactionLimit, let window = contextWindow(primary),
               ContextBudget.usage(conversation.messages, window: window).isOverThreshold {
                state.midCompactions += 1
                switch await compactContext(id, agent: agent, reason: state.calls == 0 ? .threshold : .midRun, focus: nil) {
                case .done, .pruned: break
                // Nothing could be folded (or it failed): no point asking again in this run (omp: no no-op loops).
                case .nothing, .failed: state.midCompactions = Self.midRunCompactionLimit
                }
                guard isCurrent(runID, id) else { return }
                continue
            }
            let outcome = await call(conversation, runID: runID, agent: agent, candidates: candidates, state: &state)
            guard isCurrent(runID, id) else { return }
            state.calls += 1
            switch outcome {
            case .compacted:
                continue
            case .failed(let reason):
                let model = candidates[min(state.model, candidates.count - 1)]
                return finish(id, runID: runID, Message(role: .agent, agentID: agent.id, speakerName: speaker(agent, in: id), text: "",
                                                        model: model, failure: reason, runID: runID))
            case let .interrupted(turn, failure):
                return finish(id, runID: runID, message(turn, agent: agent, in: id, runID: runID, calls: [], note: "回复中断：\(failure.message)"))
            case .turn(let turn):
                if turn.calls.isEmpty, ChatText.clean(turn.text).isEmpty {
                    if state.empty < Self.emptyLimit {
                        state.empty += 1
                        nudge(id, runID: runID, "你上一条回复没有正文。直接回答用户；需要查看或修改文件就调用工具。")
                        continue
                    }
                    if turn.thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return finish(id, runID: runID, Message(role: .agent, agentID: agent.id, speakerName: speaker(agent, in: id),
                                                                text: "", model: turn.model, failure: ChatFailure.empty.message, runID: runID))
                    }
                    return finish(id, runID: runID, message(turn, agent: agent, in: id, runID: runID,
                                                            note: "模型只返回了思考过程，没有正文。可以换个模型，或者换种问法。"))
                }
                let reply = message(turn, agent: agent, in: id, runID: runID, note: state.note)
                state.note = nil
                if turn.calls.isEmpty {
                    if turn.stop == .length, state.continued < Self.lengthLimit {
                        state.continued += 1
                        conversations.append(reply, to: id)
                        nudge(id, runID: runID, "你的回复被长度上限截断了。从断开的地方接着写，不要重复已经写过的内容。")
                        continue
                    }
                    if steering[id]?.isEmpty == false {
                        conversations.append(reply, to: id)
                        if deliverSteering(id, runID: runID) { state.steered = true }
                        continue
                    }
                    // The plan's open steps (user 2026-09-14; omp's todo reminder): a reply that stops with steps still open
                    // is sent back to them, at most three times a run. Not in plan mode (the plan is for the user), not a
                    // hand-off; a question is a call, so it never comes here. And only when the plan is what this run is
                    // about (user 2026-09-17): an old plan once sent 「删除 skills 来源文件夹」 back to seven steps of a design.
                    if state.planContinues < Self.planContinueLimit, !conversation.planMode, !state.steered,
                       Self.followsPlan(conversations.conversation(id) ?? conversation, touched: state.touchedPlan),
                       let open = conversations.conversation(id)?.plan.filter(\.isOpen), !open.isEmpty,
                       trailingHandoff(reply.text, conversationID: id, agent: agent).handoff == nil {
                        state.planContinues += 1
                        conversations.append(reply, to: id)
                        nudge(id, runID: runID, "计划里还有 \(open.count) 步没做完：\(open.map { "「\($0.text)」" }.joined(separator: "、"))。接着做，做完一步标一步，全部做完再回复；确实要用户决定的事，用 ask 问他，不要停下来等。")
                        continue
                    }
                    // Stop hooks may send it back to work (H6), at most three times a run.
                    let stop = await hook(isSubtask ? .subagentStop : .stop, id, agent: agent, message: "「\(agent.displayName)」回复完了：\(reply.text.prefix(300))") {
                        $0.lastAssistantMessage = reply.text
                        $0.stopHookActive = state.stopContinues > 0
                    }
                    guard isCurrent(runID, id) else { return }
                    var ended = reply
                    ended.note = Self.joined(ended.note, stop.notes)
                    if let reason = stop.blocked, state.stopContinues < Self.stopLimit {
                        state.stopContinues += 1
                        ended.note = Self.joined(ended.note, ["Hook 要它接着做：\(reason)"])
                        conversations.append(ended, to: id)
                        nudge(id, runID: runID, "Hook 要求你继续：\(reason)")
                        continue
                    }
                    // A last line `@名字 交待` hands the work on (7g, M2).
                    let onward = trailingHandoff(ended.text, conversationID: id, agent: agent)
                    if let note = onward.note { ended.note = Self.joined(ended.note, [note]) }
                    finish(id, runID: runID, ended, handoff: onward.handoff)
                    // 旁审 (10h, in place of 7d's self-review): a run that used tools has its answer read.
                    if state.toolTurns > 0 { await advise(id, runID: runID, agent: agent, final: true) }
                    return
                }
                conversations.append(reply, to: id)
                state.toolTurns += 1
                state.steered = false
                await execute(reply, conversationID: id, runID: runID, agent: agent, state: &state)
                guard isCurrent(runID, id) else { return }
                if let reason = state.stopRequested { return stopByHook(id, runID: runID, reason: reason) }
                if state.asked { return waitForAnswer(id, runID: runID) }
                // handoff and goal_done end the run with this turn (7g, M2, A3: the terminal result of L2).
                if state.handoff != nil || state.goalClaimed { return finish(id, runID: runID, nil, handoff: state.handoff) }
                // 旁审 (10h): a step that changed something is read; the note, if any, arrives as steering.
                if reply.toolCalls.contains(where: { (tier(of: $0.name, agent: agent) ?? .exec) > .read }) {
                    await advise(id, runID: runID, agent: agent, final: false)
                    guard isCurrent(runID, id) else { return }
                }
                if deliverSteering(id, runID: runID) { state.steered = true }
            }
        }
    }

    /// One model call: primary first, then the fallbacks; transient failures wait and retry on the same model
    /// (L3); a host that refuses the reasoning fields or the tools is asked once more without them.
    private func call(_ conversation: Conversation, runID: UUID, agent: AgentRecord, candidates: [ModelReference],
                      state: inout RunState) async -> Outcome {
        // A watched rule's reminder (10g) joins the history before the call goes again.
        var conversation = conversation
        let id = conversation.id
        let root = workRoot(for: conversation)
        var lastFailure = ChatFailure.empty
        var attempts = 0
        var notice: String?
        while state.model < candidates.count {
            guard isCurrent(runID, id) else { return .failed(ChatFailure.cancelled.message) }
            let reference = candidates[state.model]
            guard var target = await target(for: reference) else {
                lastFailure = .provider("「\(providers.entry(reference.providerID)?.name ?? reference.providerID)」没有配置 API Key")
                state.model += 1
                continue
            }
            // One session per conversation: the ChatGPT backend caches by it (omp's Codex wire, 2026-09-18).
            target.session = id.uuidString.lowercased()
            // Per model: a fallback may see images the primary can't, or the other way round (7j, V2).
            let history = ChatText.history(conversation.messages, as: conversation.isGroup ? agent.id : nil, root: root,
                                           seesImages: await seesImages(reference, in: conversation))
            let offered = state.sendsTools ? offeredTools(conversation, agent: agent) : []
            // 兼容模式 (7d, D8): the tools in the prompt, calls and results as text, nothing in `tools`.
            let textTools = !offered.isEmpty
                && (state.textTools || providers.usesTextTools(providerID: reference.providerID, modelID: reference.modelID))
            var system = systemPrompt(agent: agent, conversation: conversation, tools: offered)
            if textTools { system += "\n\n" + TextToolProtocol.prompt(offered) }
            // 推理强度按模型 (user 2026-09-18): the conversation's level brought onto this model's own ladder, the
            // levels its host refused before left out.
            let level = reasoningLevel(conversation.reasoning, for: target)
            guard let request = ChatWire.request(target, system: system, history: textTools ? TextToolProtocol.encode(history) : history,
                                                 reasoning: level, sendsReasoning: state.sendsReasoning,
                                                 tools: textTools ? [] : offered) else {
                lastFailure = .provider("「\(reference.providerID)」的 Base URL 无效")
                state.model += 1
                continue
            }
            // 10g: the project's watched rules — each once per conversation, a few stops a run at most.
            let fired = WatchRules.fired(in: conversation.messages)
            let rules = state.ruleBreaks < RunState.ruleBreakLimit
                ? (root.map { WatchRules.load(root: $0) } ?? []).filter { !fired.contains($0.name) } : []
            let fallback = state.model > 0 ? "主模型没有回复，这条由备用模型 \(reference.modelID) 回答" : nil
            drafts[id] = Draft(startedAt: .now, model: reference, agentID: agent.id, runID: runID, note: notice ?? state.note)
            do {
                let turn = try await stream(request, apiProtocol: target.endpoint.apiProtocol, conversationID: id, runID: runID,
                                            textTools: textTools, rules: rules)
                drafts[id] = nil
                state.searchTarget = WebTools.nativeSearchTarget(target)
                if let fallback, !state.fallbackNoted {
                    state.fallbackNoted = true
                    state.note = [state.note, fallback].compactMap { $0 }.joined(separator: "；")
                }
                return .turn(turn)
            } catch {
                // 10g: a watched rule broken — what it wrote goes, the rule goes in, the same model answers again.
                if let broken = error as? WatchRules.Broken, isCurrent(runID, id) {
                    drafts[id] = nil
                    state.ruleBreaks += 1
                    var reminder = Message(role: .user, agentID: agent.id, text: WatchRules.reminder(broken.rule), runID: runID,
                                           isHidden: true, marker: WatchRules.marker(broken.rule))
                    reminder.rule = broken.rule.name
                    conversations.append(reminder, to: id)
                    conversation = conversations.conversation(id) ?? conversation
                    continue
                }
                let failure = ChatFailure.from(error)
                guard isCurrent(runID, id), failure != .cancelled else { return .failed(ChatFailure.cancelled.message) }
                let arrived = drafts[id].map { !$0.text.isEmpty } ?? false
                // Too long for the window (E4): compact once and go again; if that can't be done, the next model.
                if failure.isContextOverflow, !arrived, !state.overflowCompacted {
                    state.overflowCompacted = true
                    drafts[id] = nil
                    if case .done = await compactContext(id, agent: agent, reason: .overflow, focus: nil) {
                        return isCurrent(runID, id) ? .compacted : .failed(ChatFailure.cancelled.message)
                    }
                    guard isCurrent(runID, id) else { return .failed(ChatFailure.cancelled.message) }
                }
                // The host refused the level (user 2026-09-18): remembered, so the menu stops listing it; the same model
                // is asked once more on the next level below, and after a second refusal without the fields — never
                // the fallback model for this.
                if state.sendsReasoning, failure.rejectsReasoning, !arrived {
                    if level != .auto {
                        providers.rememberRejectedReasoning(providerID: reference.providerID, modelID: reference.modelID, level: level)
                        state.refusedLevels.append(level)
                    }
                    let next = reasoningLevel(conversation.reasoning, for: target)
                    let refused = state.refusedLevels.map { "「\(label($0, for: target))」" }
                    if state.refusedLevels.count == 1, next != .auto, next != level {
                        state.note = "这个模型不接受推理强度\(refused[0])，这次改按「\(label(next, for: target))」，以后不再列它"
                    } else {
                        state.sendsReasoning = false
                        state.note = refused.isEmpty ? "这个模型不接受推理强度参数，这次按它的默认方式回答"
                            : "这个模型不接受推理强度\(refused.joined(separator: "和"))，这次按它的默认方式回答，以后不再列\(refused.count > 1 ? "它们" : "它")"
                    }
                    continue
                }
                // 自动: a model that refuses native tools gets them as text, and keeps them so (D8).
                if state.sendsTools, !textTools, failure.rejectsTools, !arrived, providers.toolMode(reference.providerID) == .auto {
                    state.textTools = true
                    providers.rememberTextTools(providerID: reference.providerID, modelID: reference.modelID)
                    state.note = "这个模型不支持原生工具调用，已改用兼容模式（用文字调用工具）"
                    continue
                }
                if state.sendsTools, failure.rejectsTools, !arrived {
                    state.sendsTools = false
                    state.note = "这个模型不支持工具调用，这次只能对话，不能查看或修改文件"
                    continue
                }
                // A transient failure — throttling, the host's own error, the network, a stream the host cut short (user
                // 2026-09-14: OpenRouter's upstream dropping the connection mid-reply) — waits and goes again on the same
                // model. What had arrived is dropped; the retry starts the reply over.
                if failure.isTransient, attempts < Self.retryLimit {
                    attempts += 1
                    notice = arrived ? "回复中途断了（\(failure.message)），正在第 \(attempts) 次重试"
                        : "服务商暂时不可用，正在第 \(attempts) 次重试（\(failure.message)）"
                    drafts[id]?.note = notice
                    waiting[id] = failure.isRateLimit ? "等待限流" : "等待重试"
                    try? await Task.sleep(for: retryDelay(attempts))
                    waiting[id] = nil
                    continue
                }
                if arrived, let draft = drafts.removeValue(forKey: id) {
                    return .interrupted(Turn(text: draft.text, thinking: draft.thinking, usage: draft.usage, model: draft.model,
                                             startedAt: draft.startedAt, thinkingSeconds: draft.thinkingSeconds), failure)
                }
                lastFailure = failure
                state.model += 1
                attempts = 0
                notice = nil
            }
        }
        drafts[id] = nil
        return .failed(lastFailure.message)
    }

    /// Reads one stream into the draft, publishing at most every `publishInterval`.
    /// In 兼容模式 the words go through the text protocol's scanner: calls come out of them, and a result the model
    /// writes itself ends the reading (D8).
    private func stream(_ request: URLRequest, apiProtocol: APIProtocol, conversationID id: UUID, runID: UUID,
                        textTools: Bool = false, rules: [WatchRules.Rule] = []) async throws -> Turn {
        var text = ""
        // 10g: the reply's words so far, watched against the rules.
        var said = ""
        var thinking = ""
        var turn = Turn(model: drafts[id]?.model ?? ModelReference(providerID: "", modelID: ""), startedAt: .now)
        var lastPublish = Date.distantPast
        var scanner: TextToolProtocol.Scanner? = textTools ? TextToolProtocol.Scanner() : nil
        do {
            reading: for try await event in client.stream(request, apiProtocol: apiProtocol) {
                guard isCurrent(runID, id) else { break }
                switch event {
                case .text(let piece):
                    if var reader = scanner {
                        let out = reader.feed(piece)
                        scanner = reader
                        text += out.text
                        turn.calls += out.calls
                        endThinking(id)
                        try watch(out.text, calls: out.calls, said: &said, rules: rules)
                        if out.fabricated { break reading }
                        break
                    }
                    text += piece
                    endThinking(id)
                    try watch(piece, calls: [], said: &said, rules: rules)
                case .thinking(let piece):
                    if drafts[id]?.thinkingStartedAt == nil { drafts[id]?.thinkingStartedAt = .now }
                    thinking += piece
                case .thinkingSignature(let piece):
                    turn.signature = (turn.signature ?? "") + piece
                case .toolCall(var call):
                    if call.id.isEmpty { call.id = "call_" + UUID().uuidString.prefix(8).lowercased() }
                    turn.calls.append(call)
                    endThinking(id)
                    try watch("", calls: [call], said: &said, rules: rules)
                case .stop(let stop):
                    turn.stop = stop
                case let .usage(input, output, cached, reasoning):
                    var usage = drafts[id]?.usage ?? TokenUsage()
                    if let input { usage.input = input }
                    if let output { usage.output = output }
                    if let cached { usage.cached = cached }
                    if let reasoning { usage.reasoning = reasoning }
                    drafts[id]?.usage = usage
                case .failed(let message):
                    throw ChatFailure.provider(message)
                }
                if Date.now.timeIntervalSince(lastPublish) >= publishInterval {
                    publish(id, runID: runID, text: &text, thinking: &thinking)
                    lastPublish = .now
                }
            }
        } catch {
            publish(id, runID: runID, text: &text, thinking: &thinking)
            throw error
        }
        if var reader = scanner {
            let out = reader.finish()
            text += out.text
            turn.calls += out.calls
            try watch(out.text, calls: out.calls, said: &said, rules: rules)
            if !turn.calls.isEmpty { turn.stop = .toolUse }
        }
        publish(id, runID: runID, text: &text, thinking: &thinking)
        // 10a: what came back has its placeholders swapped back before it is kept or run (Y1).
        turn.calls = SecretShield.shared.restore(turn.calls)
        guard let draft = drafts[id] else { return turn }
        turn.text = SecretShield.shared.restore(draft.text)
        turn.thinking = draft.thinking
        turn.usage = draft.usage
        turn.model = draft.model
        turn.startedAt = draft.startedAt
        turn.thinkingSeconds = draft.thinkingSeconds
        return turn
    }

    private func endThinking(_ id: UUID) {
        if drafts[id]?.thinkingStartedAt != nil, drafts[id]?.thinkingEndedAt == nil { drafts[id]?.thinkingEndedAt = .now }
    }

    /// 10g: the reply's words and calls against the project's watched rules — a match ends the reading here. The
    /// words are matched where they end, far enough back for an expression that spans pieces.
    private func watch(_ piece: String, calls: [ToolCall], said: inout String, rules: [WatchRules.Rule]) throws {
        guard !rules.isEmpty else { return }
        if !piece.isEmpty {
            said += piece
            if let rule = WatchRules.broken(text: String(said.suffix(piece.count + 500)), rules: rules) { throw WatchRules.Broken(rule: rule) }
        }
        for call in calls {
            if let rule = WatchRules.broken(call: call, rules: rules) { throw WatchRules.Broken(rule: rule) }
        }
    }

    private func publish(_ id: UUID, runID: UUID, text: inout String, thinking: inout String) {
        guard !text.isEmpty || !thinking.isEmpty else { return }
        if isCurrent(runID, id) {
            drafts[id]?.text += text
            // 10a: shown as it will be kept — a placeholder, once whole, is its value again.
            if let draft = drafts[id], draft.text.contains(SecretShield.marker) { draft.text = SecretShield.shared.restore(draft.text) }
            drafts[id]?.thinking += thinking
        }
        text = ""
        thinking = ""
    }

    /// The turn's calls, one after another (never at once: the second may depend on the first). Each result lands
    /// on the message as soon as it is in; a write that went through marks the task 已完成 (L8).
    private func execute(_ reply: Message, conversationID id: UUID, runID: UUID, agent: AgentRecord, state: inout RunState) async {
        // `ask` goes last: the turn's other calls run first, then it waits on the user (7d, D6).
        let asks = reply.toolCalls.filter { $0.name == AskTool.spec.name }
        let calls = reply.toolCalls.filter { $0.name != AskTool.spec.name } + asks
        var index = 0
        while index < calls.count {
            guard isCurrent(runID, id) else { return }
            let call = calls[index]
            index += 1
            if call.name == AskTool.spec.name {
                if let result = ask(call, conversationID: id, state: &state) {
                    conversations.setToolResult(result, call: call.id, message: reply.id, in: id)
                }
                continue
            }
            // Delegations side by side run at once (7g, S3): this one and those right after it.
            if call.name == TeamTools.delegateName {
                var batch = [call]
                while index < calls.count, calls[index].name == TeamTools.delegateName {
                    batch.append(calls[index])
                    index += 1
                }
                await delegate(batch, message: reply.id, conversationID: id, runID: runID, agent: agent, state: &state)
                continue
            }
            let signature = call.name + "\u{0}" + call.arguments
            state.repeats = signature == state.lastCall ? state.repeats + 1 : 1
            state.lastCall = signature
            let started = Date()
            var result = await perform(call, messageID: reply.id, conversationID: id, runID: runID, agent: agent, state: &state)
            AppLog.shared.write(result.status == .failed ? .warn : .info, "tool", "\(call.name) → \(result.status.rawValue) 对话=\(id.uuidString.prefix(8))" + (result.status == .failed ? " \(result.output.prefix(200))" : ""))
            result.seconds = Date().timeIntervalSince(started)
            guard isCurrent(runID, id) else { return }
            if result.status == .done {
                let post = await hook(.postToolUse, id, agent: agent, message: "「\(agent.displayName)」\(call.summary)，完成了") {
                    $0.toolName = call.name
                    $0.toolInput = call.arguments
                    $0.toolUseID = call.id
                    $0.toolResponse = result.output
                }
                guard isCurrent(runID, id) else { return }
                result.output += Self.feedback(post)
                state.note = Self.joined(state.note, post.notes)
                if let stop = post.stopRun { state.stopRequested = stop }
            }
            conversations.setToolResult(result, call: call.id, message: reply.id, in: id)
            if result.status == .done, let path = result.savedPath {
                conversations.setStatus(id, .done)
                state.written.append(path)
            }
        }
        if state.repeats >= Self.repeatLimit {
            state.repeats = 0
            nudge(id, runID: runID, "你已经连续 \(Self.repeatLimit) 次用同样的参数调用 \(reply.toolCalls.last?.name ?? "同一个工具")，结果不会变。换一个做法，或者直接告诉用户你卡在哪里。")
        }
    }

    /// What stands before a call (L5, H6): plan mode, a read-only subtask, the PreToolUse hooks — which can refuse it,
    /// let it through or ask for the user — then the Agent's 权限模式. A refusal is a result the model reads.
    enum Gate {
        case refused(ToolResult)
        /// Through, with what the hooks added.
        case cleared(HookOutcome)
    }

    func gate(_ call: ToolCall, messageID: UUID, conversationID id: UUID, runID: UUID, agent: AgentRecord,
              state: inout RunState) async -> Gate {
        let stopped = ToolResult(status: .stopped, output: "用户停止了，这一步没有执行。")
        let conversation = conversations.conversation(id)
        let tier = tier(of: call.name, agent: agent)
        // Plan mode (D5): tools above read aren't offered, but a text-protocol model may write one anyway.
        if conversation?.planMode == true, let tier, tier > .read, call.name != AgentTools.fetch.name {
            return .refused(ToolResult(status: .denied, output: "现在是计划模式：不能写文件、改文件或运行命令。把方案写出来，用户点「按这个计划做」之后才会关掉计划模式。"))
        }
        // A read-only subtask (7g, S1), the same way — reading a page aside: it only looks, and it asks (D70).
        if conversation?.parent?.readOnly == true, let tier, tier > .read, call.name != AgentTools.fetch.name {
            return .refused(ToolResult(status: .denied, output: "这个子任务只查不改：不能写文件、改文件或运行命令。把发现写进报告。"))
        }
        let pre = await hook(.preToolUse, id, agent: agent, message: "「\(agent.displayName)」要\(call.summary)") {
            $0.toolName = call.name
            $0.toolInput = call.arguments
            $0.toolUseID = call.id
        }
        guard isCurrent(runID, id) else { return .refused(stopped) }
        state.note = Self.joined(state.note, pre.notes)
        if let stop = pre.stopRun { state.stopRequested = stop }
        if let reason = pre.blocked ?? (pre.permission == .deny ? pre.permissionReason ?? "Hook 不允许这一步" : nil) {
            return .refused(ToolResult(status: .denied, output: "Hook 拦下了这一步：\(reason)"))
        }
        // Computer use (7j, C2): looking never asks; the first acting call of a run asks once, 全部放行 not at all.
        let isComputer = call.name == ComputerTool.name
        let aboveMode = isComputer
            ? ComputerTool.acts(call.arguments) && agent.approvalMode != .yolo && !state.computerAllowed
            : tier.map { agent.approvalMode.needsApproval($0) } ?? false
        // The seven kinds of dangerous command ask whatever a hook allowed (7c, C3) — except under 全部放行 (user 2026-09-15).
        let forced = AgentTools.forcedApproval(call, mode: agent.approvalMode)
        // 10b: what the user said to remember — for this conversation, or the project — needs no asking. A forced step
        // (a dangerous command, a new MCP server) and a hook's own ask always ask, and offer nothing to remember.
        let rememberable = forced == nil && pre.permission != .ask
        let remembered = rememberable && aboveMode && isGranted(call, conversationID: id)
        if !remembered, forced != nil || pre.permission == .ask || (aboveMode && pre.permission != .allow) {
            approvals[id] = Approval(messageID: messageID, callID: call.id, reason: forced,
                                     grant: rememberable ? ApprovalGrants.offer(for: call) : nil,
                                     preview: conversation.flatMap { workRoot(for: $0) }.flatMap { FileHistory.preview(call, root: $0) })
            explainRisk(id, call: call, agent: agent)
            let allowed = await withCheckedContinuation { decisions[id] = $0 }
            approvals[id] = nil
            guard allowed else {
                return .refused(ToolResult(status: .denied, output: "用户拒绝了这一步（\(call.summary)）。不要换个说法再做同样的事；换个做法，或者问用户想怎么做。"))
            }
            if isComputer { state.computerAllowed = true }
        }
        guard isCurrent(runID, id) else { return .refused(stopped) }
        return .cleared(pre)
    }

    /// J (9e): a step waiting for 允许 / 拒绝 gets one plain sentence from Bob on what it changes and risks. It only
    /// explains: the step waits for the user whatever he says, and when he says nothing the card is as before.
    private func explainRisk(_ id: UUID, call: ToolCall, agent: AgentRecord) {
        guard conductorModel() != nil else { return }
        let prompt = Conductor.riskRequest(agent: agent.displayName, summary: call.summary, name: call.name, arguments: call.arguments)
        Task { [weak self] in
            guard let self, let answer = await self.askBob(Conductor.riskSystem, prompt, in: id) else { return }
            let line = Conductor.riskLine(answer)
            guard !line.isEmpty, self.approvals[id]?.callID == call.id else { return }
            self.approvals[id]?.risk = line
        }
    }

    /// The call itself, once `gate` let it through. A refusal is a result the model reads.
    private func perform(_ call: ToolCall, messageID: UUID, conversationID id: UUID, runID: UUID, agent: AgentRecord,
                         state: inout RunState) async -> ToolResult {
        // 兼容模式 (D8): a call that wasn't valid JSON goes back with how to write it.
        if call.name == TextToolProtocol.malformedName {
            return .failed("这个 <tool_call> 不是合法的 JSON，或者缺了 name：\(call.arguments.prefix(300))\n照这个格式重写：<tool_call>{\"name\":\"工具名\",\"arguments\":{…}}</tool_call>")
        }
        let pre: HookOutcome
        switch await gate(call, messageID: messageID, conversationID: id, runID: runID, agent: agent, state: &state) {
        case .refused(let result): return result
        case .cleared(let outcome): pre = outcome
        }
        if call.name == PlanTool.spec.name {
            // Written from habit, or from an old turn of the history: there is no list to keep (user 2026-09-17).
            guard conversations.conversation(id).map(Self.keepsPlan) == true else {
                return .failed("现在没有开计划模式，也没有进行中的计划：不用列计划，直接做事。")
            }
            let outcome = PlanTool.apply(call.arguments, to: conversations.conversation(id)?.plan ?? [])
            if outcome.result.status == .done, outcome.plan != conversations.conversation(id)?.plan { state.touchedPlan = true }
            conversations.setPlan(outcome.plan, in: id)
            return outcome.result
        }
        // 7g: the hand-off and the goal's claim; the run ends after this turn (M2, A3).
        if call.name == TeamTools.handoff.name { return handOff(call, conversationID: id, agent: agent, state: &state) }
        if call.name == TeamTools.goalDone.name { return claimGoal(call, conversationID: id, state: &state) }
        if var result = await runAgentTool(call, conversationID: id, agent: agent) {
            result.output += Self.feedback(HookOutcome(context: pre.context))
            return result
        }
        if call.name == ComputerTool.name {
            var result = await operate(call, conversationID: id, runID: runID, state: &state)
            result.output += Self.feedback(HookOutcome(context: pre.context))
            return result
        }
        if ScriptTools.names.contains(call.name) {
            executing[id] = call.id
            defer { executing[id] = nil }
            var result = await ScriptTools.run(call, runner: scriptRunner)
            result.output += Self.feedback(HookOutcome(context: pre.context))
            return result
        }
        // 10f: kept running in the background — the conversation's job, no longer this call's.
        if call.name == AgentTools.bash.name, BackgroundJobs.wantsBackground(call.arguments) {
            executing[id] = call.id
            defer { executing[id] = nil }
            var result = await startJob(call, conversationID: id)
            result.output += Self.feedback(HookOutcome(context: pre.context))
            return result
        }
        executing[id] = call.id
        defer { executing[id] = nil }
        let root = conversations.conversation(id).flatMap { workRoot(for: $0) }
        // 子代理读文件给结构摘要（user 2026-09-16）：干净上下文里只要结论，省 token；主 Agent 仍读整篇。
        let summarizeReads = conversations.conversation(id)?.parent?.subagent != nil
        // A command steps aside for the user's message (user 2026-09-17) — one that waits already counts.
        var aside: Shell.Aside?
        if call.name == AgentTools.bash.name {
            let waiting = Shell.Aside(grace: asideGrace)
            if steering[id]?.contains(where: Self.isSpoken) == true { waiting.request() }
            asides[id] = waiting
            aside = waiting
        }
        defer { asides[id] = nil }
        var result = await AgentTools.run(call, root: root, search: state.searchTarget, readRoots: readRoots(agent),
                                          writeRoots: createdSkillFolders[id] ?? [], history: fileHistoryFolder,
                                          summarizeReads: summarizeReads, aside: aside)
        // It stepped aside: the conversation's background job from here on (10f).
        if let aside, aside.pid > 0, let root {
            let command = (ToolArguments.parse(call.arguments)?["command"] as? String) ?? ""
            let job = jobs.adopt(aside, command: command.trimmingCharacters(in: .whitespacesAndNewlines), in: id, cwd: root)
            result = .done(BashTool.asideNote(job: job, printed: result.output))
        }
        result.output += Self.feedback(HookOutcome(context: pre.context))
        return result
    }

    /// 10f: a bash call with `background`: started in the project folder, the conversation's from now on.
    private func startJob(_ call: ToolCall, conversationID id: UUID) async -> ToolResult {
        guard let command = (ToolArguments.parse(call.arguments)?["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !command.isEmpty else { return .failed("缺少参数 command") }
        guard let root = conversations.conversation(id).flatMap({ workRoot(for: $0) }) else {
            return .failed("项目文件夹现在打不开，不能运行命令。请用户在 Formora 里重新打开项目。")
        }
        return await jobs.start(command, in: id, cwd: root)
    }

    /// 10f: a background command ended while nobody looked — the Agent reads it before its next step, or with the
    /// conversation's next turn.
    private func jobEnded(_ note: String, in id: UUID) {
        guard conversations.conversation(id) != nil else { return }
        let message = Message(role: .user, text: note, isHidden: true)
        if isRunning(id) { steer(id, message) } else { conversations.append(message, to: id) }
    }

    /// A `computer` call (7j, C1): its actions against the Mac, in this conversation's session of refs and screenshots.
    /// The first one that acts raises the stop bar for the rest of the run (C3).
    private func operate(_ call: ToolCall, conversationID id: UUID, runID: UUID, state: inout RunState) async -> ToolResult {
        guard let desktop, ComputerBuild.isAvailable else { return .failed("这个版本不能操作电脑") }
        let actions: [ComputerAction]
        switch ComputerAction.parse(call.arguments) {
        case .failure(let problem): return .failed(problem.message)
        case .success(let parsed): actions = parsed
        }
        if actions.contains(where: { $0.kind.acts }), !state.operating {
            state.operating = true
            onOperating(id, true)
        }
        executing[id] = call.id
        defer { executing[id] = nil }
        let session = computerSessions[id] ?? ComputerSession()
        computerSessions[id] = session
        let folder = (screenshotFolder ?? FileManager.default.temporaryDirectory.appendingPathComponent("FormoraScreenshots", isDirectory: true))
            .appendingPathComponent(id.uuidString, isDirectory: true)
        return await session.run(actions, on: desktop, folder: folder) { !isCurrent(runID, id) }
    }

    /// Asks the hooks of a moment, telling them where and who (H1).
    func hook(_ event: HookEvent, _ id: UUID, agent: AgentRecord, message: String,
                      _ fill: (inout HookInput) -> Void = { _ in }) async -> HookOutcome {
        let conversation = conversations.conversation(id)
        let root = conversation.flatMap { workRoot(for: $0) }
        var input = HookInput(event: event, conversationID: id, title: conversation?.title ?? "", projectPath: root?.path,
                              projectName: conversation.flatMap { projectName($0.projectID) }, agentID: agent.id,
                              agentName: agent.displayName, agentRole: agent.roleID, permissionMode: agent.approvalMode.rawValue,
                              message: message)
        fill(&input)
        return await hooks(event, input, root)
    }

    /// What hooks tell the model about a tool call, after its result.
    private static func feedback(_ outcome: HookOutcome) -> String {
        var text = ""
        if let reason = outcome.blocked { text += "\n\nHook 的反馈：\(reason)" }
        for context in outcome.context { text += "\n\nHook 补充：\(context)" }
        return text
    }

    static func joined(_ note: String?, _ more: [String]) -> String? {
        let parts = ([note] + more.map(Optional.some)).compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "；")
    }

    /// A hook said `"continue": false` (H6): the run ends here, and its last turn says why.
    private func stopByHook(_ id: UUID, runID: UUID, reason: String) {
        guard isCurrent(runID, id) else { return }
        end(id)
        conversations.closeOpenCalls(in: id, ToolResult(status: .stopped, output: "Hook 让它停下了，这一步没有执行。"))
        if let last = conversations.conversation(id)?.messages.last(where: { $0.runID == runID && !$0.isHidden }) {
            conversations.setNote(Self.joined(last.note, ["Hook 让它停下：\(reason)"]) ?? "", message: last.id, in: id)
        }
        flushMemoryNotes(id)
        deliverSteering(id)
        if settleSubtask(id) { return }
        endAutorun(id, .interrupted("Hook 让它停下：\(reason)"))
        advance(id)
    }

    /// The loop's own words to the model: sent, never shown (L3).
    func nudge(_ id: UUID, runID: UUID, _ text: String) {
        conversations.append(Message(role: .user, text: text, runID: runID, isHidden: true), to: id)
    }

    /// × on the plan strip (user 2026-09-17): the open steps are dropped, and the model — whose history still holds the
    /// list — is told not to go on with them. Not under a run: 停止 comes first. `false` when nothing was closed.
    @discardableResult
    func closePlan(_ id: UUID) -> Bool {
        guard !isRunning(id), let plan = conversations.conversation(id)?.plan, plan.contains(where: \.isOpen) else { return false }
        conversations.setPlan(plan.map { item in
            var item = item
            if item.isOpen { item.status = .dropped }
            return item
        }, in: id)
        conversations.append(Message(role: .user, text: "用户关闭了这份计划：剩下没做的步骤不要再做，也不要再提。接下来按用户说的办。", isHidden: true), to: id)
        return true
    }

    /// The user's own words, as against what the program steers in: a background command's end, 旁审's note.
    nonisolated static func isSpoken(_ message: Message) -> Bool { message.role == .user && !message.isHidden && message.event == nil }

    /// What waited goes into the thread. Under a run that goes on (`runID`), the user's own message is led by the
    /// unseen 先处理 note (user 2026-09-17). `true` when the user's own words were among it.
    @discardableResult
    func deliverSteering(_ id: UUID, runID: UUID? = nil) -> Bool {
        guard let messages = steering.removeValue(forKey: id), !messages.isEmpty else { return false }
        let spoken = messages.contains(where: Self.isSpoken)
        // The user's words last, right under the note: they are what the model reads before it answers.
        for message in messages where !Self.isSpoken(message) { conversations.append(message, to: id) }
        if spoken, let runID { nudge(id, runID: runID, Self.steeringNote) }
        for message in messages where Self.isSpoken(message) { conversations.append(message, to: id) }
        return spoken
    }

    /// What a reply is signed as: the Agent's name, or the subagent's when the conversation is its run (user 2026-09-15).
    func speaker(_ agent: AgentRecord, in id: UUID) -> String {
        if let name = conversations.conversation(id)?.parent?.subagent { return "子代理「\(name)」" }
        return agent.displayName
    }

    private func message(_ turn: Turn, agent: AgentRecord, in id: UUID, runID: UUID, calls: [ToolCall]? = nil, note: String? = nil) -> Message {
        let thinking = turn.thinking.trimmingCharacters(in: .whitespacesAndNewlines)
        return Message(role: .agent, agentID: agent.id, speakerName: speaker(agent, in: id), text: ChatText.clean(turn.text),
                       thinking: thinking.isEmpty ? nil : thinking, thinkingSeconds: turn.thinkingSeconds, model: turn.model,
                       usage: turn.usage, durationSeconds: Date.now.timeIntervalSince(turn.startedAt), note: note,
                       toolCalls: calls ?? turn.calls, thinkingSignature: turn.signature, runID: runID)
    }

    /// The run is over: its last message lands (unread and announced where the user isn't looking), what the user
    /// sent meanwhile is kept, the task is named, the group's next member starts — first whoever it was handed to
    /// (7g, M2). A subtask's report goes back to its parent instead (S5). `nil`: the run ended on a turn already in
    /// the thread (a hand-off, a goal claimed).
    func finish(_ id: UUID, runID: UUID, _ message: Message?, handoff: Handoff? = nil) {
        guard isCurrent(runID, id) else { return }
        end(id)
        onFinished(id)
        if let failure = message?.failure {
            AppLog.error("run", "失败 对话=\(id.uuidString.prefix(8)) \(failure.prefix(300))")
        } else {
            let usage = message?.usage.map { "输入 \($0.input ?? 0) 输出 \($0.output ?? 0)" } ?? "无用量"
            AppLog.info("run", "结束 对话=\(id.uuidString.prefix(8)) 工具 \(message?.toolCalls.count ?? 0) 次 \(usage)")
        }
        let last = message ?? conversations.conversation(id)?.messages.last { $0.runID == runID && !$0.isHidden }
        if let message {
            announce(message, in: id)
        } else if let last {
            notifyUnseen(id, last)
        }
        flushMemoryNotes(id)
        let spoken = deliverSteering(id)
        // Whatever ends the run below, a message that arrived while it was ending is answered, not left in the
        // thread (user 2026-09-17) — a direct chat's; a group's `@`-ed members are in the queue already.
        defer { if spoken, message?.failure == nil, handoff == nil { reply(to: id) } }
        if last?.failure == nil, let model = last?.model { nameTask(id, with: model) }
        compactAfterRun(id, agentID: last?.agentID)
        if settleSubtask(id) { return }
        // E (9e): a failed reply — Bob gives the work to another member who can do it.
        if let failure = message?.failure, autoruns[id] == nil, let agent = agents.agent(last?.agentID),
           takeOver(id, from: agent, reason: failure) { return }
        if let failure = message?.failure { endAutorun(id, .interrupted("出错了：\(failure)")) }
        if let handoff, let from = agents.agent(last?.agentID) { relayOnward(id, from: from, handoff) }
        // C (9e): nobody handed on and nobody waits — Bob looks whether the user's request is done.
        if handoff == nil, message?.failure == nil, pending(id).isEmpty, reviewTurn(id, agentID: last?.agentID) { return }
        advance(id)
    }

    /// The pre-call gate or the deadline (L2): the run stops on its last message and asks 「继续？」.
    private func pause(_ id: UUID, runID: UUID, reason: String) {
        guard isCurrent(runID, id) else { return }
        end(id)
        queues[id] = nil
        flushMemoryNotes(id)
        deliverSteering(id)
        endRelay(id, .paused)
        endAutorun(id, .interrupted(reason))
        endConduct(id, .paused)
        // A lane has nobody to ask 「继续？」: it ends where it is, and its reply says so in the group (9e).
        if conversations.conversation(id)?.isLane == true { settleSubtask(id, .limit(reason)) }
        guard let last = conversations.conversation(id)?.messages.last(where: { $0.runID == runID && !$0.isHidden }) else { return }
        conversations.setPause(reason, message: last.id, in: id)
        notifyUnseen(id, last)
    }

    func end(_ id: UUID) {
        onOperating(id, false)
        waiting[id] = nil
        runs[id] = nil
        activeRuns[id] = nil
        drafts[id] = nil
        approvals[id] = nil
        executing[id] = nil
    }

    func announce(_ message: Message, in id: UUID) {
        conversations.append(message, to: id)
        notifyUnseen(id, message)
    }

    /// Unread and announced where the user isn't looking — not a subtask's: its parent's card says it (7g, S8).
    private func notifyUnseen(_ id: UUID, _ message: Message) {
        guard !isVisible(id), conversations.conversation(id)?.isSubtask == false else { return }
        conversations.incrementUnread(id)
        if let conversation = conversations.conversation(id) { onUnseenReply(conversation, message) }
    }

    private func systemPrompt(agent: AgentRecord, conversation: Conversation, tools: [ToolSpec]) -> String {
        // A lane works for its group (9e): the group's name and members — not a delegation's brief.
        let group = conversation.isLane ? conversations.conversation(conversation.parent?.conversationID) ?? conversation : conversation
        let members = group.isGroup ? ConversationReadiness.members(of: group, agents: agents).map(\.displayName) : []
        return SystemPrompt.build(role: agent.role, environment: SystemPrompt.Environment(
            projectName: projectName(conversation.projectID), userName: userName(),
            groupName: group.isGroup ? group.groupName : nil, groupMembers: members,
            canAsk: tools.contains { $0.name == AskTool.spec.name }, tools: tools.map(\.name), planMode: conversation.planMode,
            skills: tools.contains { $0.name == SkillTools.load.name }
                ? enabledSkills(agent).map { SystemPrompt.SkillLine(name: $0.name, description: $0.document.description) } : [],
            // Its directory only (user 2026-09-17) — without the notes not read or confirmed for half a year (10j).
            memory: memory?.directory(memoryScopes(conversation, agent: agent)),
            // A side conversation (10i) isn't a delegation: its boundary says what it is.
            subtask: conversation.isLane || conversation.isSide ? nil
                : conversation.parent.map { SystemPrompt.Subtask(requester: $0.requesterName, isCheck: $0.isCheck) },
            subagent: conversation.parent?.subagent.flatMap { subagents?.definition(named: $0) }
                .map { SystemPrompt.SubagentPrompt(name: $0.name, prompt: $0.prompt) },
            goal: autoruns[conversation.id]?.objective,
            // 10c: read at every request — an edit to AGENTS.md counts from the next call.
            projectInstructions: workRoot(for: conversation).map(ContextFiles.load) ?? []))
    }

    /// Once, after a reply, the model that answered names the task (7a, P4): the latest user message, reasoning
    /// off, one retry without the reasoning fields if the host refuses them. A manual name, a greeting or any
    /// failure leaves the name as it is.
    private func nameTask(_ id: UUID, with reference: ModelReference) {
        guard namesTasks, let conversation = conversations.conversation(id), conversation.titleIsAuto, !conversation.titleIsModelNamed,
              let last = conversation.messages.last(where: { $0.role == .user && !$0.isHidden && $0.event == nil }),
              let input = TaskTitle.input(from: last.text) else { return }
        let client = client
        let history = [ChatTurn(role: .user, text: input)]
        // 省事: a cheaper model names the task (user 2026-09-16); else Bob's (9e), else the one that answered.
        let model = contextAgent(conversation)?.model(for: .chore) ?? conductorModel() ?? reference
        Task { [weak self] in
            guard let target = await self?.target(for: model) else { return }
            func ask(sendsReasoning: Bool) async throws -> String {
                guard let request = ChatWire.request(target, system: TaskTitle.system, history: history, reasoning: .off,
                                                     sendsReasoning: sendsReasoning) else { return "" }
                var reply = ""
                for try await event in client.stream(request, apiProtocol: target.endpoint.apiProtocol) {
                    if case .text(let piece) = event { reply += piece }
                }
                return reply
            }
            var reply = ""
            do {
                reply = try await ask(sendsReasoning: true)
            } catch {
                guard ChatFailure.from(error).rejectsReasoning, let retried = try? await ask(sendsReasoning: false) else { return }
                reply = retried
            }
            guard let self, let title = TaskTitle.parse(SecretShield.shared.restore(reply)) else { return }
            self.conversations.setModelTitle(id, title)
        }
    }

    /// Whether this model gets the conversation's pictures (7j, V2). When nothing says yet, the provider's list —
    /// which may — is read first, once.
    private func seesImages(_ reference: ModelReference, in conversation: Conversation) async -> Bool {
        let hasPictures = conversation.messages.contains { message in
            message.attachments.contains { $0.kind == .image } || message.toolCalls.contains { !($0.result?.images ?? []).isEmpty }
        }
        guard hasPictures else { return false }
        if providers.modelInfo(reference.providerID, reference.modelID)?.acceptsImages == nil,
           providers.modelLists[reference.providerID] == nil {
            await providers.loadModels(reference.providerID)
        }
        return providers.seesImages(reference.providerID, reference.modelID)
    }

    /// A ChatGPT sign-in is refreshed here first when it is about to lapse (7i, U2).
    /// 推理强度按模型 (user 2026-09-18): the level a request to `target` carries — the conversation's, brought onto the
    /// model's own ladder, the levels its host refused before left out.
    private func reasoningLevel(_ level: ReasoningLevel, for target: ChatTarget) -> ReasoningLevel {
        let rejected = providers.rejectedReasoning(providerID: target.providerID, modelID: target.modelID)
        let options = ModelThinking.options(providerID: target.providerID, modelID: target.modelID, apiProtocol: target.endpoint.apiProtocol,
                                            baseURL: target.endpoint.baseURL, rejected: rejected)
        return ModelThinking.clamp(level, to: options.map(\.level))
    }

    /// The level's name on this model — 开启 where the host only has a switch.
    private func label(_ level: ReasoningLevel, for target: ChatTarget) -> String {
        ModelThinking.options(providerID: target.providerID, modelID: target.modelID, apiProtocol: target.endpoint.apiProtocol,
                              baseURL: target.endpoint.baseURL)
            .first { $0.level == level }?.label ?? level.label
    }

    private func target(for reference: ModelReference) async -> ChatTarget? {
        guard !reference.modelID.isEmpty, let authorization = await providers.authorization(reference.providerID),
              let endpoint = await providers.endpoint(for: reference.providerID, model: reference.modelID) else { return nil }
        return ChatTarget(providerID: reference.providerID, modelID: reference.modelID, endpoint: endpoint, key: authorization.key,
                          maxOutput: providers.modelInfo(reference.providerID, reference.modelID)?.maxOutput, headers: authorization.headers)
    }
}

// MARK: QA

extension ChatRunner {
    /// QA (9a, P1): a reply written into `id` as a model would, piece by piece — the streaming load without a model.
    func qaSimulateDraft(_ id: UUID, agent: UUID, thinking: [String], text: [String], every interval: Duration) async {
        let runID = UUID()
        activeRuns[id] = Run(id: runID, agentID: agent)
        drafts[id] = Draft(startedAt: .now, model: ModelReference(providerID: "qa", modelID: "qa"), agentID: agent, runID: runID)
        drafts[id]?.thinkingStartedAt = .now
        for piece in thinking {
            drafts[id]?.thinking += piece
            try? await Task.sleep(for: interval)
        }
        drafts[id]?.thinkingEndedAt = .now
        for piece in text {
            drafts[id]?.text += piece
            try? await Task.sleep(for: interval)
        }
        drafts[id] = nil
        activeRuns[id] = nil
    }
}
