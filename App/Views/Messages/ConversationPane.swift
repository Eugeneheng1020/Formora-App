import AppKit
import SwiftUI

/// 消息's detail column: the selected conversation of the current project and view, else the first one;
/// with none at all, the empty page (C20).
struct ConversationPane: View {
    let state: AppState
    let session: ProjectSession

    var body: some View {
        let list = state.conversations.list(project: session.current?.id, hiddenView: state.showsHiddenConversations)
        // A subtask isn't in the list: it opens from its parent's card (7g, S8).
        let subtask = state.conversations.conversation(state.selectedConversationID)
            .flatMap { $0.isSubtask && $0.projectID == session.current?.id ? $0 : nil }
        let current = subtask ?? list.first { $0.id == state.selectedConversationID } ?? list.first
        Group {
            if let current {
                ConversationView(state: state, session: session, conversation: current).id(current.id)
            } else if state.showsHiddenConversations {
                Text("没有已隐藏的会话")
                    .font(FormoraFont.ui(13))
                    .foregroundStyle(Palette.inkFaint.color)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                MessagesEmptyState()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.ground.color)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail.messages")
    }
}

private struct ConversationView: View {
    let state: AppState
    let session: ProjectSession
    let conversation: Conversation

    /// A subtask takes steering while its helper works; afterwards its report is back in the parent (7g, S8).
    static func subtaskReason(_ link: SubtaskLink) -> String {
        if link.lane == true { return "这是群聊「\(link.requesterName)」里同时进行的一部分，已经结束，回复发回了群聊" }
        return link.isCheck ? "这是一次目标复核，已经结束，结论写回了原对话" : "这是「\(link.requesterName)」委派的子任务，已经结束，报告交回了原对话"
    }

    var body: some View {
        let reason: String? = if let link = conversation.parent {
            // A side conversation (10i) is the user's own to ask in.
            link.side == true || state.chat.isRunning(conversation.id) ? nil : Self.subtaskReason(link)
        } else {
            ConversationReadiness.blockReason(of: conversation, agents: state.agents, currentProject: session.current,
                                              providers: state.providers)
        }
        VStack(spacing: 0) {
            ConversationHeader(state: state, conversation: conversation)
            if conversation.isSide { SideBanner { state.closeSide(conversation.id) } }
            ThreadView(state: state, session: session, conversation: conversation)
            ComposerView(state: state, session: session, conversation: conversation, blockReason: reason)
        }
        .onAppear {
            state.displayedConversationID = conversation.id
            state.conversations.markRead(conversation.id)
        }
        .onDisappear {
            if state.displayedConversationID == conversation.id { state.displayedConversationID = nil }
            // Left for another conversation: a side conversation goes (10i).
            if conversation.isSide, state.selectedConversationID != conversation.id { state.closeSide(conversation.id, returning: false) }
        }
        .onChange(of: conversation.unread) {
            if conversation.unread > 0, NSApplication.shared.isActive { state.conversations.markRead(conversation.id) }
        }
    }
}

/// `.chat-header` (spec §9.3): avatar, the task name and ✎ right after it — nothing else.
private struct ConversationHeader: View {
    let state: AppState
    let conversation: Conversation

    @State private var isRenaming = false
    @State private var draft = ""
    @State private var problem: String?

