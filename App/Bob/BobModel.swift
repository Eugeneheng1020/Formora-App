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
    /// 设置 → Bob's 「权限模式」 (user 2026-09-13): the three an Agent has, 每次询问 until the user changes it — what he
    /// did before there was a choice (D55). What asks whatever the mode is `BobSession.alwaysAsks`.
    private(set) var approvalMode: ApprovalMode
    @ObservationIgnored private let defaults: UserDefaults?

    static let key = "bob.model"
    static let computerKey = "bob.allowsComputer"
    static let approvalKey = "bob.approvalMode"

    /// `defaults == nil` keeps the choice in memory (tests).
    init(defaults: UserDefaults?) {
        self.defaults = defaults
        allowsComputer = defaults?.bool(forKey: Self.computerKey) ?? false
        approvalMode = defaults?.string(forKey: Self.approvalKey).flatMap(ApprovalMode.init(rawValue:)) ?? .alwaysAsk
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

    func setApprovalMode(_ mode: ApprovalMode) {
        approvalMode = mode
        defaults?.set(mode.rawValue, forKey: Self.approvalKey)
    }

    /// What each mode means for him: his changes are settings as well as files.
    static func note(_ mode: ApprovalMode) -> String {
        switch mode {
        case .alwaysAsk: "看和查直接做，会改东西的都先问你。"
        case .write: "写文件、建 Skill、改设置直接做；跑命令、读网页、打开网址先问你。"
        case .yolo: "全都直接做，不问；只在信得过时用。"
        }
    }

    static let alwaysAsked = "危险命令、接入 MCP、清空记忆、会删数据的工具永远先问。"

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
