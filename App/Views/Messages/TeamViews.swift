import SwiftUI

/// A line the runner wrote between turns (7g): a dispatch, a hand-off, a round, a goal's check, an end. Centred and
/// quiet like the compaction's divider (E5), the brief or the reasons under it.
struct EventDivider: View {
    let state: AppState
    let event: ThreadEvent
    /// The thread it is in: a direct chat's upgrade offers 重命名 there (8d; mockup `dividerHtml`).
    var conversationID: UUID? = nil
    /// The message carrying it: a memory line's 撤销 names it (user 2026-09-17).
    var messageID: UUID? = nil

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                rule
                Text(event.title)
                    .font(FormoraFont.mono(10.5))
                    .foregroundStyle(color)
                    .strikethrough(event.undone == true)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                    .accessibilityIdentifier("event.title")
                if let subtaskID = event.subtaskID, state.conversations.conversation(subtaskID) != nil {
                    SmallButton(title: "看复核过程", identifier: "event.subtask") { state.selectedConversationID = subtaskID }
                }
                // What it remembered is said where the user reads, and taken back right there (user 2026-09-17).
                if event.kind == .memory, let conversationID, let messageID {
                    if event.undone == true {
                        Text("已撤销").font(FormoraFont.ui(11)).foregroundStyle(Palette.inkFaint.color)
                            .accessibilityIdentifier("event.memory.undone")
                    } else {
                        SmallButton(title: "撤销", identifier: "event.memory.undo") { state.chat.undoMemory(messageID, in: conversationID) }
                    }
                }
                // No dialog at the `@` (it is frequent), but the name the group took can be changed right here.
                if event.kind == .upgrade, event.agentID != nil, let conversationID {
                    SmallButton(title: "重命名", identifier: "event.rename") { state.groupDialog = .settings(conversationID) }
                }
                rule
            }
            if !event.detail.isEmpty {
                Text(event.detail)
                    .font(FormoraFont.ui(11.5))
                    .foregroundStyle(Palette.inkMuted.color)
                    .lineSpacing(3)
                    .lineLimit(4)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 560)
                    .accessibilityIdentifier("event.detail")
            }
            if event.kind == .conduct, let plan = event.arrangement, !plan.lanes.isEmpty {
                LaneStrips(state: state, lanes: plan.lanes)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("event.\(event.kind.rawValue)")
    }

    private var rule: some View {
        Rectangle().fill(Palette.line.color).frame(height: 1).frame(maxWidth: .infinity)
    }

    private var color: Color {
        switch event.passed {
        case true: Palette.success.color
        case false: Palette.alert.color
        default: Palette.inkFaint.color
        }
    }
}

/// D (9e): Bob's conclusion from members who worked side by side — quiet, on the left like a reply, read in full.
struct SummaryCard: View {
    let event: ThreadEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(event.title)
                .font(FormoraFont.ui(11.5, weight: 600))
                .foregroundStyle(Palette.inkMuted.color)
            MarkdownText(source: event.detail)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .frame(maxWidth: 640, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.surfaceRaised.color))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.line.color, lineWidth: 1))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("event.summary")
    }
}

/// Over the composer while Agents work on their own (7g, M4, A4; spec §9.8c): what is going on, and 停止 — which
/// doesn't scroll away with the thread.
struct TeamBanner: View {
    let title: String
    let detail: String?
    let stop: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(FormoraFont.ui(12.5, weight: 600))
                    .foregroundStyle(Palette.ink.color)
                    .accessibilityIdentifier("team.banner.title")
                if let detail {
                    Text(detail)
                        .font(FormoraFont.ui(11))
                        .foregroundStyle(Palette.inkMuted.color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            Button("停止", action: stop)
                .buttonStyle(FormoraButtonStyle(kind: .ghost))
                .accessibilityIdentifier("team.stop")
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.accentSoft.color))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.accent.color.opacity(0.35), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("team.banner")
    }
}

