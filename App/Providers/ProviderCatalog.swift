import Foundation

/// The wire protocol a provider speaks (design spec §7.4). It also decides how the key is sent and where
/// the model list lives.
enum APIProtocol: String, CaseIterable, Codable, Sendable, Identifiable {
    case openAICompletions = "openai-completions"
    case openAIResponses = "openai-responses"
    case anthropicMessages = "anthropic-messages"
    case googleGenerativeAI = "google-generative-ai"

    var id: String { rawValue }

    /// Relative to the base URL. Anthropic bases are the bare host (omp's convention), so the version is in
    /// the path — without it the API answers 404 (old app, 2026-09-05). Both Anthropic and Google page their
    /// lists; ask for everything at once.
    var modelsPath: String {
        switch self {
        case .openAICompletions, .openAIResponses: "/models"
        case .anthropicMessages: "/v1/models?limit=1000"
        case .googleGenerativeAI: "/models?pageSize=1000"
        }
    }
}

struct ModelInfo: Equatable, Hashable, Sendable, Identifiable {
    let id: String
    var name: String?
    var contextWindow: Int?
    var maxOutput: Int?
    var acceptsImages: Bool?
    /// The endpoints the platform serves this model on, when its list says (`supported_endpoints`: Command Code's
    /// Claude models only on `/messages`, the rest only on `/chat/completions`). `nil` = the list doesn't say.
    var endpoints: [String]?
    /// Per million tokens, in dollars — omp's catalog (user 2026-09-18); `nil` = not known.
    var cost: ModelCatalog.Cost?
    var reasoning: Bool?
}

extension ModelInfo {
    /// A catalog row as the lists hold it: omp's data; images only when omp doesn't strip them for this model.
    static func from(_ row: ModelCatalog.Model) -> ModelInfo {
        ModelInfo(id: row.id, name: row.name, contextWindow: row.contextWindow, maxOutput: row.maxOutput,
                  acceptsImages: row.images && row.compat.bool("stripImageInput") != true, cost: row.cost(), reasoning: row.reasoning)
    }
}

struct ProviderHost: Equatable, Sendable {
    /// 「中国大陆」/「国际」 when a provider has both; empty otherwise.
    let label: String
    let baseURL: String
}

struct BuiltInProvider: Identifiable, Sendable {
    let id: String
    let name: String
    /// File name in `Resources/ProviderLogos` (simple-icons, CC0); `nil` shows `mark`.
    let logo: String?
    let mark: String
    let apiProtocol: APIProtocol
    /// The first is tried first. Several = mainland and international hosts whose keys don't cross over (S15).
    let hosts: [ProviderHost]
    /// Where a key is verified when the model list can't tell (OpenRouter's list is public: any key gets 200).
    var keyCheckPath: String?
    /// The host authenticates before routing, so a 404 after that means the key was accepted and there is
    /// simply no list endpoint.
    var notFoundMeansAuthorized = false
    /// 「常用模型」 shown before a key is bound (todo #4): the featured few, their data from omp's catalog.
    let commonModels: [ModelInfo]
    /// Every model omp's catalog has for this provider, the featured first (user 2026-09-18: 目录 ∪ 实时).
    var catalogModels: [ModelInfo] = []
    /// A key, or a subscription sign-in (7i).
    var access: ProviderAccess = .key
    /// A mark after the name: 「订阅登录 · 非官方接入」 (7i).
    var tag: String?
}

/// The ten built-in providers, in popularity order with aggregators last (design spec §7.4; user 2026-09-05:
/// Mistral and Groq out, Qwen in). Hosts, protocols and model metadata come from omp's catalog
/// (`packages/catalog`, 2026-09-11) except Qwen, whose DashScope compatible-mode hosts come from the old app.
/// Every key-check path was probed 2026-09-11 with a fake key: 401 (Google and xAI: 400), never 404.
/// This order and the common models follow the market and need periodic review. 7i adds the ChatGPT plan after
/// OpenAI (deviation D57; the coding plans came out again the same day — none has a sign-in a third-party app may use).
enum ProviderCatalog {
    static let builtIns: [BuiltInProvider] = listed.map(withCatalog)

    /// Each featured id with its catalog row's data (a bare id where omp has none).
    private static func featured(_ ids: [String], provider: String) -> [ModelInfo] {
        ids.map { id in ModelCatalog.model(providerID: provider, modelID: id).map(ModelInfo.from) ?? ModelInfo(id: id) }
    }

    /// The provider with every catalog row after its featured ones — the rest newest-looking first (omp lists them by id,
    /// so the later names are the newer ones). 通义 has no rows: its hand-written three are the whole catalog.
    private static func withCatalog(_ provider: BuiltInProvider) -> BuiltInProvider {
        var provider = provider
        let featured = Set(provider.commonModels.map(\.id))
        let rest = ModelCatalog.models(providerID: provider.id).filter { !featured.contains($0.id) }.reversed().map(ModelInfo.from)
        provider.catalogModels = provider.commonModels + rest
        return provider
    }