    var body: some View {
        HStack(spacing: 10) {
            // A side conversation's way back is its banner's 回到主对话, which throws it away (10i).
            if let link = conversation.parent, !conversation.isSide {
                SubtaskBackButton(state: state, link: link)
            }
            ConversationAvatar(state: state, conversation: conversation, size: 34)
            if isRenaming {
                VStack(alignment: .leading, spacing: 5) {
                    InputField(placeholder: "任务名称", text: $draft, height: 32, isInvalid: problem != nil,
                               identifier: "conversation.title.input", onCommit: commit)
                    Text(problem ?? note)
                        .font(FormoraFont.ui(11))
                        .foregroundStyle(problem == nil ? Palette.inkFaint.color : Palette.alert.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                IconActionButton(icon: Icons.check, label: "保存任务名", identifier: "conversation.title.save", action: commit)
                IconActionButton(icon: Icons.close, label: "取消重命名", identifier: "conversation.title.cancel") { isRenaming = false }
            } else {
                Text(conversation.title)
                    .font(FormoraFont.ui(14.5, weight: 600))
                    .foregroundStyle(Palette.ink.color)
                    .lineLimit(1)
                    .accessibilityIdentifier("conversation.title")
                // Nothing to rename in a side conversation: it is gone when the user goes back (Codex: same).
                if !conversation.isSide {
                    IconActionButton(icon: Icons.pencil, label: "重命名任务", identifier: "conversation.rename") {
                        draft = conversation.title
                        problem = nil
                        isRenaming = true
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 24)
        .frame(minHeight: 62)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line.color).frame(height: 1) }
        .onExitCommand { isRenaming = false }
        .onChange(of: draft) { problem = nil }
    }

    private var note: String {
        (conversation.isGroup ? "改的是这个群当前的任务名，不是群聊名称。" : "")
            + "任务名在第一条消息后自动生成（目前取第一句话），手动修改后不再自动更新。"
    }

    private func commit() {
        do {
            try state.conversations.rename(conversation.id, to: draft)
            isRenaming = false
            state.toasts.show("任务名已更新", seconds: 2)
        } catch {
            problem = (error as? ConversationProblem)?.message ?? error.localizedDescription
        }
    }
}

/// A user message, or an Agent's run: its turns share one frame (7b, L8; old D37).
private struct ThreadItem: Identifiable {
    let messages: [Message]

    var id: UUID { messages[0].id }
    /// A self-review's marker belongs to the Agent's frame, not to the user's side (7d, D7).
    var isUser: Bool { messages[0].role == .user && messages[0].marker == nil }
    var runID: UUID? { messages.last?.runID }

    static func group(_ messages: [Message]) -> [ThreadItem] {
        var items: [ThreadItem] = []
        for message in messages {
            let joinsRun = message.role == .agent || message.marker != nil
            if joinsRun, let last = items.last, !last.isUser, let run = message.runID, last.runID == run,
               last.messages.last?.agentID == message.agentID {
                items[items.count - 1] = ThreadItem(messages: last.messages + [message])
            } else {
                items.append(ThreadItem(messages: [message]))
            }
        }
        return items
    }
}

/// `.thread`: messages bottom-anchored (opening shows the latest); a search hit scrolls to its message and
/// flashes it (C15). The loop's own nudges are never shown (7b, L3).
private struct ThreadView: View {
    let state: AppState
    let session: ProjectSession
    let conversation: Conversation

    @State private var flashing: UUID?
    /// 展开原文 on the compaction divider (7e, E5).
    @State private var showsFolded = false
    /// Earlier versions opened under their lines (10e).
    @State private var openVersions: Set<UUID> = []

    static let draftAnchor = "draft"
    static let cardAnchor = "commandCard"
    static let planAnchor = "planApproval"
    static let dividerAnchor = "compactDivider"

    private var id: UUID { conversation.id }
    /// Not the loop's own words — except a self-review's marker line (7d, D7).
    private var visible: [Message] { conversation.messages.filter { !$0.isHidden || $0.marker != nil } }

    /// A plan-mode run ended on its answer (D5): the way from the plan to the work sits under it.
    private var showsPlanApproval: Bool {
        guard conversation.planMode, !state.chat.isRunning(id), state.chat.pendingQuestion(id) == nil,
              let last = conversation.messages.last(where: { !$0.isHidden }) else { return false }
        return last.role == .agent && last.failure == nil && last.pause == nil
    }

    var body: some View {
        let visible = visible
        let fold = Self.fold(visible, in: conversation)
        let items = ThreadItem.group(fold.kept)
        let draft = state.chat.drafts[id]
        let draftInFrame = draft != nil && items.last.map { !$0.isUser && $0.runID == draft?.runID } == true
        ScrollViewReader { proxy in
            ScrollView {
                if visible.isEmpty, draft == nil, state.commandCards[id] == nil {
                    Text(emptyText)
                        .font(FormoraFont.ui(13))
                        .foregroundStyle(Palette.inkFaint.color)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                        .accessibilityIdentifier("conversation.empty")
                } else {
                    // Lazy (9a): a long thread draws what is on screen, not all of it on opening.
                    LazyVStack(spacing: 16) {
                        // Before the latest compaction's boundary: folded behind the divider, kept (7e, E5).
                        if showsFolded {
                            ForEach(ThreadItem.group(fold.folded)) { item in
                                itemRow(item, isLast: false, draft: nil, lastID: visible.last?.id)
                            }
                        }
                        if let record = fold.record {
                            CompactDivider(record: record, foldedCount: fold.folded.count, isExpanded: showsFolded,
                                           showsSummaryInitially: state.revealsCompaction) { showsFolded.toggle() }
                                .id(Self.dividerAnchor)
                        }
                        ForEach(items) { item in
                            itemRow(item, isLast: item.id == items.last?.id, draft: draftInFrame && item.id == items.last?.id ? draft : nil,
                                    lastID: visible.last?.id, follow: { proxy.scrollTo(Self.draftAnchor, anchor: .bottom) })
                        }
                        if let draft, !draftInFrame {
                            DraftRow(state: state, conversation: conversation, draft: draft,
                                     follow: { proxy.scrollTo(Self.draftAnchor, anchor: .bottom) })
                                .id(Self.draftAnchor)
                        }
                        // Sent while the Agent works: it reads them after the current step (L4).
                        ForEach((state.chat.steering[id] ?? []).filter { !$0.isHidden }) { message in
                            MessageRow(state: state, session: session, conversation: conversation, message: message,
                                       isFlashing: false, isQueued: true)
                                .id(message.id)
                        }
                        if let reason = state.chat.compacting[id] {
                            CompactingRow(reason: reason)
                        }
                        // A command's output (D2): one-off, under everything.
                        if let card = state.commandCards[id] {
                            CommandCardView(card: card, close: { state.commandCards[id] = nil }) {
                                switch card.body {
                                case .usage:
                                    UsageSummary(report: UsageReport(conversation, subtasks: state.conversations.subtasks(of: conversation.id))) { model in
                                        "\(state.providers.entry(model.providerID)?.name ?? model.providerID) · \(model.modelID)"
                                    }
                                case .memory:
                                    MemorySummary(text: state.commandAgent(conversation).flatMap {
                                        state.chat.memory?.text(agent: $0.id, project: conversation.projectID)
                                    })
                                default:
                                    PlanList(items: conversation.plan)
                                }
                            }
                            .id(Self.cardAnchor)
                        }
                    }
                    .padding(.vertical, 22)
                    .padding(.horizontal, 26)
                }
            }
            // Short threads start at the top like the mockup; opening scrolls to the latest message.
            .onAppear {
                if state.messageJump?.conversationID == id {
                    jump(proxy)
                } else if let last = visible.last {
                    // Twice (user 2026-09-14: 「重新打开必须是最新的内容」): the lazy rows above get their real heights only once
                    // laid out, and the first jump can land short of the latest message.
                    Task { proxy.scrollTo(last.id, anchor: .bottom) }
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(250))
                        proxy.scrollTo(visible.last?.id ?? last.id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: state.messageJump) { jump(proxy) }
            .onChange(of: visible.count) { toBottom(proxy) }
            .onChange(of: state.chat.steering[id]?.count) { toBottom(proxy) }
            .onChange(of: state.chat.approvals[id]) { toBottom(proxy) }
            // QA (-FormoraRevealCompaction): a new compaction's divider comes into view.
            .onChange(of: conversation.messages.last(where: { $0.compaction != nil })?.id) { _, landed in
                guard landed != nil, state.revealsCompaction else { return }
                Task { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.dividerAnchor, anchor: .top) } }
            }
            // The way from the plan to the work sits under the plan's last words: keep it in sight (D5).
            .onChange(of: showsPlanApproval) { _, shown in
                guard shown else { return }
                Task { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.planAnchor, anchor: .bottom) } }
            }
            .onChange(of: state.commandCards[id]?.id) {
                guard state.commandCards[id] != nil else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.cardAnchor, anchor: .bottom) }
            }
            // The reply being written stays in view as it grows: the draft's own view follows it (9a — reading its
            // text here would redraw the whole thread for every token).
            .onChange(of: draft?.runID) { if draft != nil { proxy.scrollTo(Self.draftAnchor, anchor: .bottom) } }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("conversation.thread")
    }