/// A delegate call (S8): the ordinary card — its report folded — and under it the helper at work: who, the task, status
/// and tokens, 打开子任务, and word of a call of theirs waiting for 允许 / 拒绝 above the composer (S6).
struct DelegateCard: View {
    let state: AppState
    let call: ToolCall
    let phase: ToolCallCard.Phase

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ToolCallCard(call: call, phase: phase)
            if let subtask = state.conversations.conversation(call.subtaskID) {
                SubtaskStrip(state: state, subtask: subtask)
            }
        }
    }
}

/// The lanes at work under their arrangement's line (9e): who, how far, 看过程, and word of a step waiting for 允许 / 拒绝
/// above the composer. A lane that is done leaves: its reply is in the thread.
private struct LaneStrips: View {
    let state: AppState
    let lanes: [ThreadEvent.Arrangement.Lane]

    var body: some View {
        let live = lanes.compactMap { state.conversations.conversation($0.subtaskID) }.filter { state.chat.isRunning($0.id) }
        if !live.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(live) { SubtaskStrip(state: state, subtask: $0) }
            }
            .frame(maxWidth: 560)
            .accessibilityIdentifier("event.lanes")
        }
    }
}

private struct SubtaskStrip: View {
    let state: AppState
    let subtask: Conversation

    private var helper: AgentRecord? { state.agents.agent(subtask.agentID) }
    private var isClone: Bool { subtask.parent?.requesterID == subtask.agentID }
    private var isRunning: Bool { state.chat.isRunning(subtask.id) }

    /// The helper's call waiting for the user, if any — decided above the composer (user 2026-09-15).
    private var waiting: ToolCall? {
        guard let approval = state.chat.approvals[subtask.id] else { return nil }
        return subtask.messages.first { $0.id == approval.messageID }?.toolCalls.first { $0.id == approval.callID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                AgentAvatar(image: helper.flatMap { state.agents.avatars[$0.id] }, initial: helper?.role.initial ?? "?", size: 22,
                            isMuted: helper == nil)
                Text(name)
                    .font(FormoraFont.ui(12, weight: 600))
                    .foregroundStyle(Palette.ink.color)
                    .lineLimit(1)
                Text(status)
                    .font(FormoraFont.ui(11))
                    .foregroundStyle(isRunning ? Palette.accent.color : Palette.inkFaint.color)
                    .lineLimit(1)
                    .accessibilityIdentifier("subtask.status")
                Spacer(minLength: 8)
                SmallButton(title: subtask.isLane ? "看过程" : "打开子任务", identifier: "subtask.open") { state.selectedConversationID = subtask.id }
            }
            if let waiting {
                Text("等你确认：\(waiting.summary) · 在输入框上方")
                    .font(FormoraFont.mono(11))
                    .foregroundStyle(Palette.accent.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("subtask.waiting")
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.surfaceRaised.color))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("subtask.strip")
    }

    private var name: String {
        guard let helper else { return ConversationReadiness.deletedAgentName }
        return isClone ? "\(helper.displayName) 的分身" : helper.displayName
    }

    private var status: String {
        let tokens = Subtasks.tokens(subtask)
        let used = tokens > 0 ? " · 约 \(ContextBudget.format(tokens)) token" : ""
        if waiting != nil { return "等你确认" + used }
        return (isRunning ? "进行中" : "已结束") + used
    }
}

/// A subtask's header (S8): whose it is, and the way back to where it came from.
struct SubtaskBackButton: View {
    let state: AppState
    let link: SubtaskLink

    var body: some View {
        Button {
            state.selectedConversationID = link.conversationID
        } label: {
            HStack(spacing: 4) {
                IconView(Icons.chevronRight, size: 10).rotationEffect(.degrees(180))
                Text(link.isCheck ? "复核 · 返回" : link.lane == true ? "返回群聊「\(link.requesterName)」" : "\(link.requesterName) 的子任务 · 返回")
                    .font(FormoraFont.ui(11.5))
                    .lineLimit(1)
            }
            .foregroundStyle(Palette.inkMuted.color)
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.surfaceRaised.color))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("subtask.back")
    }
}
