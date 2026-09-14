import Foundation

/// 用量 (user 2026-09-14): every reply already records its model, its tokens and its time, so the ledger is a pass over
/// the conversations — today, seven days, thirty days or everything, by conversation, Agent or model, priced by
/// `ModelPriceStore`. Nothing is stored twice.
enum UsageLedger {
    enum Period: String, CaseIterable, Identifiable, Sendable {
        case today, week, month, all

        var id: String { rawValue }

        var title: String {
            switch self {
            case .today: "今天"
            case .week: "7 天"
            case .month: "30 天"
            case .all: "全部"
            }
        }
    }

    enum Grouping: String, CaseIterable, Identifiable, Sendable {
        case conversation, agent, model

        var id: String { rawValue }

        var title: String {
            switch self {
            case .conversation: "按对话"
            case .agent: "按 Agent"
            case .model: "按模型"
            }
        }
    }

    /// One priced reply.
    struct Entry: Equatable, Sendable {
        var date: Date
        var conversationID: UUID
        var conversationTitle: String
        var agentID: UUID?
        var agentName: String
        var model: ModelReference
        var usage: TokenUsage
    }

    /// One row of a grouped table.
    struct Line: Identifiable, Equatable, Sendable {
        var id: String
        var name: String
        var detail: String
        var runs: Int
        var input: Int
        var output: Int
        var cost: [Currency: Double]
        /// Some of its replies came from a model without a price.
        var unpriced: Bool
    }

    struct Totals: Equatable, Sendable {
        var runs = 0
        var input = 0
        var output = 0
        var cost: [Currency: Double] = [:]
        /// Models seen without a price.
        var unpricedModels: [ModelReference] = []
    }

    /// The replies that carry a model and a usage — an Agent's turns, the app's own summaries too.
    static func entries(_ conversations: [Conversation], agentName: (UUID?) -> String) -> [Entry] {
        var entries: [Entry] = []
        for conversation in conversations {
            for message in conversation.messages {
                guard let model = message.model, let usage = message.usage, (usage.input ?? 0) + (usage.output ?? 0) > 0 else { continue }
                entries.append(Entry(date: message.createdAt, conversationID: conversation.id, conversationTitle: conversation.title,
                                     agentID: message.agentID, agentName: message.agentID.map(agentName) ?? "Formora", model: model, usage: usage))
            }
        }
        return entries
    }

    static func filter(_ entries: [Entry], period: Period, now: Date = Date(), calendar: Calendar = .current) -> [Entry] {
        let since: Date
        switch period {
        case .today: since = calendar.startOfDay(for: now)
        case .week: since = calendar.date(byAdding: .day, value: -7, to: now) ?? now
        case .month: since = calendar.date(byAdding: .day, value: -30, to: now) ?? now
        case .all: return entries
        }
        return entries.filter { $0.date >= since }
    }

    /// Input and output at their prices; cache reads count as input.
    static func cost(_ usage: TokenUsage, at price: ModelPrice) -> Double {
        (Double(usage.input ?? 0) * price.input + Double(usage.output ?? 0) * price.output) / 1_000_000
    }

    static func totals(_ entries: [Entry], price: (ModelReference) -> ModelPrice?) -> Totals {
        var totals = Totals()
        var unpriced: [ModelReference] = []
        for entry in entries {
            totals.runs += 1
            totals.input += entry.usage.input ?? 0
            totals.output += entry.usage.output ?? 0
            if let price = price(entry.model) {
                totals.cost[price.currency, default: 0] += cost(entry.usage, at: price)
            } else if !unpriced.contains(entry.model) {
                unpriced.append(entry.model)
            }
        }
        totals.unpricedModels = unpriced
        return totals
    }

    /// The table for a grouping, biggest spender first (then most tokens).
    static func lines(_ entries: [Entry], by grouping: Grouping, price: (ModelReference) -> ModelPrice?) -> [Line] {
        var lines: [String: Line] = [:]
        var order: [String] = []
        for entry in entries {
            let key: String, name: String, detail: String
            switch grouping {
            case .conversation:
                key = entry.conversationID.uuidString
                name = entry.conversationTitle
                detail = ""
            case .agent:
                key = entry.agentID?.uuidString ?? "formora"
                name = entry.agentName
                detail = ""
            case .model:
                key = ModelPriceStore.key(entry.model)
                name = entry.model.modelID
                detail = entry.model.providerID
            }
            if lines[key] == nil {
                lines[key] = Line(id: key, name: name, detail: detail, runs: 0, input: 0, output: 0, cost: [:], unpriced: false)
                order.append(key)
            }
            lines[key]!.runs += 1
            lines[key]!.input += entry.usage.input ?? 0
            lines[key]!.output += entry.usage.output ?? 0
            if let price = price(entry.model) {
                lines[key]!.cost[price.currency, default: 0] += cost(entry.usage, at: price)
            } else {
                lines[key]!.unpriced = true
            }
        }
        return order.compactMap { lines[$0] }.sorted { a, b in
            let costA = a.cost.values.reduce(0, +), costB = b.cost.values.reduce(0, +)
            if costA != costB { return costA > costB }
            return a.input + a.output > b.input + b.output
        }
    }

    /// The models to price: every one that appears, plus the Agents' current ones.
    static func models(_ entries: [Entry], agents: [ModelReference]) -> [ModelReference] {
        var seen: [ModelReference] = []
        for model in entries.map(\.model) + agents where !seen.contains(model) { seen.append(model) }
        return seen.sorted { ModelPriceStore.key($0) < ModelPriceStore.key($1) }
    }

    /// `2026-09`.
    static func month(of date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    /// This calendar month's spend in the budget's currency.
    static func monthSpend(_ entries: [Entry], currency: Currency, now: Date = Date(), calendar: Calendar = .current,
                           price: (ModelReference) -> ModelPrice?) -> Double {
        let start = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
        return totals(entries.filter { $0.date >= start }, price: price).cost[currency] ?? 0
    }

    // MARK: Formatting

    static func tokens(_ count: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        return formatter.string(from: NSNumber(value: count)) ?? String(count)
    }

    static func money(_ amount: Double, _ currency: Currency) -> String {
        let digits = amount >= 1 || amount == 0 ? 2 : 4
        return currency.symbol + String(format: "%.\(digits)f", amount)
    }

    /// `¥12.30 · $0.45`, or `—` with nothing priced.
    static func money(_ cost: [Currency: Double]) -> String {
        let parts = Currency.allCases.compactMap { currency in cost[currency].map { money($0, currency) } }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }
}
