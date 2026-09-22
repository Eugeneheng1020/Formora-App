import AppKit
import SwiftUI

/// The composer (spec §9.6, C12): a 14-radius card with the attachments, the text, and the tool row — left the
/// preparation (添加文件, reasoning), right only 发送 (停止 while a reply streams). Blocked with the same judgement
/// that stops sending, and the reason written under it. `/` at the start opens the commands, `@` the project files —
/// in a group the members first (7d, D1–D3; spec §9.8, §9.10). Docked above it: the plan, and every decision waiting
/// for the user (spec §5, §9.8b; `DecisionDock`).
struct ComposerView: View {
    let state: AppState
    let session: ProjectSession
    let conversation: Conversation
    let blockReason: String?
    /// On the canvas (8d, K13): the focused card it pushes on — the same composer, floating over the board.
    var boardCard: BoardCard? = nil
    /// The files pane's chat (user 2026-09-22): the path to send along as an `@` token, asked at send time; `nil` elsewhere.
    var carry: (() -> String?)? = nil

    @State private var height: CGFloat = 22
    @State private var isFocused = false
    /// The `/` or `@` right before the caret; `nil` = the popover is closed.
    @State private var token: ComposerToken?
    @State private var cursor = 0
    /// The project's files for the `@` list, read when it opens.
    @State private var projectFiles: [String] = []
    @State private var controller = ComposerController()

    private var id: UUID { conversation.id }
    private var draft: AppState.ComposerDraft { state.composerDrafts[id] ?? AppState.ComposerDraft() }
    private var isBlocked: Bool { blockReason != nil }
    private var onBoard: Bool { boardCard != nil }
    private var isRunning: Bool { state.chat.isRunning(id) }
    /// While the Agent works, sending is steering: it reads the message after the current step (7b, L4).
    private var canSend: Bool {
        !isBlocked && (!draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draft.attachments.isEmpty)
    }
    private var showsPopover: Bool { token != nil && !isBlocked }
    private var contextUsage: ContextBudget.Usage? { state.chat.contextUsage(id) }

    /// At 85% and over, no standing bar — one line suggesting /compact (old D25), unless a compaction is running.
    private var contextHint: String? {
        guard state.chat.compacting[id] == nil, let ratio = contextUsage?.ratio, ratio >= ContextBudget.hintRatio else { return nil }
        return "上下文已用约 \(Int((ratio * 100).rounded()))%（估算），建议输入 /compact 压缩"
    }

    /// Agents at work on their own (7g): a dispatcher choosing, a chain of hand-offs, an autorun — 停止 in reach.
    private var banner: (title: String, detail: String?)? {
        if let autorun = state.chat.autoruns[id] {
            if autorun.checkID != nil { return ("正在复核目标", "另一个 Agent 在对照目标查看项目现在的样子") }
            if autorun.bobChecks { return ("正在复核目标", "对照目标查看交付物") }
            if autorun.objective != nil {
                return ("目标模式 · 第 \(autorun.round) 轮（最多 \(autorun.rounds) 轮）",
                        "已用约 \(ContextBudget.format(state.chat.autorunTokens(id))) token，上限约 \(ContextBudget.format(TeamLimits.goalTokens))")
            }
            return ("自主运行 · 第 \(autorun.round)/\(autorun.rounds) 轮", nil)
        }
        if let relay = state.chat.relays[id], state.chat.isRunning(id) {
            return ("接力中 · 第 \(relay.hops)/\(TeamLimits.hops) 次", "\(relay.from) → \(relay.to)")
        }
        if let line = state.chat.conductLine(id) { return ("按安排进行", line) }
        if state.chat.reviewing.contains(id) { return ("正在安排下一步", nil) }
        if state.chat.dispatching.contains(id) { return ("正在分配", "按任务的性质找合适的成员") }
        return nil
    }

