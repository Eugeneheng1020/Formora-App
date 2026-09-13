import SwiftUI

/// The 消息 list column (mockup `renderConvListBody`): title + ⊕ (groups only, C6), search, 全部 / 进行中 /
/// 已完成, the rows, and — only when something is hidden — the 「已隐藏的会话」 row (spec §9.1b).
struct MessageListColumn: View {
    let state: AppState
    let session: ProjectSession

    private var store: ConversationStore { state.conversations }
    private var project: UUID? { session.current?.id }

    var body: some View {
        let scoped = store.list(project: project, hiddenView: state.showsHiddenConversations)
        let hasAny = !store.list(project: project, hiddenView: false).isEmpty || store.hiddenCount(project: project) > 0
        let filtered = scoped.filter { state.messageFilter == nil || $0.status == state.messageFilter }
        let rows = rows(filtered)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    Text("消息")
                        .font(FormoraFont.ui(19, weight: 700))
                        .tracking(-0.19)
                        .foregroundStyle(Palette.ink.color)
                        .accessibilityIdentifier("list.title")
                    Spacer(minLength: 0)
                    ListAddButton(label: "新建群聊", identifier: "messages.add") { state.groupDialog = .create }
                }
                .frame(height: 26)
                .padding(.bottom, 14)
                if hasAny {
                    SearchField(placeholder: "搜索对话", text: Binding(get: { state.messageSearch }, set: { state.messageSearch = $0 }),
                                identifier: "messages.search")
                        .padding(.bottom, 12)
                }
            }
            .padding(.top, 16)
            .padding(.horizontal, 18)

            if hasAny {
                // `.filter-tabs` pads 10 inside the list head's 18.
                FilterTabs(state: state, scoped: scoped).padding(.leading, 28).padding(.trailing, 18).padding(.bottom, 10)
            } else {
                Color.clear.frame(height: 10) // the empty `.filter-tabs` row
            }

            TimelineView(.everyMinute) { context in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        if state.showsHiddenConversations { DrillRow(isBack: true, count: 0) { leaveHidden() } }
                        ForEach(rows, id: \.conversation.id) { row in
                            ConversationRow(state: state, conversation: row.conversation, snippet: row.hit?.snippet, now: context.date) {
                                select(row.conversation.id, message: row.hit?.messageID)
                            }
                        }
                        if hasAny, rows.isEmpty {
                            Text(emptyText)
                                .font(FormoraFont.ui(12))
                                .foregroundStyle(Palette.inkFaint.color)
                                .padding(.vertical, 34)
                                .frame(maxWidth: .infinity)
                                .accessibilityIdentifier("messages.noMatch")
                        }
                        let hidden = store.hiddenCount(project: project)
                        if !state.showsHiddenConversations, hidden > 0 {
                            DrillRow(isBack: false, count: hidden) { enterHidden() }
                        }
                    }
                    .padding(.top, 2)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
                }
            }
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.upArrow) { move(-1, in: rows.map(\.conversation)); return .handled }
            .onKeyPress(.downArrow) { move(1, in: rows.map(\.conversation)); return .handled }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("messages.list")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.surface.color)
        .overlay(alignment: .trailing) { Rectangle().fill(Palette.line.color).frame(width: 1) }
    }

    private struct Row {
        let conversation: Conversation
        let hit: ConversationStore.SearchHit?
    }

    private func rows(_ list: [Conversation]) -> [Row] {
        guard !state.messageSearch.trimmingCharacters(in: .whitespaces).isEmpty else { return list.map { Row(conversation: $0, hit: nil) } }
        return store.search(state.messageSearch, in: list) { ConversationReadiness.headline(of: $0, agents: state.agents) }
            .compactMap { hit in store.conversation(hit.conversationID).map { Row(conversation: $0, hit: hit) } }
    }

    private var emptyText: String {
        if !state.messageSearch.trimmingCharacters(in: .whitespaces).isEmpty { return "没有匹配的对话" }
        if state.showsHiddenConversations { return "没有已隐藏的会话" }
        return state.messageFilter == .done ? "还没有已完成的对话" : "没有进行中的对话"
    }

    private func select(_ id: UUID, message: UUID?) {
        state.selectedConversationID = id
        state.conversations.markRead(id)
        state.messageJump = message.map { AppState.MessageJump(conversationID: id, messageID: $0) }
    }

    private func enterHidden() {
        state.showsHiddenConversations = true
        state.messageSearch = ""
    }

    private func leaveHidden() {
        state.showsHiddenConversations = false
        state.messageSearch = ""
    }

    private func move(_ delta: Int, in list: [Conversation]) {
        guard !list.isEmpty else { return }
        let current = list.firstIndex { $0.id == state.selectedConversationID } ?? (delta > 0 ? -1 : list.count)
        select(list[min(max(current + delta, 0), list.count - 1)].id, message: nil)
    }
}

