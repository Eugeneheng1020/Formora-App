import Foundation

struct CustomProvider: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var name: String
    var baseURL: String
    var apiProtocol: APIProtocol
}

/// How a provider's models call tools (7d, D8): natively, as text (兼容模式), or native first and text once a model
/// refuses.
enum ToolCallMode: String, Codable, CaseIterable, Sendable {
    case auto, native, text

    var label: String {
        switch self {
        case .auto: "自动"
        case .native: "原生"
        case .text: "文本（兼容模式）"
        }
    }

    var note: String {
        switch self {
        case .auto: "先用服务商原生的工具调用；哪个模型不支持，就自动改用兼容模式并记住。"
        case .native: "只用原生的工具调用。模型不支持时，这次只能对话。"
        case .text: "把工具写进提示词，让模型用文字调用。给不支持原生工具调用的模型或网关用，好不好用取决于模型。"
        }
    }
}

/// What 设置 → 模型 keeps on disk (`Providers.json` in the profile's support folder). Never a key — keys
/// live in the Keychain; `withKey` only records which providers have one, so listing statuses never
/// touches the Keychain.
struct ProviderConfig: Codable, Equatable, Sendable {
    static let fileName = "Providers.json"

    var custom: [CustomProvider] = []
    /// Provider id → the host (base URL) that accepted its key (S15).
    var chosenHosts: [String: String] = [:]
    var withKey: Set<String> = []
    /// Provider id → how its models call tools; absent means 自动 (7d, D8).
    var toolModes: [String: ToolCallMode] = [:]
    /// `provider/model` pairs that refused native tools under 自动 and now use the text protocol.
    var textToolModels: Set<String> = []
    /// `provider/model#level` — a reasoning level the host refused (user 2026-09-18): the menu stops listing it.
    var rejectedReasoning: Set<String> = []

    init() {}

    private enum CodingKeys: String, CodingKey {
        case custom, chosenHosts, withKey, toolModes, textToolModels, rejectedReasoning
    }

    /// Fields added later are optional on disk: an older file still opens with its custom providers.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        custom = try values.decodeIfPresent([CustomProvider].self, forKey: .custom) ?? []
        chosenHosts = try values.decodeIfPresent([String: String].self, forKey: .chosenHosts) ?? [:]
        withKey = try values.decodeIfPresent(Set<String>.self, forKey: .withKey) ?? []
        toolModes = try values.decodeIfPresent([String: ToolCallMode].self, forKey: .toolModes) ?? [:]
        textToolModels = try values.decodeIfPresent(Set<String>.self, forKey: .textToolModels) ?? []
        rejectedReasoning = try values.decodeIfPresent(Set<String>.self, forKey: .rejectedReasoning) ?? []
    }

    static func load(from url: URL?) -> ProviderConfig {
        guard let url, let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(ProviderConfig.self, from: data) else { return ProviderConfig() }
        return config
    }

    func save(to url: URL?) throws {
        guard let url else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
