import Foundation

/// K (9e): back after a while, one sentence on what happened meanwhile — the facts from the conversations themselves,
/// put into one sentence by Bob when he has a model.
enum AwayDigest {
    /// Away at least this long before there is anything to say.
    static let threshold: TimeInterval = 10 * 60
    static let title = "你不在的时候"

    static let system = """
    你是 Formora 的 Bob。用户离开了一阵，刚回来。根据下面的记录，用一句话（不超过 60 个字）告诉他这段时间发生了什么，先说最要紧的：出错的、等他确认的。只回这一句。
    """

    /// One line per conversation that moved since `since`: who replied, who failed, how a run or an arrangement ended,
    /// a summary. Nothing new, no line.
    static func facts(_ conversations: [Conversation], since: Date, name: (Conversation) -> String) -> [String] {
        conversations.compactMap { conversation in
            let new = conversation.messages.filter { $0.createdAt > since && !$0.isHidden && !$0.isUpkeep }
            var parts: [String] = []
            let replies = new.filter { $0.role == .agent && $0.failure == nil && !$0.text.isEmpty }
            if !replies.isEmpty {
                let speakers = ordered(replies.compactMap(\.speakerName))
                parts.append((speakers.isEmpty ? "有" : speakers.joined(separator: "、") + " ") + "回复了 \(replies.count) 条")
            }
            let failed = ordered(new.filter { $0.failure != nil }.map { $0.speakerName ?? "Agent" })
            if !failed.isEmpty { parts.append(failed.joined(separator: "、") + " 出错了") }
            let endings: Set<ThreadEvent.Kind> = [.autorunEnd, .conductEnd, .summary]
            for event in new.compactMap(\.event) where endings.contains(event.kind) {
                parts.append(event.kind == .summary ? "Bob 发了汇总" : event.title)
            }
            return parts.isEmpty ? nil : "「\(name(conversation))」" + parts.joined(separator: "，")
        }
    }

    /// Without Bob: the facts as one sentence — under the toast's title 「你不在的时候」, which it doesn't repeat.
    static func plain(_ facts: [String]) -> String {
        guard facts.count > 1 else { return facts.first ?? "" }
        return "\(facts.count) 个对话有进展：" + facts.prefix(3).joined(separator: "；") + (facts.count > 3 ? "……" : "")
    }

    /// Bob's sentence: the first line, at most 100 characters.
    static func line(_ reply: String) -> String {
        let line = reply.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        return line.count > 100 ? String(line.prefix(100)) + "…" : line
    }

    private static func ordered(_ names: [String]) -> [String] {
        names.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    }
}
