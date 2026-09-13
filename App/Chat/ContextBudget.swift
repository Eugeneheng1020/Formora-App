import Foundation

/// How full a conversation's context is (7e, E2–E3): what the next request would carry, against the model's window,
/// and when compaction starts (omp's reserve). Anchored on the provider's last real count; only what came after it
/// is estimated, and the screen says 估算 wherever an estimate shows (spec §9.8d).
enum ContextBudget {
    /// The share of the window from which the composer suggests `/compact` and the ring turns alert (old D25).
    static let hintRatio = 0.85
    /// What the system prompt and the tool list take when there is no real count yet.
    static let promptAllowance = 3_000

    /// A rough count: about four ASCII characters a token, one token per CJK (or other) character.
    static func estimate(_ text: String) -> Int {
        var ascii = 0
        var other = 0
        for scalar in text.unicodeScalars {
            if scalar.isASCII { ascii += 1 } else { other += 1 }
        }
        return (ascii + 3) / 4 + other
    }

    /// omp: at least 16k and 15% of the window; on a small window a 16k floor would eat it, so 15% alone.
    static func reserve(window: Int) -> Int {
        window < 64_000 ? window * 15 / 100 : max(16_384, window * 15 / 100)
    }

    static func threshold(window: Int) -> Int { window - reserve(window: window) }

    struct Usage: Equatable {
        var tokens: Int
        var window: Int?
        /// No real count since the latest compaction: all of it is estimated.
        var isEstimated: Bool

        var ratio: Double? { window.flatMap { $0 > 0 ? Double(tokens) / Double($0) : nil } }
        var isOverThreshold: Bool { window.map { tokens > ContextBudget.threshold(window: $0) } ?? false }
    }

    /// The context the next request carries.
    static func usage(_ messages: [Message], window: Int?) -> Usage {
        let effective = Compaction.effective(messages)
        var tokens = effective.summary.map { estimate(Compaction.context($0.summary)) } ?? 0
        // The latest reply the provider counted since the compaction: its input was the whole context then (summary
        // included), its output joins it. Counts from before the compaction measured the longer context.
        let since = effective.messages.indices.dropFirst(effective.keptCount)
        if let anchor = since.last(where: { effective.messages[$0].role == .agent && effective.messages[$0].usage?.input != nil }) {
            let counted = effective.messages[anchor]
            tokens = (counted.usage?.input ?? 0) + (counted.usage?.output ?? estimate(counted.text))
            tokens += counted.toolCalls.reduce(0) { $0 + estimate(result: $1) }
            for message in effective.messages[(anchor + 1)...] { tokens += estimate(message) }
            return Usage(tokens: tokens, window: window, isEstimated: false)
        }
        tokens += promptAllowance
        for message in effective.messages { tokens += estimate(message) }
        return Usage(tokens: tokens, window: window, isEstimated: true)
    }

    /// A picture at the size it is sent (7j, V1): Anthropic counts width × height / 750, about 1,600 for a screen.
    static let imageTokens = 1_600

    /// One message as the model reads it: words, `@` files, pictures, tool calls and their results.
    static func estimate(_ message: Message) -> Int {
        guard message.compaction == nil else { return 0 }
        var tokens = estimate(message.text) + 4
        tokens += message.mentions.reduce(0) { $0 + estimate($1.content ?? $1.path) }
        tokens += message.attachments.filter { $0.kind == .image }.count * imageTokens
        for call in message.toolCalls {
            tokens += estimate(call.arguments) + estimate(result: call)
        }
        return tokens
    }

    static func estimate(result call: ToolCall) -> Int {
        guard let result = call.result else { return 0 }
        return result.pruned == true ? 12 : estimate(result.output) + (result.images?.count ?? 0) * imageTokens
    }

    /// `12.3k` / `1.2M`, as the ring's tooltip, the divider and `/cost` write it.
    static func format(_ tokens: Int) -> String {
        switch tokens {
        case 1_000_000...: String(format: "%.1fM", Double(tokens) / 1_000_000)
        case 1_000...: String(format: "%.1fk", Double(tokens) / 1_000)
        default: "\(tokens)"
        }
    }
}
