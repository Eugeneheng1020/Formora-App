import Foundation
import Observation

/// Bob's model (7h, B2): chosen at the top of his page. By default the first configured model — the first provider
/// with a key, its first model — moving on when that one goes; a choice the user made is kept while its provider
/// still has a key.
@MainActor
@Observable
final class BobModel {
    /// A provider with a key and the models it offers: the real list once read, else the catalog's common ones.
    struct Option: Identifiable {
        let provider: ProviderEntry
        let models: [ModelInfo]

        var id: String { provider.id }
    }

    private(set) var chosen: ModelReference?
    /// 设置 → Bob's 「允许操作电脑」 (D97): off until the user turns it on, like an Agent's.
    private(set) var allowsComputer: Bool
    @ObservationIgnored private let defaults: UserDefaults?

    static let key = "bob.model"
    static let computerKey = "bob.allowsComputer"

    /// `defaults == nil` keeps the choice in memory (tests).
    init(defaults: UserDefaults?) {
        self.defaults = defaults
        allowsComputer = defaults?.bool(forKey: Self.computerKey) ?? false
        if let data = defaults?.data(forKey: Self.key) { chosen = try? JSONDecoder().decode(ModelReference.self, from: data) }
    }

    /// `nil` goes back to the default.
    func choose(_ reference: ModelReference?) {
        chosen = reference
        if let reference, let data = try? JSONEncoder().encode(reference) {
            defaults?.set(data, forKey: Self.key)
        } else {
            defaults?.removeObject(forKey: Self.key)
        }
    }

    func setAllowsComputer(_ on: Bool) {
        allowsComputer = on
        defaults?.set(on, forKey: Self.computerKey)
    }

    static func options(_ providers: ProviderStore) -> [Option] {
        providers.entries.filter { providers.hasKey($0.id) }.compactMap { entry in
            let listed: [ModelInfo] = if case .loaded(let models) = providers.modelLists[entry.id], !models.isEmpty { models } else { entry.commonModels }
            return listed.isEmpty ? nil : Option(provider: entry, models: listed)
        }
    }

    /// The model Bob answers with now; `nil` when no provider has a key and a model.
    func current(_ providers: ProviderStore) -> ModelReference? {
        if let chosen, !chosen.modelID.isEmpty, providers.hasKey(chosen.providerID) { return chosen }
        guard let first = Self.options(providers).first, let model = first.models.first else { return nil }
        return ModelReference(providerID: first.provider.id, modelID: model.id)
    }
}
