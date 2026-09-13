import Foundation

/// `/cost` in tokens (7e, E6; old answer A): how long the Agents worked, how many tokens, how many model calls, and per
/// model the input, cache hits and output. The summary calls of compactions count too. No money: prices go stale and
/// custom hosts have none.
struct UsageReport: Equatable {
    struct Row: Equatable {
        var model: ModelReference
        var calls = 0
        var input = 0
        var cached = 0
        var output = 0
    }

    var seconds: Double = 0
    var rows: [Row] = []

    var calls: Int { rows.reduce(0) { $0 + $1.calls } }
    var tokens: Int { rows.reduce(0) { $0 + $1.input + $1.output } }
    var isEmpty: Bool { rows.isEmpty }

    /// `subtasks`: the conversation's delegations, checks and lanes (7g, 9e) — work done for it, counted with it.
    init(_ conversation: Conversation, subtasks: [Conversation] = []) {
        // What edited messages replaced (10e) was paid for too.
        for message in conversation.messages + conversation.earlier.flatMap(\.messages) + subtasks.flatMap(\.messages) {
            guard let model = message.model, message.failure == nil else { continue }
            if message.role == .agent { seconds += message.durationSeconds ?? 0 }
            // A reply, a compaction's summary call, the memory extraction — a call even when the host sent no counts.
            guard message.role == .agent || message.compaction != nil || message.isUpkeep else { continue }
            let index = rows.firstIndex { $0.model == model } ?? {
                rows.append(Row(model: model))
                return rows.count - 1
            }()
            rows[index].calls += 1
            rows[index].input += message.usage?.input ?? 0
            rows[index].cached += message.usage?.cached ?? 0
            rows[index].output += message.usage?.output ?? 0
        }
    }
}
