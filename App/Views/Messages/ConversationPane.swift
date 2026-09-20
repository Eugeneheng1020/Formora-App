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
    /// Just opened: every change of the content's height while the lazy rows settle sends it back to the end.
    @State private var isLanding = false
    /// Whether the thread is following its end (9a, user 2026-09-20). It stops following the moment the user scrolls
    /// away from the bottom, and follows again once they are back — a chat app's rule, not an unconditional jump.
    @State private var atEnd = true
    /// The content's height and where its top sits, and the window it is read through: growth is told apart from the
    /// user's own scrolling by which of them changed.
    @State private var metrics = ThreadMetrics()
    @State private var viewport: CGFloat = 0

    static let cardAnchor = "commandCard"
    /// The thread's very end: the last run's fold and time under its words (user 2026-09-15), the command card, all of it.
    static let endAnchor = "threadEnd"
    static let dividerAnchor = "compactDivider"
    /// A message still waiting is its own view, never the thread row of the same message: one `.id` per view in the
    /// stack, or SwiftUI keeps the one it had — the delivered message stayed dimmed (user 2026-09-20).
    static func queuedAnchor(_ messageID: UUID) -> String { "queued-" + messageID.uuidString }
    static let space = "thread"
    /// Close enough to the bottom to count as being there — a pixel short of it must not stop the thread following.
    static let endSlack: CGFloat = 40

    private var id: UUID { conversation.id }
    /// Not the loop's own words — except a self-review's marker line (7d, D7).
    private var visible: [Message] { conversation.messages.filter { !$0.isHidden || $0.marker != nil } }

    var body: some View {
        let visible = visible
        let fold = Self.fold(visible, in: conversation)
        let items = ThreadItem.group(fold.kept)
        let draft = state.chat.drafts[id]
        let draftInFrame = draft != nil && items.last.map { !$0.isUser && $0.runID == draft?.runID } == true
        let waiting: [Message] = (state.chat.steering[id] ?? []).filter { !$0.isHidden }
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
                        let lastItem = items.last?.id
                        let lastVisible = visible.last?.id
                        let following = followDraft(proxy)
                        let revealing = reveal(proxy)
                        ForEach(items) { item in
                            let inFrame: ChatRunner.Draft? = draftInFrame && item.id == lastItem ? draft : nil
                            itemRow(item, isLast: item.id == lastItem, draft: inFrame, lastID: lastVisible,
                                    follow: following, reveal: revealing)
                        }
                        if let draft, !draftInFrame {
                            // No `.id` of its own: the reply being written shows up in two places (its own row here,
                            // or inside the run's frame), and one identity used by both is what left a delivered
                            // message dimmed — see `queuedAnchor`. The thread follows `endAnchor`, not the draft.
                            DraftRow(state: state, conversation: conversation, draft: draft, follow: followDraft(proxy))
                        }
                        // Sent while the Agent works: it reads them after the current step (L4).
                        ForEach(waiting) { message in
                            MessageRow(state: state, session: session, conversation: conversation, message: message,
                                       isFlashing: false, isQueued: true)
                                .id(Self.queuedAnchor(message.id))
                        }
                        if let reason = state.chat.compacting[id] {
                            CompactingRow(reason: reason)
                        }
                        // A command's output (D2): one-off, under everything.
                        commandCard
                        // Air under the last message (user 2026-09-15: 12; 2026-09-20: 「甚至没有安全距离」): while a run
                        // writes, the thread follows this, so this is the distance kept from the composer's line.
                        Color.clear.frame(height: 26).id(Self.endAnchor)
                    }
                    .padding(.top, 22)
                    .padding(.horizontal, 26)
                    .background(ContentProbe())
                }
            }
            // The window the thread is read through, and the space the content's place is measured in.
            .coordinateSpace(name: Self.space)
            .background(ViewportProbe())
            // 回到最新 (user 2026-09-20): while the thread isn't following, the way back is one click — and following
            // starts again from there.
            .overlay(alignment: .bottomTrailing) { backToLatest(proxy, hasContent: !visible.isEmpty) }
            .animation(.easeOut(duration: 0.15), value: atEnd)
            // Opens at its end (user 2026-09-14: 「重新打开必须是最新的内容」; 2026-09-15: switching to 消息 still showed the first
            // message of a long thread). The lazy rows get their real heights only once laid out, so one jump lands short:
            // it jumps again whenever the content's height changes in the first moments, and on a schedule besides.
            .onPreferenceChange(ThreadViewport.self) { viewport = $0 }
            .onPreferenceChange(ThreadGeometry.self) { settled(proxy, $0) }
            .onAppear {
                if state.messageJump?.conversationID == id {
                    jump(proxy)
                } else if !visible.isEmpty {
                    land(proxy)
                }
            }
            .onChange(of: state.messageJump) { jump(proxy) }
            .onChange(of: visible.count) { toBottom(proxy, isOwn: endsWithOwnMessage) }
            .onChange(of: state.chat.steering[id]?.count) { toBottom(proxy, isOwn: true) }
            .onChange(of: state.chat.approvals[id]) { toBottom(proxy) }
            // QA (-FormoraRevealCompaction): a new compaction's divider comes into view.
            .onChange(of: conversation.messages.last(where: { $0.compaction != nil })?.id) { _, landed in
                guard landed != nil, state.revealsCompaction else { return }
                Task { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.dividerAnchor, anchor: .top) } }
            }
            .onChange(of: state.commandCards[id]?.id) {
                guard state.commandCards[id] != nil else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.cardAnchor, anchor: .bottom) }
            }
            // A new turn of a run it is following comes into view with the rest.
            .onChange(of: draft?.runID) { if draft != nil { follow(proxy) } }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("conversation.thread")
    }

    @ViewBuilder private func itemRow(_ item: ThreadItem, isLast: Bool, draft: ChatRunner.Draft?, lastID: UUID?,
                                      follow: @escaping () -> Void = {}, reveal: @escaping (AnyHashable) -> Void = { _ in }) -> some View {
        if item.isUser {
            let message = item.messages[0]
            if let event = message.event {
                if event.kind == .summary {
                    SummaryCard(event: event).id(message.id)
                } else if event.kind == .rewind {
                    // 10e (user 2026-09-20): an edit that was re-sent leaves no line. New ones are hidden outright;
                    // this skips the ones older conversations already have on disk.
                    EmptyView()
                } else {
                    EventDivider(state: state, event: event, conversationID: conversation.id, messageID: message.id).id(message.id)
                }
            } else {
                MessageRow(state: state, session: session, conversation: conversation, message: message, isFlashing: flashing == message.id)
                    .id(message.id)
            }
        } else {
            AgentRunRow(state: state, session: session, conversation: conversation, messages: item.messages, flashing: flashing,
                        draft: draft, lastID: lastID, follow: follow, reveal: reveal)
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

    /// Keeps the reply being written in view as it grows — the thread's end, so the run's steps and folds under the
    /// words are in view too (user 2026-09-20), and only while the thread is following.
    private func followDraft(_ proxy: ScrollViewProxy) -> () -> Void {
        { follow(proxy) }
    }

    /// A command's output (D2): `/cost`, `/memory`, the plan.
    @ViewBuilder private var commandCard: some View {
        if let card = state.commandCards[id] {
            CommandCardView(card: card, close: { state.commandCards[id] = nil }) {
                switch card.body {
                case .usage:
                    UsageSummary(report: UsageReport(conversation, subtasks: state.conversations.subtasks(of: conversation.id))) { model in
                        "\(state.providers.entry(model.providerID)?.name ?? model.providerID) · \(model.modelID)"
                    }
                case .memory:
                    MemorySummary(groups: MemorySummary.groups(state.chat.memory, conversation: conversation,
                                                              agent: state.commandAgent(conversation)))
                default:
                    PlanList(items: conversation.plan)
                }
            }
            .id(Self.cardAnchor)
        }
    }

    @ViewBuilder private func backToLatest(_ proxy: ScrollViewProxy, hasContent: Bool) -> some View {
        // Not while the thread is still settling onto its end: it is on its way there, not left behind.
        if !atEnd, hasContent, !isLanding {
            BackToLatestButton {
                atEnd = true
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.endAnchor, anchor: .bottom) }
            }
            .padding(.trailing, 18)
            .padding(.bottom, 14)
            .transition(.opacity)
        }
    }

    /// To the end, unless the user has scrolled away from it.
    private func follow(_ proxy: ScrollViewProxy) {
        guard atEnd else { return }
        proxy.scrollTo(Self.endAnchor, anchor: .bottom)
    }

    /// Every layout of the thread. The content growing is the Agent at work: the thread follows it if it was
    /// following. Only the user moving it decides whether it follows at all — or growth itself, which takes the
    /// bottom away for an instant, would stop the following at the first token.
    private func settled(_ proxy: ScrollViewProxy, _ next: ThreadMetrics) {
        let previous = metrics
        metrics = next
        // Scrolled up by hand while the thread is still settling onto its end: the user wins, and the scheduled
        // jumps stop with it. Landing only ever moves the content the other way (its top downwards), so the
        // direction tells them apart — the first frames of an opening thread are never mistaken for a scroll.
        if isLanding, next.top > previous.top + 1 { isLanding = false }
        // While landing, how far from the end it is means nothing: it is mid-jump, and a frame caught in the middle
        // of one read as 「滚走了」 and left 回到最新 showing on a thread that was already at its end.
        if isLanding {
            if next.height != previous.height { proxy.scrollTo(Self.endAnchor, anchor: .bottom) }
            return
        }
        if next.height != previous.height {
            follow(proxy)
            return
        }
        guard next.top != previous.top, viewport > 0 else { return }
        // How much of the content is still below the window.
        atEnd = next.height + next.top - viewport <= Self.endSlack
    }

    /// The least scroll that shows a view whole — a fold's cards once it opens (user 2026-09-15).
    private func reveal(_ proxy: ScrollViewProxy) -> (AnyHashable) -> Void {
        { id in withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: nil) } }
    }

    /// To the end now, and again as the rows settle — for a second and a half, unless something else moved the thread.
    private func land(_ proxy: ScrollViewProxy) {
        isLanding = true
        atEnd = true
        proxy.scrollTo(Self.endAnchor, anchor: .bottom)
        Task { @MainActor in
            for delay in [60, 250, 700, 1500] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard isLanding else { return }
                proxy.scrollTo(Self.endAnchor, anchor: .bottom)
            }
            isLanding = false
        }
    }

    /// New content at the end. What the user sends themselves always takes them there — sending is asking to see it
    /// (every chat app); the Agent's own goes unfollowed while they are reading further up (user 2026-09-20).
    private func toBottom(_ proxy: ScrollViewProxy, isOwn: Bool = false) {
        if isOwn { atEnd = true }
        guard atEnd else { return }
        let target: AnyHashable = (state.chat.steering[id]?.last?.id).map { Self.queuedAnchor($0) } ?? Self.endAnchor
        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(target, anchor: .bottom) }
    }

    /// The last thing in the thread is the user's own message: they just sent it.
    private var endsWithOwnMessage: Bool {
        guard let last = visible.last else { return false }
        return last.role == .user && last.marker == nil && last.event == nil
    }

    private func jump(_ proxy: ScrollViewProxy) {
        guard let jump = state.messageJump, jump.conversationID == id else { return }
        isLanding = false
        state.messageJump = nil
        flashing = jump.messageID
        Task {
            proxy.scrollTo(jump.messageID, anchor: .center)
            try? await Task.sleep(for: .seconds(2))
            if flashing == jump.messageID { flashing = nil }
        }
    }
}