/// `.filter-tabs`: 全部 / 进行中 / 已完成 with counts of the current view (hidden view counts the hidden ones).
private struct FilterTabs: View {
    let state: AppState
    let scoped: [Conversation]

    var body: some View {
        HStack(spacing: 4) {
            tab("全部", count: scoped.count, value: nil)
            ForEach(ConversationStatus.allCases, id: \.self) { status in
                tab(status.label, count: scoped.filter { $0.status == status }.count, value: status)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("messages.filters")
    }

    private func tab(_ title: String, count: Int, value: ConversationStatus?) -> some View {
        FilterTab(title: title, count: count, isOn: state.messageFilter == value,
                  identifier: "messages.filter.\(value?.rawValue ?? "all")") { state.messageFilter = value }
    }
}

private struct FilterTab: View {
    let title: String
    let count: Int
    let isOn: Bool
    let identifier: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(title).font(FormoraFont.ui(12, weight: 500)).foregroundStyle(isOn ? Palette.ink.color : Palette.inkMuted.color)
                Text("\(count)").font(FormoraFont.mono(12)).foregroundStyle(isOn ? Palette.inkMuted.color : Palette.inkFaint.color)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 6)
            .background(Capsule().fill(isOn ? Palette.surfaceRaised2.color : isHovering ? Palette.surfaceRaised.color : .clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }
}

/// `.conv-item`: avatar 40; line 1 name + time, line 2 last message (or the search hit's sentence), line 3 the
/// status badge and the task-name badge (spec §9.1).
private struct ConversationRow: View {
    let state: AppState
    let conversation: Conversation
    let snippet: String?
    let now: Date
    let action: () -> Void

    @State private var isHovering = false

    private var isSelected: Bool { state.selectedConversationID == conversation.id }

    var body: some View {
        let headline = ConversationReadiness.headline(of: conversation, agents: state.agents)
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                ConversationAvatar(state: state, conversation: conversation, size: 40)
                    .overlay(alignment: .topTrailing) {
                        if conversation.unread > 0 { UnreadDot(count: conversation.unread).offset(x: 3, y: -3) }
                    }
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(headline)
                            .font(FormoraFont.ui(13.5, weight: 600))
                            .foregroundStyle(Palette.ink.color)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text(ConversationText.timeLabel(conversation.updatedAt, now: now))
                            .font(FormoraFont.mono(11))
                            .foregroundStyle(Palette.inkFaint.color)
                    }
                    .frame(height: 20) // the web's line box at 13.5 × 1.5
                    let isReplying = state.chat.isRunning(conversation.id)
                    // An approval or a question (7d, D6): stuck on the user. Spec §9.8b: it takes the status badge's place
                    // in alert — 进行中 is the Agent busy, 等你确认 is waiting on you — and the line keeps saying what for.
                    let isWaiting = state.chat.approvals[conversation.id] != nil || state.chat.pendingQuestion(conversation.id) != nil
                        || state.chat.subtaskWaiting(conversation.id) != nil
                    Text(isReplying ? "正在回复…" : snippet ?? conversation.preview)
                        .font(FormoraFont.ui(12.5))
                        .foregroundStyle(isReplying ? Palette.accent.color : snippet == nil ? Palette.inkMuted.color : Palette.ink.color)
                        .lineLimit(1)
                        .frame(height: 19)
                        .padding(.top, 2)
                    HStack(spacing: 5) {
                        if isWaiting {
                            Badge(text: "等你确认", tone: .waiting)
                        } else {
                            Badge(text: conversation.status.label, tone: conversation.status == .done ? .done : .pending)
                        }
                        Badge(text: conversation.title, tone: .task)
                    }
                    .padding(.top, 6)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Palette.surfaceRaised2.color : isHovering ? Palette.surfaceRaised.color : .clear))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isSelected ? Palette.lineStrong.color : .clear, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .contextMenu { ConversationMenu(state: state, conversation: conversation) }
        .accessibilityLabel("\(headline)，\(conversation.title)，\(conversation.status.label)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("messages.row.\(conversation.title)")
    }
}

/// Spec §9.3 + C5: the whole-conversation actions, icon + text. Deleting is not here — only in 设置 → 归档.
private struct ConversationMenu: View {
    let state: AppState
    let conversation: Conversation

