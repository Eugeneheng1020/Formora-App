import SwiftUI

/// 10e: 修改 on a message of the user's own — its words in place of the bubble, and under them what going again does:
/// the thread from here folds away as an earlier version; the files the Agent changed since can go back with it (10d's
/// 撤销, newest first). ⌘↩ sends; esc leaves everything as it was.
struct MessageEditor: View {
    let state: AppState
    let session: ProjectSession
    let conversation: Conversation
    let message: Message

    @State private var text: String
    @State private var restoresFiles = false
    @State private var isSending = false

    init(state: AppState, session: ProjectSession, conversation: Conversation, message: Message) {
        self.state = state
        self.session = session
        self.conversation = conversation
        self.message = message
        _text = State(initialValue: message.text)
    }

    /// The replies and messages that fold away with it.
    private var following: Int {
        guard let index = conversation.messages.firstIndex(where: { $0.id == message.id }) else { return 0 }
        let after = conversation.messages[(index + 1)...].filter { !$0.isHidden && !$0.isUpkeep }
        let runs = Set(after.filter { $0.role == .agent }.map { $0.runID ?? $0.id })
        return runs.count + after.filter { $0.role == .user && $0.event == nil }.count
    }

    private var changedFiles: [String] {
        state.chat.changes(since: message.id, in: conversation.id).reduce(into: [String]()) { if !$0.contains($1.path) { $0.append($1.path) } }
    }

    private var canSend: Bool {
        !isSending && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !message.attachments.isEmpty)
    }

    private var height: CGFloat {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
        return min(200, max(66, CGFloat(lines) * 22 + 22))
    }

    var body: some View {
        let files = changedFiles
        let shape = UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12, bottomTrailingRadius: 12, topTrailingRadius: 4,
                                           style: .continuous)
        VStack(alignment: .leading, spacing: 10) {
            FormoraTextEditor(placeholder: "改成…", text: $text, height: height, identifier: "message.editText")
            Text(following == 0 ? "重新发送后，Agent 从这条开始重新做。"
                 : "重新发送后，这条之后的 \(following) 条回复和消息会收起，Agent 从这条开始重新做，不再看到它们。")
                .font(FormoraFont.ui(11.5))
                .foregroundStyle(Palette.inkMuted.color)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("message.edit.note")
            if !files.isEmpty { restoreRow(files) }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("取消") { state.editingMessage = nil }
                    .buttonStyle(FormoraButtonStyle(kind: .ghost))
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("message.edit.cancel")
                Button("重新发送") { send() }
                    .buttonStyle(FormoraButtonStyle(kind: .primary))
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canSend)
                    .accessibilityIdentifier("message.edit.send")
            }
        }
        .padding(12)
        .frame(maxWidth: 540)
        .background(shape.fill(Palette.surfaceRaised2.color))
        .overlay(shape.strokeBorder(Palette.accent.color, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("message.editor")
    }

    private func restoreRow(_ files: [String]) -> some View {
        Button { restoresFiles.toggle() } label: {
            HStack(alignment: .top, spacing: 8) {
                CheckBox(isOn: restoresFiles)
                VStack(alignment: .leading, spacing: 3) {
                    Text("同时把之后改过的 \(files.count) 个文件恢复原样")
                        .font(FormoraFont.ui(12.5))
                        .foregroundStyle(Palette.ink.color)
                    Text(files.prefix(3).joined(separator: "、") + (files.count > 3 ? " 等" : ""))
                        .font(FormoraFont.mono(10.5))
                        .foregroundStyle(Palette.inkFaint.color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("只恢复还是 Agent 改完那样的文件，之后你或别人又改过的不动。不恢复的话，Agent 会知道这些文件还是改过的样子。")
        .accessibilityLabel("同时把之后改过的 \(files.count) 个文件恢复原样")
        .accessibilityValue(restoresFiles ? "开" : "关")
        .accessibilityAddTraits(.isToggle)
        .accessibilityIdentifier("message.edit.restoreFiles")
    }

    private func send() {
        guard canSend else { return }
        isSending = true
        let root = session.accessibleRoot
        let name = session.current?.name
        Task {
            let reason = await state.resend(conversation.id, message: message.id, text: text, restoringFiles: restoresFiles,
                                            projectRoot: root, projectName: name)
            isSending = false
            if let reason {
                state.toasts.show("没有发送", note: reason, isError: true)
            } else {
                state.editingMessage = nil
            }
        }
    }
}

/// 10e: the line where the user went back, over the message that went again — and the way to what it replaced.
struct RewindDivider: View {
    let title: String
    let count: Int
    let isOpen: Bool
    let canOpen: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            rule
            Text(title)
                .font(FormoraFont.mono(10.5))
                .foregroundStyle(Palette.inkFaint.color)
                .lineLimit(1)
                .layoutPriority(1)
                .accessibilityIdentifier("rewind.title")
            if canOpen {
                SmallButton(title: isOpen ? "收起" : "看之前的版本（\(count) 条）", identifier: "rewind.toggle", action: toggle)
            }
            rule
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("event.rewind")
    }

    private var rule: some View {
        Rectangle().fill(Palette.line.color).frame(height: 1).frame(maxWidth: .infinity)
    }
}
