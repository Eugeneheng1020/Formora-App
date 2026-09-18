import Foundation

/// 一次运行底部的三组折叠 (user 2026-09-18: 「思考中的内容集中放在一个里面，统一展开收起；文件修改也是」): what used to sit in
/// every turn — the 「思考了 N 秒」 fold, the 旁审 card, the green 「文件已修改」 card — is one group each under the run's
/// words, beside the tool group of 2026-09-15: a line when closed, everything when open. Pure: the view reads it, the
/// tests check it. 必须停 keeps its place in the turn: it is a stop, not a note.
enum RunFolds {
    struct Thought: Identifiable, Equatable, Sendable {
        let messageID: UUID
        let text: String
        let seconds: Double?

        var id: UUID { messageID }
    }

    struct Advice: Identifiable, Equatable, Sendable {
        let messageID: UUID
        let severity: Advisor.Severity
        let text: String

        var id: UUID { messageID }
    }

    struct Change: Identifiable, Equatable, Sendable {
        let path: String
        var isNew: Bool
        /// The last write to the path — its lines and diff, and the call 撤销 undoes; `nil` for a write before there was
        /// a history.
        var change: FileChange?
        var callID: String?
        var messageID: UUID

        var id: String { path }
    }

    // MARK: 思考

    /// Every turn's thinking, in order; a turn that showed none is skipped.
    static func thoughts(in messages: [Message]) -> [Thought] {
        messages.compactMap { message in
            guard let thinking = message.thinking, !thinking.isEmpty else { return nil }
            return Thought(messageID: message.id, text: thinking, seconds: message.thinkingSeconds)
        }
    }

    /// The closed group's line: 「思考中…」 while the model thinks, 「思考了 8 秒」 for one segment, 「思考 · 3 段 · 共 23 秒」
    /// for more. Empty with nothing: the view shows nothing.
    static func thinkingSummary(_ thoughts: [Thought], isThinking: Bool) -> String {
        if isThinking { return "思考中…" }
        guard !thoughts.isEmpty else { return "" }
        let seconds = thoughts.reduce(0.0) { $0 + ($1.seconds ?? 0) }
        if thoughts.count == 1 { return "思考了 \(ThinkingFold.duration(seconds))" }
        return "思考 · \(thoughts.count) 段 · 共 \(ThinkingFold.duration(seconds))"
    }

    // MARK: 旁审

    /// The watcher's 提醒 and 担心 of the run; 必须停 stays in its turn.
    static func advice(in messages: [Message]) -> [Advice] {
        messages.compactMap { message in
            guard let marker = message.marker, let severity = message.advice, severity != .blocker, message.review == nil else { return nil }
            return Advice(messageID: message.id, severity: severity, text: marker)
        }
    }

    /// 「旁审 · 3 条 · 提醒 1 · 担心 2」.
    static func adviceSummary(_ notes: [Advice]) -> String {
        guard !notes.isEmpty else { return "" }
        var parts = ["旁审", "\(notes.count) 条"]
        let nits = notes.filter { $0.severity == .nit }.count
        let concerns = notes.filter { $0.severity == .concern }.count
        if nits > 0 { parts.append("提醒 \(nits)") }
        if concerns > 0 { parts.append("担心 \(concerns)") }
        return parts.joined(separator: " · ")
    }

    // MARK: 文件

    /// The files the run wrote, once each in the order first touched — the last write to a path decides its lines and
    /// its 撤销, a new file stays new.
    static func changes(in messages: [Message]) -> [Change] {
        var changes: [Change] = []
        for message in messages {
            for call in message.toolCalls {
                guard let result = call.result, result.status == .done, let path = result.savedPath else { continue }
                let latest = (result.change != nil ? (result.change, call.id) : (nil, nil))
                if let index = changes.firstIndex(where: { $0.path == path }) {
                    changes[index].isNew = changes[index].isNew || result.isNewFile == true
                    if latest.0 != nil {
                        changes[index].change = latest.0
                        changes[index].callID = latest.1
                        changes[index].messageID = message.id
                    }
                } else {
                    changes.append(Change(path: path, isNew: result.isNewFile == true, change: latest.0, callID: latest.1, messageID: message.id))
                }
            }
        }
        return changes
    }

    /// 「文件 · 改了 3 个 · +120 −8 · 已撤销 1」: the lines of the changes still standing.
    static func changesSummary(_ changes: [Change]) -> String {
        guard !changes.isEmpty else { return "" }
        var parts = ["文件", "改了 \(changes.count) 个"]
        let standing = changes.compactMap(\.change).filter { $0.undone != true }
        if !standing.isEmpty {
            parts.append("+\(standing.reduce(0) { $0 + $1.added }) −\(standing.reduce(0) { $0 + $1.removed })")
        }
        let undone = changes.filter { $0.change?.undone == true }.count
        if undone > 0 { parts.append("已撤销 \(undone)") }
        return parts.joined(separator: " · ")
    }
}
