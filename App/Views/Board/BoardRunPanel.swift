import SwiftUI

/// 「运行过程」 (8c; 9c, R1–R4): the focused card's whole run as a small terminal, printed the way omp and Codex print one
/// — `›` the user's words, `•` thinking in dim italic (never folded), `•` the Agent's words, `•` a step with `└` what came
/// back — streaming while it runs, a status line at the bottom. Over the canvas on the right, 380 pt: no fourth column.
struct BoardRunPanel: View {
    let state: AppState
    let card: BoardCard
    /// Where the card's run happens: the conversation, or a delegation's subtask.
    let runIn: UUID

    static let width: CGFloat = 380
    /// Clear of the title above and of the composer's place below (mockup `.task-popover`).
    static let top: CGFloat = 74
    static let bottom: CGFloat = 148
    static let edge: CGFloat = 28
    /// The terminal's one size.
    static let size: CGFloat = 11.5

    private static let end = "board.run.end"

    /// The end is on screen: the panel follows the run. Scrolled up, it stays where the user is (R3).
    @State private var atEnd = true

    /// The model's turn being written, when it is this card's.
    private var draft: ChatRunner.Draft? {
        guard BoardRun.isLive(card.status), let draft = state.chat.drafts[runIn], draft.agentID == card.agentID else { return nil }
        return draft
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        headline
                        ForEach(Array(card.entries.enumerated()), id: \.offset) { _, entry in row(entry) }
                        if let draft { LiveTurn(draft: draft) { follow(reader) } }
                        if card.entries.isEmpty, draft == nil {
                            CLILine(mark: " ", color: .clear) { Text("还没有执行记录。").foregroundStyle(Palette.inkFaint.color) }
                        }
                        Color.clear
                            .frame(height: 1)
                            .id(Self.end)
                            .onAppear { atEnd = true }
                            .onDisappear { atEnd = false }
                    }
                    .font(FormoraFont.mono(Self.size))
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // A run under way opens at its end; a finished one at its start.
                .onAppear { if BoardRun.isLive(card.status) { reader.scrollTo(Self.end, anchor: .bottom) } }
                .onChange(of: card.entries) { _, _ in follow(reader) }
            }
            statusLine
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(Palette.railGround.color)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.lineStrong.color, lineWidth: 1))
        // The shape casts the shadow, not the content (9a): a shadow of the content was redrawn with every line.
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.railGround.color).softShadow())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("运行过程：\(card.title)")
        .accessibilityIdentifier("board.run")
    }

    private func follow(_ reader: ScrollViewProxy) {
        guard atEnd, BoardRun.isLive(card.status) else { return }
        reader.scrollTo(Self.end, anchor: .bottom)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("运行过程").font(FormoraFont.mono(12, weight: 600)).foregroundStyle(Palette.ink.color)
            Text(card.agentName).font(FormoraFont.mono(11)).foregroundStyle(Palette.inkFaint.color).lineLimit(1)
            Spacer(minLength: 6)
            IconActionButton(icon: Icons.close, label: "关闭", identifier: "board.run.close") { state.boardFocus = nil }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line.color).frame(height: 1) }
    }

    /// The task, and who with how many steps: one `•` whose colour is the state (omp).
    private var headline: some View {
        VStack(alignment: .leading, spacing: 2) {
            CLILine(mark: "•", color: dot(card.status)) {
                Text(card.title).fontWeight(.semibold).foregroundStyle(Palette.ink.color)
            }
            Text(BoardRun.stats(card))
                .foregroundStyle(Palette.inkFaint.color)
                .padding(.leading, 16)
        }
        .padding(.bottom, 8)
        .accessibilityIdentifier("board.run.headline")
    }

    @ViewBuilder private func row(_ entry: BoardCard.Entry) -> some View {
        switch entry.kind {
        case let .said(speaker, text, isUser):
            if isUser {
                CLILine(mark: "›", color: Palette.accent.color) {
                    Text(text.trimmingCharacters(in: .whitespacesAndNewlines)).foregroundStyle(Palette.ink.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 8)
                .accessibilityIdentifier("board.run.user")
            } else if speaker == card.agentName {
                CLILine(mark: "•", color: Palette.ink.color) { MarkdownText(source: text, size: Self.size, mono: true) }
                    .accessibilityIdentifier("board.run.said")
            } else {
                // A brief handed over: who handed it, then the brief.
                CLILine(mark: "›", color: Palette.inkFaint.color) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(speaker).foregroundStyle(Palette.inkFaint.color)
                        Text(text.trimmingCharacters(in: .whitespacesAndNewlines)).foregroundStyle(Palette.inkMuted.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 8)
                .accessibilityIdentifier("board.run.brief")
            }
        case .thinking(let text):
            CLILine(mark: "•", color: Palette.inkFaint.color) { ThinkingText(text: text) }
                .accessibilityIdentifier("board.run.thinking")
        case .step(let call):
            step(call)
        case .line(let text):
            CLILine(mark: " ", color: .clear) { Text(text).foregroundStyle(Palette.inkFaint.color) }
                .accessibilityIdentifier("board.run.line")
        }
    }

    /// `•` the step in the product's words, its dot the state; a word only when it didn't simply go through, the time
    /// past 5 seconds; `└` what came back.
    private func step(_ call: ToolCall) -> some View {
        let stepState = BoardRun.step(call, live: BoardRun.isLive(card.status))
        let detail = BoardRun.detail(call)
        return VStack(alignment: .leading, spacing: 0) {
            CLILine(mark: "•", color: dot(stepState)) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(call.summary)
                        .foregroundStyle(stepState == .failed ? Palette.alert.color : Palette.inkMuted.color)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    if let word = BoardRun.word(stepState) { Text(word).foregroundStyle(dot(stepState)) }
                    if let time = BoardRun.duration(call) { Text(time).foregroundStyle(Palette.inkFaint.color) }
                }
            }
            if let detail {
                CLILine(mark: "└", color: Palette.inkFaint.color) {
                    Text(detail).foregroundStyle(Palette.inkFaint.color).lineLimit(3)
                }
                .padding(.leading, 16)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("board.run.step")
    }

    /// The status line (R3): what the run is doing now, with its time and tokens while it runs.
    @ViewBuilder private var statusLine: some View {
        Group {
            if BoardRun.isLive(card.status) {
                TimelineView(.periodic(from: .now, by: 1)) { context in statusContent(now: context.date) }
            } else {
                statusContent(now: .now)
            }
        }
        .font(FormoraFont.mono(11))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(Palette.line.color).frame(height: 1) }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("board.run.status")
    }

    private func statusContent(now: Date) -> some View {
        let (mark, color, text) = status(now: now)
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(mark).foregroundStyle(color)
            Text(text).foregroundStyle(Palette.inkMuted.color).lineLimit(1).truncationMode(.middle)
        }
    }

    private func status(now: Date) -> (String, Color, String) {
        let tokens = card.tokens + (draft.map { ($0.usage?.input ?? 0) + ($0.usage?.output ?? 0) } ?? 0)
        let seconds = card.seconds + (draft.map { now.timeIntervalSince($0.startedAt) } ?? 0)
        let numbers = "\(BoardFormat.seconds(seconds)) · \(ContextBudget.format(tokens)) token"
        if let approval = state.chat.approvals[runIn], let call = card.entries.lazy.compactMap({ entry -> ToolCall? in
            if case .step(let call) = entry.kind, call.id == approval.callID { return call }
            return nil
        }).first {
            return ("?", Palette.accent.color, "等你确认：\(call.summary)")
        }
        switch card.status {
        case .running: return ("●", Palette.accent.color, "进行中 · \(numbers)")
        case .waiting(let label): return ("◌", Palette.inkFaint.color, "\(label) · \(numbers)")
        case .done: return ("✓", Palette.success.color, "已完成 · \(numbers)")
        case .failed: return ("✗", Palette.alert.color, "已失败 · \(numbers)")
        case .stopped: return ("■", Palette.inkFaint.color, "已停止 · \(numbers)")
        case .pending: return ("○", Palette.inkFaint.color, "待开始")
        case .queued(let label):
            return ("○", Palette.inkFaint.color, card.after.count > 1 ? "等待 \(card.after.joined(separator: "、")) 完成" : label)
        }
    }

    private func dot(_ status: BoardCard.Status) -> Color {
        switch status {
        case .running: Palette.accent.color
        case .done: Palette.ink.color
        case .failed: Palette.alert.color
        case .pending, .stopped, .waiting, .queued: Palette.inkFaint.color
        }
    }

    private func dot(_ step: BoardRun.Step) -> Color {
        switch step {
        case .running: Palette.accent.color
        case .failed: Palette.alert.color
        case .done: Palette.ink.color
        case .denied, .stopped, .skipped: Palette.inkFaint.color
        }
    }
}