    var body: some View {
        if !conversation.isGroup, let agent = state.agents.agent(conversation.agentID) {
            Button { state.selectedAgentID = agent.id; state.agentTab = .overview; state.select(.agents) } label: {
                Label { Text("去 \(agent.displayName) 的详情") } icon: { Image(nsImage: Icons.arrowUpRight.templateImage()) }
            }
        }
        if conversation.isGroup {
            Button { state.groupDialog = .settings(conversation.id) } label: {
                Label { Text("群设置") } icon: { Image(nsImage: Icons.users.templateImage()) }
            }
        }
        let hidden = conversation.visibility == .hidden
        Button { hide(!hidden) } label: {
            Label { Text(hidden ? "取消隐藏" : "隐藏会话") } icon: { Image(nsImage: (hidden ? Icons.eye : Icons.eyeOff).templateImage()) }
        }
        Button { archive() } label: {
            Label { Text("归档会话") } icon: { Image(nsImage: Icons.archive.templateImage()) }
        }
    }

    /// Reversible and lossless, so no confirmation (spec §8.7 rule 3).
    private func hide(_ hide: Bool) {
        state.conversations.setVisibility(conversation.id, hide ? .hidden : .normal)
        state.toasts.show(hide ? "已隐藏" : "已取消隐藏",
                          note: hide ? "在列表底部「已隐藏的会话」里找到它" : "「\(conversation.title)」回到了消息列表", seconds: 2)
    }

    private func archive() {
        state.conversations.setVisibility(conversation.id, .archived)
        state.toasts.show("已归档", note: "在「设置 → 归档」里可以恢复或删除", seconds: 2)
    }
}

/// `.conv-drill`: 「已隐藏的会话 N ›」, or the 「‹ 返回消息」 row at the top of the hidden view.
private struct DrillRow: View {
    let isBack: Bool
    let count: Int
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                IconView(isBack ? Icons.chevronLeft : Icons.eyeOff, size: 15)
                Text(isBack ? "返回消息" : "已隐藏的会话").font(FormoraFont.ui(12.5))
                Spacer(minLength: 0)
                if !isBack {
                    Text("\(count)").font(FormoraFont.mono(10.5)).foregroundStyle(Palette.inkFaint.color)
                    IconView(Icons.chevronRight, size: 13)
                }
            }
            .foregroundStyle(isHovering ? Palette.ink.color : Palette.inkMuted.color)
            .padding(10)
            .background(UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: isBack ? 0 : 10,
                                               bottomTrailingRadius: isBack ? 0 : 10, topTrailingRadius: 10, style: .continuous)
                .fill(isHovering ? Palette.surfaceRaised.color : .clear))
            .overlay(alignment: .bottom) {
                if isBack { Rectangle().fill(Palette.line.color).frame(height: 1) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, isBack ? 0 : 4)
        .padding(.bottom, isBack ? 6 : 0)
        .onHover { isHovering = $0 }
        .accessibilityIdentifier(isBack ? "messages.hidden.back" : "messages.hidden.enter")
    }
}

/// `.badge`: mono 10.5 pill — 进行中 accent, 已完成 success, the task name neutral and capped at 190.
struct Badge: View {
    enum Tone { case pending, done, task, waiting }

    let text: String
    let tone: Tone

    var body: some View {
        Text(text)
            .font(FormoraFont.mono(10.5, weight: 500))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(minHeight: 18)
            .background(Capsule().fill(background))
            .frame(maxWidth: tone == .task ? 190 : nil, alignment: .leading)
            .fixedSize(horizontal: tone != .task, vertical: false)
    }

    private var foreground: Color {
        switch tone {
        case .pending: Palette.accent.color
        case .done: Palette.success.color
        case .task: Palette.inkMuted.color
        case .waiting: Palette.alert.color
        }
    }

    private var background: Color {
        switch tone {
        case .pending: Palette.accentSoft.color
        case .done: Palette.successSoft.color
        case .task: Palette.surfaceRaised2.color
        case .waiting: Palette.alertSoft.color
        }
    }
}

/// `.unread-dot`: alert pill with a mono count, ringed with the list's surface.
struct UnreadDot: View {
    let count: Int
    /// The ground it sits on, so it reads as cut out of the avatar or icon.
    var ring = Palette.surface.color

    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(FormoraFont.mono(9.5, weight: 700))
            .foregroundStyle(Palette.alertInk.color)
            .padding(.horizontal, 4)
            .frame(minWidth: 16, minHeight: 16)
            .background(Capsule().fill(Palette.alert.color))
            .overlay(Capsule().strokeBorder(ring, lineWidth: 2))
            .accessibilityLabel("\(count) 条未读")
    }
}
