import SwiftUI

/// 看板's list (8b, K15): the project's conversations as chains — the same conversations as 消息, framed differently:
/// sorted failed and working first, the avatar the chain's state, the second line how many tasks are done.
struct BoardListColumn: View {
    let state: AppState
    let session: ProjectSession

    private struct Row {
        let conversation: Conversation
        let cards: [BoardCard]
        let chain: BoardChain.Status?
    }

    var body: some View {
        let all = state.boardConversations(project: session.current?.id)
        let rows = rows(all)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("看板")
                    .font(FormoraFont.ui(19, weight: 700))
                    .tracking(-0.19)
                    .foregroundStyle(Palette.ink.color)
                    .frame(height: 26, alignment: .leading)
                    .padding(.bottom, 14)
                    .accessibilityIdentifier("list.title")
                if !all.isEmpty {
                    SearchField(placeholder: "搜索对话、成员、任务", text: Binding(get: { state.boardSearch }, set: { state.boardSearch = $0 }),
                                identifier: "board.search")
                        .padding(.bottom, 12)
                }
            }
            .padding(.top, 16)
            .padding(.horizontal, 18)

            TimelineView(.everyMinute) { context in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(rows, id: \.conversation.id) { row in
                            BoardRow(state: state, conversation: row.conversation, cards: row.cards, chain: row.chain, now: context.date) {
                                state.selectBoardConversation(row.conversation.id)
                            }
                        }
                        if rows.isEmpty {
                            // 「本来就没有」和「筛过之后没有」 say different things (spec checklist 13).
                            Text(all.isEmpty ? "这个项目下还没有对话" : "没有匹配的对话")
                                .font(FormoraFont.ui(12))
                                .foregroundStyle(Palette.inkFaint.color)
                                .padding(.vertical, 34)
                                .frame(maxWidth: .infinity)
                                .accessibilityIdentifier("board.noMatch")
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
            .accessibilityIdentifier("board.list")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.surface.color)
        .overlay(alignment: .trailing) { Rectangle().fill(Palette.line.color).frame(width: 1) }
        // No silent 「the first one」 when the selection isn't here (spec checklist 35): a project switch reselects, openly.
        .onAppear { reselect(rows.map(\.conversation.id)) }
        .onChange(of: rows.map(\.conversation.id)) { _, ids in reselect(ids) }
    }

    /// Search by the chain's name, the conversation's title, its members and its cards (K15); failed and working
    /// first, the newest first within.
    private func rows(_ conversations: [Conversation]) -> [Row] {
        let query = FileSearch.normalize(state.boardSearch.trimmingCharacters(in: .whitespaces))
        let rank: (BoardChain.Status?) -> Int = { status in
            switch status {
            case .failed: 0
            case .working: 1
            case .done: 2
            case nil: 3
            }
        }
        return conversations.compactMap { conversation -> Row? in
            let cards = state.boardCards(conversation)
            if !query.isEmpty {
                let members = ConversationReadiness.members(of: conversation, agents: state.agents).map(\.displayName)
                let haystack = ([BoardHeadline.of(conversation, agents: state.agents), conversation.title] + members + cards.map(\.title))
                    .joined(separator: " ")
                guard FileSearch.normalize(haystack).contains(query) else { return nil }
            }
            return Row(conversation: conversation, cards: cards, chain: BoardChain.status(cards))
        }
        .enumerated()
        .sorted { rank($0.element.chain) != rank($1.element.chain) ? rank($0.element.chain) < rank($1.element.chain) : $0.offset < $1.offset }
        .map(\.element)
    }

    private func reselect(_ ids: [UUID]) {
        guard !ids.contains(where: { $0 == state.boardConversationID }) else { return }
        state.selectBoardConversation(ids.first)
    }

    private func move(_ delta: Int, in list: [Conversation]) {
        guard !list.isEmpty else { return }
        let index = list.firstIndex { $0.id == state.boardConversationID } ?? -1
        state.selectBoardConversation(list[max(0, min(list.count - 1, index + delta))].id)
    }
}

/// What a chain is called (spec §9 v4): a group by its stable name, a direct chat by its task — the row's own name
/// (spec checklist 20), never just 「和谁聊」.
enum BoardHeadline {
    static func of(_ conversation: Conversation, agents: AgentStore) -> String {
        if conversation.isGroup, !conversation.groupName.isEmpty { return conversation.groupName }
        return conversation.title
    }
}

private struct BoardRow: View {
    let state: AppState
    let conversation: Conversation
    let cards: [BoardCard]
    let chain: BoardChain.Status?
    let now: Date
    let action: () -> Void

    @State private var isHovering = false

    private var isSelected: Bool { state.boardConversationID == conversation.id }

    var body: some View {
        let headline = BoardHeadline.of(conversation, agents: state.agents)
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                ChainAvatar(state: state, conversation: conversation, chain: chain)
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
                    .frame(height: 20)
                    Text(BoardChain.line(cards))
                        .font(FormoraFont.ui(12.5))
                        .foregroundStyle(Palette.inkMuted.color)
                        .lineLimit(1)
                        .frame(height: 19)
                        .padding(.top, 2)
                    HStack(spacing: 5) {
                        Badge(text: conversation.isGroup ? "群聊" : "单聊", tone: chain == .done ? .done : .pending)
                        // An upgraded chat is named by its task (K14): the name once, not twice.
                        if conversation.isGroup, conversation.title != headline { Badge(text: conversation.title, tone: .task) }
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
        .accessibilityLabel("\(headline)，\(BoardChain.line(cards))")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("board.row.\(conversation.title)")
    }
}

/// The chain's state as the row's avatar (K15): ! for a failure, dots while any is under way, ✓ when all are done,
/// the conversation's own avatar when there is nothing on the board yet.
private struct ChainAvatar: View {
    let state: AppState
    let conversation: Conversation
    let chain: BoardChain.Status?

    var body: some View {
        switch chain {
        case nil:
            ConversationAvatar(state: state, conversation: conversation, size: 40)
        case .failed:
            tile(IconView(Icons.alertCircle, size: 18).foregroundStyle(Palette.alert.color), fill: Palette.alertSoft.color)
        case .done:
            tile(IconView(Icons.check, size: 18).foregroundStyle(Palette.success.color), fill: Palette.successSoft.color)
        case .working:
            tile(HStack(spacing: 3) { ForEach(0..<3, id: \.self) { _ in Circle().fill(Palette.accent.color).frame(width: 4, height: 4) } },
                 fill: Palette.accentSoft.color)
        }
    }

    private func tile<Content: View>(_ content: Content, fill: Color) -> some View {
        content
            .frame(width: 40, height: 40)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(fill))
    }
}