    private var projectRoot: URL? { session.current?.id == conversation.projectID ? session.accessibleRoot : nil }
    private var projectName: String? { session.projects.first { $0.id == conversation.projectID }?.name }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let banner {
                TeamBanner(title: banner.title, detail: banner.detail) { state.chat.stop(id) }
                    .padding(.bottom, 10)
            }
            if conversation.plan.contains(where: \.isOpen) {
                PlanStrip(plan: conversation.plan, close: isRunning ? nil : { closePlan() }).padding(.bottom, 10)
            }
            // 10f: commands still running in the background, each with 停止.
            let jobs = state.chat.jobs.running(in: id)
            if !jobs.isEmpty {
                BackgroundJobsStrip(jobs: jobs) { state.chat.jobs.stopByUser($0) }.padding(.bottom, 10)
            }
            // Every decision waits here (user 2026-09-15): 等你确认, a question, a reply's numbered ways, 方案出来了, 要继续吗,
            // 重试 — on the canvas for the focused card's run. A pick is sent as the user's words.
            DecisionDock(state: state, session: session, conversation: conversation, focus: boardCard.map { $0.subtaskID ?? id }) { text in
                state.composerDrafts[id, default: AppState.ComposerDraft()].text = text
                send()
            }
            VStack(alignment: .leading, spacing: 8) {
                if !draft.attachments.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(draft.attachments) { attachment in
                            AttachmentChip(attachment: attachment, projectRoot: session.accessibleRoot, onRemove: { remove(attachment) })
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("composer.attachments")
                }
                ComposerTextView(text: textBinding, height: $height, isFocused: $isFocused, isEditable: !isBlocked,
                                 placeholder: placeholder, identifier: "composer.input",
                                 onSubmit: send, onPasteImage: pasteImage, onPasteFiles: add, memberNames: memberNames,
                                 onToken: { token = $0 }, onMentionKey: handleKey, controller: controller,
                                 autofocus: !onBoard, history: { [conversation] in Self.sentTexts(conversation) }, onEscape: escape,
                                 listOpen: { showsPopover }, ghost: ghost, onTab: handleTab)
                    // `.composer-editor`: 22 min + 3 padding above and below, at most 160.
                    .frame(height: min(max(height, 28), 160))
                HStack(spacing: 6) {
                    IconActionButton(icon: Icons.paperclip, label: "添加附件", identifier: "composer.attach") { pickFiles() }
                    ReasoningPill(state: state, conversation: conversation)
                    if conversation.planMode {
                        PlanModePill { state.conversations.setPlanMode(false, in: id) }
                    }
                    Spacer(minLength: 10)
                    // 7e, E7: the context ring right before 发送 (user 2026-09-06); a click opens /cost.
                    if let usage = contextUsage, let cost = Commands.all.first(where: { $0.action == .cost }) {
                        ContextRing(usage: usage) { run(cost, argument: "") }
                    }
                    if isRunning {
                        StopButton { state.chat.stop(id) }
                    } else {
                        SendButton(isEnabled: canSend, action: send)
                    }
                }
                .disabled(isBlocked)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            // Over the canvas it floats (mockup `.canvas-composer .composer-box`): the surface and a soft shadow.
            // The box's shape casts the shadow on the canvas, not its text (9a): that was redrawn with every key.
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(onBoard ? Palette.surface.color : Palette.surfaceRaised.color)
                .shadow(color: .black.opacity(onBoard ? 0.75 : 0), radius: onBoard ? 12 : 0, y: onBoard ? 10 : 0))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isFocused && !isBlocked ? Palette.accent.color : onBoard ? Palette.lineStrong.color : Palette.line.color, lineWidth: 1))
            .opacity(isBlocked ? 0.55 : 1)
            // Dimmed, it still hides the cards behind it on the canvas.
            .background { if onBoard { RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.ground.color) } }
            // The list opens upward from the box (spec §9.8: the composer sits at the bottom).
            .overlay(alignment: .topLeading) {
                if showsPopover {
                    // A zero-height frame anchored at its bottom: the list grows upward from 8pt above the box.
                    ComposerPopover(state: state, sections: sections, cursor: cursor, emptyText: emptyText) { accept($0) }
                        .fixedSize()
                        .frame(height: 0, alignment: .bottomLeading)
                        .offset(y: -8)
                }
            }
            if let blockReason {
                Text(blockReason)
                    .font(FormoraFont.ui(11))
                    .foregroundStyle(Palette.inkFaint.color)
                    .padding(.horizontal, onBoard ? 8 : 0)
                    .padding(.vertical, onBoard ? 3 : 0)
                    .background { if onBoard { Capsule().fill(Palette.ground.color) } }
                    .padding(.top, 8)
                    .accessibilityIdentifier("composer.blockReason")
            } else if hasSuggestion {
                // 按 Tab 联想下一句 (user 2026-09-20): what the grey line is for — a note, not a warning.
                Text("按 Tab 采用这句，Esc 不要")
                    .font(FormoraFont.ui(11))
                    .foregroundStyle(Palette.inkFaint.color)
                    .padding(.top, 8)
                    .accessibilityIdentifier("composer.suggestHint")
            } else if let contextHint {
                Text(contextHint)
                    .font(FormoraFont.ui(11))
                    .foregroundStyle(Palette.alert.color)
                    .padding(.top, 8)
                    .accessibilityIdentifier("composer.contextHint")
            }
        }
        .padding(.top, onBoard ? 0 : 14)
        .padding(.horizontal, onBoard ? 0 : 22)
        .padding(.bottom, onBoard ? 0 : 18)
        .overlay(alignment: .top) { if !onBoard { Rectangle().fill(Palette.line.color).frame(height: 1) } }
        .onChange(of: token) { cursor = 0 }
        .onChange(of: token?.kind) {
            if token?.kind == .at { loadFiles() }
            // `/model`: the providers' real lists, read once — the 常用模型 stand in until they arrive.
            if token?.kind == .model {
                for entry in state.providers.entries where state.providers.hasKey(entry.id) {
                    Task { await state.providers.loadModels(entry.id) }
                }
            }
        }
    }

    /// Names who will read it; with a question waiting, writing is answering (spec §9.8b).
    private var placeholder: String {
        if isRunning { return "补充或纠正，它做完这一步就会看到…" }
        if state.chat.pendingQuestion(id) != nil { return "也可以直接在这里回答，发出去就算你的回答…" }
        // The mockup's words: the canvas pushes a card on, it never starts one (K13).
        if onBoard { return "补充或纠正…　@ 一个角色派给他，/ 指令" }
        return conversation.isGroup ? "@ 谁就交给谁，不 @ 就按任务自动分配…"
            : "给 \(ConversationReadiness.headline(of: conversation, agents: state.agents)) 发消息…　/ 指令，@ 引用文件"
    }

    /// What ↑ brings back (9b, Q3): the user's own words, oldest first — not the loop's, not the thread's lines.
    static func sentTexts(_ conversation: Conversation) -> [String] {
        conversation.messages.filter { $0.role == .user && !$0.isHidden && $0.event == nil && !$0.text.isEmpty }.map(\.text)
    }

    // MARK: 按 Tab 联想下一句 (user 2026-09-20)

    /// The grey line in an empty composer: what it suggests, or what it is doing. Only a suggestion can be taken.
    private var ghost: String {
        guard !isRunning, draft.text.isEmpty, draft.attachments.isEmpty else { return "" }
        if let line = state.chat.suggestions[id] { return line }
        if state.chat.suggesting.contains(id) { return "正在想你接下来会说什么…" }
        if state.chat.suggestFailures.contains(id) { return "这次没想到要补充的，直接说吧" }
        return ""
    }

    private var hasSuggestion: Bool { !isRunning && draft.text.isEmpty && state.chat.suggestions[id] != nil }

    /// Tab in an empty composer (user 2026-09-20): the first asks the conversation's own model what the user would
    /// say next, the second takes the whole line. With the 「/」 or 「@」 list open Tab is the list's, as before.
    private func handleTab() -> Bool {
        guard !isBlocked, !showsPopover, draft.text.isEmpty, draft.attachments.isEmpty else { return false }
        if let line = state.chat.suggestions[id] {
            state.composerDrafts[id, default: AppState.ComposerDraft()].text = line
            state.chat.clearSuggestion(id)
            return true
        }
        // Already asking: the key is swallowed, not asked twice.
        if !state.chat.suggesting.contains(id), state.chat.canSuggest(id) {
            state.chat.clearSuggestion(id)
            state.chat.suggestNext(id)
        }
        // Tab in an empty composer is this key and nothing else — never a tab character in the message.
        return true
    }

    /// Esc (9b, Q4): a line offered goes first, then a reply under way stops; otherwise the key is the text view's.
    private func escape() -> Bool {
        if ghost.isEmpty == false, !isRunning {
            state.chat.clearSuggestion(id)
            return true
        }
        guard isRunning else { return false }
        state.chat.stop(id)
        return true
    }

    private var textBinding: Binding<String> {
        Binding(get: { draft.text }, set: { typed in
            // Typed into: what was offered is no longer what the user is writing.
            if !typed.isEmpty { state.chat.clearSuggestion(id) }
            state.composerDrafts[id, default: AppState.ComposerDraft()].text = typed
        })
    }

    // MARK: Sending

    /// × on the plan strip (user 2026-09-17).
    private func closePlan() {
        guard state.chat.closePlan(id) else { return }
        state.toasts.show("已关闭计划", note: "剩下的步骤它不会再做", seconds: 3)
    }

    private func send() {
        guard canSend else { return }
        let text = draft.text
        // `/name …` typed in full runs as a command (D1); `/Users/…` and the like are words.
        switch Commands.parse(text, roles: state.commandRoles(conversation), subagents: state.subagents.names) {
        case .command(let command, let argument):
            state.composerDrafts[id, default: AppState.ComposerDraft()].text = ""
            token = nil
            run(command, argument: argument)
            return
        case .skill(let skillID, let argument):
            if let reason = state.runSkill(skillID, text: argument, in: id, projectRoot: projectRoot, projectName: projectName) {
                state.toasts.show("没有发送", note: reason, isError: true)
            } else {
                state.composerDrafts[id, default: AppState.ComposerDraft()].text = ""
                token = nil
            }
            return
        case .subagentRun(let name, let argument):
            // A subagent's name as a command (user 2026-09-15): its work, in its own subtask.
            state.composerDrafts[id, default: AppState.ComposerDraft()].text = ""
            token = nil
            Task {
                if let reason = await state.runSubagentCommand(name, task: argument, in: id) {
                    state.toasts.show("/\(name) 没有执行", note: reason, isError: true)
                }
            }
            return
        case .unknown(let reason):
            state.toasts.show("未知指令", note: reason, isError: true)
            return
        case .text:
            break
        }
        // The chosen file or folder rides along (user 2026-09-22) — on words, never on a command.
        let outgoing = FileChat.outgoingText(text, carry: carry?())
        var assignees: [UUID] = []
        if conversation.isGroup || onBoard {
            assignees = Mentions.assignees(in: text, members: members)
            // Typed by hand past the greyed list: checked again here (spec §9.10) — unless Bob can find a member of the
            // group a stand-in (9e, F).
            let standsIn = conversation.isGroup && state.chat.conductorModel() != nil
            for agentID in assignees where !(standsIn && conversation.members.contains { $0.agentID == agentID }) {
                guard let agent = state.agents.agent(agentID),
                      let reason = ConversationReadiness.assignmentReason(agent, in: conversation, currentProject: session.current,
                                                                          providers: state.providers) else { continue }
                state.toasts.show("无法分配给 \(agent.displayName)", note: reason, isError: true)
                return
            }
        }
        // UserPromptSubmit hooks see it first (7b′): they may keep it unsent — then the words come back — or add
        // background for the Agent. Sent while the Agent works, it waits as steering (L4).
        let kept = draft
        state.composerDrafts[id] = nil
        token = nil
        let root = projectRoot
        let projectName = projectName
        let trimmed = outgoing.trimmingCharacters(in: .whitespacesAndNewlines)
        let card = boardCard
        let current = session.current
        Task {
            // `@` files travel with the message as they are now (D3), read off the main actor.
            var mentions: [FileMention] = []
            if let root { mentions = await Task.detached { FileMentions.snapshot(trimmed, root: root) }.value }
            let reason: String?
            if let card {
                // On the canvas (8d, K13): 「聚焦谁」×「@ 了谁」 decides where it goes.
                reason = await state.boardSend(id, card: card, text: trimmed, attachments: kept.attachments, mentioned: assignees,
                                               mentions: mentions, projectRoot: root, projectName: projectName, currentProject: current)
            } else {
                reason = await state.submit(id, text: trimmed, attachments: kept.attachments, assignees: assignees,
                                            mentions: mentions, projectRoot: root, projectName: projectName)
            }
            guard let reason else { return }
            if state.composerDrafts[id] == nil { state.composerDrafts[id] = kept }
            state.toasts.show("没有发送", note: reason, isError: true)
        }
    }

    // MARK: `/` and `@`

    /// Who can be `@`-ed: a group's members; on the canvas any of the project's Agents, those in it first — the others
    /// join when `@`-ed (8d, K14).
    private var members: [AgentRecord] {
        let inside = conversation.isGroup ? ConversationReadiness.members(of: conversation, agents: state.agents)
            : state.agents.agent(conversation.agentID).map { [$0] } ?? []
        guard onBoard else { return conversation.isGroup ? inside : [] }
        return inside + state.agents.agents.filter { agent in !inside.contains { $0.id == agent.id } }
    }

    private var memberNames: [String] { members.flatMap { [$0.displayName, $0.customName] }.filter { !$0.isEmpty } }

    private var sections: [PopoverSection] {
        guard let token else { return [] }
        switch token.kind {
        case .slash:
            let commands = Commands.matching(token.query, roles: state.commandRoles(conversation))
            // The Agent's enabled Skills (7f, F1; spec §9.8: 「/ 的真正价值是把 Skills 唤起来」).
            let needle = FileSearch.normalize(token.query)
            let skills = state.commandSkills(conversation).filter {
                needle.isEmpty || FileSearch.normalize("skill:\($0.id) \($0.name)").contains(needle)
            }
            let subagents = state.subagents.definitions.filter { needle.isEmpty || FileSearch.normalize($0.name + " " + $0.description).contains(needle) }
            return [PopoverSection(title: "指令", items: commands.map { .command($0) }),
                    PopoverSection(title: "子代理", items: subagents.map { .subagent($0) }),
                    PopoverSection(title: "Skills", items: skills.map { .skill(id: $0.id, name: $0.name) })]
        case .model:
            // `/model` (user 2026-09-18): the models on offer, by provider, narrowed by what follows.
            return state.modelChoices(for: conversation, query: token.query).map { group in
                PopoverSection(title: group.title, items: group.items.map { .model($0) })
            }
        case .at:
            let needle = FileSearch.normalize(token.query)
            var result: [PopoverSection] = []
            if conversation.isGroup || onBoard {
                let picked = members
                    .filter { needle.isEmpty || FileSearch.normalize($0.displayName).contains(needle) || FileSearch.normalize($0.customName).contains(needle) }
                    .map { PopoverItem.member(MentionItem(agent: $0, reason: ConversationReadiness.assignmentReason(
                        $0, in: conversation, currentProject: session.current, providers: state.providers))) }
                result.append(PopoverSection(title: "角色", items: picked))
            }
            // Files whose name matches first, then those matching only by folder.
            let matching = projectFiles.filter { needle.isEmpty || FileSearch.normalize($0).contains(needle) }
            let named = matching.filter { needle.isEmpty || FileSearch.normalize(($0 as NSString).lastPathComponent).contains(needle) }
            let namedSet = Set(named)
            let files = (named + matching.filter { !namedSet.contains($0) }).prefix(40)
            result.append(PopoverSection(title: "项目文件", items: files.map { .file($0) }))
            return result
        }
    }

    /// 「还没有」 and 「没有匹配的」 are different things (spec §9.8).
    private var emptyText: String {
        guard let token else { return "" }
        let filtered = !token.query.isEmpty
        switch token.kind {
        case .slash:
            return filtered ? "没有匹配的指令" : "还没有指令"
        case .model:
            return filtered ? "没有匹配的模型" : "还没有可选的模型：先在「设置 → 模型」配一个"
        case .at:
            if conversation.isGroup || onBoard { return filtered ? "没有匹配的角色或文件" : "还没有角色或项目文件" }
            if session.accessibleRoot == nil { return "项目文件夹现在打不开" }
            return filtered ? "没有匹配的项目文件" : "还没有项目文件"
        }
    }

    /// ↑↓ move, Enter / Tab pick, Esc closes — only while the popover is open.
    private func handleKey(_ key: MentionKey) -> Bool {
        guard showsPopover else { return false }
        let items = sections.flatMap(\.items)
        switch key {
        case .up:
            if !items.isEmpty { cursor = (cursor - 1 + items.count) % items.count }
            return true
        case .down:
            if !items.isEmpty { cursor = (cursor + 1) % items.count }
            return true
        case .accept:
            // Nothing to pick: Enter sends what is typed.
            guard items.indices.contains(cursor) else {
                token = nil
                return false
            }
            accept(items[cursor])
            return true
        case .cancel:
            token = nil
            return true
        }
    }

    private func accept(_ item: PopoverItem) {
        switch item {
        case .command(let command):
            if command.takesArgument {
                controller.replaceToken(with: command.name + " ")
            } else {
                state.composerDrafts[id, default: AppState.ComposerDraft()].text = ""
                run(command, argument: "")
            }
        case .member(let member):
            guard member.reason == nil else { return }
            controller.replaceToken(with: "@\(member.agent.displayName) ")
        case .skill(let skillID, _):
            controller.replaceToken(with: "/skill:\(skillID) ")
        case .subagent(let definition):
            controller.replaceToken(with: definition.command + " ")
        case .file(let path):
            controller.replaceToken(with: FileMentions.token(for: path) + " ")
        case .model(let choice):
            // The line was `/model …`: it goes, the pick takes effect at once.
            state.composerDrafts[id, default: AppState.ComposerDraft()].text = ""
            if let reason = state.switchModel(choice.reference, in: conversation) {
                state.toasts.show("/model 没有执行", note: reason, isError: true)
            }
        }
        token = nil
    }

    private func run(_ command: ComposerCommand, argument: String) {
        let root = projectRoot
        let name = projectName
        let card = boardCard?.id
        Task {
            if let reason = await state.runCommand(command, argument: argument, in: id, projectRoot: root, projectName: name,
                                                   boardCard: card) {
                state.toasts.show("\(command.name) 没有执行", note: reason, isError: true)
            }
        }
    }

    private func loadFiles() {
        guard let root = session.accessibleRoot else {
            projectFiles = []
            return
        }
        Task {
            let files = await Task.detached { FileMentions.projectFiles(root: root) }.value
            projectFiles = files
        }
    }

    // MARK: Attachments

    private func remove(_ attachment: Attachment) {
        state.composerDrafts[id, default: AppState.ComposerDraft()].attachments.removeAll { $0.id == attachment.id }
    }

    private func pickFiles() {
        guard session.accessibleRoot != nil else {
            state.toasts.show("不能添加附件", note: "项目文件夹现在打不开", isError: true)
            return
        }
        let panel = NSOpenPanel()
        panel.title = "添加附件"
        panel.prompt = "添加"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    /// C13: outside files are copied into 附件/, project files are referenced.
    private func add(_ urls: [URL]) {
        guard let root = session.accessibleRoot else { return }
        for url in urls {
            do {
                let attachment = try ConversationStore.importAttachment(from: url, projectRoot: root)
                state.composerDrafts[id, default: AppState.ComposerDraft()].attachments.append(attachment)
            } catch {
                state.toasts.show("没有添加「\(url.lastPathComponent)」", note: error.localizedDescription, isError: true)
            }
        }
        Task { await state.files?.refresh() }
    }

    private func pasteImage(_ png: Data) {
        guard let root = session.accessibleRoot else {
            state.toasts.show("不能粘贴图片", note: "项目文件夹现在打不开", isError: true)
            return
        }
        do {
            let attachment = try ConversationStore.savePastedImage(png, projectRoot: root)
            state.composerDrafts[id, default: AppState.ComposerDraft()].attachments.append(attachment)
            Task { await state.files?.refresh() }
        } catch {
            state.toasts.show("没有粘贴图片", note: error.localizedDescription, isError: true)
        }
    }
}

