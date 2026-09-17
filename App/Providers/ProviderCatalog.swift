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
    /// 「常用模型」 shown before a key is bound (todo #4).
    let commonModels: [ModelInfo]
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
    static let builtIns: [BuiltInProvider] = [
        BuiltInProvider(id: "openai", name: "OpenAI", logo: "openai", mark: "OA", apiProtocol: .openAIResponses,
                        hosts: [ProviderHost(label: "", baseURL: "https://api.openai.com/v1")],
                        commonModels: [
                            ModelInfo(id: "gpt-5.6-sol", name: "GPT-5.6 Sol", contextWindow: 1_050_000, maxOutput: 128_000, acceptsImages: true),
                            ModelInfo(id: "gpt-5.6-terra", name: "GPT-5.6 Terra", contextWindow: 1_050_000, maxOutput: 128_000, acceptsImages: true),
                            ModelInfo(id: "gpt-5.4-mini", name: "GPT-5.4 mini", contextWindow: 400_000, maxOutput: 128_000, acceptsImages: true),
                        ]),
        // 7i, U1: a ChatGPT Plus / Pro plan, signed in with the browser instead of a key.
        BuiltInProvider(id: ChatGPTAuth.providerID, name: "ChatGPT 订阅", logo: "openai", mark: "GP", apiProtocol: .openAIResponses,
                        hosts: [ProviderHost(label: "", baseURL: ChatGPTAuth.baseURL)],
                        commonModels: [
                            ModelInfo(id: "gpt-5.6-sol", name: "GPT-5.6 Sol", acceptsImages: true),
                            ModelInfo(id: "gpt-5.6-luna", name: "GPT-5.6 Luna", acceptsImages: true),
                            ModelInfo(id: "gpt-5.5", name: "GPT-5.5", acceptsImages: true),
                            ModelInfo(id: "gpt-5.4", name: "GPT-5.4", acceptsImages: true),
                            ModelInfo(id: "gpt-5.4-mini", name: "GPT-5.4 mini", acceptsImages: true),
                            ModelInfo(id: "gpt-5.3-codex-spark", name: "GPT-5.3 Codex Spark"),
                        ], access: .chatGPT, tag: "订阅登录 · 非官方接入"),
        BuiltInProvider(id: "anthropic", name: "Anthropic", logo: "anthropic", mark: "A", apiProtocol: .anthropicMessages,
                        hosts: [ProviderHost(label: "", baseURL: "https://api.anthropic.com")],
                        commonModels: [
                            ModelInfo(id: "claude-opus-5", name: "Claude Opus 5", contextWindow: 1_000_000, maxOutput: 128_000, acceptsImages: true),
                            ModelInfo(id: "claude-sonnet-5", name: "Claude Sonnet 5", contextWindow: 1_000_000, maxOutput: 128_000, acceptsImages: true),
                            ModelInfo(id: "claude-haiku-4-5", name: "Claude Haiku 4.5", contextWindow: 200_000, maxOutput: 64_000, acceptsImages: true),
                        ]),
        BuiltInProvider(id: "google", name: "Google Gemini", logo: "googlegemini", mark: "G", apiProtocol: .googleGenerativeAI,
                        hosts: [ProviderHost(label: "", baseURL: "https://generativelanguage.googleapis.com/v1beta")],
                        commonModels: [
                            ModelInfo(id: "gemini-3.1-pro-preview", name: "Gemini 3.1 Pro Preview", contextWindow: 1_048_576, maxOutput: 65_536, acceptsImages: true),
                            ModelInfo(id: "gemini-3.8-flash", name: "Gemini 3.8 Flash", contextWindow: 1_048_576, maxOutput: 65_536, acceptsImages: true),
                            ModelInfo(id: "gemini-flash-lite-latest", name: "Gemini Flash-Lite Latest", contextWindow: 1_048_576, maxOutput: 65_536, acceptsImages: true),
                        ]),
        BuiltInProvider(id: "deepseek", name: "DeepSeek", logo: "deepseek", mark: "DS", apiProtocol: .openAICompletions,
                        hosts: [ProviderHost(label: "", baseURL: "https://api.deepseek.com")],
                        commonModels: [
                            ModelInfo(id: "deepseek-flash", name: "DeepSeek V4.1 Flash", contextWindow: 1_000_000, maxOutput: 384_000, acceptsImages: true),
                            ModelInfo(id: "deepseek-v4-pro", name: "DeepSeek V4 Pro", contextWindow: 1_000_000, maxOutput: 384_000, acceptsImages: false),
                            ModelInfo(id: "deepseek-v4-flash", name: "DeepSeek V4 Flash", contextWindow: 1_000_000, maxOutput: 384_000, acceptsImages: true),
                            ModelInfo(id: "deepseek-v4-flash-vision-exp", name: "DeepSeek V4 Flash Vision Exp", contextWindow: 1_000_000, maxOutput: 384_000, acceptsImages: true),
                        ]),
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
                        commonModels: [
                            ModelInfo(id: "kimi-k3", name: "Kimi K3", contextWindow: 1_048_576, maxOutput: 131_072, acceptsImages: true),
                            ModelInfo(id: "kimi-k2.6", name: "Kimi K2.6", contextWindow: 262_144, maxOutput: 262_144, acceptsImages: true),
                            ModelInfo(id: "kimi-k2.7-code", name: "Kimi K2.7 Code", contextWindow: 262_144, maxOutput: 262_144, acceptsImages: true),
                        ]),
        // simple-icons has no Z.AI mark; borrowing another brand's logo would be worse than its letter.
        BuiltInProvider(id: "zai", name: "Z.AI", logo: nil, mark: "Z", apiProtocol: .openAICompletions,
                        hosts: [ProviderHost(label: "", baseURL: "https://api.z.ai/api/paas/v4")],
                        commonModels: [
                            ModelInfo(id: "glm-5.3", name: "GLM-5.3", contextWindow: 1_000_000, maxOutput: 131_072, acceptsImages: false),
                            ModelInfo(id: "glm-5.3-flash", name: "GLM-5.3-Flash", contextWindow: 1_000_000, maxOutput: 131_072, acceptsImages: true),
                            ModelInfo(id: "glm-5v-turbo", name: "GLM-5V-Turbo", contextWindow: 200_000, maxOutput: 131_072, acceptsImages: true),
                        ]),
        BuiltInProvider(id: "xai", name: "xAI", logo: "x", mark: "x", apiProtocol: .openAIResponses,
                        hosts: [ProviderHost(label: "", baseURL: "https://api.x.ai/v1")],
                        commonModels: [
                            ModelInfo(id: "grok-4.6", name: "Grok 4.6", contextWindow: 500_000, maxOutput: 500_000, acceptsImages: true),
                            ModelInfo(id: "grok-4-1-fast", name: "Grok 4.1 Fast", contextWindow: 2_000_000, maxOutput: 30_000, acceptsImages: true),
                            ModelInfo(id: "grok-code-fast-1", name: "Grok Code Fast 1", contextWindow: 256_000, maxOutput: 10_000, acceptsImages: false),
                        ]),
        // Not yet verified with a real key: MiniMax authenticates before routing (a fake key gets 401 on any
        // path), so a 404 with a real key means the key passed and there is no list endpoint.
        BuiltInProvider(id: "minimax", name: "MiniMax", logo: "minimax", mark: "MM", apiProtocol: .openAICompletions,
                        hosts: [ProviderHost(label: "中国大陆", baseURL: "https://api.minimaxi.com/v1"),
                                ProviderHost(label: "国际", baseURL: "https://api.minimax.io/v1")],
                        notFoundMeansAuthorized: true,
                        commonModels: [
                            ModelInfo(id: "MiniMax-M3", name: "MiniMax-M3", contextWindow: 1_000_000, maxOutput: 128_000, acceptsImages: true),
                            ModelInfo(id: "MiniMax-M2.7", name: "MiniMax-M2.7", contextWindow: 204_800, maxOutput: 131_072, acceptsImages: false),
                            ModelInfo(id: "MiniMax-M2.7-highspeed", name: "MiniMax-M2.7-highspeed", contextWindow: 204_800, maxOutput: 131_072, acceptsImages: false),
                        ]),
        BuiltInProvider(id: "openrouter", name: "OpenRouter", logo: "openrouter", mark: "OR", apiProtocol: .openAICompletions,
                        hosts: [ProviderHost(label: "", baseURL: "https://openrouter.ai/api/v1")],
                        keyCheckPath: "/auth/key",
                        commonModels: [
                            ModelInfo(id: "~anthropic/claude-sonnet-latest", name: "Claude Sonnet Latest", contextWindow: 1_000_000, maxOutput: 128_000, acceptsImages: true),
                            ModelInfo(id: "~openai/gpt-latest", name: "GPT Latest", contextWindow: 1_050_000, maxOutput: 128_000, acceptsImages: true),
                            ModelInfo(id: "~google/gemini-pro-latest", name: "Gemini Pro Latest", contextWindow: 1_048_576, maxOutput: 65_536, acceptsImages: true),
                        ]),
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
