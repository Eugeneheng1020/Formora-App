import AppKit
import SwiftUI

/// The files pane's chat (user 2026-09-22): the fourth column. An Agent picked at the top, the whole conversation printed
/// as a terminal (the board's 「运行过程」 look), the status line, 消息's own composer, and under it the file or folder
/// the next message carries. The conversation is one of 消息's — the one pinned for this Agent here (user 2026-09-23).
struct FileChatPanel: View {
    let state: AppState
    let session: ProjectSession

    private static let end = "files.chat.end"
    /// The end is on screen: the panel follows the run. Scrolled up, it stays where the user is.
    @State private var atEnd = true

    var body: some View {
        let project = session.current
        let agentID = project.flatMap { state.filesChatAgentID(project: $0.id) }
        let agent = state.agents.agent(agentID)
        let conversation = project.flatMap { state.filesChatConversation(project: $0.id) }
        VStack(spacing: 0) {
            header(agent: agent, agentID: agentID, project: project)
            if let conversation, let project {
                transcript(conversation)
                statusLine(conversation)
                ComposerView(state: state, session: session, conversation: conversation,
                             blockReason: ConversationReadiness.blockReason(of: conversation, agents: state.agents, currentProject: project,
                                                                            providers: state.providers),
                             carry: { [state] in state.filesChatCarries ? Self.carriedPath(state) : nil })
                carryTag
                    .padding(.horizontal, 22)
                    .padding(.top, -10)
                    .padding(.bottom, 14)
            } else {
                emptyBody(agent: agent, agentID: agentID, project: project)
            }
        }
        .frame(maxHeight: .infinity)
        .background(Palette.railGround.color)
        .overlay(alignment: .leading) { Rectangle().fill(Palette.line.color).frame(width: 1) }
        // The chosen Agent's conversation is pinned (user 2026-09-23); none (none yet, or 消息 archived it): start one, as
        // 发起对话 would.
        .task(id: [project?.id.uuidString ?? "", agentID?.uuidString ?? "", conversation?.id.uuidString ?? ""].joined(separator: "/")) {
            guard let project, agentID != nil else { return }
            state.ensureFilesChatConversation(project: project)
        }
        .onChange(of: conversation?.id, initial: true) { _, id in
            state.filesChatShownConversationID = id
            if let id { state.conversations.markRead(id) }
        }
        .onChange(of: conversation?.unread) { _, unread in
            if let id = conversation?.id, (unread ?? 0) > 0, NSApplication.shared.isActive { state.conversations.markRead(id) }
        }
        .onDisappear { state.filesChatShownConversationID = nil }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("files.chat")
    }

    // MARK: Header