/// One line of the terminal: its mark in a column of its own, the rest hanging beside it.
private struct CLILine<Content: View>: View {
    let mark: String
    let color: Color
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(mark).foregroundStyle(color).frame(width: 10, alignment: .leading)
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 3)
    }
}

/// Thinking as Codex prints it: dim and italic (R2) — the system's mono, which has an italic.
private struct ThinkingText: View {
    let text: String

    var body: some View {
        Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
            .font(.system(size: BoardRunPanel.size, design: .monospaced).italic())
            .foregroundStyle(Palette.inkFaint.color)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The turn being written, streaming (R2): its thinking, then its words with the cursor. Its own view, so a token
/// redraws only this (9a).
private struct LiveTurn: View {
    let draft: ChatRunner.Draft
    let follow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !draft.thinking.isEmpty {
                CLILine(mark: "•", color: Palette.inkFaint.color) { ThinkingText(text: draft.thinking + (draft.text.isEmpty ? " ▍" : "")) }
            }
            if !draft.text.isEmpty {
                CLILine(mark: "•", color: Palette.accent.color) {
                    MarkdownText(source: ChatText.clean(draft.text), showsCursor: true, size: BoardRunPanel.size, mono: true)
                }
            } else if draft.thinking.isEmpty {
                CLILine(mark: "•", color: Palette.accent.color) { Text("思考中…").foregroundStyle(Palette.inkFaint.color) }
            }
        }
        .onChange(of: draft.text.count) { follow() }
        .onChange(of: draft.thinking.count) { follow() }
        .accessibilityIdentifier("board.run.live")
    }
}