struct MentionItem: Identifiable {
    let agent: AgentRecord
    /// Why it can't be picked — greyed, the reason in alert (mockup `.cmd-item.disabled`).
    let reason: String?

    var id: UUID { agent.id }
}

/// What the popover lists (spec §9.8): commands, members, project files — and, after `/model`, models.
enum PopoverItem: Identifiable {
    case command(ComposerCommand)
    case skill(id: String, name: String)
    /// A subagent's name as a command (user 2026-09-15).
    case subagent(SubagentDefinition)
    case member(MentionItem)
    case file(String)
    /// A model to switch to (user 2026-09-18).
    case model(ModelChoice)

    var id: String {
        switch self {
        case .command(let command): "command:" + command.name
        case .skill(let skillID, _): "skill:" + skillID
        case .subagent(let definition): "subagent:" + definition.name
        case .member(let member): "member:" + member.id.uuidString
        case .file(let path): "file:" + path
        case .model(let choice): "model:" + choice.id
        }
    }
}

struct PopoverSection {
    let title: String
    let items: [PopoverItem]
}

/// The one popover of `/` and `@` (spec §9.8; mockup `cmdPopoverItems`): grouped — 指令; 角色 then 项目文件 — the
/// highlighted row follows ↑↓, a long list scrolls.
private struct ComposerPopover: View {
    let state: AppState
    let sections: [PopoverSection]
    let cursor: Int
    let emptyText: String
    let pick: (PopoverItem) -> Void