    @ViewBuilder private func itemRow(_ item: ThreadItem, isLast: Bool, draft: ChatRunner.Draft?, lastID: UUID?,
                                      follow: @escaping () -> Void = {}, isEarlier: Bool = false) -> some View {
        if item.isUser {
            let message = item.messages[0]
            if let event = message.event {
                if event.kind == .summary {
                    SummaryCard(event: event).id(message.id)
                } else if event.kind == .rewind {
                    rewindRow(event, isEarlier: isEarlier).id(message.id)
                } else {
                    EventDivider(state: state, event: event, conversationID: conversation.id).id(message.id)
                }
            } else {
                MessageRow(state: state, session: session, conversation: conversation, message: message, isFlashing: flashing == message.id,
                           isEarlier: isEarlier)
                    .id(message.id)
            }
        } else {
            AgentRunRow(state: state, session: session, conversation: conversation, messages: item.messages, flashing: flashing,
                        draft: draft, lastID: lastID, showsPlanApproval: isLast && showsPlanApproval, follow: follow)
        }
    }

    /// 10e: where the user went back — the line, and under it, opened, what the edited message replaced: dimmed and
    /// read-only. A line inside an earlier version stays a line.
    private func rewindRow(_ event: ThreadEvent, isEarlier: Bool) -> some View {
        let version = conversation.earlier.first { $0.id == event.versionID }
        let items = version.map { ThreadItem.group($0.messages.filter { !$0.isHidden || $0.marker != nil }) } ?? []
        let canOpen = !isEarlier && !items.isEmpty
        let isOpen = canOpen && (version.map { openVersions.contains($0.id) } == true || VerificationHooks.opensToolCards)
        return VStack(spacing: 14) {
            RewindDivider(title: event.title, count: items.count, isOpen: isOpen, canOpen: canOpen) {
                guard let version else { return }
                if openVersions.remove(version.id) == nil { openVersions.insert(version.id) }
            }
            if isOpen {
                // The rows inside are this view's own rows: erased, or the type would contain itself.
                AnyView(VStack(spacing: 16) {
                    ForEach(items) { item in itemRow(item, isLast: false, draft: nil, lastID: nil, isEarlier: true) }
                })
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.surfaceRaised.color.opacity(0.5)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Palette.line.color, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                .opacity(0.6)
                .disabled(true)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("rewind.earlier")
            }
        }
    }

