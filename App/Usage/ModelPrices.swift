import Foundation
import Observation

/// What a million tokens cost, in the provider's currency.
struct ModelPrice: Codable, Equatable, Sendable {
    var input: Double
    var output: Double
    var currency: Currency
}

enum Currency: String, Codable, CaseIterable, Identifiable, Sendable {
    case cny = "CNY", usd = "USD"

    var id: String { rawValue }
    var symbol: String { self == .cny ? "¥" : "$" }
}

/// A monthly budget (2026-09-14): crossed, the user is told once that month.
struct UsageBudget: Codable, Equatable, Sendable {
    var amount: Double
    var currency: Currency
}

/// 单价 (user 2026-09-14: built-in defaults the user can change, over blanks): reference prices for the models the
/// catalog knows, matched by provider and the model's name — the official prices move, so every one can be edited in
/// 设置 → 用量 and the user's own are kept in `prices.json`. Cache reads count as plain input: the discount differs per
/// provider and the ledger stays simple.
@MainActor
@Observable
final class ModelPriceStore {
    private(set) var custom: [String: ModelPrice] = [:]
    private(set) var budget: UsageBudget?
    /// `2026-09`: the month the budget notice went out, so it goes once.
    private(set) var budgetNotifiedMonth: String?

    static let fileName = "prices.json"

    private let fileURL: URL?

    private struct File: Codable {
        var custom: [String: ModelPrice] = [:]
        var budget: UsageBudget?
        var budgetNotifiedMonth: String?
    }

    init(fileURL: URL?) {
        self.fileURL = fileURL
        guard let fileURL, let data = try? Data(contentsOf: fileURL), let file = try? JSONDecoder().decode(File.self, from: data) else { return }
        custom = file.custom
        budget = file.budget
        budgetNotifiedMonth = file.budgetNotifiedMonth
    }

    nonisolated static func key(_ reference: ModelReference) -> String { reference.providerID + "/" + reference.modelID }

    /// The price in force and whether it is the built-in one; `nil` when neither exists (a custom provider's model).
    func price(for reference: ModelReference) -> (price: ModelPrice, isDefault: Bool)? {
        if let own = custom[Self.key(reference)] { return (own, false) }
        return Self.defaultPrice(reference).map { ($0, true) }
    }

    /// Sets the user's price; `nil` goes back to the default.
    func set(_ price: ModelPrice?, for reference: ModelReference) {
        custom[Self.key(reference)] = price
        save()
    }

    func setBudget(_ budget: UsageBudget?) {
        self.budget = budget
        if budget == nil { budgetNotifiedMonth = nil }
        save()
    }

    func markBudgetNotified(month: String) {
        budgetNotifiedMonth = month
        save()
    }

    private func save() {
        guard let fileURL else { return }
        let file = File(custom: custom, budget: budget, budgetNotifiedMonth: budgetNotifiedMonth)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(file) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: Defaults

    /// The reference price by provider and name (an OpenRouter model routes by its vendor prefix). Per million tokens.
    static func defaultPrice(_ reference: ModelReference) -> ModelPrice? {
        var provider = reference.providerID
        var model = reference.modelID.lowercased()
        if model.hasPrefix("~") { model.removeFirst() }
        if provider == "openrouter", let slash = model.firstIndex(of: "/") {
            provider = String(model[..<slash])
            model = String(model[model.index(after: slash)...])
        }
        func usd(_ input: Double, _ output: Double) -> ModelPrice { ModelPrice(input: input, output: output, currency: .usd) }
        func cny(_ input: Double, _ output: Double) -> ModelPrice { ModelPrice(input: input, output: output, currency: .cny) }
        switch provider {
        case "openai":
            if model.contains("nano") { return usd(0.1, 0.4) }
            if model.contains("mini") { return usd(0.4, 1.6) }
            if model.hasPrefix("o3") || model.hasPrefix("o4") { return usd(2, 8) }
            if model.contains("gpt-4o") { return usd(2.5, 10) }
            if model.contains("gpt-4.1") { return usd(2, 8) }
            return usd(1.25, 10)
        case "anthropic":
            if model.contains("opus") { return usd(15, 75) }
            if model.contains("haiku") { return usd(1, 5) }
            if model.contains("sonnet") { return usd(3, 15) }
            return nil
        case "google", "gemini":
            if model.contains("flash-lite") || model.contains("flash_lite") { return usd(0.1, 0.4) }
            if model.contains("flash") { return usd(0.3, 2.5) }
            if model.contains("pro") { return usd(1.25, 10) }
            return nil
        case "deepseek":
            if model.contains("reasoner") || model.contains("r1") || model.contains("pro") { return cny(4, 16) }
            if model.contains("flash") { return cny(1, 4) }
            return cny(2, 8)
        case "qwen", "alibaba":
            if model.contains("max") { return cny(2.4, 9.6) }
            if model.contains("coder") { return cny(4, 16) }
            if model.contains("turbo") || model.contains("flash") { return cny(0.3, 0.6) }
            if model.contains("plus") { return cny(0.8, 2) }
            return nil
        case "moonshot", "moonshotai":
            return cny(4, 16)
        case "zai", "z-ai", "zhipu":
            if model.contains("flash") { return cny(0.5, 2) }
            if model.contains("turbo") { return cny(1, 4) }
            return cny(2, 8)
        case "xai", "x-ai":
            if model.contains("code-fast") { return usd(0.2, 1.5) }
            if model.contains("fast") { return usd(0.2, 0.5) }
            return usd(3, 15)
        case "minimax":
            return usd(0.3, 1.2)
        default:
            return nil
        }
    }
}