    private static let listed: [BuiltInProvider] = [
        BuiltInProvider(id: "openai", name: "OpenAI", logo: "openai", mark: "OA", apiProtocol: .openAIResponses,
                        hosts: [ProviderHost(label: "", baseURL: "https://api.openai.com/v1")],
                        commonModels: featured(["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.4-mini"], provider: "openai")),
        // 7i, U1: a ChatGPT Plus / Pro plan, signed in with the browser instead of a key.
        BuiltInProvider(id: ChatGPTAuth.providerID, name: "ChatGPT 订阅", logo: "openai", mark: "GP", apiProtocol: .openAIResponses,
                        hosts: [ProviderHost(label: "", baseURL: ChatGPTAuth.baseURL)],
                        commonModels: featured(["gpt-5.6-sol", "gpt-5.6-luna", "gpt-5.6-terra", "gpt-6-astra", "gpt-5.5", "gpt-5.4",
                                                "gpt-5.4-mini", "gpt-5.3-codex-spark"], provider: ChatGPTAuth.providerID),
                        access: .chatGPT, tag: "订阅登录 · 非官方接入"),
        BuiltInProvider(id: "anthropic", name: "Anthropic", logo: "anthropic", mark: "A", apiProtocol: .anthropicMessages,
                        hosts: [ProviderHost(label: "", baseURL: "https://api.anthropic.com")],
                        commonModels: featured(["claude-opus-5", "claude-sonnet-5", "claude-haiku-4-5"], provider: "anthropic")),
        BuiltInProvider(id: "google", name: "Google Gemini", logo: "googlegemini", mark: "G", apiProtocol: .googleGenerativeAI,
                        hosts: [ProviderHost(label: "", baseURL: "https://generativelanguage.googleapis.com/v1beta")],
                        commonModels: featured(["gemini-3.1-pro-preview", "gemini-3.8-flash", "gemini-flash-lite-latest"], provider: "google")),
        BuiltInProvider(id: "deepseek", name: "DeepSeek", logo: "deepseek", mark: "DS", apiProtocol: .openAICompletions,
                        hosts: [ProviderHost(label: "", baseURL: "https://api.deepseek.com")],
                        commonModels: featured(["deepseek-flash", "deepseek-v4-pro", "deepseek-v4-flash", "deepseek-v4-flash-vision-exp"], provider: "deepseek")),
        BuiltInProvider(id: "qwen", name: "Qwen", logo: "qwen", mark: "QW", apiProtocol: .openAICompletions,
                        hosts: [ProviderHost(label: "中国大陆", baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1"),
                                ProviderHost(label: "国际", baseURL: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1")],
                        commonModels: [
                            ModelInfo(id: "qwen3-max", name: "Qwen3 Max", contextWindow: 262_144, maxOutput: 65_536, acceptsImages: false),
                            ModelInfo(id: "qwen-plus", name: "Qwen Plus", contextWindow: 1_000_000, maxOutput: 32_768, acceptsImages: false),
                            ModelInfo(id: "qwen3-coder-plus", name: "Qwen3 Coder Plus", contextWindow: 1_000_000, maxOutput: 65_536, acceptsImages: false),
                        ]),
        BuiltInProvider(id: "moonshot", name: "Moonshot", logo: "moonshotai", mark: "K", apiProtocol: .openAICompletions,
                        hosts: [ProviderHost(label: "中国大陆", baseURL: "https://api.moonshot.cn/v1"),
                                ProviderHost(label: "国际", baseURL: "https://api.moonshot.ai/v1")],
                        commonModels: featured(["kimi-k3", "kimi-k2.6", "kimi-k2.7-code"], provider: "moonshot")),
        // simple-icons has no Z.AI mark; borrowing another brand's logo would be worse than its letter.
        BuiltInProvider(id: "zai", name: "Z.AI", logo: nil, mark: "Z", apiProtocol: .openAICompletions,
                        hosts: [ProviderHost(label: "", baseURL: "https://api.z.ai/api/paas/v4")],
                        commonModels: featured(["glm-5.3", "glm-5.3-flash", "glm-5v-turbo"], provider: "zai")),
        BuiltInProvider(id: "xai", name: "xAI", logo: "x", mark: "x", apiProtocol: .openAIResponses,
                        hosts: [ProviderHost(label: "", baseURL: "https://api.x.ai/v1")],
                        commonModels: featured(["grok-4.6", "grok-4-1-fast", "grok-code-fast-1"], provider: "xai")),
        // Not yet verified with a real key: MiniMax authenticates before routing (a fake key gets 401 on any
        // path), so a 404 with a real key means the key passed and there is no list endpoint.
        BuiltInProvider(id: "minimax", name: "MiniMax", logo: "minimax", mark: "MM", apiProtocol: .openAICompletions,
                        hosts: [ProviderHost(label: "中国大陆", baseURL: "https://api.minimaxi.com/v1"),
                                ProviderHost(label: "国际", baseURL: "https://api.minimax.io/v1")],
                        notFoundMeansAuthorized: true,
                        commonModels: featured(["MiniMax-M3", "MiniMax-M2.7", "MiniMax-M2.7-highspeed"], provider: "minimax")),
        BuiltInProvider(id: "openrouter", name: "OpenRouter", logo: "openrouter", mark: "OR", apiProtocol: .openAICompletions,
                        hosts: [ProviderHost(label: "", baseURL: "https://openrouter.ai/api/v1")],
                        keyCheckPath: "/auth/key",
                        commonModels: featured(["~anthropic/claude-sonnet-latest", "~openai/gpt-latest", "~google/gemini-pro-latest"], provider: "openrouter")),
    ]

    static func builtIn(_ id: String) -> BuiltInProvider? { builtIns.first { $0.id == id } }
}

/// The bundled logos (simple-icons, CC0), parsed once: the model providers' and, since D94, the MCP catalog's — in the
/// same folder, so neither repository's project.yml needed another resource folder.
enum ProviderLogos {
    static func icon(_ name: String) -> SVGIcon? { all[name] }

    static let all: [String: SVGIcon] = {
        guard let folder = Bundle.main.url(forResource: "ProviderLogos", withExtension: nil),
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else {
            return [:]
        }
        var icons: [String: SVGIcon] = [:]
        for file in files where file.pathExtension == "svg" {
            if let text = try? String(contentsOf: file, encoding: .utf8), let icon = SVGIcon(svg: text) {
                icons[file.deletingPathExtension().lastPathComponent] = icon
            }
        }
        return icons
    }()
}