    /// The latest compaction folds the visible messages before its boundary (E5); none are removed.
    static func fold(_ visible: [Message], in conversation: Conversation) -> (folded: [Message], kept: [Message], record: CompactionRecord?) {
        guard let record = conversation.messages.last(where: { $0.compaction != nil })?.compaction,
              let boundary = conversation.messages.firstIndex(where: { $0.id == record.firstKeptID }) else { return ([], visible, nil) }
        let before = Set(conversation.messages[..<boundary].map(\.id))
        let folded = visible.filter { before.contains($0.id) }
        guard !folded.isEmpty else { return ([], visible, nil) }
        return (folded, visible.filter { !before.contains($0.id) }, record)
    }

    private var emptyText: String {
        if conversation.isSide { return "岔开问点别的：它能看文件、搜索，但不会改动任何东西。" }
        if conversation.isGroup { return "群里有 \(conversation.members.count) 个角色：@ 谁就交给谁，不 @ 就按任务的性质自动分配" }
        return "开始与 \(ConversationReadiness.headline(of: conversation, agents: state.agents)) 对话"
    }

    private func toBottom(_ proxy: ScrollViewProxy) {
        let target: AnyHashable? = state.chat.steering[id]?.last?.id ?? (state.chat.drafts[id] != nil ? Self.draftAnchor : visible.last?.id)
        guard let target else { return }
        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(target, anchor: .bottom) }
    }

    private func jump(_ proxy: ScrollViewProxy) {
        guard let jump = state.messageJump, jump.conversationID == id else { return }
        state.messageJump = nil
        flashing = jump.messageID
        Task {
            proxy.scrollTo(jump.messageID, anchor: .center)
            try? await Task.sleep(for: .seconds(2))
            if flashing == jump.messageID { flashing = nil }
        }
    }
}

/// `.msg-row` for the user: right-aligned bubble, avatar 32 (old D11), time in mono under it; at most 640 wide.
/// A message sent while the Agent works waits here, dimmed, until the current step is done (7b, L4).
private struct MessageRow: View {
    let state: AppState
    let session: ProjectSession
    let conversation: Conversation
    let message: Message
    let isFlashing: Bool
    var isQueued = false
    /// Inside an earlier version (10e): read-only.
    var isEarlier = false

    @State private var isHovering = false

