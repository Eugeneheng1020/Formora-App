import Foundation
import Observation

/// What a million tokens cost, in the provider's currency. `cacheRead`: a cache read's own rate (omp's catalog,
/// 2026-09-18); without one, cache reads count as input.
struct ModelPrice: Codable, Equatable, Sendable {
    var input: Double
    var output: Double
    var currency: Currency
    var cacheRead: Double? = nil
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

/// 单价 (user 2026-09-14: built-in defaults the user can change, over blanks; 2026-09-18: the defaults are omp's catalog):
/// the price in force for each model, cache reads at their own rate — every one can be edited in 设置 → 用量 and the
/// user's own are kept in `prices.json`.
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

    /// A provider's base URL, so a custom platform's model is priced by its host's rows (Command Code); set at launch.
    @ObservationIgnored var baseURL: (String) -> String? = { _ in nil }

    /// The price in force and whether it is the built-in one; `nil` when neither exists (a model omp doesn't know).
    func price(for reference: ModelReference) -> (price: ModelPrice, isDefault: Bool)? {
        if let own = custom[Self.key(reference)] { return (own, false) }
        return Self.defaultPrice(reference, baseURL: baseURL(reference.providerID)).map { ($0, true) }
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

    /// The reference price (user 2026-09-18: omp's catalog replaces the hand-written ones): the price in force for the
    /// model's catalog row, in dollars per million; 通义 isn't in omp's catalog and keeps its hand-written yuan.
    static func defaultPrice(_ reference: ModelReference, baseURL: String? = nil, at date: Date = .now) -> ModelPrice? {
        if reference.providerID == "qwen" { return qwenPrice(reference.modelID.lowercased()) }
        guard let cost = ModelCatalog.model(providerID: reference.providerID, modelID: reference.modelID, baseURL: baseURL)?.cost(at: date)
        else { return nil }
        return ModelPrice(input: cost.input, output: cost.output, currency: .usd, cacheRead: cost.cacheRead)
    }

    /// 通义 (DashScope), in yuan per million — omp has no DashScope rows.
    private static func qwenPrice(_ model: String) -> ModelPrice? {
        func cny(_ input: Double, _ output: Double) -> ModelPrice { ModelPrice(input: input, output: output, currency: .cny) }
        if model.contains("max") { return cny(2.4, 9.6) }
        if model.contains("coder") { return cny(4, 16) }
        if model.contains("turbo") || model.contains("flash") { return cny(0.3, 0.6) }
        if model.contains("plus") { return cny(0.8, 2) }
        return nil
    }
}