    var body: some View {
        let flat = sections.flatMap(\.items)
        Group {
            if flat.count > 8 {
                ScrollViewReader { proxy in
                    ScrollView { content(flat) }
                        .frame(height: 320)
                        .onChange(of: cursor) { if flat.indices.contains(cursor) { proxy.scrollTo(flat[cursor].id) } }
                }
            } else {
                content(flat)
            }
        }
        .frame(width: 340, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.surfaceRaised.color))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.lineStrong.color, lineWidth: 1))
        .modalShadow()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mention.popover")
    }

    private func content(_ flat: [PopoverItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if flat.isEmpty {
                Text(emptyText)
                    .font(FormoraFont.ui(12))
                    .foregroundStyle(Palette.inkFaint.color)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .accessibilityIdentifier("popover.empty")
            }
            ForEach(sections.filter { !$0.items.isEmpty }, id: \.title) { section in
                Text(section.title)
                    .font(FormoraFont.ui(12.5, weight: 600))
                    .foregroundStyle(Palette.ink.color)
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                ForEach(section.items) { item in
                    row(item, isOn: flat.firstIndex { $0.id == item.id } == cursor).id(item.id)
                }
            }
        }
        .padding(6)
    }

    @ViewBuilder private func row(_ item: PopoverItem, isOn: Bool) -> some View {
        switch item {
        case .command(let command): CommandRow(command: command, isOn: isOn) { pick(item) }
        case .skill(let skillID, let name):
            CommandRow(command: ComposerCommand(name: "/skill:\(skillID)", note: name, takesArgument: true, action: .help), isOn: isOn) { pick(item) }
        case .subagent(let definition):
            CommandRow(command: ComposerCommand(name: definition.command, note: definition.description, takesArgument: true, action: .help), isOn: isOn) { pick(item) }
        case .member(let member): MentionRow(state: state, item: member, isOn: isOn) { pick(item) }
        case .file(let path): FileRow(path: path, isOn: isOn) { pick(item) }
        case .model(let choice): ModelRow(choice: choice, isOn: isOn) { pick(item) }
        }
    }
}