    private var isEditing: Bool { !isQueued && !isEarlier && state.editingMessage == message.id }
    /// 10e: 修改 while the pointer is on it.
    private var showsEdit: Bool { isHovering && !isQueued && !isEarlier && state.canEdit(message, in: conversation) }
    /// 复制 while the pointer is on it (user 2026-09-14).
    private var showsCopy: Bool { isHovering && !isEditing && !message.text.isEmpty }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .trailing, spacing: 4) {
                if isEditing {
                    MessageEditor(state: state, session: session, conversation: conversation, message: message)
                } else {
                    bubble
                    HStack(spacing: 10) {
                        if showsEdit { editButton }
                        if showsCopy { CopyButton(text: message.text, state: state) }
                        Text(isQueued ? "它做完这一步就会看到" : ConversationText.clock(message.createdAt))
                            .font(isQueued ? FormoraFont.ui(11) : FormoraFont.mono(10.5))
                            .foregroundStyle(Palette.inkFaint.color)
                            .padding(.horizontal, 3)
                            .accessibilityIdentifier(isQueued ? "message.queued" : "message.time")
                    }
                }
            }
            UserAvatar(state: state, size: 32).padding(.top, 2)
        }
        .opacity(isQueued ? 0.6 : 1)
        .frame(maxWidth: 640, alignment: .trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("message.user")
    }

    private var editButton: some View {
        Button { state.editingMessage = message.id } label: {
            HStack(spacing: 4) {
                IconView(Icons.pencil, size: 11)
                Text("修改")
            }
            .font(FormoraFont.ui(11))
            .foregroundStyle(Palette.inkMuted.color)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("改了重新发送：这条之后的对话会收起，Agent 从这条开始重新做")
        .accessibilityIdentifier("message.edit")
    }

    private var bubble: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12, bottomTrailingRadius: 12, topTrailingRadius: 4,
                                           style: .continuous)
        return VStack(alignment: .leading, spacing: 9) {
            if !message.text.isEmpty {
                Text(Self.userText(message, in: conversation, agents: state.agents))
                    .font(FormoraFont.ui(13.5))
                    .foregroundStyle(Palette.ink.color)
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    // An `@` file opens in 文件 (7d, D3).
                    .environment(\.openURL, OpenURLAction { url in
                        guard let path = FileMentions.path(fromLink: url) else { return .systemAction }
                        state.select(.files)
                        Task { await state.files?.reveal(relativePath: path) }
                        return .handled
                    })
                    .contextMenu { Button("复制") { CopyButton.copy(message.text, state: state) } }
            }
            if !message.attachments.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(message.attachments) { attachment in
                        AttachmentChip(attachment: attachment, projectRoot: session.accessibleRoot, fill: Palette.surfaceRaised.color) {
                            state.select(.files)
                            Task { await state.files?.reveal(relativePath: attachment.relativePath) }
                        }
                    }
                }
            }
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 14)
        .background(shape.fill(isFlashing ? Palette.accentSoft.color : Palette.surfaceRaised2.color))
        .overlay(shape.strokeBorder(isFlashing ? Palette.accent.color : Palette.lineStrong.color, lineWidth: 1))
        .animation(.easeOut(duration: 0.25), value: isFlashing)
    }

    /// The `@`-ed members stand out in success colour — who the work went to (spec §9.10: role chips are
    /// success, file chips accent).
    static func userText(_ message: Message, in conversation: Conversation, agents: AgentStore) -> AttributedString {
        var text = AttributedString(message.text)
        // `@` files (7d, D3): accent mono text (not pills — deviation), a link to the file.
        for mention in message.mentions {
            for token in Set([FileMentions.token(for: mention.path), "@" + mention.path]) {
                for range in Mentions.ranges(of: token, in: message.text) {
                    guard let lower = AttributedString.Index(range.lowerBound, within: text),
                          let upper = AttributedString.Index(range.upperBound, within: text) else { continue }
                    text[lower..<upper].foregroundColor = Palette.accent.color
                    text[lower..<upper].backgroundColor = Palette.accentSoft.color
                    text[lower..<upper].font = FormoraFont.mono(12.5)
                    text[lower..<upper].link = FileMentions.link(mention.path)
                }
            }
        }
        guard conversation.isGroup, !message.assignees.isEmpty else { return text }
        let names = message.assignees.compactMap { agents.agent($0) }.flatMap { [$0.displayName, $0.customName] }
        for name in names.sorted(by: { $0.count > $1.count }) {
            for range in Mentions.ranges(of: "@" + name, in: message.text) {
                guard let lower = AttributedString.Index(range.lowerBound, within: text),
                      let upper = AttributedString.Index(range.upperBound, within: text) else { continue }
                text[lower..<upper].foregroundColor = Palette.success.color
                text[lower..<upper].backgroundColor = Palette.successSoft.color
            }
        }
        return text
    }
}

/// An Agent's run in one frame (7b, L8; old D37): avatar and name once; each turn's thinking, words, tool cards
/// and save cards in order; the model's turn being written at the end; the time once.
private struct AgentRunRow: View {
    let state: AppState
    let session: ProjectSession
    let conversation: Conversation
    let messages: [Message]
    let flashing: UUID?
    let draft: ChatRunner.Draft?
    let lastID: UUID?
    /// The last run of a plan-mode conversation (D5).
    var showsPlanApproval = false
    /// Keeps the reply being written in view as it grows.
    var follow: () -> Void = {}

    private var agent: AgentRecord? { state.agents.agent(messages[0].agentID ?? conversation.agentID) }
    private var isRunning: Bool { state.chat.isRunning(conversation.id) }

    @State private var isHovering = false

