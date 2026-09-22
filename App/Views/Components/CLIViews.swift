import SwiftUI

/// The terminal the board's 「运行过程」 (8c) and the files pane's chat (user 2026-09-22) both print: one size, one
/// line shape, one way to show a step and the turn being written.
enum CLIStyle {
    /// The terminal's one size.
    static let size: CGFloat = 11.5
}

/// One line of the terminal: its mark in a column of its own, the rest hanging beside it.
struct CLILine<Content: View>: View {
    let mark: String
    let color: Color
    let content: Content

    init(mark: String, color: Color, @ViewBuilder content: () -> Content) {
        self.mark = mark
        self.color = color
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(mark).foregroundStyle(color).frame(width: 10, alignment: .leading)
            // Selectable line by line: one selection group over a run's hundreds of lines cost every scroll a relayout of
            // them all (audit 2026-09-14).
            content.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
        }
        .padding(.vertical, 3)
    }
}

/// Thinking as Codex prints it: dim and italic (R2) — the system's mono, which has an italic.
struct ThinkingText: View {
    let text: String

    var body: some View {
        Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
            .font(.system(size: CLIStyle.size, design: .monospaced).italic())
            .foregroundStyle(Palette.inkFaint.color)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The turn being written, streaming (R2): its thinking, then its words with the cursor. Its own view, so a token
/// redraws only this (9a).
struct LiveTurn: View {
    let draft: ChatRunner.Draft
    var identifier = "board.run.live"
    let follow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !draft.thinking.isEmpty {
                CLILine(mark: "•", color: Palette.inkFaint.color) { ThinkingText(text: draft.thinking + (draft.text.isEmpty ? " ▍" : "")) }
            }
            if !draft.text.isEmpty {
                CLILine(mark: "•", color: Palette.accent.color) {
                    MarkdownText(source: ChatText.clean(draft.text), showsCursor: true, size: CLIStyle.size, mono: true)
                }
            } else if draft.thinking.isEmpty {
                CLILine(mark: "•", color: Palette.accent.color) { Text("思考中…").foregroundStyle(Palette.inkFaint.color) }
            }
        }
        .onChange(of: draft.text.count) { follow() }
        .onChange(of: draft.thinking.count) { follow() }
        .accessibilityIdentifier(identifier)
    }
}

/// `•` the step in the product's words, its dot the state; a word only when it didn't simply go through, the time
/// past 5 seconds; `└` what came back.
struct CLIStepLine: View {
    let call: ToolCall
    /// The run is still going: a step without a result is running, not skipped.
    let live: Bool
    var identifier = "board.run.step"

    var body: some View {
        let stepState = BoardRun.step(call, live: live)
        let detail = BoardRun.detail(call)
        VStack(alignment: .leading, spacing: 0) {
            CLILine(mark: "•", color: Self.dot(stepState)) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(call.summary)
                        .foregroundStyle(stepState == .failed ? Palette.alert.color : Palette.inkMuted.color)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    if let word = BoardRun.word(stepState) { Text(word).foregroundStyle(Self.dot(stepState)) }
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
        .accessibilityIdentifier(identifier)
    }

    static func dot(_ step: BoardRun.Step) -> Color {
        switch step {
        case .running: Palette.accent.color
        case .failed: Palette.alert.color
        case .done: Palette.ink.color
        case .denied, .stopped, .skipped: Palette.inkFaint.color
        }
    }
}