/// One model of the `/model` list (user 2026-09-18): its id, its name when the list has one, a check on the current.
private struct ModelRow: View {
    let choice: ModelChoice
    let isOn: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(choice.reference.modelID)
                    .font(FormoraFont.mono(12))
                    .foregroundStyle(choice.isCurrent ? Palette.accent.color : Palette.ink.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let name = choice.name, name != choice.reference.modelID {
                    Text(name)
                        .font(FormoraFont.ui(11.5))
                        .foregroundStyle(Palette.inkFaint.color)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if choice.isCurrent { IconView(Icons.check, size: 13).foregroundStyle(Palette.accent.color) }
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isOn || isHovering ? Palette.surfaceRaised2.color : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(choice.reference.modelID)
        // The button merges its children's identifiers: the check is read from the row's value.
        .accessibilityValue(choice.isCurrent ? "当前" : "")
        .accessibilityIdentifier("popover.model")
    }
}

private struct CommandRow: View {
    let command: ComposerCommand
    let isOn: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(command.name)
                    .font(FormoraFont.mono(12))
                    .foregroundStyle(Palette.ink.color)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(minWidth: 74, alignment: .leading)
                Text(command.note)
                    .font(FormoraFont.ui(11.5))
                    .foregroundStyle(Palette.inkFaint.color)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isOn || isHovering ? Palette.surfaceRaised2.color : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityIdentifier("popover.command.\(command.name.dropFirst())")
    }
}

private struct FileRow: View {
    let path: String
    let isOn: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                IconView(Icons.file, size: 13).foregroundStyle(Palette.accent.color)
                Text(path)
                    .font(FormoraFont.mono(11.5))
                    .foregroundStyle(Palette.ink.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isOn || isHovering ? Palette.surfaceRaised2.color : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityIdentifier("popover.file")
    }
}

