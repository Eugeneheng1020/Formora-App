import SwiftUI

/// The composer's dock of decisions (user 2026-09-15; spec §5): whatever waits for the user sits here, in 消息 and over the
/// board alike — a step waiting for 允许 / 拒绝, a question, a reply's numbered ways, 方案出来了, 要继续吗, 重试. Cards in the
/// thread and the board's 「运行过程」 only tell. `focus` is the board's focused run; `pick` sends a choice as the user's words.
struct DecisionDock: View {
    let state: AppState
    let session: ProjectSession
    let conversation: Conversation
    var focus: UUID? = nil
    let pick: (String) -> Void

    private var id: UUID { conversation.id }
    private var isRunning: Bool { state.chat.isRunning(id) }
    private var question: (message: Message, call: ToolCall, questions: [AskTool.Question])? { state.chat.pendingQuestion(id) }
    private var approval: Decisions.PendingApproval? {
        Decisions.approval(for: conversation, focus: focus, subtasks: state.conversations.subtasks(of: id), approvals: state.chat.approvals)
    }
    private var projectRoot: URL? { session.current?.id == conversation.projectID ? session.accessibleRoot : nil }
    private var projectName: String? { session.projects.first { $0.id == conversation.projectID }?.name }

    var body: some View {
        if let approval {
            ApprovalPanel(state: state, pending: approval)
                .id(approval.call.id)
                .padding(.bottom, 10)
        } else if let pending = question {
            AskPanel(state: state, conversationID: id, questions: pending.questions)
                .id(pending.call.id)
                .padding(.bottom, 10)
        } else if let choices = Decisions.choices(conversation, isRunning: isRunning, hasQuestion: false, hasApproval: false,
                                                  dismissed: state.dismissedChoices) {
            ChoicePanel(found: choices.found, dismiss: { state.dismissedChoices.insert(choices.messageID) },
                        pick: { pick(ProseChoices.reply($0)) })
                .id(choices.messageID)
                .padding(.bottom, 10)
        }
        if Decisions.planAwaitsApproval(conversation, isRunning: isRunning, hasQuestion: question != nil) {
            PlanApprovalCard { state.executePlan(id, projectRoot: projectRoot, projectName: projectName) }
                .padding(.bottom, 10)
        } else if let pause = Decisions.pause(conversation, isRunning: isRunning) {
            PauseCard(reason: pause) { state.chat.resume(id) }
                .padding(.bottom, 10)
        } else if let failure = Decisions.failure(conversation, isRunning: isRunning) {
            RetryPanel(reason: failure) { state.chat.retry(id) }
                .padding(.bottom, 10)
        }
    }
}

/// 等你确认 above the composer (D34, D79; user 2026-09-15): what the step will do, the whole command, the change it would
/// make, Bob's word on the risk, and the answers — 拒绝 / 允许, 这个对话里都允许, 以后这个项目里都不再问.
struct ApprovalPanel: View {
    let state: AppState
    let pending: Decisions.PendingApproval