    /// Every word of the run, for 复制 (user 2026-09-14) — a reply stopped halfway included.
    private var spoken: String {
        messages.filter { $0.marker == nil && $0.failure == nil }.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AgentFrameAvatar(state: state, agent: agent, fallbackName: messages[0].speakerName).padding(.top, 2)
            VStack(alignment: .leading, spacing: 8) {
                if conversation.isGroup {
                    Text(agent?.displayName ?? messages[0].speakerName ?? ConversationReadiness.deletedAgentName)
                        .font(FormoraFont.ui(11))
                        .foregroundStyle(Palette.inkFaint.color)
                        .padding(.horizontal, 3)
                }
                ForEach(messages) { message in
                    turn(message).id(message.id)
                }
                if let draft {
                    DraftContent(state: state, conversation: conversation, draft: draft, follow: follow).id(ThreadView.draftAnchor)
                } else if let last = messages.last {
                    HStack(spacing: 10) {
                        HStack(spacing: 6) {
                            Text(ConversationText.clock(last.createdAt))
                            if last.isStopped { Text("· 已停止") }
                        }
                        .font(FormoraFont.mono(10.5))
                        .foregroundStyle(Palette.inkFaint.color)
                        if isHovering, !spoken.isEmpty { CopyButton(text: spoken, state: state) }
                    }
                    .padding(.horizontal, 3)
                }
                if showsPlanApproval {
                    PlanApprovalCard {
                        let root = session.current?.id == conversation.projectID ? session.accessibleRoot : nil
                        state.executePlan(conversation.id, projectRoot: root,
                                          projectName: session.projects.first { $0.id == conversation.projectID }?.name)
                    }
                    .id(ThreadView.planAnchor)
                }
            }
        }
        .frame(maxWidth: 640, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("message.agent")
    }

    @ViewBuilder private func turn(_ message: Message) -> some View {
        if let marker = message.marker {
            // 10h: a 旁审 note; 10g: where a watched rule stopped the reply; 7d: an older self-review's line.
            if let review = message.review {
                ReviewCard(review: review)
            } else if let advice = message.advice {
                AdviceCard(severity: advice, text: marker)
            } else if message.rule != nil {
                RuleMarker(text: marker)
            } else {
                ReviewMarker(text: marker)
            }
        } else {
            answer(message)
        }
    }