private struct MentionRow: View {
    let state: AppState
    let item: MentionItem
    let isOn: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        let blocked = item.reason != nil
        Button(action: action) {
            HStack(spacing: 10) {
                AgentAvatar(image: state.agents.avatars[item.agent.id], initial: item.agent.role.initial, size: 26, isMuted: blocked)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.agent.displayName)
                        .font(FormoraFont.ui(12.5))
                        .foregroundStyle(Palette.ink.color)
                        .opacity(blocked ? 0.32 : 1)
                    Text(item.reason ?? item.agent.role.name)
                        .font(FormoraFont.ui(11))
                        .foregroundStyle(blocked ? Palette.alert.color : Palette.inkFaint.color)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill((isOn || isHovering) && !blocked ? Palette.surfaceRaised2.color : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(blocked)
        .onHover { isHovering = $0 }
        .accessibilityIdentifier("mention.\(item.agent.customName)")
    }
}

/// `.send-btn`: 34pt accent circle; faded when there is nothing to send.
private struct SendButton: View {
    let isEnabled: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            IconView(Icons.send, size: 15)
                .foregroundStyle(Palette.accentInk.color)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Palette.accent.color))
                .offset(y: isHovering && isEnabled ? -1 : 0)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .onHover { isHovering = $0 }
        .help("发送（回车）")
        .accessibilityLabel("发送")
        .accessibilityIdentifier("composer.send")
    }
}

/// `.reasoning-btn`: 30pt pill with the current level; its menu opens upward, drawn above everything by RootView.
private struct ReasoningPill: View {
    let state: AppState
    let conversation: Conversation

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    private var isOpen: Bool { state.reasoningMenuFor == conversation.id }

    var body: some View {
        let lit = isOpen || (isHovering && isEnabled)
        Button { state.reasoningMenuFor = isOpen ? nil : conversation.id } label: {
            HStack(spacing: 5) {
                IconView(Icons.bulb, size: 13)
                Text(state.reasoningLabel(conversation.id)).font(FormoraFont.ui(11.5))
            }
            .foregroundStyle(lit ? Palette.ink.color : Palette.inkMuted.color)
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(Capsule().fill(lit ? Palette.surfaceRaised2.color : .clear))
            .overlay(Capsule().strokeBorder(isOpen ? Palette.accent.color : Palette.lineStrong.color, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.32)
        .onHover { isHovering = $0 }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { report(proxy.frame(in: .global)) }
                    .onChange(of: proxy.frame(in: .global)) { _, frame in report(frame) }
            }
        }
        .accessibilityLabel("推理强度：\(state.reasoningLabel(conversation.id))")
        .accessibilityIdentifier("composer.reasoning")
    }

    private func report(_ frame: CGRect) {
        if state.reasoningButtonFrame != frame { state.reasoningButtonFrame = frame }
    }
}

/// `.reasoning-menu` (C14): the levels the conversation's model has (user 2026-09-18: omp's table, not all eight),
/// each with what it means; the one the stored level lands on checked.
struct ReasoningMenu: View {
    let state: AppState
    let conversationID: UUID

    var body: some View {
        let options = state.reasoningOptions(conversationID)
        let current = ModelThinking.clamp(state.conversations.conversation(conversationID)?.reasoning ?? .auto, to: options.map(\.level))
        VStack(alignment: .leading, spacing: 0) {
            Text("推理强度")
                .font(FormoraFont.ui(12.5, weight: 600))
                .foregroundStyle(Palette.ink.color)
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 4)
            ForEach(options, id: \.level) { option in
                ReasoningItem(option: option, isOn: option.level == current) { choose(option) }
            }
        }
        .padding(6)
        .frame(width: 230)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.surfaceRaised.color))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.lineStrong.color, lineWidth: 1))
        .modalShadow()
        .background {
            Button("") { state.reasoningMenuFor = nil }.keyboardShortcut(.cancelAction).opacity(0).accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reasoning.menu")
    }

    /// Takes effect at once and only here (spec §9.9); the toast says so.
    private func choose(_ option: ModelThinking.Option) {
        state.conversations.setReasoning(conversationID, option.level)
        state.reasoningMenuFor = nil
        state.toasts.show("推理强度：\(option.label)", note: "只影响这个对话", seconds: 2)
    }
}

private struct ReasoningItem: View {
    let option: ModelThinking.Option
    let isOn: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(FormoraFont.ui(12.5, weight: isOn ? 600 : 400))
                        .foregroundStyle(isOn ? Palette.accent.color : Palette.ink.color)
                    Text(option.note).font(FormoraFont.ui(11)).foregroundStyle(Palette.inkFaint.color)
                }
                Spacer(minLength: 0)
                IconView(Icons.check, size: 14).foregroundStyle(Palette.accent.color).opacity(isOn ? 1 : 0).frame(width: 14)
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isHovering ? Palette.surfaceRaised2.color : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier("reasoning.\(option.level.rawValue)")
    }
}

/// One key the `@` list takes while it is open.
enum MentionKey {
    case up, down, accept, cancel
}

/// What is being typed right before the caret: a `/command` at the very start, or an `@mention` anywhere — or the whole
/// line after `/model` (user 2026-09-18), which the model list filters by.
struct ComposerToken: Equatable {
    enum Kind: Equatable {
        case slash, at, model
    }

    let kind: Kind
    let query: String

    /// `nil` for anything else.
    static func from(_ text: String, at location: Int) -> ComposerToken? {
        if text.hasPrefix("@") { return ComposerToken(kind: .at, query: String(text.dropFirst())) }
        if text.hasPrefix("/"), location == 0 { return ComposerToken(kind: .slash, query: String(text.dropFirst())) }
        return nil
    }

    /// `/model` and whatever follows on that one line: the words the list is filtered by. Spaces don't end it — a model's
    /// name may be typed in pieces (`claude son`).
    static func model(in text: String) -> ComposerToken? {
        guard !text.contains("\n"), text.count >= 6, text.prefix(6).lowercased() == "/model" else { return nil }
        let rest = text.dropFirst(6)
        guard rest.isEmpty || rest.first?.isWhitespace == true else { return nil }
        return ComposerToken(kind: .model, query: rest.trimmingCharacters(in: .whitespaces))
    }
}

