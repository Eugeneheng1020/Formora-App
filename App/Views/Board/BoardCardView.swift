import SwiftUI

/// One task card (8b, K6, K12; mockup `renderTaskCard`): who, the task, its state and 💬; then what came out — the
/// output's first lines, its files, and 耗时 / token / 回复次数. The body focuses; 💬 and a file row jump.
struct BoardCardView: View {
    let state: AppState
    let conversation: Conversation
    let card: BoardCard
    let isFocused: Bool
    /// The keyboard's place on the canvas (K10).
    let isKeyboard: Bool

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                AgentAvatar(image: state.agents.avatars[card.agentID], initial: initial, size: 24)
                Text(card.agentName)
                    .font(FormoraFont.ui(13.5, weight: 600))
                    .foregroundStyle(Palette.ink.color)
                    .lineLimit(1)
                    // Who does it is read first, then its state: a long 「等待 … 完成」 gives way, not the name (9e).
                    .layoutPriority(2)
                Spacer(minLength: 0)
                StatusPill(status: card.status).layoutPriority(1)
                IconActionButton(icon: Icons.messages, label: card.subtaskID == nil ? "跳到对话" : "打开这个子任务",
                                 identifier: "board.card.chat") { openConversation() }
            }
            .padding(.bottom, 10)
            Text(card.title)
                .font(FormoraFont.ui(12.5))
                .foregroundStyle(Palette.inkMuted.color)
                .lineLimit(1)
                .padding(.bottom, 12)
            // Nothing came out yet (待开始): no empty numbers under the task.
            if !card.summary.isEmpty || !card.files.isEmpty || card.replies > 0 { output }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 18)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(isFocused ? Palette.surfaceRaised.color : Palette.surface.color))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(isFocused ? Palette.accent.color : isHovering ? Palette.inkFaint.color : Palette.lineStrong.color, lineWidth: 1))
        .overlay {
            if isKeyboard {
                RoundedRectangle(cornerRadius: 17, style: .continuous).strokeBorder(Palette.accent.color, lineWidth: 2).padding(-3)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("任务 \(card.title)，\(card.status.label)，由\(card.agentName)处理")
        .accessibilityIdentifier("board.card.\(card.id)")
    }

    /// What came out: the output's first lines, every file, the numbers.
    private var output: some View {
            VStack(alignment: .leading, spacing: 10) {
                if !card.summary.isEmpty {
                    Text(card.summary)
                        .font(FormoraFont.ui(12))
                        .foregroundStyle(Palette.inkMuted.color)
                        .lineSpacing(3)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Every file the run wrote (old D55): a file row is a jump, never a dropped fact.
                ForEach(card.files, id: \.self) { path in FileRow(path: path) { state.openBoardFile(path) } }
                HStack(spacing: 6) {
                    SmallTag(text: BoardFormat.seconds(card.seconds))
                    SmallTag(text: "\(ContextBudget.format(card.tokens)) token")
                    SmallTag(text: "\(card.replies) 次回复")
                }
            }
            .padding(.top, 12)
            .overlay(alignment: .top) { Rectangle().fill(Palette.line.color).frame(height: 1) }
    }

    private var initial: String {
        state.agents.agent(card.agentID)?.role.initial ?? String(card.agentName.prefix(1))
    }

    /// A delegation's or a check's 💬 opens its subtask; the others their message in the thread.
    private func openConversation() {
        if let subtask = card.subtaskID {
            state.openConversation(subtask)
        } else {
            state.openConversation(conversation.id, jumpTo: card.messageID)
        }
    }
}

/// `.stage-status`: the label in its tier's colour (K5).
struct StatusPill: View {
    let status: BoardCard.Status

    var body: some View {
        Text(status.label)
            .font(FormoraFont.mono(10))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(Capsule().fill(background))
            // The short labels keep their size; a waiting step's names may shorten (9e).
            .fixedSize(horizontal: !isQueued, vertical: true)
            .accessibilityIdentifier("board.card.status")
    }

    private var isQueued: Bool {
        if case .queued = status { return true }
        return false
    }

    private var foreground: Color {
        switch status.tier {
        case .neutral: Palette.inkFaint.color
        case .active: Palette.accent.color
        case .success: Palette.success.color
        case .alert: Palette.alert.color
        }
    }

    private var background: Color {
        switch status.tier {
        case .neutral: Palette.surfaceRaised2.color
        case .active: Palette.accentSoft.color
        case .success: Palette.successSoft.color
        case .alert: Palette.alertSoft.color
        }
    }
}

/// `.task-card-file`: the path, a jump to 文件.
private struct FileRow: View {
    let path: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                IconView(Icons.file, size: 15).foregroundStyle(Palette.accent.color)
                Text(path)
                    .font(FormoraFont.mono(11.5))
                    .foregroundStyle(isHovering ? Palette.ink.color : Palette.inkMuted.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isHovering ? Palette.surfaceRaised2.color : Palette.surfaceRaised.color))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(isHovering ? Palette.lineStrong.color : Palette.line.color, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("在文件中查看 \(path)")
        .accessibilityIdentifier("board.card.file")
    }
}

enum BoardFormat {
    /// `8s`, `2m 05s`, `1h 12m`.
    static func seconds(_ value: Double) -> String {
        let total = Int(value.rounded())
        if total < 60 { return "\(total)s" }
        if total < 3600 { return String(format: "%dm %02ds", total / 60, total % 60) }
        return String(format: "%dh %02dm", total / 3600, (total % 3600) / 60)
    }
}