    @ViewBuilder private func answer(_ message: Message) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let thinking = message.thinking {
                ThinkingFold(text: thinking, seconds: message.thinkingSeconds, isThinking: false)
            }
            if let failure = message.failure {
                FailedReply(reason: failure, canRetry: message.id == lastID && !isRunning) {
                    state.chat.retry(conversation.id)
                }
            } else if !message.text.isEmpty {
                bubble(message)
            }
            // The plan is docked above the composer, not a card (D4); a question is its own card (D6).
            ForEach(message.toolCalls.filter { $0.name != PlanTool.spec.name }) { call in
                if call.name == AskTool.spec.name {
                    AskCard(call: call, isWaiting: call.result == nil && !isRunning)
                } else if call.name == TeamTools.delegateName {
                    DelegateCard(state: state, call: call, phase: phase(call, in: message)) { state.chat.decide(conversation.id, allow: $0) }
                } else {
                    ToolCallCard(call: call, phase: phase(call, in: message), risk: risk(call), preview: preview(call), grant: grant(call),
                                 remember: { state.chat.decide(conversation.id, $0) }) { state.chat.decide(conversation.id, allow: $0) }
                }
            }
            ForEach(Self.saved(message), id: \.path) { file in
                let last = Self.lastChange(to: file.path, in: message)
                SaveCard(path: file.path, isNewFile: file.isNew, change: last?.change,
                         undo: last.map { found in { state.undoChange(conversation.id, message: message.id, call: found.callID) } }) {
                    state.select(.files)
                    Task { await state.files?.reveal(relativePath: file.path) }
                }
            }
            if let note = message.note {
                Text(note)
                    .font(FormoraFont.ui(11))
                    .foregroundStyle(Palette.inkFaint.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 3)
                    .accessibilityIdentifier("reply.note")
            }
            // Worked in the background (9e): its steps are in its lane.
            if let lane = message.lane, state.conversations.conversation(lane) != nil {
                SmallButton(title: "看过程", identifier: "reply.lane") { state.selectedConversationID = lane }
            }
            if let pause = message.pause, !isRunning {
                PauseCard(reason: pause) { state.chat.resume(conversation.id) }
            }
        }
    }

    private func bubble(_ message: Message) -> some View {
        let isFlashing = flashing == message.id
        let shape = UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 12, bottomTrailingRadius: 12, topTrailingRadius: 12,
                                           style: .continuous)
        return MarkdownText(source: message.text)
            .padding(.vertical, 11)
            .padding(.horizontal, 14)
            .background(shape.fill(isFlashing ? Palette.accentSoft.color : Palette.surface.color))
            .overlay(shape.strokeBorder(isFlashing ? Palette.accent.color : Palette.line.color, lineWidth: 1))
            .animation(.easeOut(duration: 0.25), value: isFlashing)
            .contextMenu { Button("复制") { CopyButton.copy(message.text, state: state) } }
    }

    /// Bob's sentence on the step waiting here (9e, J).
    private func risk(_ call: ToolCall) -> String? {
        state.chat.approvals[conversation.id].flatMap { $0.callID == call.id ? $0.risk : nil }
    }

    /// The change a write or an edit waiting here would make (10d).
    private func preview(_ call: ToolCall) -> String? {
        state.chat.approvals[conversation.id].flatMap { $0.callID == call.id ? $0.preview : nil }
    }

    /// What the step waiting here could be remembered as (10b).
    private func grant(_ call: ToolCall) -> ApprovalGrant? {
        state.chat.approvals[conversation.id].flatMap { $0.callID == call.id ? $0.grant : nil }
    }

    private func phase(_ call: ToolCall, in message: Message) -> ToolCallCard.Phase {
        if let result = call.result { return .finished(result) }
        let approval = state.chat.approvals[conversation.id]
        if let approval, approval.callID == call.id, approval.messageID == message.id { return .waiting(approval.reason) }
        if state.chat.executing[conversation.id] == call.id { return .running }
        return isRunning ? .queued : .finished(ToolResult(status: .stopped, output: "没有执行。"))
    }

    /// The files a turn wrote, once each — the last write to a path decides, a new file stays new.
    /// 10d: the last write or edit of `path` in the message — its change and its call, for the card's diff and 撤销.
    static func lastChange(to path: String, in message: Message) -> (change: FileChange, callID: String)? {
        guard let call = message.toolCalls.last(where: { $0.result?.status == .done && $0.result?.savedPath == path && $0.result?.change != nil }),
              let change = call.result?.change else { return nil }
        return (change, call.id)
    }

    static func saved(_ message: Message) -> [(path: String, isNew: Bool)] {
        var files: [(path: String, isNew: Bool)] = []
        for call in message.toolCalls {
            guard let result = call.result, result.status == .done, let path = result.savedPath else { continue }
            if let index = files.firstIndex(where: { $0.path == path }) {
                files[index].isNew = files[index].isNew || result.isNewFile == true
            } else {
                files.append((path, result.isNewFile == true))
            }
        }
        return files
    }
}

private struct AgentFrameAvatar: View {
    let state: AppState
    let agent: AgentRecord?
    let fallbackName: String?

    var body: some View {
        if let agent {
            AgentAvatar(image: state.agents.avatars[agent.id], initial: agent.role.initial, size: 32, isMuted: !agent.isActive)
        } else {
            AgentAvatar(image: nil, initial: fallbackName?.first.map(String.init) ?? "?", size: 32, isMuted: true)
        }
    }
}

/// A reply being written that starts its own frame: avatar and name, then the turn.
private struct DraftRow: View {
    let state: AppState
    let conversation: Conversation
    let draft: ChatRunner.Draft
    var follow: () -> Void = {}

