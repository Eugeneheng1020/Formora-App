import Foundation

/// The files pane's chat (user 2026-09-22) printed as a terminal, the way the board's 「运行过程」 prints one run — but
/// the whole conversation, in the thread's order, nothing folded. Pure: the view only draws the lines.
enum CLITranscript {
    struct Line: Identifiable, Equatable {
        let id: String
        let kind: Kind
    }

    enum Kind: Equatable {
        /// `›` the user's words.
        case user(String)
        /// `•` dim italic.
        case thinking(String)
        /// `•` the Agent's words, Markdown.
        case reply(String)
        /// `•` a step, `└` what came back.
        case step(ToolCall)
        /// A grey line of the thread's own: a compaction, a memory note, a hand-off, a marker.
        case note(String)
        /// `✗` a reply that never came.
        case failure(String)
    }

    /// The status line under the transcript.
    enum Status: Equatable {
        case idle, running, waiting(String), done, stopped, failed

        var mark: String {
            switch self {
            case .idle: "○"
            case .running: "●"
            case .waiting: "?"
            case .done: "✓"
            case .stopped: "■"
            case .failed: "✗"
            }
        }

        var label: String {
            switch self {
            case .idle: "还没开始"
            case .running: "进行中"
            case .waiting(let summary): "等你确认：\(summary)"
            case .done: "已完成"
            case .stopped: "已停止"
            case .failed: "已失败"
            }
        }
    }

    /// A detail longer than this stays off the line — the thread's card has it.
    static let detailLimit = 200

    static func lines(_ conversation: Conversation) -> [Line] {
        var lines: [Line] = []
        for message in conversation.messages where !message.isUpkeep {
            let id = message.id.uuidString
            if let event = message.event {
                // A rewind (10e) is kept for /cost and restore, never shown (user 2026-09-20).
                guard event.kind != .rewind else { continue }
                let detail = event.detail.trimmingCharacters(in: .whitespacesAndNewlines)
                let text = detail.isEmpty || detail.count > detailLimit ? event.title : event.title + "\n" + detail
                lines.append(Line(id: id, kind: .note(text)))
                continue
            }
            if message.role == .agent {
                if let rule = message.rule, !rule.isEmpty { lines.append(Line(id: id + "#rule", kind: .note("规则提醒：" + rule))) }
                if let thinking = message.thinking?.trimmingCharacters(in: .whitespacesAndNewlines), !thinking.isEmpty {
                    lines.append(Line(id: id + "#t", kind: .thinking(thinking)))
                }
                let reply = ChatText.clean(message.text).trimmingCharacters(in: .whitespacesAndNewlines)
                if !reply.isEmpty { lines.append(Line(id: id + "#r", kind: .reply(reply))) }
                for call in message.toolCalls { lines.append(Line(id: id + "#s" + call.id, kind: .step(call))) }
                if let interruption = message.interruption { lines.append(Line(id: id + "#f", kind: .failure(interruption))) }
                continue
            }
            if let compaction = message.compaction {
                lines.append(Line(id: id, kind: .note("已压缩 · " + compaction.reason.label)))
                continue
            }
            if message.isHidden {
                // The loop's own words aren't replayed (K11); a self-review's or 旁审's marker is its line.
                if let marker = message.marker, !marker.isEmpty { lines.append(Line(id: id, kind: .note(marker))) }
                continue
            }
            lines.append(Line(id: id, kind: .user(message.text)))
        }
        return lines
    }

    /// Waiting for the user beats running; otherwise the last turn says how it ended.
    static func status(_ conversation: Conversation, running: Bool, waitingFor: ToolCall?) -> Status {
        if let waitingFor { return .waiting(waitingFor.summary) }
        if running { return .running }
        guard let last = conversation.messages.last(where: { $0.role == .agent && !$0.isHidden && !$0.isUpkeep }) else { return .idle }
        if last.interruption != nil { return .failed }
        if last.isStopped { return .stopped }
        return .done
    }

    /// This run's seconds and tokens: the turns of the last run (the draft's while one streams), the draft's own on top.
    static func runNumbers(_ conversation: Conversation, draft: ChatRunner.Draft?, now: Date) -> (seconds: Double, tokens: Int) {
        let runID = draft?.runID ?? conversation.messages.last(where: { $0.role == .agent && $0.runID != nil })?.runID
        var seconds = 0.0
        var tokens = 0
        if let runID {
            for message in conversation.messages where message.role == .agent && message.runID == runID {
                seconds += message.durationSeconds ?? 0
                tokens += (message.usage?.input ?? 0) + (message.usage?.output ?? 0)
            }
        }
        if let draft {
            seconds += now.timeIntervalSince(draft.startedAt)
            tokens += (draft.usage?.input ?? 0) + (draft.usage?.output ?? 0)
        }
        return (seconds, tokens)
    }
}