/// Lets the composer edit its own text at the caret — replacing a typed `/query` or `@query` with what was picked.
@MainActor
final class ComposerController {
    weak var textView: NSTextView?

    func replaceToken(with replacement: String) {
        guard let view = textView, let token = ComposerTextView.tokenBeforeCaret(in: view),
              ComposerToken.from(token.text, at: token.range.location) != nil else { return }
        view.insertText(replacement, replacementRange: token.range)
        view.window?.makeFirstResponder(view)
    }
}

/// The composer's text: a real `NSTextView`, because the SwiftUI fields can't do both of what the old app
/// needed (2026-09-06): Enter sends and Shift+Enter breaks the line, and the height follows the text.
/// Pasting is plain text; a pasted image or copied files become attachments (C13). It reports a `/query` at the start
/// or an `@query` right before the caret, hands ↑↓ / Enter / Esc to the popover while that is open, and colours `@`
/// mentions as they are typed — members in success, files in accent (7d).
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    @Binding var isFocused: Bool
    var isEditable: Bool
    var placeholder: String
    var identifier: String
    var onSubmit: () -> Void
    var onPasteImage: (Data) -> Void
    var onPasteFiles: ([URL]) -> Void
    /// A group's members, coloured as roles when `@`-ed.
    var memberNames: [String] = []
    var onToken: (ComposerToken?) -> Void = { _ in }
    var onMentionKey: (MentionKey) -> Bool = { _ in false }
    var controller: ComposerController?
    /// Takes the caret when it appears (9b, Q2) — not from another field being typed in, and not while the keyboard
    /// walks a list (an arrow there opens the next conversation, and the next arrow must still be the list's).
    var autofocus = false
    /// The user's own messages in this conversation, oldest first: ↑ in an empty composer brings them back (9b, Q3).
    var history: () -> [String] = { [] }
    /// Esc with no list open; `true` when it did something — a running reply stops (9b, Q4).
    var onEscape: () -> Bool = { false }
    /// The list over it (「/」, 「@」) is open: Return is the list's, even mid-composition.
    var listOpen: () -> Bool = { false }
    /// 按 Tab 联想下一句 (user 2026-09-20): the grey line in an empty composer, and what Tab does about it.
    var ghost: String = ""
    var onTab: () -> Bool = { false }
    /// Bob's smaller panel (D96) sets it lower.
    var fontSize: CGFloat = 13.5

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        // TextKit 1 with our own layout manager: it draws the `@` chips' rounded backgrounds (user 2026-09-14).
        let storage = NSTextStorage()
        let layout = ChipLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        let view = ComposerNSTextView(frame: .zero, textContainer: container)
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isHorizontallyResizable = false
        view.delegate = context.coordinator
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.font = FormoraFont.nsFont(.sora, size: fontSize, weight: 400)
        view.textColor = NSColor(Palette.ink.color)
        view.insertionPointColor = NSColor(Palette.accent.color)
        view.textContainerInset = NSSize(width: 0, height: 3)
        view.textContainer?.lineFragmentPadding = 2
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        view.defaultParagraphStyle = paragraph
        view.typingAttributes = [.font: view.font as Any, .foregroundColor: view.textColor as Any, .paragraphStyle: paragraph]
        view.setAccessibilityIdentifier(identifier)
        view.setAccessibilityLabel("消息输入")
        scroll.documentView = view
        controller?.textView = view
        if autofocus {
            let byKeyboard = NSApp.currentEvent?.type == .keyDown
            DispatchQueue.main.async { [weak view] in
                guard !byKeyboard, let view, let window = view.window else { return }
                // Another composer (the one just replaced) may hand it over; a search field being typed in keeps it.
                if let typing = window.firstResponder as? NSText, typing.window === window, !(typing is ComposerNSTextView) { return }
                window.makeFirstResponder(view)
            }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? ComposerNSTextView else { return }
        controller?.textView = view
        // Mid-composition the view holds the input method's letters, which the binding hasn't seen: writing it back
        // wiped them and left the input method out of step — Return then went nowhere (user 2026-09-14).
        if view.string != text, !view.hasMarkedText() {
            view.string = text
            view.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            context.coordinator.measure(view)
            context.coordinator.reportToken(view)
            context.coordinator.highlight(view)
        }
        view.isEditable = isEditable
        view.isSelectable = isEditable
        view.placeholder = placeholder
        view.ghost = ghost
        view.onPasteImage = onPasteImage
        view.onPasteFiles = onPasteFiles
        view.listOpen = listOpen
        view.onFocus = { focused in DispatchQueue.main.async { context.coordinator.parent.isFocused = focused } }
        view.needsDisplay = true
    }

    /// The run of non-space characters right before the caret (an `@query` when it starts with `@`).
    static func tokenBeforeCaret(in view: NSTextView) -> (text: String, range: NSRange)? {
        let selection = view.selectedRange()
        guard selection.length == 0 else { return nil }
        let string = view.string as NSString
        let caret = min(selection.location, string.length)
        var start = caret
        while start > 0 {
            let character = string.substring(with: NSRange(location: start - 1, length: 1))
            if character.rangeOfCharacter(from: .whitespacesAndNewlines) != nil { break }
            start -= 1
        }
        guard start < caret else { return nil }
        let range = NSRange(location: start, length: caret - start)
        return (string.substring(with: range), range)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        var recalled = ComposerHistory()

        init(_ parent: ComposerTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            // Typed over: ↑ and ↓ move the caret again.
            recalled.reset()
            parent.text = view.string
            measure(view)
            reportToken(view)
            highlight(view)
            view.needsDisplay = true
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            reportToken(view)
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            // The input method is still composing: its keys are its own.
            if textView.hasMarkedText() { return false }
            let key: MentionKey? = switch selector {
            case #selector(NSResponder.moveUp(_:)): .up
            case #selector(NSResponder.moveDown(_:)): .down
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)): .accept
            case #selector(NSResponder.cancelOperation(_:)): .cancel
            default: nil
            }
            if let key, parent.onMentionKey(key) { return true }
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                return recall(textView, older: true)
            case #selector(NSResponder.moveDown(_:)):
                return recall(textView, older: false)
            case #selector(NSResponder.insertTab(_:)):
                // No list open: Tab is the composer's own (user 2026-09-20). It never inserts a tab character here.
                return parent.onTab()
            case #selector(NSResponder.cancelOperation(_:)):
                return parent.onEscape()
            case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            case #selector(NSResponder.insertNewline(_:)):
                // Shift or Option with Enter breaks the line (9b, Q4); Enter alone sends.
                let flags = NSApp.currentEvent?.modifierFlags ?? []
                if flags.contains(.shift) || flags.contains(.option) {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                } else {
                    parent.onSubmit()
                }
                return true
            default:
                return false
            }
        }

        /// ↑ / ↓ through the user's own messages (9b, Q3); `false` leaves the key to move the caret.
        private func recall(_ view: NSTextView, older: Bool) -> Bool {
            let history = parent.history()
            guard let text = older ? recalled.older(current: view.string, history: history)
                                   : recalled.newer(current: view.string, history: history) else { return false }
            view.string = text
            view.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            parent.text = text
            measure(view)
            reportToken(view)
            highlight(view)
            view.needsDisplay = true
            return true
        }

        func reportToken(_ view: NSTextView) {
            let token = ComposerToken.model(in: view.string)
                ?? ComposerTextView.tokenBeforeCaret(in: view).flatMap { ComposerToken.from($0.text, at: $0.range.location) }
            DispatchQueue.main.async { self.parent.onToken(token) }
        }

        /// `@` mentions in colour while typing — a display attribute only, the text stays plain.
        func highlight(_ view: NSTextView) {
            guard let layout = view.layoutManager, let pattern = Self.mentionPattern else { return }
            let string = view.string as NSString
            let whole = NSRange(location: 0, length: string.length)
            layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: whole)
            layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: whole)
            for match in pattern.matches(in: view.string, range: whole) {
                let word = string.substring(with: match.range).dropFirst()
                let isMember = parent.memberNames.contains { word.hasPrefix($0) }
                layout.addTemporaryAttribute(.foregroundColor, value: NSColor(isMember ? Palette.success.color : Palette.accent.color),
                                             forCharacterRange: match.range)
                // The chip (user 2026-09-14): a soft block behind the mention, rounded by `ChipLayoutManager`.
                layout.addTemporaryAttribute(.backgroundColor, value: NSColor(isMember ? Palette.successSoft.color : Palette.accentSoft.color),
                                             forCharacterRange: match.range)
            }
        }

        private static let mentionPattern = try? NSRegularExpression(pattern: FileMentions.pattern)

        func measure(_ view: NSTextView) {
            guard let layout = view.layoutManager, let container = view.textContainer else { return }
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container).height + view.textContainerInset.height * 2
            let next = max(22, ceil(used))
            if abs(parent.height - next) > 0.5 { DispatchQueue.main.async { self.parent.height = next } }
        }
    }
}