    private var call: ToolCall { pending.call }
    private var reason: String? { pending.approval.reason }
    /// A helper's step (S6): whose.
    private var helperName: String? {
        guard let subtaskID = pending.subtaskID, let subtask = state.conversations.conversation(subtaskID) else { return nil }
        return state.agents.agent(subtask.agentID)?.displayName ?? ConversationReadiness.deletedAgentName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(helperName.map { "需要你确认 · \($0) 的一步" } ?? "需要你确认")
                .font(FormoraFont.mono(10))
                .foregroundStyle(Palette.accent.color)
                .accessibilityIdentifier("approval.title")
            HStack(spacing: 8) {
                IconView(ToolCallCard.icon(for: call.name), size: 13).foregroundStyle(Palette.inkMuted.color)
                Text(call.summary)
                    .font(FormoraFont.mono(11.5))
                    .foregroundStyle(Palette.ink.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("approval.summary")
            }
            Text(ApprovalText.what(call, reason: reason))
                .font(FormoraFont.ui(12))
                .foregroundStyle(reason == nil ? Palette.inkMuted.color : Palette.alert.color)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("approval.text")
            if let risk = pending.approval.risk {
                Text("Bob：\(risk)")
                    .font(FormoraFont.ui(11.5))
                    .foregroundStyle(Palette.inkMuted.color)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("approval.risk")
            }
            // The whole command, as it will run: that is what is being allowed.
            if let command = ApprovalText.command(call) {
                HStack(alignment: .top, spacing: 6) {
                    CopyIcon(text: command) { CopyButton.copy($0, state: state) }.padding(.top, -1)
                    Text(command)
                        .font(FormoraFont.mono(11.5))
                        .foregroundStyle(Palette.ink.color)
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("approval.command")
                }
                .padding(.vertical, 9)
                .padding(.horizontal, 9)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.surfaceRaised.color))
            }
            // 10d: the change itself, as it would land.
            if let preview = pending.approval.preview {
                DiffText(text: preview, maxHeight: 220).accessibilityIdentifier("approval.preview")
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("拒绝") { state.chat.decide(pending.runID, allow: false) }
                    .buttonStyle(FormoraButtonStyle(kind: .ghost))
                    .accessibilityIdentifier("approval.deny")
                // 10b: the same step again in this conversation goes ahead.
                if pending.approval.grant != nil {
                    Button("这个对话里都允许") { state.chat.decide(pending.runID, .conversation) }
                        .buttonStyle(FormoraButtonStyle())
                        .accessibilityIdentifier("approval.allowConversation")
                }
                Button("允许") { state.chat.decide(pending.runID, allow: true) }
                    .buttonStyle(FormoraButtonStyle(kind: .primary))
                    .accessibilityIdentifier("approval.allow")
            }
            // 10b: remembered for the project — listed, and removable, in 管理项目.
            if let grant = pending.approval.grant {
                HStack {
                    Spacer(minLength: 0)
                    Button { state.chat.decide(pending.runID, .project) } label: {
                        Text("以后这个项目里都不再问：\(ApprovalGrants.label(grant))")
                            .font(FormoraFont.ui(11.5))
                            .foregroundStyle(Palette.accent.color)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("approval.allowProject")
                }
            }
        }
        .padding(.vertical, 13)
        .padding(.horizontal, 14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.surface.color))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.accent.color, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("approval.panel")
    }
}

/// A reply's numbered ways as a card (user 2026-09-15): the same option cards as a question, the recommended one marked;
/// a pick is sent in the user's words. × puts it away — the words stay in the thread.
struct ChoicePanel: View {
    let found: ProseChoices.Found
    let dismiss: () -> Void
    let pick: (ProseChoices.Choice) -> Void

    @State private var cursor: Int?
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("它给了几个方案")
                        .font(FormoraFont.mono(10))
                        .foregroundStyle(Palette.accent.color)
                    Text(found.prompt)
                        .font(FormoraFont.ui(13, weight: 600))
                        .foregroundStyle(Palette.ink.color)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("choices.prompt")
                }
                Spacer(minLength: 0)
                IconActionButton(icon: Icons.close, label: "收起", identifier: "choices.dismiss", action: dismiss)
            }
            .padding(.bottom, 10)
            VStack(spacing: 6) {
                ForEach(Array(found.choices.enumerated()), id: \.offset) { offset, choice in
                    AskOptionButton(option: AskTool.Option(label: "\(choice.number). \(choice.label)", description: choice.description),
                                    isRecommended: found.recommended == offset, isMulti: false, isSelected: false,
                                    isOn: isFocused && cursor == offset) { pick(choice) }
                }
            }
            Text("也可以直接在下面输入框里说，不一定要选这几个。")
                .font(FormoraFont.ui(11))
                .foregroundStyle(Palette.inkFaint.color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 9)
        }
        .padding(.vertical, 13)
        .padding(.horizontal, 14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.surface.color))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.lineStrong.color, lineWidth: 1))
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { move(-1) }
        .onKeyPress(.downArrow) { move(1) }
        .onKeyPress(.return) {
            guard let cursor, found.choices.indices.contains(cursor) else { return .ignored }
            pick(found.choices[cursor])
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("choices.panel")
    }

    private func move(_ step: Int) -> KeyPress.Result {
        let count = found.choices.count
        cursor = ((cursor ?? (step > 0 ? -1 : 0)) + step + count) % count
        return .handled
    }
}

/// 回复中断 above the composer (L3; user 2026-09-15): why, and 重试. The reply's own card in the thread keeps the reason.
struct RetryPanel: View {
    let reason: String
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                IconView(Icons.alertCircle, size: 14)
                Text("回复中断").font(FormoraFont.ui(12.5, weight: 700))
            }
            .foregroundStyle(Palette.alert.color)
            Text(reason)
                .font(FormoraFont.ui(12))
                .foregroundStyle(Palette.inkMuted.color)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer(minLength: 0)
                Button("重试", action: retry)
                    .buttonStyle(FormoraButtonStyle(kind: .primary))
                    .accessibilityIdentifier("reply.retry")
            }
        }
        .padding(.vertical, 13)
        .padding(.horizontal, 14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.alertSoft.color))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.alertLine.color, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("retry.panel")
    }
}