    var body: some View {
        let agent = state.agents.agent(draft.agentID)
        HStack(alignment: .top, spacing: 10) {
            AgentFrameAvatar(state: state, agent: agent, fallbackName: nil).padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                if conversation.isGroup, let agent {
                    Text(agent.displayName).font(FormoraFont.ui(11)).foregroundStyle(Palette.inkFaint.color).padding(.horizontal, 3)
                }
                DraftContent(state: state, conversation: conversation, draft: draft, follow: follow)
            }
        }
        .frame(maxWidth: 640, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The model's turn being written: the thinking fold, three dots until the first word, then the text with a cursor;
/// a retry or fallback note under it; in a group, who is next.
private struct DraftContent: View {
    let state: AppState
    let conversation: Conversation
    let draft: ChatRunner.Draft
    var follow: () -> Void = {}

    var body: some View {
        let waiting = state.chat.pending(conversation.id).compactMap { state.agents.agent($0)?.displayName }
        let shape = UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 12, bottomTrailingRadius: 12, topTrailingRadius: 12,
                                           style: .continuous)
        VStack(alignment: .leading, spacing: 4) {
            if draft.thinkingStartedAt != nil {
                ThinkingFold(text: draft.thinking, seconds: draft.thinkingSeconds, isThinking: draft.text.isEmpty)
            }
            if draft.text.isEmpty {
                TypingDots()
            } else {
                MarkdownText(source: ChatText.clean(draft.text), showsCursor: true)
                    .padding(.vertical, 11)
                    .padding(.horizontal, 14)
                    .background(shape.fill(Palette.surface.color))
                    .overlay(shape.strokeBorder(Palette.line.color, lineWidth: 1))
            }
            if let note = draft.note {
                Text(note)
                    .font(FormoraFont.ui(11))
                    .foregroundStyle(Palette.inkFaint.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 3)
                    .accessibilityIdentifier("reply.draftNote")
            }
            // A group answers one after another: who is next is in view.
            if !waiting.isEmpty {
                Text("接下来：\(waiting.joined(separator: "、"))")
                    .font(FormoraFont.ui(11))
                    .foregroundStyle(Palette.inkFaint.color)
                    .padding(.horizontal, 3)
                    .accessibilityIdentifier("reply.queue")
            }
        }
        .onChange(of: draft.text.count) { follow() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reply.draft")
    }
}

/// The account's picture, or its initial on the neutral tile (spec §9.5: never a hard-coded letter).
struct UserAvatar: View {
    let state: AppState
    let size: CGFloat

    var body: some View {
        ZStack {
            if let image = state.account.avatar {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFill()
            } else {
                AvatarShape().fill(Palette.surfaceRaised2.color)
                Text(state.accountInitial ?? "我")
                    .font(FormoraFont.ui(size * 0.35, weight: 600))
                    .foregroundStyle(Palette.inkMuted.color)
            }
        }
        .frame(width: size, height: size)
        .clipShape(AvatarShape())
        .accessibilityHidden(true)
    }
}

/// `.attach-chip`: pill with a thumbnail or glyph and the file name in mono; removable in the composer.
struct AttachmentChip: View {
    let attachment: Attachment
    let projectRoot: URL?
    var fill = Palette.surfaceRaised2.color
    var onRemove: (() -> Void)?
    var onOpen: (() -> Void)?

    init(attachment: Attachment, projectRoot: URL?, fill: Color = Palette.surfaceRaised2.color,
         onRemove: (() -> Void)? = nil, onOpen: (() -> Void)? = nil) {
        self.attachment = attachment
        self.projectRoot = projectRoot
        self.fill = fill
        self.onRemove = onRemove
        self.onOpen = onOpen
    }

    var body: some View {
        HStack(spacing: 7) {
            thumbnail
            Text(attachment.name)
                .font(FormoraFont.mono(11))
                .foregroundStyle(Palette.inkMuted.color)
                .lineLimit(1)
                .truncationMode(.middle)
            if let onRemove {
                RemoveButton(label: "移除 \(attachment.name)", action: onRemove)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, onRemove == nil ? 10 : 4)
        .padding(.vertical, 3)
        .frame(maxWidth: 220, alignment: .leading)
        .background(Capsule().fill(fill))
        .overlay(Capsule().strokeBorder(Palette.lineStrong.color, lineWidth: 1))
        .contentShape(Capsule())
        .onTapGesture { onOpen?() }
        .help(attachment.relativePath)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(attachment.name)
        .accessibilityIdentifier("attachment.\(attachment.name)")
    }

    @ViewBuilder private var thumbnail: some View {
        if attachment.kind == .image, let root = projectRoot,
           let image = NSImage(contentsOf: root.appendingPathComponent(attachment.relativePath)) {
            Image(nsImage: image).resizable().scaledToFill().frame(width: 20, height: 20)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        } else {
            IconView(attachment.kind == .image ? Icons.image : Icons.file, size: 13).foregroundStyle(Palette.inkMuted.color)
        }
    }
}

private struct RemoveButton: View {
    let label: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            IconView(Icons.close, size: 10)
                .foregroundStyle(isHovering ? Palette.ink.color : Palette.inkFaint.color)
                .frame(width: 18, height: 18)
                .background(Circle().fill(isHovering ? Palette.surfaceRaised.color : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(label)
    }
}

/// Wraps children onto new lines — attachment chips in a bubble or the composer.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, maxWidth), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// 复制 by a message's time (user 2026-09-14): the words to the clipboard, a toast saying so.
struct CopyButton: View {
    let text: String
    let state: AppState

    var body: some View {
        Button { Self.copy(text, state: state) } label: {
            HStack(spacing: 4) {
                IconView(Icons.copy, size: 11)
                Text("复制")
            }
            .font(FormoraFont.ui(11))
            .foregroundStyle(Palette.inkMuted.color)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("复制这条消息的文字")
        .accessibilityIdentifier("message.copy")
    }

    static func copy(_ text: String, state: AppState) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        state.toasts.show("已复制", seconds: 2)
    }
}