/// Draws the placeholder (there is no native one) and turns pasted images and files into attachments.
final class ComposerNSTextView: NSTextView {
    var placeholder = ""
    /// 按 Tab 联想下一句 (user 2026-09-20): drawn in the empty composer in place of the placeholder, and it wraps —
    /// a suggested line is a sentence, not a label.
    var ghost = ""
    var onPasteImage: ((Data) -> Void)?
    var onPasteFiles: (([URL]) -> Void)?
    var onFocus: ((Bool) -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let text = ghost.isEmpty ? placeholder : ghost
        guard string.isEmpty, !text.isEmpty else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        paragraph.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 13.5),
            .foregroundColor: NSColor(ghost.isEmpty ? Palette.inkFaint.color : Palette.inkMuted.color),
            .paragraphStyle: paragraph,
        ]
        let inset = textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0)
        let width = max(0, bounds.width - inset * 2)
        let box = NSRect(x: inset, y: textContainerInset.height, width: width, height: bounds.height - textContainerInset.height)
        (text as NSString).draw(in: box, withAttributes: attributes)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?(true) }
        return accepted
    }

    /// The list over the composer (「/」, 「@」) is open.
    var listOpen: (() -> Bool)?

    /// With the list open, Return picks its highlighted row even while an input method is still composing — Pinyin's
    /// letters after 「/」 — which would take the key to commit them (user 2026-09-14): they are committed as typed,
    /// the list filters on them, and Return goes on to the list.
    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn, hasMarkedText(), listOpen?() == true {
            unmarkText()
            inputContext?.discardMarkedText()
            didChangeText()
            // After the token those letters make has reached the list.
            DispatchQueue.main.async { [weak self] in self?.doCommand(by: #selector(NSResponder.insertNewline(_:))) }
            return
        }
        super.keyDown(with: event)
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onFocus?(false) }
        return accepted
    }

    /// A plain-text view turns 粘贴 off when the pasteboard holds only a picture (a screenshot), so ⌘V would never
    /// reach `paste` below.
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)), isEditable, onPasteImage != nil, NSImage.canInit(with: .general) { return true }
        return super.validateUserInterfaceItem(item)
    }

    override func paste(_ sender: Any?) {
        let board = NSPasteboard.general
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            onPasteFiles?(urls)
            return
        }
        if board.string(forType: .string) == nil, let image = NSImage(pasteboard: board),
           let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            onPasteImage?(png)
            return
        }
        // Only plain text: no styles or embedded images come in with it (spec §9.6 pit 1).
        pasteAsPlainText(sender)
    }
}

/// Draws a mention's background as a rounded chip instead of a bare rectangle (user 2026-09-14: 「@ 选中后用色块包裹」).
final class ChipLayoutManager: NSLayoutManager {
    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count rectCount: Int, forCharacterRange charRange: NSRange,
                                          color: NSColor) {
        color.setFill()
        for index in 0..<rectCount {
            let rect = rectArray[index].insetBy(dx: -2, dy: 1)
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        }
    }
}