    private func header(agent: AgentRecord?, agentID: UUID?, project: ProjectRecord?) -> some View {
        HStack(spacing: 8) {
            if let project {
                // The avatar stays outside the menu: a macOS `Menu` label shows an image or its text, not both.
                if let agent {
                    AgentAvatar(image: state.agents.avatars[agent.id], initial: agent.role.initial, size: 20, isMuted: !agent.isActive)
                }
                agentMenu(agent: agent, agentID: agentID, project: project)
            } else {
                Text("还没有打开项目").font(FormoraFont.ui(12)).foregroundStyle(Palette.inkFaint.color)
            }
            Spacer(minLength: 6)
            IconActionButton(icon: Icons.close, label: "关闭对话面板", identifier: "files.chat.close") { state.filesChatOpen = false }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: 44)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line.color).frame(height: 1) }
    }

    /// The project's Agents; one that can't take work is greyed with its reason on the next line — the same judgement as
    /// 发起对话 (spec §6.3). The one remembered but no longer here stays, greyed, never swapped for another (spec §0.3).
    private func agentMenu(agent: AgentRecord?, agentID: UUID?, project: ProjectRecord) -> some View {
        let candidates = state.agents.agents.filter { $0.projectIDs.contains(project.id) }
        let usable = candidates.contains { AgentReadiness.blockReason(of: $0, currentProject: project, providers: state.providers) == nil }
        return Menu {
            if !usable { Text("还没有能接活的 Agent，去「Agent」创建或配模型") }
            ForEach(candidates) { candidate in
                let reason = AgentReadiness.blockReason(of: candidate, currentProject: project, providers: state.providers)
                Button {
                    state.chooseFilesChatAgent(candidate.id, project: project)
                } label: {
                    if candidate.id == agentID {
                        Label(candidate.displayName, systemImage: "checkmark")
                    } else {
                        Text(candidate.displayName)
                    }
                }
                .disabled(reason != nil)
                if let reason { Text("　" + reason) }
            }
            if let agentID, !candidates.contains(where: { $0.id == agentID }) {
                Divider()
                Button(agent?.displayName ?? ConversationReadiness.deletedAgentName) {}.disabled(true)
                Text("　" + (agent == nil ? "这个 Agent 已被删除" : "在这个项目没有授权，去「Agent → 模型与权限」勾上"))
            }
        } label: {
            Text(agent?.displayName ?? (agentID == nil ? "选一个 Agent" : ConversationReadiness.deletedAgentName))
                .font(FormoraFont.ui(12, weight: 600))
                .foregroundStyle(agent == nil && agentID != nil ? Palette.inkFaint.color : Palette.ink.color)
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityIdentifier("files.chat.agent")
    }

    // MARK: Transcript

    /// The turn being written, when it is this conversation's.
    private func draft(_ conversation: Conversation) -> ChatRunner.Draft? {
        state.chat.isRunning(conversation.id) ? state.chat.drafts[conversation.id] : nil
    }

    private func transcript(_ conversation: Conversation) -> some View {
        let lines = CLITranscript.lines(conversation)
        let live = state.chat.isRunning(conversation.id)
        let draft = draft(conversation)
        return ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if lines.isEmpty, draft == nil {
                        // The identifier sits on the words, not the line: the mark's text would match it first.
                        CLILine(mark: " ", color: .clear) {
                            Text("还没有对话。发一句话，会带上你在文件树里点的文件。").foregroundStyle(Palette.inkFaint.color)
                                .accessibilityIdentifier("files.chat.empty")
                        }
                    }
                    ForEach(lines) { line in row(line, live: live) }
                    if let draft { LiveTurn(draft: draft, identifier: "files.chat.live") { follow(reader, live: live) } }
                    Color.clear
                        .frame(height: 1)
                        .id(Self.end)
                        .onAppear { atEnd = true }
                        .onDisappear { atEnd = false }
                }
                .font(FormoraFont.mono(CLIStyle.size))
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Opens at its end — twice, since the lazy rows only get their real heights once laid out (same as 「运行过程」).
            .onAppear { jumpToEnd(reader) }
            .onChange(of: conversation.id) { jumpToEnd(reader) }
            .onChange(of: conversation.messages.count) { follow(reader, live: true) }
        }
    }

    private func jumpToEnd(_ reader: ScrollViewProxy) {
        reader.scrollTo(Self.end, anchor: .bottom)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            reader.scrollTo(Self.end, anchor: .bottom)
        }
    }

    private func follow(_ reader: ScrollViewProxy, live: Bool) {
        guard atEnd, live else { return }
        reader.scrollTo(Self.end, anchor: .bottom)
    }

    @ViewBuilder private func row(_ line: CLITranscript.Line, live: Bool) -> some View {
        switch line.kind {
        case .user(let text):
            CLILine(mark: "›", color: Palette.accent.color) {
                Text(text.trimmingCharacters(in: .whitespacesAndNewlines)).foregroundStyle(Palette.ink.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("files.chat.user")
            }
            .padding(.top, 8)
        case .thinking(let text):
            CLILine(mark: "•", color: Palette.inkFaint.color) { ThinkingText(text: text) }
                .accessibilityIdentifier("files.chat.thinking")
        case .reply(let text):
            CLILine(mark: "•", color: Palette.ink.color) { MarkdownText(source: text, size: CLIStyle.size, mono: true) }
                .accessibilityIdentifier("files.chat.reply")
        case .step(let call):
            CLIStepLine(call: call, live: live, identifier: "files.chat.step")
        case .note(let text):
            CLILine(mark: " ", color: .clear) {
                Text(text).foregroundStyle(Palette.inkFaint.color).fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityIdentifier("files.chat.note")
        case .failure(let text):
            CLILine(mark: "✗", color: Palette.alert.color) {
                Text(text).foregroundStyle(Palette.alert.color).fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityIdentifier("files.chat.failure")
        }
    }

    // MARK: Status line

    private func statusLine(_ conversation: Conversation) -> some View {
        let running = state.chat.isRunning(conversation.id)
        let waiting = state.chat.approvals[conversation.id].flatMap { approval in
            conversation.messages.lazy.flatMap(\.toolCalls).first { $0.id == approval.callID }
        }
        let status = CLITranscript.status(conversation, running: running, waitingFor: waiting)
        return Group {
            if running {
                TimelineView(.periodic(from: .now, by: 1)) { context in statusContent(conversation, status: status, now: context.date) }
            } else {
                statusContent(conversation, status: status, now: .now)
            }
        }
        .font(FormoraFont.mono(11))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(Palette.line.color).frame(height: 1) }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("files.chat.status")
    }

    private func statusContent(_ conversation: Conversation, status: CLITranscript.Status, now: Date) -> some View {
        let numbers = CLITranscript.runNumbers(conversation, draft: draft(conversation), now: now)
        let text: String = switch status {
        case .idle, .waiting: status.label
        default: "\(status.label) · \(BoardFormat.seconds(numbers.seconds)) · \(ContextBudget.format(numbers.tokens)) token"
        }
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(status.mark).foregroundStyle(statusColor(status))
            Text(text).foregroundStyle(Palette.inkMuted.color).lineLimit(1).truncationMode(.middle)
        }
    }

    private func statusColor(_ status: CLITranscript.Status) -> Color {
        switch status {
        case .running, .waiting: Palette.accent.color
        case .done: Palette.success.color
        case .failed: Palette.alert.color
        case .idle, .stopped: Palette.inkFaint.color
        }
    }

    // MARK: Carry

    /// The entry last clicked in the tree, relative to the project — nothing until one was.
    private static func carriedPath(_ state: AppState) -> String? {
        guard let browser = state.files, let node = browser.lastChosen else { return nil }
        return ProjectSandbox(root: browser.root.url).relative(node.url)
    }

    @ViewBuilder private var carryTag: some View {
        if let node = state.files?.lastChosen, let path = Self.carriedPath(state) {
            let carries = state.filesChatCarries
            Button { state.filesChatCarries.toggle() } label: {
                HStack(spacing: 5) {
                    IconView(node.isFolder ? Icons.files : Icons.file, size: 11)
                    Text(carries ? path : "不带 · " + path).lineLimit(1).truncationMode(.middle)
                }
                .font(FormoraFont.mono(10))
                .foregroundStyle(carries ? Palette.inkMuted.color : Palette.inkFaint.color)
                .padding(.horizontal, 8)
                .frame(minHeight: 20)
                .background(Capsule().fill(carries ? Palette.surfaceRaised2.color : .clear))
                .overlay(Capsule().strokeBorder(carries ? .clear : Palette.line.color, lineWidth: 1))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(carries ? "这条消息会带上它，点一下就不带" : "这条消息不带它，点一下带上")
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(carries ? "携带 \(path)" : "不带 \(path)")
            .accessibilityIdentifier("files.chat.carry")
        }
    }

    // MARK: Empty

    private func emptyBody(agent: AgentRecord?, agentID: UUID?, project: ProjectRecord?) -> some View {
        let reason: String = if project == nil {
            "先打开一个项目"
        } else if agentID == nil {
            "选一个 Agent 开始"
        } else if let agent, let project {
            AgentReadiness.blockReason(of: agent, currentProject: project, providers: state.providers) ?? "正在打开对话…"
        } else {
            "这个 Agent 已被删除"
        }
        return CLILine(mark: " ", color: .clear) {
            Text(reason).foregroundStyle(Palette.inkFaint.color).accessibilityIdentifier("files.chat.empty")
        }
        .font(FormoraFont.mono(CLIStyle.size))
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