/// What the transcript says about a run, kept out of the view so it can be tested (8c).
enum BoardRun {
    enum Step: Equatable { case done, failed, denied, stopped, running, skipped }

    /// Running or waiting out a failure: the panel follows the end.
    static func isLive(_ status: BoardCard.Status) -> Bool {
        if case .waiting = status { return true }
        return status == .running
    }

    /// A step's state is its result's; none yet is running while the card runs, else it never ran.
    static func step(_ call: ToolCall, live: Bool) -> Step {
        guard let result = call.result else { return live ? .running : .skipped }
        switch result.status {
        case .done: return .done
        case .failed: return .failed
        case .denied: return .denied
        case .stopped: return .stopped
        }
    }

    /// Nothing for a step that went through: the colour already says it.
    static func word(_ step: Step) -> String? {
        switch step {
        case .done: nil
        case .failed: "失败"
        case .denied: "已拒绝"
        case .stopped: "已停止"
        case .running: "进行中"
        case .skipped: "没有执行"
        }
    }

    /// Only past 5 seconds (omp; mockup `.step-secs`): a quick step doesn't need its time.
    static func duration(_ call: ToolCall) -> String? {
        guard let seconds = call.result?.seconds, seconds > 5 else { return nil }
        return BoardFormat.seconds(seconds)
    }

    static let detailLimit = 120

    /// What came back: the output's first line. A written file's path is already in the step's name.
    static func detail(_ call: ToolCall) -> String? {
        guard let result = call.result, result.savedPath == nil,
              let line = result.output.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty })
        else { return nil }
        return line.count > detailLimit ? String(line.prefix(detailLimit)) + "…" : line
    }

    /// Under the headline: who, how many steps, tokens, time — no zeros.
    static func stats(_ card: BoardCard) -> String {
        let steps = card.entries.filter { if case .step = $0.kind { true } else { false } }.count
        var parts = [card.agentName, "\(steps) 步"]
        if card.tokens > 0 { parts.append("\(ContextBudget.format(card.tokens)) token") }
        if card.seconds > 0 { parts.append(BoardFormat.seconds(card.seconds)) }
        return parts.joined(separator: " · ")
    }
}