/// Where the thread's content stands: how tall it is, and where its top sits in the window it is read through
/// (negative once scrolled). Together with the window's height that says how much is still below — whether the
/// thread is at its end.
struct ThreadMetrics: Equatable {
    var height: CGFloat = 0
    var top: CGFloat = 0
}

/// Measures the thread's content where it stands in the window (`ThreadView.space`).
private struct ContentProbe: View {
    var body: some View {
        GeometryReader { geometry in
            let frame = geometry.frame(in: .named(ThreadView.space))
            Color.clear.preference(key: ThreadGeometry.self,
                                   value: ThreadMetrics(height: geometry.size.height, top: frame.minY))
        }
    }
}

/// Measures the window the thread is read through.
private struct ViewportProbe: View {
    var body: some View {
        GeometryReader { geometry in
            Color.clear.preference(key: ThreadViewport.self, value: geometry.size.height)
        }
    }
}

private struct ThreadGeometry: PreferenceKey {
    static let defaultValue = ThreadMetrics()
    static func reduce(value: inout ThreadMetrics, nextValue: () -> ThreadMetrics) {
        let next = nextValue()
        if next != ThreadMetrics() { value = next }
    }
}

/// The height of the window the thread is read through.
private struct ThreadViewport: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// `.back-to-latest` (user 2026-09-20): while the thread isn't following its end, the way back.
private struct BackToLatestButton: View {
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                IconView(Icons.chevronDown, size: 12)
                Text("回到最新").font(FormoraFont.ui(11.5, weight: 600))
            }
            .foregroundStyle(Palette.ink.color)
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(Capsule().fill(isHovering ? Palette.surfaceRaised2.color : Palette.surfaceRaised.color))
            .overlay(Capsule().strokeBorder(Palette.lineStrong.color, lineWidth: 1))
            .softShadow()
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("回到对话最新的一条，并重新跟随")
        .accessibilityIdentifier("thread.backToLatest")
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

    @State private var isHovering = false

    private var isEditing: Bool { !isQueued && state.editingMessage == message.id }
    /// 10e: 修改 while the pointer is on it.
    private var showsEdit: Bool { isHovering && !isQueued && state.canEdit(message, in: conversation) }
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
        .help("改了重新发送：这条之后的内容会被去掉，Agent 从这条开始重新做")
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
    /// Keeps the reply being written in view as it grows.
    var follow: () -> Void = {}
    /// Scrolls the least that shows the identified view whole — the fold's cards once it opens.
    var reveal: (AnyHashable) -> Void = { _ in }

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
                    DraftContent(state: state, conversation: conversation, draft: draft, showsThinking: false, follow: follow)
                }
                // 一次运行底部的四组折叠 (user 2026-09-15, 2026-09-18): the run's thinking, the 旁审 notes, its steps (the one
                // in hand in view while it runs) and the files it changed, each a line under its words.
                ThinkingFoldView(thoughts: RunFolds.thoughts(in: messages) + (draft.flatMap(Self.thought) ?? []),
                                 isThinking: draft.map { $0.thinkingStartedAt != nil && $0.text.isEmpty } ?? false, reveal: reveal)
                AdviceFoldView(notes: RunFolds.advice(in: messages), reveal: reveal)
                ToolFoldView(steps: ToolFold.steps(in: messages), isRunning: isRunning, executing: state.chat.executing[conversation.id],
                             approval: state.chat.approvals[conversation.id]?.callID, phase: { phase($0.call, in: $0.messageID) }, reveal: reveal,
                             onCopy: { CopyButton.copy($0, state: state) })
                ChangesFoldView(changes: RunFolds.changes(in: messages),
                                undo: { file in
                                    if let callID = file.callID { state.undoChange(conversation.id, message: file.messageID, call: callID) }
                                },
                                open: { file in
                                    state.select(.files)
                                    Task { await state.files?.reveal(relativePath: file.path) }
                                }, reveal: reveal)
                if draft == nil, let last = messages.last {
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
            }
        }
        .frame(maxWidth: 640, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("message.agent")
    }

    /// The model's turn being written, as a segment of the run's thinking group.
    private static func thought(_ draft: ChatRunner.Draft) -> [RunFolds.Thought] {
        guard draft.thinkingStartedAt != nil else { return [] }
        return [RunFolds.Thought(messageID: draft.runID, text: draft.thinking, seconds: draft.thinkingSeconds)]
    }

    @ViewBuilder private func turn(_ message: Message) -> some View {
        if let marker = message.marker {
            // 10h: a 旁审 note — 必须停 here, 提醒 and 担心 in the run's group (user 2026-09-18); 10g: where a watched rule
            // stopped the reply; 7d: an older self-review's line.
            if let review = message.review {
                ReviewCard(review: review)
            } else if let advice = message.advice {
                if advice == .blocker { AdviceCard(severity: advice, text: marker) }
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
            if let failure = message.failure {
                FailedReply(reason: failure)
            } else if !message.text.isEmpty {
                bubble(message)
            }
            // The plan is docked above the composer (D4); a question is its own card (D6); a delegation is the helper's
            // strip (S8). Every other call is in the run's fold under its words (user 2026-09-15).
            ForEach(message.toolCalls.filter { $0.name == AskTool.spec.name || $0.name == TeamTools.delegateName }) { call in
                if call.name == AskTool.spec.name {
                    AskCard(call: call, isWaiting: call.result == nil && !isRunning)
                } else {
                    DelegateCard(state: state, call: call, phase: phase(call, in: message.id))
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
        }
    }

    private var projectRoot: URL? { session.current?.id == conversation.projectID ? session.accessibleRoot : nil }

    /// A path in the reply names a file of the project (user 2026-09-15): then it is a link.
    private func fileExists(_ path: String) -> Bool {
        guard let projectRoot, !path.hasPrefix("/") else { return false }
        return FileManager.default.fileExists(atPath: projectRoot.appendingPathComponent(path).path)
    }

    private func openFile(_ path: String) {
        state.select(.files)
        Task { await state.files?.reveal(relativePath: path) }
    }

    private func bubble(_ message: Message) -> some View {
        let isFlashing = flashing == message.id
        let shape = UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 12, bottomTrailingRadius: 12, topTrailingRadius: 12,
                                           style: .continuous)
        return MarkdownText(source: message.text, links: true, fileExists: fileExists, openFile: openFile,
                            onCopy: { CopyButton.copy($0, state: state) })
            .padding(.vertical, 11)
            .padding(.horizontal, 14)
            .background(shape.fill(isFlashing ? Palette.accentSoft.color : Palette.surface.color))
            .overlay(shape.strokeBorder(isFlashing ? Palette.accent.color : Palette.line.color, lineWidth: 1))
            .animation(.easeOut(duration: 0.25), value: isFlashing)
            .contextMenu { Button("复制") { CopyButton.copy(message.text, state: state) } }
    }

    private func phase(_ call: ToolCall, in messageID: UUID) -> ToolCallCard.Phase {
        if let result = call.result { return .finished(result) }
        // A subagent sent by /名字 (user 2026-09-15): its subtask runs while this conversation doesn't.
        if let subtask = call.subtaskID, state.chat.isRunning(subtask) { return .running }
        let approval = state.chat.approvals[conversation.id]
        if let approval, approval.callID == call.id, approval.messageID == messageID { return .waiting }
        if state.chat.executing[conversation.id] == call.id { return .running }
        return isRunning ? .queued : .finished(ToolResult(status: .stopped, output: "没有执行。"))
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

/// The model's turn being written: the thinking fold (when the turn starts its own frame — in a run's frame the run's
/// group has it), three dots until the first word, then the text with a cursor; a retry or fallback note under it;
/// in a group, who is next.
private struct DraftContent: View {
    let state: AppState
    let conversation: Conversation
    let draft: ChatRunner.Draft
    var showsThinking = true
    var follow: () -> Void = {}

    var body: some View {
        let waiting = state.chat.pending(conversation.id).compactMap { state.agents.agent($0)?.displayName }
        let shape = UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 12, bottomTrailingRadius: 12, topTrailingRadius: 12,
                                           style: .continuous)
        VStack(alignment: .leading, spacing: 4) {
            if showsThinking, draft.thinkingStartedAt != nil {
                ThinkingFoldView(thoughts: [RunFolds.Thought(messageID: draft.runID, text: draft.thinking, seconds: draft.thinkingSeconds)],
                                 isThinking: draft.text.isEmpty)
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
